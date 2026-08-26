# Codex Ducker

Codex Ducker is a native macOS menu-bar utility that lowers other audio while the default microphone is active. It uses a private Core Audio process tap, so it also works with fixed-volume HDMI and DisplayPort outputs and does not need a virtual-audio driver.

## Behavior

- Triggers from the default microphone's actual running state, regardless of which app is using it.
- Bypasses headphones and headsets, including Sony WH-1000XM models and AirPods.
- Ducks all other app and system audio to 20% by default.
- Uses a 25 ms gain ramp in both directions to avoid clicks.
- Rebuilds its private path when the default output device changes.
- Can keep a user-selected microphone as the system default whenever that
  device is available. If it disconnects, macOS chooses the fallback normally;
  Codex Ducker restores the preference when it returns.
- Never changes the saved master volume and never records or saves audio.
- Fails open: the original stream stays unmuted until the tap proves it is receiving nonzero samples; if permission or routing fails, playback is left untouched.
- Excludes Codex Ducker's own Core Audio process from the global tap so the attenuated replacement stream is played instead of being muted recursively.

## Install

Run:

```sh
./scripts/install.sh
```

The installer builds an ad-hoc-signed app for the current Mac, places it in `~/Applications`, and creates a per-user launch agent so it starts at login. On first launch, choose **Enable & Test** and allow **System Audio Recording** when macOS asks. Core Audio requires that permission for process taps; the utility does not save audio.

Use the menu-bar icon to enable/disable ducking, choose 10/20/35/50%, select a
preferred microphone, or run a three-second test. Microphone preference is
opt-in: choose **Follow macOS** to leave input selection entirely unchanged.
The preference controls the system default; apps configured to use a specific
microphone directly continue to honor their own setting.

## Verify

The test suite validates the realtime gain/ramp code and output policy, then builds, signs, and checks the private audio pipeline without starting it:

```sh
./scripts/test.sh
```

Logs are written to `~/Library/Logs/CodexDucker/CodexDucker.log`.

## Remove

Run:

```sh
./scripts/uninstall.sh
```

It stops the launch agent and moves the app and launch-agent plist to the Trash so the removal is recoverable. macOS may retain the System Audio Recording permission entry; it can be removed manually in Privacy & Security.

## Requirements

- macOS 14.2 or newer (tested here against macOS 27.0)
- Xcode command-line build tools
