# scripts/benchmark_suite.jl
#
# Julia品質Export Contract v1（Issue #212）: DME の代表的な計算経路の benchmark suite 定義と
# 実行ロジック。`using BenchmarkTools` 済みの側から `include` される想定
# （`scripts/benchmark_worker.jl` と `test/test_quality_benchmark.jl`。BenchmarkTools.jl は
# slow-lane 専用ツールであり `src/` の実行時依存にしない方針のため、DME 本体には置かない —
# `scripts/jet_report_extract.jl` と同じ配置理由）。
#
# ## 対象の選定（Issue #212「対象候補の棚卸し」への回答）
#
# 「入力規模・乱数seed・solver条件・外部I/O有無を固定できるもの」という条件を満たす6経路を
# 選定した。全候補を必須にはしていない（同 Issue の但し書き）。契約 §4.4 と対。
#
#   1. solow_transition_path     代表的な単一モデル simulate（純粋な数値反復）
#   2. rbc_impulse_response      線形化モデルの IRF（行列演算を含む）
#   3. sfc_sim_simulate          SFC（SIM型）の中核計算
#   4. keen_simulate_rk4         Keen/Minsky の中核計算（固定刻み RK4、substep ループ）
#   5. capex_credit_cycle_run    CAPEX・信用循環シナリオ実行（期内10ステップ×2部門系列。
#                                現状 suite 中で最も重く、headline に採用）
#   6. real_rate_artifact_export artifact export/serialization（RFC 8785 正準化 + SHA hash）
#
# ## 除外した候補と理由（Issue #212「network/API依存処理を対象から除外またはstub化する」）
#
#   - Ramsey モデル（`transition_path`/`simulate`）: 内部で NLsolve・Ipopt（外部ソルバー）を
#     呼ぶ。実行時間がソルバー内部のヒューリスティクス・BLAS スレッド数・Ipopt/HSL の
#     ビルド差に依存し、DME 側のコード変更に対する感度より環境差の方が大きくなる。
#   - データ層（FRED/e-Stat クライアント）: ネットワーク I/O。fixture モードでもファイル
#     読み込みが支配的になり、測定対象が DME の計算ではなくディスク/OS キャッシュになる。
#   - LLM 層（provider 呼び出し）: 外部 API。MockProvider でも測っているのは mock 自身。
#   - 可視化（Plots/GR）: バックエンドの初期化・フォント解決が支配的で、環境依存が大きい。
#   - model comparison / cross-model reasoning: 上記モデル実行の薄いラッパーであり、
#     現状は独立した性能特性を持たない（重くなった時点で追加する）。
#
# ## compile time と steady-state runtime を混同しないための手当て
#
#   - 各 case の入力（モデル・初期値）は `dme_benchmark_cases()` の中、すなわち計測対象の
#     クロージャの**外**で1回だけ構築する。計測されるのはワークロード本体のみ。
#   - 計測前に workload を `DME_BENCHMARK_WARMUP_EVALS` 回呼んで JIT コンパイルを済ませ、
#     さらに `BenchmarkTools.warmup` を呼ぶ（`@benchmark` マクロが内部で行う warmup と同じ）。
#     `@benchmarkable` + `run` を手動で組み合わせる場合、`run` は warmup を自動では行わない。
#   - `tune!` は呼ばず `evals = DME_BENCHMARK_EVALS_PER_SAMPLE`（=1）に固定する。`tune!` が
#     選ぶ evals は実行時の負荷状況に依存し、実行ごとに変わると median の意味が変わるため
#     （固定した evals は `config.evals_per_sample` として export の provenance に残る）。
#   - 代表値は median を採る（mean は外れ値に、minimum は「最良ケース」に寄りすぎる。
#     CI runner の間欠的なノイズに対して median が最も素直）。
#
# ## 決定性
#
# DME のモデル実装はグローバル RNG を使わない（`src/analysis/keen_calibration.jl` が持つのは
# 自前の決定的 LCG のみ）が、将来 RNG を使う経路を suite へ追加したときに測定が
# 実行ごとに変わらないよう、各 case の実行直前に `Random.seed!(DME_BENCHMARK_SEED)` する。
#
# ## 呼び出し側の前提
#
# 本ファイルは `using` 文を持たない、副作用なしの `include` 可能ファイル
# （`scripts/jet_report_extract.jl` と同じ規約 — 呼び出し側の環境・world に依存させない）。
# include する前に `using DME`（モデル・`QUALITY_BENCHMARK_DEFAULT_MARGIN_PERCENT` 等）・
# `using Dates`（artifact の固定時刻）・`using Random`（seed）・`using BenchmarkTools` を
# 済ませておくこと。
#
# 実行方法: 直接は実行しない（`scripts/benchmark_worker.jl` および
# `test/test_quality_benchmark.jl` が include する）。

#: 各 case 実行直前に設定するグローバル RNG の seed（上記「決定性」参照）。
const DME_BENCHMARK_SEED = 20260812

#: Dashboard の共通 headline 用に代表とする benchmark（suite 中で最も重く、部門別 CAPEX・
#: 信用循環モデルという DME 固有の計算量を最もよく代表する）。個別結果は headline とは別に
#: 全件保持する（契約 §4.4「単一headline値へ集約しない」）。
const DME_BENCHMARK_HEADLINE_ID = "capex_credit_cycle_run"

#: 1 benchmark あたりの測定時間予算（秒）。suite 全体で概ね 30 秒。
const DME_BENCHMARK_SECONDS = 5.0
#: 1 benchmark あたりの最大サンプル数（時間予算より先にこちらへ到達する軽い case がある）。
const DME_BENCHMARK_SAMPLES_MAX = 10_000
#: 1サンプルあたりの評価回数。`tune!` を使わず固定する（上記参照）。
const DME_BENCHMARK_EVALS_PER_SAMPLE = 1
#: 計測前に workload を空回しする回数（JIT コンパイルを計測から外す）。
const DME_BENCHMARK_WARMUP_EVALS = 3

"""
    dme_benchmark_runner_label() -> String

`environment_key` の第1要素。優先順:

1. `DME_BENCHMARK_RUNNER_LABEL`（明示指定。異なるローカルマシンの baseline を混ぜないために
   ローカル実行では設定することを推奨する）
2. GitHub Actions 上（`GITHUB_ACTIONS == "true"`）なら `github-<RUNNER_OS>-<RUNNER_ARCH>`
3. それ以外は `"local"`
"""
function dme_benchmark_runner_label()::String
    explicit = get(ENV, "DME_BENCHMARK_RUNNER_LABEL", "")
    isempty(explicit) || return explicit
    if get(ENV, "GITHUB_ACTIONS", "") == "true"
        os = lowercase(get(ENV, "RUNNER_OS", "unknown"))
        arch = lowercase(get(ENV, "RUNNER_ARCH", "unknown"))
        return "github-$os-$arch"
    end
    return "local"
end

"""
    dme_benchmark_manifest_digest() -> Union{String,Nothing}

ルート `Manifest.toml` の sha1 先頭12桁（依存パッケージの更新差を provenance として残す。
Issue #212「dependency更新差をprovenanceへ保持する」）。`Manifest.toml` は `.gitignore`
対象なので、環境によっては存在せず `nothing` になりうる。
"""
function dme_benchmark_manifest_digest()::Union{String, Nothing}
    path = joinpath(normpath(joinpath(@__DIR__, "..")), "Manifest.toml")
    isfile(path) || return nothing
    return bytes2hex(DME.SHA.sha1(read(path)))[1:12]
end

"""
    dme_benchmark_environment() -> Dict{String,Any}

`quality_tool_benchmark_result` の `environment` に渡す provenance。`key` は
`quality_benchmark_environment_key`（runner_label/os/arch/julia の major.minor のみ）で、
`cpu_model`・`cpu_threads`・`julia_threads`・`manifest_digest` は key に含めない付随情報
（GitHub Actions の runner は同一ラベルでも CPU モデルが変動するため。
src/quality/quality_capture.jl の BenchmarkTools.jl 節を参照）。
"""
function dme_benchmark_environment()::Dict{String, Any}
    runner_label = dme_benchmark_runner_label()
    os = lowercase(string(Sys.KERNEL))
    arch = string(Sys.ARCH)
    julia_version = string(VERSION)
    cpu_model = try
        strip(first(Sys.cpu_info()).model)
    catch
        nothing
    end
    return Dict{String, Any}(
        "key" => quality_benchmark_environment_key(;
            runner_label = runner_label,
            os = os,
            arch = arch,
            julia_version = julia_version,
        ),
        "runner_label" => runner_label,
        "os" => os,
        "arch" => arch,
        "julia_version" => julia_version,
        "cpu_model" => cpu_model === nothing ? nothing : String(cpu_model),
        "cpu_threads" => Sys.CPU_THREADS,
        "julia_threads" => Threads.nthreads(),
        "manifest_digest" => dme_benchmark_manifest_digest(),
    )
end

"""
    DMEBenchmarkCase(; id, group, description, margin_percent, workload)

benchmark 1件の定義。`workload` は引数なしで呼べる関数（入力の構築は呼び出し側で済ませ、
クロージャに捕捉しておく）。`margin_percent` は回帰判定の許容幅（%）で、実測した変動幅に
応じて case ごとに変えられる（Issue #212「回帰判定marginをbenchmarkごとに設定可能にする」）。
"""
struct DMEBenchmarkCase
    id::String
    group::String
    description::String
    margin_percent::Float64
    workload::Function
end

function DMEBenchmarkCase(;
    id::AbstractString,
    group::AbstractString,
    description::AbstractString,
    margin_percent::Real = QUALITY_BENCHMARK_DEFAULT_MARGIN_PERCENT,
    workload::Function,
)
    return DMEBenchmarkCase(
        String(id),
        String(group),
        String(description),
        Float64(margin_percent),
        workload,
    )
end

"""
    dme_benchmark_cases() -> Vector{DMEBenchmarkCase}

suite の全 case。モデル・初期値の構築（＝計測対象外の setup）はこの関数の中で1回だけ行い、
各 workload はそれをクロージャで捕捉する。

`margin_percent` は case ごとに実測した変動幅から決めている（契約 §4.4「margin の根拠」）。
絶対時間が小さい case ほど OS スケジューラ・他プロセスの割り込みの影響を受けやすいため
広めに取る。実測（同一コミット・同一環境で suite を4回連続実行したときの median の最大乖離）:

| case | median | 実測乖離 | margin |
|---|---|---|---|
| `capex_credit_cycle_run` | 4.4 ms | 5.4% | 25% |
| `keen_simulate_rk4` | 0.84 ms | 4.5% | 25% |
| `real_rate_artifact_export` | 0.35 ms | 16.2% | 30% |
| `rbc_impulse_response` | 80 µs | 36.2% | 40% |
| `solow_transition_path` | 12 µs | 8.3% | 50% |
| `sfc_sim_simulate` | 3.5 µs | 34.3% | 50% |

100µs 未満の case は margin を実測乖離よりさらに広く取っている（共有 vCPU の CI runner は
ローカルより変動が大きいという前提。狭い threshold で不安定な `regressed` を出すより、
大きな回帰だけを拾う方を優先する — Issue #212「CIのノイズを考慮し、過度に狭いthresholdを
設定しない」）。裏返しとして、これらの軽い case が検出できるのは 40–50% 以上の回帰だけである。
"""
function dme_benchmark_cases()::Vector{DMEBenchmarkCase}
    # --- 1. Solow: 収束経路（純粋な数値反復） -----------------------------------
    solow = SolowModel(0.3, 0.2, 0.1, 0.01, 0.02)
    solow_k0 = steady_state(solow).k / 2

    # --- 2. RBC: 技術ショック IRF ------------------------------------------------
    rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)

    # --- 3. SIM 型 SFC: baseline シミュレーション --------------------------------
    sim = SIMModel(; α1 = 0.6, α2 = 0.4, θ = 0.2, G = 20.0)

    # --- 4. Keen: 固定刻み RK4 ---------------------------------------------------
    keen =
        KeenModel(0.025, 0.02, 0.01, 3.0, 0.03, 0.0400641, 6.41e-5, -0.0065, exp(-5), 20.0)

    # --- 5. 部門別 CAPEX・信用循環モデル: シナリオ実行 ---------------------------
    capex = capex_credit_cycle_model(capex_credit_cycle_default_targets())

    # --- 6. real-rate model artifact: 構築 + 正準 JSON シリアライズ ---------------
    # 時刻・commit sha はすべて固定値（`now()`/`git rev-parse` を使うと測定対象に
    # 外部プロセス起動が混入し、artifact の内容も実行ごとに変わる）。
    nk = NewKeynesianModel(1.0, 0.02, 0.99, 0.1, 1.5, 0.5, 0.02, 0.8, 0.5, 0.5)
    artifact_decision_time = DateTime(2026, 1, 1, 0, 0, 0)
    artifact_cutoff = DateTime(2025, 12, 31, 23, 0, 0)
    artifact_generated = DateTime(2026, 1, 1, 0, 5, 0)

    return DMEBenchmarkCase[
        DMEBenchmarkCase(;
            id = "solow_transition_path",
            group = "model_simulate",
            description = "Solow モデルの収束経路 T=200（k0 = k*/2）",
            margin_percent = 50.0,
            workload = () -> transition_path(solow, solow_k0; T = 200),
        ),
        DMEBenchmarkCase(;
            id = "rbc_impulse_response",
            group = "model_simulate",
            description = "RBC モデルの技術ショック IRF（ε0 = 1%）",
            margin_percent = 40.0,
            workload = () -> impulse_response(rbc, 0.01),
        ),
        DMEBenchmarkCase(;
            id = "sfc_sim_simulate",
            group = "model_core",
            description = "SIM 型 SFC モデルの baseline シミュレーション T=200",
            margin_percent = 50.0,
            workload = () -> simulate(sim, 0.0; T = 200),
        ),
        DMEBenchmarkCase(;
            id = "keen_simulate_rk4",
            group = "model_core",
            description = "Keen モデルの固定刻み RK4 シミュレーション T=300（年）",
            margin_percent = 25.0,
            workload = () -> simulate(keen, 0.75, 0.9, 0.1; T = 300),
        ),
        DMEBenchmarkCase(;
            id = "capex_credit_cycle_run",
            group = "scenario_run",
            description = "部門別CAPEX・信用循環モデルのシナリオ Sc3 実行（期内10ステップ）",
            margin_percent = 25.0,
            workload = () -> capex_run(capex; scenario = :Sc3),
        ),
        DMEBenchmarkCase(;
            id = "real_rate_artifact_export",
            group = "artifact_export",
            description = "real-rate model artifact の構築と正準 JSON シリアライズ",
            margin_percent = 30.0,
            workload = () -> to_json(
                real_rate_model_artifact(
                    nk;
                    country = "US",
                    scenario_id = "benchmark",
                    run_id = "benchmark-run",
                    shock = :monetary,
                    shock_size = 0.01,
                    model_period_index = 1,
                    decision_time = artifact_decision_time,
                    data_cutoff_at = artifact_cutoff,
                    generated_at = artifact_generated,
                    parameter_set_id = "nk-benchmark",
                    calibration_id = "nk-us-benchmark",
                    calibration_version = "1.0.0",
                    calibration_kind = :fixture,
                    code_commit_sha = "0"^40,
                ),
            ),
        ),
    ]
end

"""
    dme_benchmark_run_case(case::DMEBenchmarkCase; seconds = DME_BENCHMARK_SECONDS,
                            samples_max = DME_BENCHMARK_SAMPLES_MAX,
                            evals = DME_BENCHMARK_EVALS_PER_SAMPLE,
                            warmup_evals = DME_BENCHMARK_WARMUP_EVALS) -> NamedTuple

1 case を実測し、`(id, group, description, margin_percent, median_time_ns, memory_bytes,
allocs, samples, evals_per_sample)` を返す。`BenchmarkTools` が `using` 済みであることを
前提とする（ファイル冒頭コメント参照）。

`median_time_ns` は `BenchmarkTools.median(trial).time`（ns、`evals` で割り済み）を整数へ
丸めた値。1ns 未満に丸まる場合は測定不能として例外を投げる（`QualityBenchmarkResult` が
`median_time_ns <= 0` を拒否するのと同じ判断を、呼び出し側で先に検出する）。
"""
function dme_benchmark_run_case(
    case::DMEBenchmarkCase;
    seconds::Real = DME_BENCHMARK_SECONDS,
    samples_max::Integer = DME_BENCHMARK_SAMPLES_MAX,
    evals::Integer = DME_BENCHMARK_EVALS_PER_SAMPLE,
    warmup_evals::Integer = DME_BENCHMARK_WARMUP_EVALS,
)
    f = case.workload
    Random.seed!(DME_BENCHMARK_SEED)
    for _ in 1:warmup_evals
        f()
    end

    b = BenchmarkTools.@benchmarkable $f()
    b.params.seconds = Float64(seconds)
    b.params.samples = Int(samples_max)
    b.params.evals = Int(evals)
    # `run` は warmup を自動では行わない（`@benchmark` マクロだけが内部で呼ぶ）。
    BenchmarkTools.warmup(b)

    Random.seed!(DME_BENCHMARK_SEED)
    trial = BenchmarkTools.run(b)

    median_ns = round(Int, BenchmarkTools.median(trial).time)
    median_ns > 0 || error(
        "benchmark $(case.id): median time が 1ns 未満に丸まりました（測定不能）。" *
        "workload が最適化で消去されていないか確認してください。",
    )
    return (
        id = case.id,
        group = case.group,
        description = case.description,
        margin_percent = case.margin_percent,
        median_time_ns = median_ns,
        memory_bytes = Int(trial.memory),
        allocs = Int(trial.allocs),
        samples = length(trial.times),
        evals_per_sample = Int(evals),
    )
end

"""
    dme_benchmark_run_suite(; cases = dme_benchmark_cases(), kwargs...) -> Vector{NamedTuple}

suite 全体を実測する。`kwargs` は `dme_benchmark_run_case` へそのまま渡す。
"""
function dme_benchmark_run_suite(;
    cases::AbstractVector{DMEBenchmarkCase} = dme_benchmark_cases(),
    kwargs...,
)
    return [dme_benchmark_run_case(c; kwargs...) for c in cases]
end
