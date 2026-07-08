# TEST.md

**78 tests** total.

## test/smoke/ros_env.bats

### ROS environment (4)

| Test | Description |
|------|-------------|
| `ROS_DISTRO is set` | ROS_DISTRO environment variable is set |
| `ROS 1 setup.bash exists` | `/opt/ros/${ROS_DISTRO}/setup.bash` exists |
| `ROS 1 setup.bash can be sourced` | ROS 1 setup script sources without error |
| `interactive shells source ROS (roslaunch on PATH via bashrc.d)` | `config/shell/bashrc.d/10-ros-source.sh` puts `roslaunch` on PATH for interactive shells |

### Entrypoint: remote-master wait (5)

| Test | Description |
|------|-------------|
| `entrypoint injects --wait for a remote master + roslaunch (#79)` | Remote `ROS_MASTER_URI` + `roslaunch` resolves to `roslaunch --wait ...` |
| `entrypoint does not inject --wait for a local master (#79)` | `localhost` master leaves `roslaunch` args unchanged (no deadlock) |
| `entrypoint does not inject --wait when ROS_MASTER_URI is unset (#79)` | Unset/empty master leaves `roslaunch` args unchanged |
| `entrypoint passes non-roslaunch commands through unchanged (#79)` | Non-`roslaunch` command (e.g. `bash -c ...`) is not modified |
| `entrypoint does not double-inject --wait when already present (#79)` | Existing `--wait` is not duplicated |

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

### RealSense packages (2)

| Test | Description |
|------|-------------|
| `realsense2_camera discoverable via rospack` | Source-built wrapper (#88) is on `ROS_PACKAGE_PATH` (`rospack find realsense2_camera`) |
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

### System (6)

| Test | Description |
|------|-------------|
| `User is not root` | Container user is not root |
| `HOME is set and exists` | HOME is set and directory exists |
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

### install_udev_rules.sh (4)

| Test | Description |
|------|-------------|
| `install_udev_rules.sh -h exits 0` | Help exits successfully |
| `install_udev_rules.sh --help exits 0` | Help exits successfully |
| `install_udev_rules.sh -h prints usage` | Help output contains "Usage:" |
| `install_udev_rules.sh is executable` | Script carries the executable bit so the documented `./script/install_udev_rules.sh` works |

### check_udev_rules_sync.sh (4)

| Test | Description |
|------|-------------|
| `check_udev_rules_sync.sh -h exits 0` | Help exits successfully |
| `check_udev_rules_sync.sh --help exits 0` | Help exits successfully |
| `check_udev_rules_sync.sh -h prints usage` | Help output contains "Usage:" |
| `check_udev_rules_sync.sh is executable` | Drift-guard script carries the executable bit |

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
