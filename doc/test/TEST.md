# TEST.md

**49 tests** total.

## test/smoke/ros_env.bats

### ROS environment (4)

| Test | Description |
|------|-------------|
| `ROS_DISTRO is set` | ROS_DISTRO environment variable is set |
| `ROS 1 setup.bash exists` | `/opt/ros/${ROS_DISTRO}/setup.bash` exists |
| `ROS 1 setup.bash can be sourced` | ROS 1 setup script sources without error |
| `interactive shells source ROS (roslaunch on PATH via bashrc.d)` | `config/shell/bashrc.d/10-ros-source.sh` puts `roslaunch` on PATH in interactive shells |

### RealSense packages (2)

| Test | Description |
|------|-------------|
| `realsense2_camera is installed` | `ros-${ROS_DISTRO}-realsense2-camera` package installed |
| `realsense2_description is installed` | `ros-${ROS_DISTRO}-realsense2-description` package installed |

### Base tools (4)

| Test | Description |
|------|-------------|
| `git is available` | git command works |
| `vim is available` | vim command works |
| `sudo is available` | sudo command works |
| `sudo passwordless works` | sudo runs without password |

### System (7)

| Test | Description |
|------|-------------|
| `User is not root` | Container user is not root |
| `HOME is set and exists` | HOME is set and directory exists |
| `Timezone is Asia/Taipei` | Timezone configured correctly |
| `LANG is en_US.UTF-8` | LANG locale set |
| `LC_ALL is en_US.UTF-8` | LC_ALL locale set |
| `entrypoint.sh exists and executable` | `/entrypoint.sh` is executable |
| `RealSense udev rules exist` | udev rules file exists |

### Workspace (1)

| Test | Description |
|------|-------------|
| `Work directory exists` | `${HOME}/work` directory exists |

## test/smoke/install_udev_rules.bats

### install_udev_rules.sh (4)

| Test | Description |
|------|-------------|
| `install_udev_rules.sh -h exits 0` | Help flag exits successfully |
| `install_udev_rules.sh --help exits 0` | Long help flag exits successfully |
| `install_udev_rules.sh -h prints usage` | Help output contains "Usage:" |
| `install_udev_rules.sh is executable` | Script carries the executable bit (regression: shipped 0644 once) |

## template/test/smoke/script_help.bats

### build.sh (3)

| Test | Description |
|------|-------------|
| `build.sh -h exits 0` | Help exits successfully |
| `build.sh --help exits 0` | Help exits successfully |
| `build.sh -h prints usage` | Help output contains "Usage:" |

### run.sh (3)

| Test | Description |
|------|-------------|
| `run.sh -h exits 0` | Help exits successfully |
| `run.sh --help exits 0` | Help exits successfully |
| `run.sh -h prints usage` | Help output contains "Usage:" |

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

## template/test/smoke/display_env.bats

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
