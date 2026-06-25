# Source ROS 1 for interactive shells.
#
# The base bashrc is ROS-agnostic (base also serves non-ROS repos), so a ROS
# repo must source its own distro. Without this, `roslaunch`, `roscore`,
# `rosrun`, `realsense-viewer`, `rs-enumerate-devices` and the rest of
# /opt/ros/${ROS_DISTRO}/bin are NOT on PATH in interactive `just run` /
# `just exec` shells -- they come up as "command not found" even though the
# binaries are installed.
#
# Loaded from ~/.bashrc.d/ by the base bashrc, so this runs for interactive
# shells only. ROS 1's setup.bash chain dereferences unbound vars (ROS_MASTER_URI
# in profile.d/10.roslaunch.sh), so disable nounset around the source.
if [[ -n "${ROS_DISTRO:-}" && -f "/opt/ros/${ROS_DISTRO}/setup.bash" ]]; then
  set +u
  # shellcheck disable=SC1090
  source "/opt/ros/${ROS_DISTRO}/setup.bash"
fi
