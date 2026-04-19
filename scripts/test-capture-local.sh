#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d -t claude-obsidian-capture-test.XXXXXX)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local text="$2"

  grep -Fq "$text" "$file" || fail "expected $file to contain: $text"
}

assert_file_not_exists() {
  local file="$1"

  [[ ! -e "$file" ]] || fail "expected file not to exist: $file"
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [[ "$expected" == "$actual" ]] || fail "$label expected=$expected actual=$actual"
}

count_fixed() {
  local file="$1"
  local text="$2"

  awk -v text="$text" 'index($0, text) { count += 1 } END { print count + 0 }' "$file"
}

count_markers() {
  local file="$1"

  awk '/capture:item-(start|end)/ { count += 1 } END { print count + 0 }' "$file"
}

APPEND_OUTPUT="$TMP_DIR/append-output.md"
APPEND_CAPTURE="$TMP_DIR/append-capture.md"
APPEND_LOG="$TMP_DIR/append.log"

cat > "$APPEND_CAPTURE" <<'EOF'
## AI 세션 (09:00, claude.ai claude-opus-4-7)
<!-- capture:session-id=claude.ai:existing -->

**나**: 기존

**AI**: 기존

#stage/capture #from/claude-ai
EOF

cat > "$APPEND_OUTPUT" <<'EOF'
<!-- capture:item-start -->
## AI 세션 (10:00, claude.ai claude-opus-4-7)
<!-- source: claude.ai Obsidian Capture Source -->
<!-- capture:session-id=claude.ai:existing -->

**나**: 중복

**AI**: 중복

#stage/capture #from/claude-ai
<!-- capture:item-end -->
<!-- capture:item-start -->
## AI 세션 (11:00, claude.ai claude-opus-4-7)
<!-- source: claude.ai Obsidian Capture Source -->
<!-- capture:session-id=claude.ai:new -->

**나**: 신규

**AI**: 신규

#stage/capture #from/claude-ai
<!-- capture:item-end -->
<!-- capture:item-start -->
## AI 세션 (12:00, claude.ai claude-opus-4-7)

**나**: 세션 없음

**AI**: 세션 없음

#stage/capture #from/claude-ai
<!-- capture:item-end -->
EOF

"$SCRIPT_DIR/append-candidates.sh" "$APPEND_OUTPUT" "$APPEND_CAPTURE" "$APPEND_LOG"

assert_equals "1" "$(count_fixed "$APPEND_CAPTURE" "capture:session-id=claude.ai:existing")" "existing session count"
assert_equals "1" "$(count_fixed "$APPEND_CAPTURE" "capture:session-id=claude.ai:new")" "new session count"
assert_equals "0" "$(count_markers "$APPEND_CAPTURE")" "capture marker count"
assert_file_contains "$APPEND_LOG" "INFO skipped duplicate capture candidate: claude.ai:existing"
assert_file_contains "$APPEND_LOG" "WARN skipped capture candidate without session-id"

NO_CAPTURE_OUTPUT="$TMP_DIR/no-capture-output.md"
NO_CAPTURE_FILE="$TMP_DIR/no-capture.md"
NO_CAPTURE_LOG="$TMP_DIR/no-capture.log"

printf 'NO_CAPTURE_CANDIDATES\n' > "$NO_CAPTURE_OUTPUT"
"$SCRIPT_DIR/append-candidates.sh" "$NO_CAPTURE_OUTPUT" "$NO_CAPTURE_FILE" "$NO_CAPTURE_LOG"

assert_file_not_exists "$NO_CAPTURE_FILE"
assert_file_contains "$NO_CAPTURE_LOG" "INFO no capture candidates reported by Claude"

RUN_OUTPUT="$TMP_DIR/run-output.md"
RUN_VAULT="$TMP_DIR/vault"
RUN_LOG="$TMP_DIR/run.log"
RUN_LOCK="$TMP_DIR/run.lock"
RUN_CAPTURE="$RUN_VAULT/2099-01-02.md"

cat > "$RUN_OUTPUT" <<'EOF'
<!-- capture:item-start -->
## AI 세션 (22:00, claude.ai claude-opus-4-7)
<!-- source: claude.ai Obsidian Capture Source -->
<!-- capture:session-id=claude.ai:run-new -->

**나**: run fixture

**AI**: run fixture

#stage/capture #from/claude-ai
<!-- capture:item-end -->
EOF

CAPTURE_DATE="2099-01-02" \
VAULT_CAPTURE="$RUN_VAULT" \
CAPTURE_LOG_FILE="$RUN_LOG" \
CAPTURE_LOCK_DIR="$RUN_LOCK" \
CLAUDE_CAPTURE_OUTPUT_FILE="$RUN_OUTPUT" \
"$SCRIPT_DIR/run-capture.sh"

assert_file_contains "$RUN_CAPTURE" "capture:session-id=claude.ai:run-new"
assert_equals "0" "$(count_markers "$RUN_CAPTURE")" "run capture marker count"

CAPTURE_DATE="2099-01-02" \
VAULT_CAPTURE="$RUN_VAULT" \
CAPTURE_LOG_FILE="$RUN_LOG" \
CAPTURE_LOCK_DIR="$RUN_LOCK" \
CLAUDE_CAPTURE_OUTPUT_FILE="$RUN_OUTPUT" \
"$SCRIPT_DIR/run-capture.sh"

assert_equals "1" "$(count_fixed "$RUN_CAPTURE" "capture:session-id=claude.ai:run-new")" "run duplicate session count"
assert_file_contains "$RUN_LOG" "INFO skipped duplicate capture candidate: claude.ai:run-new"

FAKE_CLAUDE="$TMP_DIR/fake-claude"
FAKE_LOG="$TMP_DIR/fake.log"
FAKE_VAULT="$TMP_DIR/fake-vault"
FAKE_LOCK="$TMP_DIR/fake.lock"

cat > "$FAKE_CLAUDE" <<'EOF'
#!/bin/zsh
exit 42
EOF
chmod +x "$FAKE_CLAUDE"

set +e
CAPTURE_DATE="2099-01-03" \
VAULT_CAPTURE="$FAKE_VAULT" \
CAPTURE_LOG_FILE="$FAKE_LOG" \
CAPTURE_LOCK_DIR="$FAKE_LOCK" \
CLAUDE_BIN="$FAKE_CLAUDE" \
"$SCRIPT_DIR/run-capture.sh"
fake_status=$?
set -e

assert_equals "42" "$fake_status" "fake claude failure status"
assert_file_contains "$FAKE_LOG" "ERROR claude --print failed with status 42"

printf 'OK local capture tests passed\n'
