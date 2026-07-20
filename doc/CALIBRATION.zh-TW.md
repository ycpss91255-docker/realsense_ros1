**[English](CALIBRATION.md)** | **[繁體中文](CALIBRATION.zh-TW.md)** | **[简体中文](CALIBRATION.zh-CN.md)** | **[日本語](CALIBRATION.ja.md)**

# RealSense 動態校正工具（Dynamic Calibration Tool）

本頁說明 **Intel RealSense D400 系列動態校正工具（Dynamic Calibration Tool）**
（`librscalibrationtool`）：它的功能、與 `CAMERA.zh-TW.md` 中 on-chip 校正的差異，
以及如何執行。

> **可用性說明（ROS 1 / focal）：** 本工具**目前尚未內建於本 repo 的 `devel`
> 映像中**。ROS 2 對應版本（`realsense_ros2`）會從 Intel 的 `pool/jammy` `.deb`
> 內建它，但該套件**僅支援 amd64,且綁定特定 Ubuntu 發行版**,而本 repo 的基底是
> **Ubuntu 20.04 focal**（ROS 1 Noetic）。內建一份相容 focal 的建置版本延後到後續
> 處理。在那之前,請在 host 上（或在手動安裝好該工具的 focal 容器中）執行本工具。
> 一旦工具可用,以下流程仍然適用。

## 它是什麼（以及與 on-chip 校正的差異）

D400 相機有兩條各自獨立的校正路徑：

| | On-chip 校正 | 動態校正工具 |
|---|---|---|
| 說明於 | [CAMERA.zh-TW.md](CAMERA.zh-TW.md)（第 5 節） | 本頁 |
| 執行來源 | `realsense-viewer`（內建） | `Intel.Realsense.DynamicCalibrator` |
| 需要標靶 | 否 -- 任何有紋理的場景 | 是 -- 一張列印（或手機 app）的標靶 |
| 校正內容 | 僅深度校正（stereo IR） | 校正 + 深度尺度,**外加 RGB 裝置的 RGB 外參** |
| 使用時機 | 深度雜訊 / 平面不平 | 需要一次完整、基於標靶的重新校正時 |

動態校正只最佳化**外參（extrinsic）**參數 -- 兩個成像器之間的旋轉與平移 --
而不動內參（焦距、主點與畸變維持原廠校正）。依 User Guide（v2.11）,它提供兩種
校正類型與兩種操作模式（有標靶與無標靶）；`Intel.Realsense.DynamicCalibrator`
GUI/CLI 執行的是**有標靶（targeted）**校正：

- **Rectification 校正** -- 重新對齊兩個 IR 成像器的對極幾何
  （`RotationLeftRight` / `TranslationLeftRight`）；目標與 on-chip 校正相同,但
  是基於標靶的。
- **深度尺度校正** -- 當光學元件位移時,修正絕對深度尺度。

D455 上的 Depth<->RGB：有標靶校正**還會重新校正 RGB 外參**
（`RotationLeftRGB` / `TranslationLeftRGB` -- 彩色感測器相對於左成像器）,適用於
具備 RGB 感測器的裝置（D415/D435/D455）。這正是 runtime 對齊所依賴的
depth-to-color 關係（`realsense2_camera` 中的 `align_depth:=true`,或 SDK 中的
`rs2::align`）,因此重跑一次即可修正錯位的 depth<->color 疊合。無標靶模式只校正
深度（左/右）而**不**校正 RGB,且僅限 API -- GUI 校正器不提供此模式。

## 工具提供的內容

Intel 以預編譯的**僅 amd64**套件出貨（無 ARM64 建置）。該套件提供這些執行檔：

| 執行檔 | 用途 |
|---|---|
| `Intel.Realsense.DynamicCalibrator` | 有標靶動態校正（rectification + 深度尺度 + RGB 外參）,GUI 與 CLI |
| `Intel.Realsense.CustomRW` | 讀 / 寫相機上儲存的校正表 |
| `opencv_interactive-calibration` | OpenCV 互動式校正輔助工具 |

## 前置需求

1. **Host udev 規則。** 本工具需要對相機的 raw USB 存取,與 SDK 其餘部分的權限
   需求相同。在 host 上安裝一次即可：

   ```bash
   ./script/install_udev_rules.sh
   ```

   為何必須裝在 host 而非只在容器內,見 README 的「RealSense udev 規則」一節。

2. **一張校正標靶。** 依文件標示的比例列印官方標靶（連結見下方）,或透過 Intel
   RealSense Dynamic Target 手機 app（iOS / Android）顯示。

3. **GUI 存取。** 一個具備 X11/Qt/OpenGL 堆疊的顯示環境,校正器視窗才能開啟
   （`devel` 映像已內含此堆疊,並以 GUI 模式執行）。

## 執行方式

```bash
# Once the tool is available on PATH (see the availability note above):
Intel.Realsense.DynamicCalibrator     # interactive GUI calibration
```

把裝置放在距標靶 **600--850 mm** 處,讓標靶的橫條在視野中大致垂直；整個過程都
需要相機與標靶之間的相對移動（固定其一、移動另一）。避免反光（陽光、強烈照明、
手機螢幕眩光）-- 反光會使標靶無法被偵測。有標靶流程接著依序執行以下階段
（User Guide 第 4.5.4 節與附錄 B）：

1. **Rectification 階段** -- 一組帶陰影的**藍色方塊**會疊在即時畫面中央。每個藍色
   方塊標示視野中仍需標靶覆蓋的一塊區域。緩慢移動相機（或標靶）,讓標靶的黑白方塊
   與橫條蓋住藍色方塊；被覆蓋的方塊會逐一**清除**。重複直到全部清除。（若自動曝光
   搜尋開啟且標靶短暫遺失,影像會在搜尋時亮<->暗循環 -- 這是預期行為；若始終偵測不
   到,請重新調整位置以排除反光或距離問題。）中間結果會立即套用到串流上。
2. **尺度階段** -- 自動開始；持續把標靶移到不同、明確區隔的位置,直到接受 **15** 張
   標靶影像（綠色進度條填滿為止）。
3. **RGB 階段**（僅 RGB 裝置 -- D415/D435/D455）-- 與尺度階段類似,擷取 15 張標靶
   影像並校正 depth-to-RGB 的 UV 映射。此階段之後,左/右深度與 depth<->RGB 皆完成
   校正。

完成後,結果會寫入相機。可用 `Intel.Realsense.CustomRW` 在前後備份或還原校正表,
並在之後驗證深度品質（若不滿意則重跑）。

## 已知限制：depth<->color 對齊的殘差

即使校正成功,depth-to-color 疊合（`align`）仍有一些殘差 -- 在物體邊緣最明顯。
已在硬體上驗證：它在 **D455 於 ~1--2 m 處明顯可見**,在 **D435 上則略微存在**。
這在很大程度上是**預期且幾何性的**,並非校正失敗的徵兆。校正移除的是系統性的
外參偏移；它無法移除：

- **視差 / 遮擋** -- 深度（左 IR）與 RGB 是不同的光學中心,因此在物體邊界處,一台
  相機看得到另一台看不到的區域。該區域無法透過任何校正對齊 -- 這是純粹的幾何,也
  是邊緣「鑲邊（fringing）」的主因。
- **深度誤差** -- stereo 深度誤差大致隨距離平方成長,因此在 1--2 m 處反投影到彩色
  影像的準確度較低（在有雜訊的邊緣與空洞處更差）。
- **RGB rolling shutter / 同步** -- 彩色感測器是 rolling-shutter；當相機或場景移動
  時,它相對於（global 的）深度影格會位移。

為何 D455 比 D435 更嚴重：**D455 的 stereo baseline 為 95 mm,而 D435 為 50 mm**。
較寬的 baseline 帶來更佳的遠距深度,但也造成更大的 depth<->RGB 視差,因此殘差在近/
中距離更明顯。

哪些做法仍有幫助（但不會降到零）：

- 依使用情境選擇對齊方向是 depth->color 或 color->depth。
- 在對齊*之前*套用深度後處理（spatial / temporal / hole-filling）。
- 維持 depth/color 同步並拍攝靜態場景,以避免 rolling-shutter 位移。
- 保持在相機的最佳深度範圍內,讓深度盡可能準確。

## 官方參考資料

- 校正總覽（工具、可列印標靶與指南下載）：
  <https://dev.realsenseai.com/docs/calibration/>
- 動態校正工具下載（Windows / Ubuntu 套件）：
  <https://www.intel.com/content/www/us/en/download/645988/29618/intel-realsense-d400-series-dynamic-calibration-tool.html>
- User Guide（PDF）：
  <https://cdrdv2-public.intel.com/840579/RealSense_D400_Dyn_Calib_User_Guide.pdf>
- Programmer's Guide（PDF）：
  <https://cdrdv2-public.intel.com/840422/RealSense_D400_Dyn_Calib_Programmer.pdf>
