#!/usr/bin/env bash
#
# pre-build hook (base #440): host-side, runs before build.sh main logic.
# Receives the same "$@" as build.sh. Non-zero exit aborts the wrapper.
# Skipped when ./build.sh runs with --dry-run.
#
# Purpose: mirror build.sh's `test-tools:local` auto-build for the librealsense
# SDK. The main Dockerfile FROMs `${LIBREALSENSE_IMAGE}` (default
# `librealsense:local`) and COPYs the prebuilt librealsense trees out of it. In
# CI, main.yaml passes LIBREALSENSE_IMAGE=ghcr.io/.../librealsense:v2.55.1-focal
# so buildx PULLS the prebuilt SDK. For a LOCAL `just build` / `./build.sh`
# (LIBREALSENSE_IMAGE unset) there is no such image, so this hook builds it from
# docker/Dockerfile.librealsense first -> the local build is self-contained and
# needs no GHCR access.
#
# Contract:
#   - LIBREALSENSE_IMAGE already set (caller/CI provides it) -> no-op, exit 0.
#   - otherwise -> docker build -t librealsense:local from the SDK Dockerfile.
#
# UBUNTU_CODENAME / LIBREALSENSE_VERSION default to the main Dockerfile's pins
# (this repo is TERMINAL at focal / v2.55.1) and are env-overridable. The SDK is
# keyed on the Ubuntu codename, not the ROS distro: librealsense2 is ROS-agnostic
# and its .so is ABI-bound to the Ubuntu release.

set -euo pipefail

main() {
  # If the caller/CI already provides the SDK image, do nothing.
  if [[ -n "${LIBREALSENSE_IMAGE:-}" ]]; then
    return 0
  fi

  # Resolve the repo root from this hook's own location (script/hooks/pre/),
  # so the docker build works from any CWD.
  local hook_dir repo_root sdk_context sdk_dockerfile
  hook_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  repo_root="$(cd -- "${hook_dir}/../../.." && pwd -P)"
  sdk_context="${repo_root}/docker"
  sdk_dockerfile="${sdk_context}/Dockerfile.librealsense"

  # Pins default to the main Dockerfile's global ARGs; env-overridable.
  local ubuntu_codename="${UBUNTU_CODENAME:-focal}"
  local librealsense_version="${LIBREALSENSE_VERSION:-v2.55.1}"

  if [[ ! -f "${sdk_dockerfile}" ]]; then
    printf '[pre-build] ERROR: SDK Dockerfile not found: %s\n' \
      "${sdk_dockerfile}" >&2
    return 1
  fi

  printf '[pre-build] building librealsense:local (UBUNTU_CODENAME=%s, LIBREALSENSE_VERSION=%s)\n' \
    "${ubuntu_codename}" "${librealsense_version}" >&2

  docker build \
    -t librealsense:local \
    --build-arg "UBUNTU_CODENAME=${ubuntu_codename}" \
    --build-arg "LIBREALSENSE_VERSION=${librealsense_version}" \
    -f "${sdk_dockerfile}" \
    "${sdk_context}"
}

main "$@"
