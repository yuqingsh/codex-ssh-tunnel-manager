# Architecture

## Components

| Component | Platform | Responsibility |
| --- | --- | --- |
| Controller | Windows | Detect remote Codex SSH sessions and start or stop the corresponding tunnel task. |
| Hidden task launcher | Windows | Start PowerShell through the GUI-subsystem Windows Script Host without creating a visible console window. |
| Tunnel launcher | Windows | Wait for the local proxy, then maintain one SSH reverse tunnel. |
| Scheduled tasks | Windows | Keep the controller recoverable and tunnel processes isolated by host. |
| SSH aliases | Windows | Separate development sessions from reverse-forward sessions. |
| Codex wrapper | Linux | Inject proxy variables into non-interactive Codex processes. |

## Demand signal

The controller inspects only `ssh.exe` processes. A tunnel is considered in use when the command line contains an exact configured development alias followed later by `codex app-server proxy`.

For example, `primary-dev` does not match `primary-dev-extra`, because the regular expression requires an alias boundary. Local Codex usage and unrelated SSH sessions do not start a tunnel.

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
- Task Scheduler Operational history is enabled by the installer when permitted.

## Security boundary

The Linux endpoint is `127.0.0.1:17897`; it is not reachable from the LAN or public network. SSH host-key verification remains enabled, and the repository never manages private-key contents.
