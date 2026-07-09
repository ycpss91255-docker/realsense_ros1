**[English](CHANGELOG.md)** | **[繁體中文](CHANGELOG.zh-TW.md)** | **[简体中文](CHANGELOG.zh-CN.md)** | **[日本語](CHANGELOG.ja.md)**

# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Selectable camera config, modeled on the `app/ros1_bridge` `bridge.yaml`
  pattern. A repo-root `camera.yaml` symlink selects the active profile;
  `config/realsense/custom/` holds our profiles (`none.yaml`, an EMPTY 0-byte
  marker = stock upstream defaults 640x480x30, is the default target; and
  `usb2.yaml` = color 640x480@15 + depth 480x270@15, aligned depth on, IR/IMU
  off for a USB 2 link). The Dockerfile bakes the symlink target into the image
  as `/camera_config.yaml` via `ARG CAMERA_CONFIG="camera.yaml"` +
  `COPY --chmod=0644 "${CAMERA_CONFIG}" /camera_config.yaml` (devel + runtime
  stages). A repo-owned wrapper launch, `launch/rs_camera_config.launch` (baked
  in as `/rs_camera_config.launch`, the runtime CMD), `<include>`s the stock
  `rs_aligned_depth.launch` unchanged and adds one optional `config_file:=` arg
  that `rosparam`-loads the profile into the node namespace AFTER the include
  (ROS 1 realsense-ros 2.3.2 has no `config_file`; the later write wins, so the
  YAML overrides the launch defaults -- verified via `roslaunch --dump-params`).
  When `/camera_config.yaml` is non-empty and the command is a `roslaunch`,
  `script/entrypoint.sh` simply appends `config_file:=/camera_config.yaml`.
  Default behaviour (empty `none.yaml`) is byte-identical to before; activate a
  profile by repointing the symlink or
  `--build-arg CAMERA_CONFIG=config/realsense/custom/usb2.yaml`. For parity with
  the ROS 2 sibling, `config/realsense/official/config.yaml` holds a same-meaning
  ROS 1 port of the ROS 2 upstream example config (ROS 1 realsense-ros ships no
  config YAML of its own -- only launch args -- so there is nothing official to
  vendor or drift-check). The vendored `99-realsense-libusb.rules` udev rules
  (verbatim from the librealsense SDK, drift-checked by
  `script/check_udev_rules_sync.sh`) also live under
  `config/realsense/official/`. Our own profiles live in
  `config/realsense/custom/`; the split and the wrapper-launch mechanism are
  documented in the repo README (Camera Config section, with i18n).
- `script/hooks/pre/build.sh` (base #440 pre-build hook): for a local
  `just build` / `./build.sh` (with `LIBREALSENSE_IMAGE` unset) it auto-builds
  `librealsense:local` from `docker/Dockerfile.librealsense` before the main
  build, mirroring how `build.sh` auto-builds `test-tools:local`. The local
  build is now self-contained -- no GHCR pull needed. If `LIBREALSENSE_IMAGE`
  is already set (CI passes the `v2.55.1-focal` GHCR tag) the hook is a no-op.
- `docker/Dockerfile.librealsense` gains a `test` stage (publish-time smoke
  GATE: asserts the `/rs-full` + `/rs-stage` trees exist, `librealsense2.so` is
  present and fully linkable with no `not found`, the versioned soname is
  present, and `/rs-stage` is pruned of the viewer / `rs-*` tools / GL lib) and
  a `scratch`-based `export` stage. `build-librealsense.yaml` now builds
  `--target test` (`push: false`) as a gate BEFORE publishing, so a broken SDK
  image can never reach GHCR.
- `script/check_udev_rules_sync.sh` (#88): a drift guard that flags when the
  vendored `config/realsense/official/99-realsense-libusb.rules` is missing a device rule
  the pinned librealsense SDK tag (`v2.55.1`) ships. Compares only the
  `SUBSYSTEMS==` rule lines (tolerating the vendored header comment + local
  extra device IDs) and is network-optional (offline runs skip with exit 0), so
  a CI job can invoke it non-blocking.
- Multi-machine slave can self-heal when a **remote** master restarts after
  launch (#81), via an opt-in watchdog. Building on the #79/#80 boot gate,
  `script/entrypoint.sh` runs a supervised-restart loop when the watchdog is
  enabled and `ROS_MASTER_URI` is remote. It launches `roslaunch --wait` as a
  child, and every `WATCHDOG_INTERVAL` (default 15 s) checks whether
  `WATCHDOG_ROSNODE` (default `/camera/realsense2_camera`) is registered on the
  *current* master (`timeout WATCHDOG_TIMEOUT rosnode list`, default 5 s) --
  registration, not mere master reachability, since a master restarted on the
  same port stays TCP-reachable while the node is already deregistered. After
  `WATCHDOG_FAILURES` consecutive failures (default 3, ~45 s) it kills roslaunch
  cleanly and relaunches, so the fresh `--wait` re-waits and re-registers on the
  new master. A transient blip shorter than the failure window does not trigger
  a restart. `SIGTERM`/`SIGINT` are forwarded to the child and reaped before
  exit so `just stop` stays clean and fast (no 10 s SIGKILL wait). The watchdog
  is **opt-in (default off)**, consistent with base `[lifecycle] restart = no`:
  enable it with `WATCHDOG_ENABLED=1`. The `--wait` gate still applies for a
  remote master whether or not the watchdog is enabled; local/unset master and
  non-`roslaunch` commands are unchanged. All knobs are `.env`-configurable. The
  enable-decision and the registration check are factored into pure functions,
  guarded by 8 `ros_env.bats` tests. Interim reaping `wait`s on the direct
  roslaunch child only; grandchildren orphaned by a hard kill need a PID 1 init,
  deferred to the base `init` toggle.
- Smoke-test coverage expanded from 45 to 65 repo-specific tests (103 total with
  the shared base smoke). A new `test/smoke/dockerfile_guards.bats` pins the
  static Dockerfile invariants that have no runtime surface: the `groupadd`
  `${GROUP}`-vs-`${USER}` regression (#71), the `LIBREALSENSE_VERSION` /
  `REALSENSE_ROS_VERSION` pins, the absence of any apt-installed
  `realsense2-camera`/`-description` (#88 source build), and the runtime-test
  wrapper-discovery + dual-lib-dir ldd scan. `camera_config.bats` now also
  asserts the baked `/rs_camera_config.launch` and the Dockerfile `CMD` /
  `CAMERA_CONFIG` wiring; `ros_env.bats` adds the `USER_NAME`/`HOME` build
  contract, `realsense2_description` discovery, and the `_ros_master_is_remote`
  IPv6 (`[fd00::5]` remote, `[::1]` local) branches; `install_udev_rules.bats`
  adds the installer's bad-arg + missing-rules-file exits and drives
  `check_udev_rules_sync.sh`'s drift / covered / offline-skip logic through a
  `curl` PATH stub. The `devel-test` lint stage now also `COPY`s
  `script/hooks/pre/build.sh` into `/lint/` so ShellCheck covers the pre-build
  hook (the non-recursive `COPY script/*.sh` skipped it).

### Changed
- The prebuilt `librealsense` SDK image is ROS-agnostic and keyed on the Ubuntu
  platform, not the ROS distro. It builds on `ubuntu:focal` (was
  `ros:noetic-ros-base`) and installs into the `/usr/local` prefix (was
  `/opt/ros/noetic`); the consumer COPYs it to `/usr/local` and runs `ldconfig`,
  while the catkin wrapper still lands in `/opt/ros/noetic`. Its image tag is
  `v2.55.1-focal` rather than `noetic-v2.55.1`, since librealsense2 is a pure
  C++ library whose `.so` is ABI-bound to the Ubuntu release's glibc/libstdc++,
  not to ROS. The leaner `ubuntu` base also needs two things `ros-base` provided
  for free: `ca-certificates` (installed explicitly, for the https SDK clone)
  and `DEBIAN_FRONTEND=noninteractive` on the apt install (the GTK/GL deps pull
  in `tzdata`, which would otherwise prompt interactively and hang the TTY-less
  build).
- The main Dockerfile's `rs_sdk` source is now parameterized via a global
  `ARG LIBREALSENSE_IMAGE="librealsense:local"` + `FROM ${LIBREALSENSE_IMAGE}`,
  mirroring base's `TEST_TOOLS_IMAGE` dual-source pattern. Local builds FROM
  `librealsense:local` (built by the new `script/hooks/pre/build.sh` pre-build
  hook, no GHCR needed -> self-contained), while `main.yaml` passes
  `LIBREALSENSE_IMAGE=ghcr.io/ycpss91255-docker/librealsense:v2.55.1-focal`
  through `build_args` so CI PULLS the prebuilt SDK. The wrapper build, runtime
  overlay, entrypoint, and CMD are unchanged.
- The published `librealsense` SDK image is now the slim `scratch`-based
  `export` target -- literally just the `/rs-full` + `/rs-stage` DESTDIR trees
  the consumer COPYs, with the ros-base + build toolchain underneath dropped
  (dead weight, since nothing runs the SDK image). The publish workflow's
  build-and-push step now targets `export`; the trees are at the same paths, so
  every `COPY --from=rs_sdk` against the image is unchanged.
- librealsense is now consumed as a **prebuilt GHCR image** instead of being
  compiled on every build (option B). The SDK (v2.55.1) is built ONCE by the new
  `.github/workflows/build-librealsense.yaml` multi-arch workflow and published
  to `ghcr.io/ycpss91255-docker/librealsense:v2.55.1-focal`; the main Dockerfile
  adds an `rs_sdk` stage that `FROM`s that image and `COPY`s the pre-built SDK
  trees (`/rs-full` for `devel`, `/rs-stage` for `runtime`) into the wrapper
  build. CI no longer pays the ~15-25 min librealsense compile per run -- only
  the ~5 min catkin wrapper build (which must still compile against the SDK)
  remains inline. The wrapper build, runtime overlay, entrypoint, and CMD are
  unchanged. Since ROS 1 is terminal at v2.55.1, the SDK image is built once and
  never changes.
- The `runtime` image now launches with `initial_reset:=true` by default (#93):
  on the RSUSB userspace backend, a D455 cold-start on arm64 (Pi 5) could wedge
  the first stream-open (`RS2_USB_STATUS_IO`, topics stuck at 0 Hz); resetting
  the device at startup clears it. Adds a few seconds to launch; `runtime` CMD
  only (so `devel` is unaffected), and the arg is overridable.
- Build the RealSense stack from source instead of apt (#88). librealsense
  **v2.55.1** (SDK) and the ros1-legacy **realsense-ros 2.3.2** wrapper are now
  built from source and installed into `/opt/ros/noetic` (mirroring the apt
  layout, so the entrypoint and paths are unchanged) rather than pulled from
  apt. librealsense is no longer compiled inline -- it is now consumed as a
  prebuilt GHCR image (see the prebuilt-GHCR entry above); only the ros1-legacy
  **realsense-ros 2.3.2** catkin wrapper still compiles in the `devel` stage
  (it must build against the SDK). `runtime` gets both via `COPY --from=devel`
  of a `DESTDIR` staging tree (SDK bin tools pruned) plus an online `rosdep`
  pass for the wrapper's exec-only ROS deps. The
  apt `ros-noetic-realsense2-camera` / `ros-noetic-realsense2-description` were
  removed from both `devel` and `runtime`; `realsense2_description` is now built
  from the realsense-ros repo. The apt path pinned librealsense **2.50.0**
  (Noetic EOL), which cannot stream a D455 on a Pi 5 (`-71` / uvc watchdog); the
  self-built 2.55.1 streams it at ~30 fps. Versions are pinned and overridable
  via `--build-arg LIBREALSENSE_VERSION` / `--build-arg REALSENSE_ROS_VERSION`;
  this repo is **terminal** at this pair (ROS 1 / Noetic / ros1-legacy are EOL,
  and 2.56+ cannot build against the legacy wrapper -- realsense-ros#3406). The
  runtime default command (`rs_aligned_depth.launch`) is unchanged.

### Removed
- Unused `tini` from the Dockerfile `runtime-base` stage (#81): it was installed
  but never wired as `ENTRYPOINT` (the entrypoint is `script/entrypoint.sh`), so
  it was dead weight. Proper PID 1 zombie reaping belongs to a base-generated
  `init` toggle, not an app-level hand-edit. `sudo` is kept.
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
- The shipped `runtime` image now publishes aligned depth-to-color by default
  (#85). Its default CMD switched from `rs_camera.launch` to Intel's packaged
  `rs_aligned_depth.launch` (same launch with `align_depth` defaulting to
  `true`), so `just run -t runtime` publishes
  `/camera/aligned_depth_to_color/image_raw` out of the box. Override with the
  low-level `docker compose run --rm runtime roslaunch realsense2_camera
  rs_camera.launch ...` form to opt back out.
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
- Multi-machine slave boot race (#79): when `.env` points `ROS_MASTER_URI` at a
  **remote** master, `script/entrypoint.sh` now launches with `roslaunch
  --wait`, which blocks until the master is reachable and then launches. A slave
  that boots before its master (e.g. `restart: unless-stopped` auto-start) no
  longer comes up as an unregistered zombie node (`rostopic list` showed the
  topics but `rosnode list` never showed `/camera`). Guarded to avoid breaking
  the single-machine default: `--wait` is injected only for a remote master
  (not empty / `localhost` / `127.*` / `::1`, where roslaunch starts its own
  roscore and `--wait` would deadlock) **and** only when the command is
  `roslaunch`; other commands (e.g. an interactive `just exec` shell) pass
  through unchanged, and `--wait` is never double-injected. Guarded by 5 new
  `ros_env.bats` regression tests.
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

