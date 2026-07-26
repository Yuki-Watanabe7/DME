# モデル能力プロファイル・概念定義 metadata

各モデルが内生化する部門・金融機構・期待形成・政策変数・対応 API・実証能力を、LLM や
クロスモデル推論が根拠にできる**機械可読な repository metadata** として提供する層の解説。

> 関連: [クロスモデル推論層の設計](architecture/cross_model_reasoning.md)（Phase 4 の概念対応）・
> [ADR 0006](adr/0006-cross-model-reasoning-contract.md)・[モデル選択ガイド](model_selection_guide.md)・
> [モデル変数と実データ系列のマッピング表](data/variable_mapping.md)・[API リファレンス](api.md)

---

## 1. 目的と設計方針

- 各モデルの能力を **推測で過大申告しない**。未対応は明示的に `false` / `:none` / 空とする。
- 同名変数でも定義が異なれば **同一概念として扱わない**（`definition_key` で等価判定）。
- 既存モデル API（`model_name` / `state_variables` / `control_variables` / `parameters` /
  `steady_state` …）は変更しない。能力 metadata はそれらと並立する読み取り専用層。
- 根拠は docs（モデル節・限界節・`model_selection_guide.md`・`variable_mapping.md`・
  `simulation_outputs.md`）のみ。数値実証結果は含めない。

実装ファイル: [`src/core/model_capabilities.jl`](../src/core/model_capabilities.jl)。
契約 version: `MODEL_CAPABILITY_CONTRACT_VERSION = "model-capability/1.0.0"`。

---

## 2. 型と公開 API

| 型・関数 | 役割 |
|---|---|
| `ModelCapabilityProfile` | 1 モデルの能力プロファイル（時間表現・API・部門・金融商品・会計閉鎖・経済メカニズム・期待/最適化/均衡・実証能力） |
| `ModelConceptDefinition` | 1 変数・概念の定義（安定 id・変数名・定義・単位・stock/flow/rate・時点・集計範囲・内生/外生・観測可能性・proxy 注意） |
| `model_capabilities(model)` | モデル（インスタンスまたは `Symbol`）の `ModelCapabilityProfile` を返す |
| `concept_definitions(model)` | モデルの主要変数の `ModelConceptDefinition` 一覧を返す |
| `supports_api(p, api)` / `has_sector(p, s)` / `has_instrument(p, i)` | プロファイルの述語 |
| `concept_definitions_equivalent(a, b)` | 2 概念定義が真に等価か（`definition_key`・`kind`・`unit`・`timing` の一致） |
| `to_dict` / `to_json` / `*_from_dict` / `*_from_json` | JSON round-trip |
| `coverage_concept_definitions(cov)` | Phase 4 の `ModelConceptCoverage` を Phase 5 の概念定義へ橋渡し |

`model` 引数はモデルインスタンス（`AbstractMacroModel`）でも識別子 `Symbol`
（`:ramsey`, `:rbc`, `:solow`, `:islm`, `:adas`, `:new_keynesian`, `:var`,
`:mundell_fleming`, `:keen`, `:sim`）でもよい。

```julia
using DME
p = model_capabilities(:keen)
supports_api(p, :calibration)      # true（Keen のみ）
has_instrument(p, :debt)           # true
p.equilibrium_concept              # :bistable_with_crisis
p.accounting_closure               # :none

defs = concept_definitions(:sim)
first(defs).concept_id             # :sim_money_stock_H
```

### 固定語彙

| 語彙定数 | 値 |
|---|---|
| `CAPABILITY_TIME_REPRESENTATIONS` | `:static` / `:discrete` / `:continuous` |
| `CAPABILITY_APIS` | `:steady_state` / `:transition_path` / `:simulate` / `:impulse_response` / `:calibration` / `:validation` |
| `CAPABILITY_SECTORS` | `:household` / `:firm` / `:government` / `:bank` / `:central_bank` / `:external` |
| `CAPABILITY_INSTRUMENTS` | `:money` / `:debt` / `:bond` / `:loan` / `:deposit` |
| `CAPABILITY_ACCOUNTING_CLOSURES` | `:none` / `:partial` / `:stock_flow_consistent` |
| `CAPABILITY_TREATMENTS` | `:endogenous` / `:approximate` / `:exogenous` / `:none` |
| `CAPABILITY_EXPECTATIONS` | `:none` / `:static` / `:adaptive` / `:rational` / `:perfect_foresight` |
| `CAPABILITY_OPTIMIZATION` | `:none` / `:household` / `:firm` / `:both` |
| `CAPABILITY_EQUILIBRIUM_CONCEPTS` | `:none` / `:static_equilibrium` / `:saddle_path` / `:balanced_growth` / `:zero_gap` / `:linear_fixed_point` / `:bistable_with_crisis` / `:stock_flow_steady_state` |
| `CONCEPT_KINDS` | `:stock` / `:flow` / `:rate` / `:ratio` / `:index` |
| `CONCEPT_TIMINGS` | `:end_of_period` / `:current_flow` / `:instantaneous` / `:static` |
| `CONCEPT_ENDOGENEITY` | `:endogenous` / `:exogenous` / `:parameter` |
| `CONCEPT_OBSERVABILITY` | `:observable` / `:partially_observable` / `:latent` / `:model_only` |

---

## 3. モデル横断 比較表

対応 API（○=実装、空欄=非対応）:

| モデル | 時間 | steady_state | transition_path | simulate | impulse_response | calibration | validation |
|---|---|:--:|:--:|:--:|:--:|:--:|:--:|
| Ramsey | discrete | ○ | ○ | ○ | | | |
| RBC | discrete | ○ | ○ | | ○ | | |
| Solow | discrete | ○ | ○ | ○ | | | |
| IS-LM | static | ○ | | ○ | | | |
| AD-AS | static | ○ | | ○ | | | |
| New Keynesian | discrete | ○ | | ○ | ○ | | |
| VAR | discrete | ○ | | ○ | ○ | | |
| Mundell-Fleming | static | ○ | | ○ | | | |
| Keen | continuous | ○ | | ○ | ○ | ○ | ○ |
| SIM (SFC) | discrete | ○ | | ○ | ○ | | |

部門・金融・会計・実証:

| モデル | 部門 | 金融商品 | 内生信用 | 会計閉鎖 | 均衡概念 | 推定 | OOS 検証 |
|---|---|---|:--:|---|---|:--:|:--:|
| Ramsey | household, firm | — | | none | saddle_path | | |
| RBC | household, firm | — | | none | saddle_path | | |
| Solow | household, firm | — | | none | balanced_growth | | |
| IS-LM | household, firm, government, central_bank | money | | none | static_equilibrium | | |
| AD-AS | household, firm, government, central_bank | money | | none | static_equilibrium | | |
| New Keynesian | household, firm, central_bank | — | | none | zero_gap | | |
| VAR | （非構造） | — | | none | linear_fixed_point | | |
| Mundell-Fleming | household, firm, government, central_bank, external | money | | none | static_equilibrium | | |
| Keen | household, firm, bank | debt, loan | ○ | none | bistable_with_crisis | ○ | ○ |
| SIM (SFC) | household, firm, government | money | | stock_flow_consistent | stock_flow_steady_state | | |

経済メカニズムの扱い（`:endogenous` / `:approximate` / `:exogenous` / `:none`）:

| モデル | production | employment | income_distribution | prices | monetary_policy | fiscal_policy | external_sector | expectations |
|---|---|---|---|---|---|---|---|---|
| Ramsey | endogenous | none | none | none | none | none | none | perfect_foresight |
| RBC | endogenous | endogenous | approximate | none | none | none | none | rational |
| Solow | endogenous | exogenous | approximate | none | none | none | none | none |
| IS-LM | approximate | none | none | none | endogenous | endogenous | none | none |
| AD-AS | approximate | approximate | none | endogenous | endogenous | endogenous | none | static |
| New Keynesian | approximate | none | none | endogenous | endogenous | none | none | rational |
| VAR | none | none | none | none | none | none | none | none |
| Mundell-Fleming | approximate | none | none | none | endogenous | endogenous | endogenous | none |
| Keen | endogenous | endogenous | endogenous | none | none | none | none | none |
| SIM (SFC) | approximate | endogenous | none | none | none | endogenous | none | none |

> **同名変数の非同一性**: 利子率 `r` は RBC=実質資本限界生産物、IS-LM=名目貨幣市場金利、
> New Keynesian `i`=名目政策金利で、`concept_id`・`definition_key` がそれぞれ異なる。
> `concept_definitions_equivalent` はこれらを **等価と判定しない**。
>
> **実データ接続**: `data_connection` は汎用の `compare_with_data`（出力系列と実データの比較）を
> 指し、全モデルで `true`。一方 `estimation`（推定）・`out_of_sample_validation` は Keen 専用
> パイプライン（`calibrate_keen` / `validate_keen`）のみ `true`。

---

## 4. 既存層との接続（Phase 4 クロスモデル推論）

Phase 4 の `MODEL_CONCEPT_REGISTRY`（`ModelConceptCoverage`、比較軸 × モデルの treatment）と、
本層の `MODEL_CONCEPT_DEFINITION_REGISTRY`（変数単位の概念定義）は
`coverage_concept_definitions(cov)` で橋渡しできる。

```julia
cov = only(model_concept_coverage(model = :keen, concept = :private_debt_credit))
coverage_concept_definitions(cov)   # [:keen_debt_ratio_d]
```

これにより Phase 4 registry を段階的に Phase 5 の概念定義 metadata から参照・整合検証できる。
両 registry の `definition_key` は共通語彙を用い、同名変数の別定義を同一視しない方針を共有する。

---

## 5. 新規モデル追加手順

1. **能力プロファイルを追加**: `src/core/model_capabilities.jl` の
   `MODEL_CAPABILITY_REGISTRY` に `<model> => ModelCapabilityProfile(; …)` を追記する。
   未対応の能力は明示的に `false` / `:none` / 空のままにする（既定値が保守的なので、
   対応する項目だけ埋める）。根拠 docs を `doc_ref` に記す。
2. **型 ↔ 識別子を登録**: `_CAPABILITY_MODEL_SYMBOLS` に `NewModel => :new_model` を追記。
3. **概念定義を追加**: `MODEL_CONCEPT_DEFINITION_REGISTRY` に主要変数の
   `ModelConceptDefinition(; …)` を追記する。`concept_id` は **グローバルに一意**
   （慣例: `<model>_<意味>_<変数>`）。同名変数でも定義が異なるモデルには別 `definition_key`
   を割り当てる。
4. **export を追加**: 新しい公開名を増やす場合は `src/DME.jl` の export ブロックへ。
   registry へ追記するだけなら export 変更は不要。
5. **テスト**: `test/test_model_capabilities.jl` は「全 export 済みモデルが profile を返す」
   「stable id が重複しない」「JSON round-trip」を網羅するため、新モデルは
   `_ALL_MODEL_SYMBOLS` に追加すれば自動的に検証対象になる。
6. **比較表を更新**: 本ドキュメント §3 の表に行を追加する。

---

## 参考

- [クロスモデル推論層の設計](architecture/cross_model_reasoning.md) — Phase 4 の概念対応・mapping 導出
- [Keen–SFC 概念対応・比較レポート](analysis/keen_sfc_comparison.md) — 能力プロファイル・概念定義 metadata を根拠にした 2 モデル比較の実例
- [ADR 0006](adr/0006-cross-model-reasoning-contract.md) — 概念対応・同名非同一性の決定記録
- [モデル選択ガイド](model_selection_guide.md) — モデル横断比較表（§3）
- [モデル変数と実データ系列のマッピング表](data/variable_mapping.md) — 変数定義差・単位・変換
- [出力結果の読み方](simulation_outputs.md) — 水準・対数偏差・水準偏差の別
