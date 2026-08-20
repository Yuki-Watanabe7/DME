# scenario_types.jl: シナリオ集合と構造化拒否・警告の型（Issue #197 / `E-1`）・
# `run_scenario` の実行契約型（Issue #202 / `E-6`）。
#
# 本ファイルは `Scenario`・`ScenarioWarning`・`EventRejection`（Issue #197）に加えて
# `SCENARIO_EXECUTION_STATUSES`・`ScenarioRunOptions`・`ScenarioProvenance`（Issue #202）を
# 定義する。統合設計 §4.1 は `ScheduledEvent`・`EventSchedule` も本ファイルの責務としているが、
# 実装（Issue #198）は両者を `event_scheduler.jl` へ置いた（同ファイル冒頭コメント参照）。
# `ScenarioRun`・`run_scenario` 本体は `src/scenarios/scenario_runner.jl`（Issue #202）が担う。
#
# `ScenarioProvenance` のフィールドは統合設計 §9.2 の再現契約タプル
# `(model_version, contract_versions, scenario_id, scenario_version, event_set_hash,
#   rule_version, mapping_version, params_hash, initial_state_id, solver_settings_hash,
#   timing_rule_set)` と1:1対応する。ハッシュの実際の算出（型写像 encoder・
# `event_set_hash`・`scenario_content_hash`・`params_hash`・`initial_state_id`・
# `solver_settings_hash`）は `scenario_runner.jl` が提供する（`scenario_provenance.jl` への
# 分離・`scenario_to_dict`/`_from_dict`・`save_scenario_artifact`/`replay_scenario` は
# Issue #203 / `E-7` の対象）。
#
# `Scenario` 自体の**集合レベルの構造化検証**（`mixed_timing_basis`・`period_zero_required`・
# `horizon_mismatch` 等、統合設計 §6.1 の層(2)）は `run_scenario` の実行ステップ1が担う
# （統合設計 §5.7）。本ファイルの `Scenario` コンストラクタは単一レコードとして構築できない
# 値（層(1)）のみを検証し、複数 `assumptions` にまたがる整合性は検証しない。
#
# 設計契約:
#   docs/architecture/macro_event_runtime_integration.md §5.4（Scenario）・§6.2（EventRejection・
#     ScenarioWarning の型定義）・§11 `E-1` 行
#   docs/architecture/macro_event_contract.md §5.4（競合・矛盾の検出）・§5.5（重複投入の検出）

# ------------------------------------------------------------
# EventRejection（統合設計 §6.2）
# ------------------------------------------------------------

function _macro_event_check_rejection_detail(code::Symbol, detail::AbstractString)
    for forbidden in ("影響が無い", "効果が無い")
        occursin(forbidden, detail) && throw(
            ArgumentError(
                "EventRejection.detail に「$forbidden」を含めることはできません。" *
                "「モデルが構造上その事象を表現しない」旨を記述する" *
                "（マクロイベント変換契約 §4.5・統合設計 §6.2 契約1）",
            ),
        )
    end
    if code === :unmapped_target
        any(occursin(kw, detail) for kw in ("構造上", "表現しない", "表現できない")) ||
            throw(
                ArgumentError(
                    "EventRejection(code=:unmapped_target).detail は「モデルが構造上その事象を" *
                    "表現しない」旨を含めなければなりません（実値: \"$detail\"。マクロイベント変換契約 §4.5）",
                ),
            )
    end
    return nothing
end

"""
    EventRejection

構造化拒否（統合設計 §6.2）。`MACRO_EVENT_REJECTION_CODES` のいずれかの `code` を持ち、
`ScenarioRun`（Issue #202）の `rejections` へ集めて返す。**モデルを実行しない**（fail closed）。

## フィールド
- `code::Symbol`: `MACRO_EVENT_REJECTION_CODES` のいずれか。
- `layer::Symbol`: `MACRO_EVENT_LAYERS` のいずれか（拒否が生じた層）。
- `subject_ids::Vector{String}`: 関係する `event_id`/`assumption_id`。
- `event_type::Union{Symbol,Nothing}`
- `target_concept::Union{Symbol,Nothing}`
- `detail::String`: 日本語で「何が構造上表現されないか」を述べる。「影響が無い」「効果が無い」
  を含めてはいけない（マクロイベント変換契約 §4.5）。`code=:unmapped_target` のときは
  構造上の非表現である旨を含める。
- `upstream_issue::String`: 差し戻しID（`"D1"`–`"D4"`）または `""`。
"""
struct EventRejection
    code::Symbol
    layer::Symbol
    subject_ids::Vector{String}
    event_type::Union{Symbol, Nothing}
    target_concept::Union{Symbol, Nothing}
    detail::String
    upstream_issue::String

    function EventRejection(;
        code::Symbol,
        layer::Symbol,
        detail::AbstractString,
        subject_ids::Vector{String} = String[],
        event_type::Union{Symbol, Nothing} = nothing,
        target_concept::Union{Symbol, Nothing} = nothing,
        upstream_issue::AbstractString = "",
    )
        _macro_event_check_enum("EventRejection.code", code, MACRO_EVENT_REJECTION_CODES)
        _macro_event_check_enum("EventRejection.layer", layer, MACRO_EVENT_LAYERS)
        _macro_event_require_nonempty("EventRejection.detail", detail)
        _macro_event_check_rejection_detail(code, detail)
        return new(
            code,
            layer,
            subject_ids,
            event_type,
            target_concept,
            String(detail),
            String(upstream_issue),
        )
    end
end

# ------------------------------------------------------------
# ScenarioWarning（統合設計 §6.2）
# ------------------------------------------------------------

"""
    ScenarioWarning

警告（統合設計 §6.2）。`MACRO_EVENT_WARNING_CODES` のいずれかの `code` を持つ。実行は
妨げない。

## フィールド
- `code::Symbol`: `MACRO_EVENT_WARNING_CODES` のいずれか。
- `period::Union{Int,Nothing}`: 関係する期（`t`）。
- `subject_ids::Vector{String}`
- `target_variable::Union{Symbol,Nothing}`
- `detail::String`
"""
struct ScenarioWarning
    code::Symbol
    period::Union{Int, Nothing}
    subject_ids::Vector{String}
    target_variable::Union{Symbol, Nothing}
    detail::String

    function ScenarioWarning(;
        code::Symbol,
        detail::AbstractString,
        period::Union{Int, Nothing} = nothing,
        subject_ids::Vector{String} = String[],
        target_variable::Union{Symbol, Nothing} = nothing,
    )
        _macro_event_check_enum("ScenarioWarning.code", code, MACRO_EVENT_WARNING_CODES)
        return new(code, period, subject_ids, target_variable, String(detail))
    end
end

# ------------------------------------------------------------
# Scenario（統合設計 §5.4）
# ------------------------------------------------------------

"""
    Scenario

シナリオの時間軸設定と仮定集合（統合設計 §5.4）。`assumptions` が空でも**正当な baseline**
であり、実行して baseline 系列を返す（Issue #202 の受け入れ条件）。

`Scenario` は**モデルを保持しない**（`model::Symbol` は registry symbol のみ）。モデル
インスタンスは実行時に渡す（`run_scenario(m, scenario)`）。

`assumptions` 全体にまたがる整合性検証（`timing.basis` の混在拒否・`period_zero` の要否・
`horizon_runup`/`horizon_eval` と `CapexCreditCycleOptions` の一致等）は `run_scenario`
（Issue #202）の実行ステップ1が行う。本コンストラクタは行わない。

## フィールド
- `id::Symbol`
- `name::String`
- `version::String`
- `model::Symbol`: registry symbol（例 `:capex_credit_cycle`）。
- `period_zero::Union{CalendarQuarter,Nothing}`: `:calendar` 基準の仮定を含む場合は必須
  （`run_scenario` が検証）。
- `horizon_runup::Int` / `horizon_eval::Int`
- `assumptions::Vector{ScenarioAssumption}`
- `timing_rules::TimingRuleSet`
- `defaults_set_id::String` / `defaults_set_version::String`: 既定値セットの識別子と version。
- `notes::String`
"""
struct Scenario
    id::Symbol
    name::String
    version::String
    model::Symbol
    period_zero::Union{CalendarQuarter, Nothing}
    horizon_runup::Int
    horizon_eval::Int
    assumptions::Vector{ScenarioAssumption}
    timing_rules::TimingRuleSet
    defaults_set_id::String
    defaults_set_version::String
    notes::String

    function Scenario(;
        id::Symbol,
        model::Symbol,
        name::AbstractString = "",
        version::AbstractString = "scenario/1.0.0",
        period_zero::Union{CalendarQuarter, Nothing} = nothing,
        horizon_runup::Int = 8,
        horizon_eval::Int = 20,
        assumptions::Vector{ScenarioAssumption} = ScenarioAssumption[],
        timing_rules::TimingRuleSet = TimingRuleSet(),
        defaults_set_id::AbstractString = "",
        defaults_set_version::AbstractString = "",
        notes::AbstractString = "",
    )
        return new(
            id,
            String(name),
            String(version),
            model,
            period_zero,
            horizon_runup,
            horizon_eval,
            assumptions,
            timing_rules,
            String(defaults_set_id),
            String(defaults_set_version),
            String(notes),
        )
    end
end

# ------------------------------------------------------------
# 実行ステータス（統合設計 §6.3、Issue #202 / `E-6`）
# ------------------------------------------------------------

"""
    SCENARIO_EXECUTION_STATUSES

`run_scenario` が返す `ScenarioRun.status` の4値（統合設計 §6.3）。5値目を追加しない。

- `:completed`: 全イベントが適用され、モデルが `:completed` で終了した。
- `:rejected_validation`: `Scenario` 自体の検証に失敗（重複ID・timing基準の混在・
  horizon不一致・model不一致 等）。`result === nothing`・`exog === nothing`。
- `:rejected_mapping`: mapping または合成の段階で拒否（`unmapped_target`・
  `conflicting_absolute` 等）。`result === nothing`・`exog === nothing`。
- `:terminated`: 外生パスは構成できたが、モデルが `termination_reason ≠ :completed` で
  終了した。`result`・`exog` は非 `nothing`（有効区間まで）。

警告の有無は status に影響しない（`ScenarioRun.warnings` フィールドで表す）。
"""
const SCENARIO_EXECUTION_STATUSES =
    (:completed, :rejected_validation, :rejected_mapping, :terminated)

# ------------------------------------------------------------
# ScenarioRunOptions（統合設計 §5.7、Issue #202 / `E-6`）
# ------------------------------------------------------------

"""
    ScenarioRunOptions

`run_scenario` の実行設定（統合設計 §5.7）。

## フィールド
- `on_unmapped::Symbol`: `:reject`（既定・fail closed）または `:warn`（`Y-06`）。
  `:reject` のとき、1件でも `unmapped_target` があれば `status = :rejected_mapping` と
  なりモデルを実行しない。`:warn` のとき `unmapped_target_accepted` 警告を記録し、
  残りのイベントで実行する。
- `confidence_threshold::Union{Float64,Nothing}`: 既定 `nothing`（`Y-16`）。明示指定した
  ときのみ `low_confidence` 警告を出す。`confidence` はいかなる場合も magnitude・
  適用可否に作用しない。
- `extreme_shock_ratio::Float64`: 既定 `0.50`。baseline比 ±この比率超で `extreme_shock`
  警告を出す。
- `timing_sensitive_days::Int`: 既定 `14`。`:calendar` 基準のイベントについて cutoff
  近傍判定（`timing_sensitive` 警告、#168 時間軸 §4.6）に用いる。
- `validate_accounting::Bool`: 既定 `true`。`true` のとき `validate_capex_accounting` を
  呼び `ScenarioRun.accounting` へ格納する。
- `diagnostics::Bool`: 既定 `true`。`true` のとき `capex_diagnostics` を呼び
  `ScenarioRun.diagnostics` へ格納する。
- `model_options`: `CapexCreditCycleOptions` または `nothing`（既定。`nothing` のときは
  `Scenario` の `horizon_runup`/`horizon_eval` から構成する）。
- `thresholds`: `CapexDiagnosticThresholds` または `nothing`（既定。`nothing` のときは
  既定の `CapexDiagnosticThresholds()` を用いる）。
"""
Base.@kwdef struct ScenarioRunOptions
    on_unmapped::Symbol = :reject
    confidence_threshold::Union{Float64, Nothing} = nothing
    extreme_shock_ratio::Float64 = 0.50
    timing_sensitive_days::Int = 14
    validate_accounting::Bool = true
    diagnostics::Bool = true
    model_options = nothing
    thresholds = nothing
end

# ------------------------------------------------------------
# ScenarioProvenance（統合設計 §9.2 の再現契約タプル、Issue #202 / `E-6`）
# ------------------------------------------------------------

"""
    ScenarioProvenance

統合設計 §9.2「再現契約」のタプル
`(model_version, contract_versions, scenario_id, scenario_version, event_set_hash,
rule_version, mapping_version, params_hash, initial_state_id, solver_settings_hash,
timing_rule_set)` を1:1で保持するレコード型。`ScenarioRun.provenance` として
`run_scenario` が構築する。これらが一致するのに結果が異なる場合、それは実装のバグである
（統合設計 §9.2）。

## フィールド
- `model_version::String`: `m.contract_versions.model_version`。
- `contract_versions::Dict{String,String}`: イベント層 version 定数の一覧。
- `scenario_id::String` / `scenario_version::String`
- `event_set_hash::String`: `"sha256:…"`（`Scenario.assumptions` のみを対象、`event_set_hash`
  関数）。
- `rule_version::String`: `EVENT_RULE_VERSION`。
- `mapping_version::String`: `CAPEX_CC_EVENT_MAPPING_VERSION`。
- `params_hash::String`: `"sha256:…"`（`parameters(m)` の正準 JSON）。
- `initial_state_id::String`: `state0` の正準 JSON の SHA-256。`state0 === nothing` の
  ときは文字列 `"steady_state"`。
- `solver_settings_hash::String`: `"sha256:…"`（`CapexCreditCycleOptions` 全フィールド）。
- `timing_rule_set::Dict{String,Any}`: `TimingRuleSet` の `id`/`version`。

ハッシュの算出関数（`event_set_hash`・`scenario_content_hash`・型写像 encoder）は
`scenario_runner.jl` が定義する（Issue #203 / `E-7` が `scenario_provenance.jl` へ完成させる
までの暫定配置。統合設計 §11 `E-7` 行）。
"""
struct ScenarioProvenance
    model_version::String
    contract_versions::Dict{String, String}
    scenario_id::String
    scenario_version::String
    event_set_hash::String
    rule_version::String
    mapping_version::String
    params_hash::String
    initial_state_id::String
    solver_settings_hash::String
    timing_rule_set::Dict{String, Any}
end
