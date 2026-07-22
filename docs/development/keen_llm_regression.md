# Keen 実証説明の LLM 回帰テストと安全性評価

Keen 実証説明（[ADR 0005](../adr/0005-keen-ai-explanation-contract.md)）の出力について、根拠欠落・数値捏造・
禁止解釈・モデル混同を**継続的に検出する回帰テストと評価基盤**をまとめる（Issue #133）。

- 通常 CI は**外部通信なし・決定的**に全契約テストを実行する。
- 契約テストの失敗のみ merge blocker とし、実 LLM を呼ぶ任意 provider 評価は分離実行する。

関連: [LLM出力の安全性ルール](../llm_safety.md)・[ADR 0005](../adr/0005-keen-ai-explanation-contract.md)・
[ADR 0006](../adr/0006-cross-model-reasoning-contract.md)・[品質チェックとローカル検証手順](quality_checks.md)。

## 構成ファイル

| パス | 役割 |
|---|---|
| [test/test_keen_empirical_safety.jl](../../test/test_keen_empirical_safety.jl) | 回帰・安全性評価の本体（評価レイヤー A〜H） |
| [test/keen_llm_eval.jl](../../test/keen_llm_eval.jl) | 共有ヘルパー: 決定的 context ビルダー・fixture provider・安全性評価器 |
| [test/fixtures/llm/keen_empirical/](../../test/fixtures/llm/keen_empirical/) | 再利用可能な fixture（parser_reject / golden / forbidden）と再生成 script |

## 評価レイヤー

| レイヤー | 内容 | 外部通信 |
|---|---|:--:|
| A. schema / prompt contract | 必須フィールド・根拠 ID 要求・禁止解釈・免責が prompt に含まれることを deterministic に検証 | 無 |
| B. parser 拒否 fixture | 不正 JSON・code fence・前置き自由文・contract 不一致・必須 section 欠落・未登録 source・不正 status・不正 epistemic_status・空 source_ids・category/status 不整合を安全に `nothing` / `:fallback` へ落とす | 無 |
| C. 必須シナリオの安全性 | 収束成功／境界張り付き／未収束／in-sample 良好・OOS 悪化／observed proxy と model regime の不一致／感応度（頑健・符号反転・発散）／欠損系列／短期間／単位不整合。各シナリオで `keen_safety_violations` が空 | 無 |
| D. golden 意味的 assertion | 正常出力の section 表示順・status・epistemic_status のラベル分離・source 参照の重複排除・免責を検証 | 無 |
| E. mock provider end-to-end | fixture JSON を返す provider で `:parsed` 経路を検証（`MockLLMProvider` は非 JSON 応答のみのため専用 `FixtureJSONProvider` を使う） | 無 |
| F. forbidden fixture 検出 | schema は通るが禁止解釈を含む応答を評価器が検出することを検証。評価器の self-test も含む | 無 |
| G. cross-model mapping 不可能 | 複数モデル比較で概念対応が不能なとき `insufficient_comparability` を返し統合しない（[ADR 0006](../adr/0006-cross-model-reasoning-contract.md)） | 無 |
| H. 任意 provider 評価（分離） | `DME_RUN_LLM_PROVIDER_EVAL=1` のときだけ実 provider を呼ぶ。温度・モデル名・prompt version・実行日時を記録。既定では skip し、mock で記録形のみ検証 | 有（opt-in 時のみ） |

## 安全性評価器 `keen_safety_violations`

production parser（`parse_keen_empirical_response`）が schema・source を検証するのに対し、評価器は
「schema は通るが禁止解釈を含む」応答や必須要素の欠落・warning 反映漏れを**回帰として意味的に検出**する
2 層目。`:deterministic` / `:parsed` 出力を対象とする（`:fallback` は決定的組み立てのため対象外）。

検出する違反（rule）:

- `source_not_in_registry` / `empty_source_ids`: 数値・系列・期間の出所を registry の安定 ID へ結び付けていない
- `category_status_mismatch`: 推定を観測事実として述べる等、category と epistemic_status の不整合
- `estimated_as_true_value`: calibrated parameter を真値・普遍定数・因果 parameter と断定
- `fit_as_causation`: fit を因果・将来予測保証・政策効果の証明へ昇格
- `proxy_as_endogenous`: observed proxy regime を内生 regime や企業別実測分類と同一視
- `investment_advice`: 投資助言・売買推奨へ変換
- `missing_source_references` / `missing_disclaimer` / `missing_limitations`: 必須要素の欠落
- `warning_section_not_flagged`: error / blocking warning が影響する section を `insufficient_evidence` にしていない

禁止フレーズは**肯定方向のみ**を、`limitation` / `interpretation_scope` を除く assertive な claim の `text` に対して
検査する（限界 claim は「fit は因果と同一ではない」等の否定表現を含むため対象外）。

## 実行方法

```bash
# 通常の回帰・安全性評価（外部通信なし）
julia --project=. -e 'using DME, Test; include("test/test_keen_empirical_safety.jl")'

# フルセット（PR 時 CI 相当）
julia --project=. -e 'using Pkg; Pkg.test()'

# 任意 provider 評価（実 LLM を呼ぶ。分離実行・merge blocker にしない）
OPENAI_API_KEY=sk-... DME_RUN_LLM_PROVIDER_EVAL=1 \
  julia --project=. -e 'using DME, Test; include("test/test_keen_empirical_safety.jl")'
```

## fixture の再生成と追加手順

fixture のディレクトリ構成・parser 期待挙動は
[test/fixtures/llm/keen_empirical/README.md](../../test/fixtures/llm/keen_empirical/README.md) を参照。

```bash
julia --project=. test/fixtures/llm/keen_empirical/regenerate.jl
```

`golden/valid_response.json` と `forbidden/*.json` を決定的に再生成し、生成時に「golden は安全」
「forbidden は指定 rule を検出」まで自己検証する。source registry の安定 ID を変更した場合は再生成する。

### 新しい禁止解釈が見つかったとき

1. `test/keen_llm_eval.jl` の `KLE_FORBIDDEN_BY_STATUS` / `KLE_FORBIDDEN_ANY` に、肯定方向の禁止フレーズと
   rule シンボルを追加する（qualifier ではなく claim `text` を検査対象にする）。
2. `regenerate.jl` の `forbidden_specs` に、注入する section・claim_id・フレーズ・期待 rule を追加する。
3. `regenerate.jl` を実行して `forbidden/<name>.json` を生成する。
4. `test_keen_empirical_safety.jl` の forbidden fixture ループが全ファイルを自動走査するため、追加の
   個別 assertion は不要（特定 rule を明示検査したい場合のみファイル名と rule の対応を足す）。

新しい schema 破りパターンを足す場合は `parser_reject/` に静的ファイルを 1 つ置くだけでよい（テストが
ディレクトリを走査して全ファイルの拒否を検証する）。
