# Jarvis architecture

Jarvis is a macOS menu bar app that turns speech into browser and Mac actions. Everything runs on the
Mac: speech recognition, the language model and the voice. Only multi-step tasks leave the Mac, and only
when handed to Claude.

## 1. Pipeline

```
 INPUT                 HEAR                  UNDERSTAND                         ACT                       RESPOND
┌──────────────┐    ┌──────────────────┐   ┌───────────────────────────┐   ┌────────────────────────┐   ┌──────────────────┐
│ "Hey Jarvis" │    │ SFSpeechRecognizer│   │ 1 meta: start/end session │   │ AppleScriptDriver      │   │ HUD console      │
│ ⌥Space       │───▶│ on-device         │──▶│ 2 instant rules (regex)   │──▶│  Chrome / Safari       │──▶│ log file         │
│ session loop │    │ (Dictation engine)│   │ 3 Gemma 2B via Ollama     │   │  open, tabs, click,    │   │ Kokoro voice     │
│ typed / menu │    │ wake word + pause │   │   JSON-schema output      │   │  type, scroll, summary │   │ (macOS voice     │
└──────────────┘    │ detection         │   │ 4 guardrails              │   │ MacDriver              │   │  as fallback)    │
                    └──────────────────┘   └───────────────────────────┘   │  apps, volume, music,  │   └──────────────────┘
                                                                            │  dark mode, lock, info │
                                                                            │ Claude hand-off        │
                                                                            │  multi-step tasks      │
                                                                            └────────────────────────┘
```

A command always becomes **one `Action`** (`Brain.swift`): a small JSON object such as
`{"action":"click","text":"sign in"}` or `{"action":"volume","level":30}`. The model never writes code or
free-form steps. It picks from a fixed list, and Ollama forces its output to match a JSON schema, which is
why a 2B model is reliable enough.

### Understanding a command, in order
1. **Meta commands** (`App.swift` `run`): "start session", "end session", "that's all". These never reach the model.
2. **Instant rules** (`Brain.fastPath`, `tabRegex`, `domainRegex`, `MacCommands.fast`): scroll, back, tab numbers,
   spoken web addresses ("amazon dot in"), volume, music, dark mode, lock, time, battery, "open/quit <installed app>".
   They take 2–10 ms and are deterministic.
3. **Gemma 2B** (`Brain.parse` → Ollama `/api/chat`, temperature 0, `format` = JSON schema): everything else,
   e.g. "open hacker news", "make it a bit louder", "what's this page about". Takes about 1.1–1.6 s.
4. **Guardrails** after the model: "quit/close …" can never become *open*; a volume action needs a sound word
   (so "brightness up" is refused instead of turning the volume up); "press enter / and search" always submits.

### Acting
| Executor | How | Typical time |
|---|---|---|
| `AppleScriptDriver` (`Browser.swift`) | AppleScript to Chrome/Safari; JavaScript injected into the page for click, type, scroll, summary. Uses your real browser profile and sign-ins. | ~146 ms avg (12 runs) |
| `MacDriver` (`Mac.swift`) | `NSWorkspace` (apps, folders), AppleScript (volume, Music/Spotify, dark mode), `pmset` (lock, battery). No shut down / restart by design. | ~1 ms |
| Claude hand-off | Opens Claude Code (`claude --chrome "<task>"`) in Terminal, or copies the task and opens the Claude app. | — |

Both executors sit behind a small interface (`BrowserDriver`), so a Playwright driver for scripted test runs
can be added without touching speech or parsing.

### Responding
- **Console** (`HUD.swift`): a floating, non-activating panel (it never takes focus from the browser) with an
  arc reactor that reacts to mic level and state, plus a timestamped log: `MIC → HEARD → PARSE (source, ms) → EXEC (ms) → OK/FAULT`.
- **Log file**: `~/Library/Logs/Jarvis.log` (earlier builds: `VoiceBrowser.log`).
- **Voice** (`Voice.swift` + `tts/server.py`): Kokoro-82M neural voice; replies are split into sentences and the
  first one plays after ~0.75 s. Falls back to the macOS British voice if the voice server isn't running.

## 2. States

```
                 "Hey Jarvis" / ⌥Space
   ┌────────┐ ───────────────────────▶ ┌───────────┐  pause / key up  ┌────────────┐
   │ idle   │                          │ listening │ ───────────────▶ │ thinking   │
   │ (wake  │ ◀─────────────────────── └───────────┘                  │ parse + act│
   │ armed) │      nothing heard             ▲                        └─────┬──────┘
   └────────┘                                │ session: next command        │
        ▲                                    └──────────────────────────────┤
        │                 reply spoken, then back to waiting                ▼
        └─────────────────────────────────────────────────────────── done / error
```

- **Wake word** (`Speech.swift`): continuous on-device recognition watching for "Jarvis" (and common
  mis-hearings), restarted every 50 s to keep transcripts short. Words after the wake phrase become the
  command, so "Hey Jarvis, open YouTube" works in one breath.
- **When it listens** (menu → Hey Jarvis): Always, Only while chosen apps are open (Chrome by default, armed
  and paused on app launch/quit), or Off.
- **Session mode**: after each command Jarvis listens again without the wake word, until "end session" or
  2 minutes with no command.
- Jarvis waits until it has finished speaking before listening again, so it can't hear itself.

## 3. Processes, ports and data

| Process | Listens on | Role |
|---|---|---|
| Jarvis.app (`VoiceBrowser` binary) | nothing | Menu bar app: speech, parsing, actions, console |
| Ollama | `127.0.0.1:11434` | Runs `gemma2:2b` (1.6 GB), kept in memory 30 min (`keep_alive`) |
| Kokoro voice server (`server.py`) | `127.0.0.1:8765` | Started and stopped by Jarvis; returns raw 24 kHz PCM |

- Installed by setup: `~/Library/Application Support/Jarvis/tts` (Python venv + 340 MB voice model).
- Settings: `UserDefaults` (model, browser, voice, wake mode and apps, session, console pinned, recent commands).
- macOS permissions: Microphone, Speech Recognition, Automation (Chrome, System Events, Music/Spotify, Terminal).
  macOS ties them to the app's signature; ad-hoc signed builds are asked again after every rebuild, a local
  "Jarvis Local Signing" certificate fixes that (see `app/build.sh`).

## 4. Source map

| File | Responsibility |
|---|---|
| `App.swift` | App lifecycle, menu, hotkey, wake/session logic, the pipeline (`run`), `--parse` / `--do` test flags |
| `Speech.swift` | Mic capture, on-device recognition, wake word, pause detection, mic level |
| `Brain.swift` | `Action` type, instant rules, Ollama call with JSON schema, guardrails |
| `Browser.swift` | `BrowserDriver` protocol, AppleScript/JS browser control, Claude hand-off |
| `Mac.swift` | `MacDriver`, installed-app matching, instant Mac rules |
| `Voice.swift` | Kokoro playback (sentence streaming), macOS voice fallback, voice server lifecycle |
| `HUD.swift` | Console UI, arc reactor, log store and log file |
| `HotKey.swift` | Global ⌥Space (Carbon, no Accessibility permission needed) |
| `Setup.swift` | First-run setup: Ollama, model download, voice install, permissions, Chrome check, login item |
| `tts/server.py` | Kokoro TTS HTTP server (localhost only) |

## 5. Known limits
- Browser click/type/scroll/summary need Chrome's **View → Developer → Allow JavaScript from Apple Events**.
- No brightness, Focus/Do Not Disturb or HomeKit yet (all reachable through Shortcuts, see below).
- The Mac must be awake; a locked screen still runs commands but you can't see them.
- Gemma 2B handles single actions; anything multi-step goes to Claude by design.

---

## 6. Analysis: Shortcuts and control from the iPhone

There are two separate ideas here, and they combine well:

- **A. Jarvis runs your Shortcuts** ("Hey Jarvis, turn on the air purifier").
- **B. Your iPhone sends commands to Jarvis** (speak to the phone anywhere, the Mac does the work).

### A. Jarvis runs Shortcuts: do this first

macOS has a `shortcuts` command line tool (`shortcuts list`, `shortcuts run "<name>"`). Adding one action,
`run_shortcut {name}`, matched against your shortcut names, gives Jarvis everything Shortcuts can do:
HomeKit devices, Focus / Do Not Disturb, brightness, messages, reminders, and any shortcut you build later.
Your Mac already has relevant ones: **Turn on/off a device**, **Air purifier**, **Morning Summary**, **Log Water**.

- Cost: small (one action, one instant rule like "run <shortcut>", names fetched at launch).
- Risk: low. It only runs shortcuts you created. Shortcuts that ask questions pause, so they work best
  without prompts, or by passing the spoken text as input (`shortcuts run "<name>" --input-path -`).
- Since Shortcuts sync over iCloud, one library serves both the iPhone and Jarvis.

### B. iPhone → Mac: options compared

| Option | How it works | Reply on phone | Works away from home | Setup | Verdict |
|---|---|---|---|---|---|
| **1. Jarvis HTTP API + iPhone Shortcut** | iPhone Shortcut: *Dictate Text* → *Get Contents of URL* (POST with token) → *Speak Text* of the reply. Jarvis adds a small authenticated endpoint. | Yes: what Jarvis heard, did and said | Yes, over **Tailscale** (already installed, no port forwarding) | Turn on Tailscale on Mac and phone; import one Shortcut | **Recommended** |
| 2. *Run Script Over SSH* | Shortcut SSHes into the Mac and runs a command that hands the text to Jarvis. | Only if the command waits | Yes, over Tailscale | Enable Remote Login (needs admin), store an SSH key in Shortcuts | Works, but more setup and less safe |
| 3. iCloud relay | Shortcut writes the command to an iCloud Drive file; Jarvis watches the folder. | No | Yes | None | Fallback only: 5–60 s delay, no reply |
| 4. macOS App Intent ("Run Jarvis Command") | Native action in the Mac Shortcuts app. | n/a | No: the iPhone can't trigger Mac shortcuts directly | Small code change | Good for Mac-side automations (time of day, Focus), not for the phone |

Option 1 in practice: say **"Hey Siri, Jarvis"** on the phone → Siri asks "What's the command?" → "open my
GitHub notifications and summarize them" → the Mac runs it in Chrome → the phone speaks the summary.

Why option 1 over SSH: the command runs **inside the Jarvis app**, so it uses the permissions you already
granted (Chrome, System Events). A command started over SSH runs as a different process, and macOS can't show
its permission prompts remotely, so browser control would fail until someone allows it at the Mac.

### Design for the endpoint (option 1)

```
iPhone Shortcut ──HTTPS over Tailscale──▶ Jarvis :8777  POST /command  {"text": "..."}
  (Siri phrase)      Authorization: Bearer <token>          │
                                                            ▼
                                  same pipeline: meta → instant rules → Gemma → guardrails → executors
                                                            │
◀──────────────── {"heard", "action", "result", "spoken"} ──┘   console shows the source as PHONE
```

- **Bind only to `127.0.0.1` and the Tailscale address (100.x.y.z)**, never to all interfaces. Tailscale
  already encrypts and authenticates devices; the bearer token is a second lock.
- Token generated on first use; the menu gets a **"Set Up iPhone…"** item that shows the URL and token, and
  can export a ready-made Shortcut.
- Remote commands get a stricter allowlist by default: no `lock_screen`, no `quit_app`, and Claude
  hand-offs need confirmation, since nobody is at the Mac to stop a mis-heard command.
- Rate-limited, and every remote command is logged with its source.
- Also gives Mac-side Shortcuts and scripts a clean way in (`curl` / *Get Contents of URL*).

### Things to know before going mobile
- **The Mac must be awake.** In System Settings → Battery/Energy, prevent automatic sleep on power adapter,
  or Jarvis can keep the Mac awake while the phone bridge is on. Wake-on-network doesn't work reliably over Tailscale.
- Tailscale needs to be on (and signed in on the iPhone).
- **Firewall:** macOS may ask to allow incoming connections for Jarvis once; ad-hoc signed builds are asked
  again after rebuilds (the local signing certificate fixes this too). LuLu filters outgoing traffic, so it
  shouldn't block the phone.
- **Speech on the phone** comes from the iPhone's own dictation, so the wake word and mic aren't involved;
  the Mac's Gemma + executors do the rest.

### Suggested order
1. **`run_shortcut` action**: unlocks HomeKit, Focus and brightness from voice right away. Small change.
2. **Phone bridge** (endpoint + "Set Up iPhone…" + Shortcut template), with the remote allowlist.
3. **App Intent** for Mac-side Shortcuts automations, if you want time- or Focus-based triggers.

---

## 7. Proposal: a fully local screen and browser agent

### Why multi-step browser commands fail today
Every command becomes **one** action. "Open Chrome and route to LinkedIn notifications" runs `open_url` and
stops: Jarvis never looks at the page it opened, so there's no second step. Mis-heard speech ("how to Sydney")
makes it worse, because Gemma 2B guesses a single action instead of asking. Click / type / scroll also need
Chrome's *Allow JavaScript from Apple Events*.

### The fix: observe → decide → act, in a loop (the way Claude in Chrome works), all on the Mac

```
 goal: "open linkedin and go to my notifications"
   │
   ▼
┌──────────── OBSERVE ────────────┐   ┌──────── DECIDE ────────┐   ┌────────── ACT ──────────┐
│ DOM snapshot (primary)          │   │ local model, JSON out: │   │ click [7]               │
│  numbered interactive elements: │──▶│ {"click": 7}           │──▶│ type [3] "hello" ⏎      │
│  [7] link "Notifications"       │   │ {"type": 3, ...}       │   │ scroll, navigate, wait  │
│  [3] input "Search"   + URL     │   │ {"done": "answer"}     │   │ (or highlight only:     │
│ screenshot (when DOM isn't      │   │ max ~10 steps, asks    │   │  "show me" mode)        │
│  enough: canvas, images, charts)│   │ before send/post/buy   │   └───────────┬─────────────┘
└─────────────────────────────────┘   └────────────────────────┘               │
        ▲                                                                        │
        └──────────────────────── re-observe after each action ─────────────────┘
```

**Key design rule: the model never guesses pixel coordinates.** Small vision models are poor at that. The page
(or macOS) supplies exact element positions; the model only picks a number from the list ("set-of-marks").
The same numbers can be drawn on screen as badges, which gives you "route me" guidance: Jarvis highlights the
element and says "click Notifications, top right", or clicks it for you.

### Observing the whole Mac (not just the browser): "what's going on on my laptop?"
| Channel | What it gives | Speed (measured on this M4 where noted) |
|---|---|---|
| macOS Accessibility tree of the front app | Buttons, fields, menus with labels and exact screen frames | fast; needs Accessibility permission |
| Vision framework OCR on a screenshot | All visible text with boxes, fully on-device | **150–230 ms** for a full 2940×1912 screen (130 text regions) |
| Local vision model on a downscaled screenshot | A spoken summary: "You're in Gmail with 3 unread…", reads images and charts | a few seconds per screenshot (estimate; to be measured) |

Same loop as the browser: Accessibility/OCR elements get numbers, the model picks one, Jarvis highlights or clicks it
(real mouse clicks via `CGEvent`, which needs the Accessibility permission).

### Local models (16 GB M4)
| Role | Recommendation | Notes |
|---|---|---|
| Instant single commands | keep **gemma2:2b** + rules | ~1.4 s, already in place |
| Agent planning + screen understanding | **gemma3:4b** (one model for both: it accepts images) | ~3.3 GB; Gemma 2B is too weak for multi-step plans and can't see images |
| Stronger alternative | qwen2.5vl:7b or qwen3-vl (if available in Ollama) | better OCR and UI grounding, ~2× memory and slower |

Memory budget: gemma2:2b (1.6 GB) + gemma3:4b (~3.3 GB + image overhead) + Kokoro (~0.5 GB) fits comfortably;
the 4B model unloads when idle (`keep_alive`).

### Apple-native option (macOS 27): no Ollama, no downloads
Checked against the macOS 27 SDK on this Mac:
- **Vision framework**: on-device OCR with text boxes, measured at 150–230 ms per full screen. Works today.
- **Accessibility API**: buttons, fields and menus with exact frames for any app. Works today.
- **Foundation Models** (Apple's on-device Apple Intelligence model): in macOS 27 a prompt can include an
  **image** (`Attachment(cgImage)` / `Attachment(imageURL:)`), output can be forced into a Swift struct
  (guided generation, like Ollama's JSON schema), and the model can call **tools**, including ready-made
  `OCRTool` and `BarcodeReaderTool` from Vision. That covers command routing, the agent loop and
  "what's on my screen" with one built-in model running on the Neural Engine.
- Use **`SystemLanguageModel`** only. The SDK also has `PrivateCloudComputeLanguageModel`, which runs on
  Apple's servers and would break "fully local".
- Status on this Mac: `SystemLanguageModel.default.availability` = **`modelNotReady`** (Apple Intelligence is on,
  its model isn't ready yet), so speed and quality are untested here.
- Expected trade-offs: a small context window (DOM snapshots must stay compact), Apple's content guardrails, and
  it only runs on Apple Intelligence Macs. Keep Ollama as the fallback behind the same `Action` type.

### Getting at the browser page: three ways
| Transport | Pros | Cons |
|---|---|---|
| **AppleScript + injected JS** (today) | Your real Chrome profile and logins; nothing to install | Needs *Allow JavaScript from Apple Events*; no page screenshot (use window capture); synthetic clicks some sites ignore |
| **Local Chrome extension ↔ Jarvis (localhost WebSocket)** | How Claude in Chrome works: full DOM, page screenshots (`captureVisibleTab`), trusted clicks/typing via the debugger API, real profile, no Apple Events setting | One-time "Load unpacked" install of a small extension |
| **Playwright / DevTools protocol with a separate Chrome profile** | Most robust automation; ideal for scripted test runs | Separate profile (log in again); Chrome blocks this on your main profile |

### Privacy and safety
- Screenshots and page text stay in memory on the Mac; nothing is logged except the action taken.
- Password fields are never read or typed into by the agent; sensitive apps/sites (password managers, banking)
  can be on a skip list.
- Asks before anything irreversible: send, post, submit, buy, delete.
- macOS shows its screen-recording indicator whenever Jarvis captures the screen.

### Suggested order
1. **Browser agent loop** on the current AppleScript transport: numbered DOM snapshot, gemma3:4b planner,
   highlight + click, step cap and confirmations. Fixes "open LinkedIn and go to …".
2. **"What's on my screen"**: screenshot + OCR + Accessibility tree + gemma3:4b summary, with on-screen pointing.
3. **Chrome extension transport**: removes the Apple Events setting, adds page screenshots and trusted input.
