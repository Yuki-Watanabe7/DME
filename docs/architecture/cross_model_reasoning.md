# クロスモデル推論層の設計

Keen 実証結果を既存マクロモデルの結果と比較し、共通点・相違点・適用範囲を根拠付きで説明する層の
設計をまとめる。決定記録は [ADR 0006](../adr/0006-cross-model-reasoning-contract.md)、根拠階層・
source registry・構造化出力/fallback の基盤は [ADR 0005](../adr/0005-keen-ai-explanation-contract.md)
（Keen 実証 AI 説明契約）を再利用する。

## 目的と責務

- モデル間の概念対応を **明示** する（`ModelConceptMapping`）。直接同一視しない。
- モデルの性質は **repository metadata のみ** を根拠とする（`MODEL_CONCEPT_REGISTRY`）。LLM の一般
  知識で未登録モデルを補完しない。
- 比較不能な項目を **無理に統合しない**（`insufficient_comparability`）。
- 根拠と限界を含む比較結果を、認識論的性質（メタデータ/概念対応/実証/合成/限界）を分離して生成する。

LLM API 呼び出しは分離する。context 生成・prompt 生成・決定的 fallback は provider 未接続でも動作する。

## データフロー

```
docs（モデル節・model_selection_guide・variable_mapping・simulation_outputs）
  └─ MODEL_CONCEPT_REGISTRY（ModelConceptCoverage: 手作業で符号化した repository metadata）
        │  build_cross_model_comparison_context(; models, concepts, empirical, model_metadata)
        ▼
   CrossModelComparisonContext
     ├─ coverage: Vector{ModelConceptCoverage}   （対象 (model, concept)）
     ├─ mappings: Vector{ModelConceptMapping}     （derive_concept_mapping で導出）
     ├─ empirical: KeenEmpiricalContext | nothing （Keen 実証結果、任意）
     ├─ sources:  Dict{String,EvidenceSource}     （ADR 0005 §2 の registry を再利用）
     └─ warnings: Vector{ExplanationWarning}       （§下記の標準 code）
        │  explain_cross_model_comparison(ctx; provider)
        ▼
   CrossModelReasoningOutput（必須 section を表示順で保持。ExplanationSection / EvidenceClaim を再利用）
```

## 型

| 型 | 役割 |
|---|---|
| `ModelConceptCoverage` | あるモデルが 1 比較軸をどう扱うかの repository metadata（treatment・変数・定義・単位・doc 参照・caveat） |
| `ModelConceptMapping` | 2 モデル間・1 概念の対応（`equivalent`/`proxy`/`partial`/`incompatible`・unit/frequency/aggregation 差・caveat） |
| `CrossModelComparisonContext` | 比較の構造化コンテキスト（coverage・mappings・empirical・sources・warnings） |
| `CrossModelReasoningOutput` | 根拠付き構造化出力（必須 section・source 参照・warning・免責・generation_status） |

`EvidenceSource` / `EvidenceClaim` / `ExplanationSection` / `ExplanationWarning` は ADR 0005 の
プリミティブを再利用する。共通語彙は DME superset へ広げ（`DME_EVIDENCE_CATEGORIES` /
`DME_EPISTEMIC_STATUSES` / `DME_SECTION_STATUSES`）、Keen 層は従来どおり狭い `KEEN_*` 語彙で内部
検証を続ける。

## 比較軸と treatment

比較軸 `CROSS_MODEL_CONCEPTS`（Issue #132）:

| concept | 内容 |
|---|---|
| `private_debt_credit` | 民間債務・信用拡張の役割 |
| `income_distribution` | 所得分配・賃金シェア・利潤率 |
| `demand_and_instability` | 需要不足と金融不安定性の伝播経路 |
| `steady_state_stability` | 定常状態・局所安定性・危機regime |
| `shock_response` | 政策・外生ショック反応 |

treatment `CROSS_MODEL_TREATMENTS`: `endogenous`（内生化）/ `approximate`（近似・代理）/
`out_of_scope`（対象外）。docs のモデル節・限界節・`docs/model_selection_guide.md` §3 の横断表を根拠とする。

### registry の要点（docs 準拠）

- 民間債務・信用、所得分配の動学、危機 regime を **内生化するのは Keen のみ**。他は out_of_scope
  または α などの静的パラメータ（`docs/models/*.md`・`docs/model_selection_guide.md` §3）。
- 定常状態は Ramsey / RBC が修正黄金律（水準）、Solow が効率労働単位（比率）、NK がゼロギャップ
  （偏差）、IS-LM/AD-AS/MF は静学均衡、VAR は線形固定点、Keen は双安定（危機 regime を含む）。
- 利子率 `r` は RBC=実質資本限界生産物、IS-LM/AD-AS/MF=名目、NK=名目 `i`/自然実質 `r_n`、
  Keen=外生一定の実質貸出金利。**同名でも定義が異なるため同一視しない**。

## mapping 導出（保守的）

`derive_concept_mapping(a, b)`（ADR 0006 §3.2）:

1. いずれかが `out_of_scope` → `incompatible`。
2. `definition_key`・`measure`・`unit` が一致 → `equivalent`。
3. いずれかが `approximate` → `partial`。
4. 両方 `endogenous` だが定義等が異なる → `proxy`。

`equivalent` は定義・単位・水準/偏差が真に一致する場合だけに限る。unit / frequency / measure の差は
各差分 field へ転記し、同名変数で定義が異なる場合は比較上の注意事項へ明示する。

## warning と section status

| code | severity | 反映 |
|---|---|---|
| `INSUFFICIENT_COMPARABILITY` | warning | 該当概念の section を `insufficient_comparability`、統合しない |
| `FIT_COMPARISON_RESTRICTED` | info | fit 単純比較を抑止、比較条件を明示 |
| `EMPIRICAL_ONLY_FOR_KEEN` | info | 実証 fit を持つのは Keen 実証層のみ |
| `DEFINITION_MISMATCH` | warning | 同名変数の定義差を明示し `equivalent` としない |
| `OUTPUT_SCHEMA_INVALID` | blocking | provider 応答不正時の決定的 fallback |

section status: `:available` / `:not_available` / `:insufficient_comparability`。

## 出力 section（表示順）

`executive_summary` → `comparison_scope` → `concept_mappings` → `mechanisms_by_model` →
`consistent_observations` → `divergent_conclusions` → `empirical_support` →
`incomparable_or_insufficient` → `next_evidence` → `limitations`。加えて `source_references`・
`reproducibility`。Issue #132 の「推論出力」（各モデルが説明できるメカニズム/複数モデルで整合的な
観察/結論が異なる箇所と原因/実証的支持・反証/比較不能項目/次に必要な証拠）に対応する。

## 安全性

ADR 0006 §7 の禁止解釈を prompt・決定的生成・parser の 3 層で担保する。

- 同名変数の定義差を無視した同一視をしない（`DEFINITION_MISMATCH`・mapping caveat）。
- fit の単純比較は対象系列・期間・自由度・推定方法が一致する場合に限る。
- 一つのモデルの失敗を別モデルの正しさの証明にしない（`empirical_support` の限定 claim）。
- repository metadata のみを根拠とし、比較不能を近似・平均・単一ランキングへ潰さない。

parser は JSON parse → contract_version → 必須 section → source registry 登録 →
category/status 整合の順で検証し、いずれか失敗で `OUTPUT_SCHEMA_INVALID` 付きの決定的 fallback へ
落とす。`comparative` / `limitation` の合成 claim のみ複数 category の source を参照できる。

## 拡張

新モデルを追加する場合は `MODEL_CONCEPT_REGISTRY` に該当 (model, concept) の
`ModelConceptCoverage` を追記すれば、mapping 導出・context 生成・出力へ自動的に参加する。Keen 固有
summary を共通型へ無理に一般化しない（ADR 0005 §10）。

## 参考

- [ADR 0006](../adr/0006-cross-model-reasoning-contract.md) — 本層の決定記録
- [ADR 0005](../adr/0005-keen-ai-explanation-contract.md) — 根拠階層・source registry・fallback の基盤
- [モデル選択ガイド](../model_selection_guide.md) — モデル横断比較表（§3）
- [モデル変数と実データ系列のマッピング表](../data/variable_mapping.md) — 変数定義差・単位・変換
- [出力結果の読み方](../simulation_outputs.md) — 水準・対数偏差・水準偏差の別
- [API リファレンス](../api.md#クロスモデル推論explain_cross_model_comparison) — 公開 API
