#!/bin/bash
# Jarvis: one-command install for macOS 14+.
#
#   curl -fsSL https://raw.githubusercontent.com/prateekx8/jarvis/main/install.sh | bash
#
# or, from a clone:  ./install.sh
#
# It does everything the app needs, with no Homebrew and no system Python:
#   1. Apple's Command Line Tools (asks once, if missing) to build the app
#   2. downloads or updates the source, builds Jarvis.app, puts it in Applications
#   3. the natural voice: a private Python (via uv) + Kokoro + voice model (~340 MB),
#      all inside ~/Library/Application Support/Jarvis
#   4. Ollama + the offline model gemma2:2b (~1.6 GB) for offline answers
#   5. opens Jarvis; its setup window then only asks for the macOS permissions
#
# Options:  --no-voice   skip the natural voice (Jarvis uses the macOS voice)
#           --no-ollama  skip Ollama and Gemma (Jarvis answers with Claude or Apple's on-device model)
#           --no-open    don't open Jarvis at the end
# Env:      JARVIS_SRC   where to keep the source (default ~/Jarvis)
#           JARVIS_APPS  where to put Jarvis.app (default /Applications, or ~/Applications)
#
# Re-running is safe: finished steps are skipped and the app is rebuilt from the latest source.
set -euo pipefail

REPO="https://github.com/prateekx8/jarvis.git"
SRC="${JARVIS_SRC:-$HOME/Jarvis}"
SUPPORT="$HOME/Library/Application Support/Jarvis"
TTS="$SUPPORT/tts"
TOOLS="$SUPPORT/tools"
MODEL="gemma2:2b"
KOKORO_BASE="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
OLLAMA_URL="https://ollama.com/download/Ollama-darwin.zip"
OLLAMA_HOST="http://127.0.0.1:11434"

VOICE=1 OLLAMA=1 OPEN=1
for arg in "$@"; do
  case "$arg" in
    --no-voice) VOICE=0 ;;
    --no-ollama) OLLAMA=0 ;;
    --no-open) OPEN=0 ;;
    -h|--help) sed -n '2,21p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)"; exit 2 ;;
  esac
done

bold=$'\033[1m'; dim=$'\033[2m'; red=$'\033[31m'; green=$'\033[32m'; off=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$bold" "$*" "$off"; }
ok()   { printf '    %s✓%s %s\n' "$green" "$off" "$*"; }
note() { printf '    %s%s%s\n' "$dim" "$*" "$off"; }
die()  { printf '\n%sError:%s %s\n' "$red" "$off" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- checks
[[ "$(uname -s)" == Darwin ]] || die "Jarvis runs on macOS only."
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
(( MACOS_MAJOR >= 14 )) || die "Jarvis needs macOS 14 (Sonoma) or newer; this Mac has $(sw_vers -productVersion)."
case "$(uname -m)" in
  arm64) ARCH=aarch64 ;;
  x86_64) ARCH=x86_64 ;;
  *) die "Unsupported CPU: $(uname -m)" ;;
esac

need_gb=1; (( VOICE )) && need_gb=$((need_gb + 1)); (( OLLAMA )) && need_gb=$((need_gb + 2))
free_gb=$(( $(df -k "$HOME" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
if (( free_gb < need_gb )); then
  die "About ${need_gb} GB of free disk space is needed; only ${free_gb} GB is free. Free some space, or use --no-ollama / --no-voice."
fi

# Applications folder: /Applications when writable, else ~/Applications (no sudo).
APPS="${JARVIS_APPS:-/Applications}"
mkdir -p "$APPS" 2>/dev/null || true
[[ -w "$APPS" ]] || { APPS="$HOME/Applications"; mkdir -p "$APPS"; }

# ---------------------------------------------------------------- 1. build tools
step "Build tools"
if ! xcrun --find swift >/dev/null 2>&1 || ! xcrun --find git >/dev/null 2>&1; then
  note "Apple's Command Line Tools are needed to build Jarvis (one time, a few minutes)."
  xcode-select --install 2>/dev/null || true
  echo
  echo "    A macOS window asks to install the Command Line Tools. Click Install, wait for it to finish,"
  echo "    then run this installer again."
  exit 1
fi
ok "Swift $(swift --version 2>/dev/null | grep -oE 'version [0-9.]+' | head -1 | cut -d' ' -f2)"

# ---------------------------------------------------------------- 2. source + app
step "Jarvis app"
HERE=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [[ -n "$HERE" && -f "$HERE/app/Package.swift" ]]; then
  SRC="$HERE"
  note "Using this checkout: $SRC"
elif [[ -d "$SRC/.git" ]]; then
  note "Updating $SRC"
  git -C "$SRC" pull --ff-only --quiet || note "Couldn't update (local changes?); building what's there."
else
  note "Downloading source to $SRC"
  git clone --depth 1 --quiet "$REPO" "$SRC"
fi

note "Building (first build takes a minute or two)…"
LOG="$(mktemp -t jarvis-build)"
( cd "$SRC/app" && ./build.sh ) > "$LOG" 2>&1 || { tail -20 "$LOG"; die "Build failed (full log: $LOG)."; }
rm -f "$LOG"

# Quit the copy being replaced (only that one), so the new build starts cleanly.
RUNNING="$APPS/Jarvis.app/Contents/MacOS/VoiceBrowser"
if pgrep -f "$RUNNING" >/dev/null; then
  pkill -TERM -f "$RUNNING" 2>/dev/null || true
  sleep 1
fi
rm -rf "$APPS/Jarvis.app"
ditto "$SRC/app/build/Jarvis.app" "$APPS/Jarvis.app"
ok "Installed $APPS/Jarvis.app"

mkdir -p "$TTS" "$TOOLS"

# Download with resume and a progress bar; moves into place only when complete.
fetch() { # url dest
  curl -fL --retry 3 -C - --progress-bar -o "$2.part" "$1" && mv "$2.part" "$2"
}

# ---------------------------------------------------------------- 3. natural voice
if (( VOICE )); then
  step "Natural voice (Kokoro)"
  PY="$TTS/.venv/bin/python"
  if [[ -x "$PY" ]] && "$PY" -c "import kokoro_onnx" 2>/dev/null; then
    ok "Voice engine already installed"
  else
    UV="$TOOLS/uv"
    if [[ ! -x "$UV" ]]; then
      note "Getting uv (a small, self-contained Python installer)…"
      tmp="$(mktemp -d)"
      curl -fsSL "https://github.com/astral-sh/uv/releases/latest/download/uv-${ARCH}-apple-darwin.tar.gz" | tar -xz -C "$tmp"
      mv "$tmp/uv-${ARCH}-apple-darwin/uv" "$UV"
      rm -rf "$tmp"
    fi
    export UV_PYTHON_INSTALL_DIR="$SUPPORT/python" UV_CACHE_DIR="$SUPPORT/.uv-cache" UV_NO_CONFIG=1
    note "Installing a private Python and the voice engine (about a minute)…"
    rm -rf "$TTS/.venv"
    firewall="If a firewall such as LuLu or Little Snitch asked about uv or python, allow it and re-run (or use --no-voice)."
    "$UV" venv --quiet --python 3.12 --managed-python "$TTS/.venv" || die "Couldn't download Python. $firewall"
    "$UV" pip install --quiet --python "$PY" kokoro-onnx || die "Couldn't download the voice engine. $firewall"
    rm -rf "$UV_CACHE_DIR"
    "$PY" -c "import kokoro_onnx" || die "The voice engine didn't install. Re-run, or use --no-voice."
    ok "Voice engine installed"
  fi
  mkdir -p "$TTS/models"
  for f in kokoro-v1.0.onnx voices-v1.0.bin; do
    if [[ -s "$TTS/models/$f" ]]; then ok "$f"; else note "Downloading $f"; fetch "$KOKORO_BASE/$f" "$TTS/models/$f"; ok "$f"; fi
  done
else
  note "Skipping the natural voice (--no-voice): Jarvis uses the macOS voice."
fi

# ---------------------------------------------------------------- 4. Ollama + Gemma
ollama_up() { curl -fs -m 2 "$OLLAMA_HOST/api/tags" >/dev/null 2>&1; }
if (( OLLAMA )); then
  step "Offline answers (Ollama + $MODEL)"
  OLLAMA_APP=""
  for a in "/Applications/Ollama.app" "$HOME/Applications/Ollama.app"; do [[ -d "$a" ]] && OLLAMA_APP="$a" && break; done
  if ! ollama_up && [[ -z "$OLLAMA_APP" ]]; then
    note "Downloading Ollama…"
    tmp="$(mktemp -d)"
    fetch "$OLLAMA_URL" "$tmp/Ollama.zip"
    ditto -x -k "$tmp/Ollama.zip" "$APPS"
    rm -rf "$tmp"
    OLLAMA_APP="$APPS/Ollama.app"
    ok "Installed $OLLAMA_APP"
  fi
  if ! ollama_up; then
    note "Starting Ollama…"
    open -g "$OLLAMA_APP"
    for _ in $(seq 60); do ollama_up && break; sleep 1; done
    ollama_up || die "Ollama didn't start. Open it from Applications, then run this again (or use --no-ollama)."
  fi
  ok "Ollama running"
  if curl -fs "$OLLAMA_HOST/api/tags" | grep -q "\"$MODEL\""; then
    ok "$MODEL already downloaded"
  else
    CLI="$OLLAMA_APP/Contents/Resources/ollama"
    if [[ -x "$CLI" ]]; then
      "$CLI" pull "$MODEL"
    else
      note "Downloading $MODEL (~1.6 GB, no progress bar)…"
      curl -fs "$OLLAMA_HOST/api/pull" -d "{\"model\":\"$MODEL\",\"stream\":false}" >/dev/null
    fi
    curl -fs "$OLLAMA_HOST/api/tags" | grep -q "\"$MODEL\"" || die "$MODEL didn't download. Check the internet connection (or a firewall blocking Ollama), then re-run."
    ok "$MODEL downloaded"
  fi
else
  note "Skipping Ollama (--no-ollama)."
fi

# ---------------------------------------------------------------- 5. done
step "Done"
echo "    Jarvis is in $APPS. On first launch it asks for Microphone, Speech Recognition and"
echo "    Automation access: click Allow. Then say \"Hey Jarvis, open YouTube\" or hold ⌥Space and speak."
echo "    Re-run this installer any time to update."
(( OPEN )) && open "$APPS/Jarvis.app"
exit 0
