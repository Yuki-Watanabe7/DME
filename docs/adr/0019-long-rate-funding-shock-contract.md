# ADR 0019: 長期金利・funding-cost shockを政策金利から分離し、既存の外生変数7個・イベント層を拡張して表現する

- **ステータス**: 採用
- **日付**: 2026-09-12
- **関連Issue**: #125（ロードマップ）・#260（本決定。長期金利・funding-cost shockを政策金利から分離し2026-09 financial-instability live holdoutを実装する。本ADRはPart A「shock semantics」のみを対象とし、Part B（EDP financial-stress観測のconsumer化）・Part D（2026-09 live holdout artifact）は別途扱う）
- **前提ADR**: [ADR 0010](0010-macro-event-scenario-contract.md)（イベントの4層分離・適用先を外生変数7個に限定する決定・固定順合成）・[ADR 0011](0011-capex-credit-cycle-dynamics-contract.md)（`spread_shock_ex` を含む遅れの列挙・数値ガードの3層分離）・[ADR 0015](0015-macro-event-runtime-contract.md)（イベント型9種を宣言的レジストリで持つ・`map_event` の引数型を`ScenarioAssumption`限定とする・失敗の3層分離）
- **関連ドキュメント**: [マクロイベント変換契約](../architecture/macro_event_contract.md) §14（本決定の詳細）・[部門別CAPEX・信用循環モデル 動学方程式と数値計算契約](../models/capex_credit_cycle_equations.md)（`spread_shock_ex`・`policy_rate` の方程式）・[イベント・シナリオ実行層 統合設計](../architecture/macro_event_runtime_integration.md)

---

## コンテキスト

2026-09の米国長期金利上昇を受け、「Minsky transition / financial instabilityが進行しているか」を検証する能力の整備が優先された（#260）。この検証は、**政策金利変更を伴わない、または政策金利だけでは説明できない長期金利上昇**を独立した外生ショックとして扱えることを前提とする。

既存のイベント層（ADR 0010・ADR 0015）は9種のイベント型を持ち、うち金利・信用に関わるものは次の2つである。

- `:PolicyRateChange` → `policy_rate`（政策金利、短期・制度設定、`:absolute`/`:additive`、`%pt`）
- `:CreditSpreadShock` → `spread_shock_ex`（信用スプレッド、`:additive`、`bp`）

`CapexCreditCycleModel`（`CCC`）の実効借入コストは `r_new_s = (policy_rate + spread / 100) / 100`（`spread = spread_endo + spread_shock_ex`）で決まり、モデルは「短期政策金利」と「それ以外の加算的な上乗せ」の2区分しか持たない。長期金利のrepricing（10年国債利回り等）やsecured funding市場のストレス（SOFR/TGCRの政策アンカー対比乖離）は、このどちらの区分にも直接該当しない。

ここで2つの誤りが起こりうる。

1. **`:PolicyRateChange` へ押し込む**: 長期金利上昇をFedの短期政策スタンスと同一視し、「政策金利を上げていないのに長期金利が上がっている」という今回の仮説そのものを表現できなくする。
2. **観測されたbpをそのまま `spread_shock_ex` へ1:1で足し込む**: 長期金利repricingが実際に企業の実効借入コストへ反映される度合い（pass-through）を暗黙に1と仮定したことになり、根拠のない精度を主張する。加えて、10年名目金利・10年実質金利・inflation compensation・secured funding spread・credit spreadという異なる観測次元を、1つのbp値へ黙って合算すると、どの次元が寄与したかを後から追跡できなくなる。

`CCC` の外生変数は7個に限定する決定（ADR 0010）が既にあり、新しい exogenous 変数を安易に追加することは、[責務境界](../models/capex_credit_cycle_model_boundaries.md) §5.6-1（近似・代理・スケーリングによる適用を行わない）と同じ理由で慎重を要する。一方で、`spread_shock_ex` は既に `:CreditSpreadShock`（信用スプレッド）と `:RefinancingOrRatingEvent`（格付・借換のうち市場価格に現れた分）という2つの異なる実体を同じ加算スロットへ写像しており、複数の原因が同一の「実効借入コストへの加算的な上乗せ」という構造を区別しない設計は既に存在する。

## 決定

1. **イベント型を9種から10種へ拡張し、`:LongRateFundingShock`（長期金利・funding条件ショック）を追加する。**
   `MACRO_EVENT_TYPES`・`MACRO_EVENT_TARGET_CONCEPTS`（`:long_rate_funding_condition` を追加）・`MACRO_EVENT_TYPE_REGISTRY` を拡張する。イベント型ごとの struct は追加しない（ADR 0015 決定2「型別structを作らない」をそのまま踏襲する）。

2. **`:LongRateFundingShock` の適用先を新しい exogenous 変数ではなく既存の `spread_shock_ex` とし、`CapexCreditCycleModel` の外生変数7個を変更しない。**
   `EventMappingRule(event_type=:LongRateFundingShock, target_variable=:spread_shock_ex, application_mode=:additive, unit="bp")` を `CAPEX_CC_EVENT_MAPPING_RULES` へ追加する。`:CreditSpreadShock`・`:RefinancingOrRatingEvent`・`:LongRateFundingShock` の3つが同一の `spread_shock_ex` へ既存の固定順合成規則（ADR 0010）でそのまま加算合成される。新しい合成規則は追加しない。

3. **生データの分解（`FundingShockComponents`）とモデル入力への変換（`FundingShockPassThrough` + `funding_shock_magnitude_bps`）を分離し、pass-throughを versioned な明示parameterとする。**
   `FundingShockComponents` は `long_nominal_yield_shift_bps`（必須）・`secured_funding_spread_shift_bps`（必須）・`long_real_yield_shift_bps`（欠測可）・`inflation_compensation_shift_bps`（欠測可）を保持する。`magnitude = long_nominal_yield_shift_bps × long_nominal_yield_pass_through + secured_funding_spread_shift_bps × secured_funding_pass_through` とし、`FundingShockPassThrough` の既定係数（`1.0`）は `FUNDING_SHOCK_PASS_THROUGH_VERSION` とともに記録される named constant であって、暗黙のデフォルトではない。

4. **`long_real_yield_shift_bps`・`inflation_compensation_shift_bps`・両者から導出する `decomposition_residual_bps` を `magnitude` の算出に含めない。`decomposition_residual_bps` を `term premium` と呼ばない。**
   名目長期金利は（観測できる場合）実質金利とinflation compensationの和で近似的に説明されるが、その残差を独自の高精度推定値として扱うことは対象外（#260）である。残差は診断用の内訳として保持し、`magnitude` へ二重に加算しない。

5. **`credit_spread_shift_bps` を `FundingShockComponents` に含めない。既存の `:CreditSpreadShock` を独立入力として使う。**
   信用スプレッド固有の入力経路は既に存在するため、同じ次元を2つの event_type から二重に投入できる状態を作らない。

6. **`:LongRateFundingShock` の `allowed_target_concepts` を `[:long_rate_funding_condition]` のみとし、`:PolicyRateChange`（`[:policy_rate]`）と `:CreditSpreadShock`（`[:credit_spread]`）のいずれとも重ねない。自動的な相殺（netting）ロジックを追加しない。**
   政策金利変更と長期金利repricingを別 `ScenarioAssumption` として独立に投入できることを、レジストリによる型レベルの強制で保証する（event_type_registry.jl の既存設計原則「政策金利と信用スプレッドは別 target concept・別 event_type を持つ独立したレコードであり、自動的な相殺ロジックを持たない」を継承する）。

## 理由

- **既存の合成モデルをそのまま使える**。`spread_shock_ex` が複数の event_type からの加算を既に想定しているため、新しい exogenous 変数・新しい期内処理ステップ・新しい会計恒等式の変更を必要としない。ADR 0011（動学契約）の「全循環の遅れを本決定で列挙し実装者が個別に選ばない」という既存の秩序を壊さない。
- **pass-throughの明示化は、暗黙の精度主張を防ぐ**。`1.0` を既定にすることと、それを検証・追跡可能な named constant にすることは別である。後者はsensitivity分析（係数を変えて再計算し、結果がどれだけ係数に依存するかを示す）を可能にする。
- **観測次元を1つのbpへ潰さないことで、二重計上を防ぎ、監査可能性を保つ**。`FundingShockComponents` と `FundingShockPassThrough` を `caveats` へ自動的に記録する実装（`long_rate_funding_scenario_assumption`）により、「どの観測から、どの係数で、いくらのmagnitudeが作られたか」を後から追跡できる。
- **型レベルの強制は文書の規律より壊れにくい**。`allowed_target_concepts` による強制は、ADR 0015 決定3（層飛ばしを型で禁じる）と同型の設計判断である。

## 見送りとした選択肢

- **`:PolicyRateChange` を長期金利にも使えるよう拡張する**: #260 が明示的に禁じる誤り（短期政策スタンスとlong-end repricingの同一視）そのものであり、採用しない。
- **新しい exogenous 変数（例: `long_rate_shock_ex`）を追加する**: `CCC` の外生変数7個への限定（ADR 0010）を破る。長期金利repricingが実効借入コストへ加算的に効くという構造は `spread_shock_ex` と変わらないため、変数を増やす便益が無い。将来、長期金利と信用スプレッドが異なる動学（例: 異なる遅れ・異なる非線形性）を持つことが判明した場合は、この決定を改訂して分離する。
- **観測されたbpをそのまま1:1で `spread_shock_ex` へ渡す（pass-through無し）**: 実装は単純だが、「観測＝モデル入力」という暗黙の精度主張になり、#260 の対象外事項（term premiumの独自高精度推定）と同じ誤りを形を変えて犯す。
- **`long_real_yield_shift_bps`/`inflation_compensation_shift_bps`もmagnitudeへ合算する**: 名目金利は定義上おおむね実質金利とinflation compensationの和であるため、これを別立てで足すと二重計上になる。

## 影響

- **`CapexCreditCycleModel` の外生変数7個・期内処理順序10ステップ・会計恒等式は変更しない**。既存の `Sc0`–`Sc4`・履歴再生（#247–#251）・既存シナリオの数値互換に影響しない。
- **`MACRO_EVENT_TYPES`（9→10）・`MACRO_EVENT_TARGET_CONCEPTS`（9→10）・`MACRO_EVENT_CONTRACT_VERSION`（`1.0.2`→`1.0.3`）を変更する**。既存9種のレジストリ行・マッピング行・テストは変更しない（非破壊の追加）。
- **`src/scenarios/long_rate_funding_shock.jl` を新設する**（`FundingShockComponents`・`FundingShockPassThrough`・`FUNDING_SHOCK_PASS_THROUGH_VERSION`・`funding_shock_magnitude_bps`・`long_rate_funding_scenario_assumption`）。`macro_events.jl`・`scenario_types.jl` は変更しない（4層レコード型・`Scenario` 自体へフィールドを追加しない）。
- **#260 Part B（EDP financial-stress観測のconsumer化）・Part D（2026-09 live holdout artifact）は本ADRの対象外**。Part B が取得する生観測（CCC OAS・broad HY OAS・SOFR・TGCR・IORB・10年名目/実質金利・inflation compensation）から `FundingShockComponents` を構築する変換は、Part B/D 側の実装課題として引き継ぐ。
- **較正は対象外のまま**。`default_shape_params`（半減期4四半期）・`FundingShockPassThrough` の既定係数（`1.0`）はいずれも暫定既定値であり、#260 は2026-09データを較正に使わないことを明記している。

## 参考

- [マクロイベント変換契約](../architecture/macro_event_contract.md) §14 — 本決定の詳細（イベント型10種目・pass-through・独立性の3点）
- [部門別CAPEX・信用循環モデル 動学方程式と数値計算契約](../models/capex_credit_cycle_equations.md) §4.2-4.3・§5.3 — `spread_shock_ex`・`policy_rate`・`r_new_s` の方程式
- [ADR 0010](0010-macro-event-scenario-contract.md) — イベントの4層分離・適用先を外生変数7個に限定する決定
- [ADR 0011](0011-capex-credit-cycle-dynamics-contract.md) — 全循環の遅れの列挙・数値ガードの3層分離
- [ADR 0015](0015-macro-event-runtime-contract.md) — イベント型9種を宣言的レジストリで持つ・型による層飛ばし禁止
