"""
    SolverOptions

`find_path` / `shock` / `simulate_by_nlvar` の実行設定。

## フィールド
- `horizon::Int`       : シミュレーション期間（maxT に対応、デフォルト: 30）
- `max_iter::Int`      : 最大反復回数（デフォルト: 1000）
- `tolerance::Float64` : 収束判定閾値（デフォルト: 1e-8）
"""
Base.@kwdef struct SolverOptions
    horizon::Int = 30
    max_iter::Int = 1000
    tolerance::Float64 = 1e-8
end

"""
    ValueIterationOptions

Ramsey モデルの `solve_by_nlvar` に渡す価値反復法の設定。

## フィールド
- `n::Int`             : グリッドサイズ（デフォルト: 20）
- `a::Float64`         : グリッド下限（デフォルト: 0.5）
- `b::Float64`         : グリッド上限（デフォルト: 3.0）
- `max_iter::Int`      : 最大反復回数（デフォルト: 100）
- `tolerance::Float64` : 収束判定閾値（デフォルト: 0.0001）
- `itp_type::Interpo_Type` : 補間方式（デフォルト: ITPCubic）
"""
Base.@kwdef struct ValueIterationOptions
    n::Int = 20
    a::Float64 = 0.5
    b::Float64 = 3.0
    max_iter::Int = 100
    tolerance::Float64 = 0.0001
    itp_type::Interpo_Type = ITPCubic
end

"""
    ODESolverOptions

連続時間 ODE モデル（`KeenModel` 等）の `simulate` / `impulse_response` に渡す
固定刻み RK4 ソルバーの設定。

## フィールド
- `substeps::Int`      : 1期（1年）あたりの RK4 サブステップ数（デフォルト: 20、dt = 1/substeps）
- `guard_max::Float64` : 発散判定の閾値。状態変数の絶対値がこれを超えると打ち切る（デフォルト: 1e6）
"""
Base.@kwdef struct ODESolverOptions
    substeps::Int = 20
    guard_max::Float64 = 1e6
end
