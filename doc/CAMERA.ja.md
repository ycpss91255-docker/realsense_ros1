**[English](CAMERA.md)** | **[繁體中文](CAMERA.zh-TW.md)** | **[简体中文](CAMERA.zh-CN.md)** | **[日本語](CAMERA.ja.md)**

# 物理的な RealSense カメラを使ったテスト

`TEST.md` はビルド時に自動実行されるスモークテストを扱います。このページは、コンテナを通じて実物の Intel RealSense カメラを検証するための手動手順です。

コンテナは `/dev` をマウントした状態で `privileged` として動作するため、ホスト上の USB デバイスを認識できます。イメージには ROS 1 ラッパー（`realsense2_camera`）に加えて、librealsense SDK の CLI ツール（`rs-enumerate-devices`、`realsense-viewer`、`rs-*`）が同梱されています。

## 0. ホストがカメラを認識しているか確認する

```bash
lsusb | grep -i intel    # e.g. Intel RealSense (8086:0b07)
```

何も表示されない場合: データ通信対応のケーブルを使い、USB 3.0 ポートを優先し、他のプロセスがカメラを掴んでいないことを確認してください。

## 1. コンテナに入る

```bash
just build    # first time, or after changes
just run      # interactive shell; ROS is auto-sourced (via ~/.bashrc.d)
```

## 2. クイックチェック -- カメラが検出されているか（SDK レベル）

```bash
rs-enumerate-devices        # lists model / serial / firmware
rs-enumerate-devices -s     # short form
```

これに成功すれば、カメラ・ドライバ・USB 権限がすべて正しく動作していることが確認できます。

## 3. ROS 1 統合（本リポジトリの主要ユースケース）

カメラノードを起動します:

```bash
roslaunch realsense2_camera rs_camera.launch
```

同じコンテナへの 2 つ目のシェル（ホストから `just exec bash`）で:

```bash
rostopic list                                   # expect /camera/... topics
rostopic hz /camera/depth/image_rect_raw        # confirm streaming (Hz)
rostopic echo /camera/color/image_raw -n 1      # one message
```

インタラクティブシェル（`just run` と `just exec bash`）は `~/.bashrc.d` を介して ROS を自動的に source します。`.bashrc` を読み込まない非インタラクティブな `just exec <cmd>` のみ、先に `source /opt/ros/${ROS_DISTRO}/setup.bash` が必要です。

> カラートピックは `/camera/color/image_raw`、depth トピックは `/camera/depth/image_rect_raw` で、いずれも単一の `/camera/` 名前空間にあります。（`align_depth:=true` を有効にすると `/camera/aligned_depth_to_color/image_raw` が追加されます。）

## 4. 可視化（GUI）

```bash
realsense-viewer    # librealsense GUI
rviz                # ROS 1 visualization
```

devel イメージには ROS 1 デスクトップツール一式がインストールされているため、`realsense-viewer` と `rviz`（およびそれらが必要とする Qt/OpenGL/X スタック）の両方が利用できます。コンテナの GUI モードと X11 マウントがディスプレイ表示を処理します。

## 5. オンチップキャリブレーション（任意）

D400 シリーズは、通常のシーンからステレオ depth パラメータを再キャリブレーションできます -- キャリブレーション用のターゲットは不要です。Depth は 2 つの IR カメラのステレオマッチングによって計算されますが、工場出荷時のパラメータは時間の経過とともにドリフト（温度、機械的衝撃、輸送、経年劣化）し、それが余分な depth ノイズ、平面が平らにならない、エッジのノイズとして現れます。オンチップキャリブレーションはこのドリフトを補正します。これはファームウェア更新とは独立しています: ファームウェアはカメラのファームウェアバージョンを変更し、キャリブレーションは depth 測定パラメータを調整します。ファームウェア更新後に一度実行しておくと、良い健全性チェックになります。

`realsense-viewer` から実行します: depth センサーの **More** メニューを開いて **On-Chip Calibration** を選択し、適切なシーンに向けて calibrate を押します。

シーンの要件:

- テクスチャがあり、**0.5--2 m** の距離で、**有効な depth ピクセルが 50% 超**であること（無地の壁、強く反射する面、遠すぎる対象は避ける）。
- 「White wall」サブモードは例外です: IR プロジェクタをオンにして平らな白い壁に向けるときに **のみ** 使用してください。

### 健全性チェックスコアの読み方

キャリブレーション後、ビューアは健全性チェックスコアを報告します。**重要なのはその絶対値です** -- 符号は補正の方向を示すだけで、「良い」「悪い」を意味しません。ビューアの `if >0.25` というガイダンスは `|health| > 0.25` を意味します。

| `|health|` | 意味 | アクション |
|---|---|---|
| 0 に近い（< 0.25） | すでに十分にキャリブレーションされており、今回の実行ではほとんど変化がなかった | 適用不要 |
| >= 0.25 | 目立つドリフトがあり、補正には意味がある | 新しいキャリブレーションを適用する |
| 大きい（例: > 0.75） | 大きなドリフト、または不適切なシーン | 適用し、より良いシーンで再実行して確認する |

したがって `-0.45` のスコアは `|0.45| > 0.25` であり、意味のあるドリフトが検出されたことを示すため、新しいキャリブレーションの適用が推奨されます。負の符号はキャリブレーションが失敗したことを **意味しません**。適用後、`realsense-viewer` で depth 画像を確認してください（平面がより平らに、ノイズが減る）。念のため、別のシーンで再実行してください -- スコアが再び 0 付近に戻れば、キャリブレーションが収束したことを意味します。

ターゲットを用いる方法（depth-to-colour の外部パラメータも再キャリブレーションする Dynamic Calibration Tool）は [CALIBRATION.md](CALIBRATION.md) で説明しています。

## トラブルシューティング

| 症状 | 確認事項 |
|---|---|
| `No device detected` | ホストの `lsusb` がカメラを認識しているか? ケーブル / USB 3.0 ポート / 他のプロセスに掴まれていないか。コンテナが `privileged`（デフォルト）か。 |
| `roslaunch: command not found` | インタラクティブシェルは `~/.bashrc.d` を介して ROS を自動 source します。非インタラクティブな `just exec <cmd>` のみ、先に `source /opt/ros/${ROS_DISTRO}/setup.bash` が必要です。 |
| トピックにデータが流れない / `Reduced performance ... 2.1 port` | リンクが USB 2.x でネゴシエートされています。より低いプロファイル（`depth_width:=480 depth_height:=270 depth_fps:=6 color_width:=424 color_height:=240 color_fps:=6`、D435 で約 6 Hz）を使うか、ホストに直結した USB 3 SuperSpeed ポートを使ってください。 |
| `realsense-viewer` が開かない（X11） | ホストに X サーバーがあるか、`echo $DISPLAY` が設定されているか、`config/docker/setup.conf` で GUI モードが `[gui] mode = auto` になっているか。 |
