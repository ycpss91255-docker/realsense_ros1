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

# ------------------- advertised-URI pre-flight assert (#137) ------------------
#
# The #79/#80 boot gate and the #81/#136 watchdog both assume the slave is
# *reachable* once it registers. But a remote-master slave that advertises a
# loopback or unresolvable address boots fine and registers, yet is invisible in
# practice: peers read its URI from the master, dial 127.0.1.1 (the Debian
# /etc/hosts bare-hostname trap) or an unresolvable name, and never connect --
# the classic "`rostopic list` works, `rostopic echo` hangs" symptom, with no
# error anywhere. This pre-flight blocks startup BEFORE roslaunch when the
# address THIS node will advertise -- computed in ROS precedence order without a
# live master -- resolves to loopback or does not resolve at all.
#
# Like the watchdog (#136) the decision is factored into small PURE functions
# plus a thin impure orchestrator, so sourcing the entrypoint exercises the whole
# path (a fake `getent` on PATH stands in for resolution). It is gated (in main,
# via _advertise_assert_enabled) to exactly the watchdog's scope -- roslaunch +
# remote master -- so single-machine / local-master / non-roslaunch boots stay
# byte-identical. ADVERTISE_ASSERT_ENABLED=0 is the escape hatch for deployments
# with real cross-host DNS, where a hostname is a legitimate advertised value.

# PURE. Echo the host THIS node will advertise, in rospy get_local_address /
# roscpp determineHost precedence: an argv `__hostname:=` override wins over an
# argv `__ip:=` override, which wins over ${ROS_HOSTNAME}, then ${ROS_IP}, then
# the `hostname` fallback. Scan the whole argv for each override (either may sit
# anywhere in the launch args), so a later __ip:= never shadows an __hostname:=.
_advertised_host() {
  local arg cli_hostname="" cli_ip=""
  for arg in "$@"; do
    case "${arg}" in
      __hostname:=*) cli_hostname="${arg#__hostname:=}" ;;
      __ip:=*) cli_ip="${arg#__ip:=}" ;;
    esac
  done

  if [[ -n "${cli_hostname}" ]]; then
    printf '%s\n' "${cli_hostname}"
  elif [[ -n "${cli_ip}" ]]; then
    printf '%s\n' "${cli_ip}"
  elif [[ -n "${ROS_HOSTNAME:-}" ]]; then
    printf '%s\n' "${ROS_HOSTNAME}"
  elif [[ -n "${ROS_IP:-}" ]]; then
    printf '%s\n' "${ROS_IP}"
  else
    hostname
  fi
}

# PURE classifier: does the address route only to this host? Success (return 0)
# for localhost, the whole 127.0.0.0/8 block (Debian maps the bare hostname to
# 127.0.1.1 -- the exact trap this assert catches), IPv6 loopback ::1, and its
# IPv4-mapped form ::ffff:127.*. Any other address -> failure (not loopback).
_addr_is_loopback() {
  local addr="$1"
  case "${addr}" in
    localhost | 127.* | ::1 | ::ffff:127.*) return 0 ;;
    *) return 1 ;;
  esac
}

# PURE classifier: is this string ALREADY a numeric address, i.e. is there
# nothing left to look up? Success (return 0) for an IPv4 dotted-quad and for any
# IPv6 form -- a colon can only mean IPv6 (`::1`, `2001:db8::5`,
# `::ffff:192.0.2.1`) since no DNS name may contain one. A hostname, bare or
# FQDN, always carries a non-digit outside the dots, so it never classifies as a
# literal. Backs the _resolve_host_addr short-circuit below.
_addr_is_ip_literal() {
  local addr="$1"
  case "${addr}" in
    *:*) return 0 ;;
  esac
  [[ "${addr}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  return 0
}

# PURE truth table (like _watchdog_decide): map a resolved address onto a verdict
# echoed on stdout, always returning 0.
#   ""                    -> UNRESOLVABLE (getent failed, host does not resolve)
#   loopback address      -> LOOPBACK
#   any other address     -> OK
_advertise_decide() {
  local addr="$1"
  if [[ -z "${addr}" ]]; then
    printf 'UNRESOLVABLE\n'
  elif _addr_is_loopback "${addr}"; then
    printf 'LOOPBACK\n'
  else
    printf 'OK\n'
  fi
  return 0
}

# Impure resolver: echo the address the advertised host maps to. An IP literal
# is echoed back UNCHANGED and never reaches `getent` (#141): `getent hosts <ip>`
# is not a forward lookup, it is a REVERSE (PTR) lookup, so a perfectly routable
# numeric ROS_IP with no PTR record exits 2 with no output -- and whether a PTR
# answers varies boot to boot, which made this assert both false-positive on the
# most common correct configuration and non-deterministic. Only a NAME is worth
# looking up: `getent hosts <name>` echoes the mapped address in its first field
# (`localhost` -> 127.0.0.1, a Debian bare hostname -> 127.0.1.1, the trap this
# assert exists to catch). On lookup failure (getent non-zero) echo nothing and
# return non-zero. The name path is injectable via a fake `getent` on PATH, the
# same trick the fake-`rosnode` tests use.
_resolve_host_addr() {
  local host="$1"
  local line addr
  if _addr_is_ip_literal "${host}"; then
    printf '%s\n' "${host}"
    return 0
  fi
  line="$(getent hosts "${host}")" || return 1
  read -r addr _ <<< "${line}"
  printf '%s\n' "${addr}"
}

# PURE gate, mirrors _watchdog_enabled: engage the assert only when it is not
# explicitly disabled (ADVERTISE_ASSERT_ENABLED defaults to 1, "0" opts out) AND
# the command is roslaunch AND the master is remote. Reuses _ros_master_is_remote
# so single-machine / local-master boots keep the gate false (byte-identical).
_advertise_assert_enabled() {
  [[ "${ADVERTISE_ASSERT_ENABLED:-1}" != "0" ]] || return 1
  [[ "${1:-}" == "roslaunch" ]] || return 1
  _ros_master_is_remote || return 1
  return 0
}

# Orchestrator (main gates it; NO gate inside). Resolve the advertised host and
# return 0 when the verdict is OK. Otherwise print the FULL derivation chain --
# the precedence layers with their values, which host was selected, what it
# resolved to (or UNRESOLVABLE), the verdict, and the fix -- to stderr and return
# 1, so an operator who reads only this message can fix it without knowing ROS
# host-precedence.
_assert_advertised() {
  local host addr verdict
  host="$(_advertised_host "$@")"
  addr="$(_resolve_host_addr "${host}" || true)"
  verdict="$(_advertise_decide "${addr}")"
  [[ "${verdict}" == "OK" ]] && return 0

  local arg cli_hostname="" cli_ip=""
  for arg in "$@"; do
    case "${arg}" in
      __hostname:=*) cli_hostname="${arg#__hostname:=}" ;;
      __ip:=*) cli_ip="${arg#__ip:=}" ;;
    esac
  done

  {
    printf 'FATAL: advertised-address pre-flight assert failed (#137).\n'
    printf 'This node would advertise an address that peers cannot reach, so it\n'
    printf 'would register on the remote master but receive no connections\n'
    printf '(the "rostopic list works, rostopic echo hangs" symptom).\n'
    printf 'advertised-host precedence (first set wins):\n'
    printf '  __hostname:= %s -> __ip:= %s -> ROS_HOSTNAME %s -> ROS_IP %s -> hostname %s\n' \
      "${cli_hostname:-unset}" "${cli_ip:-unset}" \
      "${ROS_HOSTNAME:-unset}" "${ROS_IP:-unset}" "$(hostname)"
    printf 'selected advertised host: %s\n' "${host}"
    if [[ -z "${addr}" ]]; then
      printf 'resolution: %s -> UNRESOLVABLE\n' "${host}"
    else
      printf 'resolution: %s -> %s\n' "${host}" "${addr}"
    fi
    printf 'verdict: %s\n' "${verdict}"
    printf 'fix: set ROS_IP to this machine'\''s LAN IP so it advertises a routable\n'
    printf '     address; or set ADVERTISE_ASSERT_ENABLED=0 to bypass this check\n'
    printf '     (only if a real cross-host DNS makes the advertised host reachable).\n'
  } >&2
  return 1
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

# ---------------------------- filter config (#146) ----------------------------
#
# Baked-in post-processing filter profile, the exact mirror of the camera
# profile above: the Dockerfile COPYs the repo-root `filters.yaml` symlink's
# TARGET into the image as /filter_config.yaml (default target
# config/realsense/filters/none.yaml is EMPTY = "no post-processing"), and
# activating a profile is repointing that symlink (or passing --build-arg
# FILTER_CONFIG=config/realsense/filters/temporal_smooth.yaml).
#
# One profile file owns BOTH halves of the configuration, because they cannot
# share a namespace and splitting them across two files makes half-configured
# states possible with no warning:
#
#   which filters to construct -> <camera>/realsense2_camera/filters
#   their parameters           -> <camera>/<filter>/... (e.g. <camera>/temporal)
#
# So the wrapper launch takes them through two different routes: the parameters
# are rosparam-loaded into the PUBLIC camera namespace via `filter_config_file:=`,
# and the filter list is forwarded to the stock launch arg via `filters:=`, read
# out of the profile's `filters_list` key. The two are appended TOGETHER or not
# at all: appending only the first would load parameters for filters that are
# never constructed; appending only the second would construct them with the
# librealsense defaults (temporal alpha 0.4 instead of 0.1 -- measured as
# 12.16 mm of temporal noise instead of 5.59 mm). A non-empty profile that
# yields no usable filter list is therefore a misconfiguration, not a
# "parameters-only" mode, and it is fatal (see _apply_filter_config).
FILTER_CONFIG_FILE="/filter_config.yaml"

# The closed set of filter names upstream realsense-ros 2.3.2 `setupFilters()`
# accepts. Anything else reaches its `else` branch, which does
# `ROS_ERROR_STREAM(...); throw;` -- a bare re-throw with NO active exception,
# i.e. std::terminate(), killing the nodelet manager. The manager is not
# `required`, so roslaunch survives, the camera node never registers, and the
# #136 watchdog relaunches on its startup deadline into the same crash: one
# malformed line becomes a permanent ~5-minute crash loop. Validating here and
# refusing to start is strictly better than that loop.
readonly FILTER_NAMES_ALLOWED="colorizer disparity spatial temporal \
hole_filling decimation pointcloud hdr_merge"

# PURE. Is $1 a comma-separated list of names from FILTER_NAMES_ALLOWED?
# The shape check rejects everything the whitespace/comment/quote normalisation
# below cannot fix -- YAML flow sequences (`[a, b]`), block scalars (`>`, `|`),
# `null`, an unterminated quote, empty elements (`a,,b`, `a,`) -- and the
# membership check then rejects names upstream would terminate on.
_filters_list_is_valid() {
  local value="$1"
  [[ "${value}" =~ ^[a-z_]+(,[a-z_]+)*$ ]] || return 1

  local name
  local -a names=()
  IFS=',' read -r -a names <<< "${value}"
  for name in "${names[@]}"; do
    [[ " ${FILTER_NAMES_ALLOWED} " == *" ${name} "* ]] || return 1
  done
  return 0
}

# Print the validated `filters_list` value of the profile file named by $1, or
# nothing when the key is absent or its value is empty. Returns non-zero (after
# printing a FATAL block to stderr) when the file cannot be read or the value is
# malformed -- the caller must propagate that, never fall back.
#
# The key is entrypoint-facing rather than ROS-facing, but it still lands on the
# parameter server, so it must be a legal ROS graph resource name: a leading
# underscore is not (`getParam("_filters", ...)` throws InvalidNameException in
# roscpp), hence `filters_list`.
#
# Matched anchored at the line start, so a commented-out `# filters_list:` stays
# disabled (commenting the key out is how a profile is parked while its
# parameters stay documented) and an indented `filters_list:` nested inside a
# filter block is not mistaken for the top-level key.
#
# Normalisation, in order: drop an inline `#` comment (a filter name can never
# contain `#`, so cutting at the first one is safe and strictly stricter than
# YAML's "whitespace before #" rule), drop ALL whitespace including internal
# (`"disparity, temporal"` is the natural thing to write), then strip one
# matching layer of quotes -- the repo's own profile quotes the value because it
# contains a comma, and roslaunch must receive the bare list.
_read_filters_list() {
  local file="$1"
  local line value grep_status=0

  # `-s` (the caller's gate) is true for a DIRECTORY too, and a plain grep error
  # was previously swallowed by `2>/dev/null || return 0`, reporting "no filters"
  # for a file we could not read while the caller still pointed roslaunch at it.
  if [[ ! -f "${file}" || ! -r "${file}" ]]; then
    {
      printf 'FATAL: filter profile is not a readable file (#146).\n'
      printf 'The baked filter profile could not be read, so the filter list it\n'
      printf 'owns cannot be honoured. Refusing to start rather than launching\n'
      printf 'with post-processing silently disabled.\n'
      printf 'profile path: %s\n' "${file}"
      printf 'fix: check the FILTER_CONFIG build arg and any bind-mount over\n'
      printf '     this path -- it must be a readable regular file (the default\n'
      printf '     empty config/realsense/filters/none.yaml disables filtering).\n'
    } >&2
    return 1
  fi

  line="$(grep -m 1 -E '^filters_list[[:space:]]*:' -- "${file}")" || grep_status="$?"
  if (( grep_status > 1 )); then
    {
      printf 'FATAL: filter profile could not be scanned (#146).\n'
      printf 'profile file: %s\n' "${file}"
      printf 'fix: check the file is readable and not truncated.\n'
    } >&2
    return 1
  fi
  (( grep_status == 0 )) || return 0

  value="${line#*:}"
  value="${value%%#*}"
  value="${value//[[:space:]]/}"
  if [[ "${value}" == \"*\" || "${value}" == \'*\' ]]; then
    value="${value:1:${#value}-2}"
  fi

  [[ -n "${value}" ]] || return 0

  if ! _filters_list_is_valid "${value}"; then
    {
      printf 'FATAL: filter profile has a malformed `filters_list` value (#146).\n'
      printf 'Passing it through would make the camera node terminate on an\n'
      printf 'unknown filter name (upstream setupFilters() re-throws with no\n'
      printf 'active exception, killing the nodelet manager), and the watchdog\n'
      printf 'would relaunch it into the same crash forever. Refusing to start.\n'
      printf 'profile file: %s\n' "${file}"
      printf 'offending line: %s\n' "${line}"
      printf 'normalised value: %s\n' "${value}"
      printf 'expected: a comma-separated list, no spaces required, of: %s\n' \
        "${FILTER_NAMES_ALLOWED// /, }"
      printf 'fix: write it as one plain scalar, e.g.\n'
      printf '       filters_list: "disparity,temporal"\n'
      printf '     A YAML sequence ([a, b]), a block scalar (> or |), `null`\n'
      printf '     and an unterminated quote are all rejected on purpose.\n'
    } >&2
    return 1
  fi

  printf '%s\n' "${value}"
}

# Resolve the launch argv into CONFIGURED_ARGV, same contract as
# _apply_camera_config: append the filter args when the command is a roslaunch
# AND a NON-empty /filter_config.yaml is baked in; leave the argv untouched for
# an empty profile (the default), a config bind-mounted away entirely, or a
# non-roslaunch command such as the devel `bash`.
#
# Returns non-zero when a baked profile is present but unusable -- unreadable,
# malformed `filters_list`, or no `filters_list` at all. The last one is not a
# supported "parameters-only" mode: loading parameters for filters that are
# never constructed is exactly the silent half-configured state this single-file
# design exists to prevent, so it fails loudly instead. The caller exits on a
# non-zero return.
#
# Injection is skipped entirely when the incoming argv already sets `filters:=`
# (or `filter_config_file:=`), mirroring the `--wait` guard in _resolve_argv:
# roslaunch takes the LAST value for a repeated arg, so appending ours after the
# operator's would silently override the explicit command line
# (`... rs_camera.launch filters:=pointcloud`).
#
# The two appliers are independent and compose; the caller chains them by
# feeding CONFIGURED_ARGV from one into the next.
_apply_filter_config() {
  CONFIGURED_ARGV=("$@")

  [[ "${1:-}" == "roslaunch" ]] || return 0
  # `-s` is the "a profile is baked in" gate (the default none.yaml is 0 bytes).
  # `-d` is ORed in so a bind-mount that lands a DIRECTORY here reaches the fatal
  # read check below instead of depending on a directory's apparent size.
  [[ -s "${FILTER_CONFIG_FILE}" || -d "${FILTER_CONFIG_FILE}" ]] || return 0

  local arg
  for arg in "$@"; do
    case "${arg}" in
      filters:=* | filter_config_file:=*)
        printf 'Filter args already set on the command line; the baked filter\n' >&2
        printf 'profile (%s) is NOT applied for this run.\n' \
          "${FILTER_CONFIG_FILE}" >&2
        return 0
        ;;
    esac
  done

  local filters
  filters="$(_read_filters_list "${FILTER_CONFIG_FILE}")" || return 1

  if [[ -z "${filters}" ]]; then
    {
      printf 'FATAL: filter profile has no `filters_list` key (#146).\n'
      printf 'A non-empty profile must say which filters to construct: its\n'
      printf 'parameter blocks are read from each filter, so loading them\n'
      printf 'without constructing the filters does nothing at all, silently.\n'
      printf 'profile file: %s\n' "${FILTER_CONFIG_FILE}"
      printf 'expected: a top-level, uncommented line such as\n'
      printf '       filters_list: "disparity,temporal"\n'
      printf 'fix: add it, or select the empty profile\n'
      printf '     (config/realsense/filters/none.yaml) to run no filters.\n'
    } >&2
    return 1
  fi

  printf 'Applying filter profile from %s\n' "${FILTER_CONFIG_FILE}"
  CONFIGURED_ARGV=("$@" "filter_config_file:=${FILTER_CONFIG_FILE}" \
    "filters:=${filters}")
}

# --------------------- profile pre-flight assert (#149) ----------------------
#
# _apply_filter_config validates the profile FILE. Nothing validated that the
# args it appends REACH the node, and roslaunch silently drops a top-level arg
# the launch file does not declare. A deployment that bind-mounts its own
# /rs_camera.launch override -- written before #146, or simply not forwarding
# the two args into its <include> -- therefore ran completely unfiltered while
# this script printed "Applying filter profile" and the process argv showed both
# args. Observed on hardware as /camera/realsense2_camera/filters == '' with no
# /camera/temporal namespace at all. Same failure class as #143: a config that
# reports success and does nothing.
#
# `roslaunch --dump-params` resolves the entire include tree OFFLINE -- no
# master, no device, nothing started -- and prints the parameters that would
# actually be set. That makes the swallow detectable before startup.

# PURE. Print the top-level parameter BLOCKS a profile declares, one per line: a
# key at column 0 with no inline value. Keys that carry a value (filters_list)
# name no namespace, and commented-out or indented keys are not blocks -- the
# example profile ships optional blocks commented out, and asserting on those
# would block startup for a profile that is behaving correctly.
_profile_param_blocks() {
  sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\):[[:space:]]*$/\1/p' "${1}"
}

# PURE. Compare a --dump-params dump against what the entrypoint appended and
# print the verdict, mirroring _advertise_decide. Args: the dump, the expected
# `filters` value, then zero or more profile block names.
#
# Two distinct swallows are possible and both matter:
#   FILTERS_SWALLOWED  `filters:=` was dropped -- no filter is constructed
#   BLOCK_MISSING:<b>  `filter_config_file:=` was dropped while `filters:=` got
#                      through -- the filters ARE constructed but every
#                      parameter falls back to the librealsense default, which
#                      is exactly the half-configured state #146 exists to
#                      prevent
# FILTERS_MISMATCH reports the winning value verbatim, because the likely cause
# is an override hardcoding its own filters:= and the operator needs to see what
# won, not merely that something differs.
_profile_decide() {
  local dump="${1}" expected="${2}"
  shift 2

  # Here-strings, NOT `printf | sed`: under `pipefail` a downstream reader that
  # exits early (head, grep -q) SIGPIPEs the writer and the whole pipeline
  # reports non-zero, which would turn a present block into a false
  # BLOCK_MISSING on any dump large enough to outgrow the pipe buffer.
  local actual
  actual="$(sed -n 's#^/.*/realsense2_camera/filters:[[:space:]]*##p' \
    <<< "${dump}")"
  actual="${actual%%$'\n'*}"
  # roslaunch renders a dropped arg's empty-string default as ''.
  actual="${actual#\'}"
  actual="${actual%\'}"

  if [[ -z "${actual}" ]]; then
    printf 'FILTERS_SWALLOWED\n'
    return 0
  fi

  if [[ "${actual}" != "${expected}" ]]; then
    printf 'FILTERS_MISMATCH:%s\n' "${actual}"
    return 0
  fi

  local block
  for block in "$@"; do
    if ! grep -qE "^/.*/${block}/" <<< "${dump}"; then
      printf 'BLOCK_MISSING:%s\n' "${block}"
      return 0
    fi
  done

  printf 'OK\n'
}

# PURE gate, mirrors _advertise_assert_enabled: engage only when not explicitly
# disabled (PROFILE_ASSERT_ENABLED defaults to 1, "0" opts out), the command is
# roslaunch, AND a profile was actually applied. The last condition keeps the
# default empty profile and every non-profile boot byte-identical -- with no
# `filters:=` in the argv there is nothing to assert.
_profile_assert_enabled() {
  [[ "${PROFILE_ASSERT_ENABLED:-1}" != "0" ]] || return 1
  [[ "${1:-}" == "roslaunch" ]] || return 1

  local arg
  for arg in "$@"; do
    case "${arg}" in
      filters:=*) return 0 ;;
    esac
  done
  return 1
}

# Orchestrator (main gates it; NO gate inside). Return 0 when the profile
# provably reaches the node. Otherwise print what was appended, what the launch
# tree actually resolves to, and the exact <arg> lines that are missing, then
# return 1.
#
# Runs BEFORE _resolve_argv, so the argv here is `roslaunch <file> <args...>`
# with no --wait injected yet; "${@:2}" is the launch file and its args.
#
# A dump that cannot be produced is a WARNING, not a failure: roslaunch reports
# its own parse error moments later, and a false positive here must never block
# a correct config. That is the #137 -> #141 lesson, where a reverse-DNS lookup
# that legitimately had no PTR record blocked a perfectly good ROS_IP.
_assert_profile_applied() {
  local arg expected=""
  for arg in "$@"; do
    case "${arg}" in
      filters:=*) expected="${arg#filters:=}" ;;
    esac
  done

  local dump
  if ! dump="$(roslaunch --dump-params "${@:2}" 2>/dev/null)"; then
    {
      printf 'WARNING: `roslaunch --dump-params` failed, so the filter profile\n'
      printf 'pre-flight assert (#149) was SKIPPED and startup continues.\n'
      printf 'roslaunch reports its own error next; this check does not block\n'
      printf 'a config it cannot evaluate.\n'
    } >&2
    return 0
  fi

  local blocks=()
  if [[ -r "${FILTER_CONFIG_FILE}" ]]; then
    mapfile -t blocks < <(_profile_param_blocks "${FILTER_CONFIG_FILE}")
  fi

  local verdict
  verdict="$(_profile_decide "${dump}" "${expected}" "${blocks[@]}")"
  [[ "${verdict}" == "OK" ]] && return 0

  local launch_file="${2:-<unknown>}"
  {
    printf 'FATAL: filter profile pre-flight assert failed (#149).\n'
    printf 'The profile args were appended but do NOT reach the node, so the\n'
    printf 'camera would run misconfigured while every log line above claims\n'
    printf 'the profile was applied.\n'
    printf 'launch file:      %s\n' "${launch_file}"
    printf 'profile file:     %s\n' "${FILTER_CONFIG_FILE}"
    printf 'appended:         filter_config_file:=%s filters:=%s\n' \
      "${FILTER_CONFIG_FILE}" "${expected}"
    printf 'verdict:          %s\n' "${verdict}"
    case "${verdict}" in
      FILTERS_SWALLOWED)
        printf 'resolved filters: <empty> (the arg was dropped)\n'
        ;;
      FILTERS_MISMATCH:*)
        printf 'resolved filters: %s (something else set it)\n' \
          "${verdict#FILTERS_MISMATCH:}"
        ;;
      BLOCK_MISSING:*)
        printf 'resolved filters: %s (correct), but the profile parameters\n' \
          "${expected}"
        printf '                  never load: no %s namespace in the launch\n' \
          "${verdict#BLOCK_MISSING:}"
        printf '                  tree, so every value falls back to the\n'
        printf '                  librealsense default.\n'
        ;;
    esac
    printf 'cause:            roslaunch SILENTLY DROPS a top-level arg the\n'
    printf '                  launch file does not declare.\n'
    printf 'fix: in %s declare BOTH args and\n' "${launch_file}"
    printf '     forward them into its <include> of /rs_camera_config.launch:\n'
    printf '       <arg name="filter_config_file" default=""/>\n'
    printf '       <arg name="filters"            default=""/>\n'
    printf '       ...\n'
    printf '       <include file="/rs_camera_config.launch">\n'
    printf '         <arg name="filter_config_file" value="$(arg filter_config_file)"/>\n'
    printf '         <arg name="filters"            value="$(arg filters)"/>\n'
    printf '       </include>\n'
    printf '     See config/realsense/rs_camera_remap.example.launch for a\n'
    printf '     complete override. Or set PROFILE_ASSERT_ENABLED=0 to bypass\n'
    printf '     (only if the profile is deliberately not meant to apply).\n'
  } >&2
  return 1
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

  # Apply the baked-in camera and filter profiles (if any) BEFORE the
  # wait/watchdog gates, so the rewritten roslaunch argv still flows through
  # --wait injection and the watchdog relaunch loop unchanged. The two are
  # independent: chaining CONFIGURED_ARGV through both keeps either profile
  # usable on its own or together.
  _apply_camera_config "$@"
  set -- "${CONFIGURED_ARGV[@]}"

  # A baked filter profile that cannot be honoured (unreadable / malformed /
  # no filter list) exits here: launching anyway would either crash-loop the
  # nodelet manager or run silently unfiltered.
  _apply_filter_config "$@" || exit 1
  set -- "${CONFIGURED_ARGV[@]}"

  # Pre-flight (#149): prove the profile args actually reach the node. A launch
  # file that does not declare (or does not forward) them makes roslaunch drop
  # them silently, and the camera then runs misconfigured with nothing but
  # success messages in the log. Only engages when a profile was applied.
  if _profile_assert_enabled "$@"; then
    _assert_profile_applied "$@" || exit 1
  fi

  # Pre-flight (#137): for a remote-master roslaunch, block startup if the address
  # this node would advertise resolves to loopback or does not resolve -- it would
  # register but be unreachable. Gated to the watchdog's scope, so single-machine
  # / local-master / non-roslaunch paths stay byte-identical; ADVERTISE_ASSERT_ENABLED=0
  # opts out. Runs once for both the watchdog and the plain-exec roslaunch paths.
  if _advertise_assert_enabled "$@"; then
    _assert_advertised "$@" || exit 1
  fi

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
