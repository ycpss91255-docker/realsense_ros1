**[English](CALIBRATION.md)** | **[繁體中文](CALIBRATION.zh-TW.md)** | **[简体中文](CALIBRATION.zh-CN.md)** | **[日本語](CALIBRATION.ja.md)**

# RealSense 動態校正工具

本頁說明 **Intel RealSense D400 Series Dynamic Calibration Tool**
（`librscalibrationtool`）：它的功能、它與 `CAMERA.md` 中的晶片內
（on-chip）校正有何差異，以及如何執行它。

> **可用性說明（ROS 1 / focal）：** 本工具**目前並未內建於本 repo 的
> `devel` image 中。** ROS 2 對應版本（`realsense_ros2`）會從 Intel 的
> `pool/jammy` `.deb` 內建此工具，但該套件**僅支援 amd64 且綁定特定
> Ubuntu 版本**，而本 repo 的基底是 **Ubuntu 20.04 focal**（ROS 1
> Noetic）。內建一個相容於 focal 的建置版本延後至後續處理。在此之前，
> 請在主機上（或在手動安裝該工具的 focal 容器內）執行本工具。下方的
> 工作流程在工具可用之後仍然適用。

## 它是什麼（以及與晶片內校正的差異）

D400 相機有兩條各自獨立的校正路徑：

| | 晶片內校正 | 動態校正工具 |
|---|---|---|
| 說明於 | [CAMERA.md](CAMERA.md)（第 5 節） | 本頁 |
| 執行來源 | `realsense-viewer`（內建） | `Intel.Realsense.DynamicCalibrator` |
| 是否需要標靶 | 否 —— 任何具紋理的場景皆可 | 是 —— 需要列印（或手機 app）的標靶 |
| 校正內容 | 僅深度校正（立體 IR） | 校正 + 深度尺度，**加上 RGB 裝置上的 RGB 外參（extrinsics）** |
| 何時使用 | 深度雜訊 / 非平坦的平面 | 需要進行完整、以標靶為基礎的重新校正時 |

動態校正僅最佳化**外參（extrinsic）**參數 —— 也就是各影像感測器
（imager）之間的旋轉與平移 —— 而非內參（focal length、principal point
與失真維持原廠校正值）。根據 User Guide（v2.11），它提供兩種校正類型、
兩種操作模式（有標靶與無標靶）；`Intel.Realsense.DynamicCalibrator`
GUI/CLI 執行的是**有標靶（targeted）**校正：

- **Rectification 校正** —— 重新對齊兩個 IR imager 的核線幾何
  （epipolar geometry）（`RotationLeftRight` / `TranslationLeftRight`）；
  目標與晶片內校正相同，但以標靶為基礎。
- **Depth scale 校正** —— 當光學元件位移時，修正絕對深度尺度。

D455 上的 Depth<->RGB：有標靶校正在具備 RGB 感測器的裝置
（D415/D435/D455）上**也會重新校正 RGB 外參**
（`RotationLeftRGB` / `TranslationLeftRGB` —— 彩色感測器相對於左側
imager 的關係）。這正是執行時對齊所依賴的 depth-to-color 關係
（`realsense2_camera` 中的 `align_depth:=true`，或 SDK 中的
`rs2::align`），因此重新執行它可修正錯位的 depth<->color 疊合。無標靶
模式僅校正深度（左/右），而**不會**校正 RGB，且僅限 API —— GUI 校正器
並不提供此模式。

## 工具提供的內容

Intel 以預先編譯、**僅支援 amd64** 的套件形式提供本工具（沒有 ARM64
建置版本）。該套件提供下列可執行檔：

| 可執行檔 | 用途 |
|---|---|
| `Intel.Realsense.DynamicCalibrator` | 有標靶動態校正（rectification + depth scale + RGB 外參），GUI 與 CLI |
| `Intel.Realsense.CustomRW` | 讀取 / 寫入儲存在相機上的校正表 |
| `opencv_interactive-calibration` | OpenCV 互動式校正輔助工具 |

## 先決條件

1. **主機 udev 規則。** 本工具需要對相機進行原始 USB 存取，這與 SDK
   其餘部分的權限需求相同。在主機上安裝一次即可：

   ```bash
   ./script/install_udev_rules.sh
   ```

   關於為何必須安裝在主機上、而非僅在容器內，請參閱 README 中的
   「RealSense udev Rules」一節。

2. **一個校正標靶。** 可依文件所述的比例列印官方標靶（連結見下方），
   或透過 Intel RealSense Dynamic Target 手機 app（iOS / Android）顯示。

3. **GUI 存取。** 具備 X11/Qt/OpenGL 堆疊的顯示環境，讓校正器視窗能夠
   開啟（`devel` image 已包含此環境並以 GUI 模式執行）。

## 執行方式

```bash
# Once the tool is available on PATH (see the availability note above):
Intel.Realsense.DynamicCalibrator     # interactive GUI calibration
```

將裝置放置在距離標靶 **600--850 mm** 處，並讓標靶的長條在視野中大致
呈垂直；整個過程都需要相機與標靶之間的相對移動（固定其中一個、移動
另一個）。避免反光（陽光、強光、手機螢幕眩光）—— 它們會使標靶無法被
偵測。有標靶流程接著會依序執行下列階段（User Guide 第 4.5.4 節與
附錄 B）：

1. **Rectification 階段** —— 在即時畫面中央疊加一組帶陰影的**藍色方格**。
   每個藍色方格代表視野中仍需標靶覆蓋的區域。緩慢移動相機（或標靶），
   讓標靶的黑/白方格與長條蓋過藍色方格；被覆蓋到的方格會逐一**清除**。
   重複直到全部清除為止。（若自動曝光搜尋開啟且標靶短暫遺失，影像會在
   搜尋時亮<->暗循環 —— 這是預期行為；若始終偵測不到，請重新調整位置
   以修正反光或距離。）中間結果會立即套用到串流上。
2. **Scale 階段** —— 自動開始；持續將標靶重新定位到不同、明顯區隔的
   位置，直到有 **15** 張標靶影像被接受（綠色進度條填滿即完成）。
3. **RGB 階段**（僅限 RGB 裝置 —— D415/D435/D455）—— 與 scale 階段相似，
   它會擷取 15 張標靶影像並校正 depth-to-RGB 的 UV 映射。完成後，左/右
   深度與 depth<->RGB 皆已校正完成。

完成後，結果會寫入相機。使用 `Intel.Realsense.CustomRW` 在校正前後備份
或還原校正表，並在之後驗證深度品質（若不滿意則重新執行）。

## 已知限制：depth<->color 對齊的殘餘誤差

即使校正成功，depth-to-color 疊合（`align`）仍會有一些殘餘誤差 ——
在物體邊緣附近最為明顯。已在硬體上驗證：它在 **D455 於 ~1--2 m 時
明顯可見**，而在 **D435 上略微存在**。這在很大程度上是**預期之中且屬於
幾何性質**的，並非校正失敗的徵兆。校正移除的是系統性的外參偏移；它
無法移除：

- **視差 / 遮擋（Parallax / occlusion）** —— 深度（左 IR）與 RGB 是不同的
  光學中心，因此在物體邊界處，一台相機會看到另一台看不到的部分。該區域
  無法由任何校正加以對齊 —— 這純屬幾何，也是邊緣「毛邊（fringing）」的
  主因。
- **深度誤差** —— 立體深度誤差大約隨距離平方成長，因此在 1--2 m 時，
  反投影到彩色影像的準確度較低（在有雜訊的邊緣與孔洞處更差）。
- **RGB 捲簾快門 / 同步** —— 彩色感測器為捲簾快門（rolling shutter）；
  在相機或場景移動時，它會相對於（全域式的）深度影格產生位移。

為何 D455 比 D435 差：**D455 的立體基線為 95 mm，而 D435 為 50 mm**。
較寬的基線可帶來更佳的長距離深度，但也造成較大的 depth<->RGB 視差，
因此殘餘在近/中距離時更明顯。

哪些做法仍有幫助（不會歸零）：

- 依使用情境選擇要對齊 depth->color 或 color->depth。
- 在對齊*之前*套用深度後處理（spatial / temporal / hole-filling）。
- 保持 depth/color 同步並拍攝靜態場景，以避免捲簾快門位移。
- 維持在相機的最佳深度範圍內，讓深度盡可能準確。

### 對齊方向：depth->color 對比 color->depth

這兩個方向**並不對稱** —— 它們是不同的演算法，這也是為何上述選擇很
重要（依 Intel 的 *Projection, Texture-Mapping and Occlusion* 白皮書
第 3.4 節）：

- **Color->depth**（將 color 對齊進 depth 影格）是成本較低的方向：對每個
  深度像素，查出其 uv-map 座標並在該處擷取 color。輸出為深度解析度，
  每像素一次查詢 —— 沒有孔洞。
- **Depth->color**（將 depth 對齊進 color 影格 —— 也就是
  `align_depth:=true` / `rs_aligned_depth.launch` 所產生的結果）則「稍微
  棘手一些」：一個 color 像素無法輕易反投影回 3D，因此改以每個深度像素
  **前向投影（forward-projected）**到 color 座標，當多個像素落在同一個
  color 像素上時保留最近的深度（z-buffering）。若彩色感測器解析度高於
  深度，某些 color 像素會沒有深度 -> 產生孔洞，SDK 則以將每個深度像素
  splatting 成 2x2 區塊來加以掩蓋。

因此出貨的預設值（`depth->color`）是較困難、易產生近似誤差的方向 ——
前向投影 + 2x2 補孔正是殘餘最常以邊緣毛邊形式出現的部分原因。能夠
處理深度解析度輸出的應用程式，可藉由選擇 `color->depth` 來避免此類
假影。

## 官方文件量化了哪些（以及沒有量化哪些）

Intel **並未**公布 depth<->color *對齊*誤差對距離的表格。最接近的官方
數據是：

- **深度 Z 準確度（絕對誤差）：+/-2%** —— D400-Series Datasheet
  （337029-017）Table 4-15「Depth Quality Specification」，同時列出
  Fill Rate >=99%、RMS Error <=2%、Temporal Noise <=1%。量測距離依型號
  而異：D43x 規格標示為「<=2 m, 80% ROI, HD」，D450/D455 規格為
  「<=4 m, 80% ROI, HD」。**這是深度準確度規格，而非對齊誤差規格** ——
  它界定 Z 值可以有多大誤差，而這只會*間接*影響到反投影至 color。並沒有
  逐距離（1 m / 2 m / 3 m）的細分。
- **對齊演算法及其誤差來源**在 *Projection, Texture-Mapping and
  Occlusion* 白皮書中以*定性*方式描述：第 3.4 節（串流對齊 —— 即上述
  兩個方向）與第 4 節（遮擋失效判定 —— 在物體邊界處一個 imager 會看到
  另一個看不到的部分；SDK 2.35+ 會在點雲計算過程中自動使這些被遮擋
  區域失效）。它解釋了邊緣誤差*為何*存在，但未給出量測數值。

結論：「1 m / 2 m / 3 m 殘餘」的數值**無法從 Intel 取得** —— 必須自行
內部量測（見下方）。

## 規劃中的量化實驗（已延後）

目標：將「D455 於 1--2 m 較差」這個定性觀察，轉化為距離對誤差的表格
（1 m / 2 m / 3 m 的誤差）。

**已延後（2026-07-03）。** 一次可信的量測需要**穩定、可控的設定**，
而目前唯一可用的 D455 安裝在一台運行中的 AMR 上（執行導航堆疊），
相機姿態不受控 —— 那是一個生產節點，而非量測平台。待有專用的靜態
設定可用時再執行此實驗。

設計：

- **指標（主要）：邊緣偏移（edge-offset）。** 將相機對準一個具有已知
  直邊的物體（一塊平板，或一個棋盤格）。量測對齊影格中**深度邊緣**與
  **color 邊緣**之間的像素偏移；再透過深度 Z 與相機內參換算為 mm。這與
  最初觀察到的邊緣毛邊相符，並可直接讀作「在 1 m 處邊緣偏差 X px / Y mm」。
- **指標（選用，更嚴謹）：棋盤格重投影（reprojection）。** 偵測 color
  中的棋盤格角點，對比從深度反投影出的角點；回報重投影誤差（px / mm）。
  當數值需要具說服力（報告 / 對外）時使用。
- **對齊方向：** 量測 **depth->color**（`align_depth:=true`，出貨的預設
  值），使數值對應到實際出貨的結果；選擇性地也可量測 `color->depth`
  以供比較。
- **擷取：** 在 1 / 2 / 3 m 各距離（量測至相機保護玻璃 —— Ground-Zero
  基準，datasheet 4.8）記錄同步的對齊 depth+color、靜態場景、相機離開
  機器人。在對齊*之前*套用深度後處理（spatial / temporal / hole-fill），
  如同生產環境。
- **對照組：** 同時執行 D455 與 D435，以重現由基線驅動的差異
  （95 mm 對比 50 mm）。標靶需照明良好、無反光、大致填滿 ROI。
- **輸出：** 一張距離對誤差的表格 + 疊合截圖，附加於此。

先決條件：執行中的容器必須確實發布
`/camera/aligned_depth_to_color/image_raw`。在 2026-07-03 之前建置的
執行時 image 預設使用未對齊的 `rs_camera.launch`；請重新建置以採用新的
對齊預設值，或在擷取時明確啟動對齊。

## 官方參考資料

- 校正總覽（工具、可列印標靶與指南下載）：
  <https://dev.realsenseai.com/docs/calibration/>
- Dynamic Calibration Tool 下載（Windows / Ubuntu 套件）：
  <https://www.intel.com/content/www/us/en/download/645988/29618/intel-realsense-d400-series-dynamic-calibration-tool.html>
- User Guide（PDF）：
  <https://cdrdv2-public.intel.com/840579/RealSense_D400_Dyn_Calib_User_Guide.pdf>
- Programmer's Guide（PDF）：
  <https://cdrdv2-public.intel.com/840422/RealSense_D400_Dyn_Calib_Programmer.pdf>
