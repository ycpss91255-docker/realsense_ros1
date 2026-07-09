#!/usr/bin/env bats

setup() {
    load "${BATS_TEST_DIRNAME}/test_helper"
}

# -------------------- Camera config wiring --------------------
#
# The Dockerfile bakes the repo-root `camera.yaml` symlink's target into the
# image as /camera_config.yaml (default target config/realsense/custom/none.yaml
# is EMPTY = stream the stock upstream defaults). The entrypoint appends
# `config_file:=/camera_config.yaml` to the roslaunch argv only when that file
# is NON-empty AND the command is roslaunch; the wrapper launch
# (/rs_camera_config.launch) then rosparam-loads the profile. Sourcing the
# entrypoint runs only the pure functions; the ROS-source + exec are guarded to
# the real invocation, so these tests can source it safely.

@test "camera config is baked into the image" {
    assert [ -f "/camera_config.yaml" ]
}

@test "default baked camera config is empty (stock upstream defaults)" {
    # none.yaml is a 0-byte marker: [ -s ] is false, so the entrypoint keeps the
    # stock CMD -> the camera streams the upstream defaults (640x480x30).
    assert [ ! -s "/camera_config.yaml" ]
}

@test "entrypoint leaves the stock CMD unchanged for an empty config" {
    run bash -c 'source /entrypoint.sh; _apply_camera_config roslaunch /rs_camera_config.launch initial_reset:=true; echo "${CONFIGURED_ARGV[@]}"'
    assert_success
    assert_output "roslaunch /rs_camera_config.launch initial_reset:=true"
}

@test "entrypoint appends config_file:= for a non-empty camera config" {
    run bash -c '
        f="$(mktemp)"; printf "color_width: 640\n" > "$f"
        source /entrypoint.sh
        CAMERA_CONFIG_FILE="$f"
        _apply_camera_config roslaunch /rs_camera_config.launch initial_reset:=true
        echo "${CONFIGURED_ARGV[@]}"
        rm -f "$f"'
    assert_success
    assert_output --partial "roslaunch /rs_camera_config.launch initial_reset:=true"
    assert_output --partial "config_file:=/tmp/"
}

@test "entrypoint does not hijack a non-roslaunch command even with a config" {
    # The devel image ships CMD bash; a baked profile must not turn it into a
    # camera launch.
    run bash -c '
        f="$(mktemp)"; printf "color_width: 640\n" > "$f"
        source /entrypoint.sh
        CAMERA_CONFIG_FILE="$f"
        _apply_camera_config bash
        rm -f "$f"
        echo "${CONFIGURED_ARGV[@]}"'
    assert_success
    assert_output "bash"
}
