# japan_fiscal_scenario_schema.jl: Japan Fiscal Scenario Lab の scenario catalog・
# explicit assumption schema・FRE context contract（Issue #275 / Phase 3）。
#
# #274（`japan_fiscal_capability.jl`）が確定した 5 scenario family × 11 モデルの representability
# と、#285（`japan_fiscal_claim_contract.jl`）が確定した claim-level / coverage 契約を前提に、
# 「observed context（FRE snapshot）と explicit Scenario Assumption を混同しない、
# versioned / serializable / deterministic な入力契約」を実装する。
#
# 設計方針（Issue #275 受け入れ条件）:
#   - FRE context と Scenario Assumption を**別の型**として保持し、FRE のフィールドを
#     magnitude 導出に用いる関数を一切持たない（`JAPAN_FISCAL_FRE_CONTEXT_ROLE =
#     :observed_context_only`。#274）。
#   - 5 scenario family は #274 の `JAPAN_FISCAL_FAMILY_REGISTRY` から**導出**し、
#     catalog が独自に `required_concepts` / `optional_concepts` / `guardrails` を
#     再定義しない（`H-01`）。
#   - assumption の magnitude 未指定と 0 を区別する。区別は「concept ごとに
#     `JapanFiscalScenarioAssumption` が存在するか」で表し、存在しない concept は
#     欠測（missing）、`magnitude = 0.0` で存在する concept は「変化なし」の明示的主張である。
#   - `magnitude_source` を必須とし、`japan_fiscal_magnitude_source_allowed`（#274）が
#     `false` を返す値（`:external_belief`）を construction 時に拒否する（`H-04`）。
#   - scenario artifact の identity に `JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION` と
#     `JAPAN_FISCAL_CLAIM_CONTRACT_VERSION` の両方を含める（`H-02`）。
#   - family の required/optional concepts に無い assumption concept を黙って無視せず、
#     construction 時に `ArgumentError` で拒否する。model 別の unsupported 判定
#     （`japan_fiscal_unsupported_concepts`）は #274 の registry を引き続き使う
#     （#275 では再実装しない）。
#   - canonical JSON（RFC 8785）+ SHA-256 による content hash を持ち、assumption の
#     並び順に依存しない・同一の意味内容から同一の hash を得る。
#
# 本ファイルは scenario の**構造**のみを定義する。model adapter・runner・result artifact は
# 実装しない（#276）。E2E / consumer fixture も実装しない（#277）。モデル方程式・#274/#285 の
# registry は変更しない。
#
# 依存: scenarios/japan_fiscal_capability.jl（#274）・scenarios/japan_fiscal_claim_contract.jl
# （#285）・artifacts/json_canonical.jl（`sha256_hex_of_canonical`）・JSON3・Dates。
#
# 設計契約:
#   docs/architecture/japan_fiscal_scenario_schema_contract.md
#   docs/adr/0022-japan-fiscal-scenario-schema-contract.md

# ===========================================================================
# 契約 version と固定語彙
# ===========================================================================

"Japan fiscal scenario schema 契約の version。"
const JAPAN_FISCAL_SCENARIO_SCHEMA_VERSION = "japan-fiscal-scenario-schema/1.0.0"

"""
FRE snapshot の regime 判定状態。

- `:primary` … 単一のレジームに明確に近い（`primary_regime` が必須）
- `:ambiguous` … 複数レジーム間で判定が割れている（`primary_regime` は `nothing`）
- `:unavailable` … データ不足等により判定できない（`primary_regime` は `nothing`）
"""
const JAPAN_FISCAL_FRE_REGIME_DETERMINATIONS = (:primary, :ambiguous, :unavailable)

"""
scenario の assumption 集合がどこから来たか。

- `:user` … 人手による明示的入力
- `:preset` … あらかじめ用意された scenario preset
- `:fixture` … テスト/デモ用 fixture
- `:analysis` … 分析パイプラインによる生成

`magnitude_source`（#274・個々の assumption の数値の出所）とは別の語彙である。
"""
const JAPAN_FISCAL_ASSUMPTION_SOURCES = (:user, :preset, :fixture, :analysis)

# ===========================================================================
# 検証ヘルパ（`_jf_check`・`_jf_check_subset` は japan_fiscal_capability.jl で定義済み）
# ===========================================================================

function _jf_require_nonempty(label::AbstractString, value::AbstractString)
    isempty(value) &&
        throw(ArgumentError("$label は空文字であってはいけません（Japan fiscal scenario schema契約）"))
    return nothing
end

function _jf_require_finite(label::AbstractString, value::Real)
    isfinite(value) ||
        throw(ArgumentError("$label は有限の値でなければなりません（実値: $(value)）"))
    return nothing
end

# ===========================================================================
# JapanFiscalFREContext（FRE context contract。#274 §2.1 / Issue #275 scope 1）
# ===========================================================================

"""
    JapanFiscalFREContext

fiscal-regime-engine（FRE）の current snapshot を保持する **observed context**。

`JAPAN_FISCAL_FRE_CONTEXT_ROLE = :observed_context_only`（#274）を型として体現する。
本型のどのフィールドも `JapanFiscalScenarioAssumption` の magnitude を計算する関数の
引数として使われない（本ファイルにそのような関数は存在しない）。FRE の affinity・share・
confidence・dimension score・Constraint Pressure・data quality score は、「どのレジームに
近いか」の度合いであって経済量ではない（#274 `JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_INPUT_FIELDS`）。

DME は FRE のスキーマを所有しない（fiscal-regime-engine は別リポジトリ）。本型は Issue #275
scope §1 が列挙する最低限のフィールド（identity / as-of / vintage basis・primary/ambiguity/
unavailable・Constraint Pressure・5 dimensions・dominant drivers・data quality・methodology・
policy version）を DME 内の record として保持するためのものであり、FRE 側の契約を変更・
再定義しない。

## フィールド
- `snapshot_id::String` : FRE 側の snapshot identity
- `as_of::Date` : snapshot の as-of 日付
- `vintage_basis::String` : vintage の基準（FRE 側の識別子）
- `regime_determination::Symbol` : `JAPAN_FISCAL_FRE_REGIME_DETERMINATIONS`
- `primary_regime::Union{String,Nothing}` : `regime_determination === :primary` のときのみ非 `nothing`
- `regime_affinity::Dict{String,Float64}` : archetype 名 => affinity
- `regime_share::Dict{String,Float64}` : archetype 名 => share
- `regime_confidence::Union{Float64,Nothing}`
- `dimension_score::Dict{String,Float64}` : dimension 名 => score（5 dimensions）
- `constraint_pressure::Union{Float64,Nothing}`
- `dominant_drivers::Vector{String}`
- `data_quality_score::Union{Float64,Nothing}`
- `methodology_version::String`
- `policy_version::String`
- `notes::String`
"""
struct JapanFiscalFREContext
    snapshot_id::String
    as_of::Date
    vintage_basis::String
    regime_determination::Symbol
    primary_regime::Union{String, Nothing}
    regime_affinity::Dict{String, Float64}
    regime_share::Dict{String, Float64}
    regime_confidence::Union{Float64, Nothing}
    dimension_score::Dict{String, Float64}
    constraint_pressure::Union{Float64, Nothing}
    dominant_drivers::Vector{String}
    data_quality_score::Union{Float64, Nothing}
    methodology_version::String
    policy_version::String
    notes::String
end

function JapanFiscalFREContext(;
    snapshot_id::AbstractString,
    as_of::Date,
    vintage_basis::AbstractString,
    regime_determination::Symbol,
    primary_regime::Union{AbstractString, Nothing} = nothing,
    regime_affinity = Dict{String, Float64}(),
    regime_share = Dict{String, Float64}(),
    regime_confidence::Union{Real, Nothing} = nothing,
    dimension_score = Dict{String, Float64}(),
    constraint_pressure::Union{Real, Nothing} = nothing,
    dominant_drivers::Vector{<:AbstractString} = String[],
    data_quality_score::Union{Real, Nothing} = nothing,
    methodology_version::AbstractString = "",
    policy_version::AbstractString = "",
    notes::AbstractString = "",
)
    _jf_require_nonempty("JapanFiscalFREContext.snapshot_id", snapshot_id)
    _jf_require_nonempty("JapanFiscalFREContext.vintage_basis", vintage_basis)
    _jf_check(
        regime_determination,
        JAPAN_FISCAL_FRE_REGIME_DETERMINATIONS,
        "regime_determination",
    )
    if regime_determination === :primary
        (primary_regime === nothing || isempty(primary_regime)) && throw(
            ArgumentError(
                "regime_determination=:primary のとき primary_regime は必須です（FRE context contract。#275 scope 1）",
            ),
        )
    else
        primary_regime === nothing || throw(
            ArgumentError(
                "regime_determination=$(repr(regime_determination)) のとき primary_regime は nothing でなければなりません（実値: $(repr(primary_regime))）",
            ),
        )
    end
    regime_confidence === nothing ||
        _jf_require_finite("JapanFiscalFREContext.regime_confidence", regime_confidence)
    constraint_pressure === nothing ||
        _jf_require_finite("JapanFiscalFREContext.constraint_pressure", constraint_pressure)
    data_quality_score === nothing ||
        _jf_require_finite("JapanFiscalFREContext.data_quality_score", data_quality_score)
    for (label, d) in (
        ("regime_affinity", regime_affinity),
        ("regime_share", regime_share),
        ("dimension_score", dimension_score),
    )
        for (k, v) in d
            _jf_require_finite("JapanFiscalFREContext.$(label)[$(repr(k))]", v)
        end
    end
    return JapanFiscalFREContext(
        String(snapshot_id),
        as_of,
        String(vintage_basis),
        regime_determination,
        primary_regime === nothing ? nothing : String(primary_regime),
        Dict{String, Float64}(String(k) => Float64(v) for (k, v) in regime_affinity),
        Dict{String, Float64}(String(k) => Float64(v) for (k, v) in regime_share),
        regime_confidence === nothing ? nothing : Float64(regime_confidence),
        Dict{String, Float64}(String(k) => Float64(v) for (k, v) in dimension_score),
        constraint_pressure === nothing ? nothing : Float64(constraint_pressure),
        String.(dominant_drivers),
        data_quality_score === nothing ? nothing : Float64(data_quality_score),
        String(methodology_version),
        String(policy_version),
        String(notes),
    )
end

"""
    japan_fiscal_fre_context_identity(context::JapanFiscalFREContext) -> String

`context` の内容から決定論的に導出する `"sha256:…"` 形式の identity。`notes` は表示専用として
identity 対象から除外する。`dominant_drivers` は整列してから正準化するため、入力順に依存しない。
"""
function japan_fiscal_fre_context_identity(context::JapanFiscalFREContext)::String
    payload = Dict{String, Any}(
        "snapshot_id" => context.snapshot_id,
        "as_of" => Dates.format(context.as_of, "yyyy-mm-dd"),
        "vintage_basis" => context.vintage_basis,
        "regime_determination" => String(context.regime_determination),
        "primary_regime" => context.primary_regime,
        "regime_affinity" => context.regime_affinity,
        "regime_share" => context.regime_share,
        "regime_confidence" => context.regime_confidence,
        "dimension_score" => context.dimension_score,
        "constraint_pressure" => context.constraint_pressure,
        "dominant_drivers" => sort(copy(context.dominant_drivers)),
        "data_quality_score" => context.data_quality_score,
        "methodology_version" => context.methodology_version,
        "policy_version" => context.policy_version,
    )
    return "sha256:" * sha256_hex_of_canonical(payload)
end

# ===========================================================================
# JapanFiscalScenarioAssumption（explicit assumption schema。Issue #275 scope 3）
# ===========================================================================

"""
    JapanFiscalScenarioAssumption

明示的 Scenario Assumption 1 件。`JAPAN_FISCAL_ASSUMPTION_CONCEPTS`（#274。9 概念）のいずれか
1 つに対する、単一の明示的な数値主張である。

## 0 と missing の区別
`magnitude` は常に有限の `Float64`（欠測を表す `nothing` を持たない）。「この concept について
assumption を置いていない」は、`JapanFiscalScenario.assumptions` にその concept の
`JapanFiscalScenarioAssumption` が**存在しないこと**で表す。`magnitude = 0.0` は
「変化なしという明示的な主張」であり、両者は construction／serialization のいずれでも
混同されない（`H-03`）。

## unit・direction
`unit` はフィールドとして保持しない。`japan_fiscal_assumption_concept(concept).unit`
（#274）から導出する（二重管理を避ける）。`direction`（`:up`/`:down`/`:none`）も
フィールドとして保持せず、`japan_fiscal_assumption_direction` で `magnitude` の符号から導出する。

## magnitude_source
`MACRO_EVENT_MAGNITUDE_SOURCES`（マクロイベント変換契約）のいずれかを要求し、
`japan_fiscal_magnitude_source_allowed`（#274）が `false` を返す値（`:external_belief`）は
construction 時に `ArgumentError` で拒否する（`H-04`）。FRE の affinity/share/confidence が
外部 belief の数量を経由して magnitude へ入る経路を、この検査が閉じる。

## フィールド
- `assumption_id::String`
- `concept::Symbol` : `JAPAN_FISCAL_ASSUMPTION_CONCEPTS`
- `magnitude::Float64` : 有限値。単位は概念の `basis`/`unit` に従う
- `magnitude_source::Symbol` : `MACRO_EVENT_MAGNITUDE_SOURCES`
- `notes::String`
"""
struct JapanFiscalScenarioAssumption
    assumption_id::String
    concept::Symbol
    magnitude::Float64
    magnitude_source::Symbol
    notes::String

    function JapanFiscalScenarioAssumption(;
        assumption_id::AbstractString,
        concept::Symbol,
        magnitude::Real,
        magnitude_source::Symbol,
        notes::AbstractString = "",
    )
        _jf_require_nonempty("JapanFiscalScenarioAssumption.assumption_id", assumption_id)
        _jf_check(concept, JAPAN_FISCAL_ASSUMPTION_CONCEPTS, "assumption concept")
        _jf_require_finite("JapanFiscalScenarioAssumption.magnitude", magnitude)
        _jf_check(magnitude_source, MACRO_EVENT_MAGNITUDE_SOURCES, "magnitude_source")
        japan_fiscal_magnitude_source_allowed(magnitude_source) || throw(
            ArgumentError(
                "magnitude_source=$(repr(magnitude_source)) は Japan fiscal scenario assumption で受理されません" *
                "（JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_SOURCES。FRE のスコアが外部 belief を経由して" *
                "magnitude へ入る経路を塞ぐための制約。`H-04`）",
            ),
        )
        return new(
            String(assumption_id),
            concept,
            Float64(magnitude),
            magnitude_source,
            String(notes),
        )
    end
end

"`a.magnitude` の符号から方向を導出する（フィールドとしては保持しない）。"
function japan_fiscal_assumption_direction(a::JapanFiscalScenarioAssumption)::Symbol
    a.magnitude > 0 && return :up
    a.magnitude < 0 && return :down
    return :none
end

"`a.concept` に対応する単位（#274 `japan_fiscal_assumption_concept`）。"
japan_fiscal_assumption_unit(a::JapanFiscalScenarioAssumption)::String =
    japan_fiscal_assumption_concept(a.concept).unit

# ===========================================================================
# JapanFiscalScenarioProvenance（provenance / identity。Issue #275 scope 4）
# ===========================================================================

"""
    JapanFiscalScenarioProvenance

scenario artifact の identity・creation metadata。**identity 対象**（`schema_version`・
`capability_contract_version`・`claim_contract_version`・`assumption_source`）と
**identity 非対象**（`created_at`・`created_by`。volatile）を分離する。`content_hash` 自身は
このレコードのフィールドとして持たない（hash 自己参照を避けるため。ADR 0008 と同じ設計判断）。
`japan_fiscal_scenario_content_hash` が別関数として計算する。

## フィールド
- `schema_version::String` : 作成時点の `JAPAN_FISCAL_SCENARIO_SCHEMA_VERSION`
- `capability_contract_version::String` : 作成時点の `JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION`（#274）
- `claim_contract_version::String` : 作成時点の `JAPAN_FISCAL_CLAIM_CONTRACT_VERSION`（#285）
- `assumption_source::Symbol` : `JAPAN_FISCAL_ASSUMPTION_SOURCES`
- `created_at::Union{DateTime,Nothing}` : volatile。hash 対象外
- `created_by::String` : volatile。hash 対象外
"""
struct JapanFiscalScenarioProvenance
    schema_version::String
    capability_contract_version::String
    claim_contract_version::String
    assumption_source::Symbol
    created_at::Union{DateTime, Nothing}
    created_by::String

    function JapanFiscalScenarioProvenance(;
        assumption_source::Symbol,
        schema_version::AbstractString = JAPAN_FISCAL_SCENARIO_SCHEMA_VERSION,
        capability_contract_version::AbstractString = JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION,
        claim_contract_version::AbstractString = JAPAN_FISCAL_CLAIM_CONTRACT_VERSION,
        created_at::Union{DateTime, Nothing} = nothing,
        created_by::AbstractString = "",
    )
        _jf_check(assumption_source, JAPAN_FISCAL_ASSUMPTION_SOURCES, "assumption_source")
        _jf_require_nonempty(
            "JapanFiscalScenarioProvenance.schema_version",
            schema_version,
        )
        return new(
            String(schema_version),
            String(capability_contract_version),
            String(claim_contract_version),
            assumption_source,
            created_at,
            String(created_by),
        )
    end
end

# ===========================================================================
# JapanFiscalScenario（scenario 集合本体）
# ===========================================================================

"""
    JapanFiscalScenario

1 つの scenario family に対する明示的 assumption 集合と、observed context（FRE snapshot）・
provenance をまとめた record。**モデルを保持しない**（family と model の mapping は #276 の
責務であり、#274 の `japan_fiscal_model_mapping(family, model)` を引く）。

## construction 時の検証
- `family` は `JAPAN_FISCAL_SCENARIO_FAMILIES` のいずれか。
- 各 `assumptions[i].concept` は、`japan_fiscal_family_spec(family)` の
  `required_concepts ∪ optional_concepts` に含まれなければならない。含まれない concept は
  黙って無視せず `ArgumentError` で拒否する（表現不能な概念を近い入力へ寄せない、#274 の方針の
  scenario 構築時点での具体化）。
- 同一 `concept` を複数の assumption で重複して主張できない（あいまいさを避ける）。

`fre_context` は `nothing` であってもよい（observed context 無しの scenario は正当である）。

## フィールド
- `scenario_id::String`
- `family::Symbol`
- `name::String`
- `fre_context::Union{JapanFiscalFREContext,Nothing}`
- `assumptions::Vector{JapanFiscalScenarioAssumption}`
- `provenance::JapanFiscalScenarioProvenance`
- `notes::String`
"""
struct JapanFiscalScenario
    scenario_id::String
    family::Symbol
    name::String
    fre_context::Union{JapanFiscalFREContext, Nothing}
    assumptions::Vector{JapanFiscalScenarioAssumption}
    provenance::JapanFiscalScenarioProvenance
    notes::String

    function JapanFiscalScenario(;
        scenario_id::AbstractString,
        family::Symbol,
        provenance::JapanFiscalScenarioProvenance,
        name::AbstractString = "",
        fre_context::Union{JapanFiscalFREContext, Nothing} = nothing,
        assumptions::Vector{JapanFiscalScenarioAssumption} = JapanFiscalScenarioAssumption[],
        notes::AbstractString = "",
    )
        _jf_require_nonempty("JapanFiscalScenario.scenario_id", scenario_id)
        _jf_check(family, JAPAN_FISCAL_SCENARIO_FAMILIES, "scenario family")
        spec = japan_fiscal_family_spec(family)
        allowed = Set(vcat(spec.required_concepts, spec.optional_concepts))
        seen = Set{Symbol}()
        for a in assumptions
            a.concept in allowed || throw(
                ArgumentError(
                    "assumption concept $(repr(a.concept))（assumption_id=$(a.assumption_id)）は " *
                    "family=$(repr(family)) の required/optional concepts に含まれません" *
                    "（許容: $(sort(collect(allowed)))）。表現不能な概念を黙って無視せず construction 時に拒否する。",
                ),
            )
            a.concept in seen && throw(
                ArgumentError(
                    "concept $(repr(a.concept)) が複数の assumption で重複しています" *
                    "（assumption_id=$(a.assumption_id)）。1 scenario 内で同一 concept は 1 つの assumption のみ許容します。",
                ),
            )
            push!(seen, a.concept)
        end
        return new(
            String(scenario_id),
            family,
            String(name),
            fre_context,
            assumptions,
            provenance,
            String(notes),
        )
    end
end

"""
    japan_fiscal_assumption_set_hash(scenario::JapanFiscalScenario) -> String

`scenario.assumptions` のみを対象とした `"sha256:…"`。`fre_context` を含まないため、
FRE context だけを変えても値は変わらない（`H-05`。#276 の「applied model input」の identity は
この hash を用いる）。`assumption_id` 昇順に整列してから正準化するため、入力順に依存しない。
`notes` は表示専用として対象外。
"""
function japan_fiscal_assumption_set_hash(scenario::JapanFiscalScenario)::String
    sorted = sort(scenario.assumptions; by = a -> a.assumption_id)
    payload = Dict{String, Any}(
        "assumptions" => [
            Dict{String, Any}(
                "assumption_id" => a.assumption_id,
                "concept" => String(a.concept),
                "magnitude" => a.magnitude,
                "magnitude_source" => String(a.magnitude_source),
            ) for a in sorted
        ],
    )
    return "sha256:" * sha256_hex_of_canonical(payload)
end

"""
    japan_fiscal_scenario_content_hash(scenario::JapanFiscalScenario) -> String

`scenario` 全体（`fre_context`・assumption 集合・identity 対象 provenance を含む）を対象とした
`"sha256:…"`。同一の意味内容（同一 family・同一 assumption 集合・同一 FRE context・同一 identity
対象 provenance）から常に同一の値を得る（決定論的な scenario identity）。`created_at`・
`created_by`・`notes` は volatile として対象外。
"""
function japan_fiscal_scenario_content_hash(scenario::JapanFiscalScenario)::String
    p = scenario.provenance
    payload = Dict{String, Any}(
        "scenario_id" => scenario.scenario_id,
        "family" => String(scenario.family),
        "name" => scenario.name,
        "fre_context_identity" => scenario.fre_context === nothing ? nothing :
                                   japan_fiscal_fre_context_identity(scenario.fre_context),
        "assumption_set_hash" => japan_fiscal_assumption_set_hash(scenario),
        "provenance" => Dict{String, Any}(
            "schema_version" => p.schema_version,
            "capability_contract_version" => p.capability_contract_version,
            "claim_contract_version" => p.claim_contract_version,
            "assumption_source" => String(p.assumption_source),
        ),
    )
    return "sha256:" * sha256_hex_of_canonical(payload)
end

# ===========================================================================
# JapanFiscalScenarioCatalogEntry（scenario catalog。Issue #275 scope 2）
# ===========================================================================

"""
    JapanFiscalScenarioCatalogEntry

1 scenario family の catalog entry。`required_concepts`・`optional_concepts`・`guardrails` は
`japan_fiscal_family_spec(family)`（#274）から**そのまま**引く（独自に再定義しない。`H-01`。
`japan_fiscal_scenario_schema.jl` の load 時 invariant がこの一致を検査する）。

`concept_units`・`compatible_models`・`horizons`・`unsupported_channel_ids` は #274/#285 の
registry からの**導出**である。per-(family, model) の horizon（`JapanFiscalInputMapping.horizon`）
・persistence の選択は #276（adapter/runner）の責務であり、catalog は family 単位の値を
新たに定義しない（複数モデルで horizon が異なりうるため、単一の代表値へ縮約すると誤読を招く）。

## フィールド
- `family::Symbol` / `display_name::String` / `economic_meaning::String`
- `required_concepts::Vector{Symbol}` / `optional_concepts::Vector{Symbol}`
- `concept_units::Dict{String,String}` : concept => 単位（#274 `japan_fiscal_assumption_concept`）
- `guardrails::Vector{String}`
- `horizons::Vector{Symbol}` : この family の実装候補モデルが用いる `JAPAN_FISCAL_HORIZONS` の値
  （重複を除き、`:not_accepted` の入力は除く）
- `compatible_models::Vector{Symbol}` : `japan_fiscal_implementation_candidates(family)`
- `unsupported_channel_ids::Vector{Symbol}` : `:unsupported` の因果チャネル ID（#285）
- `capability_contract_version::String` / `claim_contract_version::String`
- `doc_ref::String`
"""
struct JapanFiscalScenarioCatalogEntry
    family::Symbol
    display_name::String
    economic_meaning::String
    required_concepts::Vector{Symbol}
    optional_concepts::Vector{Symbol}
    concept_units::Dict{String, String}
    guardrails::Vector{String}
    horizons::Vector{Symbol}
    compatible_models::Vector{Symbol}
    unsupported_channel_ids::Vector{Symbol}
    capability_contract_version::String
    claim_contract_version::String
    doc_ref::String
end

"""
    japan_fiscal_scenario_catalog_entry(family::Symbol) -> JapanFiscalScenarioCatalogEntry

`family` の catalog entry を #274/#285 の registry から構築する。
"""
function japan_fiscal_scenario_catalog_entry(family::Symbol)::JapanFiscalScenarioCatalogEntry
    _jf_check(family, JAPAN_FISCAL_SCENARIO_FAMILIES, "scenario family")
    spec = japan_fiscal_family_spec(family)
    concept_units = Dict{String, String}(
        String(c) => japan_fiscal_assumption_concept(c).unit for
        c in vcat(spec.required_concepts, spec.optional_concepts)
    )
    models = japan_fiscal_implementation_candidates(family)
    horizons = Symbol[]
    for model in models
        m = japan_fiscal_model_mapping(family, model)
        for inp in m.inputs
            inp.input_kind === :not_accepted && continue
            inp.horizon in horizons || push!(horizons, inp.horizon)
        end
    end
    unsupported_ids =
        Symbol[c.channel_id for c in japan_fiscal_channels(; family = family, status = :unsupported)]
    return JapanFiscalScenarioCatalogEntry(
        family,
        spec.display_name,
        spec.economic_meaning,
        spec.required_concepts,
        spec.optional_concepts,
        concept_units,
        spec.guardrails,
        horizons,
        models,
        unsupported_ids,
        JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION,
        JAPAN_FISCAL_CLAIM_CONTRACT_VERSION,
        spec.doc_ref,
    )
end

"""
    japan_fiscal_scenario_catalog() -> Dict{Symbol,JapanFiscalScenarioCatalogEntry}

5 scenario family すべての catalog entry。
"""
function japan_fiscal_scenario_catalog()::Dict{Symbol, JapanFiscalScenarioCatalogEntry}
    return Dict{Symbol, JapanFiscalScenarioCatalogEntry}(
        f => japan_fiscal_scenario_catalog_entry(f) for f in JAPAN_FISCAL_SCENARIO_FAMILIES
    )
end

"""
    japan_fiscal_scenario_schema_contract() -> Dict{String,Any}

本契約全体の機械可読 export。Market Analyzer は Julia 内部型を import せず、この Dict のみを
consume する（#274 `japan_fiscal_capability_matrix()`・#285 `japan_fiscal_downstream_contract()`
と同じ設計）。
"""
function japan_fiscal_scenario_schema_contract()::Dict{String, Any}
    return Dict{String, Any}(
        "schema_version" => JAPAN_FISCAL_SCENARIO_SCHEMA_VERSION,
        "capability_contract_version" => JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION,
        "claim_contract_version" => JAPAN_FISCAL_CLAIM_CONTRACT_VERSION,
        "fre_context_role" => String(JAPAN_FISCAL_FRE_CONTEXT_ROLE),
        "forbidden_magnitude_sources" => _jf_syms(JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_SOURCES),
        "forbidden_magnitude_input_fields" =>
            collect(JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_INPUT_FIELDS),
        "assumption_sources" => _jf_syms(JAPAN_FISCAL_ASSUMPTION_SOURCES),
        "assumption_concepts" => Dict{String, Any}(
            String(c) => to_dict(japan_fiscal_assumption_concept(c)) for
            c in JAPAN_FISCAL_ASSUMPTION_CONCEPTS
        ),
        "catalog" => Dict{String, Any}(
            String(f) => to_dict(japan_fiscal_scenario_catalog_entry(f)) for
            f in JAPAN_FISCAL_SCENARIO_FAMILIES
        ),
    )
end

# ===========================================================================
# to_dict / to_json
# ===========================================================================

to_dict(c::JapanFiscalFREContext) = Dict{String, Any}(
    "snapshot_id" => c.snapshot_id,
    "as_of" => Dates.format(c.as_of, "yyyy-mm-dd"),
    "vintage_basis" => c.vintage_basis,
    "regime_determination" => String(c.regime_determination),
    "primary_regime" => c.primary_regime,
    "regime_affinity" => c.regime_affinity,
    "regime_share" => c.regime_share,
    "regime_confidence" => c.regime_confidence,
    "dimension_score" => c.dimension_score,
    "constraint_pressure" => c.constraint_pressure,
    "dominant_drivers" => c.dominant_drivers,
    "data_quality_score" => c.data_quality_score,
    "methodology_version" => c.methodology_version,
    "policy_version" => c.policy_version,
    "notes" => c.notes,
    "context_identity" => japan_fiscal_fre_context_identity(c),
)

to_dict(a::JapanFiscalScenarioAssumption) = Dict{String, Any}(
    "assumption_id" => a.assumption_id,
    "concept" => String(a.concept),
    "unit" => japan_fiscal_assumption_unit(a),
    "magnitude" => a.magnitude,
    "direction" => String(japan_fiscal_assumption_direction(a)),
    "magnitude_source" => String(a.magnitude_source),
    "notes" => a.notes,
)

to_dict(p::JapanFiscalScenarioProvenance) = Dict{String, Any}(
    "schema_version" => p.schema_version,
    "capability_contract_version" => p.capability_contract_version,
    "claim_contract_version" => p.claim_contract_version,
    "assumption_source" => String(p.assumption_source),
    "created_at" => p.created_at === nothing ? nothing :
                    Dates.format(p.created_at, dateformat"yyyy-mm-ddTHH:MM:SS") * "Z",
    "created_by" => p.created_by,
)

function to_dict(s::JapanFiscalScenario)
    return Dict{String, Any}(
        "scenario_id" => s.scenario_id,
        "family" => String(s.family),
        "name" => s.name,
        "notes" => s.notes,
        "fre_context" => s.fre_context === nothing ? nothing : to_dict(s.fre_context),
        "fre_context_identity" => s.fre_context === nothing ? nothing :
                                   japan_fiscal_fre_context_identity(s.fre_context),
        "assumptions" => [to_dict(a) for a in s.assumptions],
        "assumption_set_hash" => japan_fiscal_assumption_set_hash(s),
        "provenance" => to_dict(s.provenance),
        "content_hash" => japan_fiscal_scenario_content_hash(s),
    )
end

to_dict(e::JapanFiscalScenarioCatalogEntry) = Dict{String, Any}(
    "family" => String(e.family),
    "display_name" => e.display_name,
    "economic_meaning" => e.economic_meaning,
    "required_concepts" => _jf_syms(e.required_concepts),
    "optional_concepts" => _jf_syms(e.optional_concepts),
    "concept_units" => e.concept_units,
    "guardrails" => e.guardrails,
    "horizons" => _jf_syms(e.horizons),
    "compatible_models" => _jf_syms(e.compatible_models),
    "unsupported_channel_ids" => _jf_syms(e.unsupported_channel_ids),
    "capability_contract_version" => e.capability_contract_version,
    "claim_contract_version" => e.claim_contract_version,
    "doc_ref" => e.doc_ref,
)

to_json(c::JapanFiscalFREContext) = JSON3.write(to_dict(c))
to_json(a::JapanFiscalScenarioAssumption) = JSON3.write(to_dict(a))
to_json(p::JapanFiscalScenarioProvenance) = JSON3.write(to_dict(p))
to_json(s::JapanFiscalScenario) = JSON3.write(to_dict(s))
to_json(e::JapanFiscalScenarioCatalogEntry) = JSON3.write(to_dict(e))

# ===========================================================================
# JSON decode（fail closed。scenario_serialization.jl の `_scenario_check_keys`・
# `_scenario_as_*` と同じ idiom をこのファイル専用に持つ）
# ===========================================================================

_jf_json_to_plain(x::JSON3.Object) =
    Dict{String, Any}(String(k) => _jf_json_to_plain(v) for (k, v) in x)
_jf_json_to_plain(x::JSON3.Array) = Any[_jf_json_to_plain(v) for v in x]
_jf_json_to_plain(x) = x

function _jf_check_keys(label::AbstractString, d::AbstractDict, required)
    present = Set(String(k) for k in keys(d))
    expected = Set(String(k) for k in required)
    missing_keys = sort(collect(setdiff(expected, present)))
    extra_keys = sort(collect(setdiff(present, expected)))
    isempty(missing_keys) || throw(
        ArgumentError("$(label): 必須フィールドが欠落しています: $(missing_keys)"),
    )
    isempty(extra_keys) ||
        throw(ArgumentError("$(label): 未知のキーが含まれています: $(extra_keys)"))
    return nothing
end

_jf_as_string(v, label::AbstractString) =
    v isa AbstractString ? String(v) :
    throw(ArgumentError("$label は文字列でなければなりません（実値: $(repr(v))）"))
_jf_as_symbol(v, label::AbstractString) = Symbol(_jf_as_string(v, label))
_jf_as_float(v, label::AbstractString) =
    v isa Real ? Float64(v) :
    throw(ArgumentError("$label は数値でなければなりません（実値: $(repr(v))）"))
_jf_as_date(v, label::AbstractString) =
    v isa AbstractString ? Date(v, dateformat"yyyy-mm-dd") :
    throw(ArgumentError("$label は \"YYYY-MM-DD\" 形式の文字列でなければなりません"))
function _jf_as_datetime(v, label::AbstractString)
    v isa AbstractString ||
        throw(ArgumentError("$label は ISO 8601 文字列でなければなりません"))
    s = endswith(v, "Z") ? v[1:(end - 1)] : v
    return DateTime(s, dateformat"yyyy-mm-ddTHH:MM:SS")
end
_jf_as_optional(f, v, label::AbstractString) = v === nothing ? nothing : f(v, label)

"""
    japan_fiscal_fre_context_from_dict(d) -> JapanFiscalFREContext

`to_dict(::JapanFiscalFREContext)` の round trip。`context_identity` を読み戻した値と再計算した
値が一致することを検査する（不一致は `ArgumentError`）。
"""
function japan_fiscal_fre_context_from_dict(d::AbstractDict)::JapanFiscalFREContext
    _jf_check_keys(
        "JapanFiscalFREContext",
        d,
        (
            "snapshot_id", "as_of", "vintage_basis", "regime_determination",
            "primary_regime", "regime_affinity", "regime_share", "regime_confidence",
            "dimension_score", "constraint_pressure", "dominant_drivers",
            "data_quality_score", "methodology_version", "policy_version", "notes",
            "context_identity",
        ),
    )
    ctx = JapanFiscalFREContext(;
        snapshot_id = _jf_as_string(d["snapshot_id"], "snapshot_id"),
        as_of = _jf_as_date(d["as_of"], "as_of"),
        vintage_basis = _jf_as_string(d["vintage_basis"], "vintage_basis"),
        regime_determination = _jf_as_symbol(
            d["regime_determination"],
            "regime_determination",
        ),
        primary_regime = _jf_as_optional(_jf_as_string, d["primary_regime"], "primary_regime"),
        regime_affinity = Dict{String, Float64}(
            String(k) => _jf_as_float(v, "regime_affinity[$k]") for
            (k, v) in d["regime_affinity"]
        ),
        regime_share = Dict{String, Float64}(
            String(k) => _jf_as_float(v, "regime_share[$k]") for (k, v) in d["regime_share"]
        ),
        regime_confidence = _jf_as_optional(
            _jf_as_float,
            d["regime_confidence"],
            "regime_confidence",
        ),
        dimension_score = Dict{String, Float64}(
            String(k) => _jf_as_float(v, "dimension_score[$k]") for
            (k, v) in d["dimension_score"]
        ),
        constraint_pressure = _jf_as_optional(
            _jf_as_float,
            d["constraint_pressure"],
            "constraint_pressure",
        ),
        dominant_drivers = String[
            _jf_as_string(x, "dominant_drivers[]") for x in d["dominant_drivers"]
        ],
        data_quality_score = _jf_as_optional(
            _jf_as_float,
            d["data_quality_score"],
            "data_quality_score",
        ),
        methodology_version = _jf_as_string(
            d["methodology_version"],
            "methodology_version",
        ),
        policy_version = _jf_as_string(d["policy_version"], "policy_version"),
        notes = _jf_as_string(d["notes"], "notes"),
    )
    expected_identity = _jf_as_string(d["context_identity"], "context_identity")
    recomputed_identity = japan_fiscal_fre_context_identity(ctx)
    expected_identity == recomputed_identity || throw(
        ArgumentError(
            "JapanFiscalFREContext: context_identity が内容と一致しません " *
            "(読み込んだ値: $(expected_identity), 再計算した値: $(recomputed_identity))",
        ),
    )
    return ctx
end

"""
    japan_fiscal_assumption_from_dict(d) -> JapanFiscalScenarioAssumption

`to_dict(::JapanFiscalScenarioAssumption)` の round trip。`unit`・`direction` は導出値として
読み込むが construction には使わない（`concept`/`magnitude` から再導出したものと不一致が
無いことを検査する）。
"""
function japan_fiscal_assumption_from_dict(d::AbstractDict)::JapanFiscalScenarioAssumption
    _jf_check_keys(
        "JapanFiscalScenarioAssumption",
        d,
        ("assumption_id", "concept", "unit", "magnitude", "direction", "magnitude_source", "notes"),
    )
    a = JapanFiscalScenarioAssumption(;
        assumption_id = _jf_as_string(d["assumption_id"], "assumption_id"),
        concept = _jf_as_symbol(d["concept"], "concept"),
        magnitude = _jf_as_float(d["magnitude"], "magnitude"),
        magnitude_source = _jf_as_symbol(d["magnitude_source"], "magnitude_source"),
        notes = _jf_as_string(d["notes"], "notes"),
    )
    expected_unit = _jf_as_string(d["unit"], "unit")
    expected_unit == japan_fiscal_assumption_unit(a) || throw(
        ArgumentError(
            "JapanFiscalScenarioAssumption(assumption_id=$(a.assumption_id)): unit が concept と一致しません " *
            "(読み込んだ値: $(expected_unit), concept から導出した値: $(japan_fiscal_assumption_unit(a)))",
        ),
    )
    expected_direction = _jf_as_symbol(d["direction"], "direction")
    expected_direction === japan_fiscal_assumption_direction(a) || throw(
        ArgumentError(
            "JapanFiscalScenarioAssumption(assumption_id=$(a.assumption_id)): direction が magnitude の符号と一致しません " *
            "(読み込んだ値: $(expected_direction), magnitude から導出した値: $(japan_fiscal_assumption_direction(a)))",
        ),
    )
    return a
end

function _jf_provenance_from_dict(d::AbstractDict)::JapanFiscalScenarioProvenance
    _jf_check_keys(
        "JapanFiscalScenarioProvenance",
        d,
        (
            "schema_version", "capability_contract_version", "claim_contract_version",
            "assumption_source", "created_at", "created_by",
        ),
    )
    return JapanFiscalScenarioProvenance(;
        schema_version = _jf_as_string(d["schema_version"], "schema_version"),
        capability_contract_version = _jf_as_string(
            d["capability_contract_version"],
            "capability_contract_version",
        ),
        claim_contract_version = _jf_as_string(
            d["claim_contract_version"],
            "claim_contract_version",
        ),
        assumption_source = _jf_as_symbol(d["assumption_source"], "assumption_source"),
        created_at = _jf_as_optional(_jf_as_datetime, d["created_at"], "created_at"),
        created_by = _jf_as_string(d["created_by"], "created_by"),
    )
end

"""
    japan_fiscal_scenario_from_dict(d) -> JapanFiscalScenario

`to_dict(::JapanFiscalScenario)` の round trip。`content_hash`・`assumption_set_hash`・
`fre_context_identity` を読み戻した値と再計算した値が一致することを検査する
（不一致は `ArgumentError`。JSON 化の過程で改変・欠落が起きていないことを検出する、`H-14`）。
`assumptions` が空でも正当な scenario として round trip する。
"""
function japan_fiscal_scenario_from_dict(d::AbstractDict)::JapanFiscalScenario
    _jf_check_keys(
        "JapanFiscalScenario",
        d,
        (
            "scenario_id", "family", "name", "notes", "fre_context", "fre_context_identity",
            "assumptions", "assumption_set_hash", "provenance", "content_hash",
        ),
    )
    fre_context = d["fre_context"] === nothing ? nothing :
                  japan_fiscal_fre_context_from_dict(d["fre_context"])
    assumptions_d = d["assumptions"]
    assumptions_d isa AbstractVector ||
        throw(ArgumentError("JapanFiscalScenario.assumptions は配列でなければなりません"))
    assumptions = JapanFiscalScenarioAssumption[
        japan_fiscal_assumption_from_dict(x) for x in assumptions_d
    ]
    scenario = JapanFiscalScenario(;
        scenario_id = _jf_as_string(d["scenario_id"], "scenario_id"),
        family = _jf_as_symbol(d["family"], "family"),
        name = _jf_as_string(d["name"], "name"),
        fre_context = fre_context,
        assumptions = assumptions,
        provenance = _jf_provenance_from_dict(d["provenance"]),
        notes = _jf_as_string(d["notes"], "notes"),
    )

    expected_fre_identity = _jf_as_optional(
        _jf_as_string,
        d["fre_context_identity"],
        "fre_context_identity",
    )
    recomputed_fre_identity = scenario.fre_context === nothing ? nothing :
                               japan_fiscal_fre_context_identity(scenario.fre_context)
    expected_fre_identity == recomputed_fre_identity || throw(
        ArgumentError("JapanFiscalScenario: fre_context_identity が内容と一致しません"),
    )

    expected_assumption_hash = _jf_as_string(d["assumption_set_hash"], "assumption_set_hash")
    expected_assumption_hash == japan_fiscal_assumption_set_hash(scenario) || throw(
        ArgumentError("JapanFiscalScenario: assumption_set_hash が内容と一致しません"),
    )

    expected_content_hash = _jf_as_string(d["content_hash"], "content_hash")
    expected_content_hash == japan_fiscal_scenario_content_hash(scenario) || throw(
        ArgumentError("JapanFiscalScenario: content_hash が内容と一致しません"),
    )

    return scenario
end

# ===========================================================================
# load 時 invariant（`H-01`: catalog は #274 の family spec から導出し再定義しない）
# ===========================================================================

let
    for f in JAPAN_FISCAL_SCENARIO_FAMILIES
        entry = japan_fiscal_scenario_catalog_entry(f)
        spec = japan_fiscal_family_spec(f)
        entry.required_concepts == spec.required_concepts || error(
            "japan_fiscal_scenario_schema.jl load時invariant違反: " *
            "family=$(f) の catalog required_concepts が japan_fiscal_family_spec と一致しません（H-01）",
        )
        entry.optional_concepts == spec.optional_concepts || error(
            "japan_fiscal_scenario_schema.jl load時invariant違反: " *
            "family=$(f) の catalog optional_concepts が japan_fiscal_family_spec と一致しません（H-01）",
        )
        entry.guardrails == spec.guardrails || error(
            "japan_fiscal_scenario_schema.jl load時invariant違反: " *
            "family=$(f) の catalog guardrails が japan_fiscal_family_spec と一致しません（H-01）",
        )
    end
end
