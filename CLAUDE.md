# CLAUDE.md

DME は動学的マクロ経済モデルを Julia で実装したパッケージです。
モデル群（Ramsey / Solow / RBC / IS-LM / AD-AS / New Keynesian / Mundell-Fleming / VAR / Keen）の計算・可視化に加え、
実データ接続（FRED・e-Stat）と LLM による結果説明生成をサポートします。
このファイルは Claude Code がこのリポジトリで作業する際の入口ガイドです。

## リポジトリ構成

| パス | 内容 |
|---|---|
| `src/models/` | 各モデルの実装 |
| `src/core/` | モデル共通インターフェース・SimulationResult・比較・可視化 |
| `src/data/` | 実データ層（DataSeries・前処理・FRED / e-Stat クライアント） |
| `src/llm/` | LLM 層（AnalysisContext・プロンプト・provider 抽象化） |
| `src/numerics/` | グリッド・補間などの数値計算ユーティリティ |
| `examples/` | 機能別デモスクリプト（API キー不要で完走） |
| `test/` | テスト（`test/fixtures/` に API fixture、`test/Project.toml`/`test/Manifest.toml` にテスト専用依存を固定） |
| `docs/` | 詳細ドキュメント（下表参照） |

## よく使うコマンド

```bash
# 依存解決
julia --project=. -e "using Pkg; Pkg.instantiate()"

# テスト全体を実行
julia --project=. -e "using Pkg; Pkg.test()"
```

## 作業時の重要ルール

1. **作業前に確認する**: 変更前に関連コード・関連テスト・関連 docs を確認すること。
2. **変更種別に応じた検証**:
   - Julia コード・テスト・CI 設定・`Project.toml` / `Manifest.toml` を変更した場合はフルセットの検証は行わないが、少なくとも変更対象のコードや関数に対する簡単なsmoke testを行うこと。可能であれば、対象テストセット相当の最小確認も行うこと。(`Pkg.test()`によるフルセットの検証はPR時のCIにて行う。)
      - julia --project=. -e "using DME"
      - 変更対象モデル・関数の簡単な smoke test
      - 可能であれば対象テストセット相当の最小確認
   - `docs/` 配下のみの変更（docs-only）の場合は Julia 環境セットアップや `Pkg.test()` は不要。docs-only 変更をした場合は PR 本文または最終コメントに「docs-only のため Julia test は未実行」と明記すること。
3. **Project.toml を変更した場合**: `julia --project=. -e 'using Pkg; Pkg.resolve()'` を実行し、`Manifest.toml` もコミットすること。
4. **test/Project.toml を変更した場合**: `julia --project=test -e 'using Pkg; Pkg.instantiate()'` を実行し、`test/Manifest.toml` もコミットすること。テスト専用依存（`Aqua`・`JuliaFormatter`・`Test`）を追加・変更する場合はルート `Project.toml` の `[extras]`/`[targets]` も更新すること（詳細: [品質チェックとローカル検証手順](docs/development/quality_checks.md) 2.1 節）。

## GitHub Issue対応の標準手順

ローカルClaude CodeでIssue対応する場合は、GitHub CLI `gh` を使ってIssue本文・コメント・PR状態を確認する。

基本コマンド:

```bash
gh issue view <issue-number> --comments
gh issue list --state open
```

Issue対応時の標準フロー:

gh issue view <issue-number> --comments でIssue本文とコメントを確認する
関連コード・関連テスト・関連docsを読む
作業方針を短く説明する
実装・docs更新を行う
軽量検証を実行する


## 詳細ドキュメント

各モデルの解説は `docs/models/<モデル名>.md`（ramsey / solow / rbc / islm / adas / new_keynesian / mundell_fleming / var / keen / sim_sfc、テンプレートは template.md）。全ドキュメントの一覧は [README のドキュメント節](README.md#ドキュメント) を参照。

| ドキュメント | 内容 |
|---|---|
| [API リファレンス](docs/api.md) | Public/Internal API の一覧・シグネチャ・移行ガイド |
| [モデル選択ガイド](docs/model_selection_guide.md) | 問い・現象からモデルを選ぶためのリファレンス・比較表・決定木 |
| [モデル能力・概念定義 metadata](docs/model_capabilities.md) | 各モデルの部門・金融機構・対応API・実証能力の機械可読プロファイルと変数の概念定義・横断比較表・追加手順 |
| [出力結果の読み方](docs/simulation_outputs.md) | 定常状態・移行経路・IRF・水準/対数偏差の概念 |
| [モデル共通インターフェース](docs/architecture/model_interface.md) | 抽象型階層・命名方針・新規モデル追加ルール |
| [パッケージ構成とアーキテクチャ概要](docs/architecture/package_structure.md) | ソースツリー・include 順序・Node 型階層・補間・モデル内部関数 |
| [AIエコノミスト化アーキテクチャ](docs/architecture/ai_economist.md) | 分析カーネル・データ層・LLM 層の全体構成とデータフロー |
| [LLM接続層の設計](docs/architecture/llm_layer.md) | LLM層の責務・入出力仕様・禁止事項・安全性方針 |
| [LLM Provider設定ガイド](docs/architecture/llm_provider.md) | provider抽象化・OpenAI設定・MockProvider・差し替え方法 |
| [AnalysisContext 設計](docs/architecture/analysis_context.md) | LLMへ渡す構造化コンテキスト型の設計・構造・利用例 |
| [クロスモデル推論層の設計](docs/architecture/cross_model_reasoning.md) | Keen 実証結果と既存モデルの概念対応・mapping 導出・出力 section・安全性（ADR 0006） |
| [LLM出力の安全性・免責・禁止表現ルール](docs/llm_safety.md) | 禁止表現・必須記載・プロンプトテンプレート・出力チェックリスト |
| [DataSeries / MacroDataset 利用ガイド](docs/data/data_series_guide.md) | 実データ標準型の構造と操作 |
| [モデル変数と実データ系列のマッピング表](docs/data/variable_mapping.md) | 各モデル変数と候補実データ系列の対応・単位・変換注意事項 |
| [実データ前処理ユーティリティ](docs/data/preprocess.md) | 欠損値補完・対数・差分・移動平均・標準化・頻度変換などの使用例 |
| [FRED API 接続ガイド](docs/data/fred.md) | FRED API クライアントの使い方・API キー設定・fixture モード |
| [e-Stat API 接続ガイド](docs/data/estat.md) | e-Stat API クライアントの使い方・appId 設定・日本統計系列・fixture モード |
| [日本マクロデータ接続 設計方針](docs/data/japan_macro_sources.md) | BOJ・内閣府・財務省・総務省のデータソース整理・優先順位・ライセンス |
| [小国開放経済モデル設計方針](docs/models/open_economy_design.md) | 候補モデル比較・最小実装選定（Mundell-Fleming）・実データ候補系列 |
| [Minsky系金融不安定性モデル設計方針](docs/models/minsky_design.md) | 候補モデル比較（Keen / Ryoo / SFC）・初版採用モデル選定・実データ候補系列 |
| [Minsky系（Keen）モデル DME統合設計](docs/models/minsky_integration_design.md) | Keen モデルのインターフェース適合・ODE ソルバー接続・出力スキーマ・LLM メタデータ・テスト設計 |
| [Minsky 資金調達区分診断](docs/models/minsky_regime_diagnostics.md) | Hedge / Speculative / Ponzi の操作的定義・元本返済代理仮定・型/関数契約・限界の設計 |
| [Minsky 連続診断指標・サマリー](docs/models/minsky_diagnostics_summary.md) | カバレッジ比率・マージン・regime滞在比率・peak/minimum・発散時点の指標定義とサマリー契約 |
| [Keen モデル 実証化戦略](docs/models/keen_empirical_strategy.md) | 実データ接続の観測方程式・単位変換・共通頻度・年単位ODE↔四半期の時間軸契約・固定/推定パラメータ分離・識別戦略・検証方針 |
| [SFC 統合設計（最小 SIM 型モデル）](docs/models/sfc_integration_design.md) | SIM 型モデルの方程式・部門・金融資産・貸借対照表/取引フロー行列・会計恒等式の検証契約・型/API スケッチ |
| [最小 SIM 型 SFC モデル](docs/models/sim_sfc.md) | `SIMModel` の目的・方程式・会計表・変数の単位/時点・財政ショック定義・限界・`sfc_result` adapter |
| [ADR 0001: Minsky系モデル選定](docs/adr/0001-minsky-model-selection.md) | Keen モデル採用の決定記録（`docs/adr/` は設計決定記録の置き場） |
| [ADR 0002: Keen モデルの統合方式](docs/adr/0002-minsky-integration-design.md) | 既存インターフェース準拠・自前 RK4・LLM 層無拡張という統合方針の決定記録 |
| [ADR 0003: Minsky 資金調達区分の診断層](docs/adr/0003-minsky-financing-regime-diagnostics.md) | 診断を Keen 本体から分離した読み取り専用層とし hysteresis を不採用とする決定記録 |
| [ADR 0004: Keen モデル実証化の識別戦略](docs/adr/0004-keen-empirical-calibration-strategy.md) | 米国基準・指数/比率の検証義務・Δt=0.25 の時間軸契約・固定/推定分離・ODE residual 採用の決定記録 |
| [ADR 0005: Keen 実証結果の AI 説明契約](docs/adr/0005-keen-ai-explanation-contract.md) | 観測・測定・推定・モデル出力・診断proxy・感応度を分離する根拠階層・source reference・禁止解釈・構造化出力/fallback の決定記録 |
| [ADR 0006: クロスモデル推論契約](docs/adr/0006-cross-model-reasoning-contract.md) | 概念対応（ModelConceptMapping）の明示・repository metadata 限定・同名変数の非同一視・比較不能の非統合（insufficient_comparability）・fit 比較制限の決定記録 |
| [ADR 0007: SFC 統合契約](docs/adr/0007-sfc-integration-contract.md) | SIM 型を初版 SFC とし、会計恒等式をモデル方程式と別の検証契約とする・不整合を自動補正せず構造化・SFCResult を別型で adapter 接続・compare v1 非破壊/v2 加算の決定記録 |
| [品質チェックとローカル検証手順](docs/development/quality_checks.md) | Aqua.jl・JuliaFormatter・テスト実行方法 |
| [Keen 実証説明の LLM 回帰テストと安全性評価](docs/development/keen_llm_regression.md) | 契約/parser/シナリオ/golden/forbidden の評価レイヤー・安全性評価器・fixture 再生成/追加手順・任意 provider 評価 |
| [Keen 実証 AIエコノミスト統合デモ](docs/examples/keen_empirical_ai_economist.md) | データ取得→実証分析→根拠付きLLM説明→クロスモデル比較→provenance保存の再現可能な統合デモの実行手順・成果物・設定例 |
| [依存パッケージ管理と注意点](docs/development/dependency_management.md) | JuMP・Interpolations・NLsolve の注意点・Manifest.toml 管理 |
| [設定・環境変数管理ガイド](docs/development/configuration.md) | API キー設定・fixture/mock モード・CI 運用方針 |
