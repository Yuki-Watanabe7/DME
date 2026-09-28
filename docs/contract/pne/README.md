# PNE sector-output-path contract（vendor コピー）

このディレクトリは `Yuki-Watanabe7/production-network-engine`（PNE）が所有する
`production-network-sector-output-path/v1` の JSON Schema のコピーです（コミット
`30beab183ef7f2387ce469ae19ad9885f9f55d71`、`contracts/production-network-sector-output-path-v1.schema.json`）。

正本は PNE 側にあります（[sector output path contract](https://github.com/Yuki-Watanabe7/production-network-engine/blob/30beab183ef7f2387ce469ae19ad9885f9f55d71/docs/sector-output-path-contract.md)・
[PNE ADR 14](https://github.com/Yuki-Watanabe7/production-network-engine/blob/30beab183ef7f2387ce469ae19ad9885f9f55d71/docs/decisions/0014-macro-boundary-is-native-sector-output-not-dynamic-state.md)）。
schema・fixture を**手で編集しない**でください。PNE 側の変更を取り込む場合は、PNE の該当コミットから
バイト列のまま再コピーし、`test/fixtures/pne/sector_output_path/v1/MANIFEST.json` の `upstream_commit` と
各ファイルの `sha256` を更新します（`test/test_cross_model_compatibility.jl` が MANIFEST とファイルの
hash の一致を検査し、黙った drift を検出します）。

| ファイル | 内容 |
|---|---|
| `production-network-sector-output-path-v1.schema.json` | PNE artifact の JSON Schema（2020-12）と `x-semantic-invariants` |
| `test/fixtures/pne/sector_output_path/v1/representative.json` | PNE の実 simulation・export 経路で生成された synthetic artifact（vendor） |
| `test/fixtures/pne/sector_output_path/v1/rejected/*.json` | 1 事実だけを変えた PNE の negative fixture 6 件（vendor） |
| `test/fixtures/pne/sector_output_path/v1/MANIFEST.json` | 上記ファイルの upstream commit・upstream path・SHA-256（DME が記録） |

DME はこの schema に対する汎用 JSON Schema バリデータを内蔵しません（ADR 0008 と同じ方針）。
schema の制約と `x-semantic-invariants` は `src/scenarios/pne_sector_output_path.jl` が Julia で個別に
再実装しており、PNE の Python package を import しません（[ADR 0024](../../adr/0024-pne-sector-output-cross-model-input-contract.md)
決定 3）。DME 側の受理・互換性判定・mapping の契約は
[PNE sector-output-path 受け入れ契約](../../architecture/pne_sector_output_integration.md) を参照してください。
