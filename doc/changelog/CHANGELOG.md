**[English](CHANGELOG.md)** | **[繁體中文](CHANGELOG.zh-TW.md)** | **[简体中文](CHANGELOG.zh-CN.md)** | **[日本語](CHANGELOG.ja.md)**

# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `LICENSE` (Apache 2.0) and CI / License badges in
  `README.md` + 3 translated READMEs (#40). Fresh add
  -- repo previously had no LICENSE and no badges. Aligns with
  the org-wide Apache 2.0 migration tracked across 17 sister
  repos.
- `doc/adr/00000001-realsense-requires-privileged.md` (this repo's first
  repo-specific ADR): records why the RealSense containers keep
  `privileged = true` (the full D4xx feature set -- V4L2 streaming + HID/IIO
  IMU -- needs privileged-level access; a `privileged = false` config was tested
  end-to-end on a D455 and rejected as fragile). ROS 1 sibling of the
  realsense_ros2 ADR (#64).
- `script/install_udev_rules.sh`: host-side one-shot installer that copies the
  bundled RealSense udev rules to `/etc/udev/rules.d/` and reloads udev. The
  in-image rules alone are not enough (the container has no `udevd`); without
  the host rules the non-root container user cannot open the raw USB node and
  the SDK misdetects the camera. Ships executable (0755); guarded by a new
  `test/smoke/install_udev_rules.bats` (incl. an `is executable` regression
  test). ROS 1 parity with realsense_ros2 (#69).
- `config/shell/bashrc.d/10-ros-source.sh`: source ROS 1 for interactive shells
  so `roslaunch` / `roscore` / `realsense-viewer` are on PATH in `just run` /
  `just exec` shells (the base bashrc is ROS-agnostic). Guarded by a new
  `ros_env.bats` test. nounset-safe (ROS 1 `setup.bash` reads `$ROS_MASTER_URI`)
  (#61, base#657).

### Changed
- `config/docker/setup.conf`: remove the dead `cap_add`
  (`SYS_ADMIN`/`NET_ADMIN`/`MKNOD`) and `security_opt` (`seccomp:unconfined`)
  entries -- under `privileged = true` they are no-ops (#64). Move `/dev` from a
  `[devices]` snapshot to a `[volumes]` live bind so hot-plug / firmware-DFU
  re-enumeration is visible without a container restart. `privileged = true` is
  kept and documented (rationale in
  `doc/adr/00000001-realsense-requires-privileged.md`); hardware testing on a
  D455 confirmed the full feature set needs it.
- `config/docker/setup.conf`: migrate the `[deploy] runtime` key to its
  v0.41.0 name `gpu_runtime` (base#481; the old key is a permanent alias, but
  align before the v1.0.0 removal) (#58).

### Fixed
- revert display mount to XDG_RUNTIME_DIR:rw
- use tmpfs for XDG_RUNTIME_DIR + Wayland socket mount
- Restore `.env.example` (removed during APT-mirror refactor) so `setup.sh`'s IMAGE_NAME detection has its documented fallback. Without this, any checkout under a non-`docker_*` / non-`*_ws` directory name falls through to `IMAGE_NAME=unknown`.

### Changed
- Align README.md to template framework: move H1 above the language switch link, add CI status badge, promote TL;DR blockquote to `## TL;DR` H2, add `## Overview` section, extend Table of Contents. Translations untouched.

## [v2.0.0] - 2026-03-28

### Added
- migrate from docker_setup_helper to template
- add Wayland display support for X11/Wayland dual compatibility

### Changed
- remove docker_setup_helper subtree and local CI workflows
- add docker_setup_helper subtree
- Squashed 'docker_setup_helper/' content from commit 0141a19
- upgrade to full env-level architecture

### Fixed
- add missing backslash in Dockerfile RUN continuation

## [v1.0.0] - 2026-03-25

### Added
- initial realsense_noetic repo

