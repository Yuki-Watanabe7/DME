# CCC 履歴再生候補（`H1`–`H6`）の選定基準と NC-1–NC-7 判定機構

`src/analysis/capex_credit_cycle_history.jl` の `CAPEX_CC_EPISODE_SPECS`（`H1`–`H6`）と `assess_capex_episodes` が機械可読な正本である。この文書は選定基準（[観測方程式・識別戦略・検証方針](../models/capex_credit_cycle_empirical_strategy.md) §9）を `NC-1`–`NC-7` の判定機構としてどう実装したか、各候補の `L1`（`ObservedEvent`）・特殊要因・データ定義断絶・想定診断ラベルをどう固定したかを説明する。**replay の実行（`capex_run` 呼び出し・パラメータ推定）はここに含まれない**（#248 / P-8 の責務）。

## 位置づけ

- 本書・本モジュールは Issue #247（P-7）の成果物である。依存は #243（`CapexEmpiricalDataset`）のみで、#244–#246（較正・識別・推定）には依存しない。
- `H1`–`H6` の**最終選定**（`:selected` / `:excluded` / `:insufficient_data`）は本書では固定しない。`assess_capex_episodes(ds)` が実際の `CapexEmpiricalDataset` に対して機械的に判定する（[実証戦略](../models/capex_credit_cycle_empirical_strategy.md) §9.2「期間の最終選定は実装フェーズで行う」）。
- **2026-09 の現在局面（AI・半導体 CAPEX 調整）は `H1`–`H6` に含まれない。** `CAPEX_CC_EPISODE_IDS` は `(:H1, :H2, :H3, :H4, :H5, :H6)` に固定されており、現在局面は #260 の live holdout としてのみ扱う。

## `NC-1`–`NC-7` の判定方法（実証戦略 §9.1 の実装）

| ID | 必要条件 | 本モジュールでの判定方法 |
|---|---|---|
| `NC-1` | 必須観測系列（`EB-1`・`EB-3`・`EB-6`・`EB-7` の `required_keys` の和集合、17変数）が助走+評価の全期間で利用可能 | `CAPEX_CC_EPISODE_REQUIRED_MODEL_VARS` の各 model var を、`ds.measurements` から `model_vars` で逆引きし、四半期ごとに欠損の有無を機械的に判定する。`role` ではフィルタしない（`:cons`・`:hh_income` は catalog 上 `validation_only` だが `EB-7` の観測入力として使う。下記「role非依存の理由」参照） |
| `NC-2` | `order_s2`・`capex_exec_s1`・`spread`・`emp_tot` の4系列に、悪化開始時点を識別できる変動がある | 助走期間平均を baseline とし、評価期間内の peak 乖離を `CapexDiagnosticThresholds`（分析契約 §4.2 `G1`–`G4`）の `di_sector`（`order_s2`・`capex_exec_s1`）・`dl`（`emp_tot`）・`spread_bp`（`spread`）と比較する。診断層の既定閾値を共有し、独自の数値を新設しない |
| `NC-3` | 単一の特殊要因だけで説明されない | `special_factors::Vector{Symbol}`（`CAPEX_CC_SPECIAL_FACTOR_KINDS` の4種: `financial_crisis`・`supply_shock`・`policy_regime_shift`・`statistical_definition_change`）が2件以上なら不成立。この4種**以外**の同時発生要因（商品価格変動・通商政策等）は対象に含めない（下記「NC-3の対象外とした確認事項」参照） |
| `NC-4` | データ revision・定義変更を追跡できる | `data_definition_break_resolved::Bool`（人手判定。下記「NC-4の判定根拠」参照） |
| `NC-5` | baseline 期間と out-of-sample 期間を確保できる | 助走+評価の窓が `ds.dates` の実際の利用可能期間（最古四半期〜最新四半期）に収まるかのみを機械的に判定する。`runup_deviation`（定常近傍かどうか）はモデル実行を要するため対象外とし、P-8 の replay 実行時に別途確認することを `nc_details` に明記する |
| `NC-6` | `ai_exp` の代替構成が2/3仕様以上で定義できる（実証戦略 §8.2 `ID-1`） | (a) 定数=1（常に可）、(b) `y_s1_proxy` の window内可用性、(c) `equity_val_sector` の window内可用性、の3仕様のうち可用な数を数える |
| `NC-7` | 候補集合全体として `broad_downturn` 想定・`contained_adjustment` 想定を最低1件ずつ含む | `NC-1`–`NC-6` をすべて満たす episode の集合（`eligible`）の中で、`expected_diagnostic_label`（事前の想定ラベル。下記参照）が `:broad_downturn` の episode が1件以上・`:contained_adjustment` の episode が1件以上あるかを判定する。**同一の判定値を候補集合内の全 episode が共有する**（集合レベルの必要条件のため） |

### role非依存の理由（`NC-1`・`NC-2`）

`NC-1`・`NC-2` のモデル変数への投影は、[実証較正層](../architecture/capex_credit_cycle_empirical_integration.md) §7.2 の `_capex_project_observations`（steady-state target 構築）と同じ規約を四半期ごとに適用する。catalog の `role`（`calibration_required` / `estimation_input` / `validation_only`）は「`:calibration_required` の inner join に使うか」という #243 の軸であり、「この model var を観測できるか」という history 層の問いとは別の軸である。`EB-7` の `required_keys` である `:cons`・`:hh_income` は catalog 上 `role=:validation_only`（両者が proxy でありモデルの `cons` は部門範囲が狭いため、[観測系列 coverage matrix](capex_credit_cycle_series_catalog.md) 参照）だが、観測可能性としては使える。`role` でここを絞ると `EB-7` 対象の2キーが常に「欠損」と誤判定される。

結合規約は、単一ソースはそのまま、複数ソースがすべて `:aggregation`（`capex_exec_s1` の equipment/software/structures、`emp_s3` の machinery/construction/utilities）なら和、それ以外（`spread` の `spread_hy`/`spread_ig`）は平均とする。`allocation` methodology の按分（`nfc_debt_total` 等）は `NC-1`・`NC-2` の対象変数に現れないため実装しない。

### `NC-3` の対象外とした確認事項

[実証戦略](../models/capex_credit_cycle_empirical_strategy.md) §9.2 の懸念表は `H4`（エネルギー価格急落）・`H5`（通商政策）に「別要因の併存」を挙げるが、これらは `NC-3` が数える4種（金融危機・パンデミック等供給制約・大規模財政金融政策の急転・統計定義変更）のいずれにも厳密には該当しない。本書は `NC-3` の定義を拡張せず、`H4`・`H5` の `special_factors` を空とし、解釈上の confound（交絡）として `interpretation_notes`／`notes` へ記録するにとどめる。混同すると特殊要因の判定範囲が際限なく広がるため。

### `NC-4` の判定根拠

`H1`（2000–2003）は [実証戦略](../models/capex_credit_cycle_empirical_strategy.md) §9.2 で「NAICS 1997→2002 改訂」への懸念が挙げられている。本書は `data_definition_break_resolved=true` とした。理由: [観測系列 coverage matrix](capex_credit_cycle_series_catalog.md) の `y_s2`/`y_s3` は FRB 鉱工業生産指数（`IPG3344S`/`IPG333S`）を採用しており、これは provider が現行 NAICS 分類で継続的に再基準化する系列である（BEA GDP-by-Industry の年次改定と同様、過去分類との接続を都度遡及適用する）。#241 の系列選定時点でこの点を確認済みであり、[実証戦略](../models/capex_credit_cycle_empirical_strategy.md) §9.2 が想定した懸念は本カタログの系列選択により実務上は解消していると判断する。他の5候補には期間内の系列定義変更の懸念は無い。

### `NC-1`/`NC-5` に関する既知の制約（実データ確認待ち）

以下は本書が事前に把握している、実データに対する機械判定で `NC-1`/`NC-5` の不成立が濃厚な事実である。**本モジュールはこれらを先取りして `H1`–`H6` の `special_factors`/`data_definition_break_resolved` 等へ反映しない**（NC-1/NC-5はデータ依存であり、`assess_capex_episodes` が実データに対して判定する）。

- [観測系列 coverage matrix](capex_credit_cycle_series_catalog.md) §「expected common sample」: catalog 上の較正必須系列全体（`NC-1` の17変数に限らない）の inner join は、`va_s2`/`va_s3`（BEA 四半期 GDP-by-Industry、availability 2005-Q1）に拘束され、**想定される共通 sample の開始候補は 2005-Q1** である。`H1` の助走区間（起点 2000-Q4 の8四半期前 = 1998-Q4）はこれより大幅に早く、`dataset` に該当四半期が存在しない可能性が高い（`NC-5` 不成立の候補）。
- `wage`（`FRED_CES0500000003`、`EB-6` 必須）は availability 2006-Q1 である。`H1` の助走区間はこれより早く、`NC-1` 不成立の候補になる。
- `H6`（2022Q3–2023）は [実証戦略](../models/capex_credit_cycle_empirical_strategy.md) §9.2 自身が「期間末が最新データに近く評価20四半期を確保できない可能性」を指摘している（`Z-30`）。評価終端が dataset の最新四半期を超える場合、`NC-5` が機械的に不成立と判定する。

## `H1`–`H6` の固定内容

| ID | 期間（`period_zero`、助走/評価） | 起点イベント（`L1`） | `special_factors` | `data_definition_break_resolved` | 想定診断ラベル（`NC-7`専用） |
|---|---|---|---|---|---|
| `H1` | 2000Q4（8Q/20Q） | ITバブル崩壊後のIT・半導体設備投資減速（NBER景気循環日付、2001年3月山） | なし | `true`（FRB IP指数の再基準化で解消と判断） | `broad_downturn` |
| `H2` | 2008Q3（8Q/20Q） | 世界金融危機下の信用スプレッド急拡大（Lehman Brothers破綻、2008年9月15日） | `financial_crisis`・`policy_regime_shift`（2件併存） | `true` | `broad_downturn` |
| `H3` | 2011Q3（8Q/20Q） | タイ洪水によるサプライチェーン混乱＋半導体在庫調整 | なし | `true` | `contained_adjustment` |
| `H4` | 2015Q3（8Q/20Q） | 原油価格急落（2014年11月OPEC総会）＋半導体メモリ需要減速 | なし（エネルギー価格急落はNC-3の4種に非該当） | `true` | `sectoral_downturn` |
| `H5` | 2018Q4（8Q/20Q） | 対中制裁関税第3弾（2018年9月24日発効）に伴う半導体受注調整 | なし（通商政策はNC-3の4種に非該当） | `true` | `contained_adjustment` |
| `H6` | 2022Q3（8Q/20Q） | 急速な政策金利引き上げ（2022年6月FOMC 75bp）＋メモリ・PC需要減速 | `policy_regime_shift` | `true` | `sectoral_downturn` |

各 `ObservedEvent`（`L1`）は NBER・FOMC・USTR・EIA・SIA/WSTS 等の一次資料を `EventSource` として保持する。**`magnitude` はいずれも欠測のままとする**（実証戦略が禁じる「観測イベントにmagnitudeがない場合の暗黙数値化」を避けるため）。`H6` のみ、`L1`（`H6-OE2`、メモリ・PC需要減速。magnitude欠測）に対応する `L3`（`H6-SA1`）を1件持ち、`magnitude_source=:assumed_default` として例示的な仮定値（-10%）を明示する。この assumption は **`L1` へ書き戻されず**、かつ replay 実行（P-8）が使うかどうかを別途決定する記録専用の値である（`assess_capex_episodes` の `NC-1`–`NC-7` 判定には使わない）。

## `NC-7`（集合レベル）に関する留意事項

`NC-7` は「`NC-1`–`NC-6` をすべて満たす候補の中で `broad_downturn` 想定・`contained_adjustment` 想定を最低1件ずつ含む」ことを求める。上表の想定ラベルでは `broad_downturn` 想定は `H1`・`H2` の2件のみである。しかし:

- `H1` は前節のとおり `NC-1`/`NC-5` が実データに対して不成立になる可能性が高い（`wage` の availability 2006-Q1、較正必須系列全体の想定共通sample開始候補 2005-Q1）。
- `H2` は `special_factors=[:financial_crisis, :policy_regime_shift]`（2件併存）のため `NC-3` が不成立である。

両者がともに不成立となった場合、**`NC-1`–`NC-6` をすべて満たす候補の中に `broad_downturn` 想定が1件も残らず、`NC-7` は候補集合全体として不成立になる**。この場合、`H3`–`H6` のうち `NC-1`–`NC-6` を満たす候補があっても `:selected` にはならず（`assess_capex_episodes` の集合レベル判定）、達成可能な履歴再生候補集合が `contained_adjustment`/`sectoral_downturn` 系のみに限定される事実を、閾値や `NC-3` の定義を緩めることなくそのまま報告する（[実証戦略](../models/capex_credit_cycle_empirical_strategy.md) §9.2 契約1・ADR 0012 決定20「post-hocで最もfitの良いepisodeのみ残すことを対象外とする」の遵守）。**実データに対する最終判定は `assess_capex_episodes(ds)` を実行して確認する。**

## 出力・再現契約

- `assess_capex_episodes(ds; specs=CAPEX_CC_EPISODE_SPECS)` は `Vector{CapexEpisodeAssessment}` を返す。各要素は `status`（`:selected`/`:excluded`/`:insufficient_data`）・`nc_results`（`NC1`–`NC7` の真偽）・`nc_details`（判定根拠の文章）・`missing_keys`・`coverage_start`/`coverage_end`・`exclusion_reason`・`episode_hash`・`metadata` を持つ。
- `metadata["replay_kind"] = "revised_data_historical_replay"` を全 episode で固定する。**これは改定後データによる履歴再生であり、"当時入手可能だった情報だけの再現"（point-in-time replay）ではない**（`:as_of` 非実装、`Z-21`）。
- `episode_hash` は episode spec（`L1`/`L3`・window・`special_factors`・`data_definition_break_resolved`・`expected_diagnostic_label`）と `ds.metadata["dataset_hash"]` から `sha256_hex_of_canonical` で決定論的に生成する。同一 source/config から同一 identity となる。
- `capex_episode_spec_to_dict(ep)` / `capex_episode_assessment_to_dict(a)` / `save_capex_episode_assessment(path, a)` で再現に必要な公開情報を辞書化・保存できる。API キー・provider URL 以外のローカルパス・秘密情報は含まない（`EventSource.url` は一次資料の公開URL）。

## 対象外

- replay の実行（外生パス構築・`capex_run` 呼び出し・会計検証・診断）: [#248 / P-8](https://github.com/Yuki-Watanabe7/DME/issues/248)。
- パラメータ推定・較正: #244–#246（P-4–P-6）。
- `:as_of` / real-time vintage replay。
- 2026-09 現在局面を用いたモデル・閾値の調整: [#260](https://github.com/Yuki-Watanabe7/DME/issues/260) の live holdout 専用。
