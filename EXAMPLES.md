# Examples

These examples assume:

- Helium window id: `120310`
- buy button target: `733 531`

## Cursor Move And Click

```bash
./.build/release/macos-bg-cua cursor start background 120310 50 50 --duration 0.0
./.build/release/macos-bg-cua cursor move 733 531 --duration 2.55 --wait
./.build/release/macos-bg-cua cursor click --wait
./.build/release/macos-bg-cua background click 120310 733 531
sleep 2.2 && ./.build/release/macos-bg-cua cursor stop
```

## Cursor Move Only

```bash
./.build/release/macos-bg-cua cursor start background 120310 50 50 --duration 0.0
./.build/release/macos-bg-cua cursor move 733 531 --duration 2.55 --wait
sleep 2.2 && ./.build/release/macos-bg-cua cursor stop
```

## Explicit Multi-Step Move

```bash
./.build/release/macos-bg-cua cursor start background 120310 50 50 --duration 0.0
./.build/release/macos-bg-cua cursor move 200 120 --duration 1.20 --wait
./.build/release/macos-bg-cua cursor move 500 260 --duration 1.20 --wait
./.build/release/macos-bg-cua cursor move 733 531 --duration 1.20 --wait
./.build/release/macos-bg-cua cursor click --wait
./.build/release/macos-bg-cua background click 120310 733 531
sleep 2.2 && ./.build/release/macos-bg-cua cursor stop
```

## Restart Cursor Daemon

Use this after rebuilding so the overlay picks up the latest renderer:

```bash
./.build/release/macos-bg-cua cursor stop
./.build/release/macos-bg-cua cursor start background 120310 50 50 --duration 0.0
```
