# examples/capex_credit_cycle_demo.jl
#
# 部門別CAPEX・信用循環モデルの統合デモ（Issue #186 / `I-8`）
#
# Sc0（baseline）〜Sc4（需要期待下方修正 + CAPEX削減 + 信用ショック + 金融緩和）の5シナリオを、
# 外部APIキー・ネットワークなしで比較する。シナリオ実行 → 会計恒等式検証（12項目）→ 診断
# （ラベル・資金繰り・ループ利得・非線形性近傍・反実仮想寄与 A・share_C）→ 閾値感応度 →
# 比較API v2（mechanismモード、同一モデル内のシナリオ比較）→ 可視化 → 数値・図表・
# provenanceのrun単位保存、までを1本で決定的に完走する。
#
# 実行方法:
#   julia --project=. examples/capex_credit_cycle_demo.jl
#
# 成果物の出力先（既定はリポジトリ内 artifacts/、環境変数で上書き可）:
#   CAPEX_CC_DEMO_OUTDIR=/path/to/dir
#
# 保存する成果物:
#   capex_scenario_Sc0.json .. capex_scenario_Sc4.json … シナリオ別の基礎系列・baseline比乖離・
#                                診断ラベル・資金繰り診断・ループ診断・会計検証要約・閾値感応度
#   capex_judgment_questions.json … Q2のA（Sc3）・Q3のshare_C（Sc2/Sc3、主方式+加法分解+残差比）・
#                                Q4のSc3 vs Sc4比較
#   capex_comparison_v2.json    … compare_results_v2のmechanismモード比較（Sc0 vs Sc3）
#   capex_run_manifest.json     … metadata予約キー20個（Sc3代表）・警告・打ち切り・provenance・
#                                注意事項7件
#   report.md                   … 人が読むサマリー
#   capex_sector_series_Sc3.png / capex_scenario_comparison.png /
#   capex_diagnostic_label_Sc3.png / capex_funding_pressure_Sc3.png
#
# 注意（結果の限界・禁止される解釈。統合設計 §8.4）:
#   1. パラメータは例示値であり実データによる較正を経ていない。系列の水準の絶対値に意味はなく、
#      baseline比乖離の符号・順序・大小関係のみが解釈対象である。
#   2. 診断ラベル `broad_downturn` はモデル内の診断であり、景気後退の予測・確率ではない。
#   3. `A` と `share_C` は同一実装内の反実仮想寄与であり因果推定ではない。
#   4. `funding_pressure_s` は倒産・信用イベントの予測ではない（デフォルトを内生化していない）。
#   5. 会計は残差部門 `SX` を置いて閉じており、経済全体で閉じていない（`accounting_closure = :partial`）。
#      SFC検証済みと同じ意味ではない。
#   6. `cost_capital_s`・`ai_exp`・`target_cap_s1`・`cancel_s1` は潜在変数であり、単独の水準を
#      提示しない。
#   7. 本出力は投資判断・政策立案の根拠として使用することを意図していない。
#
# 関連: docs/examples/capex_credit_cycle_demo.md /
#       docs/architecture/capex_credit_cycle_integration.md §8（本デモの正本） /
#       docs/models/capex_credit_cycle_analysis_contract.md（判定問題 Q1–Q5） /
#       docs/adr/0013-capex-credit-cycle-integration-contract.md /
#       docs/adr/0014-digital-twin-naming-conditions.md

# ヘッドレス環境（CI・無表示）でプロット保存を可能にする
get!(ENV, "GKSwstype", "nul")

using DME
using Plots
using Dates: now
const JSON3 = DME.JSON3

# ─────────────────────────────────────────────────────────────────
# 定数
# ─────────────────────────────────────────────────────────────────

const CAPEX_DEMO_SCENARIOS = (:Sc0, :Sc1, :Sc2, :Sc3, :Sc4)

# 基礎系列（統合設計 §8.3-1）。水準変数（相対乖離）とレート/スプレッド変数（絶対差）を分ける
# （分析契約 §2.4 の baseline比乖離の規約）。
const CAPEX_DEMO_LEVEL_VARS = (
    :capex_exec_s1,
    :invest_s2,
    :invest_s3,
    :order_s2,
    :order_s3,
    :debt_s1,
    :debt_s2,
    :debt_s3,
    :emp_tot,
    :hh_income,
    :cons,
    :y_tot,
)
const CAPEX_DEMO_RATE_VARS = (:util_s2, :util_s3, :inv_ratio_s2, :inv_ratio_s3, :spread)

const CAPEX_DEMO_NOTES = String[
    "パラメータは例示値であり実データによる較正を経ていない。系列の水準の絶対値に意味はなく、" *
    "baseline比乖離の符号・順序・大小関係のみが解釈対象である。",
    "診断ラベル broad_downturn はモデル内の診断であり、景気後退の予測・確率ではない。",
    "A と share_C は同一実装内の反実仮想寄与であり因果推定ではない。",
    "funding_pressure_s は倒産・信用イベントの予測ではない（デフォルトを内生化していない）。",
    "会計は残差部門 SX を置いて閉じており、経済全体で閉じていない（accounting_closure = :partial）。" *
    "SFC検証済みと同じ意味ではない。",
    "cost_capital_s・ai_exp・target_cap_s1・cancel_s1 は潜在変数であり、単独の水準を提示しない。",
    "本出力は投資判断・政策立案の根拠として使用することを意図していない。",
]

# ─────────────────────────────────────────────────────────────────
# provenance・JSON安全化ヘルパー
# ─────────────────────────────────────────────────────────────────

function _capex_demo_git_revision()
    try
        rev = readchomp(`git -C $(@__DIR__) rev-parse --short HEAD`)
        isempty(rev) ? "unknown" : rev
    catch
        "unknown"
    end
end

# 非有限値（NaN/Inf）を文字列タグへ符号化する（`src/sfc/serialization.jl` と同じ規約）。
# 打ち切り・助走区間の初期化次第で系列にNaNが混ざりうるため、JSON3.write前に必ず通す。
_capex_demo_json_safe(x::AbstractFloat) =
    isfinite(x) ? x : (isnan(x) ? "NaN" : (x > 0 ? "Inf" : "-Inf"))
_capex_demo_json_safe(x::AbstractVector) = Any[_capex_demo_json_safe(v) for v in x]
_capex_demo_json_safe(x::Nothing) = nothing
_capex_demo_json_safe(x) = x

# ─────────────────────────────────────────────────────────────────
# baseline比乖離（分析契約 §2.4: 水準変数は相対乖離、比率・金利・スプレッドは差分）
# ─────────────────────────────────────────────────────────────────

function _capex_demo_rel_dev(x::Vector{Float64}, base::Float64; eps::Float64 = 1e-8)
    abs(base) > eps ? (x .- base) ./ base : fill(NaN, length(x))
end
_capex_demo_abs_dev(x::Vector{Float64}, base::Float64) = x .- base

function _capex_demo_series_and_deviation(run::CapexCreditCycleRun, ss)
    series = Dict{String, Any}()
    deviation = Dict{String, Any}()
    for v in CAPEX_DEMO_LEVEL_VARS
        x = Float64.(getproperty(run.series, v))
        series[String(v)] = _capex_demo_json_safe(x)
        deviation[String(v)] = _capex_demo_json_safe(_capex_demo_rel_dev(x, getproperty(ss, v)))
    end
    for v in CAPEX_DEMO_RATE_VARS
        x = Float64.(getproperty(run.series, v))
        series[String(v)] = _capex_demo_json_safe(x)
        deviation[String(v)] = _capex_demo_json_safe(_capex_demo_abs_dev(x, getproperty(ss, v)))
    end
    return series, deviation
end

# `|series|` を最大化する点（値・期）。`_capex_peak`（診断層、非公開）と同じ規約。
function _capex_demo_peak_abs(values::Vector{Float64}, periods::Vector{Int})
    best_i = 0
    best_v = 0.0
    for (i, v) in enumerate(values)
        isfinite(v) || continue
        if best_i == 0 || abs(v) > abs(best_v)
            best_v = v
            best_i = i
        end
    end
    best_i == 0 && return (value = NaN, period = nothing)
    return (value = best_v, period = periods[best_i])
end

# ─────────────────────────────────────────────────────────────────
# シナリオ別サマリー構築
# ─────────────────────────────────────────────────────────────────

function _capex_demo_diagnostics_summary(diag::CapexDiagnostics)
    return Dict{String, Any}(
        "label" => String(diag.label),
        "label_loop_mismatch" => diag.label_loop_mismatch,
        "accounting_status" => accounting_status_label(diag.accounting_status),
        "group_status" => Dict{String, Any}(
            String(k) =>
                Dict{String, Any}("met" => v.met, "start_period" => v.start_period, "duration" => v.duration) for (k, v) in diag.group_status
        ),
        "breadth" => diag.breadth,
        "breadth_excl_s1" => diag.breadth_excl_s1,
        "breadth_note" =>
            "実体部門4のため breadth ≥ 0.60 は4部門中3部門以上を意味する（0.25刻み）",
        "deteriorated_sectors" => String.(diag.deteriorated_sectors),
        "peaks" => Dict{String, Any}(
            k => Dict{String, Any}("value" => _capex_demo_json_safe(v.value), "period" => v.period) for (k, v) in diag.peaks
        ),
        "recovery_period" => diag.recovery_period,
        "delayed_containment" => diag.delayed_containment,
    )
end

function _capex_demo_funding_pressure_summary(diag::CapexDiagnostics)
    return Dict{String, Any}(
        String(sector) => begin
            labels = diag.funding_pressure[sector]
            n = length(labels)
            Dict{String, Any}(
                "labels" => String.(labels),
                "residency_ratio" => Dict{String, Any}(
                    String(lbl) => (n == 0 ? 0.0 : count(==(lbl), labels) / n) for
                    lbl in CAPEX_CC_FUNDING_PRESSURE_LABELS
                ),
            )
        end for sector in (:s1, :s2, :s3)
    )
end

function _capex_demo_loop_summary(diag::CapexDiagnostics, run::CapexCreditCycleRun)
    eval_periods = filter(t -> t >= 0, run.periods)
    sr_peak = _capex_demo_peak_abs(diag.spectral_radius, eval_periods)
    gshort_peak = _capex_demo_peak_abs(diag.short_circuit_gain, run.periods)
    return Dict{String, Any}(
        "loop_active" => Dict{String, Any}(String(k) => v for (k, v) in diag.loop_active),
        "loop_gain" =>
            Dict{String, Any}(String(k) => _capex_demo_json_safe(v) for (k, v) in diag.loop_gain),
        "spectral_radius" => Dict{String, Any}(
            "series" => _capex_demo_json_safe(diag.spectral_radius),
            "periods" => eval_periods,
            "max" => _capex_demo_json_safe(sr_peak.value),
            "max_period" => sr_peak.period,
            "note" => "ρ_t は状態依存であり単一値ではない。系列と最大値・その時点のみを報告する。",
        ),
        "short_circuit_gain" => Dict{String, Any}(
            "series" => _capex_demo_json_safe(diag.short_circuit_gain),
            "periods" => run.periods,
            "peak_abs" => _capex_demo_json_safe(gshort_peak.value),
            "peak_abs_period" => gshort_peak.period,
        ),
        "threshold_proximity" => [
            Dict{String, Any}(
                "id" => String(np.id),
                "period" => np.period,
                "sector" => String(np.sector),
                "proximity" => _capex_demo_json_safe(np.proximity),
                "crossed" => np.crossed,
            ) for np in diag.threshold_proximity
        ],
    )
end

function _capex_demo_accounting_summary(acc::AccountingCheckReport)
    violations_by_check = Dict{String, Int}()
    for v in acc.violations
        k = String(v.check)
        violations_by_check[k] = get(violations_by_check, k, 0) + 1
    end
    return Dict{String, Any}(
        "status" => accounting_status_label(acc.status),
        "checks_performed" => acc.checks_performed,
        "checks_passed" => acc.checks_passed,
        "max_abs_residual" => _capex_demo_json_safe(acc.max_abs_residual),
        "has_violations" => !isempty(acc.violations),
        "violations_by_check" => violations_by_check,
        "invalid_periods" => acc.invalid_periods,
    )
end

function _capex_demo_sensitivity_summary(sens::Dict{Symbol, <:NamedTuple})
    return Dict{String, Any}(
        String(field) => Dict{String, Any}(
            "baseline" => String(v.baseline),
            "minus50" => String(v.minus50),
            "plus50" => String(v.plus50),
        ) for (field, v) in sens
    )
end

function _capex_demo_scenario_dict(
    sc::CapexScenario,
    run::CapexCreditCycleRun,
    ss,
    acc::AccountingCheckReport,
    diag::CapexDiagnostics,
    sens::Dict{Symbol, <:NamedTuple},
)
    series, deviation = _capex_demo_series_and_deviation(run, ss)
    return Dict{String, Any}(
        "scenario" => Dict{String, Any}(
            "id" => String(sc.id),
            "name" => sc.name,
            "n_shocks" => length(sc.shocks),
        ),
        "periods" => run.periods,
        "series" => series,
        "deviation" => deviation,
        "diagnostics" => _capex_demo_diagnostics_summary(diag),
        "funding_pressure" => _capex_demo_funding_pressure_summary(diag),
        "loop_diagnostics" => _capex_demo_loop_summary(diag, run),
        "accounting" => _capex_demo_accounting_summary(acc),
        "sensitivity" => _capex_demo_sensitivity_summary(sens),
        "termination_reason" => String(run.termination_reason),
        "termination_period" => run.termination_period,
        "warnings" => run.warnings,
    )
end

# ─────────────────────────────────────────────────────────────────
# 判定問題の回答（分析契約 §3 Q2・Q3・Q4）
# ─────────────────────────────────────────────────────────────────

function _capex_demo_judgment_questions(diags::Dict{Symbol, CapexDiagnostics})
    d2, d3, d4 = diags[:Sc2], diags[:Sc3], diags[:Sc4]
    share_c_residual(main, add) =
        (main === nothing || add === nothing) ? nothing : 1.0 - add / main
    peak_dict(peak) =
        Dict{String, Any}("value" => _capex_demo_json_safe(peak.value), "period" => peak.period)

    return Dict{String, Any}(
        "Q2_amplification" => Dict{String, Any}(
            "scenario" => "Sc3",
            "A" => _capex_demo_json_safe(d3.amplification),
            "threshold_q2_amplification" => d3.thresholds.q2_amplification,
        ),
        "Q3_share_C" => Dict{String, Any}(
            id => Dict{String, Any}(
                "share_c_primary" => _capex_demo_json_safe(d.share_c),
                "share_c_additive" => _capex_demo_json_safe(d.share_c_additive),
                "residual_ratio" =>
                    _capex_demo_json_safe(share_c_residual(d.share_c, d.share_c_additive)),
            ) for (id, d) in ("Sc2" => d2, "Sc3" => d3)
        ),
        "Q4_easing_containment" => Dict{String, Any}(
            "peak_dY_Sc3" => peak_dict(d3.peaks["dY"]),
            "peak_dY_Sc4" => peak_dict(d4.peaks["dY"]),
            "recovery_period_Sc3" => d3.recovery_period,
            "recovery_period_Sc4" => d4.recovery_period,
        ),
    )
end

# ─────────────────────────────────────────────────────────────────
# Markdown レポート
# ─────────────────────────────────────────────────────────────────

function _capex_demo_write_markdown_report(
    path,
    m::CapexCreditCycleModel,
    diags::Dict{Symbol, CapexDiagnostics},
    accs::Dict{Symbol, AccountingCheckReport},
    judgment::Dict{String, Any},
    manifest::Dict{String, Any},
    artifact_names::Vector{String},
)
    io = IOBuffer()
    println(io, "# 部門別CAPEX・信用循環モデル 統合デモ — 実行レポート\n")
    println(
        io,
        "> 本レポートは自動生成物です。パラメータは例示値であり実データによる較正を経ていません。",
    )
    println(
        io,
        "> 診断ラベル `broad_downturn` はモデル内の診断であり、景気後退の予測・確率ではありません。\n",
    )

    println(io, "## 1. 実行メタデータ（provenance）\n")
    println(io, "- 実行日時: `$(manifest["run_timestamp"])`")
    println(io, "- code revision: `$(manifest["code_revision"])`")
    println(io, "- model_version: `$(manifest["methodology"]["model_version"])`")

    println(io, "\n## 2. シナリオ別 診断ラベル・会計検証\n")
    println(io, "| シナリオ | ラベル | breadth | peak(dY) | 会計 pass | 会計違反有無 |")
    println(io, "|---|---|---|---|---|---|")
    for id in CAPEX_DEMO_SCENARIOS
        d = diags[id]
        acc = accs[id]
        peak = d.peaks["dY"]
        peak_str = isnan(peak.value) ? "-" : "$(round(peak.value, sigdigits = 4)) (t=$(peak.period))"
        println(
            io,
            "| $(id) | $(d.label) | $(round(d.breadth, digits = 2)) | $(peak_str) | " *
            "$(acc.checks_passed)/$(acc.checks_performed) | $(!isempty(acc.violations)) |",
        )
    end

    println(io, "\n## 3. 判定問題の回答（分析契約 §3）\n")
    q2 = judgment["Q2_amplification"]
    println(io, "- **Q2（信用による増幅）**: Sc3 の `A` = `$(q2["A"])`（閾値 `$(q2["threshold_q2_amplification"])`）")
    for id in ("Sc2", "Sc3")
        q3 = judgment["Q3_share_C"][id]
        println(
            io,
            "- **Q3（消費経路の寄与、$(id)）**: 主方式 `share_C` = `$(q3["share_c_primary"])`、" *
            "加法分解 = `$(q3["share_c_additive"])`、残差比 = `$(q3["residual_ratio"])`",
        )
    end
    q4 = judgment["Q4_easing_containment"]
    println(
        io,
        "- **Q4（金融緩和による遮断）**: peak(dY) Sc3=`$(q4["peak_dY_Sc3"]["value"])` " *
        "(t=$(q4["peak_dY_Sc3"]["period"])) vs Sc4=`$(q4["peak_dY_Sc4"]["value"])` " *
        "(t=$(q4["peak_dY_Sc4"]["period"]))、回復時点 Sc3=`$(q4["recovery_period_Sc3"])` " *
        "vs Sc4=`$(q4["recovery_period_Sc4"])`",
    )

    println(io, "\n## 4. 資金繰り診断（Sc3、funding_pressure_s）\n")
    fp = _capex_demo_funding_pressure_summary(diags[:Sc3])
    for s in ("s1", "s2", "s3")
        ratios = fp[s]["residency_ratio"]
        parts = ["$(k)=$(round(v, digits = 2))" for (k, v) in sort(collect(ratios))]
        println(io, "- $(s): " * join(parts, "  "))
    end

    println(io, "\n## 5. 比較 API v2（mechanismモード、Sc0 vs Sc3）\n")
    println(
        io,
        "同一モデル内のシナリオ比較のため能力metadataの構造化差分に差異は生じない" *
        "（数値比較は診断層・上表が担う）。",
    )

    println(io, "\n## 6. 保存した成果物\n")
    for name in artifact_names
        println(io, "- `$(name)`")
    end

    println(io, "\n## 7. 注意事項（結果の限界・禁止される解釈）\n")
    for (i, note) in enumerate(CAPEX_DEMO_NOTES)
        println(io, "$(i). $(note)")
    end

    write(path, String(take!(io)))
    return path
end

# ─────────────────────────────────────────────────────────────────
# 本体: 一連のフローを実行し成果物を保存する
# ─────────────────────────────────────────────────────────────────

"""
    run_capex_credit_cycle_demo(; outdir, thresholds=CapexDiagnosticThresholds(),
                                 make_plots=true, verbose=true) -> NamedTuple

部門別CAPEX・信用循環モデルの `Sc0`–`Sc4` シナリオ比較（統合設計 §8）を実行し、
成果物パスと主要結果を返す。API キー不要・ネットワークアクセスなし・決定的に完走する。
"""
function run_capex_credit_cycle_demo(;
    outdir::AbstractString,
    thresholds::CapexDiagnosticThresholds = CapexDiagnosticThresholds(),
    make_plots::Bool = true,
    verbose::Bool = true,
)
    isdir(outdir) || mkpath(outdir)
    say(args...) = verbose && println(args...)

    # ---- Step 1  モデル構築（逆較正） -------------------------------------
    say("=" ^ 64)
    say("Step 1  モデル構築（例示定常水準からの逆較正）")
    say("=" ^ 64)
    m = capex_credit_cycle_model(capex_credit_cycle_default_targets())
    ss = steady_state(m)
    ss_report = capex_steady_state_report(m)
    say("  定常条件 SS-1–SS-17: ", passed(ss_report) ? "全件 passed" : "違反あり")

    # ---- Step 2  Sc0–Sc4 の実行・会計検証・診断・感応度 --------------------
    say("\n" * "=" ^ 64)
    say("Step 2  シナリオ Sc0–Sc4 の実行・会計検証（12項目）・診断・閾値感応度")
    say("=" ^ 64)
    scenarios = Dict{Symbol, CapexScenario}()
    runs = Dict{Symbol, CapexCreditCycleRun}()
    srs = Dict{Symbol, SimulationResult}()
    accs = Dict{Symbol, AccountingCheckReport}()
    diags = Dict{Symbol, CapexDiagnostics}()
    senses = Dict{Symbol, Dict{Symbol, NamedTuple}}()
    for id in CAPEX_DEMO_SCENARIOS
        sc = capex_scenario(id)
        exog = capex_exogenous_paths(m, sc)
        run = capex_run(m; scenario = id, exog = exog)
        acc = validate_capex_accounting(m, run)
        diag = capex_diagnostics(m, run; thresholds = thresholds, accounting = acc)
        sens = capex_label_sensitivity(m, run; thresholds = thresholds)
        sr = to_simulation_result(m, run, String(id))

        scenarios[id] = sc
        runs[id] = run
        srs[id] = sr
        accs[id] = acc
        diags[id] = diag
        senses[id] = sens

        say(
            "  $(id) ($(sc.name)): label=$(diag.label)  " *
            "acc=$(accounting_status_label(acc.status)) ($(acc.checks_passed)/$(acc.checks_performed))  " *
            "termination=$(run.termination_reason)",
        )
    end

    all_acc_pass = all(accounting_passed(accs[id]) for id in CAPEX_DEMO_SCENARIOS)
    say("  全シナリオで会計検証12項目 pass: ", all_acc_pass)

    # ---- Step 3  判定問題の回答（Q2・Q3・Q4） ------------------------------
    say("\n" * "=" ^ 64)
    say("Step 3  判定問題の回答（分析契約 §3 Q2・Q3・Q4）")
    say("=" ^ 64)
    judgment = _capex_demo_judgment_questions(diags)
    say("  Q2 (A, Sc3) = ", judgment["Q2_amplification"]["A"])
    say("  Q3 (share_C, Sc3) = ", judgment["Q3_share_C"]["Sc3"]["share_c_primary"])

    # ---- Step 4  比較API v2（mechanismモード、Sc0 vs Sc3）-----------------
    say("\n" * "=" ^ 64)
    say("Step 4  比較API v2（mechanismモード、Sc0 vs Sc3、同一モデル内のシナリオ比較）")
    say("=" ^ 64)
    v2_spec = ComparisonSpec(;
        mode = :mechanism,
        left_model = :capex_credit_cycle,
        right_model = :capex_credit_cycle,
    )
    comparison_v2 = compare_results_v2(srs[:Sc0], srs[:Sc3]; spec = v2_spec)
    say("  assessment.level = ", comparison_v2.assessment.level)

    # ---- Step 5  図の保存 ---------------------------------------------------
    artifact_paths = String[]
    if make_plots
        say("\n" * "=" ^ 64)
        say("Step 5  可視化の保存")
        say("=" ^ 64)
        figs = (
            (
                "capex_sector_series_Sc3.png",
                plot_capex_sector_series(srs[:Sc3]; title = "Sc3（部門別系列）"),
            ),
            (
                "capex_scenario_comparison.png",
                plot_capex_scenario_comparison(
                    m,
                    [runs[id] for id in CAPEX_DEMO_SCENARIOS];
                    labels = [String(id) for id in CAPEX_DEMO_SCENARIOS],
                ),
            ),
            (
                "capex_diagnostic_label_Sc3.png",
                plot_capex_diagnostic_label(diags[:Sc3], runs[:Sc3]),
            ),
            (
                "capex_funding_pressure_Sc3.png",
                plot_capex_funding_pressure(diags[:Sc3], runs[:Sc3]),
            ),
        )
        for (name, fig) in figs
            path = joinpath(outdir, name)
            savefig(fig, path)
            push!(artifact_paths, path)
            say("  saved: $(name)")
        end
    end

    # ---- Step 6  機械可読成果物・provenance の保存 -------------------------
    say("\n" * "=" ^ 64)
    say("Step 6  機械可読成果物・provenance の保存")
    say("=" ^ 64)

    scenario_paths = String[]
    for id in CAPEX_DEMO_SCENARIOS
        d = _capex_demo_scenario_dict(
            scenarios[id],
            runs[id],
            ss,
            accs[id],
            diags[id],
            senses[id],
        )
        path = joinpath(outdir, "capex_scenario_$(id).json")
        write(path, JSON3.write(d))
        push!(scenario_paths, path)
    end

    judgment_path = joinpath(outdir, "capex_judgment_questions.json")
    write(judgment_path, JSON3.write(judgment))

    v2_path = joinpath(outdir, "capex_comparison_v2.json")
    write(v2_path, to_json(comparison_v2))

    representative_metadata = srs[:Sc3].metadata
    manifest = Dict{String, Any}(
        "demo" => "capex_credit_cycle",
        "run_timestamp" => string(now()),
        "code_revision" => _capex_demo_git_revision(),
        "scenarios" => Dict{String, Any}(
            String(id) => Dict{String, Any}(
                "name" => scenarios[id].name,
                "n_shocks" => length(scenarios[id].shocks),
                "termination_reason" => String(runs[id].termination_reason),
            ) for id in CAPEX_DEMO_SCENARIOS
        ),
        "accounting" => Dict{String, Any}(
            "all_scenarios_pass" => all_acc_pass,
            "per_scenario" => Dict{String, Any}(
                String(id) => accounting_passed(accs[id]) for id in CAPEX_DEMO_SCENARIOS
            ),
        ),
        "methodology" => Dict{String, Any}(
            "contract_version" => representative_metadata["contract_version"],
            "graph_version" => representative_metadata["graph_version"],
            "vars_version" => representative_metadata["vars_version"],
            "accounting_version" => representative_metadata["accounting_version"],
            "boundaries_version" => representative_metadata["boundaries_version"],
            "equations_version" => representative_metadata["equations_version"],
            "empirical_version" => representative_metadata["empirical_version"],
            "model_version" => representative_metadata["model_version"],
            "diagnostic_threshold_set" => representative_metadata["diagnostic_threshold_set"],
        ),
        "reserved_metadata_keys_representative_scenario" => "Sc3",
        "reserved_metadata" => representative_metadata,
        "warnings" =>
            vcat([w for id in CAPEX_DEMO_SCENARIOS for w in runs[id].warnings]...),
        "notes" => CAPEX_DEMO_NOTES,
    )
    manifest_path = joinpath(outdir, "capex_run_manifest.json")
    write(manifest_path, JSON3.write(manifest))

    artifact_names = [
        basename(p) for
        p in vcat(artifact_paths, scenario_paths, [judgment_path, v2_path])
    ]
    md_path = joinpath(outdir, "report.md")
    _capex_demo_write_markdown_report(
        md_path,
        m,
        diags,
        accs,
        judgment,
        manifest,
        vcat(artifact_names, ["capex_run_manifest.json"]),
    )

    for p in vcat(scenario_paths, [judgment_path, v2_path, manifest_path, md_path])
        say("  saved: $(basename(p))")
    end

    return (
        outdir = outdir,
        model = m,
        scenarios = scenarios,
        runs = runs,
        simulation_results = srs,
        accounting = accs,
        diagnostics = diags,
        sensitivity = senses,
        judgment_questions = judgment,
        comparison_v2 = comparison_v2,
        all_accounting_pass = all_acc_pass,
        manifest = manifest,
        artifact_paths = vcat(
            artifact_paths,
            scenario_paths,
            [judgment_path, v2_path, manifest_path, md_path],
        ),
    )
end

# ─────────────────────────────────────────────────────────────────
# スクリプトとして直接実行された場合のみ走らせる（include では実行しない）
# ─────────────────────────────────────────────────────────────────
if abspath(PROGRAM_FILE) == @__FILE__
    outdir = get(
        ENV,
        "CAPEX_CC_DEMO_OUTDIR",
        joinpath(@__DIR__, "..", "artifacts", "capex_credit_cycle_demo"),
    )

    println(
        """
╔═══════════════════════════════════════════════════════════════════╗
║  部門別CAPEX・信用循環モデル 統合デモ                                ║
║  Sc0–Sc4 → 会計検証 → 診断 → 判定問題 → 比較API → 可視化 → 保存      ║
╚═══════════════════════════════════════════════════════════════════╝

  出力先: $(outdir)

注意: パラメータは例示値であり実データによる較正を経ていない。
      broad_downturn はモデル内の診断であり景気後退の予測・確率ではない。
      A・share_C は反実仮想寄与であり因果推定ではない。
      本デモは投資判断・政策立案の根拠として使用することを意図していない。
""",
    )

    out = run_capex_credit_cycle_demo(; outdir = outdir)

    println(
        """

完了。出力ディレクトリ: $(out.outdir)

再現性: 乱数を用いず完全に決定的（同一パラメータで同一の数値成果物）。
        capex_run_manifest.json に code revision・契約 version・実行日時・警告を記録。
限界: 会計は残差部門 SX を置いて閉じており経済全体で閉じていない（accounting_closure=:partial）。
      funding_pressure_s は倒産・信用イベントの予測ではない。本デモは投資助言・政策判断を目的としない。
詳細: docs/examples/capex_credit_cycle_demo.md
""",
    )
end
