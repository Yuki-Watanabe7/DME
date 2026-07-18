# DME — Dynamic Macroeconomic Models in Julia

動学的マクロ経済モデルを Julia で実装したパッケージです。

モデルの数値解法にとどまらず、以下を一つの共通 API で扱えます。

- **モデル計算**: 定常状態・移行経路・シミュレーション・インパルス応答（IRF）
- **可視化**: `plot_result` / `plot_irf` / `plot_comparison`
- **実データ接続**: FRED・e-Stat からの系列取得と前処理・モデル出力との定量比較
- **LLM による結果説明**: 分析コンテキスト（`AnalysisContext`）を構築し、自然言語の説明文を生成

## モデル一覧

| モデル | 分類 | 概要 |
|---|---|---|
| [Ramsey](docs/models/ramsey.md) | 長期成長 | 無限期間最適成長モデル。価値反復法と完全予見経路の計算をサポート |
| [Solow](docs/models/solow.md) | 長期成長 | 外生的貯蓄率による長期成長モデル。解析的定常状態と収束経路の計算をサポート |
| [RBC](docs/models/rbc.md) | 景気変動 | リアル・ビジネス・サイクルモデル。線形化（Blanchard-Kahn 法）によるインパルス応答計算をサポート |
| [IS-LM](docs/models/islm.md) | 短期政策 | 財市場・貨幣市場の同時均衡。財政・金融政策ショックの比較静学 |
| [AD-AS](docs/models/adas.md) | 短期政策 | 総需要・総供給モデル。物価と産出に対する需要・供給ショックの分析 |
| [New Keynesian](docs/models/new_keynesian.md) | 短期政策 | 3方程式 NK モデル。需要・コストプッシュ・金融政策ショックの IRF |
| [Mundell-Fleming](docs/models/mundell_fleming.md) | 開放経済 | 小国開放経済（変動相場制・完全資本移動）の政策効果分析 |
| [VAR](docs/models/var.md) | データ駆動 | 簡易ベクトル自己回帰（1 次）。多変量時系列のシミュレーションと IRF |
| [Keen](docs/models/keen.md) | 金融不安定性 | Minsky系金融不安定性モデル（連続時間 ODE）。良い均衡への収束と債務崩壊の双安定性を再現 |

どのモデルを使うべきか迷った場合は[モデル選択ガイド](docs/model_selection_guide.md)を参照してください。

## セットアップ

Julia 1.x が必要です。

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

### 外部 API 設定（実データ・LLM 機能）

FRED・e-Stat・OpenAI など外部 API を使う場合は、環境変数ファイルを作成してください。

```bash
cp .env.example .env
# .env を開き、使用する API キーを設定する
```

**API キーなしでも動きます**。デフォルトは `fixture` モードのため、テスト・デモは API キー不要で実行できます。詳細は [設定・環境変数管理ガイド](docs/development/configuration.md) を参照してください。

## 使い方

### Ramsey モデル

```julia
using DME

m = RamseyModel(0.3, 0.99, 0.25)  # α, β, δ

# 定常状態（NamedTuple で返す）
ep = steady_state(m)
ep.K  # 定常資本
ep.C  # 定常消費

# 完全予見経路（K0 から定常状態への移行）
path = transition_path(m, ep.K / 2)
path.K  # 資本系列
path.C  # 消費系列

# 価値反復法でポリシー関数を求め、シミュレーション
result = simulate(m, ep.K / 2)
result.K  # 資本系列
result.C  # 消費系列

# SimulationResult 型に変換（汎用的な後処理に便利）
sr = to_simulation_result(m, result, "simulate")
sr["K"]  # 変数系列の取得
nperiods(sr)  # 期間数
```

### RBC モデル

```julia
using DME

m = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)  # α, β, γ, δ, μ, ρ

# 定常状態（NamedTuple で返す）
ep = steady_state(m)
ep.K   # 定常資本
ep.C   # 定常消費
ep.L   # 定常労働
ep.Y   # 定常産出

# 完全予見経路
path = transition_path(m, 1.0, ep.K)  # A0, K0

# インパルス応答（技術ショック ε₀ = 0.01）
irf = impulse_response(m, 0.01)
irf.ĉ  # 消費の対数偏差
irf.k̂  # 資本の対数偏差
```

### Solow モデル

```julia
using DME

m = SolowModel(0.3, 0.2, 0.1, 0.01, 0.02)  # α, s, δ, n, g

# 定常状態（解析解: 効率労働単位あたり）
ep = steady_state(m)
ep.k  # 定常資本
ep.y  # 定常産出
ep.c  # 定常消費

# 収束経路（k0 から定常状態へ T=100 期の前向き反復）
path = transition_path(m, ep.k / 2; T=100)
path.k    # 資本系列
path.y    # 産出系列
path.c    # 消費系列
path.inv  # 投資系列

# SimulationResult に変換してプロット
sr = to_simulation_result(m, path, "convergence")
p = plot_result(sr; vars=["k", "y", "c"], title="Solow 収束経路")
```

### プロット

`SimulationResult` を直接プロットできます。

```julia
using DME

m = RamseyModel(0.3, 0.99, 0.25)
ep = steady_state(m)
sr = to_simulation_result(m, simulate(m, ep.K / 2), "simulate")

# すべての変数をプロット
p = plot_result(sr)

# 特定の変数を指定してプロット
p = plot_result(sr; vars = ["K", "C"], title = "Ramsey 移行経路")

# Symbol でも指定可能
p = plot_result(sr; vars = :K, xlabel = "Period", ylabel = "Capital")
```

存在しない変数を指定すると、利用可能な変数名を含むエラーが返ります。

```julia
plot_result(sr; vars = "Z")
# ArgumentError: 次の変数が見つかりません: Z. 利用可能な変数: C, K
```

### モデルメタ情報

すべてのモデルは共通のメタ情報 API を持ちます。

```julia
using DME

m = RamseyModel(0.3, 0.99, 0.25)

model_name(m)          # "Ramsey Model"
state_variables(m)     # [:K]
control_variables(m)   # [:C]
parameters(m)          # (α = 0.3, β = 0.99, δ = 0.25)
```

### 実データ接続（FRED / e-Stat）

FRED・e-Stat の系列を取得し、前処理を経てモデル出力と比較できます。デフォルトは fixture モード（API キー不要）です。

```julia
using DME

# FRED から実質 GDP を取得（デフォルト: fixture モード）
gdp = fetch_fred_series("GDPC1")

# e-Stat から日本の統計系列を取得
cpi = fetch_estat_series("0003427113")

# 前処理: 対数化・前年比・標準化など
gdp_log = apply_log(gdp)
gdp_yoy = pct_change(gdp; periods = 4)

# モデル出力と実データの定量比較（SimulationResult 同士を変数マッピングで比較）
m = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
model_sr = to_simulation_result(m, impulse_response(m, 0.01), "tech_shock")
data_sr = to_simulation_result(standardize(gdp_yoy), "actual_data")
cr = compare_with_data(model_sr, data_sr; mapping = Dict("ŷ" => "FRED_GDPC1"))
cr.variables["ŷ"].rmse         # RMSE
cr.variables["ŷ"].correlation  # 相関係数
```

詳細は [FRED 接続ガイド](docs/data/fred.md)・[e-Stat 接続ガイド](docs/data/estat.md)・[前処理ユーティリティ](docs/data/preprocess.md) を参照してください。

### LLM による結果説明

シミュレーション結果を `AnalysisContext` に集約し、自然言語の説明を生成できます。`OPENAI_API_KEY` 未設定時は Mock プロバイダが使われるため、API キーなしで試せます。

```julia
using DME

m = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
sr = to_simulation_result(m, impulse_response(m, 0.01), "tech_shock")

ctx = AnalysisContext(m, sr; shock_description = "1% positive technology shock")
explanation = explain_result(ctx)   # 構造化された説明（caveats・免責付き）

# 実 LLM を呼ぶ場合
provider = create_provider()        # OPENAI_API_KEY があれば OpenAIProvider
response = complete_from_prompt(provider, build_explain_prompt(ctx))
```

出力の安全性ルールは [LLM 出力の安全性・免責・禁止表現ルール](docs/llm_safety.md) を参照してください。

## サンプルスクリプト

`examples/` ディレクトリに、機能ごとのデモスクリプトがあります。いずれも API キー不要で完走します。

| スクリプト | 内容 |
|---|---|
| [examples/growth_models.jl](examples/growth_models.jl) | **長期成長・景気変動デモ**。Ramsey / RBC / Solow の定常状態・移行経路・IRF・プロット API の使い方を示す。 |
| [examples/policy_analysis.jl](examples/policy_analysis.jl) | **短期政策分析デモ**。IS-LM / AD-AS / New Keynesian による財政・金融・需要・供給ショックの比較と各モデルの使い分けを示す。 |
| [examples/model_overview_demo.jl](examples/model_overview_demo.jl) | **モデル横断デモ**。Ramsey / Solow / RBC / Mundell-Fleming / New Keynesian を共通 API で横断し、可視化・横断比較までの一連のワークフローを示す。 |
| [examples/real_data_demo.jl](examples/real_data_demo.jl) | **実データ接続デモ**。FRED からのデータ取得（fixture / live モード）・前処理・SimulationResult 変換・モデル比較・可視化・AnalysisContext 接続を示す。 |
| [examples/ai_economist_demo.jl](examples/ai_economist_demo.jl) | **AIエコノミスト統合デモ**。モデル選択 → シミュレーション → 実データ取得 → 前処理 → モデル比較 → AnalysisContext → docs コンテキスト → LLM 説明生成の一連のフロー。 |
| [examples/minsky_phase2_demo.jl](examples/minsky_phase2_demo.jl) | **Minsky Phase 2 統合デモ**。Keen モデルの良い均衡回帰経路・高債務崩壊経路の両方について、資金調達区分診断（Hedge/Speculative/Ponzi）・金融不安定性連続診断指標とサマリー・regime timeline / diagnostics plot・シナリオ比較を一通り実行する。 |
| [examples/keen_empirical_phase3_demo.jl](examples/keen_empirical_phase3_demo.jl) | **Keen 実証統合デモ**。米国 Keen 実証 MVP について、実データ取得 → 観測系列変換 → 限定キャリブレーション → in-sample/out-of-sample 検証 → observed proxy / model の金融不安定性 regime 比較 → 感応度分析 → 可視化 → 機械可読レポート出力までを完走する。fixture モードは API キー不要・決定的。 |

```bash
julia --project=. examples/growth_models.jl
julia --project=. examples/policy_analysis.jl
julia --project=. examples/model_overview_demo.jl
julia --project=. examples/real_data_demo.jl
julia --project=. examples/ai_economist_demo.jl
julia --project=. examples/minsky_phase2_demo.jl
julia --project=. examples/keen_empirical_phase3_demo.jl
```

実データ・実 LLM で実行する場合は環境変数を設定します。

```bash
export FRED_API_KEY=your_api_key_here
export DME_DATA_MODE=live
export OPENAI_API_KEY=sk-...
julia --project=. examples/ai_economist_demo.jl
```

Keen 実証デモは取得モードと図・レポートの出力先を環境変数で切り替えます（fixture が既定・正、`source unavailable` 時に fixture へ暗黙 fallback せず失敗理由を表示）。

```bash
# fixture（既定・API キー不要・決定的）
julia --project=. examples/keen_empirical_phase3_demo.jl

# live（FRED API、要 API キー） / rest_api（要 DATA_PROVIDER_BASE_URL）。図・JSON の出力先を指定
DME_DATA_MODE=live FRED_API_KEY=... KEEN_DEMO_OUTDIR=./out \
  julia --project=. examples/keen_empirical_phase3_demo.jl
```

> 実証結果の限界: 観測系列は理論変数（ω・λ・d）の近似 proxy、calibrated parameter は採用期間・proxy・weight・bounds 依存、observed regime も集計 proxy 診断、out-of-sample fit は危機予測能力を意味しない。本デモは投資助言・政策判断の自動化を目的としない。

## テスト

```bash
julia --project=. -e "using Pkg; Pkg.test()"
```

## ドキュメント

### ガイド

| ドキュメント | 内容 |
|---|---|
| [モデル選択ガイド](docs/model_selection_guide.md) | 問い・現象からモデルを選ぶためのリファレンス。比較表・決定木・各モデルの限界 |
| [出力結果の読み方](docs/simulation_outputs.md) | 定常状態・移行経路・IRF・水準/対数偏差の概念と出力例 |
| [API リファレンス](docs/api.md) | Public/Internal API の一覧・シグネチャ・移行ガイド |

### モデル解説

| ドキュメント | 内容 |
|---|---|
| [Ramsey モデル](docs/models/ramsey.md) | 無限期間最適成長モデルの目的・変数・パラメータ・出力・限界 |
| [Solow モデル](docs/models/solow.md) | 外生的貯蓄率による長期成長モデルの解説 |
| [RBC モデル](docs/models/rbc.md) | リアル・ビジネス・サイクルモデルの目的・変数・IRF・限界 |
| [IS-LM モデル](docs/models/islm.md) | 財市場・貨幣市場の同時均衡モデルの解説 |
| [AD-AS モデル](docs/models/adas.md) | 総需要・総供給モデルの解説 |
| [New Keynesian モデル](docs/models/new_keynesian.md) | 3方程式 NK モデルの解説 |
| [Mundell-Fleming モデル](docs/models/mundell_fleming.md) | 小国開放経済モデルの解説 |
| [VAR モデル](docs/models/var.md) | 簡易ベクトル自己回帰モデルの解説 |
| [Keen モデル](docs/models/keen.md) | Minsky系金融不安定性モデルの目的・変数・パラメータ・出力・限界 |
| [小国開放経済モデル設計方針](docs/models/open_economy_design.md) | 候補モデル比較と Mundell-Fleming 選定の経緯 |
| [Minsky系金融不安定性モデル設計方針](docs/models/minsky_design.md) | Keen / Ryoo / Godley-Lavoie (SFC) の候補比較と Keen モデル選定の経緯 |
| [Minsky系（Keen）モデル DME統合設計](docs/models/minsky_integration_design.md) | Keen モデルのインターフェース適合・ソルバー接続・出力スキーマ・LLM メタデータ設計 |
| [Minsky 資金調達区分診断](docs/models/minsky_regime_diagnostics.md) | Hedge / Speculative / Ponzi の操作的定義・仮定・型/関数契約・限界の設計 |
| [Minsky 連続診断指標・サマリー](docs/models/minsky_diagnostics_summary.md) | カバレッジ比率・マージン・regime滞在比率・peak/minimum・発散時点の指標定義とサマリー契約（Phase 2） |
| [Keen モデル 実証化戦略](docs/models/keen_empirical_strategy.md) | 実データ接続の観測方程式・単位変換・共通頻度・年単位ODE↔四半期の時間軸契約・固定/推定パラメータ分離・識別戦略・検証方針 |
| [モデル解説テンプレート](docs/models/template.md) | 新規モデルの解説ドキュメント作成用テンプレート |

### 実データ接続

| ドキュメント | 内容 |
|---|---|
| [FRED API 接続ガイド](docs/data/fred.md) | FRED クライアントの使い方・API キー設定・fixture モード |
| [e-Stat API 接続ガイド](docs/data/estat.md) | e-Stat クライアントの使い方・appId 設定・日本統計系列 |
| [DataSeries / MacroDataset 利用ガイド](docs/data/data_series_guide.md) | 実データ標準型の構造と操作 |
| [実データ前処理ユーティリティ](docs/data/preprocess.md) | 欠損値補完・対数・差分・移動平均・標準化・頻度変換 |
| [モデル変数と実データ系列のマッピング表](docs/data/variable_mapping.md) | 各モデル変数と実データ系列の対応・単位・変換注意事項 |
| [日本マクロデータ接続 設計方針](docs/data/japan_macro_sources.md) | BOJ・内閣府・財務省・総務省のデータソース整理・優先順位・ライセンス |

### アーキテクチャ・LLM 層

| ドキュメント | 内容 |
|---|---|
| [モデル共通インターフェース](docs/architecture/model_interface.md) | 抽象型階層・命名方針・新規モデル追加ルール |
| [パッケージ構成とアーキテクチャ概要](docs/architecture/package_structure.md) | ソースツリー・include 順序・Node 型階層・補間 |
| [AIエコノミスト化アーキテクチャ](docs/architecture/ai_economist.md) | 分析カーネル・データ層・LLM 層の全体構成とデータフロー |
| [LLM 接続層の設計](docs/architecture/llm_layer.md) | LLM 層の責務・入出力仕様・禁止事項・安全性方針 |
| [LLM Provider 設定ガイド](docs/architecture/llm_provider.md) | provider 抽象化・OpenAI 設定・MockProvider・差し替え方法 |
| [AnalysisContext 設計](docs/architecture/analysis_context.md) | LLM へ渡す構造化コンテキスト型の設計・構造・利用例 |
| [LLM 出力の安全性・免責・禁止表現ルール](docs/llm_safety.md) | 禁止表現・必須記載・プロンプトテンプレート・出力チェックリスト |

### 設計決定記録（ADR）

| ドキュメント | 内容 |
|---|---|
| [ADR 0001: Minsky系モデルとして Keen モデルを採用](docs/adr/0001-minsky-model-selection.md) | Minsky系金融不安定性モデル初版の採用決定と選定理由 |
| [ADR 0002: Keen モデルの統合方式](docs/adr/0002-minsky-integration-design.md) | 既存インターフェース準拠・自前 RK4・LLM 層無拡張という統合方針の決定記録 |
| [ADR 0003: Minsky 資金調達区分の診断層](docs/adr/0003-minsky-financing-regime-diagnostics.md) | 診断を Keen 本体から分離した読み取り専用層とし hysteresis を不採用とする決定記録 |
| [ADR 0004: Keen モデル実証化の識別戦略](docs/adr/0004-keen-empirical-calibration-strategy.md) | 米国基準・指数/比率の検証義務・Δt=0.25 の時間軸契約・固定/推定分離・ODE residual 採用の決定記録 |

### 開発

| ドキュメント | 内容 |
|---|---|
| [品質チェックとローカル検証手順](docs/development/quality_checks.md) | Aqua.jl・JuliaFormatter・テスト実行方法 |
| [依存パッケージ管理と注意点](docs/development/dependency_management.md) | JuMP・Interpolations・NLsolve の注意点・Manifest.toml 管理 |
| [設定・環境変数管理ガイド](docs/development/configuration.md) | API キー設定・fixture/mock モード・CI 運用方針 |

## 外部データソース

本パッケージが利用する外部データソースおよびその利用条件を示します。

| サービス | 利用条件・クレジット |
|---|---|
| [政府統計総合窓口（e-Stat）](https://www.e-stat.go.jp/) | このサービスは、政府統計総合窓口(e-Stat)のAPI機能を使用していますが、サービスの内容は国によって保証されたものではありません。 |
| [FRED（Federal Reserve Economic Data）](https://fred.stlouisfed.org/) | データは St. Louis Fed が提供する FRED API 経由で取得します。利用には [FRED 利用規約](https://fred.stlouisfed.org/docs/api/terms_of_use.html) が適用されます。 |
