**[English](CAMERA.md)** | **[繁體中文](CAMERA.zh-TW.md)** | **[简体中文](CAMERA.zh-CN.md)** | **[日本語](CAMERA.ja.md)**

# 以實體 RealSense 相機測試

`TEST.md` 涵蓋的是建置期自動 smoke 測試。本頁則是透過容器驗證一台真正的 Intel
RealSense 相機的手動流程。

容器以 `privileged` 模式執行並掛載 `/dev`,因此能看到 host 上的 USB 裝置。`devel`
映像出貨 ROS 1 wrapper（`realsense2_camera`）以及從原始碼建置的 librealsense SDK
CLI 工具（`rs-enumerate-devices`、`realsense-viewer`、`rs-*`）。（`runtime` 映像
僅含節點 -- 它帶有 wrapper 與 SDK 函式庫,但不含這些 CLI 工具。）

## 0. 確認 host 看得到相機

```bash
lsusb | grep -i intel    # e.g. Intel RealSense (8086:0b07)
```

若沒有任何輸出：請使用具備資料傳輸能力的線材、優先選 USB 3.0 埠,並確認沒有其他
程序占用相機。

## 1. 進入容器

```bash
just build    # first time, or after changes
just run      # interactive shell; ROS is auto-sourced (via ~/.bashrc.d)
```

## 2. 快速檢查 -- 相機是否被偵測（SDK 層級）

```bash
rs-enumerate-devices        # lists model / serial / firmware
rs-enumerate-devices -s     # short form
```

通過此步即確認相機、驅動與 USB 權限皆正常運作。

## 3. ROS 1 整合（本 repo 的主要使用情境）

啟動相機節點：

```bash
roslaunch realsense2_camera rs_camera.launch
```

在進入同一容器的第二個 shell 中（從 host 執行 `just exec bash`）：

```bash
rostopic list                                   # expect /camera/... topics
rostopic hz /camera/depth/image_rect_raw        # confirm streaming (Hz)
rostopic echo /camera/color/image_raw -n 1      # one message
```

互動式 shell（`just run` 與 `just exec bash`）會透過 `~/.bashrc.d` 自動 source
ROS。只有非互動式的 `just exec <cmd>`（不會讀取 `.bashrc`）才需要先
`source /opt/ros/${ROS_DISTRO}/setup.bash`。

> 彩色 topic 是 `/camera/color/image_raw`,深度是
> `/camera/depth/image_rect_raw` -- 單一 `/camera/` namespace。（啟用
> `align_depth:=true` 會新增 `/camera/aligned_depth_to_color/image_raw`。）

## 4. 視覺化（GUI）

```bash
realsense-viewer    # librealsense GUI
rviz                # ROS 1 visualization
```

`realsense-viewer`（以及 `rs-*` 工具）來自從原始碼建置的 librealsense SDK,`devel`
映像在編譯時已啟用圖形化範例；`rviz` 則來自 ROS 1 desktop 工具。兩者（加上它們
所需的 Qt/OpenGL/X 堆疊）在 `devel` 中皆可用。`runtime` 映像僅含節點,不出貨 SDK
GUI 工具。容器的 GUI 模式 + X11 掛載會處理顯示。

## 5. On-chip 校正（選用）

D400 系列可從一般場景重新校正其 stereo 深度參數 -- 不需校正標靶。深度是透過對兩
台 IR 相機做 stereo matching 計算而來,而原廠參數會隨時間漂移（溫度、機械衝擊、
運輸、老化）,表現為額外的深度雜訊、平面不平或邊緣雜訊。On-chip 校正會修正這種
漂移。它與韌體更新彼此獨立：韌體更新改變的是相機的韌體版本,校正調整的是深度量測
參數。韌體更新後跑一次校正是不錯的健全性檢查。

從 `realsense-viewer` 執行：開啟深度感測器的 **More** 選單並選 **On-Chip
Calibration**,接著對準合適的場景並按下校正。

場景需求：

- 有紋理、距離 **0.5--2 m**、且**有效深度像素 > 50%**（避免空白牆面、高反射表面
  或任何太遠的物體）。
- 「White wall」子模式是例外：**只**在開啟 IR projector 並對準平坦白牆時使用。

### 判讀 health-check 分數

校正後,viewer 會回報一個 health-check 分數。**重要的是它的絕對值** -- 正負號只
編碼修正的方向,而非「更好」或「更差」。viewer 的 `if >0.25` 提示指的是
`|health| > 0.25`。

| `|health|` | 意義 | 動作 |
|---|---|---|
| 接近 0（< 0.25） | 已校正良好；此次幾乎沒有改變 | 不需套用 |
| >= 0.25 | 有明顯漂移；此修正有意義 | 套用新校正 |
| 很大（例如 > 0.75） | 嚴重漂移,或場景不合適 | 套用後,再換一個較佳場景重跑以確認 |

因此 `-0.45` 的分數是 `|0.45| > 0.25`：偵測到有意義的漂移,建議套用新校正。負號**不
代表**校正失敗。套用後,在 `realsense-viewer` 檢查深度影像（平面更平、雜訊更少）；
保險起見,換一個場景重跑 -- 分數回到接近 0 表示校正已收斂。

一條基於標靶的路徑（動態校正工具,它還會重新校正 depth-to-color 外參）說明於
[CALIBRATION.zh-TW.md](CALIBRATION.zh-TW.md)。

## 疑難排解

| 症狀 | 檢查 |
|---|---|
| `No device detected` | host `lsusb` 看得到相機嗎？線材 / USB 3.0 埠 / 未被其他程序占用。容器為 `privileged`（預設）。 |
| `roslaunch: command not found` | 互動式 shell 會透過 `~/.bashrc.d` 自動 source ROS。只有非互動式的 `just exec <cmd>` 才需要先 `source /opt/ros/${ROS_DISTRO}/setup.bash`。 |
| Topic 沒有資料 / `Reduced performance ... 2.1 port` | 連線協商成 USB 2.x。改用較低 profile（`depth_width:=480 depth_height:=270 depth_fps:=6 color_width:=424 color_height:=240 color_fps:=6`,D435 上約 ~6 Hz）或直接接到 host 的 USB 3 SuperSpeed 埠。 |
| `realsense-viewer` 無法開啟（X11） | host 有 X server；`echo $DISPLAY` 有設定；GUI 模式在 `config/docker/setup.conf` 中為 `[gui] mode = auto`。 |
