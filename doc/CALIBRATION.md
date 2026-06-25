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

## Official references

- Calibration overview (tool, printable target, and guide downloads):
  <https://dev.realsenseai.com/docs/calibration/>
- Dynamic Calibration Tool download (Windows / Ubuntu packages):
  <https://www.intel.com/content/www/us/en/download/645988/29618/intel-realsense-d400-series-dynamic-calibration-tool.html>
- User Guide (PDF):
  <https://cdrdv2-public.intel.com/840579/RealSense_D400_Dyn_Calib_User_Guide.pdf>
- Programmer's Guide (PDF):
  <https://cdrdv2-public.intel.com/840422/RealSense_D400_Dyn_Calib_Programmer.pdf>
