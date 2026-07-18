@testset "Keen 実証バリデーション・感応度分析" begin
    lit = KEEN_LITERATURE_PARAMS

    # ---- ヘルパー ---------------------------------------------------------

    # 既知モデルを Δt=0.25 の RK4 で前進し、四半期状態系列を生成する
    # （validate_keen の予測 substeps_per_year=4 = 1 step/quarter と整合し、
    #   真モデルの予測 trajectory が観測を厳密再現する）。
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

    # % 単位の MacroDataset → 実パイプラインで KeenEmpiricalDataset を構築
    function synth_dataset(m::KeenModel; n = 40, validation_split = 0.3)
        ωs, λs, ds = rk4_states(m; n = n)
        ql = ["$(2000 + (i - 1) ÷ 4)-Q$(((i - 1) % 4) + 1)" for i in 1:n]
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
                mk("OMEGA", "Percent", ωs .* 100),
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

    # KeenEmpiricalDataset を直接構築（regime timing 等、観測系列を制御したいとき）
    function direct_eds(ω, λ, d; r = 0.05, calib = nothing, valid = nothing)
        n = length(ω)
        dates = ["$(2000 + (i - 1) ÷ 4)-Q$(((i - 1) % 4) + 1)" for i in 1:n]
        ot = [0.25 * (i - 1) for i in 1:n]
        ci = calib === nothing ? collect(1:n) : calib
        vi = valid === nothing ? Int[] : valid
        cfg = keen_us_default_config()
        src = MacroDataset("empty", DataSeries[])
        KeenEmpiricalDataset(
            cfg,
            dates,
            ot,
            collect(float.(ω)),
            collect(float.(λ)),
            collect(float.(d)),
            fill(float(r), n),
            (ω0 = ω[1], λ0 = λ[1], d0 = d[1]),
            r,
            ci,
            vi,
            Dict{Symbol, KeenSeriesProvenance}(),
            String[],
            Dict{String, Any}(),
            src,
            Dict{String, Any}(
                "sample_start" => dates[1],
                "sample_end" => dates[end],
                "mode" => :provided,
                "vintage" => "revised",
            ),
        )
    end

    # 真パラメータ（literature とは異なる → calibrated が literature を改善できる設定）
    m_true =
        KeenModel(lit.α, lit.β, lit.δ, lit.ν, lit.r, 0.05, 8.0e-5, -0.005, 0.007, lit.κ2)

    # ---- metric ヘルパーの境界ケース -------------------------------------
    @testset "変数別 metric の境界ケース" begin
        # 単調一致: rmse=0・方向一致率1・転換点0
        p = [1.0, 2.0, 3.0, 4.0]
        o = [1.0, 2.0, 3.0, 4.0]
        mt = DME._keen_variable_metrics(p, o, :d)
        @test mt.n_pairs == 4
        @test mt.rmse == 0.0
        @test mt.direction_accuracy == 1.0
        @test mt.n_direction_pairs == 3
        @test mt.turning_points_observed == 0
        @test mt.turning_points_predicted == 0
        @test mt.turning_point_timing_error === nothing

        # ジグザグ: 内部各点が転換点
        z = [1.0, 2.0, 1.0, 2.0, 1.0]
        mz = DME._keen_variable_metrics(z, z, :ω)
        @test mz.turning_points_observed == 3
        @test mz.turning_points_predicted == 3
        @test mz.turning_point_timing_error == 0.0

        # 発散後 NaN を 0 として扱わない（有効ペアのみで計算）
        pn = [1.0, 2.0, NaN, NaN]
        on = [1.0, 2.0, 3.0, 4.0]
        mn = DME._keen_variable_metrics(pn, on, :d)
        @test mn.n_pairs == 2
        @test mn.rmse == 0.0            # 0埋めなら大きな誤差になるはず
        @test mn.n_direction_pairs == 1 # (1,2)のみ、NaN絡みは除外
        @test mn.direction_accuracy == 1.0

        # 逆方向: 方向一致率0
        mr = DME._keen_variable_metrics([1.0, 2.0, 3.0], [3.0, 2.0, 1.0], :λ)
        @test mr.direction_accuracy == 0.0

        # 観測分散0 → 標準化 metric は NaN、相関も NaN
        mc = DME._keen_variable_metrics([1.0, 1.0, 1.0], [2.0, 2.0, 2.0], :d)
        @test isnan(mc.rmse_standardized)
        @test isnan(mc.correlation)
        @test mc.rmse == 1.0

        # 有効ペア0
        m0 = DME._keen_variable_metrics([NaN, NaN], [1.0, 2.0], :d)
        @test m0.n_pairs == 0
        @test isnan(m0.rmse)
        @test m0.turning_point_timing_error === nothing
    end

    # ---- config バリデーション -------------------------------------------
    @testset "KeenValidationConfig の契約" begin
        eds = synth_dataset(m_true; n = 24)
        cal = keen_default_calibration_config(eds)
        @test KeenValidationConfig(; calibration_config = cal) isa KeenValidationConfig
        @test_throws ArgumentError KeenValidationConfig(;
            calibration_config = cal,
            comparison_models = Symbol[],
        )
        @test_throws ArgumentError KeenValidationConfig(;
            calibration_config = cal,
            initial_state_modes = [:bad],
        )
        @test_throws ArgumentError KeenValidationConfig(;
            calibration_config = cal,
            eval_variables = [:x],
        )
        @test_throws ArgumentError KeenValidationConfig(;
            calibration_config = cal,
            metrics = [:unknown],
        )
        @test_throws ArgumentError KeenValidationConfig(;
            calibration_config = cal,
            substeps_per_year = 0,
        )
        @test_throws ArgumentError KeenSensitivityScenario(; name = "x", kind = :nope)
    end

    # ---- split の重複・look-ahead が無い ---------------------------------
    @testset "calibration/validation split に重複・look-ahead が無い" begin
        eds = synth_dataset(m_true; n = 40, validation_split = 0.3)
        vcfg = keen_default_validation_config(
            eds;
            calibration_config = keen_default_calibration_config(eds; n_starts = 2),
        )
        res = validate_keen(eds, vcfg)
        si = res.split_info
        @test si["no_overlap"] == true
        @test isempty(
            intersect(Set(si["calibration_indices"]), Set(si["validation_indices"])),
        )
        # calibration は validation より時間的に前
        @test maximum(si["calibration_indices"]) < minimum(si["validation_indices"])
        @test si["n_calibration"] + si["n_validation"] == si["n_obs_total"]
    end

    # ---- 正しいモデルが誤指定より良い metric ------------------------------
    @testset "synthetic: calibrated が literature を改善する" begin
        eds = synth_dataset(m_true; n = 40, validation_split = 0.3)
        vcfg = keen_default_validation_config(
            eds;
            calibration_config = keen_default_calibration_config(eds; n_starts = 4),
        )
        res = validate_keen(eds, vcfg)
        lit_rmse = res.metadata["aggregate_rmse_literature"]
        cal_rmse = res.metadata["aggregate_rmse_calibrated"]
        @test isfinite(lit_rmse) && isfinite(cal_rmse)
        # 真モデルは literature と異なる → calibrated が改善する
        @test cal_rmse < lit_rmse
        @test res.calibrated_worse_than_literature == false
    end

    # ---- literature/calibrated が同一契約で返る ---------------------------
    @testset "literature/calibrated が同一契約・両期間で返る" begin
        eds = synth_dataset(m_true; n = 32, validation_split = 0.3)
        vcfg = keen_default_validation_config(
            eds;
            calibration_config = keen_default_calibration_config(eds; n_starts = 2),
        )
        res = validate_keen(eds, vcfg)
        for label in (:literature, :calibrated)
            for period in (:in_sample, :out_of_sample)
                evs = filter(
                    e -> e.model_label == label && e.period == period,
                    res.evaluations,
                )
                @test !isempty(evs)
                for e in evs
                    @test Set(keys(e.metrics)) == Set([:ω, :λ, :d])
                end
            end
        end
        # validation は初期値方式ごとに別 metric として区別される
        oos = filter(
            e -> e.model_label == :calibrated && e.period == :out_of_sample,
            res.evaluations,
        )
        modes = Set(e.initial_state_mode for e in oos)
        @test modes == Set([:observed_start, :calibration_continued])
    end

    # ---- amortization 変更で推定は不変・診断だけ変わる --------------------
    @testset "amortization 変更で ODE/推定不変・診断のみ変化" begin
        eds = synth_dataset(m_true; n = 32, validation_split = 0.3)
        base_cal = keen_default_calibration_config(eds; n_starts = 2)

        # 感応度シナリオ内の amortization 3 値は base 推定を再利用（推定不変）
        vcfg = keen_default_validation_config(eds; calibration_config = base_cal)
        res = validate_keen(eds, vcfg)
        base_res = res.sensitivity[1]
        @test base_res.scenario.name == "base"
        amorts = filter(s -> s.scenario.kind == :amortization_rate, res.sensitivity)
        @test length(amorts) == 3
        for s in amorts
            @test s.reused_base_calibration == true
            @test s.estimated == base_res.estimated
            @test s.objective_value == base_res.objective_value
            @test s.fit_rmse == base_res.fit_rmse
        end

        # 観測 proxy regime: amortization を変えると hedge/speculative 境界が動く
        # （interest のみに依存する ponzi 境界は不変）。ω=0.7, r=0.05 で
        #   hedge: 0.3 ≥ (r+a)d, speculative: rd ≤ 0.3 < (r+a)d, ponzi: 0.3 < rd
        n = 12
        ω = fill(0.7, n)
        λ = fill(0.9, n)
        d = Float64[min(i, 8) for i in 1:n]
        de = direct_eds(ω, λ, d; r = 0.05, calib = collect(1:9), valid = collect(10:12))

        function first_spec(amort)
            rc = FinancingRegimeConfig(; amortization_rate = amort)
            vc = keen_default_validation_config(
                de;
                calibration_config = keen_default_calibration_config(de; n_starts = 1),
                regime_config = rc,
            )
            r = validate_keen(de, vc)
            (
                r.regime_comparison.observed_summary.first_speculative_time,
                r.sensitivity[1].estimated,
            )
        end
        fs_low, est_low = first_spec(0.05)   # hedge: d≤3 → first spec at d=4 (idx4)
        fs_high, est_high = first_spec(0.20) # hedge: d≤1.2 → first spec at d=2 (idx2)
        @test fs_low == 4
        @test fs_high == 2
        # ODE/推定は amortization に依存しない
        @test est_low == est_high
    end

    # ---- 感応度シナリオの設定と結果が対応する ----------------------------
    @testset "感応度シナリオの設定と結果が対応する" begin
        eds = synth_dataset(m_true; n = 32, validation_split = 0.3)
        base_cal = keen_default_calibration_config(eds; n_starts = 2)

        # dataset override シナリオ（標本期間短縮）を追加
        eds_short = synth_dataset(m_true; n = 24, validation_split = 0.3)
        scen = KeenSensitivityScenario(;
            name = "calibration_sample=short",
            kind = :calibration_sample,
            dataset = eds_short,
            note = "標本を短縮した dataset で再推定",
        )
        vcfg = keen_default_validation_config(eds; calibration_config = base_cal)
        scenarios = vcat(vcfg.sensitivity_scenarios, [scen])
        vcfg2 = KeenValidationConfig(;
            calibration_config = base_cal,
            sensitivity_scenarios = scenarios,
        )
        res = validate_keen(eds, vcfg2)

        names = [s.scenario.name for s in res.sensitivity]
        @test "base" in names
        @test "rate_method=real_proxy" in names
        @test "variable_weight=none" in names
        @test "calibration_sample=short" in names
        # dataset override シナリオは base 推定を再利用しない
        short = first(
            s for s in res.sensitivity if s.scenario.name == "calibration_sample=short"
        )
        @test short.reused_base_calibration == false
        # rate_method は r を変えて再推定 → base とは異なる推定になりうる
        rate = first(s for s in res.sensitivity if s.scenario.kind == :rate_method)
        @test rate.reused_base_calibration == false
        @test haskey(rate.fit_rmse, :d)
    end

    # ---- observed regime transition の時点が正しい ------------------------
    @testset "observed proxy regime の遷移時点" begin
        # ω=0.7, r=0.05, amort=0.05 → hedge:d≤3, spec:3<d≤6, ponzi:d>6
        n = 10
        ω = fill(0.7, n)
        λ = fill(0.9, n)
        d = Float64[i for i in 1:n]  # 1..10
        de = direct_eds(ω, λ, d; r = 0.05)
        vc = keen_default_validation_config(
            de;
            calibration_config = keen_default_calibration_config(de; n_starts = 1),
        )
        res = validate_keen(de, vc)
        os = res.regime_comparison.observed_summary
        @test os.first_speculative_time == 4  # 最初に d>3 になる index
        @test os.first_ponzi_time == 7        # 最初に d>6 になる index
        @test os.peak_debt_ratio == 10.0
    end

    # ---- 決定性 ----------------------------------------------------------
    @testset "同一設定で決定的" begin
        eds = synth_dataset(m_true; n = 32, validation_split = 0.3)
        vcfg = keen_default_validation_config(
            eds;
            calibration_config = keen_default_calibration_config(eds; n_starts = 3),
        )
        r1 = validate_keen(eds, vcfg)
        r2 = validate_keen(eds, vcfg)
        @test r1.sensitivity[1].estimated == r2.sensitivity[1].estimated
        for (e1, e2) in zip(r1.evaluations, r2.evaluations)
            for v in (:ω, :λ, :d)
                a = e1.metrics[v].rmse
                b = e2.metrics[v].rmse
                @test (isnan(a) && isnan(b)) || a == b
            end
        end
        @test r1.warnings == r2.warnings
    end

    # ---- validation 無し（split=0）でも in-sample のみで動く --------------
    @testset "validation 空でも in-sample 評価は返る" begin
        eds = synth_dataset(m_true; n = 20, validation_split = 0.0)
        vcfg = keen_default_validation_config(
            eds;
            calibration_config = keen_default_calibration_config(eds; n_starts = 1),
        )
        res = validate_keen(eds, vcfg)
        @test any(e -> e.period == :in_sample, res.evaluations)
        @test !any(e -> e.period == :out_of_sample, res.evaluations)
        @test any(w -> occursin("validation_indices が空", w), res.warnings)
    end

    # ---- JSON 保存 -------------------------------------------------------
    @testset "keen_validation_to_dict / save_keen_validation" begin
        eds = synth_dataset(m_true; n = 24, validation_split = 0.3)
        vcfg = keen_default_validation_config(
            eds;
            calibration_config = keen_default_calibration_config(eds; n_starts = 2),
        )
        res = validate_keen(eds, vcfg)
        d = keen_validation_to_dict(res)
        @test haskey(d, "evaluations")
        @test haskey(d, "regime_comparison")
        @test haskey(d, "sensitivity")
        @test haskey(d, "split_info")
        @test !isempty(d["caveats"])
        path = tempname() * ".json"
        save_keen_validation(path, res)
        @test isfile(path)
        @test filesize(path) > 0
        rm(path; force = true)
    end
end
