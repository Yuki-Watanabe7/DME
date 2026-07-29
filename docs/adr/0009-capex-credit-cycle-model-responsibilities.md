# ADR 0009: 部門別CAPEX・信用循環モデルを独立モデルとし、会計整合性を残差部門つき部分閉鎖に限定し、モデル横断比較を概念対応の明示に留める

- **ステータス**: 採用
- **日付**: 2026-07-29
- **関連Issue**: #125（ロードマップ）・#167（本決定・責務境界）・#163／#164／#165／#166（前提設計）・後続 #168 以降（実装）・#99（SFC ロードマップ）
- **前提ADR**: [ADR 0002](0002-minsky-integration-design.md)（既存インターフェース準拠・自前ソルバー・LLM 層無拡張の統合方針）・[ADR 0003](0003-minsky-financing-regime-diagnostics.md)（診断をモデル本体から分離した読み取り専用層とする）・[ADR 0006](0006-cross-model-reasoning-contract.md)（概念対応の明示・同名変数の非同一視・比較不能の非統合）・[ADR 0007](0007-sfc-integration-contract.md)（会計恒等式をモデル方程式と分離した検証契約とする・不整合を自動補正しない）
- **関連ドキュメント**: [責務境界とモデル間比較契約](../models/capex_credit_cycle_model_boundaries.md)・[分析契約](../models/capex_credit_cycle_analysis_contract.md)・[因果グラフ](../models/capex_credit_cycle_causal_graph.md)・[部門境界と変数定義](../models/capex_credit_cycle_sectors_variables.md)・[ストック・フロー会計表](../models/capex_credit_cycle_stock_flow.md)・[モデル能力・概念定義 metadata](../model_capabilities.md)・[モデル共通インターフェース](../architecture/model_interface.md)

## コンテキスト

DME には解析的マクロモデル群（Ramsey / Solow / RBC / IS-LM / AD-AS / New Keynesian /
Mundell-Fleming / VAR）に加え、Minsky 系 `KeenModel`（集計的な賃金シェア・雇用率・民間債務比率の
3 変数 ODE）と最小 SIM 型 SFC モデル `SIMModel`（会計整合的な閉鎖経済）がある。Roadmap #125 は
これらとは別に、AI・半導体 CAPEX 調整が部門別の実物・金融経路を通じてどう波及するかを扱う
**部門別CAPEX・信用循環モデル**（以下 `CCC`）を求めている。

#163–#166 が、`CCC` の分析契約（判定問題 Q1–Q5・`broad_downturn` の操作的定義）・因果グラフ
（増幅ループ `R1`–`R4`・遮断経路 `B1`–`B7`）・部門境界（案A 5 部門）と変数辞書・ストック・フロー
会計表（残差部門 `SX` を含む 6 列、会計恒等式 12 項目）を確定した。しかし「このモデルが DME 内で
何を担い、何を担わないか」は未確定であり、次の 3 つの失敗様式が具体的に起こりうる状態にある。

1. **重複と混在**: 金融不安定性・会計整合性・金融政策・実証フィットの全責務を `CCC` へ詰め込むと、
   `Keen` の集計信用循環、`SIM` の会計閉鎖、`NK` の価格設定と政策反応が `CCC` 内部で再実装され、
   どの機構が結果を生んだかを識別できない巨大モデルになる。
2. **無断複製**: `CCC` が既存モデルの理論・API を複製すると、同名概念の 2 系統（`d` と `debt_s`、
   Hedge/Speculative/Ponzi と資金繰り圧力ラベル）が生じ、どちらが正かを判定する基準が無くなる。
3. **過剰な統合**: 逆に各モデルを完全に分離すると、同一シナリオを横断比較するという #125 の目的が
   実現できない。一方で無条件に統合すると、[ADR 0006](0006-cross-model-reasoning-contract.md) が禁じた
   同名変数の同一視・比較不能の平均化が復活する。

加えて `CCC` の会計表は #99 Phase 5 の SFC 検討と重複しうる。#166 は会計プリミティブを再利用する
方針を採ったが、「限定的会計整合性」と「一般 SFC フレームワーク」の境界、および共通機能の移管可否は
未確定である。

## 決定

1. **`CCC` を `AbstractMacroModel` を直接継承する独立モデルとする。既存モデルの拡張・派生としない。**
   `KeenModel` の拡張、`SIMModel` の部門追加、`NewKeynesianModel` へのブロック追加のいずれも採らない
   （§1）。

2. **`CCC` の責務を、判定問題 Q1–Q5 に必要な範囲へ限定する。**
   含める責務 10 件（部門別の需要・供給・受注残・在庫・稼働率、CAPEX と資本パイプライン、企業 CF・
   債務・資金調達制約、信用条件による投資増幅、家計への波及、政策金利の外生経路、限定的会計制約、
   診断ラベル、資金繰り圧力診断）と、含めない責務 12 件を [責務境界](../models/capex_credit_cycle_model_boundaries.md) §3・§4 で
   確定した。含めない責務は例外なく「含めない」で確定する（§2）。

3. **初期MVPの会計整合性は、モデル外・残差部門 `SX` を置いた部分閉鎖に限定する。**
   `accounting_closure` は `:partial` を申告し、`:stock_flow_consistent` を名乗らない。`CCC` は SFC を
   名乗らない（§3）。

4. **会計プリミティブと汎用検証は既存 `src/sfc/` を再利用し、登録簿とモデル固有恒等式は共有しない。**
   `CCC` 専用の会計型を新設せず、かつ `CCC` の会計表を一般 SFC 用に汎化しない（§3.2）。

5. **モデル横断比較では、概念対応（`mapping_type`）と数値比較可否（`comparability`）を分離して保持する。**
   `CCC` と既存 4 モデルの間に `equivalent` は 1 つも存在しないことを確定事項として記録する（§4）。

6. **同一イベントのモデル間翻訳可否を表として固定し、翻訳不能なイベントを近似・代理・スケーリングで
   適用しない。** 翻訳不能を「そのモデルでは影響が無い」と解釈しない（§4.2）。

7. **契約 §3 Q2 の信用増幅度は、同一実装内で信用条件感応パラメータを `0` に固定した反実仮想としてのみ
   定義する。** 信用チャネルを持たない別モデルとの IRF 差で代用しない（§4.3）。

8. **`SimulationResult` 型を変更しない。methodology 相当の情報は `metadata::Dict{String,Any}` の
   予約キーで保持する。** 部門・金融商品の構造は `SFCResult` 側に置き、平坦 Dict へ潰さない（§5）。

9. **モデル合成・連成（あるモデルの出力を別モデルの入力へ渡す機構）を本 Phase で実装しない。**
   横断比較はシナリオレベルの並列実行と、概念対応を明示した比較に留める（§6）。

## 1. なぜ新規独立モデルとするか

### 1.1 既存モデルが判定問題に答えられない

契約 §3 の Q1–Q5 は、部門別の産出乖離 `dY_{s,t}`・在庫比率・稼働率・部門別実行 CAPEX・部門別信用
スプレッドを判定量として要求する。既存 4 モデルはいずれもこれらを持たない。

| モデル | 欠けているもの |
|---|---|
| `KeenModel` | 部門構造そのもの。集計経済 1 部門で、受注残・在庫・稼働率・資本財の受発注を持たない |
| `SIMModel` | 企業債務・在庫・資本・投資・信用条件。金融資産は政府貨幣 `H` のみ |
| `NewKeynesianModel` | 部門構造・信用の伝播経路・ストック。状態変数を持たない静学的 MSV 解 |
| `VARModel` | 構造そのもの。係数は手入力で、増幅ループの遮断（`credit-off` 反実仮想）を定義できない |

### 1.2 なぜ `Keen` 拡張として実装しないか

`CCC` は `Keen` と同じ現象クラス（信用による投資の増幅と崩壊）を扱うため、`Keen` の拡張が最も
自然な選択肢に見える。しかし次の 4 点により成立しない。

| 観点 | `KeenModel` | `CCC` | 拡張した場合に壊れるもの |
|---|---|---|---|
| 状態空間 | `ω`・`λ`・`d` の 3 変数（すべて比率） | 約 16 の部門別水準状態（`cap_s`・`capex_pipe_s`・`backlog_s`・`inv_s`・`cash_s`・`debt_s`） | `steady_state` の閉形式解（良い均衡）。3 変数を前提とした導出が成立しない |
| 時間表現 | 連続時間 ODE、年単位、固定刻み RK4 | 離散四半期（`Δt = 0.25`）、期内処理順序 10 ステップ | ODE ソルバー・`ODESolverOptions`・`guard_max` による発散打ち切り |
| 集計レベル | 集計経済 1 | 5 経済部門 + 残差部門 `SX` | `d = D/Y` の定義。部門別債務の集計を `d` と呼べない（[ADR 0006](0006-cross-model-reasoning-contract.md) の同名変数非同一視） |
| 依存する後段層 | 診断層（`diagnose_financing_regime`・`minsky_diagnostics`）・実証層（`calibrate_keen`・`validate_keen`）・LLM 説明契約（[ADR 0005](0005-keen-ai-explanation-contract.md)） | 独自の診断ラベル 4 値・`funding_pressure_s` 5 値 | すべてが `ω`・`λ`・`d` に依存しており、状態空間を変えると同時に破壊される |

[ADR 0004](0004-keen-empirical-calibration-strategy.md) が定めた `Δt = 0.25` の時間軸契約は、**年単位 ODE
である `Keen` を四半期データへ接続するための契約**であって `Keen` 自体を四半期モデルへ変換するもの
ではない。この契約を根拠に `Keen` を離散四半期化することはできない。

### 1.3 `SIM` 拡張・`NK` 拡張も採らない

`SIMModel` の部門を 5 つへ拡張する案は、`SIM` の中心的性質（経済全体で完全に閉じる、残差部門を
置かない）を `SX` の導入で壊す。`NewKeynesianModel` へ部門ブロックを追加する案は、前向き合理的
期待と後ろ向き行動方程式を同一モデル内で混在させ、どちらが結果を生んだかを識別できなくする。

## 2. 含めない責務の確定

[責務境界](../models/capex_credit_cycle_model_boundaries.md) §4.1 で 12 件を採否付きで確定した。Issue #167 §3 が挙げた候補 7 件は
すべて「含めない」で確定し、上流 4 文書の設計から派生する候補 5 件を追加した。

| 候補 | 採否 | 主な根拠 |
|---|---|---|
| Keen 型 `ω`・`λ`・`d` の ODE 複製 | 含めない | §1.2。複製すると同名の 2 系統が生じ、どちらが正かを判定できない |
| 完全な Godley-Lavoie 型制度部門 SFC | 含めない | #99 Phase 5 の責務。Q1–Q5 が必要としない |
| 標準 NK の価格設定・期待方程式一式 | 含めない | 前向き期待と後ろ向き行動方程式の混在を避ける |
| VAR による統計推定ロジック | 含めない | [ADR 0004](0004-keen-empirical-calibration-strategy.md) の固定/推定分離と同じ規律 |
| 個別企業の最適化問題・合理的期待均衡 | 含めない | 契約 §6 が ABM を対象外。集約部門モデルは粒度を持たない |
| 株価の価格形成モデル | 含めない | 株式を貸借対照表へ載せない決定（#166 §3.4）と整合。評価損経路の復活を避ける |
| 投資判断・景気後退確率の生成 | 含めない | 契約 §6・§4.1（`recession` を出力語として禁止）。[llm_safety.md](../llm_safety.md) の禁止表現 |
| 金融政策反応関数（Taylor ルール型） | 含めない | `X05` は `EXT`。Q4 は規模×遅延の 2 次元スイープで定義済み |
| 一般物価・インフレ動学 | 含めない | 全変数を実質で定義済み（#165 §5.1）。観測方程式の実質化と二重になる |
| デフォルト・信用損失の内生化 | 含めない | `nw_s4 ≡ 0` のため貸倒の吸収先が定義できない（#166 §7.2） |
| 家計の金融資産・負債・資産効果 | 含めない | `X01`・`X02` は `EXT`。会計改訂が先決 |
| モデル合成・連成 | 含めない | §6 |

除外の帰結として `CCC` が答えられない問い（金融政策効果・分配動学・経済全体の資金循環・倒産確率・
景気後退確率・銀行の貸し渋り・個別企業の帰結・国際波及）を [責務境界](../models/capex_credit_cycle_model_boundaries.md) §4.2 に明示し、
LLM 説明層はこれらを問われた場合に答えを生成せず、範囲外である旨と送り先モデルを返す。

## 3. 初期MVPで採用する会計整合性の範囲

### 3.1 部分閉鎖の申告

| 項目 | 決定 |
|---|---|
| 会計上の部門 | `S1`–`S5` + モデル外・残差部門 `SX`（6 列） |
| 閉鎖の程度 | **部分的**。`SX` 列の列和は定義上ゼロになるため検証対象にしない |
| `accounting_closure` | `:partial`（`:stock_flow_consistent` を名乗らない） |
| 検証項目 | 12 件（汎用 5 + `CCC` 固有 7、#166 §8.1） |
| 許容誤差・`NaN`・発散の扱い | [ADR 0007](0007-sfc-integration-contract.md) を継承。`CCC` 専用規約を作らない |
| 自動補正 | 行わない（[ADR 0007](0007-sfc-integration-contract.md) 決定 §5） |

`CCC` は SFC を名乗らない。LLM 説明層は「経済全体で閉じた SFC ではない」ことと「`S5` の貯蓄・
純資産を追跡していない」ことを必ず明示する。「会計恒等式を検証している」ことと「SFC である」ことを
同一視しない。

### 3.2 #99 Phase 5 との境界と再利用方針

| 層 | 扱い |
|---|---|
| 会計プリミティブ（`SFCSector` / `SFCInstrument` / `BalanceSheetMatrix` / `TransactionFlowMatrix` / `SFCPeriodSnapshot` / `SFCResult`） | **再利用する。新設しない** |
| 汎用検証（`:balance_row_sum` / `:balance_column_sum` / `:flow_row_sum` / `:flow_column_sum` / `:stock_flow`） | **再利用する** |
| 符号規約・時点規約・許容誤差・`NaN` 処理 | **[ADR 0007](0007-sfc-integration-contract.md) から継承する** |
| 登録簿（`S1`–`S5`・`SX`、instrument 4 種） | **`SIM` と共有しない**（部門定義が根本的に異なる） |
| `CCC` 固有恒等式（`:nlb_consistency`・`:net_worth_update`・`:capex_funding`・`:s4_balance_sheet`・`:output_income_split`・`:aggregate_output`・`:no_double_count`） | **`CCC` 固有の読み取り専用検証層として追加する** |
| 完全な制度部門別 SFC・本格 Minsky-SFC | **#99 Phase 5**（`CCC` は `nw_s4 ≡ 0`・`writeoff_s ≡ 0` として境界のみ残す） |

`:nlb_consistency`・`:net_worth_update`・`:s4_balance_sheet`（汎化が必要）は部門構成に依存しないため
**#99 Phase 5 への移管候補**として登録する。本 ADR は移管を決定せず、候補としての引き渡しに留める。

## 4. モデル横断比較で保証するもの・保証しないもの

### 4.1 保証範囲

| 保証する | 保証しない |
|---|---|
| 概念対応の明示（`mapping_type` ∈ `equivalent`/`proxy`/`partial`/`incompatible`） | 同名変数の同一性 |
| 数値比較可否の判定（`comparability` ∈ `comparable`/`partial`/`insufficient`/`incompatible`） | 比較可能と判定された数値の経済学的な意味の一致 |
| 単位・頻度・集計・時点・型の差の記録 | 差を埋める変換の自動生成（明示 `transform` が無ければ降格） |
| 比較不能の構造化（理由・必要な追加証拠） | 比較不能項目の近似・平均による補完 |
| 翻訳不能なイベントの構造化（`untranslatable`） | 翻訳不能を「影響が無い」と読み替えること |
| モデルごとの機構差の記述 | 統一パラメータ推定・ensemble 予測・モデル平均・単一ランキング |

`CROSS_MODEL_CONCEPTS` の 5 軸について、[ADR 0006](0006-cross-model-reasoning-contract.md) §3.2 の導出規則を
`CCC` の `ModelConceptCoverage` へ機械的に適用した結果、**`CCC` と既存 4 モデルの間に `equivalent` は
1 つも存在しない**。したがって `shared_concepts` は空であり、共通概念として並べられる系列は無い。

概念対応と数値比較可否は別問題として扱う。具体例として、`CCC` × `SIM` の `shock_response` は導出
規則上 `proxy` になるが、共通のショック種別が存在しない（`SIM` は `G`・`θ`、`CCC` は CAPEX・信用）
ため `comparability = :incompatible` とする。

### 4.2 イベント翻訳

契約 §5.3 の `SH-EXP` / `SH-CAPEX` / `SH-CREDIT` / `SH-EASING` について、各モデルへの翻訳可否を
[責務境界](../models/capex_credit_cycle_model_boundaries.md) §5.5 の表で固定した。規則は次の 5 点。

1. 翻訳不能（`×`）のイベントを当該モデルへ適用しない。近似・代理・スケーリングによる適用を行わない。
2. 翻訳不能を「そのモデルでは影響が無い」と解釈しない。構造上表現できないことを述べる。
3. 部分翻訳（`△`）の結果を完全翻訳（`○`）と同じ確度で提示しない。失われた情報を必ず併記する。
4. 翻訳不能なイベントを含む比較で、モデル間の優劣を述べない（[ADR 0006](0006-cross-model-reasoning-contract.md) 決定 §6）。
5. 翻訳不能を出力から省略せず、理由・欠落機構・必要な追加証拠を構造化して返す。

### 4.3 信用増幅度の定義を反実仮想へ限定する

契約 §3 Q2 の増幅度 `A = |peak(dI^{full})| / |peak(dI^{credit-off})|` は、**同一実装内で投資関数の
信用条件感応パラメータを `0` に固定した反実仮想としてのみ定義する**。ショック系列・初期状態・乱数は
変えない。信用チャネルを持たない別モデル（`NK` 等）との IRF 差で代用しない。

根拠: `NK` の産出ギャップ IRF は対数偏差・集計・前向き期待付きであり、`CCC` の `dI`（部門別実行
CAPEX の baseline 比乖離）と `measure`・`aggregation`・期待形成のすべてが異なる。両者の差を増幅度と
呼ぶと、信用チャネルの寄与と集計レベル・期待形成の差が分離できない。

## 5. 出力コンテナと methodology metadata

`src/core/simulation_result.jl` の `SimulationResult` は `model_name` / `scenario_name` / `variables` /
`metadata` の 4 フィールドで、`methodology` フィールドを持たない。既存 8 モデル以上がこの型に依存
しており、フィールド追加は破壊的変更になる。

**決定: 型を変更せず、`metadata::Dict{String,Any}` の予約キーで methodology 相当を保持する。**

| 情報 | 置き場 |
|---|---|
| 水準系列・診断系列 | `variables`（平坦キー + 部門接尾辞、#165 §6.5） |
| モデルパラメータ | `metadata["parameters"]`（既存 adapter 慣習） |
| 変数の役割・部門・単位 | `metadata["variable_roles"]` / `["variable_sectors"]` / `["variable_units"]` |
| 契約バージョン | `metadata["contract_version"]` / `["graph_version"]` / `["vars_version"]` / `["accounting_version"]` / `["boundaries_version"]` |
| シナリオ・ショック定義（7 項目） | `metadata["scenario"]` |
| 診断閾値セットの識別子とバージョン | `metadata["diagnostic_threshold_set"]` |
| 会計表・検証結果 | `SFCResult`（別型。`simulation_result` フィールドで参照） |

部門・金融商品の構造を平坦 Dict へ潰さない点は [ADR 0007](0007-sfc-integration-contract.md) 決定 §6 と同型である。
予約キーは `CCC` がモデル差を保持するための手段であり、他モデルへ同じキーを要求しない。

## 6. なぜモデル合成・連成を本 Phase で実施しないか

1. **`equivalent` な概念が 1 つも無い**（§4.1）。ある モデルの出力を別モデルの入力へ渡すには、
   受け渡す変数が定義・単位・時点・集計のすべてで一致している必要がある。現状 `proxy` 以下しか
   存在せず、渡した時点で定義の不一致が数値へ埋め込まれ、下流では検出できなくなる。
2. **時間軸・頻度が揃わない**。`Keen` は連続時間・年、`CCC` は離散四半期、`NK` は静学的 MSV 解で
   ある。連成には時間軸変換が必要だが、変換の妥当性は [ADR 0004](0004-keen-empirical-calibration-strategy.md) の
   識別戦略と同等の検証を要し、本 Phase の範囲を超える。
3. **検証手段が無い**。連成結果の正しさを判定する基準（どちらのモデルの出力を正とするか）が存在
   しない。#170 の履歴再生は単一モデルの検証方式であり、連成系には適用できない。
4. **判定問題が連成を必要としない**。Q1–Q5 はすべて `CCC` 単独の反実仮想・スイープで定義されて
   おり、他モデルの出力を入力として要求していない。

代替として、同一イベントを §4.2 の翻訳表に従って各モデルへ個別適用し、**シナリオレベルの並列実行**
の結果を概念対応を明示したうえで比較する。これは既存の `compare_results_v2` と
`build_cross_model_comparison_context` で実現でき、新規機構を要しない。

## 7. versioning

- 本決定に対応する文書バージョンは `capex-credit-cycle-boundaries/1.0.0`。
- 次を変更する場合は major: 責務の含む/含めないの採否、`accounting_closure` の申告値、
  `mapping_type` / `comparability` の 2 層分離、イベント翻訳可否表の判定（`○`/`△`/`×`）、
  `equivalent` が存在しないという確定事項、`metadata` 予約キーの意味論、Q2 増幅度の定義。
- 既存モデルの拡張により §4.2 の翻訳可否が変わった場合は、[責務境界](../models/capex_credit_cycle_model_boundaries.md) の改訂を要する。
- `ModelCapabilityProfile` / `ModelConceptCoverage` の提案値は #171 の registry 登録時に確定する。
  提案値と異なる値で登録する場合は本 ADR と [責務境界](../models/capex_credit_cycle_model_boundaries.md) §2.6・§5.2 を改訂する。

## 理由

- **判定問題からの逆算**: 責務の含む/含めないを「一般に望ましいか」ではなく「Q1–Q5 に必要か」で
  決めた。これにより、較正できない自由度をモデルへ持ち込まないという #166 §7.2 の規律が責務レベル
  でも一貫する。
- **既存資産の保護**: `Keen` の診断層・実証層・LLM 説明契約、`SIM` の会計検証、`NK` の概念分離は
  いずれも各モデルの状態空間に強く依存している。独立モデルとすることで、これらを一切変更せずに
  `CCC` を追加できる（[ADR 0002](0002-minsky-integration-design.md) の「既存インターフェース準拠・既存層無拡張」と同方針）。
- **検出可能な失敗を選ぶ**: 部分閉鎖（`:partial`）を正直に申告することで、`SX` へ流れる規模が大きい
  ときに会計検証の検出力が下がることを利用者が把握できる。`:stock_flow_consistent` を名乗ると、
  同じ結果が「検証済み」として過大に信頼される。
- **比較の 2 層分離**: 概念対応と数値比較可否を分けることで、「概念としては対応するが数値は並べられ
  ない」という最も頻度の高いケースを、無理な統合にも過剰な切断にも倒さずに表現できる
  （[Keen–SFC 比較レポート](../analysis/keen_sfc_comparison.md) で有効性が確認済みの設計）。
- **連成の先送りは可逆**: 合成・連成を実装しないことは、将来 `equivalent` 概念が増えた時点で
  再検討できる。逆に、対応が曖昧なまま連成を実装すると、誤った受け渡しが下流の全結果へ伝播し、
  事後に切り分けられない。

## 見送りとした選択肢

- **`KeenModel` の拡張として実装**: 状態空間・時間表現・集計レベルが異なり、`Keen` の閉形式定常状態・
  双安定性・診断層・実証層・LLM 説明契約がすべて `ω`・`λ`・`d` に依存しているため同時に破壊される（§1.2）。
- **`SIMModel` の部門拡張として実装**: 残差部門 `SX` の導入が `SIM` の中心的性質（経済全体で完全に
  閉じる）を壊す。`SIM` の会計検証が保証している内容が変質する。
- **`NewKeynesianModel` への部門ブロック追加**: 前向き合理的期待と後ろ向き行動方程式が同一モデル内で
  混在し、どちらの機構が結果を生んだかを識別できなくなる。
- **#99 Phase 5 の一般 SFC 基盤を先に実装し、その上に `CCC` を載せる（案 I）**: #125 が #99 Phase 5 の
  完了に依存し、判定問題への到達が大幅に遅れる。加えて `SX`（残差部門）という `CCC` 固有の設計を
  一般 SFC の要件へ持ち込むと、経済全体で閉じるという SFC の中心的性質が緩む。
- **`CCC` 内に会計表・検証を完全に自前実装する（案 II）**: `src/sfc/` と重複した型・検証が二系統になり、
  [ADR 0007](0007-sfc-integration-contract.md) の規約と分岐しうる。Issue #167 が禁じる「既存モデルの理論・API の無断複製」に該当する。
- **`accounting_closure = :stock_flow_consistent` を申告する**: `SX` を置いた部分閉鎖であり事実に反する。
  能力を推測で過大申告しないという `docs/model_capabilities.md` §5 の設計方針に反する。
- **`SimulationResult` へ `methodology` フィールドを追加する**: 既存 8 モデル以上に依存される型の
  破壊的変更になる。`metadata` の予約キーで同じ情報を保持でき、[ADR 0007](0007-sfc-integration-contract.md) が
  `SFCResult` で採った「別型へ分離する」方針とも整合する。
- **`CAPABILITY_EQUILIBRIUM_CONCEPTS` へ `CCC` 用の新語彙を追加する**: 語彙の追加は全モデルの
  JSON round-trip と比較層の意味論に影響する。`:none` を申告し、追加の要否は #171 が判断する。
- **翻訳不能なイベントをスケーリングで各モデルへ適用する**: 翻訳不能はモデルの構造上その事象を
  表現できないことを意味し、スケーリングでは埋まらない。適用すると「効果が小さい」という誤った
  結論を生む。
- **モデル横断で fit を比較しランキングを作る**: 実証 fit を持つのは `Keen` 実証層のみであり、
  対象系列・期間・自由度・推定方法が一致しない（[ADR 0006](0006-cross-model-reasoning-contract.md) 決定 §5）。

## 影響

- **既存コードへの影響は無い**。本 ADR は既存モデルの型・API・出力キー・docs の変更を求めない。
  `CCC` の実装（#171）が registry へ追記する時点で初めてコード変更が生じる。
- **#168（イベント変換）** は [責務境界](../models/capex_credit_cycle_model_boundaries.md) §5.5 の翻訳可否表を判定結果として受け取り、
  実装のみを行う。翻訳可否そのものを #168 で再判定しない。`untranslatable` の構造化返却を実装する。
- **#169（動学方程式）** は §2 の含めない責務 12 件を方程式として実装しない。診断層をモデル本体から
  分離し、会計検証を行動方程式と独立に走らせる。
- **#170（観測・検証）** は §3 で `false` とした `estimation` / `out_of_sample_validation` の申告を
  再評価し、統計推定ロジックをモデル本体へ持ち込まない。
- **#171（統合）** は `ModelCapabilityProfile` / `ModelConceptCoverage` / `ModelConceptDefinition` /
  `_XM_MODEL_LABELS` への追記、`docs/model_capabilities.md` §3 と `docs/model_selection_guide.md` への
  行追加、および [責務境界](../models/capex_credit_cycle_model_boundaries.md) §8 の差し戻し事項 `C1`（`model_interface.md` の実装モデル列挙に
  `KeenModel`・`SIMModel` が無い）・`C2`（選択ガイドに `SIM` が無い）・`C3`（均衡概念の語彙）を処理する。
- **#99 Phase 5** は §3.2 の移管候補（`:nlb_consistency`・`:net_worth_update`・`:s4_balance_sheet` の
  汎化）と、残差部門を持つ会計表の扱いの共通化可能性を検討事項として受け取る。
- **LLM 説明層** は [責務境界](../models/capex_credit_cycle_model_boundaries.md) §9 の必須記載 5 項目（`equivalent` が無いこと、翻訳不能の
  読み替え禁止、「SFC 検証済み」と述べないこと、答えられない問いの扱い、資金繰り圧力ラベルを
  Hedge/Speculative/Ponzi と同一視しないこと）を [llm_safety.md](../llm_safety.md) の必須記載と併せて適用する。

## 参考

- [部門別CAPEX・信用循環モデル 責務境界とモデル間比較契約](../models/capex_credit_cycle_model_boundaries.md) — 本 ADR の詳細設計。横断比較表・責務の採否・比較契約・SFC 重複整理
- [部門別CAPEX・信用循環モデル 分析契約](../models/capex_credit_cycle_analysis_contract.md) — 判定問題 Q1–Q5・`broad_downturn` の操作的定義・比較シナリオ
- [部門別CAPEX・信用循環モデル 因果グラフ](../models/capex_credit_cycle_causal_graph.md) — 増幅ループ `R1`–`R4`・遮断経路 `B1`–`B7`・`EXT` エッジ
- [部門別CAPEX・信用循環モデル 部門境界と変数定義](../models/capex_credit_cycle_sectors_variables.md) — 案A 5 部門・役割判定規則・変数辞書・共通 API 適合方針
- [部門別CAPEX・信用循環モデル ストック・フロー会計表](../models/capex_credit_cycle_stock_flow.md) — `SX` を含む会計表・残高更新式・会計恒等式 12 項目・#99 Phase 5 との責務境界
- [ADR 0006: クロスモデル推論契約](0006-cross-model-reasoning-contract.md) — 概念対応の明示・同名変数の非同一視・`insufficient_comparability`・fit 比較制限
- [ADR 0007: SFC 統合契約](0007-sfc-integration-contract.md) — 会計恒等式を別検証契約とする・自動補正しない・`SFCResult` 別型・compare v1 非破壊/v2 加算
- [モデル能力・概念定義 metadata](../model_capabilities.md) — `ModelCapabilityProfile` / `ModelConceptDefinition` のスキーマと新規モデル追加手順
- [モデル共通インターフェース](../architecture/model_interface.md) — 抽象型階層・新規モデル追加ルール
- [Keen–SFC 概念対応・比較レポート](../analysis/keen_sfc_comparison.md) — 概念対応と数値比較可否を分離する設計の先行例
