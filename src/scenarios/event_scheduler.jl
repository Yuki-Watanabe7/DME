# event_scheduler.jl: イベントの全順序・固定順合成・外生パス生成（Issue #198 / `E-2`）。
#
# 本ファイルは `Vector{AppliedModelInput}`（L4）を、決定論的な全順序で並べ、baseline 外生パス
# （`Dict{Symbol,Vector{Float64}}`）へ合成し、監査用の `EventLogEntry` を生成する。**モデル状態・
# 外部データ・ファイルシステム・時計へアクセスしない pure transformation** である（統合設計 §5.5
# 契約1）。乱数を用いない。
#
# 設計契約:
#   docs/architecture/macro_event_runtime_integration.md §5.5（`ScheduledEvent`・`EventSchedule`・
#     `schedule_events`・`compose_exogenous_paths` の型・シグネチャ）・§6（失敗契約の3層分離）・
#     §7.5（全順序 `order_key` と固定順合成）・§9.1（`EventLogEntry` 14項目）
#   docs/architecture/macro_event_contract.md §5.1（全順序）・§5.2（固定順合成）・§5.4（競合検出）
#
# `EventSchedule.rejections`（`Vector{EventRejection}`）は本書 §5.5 の抜粋コードブロックには
# 明示されていないが、Issue #198 本文が要求する「duplicate・conflicting absolute・相反
# direction・範囲外イベント・重複期間を構造化して分類する」を非例外（fail closed）で満たすために
# 追加する。`schedule_events` は例外を投げず、`rejections` が非空のとき `run_scenario`
# （Issue #202）が `status = :rejected_mapping` へ落とす想定である。

# ------------------------------------------------------------
# 型（統合設計 §5.5・§9.1）
# ------------------------------------------------------------

"""
    ScheduledEvent

全順序で整列された1件の `AppliedModelInput`（統合設計 §5.5）。

## フィールド
- `input::AppliedModelInput`
- `t_apply::Int`
- `order_key::Tuple{Int,Int,Int,String,String}`: `(t_apply, event_class_rank, target_rank,
  timing_sort_key, input_id)`（統合設計 §7.5）。
"""
struct ScheduledEvent
    input::AppliedModelInput
    t_apply::Int
    order_key::Tuple{Int, Int, Int, String, String}
end

"""
    EventLogEntry

適用した1件の `L4` について、監査に必要な情報を記録する（統合設計 §9.1 の14項目）。

`event_type`・`schema_version`・`timing_basis`・`timing_rule`・`effective_from`・
`effective_until`・`magnitude_source` は `Scenario.assumptions` から `assumption_id` で
遡って得る（`AppliedModelInput` 自体は持たない）。対応する `ScenarioAssumption` が見つからない
場合は `nothing` / `:period` / `:explicit_period` の既定値を用いる。

`pre_value`/`post_value`/`baseline_value` は**当該イベント群**（同一 `target_variable` へ写る
全 `AppliedModelInput`）の合成適用前後の値であり、個々のイベント単独の反実仮想値ではない
（統合設計 §9.1 item 9 の「当該イベント群の」を group-level の値として解釈する）。
"""
struct EventLogEntry
    input_id::String
    assumption_id::String
    derived_from::Vector{String}
    event_type::Union{Symbol, Nothing}
    schema_version::String
    t_apply::Int
    timing_basis::Symbol
    timing_rule::Symbol
    effective_from::Union{Date, Nothing}
    effective_until::Union{Date, Nothing}
    target_variable::Symbol
    application_mode::Symbol
    unit::String
    shape::Symbol
    shape_params::NamedTuple
    duration::Union{Int, Nothing}
    magnitude::Float64
    magnitude_source::Union{Symbol, Nothing}
    baseline_value::Vector{Float64}
    pre_value::Vector{Float64}
    post_value::Vector{Float64}
    applied_delta::Vector{Float64}
    composition_members::Vector{String}
    order_key::Tuple{Int, Int, Int, String, String}
    rule_id::String
    rule_version::String
    mapping_id::String
    mapping_version::String
    warnings::Vector{Symbol}
end

"""
    EventSchedule

`schedule_events` の戻り値（統合設計 §5.5）。

## フィールド
- `events::Vector{ScheduledEvent}`: `order_key` 昇順。
- `paths::Dict{Symbol,Vector{Float64}}`: 合成済み外生パス。`baseline` のキー集合と一致する。
- `log::Vector{EventLogEntry}`
- `warnings::Vector{ScenarioWarning}`
- `rejections::Vector{EventRejection}`: `conflicting_absolute` 等（本書冒頭コメント参照）。
- `periods::Vector{Int}`
"""
struct EventSchedule
    events::Vector{ScheduledEvent}
    paths::Dict{Symbol, Vector{Float64}}
    log::Vector{EventLogEntry}
    warnings::Vector{ScenarioWarning}
    rejections::Vector{EventRejection}
    periods::Vector{Int}
end

# ------------------------------------------------------------
# 全順序（統合設計 §7.5、`Y-13`）
# ------------------------------------------------------------

function _event_scheduler_class_rank(application_mode::Symbol)
    application_mode === :absolute && return 1
    application_mode === :multiplicative && return 2
    application_mode === :additive && return 3
    throw(
        ArgumentError(
            "未知の application_mode: $(application_mode)（$(MACRO_EVENT_APPLICATION_MODES) の" *
            "いずれかでなければなりません）",
        ),
    )
end

"""
    _event_scheduler_timing_sort_key(assumption, t_apply) -> String

`order_key` 第4要素（統合設計 §7.5・`Y-13`）。`:calendar` 基準は `effective_from` の
`"YYYY-MM-DD"`、`:period` 基準（または対応する `ScenarioAssumption` が見つからない場合）は
`t_apply` の符号付き0埋め文字列（例 `"+0003"`）。
"""
function _event_scheduler_timing_sort_key(
    assumption::Union{ScenarioAssumption, Nothing},
    t_apply::Int,
)
    if assumption !== nothing && assumption.timing.basis === :calendar
        return Dates.format(assumption.timing.effective_from, "yyyy-mm-dd")
    end
    sign_char = t_apply < 0 ? "-" : "+"
    return sign_char * lpad(abs(t_apply), 4, "0")
end

# ------------------------------------------------------------
# 構造化分類: duplicate / out_of_horizon（統合設計 §6.2・§7.3、`Y-09`）
# ------------------------------------------------------------

function _event_scheduler_filter_out_of_horizon(
    inputs::Vector{AppliedModelInput},
    horizon_runup::Int,
    horizon_eval::Int,
)
    warnings = ScenarioWarning[]
    in_range = AppliedModelInput[]
    for inp in inputs
        if inp.t_apply < -horizon_runup || inp.t_apply > horizon_eval - 1
            push!(
                warnings,
                ScenarioWarning(;
                    code = :out_of_horizon,
                    period = inp.t_apply,
                    subject_ids = [inp.input_id],
                    target_variable = inp.target_variable,
                    detail = "t_apply=$(inp.t_apply) はホライズン [-$(horizon_runup), " *
                             "$(horizon_eval - 1)] の外のため適用しません（統合設計 §7.3、`Y-09`）",
                ),
            )
        else
            push!(in_range, inp)
        end
    end
    return in_range, warnings
end

function _event_scheduler_drop_duplicates(inputs::Vector{AppliedModelInput})
    warnings = ScenarioWarning[]
    seen = Set{String}()
    deduped = AppliedModelInput[]
    for inp in inputs
        if inp.input_id in seen
            push!(
                warnings,
                ScenarioWarning(;
                    code = :duplicate_dropped,
                    period = inp.t_apply,
                    subject_ids = [inp.input_id],
                    target_variable = inp.target_variable,
                    detail = "input_id=$(inp.input_id) が重複して渡されました。先に現れたものを" *
                             "採用し、重複はログ（warnings）に残して適用対象からは除きます",
                ),
            )
        else
            push!(seen, inp.input_id)
            push!(deduped, inp)
        end
    end
    return deduped, warnings
end

"""
    _event_scheduler_offsetting_warnings(inputs) -> Vector{ScenarioWarning}

同一 `(t_apply, target_variable)` に符号の異なる `magnitude` を持つイベントが集まっている場合
（相殺）に `offsetting_events` を警告する（統合設計 §7.5 契約2）。相殺を理由にイベントを除去
しない。
"""
function _event_scheduler_offsetting_warnings(inputs::Vector{AppliedModelInput})
    groups = Dict{Tuple{Int, Symbol}, Vector{AppliedModelInput}}()
    for inp in inputs
        key = (inp.t_apply, inp.target_variable)
        push!(get!(() -> AppliedModelInput[], groups, key), inp)
    end
    warnings = ScenarioWarning[]
    for key in sort(collect(keys(groups)); by = k -> (k[1], String(k[2])))
        group = groups[key]
        length(group) < 2 && continue
        signs = Set(sign(inp.magnitude) for inp in group if inp.magnitude != 0.0)
        length(signs) <= 1 && continue
        t_apply, target = key
        net = sum(inp.magnitude for inp in group)
        gross = [inp.magnitude for inp in group]
        push!(
            warnings,
            ScenarioWarning(;
                code = :offsetting_events,
                period = t_apply,
                subject_ids = [inp.input_id for inp in group],
                target_variable = target,
                detail = "t_apply=$(t_apply) の $(target) で符号の異なるイベントが相殺しています" *
                         "（net=$(net)、gross=$(gross)）。相殺を理由にイベントを除去していません" *
                         "（統合設計 §7.5 契約2）",
            ),
        )
    end
    return warnings
end

"""
    _event_scheduler_conflicting_absolute(inputs, periods) -> Vector{EventRejection}

同一 `target_variable` に `:absolute` のイベントが期を跨いで同時活性化する場合を検出する
（統合設計 §7.5・`conflicting_absolute`）。活性判定は `values[idx] != 0.0` を用いる
（`AppliedModelInput` は `t_until` を保持しないため形状から活性窓を再計算できない。`magnitude`
が厳密に `0.0` の `:absolute` イベントは本判定の対象外という限界を持つ）。
"""
function _event_scheduler_conflicting_absolute(
    inputs::Vector{AppliedModelInput},
    periods::Vector{Int},
)
    by_target = Dict{Symbol, Vector{AppliedModelInput}}()
    for inp in inputs
        inp.application_mode === :absolute || continue
        push!(get!(() -> AppliedModelInput[], by_target, inp.target_variable), inp)
    end
    rejections = EventRejection[]
    for target in sort(collect(keys(by_target)); by = String)
        abs_inputs = by_target[target]
        length(abs_inputs) < 2 && continue
        conflict_periods = Int[]
        conflict_ids = Set{String}()
        for (idx, t) in enumerate(periods)
            active = [inp for inp in abs_inputs if inp.values[idx] != 0.0]
            if length(active) > 1
                push!(conflict_periods, t)
                for inp in active
                    push!(conflict_ids, inp.input_id)
                end
            end
        end
        isempty(conflict_periods) && continue
        push!(
            rejections,
            EventRejection(;
                code = :conflicting_absolute,
                layer = :applied,
                subject_ids = sort(collect(conflict_ids)),
                target_concept = nothing,
                detail = "target=$target で :absolute のイベントが同時に複数活性化する期が" *
                         "あります（t=$(conflict_periods)）。モデルは単一の絶対値しか保持できず、" *
                         "1つに定まりません（統合設計 §7.5）",
            ),
        )
    end
    return rejections
end

# ------------------------------------------------------------
# 固定順合成（統合設計 §7.5・§7.4 反映式）
# ------------------------------------------------------------

function _event_scheduler_applied_delta(
    application_mode::Symbol,
    pre::Vector{Float64},
    post::Vector{Float64},
)
    if application_mode === :multiplicative
        return [p == 0.0 ? 0.0 : post[i] / p - 1 for (i, p) in enumerate(pre)]
    end
    return post .- pre
end

"""
    compose_exogenous_paths(baseline, inputs, periods;
                             assumptions = Dict{String,ScenarioAssumption}()) ->
        Tuple{Dict{Symbol,Vector{Float64}},Vector{EventLogEntry}}

`inputs`（**既に全順序で整列済み**であることを前提とする）を `baseline` へ合成する
（統合設計 §5.5・§7.5）。同一 `target_variable` に集まる `inputs` を `:absolute` →
`:multiplicative` → `:additive` の固定順で、各クラス内は与えられた順（呼び出し側の全順序）で
逐次適用する（総和・総積を先に計算しない、統合設計 §8.3「演算順序の保存」と同型の規律）。

`assumptions`（`assumption_id => ScenarioAssumption`）を与えると、`EventLogEntry` の
`event_type`/`schema_version`/`timing_basis`/`timing_rule`/`effective_from`/
`effective_until`/`magnitude_source` を埋める（省略時は `nothing`/既定値）。

`paths` のキー集合は `baseline` のキー集合と一致する。`inputs` の `target_variable` が
`baseline` に無い場合は無視する（適用先7変数以外への防御）。
"""
function compose_exogenous_paths(
    baseline::Dict{Symbol, Vector{Float64}},
    inputs::Vector{AppliedModelInput},
    periods::Vector{Int};
    assumptions::Dict{String, ScenarioAssumption} = Dict{String, ScenarioAssumption}(),
    order_keys::Dict{String, Tuple{Int, Int, Int, String, String}} = Dict{
        String,
        Tuple{Int, Int, Int, String, String},
    }(),
)
    n = length(periods)
    paths = Dict{Symbol, Vector{Float64}}(k => copy(v) for (k, v) in baseline)

    by_target = Dict{Symbol, Vector{AppliedModelInput}}()
    for inp in inputs
        push!(get!(() -> AppliedModelInput[], by_target, inp.target_variable), inp)
    end

    log = EventLogEntry[]
    for target in keys(by_target)
        haskey(paths, target) || continue
        group = by_target[target]
        base_series = baseline[target]
        abs_inputs = filter(i -> i.application_mode === :absolute, group)
        mul_inputs = filter(i -> i.application_mode === :multiplicative, group)
        add_inputs = filter(i -> i.application_mode === :additive, group)

        post_series = Vector{Float64}(undef, n)
        for idx in 1:n
            x = base_series[idx]
            active_abs = [i for i in abs_inputs if i.values[idx] != 0.0]
            if !isempty(active_abs)
                x = active_abs[end].values[idx]
            end
            for i in mul_inputs
                a = i.values[idx]
                a == 0.0 && continue
                x *= 1 + a / 100
            end
            for i in add_inputs
                a = i.values[idx]
                a == 0.0 && continue
                x += a
            end
            post_series[idx] = x
        end
        paths[target] = post_series

        pre_copy = copy(base_series)
        post_copy = copy(post_series)
        member_ids = [i.input_id for i in group]
        for inp in group
            assumption = get(assumptions, inp.assumption_id, nothing)
            order_key = get(
                order_keys,
                inp.input_id,
                (inp.t_apply, _event_scheduler_class_rank(inp.application_mode), 0, "", inp.input_id),
            )
            push!(
                log,
                EventLogEntry(
                    inp.input_id,
                    inp.assumption_id,
                    inp.provenance.derived_from,
                    assumption === nothing ? nothing : assumption.event_type,
                    assumption === nothing ? MACRO_EVENT_CONTRACT_VERSION : assumption.schema_version,
                    inp.t_apply,
                    assumption === nothing ? :period : assumption.timing.basis,
                    assumption === nothing ? :explicit_period : assumption.timing.rule,
                    assumption === nothing ? nothing : assumption.timing.effective_from,
                    assumption === nothing ? nothing : assumption.timing.effective_until,
                    inp.target_variable,
                    inp.application_mode,
                    inp.unit,
                    inp.persistence.shape,
                    inp.persistence.params,
                    inp.persistence.duration,
                    inp.magnitude,
                    assumption === nothing ? nothing : assumption.magnitude_source,
                    pre_copy,
                    pre_copy,
                    post_copy,
                    _event_scheduler_applied_delta(inp.application_mode, pre_copy, post_copy),
                    member_ids,
                    order_key,
                    inp.provenance.rule_id,
                    inp.provenance.rule_version,
                    inp.mapping_id,
                    inp.mapping_version,
                    inp.warnings,
                ),
            )
        end
    end

    return paths, log
end

# ------------------------------------------------------------
# schedule_events（統合設計 §5.5）
# ------------------------------------------------------------

"""
    schedule_events(inputs::Vector{AppliedModelInput}, sc::Scenario,
                     baseline::Dict{Symbol,Vector{Float64}}) -> EventSchedule

`inputs`（`L4`）を統合設計 §7.5 の全順序（`order_key`）で整列し、`baseline` へ合成した
`EventSchedule` を返す。**モデル状態・外部データ・ファイルシステム・時計へアクセスしない**
pure transformation である（統合設計 §5.5 契約1）。乱数を用いない。例外を投げない
（構造化拒否は `rejections`、警告は `warnings` へ集める）。

`target_rank`（`order_key` 第3要素）は `baseline` のキー反復順を正本とする。呼び出し側が
`exogenous_variables(m)` の順序で `baseline` を構築することを前提とする（Julia の `Dict` は
削除を伴わない挿入順を反復順として保持する）。

処理順序: `out_of_horizon` 除外 → `duplicate_dropped` 除外 → 全順序ソート → 固定順合成
（`compose_exogenous_paths`） → `conflicting_absolute`/`offsetting_events` 検出。
"""
function schedule_events(
    inputs::Vector{AppliedModelInput},
    sc::Scenario,
    baseline::Dict{Symbol, Vector{Float64}},
)
    periods = collect((-sc.horizon_runup):(sc.horizon_eval - 1))
    assumption_by_id = Dict(a.assumption_id => a for a in sc.assumptions)

    in_range, horizon_warnings = _event_scheduler_filter_out_of_horizon(
        inputs,
        sc.horizon_runup,
        sc.horizon_eval,
    )
    deduped, duplicate_warnings = _event_scheduler_drop_duplicates(in_range)

    target_order = collect(keys(baseline))
    target_rank = Dict(v => i for (i, v) in enumerate(target_order))

    scheduled = ScheduledEvent[]
    for inp in deduped
        assumption = get(assumption_by_id, inp.assumption_id, nothing)
        tsk = _event_scheduler_timing_sort_key(assumption, inp.t_apply)
        rank = get(target_rank, inp.target_variable, typemax(Int) - 1)
        ck = _event_scheduler_class_rank(inp.application_mode)
        order_key = (inp.t_apply, ck, rank, tsk, inp.input_id)
        push!(scheduled, ScheduledEvent(inp, inp.t_apply, order_key))
    end
    sort!(scheduled; by = se -> se.order_key)

    ordered_inputs = [se.input for se in scheduled]
    order_keys = Dict(se.input.input_id => se.order_key for se in scheduled)
    paths, log = compose_exogenous_paths(
        baseline,
        ordered_inputs,
        periods;
        assumptions = assumption_by_id,
        order_keys = order_keys,
    )

    rejections = _event_scheduler_conflicting_absolute(ordered_inputs, periods)
    offsetting_warnings = _event_scheduler_offsetting_warnings(ordered_inputs)

    warnings = vcat(horizon_warnings, duplicate_warnings, offsetting_warnings)

    return EventSchedule(scheduled, paths, log, warnings, rejections, periods)
end
