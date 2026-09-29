# Japan Fiscal Scenario Lab fixture（Issue #277）

Japan Fiscal Scenario Lab の deterministic E2E fixture と、Market Analyzer 向けの versioned consumer fixture。
契約の詳細は [docs/architecture/japan_fiscal_scenario_handoff.md](../../../docs/architecture/japan_fiscal_scenario_handoff.md)。

| パス | 種類 | 内容 |
|---|---|---|
| `inputs/fre_context/*.json` | 入力（手で管理） | FRE current snapshot の fixture。**架空**であり fiscal-regime-engine の実出力ではない。observed context としてのみ使う |
| `inputs/assumptions/*.json` | 入力（手で管理） | explicit Scenario Assumption の集合。magnitude は FRE snapshot と独立にここで明示する |
| `inputs/cases.json` | 入力（手で管理） | scenario（family × assumption 集合 × FRE context）・case（scenario × model × horizon × tags）・入力エラー・固定 `generated_at` |
| `handoff/v1/` | 生成物 | consumer fixture（`japan-fiscal-scenario-handoff/1.0.0`）。`index.json` が入口 |
| `invalid_inputs/` | 生成物 | 有効な scenario から 1 事実だけを破った scenario JSON（DME 側の fail closed 検証用） |
| `japan_fiscal_fixture_cases.jl` | ヘルパ | `inputs/` → `JapanFiscalHandoffCase`（テストと `regenerate.jl` が共有） |
| `json_schema_subset.jl` | ヘルパ | `schemas/japan-fiscal-scenario-*.schema.json` が使うキーワードだけを解釈する最小 validator |
| `regenerate.jl` | スクリプト | `handoff/v1/` と `invalid_inputs/` を再生成する |

## 再生成

```bash
julia --project=. test/fixtures/japan_fiscal/regenerate.jl
```

`inputs/` は変更しない。契約の version を上げたとき・case を追加したときに実行し、差分をレビューしてから
コミットする。`test/test_japan_fiscal_e2e.jl` は再生成結果と commit 済みファイルの一致を検査する（数値系列を含む
ファイルは BLAS 等のプラットフォーム差を許容誤差で吸収する）。

## consumer（Market Analyzer）が vendor する場合

- `handoff/v1/` 全体と `schemas/japan-fiscal-scenario-result-v2.schema.json`・
  `schemas/japan-fiscal-scenario-v1.schema.json`・`schemas/japan-fiscal-scenario-handoff-v1.schema.json` を、DME の
  commit を記録したうえでコピーする。
- `index.json` の `sha256`（ファイルのバイト列）と `bundle_content_hash` で改変を検出できる。
- `negative/` の artifact はすべて拒否されなければならない（`negative_artifacts[].expected_failure`）。
