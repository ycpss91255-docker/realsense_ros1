# Prebuilt librealsense SDK source image (issue #88 / option B).
#
# ROS 1 (Noetic / ros1-legacy) is TERMINAL at librealsense v2.55.1 -- v2.56+
# pulls ROS 2 DDS artifacts the ros1-legacy wrapper cannot build against
# (realsense-ros#3406). So the SDK is compiled ONCE here and published to
# ghcr.io/ycpss91255-docker/librealsense:${LIBREALSENSE_VERSION}-${UBUNTU_CODENAME};
# the main repo Dockerfile then FROMs this image and COPYs the pre-built trees
# instead of recompiling librealsense (~15-25 min) on every CI run. The catkin
# wrapper (which must compile against the SDK) still builds in the main image.
#
# librealsense2 is a pure C++ SDK -- it does NOT depend on ROS. Its only real
# axis is the Ubuntu platform: the compiled .so is ABI-bound to that release's
# glibc/libstdc++. So the image is keyed on UBUNTU_CODENAME (focal, for Noetic)
# and installs into the ROS-agnostic /usr/local prefix, and its tag is
# ${LIBREALSENSE_VERSION}-focal rather than noetic-${LIBREALSENSE_VERSION}.
#
# This image is a BUILD-TIME SOURCE only (never shipped), so its size is
# irrelevant: it carries two DESTDIR trees the consumer COPYs librealsense
# files out of, WITHOUT dragging in the base ROS install.
#   /rs-full  -- full install: viewer + rs-* examples + librealsense2-gl
#   /rs-stage -- tools-pruned copy for the runtime overlay (viewer / rs-* / gl
#                removed), matching exactly what the old inline build staged.
#
# The cmake flag set and prune list are IDENTICAL to the source build that
# previously lived in the main Dockerfile's devel-base stage; keep them in sync
# if the pins ever move (they should not -- this repo is terminal).
ARG UBUNTU_CODENAME=focal
ARG LIBREALSENSE_VERSION=v2.55.1

FROM ubuntu:${UBUNTU_CODENAME} AS build

ARG LIBREALSENSE_VERSION

SHELL ["/bin/bash", "-x", "-euo", "pipefail", "-c"]

# librealsense source-build deps (Intel's official Ubuntu list). Two things the
# leaner ubuntu:${UBUNTU_CODENAME} base needs that the old ros-base handled for
# us: ca-certificates (explicit -- ros-base pulled it in transitively; without
# it the https git clone below fails TLS), and DEBIAN_FRONTEND=noninteractive on
# the install (the GTK/GL deps pull in tzdata, whose postinst prompts for a
# timezone on this TTY-less build otherwise, wedging it indefinitely).
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        wget \
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

# Clone + compile librealsense at the pinned tag, install into the ROS-agnostic
# /usr/local prefix (the consumer's find_package(realsense2) resolves it from
# /usr/local -- a CMake default prefix -- and ldconfig registers /usr/local/lib
# via Ubuntu's /etc/ld.so.conf.d/libc.conf). FORCE_RSUSB_BACKEND=true =
# userspace backend (no kernel module -- required for the Pi). Python bindings
# stay OFF (pybind11 cannot inherit PYTHON_EXECUTABLE here). Two DESTDIR trees
# are produced: /rs-full (full) and /rs-stage (tools-pruned), so the consumer
# can COPY only librealsense files and never the base Ubuntu install.
RUN git clone --depth 1 --branch "${LIBREALSENSE_VERSION}" \
        https://github.com/IntelRealSense/librealsense.git /tmp/librealsense && \
    cmake -S /tmp/librealsense -B /tmp/librealsense/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="/usr/local" \
        -DFORCE_RSUSB_BACKEND=true \
        -DBUILD_WITH_DDS=OFF \
        -DCHECK_FOR_UPDATES=OFF \
        -DBUILD_PYTHON_BINDINGS=false \
        -DBUILD_WITH_CUDA=false \
        -DBUILD_EXAMPLES=true \
        -DBUILD_GRAPHICAL_EXAMPLES=true && \
    cmake --build /tmp/librealsense/build -j"$(nproc)" && \
    DESTDIR=/rs-full cmake --install /tmp/librealsense/build && \
    cp -a /rs-full /rs-stage && \
    rm -f /rs-stage/usr/local/bin/realsense-viewer && \
    rm -f /rs-stage/usr/local/bin/rs-* && \
    rm -f /rs-stage/usr/local/lib/librealsense2-gl.so* && \
    rm -rf /tmp/librealsense

############################## test (publish gate) ##############################
# Publish-time smoke gate. A librealsense SDK image that fails these asserts
# must never be pushed, so this stage IS the correctness contract of the two
# DESTDIR trees the consumer COPYs. The publish workflow builds `--target test`
# (push=false) BEFORE it pushes the `export` image; see
# .github/workflows/build-librealsense.yaml. Written PIPE-FREE (bash `case` on a
# captured ldd string + `find -print -quit` guards, no `| grep`): the inherited
# SHELL/pipefail is NOT tracked across this FROM boundary, so a pipe would trip
# hadolint DL4006.
FROM build AS test

# `set -eux`: any failed assert aborts the build (non-zero RUN) -> the gate
# blocks the push. Each check maps to a property the consumer relies on.
RUN set -eux; \
    lib_full="/rs-full/usr/local/lib"; \
    lib_stage="/rs-stage/usr/local/lib"; \
    bin_stage="/rs-stage/usr/local/bin"; \
    # (1) Both DESTDIR trees exist with a populated lib dir under the ROS prefix.
    test -d "${lib_full}"; \
    test -d "${lib_stage}"; \
    # (2) The core SDK shared object is present in the full tree ...
    test -f "${lib_full}/librealsense2.so"; \
    # ... and every one of its shared-library deps resolves (no "not found").
    ldd_out="$(ldd "${lib_full}/librealsense2.so" 2>&1)"; \
    echo "${ldd_out}"; \
    case "${ldd_out}" in \
        *"not found"*) \
            echo "SDK TEST FAIL: unresolved shared library in librealsense2.so" >&2; \
            exit 1 ;; \
    esac; \
    # (3) The versioned soname (librealsense2.so.<major.minor>) is present.
    soname="$(find "${lib_full}" -maxdepth 1 -name 'librealsense2.so.*' -print -quit)"; \
    test -n "${soname}"; \
    # (4) /rs-stage is the runtime-pruned tree: NO GUI viewer, NO rs-* example
    # binaries, NO GL helper library (all only belong in the devel overlay).
    test ! -e "${bin_stage}/realsense-viewer"; \
    leaked_rs="$(find "${bin_stage}" -maxdepth 1 -name 'rs-*' -print -quit 2>/dev/null || true)"; \
    if [ -n "${leaked_rs}" ]; then \
        echo "SDK TEST FAIL: rs-* example tools leaked into /rs-stage" >&2; \
        exit 1; \
    fi; \
    leaked_gl="$(find "${lib_stage}" -maxdepth 1 -name 'librealsense2-gl.so*' -print -quit 2>/dev/null || true)"; \
    if [ -n "${leaked_gl}" ]; then \
        echo "SDK TEST FAIL: librealsense2-gl leaked into /rs-stage" >&2; \
        exit 1; \
    fi; \
    echo "SDK TEST OK: /rs-full + /rs-stage trees validated"

############################## export (published image) ##############################
# The PUBLISHED image is literally just the two librealsense DESTDIR trees on
# `scratch`. The consumer only ever COPYs /rs-full and /rs-stage out of this
# image, so shipping the ros-base + build toolchain underneath was dead weight;
# this mirrors base's test-tools image being a clean COPY-source. Built with
# `--target export` on the build-and-push step of the publish workflow.
FROM scratch AS export

COPY --from=build /rs-full /rs-full
COPY --from=build /rs-stage /rs-stage
