"""
    KeenModel <: AbstractMacroModel

Keen モデル（Grasselli & Costa Lima 2012 定式化）。賃金シェア・雇用率・民間債務比率の
3変数連続時間 ODE 系による Minsky 系金融不安定性モデル。

## 状態変数（連続時間, 年率）
- `ω` : 賃金シェア `wL/Y`（想定域: `0 < ω < 1` 近傍。崩壊経路では 0 へ）
- `λ` : 雇用率 `L/N`（想定域: `0 < λ < 1`。`λ = 1` で Phillips 曲線が発散）
- `d` : 民間債務比率 `D/Y`（想定域: `d ≥ 0` 近傍。崩壊経路では発散）

## パラメータ（デフォルトは Grasselli & Costa Lima (2012) の数値例）
- `α`  : 労働生産性成長率（デフォルト 0.025）
- `β`  : 労働人口成長率（デフォルト 0.02）
- `δ`  : 資本減耗率（デフォルト 0.01）
- `ν`  : 資本産出比率（デフォルト 3.0）
- `r`  : 貸出金利（実質・一定、デフォルト 0.03）
- `φ0` : Phillips曲線の定数項（デフォルト 0.0400641、Keen 1995）
- `φ1` : Phillips曲線の感応度（デフォルト 6.41e-5）
- `κ0` : 投資関数の定数項（デフォルト -0.0065）
- `κ1` : 投資関数のスケール（デフォルト exp(-5) ≈ 0.00674）
- `κ2` : 投資関数の利潤感応度（デフォルト 20.0）

## モデル方程式

```
ω' = ω [Φ(λ) - α]
λ' = λ [κ(π)/ν - δ - α - β]
d' = κ(π) - π - d [κ(π)/ν - δ]

Φ(λ) = φ1 / (1 - λ)^2 - φ0     （Phillips 曲線）
κ(π) = κ0 + κ1 exp(κ2 π)       （投資関数）
π    = 1 - ω - r d              （利潤シェア、派生変数）
```

## 均衡

閉鎖経済・政府部門なし・物価と名目金利は固定（実質モデル）の決定論的 ODE であり、
双安定性を持つ（良い均衡と、`ω → 0, λ → 0, d → ∞` の崩壊経路である悪い均衡）。
`steady_state` は**良い均衡のみ**を閉形式で返す。悪い均衡は座標が無限遠にあるため対象外。

## 出典
Grasselli, M. R., & Costa Lima, B. (2012). An analysis of the Keen model for credit
expansion, asset price bubbles and financial fragility. Mathematics and Financial
Economics, 6(3), 191-210.
"""
struct KeenModel <: AbstractMacroModel
    α::Float64
    β::Float64
    δ::Float64
    ν::Float64
    r::Float64
    φ0::Float64
    φ1::Float64
    κ0::Float64
    κ1::Float64
    κ2::Float64
end

model_name(::KeenModel) = "Keen Model"
state_variables(::KeenModel) = [:ω, :λ, :d]
control_variables(::KeenModel) = Symbol[]
parameters(m::KeenModel) = (
    α = m.α,
    β = m.β,
    δ = m.δ,
    ν = m.ν,
    r = m.r,
    φ0 = m.φ0,
    φ1 = m.φ1,
    κ0 = m.κ0,
    κ1 = m.κ1,
    κ2 = m.κ2,
)

"""
    keen_rhs(m::KeenModel, ω::Float64, λ::Float64, d::Float64) -> (dω, dλ, dd)

Keen モデルの ODE 右辺 `(ω', λ', d')` を状態 `(ω, λ, d)` から計算する。

Phillips 曲線 `Φ(λ) = φ1 / (1 - λ)^2 - φ0` と投資関数 `κ(π) = κ0 + κ1 exp(κ2 π)` を
内部で評価する（`π = 1 - ω - r d`）。
"""
function keen_rhs(m::KeenModel, ω::Float64, λ::Float64, d::Float64)
    π = 1 - ω - m.r * d
    κ_π = m.κ0 + m.κ1 * exp(m.κ2 * π)
    Φ_λ = m.φ1 / (1 - λ)^2 - m.φ0
    g = κ_π / m.ν - m.δ

    dω = ω * (Φ_λ - m.α)
    dλ = λ * (g - m.α - m.β)
    dd = κ_π - π - d * g

    return dω, dλ, dd
end

"""
    steady_state(m::KeenModel) -> NamedTuple

Keen モデルの**良い均衡** `(ω, λ, d, π, g)` を閉形式で返す。

```
π̄ = ln((ν(α + β + δ) - κ0) / κ1) / κ2      （κ(π̄) = ν(α + β + δ) を逆算）
λ̄ = 1 - sqrt(φ1 / (α + φ0))                 （Φ(λ̄) = α を逆算）
d̄ = (κ(π̄) - π̄) / (α + β)
ω̄ = 1 - π̄ - r d̄
ḡ = α + β
```

悪い均衡（`ω → 0, λ → 0, d → ∞` の崩壊経路）は座標が無限遠にあるため対象外。
"""
function steady_state(m::KeenModel)
    α, β, δ, ν, r = m.α, m.β, m.δ, m.ν, m.r
    φ0, φ1, κ0, κ1, κ2 = m.φ0, m.φ1, m.κ0, m.κ1, m.κ2

    κ_target = ν * (α + β + δ)
    π = log((κ_target - κ0) / κ1) / κ2
    λ = 1 - sqrt(φ1 / (α + φ0))
    d = (κ_target - π) / (α + β)
    ω = 1 - π - r * d
    g = α + β

    (ω = ω, λ = λ, d = d, π = π, g = g)
end

"""
    keen_rk4_step(m::KeenModel, ω::Float64, λ::Float64, d::Float64, dt::Float64) -> (ω_next, λ_next, d_next)

古典的4次 Runge-Kutta法（固定刻み）で `keen_rhs` を `dt` だけ積分し、1ステップ先の
状態 `(ω, λ, d)` を返す。
"""
function keen_rk4_step(m::KeenModel, ω::Float64, λ::Float64, d::Float64, dt::Float64)
    k1ω, k1λ, k1d = keen_rhs(m, ω, λ, d)
    k2ω, k2λ, k2d = keen_rhs(m, ω + dt / 2 * k1ω, λ + dt / 2 * k1λ, d + dt / 2 * k1d)
    k3ω, k3λ, k3d = keen_rhs(m, ω + dt / 2 * k2ω, λ + dt / 2 * k2λ, d + dt / 2 * k2d)
    k4ω, k4λ, k4d = keen_rhs(m, ω + dt * k3ω, λ + dt * k3λ, d + dt * k3d)

    ω_next = ω + dt / 6 * (k1ω + 2k2ω + 2k3ω + k4ω)
    λ_next = λ + dt / 6 * (k1λ + 2k2λ + 2k3λ + k4λ)
    d_next = d + dt / 6 * (k1d + 2k2d + 2k3d + k4d)

    return ω_next, λ_next, d_next
end

"""
    keen_diverged(ω::Float64, λ::Float64, d::Float64, guard_max::Float64) -> Bool

発散判定: 非有限値・`abs` が `guard_max` 超過・`λ ≥ 1`（Phillips曲線の特異点）の
いずれかを満たすかを返す。
"""
function keen_diverged(ω::Float64, λ::Float64, d::Float64, guard_max::Float64)
    !isfinite(ω) ||
        !isfinite(λ) ||
        !isfinite(d) ||
        abs(ω) > guard_max ||
        abs(λ) > guard_max ||
        abs(d) > guard_max ||
        λ >= 1
end

"""
    simulate(m::KeenModel, ω0::Float64, λ0::Float64, d0::Float64;
             T::Int = 300, options::ODESolverOptions = ODESolverOptions()) -> NamedTuple

初期値 `(ω0, λ0, d0)` から固定刻み RK4 で `T` 期（年）シミュレーションする。

1期の内部刻みは `dt = 1 / options.substeps`。出力は各整数時点でサンプリングした
長さ `T` の水準系列（第1要素が初期値）。発散ガード（非有限値・`abs > guard_max`・
`λ ≥ 1`）に抵触した時点で打ち切り、残り期間は `NaN` で埋める。
"""
function simulate(
    m::KeenModel,
    ω0::Float64,
    λ0::Float64,
    d0::Float64;
    T::Int = 300,
    options::ODESolverOptions = ODESolverOptions(),
)
    dt = 1.0 / options.substeps

    ω = Vector{Float64}(undef, T)
    λ = Vector{Float64}(undef, T)
    d = Vector{Float64}(undef, T)

    ω[1] = ω0
    λ[1] = λ0
    d[1] = d0

    diverged = keen_diverged(ω0, λ0, d0, options.guard_max)

    for t in 1:(T - 1)
        if diverged
            ω[t + 1] = NaN
            λ[t + 1] = NaN
            d[t + 1] = NaN
            continue
        end

        ωc, λc, dc = ω[t], λ[t], d[t]
        for _ in 1:(options.substeps)
            ωc, λc, dc = keen_rk4_step(m, ωc, λc, dc, dt)
            if keen_diverged(ωc, λc, dc, options.guard_max)
                diverged = true
                break
            end
        end

        if diverged
            ω[t + 1] = NaN
            λ[t + 1] = NaN
            d[t + 1] = NaN
        else
            ω[t + 1] = ωc
            λ[t + 1] = λc
            d[t + 1] = dc
        end
    end

    π = Vector{Float64}(undef, T)
    g = Vector{Float64}(undef, T)
    for t in 1:T
        if isnan(ω[t]) || isnan(λ[t]) || isnan(d[t])
            π[t] = NaN
            g[t] = NaN
        else
            π_t = 1 - ω[t] - m.r * d[t]
            κ_π = m.κ0 + m.κ1 * exp(m.κ2 * π_t)
            π[t] = π_t
            g[t] = κ_π / m.ν - m.δ
        end
    end

    (ω = ω, λ = λ, d = d, π = π, g = g)
end

"""
    impulse_response(m::KeenModel, shock::Float64; T::Int = 300, variable::Symbol = :d,
                      options::ODESolverOptions = ODESolverOptions()) -> NamedTuple

均衡攪乱型のインパルス応答。良い均衡から `variable` を `shock` だけ加法的にずらした
初期値で `simulate` を実行し、水準系列 `(ω, λ, d, π, g)` を返す。

線形化した対数偏差 IRF は提供しない（双安定性というモデルの本質が失われるため）。
小さな `shock` では良い均衡へ回帰し、大きな `shock`（例: `d̄ + 1.0`）では債務崩壊経路へ
移行する、双安定性そのものを観察できる。

`variable` は `:ω`・`:λ`・`:d` のいずれか。`SimulationResult` へ変換する際の
`scenario_name` 規約は `"irf_<variable>"`（例: `"irf_d"`）とする。
"""
function impulse_response(
    m::KeenModel,
    shock::Float64;
    T::Int = 300,
    variable::Symbol = :d,
    options::ODESolverOptions = ODESolverOptions(),
)
    ss = steady_state(m)
    ω0, λ0, d0 = ss.ω, ss.λ, ss.d

    if variable == :ω
        ω0 += shock
    elseif variable == :λ
        λ0 += shock
    elseif variable == :d
        d0 += shock
    else
        throw(
            ArgumentError(
                "variable は :ω, :λ, :d のいずれかでなければなりません（指定: $(variable)）",
            ),
        )
    end

    simulate(m, ω0, λ0, d0; T = T, options = options)
end

"""
    keen_scenario_comparison(m_base::KeenModel, m_scenario::KeenModel;
                              scenario_names::Tuple{String, String} = ("baseline", "scenario")) -> SimulationResult

ベースラインとパラメータ変更後（例: 金利 `r` の引き上げ）の Keen モデルの良い均衡を比較する。

`mf_policy_shock` と同型の出力構造: 返り値の `SimulationResult` は変数ごとに長さ2の
ベクトルを持ち、インデックス1がベースライン、インデックス2がシナリオの良い均衡値。
"""
function keen_scenario_comparison(
    m_base::KeenModel,
    m_scenario::KeenModel;
    scenario_names::Tuple{String, String} = ("baseline", "scenario"),
)
    ss_base = steady_state(m_base)
    ss_scenario = steady_state(m_scenario)
    vars = Dict{String, Vector{Float64}}(
        "ω" => [ss_base.ω, ss_scenario.ω],
        "λ" => [ss_base.λ, ss_scenario.λ],
        "d" => [ss_base.d, ss_scenario.d],
        "π" => [ss_base.π, ss_scenario.π],
        "g" => [ss_base.g, ss_scenario.g],
    )
    meta = Dict{String, Any}(
        "scenario_names" => collect(scenario_names),
        "parameters_base" => parameters(m_base),
        "parameters_scenario" => parameters(m_scenario),
    )
    SimulationResult("Keen Model", "scenario_comparison", vars, meta)
end
