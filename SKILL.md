# macOS Background CUA Swift

Use this skill to operate macOS app windows in the background using the native Swift CLI at `.build/release/macos-bg-cua`.

This tool is intended for coding agents. The normal loop is: list windows, pick a `wid`, capture a screenshot, inspect the image, then act using coordinates from that screenshot.

## Build

If the release binary is missing, run:

```bash
swift build -c release
```

## Commands

All commands print one JSON object or array to stdout unless noted.

```bash
.build/release/macos-bg-cua list-windows
.build/release/macos-bg-cua screenshot <wid> [-o path] [--png] [--quality 0.8]
.build/release/macos-bg-cua click <wid> <x> <y> [--coord pixel|normalized|global]
.build/release/macos-bg-cua right-click <wid> <x> <y> [--coord pixel|normalized|global]
.build/release/macos-bg-cua double-click <wid> <x> <y> [--coord pixel|normalized|global]
.build/release/macos-bg-cua drag <wid> <x1> <y1> <x2> <y2> [--duration 0.3] [--steps 20] [--coord pixel|normalized|global]
.build/release/macos-bg-cua scroll <wid> <x> <y> <dx> <dy> [--coord pixel|normalized|global]
.build/release/macos-bg-cua type <wid> <text> [--at X Y] [--coord pixel|normalized|global]
.build/release/macos-bg-cua press <wid> <key> [--mod cmd]...
.build/release/macos-bg-cua hotkey <wid> <mod>... <key>
```

Coordinates default to window-local pixels with the top-left as origin. This matches screenshot pixels.

## Agent Coordinate Rules

Use `pixel` coordinates by default. They are measured in the saved screenshot's real pixel dimensions, not in the size of a preview shown by a chat UI, browser, or image viewer.

If `list-windows` says a window is `1000x700`, the top-left pixel is approximately `0,0`, the center is `500,350`, and the bottom-right is approximately `999,699`.

When an image preview is downscaled, estimate proportionally and convert back to the real screenshot size. If a target appears 25% across and 40% down in any preview of a `1000x700` screenshot, click `250,280`.

Use `--coord normalized` only when you intentionally want fractions from `0.0` to `1.0`. For example, `0.5 0.5 --coord normalized` targets the window center regardless of pixel size.

Use `--coord global` only when you already know macOS global display coordinates. Agents should usually avoid global coordinates because screenshots and `list-windows` are window-local.

## Command Notes

`list-windows` prints JSON entries with `pid`, `wid`, `width`, `height`, `owner`, and `name`. Use `wid` for later commands and `width`/`height` as the coordinate frame.

`screenshot` saves the window image and prints the path. It does not print JSON. Prefer `--png` for visual reasoning.

`click` tries Accessibility first, including `AXPress`, text focus, and row selection. It falls back to PID-targeted CoreGraphics events for canvas-like regions. It prints `plan`, `role`, and `ok`; use that to understand whether the action used AX or CG.

`scroll` tries AX page scroll first, then CoreGraphics wheel events. Positive `dy` scrolls down. Negative `dy` scrolls up. Positive `dx` scrolls right.

`type --at X Y` is usually best for text fields. It first targets the point, then tries AX text insertion, which handles Unicode and avoids keyboard-layout issues. Without `--at`, it uses the currently focused element if possible.

`press` and `hotkey` send US-keyboard virtual-key events to the target PID. Use named keys like `Enter`, `Tab`, `Escape`, `ArrowDown`, `PageUp`, and `F5`.

## Examples

```bash
.build/release/macos-bg-cua list-windows
.build/release/macos-bg-cua screenshot 12345 --png -o /tmp/app.png
.build/release/macos-bg-cua click 12345 240 180
.build/release/macos-bg-cua click 12345 0.25 0.40 --coord normalized
.build/release/macos-bg-cua double-click 12345 410 300
.build/release/macos-bg-cua right-click 12345 410 300
.build/release/macos-bg-cua drag 12345 120 400 500 400 --duration 0.5 --steps 30
.build/release/macos-bg-cua scroll 12345 600 500 0 700
.build/release/macos-bg-cua scroll 12345 600 500 0 -700
.build/release/macos-bg-cua type 12345 "hello world" --at 320 740
.build/release/macos-bg-cua press 12345 Enter
.build/release/macos-bg-cua press 12345 ArrowDown
.build/release/macos-bg-cua press 12345 c --mod cmd
.build/release/macos-bg-cua press 12345 p --mod cmd --mod shift
.build/release/macos-bg-cua hotkey 12345 cmd c
.build/release/macos-bg-cua hotkey 12345 cmd v
.build/release/macos-bg-cua hotkey 12345 cmd shift p
.build/release/macos-bg-cua hotkey 12345 cmd alt Escape
```

## Permissions

Grant Accessibility and Screen Recording permissions to the compiled binary or to the terminal process launching it. A black screenshot usually means Screen Recording is denied. Clicks or keys silently failing usually means Accessibility is denied.

## Limitations

Some Qt, wxWidgets, OpenGL, Metal, and canvas-heavy apps may ignore background CG events because their event loops require the app to be key/frontmost. The Swift implementation cannot bypass that macOS/app-level limitation.
