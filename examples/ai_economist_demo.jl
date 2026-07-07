# examples/ai_economist_demo.jl
#
# DME AIエコノミスト統合デモ
#
# モデル選択 → シミュレーション → 実データ取得/fixture → 前処理 →
# SimulationResult 変換 → モデル結果比較 → AnalysisContext 生成 →
# docs 参照コンテキスト追加 → LLM 説明生成 という一連のフローを示す。
#
# 実行方法:
#   julia --project=. examples/ai_economist_demo.jl
#
# モード選択:
#   【デフォルト】API キー不要（fixture データ + Mock LLM）
#
#   【実データ + Mock LLM】
#     export FRED_API_KEY=your_api_key_here
#     export DME_DATA_MODE=live
#     julia --project=. examples/ai_economist_demo.jl
#
#   【実データ + 実 LLM（OpenAI）】
#     export FRED_API_KEY=your_api_key_here
#     export DME_DATA_MODE=live
#     export OPENAI_API_KEY=sk-...
#     julia --project=. examples/ai_economist_demo.jl
#
#   FRED API キー:   https://fred.stlouisfed.org/docs/api/api_key.html
#   OpenAI API キー: https://platform.openai.com/api-keys

using DME
using Statistics: mean, std

println("""
╔═══════════════════════════════════════════════════════════════════╗
║   DME AIエコノミスト統合デモ                                      ║
╚═══════════════════════════════════════════════════════════════════╝

このデモは「AIエコノミスト」としての DME が一連のフローで機能する様子を示す。

  Step 1  モデル選択        ─ 問いに応じたモデルを選択する
  Step 2  シミュレーション  ─ RBC 技術ショック IRF を計算する
  Step 3  実データ取得      ─ FRED fixture（または live API）
  Step 4  前処理            ─ 対数・標準化・周波数変換
  Step 5  モデル結果比較    ─ RBC IRF vs 実 GDP（標準化比較）
  Step 6  AnalysisContext   ─ LLM へ渡す構造化コンテキストを構築する
  Step 7  docs 参照コンテキスト ─ docs/ 抜粋を RAG 的に埋め込む
  Step 8  LLM 説明生成      ─ モデル結果 + 実データ比較の自然言語説明
""")


# ─────────────────────────────────────────────────────────────────
# Step 1  モデル選択
# ─────────────────────────────────────────────────────────────────
println("=" ^ 68)
println("Step 1  モデル選択")
println("=" ^ 68)

println("""
問い: 「技術ショックは産出・消費・資本にどのような動態をもたらすか？」

この問いには「景気変動・技術ショックの短中期動態」を分析する
RBC（リアル・ビジネス・サイクル）モデルが適切。

他のモデルとの使い分け:
  Ramsey / Solow → 長期成長・最適貯蓄
  IS-LM / New Keynesian → 短期政策効果・名目硬直性
  Mundell-Fleming → 開放経済・為替の政策効果

→ 今回は RBC モデルを選択する。
""")

rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)  # α, β, γ, δ, μ, ρ
println("選択モデル: $(model_name(rbc))")
println("状態変数:   $(state_variables(rbc))")
println("制御変数:   $(control_variables(rbc))")

ep = steady_state(rbc)
println("\n[定常状態]")
println("  K* = $(round(ep.K, digits=4))  Y* = $(round(ep.Y, digits=4))" *
        "  C* = $(round(ep.C, digits=4))  L* = $(round(ep.L, digits=4))")


# ─────────────────────────────────────────────────────────────────
# Step 2  シミュレーション — RBC 技術ショック IRF
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 68)
println("Step 2  シミュレーション — RBC 技術ショック IRF")
println("=" ^ 68)

# 技術ショック（ε₀ = 1%）のインパルス応答
# 返り値: 定常状態からの対数偏差 (ĉ, k̂, ŷ, l̂ など)
irf = impulse_response(rbc, 0.01; maxT=40)
model_sr = to_simulation_result(rbc, irf, "technology_shock_1pct")

println("[技術ショック IRF]  ε₀ = 1%（対数偏差, T = $(nperiods(model_sr)) 期）")
sum_model = summarize_result(model_sr)
for var in ["ŷ", "ĉ", "k̂", "l̂"]
    s = sum_model["variables"][var]
    println("  $var: peak = $(round(s.peak_response, digits=5)) (t=$(s.argmax - 1))" *
            "  sign_reversal = $(s.sign_reversal)")
end

# プロット（変数名保持、savefig はコメントアウト）
p_irf = plot_irf(model_sr;
    vars   = ["ŷ", "ĉ", "k̂"],
    title  = "RBC: 技術ショック IRF（ε₀ = 1%）",
    ylabel = "Log deviation from SS",
)
# savefig(p_irf, "rbc_irf.png")
println("  → p_irf を生成: RBC 技術ショック IRF（ŷ, ĉ, k̂）")


# ─────────────────────────────────────────────────────────────────
# Step 3  実データ取得 — FRED
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 68)
println("Step 3  実データ取得 — FRED")
println("=" ^ 68)

# FredClient は環境変数 DME_DATA_MODE / FRED_API_KEY を見てモードを自動選択:
#   FRED_API_KEY 未設定 → fixture モード（test/fixtures/fred/*.json を使用）
#   FRED_API_KEY 設定済み → live モード（実 API を呼び出し）
fred_client = FredClient()
println("FredClient モード: $(fred_client.mode)")

# 実 GDP（四半期）を取得
gdp_raw = fetch_fred_series("GDPC1"; client=fred_client)
println("\n[GDPC1 取得]")
println("  名称: $(gdp_raw.name)")
println("  出所: $(gdp_raw.source)")
println("  頻度: $(gdp_raw.frequency)")
println("  単位: $(gdp_raw.unit)")
println("  期間: $(first(gdp_raw.dates)) 〜 $(last(gdp_raw.dates))  ($(length(gdp_raw)) 観測点)")

# GDP に加えて CPI・FF 金利・失業率も取得してデータセットを構成する
dataset = fetch_fred_dataset(
    ["GDPC1", "CPIAUCSL", "FEDFUNDS", "UNRATE"];
    client = fred_client,
    name   = "RBC 比較用 FRED データセット",
)
println("\n[MacroDataset 取得]")
println("  系列数: $(length(dataset))  ($(sort(series_ids(dataset))))")


# ─────────────────────────────────────────────────────────────────
# Step 4  前処理
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 68)
println("Step 4  前処理")
println("=" ^ 68)

gdp = get_series(dataset, "FRED_GDPC1")

# 4a. 対数変換 → 前年同期比成長率（景気変動の可視化）
println("[4a. GDP: apply_log → pct_change(periods=4) — 前年同期比成長率]")
gdp_log = apply_log(gdp)
gdp_yoy = pct_change(gdp_log; periods=4)
yoy_vals = nonmissing_values(gdp_yoy)
if !isempty(yoy_vals)
    println("  期間: $(first(gdp_yoy.dates)) 〜 $(last(gdp_yoy.dates))  ($(length(gdp_yoy)) 点)")
    println("  前年比成長率 [%]: 最小 $(round(minimum(yoy_vals), digits=2))  最大 $(round(maximum(yoy_vals), digits=2))")
end

# 4b. 標準化（z スコア）— RBC IRF との単位非依存比較に使用
println("\n[4b. GDP: standardize — モデル IRF との z スコア比較用]")
gdp_std = standardize(gdp)
std_vals = nonmissing_values(gdp_std)
if !isempty(std_vals)
    println("  標準化後: 平均 ≈ $(round(mean(std_vals), digits=4))  標準偏差 ≈ $(round(std(std_vals), digits=4))")
end


# ─────────────────────────────────────────────────────────────────
# Step 5  モデル結果と実データの比較
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 68)
println("Step 5  モデル結果と実データの比較")
println("=" ^ 68)

println("""
[単位注記]
  ŷ         : RBC 技術ショック IRF の対数偏差（例: 0.014 ≈ +1.4% 偏差）
  FRED_GDPC1: 兆ドル単位の実水準（例: 18000–19000 Bil. USD）
  → 生水準の直接比較は意味がないため、標準化（z スコア）で比較する。
  → 相関係数がコア指標（スケール非依存）。
""")

data_std_sr = to_simulation_result(gdp_std, "actual_gdp_standardized")
cr = compare_with_data(model_sr, data_std_sr; mapping=Dict("ŷ" => "FRED_GDPC1"))
m = cr.variables["ŷ"]

println("[標準化後の比較結果]")
println("  比較期間数: $(m.n_periods)")
println("  RMSE:       $(round(m.rmse,        digits=4))")
println("  MAE:        $(round(m.mae,         digits=4))")
println("  相関係数:   $(round(m.correlation, digits=4))")
println("""
  解釈: 相関係数 ≈ $(round(m.correlation, digits=2)) — RBC 技術ショック IRF の動態形状と
        実 GDP の変動には$(abs(m.correlation) < 0.3 ? "弱い" : abs(m.correlation) < 0.6 ? "中程度の" : "強い")相関がある（参考比較）。
        キャリブレーションなしの参考比較であり、モデルの妥当性評価ではない。
""")

# DataComparisonSummary — AnalysisContext への入力用
dcs = to_data_comparison_summary(
    cr;
    caveats = [
        "ŷ は RBC 技術ショック IRF の対数偏差",
        "FRED_GDPC1 は z スコア標準化済み（キャリブレーションなし）",
        "fixture データ使用の場合は実データと異なる可能性あり",
    ],
)

# プロット
p_gdp_std = plot_result(data_std_sr;
    title  = "実 GDP（FRED GDPC1）— 標準化",
    xlabel = "Period",
    ylabel = "z score",
)
# savefig(p_gdp_std, "gdp_standardized.png")
println("  → p_gdp_std を生成: 実 GDP 標準化系列")


# ─────────────────────────────────────────────────────────────────
# Step 6  AnalysisContext 生成
# ─────────────────────────────────────────────────────────────────
println("=" ^ 68)
println("Step 6  AnalysisContext 生成")
println("=" ^ 68)

ctx = AnalysisContext(
    rbc,
    model_sr;
    shock_description = "1% positive technology shock (ε₀ = 0.01)",
    data_comparison_summary = dcs,
    caveats = Caveats(
        [
            "Closed economy (no international trade or capital flows)",
            "Representative agent (no heterogeneity)",
            "Log-linearized around deterministic steady state",
            "Frictionless labor and capital markets",
        ],
        [
            "Fixture data: FRED GDPC1, 2018-Q1 to 2020-Q4 (12 obs)",
            "Standardized for unit-invariant comparison (not calibrated)",
        ],
        [
            "ŷ is log deviation from steady state, not growth rate",
            "RMSE reflects scale difference, correlation is the core metric",
            "Reference comparison only — not a formal model evaluation",
        ],
    ),
)

println("[AnalysisContext 構築完了]")
println("  モデル:       $(ctx.model_metadata.model_name)")
println("  シナリオ:     $(ctx.simulation_result_summary.scenario_name)")
println("  期間数:       $(ctx.simulation_result_summary.n_periods)")
cmp_status = ctx.data_comparison_summary !== nothing ?
    "設定済み ($(ctx.data_comparison_summary.data_source))" : "なし"
println("  実データ比較: $cmp_status")

# to_compact_dict でトークン効率の良い形式に変換
ctx_dict = to_compact_dict(ctx)
println("\n[to_compact_dict トップレベルキー]")
println("  $(sort(collect(keys(ctx_dict))))")


# ─────────────────────────────────────────────────────────────────
# Step 7  docs 参照コンテキスト追加（軽量 RAG）
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 68)
println("Step 7  docs 参照コンテキスト追加（軽量 RAG）")
println("=" ^ 68)

println("""
build_docs_excerpts は docs/ 配下の Markdown を読み込み、
モデル名・変数名・シナリオ名に基づいて関連セクションを選択し
DocsExcerpts を返す。LLM API は呼ばない。
""")

docs_ex = build_docs_excerpts(
    ctx;
    max_chars_per_doc = 800,
)

println("[DocsExcerpts 生成]")
println("  model_doc   : $(length(docs_ex.model_doc)) 文字$(isempty(docs_ex.model_doc) ? " （該当なし）" : "")")
println("  output_guide: $(length(docs_ex.output_guide)) 文字$(isempty(docs_ex.output_guide) ? " （該当なし）" : "")")
println("  caveats_doc : $(length(docs_ex.caveats_doc)) 文字$(isempty(docs_ex.caveats_doc) ? " （該当なし）" : "")")

if !isempty(docs_ex.model_doc)
    println("\n  [model_doc 先頭 200 文字]")
    println("  " * first(docs_ex.model_doc, 200) * (length(docs_ex.model_doc) > 200 ? "…" : ""))
end

# docs_excerpts を AnalysisContext に付加した新しいコンテキストを作成する
ctx_with_docs = AnalysisContext(
    ctx.model_metadata,
    ctx.simulation_result_summary,
    ctx.data_comparison_summary,
    ctx.caveats,
    docs_ex,
)
println("\n[docs_excerpts 付き AnalysisContext 生成完了]")


# ─────────────────────────────────────────────────────────────────
# Step 8  LLM 説明生成
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 68)
println("Step 8  LLM 説明生成")
println("=" ^ 68)

# LLM Provider を選択:
#   OPENAI_API_KEY 未設定 → MockLLMProvider（API 呼び出しなし）
#   OPENAI_API_KEY 設定済み → OpenAIProvider（実 API を呼び出し）
provider = create_provider()
provider_type = provider isa MockLLMProvider ? "MockLLMProvider（API キーなし）" :
                                               "OpenAIProvider（実 API 使用）"
println("LLM Provider: $provider_type")

println("""

--- 8a. シミュレーション結果の説明（explain_result）---
""")

# explain_result: AnalysisContext から構造化 mock 応答を生成する
# （実 LLM で生成する場合は create_provider + complete_from_prompt を使う）
explanation = explain_result(ctx_with_docs)

println("[何を計算したか]")
println(explanation.what_was_computed)

println("\n[主要変数の動き]")
println(explanation.variable_movements)

println("\n[経済学的解釈]")
println(explanation.economic_interpretation)

println("\n[モデルの限界]")
println(explanation.model_limitations)

println("\n[次の分析候補]")
for (i, a) in enumerate(explanation.next_analyses)
    println("  $(i). $a")
end

println("\n[免責]")
println(explanation.disclaimer)

println("""

--- 8b. 実データ比較の説明（explain_data_comparison）---
""")

# explain_data_comparison: data_comparison_summary が設定済みの場合に使用する
comparison_explanation = explain_data_comparison(ctx_with_docs)

println("[何を比較したか]")
println(comparison_explanation.what_was_compared)

println("\n[乖離の大きい変数]")
println(comparison_explanation.large_deviation_variables)

println("\n[モデルが説明しやすい点]")
println(comparison_explanation.model_explains_well)

println("\n[モデルが説明しにくい点]")
println(comparison_explanation.model_explains_poorly)

println("\n[追加で確認すべき系列の候補]")
for (i, s) in enumerate(comparison_explanation.additional_series)
    println("  $(i). $s")
end

println("""

--- 8c. LLM API 呼び出し（complete_from_prompt）---
""")

# build_explain_prompt でプロンプトを生成し、provider 経由で LLM を呼ぶ
# MockLLMProvider の場合は API 呼び出しなしで決定的な mock 応答を返す
prompt = build_explain_prompt(ctx_with_docs)
llm_response = complete_from_prompt(provider, prompt; max_tokens=1500)

println("[LLM 応答（モデル結果説明）]")
println("  使用モデル:   $(llm_response.model)")
println("  終了理由:     $(llm_response.finish_reason)")
if llm_response.input_tokens !== nothing
    println("  入力トークン: $(llm_response.input_tokens)")
    println("  出力トークン: $(llm_response.output_tokens)")
end
println("\n  応答内容:")
println("  " * replace(llm_response.content, "\n" => "\n  "))

# 実データ比較の LLM 説明も生成する
prompt_cmp = build_data_comparison_prompt(ctx_with_docs)
llm_response_cmp = complete_from_prompt(provider, prompt_cmp; max_tokens=1500)

println("\n[LLM 応答（実データ比較説明）]")
println("  使用モデル:   $(llm_response_cmp.model)")
println("  終了理由:     $(llm_response_cmp.finish_reason)")
println("\n  応答内容:")
println("  " * replace(llm_response_cmp.content, "\n" => "\n  "))


# ─────────────────────────────────────────────────────────────────
# 完了サマリー
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 68)
println("  AIエコノミスト統合デモ — 完了")
println("=" ^ 68)
println("""
このデモで示したフロー:
  Step 1  モデル選択        ─ 問いに応じて RBC を選択
  Step 2  シミュレーション  ─ IRF を計算し SimulationResult に変換
  Step 3  実データ取得      ─ FredClient（fixture / live を自動選択）
  Step 4  前処理            ─ log, pct_change, standardize
  Step 5  モデル結果比較    ─ compare_with_data → DataComparisonSummary
  Step 6  AnalysisContext   ─ モデル情報・比較サマリー・注意事項を構造化
  Step 7  docs コンテキスト ─ build_docs_excerpts で docs/ 抜粋を付加
  Step 8  LLM 説明生成      ─ explain_result / explain_data_comparison /
                               complete_from_prompt（mock / 実 API）

使用した LLM Provider: $provider_type

実データ・実 LLM を有効にするには:
  export FRED_API_KEY=...      # FRED 実データ
  export DME_DATA_MODE=live
  export OPENAI_API_KEY=sk-... # OpenAI 実 LLM
  julia --project=. examples/ai_economist_demo.jl

詳細ドキュメント:
  docs/architecture/ai_economist.md  ─ AIエコノミスト化アーキテクチャ
  docs/architecture/llm_layer.md     ─ LLM接続層の設計・禁止事項
  docs/architecture/llm_provider.md  ─ Provider 設定ガイド
  docs/architecture/analysis_context.md ─ AnalysisContext の設計
  docs/llm_safety.md                 ─ 安全性・免責・禁止表現ルール
""")
