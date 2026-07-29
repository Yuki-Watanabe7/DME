# 部門別CAPEX・信用循環モデル 責務境界とモデル間比較契約

> 関連 Issue: #167（本書）・#163（分析契約）・#164（因果グラフ）・#165（部門境界と変数定義）・#166（ストック・フロー会計表）・#99（SFC ロードマップ）・#125（ロードマップ）
> 前提: [分析契約](capex_credit_cycle_analysis_contract.md)・[因果グラフ](capex_credit_cycle_causal_graph.md)・[部門境界と変数定義](capex_credit_cycle_sectors_variables.md)・[ストック・フロー会計表](capex_credit_cycle_stock_flow.md)・[ADR 0006](../adr/0006-cross-model-reasoning-contract.md)・[ADR 0007](../adr/0007-sfc-integration-contract.md)
> 決定記録: [ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md)
> 後続設計: #168（イベント変換）・#169（動学方程式）・#170（観測・検証）・#171（統合）

---

## メタ情報

| 項目 | 内容 |
|---|---|
| **対象** | 部門別CAPEX・信用循環モデル（`CapexCreditCycleModel` 相当、未実装）と既存モデル群（`KeenModel` / `SIMModel` / `NewKeynesianModel` / `VARModel`）の責務分担 |
| **ステータス** | 責務境界・比較契約・SFC との重複整理のみ確定。方程式・実装・registry コードは未着手 |
| **boundaries version** | `capex-credit-cycle-boundaries/1.0.0` |
| **上位契約** | `capex-credit-cycle-contract/1.0.0`・`capex-credit-cycle-graph/1.0.0`・`capex-credit-cycle-vars/1.0.0`・`capex-credit-cycle-accounting/1.0.0` |
| **継承する横断契約** | `cross-model-context/1.0.0`（[ADR 0006](../adr/0006-cross-model-reasoning-contract.md)）・`comparison-v2/1.0.0`（`src/core/compare_v2.jl`）・`model-capability/1.0.0`（`src/core/model_capabilities.jl`） |
| **基準経済・頻度** | 米国・四半期（契約 §2.1 を継承。`Δt = 0.25` 年） |
| **モデル識別子（提案）** | `:capex_credit_cycle`（`_XM_MODEL_LABELS` 表示名「部門別CAPEX・信用循環モデル」） |

> **LLM向け要約**: 本書は新規部門別CAPEX・信用循環モデルの**理論的・実装上の範囲**を固定する。
> 各モデルが回答する問い・主要状態・強み・限界を §2 の横断比較表に整理し、新規モデルへ**含める責務**（§3）と
> **含めない責務**（§4）を採否付きで確定する。含めない責務の代表は Keen 型 3 変数 ODE の複製・完全な
> Godley-Lavoie 型 SFC・New Keynesian の価格設定/期待方程式・VAR の統計推定・個別企業最適化・株価の
> 価格形成・景気後退確率の生成である。モデル間比較は [ADR 0006](../adr/0006-cross-model-reasoning-contract.md) を継承し、
> **概念対応（`mapping_type`）と数値比較可否（`comparability`）を分離**する（§5）。新規モデルと既存 4 モデルの間に
> `equivalent` は 1 つも存在しない（§5.2）。同一イベントの翻訳可否は §5.5 の表で固定し、**翻訳不能なイベントを
> 無理に適用しない**（§5.6）。`SimulationResult` を共通コンテナとしつつ methodology 相当情報は `metadata` の
> 予約キーで保持する（§5.7）。#166 の限定的会計整合性と #99 Phase 5 の一般 SFC の境界は §6 で確定する。
> 本書は方程式・パラメータ値・実装・registry コードを定めない（§10）。

---

## 1. 本書の位置づけと確定範囲

### 1.1 位置づけ

[分析契約](capex_credit_cycle_analysis_contract.md)が「何を問うか」、[因果グラフ](capex_credit_cycle_causal_graph.md)が「どの経路で伝わるか」、[部門境界と変数定義](capex_credit_cycle_sectors_variables.md)が「どの部門が何を持つか」、[ストック・フロー会計表](capex_credit_cycle_stock_flow.md)が「各期の残高がどう閉じるか」を固定した。
本書はその上で「**このモデルが DME 内で何を担い、何を担わないか**」と「**他モデルと何をどこまで比べてよいか**」を固定する。

DME には既に Keen（金融不安定性）・SIM（会計整合性）・New Keynesian（金融政策）・VAR（統計的ベンチマーク）が存在する。新規モデルへ全責務を詰め込むと、既存モデルとの重複・理論の混在・検証不能な巨大モデル化を招く。一方で完全に分離すると #125 の目的（同一シナリオの横断比較）が実現できない。本書はその中間点を**明示的な契約**として固定する。

| 本書が固定するもの | 本書が固定しないもの |
|---|---|
| 各モデルが回答する問い・主要状態・強み・限界の横断比較（§2） | 既存モデルの実装・API・docs の変更（対象外、§10） |
| 新規モデルへ含める責務と、その限定条件（§3） | 各責務の方程式・関数形・パラメータ値（#169・#170） |
| 新規モデルへ含めない責務の採否と、除外に伴う「できないこと」（§4） | 除外項目の将来の再導入時期（`EXT` として境界のみ保持） |
| 概念対応・比較可能性・単位差の扱い（§5.1–§5.4） | `ModelConceptCoverage` / `ModelConceptMapping` の実際の registry コード（#171） |
| 同一イベントのモデル間翻訳可否と、翻訳不能時の規則（§5.5・§5.6） | イベント型・翻訳器の Julia API（#168） |
| `SimulationResult` を共通コンテナとする方式と methodology 相当情報の置き場（§5.7） | `SimulationResult` 型そのものの変更（行わない、§5.7） |
| #166 の限定的会計整合性と #99 Phase 5 の一般 SFC の境界・移管候補（§6） | 一般 SFC 基盤の実装時期・設計（#99 Phase 5） |
| 独立モデルとする判断とその根拠（§7、[ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md)） | モデル合成・連成エンジン（対象外、§10） |

### 1.2 規律（契約）

1. **既存モデルのコードを変更しない**。本書の結論は新規モデル側の設計制約と、新規モデルを登録する際の registry 追記（#171）としてのみ現れる。既存モデルの型・API・出力キーを変更する提案を本書は行わない。
2. **既存モデルの理論・API を複製しない**。同じ機構が必要になった場合、複製ではなく「そのモデルへ問いを送る」か「本モデルの範囲外と明示する」のいずれかを選ぶ（§4）。
3. **同名変数を同一視しない**。`d`・`debt`・`r`・`Y`・`I` などが複数モデルに現れても、`definition_key`・`unit`・`measure`・`timing` が一致しない限り `equivalent` としない（[ADR 0006](../adr/0006-cross-model-reasoning-contract.md)）。
4. **比較不能を統合しない**。共通化・平均・単一ランキングへ潰さず、`insufficient_comparability` として構造化して返す（[ADR 0006](../adr/0006-cross-model-reasoning-contract.md) 決定 §4）。
5. **能力を過大申告しない**。`ModelCapabilityProfile` の各フィールドは、上流 4 文書が明示的に確定した範囲のみを申告する。未確定は保守的な既定値（`false` / `:none` / 空）のままにする（`docs/model_capabilities.md` §5 の設計方針）。
6. **上流 4 文書の決定を本書で覆さない**。矛盾を検出した場合は §8 の差し戻し事項として登録し、当該文書の改訂で解決する（#165 §7・#166 §10.2 と同じ手続き）。

### 1.3 表記

| 記法 | 意味 |
|---|---|
| `CCC` | 部門別CAPEX・信用循環モデル（本モデル）。registry 識別子は `:capex_credit_cycle` |
| `Keen` / `SIM` / `NK` / `VAR` | `KeenModel` / `SIMModel` / `NewKeynesianModel` / `VARModel` |
| `equivalent` / `proxy` / `partial` / `incompatible` | `CROSS_MODEL_MAPPING_TYPES`（概念対応の種別、[ADR 0006](../adr/0006-cross-model-reasoning-contract.md) §3.1） |
| `comparable` / `partial` / `insufficient` / `incompatible` | `COMPARABILITY_LEVELS`（数値比較の可否、`src/core/compare_v2.jl`） |
| `endogenous` / `approximate` / `out_of_scope` | `CROSS_MODEL_TREATMENTS`（概念の扱い、[ADR 0006](../adr/0006-cross-model-reasoning-contract.md) §2） |
| `MVP` / `EXT` | 初期MVPで実装 / 将来拡張（因果グラフ §1.3 を継承） |
| `†` | 本書が新規に提案する registry 項目。実装は #171 |

---

## 2. モデル別の分析目的

### 2.1 横断比較表: 回答する問い・主要状態・強み・限界

| 観点 | `Keen` | `SIM`（SFC） | `NK` | `VAR` | `CCC`（新規） |
|---|---|---|---|---|---|
| **回答する問い** | 好況期の信用拡大はなぜ内生的に不安定化するか。債務はどの条件で崩壊経路へ入るか | 会計整合的な閉鎖経済で、政府支出・税率が需要と家計の富をどう決めるか | 需要・コストプッシュ・金融政策ショックに対しインフレと産出ギャップがどう動くか | 観測時系列間の線形動学はどうか（理論非依存のベンチマーク） | 特定CAPEXショックが部門別の実物・金融経路でどう波及し、どの条件で一般経済へ及ぶか |
| **主要状態** | `ω`（賃金シェア）・`λ`（雇用率）・`d`（民間債務比率）。すべて比率 | `H`（政府貨幣ストック、賃金単位・期末） | なし（`x`・`π`・`i` はすべて制御変数） | ユーザ定義の `n` 変数（単位もユーザ定義） | `cap_s`・`capex_pipe_s`・`backlog_s`・`inv_s`・`cash_s`・`debt_s`（約 16 状態、部門別水準） |
| **時間表現** | 連続時間 ODE（年） | 離散期 | 静学的解（四半期の IRF） | 離散期（ラグ 1） | 離散四半期（`Δt = 0.25`） |
| **主体の数** | 集計経済 1 | 3 部門（家計・政府・生産） | 代表的主体 | 非構造 | 5 経済部門 + 残差部門 `SX` |
| **信用** | 内生（受動的銀行貸出、`d` を追跡） | なし（金融資産は政府貨幣のみ） | なし | なし | 内生（部門別 `debt_s` と信用条件 `spread` / `rollover` / `lend_stance`） |
| **会計閉鎖** | `:none`（`d` のみ追跡） | `:stock_flow_consistent`（完全に閉じる） | `:none` | `:none` | `:partial`（`SX` を置いて閉じる、§6.1） |
| **期待** | 前向き期待なし | 前向き期待なし | 前向き合理的期待（MSV 解） | なし | 前向き期待なし（`ai_exp` は外生、期待の内生化 `X04` は `EXT`） |
| **最適化** | なし（行動方程式） | なし（行動方程式） | あり（代表的主体） | なし | なし（行動方程式） |
| **物価** | 固定（実質モデル） | 扱わない（`W` は数値基準） | 内生（`π`、一般物価） | 任意 | 部門相対価格 `price_s` のみ内生。一般物価・インフレなし |
| **金融政策** | なし（`r` は一定パラメータ） | なし | あり（Taylor ルール、内生反応） | 任意 | `policy_rate` は外生パス。政策反応関数 `X05` は `EXT` |
| **財政政策** | なし | あり（`G`・`θ`） | なし | 任意 | なし（`tax_s ≡ 0`、政府は `SX` へ集約） |
| **強み** | 外生ショックゼロで循環・崩壊が生じる。双安定性。実証較正 API を持つ唯一のモデル | 会計恒等式をモデル方程式と独立に全期検証できる唯一のモデル。閉形式・大域安定 | 前向き期待と政策反応を同時に扱える。概念分離が最も精緻（名目/実質/自然利子率を別 concept） | 変数集合が自由。理論モデルと実証の対比に使える | 部門別の CAPEX・受注・在庫・稼働率と信用条件を同時に持つ唯一のモデル。判定問題 Q1–Q5 に直接答える |
| **限界（抜粋）** | 政府・開放経済・資産価格なし。物価・金融政策チャネルなし。Hedge/Speculative/Ponzi は代理診断であり倒産予測ではない | 金融不安定性・企業債務・在庫・資本・価格変動なし。危機regime なし | ZLB なし。信用の伝播経路なし。カリブレーションのみで推定は非対象。異質主体なし | ラグ 1 期のみ。係数推定・SVAR 識別・信頼区間なし | 会計は `SX` を置いて閉じており経済全体で閉じない。デフォルト非内生。一般物価・政策反応関数・家計金融資産なし |
| **実装** | `src/models/keen.jl` | `src/models/sfc_sim.jl` | `src/models/new_keynesian.jl` | `src/models/var.jl` | 未実装（#171） |
| **参照** | [keen.md](keen.md) | [sim_sfc.md](sim_sfc.md) | [new_keynesian.md](new_keynesian.md) | [var.md](var.md) | 本書・上流 4 文書 |

### 2.2 `KeenModel`

| 項目 | 内容 |
|---|---|
| 分析目的 | 集計的な賃金シェア・雇用率・民間債務比率の相互作用から生じる金融不安定性。良い均衡への回帰と債務崩壊経路の双安定性。貸出金利の比較静学 |
| 状態 | `ω = wL/Y`・`λ = L/N`・`d = D/Y`（すべて比率、連続時間） |
| 派生量 | `π = 1 − ω − r·d`（利払い後利潤シェア）・`g = κ(π)/ν − δ` |
| 診断層 | `diagnose_financing_regime`（Hedge / Speculative / Ponzi 代理診断）・`minsky_diagnostics`（カバレッジ比率・regime滞在比率・発散時点） |
| 実証層 | `build_keen_empirical_dataset` → `calibrate_keen` → `validate_keen`（DME 内で唯一 `calibration` / `validation` API を持つ） |
| `CCC` との関係 | **同じ現象クラス（信用による投資の増幅と崩壊）を、異なる集計レベル・時間表現・状態空間で扱う**。相互補完であり代替ではない（§7・[ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md)） |

**契約**: Keen の集計的信用循環と `CCC` の部門別信用循環は、`private_debt_credit` 軸で `proxy` として対応づける（§5.2）。`d` と `debt_s` / `leverage_s` は**同名概念でも同一でない**（#165 §8・#166 §7.4）。

### 2.3 SFC モデル候補（`SIM` と #99 Phase 5）

| 項目 | 内容 |
|---|---|
| 分析目的 | 制度部門間の会計整合的なストック・フロー動学。金融資産と負債の完全な対応（「すべての金融資産は誰かの負債」） |
| 現行実装 | `SIMModel`（Godley & Lavoie 第3章、家計・政府・生産の 3 部門、金融資産は政府貨幣 `H` のみ） |
| 検証層 | `validate_sfc_accounting` → `AccountingCheckReport`（`:balance_row_sum` / `:balance_column_sum` / `:flow_row_sum` / `:flow_column_sum` / `:stock_flow`） |
| 将来 | 完全な制度部門別 SFC（政府・中央銀行・海外部門、価格体系、複数金融商品、評価損益）と本格 Minsky-SFC は #99 Phase 5 |
| `CCC` との関係 | **会計プリミティブと汎用検証は再利用し、登録簿とモデル固有恒等式は共有しない**（§6・#166 §9.1） |

**契約**: `SIM` と `CCC` の部門（`:households` と `S5`、`:production` と `S2`/`S3`）を同一概念として対応づけない。両モデルの会計残差・純資産を同一の比較表に並べない（#166 §9.2 を継承）。

### 2.4 `NewKeynesianModel`

| 項目 | 内容 |
|---|---|
| 分析目的 | 需要・コストプッシュ・金融政策ショックに対する集計 IRF。価格硬直性と Taylor ルールによる政策反応 |
| 変数 | `x`（産出ギャップ）・`π`（インフレ率）・`i`（名目利子率）。IRF はすべて定常状態からの乖離 |
| 概念分離 | `current_inflation` / `expected_inflation` / `inflation_target` / `nominal_policy_rate` / `model_implied_real_policy_rate` / `natural_real_rate` を別 concept として扱う（定常状態で数値一致しても同一概念としない） |
| `CCC` との関係 | **金融政策の内生反応と一般物価は `NK` の責務。`CCC` は `policy_rate` を外生パスとして受け取るのみ**（§4-8・§4-9） |

**契約**: 契約 §3 Q2 の増幅度 `A` は**同一実装内の反実仮想（`credit-off`）でのみ定義する**。信用チャネルを持たない `NK` との IRF 差で代用しない（分析契約 §3 Q2 が #167 へ差し戻した事項。§5.3 で再掲）。

### 2.5 `VARModel`

| 項目 | 内容 |
|---|---|
| 分析目的 | 観測時系列間の線形動学の記述。理論モデルの IRF に対する非構造ベンチマーク |
| 変数 | ユーザ定義の `n` 変数（`var_names`）。係数 `A`・定数 `c` は手入力 |
| `CCC` との関係 | **統計推定ロジックを `CCC` に持ち込まない**（§4-4）。`CCC` の IRF を `VAR` の IRF と比較する場合は、比較対象系列・期間・変換を `ComparisonSpec` で明示宣言する（§5.2） |

**契約**: `VAR` の概念対応は**利用者が選んだ変数集合に依存する**（registry の `caveats` に「変数定義はユーザーが選ぶ（理論的解釈なし）」と記録済み）。`CCC` との比較は registry の固定 mapping ではなく、`VariableComparisonMapping` の個別宣言によってのみ行う。

### 2.6 部門別CAPEX・信用循環モデル（`CCC`）

| 項目 | 内容 |
|---|---|
| 分析目的 | 特定 CAPEX ショック（AI 計算需要・収益期待の下方修正、hyperscaler の CAPEX 計画縮小）の産業別実物・金融波及。過剰設備・投資調整・信用増幅・雇用と消費への伝播 |
| 判定問題 | 契約 §3 の Q1–Q5（産業内収束条件・信用増幅条件・一般経済波及条件・遮断条件・分岐の非線形性） |
| 部門 | `S1` AI・クラウド需要 / `S2` 半導体設計・製造 / `S3` 製造装置・DC建設・電力 / `S4` 金融・信用 / `S5` 家計・一般経済 + 会計上の `SX` |
| 増幅機構 | `R1` 内部資金・受注ループ / `R2` 信用増幅ループ / `R3` 担保・借換ループ / `R4` 所得・消費ループ |
| 診断出力 | `contained_adjustment` / `sectoral_downturn` / `broad_downturn` / `indeterminate`（契約 §4.2） |
| 出力の性質 | すべて baseline 比の乖離 `dx_t`。水準の絶対値で判定・診断しない（契約 §2.4） |

**`ModelCapabilityProfile`（提案、#171 が `MODEL_CAPABILITY_REGISTRY` へ登録）†**

| フィールド | 値 | 根拠 |
|---|---|---|
| `model` / `model_type` | `:capex_credit_cycle` / `:CapexCreditCycleModel` | 本書 §1.3 |
| `time_representation` / `time_unit` | `:discrete` / `"quarterly"` | 契約 §2.1 |
| `apis` | `[:steady_state, :simulate, :impulse_response]` | `transition_path` は前向き期待を持たないため実装しない（Keen と同方針）。`calibration` / `validation` の可否は #170 が判断 |
| `sectors` | `[:household, :firm, :bank]` | `S5` → `:household`、`S1`–`S3` → `:firm`、`S4` → `:bank`。`:government` / `:external` は `SX` へ集約するため申告しない |
| `instruments` | `[:loan, :deposit]` | `:advance` は既存語彙に無い（MVP `≡ 0`、`metadata` に記録） |
| `endogenous_credit` | `true` | `debt_s` は `newdebt_s` / `repay_s` により内生。**`caveats` に「借り手側のみ内生。銀行の自己資本・貸出数量制約を持たない」を必ず記載** |
| `accounting_closure` | `:partial` | `SX` を置いて閉じるため `:stock_flow_consistent` を名乗らない（§6.1） |
| `production` / `employment` | `:endogenous` / `:endogenous` | #165 §5.3・§5.5 |
| `income_distribution` | `:approximate` | `wagebill_s`・`profit_s` は会計残差。集計賃金シェアを状態変数として持たない（#166 `B6`） |
| `prices` | `:approximate` | 部門相対価格 `price_s` のみ。一般物価・インフレなし |
| `monetary_policy` | `:exogenous` | `policy_rate` は外生パス。反応関数 `X05` は `EXT` |
| `fiscal_policy` / `external_sector` | `:none` / `:none` | `tax_s ≡ 0`、政府・海外は `SX`（#166 §2.1） |
| `expectations` | `:static` | `ai_exp` は外生、計画は後ろ向き（加速度原理）。期待の内生化 `X04` は `EXT`。過大申告を避け `:adaptive` を名乗らない |
| `optimization` / `behavioral_equations` | `:none` / `true` | 個別企業の最適化問題を持たない（§4-5） |
| `equilibrium_concept` | `:none` | 既存語彙（`:bistable_with_crisis` 等）に該当するものが無い。**語彙を無断拡張せず `:none` とし、拡張の要否は #171 が判断する** |
| `data_connection` / `estimation` / `out_of_sample_validation` | `true` / `false` / `false` | 較正・検証方式は #170 が確定するまで `false` |
| `doc_ref` | `"docs/models/capex_credit_cycle_model_boundaries.md"` | 本書 |
| `caveats` | 下記 5 件 | — |

`caveats`（必須）:

1. 残差部門 `SX` を持つため会計は経済全体で閉じていない（#166 §9.2 が要求）。
2. デフォルト・信用損失を内生化していない。資金繰り診断は倒産・信用イベントの予測ではない（#166 §7）。
3. 信用の内生性は借り手側のみ。銀行の自己資本・調達コスト・貸出数量制約を持たない（#166 §12-1）。
4. 一般物価・インフレ・金融政策の内生反応を持たない。`policy_rate` は外生パスである。
5. 出力はすべて baseline 比の乖離であり、水準の絶対値は較正済みの実額を意味しない（契約 §2.4）。

### 2.7 問いの振り分け

| 問い | 送り先 | 理由 |
|---|---|---|
| 集計経済の信用拡大がいつ崩壊へ転じるか | `Keen` | 双安定性と崩壊経路を持つのは `Keen` のみ |
| ある部門の CAPEX 削減が他部門と家計へどう及ぶか | `CCC` | 部門別の受注・在庫・稼働率・信用条件を持つのは `CCC` のみ |
| 財政支出の変更が需要と家計の富へどう及ぶか | `SIM` | 政府部門と財政変数を持つのは `SIM` のみ |
| 金融政策の変更がインフレと産出ギャップへどう及ぶか | `NK` | 前向き期待と Taylor ルールを持つのは `NK` のみ |
| 観測時系列の動学的ベンチマークが欲しい | `VAR` | 理論非依存の記述を担う |
| 経済全体の資金循環が会計的に閉じるか | `SIM` / #99 Phase 5 | `CCC` は `SX` を持つため経済全体では閉じない（§6.1） |
| 企業の資金調達区分（Hedge/Speculative/Ponzi）の推移 | `Keen`（診断層） | `CCC` の `funding_pressure_s` は**別ラベル体系**であり Keen と同一視しない（#166 §7.4） |

---

## 3. 新規モデルへ含める責務

### 3.1 含める責務の一覧

| # | 責務 | 上流文書の根拠 | 実装優先度 | 限定条件 |
|---|---|---|---|---|
| I-1 | 部門別の需要・供給・受注・受注残・在庫・稼働率 | #164 ブロック B（`L09`–`L17`）・#165 §5.3 | `MVP` | 5 部門（案A）。部門追加分割は `EXT` |
| I-2 | 部門別 CAPEX（計画・実行・キャンセル・延期）と資本パイプライン | #164 ブロック A（`L02`–`L08`）・#166 §6.1 | `MVP` | 計画・実行・キャンセル・延期は同一恒等式の閉じ変数として扱う |
| I-3 | 部門別の稼働資本ストックと建設中資本、稼働開始ラグ | #165 §4.3・#166 §5.1・§5.2 | `MVP` | 納期の内生変動は持たない（#166 仮定 A-2） |
| I-4 | 企業部門の簡略化したキャッシュフロー・債務・資金調達制約 | #164 ブロック C（`L20`–`L28`）・#166 §5.4・§6.2 | `MVP` | `profit_s` は会計残差（#166 `B6`）。資金調達順序の関数形は #169 |
| I-5 | 信用条件（スプレッド・貸出態度・借換条件・資本コスト）による投資増幅 | #164 ブロック D（`L30`–`L42`）・増幅ループ `R2`・`R3` | `MVP` | `S4` は単一系列。部門別化は `EXT`。銀行の数量制約は持たない |
| I-6 | 家計の雇用・所得・消費への波及 | #164 ブロック E（`L43`–`L50`）・増幅ループ `R4` | `MVP` | 家計の金融資産・負債は持たない（`X01`・`X02` は `EXT`） |
| I-7 | 政策金利・金融環境の簡略化した外生経路 | #164 ブロック F（`L53`–`L55`）・`SH-EASING` | `MVP` | **外生パスのみ**。政策反応関数 `X05` は `EXT`（§4-8） |
| I-8 | 初期MVPに必要なストック・フロー会計制約 | #166 §8.1 の 12 検証項目 | `MVP` | `SX` を置いた**部分的**閉鎖。汎用検証 1–5 は既存層を再利用（§6.2） |
| I-9 | 診断ラベルの生成（`contained_adjustment` / `sectoral_downturn` / `broad_downturn` / `indeterminate`） | 契約 §4.2・§4.3 | `MVP` | 閾値は外部化し、感応度を必ず併記（契約 §4.4） |
| I-10 | 資金繰り圧力の診断（`funding_pressure_s` の 5 値ラベル） | #166 §7.3 | `MVP` | **読み取り専用の診断層**。モデル本体の動学に影響しない（[ADR 0003](../adr/0003-minsky-financing-regime-diagnostics.md) と同方針） |

### 3.2 含める責務に共通する限定条件

1. **すべての責務は判定問題 Q1–Q5 に必要な範囲に限る**。Q1–Q5 の判定量・`broad_downturn` の 4 指標群に現れない量を、責務の一般性を理由に追加しない。
2. **診断層はモデル本体から分離する**（I-9・I-10）。診断は結果を変更しない読み取り専用層とし、閾値・方法論バージョンを出力へ含める（[ADR 0003](../adr/0003-minsky-financing-regime-diagnostics.md)・[ADR 0007](../adr/0007-sfc-integration-contract.md) §4 と同型）。
3. **会計検証は行動方程式と独立に走る**（I-8）。検証は結果を補正せず、違反を構造化して返す（[ADR 0007](../adr/0007-sfc-integration-contract.md) 決定 §5）。
4. **外生として持つものは外生と申告する**（I-7）。`policy_rate` を外生パスとして受け取ることを、金融政策を扱えることとして申告しない（§2.6 の `monetary_policy = :exogenous`）。

---

## 4. 新規モデルへ含めない責務

### 4.1 採否の決定

Issue #167 §3 が挙げた候補 7 件に、上流 4 文書の設計から派生する候補 5 件を加えて採否を確定する。**すべて「含めない」で確定した**。

| # | 候補 | 採否 | 理由 | 代替として提供するもの | 再導入の条件 |
|---|---|---|---|---|---|
| 4-1 | Keen 型の賃金シェア・雇用率・債務比率 ODE の複製 | **含めない** | 状態空間・時間表現・集計レベルが異なる（連続時間・年・比率 vs 離散四半期・部門別水準）。複製すると同一名の 2 系統が生じ、どちらが正かを判定できない | `private_debt_credit` 軸での `proxy` 対応（§5.2）。集計的な問いは `Keen` へ送る（§2.7） | なし（複製は行わない。概念対応の精緻化のみ） |
| 4-2 | 完全な Godley-Lavoie 型制度部門 SFC | **含めない** | 政府・中央銀行・海外部門・価格体系・複数金融商品・評価損益は #99 Phase 5 の責務。判定問題 Q1–Q5 はこれらを必要としない | `SX` を置いた部分的会計閉鎖と 12 検証項目（§6.1） | #99 Phase 5 の一般 SFC 基盤が実装された後、本モデルを載せ替えるかを再評価（§6.4） |
| 4-3 | 標準 New Keynesian の価格設定・期待方程式一式（NKPC・IS・Taylor ルール） | **含めない** | 前向き合理的期待と一般物価を導入すると、`CCC` の後ろ向き行動方程式と混在し、どの機構が結果を生んだか識別できなくなる。金融政策の問いは `NK` の責務 | 部門相対価格 `price_s`（`L16`・`L17`）と外生 `policy_rate` | 期待の内生化 `X04` を導入する場合も、合理的期待ではなく適応的・外挿的形式に限る（#169 が判断） |
| 4-4 | `VAR` による統計推定ロジック | **含めない** | 構造モデルの内部に非構造推定を持ち込むと、パラメータの由来（構造 vs 統計）が混在する。[ADR 0004](../adr/0004-keen-empirical-calibration-strategy.md) の固定/推定分離と同じ規律 | #170 が定める較正・検証方式。`VAR` との比較は `ComparisonSpec` の個別宣言で行う（§5.2） | なし（推定は #170 の較正層の責務） |
| 4-5 | 個別企業の最適化問題・合理的期待均衡 | **含めない** | 契約 §6 が ABM を対象外としており、集約部門モデルは個別最適化を表現する粒度を持たない。較正できない自由度が増えるだけ（#166 §7.2 と同じ根拠） | 部門レベルの行動方程式（`behavioral_equations = true`、`optimization = :none`） | 個別企業ネットワークは #125 後段（`X03` fire-sale を含む） |
| 4-6 | 株価の価格形成モデル | **含めない** | `equity_val` は指数であり価値額でない。株式を貸借対照表へ載せない決定（#166 §3.4）と整合させる。価格形成を内生化すると評価損経路 (e) が復活し、#164 §6.1 の禁止と矛盾する | `equity_val` は**媒介変数**として保持し、資本コスト経路 (a) と担保・借換経路 (b)(c) のみを通じて実体支出へ作用させる（#166 §6.4） | 株式を貸借対照表へ計上する会計改訂が先決（#166 §3.4） |
| 4-7 | 投資判断・景気後退確率の生成 | **含めない** | 契約 §6 が投資推奨・自動売買を対象外とし、§4.1 が `recession` を出力語として禁止している。確率の一点推定は較正不能な自由度を出力に持ち込む | 診断ラベル（4 値）と閾値・パラメータ感応度（契約 §4.4） | なし（[llm_safety.md](../llm_safety.md) の禁止表現に該当） |
| 4-8 | 金融政策反応関数（Taylor ルール型の内生反応） | **含めない** | `X05` は `EXT`。Q4（遮断条件）は緩和の**規模と適用時点の 2 次元スイープ**として定義されており、反応関数を必要としない | 外生 `policy_rate` パスと `SH-EASING`（規模・遅延をシナリオで指定） | `X05` の実装は #164 の改訂を要する |
| 4-9 | 一般物価・インフレ動学 | **含めない** | すべての変数を実質・2017年連鎖ドル基準で定義済み（#165 §5.1）。名目化すると観測方程式（`GDPDEF` による実質化）と二重になる | 部門相対価格 `price_s`（index、baseline 定常値 `1.0`） | なし（実質モデルとして固定） |
| 4-10 | デフォルト・信用損失の内生化 | **含めない** | `nw_s4 ≡ 0` としたため貸倒の吸収先が定義できない。判定問題がデフォルト率を必要としない（#166 §7.2） | `funding_pressure_s` の 5 値ラベルと `liquidity_gap_s` などの診断量（#166 §7.3） | `nw_s4` の導入・`S4` の資金調達コスト・自己資本比率制約が先決（#166 §7.5） |
| 4-11 | 家計の金融資産・負債・資産効果 | **含めない** | `X01`（資産効果）・`X02`（家計信用）は `EXT`。家計の金融資産を持たないため `s5_net_sx` として `SX` へ流出する（#166 §12-2） | `hh_income` → `cons` の限界消費性向経路（`L48`）のみ | 家計の金融資産を instrument として追加する会計改訂が先決 |
| 4-12 | モデル合成・連成（`CCC` の出力を `Keen` / `NK` の入力へ渡す） | **含めない** | 概念対応に `equivalent` が 1 つも存在しない状態（§5.2）で連成すると、単位・定義の不一致が数値的に伝播して検出できなくなる | §5.5 のイベント翻訳表による**シナリオレベルの並列実行**と横断比較 | すべての受け渡し変数が `equivalent` になるまで行わない（[ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md)） |

### 4.2 除外に伴う「できないこと」

責務を除外した結果、本モデルが**答えられない問い**を明示する。LLM 説明層はこれらを問われた場合、答えを生成せず該当モデルへ送るか、範囲外である旨を返す（§5.8）。

| 答えられない問い | 理由 | 送り先 |
|---|---|---|
| 政策金利変更がインフレ・産出ギャップへ与える効果 | 一般物価・前向き期待・政策反応関数を持たない（4-3・4-8・4-9） | `NK` |
| CAPEX ショックが集計的な賃金シェア・利潤シェアへ与える効果 | `income_distribution = :approximate`。分配は会計残差であり動学を持たない（4-1） | `Keen` |
| 経済全体の資金循環が閉じるか、家計の富がどう蓄積するか | `SX` を置いた部分閉鎖。家計の金融資産を持たない（4-2・4-11） | `SIM` / #99 Phase 5 |
| 何％の企業が倒産するか、信用損失はいくらか | デフォルト非内生（4-10） | なし（本 Roadmap の範囲外） |
| 景気後退が起きる確率はいくらか | 確率の一点推定を生成しない（4-7） | なし（診断ラベルと感応度で代替） |
| 銀行の自己資本毀損による貸し渋りの効果 | 銀行の数量制約を持たない（I-5 の限定条件） | なし（#99 Phase 5 の本格 Minsky-SFC） |
| 個別企業（特定の hyperscaler・foundry）の帰結 | 集約部門モデル（4-5） | なし（契約 §6） |
| 国際波及・輸出入経路 | `X07` は `EXT`、`external_sector = :none` | `Mundell-Fleming`（ただし機構が異なる） |

---

## 5. モデル間比較契約

### 5.1 比較の 2 層

[ADR 0006](../adr/0006-cross-model-reasoning-contract.md) と [Keen–SFC 比較レポート](../analysis/keen_sfc_comparison.md) の設計を継承し、**概念対応と数値比較可否を別問題として扱う**。

| 層 | 語彙 | 問い | 判定主体 |
|---|---|---|---|
| 概念対応 | `mapping_type` ∈ {`equivalent`, `proxy`, `partial`, `incompatible`} | 両モデルが**同じ経済概念を扱っているか** | `derive_concept_mapping`（[ADR 0006](../adr/0006-cross-model-reasoning-contract.md) §3.2 の導出規則） |
| 数値比較可否 | `comparability` ∈ {`comparable`, `partial`, `insufficient`, `incompatible`} | 得られた**数値系列を並べてよいか** | `compare_results_v2`（`ComparabilityAssessment`） |

**契約**:

- `mapping_type` が `proxy` 以上でも、単位・頻度・時間軸・出力系列が揃わなければ数値比較しない。両者を混同しない。
- `mapping_type = :incompatible` ならば `comparability` は必ず `:incompatible`（`KeenSFCConceptCorrespondence` の不変条件と同型）。逆は成立しない。
- 数値比較を行わなかった場合は、必ず `reason` と `required_evidence` を残す（[Keen–SFC 比較レポート](../analysis/keen_sfc_comparison.md) §7 の 5 区分に準拠）。

### 5.2 比較可能な概念・比較不能な概念

`CROSS_MODEL_CONCEPTS`（5 軸）に対する `CCC` の `ModelConceptCoverage`（提案）†:

| 概念軸 | `treatment` | `definition_key` † | `unit` | `measure` | 主な変数 |
|---|---|---|---|---|---|
| `private_debt_credit` | `endogenous` | `:ccc_sector_debt_credit_conditions` | `"level (bn USD, 2017 chained); bp"` | `"level"` | `debt_s`・`leverage_s`・`spread`・`rollover`・`lend_stance` |
| `income_distribution` | `approximate` | `:ccc_accounting_factor_shares` | `"level (bn USD, 2017 chained)"` | `"level"` | `wagebill_s`・`profit_s`・`va_s`（いずれも会計残差） |
| `demand_and_instability` | `endogenous` | `:ccc_sectoral_capex_credit_propagation` | `"level (bn USD, 2017 chained)"` | `"level"` | `capex_exec_s1`・`order_s`・`y_s`・`cons`・`y_tot` |
| `steady_state_stability` | `approximate` | `:ccc_baseline_path` | `"level (bn USD, 2017 chained)"` | `"level"` | baseline 経路（`t = -8 … -1` で乖離ゼロ） |
| `shock_response` | `endogenous` | `:ccc_baseline_relative_deviation` | `"relative deviation; %pt; bp"` | `"deviation"` | `dY_t`・`dI_t`・`dC_t`・`peak(dx)` |

上記と既存 registry から [ADR 0006](../adr/0006-cross-model-reasoning-contract.md) §3.2 の導出規則を機械的に適用した結果:

| 概念軸 | `CCC` × `Keen` | `CCC` × `SIM` | `CCC` × `NK` | `CCC` × `VAR` |
|---|---|---|---|---|
| `private_debt_credit` | `proxy` | `incompatible` | `incompatible` | `incompatible` |
| `income_distribution` | `partial` | `incompatible` | `incompatible` | `incompatible` |
| `demand_and_instability` | `proxy` | `partial` | `partial` | `partial` |
| `steady_state_stability` | `partial` | `partial` | `partial` | `partial` |
| `shock_response` | `partial` | `proxy` | `proxy` | `partial` |

**確定事項**:

1. **`CCC` と既存 4 モデルの間に `equivalent` は 1 つも存在しない**。したがって `shared_concepts` は空であり、共通概念として並べられる系列は無い（[Keen–SFC 比較レポート](../analysis/keen_sfc_comparison.md) §2.1 と同じ状況）。
2. `CCC` × `SIM` の `shock_response` は導出規則上 `proxy` になるが、**共通のショック種別が存在しない**（`SIM` は `G`・`θ`、`CCC` は CAPEX・信用）ため `comparability = :incompatible` とする。これが §5.1 の 2 層分離を要する具体例である。
3. `CCC` × `VAR` は registry の固定 mapping を根拠にしない。`VAR` の変数定義は利用者が選ぶため、比較のたびに `VariableComparisonMapping` で `model_variable` / `data_variable` / `unit` / `transform` を明示宣言する。宣言が無い場合の既定は `insufficient`。

**比較不能の理由（欠落側による分類）**:

| 区分 | 概念 | 理由 |
|---|---|---|
| `CCC` 固有 | 部門別 CAPEX・受注残・在庫・稼働率・部門別信用条件・資金調達区分診断 | `Keen`・`SIM`・`NK`・`VAR` はいずれも部門構造と資本財の受発注を持たない |
| `Keen` 固有 | 賃金シェア `ω`・雇用率 `λ` の動学、良い均衡の閉形式、双安定性 | `CCC` は分配を会計残差としてのみ持ち、均衡の解析解を持たない |
| `SIM` 固有 | 家計金融資産・政府負債・完全な会計閉鎖・財政政策 | `CCC` は `SX` を置いており、家計の金融資産・政府部門を持たない |
| `NK` 固有 | インフレ動学・前向き期待・政策反応関数・自然利子率 | `CCC` は実質モデルで期待は外生 |
| `VAR` 固有 | 理論非依存の任意変数集合 | `CCC` の変数は構造的に固定されている |

### 5.3 同名変数の非同一視ルール

| 変数名 | 各モデルでの定義 | 扱い |
|---|---|---|
| `d` / `debt` | `Keen`: `D/Y`（集計・比率・年） / `CCC`: `debt_s`（部門別・10億ドル・四半期末） | **同一視しない**。`unit_difference = "ratio vs level (bn USD)"`、`aggregation_difference = "aggregate economy vs sector"` を必ず記録 |
| `r` | `RBC`: 実質資本限界生産物 / `IS-LM`・`AD-AS`・`MF`: 名目 / `NK`: 名目 `i` と自然実質 `r_n` / `Keen`: 外生一定の実質貸出金利 / `CCC`: `policy_rate`（外生・年率%）・`cost_capital_s`（部門別）・`r_eff_s`（実効金利） | **すべて別概念**。`CCC` 内部でも 3 変数を区別する |
| `Y` | `Keen`: 集計産出（実質水準） / `SIM`: 賃金単位の産出 / `NK`: 産出ギャップ `x`（対数偏差） / `CCC`: `y_tot`（付加価値の和、10億ドル） | **同一視しない**。`measure` が level / level / deviation / level と異なる |
| `I` / 投資 | `Keen`: `κ(π)/ν` に含まれる（独立変数として出力しない） / `CCC`: `capex_exec_s1`・`invest_s`（部門別・発注ベース） | **同一視しない**。`Keen` は独立系列として持たない |
| `C` / 消費 | `SIM`: `C`（賃金単位） / `CCC`: `cons`（10億ドル、`S1` 向け `cons_s1` は `B4` 解決まで `≡ 0`） | `partial` 止まり。単位・決定機構が異なる |
| Hedge / Speculative / Ponzi | `Keen`: 診断層のラベル（集計・元本返済代理仮定あり） / `CCC`: `funding_pressure_s` の 5 値（`fp_unlevered` / `fp_covered` / `fp_rollover_dependent` / `fp_interest_uncovered` / `fp_invalid`） | **ラベル名を流用しない。同一図に重ねない**。比較時は `insufficient_comparability` を明示（#166 §7.4） |
| 会計恒等式の検証結果 | `SIM`: 経済全体で閉じる / `CCC`: `SX` を置いて閉じる | **「SFC 検証済み」と同じ意味で述べない**。`CCC` の検証は部分的閉鎖のもとでの整合性である（§6.1） |

**契約（分析契約 §3 Q2 からの差し戻し事項の確定）**: 契約 §3 Q2 の信用増幅度 `A = |peak(dI^{full})| / |peak(dI^{credit-off})|` は、**同一実装内で信用条件感応パラメータを `0` に固定した反実仮想としてのみ定義する**。信用チャネルを持たない別モデル（`NK` 等）との IRF 差で代用しない。理由は、`NK` の産出ギャップ IRF が対数偏差・集計・前向き期待付きであり、`CCC` の `dI` と `measure`・`aggregation`・期待形成のすべてが異なるためである。

### 5.4 単位・表現差の明示規約

| 差の種別 | `CCC` の値 | 記録先 | 比較時の扱い |
|---|---|---|---|
| 単位 | 10億ドル（2017年連鎖ドル）・比率・年率%・bp・百万人 | `VariableComparisonMapping.unit`、`ModelConceptCoverage.unit` | 明示 `transform` が無ければ `comparability` を降格し `required_transforms` を返す |
| 表現 | 水準（内部）と baseline 比乖離（判定・出力） | `measure`（`"level"` / `"deviation"`） | 対数偏差モデル（`NK`・`RBC`）との比較は `measure` 不一致として降格 |
| 頻度 | 四半期 | `frequency`（`"quarterly"`） | `Keen`（年・連続時間）との比較は `frequency_difference` を必ず記録 |
| 集計 | 部門別（`_s1`–`_s5`）・全部門合計（`_tot`）・加重平均（`_agg`） | `aggregation` / `aggregation_difference` | 集計モデルとの比較は `_tot` / `_agg` のみを候補とし、部門別系列を直接対応づけない |
| 時点 | ストックは期末 `EOP`、フローは四半期合計 `SUM`、レートは `AVG` | `ModelConceptDefinition.timing` | `timing` 不一致は `equivalent` の要件を満たさない |
| 型 | `stock` / `flow` / `rate` / `ratio` / `index` | `kind` | `kind` が異なれば `:incompatible` として数値比較しない（`src/core/compare_v2.jl` の契約） |

**契約**: `CCC` は内部を水準で保持し、判定・診断・比較はすべて baseline 比乖離 `dx_t` で行う（契約 §2.4）。比較層が生成する乖離系列には予約接頭辞 `d_` を用い、モデルはこの接頭辞を使わない（#165 §6.4）。

### 5.5 同一イベントのモデル間翻訳

契約 §5.3 のショック定義を各モデルへ翻訳できるかを固定する。`○` = 翻訳可（単位変換を明示）、`△` = 部分翻訳可（情報が失われる）、`×` = 翻訳不能。

| イベント | `CCC` での適用先 | `Keen` | `SIM` | `NK` | `VAR` |
|---|---|---|---|---|---|
| `SH-EXP`（期待需要 `-10%`、AR1 半減期6Q） | `ai_exp`（外生） | `×` 期待変数を持たない | `×` 期待変数を持たない | `△` 需要ショック `:demand` へ縮約（部門情報と持続形状が失われる） | `△` 利用者が対応変数を宣言した場合のみ |
| `SH-CAPEX`（計画CAPEX `-15%`、8Q） | `capex_plan_shock_ex`（外生） | `×` 投資関数 `κ(π)` に外生シフト項が無い | `×` 投資を持たない | `△` 需要ショックへ縮約 | `△` 同上 |
| `SH-CREDIT`（スプレッド `+150bp`） | `spread_shock_ex`（外生） | `△` `r` の水準変更として**別モデル実行の比較静学**にしかならない（`r` はパラメータであり時間経路を持たない）。良い均衡の `d̄` は `r` に依存しないため、`d` への効果は生じない | `×` 信用を持たない | `×` `NK` の `i` は政策金利であってスプレッドではない | `△` 利用者宣言時のみ |
| `SH-EASING`（政策金利 `-100bp`、t=2 適用） | `policy_rate`（外生パス） | `△` `SH-CREDIT` と同じ制約 | `×` 金融政策を持たない | `○` 金融政策ショック `:monetary` へ翻訳可。ただし `NK` は名目・前向き期待付き、`CCC` は実質・期待なし（`proxy`） | `△` 利用者宣言時のみ |
| 財政ショック（`SIM` の `G`・`θ`） | `×` | `×` | `○`（`SIM` 固有） | `×` | `△` |
| 技術ショック（`RBC` の TFP） | `×` | `×` | `×` | `×` | `△` |

**翻訳の責務分担**:

| 責務 | 担当 |
|---|---|
| 翻訳可否の判定表（本表） | 本書（#167） |
| イベント型・翻訳器の Julia API・単位変換の実装 | #168 |
| 翻訳後のショック規模の較正（`-10%` が `NK` の何単位に相当するか） | #170 |
| 翻訳結果を LLM 説明へ載せる際の必須記載 | #171（§5.8） |

### 5.6 翻訳不能なイベントの規則

1. **`×` のイベントを当該モデルへ適用しない**。近似・代理・スケーリングによる適用を行わない。
2. **`×` を「そのモデルでは影響が無い」と解釈しない**。翻訳不能はモデルの構造上その事象を表現できないことを意味し、現実に影響が無いことを意味しない（[llm_safety.md](../llm_safety.md) の必須記載に該当）。
3. **`△` の翻訳結果を `○` と同じ確度で提示しない**。失われた情報（部門構造・持続形状・期待形成）を必ず併記する。
4. **翻訳不能なイベントを含む比較で、モデル間の優劣を述べない**。一つのモデルで効果が出ず他方で出たことを、後者の正しさの証明としない（[ADR 0006](../adr/0006-cross-model-reasoning-contract.md) 決定 §6）。
5. **翻訳不能を出力から省略しない**。`untranslatable` として理由・欠落機構・必要な追加証拠を構造化して返す（#168 が実装）。

### 5.7 `SimulationResult` を共通コンテナとする方式

**決定: `SimulationResult` 型を変更しない。methodology 相当の情報は `metadata::Dict{String,Any}` の予約キーで保持する。**

`src/core/simulation_result.jl` の `SimulationResult` は `model_name` / `scenario_name` / `variables::Dict{String,Vector{Float64}}` / `metadata::Dict{String,Any}` の 4 フィールドで、`methodology` フィールドを持たない。既存 8 モデル以上がこの型に依存しており、フィールド追加は破壊的変更になる。

| 情報 | 置き場 | 根拠 |
|---|---|---|
| 水準系列・診断系列 | `SimulationResult.variables`（平坦キー + 部門接尾辞） | #165 §6.5 |
| モデルパラメータ | `metadata["parameters"]`（既存 adapter 慣習） | [ADR 0007](../adr/0007-sfc-integration-contract.md) §6 |
| 変数の役割・部門・単位 | `metadata["variable_roles"]` / `["variable_sectors"]` / `["variable_units"]` | #165 §6.5 |
| 契約バージョン | `metadata["contract_version"]` / `["graph_version"]` / `["vars_version"]` / `["accounting_version"]` / `["boundaries_version"]` † | 本書 |
| シナリオ・ショック定義 | `metadata["scenario"]`（`target` / `meaning` / `unit` / `sign` / `timing` / `shape` / `duration` の 7 項目） | 契約 §5.2 |
| 診断閾値セット | `metadata["diagnostic_threshold_set"]`（識別子とバージョン） | 契約 §4.3 |
| 会計表・検証結果 | `SFCResult`（別型。`simulation_result` フィールドで `SimulationResult` を参照） | [ADR 0007](../adr/0007-sfc-integration-contract.md) 決定 §6・#166 §9.1 |

**契約**:

- `variables` に載せるのは `Vector{Float64}` で表せる系列のみ。部門・金融商品の構造は `SFCResult` 側に置き、平坦 Dict へ潰さない。
- `metadata` の予約キーは **`CCC` 専用の新型を作らずに**モデル差を保持するための手段であり、他モデルへ同じキーを要求しない。
- 比較層は `metadata` のバージョンキーを読み、契約バージョンが異なる結果同士の比較では `provenance` にその差を記録する。

### 5.8 cross-model registry への登録要件

#171 が `CCC` を registry へ登録する際の必須要件:

1. `_XM_MODEL_LABELS` へ `:capex_credit_cycle => "部門別CAPEX・信用循環モデル"` を追加する。
2. `MODEL_CONCEPT_REGISTRY` へ §5.2 の 5 行を追加する。`caveats` に §2.6 の 5 件を含める。
3. `MODEL_CAPABILITY_REGISTRY` と `_CAPABILITY_MODEL_SYMBOLS` へ §2.6 のプロファイルを追加する。
4. `MODEL_CONCEPT_DEFINITION_REGISTRY` へ主要変数の `ModelConceptDefinition` を追加する。`concept_id` は `ccc_` 接頭辞でグローバル一意にし、`Keen` の `keen_debt_ratio_d` と `debt_s` が別 `definition_key` になることを保証する。
5. `docs/model_capabilities.md` §3 の比較表と `docs/model_selection_guide.md` へ行を追加する（`docs/model_capabilities.md` §5 の追加手順 6）。
6. LLM 説明層は §2.6 の `caveats` 5 件と §4.2 の「答えられない問い」表を必ず参照可能な形で保持する。

---

## 6. SFC との重複整理

### 6.1 #166 の限定的会計整合性と一般 SFC フレームワークの境界

| 観点 | #166 の限定的会計整合性（`CCC`） | 一般 SFC フレームワーク（`SIM` / #99 Phase 5） |
|---|---|---|
| 目的 | 行動方程式が満たすべき制約の集合を先に固定し、CAPEX 削減で消えた支出の行き先を追跡可能にする | 「すべての金融資産は誰かの負債」が**経済全体で**成立することを検証する |
| 部門 | `S1`–`S5` + 残差部門 `SX`（6 列） | 制度部門（家計・政府・生産、将来は中央銀行・海外部門） |
| 閉鎖 | **部分的**。`SX` 列の列和は定義上ゼロで検証対象にしない | **完全**。残差部門を置かない |
| `accounting_closure` | `:partial` | `:stock_flow_consistent` |
| 金融商品 | 預金・貸出・前受金（MVP `≡ 0`）・モデル外調達（4） | `SIM` は政府貨幣 `H` のみ。将来は複数金融商品・評価損益 |
| 実物資産 | 稼働資本・建設中資本・在庫（3） | `SIM` は持たない |
| 検証項目 | 12 件（汎用 5 + モデル固有 7） | 汎用 5 件 |
| 価格体系 | 部門相対価格 `price_s` のみ | 一般的な価格体系（#99 Phase 5） |
| 登録簿 | `S1`–`S5`・`SX`、`:deposit` / `:loan` / `:advance` / `:extfund` | `SIM` の登録簿と**共有しない**（#166 §9.1） |

**確定事項**: `CCC` は SFC を名乗らない。`accounting_closure = :partial` を申告し、LLM 説明層は「経済全体で閉じた SFC ではない」ことを必ず明示する（§2.6 `caveats` 1）。「会計恒等式を検証している」ことと「SFC である」ことを同一視しない。

### 6.2 会計表を将来 SFC モデルへ再利用可能な形にするか

**決定: プリミティブ層は既存 `src/sfc/` を再利用し、登録簿とモデル固有恒等式は共有しない。`CCC` の会計表を一般 SFC 用に汎化することは行わない。**

| 層 | 扱い | 理由 |
|---|---|---|
| 会計プリミティブ（`SFCSector` / `SFCInstrument` / `BalanceSheetMatrix` / `TransactionFlowMatrix` / `SFCPeriodSnapshot` / `SFCResult`） | **再利用する。新設しない** | 型は部門・金融商品に非依存。`CCC` 専用型を作ると SFC 側と二系統になる |
| 汎用検証（#166 §8.1 の 1–5） | **再利用する**（`src/analysis/sfc_accounting.jl`） | 恒等式が部門構成に依存しない |
| 符号規約・時点規約・許容誤差・`NaN` 処理 | **[ADR 0007](../adr/0007-sfc-integration-contract.md) から継承する。`CCC` 専用規約を作らない** | 規約が分岐すると比較時に残差の意味が揃わない |
| 登録簿（`S1`–`S5`・`SX`、instrument 4 種） | **共有しない** | 部門定義が `SIM` と根本的に異なる（§5.3）。共有すると同名部門の非同一視契約に反する |
| モデル固有恒等式（#166 §8.1 の 6–12） | **`CCC` 固有の読み取り専用検証層として実装する** | `:capex_funding` / `:no_double_count` などは `CCC` の部門・変数に強く依存 |

### 6.3 一般 SFC 基盤先行 vs 部門モデル内限定実装

| 案 | 内容 | 利点 | 欠点 | 採否 |
|---|---|---|---|---|
| 案 I | #99 Phase 5 の一般 SFC 基盤を先に実装し、`CCC` をその上に載せる | 会計層が 1 つに統一される。将来の制度部門拡張が自然 | #125 が #99 Phase 5 の完了に依存し、判定問題 Q1–Q5 への到達が大幅に遅れる。一般基盤の要件を `CCC` の都合で歪める危険 | **不採用** |
| 案 II | `CCC` 内に会計表・検証を完全に自前実装する | #99 に依存せず進められる | `src/sfc/` と重複した型・検証が二系統になる。[ADR 0007](../adr/0007-sfc-integration-contract.md) の規約と分岐しうる。#167 が禁じる「既存モデルの理論・API の無断複製」に該当 | **不採用** |
| 案 III | 既存プリミティブと汎用検証を再利用し、モデル固有恒等式のみ `CCC` 側に追加する | #99 に依存せず進められる。型・規約は一系統。将来 #99 Phase 5 が一般基盤を作った際、`CCC` 側は登録簿と固有検証を残したまま載せ替えられる | 部分閉鎖（`SX`）のため SFC の検証力を完全には得られない。汎用検証の変更が `CCC` へ波及しうる | **採用** |

**採用理由**: 案 III は #166 §9.1 が既に選択した方針であり、本書はそれを責務境界として追認する。案 I の「一般基盤の要件を `CCC` の都合で歪める危険」は具体的で、`SX`（残差部門）という `CCC` 固有の設計を一般 SFC の要件に持ち込むと、経済全体で閉じるという SFC の中心的性質が緩む。

### 6.4 #99 Phase 5 へ移すべき共通機能

#166 §8.1 の 12 検証項目のうち、部門構成に依存せず一般化できるものを移管候補として登録する。**本書は移管を決定せず、候補として #99 Phase 5 へ引き渡す。**

| 検証項目 | 一般性 | 移管 |
|---|---|---|
| `:balance_row_sum` / `:balance_column_sum` / `:flow_row_sum` / `:flow_column_sum` / `:stock_flow` | 部門非依存 | 既に #99 Phase 5 系（`src/analysis/sfc_accounting.jl`）。**移管済み** |
| `:nlb_consistency`（経常・資本ブロック列和 = −金融ブロック列和 = `nlb_s`） | 部門非依存。取引フロー行列をブロック分割する任意の SFC モデルで成立 | **移管候補** |
| `:net_worth_update`（純資産更新式の左右一致） | 部門非依存。資産・負債・評価差額を持つ任意の部門で成立 | **移管候補** |
| `:s4_balance_sheet`（`loans_s4 = Σ debt_s` かつ `dep_s4 = Σ cash_s`） | 「金融部門の資産＝他部門の負債」の一般形として汎化しうる | **移管候補**（汎化が必要） |
| `:output_income_split`（`va_s = wagebill_s + dep_s + profit_s`） | 生産部門を持つモデルに一般的だが、`SIM` は利潤ゼロで自明 | 移管しない（`CCC` 固有層） |
| `:capex_funding` / `:aggregate_output` / `:no_double_count` | `CCC` の部門・変数・集計規約（R-1・R-3・R-4）に依存 | 移管しない（`CCC` 固有層） |

加えて、**残差部門を持つ会計表の扱い**（部分閉鎖のもとでの検証、残差の規模監視、`acc_warning` の閾値）は `CCC` 固有の設計として始まるが、将来 `SX` 型の部分閉鎖を持つモデルが複数現れた場合は共通機能として抽出しうる。#99 Phase 5 への引き渡し事項として登録する。

---

## 7. 独立モデルとする判断

詳細な決定記録は [ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md) に置く。本節は要点のみを示す。

| 論点 | 判断 |
|---|---|
| 新規独立モデルとするか | **する**。既存 4 モデルのいずれも部門別 CAPEX・受注残・在庫・稼働率と部門別信用条件を同時に持たず、判定問題 Q1–Q5 に答えられない（§2.7） |
| `Keen` 拡張として実装しないのはなぜか | 状態空間（3 変数比率 vs 約 16 の部門別水準）・時間表現（連続時間 ODE・年 vs 離散四半期）・集計レベル（集計経済 vs 5 部門）が異なる。拡張すると `Keen` の閉形式定常状態・双安定性・診断層・実証層（`calibrate_keen` / `validate_keen`）・LLM 説明契約（[ADR 0005](../adr/0005-keen-ai-explanation-contract.md)）がすべて `ω`・`λ`・`d` に依存しているため成立しなくなる |
| 初期MVPの会計整合性の範囲 | `SX` を置いた**部分的**閉鎖。汎用検証 5 + モデル固有 7 の 12 項目（§6.1） |
| 横断比較で保証するもの | 概念対応の明示（`mapping_type`）・数値比較可否の判定（`comparability`）・単位/頻度/集計差の記録・翻訳不能の構造化 |
| 横断比較で保証しないもの | 同名変数の同一性・統一パラメータ推定・ensemble 予測・モデル平均・単一ランキング |
| モデル合成・連成を Phase 0 で行わない理由 | 概念対応に `equivalent` が 1 つも無い状態（§5.2）で出力を受け渡すと、単位・定義の不一致が数値的に伝播して検出できなくなる（§4-12） |

---

## 8. 上流ドキュメントへの差し戻し事項

本書の作成過程で、上流文書および既存 docs に**本書だけでは解決できない不整合・欠落**を 3 件検出した。#165 §1.2 と同じ手続きに従い、本書では責務境界上の暫定確定を行い、正式な改訂は当該文書で行う。

| ID | 対象 | 内容 | 本書での暫定扱い | 影響する Issue |
|---|---|---|---|---|
| `C1` | `docs/architecture/model_interface.md` §2 | 実装モデルの列挙に `KeenModel` と `SIMModel` が含まれていない（いずれも実装済みで `AbstractMacroModel` を継承している）。`CCC` を追加する際、この列挙が正であるかを判断できない | 本書 §2.1 の横断比較表を `CCC` 追加時の参照とする。`model_interface.md` の列挙は #171 が更新する | #171 |
| `C2` | `docs/model_selection_guide.md` §1–§4 | `SIM`（SFC）が早見表・決定木・比較表・個別節のいずれにも収載されていない（`docs/model_capabilities.md` §3 には収載済み）。`CCC` を追加すると欠落が 2 件になる | 本書 §2.7 に問いの振り分け表を置き、暫定の選択指針とする。選択ガイドへの `SIM`・`CCC` 追加は #171 が行う | #171 |
| `C3` | `src/core/model_capabilities.jl` `CAPABILITY_EQUILIBRIUM_CONCEPTS` | `CCC` の均衡概念（外生 baseline 経路 + 非線形閾値による経路分岐）に対応する語彙が既存 8 値に無い | `equilibrium_concept = :none` を申告し、語彙を無断拡張しない（§2.6）。語彙追加の要否は #171 が判断する | #171 |

**契約**: `C1`・`C2` は docs の更新であり `CCC` の設計に影響しない。`C3` は registry 登録時に判断が必要であり、**#171 は `C3` の判断を行わずに `equilibrium_concept` へ新語彙を追加してはならない**。#168・#169・#170 は本書の責務境界を前提に着手してよい。

---

## 9. 後続 Issue への引き渡し

| Issue | 本書から受け取るもの |
|---|---|
| #168 イベント変換 | §5.5 の翻訳可否表（`○`/`△`/`×` の判定は本書が固定し、#168 は実装のみ）・§5.6 の翻訳不能時の規則 5 項目・`untranslatable` の返却要件・§5.4 の単位/表現/頻度/集計/時点/型の記録項目 |
| #169 動学方程式 | §3.1 の含める責務 10 件と限定条件・§4.1 の含めない責務 12 件（**これらを方程式として実装しない**）・§3.2-2 の診断層分離・§3.2-3 の会計検証の独立性 |
| #170 観測・検証 | §2.6 の `estimation` / `out_of_sample_validation` を `false` としている判断の再評価・§5.5 の翻訳後ショック規模の較正・§4-4 の統計推定を本体へ持ち込まない規律 |
| #171 統合 | §2.6 の `ModelCapabilityProfile`（提案）・§5.2 の `ModelConceptCoverage` 5 行（提案）・§5.7 の `metadata` 予約キー・§5.8 の registry 登録要件 6 項目・§8 の `C1`–`C3` |
| #99 Phase 5 | §6.4 の移管候補（`:nlb_consistency`・`:net_worth_update`・`:s4_balance_sheet` の汎化）・残差部門を持つ会計表の扱いの共通化可能性・§6.3 案 III が前提とする載せ替え経路 |

**LLM 説明層への必須記載事項**（[llm_safety.md](../llm_safety.md) の必須記載と併せて適用）

1. `CCC` の結果を他モデルと並べる場合、**`equivalent` な概念が 1 つも無いこと**（§5.2）を明示し、共通概念として扱わない。
2. 翻訳不能なイベント（§5.5 の `×`）について、**「そのモデルでは影響が無い」と述べない**。構造上表現できないことを述べる。
3. `CCC` の会計検証結果を「SFC 検証済み」と同じ意味で述べない（§6.1）。
4. §4.2 の「答えられない問い」に該当する質問には、モデル出力から答えを生成せず、範囲外である旨と送り先モデルを返す。
5. `funding_pressure_s` を Keen の Hedge/Speculative/Ponzi と同一視・同一図表示しない（§5.3）。

---

## 10. 限界

1. **本書は責務の宣言であって検証ではない**。§2.6 の能力プロファイルは上流 4 文書の設計に基づく申告であり、実装が実際にその能力を持つことは #171 の実装と #170 の検証を経て初めて確認される。
2. **比較契約は概念レベルに留まる**。§5.2 の `mapping_type` は [ADR 0006](../adr/0006-cross-model-reasoning-contract.md) の導出規則を機械的に適用した結果であり、経済学的な妥当性の判断ではない。実際に数値比較が有意味かは §5.1 の第 2 層（`comparability`）と #170 の検証に依存する。
3. **`equivalent` が 1 つも無いことは、比較が無価値であることを意味しない**。`proxy`・`partial` の対応は、機構の差を明示したうえでの定性的比較には使える。ただし数値の直接比較・優劣判断には使えない。
4. **§5.5 の翻訳可否は現行実装に対する判定である**。既存モデルが将来拡張されれば（例: `Keen` に外生投資シフト項が加わる）判定は変わる。本書の改訂を要する。
5. **`accounting_closure = :partial` の検証力は `SX` の規模に依存する**。`SX` へ流れる項目が大きいほど会計検証の検出力は下がる（#166 §12-3）。責務境界としては `:partial` で正しいが、それが十分な整合性を意味するとは限らない。
6. **含めない責務の一部は将来の再導入余地を持つ**（4-3・4-8・4-10・4-11）。本書はそれらを `EXT` として境界のみ保持しており、再導入時に本書と上流文書の双方の改訂が必要になる。
7. **責務分担は「どのモデルへ送るか」を示すが、答えの整合性を保証しない**。§2.7 で `Keen` へ送った問いの答えと `CCC` の答えが整合することは、モデル間に `equivalent` 概念が無い以上、保証されない。
8. **本書は実装・実データによる検証を経ていない**。§2.6 のプロファイル値、特に `endogenous_credit = true` と `production` / `employment` の `:endogenous` 申告は、#169 の方程式が確定するまで暫定である。

LLM による説明生成時は、上記を [llm_safety.md](../llm_safety.md) の必須記載事項と併せて提示する。

---

## 11. 対象外

[Issue #167](https://github.com/Yuki-Watanabe7/DME/issues/167) の対象外に加え、本書で明示する。

| 対象外 | 扱い |
|---|---|
| 既存モデル（`Keen` / `SIM` / `NK` / `VAR`）のコード変更 | 行わない（§1.2-1） |
| モデル連成・合成エンジンの実装 | 行わない（§4-12・[ADR 0009](../adr/0009-capex-credit-cycle-model-responsibilities.md)） |
| 共通イベント API の本実装 | #168（本書は翻訳可否表のみ固定） |
| registry コード（`MODEL_CONCEPT_REGISTRY`・`MODEL_CAPABILITY_REGISTRY` 等）の追記 | #171（本書は提案値のみ固定） |
| 各モデルの実データ較正・翻訳後ショック規模の較正 | #170 |
| 行動方程式の関数形・パラメータ値 | #169 |
| `SimulationResult` 型の変更 | 行わない（§5.7） |
| 一般 SFC 基盤の設計・実装 | #99 Phase 5（§6.3 案 III） |
| `docs/architecture/model_interface.md`・`docs/model_selection_guide.md` の更新 | #171（§8 の `C1`・`C2`） |
| `CAPABILITY_EQUILIBRIUM_CONCEPTS` の語彙拡張 | #171（§8 の `C3`） |

---

## 12. 改訂履歴

| version | 日付 | 変更 |
|---|---|---|
| `capex-credit-cycle-boundaries/1.0.0` | 2026-07-29 | 初版（#167）。5 モデル横断比較表（回答する問い・主要状態・強み・限界）・新規モデルへ含める責務 10 件と限定条件・含めない責務 12 件の採否と「できないこと」・概念対応と数値比較可否の 2 層分離・`ModelConceptCoverage` 5 行と `ModelCapabilityProfile`（提案）・`equivalent` が 1 つも存在しないことの確定・同名変数の非同一視表・Q2 増幅度を同一実装内反実仮想に限定する確定・イベント翻訳可否表と翻訳不能時の規則・`SimulationResult` を変更せず `metadata` 予約キーで methodology 相当を保持する決定・registry 登録要件・#166 の限定的会計整合性と一般 SFC の境界・会計層の再利用方針（案 III 採用）・#99 Phase 5 への移管候補・差し戻し事項 `C1`–`C3` を固定 |
