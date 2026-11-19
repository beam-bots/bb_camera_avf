# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.BbCameraAvf.Install do
    @shortdoc "Installs BB.Camera.AVF into a robot"
    @moduledoc """
    #{@shortdoc}

    Adds a `:config.:camera` param group holding the camera name and geometry,
    writes the camera default to the robot's parameters, and imports
    `bb_camera_avf` into your formatter.

    The camera itself belongs on a specific link — whichever one it is bolted
    to — and the installer cannot guess which, so it prints a snippet to paste
    into the topology.

    ## Example

    ```bash
    mix igniter.install bb_camera_avf
    mix igniter.install bb_camera_avf --device "HD Pro Webcam C920"
    ```

    ## Options

    * `--robot` - The robot module (defaults to `{AppPrefix}.Robot`).
    * `--device` - The camera's name as ffmpeg lists it (default `default`,
      the system's default camera).
    """

    use Igniter.Mix.Task

    alias Igniter.Project.Formatter

    @param_group :camera
    @default_device "default"

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        schema: [robot: :string, device: :string],
        aliases: [r: :robot, d: :device]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      robot_module = BB.Igniter.robot_module(igniter)
      device = Keyword.get(igniter.args.options, :device, @default_device)

      igniter
      |> Formatter.import_dep(:bb_camera_avf)
      |> BB.Igniter.add_param_group(robot_module, [:config, @param_group], param_group_body())
      |> BB.Igniter.set_robot_param_default(
        robot_module,
        [:config, @param_group, :device],
        device
      )
      |> Igniter.add_notice(topology_snippet())
    end

    defp param_group_body do
      """
      param :device, type: :string, doc: "Camera name as ffmpeg lists it, or \\"default\\""

      param :width, type: :integer, default: 640, doc: "Width in pixels to ask the device for"

      param :height, type: :integer, default: 480, doc: "Height in pixels to ask the device for"
      """
    end

    defp topology_snippet do
      """
      bb_camera_avf: add a camera to whichever link it is mounted on. Example:

          link :head do
            sensor :eye, {BB.Camera.AVF,
              device: param([:config, :camera, :device]),
              width: param([:config, :camera, :width]),
              height: param([:config, :camera, :height]),
              frame_rate: 30
            }
          end

      List the cameras ffmpeg can see, by name:

          mix bb_camera_avf.scan

      Ask for a size the camera does not support and ffmpeg prints every mode
      it does. The app you start the VM from needs camera access in System
      Settings > Privacy & Security > Camera.
      """
    end
  end
else
  defmodule Mix.Tasks.BbCameraAvf.Install do
    @shortdoc "Installs BB.Camera.AVF into a robot"
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The bb_camera_avf.install task requires igniter.

          mix igniter.install bb_camera_avf
      """)

      exit({:shutdown, 1})
    end
  end
end
