# Security policy

## Sensitive data

This repository must not contain:

- SSH private keys or copied key material;
- passwords, API keys, cookies, or access tokens;
- `authorized_keys`, `known_hosts`, or runtime logs;
- exported scheduled-task XML containing unexpected user or machine data.

Committed examples must use reserved domains and generic SSH aliases. Real host names, user names, externally reachable SSH ports, and public-key contents are machine-local data. Actual per-machine configuration should use `config/tunnels.psd1`, which is ignored by Git.

## Network boundary

The reverse-forward endpoint on Linux must bind to `127.0.0.1`. Do not use `0.0.0.0`, and do not enable SSH `GatewayPorts` for this workflow. The Windows proxy target should also remain on loopback.

## Reporting

Do not open a public issue containing credentials or logs. Revoke exposed credentials first, then report the minimum reproducible details to the repository owner through a private channel.
