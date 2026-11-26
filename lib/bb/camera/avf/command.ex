# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.AVF.Command do
  @moduledoc """
  The ffmpeg invocation for one capture, built and validated up front.

  Keeping this separate from the process that runs it means the exact argument
  vector for a given set of camera options is a pure function, and can be
  asserted on without a camera, without ffmpeg, and without starting anything.
  Given how much of "why is this camera not working" turns out to be a wrong
  flag, that is the part most worth being able to see.

  ## No shell, ever

  The vector is handed to `Port.open/2` with `:spawn_executable`, which calls
  `execve` directly. There is no shell, so no amount of punctuation in a device
  name can turn into a command. The validation here is not defending against
  that; it is defending against arguments that are merely *wrong*.

  ## Naming a camera

  ffmpeg's AVFoundation input takes a camera by name or by index, and both
  have sharp edges that are ffmpeg's rather than this driver's:

  - **An index is not stable.** It is a position in the list ffmpeg prints with
    `-list_devices true`, which changes as cameras are plugged in. Indices past
    the last camera are *screens*, so a stale index can capture a display.
  - **A name is matched exactly**, and two identical webcams share one.
  - **A name containing `:` cannot be used.** ffmpeg splits its input on `:`
    into a video and an audio device, so it is refused here rather than
    silently truncated.
  - **A name beginning `none` or `default` is not a name.** ffmpeg compares
    only those prefixes, and treats them as "no video" and "the system's
    default camera" respectively. `"default"` is accepted on purpose; a name
    beginning `none` is refused.

  Newer ffmpeg can select a camera by its unique ID. 9.0 cannot, so neither
  can this driver.

  ## Always decoding, always scaling

  AVFoundation hands ffmpeg decompressed buffers, even from a USB camera that
  sends MJPEG over the wire, and the hub carries raw frames only. So every frame
  goes through ffmpeg's scale filter on its way out:
  `-vf scale=W:H:out_range=full,format=yuv420p -f rawvideo`, which writes
  full-range I420 at exactly `:width` x `:height`.

  That is forced rather than requested because raw video doesn't describe
  itself: ffmpeg's console output isn't read, so nothing could say what it
  produced if it were left to choose. It has two consequences worth knowing:

  - **A camera that delivers a different size is scaled to the requested
    one.** When AVFoundation refuses ffmpeg's configuration, ffmpeg warns and
    captures at the camera's default size; the filter then resizes every frame
    to the size that was asked for, aspect ratio and all.
  - **The video is never stream-copied.** ffmpeg's AVFoundation input
    allocates each packet at the pixel buffer's padded size but copies the
    image in tightly packed, so `-c:v copy` would put trailing junk bytes on
    the pipe after every frame. The scale filter re-emits tightly packed
    frames.

  `:input_format` still matters: it is what AVFoundation is asked to deliver,
  and so what the filter converts from.

  ## Frame timing

  ffmpeg is told not to change the frame rate on the way out
  (`-fps_mode passthrough`). The raw video muxer carries no timestamps, and for
  such a muxer ffmpeg's default is a constant rate: a camera that slows down
  in low light would have its frames duplicated up to the requested rate,
  rather than producing fewer.
  """

  alias BB.Camera.FFmpeg.FrameRate
  alias BB.Camera.Format
  alias BB.Error.Invalid.Camera.UnsupportedFormat

  @format {:raw, :I420}

  defstruct [:source, :width, :height, :frame_rate, :input_format, :frame_bytes, :executable]

  @typedoc """
  Where the frames come from.

  `{:device, name}` and `{:device, index}` are a real camera. `{:lavfi, filter}`
  is one of ffmpeg's own synthetic sources, which produces genuine raw video
  through the real filter and the real pipe without any hardware —
  useful for proving the pipeline works before blaming the camera.
  """
  @type source ::
          {:device, String.t() | non_neg_integer()} | {:lavfi, String.t()}

  @type t :: %__MODULE__{
          source: source(),
          width: pos_integer(),
          height: pos_integer(),
          frame_rate: FrameRate.t(),
          input_format: String.t(),
          frame_bytes: pos_integer(),
          executable: String.t()
        }

  @type error ::
          {:invalid_device, term()}
          | {:invalid_dimension, term()}
          | {:invalid_frame_rate, term()}
          | {:invalid_input_format, term()}
          | {:invalid_lavfi_source, term()}
          | {:no_source, term()}
          | {:ffmpeg_not_found, term()}
          | UnsupportedFormat.t()

  @format_pattern ~r/\A[a-z0-9_]+\z/

  @doc """
  Build and validate a command.

  ## Options

  - `:device` — the camera's name as ffmpeg lists it (`"FaceTime HD Camera"`),
    `"default"` for the system's default camera, or its index in that list.
    Required, unless `:lavfi` is given.
  - `:lavfi` — the name of an ffmpeg synthetic source such as `"testsrc2"`,
    instead of a device. Only the bare filter name is accepted; the size and
    rate are filled in from `:width`, `:height` and `:frame_rate`, so there is
    one source of truth for them and no filtergraph to get wrong.
  - `:width`, `:height` — positive, even pixel dimensions; I420 halves both
    for its chroma planes, so an odd one is refused with
    `BB.Error.Invalid.Camera.UnsupportedFormat`. AVFoundation is asked for
    this size, and the output is scaled to it whatever the camera delivers.
  - `:frame_rate` — see `BB.Camera.FFmpeg.FrameRate`. ffmpeg matches it against
    the camera's own rates to within 0.01, so `30` selects a camera's
    `30.000030`.
  - `:input_format` — the pixel format to ask AVFoundation for, as ffmpeg names
    it. Default `"nv12"`, which is already 4:2:0 and the cheapest to convert
    to I420. A camera that lacks it gets its first listed format instead, with
    a warning from ffmpeg.
  - `:executable` — path to ffmpeg. Defaults to whatever is on `$PATH`.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, error()}
  def new(opts) do
    with {:ok, source} <- validate_source(opts),
         {:ok, width} <- validate_dimension(Keyword.get(opts, :width)),
         {:ok, height} <- validate_dimension(Keyword.get(opts, :height)),
         {:ok, frame_rate} <- validate_frame_rate(Keyword.get(opts, :frame_rate)),
         {:ok, input_format} <- validate_input_format(Keyword.get(opts, :input_format, "nv12")),
         {:ok, frame_bytes} <- Format.frame_size(@format, width, height),
         {:ok, executable} <- validate_executable(Keyword.get(opts, :executable)) do
      {:ok,
       %__MODULE__{
         source: source,
         width: width,
         height: height,
         frame_rate: frame_rate,
         input_format: input_format,
         frame_bytes: frame_bytes,
         executable: executable
       }}
    end
  end

  @doc """
  The format every command writes: full-range I420.
  """
  @spec format() :: Format.t()
  def format, do: @format

  @doc """
  The argument vector, without the executable itself.

      iex> {:ok, command} = BB.Camera.AVF.Command.new(
      ...>   device: "FaceTime HD Camera", width: 1280, height: 720,
      ...>   frame_rate: 30, executable: "/opt/homebrew/bin/ffmpeg")
      iex> BB.Camera.AVF.Command.argv(command)
      ["-nostdin", "-hide_banner", "-loglevel", "error", "-f", "avfoundation",
       "-pixel_format", "nv12", "-video_size", "1280x720", "-framerate", "30",
       "-i", "FaceTime HD Camera", "-an", "-vf",
       "scale=1280:720:out_range=full,format=yuv420p", "-fps_mode", "passthrough",
       "-f", "rawvideo", "-flush_packets", "1", "pipe:1"]

      iex> {:ok, command} = BB.Camera.AVF.Command.new(
      ...>   lavfi: "testsrc2", width: 320, height: 240,
      ...>   frame_rate: 10, executable: "/opt/homebrew/bin/ffmpeg")
      iex> BB.Camera.AVF.Command.argv(command)
      ["-nostdin", "-hide_banner", "-loglevel", "error", "-re", "-f", "lavfi", "-i",
       "testsrc2=size=320x240:rate=10", "-an", "-vf",
       "scale=320:240:out_range=full,format=yuv420p", "-fps_mode", "passthrough",
       "-f", "rawvideo", "-flush_packets", "1", "pipe:1"]
  """
  @spec argv(t()) :: [String.t()]
  def argv(%__MODULE__{} = command) do
    # `-nostdin` because ffmpeg's stdin is MuonTrap's flow-control channel;
    # see `BB.Camera.FFmpeg.Backend.MuonTrap`. `-flush_packets 1` keeps ffmpeg
    # from holding finished frames in its output buffer waiting for more;
    # without it a low-rate camera's frames arrive in lumps and the measured
    # latency is the buffer, not the camera.
    ["-nostdin", "-hide_banner", "-loglevel", "error"] ++
      input_argv(command) ++
      [
        "-an",
        "-vf",
        "scale=#{command.width}:#{command.height}:out_range=full,format=yuv420p",
        "-fps_mode",
        "passthrough",
        "-f",
        "rawvideo",
        "-flush_packets",
        "1",
        "pipe:1"
      ]
  end

  # ffmpeg's own default rate is NTSC's 29.97, which no camera tested here
  # lists, so the rate is always given explicitly.
  defp input_argv(%__MODULE__{source: {:device, device}} = command) do
    [
      "-f",
      "avfoundation",
      "-pixel_format",
      command.input_format,
      "-video_size",
      "#{command.width}x#{command.height}",
      "-framerate",
      FrameRate.to_string(command.frame_rate),
      "-i",
      device_argument(device)
    ]
  end

  defp input_argv(%__MODULE__{source: {:lavfi, filter}} = command) do
    graph =
      "#{filter}=size=#{command.width}x#{command.height}" <>
        ":rate=#{FrameRate.to_string(command.frame_rate)}"

    # A synthetic source has no hardware pacing it, so without `-re` ffmpeg
    # generates frames as fast as it can filter them - thousands a second, and
    # nothing like the camera it is standing in for.
    ["-re", "-f", "lavfi", "-i", graph]
  end

  defp device_argument(index) when is_integer(index), do: Integer.to_string(index)
  defp device_argument(name), do: name

  defp validate_source(opts) do
    case {Keyword.get(opts, :device), Keyword.get(opts, :lavfi)} do
      {nil, nil} -> {:error, {:no_source, nil}}
      {device, nil} -> with {:ok, device} <- validate_device(device), do: {:ok, {:device, device}}
      {nil, filter} -> with {:ok, name} <- validate_lavfi(filter), do: {:ok, {:lavfi, name}}
      {device, filter} -> {:error, {:no_source, {device, filter}}}
    end
  end

  defp validate_lavfi(filter) when is_binary(filter) do
    if Regex.match?(@format_pattern, filter) do
      {:ok, filter}
    else
      {:error, {:invalid_lavfi_source, filter}}
    end
  end

  defp validate_lavfi(filter), do: {:error, {:invalid_lavfi_source, filter}}

  defp validate_device(index) when is_integer(index) and index >= 0, do: {:ok, index}

  defp validate_device(name) when is_binary(name) do
    cond do
      String.trim(name) == "" -> {:error, {:invalid_device, name}}
      String.contains?(name, [<<0>>, ":"]) -> {:error, {:invalid_device, name}}
      String.starts_with?(name, "none") -> {:error, {:invalid_device, name}}
      true -> {:ok, name}
    end
  end

  defp validate_device(device), do: {:error, {:invalid_device, device}}

  defp validate_dimension(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp validate_dimension(value), do: {:error, {:invalid_dimension, value}}

  defp validate_frame_rate(value) do
    case FrameRate.new(value) do
      {:ok, frame_rate} -> {:ok, frame_rate}
      {:error, _reason} -> {:error, {:invalid_frame_rate, value}}
    end
  end

  defp validate_input_format(value) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> validate_input_format()

  defp validate_input_format(value) when is_binary(value) do
    if Regex.match?(@format_pattern, value) do
      {:ok, value}
    else
      {:error, {:invalid_input_format, value}}
    end
  end

  defp validate_input_format(value), do: {:error, {:invalid_input_format, value}}

  defp validate_executable(nil) do
    case System.find_executable("ffmpeg") do
      nil -> {:error, {:ffmpeg_not_found, "ffmpeg"}}
      path -> {:ok, path}
    end
  end

  defp validate_executable(path) when is_binary(path), do: {:ok, path}
  defp validate_executable(path), do: {:error, {:ffmpeg_not_found, path}}
end
