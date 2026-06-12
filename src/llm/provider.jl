# LLM provider 抽象化層
# LLM API 呼び出しはこのファイルに閉じる。モデル層・データ層・可視化層はこのファイルに依存しない。

"""
    LLMProviderError <: Exception

LLM provider に関するエラー。API キー未設定・タイムアウト・HTTP エラー等を表す。
"""
struct LLMProviderError <: Exception
    message::String
end

Base.showerror(io::IO, e::LLMProviderError) = print(io, "LLMProviderError: ", e.message)

"""
    LLMRequest

LLM への 1 回のリクエストを表す構造体。

## フィールド
- `system_prompt::String`  : システム指示（安全ルール・役割定義など）
- `user_prompt::String`    : ユーザープロンプト（シミュレーション結果等の文脈と指示）
- `max_tokens::Int`        : 最大出力トークン数（デフォルト: 2000）
- `temperature::Float64`   : サンプリング温度（デフォルト: 0.3）
"""
struct LLMRequest
    system_prompt::String
    user_prompt::String
    max_tokens::Int
    temperature::Float64
end

LLMRequest(
    system_prompt::String,
    user_prompt::String;
    max_tokens::Int = 2000,
    temperature::Float64 = 0.3,
) = LLMRequest(system_prompt, user_prompt, max_tokens, temperature)

"""
    LLMResponse

LLM からの応答を表す構造体。

## フィールド
- `content::String`               : 生成されたテキスト
- `model::String`                 : 使用されたモデル名
- `finish_reason::String`         : 終了理由（"stop", "length", "mock" 等）
- `input_tokens::Union{Int, Nothing}`  : 入力トークン数（取得できない場合は `nothing`）
- `output_tokens::Union{Int, Nothing}` : 出力トークン数（取得できない場合は `nothing`）
"""
struct LLMResponse
    content::String
    model::String
    finish_reason::String
    input_tokens::Union{Int, Nothing}
    output_tokens::Union{Int, Nothing}
end

# ===================================================================
# AbstractLLMProvider
# ===================================================================

"""
    AbstractLLMProvider

LLM provider の抽象型。各 provider は `complete(provider, request)` を実装する必要がある。

## 実装済み provider
- [`MockLLMProvider`](@ref): テスト・デモ用。LLM API を呼ばない。
- [`OpenAIProvider`](@ref): OpenAI Chat Completions API への接続。

## 独自 provider の実装方法

```julia
struct MyProvider <: AbstractLLMProvider
    # ...
end

function DME.complete(provider::MyProvider, request::DME.LLMRequest)::DME.LLMResponse
    # ... HTTP リクエスト等 ...
end
```
"""
abstract type AbstractLLMProvider end

"""
    complete(provider::AbstractLLMProvider, request::LLMRequest) -> LLMResponse

`request` を `provider` へ送信し、[`LLMResponse`](@ref) を返す。

各 provider サブタイプはこのメソッドを実装する。
未実装の provider に対しては `LLMProviderError` を送出する。
"""
function complete(provider::AbstractLLMProvider, ::LLMRequest)::LLMResponse
    throw(LLMProviderError("complete is not implemented for $(typeof(provider))"))
end

# ===================================================================
# MockLLMProvider
# ===================================================================

"""
    MockLLMProvider <: AbstractLLMProvider

テスト・デモ用の LLM provider。LLM API を一切呼ばず、決定的な mock 応答を返す。

OpenAI API キーが不要なため、テスト環境・CI・API キー未設定時のデモで利用できる。

## 使用例

```julia
provider = MockLLMProvider()
req = LLMRequest("システム指示", "ユーザー質問")
res = complete(provider, req)
println(res.content)
```
"""
struct MockLLMProvider <: AbstractLLMProvider
    response_template::String
end

"""
    MockLLMProvider() -> MockLLMProvider

デフォルトの mock 応答テンプレートで `MockLLMProvider` を作成する。
"""
MockLLMProvider() = MockLLMProvider(
    "[Mock LLM 応答] プロンプトを受信しました。" *
    "このシステムは学術的なマクロ経済モデルのシミュレーションツールであり、" *
    "実際の経済・市場の動向を予測するものではありません。" *
    "本出力は投資判断・政策立案の根拠として使用することを意図していません。",
)

function complete(provider::MockLLMProvider, request::LLMRequest)::LLMResponse
    content =
        provider.response_template *
        "\n\n[受信プロンプト長: system=$(length(request.system_prompt))文字, " *
        "user=$(length(request.user_prompt))文字]"
    LLMResponse(content, "mock", "mock", nothing, nothing)
end

# ===================================================================
# OpenAIProvider
# ===================================================================

"""
    OpenAIProvider <: AbstractLLMProvider

OpenAI Chat Completions API への接続を提供する LLM provider。

API キーは環境変数 `OPENAI_API_KEY` から読み込む（コードへの直書き禁止）。
タイムアウトと指数バックオフによるリトライを最低限サポートする。

## フィールド
- `api_key::String`              : OpenAI API キー
- `model::String`                : モデル名（例: `"gpt-4o-mini"`, `"gpt-4o"`）
- `timeout_seconds::Int`         : HTTP タイムアウト秒数
- `max_retries::Int`             : 最大リトライ回数
- `retry_delay_seconds::Float64` : リトライ間隔の基本秒数（指数バックオフ）

## 使用例

```julia
# 環境変数 OPENAI_API_KEY を設定してから使用する
# export OPENAI_API_KEY=sk-...
provider = OpenAIProvider()
req = LLMRequest(system_prompt, user_prompt)
res = complete(provider, req)
println(res.content)
```
"""
struct OpenAIProvider <: AbstractLLMProvider
    api_key::String
    model::String
    timeout_seconds::Int
    max_retries::Int
    retry_delay_seconds::Float64
end

"""
    OpenAIProvider(; model, timeout_seconds, max_retries, retry_delay_seconds) -> OpenAIProvider

環境変数から API キーと各設定値を読み込んで `OpenAIProvider` を作成する。

設定の優先順位: **キーワード引数 > 環境変数 > デフォルト値**

API キーが設定されていない場合は `LLMProviderError` を送出する。
テスト環境では [`MockLLMProvider`](@ref) または [`create_provider`](@ref) を使用すること。

## 設定可能な環境変数

| 環境変数 | 対応フィールド | デフォルト値 |
|---|---|---|
| `OPENAI_API_KEY` | `api_key` | （必須） |
| `OPENAI_MODEL` | `model` | `"gpt-4o-mini"` |
| `OPENAI_TIMEOUT_SECONDS` | `timeout_seconds` | `30` |
| `OPENAI_MAX_RETRIES` | `max_retries` | `3` |
| `OPENAI_RETRY_DELAY_SECONDS` | `retry_delay_seconds` | `1.0` |
"""
function OpenAIProvider(;
    model::Union{String, Nothing} = nothing,
    timeout_seconds::Union{Int, Nothing} = nothing,
    max_retries::Union{Int, Nothing} = nothing,
    retry_delay_seconds::Union{Float64, Nothing} = nothing,
)
    cfg = _load_openai_config()
    if isempty(cfg.api_key)
        throw(
            LLMProviderError(
                "OPENAI_API_KEY が見つかりません。" *
                "環境変数 OPENAI_API_KEY=sk-... を設定してから Julia を起動してください。" *
                "テスト・デモ用途では MockLLMProvider() または create_provider(use_mock=true) を使用してください。",
            ),
        )
    end
    OpenAIProvider(
        cfg.api_key,
        isnothing(model) ? cfg.model : model,
        isnothing(timeout_seconds) ? cfg.timeout_seconds : timeout_seconds,
        isnothing(max_retries) ? cfg.max_retries : max_retries,
        isnothing(retry_delay_seconds) ? cfg.retry_delay_seconds : retry_delay_seconds,
    )
end

"""
    OpenAIProvider(api_key::String; kwargs...) -> OpenAIProvider

API キーを直接指定して `OpenAIProvider` を作成する。

**注意**: API キーのコードへの直書きは禁止。テスト用途でのみ使用可。
"""
function OpenAIProvider(
    api_key::String;
    model::String = "gpt-4o-mini",
    timeout_seconds::Int = 30,
    max_retries::Int = 3,
    retry_delay_seconds::Float64 = 1.0,
)
    isempty(api_key) && throw(LLMProviderError("api_key は空文字列にできません"))
    OpenAIProvider(api_key, model, timeout_seconds, max_retries, retry_delay_seconds)
end

# OpenAIProvider のデフォルト値
const _DEFAULT_OPENAI_MODEL = "gpt-4o-mini"
const _DEFAULT_OPENAI_TIMEOUT = 30
const _DEFAULT_OPENAI_MAX_RETRIES = 3
const _DEFAULT_OPENAI_RETRY_DELAY = 1.0

# Internal: 解決済み設定のホルダー
struct _OpenAIConfig
    api_key::String
    model::String
    timeout_seconds::Int
    max_retries::Int
    retry_delay_seconds::Float64
end

# 環境変数から OpenAI の全設定値を解決する
# 優先順位: 環境変数 > デフォルト値
function _load_openai_config()::_OpenAIConfig
    _env(key) =
        let v = get(ENV, key, "");
            isempty(v) ? nothing : v
        end
    api_key = something(_env("OPENAI_API_KEY"), "")
    model = something(_env("OPENAI_MODEL"), _DEFAULT_OPENAI_MODEL)
    timeout = let s = _env("OPENAI_TIMEOUT_SECONDS")
        isnothing(s) ? _DEFAULT_OPENAI_TIMEOUT :
        something(tryparse(Int, s), _DEFAULT_OPENAI_TIMEOUT)
    end
    max_retries = let s = _env("OPENAI_MAX_RETRIES")
        isnothing(s) ? _DEFAULT_OPENAI_MAX_RETRIES :
        something(tryparse(Int, s), _DEFAULT_OPENAI_MAX_RETRIES)
    end
    retry_delay = let s = _env("OPENAI_RETRY_DELAY_SECONDS")
        isnothing(s) ? _DEFAULT_OPENAI_RETRY_DELAY :
        something(tryparse(Float64, s), _DEFAULT_OPENAI_RETRY_DELAY)
    end
    _OpenAIConfig(api_key, model, timeout, max_retries, retry_delay)
end

const _OPENAI_CHAT_URL = "https://api.openai.com/v1/chat/completions"

function complete(provider::OpenAIProvider, request::LLMRequest)::LLMResponse
    body = JSON3.write(
        Dict(
            "model" => provider.model,
            "messages" => Any[
                Dict("role" => "system", "content" => request.system_prompt),
                Dict("role" => "user", "content" => request.user_prompt),
            ],
            "max_tokens" => request.max_tokens,
            "temperature" => request.temperature,
        ),
    )
    raw = _openai_request_with_retry(
        provider.api_key,
        body,
        provider.timeout_seconds,
        provider.max_retries,
        provider.retry_delay_seconds,
    )
    _parse_openai_response(raw, provider.model)
end

function _openai_request_with_retry(
    api_key::String,
    body::String,
    timeout_seconds::Int,
    max_retries::Int,
    retry_delay::Float64,
)::String
    last_error = nothing
    for attempt in 1:max_retries
        try
            return _openai_http_post(api_key, body, timeout_seconds)
        catch e
            last_error = e
            attempt < max_retries && sleep(retry_delay * attempt)
        end
    end
    throw(
        LLMProviderError("OpenAI API リクエストが $(max_retries) 回のリトライ後に失敗しました: $(last_error)"),
    )
end

function _openai_http_post(api_key::String, body::String, timeout_seconds::Int)::String
    output = IOBuffer()
    resp = try
        Downloads.request(
            _OPENAI_CHAT_URL;
            method = "POST",
            headers = [
                "Authorization" => "Bearer $(api_key)",
                "Content-Type" => "application/json",
            ],
            input = IOBuffer(body),
            output = output,
            timeout = Float64(timeout_seconds),
        )
    catch e
        throw(LLMProviderError("OpenAI への HTTP リクエストが失敗しました: $(e)"))
    end
    resp.status == 200 ||
        throw(LLMProviderError("OpenAI API HTTP エラー: ステータス $(resp.status)"))
    String(take!(output))
end

function _parse_openai_response(raw::String, model::String)::LLMResponse
    parsed = try
        JSON3.read(raw)
    catch e
        throw(LLMProviderError("OpenAI レスポンス JSON のパースに失敗しました: $(e)"))
    end

    if haskey(parsed, :error)
        err = parsed[:error]
        msg = haskey(err, :message) ? string(err[:message]) : "unknown error"
        throw(LLMProviderError("OpenAI API エラー: $(msg)"))
    end

    (haskey(parsed, :choices) && !isempty(parsed[:choices])) ||
        throw(LLMProviderError("OpenAI レスポンスに choices がありません: $(first(raw, 200))"))

    first_choice = parsed[:choices][1]
    message = first_choice[:message]
    content = string(message[:content])
    finish_reason =
        haskey(first_choice, :finish_reason) ? string(first_choice[:finish_reason]) :
        "unknown"

    input_tokens = nothing
    output_tokens = nothing
    if haskey(parsed, :usage)
        usage = parsed[:usage]
        input_tokens = haskey(usage, :prompt_tokens) ? Int(usage[:prompt_tokens]) : nothing
        output_tokens =
            haskey(usage, :completion_tokens) ? Int(usage[:completion_tokens]) : nothing
    end

    resp_model = haskey(parsed, :model) ? string(parsed[:model]) : model
    LLMResponse(content, resp_model, finish_reason, input_tokens, output_tokens)
end

# ===================================================================
# ファクトリ・ヘルパー
# ===================================================================

"""
    create_provider(; use_mock, model, timeout_seconds, max_retries, retry_delay_seconds) -> AbstractLLMProvider

環境変数 `OPENAI_API_KEY` の有無に基づいて適切な provider を返すファクトリ関数。

- `use_mock=true` を指定すると [`MockLLMProvider`](@ref) を返す。
- `OPENAI_API_KEY` が設定されている場合は [`OpenAIProvider`](@ref) を返す。
- `OPENAI_API_KEY` が未設定の場合は警告を出しつつ [`MockLLMProvider`](@ref) にフォールバックする。

テスト・CI では `use_mock=true` を明示的に指定することを推奨する。

## 使用例

```julia
# テスト・CI: mock を明示
provider = create_provider(use_mock=true)

# 本番: 環境変数から自動判定
provider = create_provider()

res = complete(provider, LLMRequest(system_prompt, user_prompt))
```
"""
function create_provider(;
    use_mock::Bool = false,
    model::Union{String, Nothing} = nothing,
    timeout_seconds::Union{Int, Nothing} = nothing,
    max_retries::Union{Int, Nothing} = nothing,
    retry_delay_seconds::Union{Float64, Nothing} = nothing,
)::AbstractLLMProvider
    use_mock && return MockLLMProvider()
    cfg = _load_openai_config()
    if isempty(cfg.api_key)
        @warn "OPENAI_API_KEY が見つからないため MockLLMProvider にフォールバックします。" *
              " 環境変数 OPENAI_API_KEY を設定してから Julia を起動してください。"
        return MockLLMProvider()
    end
    OpenAIProvider(
        cfg.api_key,
        isnothing(model) ? cfg.model : model,
        isnothing(timeout_seconds) ? cfg.timeout_seconds : timeout_seconds,
        isnothing(max_retries) ? cfg.max_retries : max_retries,
        isnothing(retry_delay_seconds) ? cfg.retry_delay_seconds : retry_delay_seconds,
    )
end

"""
    complete_from_prompt(provider, full_prompt; max_tokens, temperature) -> LLMResponse

`build_explain_prompt` / `build_data_comparison_prompt` が返す結合プロンプト文字列を
[`LLMRequest`](@ref) に変換して `complete` を呼ぶ。

`"\\n---\\n"` を区切り文字としてシステムプロンプトとユーザープロンプトに分割する。
区切りが見つからない場合は全文をユーザープロンプトとして扱う。

## 使用例

```julia
provider = create_provider(use_mock=true)
prompt = build_explain_prompt(ctx)
res = complete_from_prompt(provider, prompt)
println(res.content)
```
"""
function complete_from_prompt(
    provider::AbstractLLMProvider,
    full_prompt::String;
    max_tokens::Int = 2000,
    temperature::Float64 = 0.3,
)::LLMResponse
    parts = split(full_prompt, "\n---\n"; limit = 2)
    request = if length(parts) == 2
        LLMRequest(parts[1], parts[2], max_tokens, temperature)
    else
        LLMRequest("", full_prompt, max_tokens, temperature)
    end
    complete(provider, request)
end
