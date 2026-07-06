**[English](CAMERA.md)** | **[繁體中文](CAMERA.zh-TW.md)** | **[简体中文](CAMERA.zh-CN.md)** | **[日本語](CAMERA.ja.md)**

# 使用物理 RealSense 相机进行测试

`TEST.md` 涵盖了构建时的自动冒烟测试（smoke test）。本页则是通过容器验证真实
Intel RealSense 相机的手动流程。

容器以 `privileged` 模式运行并挂载了 `/dev`，因此它能看到主机上的 USB 设备。
该镜像内置了 ROS 1 封装（`realsense2_camera`）以及 librealsense SDK 命令行工具
（`rs-enumerate-devices`、`realsense-viewer`、`rs-*`）。

## 0. 确认主机能看到相机

```bash
lsusb | grep -i intel    # e.g. Intel RealSense (8086:0b07)
```

如果没有任何显示：请使用支持数据传输的线缆，优先选择 USB 3.0 接口，并确保没有其他
进程占用该相机。

## 1. 进入容器

```bash
just build    # first time, or after changes
just run      # interactive shell; ROS is auto-sourced (via ~/.bashrc.d)
```

## 2. 快速检查 —— 相机是否被检测到（SDK 层级）

```bash
rs-enumerate-devices        # lists model / serial / firmware
rs-enumerate-devices -s     # short form
```

通过此项即可确认相机、驱动和 USB 权限均正常工作。

## 3. ROS 1 集成（本仓库的主要用例）

启动相机节点：

```bash
roslaunch realsense2_camera rs_camera.launch
```

在进入同一容器的第二个 shell 中（从主机执行 `just exec bash`）：

```bash
rostopic list                                   # expect /camera/... topics
rostopic hz /camera/depth/image_rect_raw        # confirm streaming (Hz)
rostopic echo /camera/color/image_raw -n 1      # one message
```

交互式 shell（`just run` 和 `just exec bash`）会通过 `~/.bashrc.d` 自动 source
ROS。只有非交互式的 `just exec <cmd>`（它不会读取 `.bashrc`）需要先执行
`source /opt/ros/${ROS_DISTRO}/setup.bash`。

> 彩色话题为 `/camera/color/image_raw`，深度话题为
> `/camera/depth/image_rect_raw` —— 都在单一的 `/camera/` 命名空间下。（启用
> `align_depth:=true` 会新增 `/camera/aligned_depth_to_color/image_raw`。）

## 4. 可视化（GUI）

```bash
realsense-viewer    # librealsense GUI
rviz                # ROS 1 visualization
```

devel 镜像安装了 ROS 1 桌面工具链，因此 `realsense-viewer` 和 `rviz`（以及它们
所需的 Qt/OpenGL/X 栈）均可用。容器的 GUI 模式 + X11 挂载会处理显示。

## 5. 片上标定（可选）

D400 系列可以从普通场景重新标定其立体深度参数 —— 无需标定靶标。深度是通过对两个
IR 相机进行立体匹配计算得出的，而出厂参数会随时间漂移（温度、机械冲击、运输、老化），
表现为额外的深度噪声、不平整的平面或带噪声的边缘。片上标定可以纠正这种漂移。它独立
于固件更新：固件更新改变的是相机的固件版本，标定调整的是深度测量参数。在固件更新后
运行一次是一个不错的健全性检查。

从 `realsense-viewer` 运行它：打开深度传感器的 **More** 菜单并选择
**On-Chip Calibration**，然后对准合适的场景并按下 calibrate。

场景要求：

- 有纹理，距离 **0.5--2 m**，且 **> 50% 有效深度像素**（避免空白墙面、高反光表面
  或过远的物体）。
- "White wall" 子模式是例外：**仅** 在对准平坦白墙且开启 IR 投影器时使用。

### 解读健康检查得分（health-check score）

标定后，查看器会报告一个健康检查得分。**关键在于它的绝对值** —— 符号仅表示校正的
方向，并不代表"更好"或"更差"。查看器的 `if >0.25` 提示意为 `|health| > 0.25`。

| `|health|` | 含义 | 操作 |
|---|---|---|
| 接近 0（< 0.25） | 已经标定良好；本次运行几乎没有改变任何东西 | 无需应用 |
| >= 0.25 | 存在明显漂移；此校正有意义 | 应用新的标定 |
| 较大（例如 > 0.75） | 严重漂移，或场景不合适 | 应用，然后在更好的场景上重新运行以确认 |

因此得分 `-0.45` 即 `|0.45| > 0.25`：检测到了有意义的漂移，建议应用新的标定。负号
**并不** 意味着标定失败。应用后，在 `realsense-viewer` 中检查深度图像（更平整的平面、
更少的噪声）；保险起见，在不同场景上重新运行一次 —— 得分回到接近 0 表示标定已经收敛。

基于靶标的路径（Dynamic Calibration Tool，它还会重新标定深度到彩色的外参）在
[CALIBRATION.md](CALIBRATION.md) 中有描述。

## 故障排查

| 症状 | 检查 |
|---|---|
| `No device detected` | 主机 `lsusb` 能看到相机吗？线缆 / USB 3.0 接口 / 未被其他进程占用。容器为 `privileged`（默认）。 |
| `roslaunch: command not found` | 交互式 shell 会通过 `~/.bashrc.d` 自动 source ROS。只有非交互式的 `just exec <cmd>` 需要先执行 `source /opt/ros/${ROS_DISTRO}/setup.bash`。 |
| 话题没有数据 / `Reduced performance ... 2.1 port` | 链路协商为 USB 2.x。请使用更低的配置（`depth_width:=480 depth_height:=270 depth_fps:=6 color_width:=424 color_height:=240 color_fps:=6`，在 D435 上约 6 Hz）或直连主机的 USB 3 SuperSpeed 接口。 |
| `realsense-viewer` 无法打开（X11） | 主机有 X server；`echo $DISPLAY` 已设置；`config/docker/setup.conf` 中 GUI 模式为 `[gui] mode = auto`。 |
