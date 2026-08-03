# Contributing

## Workflow

1. Create a focused branch from `main`.
2. Keep machine-specific values in `config/tunnels.psd1`; do not commit that file.
3. Make the smallest behavior-preserving change possible.
4. Update `CHANGELOG.md` for user-visible changes.
5. Run the required verification commands.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-StaticChecks.ps1
git diff --check
```

For Linux script changes, also run:

```bash
bash -n scripts/linux/*.sh
```

For macOS script changes, also run:

```bash
tests/Invoke-MacOSStaticChecks.sh
```

macOS integration checks may inspect local SSH, Clash, launchd, and Linux transport state only when explicitly requested. Static checks must not load launchd jobs, edit SSH configuration, or modify remote Linux files.

## Commit messages

Use a short imperative subject. Conventional Commit prefixes are preferred:

- `feat:` new behavior;
- `fix:` bug fix;
- `docs:` documentation only;
- `test:` validation changes;
- `chore:` repository maintenance.

## Review checklist

- No credentials, private keys, runtime logs, or machine-generated state are included.
- Remote forwards remain loopback-only.
- Host aliases are matched exactly.
- Tunnel tasks remain triggerless and controller-owned.
- Installation and uninstallation are idempotent and scoped to configured task names.
