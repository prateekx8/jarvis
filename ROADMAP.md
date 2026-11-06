# Jarvis roadmap: what the cloud connection should add

Written 4 November 2026. Scope: features that need an online model or service (Claude first, others where
they are clearly better), and how to make that path fast, cheap, private and safe. Local-only work
(browser agent loop, OCR, Accessibility) is covered in [ARCHITECTURE.md §7](ARCHITECTURE.md) and only
mentioned here where the cloud path depends on it.

Ground rules this roadmap keeps:
- **Local first.** Wake word, speech recognition, instant rules, Gemma and Kokoro stay on the Mac. The cloud is
  called for things the Mac can't do well: reasoning over long context, drafting, research, connectors,
  work that continues while the Mac is asleep.
- **Every cloud feature has an offline answer**, even if that answer is "I'll do it when we're back online".
- **Safety lives in Swift, not in the prompt.** The model can ask for anything; the executor decides.

---

## 1. Summary: the next five things to build

1. **A direct, streaming Claude path for quick questions (Haiku 5.5 + prompt caching + pre-warm on wake word).**
   Today a cloud answer needs an open Claude Code session or a cold `claude -p`; a direct streamed call with a
   cached prefix is the single biggest latency win, and it makes "Auto" answers feel as quick as Gemma.
2. **Action tiers with spoken confirmation, enforced in the executor.** Draft-a-reply, Full Control and email
   connectors all let untrusted text steer real actions; a tier gate (read / reversible / external / never)
   has to exist before those features are safe to leave switched on.
3. **Personal memory as local files Claude can read and write.** "Remember I prefer window seats", "what did
   I ask you about yesterday?" Memory is what makes an assistant personal, and keeping it as plain files in
   Application Support keeps it private, editable and shared with the offline model.
4. **Morning briefing + calendar/mail/reminders, local data first.** Calendar and Reminders via EventKit (on
   the Mac), mail counts via Mail.app, Gmail/Google Calendar via Claude connectors when needed; Claude only
   writes the 30-second summary. This is the most-used feature of every assistant studied.
5. **Phone bridge with async jobs and push notifications.** The `/command` endpoint over Tailscale is already
   designed; adding job IDs and a "done" push lets long Claude tasks run on the Mac while you're away, with
   the result on your iPhone or Watch.

---

## 2. Prioritised feature table

Effort: **S** ≈ a day or two, **M** ≈ a week, **L** ≈ several weeks. Order = recommended build order.

| # | Feature | What it does for you | Cloud piece needed | Effort | Privacy / security notes |
|---|---|---|---|---|---|
| 1 | Fast cloud answers | "Hey Jarvis, why is the sky orange today?" answered in about a second, first sentence spoken while the rest streams | Claude Messages API, streaming, Haiku 5.5 default, prompt caching, pre-warm request on wake word | M | API key in Keychain; send only the question + small cached prefix; no screen/clipboard unless asked |
| 2 | Action tiers + confirmation | Jarvis reads back "Send to Alex: 'Running 10 min late'. Send?" before anything that leaves the Mac | None (local gate); model only proposes | M | The gate is the main defence against prompt injection; remote (phone) commands get a stricter tier table |
| 3 | Personal memory | Remembers preferences, people, ongoing projects; "what do you know about me?", "forget that" | Claude memory tool (client-side, files stay on the Mac) | M | Plain Markdown files, user-editable; secret-pattern filter before any write; never stores passwords/OTPs |
| 4 | Morning briefing | First wake of the day: calendar, travel time, reminders, unread from key people, one news line | Claude (summary), optional web search, optional Gmail/Calendar connector | M | Raw calendar/mail pulled locally; only the needed fields sent; briefing text cached locally |
| 5 | Phone bridge + async jobs | Ask from the iPhone/Watch, Mac does it, phone gets spoken reply or a push when done | Tailscale (already planned); push service (ntfy or Pushover) | M | Bind to 127.0.0.1 + Tailscale IP only; bearer token; push body says "done", details fetched over Tailscale |
| 6 | Draft-and-send replies | Extends "draft a reply": dictate tweaks ("shorter, warmer"), then send after confirmation | Claude Sonnet 5.5 for drafting | S | Email text is untrusted input; drafting never triggers other tools; send is tier 3 |
| 7 | Calendar + reminders by voice | "Move my 3 pm to Thursday", "remind me when I get home to call Mum" | Claude for parsing fuzzy requests only (Gemma for simple ones) | M | EventKit is local; edits confirmed by read-back |
| 8 | Web research answers | "Compare the M5 Air and the Air I have", spoken 3-line answer + full write-up in the console | Claude web search tool ($10 per 1,000 searches) or the Claude Code session | S | Searches are logged; result pages are untrusted text |
| 9 | Watchers | "Tell me when this page's price drops", "when the build finishes", "when Rahul replies" | Claude only to judge "meaningful change"; polling is local | M | Per-watcher expiry; notifications only, no actions without asking |
| 10 | Scheduled tasks | "Every Friday 5 pm, summarise my week's GitHub activity" | Local scheduler while the Mac is awake; Claude Code routines for Mac-asleep jobs | M | Cloud routines see only what their connectors allow; list and pause them by voice |
| 11 | Screen-aware help | "What's this error?", "explain this chart" with the screenshot or OCR text | Claude vision | S | OCR text first (smaller, redactable), screenshot only if needed; screen-recording indicator shows |
| 12 | Full Control tasks | Multi-step jobs across apps with screenshot/keyboard/mouse | Claude computer use (beta) via the MCP session | L | Time-boxed grant, allowlist not just blocklist, kill phrase, password/banking apps excluded |
| 13 | Conversation mode (speech-to-speech) | Natural back-and-forth with interruptions, for brainstorming or practice | OpenAI Realtime or Gemini Live, opt-in per session | L | Raw audio leaves the Mac only while this mode is on; wake word and commands stay local |
| 14 | Messages integration | "Read my unread iMessages from Mum", "reply 'on my way'" | Claude for summarise/draft only | M | Reading `chat.db` needs Full Disk Access: keep it an explicit opt-in; prefer Shortcuts' Messages actions |
| 15 | Apple App Intents | Siri, Shortcuts, Spotlight and Apple's new Siri can call Jarvis actions | None | S | Same tier gate applies to intent calls |

---

## 3. Design notes by theme

### 3.1 Latency and voice

**Where time goes today on a cloud question** (to be measured with the console's existing timings): end-of-speech
pause detection → transport to Claude (open MCP session, or a cold `claude -p` start) → model time-to-first-token →
Kokoro first sentence (~0.75 s). The middle two dominate.

**Add a third cloud transport: direct API.** Keep the two existing ones; each has a job.

| Transport | Best for | Why |
|---|---|---|
| Direct Messages API (new, `CloudBrain.swift`) | Quick questions, draft replies, briefings, "is this change meaningful?" | No process start, streaming, prompt caching, model choice per request |
| MCP session (`jarvis_wait_for_request`) | Long tasks that need Claude Code's tools, connectors (Gmail, Calendar, Drive), Full Control | Uses your subscription and connectors; already built |
| `claude -p` headless | Fallback when no session is open and no API key is set | Already built |

Routing rule in `App.run`: rules → Gemma picks an action or says "question/task" → questions go to the direct
API, tasks go to the MCP session (or headless). The user's "Claude, …" / "ask locally …" prefixes still override.

**Streaming into Kokoro.** Stream the response, cut at sentence boundaries (the voice already plays sentence by
sentence), and start speaking the first sentence while later ones arrive. Ask for a spoken-style answer in the
system prompt: first sentence answers the question, no lists, no markdown. Put the long version in the console.

**Pre-warm on wake word.** When "Hey Jarvis" fires, send a `max_tokens: 0` request with the cached prefix. The
prompt-caching docs describe this as reducing time-to-first-token on the next real request. The user is still
talking for 1–3 s, which is enough time for the cache to be warm. Skip it when the command turns out to be an
instant rule (the cost is one cache write, about 1.25× the prefix's input price).

**Speculative local answer.** For questions Gemma can probably answer ("capital of Australia"), start Gemma and
Claude in parallel; speak Gemma's answer if Claude hasn't produced a first sentence within ~1.2 s, and show
Claude's in the console when it lands. Never do this for actions, only answers.

**Filler, honestly.** If the first sentence isn't ready by ~1 s, play a short local cue ("One moment.") from
Kokoro's cache. It's cheaper than any optimisation and every voice assistant does it.

**Endpointing.** Faster end-of-turn detection saves as much as a faster model. Options, in order:
1. Tune the local pause timer by context: short (~500 ms) after a complete-sounding command, longer after
   "and…" or a rising question.
2. Start the cloud request on the partial transcript once it looks complete, and cancel it if more speech
   arrives. This is the same idea as Deepgram Flux's "EagerEndOfTurn"; Deepgram notes it raises LLM calls by
   50–70%, so only do it for the cheap Haiku path.
3. A cloud streaming recogniser (Deepgram Flux reports ~260 ms end-of-turn detection) would be faster, but
   sends raw audio off the Mac. Not recommended as a default; at most part of conversation mode.

**Conversation mode (speech-to-speech), later and opt-in.** OpenAI's Realtime API and Google's Gemini Live API
take audio in and give audio out from one model, which removes the STT → LLM → TTS hops and allows natural
interruption. Trade-offs for Jarvis: all audio goes to the provider while the mode is on; cost is per audio
token (secondary sources put gpt-realtime-2.1 at about $32/$64 per million audio tokens in/out, verify before
use); and Google's own docs say the half-cascade variant is more reliable with tool use than native audio. Design:
"Hey Jarvis, let's talk" opens a session with a visible console state and a time limit; the realtime model gets
the same small tool list as MCP (`command`, `page`, `context`) and every tool call still goes through the tier
gate; "that's all" closes the socket. Build it after items 1–5.

**Model choice per request** (Claude API, from the models overview):

| Job | Model | Notes |
|---|---|---|
| Quick spoken answers, routing, "meaningful change?" checks | Haiku 5.5 (fastest; from $0.10 / $0.50 per MTok) | Set effort low; cap `max_tokens` (~300) |
| Drafting replies, briefings, research summaries | Sonnet 5.5 ($2 / $10) | Good speed/quality balance |
| Long multi-step and computer-use tasks | Opus 5.5 through the Claude Code session | Already the MCP path |

### 3.2 Memory and personal context

**What to remember.** Three small stores in `~/Library/Application Support/Jarvis/memory/`:
- `profile.md`: stable facts and preferences ("prefers metric", "partner: Alex", "works on Creator Studio").
- `people.md`: names, how you refer to them, relationships, preferred channel.
- `journal/YYYY-MM-DD.md`: one-line summaries of the day's requests and outcomes (not transcripts).

**How Claude uses it.** Use Anthropic's memory tool. It is client-side: Claude asks to view/create/edit files
under `/memories`, and Jarvis executes those operations on the folder above. Reject any path outside it (the
docs call out path-traversal protection). `profile.md` and `people.md` are small and change rarely, so they go
into the cached system prefix; journals are only opened when asked ("what did I ask about yesterday?").

**Same files offline.** Gemma gets `profile.md` in its prompt too, so "remind me of my dentist's name" works
without the internet.

**Voice commands.** "Remember that …" (instant rule, writes directly), "what do you know about me?" (reads the
profile aloud), "forget …" (removes the line and confirms), menu → Open Memory Folder.

**Write filter.** Before any memory write, run the redaction pass (see §4): drop lines that look like
passwords, OTPs, card numbers, API keys or addresses you haven't explicitly asked it to store. Log every memory
write in the console as `MEMORY +` / `MEMORY −` so you see what it learned.

**Context on demand, not by default.** The richer context being added (front app, window title, selection, page
text, clipboard) should be a tool Claude calls (`jarvis_context`), not something attached to every request.
Attach automatically only the cheap, low-risk parts (front app name, window title). Selection and page text go
when the request refers to them ("this", "here", "the page", "selected"); the clipboard only when you say
"clipboard" or "what I copied".

### 3.3 Integrations

Prefer the local API when macOS has one; use a cloud connector when the data only lives in the cloud.

| Data | Local route (preferred) | Cloud route | Jarvis action |
|---|---|---|---|
| Calendar | EventKit (covers iCloud, Google, Exchange accounts added to Calendar.app) | Google Calendar connector in the Claude session | `calendar_query`, `calendar_add`, `calendar_move` |
| Reminders | EventKit | — | `reminder_add` (with time or location) |
| Mail | Mail.app via AppleScript (unread counts, front message) | Gmail connector for search across the whole mailbox | `mail_summary`, `draft_reply` (being added) |
| Messages | Shortcuts' Messages actions; `chat.db` only with explicit Full Disk Access opt-in | — | `messages_unread`, `message_send` (tier 3) |
| Contacts | Contacts framework | — | resolves "Mum", "Alex" for other actions |
| Home, Focus, brightness | `shortcuts run` (ARCHITECTURE §6A) | — | `run_shortcut` |
| Web | Chrome via AppleScript | Claude web search tool, or the Claude Code session | `research` |
| Files | Spotlight (`mdfind`) | Drive connector | `find_file` |

Notes:
- Claude Code supports the claude.ai connectors (Gmail, Google Calendar and others) since early 2026, so the MCP
  session path gets them without Jarvis holding Google tokens. That is the right place for "search my email for
  the Goa booking". The direct API path should not get connector access; it stays a fast, low-privilege path.
- Calendar event descriptions and emails can carry injected instructions (the Classmethod write-up shows this with
  the Calendar connector). Anything read from them is marked untrusted (§3.6) and can't trigger a tier-3 action
  without your spoken yes.
- Expose Jarvis actions as **App Intents** so Siri, Shortcuts and Spotlight can call them. Apple's rebuilt Siri
  (announced at WWDC 2026, in beta since September per press reports) uses App Intents for app actions, so this
  makes Jarvis reachable from Siri on the Mac and via Shortcuts on the Watch.

### 3.4 Proactive features and automation

Lesson from the market: OpenAI retired ChatGPT Pulse and folded daily briefings into Scheduled Tasks, saying
proactive features work best when they are personalised, action-oriented and under user control. So: Jarvis
never speaks unprompted except at times you set, and every proactive item can be listed and stopped by voice.

**Morning briefing (build first).**
- Trigger: the first unlock or first "Hey Jarvis" after 6 am, or a fixed time; menu toggle.
- Gather locally (no cloud): today's events and travel gaps (EventKit), due reminders, unread counts by sender
  from Mail.app, battery, weather (Shortcuts' weather action or WeatherKit).
- One Claude call (Sonnet 5.5) turns that JSON into ~30 seconds of speech plus a fuller console version. Optional
  one web search for news on topics in `profile.md`.
- Pre-compute at 5:55 so it plays instantly; offline fallback is the same data read by a local template.

**Watchers.** "Tell me when …" creates a watcher with a check (page text selector, file, process, mail sender), an
interval and an expiry (default 24 h). Checks run locally; only when something changed does Haiku answer
"is this the change the user cares about? yes/no + one line". Output is a spoken line or a push, never an action.

**Scheduled tasks.**
- Mac awake: an in-app scheduler (store tasks in Application Support, run them through the normal pipeline as if
  spoken, source `SCHEDULE` in the log).
- Mac asleep or away: Claude Code **routines** run on Anthropic's cloud on a schedule or via an HTTP trigger
  (research preview, Pro/Max). Use them for things that don't need the Mac (weekly GitHub summary, price checks),
  and have them push the result to your phone. Desktop scheduled tasks only run while the Mac is awake.
- "What's scheduled?", "pause the Friday summary" as voice commands.

### 3.5 Mobile (iPhone, Watch)

Builds on the phone bridge design in ARCHITECTURE §6B.

- **Sync replies** (short): iPhone Shortcut → `POST /command` over Tailscale → spoken reply. Unchanged.
- **Async jobs** (long Claude tasks): `/command` returns `{"job": id, "spoken": "Working on it"}` within a second;
  the Mac runs the task; when it finishes Jarvis sends a push. `GET /job/{id}` (over Tailscale) returns the full
  result, which a second Shortcut reads aloud.
- **Push channel.** ntfy is simple (one HTTP POST), but on iOS delivery goes through Apple's push service via the
  ntfy.sh relay, so message text passes through a third party even with a self-hosted server. Pushover is similar.
  Either way: the push body says only "Jarvis: task done" or "Jarvis needs a yes/no"; details are fetched over
  Tailscale.
- **Confirmations from the phone.** A tier-3 action requested remotely pauses and sends "Send reply to Alex?"; the
  phone Shortcut shows Yes/No and calls `POST /job/{id}/confirm`. No confirmation within 10 minutes = cancelled.
- **Watch.** The same Shortcut runs on the Watch ("Hey Siri, Jarvis"). Keep the spoken reply to one sentence.
- **Mac asleep.** Remote commands fail fast with "Mac is asleep"; the Shortcut can then fall back to a Claude
  routine's HTTP trigger for cloud-only tasks.

### 3.6 Safety

Anthropic's own browser-agent research reports that even with its newest defences about 1% of prompt-injection
attempts still succeed, and that no browser agent is immune. Jarvis reads email, pages and screens, so it must
assume some instructions in that content will get through the model. The defences therefore sit in the executor.

**Action tiers** (one table in Swift, checked in the executor for every action, whatever the source):

| Tier | Examples | Rule |
|---|---|---|
| 0 Read | time, battery, page text, calendar read, screenshot for a question | Run |
| 1 Local, reversible | open/quit app, volume, tabs, scroll, dark mode, reminders add | Run; log |
| 2 Local, harder to undo | type into a field, click a button in a web form, move a calendar event, write a file | Run in the foreground session; confirm when the request came from untrusted content or the phone |
| 3 Leaves the Mac or can't be undone | send mail/message, post, submit, purchase, delete, shell commands that write, AppleScript to other apps | Always spoken read-back + "yes"; console shows a Confirm button; phone gets a push |
| 4 Never | passwords and password managers, banking apps, System Settings security panes, `sudo`, shut down, disabling Jarvis's own safety | Refused, with the reason spoken |

Details:
- **Provenance.** Every piece of text sent to the model is tagged `user_said` (from speech) or `observed` (page,
  email, screen, clipboard, tool result). Wrap observed text in clear delimiters and tell the model it is data.
  More importantly, if a tier-2/3 action was proposed in a turn that contained observed text, the executor
  requires confirmation even when the user's original request would have allowed it.
- **Full Control is time-boxed.** "Full control for 10 minutes" grants it; the console shows a red ring and a
  countdown; "Jarvis stop" (an instant rule checked before everything else) revokes it and cancels the running
  task. Replace the shell blocklist with an allowlist of command prefixes plus the blocklist as a second check:
  blocklists of shell syntax are easy to get around.
- **Least privilege per path.** The direct API path gets no tools beyond `context` and answer text. The MCP
  session gets `jarvis_command` (tier-gated). Only an explicit Full Control grant adds keyboard/mouse/shell.
- **MCP hygiene.** The MCP spec says tool descriptions from untrusted servers are untrusted and that consent must be
  handled by the implementer. Keep Jarvis's MCP server local (stdio), and review the other servers registered in
  the same Claude session: a poisoned tool description elsewhere can steer calls to `jarvis_command`.
- **Bridge.** Keep the token file mode 600, rotate from the menu, rate-limit, log the source (`LOCAL`, `MCP`,
  `PHONE`, `SCHEDULE`) of every command.
- **Audit log.** Every tier-2+ action: time, source, the exact action JSON, who confirmed. Viewable by voice
  ("what did you do today?").

---

## 4. Optimisation checklist for the cloud path

**Latency**
- [ ] Direct streaming API call for questions; first sentence spoken as soon as it ends.
- [ ] Stable prefix first (system prompt, tool definitions, `profile.md`), volatile context last, so it caches.
  Haiku 5.5 needs at least 512 tokens in the cached prefix; check `cache_read_input_tokens` > 0 in the log.
- [ ] Pre-warm the cache (`max_tokens: 0`) when the wake word fires; use the 1-hour TTL if you use Jarvis less
  than every 5 minutes but more than hourly.
- [ ] Haiku 5.5 with low effort and a small `max_tokens` for spoken answers; Sonnet only for drafting.
- [ ] `eager_input_streaming` on tools with long arguments (drafts) so text arrives without buffering.
- [ ] Keep one HTTP/2 connection to the API open (URLSession reuse) to skip TLS setup.
- [ ] Gemma in parallel for answerable questions; local filler cue after ~1 s.
- [ ] Log per stage: `END-OF-SPEECH → CLOUD-TTFT → FIRST-AUDIO`, and track p50/p95 in the console.

**Cost**
- [ ] Daily spend cap in settings (default e.g. $1/day); when hit, Auto answers fall back to Gemma and say so.
- [ ] Cache reads are 0.1× input price on Haiku-class models; a typical spoken Q&A with a cached prefix should cost a
  fraction of a cent. Show today's spend in the menu.
- [ ] `max_uses` on the web search tool (1–3 per request); searches are $10 per 1,000.
- [ ] Batch API (50% off) for non-urgent work: nightly journal summaries, weekly reviews.
- [ ] Don't send screenshots when OCR text answers the question.

**Privacy**
- [ ] Wake word, STT, instant rules and TTS never leave the Mac (conversation mode is the only exception, opt-in).
- [ ] Redaction pass before any cloud call and memory write: card numbers (Luhn check), OTP-looking codes near
  "code"/"OTP", API-key patterns, passwords from password fields (never read in the first place).
- [ ] Clipboard and selection only when the request refers to them.
- [ ] Excluded apps list (1Password, banking, Health) for screenshots and context.
- [ ] A "Private mode" voice toggle: cloud off until turned back on; console shows it.
- [ ] Memory is plain files you can read, edit and delete.

**Reliability**
- [ ] Health check (`/health` plus a cheap API ping) drives an "online/offline" badge in the console.
- [ ] Timeouts: no first token in 4 s → cancel and answer with Gemma, prefixed "Offline answer:".
- [ ] Circuit breaker: three failures in a row → offline for 2 minutes, then retry.
- [ ] Cloud-only tasks while offline are queued and run when back online, with a notification.
- [ ] Retries with backoff on 429/529; never retry tier-3 actions automatically.
- [ ] Pin model IDs (dateless IDs are pinned snapshots) and re-run the `--parse`/`--do` test set before switching.

**Security**
- [ ] Tier gate in the executor for every source (voice, MCP, phone, schedule, Full Control).
- [ ] Observed text tagged and delimited; confirmation forced when observed text was in the turn.
- [ ] Full Control time-boxed with kill phrase; shell allowlist.
- [ ] API key in Keychain; bridge token 600 and rotatable; bridge bound to 127.0.0.1 and the Tailscale IP only.
- [ ] Memory tool paths confined to the memory folder.
- [ ] Audit log of tier-2+ actions.

---

## 5. What the other assistants do (and what to borrow)

| Assistant | Notable features | Borrow for Jarvis |
|---|---|---|
| Apple Siri (Apple Intelligence, 2026) | Personal context across Mail, Messages, Calendar, Notes; on-screen awareness; app actions via App Intents | App Intents for Jarvis actions; local-first personal context |
| Google Gemini (Live, in Chrome) | Low-latency native-audio conversation; Chrome sidebar that reads Gmail/Calendar ("Connected Apps") and runs multi-step browsing | Conversation mode later; connectors only through an explicit setting |
| ChatGPT | Voice mode; agent; Scheduled Tasks (replacing Pulse) for briefings and "notify me if this changes" | Briefing + watchers under user control |
| Amazon Alexa+ | Agentic actions across partner services (bookings, orders), web navigation | Confirmation before anything that spends money |
| OpenClaw (open source, self-hosted) | Chat-app front ends (iMessage, WhatsApp, Telegram), memory, scheduled tasks, skills, shell and file access; advises starting read-only | Phone access via a channel you already use; start with low privileges |

---

## 6. Sources

Claude / Anthropic
- Models overview (IDs, prices, relative latency): https://platform.claude.com/docs/en/about-claude/models/overview
- Prompt caching (TTLs, prices, minimum lengths, pre-warming): https://platform.claude.com/docs/en/docs/build-with-claude/prompt-caching
- Memory tool (client-side memory files): https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool
- Fine-grained tool streaming: https://platform.claude.com/docs/en/docs/agents-and-tools/tool-use/fine-grained-tool-streaming
- Computer use tool: https://platform.claude.com/docs/en/build-with-claude/computer-use
- Pricing (web search $10 / 1,000, batch discount): https://platform.claude.com/docs/en/about-claude/pricing
- Claude Code scheduled tasks and routines: https://code.claude.com/docs/en/scheduled-tasks
- Mitigating prompt injection in browser use: https://www.anthropic.com/research/prompt-injection-defenses
- Claude for Chrome launch (permissions, confirmations): https://www.anthropic.com/news/claude-for-chrome
- Claude Code + Google Calendar connector, with injection warning (Classmethod): https://dev.classmethod.jp/articles/claude-code-google-calendar-connector/

Voice and realtime
- Gemini Live API (Vertex AI overview): https://docs.cloud.google.com/vertex-ai/generative-ai/docs/live-api
- Gemini Live API (Gemini API): https://ai.google.dev/api/multimodal-live
- OpenAI gpt-realtime-2.1 pricing (secondary source, verify on OpenAI's pricing page): https://datanorth.ai/news/openai-releases-gpt-realtime-2-1-voice-models
- Deepgram Flux (end-of-turn detection, EagerEndOfTurn): https://developers.deepgram.com/docs/flux/quickstart

Assistants
- ChatGPT Pulse retirement note: https://help.openai.com/en/articles/12293630-chatgpt-pulse
- ChatGPT Tasks: https://help.openai.com/en/articles/10291617-tasks-in-chatgpt
- Apple Siri AI at WWDC 2026 (press): https://www.iphoneincanada.ca/2026/06/08/wwdc-apple-unveils-siri-ai-with-personal-context-and-app-actions/
- Siri AI beta rollout (press): https://www.iclarified.com/102225/apple-launches-siri-ai-beta-with-personal-context-onscreen-awareness-and-app-actions
- Gemini in Chrome agentic browsing (TechCrunch): https://techcrunch.com/2025/09/18/google-brings-gemini-in-chrome-to-us-users-unveils-agentic-browsing-capabilities-and-more/
- Gemini Personal Intelligence in Chrome (Android Authority): https://www.androidauthority.com/google-chrome-agent-gemini-personal-intelligence-3635848
- Alexa+ agentic features (MediaPost): https://www.mediapost.com/publications/article/403746/alexa-gets-agentic-smarter-more-conversational.html
- OpenClaw overview (MacStories): https://www.macstories.net/stories/clawdbot-showed-me-what-the-future-of-personal-ai-assistants-looks-like/

Security and notifications
- MCP specification (security and trust sections): https://modelcontextprotocol.io/specification/2025-06-18/index.md
- Protecting against indirect injection in MCP (Microsoft): https://developer.microsoft.com/blog/protecting-against-indirect-injection-attacks-mcp/
- MCP prompt injection problems (Simon Willison): https://simonw.substack.com/p/model-context-protocol-has-prompt
- ntfy configuration (iOS delivery via upstream relay): https://docs.ntfy.sh/config/

Notes on confidence: Claude model, caching, memory-tool and pricing details come from Anthropic's docs. OpenAI
Realtime prices, Siri AI timelines, Alexa+ and OpenClaw details come from press or secondary sources and should be
checked before relying on exact figures. Latency figures for Jarvis's own stages are not measured yet; the first
task in item 1 is to add per-stage timing to the log.
