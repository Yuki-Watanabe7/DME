# LLM Provider 抽象化と設定ガイド

> 関連Issue: #74

---

## 1. 概要

`src/llm/provider.jl` は LLM provider の抽象化層を提供する。
`AbstractLLMProvider` を実装することで、OpenAI・モック・将来の別プロバイダを差し替え可能な設計にしている。

**設計原則**: LLM API 呼び出しはこのファイルに閉じる。モデル層・データ層・可視化層はこのファイルに依存しない（[llm_layer.md セクション7](llm_layer.md) 参照）。

---

## 2. 主要な型と関数

| 型 / 関数 | 説明 |
|---|---|
| `AbstractLLMProvider` | provider の抽象基底型 |
| `LLMRequest` | LLM への 1 リクエスト（system prompt / user prompt / オプション） |
| `LLMResponse` | LLM からの応答（content / model / finish_reason / token usage） |
| `MockLLMProvider` | テスト・デモ用 mock（API 呼び出しなし） |
| `OpenAIProvider` | OpenAI Chat Completions API 接続 |
| `complete(provider, request)` | リクエストを送信して応答を返す |
| `create_provider(; kwargs...)` | 環境変数から適切な provider を自動選択するファクトリ |
| `complete_from_prompt(provider, prompt)` | `build_explain_prompt` 等の出力を直接渡せるヘルパー |
| `LLMProviderError` | API キー未設定・タイムアウト等のエラー型 |

---

## 3. OpenAI API の設定方法

### 3.1 設定可能なパラメータ一覧

すべてのパラメータは **環境変数** で外部設定できる。

設定の優先順位: **キーワード引数 > 環境変数 > デフォルト値**

| 環境変数 | 対応パラメータ | デフォルト値 | 説明 |
|---|---|---|---|
| `OPENAI_API_KEY` | `api_key` | （必須） | OpenAI API キー |
| `OPENAI_MODEL` | `model` | `"gpt-4o-mini"` | 使用するモデル名 |
| `OPENAI_TIMEOUT_SECONDS` | `timeout_seconds` | `30` | HTTP タイムアウト秒数 |
| `OPENAI_MAX_RETRIES` | `max_retries` | `3` | 最大リトライ回数 |
| `OPENAI_RETRY_DELAY_SECONDS` | `retry_delay_seconds` | `1.0` | リトライ間隔の基本秒数（指数バックオフ） |

### 3.2 環境変数で設定する

`.env` ファイルを使う場合は、Julia 起動前に自分で `source` する。アプリケーション側は `.env` ファイルを直接読まない。

```bash
# .env に記載した上で source してから Julia を起動する
source .env
julia --project=.
```

または恒久的に設定する場合:

```bash
# ~/.zshrc または ~/.bashrc に追記
export OPENAI_API_KEY="sk-..."
export OPENAI_MODEL="gpt-4o-mini"
export OPENAI_TIMEOUT_SECONDS="30"
export OPENAI_MAX_RETRIES="3"
export OPENAI_RETRY_DELAY_SECONDS="1.0"
```

### 3.3 Julia セッション内で設定する場合

```julia
ENV["OPENAI_API_KEY"] = "sk-..."        # セッション内のみ有効
ENV["OPENAI_MODEL"] = "gpt-4o"
ENV["OPENAI_TIMEOUT_SECONDS"] = "60"
```

### 3.4 動作確認

```julia
using DME

# 環境変数から自動選択（推奨）
provider = create_provider()

# キーワード引数で一部だけ上書きする場合
provider = create_provider(model = "gpt-4o", timeout_seconds = 60)

# リクエスト送信
req = LLMRequest("あなたはマクロ経済分析AIです。", "このモデルを説明してください。")
res = complete(provider, req)
println(res.content)
```

---

## 4. テスト・CI での使い方（API キー不要）

テストや CI では `MockLLMProvider` または `create_provider(use_mock=true)` を使う。

```julia
# 明示的に mock を使う
provider = MockLLMProvider()

# or: ファクトリ経由
provider = create_provider(use_mock = true)

req = LLMRequest("system", "user")
res = complete(provider, req)
println(res.content)  # mock 応答が返る
```

`MockLLMProvider` はLLM API を呼ばないため：
- `OPENAI_API_KEY` が不要
- 決定的な応答を返す
- CI・オフライン環境で安定動作する

---

## 5. プロンプト生成との連携

`build_explain_prompt` / `build_data_comparison_prompt` が返す結合プロンプト文字列を
`complete_from_prompt` に渡すことで、プロンプト生成から LLM 呼び出しまでをつなげられる。

```julia
using DME

rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
irf = impulse_response(rbc, 0.01)
sr  = to_simulation_result(rbc, irf, "technology_shock")
ctx = AnalysisContext(rbc, sr; shock_description = "1% positive technology shock")

# プロンプト生成
prompt = build_explain_prompt(ctx)

# LLM に送信（mock または実 API）
provider = create_provider(use_mock = true)  # API キー不要
res = complete_from_prompt(provider, prompt)
println(res.content)
```

---

## 6. API キー未設定時の挙動

| 状況 | 挙動 |
|---|---|
| `OpenAIProvider()` を呼ぶが `OPENAI_API_KEY` 未設定 | `LLMProviderError` を送出 |
| `create_provider()` を呼ぶが `OPENAI_API_KEY` 未設定 | 警告ログを出して `MockLLMProvider` にフォールバック |
| `create_provider(use_mock=true)` | 常に `MockLLMProvider`（エラーなし） |

---

## 7. 独自 provider の実装方法

`AbstractLLMProvider` を継承し、`complete` を実装することで provider を差し替えられる。

```julia
struct MyProvider <: AbstractLLMProvider
    # ...
end

function DME.complete(provider::MyProvider, request::DME.LLMRequest)::DME.LLMResponse
    # ... HTTP リクエスト等 ...
    DME.LLMResponse(content, "my-model", "stop", nothing, nothing)
end
```

---

## 8. タイムアウト・リトライ設定

`OpenAIProvider` はタイムアウトと指数バックオフによるリトライをサポートする。

設定方法は 2 通り（優先順位: コード引数 > 環境変数 > デフォルト）:

```bash
# 環境変数で設定（コードを変更しなくて済む）
export OPENAI_TIMEOUT_SECONDS=60
export OPENAI_MAX_RETRIES=5
export OPENAI_RETRY_DELAY_SECONDS=2.0
```

```julia
# Julia コード内でキーワード引数を使って上書き
provider = OpenAIProvider(;
    timeout_seconds = 60,      # タイムアウト秒数（デフォルト: 30）
    max_retries = 5,           # 最大リトライ回数（デフォルト: 3）
    retry_delay_seconds = 2.0, # リトライ間隔基本秒数（デフォルト: 1.0）
)
```

---

## 9. 非対象（スコープ外）

| 項目 | 理由 |
|---|---|
| streaming response | 後続 Issue で対応 |
| tool calling / function calling | 後続 Issue で対応 |
| 複数 provider の本格的なロードバランシング | 後続 Issue で対応 |
| コスト最適化・キャッシュ本格実装 | 後続 Issue で対応 |
