# Keen 実証説明 LLM 回帰 fixture

Issue #133 の回帰・安全性評価で使う fixture 群。詳細な設計・運用は
[docs/development/keen_llm_regression.md](../../../../docs/development/keen_llm_regression.md) を参照。

すべて外部通信なしで決定的に扱える。契約テストの失敗のみ merge blocker とし、任意 provider 評価は分離する。

## ディレクトリ構成

| パス | 役割 | 期待される parser 挙動 |
|---|---|---|
| `parser_reject/` | 壊れた・不正な provider 応答（registry 非依存・手書き・静的） | `parse_keen_empirical_response` が `nothing` を返し、`explain_keen_empirical_result` が `:fallback` へ落ちる |
| `golden/valid_response.json` | schema・source・安全性を満たす基準応答（自動生成） | `:parsed` を返し、`keen_safety_violations` が空 |
| `forbidden/<name>.json` | schema は通るが ADR 0005 §6 の禁止解釈を含む応答（自動生成） | `:parsed` で通過するが、`keen_safety_violations` が該当 rule を検出する |

`golden/` と `forbidden/` は安定 source ID（`calibration.base` 等）を参照するため、標準の合成
context（`kle_base_kctx`）に対して parse できる。context の source registry を変更した場合は再生成する。

## 再生成

```bash
julia --project=. test/fixtures/llm/keen_empirical/regenerate.jl
```

`golden/valid_response.json` と `forbidden/*.json` を決定的に再生成する。生成時に
「golden は安全」「forbidden は指定 rule を検出」まで自己検証する。`parser_reject/` は触らない。

## 新しい禁止解釈が見つかったときの追加手順

1. `test/keen_llm_eval.jl` の `KLE_FORBIDDEN_BY_STATUS` または `KLE_FORBIDDEN_ANY` に、
   肯定方向の禁止フレーズと rule シンボルを追加する（qualifier ではなく claim `text` を検査する）。
2. `regenerate.jl` の `forbidden_specs` に、注入する section・claim_id・フレーズ・期待 rule を追加する。
3. `regenerate.jl` を実行して `forbidden/<name>.json` を生成する（生成時に評価器が rule を検出するか検証される）。
4. `test/test_keen_empirical_safety.jl` の forbidden fixture ループが自動で全ファイルを走査する
   （個別の追記は不要。特定 rule を明示検査したい場合のみ assertion を追加する）。

parser を拒否させたい新パターン（schema 破り）を足す場合は、`parser_reject/` に静的ファイルを 1 つ置くだけでよい
（テストがディレクトリを走査する）。
