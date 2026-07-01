#!/usr/bin/env bash
set -euo pipefail

# Is ROS_MASTER_URI pointing at a *remote* master? Remote = the URI is set and
# its host is not one of: empty, localhost, 127.*, ::1. A local/unset master
# means roslaunch starts its own roscore, so injecting --wait there would
# deadlock (it would wait forever for a master nothing else brings up).
_ros_master_is_remote() {
  local uri="${ROS_MASTER_URI:-}"
  [[ -n "${uri}" ]] || return 1

  local host="${uri#*://}"  # strip scheme (http://)
  host="${host%%/*}"        # strip any trailing path
  if [[ "${host}" == \[*\]* ]]; then
    host="${host#\[}"       # IPv6: [::1]:11311 -> ::1
    host="${host%%\]*}"
  else
    host="${host%%:*}"      # strip :port
  fi

  case "${host}" in
    "" | localhost | 127.* | ::1) return 1 ;;
    *) return 0 ;;
  esac
}

# Resolve the final argv into the RESOLVED_ARGV global array without executing.
# When the command is roslaunch and the master is remote, inject `--wait` so
# roslaunch blocks until the master is reachable, then launches -- fixing the
# multi-machine slave boot race (#79). Never double-inject if --wait is already
# present; leave every other command untouched.
_resolve_argv() {
  RESOLVED_ARGV=("$@")

  [[ "${1:-}" == "roslaunch" ]] || return 0
  _ros_master_is_remote || return 0

  local arg
  for arg in "$@"; do
    [[ "${arg}" == "--wait" ]] && return 0
  done

  RESOLVED_ARGV=("roslaunch" "--wait" "${@:2}")
}

# Only when executed as the entrypoint (not when a test sources this file):
# source ROS and exec the resolved command.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Source ROS 1. ROS's setup.bash chain dereferences unbound vars (ROS 1's
  # profile.d/10.roslaunch.sh reads $ROS_MASTER_URI), so bracket the source in
  # set +u / set -u to isolate it from this script's strict mode -- the
  # canonical pattern for sourcing third-party setup scripts (see
  # realsense_ros2 / ros1_bridge#81). Without this the entrypoint dies under
  # nounset (ROS_MASTER_URI: unbound variable) and the container exits
  # immediately on `just run` (CI never catches it: the build-time RUN smoke
  # bypasses ENTRYPOINT, so only an actual container start hits this path).
  set +u
  # shellcheck disable=SC1090,SC1091
  source "/opt/ros/${ROS_DISTRO}/setup.bash"
  set -u

  _resolve_argv "$@"
  exec "${RESOLVED_ARGV[@]}"
fi
