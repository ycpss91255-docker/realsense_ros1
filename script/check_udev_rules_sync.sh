#!/usr/bin/env bash
#
# Guard: the vendored RealSense udev rules must not drift below the pinned
# librealsense SDK tag.
#
# config/realsense/udev/99-realsense-libusb.rules is a vendored copy of the SDK's
# own config/99-realsense-libusb.rules. It is needed on the *host* (outside
# Docker, where there is no udevd) so the container user can open the raw USB
# node -- see script/install_udev_rules.sh. This repo is frozen at librealsense
# v2.55.1 (issue #88), so the vendored file must contain every device rule the
# pinned tag ships. It MAY carry extra local device lines and a header comment;
# those are tolerated. What is flagged is an upstream rule the vendored file is
# MISSING (drift below the pinned SDK) -- e.g. after a version bump.
#
# Compares only the `SUBSYSTEMS==` rule lines (comments / blank lines / ordering
# are ignored). Network-optional: if the upstream file cannot be fetched (no
# network), it prints a skip notice and exits 0 so offline lint/CI does not hard
# fail. A CI job can invoke this non-blocking.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly RULES_LOCAL="${SCRIPT_DIR}/../config/realsense/udev/99-realsense-libusb.rules"
readonly DEFAULT_LIBREALSENSE_VERSION="v2.55.1"

usage() {
  cat >&2 <<'EOF'
Usage: check_udev_rules_sync.sh [-h|--help] [VERSION]

Verify that config/realsense/udev/99-realsense-libusb.rules contains every device
rule shipped by the pinned librealsense SDK tag's config/99-realsense-libusb.rules.

VERSION is the librealsense git tag to compare against (e.g. v2.55.1). It may
also be supplied via the LIBREALSENSE_VERSION environment variable; the CLI
argument wins. Defaults to the repo's pinned tag.

Exit status:
  0  All upstream rules are present (or the fetch was skipped: no network).
  1  The vendored file is missing one or more upstream rules (drift), or a
     local error occurred.

Options:
  -h, --help   Show this help and exit.
EOF
}

# Prints the sorted, unique `SUBSYSTEMS==` rule lines of the given file.
extract_rules() {
  local file="${1}"
  grep '^SUBSYSTEMS==' "${file}" | sort -u
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      return 0
      ;;
  esac

  local version="${1:-${LIBREALSENSE_VERSION:-${DEFAULT_LIBREALSENSE_VERSION}}}"
  readonly version

  if [[ ! -f "${RULES_LOCAL}" ]]; then
    echo "check_udev_rules_sync.sh: vendored rules not found: ${RULES_LOCAL}" >&2
    return 1
  fi

  local url
  url="https://raw.githubusercontent.com/IntelRealSense/librealsense/${version}/config/99-realsense-libusb.rules"

  local upstream
  upstream="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${upstream}'" EXIT

  if ! curl -fsSL "${url}" -o "${upstream}" 2>/dev/null; then
    echo "check_udev_rules_sync.sh: could not fetch ${url} (offline?) -- skipping." >&2
    return 0
  fi

  local missing
  missing="$(comm -23 \
    <(extract_rules "${upstream}") \
    <(extract_rules "${RULES_LOCAL}"))"

  if [[ -n "${missing}" ]]; then
    echo "check_udev_rules_sync.sh: udev rules drift vs pinned SDK tag ${version}." >&2
    echo "The vendored ${RULES_LOCAL} is missing these upstream rules:" >&2
    echo "${missing}" >&2
    echo "Re-sync from ${url} and re-run this check." >&2
    return 1
  fi

  echo "check_udev_rules_sync.sh: OK -- vendored rules cover librealsense ${version}."
  return 0
}

main "${@}"
