# RealSense containers run privileged

- **Date:** 2026-06-25
- **Status:** Accepted

## Context

`config/docker/setup.conf` runs the container with `privileged = true` and a
live bind of the whole host `/dev`. On its face this looks over-broad for a
single USB camera (a reader's instinct -- and the original audit, #64 -- is to
narrow it to `privileged = false` + `/dev/bus/usb` + a device-cgroup
allow-list). This ADR records why that narrowing was tried, what it cost, and
why privileged is kept, so it is not blindly re-attempted.

We tested the narrowing end-to-end on a physical D455. A `privileged = false`
config -- live `/dev` bind + device-cgroup allow-list (`c 189:* rwm` USB,
`c 81:* rwm` V4L2, `c 226:* rwm` DRM) -- **does** work for depth + color + the
GUI tools + USB hot-plug, and correctly gates access (disk/other majors stay
unopenable though visible). But the full D455 feature set defeats it:

- **Depth/color use the V4L2 backend.** The apt/ROS `librealsense` streams over
  `/dev/video*` + `/dev/media*`, which live directly in `/dev` root and are
  **renumbered on every (re)plug**. There is no stable sub-`/dev` subtree to
  bind, so the whole `/dev` must be (live-)bound -- `/dev/bus/usb`-only makes the
  camera undetectable.
- **The IMU (accel/gyro) uses the HID/IIO path.** Enabling it *writes*
  `/sys/bus/iio/.../scan_elements/*` + buffer, but:
  - the **docker-default AppArmor** profile blocks `/sys` writes (even as root)
    -- needs `security_opt: apparmor:unconfined`;
  - the container `/sys` is read-only -- needs a `/sys:/sys` rw bind;
  - the IIO buffer char device `/dev/iio:deviceN` uses a **dynamically-allocated
    major** (505 on the test host, also `235` for media) that a fixed cgroup
    allow-list cannot track across reboots / kernels / hosts.

  (Unbinding the kernel `hid-sensor` driver to read the IMU over libusb instead
  was also tested: it just makes the IMU disappear -- this build only reads the
  IMU via IIO.)

A `privileged = false` config that streamed the IMU did exist (allow-list +
`/sys:/sys` rw + `apparmor:unconfined` + a hardcoded iio-major rule), but those
residual relaxations -- AppArmor off, `/sys` writable, fragile dynamic-major
rules that silently break the IMU after a reboot -- **approximate privileged
anyway**, for little net security gain and real fragility.

This is the ROS 1 (Noetic) sibling of the same camera stack; the constraint is
on `librealsense` + the kernel V4L2/IIO backends, not on the ROS version, so the
finding carries over from `realsense_ros2` unchanged.

## Decision

Keep `privileged = true` with a live `/dev` bind for the RealSense containers.
The full D4xx feature set (V4L2 streaming + HID/IIO IMU) requires
privileged-level access on this stack; a partial `privileged = false` config
trades a small, mostly-illusory security gain for real fragility.

Two cleanups that *are* kept (the actionable part of #64):

- Drop the `cap_add` (`SYS_ADMIN`/`NET_ADMIN`/`MKNOD`) and `security_opt`
  (`seccomp:unconfined`) entries -- under `privileged = true` they are no-ops,
  and listing them falsely implies access is scoped to them.
- Bind `/dev` as a `[volumes]` live mount rather than a `[devices]` snapshot, so
  hot-plug / firmware-DFU re-enumeration is visible without a container restart.

## Consequences

- The container has full host device + kernel access. This is acceptable for a
  developer-facing hardware-bringup image (its purpose is talking to the camera),
  but it is **not** a hardening baseline; do not copy this posture to a
  network-facing or multi-tenant deployment.
- Revisit only if the constraints change: e.g. base grows auto-detection for the
  dynamic iio/media majors (so the cgroup allow-list can track them), or
  `librealsense` is built/configured to read the IMU over libusb. Until then,
  `privileged = false` for a fully-featured D4xx is a dead end -- see #64.
