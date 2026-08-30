# MacPilot

**Stop fighting your Mac.**

MacPilot is a lightweight, native macOS power layer focused on removing everyday system friction. The first MVP provides a global command palette, workspace capture/restore, and Finder-oriented quick actions.

## MVP

- Global command palette: `⌘⇧Space`
- Menu-bar utility
- Workspace capture and restoration
- Finder actions such as Terminal handoff and path copying
- Storage overview
- Native SwiftUI/AppKit UI
- macOS 13+

## Build

Requires macOS and Swift 6.

```sh
swift build
swift run MacPilot
```

For a signed distributable app, generate an Xcode project or package the executable with the required entitlements and signing identity.

## Permissions

Some capabilities, especially window management and Finder integration, require macOS Accessibility and Automation permissions. MacPilot should request only the permissions needed for the specific action.

## Roadmap

1. Robust window positioning and workspace restoration
2. Finder context-menu integration
3. Audio controls and rules
4. Storage intelligence with safe review-before-cleanup
5. Natural-language command parsing
6. Mac Timeline / system change history
