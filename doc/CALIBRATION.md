# RealSense Dynamic Calibration Tool

This page describes the **Intel RealSense D400 Series Dynamic Calibration Tool**
(`librscalibrationtool`): what it does, how it differs from the on-chip
calibration in `CAMERA.md`, and how to run it.

> **Availability note (ROS 1 / focal):** the tool is **not currently bundled in
> this repo's `devel` image.** The ROS 2 sibling (`realsense_ros2`) bundles it
> from Intel's `pool/jammy` `.deb`, but that package is **amd64-only and tied to
> the Ubuntu release**, and this repo's base is **Ubuntu 20.04 focal** (ROS 1
> Noetic). Bundling a focal-compatible build is deferred to a follow-up. Until
> then, run the tool on the host (or in a focal container with it installed
> manually). The workflow below still applies once the tool is available.

## What it is (and how it differs from on-chip calibration)

There are two distinct calibration paths for a D400 camera:

| | On-chip calibration | Dynamic Calibration Tool |
|---|---|---|
| Covered in | [CAMERA.md](CAMERA.md) (section 5) | this page |
| Runs from | `realsense-viewer` (built in) | `Intel.Realsense.DynamicCalibrator` |
| Target needed | No -- any textured scene | Yes -- a printed (or phone-app) target |
| Calibrates | Depth rectification only (stereo IR) | Rectification + depth scale, **plus the RGB extrinsics** on RGB devices |
| Use when | Depth noise / non-flat planes | A thorough, target-based re-calibration is needed |

Dynamic calibration optimizes **extrinsic** parameters only -- the rotation and
translation between the imagers -- not intrinsics (focal length, principal point,
and distortion stay as factory-calibrated). Per the User Guide (v2.11) it offers
two calibration types in two operating modes (targeted and target-less); the
`Intel.Realsense.DynamicCalibrator` GUI/CLI runs **targeted** calibration:

- **Rectification calibration** -- re-aligns the epipolar geometry of the two IR
  imagers (`RotationLeftRight` / `TranslationLeftRight`); the same goal as on-chip
  calibration, but target-based.
- **Depth scale calibration** -- corrects the absolute depth scale when the
  optical elements have shifted.

Depth<->RGB on the D455: targeted calibration **also re-calibrates the RGB
extrinsics** (`RotationLeftRGB` / `TranslationLeftRGB` -- the color sensor relative
to the left imager) on devices that have an RGB sensor (D415/D435/D455). That is
exactly the depth-to-color relationship that runtime alignment relies on
(`align_depth:=true` in `realsense2_camera`, or `rs2::align` in the SDK), so
re-running it fixes a misaligned depth<->color overlay. Target-less mode calibrates
the depth (left/right) only and **not** RGB, and is API-only -- the GUI calibrator
does not offer it.

## What the tool provides

Intel ships the tool as a precompiled **amd64-only** package (no ARM64 build).
The package provides these executables:

| Executable | Purpose |
|---|---|
| `Intel.Realsense.DynamicCalibrator` | Targeted dynamic calibration (rectification + depth scale + RGB extrinsics), GUI and CLI |
| `Intel.Realsense.CustomRW` | Read / write the calibration tables stored on the camera |
| `opencv_interactive-calibration` | OpenCV interactive calibration helper |

## Prerequisites

1. **Host udev rules.** The tool needs raw USB access to the camera, the same
   permission requirement as the rest of the SDK. Install them once on the host:

   ```bash
   ./script/install_udev_rules.sh
   ```

   See the "RealSense udev Rules" section in the README for why this must be on
   the host, not just inside the container.

2. **A calibration target.** Either print the official target at the documented
   scale (link below), or display it via the Intel RealSense Dynamic Target phone
   app (iOS / Android).

3. **GUI access.** A display with the X11/Qt/OpenGL stack so the calibrator window
   can open (the `devel` image already includes this and runs in GUI mode).

## Running it

```bash
# Once the tool is available on PATH (see the availability note above):
Intel.Realsense.DynamicCalibrator     # interactive GUI calibration
```

Position the device **600--850 mm** from the target with the target's bars roughly
vertical in the field of view; relative movement between camera and target is
needed throughout (fix one, move the other). Avoid reflections (sunlight, bright
lighting, phone-screen glare) -- they keep the target from being detected. The
targeted flow then runs these phases in sequence (User Guide section 4.5.4 and
Appendix B):

1. **Rectification phase** -- a block of shaded **blue squares** is overlaid on the
   middle of the live view. Each blue square marks a region of the field of view
   that still needs target coverage. Move the camera (or target) slowly so the
   target's black/white squares and bars overlap the blue squares; covered squares
   **clear** one by one. Repeat until all are cleared. (If auto-exposure search is
   on and the target is briefly lost, the image cycles bright<->dark while it
   searches -- this is expected; if it never detects, reposition to fix reflection
   or distance.) The intermediate result is applied to the stream immediately.
2. **Scale phase** -- starts automatically; keep repositioning the target to
   different, distinct locations until **15** target images are accepted (a green
   progress bar fills to completion).
3. **RGB phase** (RGB devices only -- D415/D435/D455) -- like the scale phase, it
   captures 15 target images and calibrates the depth-to-RGB UV mapping. After it,
   both left/right depth and depth<->RGB are calibrated.

When done, the result is written to the camera. Use `Intel.Realsense.CustomRW` to
back up or restore the calibration tables before/after, and verify depth quality
afterwards (re-run if not satisfactory).

## Known limitation: residual depth<->color alignment error

Even after a successful calibration, the depth-to-color overlay (`align`) still has
some residual error -- most visible near object edges. Verified on hardware: it is
**clearly noticeable on the D455 at ~1--2 m**, and **slightly present on the D435**.
This is largely **expected and geometric**, not a sign the calibration failed.
Calibration removes the systematic extrinsic offset; it cannot remove:

- **Parallax / occlusion** -- depth (left IR) and RGB are different optical centres,
  so at an object boundary one camera sees what the other cannot. That region
  cannot be aligned by any calibration -- it is pure geometry, and it is the main
  cause of the edge "fringing".
- **Depth error** -- stereo depth error grows roughly with distance squared, so at
  1--2 m the deprojection into the colour image is less accurate (worse on noisy
  edges and holes).
- **RGB rolling shutter / sync** -- the colour sensor is rolling-shutter; with
  camera or scene motion it shifts relative to the (global) depth frame.

Why the D455 is worse than the D435: the **D455 has a 95 mm stereo baseline vs the
D435's 50 mm**. A wider baseline gives better long-range depth but a larger
depth<->RGB parallax, so the residual is more visible at near/mid range.

What still helps (it will not reach zero):

- Choose whether to align depth->color or color->depth depending on the use case.
- Apply depth post-processing (spatial / temporal / hole-filling) *before* aligning.
- Keep depth/colour synced and shoot static scenes to avoid rolling-shutter shift.
- Stay within the camera's optimal depth range so depth is as accurate as possible.

### Alignment direction: depth->color vs color->depth

The two directions are **not symmetric** -- they are different algorithms, which is
why the choice above matters (per Intel's *Projection, Texture-Mapping and
Occlusion* whitepaper, section 3.4):

- **Color->depth** (align color into the depth frame) is the cheap direction: for
  each depth pixel, look up its uv-map coordinate and fetch the color there. Output
  is at depth resolution, one lookup per pixel -- no holes.
- **Depth->color** (align depth into the color frame -- what `align_depth:=true` /
  `rs_aligned_depth.launch` produces) is "a bit trickier": a color pixel cannot be
  easily de-projected back to 3D, so instead every depth pixel is
  **forward-projected** into color coordinates, keeping the nearest depth when
  several land on the same color pixel (z-buffering). If the color sensor is
  higher-resolution than depth, some color pixels get no depth -> holes, which the
  SDK papers over by splatting each depth pixel to a 2x2 patch.

So the shipped default (`depth->color`) is the harder, approximation-prone
direction -- the forward-projection + 2x2 hole-fill is part of why the residual is
most visible as edge fringing. An application that can consume depth-resolution
output avoids that class of artifact by choosing `color->depth`.

## What the official documentation quantifies (and what it does not)

Intel does **not** publish a depth<->color *alignment* error vs distance table. The
closest official numbers are:

- **Depth Z-accuracy (absolute error): +/-2%** -- D400-Series Datasheet
  (337029-017) Table 4-15 "Depth Quality Specification", alongside Fill Rate >=99%,
  RMS Error <=2%, Temporal Noise <=1%. The measurement distance differs by model:
  the D43x spec is stated "<=2 m, 80% ROI, HD", the D450/D455 spec "<=4 m, 80% ROI,
  HD". **This is a depth-accuracy spec, not an alignment-error spec** -- it bounds
  how wrong the Z value is, which only *indirectly* feeds the deprojection into
  color. There is no per-distance (1 m / 2 m / 3 m) breakdown.
- **The alignment algorithm and its error sources** are described *qualitatively* in
  the *Projection, Texture-Mapping and Occlusion* whitepaper: section 3.4 (stream
  alignment -- the two directions above) and section 4 (occlusion invalidation --
  at object boundaries one imager sees what the other cannot; SDK 2.35+
  auto-invalidates these occluded regions during point-cloud calculation). It
  explains *why* edge error exists but gives no measured magnitudes.

Conclusion: the "1 m / 2 m / 3 m residual" numbers are **not available from Intel**
-- they have to be measured in-house (see below).

## Planned quantification experiment (deferred)

Goal: turn the qualitative "worse on the D455 at 1--2 m" observation into a
distance-vs-error table (error at 1 m / 2 m / 3 m).

**Deferred (2026-07-03).** A trustworthy measurement needs a **stable, controlled
setup**, and the only D455 currently available is mounted on a live AMR (running
navigation stack) with an uncontrolled camera pose -- a production node, not a
measurement rig. Run this once a dedicated, static setup is available.

Design:

- **Metric (primary): edge-offset.** Aim the camera at an object with a known
  straight edge (a flat board, or a checkerboard). Measure the pixel offset between
  the **depth edge** and the **color edge** in the aligned frame; convert to mm via
  the depth Z and camera intrinsics. Matches the originally-observed edge fringing
  and reads directly as "at 1 m the edge is off by X px / Y mm".
- **Metric (optional, more rigorous): checkerboard reprojection.** Detect
  checkerboard corners in color vs the corners deprojected from depth; report the
  reprojection error (px / mm). Use if the numbers need to be defensible (report /
  external).
- **Alignment direction:** measure **depth->color** (`align_depth:=true`, the
  shipped default) so the numbers correspond to what ships; optionally also
  `color->depth` for comparison.
- **Capture:** at each of 1 / 2 / 3 m (measured to the camera cover glass -- the
  Ground-Zero reference, datasheet 4.8) record synchronized aligned depth+color,
  static scene, camera off the robot. Apply depth post-processing (spatial /
  temporal / hole-fill) *before* aligning, as in production.
- **Controls:** run both D455 and D435 to reproduce the baseline-driven difference
  (95 mm vs 50 mm). Target well-lit, no reflections, roughly filling the ROI.
- **Output:** a distance-vs-error table + overlay screenshots, appended here.

Prerequisite: the running container must actually publish
`/camera/aligned_depth_to_color/image_raw`. A runtime image built before 2026-07-03
defaults to the non-aligned `rs_camera.launch`; rebuild to pick up the new aligned
default, or launch the alignment explicitly for the capture.

## Official references

- Calibration overview (tool, printable target, and guide downloads):
  <https://dev.realsenseai.com/docs/calibration/>
- Dynamic Calibration Tool download (Windows / Ubuntu packages):
  <https://www.intel.com/content/www/us/en/download/645988/29618/intel-realsense-d400-series-dynamic-calibration-tool.html>
- User Guide (PDF):
  <https://cdrdv2-public.intel.com/840579/RealSense_D400_Dyn_Calib_User_Guide.pdf>
- Programmer's Guide (PDF):
  <https://cdrdv2-public.intel.com/840422/RealSense_D400_Dyn_Calib_Programmer.pdf>
