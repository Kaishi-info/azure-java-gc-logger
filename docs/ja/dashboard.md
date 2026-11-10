# ダッシュボードの見方と JSON 書き出し

`dashboard/index.html` は 1 ファイルで完結するオフラインのビューアです。ブラウザで直接開き、
collector の出力（CSV・NDJSON）と、あれば Unified GC ログをまとめて読み込みます。
Content-Security-Policy で外部への通信をすべて禁止しており、ファイルはどこにも送信されません。

`index.html#demo` を開くと、7 日分の合成デモ（リークするホストと正常なホスト）を表示します。

## 画面構成

| 部分 | 内容 |
| --- | --- |
| 期間 | 24 時間 / 7 日 / 全期間。データの最後の時刻から遡ります |
| ホスト | チップを押すと表示・非表示を切り替え |
| 指標カード | ホスト数、サンプル数と取得率、最大 Old 使用率、Full GC 回数と GC 時間、最大のベースライン傾き |
| リーク追跡 | ホストごとの判定、ベースライン傾き（MiB/日）と R²、GC 後ヒープの傾き、上限到達までの外挿、取得率、欠測、再起動 |
| 増加が大きかった時間帯 | ベースラインが前の 1 時間から大きく増えた時間帯の上位（増加傾向・不明瞭のホストを優先） |
| グラフ 4 枚 | Old 使用率（しきい値・イベント縦線・欠測帯）、ヒープ使用量と GC 後ヒープ、サンプル間 GC 時間、1 時間あたり Full GC |
| 曜日 × 時刻（7×24） | 最大 Old%・平均 Old%・GC 時間・Full GC 回数を曜日と時刻で集計。データの無いマスは斜線（0 とは表示しない） |
| 日次サマリー | 日付（選択タイムゾーン）× ホストごとの件数・取得率・最小 Old・最大 Old%・Full GC・GC 秒・イベント数 |
| 収集イベント / 欠測区間 | collector のイベントと、間隔の 2.5 倍以上空いた区間 |

表示言語（日本語／English）、タイムゾーン（UTC／Asia/Tokyo／ブラウザ）、テーマ（自動／ライト／ダーク）を切り替えられます。

## 判定のしかた

- **ベースライン** = 1 時間ごとの最小 Old 使用量（MiB）。`jstat` だけで得られる「GC 直後に近い値」です。
  最新の PID 区間（再起動・カウンタ巻き戻し以降）だけを使います。
- 1 時間に 3 サンプル以上ある時間を、6 時間分以上集めたら回帰直線を引きます。
- **増加傾向**: 傾きが正、R² ≥ 0.5、かつ 1 日あたり Old 容量の 1% 以上増えている
- **横ばい**: 1 日あたりの変化が Old 容量の 1% 未満
- **不明瞭**: どちらでもない（ばらつきが大きい、減っている等）
- **データ不足**: 条件を満たすデータが無い
- **上限到達（外挿）**: 「増加傾向」のとき、最後のベースラインから Old 容量に届くまでの時間を直線で外挿した値。予測ではありません。
- GC ログがあれば、Full GC 後のヒープ（4 回以上あれば）または 1 時間ごとの GC 後最小値でも同じ計算をします。

> 「増加傾向」はリークの証明ではありません。キャッシュやセッションの正常な増加でも同じ形になります。
> 原因の特定には、アクセス量・デプロイ・バッチの記録との突き合わせと、承認されたヒープ解析が必要です。

## JSON 書き出し

どちらも選択中の期間が対象です。時刻はすべて UTC（`Z` 付き ISO 8601）です。

### 生データ JSON（`java_gc_raw_<期間>.json`）

```json
{
  "schema": "java-gc-timeline/raw@1",
  "generated_utc": "...", "synthetic_demo": false,
  "range": { "from_utc": "...", "to_utc": "...", "selection": "7d" },
  "files": [ { "name": "gc_samples_2026-01-15.csv", "kind": "jstat_csv", "records": 1440, "skipped_lines": 0 } ],
  "samples": [ { "timestamp_utc": "...", "host": "APP01", "pid": 4101, "old_pct": 41.2, "old_used_mib": 1265.0, "old_capacity_mib": 3072, "heap_used_mib": 1810.3, "heap_capacity_mib": 4096, "gct_delta_ms": 12, "fgc_delta": 0, "source": "gc_samples_2026-01-15.csv" } ],
  "gc_events": [ { "timestamp_utc": "...", "host": "APP01", "gc_id": 68, "kind": "Full", "before_mib": 126, "after_mib": 104, "capacity_mib": 128, "pause_ms": 13.6, "source": "APP01_gc.log" } ],
  "collector_events": [ { "timestamp_utc": "...", "host": "APP01", "pid": 4101, "event_name": "JAVA_GC_OLD_HIGH", "old_pct": 88.3, "detail": "", "source": "gc_azure_2026-01-15.json" } ]
}
```

読み込んだ複数ファイル・複数ホストを 1 つにまとめた形なので、別のツールでの再分析や、調査記録への添付に使えます。
値の無い項目は `null` のままです。

### 分析 JSON（`java_gc_analysis_<期間>.json`）

```json
{
  "schema": "java-gc-timeline/analysis@1",
  "range": { ... }, "display_time_zone": "Asia/Tokyo",
  "caveats": [ "jstat old_pct is sampled at a point in time ...", "..." ],
  "hosts": [ {
    "host": "APP01", "first_utc": "...", "last_utc": "...", "samples": 10080, "interval_sec": 60, "coverage_pct": 99.1,
    "gaps": [ { "start_utc": "...", "end_utc": "...", "minutes": 181 } ],
    "restarts": [ { "at_utc": "...", "from_pid": 4101, "to_pid": 4377 } ], "counter_resets": 0,
    "old_pct_max": 92.9, "old_pct_p95": 81.0, "full_gc_count": 2, "gc_time_sec": 252.2, "old_capacity_mib": 3072,
    "baseline": { "slope_mib_per_day": 160.4, "r2": 0.93, "hourly_points": 54, "segment_start_utc": "...", "last_floor_mib": 1036 },
    "post_gc": { "slope_mib_per_day": 159.2, "r2": 0.91, "points": 50, "basis": "hourly_min_after_gc" },
    "assessment": "rising", "time_to_limit_hours": 302.0,
    "top_rises": [ { "hour_start_utc": "...", "rise_mib": 97.6, "floor_mib": 1036, "events_within_1h": [] } ]
  } ],
  "daily": [ { "date": "2026-01-18", "host": "APP01", "samples": 1440, "coverage_pct": 100, "min_old_used_mib": 808, "max_old_pct": 47.6, "full_gc": 0, "gc_sec": 13.3, "events": 0 } ],
  "heatmap": { "maxOld": { "time_zone": "Asia/Tokyo", "rows": "Mon..Sun", "cols": "00..23", "cells": [[...24 values or null...], "..."] }, "avgOld": {}, "gc": {}, "full": {} },
  "event_counts": { "JAVA_GC_OLD_HIGH": 5 }
}
```

`caveats` は解釈の前提（言えないこと）です。報告書を作るときは必ず一緒に載せてください。
`top_rises` の時刻は、アプリのログ・デプロイ・バッチ・アクセス量と突き合わせる候補になります。

## 読み込めるファイル

| 種類 | 条件 |
| --- | --- |
| `gc_samples_*.csv` | collector の CSV（列名で読むので列順は問いません） |
| `gc_azure_*.json` / `.jsonl` / `.ndjson` | 1 行 1 JSON。`record_type` が `metric` / `event` の行 |
| Unified GC ログ | 絶対時刻の装飾（`time` / `utctime`）と `GC(n) ... X->Y(Z) ... N.NNNms` を含む行。`uptime` だけの行は時刻を決められないため数えてスキップ |

GC ログのホスト名はファイル名から取ります: `APP01_gc.log` / `app01-gc.log.3` / `APP01.log` → `APP01`・`app01`。
collector の `HOST_LABEL` と同じ名前にしてください。
