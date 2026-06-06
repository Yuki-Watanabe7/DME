"""
    ISLMModel <: AbstractMacroModel

IS-LMモデル。財市場（IS曲線）と貨幣市場（LM曲線）の同時均衡を計算する静学モデル。

## 消費関数パラメータ
- `c0` : 自律消費 (c0 > 0)
- `c1` : 限界消費性向 MPC (0 < c1 < 1)

## 投資関数パラメータ
- `I0` : 自律投資 (I0 > 0)
- `b`  : 投資の利子率感応度 (b > 0)

## 外生変数
- `G`  : 政府支出 (G ≥ 0)
- `T`  : 税 (T ≥ 0)
- `M`  : 名目マネーサプライ (M > 0)
- `P`  : 物価水準 (P > 0, 固定)

## 貨幣需要パラメータ
- `l1` : 貨幣需要の所得感応度 (l1 > 0)
- `l2` : 貨幣需要の利子率感応度 (l2 > 0)
"""
struct ISLMModel <: AbstractMacroModel
    c0::Float64
    c1::Float64
    I0::Float64
    b::Float64
    G::Float64
    T::Float64
    l1::Float64
    l2::Float64
    M::Float64
    P::Float64
end

model_name(::ISLMModel) = "IS-LM Model"
state_variables(::ISLMModel) = Symbol[]
control_variables(::ISLMModel) = [:Y, :r]
parameters(m::ISLMModel) = (
    c0 = m.c0,
    c1 = m.c1,
    I0 = m.I0,
    b = m.b,
    G = m.G,
    T = m.T,
    l1 = m.l1,
    l2 = m.l2,
    M = m.M,
    P = m.P,
)

"""
    islm_equilibrium(m::ISLMModel) -> (Y, r, C, I)

IS-LM均衡を解析的に計算する。

IS曲線:  Y = c0 + c1*(Y-T) + I0 - b*r + G
LM曲線:  M/P = l1*Y - l2*r

同時均衡:
  Y* = (l2*A + b*M/P) / (b*l1 + l2*(1-c1))
  r* = (l1*Y* - M/P) / l2

ここで A = c0 - c1*T + I0 + G（乗数前の財需要の切片）
"""
function islm_equilibrium(m::ISLMModel)
    A = m.c0 + m.I0 + m.G - m.c1 * m.T
    MP = m.M / m.P
    denom = m.b * m.l1 + m.l2 * (1 - m.c1)
    Y = (m.l2 * A + m.b * MP) / denom
    r = (m.l1 * Y - MP) / m.l2
    C = m.c0 + m.c1 * (Y - m.T)
    I = m.I0 - m.b * r
    return Y, r, C, I
end

"""
    steady_state(m::ISLMModel) -> NamedTuple

IS-LM均衡（Y*, r*, C*, I*）を NamedTuple で返す。
"""
function steady_state(m::ISLMModel)
    Y, r, C, I = islm_equilibrium(m)
    (Y = Y, r = r, C = C, I = I)
end

"""
    simulate(m::ISLMModel) -> NamedTuple

均衡値を長さ1のベクトルとして返す。`to_simulation_result` との互換性のために提供する。
"""
function simulate(m::ISLMModel)
    eq = steady_state(m)
    (Y = [eq.Y], r = [eq.r], C = [eq.C], I = [eq.I])
end

"""
    islm_policy_shock(m_base, m_policy; scenario_names) -> SimulationResult

ベースラインと政策ショック後の均衡を比較する。

返り値の SimulationResult は変数ごとに長さ2のベクトルを持つ。
インデックス1がベースライン、インデックス2が政策後の値。

## 例

```julia
# 政府支出増加の効果
m_base   = ISLMModel(100.0, 0.8, 200.0, 50.0, 100.0, 100.0, 0.2, 100.0, 1000.0, 1.0)
m_fiscal = ISLMModel(100.0, 0.8, 200.0, 50.0, 150.0, 100.0, 0.2, 100.0, 1000.0, 1.0)
result = DME.islm_policy_shock(m_base, m_fiscal; scenario_names=("baseline", "fiscal_expansion"))
```
"""
function islm_policy_shock(
    m_base::ISLMModel,
    m_policy::ISLMModel;
    scenario_names::Tuple{String, String} = ("baseline", "policy"),
)
    eq_base = steady_state(m_base)
    eq_policy = steady_state(m_policy)
    vars = Dict{String, Vector{Float64}}(
        "Y" => [eq_base.Y, eq_policy.Y],
        "r" => [eq_base.r, eq_policy.r],
        "C" => [eq_base.C, eq_policy.C],
        "I" => [eq_base.I, eq_policy.I],
    )
    meta = Dict{String, Any}(
        "scenario_names" => collect(scenario_names),
        "parameters_base" => parameters(m_base),
        "parameters_policy" => parameters(m_policy),
    )
    SimulationResult("IS-LM Model", "policy_comparison", vars, meta)
end
