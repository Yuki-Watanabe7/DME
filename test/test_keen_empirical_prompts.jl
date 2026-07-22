@testset "Keen 実証 説明 API / prompt（ADR 0005 §4〜§9）" begin
    lit = KEEN_LITERATURE_PARAMS
    m = KeenModel(lit.α, lit.β, lit.δ, lit.ν, lit.r, 0.05, 8.0e-5, -0.005, 0.007, lit.κ2)

    # --- 合成 dataset（test_keen_empirical_context.jl と同じ手順）--------------
    function rk4_states(m::KeenModel; n = 40, ωf = 0.99, λf = 0.999, df = 1.01)
        ss = DME.steady_state(m)
        ω, λ, d = ss.ω * ωf, ss.λ * λf, ss.d * df
        ωs, λs, ds = Float64[], Float64[], Float64[]
        for _ in 1:n
            push!(ωs, ω)
            push!(λs, λ)
            push!(ds, d)
            ω, λ, d = DME.keen_rk4_step(m, ω, λ, d, 0.25)
        end
        (ωs, λs, ds)
    end

    function synth_dataset(
        m::KeenModel;
        n = 40,
        validation_split = 0.3,
        drop_missing = false,
    )
        ωs, λs, ds = rk4_states(m; n = n)
        ql = ["$(2000 + (i - 1) ÷ 4)-Q$(((i - 1) % 4) + 1)" for i in 1:n]
        ωvals = convert(Vector{Union{Float64, Missing}}, ωs .* 100)
        if drop_missing
            ωvals[5] = missing
            ωvals[12] = missing
        end
        mk(id, unit, vals) = DataSeries(
            id = id,
            name = id,
            source = "TEST",
            frequency = Quarterly,
            unit = unit,
            dates = ql,
            values = convert(Vector{Union{Float64, Missing}}, vals),
        )
        macro_ds = MacroDataset(
            "syn",
            DataSeries[
                mk("OMEGA", "Percent", ωvals),
                mk("LAMBDA", "Percent", (1 .- λs) .* 100),
                mk("DEBT", "Percent of GDP", ds .* 100),
                mk("RATE", "Percent", fill(m.r * 100, n)),
            ],
        )
        cfg = KeenEmpiricalDataConfig(;
            country = "TEST",
            omega = KeenSeriesSpec(;
                variable = :ω,
                source_id = "OMEGA",
                conversion = :ratio_from_percent,
                domain_lo = 0.0,
                domain_hi = 1.0,
                forbid_index = true,
            ),
            lambda = KeenSeriesSpec(;
                variable = :λ,
                source_id = "LAMBDA",
                conversion = :employment_from_unrate,
                domain_lo = 0.0,
                domain_hi = 1.0,
            ),
            debt = KeenSeriesSpec(;
                variable = :d,
                source_id = "DEBT",
                conversion = :ratio_from_percent,
                domain_lo = 0.0,
                domain_hi = 100.0,
            ),
            rate = KeenSeriesSpec(;
                variable = :r,
                source_id = "RATE",
                conversion = :ratio_from_percent,
                domain_lo = 0.0,
                domain_hi = 1.0,
            ),
            min_valid_obs = 8,
            validation_split = validation_split,
            r_mode = :sample_mean,
        )
        build_keen_empirical_dataset(cfg, macro_ds)
    end

    # 1 field だけ差し替えた新インスタンスを作る（immutable struct 用）
    function reconstruct(x::T; kwargs...) where {T}
        nt = (; kwargs...)
        T((haskey(nt, f) ? nt[f] : getfield(x, f) for f in fieldnames(T))...)
    end

    with_ctx(kctx; kwargs...) = reconstruct(kctx; kwargs...)

    build_actx(kctx) = begin
        rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
        sr = to_simulation_result(rbc, impulse_response(rbc, 0.01), "tech")
        AnalysisContext(rbc, sr; keen_empirical = kctx)
    end

    # 全 claim の source_ids が registry に存在することを確認する
    function assert_claims_resolve(out, kctx)
        ids = keys(kctx.sources)
        for key in KEEN_OUTPUT_SECTION_ORDER
            sec = DME._keen_section(out, key)
            for cl in sec.claims
                @test !isempty(cl.source_ids)
                for sid in cl.source_ids
                    @test sid in ids
                end
                # epistemic_status は category と整合
                for sid in cl.source_ids
                    exp =
                        get(DME._KEEN_CATEGORY_STATUS, kctx.sources[sid].category, nothing)
                    exp === nothing || @test exp === cl.epistemic_status
                end
            end
        end
    end

    base_ds = synth_dataset(m; n = 40)
    base_cfg = keen_default_validation_config(base_ds)
    base_res = validate_keen(base_ds, base_cfg)
    base_kctx = KeenEmpiricalContext(base_ds, base_res; mode = :fixture)

    # ---- Case 正常: 全 section available ---------------------------------
    @testset "正常: 全 section available・ラベル分離" begin
        actx = build_actx(base_kctx)
        out = explain_keen_empirical_result(actx)

        @test out.contract_version == KEEN_AI_OUTPUT_CONTRACT_VERSION
        @test out.generation_status === :deterministic
        @test out.executive_summary.status === :available
        @test out.analysis_scope.status === :available
        @test out.observed_evidence.status === :available
        @test out.measurement_and_transformations.status === :available
        @test out.calibration_interpretation.status === :available
        @test out.validation_assessment.status === :available
        @test out.regime_assessment.status === :available
        @test out.sensitivity_and_robustness.status === :available
        @test out.interpretation_scope.status === :available
        @test out.limitations_and_alternatives.status === :available
        @test occursin("投資判断", out.disclaimer)
        @test !isempty(out.source_references)

        # 推定・モデル・診断の epistemic_status が分離されている
        @test all(
            c.epistemic_status === :estimated for c in out.calibration_interpretation.claims
        )
        @test all(
            c.epistemic_status === :simulated for c in out.validation_assessment.claims
        )
        @test all(c.epistemic_status === :diagnostic for c in out.regime_assessment.claims)
        # calibrated parameter を真値と断定しない qualifier
        @test any(
            any(occursin("真値", q) || occursin("限定推定値", q) for q in c.qualifiers) for
            c in out.calibration_interpretation.claims
        )
        assert_claims_resolve(out, base_kctx)

        # source_references は claim から参照されたものだけ・重複なし
        ref_ids = [s.id for s in out.source_references]
        @test length(ref_ids) == length(unique(ref_ids))
    end

    # ---- prompt に禁止解釈の制約が含まれる（ADR 0005 §6）-----------------
    @testset "prompt: 禁止解釈の制約と source ID 要求" begin
        actx = build_actx(base_kctx)
        prompt = build_keen_empirical_prompt(actx)
        @test occursin("分析補助AI", prompt)
        @test occursin("calibrated parameter", prompt)  # 真値断定禁止
        @test occursin("out-of-sample", prompt)          # 予測保証禁止
        @test occursin("endogenous regime", prompt)      # observed proxy 同一視禁止
        @test occursin("source ID", prompt)              # source id 対応
        @test occursin("not_available", prompt)          # 情報不足時
        @test occursin("投資助言", prompt) || occursin("投資判断", prompt)
        # 免責文言
        @test occursin(
            "投資判断・政策立案の根拠として使用することを意図していません",
            prompt,
        )
        # detail=:brief は compact context（observed 生配列なし）
        pb = build_keen_empirical_prompt(actx; detail = :brief)
        @test occursin("\"detail\": ", pb) == false  # JSON 内の key ではなく本文
        @test occursin("詳細度: brief", pb)
    end

    # ---- JSON 直列化 -----------------------------------------------------
    @testset "to_dict / to_json: NaN/Inf を含まない・section 順" begin
        out = explain_keen_empirical_result(build_actx(base_kctx))
        d = to_dict(out)
        for key in KEEN_OUTPUT_SECTION_ORDER
            @test haskey(d, key)
            @test haskey(d[key], "status")
            @test haskey(d[key], "claims")
        end
        @test haskey(d, "source_references")
        @test haskey(d, "reproducibility")
        js = to_json(out)
        @test !occursin("NaN", js) && !occursin("Inf", js)
        @test occursin("keen-ai-output/1.0.0", js)
    end

    # ---- Case データ欠損 --------------------------------------------------
    @testset "データ欠損: measurement に dropped_dates" begin
        ds = synth_dataset(m; n = 40, drop_missing = true)
        res = validate_keen(ds, keen_default_validation_config(ds))
        kctx = KeenEmpiricalContext(ds, res; mode = :fixture)
        out = explain_keen_empirical_result(build_actx(kctx))
        @test out.measurement_and_transformations.status === :available
        # 除外日付が本文に反映される
        @test any(
            occursin("除外", c.text) for c in out.measurement_and_transformations.claims
        )
        assert_claims_resolve(out, kctx)
    end

    # ---- Case 推定未収束 -------------------------------------------------
    @testset "推定未収束: calibration insufficient_evidence" begin
        cal2 = reconstruct(base_kctx.calibration; converged = false)
        w = ExplanationWarning(;
            code = "CALIBRATION_NOT_CONVERGED",
            severity = :error,
            message = "採用した推定解が収束していません。",
            affected_source_ids = copy(base_kctx.calibration.source_ids),
            affected_sections = ["calibration_interpretation"],
        )
        kctx = with_ctx(base_kctx; calibration = cal2, warnings = [w])
        out = explain_keen_empirical_result(build_actx(kctx))
        @test out.calibration_interpretation.status === :insufficient_evidence
        @test any(occursin("未収束", c.text) for c in out.calibration_interpretation.claims)
        @test !isempty(out.calibration_interpretation.missing_fields)
        # executive_summary が flagged section を報告する
        @test any(
            occursin("calibration_interpretation", c.text) for
            c in out.executive_summary.claims
        )
        assert_claims_resolve(out, kctx)
    end

    # ---- Case OOS 悪化 ---------------------------------------------------
    @testset "OOS 悪化: validation available だが qualifier で限定" begin
        val2 = reconstruct(base_kctx.validation; calibrated_worse_than_literature = true)
        w = ExplanationWarning(;
            code = "OOS_WORSE_THAN_LITERATURE",
            severity = :warning,
            message = "calibrated の集計 RMSE が literature より大きい。",
            affected_source_ids = copy(base_kctx.validation.source_ids),
            affected_sections = ["validation_assessment"],
        )
        kctx = with_ctx(base_kctx; validation = val2, warnings = [w])
        out = explain_keen_empirical_result(build_actx(kctx))
        # warning は insufficient にはしないが、肯定的結論を避ける qualifier を付ける
        @test out.validation_assessment.status === :available
        @test any(
            any(occursin("OOS_WORSE_THAN_LITERATURE", q) for q in c.qualifiers) for
            c in out.validation_assessment.claims
        )
        @test any(occursin("悪化: true", c.text) for c in out.validation_assessment.claims)
        assert_claims_resolve(out, kctx)
    end

    # ---- Case regime 不一致 ----------------------------------------------
    @testset "regime 不一致: observed proxy を endogenous と呼ばない" begin
        w = ExplanationWarning(;
            code = "REGIME_MISMATCH",
            severity = :warning,
            message = "observed proxy と calibrated model の到達 regime が不一致。",
            affected_source_ids = ["regime.observed-proxy", "regime.calibrated-model"],
            affected_sections = ["regime_assessment"],
        )
        kctx = with_ctx(base_kctx; warnings = [w])
        out = explain_keen_empirical_result(build_actx(kctx))
        @test out.regime_assessment.status === :available
        obs_claim = only(
            filter(
                c -> occursin("observed_proxy", c.claim_id),
                out.regime_assessment.claims,
            ),
        )
        @test any(
            occursin("endogenous", q) || occursin("企業別実測", q) for
            q in obs_claim.qualifiers
        )
        @test any(
            any(occursin("REGIME_MISMATCH", q) for q in c.qualifiers) for
            c in out.regime_assessment.claims
        )
        assert_claims_resolve(out, kctx)
    end

    # ---- Case 感応度不安定 -----------------------------------------------
    @testset "感応度不安定: sensitivity insufficient_evidence" begin
        @test !isempty(base_kctx.sensitivity)
        sens = copy(base_kctx.sensitivity)
        # base 以外の 1 シナリオを unstable に差し替える
        idx = findfirst(s -> s.robustness_status !== :base, sens)
        idx = idx === nothing ? 1 : idx
        sens[idx] =
            reconstruct(sens[idx]; robustness_status = :unstable, sign_reversal = true)
        w = ExplanationWarning(;
            code = "SENSITIVITY_UNSTABLE",
            severity = :warning,
            message = "感応度シナリオ間で符号反転があります。",
            affected_sections = ["sensitivity_and_robustness"],
        )
        kctx = with_ctx(base_kctx; sensitivity = sens, warnings = [w])
        out = explain_keen_empirical_result(build_actx(kctx))
        @test out.sensitivity_and_robustness.status === :insufficient_evidence
        @test "robustness_unstable" in out.sensitivity_and_robustness.missing_fields
        assert_claims_resolve(out, kctx)
    end

    # ---- Case MODEL_DIVERGED（実経路で誘発）------------------------------
    @testset "MODEL_DIVERGED: validation insufficient_evidence" begin
        ds = synth_dataset(m; n = 40)
        cfg = keen_default_validation_config(ds; guard_max = 0.4)
        res = validate_keen(ds, cfg)
        kctx = KeenEmpiricalContext(ds, res)
        @test "MODEL_DIVERGED" in Set(w.code for w in kctx.warnings)
        out = explain_keen_empirical_result(build_actx(kctx))
        @test out.validation_assessment.status === :insufficient_evidence
        @test any(occursin("発散", c.text) for c in out.validation_assessment.claims)
        assert_claims_resolve(out, kctx)
    end

    # ---- parser 検証（ADR 0005 §7.1）------------------------------------
    @testset "parser: 不正 JSON / 未登録 source / 整合性" begin
        out = explain_keen_empirical_result(build_actx(base_kctx))
        good = to_dict(out)
        good["generation_status"] = "parsed"
        good_json = DME.JSON3.write(good)

        # 正常 JSON は :parsed
        p = parse_keen_empirical_response(good_json, base_kctx)
        @test p !== nothing
        @test p.generation_status === :parsed

        # 不正 JSON（code fence 前置き含む）は nothing
        @test parse_keen_empirical_response("```json\n{}\n```", base_kctx) === nothing
        @test parse_keen_empirical_response("not json", base_kctx) === nothing

        # 必須 section 欠落は nothing
        miss = copy(good)
        delete!(miss, "validation_assessment")
        @test parse_keen_empirical_response(DME.JSON3.write(miss), base_kctx) === nothing

        # contract_version 不一致は nothing
        badv = copy(good)
        badv["contract_version"] = "keen-ai-output/9.9.9"
        @test parse_keen_empirical_response(DME.JSON3.write(badv), base_kctx) === nothing

        # 未登録 source_id は nothing
        badsrc = deepcopy(good)
        badsrc["observed_evidence"]["claims"] = Any[Dict(
            "claim_id" => "x",
            "text" => "t",
            "epistemic_status" => "observed",
            "source_ids" => ["nonexistent.id"],
            "qualifiers" => String[],
        )]
        @test parse_keen_empirical_response(DME.JSON3.write(badsrc), base_kctx) === nothing

        # category と epistemic_status の不整合は nothing
        obs_id = base_kctx.observed_data[1].source_ids[1]
        badstatus = deepcopy(good)
        badstatus["observed_evidence"]["claims"] = Any[Dict(
            "claim_id" => "x",
            "text" => "t",
            "epistemic_status" => "estimated",  # observed_data source に対して estimated
            "source_ids" => [obs_id],
            "qualifiers" => String[],
        )]
        @test parse_keen_empirical_response(DME.JSON3.write(badstatus), base_kctx) ===
              nothing
    end

    # ---- provider 経路（mock は非 JSON → fallback）-----------------------
    @testset "provider 経路: fallback と blocking" begin
        actx = build_actx(base_kctx)
        outf = explain_keen_empirical_result(actx; provider = MockLLMProvider())
        @test outf.generation_status === :fallback
        @test any(w -> w.code == "OUTPUT_SCHEMA_INVALID", outf.warnings)
        # fallback でも全 section を返す
        @test outf.observed_evidence.status === :available

        # blocking warning があれば provider を呼ばず fallback
        wb = ExplanationWarning(;
            code = "CONTEXT_SCHEMA_INVALID",
            severity = :blocking,
            message = "context schema invalid",
        )
        kctx = with_ctx(base_kctx; warnings = [wb])
        outb = explain_keen_empirical_result(build_actx(kctx); provider = MockLLMProvider())
        @test outb.generation_status === :fallback
    end

    # ---- keen_empirical が無い場合は ArgumentError -----------------------
    @testset "keen_empirical なし: ArgumentError" begin
        rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
        sr = to_simulation_result(rbc, impulse_response(rbc, 0.01), "tech")
        actx = AnalysisContext(rbc, sr)
        @test_throws ArgumentError explain_keen_empirical_result(actx)
        @test_throws ArgumentError build_keen_empirical_prompt(actx)
    end

    # ---- 既存 API の回帰防止 ---------------------------------------------
    @testset "回帰: explain_result / explain_data_comparison" begin
        rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
        sr = to_simulation_result(rbc, impulse_response(rbc, 0.01), "technology_shock")
        ctx = AnalysisContext(rbc, sr; shock_description = "1% tech shock")
        er = explain_result(ctx)
        @test er isa ExplainResultOutput
        @test occursin("投資判断", er.disclaimer)

        dcs = DataComparisonSummary(
            "FRED/GDPC1",
            (1, 20),
            Dict{String, Any}("rmse_by_variable" => Dict("Y" => 0.1)),
            String["改訂に注意"],
        )
        ctx2 = AnalysisContext(rbc, sr; data_comparison_summary = dcs)
        dc = explain_data_comparison(ctx2)
        @test dc isa ExplainDataComparisonOutput
        @test occursin("投資判断", dc.disclaimer)
    end
end
