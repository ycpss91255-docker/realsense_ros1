#!/usr/bin/env bash
#
# Install the Intel RealSense udev rules onto the *host*.
#
# librealsense needs these rules on the host, not just inside the container:
# the container has no udevd, and a device node's permissions live on the host
# devtmpfs inode that the container shares through the /dev bind mount. Without
# them the non-root container user cannot open the raw USB node, so the SDK
# misdetects the camera (reports USB 2.0, "Product Line not supported", or fails
# firmware updates). See IntelRealSense/librealsense#12022.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly RULES_SRC="${SCRIPT_DIR}/../config/realsense/official/99-realsense-libusb.rules"
readonly RULES_DST="/etc/udev/rules.d/99-realsense-libusb.rules"

usage() {
  cat >&2 <<'EOF'
Usage: install_udev_rules.sh [-h|--help]

Install the Intel RealSense udev rules onto the host so the camera enumerates
with the permissions the container needs.

Copies config/realsense/official/99-realsense-libusb.rules to /etc/udev/rules.d/ and
runs `udevadm control --reload-rules && udevadm trigger`. Privileged steps use
sudo when the script is not run as root.

Options:
  -h, --help   Show this help and exit.
EOF
}

# Runs the given command as root: directly when already root, via sudo
# otherwise. Fails when neither is possible.
run_privileged() {
  if [[ "${EUID}" -eq 0 ]]; then
    "${@}"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "${@}"
  else
    echo "install_udev_rules.sh: must run as root or have sudo installed" >&2
    return 1
  fi
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      return 0
      ;;
    "") ;;
    *)
      echo "install_udev_rules.sh: unknown argument '${1}'" >&2
      usage
      return 1
      ;;
  esac

  if [[ ! -f "${RULES_SRC}" ]]; then
    echo "install_udev_rules.sh: rules file not found: ${RULES_SRC}" >&2
    return 1
  fi

  echo "Installing ${RULES_DST} ..."
  run_privileged install -m 0644 "${RULES_SRC}" "${RULES_DST}"

  echo "Reloading udev rules ..."
  run_privileged udevadm control --reload-rules
  run_privileged udevadm trigger

  echo "Done. Re-plug the RealSense camera if it is already connected."
}

main "${@}"
