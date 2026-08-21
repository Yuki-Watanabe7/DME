# scenario_serialization.jl: JSON encode/decode・schema version 検査・成果物の保存/読込・
# replay（Issue #203 / `E-7`）。
#
# 本ファイルは `Scenario`（`L3` 集合）の完全な round-trip シリアライズ
# （`scenario_to_dict`/`scenario_from_dict`）と、`ScenarioRun` から7種の成果物ファイルを
# 書き出す `save_scenario_artifact`、保存済み `scenario.json` を読み込む `load_scenario`、
# 同一結果を再現する `replay_scenario` を提供する。
#
# **replay の入力は `scenario.json` のみ**（統合設計 §9.5 契約3。`observed_events.json`
# （`L1`/`L2` の原本）は監査用であり replay には用いない。`SimulationResult.metadata` も
# 用いない）。`replay_scenario` は同一ディレクトリの `manifest.json` を読み、
# `params_hash`/`initial_state_id`/`solver_settings_hash` を現在の実行結果と照合する
# （環境依存値へ依存した replay を許さない、統合設計 §9.5 契約2）。この照合は
# `Scenario`（仮定集合・外生パスの再構成）には使わない ─ 識別子の一致検査専用である。
#
# fail closed decode 契約（統合設計 §9.4）: 未知 `schema_version`・必須フィールド欠損・
# hash 不一致・未知キーの混入は、すべて欠損/余剰キー名を列挙した `ArgumentError`。
#
# 設計契約:
#   docs/architecture/macro_event_runtime_integration.md §5.9（公開API シグネチャ）・
#     §9.4（JSON schema と正準化、`Y-19`・`Y-27`）・§9.5（成果物と replay）・§11 `E-7` 行

# ------------------------------------------------------------
# JSON3 → 素の Dict/Vector（`real_rate_model_artifact.jl` の `_rra_to_plain` と同じ idiom）
# ------------------------------------------------------------

_scenario_json_to_plain(x::JSON3.Object) =
    Dict{String, Any}(String(k) => _scenario_json_to_plain(v) for (k, v) in x)
_scenario_json_to_plain(x::JSON3.Array) = Any[_scenario_json_to_plain(v) for v in x]
_scenario_json_to_plain(x) = x

# ------------------------------------------------------------
# decode 用ヘルパ（統合設計 §9.4 の fail closed 契約）
# ------------------------------------------------------------

"""
    _scenario_check_keys(label, d, required) -> Nothing

`d` のキー集合が `required`（`Tuple`/`Vector` of `String`）と**完全に一致する**ことを
検証する。欠損キー・未知キーのいずれも列挙した `ArgumentError` で拒否する
（統合設計 §9.4 decode fail closed契約: 必須フィールド欠損／未知キーの混入）。
"""
function _scenario_check_keys(label::AbstractString, d::AbstractDict, required)
    present = Set(String(k) for k in keys(d))
    expected = Set(String(k) for k in required)
    missing_keys = sort(collect(setdiff(expected, present)))
    extra_keys = sort(collect(setdiff(present, expected)))
    isempty(missing_keys) || throw(
        ArgumentError(
            "$(label): 必須フィールドが欠落しています: $(missing_keys)" *
            "（統合設計 §9.4 decode fail closed契約）",
        ),
    )
    isempty(extra_keys) || throw(
        ArgumentError(
            "$(label): 未知のキーが含まれています: $(extra_keys)" *
            "（schema drift の検出、統合設計 §9.4 decode fail closed契約）",
        ),
    )
    return nothing
end

_scenario_as_string(v, label::AbstractString) =
    v isa AbstractString ? String(v) :
    throw(ArgumentError("$(label) は文字列でなければなりません（実値: $(repr(v))）"))
_scenario_as_symbol(v, label::AbstractString) = Symbol(_scenario_as_string(v, label))
_scenario_as_bool(v, label::AbstractString) =
    v isa Bool ? v :
    throw(ArgumentError("$(label) は真偽値でなければなりません（実値: $(repr(v))）"))
_scenario_as_int(v, label::AbstractString) =
    v isa Integer ? Int(v) :
    throw(ArgumentError("$(label) は整数でなければなりません（実値: $(repr(v))）"))
_scenario_as_float(v, label::AbstractString) =
    v isa Real ? Float64(v) :
    throw(ArgumentError("$(label) は数値でなければなりません（実値: $(repr(v))）"))
_scenario_as_date(v, label::AbstractString) =
    v isa AbstractString ? Date(v, dateformat"yyyy-mm-dd") :
    throw(ArgumentError("$(label) は \"YYYY-MM-DD\" 形式の文字列でなければなりません"))
function _scenario_as_datetime(v, label::AbstractString)
    v isa AbstractString ||
        throw(ArgumentError("$(label) は ISO 8601 文字列でなければなりません"))
    s = endswith(v, "Z") ? v[1:(end - 1)] : v
    return DateTime(s, dateformat"yyyy-mm-ddTHH:MM:SS")
end
_scenario_as_optional(f, v, label::AbstractString) = v === nothing ? nothing : f(v, label)

# ------------------------------------------------------------
# CalendarQuarter（統合設計 §5.4・§9.4）
# ------------------------------------------------------------

_scenario_calendar_quarter_to_dict(q::CalendarQuarter)::Dict{String, Any} =
    Dict{String, Any}("year" => q.year, "quarter" => q.quarter)

function _scenario_calendar_quarter_from_dict(d::AbstractDict)::CalendarQuarter
    _scenario_check_keys("CalendarQuarter", d, ("year", "quarter"))
    return CalendarQuarter(
        _scenario_as_int(d["year"], "CalendarQuarter.year"),
        _scenario_as_int(d["quarter"], "CalendarQuarter.quarter"),
    )
end

# ------------------------------------------------------------
# TimingRuleSet（統合設計 §5.4・§9.4。to_dict は `scenario_provenance.jl` の
# `_scenario_timing_rule_set_dict` を再利用する）
# ------------------------------------------------------------

function _scenario_timing_rule_set_from_dict(d::AbstractDict)::TimingRuleSet
    _scenario_check_keys(
        "TimingRuleSet",
        d,
        ("id", "version", "cutoff_month_offset", "rules"),
    )
    rules_d = d["rules"]
    rules_d isa AbstractDict ||
        throw(ArgumentError("TimingRuleSet.rules は object でなければなりません"))
    rules = Dict{Symbol, Symbol}(
        Symbol(_scenario_as_string(k, "TimingRuleSet.rules key")) =>
            Symbol(_scenario_as_string(v, "TimingRuleSet.rules value")) for
        (k, v) in rules_d
    )
    return TimingRuleSet(;
        id = _scenario_as_string(d["id"], "TimingRuleSet.id"),
        version = _scenario_as_string(d["version"], "TimingRuleSet.version"),
        cutoff_month_offset = _scenario_as_int(
            d["cutoff_month_offset"],
            "TimingRuleSet.cutoff_month_offset",
        ),
        rules = rules,
    )
end

# ------------------------------------------------------------
# EventProvenance（統合設計 §5.2・§9.4）
# ------------------------------------------------------------

function _scenario_event_provenance_to_dict(p::EventProvenance)::Dict{String, Any}
    return Dict{String, Any}(
        "layer" => String(p.layer),
        "derived_from" => copy(p.derived_from),
        "rule_id" => p.rule_id,
        "rule_version" => p.rule_version,
        "generated_at" => _scenario_hash_encode(p.generated_at),
        "generator" => p.generator,
    )
end

function _scenario_event_provenance_from_dict(d::AbstractDict)::EventProvenance
    _scenario_check_keys(
        "EventProvenance",
        d,
        ("layer", "derived_from", "rule_id", "rule_version", "generated_at", "generator"),
    )
    derived = d["derived_from"]
    derived isa AbstractVector ||
        throw(ArgumentError("EventProvenance.derived_from は配列でなければなりません"))
    return EventProvenance(;
        layer = _scenario_as_symbol(d["layer"], "EventProvenance.layer"),
        derived_from = String[
            _scenario_as_string(x, "EventProvenance.derived_from[]") for x in derived
        ],
        rule_id = _scenario_as_string(d["rule_id"], "EventProvenance.rule_id"),
        rule_version = _scenario_as_string(
            d["rule_version"],
            "EventProvenance.rule_version",
        ),
        generator = _scenario_as_string(d["generator"], "EventProvenance.generator"),
        generated_at = _scenario_as_optional(
            _scenario_as_datetime,
            d["generated_at"],
            "EventProvenance.generated_at",
        ),
    )
end

# ------------------------------------------------------------
# EventTiming（統合設計 §5.2・§9.4、`Y-02`）
# ------------------------------------------------------------

function _scenario_event_timing_to_dict(t::EventTiming)::Dict{String, Any}
    return Dict{String, Any}(
        "basis" => String(t.basis),
        "rule" => String(t.rule),
        "effective_from" => _scenario_hash_encode(t.effective_from),
        "effective_until" => _scenario_hash_encode(t.effective_until),
        "t_apply" => t.t_apply,
        "t_until" => t.t_until,
        "rule_overridden" => t.rule_overridden,
        "from_source" => String(t.from_source),
    )
end

function _scenario_event_timing_from_dict(d::AbstractDict)::EventTiming
    _scenario_check_keys(
        "EventTiming",
        d,
        (
            "basis",
            "rule",
            "effective_from",
            "effective_until",
            "t_apply",
            "t_until",
            "rule_overridden",
            "from_source",
        ),
    )
    return EventTiming(;
        basis = _scenario_as_symbol(d["basis"], "EventTiming.basis"),
        rule = _scenario_as_symbol(d["rule"], "EventTiming.rule"),
        effective_from = _scenario_as_optional(
            _scenario_as_date,
            d["effective_from"],
            "EventTiming.effective_from",
        ),
        effective_until = _scenario_as_optional(
            _scenario_as_date,
            d["effective_until"],
            "EventTiming.effective_until",
        ),
        t_apply = _scenario_as_optional(
            _scenario_as_int,
            d["t_apply"],
            "EventTiming.t_apply",
        ),
        t_until = _scenario_as_optional(
            _scenario_as_int,
            d["t_until"],
            "EventTiming.t_until",
        ),
        rule_overridden = _scenario_as_bool(
            d["rule_overridden"],
            "EventTiming.rule_overridden",
        ),
        from_source = _scenario_as_symbol(d["from_source"], "EventTiming.from_source"),
    )
end

# ------------------------------------------------------------
# PersistenceSpec（統合設計 §5.2・§7.4・§9.4）
# ------------------------------------------------------------

function _scenario_persistence_spec_to_dict(p::PersistenceSpec)::Dict{String, Any}
    return Dict{String, Any}(
        "shape" => String(p.shape),
        "duration" => p.duration,
        "params" => _scenario_hash_encode(p.params),
    )
end

"""
    _scenario_persistence_params_from_dict(shape, d) -> NamedTuple

`shape` ごとに必須の `params` キーが異なる（統合設計 §7.4）ため、shape で分岐して
`NamedTuple` を再構成する。キー集合が想定と異なる場合は `ArgumentError`。
"""
function _scenario_persistence_params_from_dict(shape::Symbol, d::AbstractDict)
    if shape === :pulse || shape === :step || shape === :ramp
        isempty(d) || throw(
            ArgumentError(
                "PersistenceSpec.params: shape=$(shape) では空でなければなりません" *
                "（未知キー: $(sort(collect(keys(d))))）",
            ),
        )
        return NamedTuple()
    elseif shape === :step_then_ramp
        _scenario_check_keys("PersistenceSpec.params", d, ("hold", "ramp_down"))
        return (
            hold = _scenario_as_float(d["hold"], "PersistenceSpec.params.hold"),
            ramp_down = _scenario_as_float(
                d["ramp_down"],
                "PersistenceSpec.params.ramp_down",
            ),
        )
    elseif shape === :ar1_decay
        _scenario_check_keys("PersistenceSpec.params", d, ("half_life",))
        return (
            half_life = _scenario_as_float(
                d["half_life"],
                "PersistenceSpec.params.half_life",
            ),
        )
    else # :path
        _scenario_check_keys("PersistenceSpec.params", d, ("values",))
        vals = d["values"]
        vals isa AbstractVector ||
            throw(ArgumentError("PersistenceSpec.params.values は配列でなければなりません"))
        return (
            values = Float64[
                _scenario_as_float(v, "PersistenceSpec.params.values[]") for v in vals
            ],
        )
    end
end

function _scenario_persistence_spec_from_dict(d::AbstractDict)::PersistenceSpec
    _scenario_check_keys("PersistenceSpec", d, ("shape", "duration", "params"))
    shape = _scenario_as_symbol(d["shape"], "PersistenceSpec.shape")
    params_d = d["params"]
    params_d isa AbstractDict ||
        throw(ArgumentError("PersistenceSpec.params は object でなければなりません"))
    return PersistenceSpec(;
        shape = shape,
        duration = _scenario_as_optional(
            _scenario_as_int,
            d["duration"],
            "PersistenceSpec.duration",
        ),
        params = _scenario_persistence_params_from_dict(shape, params_d),
    )
end

# ------------------------------------------------------------
# ScenarioAssumption（統合設計 §5.2・§9.4）
# ------------------------------------------------------------

const _SCENARIO_ASSUMPTION_KEYS = (
    "assumption_id",
    "event_type",
    "schema_version",
    "sector",
    "geography",
    "direction",
    "magnitude",
    "unit",
    "magnitude_source",
    "application_mode",
    "timing",
    "persistence",
    "target_concepts",
    "is_scenario_assumption",
    "confidence",
    "uncertainty",
    "provenance",
    "notes",
    "caveats",
)

function _scenario_assumption_to_dict(a::ScenarioAssumption)::Dict{String, Any}
    return Dict{String, Any}(
        "assumption_id" => a.assumption_id,
        "event_type" => String(a.event_type),
        "schema_version" => a.schema_version,
        "sector" => String(a.sector),
        "geography" => a.geography,
        "direction" => String(a.direction),
        "magnitude" => a.magnitude,
        "unit" => a.unit,
        "magnitude_source" => String(a.magnitude_source),
        "application_mode" => String(a.application_mode),
        "timing" => _scenario_event_timing_to_dict(a.timing),
        "persistence" => _scenario_persistence_spec_to_dict(a.persistence),
        "target_concepts" => sort(String.(a.target_concepts)),
        "is_scenario_assumption" => a.is_scenario_assumption,
        "confidence" => a.confidence,
        "uncertainty" =>
            a.uncertainty === nothing ? nothing : Any[a.uncertainty[1], a.uncertainty[2]],
        "provenance" => _scenario_event_provenance_to_dict(a.provenance),
        "notes" => a.notes,
        "caveats" => a.caveats,
    )
end

function _scenario_uncertainty_from_dict(v, label::AbstractString)
    v === nothing && return nothing
    v isa AbstractVector && length(v) == 2 ||
        throw(ArgumentError("$(label) は長さ2の配列または null でなければなりません"))
    return (
        _scenario_as_float(v[1], "$(label)[1]"),
        _scenario_as_float(v[2], "$(label)[2]"),
    )
end

function _scenario_assumption_from_dict(d::AbstractDict)::ScenarioAssumption
    _scenario_check_keys("ScenarioAssumption", d, _SCENARIO_ASSUMPTION_KEYS)

    is_assumption = _scenario_as_bool(
        d["is_scenario_assumption"],
        "ScenarioAssumption.is_scenario_assumption",
    )
    is_assumption || throw(
        ArgumentError(
            "ScenarioAssumption.is_scenario_assumption は true でなければなりません" *
            "（実値: $(is_assumption)。改ざんまたは破損の可能性）",
        ),
    )

    timing_d = d["timing"]
    timing_d isa AbstractDict ||
        throw(ArgumentError("ScenarioAssumption.timing は object でなければなりません"))
    persistence_d = d["persistence"]
    persistence_d isa AbstractDict || throw(
        ArgumentError("ScenarioAssumption.persistence は object でなければなりません"),
    )
    provenance_d = d["provenance"]
    provenance_d isa AbstractDict ||
        throw(ArgumentError("ScenarioAssumption.provenance は object でなければなりません"))
    tc = d["target_concepts"]
    tc isa AbstractVector || throw(
        ArgumentError("ScenarioAssumption.target_concepts は配列でなければなりません"),
    )

    return ScenarioAssumption(;
        assumption_id = _scenario_as_string(
            d["assumption_id"],
            "ScenarioAssumption.assumption_id",
        ),
        event_type = _scenario_as_symbol(d["event_type"], "ScenarioAssumption.event_type"),
        schema_version = _scenario_as_string(
            d["schema_version"],
            "ScenarioAssumption.schema_version",
        ),
        sector = _scenario_as_symbol(d["sector"], "ScenarioAssumption.sector"),
        geography = _scenario_as_string(d["geography"], "ScenarioAssumption.geography"),
        direction = _scenario_as_symbol(d["direction"], "ScenarioAssumption.direction"),
        magnitude = _scenario_as_float(d["magnitude"], "ScenarioAssumption.magnitude"),
        unit = _scenario_as_string(d["unit"], "ScenarioAssumption.unit"),
        magnitude_source = _scenario_as_symbol(
            d["magnitude_source"],
            "ScenarioAssumption.magnitude_source",
        ),
        application_mode = _scenario_as_symbol(
            d["application_mode"],
            "ScenarioAssumption.application_mode",
        ),
        timing = _scenario_event_timing_from_dict(timing_d),
        persistence = _scenario_persistence_spec_from_dict(persistence_d),
        target_concepts = Symbol[
            _scenario_as_symbol(x, "ScenarioAssumption.target_concepts[]") for x in tc
        ],
        provenance = _scenario_event_provenance_from_dict(provenance_d),
        confidence = _scenario_as_optional(
            _scenario_as_float,
            d["confidence"],
            "ScenarioAssumption.confidence",
        ),
        uncertainty = _scenario_uncertainty_from_dict(
            d["uncertainty"],
            "ScenarioAssumption.uncertainty",
        ),
        notes = _scenario_as_string(d["notes"], "ScenarioAssumption.notes"),
        caveats = _scenario_as_string(d["caveats"], "ScenarioAssumption.caveats"),
    )
end

# ------------------------------------------------------------
# Scenario（統合設計 §5.4・§5.9・§9.4）
# ------------------------------------------------------------

const _SCENARIO_TOP_LEVEL_KEYS = (
    "schema_version",
    "id",
    "name",
    "version",
    "model",
    "period_zero",
    "horizon_runup",
    "horizon_eval",
    "assumptions",
    "timing_rules",
    "defaults_set_id",
    "defaults_set_version",
    "notes",
    "event_set_hash",
    "scenario_content_hash",
)

"""
    scenario_to_dict(sc::Scenario) -> Dict{String,Any}

`Scenario`（`assumptions` を含む）を ASCII キーの `Dict` へ写す（統合設計 §5.9・§9.4、
`Y-19`）。`assumptions` は `assumption_id` 昇順に整列する（配列順序の安定化はエンコーダの
責務、統合設計 §9.4）。自己検証用に `event_set_hash`/`scenario_content_hash` を含む
（`scenario_from_dict` がこれらを再計算し照合する）。
"""
function scenario_to_dict(sc::Scenario)::Dict{String, Any}
    sorted = sort(sc.assumptions; by = a -> a.assumption_id)
    return Dict{String, Any}(
        "schema_version" => SCENARIO_ARTIFACT_SCHEMA_VERSION,
        "id" => String(sc.id),
        "name" => sc.name,
        "version" => sc.version,
        "model" => String(sc.model),
        "period_zero" =>
            sc.period_zero === nothing ? nothing :
            _scenario_calendar_quarter_to_dict(sc.period_zero),
        "horizon_runup" => sc.horizon_runup,
        "horizon_eval" => sc.horizon_eval,
        "assumptions" => [_scenario_assumption_to_dict(a) for a in sorted],
        "timing_rules" => _scenario_timing_rule_set_dict(sc.timing_rules),
        "defaults_set_id" => sc.defaults_set_id,
        "defaults_set_version" => sc.defaults_set_version,
        "notes" => sc.notes,
        "event_set_hash" => event_set_hash(sc),
        "scenario_content_hash" => scenario_content_hash(sc),
    )
end

"""
    scenario_from_dict(d::AbstractDict) -> Scenario

`scenario_to_dict` の逆変換。fail closed（統合設計 §9.4）:
未知 `schema_version`・必須フィールド欠損・未知キー・`event_set_hash`/
`scenario_content_hash` の再計算値との不一致は、いずれも `ArgumentError`。
"""
function scenario_from_dict(d::AbstractDict)::Scenario
    haskey(d, "schema_version") || throw(
        ArgumentError(
            "Scenario: 必須フィールドが欠落しています: [\"schema_version\"]" *
            "（統合設計 §9.4 decode fail closed契約）",
        ),
    )
    d["schema_version"] == SCENARIO_ARTIFACT_SCHEMA_VERSION || throw(
        ArgumentError(
            "unsupported_schema_version: このパッケージがサポートするのは " *
            "$(SCENARIO_ARTIFACT_SCHEMA_VERSION) のみです（実際: $(d["schema_version"])。" *
            "統合設計 §9.4 decode fail closed契約）",
        ),
    )
    _scenario_check_keys("Scenario", d, _SCENARIO_TOP_LEVEL_KEYS)

    assumptions_d = d["assumptions"]
    assumptions_d isa AbstractVector ||
        throw(ArgumentError("Scenario.assumptions は配列でなければなりません"))
    assumptions = ScenarioAssumption[]
    for (i, ad) in enumerate(assumptions_d)
        ad isa AbstractDict || throw(
            ArgumentError("Scenario.assumptions[$(i)] は object でなければなりません"),
        )
        push!(assumptions, _scenario_assumption_from_dict(ad))
    end

    timing_rules_d = d["timing_rules"]
    timing_rules_d isa AbstractDict ||
        throw(ArgumentError("Scenario.timing_rules は object でなければなりません"))

    period_zero_v = d["period_zero"]
    period_zero = if period_zero_v === nothing
        nothing
    else
        period_zero_v isa AbstractDict || throw(
            ArgumentError(
                "Scenario.period_zero は object または null でなければなりません",
            ),
        )
        _scenario_calendar_quarter_from_dict(period_zero_v)
    end

    sc = Scenario(;
        id = _scenario_as_symbol(d["id"], "Scenario.id"),
        name = _scenario_as_string(d["name"], "Scenario.name"),
        version = _scenario_as_string(d["version"], "Scenario.version"),
        model = _scenario_as_symbol(d["model"], "Scenario.model"),
        period_zero = period_zero,
        horizon_runup = _scenario_as_int(d["horizon_runup"], "Scenario.horizon_runup"),
        horizon_eval = _scenario_as_int(d["horizon_eval"], "Scenario.horizon_eval"),
        assumptions = assumptions,
        timing_rules = _scenario_timing_rule_set_from_dict(timing_rules_d),
        defaults_set_id = _scenario_as_string(
            d["defaults_set_id"],
            "Scenario.defaults_set_id",
        ),
        defaults_set_version = _scenario_as_string(
            d["defaults_set_version"],
            "Scenario.defaults_set_version",
        ),
        notes = _scenario_as_string(d["notes"], "Scenario.notes"),
    )

    recomputed_event_set_hash = event_set_hash(sc)
    d["event_set_hash"] == recomputed_event_set_hash || throw(
        ArgumentError(
            "event_set_hash が再計算値と一致しません（改ざんまたは破損の可能性: " *
            "保存値=$(d["event_set_hash"])、再計算値=$(recomputed_event_set_hash)）",
        ),
    )
    recomputed_content_hash = scenario_content_hash(sc)
    d["scenario_content_hash"] == recomputed_content_hash || throw(
        ArgumentError(
            "scenario_content_hash が再計算値と一致しません（改ざんまたは破損の可能性: " *
            "保存値=$(d["scenario_content_hash"])、再計算値=$(recomputed_content_hash)）",
        ),
    )

    return sc
end

# ------------------------------------------------------------
# observed_events.json（L1・L2 の原本、監査用。統合設計 §9.5。replay には用いない）
# ------------------------------------------------------------

function _scenario_event_source_to_dict(s::EventSource)::Dict{String, Any}
    return Dict{String, Any}(
        "publisher" => s.publisher,
        "document_id" => s.document_id,
        "url" => s.url,
        "retrieved_at" => _scenario_hash_encode(s.retrieved_at),
    )
end

"""
    _scenario_observed_like_to_dict(e) -> Dict{String,Any}

`ObservedEvent`（`L1`）または `InterpretedSignal`（`L2`）を監査用 `Dict` へ写す
（`observed_events.json`）。decode（`from_dict`）は提供しない ── `L1`/`L2` は replay の
入力に用いないため（統合設計 §9.5 契約3）。
"""
function _scenario_observed_like_to_dict(
    e::Union{ObservedEvent, InterpretedSignal},
)::Dict{String, Any}
    d = Dict{String, Any}(
        "event_id" => e.event_id,
        "event_type" => String(e.event_type),
        "schema_version" => e.schema_version,
        "announced_at" => _scenario_hash_encode(e.announced_at),
        "observed_at" => _scenario_hash_encode(e.observed_at),
        "known_at" => _scenario_hash_encode(e.known_at),
        "effective_from" => _scenario_hash_encode(e.effective_from),
        "effective_until" => _scenario_hash_encode(e.effective_until),
        "source" => _scenario_event_source_to_dict(e.source),
        "entity" => e.entity,
        "sector" => String(e.sector),
        "geography" => e.geography,
        "direction" => String(e.direction),
        "magnitude" => e.magnitude === missing ? nothing : e.magnitude,
        "unit" => e.unit,
        "supersedes" => e.supersedes,
        "provenance" => _scenario_event_provenance_to_dict(e.provenance),
        "notes" => e.notes,
        "layer" => String(e.provenance.layer),
    )
    if e isa InterpretedSignal
        d["magnitude_source"] = String(e.magnitude_source)
        d["confidence"] = e.confidence
        d["uncertainty"] =
            e.uncertainty === nothing ? nothing : Any[e.uncertainty[1], e.uncertainty[2]]
        d["target_concepts"] = sort(String.(e.target_concepts))
        d["persistence"] =
            e.persistence === nothing ? nothing :
            _scenario_persistence_spec_to_dict(e.persistence)
    end
    return d
end

# ------------------------------------------------------------
# result_summary.json（統合設計 §9.5）
# ------------------------------------------------------------

function _scenario_result_summary_dict(run::ScenarioRun)::Dict{String, Any}
    if run.result === nothing
        return Dict{String, Any}(
            "schema_version" => SCENARIO_ARTIFACT_SCHEMA_VERSION,
            "status" => String(run.status),
            "metadata" => nothing,
            "variables" => nothing,
        )
    end
    md = Dict{String, Any}(
        String(k) => _scenario_hash_encode(v) for (k, v) in run.result.metadata
    )
    variables =
        Dict{String, Any}(String(k) => copy(v) for (k, v) in pairs(run.result.variables))
    return Dict{String, Any}(
        "schema_version" => SCENARIO_ARTIFACT_SCHEMA_VERSION,
        "status" => String(run.status),
        "metadata" => md,
        "variables" => variables,
    )
end

# ------------------------------------------------------------
# report.md（統合設計 §9.5、人間可読の要約）
# ------------------------------------------------------------

function _scenario_report_markdown(run::ScenarioRun)::String
    sc = run.scenario
    io = IOBuffer()
    println(io, "# Scenario Run Report")
    println(io)
    println(io, "- scenario_id: `$(sc.id)`")
    println(io, "- scenario_version: `$(sc.version)`")
    println(io, "- model: `$(run.model_name)` (`$(run.model_symbol)`)")
    println(io, "- status: `$(run.status)`")
    println(io, "- assumptions: $(length(sc.assumptions))")
    println(io, "- warnings: $(length(run.warnings))")
    println(io, "- rejections: $(length(run.rejections))")
    println(io, "- event_set_hash: `$(run.provenance.event_set_hash)`")
    println(io, "- params_hash: `$(run.provenance.params_hash)`")
    println(io, "- initial_state_id: `$(run.provenance.initial_state_id)`")
    println(io)
    if !isempty(run.rejections)
        println(io, "## Rejections")
        println(io)
        for r in run.rejections
            println(io, "- `$(r.code)` ($(r.layer)): $(r.detail)")
        end
        println(io)
    end
    if !isempty(run.warnings)
        println(io, "## Warnings")
        println(io)
        for w in run.warnings
            println(io, "- `$(w.code)`: $(w.detail)")
        end
        println(io)
    end
    println(io, "## Notes")
    println(io)
    println(
        io,
        "本レポートは `run_scenario` の実行結果を機械的に要約したものであり、投資判断・" *
        "政策提言を目的としない。",
    )
    return String(take!(io))
end

# ------------------------------------------------------------
# 正準 JSON のアトミック書き込み（`real_rate_model_artifact_export.jl` と同じ idiom）
# ------------------------------------------------------------

function _scenario_write_json(path::AbstractString, value)::String
    mkpath(dirname(path))
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

# ------------------------------------------------------------
# save_scenario_artifact（統合設計 §9.5）
# ------------------------------------------------------------

"""
    save_scenario_artifact(dir::AbstractString, run::ScenarioRun;
                            observed_events = AbstractMacroEvent[],
                            comparison = nothing) -> Vector{String}

`run` から成果物7種（統合設計 §9.5）を `dir` へ書き出す。すべて正準 JSON（`report.md` を
除く）・ASCII キー。`comparison`（`scenario_comparison` の出力に相当する `Dict`。
Issue #204 未実装のため既定 `nothing`）を渡したときのみ `comparison.json` を書く
（baseline がある場合のみ、統合設計 §9.5）。

書き出すファイル: `scenario.json`（replay の唯一の入力）・`observed_events.json`
（`L1`/`L2` の原本、監査用。replay には用いない）・`event_log.json`（統合設計 §9.1）・
`manifest.json`（再現契約・version 一覧・status・警告と拒否の件数）・
`result_summary.json`（`SimulationResult.metadata` と主要系列）・`comparison.json`
（任意）・`report.md`（人間可読要約）。

API キー・トークン・ローカル絶対パス・source 文書全文は書き出さない（統合設計 §9.5
契約4）。
"""
function save_scenario_artifact(
    dir::AbstractString,
    run::ScenarioRun;
    observed_events::AbstractVector{<:AbstractMacroEvent} = AbstractMacroEvent[],
    comparison::Union{AbstractDict, Nothing} = nothing,
)::Vector{String}
    mkpath(dir)
    paths = String[]

    push!(
        paths,
        _scenario_write_json(
            joinpath(dir, "scenario.json"),
            scenario_to_dict(run.scenario),
        ),
    )

    observed_dict = Dict{String, Any}(
        "schema_version" => SCENARIO_ARTIFACT_SCHEMA_VERSION,
        "events" => [_scenario_observed_like_to_dict(e) for e in observed_events],
    )
    push!(paths, _scenario_write_json(joinpath(dir, "observed_events.json"), observed_dict))

    log_entries =
        run.schedule === nothing ? Dict{String, Any}[] : scenario_event_log(run.schedule)
    event_log_dict = Dict{String, Any}(
        "schema_version" => SCENARIO_ARTIFACT_SCHEMA_VERSION,
        "event_log" => log_entries,
    )
    push!(paths, _scenario_write_json(joinpath(dir, "event_log.json"), event_log_dict))

    manifest_dict = _scenario_manifest_dict(
        run.provenance,
        run.status,
        length(run.warnings),
        length(run.rejections),
    )
    push!(paths, _scenario_write_json(joinpath(dir, "manifest.json"), manifest_dict))

    push!(
        paths,
        _scenario_write_json(
            joinpath(dir, "result_summary.json"),
            _scenario_result_summary_dict(run),
        ),
    )

    if comparison !== nothing
        comparison_dict = Dict{String, Any}(
            "schema_version" => SCENARIO_ARTIFACT_SCHEMA_VERSION,
            "comparison" => _scenario_hash_encode(comparison),
        )
        push!(
            paths,
            _scenario_write_json(joinpath(dir, "comparison.json"), comparison_dict),
        )
    end

    report_path = joinpath(dir, "report.md")
    write(report_path, _scenario_report_markdown(run))
    push!(paths, report_path)

    return paths
end

# ------------------------------------------------------------
# load_scenario / replay_scenario（統合設計 §5.9・§9.5）
# ------------------------------------------------------------

"""
    load_scenario(path::AbstractString) -> Scenario

`save_scenario_artifact` が書いた `scenario.json` を読み込み、`scenario_from_dict` の
fail closed 契約（未知 schema version・必須フィールド欠損・未知キー・hash 不一致）を
適用して返す。
"""
function load_scenario(path::AbstractString)::Scenario
    d = _scenario_json_to_plain(JSON3.read(read(path, String)))
    d isa AbstractDict ||
        throw(ArgumentError("$(path): トップレベルは object でなければなりません"))
    return scenario_from_dict(d)
end

"""
    replay_scenario(m::AbstractMacroModel, path::AbstractString;
                     options::ScenarioRunOptions = ScenarioRunOptions()) -> ScenarioRun

保存済み `scenario.json`（`path`）から `Scenario` を復元し、`run_scenario(m, sc; options)`
を再実行する（統合設計 §9.5）。**replay の入力は `scenario.json` のみ**であり、
`observed_events.json`・`SimulationResult.metadata` は用いない（同一ディレクトリの
`observed_events.json` すら読まない）。

同一ディレクトリの `manifest.json` を読み、`params_hash`/`initial_state_id`/
`solver_settings_hash` を今回の実行結果（`run.provenance`）と照合する。不一致は
`ArgumentError`（`params_identity_mismatch`。環境依存値へ依存した replay を許さない、
統合設計 §9.5 契約2）。`manifest.json` が見つからない場合も照合できないため
`ArgumentError`。
"""
function replay_scenario(
    m::AbstractMacroModel,
    path::AbstractString;
    options::ScenarioRunOptions = ScenarioRunOptions(),
)::ScenarioRun
    sc = load_scenario(path)

    manifest_path = joinpath(dirname(path), "manifest.json")
    isfile(manifest_path) || throw(
        ArgumentError(
            "replay_scenario: manifest.json が見つかりません（$(manifest_path)）。" *
            "params_hash/initial_state_id/solver_settings_hash の照合ができません" *
            "（統合設計 §9.5 契約2）",
        ),
    )
    manifest = _scenario_json_to_plain(JSON3.read(read(manifest_path, String)))
    manifest isa AbstractDict ||
        throw(ArgumentError("$(manifest_path): トップレベルは object でなければなりません"))

    run = run_scenario(m, sc; options = options)

    for key in ("params_hash", "initial_state_id", "solver_settings_hash")
        haskey(manifest, key) ||
            throw(ArgumentError("$(manifest_path) に \"$(key)\" がありません"))
        expected = manifest[key]
        actual = getproperty(run.provenance, Symbol(key))
        expected == actual || throw(
            ArgumentError(
                "params_identity_mismatch: manifest.json の $(key)=$(expected) が" *
                "現在の実行の値=$(actual) と一致しません（環境依存値へ依存した replay を" *
                "許さない、統合設計 §9.5 契約2）",
            ),
        )
    end

    return run
end
