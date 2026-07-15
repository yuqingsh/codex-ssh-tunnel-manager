# Repository guidance

This repository manages demand-driven SSH reverse tunnels used by the Codex Windows app to reach proxy services through Linux development hosts.

## Required practices

- Never commit private keys, passwords, access tokens, `authorized_keys`, `known_hosts`, or runtime logs.
- Keep real SSH host names, user names, external ports, and machine-specific aliases out of tracked examples and tests.
- Keep Windows scripts compatible with Windows PowerShell 5.1.
- Keep Linux scripts compatible with POSIX `sh` unless the shebang explicitly selects Bash.
- Bind the remote proxy endpoint to `127.0.0.1`; never broaden it to `0.0.0.0`.
- Match Codex remote sessions by exact SSH host alias plus `codex app-server proxy`; avoid substring-only host matching.
- Scheduled tunnel tasks must remain on-demand tasks with zero triggers. Only the controller may have automatic triggers.
- Scheduled-task actions must use the repository no-console launcher instead of invoking `powershell.exe` directly.
- Any process termination must first match both executable name and an alias declared in the configuration.

## Verification

Run before committing:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-StaticChecks.ps1
git diff --check
```

Static checks must not modify scheduled tasks, SSH configuration, or remote hosts.
