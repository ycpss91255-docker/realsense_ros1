**[English](CAMERA.md)** | **[繁體中文](CAMERA.zh-TW.md)** | **[简体中文](CAMERA.zh-CN.md)** | **[日本語](CAMERA.ja.md)**

# Testing with a physical RealSense camera

`TEST.md` covers the automatic build-time smoke tests. This page is the manual
procedure for verifying a real Intel RealSense camera through the container.

The container runs `privileged` with `/dev` mounted, so it sees USB devices on
the host. The image ships the ROS 1 wrapper (`realsense2_camera`) plus the
librealsense SDK CLI tools (`rs-enumerate-devices`, `realsense-viewer`, `rs-*`).

## 0. Confirm the host sees the camera

```bash
lsusb | grep -i intel    # e.g. Intel RealSense (8086:0b07)
```

If nothing shows: use a data-capable cable, prefer a USB 3.0 port, and make
sure no other process holds the camera.

## 1. Enter the container

```bash
just build    # first time, or after changes
just run      # interactive shell; ROS is auto-sourced (via ~/.bashrc.d)
```

## 2. Quick check -- is the camera detected (SDK level)

```bash
rs-enumerate-devices        # lists model / serial / firmware
rs-enumerate-devices -s     # short form
```

Passing this confirms the camera, driver, and USB permissions all work.

## 3. ROS 1 integration (the repo's primary use case)

Start the camera node:

```bash
roslaunch realsense2_camera rs_camera.launch
```

In a second shell into the same container (`just exec bash` from the host):

```bash
rostopic list                                   # expect /camera/... topics
rostopic hz /camera/depth/image_rect_raw        # confirm streaming (Hz)
rostopic echo /camera/color/image_raw -n 1      # one message
```

Interactive shells (`just run` and `just exec bash`) auto-source ROS via
`~/.bashrc.d`. Only a non-interactive `just exec <cmd>` (which does not read
`.bashrc`) needs `source /opt/ros/${ROS_DISTRO}/setup.bash` first.

> The colour topic is `/camera/color/image_raw` and depth is
> `/camera/depth/image_rect_raw` -- a single `/camera/` namespace. (Enabling
> `align_depth:=true` adds `/camera/aligned_depth_to_color/image_raw`.)

## 4. Visualize (GUI)

```bash
realsense-viewer    # librealsense GUI
rviz                # ROS 1 visualization
```

The devel image installs the ROS 1 desktop tooling, so both `realsense-viewer`
and `rviz` (plus the Qt/OpenGL/X stack they need) are available. The container's
GUI mode + X11 mounts handle the display.

## 5. On-chip calibration (optional)

The D400 series can re-calibrate its stereo depth parameters from a normal scene
-- no calibration target needed. Depth is computed by stereo-matching the two IR
cameras, and the factory parameters drift over time (temperature, mechanical
shock, transport, ageing), which shows up as extra depth noise, non-flat planes,
or noisy edges. On-chip calibration corrects that drift. It is independent of a
firmware update: firmware changes the camera's firmware version, calibration
adjusts the depth-measurement parameters. Running it once after a firmware update
is a good sanity check.

Run it from `realsense-viewer`: open the depth sensor's **More** menu and pick
**On-Chip Calibration**, then point at a suitable scene and press calibrate.

Scene requirements:

- Textured, **0.5--2 m** away, with **> 50% valid depth pixels** (avoid a blank
  wall, highly reflective surfaces, or anything too far).
- The "White wall" sub-mode is the exception: use it **only** when pointing at a
  flat white wall with the IR projector on.

### Reading the health-check score

After calibrating, the viewer reports a health-check score. **What matters is its
absolute value** -- the sign only encodes the direction of the correction, not
"better" or "worse". The viewer's `if >0.25` guidance means `|health| > 0.25`.

| `|health|` | Meaning | Action |
|---|---|---|
| near 0 (< 0.25) | Already well calibrated; this run barely changed anything | No need to apply |
| >= 0.25 | Noticeable drift; the correction is meaningful | Apply the new calibration |
| large (e.g. > 0.75) | Heavy drift, or an unsuitable scene | Apply, then re-run on a better scene to confirm |

So a score of `-0.45` is `|0.45| > 0.25`: meaningful drift was detected, and
applying the new calibration is recommended. A negative sign does **not** mean
the calibration failed. After applying, check the depth image in
`realsense-viewer` (flatter planes, less noise); to be safe, re-run on a
different scene -- a score back near 0 means the calibration has converged.

A target-based path (the Dynamic Calibration Tool, which also re-calibrates the
depth-to-colour extrinsics) is described in [CALIBRATION.md](CALIBRATION.md).

## Troubleshooting

| Symptom | Check |
|---|---|
| `No device detected` | Host `lsusb` sees the camera? cable / USB 3.0 port / not held by another process. Container is `privileged` (default). |
| `roslaunch: command not found` | Interactive shells auto-source ROS via `~/.bashrc.d`. Only a non-interactive `just exec <cmd>` needs `source /opt/ros/${ROS_DISTRO}/setup.bash` first. |
| Topics carry no data / `Reduced performance ... 2.1 port` | Link negotiated USB 2.x. Use a lower profile (`depth_width:=480 depth_height:=270 depth_fps:=6 color_width:=424 color_height:=240 color_fps:=6`, ~6 Hz on a D435) or a USB 3 SuperSpeed port direct to the host. |
| `realsense-viewer` will not open (X11) | Host has an X server; `echo $DISPLAY` is set; GUI mode is `[gui] mode = auto` in `config/docker/setup.conf`. |
