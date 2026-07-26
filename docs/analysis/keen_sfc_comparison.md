# Keen–SFC 概念対応・非対応と比較レポート

Keen（Minsky 系）モデルと最小 SIM 型 SFC モデルの概念・機構・会計範囲を比較し、
**同値 / proxy / 部分対応 / 比較不能** を根拠付きで報告する層の解説。

実装: [`src/analysis/keen_sfc_comparison.jl`](../../src/analysis/keen_sfc_comparison.jl)
テスト: [`test/test_keen_sfc_comparison.jl`](../../test/test_keen_sfc_comparison.jl)

関連: [Keen モデル](../models/keen.md) / [最小 SIM 型 SFC モデル](../models/sim_sfc.md) /
[モデル能力・概念定義 metadata](../model_capabilities.md) /
[クロスモデル推論層の設計](../architecture/cross_model_reasoning.md) /
[ADR 0006](../adr/0006-cross-model-reasoning-contract.md) / [ADR 0007](../adr/0007-sfc-integration-contract.md)

---

## 1. 目的と方針

最小 SIM 型 SFC モデルは**会計整合性**（部門別貸借対照表・取引フロー・ストック更新の全期検証）を
明示する一方、Keen モデルの中核である**企業債務・雇用率・賃金シェア・利潤シェア・内生的金融不安定性**を
持たない。逆に Keen は債務動学を内生化するが、部門別 SFC 表を構成せず政府部門も持たない。

この層はその差を「欠陥」として隠さず、**モデルが答えられる問いの違い**として構造化する。

| 方針 | 内容 |
|---|---|
| 概念対応の根拠 | #149 の `ModelCapabilityProfile`（能力プロファイル）と `ModelConceptDefinition`（変数の概念定義）。docs のみを根拠とし数値実証結果は含めない |
| 数値比較の可否 | #150 の `compare_results_v2` / `ComparabilityAssessment` に委ねる。比較不能・情報不足では metric を計算せず理由を返す |
| 出力契約 | Phase 4（ADR 0006）の `ModelConceptMapping` / `CrossModelComparisonContext` / `CrossModelReasoningOutput` を再利用・互換拡張 |
| equivalent の扱い | `concept_definitions_equivalent` が真に一致する場合のみ許可。型コンストラクタが強制する |
| 比較不能の扱い | 統合・平均・単一ランキングへ潰さない。`insufficient_comparability` とし、比較を可能にするために必要な追加モデル・系列・変換を返す |

---

## 2. 概念対応表

`KEEN_SFC_CONCEPT_CORRESPONDENCES`（`keen_sfc_correspondences()` で取得）の内容。
`mapping_type` は「概念として対応するか」、`comparability` は「数値比較してよいか」であり、別問題として扱う。

| 概念 | Keen 側 | SIM 側 | mapping_type | comparability |
|---|---|---|---|---|
| 総産出・総所得 `aggregate_output` | `Y`（生産関数 `Y=K/ν`、連続時間・年） | `Y`（需要決定 `Y=C+G`、離散期・賃金単位） | `partial` | `partial` |
| 家計消費 `household_consumption` | 明示的な消費関数を持たない（集約需要に内包） | `C=α1·YD+α2·H_{t−1}` | `partial` | `partial` |
| 家計の金融資産ストック `household_financial_wealth` | なし | `H`（政府貨幣＝家計の唯一の金融資産） | `incompatible` | `incompatible` |
| 政府負債 `government_liability` | なし（政府部門を持たない） | `H`（政府の負債） | `incompatible` | `incompatible` |
| 民間（企業）債務・レバレッジ `private_debt` | `d = D/Y`（内生。銀行は受動的に貸す） | なし（銀行・企業債務を持たない） | `incompatible` | `incompatible` |
| 資金調達区分 `financing_regime` | Hedge / Speculative / Ponzi（Minsky 診断層） | なし（債務・利払いを持たない） | `incompatible` | `incompatible` |
| 賃金シェア `wage_share` | `ω`（非線形 Phillips 曲線で動学化） | なし（企業利潤ゼロ・`W` は数値基準） | `incompatible` | `incompatible` |
| 利潤シェア `profit_share` | `π = 1 − ω − r·d` | なし（企業利潤ゼロ） | `incompatible` | `incompatible` |
| 雇用率 `employment_rate` | `λ = L/N`（比率） | なし（`N=Y/W` は雇用「水準」。労働人口を持たない） | `incompatible` | `incompatible` |
| 会計閉鎖 `accounting_closure` | 部門別 SFC 表を構成しない（`accounting_closure=:none`） | 全期の会計恒等式を検証（`:stock_flow_consistent`） | `incompatible` | `incompatible` |
| 財政政策 `fiscal_policy` | なし（`fiscal_policy=:none`） | `G`・`θ` が政策変数（`:endogenous`） | `incompatible` | `incompatible` |

### 2.1 共通概念（equivalent）は存在しない

**Keen と SIM に厳密に等価（`equivalent`）な概念は 1 つも無い。** 共通に見える総産出・家計消費も、
決定機構（生産関数 vs 需要決定）・単位（実質水準 vs 賃金単位）・時間軸（連続時間・年 vs 離散期）が
異なるため `partial` に留める。レポートはこの事実を空の `shared_concepts` と warning で明示する。

### 2.2 部分対応・proxy

`partial` の 2 概念は「概念としては共通するが、そのままでは数値比較できない」。`compare_keen_sfc` に
`SimulationResult` を渡すと、比較 API v2 が単位・頻度・日付・概念種別を検証したうえで metric を計算する。

### 2.3 比較不能の理由

| 区分 | 概念 | 理由 |
|---|---|---|
| Keen 固有 | 民間債務・資金調達区分・賃金シェア・利潤シェア・雇用率 | SIM は銀行部門・企業債務・利払い・労働人口・分配動学を持たない |
| SIM 固有 | 家計金融資産・政府負債・会計閉鎖・財政政策 | Keen は家計金融資産ストック・政府部門・部門別 SFC 表を持たない |

**同一視してはならない対応（安全性契約）**

- SIM の政府貨幣 `H`（政府負債＝家計資産）と Keen の民間債務 `d` は、発行主体・利払い構造・返済制約が
  異なる。同一の「債務」として同一視・集計・代理しない。
- SIM の雇用水準 `N` は比率である `λ` と概念種別（level vs ratio）が異なる。同一視しない。
- SIM 出力から金融不安定性・分配指標（`keen_sfc_sim_unavailable_indicators()` が返す
  `private_debt` / `financing_regime` / `wage_share` / `profit_share` / `employment_rate`）を生成しない。
- Keen の内部恒等式を「SFC 検証済み」と述べない。また SIM の会計恒等式が保証するのは**内的整合性**で
  あって現実妥当性ではない。

---

## 3. 会計構造と動学機構の違い

`keen_sfc_mechanism_diff()`（比較 API v2 の `:mechanism` モードと同じ差分関数）が返す
能力 metadata の構造化差分。数値 metric は含まない。

| 項目 | Keen | SIM |
|---|---|---|
| 会計閉鎖 `accounting_closure` | `none` | `stock_flow_consistent` |
| 内生信用 `endogenous_credit` | `true` | `false` |
| 部門 `sectors` | household, firm, **bank** | household, firm, **government** |
| 金融商品 `instruments` | debt, loan | money |
| 所得分配 `income_distribution` | `endogenous` | `none` |
| 財政政策 `fiscal_policy` | `none` | `endogenous` |
| 均衡概念 `equilibrium_concept` | `bistable_with_crisis` | `stock_flow_steady_state` |
| 時間表現 | 連続時間（年単位パラメータ） | 離散期 |
| 対応 API | steady_state, simulate, impulse_response, **calibration, validation** | steady_state, simulate, impulse_response |

---

## 4. 各モデルが適する分析問い

`keen_sfc_suitable_questions()` が返す一覧（docs と能力 metadata の記述範囲に限定）。

**Keen**

- 民間債務の累積が賃金シェア・雇用率の循環（Goodwin 循環）にどう作用するか。
- 外生ショックなしにモデル内部の非線形性だけで債務崩壊（危機regime）が生じる条件は何か。
- 利子率・投資関数パラメータの変化が良い均衡への収束/発散をどう変えるか。
- 資金調達区分（Hedge/Speculative/Ponzi）の滞在比率と推移がどう変化するか（集計比率からの proxy 分類）。
- 実データへの限定キャリブレーションと感応度・regime 比較による検証（Keen 実証層）。

**SIM（SFC）**

- 財政赤字が家計の金融資産ストック `H` としてどう積み上がるか。
- 政府支出 `G`・税率 `θ` のショックが産出・可処分所得・貨幣ストックの移行経路をどう変えるか。
- 貸借対照表・取引フローが全期で閉じているか（stock-flow consistency の検証）。
- 需要決定産出と前期末ストックからの消費が定常状態 `Y*=G/θ` へどう収束するか。
- 部門別の源泉・使途がどの取引で釣り合っているか（部門予算制約の可視化）。

---

## 5. 利用例

### 5.1 構造比較のみ（系列なし・決定的）

```julia
using DME

report = compare_keen_sfc()

report.shared_concepts          # 空（厳密に等価な概念は無い）
report.partial_concepts         # aggregate_output, household_consumption
report.incomparable_concepts    # 9 概念（Keen 固有 5・SIM 固有 4）
report.structural_differences   # 会計閉鎖・部門・機構の構造化差分
report.suitable_questions       # 各モデルが適する分析問い
report.minsky_sfc_gaps          # 次期 Minsky-SFC で埋めるべきギャップ
report.required_evidence        # 比較を可能にするために必要な追加モデル・系列・変換
```

### 5.2 数値比較（比較可能な系列のみ metric を返す）

```julia
sim = SIMModel(; α1 = 0.6, α2 = 0.4, θ = 0.2, G = 20.0)
sim_sr = to_simulation_result(sim, simulate(sim; T = 50), "baseline")

# Keen 側の産出系列は既定 simulate（ω, λ, d）に含まれないため利用側で用意する
keen_sr = SimulationResult("Keen Model", "synthetic", Dict("Y" => keen_output_series), Dict{String,Any}())

report = compare_keen_sfc(;
    keen_result = keen_sr,
    sim_result = sim_sr,
    allow_period_index = true,   # 日付 metadata が無い結果同士の位置比較は明示許可が必要
)

keys(report.numeric_comparisons)                     # ["aggregate_output"] のみ
report.numeric_comparisons["aggregate_output"].metrics["Y"].rmse
report.skipped_comparisons                           # 不実施の概念・理由・必要な追加証拠
```

比較不能な概念は、SIM 側の結果に `d` や `ω` という名前の系列が含まれていても **metric を計算しない**。
対応は変数名の一致ではなく概念対応 registry で決まる。

### 5.3 会計 check・Keen 実証結果を根拠に加える

```julia
sfc = sfc_result(sim, simulate(sim; T = 50))
acc = validate_sfc_accounting(sfc)

report = compare_keen_sfc(; accounting_report = acc, empirical = keen_ctx)
report.context.sources["accounting.sim.check"]   # 会計検証結果が根拠 source に反映される
```

会計恒等式に違反がある場合は `SFC_ACCOUNTING_VIOLATION`（severity `:error`）warning が付き、
SIM 側の数値解釈を限定するよう明示される。

### 5.4 根拠付き構造化説明（LLM 任意）

```julia
out = explain_keen_sfc_comparison(report)                       # provider なし → :deterministic
out = explain_keen_sfc_comparison(report; provider = my_llm)    # 検証通過で :parsed、失敗で :fallback

out.incomparable_or_insufficient.status   # :insufficient_comparability
out.source_references                     # claim が実際に参照した根拠 source
```

`provider` を指定しても、応答が schema・source registry・category/status 整合を満たさなければ
決定的 fallback（`OUTPUT_SCHEMA_INVALID` warning 付き）に落ちる。ADR 0006 の契約をそのまま継承する。

---

## 6. 根拠 source registry

`build_keen_sfc_comparison_context()` が登録する source（`KEEN_SFC_SOURCE_IDS`）。

| source ID | category | 内容 |
|---|---|---|
| `doc.keen.model` | `model_concept` | Keen モデル解説（`docs/models/keen.md`） |
| `doc.sim.model` | `model_concept` | 最小 SIM 型 SFC モデル解説（`docs/models/sim_sfc.md`） |
| `capability.keen` / `capability.sim` | `model_concept` | 能力プロファイル metadata（#149） |
| `accounting.sim.check` | `model_output` | SFC 会計恒等式検証（`validate_sfc_accounting`） |
| `empirical.keen.*` | `empirical_evidence` | Keen 実証結果サマリー（`empirical` を渡した場合のみ） |
| `concept.<model>.<axis>` | `model_concept` | ADR 0006 の比較軸 coverage |
| `mapping.keen.sim.<concept>` | `concept_mapping` | Keen–SFC 概念対応 |
| `limitation.keen_sfc_contract` | `limitations` | 本層の安全性・限界 |

---

## 7. 数値比較を実施した項目と不実施理由

`compare_keen_sfc` は各概念について次の順で判定し、metric を返さない場合は必ず理由を残す。

| 判定 | `skipped_comparisons` の `reason` |
|---|---|
| `comparability=:incompatible` | 「比較不能（mapping_type=incompatible）: …」＋ 対応の根拠 |
| `comparability=:insufficient` | 「情報・変換が不足しているため数値比較しない。」 |
| `SimulationResult` 未指定 | 「数値比較に必要な SimulationResult が渡されていない」 |
| 片側に系列が無い | 「Keen 側に対応系列 "C" が無い（既定出力は ω, λ, d）。」等 |
| v2 の比較可能性検証で降格 | 「比較可能性の検証で降格（level=…）: …」＋ v2 の理由 |

各エントリは `required_evidence`（比較を可能にするために必要な追加モデル・系列・変換）を併せて返す。

---

## 8. 将来拡張（次期 Minsky-SFC モデルで埋めるべきギャップ）

`keen_sfc_minsky_gaps()` が比較不能概念の `required_evidence` と ADR 0007 §11 から決定的に導出する。

- 銀行部門・企業債務・利子付き資産を含む部門別 SFC 行列（instrument に `:loan`/`:deposit`/`:bond`、
  sector に `:bank`/`:firm` を追加）。
- 政府部門・国債・利払い・財政ルールを持つ Minsky-SFC モデル。
- 企業利潤・内部留保・投資を内生化し、賃金シェア・利潤シェアの動学を会計恒等式と両立させること。
- 資金調達区分診断を集計比率の proxy ではなく SFC 表の負債・利払いフローから直接構成すること。
- 危機regime の内生化を会計整合性を保ったまま表現すること。
- SIM 側に労働人口（労働供給）系列を追加し雇用率を定義すること。

これらが埋まるまで、該当概念は `insufficient_comparability` のまま返し、統合しない。

---

## 9. テストと安全性回帰

| 観点 | 検証内容 |
|---|---|
| registry 契約 | `incompatible` の概念に数値比較レベルを与えられない・`equivalent` は概念定義が真に等価な場合のみ |
| 債務概念 | 民間債務を `equivalent`/`proxy` と誤判定しない・政府負債と企業債務を同一視しない |
| 指標の捏造防止 | SIM 出力に `d`/`ω` 相当の系列があっても Keen 固有指標の metric を返さない |
| 数値比較 | comparable/partial かつ両側に系列がある概念のみ v2 metric を返す |
| LLM 安全性 | provider 未接続で決定的生成・壊れた応答で `:fallback`・禁止解釈 fixture を安全性評価器が検出 |

禁止解釈 fixture は [`test/fixtures/llm/keen_sfc/forbidden/`](../../test/fixtures/llm/keen_sfc/forbidden/)
に置く（追加手順は同ディレクトリの `README.md`）。いずれも production parser の schema 検証は通るが、
安全性評価器 `ksfc_safety_violations` が禁止解釈として検出する。
