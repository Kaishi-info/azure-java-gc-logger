# CLAUDE.md

@AGENTS.md

## Azure 管理者が「このリポジトリの URL」だけを貼ったとき

管理者は手順書を読まない前提で、Claude Code が以下の順に案内する。目的は
「Java VM の GC を安全に観測し始め、7 日分を可視化して、リーク調査の材料を報告する」こと。

### 進め方の原則

- **本番 VM と Azure には、Claude Code から直接操作しない。** ssh / scp / az / ポータル操作は、
  コマンドや手順を提示して管理者が実行する。管理者がその場で明示的に許可した操作だけは代行してよい。
- 各ステップの最初に「何を・どこで・影響（読み取りのみ／ファイル作成／再起動の要否）」を 1 文で示す。
- 質問は 1 回にまとめる。答えが分からない項目は既定値で進め、後で変えられることを伝える。
- JVM への書き込み・GC の強制・再起動は提案しない（AGENTS.md の制約）。GC ログの有効化は JVM 再起動が要るため、
  「管理者の判断事項」として選択肢を示すだけにする。
- 結果の解釈では「リークの証明」と言わない。ダッシュボードの判定は「増加傾向」「横ばい」「不明瞭」「データ不足」までで、
  原因の特定には別途承認されたヒープ解析が要る。

### 手順

0. **手元で検証する**（管理者の PC 上、読み取りのみ）
   `sh tests/run_all.sh` を実行し、結果を 3 行で報告する。Docker があれば `sh tests/run_all.sh --docker` も提案する。
1. **ヒアリング**（1 回で聞く）
   対象 VM の台数とホスト名、OS、Java を動かしているユーザー、`jstat` の有無（JDK か JRE か）、
   systemd を使えるか、出力先ディレクトリ（既定 `/var/log/java-gc`）、保持期間、Azure Monitor 連携の要否
   （AMA 導入済みか、Log Analytics ワークスペースがあるか）。
2. **配布**
   リリースの `azure-java-gc-logger-vX.Y.Z-collector.tar.gz` と `SHA256SUMS`、またはリポジトリの `collector/` を
   VM に置くコマンドを、管理者の環境に合わせて提示する（例: `scp` → `sha256sum -c` → `/opt/java-gc-logger` へ展開）。
3. **初回セットアップ**（VM 上、JVM と同じユーザーで）
   `sh /opt/java-gc-logger/collect_gc.sh --setup` を案内する。対話でホスト名ラベル（自動取得）、Java プロセス、
   出力先、間隔、しきい値を選び、テスト採取が OK なら `gc_logger.conf` に保存される。続けて `--check` で 1 回採取。
4. **24 時間稼働**
   `collector/systemd/java-gc-logger.service` を VM に合わせて書き換えたもの（`User=`, `WorkingDirectory=`, パス）を提示する。
   `Restart=no` は意図的（失敗を隠さない）。`PrivateTmp=yes` は付けない。
5. **失敗したとき**
   collector は止まり、オペレーター向けに `--collect-logs` を実行するよう日本語で表示する。管理者から
   `diag_<ホスト>_<時刻>.tar.gz` を受け取ったら、中身（テキストのみ）を読んで下表で分類し、次の手を示す。

   | ログにある文字列 | 主な原因 | 次の手 |
   | --- | --- | --- |
   | `Could not map vmid to user Name` | JVM が `/etc/passwd` に無い uid で動いている（コンテナに多い） | JVM 側ユーザーの扱いを管理者と相談。collector は同じ名前空間・同じユーザーで動かす |
   | `MonitorException: <PID> not found` | JVM の停止・再起動で PID が変わった | `--setup` で選び直す。再起動時刻をアプリ側の記録と照合 |
   | `PID ... is not <main class>` | PID が別プログラムに再利用された | `--setup` で選び直す |
   | `jstat not found` | JRE のみで JDK が無い | 同じバージョンの JDK の導入可否を管理者が判断 |
   | `lacks required columns` / `non-numeric` | `jstat -gc` の列構成が想定外（GC 実装の違い） | Issue 用に `java.txt` の jstat 出力を添えて報告。数値は作らない |
   | 出力先に書けない | ディレクトリの権限 | 所有者・ACL を見直す（`chmod 777` は不可） |

6. **可視化と報告**
   管理者が VM から `gc_samples_*.csv`・`gc_azure_*.json`（あれば GC ログ）を回収したら、`dashboard/index.html` を
   ブラウザで開いて全ファイルを読み込むよう案内する（外部送信なし）。期間「7d」で「分析 JSON」を書き出してもらい、
   Claude Code はその JSON を読んで、次の形の報告を作る。
   - 対象と期間、取得率、欠測区間、再起動
   - ホストごとの判定（増加傾向／横ばい／不明瞭／データ不足）とベースラインの傾き（MiB/日、R²）
   - 増加が大きかった時間帯（アプリログ・デプロイ・バッチと突き合わせる候補）
   - 次に必要なデータ（GC ログ、アクセス量、承認済みヒープダンプ）と、言えないこと（`caveats`）
7. **Azure Monitor 連携（任意）**
   `azure/README.md` に沿って、カスタムテーブル `JavaGc_CL`、DCR（Custom JSON Logs）、アラートの設定内容を作り、
   管理者のレビューに回す。作成・変更は管理者が行う。費用が発生しうることを必ず書く。
8. **GC ログを追加したいとき**（JVM 再起動が必要）
   例: `-Xlog:gc:file=/var/log/java-gc/APP01_gc.log:utctime,uptime,level,tags:filecount=7,filesize=50m`
   を示し、適用するかどうか・いつ再起動するかは管理者に委ねる。

### 試験環境だけで確かめたいとき

本番に触れる前に、手元の Docker で挙動を見せられる（合成データのみ）。

- `sh examples/leaky-jdbc/run-docker.sh ./leaky-out 120` … リークする JVM と修正版の比較（2 分）
- `sh examples/lms-load/run.sh --leak session --minutes 5` … PostgreSQL + LMS 風アプリに 100 セッション同時アクセス
- 詳細: `docs/ja/testing.md`
