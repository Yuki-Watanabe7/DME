# DME real-rate model artifact — economic-data-provider ADR 006 / cross-repository JSON Schema
# (`docs/contract/dme-real-rate-model-artifact.schema.json`) に対応する型群。
#
# 規約（詳細は docs/adr/0008-real-rate-model-artifact-export.md）:
#   - すべて keyword constructor + `ArgumentError` バリデーション（`model_capabilities.jl` /
#     `sfc/types.jl` と同じ doctrine）。
#   - `artifact_id` / `parameter_hash` / `calibration_hash` / `snapshot_hash` は構造体が
#     自前で計算する。呼び出し側はこれらを引数として渡せない（自己参照を構造的に排除する）。
#   - `to_dict` が正準化・hash 計算・保存の単一の真実源。`from_dict` はハッシュ系フィールドを
#     再計算し、読み込んだ値と突き合わせて改ざん・破損を検出する。
#   - `timing.generated_at` のみを identity から除外する非対称ロジックは `compute_artifact_id`
#     の1箇所に集約する。

const REAL_RATE_ARTIFACT_SCHEMA_VERSION = "1.0.0"
const REAL_RATE_ARTIFACT_TYPE = "dme.real_rate_model"
const REAL_RATE_ARTIFACT_MODEL_ID = "dme.new_keynesian"
const REAL_RATE_ARTIFACT_CODE_REPOSITORY = "https://github.com/Yuki-Watanabe7/DME"

const RRA_COUNTRIES = ("US", "JP")
const RRA_CALENDAR_TIMEZONE_BY_COUNTRY =
    Dict("US" => "America/New_York", "JP" => "Asia/Tokyo")
const RRA_METRICS = (
    :current_inflation,
    :expected_inflation,
    :inflation_target,
    :nominal_policy_rate,
    :model_implied_real_policy_rate,
    :natural_real_rate,
)
const RRA_EXPECTATION_METRICS = (:expected_inflation, :model_implied_real_policy_rate)
const RRA_RATE_BASIS = (:per_model_period, :annualized)
const RRA_FREQUENCIES = (:daily, :monthly, :quarterly, :annual)
const RRA_VALUE_TYPES = (:level, :deviation)
const RRA_STATUSES = (:valid, :invalid)
const RRA_DERIVATION_METHODS = (:model_output, :parameter, :derived)
const RRA_CALIBRATION_KINDS = (:fixture, :synthetic, :empirical)
const RRA_SNAPSHOT_KINDS = (:none, :provider_snapshot, :custom)
const RRA_OUTPUT_KINDS = (:steady_state, :trajectory, :irf)
const RRA_PURPOSES = (:comparison, :diagnostic)
const RRA_HORIZON_KINDS = (:not_applicable, :expectation)
const RRA_AGGREGATIONS = (:none, :one_step_ahead, :arithmetic_mean, :compounded_path)

# MVP がサポートする horizon のみを固定テーブルで表現する。5Y/10Y term structure は
# 経路自体を用意しない（`Horizon` コンストラクタがこのテーブル外の duration を拒否する）。
# P1Y は複利（`compounded_path`）ではなく4四半期の年率換算値の単純平均
# （`arithmetic_mean`）を採用する。詳細は docs/adr/0008-*.md を参照。
const RRA_HORIZON_SPECS = Dict(
    "P3M" => (model_periods = 1, aggregation = :one_step_ahead),
    "P1Y" => (model_periods = 4, aggregation = :arithmetic_mean),
)

const _RRA_OBSERVATION_ID_RE = r"^[a-z0-9][a-z0-9._:-]*$"
const _RRA_COMMIT_SHA_RE = r"^[0-9a-f]{40}$"
const _RRA_SEMVER_RE =
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"
const _RRA_SHA256_RE = r"^sha256:[0-9a-f]{64}$"

# ---------------------------------------------------------------------------
# バリデーションヘルパー
# ---------------------------------------------------------------------------

function _rra_check_nonempty(s::AbstractString, name::AbstractString)
    isempty(s) && throw(ArgumentError("$name は空文字列にできません"))
    return nothing
end

function _rra_check_enum(x::Symbol, allowed::Tuple, name::AbstractString)
    x in allowed ||
        throw(ArgumentError("$name は $(allowed) のいずれかである必要があります: $x"))
    return nothing
end

function _rra_check_semver(s::AbstractString, name::AbstractString)
    occursin(_RRA_SEMVER_RE, s) ||
        throw(ArgumentError("$name は semver 形式である必要があります: $s"))
    return nothing
end

function _rra_check_commit_sha(s::AbstractString)
    occursin(_RRA_COMMIT_SHA_RE, s) ||
        throw(ArgumentError("code_commit_sha は40桁小文字16進数である必要があります: $s"))
    return nothing
end

function _rra_check_sha256_identity(s::AbstractString, name::AbstractString)
    occursin(_RRA_SHA256_RE, s) ||
        throw(ArgumentError("$name は sha256:<64桁16進> 形式である必要があります: $s"))
    return nothing
end

function _rra_check_observation_id(s::AbstractString)
    occursin(_RRA_OBSERVATION_ID_RE, s) ||
        throw(ArgumentError("observation_id の形式が不正です: $s"))
    return nothing
end

function _rra_check_unique_strings(v::Vector{String}, name::AbstractString)
    length(unique(v)) == length(v) || throw(ArgumentError("$name に重複があります: $v"))
    return nothing
end

_rra_format_date(d::Date) = Dates.format(d, dateformat"yyyy-mm-dd")
_rra_parse_date(s::AbstractString) = Date(s, dateformat"yyyy-mm-dd")

_rra_format_datetime(dt::DateTime) = Dates.format(dt, dateformat"yyyy-mm-ddTHH:MM:SS") * "Z"
function _rra_parse_datetime(s::AbstractString)
    endswith(s, "Z") || throw(
        ArgumentError(
            "timestamp は UTC (\"...Z\" 接尾辞) のみサポートします（MVP 制約）: $s",
        ),
    )
    return DateTime(s[1:(end - 1)], dateformat"yyyy-mm-ddTHH:MM:SS")
end

# ---------------------------------------------------------------------------
# ModelIdentity
# ---------------------------------------------------------------------------

struct ModelIdentity
    model_id::String
    model_version::String
    code_repository::String
    code_commit_sha::String
    solver_id::String
    solver_version::String
    solver_method::String
end

function ModelIdentity(;
    model_version::AbstractString,
    code_commit_sha::AbstractString,
    solver_id::AbstractString,
    solver_version::AbstractString,
    solver_method::AbstractString,
    model_id::AbstractString = REAL_RATE_ARTIFACT_MODEL_ID,
    code_repository::AbstractString = REAL_RATE_ARTIFACT_CODE_REPOSITORY,
)
    model_id == REAL_RATE_ARTIFACT_MODEL_ID || throw(
        ArgumentError("model_id は \"$(REAL_RATE_ARTIFACT_MODEL_ID)\" 固定です: $model_id"),
    )
    code_repository == REAL_RATE_ARTIFACT_CODE_REPOSITORY || throw(
        ArgumentError(
            "code_repository は \"$(REAL_RATE_ARTIFACT_CODE_REPOSITORY)\" 固定です: $code_repository",
        ),
    )
    _rra_check_semver(model_version, "model_version")
    _rra_check_commit_sha(code_commit_sha)
    _rra_check_nonempty(solver_id, "solver.solver_id")
    _rra_check_nonempty(solver_version, "solver.solver_version")
    _rra_check_nonempty(solver_method, "solver.method")
    return ModelIdentity(
        String(model_id),
        String(model_version),
        String(code_repository),
        String(code_commit_sha),
        String(solver_id),
        String(solver_version),
        String(solver_method),
    )
end

function to_dict(m::ModelIdentity)::Dict{String, Any}
    Dict{String, Any}(
        "model_id" => m.model_id,
        "model_version" => m.model_version,
        "code_repository" => m.code_repository,
        "code_commit_sha" => m.code_commit_sha,
        "solver" => Dict{String, Any}(
            "solver_id" => m.solver_id,
            "solver_version" => m.solver_version,
            "method" => m.solver_method,
        ),
    )
end

function model_identity_from_dict(d::AbstractDict)
    solver = d["solver"]
    return ModelIdentity(;
        model_id = d["model_id"],
        model_version = d["model_version"],
        code_repository = d["code_repository"],
        code_commit_sha = d["code_commit_sha"],
        solver_id = solver["solver_id"],
        solver_version = solver["solver_version"],
        solver_method = solver["method"],
    )
end

# ---------------------------------------------------------------------------
# ParameterSet
# ---------------------------------------------------------------------------

struct ParameterSet
    parameter_set_id::String
    parameter_hash::String
    values::Dict{String, Float64}
end

function ParameterSet(; parameter_set_id::AbstractString, values::AbstractDict)
    _rra_check_nonempty(parameter_set_id, "parameter_set_id")
    isempty(values) && throw(ArgumentError("parameter_set.values は最低1件必要です"))
    vals = Dict{String, Float64}()
    for (k, v) in values
        v isa Real ||
            throw(ArgumentError("parameter_set.values[$k] は数値である必要があります"))
        fv = Float64(v)
        isfinite(fv) || throw(
            ArgumentError("parameter_set.values[$k] は有限数である必要があります: $fv"),
        )
        vals[String(k)] = fv
    end
    hash = sha256_hex_of_canonical(Dict{String, Any}(k => v for (k, v) in vals))
    return ParameterSet(String(parameter_set_id), "sha256:" * hash, vals)
end

function to_dict(p::ParameterSet)::Dict{String, Any}
    Dict{String, Any}(
        "parameter_set_id" => p.parameter_set_id,
        "parameter_hash" => p.parameter_hash,
        "values" => Dict{String, Any}(k => v for (k, v) in p.values),
    )
end

function parameter_set_from_dict(d::AbstractDict)
    ps = ParameterSet(;
        parameter_set_id = d["parameter_set_id"],
        values = Dict{String, Float64}(String(k) => Float64(v) for (k, v) in d["values"]),
    )
    ps.parameter_hash == d["parameter_hash"] || throw(
        ArgumentError(
            "parameter_hash が再計算値と一致しません（改ざんまたは破損の可能性）",
        ),
    )
    return ps
end

# ---------------------------------------------------------------------------
# Calibration
# ---------------------------------------------------------------------------

struct Calibration
    calibration_id::String
    calibration_version::String
    calibration_kind::Symbol
    calibration_hash::String
end

function Calibration(;
    calibration_id::AbstractString,
    calibration_version::AbstractString,
    calibration_kind::Symbol,
)
    _rra_check_nonempty(calibration_id, "calibration_id")
    _rra_check_semver(calibration_version, "calibration_version")
    _rra_check_enum(calibration_kind, RRA_CALIBRATION_KINDS, "calibration_kind")
    payload = Dict{String, Any}(
        "calibration_id" => String(calibration_id),
        "calibration_version" => String(calibration_version),
        "calibration_kind" => String(calibration_kind),
    )
    hash = sha256_hex_of_canonical(payload)
    return Calibration(
        String(calibration_id),
        String(calibration_version),
        calibration_kind,
        "sha256:" * hash,
    )
end

function to_dict(c::Calibration)::Dict{String, Any}
    Dict{String, Any}(
        "calibration_id" => c.calibration_id,
        "calibration_version" => c.calibration_version,
        "calibration_kind" => String(c.calibration_kind),
        "calibration_hash" => c.calibration_hash,
    )
end

function calibration_from_dict(d::AbstractDict)
    c = Calibration(;
        calibration_id = d["calibration_id"],
        calibration_version = d["calibration_version"],
        calibration_kind = Symbol(d["calibration_kind"]),
    )
    c.calibration_hash == d["calibration_hash"] || throw(
        ArgumentError(
            "calibration_hash が再計算値と一致しません（改ざんまたは破損の可能性）",
        ),
    )
    return c
end

# ---------------------------------------------------------------------------
# InputSource / InputSnapshot
# ---------------------------------------------------------------------------

struct InputSource
    source_id::String
    source_version::String
    content_hash::String
end

function InputSource(;
    source_id::AbstractString,
    source_version::AbstractString,
    content_hash::AbstractString,
)
    _rra_check_nonempty(source_id, "input_snapshot.sources[].source_id")
    _rra_check_nonempty(source_version, "input_snapshot.sources[].source_version")
    _rra_check_sha256_identity(content_hash, "input_snapshot.sources[].content_hash")
    return InputSource(String(source_id), String(source_version), String(content_hash))
end

function to_dict(s::InputSource)::Dict{String, Any}
    Dict{String, Any}(
        "source_id" => s.source_id,
        "source_version" => s.source_version,
        "content_hash" => s.content_hash,
    )
end

input_source_from_dict(d::AbstractDict) = InputSource(;
    source_id = d["source_id"],
    source_version = d["source_version"],
    content_hash = d["content_hash"],
)

struct InputSnapshot
    snapshot_id::String
    snapshot_kind::Symbol
    snapshot_hash::String
    sources::Vector{InputSource}
end

function InputSnapshot(;
    snapshot_id::AbstractString,
    snapshot_kind::Symbol,
    sources::AbstractVector{InputSource} = InputSource[],
)
    _rra_check_nonempty(snapshot_id, "input_snapshot.snapshot_id")
    _rra_check_enum(snapshot_kind, RRA_SNAPSHOT_KINDS, "input_snapshot.snapshot_kind")
    srcs = collect(InputSource, sources)
    length(unique(srcs)) == length(srcs) ||
        throw(ArgumentError("input_snapshot.sources に重複があります"))
    payload = Dict{String, Any}(
        "snapshot_id" => String(snapshot_id),
        "snapshot_kind" => String(snapshot_kind),
        "sources" => [to_dict(s) for s in srcs],
    )
    hash = sha256_hex_of_canonical(payload)
    return InputSnapshot(String(snapshot_id), snapshot_kind, "sha256:" * hash, srcs)
end

function to_dict(s::InputSnapshot)::Dict{String, Any}
    Dict{String, Any}(
        "snapshot_id" => s.snapshot_id,
        "snapshot_kind" => String(s.snapshot_kind),
        "snapshot_hash" => s.snapshot_hash,
        "sources" => [to_dict(x) for x in s.sources],
    )
end

function input_snapshot_from_dict(d::AbstractDict)
    snap = InputSnapshot(;
        snapshot_id = d["snapshot_id"],
        snapshot_kind = Symbol(d["snapshot_kind"]),
        sources = InputSource[input_source_from_dict(s) for s in d["sources"]],
    )
    snap.snapshot_hash == d["snapshot_hash"] || throw(
        ArgumentError("snapshot_hash が再計算値と一致しません（改ざんまたは破損の可能性）"),
    )
    return snap
end

# ---------------------------------------------------------------------------
# RunIdentity
# ---------------------------------------------------------------------------

struct RunIdentity
    country::String
    calendar_timezone::String
    scenario_id::String
    run_id::String
    output_kind::Symbol
    purpose::Symbol
end

function RunIdentity(;
    country::AbstractString,
    scenario_id::AbstractString,
    run_id::AbstractString,
    output_kind::Symbol,
    purpose::Symbol,
    calendar_timezone::Union{AbstractString, Nothing} = nothing,
)
    country in RRA_COUNTRIES || throw(
        ArgumentError(
            "run.country は $(RRA_COUNTRIES) のいずれかである必要があります: $country",
        ),
    )
    tz =
        calendar_timezone === nothing ? RRA_CALENDAR_TIMEZONE_BY_COUNTRY[country] :
        String(calendar_timezone)
    _rra_check_nonempty(tz, "run.calendar_timezone")
    _rra_check_nonempty(scenario_id, "run.scenario_id")
    _rra_check_nonempty(run_id, "run.run_id")
    _rra_check_enum(output_kind, RRA_OUTPUT_KINDS, "run.output_kind")
    _rra_check_enum(purpose, RRA_PURPOSES, "run.purpose")
    return RunIdentity(
        String(country),
        tz,
        String(scenario_id),
        String(run_id),
        output_kind,
        purpose,
    )
end

function to_dict(r::RunIdentity)::Dict{String, Any}
    Dict{String, Any}(
        "country" => r.country,
        "calendar_timezone" => r.calendar_timezone,
        "scenario_id" => r.scenario_id,
        "run_id" => r.run_id,
        "output_kind" => String(r.output_kind),
        "purpose" => String(r.purpose),
    )
end

run_identity_from_dict(d::AbstractDict) = RunIdentity(;
    country = d["country"],
    calendar_timezone = d["calendar_timezone"],
    scenario_id = d["scenario_id"],
    run_id = d["run_id"],
    output_kind = Symbol(d["output_kind"]),
    purpose = Symbol(d["purpose"]),
)

# ---------------------------------------------------------------------------
# Timing
# ---------------------------------------------------------------------------

struct Timing
    decision_time::DateTime
    data_cutoff_at::DateTime
    generated_at::DateTime
end

function Timing(; decision_time::DateTime, data_cutoff_at::DateTime, generated_at::DateTime)
    data_cutoff_at <= decision_time || throw(
        ArgumentError(
            "timing.data_cutoff_at ($data_cutoff_at) は timing.decision_time ($decision_time) 以前である必要があります（look-ahead 防止）",
        ),
    )
    decision_time <= generated_at || throw(
        ArgumentError(
            "timing.decision_time ($decision_time) は timing.generated_at ($generated_at) 以前である必要があります",
        ),
    )
    return Timing(decision_time, data_cutoff_at, generated_at)
end

function to_dict(t::Timing)::Dict{String, Any}
    Dict{String, Any}(
        "decision_time" => _rra_format_datetime(t.decision_time),
        "data_cutoff_at" => _rra_format_datetime(t.data_cutoff_at),
        "generated_at" => _rra_format_datetime(t.generated_at),
    )
end

timing_from_dict(d::AbstractDict) = Timing(;
    decision_time = _rra_parse_datetime(d["decision_time"]),
    data_cutoff_at = _rra_parse_datetime(d["data_cutoff_at"]),
    generated_at = _rra_parse_datetime(d["generated_at"]),
)

# ---------------------------------------------------------------------------
# ModelPeriod
# ---------------------------------------------------------------------------

struct ModelPeriod
    index::Int
    label::String
end

function ModelPeriod(; index::Integer, label::AbstractString)
    index >= 0 ||
        throw(ArgumentError("model_period.index は0以上である必要があります: $index"))
    _rra_check_nonempty(label, "model_period.label")
    return ModelPeriod(Int(index), String(label))
end

to_dict(p::ModelPeriod)::Dict{String, Any} =
    Dict{String, Any}("index" => p.index, "label" => p.label)

model_period_from_dict(d::AbstractDict) =
    ModelPeriod(; index = d["index"], label = d["label"])

# ---------------------------------------------------------------------------
# Horizon
# ---------------------------------------------------------------------------

struct Horizon
    kind::Symbol
    duration::Union{String, Nothing}
    model_periods::Union{Int, Nothing}
    aggregation::Symbol
end

function Horizon(;
    kind::Symbol,
    duration::Union{AbstractString, Nothing} = nothing,
    model_periods::Union{Integer, Nothing} = nothing,
    aggregation::Symbol = :none,
)
    _rra_check_enum(kind, RRA_HORIZON_KINDS, "horizon.kind")
    _rra_check_enum(aggregation, RRA_AGGREGATIONS, "horizon.aggregation")
    if kind == :not_applicable
        (duration === nothing && model_periods === nothing) || throw(
            ArgumentError(
                "horizon.kind=:not_applicable のとき duration/model_periods は null である必要があります",
            ),
        )
        aggregation == :none || throw(
            ArgumentError(
                "horizon.kind=:not_applicable のとき aggregation は :none である必要があります",
            ),
        )
        return Horizon(:not_applicable, nothing, nothing, :none)
    else
        duration === nothing &&
            throw(ArgumentError("horizon.kind=:expectation のとき duration は必須です"))
        d = String(duration)
        haskey(RRA_HORIZON_SPECS, d) || throw(
            ArgumentError(
                "サポートされていない horizon.duration です: $d（対応: $(join(sort(collect(keys(RRA_HORIZON_SPECS))), ", "))）。5Y/10Y term structure は現行 New Keynesian モデルから生成しません。",
            ),
        )
        spec = RRA_HORIZON_SPECS[d]
        mp = model_periods === nothing ? spec.model_periods : Int(model_periods)
        mp == spec.model_periods || throw(
            ArgumentError(
                "horizon.duration=$d の model_periods は $(spec.model_periods) である必要があります（実際: $mp）",
            ),
        )
        agg = aggregation == :none ? spec.aggregation : aggregation
        agg == spec.aggregation || throw(
            ArgumentError(
                "horizon.duration=$d の aggregation は :$(spec.aggregation) である必要があります（実際: :$agg）",
            ),
        )
        return Horizon(:expectation, d, mp, agg)
    end
end

"""`horizon.kind = :not_applicable` の `Horizon` を返す。"""
horizon_not_applicable() = Horizon(; kind = :not_applicable)

"""
    horizon_expectation(duration::AbstractString) -> Horizon

MVP がサポートする `"P3M"` または `"P1Y"` の `Horizon` を返す（`model_periods`・
`aggregation` は `RRA_HORIZON_SPECS` から自動的に決まる）。
"""
horizon_expectation(duration::AbstractString) =
    Horizon(; kind = :expectation, duration = duration)

function to_dict(h::Horizon)::Dict{String, Any}
    Dict{String, Any}(
        "kind" => String(h.kind),
        "duration" => h.duration,
        "model_periods" => h.model_periods,
        "aggregation" => String(h.aggregation),
    )
end

horizon_from_dict(d::AbstractDict) = Horizon(;
    kind = Symbol(d["kind"]),
    duration = d["duration"],
    model_periods = d["model_periods"],
    aggregation = Symbol(d["aggregation"]),
)

# ---------------------------------------------------------------------------
# Derivation / Provenance
# ---------------------------------------------------------------------------

struct Derivation
    method::Symbol
    formula::String
    input_observation_ids::Vector{String}
    parameter_names::Vector{String}
    solver_outputs::Vector{String}
end

function Derivation(;
    method::Symbol,
    formula::AbstractString,
    input_observation_ids::AbstractVector{<:AbstractString} = String[],
    parameter_names::AbstractVector{<:AbstractString} = String[],
    solver_outputs::AbstractVector{<:AbstractString} = String[],
)
    _rra_check_enum(method, RRA_DERIVATION_METHODS, "derivation.method")
    _rra_check_nonempty(formula, "derivation.formula")
    ids = String.(input_observation_ids)
    pn = String.(parameter_names)
    so = String.(solver_outputs)
    _rra_check_unique_strings(ids, "derivation.input_observation_ids")
    _rra_check_unique_strings(pn, "derivation.parameter_names")
    _rra_check_unique_strings(so, "derivation.solver_outputs")
    return Derivation(method, String(formula), ids, pn, so)
end

function to_dict(d::Derivation)::Dict{String, Any}
    Dict{String, Any}(
        "method" => String(d.method),
        "formula" => d.formula,
        "input_observation_ids" => d.input_observation_ids,
        "parameter_names" => d.parameter_names,
        "solver_outputs" => d.solver_outputs,
    )
end

derivation_from_dict(d::AbstractDict) = Derivation(;
    method = Symbol(d["method"]),
    formula = d["formula"],
    input_observation_ids = String.(d["input_observation_ids"]),
    parameter_names = String.(d["parameter_names"]),
    solver_outputs = String.(d["solver_outputs"]),
)

struct Provenance
    source_kind::Symbol
    source_names::Vector{String}
    notes::Vector{String}
end

function Provenance(;
    source_kind::Symbol,
    source_names::AbstractVector{<:AbstractString} = String[],
    notes::AbstractVector{<:AbstractString} = String[],
)
    _rra_check_enum(source_kind, RRA_DERIVATION_METHODS, "provenance.source_kind")
    sn = String.(source_names)
    _rra_check_unique_strings(sn, "provenance.source_names")
    ns = String.(notes)
    any(isempty, ns) &&
        throw(ArgumentError("provenance.notes の各要素は空文字列にできません"))
    return Provenance(source_kind, sn, ns)
end

function to_dict(p::Provenance)::Dict{String, Any}
    Dict{String, Any}(
        "source_kind" => String(p.source_kind),
        "source_names" => p.source_names,
        "notes" => p.notes,
    )
end

provenance_from_dict(d::AbstractDict) = Provenance(;
    source_kind = Symbol(d["source_kind"]),
    source_names = String.(d["source_names"]),
    notes = String.(d["notes"]),
)

# ---------------------------------------------------------------------------
# ModelObservation
# ---------------------------------------------------------------------------

struct ModelObservation
    observation_id::String
    country::String
    metric::Symbol
    rate_type::String
    tenor::String
    unit::String
    rate_basis::Symbol
    frequency::Symbol
    model_period::ModelPeriod
    calendar_date::Union{Date, Nothing}
    horizon::Horizon
    value_type::Symbol
    value::Union{Float64, Nothing}
    status::Symbol
    validity_reasons::Vector{String}
    warnings::Vector{String}
    derivation::Derivation
    provenance::Provenance
end

function ModelObservation(;
    observation_id::AbstractString,
    country::AbstractString,
    metric::Symbol,
    model_period::ModelPeriod,
    horizon::Horizon,
    value_type::Symbol,
    value::Union{Real, Nothing},
    status::Symbol,
    derivation::Derivation,
    provenance::Provenance,
    calendar_date::Union{Date, Nothing} = nothing,
    validity_reasons::AbstractVector{<:AbstractString} = String[],
    warnings::AbstractVector{<:AbstractString} = String[],
    rate_type::AbstractString = "policy",
    tenor::AbstractString = "overnight",
    unit::AbstractString = "percent",
    rate_basis::Symbol = :annualized,
    frequency::Symbol = :quarterly,
)
    _rra_check_observation_id(observation_id)
    country in RRA_COUNTRIES || throw(
        ArgumentError(
            "observation.country は $(RRA_COUNTRIES) のいずれかである必要があります: $country",
        ),
    )
    metric in RRA_METRICS || throw(ArgumentError("observation.metric が不正です: $metric"))
    rate_type == "policy" || throw(
        ArgumentError(
            "observation.rate_type は \"policy\" 固定です（MVP スコープ外）: $rate_type",
        ),
    )
    tenor == "overnight" || throw(
        ArgumentError(
            "observation.tenor は \"overnight\" 固定です（MVP スコープ外）: $tenor",
        ),
    )
    unit == "percent" ||
        throw(ArgumentError("observation.unit は \"percent\" 固定です: $unit"))
    _rra_check_enum(rate_basis, RRA_RATE_BASIS, "observation.rate_basis")
    _rra_check_enum(frequency, RRA_FREQUENCIES, "observation.frequency")
    _rra_check_enum(value_type, RRA_VALUE_TYPES, "observation.value_type")
    _rra_check_enum(status, RRA_STATUSES, "observation.status")

    expected_kind = metric in RRA_EXPECTATION_METRICS ? :expectation : :not_applicable
    horizon.kind == expected_kind || throw(
        ArgumentError(
            "observation.metric=$(metric) は horizon.kind=:$(expected_kind) である必要があります（実際: :$(horizon.kind)）",
        ),
    )

    reasons = String.(validity_reasons)
    warns = String.(warnings)
    _rra_check_unique_strings(warns, "observation.warnings")

    local stored_value::Union{Float64, Nothing}
    if status == :valid
        value === nothing &&
            throw(ArgumentError("observation.status=:valid のとき value は必須です"))
        v = Float64(value)
        isfinite(v) || throw(
            ArgumentError(
                "observation.status=:valid のとき value は有限数である必要があります: $v",
            ),
        )
        isempty(reasons) || throw(
            ArgumentError(
                "observation.status=:valid のとき validity_reasons は空である必要があります",
            ),
        )
        stored_value = v
    else
        value === nothing || throw(
            ArgumentError(
                "observation.status=:invalid のとき value は null である必要があります",
            ),
        )
        isempty(reasons) && throw(
            ArgumentError(
                "observation.status=:invalid のとき validity_reasons は最低1件必要です",
            ),
        )
        stored_value = nothing
    end

    return ModelObservation(
        String(observation_id),
        String(country),
        metric,
        String(rate_type),
        String(tenor),
        String(unit),
        rate_basis,
        frequency,
        model_period,
        calendar_date,
        horizon,
        value_type,
        stored_value,
        status,
        reasons,
        warns,
        derivation,
        provenance,
    )
end

function to_dict(o::ModelObservation)::Dict{String, Any}
    Dict{String, Any}(
        "observation_id" => o.observation_id,
        "country" => o.country,
        "metric" => String(o.metric),
        "rate_type" => o.rate_type,
        "tenor" => o.tenor,
        "unit" => o.unit,
        "rate_basis" => String(o.rate_basis),
        "frequency" => String(o.frequency),
        "model_period" => to_dict(o.model_period),
        "calendar_date" =>
            o.calendar_date === nothing ? nothing : _rra_format_date(o.calendar_date),
        "horizon" => to_dict(o.horizon),
        "value_type" => String(o.value_type),
        "value" => o.value,
        "status" => String(o.status),
        "validity_reasons" => o.validity_reasons,
        "warnings" => o.warnings,
        "derivation" => to_dict(o.derivation),
        "provenance" => to_dict(o.provenance),
    )
end

function model_observation_from_dict(d::AbstractDict)
    cd = d["calendar_date"]
    return ModelObservation(;
        observation_id = d["observation_id"],
        country = d["country"],
        metric = Symbol(d["metric"]),
        rate_type = d["rate_type"],
        tenor = d["tenor"],
        unit = d["unit"],
        rate_basis = Symbol(d["rate_basis"]),
        frequency = Symbol(d["frequency"]),
        model_period = model_period_from_dict(d["model_period"]),
        calendar_date = cd === nothing ? nothing : _rra_parse_date(cd),
        horizon = horizon_from_dict(d["horizon"]),
        value_type = Symbol(d["value_type"]),
        value = d["value"],
        status = Symbol(d["status"]),
        validity_reasons = String.(d["validity_reasons"]),
        warnings = String.(d["warnings"]),
        derivation = derivation_from_dict(d["derivation"]),
        provenance = provenance_from_dict(d["provenance"]),
    )
end

# ---------------------------------------------------------------------------
# RealRateModelArtifact
# ---------------------------------------------------------------------------

struct RealRateModelArtifact
    schema_version::String
    artifact_type::String
    artifact_id::String
    model::ModelIdentity
    parameter_set::ParameterSet
    calibration::Calibration
    input_snapshot::InputSnapshot
    run::RunIdentity
    timing::Timing
    observations::Vector{ModelObservation}
    warnings::Vector{String}
end

"""
`generated_at` のみを除いた文書全体（`schema_version`・`artifact_type` を含む）から
`artifact_id`（`"sha256:" * hex`）を計算する。`generated_at` を除外する非対称ロジックは
ここに集約する。
"""
function compute_artifact_id(full_dict_without_artifact_id::AbstractDict)::String
    identity = deepcopy(full_dict_without_artifact_id)
    timing = deepcopy(identity["timing"])
    delete!(timing, "generated_at")
    identity["timing"] = timing
    return "sha256:" * sha256_hex_of_canonical(identity)
end

function _rra_validate_real_rate_arithmetic(observations::Vector{ModelObservation})
    by_id = Dict(o.observation_id => o for o in observations)
    for o in observations
        o.metric == :model_implied_real_policy_rate || continue
        o.status == :valid || continue
        ids = o.derivation.input_observation_ids
        length(ids) == 2 || throw(
            ArgumentError(
                "model_implied_real_policy_rate observation '$(o.observation_id)' の derivation.input_observation_ids は nominal_policy_rate と expected_inflation の2件である必要があります",
            ),
        )
        refs = ModelObservation[]
        for id in ids
            haskey(by_id, id) || throw(
                ArgumentError(
                    "model_implied_real_policy_rate observation '$(o.observation_id)' が参照する observation_id '$id' が observations 内に見つかりません",
                ),
            )
            push!(refs, by_id[id])
        end
        nominal_idx = findfirst(r -> r.metric == :nominal_policy_rate, refs)
        expected_idx = findfirst(r -> r.metric == :expected_inflation, refs)
        (nominal_idx === nothing || expected_idx === nothing) && throw(
            ArgumentError(
                "model_implied_real_policy_rate observation '$(o.observation_id)' の input_observation_ids は nominal_policy_rate と expected_inflation を1件ずつ参照する必要があります",
            ),
        )
        nominal_obs = refs[nominal_idx]
        expected_obs = refs[expected_idx]
        (nominal_obs.status == :valid && expected_obs.status == :valid) || throw(
            ArgumentError(
                "model_implied_real_policy_rate observation '$(o.observation_id)' が参照する observation が invalid です",
            ),
        )
        expected_diff = nominal_obs.value - expected_obs.value
        isapprox(o.value, expected_diff; atol = 1e-9) || throw(
            ArgumentError(
                "model_implied_real_policy_rate observation '$(o.observation_id)' の value ($(o.value)) が nominal_policy_rate - expected_inflation ($expected_diff) と許容誤差1e-9で一致しません",
            ),
        )
    end
    return nothing
end

function RealRateModelArtifact(;
    model::ModelIdentity,
    parameter_set::ParameterSet,
    calibration::Calibration,
    input_snapshot::InputSnapshot,
    run::RunIdentity,
    timing::Timing,
    observations::AbstractVector{ModelObservation},
    warnings::AbstractVector{<:AbstractString} = String[],
)
    obs = sort(collect(ModelObservation, observations); by = o -> o.observation_id)
    ids = [o.observation_id for o in obs]
    _rra_check_unique_strings(ids, "observations[].observation_id")
    length(obs) >= 3 || throw(ArgumentError("observations は最低3件必要です"))
    for metric in
        (:expected_inflation, :nominal_policy_rate, :model_implied_real_policy_rate)
        any(o -> o.metric == metric, obs) ||
            throw(ArgumentError("observations に metric=$(metric) が最低1件必要です"))
    end
    _rra_validate_real_rate_arithmetic(obs)

    warns = String.(warnings)
    _rra_check_unique_strings(warns, "warnings")

    base = Dict{String, Any}(
        "schema_version" => REAL_RATE_ARTIFACT_SCHEMA_VERSION,
        "artifact_type" => REAL_RATE_ARTIFACT_TYPE,
        "model" => to_dict(model),
        "parameter_set" => to_dict(parameter_set),
        "calibration" => to_dict(calibration),
        "input_snapshot" => to_dict(input_snapshot),
        "run" => to_dict(run),
        "timing" => to_dict(timing),
        "observations" => [to_dict(o) for o in obs],
        "warnings" => warns,
    )
    artifact_id = compute_artifact_id(base)

    return RealRateModelArtifact(
        REAL_RATE_ARTIFACT_SCHEMA_VERSION,
        REAL_RATE_ARTIFACT_TYPE,
        artifact_id,
        model,
        parameter_set,
        calibration,
        input_snapshot,
        run,
        timing,
        obs,
        warns,
    )
end

function to_dict(a::RealRateModelArtifact)::Dict{String, Any}
    Dict{String, Any}(
        "schema_version" => a.schema_version,
        "artifact_type" => a.artifact_type,
        "artifact_id" => a.artifact_id,
        "model" => to_dict(a.model),
        "parameter_set" => to_dict(a.parameter_set),
        "calibration" => to_dict(a.calibration),
        "input_snapshot" => to_dict(a.input_snapshot),
        "run" => to_dict(a.run),
        "timing" => to_dict(a.timing),
        "observations" => [to_dict(o) for o in a.observations],
        "warnings" => a.warnings,
    )
end

"""`to_dict` を正準 JSON 文字列へ変換する（保存・hash計算と同じ経路）。"""
to_json(a::RealRateModelArtifact)::String = canonical_json_string(to_dict(a))

function real_rate_model_artifact_from_dict(d::AbstractDict)
    d["schema_version"] == REAL_RATE_ARTIFACT_SCHEMA_VERSION || throw(
        ArgumentError(
            "unsupported_schema_version: このパッケージがサポートするのは $(REAL_RATE_ARTIFACT_SCHEMA_VERSION) のみです（実際: $(d["schema_version"])）",
        ),
    )
    d["artifact_type"] == REAL_RATE_ARTIFACT_TYPE ||
        throw(ArgumentError("artifact_type が不正です: $(d["artifact_type"])"))

    a = RealRateModelArtifact(;
        model = model_identity_from_dict(d["model"]),
        parameter_set = parameter_set_from_dict(d["parameter_set"]),
        calibration = calibration_from_dict(d["calibration"]),
        input_snapshot = input_snapshot_from_dict(d["input_snapshot"]),
        run = run_identity_from_dict(d["run"]),
        timing = timing_from_dict(d["timing"]),
        observations = ModelObservation[
            model_observation_from_dict(o) for o in d["observations"]
        ],
        warnings = String.(d["warnings"]),
    )
    a.artifact_id == d["artifact_id"] || throw(
        ArgumentError(
            "artifact_id が再計算値と一致しません（改ざんまたは破損の可能性）: $(d["artifact_id"]) != $(a.artifact_id)",
        ),
    )
    return a
end

_rra_to_plain(x::JSON3.Object) =
    Dict{String, Any}(String(k) => _rra_to_plain(v) for (k, v) in pairs(x))
_rra_to_plain(x::JSON3.Array) = Any[_rra_to_plain(v) for v in x]
_rra_to_plain(x) = x

real_rate_model_artifact_from_json(s::AbstractString) =
    real_rate_model_artifact_from_dict(_rra_to_plain(JSON3.read(s)))
