**[English](CAMERA.md)** | **[繁體中文](CAMERA.zh-TW.md)** | **[简体中文](CAMERA.zh-CN.md)** | **[日本語](CAMERA.ja.md)**

# 用实体 RealSense 相机测试

`TEST.md` 涵盖构建时自动执行的 smoke test。本页是通过容器验证真实 Intel RealSense
相机的手动流程。

容器以 `privileged` 运行并挂载 `/dev`，因此它能看到 host 上的 USB 设备。`devel` 镜像
搭载 ROS 1 wrapper（`realsense2_camera`）以及从源码构建的 librealsense SDK CLI 工具
（`rs-enumerate-devices`、`realsense-viewer`、`rs-*`）。（`runtime` 镜像只含 node -- 
它带有 wrapper 与 SDK 库，但不含这些 CLI 工具。）

## 0. 确认 host 能看到相机

```bash
lsusb | grep -i intel    # e.g. Intel RealSense (8086:0b07)
```

若什么都没显示：请使用支持数据传输的线材，优先选用 USB 3.0 端口，并确保没有其他进程
占用相机。

## 1. 进入容器

```bash
just build    # first time, or after changes
just run      # interactive shell; ROS is auto-sourced (via ~/.bashrc.d)
```

## 2. 快速检查 -- 相机是否被检测到（SDK 层级）

```bash
rs-enumerate-devices        # lists model / serial / firmware
rs-enumerate-devices -s     # short form
```

通过这一步即确认相机、驱动与 USB 权限都正常工作。

## 3. ROS 1 集成（本 repo 的主要用例）

启动相机节点：

```bash
roslaunch realsense2_camera rs_camera.launch
```

在进入同一容器的第二个 shell 中（从 host 执行 `just exec bash`）：

```bash
rostopic list                                   # expect /camera/... topics
rostopic hz /camera/depth/image_rect_raw        # confirm streaming (Hz)
rostopic echo /camera/color/image_raw -n 1      # one message
```

交互式 shell（`just run` 与 `just exec bash`）会通过 `~/.bashrc.d` 自动 source ROS。
只有非交互式的 `just exec <cmd>`（它不读取 `.bashrc`）才需要先
`source /opt/ros/${ROS_DISTRO}/setup.bash`。

> 彩色 topic 是 `/camera/color/image_raw`，深度是 `/camera/depth/image_rect_raw` -- 
> 单一 `/camera/` 命名空间。（启用 `align_depth:=true` 会新增
> `/camera/aligned_depth_to_color/image_raw`。）

## 4. 可视化（GUI）

```bash
realsense-viewer    # librealsense GUI
rviz                # ROS 1 visualization
```

`realsense-viewer`（以及 `rs-*` 工具）来自从源码构建的 librealsense SDK，`devel` 镜像
在编译它时启用了图形示例；`rviz` 来自 ROS 1 desktop 工具集。两者（以及它们所需的
Qt/OpenGL/X 栈）在 `devel` 中都可用。`runtime` 镜像只含 node，不搭载 SDK GUI 工具。
容器的 GUI 模式 + X11 挂载负责处理显示。

## 5. 片上校正（可选）

D400 系列可以从普通场景重新校正其立体深度参数 -- 无需标定板。深度是通过对两个 IR 相机
进行立体匹配计算得出的，而原厂参数会随时间漂移（温度、机械冲击、运输、老化），表现为额外
的深度噪声、平面不平整或边缘噪声。片上校正可修正这种漂移。它独立于固件更新：固件更新改变
的是相机的固件版本，而校正调整的是深度测量参数。在固件更新后运行一次是不错的健全性检查。

从 `realsense-viewer` 运行它：打开深度传感器的 **More** 菜单并选择
**On-Chip Calibration**，然后对准合适的场景并按下校正。

场景要求：

- 有纹理，距离 **0.5--2 m**，且 **有 > 50% 的有效深度像素**（避免空白墙面、高反光表面
  或过远的任何物体）。
- "White wall" 子模式是例外：**仅**在对准平整白墙且开启 IR 投射器时使用。

### 读取健康检查（health-check）分数

校正后，viewer 会报告一个健康检查分数。**关键在于它的绝对值** -- 符号仅表示校正的方向，
而非"更好"或"更差"。viewer 的 `if >0.25` 指引指的是 `|health| > 0.25`。

| `|health|` | 含义 | 操作 |
|---|---|---|
| 接近 0（< 0.25） | 已校正良好；本次运行几乎没有改变什么 | 无需应用 |
| >= 0.25 | 存在明显漂移；此次校正有意义 | 应用新的校正 |
| 较大（如 > 0.75） | 严重漂移，或场景不合适 | 应用后，换一个更好的场景重新运行以确认 |

因此 `-0.45` 的分数即 `|0.45| > 0.25`：检测到有意义的漂移，建议应用新的校正。负号**并不**
表示校正失败。应用后，在 `realsense-viewer` 中检查深度图像（平面更平整、噪声更少）；保险
起见，换一个不同的场景重新运行 -- 分数回到接近 0 表示校正已收敛。

基于标定板的路径（动态校正工具，它还会重新校正深度到彩色的外参）在
[CALIBRATION.zh-CN.md](CALIBRATION.zh-CN.md) 中介绍。

## 疑难排解

| 症状 | 检查 |
|---|---|
| `No device detected` | host `lsusb` 能看到相机吗？线材／USB 3.0 端口／是否被其他进程占用。容器是否为 `privileged`（默认）。 |
| `roslaunch: command not found` | 交互式 shell 会通过 `~/.bashrc.d` 自动 source ROS。只有非交互式的 `just exec <cmd>` 才需要先 `source /opt/ros/${ROS_DISTRO}/setup.bash`。 |
| Topic 没有数据 / `Reduced performance ... 2.1 port` | 连线协商成了 USB 2.x。请改用较低 profile（`depth_width:=480 depth_height:=270 depth_fps:=6 color_width:=424 color_height:=240 color_fps:=6`，D435 上约 6 Hz）或直连 host 的 USB 3 SuperSpeed 端口。 |
| `realsense-viewer` 无法打开（X11） | host 有 X server；`echo $DISPLAY` 已设置；`config/docker/setup.conf` 中 GUI 模式为 `[gui] mode = auto`。 |
