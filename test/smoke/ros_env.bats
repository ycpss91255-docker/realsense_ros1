#!/usr/bin/env bats

setup() {
    load "${BATS_TEST_DIRNAME}/test_helper"
}

# -------------------- ROS environment --------------------

@test "ROS_DISTRO is set" {
    assert [ -n "${ROS_DISTRO}" ]
}

@test "ROS 1 setup.bash exists" {
    assert [ -f "/opt/ros/${ROS_DISTRO}/setup.bash" ]
}

@test "ROS 1 setup.bash can be sourced" {
    run bash -c "source /opt/ros/${ROS_DISTRO}/setup.bash"
    assert_success
}

@test "interactive shells source ROS (roslaunch on PATH via bashrc.d)" {
    # The base bashrc is ROS-agnostic and loads ~/.bashrc.d/*.sh for interactive
    # shells; this repo ships config/shell/bashrc.d/10-ros-source.sh to source
    # ROS. Without it, roslaunch / roscore / realsense-viewer are "command not
    # found" in interactive just run / just exec shells even though installed.
    assert [ -f "${HOME}/.bashrc.d/10-ros-source.sh" ]
    run bash -c "source ${HOME}/.bashrc.d/10-ros-source.sh && command -v roslaunch"
    assert_success
    assert_output --partial "/opt/ros/${ROS_DISTRO}/bin/roslaunch"
}

# -------------------- Entrypoint: remote-master wait --------------------
#
# entrypoint.sh resolves the final argv into RESOLVED_ARGV without executing,
# so the decision is unit-testable without a live master. When ROS_MASTER_URI
# points at a remote master AND the command is roslaunch, it injects
# `roslaunch --wait` (blocks until the master is reachable, then launches),
# fixing the multi-machine slave boot race (#79). Sourcing the entrypoint runs
# only the pure functions; the ROS-source + exec are guarded to the real
# entrypoint invocation, so these tests can source it safely.

@test "entrypoint injects --wait for a remote master + roslaunch (#79)" {
    run bash -c 'export ROS_MASTER_URI=http://192.168.1.5:11311; source /entrypoint.sh; _resolve_argv roslaunch pkg foo.launch; echo "${RESOLVED_ARGV[@]}"'
    assert_success
    assert_output "roslaunch --wait pkg foo.launch"
}

@test "entrypoint does not inject --wait for a local master (#79)" {
    run bash -c 'export ROS_MASTER_URI=http://localhost:11311; source /entrypoint.sh; _resolve_argv roslaunch pkg foo.launch; echo "${RESOLVED_ARGV[@]}"'
    assert_success
    assert_output "roslaunch pkg foo.launch"
}

@test "entrypoint does not inject --wait when ROS_MASTER_URI is unset (#79)" {
    run bash -c 'unset ROS_MASTER_URI; source /entrypoint.sh; _resolve_argv roslaunch pkg foo.launch; echo "${RESOLVED_ARGV[@]}"'
    assert_success
    assert_output "roslaunch pkg foo.launch"
}

@test "entrypoint passes non-roslaunch commands through unchanged (#79)" {
    run bash -c 'export ROS_MASTER_URI=http://192.168.1.5:11311; source /entrypoint.sh; _resolve_argv bash -c "echo hi"; echo "${RESOLVED_ARGV[@]}"'
    assert_success
    assert_output "bash -c echo hi"
}

@test "entrypoint does not double-inject --wait when already present (#79)" {
    run bash -c 'export ROS_MASTER_URI=http://192.168.1.5:11311; source /entrypoint.sh; _resolve_argv roslaunch --wait pkg foo.launch; echo "${RESOLVED_ARGV[@]}"'
    assert_success
    assert_output "roslaunch --wait pkg foo.launch"
}

@test "_ros_master_is_remote treats a global IPv6 master as remote (#79)" {
    # The host parser must strip the [..] brackets before classifying; a global
    # IPv6 literal like [fd00::5] is a remote master and must trigger --wait.
    run bash -c 'export ROS_MASTER_URI=http://[fd00::5]:11311; source /entrypoint.sh; _ros_master_is_remote'
    assert_success
}

@test "_ros_master_is_remote treats IPv6 loopback [::1] as local (#79)" {
    # [::1] is loopback: roslaunch starts its own roscore, so injecting --wait
    # would deadlock. The bracket-stripped host must classify as local.
    run bash -c 'export ROS_MASTER_URI=http://[::1]:11311; source /entrypoint.sh; _ros_master_is_remote'
    assert_failure
}

# -------------------- Entrypoint: remote-master watchdog --------------------
#
# On top of the boot gate (#79/#80), when the master is remote the entrypoint
# can run a watchdog: it (re)launches `roslaunch --wait` and restarts it if our
# node stays deregistered (a remote master restarted on the same port stays
# TCP-reachable but leaves roslaunch alive and unregistered). The watchdog is
# opt-in (default off, consistent with base `[lifecycle] restart = no`); enable
# it with `WATCHDOG_ENABLED=1`. The gate (`--wait`) still applies regardless.
# The enable-decision and the registration check are factored into pure
# functions so these tests never start the real while-loop (which is guarded to
# the real entrypoint invocation and hardware-verified separately).

@test "watchdog off by default for a remote master + roslaunch (#81)" {
    run bash -c 'export ROS_MASTER_URI=http://192.168.1.5:11311; unset WATCHDOG_ENABLED; source /entrypoint.sh; _watchdog_enabled roslaunch pkg foo.launch'
    assert_failure
}

@test "watchdog enabled with WATCHDOG_ENABLED=1 + remote master + roslaunch (#81)" {
    run bash -c 'export ROS_MASTER_URI=http://192.168.1.5:11311 WATCHDOG_ENABLED=1; source /entrypoint.sh; _watchdog_enabled roslaunch pkg foo.launch'
    assert_success
}

@test "watchdog disabled when WATCHDOG_ENABLED=0 (#81)" {
    run bash -c 'export ROS_MASTER_URI=http://192.168.1.5:11311 WATCHDOG_ENABLED=0; source /entrypoint.sh; _watchdog_enabled roslaunch pkg foo.launch'
    assert_failure
}

@test "watchdog disabled for a local master even with WATCHDOG_ENABLED=1 (#81)" {
    run bash -c 'export ROS_MASTER_URI=http://localhost:11311 WATCHDOG_ENABLED=1; source /entrypoint.sh; _watchdog_enabled roslaunch pkg foo.launch'
    assert_failure
}

@test "watchdog disabled for a non-roslaunch command even with WATCHDOG_ENABLED=1 (#81)" {
    run bash -c 'export ROS_MASTER_URI=http://192.168.1.5:11311 WATCHDOG_ENABLED=1; source /entrypoint.sh; _watchdog_enabled bash -c "echo hi"'
    assert_failure
}

@test "watchdog node present in rosnode list is healthy (#81)" {
    run bash -c 'source /entrypoint.sh; _node_registered /camera/realsense2_camera "$(printf "%s\n" /rosout /camera/realsense2_camera)"'
    assert_success
}

@test "watchdog node absent from rosnode list is unhealthy (#81)" {
    run bash -c 'source /entrypoint.sh; _node_registered /camera/realsense2_camera "$(printf "%s\n" /rosout /other_node)"'
    assert_failure
}

@test "watchdog stops the roslaunch child with SIGTERM, not SIGINT (#81)" {
    # The roslaunch child is started async (`roslaunch ... &`), so a
    # non-interactive shell sets its SIGINT/SIGQUIT to SIG_IGN (POSIX). `kill
    # -INT` on it would be ignored and the following `wait` would hang forever
    # (verified: restart-on-orphan and clean shutdown both stall). The watchdog
    # must signal the child with SIGTERM, which is not ignored and which
    # roslaunch handles with a clean node shutdown.
    run grep -F 'kill -INT' /entrypoint.sh
    assert_failure
    run grep -F 'kill -TERM "${_WATCHDOG_CHILD_PID}"' /entrypoint.sh
    assert_success
}

# -------------------- Entrypoint: watchdog probe + decision --------------------
#
# The watchdog loop is a thin shell over two pure functions (#136):
#
#   _watchdog_probe  runs the `rosnode list` query and classifies the result by
#                    EXIT CODE (not by empty output): non-zero (timeout /
#                    unreachable) -> `unreachable`; exit 0 with our node in the
#                    list -> `healthy`; exit 0 WITHOUT our node (a freshly
#                    restarted master answers with an empty list) ->
#                    `deregistered`. These tests drive it with a fake `rosnode`
#                    on PATH so no live master is needed.
#
#   _watchdog_decide a pure (state, registered_once, failures, elapsed,
#                    max_failures, startup_deadline) -> action mapping. Phase 1
#                    (never registered) ignores the failure counter and only a
#                    WATCHDOG_STARTUP_DEADLINE backstop can force a restart;
#                    phase 2 (registered at least once) debounces `unreachable`
#                    blips via the failure counter and restarts immediately on
#                    `deregistered`. The full truth table is exercised below.

@test "watchdog probe classifies a listed node as healthy (#136)" {
    run bash -c '
      dir="$(mktemp -d)"
      cat >"${dir}/rosnode" <<EOF
#!/usr/bin/env bash
printf "%s\n" /rosout /camera/realsense2_camera
EOF
      chmod +x "${dir}/rosnode"
      PATH="${dir}:${PATH}"
      source /entrypoint.sh
      _watchdog_probe /camera/realsense2_camera rosnode list
    '
    assert_success
    assert_output "healthy"
}

@test "watchdog probe classifies an empty list (exit 0) as deregistered (#136)" {
    # A master restarted on the same port answers `rosnode list` successfully
    # but with an empty list -- that is `deregistered` (our node is gone), NOT
    # `unreachable`. Classification is by exit code, not empty output.
    run bash -c '
      dir="$(mktemp -d)"
      cat >"${dir}/rosnode" <<EOF
#!/usr/bin/env bash
exit 0
EOF
      chmod +x "${dir}/rosnode"
      PATH="${dir}:${PATH}"
      source /entrypoint.sh
      _watchdog_probe /camera/realsense2_camera rosnode list
    '
    assert_success
    assert_output "deregistered"
}

@test "watchdog probe classifies a non-zero (timeout) query as unreachable (#136)" {
    # `timeout` kills a hung query with exit 124; any non-zero exit means the
    # master is unreachable regardless of what was printed.
    run bash -c '
      dir="$(mktemp -d)"
      cat >"${dir}/rosnode" <<EOF
#!/usr/bin/env bash
exit 124
EOF
      chmod +x "${dir}/rosnode"
      PATH="${dir}:${PATH}"
      source /entrypoint.sh
      _watchdog_probe /camera/realsense2_camera rosnode list
    '
    assert_success
    assert_output "unreachable"
}

@test "watchdog decide: phase1 healthy marks the node registered (#136)" {
    run bash -c 'source /entrypoint.sh; _watchdog_decide healthy 0 0 0 3 300'
    assert_success
    assert_output "HEALTHY"
}

@test "watchdog decide: phase1 unreachable below the deadline waits (#136)" {
    run bash -c 'source /entrypoint.sh; _watchdog_decide unreachable 0 0 30 3 300'
    assert_success
    assert_output "WAIT"
}

@test "watchdog decide: phase1 deregistered below the deadline waits (#136)" {
    run bash -c 'source /entrypoint.sh; _watchdog_decide deregistered 0 0 30 3 300'
    assert_success
    assert_output "WAIT"
}

@test "watchdog decide: phase1 unreachable at the deadline restarts (#136)" {
    run bash -c 'source /entrypoint.sh; _watchdog_decide unreachable 0 0 300 3 300'
    assert_success
    assert_output "RESTART"
}

@test "watchdog decide: phase1 deregistered past the deadline restarts (#136)" {
    run bash -c 'source /entrypoint.sh; _watchdog_decide deregistered 0 0 305 3 300'
    assert_success
    assert_output "RESTART"
}

@test "watchdog decide: phase2 healthy resets and stays registered (#136)" {
    run bash -c 'source /entrypoint.sh; _watchdog_decide healthy 1 2 400 3 300'
    assert_success
    assert_output "HEALTHY"
}

@test "watchdog decide: phase2 unreachable below max failures waits (#136)" {
    run bash -c 'source /entrypoint.sh; _watchdog_decide unreachable 1 1 400 3 300'
    assert_success
    assert_output "WAIT"
}

@test "watchdog decide: phase2 unreachable reaching max failures restarts (#136)" {
    run bash -c 'source /entrypoint.sh; _watchdog_decide unreachable 1 2 400 3 300'
    assert_success
    assert_output "RESTART"
}

@test "watchdog decide: phase2 deregistered restarts on the next tick (#136)" {
    run bash -c 'source /entrypoint.sh; _watchdog_decide deregistered 1 0 400 3 300'
    assert_success
    assert_output "RESTART"
}

# -------------------- Entrypoint: advertised-URI pre-flight assert --------------------
#
# A remote-master slave that advertises a loopback / unresolvable address boots
# fine but is invisible on the master (peers dial the bad URI and never connect).
# The entrypoint pre-flight (#137) blocks startup when the address THIS node WILL
# advertise -- in ROS precedence order -- resolves to loopback or does not
# resolve. Like the watchdog (#136), it is factored into small PURE functions
# plus a thin impure orchestrator, so sourcing the entrypoint exercises the whole
# decision without a live master (a fake `getent` on PATH stands in for
# resolution, the same trick the fake-`rosnode` tests use):
#
#   _advertised_host       PURE. Echoes the host the node advertises, in rospy /
#                          roscpp precedence: argv `__hostname:=` -> argv
#                          `__ip:=` -> ${ROS_HOSTNAME} -> ${ROS_IP} -> `hostname`.
#   _addr_is_loopback      PURE classifier: localhost / 127.* / ::1 / ::ffff:127.*
#                          -> success (loopback), any other address -> failure.
#   _addr_is_ip_literal    PURE classifier (#141): IPv4 dotted-quad / any IPv6
#                          form -> success (already an address, nothing to look
#                          up), a hostname -> failure. Gates the getent bypass.
#   _advertise_decide      PURE truth table: "" -> UNRESOLVABLE; loopback ->
#                          LOOPBACK; else -> OK (always returns 0, echoes verdict).
#   _advertise_assert_enabled  PURE gate, mirrors _watchdog_enabled: on by default
#                          (ADVERTISE_ASSERT_ENABLED != 0) AND roslaunch AND the
#                          master is remote; ADVERTISE_ASSERT_ENABLED=0 is the
#                          escape hatch for legitimate cross-host DNS deployments.
#   _assert_advertised     orchestrator (no gate inside; main gates it): resolves
#                          the advertised host and returns non-zero with the full
#                          derivation chain + verdict when the verdict is not OK.

@test "_advertised_host prefers a __hostname:= override above all (#137)" {
    # roscpp determineHost checks the __hostname:= argv override before __ip:= and
    # before the ROS_HOSTNAME / ROS_IP env vars, so it wins even when all are set.
    run bash -c 'export ROS_HOSTNAME=envhost ROS_IP=5.6.7.8; source /entrypoint.sh; _advertised_host roslaunch __ip:=1.2.3.4 __hostname:=cli-host pkg foo.launch'
    assert_success
    assert_output "cli-host"
}

@test "_advertised_host prefers __ip:= over ROS_HOSTNAME/ROS_IP (#137)" {
    run bash -c 'export ROS_HOSTNAME=envhost ROS_IP=5.6.7.8; source /entrypoint.sh; _advertised_host roslaunch __ip:=1.2.3.4 pkg foo.launch'
    assert_success
    assert_output "1.2.3.4"
}

@test "_advertised_host prefers ROS_HOSTNAME over ROS_IP (#137)" {
    run bash -c 'export ROS_HOSTNAME=envhost ROS_IP=5.6.7.8; source /entrypoint.sh; _advertised_host roslaunch pkg foo.launch'
    assert_success
    assert_output "envhost"
}

@test "_advertised_host falls back to ROS_IP when only it is set (#137)" {
    run bash -c 'unset ROS_HOSTNAME; export ROS_IP=5.6.7.8; source /entrypoint.sh; _advertised_host roslaunch pkg foo.launch'
    assert_success
    assert_output "5.6.7.8"
}

@test "_advertised_host falls back to hostname when nothing is set (#137)" {
    # Last resort matches rospy get_local_address: with no argv override and no
    # ROS_HOSTNAME / ROS_IP, the advertised host is `hostname` (must be non-empty).
    run bash -c 'unset ROS_HOSTNAME ROS_IP; source /entrypoint.sh; out="$(_advertised_host roslaunch pkg foo.launch)"; [[ -n "${out}" && "${out}" == "$(hostname)" ]]'
    assert_success
}

@test "_addr_is_loopback classifies 127.0.0.1 as loopback (#137)" {
    run bash -c 'source /entrypoint.sh; _addr_is_loopback 127.0.0.1'
    assert_success
}

@test "_addr_is_loopback classifies 127.0.1.1 as loopback (#137)" {
    # /etc/hosts on Debian maps the bare hostname to 127.0.1.1 -- the exact trap
    # this assert exists to catch, so the whole 127.* block must count as loopback.
    run bash -c 'source /entrypoint.sh; _addr_is_loopback 127.0.1.1'
    assert_success
}

@test "_addr_is_loopback classifies ::1 as loopback (#137)" {
    run bash -c 'source /entrypoint.sh; _addr_is_loopback ::1'
    assert_success
}

@test "_addr_is_loopback classifies localhost as loopback (#137)" {
    run bash -c 'source /entrypoint.sh; _addr_is_loopback localhost'
    assert_success
}

@test "_addr_is_loopback rejects a LAN address (#137)" {
    run bash -c 'source /entrypoint.sh; _addr_is_loopback 192.168.1.5'
    assert_failure
}

@test "_advertise_decide maps an empty address to UNRESOLVABLE (#137)" {
    # An empty resolved address means `getent` failed -> UNRESOLVABLE (the decide
    # function always returns 0 and echoes the verdict, like _watchdog_decide).
    run bash -c 'source /entrypoint.sh; _advertise_decide ""'
    assert_success
    assert_output "UNRESOLVABLE"
}

@test "_advertise_decide maps a loopback address to LOOPBACK (#137)" {
    run bash -c 'source /entrypoint.sh; _advertise_decide 127.0.1.1'
    assert_success
    assert_output "LOOPBACK"
}

@test "_advertise_decide maps a LAN address to OK (#137)" {
    run bash -c 'source /entrypoint.sh; _advertise_decide 192.168.1.5'
    assert_success
    assert_output "OK"
}

@test "advertise assert enabled for a remote master + roslaunch by default (#137)" {
    # Default ON (ADVERTISE_ASSERT_ENABLED unset): the gate engages exactly when
    # the watchdog gate would -- remote master + roslaunch (reuses
    # _ros_master_is_remote, so single-machine boots stay byte-identical).
    run bash -c 'export ROS_MASTER_URI=http://192.168.1.5:11311; unset ADVERTISE_ASSERT_ENABLED; source /entrypoint.sh; _advertise_assert_enabled roslaunch pkg foo.launch'
    assert_success
}

@test "advertise assert disabled when ADVERTISE_ASSERT_ENABLED=0 (#137)" {
    # Escape hatch for deployments with real cross-host DNS, where a hostname is a
    # legitimate advertised value that resolves off-box.
    run bash -c 'export ROS_MASTER_URI=http://192.168.1.5:11311 ADVERTISE_ASSERT_ENABLED=0; source /entrypoint.sh; _advertise_assert_enabled roslaunch pkg foo.launch'
    assert_failure
}

@test "advertise assert disabled for a local master (#137)" {
    run bash -c 'export ROS_MASTER_URI=http://localhost:11311; source /entrypoint.sh; _advertise_assert_enabled roslaunch pkg foo.launch'
    assert_failure
}

@test "advertise assert disabled for a non-roslaunch command (#137)" {
    run bash -c 'export ROS_MASTER_URI=http://192.168.1.5:11311; source /entrypoint.sh; _advertise_assert_enabled bash -c "echo hi"'
    assert_failure
}

@test "advertise assert passes when ROS_IP resolves to itself (#137)" {
    # An IP literal resolves to itself. A fake `getent hosts <arg>` echoing the
    # address in the first field stands in for real resolution -> verdict OK ->
    # _assert_advertised returns 0 (no block).
    run bash -c '
      dir="$(mktemp -d)"
      cat >"${dir}/getent" <<EOF
#!/usr/bin/env bash
printf "%s %s\n" "\$2" "\$2"
EOF
      chmod +x "${dir}/getent"
      PATH="${dir}:${PATH}"
      unset ROS_HOSTNAME
      export ROS_IP=192.168.1.5
      source /entrypoint.sh
      _assert_advertised roslaunch pkg foo.launch
    '
    assert_success
}

@test "advertise assert blocks a hostname resolving to loopback (#137)" {
    # ROS_HOSTNAME=rpi with a Debian /etc/hosts maps to 127.0.1.1: the fake getent
    # returns that loopback address -> verdict LOOPBACK -> _assert_advertised
    # returns non-zero and prints the resolved address + verdict for the operator.
    run bash -c '
      dir="$(mktemp -d)"
      cat >"${dir}/getent" <<EOF
#!/usr/bin/env bash
printf "127.0.1.1 %s\n" "\$2"
EOF
      chmod +x "${dir}/getent"
      PATH="${dir}:${PATH}"
      unset ROS_IP
      export ROS_HOSTNAME=rpi
      source /entrypoint.sh
      _assert_advertised roslaunch pkg foo.launch
    '
    assert_failure
    assert_output --partial "127.0.1.1"
    assert_output --partial "LOOPBACK"
}

@test "advertise assert blocks an unresolvable advertised host (#137)" {
    # A host that does not resolve (fake getent exits non-zero) -> empty resolved
    # address -> verdict UNRESOLVABLE -> _assert_advertised returns non-zero.
    run bash -c '
      dir="$(mktemp -d)"
      cat >"${dir}/getent" <<EOF
#!/usr/bin/env bash
exit 2
EOF
      chmod +x "${dir}/getent"
      PATH="${dir}:${PATH}"
      unset ROS_IP
      export ROS_HOSTNAME=nonexistent-host
      source /entrypoint.sh
      _assert_advertised roslaunch pkg foo.launch
    '
    assert_failure
    assert_output --partial "UNRESOLVABLE"
}

# ---------- IP literals never reach getent (regression for #141) ----------
#
# The #137 assert resolved EVERY advertised host with `getent hosts`, on the
# (false) assumption that "an IP literal resolves to itself". Real glibc does a
# REVERSE (PTR) lookup for a numeric argument: `getent hosts 203.0.113.10` exits
# 2 with no output when no PTR record answers, while `getent ahostsv4` on the
# same address exits 0. So a correct, routable numeric ROS_IP was classified
# UNRESOLVABLE and startup was blocked -- non-deterministically, since the
# outcome depended on whether the reverse lookup answered at that moment. The
# old tests missed it because their fake `getent` echoed its argument back and
# always exited 0, encoding the assumption instead of glibc's behaviour. The fix
# short-circuits an IP literal to itself WITHOUT calling getent; only names are
# looked up. The tests below therefore drive the literal path with a fake
# `getent` that ALWAYS FAILS -- they fail against the pre-fix entrypoint.

@test "_addr_is_ip_literal classifies an IPv4 dotted-quad as a literal (#141)" {
    run bash -c 'source /entrypoint.sh; _addr_is_ip_literal 203.0.113.10'
    assert_success
}

@test "_addr_is_ip_literal classifies an IPv6 address as a literal (#141)" {
    # Any colon means IPv6 in some form; no DNS name may contain one.
    run bash -c 'source /entrypoint.sh; _addr_is_ip_literal 2001:db8::5'
    assert_success
}

@test "_addr_is_ip_literal rejects a hostname (#141)" {
    # A name must stay on the getent path, or the Debian bare-hostname ->
    # 127.0.1.1 trap the assert exists to catch would stop being detected.
    run bash -c 'source /entrypoint.sh; _addr_is_ip_literal board.example.com'
    assert_failure
}

@test "_resolve_host_addr returns an IP literal without calling getent (#141)" {
    # The core regression: a fake `getent` that always exits non-zero stands in
    # for the real reverse-lookup failure. The literal must still come back, and
    # the marker file proves getent was never invoked at all.
    run bash -c '
      dir="$(mktemp -d)"
      cat >"${dir}/getent" <<EOF
#!/usr/bin/env bash
touch "${dir}/called"
exit 2
EOF
      chmod +x "${dir}/getent"
      PATH="${dir}:${PATH}"
      source /entrypoint.sh
      addr="$(_resolve_host_addr 203.0.113.10)" || exit 1
      [[ "${addr}" == "203.0.113.10" ]] || exit 1
      [[ ! -e "${dir}/called" ]] || exit 1
    '
    assert_success
}

@test "_resolve_host_addr still resolves a hostname through getent (#141)" {
    # The name path is unchanged: getent IS called and its first field wins.
    run bash -c '
      dir="$(mktemp -d)"
      cat >"${dir}/getent" <<EOF
#!/usr/bin/env bash
printf "198.51.100.7 %s\n" "\$2"
EOF
      chmod +x "${dir}/getent"
      PATH="${dir}:${PATH}"
      source /entrypoint.sh
      _resolve_host_addr board.example.com
    '
    assert_success
    assert_output "198.51.100.7"
}

@test "advertise assert passes for a routable IP literal when getent fails (#141)" {
    # End-to-end regression: the exact field failure -- a correct routable
    # ROS_IP on a host whose address has no PTR record. Pre-fix this printed
    # "resolution: <ip> -> UNRESOLVABLE" and blocked startup; it must now pass.
    run bash -c '
      dir="$(mktemp -d)"
      cat >"${dir}/getent" <<EOF
#!/usr/bin/env bash
exit 2
EOF
      chmod +x "${dir}/getent"
      PATH="${dir}:${PATH}"
      unset ROS_HOSTNAME
      export ROS_IP=203.0.113.10
      source /entrypoint.sh
      _assert_advertised roslaunch pkg foo.launch
    '
    assert_success
}

@test "advertise assert still blocks a loopback IP literal when getent fails (#141)" {
    # The short-circuit only skips the LOOKUP: the literal is still fed to
    # _advertise_decide, so 127.0.1.1 must stay a hard block, not silently pass.
    run bash -c '
      dir="$(mktemp -d)"
      cat >"${dir}/getent" <<EOF
#!/usr/bin/env bash
exit 2
EOF
      chmod +x "${dir}/getent"
      PATH="${dir}:${PATH}"
      unset ROS_HOSTNAME
      export ROS_IP=127.0.1.1
      source /entrypoint.sh
      _assert_advertised roslaunch pkg foo.launch
    '
    assert_failure
    assert_output --partial "127.0.1.1"
    assert_output --partial "LOOPBACK"
}

# -------------------- RealSense packages (source-built, #88) --------------------
# The apt ros-${ROS_DISTRO}-realsense2-* packages were removed; librealsense
# v2.55.1 (SDK) + the ros1-legacy realsense-ros 2.3.2 wrapper are built from
# source (devel). The wrapper real-installs into /opt/ros/${ROS_DISTRO}; the
# ROS-agnostic SDK installs into /usr/local. Assert the wrapper is on
# ROS_PACKAGE_PATH and the SDK library landed in /usr/local.

@test "realsense2_camera discoverable via rospack" {
    run bash -c "source /opt/ros/${ROS_DISTRO}/setup.bash && rospack find realsense2_camera"
    assert_success
}

@test "realsense2_description discoverable via rospack" {
    # realsense2_description is bundled in the realsense-ros repo, so the source
    # build (#88) copies its share/ payload into the ROS prefix too; the wrapper
    # launch (rs_aligned_depth.launch) loads the URDF from it.
    run bash -c "source /opt/ros/${ROS_DISTRO}/setup.bash && rospack find realsense2_description"
    assert_success
}

@test "librealsense2 SDK library present" {
    run bash -c "ls /usr/local/lib/librealsense2.so*"
    assert_success
}

# -------------------- Desktop GUI (devel) --------------------

@test "rqt_image_view is available (devel GUI; backs the README demo)" {
    # devel-base installs ros-${ROS_DISTRO}-desktop, which ships rqt_image_view.
    # The README RGB-D demo tells users to `rosrun rqt_image_view rqt_image_view`
    # from the devel image, so guard that the package is actually present.
    run dpkg -l ros-${ROS_DISTRO}-rqt-image-view
    assert_success
}

# -------------------- Base tools --------------------

@test "git is available" {
    run git --version
    assert_success
}

@test "vim is available" {
    run vim --version
    assert_success
}

@test "sudo is available" {
    run sudo --version
    assert_success
}

@test "sudo passwordless works" {
    run sudo true
    assert_success
}

# -------------------- System --------------------

@test "User is not root" {
    assert [ "$(id -u)" -ne 0 ]
}

@test "HOME is set and exists" {
    assert [ -n "${HOME}" ]
    assert [ -d "${HOME}" ]
}

@test "container user matches the configured USER_NAME (base v0.41.0 build contract)" {
    # Regression guard: the Dockerfile must consume the USER_NAME / USER_UID /
    # USER_GROUP / USER_GID build-args that base v0.41.0's compose + CI inject.
    # If it falls back to the legacy default user, the container HOME diverges
    # from compose's /home/${USER_NAME}/work mount and `just run` breaks.
    # CONTAINER_EXPECTED_USER is set by the devel-test stage.
    assert [ -n "${CONTAINER_EXPECTED_USER}" ]
    assert_equal "$(id -un)" "${CONTAINER_EXPECTED_USER}"
}

@test "HOME path matches the container user" {
    assert_equal "${HOME}" "/home/$(id -un)"
}

@test "Timezone is Asia/Taipei" {
    run cat /etc/timezone
    assert_output "Asia/Taipei"
}

@test "LANG is en_US.UTF-8" {
    assert_equal "${LANG}" "en_US.UTF-8"
}

@test "LC_ALL is en_US.UTF-8" {
    assert_equal "${LC_ALL}" "en_US.UTF-8"
}

@test "entrypoint.sh exists and executable" {
    assert [ -x "/entrypoint.sh" ]
}

@test "RealSense udev rules exist" {
    assert [ -f "/etc/udev/rules.d/99-realsense-libusb.rules" ]
}

@test "Work directory exists" {
    assert [ -d "${HOME}/work" ]
}
