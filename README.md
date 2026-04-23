# macOS Background CUA Swift

`macos-bg-cua` is a Swift CLI for macOS GUI automation with three clean modes:

- `background`: target a specific window id
- `foreground-app`: target the frontmost app window
- `foreground-desktop`: target the main display

The core design rule is simple: screenshots define the coordinate frame for the
actions that follow.

For window screenshots, saved images are cropped to the app window bounds and do
not include extra padding or drop shadows. That means screenshot coordinates are
window-relative and directly reusable for clicks, drags, and text targeting.

## Build

```bash
swift build -c release
```

Binary:

```bash
.build/release/macos-bg-cua
```

Help:

```bash
.build/release/macos-bg-cua --help
```

## Modes

### Background

Operate a specific window id (`wid`) without bringing the target app to the
front.

Use this when you already know which window you want from `list-windows`.

### Foreground App

Operate the current frontmost app window. The screenshot is cropped to that
window and uses window-local coordinates.

Use this when the target app is visible and frontmost.

### Foreground Desktop

Operate the main display as a whole. Screenshots are full-screen and use
display-local coordinates.

Use this for desktop-wide interactions, menus, or global UI.

## Discovery

List apps:

```bash
.build/release/macos-bg-cua list-apps
```

This returns app-level JSON including:

- `pid`
- `name`
- `bundleID`
- `running`
- `active`
- `hidden`
- `bundlePath`

Example:

```json
{
  "pid": 24007,
  "name": "Helium",
  "bundleID": "net.imput.helium",
  "running": true,
  "active": false,
  "hidden": false,
  "bundlePath": "/Applications/Helium.app"
}
```

Notes:

- `list-apps` is app-level, not window-level.
- It uses `NSWorkspace.runningApplications`, so it includes helpers, XPC
  services, browser subprocesses, and agents. It is noisier than a curated CUA
  app list, but it exposes the bundle IDs and PIDs needed for filtering.

List windows:

```bash
.build/release/macos-bg-cua list-windows
.build/release/macos-bg-cua list-windows --app Helium
.build/release/macos-bg-cua list-windows --bundle-id net.imput.helium
.build/release/macos-bg-cua list-windows --pid 24007
```

This returns normal layer-0 app windows with:

- `pid`
- `wid`
- `width`
- `height`
- `owner`
- `name`
- `bundleID` when resolvable

Example:

```json
{
  "pid": 24007,
  "wid": 106167,
  "width": 1805,
  "height": 1192,
  "owner": "Helium",
  "name": "Yandex — fast Internet search",
  "bundleID": "net.imput.helium"
}
```

Frontmost-window discovery:

```bash
.build/release/macos-bg-cua active-window
.build/release/macos-bg-cua foreground-app info
.build/release/macos-bg-cua foreground-desktop info
```

`active-window` and `foreground-app info` return the current frontmost app
window. `foreground-desktop info` returns the main display bounds.

## Agent Loop

Recommended loop:

1. Discover the target:
   - `list-apps`
   - `list-windows`
   - `active-window`
   - `foreground-app info`
   - `foreground-desktop info`
2. Pick the correct mode.
3. Capture a screenshot in that mode.
4. Inspect the saved image at real size.
5. Act using coordinates from that screenshot.
6. Capture again and verify the result.

Always verify. A command returning `{"ok": true}` does not always mean the app
accepted the event.

## Commands

### Background

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

### Foreground App

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

### Foreground Desktop

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

### Compatibility Aliases

The old top-level commands still work as aliases for background mode:

```bash
.build/release/macos-bg-cua screenshot <wid> ...
.build/release/macos-bg-cua click <wid> ...
.build/release/macos-bg-cua type <wid> ...
```

## Coordinates

Use `pixel` by default.

- In `background`, `pixel` means window-local pixels relative to the targeted window screenshot.
- In `foreground-app`, `pixel` means window-local pixels relative to the frontmost app screenshot.
- In `foreground-desktop`, `pixel` means display-local pixels relative to the main display screenshot.

Other modes:

- `normalized`: `0.0` to `1.0` fractions of the current frame
- `global`: absolute macOS display coordinates

Do not use coordinates from a downscaled preview directly. Convert them back to
the real screenshot dimensions.

Example:

```text
real screenshot size: 1000x700
target looks 25% across and 40% down
click at x=250, y=280
```

## Command Behavior

### `screenshot`

- `background screenshot <wid>` captures one specific window.
- `foreground-app screenshot` captures the frontmost app window.
- `foreground-desktop screenshot` captures the full main display.

Window screenshots are cropped to the app window bounds and should not include
shadow/padding margins. Coordinates in later commands are intended to match the
saved image exactly.

### `click`

`click` tries Accessibility first:

- text fields: focus through AX
- buttons/links/menu items/pop-up buttons: `AXPress`
- rows/cells: AX selection paths

If that fails or the target is opaque/canvas-like, it falls back to CG mouse
events. Background mode posts to the target PID. Foreground desktop posts to the
global HID tap.

### `scroll`

`scroll` tries AX page scroll first, then CG wheel events.

- positive `dy`: down
- negative `dy`: up
- positive `dx`: right

### `type`

`type --at X Y` is the preferred text path.

It hit-tests the target point, focuses the text field if possible, then tries
AX text insertion via `AXSelectedText` or `AXValue`.

Use `--replace` when the existing field contents must be replaced rather than
appended. This is important for browser address bars and search fields.

If AX text insertion is unavailable, the tool falls back to CG keystrokes.

### `press` and `hotkey`

These send US-keyboard virtual-key events.

For some focused text fields, `Enter` may try semantic AX confirm before falling
back to CG. That still does not guarantee the app will navigate or submit.

## Permissions

Grant both of these to the launching terminal/app or the compiled binary:

- Accessibility
- Screen Recording

After granting permissions, restart the launching process.

Symptoms:

- `list-windows` returns `[]`: likely permission, process, or window-layer issue
- screenshot is black or empty: likely Screen Recording denial
- events return success but do nothing: likely Accessibility denial or app-specific background limitations
- `window <wid> not found`: stale id or lookup mismatch; re-run `list-windows`

## Tooling Used

This implementation combines:

Accessibility APIs:

- `AXUIElementCreateApplication`
- `AXUIElementCopyElementAtPosition`
- `AXUIElementCopyAttributeValue`
- `AXUIElementSetAttributeValue`
- `AXUIElementPerformAction`

CoreGraphics APIs:

- `CGWindowListCopyWindowInfo`
- `CGWindowListCreateDescriptionFromArray`
- `CGWindowListCreateImage`
- `CGEvent.postToPid`
- HID-tap CG event posting for foreground-desktop

App/window discovery uses `NSWorkspace` and `NSRunningApplication`.

## Constraints

This tool is useful, but it is not universal.

Reliable:

- app discovery
- window discovery
- window screenshots
- foreground app screenshots
- foreground desktop screenshots
- AX-focused text entry into accessible controls
- many AXPress-style button interactions

Less reliable:

- raw CG keyboard delivery into background Chromium/Electron/browser controls
- submit/navigation after text entry in some browser chrome fields
- custom canvas/OpenGL/Qt/wxWidgets apps that require key/frontmost state
- any path where the app exposes little or no Accessibility tree

Important rule:

`{"ok": true}` can mean "the event was posted" rather than "the app changed".
Always verify with a fresh screenshot.

## Current Local Findings

Verified locally:

- background Helium navigation works via address-bar replacement
- `type --replace` is needed for reliable address-bar control
- `foreground-app screenshot` produced a clean `1464x949` ChatGPT window crop
- `foreground-desktop screenshot` produced a `3072x1728` full-display image
- `list-apps`, `list-windows --app`, and `list-windows --bundle-id` all work

Still flaky:

- Helium/Chromium submit behavior after typing can differ depending on whether
  the page field, browser field, or default search provider takes the Enter key
- background and foreground key submission are less trustworthy than AX text set

## Example Flows

Background window:

```bash
WID=$(./.build/release/macos-bg-cua list-windows --bundle-id net.imput.helium | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["wid"])')
./.build/release/macos-bg-cua background screenshot "$WID" --png -o /tmp/helium.png
./.build/release/macos-bg-cua background type "$WID" "https://yandex.com" --at 250 49 --replace
./.build/release/macos-bg-cua background press "$WID" Enter
./.build/release/macos-bg-cua background screenshot "$WID" --png -o /tmp/helium-after.png
```

Foreground app:

```bash
./.build/release/macos-bg-cua foreground-app info
./.build/release/macos-bg-cua foreground-app screenshot --png -o /tmp/front.png
./.build/release/macos-bg-cua foreground-app click 240 180
```

Foreground desktop:

```bash
./.build/release/macos-bg-cua foreground-desktop info
./.build/release/macos-bg-cua foreground-desktop screenshot --png -o /tmp/screen.png
./.build/release/macos-bg-cua foreground-desktop click 100 100
```

## Relationship To Upstream Python Skill

This tool was originally modeled after
[`antimatter15/macos-background-cua-skill`](https://github.com/antimatter15/macos-background-cua-skill),
but this repo is a Swift CLI rather than a Python/PyObjC skill.

The interface is now broader than the original background-only flow because it
adds first-class foreground app and foreground desktop modes.
