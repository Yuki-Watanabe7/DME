# 部門別CAPEX・信用循環モデル 動学方程式と数値計算契約

> 関連 Issue: #169（本書）・#163（分析契約）・#164（因果グラフ）・#165（部門境界と変数定義）・#166（ストック・フロー会計表）・#167（責務境界）・#168（イベント変換・時間軸）・#125（ロードマップ）
> 前提: [分析契約](capex_credit_cycle_analysis_contract.md)・[因果グラフ](capex_credit_cycle_causal_graph.md)（`1.1.0`）・[部門境界と変数定義](capex_credit_cycle_sectors_variables.md)（`1.1.0`）・[ストック・フロー会計表](capex_credit_cycle_stock_flow.md)・[責務境界](capex_credit_cycle_model_boundaries.md)・[マクロイベント変換契約](../architecture/macro_event_contract.md)・[シナリオ時間軸](../architecture/scenario_time_semantics.md)・[ADR 0007](../adr/0007-sfc-integration-contract.md)・[ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md)・[ADR 0010](../adr/0010-macro-event-scenario-contract.md)
> 決定記録: [ADR 0011](../adr/0011-capex-credit-cycle-dynamics-contract.md)
> 後続設計: #170（[観測方程式・識別戦略・検証方針](capex_credit_cycle_empirical_strategy.md)）・#171（統合）

---

## メタ情報

| 項目 | 内容 |
|---|---|
| **対象** | 部門別CAPEX・信用循環モデル（`CapexCreditCycleModel` 相当、未実装） |
| **ステータス** | 動学契約のみ確定。パラメータ値・実装は未着手 |
| **equations version** | `capex-credit-cycle-equations/1.1.0` |
| **上位契約** | `capex-credit-cycle-contract/1.0.0`・`capex-credit-cycle-graph/1.1.0`・`capex-credit-cycle-vars/1.2.0`・`capex-credit-cycle-accounting/1.1.0`・`capex-credit-cycle-boundaries/1.0.0`・`macro-event-contract/1.0.1`・`scenario-time-semantics/1.0.0` |
| **改訂の優先関係** | **§21（#171 統合レビューによる改訂）が本書の正本である。§3.1・§8・§9・§11・§12・§13.2・§13.3 の一部は §21 で上書きされている。実装の前に §21 を読むこと。** |
| **基準経済・頻度** | 米国・四半期（契約 §2.1 を継承。`Δt = 0.25` 年） |
| **時間表現** | 離散時間。`t = -8 … 19`（助走 8 + 評価 20 四半期） |
| **解法** | 陽解法（期内逐次代数評価 + 1 階差分）。同時方程式・反復解法を用いない（§2） |

> **LLM向け要約**: 本書は初期MVPの**離散時間ハイブリッド方式**（期内の即時関係は代数式、残高は 1 階差分式）を
> 選定し、`capex-credit-cycle-accounting/1.0.0` §2.5 の**期内処理順序 10 ステップ**に沿って全方程式を確定する（§4–§12）。
> **期内に同時方程式を作らない**ことを契約とし、因果グラフの全循環をどのエッジの遅れで断つかを列挙する（§3.3）。
> 期待は外生指数と時間形状のみで駆動し、モデル内に二重の平滑化を置かない（§6.1）。CAPEX は
> 「計画 → キャンセル（閾値）→ 延期（資金制約の閉じ変数）→ 実行」の順で決まり、資金源の枯渇が
> **必ず実物の投資削減として現れる**（§7）。生産は資本財需要を優先充足し、一般需要は目標受注残・
> 目標在庫の水準へ部分調整する（§9）。パラメータは `st_`（構造）/ `bh_`（行動）/ `pl_`（政策）へ分類し、
> **推定対象を `bh_` の一部に限定**する（§13）。baseline は**成長率ゼロの定常状態**とし、定常水準を与えて
> 構造パラメータを逆算する（§14）。数値ガードを**経済制約（T1）/ 制約違反（T2）/ 打ち切り（T3）の 3 層**へ
> 分離し、hard clamp とシミュレーション失敗を区別する（§15）。本書はパラメータ値・実装コード・観測方程式を
> 定めない（§20）。上流への差し戻し事項 `E1`–`E6`（6 件）を §17 に登録する。
> **`1.1.0` では #171 の統合レビューにより、`price_s` の生成をステップ 5 の冒頭へ前倒し・`order_inv_s3` の
> 当期 `invest_s2` 参照・在庫の当期価格評価・`s5_net_sx` の集約範囲・`dep_stock_s4` の改名の明記・
> パラメータ区分欄と個数の修正を §21 で改訂している。**

---

## 1. 本書の位置づけと確定範囲

### 1.1 位置づけ

[分析契約](capex_credit_cycle_analysis_contract.md)が「何を問うか」、[因果グラフ](capex_credit_cycle_causal_graph.md)が「どの経路で伝わるか」、[部門境界と変数定義](capex_credit_cycle_sectors_variables.md)が「どの部門が何を持つか」、[ストック・フロー会計表](capex_credit_cycle_stock_flow.md)が「各期の残高がどう閉じるか」を固定した。
本書はその上で「**各変数が具体的にどの式で決まり、どの順で計算され、どこで破綻するか**」を固定する。

| 本書が固定するもの | 本書が固定しないもの |
|---|---|
| モデル形式（離散/ODE/ハイブリッド）と解法（§2） | 数値解法設定の既定値（`SolverOptions`、#171） |
| 期内処理順序の変数レベル割当と循環の切り方（§3） | 期内処理順序そのもの（#166 §2.5 で確定済み。変更しない） |
| 外生入力の反映式と単位換算（§4） | イベントの合成・適用四半期の決定（#168 で確定済み） |
| 全 `control` 変数の行動方程式と全 `diagnostic` 変数の定義式（§5–§12） | 各方程式のパラメータ値（#170） |
| パラメータの記号・Julia 名・単位・範囲・固定/較正/推定区分（§13） | 較正の実行・推定手法・標本期間（#170） |
| baseline の定義・初期状態の整合条件・定常条件（§14） | 定常水準の数値（#170） |
| 数値ガードの 3 層分離・ゼロ除算・発散・打ち切り契約（§15） | 許容誤差の既定値（[ADR 0007](../adr/0007-sfc-integration-contract.md) から継承） |
| 診断層の契約（ループ利得評価・寄与分解・閾値近傍）（§16） | 閾値の較正・診断 API 名（#170・#171） |

### 1.2 規律（契約）

1. **上流 5 文書の決定を本書で覆さない**。#166 §2.5 の期内処理順序・#166 §5 の残高更新式・#166 §6.2 の閉じ変数指定・#168 §4.1 の適用先 7 変数・[シナリオ時間軸](../architecture/scenario_time_semantics.md) §5.2 の時間形状 6 種は**そのまま用いる**。変更が必要な場合は §17 の差し戻し事項として登録し、当該文書の改訂で行う。
2. **恒等式で決まる量を行動方程式で二重に決めない**（#166 §1.2-2）。役割 `diagnostic` の変数には定義式のみを与え、行動方程式を書かない。
3. **期内に同時方程式を作らない**。すべての循環参照は 1 期以上の遅れで断つ（§3.3）。反復解法・不動点解法・非線形ソルバを `simulate` の期内処理に用いない。
4. **不整合を自動補正しない**（[ADR 0007](../adr/0007-sfc-integration-contract.md) §5 を継承）。符号制約違反・非有限値・会計違反を丸め・クリップ・辻褄合わせで消さない。**経済的な制約（`max(·, 0)` 等）と数値ガードを区別する**（§15.1）。
5. **含めない責務を方程式として実装しない**（[責務境界](capex_credit_cycle_model_boundaries.md) §4.1 の 12 件）。特に政策反応関数・一般物価動学・デフォルト・家計金融資産・個別主体最適化を導入しない。
6. **適用先 7 変数以外に外生入力を作らない**（[イベント変換契約](../architecture/macro_event_contract.md) §4.1）。`control` 変数へ外生入力を直接書き込まない。
7. **暫定既定値と確定値を区別する**。本書が与える関数形は確定、パラメータ値は #170 の較正対象である。関数形の選択理由を記載できない式を採用しない。

### 1.3 表記

| 記法 | 意味 |
|---|---|
| `x` / `x_t` | 当期（`t` 期）の値 |
| `x[t−1]` | 前期末値（＝当期期首、`BOP`） |
| `x[t−k]` | `k` 期前の値（遅延バッファ、#165 §4.3） |
| `x^{ss}` | 定常状態（baseline）の値 |
| `Δx` | `x − x[t−1]` |
| `s ∈ SP` | 生産部門 `{S2, S3}` |
| `s ∈ SF` | 財務主体 `{S1, S2, S3}` |
| `s ∈ SR` | 実体部門 `{S1, S2, S3, S5}` |
| `s'` | `s ∈ SP` の相手部門。初期MVPでは `s = S2 → s' = S3` のみ（`X06` が `EXT`） |
| `I_s` | 資本形成支出。`s = S1` では `capex_exec_s1`、`s ∈ SP` では `invest_s`（#166 §5.4） |
| `Δt` | `0.25`（年） |
| `≡ 0` | 初期MVPで恒等的ゼロだが式に独立項として保持する項 |
| `[T1]` / `[T2]` / `[T3]` | 数値ガードの層（§15.1） |
| `†` | 本書が上流へ差し戻す論点（§17） |

**式番号**: 方程式には `Ennn` 形式の番号を与える（`E` = equation）。因果グラフのエッジ ID（`Lnn`）とは別体系であり、各式の「由来」欄でエッジ ID を参照する。

---

## 2. モデル形式の確定

### 2.1 候補方式の比較

| 軸 | (a) 四半期連立差分方程式 | (b) 連続時間 ODE を四半期観測 | (c) ハイブリッド（即時関係=代数式・残高=差分式） |
|---|---|---|---|
| **会計恒等式の閉じ方** | 期次で閉じる。#166 §8.1 の 12 項目を各期で検証できる | ODE の状態に会計恒等式が成立しても、四半期観測点で「フローの四半期合計」が閉じることは保証されない。区間積分の離散化誤差が残差として現れ、`atol = 1e-8` の許容誤差に収まらない | (a) と同じく期次で閉じる |
| **閾値の扱い** | 閾値の跨ぎが期の境界で起きるため決定論的 | 閾値通過時点が積分刻みに依存する。`L06`・`L15`・`L30`・`L32`・`L40` の 5 閾値すべてが刻み幅感応になる | (a) と同じ |
| **イベント適用** | [シナリオ時間軸](../architecture/scenario_time_semantics.md) §3.2 の期首一括適用と直接整合 | 期首一括適用を ODE へ写すと不連続な状態ジャンプになり、剛性の高いソルバが必要になる | (a) と同じ |
| **同時性の解法** | 期内の同時方程式を非線形ソルバで解く必要が生じうる | 同時性は ODE 右辺の代数関係として現れる | **同時方程式を作らない**（すべての循環を遅れで断つ） |
| **既存実装との関係** | `SIM` 型 SFC（`src/models/sim_sfc.jl`）と同型 | `Keen`（`src/models/keen.jl`）と同型。ただし `ODESolverOptions`・`guard_max` は Keen 固有の機構であり、独立モデルとして継承しない（[ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md) §1.2） |
| **`transition_path` API** | 前向き期待を持たないため実装しない（[責務境界](capex_credit_cycle_model_boundaries.md) §2.6） | 同上 | 同上 |
| **説明可能性** | 各期の各式が独立に追跡できる | 状態の時間微分としてのみ追跡でき、「どの式が結果を生んだか」が四半期出力から辿りにくい | (a) より強い。**評価順序が一意なため各変数の生成箇所が 1 つに定まる** |
| **計算量** | 期内ソルバの反復が入ると 28 期 × スイープ格子点数だけ増える | 剛性ソルバの評価回数が支配的 | 28 期 × 定数回。スイープ（Q1・Q4・Q5）に耐える |

### 2.2 決定

**決定: (c) ハイブリッド方式を採用する。すなわち、期内の関係はすべて代数式として逐次評価し（陽解法）、ストックは 1 階差分式で更新する。期内に同時方程式・反復解法を置かない。**

**根拠を優先順に示す。**

1. **#166 §2.5 が既に一意な評価順序を与えている**。10 ステップの期内処理順序と「意思決定はすべて期首ストックを参照する」規約により、期内の関係は評価順序に沿って一方向に解ける。同時方程式が残る唯一の箇所（`L41` の遅れ `0`）は #166 §2.4・確定記録 `B7` で遅れ `1` に確定済みである。**同時方程式を導入する積極的な理由が存在しない**。
2. **会計恒等式の検証力を保つ**。#166 §8 の 12 項目は期次の残差で検証される。ODE を四半期観測する方式では離散化誤差が残差に混入し、「会計が閉じていない」のか「積分誤差なのか」を区別できない。会計整合性が本モデルの必要条件（#166 §12-9）である以上、この区別を失ってはならない。
3. **閾値の刻み幅感応を構造的に排除する**。本モデルの非線形性は 5 つの閾値（§16.4）に集中しており、契約 Q5 は「分岐が数値解法の産物でないこと」の確認を #170 に要求している。離散時間・陽解法では閾値通過が期の境界に限定され、刻み幅という自由度が存在しない。
4. **イベント適用と整合する**。[シナリオ時間軸](../architecture/scenario_time_semantics.md) §3.2 の期首一括適用（ステップ 1）は離散時間の期首という概念を前提としている。
5. **再現性の契約を満たしやすい**。[イベント変換契約](../architecture/macro_event_contract.md) §6.5 は `(model_version, …, solver_settings)` の一致で同一数値結果を要求する。陽解法では `solver_settings` に含まれる自由度が数値ガードの閾値のみであり、反復解法の収束判定・初期値依存が入らない。

**帰結（後続へ引き渡す）**

| 帰結 | 内容 |
|---|---|
| `simulate` | 前向き反復のみ。`for t in -8:19` の単一ループで完結する |
| `steady_state` | 定常状態を数値的に解かず、**定常水準を与えて構造パラメータを逆算する**（§14.2）。`steady_state(m)` は与えられた定常水準を返し、§14.3 の整合条件を検証する |
| `impulse_response` | baseline と衝撃シナリオの 2 実行の差として構成する |
| `transition_path` | **実装しない**（前向き期待を持たない） |
| 依存パッケージ | 期内ソルバを持たないため `NLsolve` / `JuMP` を必要としない。§14.2 の逆較正も閉形式である |

### 2.3 主体最適化・均衡求解を導入しない決定

| 検討 | 内容 |
|---|---|
| **決定** | 主体の動的最適化問題・期間内均衡の求解を置かない。すべての行動方程式を**部分調整・閾値・飽和の組み合わせ**として与える |
| **根拠 1** | [責務境界](capex_credit_cycle_model_boundaries.md) §4.1 の `4-5`（個別企業の最適化問題・合理的期待均衡）が「含めない」で確定しており、`ModelCapabilityProfile` は `optimization = :none`・`behavioral_equations = true`・`equilibrium_concept = :none` を申告する（同 §2.6） |
| **根拠 2** | 最適化を置くと期内に不動点求解が入り、§2.2 の決定（陽解法）と両立しない |
| **根拠 3** | 期待は `expectations = :static` を申告している（同 §2.6）。前向き期待を持たない主体に動的最適化を与えると、申告と実装が乖離する |
| **帰結** | 「均衡」という語を出力・説明で用いない。定常状態は「安定した基準経路」であり均衡概念ではない（§14.1） |

---

## 3. 期内処理順序と同時性の解法

### 3.1 期内処理順序（#166 §2.5 を継承）

**契約**: 下表の順序は #166 §2.5 で確定済みであり、本書は変更しない。本書が追加するのは、`A1` の解決（因果グラフ `1.1.0`）で生じた変数（`y_s1`・`ycap_s1`・`sales_s1`・`cons_s1`・`cons_s5`）の**ステップ割当**のみである。これは順序の変更ではなく、既存ステップへの変数追加である。

| # | ステップ | 本書の節 | 決まる主な量 | 参照する時点 |
|---|---|---|---|---|
| 1 | 外生入力の適用 | §4 | `ai_exp`・`price_s1`・`policy_rate`・`spread_shock_ex`・`capex_plan_shock_ex`・`ext_demand_s` | — |
| 2 | 金融条件の決定 | §5 | `fin_cond`・`spread`・`spread_endo`・`lend_stance`・`equity_val`・`collateral`・`rollover`・`cost_capital_s`・`r_eff_s`・`matur_s`・`refin_s`・`repay_s`・`int_burden_s` | 期首ストック・前期内生値 |
| 3 | 計画 | §6 | `compute_dem`・`target_cap_s1`・`capex_plan_s1`・`capex_plan_eff_s1`・`cancel_s1`・`capex_cancel_s1`・`invest_plan_s` | 期首 `cap_s`・`capex_pipe_s`・`plan_carry_s1` |
| 4 | 資金制約と実行 | §7 | `tax_s`・`div_s`・`newdebt_max_s`・`capex_fundable_s1`・`capex_defer_s1`・`capex_exec_s1`・`invest_s`・`capex_sx_s1`・`inv_sx_s`・`equity_issue_s`（`≡ 0`） | 期首 `cash_s`・`debt_s`、前期 `ocf_s` |
| 5 | 受注配分 | §8 | `order_cap_s`・`order_inv_s`・`order_gen_s`・`order_s` | 当期 `capex_exec_s1`、前期 `invest_s`・`y_s5`・`price_s` |
| 6 | 生産・出荷 | §9 | `ycap_s`・`y_s`・`ship_s`・`deliv_s`・`util_s`・`price_s`・`y_s1`・`ycap_s1` | 期首 `cap_s`・`backlog_s`・`inv_s` |
| 7 | 所得・支出 | §10 | `emp_s`・`emp_tot`・`wage`・`wagebill_s`・`tax_hh`・`hh_income`・`cons`・`cons_s1`・`cons_s5`・`xdem_s5`・`y_s5` | 当期 `y_s`・`y_s1`・`capex_exec_s1` |
| 8 | 収益・分配 | §11 | `sales_s`・`im_s`・`va_s`・`dep_s`・`profit_s`・`margin_s`・`dinv_s`・`ocf_s`・`y_tot`・`coverage_s`・`leverage_s`・`newdebt_s`・`nlb_s`・`s5_net_sx` | 当期フロー、期首 `debt_s` |
| 9 | 残高更新 | §12 | `capstart_s`・`cap_s`・`capex_pipe_s`・`inv_s`・`invval_s`・`backlog_s`・`cash_s`・`debt_s`・`plan_carry_s1`・`nw_s`・`loans_s4`・`dep_stock_s4`・`fund_s4` | 期首ストック + 当期フロー |
| 10 | 会計検証・診断 | §16 | #166 §8 の恒等式、契約 §4 の診断ラベル、`funding_pressure_s`、ループ利得 | 期首・期末・当期フロー |

**注意**: `int_burden_s`・`repay_s` はステップ 2 で確定する（期首 `debt_s` と当期 `r_eff_s`・`rollover` のみに依存する）。#166 §2.5 はこれらをステップ 4・8 に挙げているが、ステップ 4 の資金制約が `repay_s`・`int_burden_s` を必要とするため、生成をステップ 2 へ前倒しする。**参照する時点は変わらない**（いずれも期首 `debt_s`）ため、順序の変更には当たらない。

### 3.2 同一四半期内で参照してよい値の規約

| 参照 | 可否 | 根拠 |
|---|---|---|
| 同一ステップ内で先に確定した当期値 | 可 | 式の記載順が評価順である |
| 先行ステップで確定した当期値 | 可 | §3.1 の順序 |
| 後続ステップの当期値 | **不可** | 陽解法が壊れる。§3.3 の表に列挙した遅れで断つ |
| 前期末ストック `x[t−1]` | 可（推奨） | #166 §2.4「意思決定はすべて期首ストックを参照する」 |
| `k` 期前のフロー `x[t−k]` | 可（`k ≤ lag_depth`） | #165 §4.3 の遅延バッファ |
| baseline 系列 `x^{base}` | **不可** | モデルは baseline 比乖離を生成しない（#165 §5.1）。基準水準が必要な場合は構造パラメータ（`st_*_ref`）として与える |

### 3.3 循環参照の切り方（全循環の列挙）

因果グラフ `1.1.0` の全有向閉路について、どのエッジをどの遅れで断つかを列挙する。**この表に無い循環が実装中に見つかった場合、それは本書の欠落であり、遅れを実装者が独自に決めない**（§17 へ差し戻す）。

| # | 閉路 | 断つエッジ | 遅れ | 根拠 |
|---|---|---|---|---|
| 1 | `R1a`: `CAPEX_EXEC → CAP_S1 → Y_S1 → SALES_S1 → PROFIT_S1 → OCF_S1 → CASH_S1 → CAPEX_EXEC` | `L41`（`CASH_S1 → CAPEX_EXEC`） | 1（期首 `cash_s1`・前期 `ocf_s1`） | #166 §2.4・確定記録 `B7`。`L08` も遅れを持つが `L41` の遅れが必須 |
| 2 | `R1b`: `ORDER_s → BACKLOG_s → Y_s → SALES_s → PROFIT_s → OCF_s → CASH_s → INVEST_s → ORDER_{s'}` | `L62`（`CASH_s → INVEST_s`） | 1（期首 `cash_s`・前期 `ocf_s`） | `L41` と同一の理由（因果グラフ §3.5） |
| 3 | R2: `PROFIT_s → OCF_s → COVERAGE_s → SPREAD → COST_CAPITAL_s → CAPEX_PLAN → CAPEX_EXEC → ORDER_s → … → PROFIT_s` | `L30`（`COVERAGE_s → SPREAD`） | 1（`coverage_agg[t−1]`） | 因果グラフ `L30` の遅れ `1`。ステップ 2（金融条件）がステップ 8（収益）より前にあるため必須 |
| 4 | R2 短絡: `SPREAD → INT_BURDEN_s → COVERAGE_s → SPREAD` | `L30`（同上） | 1 | 同上。§16.3 で独立に利得評価する |
| 5 | R3: `PROFIT_s → EQUITY_VAL → COLLATERAL → ROLLOVER → CAPEX_EXEC → ORDER_s → … → PROFIT_s` | `L27`（`PROFIT_s → EQUITY_VAL`） | 1（`profit_s[t−1]`） | 因果グラフ `L27` の遅れは `0` だが、ステップ 2 がステップ 8 より前にあるため遅れ `1` を採る（§17 の `E4`） |
| 6 | R4: `Y_s → EMP → HH_INCOME → CONS → Y_S5 → ORDER_s → BACKLOG_s → Y_s` | `L50`（`Y_S5 → ORDER_s`） | 1（`y_s5[t−1]`） | 因果グラフ `L50` の遅れ `1–2` の下限。ステップ 5 がステップ 7 より前にあるため必須 |
| 7 | R4 賃金副経路: `EMP → WAGE → HH_INCOME → CONS → Y_S5 → ORDER_s → … → EMP` | `L45`（`EMP → WAGE`） | 3（`emp_tot[t−3]`） | 因果グラフ `L45` の遅れ `2–4` の中央値 |
| 8 | 価格・数量: `UTIL_s → PRICE_s → ORDER_s → … → Y_s → UTIL_s` | `L16`（`UTIL_s → PRICE_s`）と `L17`（`PRICE_s → ORDER_s`） | `L16`: 1（`util_s[t−1]`）、`L17`: 3（`price_s[t−3]`） | 因果グラフ `L16` `1–2` の下限・`L17` `2–4` の中央値 |
| 9 | 在庫循環: `Y_s → INV_s → Y_s` | `L15`（`INV_s → Y_s`） | 1（`inv_ratio_s[t−1]`） | 因果グラフ `L15` の遅れ `1–2` の下限 |
| 10 | 部門内投資: `Y_s → INVEST_s → CAP_s → Y_s` | `L18`（`Y_s → INVEST_s`） | 1（`y_s[t−1]`） | 因果グラフ `L18` の遅れ `1–2` の下限。`L57` も遅れを持つ |
| 11 | 実効金利: `SPREAD → R_EFF_s → INT_BURDEN_s → COVERAGE_s → SPREAD` | `L30`（同 #3） | 1 | `r_eff_s` は自身の前期値を参照する状態変数（#166 §5.4） |
| 12 | 資本コストと現金: `CASH_s → CAPEX_EXEC → … → CASH_s`（`L39` の state-dep 経由） | `L41` / `L62`（同 #1・#2） | 1 | `L39`・`L64` の state-dep は期首 `cash_s` を参照する |

**契約**:

- 遅れの選択規則を固定する。因果グラフの遅れが**幅**で与えられている場合（`1–2`・`2–4`）、(i) 循環を断つために必要なら**下限**を採る、(ii) 単なる伝達遅れなら**中央値**を採る（`2–4` なら 3）。この規則により実装者が遅れを恣意的に選ばない。採用値は §13.5 の遅延パラメータ表に記載する。
- 遅れの深さ `k` は #165 §4.3 の `lag_depth`（因果グラフの遅れの上限値）を**超えない**。
- 遅延バッファは `state_variables` に含める（#165 §6.1）。`t = -8` の初期化は定常値で埋める（§14.4）。

### 3.4 期内で「同時」に見えて逐次である関係

誤って同時方程式と判断されやすい箇所を明示する。

| 関係 | 見かけ上の同時性 | 実際の解法 |
|---|---|---|
| `util_s = y_s / ycap_s` と `y_s ≤ bh_util_max_s · ycap_s` | 稼働率と産出の相互決定 | `ycap_s` は期首 `cap_s[t−1]` から確定（`ycap_s = cap_s[t−1] / st_cor_s`）。`y_s` を先に決めてから `util_s` を計算する一方向 |
| `ship_s` と `inv_s`・`backlog_s` | 出荷と残高の相互決定 | `ship_s` は期首残高と当期 `y_s` から確定（`E9-08`）。残高更新はステップ 9 |
| `profit_s` と `sales_s`・`wagebill_s` | 利益と費用の相互決定 | `profit_s` は会計残差であり、`sales_s`（ステップ 8）・`wagebill_s`（ステップ 7）・`dep_s`（ステップ 8）が確定した後に一意に決まる |
| `newdebt_s` と `Δcash_s` | 資金調達と現金残高の相互決定 | `newdebt_s` は現金恒等式の閉じ変数（`E11-14`）。当期フローがすべて確定した後に一意に決まる |
| `capex_exec_s1` と `capex_defer_s1` | 実行額と延期額の相互決定 | `capex_defer_s1` を先に決め（`E7-11`）、`capex_exec_s1` を恒等式 1 の残余として求める（`E7-12`） |
| `cons` と `y_s5` | 消費と一般経済産出の相互決定 | `cons` は当期 `hh_income` から決まり（`E10-11`）、`y_s5 = cons_s5 + xdem_s5` はその後（`E10-14`）。`y_s5` が `order_gen_s` へ戻るのは翌期（`L50` の遅れ 1） |

---

## 4. ステップ 1: 外生入力とショックの適用

### 4.1 モデル層が受け取るもの

[イベント変換契約](../architecture/macro_event_contract.md) §7.2・§7.3 に従い、モデル層は**期別・変数別の合成済み外生パス**のみを受け取る。イベント属性・解釈・原文を保持しない。

```
E4-01   exog[v] :: Vector{Float64}     v ∈ {ai_exp, capex_plan_shock_ex, spread_shock_ex,
                                             policy_rate, ext_demand_s2, ext_demand_s3, price_s1}
```

**契約**:

- 上記 7 変数以外に外生入力を作らない（[イベント変換契約](../architecture/macro_event_contract.md) §4.1・[ADR 0010](../adr/0010-macro-event-scenario-contract.md) 決定 2）。
- モデル層はイベントの合成・適用四半期の決定・単位の解釈を行わない。合成は #168 §5.2、適用四半期は[シナリオ時間軸](../architecture/scenario_time_semantics.md) §4.3 で確定済みである。
- 助走区間（`t = -8 … -1`）では全外生変数が定常値に等しいことを要件とする（契約 §2.1）。違反した期を `runup_deviation` として警告する（§15.5）。

### 4.2 外生変数の baseline 値と反映式

[シナリオ時間軸](../architecture/scenario_time_semantics.md) §5.3 の反映式（`:multiplicative` は `x = x^{base}·(1 + a/100)`、`:additive` は `x = x^{base} + a`、`:absolute` は `x = a`）を適用するには、各外生変数の **baseline 値**が確定していなければならない。本書で確定する。

| 変数 | モデル内の型 | baseline 値 | `application_mode` | モデル内での使われ方 |
|---|---|---|---|---|
| `ai_exp` | 無次元指数 | `1.0` | `:multiplicative` | `E6-01` の需要水準の乗数 |
| `capex_plan_shock_ex` | 無次元**乗数** | `1.0` | `:multiplicative` | `E6-05` の計画CAPEX の乗数 |
| `price_s1` | 無次元指数 | `1.0` | `:multiplicative` | `E11-02` の売上換算 |
| `spread_shock_ex` | bp | `0.0` | `:additive` | `E5-04` のスプレッド加算項 |
| `policy_rate` | 年率 % | `st_pol_ref` | `:additive` / `:absolute` | `E5-01` の金融環境・`E5-11` の新規調達金利 |
| `ext_demand_s2` / `_s3` | 10億ドル/四半期（数量） | `st_extdem_s^{ss}` | `:multiplicative` / `:additive` / `:absolute` | `E8-04` の一般需要成分 |

**契約**:

- **`capex_plan_shock_ex` はモデル内では無次元の乗数であり、baseline 値は `1.0` である**。#165 §5.2 は単位を「baseline比 %」と記載しているが、これは**イベント側の magnitude の単位**であり、モデル内変数の単位ではない。`:multiplicative` の反映式に baseline `1.0` を与えることで、`-15%` のイベントは `capex_plan_shock_ex = 0.85` として渡る。この読み替えを実装者が独自に判断しないよう明記する。#165 の単位欄の明確化を §17 の差し戻し `E3` として登録する。
- **`ai_exp`・`price_s1` も同様に baseline `1.0` の無次元指数である**（#165 §5.1「`index` 型の変数は baseline 定常値 = `1.0` を基準とする」と整合）。
- `ext_demand_s` の baseline は定常水準であり `1.0` ではない。`:multiplicative` の反映式は定常水準に対する比として作用する。

### 4.3 単位換算（年率金利 → 四半期）

[シナリオ時間軸](../architecture/scenario_time_semantics.md) §5.3 は「四半期モデルにおける年率金利の期間換算は #169 の責務であり、イベント層では年率のまま渡す」と定めている。本書で確定する。

```
E4-02   r_new_s = (policy_rate + spread / 100) / 100          … 年率、小数（decimal）
E4-03   int_burden_s = r_eff_s · Δt · debt_s[t−1]             … 四半期の利払い額（#166 §5.4）
```

| 論点 | 決定 | 根拠 |
|---|---|---|
| bp → %pt | `spread / 100`（`100bp = 1%pt`）。**モデル層で明示的に換算し、換算式を出力の methodology metadata へ記録する** | [シナリオ時間軸](../architecture/scenario_time_semantics.md) §5.3 は「イベント側で暗黙に換算しない」ことを要求しており、モデル層が換算する主体である |
| 年率 % → 小数 | `/ 100` | — |
| 年率 → 四半期 | **単利換算 `r · Δt`**（`Δt = 0.25`）。複利換算 `(1 + r)^{0.25} − 1` を用いない | #166 §5.4 が `int_burden_s = r_eff_s · Δt · debt_s[t−1]` を既に確定している。本書はこれを変更しない。単利と複利の差は `r = 0.05` で約 0.03%pt/年であり、`atol = 1e-8`（#166 §8.2）に対しては無視できない大きさだが、**会計恒等式は単利定義のもとで閉じる**ため整合性は保たれる。近似の帰結は §19-4 に記載する |
| 満期到来率 | `φ_s = Δt / st_maturity_s`（`st_maturity_s` は年） | #166 §5.4 |
| `cost_capital_s` の単位 | 年率 %（#165 §5.4）。**四半期換算しない**（投資関数へ弾性として入るため水準の比較でよい） | `L39`・`L64` は弾性であり、期間換算は不要 |

**契約**: `spread`（bp）と `policy_rate`（年率 %）と `cost_capital_s`（年率 %）は**単位が異なる**。加算する箇所（`E4-02`・`E5-12`）で必ず換算を明示し、換算せずに加算しない。

---

## 5. ステップ 2: 金融条件

`S4` の意思決定と、期首債務から確定する利払い・返済を決める。すべて期首ストックと前期内生値のみを参照する（§3.2）。

### 5.1 金融環境と株式評価

```
E5-01   fin_cond = (1 − bh_fc_adj) · fin_cond[t−1]
                 + bh_fc_adj · bh_fc_pol · (policy_rate − st_pol_ref)            （L53）

E5-02   equity_val = (1 − bh_ev_adj) · equity_val[t−1]
                   + bh_ev_adj · (1 + bh_ev_elas · (Σ_{s∈SF} profit_s[t−1] / st_profit_ref − 1))
        equity_val ← max(equity_val, st_ev_min)                                  （L27）[T1]

E5-03   collateral = st_coll_ltv · (Σ_{s∈SF} (cap_s[t−1] + capex_pipe_s[t−1]) + Σ_{s∈SP} invval_s[t−1])
                     · equity_val^{bh_coll_elas}                                 （L31）
```

| 式 | 由来 | 設計判断 |
|---|---|---|
| `E5-01` | `L53`（`POLICY_RATE → FIN_COND`、遅れ `0–1`） | 部分調整で遅れ `0–1` を表現する。`bh_fc_adj = 1` なら遅れ 0、小さいほど伝達が遅い。`fin_cond` は引締が正の標準化指数であり、baseline 定常値は `0`。#165 §6.2 が挙げた `pl_pass_through`（政策金利伝達係数）は `bh_fc_pol` として実装し、政策変数ではなく**行動パラメータ**に分類する（貸し手の反応であり制度設定ではない） |
| `E5-02` | `L27`（`PROFIT_s → EQUITY_VAL`） | 利益の**基準値比**に対する弾性として定式化する。`equity_val` は baseline 定常値 `1.0` の指数であり（#165 §5.4）、水準の利益を直接代入できないため基準値 `st_profit_ref = Σ profit_s^{ss}` で正規化する。`profit_s[t−1]` を用いるのは §3.3 の #5（R3 の循環を断つ）ため。下限 `st_ev_min > 0` は `E5-03` の冪演算と `E5-12` の定義域を守るための**経済制約**（§15.1 の T1） |
| `E5-03` | `L31`（`EQUITY_VAL → COLLATERAL`） | 担保は**実物資産の期首残高**に評価率 `st_coll_ltv` を掛け、株式評価で修正する。株式を貸借対照表に持たない（#166 §3.4）ため、`equity_val` は担保**評価の修正係数**としてのみ入る。`bh_coll_elas = 0` なら株価は担保に影響しない（`credit-off` では固定しない — 担保経路は `L40` の弾性で切る） |

### 5.2 スプレッドと貸出態度

```
E5-04   spread_endo = st_spread0
                    + bh_spread_cov · max(0, bh_cov_threshold − coverage_agg[t−1])^{bh_spread_pow}
                    + bh_spread_fc · fin_cond[t−1]                               （L30・L54）
E5-05   spread = max(0, spread_endo + spread_shock_ex)                           [T1]

E5-06   lend_stance = − bh_lend_spread · (spread[t−1] − st_spread0)               （L33）

E5-07   rollover = clamp(1 − bh_roll_slope · max(0, Σ_{s∈SF} debt_s[t−1] / collateral − pl_ltv),
                         0, 1)                                                    （L32）[T1]
```

| 式 | 由来 | 設計判断 |
|---|---|---|
| `E5-04` | `L30`（threshold）・`L54`（linear） | **本モデルの非線形性の中核**（`NL-3`、§16.4）。カバレッジが閾値 `bh_cov_threshold` を上回る領域では第 2 項が恒等的に 0 であり、スプレッドはカバレッジに反応しない。閾値を下回ると `bh_spread_pow`（凸性指数、`1 ≤ pow ≤ 3`）の冪で急拡大する。`pow = 1` は折れ線、`pow > 1` は閾値近傍でも緩やかに立ち上がる形になる。線形化してはならない（因果グラフ R2 の注記） |
| `E5-05` | 因果グラフ §3.4 の「内生成分と外生成分を分離して出力する」 | `spread_endo`（内生成分）と `spread_shock_ex`（外生成分）を**別変数として出力する**。`SH-CREDIT` の効果を内生反応と混同しないため。`spread ≥ 0` は経済制約（負のスプレッドを許さない）であり T1 |
| `E5-06` | `L33`（`SPREAD → LEND_STANCE`、遅れ `1`、符号 `−`） | `lend_stance` は緩和方向が正の標準化指数（#165 §5.4）であり baseline 定常値は `0`。スプレッド拡大が引締め（負）方向へ作用する |
| `E5-07` | `L32`（threshold、LTV・財務制限条項） | **非線形性 `NL-4`**。担保余裕がある間（`Σdebt / collateral ≤ pl_ltv`）は `rollover = 1`（全額借換可能）。LTV 上限を超えると線形に低下する。`clamp(·, 0, 1)` は #165 の範囲制約（`0 ≤ rollover ≤ 1`）を式として満たすための T1 |

**ゼロ除算**: `E5-07` の `collateral` が `div_eps` 以下のとき `rollover = NaN` とし、`:rollover_invalid` を記録する（§15.4）。`collateral = 0` は全部門の実物資産がゼロの状態であり、通常のシミュレーションでは発生しない。

### 5.3 実効金利・満期・返済

```
E5-08   φ_s = Δt / st_maturity_s                                                （s ∈ SF）
E5-09   matur_s = φ_s · debt_s[t−1]                                             （#166 §5.4）
E5-10   refin_s = rollover · matur_s                                            （L32 → L63）
E5-11   repay_s = matur_s − refin_s = (1 − rollover) · matur_s                   （L63）
E5-12   r_new_s = (policy_rate + spread / 100) / 100                             （L35・L56）
E5-13   r_eff_s = (1 − φ_s) · r_eff_s[t−1] + φ_s · r_new_s                       （#166 §5.4）[state]
E5-14   int_burden_s = r_eff_s · Δt · debt_s[t−1]                                （L34）
E5-15   rollover_gap_s = (1 − rollover) · matur_s = repay_s                      （#166 §7.3）
```

| 論点 | 決定 |
|---|---|
| **`L35`（`SPREAD → INT_BURDEN_s`）の遅れ `1–4` の実装** | 満期構成による幾何的な浸透として表現する。`E5-13` により当期のスプレッド変化は債務の `φ_s` の割合にのみ反映され、平均遅れは `1/φ_s = st_maturity_s / Δt` 期になる。`st_maturity_s = 5` 年なら 20 期。**遅延バッファを持たない**（`r_eff_s` が状態として履歴を保持する） |
| **`L56`（`POLICY_RATE → INT_BURDEN_s`）の遅れ `1–2`** | 同じ `E5-13` の機構で表現する。政策金利も `r_new_s` を通じて借換分にのみ作用する。専用のラグを追加しない |
| **借換と新規調達の金利** | 同一（`r_new_s`）。借換分と新規調達分の金利差を持たない。初期MVPで満期別の債務構成を持たないため（#166 §3.1 の「部門別の満期・商品構成を識別する観測系列が無い」） |
| **`r_eff_s` の下限** | `r_eff_s ≥ 0`。`policy_rate ≥ 0`（#165 の符号制約）かつ `spread ≥ 0`（`E5-05`）より構造的に保証される。個別のクリップを置かない |

### 5.4 資本コスト

```
E5-16   cost_capital_s = max(0,
              st_cc0_s
            + bh_cc_spread · spread / 100
            − bh_cc_lend · lend_stance
            − bh_cc_equity · (equity_val − 1)
            + bh_cc_fc · fin_cond )                                    （L36–L38・L55）[T1]
```

| 論点 | 決定 |
|---|---|
| 単位 | 年率 %。`spread` は bp なので `/100` で %pt へ換算する（§4.3） |
| 合成方式 | 因果グラフ `L36` の「加重合成」を線形合成として実装する。`st_cc0_s` は定常状態の資本コスト水準 |
| `credit-off` での扱い | **`cost_capital_s` は固定しない**。固定するのは `L39`・`L64` の弾性（`bh_cc_elas_s1`・`bh_cc_elas_inv_s`）である。資本コスト自体は診断として出力し続ける（§16.5） |
| 出力上の制約 | `cost_capital_s` は潜在変数（観測コード `L`）であり、`SimulationResult.variables` へ出力するが**単独の水準を LLM 説明・可視化で提示しない**（#165 §5.4 の契約） |

### 5.5 集約カバレッジ

```
E5-17   coverage_agg = Σ_{s∈SF} ocf_s[t−1] / Σ_{s∈SF} int_burden_s[t−1]         （#165 §5.4）
```

| 論点 | 決定 |
|---|---|
| 定義 | **水準の総和の比**とする。#165 §5.4 の「`coverage_agg = Σ ocf_s / Σ int_burden_s`（加重は債務残高）」の 2 つの記述のうち、前者（総和の比）を採る。総和の比は各部門の `coverage_s` を `int_burden_s`（したがって `debt_s` と `r_eff_s`）で加重した平均に等しいため、両記述は一致する |
| 時点 | 前期値。§3.3 の #3・#4（R2 とその短絡ループ）を断つため |
| ゼロ除算 | `Σ int_burden_s[t−1] ≤ div_eps` のとき `coverage_agg = NaN`。この場合 `E5-04` の第 2 項を **`0` として評価する**（`NaN` を伝播させない）。根拠: 利払いがゼロの状態は「カバレッジが十分高い」ことを意味し、閾値を下回らない。この読み替えを行う箇所は本式のみであり、`coverage_agg` 自体は `NaN` として出力する（§15.4） |

---

## 6. ステップ 3: 計画

### 6.1 期待需要

**Issue #169 §2 が挙げた 3 つの期待更新方式を比較する。**

| 方式 | 内容 | 採否 |
|---|---|---|
| (i) 適応的期待 | `compute_dem = compute_dem[t−1] + λ · (実現需要[t−1] − compute_dem[t−1])` | **不採用**。実現需要から期待へのエッジ（`SALES_S1 → COMPUTE_DEM` 等）が因果グラフに存在しない。追加すると `X04`（期待の内生化、`EXT`）に該当し、因果グラフ §3.2 の「`E1` ショックの識別が困難になる」理由で除外されている |
| (ii) ガイダンス・イベントによる外生修正のみ | `compute_dem = st_cd0 · ai_exp`（`ai_exp` は外生指数、時間形状は #168 §5.2 の 6 種） | **採用** |
| (iii) 直近実績と外部シナリオの加重 | (i) と (ii) の加重平均 | **不採用**。(i) を含むため同じ理由で除外。加えて加重を識別する観測量が無い |

```
E6-01   compute_dem = st_cd0 · ai_exp                                            （L01）
```

**採用理由**

1. **期待の動学は `ai_exp` の時間形状が担う**。`SH-EXP` は `AR1_decay`（半減期 6 四半期、契約 §5.3）であり、期待の減衰・平均回帰はこの形状として与えられる。モデル内に部分調整をもう一段置くと、**同一の現象に 2 つの平滑化が掛かり `SH-EXP` の半減期が識別できなくなる**。
2. **`compute_dem` の役割が `control` のまま保たれる**。部分調整を置くと自身の前期値を参照するため遅延バッファが必要になり（#165 §4.3）、`lag_depth = 0` という #165 §5.2 の登録と矛盾する。
3. **期待の過剰反応・平均回帰は形状で表現できる**。過剰反応は `ramp` / `step_then_ramp`、平均回帰は `AR1_decay` の半減期で与える。形状を 6 種に固定する契約（[シナリオ時間軸](../architecture/scenario_time_semantics.md) §5.2-1）を守れる。

**clamp**: `ai_exp > 0` は #165 の符号制約であり、違反はイベント層が拒否する（[イベント変換契約](../architecture/macro_event_contract.md) §6.3）。モデル層で `compute_dem` をクリップしない。`compute_dem ≥ 0` は `st_cd0 > 0` と `ai_exp > 0` から構造的に保証される。

### 6.2 目標設備能力

```
E6-02   target_cap_s1 = st_cor_s1 · compute_dem / bh_util_tgt_s1                 （L02）
```

**目標稼働率の扱い**: `bh_util_tgt_s1` は「期待需要をこの稼働率で処理できる設備能力を目標とする」ことを表す。`bh_util_tgt_s1 < 1` であるため、目標設備能力は期待需要より大きい。

**設備ギャップの定義（設計判断）**

```
E6-03   capex_gap_s1 = target_cap_s1 − cap_s1[t−1] − capex_pipe_s1[t−1]          （L04）
```

| 選択肢 | 内容 | 採否 |
|---|---|---|
| (a) 建設中資本を差し引く | `gap = target − cap[t−1] − capex_pipe[t−1]` | **採用** |
| (b) 稼働資本のみと比較 | `gap = target − cap[t−1]` | 不採用 |

**採用理由**: (b) では既に発注済み・建設中の案件がギャップを縮めないため、稼働開始までの `st_pipelag_s1` 期にわたって同じギャップに対して繰り返し発注が生じ、設備が目標を大きく超過する（二重発注によるオーバーシュート）。(a) はこれを構造的に防ぐ。

**帰結（明示しておくべき副作用）**: (a) を採ると、定常状態では `cap_s1 + capex_pipe_s1 = target_cap_s1` となり、**稼働資本 `cap_s1` は目標設備能力を下回る**。したがって定常稼働率は目標稼働率を上回る。

```
util_s1^{ss} = bh_util_tgt_s1 · (1 + st_pipelag_s1 · st_delta_s1)
```

`st_pipelag_s1 = 3`・`st_delta_s1 = 0.04` なら定常稼働率は目標の 1.12 倍である。これは `bh_util_tgt_s1` を「稼働資本に対する目標稼働率」ではなく「**建設中を含む総設備能力に対する目標稼働率**」と読むことを意味する。§14.3 の整合条件 `SS-6` でこの関係を検証する。

### 6.3 計画CAPEX

```
E6-04   capex_plan_raw_s1 = st_delta_s1 · cap_s1[t−1]
                          + bh_alpha_capex_s1 · capex_gap_s1                     （L03・L04）

E6-05   liq_s1 = min(1, max(0, cash_s1[t−1] / (st_cash_ref_s1 · sales_s1[t−1])))  （L39 の state-dep）[T1]

E6-06   cc_dev_s1 = cost_capital_s1[t−1] − st_cc0_s1                              （L39）

E6-07   capex_plan_s1 = max(0,
              capex_plan_raw_s1
              · (1 − bh_cc_elas_s1 · (1 − liq_s1) · cc_dev_s1)
              · capex_plan_shock_ex )                                             [T1]
```

| 式 | 由来 | 設計判断 |
|---|---|---|
| `E6-04` | `L03`（部分調整）・`L04`（設備ギャップ） | **維持投資（減耗補填）+ ギャップの部分調整**という標準的な加速度原理の形。`bh_alpha_capex_s1 ∈ (0, 1]` が調整速度。維持投資項を分離するのは、定常状態で `capex_plan_s1 = st_delta_s1 · cap_s1` が成立する（`capex_gap_s1 = 0`）ようにするため |
| `E6-05` | `L41` の saturating・`B2`（自己資金による耐性） | 流動性充足度 `liq_s1 ∈ [0, 1]`。現金が基準（`st_cash_ref_s1 · sales_s1`）以上あれば `1`、ゼロなら `0` |
| `E6-07` | `L39`（state-dep、`CASH_s` 依存） | **資本コスト弾性を流動性で減衰させる**。`liq_s1 = 1`（現金が厚い）のとき資本コスト上昇が計画へ伝わらない。これが `B2`（遮断経路）の実装箇所である。`capex_plan_shock_ex` は乗数（§4.2）。`max(0, ·)` は投資が負にならないための**経済制約**（T1） |

**`L05`（`CAPEX_PLAN → CAPEX_EXEC`）の下方非対称の所在**: `E6-07` は下方非対称を持たない。下方硬直性は §7.3 の契約確定額 `commit_s1`（既着工・契約済み分は当期に延期できない）として実装する。計画は自由に下方修正でき、**実行だけが硬直的**という構造であり、これが `B3`（CAPEX の不可逆性）の実装である。

### 6.4 キャンセル率

```
E6-08   plan_rev_s1 = (capex_plan_s1 − capex_plan_s1[t−1]) / max(capex_plan_s1[t−1], div_eps)

E6-09   cancel_s1 = clamp(bh_cancel_slope · max(0, − plan_rev_s1 − bh_cancel_thresh),
                          0, bh_cancel_max)                                        （L06）[T1]

E6-10   revive_s1 = bh_revive_s1 · plan_carry_s1[t−1]                               （#166 §5.3・§6.1）
        capex_plan_eff_s1 = capex_plan_s1 + revive_s1
E6-11   capex_cancel_s1 = cancel_s1 · capex_plan_eff_s1                             （L06・L07）
```

| 式 | 由来 | 設計判断 |
|---|---|---|
| `E6-09` | `L06`（threshold、計画下方修正幅が閾値超で発現） | **非線形性 `NL-1`**。計画の下方修正率が `bh_cancel_thresh`（例 `0.05` = 5%）以下ならキャンセルは発生しない。閾値を超えた分に `bh_cancel_slope` を掛け、`bh_cancel_max`（例 `0.5`）で上限を置く。`clamp` は #165 の範囲制約（`0 ≤ cancel_s1 ≤ 1`）を式として満たすための T1 |
| `E6-10` | #166 §5.3・§6.1 | 延期分の繰越のうち**当期に復活する分だけ**を有効計画へ戻す。#166 §5.3 の `plan_carry_s1 = plan_carry_s1[t−1] + capex_defer_s1 − （当期に復活した繰越分）` の「復活した繰越分」を `revive_s1 = bh_revive_s1 · plan_carry_s1[t−1]`（幾何的復活）として確定する。繰越残高を全額戻すと、延期が翌期に必ず復活して延期の意味が失われる。`capex_plan_eff_s1` は**恒等式 1**（`capex_plan_eff_s1 = capex_exec_s1 + capex_cancel_s1 + capex_defer_s1`）の左辺 |
| `E6-11` | #166 §6.1 | キャンセルは有効計画に対する比率として作用する |

**`SH-CAPEX` とキャンセル/延期の配分**: [イベント変換契約](../architecture/macro_event_contract.md) §4.4 は「キャンセルと延期の配分は指定せず、配分は #169 の行動方程式が決める」と定めている。本書の決定は次のとおりである。

| 経路 | 帰結 |
|---|---|
| `SH-CAPEX`（`capex_plan_shock_ex`、`step_then_ramp`）は `capex_plan_s1` を直接引き下げる | **キャンセルでも延期でもない**。計画そのものの一時的縮小であり、`step_then_ramp` の ramp 部分で自動的に復元する |
| 計画の下方修正が `bh_cancel_thresh` を超えると `cancel_s1 > 0` になる | **キャンセル**（永久に消える）。深いショックのみが恒久的損失を生む |
| 資金源が不足した残余 | **延期**（`plan_carry_s1` へ繰越、将来復活）。§7.3 |

この 3 分岐により、「一時的削減が延期であれば繰越として戻り、キャンセルであれば戻らない」（#166 §6.1）という要求を満たす。

### 6.5 部門投資の計画（`s ∈ SP`）

```
E6-12   ycap_tgt_s = y_s[t−1] / bh_util_tgt_s
E6-13   target_cap_s = st_cor_s · ycap_tgt_s                                        （L18）
E6-14   inv_gap_s = target_cap_s − cap_s[t−1] − capex_pipe_s[t−1]
E6-15   liq_s = min(1, max(0, cash_s[t−1] / (st_cash_ref_s · sales_s[t−1])))          [T1]
E6-16   invest_plan_s = max(0,
              ( st_delta_s · cap_s[t−1] + bh_alpha_inv_s · inv_gap_s )
              · (1 − bh_cc_elas_inv_s · (1 − liq_s) · (cost_capital_s[t−1] − st_cc0_s))
              · (1 + bh_lend_elas_inv_s · lend_stance[t−1]) )                        [T1]
```

| 式 | 由来 | 設計判断 |
|---|---|---|
| `E6-12`・`E6-13` | `L18`（部門内の加速度原理、遅れ `1–2`） | `S1` と同型。目標は**前期産出を目標稼働率で処理できる能力**。`y_s[t−1]` を用いるのは §3.3 の #10（部門内投資の循環）を断つため |
| `E6-14` | `L04` の `SP` 版 | `E6-03` と同じく建設中資本を差し引く（二重発注の防止） |
| `E6-16` | `L64`（資本コスト）・`L42`（貸出態度） | `S1` の `E6-07` と同型に資本コスト弾性を流動性で減衰させる。貸出態度は乗数として作用する（`lend_stance` は緩和が正、baseline `0`） |

**`SP` に計画/実行の分離を置かない決定**: `S1` は計画（`capex_plan_s1`）と実行（`capex_exec_s1`）を分離し、キャンセル・延期を明示的に持つ。`s ∈ SP` は分離せず、`invest_plan_s` から資金制約で直接 `invest_s` を得る（§7.4）。

| 根拠 | 内容 |
|---|---|
| 会計 | #166 §6.2 の恒等式 2'（`s ∈ SP`）には `capex_cancel` / `capex_defer` に相当する項が無い。閉じ変数は `invest_s` 自身である |
| 因果グラフ | `L06`（`CAPEX_PLAN → CANCEL`）・`L40`（`ROLLOVER → CAPEX_EXEC`）はいずれも `S1` のノードに接続しており、`SP` に対応するエッジが無い |
| 分析契約 | Q1–Q5 の判定量に `SP` のキャンセル率・延期額は現れない |
| 観測 | `SP` の計画投資（ガイダンス）を四半期で観測する系列が無い。`S1` は hyperscaler の CAPEX ガイダンスが観測できる（#165 §5.2） |

---

## 7. ステップ 4: 資金制約と実行

### 7.1 分配フロー（当期の資金需要を確定するために先に決める）

```
E7-01   tax_s = pl_tau_corp · max(0, profit_s[t−1] − int_burden_s[t−1])           （MVP: pl_tau_corp = 0）
E7-02   div_s = st_payout_s · max(0, profit_s[t−1] − int_burden_s[t−1] − tax_s[t−1])   [T1]
E7-03   equity_issue_s ≡ 0                                                        （#166 §6.3）
E7-04   writeoff_s ≡ 0                                                            （#166 §7.1）
E7-05   pipe_cancel_s ≡ 0                                                         （#166 §5.2、B3 完全不可逆）
E7-06   retire_s ≡ 0                                                              （#166 §5.1）
E7-07   valchg_s ≡ 0                                                              （#166 §5.7）
E7-08   advance_s ≡ 0                                                             （#166 §3.5、仮定 A-2）
```

**前期利益を用いる根拠**: `tax_s`・`div_s` はステップ 4 の資金制約に必要だが、当期 `profit_s` はステップ 8 で決まる。前期値を用いることで同時決定を避ける（§3.2）。配当・納税が前期業績に基づいて決まることは実務上も自然である。

**恒等的ゼロ項の扱い**: `E7-03`–`E7-08` は #166 §1.2-4 に従い**独立項として保持する**。式から削除せず、`SimulationResult.variables` へ 0 の系列として出力する。将来の拡張で値を入れるとき恒等式の形を変えない。

### 7.2 資金源の上限（資金調達順序）

#166 §6.2 は「資金調達の順序と各段階の上限は #169 が定める」としている。本書で確定する。

**資金調達順序（固定）**: ① 内部資金 → ② 現金取崩 → ③ 新規借入 → ④ 増資（`≡ 0`）→ ⑤ 延期 → ⑥（キャンセルは §6.4 で先に確定）

```
E7-09   internal_s  = ocf_s[t−1] − int_burden_s − tax_s − div_s − repay_s
E7-10   cash_free_s = max(0, cash_s[t−1] − st_cash_min_s · sales_s[t−1])          [T1]
E7-11   debt_cap_s  = max(0, (st_dcap_s + bh_dcap_lend_s · lend_stance) · sales_s[t−1])  [T1]
E7-12   newdebt_max_s = max(0, debt_cap_s − (debt_s[t−1] − repay_s))              [T1]
E7-13   fundable_s  = max(0, internal_s + cash_free_s + newdebt_max_s + 0)        [T1]
```

| 式 | 設計判断 |
|---|---|
| `E7-09` | **前期営業CF**を用いる（#166 §2.4 の契約）。`int_burden_s`・`repay_s` は当期値（ステップ 2 で確定、期首 `debt_s` のみに依存） |
| `E7-10` | 最低現金保有 `st_cash_min_s · sales_s[t−1]` を下回る取崩を行わない。`sales_s[t−1]` を用いるのは当期 `sales_s` がステップ 8 で決まるため |
| `E7-11` | 債務上限を**売上比**で与え、貸出態度で修正する。担保ベースの上限（`collateral` 比）ではなく売上比を採る理由: 担保は `rollover`（`E5-07`）を通じて既発債の借換に作用しており、新規調達上限にも担保を用いると同一の担保制約が二重に効く |
| `E7-12` | 上限は**残高**に対して与える。`debt_s[t−1] − repay_s` は当期の元本返済後の残高であり、そこから上限までが新規調達余地 |
| `E7-13` | `internal_s` は負値を取りうる（利払い・返済が営業CFを超える場合）。合計に `max(0, ·)` を置くのは、資金源の総額が負になる状態を「投資可能額ゼロ」と解釈するため |

**`credit-off` 反実仮想での扱い**: `E7-11` の `bh_dcap_lend_s` は貸出態度弾性であるため `credit-off` で `0` に固定する（§16.5）。`st_dcap_s` は固定しない（数量制約の基準水準は信用条件の変動ではない）。

### 7.3 `S1` の実行CAPEX（キャンセル・延期・契約確定）

```
E7-14   commit_s1 = st_commit_s1 · capex_exec_s1[t−1]                             （L05 の下方非対称）
E7-15   defer_roll_s1 = bh_defer_roll · max(0, bh_roll_thresh − rollover)
                        · (capex_plan_eff_s1 − capex_cancel_s1)                   （L40）[T1]
E7-16   defer_max_s1  = max(0, capex_plan_eff_s1 − capex_cancel_s1 − commit_s1)   [T1]
E7-17   defer_need_s1 = max(0, (capex_plan_eff_s1 − capex_cancel_s1) − fundable_s1) [T1]
E7-18   capex_defer_s1 = min(defer_max_s1, defer_need_s1 + defer_roll_s1)         [T1]
E7-19   capex_exec_s1  = capex_plan_eff_s1 − capex_cancel_s1 − capex_defer_s1     （恒等式 1）
```

| 式 | 由来 | 設計判断 |
|---|---|---|
| `E7-14` | `L05`（下方非対称・建設リードタイム）・`B3` | **契約確定額**。前期の実行額のうち `st_commit_s1` の割合は契約済みであり当期に延期できない。`st_commit_s1 = 0` なら完全に柔軟、`1` なら前期と同額が固定される。これが `B3`（CAPEX の不可逆性）の**遅らせる**作用の実装である（因果グラフ §5 の注記「`B1`・`B3` は利得を下げるのではなく作動を遅らせる」） |
| `E7-15` | `L40`（threshold、条件悪化で投資延期） | **非線形性 `NL-5`**。借換条件が `bh_roll_thresh`（例 `0.9`）を上回る間は延期が生じない。下回ると離散的に延期が発生する |
| `E7-16` | `E7-14` | 延期できる上限。契約確定分は延期対象外 |
| `E7-17` | `E7-13` | 資金源不足による必要延期額 |
| `E7-18` | #166 §6.2 の閉じ変数指定 | **延期は資金制約の閉じ変数**。資金不足と借換条件悪化の両方が延期を生み、契約確定額が上限を与える |
| `E7-19` | #166 §6.1 の恒等式 1 | 実行額は残余として一意に決まる。`capex_exec_s1 ≥ commit_s1 · 𝟙[commit_s1 ≤ capex_plan_eff_s1 − capex_cancel_s1] ≥ 0` |

**資金不足が実物の削減として現れることの確認**（#166 §6.2 の根拠）: `fundable_s1` が小さいほど `defer_need_s1` が大きく、`capex_defer_s1` が増え、`capex_exec_s1` が減る。**残差項や暗黙の外部資金で埋めない**。

**契約確定額が資金源を超える場合**: `defer_max_s1 < defer_need_s1` のとき延期しきれず、`capex_exec_s1 > fundable_s1` となる。この場合 `newdebt_s1`（`E11-14`）が `newdebt_max_s1` を超える。**これを自動的に消さず、`funding_forced` として構造化記録する**（§15.5）。「デフォルトを持たないことが資金繰りが常に成立することを意味しない」（#166 §7.3）ことの実装上の現れである。

```
E7-20   liquidity_gap_s = max(0, int_burden_s + repay_s + I_s − ocf_s[t−1]
                                 − newdebt_max_s − cash_free_s)                   （#166 §7.3）
```

**#166 §7.3 の定義からの読み替え**: #166 は `liquidity_gap_s` の定義に実現値 `newdebt_s` を用いているが、`newdebt_s` は現金恒等式の閉じ変数（`E11-14`）であるため、それを用いると `liquidity_gap_s ≤ 0` が恒等的に成立し**検出力を失う**。本書は `newdebt_max_s`（上限）に読み替える。これは定義の意図（「正なら計画の縮小が必要」）に忠実である。読み替えを §17 の差し戻し `E5` として登録する。

### 7.4 `SP` の実行投資

```
E7-21   invest_s = min(invest_plan_s, fundable_s)                                 （L62）[T1]
```

**閉じ変数は `invest_s` 自身**である（§6.5）。`SP` にキャンセル・延期の区別を持たないため、資金不足は当期の投資削減として現れ、将来へ繰り越されない。この非対称性（`S1` は繰越、`SP` は繰越なし）は §19-6 の限界に記載する。

### 7.5 資本財の供給元配分

```
E7-22   capex_sx_s1 = st_capex_share_sx · capex_exec_s1                           （#166 C-05）
E7-23   inv_sx_s   = st_invest_share_sx · invest_s      （s = S2）
        inv_sx_s3  = invest_s3                            （s = S3、X06 が EXT のため全額 SX）
```

**契約**: `st_capex_share_s2 + st_capex_share_s3 + st_capex_share_sx = 1`、`st_invest_share_s3 + st_invest_share_sx = 1`（#165 §5.7 表 D）。この和が 1 でないパラメータセットを許容しない（§13.4 の許容条件）。

---

## 8. ステップ 5: 受注配分

`order_s`（`s ∈ SP`）を需要成分へ分解する。**すべて実質数量**（baseline 価格建て、10億ドル/四半期）である（#165 §5.1）。

```
E8-01   order_cap_s = st_capex_share_s · capex_exec_s1 / max(price_s[t−1], st_price_min_s)   （L09）
E8-02   order_inv_s = st_invest_share_s · invest_{s'}[t−1] / max(price_s[t−1], st_price_min_s)  （L19）
E8-03   order_gen_s = st_gen_share_s · y_s5[t−1]
                      · (1 − bh_price_elas_s · (price_s[t−3] − 1))                （L50・L17）[T1]
        order_gen_s ← max(0, order_gen_s)                                          [T1]
E8-04   order_s = order_cap_s + order_inv_s + order_gen_s + ext_demand_s
```

| 式 | 由来 | 設計判断 |
|---|---|---|
| `E8-01` | `L09`（`CAPEX_EXEC → ORDER_s`、遅れ `0–1`） | **遅れ `0`** を採る（#166 の仮定 A-2: 発注・引渡・支払が同一期）。`capex_exec_s1` は**価値額**（支出）であるため、数量へ換算するために期首価格 `price_s[t−1]` で割る。当期 `price_s` はステップ 6 で決まるため使えない |
| `E8-02` | `L19`（`INVEST_s → ORDER_{s'}`、遅れ `1`） | 初期MVPでは `S2 → S3` の一方向のみ（`X06` が `EXT`）。したがって `order_inv_s3 = st_invest_share_s3 · invest_s2[t−1] / price_s3[t−1]`、`order_inv_s2 = 0` |
| `E8-03` | `L50`（`Y_S5 → ORDER_s`、遅れ `1–2`）・`L17`（`PRICE_s → ORDER_s`、遅れ `2–4`） | 一般需要に**のみ**価格弾力性を掛ける（下記の契約）。`y_s5[t−1]` は §3.3 の #6（R4）を断つため |
| `E8-04` | — | `ext_demand_s` は外生（数量）。`order_s ≥ 0` は各成分の非負性から構造的に保証される |

**`L17`（価格弾力性）の適用範囲（設計判断）**

| 論点 | 決定 | 根拠 |
|---|---|---|
| 資本財需要（`order_cap_s`・`order_inv_s`）に価格弾力性を掛けるか | **掛けない** | `capex_exec_s1`・`invest_s` は**価値額での意思決定**（#166 の仮定 A-2 により `capex_exec_s1` は `S1` の制御変数）であり、価格上昇はすでに `1 / price_s[t−1]` の数量換算に現れている。さらに弾力性を掛けると価格効果が二重に入る |
| 一般需要（`order_gen_s`）に掛けるか | **掛ける** | `y_s5` は一般経済の産出であり、そこから `SP` への需要は数量ベースの需要関数として与えられる。相対価格の変化が数量需要を動かす経路は `B6`（価格低下による数量需要の回復）の本体である |
| 資本財需要の価格効果 | `1 / price_s[t−1]` として即時（遅れ 0）に現れる | `B6` は資本財経路でも作動するが、遅れが `0` であり一般需要経路（遅れ `3`）より早い |

この決定を §17 の差し戻し `E3`（`L17` の適用範囲の明記）として因果グラフへ登録する。

---

## 9. ステップ 6: 生産・出荷・在庫・受注残・価格

### 9.1 `SP` の生産能力と需要

```
E9-01   ycap_s = cap_s[t−1] / st_cor_s                                            （#165 §5.3、B1）
E9-02   demand_cap_s = order_cap_s + order_inv_s                                  （A-2 により当期全額充足）
E9-03   demand_gen_s = backlog_s[t−1] + order_gen_s + ext_demand_s
E9-04   ship_desired_s = demand_cap_s + (1 − bh_backlog_target_s) · demand_gen_s   [T1]
```

| 式 | 設計判断 |
|---|---|
| `E9-01` | `B1` の解決。`cap_s` は資本ストック（10億ドル）、`st_cor_s` は資本産出比率（四半期）。期首資本を用いる（#166 §2.4） |
| `E9-02` | **仮定 A-2**（#166 §3.5）: `S1`・`S2` の資本財需要は当期に全額引き渡される。受注残に滞留しない |
| `E9-03` | 一般需要・モデル外需要は前期繰越の受注残を含む |
| `E9-04` | **目標受注残（納期）を持つ**。`bh_backlog_target_s ∈ [0, 1)` は「一般需要のうち当期に出荷せず受注残として持つ割合」であり、定常状態では `backlog_s = bh_backlog_target_s · demand_gen_s > 0` になる |

**`bh_backlog_target_s` を導入する根拠**: 目標受注残を持たない定式化（全需要を当期に充足）では定常状態の受注残がゼロになり、(i) `B1`（高い受注残による短期吸収）が定常状態で作動余地を持たない、(ii) 契約 Q5 の走査変数として「初期受注残」を扱えない、(iii) Census M3 の受注残系列と対応づけられない。納期（リードタイム）を目標受注残比率として表現することで、これら 3 点を同時に解決する。

### 9.2 `SP` の生産

```
E9-05   inv_tgt_s = bh_inv_target_s · ship_desired_s                              （目標在庫）
E9-06   y_norm_s = ship_desired_s + bh_inv_adj_s · (inv_tgt_s − inv_s[t−1])
E9-07   y_cut_s = bh_prod_cut_s · max(0, inv_ratio_s[t−1] − bh_inv_thresh_s)
                  · ship_desired_s                                                （L15）[T1]
E9-08   y_s = min( max(0, y_norm_s − y_cut_s), bh_util_max_s · ycap_s )            （L11・L59）[T1]
E9-09   util_s = y_s / ycap_s                                                     （L13・L58）
```

| 式 | 由来 | 設計判断 |
|---|---|---|
| `E9-06` | `L11`（`BACKLOG_s → Y_s`、saturating） | 望ましい出荷量 + 在庫の目標への部分調整。`bh_inv_adj_s ∈ [0, 1]` |
| `E9-07` | `L15`（threshold、目標在庫比率超で減産） | **非線形性 `NL-2`**。在庫比率が `bh_inv_thresh_s` 以下なら減産しない。超えた分に比例して減産する。契約 Q1 の主要な非線形性（因果グラフ §3.3） |
| `E9-08` | `L59`（`CAP_s → Y_s`、能力上限） | `min` が `L11`・`L59` の saturating を実装する。`max(0, ·)` は産出が負にならないための経済制約。`bh_util_max_s ≤ 1.2` により #165 の `util_s ≤ 1.2` を構造的に満たす |
| `E9-09` | `L13`（分子側）・`L58`（分母側） | **同一の定義式**であり片方だけを実装してはならない（因果グラフ §3.3）。`ycap_s > 0` は `cap_s[t−1] > 0` と `st_cor_s > 0` から保証される |

### 9.3 出荷・引渡・残高への引き渡し

```
E9-10   ship_s = min( ship_desired_s, y_s + inv_s[t−1] )                          [T1]
E9-11   ship_gen_s = max(0, ship_s − demand_cap_s)
E9-12   deliv_s = price_s · ship_s                                                （#166 §10.1）
E9-13   dinv_s = price_s · (y_s − ship_s)                                         （#166 §4.2）
E9-14   unmet_cap_s = max(0, demand_cap_s − (y_s + inv_s[t−1]))                   （A-2 違反量）
```

| 式 | 設計判断 |
|---|---|
| `E9-10` | 出荷は望ましい出荷量と利用可能量（当期産出 + 期首在庫）の小さい方。これにより `inv_s ≥ 0` が構造的に保証される（§12.3） |
| `E9-11` | 資本財需要を優先充足する（A-2）。残りが一般需要への出荷であり、受注残を減らす |
| `E9-14` | **A-2 の違反量**。`y_s + inv_s[t−1] < demand_cap_s` のとき仮定 A-2 が成立しない。`unmet_cap_s > 0` の期を `a2_violation` として警告し（§15.5）、`capex_exec_s1` が売り手の供給能力に制約された事実を明示する。#166 §12-5 の限界（納期変動を内生化しない）の運用上の現れである |

**`price_s` の評価順序**: `E9-12`・`E9-13` は当期 `price_s` を使うため、`E9-15`（価格）の後に評価する。

### 9.4 価格

Issue #169 §4 は「価格形成を本格実装しない場合、固定価格・外生マージン・簡易調整のいずれかを明記する」ことを求めている。

**決定: 簡易調整（稼働率に反応する相対価格の部分調整）を採用する。**

```
E9-15   price_tgt_s = 1 + bh_price_sens_s · tanh( (util_s[t−1] − bh_util_tgt_s) / bh_price_scale_s )
E9-16   price_s = max( st_price_min_s,
                       price_s[t−1] + bh_price_adj_s · (price_tgt_s − price_s[t−1]) )   （L16）[T1]
```

| 論点 | 決定 | 根拠 |
|---|---|---|
| 方式 | 稼働率乖離に反応する目標相対価格への部分調整 | `L16`（`UTIL_s → PRICE_s`、行動、saturating）を実装する必要がある。固定価格では `L16`・`L17` が消え、`B6`（価格低下による数量需要の回復）が表現できない |
| 飽和 | `tanh` | `L16` の関数形候補が saturating。`tanh` は原点で線形、両側で `±1` に飽和し、`bh_price_sens_s` が最大変動幅を与える |
| 一般物価 | **持たない**。`price_s` は一般物価に対する相対価格であり baseline 定常値 `1.0` | [責務境界](capex_credit_cycle_model_boundaries.md) §4.1 の `4-9`（一般物価・インフレ動学は含めない） |
| `price_s1` | 外生（#165 §5.2）。`S1` に価格方程式を置かない | `L16` は `s ∈ SP` のノード（`UTIL_s`）に接続しており、`S1` は稼働率を持たない |
| マージンの扱い | `margin_s` は `profit_s / sales_s` の**診断量**であり、外生マージンを与えない | `profit_s` は会計残差（#166 §4.2・`B6`） |
| 下限 | `st_price_min_s > 0`（例 `0.5`） | #165 の `price_s > 0` を式として満たす経済制約（T1）。`E8-01` の除算の定義域も守る |

### 9.5 `S1` の産出

```
E9-17   ycap_s1 = cap_s1[t−1] / st_cor_s1
E9-18   y_s1 = min( compute_dem, bh_util_max_s1 · ycap_s1 )                       （L60・L61）[T1]
E9-19   util_s1 = y_s1 / ycap_s1                                                  （診断のみ）
```

| 式 | 由来 | 設計判断 |
|---|---|---|
| `E9-18` | `L60`（需要側 saturating）・`L61`（能力上限 saturating） | **`A1` の解決の実装**（因果グラフ `1.1.0` §10.1）。`S1` の産出は期待需要と供給能力の小さい方。在庫・受注残を持たないため未充足需要は繰り越されない |
| `E9-19` | — | `util_s1` は #165 `1.1.0` §5.2 に役割 `diagnostic`・観測コード `L` として登録済み。§16.2 の `R1a` 作動フラグの判定に用いる。潜在変数であるため**単独の水準を LLM 説明・可視化で提示しない**（#165 §5.4 の契約と同型） |

**`R1a` の作動条件**: `compute_dem < bh_util_max_s1 · ycap_s1`（需要側が拘束）のとき `∂y_s1 / ∂cap_s1 = 0` となり、`R1a` の利得はゼロである。基準ユースケース（`SH-EXP` による需要低下）では常にこの領域にある。`R1a` が作動するのは能力側が拘束する状態（供給制約下）に限られる（因果グラフ §4 `R1a` の注記・§9-8）。

---

## 10. ステップ 7: 雇用・所得・消費

### 10.1 労働需要

```
E10-01  emp_req_s1 = y_s1[t−1] / st_lprod_s1                                      （L43）
E10-02  emp_req_s2 = y_s2[t−1] / st_lprod_s2                                      （L43）
E10-03  capex_act_s3 = st_capex_share_s3 · capex_exec_s1
                       / max(price_s3[t−1], st_price_min_s3)                       （L44）
        emp_req_s3 = ( (1 − st_cshare_s3) · y_s3[t−1]
                       + st_cshare_s3 · capex_act_s3 / st_capfrac_s3 )
                     / st_lprod_s3                                                （L43・L44）
E10-04  emp_req_s5 = y_s5[t−1] / st_lprod_s5                                       （L43）
```

**`L43` と `L44` の二重計上を避ける分解（設計判断）**

因果グラフの `EMP` ノードは部門添字を持たないため、`L44`（`CAPEX_EXEC → EMP`、遅れ `0–1`）の帰属部門がグラフ上で一意に決まらない（因果グラフ §3.6）。本書の決定は次のとおりである。

| 論点 | 決定 | 根拠 |
|---|---|---|
| `L44` の帰属部門 | **`S3`**（製造装置・データセンター建設・電力） | #165 §3.3 が「建設・据付雇用の比率が高く、`L44` を通じて家計へ最も早く波及する」と `S3` に帰属させている |
| 二重計上の回避 | `S3` の労働需要を**建設・据付成分**（比率 `st_cshare_s3`）と**その他成分**へ分割し、両者の**合計が定常状態で `y_s3 / st_lprod_s3` に一致する**ように正規化する（`st_capfrac_s3 = order_cap_s3^{ss} / y_s3^{ss}`） | `capex_exec_s1` は既に `order_cap_s3 → y_s3` を通じて雇用へ作用している（`L09` → `L11` → `L43`）。正規化なしに `capex_exec_s1` を加算すると同一の活動を 2 回数えることになる |
| 何が変わるのか | **水準ではなく timing のみ**。建設成分は当期 `capex_exec_s1`（遅れ 0）に反応し、その他成分は `y_s3[t−1]`（遅れ 1）に反応する。`st_cshare_s3` が大きいほど CAPEX 削減が家計へ早く届く | `L44` の遅れ `0–1` と `L43` の遅れ `1–2` の差が「半導体経由より早く家計へ届く」という仮説の内容である（因果グラフ §3.6） |
| `B7` の実装箇所 | `st_lprod_s`（労働生産性）と `st_cshare_s3`（建設雇用比率） | 因果グラフ §5 `B7`（`L43` の雇用弾性・`L44` の建設雇用比率） |

この帰属を §17 の差し戻し `E2` として因果グラフへ登録する。

### 10.2 労働退蔵をともなう雇用調整

```
E10-05  gap_emp_s = emp_req_s − emp_s[t−1]
E10-06  λ_s = 0                if |gap_emp_s| ≤ bh_emp_band_s · emp_s[t−1]
             = bh_emp_up_s     if gap_emp_s > 0
             = bh_emp_down_s   otherwise
E10-07  emp_s = max(0, emp_s[t−1] + λ_s · gap_emp_s)                              [T1]
E10-08  emp_tot = Σ_{s∈SR} emp_s
```

| 論点 | 決定 | 根拠 |
|---|---|---|
| 労働退蔵の表現 | **デッドバンド**（`bh_emp_band_s` 以内の乖離では雇用を動かさない） | `L43` の saturating・「労働退蔵により当初は鈍い」（因果グラフ §3.6）。**非線形性 `NL-6`**。ショックが浅い・短いうちは `R4` の利得がほぼ 0 になる（因果グラフ §4 `R4`） |
| 解雇コスト proxy | **調整速度の非対称性**（`bh_emp_down_s < bh_emp_up_s`） | 解雇には調整コストがかかるため下方調整が遅い。個別の解雇コスト項を持たず、速度差として表現する（`profit_s` は会計残差であり調整コストを費用として計上する余地が無い） |
| 資本集約産業からの波及が過大にならない制約 | `st_lprod_s`（労働生産性）を部門別に与え、`S1`・`S2` の値を `S3`・`S5` より大きくする（`B7`） | Issue #169 §6 の要求。制約は式ではなく**パラメータの大小関係**として与える（§13.4 の許容条件） |

### 10.3 賃金・所得・消費

```
E10-09  wage = max( st_wage_min,
                    wage[t−1] + bh_wage_slope · (emp_tot[t−3] / st_emp_ref − 1) )   （L45）[T1]
E10-10  wagebill_s = st_wbase_s · wage · emp_s                （s ∈ SR）             （#166 §2.2）
E10-11  tax_hh = pl_tau · Σ_{s∈SR} wagebill_s                                       （#166 §10.1）
E10-12  hh_income = (1 − pl_tau) · Σ_{s∈SR} wagebill_s                              （L46・L47）
E10-13  cons = max(0, cons[t−1]
                     + bh_cons_adj · (bh_mpc · hh_income + st_cons_auto − cons[t−1]))  （L48）[T1]
E10-14  cons_s1 = min( st_cons_share_s1 · price_s1 · y_s1, cons )                    [T1]
E10-15  cons_s5 = cons − cons_s1
E10-16  xdem_s5 = st_xdem0
E10-17  y_s5 = cons_s5 + xdem_s5                                                     （L49）
```

| 式 | 由来 | 設計判断 |
|---|---|---|
| `E10-09` | `L45`（`EMP → WAGE`、フィリップス型、遅れ `2–4`） | 総雇用の基準比に反応する水準の部分更新。`st_emp_ref = emp_tot^{ss}` により定常状態で `wage = 1` が成立する。遅れ `3`（`2–4` の中央値、§3.3 の #7） |
| `E10-10` | #166 §2.2 の `wagebill_s = st_wbase_s · wage · emp_s` | `wage`（指数）× `emp_s`（百万人）は価値額にならないため換算係数を掛ける |
| `E10-12` | `L46`・`L47` | `hh_income` は `SR` 全部門（`S5` 内部を含む）の賃金の税引後合計。#166 §4.5 は `S5` 内部の賃金支払を**取引フロー行列に計上しない**（列内で相殺される）が、家計所得としては存在するため `wagebill_s5` を含める。**移転所得を持たない**（政府部門が無い、#166 §12-8）ため #165 §5.5 の「+ 移転」項は `≡ 0` である |
| `E10-13` | `L48`（限界消費性向、遅れ `0–1`） | 目標消費（`bh_mpc · hh_income + st_cons_auto`）への部分調整。所得ショックの持続は `bh_cons_adj < 1` により消費へ滞留する。資産効果・家計信用を持たない（`X01`・`X02` は `EXT`） |
| `E10-14` | #166 §4.2 の `C-01` | `S1` 産出に対する家計・`S5` 企業の支出。`min(·, cons)` は `cons_s5 ≥ 0` を保証する経済制約（T1） |
| `E10-16` | #166 §10.1 表 2（「**残差として逆算しない**」） | **初期MVPでは定数**とする。政府支出・純輸出・非AI企業投資を内生化しない（[責務境界](capex_credit_cycle_model_boundaries.md) §4.1 の `4-9`・`4-12`、`external_sector = :none`・`fiscal_policy = :none`）。残差として逆算しないという #166 の要求を満たす最小の実装である。§17 の差し戻し `E4` として登録する |
| `E10-17` | `L49`（最終需要の集計） | `y_s5` は `S5` 産出に対する需要の合計。`S5` の `S2`・`S3` 向け一般需要（`d_{S5,s}`）は `S5` の**支出**であって `S5` 産出への需要ではないため含めない |

**`cons` の範囲についての注意（限界）**: #166 §4.2 は `cons = cons_s1 + cons_s5` と定めており、`cons` は `S1`・`S5` 産出に対する家計消費のみを含む。`S2`・`S3` 産出に対する一般需要（`order_gen_s`、`E8-03`）は `y_s5` を規模変数として `L50` で生成され、`cons` には含まれない。観測（`PCECC96`、#165 §5.5）は全部門からの消費を含むため、**`cons` と `PCECC96` の対応は近似である**。契約 §3 Q3 の判定量 `dC_t` にこの近似が入る。§17 の差し戻し `E6` として登録する。

---

## 11. ステップ 8: 収益・分配

### 11.1 売上・付加価値・利益

```
E11-01  sales_s  = price_s · y_s                        （s ∈ SP）                （L20・L21）
E11-02  sales_s1 = price_s1 · y_s1                                                （L20・L21）
E11-03  im_s = (1 − st_va_share_s) · sales_s            （s ∈ SF）                （#166 §4.2）
E11-04  va_s = sales_s − im_s = st_va_share_s · sales_s
E11-05  dep_s = st_delta_s · cap_s[t−1]                                           （#166 §5.1）
E11-06  profit_s = va_s − wagebill_s − dep_s                                      （L22、会計残差）
E11-07  margin_s = profit_s / sales_s
E11-08  ocf_s  = profit_s + dep_s − dinv_s              （s ∈ SP）                （#166 §4.4）
E11-09  ocf_s1 = profit_s1 + dep_s1                                               （Δwc_s1 ≡ 0）
```

| 論点 | 決定 | 根拠 |
|---|---|---|
| `st_va_share_s` を定数とするか | **定数**（`s ∈ SF`） | 中間投入比率を内生化すると産業連関構造の推定が必要になり、初期MVPの識別可能性を超える。#165 §3.7 の差し戻し（「定数とするか内生とするかは #169 が決める」）への回答 |
| `S5` の中間投入 | **`st_va_share_s5 = 1`（`im_s5 ≡ 0`）** | #165 §5.5 表 B は `y_s5` の観測候補を「`GDPC1 − S1`–`S3` の実質付加価値」としており、`y_s5` は**付加価値ベース**で定義されている。同時に #165 R-1 は `y_tot = Σ va_s + y_s5` と `y_s5` を付加価値として扱う。したがって `S5` に中間投入を持たせると `y_tot` が二重に控除される。#166 `C-05` の `im_s5` は恒等的ゼロの独立項として保持する（§17 の差し戻し `E6`） |
| 固定費レバレッジの所在 | `E11-06` の `wagebill_s`（`E10-07` のデッドバンド・非対称調整により産出に対して固定的）と `dep_s`（`E11-05` により期首資本のみに依存し産出に依存しない完全固定費） | `L22` の型は `会計` であり（因果グラフ `1.1.0` §3.4）、利益を売上の関数として独立に生成しない。**非線形性は費用側の固定性から導出される**（#166 §4.2・差し戻し `B6`） |
| `ocf_s` の定義 | **利払い前・税引前** | #166 §4.4 の契約（`coverage_s = ocf_s / int_burden_s` の解釈を保つため） |

### 11.2 財務診断量

```
E11-10  coverage_s = ocf_s / int_burden_s                                         （L28・L29）
E11-11  debt_service_s = int_burden_s + repay_s                                   （#166 §5.4）
E11-12  dsc_s = ocf_s / debt_service_s                                            （#166 §7.3）
```

### 11.3 資金調達の閉じと資金過不足

```
E11-13  need_s = I_s + int_burden_s + tax_s + div_s + repay_s − ocf_s
E11-14  draw_s     = min( max(0, need_s), cash_free_s )                            [T1]
        newdebt_s  = max(0, need_s − draw_s)                                       [T1]
E11-15  funding_forced_s = max(0, newdebt_s − newdebt_max_s)
E11-16  nlb_s = ocf_s − I_s − int_burden_s − tax_s − div_s        （s ∈ SF）        （#166 §4.1）
```

| 式 | 設計判断 |
|---|---|
| `E11-13` | 当期の資金需要（当期営業CF控除後）。`ocf_s` は**当期値**を用いる（`E7-09` の `fundable_s` は前期値を用いるが、それは**事前の意思決定制約**であり、事後の資金調達は当期実現値で閉じる） |
| `E11-14` | **`newdebt_s` は現金恒等式の閉じ変数**。現金取崩を優先し（`draw_s`）、残余を新規借入で埋める。これにより `cash_s ≥ st_cash_min_s · sales_s[t−1] ≥ 0` が構造的に保証される（§15.3） |
| `E11-15` | 事前上限を超えた調達額。`> 0` の期を `funding_forced` として警告する（§15.5）。**自動的に消さない** |
| `E11-16` | #166 §4.2 の経常・資本ブロック列和を整理した形。導出は #166 §4.2 の各行から機械的に得られる（`sales_s − dinv_s − I_s − im_s − wagebill_s − tax_s − int_burden_s − div_s` に `ocf_s` の定義を代入）。#166 §8.1 の `:nlb_consistency` はこの値と金融ブロック列和の符号反転一致を検証する |

### 11.4 部門間フローの配分（会計表要素の生成）

#166 §8.1 の `:no_double_count` を検証するために、取引フロー行列の要素 `d_{b,s}` を生成する。

```
E11-17  d_{S1,s}  = price_s · order_cap_s          （s ∈ SP、A-2 により当期全額引渡）
E11-18  d_{S2,S3} = price_s3 · order_inv_s3        （L19。d_{S3,S2} = 0（X06 が EXT））
E11-19  deliv_gen_s = price_s · ship_gen_s
        gen_frac_s  = order_gen_s / max(order_gen_s + ext_demand_s, div_eps)
        d_{S5,s}    = deliv_gen_s · gen_frac_s
        d_{SX,s}    = deliv_gen_s · (1 − gen_frac_s)
E11-20  xsales_s1 = sales_s1 − cons_s1                                            （#166 C-01）
E11-21  y_tot = Σ_{s∈{S1,S2,S3}} va_s + y_s5                                      （L51・L52、R-1）
E11-22  s5_net_sx = Σ_{s∈SR} wagebill_s − tax_hh − cons_s1 − cons_s5
                    − d_{S5,S2} − d_{S5,S3} + y_s5 − xdem_s5                      （#166 §4.5）
```

**`d_{S5,s}` / `d_{SX,s}` の配分についての近似**: 一般需要の引渡額 `deliv_gen_s` を `S5`（一般需要）と `SX`（モデル外需要）へ**当期の受注フロー比**で配分する。受注残 `backlog_s` の買い手構成を状態として追跡しないため、繰越分は当期のフロー比で按分される。**買い手構成を追跡する状態変数を新設しない**（#165 §1.2-1 の規律。追跡が必要なら #165 の改訂を要する）。この近似の影響は `s5_net_sx` の残差に現れ、#166 §8.3 の閾値（`|s5_net_sx| / y_tot > 0.05`）で監視される。

---

## 12. ステップ 9: 残高更新

すべて #166 §5 の残高更新式をそのまま用いる。本書が確定するのは `capstart_s`（稼働開始額）の生成規則である。

### 12.1 資本とパイプライン

```
E12-01  capstart_s = capex_pipe_s[t−1] / st_pipelag_s                             （L08・L57）
E12-02  capex_pipe_s = capex_pipe_s[t−1] + I_s − capstart_s − pipe_cancel_s       （#166 §5.2）
E12-03  cap_s = cap_s[t−1] + capstart_s − dep_s − retire_s                        （#166 §5.1）
```

| 論点 | 決定 | 根拠 |
|---|---|---|
| `capstart_s` の生成規則 | **幾何ラグ**（毎期パイプライン残高の `1 / st_pipelag_s` が稼働開始する）。固定ラグ（`st_pipelag_s` 期前の投資が全額稼働）を採らない | (i) 固定ラグは `st_pipelag_s` 期分の遅延バッファを必要とし状態数が増える。(ii) 幾何ラグの平均遅れは `st_pipelag_s` 期であり、因果グラフ `L08`・`L57` の遅れ `2–4` を `st_pipelag_s ∈ [2, 4]` として表現できる。(iii) 建設案件の規模・工期が分布していることを表現する形として自然である |
| 非負性 | `st_pipelag_s ≥ 1` により `capstart_s ≤ capex_pipe_s[t−1]` が保証され、`capex_pipe_s ≥ 0` が構造的に成立する（`I_s ≥ 0`・`pipe_cancel_s ≡ 0`） | §15.3 |
| `capex_pipe_s` を経由しない資本増加 | **作らない**（#166 §5.1 の契約） | すべての `I_s` はパイプラインを経由する |
| `pipe_cancel_s ≡ 0` | 維持（`B3` を完全不可逆として実装）。部分不可逆を導入する場合は `pipe_cancel_s ≤ (1 − st_irrev_s) · capex_pipe_s[t−1]` の形で上限を与える（#166 §5.2） | 初期MVPでは `st_irrev_s = 1` |

### 12.2 在庫・受注残・繰越計画

```
E12-04  inv_s = inv_s[t−1] + y_s − ship_s                                         （#166 §5.3）
E12-05  invval_s = st_invprice_s · inv_s                                          （#166 §5.3）
E12-06  backlog_s = backlog_s[t−1] + order_gen_s + ext_demand_s − ship_gen_s      （#166 §5.3）
E12-07  inv_ratio_s = inv_s / y_s
E12-08  backlog_ratio_s = backlog_s / y_s
E12-09  plan_carry_s1 = plan_carry_s1[t−1] − revive_s1 + capex_defer_s1           （#166 §5.3・§6.1）
```

**`E12-06` と #166 §5.3 の関係**: #166 は `backlog_s = backlog_s[t−1] + order_s − ship_s` と書いている。仮定 A-2 により資本財需要は受注残へ入らないため、`order_s` から資本財成分（`order_cap_s + order_inv_s`）を除き、`ship_s` から資本財引渡分（`demand_cap_s`）を除いた形が `E12-06` である。両者は `order_s − ship_s = (order_gen_s + ext_demand_s − ship_gen_s) + (demand_cap_s − demand_cap_s)` として一致する（`unmet_cap_s = 0` のとき）。`unmet_cap_s > 0` のとき A-2 が破れ、差分が `a2_violation` として現れる（§15.5）。

### 12.3 現金・債務・純資産

```
E12-10  cash_s = cash_s[t−1] + ocf_s − int_burden_s − tax_s − div_s − I_s
                 + newdebt_s − repay_s + equity_issue_s                           （#166 §5.4）
E12-11  debt_s = debt_s[t−1] + newdebt_s − repay_s − writeoff_s                   （#166 §5.4）
E12-12  leverage_s = debt_s / sales_s                                             （#165 §5.4）
E12-13  nw_s = cap_s + capex_pipe_s + invval_s + cash_s − debt_s                  （#166 §5.6）
E12-14  loans_s4 = Σ_{s∈SF} debt_s
        dep_stock_s4 = Σ_{s∈SF} cash_s
        fund_s4 = loans_s4 − dep_stock_s4                                         （#166 §5.5）
        nw_s4 ≡ 0
E12-15  s5_net_sx（E11-22）は残高を持たない                                        （#166 §5.5）
```

**`E12-10` と `E11-14` の整合**: `E11-14` の定義により `cash_s = cash_s[t−1] − draw_s` が成立する（`need_s > 0` のとき）。`need_s ≤ 0`（資金余剰）のときは `draw_s = newdebt_s = 0` であり `cash_s = cash_s[t−1] − need_s > cash_s[t−1]`（現金の積み増し）。#166 §6.2 の「資金源が余剰のとき、差額は `Δcash_s1`（現金の積み増し）へ回る」と整合する。

---

## 13. パラメータ辞書

### 13.1 分類方針

#165 §6.2 の接頭辞規約（`st_` 構造 / `bh_` 行動 / `pl_` 政策・制度）に従う。Issue #169 §9 が挙げた 6 分類との対応を示す。

| Issue #169 §9 の分類 | 本書の接頭辞 | 備考 |
|---|---|---|
| 会計・制度パラメータ | `st_` / `pl_` | 会計恒等式・制度設定から与える |
| 技術・生産パラメータ | `st_` | 資本産出比率・減耗率・労働生産性・付加価値率 |
| 行動パラメータ | `bh_` | **推定・較正の主対象** |
| 調整速度・ラグ | `bh_`（速度）/ `st_`（整数ラグ・パイプライン長） | §13.5 |
| 信用・政策パラメータ | `bh_`（貸し手の反応）/ `pl_`（制度上限） | 反応は行動、上限は制度 |
| シナリオ入力 | **含めない** | イベント/シナリオ型（#168）。`parameters` に入れない（#165 §6.2） |

**契約**（#165 §6.2 を継承）:

- `parameters(m)` は**平坦な `NamedTuple`** を返す。
- 数値解法設定は `parameters` に含めず `SolverOptions` で受け取る（下表）。
- 診断閾値（契約 §4.2 の深さ・持続性・`breadth`、§16.4 の `prox_band`）は `parameters` に含めず診断層の閾値セットとして外部化する（下表）。
- 初期状態（初期債務比率・初期稼働率・初期在庫比率・初期現金比率）は `parameters` に含めず初期状態指定 API で与える（#171）。
- **`bh_` に分類したパラメータのみが #170 の推定・較正の対象になりうる**。`st_` は会計・技術定義から、`pl_` は制度から与える。

**`parameters` に含めない設定値**（フィールド名は #171 が確定する）

| 設定 | 置き場 | 既定 | 出現箇所 |
|---|---|---|---|
| `div_eps`（ゼロ除算判定の下限） | `SolverOptions` | `1e-8` | §15.4 |
| `guard_max`（発散判定の閾値） | `SolverOptions` | `1e6`（既存の既定値を継承） | §15.6 |
| `runup_tol`（助走区間の許容乖離） | `SolverOptions` | `1e-8` | §14.4・§15.5 |
| `stop_on_sign_violation` | `SolverOptions` | `false` | §15.6 |
| `atol` / `rtol`（会計検証の許容誤差） | methodology metadata（#166 §8.2） | `1e-8` / `1e-6` | §15.1 |
| `jac_h`（ヤコビアンの摂動幅） | 診断閾値セット | `1e-6` | §16.2 |
| `prox_band`（閾値近傍の帯幅） | 診断閾値セット | `0.10` | §16.4 |
| `s5_resid_tol`（`S5` 残差の警告閾値） | 診断閾値セット | `0.05`（#166 §8.3） | §16.9 |
| 契約 §4.2 の深さ・持続性・`breadth` 閾値 | 診断閾値セット | 契約 §4.2 の暫定既定値 | §16.9 |

### 13.2 構造パラメータ（`st_`）

| Julia 名 | 記号 | 単位 | 範囲 | 出現式 | 固定/較正/推定 | 感応度 |
|---|---|---|---|---|---|---|
| `:st_cor_s1` – `:st_cor_s3` | `κ_s` | 四半期 | `> 0` | `E6-02`・`E6-13`・`E9-01`・`E9-17` | 較正（資本ストック/産出） | — |
| `:st_delta_s1` – `:st_delta_s3` | `δ_s` | 比率/四半期 | `0 < δ < 1` | `E6-04`・`E6-16`・`E11-05` | 較正（BEA 減耗率 ÷ 4） | ○ |
| `:st_pipelag_s1` – `:st_pipelag_s3` | `L_s` | 四半期 | `≥ 1`（既定 3） | `E12-01` | 較正（着工〜完工） | ○ |
| `:st_va_share_s1` – `:st_va_share_s3` | — | 比率 | `0 < x ≤ 1` | `E11-03` | 較正（BEA 付加価値/産出） | — |
| `:st_va_share_s5` | — | 比率 | `= 1`（固定） | `E11-03` | 固定（§11.1） | — |
| `:st_lprod_s1` – `:st_lprod_s5` | — | 10億ドル/四半期/百万人 | `> 0` | `E10-01`–`E10-04` | 較正（産出/雇用） | ○（`B7`） |
| `:st_wbase_s1` – `:st_wbase_s5` | — | 10億ドル/四半期/百万人 | `> 0` | `E10-10` | 較正（賃金支払額/(賃金指数×雇用)） | — |
| `:st_cshare_s3` | — | 比率 | `0 ≤ x ≤ 1` | `E10-03` | 較正（建設・据付雇用比率） | ○（`B7`） |
| `:st_capfrac_s3` | — | 比率 | `0 < x < 1` | `E10-03` | 定常水準から導出（`order_cap_s3^{ss}/y_s3^{ss}`） | — |
| `:st_capex_share_s2` / `_s3` / `_sx` | — | 比率 | 合計 `= 1` | `E8-01`・`E7-22`・`E10-03` | 較正（資本財の供給元構成） | ○ |
| `:st_invest_share_s3` / `_sx` | — | 比率 | 合計 `= 1` | `E8-02`・`E7-23` | 較正 | — |
| `:st_gen_share_s2` / `_s3` | — | 比率 | `≥ 0` | `E8-03` | 定常水準から導出 | ○ |
| `:st_cons_share_s1` | — | 比率 | `0 ≤ x ≤ 1` | `E10-14` | 較正 | — |
| `:st_cd0` | — | 10億ドル/四半期 | `> 0` | `E6-01` | 定常水準から導出 | — |
| `:st_invprice_s2` / `_s3` | — | 指数 | `> 0`（既定 1） | `E12-05` | 固定 | — |
| `:st_maturity_s1` – `:st_maturity_s3` | — | 年 | `≥ Δt` | `E5-08` | 較正（企業開示の平均満期） | ○ |
| `:st_cash_min_s1` – `_s3` | — | 比率（対 `sales_s`） | `≥ 0` | `E7-10` | 較正 | ○（`B2`） |
| `:st_cash_ref_s1` – `_s3` | — | 比率（対 `sales_s`） | `> 0` | `E6-05`・`E6-15` | 較正 | ○（`B2`） |
| `:st_dcap_s1` – `_s3` | — | 比率（対 `sales_s`） | `> 0` | `E7-11` | 較正（債務/売上の上限） | ○ |
| `:st_commit_s1` | — | 比率 | `0 ≤ x ≤ 1` | `E7-14` | 較正 | ○（`B3`） |
| `:st_irrev_s1` – `_s3` | — | 比率 | `= 1`（MVP） | `E7-05` の上限式 | 固定 | — |
| `:st_payout_s1` – `_s3` | — | 比率 | `= 1`（baseline、§14.3 `SS-14`） | `E7-02` | 固定（定常整合条件） | ○ |
| `:st_spread0` | — | bp | `≥ 0` | `E5-04`・`E5-06` | 較正（定常スプレッド） | — |
| `:st_pol_ref` | — | 年率 % | `≥ 0` | `E5-01`・`E4-02` | 較正（定常政策金利） | — |
| `:st_cc0_s1` – `_s3` | — | 年率 % | `≥ 0` | `E5-16`・`E6-06` | 定常水準から導出 | — |
| `:st_profit_ref` | — | 10億ドル/四半期 | `> 0` | `E5-02` | 定常水準から導出（`Σ profit_s^{ss}`） | — |
| `:st_emp_ref` | — | 百万人 | `> 0` | `E10-09` | 定常水準から導出（`emp_tot^{ss}`） | — |
| `:st_coll_ltv` | — | 比率 | `0 < x ≤ 1` | `E5-03` | 較正 | ○（`R3`） |
| `:st_xdem0` | — | 10億ドル/四半期 | `≥ 0` | `E10-16` | 定常水準から導出 | ○ |
| `:st_cons_auto` | — | 10億ドル/四半期 | 符号制約なし | `E10-13` | 定常水準から導出 | — |
| `:st_ev_min` | — | 指数 | `> 0`（既定 0.1） | `E5-02` | 固定 | — |
| `:st_price_min_s2` / `_s3` | — | 指数 | `> 0`（既定 0.5） | `E9-16`・`E8-01` | 固定 | — |
| `:st_wage_min` | — | 指数 | `> 0`（既定 0.5） | `E10-09` | 固定 | — |
| `:st_debt_tol` | — | 10億ドル | `> 0` | §16.8 | 固定 | — |
| `:st_extdem_s2` / `_s3` | — | 10億ドル/四半期 | `≥ 0` | `E4-01` の baseline | 定常水準から導出 | ○ |

### 13.3 行動パラメータ（`bh_`）と政策・制度パラメータ（`pl_`）

| Julia 名 | 単位 | 範囲 | 出現式 | 由来エッジ | 固定/較正/推定 | 感応度 |
|---|---|---|---|---|---|---|
| `:bh_util_tgt_s1` – `_s3` | 比率 | `0 < x < 1` | `E6-02`・`E6-12`・`E9-15` | `L02`・`L16`・`L18` | 較正 | ○ Q5(iii) |
| `:bh_util_max_s1` – `_s3` | 比率 | `bh_util_tgt < x ≤ 1.2` | `E9-08`・`E9-18` | `L59`・`L61` | 較正 | ○ |
| `:bh_alpha_capex_s1` | 比率/四半期 | `0 < x ≤ 1` | `E6-04` | `L03` | **推定** | ○ |
| `:bh_alpha_inv_s2` / `_s3` | 比率/四半期 | `0 < x ≤ 1` | `E6-16` | `L18` | **推定** | ○ |
| `:bh_cc_elas_s1` | 1/%pt | `≥ 0` | `E6-07` | `L39` | **推定** | ○ Q2 |
| `:bh_cc_elas_inv_s2` / `_s3` | 1/%pt | `≥ 0` | `E6-16` | `L64` | **推定** | ○ Q2 |
| `:bh_lend_elas_inv_s2` / `_s3` | 1/標準化単位 | `≥ 0` | `E6-16` | `L42` | **推定** | ○ Q2 |
| `:bh_dcap_lend_s1` – `_s3` | 比率/標準化単位 | `≥ 0` | `E7-11` | `L42` | 較正 | ○ Q2 |
| `:bh_cancel_thresh` | 比率 | `≥ 0`（既定 0.05） | `E6-09` | `L06` | 較正 | ○ **NL-1** |
| `:bh_cancel_slope` | 比率/比率 | `≥ 0` | `E6-09` | `L06` | 較正 | ○ |
| `:bh_cancel_max` | 比率 | `0 ≤ x ≤ 1` | `E6-09` | `L06` | 固定 | ○ |
| `:bh_revive_s1` | 比率/四半期 | `0 ≤ x ≤ 1` | `E6-10` | #166 §6.1 | 較正 | ○ |
| `:bh_defer_roll` | 比率/指数単位 | `≥ 0` | `E7-15` | `L40` | **推定** | ○ Q2 |
| `:bh_roll_thresh` | 指数 | `0 ≤ x ≤ 1`（既定 0.9） | `E7-15` | `L40` | 較正 | ○ **NL-5** |
| `:bh_backlog_target_s2` / `_s3` | 比率 | `0 ≤ x < 1` | `E9-04` | `L11` | 較正（受注残/需要） | ○ `B1` |
| `:bh_inv_target_s2` / `_s3` | 比率 | `≥ 0` | `E9-05` | `L15` | 較正（在庫/出荷） | ○ Q5(iv) |
| `:bh_inv_thresh_s2` / `_s3` | 比率 | `≥ bh_inv_target` | `E9-07` | `L15` | 較正 | ○ **NL-2** |
| `:bh_inv_adj_s2` / `_s3` | 比率/四半期 | `0 ≤ x ≤ 1` | `E9-06` | `L11` | **推定** | ○ |
| `:bh_prod_cut_s2` / `_s3` | 比率/比率 | `≥ 0` | `E9-07` | `L15` | **推定** | ○ Q1 |
| `:bh_price_adj_s2` / `_s3` | 比率/四半期 | `0 < x ≤ 1` | `E9-16` | `L16` | **推定** | ○ `B6` |
| `:bh_price_sens_s2` / `_s3` | 指数 | `≥ 0` | `E9-15` | `L16` | **推定** | ○ `B6` |
| `:bh_price_scale_s2` / `_s3` | 比率 | `> 0` | `E9-15` | `L16` | 固定（既定 0.1） | ○ |
| `:bh_price_elas_s2` / `_s3` | 1/指数単位 | `≥ 0` | `E8-03` | `L17` | **推定** | ○ `B6` |
| `:bh_cov_threshold` | 倍 | `> 0` | `E5-04` | `L30` | 較正 | ○ Q5(ii) **NL-3** |
| `:bh_spread_cov` | bp/倍^pow | `≥ 0` | `E5-04` | `L30` | **推定** | ○ Q5(v) |
| `:bh_spread_pow` | — | `1 ≤ x ≤ 3` | `E5-04` | `L30` | 較正（既定 1） | ○ |
| `:bh_spread_fc` | bp/標準化単位 | `≥ 0` | `E5-04` | `L54` | **推定** | ○ Q4 |
| `:bh_lend_spread` | 標準化単位/bp | `≥ 0` | `E5-06` | `L33` | **推定** | ○ |
| `:bh_fc_adj` | 比率/四半期 | `0 < x ≤ 1` | `E5-01` | `L53` | 較正 | ○ Q4 |
| `:bh_fc_pol` | 標準化単位/%pt | `≥ 0` | `E5-01` | `L53` | **推定** | ○ Q4 |
| `:bh_cc_spread` | %pt/%pt | `≥ 0` | `E5-16` | `L36` | 較正（既定 1） | ○ |
| `:bh_cc_lend` | %pt/標準化単位 | `≥ 0` | `E5-16` | `L37` | **推定** | ○ |
| `:bh_cc_equity` | %pt/指数単位 | `≥ 0` | `E5-16` | `L38` | **推定** | ○ |
| `:bh_cc_fc` | %pt/標準化単位 | `≥ 0` | `E5-16` | `L55` | **推定** | ○ Q4 |
| `:bh_ev_adj` | 比率/四半期 | `0 < x ≤ 1` | `E5-02` | `L27` | 較正 | — |
| `:bh_ev_elas` | 指数単位/比率 | `≥ 0` | `E5-02` | `L27` | **推定** | ○ `R3` |
| `:bh_coll_elas` | — | `≥ 0` | `E5-03` | `L31` | **推定** | ○ `R3` |
| `:bh_roll_slope` | 指数単位/比率 | `≥ 0` | `E5-07` | `L32` | **推定** | ○ **NL-4** |
| `:bh_emp_up_s1` – `_s5` | 比率/四半期 | `0 < x ≤ 1` | `E10-06` | `L43` | **推定** | ○ |
| `:bh_emp_down_s1` – `_s5` | 比率/四半期 | `0 < x ≤ bh_emp_up` | `E10-06` | `L43` | **推定** | ○ Q3 |
| `:bh_emp_band_s1` – `_s5` | 比率 | `≥ 0` | `E10-06` | `L43` | 較正 | ○ **NL-6** `B7` |
| `:bh_wage_slope` | 指数単位/比率 | `≥ 0` | `E10-09` | `L45` | **推定** | ○ |
| `:bh_mpc` | 比率 | `0 < x < 1` | `E10-13` | `L48` | **推定** | ○ Q3 |
| `:bh_cons_adj` | 比率/四半期 | `0 < x ≤ 1` | `E10-13` | `L48` | **推定** | ○ Q3 |
| `:pl_tau` | 比率 | `0 ≤ x < 1` | `E10-11`・`E10-12` | 制度 | 固定（実効税率） | — |
| `:pl_tau_corp` | 比率 | `= 0`（MVP） | `E7-01` | 制度 | 固定 | — |
| `:pl_ltv` | 比率 | `0 < x ≤ 1` | `E5-07` | `L32` | 較正 | ○ **NL-4** |

**`pl_pass_through` を用いない決定**: #165 §6.2 は政策・制度パラメータの例に `:pl_pass_through`（政策金利伝達係数）を挙げているが、本書は政策金利から金融環境への伝達を `bh_fc_pol`（`E5-01`）として実装する。伝達の強さは**貸し手・市場の反応**であり制度設定ではないため、`bh_` に分類する。`:pl_pass_through` は登録しない。

**全パラメータ同時推定を前提にしない**（Issue #169 §9 の要求）:

| 区分 | 個数（概算） | 決め方 |
|---|---|---|
| 定常水準から導出（自由度なし） | 12 | §14.2 の逆較正で一意に決まる |
| 固定（会計・制度・数値下限） | 18 | 会計定義・制度・既定値 |
| 較正（観測比率から直接） | 30 | 部門別比率・満期・閾値水準。#170 |
| **推定（`bh_` の一部）** | **28** | 調整速度・弾性。#170 の識別戦略で**部分集合ごとに**推定する |

### 13.4 パラメータの許容条件（実装時に検査する）

以下を満たさないパラメータセットを**不正入力として拒否する**（例外を投げる）。シミュレーション中の制約違反（§15.3）とは別種であり、`simulate` の開始前に検査する。

| # | 条件 | 理由 |
|---|---|---|
| 1 | `st_capex_share_s2 + st_capex_share_s3 + st_capex_share_sx = 1`（許容誤差 `1e-10`） | 資本財支出の全額が配分されないと `:no_double_count` が破れる |
| 2 | `st_invest_share_s3 + st_invest_share_sx = 1` | 同上 |
| 3 | `0 < st_delta_s < 1` | `cap_s > 0` の構造的保証（§15.3） |
| 4 | `st_pipelag_s ≥ 1` | `capex_pipe_s ≥ 0` の構造的保証 |
| 5 | `st_maturity_s ≥ Δt` すなわち `φ_s ≤ 1` | `matur_s ≤ debt_s[t−1]`、`debt_s ≥ 0` の構造的保証 |
| 6 | `bh_util_tgt_s < bh_util_max_s ≤ 1.2` | `util_s ≤ 1.2`（#165）の構造的保証と定常状態の存在 |
| 7 | `bh_inv_target_s ≤ bh_inv_thresh_s` | 定常状態で `y_cut_s = 0` になること（§14.3 `SS-7`） |
| 8 | `0 ≤ bh_backlog_target_s < 1` | 定常受注残が有限であること（§14.3 `SS-8`） |
| 9 | `bh_emp_down_s ≤ bh_emp_up_s` | 解雇コスト proxy の符号（§10.2） |
| 10 | `0 < bh_mpc < 1` | 消費関数の安定性 |
| 11 | `st_cash_min_s ≤ cash_s^{ss} / sales_s^{ss}` | 定常状態で `cash_free_s ≥ 0` |
| 12 | `st_payout_s = 1`（baseline） | 定常状態で `Δnw_s = 0`（§14.3 `SS-14`） |
| 13 | `st_lprod_s1 > st_lprod_s3` かつ `st_lprod_s2 > st_lprod_s3` | 資本集約産業の雇用波及が過大にならないこと（`B7`、Issue #169 §6） |
| 14 | `Σ_{s∈SF} debt_s^{ss} / collateral^{ss} ≤ pl_ltv` | 定常状態で `rollover = 1`（§14.3 `SS-2`） |
| 15 | `coverage_agg^{ss} ≥ bh_cov_threshold` | 定常状態で `spread = st_spread0`（§14.3 `SS-2`） |

### 13.5 遅延パラメータと採用遅れの一覧

因果グラフの遅れが幅で与えられているエッジについて、§3.3 の規則（循環を断つ必要があれば下限、単なる伝達遅れなら中央値）で採用値を確定する。

| エッジ | 因果グラフの遅れ | 採用値 | 規則 | 実装 |
|---|---|---|---|---|
| `L03` | 1 | 1 | — | `E6-04` は当期 `target_cap_s1` と期首 `cap_s1` を用い、部分調整が遅れを表す |
| `L05` | 1–2 | 1 | 下限（`E7-14` の `capex_exec_s1[t−1]`） | 契約確定額 |
| `L06` | 0–1 | 0 | 下限（当期の計画修正に反応） | `E6-08` は `capex_plan_s1[t−1]` を参照 |
| `L08`・`L57` | 2–4 | `st_pipelag_s`（既定 3） | 幾何ラグの平均遅れ | `E12-01` |
| `L09` | 0–1 | 0 | 仮定 A-2（#166 §4.4） | `E8-01` |
| `L11` | 0–1 | 0 | 当期需要に反応 | `E9-06` |
| `L14`・`L15` | 1（`L14`）・1–2（`L15`） | 1 | 下限（循環 #9 を断つ） | `E9-07` の `inv_ratio_s[t−1]` |
| `L16` | 1–2 | 1 | 下限（循環 #8 を断つ） | `E9-15` の `util_s[t−1]` |
| `L17` | 2–4 | 3 | 中央値 | `E8-03` の `price_s[t−3]` |
| `L18` | 1–2 | 1 | 下限（循環 #10 を断つ） | `E6-12` の `y_s[t−1]` |
| `L19` | 1 | 1 | — | `E8-02` の `invest_{s'}[t−1]` |
| `L22`–`L24` | 0–1 | 0 | 会計定義（当期フロー） | `E11-06`–`E11-09` |
| `L27` | 0 | **1** | 期内処理順序（ステップ 2 < ステップ 8）。§17 の `E4` | `E5-02` の `profit_s[t−1]` |
| `L30` | 1 | 1 | 循環 #3・#4・#11 を断つ | `E5-04` の `coverage_agg[t−1]` |
| `L31` | 0–1 | 0 | 当期 `equity_val` に反応 | `E5-03` |
| `L32` | 1 | 1 | 期首 `debt_s`・`collateral`（当期） | `E5-07` |
| `L33` | 1 | 1 | — | `E5-06` の `spread[t−1]` |
| `L35`・`L56` | 1–4・1–2 | `1/φ_s` の幾何浸透 | 満期構成による表現（§5.3） | `E5-13` |
| `L37`・`L38`・`L39`・`L55`・`L64` | 0–1・0–1・1・0–1・1 | 0（`E5-16` 内）・1（`E6-07`・`E6-16`） | 資本コストは当期合成、投資への作用は 1 期遅れ | `E5-16`・`E6-06` |
| `L41`・`L62` | 0–1 | **1（確定値）** | #166 §2.4・`B7` | `E7-09`・`E7-10` の期首 `cash_s`・前期 `ocf_s` |
| `L42` | 1 | 1 | — | `E6-16` の `lend_stance[t−1]` |
| `L43` | 1–2 | 1 | 下限（`L44` との timing 差を保つ） | `E10-01`–`E10-04` の `y_s[t−1]` |
| `L44` | 0–1 | 0 | 下限（`L43` より早いことが仮説の内容） | `E10-03` の当期 `capex_exec_s1` |
| `L45` | 2–4 | 3 | 中央値（循環 #7） | `E10-09` の `emp_tot[t−3]` |
| `L48` | 0–1 | 0 | 当期 `hh_income` に反応。持続は `bh_cons_adj` | `E10-13` |
| `L50` | 1–2 | 1 | 下限（循環 #6 を断つ） | `E8-03` の `y_s5[t−1]` |
| `L53` | 0–1 | 0 | 部分調整が遅れを表す | `E5-01` |
| `L60`・`L61` | 0 | 0 | — | `E9-18` |

**遅延バッファの必要本数**

| 深さ | 変数 |
|---|---|
| 1 | `capex_exec_s1`・`capex_plan_s1`・`ocf_s`（×3）・`profit_s`（×3）・`int_burden_s`（×3）・`tax_s`（×3）・`sales_s`（×3）・`cost_capital_s`（×3）・`coverage_agg`・`fin_cond`・`spread`・`equity_val`・`lend_stance`・`y_s1`・`y_s2`・`y_s3`・`y_s5`・`invest_s2`・`util_s2`・`util_s3`・`inv_ratio_s2`・`inv_ratio_s3`・`cons` |
| 3 | `price_s2`・`price_s3`・`emp_tot` |

**状態ベクトルの次元**: 役割 `state` の 22 変数（#165 §4.4）+ 遅延バッファ（深さ 1 が 34 本、深さ 3 が 3 本 = 9 スロット）= **65**。28 期のシミュレーションでは計算量の制約にならない（§15.7）。

---

## 14. baseline・初期状態・定常条件

### 14.1 baseline の定義

**候補の比較**

| 候補 | 内容 | 採否 |
|---|---|---|
| (a) 定常状態（成長率ゼロ） | すべての水準変数が一定 | **採用** |
| (b) 均衡成長経路 | すべての水準が共通率 `g` で成長 | 不採用 |
| (c) 安定した基準経路（データから与えるトレンド） | baseline を実データの平滑経路として与える | 不採用（初期MVP） |

**採用理由**

1. **契約 §2.1 が助走区間（`t = -8 … -1`）で baseline からの乖離ゼロを要件としている**。定常状態なら「乖離ゼロ」が「水準一定」として直接検証できる。
2. **診断はすべて baseline 比乖離 `dx_t` で行う**（契約 §2.4）。水準トレンドは `dx_t` で相殺されるため、成長経路を持つ利得が判定問題に対して存在しない。
3. **(b) は識別できない自由度を増やす**。均衡成長経路では資本係数・在庫比率・受注残比率・雇用の同時整合に加え、成長率と減耗率・調整速度の関係が制約になる。成長率を較正する観測量（AI 関連設備の長期成長率）は本モデルの標本期間で識別できない。
4. **(c) は #170 の履歴再生で必要になる**が、その場合の baseline は「実データのトレンド」であり、モデル構造から生成される基準経路ではない。初期MVPの判定問題（Q1–Q5）はいずれもショック応答であり、シナリオ間の差として評価される。トレンドの扱いは #170 が定める。

**帰結**: baseline（`Sc0`）では `y_tot` が一定である。**この定常性を「モデルが安定である根拠」として提示しない**（因果グラフ §5 の契約と同型）。定常状態は較正で課した構造であり、安定性の証明ではない。

### 14.2 初期状態の与え方（逆較正）

**決定: 定常水準を与えて構造パラメータを逆算する（inverse calibration）。定常状態を非線形ソルバで解かない。**

| 論点 | 決定 | 根拠 |
|---|---|---|
| 前向き解法（パラメータから定常状態を数値的に解く） | 採らない | `y_s5` を含むスカラー不動点（`y_s5 → order_gen_s → y_s → emp_s → hh_income → cons → y_s5`）が生じ、非線形ソルバが必要になる。§2.2 の決定（`NLsolve` を必要としない）と両立しない |
| 逆較正 | **採用**。定常水準を目標として与え、それを定常状態にする `st_` パラメータを閉形式で逆算する | すべての導出が代数的である（下表）。#170 の較正は「定常水準の目標値を実データから決める」作業になり、パラメータ推定と分離できる |
| `steady_state(m)` の返り値 | 与えられた定常水準（`SimulationResult` 相当の 1 期分） | 数値解ではないため収束判定・反復回数を持たない |
| 前向き数値解の位置づけ | #170 の数値解法頑健性確認で用いる（定常状態から出発して 28 期進めたとき水準が動かないことの検証） | 契約 Q5 の「分岐が数値解法の産物でないことの確認」 |

**逆較正の導出順序（閉形式）**

| # | 与える定常水準（#170 が実データから決める） | 逆算する `st_` パラメータ |
|---|---|---|
| 1 | `y_s^{ss}`（`s ∈ SR`）・`util_s^{ss}`・`emp_s^{ss}` | `bh_util_tgt_s = util_s^{ss}`（`SP`）・`st_lprod_s = y_s^{ss} / emp_s^{ss}` |
| 2 | `cap_s^{ss}` | `st_cor_s = cap_s^{ss} · bh_util_tgt_s / y_s^{ss}` |
| 3 | `dep_s^{ss}`（BEA 減耗率） | `st_delta_s = dep_s^{ss} / cap_s^{ss}` |
| 4 | `capex_pipe_s^{ss}` | `st_pipelag_s = capex_pipe_s^{ss} / (st_delta_s · cap_s^{ss})` |
| 5 | `capex_exec_s1^{ss}` | 整合条件 `capex_exec_s1^{ss} = st_delta_s1 · cap_s1^{ss}` を**検証**（自由度なし） |
| 6 | `compute_dem^{ss} = y_s1^{ss}` | `st_cd0 = compute_dem^{ss}`（`ai_exp^{ss} = 1`）・`bh_util_tgt_s1 = st_cor_s1 · compute_dem^{ss} / (cap_s1^{ss} + capex_pipe_s1^{ss})` |
| 7 | `order_cap_s^{ss}`（資本財の供給元構成） | `st_capex_share_s`・`st_invest_share_s`・`st_capfrac_s3 = order_cap_s3^{ss} / y_s3^{ss}` |
| 8 | `backlog_s^{ss}`・`inv_s^{ss}` | `bh_backlog_target_s = backlog_s^{ss} / demand_gen_s^{ss}`・`bh_inv_target_s = inv_s^{ss} / y_s^{ss}` |
| 9 | `order_gen_s^{ss}` = `y_s^{ss}` の残差 | `st_gen_share_s = order_gen_s^{ss} / y_s5^{ss}` |
| 10 | `va_s^{ss}`・`wagebill_s^{ss}` | `st_va_share_s = va_s^{ss} / sales_s^{ss}`・`st_wbase_s = wagebill_s^{ss} / emp_s^{ss}`（`wage^{ss} = 1`） |
| 11 | `debt_s^{ss}`・`cash_s^{ss}`・`spread^{ss}`・`policy_rate^{ss}` | `st_dcap_s ≥ debt_s^{ss} / sales_s^{ss}`・`st_spread0 = spread^{ss}`・`st_pol_ref = policy_rate^{ss}`・`st_cc0_s = cost_capital_s^{ss}` |
| 12 | `cons^{ss}`・`hh_income^{ss}`・`xdem_s5^{ss}` | `st_cons_auto = cons^{ss} − bh_mpc · hh_income^{ss}`・`st_xdem0 = xdem_s5^{ss}`・`st_cons_share_s1 = cons_s1^{ss} / sales_s1^{ss}` |
| 13 | — | `st_profit_ref = Σ profit_s^{ss}`・`st_emp_ref = emp_tot^{ss}`・`st_extdem_s = ext_demand_s^{ss}`・`st_coll_ltv`（`pl_ltv` との整合、許容条件 14） |

### 14.3 定常条件（自動テストする整合条件）

`steady_state(m)` は次を検証する。違反を `ss_inconsistent` として構造化記録し、`simulate` を実行しない。

| ID | 条件 | 由来 |
|---|---|---|
| `SS-1` | 外生変数が baseline 値（`ai_exp = 1`・`price_s1 = 1`・`capex_plan_shock_ex = 1`・`spread_shock_ex = 0`・`policy_rate = st_pol_ref`・`ext_demand_s = st_extdem_s`） | §4.2 |
| `SS-2` | `fin_cond = 0`・`equity_val = 1`・`spread = st_spread0`・`lend_stance = 0`・`rollover = 1`（したがって `repay_s = 0`・`refin_s = matur_s`） | `E5-01`–`E5-07`・許容条件 14・15 |
| `SS-3` | `capex_gap_s1 = 0`・`inv_gap_s = 0`・`cancel_s1 = 0`・`capex_defer_s1 = 0`・`plan_carry_s1 = 0` | `E6-03`・`E6-09`・`E7-18` |
| `SS-4` | `capstart_s = I_s = st_delta_s · cap_s`・`capex_pipe_s = st_pipelag_s · st_delta_s · cap_s` | `E12-01`–`E12-03` |
| `SS-5` | `cap_s1 + capex_pipe_s1 = target_cap_s1` | `E6-03 = 0` |
| `SS-6` | `util_s = bh_util_tgt_s`（`s ∈ SP`）かつ `util_s1 = bh_util_tgt_s1 · (1 + st_pipelag_s1 · st_delta_s1)` | §6.2 の帰結 |
| `SS-7` | `y_s = ship_s = ship_desired_s`・`inv_ratio_s = bh_inv_target_s ≤ bh_inv_thresh_s`・`y_cut_s = 0` | `E9-05`–`E9-10`・許容条件 7 |
| `SS-8` | `backlog_s = bh_backlog_target_s · demand_gen_s` かつ `demand_gen_s = (order_gen_s + ext_demand_s) / (1 − bh_backlog_target_s)` | `E9-03`・`E9-04`・`E12-06` |
| `SS-9` | `price_s = 1`（`price_tgt_s = 1` すなわち `util_s = bh_util_tgt_s`） | `E9-15`・`E9-16`・`SS-6` |
| `SS-10` | `emp_s = emp_req_s = y_s / st_lprod_s`（`S3` は `E10-03` の括弧内が `y_s3` に一致すること） | `E10-01`–`E10-07`・`st_capfrac_s3` の定義 |
| `SS-11` | `wage = 1`（`emp_tot = st_emp_ref`） | `E10-09` |
| `SS-12` | `cons = bh_mpc · hh_income + st_cons_auto`・`y_s5 = cons_s5 + st_xdem0` | `E10-13`・`E10-17` |
| `SS-13` | `unmet_cap_s = 0`（仮定 A-2 が成立） | `E9-14` |
| `SS-14` | **`profit_s = int_burden_s + tax_s + div_s` かつ `Δnw_s = 0`**。`pl_tau_corp = 0` のもとでこれは `st_payout_s = 1` と同値である | `E12-10`・`E12-11` が `Δcash_s = Δdebt_s = 0` を要求することから導出（下記） |
| `SS-15` | `need_s = 0`・`newdebt_s = 0`・`draw_s = 0`・`internal_s = I_s`・`fundable_s ≥ I_s`・`liquidity_gap_s = 0`・`funding_forced_s = 0` | `E7-13`・`E11-13`–`E11-15` |
| `SS-16` | #166 §8.1 の 12 検証項目がすべて `acc_pass` | #166 §8 |
| `SS-17` | `|s5_net_sx| / y_tot ≤ 0.05` | #166 §8.3 |

**`SS-14` の導出（非自明な整合条件）**

定常状態では `Δcash_s = 0` と `Δdebt_s = 0` が要求される。`E12-11` と `writeoff_s ≡ 0`・`repay_s = 0`（`SS-2`）より `newdebt_s = 0`。`E12-10` より

```
0 = ocf_s − int_burden_s − tax_s − div_s − I_s
```

`ocf_s = profit_s + dep_s − dinv_s`、`dinv_s = 0`（`SS-7`）、`I_s = capstart_s = dep_s`（`SS-4`）を代入すると

```
profit_s = int_burden_s + tax_s + div_s
```

`E7-02` の `div_s = st_payout_s · (profit_s − int_burden_s − tax_s)` を代入すると

```
(1 − st_payout_s) · (profit_s − int_burden_s − tax_s) = 0
```

したがって **`st_payout_s = 1`**（利払い・納税後の利益を全額分配）または `profit_s = int_burden_s + tax_s`（利益が利払いと納税にちょうど等しい）である。後者は較正の自由度を 1 つ潰すため、baseline では前者を採る。

**経済的な意味**: 成長率ゼロの定常状態では資本ストックが一定であり、投資は減価償却で賄われる。したがって内部留保はゼロでなければならない。`st_payout_s < 1` は純資産（現金）の恒常的な蓄積を意味し、成長のない定常状態と両立しない。この条件は §13.4 の許容条件 12 として実装時に検査する。

### 14.4 初期状態と助走区間

| 項目 | 決定 |
|---|---|
| `t = -8` の期首状態 | §14.2 の定常水準。役割 `state` の 22 変数すべてを定常値で初期化する |
| 遅延バッファの初期化 | 定常値で埋める（`x[t−k] = x^{ss}` for all `k`）。ゼロで埋めない |
| 助走区間の要件 | `t = -8 … -1` で全変数が定常値から動かないこと。相対乖離が `solver.runup_tol`（既定 `1e-8`、§13.1）を超えた期を `runup_deviation` として警告する（契約 §2.1） |
| Q5 の初期状態走査 | 契約 §3 Q5 の走査変数（初期債務比率・利払いカバレッジ・初期稼働率・初期在庫比率）を変えるとき、**定常条件を再度満たすよう逆較正を再実行する**。定常状態でない初期値から出発すると助走区間で乖離が生じ、`runup_deviation` になる |
| 初期状態指定 API | #171。本書は「定常条件を満たす初期状態のみを受け付ける」ことのみ確定する |

### 14.5 複合ショックの適用方法

| 項目 | 決定 |
|---|---|
| シナリオ | 契約 §5.1 の `Sc0`–`Sc4` を用いる。入れ子契約（`Sc1 ⊂ Sc2 ⊂ Sc3 ⊂ Sc4`）を守る |
| 複数ショックの合成 | [イベント変換契約](../architecture/macro_event_contract.md) §5.2 の固定順合成（絶対 → 乗算 → 加算）で**モデル層に入る前に**確定済み。モデル層は合成後の外生パスのみを受け取る（§4.1） |
| 期首一括適用 | [シナリオ時間軸](../architecture/scenario_time_semantics.md) §3.2。ステップ 1 で適用する。**期中適用・期内按分を行わない** |
| 適用順序の依存性 | 期内の適用順序は存在しない（合成済みの値を 1 回だけ適用する）。期を跨ぐ順序差は順序依存ではなく動学である（#168 §5.6-2） |
| 同一実行内の一貫性 | すべてのシナリオを同一の初期状態・同一のパラメータセット・同一の数値ガード設定で実行する（契約 §5.3） |

---

## 15. 数値ガード・制約・失敗契約

### 15.1 3 層の分離（本書の中心的な決定）

Issue #169 §10 は「hard clamp とシミュレーション失敗を区別する」ことを要求している。本書は制約を 3 層へ分離する。

| 層 | 名称 | 内容 | 実装 | 記録 |
|---|---|---|---|---|
| **T1** | 経済制約 | 関数形の一部としての上下限・飽和（`max(x, 0)`・`min(x, 上限)`・`clamp(x, 0, 1)`・`tanh`） | 式に組み込む | 拘束したことを `binding` フラグとして診断へ出力する。**警告ではない** |
| **T2** | 制約違反 | #165 §5.1 の符号制約・範囲制約の違反 | **クリップしない**。値をそのまま保持して続行する | `:sign_constraint` 検証で `acc_fail` 相当として構造化記録する。**モデルの誤りとして扱う** |
| **T3** | 数値ガード | 非有限値（`NaN` / `Inf`）・発散（`|state| > guard_max`） | 当該期以降を invalid として**打ち切る** | `termination_reason` / `termination_period` に記録する |

**契約**:

- **T1 は clamp ではない**。`max(capex_plan_s1, 0)` は「投資は負にならない」という経済的な事実であり、数値の辻褄合わせではない。T1 の箇所を §15.2 に**網羅的に列挙する**ことで、「どこで clamp しているか分からない」状態を作らない。
- **T2 では自動補正しない**（[ADR 0007](../adr/0007-sfc-integration-contract.md) §5・#165 §5.1・#166 §8.3）。T2 が発生した場合、それは実装の誤りか §13.4 の許容条件を満たさないパラメータセットであり、値を丸めて隠してはならない。
- **T2 を T3 へ読み替えない**。符号制約違反はシミュレーションを止めない（§15.6 の `:sign_constraint_fatal` は明示的に有効化した場合のみ）。
- **T3 でも例外を投げない**（#166 §8.3）。結果を保持し、invalid 期を明示する。
- **本モデル専用の許容誤差規約を作らない**（[ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md) §3.1）。許容誤差は #166 §8.2（`atol = 1e-8`・`rtol = 1e-6`）を継承する。

### 15.2 T1（経済制約）の網羅的列挙

| 式 | 制約 | 経済的意味 | `binding` フラグ |
|---|---|---|---|
| `E5-02` | `equity_val ≥ st_ev_min` | 株式評価は正 | `equity_floor_binding` |
| `E5-05` | `spread ≥ 0` | 負のスプレッドを許さない | `spread_floor_binding` |
| `E5-07` | `rollover ∈ [0, 1]` | 借換比率の定義域 | `rollover_binding` |
| `E5-16` | `cost_capital_s ≥ 0` | 負の資本コストを許さない | `cc_floor_binding` |
| `E6-05`・`E6-15` | `liq_s ∈ [0, 1]` | 流動性充足度の定義域 | `liq_binding` |
| `E6-07`・`E6-16` | `capex_plan_s1 ≥ 0`・`invest_plan_s ≥ 0` | 投資計画は負にならない | `plan_floor_binding` |
| `E6-09` | `cancel_s1 ∈ [0, bh_cancel_max]` | キャンセル率の定義域と上限 | `cancel_binding` |
| `E7-02` | `div_s ≥ 0` | 負の配当（株主からの拠出）を許さない | `div_floor_binding` |
| `E7-10`–`E7-13` | `cash_free_s`・`debt_cap_s`・`newdebt_max_s`・`fundable_s ≥ 0` | 資金源は負にならない | `fundable_floor_binding` |
| `E7-15`–`E7-18` | `defer_roll_s1`・`defer_max_s1`・`defer_need_s1` `≥ 0`、`capex_defer_s1 ≤ defer_max_s1` | 延期額は非負かつ契約確定分を超えない | `defer_cap_binding`（`B3` の作動） |
| `E7-21` | `invest_s ≤ fundable_s` | 資金制約 | `invest_funding_binding`（`B2` の作動） |
| `E8-03` | `order_gen_s ≥ 0` | 需要は負にならない | `order_gen_floor_binding` |
| `E9-04` | `ship_desired_s ≥ 0` | — | — |
| `E9-07` | `y_cut_s ≥ 0`（`max(0, inv_ratio − thresh)`） | 在庫が目標以下なら減産しない | `inv_threshold_binding`（`NL-2` の作動） |
| `E9-08` | `0 ≤ y_s ≤ bh_util_max_s · ycap_s` | 能力上限 | `capacity_binding`（`L59` の作動） |
| `E9-10` | `ship_s ≤ y_s + inv_s[t−1]` | 在庫を超えて出荷できない | `supply_binding`（`B1` の作動） |
| `E9-16` | `price_s ≥ st_price_min_s` | 価格は正 | `price_floor_binding` |
| `E9-18` | `y_s1 ≤ bh_util_max_s1 · ycap_s1` | 能力上限 | `capacity_binding_s1`（`R1a` の作動） |
| `E10-07` | `emp_s ≥ 0` | 雇用は負にならない | `emp_floor_binding` |
| `E10-09` | `wage ≥ st_wage_min` | 賃金は正 | `wage_floor_binding` |
| `E10-13` | `cons ≥ 0` | 消費は負にならない | `cons_floor_binding` |
| `E10-14` | `cons_s1 ≤ cons` | 部門別消費は総消費を超えない | `cons_split_binding` |
| `E11-14` | `draw_s ≥ 0`・`newdebt_s ≥ 0` | 現金取崩・新規調達は非負 | — |

**契約**: `binding` フラグは診断層の出力である（`Vector{Bool}` を `Vector{Float64}` として `SimulationResult.variables` へ出力するのではなく、診断結果型で返す）。`capacity_binding`・`supply_binding`・`inv_threshold_binding`・`defer_cap_binding`・`invest_funding_binding` は §16.2 のループ作動判定・§16.4 の遮断経路作動判定に用いる。

### 15.3 T2（符号制約）と構造的保証

#165 §5 の符号制約について、**式の構造から保証されるもの**と**検証のみで担保されるもの**を区別する。

| 変数 | 制約 | 保証 | 根拠 |
|---|---|---|---|
| `cap_s` | `> 0` | **構造的** | `E12-03` と `0 < st_delta_s < 1`（許容条件 3）より `cap_s ≥ (1 − st_delta_s) · cap_s[t−1] > 0` |
| `capex_pipe_s` | `≥ 0` | **構造的** | `E12-01`・`E12-02` と `st_pipelag_s ≥ 1`（許容条件 4） |
| `inv_s` | `≥ 0` | **構造的** | `E9-10`（`ship_s ≤ y_s + inv_s[t−1]`）より `E12-04` が非負 |
| `backlog_s` | `≥ 0` | **構造的** | `E9-11`（`ship_gen_s ≤ ship_desired_s − demand_cap_s = (1 − bh_backlog_target_s) · demand_gen_s ≤ demand_gen_s`）より `E12-06` が非負 |
| `cash_s` | `≥ 0` | **構造的** | `E11-14` により `cash_s = cash_s[t−1] − draw_s` かつ `draw_s ≤ cash_free_s ≤ cash_s[t−1]` |
| `debt_s` | `≥ 0` | **構造的** | `E12-11` と `repay_s ≤ matur_s = φ_s · debt_s[t−1] ≤ debt_s[t−1]`（許容条件 5） |
| `plan_carry_s1` | `≥ 0` | **構造的** | `E12-09` と `bh_revive_s1 ≤ 1`・`capex_defer_s1 ≥ 0` |
| `y_s`・`ship_s`・`order_s`・`emp_s`・`cons`・`hh_income` | `≥ 0` | **構造的** | T1 の下限（§15.2） |
| `util_s` | `0 ≤ x ≤ 1.2` | **構造的** | `E9-08` と `bh_util_max_s ≤ 1.2`（許容条件 6） |
| `price_s`・`wage`・`equity_val`・`ai_exp`・`price_s1` | `> 0` | **構造的** | T1 の下限、外生はイベント層が拒否（#168 §6.3） |
| `spread`・`cost_capital_s`・`int_burden_s`・`matur_s`・`repay_s` | `≥ 0` | **構造的** | T1 の下限と `policy_rate ≥ 0`・`rollover ∈ [0,1]` |
| `y_tot` | `> 0` | **検証のみ** | `y_tot = Σ va_s + y_s5`。各項は非負だが全項ゼロは排除されない |
| `emp_tot` | `> 0` | **検証のみ** | 同上 |
| `cons_s5` | `≥ 0` | **構造的** | `E10-14` の `min(·, cons)` |
| `s5_net_sx` | 符号制約なし | — | 残差。大きさを §16.9 で監視する |

**契約**: 上表で「構造的」とした制約について、**T2 の違反が発生した場合はパラメータセットが §13.4 の許容条件を満たしていないか実装に誤りがある**。したがって `:sign_constraint` 検証は「起きてはならないことが起きたか」を検出するテストであり、通常の運用では常に `acc_pass` になる。この性質を #170 の反例テスト（#166 §8.4）で確認する。

### 15.4 ゼロ除算

**規則**: 除算 `a / b` について `|b| ≤ solver.div_eps`（既定 `1e-8`、単位は分母の単位）のとき、結果を `NaN` とし、当該診断量を `*_invalid` として構造化記録する。**例外を投げない。`0` で代替しない。分母を `max(b, eps)` へ置き換えない**（置き換えると「除算できた」という誤った記録が残る）。

| 式 | 除算 | 分母がゼロになる状態 | 扱い |
|---|---|---|---|
| `E5-07` | `Σ debt_s[t−1] / collateral` | 全部門の実物資産がゼロ | `rollover = NaN`・`:rollover_invalid` |
| `E5-17` | `Σ ocf_s / Σ int_burden_s` | 全部門が無借金 | `coverage_agg = NaN`。ただし `E5-04` の閾値項は **`0` として評価する**（§5.5 の契約） |
| `E6-05`・`E6-15` | `cash_s / (st_cash_ref_s · sales_s[t−1])` | 売上ゼロ | `liq_s = NaN`・`:liq_invalid` |
| `E6-08` | `Δcapex_plan_s1 / capex_plan_s1[t−1]` | 前期計画ゼロ | 式に `max(·, div_eps)` を明示的に置く（§6.4）。**この 1 箇所のみ例外的に分母を下限で置く**。根拠: 前期計画がゼロのとき「修正率」は定義できないが、キャンセル率は `0` であるべきであり（削るものが無い）、`NaN` を伝播させるとキャンセル判定全体が無効化される。この読み替えを行う箇所は本式のみである |
| `E8-01`・`E8-02`・`E10-03` | `· / price_s[t−1]` | — | `price_s ≥ st_price_min_s > 0` により発生しない（T1） |
| `E9-09`・`E9-19` | `y_s / ycap_s` | — | `ycap_s > 0` により発生しない（`cap_s > 0`・`st_cor_s > 0`） |
| `E11-07` | `profit_s / sales_s` | 売上ゼロ | `margin_s = NaN`・`:margin_invalid` |
| `E11-10` | `ocf_s / int_burden_s` | 無借金 | **`funding_pressure_s` の precedence で先に分岐する**（§16.8）。`debt_s[t−1] ≤ st_debt_tol` なら `fp_unlevered`、それ以外で分母ゼロなら `fp_invalid` |
| `E11-12` | `ocf_s / debt_service_s` | 無借金かつ返済ゼロ | 同上 |
| `E11-19` | `order_gen_s / (order_gen_s + ext_demand_s)` | 一般需要・外生需要がともにゼロ | `gen_frac_s = NaN`。この場合 `ship_gen_s = 0` でもあるため `d_{S5,s} = d_{SX,s} = 0` として評価する |
| `E12-07`・`E12-08` | `inv_s / y_s`・`backlog_s / y_s` | 産出ゼロ | `NaN`・`:ratio_invalid`。`E9-07` の `inv_ratio_s[t−1]` が `NaN` の場合、`y_cut_s = 0` として評価する（減産の根拠が無い） |
| `E12-12` | `debt_s / sales_s` | 売上ゼロ | `NaN`・`:leverage_invalid` |
| 比較層 | `(x − x^{base}) / x^{base}` | baseline がゼロ | 比較層の責務（#165 §6.4 の `d_` 接頭辞）。モデルは `dx_t` を生成しない |

**`NaN` の伝播を止める箇所を限定する**: 上表で「`0` として評価する」としたのは 4 箇所（`E5-04` の閾値項・`E6-08` の分母・`E9-07` の減産項・`E11-19` の配分）のみである。それ以外では `NaN` を伝播させ、`*_invalid` として記録する。**伝播を止める箇所を実装者が追加しない**。

### 15.5 警告の一覧

構造化して記録し、シミュレーションを止めない。

| 警告コード | 発生条件 | 意味 | 出所 |
|---|---|---|---|
| `runup_deviation` | 助走区間（`t = -8 … -1`）で定常値からの相対乖離が `solver.runup_tol` を超える | 初期値が定常状態にない。**診断を実行せず警告とする**（契約 §2.1） | 契約 §2.1 |
| `a2_violation` | `unmet_cap_s > 0`（`E9-14`） | 仮定 A-2 が破れ、資本財需要が当期に充足されなかった。`capex_exec_s1` が売り手の供給能力に制約された | #166 §3.5・§12-5 |
| `funding_forced` | `funding_forced_s > 0`（`E11-15`） | 事前の債務上限を超えた調達が生じた。契約確定額（`E7-14`）が資金源を上回った | §7.3 |
| `liquidity_gap` | `liquidity_gap_s > 0`（`E7-20`） | 資金調達ギャップ。計画の縮小が必要な状態 | #166 §7.3 |
| `cash_below_min` | `cash_s < st_cash_min_s · sales_s[t−1]` | 最低現金保有を下回った | §7.2 |
| `threshold_proximity` | 5 つの閾値のいずれかの近傍（§16.4） | 感応度の併記が必須 | #168 §5.6-3 |
| `extreme_shock` | 外生入力が baseline 比 ±50% を超える | イベント層が記録（#168 §6.3）。モデル層は継承して出力する | #168 §6.3 |
| `acc_warning` / `acc_fail` / `acc_invalid` | #166 §8.1 の検証結果 | 会計検証層が記録 | #166 §8.3 |
| `sign_constraint` | T2 の違反（§15.3） | 実装の誤りかパラメータ不正 | #165 §5.1 |
| `ss_inconsistent` | §14.3 の定常条件違反 | 初期状態が定常状態でない | §14.3 |

**契約**: 警告は `metadata["warnings"]` へ**構造化された配列**として格納する。要素は `(code, period, sector, detail)` の 4 項目を持つ。文字列を連結した単一の警告文にしない。既存の `warnings` フィールドを持つ型（`CrossModelReasoningContext` 等）と同じ設計方針である。

### 15.6 T3（打ち切り）契約

| 状況 | 判定 | 扱い |
|---|---|---|
| 非有限値 | いずれかの `state` 変数が `!isfinite` | 当該期を `termination_period` に記録し、`termination_reason = :non_finite_state`。当該期以降を invalid 期に分類する |
| 発散 | いずれかの `state` 変数の絶対値が `solver.guard_max`（既定 `1e6`、単位 10億ドル）を超える | `termination_reason = :divergence_guard`。`divergence_time` に記録する（既存 Minsky 診断層の語彙を再利用） |
| 正常終了 | `t = 19` まで到達 | `termination_reason = :completed` |
| 符号制約違反での停止 | `solver.stop_on_sign_violation = true`（既定 `false`）のときのみ | `termination_reason = :sign_constraint_fatal`。**既定では停止しない**（§15.1 の T2 の契約） |

**`metadata` 予約キー**（本書が新設するもの）

| キー | 型 | 内容 |
|---|---|---|
| `metadata["equations_version"]` | `String` | `"capex-credit-cycle-equations/1.0.0"` |
| `metadata["termination_reason"]` | `String` | 上表の 4 値のいずれか |
| `metadata["termination_period"]` | `Int` または `nothing` | 打ち切りが生じた期。正常終了なら `nothing` |
| `metadata["divergence_time"]` | `Int` または `nothing` | 発散を検出した最初の期 |
| `metadata["warnings"]` | `Vector{Dict{String,Any}}` | §15.5 の構造化警告 |
| `metadata["unit_conversions"]` | `Dict{String,String}` | §4.3 の換算式（`"bp_to_pct_pt" => "spread / 100"`・`"annual_to_quarter" => "r * 0.25"`） |

**契約**:

- `SimulationResult` 型を変更しない（[責務境界](capex_credit_cycle_model_boundaries.md) §5.7・[ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md) 決定 8）。上記はすべて `metadata::Dict{String,Any}` の予約キーである。
- **他モデルへ同じキーを要求しない**（同 §5.7 の契約）。
- 打ち切りが生じた結果を LLM 説明層へ渡す場合、**打ち切りの事実と理由を必ず明示する**（§18 の必須記載事項）。
- `guard_max = 1e6`（10億ドル単位で `10^15` USD）は既存 `SolverOptions` の既定値を継承する。本モデル専用の値を新設しない。

### 15.7 計算量

| 項目 | 見積り |
|---|---|
| 状態ベクトル次元 | 65（§13.5） |
| 1 期あたりの評価 | 代数式約 130 本。反復なし |
| 1 実行 | 28 期 × 130 = 約 3,600 回の式評価 |
| 契約 Q5 の 1 次元スイープ | 5 変数 × 格子点数（例 21）= 105 実行 |
| 契約 Q4 の 2 次元スイープ | 規模 × 遅延（例 11 × 9）= 99 実行 |
| 契約 Q2 の反実仮想 | 各実行につき 2 倍 |
| ヤコビアン評価（§16.2） | 前進差分で 65 + 1 = 66 回の 1 期評価 / 期。28 期で約 1,850 回 |

**結論**: 反復解法を持たないため、スイープを含めても計算量は問題にならない。#165 §9-8 が #169・#170 へ委ねた「状態数増大の数値解法・計算量への影響」の評価結果である。

---

## 16. 診断層の契約

### 16.1 診断層の分離

**契約**（[責務境界](capex_credit_cycle_model_boundaries.md) §3.2-2・[ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md)）:

- 診断層は**読み取り専用**である。モデル本体の動学に影響しない（ADR 0003 の Minsky 診断層と同方針）。
- 診断閾値はモデル方程式へハードコードせず、**閾値セットとして外部化**し識別子とバージョンを出力へ含める（契約 §4.4）。`metadata["diagnostic_threshold_set"]`。
- 会計検証（#166 §8）は行動方程式と独立に走る（[責務境界](capex_credit_cycle_model_boundaries.md) §3.2-3）。

### 16.2 ループ作動フラグと利得評価方式

因果グラフ §4.1 は「合成利得を各ループ利得の単純和として計算・提示しない。ヤコビアンの固有値または数値的なインパルス比として評価する方式を #169 で定める」ことを要求している。

**決定: 2 つの指標を併用し、どちらも単一の値でループを特徴づけない。**

**(A) 局所的な増幅の強さ: 数値ヤコビアンのスペクトル半径**

```
E16-01  J_t[i,j] = ( f_i(x_t + h_j e_j) − f_i(x_t) ) / h_j ,   h_j = jac_h · max(1, |x_{t,j}|)
E16-02  ρ_t = max_k |λ_k(J_t)|
```

`f` は「期首状態ベクトル → 期末状態ベクトル」の写像（§3.1 のステップ 2–9 を 1 回適用したもの）。`x_t` は当該期に実現した期首状態である。`jac_h` は前進差分の摂動幅（診断閾値セットの設定値、既定 `1e-6`）。

| 契約 | 内容 |
|---|---|
| `ρ_t` は**状態依存**である | 単一の値として報告しない。評価期間の系列と、その最大値・最大値の時点を報告する |
| `ρ_t > 1` を「発散する」と述べない | 局所線形化の性質であり、閾値・飽和により大域的には収束しうる。因果グラフ §9-6（「ループ利得は状態依存であり、単一の数値で特徴づけられない」）を継承する |
| 摂動幅の感応度 | `jac_h` を 10 倍・0.1 倍したときの `ρ_t` の変化を #170 の頑健性確認に含める。閾値近傍では前進差分が不安定になりうる |

**(B) ループ別の寄与: 反実仮想インパルス比**

```
E16-03  gain(loop) = |peak(dz^{full})| / |peak(dz^{loop-off})|
```

`dz` は当該ループの代表変数の baseline 比乖離、`loop-off` は当該ループを構成する**行動エッジの弾性を `0` に固定した再実行**である。

| ループ | 代表変数 `z` | `loop-off` の操作 |
|---|---|---|
| `R1a` | `capex_exec_s1` | `E7-09` の `ocf_s1[t−1]` を定常値 `ocf_s1^{ss}` に固定する（`L41` の内部資金経路を切る）。固定するパラメータが無い経路であるため、**変数の固定として実装する** |
| `R1b` | `Σ_{s∈SP} y_s` | `E7-09` の `ocf_s[t−1]`（`s ∈ SP`）を定常値に固定する（`L62` を切る） |
| `R2` | `Σ_{s∈SF} I_s` | `bh_spread_cov = 0`（`L30` を切る） |
| `R2` 短絡 | `spread` | `bh_spread_cov = 0` かつ `E5-13` の `r_new_s` を定常値に固定 |
| `R3` | `capex_exec_s1` | `bh_roll_slope = 0`（`L32` を切る） |
| `R4` | `cons` | `st_gen_share_s = 0`（`L50` を切る） |

| 契約 | 内容 |
|---|---|
| 単純和を用いない | ループはノード（`profit_s`・`order_s`）を共有しており、`gain(R1b) + gain(R2)` は合成利得にならない（因果グラフ §4.1） |
| `loop-off` は 1 ループずつ | 複数ループを同時に切った結果を「各ループの寄与」として提示しない |
| 定義できない場合 | `peak(dz^{loop-off}) = 0` のとき比を報告せず `indeterminate` とする（契約 Q2 の `A` と同型） |
| `R1a` の扱い | `capacity_binding_s1`（§15.2）が全期 `false` のとき `gain(R1a)` は 1 に極めて近い。この場合「`R1a` は作動していない」と報告し、比の値を強調しない |

**ループ作動フラグ**

```
E16-04  active(R1a) = capacity_binding_s1 が 1 期以上 true
        active(R1b) = supply_binding または inv_threshold_binding が 1 期以上 true
        active(R2)  = coverage_agg[t−1] < bh_cov_threshold が 1 期以上成立
        active(R3)  = rollover < 1 が 1 期以上成立
        active(R4)  = λ_s ≠ 0（s ∈ SR、デッドバンド外）が 1 期以上成立
```

### 16.3 R2 短絡ループの独立評価

因果グラフ §4 R2 の注記は「`SPREAD → INT_BURDEN_s → COVERAGE_s → SPREAD` の短絡ループの利得を独立に評価することを設計要件とする」と定めている。1 周利得を閉形式で与える。

```
E16-05  g_short = Σ_{s∈SF} [ (∂int_burden_s / ∂spread) · (∂coverage_agg / ∂int_burden_s) ]
                 · (∂spread / ∂coverage_agg)

        ∂int_burden_s / ∂spread    = φ_s · Δt · debt_s[t−1] / 10^4          （L35・E5-12・E5-13）
        ∂coverage_agg / ∂int_burden_s = − coverage_agg / Σ_{s∈SF} int_burden_s   （L29・E5-17）
        ∂spread / ∂coverage_agg    = − bh_spread_cov · bh_spread_pow
                                     · max(0, bh_cov_threshold − coverage_agg)^{bh_spread_pow − 1}
                                                                             （L30・E5-04）
```

`10^4` は bp → 小数の換算（`spread / 100` で %pt、さらに `/100` で小数）である。

| 契約 | 内容 |
|---|---|
| `g_short > 1` の意味 | 実体側（産出・利益）を経由せずに信用条件だけで自己強化する経路が作動している。**産出が回復しても信用条件が悪化し続ける**状態を示す |
| 報告 | 各期の `g_short` を診断系列として出力し、`> 1` となった期を明示する |
| 閾値項がゼロの領域 | `coverage_agg ≥ bh_cov_threshold` のとき `∂spread / ∂coverage_agg = 0` であり `g_short = 0`。閾値の外では短絡ループは作動しない |
| 1 期あたりの遅れ | `L30` の遅れ `1` により 1 周は 1 四半期。実体経由の R2（最短 4 四半期）より速い |

### 16.4 非線形性の所在と `threshold_proximity`

| ID | 所在 | 式 | 閾値パラメータ | 契約 Q5 との対応 |
|---|---|---|---|---|
| `NL-1` | 計画修正幅のキャンセル閾値 | `E6-09` | `bh_cancel_thresh` | 追加候補（因果グラフ §7.1 の #2） |
| `NL-2` | 目標在庫比率超での減産 | `E9-07` | `bh_inv_thresh_s` | **(iv) 初期在庫比率** |
| `NL-3` | カバレッジ閾値でのスプレッド急拡大 | `E5-04` | `bh_cov_threshold`・`bh_spread_pow` | **(ii) 利払いカバレッジ比率**・**(v) スプレッド感応パラメータ** |
| `NL-4` | LTV 上限での借換条件悪化 | `E5-07` | `pl_ltv` | **(i) 初期債務比率** |
| `NL-5` | 借換条件閾値での投資延期 | `E7-15` | `bh_roll_thresh` | 追加候補 |
| `NL-6` | 労働退蔵のデッドバンド | `E10-06` | `bh_emp_band_s` | 追加候補（因果グラフ §7.1 の #8） |
| `NL-7` | 能力上限・在庫上限による飽和 | `E9-08`・`E9-10`・`E9-18` | `bh_util_max_s` | **(iii) 初期稼働率** |

**`threshold_proximity` 診断**（#168 §5.6-3・[ADR 0010](../adr/0010-macro-event-scenario-contract.md) の要求）

```
E16-06  proximity(NL-k, t) = |状態量_t − 閾値| / max(|閾値|, div_eps) ≤ prox_band
```

`prox_band` は診断層の閾値セットの設定値（既定 `0.10`、§13.1）である。

| 契約 | 内容 |
|---|---|
| 検出対象 | `NL-1`–`NL-7` の 7 箇所すべて。#168 §5.6 が挙げた 5 箇所（`L06`・`L15`・`L30`・`L32`・`L40`）は `NL-1`・`NL-2`・`NL-3`・`NL-4`・`NL-5` に対応し、`NL-6`・`NL-7` は本書が追加した |
| 検出時の義務 | `threshold_proximity` を警告として記録し、**当該閾値を ±50% 変化させたときの診断ラベルを併記する**（契約 §4.4） |
| 閾値をまたいだ場合 | 近傍でなくてもまたいだ事実（`crossed(NL-k, t)`）を記録する |
| ハードコード禁止 | `prox_band` をモデル方程式へ埋め込まない。診断層の設定値として外部化する（契約 §4.4） |

### 16.5 `credit-off` 反実仮想の実装契約

契約 §3 Q2 は `credit-off` を「投資関数の信用条件感応パラメータ（資本コスト・貸出態度・借換条件の各弾性）を `0` に固定して再実行したもの。ショック系列・初期状態・乱数は変えない」と定めている。本書で固定するパラメータ集合を確定する。

| 固定するパラメータ | 値 | 対応エッジ | 根拠 |
|---|---|---|---|
| `bh_cc_elas_s1` | `0` | `L39` | 資本コスト弾性（`S1` の計画） |
| `bh_cc_elas_inv_s2` / `_s3` | `0` | `L64` | 資本コスト弾性（`SP` の投資） |
| `bh_lend_elas_inv_s2` / `_s3` | `0` | `L42` | 貸出態度弾性 |
| `bh_dcap_lend_s1` – `_s3` | `0` | `L42`（数量上限側） | 貸出態度が債務上限へ作用する経路 |
| `bh_defer_roll` | `0` | `L40` | 借換条件弾性（投資延期） |

| 固定しないパラメータ | 理由 |
|---|---|
| `E7-09`・`E7-10` の内部資金・現金経路（`L41`・`L62`） | 信用チャネルではなく**内部資金チャネル**である（因果グラフ §3.5） |
| `E5-11` の `repay_s`（`L63`） | 借換不能に伴う現金流出は会計エッジであり、信用条件の**弾性**ではない。ただし `rollover` 自体は内生のまま動くため、`credit-off` でも現金制約は作動する |
| `bh_spread_cov`・`bh_roll_slope`・`bh_coll_elas` | 信用条件の**生成**側であり、投資関数の感応パラメータではない。`credit-off` は「信用条件が投資へ伝わらない」反実仮想であって「信用条件が動かない」反実仮想ではない |
| `st_dcap_s` | 数量上限の基準水準は信用条件の変動ではない（§7.2） |

**契約**:

- `credit-off` は**同一実装内の反実仮想**である。信用チャネルを持たない別モデルとの比較で代用しない（契約 §3 Q2・[ADR 0006](../adr/0006-cross-model-reasoning-contract.md)）。
- 増幅度 `A = |peak(dI^{full})| / |peak(dI^{credit-off})|` の `dI` は `S1`–`S3` 合計の実行 CAPEX 乖離（`capex_exec_s1 + invest_s2 + invest_s3`）である。
- 結果を政策効果・チャネル寄与の**因果推定として提示しない**（契約 §8-4）。

### 16.6 `share_C`（消費経路の寄与シェア）の分解方式

契約 §3 Q3 は「`share_C` は総産出乖離を最終需要項目別へ分解した寄与の比。分解方式は #169 で確定する。分解が定義できない場合は Q3 を `indeterminate` とし `share_C` を報告しない」と定めている。

**決定: 反実仮想寄与分解（consumption-off）を主方式とし、加法分解を補助的に併記する。**

**(A) 主方式: 反実仮想寄与**

```
E16-07  share_C = ( peak(dY^{full}) − peak(dY^{cons-off}) ) / peak(dY^{full})
```

`cons-off` は `E10-13` の `cons` を baseline 系列に固定して再実行したものである（`bh_mpc = 0` かつ `st_cons_auto = cons^{ss}` と同値）。

| 論点 | 決定・根拠 |
|---|---|
| なぜ反実仮想か | 本モデルは非線形（`NL-1`–`NL-7`）であり、総産出乖離を最終需要項目別へ**加法的に**分解すると必ず残差が残る。残差を任意の項目へ配賦すると `share_C` の値が配賦規則に依存する |
| Q2 との一貫性 | 契約 §3 Q2 の増幅度 `A` も同一実装内の反実仮想として定義されている。同じ idiom を用いることで、Q2 と Q3 の解釈が揃う |
| 実行コスト | Q3 に追加 1 実行が必要になる。契約 §3 の「必要な実行構成」表は Q3 を「単一実行 + 寄与分解」としているが、**寄与分解が 1 実行を要することを本書で明示する**。#170 の実行計画へ引き渡す |
| 定義できない場合 | `peak(dY^{full}) = 0` のとき `share_C` を報告せず Q3 を `indeterminate` とする（契約 §3 Q3） |
| 提示上の制約 | `share_C` は**反実仮想寄与**であり因果推定ではない。契約 §8-4 の限界を併記する |

**(B) 補助方式: 加法分解（残差を明示する）**

```
E16-08  dY_t ≈ Σ_j μ_j · (D_{j,t} − D_{j,t}^{base}) + resid_t
        j ∈ { capex（capex_exec_s1）, invest（Σ invest_s）, cons（cons）,
              ext（Σ ext_demand_s）, xdem（xdem_s5） }
        μ_j = 当該最終需要項目 1 単位あたりの総付加価値換算係数（定常状態で評価）
```

| 契約 | 内容 |
|---|---|
| `resid_t` を隠さない | 加法分解を提示する場合、`resid_t / dY_t` を必ず併記する。残差が大きい期では加法分解を用いない |
| 主方式との不一致 | (A) と (B) の `share_C` が乖離する場合、**両方を報告し (A) を採用値とする**。乖離の大きさは非線形性の強さの指標である |
| `μ_j` の導出 | 定常状態で 1 単位の需要増を与えたときの `y_tot` の増分（1 期の直接効果のみ、乗数を含まない）。#170 で数値的に求める |

### 16.7 遅延型遮断の識別

因果グラフ §5 の注記は「`B1`・`B3` は利得を下げるのではなく作動を遅らせる経路である。`contained_adjustment` と判定された場合も、遅延型の遮断か真の収束かを区別して報告する」ことを #169 の診断出力要件としている。

```
E16-09  診断ラベルが contained_adjustment のとき、評価期間を +8 四半期延長（t = 0 … 27）して再実行し、
        延長区間で契約 §3 Q1 の (a)–(d) のいずれかが破れるかを判定する。

        delayed_containment = true   … 延長区間で条件が破れる（遅延型の遮断）
                            = false  … 延長区間でも条件を満たす（本グリッド上では真の収束）
```

| 契約 | 内容 |
|---|---|
| 延長は診断のためのみ | 延長区間の結果を判定ラベルへ反映しない。**契約 §2.1 の評価期間（20 四半期）を変更しない** |
| `delayed_containment = true` の報告 | 「評価期間内では収束したが、期間を延長すると再悪化する」ことを必ず明示する。`contained_adjustment` を単独で提示しない |
| どの経路が遅らせたか | `defer_cap_binding`（`B3`）・`supply_binding`（`B1`）の作動期を併記する（§15.2） |
| 「真の収束」と断定しない | `false` の場合も「延長した 28 四半期の範囲では条件を満たした」と記述する。期間をさらに延ばした場合を保証しない |

### 16.8 資金繰り圧力の診断（`funding_pressure_s`）

#166 §7.4 の 5 値ラベルをそのまま用いる。**Keen 側のラベル名（`hedge` / `speculative` / `ponzi`）を流用しない**。

| ラベル | 条件 | precedence |
|---|---|---|
| `fp_invalid` | `NaN` / `Inf` / 打ち切り後 | 1（最上位） |
| `fp_unlevered` | `debt_s[t−1] ≤ st_debt_tol` | 2 |
| `fp_interest_uncovered` | `ocf_s < int_burden_s − τ` | 3 |
| `fp_rollover_dependent` | `int_burden_s ≤ ocf_s < debt_service_s − τ` | 4 |
| `fp_covered` | `ocf_s ≥ debt_service_s − τ` | 5 |

`τ` は許容誤差（#166 §8.2 の `atol + rtol · scale`）である。

**契約**（#166 §7.4 を継承）:

- `fp_rollover_dependent` を Keen の `speculative` と**同一視しない**。
- 両モデルの区分系列を**同一の図に重ねて表示しない**。比較する場合は概念対応表を併記し `insufficient_comparability` を明示する（[ADR 0006](../adr/0006-cross-model-reasoning-contract.md)）。
- 本モデルの区分は**倒産予測・危機予測ではない**。デフォルトを内生化していないため、`fp_interest_uncovered` が続いても本モデル内で倒産は発生しない。

### 16.9 診断ラベルとループ作動状態の整合確認

因果グラフ §7.2 は「#169 では両者が整合するかを確認し、整合しない場合はラベル判定を優先して差異を報告する」と定めている。

| ラベル（契約 §4.2 の指標で判定） | 期待されるループ作動状態（因果グラフ §7.2） |
|---|---|
| `contained_adjustment` | `active(R1a)` または `active(R1b)` のみ（かつ `B1`・`B3`・`B6` の作動フラグが立つ） |
| `sectoral_downturn` | 上記 + `active(R2)` または `active(R3)`。`active(R4) = false` |
| `broad_downturn` | 上記 + `active(R4) = true` |
| `indeterminate` | ループ作動状態からラベルを推論しない |

**契約**:

- ラベル判定は**契約 §4.2 の指標・閾値のみ**で行う。ループ作動状態からラベルを決定しない（潜在ノードに依存し検証できないため）。
- 整合しない場合、`label_loop_mismatch` として差異を報告する。**ラベルを変更しない**。
- `breadth` は 0.25 刻みの離散値しか取らない（#165 §2.3）。`breadth ≥ 0.60` は「実体部門 4 のうち 3 部門以上」を意味する。閾値感応度を報告する際にこの離散性を明示する。
- 会計違反（`acc_fail`）がある期を含む結果について診断ラベルを出力する場合、**会計違反の存在を必ず併記する**。違反を理由にラベルを `indeterminate` へ自動変更しない（#166 §8.3）。

---

## 17. 上流ドキュメントへの差し戻し事項

本書の作成過程で検出した、**本書だけでは解決できない上流の欠落・不明確さ**を登録する。因果グラフ §1.2-7・#165 §1.2-1・#166 §1.2-6 に従い、本書では暫定確定を行い、正式な改訂は当該文書で行う。

| ID | 対象 | 内容 | 本書での暫定扱い | 影響する Issue |
|---|---|---|---|---|
| `E1` | #164 §3.2 | 家計所得から `S1` 需要への還流経路が無い（`Y_S5 → COMPUTE_DEM` が存在しない）。`compute_dem` は `ai_exp` のみで駆動されるため、R4（所得・消費ループ）は `S2`・`S3` 経由に限られ、`S1` の産出は家計消費の悪化に反応しない。`breadth` の判定で `S1` が悪化しにくい方向のバイアスが生じる | エッジを追加しない。`E6-01` を `compute_dem = st_cd0 · ai_exp` のままとし、限界（§19-2）として明示する | #164（エッジ追加の可否）・#170（`breadth` のバイアス評価） |
| `E2` | #164 §3.6 | `EMP` ノードが部門添字を持たないため `L44`（`CAPEX_EXEC → EMP`）の帰属部門が一意に決まらない | `S3` に帰属させ、`st_cshare_s3`・`st_capfrac_s3` による正規化で `L43` との二重計上を避ける（§10.1） | #164（ノードの部門展開）・#170（`L43`/`L44` の弾性分離の検証） |
| `E3` | #164 §3.3・#165 §5.2 | (i) `L17`（`PRICE_s → ORDER_s`）の適用範囲が明示されていない。資本財需要にも一般需要にも掛けると価格効果が二重に入る。(ii) `capex_plan_shock_ex` の単位欄が「baseline比 %」であり、モデル内の無次元乗数（baseline `1.0`）との区別が付かない | (i) 一般需要にのみ適用する（§8）。(ii) モデル内は baseline `1.0` の乗数として扱う（§4.2）。#165 `1.1.0` は単位欄を変更していないため、イベント側単位とモデル内単位の区別を本書 §4.2 の契約として保持する | #164（`L17` の適用範囲の明記）・#165（単位欄の明確化） |
| `E4` | #164 §3.4・#163 §5.3 | (i) `L27`（`PROFIT_s → EQUITY_VAL`）の遅れが `0` だが、期内処理順序（ステップ 2 < ステップ 8）により遅れ `1` でしか実装できない。(ii) `xdem_s5`（`S5` 産出のモデル外需要）を生成する行動方程式の根拠が上流に無い | (i) 遅れ `1` を採る（§13.5）。範囲外の選択であり #164 の改訂を要する。(ii) 定数とする（§10.3）。政府・海外部門を持たないため内生化の根拠が無い | #164（`L27` の遅れの改訂）・#163／#170（`xdem_s5` の扱い） |
| `E5` | #166 §7.3 | `liquidity_gap_s` の定義に実現値 `newdebt_s` が含まれるが、`newdebt_s` は現金恒等式の閉じ変数であるため、この定義では `liquidity_gap_s ≤ 0` が恒等的に成立し検出力を失う | `newdebt_max_s`（事前上限）に読み替える（`E7-20`）。定義の意図（「正なら計画の縮小が必要」）に忠実である | #166（定義の改訂） |
| `E6` | #166 §4.2・§4.5 | (i) `cons = cons_s1 + cons_s5` は `S2`・`S3` 産出への家計支出を含まないが、観測（`PCECC96`）は全部門からの消費を含む。契約 §3 Q3 の判定量 `dC_t` にこの近似が入る。(ii) `C-05` の `im_s5` を持つと `y_tot = Σ va_s + y_s5`（R-1）で `S5` の中間投入が二重に控除される | (i) #166 の定義を維持し、観測対応の近似を限界（§19-3）として明示する。(ii) `st_va_share_s5 = 1`（`im_s5 ≡ 0`）とする（§11.1） | #166（`cons` の範囲・`im_s5` の扱い）・#170（観測方程式での対応） |

**契約**:

- `E1`–`E6` はいずれも**本書の暫定扱いで実装可能**である。Julia 実装（#171）の着手を妨げない。
- `E1`・`E2`・`E3`(i)・`E4`(i) は #164 の改訂事項、`E3`(ii)(iii) は #165、`E5`・`E6` は #166 の改訂事項である。
- 改訂が行われた場合、本書の該当箇所を改訂し `equations version` を上げる（§21）。
- **実装者が本書に無い遅れ・関数形・単位換算を独自に決めない**。必要が生じた場合は本書へ差し戻す（§1.2-7）。

---

## 18. 後続 Issue への引き渡し

| Issue | 本書から受け取るもの |
|---|---|
| #170 観測・検証 | §13 のパラメータ辞書（固定/較正/推定区分と感応度対象）・§14.2 の逆較正で必要な定常水準の一覧・§14.3 の定常条件（自動テスト対象）・§15.4 の許容誤差の妥当性確認（§13.1 の `div_eps`・`guard_max`・`jac_h`）・§16.2 のヤコビアン摂動幅の感応度・§16.6 の `μ_j` の数値導出・Q3 に追加 1 実行が必要であること・§17 の `E1` の `breadth` バイアス評価 |
| #171 統合 | §2.2 の API 帰結（`transition_path` 非実装・`NLsolve` 不要）・§3.1 のステップ構造（`simulate` の実装骨格）・§13.1 の `parameters` 平坦化と含めないもの・§13.4 の許容条件（開始前検査）・§15.5 の構造化警告・§15.6 の `metadata` 予約キー 6 件・§16.1 の診断層分離・§16.5 の `credit-off` 実装契約 |

**Julia 実装の受け入れ確認事項**（本書が「追加の理論判断なしに実装できる」ことの検証項目）

| # | 確認 |
|---|---|
| 1 | §3.1 の 10 ステップに沿って `simulate` を実装でき、各ステップの式が §4–§12 に 1 対 1 で対応する |
| 2 | 全 `control` 変数に行動方程式があり、全 `diagnostic` 変数に定義式がある（#165 §5・§5.7 の必須変数と §4–§12 の式の対応表を実装時に検査する） |
| 3 | §3.3 の 12 循環すべてについて遅れが指定されており、遅延バッファの深さが §13.5 で確定している |
| 4 | §13.2・§13.3 の全パラメータに単位・範囲・分類がある |
| 5 | §14.2 の逆較正が閉形式であり、非線形ソルバを必要としない |
| 6 | §14.3 の 17 条件がテストとして書ける |
| 7 | §15.2 の T1 が式の中に、§15.3 の T2 が検証層に、§15.6 の T3 が打ち切り層に分離できる |
| 8 | §16 の診断がモデル本体を変更せずに実装できる |

**LLM 説明層への必須記載事項**（[llm_safety.md](../llm_safety.md)・#166 §11 の必須記載と併せて適用）

1. 打ち切り（§15.6）が生じた結果を説明する場合、**打ち切りの事実と `termination_reason` を必ず明示する**。
2. `runup_deviation`・`a2_violation`・`funding_forced`・`sign_constraint` が記録された結果を説明する場合、その事実を明示する。
3. ループ利得（§16.2）を説明する場合、**状態依存であり単一の値でループを特徴づけられないこと**を明示する。`ρ_t > 1` を「発散する」と述べない。
4. `share_C`（§16.6）・増幅度 `A`（§16.5）は**同一実装内の反実仮想寄与**であり、因果推定ではない。
5. `contained_adjustment` を提示する場合、`delayed_containment`（§16.7）の判定結果を併記する。
6. `threshold_proximity`（§16.4）が記録された場合、**閾値を ±50% 変化させたときのラベルを併記する**。
7. 定常状態（§14.1）を「モデルが安定である根拠」として提示しない。較正で課した構造である。
8. `funding_pressure_s`（§16.8）は倒産・信用イベントの予測ではない。

---

## 19. 限界

1. **関数形は仮説である**。§5–§12 の式は因果グラフの「関数形候補」欄と経済理論の標準形から選んだ設計判断であり、実データによる関数形選択（ノンパラメトリック推定・モデル選択）を経ていない。#170 の検証で棄却されうる。
2. **家計所得が `S1` 需要へ還流しない**（§17 の `E1`）。`compute_dem` は `ai_exp` のみで駆動されるため、R4 は `S2`・`S3` 経由に限られる。`breadth` の判定で `S1` が悪化しにくい方向のバイアスが生じる。
3. **`cons` と観測系列の対応が近似である**（§17 の `E6`）。`cons` は `S1`・`S5` 産出への家計支出のみを含み、`S2`・`S3` 産出への一般需要を含まない。契約 §3 Q3 の判定量 `dC_t` にこの近似が入る。
4. **年率金利の四半期換算が単利である**（§4.3）。`r · Δt` は複利換算 `(1 + r)^{Δt} − 1` と `r = 0.05` で約 0.03%pt/年の差を生む。#166 §5.4 の定義に従った選択であり、会計恒等式は単利定義のもとで閉じるが、実データの利払い額との照合時にこの差が残差として現れる。
5. **`R1a` は基準ユースケースで作動しない**（§9.5）。`L61`（能力上限）が非拘束であるため、`S1` の内部資金ループは需要主導の下方ショックでは利得がゼロである。`S1` の CAPEX 削減が `S1` 自身の収益を通じて自己増幅する経路は能力拘束下に限られる。
6. **`SP` の投資に繰越が無い**（§7.4）。`S1` は延期分を `plan_carry_s1` へ繰り越すが、`s ∈ SP` は資金不足による投資削減が将来へ繰り越されない。`S1` と `SP` の非対称性は #166 §6.2 の恒等式の差（`SP` に閉じ変数としてのキャンセル・延期が無い）に由来する。
7. **受注残の買い手構成を追跡しない**（§11.4）。一般需要の引渡額を `S5` と `SX` へ当期の受注フロー比で按分するため、繰越分の買い手が正確に帰属しない。影響は `s5_net_sx` の残差に現れ #166 §8.3 で監視されるが、`S5` の所得・支出の整合性は近似である。
8. **`xdem_s5` が定数である**（§10.3・§17 の `E4`）。政府支出・純輸出・非AI企業投資が景気に反応しない。`Sc1`–`Sc4` のいずれでも `S5` の外生需要が一定に保たれるため、財政・外需による自動安定化装置が存在しない。
9. **定常状態は較正で課した構造である**（§14.1）。定常性の成立はモデルの安定性の証明ではない。§14.3 の 17 条件はすべて逆較正で満たされるよう構成されており、条件が成立することからモデルの妥当性は導かれない。
10. **`st_payout_s = 1` の制約が現実の配当性向と乖離する**（§14.3 の `SS-14`）。成長率ゼロの定常状態は内部留保ゼロを要求するため、baseline では利払い後利益を全額分配することになる。実際の hyperscaler・半導体企業の配当性向は 1 より小さく、その差は成長によって説明される。成長を持たない初期MVPではこの乖離を表現できない。
11. **ヤコビアンによるループ利得評価は局所線形化である**（§16.2）。閾値近傍では前進差分が不安定になりうる。`ρ_t > 1` は局所的な増幅を示すが、飽和・閾値により大域的には収束しうる。
12. **`share_C` の加法分解に残差が残る**（§16.6）。非線形モデルであるため加法分解は近似であり、主方式（反実仮想寄与）と乖離しうる。乖離の大きさは非線形性の強さの指標であって、どちらかが誤りであることを意味しない。
13. **本書は実データによる検証を経ていない**。関数形・遅れの採用値・パラメータの許容条件の妥当性は #170 の履歴再生で初めて評価される。

LLM による説明生成時は、上記を [llm_safety.md](../llm_safety.md) の必須記載事項と併せて提示する。

---

## 20. 対象外

[Issue #169](https://github.com/Yuki-Watanabe7/DME/issues/169) の対象外に加え、本書で明示する。

| 対象外 | 扱い |
|---|---|
| Julia コードの実装・型定義・API 名 | #171 |
| パラメータの最終推定値・定常水準の数値 | #170 |
| 観測方程式・系列 ID・単位変換の実装 | #170 |
| 数値解法設定の既定値（`SolverOptions` のフィールド） | #171 |
| 診断閾値セットの数値・API | #170（較正）・#171（型） |
| 企業単位の最適化・ABM | 契約 §6・[責務境界](capex_credit_cycle_model_boundaries.md) §4.1 の `4-5` |
| 複雑な資産価格形成 | [責務境界](capex_credit_cycle_model_boundaries.md) §4.1 の `4-6` |
| 政策反応関数 | 因果グラフ `X05`（`EXT`）・[責務境界](capex_credit_cycle_model_boundaries.md) §4.1 の `4-8` |
| 一般物価・インフレ動学 | [責務境界](capex_credit_cycle_model_boundaries.md) §4.1 の `4-9` |
| デフォルト・信用損失の内生化 | #166 §7.1 |
| 家計の金融資産・資産効果 | 因果グラフ `X01`・`X02`（`EXT`） |
| 期内処理順序の変更 | #166 §2.5（変更しない） |
| 時間形状の追加（6 種を超える） | [シナリオ時間軸](../architecture/scenario_time_semantics.md) §5.2-1（改訂が必要） |
| イベントの合成・適用四半期の決定 | #168（確定済み） |
| `SimulationResult` 型の変更 | 行わない（[ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md) 決定 8） |
| モデル合成・連成 | [ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md) 決定 9 |

---

## 21. #171 統合レビューによる改訂（`1.1.0`）

本節は #171 の横断整合レビュー（[統合設計](../architecture/capex_credit_cycle_integration.md) §2）で検出された不一致のうち本書が担当する 7 件の解決を記録する。**本節は本書の正本であり、本文の該当箇所と矛盾する場合は本節が優先する。**

### 21.1 `price_s` の生成位置と資本財受注の価格整合（`X-15`）

**改訂**: `price_s`（`s ∈ SP`）の生成を **期内処理順序ステップ 5 の冒頭**へ前倒しする。§3.1 のステップ 5 の名称を「受注配分」から**「価格確定と受注配分」**へ改め、ステップ 6 の「決まる主な量」から `price_s` を除く。

**根拠**: `price_s` は `E9-15`（`price_tgt_s` を `util_s[t−1]` から決める）・`E9-16`（`price_s[t−1]` からの部分調整）により**`util_s[t−1]` と `price_s[t−1]` のみに依存する先決変数**である。したがって生成位置の前倒しが可能であり、**参照する時点は変わらない**。これは本書 §3.1 の注意が `int_burden_s`・`repay_s` をステップ 2 へ前倒しした際と同一の論法であり、順序の変更には当たらない。

**必要性**: 改訂前は `E8-01` が `order_cap_s = st_capex_share_s · capex_exec_s1 / max(price_s[t−1], st_price_min_s)`（期首価格で除算）、`E11-17` が `d_{S1,s} = price_s · order_cap_s`（当期価格で乗算）であり、合成すると

```
d_{S1,S2} + d_{S1,S3} + capex_sx_s1
  = capex_exec_s1 · [ share_s2 · price_s2/price_s2[t−1] + share_s3 · price_s3/price_s3[t−1] + share_sx ]
```

となる。`price_s = price_s[t−1]` のときのみ #166 §8.1-12 `:no_double_count` の `R-3` が成立し、価格が動く局面（つまりショックを与える局面すべて）で恒等式が破れる。

**改訂後の式**:

```
E8-01'  order_cap_s = st_capex_share_s · capex_exec_s1 / max(price_s, st_price_min_s)      （s ∈ SP、当期 price_s）
E11-17' d_{S1,s}    = price_s · order_cap_s                                                （s ∈ SP）
```

これにより `Σ_{s∈SP} d_{S1,s} + capex_sx_s1 = capex_exec_s1` が**構成上厳密に成立する**（`E7-22` の `capex_sx_s1 = st_capex_share_sx · capex_exec_s1` と許容条件 1 の `Σ share = 1` による）。

### 21.2 `order_inv_s3` の参照時点（`X-16`）

**改訂**: `E8-02` の `invest_s2[t−1]` を**当期 `invest_s2`** へ改め、価格も当期 `price_s3` を用いる。

```
E8-02'  order_inv_s3 = st_invest_share_s3 · invest_s2 / max(price_s3, st_price_min_s3)
E11-18' d_{S2,S3}    = price_s3 · order_inv_s3
```

**根拠**: `invest_s2` はステップ 4（資金制約と実行）で確定し、`order_inv_s3` はステップ 5 で生成されるため、当期値を参照しても循環しない。`L19` の遅れ `1` は §13.5 の表で規則欄が「—」であり、循環を断つための下限選択ではない（範囲内の選択である）。改訂前は `E7-23` の `inv_sx_s2 = st_invest_share_sx · invest_s2`（当期）と時点が食い違い、`invest_s2` が期間変化するだけで `:no_double_count` の `R-4` が破れた。

**§13.5 の遅延パラメータ表の該当行を改める**: `L19` の採用値を `1` から **`0`** へ。実装は `E8-02'`。遅延バッファから `invest_s2` の深さ 1 を除く（深さ 1 のバッファは 34 本から 33 本へ、状態次元は 65 から 64 へ）。

### 21.3 在庫の当期価格評価（`X-14`）

[ADR 0013](../adr/0013-capex-credit-cycle-integration-contract.md) 決定 4・#166 §14.5 に従い、本書の該当式を次のとおり改める。

| 式 | 改訂前 | 改訂後 |
|---|---|---|
| `E12-05` | `invval_s = st_invprice_s · inv_s` | **`invval_s = price_s · inv_s`** |
| `E9-13` | `dinv_s = price_s · (y_s − ship_s)` | 変更なし（当期価格建てで正しい） |
| `E11-08` | `ocf_s = profit_s + dep_s − dinv_s` | 変更なし |
| 新設 | — | **`E12-05b  valchg_s = (price_s − price_s[t−1]) · inv_s[t−1]`**（`s ∈ SP`。`valchg_s1 ≡ 0`） |

`Δinvval_s = dinv_s + valchg_s` が恒等的に成立する。§13.2 のパラメータ表から **`:st_invprice_s2`・`:st_invprice_s3` を削除する**（構造パラメータは 35 系統から 34 系統へ）。§7 の恒等的ゼロ項の一覧から `valchg_s` を除く（`E7-08` を削除し、`valchg_s` は `E12-05b` で生成される `diagnostic` とする）。定常状態では `price_s` が一定であるため `valchg_s = 0` となり、§14.3 の `SS-1`–`SS-17` は変更を要しない。

**`price_s` は `E12-05` の評価時点で当期値が確定している**（21.1 によりステップ 5 で確定するため、ステップ 9 の残高更新で参照できる）。

### 21.4 `s5_net_sx` の集約範囲（`X-17`）

**改訂**: `E11-22` の賃金項の集約を `s ∈ SR`（`= {S1, S2, S3, S5}`）から **`s ∈ SF`（`= {S1, S2, S3}`）**へ改める。

```
E11-22'  s5_net_sx = Σ_{s∈SF} wagebill_s − tax_hh − cons_s1 − cons_s5
                     − d_{S5,S2} − d_{S5,S3} + y_s5 − xdem_s5
```

**根拠**: `S5` 内部の賃金支払（`wagebill_s5`）は `S5` 列の中で源泉と使途が相殺されるため取引フロー行列に計上しない（#166 §4.2 `C-06` の行説明）。改訂前は源泉側のみ `wagebill_s5` を計上しており、#166 §4.5 の定義と `wagebill_s5` だけ乖離し、§8.3 の残差監視閾値（`|s5_net_sx| / y_tot > 0.05`）の判定が系統的にバイアスした。`im_s5` は `st_va_share_s5 = 1` により恒等的にゼロであり（§11.1）、改訂後の式に現れない。

**`E10-12`（`hh_income`）との整合**: `hh_income = Σ_{s∈SF} wagebill_s − tax_hh` であり、集約範囲が一致する（#165 §11.4 `X-28`）。

### 21.5 記号の改名の記録（`X-31`）

`E12-14` の `dep_stock_s4` は、#166 `1.0.0` §5.5 本文が `dep_s4` と表記していたものの改名である。本書 `1.0.0` はこの改名を明示的に記録していなかった。**改名の根拠**: `dep_s` は固定資本減耗（`:dep_s1`–`:dep_s3`、`E11-05`）であり `dep_s4` と記号衝突する。#166 §14.6 で表記が統一された。実装時のキー衝突検査（#165 §6.5 契約 1）で再発を防ぐ。

### 21.6 パラメータ区分欄と個数の修正（`X-20`・`X-21`）

| ID | 改訂 |
|---|---|
| `X-20` | §13.2・§13.3 の「固定/較正/推定」欄のうち、**§14.2 の逆較正で閉形式導出される（自由度のない）11 系統を「定常水準から導出」へ改める**。対象: `:st_cor_s1`–`_s3`（ステップ 2）・`:st_lprod_s1`–`_s5`（ステップ 1）・`:st_va_share_s1`–`_s3`（ステップ 10）・`:st_wbase_s1`–`_s5`（ステップ 10）・`:st_cons_share_s1`（ステップ 12）・`:st_spread0`（ステップ 11）・`:st_pol_ref`（ステップ 11）・`:st_coll_ltv`（ステップ 13）・`:bh_util_tgt_s1`–`_s3`（ステップ 1・6）・`:bh_backlog_target_s2`/`_s3`（ステップ 8）・`:bh_inv_target_s2`/`_s3`（ステップ 8）。#170 §7.2 が `CAL-SS` を割り当てているのと整合する。**「較正」欄に残るのは §14.2 で逆算されないもののみである** |
| `X-21` | §13.3 末尾の区分別個数を**行（系統）数基準**へ統一し、実測値へ改める。#170 が「全 35 系統」「全 44 系統」と行数基準で参照しているため基準を揃える。改訂後の値（在庫評価の変更で `st_invprice_s` を削除した後）:<br><br>**行（系統）数基準（合計 81 行 = `st_` 34 + `bh_` 44 + `pl_` 3）**<br>・定常水準から導出（自由度なし）: 20 行（従来「定常水準から導出」9 行 + `X-20` で移した 11 行）<br>・固定（会計・制度・数値下限）: 12 行<br>・較正（観測比率・文献値から直接）: 23 行<br>・推定（`bh_` の一部）: 26 行<br><br>**部門展開後の個別数（合計 147 個 = `st_` 70 + `bh_` 74 + `pl_` 3）**<br>区分別の個別数は系統ごとの部門展開数に依存するため本書では固定せず、実装時に `CAPEX_CC_PARAMETER_NAMES` から導出してテストで検証する（[統合設計](../architecture/capex_credit_cycle_integration.md) §7.1-7）。<br><br>改訂前の記載（導出 12 / 固定 18 / 較正 30 / 推定 28、合計 88）は、行数基準・個別数基準のいずれとも一致していなかった |

### 21.7 上流改訂への差し戻しの解決状態

§17 の差し戻し `E1`–`E6` の状態を次のとおり更新する。

| ID | 状態 |
|---|---|
| `E1`（`Y_S5 → COMPUTE_DEM` の欠落） | **未解決**。#164 の改訂事項。#170 §7.6 が `S1` 除外版 `breadth` の併記を確定済み。実装は本書の暫定扱い（`compute_dem = st_cd0 · ai_exp`）に従う |
| `E2`（`EMP` の部門帰属） | **部分解決**。`L44` の帰属は #165 §11.1 `X-06` で `S3` に確定した。ノードの部門展開は #164 の改訂事項として残る |
| `E3`(i)（`L17` の適用範囲） | **未解決**。#164 の改訂事項。実装は本書 §8 の暫定扱い（一般需要にのみ適用）に従う |
| `E3`(ii)（`capex_plan_shock_ex` の単位欄） | **解決**。#165 の単位欄は変更しないが、モデル内は baseline `1.0` の無次元乗数であることを本書 §4.2 の契約として保持し、[統合モデル仕様 index](capex_credit_cycle_design.md) §4.3 が両者の区別を明記した |
| `E4`(i)（`L27` の遅れ） | **未解決**。#164 の改訂事項。実装は遅れ `1` とし `metadata["deviations"]` に記録する |
| `E4`(ii)（`xdem_s5` の根拠） | **解決**。#170 §3.2 が `A`（観測不能・シナリオ仮定）として分類し、本書 §10.3 の定数扱いを是認した |
| `E5`（`liquidity_gap_s` の定義） | **解決**。#166 §14.6 が `newdebt_max_s` ベースへ改訂した |
| `E6`(i)（`cons` の部門範囲） | **解決**（限界として保持）。#170 §3.2 が観測対応の近似を明示した |
| `E6`(ii)（`im_s5`） | **解決**。#166 §14.6 が `s5_net_sx` から `im_s5` を除いた |

**LLM 向け要約の修正**: 冒頭の「上流への差し戻し事項 `E1`–`E5` を §17 に登録する」は誤りであり、§17 は `E1`–`E6` の 6 件を登録している。メタ情報直下の要約を修正した。

---

## 22. 改訂履歴

| version | 日付 | 変更 |
|---|---|---|
| `capex-credit-cycle-equations/1.1.0` | 2026-07-30 | #171 の統合レビューによる改訂（§21）。上位契約を `vars/1.2.0`・`accounting/1.1.0`・`macro-event-contract/1.0.1` へ更新。`price_s` の生成をステップ 5 冒頭へ前倒しし `E8-01`・`E11-17` を当期価格へ統一（`:no_double_count` の `R-3` を厳密化）。`E8-02` を当期 `invest_s2` 参照へ改め `L19` の採用遅れを `0` へ、状態次元を 65 → 64 へ。在庫を当期価格評価へ変更し `E12-05` を改訂・`E12-05b`（`valchg_s`）を新設・`st_invprice_s` を削除（構造 35 → 34 系統）・`E7-08` を削除。`E11-22` の賃金項集約を `SR` → `SF` へ。`dep_stock_s4` への改名の根拠を記録。§13.2・§13.3 の区分欄 11 系統を「定常水準から導出」へ修正し区分別個数を行数基準の実測値へ修正。LLM 向け要約の `E1`–`E5` を `E1`–`E6` へ修正。差し戻し `E1`–`E6` の解決状態を更新 |
| `capex-credit-cycle-equations/1.0.0` | 2026-07-30 | 初版（#169）。離散時間ハイブリッド方式と陽解法の選定・主体最適化/均衡求解の非採用・期内処理順序の変数レベル割当・全 12 循環の遅れ指定・外生変数の baseline 値と単位換算（年率→四半期は単利）・金融条件 17 式・期待/計画 16 式・資金制約と実行 23 式・受注配分 4 式・生産/出荷/価格 19 式・雇用/所得/消費 17 式・収益/分配 22 式・残高更新 15 式・パラメータ辞書（構造 35 系統・行動 44 系統・政策 3 系統）と許容条件 15 件・遅延パラメータ採用値の一覧と状態次元 65・baseline を成長率ゼロの定常状態とする決定・逆較正による初期状態の与え方・定常条件 17 件（`st_payout_s = 1` の導出を含む）・数値ガードの 3 層分離（T1 経済制約 23 箇所・T2 符号制約と構造的保証・T3 打ち切り）・ゼロ除算 13 箇所の扱いと `NaN` 伝播を止める 4 箇所の限定・警告 10 種・`metadata` 予約キー 6 件・ループ利得のヤコビアン/反実仮想併用方式・R2 短絡ループの閉形式利得・非線形性 7 箇所と `threshold_proximity`・`credit-off` の固定パラメータ集合・`share_C` の反実仮想寄与分解・遅延型遮断の識別・差し戻し事項 `E1`–`E6` を固定 |

