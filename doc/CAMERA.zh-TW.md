**[English](CAMERA.md)** | **[繁體中文](CAMERA.zh-TW.md)** | **[简体中文](CAMERA.zh-CN.md)** | **[日本語](CAMERA.ja.md)**

# 使用實體 RealSense 相機進行測試

`TEST.md` 涵蓋的是建置時的自動化冒煙測試（smoke test）。本頁則是透過容器驗證實體 Intel RealSense 相機的手動流程。

容器以 `privileged` 模式執行並掛載 `/dev`，因此可以看到主機上的 USB 裝置。此映像檔內含 ROS 1 包裝器（`realsense2_camera`）以及 librealsense SDK 的 CLI 工具（`rs-enumerate-devices`、`realsense-viewer`、`rs-*`）。

## 0. 確認主機能看到相機

```bash
lsusb | grep -i intel    # e.g. Intel RealSense (8086:0b07)
```

若沒有任何顯示：請使用支援資料傳輸的線材、優先選用 USB 3.0 連接埠，並確認沒有其他程序占用相機。

## 1. 進入容器

```bash
just build    # first time, or after changes
just run      # interactive shell; ROS is auto-sourced (via ~/.bashrc.d)
```

## 2. 快速檢查 —— 相機是否被偵測到（SDK 層級）

```bash
rs-enumerate-devices        # lists model / serial / firmware
rs-enumerate-devices -s     # short form
```

通過這一步即可確認相機、驅動程式與 USB 權限皆正常運作。

## 3. ROS 1 整合（本儲存庫的主要使用情境）

啟動相機節點：

```bash
roslaunch realsense2_camera rs_camera.launch
```

在進入同一容器的第二個 shell 中（從主機執行 `just exec bash`）：

```bash
rostopic list                                   # expect /camera/... topics
rostopic hz /camera/depth/image_rect_raw        # confirm streaming (Hz)
rostopic echo /camera/color/image_raw -n 1      # one message
```

互動式 shell（`just run` 與 `just exec bash`）會透過 `~/.bashrc.d` 自動 source ROS。只有非互動式的 `just exec <cmd>`（它不會讀取 `.bashrc`）才需要先執行 `source /opt/ros/${ROS_DISTRO}/setup.bash`。

> 彩色主題（topic）為 `/camera/color/image_raw`，深度主題為 `/camera/depth/image_rect_raw` —— 統一在單一的 `/camera/` 命名空間下。（啟用 `align_depth:=true` 會額外新增 `/camera/aligned_depth_to_color/image_raw`。）

## 4. 視覺化（GUI）

```bash
realsense-viewer    # librealsense GUI
rviz                # ROS 1 visualization
```

devel 映像檔已安裝 ROS 1 desktop 工具，因此 `realsense-viewer` 與 `rviz`（以及它們所需的 Qt/OpenGL/X 堆疊）皆可使用。容器的 GUI 模式加上 X11 掛載即可處理顯示。

## 5. 晶片內校正（選用）

D400 系列可從一般場景重新校正其立體深度參數 —— 無需校正標靶。深度是透過對兩個 IR 相機進行立體匹配（stereo-matching）計算而得，而出廠參數會隨時間漂移（溫度、機械衝擊、運輸、老化），其表現為額外的深度雜訊、平面不平整或邊緣雜訊。晶片內校正（On-Chip Calibration）可修正這類漂移。它與韌體更新彼此獨立：韌體更新會變更相機的韌體版本，而校正則是調整深度量測參數。在韌體更新後執行一次是很好的健全性檢查（sanity check）。

從 `realsense-viewer` 執行：開啟深度感測器的 **More** 選單並選擇 **On-Chip Calibration**，接著對準合適的場景並按下校正。

場景需求：

- 具有紋理、距離 **0.5--2 m**，且 **有效深度像素 > 50%**（避免空白牆面、高反射表面或過遠的物體）。
- 「White wall」子模式為例外：**僅**在開啟 IR 投影器並對準平坦白牆時使用。

### 判讀健康檢查分數

校正後，viewer 會回報一個健康檢查（health-check）分數。**重要的是它的絕對值** —— 正負號只代表修正的方向，並非「較好」或「較差」。viewer 的 `if >0.25` 指引意指 `|health| > 0.25`。

| `|health|` | 意義 | 動作 |
|---|---|---|
| 接近 0（< 0.25） | 已校正良好；這次執行幾乎沒有改變任何東西 | 無需套用 |
| >= 0.25 | 有明顯漂移；此修正具有意義 | 套用新的校正 |
| 很大（例如 > 0.75） | 嚴重漂移，或場景不適合 | 先套用，再於更合適的場景重跑以確認 |

因此分數為 `-0.45` 即 `|0.45| > 0.25`：偵測到具意義的漂移，建議套用新的校正。負號**不**代表校正失敗。套用後，請在 `realsense-viewer` 中檢查深度影像（平面更平整、雜訊更少）；為求穩妥，可在不同場景重跑一次 —— 分數回到接近 0 表示校正已收斂。

以標靶為基礎的流程（Dynamic Calibration Tool，它同時會重新校正深度對彩色的外參〔extrinsics〕）記載於 [CALIBRATION.md](CALIBRATION.md)。

## 疑難排解

| 症狀 | 檢查項目 |
|---|---|
| `No device detected` | 主機的 `lsusb` 是否看到相機？線材／USB 3.0 連接埠／未被其他程序占用。容器為 `privileged`（預設）。 |
| `roslaunch: command not found` | 互動式 shell 會透過 `~/.bashrc.d` 自動 source ROS。只有非互動式的 `just exec <cmd>` 才需要先執行 `source /opt/ros/${ROS_DISTRO}/setup.bash`。 |
| 主題沒有資料／`Reduced performance ... 2.1 port` | 連結協商為 USB 2.x。請使用較低的設定檔（`depth_width:=480 depth_height:=270 depth_fps:=6 color_width:=424 color_height:=240 color_fps:=6`，在 D435 上約 6 Hz）或直接連到主機的 USB 3 SuperSpeed 連接埠。 |
| `realsense-viewer` 無法開啟（X11） | 主機具備 X server；`echo $DISPLAY` 有設定值；`config/docker/setup.conf` 中的 GUI 模式為 `[gui] mode = auto`。 |
