"""
    ADASModel <: AbstractMacroModel

AD-ASモデル。総需要（AD）曲線と短期総供給（SRAS）曲線の交点として短期均衡を計算する静学モデル。

## 総需要側パラメータ（IS-LMから導出）

### 消費関数
- `c0` : 自律消費 (c0 > 0)
- `c1` : 限界消費性向 MPC (0 < c1 < 1)

### 投資関数
- `I0` : 自律投資 (I0 > 0)
- `b`  : 投資の利子率感応度 (b > 0)

### 財政・外生変数
- `G`  : 政府支出 (G ≥ 0)
- `T`  : 税（定額税, T ≥ 0）

### 貨幣市場
- `l1` : 貨幣需要の所得感応度 (l1 > 0)
- `l2` : 貨幣需要の利子率感応度 (l2 > 0)
- `M`  : 名目マネーサプライ (M > 0)

## 総供給側パラメータ

- `Y_n` : 潜在産出（自然産出水準, Y_n > 0）
- `v`   : SRAS曲線の傾き（価格感応度, v > 0）
- `P_e` : 期待物価水準 (P_e > 0)
"""
struct ADASModel <: AbstractMacroModel
    c0::Float64
    c1::Float64
    I0::Float64
    b::Float64
    G::Float64
    T::Float64
    l1::Float64
    l2::Float64
    M::Float64
    Y_n::Float64
    v::Float64
    P_e::Float64
end

model_name(::ADASModel) = "AD-AS Model"
state_variables(::ADASModel) = Symbol[]
control_variables(::ADASModel) = [:Y, :P]
parameters(m::ADASModel) = (
    c0  = m.c0,
    c1  = m.c1,
    I0  = m.I0,
    b   = m.b,
    G   = m.G,
    T   = m.T,
    l1  = m.l1,
    l2  = m.l2,
    M   = m.M,
    Y_n = m.Y_n,
    v   = m.v,
    P_e = m.P_e,
)

"""
    adas_equilibrium(m::ADASModel) -> (Y, P, r, C, I)

AD-AS短期均衡を解析的に計算する。

AD曲線（IS-LMから導出）:
  A   = c0 - c1*T + I0 + G  （自律需要の切片）
  D   = b*l1 + l2*(1-c1)    （IS-LM共通分母、D > 0）
  Y_ad(P) = (l2*A + b*M/P) / D

SRAS曲線（線形型）:
  Y_sras(P) = Y_n + v*(P - P_e)

均衡条件 Y_ad = Y_sras を整理すると P の2次方程式になる:
  D*v*P^2 + [D*(Y_n - v*P_e) - l2*A]*P - b*M = 0

判別式は常に正であり、正の根のみ経済的に意味を持つ:
  P* = (-B + sqrt(B^2 + 4*D*v*b*M)) / (2*D*v)
  Y* = Y_n + v*(P* - P_e)
  r* = (l1*Y* - M/P*) / l2
"""
function adas_equilibrium(m::ADASModel)
    A = m.c0 + m.I0 + m.G - m.c1 * m.T
    D = m.b * m.l1 + m.l2 * (1 - m.c1)
    a_coef = D * m.v
    b_coef = D * (m.Y_n - m.v * m.P_e) - m.l2 * A
    disc = b_coef^2 + 4 * a_coef * m.b * m.M
    P = (-b_coef + sqrt(disc)) / (2 * a_coef)
    Y = m.Y_n + m.v * (P - m.P_e)
    r = (m.l1 * Y - m.M / P) / m.l2
    C = m.c0 + m.c1 * (Y - m.T)
    I = m.I0 - m.b * r
    return Y, P, r, C, I
end

"""
    steady_state(m::ADASModel) -> NamedTuple

AD-AS短期均衡（Y*, P*, r*, C*, I*）を NamedTuple で返す。
"""
function steady_state(m::ADASModel)
    Y, P, r, C, I = adas_equilibrium(m)
    (Y = Y, P = P, r = r, C = C, I = I)
end

"""
    simulate(m::ADASModel) -> NamedTuple

均衡値を長さ1のベクトルとして返す。`to_simulation_result` との互換性のために提供する。
"""
function simulate(m::ADASModel)
    eq = steady_state(m)
    (Y = [eq.Y], P = [eq.P], r = [eq.r], C = [eq.C], I = [eq.I])
end

"""
    adas_shock_compare(m_base, m_shock; scenario_names) -> SimulationResult

ベースラインとショック後の均衡を比較する。

需要ショック（G・M・T の変化）と供給ショック（Y_n・P_e の変化）の両方に対応する。
返り値の SimulationResult は変数ごとに長さ2のベクトルを持つ。
インデックス1がベースライン、インデックス2がショック後の値。

## 例

```julia
# 政府支出増加（需要ショック）
m_base   = ADASModel(100.0, 0.8, 200.0, 50.0, 100.0, 100.0, 0.2, 100.0, 300.0, 1500.0, 500.0, 1.0)
m_demand = ADASModel(100.0, 0.8, 200.0, 50.0, 150.0, 100.0, 0.2, 100.0, 300.0, 1500.0, 500.0, 1.0)
result = DME.adas_shock_compare(m_base, m_demand; scenario_names=("baseline", "demand_shock"))
```
"""
function adas_shock_compare(
    m_base::ADASModel,
    m_shock::ADASModel;
    scenario_names::Tuple{String, String} = ("baseline", "shock"),
)
    eq_base  = steady_state(m_base)
    eq_shock = steady_state(m_shock)
    vars = Dict{String, Vector{Float64}}(
        "Y" => [eq_base.Y, eq_shock.Y],
        "P" => [eq_base.P, eq_shock.P],
        "r" => [eq_base.r, eq_shock.r],
        "C" => [eq_base.C, eq_shock.C],
        "I" => [eq_base.I, eq_shock.I],
    )
    meta = Dict{String, Any}(
        "scenario_names"   => collect(scenario_names),
        "parameters_base"  => parameters(m_base),
        "parameters_shock" => parameters(m_shock),
    )
    SimulationResult("AD-AS Model", "shock_comparison", vars, meta)
end
