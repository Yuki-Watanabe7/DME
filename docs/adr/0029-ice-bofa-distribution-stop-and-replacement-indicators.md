# ADR 0029: ICE BofA 2系列の提供停止への追従と代替指標

- **ステータス**: 採用
- **日付**: 2026-11-08
- **関連Issue**: [#312](https://github.com/Yuki-Watanabe7/DME/issues/312)（本決定）・Yuki-Watanabe7/economic-data-provider#313（EDP ADR 072、契約6.0.0）
- **前提ADR**: [ADR 0028](0028-public-repository-scope.md)（public リポジトリとして公開してよい範囲）・[ADR 0019](0019-long-rate-funding-shock-contract.md)（長期金利・funding-cost shock の分離）・[ADR 0018](0018-capex-credit-cycle-empirical-runtime-contract.md)（CCC 実証層）
- **関連ドキュメント**: [金融ストレス観測 利用ガイド](../data/financial_stress.md)・[CCC 観測系列 coverage matrix](../data/capex_credit_cycle_series_catalog.md)・[CCC 実証化戦略](../models/capex_credit_cycle_empirical_strategy.md) §17

---

## コンテキスト

economic-data-provider（EDP）は契約6.0.0（EDP ADR 072、2026-11-07）で、FRED 経由の ICE BofA 2系列の提供を停止した。

| series_id | 名称 | DME での用途 |
|---|---|---|
| `BAMLH0A3HYC` | ICE BofA CCC & Lower US High Yield Index OAS | 金融ストレス観測 `:ccc_oas`。`weak_credit_state` の入力 |
| `BAMLH0A0HYM2` | ICE BofA US High Yield Index OAS | 金融ストレス観測 `:broad_hy_oas`。CCC 実証 catalog `:spread_hy`（`spread` の主系列、較正必須） |

FRED の権利区分は "Copyrighted: Pre-Approval Required" で、注記は ICE Data の書面の承認なしに第三者へ提供することを禁じている。停止後の `GET /v1/series/{id}` は HTTP 410 と `{"detail": {"code": "distribution_stopped", "reason_code": "redistribution_rights", ...}}` を返す。EDP はカタログ外の FRED 系列の中継を続ける（EDP ADR 072 決定5）。

DME 側には次の問題があった。

1. 2系列を取得しようとすると、410 が `:provider_error`（障害）として記録され、意図した提供停止と区別できない。
2. `weak_credit_state` の入力が恒久的に得られないのに、`:insufficient_data`（一時的なデータ不足）として扱われる。
3. CCC 実証 catalog の alternative proxy `:spread_ig`（`BAMLC0A0CM`、ICE BofA US Corporate Index OAS）も、EDP の catalog には無いが、FRED の系列ページに同じ区分・同じ注記がある（2026-11-08 確認）。

利用者は、指標を外すのではなく、なるべく代替を探す方針を示した（2026-11-08）。

## 決定

### 1. 代替系列の条件

代替系列は次の3点をすべて満たすものから選ぶ。

1. FRED の権利区分が "Public Domain: Citation Requested" で、注記に第三者の著作権表示が無い。
2. EDP の FRED 中継（`GET /v1/series/{id}`）で取得でき、EDP の変更を要しない。
3. 置き換える指標の構造（金融ストレス観測は「下位階層 − 上位階層」の同日差分、CCC の `spread` は「社債利回り − 国債利回り」）を保てる。

区分と開始時期は FRED の系列ページで確認した（2026-11-08）。

| series_id | 名称 | 出典 | 頻度 | 開始 | FRED 区分 |
|---|---|---|---|---|---|
| `RIFSPPNA2P2D30NB` | 30-Day A2/P2 Nonfinancial Commercial Paper Interest Rate | FRB Commercial Paper | 日次 | 1997-01-02 | Public Domain: Citation Requested |
| `RIFSPPNAAD30NB` | 30-Day AA Nonfinancial Commercial Paper Interest Rate | FRB Commercial Paper | 日次 | 1997-01-02 | 同上 |
| `RIFSPPNA2P2D90NB` | 90-Day A2/P2 Nonfinancial Commercial Paper Interest Rate | FRB Commercial Paper | 日次 | 1998-01-02 | 同上 |
| `HQMCB10YRP` | 10-Year High Quality Market (HQM) Corporate Bond Par Yield | 米財務省 | 月次 | 1984-01 | 同上 |
| `GS10` | 10-Year Treasury Constant Maturity（月次平均） | FRB H.15 | 月次 | 1953-04 | 同上 |
| `TB3MS` | 3-Month Treasury Bill Secondary Market Rate, Discount Basis | FRB H.15 | 月次 | 1934-01 | 同上 |

### 2. `weak_credit_state` は CP の格付け階層差で観測する

金融ストレス観測 catalog（`financial-stress-catalog/2.0.0`）の credit-tier 2系列を、30日物 A2/P2 非金融 CP 金利（`:cp_a2p2_nonfinancial_30d`）と AA 非金融 CP 金利（`:cp_aa_nonfinancial_30d`）に置き換える。差分は `cp_a2p2_minus_aa_bp`（`ccc_minus_broad_hy_oas_bp` の置き換え）で計算する。

- 30日物を選んだのは、A2/P2 と AA の両方が同じ release・同じ満期で揃い、満期や発行体区分の差を差分に持ち込まないためである。
- role は `credit_tier_lower_cp_rate`・`credit_tier_upper_cp_rate` とし、EDP が削除した `credit_stress_ccc_oas`・`credit_stress_broad_hy_oas` の名前を引き継がない。観測対象が違うためである。
- `WeakCreditState` に `measure`（`WEAK_CREDIT_MEASURE`）を持たせ、`ccc_oas_latest` を `lower_tier_rate_latest` に置き換える。assessment を `financial-instability-holdout/2.0.0`、比較を `financial-instability-comparison/2.0.0` にする。
- 閾値 `weak_credit_watch_bps`/`weak_credit_confirmed_bps`（30/75 bp）の数値は変えず、rule を `financial-instability-rule/2.0.0` にする。適用対象が変わったことを版で示す。数値は新しい指標に対して較正した値ではない（較正は別Issue。#260 と同じく、2026-09 の観測を閾値の選定に使わない）。
- 合成 fixture（`test/fixtures/data/financial_stress/series/`）は、ICE BofA 名の2ファイルを削除し、CP 名の2ファイルを追加する。値は fictional で、旧 fixture と同じ日付・同じ欠測位置・同じ乖離拡大幅（46 bp）にした。

### 3. CCC の `spread` は「社債利回り − 国債利回り」を measurement 層で構成する

公表統計と FRED の Public Domain 区分に、スプレッドそのものを提供する社債系列は無い。そこで `CapexSeriesSpec` に `reference_key` を追加し、measurement 層が「系列 − reference 系列」を構成する。

| key | 構成 | role | 分類 |
|---|---|---|---|
| `:spread_hqm_corporate` | `HQMCB10YRP − GS10` | `calibration_required`（主系列） | `C`・`proxy`・`scope_bias = :under` |
| `:spread_cp_a2p2` | `RIFSPPNA2P2D90NB − TB3MS` | `validation_only`（alternative proxy） | `C`・`proxy`・`scope_bias = :indeterminate` |
| `:treasury_10y`・`:treasury_bill_3m` | 参照脚（モデル変数なし） | 差分系列と同じ role | `D`・`direct` |

- 両脚をそれぞれの観測方程式で四半期化した後、同じ四半期の差を取る。片方が欠測の四半期は欠測のままにする。
- 参照脚を測定できない場合は差分を作らず、`measurement_failed` として記録する。
- validator は、`reference_key` を持つ系列に `observability = :C`・水準系列・`methodology ∈ (:direct, :proxy)` を要求し、参照脚と単位・頻度・時点基準・集計方式が一致すること、参照の連鎖が無いことを検査する。参照脚が部分 catalog に無いことは許す（measurement 層で fail closed になる）。
- HQM は par yield を使い、国債の CMT（par yield）と対にする。spot rate（`HQMCB10YR`）と CMT を混ぜない。
- alternative proxy の CP は90日物を使い、3か月 T-bill と満期を揃える。
- [CCC 実証化戦略](../models/capex_credit_cycle_empirical_strategy.md) を `capex-credit-cycle-empirical/1.3.0` に改訂し（§17）、HY・CCC 層を観測しなくなる限界を記録する。

### 4. EDP の 410 `distribution_stopped` を独立の status にする

- `_DataProviderHTTPError` に `error_code`・`reason_code` を持たせる。200 以外の応答本文から `detail.code` と `detail.reason_code` だけを取り出す。どちらも短い小文字トークン（`^[a-z][a-z0-9_]{0,63}$`）に限り、`detail.message` などの自由記述は保持しない。
- `FINANCIAL_STRESS_RAW_STATUSES` に `:distribution_stopped` を追加する。HTTP 410 かつ `detail.code == "distribution_stopped"` のときに限り使う。`detail` に `reason_code` を残す。それ以外の 410（`symbol_migrated` など）は `:provider_error` のままとする。
- `trigger_state`・`weak_credit_state`・`funding_state` に `input_statuses`（入力系列ごとの raw status）を持たせる。`label` の語彙（`FINANCIAL_INSTABILITY_STATUSES`）は変えない。`:insufficient_data` の原因が提供停止か一時的な欠測かは `input_statuses` で判別する。

### 5. 再配布できない系列を catalog に戻せないようにする

`_REDISTRIBUTION_EXCLUDED_SERIES`（`src/data/data_provider.jl`）に `BAMLH0A0HYM2`・`BAMLH0A3HYC`（EDP が提供停止）と `BAMLC0A0CM`（DME が同じ権利表示を確認して除外）を記録する。金融ストレス観測と CCC 実証の両 catalog の validator は、前後の空白・大文字小文字・`FRED_` 接頭辞を無視して照合し、これらの ID を拒否する。

## 見送りとした選択肢

| 選択肢 | 見送った理由 |
|---|---|
| `weak_credit_state` を `:not_supported` で明示的に外す（Issue の案A） | `:not_supported` は「判定できて、支持されない」を意味する語彙で、「判定できない」に転用すると語彙の意味が変わる。dimension が減ると、`overall_status` の判定に使える補助 dimension が3つから2つになる。利用者は代替を探す方針を示した |
| Moody's の Baa・Aaa 利回り（`DBAA`・`DAAA`・`BAA10Y` 等） | FRED 区分が "Copyrighted: Citation Required" で、注記に Moody's の著作権表示（"protected by copyright and other intellectual property laws"）がある。EDP は "Citation Required" を第三者所有の系列の所有者の許可として扱わない（EDP #266）。今回停止された系列と同じ種類のリスクが残る |
| `CPFF`（3-Month Commercial Paper Minus Federal Funds Rate） | CP 金利と政策金利の差であり、格付け階層間の差ではない。FRED 区分も "Copyrighted: Citation Required" である |
| Gilchrist–Zakrajšek spread・excess bond premium（FRB） | FRB が FEDS Notes の付属データとして公表する月次系列で、FRED 中継で取得できることを確認していない。EDP に新しい供給源の追加が要る（EDP の変更は Issue #312 の範囲外）。月次のため日次の `weak_credit_state` には使えない。CCC の `spread` の候補としては将来検討の余地がある |
| HQM の spot rate（`HQMCB10YR`）− `GS10` | spot rate と par yield（CMT）を混ぜることになる |
| ICE Data の許諾を得て継続する | Issue #312 の範囲外（許諾申請・データ購入は含めない） |
| 410 を `:missing_series` に寄せる、または `detail` の文字列だけで区別する | 一時的なデータ不足と恒久的な提供停止が同じ status になり、集計（`status_counts`）や handoff の `unavailable_evidence` で区別できない |

## 影響

- **観測できなくなるもの**: HY・CCC 社債の信用リスク。`weak_credit_state` は短期・投資適格の CP 発行体を、CCC の主系列は AAA/AA/A の社債を観測する。どちらも信用ストレス局面の拡大幅を HY 指標より小さく見せうる。CP を発行できない、または発行を止めた企業の状態は反映しない。
- **比較できないもの**: assessment 1.0.0（ICE BofA 指標）と 2.0.0 の比較は、版の不一致により `:insufficient_comparable_data` になる。1.0.0 にしか無いフィールドは比較値を `null` にし、例外で止めない。CCC の `targets_hash` は `spread` の観測式の記述が変わるため変わる（golden fixture を更新した）。
- **EDP 本番の反映時期に依存しない**: DME は停止系列を要求しなくなるため、EDP の本番イメージ更新の前後どちらでも動く。
- **残る課題（本ADRの範囲外）**: CCC の provider adapter は EDP の `/v1/catalog/series` に載っている系列だけを取得するため、`spread` の4系列は provider gap（`:missing_series`）のままである。CCC catalog の `FRED_` 接頭辞付き ID を EDP が解決するかは Issue #312 の「関連して見つかったこと」として別途確認する。
