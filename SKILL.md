---
name: macos-background-cua-swift
description: Use this skill to inspect and control macOS windows in three modes: background by window id, foreground app window, and foreground desktop. Prefer it when the task is macOS GUI automation and the agent needs screenshots whose coordinates match the action frame exactly.
---

# macOS Background CUA Swift

Use the native Swift CLI at `.build/release/macos-bg-cua`.

The tool has three operating modes:

- `background`: target a specific window id (`wid`)
- `foreground-app`: target the frontmost app window
- `foreground-desktop`: target the main display

It also has a persistent `cursor` helper for rendering a virtual cursor overlay
as a separate transparent window.

All screenshots are meant to be used as the coordinate frame for later actions.
For window screenshots, coordinates are relative to the cropped window image, not
to a padded or shadowed frame.

## Build

If the binary is missing:

```bash
swift build -c release
```

## Discovery

List apps when you need bundle IDs or PIDs:

```bash
.build/release/macos-bg-cua list-apps
```

List windows, optionally filtered:

```bash
.build/release/macos-bg-cua list-windows
.build/release/macos-bg-cua list-windows --app Helium
.build/release/macos-bg-cua list-windows --bundle-id net.imput.helium
.build/release/macos-bg-cua list-windows --pid 24007
```

For the frontmost app window:

```bash
.build/release/macos-bg-cua active-window
.build/release/macos-bg-cua foreground-app info
```

For the main display:

```bash
.build/release/macos-bg-cua foreground-desktop info
```

Virtual cursor:

```bash
.build/release/macos-bg-cua cursor start background <wid> <x> <y>
.build/release/macos-bg-cua cursor move <x> <y> --duration 0.18
.build/release/macos-bg-cua cursor status
.build/release/macos-bg-cua cursor stop
```

## Agent Loop

Use this pattern:

1. Discover the target with `list-apps`, `list-windows`, `active-window`, or `foreground-*-info`.
2. Capture a screenshot in the same mode you will act in.
3. Inspect the saved image at its real size.
4. Act using coordinates from that image.
5. Capture again and verify the result.

Always verify after actions. A successful return value may only mean the event
was sent, not that the app accepted it.

## Commands

Background mode:

```bash
.build/release/macos-bg-cua background screenshot <wid> [-o path] [--png] [--quality 0.8]
.build/release/macos-bg-cua background click <wid> <x> <y> [--coord pixel|normalized|global]
.build/release/macos-bg-cua background right-click <wid> <x> <y> [--coord pixel|normalized|global]
.build/release/macos-bg-cua background double-click <wid> <x> <y> [--coord pixel|normalized|global]
.build/release/macos-bg-cua background drag <wid> <x1> <y1> <x2> <y2> [--duration 0.3] [--steps 20] [--coord pixel|normalized|global]
.build/release/macos-bg-cua background scroll <wid> <x> <y> <dx> <dy> [--coord pixel|normalized|global]
.build/release/macos-bg-cua background type <wid> <text> [--at X Y] [--replace] [--coord pixel|normalized|global]
.build/release/macos-bg-cua background press <wid> <key> [--mod cmd]...
.build/release/macos-bg-cua background hotkey <wid> <mod>... <key>
```

Foreground app mode:

```bash
.build/release/macos-bg-cua foreground-app info
.build/release/macos-bg-cua foreground-app screenshot [-o path] [--png] [--quality 0.8]
.build/release/macos-bg-cua foreground-app click <x> <y> [--coord pixel|normalized|global]
.build/release/macos-bg-cua foreground-app right-click <x> <y> [--coord pixel|normalized|global]
.build/release/macos-bg-cua foreground-app double-click <x> <y> [--coord pixel|normalized|global]
.build/release/macos-bg-cua foreground-app drag <x1> <y1> <x2> <y2> [--duration 0.3] [--steps 20] [--coord pixel|normalized|global]
.build/release/macos-bg-cua foreground-app scroll <x> <y> <dx> <dy> [--coord pixel|normalized|global]
.build/release/macos-bg-cua foreground-app type <text> [--at X Y] [--replace] [--coord pixel|normalized|global]
.build/release/macos-bg-cua foreground-app press <key> [--mod cmd]...
.build/release/macos-bg-cua foreground-app hotkey <mod>... <key>
```

Foreground desktop mode:

```bash
.build/release/macos-bg-cua foreground-desktop info
.build/release/macos-bg-cua foreground-desktop screenshot [-o path] [--png] [--quality 0.8]
.build/release/macos-bg-cua foreground-desktop click <x> <y> [--coord pixel|normalized|global]
.build/release/macos-bg-cua foreground-desktop right-click <x> <y> [--coord pixel|normalized|global]
.build/release/macos-bg-cua foreground-desktop double-click <x> <y> [--coord pixel|normalized|global]
.build/release/macos-bg-cua foreground-desktop drag <x1> <y1> <x2> <y2> [--duration 0.3] [--steps 20] [--coord pixel|normalized|global]
.build/release/macos-bg-cua foreground-desktop scroll <x> <y> <dx> <dy> [--coord pixel|normalized|global]
.build/release/macos-bg-cua foreground-desktop type <text> [--at X Y] [--coord pixel|normalized|global]
.build/release/macos-bg-cua foreground-desktop press <key> [--mod cmd]...
.build/release/macos-bg-cua foreground-desktop hotkey <mod>... <key>
```

Compatibility aliases still work for background mode:

```bash
.build/release/macos-bg-cua screenshot <wid> ...
.build/release/macos-bg-cua click <wid> ...
```

## Coordinate Rules

Use `pixel` coordinates by default.

- In `background`, pixels are window-local and match the saved window screenshot.
- In `foreground-app`, pixels are local to the frontmost app window screenshot.
- In `foreground-desktop`, pixels are local to the main display screenshot.

`normalized` means `0.0...1.0` fractions of the current frame.

Avoid `global` unless you already know absolute macOS display coordinates.

Do not use coordinates from a downscaled preview directly. Convert back to the
real screenshot size.

## Important Behavior

- `click` prefers Accessibility routes (`AXPress`, text focus, row selection) and falls back to PID-targeted CG mouse events.
- `scroll` prefers AX page-scroll and falls back to CG wheel events.
- `type --at X Y` is the most reliable text path.
- `type --replace` is important for address bars and search bars whose current value must be replaced instead of appended.
- `press` and `hotkey` may still be ignored by some apps while backgrounded, especially Chromium/Electron controls.

## Constraints

This tool is not universal.

- AX-aware controls often work well.
- Canvas-heavy, Qt, wxWidgets, OpenGL, and custom-rendered apps may ignore background CG events.
- A command returning `{"ok": true}` may only mean the event was posted.
- For browser-like apps, text insertion may work while Enter/submit remains flaky.

## Permissions

Grant both:

- Accessibility
- Screen Recording

to the launching terminal/app or the compiled binary. Restart the launching
process after granting permissions.
