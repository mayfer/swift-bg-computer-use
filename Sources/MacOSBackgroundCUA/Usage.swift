import Foundation

func usage() -> String {
    """
    macos-bg-cua: background macOS window control for coding agents

    This tool lets an agent inspect and operate a target app window without
    activating it, or operate the frontmost app / desktop in foreground modes.
    Start with list-apps or list-windows, capture a screenshot, inspect the
    saved image, then act using coordinates from that image.

    usage:
      macos-bg-cua list-apps
      macos-bg-cua list-windows
      macos-bg-cua list-windows [--app NAME] [--bundle-id ID] [--pid PID]
      macos-bg-cua active-window
      macos-bg-cua cursor <command> ...
      macos-bg-cua service <command> ...
      macos-bg-cua background <command> ...
      macos-bg-cua foreground-app <command> ...
      macos-bg-cua foreground-desktop <command> ...
      macos-bg-cua screenshot <wid|app> [-o path] [--png] [--quality 0.8] [--any-window]
      macos-bg-cua click <wid|app> <x> <y> [--coord pixel|normalized|global] [--any-window]
      macos-bg-cua right-click <wid|app> <x> <y> [--coord pixel|normalized|global] [--any-window]
      macos-bg-cua double-click <wid|app> <x> <y> [--coord pixel|normalized|global] [--any-window]
      macos-bg-cua drag <wid|app> <x1> <y1> <x2> <y2> [--duration 0.3] [--steps 20] [--coord pixel|normalized|global] [--any-window]
      macos-bg-cua scroll <wid|app> <x> <y> <dx> <dy> [--coord pixel|normalized|global] [--any-window]
      macos-bg-cua type <wid|app> <text> [--at X Y] [--replace] [--coord pixel|normalized|global] [--any-window]
      macos-bg-cua press <wid|app> <key> [--mod cmd]... [--any-window]
      macos-bg-cua hotkey <wid|app> <mod>... <key> [--any-window]

    agent loop:
      1. Run list-apps if you need a bundle id or pid.
      2. Run list-windows, optionally filtered by --app/--bundle-id/--pid,
         and choose a wid.
      3. Run screenshot <wid> --png -o /tmp/window.png.
      4. Inspect the actual image dimensions, or use width/height from
         list-windows. Those dimensions are the coordinate frame.
      5. Click/type/drag/scroll with x,y measured from the screenshot's top-left.

    modes:
      background         Operate a specific window id (wid) or an app name.
                         If the app has one layer-0 window, it is used directly.
                         If it has multiple windows, pass an exact wid or add
                         --any-window to let the tool pick one. Coordinates are
                         window-local.
      foreground-app     Operate the frontmost app window. Screenshots are
                         cropped to the active window bounds, excluding shadow.
                         Coordinates are window-local unless --coord global.
      foreground-desktop Operate the main display. Screenshots are full-screen.
                         Coordinates are display-local pixels or normalized.
                         Use `info` to get width/height for the current screen.

    coordinate modes:
      pixel       Default. x,y are window-local screenshot pixels, top-left
                  origin. If the screenshot is 1200x800, its bottom-right is
                  approximately x=1199,y=799. This is the safest mode for GPT
                  agents because it matches the captured image bytes.
      normalized  x,y are fractions of the window size from 0.0 to 1.0. Use this
                  only when reasoning proportionally across changing window sizes.
      global      x,y are macOS global screen coordinates. Use only when you
                  already have absolute display coordinates.

    image and coordinate warning:
      Do not use coordinates from a downscaled preview in a chat UI or image
      viewer. Viewers often display the screenshot smaller than its real pixel
      size. Convert proportionally back to the real screenshot/list-windows size.
      Example: a target that appears 25% across and 40% down in any preview of a
      1000x700 window should be clicked at x=250,y=280.

    command behavior:
      list-apps      Prints JSON running apps: pid,name,bundleID,running,active,
                     hidden,bundlePath. This is for discovering bundle IDs/PIDs.
      list-windows   Prints JSON windows: pid,wid,width,height,owner,name.
                     Only normal layer-0 app windows are listed. Add filters to
                     get windows for a specific app.
      background app targeting
                     Background commands accept either a wid or an app name such
                     as "Helium". If multiple windows match, the command errors
                     and prints candidate window ids unless --any-window is used.
      active-window  Prints JSON for the frontmost app's current layer-0 window.
      foreground-app info
                     Prints JSON for the current frontmost app window.
      foreground-desktop info
                     Prints JSON for the main display bounds.
      screenshot     Saves a window image and prints the output path, not JSON.
                     Works for occluded/background windows when Screen Recording
                     permission is granted.
      click          Tries Accessibility first: AXPress, text focus, row select.
                     Falls back to CGEventPostToPid for canvas/opaque areas.
                     Prints {"plan","role","ok"} so agents can see the route.
      right-click    Uses PID-targeted CG events.
      double-click   Sends two clicks at the same coordinate.
      drag           Sends interpolated PID-targeted mouse events.
      scroll         Tries AX page scroll first, then CG wheel. Positive dy means
                     scroll down; positive dx means scroll right. Prints {"via"}.
      type           With --at X Y, first targets that point. AX text insertion is
                     preferred because it handles Unicode and does not depend on
                     keyboard layout. Falls back to ASCII CG keystrokes.
      press/hotkey   Sends US-keyboard virtual-key events to the target PID.
      cursor         Runs a persistent visual overlay cursor. In background mode,
                     it is ordered relative to the target window so overlapping
                     front windows should cover it while the target app is behind.
      service        Runs the CLI as a long-running daemon that accepts commands
                     over a UNIX domain socket at /tmp/macos-bg-cua-service/sock.
                     `service send <args...>` pipes argv to the daemon, which
                     executes the same commands as the CLI and returns stdout,
                     stderr, and an exit code as JSON. The daemon auto-spawns on
                     first `service send` if not running, auto-hides the cursor
                     overlay after a short idle period, and stops the cursor
                     overlay cleanly on `service stop`.

    service commands:
      service start           Spawn the daemon in the background. Idempotent.
      service stop            Shut down the daemon and its cursor overlay.
      service status          JSON status: running pid, socket, cursor state.
      service send <args>...  Execute argv inside the running daemon.
      service ping            Round-trip check against the daemon.
      service run             Run the daemon in the foreground (used internally
                              by `service start`; useful for launchd supervision).

    permissions:
      Accessibility is required for AX actions and most input reliability.
      Screen Recording is required for screenshots. Grant permissions to the
      launching terminal/app or to the compiled binary.

    examples:
      macos-bg-cua list-apps
      macos-bg-cua list-windows
      macos-bg-cua list-windows --bundle-id net.imput.helium
      macos-bg-cua list-windows --app Helium
      macos-bg-cua active-window
      macos-bg-cua cursor start background 12345 240 180 --duration 0.0
      macos-bg-cua cursor start background Helium 240 180 --duration 0.0 --any-window
      macos-bg-cua cursor move 400 320 --duration 0.25 --wait
      macos-bg-cua cursor retarget foreground-app --wait
      macos-bg-cua cursor click --wait
      macos-bg-cua cursor hide
      macos-bg-cua cursor stop
      macos-bg-cua service start
      macos-bg-cua service send list-windows
      macos-bg-cua service send cursor start foreground-desktop 400 400
      macos-bg-cua service send cursor move 700 400 --duration 0.25 --wait
      macos-bg-cua service status
      macos-bg-cua service stop
      macos-bg-cua screenshot 12345 --png -o /tmp/app.png
      macos-bg-cua screenshot Helium --png -o /tmp/helium.png --any-window
      macos-bg-cua foreground-app screenshot --png -o /tmp/front.png
      macos-bg-cua foreground-desktop screenshot --png -o /tmp/screen.png
      macos-bg-cua foreground-app click 240 180
      macos-bg-cua foreground-desktop click 240 180
      macos-bg-cua click 12345 240 180
      macos-bg-cua click Helium 240 180 --any-window
      macos-bg-cua click 12345 0.25 0.40 --coord normalized
      macos-bg-cua double-click 12345 410 300
      macos-bg-cua right-click 12345 410 300
      macos-bg-cua drag 12345 120 400 500 400 --duration 0.5 --steps 30
      macos-bg-cua scroll 12345 600 500 0 700
      macos-bg-cua scroll 12345 600 500 0 -700
      macos-bg-cua type 12345 "hello world" --at 320 740
      macos-bg-cua press 12345 Enter
      macos-bg-cua press 12345 ArrowDown
      macos-bg-cua press 12345 c --mod cmd
      macos-bg-cua press 12345 p --mod cmd --mod shift
      macos-bg-cua hotkey 12345 cmd c
      macos-bg-cua hotkey 12345 cmd v
      macos-bg-cua hotkey 12345 cmd shift p
      macos-bg-cua hotkey 12345 cmd alt Escape
    """
}
