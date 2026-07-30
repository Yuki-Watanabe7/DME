# 部門別CAPEX・信用循環モデル 観測方程式・識別戦略・検証方針

> 関連 Issue: #170（本書）・#163（分析契約）・#164（因果グラフ）・#165（部門境界と変数定義）・#166（ストック・フロー会計表）・#167（責務境界）・#168（イベント変換・時間軸）・#169（動学方程式）・#171（統合）・#125（ロードマップ）
> 前提: [分析契約](capex_credit_cycle_analysis_contract.md)・[部門境界と変数定義](capex_credit_cycle_sectors_variables.md)・[ストック・フロー会計表](capex_credit_cycle_stock_flow.md)・[責務境界](capex_credit_cycle_model_boundaries.md)・[イベント変換契約](../architecture/macro_event_contract.md)・[シナリオ時間軸](../architecture/scenario_time_semantics.md)・[動学方程式と数値計算契約](capex_credit_cycle_equations.md)
> 設計原則の継承元: [Keen モデル 実証化戦略](keen_empirical_strategy.md)（測定・識別・頻度整列）・[ADR 0004](../adr/0004-keen-empirical-calibration-strategy.md)（固定/推定分離）・[ADR 0005](../adr/0005-keen-ai-explanation-contract.md)（根拠階層）

---

## メタ情報

| 項目 | 内容 |
|---|---|
| **対象** | 部門別CAPEX・信用循環モデル（`CapexCreditCycleModel` 相当、未実装） |
| **ステータス** | 観測方程式・識別戦略・検証契約のみ確定。データ取得コード・パラメータ推定・履歴再生の実行は未着手 |
| **empirical version** | `capex-credit-cycle-empirical/1.1.0` |
| **上位契約** | `capex-credit-cycle-contract/1.0.0`・`capex-credit-cycle-graph/1.1.0`・`capex-credit-cycle-vars/1.2.0`・`capex-credit-cycle-accounting/1.1.0`・`capex-credit-cycle-boundaries/1.0.0`・`capex-credit-cycle-equations/1.1.0`・`macro-event-contract/1.0.1`・`scenario-time-semantics/1.0.0` |
| **改訂の優先関係** | **§15（#171 統合レビューによる改訂）が本書の正本である。§5.2・§7.1・§7.2・§7.4・§7.5 の一部は §15 で上書きされている。較正・推定の前に §15 を読むこと。** |
| **基準経済・頻度** | 米国・四半期（`Δt = 0.25` 年。契約 §2.1 を継承） |
| **決定記録** | [ADR 0012](../adr/0012-capex-credit-cycle-empirical-contract.md) |

> **LLM向け要約**: 本書は、部門別CAPEX・信用循環モデルを実データへ接続する際の
> **観測可能性の分類**（§3）・**観測方程式**（§4）・**逆較正が必要とする定常水準の観測対応**（§5）・
> **データソース境界**（§6）・**パラメータの固定/較正/限定推定/シナリオ/感応度の区分**（§7）・
> **識別リスクと弱識別時の対応規則**（§8）・**履歴再生候補の必要条件**（§9）・
> **数値fitと構造的検証を分離した検証契約**（§10）を確定する。
> 中心的な決定は 4 つである。(1) 観測方程式を系列名マッピングとして扱わず、**単位・部門範囲・名目/実質・季節調整・頻度集計・vintage・aggregation/allocation/proxy の methodology metadata を伴う変換契約**として定義する。
> (2) **企業開示に依拠する系列を初期MVPの推定・較正の入力に用いない**（比較用途のみ）。集計対象企業の選定基準が再現性を左右するためである。
> (3) 推定対象を `bh_` の一部に限り、**7 つの推定ブロックへ分割して同時推定しない**。ブロックごとに、どの観測変動が識別に寄与するかを明記する。
> (4) 弱識別を検出したときの対応（固定へ降格 / 範囲報告 / 複数仕様併記 / 感応度のみ）を**推定前に規則として決める**。
> 本書は当てはまり（fit）を因果妥当性・景気後退確率・投資助言へ読み替えない（§11）。

---

## 1. 本書の位置づけと確定範囲

### 1.1 位置づけ

[分析契約](capex_credit_cycle_analysis_contract.md)は「何を問うか」、[因果グラフ](capex_credit_cycle_causal_graph.md)は「どの経路で伝わるか」、[部門境界と変数定義](capex_credit_cycle_sectors_variables.md)は「どの部門が何を持つか」、[動学方程式](capex_credit_cycle_equations.md)は「どう計算するか」を固定した。
本書はその上で「**モデルの各量が現実の何と対応し、どのパラメータをどう決め、何をもって検証したと言えるか**」を固定する。

| 本書が固定するもの | 本書が固定しないもの |
|---|---|
| 主要変数の観測可能性分類（§3） | 系列 ID の存在・定義・基準年の一次資料確認（実装フェーズの義務。§4.1） |
| 観測方程式（単位・範囲・頻度・集計・vintage・metadata）（§4） | 変換の Julia 実装（`build_*_dataset` 相当） |
| 逆較正が必要とする定常水準の観測対応（§5） | 定常水準の数値 |
| DME / `economic-data-provider` / 企業データ provider の責務境界（§6） | provider 側の内部設計・API 仕様 |
| 全パラメータの固定/較正/限定推定/シナリオ/感応度の区分と推定ブロック（§7） | パラメータの推定値 |
| 識別リスクと弱識別時の対応規則（§8） | 実際の識別診断結果 |
| 履歴再生候補の必要条件と候補集合（§9） | 標本期間の最終選定 |
| 検証指標・感応度計画・合格判定の扱い（§10） | 検証の実行結果 |

### 1.2 規律（契約）

1. **観測方程式を系列名マッピングとして扱わない**。単位・部門範囲・名目/実質・季節調整・頻度集計方式・vintage・aggregation/allocation/proxy の別を伴わない対応を「観測方程式を定義した」と申告しない（Issue #170 §2 の要求）。
2. **系列が指数か水準か比率かを検証せずに直接利用しない**（[Keen 実証化戦略](keen_empirical_strategy.md) §2 冒頭の義務を継承）。指数系列を水準として使う場合はアンカー方式を明記する。
3. **推定対象は `bh_` に分類されたパラメータの一部に限る**（[動学方程式](capex_credit_cycle_equations.md) §13.1 の契約）。`st_` は会計・技術定義または逆較正から、`pl_` は制度から与える。
4. **同一の観測系列から多数の行動パラメータを同時推定しない**。§7.4 の推定ブロックを単位とし、ブロックを跨いだ同時推定を既定にしない。
5. **弱識別時の対応を推定後に選ばない**。§8.3 の規則 `W1`–`W4` を事前に割り当てる。
6. **fit を較正の唯一の目的関数にしない**。数値fit・動学再現・構造的検証・感応度を分離して報告する（§10）。公式景気後退判定との一致率を目的関数にしない（契約 §4.1）。
7. **本書に無い系列・変換・推定対象を実装が独自に追加しない**。必要が生じた場合は本書を改訂する（§13）。
8. **モデル層は外部 API を呼ばない**（#125 の方針・[イベント変換契約](../architecture/macro_event_contract.md) §12-2）。データ層・較正層とモデル層の境界を §6.5 で固定する。

### 1.3 表記

| 記法 | 意味 |
|---|---|
| `x_t` | モデル変数（[部門境界と変数定義](capex_credit_cycle_sectors_variables.md) §5 の Julia 名） |
| `x^{obs}_t` | 変換後の観測値（モデルの単位・時点・部門範囲へ揃えたもの） |
| `x^{ss}` | 定常水準（[動学方程式](capex_credit_cycle_equations.md) §14.2 の逆較正入力） |
| 観測分類 `D` / `C` / `P` / `E` / `A` | §3.1 の 5 分類 |
| パラメータ区分 `FIX` / `CAL-SS` / `CAL-OBS` / `EST` / `SCN` / `SENS` | §7.1 の 6 区分 |
| 推定ブロック `EB-1`–`EB-7` | §7.4 |
| 識別リスク `ID-1`–`ID-7` | §8.2 |
| 弱識別対応 `W1`–`W4` | §8.3 |
| 履歴再生候補 `H1`–`H6`、必要条件 `NC-1`–`NC-7` | §9 |
| `SUM` / `AVG` / `EOP` / `BOP` | 四半期合計 / 四半期平均 / 期末値 / 期首値（#165 §1.3 と同一） |

---

## 2. 基準経済・標本期間・vintage

### 2.1 基準経済と頻度

契約 §2.1 を継承する（米国・四半期・`Δt = 0.25`）。日本その他への拡張は、国固有系列・制度設定をモデル本体へ埋め込まず、観測データ設定と measurement metadata で分離する（[Keen 実証化戦略](keen_empirical_strategy.md) §1.1 と同方針）。

### 2.2 標本期間の決定方式

**標本期間の固定値を本書で決めない。必須系列の共通利用可能期間から決定論的に算出する。**

| 項目 | 規約 |
|---|---|
| 共通時間軸 | 四半期ラベル `"YYYY-Qn"` を数値時間 `year + (n−1)·0.25` へ変換し、この軸で **inner join** する。文字列順で結合しない（[Keen 実証化戦略](keen_empirical_strategy.md) §4.3 を継承） |
| 端点 | §4 の「較正必須」系列がすべて非欠損である最初と最後の四半期 |
| 記録 | `sample_start`・`sample_end`・`n_obs`・`binding_series`（端点を決めた系列）を methodology metadata へ保存する |
| 履歴再生区間 | `period_zero` の 8 四半期前から 20 四半期後（[シナリオ時間軸](../architecture/scenario_time_semantics.md) §7）。区間末が最新データを超える場合、超過分を評価対象外として明示する |
| ホールドアウト | 履歴再生候補（§9）のうち 1 件以上を推定に用いず out-of-sample 区間として確保する。切り出しは共通期間から決定論的に行う |

### 2.3 欠損・補完

| 規約 | 内容 |
|---|---|
| ゼロ変換の禁止 | **欠損を `0` へ変換しない**（`fill_missing(:zero)` を既定にしない） |
| 補完 | forward fill の可否を系列別に明示し、既定では暗黙補完しない。補完した場合は `DataSeries.metadata["transformations"]` に残す（[実データ前処理ユーティリティ](../data/preprocess.md)） |
| 内部欠損 | inner join 後に残る欠損期は推定 objective・検証 metric の有効ペアから除外し、除外期数と理由を記録する。`NaN` を `0` として扱わない |

### 2.4 vintage と as-of

[シナリオ時間軸](../architecture/scenario_time_semantics.md) §6 が要求した実装方式を本書で確定する。

| 論点 | 決定 | 根拠 |
|---|---|---|
| 初期MVPの既定モード | **`:latest`（最新 vintage・確定値）** | 履歴再生の目的はモデル構造の妥当性検証と較正であり、「その時点で判断できたか」ではない（同 §6.2 の用途対応） |
| `:as_of` モード | 初期MVPでは**実装しない**。実装しないまま `:as_of` を提供したと申告しない（同 §6.3 の契約） | vintage 軸を `DataSeries` 型が持たないため、複数 vintage の保持方式（別 `DataSeries` か metadata か）を決めても、全必須系列の vintage 取得経路が揃わない |
| `DataSeries` 型の変更 | **行わない**（同 §6.3 の非破壊方針） | 既存モデル・前処理・比較 API への影響を避ける |
| vintage の記録 | `metadata["data_vintage"] = "latest"` と取得日（`retrieved_at`）を必ず保存する | 同 §6.2 の記録義務 |
| 改定の追跡 | 初期MVPでは行わない。定義変更・改定により結果が変わった場合は「変わった事実を報告する」義務のみを負う（同 §6.4-2） | 複数 vintage の取得経路が無いため |

**契約**: `:latest` で較正・検証した結果を「その時点で予測できた」と述べない（同 §6.4-1）。この禁止は LLM 説明層へ引き渡す（§12）。

---

## 3. 変数ごとの観測可能性分類

### 3.1 分類の定義

Issue #170 §1 の 5 分類を、#165 §1.3 の観測コード（`O` / `P` / `L`）を細分化する形で定義する。#165 は「公表系列があるか」を、本書は「**較正・検証の入力として使える形にできるか**」を問う。

| コード | 名称 | 定義 | #165 の観測コードとの対応 |
|---|---|---|---|
| `D` | 直接観測可能 | 単一の公表系列を単位・頻度変換のみでモデル変数へ対応させられる | `O` |
| `C` | 複数系列から構成可能 | 2 系列以上の比・差・残差として構成する。構成規則が一意に定まる | `O` または `P` |
| `P` | proxy でのみ観測可能 | 概念的に一致しない代理量を用いる。ずれの方向が既知であることを要件とする | `P` |
| `E` | 潜在状態として推定が必要 | 公表系列に対応が無く、モデルの他変数と観測の組から逆算・推定する | `L` |
| `A` | 観測不能・シナリオ仮定のみ | 初期MVPでは観測に接続せず、シナリオ入力または定常仮定として与える | `L` |

**契約**:

- `E` と `A` の区別は「初期MVPで推定を試みるか」で決まる。`A` は推定を試みない決定であり、観測不能性の主張ではない。
- `P` に分類した変数について、**ずれの方向（過大/過小/不定）を必ず記載する**。不定のものは検証で符号を主張しない。
- 分類は変数の性質ではなく、**初期MVPのデータソース境界（§6）に条件付き**である。企業データ provider を導入すれば `A` → `P` へ移る変数がある（§6.4）。

### 3.2 分類一覧

Issue #170 §1 が列挙した 8 群について、#165 §5 の変数と対応させる。

#### (1) AI・クラウド需要期待

| 変数 | 分類 | 理由・方式 |
|---|---|---|
| `ai_exp` | `A` | 期待そのものの公表系列が無い。企業 CAPEX ガイダンスは実行計画であり期待ではなく、`capex_plan_s1` と混同する。**シナリオ入力（`SH-EXP` の適用先）としてのみ与える**。baseline `= 1`（§4.5） |
| `compute_dem` | `P` | クラウド事業者セグメント売上の集計。企業開示依存のため初期MVPでは比較用途のみ（§6.4）。ずれ: サービス売上は価格変動を含むため数量需要に対して**不定** |
| `price_s1` | `P` | BLS PPI のデータ処理・ホスティング。ずれ: 品質調整の扱いによりクラウド価格低下を過小に測る（**過大**方向） |

#### (2) CAPEX 計画・実行額

| 変数 | 分類 | 理由・方式 |
|---|---|---|
| `capex_exec_s1` | `C` | BEA NIPA の情報処理機器・ソフトウェア・構築物投資の和。**マクロ統計から構成できるため初期MVPの較正入力に使える** |
| `capex_plan_s1` | `A` | hyperscaler の四半期 CAPEX ガイダンス（企業開示）のみ。集計対象企業の選定基準が再現性を左右するため初期MVPの較正入力に用いない |
| `capex_pipe_s1` | `E` | Census 建設支出のデータセンター区分の着工〜完工差から逆算しうるが、機器投資分のパイプラインが含まれない。**逆較正（§5）で `st_pipelag_s1` を介して与える** |
| `cancel_s1`・`capex_defer_s1`・`plan_carry_s1` | `A` | 受注取消・納期延期の報道は定性情報であり系列化できない。baseline `= 0`（定常条件 `SS-3`）とし、ショック応答は内生 |
| `capstart_s`・`retire_s`・`pipe_cancel_s` | `E` / `A` | `capstart_s` は `st_pipelag_s` から内生（`E`）。`retire_s`・`pipe_cancel_s` は MVP `≡ 0`（`A`） |

#### (3) GPU・半導体受注・受注残

| 変数 | 分類 | 理由・方式 |
|---|---|---|
| `order_s2`・`backlog_s2` | `D` | Census M3（NAICS 334 新規受注・受注残） |
| `order_s3` | `C` | Census M3（NAICS 333）+ Census 建設支出のデータセンター区分。建設分は受注概念でないため構成規則を §4.3 で固定する |
| `backlog_s3` | `P` | Census M3（NAICS 333）のみ。建設・電力の受注残が含まれない（**過小**） |
| `ext_demand_s2`・`ext_demand_s3` | `C` | `order_s` から AI CAPEX 起因分（`capex_exec_s1 · st_capex_share_s` + `invest_s2 · st_invest_share_s3`）と一般需要分を差し引いた残差（§4.3・`ID-3`） |
| `ship_s`・`deliv_s` | `D` | Census M3（出荷・出荷額）。`ship_s` は実質化が必要（`deliv_s` が名目） |

#### (4) 生産能力・稼働率・在庫

| 変数 | 分類 | 理由・方式 |
|---|---|---|
| `util_s2`・`util_s3` | `D` | FRB 稼働率（`CAPUTLG3344S`・`CAPUTLG333S`）。ただしモデル定義は `y_s / ycap_s[t−1]` であり、FRB の分母（技術的能力）と一致しない（§4.4 の注意） |
| `ycap_s2`・`ycap_s3` | `P` | FRB 設備能力（Capacity）。**ずれ: 物量・技術的能力の指数であり、`cap_s / st_cor_s` と概念が一致しない（不定）**（#165 §9-9） |
| `cap_s1`–`cap_s3` | `P` | BEA 固定資産統計の産業別純資本ストック。年次公表であり四半期補間が必要（§4.4） |
| `inv_s2`・`inv_s3`・`inv_ratio_s` | `D` | Census M3（在庫・在庫/出荷比） |
| `y_s2`・`y_s3` | `C` | FRB 産業生産指数（`IPG3344S`・`IPG333S`）は指数であり、水準化に BEA 産業別実質産出額を要する（§4.4 のアンカー方式） |
| `util_s1`・`ycap_s1`・`y_s1` | `E` / `P` | `util_s1`・`ycap_s1` は対応系列が無く逆較正で与える（`E`）。`y_s1` は BEA GDP by Industry のデータ処理・ホスティング関連（`P`、部門範囲が広い＝**過大**） |
| `price_s2`・`price_s3` | `D` | BLS PPI（NAICS 334 / 333）。指数であり baseline `= 1` へ再基準化する |

#### (5) 部門別売上・利益・営業CF

| 変数 | 分類 | 理由・方式 |
|---|---|---|
| `va_s2`・`va_s3`・`y_s5`・`y_tot` | `D` / `C` | `y_tot` は `GDPC1`（`D`）。`va_s` は BEA GDP by Industry の実質付加価値（`D`）。`y_s5` は `GDPC1 − Σ va_s`（`C`） |
| `sales_s`・`im_s`・`dinv_s` | `C` | `sales_s = price_s · y_s`（産出額）。`im_s = (1 − st_va_share_s) · sales_s`。`dinv_s` は M3 在庫の差分 |
| `profit_s2`・`profit_s3` | `P` | BEA NIPA 表 6.16 の産業別法人利益。**ずれ: モデルの `profit_s = va_s − wagebill_s − dep_s` は利払い前・税前であり、NIPA の利潤概念と一致しない（不定）** |
| `profit_s1`・`ocf_s1`・`sales_s1` | `A` | 企業開示のセグメント売上・営業利益・営業CF に依拠する。初期MVPの較正入力に用いない |
| `ocf_s2`・`ocf_s3` | `C` | `ocf_s = profit_s + dep_s − dinv_s`。構成要素がすべて `D` / `P` であるため構成可能。企業開示の営業CF は用いない |
| `margin_s`・`va_s1` | `P` | 上記の比 / BEA GDP by Industry（部門範囲が広い） |

#### (6) 債務・利払い・借換条件

| 変数 | 分類 | 理由・方式 |
|---|---|---|
| `debt_s1`–`debt_s3` | `P` | FRB Z.1 表 B.103・L.103 の非金融法人負債。**ずれ: 産業別内訳が無いため部門配分に allocation を要する（§4.6）。方向は不定** |
| `int_burden_s` | `P` | BEA NIPA の企業純利子支払（部門別内訳なし）。allocation 依存 |
| `r_eff_s` | `E` | `int_burden_s / debt_s[t−1]` として構成できるが、両者が allocation 依存のため独立情報を持たない。**逆較正で `st_maturity_s`・`st_spread0` から与える** |
| `coverage_s`・`coverage_agg`・`leverage_s`・`dsc_s` | `C` | 上記の比。allocation の任意性が比へ伝播する（`ID-2`） |
| `matur_s`・`refin_s`・`newdebt_s`・`repay_s`・`rollover_gap_s` | `E` / `A` | `matur_s = φ_s · debt_s[t−1]` は `st_maturity_s` に条件付き（`E`）。`refin_s`・`newdebt_s` は内生（`A`） |
| `rollover` | `P` | 社債発行額・借換比率、SLOOS の貸出条件。**ずれ: 指数化の基準が任意（不定）**。baseline `= 1`（`SS-2`） |
| `cost_capital_s` | `E` | 潜在変数。**単独の水準を分析結果として提示しない**（#165 §5.4 の契約）。§8.2 `ID-2` の対応として proxy を用いる場合も、proxy であることを出力へ明記する |

#### (7) 株式評価・信用スプレッド・貸出態度

| 変数 | 分類 | 理由・方式 |
|---|---|---|
| `spread` | `D` | ICE BofA `BAMLH0A0HYM2`（HY OAS）・`BAMLC0A0CM`（IG OAS）。日次 → 四半期平均 |
| `spread_endo`・`spread_shock_ex` | `A` | 内生/外生成分の分解はモデル内部の定義であり観測できない。`spread_shock_ex` はシナリオ入力（`SH-CREDIT` の適用先） |
| `lend_stance` | `D` | SLOOS `DRTSCILM`（C&I 貸出基準の引締ネット%）。**符号の向き（引締が正）を metadata に明記する** |
| `fin_cond` | `D` | Chicago Fed `NFCI`（引締が正）。標準化系列であり baseline `= 0` |
| `policy_rate` | `D` | `FEDFUNDS`（四半期平均）。シナリオでは外生入力（`SH-EASING` の適用先） |
| `equity_val` | `P` | 半導体・情報技術セクター株価指数を `GDPDEF` で実質化し baseline `= 1` へ再基準化。**ずれ: モデルは `Σ profit_s` の関数として定義しており、株価は期待・割引率の変動を含む（過大変動）** |
| `collateral` | `E` | `equity_val` の関数として内生（`L31`）。独立の観測を持たない |

#### (8) 雇用・所得・消費・産出

| 変数 | 分類 | 理由・方式 |
|---|---|---|
| `emp_tot` | `D` | `PAYEMS`（非農業雇用者数） |
| `emp_s1`–`emp_s3` | `D` | BLS CES（NAICS 51 / 334 / 333 + 建設 23 + 公益 22）。`S3` は 3 業種の和（`C` に近いが公表系列の単純和で一意） |
| `emp_s5` | `C` | `PAYEMS − Σ_{s∈{S1,S2,S3}} emp_s` |
| `wage` | `C` | `CES0500000003`（平均時給）を `GDPDEF` で実質化し baseline `= 1` へ再基準化 |
| `hh_income` | `P` | `DSPIC96`（実質可処分個人所得）。**ずれ: モデルの `hh_income = Σ wagebill_s · (1 − pl_tau) + 移転` は賃金所得中心であり、資産所得・自営業所得を含む観測に対して過小** |
| `cons` | `P` | `PCECC96`（実質個人消費支出）。**ずれ: モデルの `cons` は `S1`・`S5` 産出への支出のみを含み、`S2`・`S3` 産出への一般需要を含まない（過小）**（[動学方程式](capex_credit_cycle_equations.md) §17 `E6`・§19-3） |
| `wagebill_s`・`tax_hh`・`cons_s1`・`cons_s5`・`xsales_s1` | `C` / `A` | `wagebill_s` は `st_wbase_s · wage · emp_s`（`C`）。配分変数（`cons_s1`・`cons_s5`・`xsales_s1`）は `st_cons_share_s1` に条件付き（`A`） |
| `xdem_s5` | `A` | 定数（[動学方程式](capex_credit_cycle_equations.md) §10.3・§17 `E4`）。政府支出・純輸出・非AI企業投資を分離しない |

### 3.3 分類の集計と帰結

| 分類 | 主な変数群 | 較正・検証での用途 |
|---|---|---|
| `D`（直接） | `spread`・`lend_stance`・`fin_cond`・`policy_rate`・`y_tot`・`emp_tot`・`emp_s`・`order_s2`・`backlog_s2`・`inv_s`・`ship_s`・`util_s`・`price_s`・`va_s2`・`va_s3` | **推定・較正・検証のすべてに使える** |
| `C`（構成） | `capex_exec_s1`・`order_s3`・`ext_demand_s`・`y_s`・`ocf_s2`・`ocf_s3`・`y_s5`・`emp_s5`・`wage`・`coverage_s`・`leverage_s` | 構成規則を metadata へ記録した上で使える |
| `P`（proxy） | `ycap_s`・`cap_s`・`debt_s`・`int_burden_s`・`profit_s2`・`profit_s3`・`equity_val`・`rollover`・`hh_income`・`cons`・`y_s1`・`compute_dem` | **比較・感応度に使う。単独で推定を駆動しない** |
| `E`（潜在） | `capex_pipe_s`・`r_eff_s`・`cost_capital_s`・`ycap_s1`・`util_s1`・`collateral`・`capstart_s`・`matur_s` | 逆較正（§5）または内生。推定対象にしない |
| `A`（仮定） | `ai_exp`・`capex_plan_s1`・`cancel_s1`・`xdem_s5`・企業開示依存の `S1` 収益系列・MVP `≡ 0` の 7 変数 | シナリオ入力・定常仮定。**観測との一致を主張しない** |

**帰結（設計上重要）**:

1. **`S1` の収益ブロック（`sales_s1`・`profit_s1`・`ocf_s1`・`cash_s1`）は初期MVPで観測に接続されない**。したがって増幅ループ `R1a`（`S1` 内部資金）は実データで検証できない。[動学方程式](capex_credit_cycle_equations.md) §19-5 が「`R1a` は基準ユースケースで作動しない」としていることと合わせ、`R1a` は理論上の経路として保持しつつ実証的主張を行わない。
2. **`ai_exp` が `A` であるため、Q1・Q2 の起点となるショック規模（`SH-EXP` の `-10%`）を観測から較正できない**。§7.5 の扱いに従い、規模は感応度走査の対象とし、単一の較正値として提示しない。
3. **`debt_s`・`int_burden_s` が allocation 依存であるため、信用チャネルの部門別パラメータは弱識別になりやすい**（`ID-2`）。§8.3 の `W2`（範囲報告）を既定の対応とする。

---

## 4. 観測方程式

### 4.1 観測方程式の構成要素

各観測方程式は次の 9 項目をすべて備える。欠けているものを「観測方程式」と呼ばない（§1.2-1）。

| # | 項目 | 内容 |
|---|---|---|
| 1 | `model_var` | モデル変数の Julia 名 |
| 2 | `series` | 系列 ID の候補と provider |
| 3 | `level_form` | 水準 / 比率 / 指数 / 成長率のいずれか。指数の場合はアンカー方式 |
| 4 | `unit_conversion` | 単位変換式（`%`→比率、`% of GDP`→比率、名目→実質、10億ドル基準への換算） |
| 5 | `sector_scope` | 部門範囲の一致/不一致と、不一致の方向（過大 / 過小 / 不定） |
| 6 | `published_basis` | 名目/実質・季節調整の有無・基準年 |
| 7 | `aggregation` | 頻度変換方式（`:mean` / `:sum` / `:end`）と、期中平均/期末値/四半期合計のどれをモデルが要求するか |
| 8 | `methodology` | `aggregation` / `allocation` / `proxy` のいずれに該当するか（§4.6） |
| 9 | `vintage` | `:latest` 固定（§2.4）・公表ラグ（四半期）・改定の有無 |

**契約**:

- 系列 ID は**候補**である。存在・定義・単位・基準年・季節調整の有無を **provider metadata または一次資料で確認してから採用する**。確認前の系列で較正結果を報告しない。
- `level_form` が `index` の系列を水準として使う場合、**アンカー方式（どの期の水準値へ合わせるか）を必ず記載する**。指数をそのまま水準として扱わない（[Keen 実証化戦略](keen_empirical_strategy.md) §2.1 の禁止を継承）。
- 上記 9 項目は `DataSeries.metadata` および methodology metadata（§6.6）へ機械可読に保存する。

### 4.2 頻度変換の既定割当

モデルの時点基準（#165 §5.1）と観測の集計方式を対応させる。**モデルが要求する時点と観測の集計方式が一致しない組を作らない**。

| モデルの時点 | 対象変数の型 | 既定の `aggregation` | 根拠 |
|---|---|---|---|
| `SUM`（四半期合計） | フロー（`order_s`・`ship_s`・`capex_exec_s1`・`y_s`・`cons`・`hh_income`・`va_s`） | `:sum`（月次系列）／四半期公表はそのまま | 期中フローの合計。**年率換算値を用いる場合は 4 で除す**（NIPA・BEA は年率表示が既定） |
| `EOP`（期末値） | ストック（`inv_s`・`backlog_s`・`cap_s`・`debt_s`・`cash_s`・`capex_pipe_s`） | `:end` | 残高は期末時点。`to_quarterly(s; method=:end)` を用いる（`src/data/preprocess.jl` に実装済み） |
| `AVG`（四半期平均） | レート・比率・指数（`spread`・`policy_rate`・`lend_stance`・`fin_cond`・`util_s`・`price_s`・`wage`・`equity_val`・`emp_s`） | `:mean` | 期間中の代表値 |

**注意**:

1. **NIPA・BEA のフロー系列は年率（SAAR）表示が既定である**。モデルは四半期合計（`SUM`、年率換算しない）を要求するため、`÷ 4` の換算を必ず入れる。この換算漏れはフロー変数を 4 倍に見積もる系統的誤りとなり、資金調達恒等式（#166 §6）との照合で検出されるまで気付かない。換算の有無を `unit_conversion` へ明記する。
2. **`emp_s` は #165 で `stock`・`AVG` である**。BLS CES は月次であり `:mean` を用いる。
3. 日次系列（`BAMLH0A0HYM2` 等）は月次を経ずに四半期平均へ集約してよいが、集約方式（単純平均 / 営業日加重）を記録する。

### 4.3 部門別実物量の観測方程式（`S2`・`S3`）

| `model_var` | `series`（候補） | `level_form` | `unit_conversion` | `sector_scope` | `published_basis` | `aggregation` | `methodology` |
|---|---|---|---|---|---|---|---|
| `order_s2` | Census M3 新規受注（NAICS 334） | 水準（名目） | `GDPDEF` または PPI(334) で実質化、10億ドル、`÷ 4` 不要（月次合計） | NAICS 334 は半導体を含む電子製品全体。**過大**（通信機器等を含む） | 名目・季節調整済 | `:sum` | `aggregation` |
| `order_s3` | Census M3 新規受注（NAICS 333）+ Census 建設支出（データセンター区分） | 水準（名目） | PPI(333) / 建設コスト指数で実質化、和を取る | 機械全体 + DC 建設。電力設備が欠落。**不定** | 名目・季節調整済 | `:sum` | `allocation` |
| `backlog_s2` | Census M3 受注残（NAICS 334） | 水準（名目） | 同上で実質化 | 同上・**過大** | 名目・季節調整済 | `:end` | `aggregation` |
| `backlog_s3` | Census M3 受注残（NAICS 333） | 水準（名目） | 同上 | 建設・電力の受注残が欠落。**過小** | 名目・季節調整済 | `:end` | `proxy` |
| `inv_s2` / `inv_s3` | Census M3 在庫（NAICS 334 / 333） | 水準（名目） | 同上。#166 §4.4 の `invval_s = st_invprice_s · inv_s` に対応するのは観測側の在庫**価値額**である | 同上 | 名目・季節調整済 | `:end` | `aggregation` |
| `ship_s2` / `ship_s3` | Census M3 出荷（NAICS 334 / 333） | 水準（名目） | 同上で実質化。名目のままなら `deliv_s` に対応する | 同上 | 名目・季節調整済 | `:sum` | `aggregation` |
| `y_s2` / `y_s3` | FRB 産業生産指数 `IPG3344S` / `IPG333S`（**指数**） | 指数 | **BEA 産業別実質産出額（年次）を用いてアンカーし水準化する**。指数を水準として使わない | NAICS 3344 は設計・製造統合（#165 §2.2）。**過大** | 実質・季節調整済・基準年あり | `:mean`（指数の四半期平均）→ 水準化後に `SUM` へ換算 | `proxy` |
| `util_s2` / `util_s3` | FRB 稼働率 `CAPUTLG3344S` / `CAPUTLG333S` | 比率（%） | `÷ 100` | 同上 | 季節調整済 | `:mean` | `proxy` |
| `price_s2` / `price_s3` | BLS PPI（NAICS 334 / 333） | 指数 | `GDPDEF` で実質化し、baseline 期間平均 `= 1` へ再基準化 | 同上 | 名目・季節調整の有無を確認 | `:mean` | `aggregation` |
| `va_s2` / `va_s3` | BEA GDP by Industry 実質付加価値（四半期） | 水準 | 年率表示のため `÷ 4`、10億ドル | NAICS 334 / 333。**過大** | 実質・季節調整済・連鎖ドル | 四半期公表 | `aggregation` |
| `ext_demand_s2` / `ext_demand_s3` | 構成: `order_s − (capex 起因分 + invest 起因分 + 一般需要分)` | 水準 | — | 定義上残差 | — | — | `allocation` |

**`y_s` の水準化（アンカー方式の確定）**:

```
y_s[q] = va_s^{annual}(base_year) / st_va_share_s / 4 × ( IP_s[q] / mean_{q ∈ base_year} IP_s[q] )
```

`base_year` は baseline 期間に含まれる暦年から選び、`base_year` と選定根拠を metadata へ保存する。**IP 指数の変化率のみを情報として使い、水準は BEA 産出額に帰属させる**。

**`ext_demand_s` の構成規則（`ID-3` の中核）**:

```
ext_demand_s[q] = order_s^{obs}[q]
                  − st_capex_share_s · capex_exec_s1^{obs}[q]
                  − ( s = S3 の場合 ) st_invest_share_s3 · invest_s2^{obs}[q−1]
                  − st_gen_share_s · y_s5^{obs}[q−1]
```

**契約**: この残差は測定誤差・部門範囲の過大（NAICS 334 の非 AI 半導体）・配分比の誤りをすべて吸収する。したがって

1. `ext_demand_s` の水準・変動を「モデル外需要の推定値」として提示しない。**残差であることを出力に明記する**。
2. `ext_demand_s` が負になる期を検出したら、配分比 `st_capex_share_s`・`st_gen_share_s` の較正が過大であることを示す診断として報告する（`≥ 0` は #165 の符号制約）。**負値をクリップしない**。
3. `ext_demand_s` の分散が `order_s` の分散を超える場合、AI CAPEX 起因分の識別に失敗しているとみなし、`ID-3` の対応（§8.3）を適用する。

### 4.4 資本・能力の観測方程式

| `model_var` | `series` | 変換と注意 |
|---|---|---|
| `cap_s1`–`cap_s3` | BEA 固定資産統計 産業別純資本ストック（**年次**） | 実質・10億ドル。**四半期補間が必要**。補間方式は線形（年末値を `:end` として四半期へ配分）とし、方式を metadata へ記録する。補間により四半期変動が平滑化されるため、`cap_s` を高頻度の検証 metric に用いない |
| `ycap_s2` / `ycap_s3` | FRB 設備能力（Capacity、NAICS 3344 / 333） | 指数。**モデルの `ycap_s = cap_s / st_cor_s` と概念が一致しない**（#165 §9-9）。`st_cor_s` を定数とする仮定の妥当性評価に用い、`ycap_s` の水準比較には用いない |
| `util_s` の定義差 | — | モデル定義 `util_s = y_s / ycap_s[t−1]`、FRB 定義 = 産出指数 / 能力指数（同期）。**分母の時点が異なる（モデルは期首、FRB は同期）**。検証では FRB 稼働率を `util_s` の proxy として扱い、水準の一致ではなく**変化の一致**を評価する |
| `dep_s` | BEA 固定資産統計 産業別固定資本減耗（年次） | `st_delta_s = dep_s^{ss} / cap_s^{ss}` の較正に用いる（§5）。四半期換算は `÷ 4` |
| `capex_pipe_s1` | Census 建設支出（データセンター区分）の着工〜完工差 | **機器投資のパイプラインを含まないため部分的**。§5 の逆較正で `st_pipelag_s1` として与え、観測は `st_pipelag_s1` の妥当性チェックにのみ用いる |

### 4.5 金融・信用の観測方程式

| `model_var` | `series` | `level_form` | 変換と注意 |
|---|---|---|---|
| `spread` | `BAMLH0A0HYM2`（HY OAS）／`BAMLC0A0CM`（IG OAS） | 水準（%） | `× 100` で bp へ。日次 → `:mean`。**HY と IG のどちらを主とするかを alternative proxy として比較する**（§10.4） |
| `lend_stance` | `DRTSCILM`（SLOOS、C&I 貸出基準の引締ネット%） | 水準（%、標準化前） | baseline 期間平均を差し引き、baseline 期間標準偏差で除して標準化（baseline `= 0`）。**引締が正**であることを metadata に明記する |
| `fin_cond` | `NFCI` | 標準化済み指数 | 追加標準化を行わない。baseline 期間平均を差し引いて baseline `= 0` へ。**引締が正** |
| `policy_rate` | `FEDFUNDS` | 水準（年率 %） | `:mean`。四半期換算（`× Δt`）はモデル内部で行う（[動学方程式](capex_credit_cycle_equations.md) §4.3 の単利換算） |
| `equity_val` | 半導体・情報技術セクター株価指数 | 指数 | `GDPDEF` で実質化、baseline 期間平均 `= 1`。**期待・割引率変動を含むため変動が過大**。#166 §5.7 の「評価損を実体支出と同一視しない」方針と合わせ、`equity_val` の乖離を実体的損失として説明しない |
| `debt_s` | FRB Z.1 表 B.103 / L.103 非金融法人負債 | 水準（名目） | `GDPDEF` で実質化、`:end`。**産業別内訳が無いため allocation が必要**（§4.6）。allocation 前の総額を部門別として提示しない |
| `int_burden_s` | BEA NIPA 企業純利子支払 | 水準（名目・年率） | 実質化、`÷ 4`、allocation。**`debt_s` と同じ allocation キーを用いる**（比 `r_eff_s` に allocation の任意性が残らないようにする） |
| `rollover` | 社債発行額／満期到来額の比、SLOOS 貸出条件 | 比率・指数 | baseline `= 1` へ再基準化。**基準化方式が任意であるため `W2`（範囲報告）を既定とする** |

### 4.6 aggregation / allocation / proxy の methodology metadata

Issue #170 §2 が要求する 3 種の methodology を、次の意味で区別して記録する。

| 種別 | 定義 | 記録項目 | 例 |
|---|---|---|---|
| `aggregation` | 公表系列を時間方向または系列方向へ**足し合わせる**変換。情報の損失はあるが任意性は小さい | 集計方式（`:mean` / `:sum` / `:end`）・構成系列 ID の一覧 | `emp_s3` = CES(333) + CES(23) + CES(22)、日次 OAS の四半期平均 |
| `allocation` | 公表系列を**部門・用途へ按分する**変換。按分キーが結果を左右する | 按分キーの系列 ID・按分式・キーの選択根拠・**代替キーでの感応度** | `debt_s` = Z.1 総額 × 部門別 `sales_s` シェア、`order_s3` の建設分配分 |
| `proxy` | 概念的に一致しない量で**代替する**変換 | 概念差の記述・**ずれの方向（過大/過小/不定）**・代替 proxy 候補 | `ycap_s` ← FRB Capacity、`cons` ← `PCECC96`、`equity_val` ← 株価指数 |

**契約**:

1. **`allocation` を用いた系列を、按分キーを変えた感応度なしに較正・検証へ用いない**（§10.4 の `alternative proxy` に含める）。
2. **`proxy` を用いた系列について、ずれの方向が「不定」のものは検証で符号を主張しない**。
3. 1 つの変数に対して `aggregation` → `allocation` → `proxy` が連鎖する場合、**連鎖の順序を記録し、各段の出力を保持する**。最終値のみを保存しない。
4. これらは `DataSeries.metadata` の `transformations` と、methodology metadata（§6.6）の両方へ記録する。

---

## 5. 逆較正が必要とする定常水準の観測対応

[動学方程式](capex_credit_cycle_equations.md) §14.2 は「定常水準を与えて `st_` パラメータを閉形式で逆算する」ことを決定し、**定常水準を実データから決める作業を本書へ引き渡した**。本節でその対応を確定する。

### 5.1 定常水準の算出方式

| 論点 | 決定 | 根拠 |
|---|---|---|
| 算出方式 | **baseline 期間（`period_zero` の 8 四半期前から `period_zero − 1`、計 8 四半期）の観測平均** | 契約 §2.1 の助走区間と一致させる。トレンド除去や HP フィルタを用いない（平滑化方式の任意性を持ち込まない） |
| フロー変数 | 8 四半期の平均（四半期値のまま。年率換算しない） | #165 §5.1 の `SUM` 規約 |
| ストック変数 | 8 四半期の期末値の平均 | `EOP` 規約 |
| 指数・比率 | 8 四半期の平均。指数は baseline 平均を `1`（または `0`）へ再基準化する（§4.5） | `SS-1`・`SS-2` の baseline 値と一致させる |
| 成長トレンドの扱い | **除去しない**。baseline 期間内にトレンドがある場合、平均を定常水準とすることで定常条件が近似的にしか満たされない。乖離を `runup_deviation`（§10.3）として報告する | baseline を成長率ゼロの定常状態とする決定（[動学方程式](capex_credit_cycle_equations.md) §14.1）の帰結 |
| 整合しない場合 | 定常条件（`SS-1`–`SS-17`）を満たさない定常水準セットを**自動補正しない**。`ss_inconsistent` として構造化記録し、どの条件が破れたかを報告する | ADR 0007 の「不整合を自動補正せず構造化する」方針 |

### 5.2 逆較正入力の観測対応

[動学方程式](capex_credit_cycle_equations.md) §14.2 の導出順序 13 ステップに対し、各定常水準の観測ソースと分類を与える。

| # | 必要な定常水準 | 観測ソース | 分類 | 注意 |
|---|---|---|---|---|
| 1 | `y_s^{ss}`（`s ∈ SR`）・`util_s^{ss}`・`emp_s^{ss}` | `y_s2`/`y_s3`: §4.3 のアンカー水準化、`y_s1`: BEA GDP by Industry、`y_s5`: `GDPC1 − Σ va_s`、`util_s`: FRB 稼働率、`emp_s`: BLS CES | `C` / `D` | `y_s1` は部門範囲が過大（§3.2-4）。`st_lprod_s` が過大になる方向 |
| 2 | `cap_s^{ss}` | BEA 固定資産（年次・四半期補間） | `P` | `st_cor_s` の水準が BEA の資本概念に依存する |
| 3 | `dep_s^{ss}` | BEA 固定資本減耗（年次）`÷ 4` | `P` | `st_delta_s = dep_s^{ss} / cap_s^{ss}`。同一統計内の比のため整合性は保たれる |
| 4 | `capex_pipe_s^{ss}` | Census 建設支出のデータセンター区分（`S1` のみ部分的） | `E` | **観測が不十分**。`st_pipelag_s` を文献・業界の着工〜完工期間（既定 3 四半期）から与え、`capex_pipe_s^{ss} = st_pipelag_s · st_delta_s · cap_s^{ss}`（`SS-4`）で逆算する |
| 5 | `capex_exec_s1^{ss}` | BEA NIPA 情報処理機器・ソフトウェア・構築物投資（年率 `÷ 4`） | `C` | §14.2-5 は自由度なしの**整合条件**（`capex_exec_s1^{ss} = st_delta_s1 · cap_s1^{ss}`）。観測値と逆算値の乖離を必ず報告する（§10.3 の `ss_residual`） |
| 6 | `compute_dem^{ss} = y_s1^{ss}` | 上記 `y_s1^{ss}` | `P` | `ai_exp^{ss} = 1` を課すため、`st_cd0 = compute_dem^{ss}` |
| 7 | `order_cap_s^{ss}`（資本財の供給元構成） | Census M3 受注のうち資本財相当 + BEA 投資の財別内訳 | `P`（`allocation`） | `st_capex_share_s2` / `_s3` / `_sx` の較正。**配分比の任意性が `ID-3` の中心**。`alternative proxy` 感応度の必須対象 |
| 8 | `backlog_s^{ss}`・`inv_s^{ss}` | Census M3 受注残・在庫 | `D` | 比率として与えるため水準の実質化誤差が相殺されやすい |
| 9 | `order_gen_s^{ss}` | 残差（`y_s^{ss}` から資本財起因分と `ext_demand_s^{ss}` を控除） | `C` | `st_gen_share_s` が `y_s5^{ss}` に対する比として決まる |
| 10 | `va_s^{ss}`・`wagebill_s^{ss}` | BEA GDP by Industry 付加価値、BLS/BEA 産業別雇用者報酬 | `D` / `P` | `st_va_share_s = va_s^{ss} / sales_s^{ss}`。`st_va_share_s5 = 1` は固定（[動学方程式](capex_credit_cycle_equations.md) §11.1） |
| 11 | `debt_s^{ss}`・`cash_s^{ss}`・`spread^{ss}`・`policy_rate^{ss}` | Z.1 B.103（allocation）・OAS・`FEDFUNDS` | `P` / `D` | `st_dcap_s ≥ debt_s^{ss} / sales_s^{ss}` は不等式であり、余裕幅の選択が `ID-2` に影響する。既定は `1.2 ×`（暫定）とし感応度対象 |
| 12 | `cons^{ss}`・`hh_income^{ss}`・`xdem_s5^{ss}` | `PCECC96`・`DSPIC96`（年率 `÷ 4`）、`xdem_s5^{ss}` は残差 | `P` / `A` | `cons` の部門範囲の近似（§3.2-8）が `st_cons_auto` へ吸収される |
| 13 | `st_profit_ref`・`st_emp_ref`・`st_extdem_s`・`st_coll_ltv` | 上記から機械的に導出 | — | `st_coll_ltv` は `pl_ltv` との整合（許容条件 14）を満たすよう選ぶ。自由度は `pl_ltv` 側 |

**契約**:

1. **定常水準は 1 つの baseline 期間から一貫して算出する**。変数ごとに異なる期間の平均を混在させない。
2. 定常水準セットを `steady_state_targets` として methodology metadata へ保存し、そこから逆算した `st_` パラメータと併せて記録する。**逆算後のパラメータのみを保存しない**（再現に定常水準が必要）。
3. §14.2-5 の整合条件（自由度なし）が観測と乖離する場合、**乖離をゼロにするために `cap_s1^{ss}` や `st_delta_s1` を調整しない**。乖離を `ss_residual` として報告し、どちらの観測を優先したかを記録する。
4. 定常条件 `SS-1`–`SS-17` の検証は逆較正の直後に実行し、`ss_inconsistent` の内容を較正結果に含める。

---

## 6. データソース境界

### 6.1 3 層の責務

| 層 | 責務 | 本モデルで受け取るもの |
|---|---|---|
| **DME 既存 FRED / e-Stat 接続**（`src/data/fred.jl`・`estat.jl`） | FRED から取得できる系列の取得・fixture 再生・`DataSeries` 化 | §6.2 の系列 |
| **`economic-data-provider`** | FRED に無い系列（Census M3・BEA GDP by Industry・BEA 固定資産・Census 建設支出）の取得、実質化・季節調整・単位統一・品質管理・vintage 管理 | §6.3 の系列。観測イベント（`L1`）も同層（[イベント変換契約](../architecture/macro_event_contract.md) §2.3） |
| **企業データ provider（未整備）** | 企業決算・セグメント開示・CAPEX ガイダンス・平均満期 | **初期MVPでは接続しない**（§6.4） |

### 6.2 DME 既存 FRED 接続で取得する系列

| 系列 ID | 対応変数 | 用途 |
|---|---|---|
| `GDPC1` | `y_tot` | 較正・検証（`G1`） |
| `GDPDEF` | 実質化デフレータ | 変換 |
| `PAYEMS` | `emp_tot` | 較正・検証（`G3`） |
| `DSPIC96` | `hh_income` | 検証（`G3`） |
| `PCECC96` | `cons` | 較正・検証（`G3`） |
| `CES0500000003` | `wage` | 較正 |
| `FEDFUNDS` | `policy_rate` | 較正・外生入力 |
| `BAMLH0A0HYM2` / `BAMLC0A0CM` | `spread` | 推定（`EB-1`）・検証（`G4`） |
| `DRTSCILM` | `lend_stance` | 推定（`EB-1`）・検証（`G4`） |
| `NFCI` | `fin_cond` | 推定（`EB-1`） |
| `CAPUTLG3344S` / `CAPUTLG333S` | `util_s2` / `util_s3` | 推定（`EB-3`）・検証 |
| `IPG3344S` / `IPG333S` | `y_s2` / `y_s3`（指数） | 推定（`EB-3`・`EB-4`） |
| `UNRATE` | 参考（労働市場） | 検証の補助 |

**契約**: 系列 ID の存在・定義・単位・季節調整・基準年を `FredClient` の live 取得時の metadata または FRED のシリーズページで確認する。**上表は候補であり、確認前の較正結果を報告しない**（§4.1）。

### 6.3 `economic-data-provider` 経由で取得・品質管理する系列

| 系列群 | 対応変数 | provider へ要求する品質管理 |
|---|---|---|
| Census M3（新規受注・受注残・在庫・出荷、NAICS 334 / 333） | `order_s2`・`backlog_s`・`inv_s`・`ship_s` | 名目/実質の別、季節調整、定義変更（NAICS 改訂）の追跡 |
| BEA GDP by Industry（実質付加価値・産出、四半期） | `va_s`・`y_s1` | 年率/四半期の別、連鎖ドル基準年、産業分類の対応表 |
| BEA 固定資産統計（産業別純資本ストック・固定資本減耗、年次） | `cap_s`・`dep_s` | 実質基準年、四半期補間を行っていないこと（補間は DME 側の責務） |
| Census 建設支出（データセンター区分） | `order_s3` の建設分・`capex_pipe_s1` | 区分の定義変更・公表開始時期 |
| BEA NIPA（産業別法人利益・企業純利子支払・情報処理投資） | `profit_s`・`int_burden_s`・`capex_exec_s1` | 年率表示の明示、産業別内訳の粒度 |
| FRB Z.1（表 B.103・L.103） | `debt_s`・`cash_s` | 部門定義、産業別内訳が存在しないことの明示 |
| BLS PPI・CES（産業別） | `price_s`・`emp_s` | 指数基準年、季節調整 |
| セクター株価指数 | `equity_val` | 構成銘柄の定義、実質化前の名目基準 |

**契約**:

1. **DME 側は provider が返す系列の単位・基準・季節調整を再確認する**。provider が品質管理したことを理由に §4.1 の確認義務を免除しない。
2. provider が系列を返せない場合、**代替 proxy へ黙って切り替えない**。当該変数を欠損として扱い、その変数を必要とする推定ブロック（§7.4）を実行しないという扱いにする。
3. 本書は provider 側の API 仕様・内部設計を定めない（[イベント変換契約](../architecture/macro_event_contract.md) §1 の対象外を継承）。

### 6.4 企業決算・ガイダンス等（初期MVPで接続しない決定）

**決定: 企業開示に依拠する系列を初期MVPの推定・較正の入力に用いない。比較・定性参照の用途に限る。**

| 論点 | 内容 |
|---|---|
| 対象変数 | `capex_plan_s1`・`compute_dem`・`sales_s1`・`profit_s1`・`ocf_s1`・`cash_s1`・`st_maturity_s`・企業開示の営業CF・支払利息 |
| 理由 1 | **集計対象企業の選定基準が再現性を左右する**（#165 §9-5）。「主要 hyperscaler」の定義は時点により変わり、選定を固定しない集計は再現できない |
| 理由 2 | 会計年度・セグメント区分・報告基準が企業間・時点間で一致しない。部門定義（`S1` = AI・クラウド需要）との対応が任意になる |
| 理由 3 | 契約 §6 は「非公開企業・銀行データを前提とした較正」を対象外としている。企業開示は公開だが、**集計の再現性という同じ理由**が当てはまる |
| 帰結 | `S1` の収益ブロックが観測に接続されず、`R1a` を実証的に検証できない（§3.3-1）。この限界を §11 に記録する |
| 将来の扱い | 企業データ provider が整備され、**選定基準・集計規則をバージョン付きで固定できる**場合に `A` → `P` へ移す。移す際は本書を改訂し `empirical version` を上げる |

**契約**: 企業開示由来の数値を比較目的で提示する場合、**選定企業の一覧と集計規則を出力へ添える**。添えられないものを提示しない。

### 6.5 モデル層とデータ層・較正層の境界

**モデル層が外部 API を直接呼ばない構造を維持する**（#125 の方針）。

```
[データ層]  provider / FredClient → DataSeries（生系列 + transformations metadata）
     ↓ （§4 の観測方程式）
[較正層]    観測データセット（モデル単位・四半期整列）→ 定常水準（§5）→ st_ パラメータ
                                                    → 推定（§7.4）→ bh_ パラメータ
     ↓ （数値のみ）
[モデル層]  CapexCreditCycleModel（parameters::NamedTuple・初期状態）→ simulate
     ↓
[検証層]    観測データセットとシミュレーション結果を突き合わせる（§10。読み取り専用）
```

| 論点 | 決定 |
|---|---|
| モデル層が受け取るもの | 平坦な `parameters::NamedTuple`（`st_`・`bh_`・`pl_`）と定常状態の初期値、外生変数の四半期パス（[動学方程式](capex_credit_cycle_equations.md) §4.1）。**`DataSeries` を受け取らない** |
| データ品質の伝達 | 較正層が `data_quality`（欠損期数・補完の有無・最新観測期・vintage・按分キー）を methodology metadata へ保持する。**モデル層へ品質フラグを渡さない**（モデルの動学が品質に依存しない構造を保つ） |
| 取得失敗の扱い | 較正層で例外として扱い、`simulate` を実行しない。**欠損を既定値で埋めて実行しない** |
| データの古さ | 最新観測期が評価区間末より前の場合、超過区間を評価対象外として明示する（§2.2）。**古いデータで区間を延長しない** |
| 検証層の配置 | 読み取り専用の後処理層。モデル本体・可視化・LLM 層を変更しない（Minsky 診断層・SFC 会計検証層と同じ配置方針） |

### 6.6 fixture へ固定する最小データセットと methodology metadata

| 項目 | 規約 |
|---|---|
| fixture の範囲 | §6.2 の FRED 系列すべてと、§6.3 のうち推定ブロック `EB-1`・`EB-3`・`EB-6`・`EB-7` に必要な系列（Census M3 の 334 / 333 の受注・受注残・在庫・出荷、BEA GDP by Industry の `va_s2`・`va_s3`、BLS CES の部門別雇用） |
| 格納先 | FRED 系列は `test/fixtures/fred/<SERIES_ID>.json`（[FRED 接続ガイド](../data/fred.md) の形式）。provider 系列は別ディレクトリを設け、形式は #171 が確定する |
| 決定性 | fixture モードで API キー不要・決定的に完走すること。CI は fixture モードで動作させる（[設定・環境変数管理ガイド](../development/configuration.md)） |
| 期間 | 履歴再生候補（§9）のうち最低 1 件と baseline 期間を含む長さ |
| methodology metadata の保存項目 | `empirical_version`・系列 ID と provider・取得日（`retrieved_at`）・`data_vintage`・§4.1 の 9 項目・`transformations`・`aggregation`/`allocation`/`proxy` の種別と按分キー・`sample_start`/`sample_end`/`n_obs`/`binding_series`・`steady_state_targets`・逆算した `st_` パラメータ・推定ブロックごとの推定対象と境界・objective 定義・除外期とその理由・弱識別診断・`data_quality` |
| 保存しないもの | API キー・環境変数値・秘密情報（[Keen 実証化戦略](keen_empirical_strategy.md) §6.1 と同方針） |

---

## 7. 固定・較正・限定推定・シナリオ・感応度の区分

### 7.1 区分の定義

Issue #170 §4 の 5 分類を、[動学方程式](capex_credit_cycle_equations.md) §13 のパラメータ辞書へ適用する。同書が「定常水準から導出（自由度なし）」を別扱いしているため、較正を 2 つに分けた 6 区分とする。

| 区分 | 定義 | 決め方 |
|---|---|---|
| `FIX` | 会計恒等式・制度設定・数値下限から固定 | 定義・制度・既定値。観測を用いない |
| `CAL-SS` | 定常水準から逆較正で一意に決まる（自由度なし） | §5 の定常水準から閉形式で逆算 |
| `CAL-OBS` | 観測比率・文献値から直接較正 | §4 の観測系列の baseline 期間比率、または文献値 |
| `EST` | 限定的に推定 | §7.4 の推定ブロックごとに推定 |
| `SCN` | シナリオ入力として与える | `parameters` に含めない（[動学方程式](capex_credit_cycle_equations.md) §13.1）。イベント/シナリオ型 |
| `SENS` | 推定・較正せず感応度分析のみ | 既定値を置き、走査範囲を定める |

**契約**: 各パラメータは**ちょうど 1 つの区分を持つ**。`EST` に分類したものが弱識別と判定された場合、§8.3 の規則により `CAL-OBS`・`FIX`・`SENS` へ移る。**移した事実と移動先を記録する**（推定を試みて失敗したことを隠さない）。

### 7.2 構造パラメータ（`st_`）の区分

[動学方程式](capex_credit_cycle_equations.md) §13.2 の全 35 系統。

| パラメータ | 区分 | 観測ソース・決め方 |
|---|---|---|
| `st_cor_s1`–`st_cor_s3` | `CAL-SS` | §5.2-2（`cap_s^{ss} · bh_util_tgt_s / y_s^{ss}`） |
| `st_delta_s1`–`st_delta_s3` | `CAL-OBS` | BEA 固定資本減耗 ÷ 資本ストック ÷ 4（§5.2-3） |
| `st_pipelag_s1`–`st_pipelag_s3` | `CAL-OBS` | 業界の着工〜完工期間（既定 3 四半期）。観測が不十分なため `SENS` 併用（§7.5） |
| `st_va_share_s1`–`st_va_share_s3` | `CAL-SS` | §5.2-10 |
| `st_va_share_s5` | `FIX` | `= 1`（[動学方程式](capex_credit_cycle_equations.md) §11.1） |
| `st_lprod_s1`–`st_lprod_s5` | `CAL-SS` | §5.2-1（`y_s^{ss} / emp_s^{ss}`）。許容条件 13 の順序を検査 |
| `st_wbase_s1`–`st_wbase_s5` | `CAL-SS` | §5.2-10 |
| `st_cshare_s3` | `CAL-OBS` | BLS CES の建設 23 + 公益 22 が `emp_s3` に占める比 |
| `st_capfrac_s3` | `CAL-SS` | §14.2-7（`order_cap_s3^{ss} / y_s3^{ss}`） |
| `st_capex_share_s2` / `_s3` / `_sx` | `CAL-OBS` | §5.2-7。**`allocation` であり `alternative proxy` 感応度の必須対象**（`ID-3`） |
| `st_invest_share_s3` / `_sx` | `CAL-OBS` | 同上 |
| `st_gen_share_s2` / `_s3` | `CAL-SS` | §5.2-9 |
| `st_cons_share_s1` | `CAL-SS` | §5.2-12 |
| `st_cd0` | `CAL-SS` | §5.2-6 |
| `st_invprice_s2` / `_s3` | `FIX` | 既定 1 |
| `st_maturity_s1`–`st_maturity_s3` | `SENS` | 企業開示の平均満期に依拠するため `A`（§6.4）。**文献・社債市場の平均残存期間から既定値を置き、感応度で扱う** |
| `st_cash_min_s1`–`_s3` | `CAL-OBS` | Z.1 の現金/売上比の下位分位。許容条件 11 を検査 |
| `st_cash_ref_s1`–`_s3` | `CAL-OBS` | Z.1 の現金/売上比の baseline 平均 |
| `st_dcap_s1`–`_s3` | `CAL-OBS` | `debt_s^{ss} / sales_s^{ss}` の 1.2 倍（暫定）。倍率は `SENS` |
| `st_commit_s1` | `SENS` | 契約確定比率の観測が無い。既定値 + 走査（`B3`） |
| `st_irrev_s1`–`_s3` | `FIX` | `= 1`（MVP） |
| `st_payout_s1`–`_s3` | `FIX` | `= 1`（定常整合条件 `SS-14`・許容条件 12） |
| `st_spread0` | `CAL-SS` | §5.2-11 |
| `st_pol_ref` | `CAL-SS` | §5.2-11 |
| `st_cc0_s1`–`_s3` | `CAL-SS` | §5.2-11 |
| `st_profit_ref`・`st_emp_ref` | `CAL-SS` | §5.2-13 |
| `st_coll_ltv` | `CAL-SS` | §5.2-13（`pl_ltv` との整合、許容条件 14） |
| `st_xdem0`・`st_cons_auto` | `CAL-SS` | §5.2-12 |
| `st_extdem_s2` / `_s3` | `CAL-SS` | §5.2（`ext_demand_s^{ss}`、§4.3 の残差） |
| `st_ev_min`・`st_price_min_s`・`st_wage_min`・`st_debt_tol` | `FIX` | 数値下限（既定値） |

### 7.3 政策・制度パラメータ（`pl_`）の区分

| パラメータ | 区分 | 決め方 |
|---|---|---|
| `pl_tau` | `FIX` | 実効個人税・移転率。NIPA の個人経常税/個人所得比から固定 |
| `pl_tau_corp` | `FIX` | `= 0`（MVP） |
| `pl_ltv` | `SENS` | LTV 上限の観測が無い。既定値 + 走査。**`NL-4` の閾値であり Q5 の分岐に直結する** |

### 7.4 行動パラメータ（`bh_`）の区分と推定ブロック

[動学方程式](capex_credit_cycle_equations.md) §13.3 の全 44 系統を 7 ブロックへ割り当てる。**ブロックを跨いだ同時推定を既定にしない**（§1.2-4）。

| ブロック | 対象パラメータ | `EST` / その他 | 識別に寄与する観測変動 |
|---|---|---|---|
| **`EB-1` 金融条件** | `bh_fc_adj`(`CAL-OBS`)・`bh_fc_pol`(`EST`)・`bh_spread_cov`(`EST`)・`bh_spread_pow`(`CAL-OBS`, 既定 1)・`bh_spread_fc`(`EST`)・`bh_lend_spread`(`EST`)・`bh_cov_threshold`(`CAL-OBS`) | 4 `EST` | `NFCI`・`FEDFUNDS`・OAS・`DRTSCILM` はすべて `D` 分類。**部門実物量を用いず金融系列のみで単一方程式ごとに推定できる**（`E5-01`・`E5-04`・`E5-06` の逐次構造）。`bh_spread_cov` は `coverage_agg` を要するため allocation 依存（`ID-2`）→ `W2` |
| **`EB-2` 資本コスト・評価・担保** | `bh_cc_spread`(`CAL-OBS`, 既定 1)・`bh_cc_lend`(`EST`)・`bh_cc_equity`(`EST`)・`bh_cc_fc`(`EST`)・`bh_ev_adj`(`CAL-OBS`)・`bh_ev_elas`(`EST`)・`bh_coll_elas`(`EST`)・`bh_roll_slope`(`EST`)・`bh_roll_thresh`(`CAL-OBS`) | 6 `EST` | `cost_capital_s`・`collateral` が `E`（潜在）であるため、**この 4 本（`bh_cc_lend`・`bh_cc_equity`・`bh_cc_fc`・`bh_coll_elas`）は観測から識別できない**。`bh_ev_elas` は `equity_val`（`P`）と `Σ profit_s`（`P`）の関係から推定しうるが proxy 依存。**既定対応: `bh_cc_*` は `W1`（固定へ降格）、`bh_ev_elas`・`bh_coll_elas`・`bh_roll_slope` は `W2`（範囲報告）** |
| **`EB-3` 生産・在庫・受注残** | `bh_util_tgt_s`(`CAL-SS`)・`bh_util_max_s`(`CAL-OBS`)・`bh_backlog_target_s`(`CAL-SS`)・`bh_inv_target_s`(`CAL-SS`)・`bh_inv_thresh_s`(`CAL-OBS`)・`bh_inv_adj_s`(`EST`)・`bh_prod_cut_s`(`EST`) | 4 `EST`（部門別 2×2） | **最も観測が揃うブロック**。Census M3 の受注・受注残・在庫・出荷（すべて `D`）と FRB IP・稼働率。会計恒等式 `inv_s = inv_s[t−1] + y_s − ship_s`・`backlog_s = backlog_s[t−1] + order_s − ship_s`（#166 §5.3）が制約となり自由度を削るため識別が最も良い。`ID-4` の対応（§8.3） |
| **`EB-4` 価格** | `bh_price_adj_s`(`EST`)・`bh_price_sens_s`(`EST`)・`bh_price_scale_s`(`FIX`, 既定 0.1)・`bh_price_elas_s`(`SENS`) | 4 `EST` + 1 `SENS` | BLS PPI（`D`）と FRB 稼働率（`D`）の関係（`E9-15`・`E9-16`）。`bh_price_elas_s` は**一般需要にのみ適用される**（[動学方程式](capex_credit_cycle_equations.md) §17 `E3`(i)）ため、一般需要と資本財需要を分離した観測が必要であり `ext_demand_s` の残差性に依存する → `SENS` |
| **`EB-5` CAPEX・投資** | `bh_alpha_capex_s1`(`EST`)・`bh_cc_elas_s1`(`EST`)・`bh_alpha_inv_s2`/`_s3`(`EST`)・`bh_cc_elas_inv_s`(`EST`)・`bh_lend_elas_inv_s`(`EST`)・`bh_dcap_lend_s`(`CAL-OBS`)・`bh_defer_roll`(`EST`)・`bh_cancel_thresh`(`CAL-OBS`)・`bh_cancel_slope`(`CAL-OBS`)・`bh_cancel_max`(`FIX`)・`bh_revive_s1`(`CAL-OBS`) | 8 `EST` | **識別が最も難しいブロック**（`ID-1`・`ID-2`）。`capex_exec_s1` は `C` で観測できるが、`target_cap_s1`・`cost_capital_s`・`cancel_s1` が潜在。`bh_alpha_capex_s1` と `bh_cc_elas_s1` を**同時推定しない**（§8.3 `ID-2` の対応）。`invest_s2`（BEA 産業別設備投資、`P`）で `bh_alpha_inv_s2` を推定する |
| **`EB-6` 雇用・賃金** | `bh_emp_up_s1`–`_s5`(`EST`)・`bh_emp_down_s1`–`_s5`(`EST`)・`bh_emp_band_s`(`CAL-OBS`)・`bh_wage_slope`(`EST`) | 部門別 + 1 | BLS CES の部門別雇用（`D`）と部門別産出（`D`/`C`）。上方・下方の調整速度差は雇用が増加した期と減少した期を分けて推定する。`bh_wage_slope` は `CES0500000003`（`C`）と `PAYEMS`（`D`）。**`bh_emp_band_s`（`NL-6`）は閾値であり回帰で推定しない** |
| **`EB-7` 消費** | `bh_mpc`(`EST`)・`bh_cons_adj`(`EST`) | 2 `EST` | `DSPIC96`（`P`）と `PCECC96`（`P`）。**両者が proxy であり、モデルの `cons` は部門範囲が狭い**（§3.2-8）。`ID-5` の対応として `EB-6` と分離して段階推定する |

**ブロック横断の契約**:

1. **推定は「そのブロックが必要とする観測系列がすべて揃っている」ときにのみ実行する**。1 系列でも欠ける場合、当該ブロックのパラメータは `CAL-OBS`（文献値）または `SENS` へ落とす（§6.3-2）。
2. **推定順序を固定する**: `EB-1` → `EB-3` → `EB-4` → `EB-6` → `EB-7` → `EB-5` → `EB-2`。金融条件と生産・在庫という観測が最も揃うブロックを先に確定し、識別が弱いブロックを後に置く。逆順で推定しない（順序依存の結果を隠さないため、順序を記録する）。
3. **objective は方程式別残差とする**（[Keen 実証化戦略](keen_empirical_strategy.md) §5.2 の ODE residual と同型）。各行動方程式の左辺の観測値と、右辺を観測値で評価した値の残差を最小化する。**軌跡全体を積分してから合わせる方式（trajectory matching）を初版に採らない**（非線形・閾値により目的関数が不連続になるため）。
4. **重み付けは方程式ごとの観測標準偏差の逆数**（`:std_normalize`）を既定とし、実際に用いた重みを保存する。単一の総合スコアへ集約しない。
5. **境界・符号制約は [動学方程式](capex_credit_cycle_equations.md) §13.2・§13.3 の範囲欄と §13.4 の許容条件を強制する**。境界に張り付いた推定値（`boundary_hits`）を隠さない。
6. 除外規則: 欠損期・`NaN`/`Inf`・符号制約違反期・§9 で選定した out-of-sample 区間を objective から除外し、除外期数と理由を記録する。

### 7.5 `SCN`（シナリオ入力）と `SENS`（感応度のみ）

| 対象 | 区分 | 扱い |
|---|---|---|
| `SH-EXP`・`SH-CAPEX`・`SH-CREDIT`・`SH-EASING` の規模・形状・時点・持続（契約 §5.3） | `SCN` | `parameters` に含めない。**`ai_exp` が `A` であるため `SH-EXP` の規模を観測から較正できない**（§3.3-2）。暫定既定値（`-10%` 等）を維持し、**規模の走査結果として結論を提示する**。単一の較正値として提示しない |
| 履歴再生時の外生パス（`policy_rate`・`ext_demand_s`・`price_s1`） | `SCN` | 実現値の観測パスを与える。`SH-EASING` を履歴再生で外生ショックとして重ねない（`ID-6`） |
| 初期状態（初期債務比率・稼働率・在庫比率・現金比率） | `SCN` | 契約 Q5 の走査対象。`parameters` に含めない。**走査時は定常条件を満たすよう逆較正を再実行する**（[動学方程式](capex_credit_cycle_equations.md) §14.4） |
| 診断閾値セット（契約 §4.2 の深さ・持続性・`breadth`、`prox_band`、`s5_resid_tol`） | `SENS` | §7.6 |
| `st_maturity_s`・`st_commit_s`・`pl_ltv`・`bh_price_elas_s` | `SENS` | 観測が無く推定もしない。既定値 + 走査範囲を定める |
| `SolverOptions`（`div_eps`・`guard_max`・`runup_tol`・`stop_on_sign_violation`）・`jac_h` | `SENS` | §10.5 の数値解法頑健性確認の対象 |

### 7.6 診断閾値の較正可能性

契約 §4.2 の閾値と `breadth` について、**較正できるもの/できないものを分ける**。

| 対象 | 較正可能性 | 扱い |
|---|---|---|
| `G1`–`G4` の深さ閾値（`dY ≤ -1.0%` 等） | **較正しない** | 契約 §8-2 が「閾値は理論から導かれていない」と明記している。履歴再生で公式景気後退期と一致するよう閾値を選ぶことは、契約 §4.1 が禁じる「一致率の目的関数化」に当たる。**暫定既定値を維持し、±50% の感応度を必ず併記する**（契約 §4.4） |
| 持続性（2 四半期以上連続） | **較正しない** | 同上 |
| `breadth ≥ 0.60` | **較正できない** | 実体部門 4 のため 0.25 刻みの離散値しか取らない（#165 §2.3・§9-6）。`0.60` の閾値は実質「4 部門中 3 部門以上」を意味する。**閾値を連続的に較正することは不可能である**。感応度は「2 部門以上 / 3 部門以上 / 4 部門」の 3 通りの離散比較として報告する |
| `breadth` のバイアス | **評価する** | [動学方程式](capex_credit_cycle_equations.md) §17 `E1`（家計所得が `S1` 需要へ還流しない）により `S1` が悪化しにくい方向のバイアスがある。**`S1` を分母から除いた `breadth`（3 部門版）を併記し、ラベルが変わるかを報告する**（同 §18 の引き渡し事項） |
| `s5_resid_tol`（既定 0.05） | `SENS` | #166 §8.3。履歴再生で `s5_net_sx` の実際の規模を確認し、既定値の妥当性を報告する（閾値を結果に合わせて緩めない） |

---

## 8. 識別リスクと弱識別時の対応

### 8.1 前提: 本モデルの構造が識別問題に与える影響

[ADR 0011](../adr/0011-capex-credit-cycle-dynamics-contract.md) の 2 つの決定が、Issue #170 §5 が挙げた識別リスクの形を変えている。

| 決定 | 識別問題への影響 |
|---|---|
| **期内に同時方程式を置かず、全循環に遅れを指定する**（同 決定 1・全 12 循環） | 推定は**逐次単一方程式**として書ける。連立方程式の同時性バイアスは構造上生じない。一方、**遅れの採用値（[動学方程式](capex_credit_cycle_equations.md) §13.5）が誤っていると、パラメータ推定値がその誤りを吸収する**。遅れの妥当性は §10.3 の反応ラグ検証で評価する |
| **期待に平滑化を重ねない（`ai_exp` は外生・平滑化なし）**（同 決定 3） | 「期待需要更新速度」というパラメータが存在しない。Issue #170 §5 の第 1 項（CAPEX 調整速度と期待需要更新速度の識別）は、**パラメータ間の識別問題から `ai_exp` proxy の構成の任意性へ変質する**（`ID-1`） |

### 8.2 識別リスクの一覧

| ID | リスク | 何が起きるか | 対応 |
|---|---|---|---|
| `ID-1` | **CAPEX 調整速度と期待の識別** | `ai_exp` が `A`（観測不能）であるため、`capex_exec_s1` の観測変動を「期待が動いた」と「調整速度が速い」のどちらへも帰属できる。`bh_alpha_capex_s1` の推定値は `ai_exp` の与え方に完全に依存する | `W3`（複数仕様併記）。`ai_exp` の代替構成（(a) 定数 = 1、(b) `compute_dem` の観測変動から逆算、(c) セクター株価の変動）で `bh_alpha_capex_s1` を推定し、**3 通りの推定値を並べて報告する**。単一値を採らない |
| `ID-2` | **信用スプレッド効果と営業CF効果の識別** | `spread` と `ocf_s` は不況期に同時に悪化する（共通ショック）。`bh_cc_elas_s1`（資本コスト経路）と `st_cash_ref_s1`/資金制約経路（`E7-10`）が観測 `capex_exec_s1` に対して代替的。加えて `cost_capital_s` が潜在、`debt_s`・`int_burden_s` が allocation 依存 | `W1` + `W2`。`bh_cc_spread = 1` を固定し `bh_cc_lend`・`bh_cc_equity`・`bh_cc_fc` を `W1`（文献値で固定）、`bh_cc_elas_s1` は `W2`（objective の等値域をグリッドで範囲報告）。**`bh_alpha_capex_s1` と `bh_cc_elas_s1` を同時推定しない**（`bh_alpha_capex_s1` を先に `ID-1` の仕様別に固定し、次に `bh_cc_elas_s1` を推定する） |
| `ID-3` | **需要減少と供給能力過剰の識別** | `util_s` の低下は「需要（`order_s`）が減った」でも「能力（`ycap_s`）が増えた」でも生じる。`ycap_s` が `P`（FRB Capacity は概念不一致）であるため分離が難しい。加えて `ext_demand_s` が残差であるため、AI CAPEX 起因分の配分比誤りが需要減少として現れる | `W2` + 独立情報の利用。**`backlog_s` と `inv_s` を分離情報として使う**（需要減少 → 受注残の減少が先行、供給過剰 → 在庫の増加が先行）。§4.3 の `ext_demand_s` 構成規則の 3 契約を適用し、配分比 `st_capex_share_s` は `alternative proxy` 感応度の必須対象とする |
| `ID-4` | **稼働率と在庫調整の代替性** | `bh_prod_cut_s`（在庫過剰による減産）と `bh_inv_adj_s`（在庫ギャップの調整速度）が観測 `y_s` に対して代替的 | **会計恒等式を制約として課す**。`inv_s = inv_s[t−1] + y_s − ship_s` と `backlog_s = backlog_s[t−1] + order_s − ship_s` を同一の `ship_s` で閉じる（#166 §5.3）ことで自由度が 1 つ減る。`inv_s`・`y_s`・`ship_s`・`order_s`・`backlog_s` の 5 系列がすべて `D` であるため、`EB-3` は本モデルで**最も識別が良いブロック**である |
| `ID-5` | **雇用乗数と消費性向の識別** | `bh_emp_down_s`（雇用の下方調整速度）と `bh_mpc`（限界消費性向）は `dC` に対して積として入る。同時推定すると片方が大きく他方が小さい解と、その逆の解が同じ fit を与える | **段階推定**（§7.4 の推定順序）。`EB-6`（雇用）を部門別雇用と部門別産出の関係から先に推定し、その結果を所与として `EB-7`（消費）を `hh_income` と `cons` の関係から推定する。同時推定しない。`bh_mpc` は文献値との比較を必ず併記する |
| `ID-6` | **政策反応と自然回復の識別** | モデルは政策反応関数を持たず `policy_rate` を外生とする（因果グラフ `X05` は `EXT`）。しかし**履歴再生では現実の緩和が内生反応である**ため、実現値の `policy_rate` パスを外生入力として与えると、緩和の効果と自然回復が分離されず、緩和効果が過大に帰属される | **構造的な対応**: (a) 履歴再生では `policy_rate` を実現値パスで与える。(b) **Q4（遮断成功の判定）を履歴再生から行わない**。Q4 は理論シナリオ（`Sc3` vs `Sc4`）の反実仮想比較に限定する。(c) 履歴再生の結果を「緩和が波及を遮断した」という因果的主張へ用いない |
| `ID-7` | **同時性・逆因果・共通ショック** | (a) 遅れ 0 のエッジ（`L44`・`L48`・`L31`・`L09`・`L11`）は期内の因果順序を表すが、四半期集約された観測からは順序を確認できない。(b) `equity_val` → `collateral` → `rollover` は逆因果（信用条件悪化が株価を下げる）を含みうる。(c) マクロショック（金融引締め・パンデミック）が AI CAPEX と一般経済を同時に動かす | (a) **遅れ 0 のエッジのパラメータを回帰で推定しない**（`CAL-OBS` または `SENS` へ）。`bh_cons_adj` は遅れ 0 の `L48` に属するため、`bh_mpc` と分離して推定する。(b) `bh_coll_elas`・`bh_roll_slope` は `W2`（範囲報告）。(c) `ext_demand_s`・`xdem_s5` が共通ショックを吸収する構造を明示し、**履歴再生でマクロショック期を含む場合はその事実を報告する**（§9 の `NC-3`） |

### 8.3 弱識別時の対応規則

**規則を推定前に割り当てる。推定後に選ばない**（§1.2-5）。

| 規則 | 内容 | 適用条件（事前に決める） |
|---|---|---|
| `W1` | **固定へ降格**（`CAL-OBS`・`FIX` へ移す） | 対応する観測変数が `E`（潜在）である。または方程式の左辺が観測できない |
| `W2` | **範囲報告**（点推定を出さず、objective の等値域をグリッドで報告） | 観測が `P` または `allocation` 依存であり、proxy・按分キーの選択で推定値が動く |
| `W3` | **複数仕様の並列報告** | 潜在系列の構成方式が複数ありうる（`ai_exp` の 3 仕様） |
| `W4` | **推定せず感応度のみ**（`SENS` へ移す） | 該当ブロックの観測系列が揃わない。または閾値パラメータ（`NL-1`–`NL-7`） |

**弱識別の検出方法**（実装フェーズの要件）

| 検出項目 | 方法 |
|---|---|
| 複数局所解 | 決定的な擬似乱数で初期値を摂動した multi-start。収束解の散らばりを報告 |
| 平坦な objective | 各推定値まわりの objective 曲率（前進差分による近似）。曲率が閾値未満なら弱識別 |
| パラメータ間相関 | ブロック内の推定値ペアの相関。高相関ペアは `W2` へ |
| 境界張り付き | `boundary_hits`。範囲欄の端に到達した推定値を隠さない |
| proxy 依存 | `alternative proxy` での再推定（§10.4）。推定値が符号を変えるものは `W2` へ |

**契約**:

1. **標準誤差を報告しない**（`standard_errors_supported = false`）。objective の曲率は分散推定ではない（[Keen 実証化戦略](keen_empirical_strategy.md) §5.4 と同方針）。
2. `W1`–`W4` を適用した事実・適用先・元の区分を methodology metadata へ記録する。
3. **弱識別を理由に推定対象を増やさない**。識別が難しい場合の解は「より多くを推定する」ではなく「固定する・範囲で報告する」である。

---

## 9. 履歴再生の候補と選定基準

### 9.1 必要条件（本書で固定する）

Issue #170 §6 の 5 基準を、判定可能な必要条件 7 件へ展開する。**全条件を満たさない候補を履歴再生に用いない**。

| ID | 必要条件 | 判定方法 |
|---|---|---|
| `NC-1` | **必須観測系列がすべて利用可能**（§6.2・§6.3 の系列のうち推定ブロック `EB-1`・`EB-3`・`EB-6`・`EB-7` に必要なもの） | 助走 8 四半期 + 評価 20 四半期の全期で非欠損（§2.2 の inner join） |
| `NC-2` | **需要・CAPEX・信用・雇用の時間順序を確認できる** | `order_s2`・`capex_exec_s1`・`spread`・`emp_tot` の 4 系列に、baseline 比の悪化開始時点が識別できる程度の変動（peak 乖離が `G1`–`G4` の深さ閾値を超える）があること |
| `NC-3` | **単一の特殊要因だけで説明されない** | 期間中に (a) 金融危機、(b) パンデミック等の供給制約、(c) 大規模財政・金融政策の急転、(d) 統計の定義変更が**同時に 2 つ以上**存在しないこと。1 つ存在する場合は該当事実を報告し、`ext_demand_s`・`xdem_s5` が吸収する量を併記する |
| `NC-4` | **データ revision・定義変更を追跡できる** | NAICS 改訂・BEA 産業分類変更・Census M3 の区分変更が期間内にある場合、変更前後の接続方法が provider metadata または一次資料で確認できること。接続できない場合は候補から外す |
| `NC-5` | **baseline 期間と out-of-sample 期間を確保できる** | 助走 8 四半期が定常近傍（`runup_deviation` が許容内）であり、かつ評価 20 四半期のうち後半 8 四半期以上を推定 objective から除外できること |
| `NC-6` | **`ai_exp` の代替構成が定義できる**（`ID-1` の `W3`） | §8.2 `ID-1` の 3 仕様（定数 / `compute_dem` 逆算 / 株価）のうち 2 つ以上が期間内で構成できること |
| `NC-7` | **診断ラベルの識別力が確認できる組を作れる** | 候補集合全体として、`contained_adjustment` に該当しそうな局面と `broad_downturn` に該当しそうな局面を**最低 1 件ずつ含む**こと（単一候補では満たせない集合レベルの条件） |

### 9.2 候補集合

**期間の最終選定は実装フェーズで行う**（Issue #170 の対象外）。本書は候補と、各候補が必要条件のどこで問題になりうるかを固定する。

| ID | 候補局面（暫定） | 想定される診断ラベル | 必要条件上の懸念 |
|---|---|---|---|
| `H1` | 2000–2003（ドットコム後の IT・半導体設備調整） | `broad_downturn` 寄り | `NC-4`: NAICS 1997→2002 改訂。`NC-1`: BEA GDP by Industry の四半期系列の開始時期。データセンター建設区分が存在しない |
| `H2` | 2008Q3–2010（世界金融危機） | `broad_downturn` | `NC-3`: 金融危機と急激な政策転換が同時（2 要因）。`ID-6` の政策反応問題が最も強く出る |
| `H3` | 2011–2012（半導体在庫調整） | `contained_adjustment` 寄り | `NC-2`: 変動が小さく悪化開始時点の識別が難しい可能性 |
| `H4` | 2015–2016（半導体・エネルギー設備調整） | `sectoral_downturn` 寄り | `NC-3`: エネルギー価格急落という別要因の併存 |
| `H5` | 2018Q4–2019（米中貿易摩擦下の半導体調整） | `contained_adjustment` / `sectoral_downturn` | `NC-3`: 通商政策という別要因。ただし信用条件は比較的安定で `credit-off` 対照として有用 |
| `H6` | 2022Q3–2023（メモリ・PC 需要調整 + 金融引締め） | `sectoral_downturn` 寄り | `NC-3`: 金融引締めとインフレが同時。`NC-5`: 期間末が最新データに近く評価 20 四半期を確保できない可能性 |

**契約**:

1. **`NC-7` を満たす最小の組を選ぶ**。候補を多く選んで fit の良いものを事後に選択しない。選定した候補と、除外した候補の除外理由を記録する。
2. **AI・データセンター CAPEX 局面（2023 以降）を履歴再生に用いない**。評価 20 四半期を確保できず（`NC-5`）、かつ baseline 期間が定常近傍でない（急成長局面）。契約 §2.1 の助走要件を満たさない。
3. **過去局面での較正結果を現在の AI 投資構造へそのまま移植しない**（§11-6）。`H1`–`H6` はいずれもデータセンター建設・アクセラレータ主導の CAPEX 構造を持たない。
4. 履歴再生の結果と公式景気後退判定の時期的一致は**記述的に報告するにとどめる**。一致率を較正の目的関数にしない（契約 §4.1・[シナリオ時間軸](../architecture/scenario_time_semantics.md) §7）。

### 9.3 履歴再生の baseline の扱い

[動学方程式](capex_credit_cycle_equations.md) §14.1 は「baseline を成長率ゼロの定常状態とする」ことを決め、実データのトレンドを baseline とする方式（候補 (c)）の扱いを本書へ引き渡した。

| 論点 | 決定 | 根拠 |
|---|---|---|
| 履歴再生の baseline | **助走 8 四半期の観測平均を定常水準とし、成長率ゼロの定常状態を baseline とする**（§5.1 と同一） | モデル構造が成長経路を持たないため、トレンド付き baseline を与えても定常条件が満たされない |
| トレンドの扱い | 観測系列のトレンドを除去しない。**観測とモデルの比較は baseline 比乖離 `dx_t` で行う**（契約 §2.4）。観測側の `dx_t` は助走期間平均を `x^{base}` として計算する | 水準トレンドは `dx_t` で部分的に相殺される。完全には相殺されないため §11-4 の限界とする |
| 帰結 | 評価 20 四半期に成長トレンドがある場合、**観測の `dx_t` はトレンド分を含み、モデルの `dx_t` は含まない**。この非対称性を検証 metric の解釈に必ず添える | トレンドをモデル側へ入れると `st_` パラメータの定常整合が崩れる（§14.1 の (b) 不採用理由） |

---

## 10. 検証指標

### 10.1 数値fitと構造的検証の分離（本節の中心的な決定）

**決定: 数値fit・動学再現・構造的検証・感応度を別のレイヤーとして報告し、単一の総合スコアへ集約しない。**

| レイヤー | 問い | 集約 |
|---|---|---|
| §10.2 数値fit | 系列の水準・変動がどれだけ合うか | 変数別に報告。総合点を作らない |
| §10.3 動学・構造 | 波及の順序・遅れ・形が合うか | 項目別の真偽・時点差として報告 |
| §10.4 比較 | 仕様・proxy・標本・イベント写像を変えて結論が変わるか | 仕様間の差として報告 |
| §10.5 数値解法頑健性 | 結果が数値設定の産物でないか | 設定別の差として報告 |

**契約**: 実証層で単一の pass/fail 閾値を課さない。calibrated が literature/default より悪化した場合は `calibrated_worse_than_literature` として明示し隠さない（[Keen 実証化戦略](keen_empirical_strategy.md) §6.1 と同方針）。

### 10.2 数値fit

| 指標 | 定義・注意 |
|---|---|
| RMSE / MAE | 変数別・区間別（in-sample / out-of-sample）。**欠損・打ち切り後の `NaN` を有効ペアから除外し `0` として扱わない** |
| correlation | 変数別。水準とレベル差分の両方で計算し区別する |
| bias（mean error） | 符号付き平均誤差。系統的なずれの検出 |
| scale-normalized error | 観測標準偏差で正規化した RMSE（`rmse_standardized`）。**部門別水準（10億ドル）と比率・指数のスケール差を単一点へ集約しないための代替**であり、総合スコアではない |
| 評価対象 | `D` / `C` 分類の変数に限る。**`P` 分類の変数の水準 RMSE を fit の根拠として提示しない**（§3.1 の契約）。`E` / `A` 分類の変数について fit を計算しない |
| 区間分離 | in-sample（推定に用いた区間）と out-of-sample（`NC-5` で確保した区間）を**必ず別々に報告する** |

### 10.3 動学・構造の検証

| 項目 | 判定方法 |
|---|---|
| **方向性** | `dx_t` の前期比符号の一致率。変数別 |
| **転換点** | peak / bottom の個数と timing error（四半期）。`peak(dx)` の定義は契約 §2.4 |
| **反応ラグ** | 悪化開始時点（`dx_t` が閾値を初めて超える期）の系列間差。**[動学方程式](capex_credit_cycle_equations.md) §13.5 の遅れ採用値の妥当性評価に用いる**（§8.1 の懸念への対応）。観測とモデルでラグが系統的に異なる場合、遅れの採用値を再検討事項として同書へ差し戻す |
| **peak と持続期間** | `peak(dx)` の値と、閾値超過が連続した四半期数 |
| **部門間波及順序** | `capex_exec_s1` → `order_s2`/`order_s3` → `emp_s2`/`emp_s3` → `hh_income` → `cons` → `y_tot` の悪化開始時点が**観測でもこの順序になっているか**。順序が逆転する系列対を報告する。**`L44`（`capex_exec_s1` → `S3` 雇用）が `L43`（産出経由）より早いことは仮説の内容であり**（同 §13.5）、観測で確認する |
| **信用ショック有無による増幅差** | **観測から `A`（増幅度）を計算しない**。`A` は同一実装内の反実仮想（`credit-off`）でのみ定義される（契約 §3 Q2 の契約・[責務境界](capex_credit_cycle_model_boundaries.md) §2.4）。履歴再生では、信用条件が悪化した局面（`H2`・`H6`）と比較的安定な局面（`H5`）で**モデルの `A` が異なるか**を報告する。観測の増幅を推定したとは述べない |
| **産業内調整 / `broad_downturn` の分類** | 診断ラベルの一致を**記述的に**報告する。ラベルの正解が観測に存在しないため、`G1`–`G4` の観測側充足状況と併記する。**一致率を目的関数にしない**（§7.6） |
| **会計恒等式の維持** | #166 §8.1 の 12 項目が全期 `acc_pass` であること。履歴再生（外生パスが実現値）でも成立することを確認する。`acc_fail` があるシミュレーションの診断ラベルには**会計違反の存在を必ず併記する**（#166 §8.3） |
| **定常条件・助走** | `SS-1`–`SS-17` の充足、`runup_deviation` の有無と大きさ、§5.2-5 の `ss_residual` |
| **構造的警告** | `termination_reason`・`funding_forced`・`a2_violation`（`unmet_cap_s > 0`）・`sign_constraint`・`threshold_proximity` の発生を隠さず報告する（[動学方程式](capex_credit_cycle_equations.md) §15.5・§18） |

### 10.4 比較（仕様間）

| 比較軸 | 内容 |
|---|---|
| `literature/default` vs `calibrated` | 文献値・既定値のパラメータセットと較正後を**必ず並べる**。較正が改善するとは限らないことも報告する |
| `alternative proxy` | 必須対象: (a) `spread` の HY / IG、(b) `debt_s`・`int_burden_s` の按分キー（`sales_s` シェア / `cap_s` シェア）、(c) `ai_exp` の 3 仕様（`ID-1` の `W3`）、(d) `st_capex_share_s` の配分比（`ID-3`）、(e) `y_s` のアンカー基準年、(f) `ycap_s` に FRB Capacity を用いる場合と `cap_s / st_cor_s` を用いる場合 |
| `alternative sample` | §9 で選定した履歴再生候補のうち 2 件以上で同じ推定・検証を行い、推定値と結論の安定性を報告する |
| `alternative event mapping` | イベント → 外生変数の写像（[イベント変換契約](../architecture/macro_event_contract.md) §4）と適用四半期の割当規則（[シナリオ時間軸](../architecture/scenario_time_semantics.md) §4.3 の `:cutoff` / `:same_quarter` / `:next_quarter`、`cutoff_date` の既定）を変えた場合の結論の差。**割当規則の感応度併記は同書 §4.6 の義務** |
| `alternative shock scale` | `SH-EXP`・`SH-CAPEX`・`SH-CREDIT` の規模走査（§7.5 の `SCN`）。**規模を較正値として提示せず走査結果として提示する** |
| 閾値感応度 | 契約 §4.2 の各閾値 ±50%（契約 §4.4 の義務）と、`breadth` の 3 通りの離散比較・`S1` 除外版（§7.6） |

### 10.5 数値解法頑健性と診断量の数値導出

[動学方程式](capex_credit_cycle_equations.md) §18 が本書へ引き渡した確認事項。

| 項目 | 確認方法 |
|---|---|
| 定常状態からの前向き数値解 | 定常状態から 28 期進めて水準が動かないこと（同 §14.2 の位置づけ）。契約 Q5 の「分岐が数値解法の産物でないことの確認」 |
| `div_eps`（既定 `1e-8`） | 1 桁上下させて結果が変わらないこと。変わる場合はゼロ除算の発生箇所（同 §15.4 の 13 箇所）を特定して報告する |
| `guard_max`（既定 `1e6`） | 打ち切り（`termination_reason`）の発生有無が閾値に依存しないこと。依存する場合は打ち切りの事実を必ず明示する（同 §18 の LLM 必須記載 1） |
| `runup_tol`（既定 `1e-8`） | 履歴再生の baseline 期間で `runup_deviation` が発生する場合、閾値を緩めるのではなく**定常水準の算出方式（§5.1）の限界として報告する** |
| `jac_h`（既定 `1e-6`、ループ利得のヤコビアン摂動幅） | 1 桁上下させたときのループ利得 `ρ_t` の変化を報告する。閾値近傍で不安定になる（同 §19-11）ことの確認 |
| `prox_band`（既定 `0.10`） | `threshold_proximity` の検出が帯幅に依存する度合い |
| `μ_j` の数値導出（`share_C` の寄与分解） | 同 §16.6 の反実仮想寄与を数値的に導出し、加法分解との乖離を報告する（同 §19-12） |
| Q3 の追加 1 実行 | 同 §16.6 が `share_C` の算出に追加 1 実行を要することを検証計画へ織り込む |
| `breadth` バイアス（`E1`） | §7.6 の 3 部門版 `breadth` 併記 |
| 会計許容誤差（`atol = 1e-8` / `rtol = 1e-6`） | 水準が 10億ドル基準であるため `rtol` が絶対誤差 100万ドル相当になる（#166 §8.2 の注意）。20 四半期累積で系統誤差が生じないことを `:stock_flow` の毎期検証で確認する |

### 10.6 検証結果の出力契約

| 項目 | 規約 |
|---|---|
| 分離 | §10.2–§10.5 を別フィールドとして構造化する。単一スコアへ集約しない |
| 警告 | 弱識別（`W1`–`W4` の適用）・境界張り付き・打ち切り・会計違反・`runup_deviation`・`ss_inconsistent` を `warnings` へ集約し隠さない |
| caveats | §11 の限界を機械可読な `caveats` として保持し、LLM 説明層へ渡す（[ADR 0005](../adr/0005-keen-ai-explanation-contract.md) の根拠階層に写像する） |
| 根拠階層 | 観測（`D`/`C`/`P`）・逆較正（`CAL-SS`）・推定（`EST`）・モデル出力（`simulated`）・診断（`diagnostic`）・感応度（`sensitivity`）を**分離して出力する**。同書の category へ対応させる |
| 決定性 | 同一 fixture・同一設定・同一 seed で決定的に再現すること。非有限値は JSON `null` として保存し `0` 化しない |
| provenance | §6.6 の methodology metadata を結果に含める。生系列は含めない |

---

## 11. 因果・予測上の限界

Issue #170 §8 の 7 項目を、本モデル固有の内容とともに明記する。

1. **当てはまりは因果妥当性を保証しない**。§10 の fit が良いことは、モデルの因果構造（[因果グラフ](capex_credit_cycle_causal_graph.md)）が正しいことを意味しない。関数形は仮説であり実データによる関数形選択を経ていない（[動学方程式](capex_credit_cycle_equations.md) §19-1）。
2. **シナリオ結果は景気後退確率ではない**。`broad_downturn` はモデル内診断ラベルであり、公式景気後退判定でもその予測でもない（契約 §4.1）。確率の一点推定を出力しない（契約 §6）。
3. **株価・企業ガイダンスは期待と実体を混在させる**。`equity_val` は期待・割引率の変動を含み変動が過大である（§4.5）。`capex_plan_s1` に対応する企業ガイダンスは計画であり実行ではない。#166 §5.7 の「評価損を実体支出と同一視しない」方針と合わせ、`equity_val` の乖離を実体的損失として説明しない。
4. **公表統計にはラグ・revision・aggregation error がある**。初期MVPは `:latest`（確定値）のみを用い `:as_of` を実装しない（§2.4）。したがって**「その時点で判断できた」という主張を一切行えない**。`allocation` を伴う系列（`debt_s`・`int_burden_s`・`order_s3`）は按分キーの選択で値が変わる（§4.6）。baseline 期間平均を定常水準とする方式は、期間内のトレンドを定常状態へ押し込む（§9.3）。
5. **非観測期待・信用制約には複数の説明がありうる**。`ai_exp`・`cost_capital_s`・`target_cap_s1`・`cancel_s1` は潜在であり、同じ観測を複数のパラメータ組が説明する（`ID-1`・`ID-2`）。`W2`・`W3` による範囲・複数仕様の報告は、**この非一意性を隠さないための手段であり、真の値へ近づく手段ではない**。
6. **過去局面での較正は現在の AI 投資構造へそのまま移植できない**。`H1`–`H6` はいずれもデータセンター建設・アクセラレータ主導の CAPEX 構造を持たず、資本財の供給元構成（`st_capex_share_s`）・リードタイム（`st_pipelag_s`）・部門の異質性が現在と異なる（§9.2-3）。
7. **モデル結果を投資助言・政策推奨と同一視しない**。Q4 の遮断判定は理論シナリオの反実仮想比較に限定し（`ID-6`）、政策効果の因果推定として提示しない（契約 §4 Q4 の契約）。個別企業の株価予測・投資推奨は対象外（契約 §6）。

**本モデル固有の追加限界**

8. **`S1` の収益ブロックが観測に接続されない**（§6.4 の決定）。`sales_s1`・`profit_s1`・`ocf_s1`・`cash_s1` は企業開示依存のため初期MVPで較正・検証されない。増幅ループ `R1a` を実証的に検証できない。
9. **`SH-EXP` の規模を観測から較正できない**（§3.3-2）。`ai_exp` が `A` 分類であるため、起点ショックの大きさは走査対象であり較正値ではない。したがって **`peak(dY)` の絶対的な大きさに実証的な意味を与えられない**。判定問題の回答は「どの条件で何が起きるか」に限られ、「どの程度悪化するか」の実証的推定ではない。
10. **`breadth` の閾値を較正できない**（§7.6）。実体部門 4 のため 0.25 刻みであり、`0.60` は「4 部門中 3 部門以上」を意味する離散判定である。
11. **`ext_demand_s` が残差であるため測定誤差・部門範囲の過大・配分比の誤りをすべて吸収する**（§4.3 の契約）。この残差の変動を「モデル外需要の推定値」として提示しない。
12. **推定ブロックの順序が結果に影響する**（§7.4-2）。逐次推定は同時推定の識別困難を回避する手段であり、ブロック間の相互依存を無視する近似である。順序を変えた場合の推定値の差は `alternative specification` として報告しうるが、初期MVPの既定は固定順序である。
13. **out-of-sample 検証はモデル構造の妥当性の検証であり予測精度の評価ではない**。標本が短く（`NC-5` で 8 四半期以上）、履歴再生候補が構造の異なる過去局面であるため、予測誤差を将来の予測精度として提示しない。
14. **本書は実装・実データによる検証を経ていない**。§4 の系列候補・§5 の定常水準算出方式・§7 の区分・§8 の識別リスク評価・§9 の候補集合は設計判断であり、実装フェーズで棄却されうる。

LLM による説明生成時は、上記を [llm_safety.md](../llm_safety.md) の必須記載事項および [動学方程式](capex_credit_cycle_equations.md) §18 の LLM 必須記載 8 項目と併せて提示する。

---

## 12. 後続作業への引き渡し

| 引き渡し先 | 内容 |
|---|---|
| #171 統合 | §6.5 の層境界（モデル層が `DataSeries` を受け取らない）・§6.6 の methodology metadata 保存項目と fixture 配置・§10.6 の出力契約と根拠階層・§7.5 の `SCN`（初期状態指定 API・診断閾値セット型）・§2.4 の `:as_of` を実装しない決定の API 上の表現 |
| データ層実装 | §4 の観測方程式 9 項目・§4.2 の頻度変換割当（NIPA 年率の `÷ 4` を含む）・§4.3 の `y_s` アンカー式と `ext_demand_s` 構成規則・§6.2/§6.3 の系列リストと確認義務・§2.2 の inner join と標本期間算出・§2.3 の欠損規約 |
| 較正・推定層実装 | §5 の逆較正入力の観測対応と `steady_state_targets` の保存・§7 の 6 区分と全パラメータの割当・§7.4 の推定ブロックと固定順序・objective/重み/除外規則・§8.3 の弱識別検出と `W1`–`W4` |
| 検証層実装 | §10.2–§10.6 の指標・分離・警告・決定性 |
| LLM 説明層 | §11 の 14 限界・§10.6 の根拠階層・§2.4 の「その時点で予測できた」禁止・§3.2 の `P` 分類のずれの方向・`cost_capital_s` の単独提示抑止（#165 §5.4） |
| 上流への差し戻し候補 | §10.3 の反応ラグ検証が [動学方程式](capex_credit_cycle_equations.md) §13.5 の遅れ採用値と系統的に食い違う場合、同書へ差し戻す。`E1`（`breadth` バイアス）の評価結果は #164 のエッジ追加可否の判断材料として同書 §17 へ返す |

---

## 13. 対象外

[Issue #170](https://github.com/Yuki-Watanabe7/DME/issues/170) の対象外に加え、本書で明示する。

| 対象外 | 扱い |
|---|---|
| データ取得コード・変換の Julia 実装 | データ層実装（後続） |
| 実際のパラメータ推定・推定値 | 較正層実装（後続） |
| 履歴再生の実行・標本期間の最終選定 | 検証層実装（後続） |
| 景気後退確率・因果効果の推定 | 行わない（契約 §6・§11-2） |
| `:as_of`（vintage）モードの実装 | 初期MVPでは行わない（§2.4）。実装する場合は本書を改訂する |
| 企業データ provider の接続 | 初期MVPでは行わない（§6.4） |
| ベイズ推定・状態空間モデル・粒子フィルタ | 行わない（[Keen 実証化戦略](keen_empirical_strategy.md) §9 と同方針） |
| 標準誤差の統計的推論 | 行わない（§8.3 の契約） |
| 診断閾値の較正 | 行わない（§7.6）。感応度のみ |
| 日本その他への拡張 | 設定分離のみ確定（§2.1） |
| `economic-data-provider` 側の API 仕様・内部設計 | 同リポジトリ |
| モデル方程式・パラメータの関数形の変更 | [動学方程式](capex_credit_cycle_equations.md)（改訂が必要） |

---

## 14. 参考

- [分析契約](capex_credit_cycle_analysis_contract.md) — 基準ユースケース・判定問題 Q1–Q5・シナリオ `Sc0`–`Sc4`・`broad_downturn` の操作的定義
- [因果グラフ](capex_credit_cycle_causal_graph.md) — `1.1.0`。ノード・エッジ・増幅ループ・遮断経路・観測可能性コード
- [部門境界と変数定義](capex_credit_cycle_sectors_variables.md) — `1.1.0`。変数辞書・観測候補・役割分類・単位と時点基準
- [ストック・フロー会計表](capex_credit_cycle_stock_flow.md) — 残高更新式・資金調達恒等式・会計検証 12 項目と許容誤差
- [責務境界とモデル間比較契約](capex_credit_cycle_model_boundaries.md) — 横断比較・`mapping_type` と `comparability` の 2 層分離・`metadata` 予約キー
- [動学方程式と数値計算契約](capex_credit_cycle_equations.md) — `1.0.0`。パラメータ辞書・逆較正・定常条件・数値ガード・診断層
- [マクロイベント変換契約](../architecture/macro_event_contract.md)・[シナリオ時間軸](../architecture/scenario_time_semantics.md) — 適用先 7 変数・合成規則・vintage と as-of
- [Keen モデル 実証化戦略](keen_empirical_strategy.md) — 測定・識別・頻度整列・固定/推定分離・検証の設計原則の継承元
- [ADR 0004](../adr/0004-keen-empirical-calibration-strategy.md)・[ADR 0005](../adr/0005-keen-ai-explanation-contract.md)・[ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md)・[ADR 0011](../adr/0011-capex-credit-cycle-dynamics-contract.md)・[ADR 0012](../adr/0012-capex-credit-cycle-empirical-contract.md)
- [FRED API 接続ガイド](../data/fred.md)・[実データ前処理ユーティリティ](../data/preprocess.md)・[DataSeries / MacroDataset 利用ガイド](../data/data_series_guide.md)・[モデル変数と実データ系列のマッピング表](../data/variable_mapping.md)
- [LLM出力の安全性・免責・禁止表現ルール](../llm_safety.md)

---

## 15. #171 統合レビューによる改訂（`1.1.0`）

本節は #171 の横断整合レビュー（[統合設計](../architecture/capex_credit_cycle_integration.md) §2）で検出された不一致のうち本書が担当する 6 件の解決を記録する。**本節は本書の正本であり、本文の該当箇所と矛盾する場合は本節が優先する。**

### 15.1 区分の一意性の確保（`X-23`）

§7.1 は「各パラメータは**ちょうど 1 つの区分を持つ**」と契約しているが、§7.2・§7.4 に二重区分が 3 件あった。次のとおり一意化する。

| パラメータ | 改訂前 | 改訂後 |
|---|---|---|
| `st_pipelag_s1`–`_s3` | `CAL-OBS`（観測が不十分なため `SENS` 併用） | **`CAL-OBS`**。感応度走査は §10.4 の `alternative proxy` 感応度の必須対象として扱う（区分ではない） |
| `st_dcap_s1`–`_s3` | `CAL-OBS`（倍率は `SENS`） | **`CAL-OBS`**。倍率の走査は §10.4 の感応度対象として扱う |
| `bh_cc_lend`・`bh_cc_equity`・`bh_cc_fc` | 表上 `EST`、既定対応が `W1`（固定へ降格） | **`CAL-OBS`**。`W1` を**事前適用**する。`W1` の適用条件（対応する観測変数が `E`（潜在））は `cost_capital_s` が `E` であることから推定前に判定できるため、推定後の移動ではない。`EST` の一覧から外す |

**§7.1 への追加契約**: **区分と「感応度走査の対象であること」は直交する概念である**。`CAL-OBS` に分類したパラメータを §10.4 の感応度対象に含めることは区分の二重付与ではない。`SENS` は「推定・較正せず既定値を置く」ことを意味し、較正したうえで感応度を見る場合は `CAL-OBS` である。

**§7.5 の `SENS` 一覧**（改訂後）: `st_maturity_s1`–`_s3`・`st_commit_s1`・`pl_ltv`・`bh_price_elas_s2`/`_s3`・診断閾値セット・`CapexCreditCycleOptions` の数値設定。`st_pipelag_s`・`st_dcap_s` は含まれない。

### 15.2 記号名と個数の修正（`X-22`・`X-25`）

| ID | 改訂 |
|---|---|
| `X-25` | §7.5 の `st_commit_s`（部門一般形）を **`st_commit_s1`** へ修正する。#169 §13.2 に存在するのは `S1` のみである |
| `X-22` | §7.4 の推定ブロックの `EST` 個数を実測値へ修正する。改訂後（15.1 の `W1` 事前適用と `X-20` の `CAL-SS` 反映を含む）:<br>・`EB-1` 金融条件: **4 `EST`**（`bh_fc_pol`・`bh_spread_cov`・`bh_spread_fc`・`bh_lend_spread`）<br>・`EB-2` 資本コスト・評価・担保: **3 `EST`**（`bh_ev_elas`・`bh_coll_elas`・`bh_roll_slope`。`bh_cc_lend`・`bh_cc_equity`・`bh_cc_fc` は `W1` 事前適用により `CAL-OBS`）<br>・`EB-3` 生産・在庫・受注残: **4 `EST`**（`bh_inv_adj_s2`/`_s3`・`bh_prod_cut_s2`/`_s3`）<br>・`EB-4` 価格: **4 `EST`**（`bh_price_adj_s2`/`_s3`・`bh_price_sens_s2`/`_s3`）<br>・`EB-5` CAPEX・投資: **9 `EST`**（`bh_alpha_capex_s1`・`bh_cc_elas_s1`・`bh_alpha_inv_s2`/`_s3`・`bh_cc_elas_inv_s2`/`_s3`・`bh_lend_elas_inv_s2`/`_s3`・`bh_defer_roll`）<br>・`EB-6` 雇用・賃金: **11 `EST`**（`bh_emp_up_s1`–`_s5` 5・`bh_emp_down_s1`–`_s5` 5・`bh_wage_slope` 1）<br>・`EB-7` 消費: **2 `EST`**（`bh_mpc`・`bh_cons_adj`）<br>**`EST` 総数 = 37（部門展開後）**。改訂前の `EB-5` の「8」・`EB-6` の個数未記載・#169 §13.3 末尾の「推定 28」はいずれも実測と一致していなかった（#169 側は同書 §21.6 で行数基準へ修正済み） |

### 15.3 #166 §11 の引き渡し要求の変更の記録（`X-24`）

**追記**: #166 §11 の #170 への引き渡しは「§10.1 表 4 の構造パラメータの較正対象（`st_capex_share_s`・`st_cor_s`・**`st_maturity_s`**・`st_wbase_s`）」と明記していた。本書は `st_maturity_s` を較正せず `SENS` としており、引き渡し要求を外している。

**理由**（§7.2 に記載済み。本節で引き渡し変更の事実として明示する）: `st_maturity_s`（部門別の平均満期）は企業開示に依拠する `A` 分類の量であり、[ADR 0012](../adr/0012-capex-credit-cycle-empirical-contract.md) 決定 9（企業開示を較正入力から除外する）に該当する。公開系列に部門別の平均満期は存在しない。したがって既定値を置き、走査範囲を定める `SENS` として扱う。#166 §11 の引き渡し要求はこの決定により**充足されない**。

`st_capex_share_s`・`st_cor_s`・`st_wbase_s` の 3 系統は引き渡しどおり較正対象である（`st_cor_s`・`st_wbase_s` は `CAL-SS`、`st_capex_share_s` は `CAL-OBS` かつ §10.4 の `alternative proxy` 感応度の必須対象）。

### 15.4 `ext_demand_s^{ss}` の観測ソース参照の修正（`X-20` 付随・`D-12`）

§7.2 は `st_extdem_s2` / `_s3` を `CAL-SS` として「§5.2（`ext_demand_s^{ss}`、§4.3 の残差）」と参照しているが、**§5.2 の 13 行目（#169 §14.2 ステップ 13 に対応）の観測ソース欄は「上記から機械的に導出」であり、`ext_demand_s^{ss}` の観測ソースを与えていない**。

**改訂**: §5.2 の 13 行目の観測ソース欄を次へ改める。

> `st_profit_ref`・`st_emp_ref`・`st_coll_ltv` は上記ステップの出力から機械的に導出する。**`st_extdem_s2` / `_s3`（= `ext_demand_s^{ss}`）は §4.3 の残差構成規則により、`y_s^{ss}` から資本財需要成分（`order_cap_s^{ss}`・`order_inv_s3^{ss}`）と一般需要成分（`order_gen_s^{ss}`）を差し引いた残差として算出する**。残差であるため測定誤差・部門範囲の過大・配分比の誤りをすべて吸収する（§11-11）。残差が負になる場合は**クリップせず**、配分比（`st_capex_share_s`・`st_gen_share_s`）または部門範囲の設定を見直す（§4.3 の 3 契約）。

### 15.5 上流改訂の反映（`X-14`・`X-20`）

| 上流改訂 | 本書への影響 |
|---|---|
| 在庫の当期価格評価（[ADR 0013](../adr/0013-capex-credit-cycle-integration-contract.md) 決定 4・#166 §14.5・#169 §21.3） | §7.2 の `FIX` 一覧から **`st_invprice_s2`・`st_invprice_s3` を削除する**。構造パラメータは 35 系統から **34 系統**へ。§7.2 の「全 35 系統」という記述を「全 34 系統」へ改める。`invval_s` の観測対応（在庫の価値額）は当期価格建てとなり、Census M3 の在庫額（帳簿価額）との差を `proxy` のずれの方向として記録する（過小方向。物価上昇局面では帳簿価額が当期価格を下回る） |
| §13.2・§13.3 の区分欄の修正（#169 §21.6） | §7.1 の契約へ追記: 「**`CAL-OBS` から `CAL-SS` へ移した系統を記録する**。#169 `1.0.0` §13.2・§13.3 が『較正』としていた 11 系統（`st_cor_s`・`st_lprod_s`・`st_va_share_s`・`st_wbase_s`・`st_cons_share_s1`・`st_spread0`・`st_pol_ref`・`st_coll_ltv`・`bh_util_tgt_s`・`bh_backlog_target_s`・`bh_inv_target_s`）は §14.2 の逆較正で閉形式導出されるため本書は `CAL-SS` を割り当てた。この読み替えは #169 §21.6 で同書側にも反映された。」既存の契約（`EST` から移した事実と移動先を記録する）は `EST` 起点の移動のみを対象としていた |
| `price_s` の生成位置・`order_inv_s3` の参照時点（#169 §21.1・§21.2） | §10.5 の数値解法頑健性の確認項目に **「`:no_double_count` が価格変化局面・投資変化局面で `acc_pass` になること」**を追加する（改訂前の式では定常状態外で破れていたため、履歴再生で `acc_fail` が生じうる） |
| 状態次元 65 → 64（#169 §21.2） | §10.5 のヤコビアン評価回数の見積り（`65 + 1 = 66` 回 / 期）を **`64 + 1 = 65` 回 / 期**へ改める |

### 15.6 検証項目への追加（`X-14` の帰結）

§10.3「会計恒等式の維持」の判定に次を追加する。

> 履歴再生（外生パスが実現値）でも #166 §8.1 の 12 項目が全期 `acc_pass` であることを確認する。**特に `:stock_flow`・`:net_worth_update`・`:no_double_count` は、改訂前の在庫評価・資本財受注価格の定義では定常状態外で系統的に破れていた**（[統合設計](../architecture/capex_credit_cycle_integration.md) §2.2 `X-14`・`X-15`・`X-16`）。改訂後の定義で成立することを、価格が動く局面・投資が動く局面を含む区間で確認する。定常条件テスト（`SS-1`–`SS-17`）はこの種の不整合を検出しないため、代替にしない。

---

## 16. 改訂履歴

| version | 日付 | 変更 |
|---|---|---|
| `capex-credit-cycle-empirical/1.1.0` | 2026-07-30 | #171 の統合レビューによる改訂（§15）。上位契約を `vars/1.2.0`・`accounting/1.1.0`・`equations/1.1.0`・`macro-event-contract/1.0.1` へ更新。区分の二重付与 3 件を一意化（`st_pipelag_s`・`st_dcap_s` を `CAL-OBS`、`bh_cc_lend`/`bh_cc_equity`/`bh_cc_fc` を `W1` 事前適用で `CAL-OBS`）し、区分と感応度対象が直交する概念であることを §7.1 へ追記。`st_commit_s` を `st_commit_s1` へ修正。推定ブロックの `EST` 個数を実測値へ修正（総数 37）。#166 §11 が引き渡した `st_maturity_s` の較正要求を外した事実と理由を記録。§5.2 の `ext_demand_s^{ss}` の観測ソースを §4.3 の残差構成規則として明記。在庫の当期価格評価に伴い `st_invprice_s` を `FIX` 一覧から削除（構造 35 → 34 系統）。状態次元を 64 へ。`:no_double_count` の価格・投資変化局面での検証と会計恒等式の履歴再生検証を §10 へ追加 |
| `capex-credit-cycle-empirical/1.0.0` | 2026-07-30 | 初版（#170）。観測可能性 5 分類（`D`/`C`/`P`/`E`/`A`）と 8 群の変数割当・観測方程式の構成要素 9 項目と部門別実物量/資本能力/金融信用の観測方程式・頻度変換の既定割当（NIPA 年率の `÷ 4` を含む）・`y_s` のアンカー式と `ext_demand_s` の残差構成規則と 3 契約・`aggregation`/`allocation`/`proxy` の methodology metadata・逆較正入力 13 項目の観測対応と定常水準の算出方式・データソース境界 3 層と企業開示を較正入力に用いない決定・モデル層/データ層/較正層の境界・fixture 最小セットと metadata 保存項目・パラメータ 6 区分（`FIX`/`CAL-SS`/`CAL-OBS`/`EST`/`SCN`/`SENS`）の全パラメータ割当・推定ブロック `EB-1`–`EB-7` と固定推定順序・診断閾値を較正しない決定と `breadth` の較正不能性・識別リスク `ID-1`–`ID-7` と弱識別対応規則 `W1`–`W4`・履歴再生の必要条件 `NC-1`–`NC-7` と候補 `H1`–`H6`・履歴再生 baseline を成長率ゼロの定常状態とする決定・数値fit/動学構造/比較/数値頑健性の 4 レイヤー分離と出力契約・因果と予測上の限界 14 件を固定 |
