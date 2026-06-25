#!/usr/bin/env bash
set -euo pipefail

# Source ROS 1. ROS's setup.bash chain dereferences unbound vars (ROS 1's
# profile.d/10.roslaunch.sh reads $ROS_MASTER_URI), so bracket the source in
# set +u / set -u to isolate it from this script's strict mode -- the canonical
# pattern for sourcing third-party setup scripts (see realsense_ros2 /
# ros1_bridge#81). Without this the entrypoint dies under nounset
# (ROS_MASTER_URI: unbound variable) and the container exits immediately on
# `just run` (CI never catches it: the build-time RUN smoke bypasses ENTRYPOINT,
# so only an actual container start hits this path).
set +u
# shellcheck disable=SC1090,SC1091
source "/opt/ros/${ROS_DISTRO}/setup.bash"
set -u

exec "${@}"
