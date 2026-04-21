# macOS Background CUA Swift

`macos-bg-cua` is a Swift CLI for controlling a specific macOS app window from
the background. It is intended for coding agents that need to inspect a window,
click controls, type into fields, scroll, drag, and press keys without activating
the target app or stealing focus from the user.

The command shape mirrors
[`antimatter15/macos-background-cua-skill`](https://github.com/antimatter15/macos-background-cua-skill),
but this implementation is Swift-only and does not require Python or PyObjC.

## Status

This tool is useful, but it is not a universal background automation layer.

Confirmed in local testing:

- Window listing works for normal layer-0 app windows.
- Window screenshots work for Helium after the `getWindow` fallback.
- AX text replacement into Helium's address bar works with `type --at ... --replace`.
- Pressing Enter after address-bar replacement can navigate Helium via the CG fallback.
- Raw background CG key events are not guaranteed to affect every app or every control.

Known limitations:

- A command returning `{"ok": true}` may mean "the event was posted", not "the app changed state".
- Browser/Electron/Chromium controls often require AX text insertion; raw CG typing can be ignored while backgrounded.
- Some apps require key-window/frontmost state for canvas or custom event loops. Those cannot be reliably fixed without activation.
- Screenshots use `CGWindowListCreateImage`, which is deprecated by Apple. ScreenCaptureKit is the long-term replacement.

## Build

```bash
swift build -c release
```

The binary is emitted at:

```bash
.build/release/macos-bg-cua
```

Run help:

```bash
.build/release/macos-bg-cua --help
```

## Permissions

macOS privacy permissions are required.

Grant both permissions to the launching app, usually Terminal, Codex, or the
compiled binary itself:

- Accessibility: required for AX hit testing, AXPress, AXValue, focused-element access, and reliable input.
- Screen Recording: required for window screenshots.

After changing permissions, restart the launching process. macOS often caches
permission state at process start.

Symptoms:

- `list-windows` returns `[]`: likely permission, process, or window-layer issue.
- Screenshot is black or empty: likely Screen Recording denial.
- Clicks/type return success but do nothing: likely Accessibility denial or app-specific background input limits.
- `screenshot <wid>` says `window <wid> not found`: the ID may be stale, or a lookup path failed. Re-run `list-windows`.

## Agent Loop

The intended flow is:

1. Optionally list apps to find a bundle ID or PID.
2. List windows, preferably filtered to the target app, and choose the target `wid`.
3. Capture a screenshot for that exact `wid`.
4. Inspect the screenshot at its real pixel size.
5. Act using coordinates measured from the screenshot's top-left.
6. Capture again and verify the result.

Example:

```bash
.build/release/macos-bg-cua list-apps
.build/release/macos-bg-cua list-windows --bundle-id net.imput.helium
.build/release/macos-bg-cua list-windows
.build/release/macos-bg-cua screenshot 105721 --png -o /tmp/helium.png
.build/release/macos-bg-cua click 105721 240 180
.build/release/macos-bg-cua screenshot 105721 --png -o /tmp/helium-after.png
```

Always verify after actions. Background input APIs can report that an event was
sent even when the target app ignores it.

## Commands

```bash
macos-bg-cua list-apps [--running-only]
macos-bg-cua list-windows
macos-bg-cua list-windows [--app NAME] [--bundle-id ID] [--pid PID]
macos-bg-cua screenshot <wid> [-o path] [--png] [--quality 0.8]
macos-bg-cua click <wid> <x> <y> [--coord pixel|normalized|global]
macos-bg-cua right-click <wid> <x> <y> [--coord pixel|normalized|global]
macos-bg-cua double-click <wid> <x> <y> [--coord pixel|normalized|global]
macos-bg-cua drag <wid> <x1> <y1> <x2> <y2> [--duration 0.3] [--steps 20] [--coord pixel|normalized|global]
macos-bg-cua scroll <wid> <x> <y> <dx> <dy> [--coord pixel|normalized|global]
macos-bg-cua type <wid> <text> [--at X Y] [--replace] [--coord pixel|normalized|global]
macos-bg-cua press <wid> <key> [--mod cmd]...
macos-bg-cua hotkey <wid> <mod>... <key>
```

All commands that target a window take `wid` as the first positional argument.
`wid` is the `wid` returned by `list-windows`.

## Coordinates

Coordinates default to `pixel`: window-local screenshot pixels with top-left
origin. This matches the saved screenshot exactly.

Coordinate modes:

- `pixel`: `x,y` are window-local screenshot pixels.
- `normalized`: `x,y` are fractions from `0.0` to `1.0`.
- `global`: `x,y` are macOS global display coordinates.

Use `pixel` by default. `global` is mainly for debugging because it breaks the
simple screenshot-to-action coordinate model.

Important: do not use coordinates from a downscaled preview. If a viewer renders
an `1805x1192` screenshot smaller on screen, estimate proportionally and convert
back to the real screenshot size.

Example:

```text
Window size: 1000x700
Target appears 25% across and 40% down
Click at x=250, y=280
```

## Command Details

### `list-apps`

Prints JSON for running applications known to `NSWorkspace`:

```json
[
  {
    "pid": 24007,
    "name": "Helium",
    "bundleID": "net.imput.helium",
    "running": true,
    "active": false,
    "hidden": false,
    "bundlePath": "/Applications/Helium.app"
  }
]
```

This command is intentionally app-level, not window-level. Use it when an agent
needs to discover a bundle ID or PID before narrowing windows.

`NSWorkspace` includes helper processes, XPC services, menu agents, browser web
content processes, and system agents. That makes the raw output much noisier
than `computer-use.list_apps`, but it exposes useful identifiers for filtering.
For user-facing apps, prefer rows with a non-empty `bundleID` and an `.app`
`bundlePath`.

Options:

- `--running-only`: currently redundant because `NSWorkspace.runningApplications`
  already returns running apps, but kept for CLI symmetry.

### `list-windows`

Prints JSON for normal layer-0 app windows:

```json
[
  {
    "pid": 24007,
    "wid": 105721,
    "width": 1805,
    "height": 1192,
    "owner": "Helium",
    "name": "New Tab",
    "bundleID": "net.imput.helium"
  }
]
```

Only layer-0 windows are listed. This avoids menu extras, wallpaper, popovers,
and other non-document surfaces returned by CoreGraphics.

You can filter windows to a specific app:

```bash
.build/release/macos-bg-cua list-windows --app Helium
.build/release/macos-bg-cua list-windows --bundle-id net.imput.helium
.build/release/macos-bg-cua list-windows --pid 24007
```

Filtering by bundle ID is usually the most stable path. Filtering by app name is
case-insensitive and substring-based, which is convenient but less precise.

### `screenshot`

Captures one window:

```bash
.build/release/macos-bg-cua screenshot 105721 --png -o /tmp/window.png
```

The screenshot path is printed to stdout. PNG is best for visual inspection.
JPEG is the default for smaller files.

Implementation:

- Uses `CGWindowListCreateImage`.
- Captures by window ID.
- Can capture occluded/background windows when Screen Recording permission is granted.

### `click`

Clicks a coordinate in the target window:

```bash
.build/release/macos-bg-cua click 105721 240 180
```

The click planner tries semantic Accessibility routes first:

- Text field: set `AXFocused=true`.
- Button/link/menu item/pop-up button: perform `AXPress`.
- Selectable rows/cells: select through AX where possible.
- Opaque/canvas areas: fall back to PID-targeted CoreGraphics mouse events.

Example output:

```json
{"plan":"press","role":"AXButton","ok":true}
```

or:

```json
{"plan":"cg","role":"AXGroup","ok":true}
```

`cg` means a raw mouse event was posted to the target process. It may still be
ignored by apps that require frontmost/key-window state.

### `right-click` and `double-click`

These use PID-targeted CoreGraphics mouse events. AX has no general-purpose
right-click action.

```bash
.build/release/macos-bg-cua right-click 105721 400 300
.build/release/macos-bg-cua double-click 105721 400 300
```

### `drag`

Sends an interpolated drag using PID-targeted CoreGraphics mouse events:

```bash
.build/release/macos-bg-cua drag 105721 120 400 500 400 --duration 0.5 --steps 30
```

Useful for sliders, resize handles, selections, and drag/drop surfaces. Custom
canvas apps may ignore it while backgrounded.

### `scroll`

Scrolls at a coordinate by pixel deltas:

```bash
.build/release/macos-bg-cua scroll 105721 600 500 0 700
.build/release/macos-bg-cua scroll 105721 600 500 0 -700
```

Positive `dy` means scroll down. Positive `dx` means scroll right.

Routing:

- Tries AX page-scroll actions on the scrollable ancestor.
- Falls back to CG wheel events.

Example output:

```json
{"via":"ax"}
```

or:

```json
{"via":"cg"}
```

### `type`

Types text into the target app:

```bash
.build/release/macos-bg-cua type 105721 "hello world" --at 250 49
```

Preferred path:

- Use `--at X Y` to hit-test a specific text field.
- The tool focuses that text field through AX.
- It writes the whole string through `AXSelectedText` or `AXValue`.

Fallback path:

- If no text field is found, it sends per-character CG key events.
- CG typing is less reliable for background apps and may be ignored.

Use `--replace` when controlling address bars or any field whose existing value
must be replaced rather than appended:

```bash
.build/release/macos-bg-cua type 105721 "chrome://settings" --at 250 49 --replace
```

This was required for Helium/Chromium address-bar control. Without `--replace`,
AX insertion may append to the current address.

Output:

```json
{"via":"ax"}
```

or:

```json
{"via":"cg"}
```

### `press`

Presses one key, optionally with modifiers:

```bash
.build/release/macos-bg-cua press 105721 Enter
.build/release/macos-bg-cua press 105721 ArrowDown
.build/release/macos-bg-cua press 105721 c --mod cmd
```

For focused text fields and `Enter`, the tool first tries semantic AX confirm
actions. If no confirm action is available, it falls back to CG key events.

Important: `{"ok":true}` means the tool found a route and sent/performed it.
It does not prove the app accepted the key. Verify with a screenshot.

Supported keys include:

- `Enter`, `Return`, `Tab`, `Space`, `Escape`
- `Backspace`, `Delete`
- `ArrowUp`, `ArrowDown`, `ArrowLeft`, `ArrowRight`
- `Home`, `End`, `PageUp`, `PageDown`
- `F1` through `F12`
- single ASCII letters, digits, and common punctuation

Supported modifiers:

- `cmd`
- `shift`
- `alt`
- `ctrl`
- `fn`

### `hotkey`

Convenience form for modified keypresses:

```bash
.build/release/macos-bg-cua hotkey 105721 cmd c
.build/release/macos-bg-cua hotkey 105721 cmd shift p
```

This uses the same underlying key event path as `press`.

## Helium Example

Open Helium settings from a background tab:

```bash
WID=105721
.build/release/macos-bg-cua screenshot "$WID" --png -o /tmp/helium.png
.build/release/macos-bg-cua type "$WID" "chrome://settings" --at 250 49 --replace
.build/release/macos-bg-cua press "$WID" Enter
.build/release/macos-bg-cua screenshot "$WID" --png -o /tmp/helium-settings.png
```

Notes from testing:

- `--at 250 49` hit Helium's address bar in an `1805x1192` window.
- `--at 250 30` was too high and hit toolbar/tab chrome, so text fell back to CG and did not land.
- `--replace` prevented duplicated address text.
- The tab title changed to `Settings` and the URL became `helium://settings`.

## Implementation

The tool combines two macOS automation systems.

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

The target window is resolved by `wid`. `list-windows` uses
`CGWindowListCopyWindowInfo`; individual commands first try
`CGWindowListCreateDescriptionFromArray`, then fall back to the same full
window enumeration path. That fallback is important because some IDs returned by
`list-windows` were not resolvable through `CGWindowListCreateDescriptionFromArray`
alone in local testing.

On attach, the tool sets:

- `AXEnhancedUserInterface=true`
- `AXManualAccessibility=true`

AppKit apps may accept these and become more responsive to background AX
operations. Some apps reject them harmlessly.

## Constraints

This tool cannot guarantee background control of all UI.

Reliable paths:

- Window screenshots with Screen Recording permission.
- AXPress on accessible buttons/links.
- AXValue or AXSelectedText writes into accessible text fields.
- AX scroll actions where exposed.

Less reliable paths:

- Raw CG keyboard events into background Chromium/Electron/browser windows.
- Raw CG mouse/key events into canvas/OpenGL/Qt/wxWidgets apps.
- Hotkeys that require the app to be key/frontmost.
- Controls with no useful Accessibility tree.

Behavior to expect:

- `click` can work when `press` does not.
- `type --at ... --replace` can work when raw typing does not.
- `press Enter` may route through AX for text fields, but if AX exposes no
  confirm action it falls back to CG.
- App state must be verified by screenshot or by re-listing window titles.

## Troubleshooting

Re-list before acting if a command says the window was not found:

```bash
.build/release/macos-bg-cua list-windows
```

Capture before and after:

```bash
.build/release/macos-bg-cua screenshot "$WID" --png -o /tmp/before.png
.build/release/macos-bg-cua click "$WID" 100 100
.build/release/macos-bg-cua screenshot "$WID" --png -o /tmp/after.png
```

If text does not land:

- Prefer `type --at X Y`.
- Check that `X Y` actually hits the text field in the screenshot.
- Use `--replace` for address bars/search bars.
- Avoid relying on `hotkey cmd l` for background browser address selection.

If Enter does not submit:

- The app may not expose `AXConfirm`.
- The CG fallback may be ignored while backgrounded.
- Look for an accessible Go/Search/Submit button and use `click` on that instead.

If coordinates are wrong:

- Check the real screenshot dimensions with `sips -g pixelWidth -g pixelHeight /tmp/window.png`.
- Convert from preview proportions back to real pixels.

## Relationship To Upstream Python Skill

The upstream Python skill is the reference design:

- Python file: `scripts/macos_bg_cua.py`
- Depends on PyObjC: Cocoa, Quartz, ApplicationServices.
- Provides both CLI and Python importable functions.

This Swift port keeps the same user-facing command model but differs in a few
ways:

- No Python dependency.
- No importable Python API.
- Adds `type --replace` for reliable address-bar replacement.
- Adds a `getWindow` fallback for IDs listed by CoreGraphics but not resolved
  by direct description lookup.

The same macOS constraints still apply. Swift does not make background CG
keyboard delivery universally reliable; the robust path is semantic AX wherever
the target app exposes it.
