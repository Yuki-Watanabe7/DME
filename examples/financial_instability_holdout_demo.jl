# examples/financial_instability_holdout_demo.jl
#
# 2026-09 financial-instability live holdoutデモ（Issue #260 Part D）+
# pre-FOMC canonical live snapshot（Issue #271 Part A）+
# post-FOMC比較・finance-checker handoff（Issue #271 Part B・Part C・Part D）
#
# Part A（src/scenarios/long_rate_funding_shock.jl）・Part B
# （src/data/financial_stress_provider.jl・financial_stress_diagnostics.jl）・Part D
# （src/analysis/financial_instability_holdout.jl）を接続し、EDP経由の8系列 +
# NFCI/SLOOSから `FinancialInstabilityAssessment` を構築し、JSON artifact +
# 人が読むreport + run manifest（Issue #271 Part A）を保存するまでの経路を実演する。
#
# **既定（fixtureモード）では入力データは全て fictional（架空）である**
# （test/fixtures/data/financial_stress/・test/fixtures/fred/NFCI.json・DRTSCILM.json）。
# 実在の2026-09の金利水準・信用スプレッド・funding conditionを表すものではない。
#
# 2026-09の実際のpre/post-FOMC live holdoutを実行する場合（Issue #271 Part A/B）は、
# `DME_DATA_MODE=live` と `DATA_PROVIDER_BASE_URL`（EDP）・`FRED_API_KEY`（NFCI/SLOOS・EDP側）を
# 設定した上で `run_financial_instability_holdout_live_snapshot` を呼ぶ（fixtureベースの
# artifactを誤って canonical として扱わないよう、`DME_DATA_MODE=live` でなければ拒否する）。
# from_date/to_date は現在の市場水準を見て選ばず、`select_observation_window`（凍結済みの
# ルール、既定 `FIH_DEFAULT_LOOKBACK_DAYS`=28暦日）で機械的に選定する。
#
# 実行方法:
#   julia --project=. examples/financial_instability_holdout_demo.jl
#
# 成果物の出力先（既定はリポジトリ内 artifacts/、環境変数で上書き可）:
#   FIH_DEMO_OUTDIR=/path/to/dir
#
# 保存する成果物:
#   assessment.json … FinancialInstabilityAssessment（financial_instability_assessment_to_dict）
#   report.md        … 人が読むサマリー
#   run_manifest.json … freeze対象（DME code revision・rule/threshold version・catalog
#                        version・observation window・各系列のprovenance）（Issue #271 Part A）
#
# 注意（結果の限界・禁止される解釈）: FIH_NOTES を参照。本ファイルはIssue #260/#271の
# 対象外事項（crisis/recession probability・投資助言・2026-09データを用いたparameter
# tuning・`:as_of` の実装）を一切行わない。
#
# 関連: docs/examples/financial_instability_holdout_demo.md /
#       docs/data/financial_stress.md /
#       docs/adr/0019-long-rate-funding-shock-contract.md /
#       Issue #260, #271

using DME
using Dates

# DME 本体が既に依存として持つ stdlib を DME 経由で参照する（test/Project.toml には
# 含まれない stdlib を examples 側で `using` すると、`Pkg.test()` が使う test 環境
# （test/Project.toml）でロードに失敗するため。`examples/capex_credit_cycle_demo.jl:53`
# の `const JSON3 = DME.JSON3` と同じ idiom）。
const JSON3 = DME.JSON3
const Downloads = DME.Downloads

const FIH_NOTES = String[
    "本assessmentは危機確率・景気後退確率の推定ではない。",
    "本assessmentは投資判断・売買シグナルではない。",
    "fixtureモードの入力データは全て fictional（架空）であり、実在の観測値ではない。" *
    "liveモードでは実際の観測値を使うが、それでも上記2点（危機確率・投資判断ではない）は" *
    "変わらない。",
    "長期金利の上昇のみでは overall_status = :confirmed にならない（複数dimensionの" *
    "evidenceを要求する、FinancialInstabilityAssessmentの型で強制）。",
    "model_amplification_state・minsky_diagnostic_stateは既存capabilityへの静的citationで" *
    "あり、本ファイルの入力データに対する新規のモデル実行・較正ではない。",
    ":as_of は実装していない。known_atは監査属性であり「その時点で判断できた」という" *
    "主張には用いない。",
    "観測ウィンドウ（from_date/to_date）は現在の市場水準を見てから選んでいない" *
    "（select_observation_window、Issue #271 Part A で事前に凍結したルール）。",
]

# ─────────────────────────────────────────────────────────────────
# データ取得
# ─────────────────────────────────────────────────────────────────

"""
    _fih_demo_fixture_dir() -> String

金融ストレス観測（Part B）の fixture ディレクトリ。`test/fixtures/data/financial_stress/`
（fictional）。
"""
_fih_demo_fixture_dir() =
    joinpath(@__DIR__, "..", "test", "fixtures", "data", "financial_stress")

"""
    FIH_DEFAULT_LOOKBACK_DAYS

観測ウィンドウ（`from_date`→`to_date`）の既定ラックバック日数（暦日）。Issue #271 Part A で
事前に凍結した値（直近4週間）。現在の市場水準を見てから選んでいない。
"""
const FIH_DEFAULT_LOOKBACK_DAYS = 28

"""
観測ウィンドウ選定ルールの説明文。`run_manifest.json` にそのまま埋め込む
（Issue #271 Part A 受け入れ条件「observation selection ruleをfreezeする」）。
"""
const FIH_OBSERVATION_WINDOW_SELECTION_RULE = "to_date = window_key系列（既定 " *
    ":long_nominal_yield、DGS10）でto_date_cutoff以前の非欠測の最新観測日。from_date = " *
    "同系列で(to_date - lookback_days暦日)以前の非欠測の最新観測日。lookback_daysは事前に" *
    "固定（既定28暦日）し、現在のスプレッド水準を見てから選ばない。いずれかの日付が" *
    "見つからない場合はArgumentError（0や近い日付への暗黙の妥協をしない）。"

"""
    select_observation_window(raw; to_date_cutoff = nothing,
        lookback_days = FIH_DEFAULT_LOOKBACK_DAYS, window_key = :long_nominal_yield)
        -> NamedTuple

Issue #271 Part A の観測ウィンドウ選定ルール（`FIH_OBSERVATION_WINDOW_SELECTION_RULE`）を
実装する。`window_key` 系列（`raw::FinancialStressRawDataset`、`src/data/financial_stress_provider.jl`）
の実際の観測日だけから `from_date`/`to_date` を機械的に決める。`to_date_cutoff`（`nothing` なら
上限なし＝系列の最新観測日）以前で非欠測の最新日を `to_date`、そこから `lookback_days` 暦日
以前で非欠測の最新日を `from_date` とする。該当日が無ければ `ArgumentError`。
"""
function select_observation_window(
    raw::FinancialStressRawDataset;
    to_date_cutoff::Union{AbstractString, Nothing} = nothing,
    lookback_days::Int = FIH_DEFAULT_LOOKBACK_DAYS,
    window_key::Symbol = :long_nominal_yield,
)
    lookback_days > 0 ||
        throw(ArgumentError("lookback_days は正の整数でなければなりません: $lookback_days"))
    haskey(raw.observations, window_key) ||
        throw(ArgumentError("dataset に存在しない key です: $window_key"))
    obs = raw.observations[window_key]
    obs.status == :ok || throw(
        ArgumentError(
            "観測ウィンドウ選定の基準系列 $window_key の取得に失敗しています" *
            "（status=$(obs.status)）: $(obs.detail)",
        ),
    )
    series = obs.series

    to_date = _fih_latest_on_or_before(series, to_date_cutoff)
    to_date === nothing && throw(
        ArgumentError(
            "観測ウィンドウ選定に失敗: $window_key に to_date_cutoff=$(to_date_cutoff) " *
            "以前の非欠測観測がありません",
        ),
    )

    from_cutoff = string(Date(to_date) - Day(lookback_days))
    from_date = _fih_latest_on_or_before(series, from_cutoff)
    from_date === nothing && throw(
        ArgumentError(
            "観測ウィンドウ選定に失敗: $window_key に $from_cutoff（to_date=$to_date から " *
            "$lookback_days 暦日前）以前の非欠測観測がありません（データ期間が短すぎます）",
        ),
    )

    return (
        from_date = from_date,
        to_date = to_date,
        lookback_days = lookback_days,
        window_key = window_key,
    )
end

"""`s`（`FinancialStressSeries`）の中で `cutoff` 以前（`nothing` なら上限なし）の非欠測の
最新観測日を返す。無ければ `nothing`（forward-fill・近い日付への妥協をしない）。"""
function _fih_latest_on_or_before(
    s::FinancialStressSeries,
    cutoff::Union{AbstractString, Nothing},
)::Union{String, Nothing}
    for i in length(s.dates):-1:1
        (cutoff === nothing || s.dates[i] <= cutoff) &&
            s.values[i] !== missing &&
            return s.dates[i]
    end
    return nothing
end

"""
    build_financial_instability_holdout_demo_assessment(; from_date, to_date, lookback_days)
        -> NamedTuple

Part B の8系列とNFCI/SLOOSから `FinancialInstabilityAssessment` を構築する。`DME_DATA_MODE=live`
を設定すると、EDP・FREDへの実際のAPI呼び出しへ切り替わる（fixture_dirの指定は :fixture
モードのみ有効。live/rest_apiでは `DataProviderClient()`/`FredClient()` の既定解決に従う）。

`from_date`/`to_date` を両方省略（`nothing`）すると `select_observation_window` で自動選定する
（Issue #271 Part A）。片方だけ省略はエラー。既定値（`"2026-08-25"`/`"2026-09-04"`）は既存の
fixtureデモ挙動を変えないための後方互換用。

戻り値は `(assessment, raw, nfci_series, sloos_series, mode, window_auto)` の `NamedTuple`。
"""
function build_financial_instability_holdout_demo_assessment(;
    from_date::Union{AbstractString, Nothing} = "2026-08-25",
    to_date::Union{AbstractString, Nothing} = "2026-09-04",
    lookback_days::Int = FIH_DEFAULT_LOOKBACK_DAYS,
)
    live = get(ENV, "DME_DATA_MODE", "") == "live"
    provider_client = live ? DataProviderClient() :
                      DataProviderClient(; mode = :fixture, fixture_dir = _fih_demo_fixture_dir())
    raw = build_financial_stress_raw_dataset(; client = provider_client)

    fred_client = live ? FredClient() : FredClient(; mode = :fixture)
    nfci = fetch_fred_series("NFCI"; client = fred_client)
    sloos = fetch_fred_series("DRTSCILM"; client = fred_client)
    nfci_latest = isempty(nfci.dates) ? nothing : (nfci.dates[end], nfci.values[end])
    sloos_latest = isempty(sloos.dates) ? nothing : (sloos.dates[end], sloos.values[end])

    window_auto = from_date === nothing && to_date === nothing
    (from_date === nothing) == (to_date === nothing) || throw(
        ArgumentError("from_date と to_date は両方指定するか、両方省略（自動選定）してください"),
    )
    resolved_from, resolved_to = if window_auto
        w = select_observation_window(raw; lookback_days = lookback_days)
        w.from_date, w.to_date
    else
        from_date, to_date
    end

    a = assess_financial_instability(
        raw, resolved_from, resolved_to; nfci_latest = nfci_latest, sloos_latest = sloos_latest,
    )

    return (
        assessment = a,
        raw = raw,
        nfci_series = nfci,
        sloos_series = sloos,
        mode = live ? :live : :fixture,
        window_auto = window_auto,
    )
end

# ─────────────────────────────────────────────────────────────────
# run manifest（Issue #271 Part A: freeze対象の記録）
# ─────────────────────────────────────────────────────────────────

"""現在の git revision（短縮SHA）。取得できなければ `"unknown"`（`_capex_demo_git_revision`、
examples/capex_credit_cycle_demo.jl と同じパターン）。"""
function _fih_git_revision()
    try
        rev = readchomp(`git -C $(@__DIR__) rev-parse --short HEAD`)
        isempty(rev) ? "unknown" : String(rev)
    catch
        "unknown"
    end
end

"""EDPの `/health` をベストエフォートで取得する。失敗（未起動・タイムアウト等）しても
`nothing` を返すのみで呼び出し元を落とさない（missing/stale を偽装しない、という本ファイル
冒頭コメントの方針を踏襲）。"""
function _fih_fetch_edp_identity(provider_base::AbstractString)::Union{Dict{String, Any}, Nothing}
    isempty(strip(provider_base)) && return nothing
    try
        buffer = IOBuffer()
        url = "$(rstrip(provider_base, '/'))/health"
        response = Downloads.request(url; output = buffer, timeout = 10.0)
        response.status == 200 || return nothing
        data = JSON3.read(String(take!(buffer)))
        return Dict{String, Any}(
            "api_version" => get(data, "api_version", nothing),
            "application_version" => get(data, "application_version", nothing),
            "contract_version" => get(data, "contract_version", nothing),
            "schema_version" => get(data, "schema_version", nothing),
        )
    catch
        return nothing
    end
end

_fih_obs_tuple(t::Union{Tuple{String, Float64}, Nothing}) =
    t === nothing ? nothing : Dict{String, Any}("date" => t[1], "value" => t[2])

"""8系列（EDP経由）それぞれの provenance（`key`・`provider_series_id`・`status`・`mode`・
`retrieved_at`・観測件数・最新観測日）。Issue #271 Part A 受け入れ条件「各観測系列の実
observation date/provenance/missing-stale状態が追跡可能である」。"""
function _fih_stress_series_provenance(raw::FinancialStressRawDataset)::Vector{Dict{String, Any}}
    entries = Dict{String, Any}[]
    for key in sort(collect(keys(raw.observations)); by = string)
        obs = raw.observations[key]
        series = obs.series
        latest = series === nothing ? nothing : _fih_latest_series_value(series)
        push!(
            entries,
            Dict{String, Any}(
                "key" => String(key),
                "provider_series_id" => obs.spec.provider_series_id,
                "status" => String(obs.status),
                "mode" => String(obs.mode),
                "retrieved_at" => obs.retrieved_at,
                "n_observations" => series === nothing ? 0 : length(series),
                "latest_observation" => _fih_obs_tuple(latest),
                "detail" => obs.detail,
            ),
        )
    end
    return entries
end

function _fih_latest_series_value(s::FinancialStressSeries)::Union{Tuple{String, Float64}, Nothing}
    for i in length(s.dates):-1:1
        s.values[i] === missing || return (s.dates[i], s.values[i])
    end
    return nothing
end

"""NFCI/SLOOS（`DataSeries`、FRED直接経路）の provenance。"""
function _fih_fred_series_provenance(
    fred_series_id::AbstractString,
    s,
    mode::Symbol,
)::Dict{String, Any}
    latest = isempty(s.dates) ? nothing : (s.dates[end], s.values[end])
    return Dict{String, Any}(
        "key" => fred_series_id,
        "provider_series_id" => fred_series_id,
        "status" => isempty(s.dates) ? "missing_series" : "ok",
        "mode" => String(mode),
        "retrieved_at" => nothing,
        "n_observations" => length(s.dates),
        "latest_observation" => _fih_obs_tuple(latest),
        "detail" => "",
    )
end

"""
    _fih_build_run_manifest(built; lookback_days) -> Dict{String,Any}

Issue #271 Part A の freeze 対象（DME code revision・rule/threshold version・catalog
version・EDP identity・observation window・各系列の provenance）をまとめた manifest を
構築する。`built` は `build_financial_instability_holdout_demo_assessment` の戻り値。
"""
function _fih_build_run_manifest(built; lookback_days::Int)::Dict{String, Any}
    a = built.assessment
    raw = built.raw
    d = financial_instability_assessment_to_dict(a)
    edp_identity = built.mode == :live ? _fih_fetch_edp_identity(raw.provider_base) : nothing

    return Dict{String, Any}(
        "manifest_kind" => "financial-instability-holdout-run-manifest/1.0.0",
        "issue" => "#271 Part A",
        "run_timestamp" => Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sssZ"),
        "dme_code_revision" => _fih_git_revision(),
        "data_mode" => String(built.mode),
        "dme_data_mode_env" => get(ENV, "DME_DATA_MODE", ""),
        "assessment_version" => a.version,
        "rule_version" => a.thresholds.version,
        "thresholds" => d["thresholds"],
        "financial_stress_catalog_version" => raw.catalog_version,
        "provider_base" => raw.provider_base,
        "edp_identity" => edp_identity,
        "observation_window" => Dict{String, Any}(
            "from_date" => a.from_date,
            "to_date" => a.to_date,
            "lookback_days" => lookback_days,
            "auto_selected" => built.window_auto,
            "selection_rule" => FIH_OBSERVATION_WINDOW_SELECTION_RULE,
        ),
        "series_provenance" => vcat(
            _fih_stress_series_provenance(raw),
            [
                _fih_fred_series_provenance("NFCI", built.nfci_series, built.mode),
                _fih_fred_series_provenance("DRTSCILM", built.sloos_series, built.mode),
            ],
        ),
        "historical_validation_citation" => a.model_amplification_state.citation,
        "assessment_identity_hash" => d["identity_hash"],
        "raw_dataset_status_counts" => get(raw.metadata, "status_counts", nothing),
        "raw_dataset_identity" => get(raw.metadata, "raw_identity", nothing),
        "notes" => FIH_NOTES,
    )
end

# ─────────────────────────────────────────────────────────────────
# レポート
# ─────────────────────────────────────────────────────────────────

_fih_fmt(v::Union{Float64, Missing}) = v === missing ? "N/A（欠測）" : string(round(v; digits = 1))
_fih_fmt(t::Union{Tuple{String, Float64}, Nothing}) =
    t === nothing ? "N/A（欠測）" : "$(round(t[2]; digits = 2)) ($(t[1]))"

function _fih_write_report(path::AbstractString, a, mode::Symbol, manifest::Dict{String, Any})
    open(path, "w") do io
        title = mode == :live ?
                "# 2026-09 Financial-Instability Live Holdout — Canonical Snapshot（real market data）\n" :
                "# 2026-09 Financial-Instability Live Holdout（fictional demo）\n"
        println(io, title)
        if mode == :live
            println(
                io,
                "本reportは実際の live 観測値（`DME_DATA_MODE=live`）から生成した。" *
                "詳細な provenance は `run_manifest.json` を参照。\n",
            )
        else
            println(io, "入力データは全て fictional（架空）である。\n")
        end
        println(io, "対象期間: $(a.from_date) → $(a.to_date)\n")
        println(io, "## Overall\n")
        println(io, "- `overall_status`: **$(a.overall_status)**")
        println(io, "- evidence: $(join(a.overall_evidence, ", "))\n")
        println(io, "## Dimensions\n")
        println(io, "| dimension | label | 詳細 |")
        println(io, "|---|---|---|")
        println(
            io,
            "| trigger_state | $(a.trigger_state.label) | " *
            "long_nominal_yield_shift_bps=$(_fih_fmt(a.trigger_state.long_nominal_yield_shift_bps)) |",
        )
        println(
            io,
            "| weak_credit_state | $(a.weak_credit_state.label) | " *
            "divergence_shift_bps=$(_fih_fmt(a.weak_credit_state.divergence_shift_bps))・" *
            "ccc_oas_latest=$(_fih_fmt(a.weak_credit_state.ccc_oas_latest)) |",
        )
        println(
            io,
            "| funding_state | $(a.funding_state.label) | " *
            "sofr_minus_iorb=$(_fih_fmt(a.funding_state.sofr_minus_iorb_latest_bps))・" *
            "tgcr_minus_iorb=$(_fih_fmt(a.funding_state.tgcr_minus_iorb_latest_bps)) |",
        )
        println(
            io,
            "| broad_conditions_state | $(a.broad_conditions_state.label) | " *
            "nfci=$(_fih_fmt(a.broad_conditions_state.nfci_latest))・" *
            "sloos=$(_fih_fmt(a.broad_conditions_state.sloos_latest)) |",
        )
        println(
            io,
            "| model_amplification_state | (citation) | $(a.model_amplification_state.citation) |",
        )
        println(
            io,
            "| minsky_diagnostic_state | (citation) | $(a.minsky_diagnostic_state.citation) |",
        )
        println(io, "\n## 観測系列 provenance\n")
        println(io, "| key | status | mode | 最新observation日 | 件数 |")
        println(io, "|---|---|---|---|---|")
        for entry in manifest["series_provenance"]
            latest = entry["latest_observation"]
            latest_str = latest === nothing ? "N/A" : "$(latest["date"]) ($(latest["value"]))"
            println(
                io,
                "| $(entry["key"]) | $(entry["status"]) | $(entry["mode"]) | $latest_str | " *
                "$(entry["n_observations"]) |",
            )
        end
        println(io, "\n## 注意事項\n")
        for note in a.caveats
            println(io, "- $note")
        end
    end
    return path
end

# ─────────────────────────────────────────────────────────────────
# 実行
# ─────────────────────────────────────────────────────────────────

"""
    run_financial_instability_holdout_demo(; outdir, from_date, to_date, lookback_days, verbose)
        -> NamedTuple

`assessment.json`・`report.md`・`run_manifest.json`（Issue #271 Part A）を `outdir` に保存する。
`from_date`/`to_date` の既定値は既存の fixture デモ挙動を変えない固定値。両方 `nothing` を渡すと
`select_observation_window` で自動選定する（`run_financial_instability_holdout_live_snapshot` が
使う経路）。
"""
function run_financial_instability_holdout_demo(;
    outdir::AbstractString,
    from_date::Union{AbstractString, Nothing} = "2026-08-25",
    to_date::Union{AbstractString, Nothing} = "2026-09-04",
    lookback_days::Int = FIH_DEFAULT_LOOKBACK_DAYS,
    verbose::Bool = true,
)
    mkpath(outdir)
    built = build_financial_instability_holdout_demo_assessment(;
        from_date = from_date, to_date = to_date, lookback_days = lookback_days,
    )
    a = built.assessment
    assessment_path = save_financial_instability_assessment(joinpath(outdir, "assessment.json"), a)

    manifest = _fih_build_run_manifest(built; lookback_days = lookback_days)
    manifest_path = joinpath(outdir, "run_manifest.json")
    open(manifest_path, "w") do io
        JSON3.pretty(io, manifest)
    end

    report_path = _fih_write_report(joinpath(outdir, "report.md"), a, built.mode, manifest)

    verbose && println("overall_status = $(a.overall_status)（evidence: $(join(a.overall_evidence, ", "))）")

    return (
        outdir = outdir,
        assessment = a,
        assessment_path = assessment_path,
        report_path = report_path,
        manifest_path = manifest_path,
        manifest = manifest,
    )
end

"""
    run_financial_instability_holdout_live_snapshot(; outdir, lookback_days, verbose) -> NamedTuple

Issue #271 Part A の canonical live snapshot 用エントリポイント。`DME_DATA_MODE=live` が
設定されている場合のみ実行できる（fixture ベースの artifact が誤って canonical として
扱われることを防ぐ）。`from_date`/`to_date` は `select_observation_window` で自動選定する。
"""
function run_financial_instability_holdout_live_snapshot(;
    outdir::AbstractString,
    lookback_days::Int = FIH_DEFAULT_LOOKBACK_DAYS,
    verbose::Bool = true,
)
    get(ENV, "DME_DATA_MODE", "") == "live" || throw(
        ArgumentError(
            "run_financial_instability_holdout_live_snapshot は DME_DATA_MODE=live が" *
            "設定されている場合のみ実行できます（canonical snapshot が意図せず fixture " *
            "データになることを防ぐ）。",
        ),
    )
    return run_financial_instability_holdout_demo(;
        outdir = outdir,
        from_date = nothing,
        to_date = nothing,
        lookback_days = lookback_days,
        verbose = verbose,
    )
end

# ─────────────────────────────────────────────────────────────────
# post-FOMC比較・finance-checker handoff（Issue #271 Part B・Part C・Part D）
# ─────────────────────────────────────────────────────────────────

"""`dir` に保存済みの `assessment.json`/`run_manifest.json`（`run_financial_instability_holdout_demo`
が保存した形）を `Dict{String,Any}` として読み込む。新規のEDP/FRED fetchを行わない。"""
function _fih_load_snapshot_dicts(dir::AbstractString)
    assessment = JSON3.read(read(joinpath(dir, "assessment.json"), String), Dict{String, Any})
    manifest = JSON3.read(read(joinpath(dir, "run_manifest.json"), String), Dict{String, Any})
    return (assessment = assessment, manifest = manifest)
end

_fic_fmt_diff(d::Dict{String, Any}, key::String = "delta") =
    d[key] === nothing ? "N/A" : string(round(d[key]; digits = 1))
_fic_fmt_num(v) = v === nothing ? "N/A" : string(round(v; digits = 1))
_fic_fmt_tuple_value(t) = t === nothing ? "N/A" : "$(round(t["value"]; digits = 1)) ($(t["date"]))"

function _fih_write_comparison_report(
    path::AbstractString,
    comparison::FinancialInstabilityComparison,
    handoff::FinancialInstabilityHandoff,
)
    open(path, "w") do io
        println(io, "# 2026-09 Financial-Instability Live Holdout — pre/post-FOMC比較\n")
        println(
            io,
            "pre: $(comparison.pre_window["from_date"]) → $(comparison.pre_window["to_date"])" *
            "（$(comparison.pre_data_mode)）",
        )
        println(
            io,
            "post: $(comparison.post_window["from_date"]) → $(comparison.post_window["to_date"])" *
            "（$(comparison.post_data_mode)）\n",
        )
        println(io, "## 結論\n")
        println(io, "- `conclusion`: **$(comparison.conclusion)**")
        println(io, "- 根拠: $(comparison.conclusion_reason)\n")
        println(io, "## overall_status の遷移\n")
        println(
            io,
            "- $(comparison.pre_overall_status) → $(comparison.post_overall_status)" *
            "（changed=$(comparison.overall_status_changed)）",
        )
        println(io, "- pre evidence: $(join(comparison.pre_overall_evidence, ", "))")
        println(io, "- post evidence: $(join(comparison.post_overall_evidence, ", "))\n")
        println(io, "## version 整合性\n")
        vc = comparison.version_consistency
        println(io, "- all_semantic_versions_match: **$(vc["all_semantic_versions_match"])**")
        println(
            io,
            "- dme_code_revision: $(vc["dme_code_revision"]["pre"]) → " *
            "$(vc["dme_code_revision"]["post"])（match=$(vc["dme_code_revision"]["match"])）\n",
        )
        println(io, "## dimension別 label 遷移\n")
        println(io, "| dimension | pre | post | changed |")
        println(io, "|---|---|---|---|")
        for d in comparison.dimensions
            println(io, "| $(d.dimension) | $(d.pre_label) | $(d.post_label) | $(d.label_changed) |")
        end
        println(io, "\n## 主要指標の変化（bp）\n")
        t = only(filter(d -> d.dimension == :trigger_state, comparison.dimensions)).values
        w = only(filter(d -> d.dimension == :weak_credit_state, comparison.dimensions)).values
        f = only(filter(d -> d.dimension == :funding_state, comparison.dimensions)).values
        println(io, "| 指標 | pre→post | delta |")
        println(io, "|---|---|---|")
        println(
            io,
            "| long_nominal_yield_shift_bps | " *
            "$(_fic_fmt_num(t["long_nominal_yield_shift_bps"]["pre"]))→" *
            "$(_fic_fmt_num(t["long_nominal_yield_shift_bps"]["post"])) | " *
            "$(_fic_fmt_diff(t["long_nominal_yield_shift_bps"])) |",
        )
        println(
            io,
            "| divergence_shift_bps（CCC-broad HY） | " *
            "$(_fic_fmt_num(w["divergence_shift_bps"]["pre"]))→" *
            "$(_fic_fmt_num(w["divergence_shift_bps"]["post"])) | " *
            "$(_fic_fmt_diff(w["divergence_shift_bps"])) |",
        )
        println(
            io,
            "| sofr_minus_iorb_latest_bps | " *
            "$(_fic_fmt_tuple_value(f["sofr_minus_iorb_latest_bps"]["pre"]))→" *
            "$(_fic_fmt_tuple_value(f["sofr_minus_iorb_latest_bps"]["post"])) | " *
            "$(_fic_fmt_diff(f["sofr_minus_iorb_latest_bps"], "value_delta")) |",
        )
        println(io, "\n## unavailable evidence\n")
        if isempty(handoff.unavailable_evidence)
            println(io, "（なし。全系列 status=ok）")
        else
            for n in handoff.unavailable_evidence
                println(io, "- $n")
            end
        end
        println(io, "\n## 注意事項\n")
        for note in comparison.caveats
            println(io, "- $note")
        end
        println(io, "\n## データの位置づけ（Issue #271 Part D）\n")
        for (k, v) in handoff.classification
            println(io, "- **$k**: $v")
        end
    end
    return path
end

"""
    run_financial_instability_post_fomc_comparison(; pre_dir, outdir,
        lookback_days = FIH_DEFAULT_LOOKBACK_DAYS, verbose = true) -> NamedTuple

Issue #271 Part B（post-FOMC live snapshot再実行）・Part C（pre/post比較）・Part D
（finance-checker handoff artifact）をまとめて実行する。

`pre_dir`（`run_financial_instability_holdout_live_snapshot` が保存した既存ディレクトリ、
Part Aの成果物）を読み込み、`DME_DATA_MODE=live` の下で新たに
`run_financial_instability_holdout_live_snapshot` を実行して post snapshot を作る。
pre-FOMCと同じ `lookback_days`（既定 `FIH_DEFAULT_LOOKBACK_DAYS`）を使うことで、
parameter/threshold/selection ruleを変更しない（Issue #271 Post-FOMC受け入れ条件）。

保存する成果物（`outdir`）:
- `assessment.json`/`report.md`/`run_manifest.json`（post snapshot本体、
  `run_financial_instability_holdout_live_snapshot` と同じ形）
- `comparison.json`（Part C、`financial_instability_comparison_to_dict`）
- `handoff.json`（Part D、`financial_instability_handoff_to_dict`）
- `comparison_report.md`（人が読むpre/post比較サマリー）
"""
function run_financial_instability_post_fomc_comparison(;
    pre_dir::AbstractString,
    outdir::AbstractString,
    lookback_days::Int = FIH_DEFAULT_LOOKBACK_DAYS,
    verbose::Bool = true,
)
    pre = _fih_load_snapshot_dicts(pre_dir)

    post = run_financial_instability_holdout_live_snapshot(;
        outdir = outdir, lookback_days = lookback_days, verbose = verbose,
    )
    post_assessment = financial_instability_assessment_to_dict(post.assessment)
    post_manifest = post.manifest

    comparison = compare_financial_instability_assessments(
        pre.assessment, pre.manifest, post_assessment, post_manifest,
    )
    comparison_path = save_financial_instability_comparison(joinpath(outdir, "comparison.json"), comparison)

    handoff = build_financial_instability_handoff(pre.assessment, pre.manifest, post_assessment, post_manifest)
    handoff_path = save_financial_instability_handoff(joinpath(outdir, "handoff.json"), handoff)

    report_path = _fih_write_comparison_report(
        joinpath(outdir, "comparison_report.md"), comparison, handoff,
    )

    verbose && println(
        "conclusion = $(comparison.conclusion)（$(comparison.pre_overall_status) → " *
        "$(comparison.post_overall_status)）",
    )

    return (
        outdir = outdir,
        post = post,
        comparison = comparison,
        comparison_path = comparison_path,
        handoff = handoff,
        handoff_path = handoff_path,
        comparison_report_path = report_path,
    )
end

# ─────────────────────────────────────────────────────────────────
# スクリプトとして直接実行された場合のみ走らせる（include では実行しない）
# ─────────────────────────────────────────────────────────────────

if abspath(PROGRAM_FILE) == @__FILE__
    outdir = get(
        ENV,
        "FIH_DEMO_OUTDIR",
        joinpath(@__DIR__, "..", "artifacts", "financial_instability_holdout_demo"),
    )
    live = get(ENV, "DME_DATA_MODE", "") == "live"

    println(
        """
╔═══════════════════════════════════════════════════════════════════╗
║  2026-09 Financial-Instability Live Holdout デモ / Canonical Snapshot ║
║  Part A（shock semantics）+ Part B（EDP consumer）+ Part D（診断）    ║
║  + Issue #271 Part A（pre-FOMC live snapshot）                       ║
╚═══════════════════════════════════════════════════════════════════╝

  出力先: $(outdir)
  data_mode: $(live ? "live" : "fixture")

$(live ?
            "注意: liveモードで実際の観測値を取得する。本出力は危機確率・景気後退確率・" *
            "投資判断・売買シグナルではない。" :
            "注意: 入力データは全て fictional（架空）であり、実在の2026-09の観測値ではない。\n" *
            "      本出力は危機確率・景気後退確率・投資判断・売買シグナルではない。")
""",
    )

    out = live ? run_financial_instability_holdout_live_snapshot(; outdir = outdir) :
          run_financial_instability_holdout_demo(; outdir = outdir)

    println(
        """

完了。出力ディレクトリ: $(out.outdir)

overall_status: $(out.assessment.overall_status)
evidence: $(join(out.assessment.overall_evidence, ", "))
成果物: $(out.assessment_path)
        $(out.report_path)
        $(out.manifest_path)
""",
    )
    for note in FIH_NOTES
        println("  - ", note)
    end
end
