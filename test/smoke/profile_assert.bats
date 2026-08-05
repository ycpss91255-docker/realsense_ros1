#!/usr/bin/env bats

setup() {
    load "${BATS_TEST_DIRNAME}/test_helper"
    SHIPPED_FILTERS_DIR="/lint/filters"
}

# -------------------- Profile pre-flight assert (#149) --------------------
#
# _apply_filter_config verifies the profile FILE, but nothing verified that the
# args it appends actually reach the node. roslaunch silently DROPS a top-level
# arg the launch file does not declare, so a deployment that bind-mounts its own
# /rs_camera.launch override -- one written before #146, or one that simply
# forgot to forward the two args into its <include> -- ran completely unfiltered
# while the entrypoint logged "Applying filter profile" and the process argv
# showed both args. Nothing warned. On hardware this surfaced as
# /camera/realsense2_camera/filters == '' with no /camera/temporal namespace at
# all.
#
# `roslaunch --dump-params` resolves the whole include tree OFFLINE -- no master,
# no device -- and prints the parameters that would actually be set, which makes
# the swallow detectable BEFORE anything starts. The assert compares that dump
# against what the entrypoint appended:
#
#   1. the `filters` parameter must equal the value we appended
#      (catches `filters:=` being dropped)
#   2. every top-level parameter block in the profile must appear as a namespace
#      (catches `filter_config_file:=` being dropped while `filters:=` gets
#      through -- filters constructed, but with librealsense defaults)
#
# A dump that cannot be produced is NOT fatal: roslaunch reports its own parse
# error a moment later, and a false positive here must never block a correct
# config. That is the #137 -> #141 lesson, where a reverse-DNS failure blocked a
# perfectly good ROS_IP.

# ---- _profile_param_blocks: which parameter blocks a profile declares ----

@test "profile blocks: a bare key with no inline value is a block (#149)" {
    run bash -c '
        f="$(mktemp)"; printf "temporal:\n  holes_fill: 0\n" > "$f"
        source /entrypoint.sh
        _profile_param_blocks "$f"
        rm -f "$f"'
    assert_success
    assert_output "temporal"
}

@test "profile blocks: a key with an inline value is not a block (#149)" {
    # filters_list carries a value, so it names no namespace to check for.
    run bash -c '
        f="$(mktemp)"; printf "filters_list: \"disparity,temporal\"\n" > "$f"
        source /entrypoint.sh
        _profile_param_blocks "$f"
        rm -f "$f"'
    assert_success
    assert_output ""
}

@test "profile blocks: commented and indented keys are not blocks (#149)" {
    # A commented-out block must not be asserted on, or selecting the example
    # profile with its optional blocks commented out would fail startup.
    run bash -c '
        f="$(mktemp)"
        printf "# rgb_camera:\n  nested:\n    x: 1\nreal:\n" > "$f"
        source /entrypoint.sh
        _profile_param_blocks "$f"
        rm -f "$f"'
    assert_success
    assert_output "real"
}

@test "profile blocks: every block of a multi-block profile is listed (#149)" {
    run bash -c '
        f="$(mktemp)"
        printf "filters_list: x\ntemporal:\n  a: 1\nrgb_camera:\n  b: 2\n" > "$f"
        source /entrypoint.sh
        _profile_param_blocks "$f"
        rm -f "$f"'
    assert_success
    assert_line --index 0 "temporal"
    assert_line --index 1 "rgb_camera"
}

@test "profile blocks: shipped temporal_smooth.yaml declares temporal (#149)" {
    run bash -c "
        source /entrypoint.sh
        _profile_param_blocks '${SHIPPED_FILTERS_DIR}/temporal_smooth.yaml'"
    assert_success
    assert_output "temporal"
}

# ---- _profile_decide: the verdict, given a dump ----

@test "profile decide: OK when filters and blocks both landed (#149)" {
    run bash -c '
        source /entrypoint.sh
        _profile_decide \
          "/camera/realsense2_camera/filters: disparity,temporal
/camera/temporal/holes_fill: 0" \
          "disparity,temporal" temporal'
    assert_success
    assert_output "OK"
}

@test "profile decide: an empty-quoted filters value is the swallow (#149)" {
    # The exact shape observed on hardware: roslaunch renders the dropped arg's
    # default (an empty string) as ''.
    run bash -c '
        source /entrypoint.sh
        _profile_decide "/camera/realsense2_camera/filters: '\'''\''" \
          "disparity,temporal" temporal'
    assert_success
    assert_output "FILTERS_SWALLOWED"
}

@test "profile decide: a missing filters key is the swallow (#149)" {
    run bash -c '
        source /entrypoint.sh
        _profile_decide "/camera/realsense2_camera/other: 1" \
          "disparity,temporal" temporal'
    assert_success
    assert_output "FILTERS_SWALLOWED"
}

@test "profile decide: a different filters value is reported verbatim (#149)" {
    # An override that hardcodes its own filters:= would land here. The operator
    # needs to see WHAT won, not just that it differs.
    run bash -c '
        source /entrypoint.sh
        _profile_decide "/camera/realsense2_camera/filters: pointcloud" \
          "disparity,temporal" temporal'
    assert_success
    assert_output "FILTERS_MISMATCH:pointcloud"
}

@test "profile decide: filters through but parameters dropped is caught (#149)" {
    # filter_config_file swallowed while filters survived: the filters ARE
    # constructed, but every parameter silently falls back to the librealsense
    # default -- the exact half-configured state #146 exists to prevent.
    run bash -c '
        source /entrypoint.sh
        _profile_decide "/camera/realsense2_camera/filters: disparity,temporal" \
          "disparity,temporal" temporal'
    assert_success
    assert_output "BLOCK_MISSING:temporal"
}

@test "profile decide: OK when the profile declares no blocks (#149)" {
    # filters_list with no parameter block is legal: construct the filters and
    # accept the librealsense defaults.
    run bash -c '
        source /entrypoint.sh
        _profile_decide "/camera/realsense2_camera/filters: disparity" disparity'
    assert_success
    assert_output "OK"
}

@test "profile decide: a renamed camera namespace still matches (#149)" {
    # camera:=front_camera must not defeat the assert.
    run bash -c '
        source /entrypoint.sh
        _profile_decide \
          "/front_camera/realsense2_camera/filters: temporal
/front_camera/temporal/holes_fill: 0" \
          "temporal" temporal'
    assert_success
    assert_output "OK"
}

@test "profile decide: a large dump does not trip pipefail into a false miss (#149)" {
    # Regression guard. The entrypoint runs under `set -euo pipefail`. Written as
    # `printf "%s" "$dump" | grep -q ...`, a match makes grep exit before printf
    # has finished writing; printf takes SIGPIPE, pipefail promotes that to the
    # pipeline's status, and a block that IS present reports BLOCK_MISSING. It
    # only bites once the dump outgrows the pipe buffer, so every small-input
    # test above passes either way. Here-strings avoid the pipeline entirely.
    run bash -c '
        set -euo pipefail
        source /entrypoint.sh
        # ~250 KB, comfortably past the 64 KB pipe buffer, with the matching
        # lines FIRST so grep -q would exit while the writer still has most of
        # the dump left to push.
        dump="$(printf "/camera/realsense2_camera/filters: temporal\n"
                printf "/camera/temporal/holes_fill: 0\n"
                seq 1 5000 | sed "s#^#/camera/realsense2_camera/padding_#; s#\$#: 0#")"
        _profile_decide "${dump}" temporal temporal'
    assert_success
    assert_output "OK"
}

@test "profile decide: every declared block must be present (#149)" {
    run bash -c '
        source /entrypoint.sh
        _profile_decide \
          "/camera/realsense2_camera/filters: temporal
/camera/temporal/holes_fill: 0" \
          "temporal" temporal rgb_camera'
    assert_success
    assert_output "BLOCK_MISSING:rgb_camera"
}

# ---- _profile_assert_enabled: the gate ----

@test "profile gate: engaged for a roslaunch carrying filters:= (#149)" {
    run bash -c '
        source /entrypoint.sh
        _profile_assert_enabled roslaunch /rs_camera.launch filters:=temporal'
    assert_success
}

@test "profile gate: PROFILE_ASSERT_ENABLED=0 opts out (#149)" {
    run bash -c '
        source /entrypoint.sh
        PROFILE_ASSERT_ENABLED=0 \
          _profile_assert_enabled roslaunch /rs_camera.launch filters:=temporal'
    assert_failure
}

@test "profile gate: not engaged for a non-roslaunch command (#149)" {
    # The devel image runs `bash`; it must reach the shell unchanged.
    run bash -c '
        source /entrypoint.sh
        _profile_assert_enabled bash filters:=temporal'
    assert_failure
}

@test "profile gate: not engaged when no profile was applied (#149)" {
    # The default empty profile appends nothing, so there is nothing to assert.
    run bash -c '
        source /entrypoint.sh
        _profile_assert_enabled roslaunch /rs_camera.launch initial_reset:=true'
    assert_failure
}

# ---- shipped example profile ----

@test "sensor options example profile is shipped (#149)" {
    assert [ -f "${SHIPPED_FILTERS_DIR}/sensor_options.example.yaml" ]
}

@test "sensor options example declares filters_list (#149)" {
    # A non-empty profile without filters_list is fatal at startup, so the
    # template must not teach a shape the entrypoint refuses.
    run bash -c "
        source /entrypoint.sh
        _read_filters_list '${SHIPPED_FILTERS_DIR}/sensor_options.example.yaml'"
    assert_success
    assert_output "disparity,temporal"
}

@test "sensor options example declares the sensor blocks (#149)" {
    # The point of the template: one file reaches the filters AND both sensors,
    # which is why exposure needs no separate mechanism.
    run bash -c "
        source /entrypoint.sh
        _profile_param_blocks '${SHIPPED_FILTERS_DIR}/sensor_options.example.yaml'"
    assert_success
    assert_line "temporal"
    assert_line "rgb_camera"
    assert_line "stereo_module"
}

@test "sensor options example keeps integer options unquoted integers (#149)" {
    # roscpp promotes int -> double but never double -> int, so gain: 64.0 is
    # silently ignored. The template must not model the broken form.
    run grep -E "^\s+(gain|exposure|filter_smooth_delta|holes_fill):" \
        "${SHIPPED_FILTERS_DIR}/sensor_options.example.yaml"
    assert_success
    refute_output --regexp "[0-9]\.[0-9]"
}
