**[English](CALIBRATION.md)** | **[繁體中文](CALIBRATION.zh-TW.md)** | **[简体中文](CALIBRATION.zh-CN.md)** | **[日本語](CALIBRATION.ja.md)**

# RealSense 动态校正工具

本页介绍 **Intel RealSense D400 系列动态校正工具（Dynamic Calibration Tool）**
（`librscalibrationtool`）：它的功能、与 `CAMERA.md` 中片上（on-chip）校正的差异，
以及如何运行它。

> **可用性说明（ROS 1 / focal）：** 该工具**目前尚未内置于本 repo 的 `devel` 镜像**。
> ROS 2 姊妹版（`realsense_ros2`）从 Intel 的 `pool/jammy` `.deb` 内置它，但该软件包
> **仅支持 amd64 且与 Ubuntu 发行版绑定**，而本 repo 的基础是 **Ubuntu 20.04 focal**
> （ROS 1 Noetic）。内置一个兼容 focal 的构建版本已延后到后续处理。在那之前，请在 host
> 上运行该工具（或在手动安装了它的 focal 容器内运行）。工具可用后，下面的工作流程依然适用。

## 它是什么（以及与片上校正的差异）

D400 相机有两条不同的校正路径：

| | 片上校正 | 动态校正工具 |
|---|---|---|
| 涵盖于 | [CAMERA.zh-CN.md](CAMERA.zh-CN.md)（第 5 节） | 本页 |
| 运行来源 | `realsense-viewer`（内置） | `Intel.Realsense.DynamicCalibrator` |
| 是否需要标定板 | 否 -- 任意带纹理的场景即可 | 是 -- 需要打印（或手机 app）的标定板 |
| 校正内容 | 仅深度校正（立体 IR） | 校正 + 深度尺度，**外加 RGB 设备上的 RGB 外参** |
| 何时使用 | 深度噪声／平面不平整 | 需要一次彻底的、基于标定板的重新校正 |

动态校正只优化 **外参（extrinsic）** -- 即各成像器之间的旋转与平移 -- 而非内参
（焦距、主点与畸变仍维持原厂校正值）。依据 User Guide（v2.11），它在两种操作模式
（有标定板与无标定板）下提供两种校正类型；`Intel.Realsense.DynamicCalibrator` GUI/CLI
运行的是 **有标定板（targeted）** 校正：

- **Rectification 校正** -- 重新对齐两个 IR 成像器的对极几何
  （`RotationLeftRight` / `TranslationLeftRight`）；目标与片上校正相同，但基于标定板。
- **深度尺度校正** -- 在光学元件发生位移时，修正绝对深度尺度。

D455 上的 Depth<->RGB：有标定板校正**还会重新校正 RGB 外参**
（`RotationLeftRGB` / `TranslationLeftRGB` -- 即彩色传感器相对于左成像器）在具备 RGB
传感器的设备上（D415/D435/D455）。这正是运行时对齐所依赖的深度到彩色关系
（`realsense2_camera` 中的 `align_depth:=true`，或 SDK 中的 `rs2::align`），因此重新运行
它可以修复错位的 depth<->color 叠加。无标定板模式只校正深度（左／右）而**不**校正 RGB，
且仅提供 API -- GUI 校正器不提供该模式。

## 该工具提供什么

Intel 以预编译的 **仅 amd64** 软件包形式发布该工具（没有 ARM64 构建）。软件包提供以下
可执行文件：

| 可执行文件 | 用途 |
|---|---|
| `Intel.Realsense.DynamicCalibrator` | 有标定板动态校正（校正 + 深度尺度 + RGB 外参），GUI 与 CLI |
| `Intel.Realsense.CustomRW` | 读／写存储在相机上的校正表 |
| `opencv_interactive-calibration` | OpenCV 交互式校正辅助工具 |

## 前置条件

1. **Host udev 规则。** 该工具需要对相机进行原始 USB 访问，与 SDK 其余部分的权限
   要求相同。在 host 上安装一次：

   ```bash
   ./script/install_udev_rules.sh
   ```

   为什么必须装在 host 而不仅仅是容器内，请见 README 的 "RealSense udev Rules" 一节。

2. **标定板。** 可依据文档标注的比例打印官方标定板（链接见下），或通过 Intel RealSense
   Dynamic Target 手机 app（iOS / Android）显示它。

3. **GUI 访问。** 需要带 X11/Qt/OpenGL 栈的显示环境以便校正器窗口能打开（`devel`
   镜像已内含这些并以 GUI 模式运行）。

## 运行它

```bash
# Once the tool is available on PATH (see the availability note above):
Intel.Realsense.DynamicCalibrator     # interactive GUI calibration
```

将设备摆放在距离标定板 **600--850 mm** 处，让标定板的条纹在视野内大致垂直；整个过程都
需要相机与标定板之间有相对运动（固定其一、移动另一个）。避免反光（阳光、强光、手机屏幕
眩光） -- 它们会导致无法检测到标定板。有标定板流程随后会依次运行以下阶段（User Guide
第 4.5.4 节与附录 B）：

1. **Rectification 阶段** -- 一组带阴影的**蓝色方块**会叠加在实时画面的中央。
   每个蓝色方块标记视野中仍需标定板覆盖的区域。缓慢移动相机（或标定板），让标定板的
   黑／白方块和条纹与蓝色方块重叠；被覆盖的方块会一个一个**清除**。重复直到全部清除。
   （若开启了自动曝光搜索且标定板短暂丢失，图像会在搜索时明<->暗循环 -- 这是预期行为；
   若始终检测不到，请重新摆位以消除反光或调整距离。）中间结果会立即应用到数据流上。
2. **尺度（Scale）阶段** -- 自动开始；持续把标定板重新摆放到不同的、互异的位置，直到
   **15** 张标定板图像被接受（一条绿色进度条填满至完成）。
3. **RGB 阶段**（仅 RGB 设备 -- D415/D435/D455） -- 与尺度阶段类似，它捕获 15 张标定板
   图像并校正深度到 RGB 的 UV 映射。完成后，左／右深度以及 depth<->RGB 都完成校正。

完成后，结果会写入相机。可用 `Intel.Realsense.CustomRW` 在校正前／后备份或还原校正表，
并在之后验证深度质量（若不满意则重新运行）。

## 已知限制：残留的 depth<->color 对齐误差

即便校正成功，depth 到 color 的叠加（`align`）仍会有一些残留误差 -- 在物体边缘附近
最为明显。已在硬件上验证：它在 **D455 上于 ~1--2 m 处明显可见**，在 **D435 上则略有出现**。
这在很大程度上是 **预期内且属几何性质的**，并非校正失败的迹象。校正能消除系统性的外参
偏移；但它无法消除：

- **视差／遮挡** -- 深度（左 IR）与 RGB 是不同的光学中心，因此在物体边界处，一个相机看得
  到另一个相机看不到的部分。该区域无法通过任何校正来对齐 -- 这纯粹是几何问题，也是边缘
  "镶边（fringing）" 的主因。
- **深度误差** -- 立体深度误差大致随距离的平方增长，因此在 1--2 m 处，将深度反投影到彩色
  图像的精度较低（在有噪声的边缘和空洞处更差）。
- **RGB 卷帘快门／同步** -- 彩色传感器为卷帘快门；当相机或场景运动时，它相对于（全局
  快门的）深度帧会发生偏移。

为什么 D455 比 D435 更差：**D455 的立体基线为 95 mm，而 D435 为 50 mm**。更宽的基线带来更
好的远距离深度，但也带来更大的 depth<->RGB 视差，因此在近／中距离残留误差更明显。

哪些做法仍有帮助（它不会归零）：

- 依用例选择是对齐 depth->color 还是 color->depth。
- 在对齐*之前*施加深度后处理（空间／时间／空洞填充）。
- 保持 depth/color 同步并拍摄静态场景，以避免卷帘快门偏移。
- 保持在相机的最佳深度范围内，让深度尽可能准确。

## 官方参考

- 校正概览（工具、可打印标定板与指南下载）：
  <https://dev.realsenseai.com/docs/calibration/>
- 动态校正工具下载（Windows / Ubuntu 软件包）：
  <https://www.intel.com/content/www/us/en/download/645988/29618/intel-realsense-d400-series-dynamic-calibration-tool.html>
- User Guide（PDF）：
  <https://cdrdv2-public.intel.com/840579/RealSense_D400_Dyn_Calib_User_Guide.pdf>
- Programmer's Guide（PDF）：
  <https://cdrdv2-public.intel.com/840422/RealSense_D400_Dyn_Calib_Programmer.pdf>
