# Changelog

All notable changes to this project are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add macOS Cursor Remote SSH demand detection with exact SSH destination parsing and Cursor process ancestry checks, sharing the existing Codex tunnel and idle grace period.
- Report separate Cursor session counts, document per-host Cursor proxy settings and server restart, and test matching exclusions plus the controller lifecycle without changing system state.
- Add a macOS user-level launchd controller and triggerless on-demand tunnel jobs.
- Add macOS configuration, installation, status, inspection, uninstallation, and static-check scripts.
- Add an interactive macOS setup wizard that detects Clash ports, generates machine-local configuration, optionally manages a dedicated SSH include, and invokes the launchd installer.
- Add macOS deployment and usage documentation while preserving the Windows and Linux implementations.

### Fixed

- Document Cursor native Agent's separate inference route: proxy environment variables alone do not cover its remote HTTP/2 transport. Configure the built-in local-client hop per remote, and require an actual chat response plus route verification when validating the setup.
- Fix macOS controller state writes so the tunnel name and all state fields are passed consistently under POSIX shell `set -u`.

## [0.2.0] - 2026-07-15

### Changed

- Publish the project under the MIT License.
- Replace machine-specific SSH endpoints, aliases, users, ports, and task names with reusable examples.
- Replace the private deployment history with a clean public release history.

## [0.1.1] - 2026-07-14

### Added

- Windows bootstrap guide for cloning the repository and installing the demand-driven behavior.

### Fixed

- Run scheduled controller and tunnel tasks through a no-console Windows Script Host launcher so background tasks do not create blank PowerShell windows.
- Handle stopped tunnels without a `ProcessId` property in the status command under strict mode.

## [0.1.0] - 2026-07-13

### Added

- Demand-driven controller for two Codex remote SSH sessions.
- On-demand reverse-tunnel launcher with Clash readiness and SSH keepalive checks.
- Idempotent Windows installer, uninstaller, status command, and public-key helper.
- Linux Codex proxy wrapper and remote transport verification script.
- Static validation for PowerShell syntax, configuration, matching rules, and secret markers.
