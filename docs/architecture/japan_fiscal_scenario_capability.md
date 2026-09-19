# Japan Fiscal Scenario Lab — scenario family × model capability / mapping 契約

Japan Fiscal Scenario Lab（[Issue #273](https://github.com/Yuki-Watanabe7/DME/issues/273)）で扱う 5 つの scenario family を、
既存 DME モデルでどこまで表現できるかを**実装前に固定した契約**。
[Issue #274](https://github.com/Yuki-Watanabe7/DME/issues/274) の成果物であり、scenario catalog（#275）・
model adapter / runner（#276）・E2E / consumer artifact（#277）はこの判定を前提に進める。

> 関連: [ADR 0020](../adr/0020-japan-fiscal-scenario-capability-contract.md)（決定記録）・
> [モデル能力・概念定義 metadata](../model_capabilities.md)・
> [マクロイベント変換契約](macro_event_contract.md)・
> [ADR 0019](../adr/0019-long-rate-funding-shock-contract.md)（長期金利・funding-cost shock）・
> [ADR 0010](../adr/0010-macro-event-scenario-contract.md)（イベントの4層分離）

実装ファイル: [`src/scenarios/japan_fiscal_capability.jl`](../../src/scenarios/japan_fiscal_capability.jl)。
契約 version: `JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION = "japan-fiscal-scenario-capability/1.0.0"`。

---

## 1. この文書が決めること・決めないこと

決めること。

- 5 scenario family × 11 候補モデル = **55 セルすべての representability 判定**とその理由。
- 各セルで assumption 概念がどのモデル変数へ、どの単位・どの時間軸で入るか。
- 表現できない概念を**どの変数へ寄せてはならないか**（禁止代理の列挙）。
- FRE（fiscal-regime-engine）snapshot の役割を `observed_context_only` に固定すること。
- 解消せず限界として保持する構造的ギャップ 15 件（`G-01`–`G-15`）。
- Phase 3 で実装する mapping（`adoption = :primary` / `:supporting`）。

決めないこと。

- モデル方程式の改造（#273 non-goal）。本契約は既存モデルを一切変更しない。
- scenario catalog・assumption schema の型定義（#275）。
- adapter / runner / result artifact の実装（#276）。
- fixture・E2E・Market Analyzer handoff（#277）。
- モデルの自動選択・ランキング。

### 1.1 最初に結論

監査の結果、次の 3 点が Phase 3 全体の前提になる。

1. **利付き政府債務ストックを持つモデルが 1 つも無い**（`G-01`）。SIM の `H` は無利子の政府貨幣であり国債ではない。
   したがって債務残高/GDP・利払費・`r − g` 債務動学は、どの scenario family でも出力できない。
2. **日本データで較正されたモデルが 1 つも無い**（`G-02`）。実証較正は Keen（米国）と CCC（米国 NIPA・AI/半導体）のみで、
   イベント層の `geography` 既定値も `"US"` である。したがって Phase 3 のすべての結果は方向と相対的な時間形状までであり、
   日本の量として提示できない。契約上は `claim_level = :magnitude` を名乗れるセルが存在しない。
3. **GDP 成長率パスを外生入力として受け取るモデルが 1 つも無い**（`G-03`）。成長は必ず構造ドライバー
   （Solow の `g`・RBC の TFP・Keen の `α`）へ変換され、その変換は一意でない。

この 3 点は #276 の adapter 実装で「後から埋める」ことができない。埋めるには新しいモデルが要り、それは #273 の non-goal である。

---

## 2. 境界と層

```text
FRE Current Snapshot
  └─ observed_context / scenario_relevance だけに使う（magnitude を作らない）
Explicit Scenario Assumption        ← 本契約の `JAPAN_FISCAL_ASSUMPTION_CONCEPTS`（9 概念）
  └─ model-specific mapping         ← 本契約の `JapanFiscalModelMapping`（55 セル）
Applied model input                 ← モデル側の変数・パラメータ・ショック過程
  └─ model-implied result           ← `claim_level` が主張してよい水準を定める
```

### 2.1 FRE context contract

| 項目 | 値 |
|---|---|
| `JAPAN_FISCAL_FRE_CONTEXT_ROLE` | `:observed_context_only` |
| `JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_SOURCES` | `(:external_belief,)` |
| `JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_INPUT_FIELDS` | `regime_affinity` / `regime_share` / `regime_confidence` / `dimension_score` / `constraint_pressure` / `data_quality_score` |

契約。

1. FRE の affinity・share・confidence・dimension score・Constraint Pressure は、**どの assumption の magnitude 導出にも入力しない**。
   これらは「どのレジームに近いか」の度合いであって経済量ではない（FRE 設計原則 `Regime affinity ≠ probability`・
   `DME shock magnitude ≠ regime confidence`）。
2. `magnitude_source = :external_belief` を Japan fiscal scenario assumption で受理しない
   （[`japan_fiscal_magnitude_source_allowed`](../../src/scenarios/japan_fiscal_capability.jl) が `false` を返す）。
   外部システムの belief に数量が付いていても、それを経由して FRE のスコアが magnitude へ入る経路を作らない。
3. 本 registry のどの `JapanFiscalInputMapping.variable` も FRE のフィールド名と一致しない（テストで検査する）。
4. FRE context の欠測・`unavailable` を 0 として扱わない。0 は「変化なし」という別の主張である。

### 2.2 assumption 概念（9 種）

| 概念 | 単位 | 基準 | イベント層 target concept |
|---|---|---|---|
| `:growth_path` | %pt（年率成長率） | `:growth_rate` | — |
| `:productivity_growth` | %pt（年率）または水準指数 | `:growth_rate` | — |
| `:policy_rate` | %pt（年率） | `:rate` | `:policy_rate` |
| `:long_rate_funding_condition` | bp | `:rate` | `:long_rate_funding_condition` |
| `:government_spending` | 水準 または 対 GDP 比 | `:level` | — |
| `:tax` | 税率（比率）または税額（水準） | `:rate` | — |
| `:primary_balance` | 対 GDP 比 | `:ratio_to_gdp` | — |
| `:inflation` | %pt（年率） | `:rate` | — |
| `:cb_jgb_absorption` | 残高 または 対 JGB 発行残高比 | `:stock` | — |

`:policy_rate` と `:long_rate_funding_condition` は、イベント層の同名 target concept と**同一の概念・同一の単位**を指す
（意図的な同名であり、[ADR 0006](../adr/0006-cross-model-reasoning-contract.md) の「同名変数の非同一視」の例外として明示する）。
他の 7 概念はイベント層に対応物を持たず、#275 で新しく定義する。

0 と未指定は常に区別する。0 は「変化なし」、未指定は「その assumption を置いていない」である。

---

## 3. capability matrix

`representable` / `partial` / `—`（= `not_representable`）。
`**P**` は Phase 3 の主候補（`adoption = :primary`）、`(s)` は補助候補（`:supporting`）。

| モデル | F1 低成長+高金利 | F2 財政再建 | F3 金融抑圧 | F4 高成長/生産性 | F5 JGB funding-cost |
|---|---|---|---|---|---|
| Ramsey | — | — | — | — | — |
| RBC | — | — | — | representable (s) | — |
| Solow | — | — | — | representable **P** | — |
| IS-LM | — | partial (s) | — | — | — |
| AD-AS | — | partial (s) | — | partial (s) | — |
| New Keynesian | partial (s) | — | partial **P** | — | — |
| VAR | — | — | — | — | — |
| Mundell-Fleming | — | partial (s) | — | — | — |
| Keen | partial (s) | — | — | partial (s) | partial (s) |
| SIM (SFC) | — | representable **P** | — | — | — |
| CCC | partial **P** | — | partial | — | partial **P** |

判定規則（[`JapanFiscalModelMapping`](../../src/scenarios/japan_fiscal_capability.jl) のコンストラクタが強制する）。

- `:representable` … family の `required_concepts` を**すべて**別々の入力として受け取り、かつ `required_outputs` を**すべて**内生的に返す。
- `:partial` … `required_concepts` の一部を受け取るが上の条件を満たさない（受け取れない概念があるか、必要な出力を返さない）。
- `:not_representable` … `required_concepts` を 1 つも受け取れない。

宣言値と導出値の不一致は registry 登録時に例外で落ちる。「表現できるつもり」で書いた行が通らない。

### 3.1 VAR を全 family で `not_representable` とする理由

`VARModel` は係数手入力・ラグ 1 の簡易 VAR であり、どのショックがどの経済概念に対応するかを与える構造識別の機構を持たない。
任意の変数集合を置けるため形式的には何でも表現できるように見えるが、係数の供給元も識別の根拠も DME に無い（`G-10`）。
能力 metadata の原則「推測で過大申告しない」に従い、全 family で `not_representable` と判定する。

---

## 4. scenario family ごとの判定

### 4.1 F1 低成長 + 高金利（`:low_growth_high_rates`）

| 項目 | 内容 |
|---|---|
| required concepts | `:growth_path` / `:policy_rate` / `:long_rate_funding_condition` |
| optional concepts | `:inflation` / `:productivity_growth` |
| required outputs | `:output` / `:private_borrowing_cost` |
| unsupported outputs | `:government_debt_stock` / `:government_balance` |

**分解規則**: 政策金利・長期金利・成長を 1 つの入力へ縮約しない。3 概念は別々の Scenario Assumption として保持し、
モデルが受け取れない概念は近い入力へ寄せずに unsupported として返す。

**禁止代理**。

- IS-LM / AD-AS のマネーサプライ `M` の減少を「高金利 assumption」として用いない。金利と産出が同一入力の同時結果になる。
- CCC の `ext_demand_s2` / `ext_demand_s3`（本モデル外の半導体・装置需要）を GDP 成長率パスの代理に用いない（`G-12`）。
- Mundell-Fleming の `r_star`（世界利子率）を日本の長期金利の代理に用いない（`G-08`）。
- New Keynesian の産出ギャップ `x` の低下を「低成長」として提示しない。ギャップは潜在産出からの乖離であり成長率ではない。

**採用**。

| モデル | 判定 | 受け取る概念 | モデル入力 | 主張水準 |
|---|---|---|---|---|
| CCC **P** | partial | `:policy_rate` / `:long_rate_funding_condition` | `policy_rate`（外生パス, %, 四半期）／ `spread_shock_ex`（外生パス, bp, 四半期） | `direction_and_relative_timing` |
| New Keynesian (s) | partial | `:policy_rate` / `:inflation` | `i`（`:monetary` ショック, %pt 乖離）／ `π_star`（パラメータ） | `direction_and_relative_timing` |
| Keen (s) | partial | `:long_rate_funding_condition` | `r`（パラメータ, 年率実質, 恒久ステップのみ） | `direction_only` |

CCC が主候補なのは、**政策金利と長期金利を別々のモデル変数へ入れられる唯一のモデル**だからである
（`policy_rate` と `spread_shock_ex`。[ADR 0019](../adr/0019-long-rate-funding-shock-contract.md) 決定 6 の
`allowed_target_concepts` により型レベルで分離が保証される）。ただしこれは期間構造ではなく「短期金利 + 加算スプレッド」であり、
イールドカーブの形状変化は表現しない（`G-06`）。

### 4.2 F2 財政再建（`:fiscal_consolidation`）

| 項目 | 内容 |
|---|---|
| required concepts | `:government_spending` / `:tax` |
| optional concepts | `:primary_balance` / `:growth_path` / `:policy_rate` / `:inflation` |
| required outputs | `:output` / `:government_balance` |
| unsupported outputs | `:government_debt_stock` |

**分解規則**: プライマリーバランス assumption はどのモデルでも直接の入力ではない。
`:primary_balance` は `(:government_spending, :tax)` へ変換したうえで、変換式と「同じ PB を与える組が無数にある」ことを記録する（`G-07`）。
変換は**閉じ変数を 1 本に固定**して行い、固定した事実と代替案の感応度を artifact に残す。

**禁止代理**。

- Solow の貯蓄率 `s` を財政再建の代理に用いない。`s` は民間貯蓄率であり公的貯蓄ではない（`G-13`）。
- New Keynesian の `:demand` ショックを財政緊縮の代理に用いない。税・支出・債務のいずれの意味も持たず、財政乗数として解釈できない。
- CCC のモデル外需要の低下を財政緊縮の代理に用いない（`G-12`）。
- Keen の投資関数パラメータ `κ0` の引き下げを財政緊縮の代理に用いない。

**採用**。

| モデル | 判定 | 受け取る概念 | モデル入力 | 主張水準 |
|---|---|---|---|---|
| SIM (SFC) **P** | representable | `:government_spending` / `:tax` / `:primary_balance` | `G`（外生系列）／ `θ`（税率, 外生系列）／ PB は `θ` を閉じ変数として逆算 | `direction_and_relative_timing` |
| IS-LM (s) | partial | 同上 | `G` / `T`（いずれも静学パラメータ, 定額税） | `direction_only` |
| AD-AS (s) | partial | 同上 | `G` / `T`（+ 物価 `P` の内生応答） | `direction_only` |
| Mundell-Fleming (s) | partial | `:government_spending` / `:tax` | `G` / `T` | `direction_only` |

SIM だけが `representable` なのは、**税収 `T = θ·Y` が内生であるため財政収支がモデルの出力になる**唯一のモデルだからである。
IS-LM / AD-AS / Mundell-Fleming では `T` が定額税の入力であり、`T − G` は入力の差にすぎない。

Mundell-Fleming の「財政政策は無効」という結果は、変動相場・完全資本移動・小国という**モデル構造の帰結**であって、
日本についての実証的発見ではない（`G-08`）。国債が国内で消化され中央銀行が大量保有する日本の状況と、この仮定は整合しない。

### 4.3 F3 金融抑圧（`:financial_repression`）

| 項目 | 内容 |
|---|---|
| required concepts | `:policy_rate` / `:inflation` / `:cb_jgb_absorption` |
| optional concepts | `:long_rate_funding_condition` / `:growth_path` |
| required outputs | `:nominal_rate` / `:inflation` / `:real_rate` |
| unsupported outputs | `:government_debt_stock` / `:government_balance` / `:money_stock` |

**分解規則**: 金融抑圧を単一の政策金利ショックへ縮約しない。名目政策金利・インフレ・中央銀行の JGB 吸収を
**独立な 3 つの Scenario Assumption** として保持し、受け取れない概念を unsupported として返す。
`:cb_jgb_absorption` は**すべてのモデルで受け取れない**（`G-04`）。

**禁止代理**。

- AD-AS のマネーサプライ `M` 増加を「政策金利低位維持 + インフレ上昇」の合成入力として用いない。
  2 概念が単一入力の同時結果になり、分解規則に反する（`G-05`）。期待物価 `P_e` は外生パラメータだが物価の「水準」であって上昇「率」ではない。
  この理由により AD-AS は `not_representable` とする。
- CCC の `price_s1`（S1 部門の産出価格）を一般物価・インフレの代理に用いない（`G-11`）。
- 中央銀行の JGB 吸収を政策金利の追加的な引き下げへ振り替えない（`G-04`）。
- Keen の実質貸出金利 `r` の低下を「政策金利の低位維持」として提示しない。`r` は民間の実質借入金利である。

**採用**。

| モデル | 判定 | 受け取る概念 | モデル入力 | 主張水準 |
|---|---|---|---|---|
| New Keynesian **P** | partial | `:policy_rate` / `:inflation` | `i`（`:monetary` ショック, `ρ_m` で持続性）／ `π_star`（インフレ目標） | `direction_and_relative_timing` |

New Keynesian だけが、**名目政策金利とインフレを独立な入力として受け取れる**（`G-05`）。
「名目金利を据え置いたままインフレだけ上げる」には `π_star` の引き上げと負の金融政策ショックの**組み合わせ**が要る
（`π_star` の変更は定常状態の名目金利 `i* = r_n + π_star` も動かすため）。この組み合わせ規則自体を assumption として記録する。

実質金利は `i − E[π]` として導出でき、既存の `nk_expected_inflation_path` と
[real-rate model artifact](../examples/real_rate_model_artifact.md) の機構をそのまま再利用できる。

CCC は `policy_rate` を受け取れるため `partial` だが、一般物価を持たず（`G-11`）実質金利を返さないため、Phase 3 では採用しない。

### 4.4 F4 高成長 / 生産性ショック（`:high_growth_productivity`）

| 項目 | 内容 |
|---|---|
| required concepts | `:productivity_growth` |
| optional concepts | `:growth_path` / `:policy_rate` / `:inflation` |
| required outputs | `:output` / `:capital_stock` |
| unsupported outputs | `:government_debt_stock` / `:government_balance` |

**分解規則**: 生産性ショックと GDP 成長パス assumption を区別する。`:growth_path` を直接受け取るモデルは存在しないため、
成長仮定は必ず構造ドライバーへ変換し、変換の非一意性を記録する（`G-03`）。

**禁止代理**。

- New Keynesian の `:demand` ショックを生産性向上の代理に用いない。産出ギャップの一時的拡大であり潜在産出の上昇ではない。
- SIM の賃金率 `W` を労働生産性の代理に用いない。`W` は数値基準であり `N = Y/W` は会計上の恒等式である。
- CCC の `ai_exp` を日本の生産性成長の代理に用いない。米国 AI 設備投資期待の外生入力である（`G-12`）。
- Ramsey の資本分配率 `α` の変更を生産性ショックの代理に用いない。生産関数の形状パラメータであり技術水準ではない。

**採用**。

| モデル | 判定 | モデル入力 | 主張水準 |
|---|---|---|---|
| Solow **P** | representable | `g`（技術進歩率, 成長率パラメータ） | `direction_and_relative_timing` |
| RBC (s) | representable | `A`（TFP ショック, 対数水準乖離, `ρ` で平均回帰） | `direction_and_relative_timing` |
| AD-AS (s) | partial | `Y_n`（潜在産出**水準**。成長率からの変換が要る） | `direction_only` |
| Keen (s) | partial | `α`（労働生産性成長率, 年率） | `direction_only` |

`g`・`α` は成長「率」、`Y_n` は潜在産出「水準」であり、相互に自動変換しない。RBC の TFP ショックは `ρ < 1` で平均回帰するため、
持続的な成長regimeの変化ではない。

CCC は `not_representable` とする。baseline を成長率ゼロの定常状態と定義しており
（[ADR 0011](../adr/0011-capex-credit-cycle-dynamics-contract.md)）、`st_lprod_s` の変更は定常水準の移動であって成長率の変更ではない。

### 4.5 F5 JGB funding-cost ショック（`:jgb_funding_cost`）

| 項目 | 内容 |
|---|---|
| required concepts | `:long_rate_funding_condition` |
| optional concepts | `:policy_rate` / `:inflation` |
| required outputs | `:private_borrowing_cost` / `:government_balance` |
| unsupported outputs | `:government_debt_stock` |

**分解規則**: JGB funding-cost ショックを **sovereign leg**（政府の調達コスト・利払費）と
**private pass-through leg**（民間の実効借入コスト）に分け、sovereign leg はどのモデルでも表現できないことを結果に明示する
（`G-01`・`G-14`）。`:government_balance` はどのモデルも返さない。

**#260 契約の日本再利用範囲**（#274 確認事項 3 への回答）。

| 要素 | 日本へ再利用できるか | 理由 |
|---|---|---|
| イベント型 `:LongRateFundingShock` | ○ | モデル非依存。`geography` フィールドで日本を指定できる |
| `FundingShockComponents`（生データ分解） | ○ | 長期名目金利・長期実質金利・inflation compensation・secured funding スプレッドという分解は日本にも成立する |
| `FundingShockPassThrough`（versioned 係数） | △ | 構造は再利用できるが、既定係数 `1.0` は米国についても較正されていない。日本適用時は感応度併記を必須とする |
| `:LongRateFundingShock` → `spread_shock_ex` の写像 | × | 企業の実効借入コストへの写像であり、政府の調達コストではない（`G-14`） |
| CCC の部門構成 S1–S5・逆較正 48 target | × | 米国 AI・半導体 CAPEX 循環・米国 NIPA 由来（`G-02`） |
| financial-stress 観測系列（CCC OAS・SOFR・TGCR・IORB 等 8 系列） | × | すべて米国系列。日本の対応系列（10年 JGB・TONA/GC レポ・日銀政策金利・JGB breakeven）は未実装（`G-15`） |

したがって Phase 3 では、`FundingShockComponents` を**観測から自動構成せず**、明示的 Scenario Assumption として与える。

**禁止代理**。

- `:LongRateFundingShock` → `spread_shock_ex` の写像を sovereign leg に用いない（`G-14`）。
- Mundell-Fleming の `r_star` を JGB 利回りの代理に用いない（`G-08`）。
- New Keynesian の `:monetary` ショックを長期金利ショックの代理に用いない。期間構造を持たない（`G-06`）。
- IS-LM / AD-AS の `r` を JGB 利回りとして解釈しない。単一の内生金利であり、政策金利とも長期金利とも同定されない。
- `decomposition_residual_bps` を term premium と呼ばない（ADR 0019 決定 4）。

**採用**。

| モデル | 判定 | 受け取る概念 | モデル入力 | 主張水準 |
|---|---|---|---|---|
| CCC **P** | partial | `:long_rate_funding_condition` / `:policy_rate` | `spread_shock_ex`（外生パス, bp, 四半期）／ `policy_rate`（外生パス, %, 四半期） | `direction_and_relative_timing` |
| Keen (s) | partial | `:long_rate_funding_condition` | `r`（パラメータ, 年率実質, 恒久ステップのみ） | `direction_only` |

---

## 5. model-specific mapping requirements（#276 への要件）

### 5.1 すべての mapping に共通

1. **unsupported を silent ignore しない**。`japan_fiscal_unsupported_concepts(family, model)` と
   `japan_fiscal_unsupported_outputs(family, model)` が返す概念・出力は、結果 artifact に明示的に列挙する。
2. **baseline と scenario の同一性を検証する**。モデル・パラメータ・初期状態・ホライズンの一致を実行前に確認する。
3. **claim_level を artifact に持たせる**。`:magnitude` を名乗れるセルは存在しないため、
   量を日本の値として提示する出力経路を作らない。
4. **禁止代理を実装に持ち込まない**。`forbidden_proxies` に列挙した変換を行うコードを書かない。
5. **単位換算式を記録する**。`JapanFiscalInputMapping.conversion` に書いた換算を artifact の provenance に残す。

### 5.2 モデル別の固有要件

| モデル | 要件 |
|---|---|
| SIM (SFC) | `impulse_response` は `G` か `θ` の一方しか動かせない。歳出削減と増税の同時実施には期別系列（`Gseq`・`θseq`）を与える薄い adapter が要る。`θ ∉ (0,1)` は `ArgumentError` で拒否される |
| New Keynesian | `PersistenceSpec` の時間形状 → `ρ_m` の変換規則を明示する。`ρ_m → 1` で MSV 解が不安定化するため上限を設ける。`φ_π > 1` を検査する |
| Solow | `n < 0`（人口減少）は定常条件 `δ + n + g + n·g > 0` を満たす範囲でのみ許す。効率労働単位あたり量と水準量の換算式を記録する |
| RBC | 出力は `A* = 1` 正規化のもとでの定常状態比として解釈する。`ρ` による平均回帰を明示する |
| Keen | 金利・生産性は期別パスを取れない。2 モデルインスタンスの比較（恒久ステップ）としてのみ実行する（`G-09`）。双安定性のため初期値と当該パラメータの ±50% 感応度を必ず併記する |
| CCC | `FundingShockPassThrough` の係数感応度（±50%）を必須とする。`policy_rate` と `spread_shock_ex` を同時に動かす場合は反実仮想による寄与分解を併記する。`ai_exp` は baseline 値から動かさない |
| IS-LM / AD-AS / Mundell-Fleming | 静学 1 点解であり時間経路を返さない。peak / onset / duration を出力に含めない |

### 5.3 primary balance の変換規則

`:primary_balance` を受け取る 3 セル（SIM・IS-LM・AD-AS。Mundell-Fleming は受け取らない）はいずれも
`:requires_structural_conversion` である。

- 閉じ変数を 1 本に固定する（SIM は既定 `θ`、IS-LM / AD-AS は既定 `T`）。
- SIM では `Y` も同時に動くため逆算は反復を要する。
- 固定した閉じ変数と、もう一方を閉じ変数にした場合の感応度を artifact に記録する（`G-07`）。

---

## 6. unsupported / gap register

Phase 3 で解消せず限界として保持する構造的ギャップ。`hold_as_limitation` は #273 の non-goal に触れるため
Phase 3 では解消しない。`followup_issue` は後続 Issue の候補、`out_of_scope` は DME の責務外。

| ID | 内容 | 影響 family | 解決先 |
|---|---|---|---|
| `G-01` | 利付き政府債務ストックを持つモデルが存在しない | 全 family | `hold_as_limitation` |
| `G-02` | 日本較正済みのモデルが存在しない | 全 family | `followup_issue` |
| `G-03` | GDP 成長率パスを外生入力として受け取るモデルが存在しない | F1・F4 | `hold_as_limitation` |
| `G-04` | 中央銀行のバランスシート・JGB 吸収を持つモデルが存在しない | F3・F5 | `hold_as_limitation` |
| `G-05` | インフレを政策金利と独立な assumption として受け取れるのは New Keynesian のみ | F3 | `hold_as_limitation` |
| `G-06` | 期間構造（短期金利と長期金利の同時保持）を持つモデルが存在しない | F1・F5 | `hold_as_limitation` |
| `G-07` | プライマリーバランスを直接の入力として受け取るモデルが存在しない | F2 | `hold_as_limitation` |
| `G-08` | 開放経済かつ財政を持つモデルは Mundell-Fleming のみで、その構造が財政乗数をゼロにする | F2・F5 | `hold_as_limitation` |
| `G-09` | Keen の貸出金利 `r` は時間変化しないスカラーパラメータ | F1・F3・F5 | `hold_as_limitation` |
| `G-10` | VAR は係数手入力・ラグ 1 のみで、推定機能を持たない | 全 family | `out_of_scope` |
| `G-11` | CCC の `price_s1` は S1 部門の産出価格であり一般物価ではない | F3 | `hold_as_limitation` |
| `G-12` | CCC の `ext_demand_s2` / `ext_demand_s3` はモデル外需要であり GDP 成長パスではない | F1・F2・F4 | `hold_as_limitation` |
| `G-13` | Solow の貯蓄率 `s` は民間貯蓄率であり財政再建の代理ではない | F2 | `hold_as_limitation` |
| `G-14` | `:LongRateFundingShock` → `spread_shock_ex` は企業の実効借入コストへの写像であり、政府の調達コストではない | F5 | `hold_as_limitation` |
| `G-15` | financial-stress 観測系列（#260 Part B）は米国系列のみ | F5 | `followup_issue` |

各 gap の詳細（description・consequence・影響モデル）は `japan_fiscal_gap("G-01")` で引ける。

---

## 7. model-implied result として言えること・言えないこと

### 7.1 言えること

- 各 assumption を**別々の入力**として与えたときの、モデル出力の**方向**（符号）。
- `claim_level = :direction_and_relative_timing` のセルでは、加えて **peak / onset / duration の相対的な順序と時間形状**。
- 複数の入力を同時に与えたときの、反実仮想による**寄与分解**（CCC）。
- 会計恒等式が全期で成立すること（SIM）。
- 事前的実質金利 `i − E[π]` の経路（New Keynesian）。

### 7.2 言えないこと

- **日本の量**。日本較正済みモデルが無いため、変化幅・水準を日本の値として提示しない（`G-02`）。
- **債務持続可能性**。債務残高/GDP・利払費・`r − g` 動学をどのモデルも返さない（`G-01`）。
- **確率**。Keen の双安定系は決定論的軌道であり、危機の発生確率でも発生時期の予測でもない。
- **予測**。model-implied counterfactual を forecast・observed outcome として提示しない。
- **投資判断**。売買推奨・信用判断へ変換しない。
- **中央銀行の量的政策の効果**（`G-04`）。

---

## 8. 後続 Issue への引き継ぎ

| Issue | 本契約から引き継ぐもの |
|---|---|
| #275（catalog / assumption schema） | `JAPAN_FISCAL_SCENARIO_FAMILIES`（安定 ID）・`JAPAN_FISCAL_ASSUMPTION_CONCEPTS`（単位・0/未指定の区別）・family ごとの `required_concepts` / `optional_concepts` / `guardrails`・`JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION`（scenario artifact の model capability decision version）・FRE context contract |
| #276（adapter / runner / artifact） | 55 セルの `inputs`（変数・単位・時間軸・換算）・`adoption`（実装対象の絞り込み）・`claim_level`・`baseline_requirements`・`parameterization_requirements`・§5 の mapping requirements |
| #277（E2E / consumer fixture） | `representable` / `partial` / `not_representable` の代表セル・`forbidden_proxies`（negative fixture の根拠）・`japan_fiscal_capability_matrix()`（consumer が読む機械可読 matrix）・§7 の言えること/言えないこと |

`japan_fiscal_capability_matrix()` は契約全体を 1 つの `Dict{String,Any}` として返す。
Market Analyzer は Julia 内部型を import せず、この matrix と #276 の result artifact のみを consume する。

---

## 9. 公開 API

| 関数・定数 | 役割 |
|---|---|
| `JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION` | 契約 version（#275 の provenance が参照する決定 version） |
| `japan_fiscal_scenario_families()` | family 一覧 |
| `japan_fiscal_family_spec(family)` | family 仕様（必要概念・分解規則・禁止代理） |
| `japan_fiscal_assumption_concept(concept)` | assumption 概念の定義（単位・基準・イベント層対応） |
| `japan_fiscal_model_mappings(; family, model, representability, adoption)` | capability matrix の絞り込み |
| `japan_fiscal_model_mapping(family, model)` | 1 セルの判定 |
| `japan_fiscal_representability(family, model)` | 1 セルの representability |
| `japan_fiscal_accepted_concepts(mapping)` | 受け取る概念 |
| `japan_fiscal_unsupported_concepts(family, model)` | 受け取れない必要概念 |
| `japan_fiscal_unsupported_outputs(family, model)` | 返さない必要出力 |
| `japan_fiscal_implementation_candidates(family)` | Phase 3 の実装候補（`:primary` が先頭） |
| `japan_fiscal_gaps(; family, model)` / `japan_fiscal_gap(id)` | gap register |
| `japan_fiscal_magnitude_source_allowed(source)` | `magnitude_source` の可否 |
| `japan_fiscal_capability_matrix()` | 契約全体の機械可読 export |
| `to_dict` / `to_json` | 各レコード型の JSON 化 |

```julia
using DME

japan_fiscal_implementation_candidates(:fiscal_consolidation)
# => [:sim, :islm, :adas, :mundell_fleming]

japan_fiscal_unsupported_concepts(:financial_repression, :new_keynesian)
# => [:cb_jgb_absorption]

japan_fiscal_magnitude_source_allowed(:external_belief)
# => false

m = japan_fiscal_model_mapping(:jgb_funding_cost, :capex_credit_cycle)
m.representability   # :partial
m.claim_level        # :direction_and_relative_timing
m.cannot_state       # 政府の調達コスト・利払費 …
```
