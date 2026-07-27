@testset "RealRateModelArtifact 型・バリデーション・hash" begin
    valid_model() = ModelIdentity(;
        model_version = "0.1.0",
        code_commit_sha = "0"^40,
        solver_id = "dme.new_keynesian.msv",
        solver_version = "1.0.0",
        solver_method = "minimum_state_variable_linear_solution",
    )
    valid_parameter_set() =
        ParameterSet(; parameter_set_id = "p1", values = Dict("pi_star" => 0.02, "r_n" => 0.02))
    valid_calibration() =
        Calibration(; calibration_id = "fixture-v1", calibration_version = "1.0.0", calibration_kind = :fixture)
    valid_snapshot() = InputSnapshot(; snapshot_id = "no-external-input", snapshot_kind = :none)
    valid_run() =
        RunIdentity(; country = "US", scenario_id = "s1", run_id = "r1", output_kind = :trajectory, purpose = :comparison)
    valid_timing() = Timing(;
        decision_time = DateTime(2026, 7, 27, 9, 0, 0),
        data_cutoff_at = DateTime(2026, 7, 26, 23, 0, 0),
        generated_at = DateTime(2026, 7, 27, 9, 0, 1),
    )
    mp() = ModelPeriod(; index = 8, label = "2026-Q2")

    function obs(;
        id,
        metric,
        value,
        horizon = horizon_not_applicable(),
        status = :valid,
        validity_reasons = String[],
        method = :derived,
        input_observation_ids = String[],
    )
        ModelObservation(;
            observation_id = id,
            country = "US",
            metric = metric,
            model_period = mp(),
            calendar_date = Date(2026, 7, 1),
            horizon = horizon,
            value_type = :level,
            value = value,
            status = status,
            validity_reasons = validity_reasons,
            derivation = Derivation(;
                method = method,
                formula = "f",
                input_observation_ids = input_observation_ids,
            ),
            provenance = Provenance(; source_kind = method == :parameter ? :parameter : :derived),
        )
    end

    function base_observations(; nominal = 4.5, expected = 2.1)
        real_rate = nominal - expected
        [
            obs(id = "us.2026q2.current_inflation", metric = :current_inflation, value = 2.2),
            obs(
                id = "us.2026q2.nominal_policy_rate",
                metric = :nominal_policy_rate,
                value = nominal,
            ),
            obs(
                id = "us.2026q2.expected_inflation.p1y",
                metric = :expected_inflation,
                value = expected,
                horizon = horizon_expectation("P1Y"),
            ),
            obs(
                id = "us.2026q2.model_implied_real_policy_rate.p1y",
                metric = :model_implied_real_policy_rate,
                value = real_rate,
                horizon = horizon_expectation("P1Y"),
                input_observation_ids = [
                    "us.2026q2.nominal_policy_rate",
                    "us.2026q2.expected_inflation.p1y",
                ],
            ),
        ]
    end

    function build_artifact(; observations = base_observations(), timing = valid_timing())
        RealRateModelArtifact(;
            model = valid_model(),
            parameter_set = valid_parameter_set(),
            calibration = valid_calibration(),
            input_snapshot = valid_snapshot(),
            run = valid_run(),
            timing = timing,
            observations = observations,
        )
    end

    @testset "ModelIdentity バリデーション" begin
        @test valid_model() isa ModelIdentity
        @test_throws ArgumentError ModelIdentity(;
            model_version = "not-semver",
            code_commit_sha = "0"^40,
            solver_id = "a",
            solver_version = "1",
            solver_method = "m",
        )
        @test_throws ArgumentError ModelIdentity(;
            model_version = "0.1.0",
            code_commit_sha = "too-short",
            solver_id = "a",
            solver_version = "1",
            solver_method = "m",
        )
        @test_throws ArgumentError ModelIdentity(;
            model_version = "0.1.0",
            code_commit_sha = "0"^40,
            solver_id = "",
            solver_version = "1",
            solver_method = "m",
        )
        @test_throws ArgumentError ModelIdentity(;
            model_id = "dme.other_model",
            model_version = "0.1.0",
            code_commit_sha = "0"^40,
            solver_id = "a",
            solver_version = "1",
            solver_method = "m",
        )
    end

    @testset "ParameterSet: 空・NaN・hash" begin
        @test_throws ArgumentError ParameterSet(; parameter_set_id = "p", values = Dict{String, Float64}())
        @test_throws ArgumentError ParameterSet(; parameter_set_id = "p", values = Dict("a" => NaN))
        @test_throws ArgumentError ParameterSet(; parameter_set_id = "p", values = Dict("a" => Inf))
        ps1 = ParameterSet(; parameter_set_id = "p", values = Dict("a" => 1.0, "b" => 2.0))
        ps2 = ParameterSet(; parameter_set_id = "p", values = Dict("b" => 2.0, "a" => 1.0))
        @test ps1.parameter_hash == ps2.parameter_hash  # 挿入順序に非依存
        ps3 = ParameterSet(; parameter_set_id = "p", values = Dict("a" => 1.0, "b" => 2.1))
        @test ps1.parameter_hash != ps3.parameter_hash
        @test startswith(ps1.parameter_hash, "sha256:")
    end

    @testset "Calibration: enum・hash" begin
        @test_throws ArgumentError Calibration(;
            calibration_id = "c",
            calibration_version = "1.0.0",
            calibration_kind = :not_a_kind,
        )
        c1 = Calibration(; calibration_id = "c1", calibration_version = "1.0.0", calibration_kind = :fixture)
        c2 = Calibration(; calibration_id = "c1", calibration_version = "1.0.0", calibration_kind = :empirical)
        @test c1.calibration_hash != c2.calibration_hash
    end

    @testset "InputSnapshot: 重複ソース拒否・hash" begin
        s1 = InputSource(; source_id = "s", source_version = "v1", content_hash = "sha256:" * ("0"^64))
        @test_throws ArgumentError InputSnapshot(;
            snapshot_id = "snap",
            snapshot_kind = :custom,
            sources = [s1, s1],
        )
        snap = InputSnapshot(; snapshot_id = "snap", snapshot_kind = :custom, sources = [s1])
        @test startswith(snap.snapshot_hash, "sha256:")
    end

    @testset "RunIdentity: country / output_kind / purpose 検証" begin
        @test_throws ArgumentError RunIdentity(;
            country = "UK",
            scenario_id = "s",
            run_id = "r",
            output_kind = :trajectory,
            purpose = :comparison,
        )
        @test_throws ArgumentError RunIdentity(;
            country = "US",
            scenario_id = "s",
            run_id = "r",
            output_kind = :not_a_kind,
            purpose = :comparison,
        )
        r = RunIdentity(; country = "JP", scenario_id = "s", run_id = "r", output_kind = :steady_state, purpose = :diagnostic)
        @test r.calendar_timezone == "Asia/Tokyo"
    end

    @testset "Timing: look-ahead 防止" begin
        @test_throws ArgumentError Timing(;
            decision_time = DateTime(2026, 7, 27),
            data_cutoff_at = DateTime(2026, 7, 28),
            generated_at = DateTime(2026, 7, 29),
        )
        @test_throws ArgumentError Timing(;
            decision_time = DateTime(2026, 7, 27),
            data_cutoff_at = DateTime(2026, 7, 26),
            generated_at = DateTime(2026, 7, 26),
        )
    end

    @testset "Horizon: サポート外 duration・model_periods/aggregation 不整合" begin
        @test_throws ArgumentError Horizon(; kind = :expectation, duration = "P5Y")
        @test_throws ArgumentError Horizon(; kind = :expectation, duration = "P10Y")
        @test_throws ArgumentError Horizon(; kind = :expectation, duration = "P1Y", model_periods = 1)
        @test_throws ArgumentError Horizon(; kind = :expectation, duration = "P1Y", aggregation = :compounded_path)
        @test_throws ArgumentError Horizon(; kind = :expectation, duration = "P3M", aggregation = :arithmetic_mean)
        @test_throws ArgumentError Horizon(; kind = :not_applicable, duration = "P1Y")
        h = horizon_expectation("P3M")
        @test h.model_periods == 1
        @test h.aggregation == :one_step_ahead
        h2 = horizon_expectation("P1Y")
        @test h2.model_periods == 4
        @test h2.aggregation == :arithmetic_mean
    end

    @testset "ModelObservation: horizon.kind と metric の整合" begin
        @test_throws ArgumentError obs(
            id = "x.y.z",
            metric = :expected_inflation,
            value = 1.0,
            horizon = horizon_not_applicable(),
        )
        @test_throws ArgumentError obs(
            id = "x.y.z",
            metric = :current_inflation,
            value = 1.0,
            horizon = horizon_expectation("P1Y"),
        )
    end

    @testset "ModelObservation: observation_id 形式" begin
        @test_throws ArgumentError obs(id = "Bad ID", metric = :current_inflation, value = 1.0)
        @test_throws ArgumentError obs(id = "_leading_underscore", metric = :current_inflation, value = 1.0)
        @test obs(id = "ok.id-1", metric = :current_inflation, value = 1.0) isa ModelObservation
    end

    @testset "ModelObservation: status/value/validity_reasons 整合" begin
        @test_throws ArgumentError obs(id = "x.y.z", metric = :current_inflation, value = nothing, status = :valid)
        @test_throws ArgumentError obs(id = "x.y.z", metric = :current_inflation, value = NaN, status = :valid)
        @test_throws ArgumentError obs(
            id = "x.y.z",
            metric = :current_inflation,
            value = 1.0,
            status = :valid,
            validity_reasons = ["非空はvalidで禁止"],
        )
        @test_throws ArgumentError obs(id = "x.y.z", metric = :current_inflation, value = nothing, status = :invalid)
        @test_throws ArgumentError obs(
            id = "x.y.z",
            metric = :current_inflation,
            value = 1.0,
            status = :invalid,
            validity_reasons = ["ok"],
        )
        invalid_obs = obs(
            id = "x.y.z",
            metric = :current_inflation,
            value = nothing,
            status = :invalid,
            validity_reasons = ["no_data"],
        )
        @test invalid_obs.value === nothing
        @test invalid_obs.validity_reasons == ["no_data"]
    end

    @testset "RealRateModelArtifact: 必須metric・最小件数" begin
        only_current = [obs(id = "us.2026q2.current_inflation", metric = :current_inflation, value = 2.0)]
        @test_throws ArgumentError build_artifact(; observations = only_current)
    end

    @testset "RealRateModelArtifact: observation_id 重複拒否" begin
        dup = vcat(base_observations(), [obs(id = "us.2026q2.current_inflation", metric = :inflation_target, value = 2.0)])
        @test_throws ArgumentError build_artifact(; observations = dup)
    end

    @testset "RealRateModelArtifact: 実質金利算術関係の検証" begin
        # nominal - expected != model_implied_real_policy_rate.value
        broken = base_observations()
        idx = findfirst(o -> o.metric == :model_implied_real_policy_rate, broken)
        broken[idx] = obs(
            id = broken[idx].observation_id,
            metric = :model_implied_real_policy_rate,
            value = 999.0,  # 不一致
            horizon = horizon_expectation("P1Y"),
            input_observation_ids = broken[idx].derivation.input_observation_ids,
        )
        @test_throws ArgumentError build_artifact(; observations = broken)
    end

    @testset "RealRateModelArtifact: model_implied_real_policy_rate の入力参照欠落を拒否" begin
        broken = base_observations()
        idx = findfirst(o -> o.metric == :model_implied_real_policy_rate, broken)
        broken[idx] = obs(
            id = broken[idx].observation_id,
            metric = :model_implied_real_policy_rate,
            value = 2.4,
            horizon = horizon_expectation("P1Y"),
            input_observation_ids = String[],  # 参照が空
        )
        @test_throws ArgumentError build_artifact(; observations = broken)
    end

    @testset "artifact_id の決定性" begin
        a1 = build_artifact()
        a2 = build_artifact()
        @test a1.artifact_id == a2.artifact_id
        @test startswith(a1.artifact_id, "sha256:")

        # generated_at だけ変更しても artifact_id は不変
        t2 = Timing(;
            decision_time = DateTime(2026, 7, 27, 9, 0, 0),
            data_cutoff_at = DateTime(2026, 7, 26, 23, 0, 0),
            generated_at = DateTime(2026, 7, 27, 12, 0, 0),
        )
        a3 = build_artifact(; timing = t2)
        @test a3.artifact_id == a1.artifact_id

        # decision_time を変えると artifact_id は変わる
        t3 = Timing(;
            decision_time = DateTime(2026, 7, 27, 10, 0, 0),
            data_cutoff_at = DateTime(2026, 7, 26, 23, 0, 0),
            generated_at = DateTime(2026, 7, 27, 12, 0, 0),
        )
        a4 = build_artifact(; timing = t3)
        @test a4.artifact_id != a1.artifact_id

        # observation の値を変えると artifact_id は変わる
        a5 = build_artifact(; observations = base_observations(; nominal = 4.6, expected = 2.2))
        @test a5.artifact_id != a1.artifact_id
    end

    @testset "hash の局所性: 無関係フィールド変更で不変" begin
        ps1 = ParameterSet(; parameter_set_id = "p1", values = Dict("a" => 1.0))
        ps2 = ParameterSet(; parameter_set_id = "p2", values = Dict("a" => 1.0))  # id だけ違う
        @test ps1.parameter_hash == ps2.parameter_hash  # values のみが hash 対象

        c1 = Calibration(; calibration_id = "c", calibration_version = "1.0.0", calibration_kind = :fixture)
        c2 = Calibration(; calibration_id = "c", calibration_version = "2.0.0", calibration_kind = :fixture)
        @test c1.calibration_hash != c2.calibration_hash
    end

    @testset "to_dict / from_dict round-trip" begin
        a = build_artifact()
        d = to_dict(a)
        a2 = real_rate_model_artifact_from_dict(d)
        @test a2.artifact_id == a.artifact_id
        @test to_dict(a2) == d

        j = to_json(a)
        a3 = real_rate_model_artifact_from_json(j)
        @test a3.artifact_id == a.artifact_id
    end

    @testset "from_dict: 改ざんされた hash / artifact_id を拒否" begin
        a = build_artifact()
        d = to_dict(a)

        d_bad_id = deepcopy(d)
        d_bad_id["artifact_id"] = "sha256:" * ("0"^64)
        @test_throws ArgumentError real_rate_model_artifact_from_dict(d_bad_id)

        d_bad_param_hash = deepcopy(d)
        d_bad_param_hash["parameter_set"]["parameter_hash"] = "sha256:" * ("1"^64)
        @test_throws ArgumentError real_rate_model_artifact_from_dict(d_bad_param_hash)
    end

    @testset "unsupported_schema_version を拒否" begin
        a = build_artifact()
        d = to_dict(a)
        d["schema_version"] = "2.0.0"
        @test_throws ArgumentError real_rate_model_artifact_from_dict(d)
    end
end
