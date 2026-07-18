@testset "Keen 実証データセット" begin
    keen_fixture_dir = joinpath(@__DIR__, "fixtures", "keen")

    # ---- ヘルパー ---------------------------------------------------------
    function mk_series(id, freq, unit, dates, values; source = "TEST")
        DataSeries(
            id = id,
            name = id,
            source = source,
            frequency = freq,
            unit = unit,
            dates = dates,
            values = convert(Vector{Union{Float64, Missing}}, values),
        )
    end

    # 四半期ラベル生成
    qlabels(y0, y1) = ["$(y)-Q$(q)" for y in y0:y1 for q in 1:4]
    # 月次ラベル生成
    mlabels(y0, y1) = ["$(y)-$(lpad(m,2,'0'))" for y in y0:y1 for m in 1:12]

    # 既定に近い最小設定（min_valid_obs を下げてテストしやすくする）
    function mkcfg(;
        min_valid_obs = 8,
        validation_split = 0.3,
        r_mode = :sample_mean,
        omega_conv = :ratio_from_percent,
        omega_forbid = true,
        omega_lo = 0.0,
        omega_hi = 1.0,
        sample_start = nothing,
        sample_end = nothing,
    )
        KeenEmpiricalDataConfig(;
            country = "TEST",
            omega = KeenSeriesSpec(;
                variable = :ω,
                source_id = "OMEGA",
                conversion = omega_conv,
                aggregation = :mean,
                domain_lo = omega_lo,
                domain_hi = omega_hi,
                forbid_index = omega_forbid,
            ),
            lambda = KeenSeriesSpec(;
                variable = :λ,
                source_id = "LAMBDA",
                conversion = :employment_from_unrate,
                aggregation = :mean,
                domain_lo = 0.0,
                domain_hi = 1.0,
            ),
            debt = KeenSeriesSpec(;
                variable = :d,
                source_id = "DEBT",
                conversion = :ratio_from_percent,
                aggregation = :mean,
                domain_lo = 0.0,
                domain_hi = 100.0,
            ),
            rate = KeenSeriesSpec(;
                variable = :r,
                source_id = "RATE",
                conversion = :ratio_from_percent,
                aggregation = :mean,
                domain_lo = 0.0,
                domain_hi = 1.0,
            ),
            min_valid_obs = min_valid_obs,
            validation_split = validation_split,
            r_mode = r_mode,
            sample_start = sample_start,
            sample_end = sample_end,
        )
    end

    # ω, λ, d, r をすべて 2000-2003（16四半期）で用意した MacroDataset
    function full_dataset(; omega_unit = "Percent", omega_vals = nothing)
        ql = qlabels(2000, 2003)
        ml = mlabels(2000, 2003)
        ov = omega_vals === nothing ? fill(57.0, length(ql)) : omega_vals
        MacroDataset(
            "test",
            DataSeries[
                mk_series("OMEGA", Quarterly, omega_unit, ql, ov),
                mk_series("LAMBDA", Monthly, "Percent", ml, fill(5.0, length(ml))),
                mk_series("DEBT", Quarterly, "Percent of GDP", ql, fill(120.0, length(ql))),
                mk_series("RATE", Monthly, "Percent", ml, fill(4.0, length(ml))),
            ],
        )
    end

    # ---- 純粋関数の変換 ---------------------------------------------------
    @testset "観測方程式・単位変換が式どおり" begin
        sp_pct = KeenSeriesSpec(;
            variable = :d,
            source_id = "X",
            conversion = :ratio_from_percent,
            domain_lo = 0.0,
            domain_hi = 100.0,
        )
        @test keen_convert_value(sp_pct, 120.0) ≈ 1.2
        sp_emp = KeenSeriesSpec(;
            variable = :λ,
            source_id = "X",
            conversion = :employment_from_unrate,
            domain_lo = 0.0,
            domain_hi = 1.0,
        )
        @test keen_convert_value(sp_emp, 5.0) ≈ 0.95
        sp_id = KeenSeriesSpec(;
            variable = :ω,
            source_id = "X",
            conversion = :identity_ratio,
            domain_lo = 0.0,
            domain_hi = 1.0,
        )
        @test keen_convert_value(sp_id, 0.6) ≈ 0.6
        # missing / 非有限は変換も 0埋めもせず伝播
        @test ismissing(keen_convert_value(sp_pct, missing))
        @test !isfinite(keen_convert_value(sp_pct, NaN))
    end

    @testset "妥当域検証（clampしない）" begin
        sp = KeenSeriesSpec(;
            variable = :ω,
            source_id = "X",
            conversion = :identity_ratio,
            domain_lo = 0.0,
            domain_hi = 1.0,
        )
        @test keen_value_valid(sp, 0.6)
        @test !keen_value_valid(sp, 1.5)      # 域外 → invalid（clampしない）
        @test !keen_value_valid(sp, missing)
        @test !keen_value_valid(sp, NaN)
    end

    # ---- % と ratio の取り違え検出 ---------------------------------------
    @testset "% を ratio として取り違えると invalid になる" begin
        # ω を identity_ratio 扱いにして % 値(57.0)を渡すと域外 → 全 invalid → 構築失敗
        ds = full_dataset()
        cfg = mkcfg(; min_valid_obs = 4, omega_conv = :identity_ratio, omega_forbid = false)
        @test_throws ArgumentError build_keen_empirical_dataset(cfg, ds)
    end

    # ---- 指数型 labor share を ratio として受理しない ---------------------
    @testset "指数 unit の labor share を拒否" begin
        ds = full_dataset(; omega_unit = "Index 2012=100")
        cfg = mkcfg(; min_valid_obs = 4)
        @test_throws ArgumentError build_keen_empirical_dataset(cfg, ds)
    end

    # ---- monthly / quarterly 混在の整列 ----------------------------------
    @testset "月次・四半期混在が同じ四半期軸へ整列する" begin
        ds = full_dataset()
        cfg = mkcfg(; min_valid_obs = 4)
        out = build_keen_empirical_dataset(cfg, ds)
        @test length(out) == 16
        @test out.dates[1] == "2000-Q1"
        @test out.λ[1] ≈ 0.95          # 1 - 5/100
        @test out.d[1] ≈ 1.2           # 120/100
        @test out.r[1] ≈ 0.04          # 4/100
        @test out.provenance[:λ].original_frequency == Monthly
        @test out.provenance[:λ].aggregation == :mean
        @test out.provenance[:d].aggregation == :none   # 元が四半期
    end

    # ---- 共通期間が日付 intersection で決まる ----------------------------
    @testset "共通期間は配列位置でなく日付 intersection" begin
        # ω: 2000-2001, d: 2001-2002 → 共通は 2001 の 4 四半期のみ
        ov_labels = qlabels(2000, 2001)
        dv_labels = qlabels(2001, 2002)
        ml = mlabels(2000, 2002)
        dataset = MacroDataset(
            "t",
            DataSeries[
                mk_series("OMEGA", Quarterly, "Percent", ov_labels, fill(57.0, 8)),
                mk_series("LAMBDA", Monthly, "Percent", ml, fill(5.0, length(ml))),
                mk_series("DEBT", Quarterly, "Percent of GDP", dv_labels, fill(120.0, 8)),
                mk_series("RATE", Monthly, "Percent", ml, fill(4.0, length(ml))),
            ],
        )
        cfg = mkcfg(; min_valid_obs = 4, validation_split = 0.0)
        out = build_keen_empirical_dataset(cfg, dataset)
        @test out.dates == ["2001-Q1", "2001-Q2", "2001-Q3", "2001-Q4"]
        # 2000 の観測は d に無いので除外される
        @test "2000-Q1" ∉ out.dates
    end

    # ---- 欠損四半期を暗黙 forward fill しない -----------------------------
    @testset "欠損四半期を除外し forward fill しない" begin
        ql = qlabels(2000, 2003)
        ov = Union{Float64, Missing}[fill(57.0, 16)...]
        ov[3] = missing                 # 2000-Q3 の ω を欠損に
        ml = mlabels(2000, 2003)
        dataset = MacroDataset(
            "t",
            DataSeries[
                mk_series("OMEGA", Quarterly, "Percent", ql, ov),
                mk_series("LAMBDA", Monthly, "Percent", ml, fill(5.0, length(ml))),
                mk_series("DEBT", Quarterly, "Percent of GDP", ql, fill(120.0, 16)),
                mk_series("RATE", Monthly, "Percent", ml, fill(4.0, length(ml))),
            ],
        )
        cfg = mkcfg(; min_valid_obs = 4, validation_split = 0.0)
        out = build_keen_empirical_dataset(cfg, dataset)
        @test length(out) == 15
        @test "2000-Q3" ∉ out.dates
        @test "2000-Q3" ∈ out.dropped_dates
        # 欠損直後の四半期の観測時点は 0.25 の間隔を保つ（forward fill せず gap を反映）
        i = findfirst(==("2000-Q4"), out.dates)
        @test out.observation_times[i] ≈ 0.75
    end

    # ---- 重複日付・順序不定・空系列 ---------------------------------------
    @testset "重複四半期ラベルは失敗する" begin
        ql = vcat(qlabels(2000, 2003), ["2003-Q4"])   # 重複
        ov = fill(57.0, length(ql))
        ml = mlabels(2000, 2003)
        dataset = MacroDataset(
            "t",
            DataSeries[
                mk_series("OMEGA", Quarterly, "Percent", ql, ov),
                mk_series("LAMBDA", Monthly, "Percent", ml, fill(5.0, length(ml))),
                mk_series(
                    "DEBT",
                    Quarterly,
                    "Percent of GDP",
                    qlabels(2000, 2003),
                    fill(120.0, 16),
                ),
                mk_series("RATE", Monthly, "Percent", ml, fill(4.0, length(ml))),
            ],
        )
        cfg = mkcfg(; min_valid_obs = 4)
        @test_throws ArgumentError build_keen_empirical_dataset(cfg, dataset)
    end

    @testset "順序不定の入力でも同一結果" begin
        ds_ordered = full_dataset()
        # ω の日付・値をシャッフル
        ql = qlabels(2000, 2003)
        perm = reverse(1:16)
        ml = mlabels(2000, 2003)
        ds_shuffled = MacroDataset(
            "t",
            DataSeries[
                mk_series("OMEGA", Quarterly, "Percent", ql[perm], fill(57.0, 16)[perm]),
                mk_series("LAMBDA", Monthly, "Percent", ml, fill(5.0, length(ml))),
                mk_series("DEBT", Quarterly, "Percent of GDP", ql, fill(120.0, 16)),
                mk_series("RATE", Monthly, "Percent", ml, fill(4.0, length(ml))),
            ],
        )
        cfg = mkcfg(; min_valid_obs = 4)
        a = build_keen_empirical_dataset(cfg, ds_ordered)
        b = build_keen_empirical_dataset(cfg, ds_shuffled)
        @test a.dates == b.dates
        @test a.ω == b.ω
    end

    @testset "空（全欠損）系列は min_valid_obs で失敗" begin
        ql = qlabels(2000, 2003)
        ml = mlabels(2000, 2003)
        dataset = MacroDataset(
            "t",
            DataSeries[
                mk_series("OMEGA", Quarterly, "Percent", ql, fill(missing, 16)),
                mk_series("LAMBDA", Monthly, "Percent", ml, fill(5.0, length(ml))),
                mk_series("DEBT", Quarterly, "Percent of GDP", ql, fill(120.0, 16)),
                mk_series("RATE", Monthly, "Percent", ml, fill(4.0, length(ml))),
            ],
        )
        cfg = mkcfg(; min_valid_obs = 4)
        @test_throws ArgumentError build_keen_empirical_dataset(cfg, dataset)
    end

    # ---- 初期状態・Δt=0.25・分割 -----------------------------------------
    @testset "初期状態と Δt=0.25 観測時間軸" begin
        out = build_keen_empirical_dataset(mkcfg(; min_valid_obs = 4), full_dataset())
        @test out.initial_state.ω0 ≈ out.ω[1]
        @test out.initial_state.λ0 ≈ out.λ[1]
        @test out.initial_state.d0 ≈ out.d[1]
        @test out.observation_times[1] == 0.0
        @test all(diff(out.observation_times) .≈ 0.25)
    end

    @testset "calibration/validation split に重複・look-ahead なし" begin
        out = build_keen_empirical_dataset(
            mkcfg(; min_valid_obs = 4, validation_split = 0.25),
            full_dataset(),
        )
        n = length(out)
        @test isempty(intersect(out.calibration_indices, out.validation_indices))
        @test sort(vcat(out.calibration_indices, out.validation_indices)) == collect(1:n)
        @test maximum(out.calibration_indices) < minimum(out.validation_indices)  # look-ahead なし
        @test length(out.validation_indices) == 4   # floor(16*0.25)
    end

    @testset "日付指定の split" begin
        out = build_keen_empirical_dataset(
            mkcfg(; min_valid_obs = 4, validation_split = "2002-Q4"),
            full_dataset(),
        )
        # 2002-Q4 までが calibration（2000-2002 = 12 四半期）
        @test length(out.calibration_indices) == 12
        @test length(out.validation_indices) == 4
        @test out.dates[out.validation_indices[1]] == "2003-Q1"
    end

    # ---- r_mode -----------------------------------------------------------
    @testset "r_mode の切り替え" begin
        ds = full_dataset()
        m = build_keen_empirical_dataset(
            mkcfg(; min_valid_obs = 4, r_mode = :sample_mean),
            ds,
        )
        @test m.r_param ≈ 0.04
        s = build_keen_empirical_dataset(mkcfg(; min_valid_obs = 4, r_mode = :start), ds)
        @test s.r_param ≈ m.r[1]
        fcfg = KeenEmpiricalDataConfig(;
            country = "TEST",
            omega = mkcfg().omega,
            lambda = mkcfg().lambda,
            debt = mkcfg().debt,
            rate = mkcfg().rate,
            min_valid_obs = 4,
            r_mode = :fixed,
            r_fixed = 0.03,
        )
        f = build_keen_empirical_dataset(fcfg, ds)
        @test f.r_param ≈ 0.03
    end

    # ---- provenance / metadata / 決定性 ----------------------------------
    @testset "provenance と metadata が保持される" begin
        out = build_keen_empirical_dataset(
            mkcfg(; min_valid_obs = 4),
            full_dataset();
            mode = :provided,
        )
        @test out.metadata["methodology_version"] == KEEN_EMPIRICAL_METHODOLOGY_VERSION
        @test out.metadata["mode"] == :provided
        @test out.metadata["vintage"] == "revised"
        @test out.provenance[:d].original_unit == "Percent of GDP"
        @test out.provenance[:d].conversion_formula == "value / 100"
        @test out.provenance[:ω].source == "TEST"
        # 元データセットを無変更で参照保持
        @test haskey(out.source_dataset, "OMEGA")
    end

    @testset "同一設定で完全に決定的" begin
        ds = full_dataset()
        cfg = mkcfg(; min_valid_obs = 4)
        a = build_keen_empirical_dataset(cfg, ds)
        b = build_keen_empirical_dataset(cfg, ds)
        @test a.dates == b.dates
        @test a.ω == b.ω && a.λ == b.λ && a.d == b.d && a.r == b.r
        @test a.observation_times == b.observation_times
        @test a.r_param == b.r_param
        @test a.calibration_indices == b.calibration_indices
    end

    # ---- fixture 経路（同一契約） ----------------------------------------
    @testset "fixture 経路で dataset 契約を満たす" begin
        client = FredClient(mode = :fixture, fixture_dir = keen_fixture_dir)
        cfg = keen_us_default_config()
        out = build_keen_empirical_dataset(
            cfg;
            client = client,
            retrieved_at = "2026-07-18T00:00:00",
        )
        @test out.metadata["mode"] == :fixture
        @test length(out) == 60
        @test out.observation_times[1] == 0.0
        @test all(diff(out.observation_times) .≈ 0.25)
        @test all(0.0 .< out.ω .< 1.0)
        @test all(0.0 .< out.λ .< 1.0)
        @test all(out.d .> 0.0)
        @test all(0.0 .< out.r .< 1.0)
        @test out.provenance[:ω].mode == :fixture
        @test out.provenance[:ω].retrieved_at == "2026-07-18T00:00:00"
    end

    # ---- to_quarterly :end 拡張 ------------------------------------------
    @testset "to_quarterly :end（期末集計）" begin
        s = mk_series(
            "M",
            Monthly,
            "Percent",
            ["2000-01", "2000-02", "2000-03"],
            [1.0, 2.0, 3.0],
        )
        q = to_quarterly(s; method = :end)
        @test q.values[1] == 3.0        # 期末（3月）
        # 順序不定でも月番号で期末を選ぶ
        s2 = mk_series(
            "M",
            Monthly,
            "Percent",
            ["2000-03", "2000-01", "2000-02"],
            [3.0, 1.0, 2.0],
        )
        @test to_quarterly(s2; method = :end).values[1] == 3.0
    end
end
