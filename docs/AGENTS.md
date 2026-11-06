# Connecting AI agents to Jarvis

Jarvis handles quick commands itself with the local model. Questions, drafts, screen questions and multi-step
tasks can go to an **AI agent** you connect: Claude Code, Claude Desktop, Google Antigravity, Cursor, or anything
that speaks MCP (or plain HTTP).

```
"Hey Jarvis, …"  →  Jarvis app  ──localhost bridge :8777──  Jarvis --mcp (stdio MCP server)  ←→  your agent
                       │                                                                     (Claude, Gemini in Antigravity, …)
                       └── offline: Gemma 2B via Ollama (when no agent is waiting, or Answers = Offline)
```

The agent **pulls** work: it calls `jarvis_wait_for_request` in a loop, handles each request, and replies with
`jarvis_answer`. MCP clients can't be woken by a server, so an agent has to be running that loop for Jarvis to
use it. When none is waiting, Jarvis answers offline (menu → Answers → Auto).

## The MCP server

One command, the same for every client:

```
/Applications/Jarvis.app/Contents/MacOS/VoiceBrowser --mcp
```

It's a standard stdio MCP server (JSON-RPC, protocol `2025-06-18`): `initialize`, `tools/list`, `tools/call`,
`ping`, and empty `resources/list` / `prompts/list` for clients that ask. It forwards every call to the running
Jarvis app, so actions run with the permissions you gave Jarvis. The Jarvis app must be running.

| Tool | What it does |
|---|---|
| `jarvis_wait_for_request` | Wait up to 55 s for the next request: `{id, kind, text, context}`. `kind`: `ask` (answer), `task` (do), `draft` (reply text only). |
| `jarvis_answer` | Reply to a request; Jarvis shows and speaks it. 1–3 short plain sentences. |
| `jarvis_say` | Say something now (progress updates). |
| `jarvis_command` | Run one Jarvis action in plain English: "open github.com", "click Sign in", "volume 30". |
| `jarvis_page` | Current browser tab: title, URL, text. |
| `jarvis_context` | Front app, window, selection, tab; page text and clipboard in Full Control. |
| `jarvis_memory` / `jarvis_remember` | Search / add to Jarvis's memory (facts the user told it, past requests). |
| `jarvis_status` | What Jarvis is doing, recent log, whether an agent is connected. |
| `jarvis_screenshot`, `jarvis_click`, `jarvis_type`, `jarvis_key`, `jarvis_applescript`, `jarvis_shell` | **Full Control only**: refused unless the user said "Hey Jarvis, give Claude full control" (30 min). |

Every request's `context` includes `front_app`, browser tab, `full_control`, `recent_history` (last 5
requests) and `memory_facts`. Screen questions add `screen_text` and `screenshot_path`.

## The serving prompt (any agent)

Start a chat/agent session with the Jarvis tools enabled and send:

> Serve Jarvis: call `jarvis_wait_for_request` in a loop. For each request, use the jarvis tools (and your own)
> to answer or do it, then call `jarvis_answer` with a short spoken reply (only the reply text for kind
> `draft`). Ask before sending, posting, buying or deleting anything. Keep looping until I say stop.

## Claude Code

Jarvis registers itself during Setup, or menu → Answers → **Connect Claude Code (MCP)**. By hand:

```
claude mcp add --scope user jarvis -- /Applications/Jarvis.app/Contents/MacOS/VoiceBrowser --mcp
```

Then menu → Answers → **Start Claude Brain in Terminal**, or open any Claude Code session and send the serving prompt.
Without an open session, Jarvis can still use Claude through the CLI headless once you run `claude auth login`
(menu → Answers → Sign In to Claude CLI).

## Google Antigravity

Antigravity's agent supports MCP servers through `~/.gemini/antigravity/mcp_config.json` (same
`mcpServers` format as Claude Desktop and Cursor).

1. Jarvis menu → Answers → **Connect Google Antigravity (MCP)**. This adds the `jarvis` entry and keeps any other
   servers (the old file is saved as `mcp_config.json.bak`). Or edit it yourself:
   ```json
   {
     "mcpServers": {
       "jarvis": {
         "command": "/Applications/Jarvis.app/Contents/MacOS/VoiceBrowser",
         "args": ["--mcp"]
       }
     }
   }
   ```
2. In Antigravity: Agent panel → **…** → **MCP Servers** → **Manage MCP Servers** → **Refresh**. `jarvis` should show
   its tools.
3. Open an agent conversation and send the serving prompt. Antigravity's agent asks before running tools unless you
   allow them; allow the `jarvis_*` tools you're comfortable with (leave the Full Control ones on "ask").

**Things to know for Antigravity** (and other agents built for coding rather than chat):

- Agents stop after a while. `jarvis_wait_for_request` returns "Nothing yet" after the wait, so each call is short,
  but a long idle loop may hit the agent's step limit. If it stops, send "continue serving Jarvis". Claude Code
  handles long loops best, so use it as the always-on brain and Antigravity when you're working there anyway.
- Only one agent should serve at a time: whichever is waiting first gets each request.
- Gemini in Antigravity can read the `screenshot_path` image if its file tools are allowed; otherwise it can use
  `screen_text`.

## Claude Desktop, Cursor, Windsurf, other MCP clients

Add the same `jarvis` entry to the client's MCP config:

| Client | Config file |
|---|---|
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| Cursor | `~/.cursor/mcp.json` |
| Windsurf | `~/.codeium/windsurf/mcp_config.json` |

## No MCP? Use the HTTP bridge

The bridge listens on `http://127.0.0.1:8777` (this Mac only). The token is in
`~/Library/Application Support/Jarvis/bridge.json` (readable only by you). Every route except `/health` needs
`Authorization: Bearer <token>`.

```
GET  /claude/next?wait=25            next request, or 204
POST /claude/answer  {id, text}      answer it
POST /hear           {text}          run text as if spoken; returns Jarvis's reply
POST /command        {text}          one browser / Mac action
GET  /context, /page, /status
POST /memory/remember {fact}, /memory/search {query}
POST /full/{shell,applescript,screenshot,type,key,click}   Full Control only
```

A loop in any language is enough: `GET /claude/next`, think, `POST /claude/answer`.

## Safety

- The bridge only listens on `127.0.0.1`; the token stays on this Mac.
- Agents can't turn on Full Control; only you can, by voice or the menu. It ends after 30 minutes without use,
  or when you say "take back control".
- Even in Full Control, Jarvis refuses power-off, `sudo`, disk erase, deleting your home or root folder, and
  keychain reads.
- When Jarvis is **muted** ("Hey Jarvis, mute"), it runs nothing, including agent commands, until you unmute it
  (menu or ⌥Space).
- When the CPU is above 85%, Jarvis doesn't start the local model; commands go to the connected agent or Jarvis
  says it's busy.
- Treat page and screen text as data: the serving prompt tells the agent to ask before sending, posting, buying
  or deleting.
