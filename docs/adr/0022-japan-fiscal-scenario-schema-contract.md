# ADR 0022: Japan Fiscal Scenario Lab の scenario catalog・explicit assumption schema・FRE context contract

- **ステータス**: 採用
- **日付**: 2026-09-20
- **関連Issue**: [#273](https://github.com/Yuki-Watanabe7/DME/issues/273)（Japan Fiscal Scenario Lab ロードマップ）・[#274](https://github.com/Yuki-Watanabe7/DME/issues/274)（capability audit。本決定の前提）・[#285](https://github.com/Yuki-Watanabe7/DME/issues/285)（claim-level / coverage 契約。本決定の前提）・[#275](https://github.com/Yuki-Watanabe7/DME/issues/275)（本決定）・downstream [#276](https://github.com/Yuki-Watanabe7/DME/issues/276)・[#277](https://github.com/Yuki-Watanabe7/DME/issues/277)。関連 producer: Yuki-Watanabe7/fiscal-regime-engine#1
- **前提ADR**: [ADR 0020](0020-japan-fiscal-scenario-capability-contract.md)（55 セルの representability・9 assumption concept・FRE context の役割を `:observed_context_only` に固定する決定）・[ADR 0021](0021-japan-fiscal-claim-level-contract.md)（claim-level / coverage の downstream 伝播・`H-01`–`H-05` の要件を #275 に割り当てる決定）
- **関連ドキュメント**: [scenario catalog / assumption schema / FRE context 契約](../architecture/japan_fiscal_scenario_schema_contract.md)（本決定の詳細）・[capability / mapping 契約](../architecture/japan_fiscal_scenario_capability.md)（#274）・[claim-level / coverage 契約](../architecture/japan_fiscal_claim_level_contract.md)（#285）

---

## コンテキスト

#274 は 5 scenario family × 11 モデル = 55 セルの representability を確定し、9 つの assumption
concept（単位・時点基準・イベント層対応）と FRE snapshot の役割（`:observed_context_only`）を
固定した。#285 はその判定を「artifact が主張してよい診断」「保持する数値系列の意味づけ」へ
展開し、downstream handoff requirements 22 件（`H-01`–`H-22`）を確定した。うち `H-01`–`H-05`
の 5 件が #275（本Issue）の受け入れ条件として割り当てられている。

#274/#285 はいずれも**宣言のみ**（既存モデル・既存 registry に対する固定 55 セルの静的な監査
結果）であり、実際に scenario を構築する型を持たない。#275 が構築する型が満たさなければ
ならない制約は、次の 3 点である。

1. **observed context（FRE snapshot）と explicit assumption を型として分離する**こと。
   FRE の affinity・share・confidence・dimension score・Constraint Pressure・data quality score
   は「どのレジームに近いか」の度合いであって経済量ではなく（#274 `JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_INPUT_FIELDS`）、
   scenario の magnitude を生成する経路にこれらを混入させてはならない。
2. **0 と missing を区別する**こと。0 は「変化なしという明示的な主張」、missing は
   「その assumption を置いていない」であり、意味が異なる。
3. **`magnitude_source = :external_belief` を construction 時に拒否する**こと（`H-04`）。
   外部システムの belief に付随した数量が、この経路を経由して FRE のスコアを magnitude へ
   持ち込む可能性を塞ぐ。

## 決定

1. **FRE context を `JapanFiscalScenarioAssumption`・`JapanFiscalScenario` とは別の型
   `JapanFiscalFREContext` として持つ。** DME は FRE（fiscal-regime-engine、別リポジトリ）の
   スキーマを所有しないため、Issue #275 scope §1 が列挙する最低限のフィールド（snapshot
   identity・as-of・vintage basis・`:primary`/`:ambiguous`/`:unavailable` の regime
   determination・Constraint Pressure・5 dimensions の `dimension_score`・dominant drivers・
   data quality・methodology/policy version）を保持する record として定義する。本型を引数に
   取り magnitude を返す関数は本ファイルに一切実装しない。これは規約ではなく構造的な事実として
   検査できる（`JapanFiscalScenarioAssumption` の constructor 引数・`fieldnames` に
   `JapanFiscalFREContext` 型の値が現れない）。

2. **assumption の 0 と missing の区別を、`Union{Float64,Nothing}` のような nullable
   magnitude フィールドではなく、「concept ごとに `JapanFiscalScenarioAssumption` が
   `JapanFiscalScenario.assumptions` に存在するかどうか」で表す。** `magnitude::Float64` は
   常に有限の具体値であり、「置いていない」状態を型の内部に持たない。これは一般 macro event
   層の `ScenarioAssumption.magnitude::Float64`（nullable ではない）と同じ設計であり、
   serialization でも「存在しない concept の JSON キーを作らない」という自然な形で round trip
   する（`H-03`）。

3. **`unit` と `direction` をフィールドとして保持せず、`concept` と `magnitude` から導出する。**
   `unit` は `japan_fiscal_assumption_concept(concept).unit`（#274）から、`direction`
   （`:up`/`:down`/`:none`）は `sign(magnitude)` から導出する。二重管理を避けるための設計判断
   であり、`to_dict` の出力には両方とも含める（consumer は Julia 型を持たないため、値の再導出を
   要求しない）。`from_dict` は読み込んだ値と再導出した値の一致を検査し、不一致を
   `ArgumentError` とする。

4. **`magnitude_source` を `MACRO_EVENT_MAGNITUDE_SOURCES`（マクロイベント変換契約）から
   要求し、`japan_fiscal_magnitude_source_allowed`（#274）が `false` を返す値
   （`:external_belief`）を construction 時に `ArgumentError` で拒否する（`H-04`）。**
   #274 が固定した禁止判定をそのまま呼び出すだけであり、#275 で新しい判定基準を作らない。

5. **`JapanFiscalScenario` の construction 時に、各 assumption の `concept` が
   `japan_fiscal_family_spec(family)`（#274）の `required_concepts ∪ optional_concepts` に
   含まれることを検証し、含まれない concept を `ArgumentError` で拒否する。** 表現不能な概念を
   近い入力へ黙って寄せない、という #274 の方針を scenario 構築時点で具体化したものである。
   同一 concept の重複した assumption も拒否する（あいまいさを避ける）。model 別の unsupported
   判定（ある model がある concept を受け取れるか）は #274 の registry が引き続き担い、#275 は
   再実装しない。

6. **scenario catalog（5 family）は `japan_fiscal_family_spec`（#274）から `required_concepts`・
   `optional_concepts`・`guardrails`・`display_name`・`doc_ref` をそのまま引き、独自に
   再定義しない（`H-01`）。** `concept_units`（#274 の assumption concept registry から導出）・
   `compatible_models`（`japan_fiscal_implementation_candidates`）・`horizons`（#274 の
   `JapanFiscalInputMapping.horizon` の distinct 集合として導出。`:not_accepted` の入力は除く）・
   `unsupported_channel_ids`（#285 の channel registry の `:unsupported` から導出）のみを
   catalog 独自の追加情報として持つ。この一致は load 時 invariant として検査する（ADR 0021 と
   同じ、テストより強い保証）。

7. **family 単位の「代表的な horizon・persistence」という値は catalog に持たせない。**
   per-(family, model) の horizon は #274 の `JapanFiscalInputMapping.horizon` にすでに存在し、
   persistence（時間形状）の選択は #276（adapter/runner）の責務である。単一の代表値へ
   縮約すると、モデルごとに異なる horizon・persistence を隠して誤読を招く。catalog は
   `horizons::Vector{Symbol}`（distinct 値の列挙）のみを持ち、どの値がどの model のものかは
   `japan_fiscal_model_mapping(family, model).inputs` を直接参照させる。

8. **scenario artifact の identity（`JapanFiscalScenarioProvenance`）に
   `JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION`（#274）と `JAPAN_FISCAL_CLAIM_CONTRACT_VERSION`
   （#285）の両方を持たせる（`H-02`）。** `content_hash` 自身は `JapanFiscalScenarioProvenance`
   のフィールドとして持たない（hash 自己参照を避ける。ADR 0008 と同じ設計判断）。
   `japan_fiscal_scenario_content_hash` が別関数として計算し、artifact（`to_dict`）にのみ
   計算結果を含める。

9. **identity 対象（`schema_version`・両 contract version・`assumption_source`）と
   volatile（`created_at`・`created_by`・`notes`）を `JapanFiscalScenarioProvenance` の
   フィールドとして分離する。** volatile フィールドを変更しても `content_hash` は変わらない。

10. **2 種類の hash を分離する。** `japan_fiscal_assumption_set_hash` は `assumptions` のみを
    対象とし、`fre_context` を含まない。`japan_fiscal_scenario_content_hash` は `fre_context`
    の identity・`assumption_set_hash`・identity 対象 provenance を合成する。この分離により、
    「FRE context だけを変えた 2 つの scenario が同一の applied model input を生む」
    （`H-05`）ことを、#276 が `japan_fiscal_assumption_set_hash` を「applied model input」の
    identity として使うだけで自動的に満たせる。両 hash とも RFC 8785 正準 JSON
    （`artifacts/json_canonical.jl`）+ SHA-256 とし、`assumptions` は `assumption_id` 昇順に
    整列してから正準化する（入力順に依存しない）。

11. **`assumption_source`（scenario 全体がどこから来たか。`:user`/`:preset`/`:fixture`/
    `:analysis`）と `magnitude_source`（個々の assumption の数値の出所。#274 の
    `MACRO_EVENT_MAGNITUDE_SOURCES`）を別の語彙として持つ。** 混同すると「FRE 由来の belief を
    経由した magnitude を拒否する」制約（決定4）と「scenario の作成経路を記録する」制約が
    同じフィールドで競合する。

12. **JSON round trip（`to_dict`/`to_json`/`japan_fiscal_*_from_dict`）を、
    `scenario_serialization.jl`（一般 macro event 層、Issue #203）と同じ fail closed
    decode 契約で実装する。** 必須キーの欠落・未知キーの混入を `ArgumentError` で拒否し、
    `content_hash`・`assumption_set_hash`・`context_identity`・`unit`・`direction` について
    読み込んだ値と再計算した値の一致を検査する。改変された artifact を気付かずに読み込む
    経路を作らない。

## 理由

- **型による分離は文書の注意書きより壊れにくい**。#274 の `JAPAN_FISCAL_FRE_CONTEXT_ROLE =
  :observed_context_only` は文書上の宣言だったが、`JapanFiscalFREContext` を独立した型にし、
  `JapanFiscalScenarioAssumption` の constructor がこの型を引数に取らないことで、
  「FRE のスコアが magnitude 計算に混入しない」ことを型シグネチャで示せる。
- **0 と missing の区別は「置いたかどうか」で表す方が、nullable フィールドより単純で
  誤りにくい**。nullable `magnitude::Union{Float64,Nothing}` を採用すると、
  「missing の assumption を保持するかどうか」という新しい選択を持ち込み、
  serialization でも「missing をどう表現するか」（JSON の `null` か、キー省略か）という
  二重の決定が必要になる。「存在しない = missing」は Vector の要素の有無だけで表現でき、
  一般 macro event 層の `ScenarioAssumption` とも設計が揃う。
- **導出値は二重管理より壊れにくい**（ADR 0020 決定 2・ADR 0021 決定 3 と同じ理由）。
  `unit`・`direction`・catalog の `required_concepts`/`optional_concepts`/`guardrails`/
  `horizons` はいずれも #274/#285 の registry または他フィールドから導出し、#275 が独自の
  正本を持たない。
- **hash 自己参照の排除は ADR 0008 の real-rate model artifact と同じ理由**。
  `content_hash` を hash 対象ペイロードに含めると、hash 自身が入力に依存するという循環が
  生じる。
- **assumption_set_hash と content_hash の分離は H-05 を「テストで検証する規約」ではなく
  「関数の戻り値が構造的に満たす性質」にする**。#276 が「applied model input の identity」に
  `japan_fiscal_assumption_set_hash` を使う限り、FRE context の変更が意図せず re-run を
  引き起こすことがない。
- **catalog に family 単位の horizon/persistence 代表値を持たせない判断は、#274 の
  per-(family,model) 粒度の情報をすでに持つ registry と重複させないため**。単一値へ縮約すると、
  静学モデル（IS-LM・AD-AS・Mundell-Fleming）と時間パスを持つモデル（CCC・NK・RBC）を
  同じ horizon として提示してしまう誤読リスクがある。

## 見送りとした選択肢

- **`ScenarioAssumption`（一般 macro event 層、#197）をそのまま Japan Fiscal assumption として
  再利用する**: `target_concepts` が `MACRO_EVENT_TARGET_CONCEPTS`（10 概念）に固定されており、
  Japan Fiscal の 9 concept のうち 7 つ（`:growth_path`・`:productivity_growth`・
  `:government_spending`・`:tax`・`:primary_balance`・`:inflation`・`:cb_jgb_absorption`）は
  対応物を持たない（#274 §2.2「他の 7 概念はイベント層に対応物を持たない」）。`sector`
  （CCC の S1–S5 部門区分）も Japan Fiscal の概念に当てはまらない。ADR 0010 の
  「適用先を外生変数7個に限定する」決定を#275で緩めることになるため、新しい専用型を作った。
- **`magnitude::Union{Float64,Nothing}` を assumption のフィールドとして持つ**: 決定2・
  理由の節で述べた通り、「存在しない = missing」のほうが serialization・construction の
  両方で単純である。
- **FRE のスキーマを DME 内で完全にミラーする**: fiscal-regime-engine は別リポジトリであり、
  そのスキーマ変更のたびに DME 側の型を追随させる結合を持ち込みたくない。Issue #275 scope
  §1 が列挙する最低限のフィールドのみを保持し、FRE 契約を変更しない（#273 non-goal）。
- **family ごとに horizon・persistence の代表値を catalog に持たせる**: 決定7・理由の節の
  通り、per-model の粒度で異なる値を単一値へ縮約すると誤読を招く。
- **primary_balance 等の構造的変換規則（閉じ変数の選び方）を #275 で先取りする**: #274 §5.3
  が定めた「閉じ変数を1本に固定し感応度を記録する」規則は #276（adapter/runner）の実装対象
  であり、#275 は「scenario がどの concept を明示的に持てるか」までを扱う。scenario 自体は
  `:primary_balance` という concept を持てるが、どのモデル変数へどう変換するかは決めない。
- **`assumption_id` の一意性を scenario 内で個別に検証する**: 同一 concept の重複を拒否すれば
  （決定5）、1 scenario 内で同一 concept に複数の `assumption_id` が割り当たることはなく、
  一意性は自動的に保証される。

## 影響

- **`src/scenarios/japan_fiscal_scenario_schema.jl` を新設する**（型 5 種
  `JapanFiscalFREContext`・`JapanFiscalScenarioAssumption`・`JapanFiscalScenarioProvenance`・
  `JapanFiscalScenario`・`JapanFiscalScenarioCatalogEntry`、語彙 2 種、照会/検証/serialization
  API 多数）。`src/DME.jl` の include（`artifacts/json_canonical.jl` の直後）と export のみを
  変更する。
- **#274 の `japan_fiscal_capability.jl`・#285 の `japan_fiscal_claim_contract.jl`・
  モデル方程式・`SimulationResult`・イベント層 API は変更しない**。既存テスト・既存 artifact の
  数値互換に影響しない。
- **#276（model adapter・scenario runner・result artifact）は本ファイルの
  `JapanFiscalScenario`・`japan_fiscal_assumption_set_hash` を入力として使う。** 「applied
  model input の identity」は `japan_fiscal_assumption_set_hash` を用い、FRE context の変更で
  不要な re-run が起きないようにする。
- **#277（E2E / consumer fixture）は本ファイルの `japan_fiscal_scenario_schema_contract()` を
  consumer fixture の一部として使う。** Market Analyzer は Julia 内部型を import せず、この
  Dict と #276 の result artifact のみを consume する。
- **`docs/models/*.md`・#274/#285 の gap register・capability matrix は変更しない**。

## 参考

- [scenario catalog / assumption schema / FRE context 契約](../architecture/japan_fiscal_scenario_schema_contract.md) — 型定義・validation・serialization・catalog の詳細
- [capability / mapping 契約](../architecture/japan_fiscal_scenario_capability.md)（#274） — 55 セルの判定・9 assumption concept・FRE context の役割（本契約の前提）
- [claim-level / coverage 契約](../architecture/japan_fiscal_claim_level_contract.md)（#285） — `H-01`–`H-05` の要件定義元
- [ADR 0020](0020-japan-fiscal-scenario-capability-contract.md) — representability を導出値として強制する決定・FRE context の役割の固定
- [ADR 0021](0021-japan-fiscal-claim-level-contract.md) — downstream handoff requirements・限定的伝播の設計判断
- [ADR 0008](0008-real-rate-model-artifact-export.md) — hash 自己参照排除・RFC 8785 正準化の先例
- [ADR 0010](0010-macro-event-scenario-contract.md) — 適用先を外生変数7個に限定する決定（本契約が Japan Fiscal 専用の型を新設する理由）
