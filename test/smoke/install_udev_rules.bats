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
