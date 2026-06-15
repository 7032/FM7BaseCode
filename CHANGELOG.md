# Changelog

本ファイルは FM7BaseCode の主要な変更点を記録します。 書式は [Keep a Changelog](https://keepachangelog.com/ja/) に準拠し、 プロジェクトに版番号が無いため、 見出しは日付ベース (新しい順) で記載します。

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
- D77 から HFE (HxC Floppy Emulator 形式) も同時ビルドするように

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
