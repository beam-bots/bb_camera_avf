# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.AVF.DevicesTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias BB.Camera.AVF.Devices
  alias Mix.Tasks.BbCameraAvf.Scan

  doctest BB.Camera.AVF.Devices

  # Captured from ffmpeg 9.0.2 on macOS 27, with a USB webcam plugged in.
  @listing """
  [AVFoundation indev @ 0x76c100c140] AVFoundation video devices:
  [AVFoundation indev @ 0x76c100c140] [0] HD Pro Webcam C920
  [AVFoundation indev @ 0x76c100c140] [1] FaceTime HD Camera
  [AVFoundation indev @ 0x76c100c140] [2] Capture screen 0
  [AVFoundation indev @ 0x76c100c140] [3] Capture screen 1
  [AVFoundation indev @ 0x76c100c140] AVFoundation audio devices:
  [AVFoundation indev @ 0x76c100c140] [0] USB Advanced Audio Device
  [AVFoundation indev @ 0x76c100c140] [1] HD Pro Webcam C920
  [in#0 @ 0x76c100c000] Error opening input: Input/output error
  Error opening input file .
  Error opening input files: Input/output error
  """

  describe "parse/1" do
    test "reads cameras and screens, and nothing from the audio list" do
      assert {:ok, devices} = Devices.parse(@listing)

      assert devices == [
               %{index: 0, name: "HD Pro Webcam C920", kind: :camera},
               %{index: 1, name: "FaceTime HD Camera", kind: :camera},
               %{index: 2, name: "Capture screen 0", kind: :screen},
               %{index: 3, name: "Capture screen 1", kind: :screen}
             ]
    end

    test "leaves the unique ID newer ffmpeg appends out of the name" do
      output = """
      [AVFoundation indev @ 0x1] AVFoundation video devices:
      [AVFoundation indev @ 0x1] [0] HD Pro Webcam C920  [uid:0x21300000046d0892]  [serial:ABC123]
      [AVFoundation indev @ 0x1] AVFoundation audio devices:
      """

      assert {:ok, [%{name: "HD Pro Webcam C920"}]} = Devices.parse(output)
    end

    test "finds no devices in a listing that has none" do
      output = """
      [AVFoundation indev @ 0x1] AVFoundation video devices:
      [AVFoundation indev @ 0x1] AVFoundation audio devices:
      """

      assert {:ok, []} = Devices.parse(output)
    end

    test "says so when ffmpeg has no AVFoundation input at all" do
      output = "Unknown input format: 'avfoundation'\n"

      assert {:error, {:no_avfoundation, "Unknown input format: 'avfoundation'"}} =
               Devices.parse(output)
    end
  end

  describe "list/1" do
    test "reports an ffmpeg that is not there" do
      assert {:error, {:ffmpeg_not_found, "ffmpeg"}} =
               with_path("", fn -> Devices.list() end)
    end

    @tag :ffmpeg
    @tag :macos
    test "asks the real ffmpeg" do
      assert {:ok, devices} = Devices.list()
      assert Enum.all?(devices, &(&1.kind in [:camera, :screen]))
    end
  end

  describe "mix bb_camera_avf.scan" do
    @describetag :ffmpeg
    @describetag :macos

    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    test "prints each camera and a sensor to paste" do
      {:ok, devices} = Devices.list()
      Scan.run([])

      for %{kind: :camera, index: index, name: name} <- devices do
        assert_received {:mix_shell, :info, ["  [" <> _ = line]}
        assert line == "  [#{index}] #{name}"
      end
    end
  end

  defp with_path(path, fun) do
    original = System.get_env("PATH")
    System.put_env("PATH", path)

    try do
      fun.()
    after
      System.put_env("PATH", original)
    end
  end
end
