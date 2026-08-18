# scenario_time.jl: シナリオ・イベント実行層の時間軸（Issue #197 / `E-1`・Issue #198 / `E-2`）。
#
# `CalendarQuarter`・`TimingRuleSet` の型（#197）に加え、四半期の暦日変換（`quarter_of`・
# `quarter_index`・`quarter_label`）・適用四半期の割当規則（`:same_quarter` / `:next_quarter` /
# `:cutoff` / `:explicit_period`、`resolve_t_apply`）・時間形状6種の離散式（`shock_shape_path`）
# の「規則の実装」（#198）を定義する。
#
# 設計契約:
#   docs/architecture/macro_event_runtime_integration.md §5.4（`CalendarQuarter`/`TimingRuleSet`
#     の型定義の正本）・§7.3（適用四半期の決定）・§7.4（時間形状6種、`Y-10`・`Y-11`・`Y-12`）・
#     §4.1（配置・依存）
#   docs/architecture/scenario_time_semantics.md §2.2（暦四半期の表現）・§4.3（`:cutoff` の
#     既定境界）・§5.2（時間形状の離散定義）・§11.1（時点指定の2基準、`Y-02`）・
#     §11.3（ホライズン境界を設定値から求める、`Y-09`）
#
# 依存: stdlib（`Dates`）に加え、`resolve_t_apply`（`EventTiming` を引数にとる）・
# `shock_shape_path`（`PersistenceSpec` を引数にとる）が `macro_events.jl` の型に依存するため、
# `src/DME.jl` の include 順序は **`macro_events.jl` → 本ファイル** とする（#197 時点の想定
# 「本ファイルは依存を持たず他ファイルより先に include される」を #198 実装時に修正した。
# `macro_events.jl` 自体は本ファイルの型 `CalendarQuarter`/`TimingRuleSet` を参照しないため、
# 逆順にしても安全である）。

# ------------------------------------------------------------
# CalendarQuarter（統合設計 §5.4）
# ------------------------------------------------------------

"""
    CalendarQuarter

暦四半期 `(year, quarter)`。表示形式は `"YYYYQn"`（例 `"2026Q1"`、
シナリオ時間軸の意味論 §2.2）。

## フィールド
- `year::Int`
- `quarter::Int`: `1:4` のいずれか。

`quarter ∉ 1:4` は構築時に `ArgumentError`（§6.1 の層 (1)）。暦日 ⇄ `CalendarQuarter` の変換
（`quarter_of`・`quarter_index`・`quarter_label`）は Issue #198 が実装する。
"""
struct CalendarQuarter
    year::Int
    quarter::Int

    function CalendarQuarter(year::Int, quarter::Int)
        quarter in 1:4 || throw(
            ArgumentError(
                "CalendarQuarter.quarter=$quarter は 1:4 のいずれかでなければなりません" *
                "（シナリオ時間軸の意味論 §2.2）",
            ),
        )
        return new(year, quarter)
    end
end

# ------------------------------------------------------------
# TimingRuleSet（統合設計 §5.4。適用四半期の割当規則の設定値）
# ------------------------------------------------------------

"""
    TimingRuleSet

適用四半期の割当規則の**設定値**（シナリオ時間軸の意味論 §4.3・統合設計 §7.3）。
コード変更を伴わずに結果を変えうる値（`cutoff_month_offset` 等）は必ず `id`/`version` を
持つ（ADR 0010 §7）。

## フィールド
- `id::String`: 規則セットの識別子（既定 `"default"`）。
- `version::String`: 規則セットの version（既定 `"timing-rule-set/1.0.0"`）。
  `cutoff_month_offset` 等の設定値を変えたら上げる。
- `cutoff_month_offset::Int`: `:cutoff` 規則の境界（当該四半期の第何月の末日か。既定 `2`
  = 第2月末日、シナリオ時間軸 §4.3）。
- `rules::Dict{Symbol,Symbol}`: `event_type => 割当規則`（シナリオ時間軸 §4.4）。
  既定は空 `Dict`（イベント型ごとの既定規則の登録は Issue #198/#199/#200 の対象）。

適用四半期の決定アルゴリズム（`offset(:cutoff, ...)` 等、シナリオ時間軸 §4.3・統合設計 §7.3）
の実装は Issue #198 が対象とする。本ファイルは設定値を保持する型のみを定義する。
"""
Base.@kwdef struct TimingRuleSet
    id::String = "default"
    version::String = "timing-rule-set/1.0.0"
    cutoff_month_offset::Int = 2
    rules::Dict{Symbol, Symbol} = Dict{Symbol, Symbol}()
end

# ------------------------------------------------------------
# 暦四半期変換（Issue #198 / `E-2`。統合設計 §5.4・§7.1-7.3）
# ------------------------------------------------------------

"""
    quarter_of(d::Date) -> CalendarQuarter

暦日 `d` が属する暦四半期を返す（シナリオ時間軸の意味論 §2.2）。暦年基準
（`Q1` = 1–3月、`Q2` = 4–6月、`Q3` = 7–9月、`Q4` = 10–12月）で、会計年度は用いない。
"""
function quarter_of(d::Date)
    q = div(Dates.month(d) - 1, 3) + 1
    return CalendarQuarter(Dates.year(d), q)
end

"""
    quarter_index(q::CalendarQuarter, zero::CalendarQuarter) -> Int

`zero` を `t = 0` として、`q` に対応するモデル期インデックス `t` を返す
（`t = 4·(year − year₀) + (quarter − quarter₀)`、シナリオ時間軸の意味論 §2.2）。
"""
function quarter_index(q::CalendarQuarter, zero::CalendarQuarter)
    return 4 * (q.year - zero.year) + (q.quarter - zero.quarter)
end

"""
    quarter_label(q::CalendarQuarter) -> String

`"YYYYQn"` 形式の表示文字列を返す（例 `"2026Q1"`、シナリオ時間軸の意味論 §2.2）。
"""
function quarter_label(q::CalendarQuarter)
    return string(q.year, "Q", q.quarter)
end

"""
    _scenario_time_cutoff_date(q::CalendarQuarter, timing_rules::TimingRuleSet) -> Date

`:cutoff` 規則の境界日（`q` の第 `timing_rules.cutoff_month_offset` 月の末日。既定は第2月末日、
シナリオ時間軸の意味論 §4.3）。`cutoff_month_offset` はモデル方程式へハードコードせず、
`TimingRuleSet` の設定値として外部化する。
"""
function _scenario_time_cutoff_date(q::CalendarQuarter, timing_rules::TimingRuleSet)
    first_month = 3 * (q.quarter - 1) + 1
    cutoff_month = first_month + timing_rules.cutoff_month_offset - 1
    return Dates.lastdayofmonth(Date(q.year, cutoff_month, 1))
end

"""
    _scenario_time_calendar_offset(rule, effective_from, q, timing_rules) -> Int

`:calendar` 基準の割当規則3種（統合設計 §7.3）に対応するオフセットを返す。

```
offset(:same_quarter, …)  = 0
offset(:next_quarter, …)  = 1
offset(:cutoff, d, q, rs) = d ≤ cutoff_date(q, rs) ? 0 : 1
```
"""
function _scenario_time_calendar_offset(
    rule::Symbol,
    effective_from::Date,
    q::CalendarQuarter,
    timing_rules::TimingRuleSet,
)
    if rule === :same_quarter
        return 0
    elseif rule === :next_quarter
        return 1
    elseif rule === :cutoff
        return effective_from <= _scenario_time_cutoff_date(q, timing_rules) ? 0 : 1
    end
    throw(
        ArgumentError(
            "EventTiming.rule=$rule は basis=:calendar のとき :same_quarter/:next_quarter/" *
            ":cutoff のいずれかでなければなりません（シナリオ時間軸の意味論 §11.1）",
        ),
    )
end

"""
    resolve_t_apply(timing::EventTiming, period_zero::Union{CalendarQuarter,Nothing},
                     timing_rules::TimingRuleSet = TimingRuleSet()) -> Int

`EventTiming` から適用四半期 `t_apply` を決定する（統合設計 §7.2-7.3、`Y-02`）。

- `timing.basis === :period` のとき: `timing.t_apply` をそのまま返す（`:explicit_period`）。
- `timing.basis === :calendar` のとき: `effective_from` を `period_zero` 起点の
  `quarter_index` へ写し、`timing.rule`（`:same_quarter`/`:next_quarter`/`:cutoff`）に応じた
  オフセットを加える（統合設計 §7.3）。`period_zero === nothing` は `ArgumentError`
  （`period_zero_required` の型レベル防止、統合設計 §5.4）。

`out_of_horizon`（統合設計 §7.3・`Y-09`）の判定は行わない。呼び出し側（`schedule_events`）が
ホライズン設定に対して行う。
"""
function resolve_t_apply(
    timing::EventTiming,
    period_zero::Union{CalendarQuarter, Nothing},
    timing_rules::TimingRuleSet = TimingRuleSet(),
)
    timing.basis === :period && return timing.t_apply
    period_zero === nothing && throw(
        ArgumentError(
            "period_zero_required: timing.basis=:calendar のとき period_zero は必須です" *
            "（シナリオ時間軸の意味論 §2.1・統合設計 §5.4）",
        ),
    )
    q = quarter_of(timing.effective_from)
    t_raw = quarter_index(q, period_zero)
    offset =
        _scenario_time_calendar_offset(timing.rule, timing.effective_from, q, timing_rules)
    return t_raw + offset
end

# ------------------------------------------------------------
# 持続・減衰の時間形状6種（Issue #198 / `E-2`。統合設計 §7.4、`Y-10`・`Y-11`・`Y-12`）
# ------------------------------------------------------------

function _scenario_time_shape_value(
    p::PersistenceSpec,
    m::Float64,
    t0::Int,
    t::Int,
    t_until::Union{Int, Nothing},
)
    t < t0 && return 0.0
    t_until !== nothing && t > t_until && return 0.0
    shape = p.shape
    if shape === :pulse
        return t == t0 ? m : 0.0
    elseif shape === :step
        D = p.duration
        return (D === nothing || t < t0 + D) ? m : 0.0
    elseif shape === :ramp
        D = p.duration
        return t < t0 + D ? m * (t - t0 + 1) / D : m
    elseif shape === :step_then_ramp
        H = p.params.hold
        R = p.params.ramp_down
        t < t0 + H && return m
        t < t0 + H + R && return m * (1 - (t - t0 - H + 1) / R)
        return 0.0
    elseif shape === :ar1_decay
        h = p.params.half_life
        D = p.duration
        (D !== nothing && t >= t0 + D) && return 0.0
        rho = 0.5^(1 / h)
        return m * rho^(t - t0)
    else # :path
        values = p.params.values
        i = t - t0 + 1
        (i < 1 || i > length(values)) && return 0.0
        return Float64(values[i])
    end
end

"""
    shock_shape_path(p::PersistenceSpec, magnitude::Float64, t0::Int,
                      periods::Vector{Int}, t_until::Union{Int,Nothing}) -> Vector{Float64}

持続・減衰の時間形状6種（`MACRO_EVENT_SHAPES`）の離散式（シナリオ時間軸の意味論 §5.2・
統合設計 §7.4）に従い、`periods` の各期における `a_t` を計算して返す。

`t < t0` は常に `0`。`t_until` が指定されている場合、`t > t_until` では形状によらず一律に
`0` とする（打ち切り、`Y-11`）。既存 `capex_exogenous_paths` が用いる4形状（`:step`・`:ramp`・
`:ar1_decay`・`:step_then_ramp`）は既存実装（`_ccc_shock_active`/`_ccc_shock_value`）と
同一の演算順序・同一の数式を用い、同一パラメータで同一ベクトルを返す（`Y-10`）。
"""
function shock_shape_path(
    p::PersistenceSpec,
    magnitude::Float64,
    t0::Int,
    periods::Vector{Int},
    t_until::Union{Int, Nothing},
)
    return [_scenario_time_shape_value(p, magnitude, t0, t, t_until) for t in periods]
end
