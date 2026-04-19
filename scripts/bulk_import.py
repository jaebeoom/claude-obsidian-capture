#!/usr/bin/env python3
"""One-time bulk import of claude.ai sessions into Vault/Capture/YYYY-MM-DD.md files.

Reads a user-provided JSON export of Claude conversation data and appends
capture-worthy sessions to date-based Obsidian Capture files, deduping by session-id.
"""
from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

KST = timezone(timedelta(hours=9))

VAULT_CAPTURE = Path("/Users/nathan/Code/Atelier/Vault/Capture")
JSON_PATH = Path.home() / "Downloads/claude-captures.json"


def parse_iso(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def conversation_date(conv: dict) -> datetime:
    """Use created_at of the first human message (actual conversation start) in KST."""
    for m in conv.get("messages", []):
        if m.get("sender") == "human" and m.get("created_at"):
            return parse_iso(m["created_at"]).astimezone(KST)
    return parse_iso(conv["created_at"]).astimezone(KST)


def first_time_str(conv: dict) -> str:
    dt = conversation_date(conv)
    return dt.strftime("%H:%M")


def format_session(conv: dict) -> str:
    dt = conversation_date(conv)
    time_str = dt.strftime("%H:%M")
    session_id = f"claude.ai:{conv['uuid']}"
    title = conv["title"]

    lines: list[str] = []
    lines.append(f"## AI 세션 ({time_str}, claude.ai) — {title}")
    lines.append(f"<!-- source: https://claude.ai/chat/{conv['uuid']} -->")
    lines.append(f"<!-- capture:session-id={session_id} -->")
    lines.append("")

    for m in conv["messages"]:
        text = (m.get("text") or "").strip()
        if not text:
            continue
        prefix = "**나**" if m["sender"] == "human" else "**AI**"
        lines.append(f"{prefix}: {text}")
        lines.append("")

    lines.append("#stage/capture #from/claude-ai")
    lines.append("")
    return "\n".join(lines)


SESSION_ID_RE = re.compile(r"capture:session-id=([^\s>]+)")


def existing_session_ids(path: Path) -> set[str]:
    if not path.exists():
        return set()
    text = path.read_text(encoding="utf-8")
    return set(SESSION_ID_RE.findall(text))


def ensure_header(path: Path, date: datetime) -> None:
    if path.exists():
        return
    weekday = date.strftime("%A")
    header = f"# {date.strftime('%Y-%m-%d')} {weekday}\n\n\n---\n\n"
    path.write_text(header, encoding="utf-8")


def main() -> int:
    if not JSON_PATH.exists():
        print(f"ERROR: JSON not found at {JSON_PATH}", file=sys.stderr)
        return 1

    data = json.loads(JSON_PATH.read_text(encoding="utf-8"))
    print(f"Loaded {len(data)} conversations from {JSON_PATH}")

    # Group by KST date
    by_date: dict[str, list[dict]] = {}
    for conv in data:
        dt = conversation_date(conv)
        key = dt.strftime("%Y-%m-%d")
        by_date.setdefault(key, []).append(conv)

    # Sort each day's convs by time ascending
    for convs in by_date.values():
        convs.sort(key=conversation_date)

    added = 0
    skipped = 0
    created_files: list[str] = []
    updated_files: list[str] = []

    for date_str in sorted(by_date.keys()):
        convs = by_date[date_str]
        path = VAULT_CAPTURE / f"{date_str}.md"
        date_dt = conversation_date(convs[0])
        is_new = not path.exists()
        ensure_header(path, date_dt)
        if is_new:
            created_files.append(date_str)

        existing_ids = existing_session_ids(path)
        appended_this_file = 0
        # If file just has the header (ends with "---\n\n"), don't prepend another separator for first block.
        current = path.read_text(encoding="utf-8")
        needs_sep = not current.rstrip().endswith("---") or "## " in current
        with path.open("a", encoding="utf-8") as f:
            for conv in convs:
                sid = f"claude.ai:{conv['uuid']}"
                if sid in existing_ids:
                    skipped += 1
                    continue
                block = format_session(conv)
                if needs_sep:
                    f.write("\n---\n\n")
                else:
                    needs_sep = True
                f.write(block)
                added += 1
                appended_this_file += 1
                existing_ids.add(sid)
        if appended_this_file and not is_new:
            updated_files.append(date_str)

    print(f"\n=== Summary ===")
    print(f"Added sessions: {added}")
    print(f"Skipped (duplicates): {skipped}")
    print(f"Created files ({len(created_files)}): {created_files}")
    print(f"Updated files ({len(updated_files)}): {updated_files}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
