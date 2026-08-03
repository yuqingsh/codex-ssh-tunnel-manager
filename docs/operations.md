# Operations runbook

macOS users should follow the complete [macOS deployment and usage guide](macos-setup.md). The sections below retain the Windows and Linux operational details.

## Prerequisites

Windows requires:

- Windows PowerShell 5.1;
- OpenSSH Client;
- Clash or another HTTP/mixed proxy listening on `127.0.0.1:7897`;
- SSH development and proxy aliases in `~/.ssh/config`;
- key-only login to each development alias.

Linux requires OpenSSH Server, `curl`, `git`, and a compatible Codex CLI installation.

macOS requires the built-in OpenSSH Client, a Clash HTTP/mixed port, user-level launchd support, and the macOS SSH aliases described in [macOS deployment and usage guide](macos-setup.md).

## Configure Windows

Create the untracked local configuration:

```powershell
Copy-Item .\config\tunnels.example.psd1 .\config\tunnels.psd1
```

Review `config/tunnels.psd1`, then merge the required blocks from `examples/ssh_config` into `~/.ssh/config`. Confirm the local proxy first:

```powershell
Test-NetConnection 127.0.0.1 -Port 7897
ssh -o BatchMode=yes primary-dev hostname
ssh -o BatchMode=yes secondary-dev hostname
```

Do not disable `StrictHostKeyChecking`. Verify first-use fingerprints through a trusted channel.

## Install or upgrade Windows tasks

Open an administrator PowerShell in the repository root:

```powershell
.\scripts\windows\Install-CodexSshTunnelManager.ps1 `
  -ConfigPath .\config\tunnels.psd1 `
  -Verbose
```

The installer is idempotent. It captures current Codex remote-session signals, stops only configured tasks and exact matching tunnel processes, deploys versioned scripts under `%LOCALAPPDATA%\Codex\ssh-tunnel-manager`, recreates the tasks, and restores tunnels that were in use.

The controller and tunnel tasks use the Windows Script Host no-console launcher. They keep the interactive user identity needed for SSH keys but do not display blank PowerShell windows.

## Install the Linux wrapper

Copy `scripts/linux` to the Linux host, then run:

```bash
chmod +x install-codex-wrapper.sh codex-app-proxy-wrapper.sh verify-remote-codex.sh
./install-codex-wrapper.sh
```

The wrapper exposes the reverse tunnel through upper- and lower-case proxy environment variables. It delegates to `~/.local/bin/codex.direct`.

Codex CLI upgrades may replace `~/.local/bin/codex`; reinstall the wrapper if network failures return after an upgrade.

## Status and verification

On Windows:

```powershell
& "$env:LOCALAPPDATA\Codex\ssh-tunnel-manager\Get-CodexSshTunnelStatus.ps1" |
  Format-Table -AutoSize
```

Expected invariants:

- the controller is `Running`;
- every tunnel task has `TriggerCount=0`;
- a tunnel is `Running` only while the matching remote Codex session exists or remains inside its grace period;
- `LocalProxyReachable=True` while Clash is available.
- no blank PowerShell windows are visible for the controller or active tunnel tasks.

On Linux:

```bash
./verify-remote-codex.sh
```

An HTTP `401` from an unauthenticated API request still proves that the TCP, TLS, and proxy transport path works when `TRANSPORT_CURL_EXIT=0`.

## Logs

```text
%LOCALAPPDATA%\Codex\ssh-tunnels\watchdog.log
%LOCALAPPDATA%\Codex\ssh-tunnels\<proxy-alias>.log
```

Task Scheduler events are under `Microsoft-Windows-TaskScheduler/Operational`.

## Troubleshooting

### `remote port forwarding failed for listen port 17897`

Another SSH process is already forwarding the same port on that Linux host. Identify only exact configured proxy aliases before terminating a process:

```powershell
Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" |
  Where-Object CommandLine -Match 'primary-proxy|secondary-proxy'
```

Re-run the installer to perform a scoped handoff.

### Controller is running but a tunnel is stopped

Check whether the corresponding development session exists:

```powershell
Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" |
  Where-Object CommandLine -Match 'codex app-server proxy'
```

Then inspect the launcher log for Clash readiness, SSH authentication, or remote-forward conflicts.

### `stream disconnected before completion`

On Linux, verify in order:

```bash
nc -z -w3 127.0.0.1 17897
curl --proxy http://127.0.0.1:17897 -I --max-time 15 https://api.openai.com/
```

If the port and transport work, verify that the running Codex process inherited `HTTPS_PROXY=http://127.0.0.1:17897`.

## Uninstall

In an administrator PowerShell:

```powershell
& "$env:LOCALAPPDATA\Codex\ssh-tunnel-manager\Uninstall-CodexSshTunnelManager.ps1" `
  -RemoveInstalledFiles
```

Uninstallation does not edit SSH configuration, revoke public keys, or alter Linux files.
