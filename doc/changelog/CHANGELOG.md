**[English](CHANGELOG.md)** | **[繁體中文](CHANGELOG.zh-TW.md)** | **[简体中文](CHANGELOG.zh-CN.md)** | **[日本語](CHANGELOG.ja.md)**

# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- revert display mount to XDG_RUNTIME_DIR:rw
- use tmpfs for XDG_RUNTIME_DIR + Wayland socket mount
- Restore `.env.example` (removed during APT-mirror refactor) so `setup.sh`'s IMAGE_NAME detection has its documented fallback. Without this, any checkout under a non-`docker_*` / non-`*_ws` directory name falls through to `IMAGE_NAME=unknown`.

### Changed
- Align README.md to template framework: move H1 above the language switch link, add CI status badge, promote TL;DR blockquote to `## TL;DR` H2, add `## Overview` section, extend Table of Contents. Translations untouched.

## [v2.0.0] - 2026-03-28

### Added
- migrate from docker_setup_helper to template
- add Wayland display support for X11/Wayland dual compatibility

### Changed
- remove docker_setup_helper subtree and local CI workflows
- add docker_setup_helper subtree
- Squashed 'docker_setup_helper/' content from commit 0141a19
- upgrade to full env-level architecture

### Fixed
- add missing backslash in Dockerfile RUN continuation

## [v1.0.0] - 2026-03-25

### Added
- initial realsense_noetic repo

