# Architecture

## Components

| Component | Platform | Responsibility |
| --- | --- | --- |
| Controller | Windows | Detect remote Codex SSH sessions and start or stop the corresponding tunnel task. |
| Controller | macOS | Detect remote Codex or Cursor SSH sessions and demand-start or stop the shared launchd tunnel job. |
| Hidden task launcher | Windows | Start PowerShell through the GUI-subsystem Windows Script Host without creating a visible console window. |
| Tunnel launcher | Windows | Wait for the local proxy, then maintain one SSH reverse tunnel. |
| Scheduled tasks | Windows | Keep the controller recoverable and tunnel processes isolated by host. |
| LaunchAgents | macOS | Keep the controller recoverable while leaving tunnel jobs loaded but triggerless. |
| SSH aliases | Windows | Separate development sessions from reverse-forward sessions. |
| SSH aliases | macOS | Separate development sessions from reverse-forward sessions. |
| macOS setup wizard | macOS | Detect local proxy settings, generate machine-local tunnel configuration, optionally manage a dedicated SSH include, and invoke the installer. |
| Codex wrapper | Linux | Inject proxy variables into non-interactive Codex processes. |

## Demand signal

The controller inspects only `ssh.exe` (Windows) or `ssh` (macOS) processes. Codex demand requires an exact configured development alias followed later by `codex app-server proxy`.

For example, `primary-dev` does not match `primary-dev-extra`, because the regular expression requires an alias boundary. Local Codex usage and unrelated SSH sessions do not start a tunnel.

On macOS, Cursor demand additionally accepts the Remote SSH install/keepalive command: SSH options include `-T` and `-D` or `-L`, the parsed destination equals the configured development alias, and the remote command is `bash --login -c bash` (also accepting `/bin/bash`). The SSH process must have a Cursor app executable in its ancestor chain. Host-like tokens in option values or remote commands are not destinations. Unknown shapes fail closed and can be investigated with the inspection script. Ancestry traversal is bounded and tolerates exited parents and cycles.

Either client keeps the existing tunnel alive; the grace period starts only when neither is present. Status reports separate Codex and Cursor counts. Cursor Remote SSH proxy settings inject the remote loopback proxy into newly started servers. Existing servers require a restart; applications that ignore proxy variables still need their own configuration.

### Cursor native inference

Cursor 3.21.16 has a separate native AgentService transport. Its remote HTTP/2 connection was observed connecting directly even with `HTTP_PROXY` and `HTTPS_PROXY` set. The default `cursorAgentHost.remoteInferenceRoute: "auto"` can retain that remote route when its connectivity probe succeeds; connectivity does not establish model availability.

Set `cursorAgentHost.remoteInferenceRoute` to `"always"` in the target remote's machine settings and reload its window. This built-in option routes AgentService through the local Cursor client while file access and tool execution stay on the remote. Mac proxy routing must cover Cursor's service domains. Extensions and tools that honor proxy variables continue using the SSH reverse tunnel. No vendor bundle patches or TLS-verification changes are needed.

This setting is verified in Cursor 3.21.16 and is ignored for private-inference remotes because the local hop bypasses their private inference path. Verify support and constraints in the installed version before applying it elsewhere. Acceptance requires an actual native-model reply and the Agent Host log reporting `route=always`, `routing inference via local client`, and `network kind: external`; a proxy variable or HTTP health check alone is insufficient.

## State model

| Current state | Signal | Action | Next state |
| --- | --- | --- | --- |
| Stopped | Matching session appears | Start the corresponding tunnel task | Running |
| Running | Matching session remains | Refresh last-seen time | Running |
| Running | Signal disappears | Start grace timer | Grace |
| Grace | Signal returns | Cancel stop and refresh last-seen time | Running |
| Grace | Grace period expires | Stop the tunnel task | Stopped |
| Any | Controller exits | Task Scheduler restarts it | Recovered |

The grace timer is in memory. If the controller restarts while a tunnel is running but its session signal is absent, a fresh grace period begins. This favors continuity over aggressive shutdown.

## Scheduled-task invariants

- Each tunnel task has zero triggers and can only be started on demand.
- The controller has a logon trigger and a repeating recovery trigger.
- `MultipleInstances=IgnoreNew` prevents duplicate controllers and tunnels.
- Task actions run through `wscript.exe` and the no-console launcher, while retaining the interactive user principal required for user-owned SSH keys and network settings.
- Tunnel launchers use `ExitOnForwardFailure=yes` and SSH keepalives.

## macOS launchd invariants

- The controller is a user-level LaunchAgent under `~/Library/LaunchAgents`.
- The controller uses `RunAtLoad=true` and `KeepAlive=true` so it recovers after login or an unexpected exit.
- Each tunnel has its own LaunchAgent label, but tunnel jobs use `RunAtLoad=false` and `KeepAlive=false`.
- The controller starts a tunnel only through `launchctl kickstart` after detecting a matching Codex or Cursor session.
- A live tunnel is identified by the exact configured proxy alias and its verified PID.
- Before termination, the executable name, PID, and exact configured alias are checked together.
- launchd output and controller logs are written to user-level macOS log directories, not the repository.

The macOS configuration is a non-executable `KEY=VALUE` file because the Windows PowerShell data file is not a safe POSIX shell configuration format. The setup wizard writes the real file with mode `600` and keeps it outside Git's tracked content. The Windows `tunnels.psd1` contract remains unchanged.
- Task Scheduler Operational history is enabled by the installer when permitted.

## Security boundary

The Linux endpoint is `127.0.0.1:17897`; it is not reachable from the LAN or public network. SSH host-key verification remains enabled, and the repository never manages private-key contents.

The macOS local proxy endpoint is also restricted to `127.0.0.1`. The controller and base installer do not modify remote Linux files or the user's SSH configuration. Only the explicitly selected setup-wizard mode may create the dedicated local SSH include.
