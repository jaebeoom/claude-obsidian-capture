#!/bin/zsh
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  printf 'Usage: %s CLAUDE_OUTPUT_FILE CAPTURE_FILE LOG_FILE\n' "$0" >&2
  exit 2
fi

OUTPUT_FILE="$1"
CAPTURE_FILE="$2"
LOG_FILE="$3"
BLOCK_DIR="$(mktemp -d -t claude-obsidian-capture-blocks.XXXXXX)"
BLOCK_INDEX="$BLOCK_DIR/index"
PARSE_LOG="$BLOCK_DIR/parse.log"

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG_FILE"
}

log_first_nonempty_line() {
  local output_file="$1"
  local first_line

  if [[ ! -s "$output_file" ]]; then
    return
  fi

  first_line="$(awk 'NF { print; exit }' "$output_file")"
  if [[ -n "$first_line" ]]; then
    if (( ${#first_line} > 200 )); then
      first_line="${first_line[1,200]}..."
    fi
    log "WARN Claude output first non-empty line: $first_line"
  fi
}

contains_capture_markers() {
  local output_file="$1"

  grep -Eq '<!--[[:space:]]*capture:item-(start|end)[[:space:]]*-->' "$output_file"
}

contains_no_capture_sentinel() {
  local output_file="$1"

  awk '
    $0 == "NO_CAPTURE_CANDIDATES" {
      found = 1
    }
    END {
      exit !found
    }
  ' "$output_file"
}

contains_extra_nonempty_output() {
  local output_file="$1"

  awk '
    NF && $0 != "NO_CAPTURE_CANDIDATES" {
      extra = 1
    }
    END {
      exit !extra
    }
  ' "$output_file"
}

log_unparseable_output() {
  local output_file="$1"

  if [[ ! -s "$output_file" ]]; then
    log "WARN Claude output was empty"
    return
  fi

  if grep -Eiq 'requires approval|permission mode|AppleScript|osascript' "$output_file"; then
    log "ERROR Claude capture automation was blocked by permission requirements"
  elif grep -Fq 'NO_CAPTURE_CANDIDATES' "$output_file"; then
    log "WARN Claude output included NO_CAPTURE_CANDIDATES but parseable capture blocks were not found"
  else
    log "WARN Claude output did not contain parseable capture blocks"
  fi

  log_first_nonempty_line "$output_file"
}

session_exists() {
  local capture_file="$1"
  local session_id="$2"
  local line

  [[ -f "$capture_file" ]] || return 1

  while IFS= read -r line; do
    if [[ "$line" == *"capture:session-id=$session_id"* ]]; then
      return 0
    fi
  done < "$capture_file"

  return 1
}

cleanup() {
  rm -rf "$BLOCK_DIR"
}

trap cleanup EXIT

if [[ ! -f "$OUTPUT_FILE" ]]; then
  log "ERROR Claude output file not found: $OUTPUT_FILE"
  exit 1
fi

if ! contains_capture_markers "$OUTPUT_FILE" && contains_no_capture_sentinel "$OUTPUT_FILE"; then
  if grep -Eiq 'requires approval|permission mode|AppleScript|osascript' "$OUTPUT_FILE"; then
    log "ERROR Claude capture automation was blocked by permission requirements"
    log_first_nonempty_line "$OUTPUT_FILE"
    log "INFO no complete capture candidate blocks found"
  else
    if contains_extra_nonempty_output "$OUTPUT_FILE"; then
      log "WARN Claude output mixed NO_CAPTURE_CANDIDATES with additional text"
      log_first_nonempty_line "$OUTPUT_FILE"
    fi
    log "INFO no capture candidates reported by Claude"
  fi
  exit 0
fi

mkdir -p "$BLOCK_DIR"
: > "$BLOCK_INDEX"
: > "$PARSE_LOG"

awk -v dir="$BLOCK_DIR" -v index_file="$BLOCK_INDEX" -v parse_log="$PARSE_LOG" '
  /<!--[[:space:]]*capture:item-start[[:space:]]*-->/ {
    if (in_block) {
      print "WARN nested capture:item-start before capture:item-end; previous block skipped" >> parse_log
      close(out)
    }
    block += 1
    in_block = 1
    out = sprintf("%s/block-%06d.md", dir, block)
    next
  }

  /<!--[[:space:]]*capture:item-end[[:space:]]*-->/ {
    if (!in_block) {
      print "WARN capture:item-end without capture:item-start skipped" >> parse_log
      next
    }
    in_block = 0
    close(out)
    print out >> index_file
    next
  }

  in_block {
    print > out
  }

  END {
    if (in_block) {
      print "WARN capture:item-start without capture:item-end; incomplete block skipped" >> parse_log
      close(out)
    }
  }
' "$OUTPUT_FILE"

while IFS= read -r parse_warning; do
  [[ -n "$parse_warning" ]] && log "$parse_warning"
done < "$PARSE_LOG"

if [[ ! -s "$BLOCK_INDEX" ]]; then
  log_unparseable_output "$OUTPUT_FILE"
  log "INFO no complete capture candidate blocks found"
  exit 0
fi

mkdir -p "$(dirname "$CAPTURE_FILE")"

appended_count=0
skipped_count=0

while IFS= read -r block_file; do
  [[ -f "$block_file" ]] || continue

  session_id="$(awk 'match($0, /capture:session-id=[^ >]+/) { print substr($0, RSTART + 19, RLENGTH - 19); exit }' "$block_file")"

  if [[ -z "$session_id" ]]; then
    log "WARN skipped capture candidate without session-id: $(basename "$block_file")"
    skipped_count=$((skipped_count + 1))
    continue
  fi

  if session_exists "$CAPTURE_FILE" "$session_id"; then
    log "INFO skipped duplicate capture candidate: $session_id"
    skipped_count=$((skipped_count + 1))
    continue
  fi

  if {
    if [[ -s "$CAPTURE_FILE" ]]; then
      printf '\n\n'
    fi
    cat "$block_file"
    printf '\n'
  } >> "$CAPTURE_FILE"; then
    log "INFO appended capture candidate: $session_id"
    appended_count=$((appended_count + 1))
  else
    log "ERROR failed to append capture candidate: $session_id ($(basename "$block_file"))"
    exit 1
  fi
done < "$BLOCK_INDEX"

log "INFO append summary: appended=$appended_count skipped=$skipped_count"
