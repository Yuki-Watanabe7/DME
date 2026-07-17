# minsky_regimes.jl: Keen モデル出力から Minsky 資金調達区分（Hedge/Speculative/Ponzi）を
# 診断する読み取り専用の後処理層。
#
# 操作的定義・仮定・契約は docs/models/minsky_regime_diagnostics.md、
# 責務境界（KeenModel 本体から分離する理由）は docs/adr/0003-minsky-financing-regime-diagnostics.md
# を参照。KeenModel の struct・parameters・ODE 動学（keen_rhs 等）はこのファイルの追加によって
# 一切変更されない。

"""
    FinancingRegime

Minsky 資金調達区分。

- `unlevered`   : 正の債務負担が実質的にない（`d ≤ debt_tolerance`）
- `hedge`       : 営業余剰が利払いと元本返済代理の双方を賄う
- `speculative` : 営業余剰が利払いは賄うが、元本返済代理までは賄わない
- `ponzi`       : 営業余剰が利払いを賄わない
- `invalid`     : 非有限値（発散後の `NaN` 埋め区間等）で判定不能

詳細な操作的定義は `docs/models/minsky_regime_diagnostics.md` を参照。
"""
@enum FinancingRegime unlevered hedge speculative ponzi invalid

"""
    FinancingRegimeConfig

Minsky 資金調達区分診断の設定。**診断層専用の仮定**であり、`KeenModel` の
`struct`・`parameters`・ODE 動学には一切影響しない
（`docs/adr/0003-minsky-financing-regime-diagnostics.md`）。

## フィールド
- `amortization_rate::Float64` : 元本返済代理率（単位: 1/年）。既定 `0.05`（平均満期20年相当）
- `debt_tolerance::Float64` : `unlevered` 判定閾値。`d ≤ debt_tolerance` で `unlevered`
- `classification_tolerance::Float64` : 区分境界の数値許容差 `τ`。境界比較を `≥ -τ` で行い、
  浮動小数点ジッタによる境界付近の反転を抑える（hysteresis は不採用、ADR 0003 参照）
- `methodology_version::String` : 診断ロジックのバージョン識別子（provenance 追跡用）

## デフォルト値の根拠
`amortization_rate` の既定値 `0.05` は企業債務の平均満期を保守的に長め（20年）に取る
作業仮定であり、理論的アンカーではない。実データによる校正は Phase 3 の対象
（`docs/models/minsky_regime_diagnostics.md` §3・§7）。
"""
struct FinancingRegimeConfig
    amortization_rate::Float64
    debt_tolerance::Float64
    classification_tolerance::Float64
    methodology_version::String

    function FinancingRegimeConfig(
        amortization_rate::Float64,
        debt_tolerance::Float64,
        classification_tolerance::Float64,
        methodology_version::String,
    )
        if !isfinite(amortization_rate) || amortization_rate < 0
            throw(
                ArgumentError(
                    "amortization_rate は 0 以上の有限値でなければなりません（指定: $(amortization_rate)）",
                ),
            )
        end
        if !isfinite(debt_tolerance)
            throw(
                ArgumentError(
                    "debt_tolerance は有限値でなければなりません（指定: $(debt_tolerance)）",
                ),
            )
        end
        if !isfinite(classification_tolerance) || classification_tolerance < 0
            throw(
                ArgumentError(
                    "classification_tolerance は 0 以上の有限値でなければなりません（指定: $(classification_tolerance)）",
                ),
            )
        end
        new(
            amortization_rate,
            debt_tolerance,
            classification_tolerance,
            methodology_version,
        )
    end
end

"""
    FinancingRegimeConfig(; amortization_rate=0.05, debt_tolerance=1e-8,
                           classification_tolerance=1e-9,
                           methodology_version="minsky-regime/1.0.0")

既定値付きのキーワードコンストラクタ。
"""
FinancingRegimeConfig(;
    amortization_rate::Float64 = 0.05,
    debt_tolerance::Float64 = 1e-8,
    classification_tolerance::Float64 = 1e-9,
    methodology_version::String = "minsky-regime/1.0.0",
) = FinancingRegimeConfig(
    amortization_rate,
    debt_tolerance,
    classification_tolerance,
    methodology_version,
)

"""
    FinancingRegimeObservation

単一時点の資金調達区分診断結果。判定根拠（各キャッシュフロー代理値・境界マージン）を
後から再計算せず追跡できるよう、入力値・中間量・判定結果をすべて保持する。

## フィールド
- `time::Int` : 時点（元の時系列のインデックス、1始まり）
- `regime::FinancingRegime` : 判定された区分
- `ω::Float64` : 賃金シェア（入力値）
- `d::Float64` : 民間債務比率（入力値）
- `r::Float64` : 貸出金利（`KeenModel` パラメータ、入力値）
- `operating_surplus::Float64` : 営業余剰の代理 `1 - ω`
- `interest_commitment::Float64` : 利払い負担 `r * max(d, 0)`
- `principal_commitment::Float64` : 元本返済負担の代理 `amortization_rate * max(d, 0)`
- `debt_service::Float64` : 総デットサービス `interest_commitment + principal_commitment`
- `ponzi_margin::Float64` : Ponzi境界からの距離 `operating_surplus - interest_commitment`
  （`d > 0` では利払い後利潤シェア `π` に一致）。正なら利払いを賄える側
- `hedge_margin::Float64` : Hedge境界からの距離 `operating_surplus - debt_service`。
  正なら利払い・元本返済代理の双方を賄える側
- `methodology_version::String` : 生成時の methodology version（provenance）

`ω`・`d`・`r` のいずれかが非有限のとき `regime = invalid` となり、
`operating_surplus` 以降の派生量はすべて `NaN` になる。
"""
struct FinancingRegimeObservation
    time::Int
    regime::FinancingRegime
    ω::Float64
    d::Float64
    r::Float64
    operating_surplus::Float64
    interest_commitment::Float64
    principal_commitment::Float64
    debt_service::Float64
    ponzi_margin::Float64
    hedge_margin::Float64
    methodology_version::String
end

"""
    FinancingRegimeTransition

連続する2時点間で資金調達区分が変化した記録。

## フィールド
- `time::Int` : 遷移後（`to` 側）の時点
- `from::FinancingRegime` : 遷移前の区分
- `to::FinancingRegime` : 遷移後の区分
- `ponzi_margin::Float64` : 遷移後時点の `ponzi_margin`
- `hedge_margin::Float64` : 遷移後時点の `hedge_margin`
- `from_observation::FinancingRegimeObservation` : 遷移直前の観測
- `to_observation::FinancingRegimeObservation` : 遷移直後の観測

`invalid` への遷移（`to == invalid`）は発散・欠損イベントであり、経済的な資金調達区分の
変化とは意味が異なる。呼び出し側は `to == invalid` / `from == invalid` で区別できる。

hysteresis は不採用（`docs/adr/0003-minsky-financing-regime-diagnostics.md`）のため、
瞬間的な境界交差と確定遷移の区別は行わない。連続する2時点で区分が変わればすべて記録する。
"""
struct FinancingRegimeTransition
    time::Int
    from::FinancingRegime
    to::FinancingRegime
    ponzi_margin::Float64
    hedge_margin::Float64
    from_observation::FinancingRegimeObservation
    to_observation::FinancingRegimeObservation
end

"""
    FinancingRegimeDiagnostics

時系列全体の資金調達区分診断結果。

## フィールド
- `observations::Vector{FinancingRegimeObservation}` : 各時点の診断結果。
  元の時系列と同じ長さ・順序で保持し、発散後の期間があっても切り詰めない
- `transitions::Vector{FinancingRegimeTransition}` : 区分が変化した時点の記録（`invalid` との
  遷移を含む）
- `config::FinancingRegimeConfig` : 診断に用いた設定（methodology version を含む）
- `valid_periods::Vector{Int}` : `regime != invalid` な時点のリスト（昇順）
- `invalid_periods::Vector{Int}` : `regime == invalid` な時点のリスト（昇順、発散後の
  `NaN` 埋め区間に対応）
"""
struct FinancingRegimeDiagnostics
    observations::Vector{FinancingRegimeObservation}
    transitions::Vector{FinancingRegimeTransition}
    config::FinancingRegimeConfig
    valid_periods::Vector{Int}
    invalid_periods::Vector{Int}
end

# 単一時点の区分判定（内部コア）。KeenModel を要求せず ω, d, r のみから計算することで、
# NamedTuple 経路・SimulationResult 経路の双方から同一ロジックを共有できるようにする。
function _classify_financing_regime(
    ω::Float64,
    d::Float64,
    r::Float64;
    config::FinancingRegimeConfig,
    time::Int,
)
    if !isfinite(ω) || !isfinite(d) || !isfinite(r)
        return FinancingRegimeObservation(
            time,
            invalid,
            ω,
            d,
            r,
            NaN,
            NaN,
            NaN,
            NaN,
            NaN,
            NaN,
            config.methodology_version,
        )
    end

    operating_surplus = 1.0 - ω
    interest_commitment = r * max(d, 0.0)
    principal_commitment = config.amortization_rate * max(d, 0.0)
    debt_service = interest_commitment + principal_commitment
    ponzi_margin = operating_surplus - interest_commitment
    hedge_margin = operating_surplus - debt_service

    τ = config.classification_tolerance
    regime = if d <= config.debt_tolerance
        unlevered
    elseif hedge_margin >= -τ
        hedge
    elseif ponzi_margin >= -τ
        speculative
    else
        ponzi
    end

    FinancingRegimeObservation(
        time,
        regime,
        ω,
        d,
        r,
        operating_surplus,
        interest_commitment,
        principal_commitment,
        debt_service,
        ponzi_margin,
        hedge_margin,
        config.methodology_version,
    )
end

"""
    classify_financing_regime(m::KeenModel, ω::Float64, d::Float64;
                               config::FinancingRegimeConfig = FinancingRegimeConfig(),
                               time::Int = 1) -> FinancingRegimeObservation

単一時点 `(ω, d)` の Minsky 資金調達区分を診断する。`m.r`（貸出金利）を用いて
利払い負担・元本返済負担の代理を計算する。`λ` は区分式に不要のため要求しない。

入力（`m`・`ω`・`d`）を変更しない純粋な診断処理。非有限値（`NaN`/`Inf`）を渡した場合は
例外を送出せず `regime = invalid` を返す。

## 引数
- `m` : `KeenModel`（`r` の参照のみに使用。ODE 動学・パラメータは変更しない）
- `ω`・`d` : 診断対象の状態変数（水準）
- `config` : 診断設定（省略時は既定値）
- `time` : 観測に付与する時点インデックス（省略時 `1`）

## 使用例
```julia
m = KeenModel(0.025, 0.02, 0.01, 3.0, 0.03, 0.0400641, 6.41e-5, -0.0065, exp(-5), 20.0)
ss = steady_state(m)
obs = classify_financing_regime(m, ss.ω, ss.d)
obs.regime          # :hedge 等（FinancingRegime）
obs.ponzi_margin    # Ponzi境界からの距離
```

## 境界条件・数値許容差
判定は次の優先順位で行う（`docs/models/minsky_regime_diagnostics.md` §4.3）。

1. `ω`・`d`・`r` のいずれかが非有限 → `invalid`
2. `d ≤ config.debt_tolerance` → `unlevered`（負の `d` を含む）
3. `hedge_margin ≥ -τ` → `hedge`
4. `ponzi_margin ≥ -τ` → `speculative`
5. それ以外 → `ponzi`

`τ = config.classification_tolerance`。境界ちょうど（マージン `= 0`）は許容差の分だけ
「賄える側」に確定し、浮動小数点ジッタで反転しない。
"""
function classify_financing_regime(
    m::KeenModel,
    ω::Float64,
    d::Float64;
    config::FinancingRegimeConfig = FinancingRegimeConfig(),
    time::Int = 1,
)
    _classify_financing_regime(ω, d, m.r; config = config, time = time)
end

# 観測列から transitions・valid/invalid periods を組み立てる内部ヘルパー。
# NamedTuple 経路・SimulationResult 経路の双方から共有する。
function _diagnose_from_series(
    ω::Vector{Float64},
    d::Vector{Float64},
    r::Float64;
    config::FinancingRegimeConfig,
)
    if length(ω) != length(d)
        throw(
            ArgumentError(
                "ω と d の長さが一致しません（ω: $(length(ω))、d: $(length(d))）",
            ),
        )
    end

    n = length(ω)
    observations = Vector{FinancingRegimeObservation}(undef, n)
    for i in 1:n
        observations[i] =
            _classify_financing_regime(ω[i], d[i], r; config = config, time = i)
    end

    transitions = FinancingRegimeTransition[]
    for i in 1:(n - 1)
        from_obs = observations[i]
        to_obs = observations[i + 1]
        if from_obs.regime != to_obs.regime
            push!(
                transitions,
                FinancingRegimeTransition(
                    to_obs.time,
                    from_obs.regime,
                    to_obs.regime,
                    to_obs.ponzi_margin,
                    to_obs.hedge_margin,
                    from_obs,
                    to_obs,
                ),
            )
        end
    end

    valid_periods = [obs.time for obs in observations if obs.regime != invalid]
    invalid_periods = [obs.time for obs in observations if obs.regime == invalid]

    FinancingRegimeDiagnostics(
        observations,
        transitions,
        config,
        valid_periods,
        invalid_periods,
    )
end

"""
    diagnose_financing_regime(m::KeenModel, result::NamedTuple;
                               config::FinancingRegimeConfig = FinancingRegimeConfig()) -> FinancingRegimeDiagnostics

`simulate(m, ...)` / `impulse_response(m, ...)` が返す `NamedTuple`（`:ω`・`:d` を含む）から
時系列全体の資金調達区分を診断する。`m.r` を用いる。

発散ガード作動後の `NaN` 埋め区間は `regime = invalid` として扱われ、`ponzi` へ誤分類されない。
元系列を切り詰めず、`result.ω`（または `result.d`）と同じ長さの `observations` を返す。
入力 `result` は変更しない。

## 使用例
```julia
m = KeenModel(0.025, 0.02, 0.01, 3.0, 0.03, 0.0400641, 6.41e-5, -0.0065, exp(-5), 20.0)
ss = steady_state(m)
result = simulate(m, ss.ω, ss.λ, 5.0; T = 300)  # 高債務初期値 → 崩壊経路
diag = diagnose_financing_regime(m, result)

diag.observations[end].regime   # invalid（発散後）
diag.invalid_periods            # 発散後の時点インデックス
diag.transitions                # 区分が変化した時点の一覧
```
"""
function diagnose_financing_regime(
    m::KeenModel,
    result::NamedTuple;
    config::FinancingRegimeConfig = FinancingRegimeConfig(),
)
    if !haskey(result, :ω) || !haskey(result, :d)
        throw(
            ArgumentError(
                "result は :ω, :d フィールドを持つ NamedTuple でなければなりません",
            ),
        )
    end
    _diagnose_from_series(result.ω, result.d, m.r; config = config)
end

"""
    diagnose_financing_regime(sr::SimulationResult;
                               config::FinancingRegimeConfig = FinancingRegimeConfig()) -> FinancingRegimeDiagnostics

`to_simulation_result` 済みの `SimulationResult`（`"ω"`・`"d"` 変数と
`metadata["parameters"].r` を含む）から時系列全体の資金調達区分を診断する。

`NamedTuple` 経路（`diagnose_financing_regime(m, result)`）と同一の内部ロジックを共有するため、
同じシミュレーション結果に対しては両経路で同一の診断結果を返す。入力 `sr` は変更しない。

## エラー
- `"ω"` または `"d"` が `sr` に存在しない場合は `ArgumentError`
- `sr.metadata["parameters"]` が存在しない、または `r` フィールドを持たない場合は `ArgumentError`
  （区分を推測せず明示的に失敗する）

## 使用例
```julia
sr = to_simulation_result(m, result, "simulate")
diag = diagnose_financing_regime(sr)
```
"""
function diagnose_financing_regime(
    sr::SimulationResult;
    config::FinancingRegimeConfig = FinancingRegimeConfig(),
)
    if !haskey(sr, "ω") || !haskey(sr, "d")
        throw(
            ArgumentError(
                "SimulationResult は \"ω\", \"d\" 変数を持たなければなりません。" *
                "利用可能な変数: $(sort(variable_names(sr)))",
            ),
        )
    end
    if !haskey(sr.metadata, "parameters") || !hasproperty(sr.metadata["parameters"], :r)
        throw(
            ArgumentError(
                "SimulationResult の metadata[\"parameters\"] に r（貸出金利）が必要です",
            ),
        )
    end
    _diagnose_from_series(sr["ω"], sr["d"], sr.metadata["parameters"].r; config = config)
end
