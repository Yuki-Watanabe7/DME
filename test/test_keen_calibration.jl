@testset "Keen 限定キャリブレーション" begin
    keen_fixture_dir = joinpath(@__DIR__, "fixtures", "keen")
    lit = KEEN_LITERATURE_PARAMS

    # ---- ヘルパー ---------------------------------------------------------

    # 既知モデルを Δt=0.25 で explicit Euler 前進し、四半期状態系列を生成する。
    # forward-difference 残差は真パラメータで厳密に 0 になる（keen_rhs と一致）。
    function euler_states(m::KeenModel; n = 40, ωf = 0.98, λf = 0.995, df = 1.03)
        ss = DME.steady_state(m)
        ω, λ, d = ss.ω * ωf, ss.λ * λf, ss.d * df
        ωs, λs, ds = Float64[], Float64[], Float64[]
        for _ in 1:n
            push!(ωs, ω)
            push!(λs, λ)
            push!(ds, d)
            dω, dλ, dd = DME.keen_rhs(m, ω, λ, d)
            ω += 0.25 * dω
            λ += 0.25 * dλ
            d += 0.25 * dd
        end
        (ωs, λs, ds)
    end

    # % 単位の MacroDataset（全四半期）→ 実パイプラインで KeenEmpiricalDataset を構築
    function synth_dataset(m::KeenModel; n = 40, validation_split = 0.0, ωvals = nothing)
        ωs, λs, ds = euler_states(m; n = n)
        ωs = ωvals === nothing ? ωs : ωvals
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
                mk("LAMBDA", "Percent", (1 .- λs) .* 100),  # UNRATE% = 100(1-λ)
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

    # KeenEmpiricalDataset を直接構築する最小ヘルパ（発散/非有限の混入テスト用）
    function direct_eds(ω, λ, d, r; r_param = 0.03, obs_times = nothing)
        n = length(ω)
        dates = ["$(2000 + (i - 1) ÷ 4)-Q$(((i - 1) % 4) + 1)" for i in 1:n]
        ot = obs_times === nothing ? [0.25 * (i - 1) for i in 1:n] : obs_times
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
            r_param,
            collect(1:n),
            Int[],
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

    m_true =
        KeenModel(lit.α, lit.β, lit.δ, lit.ν, lit.r, lit.φ0, lit.φ1, lit.κ0, lit.κ1, lit.κ2)

    # ---- synthetic recovery ----------------------------------------------
    @testset "synthetic data から限定パラメータを回収" begin
        eds = synth_dataset(m_true; n = 40)
        cfg = keen_default_calibration_config(eds; n_starts = 4)
        res = calibrate_keen(eds, cfg)
        @test res.converged
        @test res.objective_value < 1e-10
        for p in cfg.estimated_params
            @test isapprox(res.estimated[p], getproperty(lit, p); rtol = 1e-4, atol = 1e-8)
        end
        @test res.n_obs_used > 0
        @test res.standard_errors_supported == false
    end

    # ---- 固定パラメータが推定中に変更されない -----------------------------
    @testset "固定パラメータは推定で不変" begin
        eds = synth_dataset(m_true; n = 32)
        cfg = keen_default_calibration_config(eds)
        res = calibrate_keen(eds, cfg)
        @test res.fixed == cfg.fixed_params
        @test res.model.α == cfg.fixed_params[:α]
        @test res.model.β == cfg.fixed_params[:β]
        @test res.model.δ == cfg.fixed_params[:δ]
        @test res.model.ν == cfg.fixed_params[:ν]
        @test res.model.r == cfg.fixed_params[:r]
        @test res.model.κ2 == cfg.fixed_params[:κ2]  # κ2 は固定（推定対象外）
        # 推定対象は model に反映される
        @test res.model.φ0 == res.estimated[:φ0]
        @test res.model.κ1 == res.estimated[:κ1]
    end

    # ---- bounds / 符号制約 / 不正 initial guess ---------------------------
    @testset "bounds・符号制約・不正 initial guess が契約どおり" begin
        eds = synth_dataset(m_true; n = 16)
        fixed = Dict{Symbol, Float64}(
            :α => lit.α,
            :β => lit.β,
            :δ => lit.δ,
            :ν => lit.ν,
            :r => eds.r_param,
            :κ2 => lit.κ2,
        )
        base(; kw...) = KeenCalibrationConfig(;
            estimated_params = [:φ0, :φ1, :κ0, :κ1],
            fixed_params = fixed,
            bounds = Dict(
                :φ0 => (0.0, 0.5),
                :φ1 => (1e-8, 1e-2),
                :κ0 => (-0.5, 0.5),
                :κ1 => (1e-8, 0.5),
            ),
            initial_guess = Dict(:φ0 => 0.04, :φ1 => 6e-5, :κ0 => -0.006, :κ1 => 0.006),
            kw...,
        )
        @test base() isa KeenCalibrationConfig
        # lo >= hi
        @test_throws ArgumentError KeenCalibrationConfig(;
            estimated_params = [:φ1],
            fixed_params = merge(fixed, Dict(:φ0 => 0.04, :κ0 => -0.006, :κ1 => 0.006)),
            bounds = Dict(:φ1 => (1e-2, 1e-8)),
            initial_guess = Dict(:φ1 => 1e-4),
        )
        # φ1 は正値制約 → 下限 <= 0 は不可
        @test_throws ArgumentError KeenCalibrationConfig(;
            estimated_params = [:φ1],
            fixed_params = merge(fixed, Dict(:φ0 => 0.04, :κ0 => -0.006, :κ1 => 0.006)),
            bounds = Dict(:φ1 => (0.0, 1e-2)),
            initial_guess = Dict(:φ1 => 1e-4),
        )
        # initial guess が bounds 外
        @test_throws ArgumentError KeenCalibrationConfig(;
            estimated_params = [:φ0],
            fixed_params = merge(fixed, Dict(:φ1 => 6e-5, :κ0 => -0.006, :κ1 => 0.006)),
            bounds = Dict(:φ0 => (0.0, 0.5)),
            initial_guess = Dict(:φ0 => 1.0),
        )
        # 推定不可パラメータ
        @test_throws ArgumentError KeenCalibrationConfig(;
            estimated_params = [:α],
            fixed_params = fixed,
            bounds = Dict(:α => (0.0, 1.0)),
            initial_guess = Dict(:α => 0.02),
        )
        # 固定と推定の重複
        @test_throws ArgumentError KeenCalibrationConfig(;
            estimated_params = [:φ0],
            fixed_params = merge(
                fixed,
                Dict(:φ0 => 0.04, :φ1 => 6e-5, :κ0 => -0.006, :κ1 => 0.006),
            ),
            bounds = Dict(:φ0 => (0.0, 0.5)),
            initial_guess = Dict(:φ0 => 0.04),
        )
        # 固定にも推定にもない（網羅漏れ）
        @test_throws ArgumentError KeenCalibrationConfig(;
            estimated_params = [:φ0],
            fixed_params = fixed,  # φ1,κ0,κ1 が欠落
            bounds = Dict(:φ0 => (0.0, 0.5)),
            initial_guess = Dict(:φ0 => 0.04),
        )
    end

    # ---- 境界到達 warning -------------------------------------------------
    @testset "bounds へ張り付いた解が warning になる" begin
        eds = synth_dataset(m_true; n = 40)
        fixed = Dict{Symbol, Float64}(
            :α => lit.α,
            :β => lit.β,
            :δ => lit.δ,
            :ν => lit.ν,
            :r => eds.r_param,
            :κ2 => lit.κ2,
            :φ0 => lit.φ0,
            :φ1 => lit.φ1,
            :κ0 => lit.κ0,
        )
        # κ1 の最適は ~0.0067 だが上限を 1e-4 に絞る → 上限へ張り付く
        cfg = KeenCalibrationConfig(;
            estimated_params = [:κ1],
            fixed_params = fixed,
            bounds = Dict(:κ1 => (1e-8, 1e-4)),
            initial_guess = Dict(:κ1 => 5e-5),
            n_starts = 2,
        )
        res = calibrate_keen(eds, cfg)
        @test :κ1 in res.boundary_hits
    end

    # ---- 欠損・非連続・発散の除外 -----------------------------------------
    @testset "欠損四半期は非連続として除外される" begin
        ωs, λs, ds = euler_states(m_true; n = 24)
        ql = ["$(2000 + (i - 1) ÷ 4)-Q$(((i - 1) % 4) + 1)" for i in 1:24]
        ov = convert(Vector{Union{Float64, Missing}}, ωs .* 100)
        ov[10] = missing  # 中間四半期を欠損に
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
                mk("OMEGA", "Percent", ov),
                mk("LAMBDA", "Percent", (1 .- λs) .* 100),
                mk("DEBT", "Percent of GDP", ds .* 100),
                mk("RATE", "Percent", fill(m_true.r * 100, 24)),
            ],
        )
        dcfg = KeenEmpiricalDataConfig(;
            country = "TEST",
            omega = keen_us_default_config().omega,
            lambda = keen_us_default_config().lambda,
            debt = keen_us_default_config().debt,
            rate = keen_us_default_config().rate,
            min_valid_obs = 8,
            validation_split = 0.0,
        )
        # source_id を TEST 系列名へ差し替え
        dcfg = KeenEmpiricalDataConfig(;
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
            validation_split = 0.0,
        )
        eds = build_keen_empirical_dataset(dcfg, macro_ds)
        @test "2002-Q2" ∉ eds.dates  # index 10 = 2002-Q2 を欠損 → drop
        cfg = keen_default_calibration_config(eds; n_starts = 1)
        res = calibrate_keen(eds, cfg)
        # 欠損の前後で非連続ペアが 1 つ生じる
        @test res.excluded_reasons["non_contiguous"] >= 1
        @test res.n_obs_excluded >= 1
    end

    @testset "発散・非有限を含むペアは成功扱いにならない" begin
        ωs, λs, ds = euler_states(m_true; n = 24)
        # 非有限・状態域逸脱を離れた位置に混入（発散区間の模擬）
        ω = collect(ωs)
        λ = collect(λs)
        d = collect(ds)
        ω[6] = NaN     # 非有限
        λ[12] = 1.2    # 状態域逸脱（λ ≥ 1、近傍は有限）
        d[18] = Inf    # 非有限
        eds = direct_eds(ω, λ, d, m_true.r; r_param = m_true.r)
        cfg = keen_default_calibration_config(
            eds;
            n_starts = 1,
            use_calibration_split = false,
        )
        res = calibrate_keen(eds, cfg)
        @test res.n_obs_excluded >= 1
        @test res.excluded_reasons["non_finite"] >= 1
        @test res.excluded_reasons["out_of_domain"] >= 1
        # 除外後の有効ペアだけで有限の objective が得られる
        @test isfinite(res.objective_value)
    end

    # ---- multi-start と代替解 --------------------------------------------
    @testset "multi-start で最良解と全 start が追跡される" begin
        eds = synth_dataset(m_true; n = 36)
        cfg = keen_default_calibration_config(eds; n_starts = 5)
        res = calibrate_keen(eds, cfg)
        @test length(res.starts) == 5
        @test 1 <= res.adopted_start <= 5
        # 採用解は objective 最小
        @test res.objective_value ≈ minimum(st.objective_value for st in res.starts)
        @test res.starts[res.adopted_start].objective_value == res.objective_value
    end

    # ---- 決定性 -----------------------------------------------------------
    @testset "同一 dataset・seed・設定で決定的" begin
        eds = synth_dataset(m_true; n = 32)
        cfg = keen_default_calibration_config(eds; n_starts = 4, seed = 12345)
        a = calibrate_keen(eds, cfg)
        b = calibrate_keen(eds, cfg)
        @test a.estimated == b.estimated
        @test a.objective_value == b.objective_value
        @test a.adopted_start == b.adopted_start
        @test [s.objective_value for s in a.starts] == [s.objective_value for s in b.starts]
        @test [s.initial for s in a.starts] == [s.initial for s in b.starts]
    end

    # ---- literature 比較 --------------------------------------------------
    @testset "literature default との objective 差を取得できる" begin
        eds = synth_dataset(m_true; n = 36)
        cfg = keen_default_calibration_config(eds; n_starts = 3)
        res = calibrate_keen(eds, cfg)
        @test isfinite(res.literature_objective)
        @test haskey(res.literature_params, :φ0)
        # calibrated は literature 初期点から悪化しない（NM は単調非増加）
        @test res.objective_value <= res.literature_objective + 1e-12
    end

    # ---- 保存 → 読込 → 再実行 --------------------------------------------
    @testset "保存→読込→再実行で推定が一致" begin
        eds = synth_dataset(m_true; n = 32)
        cfg = keen_default_calibration_config(eds; n_starts = 3, seed = 777)
        res = calibrate_keen(eds, cfg)

        dir = mktempdir()
        cfg_path = joinpath(dir, "config.json")
        res_path = joinpath(dir, "result.json")
        save_keen_calibration_config(cfg_path, cfg)
        save_keen_calibration(res_path, res)
        @test isfile(cfg_path)
        @test isfile(res_path)

        # config ファイルから読み込み → 同じ fixture で再実行
        cfg2 = load_keen_calibration_config(cfg_path)
        res2 = calibrate_keen(eds, cfg2)
        @test res2.estimated == res.estimated
        @test res2.objective_value == res.objective_value

        # 結果ファイル（"config" キー配下）からも設定を復元できる
        cfg3 = load_keen_calibration_config(res_path)
        res3 = calibrate_keen(eds, cfg3)
        @test res3.estimated == res.estimated
    end

    @testset "config の dict roundtrip が一致" begin
        eds = synth_dataset(m_true; n = 16)
        cfg = keen_default_calibration_config(eds; n_starts = 2)
        d = keen_calibration_config_to_dict(cfg)
        cfg2 = keen_calibration_config_from_dict(d)
        @test cfg2.estimated_params == cfg.estimated_params
        @test cfg2.fixed_params == cfg.fixed_params
        @test cfg2.bounds == cfg.bounds
        @test cfg2.initial_guess == cfg.initial_guess
        @test cfg2.seed == cfg.seed
        @test cfg2.methodology_version == cfg.methodology_version
    end

    # ---- calibration split の尊重 ----------------------------------------
    @testset "use_calibration_split で validation を推定に使わない" begin
        eds = synth_dataset(m_true; n = 40, validation_split = 0.25)
        cfg_split = keen_default_calibration_config(eds; use_calibration_split = true)
        cfg_all = keen_default_calibration_config(eds; use_calibration_split = false)
        r_split = calibrate_keen(eds, cfg_split)
        r_all = calibrate_keen(eds, cfg_all)
        # calibration のみのペア数 < 全体
        @test r_split.n_obs_used < r_all.n_obs_used
    end

    # ---- fixture 経路（実データ契約） ------------------------------------
    @testset "fixture 経路で推定契約を満たす" begin
        client = FredClient(mode = :fixture, fixture_dir = keen_fixture_dir)
        eds = build_keen_empirical_dataset(keen_us_default_config(); client = client)
        cfg = keen_default_calibration_config(eds; n_starts = 3)
        res = calibrate_keen(eds, cfg)
        @test isfinite(res.objective_value)
        @test res.n_obs_used > 0
        @test res.methodology_version == KEEN_CALIBRATION_METHODOLOGY_VERSION
        @test res.dataset_metadata["measurement_version"] ==
              KEEN_EMPIRICAL_METHODOLOGY_VERSION
        @test haskey(res.dataset_metadata["series_ids"], "ω")
        @test res.standard_errors_supported == false
        @test occursin("未対応", res.metadata["standard_errors_note"])
        # 決定的
        res_b = calibrate_keen(eds, cfg)
        @test res.estimated == res_b.estimated
    end
end
