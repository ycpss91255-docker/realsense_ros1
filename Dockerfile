ARG ROS_DISTRO="noetic"
ARG ROS_TAG="ros-base"
ARG UBUNTU_CODENAME="focal"
# librealsense SDK pin. Declared before the first FROM so the `rs_sdk` stage's
# FROM tag can reference it (FROM-line ARGs must be global or pre-FROM). This
# repo is TERMINAL at v2.55.1 (the ceiling the ros1-legacy wrapper builds
# against -- 2.56+ pulls ROS 2 DDS artifacts, realsense-ros#3406), so the pin
# never moves. The prebuilt SDK image is produced by
# .github/workflows/build-librealsense.yaml and consumed below via `rs_sdk`.
ARG LIBREALSENSE_VERSION="v2.55.1"
# Pre-built lint + bats tools image (ShellCheck, Hadolint, Bats + the
# bats-support/assert/mock extensions). Resolves to `test-tools:local` for the
# local `just build` flow (build.sh auto-builds it from
# .base/dockerfile/Dockerfile.test-tools) or to the multi-arch
# ghcr.io/ycpss91255-docker/test-tools:vX.Y.Z in CI. The image is multi-arch,
# so `FROM ${TEST_TOOLS_IMAGE}` resolves the matching variant per build
# platform -- that is what lets the arm64 build (#65) ship arm64 lint/bats
# binaries with no per-repo arch-aware download logic. Consuming this image
# (instead of self-building the tools) is the template's canonical pattern
# (Dockerfile.example); see the sibling app/realsense_ros2 for the same setup.
ARG TEST_TOOLS_IMAGE="test-tools:local"
# Prebuilt librealsense SDK image. Resolves to `librealsense:local` for the
# local `just build` flow (the pre-build hook script/hooks/pre/build.sh
# auto-builds it from docker/librealsense/Dockerfile when LIBREALSENSE_IMAGE is
# unset) or to the multi-arch ghcr.io/ycpss91255-docker/librealsense:v2.55.1-focal
# in CI (injected via build_args, so the FROM below pulls the prebuilt image
# instead of recompiling librealsense). Same dual-source pattern as
# TEST_TOOLS_IMAGE above; see the sibling app/realsense_ros2 for the same setup.
ARG LIBREALSENSE_IMAGE="librealsense:local"

############################## rs_sdk ##############################
# Prebuilt librealsense SDK (issue #88 / option B). Compiled ONCE by
# .github/workflows/build-librealsense.yaml and published to GHCR, so CI no
# longer recompiles librealsense (~15-25 min) on every run -- it just pulls
# this image and COPYs the pre-built trees into the wrapper build below. The
# image carries two DESTDIR trees: /rs-full (full SDK: viewer + rs-* + gl) and
# /rs-stage (tools-pruned, for the runtime overlay). Multi-arch, so the tag
# resolves the matching variant per build platform.
# hadolint ignore=DL3006
FROM ${LIBREALSENSE_IMAGE} AS rs_sdk

############################## sys ##############################
FROM ros:${ROS_DISTRO}-${ROS_TAG}-${UBUNTU_CODENAME} AS sys

# base v0.41.0 build contract: compose / CI inject USER_NAME / USER_GROUP /
# USER_UID / USER_GID (not the legacy USER / GROUP / UID / GID). Declare the
# new names and alias the legacy ones from them so the rest of this stage's
# user-creation logic stays unchanged. Without this the injected build-args
# are dropped and the image is built as the default user, breaking `just run`
# (image HOME != compose's /home/${USER_NAME}/work mount).
ARG USER_NAME="user"
ARG USER_GROUP="user"
ARG USER_UID="1000"
ARG USER_GID="${USER_UID}"
ARG USER="${USER_NAME}"
ARG GROUP="${USER_GROUP}"
ARG UID="${USER_UID}"
ARG GID="${USER_GID}"
ARG SHELL="/bin/bash"
ARG HARDWARE="x86_64"
ENV HOME="/home/${USER}"

ENV NVIDIA_VISIBLE_DEVICES="all"
ENV NVIDIA_DRIVER_CAPABILITIES="all"

SHELL ["/bin/bash", "-x", "-euo", "pipefail", "-c"]

# Setup users and groups
RUN if getent group "${GID}" >/dev/null; then \
        existing_grp="$(getent group "${GID}" | cut -d: -f1)"; \
        if [ "${existing_grp}" != "${GROUP}" ]; then \
            groupmod -n "${GROUP}" "${existing_grp}"; \
        fi; \
    else \
        groupadd -g "${GID}" "${GROUP}"; \
    fi; \
    \
    if getent passwd "${UID}" >/dev/null; then \
        existing_user="$(getent passwd "${UID}" | cut -d: -f1)"; \
        if [ "${existing_user}" != "${USER}" ]; then \
            usermod -l "${USER}" "${existing_user}"; \
        fi; \
        usermod -g "${GID}" -s "${SHELL}" -d "${HOME}" -m "${USER}"; \
    elif id -u "${USER}" >/dev/null 2>&1; then \
        usermod -u "${UID}" -g "${GID}" -s "${SHELL}" -d "/home/${USER}" -m "${USER}"; \
    else \
        useradd -l -u "${UID}" -g "${GID}" -s "${SHELL}" -m "${USER}"; \
    fi; \
    \
    mkdir -p /etc/sudoers.d; \
    echo "${USER} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${USER}"; \
    chmod 0440 "/etc/sudoers.d/${USER}"

# Setup locale, timezone and replace apt urls (Taiwan mirror)
ENV TZ="Asia/Taipei"
ENV LC_ALL="en_US.UTF-8"
ENV LANG="en_US.UTF-8"
ENV LANGUAGE="en_US:en"

ARG APT_MIRROR_UBUNTU="tw.archive.ubuntu.com"
RUN sed -i "s@archive.ubuntu.com@${APT_MIRROR_UBUNTU}@g" /etc/apt/sources.list || true && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        tzdata \
        locales && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    locale-gen "${LANG}" && \
    update-locale LANG="${LANG}" && \
    ln -snf /usr/share/zoneinfo/"${TZ}" /etc/localtime && echo "${TZ}" > /etc/timezone

############################## devel-base ##############################
FROM sys AS devel-base

ARG ROS_DISTRO
ARG UBUNTU_CODENAME

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        sudo \
        psmisc \
        htop \
        # Shell
        tmux \
        terminator \
        # base tools
        ca-certificates \
        software-properties-common \
        wget \
        curl \
        git \
        vim \
        tree \
        # python3 tools
        python3-pip \
        python3-dev \
        python3-setuptools \
        # ROS 1 tools
        bash-completion \
        python3-catkin-tools \
        # ROS 1 desktop (devel only): rviz + rqt (incl. rqt_image_view, used by
        # the README RGB-D demo) + the Qt/OpenGL/X stack GUI tools need. The
        # runtime image stays on ros-base (this is in devel-base, not runtime).
        ros-${ROS_DISTRO}-desktop \
        # realsense2_camera build/run dep. The apt SDK path we removed used to
        # pull this in transitively; rosdep cannot resolve its key here (it is
        # the one wrapper dep not already in ros-desktop), so install it
        # explicitly and skip-key it in the rosdep calls below (#88).
        ros-${ROS_DISTRO}-ddynamic-reconfigure \
        # librealsense link + devel-tools runtime deps. librealsense itself is
        # NO LONGER compiled here -- it comes prebuilt from the `rs_sdk` image
        # (issue #88 / option B; see .github/workflows/build-librealsense.yaml).
        # These stay because the catkin wrapper built below links realsense2_camera
        # against the copied librealsense2.so (needs cmake / build-essential /
        # pkg-config + the libusb/libssl/libudev the SDK links) AND devel keeps the
        # full SDK viewer + librealsense2-gl.so, whose GTK/GLFW/GL runtime libs the
        # -dev packages pull in. The apt ros-noetic-realsense2-* packages -- pinned
        # to the EOL librealsense 2.50.0, which cannot stream a D455 on a Pi 5
        # (-71 / uvc watchdog) -- remain deliberately NOT installed. git / wget /
        # curl are already above; do not duplicate them.
        cmake \
        build-essential \
        pkg-config \
        libssl-dev \
        libusb-1.0-0-dev \
        libudev-dev \
        libgtk-3-dev \
        libglfw3-dev \
        libgl1-mesa-dev \
        libglu1-mesa-dev \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# --- RealSense SDK (prebuilt) + ROS 1 wrapper (built here) --- (issue #88)
# librealsense is now consumed as a PREBUILT GHCR image (the `rs_sdk` stage at
# the top), not compiled here -- CI no longer pays the ~15-25 min librealsense
# compile per run, only the ~5 min catkin wrapper build. The build itself lives
# in .github/workflows/build-librealsense.yaml (built once; this repo is
# terminal at v2.55.1). The apt path had pinned librealsense 2.50.0 (Noetic
# EOL), which cannot stream a D455 on a Pi 5; v2.55.1 streams it at ~30 fps and
# is the CEILING the ros1-legacy wrapper builds against (2.56+ pulls ROS 2 DDS
# artifacts -- realsense-ros#3406). The wrapper is pinned to the 2.3.2 release
# TAG (last ROS 1 release; a bare branch tip moves, a tag does not). This repo
# is TERMINAL at this pair (ROS 1 / Noetic / ros1-legacy are all EOL): the pins
# are --build-arg overridable but there is nothing newer to chase.
ARG REALSENSE_ROS_VERSION="2.3.2"

# COPY the prebuilt SDK trees in BEFORE the wrapper build. librealsense is
# ROS-agnostic, so the full SDK (viewer + rs-* + gl) installs into /usr/local
# (ldconfig below + catkin find_package(realsense2) resolve it from there); the
# tools-pruned copy stages at /opt/rs-stage/usr/local for the runtime COPY. The
# catkin wrapper itself still builds into /opt/ros/${ROS_DISTRO} below. The SDK
# was built with FORCE_RSUSB_BACKEND=true (userspace, no kernel module -- the
# whole point for the Pi) and no Python bindings (see the rs_sdk Dockerfile).
COPY --from=rs_sdk /rs-full/usr/local /usr/local
COPY --from=rs_sdk /rs-stage/usr/local /opt/rs-stage/usr/local

# ldconfig registers the copied librealsense .so, then the ros1-legacy wrapper
# is built with catkin against the SDK (sourcing setup.bash puts the ROS prefix
# on CMAKE_PREFIX_PATH). `catkin_make install` installs into the workspace
# install space (/tmp/rs_ws/install); we then copy ONLY the package payload
# (lib/ + each package's share/ dir) into the ROS prefix (real, devel) and into
# /opt/rs-stage (runtime), deliberately NOT catkin's generated top-level
# setup.bash / _setup_util.py / env.sh, which would clobber the base image's
# /opt/ros/noetic/setup.bash. (catkin has no per-package standalone
# `cmake --install` -- that is a colcon/ament pattern.) rosdep
# --skip-keys=librealsense2 must NOT apt-install the SDK we already COPYed in.
# hadolint ignore=DL3003
RUN ldconfig && \
    mkdir -p /tmp/rs_ws/src && \
    git clone --depth 1 --branch "${REALSENSE_ROS_VERSION}" \
        https://github.com/IntelRealSense/realsense-ros.git \
        /tmp/rs_ws/src/realsense-ros && \
    set +u && . "/opt/ros/${ROS_DISTRO}/setup.bash" && set -u && \
    rosdep update && \
    rosdep install --from-paths /tmp/rs_ws/src --ignore-src \
        --rosdistro "${ROS_DISTRO}" \
        --skip-keys="librealsense2 ddynamic_reconfigure" -y && \
    cd /tmp/rs_ws && \
    catkin_make install -DCMAKE_BUILD_TYPE=Release && \
    for tree in "/opt/ros/${ROS_DISTRO}" "/opt/rs-stage/opt/ros/${ROS_DISTRO}"; do \
        mkdir -p "${tree}/lib" "${tree}/share" && \
        cp -a /tmp/rs_ws/install/lib/. "${tree}/lib/" && \
        cp -a /tmp/rs_ws/install/share/realsense2_camera "${tree}/share/" && \
        cp -a /tmp/rs_ws/install/share/realsense2_description "${tree}/share/"; \
    done && \
    rm -rf /tmp/rs_ws

############################## devel ##############################
FROM devel-base AS devel

ARG USER_NAME="user"
ARG USER_GROUP="user"
ARG USER="${USER_NAME}"
ARG GROUP="${USER_GROUP}"
ARG ENTRYPOINT_FILE="script/entrypoint.sh"
ARG CONFIG_DIR="/tmp/config"
ARG SETUP_DIR="/tmp/setup"
ARG CONFIG_SRC="config"

COPY --chmod=0755 "./${ENTRYPOINT_FILE}" "/entrypoint.sh"
COPY --chown="${USER}":"${GROUP}" --chmod=0755 .base/config "${CONFIG_DIR}"
COPY --chown="${USER}":"${GROUP}" --chmod=0755 "${CONFIG_SRC}" "${CONFIG_DIR}"

# Copy RealSense udev rules
RUN mkdir -p /etc/udev/rules.d
COPY --chmod=0644 config/realsense/99-realsense-libusb.rules /etc/udev/rules.d/

USER "${USER}"


# Setup shell, terminator, tmux
RUN cat "${CONFIG_DIR}"/shell/bashrc >> "${HOME}/.bashrc" && \
    chown "${USER}":"${GROUP}" "${HOME}/.bashrc" && \
    mkdir -p "${HOME}/.bashrc.d" && \
    cp -n "${CONFIG_DIR}"/shell/bashrc.d/*.sh "${HOME}/.bashrc.d/" 2>/dev/null || true && \
    chown -R "${USER}":"${GROUP}" "${HOME}/.bashrc.d" && \
    "${CONFIG_DIR}"/shell/terminator/setup.sh && \
    "${CONFIG_DIR}"/shell/tmux/setup.sh && \
    sudo rm -rf "${CONFIG_DIR}" "${SETUP_DIR}"

WORKDIR "${HOME}/work"

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]

############################## devel-test (ephemeral) ##############################
# Resolves to test-tools:local (local just build) or
# ghcr.io/ycpss91255-docker/test-tools:vX.Y.Z (CI); see TEST_TOOLS_IMAGE at top.
# hadolint ignore=DL3006
FROM ${TEST_TOOLS_IMAGE} AS test-tools-stage

FROM devel AS devel-test

USER root

# Install lint tools (from the pre-built multi-arch test-tools image)
COPY --from=test-tools-stage /usr/local/bin/shellcheck /usr/local/bin/shellcheck
COPY --from=test-tools-stage /usr/local/bin/hadolint /usr/local/bin/hadolint

# Lint: ShellCheck (.sh) + Hadolint (Dockerfile)
COPY .hadolint.yaml /lint/.hadolint.yaml
COPY Dockerfile /lint/Dockerfile
# base v0.41.0 moved the wrapper scripts under .base/script/docker/wrapper/,
# so the old `COPY .base/script/docker/*.sh` glob matched nothing and broke
# this stage. The repo's own script/*.sh are symlinks to those wrappers, so
# `COPY script/*.sh /lint/` already dereferences and lints them.
COPY script/*.sh /lint/
COPY .base/script/docker/lib /lint/lib
RUN shellcheck -S warning /lint/*.sh /lint/lib/*.sh
WORKDIR /lint
RUN hadolint Dockerfile

# Install bats (the bats-support/assert/mock extensions are already merged
# into /usr/lib/bats inside the test-tools image)
COPY --from=test-tools-stage /opt/bats /opt/bats
COPY --from=test-tools-stage /usr/lib/bats /usr/lib/bats
RUN ln -sf /opt/bats/bin/bats /usr/local/bin/bats

ENV BATS_LIB_PATH="/usr/lib/bats"

# Smoke test
COPY .base/test/smoke/ /smoke_test/
COPY test/smoke/ /smoke_test/

ARG USER_NAME="user"
ARG USER="${USER_NAME}"
# Surface the configured user so the smoke test can assert the image was
# actually built as it (regression guard for the USER_NAME build contract).
# Ephemeral devel-test stage only -- not shipped in devel/runtime.
ENV CONTAINER_EXPECTED_USER="${USER_NAME}"
USER "${USER}"

RUN bats /smoke_test/

############################## runtime-base ##############################
FROM sys AS runtime-base

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        sudo \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

############################## runtime ##############################
FROM runtime-base AS runtime

ARG ROS_DISTRO
ARG USER_NAME="user"
ARG USER="${USER_NAME}"

# Runtime deps. libusb-1.0-0: the RSUSB userspace backend links libusb-1.0.so.0.
# The realsense2_camera / realsense2_description RUNTIME (exec) ROS deps that are
# NOT already in the ros-base image are installed EXPLICITLY here. They were
# derived by rosdep from the wrapper package.xml (`rosdep install
# --dependency-types=exec --simulate` against ros-base), then hardcoded because
# at build time `rosdep update` SKIPS the EOL noetic distro ("Skip end-of-life
# distro noetic"), so a build-time `rosdep install` cannot resolve these keys.
# rosdep key -> apt package:
#   image_transport      -> ros-noetic-image-transport
#   cv_bridge            -> ros-noetic-cv-bridge
#   tf                   -> ros-noetic-tf
#   ddynamic_reconfigure -> ros-noetic-ddynamic-reconfigure
#   diagnostic_updater   -> ros-noetic-diagnostic-updater
#   xacro                -> ros-noetic-xacro
#   eigen                -> libeigen3-dev
# All other package.xml deps (roscpp, sensor_msgs, nodelet, std_srvs, tf2, ...)
# are already in ros-base; librealsense2 is our self-built SDK (COPYed below).
#
# Also append a ROS source to /etc/bash.bashrc so interactive `docker exec`
# shells get `roslaunch` on PATH: the entrypoint sources ROS for PID 1 only and
# `docker exec` bypasses it. /etc/bash.bashrc is read by interactive shells only
# (leading non-interactive guard short-circuits otherwise). Folded into this RUN
# to avoid a consecutive-RUN lint (DL3059).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libusb-1.0-0 \
        ros-${ROS_DISTRO}-image-transport \
        ros-${ROS_DISTRO}-cv-bridge \
        ros-${ROS_DISTRO}-tf \
        ros-${ROS_DISTRO}-ddynamic-reconfigure \
        ros-${ROS_DISTRO}-diagnostic-updater \
        ros-${ROS_DISTRO}-xacro \
        libeigen3-dev \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    printf 'source /opt/ros/%s/setup.bash\n' "${ROS_DISTRO}" >> /etc/bash.bashrc

# Self-built RealSense SDK + ros1-legacy wrapper (built in devel, issue #88).
# The staged /opt/rs-stage tree carries BOTH subtrees: the librealsense SDK libs
# under usr/local (ROS-agnostic) and the two wrapper packages (realsense2_camera,
# realsense2_description) + their package.xml under opt/ros/${ROS_DISTRO}.
# Copying it to / lands the SDK in /usr/local and the wrapper in
# /opt/ros/${ROS_DISTRO}/{lib,share} in one shot. Deliberately does NOT touch
# /opt/ros/${ROS_DISTRO}/setup.bash (the DESTDIR stage carries no catkin
# top-level setup.*), so the base ROS env is intact. The SDK bin tools (viewer /
# rs-*) were pruned from the stage -- runtime is node-only. libusb-1.0-0
# (installed above) is what the RSUSB userspace backend links (libusb-1.0.so.0).
COPY --from=devel /opt/rs-stage/ /

# ldconfig registers the SDK's librealsense2.so.* now living in /usr/local/lib
# (Ubuntu's /etc/ld.so.conf.d/libc.conf lists it) so the wrapper resolves it at
# runtime; folded with the udev-rules mkdir to avoid a consecutive-RUN lint.
RUN ldconfig && \
    mkdir -p /etc/udev/rules.d
COPY --chmod=0644 config/realsense/99-realsense-libusb.rules /etc/udev/rules.d/

COPY --chmod=0755 script/entrypoint.sh /entrypoint.sh

USER "${USER}"
WORKDIR "${HOME}/work"

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
# initial_reset:=true resets the camera at startup so a D455 cold-start on the
# RSUSB/arm64 backend does not wedge the first stream-open (RS2_USB_STATUS_IO,
# topics stuck at 0 Hz); see #93. Adds a few seconds; override the arg to skip.
CMD ["roslaunch", "realsense2_camera", "rs_aligned_depth.launch", "initial_reset:=true"]

############################## runtime-test (ephemeral) ##############################
# Install-check smoke for the runtime image (template v0.21.1+ #243).
#
# This repo overrides the default smoke (USER + bash) to verify that the
# realsense2_camera node's shared libraries all resolve in the runtime
# image -- the exact regression class that went undetected in
# ros1_bridge#123 (a missing transitive .so the devel-stage bats never
# exercised, because devel carries the full build deps). ldd every
# realsense2_camera shared object and fail on any "not found"; the non-empty
# guard prevents a vacuous pass if the layout ever changes.
#
# ROS 1 (catkin) installs the nodelet libs directly under
# /opt/ros/${ROS_DISTRO}/lib/ as librealsense2_camera.so -- there is NO
# per-package lib/<pkg>/ subdir (that is the ROS 2 / ament layout). The
# librealsense SDK .so now lives in /usr/local/lib (ROS-agnostic), so scan BOTH
# dirs for librealsense2*.so* -- this ldd-checks the wrapper nodelet AND the SDK
# library it links against.
#
# `bash -c` (not `sh -c`): the command sources ROS setup.bash and uses a
# bash for-loop. The inner bash runs without the outer SHELL's
# -euo pipefail, so `source` under nounset is safe (matches ros1_bridge).
FROM runtime AS runtime-test

ARG RUNTIME_SMOKE_CMD='whoami && bash --version && \
  source /opt/ros/${ROS_DISTRO}/setup.bash && \
  { rospack find realsense2_camera || \
    { echo "RUNTIME SMOKE FAIL: realsense2_camera not on ROS_PACKAGE_PATH"; exit 1; }; } && \
  libs="$(find "/opt/ros/${ROS_DISTRO}/lib" "/usr/local/lib" -maxdepth 1 -name "librealsense2*.so*")" && \
  test -n "${libs}" && \
  for f in ${libs}; do \
    echo "--- ldd: ${f} ---"; ldd "${f}" || true; \
    if ldd "${f}" 2>&1 | grep -q "not found"; then \
      echo "RUNTIME SMOKE FAIL: unresolved shared library in ${f}"; exit 1; \
    fi; \
  done && \
  echo "RUNTIME SMOKE OK: realsense2_camera shared libraries resolved"'
RUN bash -c "${RUNTIME_SMOKE_CMD}"
