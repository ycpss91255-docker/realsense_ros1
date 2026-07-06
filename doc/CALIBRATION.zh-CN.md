**[English](CALIBRATION.md)** | **[繁體中文](CALIBRATION.zh-TW.md)** | **[简体中文](CALIBRATION.zh-CN.md)** | **[日本語](CALIBRATION.ja.md)**

# RealSense 动态标定工具

本页介绍 **Intel RealSense D400 系列动态标定工具（Dynamic Calibration Tool）**
（`librscalibrationtool`）：它的功能、它与 `CAMERA.md` 中片上标定（on-chip
calibration）的区别，以及如何运行它。

> **可用性说明（ROS 1 / focal）：** 该工具**目前未打包进本仓库的 `devel` 镜像。**
> ROS 2 版本（`realsense_ros2`）从 Intel 的 `pool/jammy` `.deb` 打包了它，但该软件包
> **仅支持 amd64 且与 Ubuntu 发行版绑定**，而本仓库的基础镜像是 **Ubuntu 20.04 focal**
> （ROS 1 Noetic）。打包一个兼容 focal 的构建版本被推迟到后续处理。在此之前，请在宿主机上
> （或在手动安装了该工具的 focal 容器中）运行本工具。一旦工具可用，下面的工作流程仍然适用。

## 它是什么（以及它与片上标定的区别）

D400 相机有两条不同的标定路径：

| | 片上标定（On-chip calibration） | 动态标定工具（Dynamic Calibration Tool） |
|---|---|---|
| 相关文档 | [CAMERA.md](CAMERA.md)（第 5 节） | 本页 |
| 运行自 | `realsense-viewer`（内置） | `Intel.Realsense.DynamicCalibrator` |
| 是否需要标定靶 | 否 —— 任意有纹理的场景即可 | 是 —— 需要打印的（或手机 App 显示的）标定靶 |
| 标定内容 | 仅深度校正（立体 IR） | 校正 + 深度尺度，**外加 RGB 外参**（在带 RGB 的设备上） |
| 何时使用 | 深度噪声 / 平面不平 | 需要基于标定靶的彻底重新标定时 |

动态标定仅优化**外参（extrinsic）**参数 —— 即成像器之间的旋转与平移 —— 而非内参
（焦距、主点和畸变保持出厂标定值）。根据《用户指南》（v2.11），它提供两种标定类型、两种
运行模式（有靶模式 targeted 与无靶模式 target-less）；`Intel.Realsense.DynamicCalibrator`
GUI/CLI 运行的是**有靶（targeted）**标定：

- **校正标定（Rectification calibration）** —— 重新对齐两个 IR 成像器的极线几何
  （`RotationLeftRight` / `TranslationLeftRight`）；目标与片上标定相同，但基于标定靶。
- **深度尺度标定（Depth scale calibration）** —— 当光学元件发生位移时，修正绝对深度尺度。

D455 上的 Depth<->RGB：在带 RGB 传感器的设备（D415/D435/D455）上，有靶标定**还会重新标定
RGB 外参**（`RotationLeftRGB` / `TranslationLeftRGB` —— 彩色传感器相对于左成像器的关系）。
这正是运行时对齐所依赖的 depth-to-color 关系（`realsense2_camera` 中的 `align_depth:=true`，
或 SDK 中的 `rs2::align`），因此重新运行它可以修正错位的 depth<->color 叠加。无靶模式仅标定
深度（左/右）而**不**标定 RGB，且仅提供 API —— GUI 标定器不提供该模式。

## 该工具提供的内容

Intel 以预编译的**仅 amd64** 软件包形式发布该工具（没有 ARM64 构建版本）。该软件包提供以下
可执行文件：

| 可执行文件 | 用途 |
|---|---|
| `Intel.Realsense.DynamicCalibrator` | 有靶动态标定（校正 + 深度尺度 + RGB 外参），GUI 和 CLI |
| `Intel.Realsense.CustomRW` | 读取 / 写入相机上存储的标定表 |
| `opencv_interactive-calibration` | OpenCV 交互式标定辅助工具 |

## 前置条件

1. **宿主机 udev 规则。** 该工具需要对相机的原始 USB 访问权限，这与 SDK 其余部分的权限要求
   相同。在宿主机上安装一次即可：

   ```bash
   ./script/install_udev_rules.sh
   ```

   有关为何必须安装在宿主机上而不仅仅是容器内，请参见 README 中的 "RealSense udev Rules" 一节。

2. **一个标定靶。** 可以按文档标注的比例打印官方标定靶（链接见下文），或通过 Intel RealSense
   Dynamic Target 手机 App（iOS / Android）显示它。

3. **GUI 访问。** 需要一个带 X11/Qt/OpenGL 栈的显示器，以便标定器窗口能够打开（`devel` 镜像
   已包含此栈并以 GUI 模式运行）。

## 运行它

```bash
# Once the tool is available on PATH (see the availability note above):
Intel.Realsense.DynamicCalibrator     # interactive GUI calibration
```

将设备放置在距离标定靶 **600--850 mm** 处，使标定靶的条纹在视野中大致竖直；整个过程中需要
相机与标定靶之间存在相对运动（固定一方，移动另一方）。避免反射（阳光、强光、手机屏幕眩光）——
它们会导致标定靶无法被检测到。有靶流程随后按顺序运行以下阶段（《用户指南》第 4.5.4 节及附录 B）：

1. **校正阶段（Rectification phase）** —— 实时画面中央会叠加一组带阴影的**蓝色方块**。每个蓝色
   方块标记视野中仍需标定靶覆盖的区域。缓慢移动相机（或标定靶），使标定靶的黑/白方块和条纹与蓝色
   方块重叠；被覆盖的方块会逐个**清除**。重复直到全部清除。（如果开启了自动曝光搜索且标定靶短暂
   丢失，图像会在明<->暗之间循环切换，这是正常现象；如果始终无法检测到，请重新调整位置以消除反射
   或距离问题。）中间结果会立即应用到数据流。
2. **尺度阶段（Scale phase）** —— 自动开始；持续将标定靶重新放置到不同的、彼此区分的位置，直到
   有 **15** 张标定靶图像被接受（绿色进度条填满完成）。
3. **RGB 阶段（RGB phase）**（仅限带 RGB 的设备 —— D415/D435/D455）—— 与尺度阶段类似，它采集
   15 张标定靶图像并标定 depth-to-RGB 的 UV 映射。完成后，左/右深度和 depth<->RGB 都已完成标定。

完成后，结果会写入相机。可使用 `Intel.Realsense.CustomRW` 在标定前后备份或恢复标定表，并在
之后验证深度质量（如不满意可重新运行）。

## 已知局限：残余的 depth<->color 对齐误差

即便标定成功，depth-to-color 叠加（`align`）仍存在一些残余误差 —— 在物体边缘附近最为明显。已在
硬件上验证：在 **D455 上于约 1--2 m 处明显可见**，在 **D435 上则略有存在**。这在很大程度上是
**预期的、几何性的**，而非标定失败的迹象。标定消除了系统性的外参偏移，但它无法消除：

- **视差 / 遮挡（Parallax / occlusion）** —— 深度（左 IR）与 RGB 是不同的光学中心，因此在物体
  边界处，一个相机看得到的部分另一个看不到。任何标定都无法对齐该区域 —— 这纯粹是几何问题，也是
  边缘"镶边（fringing）"的主要成因。
- **深度误差（Depth error）** —— 立体深度误差大致随距离的平方增长，因此在 1--2 m 处，向彩色图像
  的反投影准确度较低（在有噪声的边缘和空洞处更差）。
- **RGB 卷帘快门 / 同步（RGB rolling shutter / sync）** —— 彩色传感器为卷帘快门；当相机或场景
  运动时，它会相对于（全局快门的）深度帧发生位移。

为何 D455 比 D435 更差：**D455 的立体基线为 95 mm，而 D435 为 50 mm**。更宽的基线带来更好的
远距离深度，但也带来更大的 depth<->RGB 视差，因此在近/中距离处残余更明显。

哪些方法仍有帮助（它不会降到零）：

- 根据用例选择对齐方向：depth->color 还是 color->depth。
- 在对齐*之前*应用深度后处理（空间 / 时间 / 空洞填充）。
- 保持深度/彩色同步并拍摄静态场景，以避免卷帘快门位移。
- 保持在相机的最佳深度范围内，使深度尽可能准确。

### 对齐方向：depth->color 与 color->depth

这两个方向**并不对称** —— 它们是不同的算法，这正是上面选择很重要的原因（依据 Intel 的
*Projection, Texture-Mapping and Occlusion* 白皮书第 3.4 节）：

- **Color->depth**（将彩色对齐到深度帧）是开销较小的方向：对每个深度像素，查找其 uv-map 坐标并
  取出该处的彩色值。输出为深度分辨率，每像素一次查找 —— 没有空洞。
- **Depth->color**（将深度对齐到彩色帧 —— 即 `align_depth:=true` / `rs_aligned_depth.launch`
  所产生的结果）"稍微棘手一些"：彩色像素无法轻易反投影回 3D，因此改为将每个深度像素
  **前向投影（forward-project）**到彩色坐标，当多个像素落在同一个彩色像素上时保留最近的深度
  （z-buffering）。如果彩色传感器分辨率高于深度，则一些彩色像素得不到深度 -> 出现空洞，SDK 通过
  将每个深度像素散布（splatting）到 2x2 补丁来掩盖这些空洞。

因此，出厂默认方向（`depth->color`）是较难、易产生近似误差的方向 —— 前向投影 + 2x2 空洞填充正是
残余误差最明显地表现为边缘镶边的部分原因。能够消费深度分辨率输出的应用，可以通过选择
`color->depth` 来避免这一类伪影。

## 官方文档量化了什么（以及没有量化什么）

Intel **没有**公布 depth<->color *对齐*误差随距离变化的表格。最接近的官方数字是：

- **深度 Z 精度（绝对误差）：+/-2%** —— D400 系列数据手册（337029-017）表 4-15 "Depth Quality
  Specification"，同时列出 Fill Rate >=99%、RMS Error <=2%、Temporal Noise <=1%。测量距离因型号
  而异：D43x 规格标注为 "<=2 m, 80% ROI, HD"，D450/D455 规格为 "<=4 m, 80% ROI, HD"。**这是深度
  精度规格，不是对齐误差规格** —— 它约束的是 Z 值有多大误差，而这只*间接*影响向彩色的反投影。
  没有按距离（1 m / 2 m / 3 m）的细分。
- **对齐算法及其误差来源**在 *Projection, Texture-Mapping and Occlusion* 白皮书中有*定性*描述：
  第 3.4 节（数据流对齐 —— 上述两个方向）和第 4 节（遮挡失效 —— 在物体边界处一个成像器看得到而
  另一个看不到；SDK 2.35+ 在点云计算期间会自动使这些被遮挡区域失效）。它解释了边缘误差*为何*存在，
  但没有给出实测量级。

结论：所谓 "1 m / 2 m / 3 m 残余" 数字**无法从 Intel 获得** —— 必须自行内部测量（见下文）。

## 计划中的量化实验（已推迟）

目标：将定性的"D455 在 1--2 m 处更差"观察转化为一张距离-误差表（1 m / 2 m / 3 m 处的误差）。

**已推迟（2026-07-03）。** 可信的测量需要一个**稳定、受控的装置**，而目前唯一可用的 D455 安装在
一台运行中的 AMR 上（运行导航栈），相机位姿不受控 —— 这是一个生产节点，而非测量台架。一旦有专用的
静态装置可用，即运行此实验。

设计：

- **指标（主要）：边缘偏移（edge-offset）。** 将相机对准一个具有已知直边的物体（一块平板，或一个
  棋盘格）。测量对齐帧中**深度边缘**与**彩色边缘**之间的像素偏移；通过深度 Z 和相机内参将其换算为
  mm。这与最初观察到的边缘镶边相匹配，并可直接读作"在 1 m 处，边缘偏差为 X px / Y mm"。
- **指标（可选，更严格）：棋盘格重投影（checkerboard reprojection）。** 在彩色图中检测棋盘格角点，
  并与从深度反投影得到的角点对比；报告重投影误差（px / mm）。当数字需要经得起推敲（报告 / 对外）时
  使用。
- **对齐方向：** 测量 **depth->color**（`align_depth:=true`，出厂默认），以使数字对应实际交付的
  内容；可选地也测量 `color->depth` 以作对比。
- **采集：** 在 1 / 2 / 3 m 的每个距离处（测量到相机盖玻璃 —— 即 Ground-Zero 参考基准，数据手册
  4.8）记录同步的对齐深度+彩色，静态场景，相机脱离机器人。在对齐*之前*应用深度后处理（空间 / 时间 /
  空洞填充），与生产环境一致。
- **对照：** 同时运行 D455 和 D435，以复现由基线差异驱动的区别（95 mm 与 50 mm）。标定靶要光照
  充足、无反射，大致填满 ROI。
- **输出：** 一张距离-误差表 + 叠加截图，追加于此处。

前置条件：运行中的容器必须实际发布 `/camera/aligned_depth_to_color/image_raw`。在 2026-07-03
之前构建的运行时镜像默认使用非对齐的 `rs_camera.launch`；请重新构建以采用新的对齐默认值，或在采集时
显式启动对齐。

## 官方参考资料

- 标定概览（工具、可打印标定靶和指南下载）：
  <https://dev.realsenseai.com/docs/calibration/>
- 动态标定工具下载（Windows / Ubuntu 软件包）：
  <https://www.intel.com/content/www/us/en/download/645988/29618/intel-realsense-d400-series-dynamic-calibration-tool.html>
- 用户指南（PDF）：
  <https://cdrdv2-public.intel.com/840579/RealSense_D400_Dyn_Calib_User_Guide.pdf>
- 程序员指南（PDF）：
  <https://cdrdv2-public.intel.com/840422/RealSense_D400_Dyn_Calib_Programmer.pdf>
