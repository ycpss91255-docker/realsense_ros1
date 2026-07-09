# Deployment-overridable camera launch (topic remap et al.)

- **Date:** 2026-07-09
- **Status:** Accepted

## Context

Downstream integrations need to customise the camera launch per deployment --
first case: rename the realsense output topics (`/camera/color/image_raw` ->
`/camera_image_raw`, aligned depth -> `/camera_depth_image_raw`) for a consumer
that subscribes the old IDS-camera names. This will recur and grow (more remaps,
extra filter nodes, param tweaks), so it needs a first-class mechanism, not a
one-off hand-edit of the baked launch.

Hard ROS 1 facts that constrain the design (verified empirically in-container
with `roslaunch --args`, not just from docs):

- `roslaunch` has **no CLI topic remap** and realsense-ros 2.3.2 exposes **no
  topic-rename arg** -- a topic remap can only be a launch-file `<remap>`.
- A `<remap>` only propagates **downward** into `<include>`s that follow it in
  the same scope. A `<remap>` inside an included file does **not** reach the
  parent's sibling includes. So the file that declares the remap must be the one
  that (transitively, before) includes the realsense launch.
- Therefore the remap-owning file is inherently the *operative* launch the
  entrypoint runs. To change it per deployment without an image rebuild, the
  deployment must override that operative file.

## Decision

A three-layer launch under `config/realsense/launch/`, baked to `/`:

```
official rs_aligned_depth.launch
  ^ include
/rs_camera_config.launch   "our config": include official + config_file + initial_reset. Immutable in the image.
  ^ include
/rs_camera.launch          entrypoint target: includes our config, no remap (default). Deployment overrides this.
```

- The runtime CMD runs `roslaunch /rs_camera.launch initial_reset:=true`.
- A deployment copies `rs_camera_remap.example.launch`, edits the two
  `<remap>` lines, and **bind-mounts** its copy over `/rs_camera.launch` (via
  `config/docker/setup.conf [volumes]`). Its override `<include>`s the immutable
  `/rs_camera_config.launch`, so it never duplicates the bringup logic.
- **No env var / `.env`.** `.env` is reserved for environment parameters
  (`ROS_MASTER_URI`, versions), not application/launch config.
- **No fallback.** A malformed override fails loudly at `roslaunch` (relaunch
  loop, visible in the container log). A silent fallback to the stock launch
  would let a broken customisation look "normal".
- The shipped `example` template is validated well-formed in CI (`xmllint`, see
  `test/smoke/camera_config.bats`). A deployment's own edited copy is its
  responsibility (`xmllint` it before mounting).

## Alternatives rejected

- **`.env` value passthrough (`RS_LAUNCH_ARGS` -> roslaunch args, our config
  keeps arg-driven `<remap>` with no-op default).** Fail-safe, entrypoint runs
  our stable config. Rejected because it puts app config in `.env` (against our
  `.env` convention) and only covers args the wrapper pre-declares -- it does
  not scale to arbitrary future launch customisation (extra nodes, other
  remaps), which the launch-override does for free.
- **Our config includes a user remap fragment.** Does not work: ROS 1 remap
  scoping (above) means the fragment's remaps never reach the realsense node.
- **Duplicate the whole wrapper in the deployment file (override at the same
  path as our config).** Drifts when our config changes; the include-layer
  avoids it.

## Consequences

- Extensible: a deployment's `/rs_camera.launch` can do anything ROS launch
  allows, with zero repo changes.
- No drift: the override includes our immutable config; bringup logic has one
  source.
- Default (no override) behaviour is unchanged for every deployment.
- The deployment's override file is not covered by CI (it is not in the image);
  a broken override takes that deployment's camera down by design (fail loud).
  Mitigation: the override is tiny (remap + one include) and the shipped
  template is CI-validated.
