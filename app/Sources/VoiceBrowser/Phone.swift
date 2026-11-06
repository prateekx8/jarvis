import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// The Mac's Tailscale address (100.64.0.0/10), if Tailscale is running. The phone page is served only there:
/// private to your own devices, never the open internet or the local Wi-Fi.
enum Tailnet {
    static func address() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var p = head
        while let ifa = p?.pointee {
            defer { p = ifa.ifa_next }
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if isTailscale(ip) { return ip }
        }
        return nil
    }

    /// 100.64.0.0 – 100.127.255.255 (the CGNAT range Tailscale uses).
    static func isTailscale(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }
}

/// The phone link's token, separate from the agents' bridge token (the phone gets fewer powers).
enum PhoneLink {
    static let port: UInt16 = 8778
    static let file = Paths.support.appendingPathComponent("phone.json")

    static func token(reset: Bool = false) -> String {
        if !reset, let data = try? Data(contentsOf: file),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String], let t = obj["token"], !t.isEmpty {
            return t
        }
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: try? JSONSerialization.data(withJSONObject: ["token": t]),
                                       attributes: [.posixPermissions: 0o600])
        return t
    }

    static func url(host: String, token: String) -> String { "http://\(host):\(port)/phone?t=\(token)" }

    static func qrCode(_ text: String, size: CGFloat = 260) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: size / ci.extent.width, y: size / ci.extent.height))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// A small JPEG of a screenshot for the phone (about 1200 px on the long side).
    static func thumbnail(_ png: URL, maxPixels: Int = 1200) -> Data? {
        guard let src = CGImageSourceCreateWithURL(png as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

/// The phone page: what Jarvis is doing, the live log, a box to type or dictate a command, and buttons for
/// screen / stop / mute. Polls every 2 s. "Add to Home Screen" makes it feel like an app.
enum PhonePage {
    static let html = #"""
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes"><meta name="theme-color" content="#04121a">
    <title>Jarvis</title>
    <style>
      :root{--cyan:#40e0ff;--amber:#ff9e3d;--bg:#04121a;--card:#0a1f2b;--ink:#e8f7ff;--dim:#7fa7b8}
      *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px -apple-system,system-ui;padding:16px 16px calc(16px + env(safe-area-inset-bottom))}
      h1{font:800 16px ui-monospace,Menlo,monospace;letter-spacing:4px;color:var(--cyan);margin:0}
      .top{display:flex;align-items:center;justify-content:space-between;margin-bottom:12px}
      .chip{font:700 11px ui-monospace,Menlo,monospace;letter-spacing:2px;padding:4px 8px;border:1px solid var(--cyan);color:var(--cyan);border-radius:4px}
      .chip.muted,.chip.fault{border-color:var(--amber);color:var(--amber)}
      .card{background:var(--card);border:1px solid #16394a;border-radius:10px;padding:12px;margin-bottom:12px}
      .now{font-size:17px;font-weight:600}.detail{color:var(--dim);margin-top:4px;white-space:pre-wrap}
      .ctx{color:var(--dim);font-size:12px;margin-top:8px}
      .log{font:12px ui-monospace,Menlo,monospace;max-height:42vh;overflow:auto}
      .log div{padding:3px 0;border-bottom:1px solid #102a37}.log .k{color:var(--cyan);display:inline-block;width:46px}
      .log .FAULT{color:var(--amber)}.log .OK{color:#5affb3}
      form{display:flex;gap:8px}input{flex:1;font-size:16px;padding:12px;border-radius:10px;border:1px solid #16394a;background:#06202c;color:var(--ink)}
      button{font:600 15px -apple-system;padding:12px 14px;border-radius:10px;border:0;background:var(--cyan);color:#022}
      .row{display:flex;gap:8px;margin-top:10px}.row button{flex:1;background:#123446;color:var(--ink)}
      img{width:100%;border-radius:8px;margin-top:10px;display:none}
      .reply{margin-top:10px;color:var(--cyan);white-space:pre-wrap}
    </style></head><body>
    <div class="top"><h1>J.A.R.V.I.S.</h1><span id="chip" class="chip">…</span></div>
    <div class="card"><div class="now" id="now">Connecting…</div><div class="detail" id="detail"></div><div class="ctx" id="ctx"></div></div>
    <div class="card">
      <form id="f"><input id="q" placeholder="Tell Jarvis… (tap the mic on the keyboard)" autocomplete="off"><button>Send</button></form>
      <div class="reply" id="reply"></div>
      <div class="row"><button id="screen">Screen</button><button id="stop">Stop</button><button id="mute">Mute</button></div>
      <img id="shot" alt="Mac screen">
    </div>
    <div class="card log" id="log"></div>
    <script>
      const t=new URLSearchParams(location.search).get('t');const H={'X-Jarvis-Phone':t,'Content-Type':'application/json'};
      const $=id=>document.getElementById(id);
      async function api(p,b){const r=await fetch(p,{method:b===undefined?'GET':'POST',headers:H,body:b===undefined?undefined:JSON.stringify(b)});return r.json();}
      function esc(s){return String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));}
      async function poll(){try{const s=await api('/phone/state');
        $('chip').textContent=s.status;$('chip').className='chip '+String(s.status).toLowerCase();
        $('now').textContent=s.transcript||'Awaiting command…';$('detail').textContent=s.detail||'';
        $('ctx').textContent=[s.front_app,s.page_title].filter(Boolean).join(' · ');
        $('log').innerHTML=(s.log||[]).slice().reverse().map(e=>`<div><span class="k ${e.kind}">${e.kind}</span> ${esc(e.time.slice(0,8))} ${esc(e.text)}</div>`).join('');
      }catch(e){$('chip').textContent='OFFLINE';}}
      $('f').onsubmit=async e=>{e.preventDefault();const q=$('q').value.trim();if(!q)return;$('q').value='';$('reply').textContent='…';
        const r=await api('/phone/say',{text:q});$('reply').textContent=r.reply||r.error||'';poll();};
      $('screen').onclick=async()=>{$('reply').textContent='Taking a screenshot…';const r=await api('/phone/screen',{});
        if(r.jpeg){$('shot').src='data:image/jpeg;base64,'+r.jpeg;$('shot').style.display='block';$('reply').textContent='';}else $('reply').textContent=r.error;};
      $('stop').onclick=async()=>{const r=await api('/phone/stop',{});$('reply').textContent=r.reply;};
      $('mute').onclick=async()=>{const r=await api('/phone/mute',{});$('reply').textContent=r.reply;poll();};
      poll();setInterval(poll,2000);
    </script></body></html>
    """#
}
