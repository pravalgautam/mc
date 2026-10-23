# mc

A tiny MonitorControl clone for Apple Silicon Macs, in one Swift file. It controls an external monitor over DDC/CI and falls back to software dimming when DDC is unavailable.

## Features

- Menu bar sliders for brightness, contrast and volume
- Input switching (DisplayPort, HDMI 1/2, USB-C)
- Brightness and volume keys control the external monitor (hold ⌥ for macOS default)
- Warm colour at night (7pm–7am)
- Meeting Glow: brighter, warmer screen while the camera is on
- Walk-Away: monitor off when your phone or watch leaves Bluetooth range
- Optional power light toggle (monitor-specific VCP code)
- Presets: Reading, Movie, Night
- Rotate 0/90/180/270°, resolution (incl. HiDPI) and refresh rate pickers
- Black out the monitor when the Mac locks
- Disco mode (tint pulses with music via the mic), Disco Party (spins on beats)
- Matrix tint after 2 min idle, Screen Wipe, Heads or Tails (⌃⌥F flips 0°/180° at random)
- Start at login

## Build

```sh
./build.sh   # builds the CLI and mc.app, installs to /Applications, launches it
```

Media keys need Accessibility permission (System Settings → Privacy & Security → Accessibility).

## CLI

```
mc brightness [0-100]
mc contrast [0-100]
mc off | on
mc get <vcp>
mc set <vcp> <value>
mc scan
mc flip
```

## Notes

- DDC/CI must be enabled in the monitor's menu. Many cheap USB-C→HDMI adapters block DDC; USB-C→DisplayPort is the most reliable.
- Power light: find your monitor's code with `mc scan`, then `defaults write com.dliver.mc ledVCP -int <code>`.
- Walk-Away tuning: `defaults write com.dliver.mc walkRSSI -int -85` and `walkDelay -int 30`.
