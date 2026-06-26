**[English](CHANGELOG.md)** | **[繁體中文](CHANGELOG.zh-TW.md)** | **[简体中文](CHANGELOG.zh-CN.md)** | **[日本語](CHANGELOG.ja.md)**

# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Removed
- Legacy `.env.example`. base v0.41.0's `detect_image_name` resolves
  `IMAGE_NAME` from `config/docker/setup.conf` `[image]` rules (here the
  `@basename` fallback -> `realsense_ros1`), so the committed `.env.example`
  fallback is no longer read. Verified: `just setup apply` emits
  `IMAGE_NAME=realsense_ros1` to `.env.generated` without it (#56).

### Added
- `ros-${ROS_DISTRO}-desktop` in the `devel` image (#61): rviz + rqt (incl.
  `rqt_image_view`) + the Qt/OpenGL/X stack the GUI tools need. The README RGB-D
  demo's visual step (`rosrun rqt_image_view rqt_image_view` from `devel`) now
  has the binary it documents. The minimal `runtime` image stays on `ros-base`.
  Guarded by a new `ros_env.bats` test. ROS 1 parity with realsense_ros2.
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
- README TL;DR + Quick Start now demonstrate the actual RGB-D **app**: `just run
  -t runtime` launches the camera node (default CMD `roslaunch realsense2_camera
  rs_camera.launch`), with a CLI check (`rostopic hz` on the colour + depth
  topics `/camera/color/image_raw` and `/camera/depth/image_rect_raw`) and a
  visual demo (`rqt_image_view` in the `devel` image) to see RGB + depth.
  Clarifies `just run` (devel shell) vs `just run -t runtime` (the app). All 4
  languages (#68).
- README **Prerequisites** (install Docker Engine + Compose plugin + `just`;
  plus host udev rules for a physical camera) and **Uninstall / Cleanup**
  (`just stop`, `just prune`, host udev-rule removal) sections, in all 4
  languages (#68). ROS 1 parity with realsense_ros2 #85.
- `doc/CALIBRATION.md` (Dynamic Calibration Tool guide -- targeted rectification,
  depth scale, and RGB extrinsics; the residual depth<->color alignment error and
  why it's worse on the D455) and `doc/CAMERA.md` (manual physical-camera test
  procedure with the ROS 1 `roslaunch` / `rostopic` workflow, plus on-chip
  calibration and the health-check score). Linked from `README.md` + 3 translated
  READMEs (#70). Adapted from realsense_ros2; CALIBRATION.md notes the tool is
  **not yet bundled** in the focal-based ROS 1 `devel` image (the donor bundles
  the amd64 `pool/jammy` `.deb`; a focal build is deferred to a follow-up).
- README **Multi-machine (ROS 1)** section (all 4 languages): run a master on
  one host and the camera container as a slave by putting `ROS_MASTER_URI` +
  `ROS_IP` in the `.env` workload overlay -- no command-line flags, since
  `compose.yaml` injects `.env` via `env_file`. Documents the `ROS_IP`
  hostname-advertisement gotcha. Verified Pi-as-slave -> host master (~28 Hz on
  the master).

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
- README (4 languages) re-synced to the actual code (#63): commands now use
  `just` recipes instead of the removed `./build.sh` / `./run.sh`; removed the
  duplicate CI badge; corrected the install claim (only
  `ros-noetic-realsense2-camera` / `-description` are apt-installed,
  `librealsense2` comes in transitively); refreshed the architecture diagram +
  stage table to the real stages (`sys`, `devel-base`, `devel`, `devel-test` via
  `test-tools-stage`, `runtime-base`, `runtime`, `runtime-test`) -- dropping the
  stale `bats-src` / `bats-extensions` / `lint-tools` stages (removed in #72);
  fixed the directory tree (`justfile`, `setup.conf`, `.base/` not `template/`,
  `script/install_udev_rules.sh`, `doc/CALIBRATION.md`, `doc/CAMERA.md`,
  `doc/adr/`); added a note that only **Noetic** is built/tested and **Kinetic is
  out of scope**. Custom launch args now use the working low-level form
  `docker compose run --rm runtime roslaunch realsense2_camera rs_camera.launch
  <args>` (the `just run -t runtime <cmd>` override is broken upstream,
  [base#679](https://github.com/ycpss91255-docker/base/issues/679)), with a
  USB 2.x reduced-profile note using verified ROS 1 arg names
  (`depth_width:=480 depth_height:=270 depth_fps:=6 color_width:=424
  color_height:=240 color_fps:=6`, ~6 Hz on a D435).
- `doc/test/TEST.md` re-synced to the actual smoke suite (#63): `template/`
  paths corrected to `.base/`, and the documented rows + total now match the
  **60** tests that actually run (18 `ros_env.bats` + 4
  `install_udev_rules.bats` + 27 `.base/.../script_help.bats` + 11
  `.base/.../display_env.bats`).
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

