# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.AVF.CommandTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias BB.Camera.AVF.Command
  alias BB.Error.Invalid.Camera.UnsupportedFormat

  doctest BB.Camera.AVF.Command

  defp options(overrides \\ []) do
    Keyword.merge(
      [
        device: "FaceTime HD Camera",
        width: 640,
        height: 480,
        frame_rate: 30,
        executable: "/usr/bin/ffmpeg"
      ],
      overrides
    )
  end

  describe "new/1" do
    test "accepts arbitrary positive even dimensions" do
      assert {:ok, command} = Command.new(options(width: 2, height: 2))
      assert {command.width, command.height} == {2, 2}

      assert {:ok, command} = Command.new(options(width: 3840, height: 2160))
      assert {command.width, command.height} == {3840, 2160}

      assert {:ok, command} = Command.new(options(width: 1234, height: 566))
      assert "1234x566" in Command.argv(command)
    end

    test "rejects odd dimensions, which I420 cannot take" do
      assert {:error, %UnsupportedFormat{reason: :invalid_dimensions, width: 641}} =
               Command.new(options(width: 641))

      assert {:error, %UnsupportedFormat{reason: :invalid_dimensions, height: 481}} =
               Command.new(options(height: 481))
    end

    test "knows the size of one frame of what it writes" do
      assert {:ok, command} = Command.new(options(width: 1280, height: 720))
      assert command.frame_bytes == div(1280 * 720 * 3, 2)
    end

    test "rejects dimensions that are not positive integers" do
      assert {:error, {:invalid_dimension, 0}} = Command.new(options(width: 0))
      assert {:error, {:invalid_dimension, -1}} = Command.new(options(height: -1))
      assert {:error, {:invalid_dimension, "640"}} = Command.new(options(width: "640"))
      assert {:error, {:invalid_dimension, 640.0}} = Command.new(options(width: 640.0))
    end

    test "keeps an exact rational frame rate" do
      assert {:ok, command} = Command.new(options(frame_rate: {30_000, 1001}))
      assert "30000/1001" in Command.argv(command)
    end

    test "accepts a frame rate as a hertz unit" do
      import BB.Unit

      assert {:ok, command} = Command.new(options(frame_rate: ~u(15 hertz)))
      assert "15" in Command.argv(command)
    end

    test "rejects a frame rate that is not positive" do
      assert {:error, {:invalid_frame_rate, 0}} = Command.new(options(frame_rate: 0))
      assert {:error, {:invalid_frame_rate, -5}} = Command.new(options(frame_rate: -5))
      assert {:error, {:invalid_frame_rate, {30, 0}}} = Command.new(options(frame_rate: {30, 0}))
    end

    test "passes a camera name through as ffmpeg's input" do
      assert {:ok, command} = Command.new(options(device: "HD Pro Webcam C920"))
      assert argv_pair(command, "-i") == "HD Pro Webcam C920"
    end

    test "accepts a camera index" do
      assert {:ok, command} = Command.new(options(device: 1))
      assert argv_pair(command, "-i") == "1"
    end

    test "accepts the system's default camera" do
      assert {:ok, command} = Command.new(options(device: "default"))
      assert argv_pair(command, "-i") == "default"
    end

    test "rejects a name ffmpeg would split into a video and an audio device" do
      assert {:error, {:invalid_device, "Camera: Left"}} =
               Command.new(options(device: "Camera: Left"))
    end

    test "rejects a name ffmpeg would read as no video at all" do
      assert {:error, {:invalid_device, "none"}} = Command.new(options(device: "none"))
    end

    test "rejects an empty name, a null byte and a negative index" do
      assert {:error, {:invalid_device, " "}} = Command.new(options(device: " "))
      assert {:error, {:invalid_device, _}} = Command.new(options(device: "Camera" <> <<0>>))
      assert {:error, {:invalid_device, -1}} = Command.new(options(device: -1))
    end

    test "rejects a pixel format that is not a format name" do
      assert {:error, {:invalid_input_format, "nv12; rm -rf /"}} =
               Command.new(options(input_format: "nv12; rm -rf /"))

      assert {:error, {:invalid_input_format, "-i"}} = Command.new(options(input_format: "-i"))
    end

    test "accepts any plausible format name without a list of its own" do
      for format <- [:uyvy422, :yuyv422, :nv12, "bgr0"] do
        assert {:ok, _command} = Command.new(options(input_format: format))
      end
    end
  end

  describe "argv/1" do
    test "forces full-range I420 at the requested size, whatever the camera delivers" do
      {:ok, command} = Command.new(options(input_format: :uyvy422, width: 1280, height: 720))

      assert argv_pair(command, "-pixel_format") == "uyvy422"
      assert argv_pair(command, "-vf") == "scale=1280:720:out_range=full,format=yuv420p"
      assert Command.format() == {:raw, :I420}
    end

    test "never stream-copies, which would put AVFoundation's padding on the pipe" do
      {:ok, command} = Command.new(options())

      refute "-c:v" in Command.argv(command)
      refute "copy" in Command.argv(command)
    end

    test "asks for nv12 unless told otherwise" do
      {:ok, command} = Command.new(options())

      assert argv_pair(command, "-pixel_format") == "nv12"
    end

    test "never invents frames to reach the requested rate" do
      {:ok, command} = Command.new(options())
      argv = Command.argv(command)

      assert argv_pair(command, "-fps_mode") == "passthrough"
      refute "-r" in argv
    end

    test "always states the frame rate, since ffmpeg's default suits no camera" do
      {:ok, command} = Command.new(options(frame_rate: 15))

      assert argv_pair(command, "-framerate") == "15"
    end

    test "writes to stdout, never to a file" do
      {:ok, command} = Command.new(options())
      argv = Command.argv(command)

      assert List.last(argv) == "pipe:1"
      assert argv_pair(command, "-f") == "avfoundation"

      output_format =
        argv
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.filter(&match?(["-f", _format], &1))
        |> List.last()

      assert output_format == ["-f", "rawvideo"]
    end

    test "never produces an argument that is not a plain string" do
      {:ok, command} = Command.new(options(frame_rate: {30_000, 1001}, width: 1280, height: 720))

      assert Enum.all?(Command.argv(command), &is_binary/1)
    end
  end

  defp argv_pair(command, flag) do
    argv = Command.argv(command)

    Enum.at(argv, Enum.find_index(argv, &(&1 == flag)) + 1)
  end
end
