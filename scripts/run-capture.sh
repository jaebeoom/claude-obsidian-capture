#!/bin/zsh
set -euo pipefail

export TZ=Asia/Seoul
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

DATE="${CAPTURE_DATE:-$(date +%Y-%m-%d)}"
VAULT_CAPTURE="${VAULT_CAPTURE:-/Users/nathan/Code/Atelier/Vault/Capture}"
CAPTURE_FILE="$VAULT_CAPTURE/$DATE.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRAPE_PROMPT_FILE="$SCRIPT_DIR/../prompts/capture-from-scrape-prompt.md"
APPEND_SCRIPT="$SCRIPT_DIR/append-candidates.sh"
BRAVE_COLLECT_SCRIPT="$SCRIPT_DIR/collect-claude-brave.py"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
BRAVE_BIN="${BRAVE_BIN:-/Applications/Brave Browser.app/Contents/MacOS/Brave Browser}"
BRAVE_PROFILE_DIR="${BRAVE_PROFILE_DIR:-$PROJECT_DIR/local/brave-claude-capture-profile}"
BRAVE_START_URL="${BRAVE_START_URL:-https://claude.ai/recents}"
BRAVE_KEEP_OPEN_ON_AUTH="${BRAVE_KEEP_OPEN_ON_AUTH:-}"
LOG_FILE="${CAPTURE_LOG_FILE:-$PROJECT_DIR/logs/capture.log}"
LOCK_DIR="${CAPTURE_LOCK_DIR:-$PROJECT_DIR/.claude-obsidian-capture.lock}"
TMP_OUTPUT="$(mktemp -t claude-obsidian-capture.XXXXXX)"
TMP_SOURCE="$(mktemp -t claude-obsidian-source.XXXXXX)"
TMP_EXISTING_IDS="$(mktemp -t claude-obsidian-existing.XXXXXX)"
LOCK_ACQUIRED=0

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG_FILE"
}

extract_session_ids() {
  local capture_file="$1"
  local line rest session_id

  [[ -f "$capture_file" ]] || return 0

  while IFS= read -r line; do
    if [[ "$line" == *capture:session-id=* ]]; then
      rest="${line#*capture:session-id=}"
      session_id="${rest%%[ >]*}"
      [[ -n "$session_id" ]] && printf '%s\n' "$session_id"
    fi
  done < "$capture_file"
}

extract_all_session_ids() {
  local capture_dir="$1"
  local capture_file

  [[ -d "$capture_dir" ]] || return 0

  for capture_file in "$capture_dir"/*.md(N); do
    extract_session_ids "$capture_file"
  done | sort -u
}

cleanup() {
  if [[ "$LOCK_ACQUIRED" -eq 1 ]]; then
    rm -rf "$LOCK_DIR"
  fi
  rm -f "$TMP_OUTPUT" "$TMP_SOURCE" "$TMP_EXISTING_IDS"
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

if ! EXISTING_SESSION_IDS="$(extract_all_session_ids "$VAULT_CAPTURE" 2>> "$LOG_FILE")"; then
  log "ERROR failed to read existing capture session ids from: $VAULT_CAPTURE"
  exit 1
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
  if [[ "$CLAUDE_BIN" == */* ]]; then
    if [[ ! -x "$CLAUDE_BIN" ]]; then
      log "ERROR claude CLI not executable: $CLAUDE_BIN"
      exit 1
    fi
  elif ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    log "ERROR claude CLI not found on PATH: $CLAUDE_BIN"
    exit 1
  fi

  printf '%s\n' "$EXISTING_SESSION_IDS" > "$TMP_EXISTING_IDS"

  if [[ ! -f "$SCRAPE_PROMPT_FILE" ]]; then
    log "ERROR scrape prompt file not found: $SCRAPE_PROMPT_FILE"
    exit 1
  fi

  if [[ -n "${CLAUDE_SCRAPE_OUTPUT_FILE:-}" ]]; then
    if [[ ! -f "$CLAUDE_SCRAPE_OUTPUT_FILE" ]]; then
      log "ERROR scraped Claude.ai fixture not found: $CLAUDE_SCRAPE_OUTPUT_FILE"
      exit 1
    fi
    log "INFO using scraped Claude.ai fixture: $CLAUDE_SCRAPE_OUTPUT_FILE"
    cp "$CLAUDE_SCRAPE_OUTPUT_FILE" "$TMP_SOURCE"
  else
    if ! command -v python3 >/dev/null 2>&1; then
      log "ERROR python3 not found on PATH"
      exit 1
    fi
    if [[ ! -f "$BRAVE_COLLECT_SCRIPT" ]]; then
      log "ERROR Brave collector script not found: $BRAVE_COLLECT_SCRIPT"
      exit 1
    fi

    typeset -a collect_args
    collect_args=(
      python3 -B "$BRAVE_COLLECT_SCRIPT"
      --date "$DATE"
      --output "$TMP_SOURCE"
      --log-file "$LOG_FILE"
      --existing-session-ids-file "$TMP_EXISTING_IDS"
      --brave-bin "$BRAVE_BIN"
      --profile-dir "$BRAVE_PROFILE_DIR"
      --start-url "$BRAVE_START_URL"
    )
    if [[ -n "$BRAVE_KEEP_OPEN_ON_AUTH" ]]; then
      collect_args+=(--keep-open-on-auth)
    fi

    set +e
    "${collect_args[@]}"
    collect_status=$?
    set -e
    if [[ "$collect_status" -ne 0 ]]; then
      log "ERROR dedicated Brave collection failed with status $collect_status"
      exit "$collect_status"
    fi
  fi

  if grep -Fxq 'NO_SOURCE_CONVERSATIONS' "$TMP_SOURCE"; then
    log "INFO no source Claude.ai conversations collected"
    log "INFO capture run finished for $DATE"
    exit 0
  fi

  PROMPT="$(cat "$SCRAPE_PROMPT_FILE")

---
Runtime context:
- KST date: $DATE
- Capture file path: $CAPTURE_FILE
- Existing capture session ids:
$EXISTING_SESSION_IDS

---
Scraped Claude.ai conversations:
$(cat "$TMP_SOURCE")
"

  typeset -a claude_args
  claude_args=(--print)

  if "$CLAUDE_BIN" "${claude_args[@]}" "$PROMPT" > "$TMP_OUTPUT" 2>> "$LOG_FILE"; then
    "$APPEND_SCRIPT" "$TMP_OUTPUT" "$CAPTURE_FILE" "$LOG_FILE"
    log "INFO capture run finished for $DATE"
  else
    exit_status=$?
    log "ERROR claude --print failed with status $exit_status"
    exit "$exit_status"
  fi
fi
