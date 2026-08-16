# capex_credit_cycle_scenarios.jl: 部門別CAPEX・信用循環モデル（`CapexCreditCycleModel`）専用の
# 比較シナリオ Sc0–Sc4 の定義と外生パス合成（Issue #182 / `I-4`）。
#
# シナリオ実行層とイベント実行層（Phase 2）の唯一の接続点は `capex_exogenous_paths` が返す
# `Dict{Symbol,Vector{Float64}}` である（ADR 0013 決定21）。`CapexShockSpec` はイベント属性
# （公表日・出所・解釈シグナル・原文）を持たない（同 決定22）。イベント型・`run_scenario`・
# イベントログは本ファイルの対象外（Phase 2）。
#
# 設計契約:
#   docs/architecture/capex_credit_cycle_integration.md §4.6・§7.4-1（本Issueの正本）
#   docs/models/capex_credit_cycle_analysis_contract.md §5（比較シナリオ Sc0–Sc4・ショック定義）
#   docs/architecture/macro_event_contract.md §3.3（単位×適用方式の許容表。§12.1 の X-18 改訂を反映）・
#     §4.1-4.2（適用先7変数）・§5.1-5.2（決定論的全順序・固定順合成）
#   docs/architecture/scenario_time_semantics.md §5.2（時間形状の離散定義）
#   docs/adr/0013-capex-credit-cycle-integration-contract.md 決定21-23

# ------------------------------------------------------------
# シナリオID（分析契約 §5.1）
# ------------------------------------------------------------

"""
    CAPEX_CC_SCENARIO_IDS

初期MVPの比較シナリオID（分析契約 §5.1）。`Sc1 ⊂ Sc2 ⊂ Sc3 ⊂ Sc4` の入れ子性を持つ
（統合設計 §4.6・ADR 0013 決定23）。
"""
const CAPEX_CC_SCENARIO_IDS = (:Sc0, :Sc1, :Sc2, :Sc3, :Sc4)

const _CCC_SCENARIO_NAMES = Dict{Symbol, String}(
    :Sc0 => "baseline",
    :Sc1 => "expectation_only",
    :Sc2 => "expectation_capex",
    :Sc3 => "capex_credit",
    :Sc4 => "capex_credit_easing",
)

# ------------------------------------------------------------
# 単位 × application_mode の許容表（イベント変換契約 §3.3。§12.1 の X-18 改訂を反映）
# ------------------------------------------------------------

const _CCC_UNIT_APPLICATION_MODE_TABLE = Dict{String, Tuple{Vararg{Symbol}}}(
    "%" => (:multiplicative,),
    "bp" => (:additive,),
    "%pt" => (:additive, :absolute),
    "bn USD (2017 chained)" => (:absolute, :additive, :multiplicative),
)

const _CCC_SHOCK_SHAPES = (:step, :ramp, :ar1_decay, :step_then_ramp)
const _CCC_APPLICATION_MODES = (:absolute, :multiplicative, :additive)

# ------------------------------------------------------------
# CapexShockSpec（統合設計 §4.6。分析契約 §5.2 の指定必須7項目 + 適用に必要な3項目）
# ------------------------------------------------------------

"""
    CapexShockSpec

ショック1件の仕様。分析契約 §5.2 の指定必須7項目（`target`・`meaning`・`unit`・`sign`・
`timing`・`shape`・`duration`）に、適用に必要な3項目（`shape_params`・`magnitude`・
`application_mode`）を加えたもの。

`AbstractMacroEvent` の前身ではない。イベントの4層分離（マクロイベント変換契約 §2.1）に
従い、公表日・出所・解釈シグナル・原文などのイベント属性を持ち込まない
（ADR 0013 決定22）。

## フィールド
- `target::Symbol`: 適用先。`exogenous_variables(m)` の7変数のいずれか。
- `meaning::String`: 経済的な意味。
- `unit::String`: 単位（`"%"` / `"bp"` / `"%pt"` / `"bn USD (2017 chained)"`。
  マクロイベント変換契約 §3.3）。
- `sign::Int`: 符号の向き（`+1` / `-1`）。`magnitude` の符号と一致しなければならない。
- `timing::Int`: 適用開始四半期（`t = 0` 起点。シナリオ時間軸 §2.1）。
- `shape::Symbol`: 時間形状（`:step` / `:ramp` / `:ar1_decay` / `:step_then_ramp`。
  シナリオ時間軸 §5.2 の離散定義）。
- `shape_params::NamedTuple`: 形状パラメータ。`:ar1_decay` は `half_life`、
  `:step_then_ramp` は `hold`・`ramp_down` を必須とする。`:step`・`:ramp` は
  `duration` フィールドのみで完結するため既定で空。
- `duration::Union{Int,Nothing}`: `:step` の持続四半期数（`nothing` = 恒久）、
  `:ramp` の立ち上がり四半期数（必須）、`:ar1_decay` の打ち切り四半期数
  （`nothing` = 打ち切りなし。恒久減衰）、`:step_then_ramp` の合計四半期数
  （`hold + ramp_down`。参考値）。
- `magnitude::Float64`: ショックの大きさ（`unit` と同一単位）。**省略できない**
  （捏造禁止、ADR 0010 決定4）。
- `application_mode::Symbol`: `:absolute` / `:multiplicative` / `:additive`
  （マクロイベント変換契約 §5.2）。

## 反映式（シナリオ時間軸 §5.3）
`x_t^{base}` を baseline 値、`a_t` を形状関数の値とする。
- `:absolute`: `x_t = a_t`
- `:multiplicative`: `x_t = x_t^{base} · (1 + a_t/100)`（`a_t` は `"%"`）
- `:additive`: `x_t = x_t^{base} + a_t`
"""
struct CapexShockSpec
    target::Symbol
    meaning::String
    unit::String
    sign::Int
    timing::Int
    shape::Symbol
    shape_params::NamedTuple
    duration::Union{Int, Nothing}
    magnitude::Float64
    application_mode::Symbol

    function CapexShockSpec(;
        target::Symbol,
        meaning::AbstractString,
        unit::AbstractString,
        sign::Int,
        timing::Int,
        shape::Symbol,
        magnitude::Float64,
        application_mode::Symbol,
        shape_params::NamedTuple = NamedTuple(),
        duration::Union{Int, Nothing} = nothing,
    )
        _ccc_validate_shock_spec(
            target,
            unit,
            sign,
            shape,
            shape_params,
            duration,
            magnitude,
            application_mode,
        )
        return new(
            target,
            String(meaning),
            String(unit),
            sign,
            timing,
            shape,
            shape_params,
            duration,
            magnitude,
            application_mode,
        )
    end
end

function _ccc_validate_shock_spec(
    target::Symbol,
    unit::AbstractString,
    sign::Int,
    shape::Symbol,
    shape_params::NamedTuple,
    duration::Union{Int, Nothing},
    magnitude::Float64,
    application_mode::Symbol,
)
    target in CAPEX_CC_EXOGENOUS_VARIABLES || throw(
        ArgumentError(
            "CapexShockSpec.target=$target は exogenous_variables(m) の7変数" *
            "（$(CAPEX_CC_EXOGENOUS_VARIABLES)）に含まれません" *
            "（マクロイベント変換契約 §4.1。control/state 変数への直接適用は禁止）",
        ),
    )
    sign in (1, -1) || throw(
        ArgumentError(
            "CapexShockSpec.sign は +1 または -1 でなければなりません（実値: $sign）",
        ),
    )
    if magnitude != 0.0 && Int(Base.sign(magnitude)) != sign
        throw(
            ArgumentError(
                "CapexShockSpec.sign=$sign が magnitude=$magnitude の符号と一致しません",
            ),
        )
    end
    application_mode in _CCC_APPLICATION_MODES || throw(
        ArgumentError(
            "CapexShockSpec.application_mode=$application_mode は " *
            "$(_CCC_APPLICATION_MODES) のいずれかでなければなりません",
        ),
    )
    shape in _CCC_SHOCK_SHAPES || throw(
        ArgumentError(
            "CapexShockSpec.shape=$shape は $(_CCC_SHOCK_SHAPES) のいずれかでなければなりません" *
            "（シナリオ時間軸 §5.2 が定義する4種に限る）",
        ),
    )
    allowed = get(_CCC_UNIT_APPLICATION_MODE_TABLE, String(unit), nothing)
    allowed === nothing && throw(
        ArgumentError(
            "CapexShockSpec.unit=\"$unit\" はマクロイベント変換契約 §3.3 の単位語彙にありません" *
            "（許容: $(collect(keys(_CCC_UNIT_APPLICATION_MODE_TABLE)))）",
        ),
    )
    application_mode in allowed || throw(
        ArgumentError(
            "invalid_unit_mode: unit=\"$unit\" と application_mode=$application_mode の組み合わせは" *
            "マクロイベント変換契約 §3.3（§12.1 改訂後）の許容表にありません（許容: $allowed）",
        ),
    )
    if shape === :ramp
        (duration isa Int && duration > 0) || throw(
            ArgumentError(
                "CapexShockSpec: shape=:ramp は duration（ramp_up期間、正の整数）を必須とします" *
                "（実値: $duration）",
            ),
        )
    elseif shape === :step
        (duration === nothing || duration > 0) || throw(
            ArgumentError(
                "CapexShockSpec: shape=:step の duration は正の整数または nothing（恒久）で" *
                "なければなりません（実値: $duration）",
            ),
        )
    elseif shape === :ar1_decay
        haskey(shape_params, :half_life) || throw(
            ArgumentError(
                "CapexShockSpec: shape=:ar1_decay は shape_params.half_life を必須とします",
            ),
        )
        shape_params.half_life > 0 || throw(
            ArgumentError(
                "CapexShockSpec: shape_params.half_life は正でなければなりません" *
                "（実値: $(shape_params.half_life)）",
            ),
        )
        (duration === nothing || duration > 0) || throw(
            ArgumentError(
                "CapexShockSpec: shape=:ar1_decay の duration（打ち切り四半期数）は正の整数" *
                "または nothing（打ち切りなし）でなければなりません（実値: $duration）",
            ),
        )
    else # :step_then_ramp
        (haskey(shape_params, :hold) && haskey(shape_params, :ramp_down)) || throw(
            ArgumentError(
                "CapexShockSpec: shape=:step_then_ramp は shape_params.hold・ramp_down を" *
                "必須とします",
            ),
        )
        (shape_params.hold > 0 && shape_params.ramp_down > 0) || throw(
            ArgumentError(
                "CapexShockSpec: shape_params.hold・ramp_down は正でなければなりません" *
                "（実値: hold=$(shape_params.hold), ramp_down=$(shape_params.ramp_down)）",
            ),
        )
    end
    return nothing
end

# ------------------------------------------------------------
# 時間形状の離散定義（シナリオ時間軸 §5.2。t < timing では 0）
#
# `_ccc_shock_value` の内部実装は共通層 `src/scenarios/scenario_time.jl` の `shock_shape_path`
# へ委譲する（統合設計 §8.3・`Y-23`。Issue #198）。`_ccc_shock_active` は `:absolute` 合成の
# 「1件のみ許可」検査専用の活性判定であり、委譲対象ではない（値0との区別に用いるため独立に
# 保持する）。**戻り値の数値は委譲前と bit 単位で変わらない**（同一の演算順序・同一の数式を
# 用いるため）。
# ------------------------------------------------------------

"""
    _ccc_shock_active(shock, t) -> Bool

期 `t` にショックが作用しているか（`shock.magnitude` を実際に用いるべきか）を判定する。
`:absolute` 適用の合成（§5.2 の「1件のみ許可」検査）で、値0との区別に用いる。
"""
function _ccc_shock_active(shock::CapexShockSpec, t::Int)
    t < shock.timing && return false
    if shock.shape === :step
        shock.duration === nothing && return true
        return t < shock.timing + shock.duration
    elseif shock.shape === :ramp
        return true
    elseif shock.shape === :ar1_decay
        shock.duration === nothing && return true
        return t < shock.timing + shock.duration
    else # :step_then_ramp
        total = shock.shape_params.hold + shock.shape_params.ramp_down
        return t < shock.timing + total
    end
end

"""
    _ccc_persistence_spec(shock::CapexShockSpec) -> PersistenceSpec

`CapexShockSpec` の形状指定（`shape`・`duration`・`shape_params`）を共通層の `PersistenceSpec`
へ写す（`shock_shape_path` への委譲のため）。`CapexShockSpec` に `AppliedModelInput` の属性を
持たせない（統合設計 §8.3 契約3）。
"""
function _ccc_persistence_spec(shock::CapexShockSpec)
    return PersistenceSpec(;
        shape = shock.shape,
        duration = shock.duration,
        params = shock.shape_params,
    )
end

"""
    _ccc_shock_value(shock, t) -> Float64

期 `t` における `a_t`（シナリオ時間軸 §5.2 の形状定義に沿った値）。`shock` が非作用の期は
`0.0` を返す（`:multiplicative`/`:additive` の合成における単位元）。共通層 `shock_shape_path`
（`src/scenarios/scenario_time.jl`）へ委譲する（`Y-23`。打ち切りは行わないため `t_until` は
`nothing`）。
"""
function _ccc_shock_value(shock::CapexShockSpec, t::Int)
    _ccc_shock_active(shock, t) || return 0.0
    persistence = _ccc_persistence_spec(shock)
    return shock_shape_path(persistence, shock.magnitude, shock.timing, [t], nothing)[1]
end

# ------------------------------------------------------------
# CapexScenario と Sc0–Sc4（統合設計 §4.6・分析契約 §5.1）
# ------------------------------------------------------------

"""
    CapexScenario

`id`（`CAPEX_CC_SCENARIO_IDS` のいずれか）・`name`（`_CCC_SCENARIO_NAMES` の表示名）・
`shocks`（適用するショックの一覧）を保持する。
"""
struct CapexScenario
    id::Symbol
    name::String
    shocks::Vector{CapexShockSpec}

    function CapexScenario(id::Symbol, name::AbstractString, shocks::Vector{CapexShockSpec})
        id in CAPEX_CC_SCENARIO_IDS || throw(
            ArgumentError(
                "CapexScenario.id=$id は $(CAPEX_CC_SCENARIO_IDS) のいずれかでなければなりません",
            ),
        )
        return new(id, String(name), shocks)
    end
end

"""
    _ccc_default_shock_sequence() -> Vector{CapexShockSpec}

`Sc4` の完全なショック列（分析契約 §5.3 の暫定既定値: `SH-EXP`・`SH-CAPEX`・`SH-CREDIT`・
`SH-EASING`、この順）。`capex_scenario` は本列を先頭から切り出すことで `Sc1 ⊂ Sc2 ⊂ Sc3 ⊂ Sc4`
の入れ子性を構造的に保証する（ADR 0013 決定23）。**規模はすべて暫定既定値であり、実データ較正値
ではない**（分析契約 §5.3・#170）。
"""
function _ccc_default_shock_sequence()
    return CapexShockSpec[
        CapexShockSpec(;                        # SH-EXP（E1）
            target = :ai_exp,
            meaning = "AI計算需要・収益期待の下方修正",
            unit = "%",
            sign = -1,
            timing = 0,
            shape = :ar1_decay,
            shape_params = (half_life = 6,),
            duration = nothing,
            magnitude = -10.0,
            application_mode = :multiplicative,
        ),
        CapexShockSpec(;                        # SH-CAPEX（E2）
            target = :capex_plan_shock_ex,
            meaning = "hyperscalerのCAPEX計画縮小（期待経由の内生反応への上乗せ）",
            unit = "%",
            sign = -1,
            timing = 0,
            shape = :step_then_ramp,
            shape_params = (hold = 4, ramp_down = 4),
            duration = 8,
            magnitude = -15.0,
            application_mode = :multiplicative,
        ),
        CapexShockSpec(;                        # SH-CREDIT
            target = :spread_shock_ex,
            meaning = "社債スプレッド拡大・借換条件悪化・貸出態度引き締め",
            unit = "bp",
            sign = 1,
            timing = 1,
            shape = :ar1_decay,
            shape_params = (half_life = 4,),
            duration = nothing,
            magnitude = 150.0,
            application_mode = :additive,
        ),
        CapexShockSpec(;                        # SH-EASING（100bp = 1%ptで%pt換算）
            target = :policy_rate,
            meaning = "金融緩和による政策金利引き下げ",
            unit = "%pt",
            sign = -1,
            timing = 2,
            shape = :step,
            shape_params = NamedTuple(),
            duration = 8,
            magnitude = -1.0,
            application_mode = :additive,
        ),
    ]
end

"""
    capex_scenario(id::Symbol) -> CapexScenario

`Sc0`（baseline・ショックなし）〜`Sc4`（`SH-EXP`+`SH-CAPEX`+`SH-CREDIT`+`SH-EASING`）を返す
（分析契約 §5.1）。`Sc4` のショック列を先頭から切り出す構成により、下位シナリオのショックは
上位シナリオでも同一の `target`・`unit`・`timing`・`shape`・`duration`・`magnitude` を持つ
（入れ子性、統合設計 §7.4-1）。
"""
function capex_scenario(id::Symbol)
    id in CAPEX_CC_SCENARIO_IDS || throw(
        ArgumentError(
            "未知のシナリオID: $(id)。$(CAPEX_CC_SCENARIO_IDS) のいずれかを指定してください",
        ),
    )
    n_shocks = findfirst(==(id), CAPEX_CC_SCENARIO_IDS) - 1
    all_shocks = _ccc_default_shock_sequence()
    return CapexScenario(id, _CCC_SCENARIO_NAMES[id], all_shocks[1:n_shocks])
end

# ------------------------------------------------------------
# 外生パス合成（マクロイベント変換契約 §5.2 の固定順合成: 絶対 → 乗算 → 加算）
# ------------------------------------------------------------

"""
    capex_exogenous_paths(m::CapexCreditCycleModel, scenario::CapexScenario,
                           options::CapexCreditCycleOptions = CapexCreditCycleOptions())
        -> Dict{Symbol,Vector{Float64}}

`scenario` のショックを baseline 外生パス（`_ccc_baseline_exog`）へ合成し、
`capex_run`/`simulate` の `exog` キーワードへそのまま渡せる `Dict{Symbol,Vector{Float64}}` を
返す。**イベント実行層（Phase 2）との接続点はこの1点に限定する**（ADR 0013 決定21）。

## 合成規則（マクロイベント変換契約 §5.2）
同一 `(t, target)` に複数ショックが集まる場合、`application_mode` のクラスごとに
`絶対 → 乗算 → 加算` の固定順で合成する。
- `:absolute` は1件のみ許可（複数あれば `ArgumentError`。`conflicting_absolute`）。
- `:multiplicative` はクラス内で積、`:additive` はクラス内で和（いずれも可換）。

`scenario.shocks` が空（`Sc0`）の場合、baseline 値をそのまま返す。
"""
function capex_exogenous_paths(
    m::CapexCreditCycleModel,
    scenario::CapexScenario,
    options::CapexCreditCycleOptions = CapexCreditCycleOptions(),
)
    n = options.horizon_runup + options.horizon_eval
    periods = collect((-options.horizon_runup):(options.horizon_eval - 1))
    paths = _ccc_baseline_exog(m, n)

    isempty(scenario.shocks) && return paths

    shocks_by_target = Dict{Symbol, Vector{CapexShockSpec}}()
    for shock in scenario.shocks
        push!(get!(() -> CapexShockSpec[], shocks_by_target, shock.target), shock)
    end

    for (target, shocks) in shocks_by_target
        series = paths[target]
        abs_shocks = filter(s -> s.application_mode === :absolute, shocks)
        mul_shocks = filter(s -> s.application_mode === :multiplicative, shocks)
        add_shocks = filter(s -> s.application_mode === :additive, shocks)

        for (idx, t) in enumerate(periods)
            active_abs = [s for s in abs_shocks if _ccc_shock_active(s, t)]
            length(active_abs) <= 1 || throw(
                ArgumentError(
                    "conflicting_absolute: t=$t の $target に :absolute のショックが" *
                    "$(length(active_abs))件あります（マクロイベント変換契約 §5.2-3）",
                ),
            )
            x = isempty(active_abs) ? series[idx] : _ccc_shock_value(active_abs[1], t)
            for s in mul_shocks
                x *= 1 + _ccc_shock_value(s, t) / 100
            end
            for s in add_shocks
                x += _ccc_shock_value(s, t)
            end
            series[idx] = x
        end
    end

    return paths
end
