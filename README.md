# Jarvis: voice control for your browser and Mac

How it works, and the plan for Shortcuts and iPhone control: [ARCHITECTURE.md](ARCHITECTURE.md).

## Install (one command)
macOS 14 or newer. Paste into Terminal:
```bash
curl -fsSL https://raw.githubusercontent.com/prateekx8/jarvis/main/install.sh | bash
```
It builds Jarvis from this repo, puts it in Applications and installs everything it needs: no Homebrew and no
system Python. The natural voice gets a private Python (via [uv](https://github.com/astral-sh/uv)) and the Kokoro
model, all inside `~/Library/Application Support/Jarvis`; offline answers get Ollama and `gemma2:2b`. About 3 GB
in total. The first time, macOS may ask to install the Command Line Tools (needed to build): click Install, then
run the command again. When Jarvis opens, allow Microphone, Speech Recognition and Automation.

Already cloned? Run `./install.sh`. Options: `--no-voice` (use the macOS voice), `--no-ollama` (no offline model),
`--no-open`. Re-run it any time to update. If a firewall such as LuLu asks about `uv`, `python` or Ollama, allow it.

## The app (recommended): Jarvis
Menu bar app in `app/`: on-device speech (Apple's Dictation engine), "Hey Jarvis" wake word, ⌥Space hotkey,
J.A.R.V.I.S.-style console with a live log (also written to `~/Library/Logs/VoiceBrowser.log`).

Build only (for development): `cd app && ./build.sh && open build/Jarvis.app`
- Say **"Hey Jarvis, open YouTube"** (one breath), or "Hey Jarvis" → chime → your command.
- Or **hold ⌥Space**, speak, release. Or **tap ⌥Space**, speak, pause.
- Menu bar 🎙: wake word on/off, Keep Console Open, Open Log File, model (default `gemma2:2b`), browser, spoken replies, recent commands.

**Browser:** open site · new tab · search · click <label> · type <x> [and press enter] · scroll · back/forward/reload · tab N / last tab · close tab · "what's this page about"
**Mac:** open/quit <app> · volume up/down/mute/set to N · play/pause/next/previous (Music, Spotify) · dark/light mode · lock screen · open downloads/desktop/documents · time, date, battery
**Claude:** multi-step tasks ("find the cheapest flight to Goa and compare airlines") are handed to Claude.
No shut down/restart by design.

Test without speaking:
```
app/build/VoiceBrowser.app/Contents/MacOS/VoiceBrowser --parse "open chrome" "volume to 30"   # show chosen actions
app/build/VoiceBrowser.app/Contents/MacOS/VoiceBrowser --do "what time is it"                 # and run them
```
Browser control sits behind the `BrowserDriver` protocol (`Browser.swift`); a Playwright driver can be added for test runs.

## Answers: Claude (online) or offline

Questions ("what…", "why…", "explain…") and multi-step tasks are answered instead of parsed as actions.
Menu → **Answers**: *Auto* (Claude when connected, else offline), *Claude*, or *Offline only*.

- "Hey Jarvis, **Claude,** what's on Hacker News?" → always Claude.
- "Hey Jarvis, **ask locally** what's the capital of Australia?" → always the local model (Gemma, ~0.5 s).

```
Jarvis app ── localhost bridge :8777 (token in ~/Library/Application Support/Jarvis/bridge.json)
   ▲                 ▲
   │                 └── Jarvis --mcp  (stdio MCP server, registered in Claude Code as "jarvis")
   │                         ▲
   │                         └── a Claude session: jarvis_wait_for_request → think/act → jarvis_answer
   └── or, with no session open: the Claude CLI headless (`claude -p`, needs `claude auth login` once)
```

### Draft a reply
"Hey Jarvis, **draft a reply** [saying I'll join at 4]". Jarvis sends Claude the conversation (selected text,
else the browser page, else the clipboard); the draft goes into the focused reply box and onto the clipboard.
It is never sent. Offline, Gemma drafts it.

### Full Control (opt-in, 30 minutes)
"Hey Jarvis, **give Claude full control**" (or the menu) gives Claude extra tools: `jarvis_screenshot`,
`jarvis_click`, `jarvis_type`, `jarvis_key`, `jarvis_applescript`, `jarvis_shell`, and richer context
(page text, clipboard). An amber *CLAUDE · FULL CONTROL* badge shows while it's on; every action is logged.
"**Take back control**" ends it; it also ends after 30 minutes without use. Only the person at the Mac can turn
it on (voice or menu), never a bridge client. Power off, `sudo`, disk erase, deleting home/root, keychain
reads and similar are always refused. Keyboard/mouse need Accessibility, screenshots need Screen Recording.

### Clap
While Jarvis is listening for "Hey Jarvis", a sharp clap makes it say "Are you looking for something? Clap
detected." and listen for a command. Menu → Respond to Claps.

### Phone
Follow Jarvis and talk to it from your iPhone, privately over **Tailscale** (on the Mac and the phone, same
account). Menu → **Connect Phone…** shows a QR code; scan it, then Share → Add to Home Screen.
- The page shows what Jarvis is doing (status, what it heard, the live log, front app and tab), refreshing every 2 s.
- Type or dictate a command (the keyboard's mic) and get Jarvis's reply on the phone; **Screen** shows a small
  screenshot of the Mac; **Stop** and **Mute** work from the phone. **Unmute** only at the Mac.
- Served only on the Mac's Tailscale address (port 8778), never the open internet or the local Wi-Fi, with its own
  token (separate from the agents' token). Phone commands can't turn on Full Control, don't open the Mac's mic, and
  are refused while Jarvis is muted. Menu → Connect Phone → **Reset Link** invalidates the old link.
- The Claude mobile app (Remote Control on the Claude session serving Jarvis) also works for longer conversations.

### Conversation mode
After Jarvis answers a spoken command, it listens for about 6 seconds for a follow-up: no "Hey Jarvis" needed
("and tomorrow?", "open the first one", "now close it"). Each follow-up keeps it going; silence, "that's all",
"thank you Jarvis" or "stop" ends it. If Claude answered, follow-up questions go back to Claude, marked as a
continuation with the previous exchange. It starts listening only after Jarvis stops talking (so it doesn't hear
itself), never after commands that came from Claude, scripts or the phone, and never while muted.
Menu → Keep Listening After Replies.

### Mute and Stop
- "Hey Jarvis, **mute**" (or "be quiet", "go to sleep", menu → Mute Jarvis): no listening, no speaking, and
  **nothing executes**, including agent commands, until you unmute (menu or ⌥Space). "Mute the sound" mutes the Mac.
- "**Stop**" / "cancel" / "never mind" (or menu → Stop, or ⌥Space while it talks): stops speaking and listening;
  a command still running finishes silently.
- The wake word now needs "**Hey** Jarvis" (or OK/Hi) so "Jarvis" in normal talk doesn't trigger it
  (menu → Wake Only on "Hey Jarvis").
- Menu → **Teach My Clap…**: clap three times; softer sounds are ignored after that.

### Memory (SQLite)
Every request is saved in `~/Library/Application Support/Jarvis/memory.sqlite` with its result and engine.
- Follow-ups: "**do that again**", "**close it**" (closes the app or tab you just opened).
- "**Remember that** my sister's name is Riya" · "**what do you remember**" · "**forget that**" · "**forget everything**".
- Gemma gets relevant facts and recent commands; Claude gets `memory_facts` and `recent_history` in every request,
  plus `jarvis_memory` / `jarvis_remember` tools.

### Voice and Whisper
- Jarvis speaks through **Creator Studio's voice server** (mlx-audio on `127.0.0.1:8765`: Kokoro on the GPU) when
  it's running, else its own Kokoro server (now on **8766**, so the two never collide), else the macOS voice.
  After a failure it reconnects by itself instead of staying on the robotic voice. Menu → Voice shows which one is
  in use and can start Creator Studio's server.
- **Whisper** (large-v3-turbo, same server) re-transcribes each command for accuracy (names and rare words); Apple's
  recognizer is the instant fallback. About 1.2 s per command; warmed up at launch. Menu → Voice → Use Whisper.
- **My Personal Voice**: pick it in menu → Voice to speak in your own voice, trained by macOS (System Settings →
  Accessibility → Personal Voice). Jarvis asks for access the first time. (Cloning with Chatterbox works for
  videos in Creator Studio but takes ~20 s a line, too slow for live replies.)

### Type into any app
"Hey Jarvis, **type** …" / "**reply** …" / "**dictate** …" puts the words at the cursor in the front app (a Claude
prompt box, Slack, Notes, a browser field) and highlights them. Return is pressed only if you say "and press
enter". "Draft a reply …" with nothing to reply to types your words the same way. Needs Accessibility.

### Look at the screen
"Hey Jarvis, **look at my screen**, what does this error mean?" takes a screenshot and reads its text on the Mac
(Apple Vision OCR) and labels what's in it (Vision's built-in classifier, no model download). Claude gets the image, text and labels; offline, Gemma answers from the text and labels. Needs Screen Recording.

### CPU guardrail
Above 85% CPU, Jarvis doesn't start the local model: commands go to Claude if connected, otherwise it says it's
busy. Instant commands still work. Menu → Skip Local Model When CPU Is Busy.

### Connecting Claude
Setup (and menu → Answers → Connect Claude Code) registers the MCP server. Menu → Answers → **Start Claude
Brain in Terminal** opens a Claude Code session that serves Jarvis.

MCP tools: `jarvis_wait_for_request`, `jarvis_answer`, `jarvis_say`, `jarvis_command` (one browser/Mac
action), `jarvis_page` (current tab title, URL, text), `jarvis_status`. To serve Jarvis, open a Claude Code
session and say: *"Serve Jarvis: loop on jarvis_wait_for_request and answer each request."*

Register the MCP server (done once): `claude mcp add --scope user jarvis -- /Applications/Jarvis.app/Contents/MacOS/VoiceBrowser --mcp`
(also in menu → Answers → Copy MCP Setup Command). Test without speaking: `POST /hear {"text": "..."}` on the bridge.

The Python script `vb.py` below is the same pipeline as a CLI.

```
Mac Dictation / Shortcut "Dictate Text"
        │  text
        ▼
vb.py ── regex fast path (scroll, back, reload…)  ──┐   ~0 ms
   └──── Ollama gemma3:4b, JSON-schema output ──────┤   ~0.3–1 s
                                                    ▼
         AppleScript + injected JS → your real Chrome (keeps your sign-ins)
                                                    │
         open-ended tasks ("compare flights…") ─────┴─► Claude (claude --chrome -p)
```

## One-time setup
1. `ollama pull gemma2:2b` (or `gemma3:1b`, `qwen3:1.7b`; set `VB_MODEL=...`)
2. Chrome → **View → Developer → Allow JavaScript from Apple Events** (needed for click/type/scroll/summarize)
3. First run: macOS asks to let Terminal control Chrome → Allow
4. System Settings → Keyboard → Dictation → On (pick a shortcut, e.g. Fn twice)

## Mode A: terminal loop (fastest to try)
```
python3 vb.py
```
Press the Dictation key, speak ("open hacker news"), press Enter.

## Mode B: hands-free hotkey/Siri (recommended)
Shortcuts app → new shortcut "Browser":
1. **Dictate Text** (Stop listening: After Pause)
2. **Run Shell Script**: `/opt/homebrew/bin/python3 /path/to/jarvis/vb.py "$1"`, Pass input: *as arguments*

Then give it a keyboard shortcut (shortcut ⓘ → Add Keyboard Shortcut) or say "Hey Siri, Browser".

## Commands it understands
open/go to <site> · new tab [site] · search for <x> · click <label> · type <x> [and press enter]
· scroll up/down/top/bottom · back/forward/reload · close tab · go to tab 3 / last tab
· what's this page about (summarizes and reads it aloud) · anything multi-step → Claude

Env: `VB_MODEL`, `VB_BROWSER=Safari`, `VB_SPEAK=0`.

## Tests
```
cd app && swift test                 # 62 unit tests: parsing, typing, conversation, phone, meta, mute/stop, safety, keys, clap, memory, follow-ups, CPU guard, audio, Whisper, agent config, HTTP, MCP, bridge
python3 -I tests/e2e_bridge.py       # 15 end-to-end tests against the running Jarvis.app (MCP, memory, Kokoro + Whisper on the voice server)
```

## Roadmap
Planned features for the cloud-connected assistant: [ROADMAP.md](ROADMAP.md). Connecting Claude, Antigravity, Cursor or any agent: [docs/AGENTS.md](docs/AGENTS.md).
