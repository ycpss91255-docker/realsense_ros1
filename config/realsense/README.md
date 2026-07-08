# RealSense camera configs

ROS 1 `realsense-ros` (pinned here at the 2.3.2 release, the last ROS 1
release) ships **no config YAML upstream** -- it exposes tuning only through
`rs_*.launch` arguments (`color_width`, `depth_fps`, `enable_infra1`, ...).
There is therefore **nothing official to vendor** and **no upstream drift
check** (unlike the ROS 2 sibling repo, whose upstream ships versioned config
YAMLs mirrored under `config/realsense/` for a drift baseline).

Consequently this directory holds only:

- `99-realsense-libusb.rules` -- the vendored udev rules (pinned to the
  librealsense SDK tag; guarded by `script/check_udev_rules_sync.sh`).
- `custom/` -- **our** camera profiles, in ROS 1 param form (flat
  `key: value`, keys are the `rs_aligned_depth.launch` arg names).

## Active profile

The repo-root symlink `camera.yaml` selects the active profile. It defaults to
`custom/none.yaml`, an **empty** file that means "no profile -- stream the
stock upstream defaults" (640x480x30). Docker bakes the symlink *target* into
the image as `/camera_config.yaml`; when that file is non-empty the entrypoint
applies it, otherwise the container launches with the stock defaults exactly as
before.

Switch profiles by repointing the symlink or overriding the build arg:

```bash
ln -sf config/realsense/custom/usb2.yaml camera.yaml   # activate USB 2 profile
ln -sf config/realsense/custom/none.yaml camera.yaml   # back to stock defaults
just build --build-arg CAMERA_CONFIG=config/realsense/custom/usb2.yaml
```

## `custom/` profiles

| File | Purpose |
|------|---------|
| `none.yaml` | Empty (0 bytes) -- stock upstream defaults (640x480x30). Default. |
| `usb2.yaml` | USB 2.x fallback: color 640x480@15, depth 480x270@15, aligned depth on, IR + IMU off. |
