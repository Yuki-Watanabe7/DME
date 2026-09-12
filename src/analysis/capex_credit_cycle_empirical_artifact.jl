# CCC 実証統合デモ・artifact/report 層（Issue #251 / P-11）。
#
# #241–#250（catalog → raw observation → measurement/dataset → 較正 → 識別 → 推定 →
# episode 選定 → 履歴再生 → 検証 → robustness）の出力を1つの canonical artifact へ束ね、
# 実証統合設計 §11.2 の identity chain（catalog_version → dataset_hash → targets_hash →
# parameter_set_hash → replay_hash、および episode_hash）を保持する。加えて、§10.4 の
# caveats 8件を含む人間可読レポート（Markdown）を生成する。
#
# 本層は読み取り専用の後処理層であり、モデル・データ・較正・識別・推定・履歴再生・検証・
# 感応度の各層の型・公開APIを一切変更しない（新規の集約のみ）。`raw observation manifest`・
# `measured dataset manifest` は他層に to_dict 関数が無いため、ここで新設する
# （実証統合設計 §4.1 の対象ファイル表は本ファイルの新設を明示しないが、§4.3 の export 一覧が
# 要求する `capex_empirical_artifact_to_dict`・`save_capex_empirical_artifact`・
# `load_capex_empirical_artifact`・`capex_empirical_report`・`save_capex_empirical_report`
# の実体はここに置く）。
#
# Design: docs/architecture/capex_credit_cycle_empirical_integration.md §3.1・§4.3・§10.4・
#         §11（provenance/hash chain）・§12.7（統合・決定性）。
#
# depends on: data/capex_credit_cycle_catalog.jl（`CapexSeriesSpec`・`capex_series_catalog_to_dict`）・
# data/capex_credit_cycle_provider.jl（`CapexRawDataset`・`CapexRawObservation`）・
# data/capex_credit_cycle_measurements.jl（`CapexEmpiricalDataset`）・
# analysis/capex_credit_cycle_calibration.jl（`CapexEmpiricalCalibration`・`capex_calibration_to_dict`）・
# analysis/capex_credit_cycle_identification.jl（`CapexIdentificationDiagnostic`・
# `capex_identification_to_dict`）・analysis/capex_credit_cycle_estimation.jl
# （`CapexParameterSet`・`capex_parameter_set_to_dict`）・analysis/capex_credit_cycle_history.jl
# （`CapexHistoricalEpisodeSpec`・`CapexEpisodeAssessment`・`capex_episode_spec_to_dict`・
# `capex_episode_assessment_to_dict`）・analysis/capex_credit_cycle_historical_replay.jl
# （`CapexHistoricalReplayRun`・`capex_historical_replay_run_to_dict`・`_capex_replay_json_num`）・
# analysis/capex_credit_cycle_empirical_validation.jl（`CapexEmpiricalValidationReport`・
# `capex_empirical_validation_report_to_dict`・`_capex_validation_json_value`）・
# analysis/capex_credit_cycle_empirical_sensitivity.jl（`EmpiricalRobustnessReport`・
# `capex_empirical_sensitivity_report_to_dict`）・artifacts/json_canonical.jl
# （`canonical_json_bytes`、`save_scenario_artifact`/`save_real_rate_model_artifact` と同じ
# atomic-write idiom）。

"本層の methodology version。"
const CAPEX_CC_EMPIRICAL_ARTIFACT_VERSION = "capex-credit-cycle-empirical-artifact/1.0.0"

# ---------------------------------------------------------------------------
# 正準 JSON のアトミック書き込み（`real_rate_model_artifact_export.jl`・
# `scenario_serialization.jl` と同じ idiom）
# ---------------------------------------------------------------------------

function _capex_empirical_write_json(path::AbstractString, value)::String
    dir = dirname(path)
    isempty(dir) || mkpath(dir)
    tmp_path = path * ".tmp"
    bytes = canonical_json_bytes(value)
    try
        open(tmp_path, "w") do io
            write(io, bytes)
            flush(io)
            @static if Sys.isunix()
                ccall(:fsync, Cint, (Cint,), fd(io))
            end
        end
        mv(tmp_path, path; force = true)
    catch
        isfile(tmp_path) && rm(tmp_path; force = true)
        rethrow()
    end
    return path
end

# ---------------------------------------------------------------------------
# raw observation manifest（新設。`CapexRawDataset` に to_dict が無いため）
# ---------------------------------------------------------------------------

function _capex_raw_observation_to_dict(obs::CapexRawObservation)::Dict{String, Any}
    series = obs.series
    return Dict{String, Any}(
        "key" => String(obs.key),
        "status" => String(obs.status),
        "provider_unit" => ismissing(obs.provider_unit) ? nothing : obs.provider_unit,
        "provider_frequency" =>
            ismissing(obs.provider_frequency) ? nothing : string(obs.provider_frequency),
        "provider_seasonal_adjustment" =>
            ismissing(obs.provider_seasonal_adjustment) ? nothing :
            obs.provider_seasonal_adjustment,
        "provider_vintage" =>
            ismissing(obs.provider_vintage) ? nothing : obs.provider_vintage,
        "metadata_mismatches" => obs.metadata_mismatches,
        "mode" => String(obs.mode),
        "detail" => obs.detail,
        "n_obs" => series === nothing ? 0 : length(series.values),
        "date_start" =>
            series === nothing || isempty(series.dates) ? nothing : first(series.dates),
        "date_end" =>
            series === nothing || isempty(series.dates) ? nothing : last(series.dates),
        "values" =>
            series === nothing ? nothing :
            [_capex_replay_json_num(v) for v in series.values],
    )
end

"""
    capex_raw_dataset_to_dict(raw::CapexRawDataset) -> Dict{String, Any}

`CapexRawDataset`（#242）を再現可能な辞書へ変換する（raw observation manifest）。
provider の値・provider metadata を保持するが、API キー・トークン・credential を含む URL・
ローカル絶対パスは含めない（`raw.provider_base` は scheme+host のみを保持する契約、
`capex_credit_cycle_provider.jl` の `_capex_safe_provider_base` 参照）。非有限値は
JSON `null` として保存する（`0` 化しない）。
"""
function capex_raw_dataset_to_dict(raw::CapexRawDataset)::Dict{String, Any}
    return Dict{String, Any}(
        "catalog_version" => raw.catalog_version,
        "integration_version" => raw.integration_version,
        "provider_base" => raw.provider_base,
        "quality_flags" => _capex_validation_json_value(raw.quality_flags),
        "observations" => Dict{String, Any}(
            String(k) => _capex_raw_observation_to_dict(o) for (k, o) in raw.observations
        ),
        "metadata" => _capex_validation_json_value(raw.metadata),
    )
end

"""
    save_capex_raw_dataset(path, raw::CapexRawDataset) -> String

[`capex_raw_dataset_to_dict`](@ref) を正準 JSON として `path` へ atomic に保存する。
"""
function save_capex_raw_dataset(path::AbstractString, raw::CapexRawDataset)::String
    return _capex_empirical_write_json(path, capex_raw_dataset_to_dict(raw))
end

# ---------------------------------------------------------------------------
# measured dataset manifest（新設。`CapexEmpiricalDataset` に to_dict が無いため）
# ---------------------------------------------------------------------------

function _capex_measurement_to_dict(
    meas::CapexMeasurement,
    ds::CapexEmpiricalDataset,
)::Dict{String, Any}
    return Dict{String, Any}(
        "conversion_formula" => meas.conversion_formula,
        "deflator_key" =>
            meas.deflator_key === nothing ? nothing : String(meas.deflator_key),
        "anchor_detail" => meas.anchor_detail,
        "allocation_key" =>
            meas.allocation_key === nothing ? nothing : String(meas.allocation_key),
        "allocation_shares" => meas.allocation_shares,
        "n_source_missing" => meas.n_source_missing,
        "n_invalid" => meas.n_invalid,
        "warnings" => meas.warnings,
        "role" => String(get(ds.roles, meas.key, :unknown)),
        "observability" => String(get(ds.observability, meas.key, :unknown)),
    )
end

"""
    capex_measurement_manifest_to_dict(ds::CapexEmpiricalDataset) -> Dict{String, Any}

`CapexEmpiricalDataset`（#243）を再現可能な辞書へ変換する（measured dataset manifest）。
`dataset_hash` は `ds.metadata` からそのまま転記する（本関数では計算し直さない。
実証統合設計 §11.3）。`:E`/`:A` 分類のキーは `ds.values` に値を持たない契約（#243）を
そのまま反映する。非有限値は JSON `null` として保存する。
"""
function capex_measurement_manifest_to_dict(ds::CapexEmpiricalDataset)::Dict{String, Any}
    measurements = Dict{String, Any}(
        String(k) => _capex_measurement_to_dict(meas, ds) for (k, meas) in ds.measurements
    )
    return Dict{String, Any}(
        "dates" => ds.dates,
        "sample" => Dict{String, Any}(
            "sample_start" => ds.sample.sample_start,
            "sample_end" => ds.sample.sample_end,
            "n_obs" => ds.sample.n_obs,
            "binding_series" => sort(String.(ds.sample.binding_series)),
            "dropped_dates" => ds.sample.dropped_dates,
            "exclusion_reasons" => ds.sample.exclusion_reasons,
        ),
        "vintage_mode" => String(ds.vintage_mode),
        "quality_flags" => _capex_validation_json_value(ds.quality_flags),
        "measurements" => measurements,
        "values" => Dict{String, Any}(
            String(k) => [_capex_replay_json_num(v) for v in vec] for (k, vec) in ds.values
        ),
        "roles" => Dict{String, Any}(String(k) => String(v) for (k, v) in ds.roles),
        "observability" =>
            Dict{String, Any}(String(k) => String(v) for (k, v) in ds.observability),
        "metadata" => _capex_validation_json_value(ds.metadata),
    )
end

"""
    save_capex_measurement_manifest(path, ds::CapexEmpiricalDataset) -> String

[`capex_measurement_manifest_to_dict`](@ref) を正準 JSON として `path` へ atomic に保存する。
"""
function save_capex_measurement_manifest(
    path::AbstractString,
    ds::CapexEmpiricalDataset,
)::String
    return _capex_empirical_write_json(path, capex_measurement_manifest_to_dict(ds))
end

# ---------------------------------------------------------------------------
# canonical artifact（7段の identity chain。実証統合設計 §11.2）
# ---------------------------------------------------------------------------

"""
    capex_empirical_artifact_to_dict(; catalog, raw, dataset, calibration, identification,
                                      parameter_sets, episode, episode_assessment=nothing,
                                      replay_runs, validation, robustness) -> Dict{String,Any}

catalog（#241）→ raw observation（#242）→ measurement/dataset（#243）→ 較正（#244）→
識別（#245）→ 推定・parameter set（#246）→ episode 選定（#247）→ 履歴再生（#248）→
検証（#249）→ robustness（#250）の全出力を1つの canonical artifact へ束ね、
`catalog_version → dataset_hash → targets_hash → parameter_set_hash → replay_hash`
（および `episode_hash`）の identity chain を `"identity"` へ保持する（実証統合設計 §11.2）。

- `parameter_sets`・`replay_runs` は `kind`（`:literature_default`/`:calibrated`/`:estimated`）を
  キーとする辞書。**literature/default と calibrated/estimated を区別して並置する**
  （実証統合設計 §9.1 契約4・#170 §10）。
- `episode_assessment` は `assess_capex_episodes` の結果（`nothing` の場合は識別できない
  ことを明示する。episode_hash 自体は `replay_runs` の各 run が既に保持する）。
- `SimulationResult`・実証層の既存の結果型は一切変更しない（読み取り専用の集約）。
- 秘密情報（API キー・URL・ローカル絶対パス）は含めない（各段の to_dict の契約を継承）。
"""
function capex_empirical_artifact_to_dict(;
    catalog::AbstractVector{<:CapexSeriesSpec},
    raw::CapexRawDataset,
    dataset::CapexEmpiricalDataset,
    calibration::CapexEmpiricalCalibration,
    identification::AbstractVector{<:CapexIdentificationDiagnostic},
    identification_config::CapexIdentificationConfig = CapexIdentificationConfig(),
    parameter_sets::AbstractDict{Symbol, CapexParameterSet},
    episode::CapexHistoricalEpisodeSpec,
    episode_assessment::Union{CapexEpisodeAssessment, Nothing} = nothing,
    replay_runs::AbstractDict{Symbol, CapexHistoricalReplayRun},
    validation::CapexEmpiricalValidationReport,
    robustness::EmpiricalRobustnessReport,
)::Dict{String, Any}
    dataset_hash = get(dataset.metadata, "dataset_hash", "")
    targets_hash = calibration.targets_hash

    identity = Dict{String, Any}(
        "catalog_version" => raw.catalog_version,
        "integration_version" => raw.integration_version,
        "dataset_hash" => dataset_hash,
        "targets_hash" => targets_hash,
        "parameter_set_hash" => Dict{String, Any}(
            String(k) => ps.parameter_set_hash for (k, ps) in parameter_sets
        ),
        "episode_hash" =>
            Dict{String, Any}(String(k) => r.episode_hash for (k, r) in replay_runs),
        "event_set_hash" =>
            Dict{String, Any}(String(k) => r.event_set_hash for (k, r) in replay_runs),
        "replay_hash" =>
            Dict{String, Any}(String(k) => r.replay_hash for (k, r) in replay_runs),
    )

    return Dict{String, Any}(
        "artifact_version" => CAPEX_CC_EMPIRICAL_ARTIFACT_VERSION,
        "identity" => identity,
        "catalog" => capex_series_catalog_to_dict(catalog),
        "raw_observation" => capex_raw_dataset_to_dict(raw),
        "measurement" => capex_measurement_manifest_to_dict(dataset),
        "calibration" => capex_calibration_to_dict(calibration),
        "identification" => capex_identification_to_dict(
            identification;
            config = identification_config,
            dataset_hash = dataset_hash,
            targets_hash = targets_hash,
        ),
        "parameter_sets" => Dict{String, Any}(
            String(k) => capex_parameter_set_to_dict(ps) for (k, ps) in parameter_sets
        ),
        "episode" => Dict{String, Any}(
            "spec" => capex_episode_spec_to_dict(episode),
            "assessment" =>
                episode_assessment === nothing ? nothing :
                capex_episode_assessment_to_dict(episode_assessment),
        ),
        "replay" => Dict{String, Any}(
            String(k) => capex_historical_replay_run_to_dict(r) for (k, r) in replay_runs
        ),
        "validation" => capex_empirical_validation_report_to_dict(validation),
        "robustness" => capex_empirical_sensitivity_report_to_dict(robustness),
    )
end

"""
    save_capex_empirical_artifact(dir, artifact::AbstractDict) -> Vector{String}

[`capex_empirical_artifact_to_dict`](@ref) の出力を `dir` 配下へ正準 JSON として分離保存する
（`save_scenario_artifact`・`save_real_rate_model_artifact` と同じ atomic-write idiom）。
`artifact.json` は identity chain と各ファイルへの索引のみを保持する軽量な manifest であり、
各段の完全な内容は分離したファイルに保存する（実証統合設計 §4.1 の成果物候補と同じ分離規約）。

書き出すファイル: `artifact.json`（identity・version・file index）・`catalog.json`・
`raw_observation_manifest.json`・`measurement_manifest.json`・`calibration.json`・
`identification.json`・`parameter_set_<kind>.json`（kind ごと）・`episode.json`・
`replay_<kind>.json`（kind ごと）・`validation.json`・`robustness.json`。
"""
function save_capex_empirical_artifact(
    dir::AbstractString,
    artifact::AbstractDict,
)::Vector{String}
    mkpath(dir)
    paths = String[]
    file_index = Dict{String, String}()

    function write_section!(filename::AbstractString, value)
        path = joinpath(dir, filename)
        push!(paths, _capex_empirical_write_json(path, value))
        file_index[filename] = filename
        return nothing
    end

    write_section!("catalog.json", artifact["catalog"])
    write_section!("raw_observation_manifest.json", artifact["raw_observation"])
    write_section!("measurement_manifest.json", artifact["measurement"])
    write_section!("calibration.json", artifact["calibration"])
    write_section!("identification.json", artifact["identification"])
    for (kind, ps) in artifact["parameter_sets"]
        write_section!("parameter_set_$(kind).json", ps)
    end
    write_section!("episode.json", artifact["episode"])
    for (kind, run) in artifact["replay"]
        write_section!("replay_$(kind).json", run)
    end
    write_section!("validation.json", artifact["validation"])
    write_section!("robustness.json", artifact["robustness"])

    manifest = Dict{String, Any}(
        "artifact_version" => artifact["artifact_version"],
        "identity" => artifact["identity"],
        "files" => file_index,
    )
    pushfirst!(paths, _capex_empirical_write_json(joinpath(dir, "artifact.json"), manifest))
    return paths
end

"""
    load_capex_empirical_artifact(dir::AbstractString) -> Dict{String, Any}

`save_capex_empirical_artifact` が `dir` へ書き出した `artifact.json` の file index に従って
各ファイルを読み込み、`capex_empirical_artifact_to_dict` と同じキー構造の辞書を再構築する
（監査・決定性確認用。実証統合設計 §12.7 項目61）。数値・hash は JSON の型（`JSON3.Object`/
`Vector`/`String`/`Number`/`nothing`）で返る。Julia の型（`CapexEmpiricalDataset` 等）へは
再構築しない（他段の to_dict も同じ「監査用の辞書化であり完全な再水和はしない」規約）。
"""
function load_capex_empirical_artifact(dir::AbstractString)::Dict{String, Any}
    manifest_path = joinpath(dir, "artifact.json")
    isfile(manifest_path) ||
        throw(ArgumentError("artifact.json が見つかりません: $(manifest_path)"))
    manifest = JSON3.read(read(manifest_path, String))

    out = Dict{String, Any}(
        "artifact_version" =>
            _capex_validation_json_value(manifest["artifact_version"]),
        "identity" => _capex_validation_json_value(manifest["identity"]),
    )

    parameter_sets = Dict{String, Any}()
    replay = Dict{String, Any}()
    for (filename, _) in pairs(manifest["files"])
        fname = String(filename)
        path = joinpath(dir, fname)
        value = _capex_validation_json_value(JSON3.read(read(path, String)))
        if fname == "catalog.json"
            out["catalog"] = value
        elseif fname == "raw_observation_manifest.json"
            out["raw_observation"] = value
        elseif fname == "measurement_manifest.json"
            out["measurement"] = value
        elseif fname == "calibration.json"
            out["calibration"] = value
        elseif fname == "identification.json"
            out["identification"] = value
        elseif fname == "episode.json"
            out["episode"] = value
        elseif fname == "validation.json"
            out["validation"] = value
        elseif fname == "robustness.json"
            out["robustness"] = value
        elseif startswith(fname, "parameter_set_") && endswith(fname, ".json")
            kind = fname[(length("parameter_set_") + 1):(end - length(".json"))]
            parameter_sets[kind] = value
        elseif startswith(fname, "replay_") && endswith(fname, ".json")
            kind = fname[(length("replay_") + 1):(end - length(".json"))]
            replay[kind] = value
        end
    end
    out["parameter_sets"] = parameter_sets
    out["replay"] = replay
    return out
end

# ---------------------------------------------------------------------------
# 人間可読レポート（Markdown。実証統合設計 §10.4 の caveats を必ず含める）
# ---------------------------------------------------------------------------

"""
    capex_empirical_report(artifact::AbstractDict) -> String

[`capex_empirical_artifact_to_dict`](@ref) の出力から、人間可読な Markdown レポートを組み立てる
（`_scenario_report_markdown` と同じ「機械的要約であり投資判断・政策提言の根拠ではない」規律）。
実証統合設計 §10.4 の caveats 8件（`CAPEX_CC_EMPIRICAL_VALIDATION_CAVEATS`）と
robustness の caveats（`CAPEX_CC_EMPIRICAL_SENSITIVITY_CAVEATS`）を必ず含める。
"""
function capex_empirical_report(artifact::AbstractDict)::String
    io = IOBuffer()
    identity = artifact["identity"]
    validation = artifact["validation"]
    episode = artifact["episode"]

    println(io, "# CCC Empirical Integration Report")
    println(io)
    println(io, "- artifact_version: `$(artifact["artifact_version"])`")
    println(io, "- catalog_version: `$(identity["catalog_version"])`")
    println(io, "- dataset_hash: `$(identity["dataset_hash"])`")
    println(io, "- targets_hash: `$(identity["targets_hash"])`")
    println(io, "- parameter_set_hash: $(identity["parameter_set_hash"])")
    println(io, "- episode_hash: $(identity["episode_hash"])")
    println(io, "- replay_hash: $(identity["replay_hash"])")
    println(io)

    println(io, "## Episode")
    println(io)
    spec = episode["spec"]
    println(io, "- id: `$(spec["id"])`")
    println(io, "- label: $(spec["label"])")
    assessment = get(episode, "assessment", nothing)
    if assessment === nothing
        println(io, "- assessment: (not evaluated against `assess_capex_episodes`)")
    else
        println(io, "- assessment status: `$(assessment["status"])`")
        println(io, "- exclusion_reason: $(assessment["exclusion_reason"])")
    end
    println(io)

    println(io, "## Validation summary")
    println(io)
    println(io, "- diagnostic_label: `$(validation["diagnostic_label"])`")
    n_applicable = count(
        f -> get(f, "applicability", nothing) == "applicable",
        values(validation["fits"]),
    )
    println(
        io,
        "- fits evaluated (applicability=applicable): $(n_applicable) / $(length(validation["fits"]))",
    )
    println(io)

    println(io, "## Robustness summary")
    println(io)
    robustness = artifact["robustness"]
    for (axis, status) in robustness["axis_status"]
        println(io, "- `$(axis)`: $(status["status"]) (n_variants=$(status["n_variants"]))")
    end
    println(io)

    println(io, "## Caveats")
    println(io)
    for c in CAPEX_CC_EMPIRICAL_VALIDATION_CAVEATS
        println(io, "- ", c)
    end
    for c in CAPEX_CC_EMPIRICAL_SENSITIVITY_CAVEATS
        println(io, "- ", c)
    end
    println(io)

    println(io, "## Notes")
    println(io)
    println(
        io,
        "本レポートは #241–#251 の実証パイプラインを機械的に要約したものであり、" *
        "投資判断・政策提言を目的としない。fit は因果妥当性・景気後退確率ではない" *
        "（ADR 0012 決定24）。「その時点で判断できた」「当時利用可能だった情報で再現した」" *
        "という主張はしない（`:as_of` 非対応、`Z-21`）。",
    )
    return String(take!(io))
end

"""
    save_capex_empirical_report(path, artifact::AbstractDict) -> String

[`capex_empirical_report`](@ref) を `path` へ書き出す（人間可読な Markdown。秘密情報は含めない）。
"""
function save_capex_empirical_report(path::AbstractString, artifact::AbstractDict)::String
    dir = dirname(path)
    isempty(dir) || mkpath(dir)
    write(path, capex_empirical_report(artifact))
    return path
end
