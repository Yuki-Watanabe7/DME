# Japan Fiscal Scenario Lab — claim-level / coverage 契約（downstream 伝播）

[Issue #274](https://github.com/Yuki-Watanabe7/DME/issues/274) の capability audit で確定した
「このモデルでは何が言えて何が言えないか」を、scenario schema（#275）・result artifact（#276）・
E2E / consumer fixture（#277）・Market Analyzer consumer へ **lossless に伝播する** ための契約。
[Issue #285](https://github.com/Yuki-Watanabe7/DME/issues/285) の成果物。

> 関連: [ADR 0021](../adr/0021-japan-fiscal-claim-level-contract.md)（決定記録）・
> [Japan Fiscal Scenario Lab capability / mapping 契約](japan_fiscal_scenario_capability.md)（#274）・
> [ADR 0020](../adr/0020-japan-fiscal-scenario-capability-contract.md)・
> [LLM出力の安全性・免責・禁止表現ルール](../llm_safety.md)

実装ファイル: [`src/scenarios/japan_fiscal_claim_contract.jl`](../../src/scenarios/japan_fiscal_claim_contract.jl)。
契約 version: `JAPAN_FISCAL_CLAIM_CONTRACT_VERSION = "japan-fiscal-claim-contract/1.0.0"`。

---

## 1. この契約が解く問題

#274 の registry には `claim_level`・未対応概念・未対応出力・`cannot_state` がすでにある。
しかし #275 と Market Analyzer 側の既存 Issue はこの監査より前に作られており、
**limitation が artifact と UI へ届く保証が acceptance criteria に入っていない**。

放置すると次が起こる。

- 「JGB funding-cost ショック」という family 名だけが表示され、sovereign leg が
  覆われていないことが読み手に伝わらない。
- 較正されていないモデルの数値が「日本の GDP が X% 変化する」として読まれる。
- 静学モデル（IS-LM・AD-AS・Mundell-Fleming）の 1 点解に、peak / onset / duration の
  時間軸 UI が当てられる。
- 未対応の assumption（例: 中央銀行の JGB 吸収）が silent ignore され、全概念が効いたと解釈される。

本契約は、これらを**文書の注意書きではなく型・検証関数・テスト**で止める。

### 1.1 Phase 3 の位置づけ

Phase 3 は **Japan-calibrated quantitative forecast lab ではない**。
日本較正済みモデルが存在しない（gap `G-02`）ため、Phase 3 が提供するのは
「明示的な assumption を置いたときに、既存モデルの構造が示す方向と相対的な時間形状」である。

| 指標 | 現在の値 |
|---|---|
| `claim_level = :magnitude` の (family, model) セル | **0 / 55** |
| `calibration_geography = :jp` のセル | **0 / 55** |
| `family_complete = true` のセル | **0 / 55** |
| `:unsupported` の因果チャネル | **11 / 25** |

これらは `japan_fiscal_downstream_contract()["invariants"]` から機械的に読める。

---

## 2. claim-level 契約

`claim_level` は artifact が**主張してよい診断**と、保持する数値系列に付けなければならない
**意味づけ**（`numeric_semantics`）を決める。上位段階は下位段階の診断を包含する（単調性を登録時に検査する）。

| claim_level | 主張してよい診断 | numeric_semantics | 該当セル数 |
|---|---|---|---|
| `none` | （なし） | `none` | 41 |
| `direction_only` | `direction` / `sign_of_delta` | `model_unit_relative` | 7 |
| `direction_and_relative_timing` | `direction` / `sign_of_delta` / `relative_ordering` / `peak` / `trough` / `onset` / `duration` / `recovery` / `contribution_decomposition` / `relative_delta` | `normalized_deviation` | 7 |
| `magnitude` | 上記すべて + `absolute_delta` / `level_path` | `japan_magnitude` | **0** |

### 2.1 numeric_semantics

| 値 | 意味 |
|---|---|
| `:none` | 数値系列を保持しない（実行しない） |
| `:model_unit_relative` | モデル単位の相対値。baseline との差の**符号**のみが意味を持つ |
| `:normalized_deviation` | baseline で正規化した偏差。時間形状の比較に使える |
| `:japan_magnitude` | 日本の量として提示してよい。`calibration_geography = :jp` のときのみ |

数値系列そのものは deterministic なモデル出力として artifact に保持してよい。
禁じているのは**その数値に与えるラベル**である。`numeric_semantics` を数値の近くに必ず出す。

### 2.2 claim_level ごとの consumer 規則

- `direction_only` … peak / onset / duration / recovery を要求・表示しない。数値の大きさを比較軸にしない。
  複数シナリオの「どちらが早いか」を表示しない。静学モデルには時間経路が存在せず、
  Keen の軌道は双安定性により時間形状が初期値とパラメータに過敏である。
- `direction_and_relative_timing` … 時点は「ショック後 n 期」として表示し、暦日・暦四半期の予測として
  表示しない。相対差を「日本の GDP が X% 変化する」と読み替えない。絶対差・水準経路を主要な結論にしない。
- `magnitude` … 日本較正の根拠（較正 Issue・データ vintage）を同時に表示する。それでも forecast・
  probability としては表示しない。

### 2.3 禁止する主張

`japan_fiscal_forbidden_claims()` が返す 8 種。artifact・API・UI のいずれも生成しない。

| 種類 | 理由 |
|---|---|
| `:forecast` | model-implied counterfactual は予測ではない |
| `:probability` | 決定論的シミュレーションであり確率分布を持たない |
| `:crisis_probability` | Keen の双安定系は決定論的軌道であり危機確率ではない |
| `:default_probability` | デフォルトを内生化したモデルが無い |
| `:japan_realized_magnitude` | 日本較正済みモデルが存在しない（`G-02`） |
| `:observed_outcome` | observed / assumed / model_implied を分離する |
| `:investment_recommendation` | 売買・信用判断へ変換しない |
| `:debt_sustainability_judgment` | 利付き政府債務ストックが無く判断の根拠が無い（`G-01`） |

---

## 3. coverage 契約

representability（表現可能性）と coverage（被覆）を**別々に**追跡する。
`japan_fiscal_coverage(family, model)` が返すレコードを #276 の result artifact がそのまま保持する。

| フィールド群 | 内容 |
|---|---|
| identity | `capability_contract_version` / `claim_contract_version` / `family` / `model` |
| 判定 | `representability` / `adoption` / `claim_level` / `numeric_semantics` |
| 診断の可否 | `permitted_diagnostics` / `forbidden_diagnostics` |
| 概念の被覆 | `required_concepts` / `accepted_concepts` / `unsupported_concepts` |
| 出力の被覆 | `required_outputs` / `produced_outputs` / `unsupported_outputs` |
| チャネルの被覆 | `covered_channels` / `uncovered_channels` / `family_complete` |
| 較正 | `calibration_basis` / `calibration_geography` |
| 限界 | `cannot_state` / `major_caveats` / `gap_ids` |

すべて #274 の registry から**導出**する。手書きの二重 registry を持たないため、
#274 を更新すれば coverage も追随する。

### 3.1 `family_complete` は全セルで false

`family_complete` は「required concepts をすべて受け取り、required outputs をすべて返し、
family の全因果チャネルを覆う」ときだけ真になる。現在の 55 セルではすべて false である。

これは未実装の placeholder ではなく #274 の監査結果そのものであり、
`family_complete = false` の結果を family 完全な結果として提示しないことが consumer 規則になる。

---

## 4. 因果チャネルの被覆

family 名（例「JGB funding-cost ショック」）だけを見ると全チャネルをモデル化したように読める。
そこで family と同じ粒度で**因果チャネル**を宣言し、何が覆われていないかを機械可読にする。

#### F1 低成長+高金利

| チャネル | 状況 | 扱うモデル | 覆われていない内容 |
|---|---|---|---|
| 成長率 assumption の波及 (`growth_assumption_transmission`) | **unsupported** | — | GDP 成長率パスを外生入力として受け取るモデルが存在しない。主候補 CCC の baseline は成長率ゼロの定常状態と定義されており、成長regimeそのものを表現しない。 |
| 政策金利の波及 (`policy_rate_transmission`) | covered | `capex_credit_cycle` / `new_keynesian` | — |
| 長期金利・funding 条件の波及 (`long_rate_funding_transmission`) | covered | `capex_credit_cycle` / `keen` | — |
| 期間構造 (`term_structure`) | **unsupported** | — | 期間構造を持つモデルが存在しない。CCC は `policy_rate` と `spread_shock_ex` の 2 スロットを持つが、これは「短期金利 + 加算スプレッド」であり期間構造ではない。 |
| 政府債務動学 (`sovereign_debt_dynamics`) | **unsupported** | — | 利付き政府債務ストックを持つモデルが存在しない。債務残高/GDP・利払費・`r − g` 動学のいずれも返らない。 |

#### F2 財政再建

| チャネル | 状況 | 扱うモデル | 覆われていない内容 |
|---|---|---|---|
| 政府支出の乗数 (`government_spending_multiplier`) | covered | `sim` / `islm` / `adas` / `mundell_fleming` | — |
| 税の効果 (`taxation`) | covered | `sim` / `islm` / `adas` / `mundell_fleming` | — |
| プライマリーバランスの経路 (`primary_balance_path`) | partially_covered | `sim` | SIM のみが税収 `T = θ·Y` を内生化し財政収支を出力として返す。IS-LM・AD-AS・Mundell-Fleming では `T` が定額税の入力であり `T − G` は入力の差にすぎない。PB を assumption として与える場合は閉じ変数を固定した逆算が要り、組は一意でない。 |
| 債務残高と利払費 (`debt_interest_burden`) | **unsupported** | — | 利付き政府債務ストックを持つモデルが存在しない。SIM の `H` は無利子の政府貨幣であり国債ではない。 |
| 対外調整（為替・純輸出） (`external_adjustment`) | partially_covered | `mundell_fleming` | 開放経済かつ財政を持つモデルは Mundell-Fleming のみで、変動相場・完全資本移動・小国という構造仮定の帰結として財政乗数が恒等的にゼロになる。これはモデル構造の帰結であり日本についての実証的発見ではない。 |

#### F3 金融抑圧

| チャネル | 状況 | 扱うモデル | 覆われていない内容 |
|---|---|---|---|
| 名目政策金利の低位維持 (`policy_rate_path`) | covered | `new_keynesian` | — |
| インフレの上昇 (`inflation_path`) | covered | `new_keynesian` | — |
| 実質金利の負化 (`real_rate_derivation`) | covered | `new_keynesian` | — |
| 中央銀行の JGB 吸収 (`cb_jgb_absorption`) | **unsupported** | — | 中央銀行のバランスシートを持つモデルが存在しない。IS-LM 系の `M` は名目マネーサプライであり資産構成（国債保有残高）ではない。この概念はすべてのモデルで受け取れない。 |
| 政府債務の実質価値圧縮 (`debt_real_value_erosion`) | **unsupported** | — | 利付き政府債務ストックを持つモデルが存在しないため、圧縮額・移転額のいずれも算出できない。 |

#### F4 高成長/生産性

| チャネル | 状況 | 扱うモデル | 覆われていない内容 |
|---|---|---|---|
| 生産性から産出へ (`productivity_to_output`) | covered | `solow` / `rbc` | — |
| 資本蓄積 (`capital_accumulation`) | covered | `solow` / `rbc` | — |
| 成長regimeの変化 (`growth_regime_change`) | partially_covered | `solow` / `keen` | 成長率パラメータを持つのは Solow の `g` と Keen の `α` のみ。RBC の TFP ショックは `ρ < 1` で平均回帰し、AD-AS の `Y_n` は潜在産出の『水準』であって率ではない。CCC は baseline が成長率ゼロの定常状態であり成長regimeを表現しない。 |
| 物価水準の応答 (`price_level_response`) | partially_covered | `adas` | AD-AS のみが物価を内生化するが静学 1 点解であり、物価『水準』の比較のみでインフレ『率』の経路を返さない。 |
| 債務比率の分母効果 (`debt_denominator_effect`) | **unsupported** | — | 政府部門・政府債務ストックを持つ成長モデルが存在しない。Solow・RBC・Keen のいずれも政府を持たない。 |

#### F5 JGB funding-cost

| チャネル | 状況 | 扱うモデル | 覆われていない内容 |
|---|---|---|---|
| 民間へのパススルー (`private_pass_through`) | covered | `capex_credit_cycle` / `keen` | — |
| 政府の調達コスト (`sovereign_funding_cost`) | **unsupported** | — | `:LongRateFundingShock` → `spread_shock_ex` の写像は企業の実効借入コストへの加算であり、政府の調達コストではない。政府部門を持つモデルが金利を持たず、金利を持つモデルが政府を持たない。 |
| 利払費から財政収支へ (`interest_burden_to_fiscal_balance`) | **unsupported** | — | 利付き政府債務ストックを持つモデルが存在しないため、利払費が定義されない。 |
| イールドカーブの形状変化 (`term_structure_shape`) | **unsupported** | — | 期間構造を持つモデルが存在しない。長期金利は単一の加算スプレッドとしてのみ表現される。 |
| 日本の観測系列からの構成 (`jp_observation_supply`) | **unsupported** | — | financial-stress 観測系列は米国 8 系列のみで、日本の対応系列は未実装。`FundingShockComponents` は観測からではなく明示的 Scenario Assumption として与えるしかない。 |

---

## 5. downstream handoff requirements

### #275 scenario schema

| ID | 要件 | 検証 |
|---|---|---|
| `H-01` | scenario catalog は family ごとの `required_concepts` / `optional_concepts` / `guardrails` を #274 の registry から引き、独自に再定義しない。 | catalog の値が `japan_fiscal_family_spec(family)` と一致することをテストする。 |
| `H-02` | scenario artifact の identity に `JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION` と `JAPAN_FISCAL_CLAIM_CONTRACT_VERSION` の両方を含める。 | artifact の canonical serialization に両 version が含まれることをテストする。 |
| `H-03` | assumption の magnitude 未指定と 0 を別の状態として保持する（欠測を 0 へ丸めない）。 | 未指定の assumption を含む fixture で、serialization 後も欠測が保たれることをテストする。 |
| `H-04` | assumption に `magnitude_source` を必須とし、`japan_fiscal_magnitude_source_allowed` が `false` を返す値を拒否する。 | `magnitude_source = :external_belief` の assumption が validation error になることをテストする。 |
| `H-05` | FRE context を Scenario Assumption と別構造で保持し、context のフィールドを magnitude 導出に用いない。 | FRE context だけを変えた 2 つの scenario が同一の applied model input を生むことをテストする。 |

### #276 result artifact

| ID | 要件 | 検証 |
|---|---|---|
| `H-06` | result artifact は `japan_fiscal_coverage(family, model)` の全フィールドを保持する。 | artifact の dict が `to_dict(japan_fiscal_coverage(...))` の全キーを含むことをテストする。 |
| `H-07` | artifact 生成前に `japan_fiscal_validate_claims` を実行し、違反があれば artifact を生成しない。 | `direction_only` の mapping で peak を要求した場合に違反が返ることをテストする。 |
| `H-08` | 保持する数値系列に `numeric_semantics` を付け、`:japan_magnitude` は `calibration_geography = :jp` のときのみ用いる。 | 全 55 セルの coverage が `numeric_semantics != :japan_magnitude` であることをテストする。 |
| `H-09` | `unsupported_concepts` / `unsupported_outputs` / `uncovered_channels` を空配列へ落とさない（silent ignore の禁止）。 | 未対応概念を開示しない artifact が `:unsupported_concept_hidden` 違反になることをテストする。 |
| `H-10` | observed（FRE context）/ assumed（Scenario Assumption）/ model_implied（結果）の 3 分類をフィールドで区別する。 | artifact schema で 3 分類が別キーにあることをテストする。 |
| `H-11` | F5 では sovereign leg と private pass-through leg を別フィールドで保持し、sovereign leg が `:unsupported` であることを明示する。 | F5 の artifact に sovereign leg の status が含まれ `:unsupported` であることをテストする。 |
| `H-12` | `family_complete` を artifact に持たせ、`false` のときは family 名だけの要約を生成しない。 | 全 55 セルで `family_complete == false` であることをテストし、artifact がこの値を保持することを検証する。 |

### #277 E2E / fixture

| ID | 要件 | 検証 |
|---|---|---|
| `H-13` | 現在の 55 セルに `claim_level = :magnitude` が 0 件であることを E2E でも検査する。 | E2E fixture の実行結果に `:magnitude` の coverage が現れないことをテストする。 |
| `H-14` | serialization round-trip で `claim_level` と unsupported フィールドが消えないことを検査する。 | artifact を JSON 化して読み戻し、`claim_level` / `unsupported_concepts` / `unsupported_outputs` / `uncovered_channels` が保持されることをテストする。 |
| `H-15` | `direction_only` の mapping に peak / onset / duration を要求する negative fixture を置き、違反が返ることを検査する。 | `japan_fiscal_validate_claims` が `:diagnostic_not_permitted` を返すことをテストする。 |
| `H-16` | consumer fixture に `japan_fiscal_downstream_contract()` を含め、Julia 内部型なしで decode できる形で公開する。 | JSON round-trip で全キーが読めることをテストする。 |

### consumer（Market Analyzer #283 / #285 / #286）

| ID | 要件 | 検証 |
|---|---|---|
| `H-17` | `claim_level` を artifact から読み、UI 側で昇格させない。`direction_only` の結果に時間軸チャート・peak / onset / duration を表示しない。 | consumer fixture の `direction_only` ケースで時間軸の表示要素が無いことを検証する。 |
| `H-18` | `unsupported_concepts` / `uncovered_channels` を折りたたんで隠さず、family 名と同じ画面に表示する。 | consumer の情報設計レビューで、limitation が要約と同じ視野に入ることを確認する。 |
| `H-19` | 数値を日本の量として表示しない。`numeric_semantics` に従ったラベル（モデル単位の相対値・正規化偏差）を数値の近くに出す。 | consumer fixture の数値表示に `numeric_semantics` 由来のラベルが付くことを検証する。 |
| `H-20` | `family_complete = false` の結果を family 完全な結果として見せない。どのチャネルが覆われていないかを明示する。 | consumer fixture の各 family で未被覆チャネル名が表示されることを検証する。 |
| `H-21` | sovereign / private leg と、observed / assumed / model_implied を区別して表示する。 | consumer fixture で 2 種類の区別が別要素として現れることを検証する。 |
| `H-22` | `JAPAN_FISCAL_FORBIDDEN_CLAIM_KINDS` のいずれとしても表示しない（forecast・probability・危機確率・投資推奨・債務持続可能性の判断）。 | consumer の表示文言レビューと、`japan_fiscal_forbidden_claims()` の一覧との突き合わせを行う。 |

---

## 6. claim_level 昇格の version 規則

将来、日本較正が実現して `claim_level` を上げるときの唯一の規則
（`JAPAN_FISCAL_CLAIM_UPGRADE_RULE`）。

**満たすべき条件**（すべて）。

1. 対象 mapping の `calibration_basis` が `:japan_calibrated` へ変わっていること。日本データによる較正・
   推定が実装され、テストとデモで示されていること。自己申告では足りない（[ADR 0014](../adr/0014-digital-twin-naming-conditions.md) と同型）。
2. 較正の対象期間・データ vintage・推定手法・識別仮定が artifact から追跡できること。
3. `JapanFiscalModelMapping` のコンストラクタ検査（`claim_level = :magnitude` は
   `calibration_basis = :japan_calibrated` のときのみ）を緩めないこと。
4. 昇格後も `japan_fiscal_validate_claims` が禁止主張を拒否し続けること。

**同時に上げる version**。

- `JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION`（#274 の registry を変更するため）
- `JAPAN_FISCAL_CLAIM_CONTRACT_VERSION`（consumer が見る claim 意味論が変わるため）

**してはならないこと**。

- consumer が artifact の `claim_level` を読み替えて昇格させること。`claim_level` は
  artifact から**読む値**であり、推論する値ではない。
- `calibration_geography` が `:us` / `:none` のまま数値を日本の量として提示すること。
- 較正の一部（例: 1 部門のみ）を根拠に family 全体の `claim_level` を上げること。
- 契約 version を据え置いたまま `claim_level` を上げること。

---

## 7. 実行時の検証

`japan_fiscal_validate_claims` が、artifact や consumer が主張しようとしている内容を検査し、
違反を列挙する（空ベクトルなら適合）。#276 は artifact 生成前にこれを実行し、
違反があれば artifact を生成しない（`H-07`）。

| 違反コード | 検出する誤り |
|---|---|
| `:diagnostic_not_permitted` | `claim_level` が許さない診断を主張している |
| `:numeric_semantics_exceeds_claim` | 数値の意味づけが `claim_level` の上限を超えている |
| `:magnitude_without_japan_calibration` | 日本較正でないモデルの数値を日本の量として提示している |
| `:unsupported_concept_hidden` | 受け取れなかった assumption 概念を開示していない |
| `:unsupported_output_hidden` | 返せない出力概念を開示していない |
| `:forbidden_claim_kind` | forecast / probability / 投資推奨 等として提示している |
| `:family_presented_as_complete` | 一部チャネルのみの結果を family 完全として提示している |

```julia
using DME

# 静学モデル（claim_level = :direction_only）に時間形状を要求すると違反になる
japan_fiscal_validate_claims(:fiscal_consolidation, :islm;
    diagnostics = [:direction, :peak, :onset],
    disclosed_unsupported_concepts = Symbol[],
    disclosed_unsupported_outputs = [:government_balance])
# => 2 件の :diagnostic_not_permitted

# 適合ケースは空
cov = japan_fiscal_coverage(:jgb_funding_cost, :capex_credit_cycle)
japan_fiscal_validate_claims(:jgb_funding_cost, :capex_credit_cycle;
    diagnostics = [:direction, :peak, :onset, :duration],
    numeric_semantics = :normalized_deviation,
    disclosed_unsupported_concepts = cov.unsupported_concepts,
    disclosed_unsupported_outputs = cov.unsupported_outputs)
# => 空（適合）
```

---

## 8. 公開 API

| 関数・定数 | 役割 |
|---|---|
| `JAPAN_FISCAL_CLAIM_CONTRACT_VERSION` | 契約 version |
| `japan_fiscal_claim_level_spec(level)` | `claim_level` の意味論 |
| `japan_fiscal_claim_level_permits(level, diagnostic)` | 診断の可否 |
| `japan_fiscal_forbidden_diagnostics(level)` | 主張できない診断 |
| `japan_fiscal_coverage(family, model)` | artifact が保持する被覆情報 |
| `japan_fiscal_coverages(; family, adoption)` | 被覆情報の一括取得 |
| `japan_fiscal_channels(; family, status)` / `japan_fiscal_channel(family, id)` | 因果チャネル |
| `japan_fiscal_calibration_geography(mapping)` | 較正地理（`calibration_basis` からの派生） |
| `japan_fiscal_numeric_semantics_rank(s)` | 数値意味づけの強さ |
| `japan_fiscal_forbidden_claims()` | 禁止する主張と理由 |
| `japan_fiscal_validate_claims(family, model; …)` | 実行時の契約検証 |
| `japan_fiscal_handoff_requirements(; audience)` | downstream 要件 |
| `JAPAN_FISCAL_CLAIM_UPGRADE_RULE` | `claim_level` 昇格の規則 |
| `japan_fiscal_downstream_contract()` | 契約全体の機械可読 export |
| `to_dict` / `to_json` | 各レコード型の JSON 化 |

`japan_fiscal_downstream_contract()` は `claim_contract_version` / `capability_contract_version` /
`claim_levels` / `diagnostics` / `numeric_semantics` / `coverages`（55 件）/ `channels`（25 件）/
`forbidden_claims` / `handoff_requirements`（22 件）/ `claim_upgrade_rule` / `invariants` を持つ
単一の `Dict{String,Any}` を返す。Market Analyzer は Julia 内部型を import せず、
この Dict と #276 の result artifact のみを consume する。

---

## 9. 対象外

- `G-01` を解消する政府債務モデルの実装
- `G-02` の日本較正そのもの
- `G-15` の日本 financial-stress データ取得
- モデル方程式の変更・#274 registry の判定変更
- Market Analyzer の UI 実装
- 危機確率・デフォルト確率の算出
