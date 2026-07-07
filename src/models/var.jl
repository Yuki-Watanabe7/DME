"""
    VARModel <: AbstractMacroModel

係数行列を手入力する簡易 VAR(1) モデル。

## 方程式

```
y_t = c + A * y_{t-1}
```

- `y_t` : n 変数ベクトル（t 期の内生変数）
- `c`   : n 次元定数項ベクトル
- `A`   : n×n 係数行列（各変数のラグ係数）

VAR が定常（spectral radius of A < 1）のとき一意の定常状態が存在する。

## フィールド

- `var_names::Vector{Symbol}` : 変数名リスト（長さ n）
- `A::Matrix{Float64}`        : n×n 係数行列
- `c::Vector{Float64}`        : n 次元定数項ベクトル

## 制約

- ラグ次数は 1 期に限定。高次ラグは将来 Issue にて対応予定。
- 係数行列は手入力のみ。実データからの推定は将来対応予定。

## 使用例

```julia
# GDP (y) とインフレ率 (π) の 2 変数 VAR(1)
var_names = [:y, :π]
A = [0.8 0.1; 0.2 0.7]
c = [0.5, 0.3]
m = VARModel(var_names, A, c)

ss = steady_state(m)          # 定常状態
path = simulate(m, [1.0, 0.5]; T = 40)   # シミュレーション
irf = impulse_response(m, [1.0, 0.0]; T = 20)  # IRF
```
"""
struct VARModel <: AbstractMacroModel
    var_names::Vector{Symbol}
    A::Matrix{Float64}
    c::Vector{Float64}

    function VARModel(var_names, A, c)
        n = length(var_names)
        size(A) == (n, n) ||
            throw(ArgumentError("A は $(n)×$(n) でなければなりません（指定: $(size(A))）"))
        length(c) == n || throw(
            ArgumentError("c の長さは $(n) でなければなりません（指定: $(length(c))）"),
        )
        new(Vector{Symbol}(var_names), Matrix{Float64}(A), Vector{Float64}(c))
    end
end

model_name(::VARModel) = "VAR Model"
state_variables(m::VARModel) = copy(m.var_names)
control_variables(::VARModel) = Symbol[]
parameters(m::VARModel) = (A = m.A, c = m.c)

"""
    steady_state(m::VARModel) -> NamedTuple

VAR(1) の定常状態を計算する。

定常状態 y* は固定点方程式の解:
```
y* = c + A * y*
(I - A) * y* = c
```

(I - A) が正則（すべての固有値が 1 でない）ことが必要。
VAR が定常（spectral radius of A < 1）の場合に一意解が存在する。
"""
function steady_state(m::VARModel)
    n = length(m.var_names)
    I_n = Matrix{Float64}(I, n, n)
    y_ss = (I_n - m.A) \ m.c
    NamedTuple{Tuple(m.var_names)}(Tuple([y_ss[i] for i in 1:n]))
end

"""
    simulate(m::VARModel, y0::Vector{Float64}; T::Int = 40) -> NamedTuple

VAR(1) を初期値 y0 からシミュレートする。

t=0（y0）から t=T まで T+1 期間の経路を返す。
返り値は変数名をキーとする NamedTuple（各値は長さ T+1 の Vector{Float64}）。

## 引数

- `y0` : 初期値ベクトル（長さ n）
- `T`  : シミュレーション期間数（デフォルト: 40）
"""
function simulate(m::VARModel, y0::Vector{Float64}; T::Int = 40)
    n = length(m.var_names)
    length(y0) == n ||
        throw(ArgumentError("y0 の長さは $(n) でなければなりません（指定: $(length(y0))）"))
    y = Matrix{Float64}(undef, n, T + 1)
    y[:, 1] = y0
    for t in 1:T
        y[:, t + 1] = m.c + m.A * y[:, t]
    end
    NamedTuple{Tuple(m.var_names)}(Tuple([y[i, :] for i in 1:n]))
end

"""
    impulse_response(m::VARModel, shock::Vector{Float64}; T::Int = 20) -> NamedTuple

VAR(1) に対するインパルス応答関数 (IRF) を計算する。

`shock` は t=1 での一時的なショックベクトル（定常状態からの初期乖離）。
返り値は t=1,...,T の各期における定常状態からの乖離（水準偏差）。

IRF の計算:
```
irf[1] = shock
irf[t] = A^(t-1) * shock
```

返り値は変数名をキーとする NamedTuple（各値は長さ T の Vector{Float64}）。

## 引数

- `shock` : ショックベクトル（長さ n、定常状態からの初期乖離）
- `T`     : IRF 期間数（デフォルト: 20）
"""
function impulse_response(m::VARModel, shock::Vector{Float64}; T::Int = 20)
    n = length(m.var_names)
    length(shock) == n || throw(
        ArgumentError("shock の長さは $(n) でなければなりません（指定: $(length(shock))）"),
    )
    irf = Matrix{Float64}(undef, n, T)
    v = copy(shock)
    for t in 1:T
        irf[:, t] = v
        v = m.A * v
    end
    NamedTuple{Tuple(m.var_names)}(Tuple([irf[i, :] for i in 1:n]))
end
