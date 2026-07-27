# Keen モデル（Minsky系金融不安定性モデル）— モデル解説ドキュメント

---

## メタ情報

| 項目 | 内容 |
|---|---|
| **モデル名** | Keen モデル（Goodwin-Keen モデル、Grasselli & Costa Lima (2012) 定式化） |
| **Julia 型名** | `KeenModel` |
| **カテゴリ** | 連続時間 ODE / Minsky系金融不安定性モデル |
| **求解手法** | 解析的定常状態（良い均衡の閉形式）/ 固定刻み RK4（自前実装） |
| **実装ファイル** | `src/models/keen.jl` |
| **テストファイル** | `test/test_keen.jl`（`@testset "KeenModel"` ブロック） |

---

## 1. モデルの目的

> **LLM向け要約**: Keen モデルは「利潤の改善が投資拡大と債務蓄積を通じてどのように金融的不安定性（好況の内生的崩壊）を生むか」を、賃金シェア・雇用率・民間債務比率の3変数連続時間 ODE で分析する Minsky 系モデルである。

このモデルは、外生的なショックを一切必要とせず、モデル内部の非線形性だけから好況循環と債務崩壊という双安定性が生じるメカニズムを提供する。

- **主な問い**: 好況期の信用拡大はなぜ内生的に不安定化を招くか。企業債務はどのような条件で崩壊的に発散するか
- **対象経済**: 賃金労働者・企業（借り手）・銀行（貸し手、金利 `r` は外生一定）からなる閉鎖経済
- **時間軸**: 連続時間（パラメータは年率）。実装は固定刻み RK4 で 1 年を `substeps` 個のサブステップに離散化する

---

## 2. 経済学的直観

### なぜこのモデルが重要か

Minsky の金融不安定性仮説（Financial Instability Hypothesis, FIH）「安定が不安定を生む」を最小の3変数系で定式化したモデルである。Goodwin (1967) の賃金シェア×雇用率の成長循環モデルに企業債務を導入し、好況が信用拡大→債務蓄積→崩壊リスクを内生的に生むメカニズムを表現する。RBC・New Keynesian のような外生ショック駆動モデルとの対比として、「ショックなしでも循環・崩壊が生じる」点が最大の特徴である。

### 直観的なメカニズム

- 雇用率 `λ` が高いほど（非線形 Phillips 曲線 `Φ(λ)` を通じて）賃金上昇圧力が強まり、賃金シェア `ω` が上昇する
- 利潤シェア `π` が高いほど（投資関数 `κ(π)` を通じて）投資が拡大し、雇用率 `λ` が上昇する
- 投資が内部資金（利潤 `π`）を上回る分は借入で賄われ、債務比率 `d` が上昇する
- 債務比率の上昇は利払い負担（`r d`）を通じて利潤シェア `π = 1 - ω - r d` を圧迫する
- パラメータ・初期条件によって、有限の値に収束する**良い均衡**と、`ω, λ → 0`・`d → ∞` に向かう**債務崩壊経路（悪い均衡）**のいずれかに向かう**双安定性**を持つ

---

## 3. 主要変数

### 状態変数

| 変数 | Julia シンボル | 意味 | 単位・スケール |
|---|---|---|---|
| 賃金シェア | `:ω` | 賃金総額の GDP 比 `wL/Y` | 比率（`0 < ω < 1` 近傍。崩壊経路では 0 へ） |
| 雇用率 | `:λ` | 雇用者数の労働力人口比 `L/N` | 比率（`0 < λ < 1`。`λ = 1` で Phillips 曲線が特異点） |
| 民間債務比率 | `:d` | 企業債務の GDP 比 `D/Y` | 比率（`d ≥ 0` 近傍。崩壊経路では発散） |

### 操作変数（コントロール変数）

このモデルは最適化問題を解かないため、操作変数は存在しない（`control_variables(m) == Symbol[]`）。`VARModel` と同じ扱いである。

### その他の内生変数

| 変数 | Julia シンボル | 意味 |
|---|---|---|
| 利潤シェア | `π` | 利払い後の企業利潤の GDP 比 `1 - ω - r d` |
| 実質成長率 | `g` | 資本蓄積による成長率 `κ(π)/ν - δ` |

### 外生変数・ショック

確率的な外生ショック項はない。良い均衡から状態変数（`ω`・`λ`・`d` のいずれか）を加法的にずらした初期値を出発点とする「均衡攪乱型」のインパルス応答で分析する（`impulse_response`）。

---

## 4. パラメータ

### Julia コンストラクタ

```julia
KeenModel(α, β, δ, ν, r, φ0, φ1, κ0, κ1, κ2)
```

### パラメータ一覧

| パラメータ | Julia フィールド | 意味 | 標準的な値域 | Grasselli & Costa Lima (2012) の数値例 |
|---|---|---|---|---|
| 労働生産性成長率 | `α` | 技術進歩率 | `α > 0` | 0.025 |
| 労働人口成長率 | `β` | 人口成長率 | `β > 0` | 0.02 |
| 資本減耗率 | `δ` | 資本ストックの減耗率 | `0 < δ < 1` | 0.01 |
| 資本産出比率 | `ν` | 資本ストック / 産出 | `ν > 0` | 3.0 |
| 貸出金利 | `r` | 実質・一定と仮定 | `r > 0` | 0.03 |
| Phillips曲線定数項 | `φ0` | 賃金上昇率の切片 | — | 0.0400641 |
| Phillips曲線感応度 | `φ1` | 雇用率への感応度 | `φ1 > 0` | 6.41e-5 |
| 投資関数定数項 | `κ0` | 利潤シェア 0 での投資率 | — | -0.0065 |
| 投資関数スケール | `κ1` | 投資関数のスケール | `κ1 > 0` | `exp(-5) ≈ 0.00674` |
| 投資関数感応度 | `κ2` | 利潤への感応度 | `κ2 > 0` | 20.0 |

コンストラクタでのパラメータ検証は行わない（既存モデルと同様の方針）。想定域を外れる値を与えると、`steady_state` が複素数・非有限値を返す場合がある。

### キャリブレーションの参照

Grasselli & Costa Lima (2012) の数値例をそのまま採用する。このパラメータのもとで良い均衡は
`ω̄ ≈ 0.8361, λ̄ ≈ 0.9686, d̄ ≈ 0.0702, π̄ ≈ 0.1618, ḡ = 0.045` となり、テストのアンカーとして使用する。

---

## 5. 主要方程式

### 均衡条件（体系）

最適化問題ではなく、行動方程式（非線形 Phillips 曲線・利潤感応的投資関数）から構成される微分方程式体系である。

```
π  = 1 - ω - r d                        （利払い後の利潤シェア）
ω' = ω [Φ(λ) - α]                       （実質賃金の Phillips 曲線動学）
λ' = λ [κ(π)/ν - δ - α - β]             （資本蓄積による雇用率動学）
d' = κ(π) - π - d [κ(π)/ν - δ]          （投資と内部資金の差 = 新規借入）

Φ(λ) = φ1 / (1 - λ)^2 - φ0              （非線形 Phillips 曲線）
κ(π) = κ0 + κ1 exp(κ2 π)                （利潤感応的な投資関数）
```

DME 内部では `keen_rhs(m, ω, λ, d) -> (dω, dλ, dd)` として実装されている。

---

## 6. 定常状態

### 解析的な定常状態の導出（良い均衡）

1. 資本蓄積が定常成長率 `α + β` に一致する条件 `κ(π̄) = ν(α + β + δ)` から `π̄` を逆算する
2. 雇用率が一定となる条件 `Φ(λ̄) = α` から `λ̄` を逆算する
3. 債務比率が一定となる条件から `d̄ = (κ(π̄) - π̄) / (α + β)` を求める
4. 利潤シェアの定義 `π̄ = 1 - ω̄ - r d̄` から `ω̄` を求める
5. 定常成長率は `ḡ = α + β`

**悪い均衡**（`ω, λ → 0`・`d → ∞` の債務崩壊経路）は座標が無限遠にあるため `steady_state` の対象外である。

### 定常状態の値

| 変数 | 解析式 | デフォルトパラメータでの値 |
|---|---|---|
| `π̄` | `ln((ν(α + β + δ) - κ0) / κ1) / κ2` | ≈ 0.1618 |
| `λ̄` | `1 - sqrt(φ1 / (α + φ0))` | ≈ 0.9686 |
| `d̄` | `(κ(π̄) - π̄) / (α + β)` | ≈ 0.0702 |
| `ω̄` | `1 - π̄ - r d̄` | ≈ 0.8361 |
| `ḡ` | `α + β` | = 0.045 |

### Julia での計算

```julia
using DME

m = KeenModel(0.025, 0.02, 0.01, 3.0, 0.03, 0.0400641, 6.41e-5, -0.0065, exp(-5), 20.0)
ss = steady_state(m)
# => (ω = 0.8361, λ = 0.9686, d = 0.0702, π = 0.1618, g = 0.045)
```

---

## 7. ショック・シナリオ

### サポートされているシナリオ

| シナリオ | 関数 | 説明 |
|---|---|---|
| 良い均衡 | `steady_state(m)` | 閉形式（数値求解不要） |
| 動学シミュレーション | `simulate(m, ω0, λ0, d0; T, options)` | 固定刻み RK4 による時間発展。良い均衡への収束・債務崩壊のいずれも再現できる |
| 均衡攪乱型インパルス応答 | `impulse_response(m, shock; T, variable, options)` | 良い均衡から `variable` を `shock` だけ加法的にずらした初期値からの `simulate` |
| パラメータシナリオ比較 | `DME.keen_scenario_comparison(m_base, m_scenario)` | 2つの `KeenModel` の良い均衡を比較（`mf_policy_shock` と同型） |

`transition_path` は実装しない。このモデルは前向き期待を持たないため、完全予見経路という概念が該当しない。

### 標準的なショックの種類

| ショック | 変数 | 経済学的意味 |
|---|---|---|
| 微小な債務攪乱 | `variable = :d`, `shock` 小さい（例: 0.01） | 局所安定性の確認。良い均衡へ回帰する |
| 大きな債務攪乱 | `variable = :d`, `shock` 大きい（例: 5.0） | 双安定性の確認。債務崩壊経路へ移行する |
| 金利変更シナリオ | `keen_scenario_comparison` で `r` の異なる2モデルを比較 | 貸出金利が良い均衡に与える影響を確認 |

### ショックのサイズとスケール

`shock` は加法的な水準シフト（比率のポイント差）であり、%表示ではない。例えば `variable=:d, shock=0.01` は債務比率を良い均衡から 1 ポイント（比率で 0.01）引き上げることを意味する。

### Minsky 資金調達区分（Hedge / Speculative / Ponzi）診断

`simulate`/`impulse_response` の出力（または `to_simulation_result` 後の `SimulationResult`）から、
時点ごとの資金調達区分（`hedge`/`speculative`/`ponzi`/`unlevered`/`invalid`）と区分遷移を
診断する読み取り専用の後処理層を提供する。`KeenModel` 本体の ODE 動学・パラメータには影響しない。

```julia
result = simulate(m, ss.ω, ss.λ, 5.0; T = 300)  # 高債務初期値 → 崩壊経路
diag = diagnose_financing_regime(m, result)
diag.observations[end].regime   # invalid（発散後の NaN 区間。ponzi へ誤分類されない）
diag.transitions                # 区分が変化した時点の一覧
```

判定式・仮定（`amortization_rate` 等）・型契約の詳細は
[Minsky 資金調達区分診断](minsky_regime_diagnostics.md) と [`docs/api.md`](../api.md) を参照。
集計モデル上の代理指標であり、倒産予測・危機予測ではない点に注意する（§9・§10）。

### Minsky 連続診断指標・サマリー

区分（Hedge/Speculative/Ponzi）だけでは失われる連続量（利払い・デットサービスの
カバレッジ比率、境界までのマージン、債務変化等）と、regime 滞在比率・最初の悪化時点・
peak/minimum・発散時点をまとめたサマリーを提供する。上記の区分診断と同一の判定結果を
内部で共有するため、区分と連続指標が食い違うことはない。

```julia
diag = minsky_diagnostics(m, result)              # MinskyDiagnosticsResult
diag.observations[1].interest_coverage_ratio      # 利払いカバレッジ比率
diag.divergence_time                              # 発散ガード作動時点（nothing なら未発散）

summary = minsky_diagnostics_summary(diag)         # MinskyDiagnosticsSummary
summary.first_ponzi_time                           # 最初に ponzi へ移行した時点（nothing なら未到達）
summary.peak_debt_ratio                            # 有効期間内の債務比率の最大値

# baseline / 高金利 / 高初期債務 / amortization_rate 感応度シナリオの比較入口
cmp = minsky_diagnostics_comparison(["baseline" => diag_base, "high_debt" => diag_high_debt])
```

指標定義・0除算規則・`debt_change` の算出方式・型契約の詳細は
[Minsky 連続診断指標・サマリー](minsky_diagnostics_summary.md) を参照。
重み付き単一複合スコアは提供しない（§9・§10 の限界に同じ）。

### Minsky 可視化

区分診断・連続診断指標を読み取るだけの可視化専用レイヤー（`src/analysis/minsky_visualization.jl`）。
診断値を再計算・変更せず、`Plots.jl`（`plot_result`/`plot_comparison` と同じライブラリ）で描画する。

```julia
diag_base = minsky_diagnostics(m, simulate(m, ss.ω, ss.λ, ss.d + 0.01; T = 300);
                               scenario_name = "baseline")
diag_high_debt = minsky_diagnostics(m, simulate(m, ss.ω, ss.λ, 5.0; T = 300);
                                    scenario_name = "high_debt")

plot_financing_regimes(diag_high_debt)     # 区分タイムライン（帯 + マーカー + 遷移縦線）
plot_minsky_diagnostics(diag_high_debt)    # 5パネル: debt ratio / burden / coverage / margin / profit・growth

cmp = minsky_diagnostics_comparison(["baseline" => diag_base, "high_debt" => diag_high_debt])
plot_minsky_scenario_comparison(cmp; var = :debt_ratio)
```

#### 図の読み方

- **`plot_financing_regimes`**: 横軸は時間、区分ごとの帯（色）と重ねたマーカー形状（色覚非依存の
  二重エンコーディング）で `unlevered`/`hedge`/`speculative`/`ponzi` を識別する。縦の破線は
  区分が変化した時点（`transitions`）。タイトルに「集計モデル上の代理診断であり実測の企業比率
  ではない」旨を明記する
- **`plot_minsky_diagnostics`**: `:coverage` パネルの水平点線（`= 1`）は損益分岐点、`:margin`
  パネルの水平点線（`= 0`）は Hedge/Ponzi 境界。各パネルの縦の点線は発散ガード作動時点
  （`divergence_time`）
- **`plot_minsky_scenario_comparison`**: 同一指標・同一軸でシナリオを重ね描きし、各シナリオの
  最初の Speculative 移行（破線）・最初の Ponzi 移行（一点鎖線）・発散時点（点線）を
  シナリオごとに同色の縦線で示す

#### 集計代理診断・注意事項（可視化固有）

- **`invalid` はPonziと同じ帯へ混入しない**: `invalid`（発散後の `NaN` 埋め区間・非有限入力）は
  破線境界・別配色・別ラベル（"invalid (unobservable / simulation truncated)"）で表示し、
  経済状態としての `ponzi` とは明確に区別する
- **発散後の `NaN` を補間・0化しない**: `Plots.jl` の標準挙動に従い、`NaN` の期間は線を
  途切れさせるだけで、直前・直後の値を結んだり 0 に置き換えたりしない。coverage ratio が
  `Inf`（無借金域）になる期間も同様にギャップとして表示する（値そのものは変更しない）
  ため、「オフスケール（判読不能）区間」であってPonzi期間として塗りつぶされているわけではない
- **`methodology_version`/`config` が異なるシナリオを暗黙に比較しない**:
  `plot_minsky_scenario_comparison` は既定 (`strict=true`) でこれらの不一致を検出すると
  `ArgumentError` を送出し、比較を拒否する
- **「Ponzi = 危機予測」ではない**: §9 と同様、区分・図はモデル内メカニズムの提示であり、
  倒産予測・危機予測・実測の企業比率ではない

統合デモは [`examples/minsky_diagnostics_demo.jl`](../../examples/minsky_diagnostics_demo.jl) を参照
（外部 API 不要、良い均衡回帰経路・崩壊経路の両方を含む）。API 詳細は
[`docs/api.md`](../api.md) の「Minsky 可視化API」節を参照。

---

## 8. 出力結果の読み方

### 返り値の構造

```julia
# simulate / impulse_response の返り値 (NamedTuple)
result = simulate(m, ss.ω, ss.λ, ss.d + 0.01; T = 300)
result.ω  # 賃金シェア時系列  Vector{Float64}（長さ T、第1要素が初期値）
result.λ  # 雇用率時系列
result.d  # 民間債務比率時系列
result.π  # 利潤シェア時系列（派生変数）
result.g  # 実質成長率時系列（派生変数）

# SimulationResult への変換
sr = to_simulation_result(m, result, "simulate")
sr["d"]       # 変数系列の取得
nperiods(sr)  # 期間数
```

### 変数系列の解釈

| 出力変数 | 単位 | 解釈 |
|---|---|---|
| `result.ω` | 水準（比率） | 賃金シェア。良い均衡 `ω̄` と比較して乖離を確認する |
| `result.λ` | 水準（比率） | 雇用率。`1` に近いほど労働市場が逼迫している |
| `result.d` | 水準（比率） | 民間債務比率。崩壊経路では発散し、最終的に `NaN` 埋めされる |
| `result.π` | 水準（比率） | 利払い後の利潤シェア |
| `result.g` | 水準（比率） | 実質成長率 |

RBC・New Keynesian の IRF（対数偏差）とは異なり、**水準（比率）系列**である点に注意する。

### 発散ガードと `NaN` 埋め

崩壊経路では `d` が急速に発散し、`λ → 1` 到達時には Phillips 曲線が特異になる。数値的な暴走を防ぐため、積分中に非有限値の出現・状態変数の絶対値が `guard_max` を超過・`λ ≥ 1` のいずれかを満たした時点で打ち切り、残り期間を `NaN` で埋める（例外は送出しない）。`summarize_result` の統計量は崩壊経路で `NaN` を含みうる。

### 典型的な結果の特徴

- 良い均衡近傍からの微小攪乱は、振動しながら指数的に減衰して均衡へ回帰する
- 大きな攪乱・高債務初期値からの経路は、好況・不況の循環を複数回経てから最終的に崩壊（`NaN` 埋め）に至ることがあり、**必ずしも単調に `d` が増大するわけではない**

---

## 9. AIエコノミスト向け利用ガイド

### このモデルで答えられること（用途）

- 好況期の信用拡大が内生的にどのように不安定化するかの定性的説明
- 初期条件・攪乱の大きさに応じた「良い均衡への回帰」と「債務崩壊」の分岐（双安定性）の提示
- 貸出金利の水準が良い均衡の賃金シェアに与える影響の比較静学（`keen_scenario_comparison`）
- 外生ショックなしに循環・崩壊が生じる点での RBC・New Keynesian との対比

### このモデルでは答えられないこと（限界・非対象）

- **政府部門・財政政策の効果**: 政府部門が存在しない
- **資産価格・ポートフォリオ選択**: 株式市場・Tobin の q 等は扱わない（Ryoo 型拡張の対象）
- **開放経済**: 為替レート・国際資本移動は扱わない
- **名目変数・金融政策**: 物価・名目金利は固定された実質モデルであり、金利 `r` は一定パラメータとして扱う
- **銀行部門の内生的与信行動**: 銀行は受動的に貸し出すと仮定し、信用供給制約・銀行の自己資本制約を扱わない
- **Hedge / Speculative / Ponzi 判定**: 資金繰り区分の判定・金融不安定性指標は `KeenModel` 本体では扱わない。区分は `classify_financing_regime`/`diagnose_financing_regime`（§7「Minsky 資金調達区分診断」）が提供する別レイヤーの診断であり、操作的定義は [Minsky 資金調達区分診断](minsky_regime_diagnostics.md) を参照（集計モデル上の代理指標であり、倒産・危機予測ではない）
- **崩壊経路は予測ではない**: 債務崩壊経路はモデル内メカニズムの提示であり、現実の金融危機の発生時期・規模を予測するものではない

### LLM が参照する際の注意点

- 変数（`ω`・`λ`・`d`・`π`・`g`）はすべて水準（比率）であり、RBC・NK のような対数偏差ではない
- `π` は利払い後の利潤シェアである（利払い前の粗利潤シェアではない）
- 崩壊経路の後半は `NaN` 埋めされる。`summarize_result` の平均・標準偏差等が `NaN` を含みうる点に注意する
- 貸出金利 `r` の引き上げは、良い均衡の閉形式上 `ω̄` のみに影響し、`d̄・λ̄・π̄・ḡ` は不変という非直感的な結果になる（`d̄` の閉形式が `r` を含まないため）。この点を説明する際は式の構造に言及すること
- 「不安定化」「崩壊」という表現は、断定的な将来予測ではなくモデル内メカニズムの提示であることを必ず明示する（[LLM出力の安全性ルール](../llm_safety.md)参照）

---

## 10. モデルの限界

### 理論的限界

| 限界 | 説明 |
|---|---|
| 閉鎖経済・政府部門なし | 財政政策・対外部門の効果を扱えない |
| 実質モデル | 物価・名目金利は固定。インフレーション・金融政策チャンネルは扱わない |
| 受動的な銀行部門 | 信用供給制約・銀行の自己資本制約・与信行動の内生化を扱わない |
| 悪い均衡は非対象 | `steady_state` は良い均衡のみを返す。債務崩壊経路は `simulate`/`impulse_response` の数値解としてのみ観察できる |
| 資産価格なし | 株式・不動産などの資産価格バブルは扱わない（Ryoo 型拡張の対象） |

### 数値的限界

| 限界 | 説明 | 回避策 |
|---|---|---|
| 固定刻み RK4 の刻み幅依存 | `substeps` が小さいと精度が低下する | `ODESolverOptions(substeps=40)` 等で精度向上（`substeps=10` と `20` の差は 1e-7 程度に収束することを確認済み） |
| 発散ガードの閾値依存 | `guard_max` の設定次第で打ち切りタイミングが変わる | デフォルト `1e6` は十分大きいが、極端なパラメータでは調整が必要な場合がある |
| `λ → 1` 特異点近傍の精度低下 | Phillips 曲線 `Φ(λ)` が `λ → 1` で発散するため、その近傍では数値誤差が拡大しやすい | `λ ≥ 1` で打ち切る発散ガードにより暴走は防止される |

---

## 11. 実データとの対応づけ

### 候補系列

以下のデータ系列と対応づけることで、パラメータのキャリブレーションや結果の検証が可能。実データ接続の実装は後続Issueの対象。

| モデル変数 | 実データ系列（日本） | 実データ系列（米国） | 備考 |
|---|---|---|---|
| `ω`（賃金シェア） | SNA 雇用者報酬 / 国民所得（内閣府） | FRED: `PRS85006173`（非農業部門 labor share） | 定義（分母の範囲等）の違いに注意 |
| `λ`（雇用率） | 総務省・労働力調査（1 − 完全失業率） | `1 - UNRATE/100` | 労働力人口の定義差に注意 |
| `d`（民間債務比率） | FRED: `QJPPAM770A`（BIS 民間非金融部門信用/GDP、日本） | FRED: `CRDQUSAPABIS`（同・米国） | いずれも BIS 集計値ベース |
| `r`（貸出金利） | 日本銀行・貸出約定平均金利 | FRED: `DPRIME` 等 | モデルの `r` は一定と仮定するが、実データは時変 |

実データ接続の観測方程式・単位変換規則・共通頻度・年単位ODEと四半期観測を整合させる時間軸契約・固定/推定パラメータの分離・識別戦略・検証方針は、[Keen モデル 実証化戦略](keen_empirical_strategy.md)（決定記録は [ADR 0004](../adr/0004-keen-empirical-calibration-strategy.md)）で定義する。上表の系列は候補であり、採用前に「指数か比率か」「部門範囲」「季節調整」「基準年」を provider metadata で検証すること。

詳細は [Minsky系金融不安定性モデル設計方針](minsky_design.md) セクション7、[モデル変数と実データ系列のマッピング表](../data/variable_mapping.md)を参照。

### キャリブレーション手順の概要

1. SNA/BEA の雇用者報酬比率から `ω` の水準を確認し、Phillips 曲線パラメータ（`φ0, φ1`）を賃金上昇率と失業率の関係から推定する
2. BIS 信用統計（GDP比）の長期平均・トレンドから `d` の妥当な範囲を確認する
3. 政策金利・貸出約定平均金利の長期平均から `r` を設定する

実データ接続の実装は次の 3 層に分かれる（いずれも `KeenModel` 本体を変更しない読み取り専用層）。

- **データ層** `build_keen_empirical_dataset`（`src/data/keen_empirical.jl`）: 系列取得・単位変換・四半期整列で `KeenEmpiricalDataset` を構築
- **推定層** `calibrate_keen`（`src/analysis/keen_calibration.jl`）: 固定/推定パラメータを分離した ODE residual 方式の限定キャリブレーション
- **検証層** `validate_keen`（`src/analysis/keen_validation.jl`）: in-sample/out-of-sample・literature vs calibrated・方向性/転換点/regime 遷移・診断仮定感応度を構造化して返す

### 実証バリデーション（`validate_keen`）

`validate_keen(dataset, config)` は、literature default と calibrated モデルを**同一データ・同一 metric**で
in-sample（calibration 期間）と out-of-sample（validation 期間）へ分けて評価する。validation の初期値は
実観測から開始する方式（`:observed_start`）と calibration 終点予測から連続する方式（`:calibration_continued`）を
別 metric として区別し、look-ahead を作らない。水準誤差（RMSE/MAE）に加え方向性・転換点・
金融不安定性 regime 遷移（[Minsky 資金調達区分診断](minsky_regime_diagnostics.md)・
`minsky_diagnostics_summary`）・発散有無を分けて評価し、`amortization_rate`・金利方式・系列 proxy・標本期間・
initial guess・weight への感応度を返す。

`amortization_rate` の変更は診断のみに作用し ODE・推定結果を変えない（感応度シナリオは base の推定を再利用）。
observed proxy regime は集計系列への操作的定義の代理であり企業別実測分類ではない。実証 fit は因果関係・
危機発生確率・将来予測精度と同一ではなく、実証層では単一 pass/fail 閾値を課さない（成功・失敗・限界を
metric・`warnings`・`caveats` として返す）。詳細は [実証化戦略 §6](keen_empirical_strategy.md)・
[API リファレンス](../api.md)、決定記録は [ADR 0004](../adr/0004-keen-empirical-calibration-strategy.md)。

### literature default と calibrated model の違い・observed proxy regime の意味

- **literature default**: Grasselli & Costa Lima (2012) の文献 default パラメータ（`KEEN_LITERATURE_PARAMS`）。
  普遍的な参照点だが、観測初期状態（例: 米国の観測 `d` は BIS 総民間信用/GDP で ≈ 1.5、良い均衡 `d̄ ≈ 0.07` から大きく乖離）から積分すると発散しうる。
- **calibrated model**: 採用した calibration 期間・観測 proxy・weight・bounds に依存する限定推定値。
  literature より当てはまる保証はなく、悪化した場合も `calibrated_worse_than_literature` と `warnings` で明示する。
  ODE residual 方式の推定であり、trajectory の完全再現を保証しない（自由走行の水準が乖離しうる）。
- **observed proxy regime**: 観測 `ω`・`d` へ Minsky の資金調達区分診断を適用した**集計代理**であり、企業別の実測分類・倒産比率ではない。
  model 側 regime は観測開始状態からの予測 trajectory への診断。

### 実証化フロー（統合デモ）

データ取得 → 観測系列変換 → 限定キャリブレーション → in-sample/out-of-sample 検証 →
observed proxy / model の regime 比較 → 感応度分析 → 可視化 → 機械可読レポート出力までを
1 本で完走する統合デモが [`examples/keen_empirical_demo.jl`](../../examples/keen_empirical_demo.jl)。
fixture モード（既定・API キー不要）で決定的に完走する。取得モードは `DME_DATA_MODE`
（`fixture`/`live`/`rest_api`、`source unavailable` 時に fixture へ暗黙 fallback しない）、
図・レポートの出力先は `KEEN_DEMO_OUTDIR` で切り替える。可視化は
`plot_keen_empirical_trajectories` / `plot_keen_regime_comparison` / `plot_keen_sensitivity`
（欠損・発散後は補間・0 化せず線を途切れさせる）。

---

## 12. 参考文献・参考実装

### 主要文献

| 文献 | 内容 |
|---|---|
| Minsky (1986), *Stabilizing an Unstable Economy* | 金融不安定性仮説（FIH）の原典 |
| Goodwin (1967), "A Growth Cycle" | 賃金シェア×雇用率の成長循環モデル（Keen モデルの基礎） |
| Keen (1995), "Finance and Economic Breakdown: Modelling Minsky's 'Financial Instability Hypothesis'" | Goodwin モデルに企業債務を導入した原論文 |
| Grasselli & Costa Lima (2012), "An Analysis of the Keen Model for Credit Expansion, Asset Price Bubbles and Financial Fragility" | 均衡の閉形式・局所安定性条件・数値例（本実装のデフォルトパラメータの出典） |

### 参考実装

本パッケージは Grasselli & Costa Lima (2012) の定式化に基づく独自実装であり、外部参考実装への直接の依拠はない。

### 関連モデル（DME内）

| モデル | 関係 |
|---|---|
| RBC モデル・New Keynesian モデル | 外生ショック駆動で景気循環を説明する対比対象（Keen モデルは外生ショックなしで循環・崩壊が生じる） |
| [最小 SIM 型 SFC モデル](sim_sfc.md) | 会計整合性を明示する対比対象。概念対応・非対応は [Keen–SFC 概念対応・比較レポート](../analysis/keen_sfc_comparison.md) を参照（民間債務・賃金シェア・雇用率は SIM 側に対応概念が無く比較不能） |

---

## 付録: DME での実装詳細

### 求解アルゴリズムの概要

1. `steady_state(m)` → 良い均衡の閉形式を直接計算（数値求解不要）
2. `simulate(m, ω0, λ0, d0)` → `keen_rk4_step` を `substeps` 回繰り返して1期（1年）分を積分し、`keen_diverged` で発散を判定して打ち切り時点以降を `NaN` 埋め
3. `impulse_response(m, shock)` → 良い均衡から `variable` を `shock` だけずらした初期値を作り `simulate` を呼ぶ
4. `DME.keen_scenario_comparison(m_base, m_scenario)` → 2つのモデルの `steady_state` を比較する `SimulationResult` を構築（`mf_policy_shock` と同型）

### 数値計算オプション

```julia
# ODESolverOptions（固定刻み RK4 のパラメータ調整）
opts = ODESolverOptions(
    substeps  = 20,    # 1期（1年）あたりの RK4 サブステップ数（dt = 1/substeps）
    guard_max = 1e6,   # 発散判定の閾値（状態変数の絶対値上限）
)

result = simulate(m, ω0, λ0, d0; T = 300, options = opts)
```

### 既知の数値的注意点

- `substeps` を増やすほど精度は向上するが計算コストも増える。デフォルトパラメータでは `substeps=10` と `20` の解の差は 1e-7 程度に収束しており、RK4（4次精度）の刻み幅依存が小さいことを確認済み
- 高債務初期値からの経路は好況・不況循環を複数回経てから崩壊に至ることがあり、必ずしも単調に `d` が増大するわけではない
- `λ` が `1` に近づくと Phillips 曲線 `Φ(λ)` が特異になるため、発散ガード（`λ ≥ 1`）が作動する
