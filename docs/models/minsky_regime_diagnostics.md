# Minsky 資金調達区分（Hedge / Speculative / Ponzi）診断 — 操作的定義と契約設計

---

## メタ情報

| 項目 | 内容 |
|---|---|
| **対象モデル** | Keen モデル（`KeenModel`、[keen.md](keen.md)） |
| **ステータス** | 実装済み（`src/analysis/minsky_regimes.jl`、#112） |
| **関連 Issue** | #99（ロードマップ）・#111（本設計）・#112（実装）。依存: #103–#106 |
| **関連 ADR** | [ADR 0003](../adr/0003-minsky-financing-regime-diagnostics.md)（責務境界・tolerance/hysteresis 採否） |
| **前提 ADR** | [ADR 0001](../adr/0001-minsky-model-selection.md)・[ADR 0002](../adr/0002-minsky-integration-design.md) |
| **methodology version** | `minsky-regime/1.0.0` |

> **LLM向け要約**: 本書は Keen モデルの出力（賃金シェア `ω`・雇用率 `λ`・民間債務比率 `d`）から Minsky の資金調達区分（Hedge / Speculative / Ponzi）を診断するための**操作的定義**を定める。区分はモデルの状態変数から一意には決まらないため、元本返済負担を診断層だけの明示的仮定（`amortization_rate`）で代理し、区分は理論概念そのものではなく**集計モデル上の代理指標**である。倒産予測・危機予測ではない。

---

## 1. 背景と設計の狙い

Phase 1 で Keen モデルの状態変数・動学シミュレーション・ショック分析・LLM 接続が利用可能になった（[keen.md](keen.md)）。Minsky の資金調達区分は、企業の**期待キャッシュフローが利払いと元本返済をどこまで賄えるか**に基づく分類である。

しかし Keen モデルは集計（マクロ）モデルであり、次のものを状態変数として持たない。

- 契約上の元本返済スケジュール
- 債務満期構成
- 企業・家計ごとの異質な資金繰り

したがって区分を Keen 出力から自動的・一意に決めることはできない。本書は、この制約を明示したうえで、

1. 診断に使うフロー量を**同一単位（産出比・年率）**で定義し、
2. 区分の**境界条件と数値許容差**を確定し、
3. 実装可能な粒度で**型・関数・戻り値・methodology version の契約**を固定し、
4. 理論上・実証上の**限界**を明記する。

区分の判定式・境界を「理論上の概念」と「DME 上の代理指標」の混同なく実装へ引き渡すことが目的である。

---

## 2. 診断に用いるフローの定義

すべて**産出比・年率**（`Y` に対する比、1 年あたり）で定義する。`ω`・`d` は Keen モデルの状態変数、`r` は貸出金利パラメータ、`amortization_rate` は診断層の仮定（§3）。

| 量 | 定義式 | 意味 |
|---|---|---|
| 営業余剰（利払い前 CF の代理） | `operating_surplus = 1 - ω` | 賃金支払い後・利払い前のキャッシュフロー代理 |
| 利払い負担 | `interest_commitment = r * max(d, 0)` | 契約上の利払いコミットメント |
| 元本返済負担の代理 | `principal_commitment = amortization_rate * max(d, 0)` | 元本返済コミットメントの代理（診断仮定） |
| 総デットサービス | `debt_service = interest_commitment + principal_commitment` | 利払い＋元本返済代理の合計 |
| 利払い後利潤シェア | `π = 1 - ω - r * d` | 既存 Keen モデルの派生変数（利払い後） |

### 2.1 `max(d, 0)` の役割

利払い・元本返済コミットメントは `max(d, 0)` を使う。`d < 0`（純貸し手・実質無借金）ではコミットメントを 0 とし、誤って負のデットサービスを与えない。負の `d` は §4 の `unlevered` へ分類される（§4.3）。

### 2.2 `π` とフローの恒等式

正の債務（`d > 0`）の下で次の恒等式が成り立つ。

```
π = operating_surplus - interest_commitment          （d > 0 のとき）
```

すなわち **`π` は「営業余剰が利払いをどれだけ上回るか」のマージン**そのものである。区分はこの `π` と元本返済代理 `principal_commitment` の大小で定義でき（§4）、直感と対応する。`d ≤ 0` の領域ではこの恒等式は一般に成り立たないが、その領域は `unlevered` に分類されるため区分判定には影響しない。

---

## 3. 元本返済代理の仮定（`amortization_rate`）

`amortization_rate` は **Keen モデル本体の構造パラメータではなく、診断層だけで使う明示的な仮定**である。`KeenModel` の `struct`・`parameters(m)`・ODE 動学には一切含めない（責務境界は [ADR 0003](../adr/0003-minsky-financing-regime-diagnostics.md)）。

### 3.1 単位と解釈

| 項目 | 内容 |
|---|---|
| 単位 | `1/年`（毎年、残存債務のうち返済に回る割合） |
| 解釈 | 平均債務満期 `M`（年）の逆数の代理 `amortization_rate ≈ 1/M` |
| 得られる量 | `principal_commitment = amortization_rate * max(d, 0)` は産出比・年率になる（`(1/年) × 無次元比`） |

### 3.2 既定値と根拠

| 項目 | 値 |
|---|---|
| 既定値 | `amortization_rate = 0.05`（平均満期 20 年、`1/20` に相当） |
| 根拠 | 企業債務の平均満期を長め（10–30 年）に取る保守的設定。集計債務比率 `d` は長期の信用ストックであり、単年で大部分が満期到来する短期債務前提は過大なデットサービスを与えるため避ける |

既定値は**理論的アンカーではなく作業仮定**であり、実データによる推定・校正は Phase 3 の対象である（§7）。

### 3.3 感応度確認方針

`amortization_rate` は区分の `hedge`／`speculative` 境界を直接動かすため、単一値に依存した結論を出さない。実装後は次のグリッドで感応度を確認することを標準とする。

| `amortization_rate` | 平均満期 | 診断への影響 |
|---|---|---|
| `0.00` | ∞（元本返済なし） | `principal_commitment = 0` となり `speculative` 帯が消失。`hedge` は `π ≥ 0`、境界は Ponzi 境界（`π = 0`）のみ。**退化ケースの整合性チェック**として有用 |
| `0.05` | 20 年 | 既定 |
| `0.10` | 10 年 | `speculative` 帯が拡大 |
| `0.20` | 5 年 | 短満期前提。`hedge` が縮小し多くの時点が `speculative`/`ponzi` へ |

感応度確認では、**区分系列の質的な結論（例: 崩壊前に `speculative`→`ponzi` へ移行する）が `amortization_rate` の妥当な範囲で頑健か**を報告する。`amortization_rate = 0` の退化ケースで `speculative` が消えることは仕様どおりであり、バグではない。

---

## 4. 資金調達区分の操作的定義

数値許容差 `τ = classification_tolerance`（§5）を考慮したうえで、区分を次のように定義する。判定は**時点ごとに独立**（メモリレス）であり、過去の区分に依存しない（hysteresis 不採用の理由は [ADR 0003](../adr/0003-minsky-financing-regime-diagnostics.md)）。

### 4.1 マージン量

```
margin_interest  = operating_surplus - interest_commitment   （= π, d>0）  … Ponzi 境界までの距離
margin_principal = operating_surplus - debt_service          （= π - principal_commitment, d>0） … Hedge 境界までの距離
```

### 4.2 基本分類（levered 領域）

`d > debt_tolerance` かつ入力が有限なとき、次の順で判定する。

| 区分 | 条件 | 経済的意味 |
|---|---|---|
| `hedge` | `margin_principal ≥ -τ` | 営業余剰が利払いと元本返済代理の**双方**を賄う |
| `speculative` | `margin_principal < -τ` かつ `margin_interest ≥ -τ` | 利払いは賄うが、元本返済代理まで**は賄わない** |
| `ponzi` | `margin_interest < -τ` | 営業余剰が**利払いすら賄わない** |

境界は許容差 `τ` の分だけ「賄える側（`hedge`/`speculative`）」に寄せる（`≥ -τ`）。これにより境界ちょうど（`margin = 0`）は数値誤差で反転せず、賄える側に確定する。

### 4.3 特殊区分（precedence 付き）

判定は次の**優先順位**で行う。上位が成立したら下位は評価しない。

1. `invalid` — `ω`・`λ`・`d`・`π` のいずれかが非有限（`NaN`/`Inf`）。発散後の `NaN` 埋め区間（[keen.md](keen.md) §8）を含む。**最優先**で判定し、`NaN` を誤って `hedge`/`ponzi` に分類しない。
2. `unlevered` — `d ≤ debt_tolerance`（負の `d` を含む）。正の債務負担が実質的にない。デットサービスがほぼ 0 のため Hedge/Speculative/Ponzi の区別が無意味な領域を明示的に切り出す。
3. `hedge` / `speculative` / `ponzi` — §4.2 の基本分類。

```
if 非有限(ω, λ, d, π)      => :invalid
elseif d <= debt_tolerance => :unlevered
elseif margin_principal >= -τ => :hedge
elseif margin_interest  >= -τ => :speculative
else                          => :ponzi
```

`invalid` を最優先にするのは、`d` が `NaN` のとき `d ≤ debt_tolerance` の評価が意味を持たないため（`NaN` 比較は `false` になり silently に別区分へ落ちる危険がある）。明示的に非有限を先に弾く。

### 4.4 受け入れ条件との対応

| 受け入れ条件（Issue #111） | 対応箇所 |
|---|---|
| Hedge/Speculative/Ponzi の判定式・単位・境界条件が明文化 | §2・§4.1・§4.2 |
| 正の債務がない状態を誤分類しない | §4.3（`unlevered`、precedence 2） |
| 発散後 `NaN` を Hedge/Ponzi へ誤分類しない | §4.3（`invalid`、precedence 1） |
| 元本返済代理の仮定と感応度確認方針の明示 | §3 |
| 型・関数・戻り値・methodology version の契約 | §5・§6 |
| 診断層と Keen 本体の責務境界を ADR に記録 | [ADR 0003](../adr/0003-minsky-financing-regime-diagnostics.md) |

---

## 5. 数値許容差と時点間の安定化

### 5.1 `classification_tolerance`（採用）

境界近傍の浮動小数点ジッタで区分が反転しないよう、境界比較に対称な許容差 `τ = classification_tolerance` を導入する（§4.2）。既定値は `1e-9`（産出比・年率スケールに対して十分小さく、実質的な誤分類を招かない）。

### 5.2 hysteresis（初版で不採用）

境界を跨ぐ区分の頻繁な反転に対し、hysteresis（区分ごとに異なる進入・退出閾値）を導入するかを検討した。**初版では採用しない。** 理由の要約（詳細と決定は [ADR 0003](../adr/0003-minsky-financing-regime-diagnostics.md)）:

- 時点ごとの純粋関数（メモリレス）に保つことで、`NamedTuple` 出力・`SimulationResult` の双方から**状態を持ち回さずに**診断でき、契約が単純になる。
- hysteresis は経路依存性と追加の内部状態を導入し、再現性・methodology version の意味論を複雑にする。
- `classification_tolerance` で数値ジッタは抑制済み。境界近傍での真の頻繁な反転は「借り手が実際にマージン上に張り付いている」という**経済的に意味のある情報**であり、平滑化で隠すべきではない。

実データ系列（Phase 3）でノイズが過大と判明した場合の hysteresis 導入余地は ADR に将来オプションとして記録する。

---

## 6. 診断契約（型・関数・戻り値）

以下は**後続 Issue が追加の理論判断なしに実装できる粒度**の公開契約である。命名・配置は既存規約（`src/models/keen.jl` に診断関数、`SimulationResult` は `src/core/`）に準拠する。

### 6.1 設定型 `FinancingRegimeConfig`

```julia
"""
    FinancingRegimeConfig

Minsky 資金調達区分診断の設定。すべて診断層専用であり KeenModel には影響しない。
"""
struct FinancingRegimeConfig
    amortization_rate::Float64        # 元本返済代理率（1/年）。既定 0.05
    debt_tolerance::Float64           # unlevered 判定閾値。既定 1e-8
    classification_tolerance::Float64 # 境界の数値許容差 τ。既定 1e-9
    methodology_version::String       # 既定 "minsky-regime/1.0.0"
end
```

- 便利コンストラクタで既定値を与える（`FinancingRegimeConfig(; amortization_rate=0.05, debt_tolerance=1e-8, classification_tolerance=1e-9, methodology_version="minsky-regime/1.0.0")`）。
- hysteresis 閾値フィールドは持たない（§5.2、[ADR 0003](../adr/0003-minsky-financing-regime-diagnostics.md)）。将来採用時に methodology version を上げて追加する。

### 6.2 観測型 `FinancingRegimeObservation`

```julia
"""
    FinancingRegimeObservation

単一時点の資金調達区分診断結果。
"""
struct FinancingRegimeObservation
    period::Int                      # 時点（1 始まり、シミュレーション期に対応）
    regime::Symbol                   # :hedge / :speculative / :ponzi / :unlevered / :invalid
    operating_surplus::Float64       # 1 - ω
    interest_commitment::Float64     # r * max(d, 0)
    principal_commitment::Float64    # amortization_rate * max(d, 0)
    debt_service::Float64            # interest + principal
    distance_to_hedge_boundary::Float64  # margin_principal = π - principal_commitment（正=Hedge 側）
    distance_to_ponzi_boundary::Float64  # margin_interest  = π（正=非 Ponzi 側）
    methodology_version::String      # 生成時の methodology version（provenance）
end
```

- 境界距離は**産出比・年率**単位。正なら該当境界の安全側、負なら跨いだ側。`invalid` 時は距離を `NaN` とする。
- `methodology_version` を各観測に持たせ、混在系列でも provenance を追跡できるようにする。

### 6.3 時系列診断結果と regime transition

```julia
"""
    FinancingRegimeTransition

区分が変化した時点の記録。
"""
struct FinancingRegimeTransition
    period::Int      # 遷移後（to 側）の時点
    from::Symbol
    to::Symbol
end

"""
    FinancingRegimeDiagnostics

時系列全体の診断結果。
"""
struct FinancingRegimeDiagnostics
    observations::Vector{FinancingRegimeObservation}
    transitions::Vector{FinancingRegimeTransition}  # 区分が変わった時点のみ
    config::FinancingRegimeConfig
end
```

### 6.4 関数契約

```julia
# 単一時点の区分（純粋関数、メモリレス）
classify_financing_regime(
    ω::Float64, λ::Float64, d::Float64, r::Float64;
    config::FinancingRegimeConfig = FinancingRegimeConfig(),
) -> Symbol

# NamedTuple 出力（simulate / impulse_response）からの時系列診断
diagnose_financing_regime(
    m::KeenModel, result::NamedTuple;
    config::FinancingRegimeConfig = FinancingRegimeConfig(),
) -> FinancingRegimeDiagnostics

# SimulationResult からの時系列診断
diagnose_financing_regime(
    sr::SimulationResult;
    config::FinancingRegimeConfig = FinancingRegimeConfig(),
) -> FinancingRegimeDiagnostics
```

**契約詳細:**

- `classify_financing_regime` は `π = 1 - ω - r*d` を**内部で再計算**し、格納済み `π` に依存しない（保存経路による不整合を避ける）。§4.3 の precedence に従って `Symbol` を返す。
- `diagnose_financing_regime(m, result)` は `r = m.r` を使い、`result.ω`・`result.λ`・`result.d` を各時点で `classify_financing_regime` に通す。`result` に含まれる `π`・`g` は診断に使わない。
- `diagnose_financing_regime(sr)` は `sr["ω"]`・`sr["λ"]`・`sr["d"]` と、`sr.metadata["parameters"].r`（`to_simulation_result` が自動設定、[simulation_result.jl](../../src/core/simulation_result.jl)）から `r` を取得する。`ω`/`λ`/`d` キーまたは `parameters.r` が欠ける場合は `ArgumentError` を送出する（区分を推測しない）。
- 両オーバーロードとも、非有限時点は `:invalid` として観測を生成し、例外を送出しない（発散経路の `NaN` 埋めと整合、[keen.md](keen.md) §8）。
- `transitions` は隣接時点で `regime` が変化した箇所のみを記録する。`:invalid` との間の遷移も遷移として記録する（崩壊への移行を追跡できる）。

### 6.5 `NamedTuple` 出力・`SimulationResult` 双方からの利用

Keen の `simulate`/`impulse_response` は `NamedTuple`、比較・可視化・LLM 層は `SimulationResult` を扱う（[keen.md](keen.md) §8、[ADR 0002](../adr/0002-minsky-integration-design.md)）。上記 2 オーバーロードで**両経路を同一 config・同一定義でカバー**する。診断は読み取り専用の後処理であり、いずれの入力に対しても Keen の ODE 動学・パラメータ・`steady_state` を変更しない。

---

## 7. 理論上・実証上の限界

Issue #111 §4 の限界を、LLM 出力でも必須記載とする（[LLM 出力の安全性ルール](../llm_safety.md)）。

| 限界 | 内容 |
|---|---|
| 集計モデル上の代理診断 | 企業・家計ごとの資金調達区分ではなく、経済全体の集計 `ω`/`d` から導く代理指標である |
| 元本返済負担は診断仮定 | `principal_commitment` は観測された満期構成ではなく、`amortization_rate` という診断仮定に基づく代理である |
| Ponzi 判定は予測ではない | `ponzi` 区分は倒産予測・市場危機予測・危機発生時期の予測ではない。モデル内メカニズムの提示である |
| 校正は Phase 3 | 実データを用いた `amortization_rate` 推定・境界閾値の校正は Phase 3 の対象。本書の既定値は作業仮定 |
| 診断は動学を変えない | 診断層の設定変更（`amortization_rate` 等）は Keen モデルの ODE 動学そのものを一切変更しない（[ADR 0003](../adr/0003-minsky-financing-regime-diagnostics.md)） |
| 単一時点の断面 | 区分はメモリレスな断面診断であり、将来のキャッシュフロー期待や資産価格を織り込まない（Keen モデル自体が資産価格を持たない、[keen.md](keen.md) §10） |

---

## 8. 対象外（本 Issue のスコープ外）

- 分類ロジックの本実装（型・関数の実体は後続 Issue）
- 実データによる `amortization_rate` 推定・閾値校正（Phase 3）
- 企業・家計の異質性、SFC / ABM の追加
- LLM による自然言語での区分判定（診断は数値契約のみを提供し、説明生成は既存 LLM 層の責務）

---

## 9. 後続実装への引き渡しチェックリスト

後続 Issue は次を追加の理論判断なしに実装できる。

- [x] §6.1–§6.3 の 4 型（`FinancingRegimeConfig`・`FinancingRegimeObservation`・`FinancingRegimeTransition`・`FinancingRegimeDiagnostics`）を定義する
- [x] §6.4 の `classify_financing_regime` を §4.3 の precedence どおりに実装する
- [x] §6.4 の `diagnose_financing_regime` を `NamedTuple`・`SimulationResult` の 2 経路で実装する
- [x] `methodology_version = "minsky-regime/1.0.0"` を既定に設定する
- [x] テスト: `unlevered`（`d≈0`）・`invalid`（`NaN`）を Hedge/Ponzi に誤分類しないこと、退化ケース `amortization_rate=0` で `speculative` が消えること、崩壊経路で終盤が `invalid` になることをアンカーする
- [x] 感応度（§3.3 のグリッド）で質的結論の頑健性を確認する

---

## 10. 参考

- [Keen モデル解説](keen.md) — 状態変数・出力スキーマ・`NaN` 埋め・限界
- [ADR 0003](../adr/0003-minsky-financing-regime-diagnostics.md) — 責務境界・tolerance/hysteresis 採否の決定記録
- [Minsky系金融不安定性モデル設計方針](minsky_design.md) — Keen 採用の経緯と実データ候補系列
- [LLM 出力の安全性・免責・禁止表現ルール](../llm_safety.md) — 予測断定の禁止・必須免責
- Minsky (1986), *Stabilizing an Unstable Economy* — Hedge/Speculative/Ponzi の原典的定義
