# 部門別CAPEX・信用循環モデル 統合設計（整合レビュー・実装配置・API・テスト・作業分解）

> 関連 Issue: #171（本書）・#163〜#170（統合対象の設計成果）・#125（ロードマップ）
> 前提: [統合モデル仕様 index](../models/capex_credit_cycle_design.md)（8 文書の正典表・横断辞書）
> 決定記録: [ADR 0013](../adr/0013-capex-credit-cycle-integration-contract.md)（統合実装設計契約）・[ADR 0014](../adr/0014-digital-twin-naming-conditions.md)（名称の使用条件）

---

## メタ情報

| 項目 | 内容 |
|---|---|
| **対象** | 部門別CAPEX・信用循環モデル（`CapexCreditCycleModel`、以下 `CCC`）の DME 内実装配置 |
| **ステータス** | 整合レビュー・実装配置・公開API・出力契約・テスト戦略・デモ仕様・作業分解を確定。Julia 実装は未着手 |
| **integration version** | `capex-credit-cycle-integration/1.0.0` |
| **上位契約** | `capex-credit-cycle-contract/1.0.0`（#163）・`capex-credit-cycle-graph/1.1.0`（#164）・`capex-credit-cycle-vars/1.2.0`（#165）・`capex-credit-cycle-accounting/1.1.0`（#166）・`capex-credit-cycle-boundaries/1.0.0`（#167）・`macro-event-contract/1.0.1`・`scenario-time-semantics/1.0.0`（#168）・`capex-credit-cycle-equations/1.1.0`（#169）・`capex-credit-cycle-empirical/1.1.0`（#170） |
| **継承する横断契約** | `model-capability/1.0.0`（`src/core/model_capabilities.jl`）・`comparison-v2/1.0.0`（`src/core/compare_v2.jl`）・`cross-model-context/1.0.0`（ADR 0006）・`sfc-primitives/1.0.0`・`sfc-accounting/1.0.0`（`src/sfc/`・`src/analysis/sfc_accounting.jl`） |
| **モデル識別子** | 型 `CapexCreditCycleModel`、registry symbol `:capex_credit_cycle`、表示名「部門別CAPEX・信用循環モデル」 |
| **基準経済・頻度** | 米国・四半期（`Δt = 0.25` 年）。助走 8 四半期 + 評価 20 四半期 = 28 四半期 |

> **LLM向け要約**: 本書は #163〜#170 の 8 設計文書を **1 つの実装可能な設計**へ統合する。
> (1) 8 文書を横断して整合レビューを行い、検出した不一致 **31 件**を `X-01`–`X-31` として登録し、
> 各件を「上流文書の改訂」「本書での実装決定」「限界として保持」のいずれかへ**明示的に**割り当てる（§2）。
> 暗黙に吸収した不一致は無い。(2) DME 既存アーキテクチャへの配置を、追加ファイル 5 本・既存ファイル修正 6 本として確定する（§3）。
> (3) 公開 API を 14 関数・内部型 8 個として確定する（§4・§5）。`AbstractMacroModel` の共通 4 関数と
> `steady_state` / `simulate` / `impulse_response` / `to_simulation_result` を実装し、`transition_path` は実装しない。
> (4) `SimulationResult` 型を変更せず、metadata 予約キー **20 個**で methodology 相当を保持する（§6）。
> (5) テストを構造・契約／状態の完全性／会計／動学／数値安全性／診断の 6 分類 **57 項目**として定義する（§7）。
> (6) `Sc0`–`Sc4` の 5 シナリオを外部 API なしで完走する統合デモを定義する（§8）。
> (7) 後続の実装 Issue を 8 件へ分解し、対象ファイル・依存・対象外・受け入れ条件を与える（§9）。
> 本書はモデル層からデータ取得・可視化・LLM 呼び出しを行わない既存原則を維持する。

---

## 1. 本書の位置づけ

### 1.1 何を確定し、何を確定しないか

| 本書が確定するもの | 本書が確定しないもの |
|---|---|
| 8 文書間の不一致とその解決（§2） | 経済的な因果仮説・関数形（#164・#169 が正本） |
| DME 内のファイル配置・include 順序・export（§3） | Julia コードそのもの（後続の実装 Issue） |
| 公開 API のシグネチャと契約（§4） | 実データ系列の取得実装（#170 §6・#125 Phase 3） |
| 内部型・内部関数の責務境界（§5） | イベント型・`run_scenario` の本実装（#125 Phase 2） |
| `SimulationResult` と metadata の出力契約（§6） | パラメータの数値（#170 の較正・推定） |
| テスト戦略と最低テストセット（§7） | 較正結果・検証結果（実データが必要） |
| 統合デモの入力・出力・成果物（§8） | LLM プロンプトの本文（既存 LLM 層の契約に従う） |
| 実装 Issue への作業分解（§9） | — |

### 1.2 本書の規律

1. **不一致を暗黙に吸収しない**。§2 に登録し、解決先を「上流改訂」「本書決定」「限界」のいずれかへ明示する。
2. **上流文書に無い経済的判断を本書で新設しない**。§2 の解決が新しい方程式・単位・遅れを要する場合は、上流文書の改訂として処理し、本書は改訂の事実と根拠のみを記録する。
3. **既存の共通型を変更しない**。`SimulationResult`・`AbstractMacroModel`・`SolverOptions` の既存フィールドを変更せず、追加のみで実装する（[ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md) 決定 8）。
4. **本モデル専用の規約を横断契約へ持ち込まない**。metadata 予約キーは `CCC` の結果にのみ現れ、他モデルへ同じキーを要求しない（#167 §5.7）。
5. **実装者が本書・上流文書に無い遅れ・関数形・単位換算を独自に決めない**（#169 §1.2-7）。必要が生じた場合は該当文書へ差し戻す。

### 1.3 正典（どの事項の正本がどの文書か）

実装時に参照先が曖昧になる事項について、正本を 1 つに固定する。詳細は [統合モデル仕様 index](../models/capex_credit_cycle_design.md) §1。

| 事項 | 正本 |
|---|---|
| 判定問題・シナリオ・診断ラベル・閾値 | #163 [分析契約](../models/capex_credit_cycle_analysis_contract.md) |
| ノード・エッジ・符号・遅れの範囲・増幅ループ | #164 [因果グラフ](../models/capex_credit_cycle_causal_graph.md) |
| 変数の存在・役割・単位・時点基準・命名 | #165 [部門境界と変数定義](../models/capex_credit_cycle_sectors_variables.md) |
| 貸借対照表・取引フロー・残高更新・会計検証項目 | #166 [ストック・フロー会計表](../models/capex_credit_cycle_stock_flow.md) |
| 責務の範囲・横断比較・metadata 予約キー・registry 登録要件 | #167 [責務境界](../models/capex_credit_cycle_model_boundaries.md) |
| イベントの 4 層分離・適用先・合成順序・適用四半期 | #168 [イベント変換契約](macro_event_contract.md)・[シナリオ時間軸](scenario_time_semantics.md) |
| 方程式・遅れの採用値・パラメータ辞書・逆較正・数値ガード・診断算式 | #169 [動学方程式](../models/capex_credit_cycle_equations.md) |
| 観測方程式・パラメータ区分・推定ブロック・検証レイヤー・限界 | #170 [観測方程式・識別戦略・検証方針](../models/capex_credit_cycle_empirical_strategy.md) |
| ファイル配置・API シグネチャ・出力契約・テスト・作業分解 | 本書 |

---

## 2. Phase 0 成果の整合レビュー結果

### 2.1 レビュー範囲と方法

#163〜#170 の 8 文書（6,225 行）について、Issue #171 §1 が挙げた 9 観点を横断照合した。照合は記号名・Julia 名・単位・時点基準・節参照・ID の**逐語一致**で行い、「概ね同じ」を一致とみなしていない。

| # | 観点 | 判定 | 検出件数 |
|---|---|---|---|
| 1 | ユースケースと因果グラフの対応 | 一致 | 0 |
| 2 | 因果ノードと変数辞書の対応 | 不一致あり | 6（`X-01`–`X-06`） |
| 3 | 部門境界と会計表の対応 | 不一致あり | 4（`X-07`–`X-10`） |
| 4 | 会計恒等式と動学方程式の整合 | 不一致あり | 7（`X-11`–`X-17`） |
| 5 | イベント入力と外生変数・状態・制約の対応 | 一致（副次的不一致 2） | 2（`X-18`・`X-19`） |
| 6 | 四半期時間契約と方程式更新順の対応 | 一致 | 0 |
| 7 | パラメータ辞書と固定・較正・推定区分の対応 | 不一致あり | 6（`X-20`–`X-25`） |
| 8 | `SimulationResult` 出力と観測方程式の対応 | 一致（単位 3 件が不一致） | 3（`X-26`–`X-28`） |
| 9 | 既存モデルとの比較可能・比較不能概念の対応 | 一致 | 0 |
| — | 差し戻し事項の状態（`A1`–`A2`・`B1`–`B7`・`E1`–`E6`） | 版ずれあり | 3（`X-29`–`X-31`） |

**一致が確認できた主要事項**（不一致なしと判定した根拠）:

- **イベント適用先の 7 変数**が #165 §4.4・#168 §4.1・#169 `E4-01` で完全一致する（`ai_exp`・`capex_plan_shock_ex`・`spread_shock_ex`・`policy_rate`・`ext_demand_s2`・`ext_demand_s3`・`price_s1`）。#168 §4.2 のイベント型 9 種のマッピングも全てこの 7 個に収まり、適用不可の行の理由が #165 の役割分類と一致する。
- **期内処理順序 10 ステップ**が #166 §2.5・#169 §3.1 で一致する。#169 が `int_burden_s`・`repay_s` の生成をステップ 2 へ前倒しした点は、参照する時点（期首 `debt_s`）が変わらないため順序変更に当たらない。
- **因果ノード 37 個**はすべて #165 §5 に登録されている（欠落なし）。
- **会計検証 12 項目**（#166 §8.1）が #169 `SS-16`・#170 §10.3 で同一項目数・同一参照として引用されている。
- **逆較正 13 ステップ**（#169 §14.2）と #170 §5.2 の観測ソース割当が 1:1 対応し、ステップ 1–12 の入力（定常水準）が完全一致する。
- **パラメータ系統数**が #169 §13.2 の 35 行・§13.3 の 44 行 + 3 行と、#170 §7.2 の「全 35 系統」・§7.4 の「全 44 系統」・§7.3 の 3 系統で一致し、`EB-1`–`EB-7` の合計に欠落・重複がない。
- **`equivalent` が 1 つも存在しない**という #167 §5.2 の確定が、`mapping_type` 導出規則（ADR 0006 §3.2）と矛盾しない。

### 2.2 検出した不一致と解決（`X-01`–`X-31`）

解決先の記号: **[U]** 上流文書の改訂として処理（改訂内容は §2.3 の errata 節に記録）／**[D]** 本書または [ADR 0013](../adr/0013-capex-credit-cycle-integration-contract.md) の実装決定として処理／**[L]** 限界として保持し実装で解決しない。

#### 観点 2: 因果ノードと変数辞書

| ID | 不一致 | 解決 | 解決先 |
|---|---|---|---|
| `X-01` | `emp_s5` の役割が `control` だが、因果グラフに `Y_S5 → EMP` エッジが無く、#165 §4.2 の判定規則 1（`T(x) = ∅` → `exogenous`）では `control` を導けない | #169 `E10-04` が `emp_s5 = y_s5 / st_lprod_s5` を与えており役割 `control` は正しい。因果グラフのエッジ欠落を #164 への差し戻し `A3` として #165 §7 へ登録する。実装は #169 に従う | **[U]** #165・**[L]** #164 |
| `X-02` | #165 §1.2-6（因果グラフに無いノードの実装状態明示義務）が `capex_pipe_s` 1 件にのみ適用され、`plan_carry_s1`・`xdem_s5`・`ext_demand_s`・`capex_sx_s1` 等の §5.7 会計項目に適用されていない | #165 §5.7 に「本節の変数は**会計実装項目**であり、生成式は #169 §7・§10–§12 が与える」旨の宣言を追加する。個別の差し戻しは行わない（生成式が既に存在するため） | **[U]** #165 |
| `X-03` | #165 §4.2 の判定規則では、当期の他変数から一意に定まる会計項目（`refin_s`・`capex_plan_eff_s1` 等）と MVP `≡ 0` 項目（`tax_s`・`writeoff_s` 等）の役割が導けず、同種の定義式に `control` と `diagnostic` が混在している | #165 §4.2 に**判定規則 5** を追加する: 「会計項目のうち、当期の他変数から一意に定まるもの、および MVP で恒等的ゼロと固定されるものは `diagnostic` とする（独立な自由度を持たないため）。ただし資金制約の閉じ変数となるもの（`capex_defer_s1`）は `control` とする」。§5.7 の役割を規則 5 で再判定する | **[U]** #165 |
| `X-04` | #165 §3.1 の注意が「`S1` の産出・売上を生成する因果エッジは因果グラフ `1.0.0` に存在しない（差し戻し `A1`）」と述べるが、§7 は `A1` を解決済みと記録している（文書内矛盾） | #165 §3.1 の注意を削除し、`A1` 解決後の記述（`y_s1`・`ycap_s1`・`sales_s1` が §5.2 に登録済み）へ差し替える | **[U]** #165 |
| `X-05` | #165 §3.2・§3.3 が `INVEST_s` の由来エッジを `L18`・`L42` のみとし、因果グラフ `1.1.0` が新設した `L62`（`CASH_s → INVEST_s`）・`L64`（`COST_CAPITAL_s → INVEST_s`）を反映していない | #165 §3.2・§3.3 に `L62`・`L64` を追記する | **[U]** #165 |
| `X-06` | `L44`（`CAPEX_EXEC → EMP`）の帰属部門が #165 §3.1 では `S1`、#164 §3.6 と #169 §10.1 では `S3` | `S3` を正とする（#169 `E10-03` が `st_cshare_s3`・`st_capfrac_s3` による正規化で `L43` との二重計上を避ける実装を与えている）。#165 §3.1 から `L44` を除き §3.3 へ移す | **[U]** #165 |

#### 観点 3: 部門境界と会計表

| ID | 不一致 | 解決 | 解決先 |
|---|---|---|---|
| `X-07` | `SX` を相手とする取引 8 行（`C-05`・`C-07`・`C-08`・`C-10`・`C-11`・`C-12`・`F-06`・`F-07`）が #165 §3.1–§3.5 の部門責務と §3.6 の 2 図に一切現れない | #165 §3 の各部門責務へ `SX` 相手の取引を追記し、§3.6 の図 1・図 2 に `SX` ノードを追加する。`SX` が**会計部門であって経済部門ではない**（`SR` に含めない・産出と雇用を出力しない）ことを図の直後の契約に明記する | **[U]** #165 |
| `X-08` | #165 §3.4 が「初期MVPでは `S4` 側の貸借対照表を独立に持たず `debt_s` の反対側として扱う」とするが、#166 §3.2 は `S4` に預金負債・モデル外調達を明示保有させている | #166 を正とする（#165 §3.4 自身が「完全な複式計上は #166 が決める」と委譲している）。#165 §3.4 を #166 §3.2 の内容へ更新し、`loans_s4`・`dep_stock_s4`・`fund_s4`・`nw_s4 ≡ 0` を明記する | **[U]** #165 |
| `X-09` | #165 §3.6 図 2 で `rollover` が `S1` にのみ接続されており、`L63`（`ROLLOVER → CASH_s`、`s ∈ SF`）・#166 `F-03`（`S2`・`S3` も `repay_s` を計上）と矛盾する | 図 2 の `S2`・`S3` 向けエッジにも `rollover` を追加する | **[U]** #165 |
| `X-10` | #166 §4.2 `C-04`・§4.5 が `sales_s5` を用いるが、この変数は #165 にも #166 §10.1 にも登録されていない | `S5` は価格変数を持たない（`price_s5` が存在しない）ため `sales_s5 ≡ y_s5` である。#166 §4.2・§4.5 の `sales_s5` を `y_s5` へ置換し、新規変数を作らない。#169 `E11-22` は既に `y_s5` を用いており整合する | **[U]** #166 |

#### 観点 4: 会計恒等式と動学方程式

| ID | 不一致 | 解決 | 解決先 |
|---|---|---|---|
| `X-11` | `capex_plan_eff_s1` の定義が #166 §6.1（`capex_plan_s1 + plan_carry_s1[t−1]`、繰越残高の全額）と #169 `E6-10`（`capex_plan_s1 + revive_s1`、`revive_s1 = bh_revive_s1 · plan_carry_s1[t−1]`）で異なる。#166 §6.1 は同一節内でも `plan_carry_s1` 更新式と二重に繰越残高を消費する | #169 `E6-10` を正とする（#166 §6.1 の定義では延期が翌期に必ず全額復活し、延期の意味が失われる）。#166 §6.1 を `revive_s1` ベースへ改訂する | **[U]** #166 |
| `X-12` | 閉じ変数の指定が #166 §6.2（`capex_cancel_s1` と `capex_defer_s1` の 2 変数）と #169（`capex_defer_s1` のみ。`capex_cancel_s1` は `E6-09` で計画修正率のみの関数として資金源に依存せず先に確定）で異なる | #169 を正とする。#166 §6.2 の閉じ変数を `capex_defer_s1` の 1 本へ縮小し、`capex_cancel_s1` はステップ 3（計画）で確定する量であることを明記する。§8.4 の閉じ変数テストも `capex_defer_s1` のみを対象へ改める | **[U]** #166 |
| `X-13` | #166 §6.2 は「資金不足を説明のつかない残差項・暗黙の外部資金で埋めない」と規律するが、#169 `E11-14` の `newdebt_s = max(0, need_s − draw_s)` には上限がなく、`st_commit_s1` が拘束する局面で `newdebt_max_s` を超える調達が生じる | #169 の扱い（`funding_forced_s > 0` として構造化記録し自動的に消さない）を正とする。#166 §6.2 の規律を「**残差項を作らず、超過を `funding_forced_s` として観測可能にする**」へ改訂する。契約確定額（`st_commit_s1`）が資金源を上回る局面は、実物側で埋めきれない構造的な状態であり、隠さず記録することが規律の目的に適合する | **[U]** #166 |
| `X-14` | 在庫評価が不整合。#166 §4.2 は `dinv_s`（当期価格建て、`Σ_b d_{b,s} + dinv_s = sales_s`）、#166 §5.3 は `invval_s = st_invprice_s · inv_s`（固定価格・再評価しない）、#166 §5.7 は `valchg_s ≡ 0`。#169 は `E9-13`（`dinv_s = price_s · (y_s − ship_s)`）と `E12-05`（`invval_s = st_invprice_s · inv_s`）を両方引用しており、`price_s ≠ st_invprice_s` のとき `:stock_flow` と `:net_worth_update` が定常状態外で系統的に破れる | **在庫を当期価格で評価する**。`st_invprice_s2`・`st_invprice_s3` を廃止し、`invval_s = price_s · inv_s`、`valchg_s = (price_s − price_s[t−1]) · inv_s[t−1]` とする。`valchg_s ≡ 0` の仮定を撤回する。これにより `Δinvval_s = dinv_s + valchg_s` が恒等的に成立し、`:stock_flow`・`:net_worth_update`・`C-02`/`C-03` 行がすべて整合する。定常状態では `price_s` が一定であるため `valchg_s = 0` となり、`SS-1`–`SS-17` は変更を要しない。構造パラメータは 35 系統から 34 系統へ減る | **[D]** ADR 0013 決定 3・**[U]** #166・#169 |
| `X-15` | `:no_double_count`（`R-3`・`R-4`）が価格変化時に成立しない。#169 `E8-01` は `order_cap_s = st_capex_share_s · capex_exec_s1 / price_s[t−1]`（期首価格で除算）、`E11-17` は `d_{S1,s} = price_s · order_cap_s`（当期価格で乗算） | `price_s` は `E9-15`・`E9-16` により `util_s[t−1]` と `price_s[t−1]` のみに依存する**先決変数**である。したがって `price_s` の生成を期内処理順序ステップ 5 の冒頭へ前倒しし、`order_cap_s` の除算と `d_{S1,s}` の乗算の双方で当期 `price_s` を用いる。参照する時点は変わらないため順序の変更に当たらない（#169 が `int_burden_s`・`repay_s` をステップ 2 へ前倒しした際と同一の論法） | **[D]** ADR 0013 決定 4・**[U]** #169 |
| `X-16` | `R-4` はさらに時点差がある。#169 `E8-02` は `order_inv_s3 = st_invest_share_s3 · invest_s2[t−1] / price_s3[t−1]`（前期 `invest_s2`）、`E7-23` は `inv_sx_s2 = st_invest_share_sx · invest_s2`（当期） | `invest_s2` はステップ 4 で確定し `order_inv_s3` はステップ 5 で生成されるため、当期値を参照しても循環しない。`E8-02` を当期 `invest_s2` へ改訂する（`L19` の遅れ 1 は循環を断つためではなく「—」であり、範囲内の選択） | **[D]** ADR 0013 決定 4・**[U]** #169 |
| `X-17` | `s5_net_sx` の定義が #166 §4.5（`Σ_{s∈{S1,S2,S3}} wagebill_s + sales_s5 − … − im_s5 − …`）と #169 `E11-22`（`Σ_{s∈SR} wagebill_s − … + y_s5 − …`、`SR` は `S5` を含む）で `wagebill_s5 + im_s5` だけ乖離する | #166 §4.2 `C-06` の行説明「`S5` 内部の賃金支払（`wagebill_s5`）は列内で相殺され行列には計上しない」が正である。#169 `E11-22` の集約を `s ∈ SF` へ改める。`im_s5` は `st_va_share_s5 = 1` により恒等的にゼロ（#169 §11.1・差し戻し `E6`(ii)）であり、#166 §4.5 から除く | **[U]** #166・#169 |

#### 観点 5: イベント入力と外生変数

| ID | 不一致 | 解決 | 解決先 |
|---|---|---|---|
| `X-18` | #168 §3.3 の単位語彙表は `"bn USD (2017 chained)"` に対し `application_mode` の既定を `:absolute` とし、表に無い組み合わせを `invalid_unit_mode` として拒否すると規律するが、#168 §4.2 行 3b（`:OrderCancellation`）は同じ単位で `:additive` を用いている（文書内矛盾） | #168 §3.3 の許容表へ `"bn USD (2017 chained)" × :additive` を追加する。#169 §4.2 は `ext_demand_s` に `:multiplicative` / `:additive` / `:absolute` の 3 モードを認めており、追加後は 3 文書が整合する | **[U]** #168 |
| `X-19` | `target_rank`（#168 §5.1）の基準が「§4.1 の表の並び」であるのに対し、#169 §3.1 ステップ 1 の列挙順は #165 §4.4 の順であり異なる。実装者が #169 §3.1 から `target_rank` を導くと決定論的全順序が壊れる | `target_rank` の正本は #168 §4.1 の並びのみとする。#169 §3.1・#165 §4.4 の列挙は説明順であり順位を定義しないことを #168 §5.1 へ明記する。実装では `exogenous_variables(m)` を #168 §4.1 の並びで 1 箇所に定義し、両文書の列挙から導出しない（本書 §4.2・§4.6） | **[U]** #168・**[D]** 本書 §4.2 |

#### 観点 7: パラメータ辞書と区分

| ID | 不一致 | 解決 | 解決先 |
|---|---|---|---|
| `X-20` | #169 §13.2・§13.3 の「固定/較正/推定」欄が「較正」とする 11 系統（`st_cor_s`・`st_lprod_s`・`st_va_share_s`・`st_wbase_s`・`st_cons_share_s1`・`st_spread0`・`st_pol_ref`・`st_coll_ltv`・`bh_util_tgt_s`・`bh_backlog_target_s`・`bh_inv_target_s`）は、§14.2 の逆較正で閉形式導出される（自由度なし）。#170 §7.2 は §14.2 側に従って `CAL-SS` を割り当てているが、読み替えを行った事実を記録していない | #170 §7.2 の割当（`CAL-SS`）を正とする。#169 §13.2・§13.3 の当該欄を「定常水準から導出」へ改め、#170 §7.1 の契約に「`CAL-OBS` から `CAL-SS` へ移した系統を記録する」を追加する | **[U]** #169・#170 |
| `X-21` | #169 §13.3 末尾の区分別個数（導出 12 / 固定 18 / 較正 30 / 推定 28、合計 88）が、行数基準（82）でも部門展開後の個別数基準（149）でも一致しない | 個数を**行（系統）数基準**へ統一し、実測値へ修正する。#170 が「全 35 系統」「全 44 系統」と行数基準で参照しているため、基準を行数に揃える。部門展開後の個別数は別欄として併記する | **[U]** #169 |
| `X-22` | #170 §7.4 の `EB-5` が「8 `EST`」とするが列挙は 9 個（部門展開後）。`EB-6` は個数を記載していない | `EB-5` を 9、`EB-6` を 11（`bh_emp_up_s1`–`_s5` 5 + `bh_emp_down_s1`–`_s5` 5 + `bh_wage_slope` 1）へ修正し、`EST` 総数を 39（部門展開後）と明記する | **[U]** #170 |
| `X-23` | #170 §7.1 は「各パラメータはちょうど 1 つの区分を持つ」と契約するが、`st_pipelag_s`（`CAL-OBS` + `SENS` 併用）・`st_dcap_s`（`CAL-OBS` + 倍率は `SENS`）・`bh_cc_lend`/`bh_cc_equity`/`bh_cc_fc`（表上 `EST` だが既定対応が `W1` 降格）が二重区分になっている | 区分を一意化する。(a) `st_pipelag_s`・`st_dcap_s` は `CAL-OBS` とし、感応度走査は「`CAL-OBS` に分類したうえで §10.4 の `alternative proxy` 感応度の必須対象とする」と表現する（区分と感応度対象は直交する概念であることを §7.1 に明記）。(b) `bh_cc_lend`・`bh_cc_equity`・`bh_cc_fc` は `W1` を**事前適用**して `CAL-OBS` とし、`EST` から外す。`W1` の適用条件（対応する観測変数が `E`）が推定前に判定できるため、推定後の移動ではない | **[U]** #170 |
| `X-24` | #166 §11 の #170 への引き渡しは `st_maturity_s` を「較正対象」と明記しているが、#170 は `SENS` とした（理由は記載あり）。引き渡し要求を外した事実が #170 に記録されていない | #170 §7.2 に「#166 §11 が較正対象として引き渡した `st_maturity_s` を、企業開示を較正入力から除外する決定（[ADR 0012](../adr/0012-capex-credit-cycle-empirical-contract.md) 決定 9）により `SENS` へ移した」旨を追記する | **[U]** #170 |
| `X-25` | #170 §7.5 が `st_commit_s` と部門一般形で記載するが、#169 §13.2 に存在するのは `st_commit_s1`（`S1` のみ） | #170 §7.5 を `st_commit_s1` へ修正する | **[U]** #170 |

#### 観点 8: 出力と観測方程式（単位・時点）

| ID | 不一致 | 解決 | 解決先 |
|---|---|---|---|
| `X-26` | `r_eff_s` の単位が #165 §5.4 で「年率 %」、#166 §5.4 の `r_new_s = (policy_rate + spread/100)/100` では小数。`int_burden_s = r_eff_s · Δt · debt_s[t−1]` が 10億ドル/四半期になるためには小数でなければならない | **小数（decimal）を正とする**。#165 §5.4 の `R_EFF_s` の単位欄を「年率・小数」へ改める。`policy_rate`（年率 %）・`spread`（bp）・`cost_capital_s`（年率 %）とは単位が異なることを #165 §5.4 の契約として明記し、換算式を `metadata["unit_conversions"]` へ出力する（#169 §4.3） | **[U]** #165 |
| `X-27` | `int_burden_s` の定義式が #165 §5.4 表 B の中で 2 通り（`INT_BURDEN_s` 行は `r_eff_s × debt_s[t−1]`、`R_EFF_s` 行は `r_eff_s · Δt · debt_s[t−1]`）。`Δt` の無い版は年率フローであり時点基準 `SUM`（四半期合計、年率換算しない）と矛盾する | `Δt` を含む版（`r_eff_s · Δt · debt_s[t−1]`）を正とする。#165 §5.4 表 B の `INT_BURDEN_s` 行を修正する | **[U]** #165 |
| `X-28` | #165 §5.5 表 B の `hh_income = wage × emp_tot × (1 − τ) + 移転` は、`wage` が無次元指数・`emp_tot` が百万人であるため 10億ドル/四半期にならない。#166 §2.2 はこれを理由に `wagebill_s = st_wbase_s · wage · emp_s` を導入し #165 §5.7 表 B に登録済みだが、§5.5 表 B の式が更新されていない | #165 §5.5 表 B の `hh_income` を `Σ_{s∈SR} wagebill_s − tax_hh` へ改める（#169 `E10-12` と一致させる）。`wagebill_s5` の扱いは `X-17` の解決に従う | **[U]** #165 |

#### 差し戻し事項の版ずれ

| ID | 不一致 | 解決 | 解決先 |
|---|---|---|---|
| `X-29` | #166 が `accounting/1.0.0` のまま上位契約を `graph/1.0.0`・`vars/1.0.0` として書かれており、`B1`–`B6` が上流（`graph/1.1.0`・`vars/1.1.0`）で解決された後の記述に更新されていない。特に §4.2 `C-01` の「`A1` が未解決のため `cons_s1 ≡ 0`・`xsales_s1 = sales_s1` とする暫定運用」は #165 §7 の「`cons_s1 ≡ 0` の暫定運用は不要になった」と**直接矛盾**する。他に §2.4（`L41` の旧仕様引用）・§4.4（`B3` 未解決）・§5.1（`cap_s` 単位）・§5.3（`ship_s` 未変数化）・§6.4(b)（`B5` エッジ無し）・§7.2・§10.1・§10.2・§11 が stale | #166 を `accounting/1.1.0` へ改版し、`B1`–`B7` 解決後の記述へ揃える。`C-01` の暫定運用を解除し、`st_cons_share_s1` を有効化する。上位契約を `graph/1.1.0`・`vars/1.2.0` へ更新する。§10.2 の「#169 は `B1`–`B3`・`B6` の改訂前に着手しない」という着手制限を解除する | **[U]** #166 |
| `X-30` | #166 §7.3 の `funding_pressure_s`† が必須診断量として要求されているにもかかわらず §10.1（#165 への追加提案表）に無く、#165 にも未登録。#166 §1.2-6（本書で暗黙に変数を追加しない）に違反している。あわせて #165 §5.4 の LLM 向け要約が「#166 が追加提案した 43 項目」とするが実測は 42 項目 | #166 §10.1 表 3 へ `funding_pressure_s` を追加し、#165 §5.7 表 C へ登録する（型は診断ラベル列であり `Vector{Float64}` でないため `SimulationResult.variables` へは出力せず診断結果型で返す旨を併記）。#165 §5.4 の項目数を 42 へ修正する | **[U]** #165・#166 |
| `X-31` | #166 §5.5 本文が `S4` の預金残高を `dep_s4` と表記し、固定資本減耗 `dep_s`（`:dep_s1`–`_s3`）と記号衝突している。#166 §10.1 表 3・#165 §5.7 表 C・#169 `E12-14` は `:dep_stock_s4` を用いている。#166 §8.1-9 の検証名 `:s4_balance_sheet` の説明も `dep_s4` のまま。#169 は改名を無言で行っている | `:dep_stock_s4` を正とする。#166 §5.5・§8.1-9 の表記を統一し、#169 §12 に改名の事実を記録する。#165 §6.4 のキー衝突検査（実装時テスト）で再発を防ぐ | **[U]** #165（検査）・#166・#169 |

### 2.3 上流文書への改訂の反映方法

`X-01`–`X-31` のうち **[U]** に分類した 27 件は、該当文書へ **「#171 統合レビューによる改訂」節**を追加し、メタ情報のバージョンと改訂履歴を更新する形で反映した。

| 文書 | 改訂後バージョン | 改訂節 | 反映した ID |
|---|---|---|---|
| #165 [部門境界と変数定義](../models/capex_credit_cycle_sectors_variables.md) | `capex-credit-cycle-vars/1.2.0` | §11 | `X-01`・`X-02`・`X-03`・`X-04`・`X-05`・`X-06`・`X-07`・`X-08`・`X-09`・`X-14`・`X-26`・`X-27`・`X-28`・`X-30`・`X-31` |
| #166 [ストック・フロー会計表](../models/capex_credit_cycle_stock_flow.md) | `capex-credit-cycle-accounting/1.1.0` | §14 | `X-10`・`X-11`・`X-12`・`X-13`・`X-14`・`X-15`・`X-16`・`X-17`・`X-29`・`X-30`・`X-31` |
| #168 [イベント変換契約](macro_event_contract.md) | `macro-event-contract/1.0.1` | §12 | `X-18`・`X-19` |
| #169 [動学方程式](../models/capex_credit_cycle_equations.md) | `capex-credit-cycle-equations/1.1.0` | §21 | `X-14`・`X-15`・`X-16`・`X-17`・`X-20`・`X-21`・`X-31` |
| #170 [観測方程式・識別戦略・検証方針](../models/capex_credit_cycle_empirical_strategy.md) | `capex-credit-cycle-empirical/1.1.0` | §15 | `X-14`・`X-20`・`X-22`・`X-23`・`X-24`・`X-25` |

**改訂節の規律**: 改訂節は当該文書の**正本**であり、本文の該当箇所と矛盾する場合は改訂節が優先する。各文書のメタ情報にこの優先関係を明記した。本文を逐語的に書き換える方式を採らなかった理由は、6,225 行にわたる 40 箇所以上の分散した修正を個別編集すると**新たな不整合を作る確率が改訂節方式より高い**ためである。改訂節は「どの記述が上書きされたか」を 1 箇所で追跡できる。

### 2.4 限界として保持する事項（実装で解決しない）

| 事項 | 出所 | 保持する理由 | 実装での扱い |
|---|---|---|---|
| 家計所得から `S1` 需要への還流経路が無い（`Y_S5 → COMPUTE_DEM` 不在）。`breadth` 判定で `S1` が悪化しにくいバイアス | #169 `E1` | エッジ追加は因果仮説の追加であり #164 の改訂を要する。#170 §7.6 が `S1` 除外版 `breadth` の併記を確定済み | 診断出力に `breadth` と `breadth_excl_s1` を併記する（§6.4） |
| `Y_S5 → EMP` エッジが無い（`X-01`） | 本書 | 同上。#169 `E10-04` が実装を与えており動作に支障がない | #165 §7 の差し戻し `A3` として登録。実装は #169 に従う |
| `L27`（`PROFIT_s → EQUITY_VAL`）の遅れが #164 では `0`、期内処理順序では `1` でしか実装できない | #169 `E4`(i) | 遅れ `1` は #164 の範囲外の選択であり同書の改訂を要する | 遅れ `1` で実装し、`metadata["deviations"]` に記録する |
| `S3` の自部門投資に相手方が無い（`invest_s3` は全額 `SX` から調達） | #166 §12-4 | `X06`（`S3 → S2` 逆連関）が `EXT` である設計判断の帰結 | `:no_double_count` の `R-4` 相当を `invest_s3 = inv_sx_s3` として検証する |
| `S4` の資金制約・自己資本を持たない（銀行側要因の信用収縮を表現しない） | #166 §12-1 | 責務境界の決定（#167 §4） | `ModelCapabilityProfile.caveats` 3 件目として保持（§3.4） |
| `S5` の純資産を追跡しない（資産効果・家計信用が `EXT`） | #166 §12-2 | 同上 | 同 `caveats` |
| 資本財の納期遅延を内生化しない（仮定 A-2） | #166 §12-5 | 同上 | `unmet_cap_s > 0` を `a2_violation` 警告として記録（§6.3） |
| デフォルト・信用損失を内生化しない | #166 §7 | 同上 | 同 `caveats` 2 件目。`funding_pressure_s` は倒産予測ではないと明記 |
| 会計が経済全体で閉じていない（`SX` 残差部門） | #166 §12-3 | `accounting_closure = :partial`。SFC を名乗らない（[ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md) 決定 3） | `SX` 列の列和を検証対象外とし、`s5_net_sx` の大きさを監視する（§7.3） |
| `S1` の収益ブロックが観測に接続されない（`R1a` を実証検証できない） | #170 §11-8 | 企業開示を較正入力から除外する決定（[ADR 0012](../adr/0012-capex-credit-cycle-empirical-contract.md) 決定 9） | `caveats` へ保持。`gain(R1a)` はモデル内診断としてのみ提示 |
| `SH-EXP` の規模を観測から較正できない（`ai_exp` が `A` 分類） | #170 §11-9 | 同 決定 10 | 走査結果として提示し較正値として提示しない（§8.3） |
| `breadth` の閾値を較正できない（実体部門 4 のため 0.25 刻み） | #170 §11-10 | 同 決定 19 | 離散性を診断出力に明記（§6.4） |

---

## 3. DME パッケージ内の配置

### 3.1 追加・修正するファイル

| 種別 | パス | 責務 | 依存 |
|---|---|---|---|
| **追加** | `src/models/capex_credit_cycle.jl` | モデル型・パラメータ辞書・許容条件検査・逆較正・メタ情報 API・`steady_state`・`simulate`（期内 10 ステップ）・数値ガード（T1–T3）・`impulse_response` | `core/model_interface.jl`・`core/solver_options.jl` |
| **追加** | `src/analysis/capex_credit_cycle_accounting.jl` | 貸借対照表・取引フロー行列の構築、会計検証 12 項目（1–5 は既存 `validate_sfc_accounting` を再利用、6–12 はモデル固有） | `sfc/types.jl`・`analysis/sfc_accounting.jl`・モデル型 |
| **追加** | `src/analysis/capex_credit_cycle_diagnostics.jl` | 診断閾値セット・診断ラベル判定・`funding_pressure_s`・`binding` フラグ集計・ループ作動と利得・非線形性近傍・`credit-off` / `cons-off` 反実仮想 | モデル型・会計層 |
| **追加** | `src/analysis/capex_credit_cycle_scenarios.jl` | `Sc0`–`Sc4` の定義とショック仕様（#163 §5.2 の 7 項目）、外生パスの合成（#168 §5.2 の固定順合成） | モデル型 |
| **追加** | `src/analysis/capex_credit_cycle_visualization.jl` | 部門別系列・診断ラベル・シナリオ比較の可視化 | `core/visualization.jl`・診断層 |
| 修正 | `src/DME.jl` | include 追加（§3.2）・export 追加（§3.3） | — |
| 修正 | `src/core/model_interface.jl` | `exogenous_variables` の関数宣言と既定メソッド（§4.2） | — |
| 修正 | `src/core/solver_options.jl` | `CapexCreditCycleOptions` の追加（§4.7） | — |
| 修正 | `src/core/model_capabilities.jl` | `_CAPABILITY_MODEL_SYMBOLS`・`MODEL_CAPABILITY_REGISTRY`・`MODEL_CONCEPT_DEFINITION_REGISTRY` への登録（§3.4） | モデル型 |
| 修正 | `src/llm/cross_model_reasoning.jl` | `_XM_MODEL_LABELS`・`MODEL_CONCEPT_REGISTRY` への登録（§3.4） | — |
| 修正 | `src/core/visualization.jl` | 必要な共通ヘルパーの追加のみ（モデル固有描画は追加ファイル側） | — |
| **追加** | `test/test_capex_credit_cycle.jl` | 構造・契約・動学・数値安全性テスト（§7.1・§7.4・§7.5） | — |
| **追加** | `test/test_capex_credit_cycle_accounting.jl` | 会計テスト（§7.3） | — |
| **追加** | `test/test_capex_credit_cycle_diagnostics.jl` | 診断テスト（§7.6） | — |
| **追加** | `test/test_capex_credit_cycle_demo.jl` | 統合デモの決定性・成果物検証（§8.5） | — |
| 修正 | `test/runtests.jl` | 上記 4 ファイルの include | — |
| **追加** | `test/fixtures/capex_credit_cycle/` | 既定パラメータ・定常水準ターゲット・退化ケース・反例 fixture（§7.7） | — |
| **追加** | `examples/capex_credit_cycle_demo.jl` | `Sc0`–`Sc4` の統合デモ（外部 API 不要、§8） | — |
| **追加** | `docs/models/capex_credit_cycle.md` | モデル解説（`docs/models/template.md` ベース） | — |

**モデル層の責務境界**（既存原則の維持）: `src/models/capex_credit_cycle.jl` は `DataSeries` を受け取らず、可視化・LLM 呼び出しを行わない（#170 §6.5・[モデル共通インターフェース](model_interface.md) §6 の禁止事項）。受け取るのは平坦な `parameters::NamedTuple`・定常状態の初期値・外生変数の四半期パスのみである。

### 3.2 include 順序

`src/DME.jl` の既存ブロックへ次のとおり挿入する。

| 挿入位置 | ファイル | 根拠 |
|---|---|---|
| `models/sfc_sim.jl` の直後（`core/simulation_result.jl` より前） | `models/capex_credit_cycle.jl` | [パッケージ構成](package_structure.md) §2 の規則「新規モデルファイルは `models/` ブロックの末尾」 |
| `analysis/sfc_sim_adapter.jl` の直後 | `analysis/capex_credit_cycle_accounting.jl` | `AccountingCheckReport`・`SFCMethodologyMetadata`（`analysis/sfc_accounting.jl`）と `SimulationResult` に依存 |
| 上記の直後 | `analysis/capex_credit_cycle_scenarios.jl` | モデル型のみに依存 |
| 上記の直後 | `analysis/capex_credit_cycle_diagnostics.jl` | 会計層に依存 |
| `analysis/keen_empirical_visualization.jl` の直後 | `analysis/capex_credit_cycle_visualization.jl` | `core/visualization.jl` より後 |

`core/model_capabilities.jl` はモデル型に依存するため、既存の位置（`core/compare.jl` の後・`core/compare_v2.jl` の前）で `CapexCreditCycleModel` を参照できる。`llm/cross_model_reasoning.jl` は最後尾ブロックにあり問題ない。

### 3.3 export

`src/DME.jl` の `export` 節へ次を追加する。既存の並び（責務別のコメント区切り）を維持する。

| 区分 | 追加する名前 |
|---|---|
| Model type hierarchy | `CapexCreditCycleModel` |
| Model metadata（既存関数に追加なし） | `exogenous_variables`（新設の共通関数、§4.2） |
| CCC: 構築・較正 | `CAPEX_CREDIT_CYCLE_MODEL_VERSION`・`CapexCreditCycleTargets`・`capex_credit_cycle_default_targets`・`capex_credit_cycle_model`・`CapexSectorSets` |
| CCC: 実行 | `CapexCreditCycleOptions`・`CapexCreditCycleRun`・`capex_run`・`capex_steady_state_report`・`CapexSteadyStateReport` |
| CCC: シナリオ | `CapexShockSpec`・`CapexScenario`・`capex_scenario`・`capex_exogenous_paths`・`CAPEX_CC_SCENARIO_IDS` |
| CCC: 会計 | `capex_accounting_snapshots`・`validate_capex_accounting`・`CAPEX_CC_ACCOUNTING_CHECKS` |
| CCC: 診断 | `CapexDiagnosticThresholds`・`CapexDiagnostics`・`capex_diagnostics`・`capex_counterfactual`・`CAPEX_CC_DIAGNOSTIC_LABELS`・`CAPEX_CC_FUNDING_PRESSURE_LABELS` |
| CCC: 可視化 | `plot_capex_sector_paths`・`plot_capex_scenario_comparison`・`plot_capex_diagnostics` |

`AccountingCheckReport`・`AccountingViolation`・`AccountingCheckStatus`・`validate_sfc_accounting` は既に export されており再利用する。

### 3.4 registry 登録

#167 §5.8 の 6 要件をそのまま実施する。

| # | 対象 | 内容 |
|---|---|---|
| 1 | `src/llm/cross_model_reasoning.jl` `_XM_MODEL_LABELS` | `:capex_credit_cycle => "部門別CAPEX・信用循環モデル"` |
| 2 | 同 `MODEL_CONCEPT_REGISTRY` | #167 §5.2 の 5 行（`private_debt_credit`・`income_distribution`・`demand_and_instability`・`steady_state_stability`・`shock_response`）。`caveats` に #167 §2.6 の 5 件を含める |
| 3 | `src/core/model_capabilities.jl` `MODEL_CAPABILITY_REGISTRY`・`_CAPABILITY_MODEL_SYMBOLS` | #167 §2.6 のプロファイル。`accounting_closure = :partial`・`expectations = :static`・`equilibrium_concept = :none`・`estimation = false`・`out_of_sample_validation = false` |
| 4 | 同 `MODEL_CONCEPT_DEFINITION_REGISTRY` | 主要変数の `ModelConceptDefinition`。`concept_id` は `ccc_` 接頭辞。`definition_key` が Keen の `keen_debt_ratio_d` と別になることを保証 |
| 5 | `docs/model_capabilities.md` §3 比較表・`docs/model_selection_guide.md` | 行を追加（`docs/model_capabilities.md` §5 の追加手順に従う） |
| 6 | LLM 説明層 | #167 §2.6 の `caveats` 5 件と §4.2 の「答えられない問い」表を参照可能な形で保持 |

**`equilibrium_concept = :none` の扱い**: #167 §2.6 は既存語彙に該当値が無いため `:none` とし、語彙拡張の要否を #171 へ委ねた。**本書は語彙を拡張しない**と決定する。`CAPABILITY_EQUILIBRIUM_CONCEPTS` へ `:none` 以外の新値を追加すると、既存 10 モデルの分類基準を再検討する必要が生じ、本モデルの実装と無関係な変更を招く。「均衡概念を持たない逐次的な行動方程式系である」という事実は `caveats` と `behavioral_equations = true` で表現できる。

---

## 4. 公開 API 契約

### 4.1 モデル型と構築

```julia
const CAPEX_CREDIT_CYCLE_MODEL_VERSION = "capex-credit-cycle/1.0.0"

struct CapexSectorSets
    SP::Vector{Symbol}   # 生産部門 = [:s2, :s3]
    SF::Vector{Symbol}   # 財務主体 = [:s1, :s2, :s3]
    SR::Vector{Symbol}   # 実体部門 = [:s1, :s2, :s3, :s5]（breadth の分母）
end

struct CapexCreditCycleTargets
    values::NamedTuple           # #169 §14.2 が要求する定常水準（平坦）
    source::Dict{String,Any}     # 定常水準の出所（fixture 名 / provider metadata / 文献）
end

struct CapexCreditCycleModel <: AbstractMacroModel
    params::NamedTuple           # 平坦。キー集合は CAPEX_CC_PARAMETER_NAMES と一致
    targets::CapexCreditCycleTargets
    sectors::CapexSectorSets
    contract_versions::NamedTuple
end
```

| 関数 | シグネチャ | 契約 |
|---|---|---|
| 既定の定常水準 | `capex_credit_cycle_default_targets() -> CapexCreditCycleTargets` | 外部 API なしでデモ・テストが完走するための例示水準。**実データの較正値ではない**ことを `source["kind"] = "illustrative"` で明示する |
| 逆較正による構築 | `capex_credit_cycle_model(targets::CapexCreditCycleTargets; behavioral::NamedTuple = NamedTuple(), policy::NamedTuple = NamedTuple(), sectors = CapexSectorSets()) -> CapexCreditCycleModel` | #169 §14.2 の 13 ステップを閉形式で適用し `st_` を逆算する。`behavioral`・`policy` で `bh_`・`pl_` を上書きする（未指定は既定値）。非線形ソルバを用いない |
| 直接構築 | `CapexCreditCycleModel(; params, targets, sectors = CapexSectorSets(), contract_versions = ...)` | 内部コンストラクタで検証する（下記） |

**内部コンストラクタの検証**（違反は `ArgumentError`、メッセージは日本語。既存モデルの慣習に従う）:

1. `keys(params)` が `CAPEX_CC_PARAMETER_NAMES` と集合として一致すること（過不足を名前付きで報告）。
2. #169 §13.4 の**許容条件 15 件**をすべて満たすこと。条件番号と違反値をメッセージに含める。
3. `sectors` の各集合が `CAPEX_CC_SECTOR_IDS` の部分集合であり、`SP ⊆ SF ⊆ SR` の包含関係を満たすこと。
4. `targets.values` が §14.2 の 13 ステップに必要なキーをすべて持つこと。
5. **キー衝突検査**（#165 §6.5 契約 1）: 部門接尾辞を除いた名前が接尾辞なしの単一系列名と衝突しないこと。

**`params` の型について**: 147 個（部門展開後）のパラメータを個別フィールドにせず、平坦な `NamedTuple` を 1 フィールドに保持する。`parameters(m)` はこれをそのまま返すため #165 §6.2 の「平坦な `NamedTuple` を返す」契約を満たす。既存モデル（`SIMModel` は 5 フィールド）と異なる形をとる理由はパラメータ数であり、`NamedTuple` のフィールド型が抽象になることによる性能低下は、`simulate` の入口で具体型のローカル変数へ展開する（`_ccc_unpack`）ことで回避する。

### 4.2 メタ情報 API

```julia
model_name(::CapexCreditCycleModel)        = "Sectoral CAPEX-Credit Cycle Model"
state_variables(m::CapexCreditCycleModel)  -> Vector{Symbol}   # 64 個
control_variables(m::CapexCreditCycleModel)-> Vector{Symbol}
exogenous_variables(m::CapexCreditCycleModel) -> Vector{Symbol} # 7 個
parameters(m::CapexCreditCycleModel)       -> NamedTuple        # 平坦
```

| 項目 | 契約 |
|---|---|
| `state_variables` | 役割 `state` の 22 変数（`advance_s2`・`advance_s3` を含む）+ 遅延バッファ 42 スロット（深さ 1 が 33 本、深さ 3 が 3 本 = 9 スロット）= **64**。#169 §13.5 は 65 としていたが、`X-16` の解決により `invest_s2` の深さ 1 バッファが不要になった（#169 §21.2）。順序は #165 §5 の表の記載順、遅延バッファは基礎変数の直後に `_lag1`・`_lag2`・`_lag3` の順。**この集合から次期状態が決定論的に再現できること**を要件とし、§7.2 でテストする |
| `control_variables` | 役割 `control` の全変数（`X-03` の判定規則 5 適用後）。順序は #165 §5 の記載順 |
| `exogenous_variables` | #168 §4.1 の並び（`ai_exp`・`capex_plan_shock_ex`・`spread_shock_ex`・`policy_rate`・`ext_demand_s2`・`ext_demand_s3`・`price_s1`）。`target_rank` の正本（§4.6） |
| `parameters` | 平坦な `NamedTuple`。数値解法設定・診断閾値・初期状態・シナリオショックを**含めない**（#169 §13.1） |

**`exogenous_variables` の新設**: #165 §6.1 は「新設するか `parameters` へ含めるかを #171 が決める」とした。**新設する**。理由は (a) 外生パスはシナリオ入力であり `parameters` の平坦 `NamedTuple`（スカラー）に入らない、(b) `state_variables` / `control_variables` へ入れると「モデルの内部状態」という両関数の意味が壊れる、(c) `metadata["variable_roles"]` だけでは実装が役割を照会できない。`src/core/model_interface.jl` に関数宣言と既定メソッド `exogenous_variables(::AbstractMacroModel) = Symbol[]` を置き、既存 10 モデルへの変更を不要にする。

### 4.3 定常状態

```julia
steady_state(m::CapexCreditCycleModel) -> NamedTuple
capex_steady_state_report(m::CapexCreditCycleModel; atol = 1e-8, rtol = 1e-6) -> CapexSteadyStateReport
```

| 項目 | 契約 |
|---|---|
| `steady_state` | 逆較正で与えた定常水準の 1 期分を、`SimulationResult.variables` と同じキー集合の `NamedTuple` として返す。**数値解ではない**ため収束判定・反復回数を持たない（#169 §14.2） |
| `CapexSteadyStateReport` | `SS-1`–`SS-17` の各条件について `passed::Bool`・`residual::Float64`・`tolerance::Float64`・`detail::String` を保持。`passed(report)::Bool` は全条件の論理積。`SS-5`（`capex_exec_s1^{ss} = st_delta_s1 · cap_s1^{ss}`）のように自由度のない整合条件は `ss_residual` として値を報告する（#170 §5.2-5） |
| `simulate` との関係 | `simulate` は開始前に `capex_steady_state_report` を評価し、`passed == false` のとき **`ArgumentError` を投げる**（report の要約をメッセージに含める）。#169 §14.3 は「`ss_inconsistent` として構造化記録し `simulate` を実行しない」と定めており、report を独立に取得できるため構造化記録は失われない。定常状態でない初期状態は §13.4 の許容条件違反と同種の**入力の誤り**であり（#169 §14.4 は Q5 走査時に逆較正の再実行を要求している）、T3 の「例外を投げない」規律（シミュレーション中の数値事象が対象）には該当しない |

### 4.4 シミュレーション

```julia
simulate(m::CapexCreditCycleModel; scenario = :Sc0, exog = nothing, state0 = nothing,
         options = CapexCreditCycleOptions()) -> NamedTuple

capex_run(m::CapexCreditCycleModel; scenario = :Sc0, exog = nothing, state0 = nothing,
          options = CapexCreditCycleOptions(), thresholds = CapexDiagnosticThresholds(),
          validate_accounting = true, diagnostics = true) -> CapexCreditCycleRun
```

| 項目 | 契約 |
|---|---|
| `simulate` | 共通 API。`capex_run(...)` の `series` フィールドをそのまま返す。既存の汎用コード（`to_simulation_result(m, ::NamedTuple, scenario)`・比較 API）が分岐なしに使える |
| `capex_run` | 系列に加えて警告・打ち切り・会計検証・診断を保持する完全な結果を返す（§5.2） |
| `scenario` | `:Sc0`–`:Sc4`。`exog` を与えた場合は `scenario` を無視せず `scenario_name` の記録にのみ用い、外生パスは `exog` を採る（両方指定時は `exog` が優先することを警告として記録） |
| `exog` | `Dict{Symbol,Vector{Float64}}`。キーは `exogenous_variables(m)` と一致、各ベクトル長は `horizon_runup + horizon_eval`。**合成済みの値**を受け取り、モデル層はイベントの合成・適用四半期の決定・単位の解釈を行わない（#169 §4.1） |
| `state0` | `nothing` のとき `steady_state(m)` から 64 次元の状態ベクトルを構成する（遅延バッファも定常値で埋め、ゼロで埋めない。#169 §14.4） |
| 助走区間 | `t = -8 … -1` で全変数が定常値から動かないことを検査し、相対乖離が `options.runup_tol` を超えた期を `runup_deviation` 警告として記録する |
| 期内処理 | #169 §3.1 の 10 ステップ。ステップ 5 の冒頭で `price_s` を確定する（`X-15` の解決） |
| 反復 | 期内に反復を持たない（陽解法・同時方程式なし。[ADR 0011](../adr/0011-capex-credit-cycle-dynamics-contract.md)） |
| 決定性 | 乱数を用いない。同一入力に対し同一出力を返す |

```julia
impulse_response(m::CapexCreditCycleModel, shock_size::Real; shock = :SH_CAPEX,
                 T = 20, options = CapexCreditCycleOptions()) -> NamedTuple
```

`shock ∈ (:SH_EXP, :SH_CAPEX, :SH_CREDIT, :SH_EASING)`。`Sc0` との差を #163 §2.4 の規約（水準変数は相対乖離、比率・金利・スプレッドは差分）で返す。返り値のキーは `d_` 接頭辞を**付けない**（`d_` は比較層の予約接頭辞であり、モデルは使わない。#165 §6.4）。乖離であることは `metadata["measure"] = "deviation"` で表す。

### 4.5 `SimulationResult` への変換

```julia
to_simulation_result(m::CapexCreditCycleModel, run::CapexCreditCycleRun,
                     scenario_name::AbstractString = String(run.scenario)) -> SimulationResult
```

既存の汎用メソッド `to_simulation_result(m::AbstractMacroModel, ::NamedTuple, ::String)` も動作するが、metadata に `"parameters"` のみが入る。予約キー 20 個（§6.1）を設定するのは `CapexCreditCycleRun` を受けるメソッドである。

### 4.6 シナリオとイベント層の境界

```julia
const CAPEX_CC_SCENARIO_IDS = (:Sc0, :Sc1, :Sc2, :Sc3, :Sc4)

struct CapexShockSpec        # #163 §5.2 の指定必須 7 項目 + 適用に必要な 3 項目
    target::Symbol           # exogenous_variables(m) の要素
    meaning::String
    unit::String             # #168 §3.3 の単位語彙
    sign::Int                # +1 / -1
    timing::Int              # 適用開始四半期（t = 0 起点）
    shape::Symbol            # :step / :ramp / :ar1_decay / :step_then_ramp
    shape_params::NamedTuple # 半減期・ramp 長など
    duration::Union{Int,Nothing}
    magnitude::Float64
    application_mode::Symbol # :absolute / :multiplicative / :additive
end

struct CapexScenario
    id::Symbol
    name::String
    shocks::Vector{CapexShockSpec}
end

capex_scenario(id::Symbol) -> CapexScenario                       # :Sc0–:Sc4
capex_exogenous_paths(m, sc::CapexScenario, options) -> Dict{Symbol,Vector{Float64}}
```

| 契約 | 内容 |
|---|---|
| 入れ子性 | `Sc1 ⊂ Sc2 ⊂ Sc3 ⊂ Sc4`。下位シナリオのショックは上位でも同一の意味・単位・時点・持続期間・規模で適用する。実装は `Sc4` のショック列を先頭から切り出す形で構成し、入れ子性を構造的に保証する（テスト §7.4-1） |
| 合成順序 | #168 §5.2 の固定順合成（絶対 → 乗算 → 加算）。同一 `target` に複数ショックが当たる場合は `application_mode` の種別順、同種内は `target_rank`（§4.2 の `exogenous_variables` の並び）→ `timing` → 定義順の全順序で適用する |
| `target_rank` の正本 | `exogenous_variables(m)` の並び（= #168 §4.1）。#169 §3.1・#165 §4.4 の列挙順から導出しない（`X-19`） |
| 期首一括適用 | 期内処理順序ステップ 1 で 1 回だけ適用する。期中適用・期内按分を行わない（#168 シナリオ時間軸 §3.2） |
| magnitude | `capex_scenario` が返す既定値は #163 §5.3 の暫定規模である。**観測から較正した値ではない**。`CapexShockSpec` に `magnitude` を与えずに実行することはできない（捏造禁止。[ADR 0010](../adr/0010-macro-event-scenario-contract.md) 決定 6） |
| 制約違反 | `application_mode` と `unit` の組み合わせが #168 §3.3 の許容表に無い場合、外生パスを生成せず `ArgumentError` を投げる。自動クリップしない |
| Phase 2 との互換性 | `capex_exogenous_paths` が返す `Dict{Symbol,Vector{Float64}}` が**唯一の接続点**である。イベント実行層は同じ型を生成し、`simulate` / `capex_run` は変更しない。`CapexShockSpec` は `AbstractMacroEvent` の**前身ではなく**、シナリオ仕様の記録用型である。イベント属性（公表日・出所・解釈シグナル）を `CapexShockSpec` へ持ち込まない（#168 の 4 層分離） |

### 4.7 数値解法オプション

```julia
Base.@kwdef struct CapexCreditCycleOptions
    horizon_runup::Int = 8
    horizon_eval::Int = 20
    div_eps::Float64 = 1e-8
    guard_max::Float64 = 1e6
    runup_tol::Float64 = 1e-8
    stop_on_sign_violation::Bool = false
end
```

`src/core/solver_options.jl` へ追加する。#169 §13.1 は「`SolverOptions`」と記載したが、**既存の `SolverOptions` にフィールドを追加しない**。理由は同型を既存 10 モデルが共有しており、本モデル固有のフィールド（`runup_tol`・`stop_on_sign_violation`）を持ち込むと他モデルの意味を汚すためである。同ファイルは既に `SolverOptions`・`ValueIterationOptions`・`ODESolverOptions` の 3 型を持ち、モデル種別ごとに型を分ける方針が確立している。`guard_max = 1e6` は `ODESolverOptions` の既定値を継承した値であり、本モデル専用の値を新設していない。

### 4.8 会計検証・診断 API

```julia
capex_accounting_snapshots(m, run::CapexCreditCycleRun) -> Vector{SFCPeriodSnapshot}
validate_capex_accounting(m, run::CapexCreditCycleRun; atol = 1e-8, rtol = 1e-6) -> AccountingCheckReport
const CAPEX_CC_ACCOUNTING_CHECKS = (:balance_row_sum, :balance_column_sum, :flow_row_sum,
    :flow_column_sum, :stock_flow, :nlb_consistency, :net_worth_update, :capex_funding,
    :s4_balance_sheet, :output_income_split, :aggregate_output, :no_double_count)

capex_diagnostics(m, run::CapexCreditCycleRun, baseline::CapexCreditCycleRun;
                  thresholds = CapexDiagnosticThresholds()) -> CapexDiagnostics
capex_counterfactual(m, run::CapexCreditCycleRun, kind::Symbol) -> CapexCreditCycleRun
```

| 項目 | 契約 |
|---|---|
| 会計プリミティブの再利用 | `SFCSector`・`SFCInstrument`・`BalanceSheetMatrix`・`TransactionFlowMatrix`・`SFCPeriodSnapshot`・`AccountingCheckStatus`・`AccountingViolation`・`AccountingCheckReport` を再利用する。検証 1–5 は `validate_sfc_accounting(snapshot)` をそのまま呼び、6–12 をモデル固有に実装して同じ report へ統合する |
| `SFCResult` を作らない | `SFCResult` は SFC モデルの登録簿と恒等式を含む型であり、`accounting_closure = :partial` の本モデルがこれを返すと「SFC 検証済み」と同じ意味に読める（#167 §5.3）。会計表は `Vector{SFCPeriodSnapshot}` として返し、`SFCResult` へ包まない |
| `methodology` | `SFCMethodologyMetadata` を再利用し、`contract_version = "sfc-primitives/1.0.0"`・`model_version = "capex-credit-cycle-accounting/1.1.0"`・`tolerance_abs = 1e-8`・`tolerance_rel = 1e-6` を設定する。本モデル専用の許容誤差規約を作らない（[ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md) §3.1） |
| 検証対象外 | `SX` 列・`S4` 列の列和、実物資産行の行和、`nlb_s5 ≡ 0`（#166 §8.1）。代わりに `s5_net_sx` の残差監視を行う |
| 自動補正なし | `acc_fail` を丸め・クリップで解消しない。`acc_invalid`（`NaN` / `Inf`）を `acc_fail` へ読み替えない（[ADR 0007](../adr/0007-sfc-integration-contract.md)） |
| `capex_counterfactual` | `kind ∈ (:credit_off, :cons_off, :loop_off_r1a, :loop_off_r1b, :loop_off_r2, :loop_off_r2_short, :loop_off_r3, :loop_off_r4)`。固定するパラメータ・変数は #169 §16.5・§16.2 の表に従い、実装が独自に選ばない |
| 診断層の読み取り専用性 | 診断はモデル本体の動学に影響しない（ADR 0003 の Minsky 診断層と同方針）。閾値をモデル方程式へハードコードしない |

---

## 5. 内部型と内部関数

### 5.1 内部型（非 export）

| 型 | 責務 |
|---|---|
| `_CCCState` | 64 次元の期首状態。基礎 state 22 と遅延バッファを保持する可変構造。`simulate` の内部のみで用いる |
| `_CCCPeriod` | 1 期分の全変数（`control`・`diagnostic` を含む）。ステップ 1–10 が順に書き込む |
| `_CCCBinding` | T1 経済制約の `binding` フラグ 23 種（#169 §15.2）。`Vector{Bool}` として期別に蓄積 |

### 5.2 結果型（export）

```julia
struct CapexCreditCycleRun
    model_name::String
    scenario::Symbol
    series::NamedTuple                      # 公開系列（§6.2）
    exog::Dict{Symbol,Vector{Float64}}      # 実際に適用した外生パス
    periods::Vector{Int}                    # -8 … 19
    state0::NamedTuple
    warnings::Vector{Dict{String,Any}}      # (code, period, sector, detail)
    termination_reason::Symbol
    termination_period::Union{Int,Nothing}
    divergence_time::Union{Int,Nothing}
    binding::Dict{Symbol,Vector{Bool}}
    accounting::Union{AccountingCheckReport,Nothing}
    diagnostics::Union{CapexDiagnostics,Nothing}
    options::CapexCreditCycleOptions
    metadata::Dict{String,Any}
end
```

`termination_reason ∈ (:completed, :non_finite_state, :divergence_guard, :sign_constraint_fatal)`（#169 §15.6 の 4 値。**5 値目を追加しない**）。

### 5.3 内部関数（非 export、期内処理順序に対応）

| 関数 | ステップ | 責務 |
|---|---|---|
| `_ccc_unpack(m)` | — | `params` を具体型のローカル `NamedTuple` へ展開する（性能） |
| `_ccc_apply_exog!(p, exog, t)` | 1 | 外生 7 変数の期首一括適用 |
| `_ccc_financial!(p, st, prm)` | 2 | 金融条件・`r_eff_s`・`matur_s`・`refin_s`・`repay_s`・`int_burden_s` |
| `_ccc_plan!(p, st, prm)` | 3 | 期待・目標設備・計画CAPEX・`cancel_s1`・`invest_plan_s` |
| `_ccc_funding!(p, st, prm)` | 4 | 資金源・`capex_defer_s1`・`capex_exec_s1`・`invest_s` |
| `_ccc_orders!(p, st, prm)` | 5 | `price_s` 確定 → `order_cap_s`・`order_inv_s`・`order_gen_s`・`order_s` |
| `_ccc_production!(p, st, prm)` | 6 | `ycap_s`・`y_s`・`ship_s`・`deliv_s`・`util_s`・`y_s1` |
| `_ccc_income!(p, st, prm)` | 7 | 雇用・賃金・`wagebill_s`・`hh_income`・`cons`・`xdem_s5`・`y_s5` |
| `_ccc_revenue!(p, st, prm)` | 8 | `sales_s`・`im_s`・`va_s`・`profit_s`・`ocf_s`・`newdebt_s`・`nlb_s`・`s5_net_sx` |
| `_ccc_update!(st, p, prm)` | 9 | 残高更新・遅延バッファのシフト |
| `_ccc_guard!(run, st, t, opts)` | 9→10 | T2 符号制約検査・T3 打ち切り判定 |
| `_ccc_div(a, b, eps)` | — | ゼロ除算規則（#169 §15.4）。分母を下限で置き換えるのは `E6-08` の 1 箇所のみ |

**契約**: `NaN` の伝播を止めるのは #169 §15.4 が列挙した 4 箇所（`E5-04` の閾値項・`E6-08` の分母・`E9-07` の減産項・`E11-19` の配分）のみである。実装がこれを追加しない。§7.5 のテストで箇所数を固定する。

---

## 6. `SimulationResult`・metadata 契約

### 6.1 metadata 予約キー（20 個）

`SimulationResult` 型を変更しない（[ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md) 決定 8）。#167 §5.7 の 11 キー・#169 §15.6 の 6 キー・#165 §6.3 の 4 キーを統合し、重複を除いた 20 キーを予約する。

| キー | 型 | 内容 | 出所 |
|---|---|---|---|
| `"parameters"` | `Dict{String,Any}` | `parameters(m)` の String 化（既存 adapter 慣習） | 既存 |
| `"variable_roles"` | `Dict{String,String}` | 変数名 → `"state"` / `"control"` / `"exogenous"` / `"diagnostic"` | #165 §6.3 |
| `"variable_sectors"` | `Dict{String,String}` | 変数名 → 部門 ID（`"s1"`–`"s5"`・`"cross"`・`"total"`） | #165 §6.3 |
| `"variable_units"` | `Dict{String,String}` | 変数名 → 単位 | #165 §6.3 |
| `"variable_timing"` | `Dict{String,String}` | 変数名 → `"EOP"` / `"SUM"` / `"AVG"` | 本書（#165 §5 の時点基準を保持） |
| `"variable_observability"` | `Dict{String,String}` | 変数名 → `"D"` / `"C"` / `"P"` / `"E"` / `"A"` | #170 §3。潜在変数の単独提示抑止に用いる |
| `"contract_version"` | `String` | `"capex-credit-cycle-contract/1.0.0"` | #167 §5.7 |
| `"graph_version"` | `String` | `"capex-credit-cycle-graph/1.1.0"` | #167 §5.7 |
| `"vars_version"` | `String` | `"capex-credit-cycle-vars/1.2.0"` | #165 §6.3・#167 §5.7 |
| `"accounting_version"` | `String` | `"capex-credit-cycle-accounting/1.1.0"` | #167 §5.7 |
| `"boundaries_version"` | `String` | `"capex-credit-cycle-boundaries/1.0.0"` | #167 §5.7 |
| `"equations_version"` | `String` | `"capex-credit-cycle-equations/1.1.0"` | #169 §15.6 |
| `"empirical_version"` | `String` | `"capex-credit-cycle-empirical/1.1.0"` | 本書 |
| `"model_version"` | `String` | `CAPEX_CREDIT_CYCLE_MODEL_VERSION` | 本書 |
| `"scenario"` | `Dict{String,Any}` | #163 §5.2 の 7 項目 × ショック数 + `application_mode` + `magnitude` | #167 §5.7 |
| `"diagnostic_threshold_set"` | `Dict{String,Any}` | 閾値セットの識別子・バージョン・全閾値 | #163 §4.4・#167 §5.7 |
| `"termination_reason"` | `String` | 4 値のいずれか | #169 §15.6 |
| `"termination_period"` | `Int` または `nothing` | 打ち切りが生じた期 | #169 §15.6 |
| `"divergence_time"` | `Int` または `nothing` | 発散を検出した最初の期 | #169 §15.6 |
| `"warnings"` | `Vector{Dict{String,Any}}` | 構造化警告。要素は `code`・`period`・`sector`・`detail` の 4 項目 | #169 §15.5 |

補助キー（予約するが値が空でもよい）:

| キー | 内容 |
|---|---|
| `"unit_conversions"` | `Dict{String,String}`。`"bp_to_pct_pt" => "spread / 100"`・`"annual_to_quarter" => "r * 0.25"`・`"maturity_to_rate" => "dt / st_maturity_s"`（#169 §4.3） |
| `"deviations"` | `Vector{Dict{String,Any}}`。上流契約からの逸脱（`L27` の遅れ `1` 等、§2.4）を記録する |
| `"measure"` | `"level"`（`simulate`）または `"deviation"`（`impulse_response`）。比較層の `measure` 判定に用いる（#167 §5.4） |

**契約**:

1. `variables` に載せるのは `Vector{Float64}` で表せる系列のみ。会計表（`Vector{SFCPeriodSnapshot}`）・診断ラベル（`Vector{Symbol}`）・`binding` フラグ（`Vector{Bool}`）・スカラーの診断量は載せない（#167 §5.7・#165 §6.3）。
2. 予約キーは `CCC` の結果にのみ現れる。**他モデルへ同じキーを要求しない**（#167 §5.7）。
3. 比較層はバージョンキーを読み、契約バージョンが異なる結果同士の比較で `provenance` に差を記録する。
4. モデルは予約接頭辞 `d_` を使わない（比較層が生成する。#165 §6.4）。
5. 秘密値（API キー・トークン）を metadata へ入れない。デモの成果物検証でこれを確認する（§8.5）。

### 6.2 公開する系列

| 分類 | 内容 | 個数 |
|---|---|---|
| `state` | 役割 `state` の優先度 `必須` 変数（水準）。`advance_s2`・`advance_s3` は `EXT` だが恒等的ゼロの独立項として出力する | 22 |
| `control` | 役割 `control` の優先度 `必須` 変数（`X-03` 適用後） | §7.1-2 のテストで #165 §5 と一致を検査 |
| `exogenous` | 適用した外生 7 変数 | 7 |
| `diagnostic` | 役割 `diagnostic` の優先度 `必須` 変数 | 同上 |
| 出力しない | 遅延バッファ（基礎変数から再構成可能）・`d_{b,s}`（買い手別購入額。買い手側支出と配分比から再構成可能）・baseline 比乖離 | — |

**辞書整合検査**（#165 §6.5 契約 2）: `SimulationResult.variables` のキー集合が #165 §5 の優先度 `必須` の変数集合と一致することをテストする（§7.1-2）。文書と実装の乖離をテストで検出する。

**潜在変数の扱い**: `cost_capital_s`・`ai_exp`・`target_cap_s1`・`cancel_s1` は `variables` へ出力するが、`metadata["variable_observability"]` に `"E"` / `"A"` を保持し、出力層（可視化・LLM 説明）が単独の水準提示を抑止できるようにする（#165 §5.4 の契約）。

### 6.3 警告コード（10 種）

`metadata["warnings"]` の `code` は #169 §15.5 の 10 種に限る。実装が新しいコードを追加しない。

`runup_deviation`・`a2_violation`・`funding_forced`・`liquidity_gap`・`cash_below_min`・`threshold_proximity`・`extreme_shock`・`acc_warning` / `acc_fail` / `acc_invalid`・`sign_constraint`・`ss_inconsistent`

### 6.4 診断結果

```julia
Base.@kwdef struct CapexDiagnosticThresholds
    id::String = "default"
    version::String = "capex-credit-cycle-thresholds/1.0.0"
    # 深さ（#163 §4.2 G1–G4）
    dy_total = -0.010; dy_sector = -0.030; di_sector = -0.080
    dl = -0.005; dyd = -0.008; dc = -0.008; spread_bp = 100.0
    # 広がり・持続性
    breadth = 0.60; persistence = 2
    # Q1・Q2・Q3
    q1_dy = 0.005; q1_spread_bp = 50.0; q1_recovery_window = 8; q1_recovery_ratio = 0.5
    q2_amplification = 1.2; q3_share_c = 0.30
    # 残差・数値
    s5_resid_tol = 0.05; prox_band = 0.10; jac_h = 1e-6
end

struct CapexDiagnostics
    label::Symbol                              # 4 値
    group_status::Dict{Symbol,NamedTuple}      # G1–G4: (met, start_period, duration)
    breadth::Float64
    breadth_excl_s1::Float64                   # E1 バイアスの併記（§2.4）
    deteriorated_sectors::Vector{Symbol}
    peaks::Dict{String,NamedTuple}             # (value, period)
    recovery_period::Union{Int,Nothing}
    funding_pressure::Dict{Symbol,Vector{Symbol}}   # 部門 → 期別 fp_* ラベル
    loop_active::Dict{Symbol,Bool}             # R1a, R1b, R2, R3, R4
    loop_gain::Dict{Symbol,Union{Float64,Nothing}}
    spectral_radius::Vector{Float64}           # ρ_t
    short_circuit_gain::Vector{Float64}        # g_short
    threshold_proximity::Vector{NamedTuple}    # (id, period, proximity, crossed)
    amplification::Union{Float64,Nothing}      # A（Q2）
    share_c::Union{Float64,Nothing}            # share_C（Q3）
    share_c_additive::Union{Float64,Nothing}   # 補助方式（残差併記）
    delayed_containment::Union{Bool,Nothing}
    label_loop_mismatch::Bool
    accounting_status::AccountingCheckStatus
    thresholds::CapexDiagnosticThresholds
end
```

| 契約 | 内容 |
|---|---|
| ラベル判定 | #163 §4.2 の指標・閾値のみで行う。ループ作動状態からラベルを推論しない。不整合は `label_loop_mismatch = true` として差異を報告し、**ラベルを変更しない**（#169 §16.9） |
| `recession` 禁止 | ラベル名・変数名・出力フィールド名に `recession` を含めない（#163 §4.1）。`broad_downturn` を用いる |
| `breadth` の離散性 | 実体部門 4 のため 0.25 刻み。`breadth ≥ 0.60` は「4 部門中 3 部門以上」を意味することを出力に明記する（#170 §11-10） |
| 会計違反の併記 | `accounting_status` が `acc_fail` を含む結果にラベルを出力する場合、会計違反の存在を必ず併記する。違反を理由にラベルを `indeterminate` へ自動変更しない（#166 §8.3） |
| `A`・`share_C` の性質 | 同一実装内の**反実仮想寄与**であり因果推定ではない。定義できない場合（分母がゼロ）は値を報告せず `nothing` とする（#163 Q2・Q3） |
| `funding_pressure` | #166 §7.4 の 5 値と precedence（`fp_invalid` → `fp_unlevered` → `fp_interest_uncovered` → `fp_rollover_dependent` → `fp_covered`）。Keen の `hedge` / `speculative` / `ponzi` を流用しない。両モデルの区分系列を同一の図に重ねない |
| `ρ_t` の提示 | 状態依存であるため単一値として報告しない。系列と最大値・その時点を報告する。`ρ_t > 1` を「発散する」と述べない（#169 §16.2） |
| 閾値の外部化 | 全閾値を `CapexDiagnosticThresholds` に持ち、`metadata["diagnostic_threshold_set"]` へ出力する。方程式へハードコードしない。各閾値 ±50% のラベルを併記する（#163 §4.4） |

---

## 7. テスト戦略

### 7.1 構造・契約（12 項目）

| # | 内容 |
|---|---|
| 1 | `CapexCreditCycleModel` の内部コンストラクタが §4.1 の検証 1–5 を行い、違反時に `ArgumentError` を投げる（許容条件 15 件それぞれについて 1 反例） |
| 2 | **辞書整合検査**: `simulate` の返り値のキー集合が #165 §5 の優先度 `必須` の変数集合と一致する |
| 3 | **キー衝突検査**: 部門接尾辞を除いた名前が接尾辞なしの単一系列名と衝突しない |
| 4 | `state_variables(m)` が 64 要素であり、遅延バッファを含む |
| 5 | `state_variables` / `control_variables` / `exogenous_variables` の 3 集合が互いに素である |
| 6 | `exogenous_variables(m)` が #168 §4.1 の並びと**順序を含めて**一致する |
| 7 | `parameters(m)` が平坦な `NamedTuple` であり、キー集合が `CAPEX_CC_PARAMETER_NAMES` と一致する |
| 8 | `parameters(m)` に数値解法設定・診断閾値・初期状態・ショック規模が**含まれない** |
| 9 | 出力長が `horizon_runup + horizon_eval` に等しく、`periods` が `-8:19` である |
| 10 | `metadata` に §6.1 の予約キー 20 個がすべて存在する |
| 11 | `metadata["variable_units"]` / `["variable_timing"]` / `["variable_roles"]` / `["variable_sectors"]` / `["variable_observability"]` の 5 辞書が `variables` の全キーを被覆する |
| 12 | 変数名に `recession` を含むものが無い |

### 7.2 状態の完全性（3 項目）

| # | 内容 |
|---|---|
| 1 | `state_variables` の 64 変数のみから次期状態が決定論的に再現できる（`t` 期の状態ベクトルを取り出し 1 期進めた結果が、通し実行の `t+1` 期と一致する） |
| 2 | 遅延バッファを定常値で初期化した場合、助走区間で全変数が定常値から動かない（`runup_deviation` が発生しない） |
| 3 | 遅延バッファをゼロで初期化した場合、`runup_deviation` 警告が記録される（初期化方式の違いが検出できることの確認） |

### 7.3 会計（10 項目）

#166 §8.4 の 5 レイヤーを実装する（`X-12` により閉じ変数テストの対象を `capex_defer_s1` へ改める）。

| # | 内容 |
|---|---|
| 1 | **恒等式**: `Sc0`–`Sc4` の全シナリオで §8.1 の 12 項目が全期 `acc_pass` |
| 2 | 同上で `abs(s5_net_sx) / y_tot ≤ 0.05`（`SS-17`） |
| 3 | **退化ケース**: `capex_exec_s1 = 0` の状態で 12 項目が成立する |
| 4 | 同 `debt_s = 0`（全部門無借金）で成立し、`coverage_agg` が `NaN` のとき `fp_unlevered` に分類される |
| 5 | 同 `inv_s = 0` で成立し、`inv_ratio_s` が `NaN` のとき `y_cut_s = 0` として評価される |
| 6 | **反例**: `cap_s` の更新式を意図的に壊した fixture で `:stock_flow` が `acc_fail` を返す |
| 7 | 同 `capex_exec_s1` の配分比の和を 1 から外した fixture で `:no_double_count` が `acc_fail` を返す |
| 8 | 同 `va_s` の分解を壊した fixture で `:output_income_split` が `acc_fail` を返す |
| 9 | **閉じ変数**: 資金源を人為的に絞った fixture で、差額が `capex_defer_s1` へ現れ、`newdebt_max_s` を超えた分が `funding_forced_s > 0` として記録される（残差項が発生しない） |
| 10 | **決定性**: 同一 fixture・同一設定で 2 回実行し、`AccountingCheckReport` が完全に一致する |

### 7.4 動学（14 項目）

| # | 内容 |
|---|---|
| 1 | **入れ子性**: `Sc1` のショック集合 ⊂ `Sc2` ⊂ `Sc3` ⊂ `Sc4` であり、共通ショックの `target`・`unit`・`timing`・`shape`・`duration`・`magnitude` が全シナリオで一致する |
| 2 | **baseline 安定性**: `Sc0` で全 28 期にわたり全変数が定常値から `runup_tol` 以内（成長率ゼロの定常状態） |
| 3 | 定常状態から出発して 28 期進めても水準が動かない（#170 §10.5 の前向き数値解） |
| 4 | `SS-1`–`SS-17` が `capex_steady_state_report` で全件 `passed` |
| 5 | 定常条件を破る初期状態を与えると `simulate` が `ArgumentError` を投げる |
| 6 | **需要期待ショック（`Sc1`）**: `ai_exp` 下方修正で `compute_dem` → `target_cap_s1` → `capex_plan_s1` → `capex_exec_s1` がすべて負方向へ動く |
| 7 | **CAPEX ショックの波及順序（`Sc2`）**: `capex_exec_s1` → `order_s2` / `order_s3` → `emp_s2` / `emp_s3` → `hh_income` → `cons` → `y_tot` の悪化開始時点がこの順序になる |
| 8 | 同上で `L44`（`capex_exec_s1` → `S3` 雇用）の悪化開始が `L43`（産出経由）より早い（仮説の実装確認） |
| 9 | **信用ショックによる増幅（`Sc3`）**: `A = |peak(dI^{full})| / |peak(dI^{credit-off})| > 1` であり、`credit-off` 反実仮想が #169 §16.5 の 5 パラメータのみを固定している |
| 10 | 同上で `spread` の悪化が `coverage_agg` の閾値割れ後に加速する（`NL-3` の作動） |
| 11 | **金融緩和による相対的緩和（`Sc4`）**: `|peak(dY)|` が `Sc3` より小さく、回復時点が早い |
| 12 | 緩和の適用時点を遅らせると遮断効果が減衰する（2 点比較） |
| 13 | **単調性**: `Sc0` → `Sc1` → `Sc2` → `Sc3` で `|peak(dY)|` が単調非減少（入れ子性の帰結） |
| 14 | ループ作動フラグ（`active(R1a)`–`active(R4)`）が `Sc0` で全 `false`、`Sc3` で `R2` または `R3` が `true` |

**規律**: 6–12 は符号・順序・単調性のみを検査し、特定の数値（`peak(dY)` の値）を期待値として固定しない。パラメータが未較正であるため数値は意味を持たない。「期待した物語になること」を検査対象にしない。

### 7.5 数値安全性（13 項目）

| # | 内容 |
|---|---|
| 1 | 許容条件 15 件それぞれに違反するパラメータセットが `ArgumentError` になる（§7.1-1 と同一だが、条件番号がメッセージに含まれることも検査） |
| 2 | `st_capex_share_s2 + st_capex_share_s3 + st_capex_share_sx ≠ 1` が拒否される |
| 3 | **T1**: `binding` フラグ 23 種がすべて発生しうる（各フラグを立てる fixture を持つ）。`binding` は警告ではないことを確認（`warnings` に現れない） |
| 4 | **T2**: 符号制約を破るパラメータセットで `sign_constraint` 警告が記録され、値が**クリップされない**（そのまま保持される） |
| 5 | 同上で既定では打ち切られない（`termination_reason == :completed`） |
| 6 | `stop_on_sign_violation = true` のとき `termination_reason == :sign_constraint_fatal` |
| 7 | **T3**: `NaN` を生む入力で `termination_reason == :non_finite_state` かつ例外を投げない |
| 8 | 発散する入力で `termination_reason == :divergence_guard` かつ `divergence_time` が記録される |
| 9 | 打ち切り後の期が invalid として分類され、`0` で埋められない |
| 10 | **ゼロ除算**: #169 §15.4 の 13 箇所それぞれで、分母がゼロのとき `NaN` になり `*_invalid` が記録される |
| 11 | `NaN` の伝播を止める箇所が**ちょうど 4 箇所**である（`E5-04`・`E6-08`・`E9-07`・`E11-19`）。5 箇所目が現れたら失敗する |
| 12 | **決定性**: 同一入力で 2 回実行し、全系列・全警告・全診断が完全一致する（fixture 非依存） |
| 13 | `div_eps`・`guard_max`・`runup_tol` を 1 桁上下させても診断ラベルが変わらない（#170 §10.5） |

### 7.6 診断（5 項目）

| # | 内容 |
|---|---|
| 1 | `funding_pressure_s` の 5 ラベルが precedence どおりに分岐する（各ラベルの fixture を持つ） |
| 2 | 診断ラベル 4 値がそれぞれ発生しうる fixture を持ち、`contained_adjustment` と `broad_downturn` が両立しない |
| 3 | 閾値を ±50% 変化させたラベルが併記される |
| 4 | `threshold_proximity` が `NL-1`–`NL-7` の 7 箇所すべてで検出されうる |
| 5 | `acc_fail` を含む結果でラベルが自動的に `indeterminate` へ変わらず、会計違反が併記される |

### 7.7 fixture（外部 API 不要・決定論的）

| パス | 内容 |
|---|---|
| `test/fixtures/capex_credit_cycle/targets_default.json` | 既定の定常水準ターゲット（例示。実データの較正値ではない） |
| `test/fixtures/capex_credit_cycle/params_default.json` | 逆較正の結果 + `bh_`・`pl_` の既定値 |
| `test/fixtures/capex_credit_cycle/degenerate_*.json` | 退化ケース 3 種（§7.3-3〜5） |
| `test/fixtures/capex_credit_cycle/broken_*.json` | 反例 3 種（§7.3-6〜8） |
| `test/fixtures/capex_credit_cycle/binding_*.json` | `binding` フラグ 23 種を立てる最小セット |
| `test/fixtures/capex_credit_cycle/fp_*.json` | `funding_pressure_s` の 5 ラベル |

**規律**: fixture は数値の**構造**（符号・大小関係・退化）を作るためのものであり、実データの代用ではない。`source["kind"] = "illustrative"` を全 fixture に持たせ、較正値と誤読されないようにする。

---

## 8. 最小統合デモ設計

### 8.1 デモの目的と制約

`examples/capex_credit_cycle_demo.jl`。外部 API キー・ネットワークなしで完走する。実データ取得を行わないため `src/data/` を使わない。

| 制約 | 内容 |
|---|---|
| 決定性 | 乱数を用いず、同一入力で同一成果物を生成する |
| 秘密値 | 成果物に API キー・トークンを含めない |
| LLM | 既定では LLM を呼ばない。`MockProvider` を用いた説明生成は任意ステップとする（既存デモの慣習） |
| 名称 | 成果物・見出しに `Digital Twin` / `Digital Shadow` を用いない（[ADR 0014](../adr/0014-digital-twin-naming-conditions.md) 決定 1） |

### 8.2 入力

| 項目 | 値 |
|---|---|
| モデル | `capex_credit_cycle_model(capex_credit_cycle_default_targets())` |
| シナリオ | `Sc0`（baseline）・`Sc1`（需要期待下方修正）・`Sc2`（+ CAPEX 削減）・`Sc3`（+ 信用ショック）・`Sc4`（+ 金融緩和） |
| ショック規模 | #163 §5.3 の暫定既定値（`-10%` / `-15%` / `+150bp` / `-100bp`） |
| ホライズン | 28 四半期（助走 8 + 評価 20） |
| 反実仮想 | 各シナリオについて `credit-off`（Q2 の `A`）・`Sc2`/`Sc3` について `cons-off`（Q3 の `share_C`） |
| 閾値セット | `CapexDiagnosticThresholds()`（既定）と ±50% の 2 変種 |

### 8.3 出力

| # | 出力 | 内容 |
|---|---|---|
| 1 | シナリオ別基礎系列 | `capex_exec_s1`・`invest_s2`・`invest_s3`・`order_s2`・`order_s3`・`util_s2`・`util_s3`・`inv_ratio_s2`・`inv_ratio_s3`・`spread`・`debt_s1`–`_s3`・`emp_tot`・`hh_income`・`cons`・`y_tot` |
| 2 | baseline 比乖離 | 上記の `dx_t`（#163 §2.4 の規約。比較層が生成） |
| 3 | 診断 | シナリオ別の診断ラベル・`G1`–`G4` 充足状況・`breadth`（`breadth_excl_s1` 併記）・`peak(dY)` と時点・回復時点 |
| 4 | 資金繰り診断 | 部門別 `funding_pressure_s` の期別ラベルと滞在比率 |
| 5 | ループ診断 | `active(R1a)`–`active(R4)`・`gain(loop)`・`ρ_t` の系列と最大値・`g_short` |
| 6 | 判定問題の回答 | Q2 の `A`（`Sc3`）・Q3 の `share_C`（主方式と加法分解の両方 + 残差比）・Q4 の `Sc3` vs `Sc4` 比較 |
| 7 | 会計検証 | シナリオ別の `AccountingCheckReport` 要約（12 項目 × 28 期の `acc_pass` 件数・違反の有無・`max_abs_residual`） |
| 8 | 感応度 | 閾値 ±50% でのラベル・`threshold_proximity` の検出結果 |
| 9 | 比較 API | `compare_results_v2` による `Sc0` vs `Sc3` の `mechanism` モード比較（同一モデル内のシナリオ比較） |
| 10 | 構造化サマリー | JSON。`metadata` 予約キー 20 個・警告・打ち切り・provenance を含む |
| 11 | 注意事項 | 下記 §8.4 |
| 12 | プロット | 部門別系列（3 段）・シナリオ比較（`dY`・`dI`・`dC`）・診断ラベルの時間帯・`funding_pressure` の帯グラフ |

### 8.4 デモ出力に必須の注意事項

1. パラメータは**例示値**であり実データによる較正を経ていない。系列の水準の絶対値に意味はなく、baseline 比乖離の符号・順序・大小関係のみが解釈対象である。
2. 診断ラベル `broad_downturn` はモデル内の診断であり、景気後退の予測・確率ではない。
3. `A` と `share_C` は同一実装内の反実仮想寄与であり因果推定ではない。
4. `funding_pressure_s` は倒産・信用イベントの予測ではない（デフォルトを内生化していない）。
5. 会計は残差部門 `SX` を置いて閉じており、経済全体で閉じていない（`accounting_closure = :partial`）。SFC 検証済みと同じ意味ではない。
6. `cost_capital_s`・`ai_exp`・`target_cap_s1`・`cancel_s1` は潜在変数であり、単独の水準を提示しない。
7. 本出力は投資判断・政策立案の根拠として使用することを意図していない（[llm_safety.md](../llm_safety.md) §5.2）。

### 8.5 デモのテスト（`test/test_capex_credit_cycle_demo.jl`）

| # | 内容 |
|---|---|
| 1 | デモが例外なく完走し、5 シナリオすべての結果を生成する |
| 2 | 2 回実行して成果物 JSON が完全一致する（決定性） |
| 3 | 成果物に `metadata` 予約キー 20 個が存在する |
| 4 | 成果物に API キー・トークンらしき文字列が含まれない |
| 5 | 成果物に `Digital Twin` / `Digital Shadow` / `デジタルツイン` が含まれない |
| 6 | 成果物に §8.4 の注意事項 7 件が含まれる |
| 7 | 全シナリオで会計検証 12 項目が `acc_pass` |
| 8 | ネットワークアクセスを行わない（`FredClient` / `EStatClient` を生成しない） |

---

## 9. 後続の実装作業への分解

追加の理論・会計・API 判断なしに着手できる粒度へ分解した 8 件。依存は `→` で示す。`I-1` → `I-2` → `I-3` / `I-4` / `I-5`（並行可）→ `I-6` → `I-7` → `I-8`。

### `I-1` モデル型・パラメータ辞書・逆較正・初期状態

| 項目 | 内容 |
|---|---|
| 対象ファイル | `src/models/capex_credit_cycle.jl`（新規）・`src/core/solver_options.jl`・`src/core/model_interface.jl`・`src/DME.jl`・`test/test_capex_credit_cycle.jl`（新規）・`test/fixtures/capex_credit_cycle/targets_default.json`・`params_default.json` |
| 実施内容 | `CapexSectorSets`・`CapexCreditCycleTargets`・`CapexCreditCycleModel`・`CapexCreditCycleOptions` の定義。`CAPEX_CC_PARAMETER_NAMES`（`st_` 34 + `bh_` 44 + `pl_` 3 = 81 系統、部門展開後 147 個）の定義。許容条件 15 件の検査。#169 §14.2 の逆較正 13 ステップ。`capex_credit_cycle_default_targets`。メタ情報 4 関数 + `exogenous_variables`（既定メソッドを含む）。`steady_state` と `capex_steady_state_report`（`SS-1`–`SS-17`） |
| 依存 | なし |
| 対象外 | `simulate`・会計・診断・シナリオ |
| 受け入れ条件 | §7.1 の 12 項目（9・10・11 を除く）・§7.4-4・§7.5-1・§7.5-2 が通る。`using DME` が通り `capex_credit_cycle_model(capex_credit_cycle_default_targets())` が構築できる |

### `I-2` 期内動学・数値ガード・`simulate`

| 項目 | 内容 |
|---|---|
| 対象ファイル | `src/models/capex_credit_cycle.jl`・`test/test_capex_credit_cycle.jl` |
| 実施内容 | 内部型 `_CCCState`・`_CCCPeriod`・`_CCCBinding`。期内処理順序 10 ステップの内部関数 9 本（§5.3）。#169 §5–§12 の全方程式。T1 経済制約 23 箇所と `binding` フラグ。T2 符号制約 15 件。T3 打ち切り 4 値。ゼロ除算規則 13 箇所（伝播停止は 4 箇所のみ）。警告 10 種の構造化記録。`simulate`・`capex_run`・`CapexCreditCycleRun` |
| 依存 | `I-1` |
| 対象外 | 会計表の構築・診断ラベル・シナリオ定義（`exog` を直接与えて検証する） |
| 受け入れ条件 | §7.1-9・§7.2 の 3 項目・§7.5 の 13 項目が通る。`Sc0` 相当（外生を定常値に固定）で全 28 期にわたり定常値から `runup_tol` 以内 |

### `I-3` 会計表・残高更新・恒等式検証

| 項目 | 内容 |
|---|---|
| 対象ファイル | `src/analysis/capex_credit_cycle_accounting.jl`（新規）・`src/DME.jl`・`test/test_capex_credit_cycle_accounting.jl`（新規）・`test/fixtures/capex_credit_cycle/degenerate_*.json`・`broken_*.json` |
| 実施内容 | instrument 8 種・部門 6 列の貸借対照表行列、`C-01`–`C-12`・`F-01`–`F-07` の取引フロー行列の構築（`capex_accounting_snapshots`）。検証 12 項目（1–5 は `validate_sfc_accounting` の再利用、6–12 は新規）。`SFCMethodologyMetadata` の設定。`SFCResult` を作らない |
| 依存 | `I-2` |
| 対象外 | 診断ラベル・シナリオ |
| 受け入れ条件 | §7.3 の 10 項目が通る。反例テスト 3 件が `acc_fail` を返す（検証が検出力を持つ） |

### `I-4` シナリオ定義と外生パス合成

| 項目 | 内容 |
|---|---|
| 対象ファイル | `src/analysis/capex_credit_cycle_scenarios.jl`（新規）・`src/DME.jl`・`test/test_capex_credit_cycle.jl` |
| 実施内容 | `CapexShockSpec`・`CapexScenario`・`capex_scenario`（`Sc0`–`Sc4`）。時間形状 4 種（`:step` / `:ramp` / `:ar1_decay` / `:step_then_ramp`）。#168 §5.2 の固定順合成と全順序。`unit` × `application_mode` の許容表検査。`capex_exogenous_paths` |
| 依存 | `I-1` |
| 対象外 | イベント型・`run_scenario`・イベントログ（Phase 2） |
| 受け入れ条件 | §7.4-1（入れ子性）が通る。許容表に無い組み合わせが `ArgumentError` になる。`Sc0` の外生パスが全期 baseline 値と一致する |

### `I-5` 診断層（ラベル・資金繰り・ループ・非線形性・反実仮想）

| 項目 | 内容 |
|---|---|
| 対象ファイル | `src/analysis/capex_credit_cycle_diagnostics.jl`（新規）・`src/DME.jl`・`test/test_capex_credit_cycle_diagnostics.jl`（新規）・`test/fixtures/capex_credit_cycle/binding_*.json`・`fp_*.json` |
| 実施内容 | `CapexDiagnosticThresholds`・`CapexDiagnostics`・`capex_diagnostics`。診断ラベル 4 値の判定（`G1`–`G4`・`breadth`・持続性）。`funding_pressure_s` の 5 値と precedence。ループ作動フラグ 5 本と利得（ヤコビアン `ρ_t` + 反実仮想比）。`g_short`。`NL-1`–`NL-7` の近傍検出。`capex_counterfactual`（`credit-off`・`cons-off`・`loop-off` 6 種）。`share_C` の主方式と加法分解 |
| 依存 | `I-2`・`I-3`（会計違反の併記のため） |
| 対象外 | 可視化・LLM 説明 |
| 受け入れ条件 | §7.6 の 5 項目・§7.4-9・§7.4-14 が通る。`credit-off` が #169 §16.5 の 5 パラメータのみを固定する |

### `I-6` `SimulationResult` 変換・registry 登録・比較 API 接続

| 項目 | 内容 |
|---|---|
| 対象ファイル | `src/models/capex_credit_cycle.jl`・`src/core/model_capabilities.jl`・`src/llm/cross_model_reasoning.jl`・`docs/model_capabilities.md`・`docs/model_selection_guide.md`・`test/test_capex_credit_cycle.jl` |
| 実施内容 | `to_simulation_result(m, run, scenario)` と metadata 予約キー 20 個。#167 §5.8 の registry 登録 6 要件。`compare_results_v2` での同一モデル内シナリオ比較の動作確認。`ModelConceptDefinition` の `ccc_` 接頭辞 |
| 依存 | `I-2`・`I-3`・`I-5` |
| 対象外 | 他モデルとの数値比較（`equivalent` が存在しないため `mechanism` モードのみ） |
| 受け入れ条件 | §7.1-10・§7.1-11 が通る。`model_capabilities(:capex_credit_cycle)` が `accounting_closure == :partial` を返す。既存の `test_model_capabilities.jl`・`test_cross_model.jl` が通る |

### `I-7` 可視化

| 項目 | 内容 |
|---|---|
| 対象ファイル | `src/analysis/capex_credit_cycle_visualization.jl`（新規）・`src/core/visualization.jl`・`src/DME.jl` |
| 実施内容 | 部門別系列・シナリオ比較・診断ラベル帯・`funding_pressure` 帯の描画。潜在変数の単独提示を抑止する（`variable_observability` を参照）。Keen の資金調達区分と同一の図に重ねない |
| 依存 | `I-6` |
| 対象外 | LLM 説明 |
| 受け入れ条件 | 図が生成され保存できる。潜在変数のみを含む図が生成されない |

### `I-8` 統合デモ・ドキュメント

| 項目 | 内容 |
|---|---|
| 対象ファイル | `examples/capex_credit_cycle_demo.jl`（新規）・`test/test_capex_credit_cycle_demo.jl`（新規）・`test/runtests.jl`・`docs/models/capex_credit_cycle.md`（新規）・`docs/examples/capex_credit_cycle_demo.md`（新規）・`CLAUDE.md`・`README.md` |
| 実施内容 | §8 のデモ。`docs/models/template.md` ベースのモデル解説（状態変数・式・単位・時間軸・限界）。デモの実行手順ドキュメント。索引更新 |
| 依存 | `I-7` |
| 対象外 | 実データ接続・較正・履歴再生 |
| 受け入れ条件 | §8.5 の 8 項目が通る。`Pkg.test()` が通る。docs のリンクが解決する |

**全 Issue に共通の受け入れ条件**: (a) `julia --project=. -e "using DME"` が通る、(b) 変更対象の関数に対する smoke test が通る、(c) `test_quality.jl`（Aqua・JuliaFormatter）が通る、(d) 上流契約に無い遅れ・関数形・単位換算を独自に追加していない。

---

## 10. 引き渡し事項と未解決事項

### 10.1 後続フェーズへの引き渡し

| 引き渡し先 | 内容 |
|---|---|
| イベント・シナリオ実行層（#125 Phase 2） | 接続点は `capex_exogenous_paths` が返す `Dict{Symbol,Vector{Float64}}` のみ（§4.6）。`AbstractMacroEvent`・`Scenario`・`run_scenario`・イベントログ・`event_set_hash` は本書の対象外。`metadata` へ `"event_log"` キーを追加する拡張点を予約する（予約のみ。本書では設定しない） |
| 実データ接続・較正（#125 Phase 3） | `CapexCreditCycleTargets` が較正層との接続点。較正層は観測から定常水準を作り `capex_credit_cycle_model` へ渡す。モデル層は `DataSeries` を受け取らない（#170 §6.5）。fixture 形式・provider 系列の取得経路は Phase 3 が確定する |
| モデル横断比較・説明（#125 Phase 4） | registry 登録（§3.4）と `metadata` 予約キー（§6.1）が接続点。`equivalent` が存在しないため数値比較は `mechanism` モードに限る（#167 §5.2）。`AnalysisContext` の拡張は Phase 4 |
| 異質性・逐次状態推定（#125 Phase 5） | `CapexSectorSets` が部門集合の拡張点。`DS-1`–`DT-4`（[ADR 0014](../adr/0014-digital-twin-naming-conditions.md)）の充足判定は Phase 5 |

### 10.2 本書で解決しなかった事項

| 事項 | 状態 | 扱い |
|---|---|---|
| §2.4 の限界 12 件 | 保持 | 実装では `caveats`・警告・診断出力の併記として表現する |
| #164 への差し戻し `A3`（`Y_S5 → EMP` エッジ）・`E1`（`Y_S5 → COMPUTE_DEM`）・`E2`（`EMP` の部門展開）・`E3`(i)（`L17` の適用範囲）・`E4`(i)（`L27` の遅れ） | 未解決 | 因果仮説の追加・変更であり #164 の改訂を要する。実装は #169 の暫定扱いに従い、`metadata["deviations"]` に記録する |
| `st_invprice_s` 廃止に伴う #170 §7.2 の `FIX` 一覧の更新 | 部分反映 | `X-14` の改訂節で `st_invprice_s2`・`st_invprice_s3` を削除した。#170 §7.2 の該当行の削除は #170 の改訂節に記録済み |
| 会計許容誤差 `rtol = 1e-6` の妥当性 | 未確定 | #166 §8.2 が「#170 の数値解法頑健性確認で再評価」としている。実装では既定値を用い、§7.5-13 で 1 桁上下の感応度を確認する |
| `equilibrium_concept` 語彙の拡張 | 拡張しない | §3.4 で決定。`:none` + `caveats` + `behavioral_equations = true` で表現する |
| `metadata["event_log"]` の構造 | 未確定 | Phase 2。キー名のみ予約する |

---

## 11. 改訂履歴

| version | 日付 | 変更 |
|---|---|---|
| `capex-credit-cycle-integration/1.0.0` | 2026-07-30 | 初版。#163〜#170 の整合レビュー（`X-01`–`X-31`）・実装配置・公開API・出力契約・テスト戦略・デモ仕様・作業分解（`I-1`–`I-8`）を確定（#171） |

---

## 参考

- [統合モデル仕様 index](../models/capex_credit_cycle_design.md) — 8 文書の正典表・横断辞書・仕様の要約
- [ADR 0013](../adr/0013-capex-credit-cycle-integration-contract.md) — 統合実装設計契約の決定記録
- [ADR 0014](../adr/0014-digital-twin-naming-conditions.md) — `Digital Twin` / `Digital Shadow` の名称使用条件
- [ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md) — 責務限定・`accounting_closure = :partial`・`SimulationResult` 非変更
- [ADR 0010](../adr/0010-macro-event-scenario-contract.md) — イベントの 4 層分離・適用先 7 変数・固定順合成
- [ADR 0011](../adr/0011-capex-credit-cycle-dynamics-contract.md) — 陽解法・遅れの列挙・数値ガード 3 層・逆較正
- [ADR 0012](../adr/0012-capex-credit-cycle-empirical-contract.md) — 観測方程式の変換契約・パラメータ 6 区分・推定ブロック・4 レイヤー検証
- [モデル共通インターフェース](model_interface.md) — 抽象型階層・共通関数・新規モデル追加時の最低限のI/F
- [パッケージ構成とアーキテクチャ概要](package_structure.md) — ソースツリー・include 順序
- [LLM出力の安全性・免責・禁止表現ルール](../llm_safety.md) — 禁止表現・必須記載・チェックリスト
