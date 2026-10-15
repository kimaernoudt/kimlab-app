# KIMLAB (native Mac app)

Cue player for live shows: audio, video and image cues, group cues, LTC timecode, OSC and MIDI, main/backup.
No Xcode needed.

## Run

Double-click `KIMLAB.app`. The cue list, shortcuts, MIDI map and settings are saved automatically in
`~/Library/Application Support/KIMLAB/state.json`. SAVE / LOAD read and write CSV showfiles.

## Build

    ./build.sh          # builds KIMLAB.app (about 20 s), log in build/build.log
    ./build.sh check    # type-check only

Needs Apple's Command Line Tools only. The script works around a stale file in this Mac's Command Line Tools
install (`/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap`, left over from 2023) without
changing anything on the system. Swift Package Manager is broken by the same install, so `Package.swift` is not used.

## Tests

    ./build/KIMLAB --selftest
        Timecode, routing, CSV, OSC, LTC encode -> decode, and a real file through decoder -> voice -> mixer
        (routing, level, mute, solo, pink, seek, loop, end of file, fade-out). No audio device needed.

    ./KIMLAB.app/Contents/MacOS/KIMLAB --livetest /tmp/report.txt
        Plays generated test media (video + linked audio, at -80 dB) through the real audio device and video
        players for a few seconds, measures GO latency and audio/video sync, tests seek and STOP, writes the
        report and quits. Nothing is saved in this mode.

## Source layout (Sources/KIMLAB)

| file | what |
|---|---|
| Core.swift | timecode, routing parser, CSV, cue / shortcut / settings models |
| AudioIO.swift | Core Audio devices, output and input units |
| Mixer.swift | voices (ring buffers), native mixer (routing, fades, mute/solo, pink, meters), file decoder threads |
| LTC.swift | LTC generator and reader |
| Video.swift | A/B video players, crossfade, blackout, test pattern, output window |
| Countdown.swift | countdown window and its NDI sender |
| Net.swift | OSC (UDP), CoreMIDI |
| Show.swift, ShowIO.swift | cue logic: GO/standby, groups, auto-follow, timecode follow + chase, MIDI learn, OSC, editing, showfiles |
| UI.swift, UI2.swift, UI3.swift | control window |
| App.swift, SelfTestAudio.swift, LiveTest.swift | entry point and tests |

## Notes

- NDI out: only for the countdown screen so far (see below). Video output over NDI or Syphon is not built yet.
- OGG audio is not supported (macOS cannot decode it). WAV, AIFF, MP3, FLAC, M4A, CAF work.
- Video audio goes through the same mixer as audio cues, so OUT routing and LEVEL apply to it, including 5.1 files.
- Video runs on the audio device's clock, so picture and sound do not drift apart on long files.
- Output: pick a window or a screen in the header (saved). Default is a window.
- F1-F8: right-click a button to edit it.

## Group cues

- GROUP (cue editor) adds a group cue. With a cue selected, that cue becomes the group's first subcue.
- With a group or subcue selected, ADD and dropped files go into that group. LINK moves a cue in or out.
- GO on a group starts all its subcues together. The group row shows the subcue with the most time left.
- A group has its own number, name, TC, FOLLOW (seconds, or `end` = when every subcue is done), MIDI IN/OUT and OSC OUT.
- The chevron folds the group. UP / DOWN / DUPLICATE move or copy a group as a whole block.
- With a playing group selected, the timeline moves all its subcues together.
- Showfile CSV: extra column `group` (1 = group cue); subcues use the existing `with` column.

## Audio outs

The mixer always has at least 8 output buses, shown as 8 strips. Outputs the current device does not have are
metered but not sent anywhere; their channel number is greyed out.

## Cue timing

- FADE IN: fade when the cue starts. FADE OUT: fade when it is stopped, replaced or its HOLD runs out
  (empty = the default fade for STOP, or the next cue's fade in for a crossfade).
- HOLD: seconds the cue stays up. After that it fades out and counts as ended, so FOLLOW = end fires the next cue.
  A video shorter than its HOLD keeps its last frame until the HOLD is over. An image without HOLD stays until replaced.
- Image cues (png, jpg, tif, heic, gif, bmp, webp) show as type I and behave like video cues without sound.
- Showfile CSV: extra columns `fade_out` and `hold`.

## Cue list

- Drag a row onto a group to make it the group's last subcue, onto a subcue to place it before that subcue,
  onto any other cue to place it before that cue, or below the list to move it to the end.
- A group moves as one block and cannot go inside another group.

## Groups, version 2

Each subcue now stores the id of its group, so the indent cannot change by accident. IN GROUP (cue editor) puts a
cue into the group right above it or takes it out. Deleting a group keeps its subcues as normal cues.
Files from Finder land where they are dropped: on a group or subcue = into that group, on another cue = before it,
below the list = at the end. Older saves and CSV showfiles are converted when loaded.

## Output resolution

Next to the output screen selection. In a window: the window gets that pixel size. On a screen: that display is
switched to the chosen mode for as long as KIMLAB runs (macOS restores it on quit); Native puts it back.
Not tested on a real display yet.

## Countdown screen

- COUNTDOWN (left column, under OUTPUT) opens a window with the time left on the running cues. The picker next to it
  puts it in a normal window (drag it to any screen; double-click or the green button for full screen, Esc to leave)
  or fills a chosen screen (Esc or a double-click closes it there). Open/closed and the screen are saved.
- Big: the cue or group started last, its name, the time left (amber from 30 s, red from 10 s) and a progress bar.
  Below: up to three other running cues. Top: time of day and the standby cue. A group counts down to its subcue
  with the most time left. HOLD counts as the end. A loop shows LOOP; an image without HOLD counts up (+00:12).
- NDI sends the same 1920 x 1080 picture as an NDI source called `KIMLAB Countdown` (30 fps), also with the window
  closed. NDI needs NDI Tools or the NDI SDK installed (ndi.video); KIMLAB loads the library when NDI is switched
  on, so it builds and runs without it. Searched: `$NDI_RUNTIME_DIR_V6`/`V5`/`V4`, `KIMLAB.app/Contents/Frameworks`,
  `~/Library/Application Support/KIMLAB/`, `/Library/NDI SDK for Apple/lib/macOS/`, `/usr/local/lib/`, `/opt/homebrew/lib/`.
- MIDI learnable (actions `countdown`, `ndi`) and OSC `/out/countdown [0|1]`, `/out/ndi [0|1]`.
- Not mirrored to the backup: each machine has its own countdown screen.

## Main / backup (REDUNDANCY box)

- OFF (bypass): plain single-machine player, nothing is sent or received.
- Set one laptop to MAIN and one to BACKUP, give each the other's IP address, and load the same showfile on both.
  Default port 7100 (UDP) both ways.
- The main mirrors GO / fired cues, STOP, standby, blackout, test and timeline seeks to the backup.
- Heartbeat twice a second. No heartbeat for 2 s = red banner in the header, a message and a beep.
- The backup compares what is playing with the main and asks for a resync when they differ for more than 1.5 s
  (also when it joins late). It restarts the cues at the main's position.
- While the main is alive the backup does not send cue OSC or MIDI to other gear. When the main is lost it does.
- Both machines can also follow the same LTC (TC FOLLOW + TC CHASE) for a tighter lock.
- SENSE TONE: 1 kHz at -20 dB on the chosen output, only while the app's main loop is alive, for an automatic
  audio switcher such as a Radial SW8. Video goes through an external switcher.
- Tested with two copies inside one process on one Mac. Not tested between two laptops or with a switcher.

## Pending (build at the end)

- Bug: cues inside a group are not shown indented.

## Show folder and sending it to the backup

- COLLECT (right column) asks for a show folder, copies every cue's media into `<folder>/media/`, points the cues
  at those copies and writes `<folder>/show.csv` with paths relative to the folder. The original files stay where
  they are. The folder then works on any Mac: LOAD its show.csv.
- SEND TO BACKUP (needs REDUNDANCY = MAIN and a connected backup) first brings the show folder up to date, then
  sends it over the network to the backup KIMLAB (TCP port 7110). Media that is already there with the same size
  and date is skipped. No Remote Login, password or AirDrop needed.
- The backup stores shows in `~/Movies/KIMLAB Shows/<show name>/` and loads the received show as soon as nothing
  is playing. It never deletes files there.
- Only a KIMLAB in BACKUP mode accepts shows, and only into that folder. There is no password on it, so use it on
  a show network, not on public Wi-Fi.

## App icon

`icon/kimlab.svg` is the source. `icon/make_icon.sh` renders it and rebuilds `icon/KIMLAB.icns`; `build.sh` copies
that into the app.
