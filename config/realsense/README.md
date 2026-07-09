# RealSense camera configs

ROS 1 `realsense-ros` (pinned here at the 2.3.2 release, the last ROS 1
release) ships **no config YAML upstream** -- it exposes tuning only through
`rs_*.launch` arguments (`color_width`, `depth_fps`, `enable_infra1`, ...).
There is therefore **nothing official to vendor** and **no upstream drift
check** (unlike the ROS 2 sibling repo, whose upstream ships versioned config
YAMLs mirrored under `config/realsense/` for a drift baseline).

This directory holds:

- `99-realsense-libusb.rules` -- the vendored udev rules (pinned to the
  librealsense SDK tag; guarded by `script/check_udev_rules_sync.sh`).
- `config.yaml` -- a ROS 1 port of the ROS 2 upstream example config, kept for
  parity so the two repos carry the same reference profile (see below).
- `custom/` -- **our** camera profiles, in ROS 1 param form.

## How a profile is applied (`rs_camera_config.launch`)

ROS 1 realsense-ros has no `config_file` arg, so the repo owns a thin wrapper
launch, `launch/rs_camera_config.launch` (baked into the image as
`/rs_camera_config.launch`). It:

1. `<include>`s the stock `realsense2_camera/rs_aligned_depth.launch` unchanged,
2. sets `initial_reset` as a node param (it is a nodelet param, not an
   `rs_aligned_depth.launch` include arg), and
3. when a non-empty `config_file:=` is passed, `<rosparam command="load">`s that
   YAML into the node's private namespace (`camera/realsense2_camera`) **after**
   the include.

roslaunch sets every param before any node starts and the later write wins, so
the YAML overrides the launch defaults (verified with `roslaunch
--dump-params`). Params in the YAML use the node's flat ROS 1 names
(`color_width`, `depth_fps`, `enable_infra1`, ...), not the ROS 2 dotted keys.

```bash
roslaunch /rs_camera_config.launch                                    # stock defaults
roslaunch /rs_camera_config.launch config_file:=/camera_config.yaml   # apply a profile
```

The container CMD runs `roslaunch /rs_camera_config.launch initial_reset:=true`;
the entrypoint appends `config_file:=/camera_config.yaml` automatically when a
profile is baked in (see "Active profile").

## Active profile

The repo-root symlink `camera.yaml` selects the active profile. It defaults to
`custom/none.yaml`, an **empty** file that means "no profile -- stream the
stock upstream defaults" (640x480x30). Docker bakes the symlink *target* into
the image as `/camera_config.yaml`; when that file is non-empty the entrypoint
appends `config_file:=/camera_config.yaml` to the launch, otherwise the
container launches with the stock defaults exactly as before.

Switch profiles by repointing the symlink or overriding the build arg:

```bash
ln -sf config/realsense/custom/usb2.yaml camera.yaml   # activate USB 2 profile
ln -sf config/realsense/custom/none.yaml camera.yaml   # back to stock defaults
just build --build-arg CAMERA_CONFIG=config/realsense/custom/usb2.yaml
```

## `config.yaml` (ROS 1 port of the ROS 2 example)

The ROS 2 upstream ships an example `config.yaml`; the ROS 1 upstream ships
nothing equivalent. We keep a same-meaning ROS 1 port here for parity and as a
ready reference, translated to ROS 1 param names:

| ROS 2 upstream | ROS 1 port |
|----------------|------------|
| `rgb_camera.color_profile: 1280x720x15` | `color_width/height/fps: 1280/720/15` |
| `align_depth.enable` | `align_depth` |
| `enable_color` / `enable_depth` / `enable_sync` | same names |
| `publish_tf` / `tf_publish_rate` | *omitted -- ROS 2 only* |

`publish_tf` / `tf_publish_rate` have no `rs_aligned_depth.launch` counterpart:
ROS 1 realsense-ros publishes the static TF tree by default, so the keys are
simply dropped in the port.

It is not wired to any build arg by default -- point `camera.yaml` at it (or
pass `--build-arg CAMERA_CONFIG=config/realsense/config.yaml`) to use it.

## `custom/` profiles

| File | Purpose |
|------|---------|
| `none.yaml` | Empty (0 bytes) -- stock upstream defaults (640x480x30). Default. |
| `usb2.yaml` | USB 2.x fallback: color 640x480@15, depth 480x270@15, aligned depth on, IR + IMU off. |

### `usb2.yaml` rationale

A D435/D455 on a USB 2 link cannot sustain the stock 640x480x30 color + depth:
the camera negotiates the link but delivers **0 frames** at 30 fps. The profile
trims bandwidth until the streams fit a 480 Mbps link:

- **color 640x480 @ 15 fps** -- 30 fps yields 0 frames on USB 2; 15 fps streams.
- **depth 480x270 @ 15 fps** -- depth is dropped below color so both fit the link
  side by side.
- **aligned depth on** -- the aligned-depth topic is the point of the image.
- **IR (`enable_infra1/2`) and IMU (`enable_gyro/accel`) off** -- both are pure
  bandwidth the USB 2 link cannot spare.

This was validated on a Raspberry Pi 5 (arm64) whose USB 3 ports could not bring
a D455 up to SuperSpeed; the camera fell back to USB 2 and only streamed with
this profile. See the repo issues for the full diagnosis.
