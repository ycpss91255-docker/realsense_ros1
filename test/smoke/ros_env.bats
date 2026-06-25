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

# -------------------- RealSense packages --------------------

@test "realsense2_camera is installed" {
    run dpkg -l ros-${ROS_DISTRO}-realsense2-camera
    assert_success
}

@test "realsense2_description is installed" {
    run dpkg -l ros-${ROS_DISTRO}-realsense2-description
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
