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

# ------------------------------ supervision (#81) ------------------------------
#
# The #79/#80 gate fixes only the *boot* race. This adds the *post-launch* case:
# when a remote master restarts after the slave launched, neither roslaunch nor
# the node exits -- they stay alive but deregistered on the new master
# (`rostopic list` shows the names, `rosnode list` lacks our node), so
# `restart: unless-stopped` never fires. When the master is remote we instead
# run a supervisor loop: (re)launch `roslaunch --wait` as a child, poll node
# registration on the *current* master, and after N consecutive failures kill
# roslaunch cleanly and relaunch (the fresh `--wait` re-waits + re-registers).

# Config env vars (all overridable via .env), with defaults:
#   ROS_MASTER_SUPERVISE     on by default; "0" disables (fall back to the gate)
#   ROS_MASTER_CHECK_INTERVAL  seconds between registration checks (15)
#   ROS_MASTER_CHECK_TIMEOUT   per-query `rosnode list` timeout, seconds (5)
#   ROS_MASTER_CHECK_FAILURES  consecutive failures before a restart (3)
#   ROS_SUPERVISE_NODE         node whose registration is the health signal
#                              (/camera/realsense2_camera)

# Should the supervisor loop engage? Only when the command is roslaunch AND the
# master is remote AND supervision is not disabled. Any other combination falls
# back to the plain gate (_resolve_argv + exec), keeping single-machine and
# non-roslaunch paths unchanged.
_supervision_enabled() {
  [[ "${1:-}" == "roslaunch" ]] || return 1
  _ros_master_is_remote || return 1
  [[ "${ROS_MASTER_SUPERVISE:-1}" != "0" ]] || return 1
  return 0
}

# Pure health decision: is the supervised node present in the given `rosnode
# list` output text? One node per line, so match a whole line exactly.
_node_registered() {
  local node="$1"
  local list_text="$2"
  grep -qxF -- "${node}" <<< "${list_text}"
}

# PID of the current roslaunch child, shared with the signal-forwarding trap.
_SUPERVISE_CHILD_PID=""

# On SIGTERM/SIGINT, forward the signal to the roslaunch child, reap it, then
# exit 0 so `just stop` is clean and fast (no 10s SIGKILL fallback).
_supervise_forward_signal() {
  if [[ -n "${_SUPERVISE_CHILD_PID}" ]] \
      && kill -0 "${_SUPERVISE_CHILD_PID}" 2>/dev/null; then
    kill -INT "${_SUPERVISE_CHILD_PID}" 2>/dev/null || true
    wait "${_SUPERVISE_CHILD_PID}" 2>/dev/null || true
  fi
  exit 0
}

# The supervisor loop. Takes the full original argv ("roslaunch" "$@"); relaunch
# uses "${@:2}" (the roslaunch args) under a fresh `--wait`. Only reached from
# the real entrypoint invocation, never from a sourcing test.
#
# Interim reaping: we `wait` on our direct roslaunch child only. Grandchildren
# orphaned by a hard kill are not reaped without a PID 1 init; that is a
# base / compose-generation concern (compose.yaml is base-generated) deferred to
# base#792 -- do not add an app-level init here.
_supervise_loop() {
  local interval="${ROS_MASTER_CHECK_INTERVAL:-15}"
  local query_timeout="${ROS_MASTER_CHECK_TIMEOUT:-5}"
  local max_failures="${ROS_MASTER_CHECK_FAILURES:-3}"
  local node="${ROS_SUPERVISE_NODE:-/camera/realsense2_camera}"

  trap _supervise_forward_signal TERM INT

  while true; do
    roslaunch --wait "${@:2}" &
    _SUPERVISE_CHILD_PID="$!"

    local failures=0
    while true; do
      # Sleep as a backgrounded child + `wait` so a signal arriving mid-sleep
      # runs the trap promptly (a foreground `sleep` would block the trap until
      # it returns, delaying shutdown).
      sleep "${interval}" &
      wait "$!" 2>/dev/null || true

      # roslaunch exited on its own -> reap and relaunch.
      if ! kill -0 "${_SUPERVISE_CHILD_PID}" 2>/dev/null; then
        wait "${_SUPERVISE_CHILD_PID}" 2>/dev/null || true
        break
      fi

      local list_text
      if list_text="$(timeout "${query_timeout}" rosnode list 2>/dev/null)" \
          && _node_registered "${node}" "${list_text}"; then
        failures=0
      else
        failures=$((failures + 1))
      fi

      if (( failures >= max_failures )); then
        kill -INT "${_SUPERVISE_CHILD_PID}" 2>/dev/null || true
        wait "${_SUPERVISE_CHILD_PID}" 2>/dev/null || true
        break
      fi
    done
  done
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

  # When supervision engages (remote master + roslaunch + not disabled), run the
  # self-healing loop instead of a one-shot exec. Every other path keeps the
  # exact gate behavior.
  if _supervision_enabled "$@"; then
    _supervise_loop "$@"
  else
    _resolve_argv "$@"
    exec "${RESOLVED_ARGV[@]}"
  fi
fi
