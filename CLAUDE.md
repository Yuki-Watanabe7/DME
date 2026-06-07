# CLAUDE.md

DME は動学的マクロ経済モデル（Ramsey・RBC）を Julia で実装したパッケージです。
このファイルは Claude Code がこのリポジトリで作業する際の入口ガイドです。

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

| ドキュメント | 内容 |
|---|---|
| [API リファレンス](docs/api.md) | Public/Internal API の一覧・シグネチャ・移行ガイド |
| [モデル共通インターフェース](docs/architecture/model_interface.md) | 抽象型階層・命名方針・新規モデル追加ルール |
| [パッケージ構成とアーキテクチャ概要](docs/architecture/package_structure.md) | ソースツリー・include 順序・Node 型階層・補間・モデル内部関数 |
| [AIエコノミスト化アーキテクチャ](docs/architecture/ai_economist.md) | Phase 3 以降の層構成・データフロー |
| [LLM接続層の設計](docs/architecture/llm_layer.md) | LLM層の責務・入出力仕様・禁止事項・安全性方針 |
| [LLM出力の安全性・免責・禁止表現ルール](docs/llm_safety.md) | 禁止表現・必須記載・プロンプトテンプレート・出力チェックリスト |
| [Ramsey モデル解説](docs/models/ramsey.md) | 目的・変数・パラメータ・出力・限界 |
| [RBC モデル解説](docs/models/rbc.md) | 目的・変数・パラメータ・IRF・限界 |
| [出力結果の読み方](docs/simulation_outputs.md) | 定常状態・移行経路・IRF・水準/対数偏差の概念 |
| [品質チェックとローカル検証手順](docs/development/quality_checks.md) | Aqua.jl・JuliaFormatter・JET.jl 見送り理由・テスト実行方法 |
| [依存パッケージ管理と注意点](docs/development/dependency_management.md) | JuMP・Interpolations・NLsolve の注意点・Manifest.toml 管理 |
| [小国開放経済モデル設計方針](docs/models/open_economy_design.md) | 候補モデル比較・最小実装選定（Mundell-Fleming）・実データ候補系列 |
| [モデル変数と実データ系列のマッピング表](docs/data/variable_mapping.md) | 各モデル変数と候補実データ系列の対応・単位・変換注意事項 |
| [実データ前処理ユーティリティ](docs/data/preprocess.md) | 欠損値補完・対数・差分・移動平均・標準化・頻度変換などの使用例 |
| [FRED API 接続ガイド](docs/data/fred.md) | FRED API クライアントの使い方・API キー設定・fixture モード |
