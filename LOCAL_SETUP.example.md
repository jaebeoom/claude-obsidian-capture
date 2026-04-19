# Local Setup

Copy this to `LOCAL_SETUP.md` and adjust paths for the machine.

Live working copy:
- `/path/to/claude-obsidian-capture`

Capture target:
- `/path/to/Vault/Capture`

launchd label:
- `com.nathan.claude-obsidian-capture`

launchd plist install path:
- `~/Library/LaunchAgents/com.nathan.claude-obsidian-capture.plist`

Useful checks:
- `launchctl print gui/$(id -u)/com.nathan.claude-obsidian-capture`
- `tail -n 120 /path/to/claude-obsidian-capture/logs/capture.log`
- `tail -n 120 /path/to/claude-obsidian-capture/logs/launchd.out.log`
- `tail -n 120 /path/to/claude-obsidian-capture/logs/launchd.err.log`

Known issue:
- If `logs/capture.log` shows `operation not permitted` for the capture file, the LaunchAgent is running but macOS is denying background access to the Vault path.
- The code path has already been reduced to zsh file I/O for Capture reads/writes; this is no longer an `awk`/`grep` quoting issue.
- Grant Full Disk Access to the shell/runtime used by the LaunchAgent, starting with `/bin/zsh`. If that is still blocked, grant it to the exact runtime binaries involved in the job, including `/opt/homebrew/bin/claude`.

Local fixture check:
- `scripts/test-capture-local.sh`

launchd smoke check:
- set `CLAUDE_CAPTURE_OUTPUT_FILE`, `VAULT_CAPTURE`, `CAPTURE_DATE`, and `CAPTURE_LOG_FILE` with `launchctl setenv`
- run `launchctl kickstart -k gui/$(id -u)/com.nathan.claude-obsidian-capture`
- clear those temporary variables with `launchctl unsetenv`

Production trigger:
- `launchctl kickstart -k gui/$(id -u)/com.nathan.claude-obsidian-capture`
