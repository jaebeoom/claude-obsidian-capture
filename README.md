# claude-obsidian-capture

Daily capture automation for Claude.ai project conversations.

The job asks Claude to review recent conversations in the Claude.ai project named
`Obsidian Capture Source`, print capture-worthy sessions as deterministic markdown
blocks, and append only new session IDs to the Obsidian Capture vault.

## Workflow

```text
launchd
  -> scripts/run-capture.sh
    -> claude --print prompts/capture-prompt.md
    -> scripts/append-candidates.sh
    -> Vault/Capture/YYYY-MM-DD.md
```

`append-candidates.sh` is the deterministic write boundary. Claude is instructed
to write nothing directly and to print only candidate blocks or
`NO_CAPTURE_CANDIDATES`.

## Key Paths

- Live launchd working copy: `/Users/nathan/Code/Atelier/Projects/claude-obsidian-capture`
- Tracked source: same local working copy
- Capture target: `/Users/nathan/Code/Atelier/Vault/Capture`
- LaunchAgent: `~/Library/LaunchAgents/com.nathan.claude-obsidian-capture.plist`
- Runtime log: `/Users/nathan/Code/Atelier/Projects/claude-obsidian-capture/logs/capture.log`

## Validation

Run these before committing launchd or script changes:

```bash
zsh -n scripts/run-capture.sh
zsh -n scripts/append-candidates.sh
zsh -n scripts/test-capture-local.sh
plutil -lint launchd/com.nathan.claude-obsidian-capture.plist
python3 -B -c "import ast, pathlib; ast.parse(pathlib.Path('scripts/bulk_import.py').read_text(encoding='utf-8'))"
scripts/test-capture-local.sh
```

The fixture test covers append parsing, duplicate skipping, missing session IDs,
`NO_CAPTURE_CANDIDATES`, and the run wrapper's fixture mode.

## Legal And Terms Notes

This repository is intended for personal local automation against the owner's own
Claude.ai account and Obsidian Vault. It is not affiliated with Anthropic and is
not intended to provide a hosted product, shared service, account proxy, or
Claude.ai credential routing for other users.

Do not commit real Claude exports, browser captures, cookies, HAR files, logs, or
Vault `Capture` data. Those files may contain private conversation text,
third-party copyrighted material, authentication artifacts, or personal data.

For any public, shared, or commercial use, prefer Anthropic's official API/SDK
and review the current Anthropic terms and usage policy first.

## Local Working Copy

The tracked checkout is also the launchd working copy. There is no mirror sync
step before fixture testing or launchd smoke testing.

## Launchd

Install or refresh the LaunchAgent from the live copy:

```bash
cp /Users/nathan/Code/Atelier/Projects/claude-obsidian-capture/launchd/com.nathan.claude-obsidian-capture.plist \
  ~/Library/LaunchAgents/com.nathan.claude-obsidian-capture.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.nathan.claude-obsidian-capture.plist
```

For an already-bootstrapped job, inspect it with:

```bash
launchctl print gui/$(id -u)/com.nathan.claude-obsidian-capture
```

## Known Operational Issue

The LaunchAgent itself can run, but macOS may deny background access to the
local Vault path with `operation not permitted`.

That failure is visible in `logs/capture.log` as a failed read of
`/Users/nathan/Code/Atelier/Vault/Capture/YYYY-MM-DD.md`. The script has
already been reduced to zsh file I/O for that read path, so this is a macOS
privacy restriction rather than an `awk` or quoting bug.

Practical fixes:

- Grant Full Disk Access to `/bin/zsh`, then retry.
- If still blocked, grant access to the exact runtime binaries involved, including
  `/opt/homebrew/bin/claude`.
- Keep the live Vault on a normal local path and sync it to cloud storage
  separately if backup is needed.

## License

This repository is released under the MIT License. See `LICENSE`.
