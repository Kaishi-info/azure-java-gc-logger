# azure-java-gc-logger（日本語）

Java アプリの GC（ガベージコレクション）の状態を、**JDK 付属の `jstat` と POSIX シェルだけ**で 24 時間記録し、
**1 ファイルのオフライン HTML** で 7 日分を可視化するツールです。必要なら Azure Monitor にイベントを送れます。
監視する VM に Python・Node.js・エージェントは入れません。JVM には一切書き込みません。

> **公開区分: v0.2.0 参考実装。** 自動テスト（collector・ダッシュボード・Docker 上の実 JVM・PostgreSQL を使う LMS 風シナリオ）は
> 通っていますが、実際の Azure 環境への取り込みと、本番サーバーでの長期稼働は未検証です。

## Claude Code を使う場合（いちばん簡単）

Claude Code に**このリポジトリの URL を貼って「これで Java の GC を監視したい」と伝えるだけ**で始められます。
Claude Code は `CLAUDE.md` の手順に沿って、手元での検証 → ヒアリング → VM への配置コマンド → 対話セットアップ →
24 時間稼働 → 失敗時のログの読み解き → 可視化と報告書づくり → （任意）Azure Monitor 連携、の順に案内します。

- 本番 VM と Azure への操作は、Claude Code が**コマンドを示して、管理者が実行**します（勝手に接続しません）。
- 判定は「増加傾向／横ばい／不明瞭／データ不足」まで。リークの断定はしません。

## 自分で使う場合

### 1. VM で初回セットアップ（対話）

```sh
# JVM と同じユーザーで
sh collector/collect_gc.sh --setup
```

ホスト名を自動で取得し、そのユーザーから見える Java プロセスを一覧表示します。番号を選び、出力先・間隔・しきい値を
Enter で確定すると、その場でテスト採取して `gc_logger.conf` に保存します。

```sh
sh collector/collect_gc.sh --check   # 1 回だけ採取して表示（ファイルは作らない）
sh collector/collect_gc.sh           # 収集開始（Ctrl+C で停止）
```

24 時間稼働させるときは `collector/systemd/java-gc-logger.service` を使います。

### 2. 失敗したら

JVM の停止・再起動・権限の変化で `jstat` が 3 回続けて失敗すると、collector は止まり、
**「オペレーターの方へ」という案内とログ回収のコマンド**を表示します。

```sh
sh collector/collect_gc.sh --collect-logs
```

表示された `diag_<ホスト>_<時刻>.tar.gz` を担当者に渡してください（テキストのみ。JVM の起動引数やヒープの中身は含みません）。

### 3. 可視化

回収した `gc_samples_*.csv`・`gc_azure_*.json`（あれば GC ログ）を手元に置き、`dashboard/index.html` をブラウザで開いて
まとめて読み込みます。ファイルは外部に送信されません。試すだけなら `dashboard/index.html#demo` で 7 日分の合成デモが出ます。

- 期間（24 時間／7 日／全期間）、ホスト、タイムゾーン、日本語／英語、ライト／ダークを切り替え
- **リーク追跡**: 1 時間ごとの最小 Old 使用量（ベースライン）の傾きと当てはまり、再起動・欠測を考慮した判定
- **増加が大きかった時間帯**: アプリのログやデプロイと突き合わせる候補
- **曜日 × 時刻（7×24）ヒートマップ**、日次サマリー、イベント、欠測区間
- **生データ JSON／分析 JSON の書き出し**（調査記録への添付、別ツールでの再分析、Claude Code への受け渡し用）

## ドキュメント

| 文書 | 内容 |
| --- | --- |
| [docs/ja/operations.md](docs/ja/operations.md) | 運用手順（セットアップ、コマンド、systemd、失敗時の対応、出力とイベント、注意点） |
| [docs/ja/dashboard.md](docs/ja/dashboard.md) | ダッシュボードの見方、判定のしかた、JSON の形式 |
| [docs/ja/testing.md](docs/ja/testing.md) | テスト一覧、異常系シナリオ、テスト用 Docker（リーク JVM・LMS 100 セッション）、CI/CD |
| [azure/README.md](azure/README.md) | Azure Monitor 連携（AMA → DCR → `JavaGc_CL` → アラート）の設定例 |
| [CLAUDE.md](CLAUDE.md) | Claude Code 向けの案内手順 |
| [AGENTS.md](AGENTS.md) | AI エージェントと運用の安全条件 |

## 解釈上の注意

- `jstat` の Old 使用率は採取時点の値で、Full GC 直後の生存量ではありません。使用率が高いことはリークの証明ではありません。
- `GCT` の差分は GC に使った累積時間で、停止時間（STW）だけとは限りません。
- **接続リークはヒープに現れないことがあります。** LMS 風シナリオでは、接続プールが枯渇してサービスが止まっても、
  Old 使用率は 60% 程度のままでした（[testing.md](docs/ja/testing.md)）。GC 監視はアプリのプール監視の代わりになりません。
- 本番での実施前に、OS 権限、PID の変化、収集負荷、保存先、保持期限、担当者、Azure 取り込み費用を確認・承認してください。
  **実ログ、認証情報、ヒープダンプ、個人情報は公開リポジトリに登録しないでください。**

MIT License © 2026 AICU Inc.
