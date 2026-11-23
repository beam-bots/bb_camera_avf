<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

<img src="https://github.com/beam-bots/bb/blob/main/logos/beam_bots_logo.png?raw=true" alt="Beam Bots Logo" width="250" />

# bb_camera_avf

[![CI](https://github.com/beam-bots/bb_camera_avf/actions/workflows/ci.yml/badge.svg)](https://github.com/beam-bots/bb_camera_avf/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache--2.0-green.svg)](https://opensource.org/licenses/Apache-2.0)
[![Hex version badge](https://img.shields.io/hexpm/v/bb_camera_avf.svg)](https://hex.pm/packages/bb_camera_avf)
[![Hexdocs badge](https://img.shields.io/badge/docs-hexdocs-purple)](https://hexdocs.pm/bb_camera_avf)
[![REUSE status](https://api.reuse.software/badge/github.com/beam-bots/bb_camera_avf)](https://api.reuse.software/info/github.com/beam-bots/bb_camera_avf)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/beam-bots/bb_camera_avf)

A [Beam Bots](https://github.com/beam-bots/bb) camera driver for macOS —
built-in FaceTime cameras, USB webcams, Continuity Camera — capturing raw
I420 frames through ffmpeg's AVFoundation input in a supervised process.

It exists mostly so that a robot developed on a Mac can see through a real
camera before it is deployed to Linux, where
[`bb_camera_v4l`](https://github.com/beam-bots/bb_camera_v4l) takes over
behind the same interface.

It is a `BB.Sensor` and a `BB.Camera`, declared like any other sensor:

```elixir
topology do
  link :head do
    sensor :eye, {BB.Camera.AVF, device: "FaceTime HD Camera", width: 1280, height: 720}
  end
end
```

Consumers go through [`bb_camera`](https://github.com/beam-bots/bb_camera),
which shares one capture between all of them. Two browser tabs previewing the
same camera produce one ffmpeg, not two.

**Frames never travel on the robot's pubsub.** That carries capture lifecycle
only — `BeginCapture` and `EndCapture`. Frame bytes go over `bb_camera`'s
bounded media interface.

## Installation

```elixir
def deps do
  [
    {:bb, "~> 0.33"},
    {:bb_camera, "~> 0.1"},
    {:bb_camera_avf, "~> 0.1"}
  ]
end
```

Working on this driver from a `bb_workspace` checkout instead? `BB_VERSION=local`
resolves `bb`, `bb_camera` and `bb_camera_ffmpeg` from the sibling checkouts
rather than from Hex.

## Requirements

- **macOS.** This driver speaks AVFoundation through ffmpeg.
- **ffmpeg** on `$PATH` — `brew install ffmpeg`.
- **The Xcode command line tools**, to build MuonTrap's wrapper program — see
  [`bb_camera_ffmpeg`](https://github.com/beam-bots/bb_camera_ffmpeg).
- **Camera access for the app that starts the VM.** See below; this is the
  thing most likely to go wrong.

## Camera access

macOS grants camera access to an *app*, not to a process. An `iex` started in
Terminal, iTerm or Ghostty captures with *that terminal's* permission, and the
first capture from a terminal that has never asked raises the system prompt.

A VM started by something with no user interface — a launchd job, a daemon,
an agent runner — may never be asked. It gets no prompt and no frames, and
nothing says why: ffmpeg opens the camera and then waits for a first frame
that never comes. In that wait it ignores both `q` and `SIGTERM`.

So capture gives up after `:start_timeout_ms` (10 seconds) without a frame,
stops ffmpeg — with `SIGKILL` after `:stop_timeout_ms`, since it ignores
`SIGTERM` — and fails with `{:no_frames, 10000}` as the reason. If the VM
stops first, ffmpeg goes with it: it runs under MuonTrap, which kills it when
the VM's end of the pipe closes. The warning
on the console points here. The timeout cannot tell missing permission from a
camera that sends nothing, so the error names what happened rather than a
cause.

To check or grant access, open **System Settings > Privacy & Security >
Camera** and look for the app you start the VM from.

## Smoke test on a Mac

This walks from nothing to a frame from a real camera. The first half needs no
camera at all, which is deliberate: if the synthetic source works and the real
one does not, the problem is the camera or its permission, and you have
narrowed it down without guessing.

### 1. Install ffmpeg

```sh
brew install ffmpeg
```

### 2. Prove the pipeline works without a camera

From the package directory:

```sh
BB_VERSION=local mix deps.get
BB_VERSION=local iex -S mix
```

`BB_VERSION=local` is needed on **both** commands. It is read each time mix
runs, not stored in the lockfile.

Paste this robot into the session. It captures one of ffmpeg's own synthetic
sources: real ffmpeg, real scale filter, real pipe, real framing — and no
hardware.

```elixir
defmodule SynthCam do
  use BB

  settings do
    name :synth_cam
  end

  topology do
    link :head do
      sensor :eye, {BB.Camera.AVF, lavfi: "testsrc2", width: 320, height: 240, frame_rate: 10}
    end
  end
end

{:ok, _pid} = SynthCam.start_link([])

{:ok, session} = BB.Camera.Media.open(SynthCam, :eye, format: {:raw, :I420})
{:ok, frame} = BB.Camera.Media.next(session, 10_000)

{frame.format, frame.width, frame.height, byte_size(frame.data)}
#=> {{:raw, :I420}, 320, 240, 115200}

File.write!("/tmp/frame.yuv", frame.data)
BB.Camera.Media.close(session)
```

The frame is raw full-range I420, so ffmpeg is what turns it into something
you can look at:

```sh
ffmpeg -f rawvideo -pixel_format yuv420p -color_range pc -video_size 320x240 \
  -i /tmp/frame.yuv /tmp/frame.png
open /tmp/frame.png
```

If that failed, nothing below will work, and the problem is ffmpeg rather than
your camera.

### 3. Find the camera

```sh
BB_VERSION=local mix bb_camera_avf.scan
```

```
Cameras:

  [0] HD Pro Webcam C920
  [1] FaceTime HD Camera

Use the name, not the number - numbers move when cameras are plugged in:

    sensor :eye, {BB.Camera.AVF, device: "HD Pro Webcam C920"}
```

It asks ffmpeg, so the names are spelled the way ffmpeg will match them, and
it opens no camera, so it needs no camera access.

Use the **name**. The number is a position in this list and moves when a
camera is plugged in. Numbers past the last camera are *screens*, so a stale
index can capture a display. Two identical webcams share one name, and this
driver cannot tell them apart.

To find the sizes and rates a camera supports, ask for one it does not:

```sh
ffmpeg -hide_banner -f avfoundation -framerate 1 -video_size 640x480 \
  -i "HD Pro Webcam C920" -frames:v 1 -f null -
```

ffmpeg refuses, and prints every mode the camera lists:

```
Selected framerate (1.000000) is not supported by the device.
Supported modes:
  1280x720@[30.000030 30.000030]fps
  1920x1080@[30.000030 30.000030]fps
  ...
```

A rate written as `30.000030` is asked for as `30`: ffmpeg matches rates to
within 0.01.

### 4. Capture from the real camera

Run this from a terminal app, so that macOS has someone to ask. The first
time, it shows a permission prompt; answer it within the 10-second timeout,
or open the session again afterwards.

```elixir
defmodule MyCam do
  use BB

  settings do
    name :my_cam
  end

  topology do
    link :head do
      sensor :eye, {BB.Camera.AVF, device: "FaceTime HD Camera", width: 1280, height: 720, frame_rate: 30}
    end
  end
end

{:ok, _pid} = MyCam.start_link([])

BB.subscribe(MyCam, [:sensor, :head, :eye])

{:ok, session} = BB.Camera.Media.open(MyCam, :eye, format: {:raw, :I420})
{:ok, frame} = BB.Camera.Media.next(session, 15_000)
{frame.width, frame.height}
File.write!("/tmp/camera.yuv", frame.data)
```

If `next/2` returns `CaptureFailed` with `{:no_frames, 10000}`, see
[Camera access](#camera-access).

`frame.width` and `frame.height` are always the size you asked for, because
ffmpeg scales every frame to it. **If the camera delivers a different size,
ffmpeg scales it to the requested one** — stretching it if the aspect ratio
differs. When ffmpeg cannot configure the camera as asked it prints
`Configuration of video device failed, falling back to default` on the
console and captures at the camera's default size; the console is the only
place that shows up.

### 5. Shut it down

```elixir
BB.Camera.Media.close(session)
flush()
```

```sh
pgrep -lx ffmpeg
```

Nothing. Capture stops when the last consumer leaves, and the camera's light
goes out.

## A preview in a browser

`bb_liveview` mounts a dashboard that previews any camera a robot declares,
this one included. Declare the camera in your robot and point the
dashboard at it; there is nothing driver-specific to wire up.

## Options

| Option | Default | |
|---|---|---|
| `:device` | — | Camera name, `"default"`, or index. Required unless `:lavfi` is given |
| `:lavfi` | — | An ffmpeg synthetic source such as `"testsrc2"`, instead of a camera |
| `:width`, `:height` | `640`, `480` | Asked of the camera and scaled to. Must be even |
| `:frame_rate` | `30` | A hertz unit, a number, or `{numerator, denominator}` |
| `:input_format` | `:nv12` | Pixel format to ask AVFoundation for; converted to I420 |
| `:ffmpeg` | `$PATH` | Path to the ffmpeg executable |
| `:start_timeout_ms` | `10000` | Fail capture when no frame has arrived by then |
| `:drop_queue_len` | `8` | Shed frames while more reads than this are waiting |
| `:stdio_window` | 256 KiB | Bytes of output ffmpeg may have in flight unacknowledged |
| `:stop_timeout_ms` | `2000` | How long ffmpeg gets after `SIGTERM` before `SIGKILL` |

## How it holds together

```
MuonTrap ──> ffmpeg ──pipe──> Capture ──frames──> BB.Camera.Hub ──> consumers
                                                       │
                                                       └─ lifecycle ──> BB.PubSub
```

- **`BB.Camera.AVF.Command`** builds the argument vector and validates it.
  No shell ever parses a camera name.
- **[`bb_camera_ffmpeg`](https://github.com/beam-bots/bb_camera_ffmpeg)** does
  the rest, shared with `bb_camera_v4l`: it runs ffmpeg under MuonTrap, so
  ffmpeg cannot outlive the capture or the VM; it flow-controls ffmpeg's
  output; it cuts the raw video into frames by size; and it holds the first frame
  until the hub has been told capture started.

## Limitations

- **macOS only.**
- **Every frame goes through ffmpeg's scale filter.** Output is always
  full-range I420 at exactly `:width` x `:height`, whatever the camera
  delivers, so a camera that ignores the requested size is scaled rather than
  reported. Both dimensions must be even.
- **Cameras are chosen by name or index.** ffmpeg 9.0 cannot select one by
  its unique ID, so two identical webcams cannot be told apart.
- **Camera access is the app's, not the VM's**, and a missing grant looks
  exactly like a camera that sends nothing. See
  [Camera access](#camera-access).
- **Timestamps are arrival times, not exposure times, and are not suitable for
  synchronisation.** The raw video ffmpeg writes has no container and no
  timestamps; a frame is stamped when the read completing it reached the
  BEAM.
- **The frame rate is reported as requested, not negotiated.** What the frames
  actually did is measured by `BB.Camera.Hub` and reported in
  `BB.Message.Camera.CaptureState`.
- **No capability enumeration.** ffmpeg prints a camera's modes when asked for
  one it does not have; see the smoke test.
- **A failed capture is not retried.** Reopening is the consumer's decision.
- **Changing an option that reaches ffmpeg restarts it**, with `EndCapture`
  and `BeginCapture` around the change.
- **ffmpeg's diagnostics go to the VM's console**, not into the error.
- **I420 only.** `bb_camera` carries raw frames, and this driver always
  writes I420.

## Testing

```sh
BB_VERSION=local mix deps.get
BB_VERSION=local mix test                   # no camera, no ffmpeg needed
BB_VERSION=local mix test --include ffmpeg  # also runs ffmpeg for real
BB_VERSION=local mix check --no-retry
```

The default suite drives the driver through `bb_camera_ffmpeg`'s stub
backend, so every lifecycle case — a capture that fails, a stop racing a
start, a parameter change mid-stream — is a function call rather than
something to wait for. No test sleeps. Framing, flow control and process
cleanup are tested in `bb_camera_ffmpeg`.

The `:ffmpeg` tagged tests run this driver's own argument vector through real
ffmpeg against a synthetic source. They need ffmpeg, but no camera. The one
also tagged `:macos` needs AVFoundation and is skipped elsewhere.

## Licence

Apache-2.0. See `LICENSES/`.
