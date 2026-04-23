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

  grep -Fq -- "$text" "$file" || fail "expected $file to contain: $text"
}

assert_file_not_contains() {
  local file="$1"
  local text="$2"

  if grep -Fq -- "$text" "$file"; then
    fail "expected $file to not contain: $text"
  fi
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
<!-- source: claude.ai recent conversations -->
<!-- capture:session-id=claude.ai:existing -->

**나**: 중복

**AI**: 중복

#stage/capture #from/claude-ai
<!-- capture:item-end -->
<!-- capture:item-start -->
## AI 세션 (11:00, claude.ai claude-opus-4-7)
<!-- source: claude.ai recent conversations -->
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

MIXED_NO_CAPTURE_OUTPUT="$TMP_DIR/mixed-no-capture-output.md"
MIXED_NO_CAPTURE_FILE="$TMP_DIR/mixed-no-capture.md"
MIXED_NO_CAPTURE_LOG="$TMP_DIR/mixed-no-capture.log"

cat > "$MIXED_NO_CAPTURE_OUTPUT" <<'EOF'
Tab close capability was unavailable, so the automation tab remains open.

NO_CAPTURE_CANDIDATES
EOF

"$SCRIPT_DIR/append-candidates.sh" "$MIXED_NO_CAPTURE_OUTPUT" "$MIXED_NO_CAPTURE_FILE" "$MIXED_NO_CAPTURE_LOG"

assert_file_not_exists "$MIXED_NO_CAPTURE_FILE"
assert_file_contains "$MIXED_NO_CAPTURE_LOG" "WARN Claude output mixed NO_CAPTURE_CANDIDATES with additional text"
assert_file_contains "$MIXED_NO_CAPTURE_LOG" "WARN Claude output first non-empty line: Tab close capability was unavailable, so the automation tab remains open."
assert_file_contains "$MIXED_NO_CAPTURE_LOG" "INFO no capture candidates reported by Claude"

PERMISSION_OUTPUT="$TMP_DIR/permission-output.md"
PERMISSION_FILE="$TMP_DIR/permission-capture.md"
PERMISSION_LOG="$TMP_DIR/permission.log"

cat > "$PERMISSION_OUTPUT" <<'EOF'
Bash 명령이 승인 없이 실행될 수 없는 상태입니다. Chrome 브라우저 자동화를 위한 AppleScript 실행이 차단되고 있습니다. `claude --print` 자동 실행 컨텍스트에서는 `--dangerouslySkipPermissions` 플래그가 필요합니다.

현재 컨텍스트에서는 Claude.ai에 접근할 수 없으므로:

NO_CAPTURE_CANDIDATES
EOF

"$SCRIPT_DIR/append-candidates.sh" "$PERMISSION_OUTPUT" "$PERMISSION_FILE" "$PERMISSION_LOG"

assert_file_not_exists "$PERMISSION_FILE"
assert_file_contains "$PERMISSION_LOG" "ERROR Claude capture automation was blocked by permission requirements"
assert_file_contains "$PERMISSION_LOG" "WARN Claude output first non-empty line: Bash 명령이 승인 없이 실행될 수 없는 상태입니다."
assert_file_contains "$PERMISSION_LOG" "INFO no complete capture candidate blocks found"

RUN_OUTPUT="$TMP_DIR/run-output.md"
RUN_VAULT="$TMP_DIR/vault"
RUN_LOG="$TMP_DIR/run.log"
RUN_LOCK="$TMP_DIR/run.lock"
RUN_CAPTURE="$RUN_VAULT/2099-01-02.md"

cat > "$RUN_OUTPUT" <<'EOF'
<!-- capture:item-start -->
## AI 세션 (22:00, claude.ai claude-opus-4-7)
<!-- source: claude.ai recent conversations -->
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

FLAG_CLAUDE="$TMP_DIR/flag-claude"
FLAG_ARGS="$TMP_DIR/flag-args.log"
FLAG_LOG="$TMP_DIR/flag.log"
FLAG_VAULT="$TMP_DIR/flag-vault"
FLAG_LOCK="$TMP_DIR/flag.lock"

cat > "$FLAG_CLAUDE" <<'EOF'
#!/bin/zsh
printf '%s\n' "$@" > "$CLAUDE_ARGS_FILE"
printf 'NO_CAPTURE_CANDIDATES\n'
EOF
chmod +x "$FLAG_CLAUDE"

CAPTURE_DATE="2099-01-04" \
VAULT_CAPTURE="$FLAG_VAULT" \
CAPTURE_LOG_FILE="$FLAG_LOG" \
CAPTURE_LOCK_DIR="$FLAG_LOCK" \
CLAUDE_BIN="$FLAG_CLAUDE" \
CLAUDE_ARGS_FILE="$FLAG_ARGS" \
"$SCRIPT_DIR/run-capture.sh"

assert_file_contains "$FLAG_ARGS" "--dangerously-skip-permissions"
assert_file_contains "$FLAG_ARGS" "--chrome"
assert_file_contains "$FLAG_ARGS" "--print"
assert_file_contains "$FLAG_LOG" "INFO invoking claude with browser integration flag: --chrome"
assert_file_contains "$FLAG_LOG" "INFO invoking claude with permission bypass flag: --dangerously-skip-permissions"
assert_file_contains "$FLAG_LOG" "INFO no capture candidates reported by Claude"

PROMPT_FILE="$SCRIPT_DIR/../prompts/capture-prompt.md"

assert_file_contains "$PROMPT_FILE" "이번 실행 전용의 자동화 탭을 하나 만든다"
assert_file_contains "$PROMPT_FILE" "기존 사용자 탭이나 창을 재사용하지 않는다"
assert_file_contains "$PROMPT_FILE" "자동화에 사용한 탭만 닫는다"
assert_file_contains "$PROMPT_FILE" '`tabs_close_mcp`'
assert_file_contains "$PROMPT_FILE" '`computer`'
assert_file_contains "$PROMPT_FILE" '`shortcuts_list`'
assert_file_contains "$PROMPT_FILE" '`shortcuts_execute`'
assert_file_contains "$PROMPT_FILE" '`tabs_context_mcp`'
assert_file_contains "$PROMPT_FILE" "자동화 탭 id가 목록에서 사라졌는지 확인한다"
assert_file_contains "$PROMPT_FILE" '`window.close()`'
assert_file_contains "$PROMPT_FILE" "페이지 레벨 JavaScript keyboard event는 탭 닫기 용도로 사용하지 않는다"
assert_file_contains "$PROMPT_FILE" "이 종료 단계의 설명이나 실패 사유를 stdout에 출력하지 않는다"
assert_file_not_contains "$PROMPT_FILE" "Cmd+W"
assert_file_not_contains "$PROMPT_FILE" "가능하면 해당 탭 id를 대상으로 닫고"

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
