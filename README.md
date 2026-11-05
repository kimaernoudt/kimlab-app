# KIMLAB

Cue player for live shows on the Mac: audio, video and image cues, group cues, LTC timecode, OSC and MIDI control,
a countdown screen with NDI out, and main/backup between two Macs.

## Install

1. Download `KIMLAB.zip` from the [latest release](https://github.com/kimaernoudt/kimlab-app/releases/latest).
2. Unzip it and move `KIMLAB.app` to Applications.
3. The first time, right-click `KIMLAB.app` and choose **Open** (the app is not notarized). After that a
   double-click works.

Needs an Apple silicon Mac with macOS 15 or later. A new release is built after every change to `main`; only the
latest one is kept.

## Basics

- Drop media files on the cue list, or use ADD. Audio: WAV, AIFF, MP3, FLAC, M4A, AAC, CAF (no OGG). Video: anything
  macOS plays. Images: PNG, JPG, TIFF, HEIC, GIF, BMP, WebP.
- GO fires the standby cue (marked `+`) and moves standby to the next cue. Playing cues are marked `>`.
- The cue list, shortcuts, MIDI map and settings are saved automatically
  (`~/Library/Application Support/KIMLAB/state.json`). SAVE / LOAD write and read CSV showfiles.
- HELP in the header shows the keys, OSC addresses and the current MIDI map.

### Cue fields

| field | what |
|---|---|
| FADE / FADE OUT | fade in when the cue starts; fade out when it stops (empty = default fade, or the next cue's fade in for a crossfade) |
| LEVEL | dB |
| OUT | audio outputs: `1-2`, `3,4`, `5-12`, or `5` (start at output 5 and use as many as the file has) |
| LOOP | loop the file |
| HOLD | seconds the cue stays up, then it fades out and counts as ended. Images without HOLD stay until replaced |
| FOLLOW | auto-fire the next cue after N seconds, or `end` when this cue is done |
| WITH (`&`) | start together with the cue above |
| REPLACE | fade out other audio when this cue starts |
| TC | timecode at which the cue fires when TC FOLLOW is on |
| MIDI IN / MIDI OUT / OSC OUT | note that fires this cue; note and OSC address sent when it fires |

### Group cues

- GROUP adds a group cue. IN GROUP or dragging a cue onto a group moves it in or out. Files dropped on a group go into it.
- GO on a group starts all its subcues together. FOLLOW `end` waits for every subcue.
- The chevron folds a group. UP, DOWN, DUPLICATE and drag move or copy it as a whole. Deleting a group keeps its subcues.

### Video and output

- Pick the output (a window or a screen) and its resolution in the header. Video crossfades between two players.
- BLACKOUT and TEST (test pattern) act on the output.
- Video sound goes through the same mixer as audio cues (OUT and LEVEL apply, 5.1 too) and runs on the audio
  device's clock, so picture and sound don't drift apart.
- The mixer always shows 8 output strips with mute, solo, meters and pink noise. Outputs the device doesn't have are
  greyed out.

### Shortcuts

F1 to F8 are shortcut buttons; right-click one to edit it.

## Keyboard

With KEYS on: space GO, left/right PREV/NEXT, up/down select, `x` STOP, `a` stop audio, `b` BLACKOUT, `t` TEST,
`[` / `]` skip 5 s, `1`-`8` shortcuts. Keys are ignored while typing in a field.

## Timecode (LTC)

- TC IN: LTC from an audio input (device and channel) or `/tc` over OSC, at 24, 25 or 30 fps.
- TC FOLLOW: cues fire when the incoming timecode passes their TC. TC CHASE also keeps playing cues locked to the
  timecode: they jump when it jumps and pause when it stops. Chase can be switched off per cue.
- TC OUT: generates LTC on a chosen output device and channel (SEND TC), and sends `/tc` over OSC.

## OSC

Listens on UDP port 7000; sends to 127.0.0.1:7001 by default (both set in the OSC box).

| in | does |
|---|---|
| `/cue/go`, `/cue/prev`, `/cue/next`, `/cue/stop` | same as the buttons |
| `/cue/goto <id>` | fire the cue with that number |
| `/shortcut/1` … `/shortcut/8` | fire a shortcut |
| `/audio/stop`, `/audio/resetpeaks` | stop audio, reset meter peaks |
| `/out/blackout`, `/out/test`, `/out/countdown`, `/out/ndi`, `/ui/lock` | toggle, or set with `0`/`1` |
| `/timeline/skip <s>`, `/timeline/seek <s>` | move the cue on the timeline |
| `/tc HH:MM:SS:FF` | timecode in |

Out: `/cue/fired <id> <name>`, `/cue/stopped`, `/tc`, and each cue's own OSC OUT address.

## MIDI

Choose the MIDI in and out ports in the MIDI box. LEARN, then click a button and send a note or CC to map it; LEARN
again on a mapped button clears it. A cue's MIDI IN note fires that cue; its MIDI OUT note is sent when it fires.

## Countdown screen

- COUNTDOWN opens a window with the time left on running cues: big for the cue or group started last (amber from
  30 s, red from 10 s, with a progress bar), smaller for up to three others, plus time of day and the standby cue.
- Put it in a normal window or full screen on a chosen screen (Esc or double-click to leave).
- NDI sends the same picture (1920 × 1080, 30 fps) as the source `KIMLAB Countdown`, also with the window closed.
  Install [NDI Tools](https://ndi.video) or the NDI SDK first; without it the NDI switch stays off.

## Main and backup

Run KIMLAB on two Macs on the same network.

1. In the REDUNDANCY box set one Mac to MAIN and the other to BACKUP, and give each the other's IP address
   (UDP port 7100).
2. On the main, COLLECT copies all media into a show folder; SEND TO BACKUP sends that folder to the backup over the
   network (TCP port 7110, only changed files). The backup stores it in `~/Movies/KIMLAB Shows/` and loads it.
3. The main mirrors GO, STOP, standby, blackout, test and seeks. The backup resyncs itself when it drifts or joins
   late, and stays quiet on OSC/MIDI while the main is alive.
4. If the main's heartbeat stops for 2 s, the backup shows a red banner and beeps.

SENSE TONE puts a 1 kHz tone on a chosen output while the app is alive, for an automatic audio switcher. For a
tighter lock, let both Macs follow the same LTC. There is no password, so use it on a show network.

## Build from source

Needs Apple's Command Line Tools (`xcode-select --install`), no Xcode.

    ./build.sh          # builds KIMLAB.app (about 20 s), log in build/build.log
    ./build.sh check    # type-check only

Tests:

    ./build/KIMLAB --selftest                                   # no audio device needed
    ./KIMLAB.app/Contents/MacOS/KIMLAB --livetest /tmp/report.txt  # real audio and video at -80 dB, then quits

`icon/make_icon.sh` rebuilds the app icon from `icon/kimlab.svg`. GitHub Actions (`.github/workflows/build.yml`)
builds every pull request and publishes every change to `main` as the latest release.

## Known limits

- Cues inside a group are not shown indented.
- Video out over NDI or Syphon is not built (NDI is for the countdown screen only).
- Output resolution switching and main/backup between two real Macs are untested.
