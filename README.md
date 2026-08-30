# MacPilot

**Stop fighting your Mac.**

MacPilot is a lightweight, native macOS power layer focused on removing everyday system friction.

## Current MVP

- Global command palette: `⌘⇧Space`
- Menu-bar utility
- Native SwiftUI/AppKit interface
- Workspace capture and restoration using macOS Accessibility APIs
- Window position and size restoration across running/launched apps
- Off-screen window recovery when a saved display is unavailable
- Finder-aware `Open Terminal Here`
- Finder-aware `Copy Selected File Path`
- Natural-language intent routing for common commands
- Storage capacity overview
- Local workspace persistence
- macOS 13+

## Example commands

```text
Restore Coding Workspace
Create workspace called YouTube
Move Chrome to monitor 2
Open Terminal Here
Copy Selected File Path
What's my disk space?
Open Settings
```

## Build

Requires macOS and Swift 6.

```sh
swift build
swift run MacPilot
```

A GitHub Actions workflow also validates `swift build` on `macos-latest` for pushes and pull requests.

## Permissions

Window capture, movement and restoration require **Accessibility** permission. Finder commands use explicit Apple Events automation and macOS will request the relevant permission when needed. MacPilot should only request these capabilities when the corresponding action is used.

## Product direction

MacPilot is intentionally being built as a **system power layer**, not another standalone file manager or window manager. The next modules are audio rules, deeper storage intelligence, saved command history, robust Finder contextual integration, and Mac Timeline/system-change visibility.
