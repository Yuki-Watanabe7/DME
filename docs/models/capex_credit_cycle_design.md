# 部門別CAPEX・信用循環モデル 統合モデル仕様（index・横断辞書）

> 関連 Issue: #171（本書）・#163〜#170（統合対象の設計成果）・#125（ロードマップ）
> 実装配置・API・テスト・作業分解: [統合設計](../architecture/capex_credit_cycle_integration.md)
> 実データ接続・較正・履歴再生・検証の実装契約: [実証統合設計](../architecture/capex_credit_cycle_empirical_integration.md)（#240）
> 決定記録: [ADR 0013](../adr/0013-capex-credit-cycle-integration-contract.md)・[ADR 0018](../adr/0018-capex-credit-cycle-empirical-runtime-contract.md)

---

## メタ情報

| 項目 | 内容 |
|---|---|
| **対象** | 部門別CAPEX・信用循環モデル（`CapexCreditCycleModel`、略記 `CCC`。未実装） |
| **ステータス** | 8 文書の統合仕様として確定。実装は未着手 |
| **design version** | `capex-credit-cycle-design/1.0.0` |
| **基準経済・頻度** | 米国・四半期（`Δt = 0.25` 年）。助走 8 四半期（`t = -8 … -1`）+ 評価 20 四半期（`t = 0 … 19`）= 28 四半期 |
| **部門** | `S1` AI・クラウド需要 / `S2` 半導体設計・製造 / `S3` 装置・建設・電力 / `S4` 金融・信用 / `S5` 家計・一般経済 / `SX` モデル外・残差（会計部門） |
| **部門集合** | `SP = {S2, S3}`（生産）・`SF = {S1, S2, S3}`（財務主体）・`SR = {S1, S2, S3, S5}`（実体部門。`breadth` の分母） |
| **会計閉鎖** | `accounting_closure = :partial`（`SX` を置いて閉じる。SFC を名乗らない） |

> **LLM向け要約**: 本書は #163〜#170 の 8 設計文書を**1 つのモデル仕様として読める形**に統合した index である。
> 新しい経済的判断を行わず、(1) どの事項の正本がどの文書のどの節かを固定し（§1）、
> (2) 分析目的から観測方程式までの 9 領域を統合仕様として要約し（§2–§10）、
> (3) 同一概念の記号・Julia 名・単位・時点基準が全文書で一致することを確認した**横断辞書**を与える（§11）。
> 実装配置・公開API・出力契約・テスト・作業分解は [統合設計](../architecture/capex_credit_cycle_integration.md) が正本である。
> 文書間の不一致 32 件（`X-01`–`X-32`）とその解決は同書 §2 に登録されており、本書はその解決後の状態を記述する。

---

## 1. 正典表（どの事項の正本がどの文書か）

実装・較正・説明のいずれの局面でも、次の対応で参照先を一意に決める。**同じ事項について 2 つの文書が異なる記述を持つ場合は、正本側を採り、他方は [統合設計](../architecture/capex_credit_cycle_integration.md) §2 の解決に従う。**

| # | 事項 | 正本（文書・節） |
|---|---|---|
| 1 | 基準ユースケース・起点事象 `E1`–`E3` | #163 [分析契約](capex_credit_cycle_analysis_contract.md) §2.2 |
| 2 | 部門の定義と追跡する代表量 | #163 §2.3（責務の詳細は #165 §3） |
| 3 | ホライズン・表記規約（`dx_t`・`peak(dx)`） | #163 §2.1・§2.4 |
| 4 | 判定問題 `Q1`–`Q5` と判定量・判定条件 | #163 §3 |
| 5 | `broad_downturn` の操作的定義・診断ラベル・閾値 | #163 §4.2・§4.3・§4.4 |
| 6 | シナリオ `Sc0`–`Sc4`・ショック 4 種の 7 項目 | #163 §5.1・§5.2・§5.3 |
| 7 | 初期MVPの対象外 | #163 §6 |
| 8 | ノード集合（37）・部門帰属 | #164 [因果グラフ](capex_credit_cycle_causal_graph.md) §2 |
| 9 | エッジ（64）の存在・型・符号・遅れの範囲・関数形候補・観測可能性・実装優先度 | #164 §3 |
| 10 | 増幅ループ `R1a`・`R1b`・`R2`–`R4`、減衰・遮断経路 `B1`–`B7` | #164 §4・§5 |
| 11 | 株式評価の媒介経路（直接エッジを置かない） | #164 §6 |
| 12 | 分岐条件候補 | #164 §7 |
| 13 | 部門区分の採用理由・部門責務・部門間フロー図 | #165 [部門境界と変数定義](capex_credit_cycle_sectors_variables.md) §2・§3 |
| 14 | 役割（`state`/`control`/`exogenous`/`diagnostic`）の判定規則 | #165 §4.2（規則 5 は改訂節） |
| 15 | 変数の存在・記号・Julia 名・単位・時点基準・優先度・`lag_depth` | #165 §5 |
| 16 | 命名規則・平坦キー方針・キー衝突検査 | #165 §6.4・§6.5 |
| 17 | instrument（8）・貸借対照表行列 | #166 [ストック・フロー会計表](capex_credit_cycle_stock_flow.md) §3.1・§3.2 |
| 18 | 取引フロー行列 `C-01`–`C-12`・`F-01`–`F-07`・ブロック分割 | #166 §4.1–§4.3 |
| 19 | 全ストックの残高更新式・純資産更新式 | #166 §5 |
| 20 | CAPEX 資金調達恒等式・閉じ変数・株価の作用経路 | #166 §6 |
| 21 | 資金繰り診断量（7）・`funding_pressure_s` の 5 値 | #166 §7.3・§7.4 |
| 22 | 会計恒等式検証 12 項目・許容誤差・残差監視・テスト設計 | #166 §8 |
| 23 | 含める責務（10）・含めない責務（12） | #167 [責務境界](capex_credit_cycle_model_boundaries.md) §3・§4 |
| 24 | `mapping_type` / `comparability` の 2 層分離・比較可否 | #167 §5.1・§5.2 |
| 25 | 同名変数の非同一視ルール・単位差の明示規約 | #167 §5.3・§5.4 |
| 26 | イベント翻訳可否表・翻訳不能時の規則 | #167 §5.5・§5.6 |
| 27 | `SimulationResult` metadata 予約キー・registry 登録要件 | #167 §5.7・§5.8（統合後の一覧は [統合設計](../architecture/capex_credit_cycle_integration.md) §6.1） |
| 28 | `ModelCapabilityProfile` の値 | #167 §2.6 |
| 29 | イベントの 4 層分離・共通属性・単位語彙 | #168 [イベント変換契約](../architecture/macro_event_contract.md) §2・§3 |
| 30 | イベント適用先（外生 7 変数）・イベント型 9 種のマッピング | #168 §4.1・§4.2 |
| 31 | 合成規則（固定順・全順序）・`target_rank` | #168 §5.1・§5.2 |
| 32 | 制約違反の拒否・`event_set_hash` による再現契約 | #168 §6・§7 |
| 33 | 四半期の内部時刻表現・期首一括適用・適用四半期の割当規則・時間形状 6 種 | #168 [シナリオ時間軸](../architecture/scenario_time_semantics.md) §3–§5 |
| 34 | 離散時間ハイブリッド・陽解法の選定・循環の遅れ指定 | #169 [動学方程式](capex_credit_cycle_equations.md) §2・§3.3 |
| 35 | 期内処理順序 10 ステップと変数のステップ割当 | #169 §3.1（`price_s` の位置は改訂節） |
| 36 | 全方程式（`E4-01`–`E12-14`） | #169 §4–§12 |
| 37 | パラメータ辞書・許容条件 15 件・遅延パラメータ採用値・状態次元 | #169 §13 |
| 38 | 逆較正 13 ステップ・定常条件 `SS-1`–`SS-17`・助走区間 | #169 §14 |
| 39 | 数値ガード 3 層・ゼロ除算・警告 10 種・`termination_reason` 4 値 | #169 §15 |
| 40 | ループ利得・非線形性 `NL-1`–`NL-7`・`credit-off`・`share_C` | #169 §16 |
| 41 | 観測可能性 5 分類・観測方程式の 9 項目 | #170 [観測方程式・識別戦略・検証方針](capex_credit_cycle_empirical_strategy.md) §3・§4 |
| 42 | 逆較正入力の観測対応・定常水準の算出方式 | #170 §5 |
| 43 | データソース境界 3 層・企業開示の除外 | #170 §6 |
| 44 | パラメータ 6 区分の割当・推定ブロック `EB-1`–`EB-7`・固定順序 | #170 §7 |
| 45 | 識別リスク `ID-1`–`ID-7`・弱識別対応 `W1`–`W4` | #170 §8 |
| 46 | 履歴再生の必要条件 `NC-1`–`NC-7`・候補 `H1`–`H6` | #170 §9 |
| 47 | 検証 4 レイヤー・出力契約 | #170 §10 |
| 48 | 因果・予測上の限界 14 件 | #170 §11 |
| 49 | ファイル配置・include 順序・export・registry 登録 | [統合設計](../architecture/capex_credit_cycle_integration.md) §3 |
| 50 | 公開 API のシグネチャと契約・内部型 | 同 §4・§5 |
| 51 | `SimulationResult`・metadata 出力契約 | 同 §6 |
| 52 | テスト戦略・fixture | 同 §7 |
| 53 | 統合デモの入力・出力・注意事項 | 同 §8 |
| 54 | 実装作業の分解 `I-1`–`I-8` | 同 §9 |
| 55 | 文書間の不一致とその解決（`X-01`–`X-32`） | 同 §2 |
| 56 | 名称（`Digital Twin` / `Digital Shadow`）の使用条件 | [ADR 0014](../adr/0014-digital-twin-naming-conditions.md) |

---

## 2. 分析目的と対象外

### 2.1 何を問うか

AI・クラウド事業者の CAPEX 見直しが、半導体・製造装置・建設・電力、信用市場、家計部門へ波及する過程について、**産業内調整にとどまる場合と広範な景気悪化へ発展する場合の条件**を比較する。

| ID | 判定問題 | 単一実行で回答可能か | 必要な実行構成 |
|---|---|---|---|
| `Q1` | CAPEX 調整が関連産業内の在庫・稼働率調整で収束する条件は何か | 不可 | スイープ（収束領域の境界） |
| `Q2` | 信用スプレッド・借換条件・貸出態度が悪化し、投資削減を増幅する条件は何か | 部分的 | 反実仮想対（`credit-off`）+ 弾性スイープ |
| `Q3` | 雇用・所得・消費を通じ、一般経済へ波及する条件は何か | 可 | `Sc2` または `Sc3` の単一実行 + 寄与分解（追加 1 実行） |
| `Q4` | 金融緩和または需要回復により波及が遮断される条件は何か | 部分的 | `Sc3` / `Sc4` 対 + 規模 × 遅延スイープ |
| `Q5` | 同じ初期ショックでも経路が分岐する非線形性・閾値をどの変数で確認するか | 不可 | 1 次元スイープ × 5 変数 |

### 2.2 対象外（初期MVP）

個別企業の株価予測／景気後退確率の一点推定／数千社規模の ABM／世界全体の国際波及／AI 技術進歩そのものの内生化／投資推奨・自動売買／非公開企業・銀行データを前提とした較正（#163 §6）。

**位置づけ**: 本モデルは「特定の仮定下での条件付きシミュレーション」であり、経済の予測ツールではない。`Digital Twin` / `Digital Shadow` と呼ばない（[ADR 0014](../adr/0014-digital-twin-naming-conditions.md)）。

---

## 3. 部門と経済的責務

| 部門 | 何を意思決定するか | 実物フローの相手 | 金融フローの相手 |
|---|---|---|---|
| `S1` AI・クラウド需要 | 期待需要 `compute_dem`・目標設備 `target_cap_s1`・計画CAPEX・延期 `capex_defer_s1`・産出 `y_s1`・雇用 `emp_s1` | 買: `S2`・`S3`（資本財）・`SX`（中間投入・モデル外資本財）／売: `S5`（`cons_s1`）・`SX`（`xsales_s1`） | `S4`（与信・利払い・返済・預金）・`SX`（配当・法人税） |
| `S2` 半導体設計・製造 | 価格 `price_s2`・産出 `y_s2`・出荷 `ship_s2`・投資 `invest_s2`・雇用 `emp_s2` | 買: `S3`（装置）・`SX`／売: `S1`・`S5`・`SX` | 同上 |
| `S3` 装置・建設・電力 | `S2` と同型（`price_s3`・`y_s3`・`invest_s3`・`emp_s3`）。`L44` により CAPEX 実行に直接反応する建設・据付雇用を持つ | 買: `SX`（自部門投資は全額 `SX` から）／売: `S1`・`S2`・`S5`・`SX` | 同上 |
| `S4` 金融・信用 | スプレッド `spread`・貸出態度 `lend_stance`・借換 `rollover`・資本コスト `cost_capital_s`・株式評価 `equity_val`・担保 `collateral`・金融環境 `fin_cond` | なし | `SF` 各部門（与信 `loans_s4`・預金 `dep_stock_s4`）・`SX`（モデル外調達 `fund_s4`・純所得の移転） |
| `S5` 家計・一般経済 | 雇用 `emp_s5`・賃金 `wage`・消費 `cons`・産出 `y_s5` | 労働を `SR` へ提供、賃金を受領／買: `S1`・`S2`・`S3`・`SX`／売: `SX`（`xdem_s5`） | なし（家計信用は `EXT`）。閉じ変数は `s5_net_sx`（`C-12`） |
| `SX` モデル外・残差 | なし（**会計部門であって経済部門ではない**） | 全部門と（中間投入・モデル外資本財・モデル外需要） | `S4`（`fund_s4`）・`SF`（増資 `≡ 0`）・税・配当 |

**`SX` の規律**: `SR`（`breadth` の分母）に含めない。`SimulationResult` へ `SX` の産出・雇用を出力しない。`SX` 列の列和は自明にゼロなので会計検証の対象にしない（#166 §3.2）。

**部門横断の単一系列**（部門接尾辞を付けない）: `equity_val`・`collateral`・`spread`・`rollover`・`lend_stance`・`fin_cond`・`policy_rate`・`wage`・`cons`・`coverage_agg`・`spread_endo`・`emp_tot`・`hh_income`・`y_tot`・`tax_hh`・`ai_exp`・`capex_plan_shock_ex`・`spread_shock_ex`。

---

## 4. 状態・制御・外生・観測・診断変数

### 4.1 役割の判定規則

| 規則 | 内容 |
|---|---|
| 1 | 生成する式が無い（`T(x) = ∅`）→ `exogenous` |
| 2 | 期首値を参照して更新される残高 → `state` |
| 3 | 行動方程式で当期に決定される → `control` |
| 4 | 当期の他変数から一意に定まる（定義式・恒等式） → `diagnostic` |
| 5 | 会計項目のうち当期の他変数から一意に定まるもの、および MVP で恒等的ゼロと固定されるものは `diagnostic`。ただし資金制約の閉じ変数（`capex_defer_s1`）は `control` |

規則 5 は本統合で追加した（[統合設計](../architecture/capex_credit_cycle_integration.md) §2.2 `X-03`）。

### 4.2 `state`（22 変数 + 遅延バッファ 43 スロット = 状態次元 65）

| 部門 | 変数 |
|---|---|
| `S1` | `cap_s1`・`capex_pipe_s1`・`cash_s1`・`plan_carry_s1`・`debt_s1`・`r_eff_s1` |
| `S2`・`S3` | `cap_s`・`capex_pipe_s`・`backlog_s`・`inv_s`・`cash_s`・`debt_s`・`r_eff_s`（各 2 変数）・`advance_s`（優先度 `EXT`、MVP `≡ 0`。恒等的ゼロの独立項として保持） |

**遅延バッファ**: 深さ 1 が 34 本（`capex_exec_s1`・`capex_plan_s1`・`ocf_s`×3・`profit_s`×3・`int_burden_s`×3・`tax_s`×3・`sales_s`×3・`cost_capital_s`×3・`coverage_agg`・`fin_cond`・`spread`・`equity_val`・`lend_stance`・`y_s1`・`y_s2`・`y_s3`・`y_s5`・`util_s2`・`util_s3`・`inv_ratio_s2`・`inv_ratio_s3`・`cons`）、深さ 3 が 3 本（`price_s2`・`price_s3`・`emp_tot`）= 9 スロット。#169 `1.0.0` §13.5 は深さ 1 を 34 本と宣言しながら列挙は `invest_s2` を含む 35 本であった。`order_inv_s3` が当期 `invest_s2` を参照する改訂（#169 §21.2）により `invest_s2` が不要になり、列挙と宣言がともに 34 本で一致する。状態次元は 65 のまま変わらない。`state_variables(m)` に含める（#165 §6.1）。

### 4.3 `exogenous`（7 変数。イベント適用先の全体）

順序は #168 §4.1 が正本であり、これが `target_rank` を定義する。

| # | Julia 名 | 型 | 単位（モデル内） | baseline 値 | `application_mode` |
|---|---|---|---|---|---|
| 1 | `:ai_exp` | index | 無次元 | `1.0` | `:multiplicative` |
| 2 | `:capex_plan_shock_ex` | index | 無次元**乗数** | `1.0` | `:multiplicative` |
| 3 | `:spread_shock_ex` | rate | bp | `0.0` | `:additive` |
| 4 | `:policy_rate` | rate | 年率 % | `st_pol_ref` | `:additive` / `:absolute` |
| 5 | `:ext_demand_s2` | flow | 10億ドル/四半期 | `st_extdem_s2` | `:multiplicative` / `:additive` / `:absolute` |
| 6 | `:ext_demand_s3` | flow | 10億ドル/四半期 | `st_extdem_s3` | 同上 |
| 7 | `:price_s1` | index | 無次元 | `1.0` | `:multiplicative` |

**単位の注意**: `capex_plan_shock_ex` の #165 §5.2 の単位欄「baseline比 %」は**イベント側の magnitude の単位**であり、モデル内変数の単位ではない。モデル内は baseline `1.0` の無次元乗数であり、`-15%` のイベントは `capex_plan_shock_ex = 0.85` として渡る（#169 §4.2）。

### 4.4 `control` と `diagnostic`

`control` は各部門が当期に決定する量（`compute_dem`・`target_cap_s1`・`capex_plan_s1`・`capex_exec_s1`・`cancel_s1`・`capex_defer_s1`・`y_s`・`ship_s`・`price_s`・`invest_s`・`emp_s`・`equity_val`・`collateral`・`spread`・`rollover`・`lend_stance`・`fin_cond`・`cost_capital_s`・`wage`・`cons`・`y_s5` 等）、`diagnostic` は恒等式・定義式のみで決まる量（`ycap_s`・`util_s`・`sales_s`・`va_s`・`im_s`・`profit_s`・`ocf_s`・`wagebill_s`・`dep_s`・`matur_s`・`repay_s`・`refin_s`・`int_burden_s`・`coverage_s`・`leverage_s`・`nlb_s`・`nw_s`・`invval_s`・`s5_net_sx`・`hh_income`・`y_tot`・`emp_tot` 等）である。

完全な列挙と単位・時点基準は #165 §5 が正本。実装は `SimulationResult.variables` のキー集合が #165 §5 の優先度 `必須` の集合と一致することをテストで保証する（[統合設計](../architecture/capex_credit_cycle_integration.md) §7.1-2）。

### 4.5 観測可能性 5 分類

| 分類 | 意味 | 主な変数 |
|---|---|---|
| `D` | 直接観測可能 | `y_tot`・`emp_tot`・`spread`・`policy_rate`・`lend_stance`・`fin_cond`・`util_s2`・`util_s3`・`backlog_s`・`inv_s`・`ship_s`・`price_s` |
| `C` | 複数系列から構成可能 | `y_s`（指数変化率 + BEA 水準）・`capex_exec_s1`・`va_s` |
| `P` | proxy でのみ観測可能（ずれの方向の記載が必須） | `invest_s`・`debt_s`・`int_burden_s`・`hh_income`・`cons`・`ycap_s` |
| `E` | 潜在（推定が必要） | `cost_capital_s`・`target_cap_s1`・`cancel_s1`・`collateral`・`capex_pipe_s` |
| `A` | 観測不能・シナリオ仮定のみ | `ai_exp`・`xdem_s5`・`st_maturity_s`・企業開示依存の `S1` 収益ブロック |

`P` 分類の水準 RMSE を fit の根拠として提示しない。`E` / `A` について fit を計算しない（#170 §10.2）。潜在変数は `SimulationResult.variables` へ出力するが単独の水準を提示しない（#165 §5.4）。

---

## 5. 貸借対照表・取引フロー・残高更新

### 5.1 instrument（8 種）

| ID | 内容 | 金融資産か | 発行（負債） | 保有（資産） | MVP |
|---|---|---|---|---|---|
| `:capital` | 稼働資本ストック `cap_s` | いいえ | — | `SF` | 必須 |
| `:cip` | 建設中資本 `capex_pipe_s` | いいえ | — | `SF` | 必須 |
| `:inventory` | 在庫 `invval_s` | いいえ | — | `SP` | 必須 |
| `:deposit` | 現金・預金 `cash_s` | はい | `S4` | `SF` | 必須 |
| `:loan` | 貸出・社債 `debt_s` | はい | `SF` | `S4` | 必須 |
| `:advance` | 前受金・前渡金 `advance_s` | はい | `SP` | `S1`・`S2` | MVP `≡ 0` |
| `:extfund` | `S4` のモデル外調達 `fund_s4` | はい | `S4` | `SX` | 必須 |
| `:equity` | 株式（簿価） | はい | — | — | `EXT` |

金融商品行（`deposit`・`loan`・`advance`・`extfund`）の行和 = 0。実物資産行の行和 ≠ 0（対応する負債が存在しないため検証対象外）。純資産行を含めた列和 = 0。`S5` 列は全行ゼロ（家計は金融資産・負債を持たない）。`nw_s4 ≡ 0`。

### 5.2 取引フロー（経常・資本 12 行 + 金融 7 行）

符号規約: `+` = 資金の源泉（受取）、`−` = 資金の使途（支払）。経常・資本ブロックの列和 = `nlb_s`、金融ブロックの列和 = `−nlb_s`、合計 0（部門予算制約）。

| ブロック | 行 |
|---|---|
| 経常・資本 | `C-01` `S1` 産出の処分／`C-02` `S2` 産出の処分／`C-03` `S3` 産出の処分／`C-04` `S5` 産出の処分／`C-05` モデル外からの中間投入・資本財購入／`C-06` 賃金／`C-07` 家計税・移転／`C-08` 法人税（`≡ 0`）／`C-09` 利払い／`C-10` 金融部門純所得のモデル外移転／`C-11` 配当・株主還元／`C-12` `S5` のモデル外への純移転 |
| 金融 | `F-01` 現金・預金の増減／`F-02` 新規借入・社債発行／`F-03` 元本返済（純）／`F-04` 貸倒償却（`≡ 0`）／`F-05` 前受金・前渡金の増減（`≡ 0`）／`F-06` 増資・外部資本（`≡ 0`）／`F-07` `S4` のモデル外調達 |

借換 `refin_s` は満期到来額の置換であり現金の出入りを伴わないため**行列に計上しない**。計上するのは純額（`newdebt_s`・`repay_s = matur_s − refin_s`）のみ。減価償却は取引ではないため行を持たない。

### 5.3 主要な残高更新式

```
cap_s        = cap_s[t−1] + capstart_s − dep_s − retire_s
capex_pipe_s = capex_pipe_s[t−1] + I_s − capstart_s − pipe_cancel_s
inv_s        = inv_s[t−1] + y_s − ship_s
invval_s     = price_s · inv_s
backlog_s    = backlog_s[t−1] + demand_s − ship_s
cash_s       = cash_s[t−1] + ocf_s − int_burden_s − tax_s − div_s − repay_s − I_s + newdebt_s + equity_issue_s
debt_s       = debt_s[t−1] + newdebt_s − repay_s − writeoff_s
plan_carry_s1= plan_carry_s1[t−1] + capex_defer_s1 − revive_s1
nw_s         = cap_s + capex_pipe_s + invval_s + cash_s − debt_s
loans_s4     = Σ_{s∈SF} debt_s ;  dep_stock_s4 = Σ_{s∈SF} cash_s ;  fund_s4 = loans_s4 − dep_stock_s4
```

**在庫の評価**: 当期価格で評価する（`invval_s = price_s · inv_s`）。価格変動による評価差額を `valchg_s = (price_s − price_s[t−1]) · inv_s[t−1]` として計上し、`Δinvval_s = dinv_s + valchg_s` が恒等的に成立する。これにより `:stock_flow` と `:net_worth_update` が定常状態外でも成立する（[統合設計](../architecture/capex_credit_cycle_integration.md) §2.2 `X-14`）。定常状態では `price_s` が一定であるため `valchg_s = 0`。

### 5.4 CAPEX 資金調達恒等式と閉じ変数

```
恒等式 1: capex_plan_eff_s1 = capex_exec_s1 + capex_cancel_s1 + capex_defer_s1
          capex_plan_eff_s1 = capex_plan_s1 + revive_s1,  revive_s1 = bh_revive_s1 · plan_carry_s1[t−1]
恒等式 2: capex_exec_s1 + div_s1 + tax_s1 + int_burden_s1 + repay_s1 + Δcash_s1
          = ocf_s1 + newdebt_s1 + equity_issue_s1
```

**閉じ変数は `capex_defer_s1`（1 本）**。`capex_cancel_s1` はステップ 3（計画）で `cancel_s1 · capex_plan_eff_s1` として確定し、資金源に依存しない。資金余剰は `Δcash_s1` へ。契約確定額（`st_commit_s1`）が資金源を上回り延期しきれない場合、超過は `newdebt_s` に現れ `funding_forced_s > 0` として構造化記録する（自動的に消さない）。

**株価の作用経路**（直接エッジを置かない。媒介は 3 経路のみ）: (a) `equity_val → cost_capital_s → capex_plan_s1`（恒等式 1 の左辺）、(b) `equity_val → collateral → rollover → repay_s`（恒等式 2 の左辺）、(c) `→ capex_defer_s1`（恒等式 1 の閉じ変数）。増資（`equity_issue_s ≡ 0`）と純資産の評価損には**作用しない**。

### 5.5 会計恒等式検証（12 項目）

| # | 検証名 | 内容 | 再利用 |
|---|---|---|---|
| 1 | `:balance_row_sum` | 金融商品行の行和 = 0 | 既存 |
| 2 | `:balance_column_sum` | 純資産行を含めた部門列の列和 = 0 | 既存 |
| 3 | `:flow_row_sum` | 取引フロー行の行和 = 0 | 既存 |
| 4 | `:flow_column_sum` | 部門列の列和 = 0（部門予算制約） | 既存 |
| 5 | `:stock_flow` | `stock_t − stock_{t−1} = flow_t + valuation_t` | 既存 |
| 6 | `:nlb_consistency` | 経常・資本ブロック列和 = −（金融ブロック列和）= `nlb_s` | 新規 |
| 7 | `:net_worth_update` | 純資産の左辺（資産−負債）と右辺（フロー構成）の一致 | 新規 |
| 8 | `:capex_funding` | 恒等式 1・2 | 新規 |
| 9 | `:s4_balance_sheet` | `loans_s4 = Σ debt_s` かつ `dep_stock_s4 = Σ cash_s` | 新規 |
| 10 | `:output_income_split` | `va_s = wagebill_s + dep_s + profit_s` かつ `va_s = sales_s − im_s` | 新規 |
| 11 | `:aggregate_output` | `y_tot = Σ_{s∈SF} va_s + y_s5` | 新規 |
| 12 | `:no_double_count` | `capex_exec_s1 = d_{S1,S2} + d_{S1,S3} + capex_sx_s1`、`invest_s2 = d_{S2,S3} + inv_sx_s2`、`invest_s3 = inv_sx_s3`、`Σ_b d_{b,s} + dinv_s = sales_s` | 新規 |

許容誤差 `abs(residual) ≤ atol + rtol · scale`（`atol = 1e-8`・`rtol = 1e-6`）。自動補正しない。`NaN` / `Inf` は `acc_invalid` として `acc_fail` と区別する。検証対象外は `SX` 列・`S4` 列の列和、実物資産行の行和、`nlb_s5 ≡ 0`（代わりに `abs(s5_net_sx) / y_tot > 0.05` を `acc_warning` として監視）。

---

## 6. 行動方程式と期内処理順序

### 6.1 期内処理順序（10 ステップ）

| # | ステップ | 決まる主な量 | 参照する時点 |
|---|---|---|---|
| 1 | 外生入力の適用 | 外生 7 変数（期首一括適用） | — |
| 2 | 金融条件の決定 | `fin_cond`・`spread`・`spread_endo`・`lend_stance`・`equity_val`・`collateral`・`rollover`・`cost_capital_s`・`r_eff_s`・`matur_s`・`refin_s`・`repay_s`・`int_burden_s` | 期首ストック・前期内生値 |
| 3 | 計画 | `compute_dem`・`target_cap_s1`・`capex_plan_s1`・`revive_s1`・`capex_plan_eff_s1`・`cancel_s1`・`capex_cancel_s1`・`invest_plan_s` | 期首 `cap_s`・`capex_pipe_s`・`plan_carry_s1` |
| 4 | 資金制約と実行 | `tax_s`・`div_s`・`newdebt_max_s`・`capex_fundable_s1`・`capex_defer_s1`・`capex_exec_s1`・`invest_s`・`capex_sx_s1`・`inv_sx_s`・`equity_issue_s`（`≡ 0`） | 期首 `cash_s`・`debt_s`、前期 `ocf_s` |
| 5 | 価格確定と受注配分 | **`price_s`**・`order_cap_s`・`order_inv_s`・`order_gen_s`・`order_s` | `util_s[t−1]`・`price_s[t−1]`、当期 `capex_exec_s1`・`invest_s`、前期 `y_s5` |
| 6 | 生産・出荷 | `ycap_s`・`y_s`・`ship_s`・`deliv_s`・`util_s`・`y_s1`・`ycap_s1`・`unmet_cap_s` | 期首 `cap_s`・`backlog_s`・`inv_s` |
| 7 | 所得・支出 | `emp_s`・`emp_tot`・`wage`・`wagebill_s`・`tax_hh`・`hh_income`・`cons`・`cons_s1`・`cons_s5`・`xdem_s5`・`y_s5` | 当期 `y_s`・`y_s1`・`capex_exec_s1` |
| 8 | 収益・分配 | `sales_s`・`im_s`・`va_s`・`dep_s`・`profit_s`・`margin_s`・`dinv_s`・`ocf_s`・`y_tot`・`coverage_s`・`leverage_s`・`newdebt_s`・`nlb_s`・`s5_net_sx` | 当期フロー、期首 `debt_s` |
| 9 | 残高更新 | `capstart_s`・`cap_s`・`capex_pipe_s`・`inv_s`・`invval_s`・`valchg_s`・`backlog_s`・`cash_s`・`debt_s`・`plan_carry_s1`・`nw_s`・`loans_s4`・`dep_stock_s4`・`fund_s4` | 期首ストック + 当期フロー |
| 10 | 会計検証・診断 | 恒等式 12 項目・診断ラベル・`funding_pressure_s`・ループ利得 | 期首・期末・当期フロー |

**`price_s` の位置**: `price_s` は `util_s[t−1]` と `price_s[t−1]` のみに依存する先決変数であるため、ステップ 5 の冒頭で確定する。これにより `order_cap_s` の除算と `d_{S1,s}` の乗算が同一価格を用い、`:no_double_count` が価格変化時にも成立する（[統合設計](../architecture/capex_credit_cycle_integration.md) §2.2 `X-15`）。参照する時点は変わらないため順序の変更ではない。

### 6.2 期内の規律

- 期内に**同時方程式を置かない**。すべて陽解法で、反復・非線形ソルバを用いない（[ADR 0011](../adr/0011-capex-credit-cycle-dynamics-contract.md)）。
- 循環を断つ遅れは #169 §13.5 が全 12 循環について採用値を列挙しており、**実装者が個別に選ばない**。
- 主体最適化・均衡求解を置かない。すべて行動方程式である。
- 期待に平滑化を重ねない（`ai_exp` は外生、計画は後ろ向きの加速度原理）。
- 意思決定はすべて期首ストックを参照する（`util_s = y_s / ycap_s[t−1]`・`int_burden_s = r_eff_s · Δt · debt_s[t−1]`・`matur_s = φ_s · debt_s[t−1]`）。

### 6.3 増幅ループと遮断経路

| ループ | 経路 | 代表変数 | 作動判定 |
|---|---|---|---|
| `R1a` | `S1` 内部資金 → CAPEX 実行 → `S1` 産出能力 | `capex_exec_s1` | `capacity_binding_s1` が 1 期以上 `true` |
| `R1b` | `SP` の受注・内部資金 → 投資 | `Σ_{s∈SP} y_s` | `supply_binding` または `inv_threshold_binding` |
| `R2` | 利益 → カバレッジ → スプレッド → 資本コスト → 投資 | `Σ_{s∈SF} I_s` | `coverage_agg[t−1] < bh_cov_threshold` |
| `R2` 短絡 | スプレッド → 利払い → カバレッジ → スプレッド（実体を経由しない） | `spread` | `g_short > 1` の期を報告 |
| `R3` | 株式評価 → 担保 → 借換 → 現金・投資延期 | `capex_exec_s1` | `rollover < 1` |
| `R4` | 雇用 → 所得 → 消費 → 一般需要 → 産出 | `cons` | 雇用デッドバンド外 |

遮断経路 `B1`（在庫による出荷制約）・`B2`（資金制約による投資抑制）・`B3`（契約確定分の不可逆性）・`B6`（価格調整）・`B7`（労働退蔵）は T1 経済制約の `binding` フラグとして観測する。

**規律**: ループ利得は状態依存であり単一の値でループを特徴づけない。`ρ_t > 1` を「発散する」と述べない。`gain(loop)` の単純和を合成利得としない（ループがノードを共有するため）。

---

## 7. パラメータ・初期状態・baseline

### 7.1 パラメータの分類（接頭辞）

| 接頭辞 | 内容 | 系統数 | 推定・較正の対象 |
|---|---|---|---|
| `st_` | 構造パラメータ（技術・会計上の係数） | 34 | 較正対象だが行動を表さない |
| `bh_` | 行動パラメータ（主体の意思決定） | 44 | **`bh_` のみが推定対象になりうる** |
| `pl_` | 政策・制度パラメータ | 3 | 制度から与える |

`st_invprice_s2`・`st_invprice_s3` は在庫の当期価格評価への変更により廃止した（35 → 34 系統。§5.3・`X-14`）。

**`parameters` に含めないもの**: 数値解法設定（`CapexCreditCycleOptions`）・診断閾値（`CapexDiagnosticThresholds`）・初期状態（`CapexCreditCycleTargets` 経由）・シナリオショック（`CapexShockSpec`）。

### 7.2 決め方の 6 区分（#170 §7.1）

| 区分 | 定義 |
|---|---|
| `FIX` | 会計恒等式・制度設定・数値下限から固定。観測を用いない |
| `CAL-SS` | 定常水準から逆較正で一意に決まる（自由度なし） |
| `CAL-OBS` | 観測比率・文献値から直接較正 |
| `EST` | 限定的に推定（推定ブロックごと） |
| `SCN` | シナリオ入力として与える |
| `SENS` | 推定・較正せず感応度分析のみ |

各パラメータはちょうど 1 つの区分を持つ。区分と「感応度走査の対象であること」は直交する概念である。`EST` が弱識別と判定された場合の移動先は `W1`–`W4` として**推定前に**割り当てる。

### 7.3 逆較正と baseline

**baseline は成長率ゼロの定常状態**である。定常水準を目標として与え、それを定常状態にする `st_` パラメータを閉形式で逆算する（前向きに非線形ソルバで解かない）。13 ステップの導出順序は #169 §14.2、観測ソースの割当は #170 §5.2 が正本。

`steady_state(m)` は与えられた定常水準を返し、収束判定・反復回数を持たない。`SS-1`–`SS-17` の 17 条件を検証し、違反があれば `simulate` を実行しない。

**助走区間**: `t = -8 … -1` で全変数が定常値から動かないこと。遅延バッファも定常値で初期化する（ゼロで埋めない）。相対乖離が `runup_tol` を超えた期を `runup_deviation` として警告する。

**非自明な定常条件 `SS-14`**: 成長率ゼロの定常状態では資本ストックが一定で投資は減価償却で賄われるため、内部留保はゼロでなければならない。したがって `st_payout_s = 1`（利払い・納税後の利益を全額分配）。許容条件 12 として実装時に検査する。

---

## 8. シナリオ入力とイベント適用点

### 8.1 シナリオ（入れ子契約 `Sc1 ⊂ Sc2 ⊂ Sc3 ⊂ Sc4`）

| ID | 名称 | 含む起点事象 |
|---|---|---|
| `Sc0` | `baseline` | — |
| `Sc1` | `expectation_only` | `E1`（AI 需要期待の下方修正） |
| `Sc2` | `expectation_capex` | `E1` + `E2`（CAPEX 計画削減） |
| `Sc3` | `capex_credit` | 上記 + 信用ショック |
| `Sc4` | `capex_credit_easing` | 上記 + 金融緩和 |

下位シナリオのショックは上位でも**同一の意味・単位・時点・持続期間・規模**で適用する。入れ子性が破れる変更は禁止（必要な場合は別 ID として追加）。

### 8.2 ショック 4 種（暫定既定値）

| ショック | `target` | `unit` | `sign` | `timing` | `shape` | `duration` | 暫定規模 |
|---|---|---|---|---|---|---|---|
| `SH-EXP` | `ai_exp` | baseline 比 % | 負 | `t = 0` | `AR1_decay`（半減期 6Q） | 恒久（減衰） | `-10%` |
| `SH-CAPEX` | `capex_plan_shock_ex` | baseline 比 % | 負 | `t = 0` | `step` → 4Q 後から `ramp` で解消 | 8Q | `-15%` |
| `SH-CREDIT` | `spread_shock_ex` | bp | 正 | `t = 1` | `AR1_decay`（半減期 4Q） | 恒久（減衰） | `+150bp` |
| `SH-EASING` | `policy_rate` | %pt | 負 | `t = 2` | `step` | 8Q | `-100bp` |

規模は**暫定既定値**であり観測から較正した値ではない。`ai_exp` は `A` 分類（観測不能）であるため `SH-EXP` の規模を較正できず、走査結果として提示する。

### 8.3 イベント層との境界

| 層 | 責務 |
|---|---|
| 観測イベント | 何が公表されたか（`L1`）。`economic-data-provider` の責務 |
| 解釈シグナル | belief・仮説。`finance-checker` の責務。**belief を直接モデル入力へ変換しない** |
| シナリオ仮定 | `CapexShockSpec`（#163 §5.2 の 7 項目 + `application_mode` + `magnitude`） |
| 適用モデル入力 | 外生 7 変数の合成済み四半期パス。**モデル層が受け取るのはこれのみ** |

**規律**: 適用先を外生 7 変数に限定し、適用先の無いイベントを近似で寄せない。期首一括適用のみ（期中適用・期内按分を行わない）。合成は絶対 → 乗算 → 加算の固定順で行い順序依存を排除する。magnitude を捏造しない。制約違反を自動クリップせず拒否する。

---

## 9. 数値制約・発散・終了契約

### 9.1 3 層の分離

| 層 | 名称 | 扱い | 記録 |
|---|---|---|---|
| `T1` | 経済制約（関数形の一部としての上下限・飽和） | 式に組み込む | `binding` フラグ（23 種）。**警告ではない** |
| `T2` | 制約違反（符号・範囲制約の違反） | **クリップしない**。値を保持して続行 | `:sign_constraint` として構造化記録。**モデルの誤り**として扱う |
| `T3` | 数値ガード（非有限値・発散） | 当該期以降を invalid として打ち切る | `termination_reason` / `termination_period` |

`T1` は clamp ではない（`max(capex_plan_s1, 0)` は経済的な事実）。`T2` を自動補正しない。`T2` を `T3` へ読み替えない。`T3` でも**例外を投げない**。

### 9.2 ゼロ除算

`|b| ≤ div_eps`（既定 `1e-8`）のとき結果を `NaN` とし、当該診断量を `*_invalid` として記録する。例外を投げない、`0` で代替しない、分母を `max(b, eps)` へ置き換えない。**`NaN` の伝播を止めるのは 4 箇所のみ**（`E5-04` の閾値項・`E6-08` の分母・`E9-07` の減産項・`E11-19` の配分）。実装がこれを追加しない。

### 9.3 警告（10 種）と終了理由（4 値）

警告: `runup_deviation`・`a2_violation`・`funding_forced`・`liquidity_gap`・`cash_below_min`・`threshold_proximity`・`extreme_shock`・`acc_warning` / `acc_fail` / `acc_invalid`・`sign_constraint`・`ss_inconsistent`。`metadata["warnings"]` へ `(code, period, sector, detail)` の構造化配列として格納する。

終了理由: `:completed`・`:non_finite_state`・`:divergence_guard`・`:sign_constraint_fatal`（既定では停止しない）。

### 9.4 診断ラベルと非線形性

| ラベル | 条件 |
|---|---|
| `contained_adjustment` | `Q1` の (a)–(d) をすべて満たす |
| `sectoral_downturn` | `G2` が持続的に閾値超、かつ `broad_downturn` でない |
| `broad_downturn` | `G1` が持続的に閾値超 かつ 4 群中 3 群以上が持続的に閾値超 かつ `breadth ≥ 0.60` |
| `indeterminate` | 上記のいずれにも該当しない、または判定に必要な系列が欠落 |

単一四半期のマイナス成長のみで景気悪化と判定しない。`recession` をラベル名・変数名・出力フィールド名に用いない。`indeterminate` を `broad_downturn` へ寄せない。`breadth` は 0.25 刻みの離散値しか取らない（実体部門 4）。

非線形性は `NL-1`（キャンセル閾値）・`NL-2`（在庫閾値での減産）・`NL-3`（カバレッジ閾値でのスプレッド急拡大）・`NL-4`（LTV 上限での借換悪化）・`NL-5`（借換閾値での投資延期）・`NL-6`（労働退蔵デッドバンド）・`NL-7`（能力・在庫上限の飽和）の 7 箇所。近傍（`prox_band` 既定 `0.10`）では `threshold_proximity` を記録し、当該閾値 ±50% のラベルを併記する。

---

## 10. 観測方程式・識別・検証・限界

### 10.1 観測方程式

系列名マッピングとして扱わず、9 項目（`model_var`・`series`・`level_form`・`unit_conversion`・`sector_scope`・`published_basis`・`aggregation`・`methodology`・`vintage`）を備えた変換契約として定義する。指数系列を水準として使う場合はアンカー方式を必ず記載する。`aggregation` / `allocation` / `proxy` を区別し、`allocation` は按分キーの感応度なしに、`proxy` はずれの方向の記載なしに用いない。NIPA の年率表示（SAAR）を四半期合計として使わない。`:as_of` を実装せず、「その時点で判断できた」という主張を行わない。

### 10.2 データソース境界（3 層）

| 層 | 責務 |
|---|---|
| DME 既存 FRED / e-Stat 接続 | FRED から取得できる 13 系列 |
| `economic-data-provider` | Census M3・BEA GDP by Industry・BEA 固定資産・Census 建設支出・BEA NIPA・FRB Z.1・BLS PPI/CES・セクター株価指数 |
| 企業データ provider | **初期MVPでは接続しない**（企業開示を較正入力に用いない） |

provider が返せない場合は代替 proxy へ黙って切り替えず、当該変数を欠損として扱い、その変数を必要とする推定ブロックを実行しない。

### 10.3 識別と推定

推定ブロック `EB-1`（金融条件）→ `EB-3`（生産・在庫・受注残）→ `EB-4`（価格）→ `EB-6`（雇用・賃金）→ `EB-7`（消費）→ `EB-5`（CAPEX・投資）→ `EB-2`（資本コスト・評価・担保）の**固定順序**で推定する。観測が最も揃うブロックを先に、識別が弱いブロックを後に置く。逆順で推定しない。

objective は**方程式別残差**（trajectory matching を初版に採らない）。標準誤差を報告しない。弱識別の対応（`W1` 固定へ降格 / `W2` 範囲報告 / `W3` 複数仕様併記 / `W4` 感応度のみ）は推定前に割り当てる。`bh_alpha_capex_s1` と `bh_cc_elas_s1` を同時推定しない。

識別リスク `ID-1`（CAPEX 調整速度と期待）・`ID-2`（スプレッド効果と営業CF効果）・`ID-3`（需要減少と能力過剰）・`ID-4`（稼働率と在庫調整）・`ID-5`（雇用乗数と消費性向）・`ID-6`（政策反応と自然回復）・`ID-7`（同時性・逆因果・共通ショック）。

### 10.4 検証（4 レイヤー。単一スコアへ集約しない）

| レイヤー | 問い |
|---|---|
| 数値fit | 系列の水準・変動がどれだけ合うか（`D` / `C` 分類に限る） |
| 動学・構造 | 波及の順序・遅れ・形が合うか |
| 比較 | 仕様・proxy・標本・イベント写像を変えて結論が変わるか |
| 数値解法頑健性 | 結果が数値設定の産物でないか |

履歴再生の候補は `NC-1`–`NC-7` の必要条件を**先に固定**して選ぶ（fit の良い期間を事後選択しない）。候補は `H1`（2000–2003）・`H2`（2008Q3–2010）・`H3`（2011–2012）・`H4`（2015–2016）・`H5`（2018Q4–2019）・`H6`（2022Q3–2023）。AI・データセンター CAPEX 局面（2023 以降）を履歴再生に用いない。`Q4` を履歴再生から行わない。

### 10.5 限界

因果・予測上の限界 14 件（#170 §11）・会計上の限界 10 件（#166 §12）・動学上の必須記載 8 項目（#169 §18）を LLM 説明層で併記する。特に:

- 当てはまりは因果妥当性を保証しない。シナリオ結果は景気後退確率ではない。
- `A`（増幅度）と `share_C`（消費経路の寄与シェア）は同一実装内の反実仮想寄与であり因果推定ではない。
- `funding_pressure_s` は倒産・信用イベントの予測ではない（デフォルトを内生化していない）。Keen の `hedge` / `speculative` / `ponzi` と同一視しない。
- 会計は `SX` を置いて閉じており、経済全体で閉じていない。「SFC 検証済み」と同じ意味で述べない。
- 出力はすべて baseline 比の乖離であり、水準の絶対値は較正済みの実額を意味しない。

---

## 11. 横断辞書（記号・Julia 名・単位・時間基準の一致確認）

### 11.1 単位の語彙（全文書共通）

| 単位 | 用途 | 時点基準 |
|---|---|---|
| 10億ドル（2017年連鎖ドル） | ストック（`cap_s`・`capex_pipe_s`・`inv_s`・`invval_s`・`cash_s`・`debt_s`・`collateral`・`plan_carry_s1`・`nw_s`・`loans_s4`・`dep_stock_s4`・`fund_s4`・`backlog_s`・`advance_s`） | `EOP`（期末） |
| 10億ドル/四半期 | フロー（産出・売上・付加価値・投資・CAPEX・利払い・賃金支払・消費・所得・受注・出荷・在庫品増加） | `SUM`（四半期合計。**年率換算しない**） |
| 無次元指数（baseline 定常値 = `1.0`） | `ai_exp`・`price_s1`・`price_s`・`wage`・`equity_val`・`rollover`・`capex_plan_shock_ex` | `AVG` |
| 標準化指数 | `lend_stance`・`fin_cond` | `AVG` |
| 比率（無次元） | `util_s`・`inv_ratio_s`・`backlog_ratio_s`・`cancel_s1`・`leverage_s`・`margin_s`・`breadth` | `AVG`（`leverage_s`・`inv_ratio_s`・`backlog_ratio_s` は `EOP`） |
| 倍 | `coverage_s`・`coverage_agg`・`dsc_s` | `AVG` |
| bp | `spread`・`spread_endo`・`spread_shock_ex` | `AVG` |
| 年率 % | `policy_rate`・`cost_capital_s` | `AVG` |
| 年率・小数 | `r_eff_s` | `AVG` |
| 百万人 | `emp_s`・`emp_tot` | `AVG` |
| 四半期 | `st_cor_s`・`st_pipelag_s`・`backlog_ratio_s`・`inv_ratio_s` の分子分母比 | — |
| 年 | `st_maturity_s` | — |

### 11.2 単位換算（実装で明示し metadata へ記録する）

```
bp → %pt          : spread / 100                （100bp = 1%pt）
年率 % → 小数      : r / 100
年率 → 四半期      : r · Δt                      （Δt = 0.25。単利換算。複利換算 (1+r)^0.25 − 1 を用いない）
満期到来率         : φ_s = Δt / st_maturity_s     （st_maturity_s は年）
新規調達金利       : r_new_s = (policy_rate + spread / 100) / 100   … 年率・小数
四半期利払い       : int_burden_s = r_eff_s · Δt · debt_s[t−1]      … 10億ドル/四半期
```

**契約**: `spread`（bp）・`policy_rate`（年率 %）・`cost_capital_s`（年率 %）・`r_eff_s`（年率・小数）は**単位が異なる**。加算する箇所で必ず換算を明示し、換算せずに加算しない。`cost_capital_s` は四半期換算しない。

### 11.3 命名規則

| 規則 | 内容 |
|---|---|
| 基本形 | 小文字 snake_case。`Symbol`（Julia 名）と `String`（`SimulationResult` キー）は同一綴り |
| 部門接尾辞 | `_s1`–`_s5`。部門横断の単一系列は接尾辞を付けない |
| 全部門合計 | `_tot`（`emp_tot`・`y_tot`） |
| 集約値 | `_agg`（`coverage_agg`）。合計（`_tot`）と加重平均（`_agg`）を区別する |
| 比率 | `_ratio`（`inv_ratio_s2`・`backlog_ratio_s2`）。比率と残高を必ず別名にする |
| 外生シフト項 | `_shock_ex`（`spread_shock_ex`・`capex_plan_shock_ex`） |
| 遅延バッファ | `_lag<k>`（`price_s2_lag2`） |
| パラメータ | `st_` / `bh_` / `pl_` 接頭辞 |
| 予約接頭辞（モデルは使わない） | `d_`（baseline 比乖離。比較層が生成） |
| 禁止 | `recession` を含む名前 |

### 11.4 記号衝突の解消（本統合で確定）

| 記号 | 衝突 | 確定した Julia 名 |
|---|---|---|
| `DEP_s` / `DEP_S4` | 固定資本減耗と `S4` の預金負債 | 減耗 = `:dep_s1`–`:dep_s3`、`S4` 預金 = **`:dep_stock_s4`** |
| `SALES_S5` | #166 が用いたが未登録。`S5` は価格変数を持たない | **`sales_s5` を作らず `y_s5` を用いる** |
| `CAP_s` | 資本ストックと生産能力 | 資本ストック（10億ドル）= `:cap_s`、生産能力（10億ドル/四半期）= `:ycap_s = cap_s / st_cor_s` |
| `SALES_s` | 産出額と引渡額 | 産出額 = `:sales_s = price_s · y_s`、引渡額 = `:deliv_s = price_s · ship_s` |
| `r` | 3 種の金利 | `:policy_rate`（年率 %）・`:cost_capital_s`（年率 %）・`:r_eff_s`（年率・小数）。**モデル内でも同一視しない** |

**キー衝突検査**（実装時テスト）: 部門接尾辞を除いた名前が接尾辞なしの単一系列名と衝突しないこと。

### 11.5 他モデルとの同名変数（同一視しない）

| 変数名 | 扱い |
|---|---|
| `d` / `debt` | Keen の `d`（比率・集計経済）と `debt_s`（水準・部門別）を同一視しない |
| `r` | すべて別概念 |
| `Y` | `measure`（level / deviation）が異なるため同一視しない |
| `I` / 投資 | Keen は独立系列として持たない |
| `C` / 消費 | `partial` 止まり |
| Hedge / Speculative / Ponzi | ラベル名を流用しない。同一図に重ねない |
| 会計恒等式の検証結果 | 「SFC 検証済み」と同じ意味で述べない |

**`CCC` と既存 4 モデルの間に `mapping_type = equivalent` は 1 つも存在しない**（#167 §5.2）。数値比較は `mechanism` モードに限る。

---

## 12. 改訂履歴

| version | 日付 | 変更 |
|---|---|---|
| `capex-credit-cycle-design/1.0.0` | 2026-07-30 | 初版。#163〜#170 の統合仕様 index・正典表 56 項目・横断辞書を確定（#171） |

---

## 参考

- [統合設計](../architecture/capex_credit_cycle_integration.md) — 整合レビュー（`X-01`–`X-32`）・実装配置・公開API・出力契約・テスト・デモ・作業分解
- [実証統合設計](../architecture/capex_credit_cycle_empirical_integration.md) — 整合レビュー（`Z-01`–`Z-30`）・7段のデータフロー・実証層の型/API・失敗契約・標本/vintage semantics・48 targetキーの観測対応・履歴再生と検証の構成・作業分解（`P-1`–`P-11`）
- #163 [分析契約](capex_credit_cycle_analysis_contract.md)・#164 [因果グラフ](capex_credit_cycle_causal_graph.md)・#165 [部門境界と変数定義](capex_credit_cycle_sectors_variables.md)・#166 [ストック・フロー会計表](capex_credit_cycle_stock_flow.md)・#167 [責務境界](capex_credit_cycle_model_boundaries.md)
- #168 [イベント変換契約](../architecture/macro_event_contract.md)・[シナリオ時間軸](../architecture/scenario_time_semantics.md)
- #169 [動学方程式](capex_credit_cycle_equations.md)・#170 [観測方程式・識別戦略・検証方針](capex_credit_cycle_empirical_strategy.md)
- [ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md)・[ADR 0010](../adr/0010-macro-event-scenario-contract.md)・[ADR 0011](../adr/0011-capex-credit-cycle-dynamics-contract.md)・[ADR 0012](../adr/0012-capex-credit-cycle-empirical-contract.md)・[ADR 0013](../adr/0013-capex-credit-cycle-integration-contract.md)・[ADR 0014](../adr/0014-digital-twin-naming-conditions.md)・[ADR 0018](../adr/0018-capex-credit-cycle-empirical-runtime-contract.md)
