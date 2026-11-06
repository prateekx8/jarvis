#!/usr/bin/env python3
"""Voice -> local LLM (Ollama) -> Chrome control on macOS.

Usage:
  vb.py                 interactive loop: press your Dictation key, speak, press Enter
  vb.py "open github"   one-shot (used by the macOS Shortcut / hotkey)

Env:
  VB_MODEL    Ollama model (default gemma2:2b)
  VB_BROWSER  "Google Chrome" (default) or "Safari"
  VB_SPEAK    1 to speak results with `say` (default 1)
"""
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request

MODEL = os.environ.get("VB_MODEL", "gemma2:2b")
BROWSER = os.environ.get("VB_BROWSER", "Google Chrome")
SPEAK = os.environ.get("VB_SPEAK", "1") == "1"
OLLAMA = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")

ACTIONS = ["open_url", "search", "new_tab", "close_tab", "switch_tab", "back",
           "forward", "reload", "scroll", "click", "type", "summarize", "escalate"]

SCHEMA = {
    "type": "object",
    "properties": {
        "action": {"type": "string", "enum": ACTIONS},
        "url": {"type": "string"},
        "query": {"type": "string"},
        "text": {"type": "string"},
        "direction": {"type": "string", "enum": ["up", "down", "top", "bottom"]},
        "index": {"type": "integer"},
        "submit": {"type": "boolean"},
    },
    "required": ["action"],
}

SYSTEM = """You turn a spoken browser command into ONE JSON action. Speech-to-text may contain errors; infer intent.
Actions:
- open_url {url}: go to a site in the current tab. Expand names to full URLs ("youtube" -> https://www.youtube.com).
- new_tab {url?}: open a new tab, optionally at url.
- search {query}: web search.
- close_tab, back, forward, reload: no args.
- switch_tab {index}: 1-based tab number; use -1 for last tab.
- scroll {direction}: up/down/top/bottom.
- click {text}: click the link/button whose visible label best matches text.
- type {text, submit}: type text into the focused/first input; submit=true if the user says search/enter/submit/go.
- summarize: user wants the current page read, summarized or explained.
- escalate {text}: multi-step or open-ended tasks (compare, book, fill a whole form, research, "find me the cheapest..."). Put the full task in text.
Examples:
"open hacker news" -> {"action":"open_url","url":"https://news.ycombinator.com"}
"search for best mechanical keyboards" -> {"action":"search","query":"best mechanical keyboards"}
"click on sign in" -> {"action":"click","text":"sign in"}
"go to the third tab" -> {"action":"switch_tab","index":3}
"type hello world and press enter" -> {"action":"type","text":"hello world","submit":true}
"what is this page about" -> {"action":"summarize"}
"find a cheap flight to goa next friday and compare airlines" -> {"action":"escalate","text":"find a cheap flight to goa next friday and compare airlines"}"""

# Instant, no-LLM handling for the most common phrases.
FAST = [
    (r"^(scroll )?down$|^scroll down", {"action": "scroll", "direction": "down"}),
    (r"^(scroll )?up$|^scroll up", {"action": "scroll", "direction": "up"}),
    (r"^(go )?back$", {"action": "back"}),
    (r"^(go )?forward$", {"action": "forward"}),
    (r"^(reload|refresh)( (the )?page)?$", {"action": "reload"}),
    (r"^close( this)?( tab)?$", {"action": "close_tab"}),
    (r"^new tab$", {"action": "new_tab"}),
    (r"^(go to |scroll to )?(the )?top$", {"action": "scroll", "direction": "top"}),
    (r"^(go to |scroll to )?(the )?bottom$", {"action": "scroll", "direction": "bottom"}),
]


def say(msg):
    print(f"  -> {msg}")
    if SPEAK:
        subprocess.Popen(["say", "-r", "210", msg])


def ollama(messages, schema=None):
    body = {"model": MODEL, "messages": messages, "stream": False,
            "keep_alive": "30m", "options": {"temperature": 0}}
    if schema:
        body["format"] = schema
    req = urllib.request.Request(f"{OLLAMA}/api/chat", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)["message"]["content"]


ORDINALS = {"first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
            "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "one": 1, "two": 2, "three": 3,
            "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "last": -1}
TAB_RE = r"^(?:go to |switch to |open )?(?:the )?(?:tab (?:number )?(\w+)|(?:(\d+)(?:st|nd|rd|th)?|(\w+)) tab)$"
DOMAIN_RE = r"^(?:open |go to |visit )?((?:[a-z0-9-]+\.)+[a-z]{2,})(/\S*)?$"


def parse(utterance):
    # Speech engines spell out web addresses: "amazon dot in" -> "amazon.in".
    utterance = re.sub(r"\s+dot\s+", ".", utterance.strip(), flags=re.I)
    u = re.sub(r"[.!?]+$", "", utterance.lower())
    u = re.sub(r"^(please |hey browser,? |browser,? )", "", u)
    for pat, act in FAST:
        if re.search(pat, u):
            return dict(act)
    if m := re.match(TAB_RE, u):
        word = m.group(1) or m.group(2) or m.group(3)
        n = int(word) if word.isdigit() else ORDINALS.get(word)
        if n:
            return {"action": "switch_tab", "index": n}
    if m := re.match(DOMAIN_RE, u):
        return {"action": "open_url", "url": "https://" + m.group(1) + (m.group(2) or "")}
    out = ollama([{"role": "system", "content": SYSTEM},
                  {"role": "user", "content": utterance}], SCHEMA)
    a = json.loads(out)
    # Small models drop optional fields; don't rely on them for "press enter".
    if a.get("action") == "type" and re.search(r"\b(press enter|hit enter|press return|and search|and submit|and go)$", u):
        a["submit"] = True
    return a


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr.strip())
    return r.stdout.strip()


def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def js(code):
    """Run JS in the active tab and return its result as a string."""
    if BROWSER == "Safari":
        return osa(f'tell application "Safari" to do JavaScript {q(code)} in current tab of front window')
    return osa(f'tell application "Google Chrome" to execute active tab of front window javascript {q(code)}')


def set_url(url):
    if BROWSER == "Safari":
        osa(f'tell application "Safari" to set URL of current tab of front window to {q(url)}')
    else:
        osa(f'tell application "Google Chrome" to set URL of active tab of front window to {q(url)}')


def ensure_window():
    osa(f'tell application "{BROWSER}" to activate')
    osa(f'tell application "{BROWSER}" to if (count of windows) = 0 then make new window')


CLICK_JS = r"""(() => {
  const want = %s.toLowerCase().trim();
  const els = [...document.querySelectorAll('a,button,[role=button],[role=link],[role=tab],[role=menuitem],input[type=submit],input[type=button],summary,label')]
    .filter(e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; });
  const label = e => (e.innerText || e.value || e.getAttribute('aria-label') || e.title || '').toLowerCase().trim().replace(/\s+/g,' ');
  let best = null, score = 0;
  for (const e of els) {
    const l = label(e); if (!l) continue;
    let s = l === want ? 100 : l.startsWith(want) ? 80 : l.includes(want) ? 60 : 0;
    if (!s) { const w = want.split(' '); s = 40 * w.filter(x => l.includes(x)).length / w.length; }
    const r = e.getBoundingClientRect();
    if (r.top >= 0 && r.bottom <= innerHeight) s += 5;
    if (s > score) { score = s; best = e; }
  }
  if (!best || score < 30) return 'NOTFOUND';
  best.scrollIntoView({block: 'center'}); best.focus(); best.click();
  return label(best).slice(0, 60);
})()"""

TYPE_JS = r"""(() => {
  const ok = e => e && e.matches && e.matches('input:not([type=hidden]):not([type=submit]):not([type=button]),textarea,[contenteditable=true]');
  let el = document.activeElement;
  if (!ok(el)) el = [...document.querySelectorAll('input[type=search],input[type=text],input:not([type]),textarea,[contenteditable=true]')]
    .find(e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; });
  if (!el) return 'NOINPUT';
  el.focus();
  if (el.isContentEditable) { document.execCommand('insertText', false, %s); }
  else {
    const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value').set;
    setter.call(el, %s);
    el.dispatchEvent(new Event('input', {bubbles: true}));
    el.dispatchEvent(new Event('change', {bubbles: true}));
  }
  if (%s) {
    el.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true}));
    if (el.form) el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit();
  }
  return 'OK';
})()"""


def execute(a):
    act = a["action"]
    ensure_window()
    if act == "open_url":
        url = a.get("url") or ""
        if not re.match(r"^https?://", url):
            url = "https://" + url
        set_url(url)
        say(f"Opening {urllib.parse.urlparse(url).netloc}")
    elif act == "new_tab":
        url = a.get("url") or ("chrome://newtab" if BROWSER != "Safari" else "")
        if url and not re.match(r"^(https?|chrome)://", url):
            url = "https://" + url
        if BROWSER == "Safari":
            osa(f'tell application "Safari" to tell front window to set current tab to (make new tab with properties {{URL:{q(url)}}})')
        else:
            osa(f'tell application "Google Chrome" to tell front window to make new tab with properties {{URL:{q(url)}}}')
        say("New tab")
    elif act == "search":
        set_url("https://www.google.com/search?q=" + urllib.parse.quote_plus(a.get("query", "")))
        say(f"Searching {a.get('query', '')}")
    elif act == "close_tab":
        tab = "current tab" if BROWSER == "Safari" else "active tab"
        osa(f'tell application "{BROWSER}" to close {tab} of front window')
    elif act == "switch_tab":
        i = a.get("index", 1)
        if BROWSER == "Safari":
            idx = "last tab" if i == -1 else f"tab {i}"
            osa(f'tell application "Safari" to tell front window to set current tab to {idx}')
        else:
            n = int(osa('tell application "Google Chrome" to count tabs of front window'))
            osa(f'tell application "Google Chrome" to set active tab index of front window to {n if i == -1 else max(1, min(i, n))}')
        say(f"Tab {i if i != -1 else 'last'}")
    elif act in ("back", "forward", "reload") and BROWSER != "Safari":
        # Native Chrome commands: work even with "Allow JavaScript from Apple Events" off.
        verb = {"back": "go back", "forward": "go forward", "reload": "reload"}[act]
        osa(f'tell application "Google Chrome" to {verb} active tab of front window')
    elif act in ("back", "forward", "reload"):
        js({"back": "history.back()", "forward": "history.forward()", "reload": "location.reload()"}[act])
    elif act == "scroll":
        d = a.get("direction", "down")
        js({"down": "scrollBy({top: innerHeight*0.8, behavior:'smooth'})",
            "up": "scrollBy({top: -innerHeight*0.8, behavior:'smooth'})",
            "top": "scrollTo({top: 0, behavior:'smooth'})",
            "bottom": "scrollTo({top: document.body.scrollHeight, behavior:'smooth'})"}[d])
    elif act == "click":
        r = js(CLICK_JS % json.dumps(a.get("text", "")))
        say(f"Couldn't find {a.get('text')}" if r == "NOTFOUND" else f"Clicked {r}")
    elif act == "type":
        t = json.dumps(a.get("text", ""))
        r = js(TYPE_JS % (t, t, "true" if a.get("submit") else "false"))
        say("No text box on this page" if r == "NOINPUT" else "Typed")
    elif act == "summarize":
        page = js("document.title + '\\n\\n' + document.body.innerText.slice(0, 8000)")
        say("Reading the page")
        s = ollama([{"role": "system", "content": "Summarize this web page in 3 short spoken sentences. No markdown."},
                    {"role": "user", "content": page}])
        say(s.strip())
    elif act == "escalate":
        escalate(a.get("text", ""))


def escalate(task):
    """Hand open-ended, multi-step tasks to Claude (Claude Code + Claude in Chrome)."""
    claude = shutil.which("claude")
    if not claude:
        say("That needs Claude. Install the Claude Code CLI to enable hand-off.")
        print(f"  [escalate] {task}")
        return
    say("Handing that to Claude")
    subprocess.Popen([claude, "--chrome", "-p", task])


def handle(utterance):
    if not utterance.strip():
        return
    try:
        a = parse(utterance)
        print(f"  {json.dumps(a)}")
        execute(a)
    except Exception as e:
        say(f"Error: {e}")


def main():
    if len(sys.argv) > 1:
        handle(" ".join(sys.argv[1:]))
        return
    print(f"Voice browser · model={MODEL} · browser={BROWSER}")
    print("Press your Dictation key (default: Fn twice / mic key), speak, then Enter. Ctrl-C to quit.")
    while True:
        try:
            handle(input("\n🎤 "))
        except (EOFError, KeyboardInterrupt):
            print()
            break


if __name__ == "__main__":
    main()
