ARG ROS_DISTRO="noetic"
ARG ROS_TAG="ros-base"
ARG UBUNTU_CODENAME="focal"

############################## test tool sources ##############################
FROM bats/bats:latest AS bats-src

FROM alpine:latest AS bats-extensions
RUN apk add --no-cache git && \
    git clone --depth 1 -b v0.3.0 \
        https://github.com/bats-core/bats-support /bats/bats-support && \
    git clone --depth 1 -b v2.1.0 \
        https://github.com/bats-core/bats-assert  /bats/bats-assert

FROM alpine:latest AS lint-tools
RUN apk add --no-cache curl xz && \
    curl -fsSL \
        https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz \
        | tar -xJ -C /tmp && \
    mv /tmp/shellcheck-v0.10.0/shellcheck /usr/local/bin/shellcheck && \
    curl -fsSL -o /usr/local/bin/hadolint \
        https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-x86_64 && \
    chmod +x /usr/local/bin/hadolint

############################## sys ##############################
FROM ros:${ROS_DISTRO}-${ROS_TAG}-${UBUNTU_CODENAME} AS sys

ARG USER="initial"
ARG GROUP="initial"
ARG UID="1000"
ARG GID="${UID}"
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
        groupadd -g "${GID}" "${USER}"; \
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
        useradd -u "${UID}" -g "${GID}" -s "${SHELL}" -m "${USER}"; \
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

############################## base ##############################
FROM sys AS base

ARG ROS_DISTRO

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
        # ROS tools
        bash-completion \
        python3-catkin-tools \
        # Application packages
        ros-${ROS_DISTRO}-realsense2-camera \
        ros-${ROS_DISTRO}-realsense2-description \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

############################## devel ##############################
FROM base AS devel

ARG USER
ARG GROUP
ARG ENTRYPOINT_FILE="script/entrypoint.sh"
ARG CONFIG_DIR="/tmp/config"
ARG CONFIG_SRC="template/config"

COPY --chmod=0755 "./${ENTRYPOINT_FILE}" "/entrypoint.sh"
COPY --chown="${USER}":"${GROUP}" --chmod=0755 "${CONFIG_SRC}" "${CONFIG_DIR}"

# Copy RealSense udev rules
RUN mkdir -p /etc/udev/rules.d
COPY --chmod=0644 config/realsense/99-realsense-libusb.rules /etc/udev/rules.d/

USER "${USER}"

# Setup pip packages
RUN "${CONFIG_DIR}"/pip/setup.sh

# Setup shell, terminator, tmux
RUN cat "${CONFIG_DIR}"/shell/bashrc >> "${HOME}/.bashrc" && \
    chown "${USER}":"${GROUP}" "${HOME}/.bashrc" && \
    "${CONFIG_DIR}"/shell/terminator/setup.sh && \
    "${CONFIG_DIR}"/shell/tmux/setup.sh && \
    sudo rm -rf "${CONFIG_DIR}"

WORKDIR "${HOME}/work"

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]

############################## test (ephemeral) ##############################
FROM devel AS test

USER root

# Install lint tools
COPY --from=lint-tools /usr/local/bin/shellcheck /usr/local/bin/shellcheck
COPY --from=lint-tools /usr/local/bin/hadolint /usr/local/bin/hadolint

# Lint: ShellCheck (.sh) + Hadolint (Dockerfile)
COPY .hadolint.yaml /lint/.hadolint.yaml
COPY Dockerfile /lint/Dockerfile
COPY *.sh /lint/
COPY template/script/docker/*.sh /lint/
RUN shellcheck -S warning /lint/*.sh
RUN cd /lint && hadolint Dockerfile

# Install bats
COPY --from=bats-src /opt/bats /opt/bats
COPY --from=bats-src /usr/lib/bats /usr/lib/bats
COPY --from=bats-extensions /bats /usr/lib/bats
RUN ln -sf /opt/bats/bin/bats /usr/local/bin/bats

ENV BATS_LIB_PATH="/usr/lib/bats"

# Smoke test
COPY template/test/smoke/ /smoke_test/
COPY test/smoke/ /smoke_test/

ARG USER
USER "${USER}"

RUN bats /smoke_test/

############################## runtime-base ##############################
FROM sys AS runtime-base

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        sudo \
        tini \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

############################## runtime ##############################
FROM runtime-base AS runtime

ARG ROS_DISTRO
ARG USER

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ros-${ROS_DISTRO}-realsense2-camera \
        ros-${ROS_DISTRO}-realsense2-description \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy RealSense udev rules
RUN mkdir -p /etc/udev/rules.d
COPY --chmod=0644 config/realsense/99-realsense-libusb.rules /etc/udev/rules.d/

COPY --chmod=0755 script/entrypoint.sh /entrypoint.sh

USER "${USER}"
WORKDIR "${HOME}/work"

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
CMD ["roslaunch", "realsense2_camera", "rs_camera.launch"]
