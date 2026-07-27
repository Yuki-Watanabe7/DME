# DME real-rate model artifact contract（vendor コピー）

このディレクトリは `Yuki-Watanabe7/economic-data-provider` の ADR 006
（`docs/decisions/006-dme-model-provider-comparison-contract.md`、コミット
`fc4be7bfe8bfc8db32ac4feedb30aa3c5c049da9`）が確定した cross-repository contract の
machine-readable schema と example artifact のコピーです。

正本は economic-data-provider リポジトリ側にあります。schema の field・semantics を
変更する場合は、まず economic-data-provider 側の ADR 006 と schema を更新し、その後この
ディレクトリを手動で同期してください（自動同期の仕組みはありません）。

| ファイル | 内容 |
|---|---|
| `dme-real-rate-model-artifact.schema.json` | artifact の JSON Schema（2020-12） |
| `examples/dme-real-rate-model-artifact.json` | 契約が要求するフィールド構造を示す illustrative な example artifact（`warnings` に `illustrative_contract_example_not_empirical_calibration` を含み、実際の DME 計算値ではない） |
| `examples/dme-real-rate-comparison-response.json` | economic-data-provider 側の比較 read model の example（DME 側の実装対象ではない。参考のためのコピー） |

DME 側の実装がこの schema をどう満たすかは
[ADR 0008](../adr/0008-real-rate-model-artifact-export.md) と
[SFC対応 AIエコノミスト統合デモ](../examples/keen_empirical_ai_economist.md) と同形式の
[real-rate model artifact 生成デモ](../examples/real_rate_model_artifact.md) を参照してください。

DME はこの schema に対する汎用 JSON Schema バリデータを内蔵しません。契約が要求する制約は
`src/artifacts/real_rate_model_artifact.jl` の Julia 側バリデーションロジックとして個別に
再実装しています（構造は本 schema と一致させています）。
