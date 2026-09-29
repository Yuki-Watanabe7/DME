# Japan Fiscal Scenario Lab — deterministic E2E・fixture・artifact validation・Market Analyzer handoff 契約

Japan Fiscal Scenario Lab（[Issue #273](https://github.com/Yuki-Watanabe7/DME/issues/273)）の vertical slice
（FRE snapshot → explicit Scenario Assumption → model-specific mapping → deterministic simulation artifact）を
fixture で完全に再現できるようにし、Market Analyzer（[market-analyzer#282](https://github.com/Yuki-Watanabe7/market-analyzer/issues/282)）が
Julia 内部型なしで consume できる versioned な consumer boundary を固定する。
[Issue #277](https://github.com/Yuki-Watanabe7/DME/issues/277) の成果物である。

> 関連: [ADR 0025](../adr/0025-japan-fiscal-scenario-handoff-contract.md)（決定記録）・
> [capability / mapping 契約](japan_fiscal_scenario_capability.md)（#274）・
> [claim-level / coverage 契約](japan_fiscal_claim_level_contract.md)（#285）・
> [scenario schema 契約](japan_fiscal_scenario_schema_contract.md)（#275）・
> [result artifact 契約](japan_fiscal_scenario_result_contract.md)（#276）

実装: [`src/scenarios/japan_fiscal_handoff.jl`](../../src/scenarios/japan_fiscal_handoff.jl)（bundle の生成・fail closed load・replay）・
[`src/scenarios/japan_fiscal_result.jl`](../../src/scenarios/japan_fiscal_result.jl)（result artifact 2.0.0）。
JSON Schema: [`schemas/japan-fiscal-scenario-result-v2.schema.json`](../../schemas/japan-fiscal-scenario-result-v2.schema.json)・
[`schemas/japan-fiscal-scenario-v1.schema.json`](../../schemas/japan-fiscal-scenario-v1.schema.json)・
[`schemas/japan-fiscal-scenario-handoff-v1.schema.json`](../../schemas/japan-fiscal-scenario-handoff-v1.schema.json)。
consumer fixture: [`test/fixtures/japan_fiscal/handoff/v1/`](../../test/fixtures/japan_fiscal/handoff/v1/)。
契約 version: `JAPAN_FISCAL_HANDOFF_SCHEMA_VERSION = "japan-fiscal-scenario-handoff/1.0.0"`・
`JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_VERSION = "japan-fiscal-scenario-result/2.0.0"`。

---

## 1. この文書が決めること・決めないこと

決めること。

- representative fixture（入力の構成・case の分類）と、その再生成手順。
- result artifact を 2.0.0 に上げる変更（`artifact_kind`・`assumption_disposition`・構造化された拒否 3 種・
  fail closed decode の強化・入力順非依存）。
- Market Analyzer 向け handoff bundle（ファイル構成・index・hash・negative artifact）と JSON Schema。
- 決定論・round-trip・replay の保証範囲。
- scenario の読み方（interpretation guide）と既知の限界。

決めないこと。

- モデル方程式・#274/#285 の registry の変更（#273 non-goal）。
- live の FRE snapshot 取得・定期実行・interactive web execution（#277 non-goal）。
- Market Analyzer 側の read model・UI（market-analyzer#283–#286）。
- finance-checker・PAP との統合（#277 non-goal）。

---

## 2. 責務境界（consumer integration boundary）

```text
fiscal-regime-engine（FRE）      DME                                        Market Analyzer
─────────────────────────       ───────────────────────────────────────     ─────────────────────────
current snapshot ──────────────▶ JapanFiscalFREContext（observed context）
（affinity / share /            │  magnitude の導出に使わない
  confidence / score）           │
                                 JapanFiscalScenarioAssumption（explicit）
                                 │  magnitude は人が明示する
                                 ▼
                                 japan_fiscal_run（#276）
                                 │  result / rejection artifact（2.0.0）
                                 ▼
                                 handoff bundle（index.json + files）──────▶ typed decode（schema のみ）
                                                                            FRE current との composition
                                                                            observed / assumed /
                                                                            model_implied の表示
```

| 主体 | 持つもの | 持たないもの |
|---|---|---|
| FRE | observed fiscal-regime context（current snapshot・dimensions・drivers・quality） | shock magnitude・model result |
| DME | scenario catalog・assumption validation・model mapping / execution・baseline 比較・診断・artifact / provenance・handoff bundle | FRE の regime 判定・UI |
| Market Analyzer | FRE context と DME artifact の composition・表示・observed / assumed / model-implied の視覚的分離 | モデル方程式・shock mapping・伝播計算の再実装・claim_level の昇格 |

consumer が守る規則（DME 側でも検査できるものは検査済み）:

- DME の Julia 型を共有しない。versioned artifact と JSON Schema だけを consume する。
- 未知の major version・必須フィールド欠損・hash 不一致・JSON Schema 違反は fail closed（明示的エラー）。
- `representable` / `partial` / `not_representable` と `claim_level`・`unsupported_*`・`uncovered_channels` を
  lossless に保持する。`rejection` を成功結果として表示しない。
- `null`・欠けたキー・`not_specified` を 0 へ変換しない。
- FRE context の identity が current snapshot と異なっても DME の結果を再計算・補正しない（警告として示す）。

---

## 3. 実行例

### 3.1 public API

```julia
using DME, Dates

fre = JapanFiscalFREContext(;
    snapshot_id = "fre-jp-2026-09-30", as_of = Date(2026, 9, 30),
    vintage_basis = "as-released", regime_determination = :primary,
    primary_regime = "FINANCIAL_REPRESSION",
    regime_affinity = Dict("FINANCIAL_REPRESSION" => 0.68),   # observed context のみ
)
sc = JapanFiscalScenario(;
    scenario_id = "jgb-funding-50bp", family = :jgb_funding_cost, fre_context = fre,
    provenance = JapanFiscalScenarioProvenance(; assumption_source = :user),
    assumptions = [
        JapanFiscalScenarioAssumption(;             # magnitude は明示する（FRE から導出しない）
            assumption_id = "long-rate", concept = :long_rate_funding_condition,
            magnitude = 50.0, magnitude_source = :assumed_default,
        ),
    ],
)

a = japan_fiscal_run(:capex_credit_cycle, sc; horizon = 20)
if a isa JapanFiscalScenarioResult
    a.coverage.claim_level          # :direction_and_relative_timing
    a.diagnostics.direction         # 変数 => :up / :down / :none
    a.assumption_disposition        # policy_rate は :not_specified / :held_at_baseline
else                                # JapanFiscalScenarioRejection
    a.rejection_code                # :not_adopted / :missing_required_assumption / :conversion_not_implemented
end

cases = [JapanFiscalHandoffCase(; case_id = "f5-ccc", purpose = "JGB funding-cost",
                                  tags = [:partial], scenario = sc, model = :capex_credit_cycle)]
write_japan_fiscal_handoff("out/handoff", cases; generated_at = now(UTC))
bundle = load_japan_fiscal_handoff("out/handoff")          # fail closed
replay_japan_fiscal_handoff_case(bundle, "f5-ccc")         # JapanFiscalReplayReport
```

### 3.2 デモ・fixture の再生成

```bash
# 5 family の primary セル + 表現不能セル + assumption 未指定を実行し、handoff bundle を書いて replay する
julia --project=. examples/japan_fiscal_scenario_lab_demo.jl

# consumer fixture（test/fixtures/japan_fiscal/handoff/v1/）と invalid input fixture を再生成する
julia --project=. test/fixtures/japan_fiscal/regenerate.jl
```

---

## 4. artifact schema / version

### 4.1 result artifact 2.0.0（1.0.0 からの変更）

1.0.0（#276）は consumer fixture として公開していない。#277 で次を加えたため major を上げた
（enum と必須フィールドの追加。[Julia 品質 Export の versioning 方針](../contract/julia-quality-export-v1.md#6-versioning-方針)と同じ考え方）。

| 変更 | 内容 | 理由 |
|---|---|---|
| `artifact_kind` | `"result"` / `"rejection"`。consumer の discriminated union の判別子 | TypeScript 等で型分岐させる |
| `assumption_disposition` | family の required → optional の宣言順に、全概念の `assumption_state`（`explicit` / `not_specified`）と `model_input`（`applied` / `held_at_baseline` / `not_accepted` / `conversion_not_implemented`） | 未指定を 0 と区別し、受け取れない assumption を黙って捨てない |
| 構造化された拒否 | `rejection_code`（`not_adopted` / `missing_required_assumption` / `conversion_not_implemented`）・`concepts`・scenario identity・`horizon`・`coverage`・`rejection_content_hash` | 実行しなかった理由を機械可読にし、scenario へ連結する |
| 必須概念の未指定 | モデルが受理する必須概念に assumption が無ければ実行せず `missing_required_assumption` | 1.0.0 は baseline のまま（= 0 の変化）で実行していた |
| 変換未実装の概念 | `primary_balance`（IS-LM / AD-AS / SIM が `:requires_structural_conversion` で受理）に assumption があれば実行せず `conversion_not_implemented` | 1.0.0 は adapter が黙って無視していた |
| 入力順非依存 | `assumed` を `assumption_id` 昇順に、`observed.dominant_drivers` を整列して出力 | 入力順が `result_content_hash` を変えていた |
| `parameter_identity_hash` | `"sha256:"` 接頭辞 | 他の hash と形式を揃える |
| `diagnostics.thresholds` | timing 診断を持つ場合に onset 判定の閾値を出力 | onset / duration の定義を artifact だけで読めるようにする |
| decode の強化 | schema / 契約 version の完全一致・coverage の registry 一致・claim_level と timing 診断の整合・disposition の整合を検査 | 改変・古い契約・claim の昇格を受理しない |
| `generated_at` の注入 | `japan_fiscal_run(...; generated_at)` | fixture を決定的なバイト列にする（hash 対象外） |

hash の規則: `result_content_hash` / `rejection_content_hash` は、artifact から `generated_at` と自身を除いた
RFC 8785 正準 JSON の SHA-256（`"sha256:" * hex`）。consumer は DME 型なしに再計算できる。

### 4.2 handoff bundle 1.0.0

```text
handoff/v1/
  index.json                         # 入口（schema: japan-fiscal-scenario-handoff-v1）
  contracts/capability_matrix.json   # japan_fiscal_capability_matrix()（#274）
  contracts/downstream_contract.json # japan_fiscal_downstream_contract()（#285。H-16）
  contracts/scenario_schema_contract.json  # japan_fiscal_scenario_schema_contract()（#275。catalog を含む）
  contracts/result_artifact_contract.json  # japan_fiscal_result_artifact_contract()
  scenarios/<scenario_id>.json       # to_dict(::JapanFiscalScenario)（schema: japan-fiscal-scenario-v1）
  artifacts/<case_id>.json           # result / rejection（schema: japan-fiscal-scenario-result-v2）
  negative/<kind>.json               # consumer が必ず拒否すべき artifact
```

`index.json` の主なフィールド:

| フィールド | 内容 |
|---|---|
| `schema_version`・`artifact_kind`（`handoff_index`） | bundle の version |
| `contract_versions` | handoff・result artifact・scenario schema・capability・claim・adapter の 6 version |
| `json_schemas` | 3 つの JSON Schema のリポジトリ内パス |
| `families` | 5 family の表示名・必須 / 任意概念・実装候補・11 モデル分の representability |
| `contracts`・`scenarios`・`cases`・`negative_artifacts` | 各ファイルの `path` と `sha256`（ファイルのバイト列） |
| `scenarios[]` | scenario identity・FRE context identity・`fre_regime_determination`・明示された概念 |
| `cases[]` | `case_id`・`purpose`・`tags`・`scenario_id`・`model`・`horizon`・`summary`（artifact からの機械的導出） |
| `bundle_content_hash` | index から `generated_at` と自身を除いた正準 JSON の SHA-256 |

`cases[].tags`（`JAPAN_FISCAL_HANDOFF_CASE_TAGS`）は consumer が normal / partial / adverse のケースを選ぶための
語彙で、`load_japan_fiscal_handoff` が artifact・scenario の内容と整合することを検査する。

negative artifact（`JAPAN_FISCAL_HANDOFF_NEGATIVE_KINDS`）:

| kind | 内容 | JSON Schema だけで拒否できるか |
|---|---|---|
| `content_hash_mismatch` | 系列を書き換え hash を据え置いた | できない（hash の再計算が必要） |
| `unsupported_schema_version` | major を上げた（hash 再計算済み） | できる |
| `missing_required_field` | `coverage` を削除（hash 再計算済み） | できる |
| `claim_level_exceeds_contract` | `coverage.claim_level = magnitude`（hash 再計算済み） | できる |
| `not_representable_presented_as_result` | not_representable セルを result と装った | できる |
| `missing_assumption_presented_as_zero` | 必須概念の assumption を除き baseline 保持と装った | できる |

### 4.3 JSON Schema

3 つの schema（draft 2020-12）は DME が所有する。JSON Schema で表現できない整合条件（hash の再計算・coverage と
registry の一致・disposition と applied_inputs の一致・summary と artifact の一致など）は各 schema の
`x-semantic-invariants` に列挙し、DME の decoder（`japan_fiscal_artifact_from_dict`・`japan_fiscal_scenario_from_dict`・
`load_japan_fiscal_handoff`）が検査する。schema 自体も result では `claim_level = magnitude`・
`numeric_semantics = japan_magnitude`・`adoption = not_adopted`・`magnitude_source = external_belief`・
「必須概念の未指定を baseline 保持として扱う disposition」を受理しない。

DME の src は汎用 JSON Schema バリデータを持たない（ADR 0008・0016）。CI では
[`test/fixtures/japan_fiscal/json_schema_subset.jl`](../../test/fixtures/japan_fiscal/json_schema_subset.jl)（schema が使う
キーワードだけを解釈し、それ以外のキーワードが現れたら失敗する最小 validator）で全ファイルを検証する。

### 4.4 versioning

| 変更 | バージョン影響 |
|---|---|
| enum への値の追加・必須フィールドの追加 / 削除 / 意味変更 | result artifact・handoff とも major を上げる |
| 契約（capability / claim / adapter / scenario schema）の version 変更 | artifact は契約 version chain を持ち、DME の decoder は完全一致を要求する。consumer fixture を再生成する |
| `claim_level` の昇格（日本較正） | [claim-level 契約 §6](japan_fiscal_claim_level_contract.md) の規則に従い、両契約 version を上げる。consumer は暗黙に昇格させない |
| fixture の case 追加・数値の再生成 | handoff の version は変えない（`bundle_content_hash` が変わる） |

---

## 5. fixture

```text
test/fixtures/japan_fiscal/
  inputs/fre_context/*.json     # FRE snapshot（架空。primary / score だけを変えた shifted / unavailable）
  inputs/assumptions/*.json     # explicit assumption 集合（12 種。FRE context と独立に magnitude を明示）
  inputs/cases.json             # scenario 16・case 31・入力エラー 3・固定 generated_at
  japan_fiscal_fixture_cases.jl # inputs → JapanFiscalHandoffCase（テストと regenerate.jl が共有）
  regenerate.jl                 # handoff/v1 と invalid_inputs を再生成
  handoff/v1/                   # consumer fixture（生成物）
  invalid_inputs/               # 1 事実だけを破った scenario JSON（生成物）
```

case の構成（5 family すべてについて、実行される result・not_representable の拒否・必須 assumption 未指定の
拒否を持つ）:

| 分類 | case |
|---|---|
| representable の通常ケース | `f2-sim`・`f4-solow`・`f4-rbc`・`f2-sim-explicit-zero-tax` |
| partial | `f1-ccc`・`f1-nk`・`f1-keen`・`f2-islm`・`f2-adas`・`f2-mundell-fleming`・`f3-nk`・`f4-adas`・`f4-keen`・`f5-ccc`・`f5-keen` |
| not_representable | `f1-solow-…`・`f2-nk-…`・`f3-islm-…`・`f4-ccc-…`・`f5-nk-…`（+ partial だが不採用の `f3-ccc-partial-not-adopted`） |
| missing FRE context / FRE unavailable / FRE score だけ変更 | `f2-sim-no-fre`・`f5-ccc-no-fre` / `f2-sim-fre-unavailable` / `f2-sim-fre-shifted` |
| missing explicit assumption | `f1-ccc-missing-long-rate`・`f2-sim-missing-tax`・`f3-nk-missing-inflation`・`f4-solow-growth-path-only`・`f5-ccc-missing-long-rate` |
| 変換未実装 | `f2-sim-primary-balance` |

未対応の unit / horizon などの入力エラーは artifact を生成しない（`ArgumentError`）。`invalid_inputs/` は
`scenario_unsupported_unit`（bp の概念に %pt）・`scenario_external_belief_magnitude`・
`scenario_affinity_as_magnitude_field`（affinity を magnitude として渡す未知フィールド）・`scenario_tampered_magnitude`・
`scenario_concept_outside_family`・`scenario_direction_mismatch` を持ち、`inputs/cases.json` の `input_errors` は
horizon 0・負の horizon・未知のモデルを持つ。

---

## 6. 決定論・round-trip・replay

| 保証 | 範囲 | 検査 |
|---|---|---|
| 同一入力から同一 canonical artifact | 同一プラットフォーム・同一依存で、`generated_at` を固定すればバイト列が一致。固定しなくても content hash は一致 | 全 case を 2 回 build して全ファイルのバイト列を比較 |
| 入力順・Dict 挿入順に非依存 | assumption の順序・FRE の `dominant_drivers` の順序・affinity 等の Dict の挿入順 | 並べ替えた scenario で canonical bytes が一致 |
| round-trip | `to_dict` → 正準 JSON → decode → `to_dict` がバイト一致。`claim_level`・`unsupported_*`・`uncovered_channels` が保持される（H-14） | 全 artifact・全 scenario |
| replay | 保存済み scenario から再実行し、保存済み artifact と比較する。数値以外（identity・構造・診断の離散値）は完全一致、数値は `rtol = 1e-9` の範囲で一致。content hash の完全一致は `exact_match` として別に報告する | 別ディレクトリへ移した bundle で全 case。同一プロセスで書いた bundle は `exact_match` まで要求 |
| committed fixture の drift 検出 | 再生成結果と commit 済みファイルの一致（数値を含まないファイルはバイト一致、数値系列を含むファイルは許容誤差） | `test/test_japan_fiscal_e2e.jl` |

content hash の完全一致を replay 成立の必要条件にしないのは、BLAS / LAPACK を使うモデル（New Keynesian・RBC・
Keen の均衡計算など）の浮動小数点の最終桁が CPU アーキテクチャで変わりうるためである。identity に使う hash
（`scenario_content_hash`・`assumption_set_hash`・`fre_context_identity`・`parameter_identity_hash`）は入力だけから
決まり、プラットフォームに依存しない。

---

## 7. semantic guardrails（E2E で検査すること）

| guardrail | 検査 |
|---|---|
| affinity / share / confidence を magnitude に使わない | FRE context だけが異なる case（なし・unavailable・score を大きく変えた snapshot・score の掃引）で `applied_inputs`・`model_implied`・`diagnostics` が不変。FRE の score のフィールド名は `observed` の中にしか現れない。`external_belief` と affinity を magnitude として渡す未知フィールドは拒否 |
| missing / unavailable を 0 にしない | FRE context なし → `observed`・`fre_context_identity` は `null`。FRE unavailable → nullable は `null`・評価できない archetype / dimension はキーごと欠く。必須概念の未指定 → 実行しない。任意概念の未指定 → `held_at_baseline` として開示し 0 の applied input を作らない。magnitude = 0.0 の明示は未指定と区別して実行する。`relative_delta` の分母不足は `null` |
| observed / assumption / model_implied を混ぜない | 3 分類のキー集合が固定されていること・相互に値が漏れないこと（H-10） |
| model-implied を forecast / probability と呼ばない | artifact・index のキーに forecast / probability / predict を含まない。`numeric_semantics ≠ japan_magnitude`・`claim_level ≠ magnitude`（H-13）。claim level の必須 caveat が `major_caveats` にある。forecast / probability / 危機確率 / 投資推奨の主張は `japan_fiscal_validate_claims` が違反にする |
| not_representable を成功 scenario に見せない | 不採用セルは常に `rejection`（`status = not_executed`・`model_implied` 等のキーを持たない）。partial は unsupported と未被覆チャネルを開示し、`family_complete = false` |

---

## 8. scenario の読み方（interpretation guide）

1. **まず representability と claim_level を読む**。`rejection` は「影響が無い」ではなく「このモデルでは表現しない /
   実行しない」である（`rejection_code` と `reason` を併記する）。`partial` は `unsupported_concepts`・
   `unsupported_outputs`・`uncovered_channels` を同じ視野に表示する。`family_complete` は全セルで `false` であり、
   family 名だけの要約（「財政再建の効果は…」）を作らない。
2. **assumption は explicit なものだけ**。`assumed` は人が置いた仮定であり観測ではない。`assumption_disposition` の
   `not_specified` / `held_at_baseline` は「その概念を動かしていない」ことであって「0 と仮定した」ことではない。
   `explicit` / `not_accepted` はモデルが受け取れなかった assumption で、結果に反映されていない。
3. **FRE context は observed context のみ**。`observed` は「現在どのレジームに近いか」の観測であり、shock の大きさ・
   結果の確からしさと無関係である。FRE の current snapshot と artifact の `fre_context_identity` が異なる場合でも、
   結果は assumption だけで決まっている。
4. **数値の意味は `numeric_semantics` に従う**。`model_implied.*.series` はモデル単位の水準のまま保持されている。
   `model_unit_relative`（`direction_only`）は符号だけを読む。`normalized_deviation`（`direction_and_relative_timing`）は
   baseline 比の偏差（`relative_delta`）と時間形状として読み、水準・絶対差を主要な結論にしない。どちらも日本の量ではない。
5. **direction は評価区間最終期の baseline 比の符号**である。循環を持つモデル（CCC）では途中で符号が反転しうる
   （例: `f5-ccc` の output は 4 期後に trough、16 期後に peak）。`direction_and_relative_timing` のセルでは peak と
   trough の両方を読む。`peak` は差分の最大、`trough` は最小であり、負の反応では `trough` が主な極値になる。
6. **時点は「ショック後 n 期」**。`periods` はモデルの期インデックス（CCC は評価区間の先頭を 0、SIM・Solow・NK は 1、
   RBC は `horizon + 1` 点）であり暦日ではない。`onset_period` は「|差分| ≥ `onset_abs` または |相対差| ≥ `onset_rel`」が
   `onset_persistence` 期以上続いた最初の区間の開始期、`recovery_period` は onset の後にその条件が `onset_persistence`
   期以上続けて外れた最初の期、`duration_periods` はその差（閾値は `diagnostics.thresholds`）。assumption は恒久 step
   として適用されるため、多くのセルで `recovery_period`・`duration_periods` は `null`（評価区間内に baseline へ戻らない）
   になる。`null` は「該当なし」であり 0 ではない。
7. **モデル別の注意**。Solow の output・capital_stock・consumption は効率労働 1 単位あたりの量で、`g` の上昇はこれを
   下げる（水準の産出の低下を意味しない）。RBC は定常状態からの偏差（対数偏差）で TFP ショックは平均回帰する。New Keynesian の
   `nominal_rate`・`inflation` は水準（年率・小数）。Keen は良い均衡の 2 点比較で時点を主張しない。静学モデル
   （IS-LM・AD-AS・Mundell-Fleming）の `horizon` は計算に使われない。`tax` は SIM では比例税率 θ、IS-LM / AD-AS /
   Mundell-Fleming では定額税 T の変化として適用され、自動変換しない（`applied_inputs[].conversion`）。
8. **言えないこと**。forecast・probability・危機確率・デフォルト確率・日本の実現幅・観測結果・投資推奨・債務持続可能性の
   判断（`japan_fiscal_forbidden_claims()`）。政府の調達コスト・利払費・債務残高（sovereign leg）はどのモデルも返さない。

---

## 9. 既知の限界

- 日本較正済みのモデルは無い（G-02）。全セルの `claim_level` は `direction_only` または `direction_and_relative_timing`。
- 政府債務ストック・利払費・`r − g` 動学を持つモデルは無い（G-01）。F5 の sovereign leg は常に `unsupported`。
- GDP 成長率パス（`growth_path`）を受け取るモデルは無い（G-03）。生産性成長率へ自動変換しない。
- 中央銀行の JGB 吸収（`cb_jgb_absorption`）を受け取るモデルは無い（G-04）。
- プライマリーバランス（`primary_balance`）から `(G, T)` への変換（閉じ変数の選択、#274 §5.3）は未実装であり、
  explicit assumption は `conversion_not_implemented` として拒否する。
- assumption は timing / persistence を持たず、評価区間の先頭期からの恒久 step としてのみ適用する（ADR 0023 決定 1）。
- FRE snapshot の fixture は架空である。FRE の実出力との接続（live snapshot の取得・スキーマの追随）は行っていない。
- content hash の完全一致による replay は同一プラットフォーム・同一依存に限る（§6）。
- 静学モデルの artifact も `horizon` を記録するが、計算には使われない。

---

## 10. 完了条件（Issue #273 の DME 側 exit criteria）との対応

| exit criterion | 根拠 |
|---|---|
| 5 scenario family の capability matrix がある | `japan_fiscal_capability_matrix()`（#274）・bundle の `contracts/capability_matrix.json`・index の `families` |
| scenario assumption と FRE context が別型・別 provenance で保持される | `JapanFiscalScenarioAssumption` / `JapanFiscalFREContext`（#275）・artifact の `assumed` / `observed`・`assumption_set_hash` / `fre_context_identity` |
| shock 量を FRE score から自動生成する経路が存在しない | `external_belief` の拒否・FRE context だけを変えた case の不変性・score の掃引（§7） |
| representable scenario を public API で baseline と比較実行できる | `japan_fiscal_run`・`f2-sim`・`f4-solow`・`f4-rbc` |
| not_representable を明示的に返せる | `JapanFiscalScenarioRejection`（`rejection_code = not_adopted`）・5 family の not_representable case |
| model / version / params / assumption / context identity を artifact から追跡できる | 契約 version chain・`parameter_identity_hash`・`assumption_set_hash`・`scenario_content_hash`・`fre_context_identity`・`applied_inputs`・`assumption_disposition` |
| baseline delta / peak / onset / duration / propagation candidates を取得できる | `diagnostics`（`relative_delta`・`peak`・`trough`・`onset_period`・`duration_periods`・`recovery_period`）・`coverage.covered_channels`・CCC の `contribution_decomposition`（timing のセルのみ） |
| deterministic fixture E2E が green | `test/test_japan_fiscal_e2e.jl` |
| Market Analyzer が内部 Julia 型ではなく versioned artifact contract を consume できる | `schemas/japan-fiscal-scenario-*.schema.json`・`test/fixtures/japan_fiscal/handoff/v1/` |

---

## 11. 公開 API

| 関数・定数 | 役割 |
|---|---|
| `JAPAN_FISCAL_HANDOFF_SCHEMA_VERSION`・`JAPAN_FISCAL_HANDOFF_JSON_SCHEMA`・`JAPAN_FISCAL_SCENARIO_JSON_SCHEMA`・`JAPAN_FISCAL_RESULT_ARTIFACT_JSON_SCHEMA` | 契約 version と schema のパス |
| `JAPAN_FISCAL_HANDOFF_CASE_TAGS`・`JAPAN_FISCAL_HANDOFF_NEGATIVE_KINDS` | case tag・negative artifact の語彙 |
| `JapanFiscalHandoffCase` | bundle に含める 1 実行（scenario × model × horizon × tags） |
| `build_japan_fiscal_handoff(cases; generated_at, negative_source_case_id)` | bundle の全ファイルを in-memory で構築 |
| `write_japan_fiscal_handoff(dir, cases; generated_at, negative_source_case_id)` | bundle を書く（上書きしない・一時ディレクトリから確定） |
| `load_japan_fiscal_handoff(dir)` → `JapanFiscalHandoffBundle` | fail closed で読む |
| `replay_japan_fiscal_handoff_case(bundle, case_id; rtol, atol)` → `JapanFiscalReplayReport` | 保存済み scenario から再実行して比較 |
| `japan_fiscal_handoff_case_summary(artifact_dict)` | index の要約（artifact から導出） |
| `japan_fiscal_handoff_negative_artifacts(result)` | negative artifact の生成 |
| `JAPAN_FISCAL_ARTIFACT_KINDS`・`JAPAN_FISCAL_REJECTION_CODES`・`JAPAN_FISCAL_ASSUMPTION_STATES`・`JAPAN_FISCAL_MODEL_INPUT_TREATMENTS` | result artifact 2.0.0 の語彙 |
| `JapanFiscalAssumptionDisposition`・`japan_fiscal_assumption_disposition(scenario, model)` | assumption の有無とモデル入力としての扱い |
| `JAPAN_FISCAL_ADAPTER_IMPLEMENTED_CONCEPTS` | adapter が変換を実装している概念 |
| `japan_fiscal_scenario_rejection_from_dict`・`japan_fiscal_artifact_from_dict` | rejection / 判別付きの fail closed decode |
