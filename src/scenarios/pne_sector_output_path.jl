# pne_sector_output_path.jl: production-network-engine（PNE）の
# `production-network-sector-output-path/v1` artifact を DME 側で受理する層（Issue #281 /
# `PN-1` の `X1`）。
#
# PNE artifact を**観測事実ではなく上流モデルの導出結果**として受理する。DME は PNE の
# Python package を import せず（`UM-8`）、PNE の JSON Schema の制約と
# `x-semantic-invariants` を本ファイルで個別に再実装する（ADR 0008 と同じ「汎用 JSON Schema
# バリデータを内蔵しない」doctrine）。
#
# 失敗の返し方（設計 §5.2・§11.1）:
#   - decode 不能な文書（必須キー欠落・未知キー・型/固定値/語彙違反・非有限値・意味論的不変条件
#     違反）は「そのような artifact は存在しえない」ため `ArgumentError` を投げる。メッセージは
#     `PNE_DECODE_ERROR_CODES` のいずれかで始まる。
#   - decode 可能だが適用してはならない artifact（`status = unsupported`・error 警告）は本層では
#     拒否せず、互換性判定（`cross_model_compatibility.jl`）が構造化拒否として返す。
#
# identity（設計 §5.3）:
#   - `content_hash`: parse 後の文書全体の RFC 8785 正準 JSON の SHA-256（`"sha256:…"`）。
#     DME 内での上流 artifact の正本 identity。
#   - `source_bytes_sha256`: 読み込んだファイルのバイト列の SHA-256。監査用であり hash 対象外。
#   - PNE 自身の `hash_document` 値・`artifact_id` の導出式は再計算しない（`PG-09`）。
#
# 設計契約:
#   docs/architecture/pne_sector_output_integration.md §2.1・§3.3・§5
#   docs/adr/0024-pne-sector-output-cross-model-input-contract.md 決定 1・3・4
# 上流契約（PNE 側が正本。vendor コピー: docs/contract/pne/）:
#   production-network-sector-output-path-v1.schema.json

# ===========================================================================
# 契約 version と固定語彙
# ===========================================================================

"cross-model input 契約（設計 `docs/architecture/pne_sector_output_integration.md`）の version。"
const CROSS_MODEL_INPUT_CONTRACT_VERSION = "cross-model-input/1.0.0"

"PNE の sector output path 契約の識別子（PNE 側が正本）。"
const PNE_SECTOR_OUTPUT_PATH_CONTRACT = "production-network-sector-output-path/v1"

"""
DME が受理する PNE sector output path の `schema_version`（完全一致）。PNE v2 等の受理は
実装変更と設計・ADR 0024 の改訂を要する（設計 §5.1）。
"""
const PNE_SECTOR_OUTPUT_PATH_ACCEPTED_SCHEMA_VERSIONS = (PNE_SECTOR_OUTPUT_PATH_CONTRACT,)

"""
PNE の損失比不変条件・回復判定に用いる絶対許容誤差（PNE の
`output_loss_ratio ≈ 1 − realized_output_ratio` 検査と同じ `1e-12`）。
"""
const PNE_RATIO_ABS_TOL = 1e-12

"PNE の `period_unit` 語彙（ラベルであって換算係数ではない。PNE `PeriodCalendar`）。"
const PNE_PERIOD_UNITS = (:baseline_period, :day, :week, :month, :quarter, :year)

"PNE の推定ステータス語彙（node・edge・sector の `source_data_status`）。"
const PNE_ESTIMATION_STATUSES = (:observed, :estimated, :inferred, :synthetic)

"PNE artifact の `status` 語彙。`:unsupported` の部分値は consumer が適用してはならない。"
const PNE_ARTIFACT_STATUSES = (:complete, :unsupported)

"PNE 警告の `severity` 語彙。"
const PNE_WARNING_SEVERITIES = (:info, :warning, :error)

"""
PNE artifact の decode 失敗（`ArgumentError`）のメッセージ先頭に置くコード（設計 §5.2・§11.1）。
構造化拒否コード（`CROSS_MODEL_REJECTION_CODES`）とは別の、層(1)の語彙である。
"""
const PNE_DECODE_ERROR_CODES = (
    :unsupported_upstream_schema_version,
    :upstream_schema_violation,
    :upstream_semantic_invariant_violation,
)

"上流 artifact の DME 内での役割（固定値、設計 §3.3）。"
const UPSTREAM_MODEL_DERIVED_RESULT_ROLE = :upstream_model_derived_endogenous_result

const _PNE_IDENTIFIER_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9._:@/+-]*$"
const _PNE_HASH_PATTERN = r"^sha256:[0-9a-f]{64}$"
const _PNE_WARNING_SOURCES = ("source_dynamic_artifact", "sector_output_exporter")

const _PNE_TOP_LEVEL_KEYS = (
    "schema_version",
    "artifact_id",
    "status",
    "source",
    "producer",
    "result_type_boundary",
    "geography",
    "geography_compatibility",
    "classification",
    "aggregation",
    "time",
    "source_provenance",
    "scenario_assumptions",
    "model_assumptions",
    "export_assumptions",
    "sectors",
    "aggregate_path_definition",
    "aggregate_path",
    "warnings",
    "unsupported_reasons",
    "result_semantics",
)

const _PNE_SOURCE_KEYS = (
    "network_id",
    "source_input_hash",
    "dynamic_artifact_id",
    "dynamic_artifact_hash",
    "scenario_hash",
    "scenario_policy_hash",
    "scenario_config_hash",
    "export_config_hash",
)

# ===========================================================================
# decode ヘルパ（層(1)。すべて `ArgumentError`）
# ===========================================================================

_pne_fail(code::Symbol, msg::AbstractString) = throw(ArgumentError("$(code): $(msg)"))
_pne_schema_fail(msg::AbstractString) = _pne_fail(:upstream_schema_violation, msg)
_pne_invariant_fail(msg::AbstractString) =
    _pne_fail(:upstream_semantic_invariant_violation, msg)

"""
    _pne_object(v, label, required, optional = ()) -> AbstractDict

`v` がオブジェクトであり、必須キーをすべて持ち、未知キーを持たないことを検証する
（PNE schema は全階層 `additionalProperties: false`）。
"""
function _pne_object(v, label::AbstractString, required, optional = ())
    v isa AbstractDict || _pne_schema_fail("$(label) はオブジェクトでなければなりません")
    present = Set(String(k) for k in keys(v))
    missing_keys = sort([k for k in required if !(k in present)])
    isempty(missing_keys) ||
        _pne_schema_fail("$(label) に必須キーがありません: $(missing_keys)")
    allowed = Set{String}(vcat(collect(required), collect(optional)))
    unknown = sort([k for k in present if !(k in allowed)])
    isempty(unknown) || _pne_schema_fail("$(label) に未知のキーがあります: $(unknown)")
    return v
end

function _pne_string(
    v,
    label::AbstractString;
    minlen::Int = 1,
    maxlen::Union{Int, Nothing} = nothing,
    pattern::Union{Regex, Nothing} = nothing,
)
    v isa AbstractString || _pne_schema_fail("$(label) は文字列でなければなりません")
    n = length(v)
    n >= minlen || _pne_schema_fail("$(label) は $(minlen) 文字以上でなければなりません")
    (maxlen === nothing || n <= maxlen) ||
        _pne_schema_fail("$(label) は $(maxlen) 文字以下でなければなりません")
    (pattern === nothing || occursin(pattern, v)) ||
        _pne_schema_fail("$(label)=\"$(v)\" が形式 $(pattern.pattern) に一致しません")
    return String(v)
end

_pne_identifier(v, label::AbstractString) =
    _pne_string(v, label; maxlen = 200, pattern = _PNE_IDENTIFIER_PATTERN)

_pne_hash(v, label::AbstractString) = _pne_string(v, label; pattern = _PNE_HASH_PATTERN)

function _pne_const(v, expected, label::AbstractString)
    if expected === nothing
        v === nothing || _pne_schema_fail("$(label) は null でなければなりません")
    elseif expected isa Bool
        (v isa Bool && v == expected) ||
            _pne_schema_fail("$(label) は $(expected) でなければなりません")
    elseif expected isa Integer
        (v isa Integer && !(v isa Bool) && v == expected) ||
            _pne_schema_fail("$(label) は $(expected) でなければなりません")
    else
        (v isa AbstractString && v == expected) ||
            _pne_schema_fail("$(label) は \"$(expected)\" でなければなりません")
    end
    return v
end

function _pne_integer(v, label::AbstractString; min::Union{Int, Nothing} = nothing)
    (v isa Integer && !(v isa Bool)) ||
        _pne_schema_fail("$(label) は整数でなければなりません")
    (min === nothing || v >= min) ||
        _pne_schema_fail("$(label) は $(min) 以上でなければなりません（実値: $(v)）")
    return Int(v)
end

"数値（Bool・文字列を除く）を `Float64` へ写す。非有限値は PNE 契約違反として拒否する。"
function _pne_number(v, label::AbstractString)
    (v isa Real && !(v isa Bool)) || _pne_schema_fail(
        "$(label) は数値でなければなりません（実値の型: $(typeof(v))。\"NaN\"・\"Infinity\" 等の文字列は受理しません）",
    )
    x = Float64(v)
    isfinite(x) || _pne_schema_fail("$(label) は有限でなければなりません（実値: $(x)）")
    return x
end

function _pne_bool(v, label::AbstractString)
    v isa Bool || _pne_schema_fail("$(label) は真偽値でなければなりません")
    return v
end

function _pne_enum(v, label::AbstractString, vocab)
    s = _pne_string(v, label)
    sym = Symbol(s)
    sym in vocab || _pne_schema_fail(
        "$(label)=\"$(s)\" は $(collect(vocab)) のいずれかでなければなりません",
    )
    return sym
end

function _pne_string_list(v, label::AbstractString)
    v isa AbstractVector || _pne_schema_fail("$(label) は配列でなければなりません")
    return String[_pne_string(x, "$(label)[$(i)]"; minlen = 0) for (i, x) in enumerate(v)]
end

# ===========================================================================
# 型
# ===========================================================================

"PNE artifact の経済圏 identity。同一性は `(system, economy_id)` のみで判定し、`name` は表示用。"
struct PNEGeography
    system::String
    economy_id::String
    name::String
end

"PNE artifact の native sector classification identity。`sector_id` は opaque。"
struct PNEClassification
    system::String
    version::String
    level::String
end

"単位つきの水準（PNE は単位変換しない。DME も換算しない）。"
struct PNEQuantity
    value::Float64
    unit::String
end

"""
    PNESectorSeries

1 つの native sector の実現産出比パス。`realized_output_ratio[i]` は `period_index = i - 1` の値。
`source_label` は presentation only であり、DME は照合に用いない（設計 `UM-5`）。
"""
struct PNESectorSeries
    sector_id::String
    source_label::String
    source_data_status::Symbol
    baseline_output::Union{PNEQuantity, Nothing}
    realized_output_ratio::Vector{Float64}
    output_loss_ratio::Vector{Float64}
end

"PNE artifact の時間軸。`calendar_anchor` は PNE が解釈しない任意文字列のまま保持する。"
struct PNETimeAxis
    period_unit::Symbol
    horizon_periods::Int
    available_periods::Int
    calendar_anchor::Union{String, Nothing}
end

"PNE artifact の警告（source dynamic artifact 由来または exporter 由来）。"
struct PNEWarning
    code::String
    message::String
    severity::Symbol
    source::String
    context::Dict{String, String}
end

"PNE artifact が `status = unsupported` である理由。"
struct PNEUnsupportedReason
    code::String
    message::String
end

"PNE の `source`（network・scenario・dynamic result への content-addressed 参照）。DME は再計算しない。"
struct PNESourceReference
    network_id::String
    source_input_hash::String
    dynamic_artifact_id::String
    dynamic_artifact_hash::String
    scenario_hash::String
    scenario_policy_hash::String
    scenario_config_hash::String
    export_config_hash::String
end

"PNE の producer identity（`engine` は常に `production-network-engine`）。"
struct PNEProducer
    engine_version::String
    exporter_version::String
    algorithm_versions::Dict{String, String}
end

"PNE の `source_provenance` 要約。`references` は検証済みの plain `Dict` のまま保持する。"
struct PNESourceProvenance
    network_as_of::String
    is_synthetic::Bool
    node_estimation_status_counts::Dict{Symbol, Int}
    edge_estimation_status_counts::Dict{Symbol, Int}
    note::String
    references::Vector{Dict{String, Any}}
end

"""
    PNESectorOutputPath(doc::AbstractDict; source_bytes_sha256 = nothing)

受理済みの PNE `production-network-sector-output-path/v1` artifact（設計 §5、`X1`）。

**唯一の構築経路は plain `Dict`（JSON を parse したもの）からの decode** であり、PNE schema の
制約と `x-semantic-invariants` をすべて検証してから構築する。違反は `ArgumentError`
（メッセージは `PNE_DECODE_ERROR_CODES` のいずれかで始まる）。

`status = :unsupported` や error 警告を持つ artifact も decode できるが、モデルへ適用しては
ならない。適用可否は `check_cross_model_compatibility` が判定する。

## 主なフィールド
- `artifact_id`: PNE が付与した識別子（DME は導出式を再計算しない）。
- `status`: `:complete` / `:unsupported`。
- `geography::PNEGeography` / `classification::PNEClassification` / `time::PNETimeAxis`
- `sectors::Vector{PNESectorSeries}`: `sector_id` 昇順（PNE の不変条件）。
- `aggregate_realized_output_ratio`: PNE の baseline 加重集計パス（無い場合 `nothing`）。
  v1 ではいかなるモデル入力にも用いない（設計 §5.2）。
- `content_hash`: RFC 8785 正準 JSON の SHA-256（`"sha256:…"`）。DME 内での正本 identity。
- `source_bytes_sha256`: 読み込んだバイト列の SHA-256（`"sha256:…"`）または `nothing`。監査用。
"""
struct PNESectorOutputPath
    schema_version::String
    artifact_id::String
    status::Symbol
    source::PNESourceReference
    producer::PNEProducer
    geography::PNEGeography
    classification::PNEClassification
    time::PNETimeAxis
    source_provenance::PNESourceProvenance
    scenario_assumptions::Vector{String}
    model_assumptions::Vector{String}
    export_assumptions::Vector{String}
    sectors::Vector{PNESectorSeries}
    aggregate_realized_output_ratio::Union{Vector{Float64}, Nothing}
    warnings::Vector{PNEWarning}
    unsupported_reasons::Vector{PNEUnsupportedReason}
    result_semantics::String
    content_hash::String
    source_bytes_sha256::Union{String, Nothing}

    function PNESectorOutputPath(
        doc::AbstractDict;
        source_bytes_sha256::Union{AbstractString, Nothing} = nothing,
    )
        if source_bytes_sha256 !== nothing
            occursin(_PNE_HASH_PATTERN, source_bytes_sha256) || throw(
                ArgumentError(
                    "source_bytes_sha256 は \"sha256:\" + 64桁の小文字16進でなければなりません",
                ),
            )
        end
        fields = _pne_decode_document(doc)
        content_hash = try
            "sha256:" * sha256_hex_of_canonical(doc)
        catch e
            e isa ArgumentError || rethrow()
            _pne_schema_fail("RFC 8785 正準化できません（$(e.msg)）")
        end
        return new(
            fields...,
            content_hash,
            source_bytes_sha256 === nothing ? nothing : String(source_bytes_sha256),
        )
    end
end

# ===========================================================================
# decode 本体
# ===========================================================================

function _pne_decode_points(v, label::AbstractString, available_periods::Int)
    v isa AbstractVector || _pne_schema_fail("$(label) は配列でなければなりません")
    ratios = Float64[]
    losses = Float64[]
    for (i, p) in enumerate(v)
        pl = "$(label)[$(i)]"
        _pne_object(p, pl, ("period_index", "realized_output_ratio", "output_loss_ratio"))
        idx = _pne_integer(p["period_index"], "$(pl).period_index"; min = 0)
        r = _pne_number(p["realized_output_ratio"], "$(pl).realized_output_ratio")
        l = _pne_number(p["output_loss_ratio"], "$(pl).output_loss_ratio")
        (0.0 <= r <= 1.0) || _pne_schema_fail(
            "$(pl).realized_output_ratio は [0, 1] に含まれなければなりません（実値: $(r)）",
        )
        (0.0 <= l <= 1.0) || _pne_schema_fail(
            "$(pl).output_loss_ratio は [0, 1] に含まれなければなりません（実値: $(l)）",
        )
        idx == i - 1 || _pne_invariant_fail(
            "$(label) は period_index 0 から昇順に 1 つずつ並ばなければなりません（$(i) 番目が $(idx)）",
        )
        abs(l - (1.0 - r)) <= PNE_RATIO_ABS_TOL || _pne_invariant_fail(
            "$(pl): output_loss_ratio=$(l) が 1 - realized_output_ratio=$(1.0 - r) と一致しません" *
            "（許容誤差 $(PNE_RATIO_ABS_TOL)）",
        )
        push!(ratios, r)
        push!(losses, l)
    end
    length(ratios) == available_periods || _pne_invariant_fail(
        "$(label) は period_index 0 … $(available_periods - 1) をちょうど覆わなければなりません" *
        "（実際の件数: $(length(ratios))）",
    )
    return ratios, losses
end

function _pne_decode_source(v)
    _pne_object(v, "source", _PNE_SOURCE_KEYS)
    return PNESourceReference(
        _pne_identifier(v["network_id"], "source.network_id"),
        _pne_hash(v["source_input_hash"], "source.source_input_hash"),
        _pne_identifier(v["dynamic_artifact_id"], "source.dynamic_artifact_id"),
        _pne_hash(v["dynamic_artifact_hash"], "source.dynamic_artifact_hash"),
        _pne_hash(v["scenario_hash"], "source.scenario_hash"),
        _pne_hash(v["scenario_policy_hash"], "source.scenario_policy_hash"),
        _pne_hash(v["scenario_config_hash"], "source.scenario_config_hash"),
        _pne_hash(v["export_config_hash"], "source.export_config_hash"),
    )
end

function _pne_decode_producer(v)
    _pne_object(
        v,
        "producer",
        ("engine", "engine_version", "algorithm_versions", "exporter_version"),
    )
    _pne_const(v["engine"], "production-network-engine", "producer.engine")
    av = v["algorithm_versions"]
    av isa AbstractDict ||
        _pne_schema_fail("producer.algorithm_versions はオブジェクトでなければなりません")
    algorithm_versions = Dict{String, String}(
        String(k) => _pne_string(x, "producer.algorithm_versions.$(k)"; minlen = 0) for
        (k, x) in av
    )
    return PNEProducer(
        _pne_string(v["engine_version"], "producer.engine_version"; maxlen = 100),
        _pne_string(v["exporter_version"], "producer.exporter_version"; maxlen = 100),
        algorithm_versions,
    )
end

function _pne_decode_result_type_boundary(v)
    _pne_object(
        v,
        "result_type_boundary",
        ("source_network_data", "pne_scenario", "output_path", "downstream_application"),
    )
    _pne_const(
        v["source_network_data"],
        "source_data_with_declared_estimation_status",
        "result_type_boundary.source_network_data",
    )
    _pne_const(
        v["pne_scenario"],
        "pne_scenario_assumption",
        "result_type_boundary.pne_scenario",
    )
    _pne_const(
        v["output_path"],
        "pne_model_derived_endogenous_result",
        "result_type_boundary.output_path",
    )
    _pne_const(
        v["downstream_application"],
        "not_present",
        "result_type_boundary.downstream_application",
    )
    return nothing
end

function _pne_decode_geography(v)
    _pne_object(v, "geography", ("economy_id", "system", "name"))
    return PNEGeography(
        _pne_string(v["system"], "geography.system"; maxlen = 100),
        _pne_identifier(v["economy_id"], "geography.economy_id"),
        _pne_string(v["name"], "geography.name"; maxlen = 200),
    )
end

function _pne_decode_geography_compatibility(v, geography::PNEGeography)
    _pne_object(
        v,
        "geography_compatibility",
        (
            "mode",
            "compatible_economy_ids",
            "explicitly_modeled_cross_economy",
            "model_reference",
        ),
    )
    _pne_const(v["mode"], "same_economy_only", "geography_compatibility.mode")
    _pne_const(
        v["explicitly_modeled_cross_economy"],
        false,
        "geography_compatibility.explicitly_modeled_cross_economy",
    )
    _pne_const(v["model_reference"], nothing, "geography_compatibility.model_reference")
    ids = v["compatible_economy_ids"]
    (ids isa AbstractVector && length(ids) == 1) || _pne_schema_fail(
        "geography_compatibility.compatible_economy_ids はちょうど 1 要素の配列でなければなりません",
    )
    id = _pne_identifier(ids[1], "geography_compatibility.compatible_economy_ids[1]")
    id == geography.economy_id || _pne_invariant_fail(
        "same_economy_only の compatible_economy_ids=[\"$(id)\"] は geography.economy_id=" *
        "\"$(geography.economy_id)\" だけを指さなければなりません",
    )
    return nothing
end

function _pne_decode_classification(v)
    _pne_object(v, "classification", ("system", "version", "level", "sector_id_semantics"))
    _pne_const(v["sector_id_semantics"], "opaque", "classification.sector_id_semantics")
    return PNEClassification(
        _pne_string(v["system"], "classification.system"; maxlen = 200),
        _pne_string(v["version"], "classification.version"; maxlen = 100),
        _pne_string(v["level"], "classification.level"; maxlen = 100),
    )
end

function _pne_decode_aggregation(v)
    _pne_object(
        v,
        "aggregation",
        (
            "status",
            "mapping_artifact_hash",
            "weighted_aggregation_rule",
            "baseline_output_weighting",
            "unmapped_sector_treatment",
            "coverage",
        ),
    )
    _pne_const(v["status"], "native_sector_path", "aggregation.status")
    for k in (
        "mapping_artifact_hash",
        "weighted_aggregation_rule",
        "baseline_output_weighting",
        "unmapped_sector_treatment",
    )
        _pne_const(v[k], nothing, "aggregation.$(k)")
    end
    _pne_number(v["coverage"], "aggregation.coverage") == 1.0 ||
        _pne_schema_fail("aggregation.coverage は 1.0 でなければなりません")
    return nothing
end

function _pne_decode_time(v)
    _pne_object(
        v,
        "time",
        (
            "period_unit",
            "frequency",
            "period_index_origin",
            "horizon_periods",
            "available_periods",
            "calendar_anchor",
            "interval_semantics",
            "value_semantics",
            "rescaled_by_exporter",
        ),
    )
    unit = _pne_enum(v["period_unit"], "time.period_unit", PNE_PERIOD_UNITS)
    _pne_const(v["frequency"], 1, "time.frequency")
    _pne_const(v["period_index_origin"], 0, "time.period_index_origin")
    _pne_const(
        v["interval_semantics"],
        "start_inclusive_end_exclusive",
        "time.interval_semantics",
    )
    _pne_const(
        v["value_semantics"],
        "period_total_realized_output_ratio",
        "time.value_semantics",
    )
    _pne_const(v["rescaled_by_exporter"], false, "time.rescaled_by_exporter")
    horizon = _pne_integer(v["horizon_periods"], "time.horizon_periods"; min = 1)
    available = _pne_integer(v["available_periods"], "time.available_periods"; min = 0)
    available <= horizon || _pne_invariant_fail(
        "time.available_periods=$(available) が horizon_periods=$(horizon) を超えています",
    )
    anchor_raw = v["calendar_anchor"]
    anchor =
        anchor_raw === nothing ? nothing :
        _pne_string(anchor_raw, "time.calendar_anchor"; minlen = 0, maxlen = 40)
    return PNETimeAxis(unit, horizon, available, anchor)
end

function _pne_decode_status_counts(v, label::AbstractString)
    v isa AbstractDict || _pne_schema_fail("$(label) はオブジェクトでなければなりません")
    counts = Dict{Symbol, Int}()
    for (k, x) in v
        status = Symbol(String(k))
        status in PNE_ESTIMATION_STATUSES || _pne_schema_fail(
            "$(label) のキー \"$(k)\" は $(collect(PNE_ESTIMATION_STATUSES)) のいずれかでなければなりません",
        )
        counts[status] = _pne_integer(x, "$(label).$(k)")
    end
    return counts
end

function _pne_decode_source_provenance(v)
    _pne_object(
        v,
        "source_provenance",
        (
            "network_as_of",
            "is_synthetic",
            "node_estimation_status_counts",
            "edge_estimation_status_counts",
            "note",
        ),
        ("references",),
    )
    references = Dict{String, Any}[]
    if haskey(v, "references")
        refs = v["references"]
        refs isa AbstractVector ||
            _pne_schema_fail("source_provenance.references は配列でなければなりません")
        for (i, r) in enumerate(refs)
            rl = "source_provenance.references[$(i)]"
            _pne_object(
                r,
                rl,
                ("source", "source_version", "observation_start", "observation_end"),
                ("available_at",),
            )
            _pne_string(r["source"], "$(rl).source"; maxlen = 300)
            _pne_string(r["source_version"], "$(rl).source_version"; maxlen = 100)
            _pne_string(r["observation_start"], "$(rl).observation_start"; maxlen = 40)
            _pne_string(r["observation_end"], "$(rl).observation_end"; maxlen = 40)
            if haskey(r, "available_at") && r["available_at"] !== nothing
                _pne_string(r["available_at"], "$(rl).available_at")
            end
            push!(references, Dict{String, Any}(String(k) => x for (k, x) in r))
        end
    end
    return PNESourceProvenance(
        _pne_string(v["network_as_of"], "source_provenance.network_as_of"; maxlen = 40),
        _pne_bool(v["is_synthetic"], "source_provenance.is_synthetic"),
        _pne_decode_status_counts(
            v["node_estimation_status_counts"],
            "source_provenance.node_estimation_status_counts",
        ),
        _pne_decode_status_counts(
            v["edge_estimation_status_counts"],
            "source_provenance.edge_estimation_status_counts",
        ),
        _pne_string(v["note"], "source_provenance.note"; maxlen = 1000),
        references,
    )
end

function _pne_decode_sectors(v, available_periods::Int)
    (v isa AbstractVector && !isempty(v)) ||
        _pne_schema_fail("sectors は 1 要素以上の配列でなければなりません")
    sectors = PNESectorSeries[]
    for (i, s) in enumerate(v)
        sl = "sectors[$(i)]"
        _pne_object(
            s,
            sl,
            (
                "sector_id",
                "source_label",
                "source_label_semantics",
                "source_data_status",
                "periods",
            ),
            ("baseline_output",),
        )
        sector_id = _pne_identifier(s["sector_id"], "$(sl).sector_id")
        _pne_const(
            s["source_label_semantics"],
            "presentation_only",
            "$(sl).source_label_semantics",
        )
        baseline = nothing
        if haskey(s, "baseline_output") && s["baseline_output"] !== nothing
            q = _pne_object(
                s["baseline_output"],
                "$(sl).baseline_output",
                ("value", "unit"),
            )
            value = _pne_number(q["value"], "$(sl).baseline_output.value")
            value >= 0.0 || _pne_schema_fail(
                "$(sl).baseline_output.value は 0 以上でなければなりません",
            )
            baseline = PNEQuantity(
                value,
                _pne_string(q["unit"], "$(sl).baseline_output.unit"; maxlen = 50),
            )
        end
        ratios, losses =
            _pne_decode_points(s["periods"], "$(sl).periods", available_periods)
        push!(
            sectors,
            PNESectorSeries(
                sector_id,
                _pne_string(s["source_label"], "$(sl).source_label"; maxlen = 300),
                _pne_enum(
                    s["source_data_status"],
                    "$(sl).source_data_status",
                    PNE_ESTIMATION_STATUSES,
                ),
                baseline,
                ratios,
                losses,
            ),
        )
    end
    for i in 2:length(sectors)
        sectors[i - 1].sector_id < sectors[i].sector_id || _pne_invariant_fail(
            "sectors は opaque な sector_id の昇順かつ一意でなければなりません" *
            "（\"$(sectors[i - 1].sector_id)\" の後に \"$(sectors[i].sector_id)\"）",
        )
    end
    return sectors
end

function _pne_decode_aggregate_path_definition(v)
    _pne_object(
        v,
        "aggregate_path_definition",
        ("weighting", "ratio_semantics", "loss_semantics", "missing_baseline_treatment"),
    )
    _pne_const(
        v["weighting"],
        "source_baseline_output",
        "aggregate_path_definition.weighting",
    )
    _pne_const(
        v["ratio_semantics"],
        "baseline_output_weighted_mean_of_sector_realized_output_ratio",
        "aggregate_path_definition.ratio_semantics",
    )
    _pne_const(
        v["loss_semantics"],
        "one_minus_aggregate_output_ratio",
        "aggregate_path_definition.loss_semantics",
    )
    _pne_const(
        v["missing_baseline_treatment"],
        "aggregate_path_absent",
        "aggregate_path_definition.missing_baseline_treatment",
    )
    return nothing
end

function _pne_decode_warnings(v)
    v isa AbstractVector || _pne_schema_fail("warnings は配列でなければなりません")
    warnings = PNEWarning[]
    for (i, w) in enumerate(v)
        wl = "warnings[$(i)]"
        _pne_object(w, wl, ("code", "message", "severity", "source"), ("context",))
        context = Dict{String, String}()
        if haskey(w, "context")
            c = w["context"]
            c isa AbstractDict ||
                _pne_schema_fail("$(wl).context はオブジェクトでなければなりません")
            for (k, x) in c
                context[String(k)] = _pne_string(x, "$(wl).context.$(k)"; minlen = 0)
            end
        end
        source = _pne_string(w["source"], "$(wl).source")
        source in _PNE_WARNING_SOURCES || _pne_schema_fail(
            "$(wl).source=\"$(source)\" は $(collect(_PNE_WARNING_SOURCES)) のいずれかでなければなりません",
        )
        push!(
            warnings,
            PNEWarning(
                _pne_string(w["code"], "$(wl).code"; maxlen = 100),
                _pne_string(w["message"], "$(wl).message"; maxlen = 2000),
                _pne_enum(w["severity"], "$(wl).severity", PNE_WARNING_SEVERITIES),
                source,
                context,
            ),
        )
    end
    return warnings
end

function _pne_decode_unsupported_reasons(v)
    v isa AbstractVector ||
        _pne_schema_fail("unsupported_reasons は配列でなければなりません")
    reasons = PNEUnsupportedReason[]
    for (i, r) in enumerate(v)
        rl = "unsupported_reasons[$(i)]"
        _pne_object(r, rl, ("code", "message"))
        push!(
            reasons,
            PNEUnsupportedReason(
                _pne_string(r["code"], "$(rl).code"; maxlen = 100),
                _pne_string(r["message"], "$(rl).message"; maxlen = 1000),
            ),
        )
    end
    return reasons
end

"""
    _pne_decode_document(doc) -> Tuple

PNE v1 文書を検証し、`PNESectorOutputPath` の（hash 以外の）フィールドをフィールド順の
`Tuple` で返す。
"""
function _pne_decode_document(doc)
    doc isa AbstractDict ||
        _pne_schema_fail("PNE artifact のトップレベルはオブジェクトでなければなりません")
    haskey(doc, "schema_version") ||
        _pne_schema_fail("PNE artifact に必須キーがありません: [\"schema_version\"]")
    schema_version = doc["schema_version"]
    (
        schema_version isa AbstractString &&
        schema_version in PNE_SECTOR_OUTPUT_PATH_ACCEPTED_SCHEMA_VERSIONS
    ) || _pne_fail(
        :unsupported_upstream_schema_version,
        "DME が受理する schema_version は $(collect(PNE_SECTOR_OUTPUT_PATH_ACCEPTED_SCHEMA_VERSIONS)) の" *
        "いずれかです（実値: $(repr(schema_version))。設計 §5.1）",
    )
    _pne_object(doc, "PNE artifact", _PNE_TOP_LEVEL_KEYS)

    artifact_id = _pne_identifier(doc["artifact_id"], "artifact_id")
    status = _pne_enum(doc["status"], "status", PNE_ARTIFACT_STATUSES)
    source = _pne_decode_source(doc["source"])
    producer = _pne_decode_producer(doc["producer"])
    _pne_decode_result_type_boundary(doc["result_type_boundary"])
    geography = _pne_decode_geography(doc["geography"])
    _pne_decode_geography_compatibility(doc["geography_compatibility"], geography)
    classification = _pne_decode_classification(doc["classification"])
    _pne_decode_aggregation(doc["aggregation"])
    time = _pne_decode_time(doc["time"])
    provenance = _pne_decode_source_provenance(doc["source_provenance"])
    scenario_assumptions =
        _pne_string_list(doc["scenario_assumptions"], "scenario_assumptions")
    model_assumptions = _pne_string_list(doc["model_assumptions"], "model_assumptions")
    export_assumptions = _pne_string_list(doc["export_assumptions"], "export_assumptions")
    sectors = _pne_decode_sectors(doc["sectors"], time.available_periods)
    _pne_decode_aggregate_path_definition(doc["aggregate_path_definition"])
    aggregate =
        doc["aggregate_path"] === nothing ? nothing :
        first(
            _pne_decode_points(
                doc["aggregate_path"],
                "aggregate_path",
                time.available_periods,
            ),
        )
    warnings = _pne_decode_warnings(doc["warnings"])
    reasons = _pne_decode_unsupported_reasons(doc["unsupported_reasons"])
    result_semantics =
        _pne_string(doc["result_semantics"], "result_semantics"; maxlen = 1000)

    if status === :complete
        isempty(reasons) || _pne_invariant_fail(
            "status=complete の artifact は unsupported_reasons を持ってはいけません",
        )
        time.available_periods == time.horizon_periods || _pne_invariant_fail(
            "status=complete の artifact は horizon 全体（horizon_periods=$(time.horizon_periods)）を" *
            "覆わなければなりません（available_periods=$(time.available_periods)）",
        )
    else
        isempty(reasons) && _pne_invariant_fail(
            "status=unsupported の artifact は unsupported_reasons を 1 件以上持たなければなりません",
        )
    end

    return (
        String(schema_version),
        artifact_id,
        status,
        source,
        producer,
        geography,
        classification,
        time,
        provenance,
        scenario_assumptions,
        model_assumptions,
        export_assumptions,
        sectors,
        aggregate,
        warnings,
        reasons,
        result_semantics,
    )
end

# ===========================================================================
# 公開 API
# ===========================================================================

"""
    pne_sector_output_path_from_dict(doc::AbstractDict; source_bytes_sha256 = nothing)
        -> PNESectorOutputPath

plain `Dict`（JSON を parse したもの）から PNE artifact を受理する。`PNESectorOutputPath(doc)`
と同じ（設計 §5）。
"""
pne_sector_output_path_from_dict(
    doc::AbstractDict;
    source_bytes_sha256::Union{AbstractString, Nothing} = nothing,
) = PNESectorOutputPath(doc; source_bytes_sha256 = source_bytes_sha256)

"""
    load_pne_sector_output_path(path::AbstractString) -> PNESectorOutputPath

JSON ファイルから PNE artifact を受理する。読み込んだバイト列の SHA-256 を
`source_bytes_sha256` として保持する（監査用。hash 対象外）。JSON として解釈できない
ファイルは `upstream_schema_violation` の `ArgumentError`。
"""
function load_pne_sector_output_path(path::AbstractString)
    bytes = read(path)
    parsed = try
        json_read(String(copy(bytes)))
    catch e
        _pne_schema_fail("$(basename(path)) を JSON として解釈できません（$(typeof(e))）")
    end
    doc = _scenario_json_to_plain(parsed)
    doc isa AbstractDict ||
        _pne_schema_fail("PNE artifact のトップレベルはオブジェクトでなければなりません")
    return PNESectorOutputPath(
        doc;
        source_bytes_sha256 = "sha256:" * bytes2hex(SHA.sha256(bytes)),
    )
end

"`sector_id` の系列を返す（無ければ `nothing`）。`sectors` は `sector_id` 昇順で一意。"
function pne_sector(a::PNESectorOutputPath, sector_id::AbstractString)
    for s in a.sectors
        s.sector_id == sector_id && return s
    end
    return nothing
end

"`sector_id` の一覧（昇順）。"
pne_sector_ids(a::PNESectorOutputPath) = String[s.sector_id for s in a.sectors]

"""
    pne_is_synthetic_source(a::PNESectorOutputPath) -> Bool

`source_provenance.is_synthetic == true` かつ全部門の `source_data_status == :synthetic` のとき
`true`（`:hypothetical_override` の受理条件、設計 §6.3）。
"""
pne_is_synthetic_source(a::PNESectorOutputPath) =
    a.source_provenance.is_synthetic &&
    all(s -> s.source_data_status === :synthetic, a.sectors)

# ===========================================================================
# UpstreamModelArtifactRef（設計 §3.3）
# ===========================================================================

"""
    UpstreamModelArtifactRef

上流 artifact の identity と provenance の参照（設計 §3.3）。値パスは持たない。
`upstream_artifact_ref(a::PNESectorOutputPath)` で構築する。PNE の `source` の hash は
**再計算せずにそのまま写す**（DME が検証できるのは `content_hash` まで、設計 §12.1）。
`source_bytes_sha256` は監査用であり、DME の hash 対象から除く。
"""
struct UpstreamModelArtifactRef
    producer::String
    producer_version::String
    exporter_version::String
    algorithm_versions::Dict{String, String}
    contract_version::String
    artifact_id::String
    content_hash::String
    source_bytes_sha256::Union{String, Nothing}
    network_id::String
    source_input_hash::String
    dynamic_artifact_id::String
    dynamic_artifact_hash::String
    scenario_hash::String
    scenario_policy_hash::String
    scenario_config_hash::String
    export_config_hash::String
    geography_system::String
    geography_economy_id::String
    classification_system::String
    classification_version::String
    classification_level::String
    is_synthetic::Bool
    network_as_of::String
    node_estimation_status_counts::Dict{Symbol, Int}
    edge_estimation_status_counts::Dict{Symbol, Int}
    result_role::Symbol
end

"`PNESectorOutputPath` から `UpstreamModelArtifactRef` を構築する。"
function upstream_artifact_ref(a::PNESectorOutputPath)
    s = a.source
    return UpstreamModelArtifactRef(
        "production-network-engine",
        a.producer.engine_version,
        a.producer.exporter_version,
        copy(a.producer.algorithm_versions),
        a.schema_version,
        a.artifact_id,
        a.content_hash,
        a.source_bytes_sha256,
        s.network_id,
        s.source_input_hash,
        s.dynamic_artifact_id,
        s.dynamic_artifact_hash,
        s.scenario_hash,
        s.scenario_policy_hash,
        s.scenario_config_hash,
        s.export_config_hash,
        a.geography.system,
        a.geography.economy_id,
        a.classification.system,
        a.classification.version,
        a.classification.level,
        a.source_provenance.is_synthetic,
        a.source_provenance.network_as_of,
        copy(a.source_provenance.node_estimation_status_counts),
        copy(a.source_provenance.edge_estimation_status_counts),
        UPSTREAM_MODEL_DERIVED_RESULT_ROLE,
    )
end

_pne_counts_to_dict(c::Dict{Symbol, Int}) =
    Dict{String, Any}(String(k) => v for (k, v) in c)

"""
    upstream_artifact_ref_to_dict(r::UpstreamModelArtifactRef; include_audit::Bool = true)
        -> Dict{String,Any}

ASCII キーの `Dict` へ写す。`include_audit = false` のとき、hash 対象外の
`source_bytes_sha256` を含めない（hash 計算用）。
"""
function upstream_artifact_ref_to_dict(
    r::UpstreamModelArtifactRef;
    include_audit::Bool = true,
)
    d = Dict{String, Any}(
        "producer" => r.producer,
        "producer_version" => r.producer_version,
        "exporter_version" => r.exporter_version,
        "algorithm_versions" =>
            Dict{String, Any}(k => v for (k, v) in r.algorithm_versions),
        "contract_version" => r.contract_version,
        "artifact_id" => r.artifact_id,
        "content_hash" => r.content_hash,
        "network_id" => r.network_id,
        "source_input_hash" => r.source_input_hash,
        "dynamic_artifact_id" => r.dynamic_artifact_id,
        "dynamic_artifact_hash" => r.dynamic_artifact_hash,
        "scenario_hash" => r.scenario_hash,
        "scenario_policy_hash" => r.scenario_policy_hash,
        "scenario_config_hash" => r.scenario_config_hash,
        "export_config_hash" => r.export_config_hash,
        "geography" => Dict{String, Any}(
            "system" => r.geography_system,
            "economy_id" => r.geography_economy_id,
        ),
        "classification" => Dict{String, Any}(
            "system" => r.classification_system,
            "version" => r.classification_version,
            "level" => r.classification_level,
        ),
        "is_synthetic" => r.is_synthetic,
        "network_as_of" => r.network_as_of,
        "node_estimation_status_counts" =>
            _pne_counts_to_dict(r.node_estimation_status_counts),
        "edge_estimation_status_counts" =>
            _pne_counts_to_dict(r.edge_estimation_status_counts),
        "result_role" => String(r.result_role),
    )
    include_audit && (d["source_bytes_sha256"] = r.source_bytes_sha256)
    return d
end
