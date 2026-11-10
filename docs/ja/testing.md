# テストと試験シナリオ

このリポジトリのテストは、すべて**合成データ**で行います。実ログ・実在のホスト名・認証情報は使いません。
監視対象の VM にテスト用のソフトを入れる必要はありません（Node.js と Docker は開発機・CI だけで使います）。

## 1. 一括実行

```sh
sh tests/run_all.sh            # 速いもの（Docker 不要、数十秒）
sh tests/run_all.sh --docker   # 実 JVM を使うシナリオも（数分）
```

| スクリプト | 内容 | 必要なもの |
| --- | --- | --- |
| `tests/check_public_content.sh` | 公開前チェック（秘密情報・GUID・私有 IP・機関名・外部通信・実ログの混入） | sh |
| `tests/test_collector.sh` | collector の正常系・異常系（jstat / jcmd をモック） | sh（dash・bash でも実行） |
| `tests/test_dashboard.cjs` | ダッシュボードの解析・判定・書き出し、外部通信が無いこと、翻訳キー | Node.js |
| `tests/test_real_jvm.sh` | 本物の JVM（Temurin 11）で collector を動かす | Docker |
| `examples/lms-load/run.sh` | PostgreSQL + LMS 風アプリに 100 セッション同時アクセス | Docker |

## 2. collector の異常系シナリオ（`tests/test_collector.sh`）

モックの `jstat` が、行ごとに「正常」「失敗」「列が足りない」「値が `-`」を返します。

| # | シナリオ | 期待する動き |
| --- | --- | --- |
| 1 | 正常に 5 回採取、Old 91% | CSV 5 行・メトリック 5 件・`OLD_HIGH` 1 回・開始/終了イベント・ファイル権限 600・UTC 時刻 |
| 2 | 高い状態が 3 回 → 低い状態が 3 回 | `OLD_HIGH` → `OLD_RECOVERED`、`fgc_delta`・`gct_delta_ms` が正しい |
| 3 | 75%〜85% を行き来する | ヒステリシスにより回復イベントを出さない（通知がばたつかない） |
| 4 | FGC カウンタが戻る（同じ PID で再起動） | `COUNTER_RESET`、負の差分を書かない |
| 5 | 1 回だけ jstat が失敗 | `SAMPLE_MISSED` を 1 件、メトリックは 2 件のまま（0 で埋めない）、エラー内容を collector ログに残す |
| 6 | jstat が 3 回連続で失敗（JVM 停止） | 終了コード 3、`COLLECTOR_FAILED`、`--collect-logs` を日本語で案内 |
| 7 | 列が足りない／値が `-` | 失敗として扱い、理由を記録（数値を作らない） |
| 8 | 不正な設定（しきい値が文字・150%・回復≥注意、ラベルに記号、PID 0 など 9 種） | 終了コード 2、何も書き込まない |
| 9 | 端末でない環境で PID 未設定 | 終了コード 2、`--setup` を案内 |
| 10 | 対話セットアップ | ホスト名の自動取得（FQDN からドメインを除く）、一覧から選択、メインクラスだけ保存、起動引数（ダミーの秘密）を表示も保存もしない、設定ファイル 600、入力が途切れたら無限ループせず中止 |
| 11 | 設定ファイルに `$(touch pwned)` | 実行されない（設定はデータとして読む） |
| 12 | 同じ PID が別プログラムに | 終了コード 4、採取しない、ログ回収を案内 |
| 13 | `--collect-logs` | アーカイブ作成（600）、jstat のエラーを含む、起動引数を含まない |
| 14 | `--check` | 1 回採取して表示、ファイルを作らない |

## 3. 本物の JVM でのシナリオ（`tests/test_real_jvm.sh`）

`eclipse-temurin:11-jdk` のコンテナ内で、collector を本物の `jstat` に向けます。

| シナリオ | 内容 | 確かめること |
| --- | --- | --- |
| A. 接続リーク vs 修正版 | `examples/leaky-jdbc`。エラー時に `close()` を通らない JDBC 風コードと、try-with-resources 版を 120 秒並走（各 `-Xmx128m`） | LEAK は Old が 85% 超・`OLD_HIGH`・OOM 後に `COLLECTOR_FAILED`。FIXED は 30% 未満。GC ログに Full GC。出力は 600 |
| B. passwd に無い uid の JVM | JVM を uid 4242（passwd 未登録）で起動 | collector が終了コード 3 で止まり、`--collect-logs` を案内し、`Could not map vmid to user Name` を記録 |
| C. 診断ログ | B と同じコンテナで `--collect-logs` | アーカイブができる |

手元での実測例（Apple Silicon の Docker、120 秒）: LEAK は Old 9% → 98% で約 100 秒後に OOM。
Full GC 後も `126M->104M` までしか減らず、これが「GC 後も残る量が増える」リークの典型的な形です。FIXED は 4〜5% で横ばいでした。

## 4. LMS 風アプリへの 100 セッション同時アクセス（`examples/lms-load`）

PostgreSQL で管理する学習管理システム（ToDo・予定表・受講管理・成績表）を想定した合成アプリに、
[Artillery](https://www.artillery.io/) で 100 セッションを同時に張り、collector で JVM を観測します。
特定の製品・組織を再現したものではありません。

```sh
sh examples/lms-load/run.sh --leak none        --minutes 5   # 正常
sh examples/lms-load/run.sh --leak connection  --minutes 5   # 接続リーク
sh examples/lms-load/run.sh --leak session     --minutes 5   # セッションキャッシュのリーク
```

構成（Docker の内部ネットワークだけで完結し、終了時に削除されます）:

| コンテナ | 役割 |
| --- | --- |
| `db` | PostgreSQL 16。学生 2,000 人・教員 50 人・40 コース・課題 800 件・予定約 7,300 件・ToDo 16,000 件・成績を自動生成。パスワードは使わない（trust 認証、内部ネットワークのみ） |
| `app` | Java 11 の LMS 風アプリ（`LmsApp.java`、`-Xmx256m`、接続プール 20）。同じコンテナで collector と GC ログ（`LMS.log`）を記録 |
| `load` | Artillery 2.0.34。100 人が順にログインし、ToDo → 予定表 → 受講コース → 成績表 → 成績登録を、考える時間 1〜2 秒を挟んで繰り返す。成績登録の約 8% は範囲外の点数 |

仕込んである欠陥（`--leak`）:

| モード | 欠陥 | 現れ方 |
| --- | --- | --- |
| `none` | なし | 基準 |
| `connection` | 成績登録で、入力チェックが接続の借用後にあり、エラー時に返却しない | 接続プールが枯渇して 503 が続く。**ヒープ・GC の指標は健全なまま** |
| `session` | 応答をセッションごとに貯め続け、セッションも期限切れにしない | Old 世代が増え続け、Full GC が増え、最後は応答不能 |

実測（4 分、100 セッション）:

| モード | 正常応答 | 503 | 最大 Old% | Full GC | 結末 |
| --- | --- | --- | --- | --- | --- |
| `none` | 23,679 | 0 | 90.6 | 0 | 正常に完走。プール 20 本はすべて返却済み |
| `connection` | 978 | 5,027 | 38.8 | 0 | 範囲外の点数による 400 が 20 回出た時点（開始から約 20 秒）でプールが枯渇し、以降 4 分間ほぼ全件 503。PostgreSQL 側は 20 本とも `idle` |
| `session` | 14,480 | 0 | 99.95 | 126 | 約 2 分半で Old が 98% 超、Full GC が続いたあと JVM が応答不能に（100 セッションすべてがソケットタイムアウトで失敗）。以後 10 分以上、jstat の値が同じまま（Old 99.84%・FGC 126） |

読み取り方:

- **`none` でも Old 使用率は 90% に達しました。** 256 MB のヒープに 100 セッション分の通常のデータが乗るためで、
  使用率の高さだけではリークと言えない実例です。判断はベースライン（1 時間ごとの最小値）の傾きで行います。
- **`connection` は GC 監視では見つかりません。** プール 20 本がすべて貸し出されたまま、PostgreSQL 側から見ても 20 本とも
  `idle` です。アプリのプール統計（借用数・待ち時間・タイムアウト）や 503 の増加を別に監視する必要があります。
- **`session` は GC 監視で見つかる型です。** Old 世代の使用量と Full GC 後の残量が増え続けます。
- **ハングした JVM は「値が凍る」。** `session` の最後は、JVM が応答しないのに collector は同じ値を記録し続けました。
  現行の collector はこの「カウンタが動かない」状態をイベントにしていません（今後の課題）。ダッシュボードでは Old% が平らに張り付き、
  GC 時間の差分が 0 になる区間として見えます。

結果は `--out` のディレクトリ（既定 `./lms-out-<モード>`）に出ます。`dashboard/index.html` で全ファイルを読み込んでください。
`artillery_report.json`（負荷試験の結果）、`app_stats.json`（プールとセッションの状態）、`pg_connections.txt`（DB 側の接続）、
`summary.txt`（1 画面の要約）も残ります。

### コンテナでの観測で分かったこと

- `docker compose run` は既定で依存先のコンテナを作り直します。作り直された JVM はコンテナ内で**同じ PID** になるため、
  2 つの JVM のデータが同じ PID で 1 本の CSV に混ざりました。台本では `--no-deps` を付けています。
  本番のコンテナでも「PID が同じ＝同じ JVM」とは限りません。
- 任意の uid でコンテナを動かすと `jstat` が接続できません（シナリオ B）。

## 5. 攻撃・高負荷のシナリオを置く場所

このリポジトリに置くのは、**自分で立てた合成環境に対する負荷試験**までです。
DoS に近い負荷、認証の総当たり、脆弱性を突く入力などの「攻撃寄り」のシナリオは、公開リポジトリには置かず、
別の非公開リポジトリで管理することを推奨します（対象・実施時間・承認者を記録し、本番には向けない）。

## 6. CI/CD（GitHub Actions）

公開リポジトリでは GitHub ホストのランナーを無料で使えます。

| ワークフロー | いつ | 内容 |
| --- | --- | --- |
| `ci.yml` | push（main）・PR・手動 | shellcheck、公開前チェック、collector テスト（Ubuntu: sh・dash・bash / macOS: sh・bash）、ダッシュボードテスト、実 JVM シナリオ（Docker） |
| `lms-scenario.yml` | 手動・毎週 | LMS シナリオ 3 モードを実行して判定し、合成の結果を成果物として保存 |
| `release.yml` | `v*` タグの push | 全チェック → collector の版数とタグの一致確認 → ソース一式と VM 用の collector 一式を SHA256SUMS 付きで GitHub Release に公開 |

Azure へのデプロイや VM への配布は CI/CD に含めません（AGENTS.md：人の承認が必要な操作）。
