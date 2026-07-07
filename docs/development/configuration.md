# 設定・環境変数管理ガイド

実データ・LLM 機能で利用する外部 API（FRED・e-Stat・OpenAI 等）の設定方法と、API キーなしでも動作させる方法を説明します。

## 概要

DME は以下の 3 段階でデータ取得モードを切り替えられます：

| モード | 説明 | API キー | 用途 |
|---|---|---|---|
| `fixture` | ローカルの fixture データを使用 | 不要 | テスト・デモ・CI（**デフォルト**） |
| `mock` | インメモリのモックプロバイダーを使用 | 不要 | ユニットテスト |
| `live` | 実際の外部 API を使用 | 必要 | 本番・実データ分析 |

API キーが未設定の場合は自動的に `fixture` モードにフォールバックするため、**API キーなしでもテストとデモが動きます**。

## クイックスタート

### 1. `.env` ファイルを作成する

```bash
cp .env.example .env
```

`.env` を開き、使用する API のキーを設定してください。設定しなかった項目は fixture モードで動作します。

### 2. （オプション）設定ファイルを作成する

```bash
cp config/dme.example.toml config/dme.toml
```

より詳細な設定（タイムアウト・デフォルト取得期間など）が必要な場合に使用します。

## 環境変数一覧

| 変数名 | 説明 | 必須 | 取得先 |
|---|---|---|---|
| `FRED_API_KEY` | FRED API キー | live モード時のみ | [fred.stlouisfed.org](https://fred.stlouisfed.org/docs/api/api_key.html) |
| `ESTAT_APP_ID` | e-Stat API アプリケーション ID | live モード時のみ | [api.e-stat.go.jp](https://api.e-stat.go.jp/) |
| `OPENAI_API_KEY` | OpenAI API キー | LLM 機能使用時のみ | [platform.openai.com](https://platform.openai.com/api-keys) |
| `DME_DATA_MODE` | データ取得モード (`live`/`fixture`/`mock`) | 任意 | — |
| `DME_API_TIMEOUT` | API タイムアウト（秒、デフォルト: 30） | 任意 | — |
| `DME_LOG_LEVEL` | ログレベル (`debug`/`info`/`warn`/`error`) | 任意 | — |

## fixture モード（API キーなし）での動作

`DME_DATA_MODE=fixture`（デフォルト）に設定すると、`test/fixtures/` 以下のローカルデータを使用します。これにより：

- FRED・e-Stat・OpenAI の API キーが不要
- ネットワーク接続なしで動作
- CI/CD で秘密情報なしでテストが通る

```bash
# fixture モードで明示的に起動する場合
export DME_DATA_MODE=fixture
julia --project=. examples/real_data_demo.jl
```

## CI での運用方針

CI（GitHub Actions）では **API キーを使用せず** `fixture` モードでテストを実行します。

- CI に API キーを登録する必要はありません
- `Pkg.test()` は `DME_DATA_MODE=fixture`（または未設定）で動作することを保証します
- 実データを使った統合テストはローカル環境で手動実行してください

## セキュリティ上の注意

- `.env` は絶対に git にコミットしないこと（`.gitignore` に登録済み）
- `config/dme.toml` も同様（`.gitignore` に登録済み）
- API キーをコードに直書きしないこと
- `config/dme.example.toml` や `.env.example` にも実際の API キーを記載しないこと

## ファイル構成

```
.env.example          # 環境変数サンプル（git 管理対象）
.env                  # 実際の環境変数（git 管理対象外）
config/
  dme.example.toml    # 設定ファイルサンプル（git 管理対象）
  dme.toml            # 実際の設定ファイル（git 管理対象外）
```

## 関連ドキュメント

- [AIエコノミスト化アーキテクチャ](../architecture/ai_economist.md) — データ層・LLM 層の全体設計
- [モデル変数と実データ系列のマッピング表](../data/variable_mapping.md) — 使用するデータ系列の一覧
- [実データ前処理ユーティリティ](../data/preprocess.md) — データ取得後の前処理
