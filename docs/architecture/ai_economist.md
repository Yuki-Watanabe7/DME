# AIエコノミスト・アーキテクチャ

DME を「複数モデルを横断して経済分析を行い、実データと突き合わせ、結果を自然言語で説明する AI エコノミスト」として機能させるための層構成・責務・データフローを説明する。

> 本ドキュメントはもともと実装前の設計方針メモ（Issue #15）として作成され、現在は実装済みアーキテクチャの説明として維持している。

---

## 1. 背景と目的

DME はマクロ経済モデル群（Ramsey / Solow / RBC / IS-LM / AD-AS / New Keynesian / Mundell-Fleming / VAR）を実装する Julia パッケージであり、可視化・実データ接続・LLM 接続を備える。
各層の責務・境界・依存関係を明確にしておかないと、モデル層・データ層・LLM 層が混在しやすい。本ドキュメントはその境界の基準を示す。

---

## 2. 全体アーキテクチャ概要

```
┌──────────────────────────────────────────────────────────┐
│  LLM解釈層                                               │
│  （自然言語による説明・要約）                              │
│  inputs: AnalysisContext（メタ情報 + 結果 + docs 抜粋）    │
└────────────────────────┬─────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────┐
│  ドキュメント/コンテキスト層                               │
│  （docs/ の抜粋を LLM 文脈として提供する軽量 RAG）          │
│  inputs: docs/models/*.md, docs/simulation_outputs.md 等  │
└───────────────┬────────────────────────┬─────────────────┘
                │                        │
┌───────────────▼──────┐   ┌─────────────▼───────────────┐
│  実データ接続層        │   │  可視化層                    │
│  （外部データの取得・  │   │  （SimulationResult の       │
│   前処理・モデル比較） │   │   グラフ・比較表示）          │
│  inputs: 外部API      │   │  inputs: SimulationResult    │
└───────────────┬──────┘   └─────────────┬───────────────┘
                │                        │
┌───────────────▼────────────────────────▼───────────────┐
│  シミュレーション層                                      │
│  （SimulationResult の生成・変換・集約）                  │
│  inputs: モデル層の出力（NamedTuple）                    │
└────────────────────────────┬────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────┐
│  モデル層                                                │
│  （AbstractMacroModel を実装する各モデル）                │
│  内容: steady_state / transition_path / simulate /       │
│        impulse_response                                  │
└─────────────────────────────────────────────────────────┘
```

---

## 3. 各層の責務と境界

### 3.1 モデル層（`src/models/`）

**責務**: 経済モデルの定義・数値計算・定常状態・最適経路の導出。

| 要素 | 内容 |
|---|---|
| 型 | `AbstractMacroModel` のサブタイプ（`RamseyModel`, `RBCModel` 等） |
| 関数 | `steady_state`, `transition_path`, `simulate`, `impulse_response` |
| メタ情報 | `model_name`, `state_variables`, `control_variables`, `parameters` |
| 戻り値 | `NamedTuple`（内部表現。外部向けには `SimulationResult` に変換） |

**境界**:
- モデル層はデータ取得・可視化・LLM 呼び出しを行わない
- 数値計算のパラメータは `SolverOptions` / `ValueIterationOptions` 型で受け取る
- 実データとの比較・キャリブレーションはモデル層の責務ではない（実データ接続層で行う）

---

### 3.2 シミュレーション層（`src/core/simulation_result.jl`, `src/core/compare.jl`）

**責務**: モデル層の出力（`NamedTuple`）を `SimulationResult` に変換し、後処理・集約・比較を提供する。

| 要素 | 内容 |
|---|---|
| 型 | `SimulationResult`, `ComparisonResult` |
| 関数 | `to_simulation_result`, `nperiods`, `variable_names`, `summarize_result`, `compare_with_data` |
| 変換 | `NamedTuple → SimulationResult`・`DataSeries → SimulationResult` の統一変換 |

**境界**:
- モデル固有のロジックを持たない（モデル層に委譲）
- 可視化・LLM 呼び出しは行わない
- `SimulationResult` は可視化層・実データ接続層・LLM解釈層の共通入力型

---

### 3.3 可視化層（`src/core/visualization.jl`）

**責務**: `SimulationResult` を受け取り、グラフ・比較表示として出力する。

| 機能 | 概要 |
|---|---|
| 時系列プロット | `plot_result(result; vars, title)` — 単一シナリオの時系列 |
| IRF プロット | `plot_irf(result; vars)` — ゼロライン付きインパルス応答 |
| 比較プロット | `plot_comparison(results; var, labels)` — 複数シナリオの比較 |

**境界**:
- 入力は常に `SimulationResult`（モデルの内部実装に依存しない）
- グラフ描画ライブラリ（Plots.jl）は可視化層内部に閉じる
- LLM への出力はこの層の責務ではない

---

### 3.4 実データ接続層（`src/data/`）

**責務**: 外部データ（FRED・e-Stat）を取得・前処理し、モデル変数と対応づける。

| 機能 | 概要 |
|---|---|
| データ標準型 | `DataSeries` / `MacroDataset`（[利用ガイド](../data/data_series_guide.md)） |
| データ取得 | `FredClient` / `EStatClient` と `fetch_*_series` / `fetch_*_dataset`。fixture / live モード切り替え |
| 前処理 | `fill_missing`, `apply_log`, `difference`, `pct_change`, `moving_average`, `standardize`, `to_quarterly`, `to_annual` 等 |
| 比較用変換 | `to_simulation_result(series)` で `SimulationResult` 互換形式に変換 |

**境界**:
- 実データの取得・前処理は実データ接続層で完結する
- モデル層・シミュレーション層に外部データの依存を持ち込まない
- 実データとモデル変数の対応は [変数マッピング表](../data/variable_mapping.md) を参照する

---

### 3.5 ドキュメント/コンテキスト層（`src/llm/doc_context.jl`）

**責務**: `docs/` 以下の構造化ドキュメントを LLM が利用できる形で提供する（軽量 RAG）。

| 内容 | 場所 |
|---|---|
| docs 抜粋の構築 | `build_docs_excerpts(model)` → `DocsExcerpts` |
| モデル経済学的説明 | `docs/models/*.md` |
| 出力変数の解釈 | `docs/simulation_outputs.md` |

**境界**:
- ドキュメント/コンテキスト層は読み取り専用（ドキュメントの内容を更新しない）
- LLM への文脈提供のみを担う

---

### 3.6 LLM解釈層（`src/llm/analysis_context.jl`, `prompts.jl`, `provider.jl`）

**責務**: モデルメタ情報・ドキュメント抜粋・`SimulationResult` を `AnalysisContext` に集約し、自然言語による説明・要約を生成する。

| 機能 | 概要 |
|---|---|
| コンテキスト集約 | `AnalysisContext`（[設計](analysis_context.md)） — メタ情報・結果サマリー・データ比較・注意事項・docs 抜粋 |
| プロンプト生成 | `build_explain_prompt`, `build_data_comparison_prompt` |
| 説明生成 | `explain_result`, `explain_data_comparison`（caveats・免責付き構造化出力） |
| provider 抽象化 | `AbstractLLMProvider` / `MockLLMProvider` / `OpenAIProvider`, `create_provider`, `complete_from_prompt`（[設定ガイド](llm_provider.md)） |

**境界**:
- LLM呼び出しはこの層のみ（下位層は LLM に依存しない）
- 下位層の出力（`SimulationResult`、メタ情報、docs）を入力として受け取るのみ
- LLM の出力を `SimulationResult` に書き戻さない（一方向の流れ）
- 出力の安全性ルールは [llm_safety.md](../llm_safety.md) に従う

---

## 4. データフロー

### 4.1 基本フロー（モデル計算 → 可視化）

```
RamseyModel / RBCModel / ...
  │
  │ steady_state / transition_path / simulate / impulse_response
  ▼
NamedTuple（内部表現）
  │
  │ to_simulation_result
  ▼
SimulationResult
  │
  │ plot_result / plot_irf / plot_comparison
  ▼
グラフ出力
```

### 4.2 実データ比較フロー（モデル + 実データ → 比較）

```
AbstractMacroModel          外部データ（FRED / e-Stat）
  │                             │
  │ impulse_response 等         │ fetch_*_series + 前処理
  ▼                             ▼
SimulationResult（モデル）  DataSeries（実データ）
  │                             │
  │                             │ to_simulation_result
  │                             ▼
  │                        SimulationResult（実データ）
  └────────────┬────────────────┘
               │ compare_with_data(mapping = ...)
               ▼
      ComparisonResult（RMSE・相関等） / plot_comparison
```

**重要**: 実データとモデル変数の対応は [変数マッピング表](../data/variable_mapping.md) に従う。
単純な数値の一致をもって「モデルが現実を説明している」と主張しない。

### 4.3 LLM 説明フロー（docs + 計算結果 → 自然言語）

```
docs/models/*.md 等          SimulationResult / ComparisonResult
      │                             │
      │ build_docs_excerpts         │ サマリー化
      ▼                             ▼
DocsExcerpts ────────────► AnalysisContext ◄──── モデルメタ情報
                                 │
                                 │ build_explain_prompt
                                 ▼
                            LLM プロンプト
                                 │
                                 │ explain_result / complete_from_prompt
                                 ▼
                    自然言語説明（caveats・免責付き）
```

---

## 5. 実装ファイル配置

```
src/
  DME.jl
  core/
    model_interface.jl      # 共通インターフェース・メタ情報
    solver_options.jl       # 数値計算オプション
    simulation_result.jl    # SimulationResult・変換
    compare.jl              # 実データ比較（ComparisonResult）
    visualization.jl        # plot_result / plot_irf / plot_comparison
  models/
    ramsey.jl / solow.jl / rbc.jl / islm.jl / adas.jl /
    new_keynesian.jl / mundell_fleming.jl / var.jl
  numerics/
    grids.jl
    interpolation.jl
  data/
    data_series.jl          # DataSeries / MacroDataset
    preprocess.jl           # 前処理ユーティリティ
    fred.jl                 # FRED クライアント
    estat.jl                # e-Stat クライアント
  llm/
    analysis_context.jl     # AnalysisContext と構成型
    doc_context.jl          # docs 抜粋（軽量 RAG）
    prompts.jl              # プロンプト生成・説明生成
    provider.jl             # LLM provider 抽象化
```

詳細は[パッケージ構成とアーキテクチャ概要](package_structure.md)を参照。

---

## 6. 設計上の制約・原則

1. **単方向依存**: 上位層は下位層を呼び出すが、下位層は上位層を知らない。モデル層は LLM を呼び出さない
2. **LLM 非依存コア**: モデル層・シミュレーション層・可視化層は LLM なしで完全に動作する
3. **型による境界**: 層間のインターフェースは `SimulationResult` 型に集約する。`NamedTuple` は内部表現に留める
4. **実データとモデルの分離**: 実データの取得・前処理は実データ接続層に閉じる。モデル層は実データに依存しない
5. **ドキュメントは人間と LLM の両方のための一次資料**: `docs/` はコードと同等の成果物として管理する

---

## 7. 実装しないこと（明示的な非対象）

以下は将来的な方向性としても意図的に対象外とする。

| 項目 | 理由 |
|---|---|
| **LLM による自動予測** | 現行モデルは条件付きシミュレーションであり、将来の経済変数の予測ツールではない。LLM の出力をそのまま経済予測として扱うことは誤解を招く |
| **投資判断の自動化** | モデルの出力は「特定の仮定下での条件付き反応」であり、実際の投資判断に直結させることは設計外 |
| **実データとの無検証な同一視** | キャリブレーションなしにモデル変数と実データ値を直接比較・同一視しない |
| **外部モデルの自動評価** | LLM が DME 外の経済モデルを評価・比較する機能はスコープ外 |
| **リアルタイムデータ連携** | データ取得は明示的な呼び出しによる。自動ポーリング・イベント駆動取得は行わない |
