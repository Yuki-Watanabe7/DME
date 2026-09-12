# examples/financial_instability_holdout_demo.jl
#
# 2026-09 financial-instability live holdoutデモ（Issue #260 Part D）
#
# Part A（src/scenarios/long_rate_funding_shock.jl）・Part B
# （src/data/financial_stress_provider.jl・financial_stress_diagnostics.jl）・Part D
# （src/analysis/financial_instability_holdout.jl）を接続し、EDP経由の8系列 +
# NFCI/SLOOSから `FinancialInstabilityAssessment` を構築し、JSON artifact +
# 人が読むreportを保存するまでの経路を、外部API・ネットワークなしで実演する。
#
# **本デモの入力データは全て fictional（架空）である**（test/fixtures/data/financial_stress/・
# test/fixtures/fred/NFCI.json・DRTSCILM.json）。実在の2026-09の金利水準・信用スプレッド・
# funding condition を表すものではない。2026-09の実際の live holdoutを実行する場合は、
# `DME_DATA_MODE=live` と `DATA_PROVIDER_BASE_URL`（EDP）・`FRED_API_KEY`（NFCI/SLOOS）を
# 設定し、`from_date`/`to_date` を実際の対象期間に置き換える。
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
#
# 注意（結果の限界・禁止される解釈）: FIH_NOTES を参照。本デモはIssue #260の対象外事項
# （crisis/recession probability・投資助言・2026-09データを用いたparameter tuning・
# `:as_of` の実装）を一切行わない。
#
# 関連: docs/examples/financial_instability_holdout_demo.md /
#       docs/data/financial_stress.md /
#       docs/adr/0019-long-rate-funding-shock-contract.md

using DME

const FIH_NOTES = String[
    "本assessmentは危機確率・景気後退確率の推定ではない。",
    "本assessmentは投資判断・売買シグナルではない。",
    "入力データは全て fictional（架空）であり、実在の2026-09の観測値ではない。",
    "長期金利の上昇のみでは overall_status = :confirmed にならない（複数dimensionの" *
    "evidenceを要求する、FinancialInstabilityAssessmentの型で強制）。",
    "model_amplification_state・minsky_diagnostic_stateは既存capabilityへの静的citationで" *
    "あり、本デモの入力データに対する新規のモデル実行・較正ではない。",
    ":as_of は実装していない。known_atは監査属性であり「その時点で判断できた」という" *
    "主張には用いない。",
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
    build_financial_instability_holdout_demo_assessment(; from_date, to_date) -> FinancialInstabilityAssessment

Part B の8系列（fixtureモード）とNFCI/SLOOS（fixtureモード）から
`FinancialInstabilityAssessment` を構築する。`DME_DATA_MODE=live` を設定すると、
EDP・FREDへの実際のAPI呼び出しへ切り替わる（fixture_dirの指定は :fixture モードのみ
有効。live/rest_apiでは `DataProviderClient()`/`FredClient()` の既定解決に従う）。
"""
function build_financial_instability_holdout_demo_assessment(;
    from_date::AbstractString = "2026-08-25",
    to_date::AbstractString = "2026-09-04",
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

    return assess_financial_instability(
        raw, from_date, to_date; nfci_latest = nfci_latest, sloos_latest = sloos_latest,
    )
end

# ─────────────────────────────────────────────────────────────────
# レポート
# ─────────────────────────────────────────────────────────────────

_fih_fmt(v::Union{Float64, Missing}) = v === missing ? "N/A（欠測）" : string(round(v; digits = 1))
_fih_fmt(t::Union{Tuple{String, Float64}, Nothing}) =
    t === nothing ? "N/A（欠測）" : "$(round(t[2]; digits = 2)) ($(t[1]))"

function _fih_write_report(path::AbstractString, a)
    open(path, "w") do io
        println(io, "# 2026-09 Financial-Instability Live Holdout（fictional demo）\n")
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

function run_financial_instability_holdout_demo(;
    outdir::AbstractString,
    from_date::AbstractString = "2026-08-25",
    to_date::AbstractString = "2026-09-04",
    verbose::Bool = true,
)
    mkpath(outdir)
    a = build_financial_instability_holdout_demo_assessment(;
        from_date = from_date, to_date = to_date,
    )
    assessment_path = save_financial_instability_assessment(joinpath(outdir, "assessment.json"), a)
    report_path = _fih_write_report(joinpath(outdir, "report.md"), a)

    verbose && println("overall_status = $(a.overall_status)（evidence: $(join(a.overall_evidence, ", "))）")

    return (
        outdir = outdir,
        assessment = a,
        assessment_path = assessment_path,
        report_path = report_path,
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

    println(
        """
╔═══════════════════════════════════════════════════════════════════╗
║  2026-09 Financial-Instability Live Holdout デモ                    ║
║  Part A（shock semantics）+ Part B（EDP consumer）+ Part D（診断）    ║
╚═══════════════════════════════════════════════════════════════════╝

  出力先: $(outdir)

注意: 入力データは全て fictional（架空）であり、実在の2026-09の観測値ではない。
      本出力は危機確率・景気後退確率・投資判断・売買シグナルではない。
""",
    )

    out = run_financial_instability_holdout_demo(; outdir = outdir)

    println(
        """

完了。出力ディレクトリ: $(out.outdir)

overall_status: $(out.assessment.overall_status)
evidence: $(join(out.assessment.overall_evidence, ", "))
成果物: $(out.assessment_path)
        $(out.report_path)
""",
    )
    for note in FIH_NOTES
        println("  - ", note)
    end
end
