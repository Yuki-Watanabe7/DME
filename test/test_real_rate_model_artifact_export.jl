@testset "real_rate_model_artifact export (Issue #159)" begin
    fixture_model() = NewKeynesianModel(1.0, 0.02, 0.99, 0.1, 1.5, 0.5, 0.02, 0.8, 0.5, 0.5)

    common_kwargs = (
        country = "US",
        scenario_id = "baseline-fixture",
        run_id = "nk-us-fixture-001",
        shock = :demand,
        shock_size = 0.01,
        model_period_index = 8,
        decision_time = DateTime(2026, 7, 2, 0, 0, 0),
        data_cutoff_at = DateTime(2026, 7, 2, 0, 0, 0),
        generated_at = DateTime(2026, 7, 2, 0, 5, 0),
        parameter_set_id = "nk-baseline-fixture",
        calibration_id = "nk-us-fixture",
        calibration_version = "1.0.0",
        calibration_kind = :fixture,
        code_commit_sha = "0"^40,
    )

    @testset "golden fixture: artifact_id 回帰" begin
        a = real_rate_model_artifact(fixture_model(); common_kwargs...)
        # 実装時に一度計算し、以後は固定値として凍結する（回帰検出用）。
        # 導出ロジックを意図的に変更する場合のみ更新する。
        @test a.artifact_id == "sha256:69ff0ee0db4b0b94ed98739343d720912ce4f525612bb09ce031be13327e25b2"
        @test a.schema_version == REAL_RATE_ARTIFACT_SCHEMA_VERSION
        @test a.artifact_type == "dme.real_rate_model"
        @test a.model.model_id == "dme.new_keynesian"
        @test a.run.output_kind == :trajectory
    end

    @testset "expected_inflation は current_inflation / inflation_target のエイリアスではない" begin
        a = real_rate_model_artifact(fixture_model(); common_kwargs...)
        current = only(filter(o -> o.metric == :current_inflation, a.observations))
        target = only(filter(o -> o.metric == :inflation_target, a.observations))
        expected_p1y = only(
            filter(o -> o.metric == :expected_inflation && o.horizon.duration == "P1Y", a.observations),
        )
        expected_p3m = only(
            filter(o -> o.metric == :expected_inflation && o.horizon.duration == "P3M", a.observations),
        )

        @test expected_p1y.value != current.value
        @test expected_p1y.value != target.value
        @test expected_p3m.value != current.value
        @test expected_p1y.derivation.method == :derived
        @test expected_p1y.derivation.input_observation_ids == String[]  # current/target を直接参照しない
        @test !(current.observation_id in expected_p1y.derivation.input_observation_ids)
        @test !(target.observation_id in expected_p1y.derivation.input_observation_ids)
    end

    @testset "nk_expected_inflation_path との直接突合" begin
        m = fixture_model()
        a = real_rate_model_artifact(m; common_kwargs...)
        expected_p3m = only(
            filter(o -> o.metric == :expected_inflation && o.horizon.duration == "P3M", a.observations),
        )
        closed_form = nk_expected_inflation_path(m, common_kwargs.shock_size, common_kwargs.model_period_index, [1]; shock = common_kwargs.shock)
        expected_level = 100.0 * nk_inflation_level(m, closed_form[1])
        @test expected_p3m.value ≈ expected_level atol = 1e-10
    end

    @testset "level/deviation 取り違え防止" begin
        m = fixture_model()
        a = real_rate_model_artifact(m; common_kwargs...)
        irf = impulse_response(m, common_kwargs.shock_size; shock = common_kwargs.shock, T = 12)
        raw_deviation = irf.π[common_kwargs.model_period_index]
        current = only(filter(o -> o.metric == :current_inflation, a.observations))
        @test current.value != 100.0 * raw_deviation  # 生の deviation そのままではない
        @test current.value ≈ 100.0 * (m.π_star + raw_deviation) atol = 1e-10  # level に復元されている
        @test all(o -> o.value_type == :level, a.observations)
    end

    @testset "実質金利の算術関係が全 observation で成立" begin
        a = real_rate_model_artifact(fixture_model(); common_kwargs...)
        nominal = only(filter(o -> o.metric == :nominal_policy_rate, a.observations))
        for horizon_dur in ("P3M", "P1Y")
            expected = only(
                filter(
                    o -> o.metric == :expected_inflation && o.horizon.duration == horizon_dur,
                    a.observations,
                ),
            )
            real_rate = only(
                filter(
                    o ->
                        o.metric == :model_implied_real_policy_rate && o.horizon.duration == horizon_dur,
                    a.observations,
                ),
            )
            @test real_rate.value ≈ nominal.value - expected.value atol = 1e-9
        end
    end

    @testset "natural_real_rate は model_implied_real_policy_rate と別 observation" begin
        a = real_rate_model_artifact(fixture_model(); common_kwargs...)
        natural = only(filter(o -> o.metric == :natural_real_rate, a.observations))
        real_rates = filter(o -> o.metric == :model_implied_real_policy_rate, a.observations)
        @test natural.derivation.method == :parameter
        for r in real_rates
            @test r.observation_id != natural.observation_id
            # ショックが非ゼロなので数値的にも一致しない
            @test !isapprox(r.value, natural.value; atol = 1e-9)
        end
    end

    @testset "look-ahead 防止 (data_cutoff_at > decision_time)" begin
        bad = merge(common_kwargs, (data_cutoff_at = DateTime(2026, 7, 3, 0, 0, 0),))
        @test_throws ArgumentError real_rate_model_artifact(fixture_model(); bad...)
    end

    @testset "shock_size = 0.0 は steady_state に縮退する" begin
        ss_kwargs = merge(common_kwargs, (shock_size = 0.0,))
        a = real_rate_model_artifact(fixture_model(); ss_kwargs...)
        @test a.run.output_kind == :steady_state
        current = only(filter(o -> o.metric == :current_inflation, a.observations))
        target = only(filter(o -> o.metric == :inflation_target, a.observations))
        @test current.value ≈ target.value atol = 1e-12
        # 数値的に一致しても derivation の method・provenance は別経路のまま
        @test current.derivation.method == :derived
        @test target.derivation.method == :parameter
    end

    @testset "サポート外 horizon (5Y/10Y 相当) を拒否" begin
        bad = merge(common_kwargs, (horizons = ["P5Y"],))
        @test_throws ArgumentError real_rate_model_artifact(fixture_model(); bad...)
        bad2 = merge(common_kwargs, (horizons = String[],))
        @test_throws ArgumentError real_rate_model_artifact(fixture_model(); bad2...)
    end

    @testset "非有限パラメータを持つモデルからの構築を拒否" begin
        bad_model = NewKeynesianModel(1.0, 0.02, 0.99, NaN, 1.5, 0.5, 0.02, 0.8, 0.5, 0.5)
        @test_throws ArgumentError real_rate_model_artifact(bad_model; common_kwargs...)
    end

    @testset "country 不正値を拒否" begin
        bad = merge(common_kwargs, (country = "UK",))
        @test_throws ArgumentError real_rate_model_artifact(fixture_model(); bad...)
    end

    @testset "save/load: ファイル名規約・atomic rename・round-trip" begin
        a = real_rate_model_artifact(fixture_model(); common_kwargs...)
        dir = mktempdir()
        path = save_real_rate_model_artifact(a, dir)

        @test isfile(path)
        @test !isfile(path * ".tmp")
        @test occursin(joinpath("artifacts", "real-rates", "1.0.0", "US", "2026", "07"), path)
        digest = replace(a.artifact_id, r"^sha256:" => "")
        @test occursin(digest, basename(path))
        @test occursin("__US__dme.new_keynesian__nk-us-fixture-001__", basename(path))

        loaded = load_real_rate_model_artifact(path)
        @test loaded.artifact_id == a.artifact_id
        @test to_dict(loaded) == to_dict(a)
    end

    @testset "save: 同一artifactの再保存は上書きしない" begin
        a = real_rate_model_artifact(fixture_model(); common_kwargs...)
        dir = mktempdir()
        save_real_rate_model_artifact(a, dir)
        @test_throws ArgumentError save_real_rate_model_artifact(a, dir)
    end

    @testset "save: 同一入力を2回保存するとバイト単位で一致する" begin
        a1 = real_rate_model_artifact(fixture_model(); common_kwargs...)
        a2 = real_rate_model_artifact(fixture_model(); common_kwargs...)
        dir1 = mktempdir()
        dir2 = mktempdir()
        p1 = save_real_rate_model_artifact(a1, dir1)
        p2 = save_real_rate_model_artifact(a2, dir2)
        @test read(p1, String) == read(p2, String)
    end

    @testset "_detect_git_commit_sha はフル40桁hexまたはnothingを返す" begin
        sha = DME._detect_git_commit_sha()
        @test sha === nothing || occursin(r"^[0-9a-f]{40}$", sha)
    end
end
