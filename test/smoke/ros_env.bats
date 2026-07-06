#!/usr/bin/env bats

setup() {
    load "${BATS_TEST_DIRNAME}/test_helper"
}

# -------------------- ROS environment --------------------

@test "ROS_DISTRO is set" {
    assert [ -n "${ROS_DISTRO}" ]
}

@test "ROS 1 setup.bash exists" {
    assert [ -f "/opt/ros/${ROS_DISTRO}/setup.bash" ]
}

@test "ROS 1 setup.bash can be sourced" {
    run bash -c "source /opt/ros/${ROS_DISTRO}/setup.bash"
    assert_success
}

@test "interactive shells source ROS (roslaunch on PATH via bashrc.d)" {
    # The base bashrc is ROS-agnostic and loads ~/.bashrc.d/*.sh for interactive
    # shells; this repo ships config/shell/bashrc.d/10-ros-source.sh to source
    # ROS. Without it, roslaunch / roscore / realsense-viewer are "command not
    # found" in interactive just run / just exec shells even though installed.
    assert [ -f "${HOME}/.bashrc.d/10-ros-source.sh" ]
    run bash -c "source ${HOME}/.bashrc.d/10-ros-source.sh && command -v roslaunch"
    assert_success
    assert_output --partial "/opt/ros/${ROS_DISTRO}/bin/roslaunch"
}

# -------------------- Entrypoint: remote-master wait --------------------
#
# entrypoint.sh resolves the final argv into RESOLVED_ARGV without executing,
# so the decision is unit-testable without a live master. When ROS_MASTER_URI
# points at a remote master AND the command is roslaunch, it injects
# `roslaunch --wait` (blocks until the master is reachable, then launches),
# fixing the multi-machine slave boot race (#79). Sourcing the entrypoint runs
# only the pure functions; the ROS-source + exec are guarded to the real
# entrypoint invocation, so these tests can source it safely.

@test "entrypoint injects --wait for a remote master + roslaunch (#79)" {
    run bash -c 'export ROS_MASTER_URI=http://192.168.1.5:11311; source /entrypoint.sh; _resolve_argv roslaunch pkg foo.launch; echo "${RESOLVED_ARGV[@]}"'
    assert_success
    assert_output "roslaunch --wait pkg foo.launch"
}

@test "entrypoint does not inject --wait for a local master (#79)" {
    run bash -c 'export ROS_MASTER_URI=http://localhost:11311; source /entrypoint.sh; _resolve_argv roslaunch pkg foo.launch; echo "${RESOLVED_ARGV[@]}"'
    assert_success
    assert_output "roslaunch pkg foo.launch"
}

@test "entrypoint does not inject --wait when ROS_MASTER_URI is unset (#79)" {
    run bash -c 'unset ROS_MASTER_URI; source /entrypoint.sh; _resolve_argv roslaunch pkg foo.launch; echo "${RESOLVED_ARGV[@]}"'
    assert_success
    assert_output "roslaunch pkg foo.launch"
}

@test "entrypoint passes non-roslaunch commands through unchanged (#79)" {
    run bash -c 'export ROS_MASTER_URI=http://192.168.1.5:11311; source /entrypoint.sh; _resolve_argv bash -c "echo hi"; echo "${RESOLVED_ARGV[@]}"'
    assert_success
    assert_output "bash -c echo hi"
}

@test "entrypoint does not double-inject --wait when already present (#79)" {
    run bash -c 'export ROS_MASTER_URI=http://192.168.1.5:11311; source /entrypoint.sh; _resolve_argv roslaunch --wait pkg foo.launch; echo "${RESOLVED_ARGV[@]}"'
    assert_success
    assert_output "roslaunch --wait pkg foo.launch"
}

# -------------------- Entrypoint: remote-master watchdog --------------------
#
# On top of the boot gate (#79/#80), when the master is remote the entrypoint
# can run a watchdog: it (re)launches `roslaunch --wait` and restarts it if our
# node stays deregistered (a remote master restarted on the same port stays
# TCP-reachable but leaves roslaunch alive and unregistered). The watchdog is
# opt-in (default off, consistent with base `[lifecycle] restart = no`); enable
# it with `WATCHDOG_ENABLED=1`. The gate (`--wait`) still applies regardless.
# The enable-decision and the registration check are factored into pure
# functions so these tests never start the real while-loop (which is guarded to
# the real entrypoint invocation and hardware-verified separately).

@test "watchdog off by default for a remote master + roslaunch (#81)" {
    run bash -c 'export ROS_MASTER_URI=http://192.168.1.5:11311; unset WATCHDOG_ENABLED; source /entrypoint.sh; _watchdog_enabled roslaunch pkg foo.launch'
    assert_failure
}

@test "watchdog enabled with WATCHDOG_ENABLED=1 + remote master + roslaunch (#81)" {
    run bash -c 'export ROS_MASTER_URI=http://192.168.1.5:11311 WATCHDOG_ENABLED=1; source /entrypoint.sh; _watchdog_enabled roslaunch pkg foo.launch'
    assert_success
}

@test "watchdog disabled when WATCHDOG_ENABLED=0 (#81)" {
    run bash -c 'export ROS_MASTER_URI=http://192.168.1.5:11311 WATCHDOG_ENABLED=0; source /entrypoint.sh; _watchdog_enabled roslaunch pkg foo.launch'
    assert_failure
}

@test "watchdog disabled for a local master even with WATCHDOG_ENABLED=1 (#81)" {
    run bash -c 'export ROS_MASTER_URI=http://localhost:11311 WATCHDOG_ENABLED=1; source /entrypoint.sh; _watchdog_enabled roslaunch pkg foo.launch'
    assert_failure
}

@test "watchdog disabled for a non-roslaunch command even with WATCHDOG_ENABLED=1 (#81)" {
    run bash -c 'export ROS_MASTER_URI=http://192.168.1.5:11311 WATCHDOG_ENABLED=1; source /entrypoint.sh; _watchdog_enabled bash -c "echo hi"'
    assert_failure
}

@test "watchdog node present in rosnode list is healthy (#81)" {
    run bash -c 'source /entrypoint.sh; _node_registered /camera/realsense2_camera "$(printf "%s\n" /rosout /camera/realsense2_camera)"'
    assert_success
}

@test "watchdog node absent from rosnode list is unhealthy (#81)" {
    run bash -c 'source /entrypoint.sh; _node_registered /camera/realsense2_camera "$(printf "%s\n" /rosout /other_node)"'
    assert_failure
}

@test "watchdog stops the roslaunch child with SIGTERM, not SIGINT (#81)" {
    # The roslaunch child is started async (`roslaunch ... &`), so a
    # non-interactive shell sets its SIGINT/SIGQUIT to SIG_IGN (POSIX). `kill
    # -INT` on it would be ignored and the following `wait` would hang forever
    # (verified: restart-on-orphan and clean shutdown both stall). The watchdog
    # must signal the child with SIGTERM, which is not ignored and which
    # roslaunch handles with a clean node shutdown.
    run grep -F 'kill -INT' /entrypoint.sh
    assert_failure
    run grep -F 'kill -TERM "${_WATCHDOG_CHILD_PID}"' /entrypoint.sh
    assert_success
}

# -------------------- RealSense packages (source-built, #88) --------------------
# The apt ros-${ROS_DISTRO}-realsense2-* packages were removed; librealsense
# v2.55.1 (SDK) + the ros1-legacy realsense-ros 2.3.2 wrapper are built from
# source and real-installed into /opt/ros/${ROS_DISTRO} (devel). Assert the
# wrapper is on ROS_PACKAGE_PATH and the SDK library landed in the ROS tree.

@test "realsense2_camera discoverable via rospack" {
    run bash -c "source /opt/ros/${ROS_DISTRO}/setup.bash && rospack find realsense2_camera"
    assert_success
}

@test "librealsense2 SDK library present" {
    run bash -c "ls /opt/ros/${ROS_DISTRO}/lib/librealsense2.so*"
    assert_success
}

# -------------------- Desktop GUI (devel) --------------------

@test "rqt_image_view is available (devel GUI; backs the README demo)" {
    # devel-base installs ros-${ROS_DISTRO}-desktop, which ships rqt_image_view.
    # The README RGB-D demo tells users to `rosrun rqt_image_view rqt_image_view`
    # from the devel image, so guard that the package is actually present.
    run dpkg -l ros-${ROS_DISTRO}-rqt-image-view
    assert_success
}

# -------------------- Base tools --------------------

@test "git is available" {
    run git --version
    assert_success
}

@test "vim is available" {
    run vim --version
    assert_success
}

@test "sudo is available" {
    run sudo --version
    assert_success
}

@test "sudo passwordless works" {
    run sudo true
    assert_success
}

# -------------------- System --------------------

@test "User is not root" {
    assert [ "$(id -u)" -ne 0 ]
}

@test "HOME is set and exists" {
    assert [ -n "${HOME}" ]
    assert [ -d "${HOME}" ]
}

@test "Timezone is Asia/Taipei" {
    run cat /etc/timezone
    assert_output "Asia/Taipei"
}

@test "LANG is en_US.UTF-8" {
    assert_equal "${LANG}" "en_US.UTF-8"
}

@test "LC_ALL is en_US.UTF-8" {
    assert_equal "${LC_ALL}" "en_US.UTF-8"
}

@test "entrypoint.sh exists and executable" {
    assert [ -x "/entrypoint.sh" ]
}

@test "RealSense udev rules exist" {
    assert [ -f "/etc/udev/rules.d/99-realsense-libusb.rules" ]
}

@test "Work directory exists" {
    assert [ -d "${HOME}/work" ]
}
