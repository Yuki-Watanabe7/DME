# Japan Fiscal Scenario Lab — scenario catalog / explicit assumption schema / FRE context 契約

Japan Fiscal Scenario Lab（[Issue #273](https://github.com/Yuki-Watanabe7/DME/issues/273)）で、
「observed context（FRE snapshot）と明示的 Scenario Assumption を混同しない、versioned /
serializable / deterministic な入力契約」を実装する。[Issue #275](https://github.com/Yuki-Watanabe7/DME/issues/275)
の成果物であり、[capability / mapping 契約](japan_fiscal_scenario_capability.md)（#274）・
[claim-level / coverage 契約](japan_fiscal_claim_level_contract.md)（#285）の確定を前提とする。
model adapter・scenario runner・result artifact（#276）と E2E / consumer fixture（#277）はこの
scenario 型を入力として進める。

> 関連: [ADR 0022](../adr/0022-japan-fiscal-scenario-schema-contract.md)（決定記録）・
> [capability / mapping 契約](japan_fiscal_scenario_capability.md)（#274）・
> [claim-level / coverage 契約](japan_fiscal_claim_level_contract.md)（#285）・
> [ADR 0020](../adr/0020-japan-fiscal-scenario-capability-contract.md)・
> [ADR 0021](../adr/0021-japan-fiscal-claim-level-contract.md)

実装ファイル: [`src/scenarios/japan_fiscal_scenario_schema.jl`](../../src/scenarios/japan_fiscal_scenario_schema.jl)。
契約 version: `JAPAN_FISCAL_SCENARIO_SCHEMA_VERSION = "japan-fiscal-scenario-schema/1.0.0"`。

---

## 1. この文書が決めること・決めないこと

決めること。

- FRE snapshot を保持する型（`JapanFiscalFREContext`）と、明示的 assumption を保持する型
  （`JapanFiscalScenarioAssumption`）を分離すること。
- 5 scenario family を `japan_fiscal_family_spec`（#274）から導出する catalog
  （`JapanFiscalScenarioCatalogEntry`）。
- assumption の magnitude における 0 と missing の区別の方法。
- `magnitude_source` の必須化と `:external_belief` の拒否。
- scenario artifact の identity（`JapanFiscalScenarioProvenance`）と content hash の構成。
- JSON serialization の fail closed decode 契約。

決めないこと。

- モデル方程式の改造・#274/#285 の registry の変更（#273 non-goal）。
- model adapter・scenario runner・result artifact の実装（#276）。
- primary balance 等の構造的変換規則（閉じ変数の選択。#274 §5.3 が定義し #276 が実装する）。
- FRE（fiscal-regime-engine）側のスキーマ・契約（#273 non-goal。DME は別リポジトリのスキーマを
  所有しない）。
- fixture・E2E・Market Analyzer handoff（#277）。

---

## 2. 層構造

```text
FRE Current Snapshot（別リポジトリ）
  └─ JapanFiscalFREContext          ← observed_context_only。magnitude を計算する関数の引数に現れない
JapanFiscalScenarioAssumption（9 assumption concept。#274）
  └─ JapanFiscalScenario            ← family・FRE context（任意）・assumption 集合・provenance
       └─ #276 model adapter        ← japan_fiscal_model_mapping(family, model) で representability を判定
            └─ #276 result artifact ← japan_fiscal_coverage(family, model) を保持（#285）
```

`JapanFiscalScenario` は**モデルを保持しない**。family と model の対応は #274 の
`japan_fiscal_model_mapping(family, model)` を都度引く（一般 macro event 層の `Scenario` が
`model::Symbol` だけを保持し、モデルインスタンスを実行時に受け取るのと同型の設計）。

---

## 3. FRE context contract

`JapanFiscalFREContext` は fiscal-regime-engine の current snapshot を保持する **observed
context** である。`JAPAN_FISCAL_FRE_CONTEXT_ROLE = :observed_context_only`（#274）を型として
体現する。

### 3.1 フィールド

| フィールド | 型 | 内容 |
|---|---|---|
| `snapshot_id` | `String` | FRE 側の snapshot identity |
| `as_of` | `Date` | snapshot の as-of 日付 |
| `vintage_basis` | `String` | vintage の基準（FRE 側の識別子） |
| `regime_determination` | `Symbol` | `:primary` / `:ambiguous` / `:unavailable` |
| `primary_regime` | `Union{String,Nothing}` | `regime_determination === :primary` のときのみ非 `nothing` |
| `regime_affinity` | `Dict{String,Float64}` | archetype 名 => affinity |
| `regime_share` | `Dict{String,Float64}` | archetype 名 => share |
| `regime_confidence` | `Union{Float64,Nothing}` | |
| `dimension_score` | `Dict{String,Float64}` | dimension 名 => score（5 dimensions） |
| `constraint_pressure` | `Union{Float64,Nothing}` | |
| `dominant_drivers` | `Vector{String}` | |
| `data_quality_score` | `Union{Float64,Nothing}` | |
| `methodology_version` | `String` | |
| `policy_version` | `String` | |
| `notes` | `String` | 表示専用。identity 対象外 |

`regime_affinity`・`regime_share`・`regime_confidence`・`dimension_score`・
`constraint_pressure`・`data_quality_score` の 6 フィールドは、#274 の
`JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_INPUT_FIELDS`（`"regime_affinity"`・`"regime_share"`・
`"regime_confidence"`・`"dimension_score"`・`"constraint_pressure"`・`"data_quality_score"`）と
1:1 対応する。これらはこの型にのみ存在し、`JapanFiscalScenarioAssumption` の construction
引数には一切現れない（テストで検査する）。

### 3.2 DME が FRE のスキーマを所有しない、という制約

fiscal-regime-engine（FRE）は別リポジトリであり、DME はその契約を変更しない（#273
non-goal）。`JapanFiscalFREContext` は Issue #275 scope §1 が列挙する最低限のフィールド
（identity / as-of / vintage basis・`primary`/`ambiguity`/`unavailable`・Constraint
Pressure・5 dimensions・dominant drivers・data quality・methodology・policy version）のみを
保持する。FRE 側のスキーマが増えても、DME 側の型を追随させる結合を持ち込まない。

### 3.3 identity

`japan_fiscal_fre_context_identity(context)` が `"sha256:…"` 形式の identity を返す。
RFC 8785 正準 JSON（`artifacts/json_canonical.jl`）+ SHA-256 であり、`notes` を除く全フィールドを
対象とする。`dominant_drivers` は整列してから正準化するため入力順に依存しない。

---

## 4. explicit assumption schema

`JapanFiscalScenarioAssumption` は 1 つの明示的 Scenario Assumption を保持する。

### 4.1 フィールド

| フィールド | 型 | 内容 |
|---|---|---|
| `assumption_id` | `String` | |
| `concept` | `Symbol` | `JAPAN_FISCAL_ASSUMPTION_CONCEPTS`（#274。9 概念） |
| `magnitude` | `Float64` | 常に有限。単位は概念の `basis`/`unit` に従う |
| `magnitude_source` | `Symbol` | `MACRO_EVENT_MAGNITUDE_SOURCES` |
| `notes` | `String` | |

`unit`（`japan_fiscal_assumption_concept(concept).unit`）と `direction`（`sign(magnitude)`
から導出、`:up`/`:down`/`:none`）はフィールドとして保持しない。二重管理を避けるための設計判断
であり、`to_dict` の出力には両方を含める（consumer が Julia 型を持たずに読めるようにする）。

### 4.2 0 と missing の区別

`magnitude` は常に有限の `Float64` であり、欠測を表す `nothing` を持たない。「この concept
について assumption を置いていない」は、`JapanFiscalScenario.assumptions` にその concept の
`JapanFiscalScenarioAssumption` が**存在しないこと**で表す。`magnitude = 0.0` で存在する
assumption は「変化なしという明示的な主張」であり、両者は construction・serialization の
いずれでも混同されない。

```julia
# tax は明示的に「変化なし」。government_spending は明示していない（missing）。
tax_zero = JapanFiscalScenarioAssumption(;
    assumption_id = "tax-zero", concept = :tax, magnitude = 0.0,
    magnitude_source = :assumed_default,
)
sc = JapanFiscalScenario(;
    scenario_id = "sc-1", family = :fiscal_consolidation, provenance = prov,
    assumptions = [tax_zero],
)
# to_dict(sc)["assumptions"] は tax のみを含み、government_spending は現れない。
```

### 4.3 magnitude_source の検査（`H-04`）

`magnitude_source` は `MACRO_EVENT_MAGNITUDE_SOURCES`（マクロイベント変換契約）のいずれかを
要求し、`japan_fiscal_magnitude_source_allowed`（#274）が `false` を返す値
（`JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_SOURCES = (:external_belief,)`）は construction 時に
`ArgumentError` で拒否する。#274 が固定した禁止判定をそのまま呼び出すだけであり、#275 で
新しい判定基準を作らない。

---

## 5. JapanFiscalScenario

### 5.1 construction 時の検証

- `family` は `JAPAN_FISCAL_SCENARIO_FAMILIES` のいずれか。
- 各 `assumptions[i].concept` は `japan_fiscal_family_spec(family)`（#274）の
  `required_concepts ∪ optional_concepts` に含まれなければならない。含まれない concept は
  黙って無視せず `ArgumentError` で拒否する。
- 同一 `concept` を複数の assumption で重複して主張できない。
- `assumptions` が空でも正当な scenario である（baseline 相当）。
- `fre_context` は `nothing` であってもよい（observed context 無しの scenario は正当）。

model 別の unsupported 判定（ある model がある concept を受け取れるか）は #274 の
`japan_fiscal_unsupported_concepts(family, model)` が引き続き担う。#275 は「family として
扱う concept かどうか」までを検証し、model 別の判定を再実装しない。

### 5.2 FRE context と assumption 集合の分離（`H-05`）

2 種類の hash を分離する。

| 関数 | 対象 | 用途 |
|---|---|---|
| `japan_fiscal_assumption_set_hash(scenario)` | `assumptions` のみ | #276 の「applied model input」の identity |
| `japan_fiscal_scenario_content_hash(scenario)` | `fre_context` の identity・`assumption_set_hash`・identity 対象 provenance | scenario 全体の identity |

`japan_fiscal_assumption_set_hash` は `fre_context` を含まないため、FRE context だけを変えても
値は変わらない。#276 が「applied model input」の identity にこの hash を使う限り、FRE context の
更新が意図せず re-run を引き起こすことはない。

```julia
sc_ctx1 = JapanFiscalScenario(; scenario_id="sc", family=:fiscal_consolidation,
    provenance=prov, fre_context=ctx1, assumptions=[a])
sc_ctx2 = JapanFiscalScenario(; scenario_id="sc", family=:fiscal_consolidation,
    provenance=prov, fre_context=ctx2, assumptions=[a])

japan_fiscal_assumption_set_hash(sc_ctx1) == japan_fiscal_assumption_set_hash(sc_ctx2)  # true
japan_fiscal_scenario_content_hash(sc_ctx1) == japan_fiscal_scenario_content_hash(sc_ctx2)  # false
```

両 hash とも RFC 8785 正準 JSON + SHA-256 とし、`assumptions` は `assumption_id` 昇順に整列
してから正準化する（入力順・`Vector` の反復順に依存しない）。

---

## 6. provenance / identity（`H-02`）

`JapanFiscalScenarioProvenance` は **identity 対象**と **volatile（identity 非対象）** を
フィールドとして分離する。

| 区分 | フィールド |
|---|---|
| identity 対象 | `schema_version`・`capability_contract_version`（#274）・`claim_contract_version`（#285）・`assumption_source` |
| volatile | `created_at`・`created_by` |

`content_hash` 自身は `JapanFiscalScenarioProvenance` のフィールドとして持たない（hash
自己参照を避ける。[ADR 0008](../adr/0008-real-rate-model-artifact-export.md) と同じ設計判断）。
`japan_fiscal_scenario_content_hash` が別関数として計算し、`to_dict(scenario)` の出力にのみ
計算結果を含める。

scenario artifact の identity には `JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION`（#274）と
`JAPAN_FISCAL_CLAIM_CONTRACT_VERSION`（#285）の**両方**を含める。claim の意味論が変わった
ときに、既存 artifact と新 artifact を `content_hash` から区別できる。

`assumption_source`（scenario 全体の作成経路。`JAPAN_FISCAL_ASSUMPTION_SOURCES = (:user,
:preset, :fixture, :analysis)`）は `magnitude_source`（個々の assumption の数値の出所。
#274 の `MACRO_EVENT_MAGNITUDE_SOURCES`）とは別の語彙である。

---

## 7. scenario catalog（`H-01`）

`japan_fiscal_scenario_catalog_entry(family)` が catalog entry を構築する。
`required_concepts`・`optional_concepts`・`guardrails`・`display_name`・`doc_ref` は
`japan_fiscal_family_spec(family)`（#274）から**そのまま**引き、独自に再定義しない。この一致は
`japan_fiscal_scenario_schema.jl` の load 時 invariant として検査する
（[ADR 0021](../adr/0021-japan-fiscal-claim-level-contract.md) と同じ、テストより強い保証。
パッケージ読み込み時に落ちる）。

catalog が新たに追加するのは、以下の**導出**フィールドのみである。

| フィールド | 導出元 |
|---|---|
| `concept_units` | `japan_fiscal_assumption_concept(concept).unit`（#274） |
| `compatible_models` | `japan_fiscal_implementation_candidates(family)`（#274） |
| `horizons` | `japan_fiscal_model_mapping(family, model).inputs[].horizon` の distinct 集合（`:not_accepted` の入力は除く） |
| `unsupported_channel_ids` | `japan_fiscal_channels(; family, status=:unsupported)`（#285） |

family 単位の「代表的な horizon・persistence」という単一値は catalog に持たせない。
per-(family, model) の horizon はすでに #274 の `JapanFiscalInputMapping.horizon` に存在し、
persistence（時間形状）の選択は #276（adapter/runner）の責務である。単一値へ縮約すると、
静学モデル（IS-LM・AD-AS・Mundell-Fleming）と時間パスを持つモデル（CCC・NK・RBC・Solow）を
同じ horizon として提示してしまう誤読リスクがある。

---

## 8. serialization（fail closed decode）

`to_dict`/`to_json`（一方向）と `japan_fiscal_*_from_dict`（round trip）を、一般 macro event 層
（`scenario_serialization.jl`、Issue #203）と同じ fail closed decode 契約で実装する。

- 必須キーの欠落・未知キーの混入は、欠損/余剰キー名を列挙した `ArgumentError`。
- `content_hash`・`assumption_set_hash`・`fre_context` の `context_identity`・assumption の
  `unit`/`direction` について、読み込んだ値と再計算した値の一致を検査する（不一致は
  `ArgumentError`）。改変された artifact を気付かずに読み込む経路を作らない。
- `assumptions` が空の scenario も正当に round trip する。

```julia
json_str = to_json(scenario)
back = japan_fiscal_scenario_from_dict(JSON3.read(json_str))
japan_fiscal_scenario_content_hash(back) == japan_fiscal_scenario_content_hash(scenario)  # true

# 改変されたJSONは拒否される
tampered = JSON3.read(json_str) |> Dict  # 概念的な例。実際は DME._jf_json_to_plain を使う
tampered["content_hash"] = "sha256:" * "0"^64
japan_fiscal_scenario_from_dict(tampered)  # ArgumentError
```

---

## 9. 後続 Issue への引き継ぎ

| Issue | 本契約から引き継ぐもの |
|---|---|
| #276（model adapter / scenario runner / result artifact） | `JapanFiscalScenario`・`japan_fiscal_assumption_set_hash`（applied model input の identity）・`japan_fiscal_family_spec`/`japan_fiscal_model_mapping` との接続点・primary balance 等の構造的変換は #276 が実装する |
| #277（E2E / consumer fixture） | `japan_fiscal_scenario_schema_contract()`（Market Analyzer が consume する単一 Dict）・fail closed decode の negative fixture candidate（未知キー・hash 改変・forbidden magnitude source） |

`japan_fiscal_scenario_schema_contract()` は本契約全体を 1 つの `Dict{String,Any}` として
返す。Market Analyzer は Julia 内部型を import せず、この Dict と #274
`japan_fiscal_capability_matrix()`・#285 `japan_fiscal_downstream_contract()`・#276 の result
artifact のみを consume する。

---

## 10. 公開 API

| 関数・定数 | 役割 |
|---|---|
| `JAPAN_FISCAL_SCENARIO_SCHEMA_VERSION` | 契約 version |
| `JAPAN_FISCAL_FRE_REGIME_DETERMINATIONS` | `:primary`/`:ambiguous`/`:unavailable` |
| `JAPAN_FISCAL_ASSUMPTION_SOURCES` | `:user`/`:preset`/`:fixture`/`:analysis` |
| `JapanFiscalFREContext` | FRE snapshot の observed context |
| `japan_fiscal_fre_context_identity(context)` | FRE context の identity hash |
| `JapanFiscalScenarioAssumption` | 明示的 assumption 1 件 |
| `japan_fiscal_assumption_direction(a)` / `japan_fiscal_assumption_unit(a)` | 導出フィールド |
| `JapanFiscalScenarioProvenance` | identity / creation metadata |
| `JapanFiscalScenario` | scenario 本体（family・context・assumptions・provenance） |
| `japan_fiscal_assumption_set_hash(scenario)` | assumption 集合のみの hash（applied model input の identity） |
| `japan_fiscal_scenario_content_hash(scenario)` | scenario 全体の identity |
| `JapanFiscalScenarioCatalogEntry` / `japan_fiscal_scenario_catalog_entry(family)` / `japan_fiscal_scenario_catalog()` | scenario catalog |
| `japan_fiscal_scenario_schema_contract()` | 契約全体の機械可読 export |
| `to_dict` / `to_json` | 各レコード型の JSON 化 |
| `japan_fiscal_fre_context_from_dict` / `japan_fiscal_assumption_from_dict` / `japan_fiscal_scenario_from_dict` | fail closed round trip |

```julia
using DME, Dates, JSON3

catalog = japan_fiscal_scenario_catalog()
catalog[:fiscal_consolidation].required_concepts
# => [:government_spending, :tax]

prov = JapanFiscalScenarioProvenance(; assumption_source = :user)
a = JapanFiscalScenarioAssumption(;
    assumption_id = "a1", concept = :government_spending, magnitude = -2.0,
    magnitude_source = :assumed_default,
)
sc = JapanFiscalScenario(;
    scenario_id = "sc-1", family = :fiscal_consolidation, provenance = prov,
    assumptions = [a],
)
japan_fiscal_scenario_content_hash(sc)
# => "sha256:…"
```
