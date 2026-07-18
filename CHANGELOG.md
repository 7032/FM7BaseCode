# Changelog

本ファイルは FM7BaseCode の主要な変更点を記録します。 書式は [Keep a Changelog](https://keepachangelog.com/ja/) に準拠し、 プロジェクトに版番号が無いため、 見出しは日付ベース (新しい順) で記載します。

## 2026-07-17

### Added
- **機能デモ集 `functest/` を追加**: 本テンプレートとは独立に単体で起動する機能デモを収録。 第 1 弾としてマウスカーソルデモ ([functest/mouse/](functest/mouse/)) を追加。 **バスマウス / インテリジェントマウス (ポート 1/2)** の両方式に対応し、 キー `0`/`1`/`2` で方式を切替 (現在の方式は画面に常時表示)。 画面上の 4 つのボタンをマウス左クリックすると **画面モードを切替** (640x200 8色=全機種 / 320x200 4096色=FM77AV 以降 / 640x400 8色=AV40系 / 320x200 262144色=AV40系。 機種を実行時判別し非対応モードのボタンは無効表示、 切替時もカーソルの物理位置と速度を維持)。 左右ボタンのインジケータと診断用の生読み値も表示。 F-BASIC を使わない 2D ディスク直接ブートで、 FM-7 / FM77AV / FM77AV40 / FM77AV40EX の全機種が同じディスクから起動する
- 同梱物は起動用ディスクイメージ `mousedemo.d77` (ドライブ 0 にセットするだけで起動)、 6809 アセンブラソース (メイン CPU 側 / サブ CPU 側)、 ヘッドレステスト一式。 ソースからの再ビルドは各デモのディレクトリで `make` (lwtools の LWASM に加えて **Node.js** が必要。 ディスクイメージ組み立ての `mkd77.mjs` が Node.js 上で動作するため)
- functest のヘッドレステストは公開エミュレータ core ([WebM7](https://github.com/7032/WebM7)) 上でデモをブートし、 各画面モードの VRAM 全プレーンを期待値モデルとバイト単位で照合する方式 (`make test`)。 core の場所を環境変数 `WEBM7_DIR`、 利用者所有の ROM 一式の場所を `FM7_ROM_DIR` で指定して実行する (どちらかが見つからない場合はエラーにならずスキップして正常終了)

### Docs
- README に「4. 機能デモ集 (functest/)」の節を新設し、 デモの機能概要 (マウス 2 方式 / 画面モード切替 / 状態表示)・起動と再ビルドの手順・ヘッドレステストの実行方法を要約のうえ、 functest/ と各デモの README への導線を追加

## 2026-06-28

### Added
- **HFE を 2D 機種用・2DD 機種用に出し分け**: `scripts/d77_to_hfe.py` に `--mode {2d,2dd}` を追加。 `make` 一発で `build/<NAME>.hfe` (2D 機種=FM-7/FM77AV 用) と `build/<NAME>_2dd.hfe` (2DD 機種=FM77AV20 以降用) を同時生成する。 2DD 用は 2D の各トラックを物理トラック 2N/2N+1 の 2 本へ複製した Double Step 相当 (80 トラック) で、 80 位置のドライブでもファイル差し替えだけで読める。 複製した 2 本の ID アドレスマークの C(シリンダ)バイトには元の 2D シリンダ番号 N を入れる。

### Changed
- 既定モード (`--mode 2d`) の出力は従来と完全に同一 (バイナリ一致) であり、 既存利用に対する挙動変化・リグレッションは無い。

### Docs
- README / DETAIL / qiita に HFE の 2D/2DD 出し分けを反映

## 2026-06-22

### Added
- **機種判別 / FM 音源搭載判定 / ジョイスティック読み出しの C API (`c_device`) を追加**: `GetMachineType()` / `GetMachineName()` / `HasFMSound()` / `JoyStick()` を提供 ([src/c_device.c](src/c_device.c) / [src/c_device.h](src/c_device.h))。 `GetMachineType()` は機能ビットマスク (`FEAT_*`) を返し、 現状は FM 音源 (OPN) と FM77AV 系を検出 (他ビットは予約)。 詳細は [docs/DEVICE.md](docs/DEVICE.md)
- 上記を解説する [docs/DEVICE.md](docs/DEVICE.md) を新設

### Docs
- README に「0. リポジトリを入手する (git clone / 更新)」の GitHub 入門ガイドを新設。 本テンプレ更新時の手順 (`git pull` → `make` で再ビルド、 自分の編集と衝突した場合の対処) も追記し、 [docs/TUTORIAL.md](docs/TUTORIAL.md) からも案内
- README の macOS 導入手順を是正 (= Xcode CLT 同梱の `curl` で取得し、 配布 tarball の素の `./configure && make` でビルド可能なことを明記。 ダウンロードを `wget` から `curl -L -O` へ統一し、 Boost / Bison / Flex を任意扱いへ格下げ)

## 2026-06-13

### Added
- **`make t77` でテープ用成果物を生成**: D77 と同じ内容を CMT (カセットテープ) ロード向けに変換し、 T77 テープイメージ・WAV (FSK 音声)・操作手順テキストを同時生成 (`scripts/d77_to_t77_chunks.py` + トランポリン多段ロード方式)。 詳細は [docs/CMT.md](docs/CMT.md)
- 上記の仕組みを解説する [docs/CMT.md](docs/CMT.md) を新設 (CMT ロード手順 / FSK 変調 / トランポリン多段ロード / サイズ上限)

### Fixed
- テープ起動 (ウォームスタート) 時にサブ CPU の乗っ取りに失敗することがある問題を修正 (サブシステムの実行中コマンドのキャンセルと安定待ちを追加)
- 変換ツールの `--addr` 等に入力検証を追加し、 不正値をエラーで停止するように修正。 あわせてスクリプトの UTF-8 宣言を明示

### Docs
- README / DETAIL / TUTORIAL に `make t77` とテープロード関連の記述を追記
- CHANGELOG.md (本ファイル) を新設

## 2026-06-08

### Docs
- CMOC の配布元 URL を恒久 URL (sarrazip.com) へ更新し、 対象バージョンを 0.1.98 へ

## 2026-06-05

### Added
- **PSG (AY-3-8910) サウンド**: 発射音 (ノイズ)・歩行音・単音 BGM を追加 ([docs/SOUND.md](docs/SOUND.md))

### Changed
- フレームペーシングをメイン CPU の周期タイマ IRQ を数える deadline 方式へ刷新 ([docs/TIMER.md](docs/TIMER.md))

### Docs
- 実行画面スクリーンショットを README / TUTORIAL に追加

## 2026-06-04

### Changed
- フレームペーシングをポーリング化し、 前景描画を store 化して高速化

### Docs
- ドキュメント全体の校正 (色名・サイズ・アドレス表記の統一、 表現の是正)

## 2026-06-03

### Added
- D77 から HFE 形式も同時ビルドするように

### Fixed
- SCORE 表示の文字化けを修正し、 配色を変更

### Docs
- README に想定読者と D77 の動かし方 (マウント要領) を追記し、 「まずエミュレータで D77」 前提に統一
- 起動シーケンス / ビルドパイプライン等の図版 (SVG) を追加

## 2026-06-01

### Docs
- 全ドキュメントを新しい描画モデル (2 plane 前景 / パレット / 背景タイル) に合わせて全面更新
- [docs/TILEMAP.md](docs/TILEMAP.md) を現状の背景タイル敷き方式に合わせて更新

## 2026-05-31

### Added
- 公開用テンプレート一式としてリポジトリを整備
- BREAK キーでのボール投げ (最大 3 連射) とフレームペーシングを追加
- タイルマップ背景の設計章 ([docs/TILEMAP.md](docs/TILEMAP.md)) を追加
