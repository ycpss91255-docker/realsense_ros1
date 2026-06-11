#!/usr/bin/env bash
set -euo pipefail

# Source ROS 1
# shellcheck disable=SC1090,SC1091
source "/opt/ros/${ROS_DISTRO}/setup.bash"

exec "${@}"
