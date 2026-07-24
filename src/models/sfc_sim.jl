"""
    SIMModel <: AbstractMacroModel

最小 SIM 型 SFC（Stock-Flow Consistent）モデル。
Godley & Lavoie (2007) 『Monetary Economics』第3章 "The Simplest Model" に基づく、
家計・生産・政府からなる閉鎖経済。金融資産は政府貨幣 `H`（high-powered money）のみ。

離散時間（期）で毎期この順に再帰的に解ける:

```
Y   = C + G                       … 産出＝需要
T   = θ · Y                       … 比例税
YD  = Y − T                       … 可処分所得
C   = α1 · YD + α2 · H_{t-1}      … 消費関数（所得＋前期富）
H   = H_{t-1} + (YD − C)          … 家計貨幣蓄積＝貯蓄
N   = Y / W                       … 雇用
```

`Y` と `C` は同時決定で閉形式に解ける:

```
Y = (G + α2 · H_{t-1}) / (1 − α1 · (1 − θ))
```

## 状態変数・操作変数
- 状態変数: `H`（政府貨幣ストック＝家計資産＝政府負債）
- 操作（内生フロー）変数: `Y`, `C`, `YD`, `T`, `N`

## パラメータ
- `α1` : 所得からの消費性向 `0 < α1 < 1`
- `α2` : 富（貨幣ストック）からの消費性向 `0 < α2 < α1`
- `θ`  : 税率 `0 < θ < 1`
- `G`  : 政府支出（政策変数・外生一定、`G ≥ 0`）
- `W`  : 名目賃金率（数値基準・`W > 0`、既定 `1.0`）

## 定常状態

貯蓄がゼロ（`ΔH = 0`、政府予算均衡 `T = G`）になる状態:

```
Y*  = G / θ
YD* = (1 − θ) · G / θ
H*  = (1 − α1) / α2 · YD*
```

`0 < α1 < 1` で大域安定であり、危機 regime を持たない（限界は
[SFC 統合設計](../../docs/models/sim_sfc.md) §限界を参照）。

## 会計との接続

`simulate` / `impulse_response` は水準系列 NamedTuple `(Y, C, YD, T, G, H, N)` を返す。
[`sfc_result`](@ref) で部門別貸借対照表・取引フロー行列を持つ `SFCResult` へ変換し、
[`validate_sfc_accounting`](@ref) で全期の会計恒等式を検証できる。

## 出典
Godley, W. & Lavoie, M. (2007). *Monetary Economics: An Integrated Approach to
Credit, Money, Income, Production and Wealth*, 第3章.
"""
struct SIMModel <: AbstractMacroModel
    α1::Float64
    α2::Float64
    θ::Float64
    G::Float64
    W::Float64

    function SIMModel(α1, α2, θ, G, W)
        (0 < α1 < 1) ||
            throw(ArgumentError("α1 は 0 < α1 < 1 でなければなりません（指定: $α1）"))
        (0 < α2 < α1) || throw(
            ArgumentError("α2 は 0 < α2 < α1 でなければなりません（指定: α2=$α2, α1=$α1）"),
        )
        (0 < θ < 1) ||
            throw(ArgumentError("θ は 0 < θ < 1 でなければなりません（指定: $θ）"))
        (G >= 0) || throw(ArgumentError("G は非負でなければなりません（指定: $G）"))
        (W > 0) || throw(ArgumentError("W は正でなければなりません（指定: $W）"))
        return new(Float64(α1), Float64(α2), Float64(θ), Float64(G), Float64(W))
    end
end

"""
    SIMModel(; α1, α2, θ, G, W=1.0)

キーワード引数版のコンストラクタ。`W` は既定で数値基準 `1.0`。
"""
SIMModel(; α1, α2, θ, G, W = 1.0) = SIMModel(α1, α2, θ, G, W)

model_name(::SIMModel) = "SIM Model"
state_variables(::SIMModel) = [:H]
control_variables(::SIMModel) = [:Y, :C, :YD, :T, :N]
parameters(m::SIMModel) = (α1 = m.α1, α2 = m.α2, θ = m.θ, G = m.G, W = m.W)

"""
    steady_state(m::SIMModel) -> NamedTuple

貯蓄ゼロ（`ΔH = 0`・政府予算均衡 `T = G`）の定常状態を閉形式で返す。

```
Y*  = G / θ,  YD* = (1 − θ)·G / θ,  H* = (1 − α1)/α2 · YD*
```

定常状態では `C* = YD*`（貯蓄ゼロ）・`T* = G`（予算均衡）。
返り値は水準系列 `simulate` と同じキー `(Y, C, YD, T, G, H, N)`。
"""
function steady_state(m::SIMModel)
    Y = m.G / m.θ
    taxes = m.θ * Y            # = G（予算均衡）
    YD = Y - taxes
    C = YD                     # ΔH = 0
    H = (1 - m.α1) / m.α2 * YD
    N = Y / m.W
    return (Y = Y, C = C, YD = YD, T = taxes, G = m.G, H = H, N = N)
end

"""
    _sim_run(m::SIMModel, H0, Gseq, θseq) -> NamedTuple

期別の政府支出 `Gseq` と税率 `θseq`（いずれも長さ `T`）を外生に与え、初期ストック
`H0`（期首 `H_0`）から SIM の再帰構造を前向きに解く内部ワークホース。

各期 `Y = (G + α2·H_{t-1}) / (1 − α1·(1 − θ))` を閉形式で解き、税・可処分所得・消費・
貨幣蓄積・雇用を更新する。非有限な `H0`（`NaN`/`Inf`）はそのまま伝播させる（会計検証層が
invalid 期として扱う）。返り値は水準系列 `(Y, C, YD, T, G, H, N)`。
"""
function _sim_run(m::SIMModel, H0::Real, Gseq::AbstractVector, θseq::AbstractVector)
    T = length(Gseq)
    length(θseq) == T || throw(
        ArgumentError(
            "Gseq（長さ $(length(Gseq))）と θseq（長さ $(length(θseq))）の長さが一致しません",
        ),
    )
    Y = Vector{Float64}(undef, T)
    C = Vector{Float64}(undef, T)
    YD = Vector{Float64}(undef, T)
    taxes = Vector{Float64}(undef, T)
    Gout = Vector{Float64}(undef, T)
    H = Vector{Float64}(undef, T)
    N = Vector{Float64}(undef, T)

    α1, α2, W = m.α1, m.α2, m.W
    Hprev = Float64(H0)
    for t in 1:T
        θt = Float64(θseq[t])
        Gt = Float64(Gseq[t])
        Yt = (Gt + α2 * Hprev) / (1 - α1 * (1 - θt))
        Tt = θt * Yt
        YDt = Yt - Tt
        Ct = α1 * YDt + α2 * Hprev
        Ht = Hprev + (YDt - Ct)
        Y[t] = Yt
        taxes[t] = Tt
        YD[t] = YDt
        C[t] = Ct
        H[t] = Ht
        N[t] = Yt / W
        Gout[t] = Gt
        Hprev = Ht
    end
    return (Y = Y, C = C, YD = YD, T = taxes, G = Gout, H = H, N = N)
end

"""
    simulate(m::SIMModel, H0=0.0; T=100) -> NamedTuple

初期ストック `H0`（既定 `0.0`）から `T` 期を前向き反復する baseline シミュレーション。
政府支出 `G`・税率 `θ` は全期一定。返り値は水準系列 `(Y, C, YD, T, G, H, N)`。

`T < 1` は `ArgumentError`。
"""
function simulate(m::SIMModel, H0::Real = 0.0; T::Int = 100)
    T >= 1 || throw(ArgumentError("期間数 T は 1 以上でなければなりません（指定: $T）"))
    return _sim_run(m, H0, fill(m.G, T), fill(m.θ, T))
end

"""
    impulse_response(m::SIMModel, shock_size; shock=:G, T=50, permanent=true,
                     shock_start=1, H0=nothing) -> NamedTuple

定常状態から出発し、政府支出（`shock=:G`）または税率（`shock=:θ`）にショックを与えた
移行経路を水準系列で返す。

- `shock_size` : 加算ショック幅（`:G` なら `G + shock_size`、`:θ` なら `θ + shock_size`）。
- `permanent`  : `true` で `shock_start` 以降ずっと、`false` で `shock_start` の 1 期のみショック。
- `H0`         : 開始ストック（既定 `nothing` = 定常状態 `H*`）。

ショック後に `G < 0` または `θ ∉ (0, 1)` となる場合は `ArgumentError`。
`shock` は `:G` / `:θ` のいずれか。ショック定義は [`sfc_result`](@ref) の `shock` 引数で
`SFCResult` の metadata に保存できる。
"""
function impulse_response(
    m::SIMModel,
    shock_size::Real;
    shock::Symbol = :G,
    T::Int = 50,
    permanent::Bool = true,
    shock_start::Int = 1,
    H0::Union{Nothing, Real} = nothing,
)
    T >= 1 || throw(ArgumentError("期間数 T は 1 以上でなければなりません（指定: $T）"))
    (1 <= shock_start <= T) || throw(
        ArgumentError(
            "shock_start は 1..$T の範囲でなければなりません（指定: $shock_start）",
        ),
    )
    shock in (:G, :θ) || throw(
        ArgumentError(
            "不明なショック種別: $(repr(shock))。:G または :θ を指定してください。",
        ),
    )

    base_H0 = H0 === nothing ? steady_state(m).H : Float64(H0)
    Gseq = fill(m.G, T)
    θseq = fill(m.θ, T)
    shock_periods = permanent ? (shock_start:T) : (shock_start:shock_start)
    for t in shock_periods
        if shock === :G
            Gseq[t] = m.G + shock_size
        else
            θseq[t] = m.θ + shock_size
        end
    end

    if shock === :G
        all(g -> g >= 0, Gseq) || throw(
            ArgumentError("ショック後の G が負になります（G=$(m.G), shock=$shock_size）"),
        )
    else
        all(θ -> 0 < θ < 1, θseq) || throw(
            ArgumentError(
                "ショック後の θ が (0, 1) の外です（θ=$(m.θ), shock=$shock_size）",
            ),
        )
    end

    return _sim_run(m, base_H0, Gseq, θseq)
end
