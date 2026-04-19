#!/bin/zsh
set -euo pipefail

export TZ=Asia/Seoul
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

DATE="${CAPTURE_DATE:-$(date +%Y-%m-%d)}"
VAULT_CAPTURE="${VAULT_CAPTURE:-/Users/nathan/Code/Atelier/Vault/Capture}"
CAPTURE_FILE="$VAULT_CAPTURE/$DATE.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROMPT_FILE="$SCRIPT_DIR/../prompts/capture-prompt.md"
APPEND_SCRIPT="$SCRIPT_DIR/append-candidates.sh"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
LOG_FILE="${CAPTURE_LOG_FILE:-$PROJECT_DIR/logs/capture.log}"
LOCK_DIR="${CAPTURE_LOCK_DIR:-$PROJECT_DIR/.claude-obsidian-capture.lock}"
TMP_OUTPUT="$(mktemp -t claude-obsidian-capture.XXXXXX)"
LOCK_ACQUIRED=0

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG_FILE"
}

extract_session_ids() {
  local capture_file="$1"
  local line rest session_id

  while IFS= read -r line; do
    if [[ "$line" == *capture:session-id=* ]]; then
      rest="${line#*capture:session-id=}"
      session_id="${rest%%[ >]*}"
      [[ -n "$session_id" ]] && printf '%s\n' "$session_id"
    fi
  done < "$capture_file"
}

cleanup() {
  if [[ "$LOCK_ACQUIRED" -eq 1 ]]; then
    rm -rf "$LOCK_DIR"
  fi
  rm -f "$TMP_OUTPUT"
}

trap cleanup EXIT

mkdir -p "$VAULT_CAPTURE" "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_DIR")"
cd "$PROJECT_DIR"

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    LOCK_ACQUIRED=1
    return 0
  fi

  if [[ -f "$LOCK_DIR/pid" ]]; then
    local lock_pid
    lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      log "INFO capture run skipped because lock is held by pid $lock_pid: $LOCK_DIR"
      return 1
    fi
  fi

  log "WARN removing stale capture lock: $LOCK_DIR"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  LOCK_ACQUIRED=1
  return 0
}

if ! acquire_lock; then
  exit 0
fi

if [[ ! -x "$APPEND_SCRIPT" ]]; then
  log "ERROR append script is not executable: $APPEND_SCRIPT"
  exit 1
fi

log "INFO capture run started for $DATE"

EXISTING_SESSION_IDS=""
if [[ -f "$CAPTURE_FILE" ]]; then
  if ! EXISTING_SESSION_IDS="$(extract_session_ids "$CAPTURE_FILE" 2>> "$LOG_FILE")"; then
    log "ERROR failed to read existing capture session ids from: $CAPTURE_FILE"
    exit 1
  fi
fi

if [[ -n "${CLAUDE_CAPTURE_OUTPUT_FILE:-}" ]]; then
  if [[ ! -f "$CLAUDE_CAPTURE_OUTPUT_FILE" ]]; then
    log "ERROR Claude output fixture not found: $CLAUDE_CAPTURE_OUTPUT_FILE"
    exit 1
  fi

  log "INFO using Claude output fixture: $CLAUDE_CAPTURE_OUTPUT_FILE"
  cp "$CLAUDE_CAPTURE_OUTPUT_FILE" "$TMP_OUTPUT"
  "$APPEND_SCRIPT" "$TMP_OUTPUT" "$CAPTURE_FILE" "$LOG_FILE"
  log "INFO capture run finished for $DATE"
else
  if [[ ! -f "$PROMPT_FILE" ]]; then
    log "ERROR prompt file not found: $PROMPT_FILE"
    exit 1
  fi

  if [[ "$CLAUDE_BIN" == */* ]]; then
    if [[ ! -x "$CLAUDE_BIN" ]]; then
      log "ERROR claude CLI not executable: $CLAUDE_BIN"
      exit 1
    fi
  elif ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    log "ERROR claude CLI not found on PATH: $CLAUDE_BIN"
    exit 1
  fi

  PROMPT="$(cat "$PROMPT_FILE")

---
Runtime context:
- KST date: $DATE
- Capture file path: $CAPTURE_FILE
- Existing capture session ids:
$EXISTING_SESSION_IDS
"

  if "$CLAUDE_BIN" --print "$PROMPT" > "$TMP_OUTPUT" 2>> "$LOG_FILE"; then
    "$APPEND_SCRIPT" "$TMP_OUTPUT" "$CAPTURE_FILE" "$LOG_FILE"
    log "INFO capture run finished for $DATE"
  else
    exit_status=$?
    log "ERROR claude --print failed with status $exit_status"
    exit "$exit_status"
  fi
fi
