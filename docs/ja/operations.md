# 運用手順（collector）

対象: Java アプリが動く Linux VM の管理者・オペレーター。
collector は `jstat` で JVM の GC 統計を**読むだけ**です。GC の強制、JVM の再起動、アプリへの書き込みは行いません。

## 1. 必要なもの

| 項目 | 内容 |
| --- | --- |
| OS | POSIX シェル（`sh`）、`awk`、`date`、`tar`、`gzip` がある Linux |
| Java | 監視する JVM と同じバージョン系列の **JDK**（`jstat` と `jcmd`。JRE には含まれません） |
| 実行ユーザー | **JVM と同じユーザー**。別ユーザーからは `jstat` が JVM を見つけられません |
| 追加ソフト | 不要（Python・Node.js・エージェントは入れません） |

## 2. 初回セットアップ（対話）

```sh
sudo mkdir -p /opt/java-gc-logger && sudo cp collect_gc.sh /opt/java-gc-logger/
sudo chown -R appuser: /opt/java-gc-logger
cd /opt/java-gc-logger
sudo -u appuser sh collect_gc.sh --setup
```

対話の流れ:

1. **ホスト名ラベル** … `hostname -s` から自動取得した値が既定です。Enter で確定。
2. **Java プロセスの選択** … そのユーザーから見える JVM が、PID とメインクラスだけで一覧されます
   （起動引数はパスワードなどを含みうるため表示も保存もしません）。番号か PID を入力。
3. **出力先・間隔・しきい値** … 既定は `./out`、60 秒、注意 85%、回復 75%、連続 3 回。
4. **テスト採取** … その場で `jstat` を 1 回実行し、Old 使用率などを表示します。失敗したら保存せずに止まり、
   ログ回収の方法を表示します。
5. 成功すると `gc_logger.conf`（権限 600）に保存されます。

設定ファイルがない状態で端末から `sh collect_gc.sh` を実行した場合も、自動でこの対話が始まります。
端末でない（systemd など）場合は対話せず、`--setup` を案内して終了します。

## 3. コマンド一覧

| コマンド | 用途 | ファイル書き込み |
| --- | --- | --- |
| `sh collect_gc.sh --setup` | 対話セットアップ・選び直し | `gc_logger.conf` |
| `sh collect_gc.sh --check` | 1 回だけ採取して表示 | なし |
| `sh collect_gc.sh` | 収集（設定ファイル＋環境変数） | 出力先に追記 |
| `sh collect_gc.sh --collect-logs` | 診断ログを 1 ファイルにまとめる | `diag_*.tar.gz` |
| `sh collect_gc.sh --help` / `--version` | ヘルプ・版数 | なし |

環境変数は設定ファイルより優先されます（例: `INTERVAL_SEC=10 sh collect_gc.sh`）。
設定ファイルは**データとして読むだけ**で、シェルとして実行しません（未知のキーは警告して無視）。

## 4. 24 時間稼働（systemd）

`collector/systemd/java-gc-logger.service` を環境に合わせて編集し、配置します。

```sh
sudo cp java-gc-logger.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now java-gc-logger
systemctl status java-gc-logger
```

- `User=` は JVM と同じユーザーにします。
- `Restart=no` は意図的です。JVM の再起動などで `jstat` が失敗したとき、自動で再起動すると
  **間違った PID を測り続ける**・**失敗が見えなくなる**ためです。
- `PrivateTmp=yes` は付けないでください。`jstat` は `/tmp/hsperfdata_<ユーザー>` を通じて JVM を見つけます。

1 分間隔なら 1 ホストあたり 1 日 1,440 行（CSV 約 150 KB、NDJSON 約 330 KB、7 日で合計約 3.4 MB）です。
ファイルは UTC の日付ごとに分かれます。保持期間を決め、古いファイルの削除は既存のログ運用（logrotate など）で行ってください。

## 5. 失敗したとき（オペレーター向け）

collector は次の場合に**止まり**、画面（systemd なら `journalctl -u java-gc-logger`）に次のような案内を出します。

```text
==================================================================
 オペレーターの方へ / To the operator
 GC 収集を停止しました: PID 12345 の jstat が 3 回連続で失敗しました（JVM の停止・再起動、権限の変化など）
 ...
   cd '/opt/java-gc-logger' && sh '/opt/java-gc-logger/collect_gc.sh' --collect-logs
==================================================================
```

| 停止理由 | 終了コード | イベント |
| --- | --- | --- |
| `jstat` が 3 回連続で失敗（JVM 停止・再起動・権限） | 3 | `JAVA_GC_COLLECTOR_FAILED` |
| 設定時と別のプログラムが同じ PID で動いている | 4 | `JAVA_GC_COLLECTOR_FAILED` |
| 設定値が不正 | 2 | なし（何も書き込まない） |

**やること**: 表示されたコマンドをそのまま実行し、表示された `diag_<ホスト>_<時刻>.tar.gz` を担当者へ渡してください。
中身はテキストだけで、`tar tzf` で事前に確認できます。含まれるもの: OS・ユーザー・設定値、`java -version`、
JVM の一覧（PID とメインクラスのみ）、`jstat` のエラー、直近の collector ログと出力の末尾。
**含まれないもの**: JVM の起動引数、ヒープの中身、アプリのログ。

1 回だけの失敗は `JAVA_GC_SAMPLE_MISSED` として記録し、収集は続きます。欠けた時刻を 0 で埋めることはしません。

## 6. 出力ファイル

| ファイル | 内容 |
| --- | --- |
| `gc_samples_YYYY-MM-DD.csv` | サンプル（ダッシュボード用） |
| `gc_azure_YYYY-MM-DD.json` | 1 行 1 JSON（メトリックとイベント。Azure Monitor Agent の取り込み対象） |
| `collector_YYYY-MM-DD.log` | collector 自身の記録（開始・停止・`jstat` のエラー） |
| `.jstat_last_error` | 直近の `jstat` のエラー出力 |

すべて `umask 077`（所有者のみ読み書き）で作られます。Azure Monitor Agent に読ませる場合は、
承認された ACL・グループで必要最小限の読み取り権限を付けてください（`chmod 777` は不可）。

### イベント

| イベント | 意味 |
| --- | --- |
| `JAVA_GC_COLLECTOR_STARTED` / `STOPPED` | 収集の開始・終了（計画停止とデータ欠落を区別するため） |
| `JAVA_GC_OLD_HIGH` / `OLD_RECOVERED` | Old 使用率が注意しきい値を連続で超えた／回復しきい値を連続で下回った |
| `JAVA_GC_SAMPLE_MISSED` | 1 回の採取失敗（理由付き） |
| `JAVA_GC_COUNTER_RESET` | GC カウンタが戻った（同じ PID での再起動の可能性） |
| `JAVA_GC_COLLECTOR_FAILED` | 収集を停止した |

## 7. 気をつけること

- **コンテナでは PID が同じまま JVM が入れ替わることがあります。** コンテナ内の JVM は再起動後も PID 1 や 8 になりがちです。
  `JAVA_MATCH`（セットアップ時のメインクラス）と `JAVA_GC_COUNTER_RESET` で検出しますが、
  同じメインクラスでの再起動は「再起動」として扱われ、ダッシュボードは最新区間だけで傾きを計算します。
- **JVM が `/etc/passwd` に無い uid で動いていると、`jstat` は接続できません**（`Could not map vmid to user Name`）。
  任意の uid で起動するコンテナでよく起きます。
- `jstat` の Old 使用率は採取時点の値で、GC 直後の生存量ではありません。使用率が高いことはリークの証明ではありません。
- `GCT` の差分は GC に使った累積時間で、停止時間（STW）だけとは限りません。
- 監視は JVM のパフォーマンスカウンタを読むだけですが、本番での実施時刻・保持期間・アクセス権は管理者が承認してください。
