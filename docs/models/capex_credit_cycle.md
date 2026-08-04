# 部門別CAPEX・信用循環モデル — モデル解説ドキュメント

> 関連: [統合モデル仕様 index](capex_credit_cycle_design.md)（全設計文書の正典表）・
> [部門境界と変数定義](capex_credit_cycle_sectors_variables.md)・
> [動学方程式と数値計算契約](capex_credit_cycle_equations.md)・
> [ストック・フロー会計表](capex_credit_cycle_stock_flow.md)・
> [責務境界とモデル間比較契約](capex_credit_cycle_model_boundaries.md)・
> [観測方程式・識別戦略・検証方針](capex_credit_cycle_empirical_strategy.md)・
> [統合設計](../architecture/capex_credit_cycle_integration.md)・
> [ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md)〜
> [ADR 0013](../adr/0013-capex-credit-cycle-integration-contract.md)・
> [統合デモ](../examples/capex_credit_cycle_demo.md)

---

## メタ情報

| 項目 | 内容 |
|---|---|
| **モデル名** | 部門別CAPEX・信用循環モデル（Sectoral CAPEX-Credit Cycle Model） |
| **Julia 型名** | `CapexCreditCycleModel` |
| **カテゴリ** | 離散時間ハイブリッド・部門別実物-金融連関モデル |
| **求解手法** | 陽解法（期内処理順序10ステップの前向き1回計算。反復・非線形ソルバなし） |
| **実装ファイル** | `src/models/capex_credit_cycle.jl`（構築・逆較正・実行・`SimulationResult`変換）・`src/analysis/capex_credit_cycle_scenarios.jl`（シナリオ）・`src/analysis/capex_credit_cycle_accounting.jl`（会計検証）・`src/analysis/capex_credit_cycle_diagnostics.jl`（診断層）・`src/analysis/capex_credit_cycle_visualization.jl`（可視化） |
| **テストファイル** | `test/test_capex_credit_cycle.jl` / `test_capex_credit_cycle_accounting.jl` / `test_capex_credit_cycle_diagnostics.jl` / `test_capex_credit_cycle_visualization.jl` / `test_capex_credit_cycle_demo.jl` |
| **正本** | 設計上の判断はすべて [統合デモ仕様](../architecture/capex_credit_cycle_integration.md) §8 と個別設計文書（メタ情報の関連リンク）が正本。本ドキュメントはそれらの要約であり、内容が食い違う場合は個別設計文書を正とする。 |

---

## 1. モデルの目的

**LLM向け要約**: AI・半導体関連のCAPEX（設備投資）調整が、信用条件の悪化を通じて増幅され、雇用・所得・消費経由で一般経済へ波及するか、あるいはCAPEX関連産業内の在庫・稼働率調整で収束するかを、部門別に追跡するモデルである。

- **主な問い**: [分析契約](capex_credit_cycle_analysis_contract.md) §3 の判定問題 Q1–Q5。
  「CAPEX調整が関連産業内の調整で収束する条件（Q1）」「信用スプレッド・借換条件・貸出態度の悪化が投資削減を増幅する条件（Q2）」「雇用・所得・消費を通じ一般経済へ波及する条件（Q3）」「金融緩和・需要回復により波及が遮断される条件（Q4）」「経路が分岐する非線形性・閾値（Q5）」。
- **対象経済**: 米国基準・四半期頻度。5部門（`S1` AI/ハイパースケーラー、`S2` 半導体・データセンター機器、`S3` 一般資本財・建設、`S4` 金融仲介、`S5` 家計）+ 残差部門 `SX`（[部門境界と変数定義](capex_credit_cycle_sectors_variables.md) §2）。
- **時間軸**: 離散時間・四半期。助走区間8期（`t=-8…-1`）+ 評価区間20期（`t=0…19`）、既定 `CapexCreditCycleOptions()`。

---

## 2. 経済学的直観

### なぜこのモデルが重要か

AI・半導体CAPEXブームの調整局面では、「設備投資の縮小が信用市場（スプレッド拡大・借換条件悪化・貸出態度引き締め）を通じて増幅されるか」が実体経済への波及規模を左右する。既存モデル（Keen・SIM・New Keynesian・VAR）はいずれもこの部門別CAPEX-信用連関を直接扱わない（[責務境界とモデル間比較契約](capex_credit_cycle_model_boundaries.md)）。本モデルはKeenの拡張ではなく独立モデルとして、判定問題Q1–Q5に必要な範囲に責務を限定して実装する（[ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md)）。

### 直観的なメカニズム

- `S1`（AI/ハイパースケーラー）の期待（`ai_exp`）が下方修正されると、目標資本ストック・CAPEX計画が縮小し、`S2`/`S3`向けの資本財発注が減る（増幅ループ`R1a`/`R1b`）。
- 収益・キャッシュフローの悪化がカバレッジ比率を押し下げ、社債スプレッド拡大・借換条件悪化・貸出態度引き締めを通じて資本コストを上昇させ、CAPEXをさらに抑制する（信用循環ループ`R2`・`R2`短絡・`R3`）。
- CAPEX削減は`S2`/`S3`の雇用・所得を通じて家計消費（`cons`）を下押しし、一般経済（`y_tot`）へ波及する（`R4`）。
- 資金不足は**残差項で埋めず**、CAPEX延期（`capex_defer_s1`）として実物側に現れる（資金調達順序の固定と閉じ変数の指定、[動学方程式](capex_credit_cycle_equations.md)）。
- 金融緩和（政策金利引き下げ）はスプレッド・カバレッジ経由で波及を遮断しうる（Q4）が、適用時点が遅れると遮断効果は減衰する。

---

## 3. 主要変数

変数の全量（150超）は[部門境界と変数定義](capex_credit_cycle_sectors_variables.md) §5（変数辞書）・[統合モデル仕様 index](capex_credit_cycle_design.md)（記号横断辞書）が正本。ここでは判定問題に直結する主要系列のみを示す。`SimulationResult.metadata` の `variable_roles`/`variable_sectors`/`variable_units`/`variable_timing`/`variable_observability` に全変数の分類が機械可読で入っている。

### 状態変数（22 + 遅延バッファ、`state_variables(m)` は70）

| 変数 | Julia シンボル | 意味 | 単位・時点 |
|---|---|---|---|
| `S1` 資本ストック | `:cap_s1` | AI/ハイパースケーラーの実効資本 | 10億ドル・EOP |
| `S1` CAPEX建設中パイプライン | `:capex_pipe_s1` | 未完了の設備投資 | 10億ドル・EOP |
| `S2`/`S3` 受注残 | `:backlog_s2`/`:backlog_s3` | 未出荷の受注 | 10億ドル・EOP |
| `S1`–`S3` 債務 | `:debt_s1`–`:debt_s3` | 部門別債務残高 | 10億ドル・EOP |
| `S1`–`S3` 実効金利 | `:r_eff_s1`–`:r_eff_s3` | 債務の加重平均金利 | 年率・小数・AVG |

### 操作変数（コントロール、33）

| 変数 | Julia シンボル | 意味 |
|---|---|---|
| CAPEX実行額 | `:capex_exec_s1` | `S1`の当期設備投資実行 |
| CAPEX延期額（閉じ変数） | `:capex_defer_s1` | 資金不足時の実物側閉じ変数（[動学方程式](capex_credit_cycle_equations.md)） |
| 受注 | `:order_s2`/`:order_s3` | `S2`/`S3`の当期受注 |
| 投資実行 | `:invest_s2`/`:invest_s3` | `S2`/`S3`の設備投資実行 |
| 社債スプレッド | `:spread` | `S4`が決める信用条件（bp） |
| 消費 | `:cons` | 家計消費 |
| 総産出 | `:y_tot` | 全部門合計産出 |

### 外生変数（7、`exogenous_variables(m)`）

| 変数 | Julia シンボル | 単位 | シナリオでの用途 |
|---|---|---|---|
| AI計算需要・収益期待 | `:ai_exp` | — | `Sc1`〜: 需要期待下方修正（`SH-EXP`） |
| CAPEX計画への上乗せショック | `:capex_plan_shock_ex` | baseline比% | `Sc2`〜: hyperscaler CAPEX縮小（`SH-CAPEX`） |
| スプレッドへの上乗せショック | `:spread_shock_ex` | bp | `Sc3`〜: 信用ショック（`SH-CREDIT`） |
| 政策金利 | `:policy_rate` | 年率% | `Sc4`: 金融緩和（`SH-EASING`） |
| `S2`/`S3`一般需要 | `:ext_demand_s2`/`:ext_demand_s3` | 10億ドル/四半期 | 外生一定（baseline） |
| `S1`向け財の相対価格 | `:price_s1` | — | 外生一定（baseline） |

### 潜在変数（単独の水準を提示しない、`variable_observability ∈ {"E","A"}`）

`cost_capital_s1`–`_s3`・`ai_exp`・`target_cap_s1`・`cancel_s1`。`plot_capex_series`/`plot_capex_sector_series` はこれらのみを要求すると `ArgumentError` を送出する（潜在変数の単独提示を抑止、[統合設計](../architecture/capex_credit_cycle_integration.md) §6.2）。

---

## 4. パラメータ

### Julia コンストラクタ（通常は逆較正経由）

```julia
targets = capex_credit_cycle_default_targets()   # 例示定常水準（実データの較正値ではない）
m = capex_credit_cycle_model(targets)             # 13ステップの逆較正でパラメータを閉形式に算出
```

`behavioral`・`policy` キーワードで既定値（逆較正で決まった値を含む）を上書きできる。直接 `CapexCreditCycleModel(; params, targets, sectors)` で構築することもあるが、通常は `capex_credit_cycle_model` を使う。

### パラメータ区分

構造（`st_`）34系統・行動（`bh_`）44系統・政策（`pl_`）3系統、部門展開後147個（`CAPEX_CC_PARAMETER_NAMES`）。区分・固定/較正/推定の対応は[動学方程式](capex_credit_cycle_equations.md)のパラメータ辞書、観測対応は[観測方程式・識別戦略・検証方針](capex_credit_cycle_empirical_strategy.md)が正本。`parameters(m)` は数値解法設定・診断閾値・初期状態・ショック規模を**含まない**（平坦な `NamedTuple` のみ）。

### 許容条件

`CapexCreditCycleModel` の内部コンストラクタが許容条件15件を検査し、違反時は `ArgumentError`（例: レバレッジ上限・カバレッジ閾値の整合、`st_capex_share_s2+st_capex_share_s3+st_capex_share_sx=1` 等）。`capex_credit_cycle_default_targets()` を用いる限り全件を満たす。

---

## 5. 主要方程式

期内処理順序10ステップ（各期1回、反復なし）で計算する（[動学方程式](capex_credit_cycle_equations.md) §3.1・§5–§12 が正本）:

| ステップ | 内容 | 主な出力 |
|---|---|---|
| 1 | 金融条件（金利・スプレッド・カバレッジ・貸出態度） | `spread`・`r_eff_s`・`coverage_agg` |
| 2 | 期待・計画（目標資本・CAPEX計画） | `target_cap_s1`・`capex_plan_s1` |
| 3 | 資金制約と実行（資金調達順序の固定・閉じ変数） | `capex_exec_s1`・`capex_defer_s1`・`funding_forced_s` |
| 4 | 受注配分 | `order_s2`・`order_s3` |
| 5 | 生産/出荷/在庫/価格（`price_s` を先決） | `y_s2`・`y_s3`・`inv_s2`・`inv_s3` |
| 6 | 雇用/所得/消費 | `emp_s1`–`_s3`・`hh_income`・`cons` |
| 7 | 収益/分配 | `profit_s`（会計残差）・`div_s`・`tax_s` |
| 8 | 残高更新（資産・負債の期末残高） | `debt_s`・`cash_s`・`nw_s` |

`profit_s` は会計残差（`va_s − wagebill_s − dep_s`）であり外生マージンを与えない。全12循環の遅れは[動学方程式](capex_credit_cycle_equations.md)が列挙し、実装者が個別に選ばない（[ADR 0011](../adr/0011-capex-credit-cycle-dynamics-contract.md)）。主体最適化・均衡求解は行わない。

---

## 6. 定常状態

`capex_credit_cycle_model` は目標定常水準（`CapexCreditCycleTargets`）から**逆較正**でパラメータを閉形式に算出し、baselineが成長率ゼロの定常状態になるよう構成する（数値ソルバは使わない）。

```julia
using DME

m = capex_credit_cycle_model(capex_credit_cycle_default_targets())
ss = steady_state(m)              # NamedTuple（state+control+exogenous+diagnosticの全キー）
ss.y_tot                          # 定常産出

report = capex_steady_state_report(m)   # SS-1–SS-17 の検証
passed(report)                          # true（既定ターゲットは全件 passed）
```

`capex_run`/`simulate` は呼び出し時に `capex_steady_state_report(m)` を検査し、条件を満たさない場合（カスタム `behavioral`/`policy` が定常性を破る場合）は `ArgumentError` を送出する（入力検査、[ADR 0013](../adr/0013-capex-credit-cycle-integration-contract.md) 決定14）。

---

## 7. シナリオ・ショック

初期MVPの比較シナリオ`Sc0`–`Sc4`は入れ子構造（`Sc1 ⊂ Sc2 ⊂ Sc3 ⊂ Sc4`）を持つ（[分析契約](capex_credit_cycle_analysis_contract.md) §5、暫定既定値）。

| シナリオ | 名称 | 追加されるショック |
|---|---|---|
| `Sc0` | baseline | なし |
| `Sc1` | expectation_only | `SH-EXP`: `ai_exp` −10%（`ar1_decay`、半減期6期） |
| `Sc2` | expectation_capex | + `SH-CAPEX`: `capex_plan_shock_ex` −15%（`step_then_ramp`、hold4/ramp_down4） |
| `Sc3` | capex_credit | + `SH-CREDIT`: `spread_shock_ex` +150bp（`ar1_decay`、半減期4期、`t=1`〜） |
| `Sc4` | capex_credit_easing | + `SH-EASING`: `policy_rate` −100bp（`step`、8期、`t=2`〜） |

```julia
sc = capex_scenario(:Sc3)
exog = capex_exogenous_paths(m, sc)          # baseline外生パスへショックを合成
run = capex_run(m; scenario = :Sc3, exog = exog)
```

`capex_run` は `exog` を優先し、`exog` を渡さない場合は `scenario` に対応するショックなしの baseline を実行する。ショック規模はすべて暫定既定値であり、実データ較正値ではない（[分析契約](capex_credit_cycle_analysis_contract.md) §5.3）。

---

## 8. 出力結果の読み方

### 返り値の構造

```julia
run = capex_run(m; scenario = :Sc3, exog = exog)   # CapexCreditCycleRun
run.series           # NamedTuple（simulate(m; ...) と同一）
run.periods           # -8:19
run.warnings          # 構造化警告（10種のcode）
run.termination_reason  # :completed / :divergence_guard / :non_finite_state / :sign_constraint_fatal

sr = to_simulation_result(m, run, "Sc3")   # SimulationResult
sr["y_tot"]           # 変数系列の取得
nperiods(sr)           # 期間数（28）
```

`run.accounting`・`run.diagnostics` は常に `nothing`（会計・診断は読み取り専用の後処理層であり、別途明示的に呼び出す）。

```julia
acc = validate_capex_accounting(m, run)     # AccountingCheckReport（会計恒等式12項目）
accounting_passed(acc)                       # Bool

diag = capex_diagnostics(m, run)            # CapexDiagnostics（診断層、下記9節）
```

### `metadata` 予約キー（20個 + 補助3個）

`to_simulation_result` が設定する。`variable_roles`/`variable_sectors`/`variable_units`/`variable_timing`/`variable_observability`（変数分類の5辞書）・`contract_version`等の8バージョン文字列・`scenario`（ショック仕様）・`diagnostic_threshold_set`・`termination_reason`/`termination_period`/`divergence_time`/`warnings`・`parameters`。補助キー`unit_conversions`/`deviations`/`measure`。予約キーは本モデルの結果にのみ現れ、他モデルへ同じキーを要求しない（[統合設計](../architecture/capex_credit_cycle_integration.md) §6.1）。

### baseline比乖離の規約

水準変数（`capex_exec_s1`・`cons`・`y_tot`等）は**相対乖離**`(x_t − x^{ss})/x^{ss}`、比率・金利・スプレッド（`util_s`・`inv_ratio_s`・`spread`）は**絶対差**`x_t − x^{ss}`（[分析契約](capex_credit_cycle_analysis_contract.md) §2.4）。モデル自身は`d_`接頭辞の変数を出力しない（比較層・デモの責務）。

---

## 9. 診断層（読み取り専用の後処理）

`capex_diagnostics(m, run)` はモデル本体の動学に影響しない読み取り専用の診断を返す（[ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md)）。

| 診断 | フィールド | 内容 |
|---|---|---|
| 診断ラベル | `diag.label` | `:contained_adjustment`/`:sectoral_downturn`/`:broad_downturn`/`:indeterminate`（`recession`という語は使わない） |
| 広がり | `diag.breadth`/`diag.breadth_excl_s1` | 実体部門4のため0.25刻み。`breadth≥0.60`は「4部門中3部門以上」 |
| 資金繰り診断 | `diag.funding_pressure` | 部門別`fp_invalid`〜`fp_covered`の5値（precedence順）。Keenの`hedge`/`speculative`/`ponzi`とは別体系で同一図に重ねない |
| ループ作動 | `diag.loop_active`/`diag.loop_gain` | `R1a`/`R1b`/`R2`/`R3`/`R4`の作動フラグと反実仮想利得 |
| 非線形性近傍 | `diag.threshold_proximity` | `NL-1`–`NL-7`の閾値近傍検出 |
| Q2: 増幅度 | `diag.amplification` | `A = |peak(dI^{full})| / |peak(dI^{credit-off})|`。反実仮想寄与であり因果推定ではない |
| Q3: 消費経路寄与 | `diag.share_c`/`diag.share_c_additive` | 主方式（反実仮想寄与）と加法分解（残差あり）の2方式を併記 |
| 会計状況の併記 | `diag.accounting_status` | `acc_fail`を含む結果でもラベルを自動的に`indeterminate`へ変更せず、違反を併記する |

`diag.amplification`/`diag.share_c`/`diag.share_c_additive` は分母がゼロに近い場合 `nothing` を返す（値を捏造しない）。閾値は `CapexDiagnosticThresholds` に外部化され、方程式へハードコードしない。`capex_label_sensitivity(m, run)` で閾値±50%のラベル併記が得られる。

---

## 10. AIエコノミスト向け利用ガイド

### このモデルで答えられること

- AI・半導体CAPEX調整が信用条件悪化で増幅されるか（Q2）・一般経済へ波及するか（Q3）・金融緩和で遮断されるか（Q4）の**部門別・機構別**な定性分析。
- 会計恒等式12項目が全期で成立する、部分閉鎖（残差部門`SX`つき）での実物-金融フローの整合的な記述。
- シナリオ`Sc0`–`Sc4`間の比較（同一モデル内、`compare_results_v2`の`mechanism`モードで能力metadataの構造化差分を確認可能）。

### このモデルでは答えられないこと（限界・非対象）

- **経済全体で閉じた会計ではない**（`accounting_closure = :partial`）。SFC検証済みと同じ意味ではない。
- **デフォルト・信用イベントの予測ではない**（`funding_pressure_s`はデフォルトを内生化しない診断ラベル）。
- **危機確率・景気後退の予測ではない**（`broad_downturn`はモデル内の中立的な診断ラベル）。
- **他モデルとの数値比較不能**（`equivalent`概念が存在しないため`mechanism`モードに限る。[責務境界](capex_credit_cycle_model_boundaries.md)）。
- **実データによる較正・検証を行っていない**（初期MVPは例示パラメータ、[観測方程式・識別戦略・検証方針](capex_credit_cycle_empirical_strategy.md)がPhase 3の対象）。

### LLM が参照する際の注意点

- `A`・`share_C`は「同一実装内の反実仮想寄与」であり因果推定ではない。値を投資判断・政策提言の根拠として提示しない（[llm_safety.md](../llm_safety.md) §5.2）。
- `cost_capital_s`・`ai_exp`・`target_cap_s1`・`cancel_s1`は潜在変数であり、単独の水準を提示しない。
- `Digital Twin`/`Digital Shadow`/`デジタルツイン`という語を本モデルまたはDME全体を指して用いない（[ADR 0014](../adr/0014-digital-twin-naming-conditions.md)）。

---

## 11. モデルの限界

### 理論的限界

| 限界 | 説明 |
|---|---|
| 主体最適化を持たない | 期待・計画・資金制約はすべて行動方程式（ルール）であり、効用最大化・利潤最大化から導出しない（[ADR 0011](../adr/0011-capex-credit-cycle-dynamics-contract.md)） |
| デフォルト非内生化 | 部門の債務不履行・破綻を状態遷移として扱わない。`funding_pressure_s`は診断ラベルに留まる |
| 部分閉鎖会計 | 残差部門`SX`を置いて会計を閉じており、経済全体のSFC整合性を主張しない |
| 受注残の買い手構成を追跡しない | 一般需要向け引渡額を当期フロー比で按分する近似（[ストック・フロー会計表](capex_credit_cycle_stock_flow.md)） |

### 数値的限界

| 限界 | 説明 | 回避策 |
|---|---|---|
| 打ち切り3値 | `divergence_guard`/`non_finite_state`/`sign_constraint_fatal`で計算が打ち切られうる | `run.termination_reason`を確認し、打ち切り後の期をNaNとして扱う（0埋めしない） |
| 閾値の較正未了 | `CapexDiagnosticThresholds`は暫定既定値であり実データ較正を経ていない | `capex_label_sensitivity`で±50%感応度を併記する |
| 年率金利の四半期換算が単利 | `r·Δt`は複利`(1+r)^{Δt}−1`と異なる（年率5%で約0.03%pt/年の差） | 会計恒等式は単利定義下で閉じる。実データ照合時は残差として現れる |

---

## 12. 参考文献・関連ドキュメント

### 設計文書（正本）

[統合モデル仕様 index](capex_credit_cycle_design.md)（全設計文書の正典表）・[分析契約](capex_credit_cycle_analysis_contract.md)・[因果グラフ](capex_credit_cycle_causal_graph.md)・[部門境界と変数定義](capex_credit_cycle_sectors_variables.md)・[ストック・フロー会計表](capex_credit_cycle_stock_flow.md)・[責務境界とモデル間比較契約](capex_credit_cycle_model_boundaries.md)・[動学方程式と数値計算契約](capex_credit_cycle_equations.md)・[観測方程式・識別戦略・検証方針](capex_credit_cycle_empirical_strategy.md)・[統合設計](../architecture/capex_credit_cycle_integration.md)。

### ADR（決定記録）

[ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md)（責務境界）・[ADR 0011](../adr/0011-capex-credit-cycle-dynamics-contract.md)（動学契約）・[ADR 0012](../adr/0012-capex-credit-cycle-empirical-contract.md)（実証化契約）・[ADR 0013](../adr/0013-capex-credit-cycle-integration-contract.md)（統合実装契約）・[ADR 0014](../adr/0014-digital-twin-naming-conditions.md)（Digital Twin名称使用条件）。

### 関連モデル・実行例

- [統合デモ](../examples/capex_credit_cycle_demo.md): `Sc0`–`Sc4`比較・会計検証・診断・判定問題Q2–Q4の回答までを再現可能に完走するデモ。
- [Keenモデル](keen.md) / [最小SIM型SFCモデル](sim_sfc.md): 会計・金融不安定性の扱いが異なる関連モデル（責務境界表は[責務境界とモデル間比較契約](capex_credit_cycle_model_boundaries.md)を参照）。
- [モデル能力・概念定義 metadata](../model_capabilities.md): `model_capabilities(:capex_credit_cycle)`で能力プロファイルを取得できる。
