# scenario_types.jl: シナリオ集合と構造化拒否・警告の型（Issue #197 / `E-1`）。
#
# 本ファイルは `Scenario`・`ScenarioWarning`・`EventRejection` を定義する。統合設計 §4.1 は
# `scenario_types.jl` の最終的な責務として `ScheduledEvent`・`EventSchedule`・
# `ScenarioRunOptions`・`ScenarioRun`・`ScenarioProvenance` も同ファイルへ含めるが、これらは
# `run_scenario`（Issue #202 / `E-6`）の実装対象であり、本 Issue では追加しない
# （Issue #197 実施内容が明示する範囲: `ScenarioWarning`・`EventRejection`・`Scenario`）。
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
