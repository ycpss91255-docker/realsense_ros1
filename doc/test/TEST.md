# TEST.md

**200 tests** total.

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

### Entrypoint: watchdog probe + decision (12)

| Test | Description |
|------|-------------|
| `watchdog probe classifies a listed node as healthy (#136)` | `_watchdog_probe`: query exits 0 with the node in the list -> `healthy` |
| `watchdog probe classifies an empty list (exit 0) as deregistered (#136)` | Query exits 0 with an empty list (master restarted on the same port) -> `deregistered`, not `unreachable` (classified by exit code) |
| `watchdog probe classifies a non-zero (timeout) query as unreachable (#136)` | Query exits non-zero (e.g. `timeout` -> 124) -> `unreachable` |
| `watchdog decide: phase1 healthy marks the node registered (#136)` | `_watchdog_decide` phase 1 + `healthy` -> `HEALTHY` (loop sets registered_once) |
| `watchdog decide: phase1 unreachable below the deadline waits (#136)` | Phase 1 + `unreachable`, `elapsed < deadline` -> `WAIT` (does not count) |
| `watchdog decide: phase1 deregistered below the deadline waits (#136)` | Phase 1 + `deregistered`, `elapsed < deadline` -> `WAIT` (does not count) |
| `watchdog decide: phase1 unreachable at the deadline restarts (#136)` | Phase 1 + `unreachable`, `elapsed >= deadline` -> `RESTART` (startup backstop) |
| `watchdog decide: phase1 deregistered past the deadline restarts (#136)` | Phase 1 + `deregistered`, `elapsed >= deadline` -> `RESTART` (startup backstop) |
| `watchdog decide: phase2 healthy resets and stays registered (#136)` | Phase 2 + `healthy` -> `HEALTHY` (loop resets the failure counter) |
| `watchdog decide: phase2 unreachable below max failures waits (#136)` | Phase 2 + `unreachable`, `failures+1 < max` -> `WAIT` (blip debounce) |
| `watchdog decide: phase2 unreachable reaching max failures restarts (#136)` | Phase 2 + `unreachable`, `failures+1 >= max` -> `RESTART` |
| `watchdog decide: phase2 deregistered restarts on the next tick (#136)` | Phase 2 + `deregistered` -> `RESTART` (no debounce) |

### Entrypoint: advertised-URI pre-flight assert (27)

| Test | Description |
|------|-------------|
| `_advertised_host prefers a __hostname:= override above all (#137)` | `_advertised_host`: argv `__hostname:=` wins over `__ip:=` and ROS_HOSTNAME/ROS_IP |
| `_advertised_host prefers __ip:= over ROS_HOSTNAME/ROS_IP (#137)` | argv `__ip:=` wins over the ROS_HOSTNAME/ROS_IP env vars |
| `_advertised_host prefers ROS_HOSTNAME over ROS_IP (#137)` | `ROS_HOSTNAME` wins over `ROS_IP` when no argv override is present |
| `_advertised_host falls back to ROS_IP when only it is set (#137)` | `ROS_IP` is used when it is the only value set |
| `_advertised_host falls back to hostname when nothing is set (#137)` | With no override / env, the advertised host is `hostname` (non-empty) |
| `_addr_is_loopback classifies 127.0.0.1 as loopback (#137)` | `_addr_is_loopback`: `127.0.0.1` -> loopback (success) |
| `_addr_is_loopback classifies 127.0.1.1 as loopback (#137)` | `127.0.1.1` (Debian `/etc/hosts` hostname map) -> loopback (success) |
| `_addr_is_loopback classifies ::1 as loopback (#137)` | `::1` -> loopback (success) |
| `_addr_is_loopback classifies localhost as loopback (#137)` | `localhost` -> loopback (success) |
| `_addr_is_loopback rejects a LAN address (#137)` | `192.168.1.5` (a LAN address) -> not loopback (failure) |
| `_advertise_decide maps an empty address to UNRESOLVABLE (#137)` | `_advertise_decide ""` -> `UNRESOLVABLE` (getent failed) |
| `_advertise_decide maps a loopback address to LOOPBACK (#137)` | `_advertise_decide 127.0.1.1` -> `LOOPBACK` |
| `_advertise_decide maps a LAN address to OK (#137)` | `_advertise_decide 192.168.1.5` -> `OK` |
| `advertise assert enabled for a remote master + roslaunch by default (#137)` | `_advertise_assert_enabled`: default ON + remote master + `roslaunch` engages |
| `advertise assert disabled when ADVERTISE_ASSERT_ENABLED=0 (#137)` | Escape hatch: `ADVERTISE_ASSERT_ENABLED=0` disables the gate |
| `advertise assert disabled for a local master (#137)` | `localhost` master does not engage the assert |
| `advertise assert disabled for a non-roslaunch command (#137)` | Non-`roslaunch` command does not engage the assert |
| `advertise assert passes when ROS_IP resolves to itself (#137)` | `_assert_advertised`: `ROS_IP=192.168.1.5` resolves to itself -> `OK` -> return 0 (fake `getent`) |
| `advertise assert blocks a hostname resolving to loopback (#137)` | `ROS_HOSTNAME=rpi` resolving to `127.0.1.1` -> return non-zero + output shows `127.0.1.1` / `LOOPBACK` |
| `advertise assert blocks an unresolvable advertised host (#137)` | An unresolvable host (fake `getent` exits non-zero) -> return non-zero + output shows `UNRESOLVABLE` |
| `_addr_is_ip_literal classifies an IPv4 dotted-quad as a literal (#141)` | `_addr_is_ip_literal`: `203.0.113.10` -> literal (success), so it never reaches `getent` |
| `_addr_is_ip_literal classifies an IPv6 address as a literal (#141)` | `2001:db8::5` (any colon form) -> literal (success) |
| `_addr_is_ip_literal rejects a hostname (#141)` | `board.example.com` -> not a literal (failure), so names stay on the `getent` path |
| `_resolve_host_addr returns an IP literal without calling getent (#141)` | Regression for #141: fake `getent` always exits non-zero (the real reverse/PTR failure) -- the literal is still echoed back and a marker file proves `getent` was never invoked |
| `_resolve_host_addr still resolves a hostname through getent (#141)` | Name path unchanged: `getent` IS called and its first field (`198.51.100.7`) is returned |
| `advertise assert passes for a routable IP literal when getent fails (#141)` | Regression for #141 end-to-end: `ROS_IP=203.0.113.10` with a failing `getent` -> `_assert_advertised` returns 0 (pre-fix it printed `UNRESOLVABLE` and blocked startup) |
| `advertise assert still blocks a loopback IP literal when getent fails (#141)` | The short-circuit skips only the lookup: `ROS_IP=127.0.1.1` still -> non-zero + `127.0.1.1` / `LOOPBACK` |

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

### Camera config wiring (11)

| Test | Description |
|------|-------------|
| `camera config is baked into the image` | `/camera_config.yaml` exists (baked from the `camera.yaml` symlink target) |
| `default baked camera config is empty (stock upstream defaults)` | Default `none.yaml` is 0 bytes, so the stock CMD streams the upstream defaults |
| `entrypoint leaves the stock CMD unchanged for an empty config` | `_apply_camera_config` keeps the original argv when `/camera_config.yaml` is empty |
| `entrypoint appends config_file:= for a non-empty camera config` | A non-empty config appends `config_file:=/camera_config.yaml` to the `roslaunch /rs_camera.launch` argv (wrapper loads the profile) |
| `entrypoint does not hijack a non-roslaunch command even with a config` | Non-`roslaunch` command (devel `bash`) is left unchanged even when a profile is baked |
| `camera launch layers are baked into the image` | `/rs_camera_config.launch` (our config), `/rs_camera.launch` (entry target), `/rs_camera_remap.example.launch` (template) all exist |
| `camera launch files are well-formed XML (xmllint)` | `xmllint` validates all three baked launches -- regression for the `--`-in-comment bug that made roslaunch reject a launch and relaunch-loop |
| `entry target + example include our config (no logic duplication / drift)` | `/rs_camera.launch` and the template `<include>` `/rs_camera_config.launch` rather than re-deriving the bringup |
| `remap template declares the output-topic remaps before the include` | The template declares the color + aligned-depth `<remap>`s before the include (so they reach the node) |
| `Dockerfile CMD launches the entry target (/rs_camera.launch)` | Dockerfile CMD is `roslaunch /rs_camera.launch initial_reset:=true` |
| `Dockerfile declares CAMERA_CONFIG and COPYs it to /camera_config.yaml` | `ARG CAMERA_CONFIG="camera.yaml"` + `COPY --chmod=0644 "${CAMERA_CONFIG}" /camera_config.yaml` |

## test/smoke/filter_config.bats

### Filter config wiring (26)

| Test | Description |
|------|-------------|
| `filter config is baked into the image (#146)` | `/filter_config.yaml` exists (baked from the `filters.yaml` symlink target) |
| `default baked filter config is empty (no post-processing filters) (#146)` | Default `filters/none.yaml` is 0 bytes, so the shipped default runs no post-processing |
| `filters_list is read unquoted from a filter profile (#146)` | `_read_filters_list` returns a bare `filters_list` value |
| `filters_list is read with the double quotes stripped (#146)` | Double quotes are YAML syntax; roslaunch must receive the bare filter list |
| `filters_list is read with the single quotes stripped (#146)` | Same for single quotes |
| `filters_list is read with surrounding whitespace trimmed (#146)` | A stray trailing space would be parsed as part of the last filter name |
| `filters_list is read with internal whitespace stripped (#146)` | `"disparity, temporal"` normalises to `disparity,temporal`; the space would otherwise become part of the second name |
| `filters_list is read with an inline comment stripped (#146)` | `disparity,temporal  # smooth` would otherwise reach upstream as the name `temporal#smooth` |
| `filters_list is read with an inline comment after a quoted value stripped (#146)` | The comment is cut before the quotes are stripped, so the quotes do not survive into the `filters:=` token |
| `no filters_list is read when the key is absent (#146)` | The parser reports "absent" cleanly; refusing to start on it is the applier's job |
| `a commented-out filters_list line is not read as a value (#146)` | `# filters_list:` stays disabled -- a substring match would enable filters nobody asked for |
| `a malformed filters_list value is fatal and names the file and value (#146)` | A YAML sequence (`[disparity, temporal]`) exits non-zero with a FATAL block naming the profile file, the offending value and the fix |
| `every known-malformed filters_list form is rejected (#146)` | Sequence, block scalar (`>` / `\|`), `null`, unterminated quote, empty element, trailing comma, wrong case -- none may be accepted |
| `an unknown filter name is rejected against the upstream set (#146)` | A typo is fatal, not passed through: upstream's unknown-name branch terminates the nodelet manager |
| `an unreadable filter profile is fatal, not silently empty (#146)` | A chmod-000 profile fails loudly instead of reporting "no filters" while the launch still points at it |
| `a directory at the filter profile path is fatal (#146)` | `[ -s ]` is true for a directory, so a bind-mount landing one here must fail loudly |
| `entrypoint leaves the argv unchanged for an empty filter config (#146)` | `_apply_filter_config` keeps the original argv when `/filter_config.yaml` is empty |
| `entrypoint leaves the argv unchanged for a missing filter config (#146)` | A config bind-mounted away degrades to the stock CMD, not a roslaunch with an unreadable file |
| `entrypoint appends filter_config_file:= and filters:= for a non-empty filter config (#146)` | Both tokens together: one alone loads parameters for filters never constructed, the other alone constructs them with the librealsense defaults |
| `entrypoint applies the camera and filter profiles together (#146)` | The two appliers compose; neither drops the other's tokens (`config_file:=` asserted anchored so `filter_config_file:=` cannot satisfy it) |
| `entrypoint does not hijack a non-roslaunch command even with a filter config (#146)` | Non-`roslaunch` command (devel `bash`) is left unchanged even when a profile is baked |
| `a non-empty profile with no filters_list refuses to start (#146)` | Parameters without a filter list is a misconfiguration, not a "parameters-only" mode -- it exits instead of loading parameters nothing reads |
| `a malformed profile makes the applier fail so the entrypoint exits (#146)` | The parser's non-zero return propagates through `_apply_filter_config` (the entrypoint runs it with `|| exit 1`) |
| `an explicit filters:= on the command line is never overridden (#146)` | With `filters:=` already in the argv the baked profile is skipped entirely -- roslaunch takes the last value, so appending ours would silently win |
| `an explicit filter_config_file:= on the command line is never overridden (#146)` | Same last-wins guard for the other half of the pair |
| `every shipped filter profile parses to a valid filter list (#146)` | The profiles COPYed to `/lint/filters/` are parsed for real: a non-empty one that does not yield a whitelist-valid list fails the build (the other parser tests all use synthetic temp files) |

### Filter launch + Dockerfile wiring (5)

| Test | Description |
|------|-------------|
| `our config loads the filter profile into the public camera namespace (#146)` | xpath: the `filter_config_file` rosparam load has `ns="$(arg camera)"` and NOT `ns="$(arg camera)/realsense2_camera"` -- that one attribute is the whole feature |
| `our config forwards filters into the stock camera include (#146)` | xpath: `filters` is declared and forwarded *inside* the stock `rs_aligned_depth.launch` include, not merely present somewhere in the file |
| `entry target passes the filter profile args through to our config (#146)` | xpath: `/rs_camera.launch` declares both args and forwards them inside its `/rs_camera_config.launch` include |
| `remap template declares and forwards the filter profile args (#146)` | xpath: the copy-me override template every deployment starts from declares and forwards both args |
| `Dockerfile declares FILTER_CONFIG and COPYs it to /filter_config.yaml (#146)` | `ARG FILTER_CONFIG="filters.yaml"` + `COPY --chmod=0644 "${FILTER_CONFIG}" /filter_config.yaml` |

## test/smoke/profile_assert.bats

### Profile block parser (5)

| Test | Description |
|------|-------------|
| `profile blocks: a bare key with no inline value is a block (#149)` | A key at column 0 with nothing after the colon names a parameter namespace to verify |
| `profile blocks: a key with an inline value is not a block (#149)` | `filters_list` carries a value, so it names no namespace |
| `profile blocks: commented and indented keys are not blocks (#149)` | A commented-out or nested key must not be asserted on -- the example profile ships optional blocks commented out |
| `profile blocks: every block of a multi-block profile is listed (#149)` | A profile carrying filter *and* sensor blocks yields all of them |
| `profile blocks: shipped temporal_smooth.yaml declares temporal (#149)` | Parses the real shipped profile, not a synthetic temp file |

### Profile pre-flight verdict (9)

| Test | Description |
|------|-------------|
| `profile decide: OK when filters and blocks both landed (#149)` | Both halves present in the resolved launch tree is the only passing verdict |
| `profile decide: an empty-quoted filters value is the swallow (#149)` | The exact shape observed on hardware: roslaunch renders the dropped arg's default as `''` |
| `profile decide: a missing filters key is the swallow (#149)` | An absent key is the same failure as an empty one |
| `profile decide: a different filters value is reported verbatim (#149)` | An override hardcoding its own `filters:=` must show WHAT won, not just that it differs |
| `profile decide: filters through but parameters dropped is caught (#149)` | `filter_config_file:=` swallowed alone: filters constructed, every parameter silently at the librealsense default |
| `profile decide: OK when the profile declares no blocks (#149)` | `filters_list` with no parameter block is legal -- construct the filters, accept the defaults |
| `profile decide: a renamed camera namespace still matches (#149)` | `camera:=front_camera` must not defeat the assert |
| `profile decide: a large dump does not trip pipefail into a false miss (#149)` | Regression guard: `printf | grep -q` SIGPIPEs the writer once the dump outgrows the pipe buffer, and `pipefail` turns that into a false `BLOCK_MISSING`; here-strings avoid the pipeline. Verified to fail against the old form at 209 KB |
| `profile decide: every declared block must be present (#149)` | One missing block out of several is still a failure |

### Profile assert gate (4)

| Test | Description |
|------|-------------|
| `profile gate: engaged for a roslaunch carrying filters:= (#149)` | The gate engages exactly when a profile was applied |
| `profile gate: PROFILE_ASSERT_ENABLED=0 opts out (#149)` | Explicit bypass, mirroring `ADVERTISE_ASSERT_ENABLED` |
| `profile gate: not engaged for a non-roslaunch command (#149)` | The devel `bash` reaches the shell unchanged |
| `profile gate: not engaged when no profile was applied (#149)` | The default empty profile appends nothing, so there is nothing to assert and the boot stays byte-identical |

### Sensor options example profile (4)

| Test | Description |
|------|-------------|
| `sensor options example profile is shipped (#149)` | The copy-and-adapt template is present in `config/realsense/filters/` |
| `sensor options example declares filters_list (#149)` | The template must not teach a shape the entrypoint refuses to start on |
| `sensor options example declares the sensor blocks (#149)` | `temporal` + `rgb_camera` + `stereo_module`: one file reaches the filters and both sensors, which is why exposure needs no separate mechanism |
| `sensor options example keeps integer options unquoted integers (#149)` | roscpp never promotes double -> int, so `gain: 64.0` is silently ignored; the template must not model the broken form |

## test/smoke/dockerfile_guards.bats

### Dockerfile static guards (9)

| Test | Description |
|------|-------------|
| `groupadd new-group branch names the group after ${GROUP}, not ${USER} (#71)` | sys stage `groupadd` names the group after `${GROUP}` (not `${USER}`) |
| `version ARGs are pinned, not floating (#88)` | `ARG LIBREALSENSE_VERSION="v2.55.1"` + `ARG REALSENSE_ROS_VERSION="2.3.2"` are concrete pins |
| `no stage apt-installs the RealSense packages (#88 source build)` | No stage apt-installs `ros-${ROS_DISTRO}-realsense2-camera` / `-description` |
| `runtime-test smoke asserts the wrapper is discoverable (#88)` | runtime-test RUN contains `rospack find realsense2_camera` |
| `runtime-test ldd scan covers both the ROS lib dir and /usr/local (#88)` | runtime-test ldd scan spans `/opt/ros/${ROS_DISTRO}/lib` and `/usr/local/lib` |
| `devel-test lints the pre-build hook (COPY into /lint scope, #88)` | Dockerfile COPYs `script/hooks/pre/build.sh` into `/lint/hooks-pre-build.sh` for shellcheck |
| `pre-build hook no-ops when LIBREALSENSE_IMAGE is already set` | Hook exits 0 without building when `LIBREALSENSE_IMAGE` is set |
| `local librealsense SDK tag is version-scoped (Dockerfile default + hook agree)` | Dockerfile `LIBREALSENSE_IMAGE` default and hook `-t` both derive `librealsense:${LIBREALSENSE_VERSION}-${UBUNTU_CODENAME}` |
| `the bare librealsense:local tag is gone (a wrong version fails the build, not runs silently)` | No bare `librealsense:local` in the Dockerfile ARG default or the hook `-t` (a missing version fails the FROM) |

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
