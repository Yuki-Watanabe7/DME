# examples/sfc_ai_economist_demo.jl
#
# 最小 SIM 型 SFC モデルを「AIエコノミスト」として実演する統合デモ（Issue #152）
#
# baseline / 財政ショック シナリオ構築 → 部門別貸借対照表・取引フロー・valuation
# adjustment の生成 → 全期の会計恒等式検証（#147）→ モデル能力・概念定義 metadata
# の出力（#149）→ 比較 API v2 を合成データへ適用（#150）→ Keen–SFC 概念対応・
# 比較レポート（#151）→ ADR 0006 の LLM provider 抽象・source registry・決定的
# fallback を用いた根拠付き説明 → run 単位の成果物・provenance 保存、までを 1 本で
# API キー不要・決定的に完走する。
#
# 実行方法（外部 API キー不要の offline 経路が既定・正）:
#   julia --project=. examples/sfc_ai_economist_demo.jl
#
# LLM provider の切替:
#   OPENAI_API_KEY 未設定 … MockLLMProvider（API 呼び出しなし。契約検証 fallback を実演）
#   OPENAI_API_KEY 設定済 … OpenAIProvider（実 API を呼び出す）
#   いずれの場合も保存する説明成果物は決定的な deterministic 生成を正とし、
#   provider 経由の応答は契約検証（schema・source・安全性）を通過した場合のみ採用する
#   （未通過は安全 fallback）。
#
# 成果物の出力先（既定はリポジトリ内 artifacts/、環境変数で上書き可）:
#   SFC_AI_DEMO_OUTDIR=/path/to/dir
#
# 保存する成果物（再現性・provenance を含む）:
#   sfc_result_baseline.json     … baseline の部門別貸借対照表・取引フロー・valuation
#                                    adjustment・methodology（全期）
#   sfc_result_fiscal_shock.json … 財政ショックシナリオの同上
#   accounting_checks.json       … 両シナリオの会計恒等式検証（全 check・最大残差）
#   model_capabilities.json      … SIM・Keen の能力プロファイル metadata（#149）
#   comparison_v2.json           … 合成「実データ」proxy との比較 API v2 結果（#150）
#   keen_sfc_comparison.json     … Keen–SFC 概念対応・非対応・構造差の構造化レポート（#151）
#   keen_sfc_explanation.json    … 根拠付き構造化説明（ADR 0006。deterministic が正）
#   run_manifest.json            … 契約 version・シナリオ設定・provider・実行日時・警告一覧
#   report.md                    … 人が読むサマリー（数値と source id を相互参照）
#   *.png                        … baseline / 財政ショックの主要系列・家計貨幣資産の比較図
#
# 注意（結果の限界・禁止される解釈）:
#   - SIM は金融不安定性・企業債務・分配動学・危機regime を持たない（大域安定な需要決定モデル）
#   - 比較 API v2 に用いる「実データ」は本デモ用に生成した合成 proxy であり、観測データではない
#   - Keen 側の Y 系列は既定 simulate 出力（ω, λ, d）に含まれないため、捏造せず比較不能として扱う
#   - Keen–SFC の比較不能概念（民間債務・資金調達区分・賃金/利潤シェア・雇用率・会計閉鎖等）に
#     数値 metric を生成しない
#   - 本デモは投資助言・危機確率・政策最適性を導出しない
#
# 関連: docs/examples/sfc_ai_economist.md / docs/models/sim_sfc.md /
#       docs/analysis/keen_sfc_comparison.md / docs/architecture/cross_model_reasoning.md /
#       docs/adr/0006-cross-model-reasoning-contract.md / docs/adr/0007-sfc-integration-contract.md

# ヘッドレス環境（CI・無表示）でプロット保存を可能にする
get!(ENV, "GKSwstype", "nul")

using DME
using Plots
using Dates: now
const JSON3 = DME.JSON3

# ─────────────────────────────────────────────────────────────────
# provenance ヘルパー
# ─────────────────────────────────────────────────────────────────

# git HEAD の revision（取得できない環境では "unknown"）。秘密情報は含まない。
function _sfc_econ_git_revision()
    try
        rev = readchomp(`git -C $(@__DIR__) rev-parse --short HEAD`)
        isempty(rev) ? "unknown" : rev
    catch
        "unknown"
    end
end

# provider の説明（秘密情報・API キーは絶対に含めない）
function _sfc_econ_provider_descriptor(provider)
    if provider isa MockLLMProvider
        (kind = "MockLLMProvider", model = "mock", uses_api = false)
    elseif provider isa OpenAIProvider
        (kind = "OpenAIProvider", model = provider.model, uses_api = true)
    else
        (kind = string(nameof(typeof(provider))), model = "unknown", uses_api = true)
    end
end

function _sfc_econ_section_overview(out, section_order)
    [
        (
            section = k,
            status = string(getfield(out, Symbol(k)).status),
            n_claims = length(getfield(out, Symbol(k)).claims),
        ) for k in section_order
    ]
end

# ─────────────────────────────────────────────────────────────────
# シナリオ・合成データ構築ヘルパー
# ─────────────────────────────────────────────────────────────────

# 表示用の四半期ラベル（暦と紐づく実測ではなく、デモの可読性のために付す期ラベル）。
function _sfc_econ_quarterly_labels(n::Int; start_year::Int = 2020)
    return String["$(start_year + div(t - 1, 4))-Q$(mod(t - 1, 4) + 1)" for t in 1:n]
end

# 比較 API v2（#150）実演用の合成「実データ」。RNG は使わず、モデル系列に決定的な
# 滑らかな乖離（sin/cos）を加えるだけの closed-form proxy（観測データではない）。
function _sfc_econ_synthetic_dataset(periods::Vector{String}, baseline_series)
    n = length(periods)
    y_proxy = Float64[
        round(baseline_series.Y[t] + 3.0 * sin(2 * pi * t / 8); digits = 4) for t in 1:n
    ]
    g_proxy = Float64[
        round(baseline_series.G[t] + 1.0 * cos(2 * pi * t / 8); digits = 4) for t in 1:n
    ]
    y_series = DataSeries(;
        id = "SFC_SYN_Y",
        name = "総産出（合成 proxy、デモ用）",
        source = "synthetic_demo",
        frequency = Quarterly,
        unit = "wage units",
        dates = periods,
        values = y_proxy,
        metadata = Dict{String, Any}(
            "note" => "deterministic synthetic proxy for demo purposes, not observed data",
        ),
    )
    g_series = DataSeries(;
        id = "SFC_SYN_G",
        name = "政府支出（合成 proxy、デモ用）",
        source = "synthetic_demo",
        frequency = Quarterly,
        unit = "wage units",
        dates = periods,
        values = g_proxy,
        metadata = Dict{String, Any}(
            "note" => "deterministic synthetic proxy for demo purposes, not observed data",
        ),
    )
    return MacroDataset("synthetic actual data (demo)", [y_series, g_series])
end

# ─────────────────────────────────────────────────────────────────
# Markdown レポート（数値レポートと source id を相互参照可能にする）
# ─────────────────────────────────────────────────────────────────

function _sfc_econ_md_sources_table(sources)
    lines = [
        "| source_id | category | series_id / method | period | artifact |",
        "|---|---|---|---|---|",
    ]
    for s in sort(sources; by = x -> x.id)
        sid =
            s.series_id === nothing ? (s.method_id === nothing ? "-" : s.method_id) :
            s.series_id
        period =
            (s.period_start === nothing || s.period_end === nothing) ? "-" :
            "$(s.period_start)..$(s.period_end)"
        art = s.artifact_path === nothing ? "-" : s.artifact_path
        push!(lines, "| `$(s.id)` | $(s.category) | $(sid) | $(period) | $(art) |")
    end
    join(lines, "\n")
end

function _sfc_econ_md_explanation_sections(out, section_order)
    io = IOBuffer()
    for k in section_order
        sec = getfield(out, Symbol(k))
        println(io, "\n### $(k)  —  _status: $(sec.status)_\n")
        if isempty(sec.claims)
            println(io, "_（この section には claim がありません）_")
            if !isempty(sec.missing_fields)
                println(io, "\nmissing: ", join(sec.missing_fields, ", "))
            end
            continue
        end
        for c in sec.claims
            src = isempty(c.source_ids) ? "-" : join(["`$(s)`" for s in c.source_ids], ", ")
            ql =
                isempty(c.qualifiers) ? "" :
                "  \n  <sub>qualifiers: $(join(c.qualifiers, "; "))</sub>"
            println(
                io,
                "- **[$(c.epistemic_status)]** $(c.text)  \n  <sub>sources: $(src)</sub>$(ql)",
            )
        end
    end
    String(take!(io))
end

function _sfc_econ_md_comparison_v2_table(cmp::ComparisonResultV2)
    lines = ["| 変数 (model⇔data) | level | 指標 |", "|---|---|---|"]
    for (var, m) in sort(collect(cmp.metrics); by = first)
        metrics_str = join(
            ["$(k)=$(round(v, sigdigits = 5))" for (k, v) in pairs(m) if v isa Real],
            "  ",
        )
        push!(lines, "| $(var) | $(cmp.assessment.per_variable[var]) | $(metrics_str) |")
    end
    return join(lines, "\n")
end

function _sfc_econ_write_markdown_report(
    path,
    baseline_series,
    shock_series,
    acc_baseline,
    acc_shock,
    comparison_v2,
    ksfc_report,
    ksfc_explanation,
    manifest,
    artifact_names,
)
    io = IOBuffer()
    println(io, "# SFC対応 AIエコノミスト統合デモ — 実行レポート\n")
    println(
        io,
        "> 本レポートは自動生成物です。SIM は金融不安定性・企業債務・分配動学・危機regime を持ちません。",
    )
    println(
        io,
        "> 比較 API v2 に用いる「実データ」は本デモ用の合成 proxy であり、観測データではありません。\n",
    )

    println(io, "## 1. 実行メタデータ（provenance）\n")
    println(io, "- 実行日時: `$(manifest["run_timestamp"])`")
    println(io, "- code revision: `$(manifest["code_revision"])`")
    println(
        io,
        "- LLM provider: `$(manifest["llm_provider"]["kind"])` / model `$(manifest["llm_provider"]["model"])`（API 呼び出し: $(manifest["llm_provider"]["uses_api"])）",
    )
    println(io, "- 説明 prompt version: `$(ksfc_explanation.prompt_version)`")
    println(io, "- 説明 generation_status: `$(ksfc_explanation.generation_status)`")

    println(io, "\n## 2. シナリオ\n")
    println(
        io,
        "- baseline: `SIMModel(α1=0.6, α2=0.4, θ=0.2, G=20.0)`、`H0=0.0` から出発、" *
        "`Y[end]=$(round(baseline_series.Y[end], sigdigits = 6))`",
    )
    println(
        io,
        "- fiscal_shock: 政府支出の恒久的増加（+5.0）。新定常 `Y*=125`（baseline `Y*=100`）、" *
        "`Y[end]=$(round(shock_series.Y[end], sigdigits = 6))`",
    )
    println(
        io,
        "- 期間数: $(length(baseline_series.Y))（`$(manifest["scenario"]["periods_start"])` .. `$(manifest["scenario"]["periods_end"])`。暦と紐づかないデモ用ラベル）",
    )

    println(io, "\n## 3. 会計恒等式の検証結果（#147）\n")
    println(
        io,
        "- baseline: status=`$(accounting_status_label(acc_baseline.status))`、" *
        "pass $(acc_baseline.checks_passed)/$(acc_baseline.checks_performed)、" *
        "最大残差=`$(round(acc_baseline.max_abs_residual, sigdigits = 6))`",
    )
    println(
        io,
        "- fiscal_shock: status=`$(accounting_status_label(acc_shock.status))`、" *
        "pass $(acc_shock.checks_passed)/$(acc_shock.checks_performed)、" *
        "最大残差=`$(round(acc_shock.max_abs_residual, sigdigits = 6))`",
    )

    println(io, "\n## 4. 財政赤字と部門別金融収支の対応\n")
    saving_last = baseline_series.G[end] - baseline_series.T[end]
    println(
        io,
        "会計恒等式（`docs/models/sim_sfc.md` §5）により、政府の財政赤字 `G−T` は毎期そのまま" *
        "家計の貨幣資産の増分 `ΔH` になる（`saving = G − T = ΔH`）。baseline 最終期: " *
        "`G−T = $(round(saving_last, sigdigits = 6))`、`H[end]−H[end-1] = " *
        "$(round(baseline_series.H[end] - baseline_series.H[end-1], sigdigits = 6))`。" *
        "この対応は全期で会計検証済み（`accounting_checks.json`）であり、モデル方程式からの" *
        "帰結であって因果的な政策効果の主張ではない。",
    )

    println(io, "\n## 5. 比較 API v2（合成データ、#150）\n")
    println(io, "mapping_type=`proxy`（観測 proxy であり同値ではない）。\n")
    println(io, _sfc_econ_md_comparison_v2_table(comparison_v2))
    if !isempty(comparison_v2.warnings)
        println(io, "\n警告:")
        for w in comparison_v2.warnings
            println(io, "- $(w)")
        end
    end

    println(io, "\n## 6. Keen–SFC 概念対応・比較レポート（#151）\n")
    println(
        io,
        "共通概念（equivalent）: $(length(ksfc_report.shared_concepts)) 件、" *
        "部分対応: $(length(ksfc_report.partial_concepts)) 件、" *
        "比較不能: $(length(ksfc_report.incomparable_concepts)) 件。",
    )
    println(io, "\n### 数値比較を実施した項目\n")
    if isempty(ksfc_report.numeric_comparisons)
        println(io, "_（実施した項目なし）_")
    else
        for k in sort(collect(keys(ksfc_report.numeric_comparisons)))
            println(io, "- `$(k)`")
        end
    end
    println(io, "\n### 数値比較を実施しなかった項目と理由\n")
    for s in ksfc_report.skipped_comparisons
        println(io, "- **$(s["label"])** (`$(s["concept"])`): $(s["reason"])")
    end

    println(io, "\n## 7. 根拠付き構造化説明（keen_sfc_explanation.json）\n")
    println(
        io,
        "契約 `$(ksfc_explanation.contract_version)` / prompt `$(ksfc_explanation.prompt_version)`。",
    )
    println(io, "\n### source references（数値レポートとの相互参照）\n")
    println(io, _sfc_econ_md_sources_table(ksfc_explanation.source_references))
    println(
        io,
        _sfc_econ_md_explanation_sections(ksfc_explanation, DME.CROSS_MODEL_OUTPUT_SECTION_ORDER),
    )
    println(io, "\n**免責**: $(ksfc_explanation.disclaimer)")

    println(io, "\n## 8. 保存した成果物\n")
    for name in artifact_names
        println(io, "- `$(name)`")
    end

    if !isempty(ksfc_report.warnings)
        println(io, "\n## 9. 警告（安全性・限界）\n")
        for w in ksfc_report.warnings
            println(io, "- $(w)")
        end
    end

    write(path, String(take!(io)))
    path
end

# ─────────────────────────────────────────────────────────────────
# 本体: 一連のフローを実行し成果物を保存する
# ─────────────────────────────────────────────────────────────────

"""
    run_sfc_ai_economist(; outdir, provider=nothing, audience=:analyst, detail=:standard,
                          make_plots=true, verbose=true) -> NamedTuple

SIM 型 SFC モデルの統合フロー（シナリオ構築→会計検証→能力 metadata→比較 API v2→
Keen–SFC 比較レポート→根拠付き説明→保存）を実行し、保存した成果物パスと主要結果を
返す。API キー不要・完全に決定的（RNG を使わない）に完走する。

保存する説明成果物は決定的な `deterministic` 生成を正とする。`provider` を渡した場合は
契約検証を通過した応答のみ採用し（`parsed`）、未通過は安全 fallback を記録する
（数値・保存物は不変）。
"""
function run_sfc_ai_economist(;
    outdir::AbstractString,
    provider = nothing,
    audience::Symbol = :analyst,
    detail::Symbol = :standard,
    make_plots::Bool = true,
    verbose::Bool = true,
)
    isdir(outdir) || mkpath(outdir)
    say(args...) = verbose && println(args...)

    # ---- Step 1  シナリオ構築 --------------------------------------------
    say("=" ^ 64)
    say("Step 1  baseline / 財政ショック シナリオの構築")
    say("=" ^ 64)
    n_periods = 40
    periods = _sfc_econ_quarterly_labels(n_periods)
    m = SIMModel(; α1 = 0.6, α2 = 0.4, θ = 0.2, G = 20.0)
    shock_size = 5.0

    baseline_series = simulate(m, 0.0; T = n_periods)
    shock_series =
        impulse_response(m, shock_size; shock = :G, T = n_periods, permanent = true)
    say(
        "  baseline Y[end]=$(round(baseline_series.Y[end], sigdigits = 6))" *
        "（定常 Y*=$(round(steady_state(m).Y, sigdigits = 6))）",
    )
    say("  fiscal_shock ΔG=+$(shock_size)  Y[end]=$(round(shock_series.Y[end], sigdigits = 6))")

    # ---- Step 2  SFC 会計（貸借対照表・取引フロー・valuation・会計検証）--
    say("\n" * "=" ^ 64)
    say("Step 2  SFC 会計表の構成と全期の会計恒等式検証（#147）")
    say("=" ^ 64)
    baseline_sfc =
        sfc_result(m, baseline_series; scenario_name = "baseline", periods = periods)
    shock_sfc = sfc_result(
        m,
        shock_series;
        scenario_name = "fiscal_shock",
        periods = periods,
        shock = (type = "G", size = shock_size, permanent = true),
    )
    acc_baseline = validate_sfc_accounting(baseline_sfc)
    acc_shock = validate_sfc_accounting(shock_sfc)
    say(
        "  baseline: ",
        accounting_status_label(acc_baseline.status),
        "  pass $(acc_baseline.checks_passed)/$(acc_baseline.checks_performed)",
    )
    say(
        "  fiscal_shock: ",
        accounting_status_label(acc_shock.status),
        "  pass $(acc_shock.checks_passed)/$(acc_shock.checks_performed)",
    )

    # ---- Step 3  モデル能力・概念定義 metadata（#149）--------------------
    say("\n" * "=" ^ 64)
    say("Step 3  モデル能力プロファイル・概念定義 metadata の出力（#149）")
    say("=" ^ 64)
    cap_sim = model_capabilities(:sim)
    cap_keen = model_capabilities(:keen)
    say("  sim: sectors=$(cap_sim.sectors)  accounting_closure=$(cap_sim.accounting_closure)")
    say(
        "  keen: sectors=$(cap_keen.sectors)  accounting_closure=$(cap_keen.accounting_closure)",
    )

    # ---- Step 4  比較 API v2 を合成「実データ」へ適用（#150）-------------
    say("\n" * "=" ^ 64)
    say("Step 4  比較 API v2 を合成「実データ」proxy へ適用（#150）")
    say("=" ^ 64)
    synthetic_ds = _sfc_econ_synthetic_dataset(periods, baseline_series)
    synthetic_sr = to_simulation_result(synthetic_ds, "synthetic_actual")
    model_sr_dated = SimulationResult(
        baseline_sfc.simulation_result.model_name,
        baseline_sfc.simulation_result.scenario_name,
        baseline_sfc.simulation_result.variables,
        merge(
            baseline_sfc.simulation_result.metadata,
            Dict{String, Any}("dates" => periods, "unit" => "wage units"),
        ),
    )
    v2_spec = ComparisonSpec(;
        mode = :trajectory,
        mappings = [
            VariableComparisonMapping(;
                model_variable = "Y",
                data_variable = "SFC_SYN_Y",
                mapping_type = :proxy,
                model_concept_id = :sim_output_Y,
                caveats = ["合成 proxy（デモ用）。観測データではない。"],
            ),
            VariableComparisonMapping(;
                model_variable = "G",
                data_variable = "SFC_SYN_G",
                mapping_type = :proxy,
                caveats = ["合成 proxy（デモ用）。観測データではない。"],
            ),
        ],
    )
    comparison_v2 = compare_results_v2(model_sr_dated, synthetic_sr; spec = v2_spec)
    say(
        "  level=$(comparison_v2.assessment.level)  比較変数=$(sort(collect(keys(comparison_v2.metrics))))",
    )

    # ---- Step 5  Keen–SFC 概念対応・比較レポート（#151）------------------
    say("\n" * "=" ^ 64)
    say("Step 5  Keen–SFC 概念対応・比較レポートの生成（#151）")
    say("=" ^ 64)
    ksfc_report = compare_keen_sfc(;
        sim_result = baseline_sfc.simulation_result,
        accounting_report = acc_baseline,
        model_metadata = Dict{Symbol, ModelMetadata}(:sim => ModelMetadata(m)),
    )
    say(
        "  共通概念(equivalent)=$(length(ksfc_report.shared_concepts))  " *
        "部分対応=$(length(ksfc_report.partial_concepts))  " *
        "比較不能=$(length(ksfc_report.incomparable_concepts))",
    )

    # ---- Step 6  根拠付き構造化説明（ADR 0006）---------------------------
    say("\n" * "=" ^ 64)
    say("Step 6  根拠付き構造化説明の生成（ADR 0006 / #151）")
    say("=" ^ 64)
    ksfc_explanation =
        explain_keen_sfc_comparison(ksfc_report; audience = audience, detail = detail)
    say("  deterministic 生成: status=$(ksfc_explanation.generation_status)")

    provider_status = "not_invoked"
    provider_desc = (kind = "none", model = "none", uses_api = false)
    if provider !== nothing
        provider_desc = _sfc_econ_provider_descriptor(provider)
        say(
            "  provider 実演: $(provider_desc.kind) / $(provider_desc.model)（uses_api=$(provider_desc.uses_api)）",
        )
        provider_out = explain_keen_sfc_comparison(
            ksfc_report;
            audience = audience,
            detail = detail,
            provider = provider,
        )
        provider_status = string(provider_out.generation_status)
        say("  provider 応答 generation_status=$(provider_status)（parsed=契約通過 / fallback=安全側）")
        say("  ※ 保存する説明成果物は決定的 deterministic を正とする（provider 応答は検証実演）。")
    else
        say("  provider=nothing（offline）。deterministic 生成のみ。")
    end

    # ---- Step 7  図の保存 --------------------------------------------------
    artifact_paths = String[]
    if make_plots
        say("\n" * "=" ^ 64)
        say("Step 7  可視化の保存")
        say("=" ^ 64)
        figs = (
            (
                "sfc_baseline_trajectories.png",
                plot_result(
                    baseline_sfc.simulation_result;
                    vars = ["Y", "C", "H"],
                    title = "SIM: baseline（Y, C, H）",
                ),
            ),
            (
                "sfc_fiscal_shock_trajectories.png",
                plot_result(
                    shock_sfc.simulation_result;
                    vars = ["Y", "C", "H"],
                    title = "SIM: fiscal shock（ΔG=+$(shock_size)、Y, C, H）",
                ),
            ),
            (
                "sfc_household_wealth_comparison.png",
                plot_comparison(
                    [baseline_sfc.simulation_result, shock_sfc.simulation_result];
                    var = "H",
                    labels = ["baseline", "fiscal_shock"],
                    title = "家計貨幣資産 H: baseline vs 財政ショック",
                    ylabel = "H (wage units)",
                ),
            ),
        )
        for (name, fig) in figs
            path = joinpath(outdir, name)
            savefig(fig, path)
            push!(artifact_paths, path)
            say("  saved: $(name)")
        end
    end

    # ---- Step 8  機械可読成果物・説明・provenance の保存 -------------------
    say("\n" * "=" ^ 64)
    say("Step 8  機械可読成果物・説明・provenance の保存")
    say("=" ^ 64)

    base_path = joinpath(outdir, "sfc_result_baseline.json")
    save_sfc_result(base_path, baseline_sfc)
    shock_path = joinpath(outdir, "sfc_result_fiscal_shock.json")
    save_sfc_result(shock_path, shock_sfc)

    acc_path = joinpath(outdir, "accounting_checks.json")
    write(
        acc_path,
        JSON3.write(
            Dict{String, Any}(
                "baseline" => to_dict(acc_baseline),
                "fiscal_shock" => to_dict(acc_shock),
            ),
        ),
    )

    cap_path = joinpath(outdir, "model_capabilities.json")
    write(
        cap_path,
        JSON3.write(
            Dict{String, Any}("sim" => to_dict(cap_sim), "keen" => to_dict(cap_keen)),
        ),
    )

    v2_path = joinpath(outdir, "comparison_v2.json")
    write(v2_path, to_json(comparison_v2))

    ksfc_report_path = joinpath(outdir, "keen_sfc_comparison.json")
    write(ksfc_report_path, to_json(ksfc_report))

    ksfc_expl_path = joinpath(outdir, "keen_sfc_explanation.json")
    write(ksfc_expl_path, to_json(ksfc_explanation))

    manifest = Dict{String, Any}(
        "demo" => "sfc_ai_economist",
        "run_timestamp" => string(now()),
        "code_revision" => _sfc_econ_git_revision(),
        "scenario" => Dict{String, Any}(
            "parameters" => Dict{String, Any}(
                "α1" => m.α1,
                "α2" => m.α2,
                "θ" => m.θ,
                "G" => m.G,
                "W" => m.W,
            ),
            "n_periods" => n_periods,
            "periods_start" => periods[1],
            "periods_end" => periods[end],
            "fiscal_shock_size" => shock_size,
        ),
        "accounting" => Dict{String, Any}(
            "baseline_status" => accounting_status_label(acc_baseline.status),
            "baseline_passed" => accounting_passed(acc_baseline),
            "fiscal_shock_status" => accounting_status_label(acc_shock.status),
            "fiscal_shock_passed" => accounting_passed(acc_shock),
        ),
        "methodology" => Dict{String, Any}(
            "sfc_contract" => SFC_CONTRACT_VERSION,
            "sfc_accounting" => SFC_ACCOUNTING_METHODOLOGY_VERSION,
            "sim_sfc_model" => SIM_SFC_MODEL_VERSION,
            "model_capability_contract" => MODEL_CAPABILITY_CONTRACT_VERSION,
            "comparison_v2_contract" => DME.COMPARISON_V2_CONTRACT_VERSION,
            "keen_sfc_comparison_contract" => KEEN_SFC_COMPARISON_CONTRACT_VERSION,
            "cross_model_context_contract" => CROSS_MODEL_CONTEXT_CONTRACT_VERSION,
            "cross_model_output_contract" => CROSS_MODEL_OUTPUT_CONTRACT_VERSION,
            "cross_model_prompt" => CROSS_MODEL_PROMPT_VERSION,
        ),
        "llm_provider" => Dict{String, Any}(
            "kind" => provider_desc.kind,
            "model" => provider_desc.model,
            "uses_api" => provider_desc.uses_api,
        ),
        "explanation" => Dict{String, Any}(
            "generation_status" => string(ksfc_explanation.generation_status),
            "sections" =>
                _sfc_econ_section_overview(ksfc_explanation, DME.CROSS_MODEL_OUTPUT_SECTION_ORDER),
            "provider_roundtrip_status" => provider_status,
            "incomparable_concepts" =>
                String[String(c.concept) for c in ksfc_report.incomparable_concepts],
            "numeric_comparisons" => sort(collect(String.(keys(ksfc_report.numeric_comparisons)))),
        ),
        "warnings" => vcat(comparison_v2.warnings, ksfc_report.warnings),
    )
    manifest_path = joinpath(outdir, "run_manifest.json")
    write(manifest_path, JSON3.write(manifest))

    artifact_names = [
        basename(p) for p in vcat(
            artifact_paths,
            [
                base_path,
                shock_path,
                acc_path,
                cap_path,
                v2_path,
                ksfc_report_path,
                ksfc_expl_path,
            ],
        )
    ]
    md_path = joinpath(outdir, "report.md")
    _sfc_econ_write_markdown_report(
        md_path,
        baseline_series,
        shock_series,
        acc_baseline,
        acc_shock,
        comparison_v2,
        ksfc_report,
        ksfc_explanation,
        manifest,
        vcat(artifact_names, ["run_manifest.json"]),
    )

    for p in (
        base_path,
        shock_path,
        acc_path,
        cap_path,
        v2_path,
        ksfc_report_path,
        ksfc_expl_path,
        manifest_path,
        md_path,
    )
        say("  saved: $(basename(p))")
    end

    (
        outdir = outdir,
        baseline_sfc = baseline_sfc,
        shock_sfc = shock_sfc,
        acc_baseline = acc_baseline,
        acc_shock = acc_shock,
        model_capabilities = (sim = cap_sim, keen = cap_keen),
        comparison_v2 = comparison_v2,
        ksfc_report = ksfc_report,
        ksfc_explanation = ksfc_explanation,
        provider_roundtrip_status = provider_status,
        manifest = manifest,
        artifact_paths = vcat(
            artifact_paths,
            [
                base_path,
                shock_path,
                acc_path,
                cap_path,
                v2_path,
                ksfc_report_path,
                ksfc_expl_path,
                manifest_path,
                md_path,
            ],
        ),
    )
end

# ─────────────────────────────────────────────────────────────────
# スクリプトとして直接実行された場合のみ走らせる（include では実行しない）
# ─────────────────────────────────────────────────────────────────
if abspath(PROGRAM_FILE) == @__FILE__
    outdir = get(
        ENV,
        "SFC_AI_DEMO_OUTDIR",
        joinpath(@__DIR__, "..", "artifacts", "sfc_ai_economist"),
    )
    # provider: OPENAI_API_KEY が設定されていれば OpenAIProvider、なければ MockLLMProvider。
    provider = create_provider()

    println(
        """
╔═══════════════════════════════════════════════════════════════════╗
║  SFC対応 AIエコノミスト統合デモ                                     ║
║  シナリオ→SFC会計→検証→能力metadata→比較v2→Keen–SFC比較→説明→保存   ║
╚═══════════════════════════════════════════════════════════════════╝

  LLM provider: $(_sfc_econ_provider_descriptor(provider).kind) / $(_sfc_econ_provider_descriptor(provider).model)
  出力先: $(outdir)

注意: SIM は金融不安定性・企業債務・分配動学・危機regime を持たない。
      比較 API v2 の「実データ」は合成 proxy。Keen–SFC の比較不能概念に数値 metric を生成しない。
      投資助言・危機確率・政策最適性の自動化は目的としない。
""",
    )

    out = run_sfc_ai_economist(; outdir = outdir, provider = provider)

    println(
        """

完了。出力ディレクトリ: $(out.outdir)

再現性: RNG を用いず完全に決定的（同一パラメータで同一の数値・説明成果物）。
        run_manifest.json に契約 version・code revision・provider・実行日時・警告を記録。
限界: SIM は大域安定な需要決定モデルであり金融不安定性・企業債務・分配動学・危機regime を持たない。
      Keen–SFC 比較は比較不能な概念を統合しない。合成「実データ」は観測データではない。
詳細: docs/examples/sfc_ai_economist.md
""",
    )
end
