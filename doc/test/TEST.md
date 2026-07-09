# TEST.md

**104 tests** total.

## test/smoke/ros_env.bats

### ROS environment (4)

| Test | Description |
|------|-------------|
| `ROS_DISTRO is set` | ROS_DISTRO environment variable is set |
| `ROS 1 setup.bash exists` | `/opt/ros/${ROS_DISTRO}/setup.bash` exists |
| `ROS 1 setup.bash can be sourced` | ROS 1 setup script sources without error |
| `interactive shells source ROS (roslaunch on PATH via bashrc.d)` | `config/shell/bashrc.d/10-ros-source.sh` puts `roslaunch` on PATH for interactive shells |

### Entrypoint: remote-master wait (7)

| Test | Description |
|------|-------------|
| `entrypoint injects --wait for a remote master + roslaunch (#79)` | Remote `ROS_MASTER_URI` + `roslaunch` resolves to `roslaunch --wait ...` |
| `entrypoint does not inject --wait for a local master (#79)` | `localhost` master leaves `roslaunch` args unchanged (no deadlock) |
| `entrypoint does not inject --wait when ROS_MASTER_URI is unset (#79)` | Unset/empty master leaves `roslaunch` args unchanged |
| `entrypoint passes non-roslaunch commands through unchanged (#79)` | Non-`roslaunch` command (e.g. `bash -c ...`) is not modified |
| `entrypoint does not double-inject --wait when already present (#79)` | Existing `--wait` is not duplicated |
| `_ros_master_is_remote treats a global IPv6 master as remote (#79)` | `http://[fd00::5]:11311` strips the brackets and classifies as remote |
| `_ros_master_is_remote treats IPv6 loopback [::1] as local (#79)` | `http://[::1]:11311` classifies as local (no `--wait` deadlock) |

### Entrypoint: remote-master watchdog (8)

| Test | Description |
|------|-------------|
| `watchdog off by default for a remote master + roslaunch (#81)` | Opt-in: remote master + `roslaunch` + unset `WATCHDOG_ENABLED` falls back to the plain `--wait` gate |
| `watchdog enabled with WATCHDOG_ENABLED=1 + remote master + roslaunch (#81)` | `WATCHDOG_ENABLED=1` + remote master + `roslaunch` engages the watchdog |
| `watchdog disabled when WATCHDOG_ENABLED=0 (#81)` | `WATCHDOG_ENABLED=0` falls back to the plain gate |
| `watchdog disabled for a local master even with WATCHDOG_ENABLED=1 (#81)` | `localhost` master does not engage the watchdog |
| `watchdog disabled for a non-roslaunch command even with WATCHDOG_ENABLED=1 (#81)` | Non-`roslaunch` command does not engage the watchdog |
| `watchdog node present in rosnode list is healthy (#81)` | `_node_registered` returns healthy when the node is in the list text |
| `watchdog node absent from rosnode list is unhealthy (#81)` | `_node_registered` returns unhealthy when the node is absent |
| `watchdog stops the roslaunch child with SIGTERM, not SIGINT (#81)` | Regression guard: async child has SIGINT set to SIG_IGN, so the child is stopped with SIGTERM (not SIGINT) or `wait` hangs |

### RealSense packages (3)

| Test | Description |
|------|-------------|
| `realsense2_camera discoverable via rospack` | Source-built wrapper (#88) is on `ROS_PACKAGE_PATH` (`rospack find realsense2_camera`) |
| `realsense2_description discoverable via rospack` | Bundled `realsense2_description` payload (#88) is on `ROS_PACKAGE_PATH` (`rospack find realsense2_description`) |
| `librealsense2 SDK library present` | Self-built librealsense v2.55.1 landed at `/usr/local/lib/librealsense2.so*` (ROS-agnostic SDK) |

### Desktop GUI (devel) (1)

| Test | Description |
|------|-------------|
| `rqt_image_view is available (devel GUI; backs the README demo)` | `ros-${ROS_DISTRO}-rqt-image-view` installed (via `ros-${ROS_DISTRO}-desktop`) |

### Base tools (4)

| Test | Description |
|------|-------------|
| `git is available` | git command works |
| `vim is available` | vim command works |
| `sudo is available` | sudo command works |
| `sudo passwordless works` | sudo runs without password |

### System (8)

| Test | Description |
|------|-------------|
| `User is not root` | Container user is not root |
| `HOME is set and exists` | HOME is set and directory exists |
| `container user matches the configured USER_NAME (base v0.41.0 build contract)` | Image built as the injected `USER_NAME` (`CONTAINER_EXPECTED_USER`), not the legacy default user |
| `HOME path matches the container user` | `HOME` equals `/home/$(id -un)` |
| `Timezone is Asia/Taipei` | Timezone configured correctly |
| `LANG is en_US.UTF-8` | LANG locale set |
| `LC_ALL is en_US.UTF-8` | LC_ALL locale set |
| `entrypoint.sh exists and executable` | `/entrypoint.sh` is executable |

### RealSense udev rules (1)

| Test | Description |
|------|-------------|
| `RealSense udev rules exist` | udev rules file exists |

### Workspace (1)

| Test | Description |
|------|-------------|
| `Work directory exists` | `${HOME}/work` directory exists |

## test/smoke/install_udev_rules.bats

### install_udev_rules.sh (6)

| Test | Description |
|------|-------------|
| `install_udev_rules.sh -h exits 0` | Help exits successfully |
| `install_udev_rules.sh --help exits 0` | Help exits successfully |
| `install_udev_rules.sh -h prints usage` | Help output contains "Usage:" |
| `install_udev_rules.sh is executable` | Script carries the executable bit so the documented `./script/install_udev_rules.sh` works |
| `install_udev_rules.sh rejects an unknown argument (non-zero + usage)` | Unknown arg exits non-zero and prints "Usage:" |
| `install_udev_rules.sh fails when the rules file is absent` | Missing `RULES_SRC` exits 1 with a "not found" message before any privileged step |

### check_udev_rules_sync.sh (7)

| Test | Description |
|------|-------------|
| `check_udev_rules_sync.sh -h exits 0` | Help exits successfully |
| `check_udev_rules_sync.sh --help exits 0` | Help exits successfully |
| `check_udev_rules_sync.sh -h prints usage` | Help output contains "Usage:" |
| `check_udev_rules_sync.sh is executable` | Drift-guard script carries the executable bit |
| `check_udev_rules_sync.sh flags drift when upstream ships a rule the vendored file lacks` | Curl-stub sandbox: upstream-only rule -> exit 1 + "drift" |
| `check_udev_rules_sync.sh passes when the vendored file covers upstream` | Curl-stub sandbox: vendored covers upstream -> exit 0 + "OK" |
| `check_udev_rules_sync.sh skips (exit 0) when the fetch fails offline` | Curl-stub failure (offline) -> exit 0 + "skip" |

## test/smoke/camera_config.bats

### Camera config wiring (9)

| Test | Description |
|------|-------------|
| `camera config is baked into the image` | `/camera_config.yaml` exists (baked from the `camera.yaml` symlink target) |
| `default baked camera config is empty (stock upstream defaults)` | Default `none.yaml` is 0 bytes, so the stock CMD streams the upstream defaults |
| `entrypoint leaves the stock CMD unchanged for an empty config` | `_apply_camera_config` keeps the original argv when `/camera_config.yaml` is empty |
| `entrypoint appends config_file:= for a non-empty camera config` | A non-empty config appends `config_file:=/camera_config.yaml` to the `roslaunch /rs_camera_config.launch` argv (wrapper loads the profile) |
| `entrypoint does not hijack a non-roslaunch command even with a config` | Non-`roslaunch` command (devel `bash`) is left unchanged even when a profile is baked |
| `wrapper launch is baked into the image (/rs_camera_config.launch exists)` | `/rs_camera_config.launch` exists (the runtime CMD depends on it) |
| `wrapper launch is well-formed XML (roslaunch-parseable)` | Parses `/rs_camera_config.launch` as XML -- regression for the `--`-in-comment bug that made roslaunch reject it and the node relaunch-loop |
| `Dockerfile CMD launches the wrapper (/rs_camera_config.launch)` | Dockerfile CMD is `roslaunch /rs_camera_config.launch initial_reset:=true` |
| `Dockerfile declares CAMERA_CONFIG and COPYs it to /camera_config.yaml` | `ARG CAMERA_CONFIG="camera.yaml"` + `COPY --chmod=0644 "${CAMERA_CONFIG}" /camera_config.yaml` |

## test/smoke/dockerfile_guards.bats

### Dockerfile static guards (7)

| Test | Description |
|------|-------------|
| `groupadd new-group branch names the group after ${GROUP}, not ${USER} (#71)` | sys stage `groupadd` names the group after `${GROUP}` (not `${USER}`) |
| `version ARGs are pinned, not floating (#88)` | `ARG LIBREALSENSE_VERSION="v2.55.1"` + `ARG REALSENSE_ROS_VERSION="2.3.2"` are concrete pins |
| `no stage apt-installs the RealSense packages (#88 source build)` | No stage apt-installs `ros-${ROS_DISTRO}-realsense2-camera` / `-description` |
| `runtime-test smoke asserts the wrapper is discoverable (#88)` | runtime-test RUN contains `rospack find realsense2_camera` |
| `runtime-test ldd scan covers both the ROS lib dir and /usr/local (#88)` | runtime-test ldd scan spans `/opt/ros/${ROS_DISTRO}/lib` and `/usr/local/lib` |
| `devel-test lints the pre-build hook (COPY into /lint scope, #88)` | Dockerfile COPYs `script/hooks/pre/build.sh` into `/lint/hooks-pre-build.sh` for shellcheck |
| `pre-build hook no-ops when LIBREALSENSE_IMAGE is already set` | Hook exits 0 without building when `LIBREALSENSE_IMAGE` is set |

## .base/test/smoke/script_help.bats

### build.sh (4)

| Test | Description |
|------|-------------|
| `build.sh -h exits 0` | Help exits successfully |
| `build.sh --help exits 0` | Help exits successfully |
| `build.sh -h prints usage` | Help output contains "Usage:" |
| `build.sh -h describes auto-apply default (no stale 'warn on drift', #365)` | Help describes auto-apply default |

### run.sh (4)

| Test | Description |
|------|-------------|
| `run.sh -h exits 0` | Help exits successfully |
| `run.sh --help exits 0` | Help exits successfully |
| `run.sh -h prints usage` | Help output contains "Usage:" |
| `run.sh -h describes auto-apply default (no stale 'warn on drift', #365)` | Help describes auto-apply default |

### exec.sh (3)

| Test | Description |
|------|-------------|
| `exec.sh -h exits 0` | Help exits successfully |
| `exec.sh --help exits 0` | Help exits successfully |
| `exec.sh -h prints usage` | Help output contains "Usage:" |

### stop.sh (3)

| Test | Description |
|------|-------------|
| `stop.sh -h exits 0` | Help exits successfully |
| `stop.sh --help exits 0` | Help exits successfully |
| `stop.sh -h prints usage` | Help output contains "Usage:" |

### LANG auto-detect (4)

| Test | Description |
|------|-------------|
| `build.sh detects zh from LANG=zh_TW.UTF-8` | Detects Traditional Chinese |
| `build.sh detects ja from LANG=ja_JP.UTF-8` | Detects Japanese |
| `build.sh defaults to en for LANG=en_US.UTF-8` | Defaults to English |
| `build.sh SETUP_LANG overrides LANG` | SETUP_LANG takes priority |

### Help --lang override (9)

| Test | Description |
|------|-------------|
| `build.sh --help --lang zh-TW prints zh-TW usage (#222)` | build.sh zh-TW help |
| `build.sh --help --lang zh-CN prints zh-CN usage (#222)` | build.sh zh-CN help |
| `build.sh --help --lang ja prints ja usage (#222)` | build.sh ja help |
| `run.sh --help --lang zh-TW prints zh-TW usage (#222)` | run.sh zh-TW help |
| `run.sh --help --lang ja prints ja usage (#222)` | run.sh ja help |
| `exec.sh --help --lang zh-TW prints zh-TW usage (#222)` | exec.sh zh-TW help |
| `exec.sh --help --lang ja prints ja usage (#222)` | exec.sh ja help |
| `stop.sh --help --lang zh-TW prints zh-TW usage (#222)` | stop.sh zh-TW help |
| `stop.sh --help --lang ja prints ja usage (#222)` | stop.sh ja help |

## .base/test/smoke/display_env.bats

### Wayland env vars (3)

| Test | Description |
|------|-------------|
| `compose.yaml contains WAYLAND_DISPLAY env` | WAYLAND_DISPLAY in compose.yaml |
| `compose.yaml contains XDG_RUNTIME_DIR env` | XDG_RUNTIME_DIR in compose.yaml |
| `compose.yaml contains XAUTHORITY env` | XAUTHORITY in compose.yaml |

### Display mounts (4)

| Test | Description |
|------|-------------|
| `compose.yaml mounts XDG_RUNTIME_DIR as rw` | XDG_RUNTIME_DIR mounted read-write |
| `compose.yaml mounts XAUTHORITY volume` | XAUTHORITY volume mounted |
| `compose.yaml has no consecutive duplicate keys` | No YAML duplicate key errors |
| `compose.yaml mounts X11-unix volume` | X11 socket mounted |

### xhost branching (4)

| Test | Description |
|------|-------------|
| `run.sh contains XDG_SESSION_TYPE check` | Session type detection present |
| `run.sh calls xhost +SI:localuser on wayland` | Wayland xhost command correct |
| `run.sh calls xhost +local: on X11` | X11 xhost command correct |
| `run.sh defaults to X11 xhost when XDG_SESSION_TYPE unset` | Falls back to X11 |
