<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# BB.Camera.AVF Usage Rules

`bb_camera_avf` provides `BB.Camera.AVF`, a macOS camera driver for
[Beam Bots](https://hexdocs.pm/bb). It captures through ffmpeg's AVFoundation
input in a supervised process, converts every frame to full-range I420 at the
configured size, and serves raw frames through
`bb_camera`. For framework basics see `bb`'s rules; for the consumer-facing
API see `bb_camera`'s. This file covers only what is specific to this driver.

## Core principles

1. **It is a declared component.** Wire it into a `sensor` slot. BB validates
   its options, injects context, and supervises it. You never call
   `start_link` or write a `child_spec`.
2. **You never start or stop capture.** `bb_camera` refcounts consumers and
   tells the driver. One capture serves all of them.
3. **Frames do not go on pubsub.** Frame bytes travel over `BB.Camera.Media`
   or `BB.Camera.subscribe/3`.
4. **It is for macOS.** On Linux use `bb_camera_v4l`. Both are `BB.Camera`s,
   so swapping one for the other changes the sensor declaration and nothing
   else.

## Wiring it in

```elixir
topology do
  link :head do
    sensor :eye, {BB.Camera.AVF,
      device: "FaceTime HD Camera",
      width: 1280,
      height: 720,
      frame_rate: 30
    }
  end
end
```

Then consume it through `bb_camera`:

```elixir
{:ok, session} = BB.Camera.Media.open(MyRobot, :eye, format: {:raw, :I420})
{:ok, frame} = BB.Camera.Media.next(session, 15_000)
BB.Camera.Media.close(session)
```

## Picking a camera and a mode

List cameras by name:

```sh
mix bb_camera_avf.scan
```

Use the name, not the number. The number moves when cameras are plugged in,
and numbers past the last camera are screens. `"default"` means the system's
default camera.

To see a camera's modes, ask for one it does not have; ffmpeg refuses and
lists them all. `width`, `height` and `frame_rate` should match one of them.
`frame_rate: 30` matches a listed `30.000030`. `width` and `height` must be
even, because I420 halves both; an odd one is refused with
`BB.Error.Invalid.Camera.UnsupportedFormat` before capture starts.

## Camera access

macOS grants camera access to the app that starts the VM — usually a
terminal. Without it, ffmpeg gets no frames and waits forever, so capture
fails after `:start_timeout_ms` with `{:no_frames, ms}` in
`BB.Error.Hardware.Camera.CaptureFailed`. Grant access in System Settings >
Privacy & Security > Camera.

The first capture from a new terminal shows a prompt. Raise
`:start_timeout_ms` if the default 10 seconds is too short to answer it.

## What the driver claims to know

- Frames are always `{:raw, :I420}`, full range, at exactly the `width` and
  `height` you asked for. **If the camera delivers a different size, ffmpeg
  scales it to the requested one**, aspect ratio and all; the only sign is
  ffmpeg's warning on the console.
- `frame_rate` in `stream_info` is the rate that was *asked for*.
  `BB.Camera.Hub` measures what the frames actually did and publishes it in
  `BB.Message.Camera.CaptureState`.

## Bounds you may need to change

- `:drop_queue_len` (8) is where frames start being shed.
- `:stdio_window` (256 KiB) is how much output ffmpeg may have in flight
  before it waits; it bounds what can queue in the VM.
- `:start_timeout_ms` (10 s) is how long a capture waits for its first frame.

## Failure modes

- **No camera access, or a camera that sends nothing** — no frame within
  `:start_timeout_ms`; ffmpeg is killed and capture fails with
  `{:no_frames, ms}`.
- **Unknown camera, or a mode it does not list** — ffmpeg exits non-zero and
  explains on the VM's console; capture fails with `{:exited, status}`.
- **Capture is not retried.** Reopening is the consumer's decision.

## Don't

- Don't start a `BB.Camera.FFmpeg.Capture` for a camera this driver
  declares. The driver owns its capture.
- Don't declare a parameter looser than the option it feeds;
  `handle_options/2` cannot refuse a change and keep running.
- Don't publish frames on pubsub, or put frame bytes in an error.
- Don't select a camera by index in anything you keep.

## Further reading

- [bb_camera_avf docs](https://hexdocs.pm/bb_camera_avf)
- `BB.Camera.AVF` for the options and the parameters they feed
- `mix bb_camera_avf.scan` to list the cameras and modes AVFoundation reports
- `bb_camera`'s usage rules for the hub, subscriptions and frames
