# benchmark baseline（`benchmarks/baseline.json`）

BenchmarkTools.jl slow lane（Issue #212）が回帰判定に使う、リポジトリ管理下の baseline。
契約・設計判断の正本は
[Julia品質Export Contract §4.4](../docs/contract/julia-quality-export-v1.md#44-benchmarktoolsjl-の-result)
と [§8 方法E](../docs/contract/julia-quality-export-v1.md#8-実行方法)。

`benchmarks/` にはこの baseline ファイルのみを置く。benchmark suite の定義と実行ロジックは
[`scripts/benchmark_suite.jl`](../scripts/benchmark_suite.jl)、実測 worker は
[`scripts/benchmark_worker.jl`](../scripts/benchmark_worker.jl)、export の生成は
[`scripts/quality_export_benchmark.jl`](../scripts/quality_export_benchmark.jl)。

## なぜリポジトリに置くか

baseline を GitHub Artifact（直近 main の測定結果）から取るのではなくリポジトリに置くのは、
更新が PR 差分としてレビューされ、更新理由・対象コミットが git 履歴に残るため
（Issue #212「baseline更新を自動で常に受理せず、更新理由と対象commitを記録する」）。

## 形式

```jsonc
{
  "baseline_schema": "dme-benchmark-baseline/v1",
  "environments": {
    // キーは environment_key = "<runner_label>|<os>|<arch>|julia<major>.<minor>"
    // 一致するキーの baseline とだけ比較する（不一致は regression_status = "unavailable"）
    "github-linux-x64|linux|x86_64|julia1.12": {
      "commit": "…40桁…",              // 測定した対象コミット
      "recorded_at": "2026-08-11T07:21:51Z",  // 測定時刻（export の measured_at）
      "reason": "Issue #212 初回 baseline 収集",  // 更新理由（必須）
      "julia_version": "1.12.6",
      "runner_label": "github-linux-x64",
      "cpu_model": "AMD EPYC 7763",     // key には含めない provenance
      "manifest_digest": "0123456789ab",// 同上（依存更新差の記録）
      "benchmarks": { "capex_credit_cycle_run": { "median_time_ns": 4384200 } }
    }
  }
}
```

`environments` が空（初期状態）のときは、全 benchmark が
`regression_status = "unavailable"`（`unavailable_reason = "baseline_missing"`）になる。
これは設計どおりであり **pass ではない**。

## 更新手順（手動のみ。CI は更新しない）

```bash
# 1. 更新したい環境で export を得る
#    CI(ubuntu) の baseline: slow lane workflow を workflow_dispatch で実行し、Artifact
#      dme-julia-quality-v1-benchmark-<sha> をダウンロードして展開する
#    ローカルの baseline:
DME_BENCHMARK_RUNNER_LABEL=<マシン識別子> julia --project=. scripts/quality_export_benchmark.jl

# 2. 差分の確認だけ（書き込みなし）
julia --project=. scripts/update_benchmark_baseline.jl \
    artifacts/quality/quality-export-benchmark.json --dry-run

# 3. 理由を付けて書き込む（--reason が空なら拒否される）
julia --project=. scripts/update_benchmark_baseline.jl \
    artifacts/quality/quality-export-benchmark.json \
    --reason "Issue #212 初回 baseline 収集（ubuntu-latest / Julia 1.12）"

# 4. 差分をレビューしてコミットする
```

`status != success` の export（timeout・crash）は baseline にできない（スクリプトが拒否する）。

ローカルで測る場合は `DME_BENCHMARK_RUNNER_LABEL` を必ず指定すること。既定の `local` のままだと、
異なるマシンで測った値が同じ `environment_key` の下に混ざり、意味のない delta が出る。
