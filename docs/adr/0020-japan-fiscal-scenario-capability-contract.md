# ADR 0020: Japan fiscal scenario の representability を実装前に固定し、表現不能な概念を近いショックへ寄せない

- **ステータス**: 採用
- **日付**: 2026-09-19
- **関連Issue**: [#273](https://github.com/Yuki-Watanabe7/DME/issues/273)（Japan Fiscal Scenario Lab ロードマップ）・[#274](https://github.com/Yuki-Watanabe7/DME/issues/274)（本決定）・後続 [#275](https://github.com/Yuki-Watanabe7/DME/issues/275)（catalog / assumption schema）・[#276](https://github.com/Yuki-Watanabe7/DME/issues/276)（adapter / runner / artifact）・[#277](https://github.com/Yuki-Watanabe7/DME/issues/277)（E2E / consumer handoff）。producer roadmap: Yuki-Watanabe7/fiscal-regime-engine#1
- **前提ADR**: [ADR 0006](0006-cross-model-reasoning-contract.md)（概念対応の明示・同名変数の非同一視・比較不能の非統合）・[ADR 0009](0009-capex-credit-cycle-model-responsibilities.md)（責務を判定問題に必要な範囲へ限定する・翻訳不能なイベントを適用しない）・[ADR 0010](0010-macro-event-scenario-contract.md)（イベントの4層分離・適用先を限定し近似で寄せない・magnitude捏造禁止）・[ADR 0014](0014-digital-twin-naming-conditions.md)（名乗る条件を先に固定し自己申告しない）・[ADR 0015](0015-macro-event-runtime-contract.md)（宣言的レジストリ・層飛ばしを型で禁じる・fail closed）・[ADR 0019](0019-long-rate-funding-shock-contract.md)（長期金利と政策金利の分離・pass-throughの明示化）
- **関連ドキュメント**: [Japan Fiscal Scenario Lab capability / mapping 契約](../architecture/japan_fiscal_scenario_capability.md)（本決定の詳細）・[モデル能力・概念定義 metadata](../model_capabilities.md)

---

## コンテキスト

fiscal-regime-engine（FRE）は日本の財政・金融状態を 4 archetype / 5 dimensions / Constraint Pressure として versioned snapshot 化し、Market Analyzer で可視化できる状態に達した。Phase 3 では、この現状観測を起点に DME で反実仮想シナリオを比較する Scenario Lab を作る（#273）。

しかし DME の既存 vertical slice は米国の CAPEX・信用循環（CCC）を中心に作られており、日本財政の 5 scenario family（low growth + high rates / fiscal consolidation / financial repression / high growth・productivity shock / JGB funding-cost shock）を既存モデルでどこまで表現できるかは未監査だった。

この状態で adapter 実装（#276）へ進むと、次の失敗が起こりやすい。

1. **表現できない概念を近いショックへ黙って寄せる**。財政緊縮を New Keynesian の需要ショックへ、GDP 成長率を CCC のモデル外需要パスへ、JGB 利回りを Mundell-Fleming の世界利子率へ写像すると、入力の意味が変わったことが結果から追跡できなくなる。
2. **FRE の affinity / share / confidence を shock magnitude へ変換する**。これらは「どのレジームに近いか」の度合いであって経済量ではない。確信度 0.8 が「-8%」を意味することはない（ADR 0010 §belief の契約と同型）。
3. **金融抑圧を単一の政策金利ショックへ縮約する**。金融抑圧は低い名目金利・高いインフレ・中央銀行の国債吸収の組み合わせであり、1 本の金利ショックへ潰すと「何を仮定したか」が消える。
4. **較正されていないモデルの出力を日本の量として提示する**。DME の実証較正は Keen（米国）と CCC（米国 NIPA）のみであり、日本データで較正されたモデルは存在しない。

加えて、Phase 3 の non-goal は「日本財政を単一モデルで完全再現すること」であり、表現不能なギャップのためにモデル方程式へ Fiscal 専用分岐を足すことは選択肢にない。

## 決定

1. **5 scenario family × 11 候補モデル = 55 セルすべてに representability 判定を置き、宣言的レジストリとして `src/scenarios/japan_fiscal_capability.jl` に保持する。**
   イベント型レジストリ（ADR 0015 決定 2）と同じ idiom を採る。family 別・モデル別の struct は作らない。判定は `:representable` / `:partial` / `:not_representable` の 3 値。

2. **representability を宣言値ではなく family 仕様からの導出値として強制する。**
   `:representable` は「family の `required_concepts` をすべて別々の入力として受け取り、かつ `required_outputs` をすべて内生的に返す」場合に限る。`:partial` は required concept の一部を受け取るが上の条件を満たさない場合、`:not_representable` は required concept を 1 つも受け取らない場合。3 値は相互排他かつ網羅的であり、宣言値と導出値の不一致は registry 登録時に例外で落とす。「表現できるつもり」で書いた行が通らない。

3. **表現できない概念は `input_kind = :not_accepted` の行として、受け取れない理由つきで明示的に記録する。禁止代理を family ごとに列挙する。**
   `JapanFiscalScenarioFamilySpec.forbidden_proxies` を空にできない（コンストラクタが拒否する）。列挙する禁止代理には、Solow の貯蓄率 `s` を財政再建の代理にしない・CCC のモデル外需要を GDP 成長パスの代理にしない・CCC の `price_s1` を一般物価の代理にしない・Mundell-Fleming の `r_star` を JGB 利回りの代理にしない・New Keynesian の `:demand` ショックを財政緊縮や生産性向上の代理にしない、を含む。

4. **FRE snapshot の役割を `:observed_context_only` に固定し、FRE のスコアが magnitude へ入る経路を型と語彙で塞ぐ。**
   `magnitude_source = :external_belief` を Japan fiscal scenario assumption で受理しない。`JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_INPUT_FIELDS`（`regime_affinity`・`regime_share`・`regime_confidence`・`dimension_score`・`constraint_pressure`・`data_quality_score`）のいずれも、registry のどの `JapanFiscalInputMapping.variable` とも一致しない（テストで検査する）。

5. **金融抑圧を単一の政策金利ショックへ縮約しない。`required_concepts` を `:policy_rate` / `:inflation` / `:cb_jgb_absorption` の 3 つに分け、受け取れない概念を unsupported として返す。**
   この規則の帰結として、AD-AS を `:not_representable` と判定する。AD-AS は物価を内生化するが、インフレと名目金利がマネーサプライという単一入力の同時結果としてしか動かないため、2 概念を独立な assumption として置けない。`:cb_jgb_absorption` はすべてのモデルで受け取れない。

6. **`claim_level = :magnitude` は `calibration_basis = :japan_calibrated` のときのみ許す。日本較正済みモデルは存在しないため、該当するセルは 1 つも無い。**
   コンストラクタと registry 健全性検査の両方で強制する。Phase 3 のすべての結果は方向（`:direction_only`）または方向と相対的な時間形状（`:direction_and_relative_timing`）までであり、日本の量として提示しない。ADR 0014 と同じく、名乗る条件を先に固定し自己申告で緩めない。

7. **GDP 成長率パスを受け取るモデルが存在しないことを確定し、成長 assumption を構造ドライバーへの変換として扱う。**
   産出はすべてのモデルで内生変数であり、`:growth_path` を直接受け取るセルは 0 である。成長仮定は Solow の `g`・RBC の TFP・Keen の `α` へ変換され、その変換は一意でない。変換の非一意性を artifact に記録する。生産性ショック（`:productivity_growth`）と GDP パス assumption（`:growth_path`）を別概念として保持する。

8. **VAR を全 family で `:not_representable` とする。**
   `VARModel` は係数手入力・ラグ 1 であり、どのショックがどの経済概念に対応するかの構造識別機構を持たない。任意の変数集合を置けるため形式的には何でも表現できるように見えるが、係数の供給元が DME に無い。能力 metadata の原則「推測で過大申告しない」に従う。

9. **JGB funding-cost ショックを sovereign leg と private pass-through leg に分け、#260 契約の日本再利用範囲を要素ごとに確定する。**
   イベント型 `:LongRateFundingShock` と `FundingShockComponents`（生データ分解）はモデル非依存であり日本へ再利用できる。`FundingShockPassThrough` は構造のみ再利用でき、既定係数 `1.0` は日本について較正されていないため感応度併記を必須とする。`:LongRateFundingShock` → `spread_shock_ex` の写像・CCC の部門構成と逆較正・米国 financial-stress 系列は再利用しない。sovereign leg（政府の調達コスト・利払費）はどのモデルでも表現できない。

10. **解消しないギャップを 15 件（`G-01`–`G-15`）登録し、解決先を `hold_as_limitation` / `followup_issue` / `out_of_scope` に割り当てる。**
    最重要は `G-01`（利付き政府債務ストックを持つモデルが存在しない。SIM の `H` は無利子の政府貨幣）と `G-02`（日本較正済みモデルが存在しない）。いずれも #276 の adapter 実装で埋められるものではなく、埋めるには新しいモデルが要る（#273 non-goal）。

11. **family ごとに `:primary` を 1 つだけ置く。複数モデルの結果を 1 本の経路へ合成しない。**
    採用は F1 = CCC、F2 = SIM、F3 = New Keynesian、F4 = Solow、F5 = CCC。補助候補（`:supporting`）は併記してよいが、ADR 0009 と同じくモデル合成・連成は行わない。

12. **モデル方程式・既存 API を一切変更しない。本契約は宣言層である。**
    `AbstractMacroModel` の各メソッド・`SimulationResult`・イベント層 API・`MODEL_CAPABILITY_REGISTRY` はいずれも変更しない。

## 理由

- **判定を実装前に固定すると、adapter が「寄せる」誘惑を持たなくなる**。#276 は `japan_fiscal_unsupported_concepts` が返すものを unsupported として返すだけでよく、近い変数を探す判断を毎回やり直さない。これは ADR 0011 の「全循環の遅れを本決定で列挙し実装者が個別に選ばない」と同型の設計判断である。
- **導出値による強制は文書の規律より壊れにくい**（ADR 0015 決定 3・ADR 0019 決定 6 と同型）。representability・`claim_level`・`:not_accepted` 行の理由の必須化・`forbidden_proxies` の非空性は、いずれもコンストラクタか registry 検査で落ちる。
- **`claim_level` の上限を較正基準に結び付けることで、較正の有無が出力の主張に機械的に反映される**。将来、日本較正済みモデルが追加されたときに初めて `:magnitude` が解禁され、それまでは型が拒否する。
- **ギャップを「後で埋める TODO」ではなく限界として登録することで、Phase 3 の成果物が何を答えないかが consumer から見える**。Market Analyzer は `japan_fiscal_capability_matrix()` の `gaps` と各 mapping の `cannot_state` をそのまま表示できる。
- **55 セルを網羅すると、監査から漏れたモデルが生じない**。候補モデル集合は `MODEL_CAPABILITY_REGISTRY` と一致することをテストで検査するため、新モデル追加時に判定漏れが検出される。

## 見送りとした選択肢

- **表現不能な family のためにモデルへ Fiscal 専用分岐を追加する**: #273 の non-goal。政府債務・中央銀行バランスシートを既存モデルへ後付けすると、モデルの責務境界（ADR 0009）が崩れ、既存シナリオの数値互換も失う。
- **`:partial` を廃し `:representable` / `:not_representable` の 2 値にする**: 実際のセルの多くは「一部の概念だけ受け取れる」状態にあり、2 値にすると切り上げ（過大申告）か切り下げ（有用な mapping の破棄）のどちらかを強いられる。
- **representability を人手の宣言だけで持つ**: 宣言と実態の乖離が検出されない。family 仕様からの導出と一致検査を入れることで、required concept を増やしたときに既存セルの判定が自動で破綻し、見直しが強制される。
- **CCC を日本シナリオで使わない**: CCC は政策金利と長期金利を別変数へ入れられる唯一のモデルであり（F1・F5 の中核要件）、これを外すと両 family の実装候補が消える。代わりに `calibration_basis = :non_japan_calibrated` と `claim_level` の上限で、量を主張できないことを型に持たせた。
- **FRE score から magnitude への変換関数を「明示的に採用した場合のみ」許す**: ADR 0010 は belief 由来の数量を `:external_belief` として記録し分析者が採否を明示する設計を持つが、FRE のスコアは数量ですらない（affinity は確率でも弾性値でもない）。採用の余地を残すと、運用の中で既定になりうるため経路自体を塞いだ。
- **capability matrix を Markdown の表だけで持つ**: #275 の scenario artifact は model capability decision version を参照する必要があり、#276 の adapter は accepted / unsupported を機械的に引く必要がある。文書だけでは両者が別々に判定を再実装することになる。

## 影響

- **`src/scenarios/japan_fiscal_capability.jl` を新設する**（型 5 種・語彙 11 種・registry 4 種・照会 API 14 種）。`src/DME.jl` の include と export のみを変更し、既存モジュールは変更しない。
- **モデル方程式・`SimulationResult`・イベント層 API・`MODEL_CAPABILITY_REGISTRY` は変更しない**。既存テスト・既存シナリオ・既存 artifact の数値互換に影響しない。
- **#275 は `JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION` を scenario artifact の model capability decision version として参照する**。本契約を改訂する場合は version を上げ、既存 artifact の identity を壊さない。
- **#276 の実装対象は `adoption != :not_adopted` の 14 セルに限定される**（`:primary` 5 + `:supporting` 9）。`:not_adopted` のセルは実装しない。
- **#277 の negative fixture は `forbidden_proxies` と `:not_representable` セルを根拠にできる**。
- **日本較正（`G-02`）と日本の financial-stress 系列（`G-15`）は後続 Issue の候補として残す**。いずれも Phase 3 では着手しない。

## 参考

- [Japan Fiscal Scenario Lab capability / mapping 契約](../architecture/japan_fiscal_scenario_capability.md) — 55 セルの判定・family 別の分解規則と禁止代理・gap register・#276 への要件
- [モデル能力・概念定義 metadata](../model_capabilities.md) — 候補モデル 11 種の能力プロファイル（本契約の候補集合はこの registry と一致する）
- [ADR 0010](0010-macro-event-scenario-contract.md) — イベントの4層分離・適用先を限定し近似で寄せない・magnitude捏造禁止
- [ADR 0015](0015-macro-event-runtime-contract.md) — 宣言的レジストリ・層飛ばしを型で禁じる・fail closed
- [ADR 0019](0019-long-rate-funding-shock-contract.md) — 長期金利と政策金利の分離・pass-throughの明示化（本契約の F5 が再利用範囲を確定する）
