# PNE producer fixture（cross-repository E2E 用）

production-network-engine（PNE）の**実 producer 経路**（CLI）で生成した
`production-network-sector-output-path/v1` artifact と、その生成に用いた DME 所有の入力です（Issue #283）。
すべて架空であり、実在の経済・部門・企業・取引・予測・観測された途絶を表しません。

| パス | 内容 | 編集 |
|---|---|---|
| `inputs/network_fictional_customer_chain.json` | 架空の `production-network-input/v1` network。2 つの組立部門（`handset_assembly`・`vehicle_assembly`）が producer（`chip_fab`）と他の架空 supplier から調達する | DME 所有（編集したら再生成する） |
| `inputs/scenario_quarterly_supplier_disruption.json` | 四半期（anchor 2025-01-01・8 期）の PNE dynamic scenario。supplier 側の capacity shock が horizon 末までに回復する | 同上 |
| `inputs/scenario_monthly_supplier_disruption.json` | 月次（anchor 2025-04-01・12 か月）の同種の scenario | 同上 |
| `inputs/export_config.json` | 架空の geography（`dme-fictional-economy/v1` / `DME-FICTIONAL-A`）と classification の宣言 | 同上 |
| `v1/*.json` | PNE CLI が書いた artifact のバイト列そのもの | **手で編集しない** |
| `MANIFEST.json` | PNE の commit・入出力の SHA-256・DME の `content_hash`・PNE dynamic artifact の identity | 生成スクリプトが書く |

producer（`chip_fab`）の産出は全期 1.0 のまま、組立部門の産出だけが下がって回復するため、DME の
派生中間需要チャネル（`ext_demand_s2`）の受理条件 `DD-6`・`DD-8` を満たします。geography は CCC の
経済圏（US）ではないため、DME は `:hypothetical_override` の mapping
（`../mappings/ccc_producer_hypothetical_{quarterly,monthly}.json`）でのみ受理します。

再生成・drift 検査の手順は [docs/contract/pne/README.md](../../../../docs/contract/pne/README.md) を参照してください。
