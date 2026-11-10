# 利用している OSS（サードパーティ） / Third-party open source

このリポジトリは以下のソフトウェアを**利用・参照するだけ**で、ソースやバイナリを同梱・再配布していません
（リリースのアーカイブにも含めません）。各ソフトウェアの権利は各権利者に帰属します。
ライセンスは 2026-11-10 時点で各プロジェクトが公表しているものです。

This repository only uses or references the software below; none of it is bundled or redistributed, including in release archives. Rights belong to their respective owners.

## 監視対象の VM で使うもの / On monitored VMs

| ソフトウェア | 用途 | ライセンス |
| --- | --- | --- |
| OpenJDK の `jstat` / `jcmd`（利用者の JDK に付属） | JVM の GC 統計の読み取り、JVM の一覧 | GPL-2.0 with Classpath Exception（配布元により異なる場合あり） |
| POSIX シェル（dash / bash など）、`awk`（mawk / gawk / BSD awk）、coreutils、`tar`、`gzip` | collector の実行 | 各 OS ディストリビューションのライセンス（GPL / BSD など） |
| systemd（任意） | 常時稼働 | LGPL-2.1-or-later |

collector 本体は POSIX シェルスクリプトで、これら以外の依存はありません。

## ブラウザで使うもの / In the browser

`dashboard/index.html` は外部ライブラリを一切使っていません（グラフは Canvas API で自前描画）。

## 開発・テスト・CI で使うもの / Development, tests and CI only

| ソフトウェア | 用途 | 取得元・版 | ライセンス |
| --- | --- | --- | --- |
| Eclipse Temurin（OpenJDK） | 実 JVM テスト | Docker イメージ `eclipse-temurin:11-jdk` | GPL-2.0 with Classpath Exception |
| Docker Engine（Moby） | 使い捨てのテスト環境 | 実行環境に導入済みのもの | Apache-2.0 |
| Node.js | ダッシュボードのテスト | 20 系（CI） | MIT |
| ShellCheck | シェルスクリプトの静的検査 | CI ランナーに導入済みのもの | GPL-3.0 |
| GitHub Actions: `actions/checkout`, `actions/setup-node` | CI | v4 | MIT |
| GitHub CLI（`gh`） | リリースの公開（CI） | ランナーに導入済みのもの | MIT |
| util-linux `setpriv` | テストで JVM を別 uid で起動 | Temurin イメージに含まれる | GPL-2.0-or-later |
| GitHub Actions: `actions/configure-pages`, `actions/upload-pages-artifact`, `actions/deploy-pages` | 公開デモ（GitHub Pages）の配信 | v5 / v3 / v4 | MIT |
| ImageMagick | README 用スクリーンショットの減色（`scripts/screenshots.sh`） | 開発機に導入済みのもの | ImageMagick License |
| Google Chrome / Chromium（ヘッドレス） | README 用スクリーンショットの撮影 | 開発機に導入済みのもの | Chromium: BSD-3-Clause ほか（Chrome は Google の利用規約） |

## 参照している仕様・サービス / Referenced specifications and services

| 対象 | 関係 |
| --- | --- |
| Azure Monitor（Azure Monitor Agent、Data Collection Rules、Log Analytics、KQL） | `azure/` の設定例とクエリ。Microsoft の商用サービスで、このリポジトリはその API を呼びません |
| Unified JVM Logging（JEP 158） | ダッシュボードが読む GC ログの形式 |
