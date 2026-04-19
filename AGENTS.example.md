# Project Instructions

This project automates Claude.ai conversation capture into an Obsidian Vault.

## Project Shape

- There is no package manager manifest for the main automation path.
- The production entrypoint is `scripts/run-capture.sh`.
- The deterministic writer is `scripts/append-candidates.sh`.
- Keep the tracked checkout and launchd working copy on a normal local path.

## Validation

Use the narrow project-native checks:

```bash
zsh -n scripts/run-capture.sh
zsh -n scripts/append-candidates.sh
zsh -n scripts/test-capture-local.sh
plutil -lint launchd/com.nathan.claude-obsidian-capture.plist
python3 -B -c "import ast, pathlib; ast.parse(pathlib.Path('scripts/bulk_import.py').read_text(encoding='utf-8'))"
scripts/test-capture-local.sh
```

Do not assume `pytest`, `uv`, or a bare `python` runner is part of this project.

## Operational Safety

- Do not read `.env` files.
- Do not run production `scripts/run-capture.sh` or `launchctl kickstart` unless explicitly asked for operational validation. Production runs can write to the real Vault and invoke Claude/Chrome automation.
- Prefer fixture validation first. `CLAUDE_CAPTURE_OUTPUT_FILE` lets `run-capture.sh` exercise the wrapper and append pipeline without invoking Claude.
- If using launchd smoke tests, set temporary `launchctl setenv` values for `CLAUDE_CAPTURE_OUTPUT_FILE`, `VAULT_CAPTURE`, `CAPTURE_DATE`, `CAPTURE_LOG_FILE`, and `CAPTURE_LOCK_DIR`, then clear them with `launchctl unsetenv`.

## Launchd Notes

- Use `launchctl bootstrap gui/$(id -u) ...` for installation, not deprecated `launchctl load`.
- Use `launchctl print gui/$(id -u)/com.nathan.claude-obsidian-capture` to inspect state.
- If macOS denies background access to the Vault with `operation not permitted`, grant Full Disk Access to `/bin/zsh`; if still blocked, grant it to the exact runtime binaries involved, including `/opt/homebrew/bin/claude`.

## Working Copy Notes

- Keep local machine paths in `AGENTS.md`, not this example file.
- Do not rsync this repository to itself before launchd testing.
- Keep any cloud backup as a separate operation outside the validation flow.
