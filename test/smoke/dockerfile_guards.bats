#!/usr/bin/env bats
#
# Static Dockerfile guards (modeled on the sibling app/realsense_ros2).
#
# These invariants have no runtime surface a behavioural smoke could exercise
# (they are latent under the default build params, or they live in ephemeral
# build-stage RUN lines), so they are pinned against the Dockerfile source
# instead. The whole Dockerfile is copied to /lint/Dockerfile in the devel-test
# stage (for hadolint), so it is available to grep here.

setup() {
    load "${BATS_TEST_DIRNAME}/test_helper"
    DOCKERFILE="/lint/Dockerfile"
}

@test "groupadd new-group branch names the group after \${GROUP}, not \${USER} (#71)" {
    # sys stage -- the else branch must create the group named after USER_GROUP.
    # Using \${USER} silently works only while USER == GROUP and becomes a real
    # bug the moment they differ.
    assert_file_exists "${DOCKERFILE}"
    run grep -E 'groupadd -g "\$\{GID\}"' "${DOCKERFILE}"
    assert_success
    assert_output --partial 'groupadd -g "${GID}" "${GROUP}"'
    refute_output --partial 'groupadd -g "${GID}" "${USER}"'
}

@test "version ARGs are pinned, not floating (#88)" {
    # The source build (#88) must pin concrete upstream tags: reproducible, no
    # auto-shipping upstream regressions. librealsense is TERMINAL at v2.55.1
    # (2.56+ pulls ROS 2 DDS artifacts) and the ros1-legacy wrapper at the 2.3.2
    # release tag (a bare branch tip moves; a tag does not).
    assert_file_exists "${DOCKERFILE}"
    run grep -F 'ARG LIBREALSENSE_VERSION="v2.55.1"' "${DOCKERFILE}"
    assert_success
    run grep -F 'ARG REALSENSE_ROS_VERSION="2.3.2"' "${DOCKERFILE}"
    assert_success
}

@test "no stage apt-installs the RealSense packages (#88 source build)" {
    # #88 migrates realsense2-camera / -description from apt (pinned to the EOL
    # librealsense 2.50.0, cannot stream a D455 on a Pi 5) to a pinned source
    # build. The apt install lines must be gone from every stage or the image
    # would carry a duplicate/stale SDK on top of the source build.
    assert_file_exists "${DOCKERFILE}"
    run grep -E 'ros-\$\{ROS_DISTRO\}-realsense2-(camera|description)' "${DOCKERFILE}"
    refute_output --partial 'ros-${ROS_DISTRO}-realsense2-camera'
    refute_output --partial 'ros-${ROS_DISTRO}-realsense2-description'
}

@test "runtime-test smoke asserts the wrapper is discoverable (#88)" {
    # #88: a missed catkin payload copy would leave the libs present but
    # `rospack find realsense2_camera` failing; the runtime smoke must catch it.
    assert_file_exists "${DOCKERFILE}"
    run grep -F 'rospack find realsense2_camera' "${DOCKERFILE}"
    assert_success
}

@test "runtime-test ldd scan covers both the ROS lib dir and /usr/local (#88)" {
    # The catkin nodelet lands under /opt/ros/\${ROS_DISTRO}/lib while the
    # ROS-agnostic SDK .so lives in /usr/local/lib; the runtime ldd smoke must
    # scan BOTH so a lib-path regression in either surfaces as "not found".
    assert_file_exists "${DOCKERFILE}"
    run grep -F 'find "/opt/ros/${ROS_DISTRO}/lib" "/usr/local/lib"' "${DOCKERFILE}"
    assert_success
}

@test "devel-test lints the pre-build hook (COPY into /lint scope, #88)" {
    # `COPY script/*.sh /lint/` is non-recursive, so script/hooks/pre/build.sh is
    # NOT shellchecked by it. A dedicated COPY brings the hook into the /lint/*.sh
    # glob the shellcheck invocation covers.
    assert_file_exists "${DOCKERFILE}"
    run grep -F 'COPY script/hooks/pre/build.sh /lint/hooks-pre-build.sh' "${DOCKERFILE}"
    assert_success
}

@test "pre-build hook no-ops when LIBREALSENSE_IMAGE is already set" {
    # Contract: when the caller/CI already provides the SDK image, the hook does
    # nothing and exits 0 (no local `docker build` of the SDK image).
    run env LIBREALSENSE_IMAGE=x bash /lint/hooks-pre-build.sh
    assert_success
}

@test "local librealsense SDK tag is version-scoped (Dockerfile default + hook agree)" {
    # A bare `librealsense:local` default lets ros1 (v2.55.1) and ros2 (v2.58.2)
    # clobber one shared local tag, so a later local build silently FROMs the
    # wrong-version SDK. The Dockerfile FROM default and the pre-build hook must
    # both derive the SAME `librealsense:<version>-<codename>` tag.
    assert_file_exists "${DOCKERFILE}"
    run grep -F 'ARG LIBREALSENSE_IMAGE="librealsense:${LIBREALSENSE_VERSION}-${UBUNTU_CODENAME}"' "${DOCKERFILE}"
    assert_success
    run grep -F -- '-t "librealsense:${librealsense_version}-${ubuntu_codename}"' /lint/hooks-pre-build.sh
    assert_success
}

@test "the bare librealsense:local tag is gone (a wrong version fails the build, not runs silently)" {
    # Regression: with a bare tag a wrong/mismatched version is silent (the tag
    # exists, holds the wrong SDK). Version-scoping makes a wrong/missing version a
    # nonexistent tag, so FROM ${LIBREALSENSE_IMAGE} fails loudly -- docker resolves
    # the missing tag to a docker.io pull that 404s and aborts the build.
    assert_file_exists "${DOCKERFILE}"
    run grep -F 'ARG LIBREALSENSE_IMAGE="librealsense:local"' "${DOCKERFILE}"
    assert_failure
    run grep -F -- '-t librealsense:local' /lint/hooks-pre-build.sh
    assert_failure
}
