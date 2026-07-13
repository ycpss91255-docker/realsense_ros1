#!/usr/bin/env bats

setup() {
    load "${BATS_TEST_DIRNAME}/test_helper"
}

# -------------------- install_udev_rules.sh --------------------
# The repo's host-side udev-rules installer. ShellCheck runs over it via the
# lint stage; here we only assert its --help contract (no privileged steps,
# which would need a host udevd unavailable in the build sandbox).

@test "install_udev_rules.sh -h exits 0" {
    run bash /lint/install_udev_rules.sh -h
    assert_success
}

@test "install_udev_rules.sh --help exits 0" {
    run bash /lint/install_udev_rules.sh --help
    assert_success
}

@test "install_udev_rules.sh -h prints usage" {
    run bash /lint/install_udev_rules.sh -h
    assert_line --partial "Usage:"
}

# Regression: the README documents `./script/install_udev_rules.sh` (direct
# execution), so the file must carry the executable bit. It shipped as 0644
# once, which made the documented command fail with "Permission denied" on a
# fresh clone. COPY preserves the source mode, so a 0644 regression surfaces
# here.
@test "install_udev_rules.sh is executable" {
    [ -x /lint/install_udev_rules.sh ]
}

@test "install_udev_rules.sh rejects an unknown argument (non-zero + usage)" {
    run bash /lint/install_udev_rules.sh --bogus
    assert_failure
    assert_output --partial "Usage:"
}

@test "install_udev_rules.sh fails when the rules file is absent" {
    # /lint/ has no sibling config/realsense/udev tree, so RULES_SRC resolves
    # to an absent path and main() must exit 1 with a clear message before any
    # privileged step.
    run bash /lint/install_udev_rules.sh
    assert_failure
    assert_output --partial "not found"
}

# -------------------- check_udev_rules_sync.sh --------------------
# The udev-rules drift guard (#88): flags the vendored rules missing a device
# the pinned librealsense SDK tag ships. Only the --help contract is exercised
# here; the network diff is offline-skipped and not run in bats.

@test "check_udev_rules_sync.sh -h exits 0" {
    run bash /lint/check_udev_rules_sync.sh -h
    assert_success
}

@test "check_udev_rules_sync.sh --help exits 0" {
    run bash /lint/check_udev_rules_sync.sh --help
    assert_success
}

@test "check_udev_rules_sync.sh -h prints usage" {
    run bash /lint/check_udev_rules_sync.sh -h
    assert_line --partial "Usage:"
}

@test "check_udev_rules_sync.sh is executable" {
    [ -x /lint/check_udev_rules_sync.sh ]
}

# Drift-logic exercised in a sandbox: a copy of the script beside a fixture
# vendored rules file, with `curl` shadowed by a PATH stub that emits a fixture
# "upstream" file (honouring the script's `-o <file>`) or fails (offline). This
# runs the real comm-based diff without touching the network.
_sync_sandbox() {
    local vendored="$1"
    SANDBOX="${BATS_TEST_TMPDIR}/sync"
    mkdir -p "${SANDBOX}/script" \
        "${SANDBOX}/config/realsense/udev" \
        "${SANDBOX}/bin"
    cp /lint/check_udev_rules_sync.sh "${SANDBOX}/script/check_udev_rules_sync.sh"
    printf '%s\n' "${vendored}" \
        > "${SANDBOX}/config/realsense/udev/99-realsense-libusb.rules"
    cat > "${SANDBOX}/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Minimal curl stub: honour `-o <file>` and emit ${CURL_STUB_FIXTURE}; exit
# non-zero when CURL_STUB_FAIL=1 to simulate an offline fetch.
out=""
prev=""
for a in "$@"; do
  [[ "${prev}" == "-o" ]] && out="${a}"
  prev="${a}"
done
[[ "${CURL_STUB_FAIL:-0}" == "1" ]] && exit 7
cat "${CURL_STUB_FIXTURE}" > "${out}"
STUB
    chmod +x "${SANDBOX}/bin/curl"
}

@test "check_udev_rules_sync.sh flags drift when upstream ships a rule the vendored file lacks" {
    _sync_sandbox 'SUBSYSTEMS=="usb", ATTRS{idProduct}=="0aa5"
SUBSYSTEMS=="usb", ATTRS{idProduct}=="0b07"'
    local upstream="${BATS_TEST_TMPDIR}/upstream.rules"
    printf '%s\n' \
        'SUBSYSTEMS=="usb", ATTRS{idProduct}=="0aa5"' \
        'SUBSYSTEMS=="usb", ATTRS{idProduct}=="0b07"' \
        'SUBSYSTEMS=="usb", ATTRS{idProduct}=="0b3a"' > "${upstream}"
    run env PATH="${SANDBOX}/bin:${PATH}" CURL_STUB_FIXTURE="${upstream}" \
        bash "${SANDBOX}/script/check_udev_rules_sync.sh"
    assert_failure
    assert_output --partial "drift"
}

@test "check_udev_rules_sync.sh passes when the vendored file covers upstream" {
    _sync_sandbox 'SUBSYSTEMS=="usb", ATTRS{idProduct}=="0aa5"
SUBSYSTEMS=="usb", ATTRS{idProduct}=="0b07"
SUBSYSTEMS=="usb", ATTRS{idProduct}=="0b3a"'
    local upstream="${BATS_TEST_TMPDIR}/upstream.rules"
    printf '%s\n' \
        'SUBSYSTEMS=="usb", ATTRS{idProduct}=="0aa5"' \
        'SUBSYSTEMS=="usb", ATTRS{idProduct}=="0b07"' > "${upstream}"
    run env PATH="${SANDBOX}/bin:${PATH}" CURL_STUB_FIXTURE="${upstream}" \
        bash "${SANDBOX}/script/check_udev_rules_sync.sh"
    assert_success
    assert_output --partial "OK"
}

@test "check_udev_rules_sync.sh skips (exit 0) when the fetch fails offline" {
    _sync_sandbox 'SUBSYSTEMS=="usb", ATTRS{idProduct}=="0aa5"'
    run env PATH="${SANDBOX}/bin:${PATH}" CURL_STUB_FAIL=1 \
        bash "${SANDBOX}/script/check_udev_rules_sync.sh"
    assert_success
    assert_output --partial "skip"
}
