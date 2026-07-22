# examples/keen_empirical_ai_economist.jl
#
# Keen 実証分析を「AIエコノミスト」として実演する統合デモ（Issue #134）
#
# データ取得 → 測定変換・欠損処理・期間整合 → 限定キャリブレーション →
# in-sample/out-of-sample 検証 → observed proxy regime 診断 → 感応度分析 →
# 拡張 AnalysisContext（keen_empirical）→ 根拠付き LLM 説明（ADR 0005）→
# クロスモデル比較（ADR 0006）→ 数値・図表・context・説明の run 単位保存
# までを 1 本で再現可能に完走する。
#
# 実行方法（外部 API キー不要の offline 経路が既定・正）:
#   julia --project=. examples/keen_empirical_ai_economist.jl
#
# 取得モードの切替（同一の公開契約。live/rest_api は追加経路）:
#   DME_DATA_MODE=fixture   … test/fixtures/keen の固定 JSON（既定・決定的・CI 用）
#   DME_DATA_MODE=live      … FRED API（要 FRED_API_KEY）
#   DME_DATA_MODE=rest_api  … economic-data-provider REST API（要 DATA_PROVIDER_BASE_URL）
#   source unavailable 時に fixture へ暗黙 fallback はせず、失敗理由を表示して停止する。
#
# LLM provider の切替:
#   OPENAI_API_KEY 未設定 … MockLLMProvider（API 呼び出しなし。契約検証 fallback を実演）
#   OPENAI_API_KEY 設定済 … OpenAIProvider（実 API を呼び出す）
#   いずれの場合も保存する説明成果物は決定的な deterministic 生成を正とし、
#   provider 経由の応答は契約検証（parse）を通過した場合のみ採用する（未通過は安全 fallback）。
#
# 成果物の出力先（既定はリポジトリ内 artifacts/、環境変数で上書き可）:
#   KEEN_AI_DEMO_OUTDIR=/path/to/dir
#
# 保存する成果物（再現性・provenance を含む）:
#   run_manifest.json            … データ系列・変換・推定設定・seed・code revision・
#                                    prompt version・provider/model・実行日時・警告一覧
#   keen_empirical_report.json   … dataset provenance + validation の機械可読レポート
#   keen_validation.json         … 検証・感応度の詳細
#   keen_calibration_config.json … 推定設定（固定/推定パラメータ・bounds・weight）
#   keen_ai_explanation.json     … 根拠付き構造化説明（section・claim・source 参照）
#   cross_model_reasoning.json   … クロスモデル比較（概念対応・比較不能の明示）
#   report.md                    … 人が読むサマリー（数値と source id を相互参照）
#   *.png                        … 実データ・モデル軌跡・regime・感応度・診断の図
#
# 注意（結果の限界・禁止される解釈）:
#   - 観測系列は理論変数（ω・λ・d）の近似 proxy であり厳密に同一ではない
#   - calibrated parameter は採用期間・proxy・weight・bounds に依存する
#   - observed regime も集計 proxy 診断であり企業別実測分類ではない
#   - out-of-sample fit は危機予測能力を意味しない
#   - クロスモデル比較の同名変数は定義が一致するとは限らず、比較不能な概念は統合しない
#   - 本デモは投資助言・政策判断の自動化を目的としない
#
# 関連: docs/examples/keen_empirical_ai_economist.md / docs/models/keen.md /
#       docs/models/keen_empirical_strategy.md / docs/architecture/cross_model_reasoning.md /
#       docs/adr/0005-keen-ai-explanation-contract.md / docs/adr/0006-cross-model-reasoning-contract.md

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
function _git_revision()
    try
        rev = readchomp(`git -C $(@__DIR__) rev-parse --short HEAD`)
        isempty(rev) ? "unknown" : rev
    catch
        "unknown"
    end
end

# provider の説明（秘密情報・API キーは絶対に含めない）
function _provider_descriptor(provider)
    if provider isa MockLLMProvider
        (kind = "MockLLMProvider", model = "mock", uses_api = false)
    elseif provider isa OpenAIProvider
        (kind = "OpenAIProvider", model = provider.model, uses_api = true)
    else
        (kind = string(nameof(typeof(provider))), model = "unknown", uses_api = true)
    end
end

# 説明出力の section ごとに status・claim 数を要約する
function _section_overview(out, section_order)
    [
        (
            section = k,
            status = string(getfield(out, Symbol(k)).status),
            n_claims = length(getfield(out, Symbol(k)).claims),
        ) for k in section_order
    ]
end

# ─────────────────────────────────────────────────────────────────
# Markdown レポート（数値レポートと source id を相互参照可能にする）
# ─────────────────────────────────────────────────────────────────

function _md_sources_table(sources)
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

function _md_explanation_sections(out, section_order)
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

function _write_markdown_report(
    path,
    dataset,
    result,
    keen_out,
    cross_out,
    manifest,
    artifact_names,
)
    cal = result.calibration_result
    io = IOBuffer()
    println(io, "# Keen 実証 AIエコノミスト統合デモ — 実行レポート\n")
    println(
        io,
        "> 本レポートは自動生成物です。実証 fit は因果・危機確率・投資判断ではありません。",
    )
    println(
        io,
        "> observed regime は集計 proxy 診断であり、企業別実測分類ではありません。\n",
    )

    println(io, "## 1. 実行メタデータ（provenance）\n")
    println(io, "- 実行日時: `$(manifest["run_timestamp"])`")
    println(io, "- code revision: `$(manifest["code_revision"])`")
    println(io, "- データ取得モード: `$(manifest["data_mode"])`")
    println(
        io,
        "- LLM provider: `$(manifest["llm_provider"]["kind"])` / model `$(manifest["llm_provider"]["model"])`（API 呼び出し: $(manifest["llm_provider"]["uses_api"])）",
    )
    println(
        io,
        "- prompt versions: keen=`$(keen_out.prompt_version)`, cross_model=`$(cross_out.prompt_version)`",
    )
    println(
        io,
        "- 説明 generation_status: keen=`$(keen_out.generation_status)`, cross_model=`$(cross_out.generation_status)`",
    )

    println(io, "\n## 2. データセット\n")
    println(
        io,
        "- 期間: `$(dataset.metadata["sample_start"])` .. `$(dataset.metadata["sample_end"])`（観測数 $(length(dataset))）",
    )
    println(
        io,
        "- 分割: calibration $(length(dataset.calibration_indices)) / validation $(length(dataset.validation_indices))（後方ホールドアウト・look-ahead なし）",
    )
    println(io, "- r_param: `$(round(dataset.r_param, sigdigits = 4))`")
    if !isempty(dataset.dropped_dates)
        println(
            io,
            "- quality: 欠損/invalid で除外した四半期 $(length(dataset.dropped_dates)) 件",
        )
    end
    println(io, "\n採用系列と単位変換:\n")
    println(io, "| 変数 | series_id | 単位 | 変換 | 集計 |")
    println(io, "|---|---|---|---|---|")
    for v in (:ω, :λ, :d, :r)
        p = dataset.provenance[v]
        println(
            io,
            "| $(v) | `$(p.series_id)` | $(p.original_unit) | $(p.conversion_formula) | $(p.aggregation) |",
        )
    end

    println(io, "\n## 3. 推定・検証（数値レポート要約）\n")
    println(io, "推定対象パラメータの calibrated 値:\n")
    for (k, val) in sort(collect(cal.estimated))
        println(io, "- `$(k)` = $(round(val, sigdigits = 6))")
    end
    println(
        io,
        "\n- objective(calibrated) = `$(round(cal.objective_value, sigdigits = 6))`, objective(literature) = `$(round(cal.literature_objective, sigdigits = 6))`",
    )
    println(
        io,
        "- converged = `$(cal.converged)`, boundary_hits = `$(cal.boundary_hits)`, weak_identification = `$(cal.weak_identification)`",
    )
    println(
        io,
        "- 集計 RMSE: literature = `$(result.metadata["aggregate_rmse_literature"])`, calibrated = `$(result.metadata["aggregate_rmse_calibrated"])`",
    )
    println(
        io,
        "- calibrated が literature より悪化: `$(result.calibrated_worse_than_literature)`",
    )

    println(io, "\n## 4. 根拠付き LLM 説明（keen_ai_explanation.json）\n")
    println(
        io,
        "契約 `$(keen_out.contract_version)` / prompt `$(keen_out.prompt_version)`。",
    )
    println(
        io,
        "各 claim は認識論的性質（observed / measured / estimated / model_output / diagnostic_proxy / interpretation …）と source id を明示する。",
    )
    println(io, "\n### source references（数値レポートとの相互参照）\n")
    println(io, _md_sources_table(keen_out.source_references))
    println(io, _md_explanation_sections(keen_out, DME.KEEN_OUTPUT_SECTION_ORDER))
    println(io, "\n**免責**: $(keen_out.disclaimer)")

    println(io, "\n## 5. クロスモデル比較（cross_model_reasoning.json）\n")
    println(
        io,
        "契約 `$(cross_out.contract_version)` / prompt `$(cross_out.prompt_version)`。",
    )
    println(
        io,
        "同名変数は定義が一致するとは限らず、比較不能な概念は `insufficient_comparability` として非統合。",
    )
    println(io, _md_explanation_sections(cross_out, DME.CROSS_MODEL_OUTPUT_SECTION_ORDER))
    println(io, "\n**免責**: $(cross_out.disclaimer)")

    println(io, "\n## 6. 保存した成果物\n")
    for name in artifact_names
        println(io, "- `$(name)`")
    end

    if !isempty(result.warnings)
        println(io, "\n## 7. 警告（不利な結果・発散を隠さない）\n")
        for w in result.warnings
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
    run_keen_empirical_ai_economist(; outdir, mode=:fixture, fixture_dir=..., provider=nothing,
                                    audience=:analyst, detail=:standard, make_plots=true,
                                    verbose=true) -> NamedTuple

Keen 実証分析の統合フロー（データ→推定→検証→拡張 context→根拠付き説明→クロスモデル比較→保存）を
実行し、保存した成果物パスと主要結果を返す。offline（fixture + provider なし/mock）で決定的に完走する。

保存する説明成果物は決定的な `deterministic` 生成を正とする。`provider` を渡した場合は契約検証を
通過した応答のみ採用し（`parsed`）、未通過は安全 fallback を記録する（数値・保存物は不変）。
"""
function run_keen_empirical_ai_economist(;
    outdir::AbstractString,
    mode::Symbol = :fixture,
    fixture_dir::AbstractString = joinpath(@__DIR__, "..", "test", "fixtures", "keen"),
    provider = nothing,
    audience::Symbol = :analyst,
    detail::Symbol = :standard,
    make_plots::Bool = true,
    verbose::Bool = true,
)
    isdir(outdir) || mkpath(outdir)
    say(args...) = verbose && println(args...)

    # ---- Step 1  データセット構築 ----------------------------------------
    say("=" ^ 64)
    say("Step 1  KeenEmpiricalDataset の構築（mode=$(mode)）")
    say("=" ^ 64)
    client = if mode === :fixture
        FredClient(; mode = :fixture, fixture_dir = fixture_dir)
    else
        FredClient(; mode = mode)  # source unavailable 時は明示的に失敗する
    end
    dataset = build_keen_empirical_dataset(keen_us_default_config(); client = client)
    say(
        "  期間 $(dataset.metadata["sample_start"]) .. $(dataset.metadata["sample_end"])  観測数=$(length(dataset))",
    )
    say(
        "  分割: calibration=$(length(dataset.calibration_indices))  validation=$(length(dataset.validation_indices))",
    )

    # ---- Step 2  推定・検証・regime・感応度 ------------------------------
    say("\n" * "=" ^ 64)
    say("Step 2  限定キャリブレーション → 検証 → regime → 感応度")
    say("=" ^ 64)
    calib_config = keen_default_calibration_config(dataset; n_starts = 5)
    valid_config =
        keen_default_validation_config(dataset; calibration_config = calib_config)
    result = validate_keen(dataset, valid_config)
    cal = result.calibration_result
    say(
        "  推定: ",
        join(
            ["$(k)=$(round(v, sigdigits = 5))" for (k, v) in sort(collect(cal.estimated))],
            "  ",
        ),
    )
    say(
        "  objective calibrated=$(round(cal.objective_value, sigdigits = 5))  literature=$(round(cal.literature_objective, sigdigits = 5))",
    )
    say(
        "  converged=$(cal.converged)  calibrated_worse=$(result.calibrated_worse_than_literature)",
    )

    # ---- Step 3  拡張 AnalysisContext（keen_empirical）-------------------
    say("\n" * "=" ^ 64)
    say("Step 3  拡張 AnalysisContext の構築（keen_empirical / ADR 0005 §3）")
    say("=" ^ 64)
    kctx = KeenEmpiricalContext(dataset, result; mode = client.mode)
    b = result.trajectories
    ω0, λ0, d0 = b.observed[:ω][1], b.observed[:λ][1], b.observed[:d][1]
    keen_traj = simulate(cal.model, ω0, λ0, d0; T = length(dataset))
    keen_sr = to_simulation_result(cal.model, keen_traj, "keen_calibrated_us")
    actx = AnalysisContext(
        cal.model,
        keen_sr;
        keen_empirical = kctx,
        caveats = Caveats(
            [
                "Keen モデルは代表的経済の集計動学であり企業別の異質性を持たない",
                "年単位 ODE を Δt=0.25 で四半期観測に対応させる時間軸契約に依存する",
            ],
            [
                "観測系列は理論変数 ω・λ・d の近似 proxy（厳密同一ではない）",
                "取得モード=$(client.mode)。fixture は固定 JSON で決定的",
            ],
            [
                "calibrated parameter は採用期間・proxy・weight・bounds に依存する",
                "out-of-sample fit は危機予測能力を意味しない",
            ],
        ),
    )
    say(
        "  keen_empirical sources: $(length(kctx.sources))  model=$(actx.model_metadata.model_name)",
    )

    # ---- Step 4  根拠付き LLM 説明（deterministic 正 + provider 実演）----
    say("\n" * "=" ^ 64)
    say("Step 4  根拠付き構造化説明の生成（ADR 0005 §4）")
    say("=" ^ 64)
    keen_explanation =
        explain_keen_empirical_result(actx; audience = audience, detail = detail)
    say(
        "  deterministic 生成: status=$(keen_explanation.generation_status)  sections=$(length(DME.KEEN_OUTPUT_SECTION_ORDER))",
    )

    provider_status = "not_invoked"
    provider_desc = (kind = "none", model = "none", uses_api = false)
    if provider !== nothing
        provider_desc = _provider_descriptor(provider)
        say(
            "  provider 実演: $(provider_desc.kind) / $(provider_desc.model)（uses_api=$(provider_desc.uses_api)）",
        )
        provider_out = explain_keen_empirical_result(
            actx;
            audience = audience,
            detail = detail,
            provider = provider,
        )
        provider_status = string(provider_out.generation_status)
        say(
            "  provider 応答 generation_status=$(provider_status)（parsed=契約通過 / fallback=安全側）",
        )
        say(
            "  ※ 保存する説明成果物は決定的 deterministic を正とする（provider 応答は検証実演）。",
        )
    else
        say("  provider=nothing（offline）。deterministic 生成のみ。")
    end

    # ---- Step 5  クロスモデル比較（ADR 0006）----------------------------
    say("\n" * "=" ^ 64)
    say("Step 5  クロスモデル比較の生成（ADR 0006）")
    say("=" ^ 64)
    cross_ctx = build_cross_model_comparison_context(;
        models = [:keen, :rbc, :islm],
        empirical = kctx,
    )
    insufficient = insufficient_comparability_concepts(cross_ctx)
    cross_explanation =
        explain_cross_model_comparison(cross_ctx; audience = audience, detail = detail)
    say("  比較モデル: keen / rbc / islm")
    say(
        "  比較不能 concept（insufficient_comparability）: $(isempty(insufficient) ? "なし" : insufficient)",
    )
    say("  empirical_support: $(cross_explanation.empirical_support.status)")

    # ---- Step 6  図の保存 ------------------------------------------------
    artifact_paths = String[]
    if make_plots
        say("\n" * "=" ^ 64)
        say("Step 6  可視化の保存（欠損・発散後は 0 化・補間せず線を途切れさせる）")
        say("=" ^ 64)
        figs = (
            ("keen_trajectories.png", plot_keen_empirical_trajectories(result)),
            ("keen_regime_comparison.png", plot_keen_regime_comparison(result)),
            (
                "keen_sensitivity_peak_debt.png",
                plot_keen_sensitivity(result; metric = :peak_debt_ratio),
            ),
            (
                "keen_calibrated_diagnostics.png",
                plot_minsky_diagnostics(result.regime_comparison.calibrated),
            ),
        )
        for (name, fig) in figs
            path = joinpath(outdir, name)
            savefig(fig, path)
            push!(artifact_paths, path)
            say("  saved: $(name)")
        end
    end

    # ---- Step 7  機械可読成果物の保存 ------------------------------------
    say("\n" * "=" ^ 64)
    say("Step 7  機械可読成果物・説明・provenance の保存")
    say("=" ^ 64)

    report_path = joinpath(outdir, "keen_empirical_report.json")
    save_keen_empirical_report(
        report_path,
        dataset,
        result;
        mode = client.mode,
        artifact_paths = artifact_paths,
    )
    validation_path = joinpath(outdir, "keen_validation.json")
    save_keen_validation(validation_path, result)
    config_path = joinpath(outdir, "keen_calibration_config.json")
    save_keen_calibration_config(config_path, calib_config)

    keen_expl_path = joinpath(outdir, "keen_ai_explanation.json")
    write(keen_expl_path, to_json(keen_explanation))
    cross_path = joinpath(outdir, "cross_model_reasoning.json")
    write(cross_path, to_json(cross_explanation))

    # run manifest（再現性・provenance）。秘密情報は含めない。
    manifest = Dict{String, Any}(
        "demo" => "keen_empirical_ai_economist",
        "run_timestamp" => string(now()),
        "code_revision" => _git_revision(),
        "data_mode" => string(client.mode),
        "seed" => calib_config.seed,
        "n_starts" => calib_config.n_starts,
        "estimated_params" => string.(calib_config.estimated_params),
        "sample" => Dict(
            "start" => dataset.metadata["sample_start"],
            "end" => dataset.metadata["sample_end"],
            "n_obs" => length(dataset),
            "n_calibration" => length(dataset.calibration_indices),
            "n_validation" => length(dataset.validation_indices),
        ),
        "series" => Dict(
            string(v) => Dict(
                "series_id" => dataset.provenance[v].series_id,
                "original_unit" => dataset.provenance[v].original_unit,
                "conversion" => dataset.provenance[v].conversion_formula,
                "aggregation" => string(dataset.provenance[v].aggregation),
                "mode" => string(dataset.provenance[v].mode),
            ) for v in (:ω, :λ, :d, :r)
        ),
        "methodology" => Dict(
            "data" => KEEN_EMPIRICAL_METHODOLOGY_VERSION,
            "calibration" => KEEN_CALIBRATION_METHODOLOGY_VERSION,
            "validation" => KEEN_VALIDATION_METHODOLOGY_VERSION,
            "keen_ai_context" => KEEN_AI_CONTEXT_CONTRACT_VERSION,
            "keen_ai_output" => KEEN_AI_OUTPUT_CONTRACT_VERSION,
            "keen_prompt" => KEEN_AI_PROMPT_VERSION,
            "cross_model_context" => CROSS_MODEL_CONTEXT_CONTRACT_VERSION,
            "cross_model_output" => CROSS_MODEL_OUTPUT_CONTRACT_VERSION,
            "cross_model_prompt" => CROSS_MODEL_PROMPT_VERSION,
        ),
        "llm_provider" => Dict(
            "kind" => provider_desc.kind,
            "model" => provider_desc.model,
            "uses_api" => provider_desc.uses_api,
        ),
        "explanation" => Dict(
            "keen_generation_status" => string(keen_explanation.generation_status),
            "keen_sections" =>
                _section_overview(keen_explanation, DME.KEEN_OUTPUT_SECTION_ORDER),
            "cross_model_generation_status" =>
                string(cross_explanation.generation_status),
            "cross_model_sections" => _section_overview(
                cross_explanation,
                DME.CROSS_MODEL_OUTPUT_SECTION_ORDER,
            ),
            "provider_roundtrip_status" => provider_status,
            "insufficient_comparability" => string.(insufficient),
        ),
        "warnings" => string.(result.warnings),
    )
    manifest_path = joinpath(outdir, "run_manifest.json")
    write(manifest_path, JSON3.write(manifest))

    artifact_names = [
        basename(p) for p in vcat(
            artifact_paths,
            [report_path, validation_path, config_path, keen_expl_path, cross_path],
        )
    ]
    md_path = joinpath(outdir, "report.md")
    _write_markdown_report(
        md_path,
        dataset,
        result,
        keen_explanation,
        cross_explanation,
        manifest,
        vcat(artifact_names, ["run_manifest.json"]),
    )

    for p in (
        report_path,
        validation_path,
        config_path,
        keen_expl_path,
        cross_path,
        manifest_path,
        md_path,
    )
        say("  saved: $(basename(p))")
    end

    (
        outdir = outdir,
        dataset = dataset,
        result = result,
        keen_context = kctx,
        keen_explanation = keen_explanation,
        cross_context = cross_ctx,
        cross_explanation = cross_explanation,
        provider_roundtrip_status = provider_status,
        manifest = manifest,
        artifact_paths = vcat(
            artifact_paths,
            [
                report_path,
                validation_path,
                config_path,
                keen_expl_path,
                cross_path,
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
    mode = Symbol(get(ENV, "DME_DATA_MODE", "fixture"))
    outdir = get(
        ENV,
        "KEEN_AI_DEMO_OUTDIR",
        joinpath(@__DIR__, "..", "artifacts", "keen_empirical_ai_economist"),
    )
    # provider: OPENAI_API_KEY が設定されていれば OpenAIProvider、なければ MockLLMProvider。
    provider = create_provider()

    println(
        """
╔═══════════════════════════════════════════════════════════════════╗
║  Keen 実証 AIエコノミスト統合デモ                                   ║
║  データ→推定→検証→拡張context→根拠付き説明→クロスモデル比較→保存   ║
╚═══════════════════════════════════════════════════════════════════╝

  取得モード: $(mode)
  LLM provider: $(_provider_descriptor(provider).kind) / $(_provider_descriptor(provider).model)
  出力先: $(outdir)

注意: 実証 fit は因果・危機確率・予測精度と同一ではない。observed regime は集計 proxy 診断。
      同名変数の非同一視・比較不能の非統合を守る。投資助言・政策判断の自動化は目的としない。
""",
    )

    out =
        run_keen_empirical_ai_economist(; outdir = outdir, mode = mode, provider = provider)

    println(
        """

完了。出力ディレクトリ: $(out.outdir)

再現性: fixture + deterministic 生成は固定データ・固定設定・固定 seed で決定的に完走する。
        run_manifest.json に code revision・prompt version・provider・実行日時・警告を記録。
限界: 実証 fit は因果・危機確率・投資判断ではない。observed regime は集計 proxy 診断。
      クロスモデル比較は同名変数を同一視せず、比較不能な概念を統合しない。
詳細: docs/examples/keen_empirical_ai_economist.md
""",
    )
end
