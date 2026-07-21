# GR バックエンドをヘッドレスモードで動作させる（CI / 無表示環境対応）
ENV["GKSwstype"] = "nul"
using Plots
# JSON3 は DME の依存（test 環境へ直接は入れない）。DME 経由で参照する。
const JSON3 = DME.JSON3

@testset "Keen 実証統合デモ" begin
    fixture_dir = joinpath(@__DIR__, "fixtures", "keen")

    # fixture mode で dataset → 推定 → 検証 を実行するヘルパー（外部接続なし・決定的）
    function run_fixture()
        client = FredClient(; mode = :fixture, fixture_dir = fixture_dir)
        ds = build_keen_empirical_dataset(keen_us_default_config(); client = client)
        ccfg = keen_default_calibration_config(ds; n_starts = 5)
        vcfg = keen_default_validation_config(ds; calibration_config = ccfg)
        res = validate_keen(ds, vcfg)
        (client, ds, ccfg, vcfg, res)
    end

    # ---- fixture mode で外部接続なしに完走する ----------------------------
    @testset "fixture mode で完走・dataset 契約" begin
        client, ds, ccfg, vcfg, res = run_fixture()
        @test client.mode === :fixture
        # 既存 fixture（US 既定系列）の確定 shape（上流 live 値ではなく固定 JSON）
        @test length(ds) == 60
        @test ds.metadata["sample_start"] == "2000-Q1"
        @test ds.metadata["sample_end"] == "2014-Q4"
        @test length(ds.calibration_indices) + length(ds.validation_indices) == length(ds)
        @test !isempty(ds.validation_indices)
        @test res isa KeenValidationResult
        @test !isempty(res.evaluations)
        @test length(res.sensitivity) >= 4  # base + amort×3 + rate + guess + weight
    end

    # ---- 同一 fixture・設定・seed で主要結果が一致する（決定性）-----------
    @testset "決定的（同一 fixture・設定・seed）" begin
        _, _, _, _, r1 = run_fixture()
        _, _, _, _, r2 = run_fixture()
        @test r1.calibration_result.estimated == r2.calibration_result.estimated
        @test r1.calibration_result.objective_value == r2.calibration_result.objective_value
        @test [s.estimated for s in r1.sensitivity] == [s.estimated for s in r2.sensitivity]
        for (e1, e2) in zip(r1.evaluations, r2.evaluations)
            for v in (:ω, :λ, :d)
                a, b = e1.metrics[v].rmse, e2.metrics[v].rmse
                @test (isnan(a) && isnan(b)) || a == b
            end
        end
        @test r1.warnings == r2.warnings
    end

    # ---- observed/literature/calibrated の系列長・時間軸が一致する --------
    @testset "trajectory の系列長・時間軸が一致" begin
        _, ds, _, _, res = run_fixture()
        b = res.trajectories
        n = length(ds)
        @test length(b.times) == n
        @test length(b.dates) == n
        for series in (b.observed, b.literature, b.calibrated)
            for v in (:ω, :λ, :d)
                @test length(series[v]) == n
            end
        end
        # 期間境界は split と対応
        @test b.calibration_end_time == ds.observation_times[ds.calibration_indices[end]]
        @test b.validation_start_time == ds.observation_times[ds.validation_indices[1]]
    end

    # ---- invalid/NaN を 0 化せず保持する ---------------------------------
    @testset "invalid/NaN を 0 化しない" begin
        _, _, _, _, res = run_fixture()
        # literature モデルは観測初期状態から発散 → trajectory に NaN が残る（0 ではない）
        lit_d = res.trajectories.literature[:d]
        @test any(isnan, lit_d)
        @test !all(x -> x == 0.0 || isnan(x), lit_d)  # 有限の実値も含む（全 0 化されていない）
        # 発散したモデルの metric は NaN（0 ではない）
        lit_eval = first(
            e for e in res.evaluations if e.model_label == :literature &&
                e.period == :out_of_sample &&
                e.initial_state_mode == :observed_start
        )
        @test lit_eval.diverged
        @test isnan(lit_eval.metrics[:d].rmse)  # 発散を 0 の完全 fit と誤認しない
    end

    # ---- amortization は診断のみ変え ODE/推定は不変 ----------------------
    @testset "amortization 感応度は推定不変" begin
        _, _, _, _, res = run_fixture()
        base = first(s for s in res.sensitivity if s.scenario.name == "base")
        amorts = filter(s -> s.scenario.kind == :amortization_rate, res.sensitivity)
        @test length(amorts) == 3
        for s in amorts
            @test s.reused_base_calibration
            @test s.estimated == base.estimated
            @test s.objective_value == base.objective_value
        end
    end

    # ---- 機械可読レポートが parse 可能で必須 metadata を含む -------------
    @testset "レポート JSON の parse・必須メタデータ・NaN→null" begin
        client, ds, _, _, res = run_fixture()
        dir = mktempdir()
        report_path = joinpath(dir, "report.json")
        save_keen_empirical_report(
            report_path,
            ds,
            res;
            mode = client.mode,
            artifact_paths = ["dummy/traj.png"],
        )
        txt = read(report_path, String)
        r = JSON3.read(txt)
        for k in (
            "report_kind",
            "methodology",
            "dataset",
            "validation",
            "artifact_paths",
            "caveats",
        )
            @test haskey(r, k)
        end
        @test r["dataset"]["mode"] == "fixture"
        @test r["dataset"]["sample_start"] == "2000-Q1"
        @test Set(String.(keys(r["dataset"]["series"]))) == Set(["ω", "λ", "d", "r"])
        @test !isempty(r["caveats"])
        @test r["methodology"]["validation"] == KEEN_VALIDATION_METHODOLOGY_VERSION
        # NaN は JSON では null（0 化しない・NaN リテラルを書かない）
        @test !occursin("NaN", txt)
        @test occursin("null", txt)
        # validation JSON も同様に保存できる
        vpath = joinpath(dir, "val.json")
        save_keen_validation(vpath, res)
        @test JSON3.read(read(vpath, String)) isa JSON3.Object
    end

    # ---- secret 値が artifact に含まれない --------------------------------
    @testset "秘密値が artifact に含まれない" begin
        client, ds, _, _, res = run_fixture()
        secret = "SECRET_TEST_TOKEN_ZZZ_9182"
        prev = get(ENV, "FRED_API_KEY", nothing)
        ENV["FRED_API_KEY"] = secret
        try
            dir = mktempdir()
            path = joinpath(dir, "report.json")
            save_keen_empirical_report(path, ds, res; mode = client.mode)
            txt = read(path, String)
            @test !occursin(secret, txt)
            @test !occursin("FRED_API_KEY", txt)
        finally
            if prev === nothing
                delete!(ENV, "FRED_API_KEY")
            else
                ENV["FRED_API_KEY"] = prev
            end
        end
    end

    # ---- headless CI で plot 保存が成功する -------------------------------
    @testset "headless plot 保存" begin
        _, ds, _, _, res = run_fixture()
        dir = mktempdir()
        figs = Dict(
            "traj.png" => plot_keen_empirical_trajectories(res),
            "regime.png" => plot_keen_regime_comparison(res),
            "sens.png" => plot_keen_sensitivity(res; metric = :peak_debt_ratio),
        )
        for (name, fig) in figs
            path = joinpath(dir, name)
            savefig(fig, path)
            @test isfile(path)
            @test filesize(path) > 0
        end
        # 非結合（変数ごとに Vector で返す）
        panels = plot_keen_empirical_trajectories(res; combine = false)
        @test panels isa Vector
        @test length(panels) == 3
        # 未知の metric / variable は明示的にエラー
        @test_throws ArgumentError plot_keen_sensitivity(res; metric = :nope)
        @test_throws ArgumentError plot_keen_empirical_trajectories(res; variables = [:x])
    end
end
