# Security policy

## Sensitive data

This repository must not contain:

- SSH private keys or copied key material;
- passwords, API keys, cookies, or access tokens;
- `authorized_keys`, `known_hosts`, or runtime logs;
- exported scheduled-task XML containing unexpected user or machine data.

Committed examples must use reserved domains and generic SSH aliases. Real host names, user names, externally reachable SSH ports, and public-key contents are machine-local data. Actual per-machine configuration should use an ignored file such as `config/tunnels.psd1` or `config/tunnels.macos.conf`.

## Network boundary

The reverse-forward endpoint on Linux must bind to `127.0.0.1`. Do not use `0.0.0.0`, and do not enable SSH `GatewayPorts` for this workflow. The Windows and macOS proxy targets should also remain on loopback.

The macOS implementation uses user-level launchd agents and user-owned directories for its controller, tunnel jobs, state, and logs. The base installer does not edit the user's SSH configuration or modify the remote Linux host. The optional setup wizard may create the explicitly named `~/.ssh/codex-ssh-tunnel-manager.conf` include and backs up existing local SSH files before changing them; it still does not modify the remote Linux host.

## Reporting

Do not open a public issue containing credentials or logs. Revoke exposed credentials first, then report the minimum reproducible details to the repository owner through a private channel.
