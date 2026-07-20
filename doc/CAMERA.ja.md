**[English](CAMERA.md)** | **[繁體中文](CAMERA.zh-TW.md)** | **[简体中文](CAMERA.zh-CN.md)** | **[日本語](CAMERA.ja.md)**

# 実機 RealSense カメラでのテスト

`TEST.md` はビルド時の自動 smoke test を扱います。このページは、実機の Intel
RealSense カメラをコンテナ経由で検証する手動手順です。

コンテナは `/dev` をマウントした `privileged` で動作するため、ホスト上の USB
デバイスを認識します。`devel` イメージは ROS 1 ラッパー（`realsense2_camera`）に
加え、ソースビルドの librealsense SDK CLI ツール（`rs-enumerate-devices`、
`realsense-viewer`、`rs-*`）を同梱します。（`runtime` イメージはノード専用で、
ラッパーと SDK ライブラリは含みますが、これらの CLI ツールは含みません。）

## 0. ホストがカメラを認識しているか確認

```bash
lsusb | grep -i intel    # e.g. Intel RealSense (8086:0b07)
```

何も表示されない場合：データ対応ケーブルを使い、USB 3.0 ポートを優先し、
他のプロセスがカメラを掴んでいないことを確認してください。

## 1. コンテナに入る

```bash
just build    # first time, or after changes
just run      # interactive shell; ROS is auto-sourced (via ~/.bashrc.d)
```

## 2. クイックチェック -- カメラが検出されるか（SDK レベル）

```bash
rs-enumerate-devices        # lists model / serial / firmware
rs-enumerate-devices -s     # short form
```

これが通れば、カメラ、ドライバ、USB 権限がすべて機能していることを確認できます。

## 3. ROS 1 統合（本リポジトリの主なユースケース）

カメラノードを起動します：

```bash
roslaunch realsense2_camera rs_camera.launch
```

同じコンテナへの 2 つ目のシェル（ホストから `just exec bash`）で：

```bash
rostopic list                                   # expect /camera/... topics
rostopic hz /camera/depth/image_rect_raw        # confirm streaming (Hz)
rostopic echo /camera/color/image_raw -n 1      # one message
```

インタラクティブシェル（`just run` と `just exec bash`）は `~/.bashrc.d` 経由で
ROS を自動 source します。`.bashrc` を読まない非インタラクティブな
`just exec <cmd>` のみ、先に `source /opt/ros/${ROS_DISTRO}/setup.bash` が必要です。

> color トピックは `/camera/color/image_raw`、depth は
> `/camera/depth/image_rect_raw` -- 単一の `/camera/` namespace です。
> （`align_depth:=true` を有効化すると `/camera/aligned_depth_to_color/image_raw`
> が追加されます。）

## 4. 可視化（GUI）

```bash
realsense-viewer    # librealsense GUI
rviz                # ROS 1 visualization
```

`realsense-viewer`（および `rs-*` ツール）は、`devel` イメージがグラフィカルな
サンプルを有効化してコンパイルするソースビルドの librealsense SDK に由来します。
`rviz` は ROS 1 desktop ツールに由来します。両者（および必要な Qt/OpenGL/X スタック）
は `devel` で利用可能です。`runtime` イメージはノード専用で、SDK の GUI ツールは
同梱しません。コンテナの GUI モード + X11 マウントがディスプレイを処理します。

## 5. On-chip calibration（任意）

D400 シリーズは、通常のシーンから stereo depth パラメータを再 calibrate できます
-- calibration ターゲットは不要です。depth は 2 つの IR カメラを stereo マッチング
して計算され、工場出荷時のパラメータは時間とともにドリフト（温度、機械的衝撃、
輸送、経年劣化）し、それが余分な depth ノイズ、平らでない平面、ノイズの多いエッジ
として現れます。On-chip calibration はそのドリフトを補正します。これはファーム
ウェア更新とは独立しています：ファームウェアはカメラのファームウェアバージョンを
変え、calibration は depth 測定パラメータを調整します。ファームウェア更新後に一度
実行しておくと、良い健全性チェックになります。

`realsense-viewer` から実行します：depth センサーの **More** メニューを開いて
**On-Chip Calibration** を選び、適切なシーンに向けて calibrate を押します。

シーンの要件：

- テクスチャがあり、**0.5--2 m** の距離で、**有効な depth ピクセルが 50% 超**
  （のっぺりした壁、高反射面、遠すぎるものは避ける）。
- 「White wall」サブモードは例外です：IR プロジェクタをオンにして平らな白い壁に
  向けるときに **のみ** 使ってください。

### health-check スコアの読み方

calibrate 後、viewer は health-check スコアを報告します。**重要なのはその絶対値**
です -- 符号は補正の方向を表すだけで、「良い」「悪い」を意味しません。viewer の
`if >0.25` というガイダンスは `|health| > 0.25` を意味します。

| `|health|` | 意味 | アクション |
|---|---|---|
| 0 に近い（< 0.25） | すでに十分 calibrate 済み；今回の実行ではほとんど変化なし | 適用不要 |
| >= 0.25 | 目立つドリフト；補正に意味がある | 新しい calibration を適用 |
| 大きい（例：> 0.75） | 大きなドリフト、または不適切なシーン | 適用後、より良いシーンで再実行して確認 |

したがって `-0.45` というスコアは `|0.45| > 0.25`：意味のあるドリフトが検出された
ということで、新しい calibration の適用が推奨されます。負の符号は calibration が
失敗したことを **意味しません**。適用後は `realsense-viewer` で depth 画像を確認し
（より平らな平面、より少ないノイズ）、念のため別のシーンで再実行してください --
スコアが再び 0 近くになれば、calibration が収束したことを意味します。

ターゲットベースの経路（depth-to-color extrinsics も再 calibrate する Dynamic
Calibration Tool）は [CALIBRATION.ja.md](CALIBRATION.ja.md) で説明しています。

## トラブルシューティング

| 症状 | 確認事項 |
|---|---|
| `No device detected` | ホストの `lsusb` はカメラを認識しているか？ ケーブル / USB 3.0 ポート / 他のプロセスに掴まれていないか。コンテナは `privileged`（デフォルト）。 |
| `roslaunch: command not found` | インタラクティブシェルは `~/.bashrc.d` 経由で ROS を自動 source します。非インタラクティブな `just exec <cmd>` のみ、先に `source /opt/ros/${ROS_DISTRO}/setup.bash` が必要です。 |
| トピックにデータが流れない / `Reduced performance ... 2.1 port` | リンクが USB 2.x でネゴシエートされています。より低い profile（`depth_width:=480 depth_height:=270 depth_fps:=6 color_width:=424 color_height:=240 color_fps:=6`、D435 で ~6 Hz）か、ホストに直結した USB 3 SuperSpeed ポートを使ってください。 |
| `realsense-viewer` が開かない（X11） | ホストに X サーバがある；`echo $DISPLAY` が設定済み；GUI モードが `config/docker/setup.conf` で `[gui] mode = auto`。 |
