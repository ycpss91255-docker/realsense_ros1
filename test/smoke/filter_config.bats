#!/usr/bin/env bats

setup() {
    load "${BATS_TEST_DIRNAME}/test_helper"
    DOCKERFILE="/lint/Dockerfile"
    SHIPPED_FILTERS_DIR="/lint/filters"
}

# -------------------- Filter config wiring --------------------
#
# Mirror of the camera-profile mechanism, for librealsense post-processing
# filters. The Dockerfile bakes the repo-root `filters.yaml` symlink's target
# into the image as /filter_config.yaml (default target
# config/realsense/filters/none.yaml is EMPTY = no post-processing). For a
# NON-empty profile the entrypoint appends BOTH
# `filter_config_file:=/filter_config.yaml` (so the wrapper rosparam-loads the
# filter parameters into the PUBLIC camera namespace, where each filter's
# nodelet reads them) AND `filters:=<value>` read out of the profile's
# `filters_list` key (so the node actually constructs those filters) -- or it
# refuses to start. One file owns both halves: enabling a filter without its
# parameters silently falls back to the librealsense defaults, and loading
# parameters for filters that are never constructed does nothing at all;
# nothing warns in either case. There is deliberately no "parameters-only" mode.
#
# `filters_list` is entrypoint-facing, not ROS-facing, but it still lands on the
# parameter server, so it must be a legal ROS graph resource name -- a leading
# underscore is not (roscpp getParam() throws InvalidNameException).
#
# The value is validated against the closed set upstream realsense-ros 2.3.2
# `setupFilters()` accepts. Its `else` branch does `ROS_ERROR_STREAM(...);
# throw;` -- a bare re-throw with no active exception, i.e. std::terminate(),
# which kills the nodelet manager; the manager is not `required`, so roslaunch
# survives, the node never registers, and the #136 watchdog relaunches into the
# same crash forever. Every malformed form below is therefore fatal at startup.

@test "filter config is baked into the image (#146)" {
    assert [ -f "/filter_config.yaml" ]
}

@test "default baked filter config is empty (no post-processing filters) (#146)" {
    # none.yaml is a 0-byte marker: [ -s ] is false, so the entrypoint keeps the
    # stock CMD -> the camera streams unfiltered, exactly as before this feature.
    assert [ ! -s "/filter_config.yaml" ]
}

@test "filters_list is read unquoted from a filter profile (#146)" {
    run bash -c '
        f="$(mktemp)"; printf "filters_list: disparity,temporal\n" > "$f"
        source /entrypoint.sh
        _read_filters_list "$f"
        rm -f "$f"'
    assert_success
    assert_output "disparity,temporal"
}

@test "filters_list is read with the double quotes stripped (#146)" {
    # The profile shipped by this repo quotes the value (it contains a comma),
    # but the quotes are YAML syntax -- roslaunch must receive the bare list.
    run bash -c '
        f="$(mktemp)"; printf "filters_list: \"disparity,temporal\"\n" > "$f"
        source /entrypoint.sh
        _read_filters_list "$f"
        rm -f "$f"'
    assert_success
    assert_output "disparity,temporal"
}

@test "filters_list is read with the single quotes stripped (#146)" {
    # \047 is a literal single quote (it cannot be typed inside the surrounding
    # single-quoted bash -c script).
    run bash -c '
        f="$(mktemp)"; printf "filters_list: \047disparity,temporal\047\n" > "$f"
        source /entrypoint.sh
        _read_filters_list "$f"
        rm -f "$f"'
    assert_success
    assert_output "disparity,temporal"
}

@test "filters_list is read with surrounding whitespace trimmed (#146)" {
    # A stray trailing space would otherwise reach roslaunch inside the
    # filters:= token and be parsed as part of the last filter name.
    run bash -c '
        f="$(mktemp)"; printf "filters_list:    \"disparity,temporal\"   \n" > "$f"
        source /entrypoint.sh
        _read_filters_list "$f"
        rm -f "$f"'
    assert_success
    assert_output "disparity,temporal"
}

@test "filters_list is read with internal whitespace stripped (#146)" {
    # `disparity, temporal` is the natural way to write a YAML list of two
    # things; unstripped, the space would make the second filter name " temporal"
    # and upstream would terminate on it.
    run bash -c '
        f="$(mktemp)"; printf "filters_list: \"disparity, temporal\"\n" > "$f"
        source /entrypoint.sh
        _read_filters_list "$f"
        rm -f "$f"'
    assert_success
    assert_output "disparity,temporal"
}

@test "filters_list is read with an inline comment stripped (#146)" {
    # Unstripped, the comment becomes part of the value: the second filter name
    # would be `temporal#smooth`, which terminates the nodelet manager.
    run bash -c '
        f="$(mktemp)"; printf "filters_list: disparity,temporal  # smooth\n" > "$f"
        source /entrypoint.sh
        _read_filters_list "$f"
        rm -f "$f"'
    assert_success
    assert_output "disparity,temporal"
}

@test "filters_list is read with an inline comment after a quoted value stripped (#146)" {
    # The comment must go BEFORE the quote stripping, otherwise the value no
    # longer ends in a quote and the quotes survive into the filters:= token.
    run bash -c '
        f="$(mktemp)"; printf "filters_list: \"disparity,temporal\" # smooth\n" > "$f"
        source /entrypoint.sh
        _read_filters_list "$f"
        rm -f "$f"'
    assert_success
    assert_output "disparity,temporal"
}

@test "no filters_list is read when the key is absent (#146)" {
    # The parser reports "absent"; refusing to start on that is the applier's
    # job (see the parameters-only test below), so this stays a clean empty read.
    run bash -c '
        f="$(mktemp)"; printf "temporal:\n  filter_smooth_alpha: 0.1\n" > "$f"
        source /entrypoint.sh
        _read_filters_list "$f"
        rm -f "$f"'
    assert_success
    assert_output ""
}

@test "a commented-out filters_list line is not read as a value (#146)" {
    # Commenting the key out is how a profile is meant to be disabled while its
    # parameters stay documented in the file; a substring match would resurrect
    # it and enable filters nobody asked for.
    run bash -c '
        f="$(mktemp)"
        printf "# filters_list: \"disparity,temporal\"\ntemporal:\n  filter_smooth_alpha: 0.1\n" > "$f"
        source /entrypoint.sh
        _read_filters_list "$f"
        rm -f "$f"'
    assert_success
    assert_output ""
}

@test "a malformed filters_list value is fatal and names the file and value (#146)" {
    # The YAML sequence form is the most likely way to write this key wrong, and
    # it used to be passed through verbatim: roslaunch would take
    # `filters:=[disparity, temporal]` and the node would terminate on the
    # `[disparity` name. Fail here instead, with a message an operator can act on.
    run bash -c '
        f="$(mktemp)"; printf "filters_list: [disparity, temporal]\n" > "$f"
        source /entrypoint.sh
        _read_filters_list "$f"
        rm -f "$f"'
    assert_failure
    assert_output --partial "FATAL"
    assert_output --partial "/tmp/"
    assert_output --partial "[disparity,temporal]"
    assert_output --partial 'filters_list: "disparity,temporal"'
}

@test "every known-malformed filters_list form is rejected (#146)" {
    # Every form here was verified to reach upstream as a bogus filter name (or
    # as literal YAML syntax) before the validation existed. Accepting any one of
    # them is a permanent crash loop, so the test lists them explicitly.
    run bash -c '
        source /entrypoint.sh
        f="$(mktemp)"
        accepted=""
        while IFS= read -r v; do
            printf "%s\n" "$v" > "$f"
            if _read_filters_list "$f" >/dev/null 2>&1; then
                accepted="${accepted}[${v}] "
            fi
        done <<EOF
filters_list: [disparity, temporal]
filters_list: >
filters_list: |
filters_list: null
filters_list: "disparity
filters_list: disparity,,temporal
filters_list: disparity,
filters_list: DISPARITY
EOF
        rm -f "$f"
        printf "%s" "${accepted}"'
    assert_success
    assert_output ""
}

@test "an unknown filter name is rejected against the upstream set (#146)" {
    # A typo is not a "pass it through and let ROS decide" case: upstream's
    # unknown-name branch terminates the process.
    run bash -c '
        f="$(mktemp)"; printf "filters_list: \"disparity,temperal\"\n" > "$f"
        source /entrypoint.sh
        _read_filters_list "$f"
        rm -f "$f"'
    assert_failure
    assert_output --partial "FATAL"
    assert_output --partial "hole_filling"
}

@test "an unreadable filter profile is fatal, not silently empty (#146)" {
    # The old parser sent grep's error to /dev/null and returned "no filters",
    # while the caller still pointed roslaunch at the same unreadable file.
    run bash -c '
        f="$(mktemp)"; printf "filters_list: \"disparity,temporal\"\n" > "$f"
        chmod 000 "$f"
        source /entrypoint.sh
        FILTER_CONFIG_FILE="$f"
        _apply_filter_config roslaunch /rs_camera.launch initial_reset:=true
        rm -f "$f"'
    assert_failure
    assert_output --partial "FATAL"
    assert_output --partial "not a readable file"
}

@test "a directory at the filter profile path is fatal (#146)" {
    # `[ -s ]` is true for a directory, so a bind-mount that lands a directory
    # here passes the "a profile is baked in" gate and must fail loudly.
    run bash -c '
        d="$(mktemp -d)"
        source /entrypoint.sh
        FILTER_CONFIG_FILE="$d"
        _apply_filter_config roslaunch /rs_camera.launch initial_reset:=true
        rmdir "$d"'
    assert_failure
    assert_output --partial "FATAL"
    assert_output --partial "not a readable file"
}

@test "entrypoint leaves the argv unchanged for an empty filter config (#146)" {
    run bash -c 'source /entrypoint.sh; _apply_filter_config roslaunch /rs_camera.launch initial_reset:=true; echo "${CONFIGURED_ARGV[@]}"'
    assert_success
    assert_output "roslaunch /rs_camera.launch initial_reset:=true"
}

@test "entrypoint leaves the argv unchanged for a missing filter config (#146)" {
    # A deployment may bind-mount /filter_config.yaml away entirely; that must
    # degrade to the stock CMD, not to a roslaunch with an unreadable file.
    run bash -c '
        source /entrypoint.sh
        FILTER_CONFIG_FILE="/nonexistent/filter_config.yaml"
        _apply_filter_config roslaunch /rs_camera.launch initial_reset:=true
        echo "${CONFIGURED_ARGV[@]}"'
    assert_success
    assert_output "roslaunch /rs_camera.launch initial_reset:=true"
}

@test "entrypoint appends filter_config_file:= and filters:= for a non-empty filter config (#146)" {
    # BOTH tokens, always together: filter_config_file:= alone loads parameters
    # for filters that were never constructed, filters:= alone constructs them
    # with the librealsense defaults (temporal alpha 0.4 instead of 0.1).
    run bash -c '
        f="$(mktemp)"
        printf "filters_list: \"disparity,temporal\"\ntemporal:\n  filter_smooth_alpha: 0.1\n" > "$f"
        source /entrypoint.sh
        FILTER_CONFIG_FILE="$f"
        _apply_filter_config roslaunch /rs_camera.launch initial_reset:=true
        echo "${CONFIGURED_ARGV[@]}"
        rm -f "$f"'
    assert_success
    assert_output --partial "roslaunch /rs_camera.launch initial_reset:=true"
    assert_output --partial "filter_config_file:=/tmp/"
    assert_output --partial "filters:=disparity,temporal"
}

@test "entrypoint applies the camera and filter profiles together (#146)" {
    # The two mechanisms are independent and compose: a stream profile and a
    # filter profile can be selected at the same time, and neither may drop the
    # other's tokens. config_file:= is asserted anchored so it cannot be
    # satisfied by the filter_config_file:= token that contains it.
    run bash -c '
        c="$(mktemp)"; printf "color_width: 640\n" > "$c"
        f="$(mktemp)"; printf "filters_list: \"disparity,temporal\"\n" > "$f"
        source /entrypoint.sh
        CAMERA_CONFIG_FILE="$c"
        FILTER_CONFIG_FILE="$f"
        _apply_camera_config roslaunch /rs_camera.launch initial_reset:=true
        _apply_filter_config "${CONFIGURED_ARGV[@]}"
        echo "${CONFIGURED_ARGV[@]}"
        rm -f "$c" "$f"'
    assert_success
    assert_output --partial "roslaunch /rs_camera.launch initial_reset:=true"
    assert_output --regexp "(^| )config_file:=/tmp/"
    assert_output --partial "filter_config_file:=/tmp/"
    assert_output --partial "filters:=disparity,temporal"
}

@test "entrypoint does not hijack a non-roslaunch command even with a filter config (#146)" {
    # The devel image ships CMD bash; a baked filter profile must not turn it
    # into a camera launch. Same gate as the camera profile.
    run bash -c '
        f="$(mktemp)"; printf "filters_list: \"disparity,temporal\"\n" > "$f"
        source /entrypoint.sh
        FILTER_CONFIG_FILE="$f"
        _apply_filter_config bash
        rm -f "$f"
        echo "${CONFIGURED_ARGV[@]}"'
    assert_success
    assert_output "bash"
}

@test "a non-empty profile with no filters_list refuses to start (#146)" {
    # Not a "parameters-only" mode: the parameters are read from each FILTER, so
    # loading them without constructing any filter does nothing at all. Failing
    # here is also what makes the YAML block-list form (a `filters_list:` with
    # its items on following lines) loud instead of inert.
    run bash -c '
        f="$(mktemp)"
        printf "temporal:\n  filter_smooth_alpha: 0.1\n" > "$f"
        source /entrypoint.sh
        FILTER_CONFIG_FILE="$f"
        _apply_filter_config roslaunch /rs_camera.launch initial_reset:=true
        rm -f "$f"'
    assert_failure
    assert_output --partial "FATAL"
    assert_output --partial "no \`filters_list\` key"
}

@test "a malformed profile makes the applier fail so the entrypoint exits (#146)" {
    # The parser's non-zero return must propagate: the entrypoint runs
    # `_apply_filter_config "$@" || exit 1`, so a swallowed failure here would
    # launch the camera with the malformed value anyway.
    run bash -c '
        f="$(mktemp)"; printf "filters_list: [disparity, temporal]\n" > "$f"
        source /entrypoint.sh
        FILTER_CONFIG_FILE="$f"
        _apply_filter_config roslaunch /rs_camera.launch initial_reset:=true
        rm -f "$f"'
    assert_failure
    assert_output --partial "FATAL"
}

@test "an explicit filters:= on the command line is never overridden (#146)" {
    # README documents `... rs_camera.launch filters:=pointcloud`. roslaunch
    # takes the LAST value of a repeated arg, so appending the baked profile's
    # filters:= after the operator's would silently override the command line.
    run bash -c '
        f="$(mktemp)"; printf "filters_list: \"disparity,temporal\"\n" > "$f"
        source /entrypoint.sh
        FILTER_CONFIG_FILE="$f"
        _apply_filter_config roslaunch /rs_camera.launch filters:=pointcloud
        echo "ARGV: ${CONFIGURED_ARGV[@]}"
        rm -f "$f"'
    assert_success
    assert_output --partial "ARGV: roslaunch /rs_camera.launch filters:=pointcloud"
    refute_output --partial "filters:=disparity,temporal"
    refute_output --partial "filter_config_file:="
}

@test "an explicit filter_config_file:= on the command line is never overridden (#146)" {
    # Same last-wins hazard for the other half of the pair.
    run bash -c '
        f="$(mktemp)"; printf "filters_list: \"disparity,temporal\"\n" > "$f"
        source /entrypoint.sh
        FILTER_CONFIG_FILE="$f"
        _apply_filter_config roslaunch /rs_camera.launch filter_config_file:=/my.yaml
        echo "ARGV: ${CONFIGURED_ARGV[@]}"
        rm -f "$f"'
    assert_success
    assert_output --partial "ARGV: roslaunch /rs_camera.launch filter_config_file:=/my.yaml"
    refute_output --partial "filters:=disparity,temporal"
}

@test "every shipped filter profile parses to a valid filter list (#146)" {
    # The parser tests above all use synthetic temp files, so rewriting a
    # SHIPPED profile into a form the parser rejects would leave them green and
    # ship a filter-less (or crash-looping) image. The profiles are COPYed into
    # the devel-test stage's lint area and parsed here for real; a non-empty
    # profile that does not yield a whitelist-valid list fails the build.
    run bash -c '
        source /entrypoint.sh
        shopt -s nullglob
        checked=0
        for f in '"${SHIPPED_FILTERS_DIR}"'/*.yaml; do
            [[ -s "$f" ]] || continue
            list="$(_read_filters_list "$f")"
            [[ -n "$list" ]] || { printf "no filters_list in %s\n" "$f"; exit 1; }
            printf "%s -> %s\n" "$f" "$list"
            checked=$((checked + 1))
        done
        (( checked > 0 )) || { printf "no non-empty shipped profile found\n"; exit 1; }'
    assert_success
    assert_output --partial "temporal_smooth.yaml -> disparity,temporal"
}

# -------------------- Filter launch + Dockerfile wiring --------------------
#
# The filter parameters must land in the PUBLIC camera namespace (<camera>/
# temporal/filter_smooth_alpha), not in <camera>/realsense2_camera where the
# stream profile goes -- registerDynamicOption() reads them from the filter's
# own node handle. That one `ns` attribute is the whole feature, so it is
# asserted with xpath rather than grep: grep cannot tell a correctly placed
# attribute from an identical string sitting somewhere inert.
#
# `filters` itself is a stock rs_aligned_depth.launch arg, so both repo-owned
# launch layers -- and the copy-me remap template every deployment override
# starts from -- have to declare and forward it, otherwise the filters:= token
# the entrypoint appends dies at the top level and the mechanism is inert.

@test "our config loads the filter profile into the public camera namespace (#146)" {
    assert_file_exists "/rs_camera_config.launch"
    run xmllint --xpath 'count(/launch/arg[@name="filter_config_file"][@default=""])' /rs_camera_config.launch
    assert_success
    assert_output "1"
    # The rosparam load must target $(arg camera) ...
    run xmllint --xpath 'string(/launch/group/rosparam[@file="$(arg filter_config_file)"]/@ns)' /rs_camera_config.launch
    assert_success
    assert_output '$(arg camera)'
    # ... and specifically NOT the node namespace the stream profile uses, where
    # nothing would read the parameters and every filter would silently fall
    # back to the librealsense defaults.
    run xmllint --xpath 'count(/launch/group/rosparam[@file="$(arg filter_config_file)"][@ns="$(arg camera)/realsense2_camera"])' /rs_camera_config.launch
    assert_success
    assert_output "0"
}

@test "our config forwards filters into the stock camera include (#146)" {
    assert_file_exists "/rs_camera_config.launch"
    run xmllint --xpath 'count(/launch/arg[@name="filters"][@default=""])' /rs_camera_config.launch
    assert_success
    assert_output "1"
    # Inside the rs_aligned_depth.launch include, not merely somewhere in the
    # file: an <arg> outside the include is inert.
    run xmllint --xpath 'string(/launch/include[@file="$(find realsense2_camera)/launch/rs_aligned_depth.launch"]/arg[@name="filters"]/@value)' /rs_camera_config.launch
    assert_success
    assert_output '$(arg filters)'
}

@test "entry target passes the filter profile args through to our config (#146)" {
    # /rs_camera.launch is the roslaunch target, so an arg it does not declare
    # never reaches /rs_camera_config.launch -- and one it declares but does not
    # forward inside the include is accepted and dropped.
    assert_file_exists "/rs_camera.launch"
    run xmllint --xpath 'count(/launch/arg[@name="filter_config_file"][@default=""])' /rs_camera.launch
    assert_success
    assert_output "1"
    run xmllint --xpath 'count(/launch/arg[@name="filters"][@default=""])' /rs_camera.launch
    assert_success
    assert_output "1"
    run xmllint --xpath 'string(/launch/include[@file="/rs_camera_config.launch"]/arg[@name="filter_config_file"]/@value)' /rs_camera.launch
    assert_success
    assert_output '$(arg filter_config_file)'
    run xmllint --xpath 'string(/launch/include[@file="/rs_camera_config.launch"]/arg[@name="filters"]/@value)' /rs_camera.launch
    assert_success
    assert_output '$(arg filters)'
}

@test "remap template declares and forwards the filter profile args (#146)" {
    # The template is what every deployment override is copied from, and the
    # README now makes forwarding these two a hard requirement for an override.
    # A template that forgot them would propagate the exact silent failure
    # (camera up, no post-processing, no warning) into every new deployment.
    assert_file_exists "/rs_camera_remap.example.launch"
    run xmllint --xpath 'count(/launch/arg[@name="filter_config_file"][@default=""])' /rs_camera_remap.example.launch
    assert_success
    assert_output "1"
    run xmllint --xpath 'count(/launch/arg[@name="filters"][@default=""])' /rs_camera_remap.example.launch
    assert_success
    assert_output "1"
    run xmllint --xpath 'string(/launch/include[@file="/rs_camera_config.launch"]/arg[@name="filter_config_file"]/@value)' /rs_camera_remap.example.launch
    assert_success
    assert_output '$(arg filter_config_file)'
    run xmllint --xpath 'string(/launch/include[@file="/rs_camera_config.launch"]/arg[@name="filters"]/@value)' /rs_camera_remap.example.launch
    assert_success
    assert_output '$(arg filters)'
}

@test "Dockerfile declares FILTER_CONFIG and COPYs it to /filter_config.yaml (#146)" {
    assert_file_exists "${DOCKERFILE}"
    run grep -F 'ARG FILTER_CONFIG="filters.yaml"' "${DOCKERFILE}"
    assert_success
    run grep -F 'COPY --chmod=0644 "${FILTER_CONFIG}" /filter_config.yaml' "${DOCKERFILE}"
    assert_success
}
