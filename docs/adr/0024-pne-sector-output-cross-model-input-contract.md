# ADR 0024: PNE sector-output-path を上流モデル由来入力として受理し、geography を fail closed とし、mapping を DME 側に置き、event registry を経由せずに `AppliedModelInput` で合流させる

- **ステータス**: 採用
- **日付**: 2026-09-28
- **関連Issue**: #280（本決定）・#125（ロードマップ）・後続 #281・#282・#283（実装）・PNE #2 Phase 1.5・PNE #32（producer 契約）・PNE #33（producer fixture）
- **前提ADR**: [ADR 0006](0006-cross-model-reasoning-contract.md)（概念対応の明示・同名変数の非同一視）・[ADR 0008](0008-real-rate-model-artifact-export.md)（RFC 8785 正準化・汎用 JSON Schema バリデータ不使用・hash 自己参照排除）・[ADR 0010](0010-macro-event-scenario-contract.md)（4 層分離・適用先 7 変数・固定順合成・magnitude 捏造禁止）・[ADR 0013](0013-capex-credit-cycle-integration-contract.md)（`SimulationResult` 非変更・metadata 予約キー）・[ADR 0015](0015-macro-event-runtime-contract.md)（失敗 3 層・status 4 値・fail closed・replay 入力の限定）・[ADR 0018](0018-capex-credit-cycle-empirical-runtime-contract.md)（`ext_demand_s` 分割の非識別・助走区間の定常固定）
- **上流の決定**: PNE [ADR 14](https://github.com/Yuki-Watanabe7/production-network-engine/blob/30beab183ef7f2387ce469ae19ad9885f9f55d71/docs/decisions/0014-macro-boundary-is-native-sector-output-not-dynamic-state.md)（macro 境界を native sector output とし、DME 固有の集約・頻度変換・cross-economy transmission を行わない）
- **関連ドキュメント**: [PNE sector-output-path 受け入れ契約](../architecture/pne_sector_output_integration.md)（本 ADR の詳細設計）・[イベント・シナリオ実行層 統合設計](../architecture/macro_event_runtime_integration.md)・[マクロイベント変換契約](../architecture/macro_event_contract.md)・[シナリオ時間軸の意味論](../architecture/scenario_time_semantics.md)

## コンテキスト

PNE Phase 1 で、production network 上の多期間 supply-shock シミュレーションと、その結果を部門別の
実現産出比へ射影する `production-network-sector-output-path/v1` が成立した。この artifact は
`result_type_boundary` で「source data・PNE のシナリオ仮定・PNE のモデル導出結果・下流適用（不在）」の 4 役割を
固定値で分け、geography（`same_economy_only`）・classification（opaque id）・時間（`period_unit` はラベル、
値は baseline 1 期間分に対する比）を必須にしている。PNE は DME 固有の集約・頻度変換・cross-economy
transmission を行わないことを ADR 14 で決めた。

一方、DME 側には次の状態がある。

- イベント実行層（#196–#205）は Observed Event / Interpreted Signal / Scenario Assumption / Applied Model Input の
  4 層を型で分離し、イベント型 10 種・拒否コード 12 種・警告コード 12 種を固定している。
- CCC は米国・四半期・5 部門を基準とし、イベントの適用先を `exogenous_variables(m)` の 7 変数に限っている。
  7 変数に供給能力の入力は無い。
- 現行の PNE real profile は日本 2020 IO・108 部門・年次の baseline 期間である。

この状態で接続を実装すると、次の失敗様式が具体的に起こりうる。

1. **モデル導出結果の観測化**: PNE の産出パスを `ObservedEvent` や `magnitude_source = :observed` の仮定として
   入れると、反実仮想が観測事実として説明・監査される。
2. **geography の黙殺**: 日本の結果を部門ラベルの類似だけで米国 CCC へ入れると、推定していない cross-border
   transmission を数値として提示することになる。
3. **供給ショックの需要ショック化**: CCC に供給能力の外生入力が無いため、「近い変数」である `ext_demand_s` へ
   供給制約の結果を入れると、供給ショックを需要ショックとして扱う代理になる。
4. **event registry の変質**: 上流に観測が存在しない「イベント型」を追加すると、4 層の意味・`event_set_hash`・
   macro-event contract version が動き、既存 artifact の意味が変わる。
5. **暗黙の穴埋め**: unmapped 部門・部分四半期・PNE horizon 後の期間を 0 ショック（比 1）で埋めると、PNE が
   何も述べていない部分について「影響が無い」と主張することになる。
6. **mapping の押し戻し**: DME の 5 部門・四半期への変換を PNE の exporter に求めると、PNE の境界（ADR 14）が
   崩れ、DME のモデル変更が PNE の破壊的変更になる。

これらは実装後には切り分けが困難であり、実装 Issue（#281–#283）の前に契約として固定する必要がある。

## 決定

1. **PNE の産出パスを「upstream model-derived scenario result」として扱い、`L1`・`L2`・event 由来の `L3` の
   いずれにもしない。第 5 の層も追加しない。`L3` と同じ位置に出自の異なる兄弟型 `ModelDerivedInput` を置き、
   `L4`（`AppliedModelInput`）で event 由来の入力と合流させる。**
   `ModelDerivedInput` を `AbstractMacroEvent` の subtype にせず、`map_event`・`validate_event`・
   `observed_events.json` の経路へ入らないことを型で担保する。上流 artifact の identity は
   `UpstreamModelArtifactRef` として分けて持つ（統合設計 §3）。

2. **PNE の結果は、DME 側の mapping artifact と、その `ModelDerivedInput` を実行に含めるという明示的な選択が
   あるときに限りモデルへ適用する。この選択が DME 側のシナリオ仮定であり、PNE の結果そのものを DME の仮定と
   同一視しない。**
   `ModelDerivedInput` は compatibility report が `accepted` の場合にしか構築できない（統合設計 §3.4 `UM-4`）。

3. **PNE v1 artifact の受理は `schema_version` の完全一致とし、schema の制約と `x-semantic-invariants` を Julia で
   再実装する。PNE package を import せず、PNE の検証を呼ばない。decode 不能な文書は例外、decode 可能だが
   `status = unsupported` / error 警告を持つ文書は構造化拒否とする。**
   未知キーを無視せず拒否する（PNE schema は全階層 `additionalProperties: false`）。損失比の許容誤差は PNE と
   同じ `1e-12` とする（統合設計 §5.2）。

4. **上流 artifact の DME 内での正本 identity を、DME が計算する RFC 8785 正準 JSON の SHA-256（`content_hash`）と
   する。PNE 自身の `hash_document` 値と `artifact_id` の導出式は再計算しない。**
   PNE の hash 規則（Python の float 表記に依存する compact JSON）を Julia で再現すると PNE の実装詳細へ結合する。
   ファイルのバイト列 SHA-256 は監査用に保持し hash 対象から除く（統合設計 §5.3、gap `PG-09`）。

5. **geography の identity を `(system, economy_id)` の完全一致のみで判定し、既定を fail closed とする。
   transmission mode を `:same_economy` / `:explicit_cross_economy` / `:hypothetical_override` の 3 値とし、
   mapping artifact に既定値なしで宣言させる。**
   `name`・部門ラベルを比較に用いない。mapping artifact に source / target の geography を明示させ、実体との
   不一致を拒否する（統合設計 §6.1–§6.2）。

6. **`:explicit_cross_economy` の受理先を v1 では空集合とする。transmission artifact の identity は検査するが、
   受理する transmission contract version が無いため常に拒否する。**
   「伝播 artifact が無い」（`geography_mismatch`）と「伝播 artifact はあるが未対応」
   （`cross_economy_transmission_unavailable`）を別コードで区別する。受理先の追加は本 ADR の改訂を要する
   （統合設計 §6.4、gap `PG-03`）。

7. **`:hypothetical_override` を synthetic source（`is_synthetic = true` かつ全部門 `source_data_status = synthetic`）
   に限る。実データの artifact を別経済のモデルへ入れる経路を、どの mode でも作らない。**
   現行の Japan-PNE → US-CCC は、`:same_economy` で `geography_mismatch`、`:explicit_cross_economy` で
   `cross_economy_transmission_unavailable`、`:hypothetical_override` で
   `hypothetical_override_requires_synthetic_source` として拒否され、3 件を negative golden とする（統合設計 §6.3・§6.5）。

8. **v1 で PNE 由来入力を受け付けるモデルを CCC のみとし、CCC でも適用先を `ext_demand_s2` / `ext_demand_s3` への
   派生中間需要チャネル（`:derived_out_of_model_demand`）の 1 種に限る。CCC の他の外生 5 変数、CCC 対応部門自身の
   供給能力、部門産出・総産出は `unmapped_target_concept` とする。他の 10 モデルは `unsupported_target_model` とする。**
   `exogenous_variables(m)` の外へ適用先を広げず、新しい外生変数を追加しない（統合設計 §7.1–§7.3、gap `PG-01`・`PG-08`）。

9. **派生中間需要チャネルを、固定投入係数の下で「CCC のモデル外顧客の実現産出比 × その顧客が target 変数の
   baseline に占める割合」として定義し、受理条件 `DD-1`–`DD-8` を置く。特に、target 製品の生産部門集合
   （producer set）を宣言させ、その全部門が全期間で baseline 産出（比 1）であることを機械的に検査する。**
   producer set が制約されていると、顧客の産出低下は target 製品の供給制約の結果であり需要低下ではないため、
   決定 8 で禁じた「供給ショックの需要ショック化」を裏口から行うことになる（統合設計 §7.4、gap `PG-06`）。

10. **sector / classification の mapping を DME consumer 側の責務とし、DME が所有する versioned な mapping artifact
    （`dme.cross-model-mapping/1.0.0`）で宣言する。classification は `(system, version, level)`・部門は opaque な
    `sector_id` の完全一致で照合し、unmapped source sector を artifact に明示リストとして宣言させる。**
    PNE の exporter へ DME の部門を持ち込まない。one-to-many（1 部門の按分）を v1 では受理しない（統合設計 §8）。

11. **部門集約の weight basis を `:source_baseline_output`（群内正規化）・`:direct_one_to_one`・
    `:declared_target_share`（再正規化しない、`Σ w ≤ 1`）の 3 種とし、CCC は `:declared_target_share` のみを受理する。
    欠落を比 1 で埋めず、`baseline_output` が揃わないときに非加重平均へ落とさない。カバーされない target の割合は
    「本入力の対象外」として記録し、「影響が無い」とは扱わない。**
    `:declared_target_share` の weight は `ext_demand_s` の顧客別構成が識別されない以上、識別仮定として記録する
    （統合設計 §8.3–§8.4、gap `PG-04`）。

12. **時間 mapping の受理を `quarter`（恒等）と `month`（3 か月の算術平均）に限り、`week`・`day`・`year`・
    `baseline_period` を拒否する。month source には四半期初日の `calendar_anchor`（`YYYY-MM-DD`）を必須とし、
    部分四半期を拒否する。PNE horizon 後は、最終四半期で入力部門が回復している場合に限り変化なしとし、
    それ以外は拒否する。**
    PNE の値は「期間合計の実現産出 / baseline 1 期間分」であり、月次 → 四半期の算術平均はこの定義から厳密に
    導かれる。低頻度 → 高頻度の分解・部分期間の外挿・horizon 後の持続仮定はいずれも PNE が述べていない値を
    作るため行わない（統合設計 §9、gap `PG-05`・`PG-10`・`PG-11`）。

13. **DME 時間軸への配置の基準を `Scenario.period_zero` の有無で決め、`ModelDerivedInput` 側で別途選ばせない。
    暦日基準では anchor から `t0` を導き、モデル期基準では `t_start` を明示させる。助走区間への配置を拒否し、
    評価区間を超える末尾は切り捨てて警告する。**
    ADR 0015 決定 5 の 2 基準をそのまま踏襲し、1 シナリオ内での基準の混在を構造的に起こさない（統合設計 §9.5）。

14. **event registry を経由しない。`map_model_derived_input` と CCC 用の宣言的 registry
    （`ccc-cross-model-mapping/1.0.0`）で `AppliedModelInput` を生成し、既存の `schedule_events` /
    `compose_exogenous_paths`（全順序・固定順合成）を 1 回だけ呼ぶ。実行入口は新設の
    `run_cross_model_scenario` とし、`run_scenario`・`map_event`・`Scenario` を変更しない。**
    `AppliedModelInput` の型は変更せずに再利用する。上流由来入力は `"xm-"` 接頭辞の ID を持ち、event 由来との
    ID 衝突は `duplicate_dropped` に委ねず実行前に拒否する（統合設計 §10）。

15. **cross-model の拒否・警告を `MACRO_EVENT_*` とは独立の語彙（拒否 30 種・警告 10 種）で持ち、実行ステータスは
    既存の 4 値を再利用する。`on_unmapped = :warn` は cross-model の拒否を緩めない。**
    `MACRO_EVENT_REJECTION_CODES`・`MACRO_EVENT_WARNING_CODES` を変更しない（ADR 0015 決定 6 の「実装が新しい
    コードを追加しない」を守る）。`ModelDerivedInput` は特定モデル向けに構築されたものであり、写せないことは
    入力集合の構成誤りだからである（統合設計 §10.5・§11）。

16. **provenance chain を DME 結果 → `AppliedModelInput` → `ModelDerivedInput` → mapping artifact / compatibility
    report → PNE bridge（`content_hash`）→ PNE dynamic artifact・scenario / policy / config hash → PNE input hash と
    source provenance とし、DME が検証するのは PNE bridge までとする。`SimulationResult` を変更せず、cross-model の
    metadata 予約キー 10 個を追加する。**
    PNE dynamic artifact 以降の hash は PNE が付与した値をそのまま保持して辿れるようにし、DME は再計算しない
    （統合設計 §12.1–§12.3）。

17. **cross-model 実行の成果物を別 schema（`dme.cross-model-scenario/1.0.0`）で保存し、既存の `scenario.json` を
    書かない。replay の入力を `cross_model_scenario.json` に限り、PNE artifact のバイト列を必要としない。PNE
    artifact が与えられた場合に限り再導出検証を行う。**
    既存 `replay_scenario` が上流入力を欠いたまま再実行することを、ファイルの不在によって構造的に防ぐ
    （既存関数を変更しない）（統合設計 §12.4）。

18. **後続の実装 Issue #281・#282・#283 を `PN-1`–`PN-3` として、配置・依存・本書による明確化つきで確定する。**
    Issue 本文と本 ADR・統合設計が異なる箇所は、Issue ごとに「本書による明確化」として明示する（統合設計 §16）。

## 1. なぜ第 5 の層ではなく `L3` の兄弟型にするか

| 方式 | 帰結 |
|---|---|
| `MACRO_EVENT_LAYERS` に `:model_derived` を追加する | 4 層の定義（観測 → 解釈 → 仮定 → 適用）は「事象がモデル入力になるまでの変換の段」であり、上流モデル結果は変換の段ではなく**出自**が違う。段の列へ出自を混ぜると、`EventProvenance.layer` の検査・拒否コードの `layer`・契約文書の全体が意味を変える |
| `ScenarioAssumption` を再利用し `magnitude_source = :derived` とする | `event_type`（10 種）に正しい値が無い。`:derived` は「観測値から導出した」を意味し、上流モデルの反実仮想を表さない。`event_set_hash` の対象に入り、イベント集合の identity が変わる |
| **`L3` と同じ位置の兄弟型 `ModelDerivedInput`（採用）** | **4 層の定義・型・hash を変えずに、「シナリオへ入れる入力の仮定」という位置だけを共有する。`L4` 以降は同じ型・同じ合成規則で扱える** |

`L4`（`AppliedModelInput`）を共有するのは、`L4` が「特定モデルの変数へ適用された変更」という**出自に依存しない**
定義を持ち、合成・ログ・実行の基盤がすべて `L4` を単位にしているためである。`L4` を分けると固定順合成を
二重に実装することになり、ADR 0015 §5 が避けた「同じシナリオが経路によって別の数値を返す」状態が生じる。

## 2. なぜ Japan-PNE → US-CCC をどの mode でも拒否するか

| mode | 許した場合に生じる主張 |
|---|---|
| `:same_economy` | 日本の供給網の結果が米国の供給網の結果であるという主張 |
| `:explicit_cross_economy` | 伝播の機構・根拠・version を持つ artifact が無いまま、伝播を推定したという主張 |
| `:hypothetical_override`（実データ） | 「仮想」と表示しても、実データの日本の結果を米国のモデルへ通した数値は「日本の途絶が米国へ及ぼす影響」と読まれる |

Issue #280 は cross-border transmission を推測しないことを明示している。3 つの mode すべてで拒否コードを
分けて返すことで、「なぜ拒否されたか」と「何があれば受理されうるか」（同一経済圏の profile、transmission
契約、synthetic 入力）を利用者が区別できる。

positive E2E（#283）は synthetic fixture を `:hypothetical_override` で通す。fixture の geography を CCC と同じ
`ISO 3166-1 alpha-2 / US` に偽装する方式は採らない。synthetic network に実在経済の identity を付けると、
PNE の fixture 規律（架空であることを識別子で示す）を破り、テストのために geography guard を弱めたのと
同じことになる。

## 3. なぜ CCC の適用先を派生中間需要チャネルだけにするか

PNE の値は供給制約の下流伝播の**結果**（部門の実現産出比）である。CCC の外生 7 変数のうち、供給側の結果を
受け取れるものは無い。

- `ai_exp`（期待）・`capex_plan_shock_ex`（計画の意思決定）・`price_s1`（価格）・`spread_shock_ex` /
  `policy_rate`（金融）は、実現産出比とは別の量である。
- `ycap_s`（供給能力）は内生であり、外生入力の口が無い。
- `ext_demand_s`（モデル外需要）は需要側の量である。

ただし `ext_demand_s` は「本モデル外の需要（スマートフォン・自動車等）」であり、固定投入係数の下では、
モデル外の顧客部門の産出が下がればその顧客の投入需要も同率で下がる。これは PNE 自身が内部で用いる
Leontief 型の固定係数と同じ仮定であり、供給ショックの**需要ショック化ではなく**、顧客側の供給制約が
その顧客の**投入需要**を下げるという別の量の導出である。

この読みが成立しない唯一の場合は、顧客の産出低下が target 製品そのものの供給不足による場合である。
producer set の産出が baseline のままであることを要求（`DD-6`）すれば、この場合を機械的に排除できる。
producer set の宣言の完全性は DME から検証できないため、宣言として記録し gap `PG-06` とする。

CCC 対応部門自身の供給制約（例: 半導体部門の産出制約）は、PNE の最も直接的な用途だが、CCC には受け取る口が
無い。これを `ext_demand_s` や `capex_plan_shock_ex` へ寄せず、gap `PG-01` として記録する。新しい外生変数の
追加は #282 の Non-goal であり、CCC のモデル変更として別の ADR を要する。

## 4. なぜ `:declared_target_share` を再正規化しないか

`ext_demand_s` のうち mapping がカバーする顧客の割合が `Σ w_j < 1` のとき、`Σ w_j` で割って正規化すると、
カバーされない需要（輸出・他の顧客・残差成分）がカバーされた顧客と同じ率で変化すると仮定することになる。
これは PNE が何も述べていない部分への外挿である。

逆に `Σ w_j < 1` を拒否すると、国内中間取引のネットワークが輸出等を含まない以上、このチャネルはほぼ使えなく
なる。一方で拒否しても、再正規化しないことと uncovered share の記録以上の安全性は得られない。

したがって、再正規化せず、uncovered share を `:not_covered_by_upstream_input` として記録・警告し、説明では
「covered share に限った寄与であり、残りは本入力の対象外」と述べることを義務づける。「影響が無い」とは述べない。

## 5. なぜ月次 → 四半期は平均で、年次 → 四半期は拒否か

PNE の 1 期間は source network の baseline 期間そのもので、値は「その期間の実現産出 / baseline 1 期間分」で
ある。月次 network では baseline が毎月同じ「1 か月分」なので、四半期の実現産出 / 四半期 baseline
（= 3 か月分）は 3 か月の比の算術平均に厳密に一致する。これは近似でも仮定の追加でもない。

年次 → 四半期は、年の中で損失がどの四半期に生じたかを決める必要があり、その情報は artifact に無い。PNE 自身が
年次表を月次へ按分しない（期内プロファイルを捏造しない）ことを契約にしており、DME も同じ原理に従う。
週次は四半期境界を跨ぐ週の按分規則を、日次は日数規約を要するため、v1 では定めずに拒否する（`PG-05`）。

## 6. なぜ event registry を経由せず、`run_scenario` も変えないか

| 候補 | 不採用の理由 |
|---|---|
| 新イベント型を追加する | §1。上流に観測の無い「イベント型」は 4 層の前提を崩す。`MACRO_EVENT_TYPES` と `event_set_hash` の意味が動く |
| 既存イベント型へ変換できる場合だけ event path を使う | 派生中間需要は需要見通しの改定でも受注取消でもない。型名が意味を誤って伝え、同じ入力が条件によって別の経路・ログ・hash を持つ |
| `run_scenario` に上流入力の引数を追加する | 引数の有無で `ScenarioRun` の意味・拒否コードの集合・保存形式が変わる。既存呼び出し側（Sc0–Sc4 の互換検証・event-driven デモ・replay）への影響範囲の検証が必要になる |
| `Scenario` に上流入力のフィールドを追加する | `scenario_from_dict` は未知キーを拒否する fail closed decode であり、`dme.scenario/1.0.0` の schema・`scenario_content_hash` を変えることになる |
| **新しい入口 `run_cross_model_scenario` + `L4` 以降の再利用（採用）** | **既存 API・schema・hash を一切変えず、固定順合成・実行・監査の基盤だけを共有する。`xs` が空のとき `run_scenario` と bit 一致することを回帰テストで固定できる** |

## 理由

- **観測とモデル導出を型で分けた**（決定 1・2）: 文書上の規律ではなく、`ModelDerivedInput` を
  `AbstractMacroEvent` にしないことで、PNE の結果を観測・解釈・event 仮定として扱う経路を**書けなくした**。
- **fail closed を geography の既定にし、例外経路を synthetic に限った**（決定 5–7）: 名称の一致・分析者の
  宣言だけで経済圏の違いを越えられる経路を残さない。Japan → US は 3 mode すべてで別コードの拒否になる。
- **代理変数への寄せを禁じ、成立する 1 チャネルだけを条件付きで開いた**（決定 8・9）: 「近い変数」へ入れる
  ことを禁じつつ、固定係数の下で正しく導出できる量（モデル外顧客の投入需要）だけを受理し、その成立条件を
  機械的に検査する。
- **mapping を DME 側に置き、欠損・範囲外を埋めない**（決定 10–13）: PNE の境界（ADR 14）を尊重し、DME の
  モデル変更が PNE の破壊的変更にならない。0 ショック・比 1・非加重平均・外挿という「PNE が述べていない値」を
  作る経路をすべて拒否か明示記録にした。
- **既存資産を変更しなかった**（決定 14–17）: 4 層・イベント型・拒否/警告コード・`Scenario`・`run_scenario`・
  `AppliedModelInput`・`scenario.json`・`SimulationResult`・CCC の外生変数を変更せず、新規の型・入口・語彙・
  metadata 予約キー・成果物 schema の追加だけで成立させた（ADR 0013・0015 と同方針）。
- **できないことをできないと言う設計を維持した**: CCC 対応部門自身の供給制約・cross-economy transmission・
  日次/週次/年次 source・未回復パス・他の 10 モデルを「後で足す」のではなく gap register（`PG-01`–`PG-11`）と
  拒否コードとして出力へ現れるようにした。

## 見送りとした選択肢

- **PNE の結果を `ObservedEvent` として取り込む**: 反実仮想が観測事実として監査・説明される（決定 1）。
- **新しいイベント型 `:UpstreamSupplyShock` を追加する**: §1・§6。
- **`ScenarioAssumption` を `magnitude_source = :derived` で再利用する**: §1。
- **Japan-PNE を部門ラベルの類似で US-CCC へ対応付ける**: cross-border transmission の推測になる（決定 5・7）。
- **`:hypothetical_override` を実データにも許す**: §2。
- **positive E2E のために fixture の geography を US に偽装する / CCC の target profile を差し替え可能にする**: §2。
- **CCC 対応部門の供給制約を `ext_demand_s` の低下として入れる**: 供給ショックの需要ショック化（§3）。
- **CCC 対応部門の供給制約を `capex_plan_shock_ex` の低下として入れる**: 供給制約を `S1` の意思決定として扱う代理（§3）。
- **PNE の `aggregate_path` を RBC / Solow の TFP ショックとして入れる**: 内生的な結果を外生プリミティブとして再度モデルへ通す代理（統合設計 §7.1）。
- **CCC に供給能力の外生変数を追加する**: #282 の Non-goal。CCC のモデル変更として別 ADR を要する（`PG-01`）。
- **`:declared_target_share` を再正規化する / `Σ w < 1` を拒否する**: §4。
- **`baseline_output` が揃わないときに非加重平均へ落とす**: PNE の `aggregate_path` と同じく、重みの無い平均は別の量である。
- **年次 source を四半期へ均等按分する**: 期内プロファイルの捏造（§5）。
- **部分四半期を残りの月から外挿する / 欠けた月を比 1 で埋める**: PNE が述べていない値を作る（決定 12）。
- **PNE horizon 後を最終値の保持・baseline への復帰で埋める**: 持続・回復の仮定を DME が暗黙に置くことになる（決定 12）。
- **PNE の `hash_document` を Julia で再現する**: PNE の実装詳細（Python の float 表記）への結合（決定 4）。
- **mapping を PNE の export config へ持ち込む**: PNE ADR 14 の境界を崩し、DME の変更が PNE の破壊的変更になる（決定 10）。
- **cross-model の拒否コードを `MACRO_EVENT_REJECTION_CODES` へ追加する**: ADR 0015 決定 6 の固定集合を変える。語彙を分ければ event 側の意味は変わらない（決定 15）。
- **`on_unmapped = :warn` で cross-model の写せない入力を落として実行する**: 部分実行が「上流入力がすべて適用された」と読まれる（決定 15）。
- **`replay_scenario` に cross-model 成果物の検出を追加する**: 既存関数の変更が必要になる。`scenario.json` を書かなければ同じ安全性が得られる（決定 17）。

## 影響

- **既存コードへの影響**: 無し（本 ADR は設計のみ）。後続の実装でも `src/scenarios/` への新規ファイル追加と
  `src/DME.jl` の include / export 追加のみを想定し、既存の型・関数・定数・schema を変更しない。
- **#281（`PN-1`）**: 受理・compatibility report・mapping artifact・target profile・`X3` を実装する。PNE の
  schema と fixture を vendor し `MANIFEST.json` で固定する。
- **#282（`PN-2`）**: `ModelDerivedInput`・`CCC_CROSS_MODEL_MAPPING_RULES`・`map_model_derived_input`・
  `run_cross_model_scenario`・保存・replay を実装する。CCC の適用先は派生中間需要チャネルのみ。
- **#283（`PN-3`）**: PNE #33 の producer 経路による synthetic fixture の positive E2E、Japan → US の 3 コードの
  negative golden、drift 検出、PNE bytes 無しの replay を固定する。
- **LLM 説明層**: [llm_safety.md](../llm_safety.md) に §2.9（上流モデル由来入力固有の禁止解釈）と §5.6
  （チェックリスト）を追加する。
- **PNE 側**: 変更を求めない。PNE が将来 artifact 自身の hash、binding input / 供給元情報、cross-economy
  transmission を契約へ加えた場合、それぞれ `PG-09`・`PG-06`・`PG-03` を解消する DME 側の version 追加の対象になる。

## 参考

- [PNE sector-output-path 受け入れ契約](../architecture/pne_sector_output_integration.md) — 本 ADR の詳細設計
- [イベント・シナリオ実行層 統合設計](../architecture/macro_event_runtime_integration.md) — `L4`・固定順合成・失敗 3 層・replay
- [マクロイベント変換契約](../architecture/macro_event_contract.md) — 4 層・適用先 7 変数・`unmapped_target`
- [シナリオ時間軸の意味論](../architecture/scenario_time_semantics.md) — 2 基準・内部時刻
- [部門別CAPEX・信用循環モデル 部門境界と変数定義](../models/capex_credit_cycle_sectors_variables.md) — `ext_demand_s` の定義
- [ADR 0015: イベント・シナリオ実行層の統合実装契約](0015-macro-event-runtime-contract.md)
- [ADR 0018: 部門別CAPEX・信用循環モデルの実証実装契約](0018-capex-credit-cycle-empirical-runtime-contract.md) — 決定 7（`ext_demand_s` 分割の非識別）
- PNE: [sector output path contract](https://github.com/Yuki-Watanabe7/production-network-engine/blob/30beab183ef7f2387ce469ae19ad9885f9f55d71/docs/sector-output-path-contract.md)・[ADR 14](https://github.com/Yuki-Watanabe7/production-network-engine/blob/30beab183ef7f2387ce469ae19ad9885f9f55d71/docs/decisions/0014-macro-boundary-is-native-sector-output-not-dynamic-state.md)
