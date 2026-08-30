# MacPilot

**Stop fighting your Mac.**

MacPilot is a native macOS power layer for repetitive system friction. It combines a command palette with workspace control, Finder actions, audio automation, storage intelligence, clipboard intelligence, local history, and a local Mac Timeline.

## Current feature set

- Global command palette: `⌘⇧Space`
- Menu-bar utility
- Native SwiftUI + AppKit interface
- Workspace capture and restoration with application window positions and sizes
- Off-screen window recovery when a saved display is unavailable
- Move an application window to a selected monitor
- Finder-aware Terminal handoff and selected-path copying
- Finder creation of new files and folders
- Finder duplicate and rename actions
- System audio controls: volume presets and mute/unmute
- App-triggered audio volume rules
- Storage intelligence scan for Applications, Documents, Downloads, Caches, Developer data, Containers, Docker, and iPhone backups
- Clipboard classification for URLs, email, phones, currency, code, and possible secrets
- Local command history
- Local Mac Timeline for app launches, terminations, display changes, commands, and storage scans
- Launch automation engine
- Local-only persistence; no account or cloud service required
- macOS 13+

## Example commands

```text
Restore Coding Workspace
Create workspace called YouTube
Move Chrome to monitor 2
Open Terminal Here
Copy Selected File Path
What's my disk space?
Inspect Clipboard
Open Control Center
```

## Control Center

The menu-bar **Control Center** provides dedicated views for:

- Workspaces
- Finder power actions
- Audio and audio rules
- Storage intelligence
- Clipboard intelligence and command history
- Mac Timeline
- App-triggered automation

## Build

Requires macOS and Swift 6.

```sh
swift build
swift run MacPilot
```

GitHub Actions validates `swift build` on `macos-latest` for pushes and pull requests.

## Permissions

Window capture, movement and restoration require **Accessibility** permission. Finder actions and system audio automation use explicit macOS automation controls where required. MacPilot should request only the permissions needed for the corresponding feature.

## Privacy

Workspace snapshots, command history, timeline events, audio rules, automation rules, and clipboard classification state are stored locally. MacPilot does not persist clipboard contents, and possible secrets are explicitly classified as non-retainable.

## Product direction

MacPilot is intentionally a **system power layer**, not a standalone Finder replacement, generic window manager, or basic clipboard manager. The long-term direction is deeper native system automation, richer workspace intelligence, safer storage explanations, and more context-aware commands.