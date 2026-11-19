<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# AGENTS.md

This file provides guidance to AI coding agents when working with code in this
repository.

## Project Overview

`bb_camera_avf` is a Beam Bots camera driver for macOS, capturing through
ffmpeg's AVFoundation input. One module, `BB.Camera.AVF`, is both a
`BB.Sensor` and a `BB.Camera`; `BB.Camera.AVF.Command` builds the ffmpeg
argument vector.

Running ffmpeg, flow control, JPEG framing and process cleanup live in
`bb_camera_ffmpeg`, shared with `bb_camera_v4l`. A fix there belongs there,
not here.

Capture lifecycle is **not** this package's decision. `bb_camera`'s
`BB.Camera.Hub` refcounts consumers and tells the driver when to start and
stop, so there is one capture per camera no matter how many consumers there
are. Do not add a second path that starts capture.

## Build and Test Commands

```bash
BB_VERSION=local mix check --no-retry        # everything
BB_VERSION=local mix test                    # no camera and no ffmpeg needed
BB_VERSION=local mix test --include ffmpeg   # also runs ffmpeg for real
```

`BB_VERSION=local` resolves `bb`, `bb_camera` and `bb_camera_ffmpeg` from the
sibling checkouts.

## Architecture

| Module | |
|---|---|
| `BB.Camera.AVF` | The driver. Options, lifecycle, and the bridge to `BB.Camera.Hub` |
| `BB.Camera.AVF.Command` | Builds and validates the ffmpeg argument vector. Pure |
| `BB.Camera.AVF.Devices` | Lists the video devices ffmpeg can see, for `mix bb_camera_avf.scan` |

Everything else is `bb_camera_ffmpeg`: `BB.Camera.FFmpeg.Capture` runs one
capture, and the driver handles its `{:bb_camera_ffmpeg, pid, event}`
messages.

## Things that are easy to get wrong

**ffmpeg's AVFoundation input can wait forever.** It loops until the first
frame arrives, with no timeout and no check for interruption. Measured with
ffmpeg 9.0.2 on macOS 27: in that loop it ignores `q` on stdin and four
`SIGTERM`s; only `SIGKILL` ends it. The usual cause is camera access — macOS
withholds frames from a process whose responsible app has no grant, and says
nothing. `Capture`'s `:start_timeout_ms` exists for this, and MuonTrap's
`SIGKILL` after `:stop_timeout_ms` is what actually ends it. A halted VM
left one of these running under init before ffmpeg ran under MuonTrap.

**Camera access belongs to an app, not to the VM.** A VM started from a
terminal inherits that terminal's grant. A VM started by a daemon or an agent
runner usually has none, and cannot be prompted. When testing against a real
camera from an agent session, expect `{:no_frames, ms}` and ask the user to
run it from their own terminal.

**`-nostdin` is not optional.** ffmpeg's stdin is MuonTrap's flow-control
channel. `Command.argv/1` always emits it, and `bb_camera_ffmpeg` refuses to
start ffmpeg without it.

**There is no passthrough.** AVFoundation hands ffmpeg decoded buffers, even
from a USB webcam that sends MJPEG, so ffmpeg always encodes. Do not
reintroduce `bb_camera_v4l`'s `-c:v copy` path.

**ffmpeg's default frame rate suits no camera.** It is NTSC's 29.97, which
cameras tested here do not list, so `-framerate` is always passed. ffmpeg
matches it against the camera's rates to within 0.01.

**`-fps_mode passthrough`, never `-r`.** A camera that slows down in low light
should produce fewer frames. `-r` makes ffmpeg duplicate them up to the
requested rate and encode every copy.

**Camera names have ffmpeg's sharp edges.** ffmpeg splits its input on `:`,
treats a name beginning `none` as no video and one beginning `default` as the
default camera, and reads a numeric string as an index. Indices past the last
camera are screens. `Command` refuses the names it cannot pass through
faithfully. ffmpeg 9.0 has no way to select by unique ID; newer ffmpeg does
(`uid:` and `serial:` prefixes), and that is the fix for two identical
webcams once it ships.

**Stop and start are a sequence.** A capture that has been asked to stop
keeps its identity in `:stopping` until its real exit arrives, and whatever
wanted to happen next waits in `:pending`. A capture that exits
`{:shutdown, :teardown_unconfirmed}` may still hold the camera, so whatever
was pending is abandoned rather than started. Whether AVFoundation lets two
ffmpegs configure one camera at once is untested; the sequencing means it
never needs to be.

**`Hub.deliver/2` is synchronous and must stay that way.** It is the delivery
bound between `bb_camera_ffmpeg` and `bb_camera`.

**Reconfiguring is `handle_options/2`, and there is no second channel.**
Restart capture only when the new options actually change the ffmpeg argument
vector.

**`stream_info/1` must stay pure.** Discovery calls it against robots that are
not running. It must not touch hardware.

**The sensor traps exits.** A camera that cannot be opened is ordinary, and
the hub has an event for saying so.

## Honesty about what is known

The driver reports dimensions parsed from each frame's own `SOF` marker. That
matters here: when AVFoundation refuses ffmpeg's configuration, ffmpeg warns
`Configuration of video device failed, falling back to default` and captures
at the camera's default size.

The frame rate in `stream_info` is only ever the one that was *asked for*.
The hub measures the real rate; this driver should not.

Do not report a requested value as a negotiated one without adding the query
that would justify it, and do not add a list of supported modes: ffmpeg
prints them when asked for one the camera lacks.

`mix bb_camera_avf.scan` lists devices, not modes, on purpose. Listing devices
opens nothing and needs no camera access. Finding modes means asking ffmpeg to
open the camera, which does, and which turns a quick look into a permission
prompt.

## Testing

The test robot declares `BB.Camera.FFmpeg.Test.StubBackend` as its backend,
and tests feed it images from `BB.Camera.FFmpeg.Test.JpegBuilder`. Both ship
in `bb_camera_ffmpeg`'s `lib` for exactly this.

**No test sleeps, and no timed negative assertions.** To show something did
not happen, push a call through the process first and then use
`refute_received`.

Tests tagged `:macos` need ffmpeg's AVFoundation input and are excluded on
other systems by `test/test_helper.exs`.

## Dependencies

- `bb` — the framework
- `bb_camera` — the `BB.Camera` behaviour, hub, frame and error types
- `bb_camera_ffmpeg` — ffmpeg under MuonTrap, flow control and JPEG framing

## Licensing headers

Every source file must carry an SPDX header — a `#`-style comment for code, an
HTML comment for Markdown, or a `<file>.license` sidecar for files that can't
hold comments. `mix check` runs `reuse lint` and fails the build if one is
missing.

When you create a new file, its `SPDX-FileCopyrightText` line must credit **the
user you are working for** — not you (the agent), and not this repo's original
author. Take their name from `git config user.name` and use the current year.
