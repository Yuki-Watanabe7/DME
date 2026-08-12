# DME

DME は動学的マクロ経済モデルを Julia で実装したパッケージです。モデル群（Ramsey / Solow /
RBC / IS-LM / AD-AS / New Keynesian / Mundell-Fleming / VAR / Keen / SFC / 部門別CAPEX・
信用循環）の計算・可視化に加え、実データ接続（FRED・e-Stat）と LLM による結果説明生成を
サポートします。

## このサイトの位置づけ

このサイトは **`src/**.jl` の docstring から機械的に生成される API リファレンス**です。
DME は Documenter.jl を「公開サイトの生成器」ではなく **docstring のビルド検査器** として
採用しており、GitHub Pages への公開は行っていません（決定の記録は
[ADR 0017](https://github.com/Yuki-Watanabe7/DME/blob/main/docs/adr/0017-documenter-adoption-and-docs-quality-export.md)）。

そのため、**読み物としてのドキュメントはリポジトリ内の Markdown が正典**です。

| 目的 | 参照先 |
|---|---|
| API の一覧・シグネチャ・移行ガイド（人手で整備した正典） | [`docs/api.md`](https://github.com/Yuki-Watanabe7/DME/blob/main/docs/api.md) |
| 各モデルの解説 | [`docs/models/`](https://github.com/Yuki-Watanabe7/DME/tree/main/docs/models) |
| アーキテクチャ・設計 | [`docs/architecture/`](https://github.com/Yuki-Watanabe7/DME/tree/main/docs/architecture) |
| 設計決定記録（ADR） | [`docs/adr/`](https://github.com/Yuki-Watanabe7/DME/tree/main/docs/adr) |
| ドキュメント全体の索引 | [README](https://github.com/Yuki-Watanabe7/DME/blob/main/README.md#ドキュメント) |

## API リファレンス

`src/` のディレクトリ構成に対応した6ページに分かれています。

- [コアインターフェース](api/core.md) — 共通インターフェース・`SimulationResult`・比較・可視化・数値ユーティリティ・CLI
- [モデル](api/models.md) — 各モデルの型・構築・シミュレーション
- [実データ層](api/data.md) — `DataSeries`・前処理・FRED / e-Stat クライアント
- [分析・診断層](api/analysis.md) — 較正・検証・診断・SFC 会計
- [LLM層](api/llm.md) — `AnalysisContext`・プロンプト・provider 抽象化
- [Artifact・品質Export層](api/artifacts.md) — 正準 JSON・real-rate model artifact・Julia品質Export
