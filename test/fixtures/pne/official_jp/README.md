# official Japan IO 由来 bridge artifact の identity（negative E2E 用）

公式 2020 Japan Input-Output Tables（e-Stat、統合中分類 108 部門）から economic-data-provider（EDP）→
production-network-engine（PNE）の実経路で生成した `production-network-sector-output-path/v1` artifact の
**identity metadata だけ**を置きます（Issue #283）。

- 公式表の再配布条件を確認していないため、公式 workbook・EDP が出力した network・shock 対象の部門 ID を含む
  scenario・bridge artifact 本体は commit しません。`bridge_identity.json` の `bridge` は artifact から
  `sectors` と `aggregate_path` を除いたもので、部門 ID・ラベル・baseline・産出パスを含みません。
- 生成時に DME が full artifact に対して計算した判定（`dme_observation`）を記録しています。US CCC へ入れる
  mapping は、どの transmission mode でも拒否されます（`same_economy` → `geography_mismatch`、
  `explicit_cross_economy` → `cross_economy_transmission_unavailable`、`hypothetical_override` →
  `hypothetical_override_requires_synthetic_source`。年次 IO の 1 期間は四半期へ整列できないため
  `unsupported_source_period_unit` も併せて報告されます）。
- テストは identity に架空の placeholder 部門（`DME-WITHHELD-*`）を付けて decode 可能な文書に戻し、同じ判定に
  なることを検査します（`test/test_pne_cross_repo_e2e.jl`）。

| パス | 内容 |
|---|---|
| `bridge_identity.json` | identity metadata（`dme.pne-bridge-identity/1.0.0`）。生成スクリプトが書く |
| `export_config.json` | 生成に用いた geography（`ISO 3166-1 alpha-2` / `JP`）と classification の宣言 |

再生成の手順は [docs/contract/pne/README.md](../../../../docs/contract/pne/README.md) を参照してください。
