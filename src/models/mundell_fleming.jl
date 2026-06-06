"""
    MundellFlemingModel <: AbstractMacroModel

Mundell-Flemingモデル。小国・完全資本移動・変動為替相場制を前提とする開放経済静学モデル。

IS-LMを開放経済へ拡張し、UIP条件（r = r*）のもとで財市場・貨幣市場・外国為替市場の
同時均衡を扱う。

## IS-LM継承パラメータ

### 消費関数
- `c0` : 自律消費 (c0 > 0)
- `c1` : 限界消費性向 MPC (0 < c1 < 1)

### 投資関数
- `I0` : 自律投資 (I0 > 0)
- `b`  : 投資の利子率感応度 (b > 0)

### 財政・外生変数
- `G`  : 政府支出 (G ≥ 0)
- `T`  : 定額税 (T ≥ 0)

### 貨幣市場
- `l1` : 貨幣需要の所得感応度 (l1 > 0)
- `l2` : 貨幣需要の利子率感応度 (l2 > 0)
- `M`  : 名目マネーサプライ (M > 0)
- `P`  : 物価水準（短期固定, P > 0）

## 開放経済追加パラメータ
- `r_star` : 世界利子率（小国仮定で外生, r_star > 0）
- `nx0`    : 自律的純輸出（切片）
- `nx1`    : 純輸出の為替感応度（nx1 > 0: 自国通貨安→NX改善）

## モデル方程式

```
IS:  Y = C(Y-T) + I(r) + G + NX(e)
LM:  M/P = l1*Y - l2*r
UIP: r = r*

C(Y-T) = c0 + c1*(Y-T)
I(r)   = I0 - b*r
NX(e)  = nx0 + nx1*e   （e: 高いほど自国通貨安）
```

## 均衡解

UIP条件 r = r* のもとで LM 方程式から Y が決まり、国民所得恒等式から NX・e が決まる。

```
r  = r*
Y  = (M/P + l2*r*) / l1
C  = c0 + c1*(Y - T)
I  = I0 - b*r*
NX = Y - C - I - G
e  = (NX - nx0) / nx1
```

## Mundell-Fleming定理（変動相場制・完全資本移動）

- **財政政策は無効**: G↑ → e が増価（自国通貨高）し NX が減少、Y は変化しない
- **金融政策は有効**: M↑ → Y 増加、e が減価（自国通貨安）し NX が改善
"""
struct MundellFlemingModel <: AbstractMacroModel
    # IS-LM パラメータ
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
    # 開放経済追加パラメータ
    r_star::Float64
    nx0::Float64
    nx1::Float64
end

model_name(::MundellFlemingModel) = "Mundell-Fleming Model"
state_variables(::MundellFlemingModel) = Symbol[]
control_variables(::MundellFlemingModel) = [:Y, :r, :e, :NX]
parameters(m::MundellFlemingModel) = (
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
    r_star = m.r_star,
    nx0 = m.nx0,
    nx1 = m.nx1,
)

"""
    mf_equilibrium(m::MundellFlemingModel) -> (Y, r, e, NX, C, I)

Mundell-Fleming均衡を解析的に計算する。

UIP条件 r = r* のもとで LM 方程式から Y、国民所得恒等式から NX、NX関数から e を導出する。
"""
function mf_equilibrium(m::MundellFlemingModel)
    r = m.r_star
    MP = m.M / m.P
    Y = (MP + m.l2 * r) / m.l1
    C = m.c0 + m.c1 * (Y - m.T)
    I_inv = m.I0 - m.b * r
    NX = Y - C - I_inv - m.G
    e = (NX - m.nx0) / m.nx1
    return Y, r, e, NX, C, I_inv
end

"""
    steady_state(m::MundellFlemingModel) -> NamedTuple

Mundell-Fleming均衡（Y*, r*, e*, NX*, C*, I*）を NamedTuple で返す。
"""
function steady_state(m::MundellFlemingModel)
    Y, r, e, NX, C, I = mf_equilibrium(m)
    (Y = Y, r = r, e = e, NX = NX, C = C, I = I)
end

"""
    simulate(m::MundellFlemingModel) -> NamedTuple

均衡値を長さ1のベクトルとして返す。`to_simulation_result` との互換性のために提供する。
"""
function simulate(m::MundellFlemingModel)
    eq = steady_state(m)
    (Y = [eq.Y], r = [eq.r], e = [eq.e], NX = [eq.NX], C = [eq.C], I = [eq.I])
end

"""
    mf_policy_shock(m_base, m_policy; scenario_names) -> SimulationResult

ベースラインと政策ショック後の均衡を比較する。

返り値の SimulationResult は変数ごとに長さ2のベクトルを持つ。
インデックス1がベースライン、インデックス2が政策後の値。

対応するシナリオ:
- 財政政策ショック: `G` の変化
- 金融政策ショック: `M` の変化
- 海外金利ショック: `r_star` の変化
- 外需ショック: `nx0` の変化

## 例

```julia
# 金融緩和（マネーサプライ増加）の効果
m_base     = MundellFlemingModel(100.0, 0.8, 200.0, 50.0, 100.0, 100.0,
                                  0.2, 100.0, 1000.0, 1.0, 0.02, 50.0, 10.0)
m_monetary = MundellFlemingModel(100.0, 0.8, 200.0, 50.0, 100.0, 100.0,
                                  0.2, 100.0, 1200.0, 1.0, 0.02, 50.0, 10.0)
result = DME.mf_policy_shock(m_base, m_monetary; scenario_names=("baseline", "monetary_easing"))
```
"""
function mf_policy_shock(
    m_base::MundellFlemingModel,
    m_policy::MundellFlemingModel;
    scenario_names::Tuple{String, String} = ("baseline", "policy"),
)
    eq_base = steady_state(m_base)
    eq_policy = steady_state(m_policy)
    vars = Dict{String, Vector{Float64}}(
        "Y" => [eq_base.Y, eq_policy.Y],
        "r" => [eq_base.r, eq_policy.r],
        "e" => [eq_base.e, eq_policy.e],
        "NX" => [eq_base.NX, eq_policy.NX],
        "C" => [eq_base.C, eq_policy.C],
        "I" => [eq_base.I, eq_policy.I],
    )
    meta = Dict{String, Any}(
        "scenario_names" => collect(scenario_names),
        "parameters_base" => parameters(m_base),
        "parameters_policy" => parameters(m_policy),
    )
    SimulationResult("Mundell-Fleming Model", "policy_comparison", vars, meta)
end
