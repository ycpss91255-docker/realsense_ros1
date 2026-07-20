**[English](CALIBRATION.md)** | **[繁體中文](CALIBRATION.zh-TW.md)** | **[简体中文](CALIBRATION.zh-CN.md)** | **[日本語](CALIBRATION.ja.md)**

# RealSense Dynamic Calibration Tool

このページでは **Intel RealSense D400 シリーズ Dynamic Calibration Tool**
（`librscalibrationtool`）について説明します：何をするツールか、`CAMERA.md` の
on-chip calibration とどう違うか、そして実行方法です。

> **入手性に関する注記（ROS 1 / focal）：** このツールは **現時点で本リポジトリの
> `devel` イメージには同梱されていません。** ROS 2 版（`realsense_ros2`）は Intel の
> `pool/jammy` の `.deb` から同梱していますが、そのパッケージは **amd64 専用で
> Ubuntu リリースに紐付いて**おり、本リポジトリのベースは **Ubuntu 20.04 focal**
> （ROS 1 Noetic）です。focal 対応ビルドの同梱は後続作業に先送りしています。それまでは
> ホスト上（または手動でインストールした focal コンテナ内）でツールを実行してください。
> 以下のワークフローはツールが利用可能になれば同様に適用できます。

## 概要（on-chip calibration との違い）

D400 カメラには 2 つの異なる calibration 経路があります：

| | On-chip calibration | Dynamic Calibration Tool |
|---|---|---|
| 解説場所 | [CAMERA.ja.md](CAMERA.ja.md)（section 5） | このページ |
| 実行元 | `realsense-viewer`（内蔵） | `Intel.Realsense.DynamicCalibrator` |
| ターゲットの要否 | 不要 -- テクスチャのある任意のシーン | 必要 -- 印刷（またはスマホアプリ）のターゲット |
| calibrate 対象 | depth の rectification のみ（stereo IR） | rectification + depth scale、**加えて** RGB デバイスでは **RGB extrinsics** |
| 使う場面 | depth ノイズ / 平面が平らでない | ターゲットベースの入念な再 calibration が必要なとき |

Dynamic calibration が最適化するのは **extrinsic** パラメータのみ -- imager 間の回転と
並進 -- であり、intrinsic（焦点距離、主点、歪み）は工場出荷時の calibration のまま
です。User Guide（v2.11）によれば、2 つの動作モード（targeted と target-less）で
2 種類の calibration を提供します。`Intel.Realsense.DynamicCalibrator` の GUI/CLI は
**targeted** calibration を実行します：

- **Rectification calibration** -- 2 つの IR imager のエピポーラ幾何を再整列します
  （`RotationLeftRight` / `TranslationLeftRight`）。目的は on-chip calibration と
  同じですが、こちらはターゲットベースです。
- **Depth scale calibration** -- 光学素子がずれたときに絶対 depth scale を補正します。

D455 における depth<->RGB：targeted calibration は、RGB センサーを持つデバイス
（D415/D435/D455）では **RGB extrinsics も再 calibrate** します
（`RotationLeftRGB` / `TranslationLeftRGB` -- 左 imager に対する color センサー）。これは
まさに runtime alignment（`realsense2_camera` の `align_depth:=true`、または SDK の
`rs2::align`）が依存する depth-to-color の関係なので、再実行すればずれた
depth<->color オーバーレイを修正できます。target-less モードは depth（左/右）のみを
calibrate し RGB は **calibrate しません**。また API 専用で、GUI calibrator では
提供されません。

## ツールが提供するもの

Intel はこのツールをプリコンパイル済みの **amd64 専用** パッケージ（ARM64 ビルドなし）
として配布しています。パッケージは以下の実行ファイルを提供します：

| 実行ファイル | 用途 |
|---|---|
| `Intel.Realsense.DynamicCalibrator` | Targeted dynamic calibration（rectification + depth scale + RGB extrinsics）、GUI と CLI |
| `Intel.Realsense.CustomRW` | カメラに保存された calibration テーブルの読み書き |
| `opencv_interactive-calibration` | OpenCV interactive calibration ヘルパー |

## 前提条件

1. **ホストの udev ルール。** ツールはカメラへの raw USB アクセスを必要とし、
   これは SDK の他の部分と同じ権限要件です。ホスト上で一度だけインストールします：

   ```bash
   ./script/install_udev_rules.sh
   ```

   なぜコンテナ内だけでなくホストに必要なのかは、README の「RealSense udev Rules」
   section を参照してください。

2. **calibration ターゲット。** 公式ターゲットを規定のスケールで印刷する（下記リンク）
   か、Intel RealSense Dynamic Target スマホアプリ（iOS / Android）で表示します。

3. **GUI アクセス。** calibrator のウィンドウを開けるよう、X11/Qt/OpenGL スタックを
   備えたディスプレイが必要です（`devel` イメージはすでにこれを含み GUI モードで
   動作します）。

## 実行方法

```bash
# Once the tool is available on PATH (see the availability note above):
Intel.Realsense.DynamicCalibrator     # interactive GUI calibration
```

デバイスをターゲットから **600--850 mm** の位置に置き、ターゲットのバーが視野内で
おおよそ垂直になるようにします。作業中はカメラとターゲットの間の相対移動が常に必要
です（一方を固定し、もう一方を動かす）。反射（日光、明るい照明、スマホ画面のグレア）
は避けてください -- ターゲットが検出されなくなります。targeted フローは以下のフェーズを
順に実行します（User Guide section 4.5.4 および Appendix B）：

1. **Rectification フェーズ** -- ライブビューの中央に、シェーディングされた
   **青い四角** のブロックが重ねて表示されます。各青い四角は、まだターゲットで
   カバーが必要な視野の領域を示します。ターゲットの黒/白の四角とバーが青い四角に
   重なるよう、カメラ（またはターゲット）をゆっくり動かします。カバーされた四角は
   1 つずつ **消えて** いきます。すべて消えるまで繰り返します。（auto-exposure サーチが
   有効でターゲットが一時的に見失われると、サーチ中に画像が明<->暗を循環します --
   これは想定内です。まったく検出されない場合は、反射や距離を直すよう位置を調整して
   ください。）中間結果はストリームに即座に適用されます。
2. **Scale フェーズ** -- 自動的に開始します。**15** 枚のターゲット画像が受理される
   （緑のプログレスバーが満了まで満たされる）まで、ターゲットを異なる別々の位置へ
   移動し続けてください。
3. **RGB フェーズ**（RGB デバイスのみ -- D415/D435/D455） -- scale フェーズと同様に、
   15 枚のターゲット画像をキャプチャし、depth-to-RGB の UV マッピングを calibrate
   します。その後、左/右の depth と depth<->RGB の両方が calibrate されます。

完了すると結果がカメラに書き込まれます。前後で calibration テーブルをバックアップ
または復元するには `Intel.Realsense.CustomRW` を使い、あとで depth 品質を検証して
ください（満足できない場合は再実行）。

## 既知の制限：depth<->color アライメントの残差誤差

calibration が成功しても、depth-to-color オーバーレイ（`align`）にはなお残差誤差が
あります -- 最も目立つのは物体のエッジ付近です。ハードウェアで確認済み：
**D455 では ~1--2 m で明確に目立ち**、**D435 ではわずかに存在** します。これは主に
**想定内で幾何学的なもの** であり、calibration が失敗した兆候ではありません。
calibration は系統的な extrinsic のオフセットを除去しますが、以下は除去できません：

- **視差 / オクルージョン** -- depth（左 IR）と RGB は光学中心が異なるため、物体の
  境界では一方のカメラが見えているものをもう一方は見られません。この領域はいかなる
  calibration でも整列できません -- 純粋に幾何学の問題であり、エッジの「フリンジ」の
  主因です。
- **Depth 誤差** -- stereo depth 誤差はおおよそ距離の 2 乗で増大するため、1--2 m では
  color 画像への逆投影の精度が下がります（ノイズの多いエッジや穴でより悪化）。
- **RGB のローリングシャッター / 同期** -- color センサーはローリングシャッターで、
  カメラやシーンの動きがあると（グローバルな）depth フレームに対してずれます。

D455 が D435 より悪い理由：**D455 は 95 mm の stereo baseline、D435 は 50 mm** です。
baseline が広いほど遠距離の depth は良くなりますが depth<->RGB の視差が大きくなるため、
近～中距離では残差がより目立ちます。

依然として有効な対策（ゼロにはなりません）：

- ユースケースに応じて depth->color と color->depth のどちらに align するか選ぶ。
- align の *前* に depth の後処理（spatial / temporal / hole-filling）を適用する。
- depth/color を同期させ、静止シーンを撮ってローリングシャッターのずれを避ける。
- カメラの最適 depth 範囲内に収め、depth をできるだけ正確にする。

## 公式リファレンス

- Calibration overview（ツール、印刷用ターゲット、ガイドのダウンロード）：
  <https://dev.realsenseai.com/docs/calibration/>
- Dynamic Calibration Tool ダウンロード（Windows / Ubuntu パッケージ）：
  <https://www.intel.com/content/www/us/en/download/645988/29618/intel-realsense-d400-series-dynamic-calibration-tool.html>
- User Guide（PDF）：
  <https://cdrdv2-public.intel.com/840579/RealSense_D400_Dyn_Calib_User_Guide.pdf>
- Programmer's Guide（PDF）：
  <https://cdrdv2-public.intel.com/840422/RealSense_D400_Dyn_Calib_Programmer.pdf>
