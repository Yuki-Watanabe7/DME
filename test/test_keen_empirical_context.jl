@testset "Keen 実証 AnalysisContext 拡張（ADR 0005 §3）" begin
    lit = KEEN_LITERATURE_PARAMS

    # ---- ヘルパー（test_keen_validation.jl と同じ合成手順）------------------
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
            # 一部欠損ケース: source 系列にいくつか missing を混ぜ、共通期間から除外させる
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

    m = KeenModel(lit.α, lit.β, lit.δ, lit.ν, lit.r, 0.05, 8.0e-5, -0.005, 0.007, lit.κ2)

    # 全 claim の source_ids が registry に存在することを確認する
    function assert_sources_resolve(kctx)
        ids = keys(kctx.sources)
        for o in kctx.observed_data
            for id in o.source_ids
                @test id in ids
            end
        end
        kctx.calibration === nothing || for id in kctx.calibration.source_ids
            @test id in ids
        end
        kctx.validation === nothing || for id in kctx.validation.source_ids
            @test id in ids
        end
        for r in kctx.regime_diagnostics, id in r.source_ids
            @test id in ids
        end
        for s in kctx.sensitivity, id in s.source_ids
            @test id in ids
        end
        for l in kctx.limitations, id in l.source_ids
            @test id in ids
        end
        for w in kctx.warnings, id in w.affected_source_ids
            @test id in ids
        end
    end

    # ---- Case 1: 実データあり（収束・全 section available）------------------
    @testset "Case 1: データあり（全 section）" begin
        ds = synth_dataset(m; n = 40)
        cfg = keen_default_validation_config(ds)
        res = validate_keen(ds, cfg)
        kctx = KeenEmpiricalContext(ds, res; mode = :fixture)

        @test kctx.contract_version == KEEN_AI_CONTEXT_CONTRACT_VERSION
        @test kctx.prompt_version == KEEN_AI_PROMPT_VERSION
        # observed / measurement / calibration / model_outputs / validation / regime / sensitivity
        @test length(kctx.observed_data) == 4
        @test kctx.measurement !== nothing
        @test kctx.calibration !== nothing
        @test kctx.calibration.converged
        @test length(kctx.model_outputs) == 2
        @test kctx.validation !== nothing
        @test !isempty(kctx.validation.evaluations)
        @test Set(r.subject for r in kctx.regime_diagnostics) ==
              Set([:observed_proxy, :literature_model, :calibrated_model])
        @test length(kctx.sensitivity) == length(res.sensitivity)
        @test any(s -> s.robustness_status === :base, kctx.sensitivity)
        @test !isempty(kctx.limitations)
        assert_sources_resolve(kctx)

        # category が型と一致して識別可能
        @test all(
            kctx.sources[id].category === :observed_data for o in kctx.observed_data for
            id in o.source_ids
        )
        @test all(
            kctx.sources[id].category === :calibration for id in kctx.calibration.source_ids
        )
        @test all(
            kctx.sources[id].category === :diagnostic_proxy for r in
                                                                kctx.regime_diagnostics for
            id in r.source_ids
        )
    end

    # ---- Case 2: 一部欠損 -------------------------------------------------
    @testset "Case 2: 一部欠損（dropped_dates を保持）" begin
        ds = synth_dataset(m; n = 40, drop_missing = true)
        cfg = keen_default_validation_config(ds)
        res = validate_keen(ds, cfg)
        kctx = KeenEmpiricalContext(ds, res; mode = :fixture)

        @test kctx.measurement !== nothing
        @test !isempty(kctx.measurement.dropped_dates)
        # 欠損は quality/provenance に記録され、採用系列そのものは有限
        @test all(
            v === nothing || isfinite(v) for o in kctx.observed_data for v in o.values
        )
        assert_sources_resolve(kctx)
        # JSON 化で NaN/Inf が現れない
        rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
        sr = to_simulation_result(rbc, impulse_response(rbc, 0.01), "tech")
        js = to_json(AnalysisContext(rbc, sr; keen_empirical = kctx))
        @test !occursin("NaN", js) && !occursin("Inf", js)
    end

    # ---- Case 3: simulation only（keen_empirical を付けない）--------------
    @testset "Case 3: simulation only（後方互換）" begin
        rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
        irf = impulse_response(rbc, 0.01)
        sr = to_simulation_result(rbc, irf, "technology_shock")
        actx = AnalysisContext(rbc, sr)
        @test actx.keen_empirical === nothing
        d = to_dict(actx)
        @test !haskey(d, "keen_empirical")
        @test !haskey(to_compact_dict(actx), "keen_empirical")
    end

    # ---- 警告生成（発散を guard_max で誘発）--------------------------------
    @testset "警告: MODEL_DIVERGED / 標準 code へ写像" begin
        ds = synth_dataset(m; n = 40)
        # guard_max を状態スケール未満にして予測 trajectory を発散扱いにする
        cfg = keen_default_validation_config(ds; guard_max = 0.4)
        res = validate_keen(ds, cfg)
        kctx = KeenEmpiricalContext(ds, res)

        codes = Set(w.code for w in kctx.warnings)
        @test "MODEL_DIVERGED" in codes
        # MODEL_DIVERGED は error severity
        for w in kctx.warnings
            w.code == "MODEL_DIVERGED" && @test w.severity === :error
        end
        # 発散は model_outputs にも反映
        @test any(mo -> mo.diverged, kctx.model_outputs)
        assert_sources_resolve(kctx)
    end

    # ---- JSON 直列化と compact -------------------------------------------
    @testset "to_dict / to_json / to_compact_dict" begin
        ds = synth_dataset(m; n = 40)
        cfg = keen_default_validation_config(ds)
        res = validate_keen(ds, cfg)
        kctx = KeenEmpiricalContext(ds, res; mode = :fixture)

        rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
        sr = to_simulation_result(rbc, impulse_response(rbc, 0.01), "tech")
        actx = AnalysisContext(rbc, sr; keen_empirical = kctx)

        d = to_dict(actx)
        @test haskey(d, "keen_empirical")
        ked = d["keen_empirical"]
        @test ked["contract_version"] == KEEN_AI_CONTEXT_CONTRACT_VERSION
        @test haskey(ked, "sources") && !isempty(ked["sources"])
        # 意味的内容の検証（キー順ではなく）
        @test ked["analysis_scope"]["country"] == "TEST"
        @test length(ked["observed_data"]) == 4
        @test ked["calibration"]["converged"] == true

        js = to_json(actx)
        @test occursin("keen_empirical", js)
        @test occursin("keen-ai-context/1.0.0", js)
        @test !occursin("NaN", js) && !occursin("Inf", js)

        cd = to_compact_dict(actx)
        @test haskey(cd, "keen_empirical")
        # compact は observed 系列の生配列を落とす
        @test !haskey(cd["keen_empirical"]["observed_data"][1], "values")
        @test !haskey(cd["keen_empirical"]["observed_data"][1], "dates")
        # 通常 dict は保持する
        @test haskey(d["keen_empirical"]["observed_data"][1], "values")
    end

    # ---- 型・source registry の契約 --------------------------------------
    @testset "EvidenceSource / ExplanationWarning の契約検証" begin
        # id 形式検証
        @test_throws ArgumentError EvidenceSource(;
            id = "Bad ID",
            category = :observed_data,
            context_path = "/x",
            label = "x",
        )
        # category 語彙検証
        @test_throws ArgumentError EvidenceSource(;
            id = "ok.id",
            category = :unknown_cat,
            context_path = "/x",
            label = "x",
        )
        s = EvidenceSource(;
            id = "obs.omega",
            category = :observed_data,
            context_path = "/dataset/series/omega",
            label = "ω",
            provider = "FRED",
        )
        sd = to_dict(s)
        @test sd["id"] == "obs.omega"
        @test sd["category"] == "observed_data"
        @test sd["provider"] == "FRED"
        @test !haskey(sd, "series_id")  # nothing は省略

        # severity 語彙検証
        @test_throws ArgumentError ExplanationWarning(;
            code = "X",
            severity = :fatal,
            message = "m",
        )
        w = ExplanationWarning(;
            code = "MODEL_DIVERGED",
            severity = :error,
            message = "diverged",
            affected_sections = ["validation_assessment"],
        )
        @test to_dict(w)["severity"] == "error"
    end
end
