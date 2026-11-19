# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.BbCameraAvf.Scan do
  @shortdoc "Scan for cameras ffmpeg can capture from"
  @moduledoc """
  Lists the cameras ffmpeg's AVFoundation input can see, by the name to use
  as `BB.Camera.AVF`'s `:device` option.

  Listing opens no camera and needs no camera access. Screens, which ffmpeg
  lists after the cameras, are counted but not shown.

  ## Usage

      mix bb_camera_avf.scan [OPTIONS]

  ## Options

    * `--ffmpeg` - Path to the ffmpeg executable (default: the one on `$PATH`)

  ## Finding a camera's sizes and rates

  ffmpeg prints every mode a camera supports when asked for one it does not
  have:

      ffmpeg -hide_banner -f avfoundation -framerate 1 -video_size 640x480 \\
        -i "FaceTime HD Camera" -frames:v 1 -f null -
  """

  use Mix.Task

  alias BB.Camera.AVF.Devices

  @switches [ffmpeg: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _args} = OptionParser.parse!(args, strict: @switches)

    case Devices.list(executable: opts[:ffmpeg]) do
      {:ok, devices} ->
        report(devices)

      {:error, {:no_avfoundation, ""}} ->
        Mix.shell().error("This ffmpeg listed no AVFoundation devices, and printed nothing.")
        exit({:shutdown, 1})

      {:error, {:no_avfoundation, output}} ->
        Mix.shell().error("This ffmpeg has no AVFoundation input. It said:\n\n#{output}")
        exit({:shutdown, 1})

      {:error, {:ffmpeg_not_found, _name}} ->
        Mix.shell().error("ffmpeg is not on $PATH. Install it with `brew install ffmpeg`.")
        exit({:shutdown, 1})
    end
  end

  defp report(devices) do
    {cameras, screens} = Enum.split_with(devices, &(&1.kind == :camera))

    case cameras do
      [] ->
        Mix.shell().info("No cameras found.")

      [first | _rest] ->
        Mix.shell().info("Cameras:\n")
        Enum.each(cameras, &Mix.shell().info("  [#{&1.index}] #{&1.name}"))

        Mix.shell().info("""

        Use the name, not the number - numbers move when cameras are plugged in:

            sensor :eye, {BB.Camera.AVF, device: #{inspect(first.name)}}

        `mix help bb_camera_avf.scan` shows how to find a camera's sizes and rates.
        """)
    end

    report_screens(length(screens))
  end

  defp report_screens(0), do: :ok
  defp report_screens(1), do: Mix.shell().info("1 screen not shown.")
  defp report_screens(count), do: Mix.shell().info("#{count} screens not shown.")
end
