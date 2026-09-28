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

## PNE の実 producer 経路で生成した cross-repository fixture（Issue #283）

vendor コピー（上表）に加えて、DME は PNE の producer 経路から次の fixture を生成して commit しています。
いずれも PNE 側のリポジトリには置かず、PNE を DME の実行時依存にもしません（DME のテストは PNE・Python・
ネットワークを必要としません）。

| パス | 内容 |
|---|---|
| `test/fixtures/pne/producer/inputs/` | DME 所有の架空の PNE 入力（network・四半期/月次の dynamic scenario・export config） |
| `test/fixtures/pne/producer/v1/*.json` | PNE CLI（`production-network dynamic-simulate` → `export-sector-output-path`）が書いた artifact のバイト列そのもの。手で編集しない |
| `test/fixtures/pne/producer/MANIFEST.json` | PNE の commit・入出力の SHA-256・DME の `content_hash`・PNE dynamic artifact の identity（PNE 自身が計算した hash） |
| `test/fixtures/pne/official_jp/bridge_identity.json` | 公式 2020 Japan IO から EDP → PNE で生成した bridge artifact の **identity metadata のみ**（部門 ID・ラベル・baseline・パスは含めない） |
| `test/fixtures/pne/official_jp/export_config.json` | 上記の生成に用いた geography / classification の宣言 |

再生成と PNE 側との drift 検査は、uv と PNE（official 用には EDP も）の checkout を用意して手動で行います。

```bash
# producer fixture を再生成する（PNE checkout は commit 済みの状態であること）
julia --project=. test/fixtures/pne/regenerate_cross_repo.jl producer --pne-repo ../production-network-engine

# drift 検査（書き込みなし）: producer fixture を再生成してバイト列を比較し、
# vendor コピー（上表）を PNE checkout の upstream_path と比較する。不一致は非 0 終了
julia --project=. test/fixtures/pne/regenerate_cross_repo.jl check --pne-repo ../production-network-engine

# official identity を再生成する（e-Stat から公式 workbook を取得する。--scratch はリポジトリの外）
julia --project=. test/fixtures/pne/regenerate_cross_repo.jl official-jp \
    --pne-repo ../production-network-engine --edp-repo ../economic-data-provider --scratch /path/outside/repo

# DME 側の golden（contract surface・report・hash chain）を再生成する
julia --project=. test/fixtures/pne/regenerate.jl
```

`test/test_pne_cross_repo_e2e.jl` は、vendor した schema から contract surface（必須キー・閉じた語彙・固定値・
数値範囲・文字列制約・`x-semantic-invariants`）を抽出して `test/fixtures/pne/golden/pne_contract_surface_v1.json`
と照合し、各制約を 1 つだけ破った文書を DME の decoder がすべて拒否することを検査します。PNE 側の schema を
再 vendor して契約面が変わった場合は、DME の再実装（`src/scenarios/pne_sector_output_path.jl`）と
[PNE sector-output-path 受け入れ契約](../../architecture/pne_sector_output_integration.md) を見直してから golden を
更新してください（詳細は同書 §21）。
