# ADR 0007: SFC 統合は会計恒等式をモデル方程式と分離した検証契約とし、SFCResult を別型で保持して adapter 接続する

- **ステータス**: 採用
- **日付**: 2026-07-24
- **関連Issue**: #99（ロードマップ）・#145（本決定・設計）・後続 #146 以降（実装）
- **前提ADR**: [ADR 0002](0002-minsky-integration-design.md)（既存インターフェース準拠・自前ソルバー・LLM 層無拡張の統合方針）・[ADR 0006](0006-cross-model-reasoning-contract.md)（概念対応の明示・同名変数の非同一視・比較不能の非統合）
- **関連ドキュメント**: [SFC 統合設計 — 最小 SIM 型モデル](../models/sfc_integration_design.md)・[Minsky系金融不安定性モデル 設計方針](../models/minsky_design.md)・[出力結果の読み方](../simulation_outputs.md)・[モデル共通インターフェース](../architecture/model_interface.md)

## コンテキスト

DME には解析的マクロモデル群（Ramsey / Solow / RBC / IS-LM / AD-AS / New Keynesian /
Mundell-Fleming / VAR）と Minsky 系 Keen モデル、および Keen 実証層がある。Keen は所得分配と
民間債務比率の動学を扱うが、部門別の貸借対照表と取引フローが会計的に閉じている
（stock-flow consistent）ことを明示的な検証対象としていない。

Issue #145 は DME へ **Stock-Flow Consistent（SFC）基盤** を導入し、最小モデル・会計表現・検証責務・
既存 API との接続方針を確定することを求める。SFC の核心は「すべての金融資産は誰かの負債」
「各部門の予算制約が閉じる」「ストック変化＝取引フロー＋評価損益」という会計恒等式を、
**モデルの行動方程式とは独立した検証契約**として持つことにある。これを平坦な `SimulationResult`
（`variables::Dict{String,Vector{Float64}}`）だけで表すと、部門・金融商品の構造と会計恒等式が
失われ、不整合を検出できない。

既存アーキテクチャは (1) `AbstractMacroModel` の平坦な interface、(2) 水準系列を保持する
`SimulationResult`、(3) 可視化・`compare_with_data`・LLM 説明層、(4) ADR 0006 の概念 registry を持つ。
本 ADR はこれらを破壊せずに SFC 固有の構造（sector・instrument・行列・会計検証）を別結果型で保持し、
後続実装が追加の設計判断なしに型・行列表現・検証契約・adapter・registry 追加・テスト分割を実装できる
ようにする。最小モデルの方程式・部門・行列の詳細は
[SFC 統合設計](../models/sfc_integration_design.md) に置く。

## 決定

1. **初版 SFC は SIM 型モデルとする。** 家計・政府・生産部門からなる閉鎖経済、金融資産は政府貨幣 `H`
   のみ、政策変数は政府支出 `G` と税率 `θ`（Godley-Lavoie *Monetary Economics* 第3章）。銀行貸出・
   企業債務・中央銀行・複数金融商品・価格評価益は非対象とし、型・行列表現に責務境界だけを残す（§11）。
2. **sector・instrument・stock・flow は安定 ID（`Symbol`）と表示名（`String`）を分離する。** ID は
   計算・検証・JSON の安定キー、表示名は人間可読・LLM 説明用。ID を表示名に依存させない。
3. **行列方向・符号・時点を固定する。** 貸借対照表行列は行 = instrument・列 = sector・資産正/負債負・
   期末ストック。取引フロー行列は行 = 取引・列 = sector・源泉正/使途負（Godley-Lavoie 規約）・期中フロー。
4. **会計恒等式をモデル方程式とは別の検証契約として定義する。** `stock_t − stock_{t-1} =
   transaction_flow_t + valuation_change_t` を検証し、MVP では `valuation_change ≡ 0` を
   **独立項として明示保持**する（将来の複数金融商品・価格変動で値を入れるだけで拡張可能）。
5. **不整合を自動補正で隠さず、違反を構造化して返す。** 丸め・クリップ・辻褄合わせをせず、各検証を
   `AccountingCheck`（残差・許容誤差・合否・理由）として返す。絶対＋相対許容誤差で判定し、
   `NaN`/欠損/発散は例外にせず invalid 期として構造化記録する。
6. **SFC 固有情報は `SFCResult` に分離し、水準系列は `SimulationResult` に載せる。** 責務境界を型で
   固定し、`SimulationResult` を消費して `SFCResult` を返す adapter で接続する（Minsky 診断層と同じ idiom）。
7. **既存 `compare_with_data` を直ちに破壊せず、比較 API v2 は加算的に導入する。** SFC は水準系列を出す
   ため既存比較にそのまま乗る。部門別ストック/フロー・会計残差を意識した比較は後方互換の v2 で追加する。
8. **cross-model 概念 registry（ADR 0006）へ `:sim` を追加登録する。** 同名変数の定義差を `caveats` に
   明示し、ADR 0006 の非同一視・比較不能の非統合方針を継承する。
9. **本格 Minsky-SFC（銀行・企業信用を含む）を次期 Roadmap 候補として明示する。**

## 1. スコープと非対象範囲

| 区分 | 内容 |
|---|---|
| **MVP 対象** | 家計・政府・生産部門の閉鎖経済。金融資産＝政府貨幣 `H` のみ。政策変数＝ `G`・`θ`。会計恒等式の検証契約。既存 interface・`SimulationResult`・可視化・LLM 層との接続。 |
| **MVP 非対象（将来拡張・§11）** | 銀行貸出、企業債務、中央銀行、複数金融商品（債券・株式）、価格評価益（valuation gains）、開放経済、危機 regime の内生化。 |

非対象は「型・行列で表現可能だが値は空/ゼロ」として責務境界だけ残す。これにより本格 Minsky-SFC への
拡張時に既存契約（型・符号・検証）を破壊しない。最小 SIM モデルの方程式・定常状態・雇用式は
[SFC 統合設計 §2](../models/sfc_integration_design.md#2-sim-型モデルの方程式)。

## 2. 安定 ID と表示名の分離

sector・instrument・stock・flow（取引種別）はそれぞれ ID（`Symbol`）と表示名（`String`）を分離する。

| 概念 | ID 例 | 表示名 例 | 役割 |
|---|---|---|---|
| sector | `:households` / `:production` / `:government` | 家計 / 生産 / 政府 | 列キー・予算制約の単位 |
| instrument | `:money` | 政府貨幣 `H` | 貸借対照表の行キー・資産負債対応の単位 |
| transaction | `:consumption` / `:wages` / `:taxes` / `:govt_expenditure` / `:money_change` | 消費 / 賃金 / 税 / 政府支出 / 貨幣変動 | 取引フローの行キー |
| stock/flow 変数 | `:H` / `:Y` / `:C` / `:T` / `:YD` | — | 系列キー |

ID は計算・検証・JSON・cross-model registry の安定キーであり、表示名変更や翻訳で壊れない。表示名は
人間可読・LLM 説明のみに使う。ID → 表示名は `SectorDef` / `InstrumentDef`（`id`, `label`）で保持する。

## 3. 行列方向・符号規約・時点

| 行列 | 行 | 列 | 符号 | 時点 |
|---|---|---|---|---|
| 貸借対照表行列（balance sheet） | instrument | sector | 資産 `+` / 負債 `−` | 期末ストック（期 `t` 末） |
| 取引フロー行列（transaction-flow） | 取引種別 | sector | 源泉(source) `+` / 使途(use) `−` | 期中フロー（期 `t`） |

- 貸借対照表には**純資産（balance）行**を持ち、各 sector 列の資産合計の符号反転を入れて列和 = 0 とする。
- 取引フローの「貨幣変動」行は、家計（資産増＝使途 `−ΔH_h`）と政府（負債増＝源泉 `+ΔH_g`）で符号が逆。
- `H_{t-1}` は期首（前期末）ストック。フローとストックの時点整合は §4 の恒等式で結ぶ。

SIM の具体的な行列（数値埋め）は [SFC 統合設計 §3](../models/sfc_integration_design.md#3-部門金融資産行列表現)。

## 4. 会計恒等式（モデル方程式と別の検証契約）

行動方程式（消費関数・産出決定）が解を出した後、それとは独立に次の恒等式群を検証する。検証は結果を
**変更しない**（読み取り専用）。

| 検証名 (`Symbol`) | 恒等式 | 意味 |
|---|---|---|
| `:balance_row_sum` | 各 instrument 行の Σ(sector) = 0 | すべての金融資産は誰かの負債（資産負債対応） |
| `:balance_column_sum` | 各 sector 列の Σ(instrument, 純資産込み) = 0 | 貸借対照表が閉じる |
| `:flow_row_sum` | 各取引行の Σ(sector) = 0 | すべてのフローに相手方がいる |
| `:flow_column_sum` | 各 sector 列の Σ(取引) = 0 | 部門予算制約（源泉＝使途） |
| `:stock_flow` | `stock_t − stock_{t-1} = transaction_flow_t + valuation_change_t` | ストック変化とフローの整合 |

`:stock_flow` の `valuation_change_t` は MVP では恒等的に 0（単一・額面固定資産）だが、恒等式の**独立項**
として保持し 0 を明示する。これにより将来の価格変動資産導入時に、恒等式・型・検証コードを変えずに
`valuation_change` に値を入れるだけで拡張できる。

検証範囲は上記 5 種を必須とし、各期・各行/列/部門/instrument に対して実行する。行動方程式の再定式化
（消費関数の形・税制）は検証契約の対象外（それはモデルの仕様であって会計恒等式ではない）。

## 5. 許容誤差・異常値・違反の返し方

### 5.1 許容誤差

残差 `r` の合否は絶対＋相対の複合基準で判定する。

```
passed = |r| ≤ atol + rtol · scale
```

`scale` は当該恒等式に関与する項の絶対値の代表値（例: 行/列の要素絶対値の最大）。既定 `atol = 1e-8`,
`rtol = 1e-6`。既定値は `AccountingCheck` に記録し、呼び出し側で上書き可能とする。

### 5.2 異常値

| 状況 | 扱い |
|---|---|
| `NaN` / `Inf` | 例外にせず、その期の該当検証を `passed=false`・`residual` に `NaN`/`Inf` を記録し invalid 期に分類 |
| 欠損 | 検証不能として `passed=false`・理由を `detail` に記録 |
| 発散 | ストックが `Inf` または閾値超過となる最初の期を `divergence_time` に記録し、以降を invalid 期に分類 |

### 5.3 違反の構造化

各検証は `AccountingCheck`（`name`, `period`, `residual`, `tolerance_abs`, `tolerance_rel`, `passed`,
`detail`）として返し、`SFCResult.checks::Vector{AccountingCheck}` に集約する。自動補正・丸め・辻褄合わせ
は行わない。違反があっても計算結果は保持し、`valid_periods` / `invalid_periods` で明示する。

## 6. 責務境界: `SFCResult` と `SimulationResult`

| 情報 | 置き場 | 理由 |
|---|---|---|
| 水準系列 `Y, C, G, T, YD, H, N` | `SimulationResult.variables` | 可視化・`compare_with_data`・cross-model 表面にそのまま乗る |
| モデル parameters | `SimulationResult.metadata["parameters"]` | 既存 adapter 慣習（Minsky 診断が依存） |
| sector / instrument 定義 | `SFCResult.sectors` / `.instruments` | 構造は平坦 Dict に載らない |
| 貸借対照表・取引フロー行列（各期） | `SFCResult.balance_sheets` / `.transaction_flows` | 行列は `SimulationResult` の対象外 |
| 評価損益（MVP は 0） | `SFCResult.valuation_changes` | §4 の独立項 |
| 会計検証結果 | `SFCResult.checks` / `valid_periods` / `invalid_periods` / `divergence_time` | 検証契約の出力 |
| methodology version | `SFCResult.methodology_version` | provenance |

**変換規則**: `SIMModel.simulate` は水準系列 `NamedTuple` を返し、汎用
`to_simulation_result(::AbstractMacroModel, ::NamedTuple, scenario)` で `SimulationResult` になる。
SFC 構造は `sfc_result(sr::SimulationResult; atol, rtol) -> SFCResult` が `sr` から復元・検証する
（`sr.metadata["parameters"]` に `θ, W` 等が必要。無ければ `ArgumentError`）。`SIMModel` 経由の
`NamedTuple` overload と内部コアを共有し、両経路で同一結果を保証する（Minsky 診断層と同じ契約）。
型・API スケッチは [SFC 統合設計 §5](../models/sfc_integration_design.md#5-型api-スケッチ実装は後続issue)。

## 7. 既存 interface・cross-model 層との接続点

| 接続先 | 方針 |
|---|---|
| `AbstractMacroModel` | `SIMModel <: AbstractMacroModel` として既存 interface（`model_name`/`state_variables`/`control_variables`/`parameters`/`steady_state`/`simulate`/`impulse_response`）を実装。抽象型階層は変更しない（ADR 0002 の方針を継承）。 |
| `ModelMetadata` | `SIMModel` から既存 `ModelMetadata(::AbstractMacroModel)` で自動生成。 |
| `MODEL_CONCEPT_REGISTRY`（ADR 0006） | `:sim` の `ModelConceptCoverage` 行を追加。`:private_debt_credit`（政府貨幣＝政府負債）・`:demand_and_instability`（需要決定）を主軸に登録し、`:steady_state_stability` は「大域安定・危機 regime なし」と明示。同名変数の定義差は `caveats` に記載し、ADR 0006 の非同一視・比較不能の非統合を継承。 |
| `_XM_MODEL_LABELS` | `:sim => "SIM（SFC）"` を追加。 |
| include 順序 | モデル型は `src/models/sfc_sim.jl`（既存 `models/` ブロック）、SFC 結果・検証層は `src/analysis/sfc_accounting.jl`（`core/simulation_result.jl` の後）。registry 追加は既存 `llm/cross_model_reasoning.jl` 内。 |

## 8. LLM 説明で必須とする情報・JSON 保存・provenance

`SFCResult` を LLM 説明・JSON へ渡す際、次を必須とする。

- **部門・金融資産の構成**: sector ID/表示名、instrument ID/表示名。
- **会計恒等式の検証結果**: 検証済みであること、`valid_periods`/`invalid_periods`、違反があれば
  `AccountingCheck` の要約。**会計違反がある場合は「モデル出力の会計的信頼性が損なわれている」旨を
  必ず明示**し、違反を無視した解釈をしない。
- **methodology version**（例 `"sfc-sim/1.0.0"`）と、モデル名・シナリオ名・parameters。
- **valuation change の扱い**: MVP では 0（額面固定・単一資産）である旨。
- **provenance**: 入力パラメータ・初期ストック・許容誤差・DME バージョン。

JSON 保存キーは安定 ID（§2）を使い、表示名変更で壊れないようにする。LLM 説明は既存の
[LLM 出力安全性ルール](../llm_safety.md) を継承し、会計恒等式が保証するのは「内的整合性」であって
「現実妥当性」ではないことを免責する。

## 9. `compare_with_data` と比較 API v2

- **現状（v1）**: `compare_with_data(model::SimulationResult, data::SimulationResult; mapping::Dict{String,String})`。
  SFC は水準系列（`Y,C,G,T,YD,H`）を `SimulationResult` に出すため、**このシグネチャを一切変えずに**
  既存比較へ乗る。破壊しない。
- **v2（加算的・後方互換）**: 部門別ストック/フロー（`(sector, instrument)` キー）や会計残差を意識した
  比較を新 API として追加する。v1 は残置し、v2 は別関数（例 `compare_sfc_with_data`）として導入して
  既存呼び出しを壊さない。SFC 特有の「観測データ側も会計的に閉じているか」の扱いは v2 の設計事項とし、
  本 ADR では v1 非破壊と v2 加算という移行方針のみ確定する。

## 10. versioning

- `methodology_version = "sfc-sim/1.0.0"`（モデル＋会計検証契約）。
- 検証名語彙（§4）・符号規約（§3）・恒等式の意味論の変更は major、`AccountingCheck` の field 追加や
  文言修正は minor/patch。sector/instrument ID の変更は破壊的変更として major。

## 11. 将来拡張（責務境界のみ残す）

次を非対象とするが、型・行列・恒等式が拡張点を持つよう設計する。

- **本格 Minsky-SFC（次期 Roadmap 候補）**: 銀行部門・企業債務・利子付き資産・信用創造を含む SFC。
  instrument に `:loans` / `:deposits` / `:bonds` を追加し、sector に `:banks` / `:firms` を追加するだけで
  行列が拡張できる方向で設計する。
- **複数金融商品・価格評価益**: `valuation_change` 独立項（§4）に値を入れて拡張。恒等式・検証は不変。
- **開放経済**: sector に `:rest_of_world`、instrument に外貨資産を追加。

これらは ID・符号・検証契約を今回固定することで、後方互換に追加できる。

## 理由

- 会計恒等式をモデル方程式と分離すると、行動仕様を変えても「会計が閉じているか」を独立に検査でき、
  実装バグ（フローとストックの取りこぼし・符号誤り）を構造的に検出できる。
- sector/instrument の安定 ID を先に固定すると、JSON・cross-model registry・将来拡張が表示名や
  モデル追加で壊れない。
- `SFCResult` を別型に分離する idiom は Minsky 診断層（`MinskyDiagnosticsResult`）で実績があり、
  `SimulationResult`・可視化・比較・LLM 層を破壊しない。
- 違反を補正で隠さず構造化して返す方針は、SFC の価値（不整合の可視化）そのものを守る。
- 比較 API を v1 非破壊・v2 加算にすると、既存モデルの比較機能を止めずに SFC 固有比較を段階導入できる。

## 見送りとした選択肢

- **`SimulationResult` の平坦 Dict だけで SFC を表現**: sector・instrument 構造と会計恒等式が失われ、
  資産負債対応・予算制約を検査できない。
- **不整合の自動補正（残差を按分して辻褄合わせ）**: SFC の主目的である「不整合の検出」を無効化する。
- **初版から銀行・企業信用を含む本格 Minsky-SFC**: 最小検証契約を固める前に複雑度を上げ、
  会計基盤の正しさを検証しにくくする（ADR 0002 の最小実装方針に反する）。
- **`compare_with_data` を SFC 向けに破壊的変更**: 既存 8+モデルの比較機能を止める。加算的 v2 で回避。
- **valuation change を MVP で省略（項自体を持たない）**: 将来の価格変動資産導入時に恒等式・型・検証を
  作り直す必要が生じる。0 の独立項として保持する方が拡張が安全。

## 影響

- 後続 #146 以降が、本 ADR と [SFC 統合設計](../models/sfc_integration_design.md)に基づき
  `src/models/sfc_sim.jl`（`SIMModel`）・`src/analysis/sfc_accounting.jl`（`SFCResult`・行列・
  `check_accounting`・adapter）・`MODEL_CONCEPT_REGISTRY` への `:sim` 追加・テスト分割を実装する。
- 既存 `AbstractMacroModel` 階層・`SimulationResult`・`compare_with_data`・可視化・LLM 層・Keen 実証層は
  変更しない。
- cross-model 比較へは `MODEL_CONCEPT_REGISTRY` に coverage 行を追記するだけで参加できる（ADR 0006 の
  拡張手順を継承）。

## 参考

- [SFC 統合設計 — 最小 SIM 型モデル](../models/sfc_integration_design.md) — SIM 方程式・定常状態・行列・型/API スケッチ
- [Minsky系金融不安定性モデル 設計方針](../models/minsky_design.md) — Godley-Lavoie(SFC) を含む候補比較
- [ADR 0002](0002-minsky-integration-design.md) — 既存インターフェース準拠・別結果型・LLM 層無拡張の統合方針
- [ADR 0006](0006-cross-model-reasoning-contract.md) — 概念対応の明示・同名変数の非同一視・比較不能の非統合
- [出力結果の読み方](../simulation_outputs.md) — 水準・偏差・ストック/フローの別
- [LLM 出力の安全性ルール](../llm_safety.md) — 汎用の免責・禁止表現
