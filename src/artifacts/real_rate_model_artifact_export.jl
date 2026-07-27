# NewKeynesianModel から RealRateModelArtifact を構築する adapter（`sfc_result` と同じ idiom）
# および atomic save / load。詳細は docs/adr/0008-real-rate-model-artifact-export.md を参照。

# ADR 006 の contract example (`docs/contract/examples/dme-real-rate-model-artifact.json`) と
# 同じ ASCII パラメータ名を使う。`NewKeynesianModel` のフィールド名はギリシャ文字 Unicode
# （σ, π_star 等）で JCS の ASCII キー制約に違反するため、このテーブルで変換する。
const _RRA_NK_PARAMETER_ASCII_NAMES = (
    σ = "sigma",
    r_n = "r_n",
    β = "beta",
    κ = "kappa",
    φ_π = "phi_pi",
    φ_x = "phi_x",
    π_star = "pi_star",
    ρ_x = "rho_x",
    ρ_c = "rho_c",
    ρ_m = "rho_m",
)

function _rra_nk_parameter_values(m::NewKeynesianModel)::Dict{String, Float64}
    p = parameters(m)
    return Dict{String, Float64}(
        _RRA_NK_PARAMETER_ASCII_NAMES[k] => Float64(v) for (k, v) in pairs(p)
    )
end

function _rra_quarter_label(d::Date)::String
    q = (Dates.month(d) - 1) ÷ 3 + 1
    return "$(Dates.year(d))-Q$(q)"
end

"""
    real_rate_model_artifact(m::NewKeynesianModel; kwargs...) -> RealRateModelArtifact

`NewKeynesianModel` から economic-data-provider ADR 006 / cross-repository JSON Schema
（`docs/contract/dme-real-rate-model-artifact.schema.json`）に準拠した
`RealRateModelArtifact` を構築する。

- `expected_inflation` の期待値パスは `nk_expected_inflation_path`（MSV 解の閉形式）から
  導出する（`current_inflation`/`inflation_target` のコピーではない）。
- `π`/`i` の IRF deviation は `nk_inflation_level`/`nk_nominal_rate_level` で level へ復元する。
- `horizons` は `"P3M"`（`one_step_ahead`）・`"P1Y"`（4四半期の年率換算値の
  `arithmetic_mean`）のみサポートする。5Y/10Y term structure は生成しない。
- `shock_size == 0.0`（デフォルト）のときは `output_kind=:steady_state` として扱う
  （IRF deviation が恒等的に0になるため、`shock` の種類は結果に影響しない）。
- `decision_time`/`data_cutoff_at`/`generated_at` は呼び出し側が明示的に渡す必須引数とする
  （`now()` 等の非決定的なデフォルトは使わない）。
"""
function real_rate_model_artifact(
    m::NewKeynesianModel;
    country::AbstractString,
    scenario_id::AbstractString,
    run_id::AbstractString,
    decision_time::DateTime,
    data_cutoff_at::DateTime,
    generated_at::DateTime,
    parameter_set_id::AbstractString,
    calibration_id::AbstractString,
    calibration_version::AbstractString,
    code_commit_sha::AbstractString,
    shock::Symbol = :demand,
    shock_size::Float64 = 0.0,
    model_period_index::Int = 1,
    horizons::AbstractVector{<:AbstractString} = ["P3M", "P1Y"],
    calibration_kind::Symbol = :fixture,
    purpose::Symbol = :comparison,
    model_version::AbstractString = "0.1.0",
    solver_id::AbstractString = "dme.new_keynesian.msv",
    solver_version::AbstractString = "1.0.0",
    solver_method::AbstractString = "minimum_state_variable_linear_solution",
    input_snapshot::InputSnapshot = InputSnapshot(;
        snapshot_id = "no-external-input",
        snapshot_kind = :none,
    ),
)::RealRateModelArtifact
    model_period_index >= 1 || throw(
        ArgumentError(
            "model_period_index は1以上である必要があります: $model_period_index",
        ),
    )
    isempty(horizons) && throw(ArgumentError("horizons は最低1件必要です"))
    for (k, v) in pairs(_rra_nk_parameter_values(m))
        isfinite(v) || throw(
            ArgumentError(
                "NewKeynesianModel のパラメータに非有限値が含まれています: $k = $v",
            ),
        )
    end
    for d in horizons
        haskey(RRA_HORIZON_SPECS, d) || throw(
            ArgumentError(
                "サポートされていない horizon です: $d（対応: $(join(sort(collect(keys(RRA_HORIZON_SPECS))), ", "))）。5Y/10Y term structure は現行 New Keynesian モデルから生成しません。",
            ),
        )
    end

    output_kind = shock_size == 0.0 ? :steady_state : :trajectory
    max_h = maximum(RRA_HORIZON_SPECS[d].model_periods for d in horizons)
    irf = impulse_response(m, shock_size; shock = shock, T = model_period_index + max_h)

    π_dev = irf.π[model_period_index]
    i_dev = irf.i[model_period_index]
    π_level = 100.0 * nk_inflation_level(m, π_dev)
    i_level = 100.0 * nk_nominal_rate_level(m, i_dev)
    π_star_level = 100.0 * m.π_star
    r_n_level = 100.0 * m.r_n

    calendar_date = Date(decision_time) + Dates.Month(3 * (model_period_index - 1))
    label = _rra_quarter_label(calendar_date)
    model_period = ModelPeriod(; index = model_period_index, label = label)

    country_slug = lowercase(country)
    period_slug = lowercase(label)
    obs_id(suffix::AbstractString) = "$(country_slug).$(period_slug).$(suffix)"

    model = ModelIdentity(;
        model_version = model_version,
        code_commit_sha = code_commit_sha,
        solver_id = solver_id,
        solver_version = solver_version,
        solver_method = solver_method,
    )
    parameter_set = ParameterSet(;
        parameter_set_id = parameter_set_id,
        values = _rra_nk_parameter_values(m),
    )
    calibration = Calibration(;
        calibration_id = calibration_id,
        calibration_version = calibration_version,
        calibration_kind = calibration_kind,
    )
    run = RunIdentity(;
        country = country,
        scenario_id = scenario_id,
        run_id = run_id,
        output_kind = output_kind,
        purpose = purpose,
    )
    timing = Timing(;
        decision_time = decision_time,
        data_cutoff_at = data_cutoff_at,
        generated_at = generated_at,
    )

    current_obs = ModelObservation(;
        observation_id = obs_id("current_inflation"),
        country = country,
        metric = :current_inflation,
        model_period = model_period,
        calendar_date = calendar_date,
        horizon = horizon_not_applicable(),
        value_type = :level,
        value = π_level,
        status = :valid,
        derivation = Derivation(;
            method = :derived,
            formula = "100 * (pi_star + pi_deviation_t)",
            parameter_names = ["pi_star"],
            solver_outputs = ["pi_deviation_t"],
        ),
        provenance = Provenance(;
            source_kind = :derived,
            source_names = ["impulse_response.π", "NewKeynesianModel.π_star"],
            notes = ["Current inflation level; not an expected-inflation observation."],
        ),
    )

    target_obs = ModelObservation(;
        observation_id = obs_id("inflation_target"),
        country = country,
        metric = :inflation_target,
        model_period = model_period,
        calendar_date = calendar_date,
        horizon = horizon_not_applicable(),
        value_type = :level,
        value = π_star_level,
        status = :valid,
        derivation = Derivation(;
            method = :parameter,
            formula = "100 * pi_star",
            parameter_names = ["pi_star"],
        ),
        provenance = Provenance(;
            source_kind = :parameter,
            source_names = ["NewKeynesianModel.π_star"],
            notes = ["Inflation target; not current or expected inflation."],
        ),
    )

    nominal_obs = ModelObservation(;
        observation_id = obs_id("nominal_policy_rate"),
        country = country,
        metric = :nominal_policy_rate,
        model_period = model_period,
        calendar_date = calendar_date,
        horizon = horizon_not_applicable(),
        value_type = :level,
        value = i_level,
        status = :valid,
        derivation = Derivation(;
            method = :derived,
            formula = "100 * (r_n + pi_star + i_deviation_t)",
            parameter_names = ["r_n", "pi_star"],
            solver_outputs = ["i_deviation_t"],
        ),
        provenance = Provenance(;
            source_kind = :derived,
            source_names = [
                "impulse_response.i",
                "NewKeynesianModel.r_n",
                "NewKeynesianModel.π_star",
            ],
            notes = ["Nominal policy-rate level restored from the IRF deviation."],
        ),
    )

    natural_obs = ModelObservation(;
        observation_id = obs_id("natural_real_rate"),
        country = country,
        metric = :natural_real_rate,
        model_period = model_period,
        calendar_date = calendar_date,
        horizon = horizon_not_applicable(),
        value_type = :level,
        value = r_n_level,
        status = :valid,
        derivation = Derivation(;
            method = :parameter,
            formula = "100 * r_n",
            parameter_names = ["r_n"],
        ),
        provenance = Provenance(;
            source_kind = :parameter,
            source_names = ["NewKeynesianModel.r_n"],
            notes = [
                "Natural real rate diagnostic; never substituted for the model-implied real policy rate.",
            ],
        ),
    )

    observations = ModelObservation[current_obs, target_obs, nominal_obs, natural_obs]
    warnings = String[]
    calibration_kind == :fixture && push!(warnings, "fixture_calibration_not_empirical")
    push!(warnings, "pi_star_r_n_interpreted_as_annualized_rate_levels")

    for duration in horizons
        spec = RRA_HORIZON_SPECS[duration]
        hs = collect(1:(spec.model_periods))
        expected_devs =
            nk_expected_inflation_path(m, shock_size, model_period_index, hs; shock = shock)
        expected_levels = [100.0 * nk_inflation_level(m, d) for d in expected_devs]

        if spec.aggregation == :one_step_ahead
            expected_value = expected_levels[1]
            formula = "100 * (pi_star + expected_pi_deviation_t_plus_1)"
        else
            expected_value = sum(expected_levels) / length(expected_levels)
            formula = "mean(h=1..$(spec.model_periods), 100 * (pi_star + expected_pi_deviation_t_plus_h))"
            push!(
                warnings,
                "p1y_expected_inflation_uses_arithmetic_mean_not_compounded_path",
            )
        end
        solver_outputs = ["expected_pi_deviation_t_plus_$(h)" for h in hs]
        horizon = horizon_expectation(duration)
        duration_slug = lowercase(duration)

        expected_obs = ModelObservation(;
            observation_id = obs_id("expected_inflation.$(duration_slug)"),
            country = country,
            metric = :expected_inflation,
            model_period = model_period,
            calendar_date = calendar_date,
            horizon = horizon,
            value_type = :level,
            value = expected_value,
            status = :valid,
            derivation = Derivation(;
                method = :derived,
                formula = formula,
                parameter_names = ["pi_star"],
                solver_outputs = solver_outputs,
            ),
            provenance = Provenance(;
                source_kind = :derived,
                source_names = ["nk_expected_inflation_path"],
                notes = [
                    "MSV 解の閉形式から導出した t+$(hs[end]) 期先までの期待インフレ率。current_inflation・inflation_target のコピーではない。",
                ],
            ),
        )

        real_rate_obs = ModelObservation(;
            observation_id = obs_id("model_implied_real_policy_rate.$(duration_slug)"),
            country = country,
            metric = :model_implied_real_policy_rate,
            model_period = model_period,
            calendar_date = calendar_date,
            horizon = horizon,
            value_type = :level,
            value = i_level - expected_value,
            status = :valid,
            derivation = Derivation(;
                method = :derived,
                formula = "nominal_policy_rate - expected_inflation",
                input_observation_ids = [
                    nominal_obs.observation_id,
                    expected_obs.observation_id,
                ],
            ),
            provenance = Provenance(;
                source_kind = :derived,
                source_names = [nominal_obs.observation_id, expected_obs.observation_id],
                notes = [
                    "Ex-ante model-implied real policy rate; not the natural real rate.",
                ],
            ),
        )

        push!(observations, expected_obs, real_rate_obs)
    end

    unique!(warnings)

    return RealRateModelArtifact(;
        model = model,
        parameter_set = parameter_set,
        calibration = calibration,
        input_snapshot = input_snapshot,
        run = run,
        timing = timing,
        observations = observations,
        warnings = warnings,
    )
end

# ---------------------------------------------------------------------------
# 保存・読み込み（atomic rename、ファイル名規約は ADR 006 §6 に準拠）
# ---------------------------------------------------------------------------

_rra_slugify(s::AbstractString)::String = replace(s, r"[^A-Za-z0-9._-]" => "-")

function _rra_artifact_file_path(base_dir::AbstractString, a::RealRateModelArtifact)::String
    g = a.timing.generated_at
    yyyy = lpad(Dates.year(g), 4, '0')
    mm = lpad(Dates.month(g), 2, '0')
    ts = Dates.format(g, dateformat"yyyymmddTHHMMSS") * "Z"
    digest = replace(a.artifact_id, r"^sha256:" => "")
    fname = string(
        ts,
        "__",
        _rra_slugify(a.run.country),
        "__",
        _rra_slugify(a.model.model_id),
        "__",
        _rra_slugify(a.run.run_id),
        "__",
        digest,
        ".json",
    )
    return joinpath(
        base_dir,
        "artifacts",
        "real-rates",
        a.schema_version,
        a.run.country,
        yyyy,
        mm,
        fname,
    )
end

"""
    save_real_rate_model_artifact(a::RealRateModelArtifact, base_dir::AbstractString) -> String

`a` を ADR 006 §6 のファイル名規約に従って `base_dir` 配下へ保存する。`.tmp` へ書いて
`fsync` した後 `mv`（atomic rename）で確定させる。同名ファイルへは上書きしない。
書き込む内容は常に正準 JSON バイト列（`canonical_json_bytes`）。生成されたファイルパスを返す。
"""
function save_real_rate_model_artifact(
    a::RealRateModelArtifact,
    base_dir::AbstractString,
)::String
    path = _rra_artifact_file_path(base_dir, a)
    isfile(path) &&
        throw(ArgumentError("artifact ファイルが既に存在します（上書きしません）: $path"))
    mkpath(dirname(path))
    tmp_path = path * ".tmp"
    bytes = canonical_json_bytes(to_dict(a))
    try
        open(tmp_path, "w") do io
            write(io, bytes)
            flush(io)
            @static if Sys.isunix()
                ccall(:fsync, Cint, (Cint,), fd(io))
            end
        end
        mv(tmp_path, path; force = false)
    catch
        isfile(tmp_path) && rm(tmp_path; force = true)
        rethrow()
    end
    return path
end

"""`save_real_rate_model_artifact` が書いたファイルを読み込み、hash を再検証して返す。"""
load_real_rate_model_artifact(path::AbstractString)::RealRateModelArtifact =
    real_rate_model_artifact_from_json(read(path, String))

"""
    _detect_git_commit_sha(; dir = pkgdir(DME)) -> Union{String,Nothing}

`git rev-parse HEAD`（40桁フル hex）を返す。失敗時（`.git` が存在しない配布環境等）は
`nothing`。`real_rate_model_artifact` の `code_commit_sha` は必須引数のため自動検出しない
（呼び出し側がこの関数の結果を明示的に渡すか、別の値を指定する）。
"""
function _detect_git_commit_sha(;
    dir::AbstractString = pkgdir(@__MODULE__),
)::Union{String, Nothing}
    try
        sha = readchomp(`git -C $dir rev-parse HEAD`)
        return occursin(_RRA_COMMIT_SHA_RE, sha) ? sha : nothing
    catch
        return nothing
    end
end
