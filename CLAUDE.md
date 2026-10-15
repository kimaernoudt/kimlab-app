# KIMLAB

Native macOS cue player (Swift, AppKit + SwiftUI), a standalone port of a TouchDesigner cue player used for live
shows: audio/video/image cues, groups, LTC timecode, OSC/MIDI, main/backup redundancy. See README.md for the
user-facing behaviour of every feature; keep it up to date when behaviour changes.

## Build and check

- `./build.sh` builds `KIMLAB.app` (about 20 s). Output goes to `build/build.log`, status to `build/status`.
- `./build.sh check` type-checks only. Run it after every change.
- Only Apple's Command Line Tools are installed, no Xcode. Swift Package Manager is broken on this Mac, so
  `Package.swift` is not used; `build.sh` calls `swiftc` directly on `Sources/KIMLAB/*.swift` and works around a
  stale `module.modulemap` with a VFS overlay. Don't "fix" this by switching to `swift build`.
- Target: arm64, macOS 15, Swift 5 language mode, `-parse-as-library`.
- After a build the app is ad-hoc signed (`codesign -s -`).

## Tests

- `./build/KIMLAB --selftest`: no audio device needed (timecode, routing, CSV, OSC, LTC, decoder → mixer).
- `./KIMLAB.app/Contents/MacOS/KIMLAB --livetest /tmp/report.txt`: plays test media through the real audio device
  and video players at -80 dB, measures GO latency and A/V sync, runs the group, main+backup and show-folder steps
  (LinkTest.swift, SyncTest.swift), writes the report and quits.
- `--idletest <report>`: CPU use with a 24-cue list, idle and playing (IdleTest.swift).

## Source layout (Sources/KIMLAB)

| file | what |
|---|---|
| App.swift | entry point, `--selftest` |
| Core.swift | timecode, routing parser, CSV, cue / shortcut / settings models |
| AudioIO.swift | Core Audio devices, output and input units |
| Mixer.swift | voices (ring buffers), mixer (routing, fades, mute/solo, pink, meters), decoder threads |
| LTC.swift | LTC generator and reader |
| Video.swift | A/B video players, crossfade, blackout, test pattern, output window |
| Net.swift | OSC (UDP), CoreMIDI |
| Show.swift, ShowIO.swift | cue logic: GO/standby, auto-follow, TC follow + chase, MIDI learn, OSC, editing, showfiles |
| Groups.swift, Link.swift | group cues (`GroupRun`), explicit group membership in the cue list |
| Extras.swift | fade out / hold and other cue-timing helpers |
| Sync.swift | main/backup redundancy, TCP helper, collect show folder + send to backup |
| Perf.swift | separate redraw tickers so meters don't redraw the cue list |
| UI.swift … UI5.swift | control window (UI4 = header, UI5 = cue rows) |
| SelfTestAudio.swift, LiveTest.swift, LinkTest.swift, SyncTest.swift, IdleTest.swift | tests |

## Conventions

- New features usually go in a new file as an `extension Show` rather than growing Show.swift.
- Audio render code runs on the Core Audio thread: no allocation, locks or Swift collections growth there.
- Showfiles are CSV and must stay compatible with the TouchDesigner version; new fields are extra columns, and
  older saves must still load.
- App state is saved in `~/Library/Application Support/KIMLAB/state.json`; backup shows land in
  `~/Movies/KIMLAB Shows/`.
- Ports: 7100 UDP (redundancy), 7110 TCP (send show to backup).

## Open items

- Cues inside a group are not shown indented.
- NDI / Syphon output not built (needs the NDI SDK).
- Output resolution switching and main/backup between two real laptops are untested.
