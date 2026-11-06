"""Local neural voice for Jarvis (Kokoro-82M via ONNX). Offline, localhost only.

POST /tts  {"text": "...", "voice": "bm_george", "speed": 1.0}
  -> raw little-endian float32 mono PCM; sample rate in the X-Sample-Rate header.
GET /health -> {"ok": true, "voices": [...]}
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
from kokoro_onnx import Kokoro

MODELS = os.environ.get("JARVIS_TTS_MODELS", os.path.join(os.path.dirname(os.path.abspath(__file__)), "models"))
PORT = int(os.environ.get("JARVIS_TTS_PORT", "8766"))  # 8765 belongs to Creator Studio's voice server
kokoro = Kokoro(os.path.join(MODELS, "kokoro-v1.0.onnx"), os.path.join(MODELS, "voices-v1.0.bin"))
VOICES = sorted(kokoro.get_voices())


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            return self.send_error(404)
        self._send(200, json.dumps({"ok": True, "voices": VOICES}).encode(), "application/json")

    def do_POST(self):
        if self.path != "/tts":
            return self.send_error(404)
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            voice = req.get("voice", "bm_george")
            if voice not in VOICES:
                voice = "bm_george"
            lang = "en-gb" if voice.startswith("b") else "en-us"
            samples, rate = kokoro.create(req["text"], voice=voice, speed=float(req.get("speed", 1.0)), lang=lang)
            self._send(200, np.asarray(samples, dtype="<f4").tobytes(), "application/octet-stream", {"X-Sample-Rate": str(rate)})
        except Exception as e:  # report, keep serving
            self._send(500, str(e).encode(), "text/plain")

    def _send(self, code, body, ctype, headers=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"Jarvis voice on http://127.0.0.1:{PORT} ({len(VOICES)} voices)", file=sys.stderr, flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
