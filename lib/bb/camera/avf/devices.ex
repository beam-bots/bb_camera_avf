# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.AVF.Devices do
  @moduledoc """
  The video devices ffmpeg's AVFoundation input can see.

  This asks ffmpeg rather than AVFoundation, because ffmpeg is what will open
  the camera: a name is only useful as a `:device` option if it is the name
  ffmpeg matches against, spelled the way ffmpeg spells it.

  ffmpeg lists screens alongside cameras, after them, as `Capture screen N`.
  They are video devices ffmpeg can open, so they are reported, but marked as
  screens rather than cameras.

  Listing does not open any device, and needs no camera access.
  """

  @type kind :: :camera | :screen

  @type device :: %{index: non_neg_integer(), name: String.t(), kind: kind()}

  @video_header "AVFoundation video devices:"
  @audio_header "AVFoundation audio devices:"

  @doc """
  Ask ffmpeg for its video devices.

  Returns `{:error, {:no_avfoundation, output}}` when ffmpeg's output has no
  device listing at all, which is what an ffmpeg without an AVFoundation input
  — any ffmpeg not built for macOS — produces. `output` is ffmpeg's own
  explanation.

  ## Options

  - `:executable` — path to ffmpeg. Defaults to whatever is on `$PATH`.
  """
  @spec list(keyword()) :: {:ok, [device()]} | {:error, term()}
  def list(opts \\ []) do
    with {:ok, executable} <- executable(opts) do
      # ffmpeg exits non-zero here even when listing worked: `""` is not a
      # device it can open, and listing is a side effect of trying.
      {output, _status} =
        System.cmd(
          executable,
          ["-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""],
          stderr_to_stdout: true
        )

      parse(output)
    end
  end

  @doc """
  Read the video devices out of ffmpeg's `-list_devices` output.

      iex> output = \"\"\"
      ...> [AVFoundation indev @ 0x1] AVFoundation video devices:
      ...> [AVFoundation indev @ 0x1] [0] FaceTime HD Camera
      ...> [AVFoundation indev @ 0x1] [1] Capture screen 0
      ...> [AVFoundation indev @ 0x1] AVFoundation audio devices:
      ...> [AVFoundation indev @ 0x1] [0] MacBook Pro Microphone
      ...> \"\"\"
      iex> BB.Camera.AVF.Devices.parse(output)
      {:ok,
       [
         %{index: 0, name: "FaceTime HD Camera", kind: :camera},
         %{index: 1, name: "Capture screen 0", kind: :screen}
       ]}
  """
  @spec parse(String.t()) :: {:ok, [device()]} | {:error, {:no_avfoundation, String.t()}}
  def parse(output) do
    lines = String.split(output, "\n")

    if Enum.any?(lines, &String.ends_with?(&1, @video_header)) do
      {:ok,
       lines
       |> Enum.drop_while(&(not String.ends_with?(&1, @video_header)))
       |> Enum.drop(1)
       |> Enum.take_while(&(not String.ends_with?(&1, @audio_header)))
       |> Enum.flat_map(&device/1)}
    else
      {:error, {:no_avfoundation, String.trim(output)}}
    end
  end

  # Newer ffmpeg follows the name with `[uid:...]` and sometimes
  # `[serial:...]`, separated by two spaces. The name itself can hold single
  # spaces but not that.
  defp device(line) do
    case Regex.run(~r/\] \[(\d+)\] (.+?)(?:  \[uid:.*)?$/, line) do
      [_line, index, name] ->
        [%{index: String.to_integer(index), name: name, kind: kind(name)}]

      nil ->
        []
    end
  end

  defp kind("Capture screen " <> _number), do: :screen
  defp kind(_name), do: :camera

  defp executable(opts) do
    case Keyword.get(opts, :executable) || System.find_executable("ffmpeg") do
      nil -> {:error, {:ffmpeg_not_found, "ffmpeg"}}
      path -> {:ok, path}
    end
  end
end
