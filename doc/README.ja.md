**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

# Intel RealSense Docker コンテナ（ROS 1 Noetic）

[![CI](https://github.com/ycpss91255-docker/realsense_ros1/actions/workflows/main.yaml/badge.svg)](https://github.com/ycpss91255-docker/realsense_ros1/actions/workflows/main.yaml) [![License](https://img.shields.io/badge/License-Apache--2.0-blue?style=flat-square)](../LICENSE)

## TL;DR

コンテナ化された ROS 1 RealSense カメラ **アプリ**：`runtime` イメージのデフォルトコマンドがカメラノードを launch し、リアルタイムの **RGB + Depth** トピックを配信します。apt から `ros-noetic-realsense2-camera` と `ros-noetic-realsense2-description` をインストールし（これにより `librealsense2` が依存関係として推移的に取り込まれます）、USB アクセス用の udev ルールを同梱します。**Noetic（Ubuntu 20.04 focal）のみ**、マルチアーキ（x86_64 + ARM64 / Raspberry Pi）。

```bash
./script/install_udev_rules.sh      # once on the host (physical camera)
just build && just run -t runtime    # build + launch the camera app
# -> logs show "RealSense Node Is Up!" and depth/color streaming
```

> `just run` 単体は **devel** 開発シェルを開くだけでカメラアプリではありません -- `just run -t runtime` を使ってください。RGB-D ストリームの確認は [クイックスタート](#クイックスタート) を参照。

---

## 目次

- [概要](#概要)
- [機能](#機能)
- [前提条件](#prerequisites)
- [クイックスタート](#クイックスタート)
- [使い方](#使い方)
- [マルチマシン](#multi-machine-ros-1)
- [アンインストール / クリーンアップ](#uninstall--cleanup)
- [設定](#設定)
- [アーキテクチャ](#アーキテクチャ)
- [Smoke Tests](#smoke-tests)
- [ディレクトリ構成](#ディレクトリ構成)

---

## 概要

Intel RealSense 深度カメラ向けに、再現可能な ROS 1 環境を提供します。CI は **ROS 1 Noetic（Ubuntu 20.04 focal）** でイメージをビルドします -- 本リポジトリは単一ディストロで、ROS 1 Kinetic は **対象外** です。ROS apt リポジトリから `ros-noetic-realsense2-camera` と `ros-noetic-realsense2-description` パッケージをインストールし（`librealsense2` ライブラリはその依存関係として推移的に取り込まれます）、さらに上流の udev ルールを焼き込んでいるため、USB デバイスがコンテナ内で正しい権限のもとで起動します。マルチアーキテクチャのベースイメージは x86_64 と ARM64（Raspberry Pi、Jetson CPU モード）をサポートします。

## 機能

- **単一ディストロ**：ROS 1 Noetic（Ubuntu 20.04 focal）；Kinetic は対象外
- **Apt ベースのインストール**：ROS apt リポジトリから `ros-noetic-realsense2-camera` と `ros-noetic-realsense2-description`（`librealsense2` は推移的に取り込まれる）
- **Smoke Test**：Bats テストがビルド時に自動実行され、環境を検証
- **Docker Compose**：単一の `compose.yaml` で全ターゲットを管理
- **udev ルール**：RealSense USB デバイスアクセス用に事前設定済み
- **マルチアーキテクチャ**：x86_64 と ARM64（RPi、Jetson CPU モード）をサポート

## Prerequisites

ユーザーのエントリポイントは `just` で、これが Docker を駆動します。以下をホストに一度だけインストールしてください：

- **Docker Engine + Compose plugin。** ラッパーは `docker compose` を呼び出すため、
  Compose plugin が必要です。公式の便利スクリプトは Engine + Buildx + Compose を
  まとめてインストールします：

  ```bash
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER"   # log out/in so docker runs without sudo
  ```

  `docker compose version` で確認してください。（ディストロのパッケージ単体では
  Compose が欠けることがあります -- 例：`docker-compose-v2` なしの `docker.io` では
  `docker: unknown command: docker compose` になります。）

- **just**（コマンドランナー）。ビルド済みバイナリを `~/.local/bin` へ、sudo 不要：

  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin
  ```

  `~/.local/bin` が `PATH` にあることを確認し、`just --version` で確認してください。
  `just` をインストールしたくない場合のために、各レシピには生のフォールバック
  （`./script/<verb>.sh`）も用意されています。

- **（実機カメラ）ホストの udev ルール。** USB 経由で実機の RealSense を使うには、
  付属のルールをホストにインストールします（[RealSense udev ルール](#realsense-udev-rules) を参照）：

  ```bash
  ./script/install_udev_rules.sh
  ```

  これがないと、コンテナ内の非 root ユーザーは raw USB ノードを開けず、SDK がカメラを
  誤検出します -- 例：USB 3 デバイスが USB 2.1 として列挙される（"Reduced
  performance expected"）。

## クイックスタート

```bash
# 1. Build
just build

# 2. (physical camera) install the host udev rules once
./script/install_udev_rules.sh

# 3. Launch the camera app. The `runtime` service's default command is
#    `roslaunch realsense2_camera rs_aligned_depth.launch`; foreground shows the node logs:
just run -t runtime
#    ...or detached:
just run -d -t runtime
```

> カメラを使うだけのデプロイ機（例：カメラだけ動かす Raspberry Pi）は step 1 を省略できます。
> `just build` は開発用の **devel** イメージ（フル開発ツール -- やや大きい）をビルドします。
> `just run -t runtime` は初回利用時に最小限の runtime イメージを自動ビルドするため、
> カメラアプリに事前の `just build` は不要です。

### See the RGB-D data

**CLI** -- カラー + Depth トピックが配信されているか確認します（インタラクティブな exec には `roslaunch`/`rostopic` があります）：

```bash
just exec -t runtime bash -ic 'rostopic hz /camera/color/image_raw'
just exec -t runtime bash -ic 'rostopic hz /camera/depth/image_rect_raw'
```

**Visual** -- `rqt` で画像ストリームを表示します（`devel` イメージには `rqt_image_view` が同梱）：

```bash
just run -t devel
# inside the container:
roslaunch realsense2_camera rs_aligned_depth.launch &   # start the camera
rosrun rqt_image_view rqt_image_view             # pick /camera/color/image_raw and /camera/depth/image_rect_raw
```

> `-t` なしの `just run` は **devel** 開発シェルを開くだけでカメラアプリではありません -- アプリには
> `just run -t runtime` を使ってください。launch 引数を上書きするには（例: point cloud を有効化）、
> デフォルトの launch を置き換える低レベルコマンドを使います：
> `docker compose run --rm runtime roslaunch realsense2_camera rs_camera.launch filters:=pointcloud`。
> `just run -t runtime <cmd>` 形式の上書きは upstream で壊れており、修正中です
> （[base#679](https://github.com/ycpss91255-docker/base/issues/679)）。他の低レベルの等価コマンドは
> [使い方](#使い方) を参照。

> **USB 2.x:** カメラの log に `Reduced performance ... 2.1 port` が出てトピックにデータが
> 流れない場合、リンクが USB 2.x でネゴシエートされ、デフォルト profile が重すぎます。
> 低めの profile を使ってください。例：
> `docker compose run --rm runtime roslaunch realsense2_camera rs_camera.launch depth_width:=480 depth_height:=270 depth_fps:=6 color_width:=424 color_height:=240 color_fps:=6`
> （D435 over USB 2 で実測 -- RGB + depth が ~6 Hz で安定）。完全なデフォルト profile には、
> hub を介さず USB 3 ケーブルでホストの SuperSpeed ポートへ直結してください。

## 使い方

### ランタイム

ユーザーのエントリポイントは `just` です（リポジトリルートの `justfile` は base
サブツリーへのシンボリックリンク）。各レシピは `script/` 配下のラッパースクリプトに
1:1 で転送され、引数はそのまま渡されます。`--` 区切りは不要です。

```bash
just build                       # ビルド（デフォルト：devel）
just build test                  # devel-test ゲートをビルド
just run                         # 起動（例：just run -d）
just exec                        # 実行中のコンテナに入る
just stop                        # コンテナを停止・削除
just setup                       # setup.conf から .env + compose.yaml を再生成

docker compose build runtime     # 同等の低レベルコマンド
docker compose up runtime        # 起動
docker compose exec runtime bash # 実行中のコンテナに入る
```

### カスタム launch 引数

`runtime` イメージのデフォルトコマンドは `roslaunch realsense2_camera
rs_aligned_depth.launch` です。launch 引数を渡すには、デフォルトの launch を置き換える
低レベルの `docker compose run` 形式を使います：

```bash
# point cloud を有効化
docker compose run --rm runtime roslaunch realsense2_camera rs_camera.launch filters:=pointcloud

# depth を color にアライン
docker compose run --rm runtime roslaunch realsense2_camera rs_camera.launch align_depth:=true

# USB 2.x リンク向けの低減 profile（~6 Hz）
docker compose run --rm runtime roslaunch realsense2_camera rs_camera.launch \
  depth_width:=480 depth_height:=270 depth_fps:=6 \
  color_width:=424 color_height:=240 color_fps:=6
```

`just run -t runtime <cmd>` 形式の上書きは upstream で壊れているため
（[base#679](https://github.com/ycpss91255-docker/base/issues/679)）、上記の
`docker compose run` 形式を使ってください。

### Smoke tests（test ステージ）

Smoke tests はビルド時に自動実行されます。テスト失敗時はビルドも失敗します。
`devel-test` ステージは lint（ShellCheck + Hadolint）と bats スイートを実行し、
`runtime-test` ステージは runtime イメージに対してチェックを実行します。

```bash
just build test
# または
docker compose --profile test build test
```

## Multi-machine (ROS 1)

ROS 1 は中央 master（`roscore`）を使います。別のマシンからカメラを利用するには、
いずれか 1 台の host で master を実行し、すべてのノードをそれに向け、各ノードが
ルーティング可能なアドレスを通告するようにします。これらはデプロイごとの runtime
値なので、**`.env`**（手書きの workload overlay -- `env_file: - .env` でコンテナに
注入され、`just run` 単独で適用され、再生成されることはなく、git で無視される）に
記述します。machine-baked / build パラメータ（GPU、privileged、マウント）は
`config/docker/setup.conf` に残します。

このリポジトリはすでに `[network] mode = host` を同梱しているため、master の
port（`11311`）と各ノードの動的 TCPROS port は host の実際の LAN IP 上にあり、
他のマシンから到達できます。

**カメラ側マシン（slave -- 例: Raspberry Pi）：** `.env` に以下を追加します

```ini
ROS_MASTER_URI=http://<master-ip>:11311   # the host running roscore
ROS_IP=<this-machine-ip>                   # this machine's LAN IP (see note)
```

その後、追加フラグなしで起動します -- compose が `.env` を注入します：

```bash
just run -t runtime
```

`.env` にリモートの `ROS_MASTER_URI` が設定されている場合、slave は master を
自動的に待ちます。entrypoint は `roslaunch --wait` で起動し、master に到達できる
ようになるまでブロックしてから起動します。起動順序はもう問題になりません --
slave は master より先に起動しても（例: 起動時に自動起動）、master が現れた時点で
きれいに登録され、未登録のゾンビノードになることはありません。

リモートの `ROS_MASTER_URI` を持つ slave は、オプトインの watchdog により
**master が起動後に再起動しても自己修復できます**。同じポートで再起動した master は
TCP 到達可能なままなので、roslaunch とノードは動き続けたまま静かに登録解除されます
（`rostopic list` には名前が残るが `rosnode list` から `/camera` が消える）-- これは
`restart: unless-stopped` では捕捉できません。有効化すると、entrypoint は*現在の*
master 上のノード登録を監視し、デバウンス窓の後に `roslaunch --wait` を再起動して
新しい master へ再登録させます。

watchdog は **オプトイン（デフォルト無効）** で、base の `[lifecycle] restart = no`
と整合します。`.env` で有効化しノブを調整します：

```ini
WATCHDOG_ENABLED=1                        # デフォルト無効；1 で watchdog を有効化
WATCHDOG_INTERVAL=15                      # チェック間隔（秒）
WATCHDOG_TIMEOUT=5                        # rosnode list クエリごとのタイムアウト（秒）
WATCHDOG_FAILURES=3                       # 再起動までの連続失敗回数（~45 秒）
WATCHDOG_ROSNODE=/camera/realsense2_camera  # ヘルスシグナルとなるノード
```

デフォルトはブリップ耐性重視です（master 再起動は数分のダウンなので、1-2 秒の
ネットワークブリップで再起動してはならない）。`just stop` は watchdog をきれいかつ
高速に停止します。watchdog はリモート master で `roslaunch` を起動する場合のみ有効で、
ローカル／未設定の master やその他のコマンドは変更されません。watchdog の有効・無効
にかかわらず、上記の `--wait` ゲートはリモート master に対して自動的に適用されます。

**master 側マシン：** master を実行して購読します（任意の ROS 1 環境、例えば
`ros_distro` 環境）：

```bash
export ROS_IP=<master-ip>
roscore &
rostopic hz /camera/color/image_raw      # data arriving from the camera machine
```

> **`ROS_IP` を必ず設定してください。** これがないと、ノードは自身の*ホスト名*を
> master に通告します。その名前を解決できないリモートの購読者は、`rostopic list`
> ではトピックを見られても、データは一切受信できません（典型的な「list は出るが
> echo がハングする」症状）。`ROS_IP` をそのマシンの LAN IP に設定すると、
> ルーティング可能なアドレスを通告するようになります。

Raspberry Pi 5（カメラ/slave）から直結リンク経由で host master に接続して実測：
`/camera/color/image_raw` が master 側に ~28 Hz で届きました。

## Uninstall / Cleanup

```bash
just stop      # stop and remove the running containers
just prune     # remove this repo's images + dangling build cache (see `just prune -h`)
```

リポジトリがホストに配置したものを完全に削除するには：

- **イメージ / ビルドキャッシュ：** `just prune`（特定のイメージは `docker image rm <tag>`）。
- **ホストの udev ルール**（インストールした場合のみ）：

  ```bash
  sudo rm -f /etc/udev/rules.d/99-realsense-libusb.rules
  sudo udevadm control --reload-rules && sudo udevadm trigger
  ```

- **リポジトリ：** クローンしたディレクトリを削除します。

## 設定

### 設定サーフェス（setup.conf）

実際の設定サーフェスは `config/docker/setup.conf` です。`just setup` がそこから
`.env` と `compose.yaml` を生成するため、`.env` は生成された成果物であり、手で
編集すべきではありません。`setup.conf` を編集（または `just setup-tui`）してから
`just setup` を再実行してください。

`setup.conf` はセクションに分かれています -- `[image]`、`[build]`、`[deploy]`、
`[gui]`、`[network]`、`[security]`、`[resources]`、`[environment]`、`[tmpfs]`、
`[devices]`、`[volumes]`。たとえば `[deploy]` セクションは GPU ランタイムキー
（`gpu_mode`、`gpu_count`、`gpu_capabilities`、`gpu_runtime`）を持ち、`[image]` は
リテラルな `image_name` キーではなく命名規則からイメージ名を導出します。

### RealSense udev ルール

udev ルールはコンテナ内だけでなく **ホスト** にインストールする必要があります。
コンテナには `udevd` がなく、デバイスノードの権限は `/dev` bind mount で共有される
ホストの `devtmpfs` inode 上にあるため、イメージに焼き込まれたルールだけでは機能
しません。ホストのルールがないと、コンテナ内の非 root ユーザーは raw USB ノードを
開けず、SDK がカメラを誤検出します（USB 2.0、`Product Line not supported` を報告、
またはファームウェア更新に失敗）。[IntelRealSense/librealsense#12022](https://github.com/IntelRealSense/librealsense/issues/12022)
を参照してください。

付属スクリプトでホストに一度だけインストールします（`sudo` を使用）：

```bash
./script/install_udev_rules.sh
```

スクリプトは `config/realsense/99-realsense-libusb.rules` を `/etc/udev/rules.d/`
にコピーして udev をリロードします。その後カメラを再接続してください。コンテナ自体は
`privileged` モードで実行され、`/dev` がマウントされます
（[doc/adr/00000001-realsense-requires-privileged.md](adr/00000001-realsense-requires-privileged.md) を参照）。

## アーキテクチャ

### Docker ビルドステージ図

```mermaid
graph TD
    EXT1["test-tools image\n(ghcr test-tools or test-tools:local)"]
    EXT2["ros:noetic-ros-base-focal"]

    EXT1 --> ttstage["test-tools-stage"]

    EXT2 --> sys["sys"]

    sys --> develbase["devel-base"]
    develbase --> devel["devel\n(shipped)"]
    devel --> develtest["devel-test (ephemeral)\nlint + bats /smoke_test/"]

    sys --> runtimebase["runtime-base"]
    runtimebase --> runtime["runtime\n(shipped)\nrealsense2_camera + udev rules"]
    runtime --> runtimetest["runtime-test (ephemeral)\nruntime smoke"]

    ttstage --> develtest
```

### ステージ説明

| ステージ | FROM | 用途 |
|----------|------|------|
| `test-tools-stage` | `${TEST_TOOLS_IMAGE}`（マルチアーキの ghcr test-tools、または `test-tools:local`） | ShellCheck + Hadolint + Bats、出荷しない |
| `sys` | `ros:noetic-ros-base-focal` | 共通ベース：ユーザー、ロケール、タイムゾーン（base v0.41.0 build contract） |
| `devel-base` | `sys` | 開発ツール + ROS 1 Noetic + RealSense パッケージ |
| `devel` | `devel-base` | 出荷する開発イメージ（デフォルト CMD `bash`） |
| `devel-test` | `devel` + `test-tools-stage` | Lint + smoke tests、ビルド後に破棄（一時的） |
| `runtime-base` | `sys` | 最小ベース（`sudo`） |
| `runtime` | `runtime-base` | 出荷するランタイムイメージ：RealSense パッケージ + udev ルール（デフォルト CMD `roslaunch realsense2_camera rs_aligned_depth.launch`） |
| `runtime-test` | `runtime` | runtime smoke、ビルド後に破棄（一時的） |

## Smoke Tests

ビルド時の自動テストは [TEST.md](test/TEST.md)、実機カメラでのテストは [CAMERA.md](CAMERA.md)、動的キャリブレーションツールは [CALIBRATION.md](CALIBRATION.md) を参照。

## ディレクトリ構成

```text
realsense_ros1/
├── Dockerfile                   # マルチステージビルド
├── LICENSE
├── README.md
├── justfile -> .base/script/docker/justfile        # シンボリックリンク（ユーザーエントリポイント）
├── .hadolint.yaml -> .base/.hadolint.yaml          # シンボリックリンク
├── .base/                       # base サブツリー（読み取り専用）
├── script/
│   ├── entrypoint.sh            # コンテナエントリポイント（リポジトリ所有）
│   ├── install_udev_rules.sh    # ホストに RealSense udev ルールをインストール（リポジトリ所有）
│   ├── build.sh -> ../.base/script/docker/wrapper/build.sh   # シンボリックリンク
│   ├── run.sh   -> ../.base/script/docker/wrapper/run.sh     # シンボリックリンク
│   ├── exec.sh  -> ../.base/script/docker/wrapper/exec.sh    # シンボリックリンク
│   ├── stop.sh  -> ../.base/script/docker/wrapper/stop.sh    # シンボリックリンク
│   ├── prune.sh -> ../.base/script/docker/wrapper/prune.sh   # シンボリックリンク
│   ├── setup.sh -> ../.base/script/docker/wrapper/setup.sh   # シンボリックリンク
│   ├── setup_tui.sh -> ../.base/script/docker/wrapper/setup_tui.sh  # シンボリックリンク
│   └── hooks/                   # pre/ + post/ ラッパーフック
├── config/
│   ├── docker/
│   │   └── setup.conf           # 設定サーフェス（.env/compose.yaml はここから生成）
│   ├── shell/
│   │   └── bashrc.d/10-ros-source.sh  # インタラクティブシェル向けに ROS を source
│   └── realsense/
│       └── 99-realsense-libusb.rules  # RealSense udev ルール
├── doc/
│   ├── README.zh-TW.md          # 繁体字中国語
│   ├── README.zh-CN.md          # 簡体字中国語
│   ├── README.ja.md             # 日本語
│   ├── adr/                     # アーキテクチャ決定記録（ADR）
│   ├── CAMERA.md                # 実機カメラでの手動テスト
│   ├── CALIBRATION.md           # 動的キャリブレーションツール解説
│   ├── changelog/CHANGELOG.md
│   └── test/
│       └── TEST.md              # ビルド時の自動 smoke テスト
├── .github/workflows/
│   └── main.yaml                # CI（base の再利用可能な build/release ワーカーを呼び出す）
└── test/
    └── smoke/                   # リポジトリ所有の bats テスト
        ├── ros_env.bats
        └── install_udev_rules.bats   # （ヘルパーと追加の .bats は .base/test/smoke/ から）
```
