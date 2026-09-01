# CCC 観測系列・proxy・source coverage matrix

`src/data/capex_credit_cycle_catalog.jl` の `CAPEX_CC_SERIES_CATALOG` が機械可読な正本である。この文書は同じ系列ID集合を、人が選定根拠・変換上の限界・EDPへの引き渡しを確認できる形で説明する。値の取得、四半期変換、較正は対象外であり、それぞれ #242、#243、#244 の責務とする。

## 境界と読み方

- 基準経済は米国、モデル時間は四半期である。`SAAR` のフローは measurement 層で `÷ 4` し、月次のフローは四半期内で `sum`、月次の水準・比率・指数は `mean` または期末 `end` にする。
- `D` は直接、`C` は明示した構成、`P` は概念差を持つproxy、`E` は潜在状態、`A` は観測不能でシナリオ仮定のみを表す。`P` の水準を直接fitの根拠にせず、`E`/`A` を較正・推定入力にしない。
- IDはDMEがEDPに要求する安定した `provider_series_id` である。`FRED_` IDはFREDの元IDを含む。`BEA_`、`BLS_`、`CENSUS_`、`FRB_` IDは一次統計の表・NAICS範囲を明示するEDP側の安定IDであり、現時点では未実装である。
- `market_data` の代替系列は自動fallbackではない。企業開示由来のものは `:firm_disclosure` として明示し、validatorが較正・推定roleを拒否する。

## coverage matrix

表の「単位・頻度・SA・実質性」はcatalogの `declared_*` フィールドを要約したもの。availabilityはcatalog宣言の開始期であり、最終sampleは #243 のdataset builderが `:calibration_required` の実データのinner joinで決める。

| Series ID | key → model variable | role / class / method | unit; native freq; SA; real/nominal | source・範囲・変換上の限界 | availability |
| --- | --- | --- | --- | --- | --- |
| `BEA_NIPA_FIXED_INVESTMENT_INFORMATION_PROCESSING_EQUIPMENT` | `capex_exec_s1_equipment` → `capex_exec_s1` | calibration_required / C / aggregation | chained $bn SAAR; Q; SAAR; real | BEA NIPA information-processing equipment。software・structuresと加算しSAARを÷4。S1より広い。 | 1947-Q1 |
| `BEA_NIPA_FIXED_INVESTMENT_SOFTWARE` | `capex_exec_s1_software` → `capex_exec_s1` | calibration_required / C / aggregation | chained $bn SAAR; Q; SAAR; real | BEA NIPA software。equipment・structuresと加算しSAARを÷4。S1外のsoftwareを含む。 | 1947-Q1 |
| `BEA_NIPA_FIXED_INVESTMENT_COMMERCIAL_HEALTH_CARE_STRUCTURES` | `capex_exec_s1_structures` → `capex_exec_s1` | calibration_required / C / aggregation | chained $bn SAAR; Q; SAAR; real | BEA NIPA commercial/health-care structures。データセンター専用の構築物ではない。 | 1947-Q1 |
| `CENSUS_M3_NAICS334_NEW_ORDERS` | `order_s2` → `order_s2` | calibration_required / D / aggregation | current $m; M; SA; nominal | Census M3 NAICS 334 new orders（cancellations控除後）。半導体だけでなく電子製品を含む。 | 1992-Q1 |
| `CENSUS_M3_NAICS333_NEW_ORDERS` | `order_s3_manufacturing` → `order_s3` | calibration_required / C / allocation | current $m; M; SA; nominal | Census M3 NAICS 333 new orders。建設分は次行のallocation keyで明示的に追加する。 | 1992-Q1 |
| `CENSUS_VIP_DATA_CENTER_CONSTRUCTION` | `data_center_construction` → `order_s3`, `capex_pipe_s1` | validation_only / P / proxy | current $m; M; NSA; nominal | Census Value of Construction Put in Place のdata-center候補。機器pipeline・電力接続を含まない。 | 2014-Q1 |
| `CENSUS_M3_NAICS334_UNFILLED_ORDERS` | `backlog_s2` → `backlog_s2` | calibration_required / D / aggregation | current $m EOM; M; SA; nominal | Census M3 NAICS 334 unfilled orders。期末残高であり、S2より広い。 | 1992-Q1 |
| `CENSUS_M3_NAICS333_UNFILLED_ORDERS` | `backlog_s3` → `backlog_s3` | validation_only / P / proxy | current $m EOM; M; SA; nominal | Census M3 NAICS 333 unfilled orders。建設・電力の受注残がなくS3を過小にする。 | 1992-Q1 |
| `CENSUS_M3_NAICS334_TOTAL_INVENTORIES` | `inv_s2` → `inv_s2` | calibration_required / D / aggregation | current $m EOM; M; SA; nominal | Census M3 NAICS 334 total inventories。M3定義の在庫価値を保存し、実質化は別段階。 | 1992-Q1 |
| `CENSUS_M3_NAICS333_TOTAL_INVENTORIES` | `inv_s3` → `inv_s3` | calibration_required / D / aggregation | current $m EOM; M; SA; nominal | Census M3 NAICS 333 total inventories。construction・utilitiesがなくS3を過小にする。 | 1992-Q1 |
| `CENSUS_M3_NAICS334_SHIPMENTS` | `ship_s2` → `ship_s2`, `deliv_s2` | calibration_required / D / aggregation | current $m; M; SA; nominal | Census M3 NAICS 334 shipments。名目はdelivery value、実質shipmentにはdeflatorが必要。 | 1992-Q1 |
| `CENSUS_M3_NAICS333_SHIPMENTS` | `ship_s3` → `ship_s3`, `deliv_s3` | calibration_required / D / aggregation | current $m; M; SA; nominal | Census M3 NAICS 333 shipments。S3 construction/electricity範囲は未充足。 | 1992-Q1 |
| `FRED_IPG3344S` | `y_s2_ip` → `y_s2` | estimation_input / C / proxy | index 2017=100; M; SA; index | FRB G.17 NAICS 3344 IP。BEA年次実質VAをanchorに水準化し、指数をそのまま水準にしない。 | 1972-Q1 |
| `FRED_IPG333S` | `y_s3_ip` → `y_s3` | estimation_input / C / proxy | index 2017=100; M; SA; index | FRB G.17 NAICS 333 IP。BEA年次実質VAをanchorに水準化。S3の建設・電力範囲を欠く。 | 1972-Q1 |
| `FRED_CAPUTLG3344S` | `util_s2` → `util_s2` | validation_only / P / proxy | percent; M; SA; ratio | FRB G.17 NAICS 3344 utilization。分母は同期の技術的capacityで、モデルのBOP分母と異なる。 | 1972-Q1 |
| `FRED_CAPUTLG333S` | `util_s3` → `util_s3` | validation_only / P / proxy | percent; M; SA; ratio | FRB G.17 NAICS 333 utilization。S3のconstruction/utilitiesを欠く。 | 1972-Q1 |
| `FRED_CAPG3344S` | `ycap_s2` → `ycap_s2` | validation_only / P / proxy | index 2017=100; M; SA; index | FRB G.17 NAICS 3344 capacity。baseline=1に再基準化する変化率proxyでありlevel比較しない。 | 1972-Q1 |
| `FRED_CAPG333S` | `ycap_s3` → `ycap_s3` | validation_only / P / proxy | index 2017=100; M; SA; index | FRB G.17 NAICS 333 capacity。S3より狭く、技術的capacityという概念差がある。 | 1972-Q1 |
| `BLS_PPI_NAICS334` | `price_s2` → `price_s2` | estimation_input / D / aggregation | PPI index; M; NSA; index | BLS PPI NAICS 334。baseline平均=1への再基準化が必要で、指数をlevelとして使用しない。 | 2003-Q1 |
| `BLS_PPI_NAICS333` | `price_s3` → `price_s3` | estimation_input / D / aggregation | PPI index; M; NSA; index | BLS PPI NAICS 333。S3のconstruction/utilitiesを含まない。 | 2003-Q1 |
| `BEA_GDPBYIND_NAICS334_REAL_VALUE_ADDED` | `va_s2` → `va_s2` | calibration_required / D / aggregation | chained $m SAAR; Q; SAAR; real | BEA GDP by Industry NAICS 334実質付加価値。SAARを÷4。S2より広い。候補binding series。 | 2005-Q1 |
| `BEA_GDPBYIND_NAICS333_REAL_VALUE_ADDED` | `va_s3` → `va_s3` | calibration_required / D / aggregation | chained $m SAAR; Q; SAAR; real | BEA GDP by Industry NAICS 333実質付加価値。SAARを÷4。S3より狭い。候補binding series。 | 2005-Q1 |
| `BEA_GDPBYIND_NAICS518_REAL_VALUE_ADDED` | `y_s1_proxy` → `y_s1` | validation_only / P / proxy | chained $m SAAR; Q; SAAR; real | BEA GDP by Industry NAICS 518。cloud/AI以外を含むためS1のvalidation-only proxy。 | 2005-Q1 |
| `BEA_FIXED_ASSETS_NAICS334_NET_STOCK` | `cap_s2` → `cap_s2` | validation_only / P / proxy | chained $bn EOY; A; n/a; real | BEA Fixed Assets NAICS 334 net stock。年末値から四半期へ明示的に配分し、高頻度fitには使わない。 | 1997-Q4 |
| `BEA_FIXED_ASSETS_NAICS333_NET_STOCK` | `cap_s3` → `cap_s3` | validation_only / P / proxy | chained $bn EOY; A; n/a; real | BEA Fixed Assets NAICS 333 net stock。S3 construction/power assetsを欠く。 | 1997-Q4 |
| `BEA_FIXED_ASSETS_NAICS334_DEPRECIATION` | `dep_s2` → `dep_s2` | validation_only / P / proxy | chained $bn annual; A; n/a; real | BEA Fixed Assets NAICS 334 depreciation。年次からの四半期配分と÷4を記録する。 | 1997-Q4 |
| `BEA_FIXED_ASSETS_NAICS333_DEPRECIATION` | `dep_s3` → `dep_s3` | validation_only / P / proxy | chained $bn annual; A; n/a; real | BEA Fixed Assets NAICS 333 depreciation。S3範囲より狭い。 | 1997-Q4 |
| `BEA_NIPA_TABLE_6_16_NAICS334_CORPORATE_PROFITS` | `profit_s2_proxy` → `profit_s2` | validation_only / P / proxy | current $m SAAR; Q; SAAR; nominal | BEA NIPA Table 6.16 industry aggregate corporate profits。企業開示ではないが、モデル利潤と会計概念が異なる。 | 2005-Q1 |
| `FRB_Z1_NONFINANCIAL_CORPORATE_DEBT` | `nfc_debt_total` → `debt_s1..s3` | validation_only / P / allocation | current $m EOP; Q; NSA; nominal | FRB Financial Accounts Z.1 aggregate NFC debt。部門別化には`sector_sales_share` allocationが必要。 | 1945-Q4 |
| `BEA_NIPA_CORPORATE_NET_INTEREST_PAYMENTS` | `nfc_net_interest` → `int_burden_s1..s3` | validation_only / P / allocation | current $bn SAAR; Q; SAAR; nominal | BEA aggregate corporate net-interest payments。debtと同一allocation keyを使い、SAARを÷4。 | 1947-Q1 |
| `FRED_BAMLH0A0HYM2` | `spread_hy` → `spread` | calibration_required / D / direct | percent; daily→M; NSA; ratio | ICE BofA US High Yield OAS（FRED）。主系列。日次はprovider側で月次化してからQ平均にする。 | 1996-Q4 |
| `FRED_BAMLC0A0CM` | `spread_ig` → `spread` | validation_only / P / proxy | percent; daily→M; NSA; ratio | ICE BofA US Corporate OAS（FRED）。HYを置換しないalternative proxy。 | 1996-Q4 |
| `FRED_DRTSCILM` | `lend_stance` → `lend_stance` | calibration_required / D / direct | net percent; Q; NSA; ratio | SLOOS C&I lending standards。正値は引締であり、measurementで符号を反転しない。 | 1990-Q2 |
| `FRED_NFCI` | `fin_cond` → `fin_cond` | calibration_required / D / direct | standardized index; weekly→M; NSA; index | Chicago Fed NFCI。正値は引締、baseline=0へ再中心化する。 | 1971-Q1 |
| `FRED_FEDFUNDS` | `policy_rate` → `policy_rate` | calibration_required / D / direct | annual percent; M; NSA; ratio | Effective Federal Funds Rate。四半期長への換算はモデル層の責務。 | 1954-Q3 |
| `MARKET_SOXX_TOTAL_RETURN` | `equity_val_sector` → `equity_val` | validation_only / P / proxy | index level; daily→M; NSA; index | semiconductor equity index。期待・割引率を含み変動が過大になりうる。実体支出と同一視しない。 | 1993-Q1 |
| `FRED_PAYEMS` | `emp_tot` → `emp_tot` | calibration_required / D / direct | thousand persons; M; SA; n/a | BLS CES total nonfarm payroll employment（FRED）。月次levelのQ平均。 | 1939-Q1 |
| `BLS_CES_NAICS51_ALL_EMPLOYEES` | `emp_s1` → `emp_s1` | estimation_input / D / aggregation | thousand persons; M; SA; n/a | BLS CES NAICS 51。S1 cloud/AI範囲より広い。 | 1990-Q1 |
| `BLS_CES_NAICS334_ALL_EMPLOYEES` | `emp_s2` → `emp_s2` | estimation_input / D / aggregation | thousand persons; M; SA; n/a | BLS CES NAICS 334。S2より広い。 | 1990-Q1 |
| `BLS_CES_NAICS333_ALL_EMPLOYEES` | `emp_s3_machinery` → `emp_s3` | estimation_input / C / aggregation | thousand persons; M; SA; n/a | BLS CES NAICS 333。S3のmachinery component。 | 1990-Q1 |
| `BLS_CES_NAICS23_ALL_EMPLOYEES` | `emp_s3_construction` → `emp_s3` | estimation_input / C / aggregation | thousand persons; M; SA; n/a | BLS CES NAICS 23。data-center限定でないconstruction component。 | 1990-Q1 |
| `BLS_CES_NAICS22_ALL_EMPLOYEES` | `emp_s3_utilities` → `emp_s3` | estimation_input / C / aggregation | thousand persons; M; SA; n/a | BLS CES NAICS 22。data-center向けだけではないutilities component。 | 1990-Q1 |
| `FRED_CES0500000003` | `wage` → `wage` | estimation_input / C / aggregation | dollars/hour; M; SA; nominal | BLS CES average hourly earnings（FRED）。GDPDEFで実質化するが、hours/benefitsは含まない。 | 2006-Q1 |
| `FRED_DSPIC96` | `hh_income` → `hh_income` | validation_only / P / proxy | chained $bn SAAR; M; SAAR; real | BEA real disposable personal income（FRED）。賃金以外の所得を含むためproxy、SAARを÷4。 | 1959-Q1 |
| `FRED_PCECC96` | `cons` → `cons` | validation_only / P / proxy | chained $bn SAAR; M; SAAR; real | BEA real PCE（FRED）。S1/S5以外の支出を含むためproxy、SAARを÷4。 | 1959-Q1 |
| `FRED_GDPC1` | `y_tot` → `y_tot` | calibration_required / D / direct | chained $bn SAAR; Q; SAAR; real | BEA real GDP（FRED）。モデルの四半期flowへSAARを÷4。 | 1947-Q1 |
| `UNAVAILABLE_AI_EXPECTATION` | `ai_exp_unavailable` → `ai_exp` | diagnostic_only / A / proxy | n/a; Q; unknown; n/a | AI需要期待を識別する公表集計系列はない。企業guidanceを期待と取り違えない。 | n/a |
| `UNAVAILABLE_HYPERSCALER_CAPEX_GUIDANCE` | `capex_plan_s1_unavailable` → `capex_plan_s1` | diagnostic_only / A / proxy | n/a; Q; unknown; n/a | 発行体集合を再現可能に固定できない企業guidance。initial MVPの較正・推定から除外。 | n/a |
| `UNAVAILABLE_HYPERSCALER_SEGMENT_FINANCIALS` | `s1_financials_unavailable` → `sales_s1`, `profit_s1`, `ocf_s1` | diagnostic_only / A / proxy | n/a; Q; unknown; n/a | S1集計を再現可能に定義できない企業segment財務。後続の別provider契約なしには使用しない。 | n/a |

## primary-source confirmation

系列の定義は「名前が似ている」ことではなく、公開元の定義・単位・頻度から採用した。Census M3はshipments/new orders/unfilled orders/inventoriesを定義し、new ordersはcancellations控除後、unfilled ordersとinventoryは期末値である。[M3 definitions](https://www.census.gov/manufacturing/m3/definitions/index.html) と [M3 survey coverage](https://www.census.gov/manufacturing/m3/about_the_surveys/index.html) を正本とする。M3の業種・NAICS改訂は履歴episode選定時にも確認し、半導体を単独に観測する系列であるかのようには扱わない。

FRB産業生産・capacity・utilizationは [G.17](https://www.federalreserve.gov/releases/g17/) を正本とする。capacity utilizationはoutput indexをcapacity indexで除した指標であるため、モデルの期首資本を分母とする`util_s`と水準同一視しない。BEAの [NIPA tables](https://apps.bea.gov/itable/?ReqID=19&step=2)、[GDP by Industry](https://apps.bea.gov/iTable/?ReqID=120&step=1)、[Fixed Assets](https://apps.bea.gov/iTable/?ReqID=10&step=1) は表ID・基準年・年率表記をEDPが返すべき一次資料である。雇用・PPIは [BLS CES](https://www.bls.gov/ces/) と [BLS PPI](https://www.bls.gov/ppi/) を、金融口座は [Federal Reserve Financial Accounts](https://www.federalreserve.gov/releases/z1/) を正本とする。

## EDP capability handoff

2026-09-01に `economic-data-provider` のmainを照合した。`/v1/catalog/series` は実質金利のcatalogを返すだけで、CCC向けの `/v1/series/{series_id}`、Census/BEA/BLS/FRBの上記系列、対応fixtureは実装されていない。`FEDFUNDS` はcatalogにあるがvintage/as-of能力を示すfieldがない。`GDPC1` はfixtureに存在する一方でseries catalogに存在せず、catalog・live・fixtureのparityも未達である。

`CAPEX_CC_PROVIDER_GAPS` は、次の不足を個別keyへ結び付けてmachine-readableに出力する。

| gap kind | upstream capability needed | DMEの扱い |
| --- | --- | --- |
| `missing_series` | BEA NIPA/GDP-by-Industry/Fixed Assets、Census M3・construction、BLS PPI/CES、FRB G.17/Z.1、SLOOS/NFCI、OASのcatalogとseries endpoint | DMEは直接HTTP fallbackを追加しない。#242でEDP responseをdecoderへ渡す。 |
| `missing_metadata` | series definition、unit、SA、base year、availability boundsをprovider responseで返す | DMEの`declared_*`をprovider metadataへコピーしない。未申告は`missing`。 |
| `missing_frequency` | 年次Fixed Assetsと日次/週次金融系列の明示的frequency contract | #243がcatalog宣言どおりにmeasurementし、暗黙変換しない。 |
| `missing_history` | data-center construction等の短い履歴と開始日を明示 | episode選定で不足期間を除外し、ゼロ埋めしない。 |
| `missing_fixture_parity` | catalog、live、fixtureが同じseries ID・schemaを返す | `GDPC1`を含め一致するまで#242はraw datasetを構築しない。 |
| `missing_vintage` | provider_vintage/data_vintageの表示能力 | 初期MVPは`:latest_only`。未申告は`"unknown"`で、`:as_of`再生とは申告しない。 |

## expected common sample

catalog上の最も遅い較正必須の開始候補はBEA四半期GDP-by-Industryの `va_s2` / `va_s3`（2005-Q1）である。従って**想定される共通sampleの開始候補は2005-Q1**、binding series候補はこの2系列である。ただしこれはavailability宣言に基づく見込みであり、最終端点・内部欠損・`binding_series`は#243のdataset builderが実データのinner joinから決定する。`data_center_construction`（2014-Q1）はvalidation-onlyのため標本を短縮しない。

## export contract

`capex_series_catalog_to_dict()` はcatalog version、全spec、全provider gapを正準JSONに変換できる辞書として返す。`save_capex_series_catalog(path)` は同じ内容を一時ファイルへ書き、`fsync`後にatomic renameする。これはcross-repository handoffであり、取得値・credential・provider URL・observed dataを保存しない。
