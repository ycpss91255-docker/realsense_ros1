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

# ------------------------------- watchdog (#81) -------------------------------
#
# The #79/#80 gate fixes only the *boot* race. This adds the *post-launch* case:
# when a remote master restarts after the slave launched, neither roslaunch nor
# the node exits -- they stay alive but deregistered on the new master
# (`rostopic list` shows the names, `rosnode list` lacks our node), so
# `restart: unless-stopped` never fires. When the watchdog is enabled and the
# master is remote we instead run a supervised-restart loop: (re)launch
# `roslaunch --wait` as a child, poll node registration on the *current* master,
# and restart roslaunch cleanly when the health signal says so (the fresh
# `--wait` re-waits + re-registers). The loop/timing knobs are a generic
# supervised-restart pattern (hence the generic WATCHDOG_* names); only the
# health-check target (WATCHDOG_ROSNODE) is ROS-specific.
#
# Two-phase child lifecycle (#136), keyed on a `registered_once` flag (have we
# EVER seen ourselves in `rosnode list` since this launch):
#
#   Phase 1 -- never registered (startup). The node may take a while to appear;
#              a slow master or a not-yet-up node is expected, not a fault. So
#              neither `unreachable` nor `deregistered` counts here -- ONLY a
#              WATCHDOG_STARTUP_DEADLINE backstop (elapsed seconds since launch)
#              can force a restart, catching a launch that never registers at
#              all (bad args, crash-looping node).
#
#   Phase 2 -- registered at least once. A single `unreachable` tick may be a
#              transient network blip, so it increments a WATCHDOG_FAILURES
#              counter and only restarts once the counter reaches the max
#              (debounce). A `deregistered` tick, by contrast, means the master
#              answered but our node is gone (master churn) -- that restarts on
#              the next tick with no debounce.
#
# The decision is factored into two pure, exhaustively-testable functions --
# `_watchdog_probe` (query -> state) and `_watchdog_decide` (state + counters ->
# action) -- so the loop is a thin shell owning only the mutable state.

# Config env vars (all overridable via .env), with defaults:
#   WATCHDOG_ENABLED           off by default; "1" enables (opt-in, consistent
#                              with base `[lifecycle] restart = no`). Anything
#                              but "1" = off.
#   WATCHDOG_INTERVAL          seconds between registration checks (15)
#   WATCHDOG_TIMEOUT           per-query `rosnode list` timeout, seconds (5)
#   WATCHDOG_FAILURES          consecutive `unreachable` ticks before a restart,
#                              PHASE 2 ONLY (3)
#   WATCHDOG_STARTUP_DEADLINE  phase-1 backstop: seconds since (re)launch after
#                              which a never-registered child is restarted (300)
#   WATCHDOG_ROSNODE           node whose registration is the health signal
#                              (/camera/realsense2_camera)

# Should the watchdog loop engage? Only when it is explicitly enabled AND the
# command is roslaunch AND the master is remote. Any other combination falls
# back to the plain gate (_resolve_argv + exec), keeping single-machine and
# non-roslaunch paths unchanged. Default off: enabled iff WATCHDOG_ENABLED is
# exactly "1" (unset / empty / anything-else = off).
_watchdog_enabled() {
  [[ "${WATCHDOG_ENABLED:-0}" == "1" ]] || return 1
  [[ "${1:-}" == "roslaunch" ]] || return 1
  _ros_master_is_remote || return 1
  return 0
}

# Pure health decision: is the supervised node present in the given `rosnode
# list` output text? One node per line, so match a whole line exactly.
_node_registered() {
  local node="$1"
  local list_text="$2"
  grep -qxF -- "${node}" <<< "${list_text}"
}

# Run the registration query and classify its result into exactly one state.
# Usage: _watchdog_probe <node> <query-cmd> [args...]
# Classification is by EXIT CODE, not by empty output:
#   query exits non-zero (timeout / master unreachable)  -> "unreachable"
#   query exits 0 AND the node is in the list            -> "healthy"
#   query exits 0 AND the node is NOT in the list        -> "deregistered"
# The empty-list case matters: a master restarted on the same port answers
# `rosnode list` successfully with an empty list -- that is `deregistered` (our
# node is gone), not `unreachable`. The query command is passed in (loop calls
# it with `timeout <t> rosnode list`) so tests can drive it with a fake rosnode.
_watchdog_probe() {
  local node="$1"
  shift

  local list_text=""
  local exit_code=0
  list_text="$("$@" 2>/dev/null)" || exit_code="$?"

  if (( exit_code != 0 )); then
    printf 'unreachable\n'
  elif _node_registered "${node}" "${list_text}"; then
    printf 'healthy\n'
  else
    printf 'deregistered\n'
  fi
}

# Pure decision: map the probed state + the loop's mutable counters onto one of
# three actions, echoed on stdout (no I/O, so it is exhaustively unit-testable):
#   HEALTHY  the node is registered -> loop sets registered_once=1, failures=0
#   RESTART  relaunch roslaunch cleanly
#   WAIT     keep waiting this tick (the loop owns the failure-counter bump)
# Usage:
#   _watchdog_decide <state> <registered_once> <failures> <elapsed> \
#     <max_failures> <startup_deadline>
# Truth table (registered_once=0 is phase 1, =1 is phase 2):
#   phase1 healthy                       -> HEALTHY (node first seen)
#   phase1 unreachable/deregistered      -> elapsed <  deadline: WAIT
#                                           elapsed >= deadline: RESTART
#   phase2 healthy                       -> HEALTHY (reset failures)
#   phase2 unreachable                   -> failures+1 <  max: WAIT
#                                           failures+1 >= max: RESTART
#   phase2 deregistered                  -> RESTART (no debounce)
_watchdog_decide() {
  local state="$1"
  local registered_once="$2"
  local failures="$3"
  local elapsed="$4"
  local max_failures="$5"
  local startup_deadline="$6"

  if [[ "${state}" == "healthy" ]]; then
    printf 'HEALTHY\n'
    return 0
  fi

  if (( registered_once == 0 )); then
    # Phase 1: never registered. Neither unreachable nor deregistered counts;
    # only the startup backstop can force a restart.
    if (( elapsed >= startup_deadline )); then
      printf 'RESTART\n'
    else
      printf 'WAIT\n'
    fi
    return 0
  fi

  # Phase 2: registered at least once.
  if [[ "${state}" == "deregistered" ]]; then
    # Master answered but our node is gone (master churn) -> restart next tick.
    printf 'RESTART\n'
    return 0
  fi

  # Phase 2 unreachable: debounce transient blips. This tick is the failures+1th
  # consecutive failure; restart once that reaches the configured max.
  if (( failures + 1 >= max_failures )); then
    printf 'RESTART\n'
  else
    printf 'WAIT\n'
  fi
}

# PID of the current roslaunch child, shared with the signal-forwarding trap.
_WATCHDOG_CHILD_PID=""

# On SIGTERM/SIGINT, forward the signal to the roslaunch child, reap it, then
# exit 0 so `just stop` is clean and fast (no 10s SIGKILL fallback).
#
# Use SIGTERM (not SIGINT) to stop the child: a command started asynchronously
# (`roslaunch ... &`) by a non-interactive shell has its SIGINT/SIGQUIT set to
# SIG_IGN (POSIX async-list behaviour), so sending it SIGINT is silently ignored
# and the following `wait` blocks forever. SIGTERM is not ignored, and roslaunch
# shuts its nodes down cleanly on SIGTERM.
_watchdog_forward_signal() {
  if [[ -n "${_WATCHDOG_CHILD_PID}" ]] \
      && kill -0 "${_WATCHDOG_CHILD_PID}" 2>/dev/null; then
    kill -TERM "${_WATCHDOG_CHILD_PID}" 2>/dev/null || true
    wait "${_WATCHDOG_CHILD_PID}" 2>/dev/null || true
  fi
  exit 0
}

# The watchdog loop. Takes the full original argv ("roslaunch" "$@"); relaunch
# uses "${@:2}" (the roslaunch args) under a fresh `--wait`. Only reached from
# the real entrypoint invocation, never from a sourcing test.
#
# Interim reaping: we `wait` on our direct roslaunch child only. Grandchildren
# orphaned by a hard kill are not reaped without a PID 1 init; that is a
# base / compose-generation concern (compose.yaml is base-generated) deferred to
# base#792 -- do not add an app-level init here.
_watchdog_loop() {
  local interval="${WATCHDOG_INTERVAL:-15}"
  local query_timeout="${WATCHDOG_TIMEOUT:-5}"
  local max_failures="${WATCHDOG_FAILURES:-3}"
  local startup_deadline="${WATCHDOG_STARTUP_DEADLINE:-300}"
  local node="${WATCHDOG_ROSNODE:-/camera/realsense2_camera}"

  trap _watchdog_forward_signal TERM INT

  while true; do
    roslaunch --wait "${@:2}" &
    _WATCHDOG_CHILD_PID="$!"

    # Per-launch state, owned here and reset on every (re)launch: have we ever
    # registered, the phase-2 blip counter, and seconds elapsed since launch.
    local registered_once=0
    local failures=0
    local elapsed=0
    while true; do
      # Sleep as a backgrounded child + `wait` so a signal arriving mid-sleep
      # runs the trap promptly (a foreground `sleep` would block the trap until
      # it returns, delaying shutdown).
      sleep "${interval}" &
      wait "$!" 2>/dev/null || true
      elapsed=$((elapsed + interval))

      # roslaunch exited on its own -> reap and relaunch.
      if ! kill -0 "${_WATCHDOG_CHILD_PID}" 2>/dev/null; then
        wait "${_WATCHDOG_CHILD_PID}" 2>/dev/null || true
        break
      fi

      local state
      state="$(_watchdog_probe "${node}" timeout "${query_timeout}" rosnode list)"

      local action
      action="$(_watchdog_decide "${state}" "${registered_once}" "${failures}" \
        "${elapsed}" "${max_failures}" "${startup_deadline}")"

      case "${action}" in
        HEALTHY)
          # Node is present -> we are in (or entering) phase 2; clear the blip
          # counter so a later transient does not carry stale failures.
          registered_once=1
          failures=0
          ;;
        RESTART)
          # SIGTERM, not SIGINT: the child was started async (`&`), so its SIGINT
          # is SIG_IGN (POSIX) and signalling it SIGINT would hang the next
          # `wait`. The fresh `--wait` re-waits + re-registers on relaunch.
          kill -TERM "${_WATCHDOG_CHILD_PID}" 2>/dev/null || true
          wait "${_WATCHDOG_CHILD_PID}" 2>/dev/null || true
          break
          ;;
        *)
          # WAIT: only a phase-2 `unreachable` tick advances the debounce
          # counter; phase-1 ticks lean on the startup deadline instead.
          if (( registered_once == 1 )) && [[ "${state}" == "unreachable" ]]; then
            failures=$((failures + 1))
          fi
          ;;
      esac
    done
  done
}

# ---------------------------- camera config (#105) ----------------------------
#
# Baked-in camera profile. The Dockerfile COPYs the repo-root `camera.yaml`
# symlink's TARGET into the image as /camera_config.yaml (default target
# config/realsense/yaml/none.yaml is EMPTY = "stream stock upstream
# defaults"). Activating a profile = repoint that symlink (or pass
# --build-arg CAMERA_CONFIG=config/realsense/yaml/usb2_640x480p15fps.yaml).
#
# ROS 1 realsense-ros (2.3.2) ships no config_file arg. The repo-owned wrapper
# launch /rs_camera_config.launch (baked in by the Dockerfile) INCLUDES the
# stock rs_aligned_depth.launch and adds one optional `config_file:=` arg that
# rosparam-loads the YAML into the node namespace AFTER the include (the later
# write wins, so it overrides the launch defaults). The runtime CMD already
# targets that wrapper, so applying a profile is just appending the arg.
CAMERA_CONFIG_FILE="/camera_config.yaml"

# Resolve the launch argv into CONFIGURED_ARGV. When the command is a roslaunch
# AND a NON-empty /camera_config.yaml is baked in, append `config_file:=` so the
# wrapper loads the profile. Any other case -- an empty config (the default), or
# a non-roslaunch command such as the devel `bash` -- leaves the argv untouched,
# so default behaviour is byte-identical to before.
_apply_camera_config() {
  CONFIGURED_ARGV=("$@")

  [[ "${1:-}" == "roslaunch" ]] || return 0
  [[ -s "${CAMERA_CONFIG_FILE}" ]] || return 0

  printf 'Applying camera profile from %s\n' "${CAMERA_CONFIG_FILE}"
  CONFIGURED_ARGV=("$@" "config_file:=${CAMERA_CONFIG_FILE}")
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

  # Apply the baked-in camera profile (if any) BEFORE the wait/watchdog gates,
  # so the rewritten roslaunch argv still flows through --wait injection and the
  # watchdog relaunch loop unchanged.
  _apply_camera_config "$@"
  set -- "${CONFIGURED_ARGV[@]}"

  # When the watchdog engages (enabled + remote master + roslaunch), run the
  # self-healing loop instead of a one-shot exec. Every other path -- including
  # the default (watchdog off) -- keeps the exact gate behavior.
  if _watchdog_enabled "$@"; then
    _watchdog_loop "$@"
  else
    _resolve_argv "$@"
    exec "${RESOLVED_ARGV[@]}"
  fi
fi
