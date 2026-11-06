#!/bin/bash
# Jarvis prerequisite check: what this Mac already has, what the installer will download, and anything
# you need to do first. Changes nothing.
#
#   curl -fsSL https://raw.githubusercontent.com/prateekx8/jarvis/main/check.sh | bash
#
# or, from a clone:  ./check.sh      (install.sh runs it first, with the same options)
#
# Options:  --no-voice   plan without the natural voice
#           --no-ollama  plan without Ollama and Gemma
# Env:      JARVIS_SRC, JARVIS_APPS  as for install.sh
#
# Exit code: 0 ready to install, 1 something must be fixed first (listed at the end).
# Works with the bash that ships with macOS (3.2).

VOICE=1 OLLAMA=1
for arg in "$@"; do
  case "$arg" in
    --no-voice) VOICE=0 ;;
    --no-ollama) OLLAMA=0 ;;
    --yes|-y|--no-open) ;;  # install.sh options, accepted and ignored here
    -h|--help) sed -n '2,15p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)"; exit 2 ;;
  esac
done

SRC="${JARVIS_SRC:-$HOME/Jarvis}"
SUPPORT="$HOME/Library/Application Support/Jarvis"
TTS="$SUPPORT/tts"
MODEL="gemma2:2b"
OLLAMA_HOST="http://127.0.0.1:11434"

if [[ -t 1 ]]; then
  bold=$'\033[1m'; dim=$'\033[2m'; red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'; blue=$'\033[34m'; off=$'\033[0m'
else
  bold= dim= red= green= yellow= blue= off=
fi

DL_MB=0        # to download
DISK_MB=0      # disk space the install will use
PROBLEMS=()    # must be fixed before installing
ACTIONS=()     # things the person will be asked to do

section() { printf '\n%s%s%s\n' "$bold" "$*" "$off"; }
# row SYMBOL NAME DETAIL
row() {
  local sym color
  case "$1" in
    ok) sym="✓"; color="$green" ;;
    get) sym="↓"; color="$blue" ;;
    you) sym="!"; color="$yellow" ;;
    bad) sym="✗"; color="$red" ;;
    *) sym="–"; color="$dim" ;;
  esac
  printf '  %s%s%s %-27s %s\n' "$color" "$sym" "$off" "$2" "$3"
}
# plan DOWNLOAD_MB DISK_MB
plan() { DL_MB=$((DL_MB + $1)); DISK_MB=$((DISK_MB + $2)); }
reach() { curl -fsI -m 8 -o /dev/null "$1" 2>/dev/null || curl -fs -m 8 -o /dev/null -r 0-0 "$1" 2>/dev/null; }

printf '%sJarvis prerequisite check%s %s(changes nothing)%s\n' "$bold" "$off" "$dim" "$off"

# ---------------------------------------------------------------- this Mac
section "This Mac"
OS="$(sw_vers -productVersion 2>/dev/null)"
if [[ "$(uname -s)" != Darwin ]]; then
  row bad "macOS" "this isn't a Mac"; PROBLEMS+=("Jarvis runs on macOS only.")
elif (( ${OS%%.*} >= 14 )); then
  row ok "macOS" "$OS"
else
  row bad "macOS" "$OS (needs 14 Sonoma or newer)"; PROBLEMS+=("Update macOS to 14 (Sonoma) or newer.")
fi
case "$(uname -m)" in
  arm64) row ok "Processor" "Apple silicon" ;;
  x86_64) row ok "Processor" "Intel (works; the local models are slower)" ;;
  *) row bad "Processor" "$(uname -m) not supported"; PROBLEMS+=("Unsupported processor.") ;;
esac
MEM_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
if (( MEM_GB >= 8 )); then row ok "Memory" "${MEM_GB} GB"; else row you "Memory" "${MEM_GB} GB (8 GB+ recommended for Gemma)"; fi

APPS="${JARVIS_APPS:-/Applications}"
if [[ -w "$APPS" ]] || { [[ ! -e "$APPS" ]] && [[ -w "$(dirname "$APPS")" ]]; }; then
  row ok "Install location" "$APPS"
else
  APPS="$HOME/Applications"; row ok "Install location" "$APPS (no admin rights for /Applications)"
fi

# ---------------------------------------------------------------- build tools
section "Build tools"
if xcrun --find swift >/dev/null 2>&1 && xcrun --find git >/dev/null 2>&1; then
  row ok "Command Line Tools" "Swift $(swift --version 2>/dev/null | grep -oE 'version [0-9.]+' | head -1 | cut -d' ' -f2), git"
else
  row you "Command Line Tools" "missing · Apple's installer (~1-2 GB), one click, then re-run"
  ACTIONS+=("Click Install in the macOS Command Line Tools window, then run the installer again.")
  plan 1500 3000
fi

# ---------------------------------------------------------------- Jarvis
section "Jarvis"
HERE=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; fi
if [[ -n "$HERE" && -f "$HERE/app/Package.swift" ]]; then
  row ok "Source" "this checkout ($HERE)"
elif [[ -d "$SRC/.git" ]]; then
  row ok "Source" "$SRC (will update)"
else
  row get "Source" "clone to $SRC (~1 MB)"; plan 1 5
fi
plan 0 400  # build output
if [[ -d "$APPS/Jarvis.app" ]]; then
  row ok "Jarvis.app" "installed in $APPS (will be rebuilt from the latest source)"
else
  row get "Jarvis.app" "build and install (~1-2 min, no download)"
fi

# ---------------------------------------------------------------- voice
section "Natural voice (Kokoro)"
if (( VOICE )); then
  PY="$TTS/.venv/bin/python"
  if [[ -x "$PY" ]] && "$PY" -c "import kokoro_onnx" 2>/dev/null; then
    row ok "Voice engine" "private Python $("$PY" -c 'import sys; print(sys.version.split()[0])') + Kokoro"
  else
    if [[ -x "$SUPPORT/tools/uv" ]]; then row ok "uv" "$SUPPORT/tools/uv"; else row get "uv" "~14 MB (Python installer, no Homebrew)"; plan 14 40; fi
    row get "Voice engine" "private Python 3.12 + Kokoro (~70 MB download, ~200 MB on disk)"; plan 70 200
  fi
  for f in kokoro-v1.0.onnx:325 voices-v1.0.bin:28; do
    name="${f%%:*}"; mb="${f##*:}"
    if [[ -s "$TTS/models/$name" ]]; then row ok "$name" "downloaded"; else row get "$name" "~${mb} MB"; plan "$mb" "$mb"; fi
  done
else
  row skip "Natural voice" "skipped (--no-voice): Jarvis uses the macOS voice"
fi

# ---------------------------------------------------------------- Ollama
section "Offline answers (Ollama + $MODEL)"
OLLAMA_UP=0; curl -fs -m 2 "$OLLAMA_HOST/api/tags" >/dev/null 2>&1 && OLLAMA_UP=1
if (( OLLAMA )); then
  OLLAMA_APP=""
  for a in "/Applications/Ollama.app" "$HOME/Applications/Ollama.app"; do [[ -d "$a" ]] && OLLAMA_APP="$a" && break; done
  if (( OLLAMA_UP )); then row ok "Ollama" "running${OLLAMA_APP:+ ($OLLAMA_APP)}"
  elif [[ -n "$OLLAMA_APP" ]]; then row ok "Ollama" "installed ($OLLAMA_APP), will be started"
  else row get "Ollama" "official app, ~230 MB download"; plan 230 600; fi
  if (( OLLAMA_UP )) && curl -fs "$OLLAMA_HOST/api/tags" | grep -q "\"$MODEL\""; then
    row ok "$MODEL" "downloaded"
  elif (( ! OLLAMA_UP )) && [[ -d "$HOME/.ollama/models/manifests/registry.ollama.ai/library/${MODEL%%:*}/${MODEL##*:}" ]]; then
    row ok "$MODEL" "downloaded"
  else
    row get "$MODEL" "~1.6 GB"; plan 1630 1630
  fi
else
  row skip "Ollama + $MODEL" "skipped (--no-ollama): Claude or Apple's on-device model answers instead"
fi

# ---------------------------------------------------------------- optional
section "Optional (not installed by the script)"
if [[ -d "/Applications/Google Chrome.app" || -d "$HOME/Applications/Google Chrome.app" ]]; then
  row ok "Google Chrome" "for click / type / summarize on pages (Safari works too)"
else
  row skip "Google Chrome" "not found · Safari works (Develop → Allow JavaScript from Apple Events)"
fi
CLAUDE=""
for c in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude "$HOME/.claude/local/claude"; do [[ -x "$c" ]] && CLAUDE="$c" && break; done
if [[ -n "$CLAUDE" || -d /Applications/Claude.app ]]; then
  row ok "Claude" "online answers and multi-step tasks"
else
  row skip "Claude" "not found · install the Claude desktop app for online answers (offline works without it)"
fi
if [[ -d /Applications/Tailscale.app ]]; then row ok "Tailscale" "for the phone link"; else row skip "Tailscale" "not found · only needed to use Jarvis from your iPhone"; fi

# ---------------------------------------------------------------- network
section "Network"
need_net=0
(( DL_MB > 1 )) && need_net=1
if (( need_net )); then
  for site in https://github.com https://raw.githubusercontent.com https://pypi.org https://ollama.com https://registry.ollama.ai; do
    case "$site" in
      *pypi*) (( VOICE )) || continue ;;
      *ollama*) (( OLLAMA )) || continue ;;
    esac
    if reach "$site"; then row ok "${site#https://}" "reachable"; else row bad "${site#https://}" "not reachable"; PROBLEMS+=("Can't reach ${site#https://}: check the internet connection, VPN or firewall."); fi
  done
else
  row ok "Downloads" "nothing to download"
fi
FW=""
pgrep -qx LuLu 2>/dev/null && FW="LuLu"
pgrep -qf "Little Snitch" 2>/dev/null && FW="${FW:+$FW, }Little Snitch"
if [[ -n "$FW" ]] && (( need_net )); then
  row you "Firewall" "$FW running · allow uv, python and Ollama when it asks"
  ACTIONS+=("Allow uv, python and Ollama in $FW when it asks during the install.")
fi

# ---------------------------------------------------------------- disk + summary
section "Disk"
FREE_MB=$(( $(df -k "$HOME" | awk 'NR==2 {print $4}') / 1024 ))
NEED_MB=$((DISK_MB + 500))  # headroom
fmt() { if (( $1 >= 1024 )); then awk -v m="$1" 'BEGIN { printf "%.1f GB", m / 1024 }'; else echo "$1 MB"; fi; }
if (( FREE_MB >= NEED_MB )); then
  row ok "Free space" "$(fmt $FREE_MB) free, about $(fmt $NEED_MB) needed"
else
  row bad "Free space" "$(fmt $FREE_MB) free, about $(fmt $NEED_MB) needed"
  PROBLEMS+=("Free up $(fmt $((NEED_MB - FREE_MB))) of disk space (or use --no-ollama / --no-voice).")
fi

section "Summary"
echo "  Downloads: about $(fmt $DL_MB). Everything goes into $APPS and"
echo "  ~/Library/Application Support/Jarvis (nothing system-wide, no Homebrew, no sudo)."
echo "  On first launch Jarvis asks for Microphone, Speech Recognition and Automation: click Allow."
for a in "${ACTIONS[@]}"; do printf '  %s!%s %s\n' "$yellow" "$off" "$a"; done
if (( ${#PROBLEMS[@]} )); then
  printf '\n  %sFix first:%s\n' "$red" "$off"
  for p in "${PROBLEMS[@]}"; do printf '  %s✗%s %s\n' "$red" "$off" "$p"; done
  exit 1
fi
printf '\n  %sReady to install.%s\n' "$green" "$off"
exit 0
