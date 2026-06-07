# examples/real_data_demo.jl
#
# DME Phase 5 実データ接続デモ
#
# 実データ取得（FRED）→ 前処理 → SimulationResult 変換 →
# モデル結果との比較 → 可視化 → AnalysisContext への接続
# という一連のフローを示す。
#
# 実行方法:
#   julia --project=. examples/real_data_demo.jl
#
# データモード:
#   デフォルト: fixture モード（API キー不要、test/fixtures/fred/ を使用）
#   実データ:   FRED API キーを取得後、以下の環境変数を設定して実行
#
#     export FRED_API_KEY=your_api_key_here
#     export DME_DATA_MODE=live
#     julia --project=. examples/real_data_demo.jl
#
#   FRED API キーの取得: https://fred.stlouisfed.org/docs/api/api_key.html

using DME

println("""
╔═══════════════════════════════════════════════════════════════╗
║   DME Phase 5 実データ接続デモ                                 ║
╚═══════════════════════════════════════════════════════════════╝

フロー:
  Step 1  データ取得       ─ FRED fixture（または live API）
  Step 2  基本操作         ─ DataSeries / MacroDataset
  Step 3  前処理           ─ log / 前年比 / 月次→四半期変換
  Step 4  SR 変換          ─ SimulationResult 互換形式へ
  Step 5  モデル比較       ─ RBC モデル結果 vs 実データ
  Step 6  可視化           ─ plot_result / plot_irf
  Step 7  Phase 6 準備     ─ AnalysisContext への接続例
""")


# ─────────────────────────────────────────────────────────────────
# Step 1  データ取得 — FRED
# ─────────────────────────────────────────────────────────────────
println("=" ^ 60)
println("Step 1  データ取得 — FRED")
println("=" ^ 60)

# FredClient は環境変数 DME_DATA_MODE / FRED_API_KEY を見てモードを自動選択:
#   FRED_API_KEY 未設定 → fixture モード（test/fixtures/fred/*.json を使用）
#   FRED_API_KEY 設定済み → live モード（実 API を呼び出し）
client = FredClient()
println("モード: $(client.mode)")

# 単一系列の取得
gdp_raw = fetch_fred_series("GDPC1"; client=client)
println("\n[GDPC1 取得]")
println("  名称:   $(gdp_raw.name)")
println("  出所:   $(gdp_raw.source)")
println("  頻度:   $(gdp_raw.frequency)")
println("  単位:   $(gdp_raw.unit)")
println("  期間:   $(first(gdp_raw.dates)) 〜 $(last(gdp_raw.dates))  ($(length(gdp_raw)) 観測点)")
println("  欠損数: $(missing_count(gdp_raw))")

# 複数系列を一括取得 → MacroDataset
dataset = fetch_fred_dataset(
    ["GDPC1", "CPIAUCSL", "FEDFUNDS", "UNRATE"];
    client = client,
    name   = "FRED Macro Dataset",
)
println("\n[MacroDataset 取得]")
println("  系列数: $(length(dataset))")
println("  系列:   $(sort(series_ids(dataset)))")


# ─────────────────────────────────────────────────────────────────
# Step 2  DataSeries / MacroDataset の基本操作
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 60)
println("Step 2  DataSeries / MacroDataset の基本操作")
println("=" ^ 60)

# データセットから各系列を取得
gdp      = get_series(dataset, "FRED_GDPC1")
cpi      = get_series(dataset, "FRED_CPIAUCSL")
fedfunds = get_series(dataset, "FRED_FEDFUNDS")
unrate   = get_series(dataset, "FRED_UNRATE")

println("[haskey / get_series]")
has_gdpc1 = haskey(dataset, "FRED_GDPC1")
has_none  = haskey(dataset, "NONEXISTENT")
println("  haskey(dataset, \"FRED_GDPC1\"):    $has_gdpc1")
println("  haskey(dataset, \"NONEXISTENT\"):   $has_none")

# 日付ラベルで値をアクセス
first_date = first(gdp.dates)
println("\n[日付インデックス]  gdp[\"$(first_date)\"] = $(gdp[first_date])")
has_old = haskey(gdp, "1900-Q1")
println("[haskey]            haskey(gdp, \"1900-Q1\") = $has_old")

# DataSeries を手動で作成する例（外部データや自前計算値の格納に使用）
custom_gdp_growth = DataSeries(
    id        = "CUSTOM_JAPAN_GROWTH",
    name      = "Japan Real GDP Growth (hypothetical)",
    source    = "Manual",
    frequency = Annual,
    unit      = "%",
    dates     = ["2018", "2019", "2020"],
    values    = [0.6, -0.4, -4.1],
)
println("\n[手動作成 DataSeries]")
println("  id=$(custom_gdp_growth.id)  length=$(length(custom_gdp_growth))")
growth_2020 = custom_gdp_growth["2020"]
println("  2020 年成長率: $(growth_2020)%")

# MacroDataset へのシリーズ追加
extended_dataset = MacroDataset("Extended Dataset")
push!(extended_dataset, gdp)
push!(extended_dataset, custom_gdp_growth)
println("\n[push! で DataSeries を MacroDataset へ追加]")
println("  系列数: $(length(extended_dataset))  →  $(sort(series_ids(extended_dataset)))")


# ─────────────────────────────────────────────────────────────────
# Step 3  前処理
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 60)
println("Step 3  前処理")
println("=" ^ 60)

# 3a. GDP（四半期）: 対数変換 → 前年同期比成長率（periods=4）
println("[3a. GDP: apply_log → pct_change(periods=4) — 前年同期比成長率]")
gdp_log = apply_log(gdp)
gdp_yoy = pct_change(gdp_log; periods=4)
println("  変換後: $(length(gdp_yoy)) 観測点  $(first(gdp_yoy.dates)) 〜 $(last(gdp_yoy.dates))")
transforms = get(gdp_yoy.metadata, "transformations", String[])
println("  変換履歴: $transforms")
yoy_vals = nonmissing_values(gdp_yoy)
if !isempty(yoy_vals)
    println("  前年比成長率 [%]: 最小 $(round(minimum(yoy_vals), digits=2))  最大 $(round(maximum(yoy_vals), digits=2))")
end

# 3b. GDP（四半期）: 年次変換
println("\n[3b. GDP: to_annual(method=:mean) — 四半期→年次]")
gdp_annual = to_annual(gdp; method=:mean)
println("  四半期 $(length(gdp)) 点 → 年次 $(length(gdp_annual)) 点")
println("  年次 GDP 水準: $(round.(nonmissing_values(gdp_annual), digits=1))")

# 3c. CPI（月次）: 月次→四半期変換 → 前期比変化率
println("\n[3c. CPI: to_quarterly → pct_change(periods=1) — 前期比インフレ率]")
cpi_q   = to_quarterly(cpi; method=:mean)
cpi_qoq = pct_change(cpi_q; periods=1)
println("  月次 $(length(cpi)) 点 → 四半期 $(length(cpi_q)) 点 → 変化率 $(length(cpi_qoq)) 点")
qoq_vals = nonmissing_values(cpi_qoq)
if !isempty(qoq_vals)
    println("  四半期インフレ率 [%]: $(round.(qoq_vals, digits=3))")
end

# 3d. FEDFUNDS（月次）: 月次→四半期変換（平均）
println("\n[3d. FEDFUNDS: to_quarterly(method=:mean) — 四半期平均政策金利]")
fedfunds_q = to_quarterly(fedfunds; method=:mean)
println("  月次 $(length(fedfunds)) 点 → 四半期 $(length(fedfunds_q)) 点")
ff_vals = nonmissing_values(fedfunds_q)
if !isempty(ff_vals)
    println("  四半期平均 FF 金利 [%]: $(round.(ff_vals, digits=3))")
end

# 3e. UNRATE（月次）: 月次→四半期変換
println("\n[3e. UNRATE: to_quarterly — 四半期平均失業率]")
unrate_q = to_quarterly(unrate; method=:mean)
println("  月次 $(length(unrate)) 点 → 四半期 $(length(unrate_q)) 点")
ur_vals = nonmissing_values(unrate_q)
if !isempty(ur_vals)
    println("  四半期平均失業率 [%]: $(round.(ur_vals, digits=2))")
end


# ─────────────────────────────────────────────────────────────────
# Step 4  SimulationResult 互換変換
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 60)
println("Step 4  SimulationResult 互換変換")
println("=" ^ 60)

# DataSeries → SimulationResult（1 系列）
gdp_sr = to_simulation_result(gdp, "actual_data")
println("[DataSeries → SimulationResult]")
println("  model_name:    $(gdp_sr.model_name)")
println("  scenario_name: $(gdp_sr.scenario_name)")
println("  変数:          $(variable_names(gdp_sr))")
println("  期間数:        $(nperiods(gdp_sr))")
dates_meta = gdp_sr.metadata["dates"]
println("  dates メタ:    $dates_meta")

# MacroDataset → SimulationResult（複数系列一括）
# 周波数の揃った系列だけでデータセットを構成して変換
quarterly_ds = MacroDataset("Quarterly Macro", [gdp, fedfunds_q, unrate_q])
quarterly_sr = to_simulation_result(quarterly_ds, "quarterly_actual")
println("\n[MacroDataset → SimulationResult（複数系列）]")
println("  変数: $(sort(variable_names(quarterly_sr)))")
println("  期間数（系列ごとに異なりうる点に注意）: $(nperiods(quarterly_sr))")

# summarize_result で統計サマリーを抽出
gdp_summary = summarize_result(gdp_sr)
gdp_vstats  = gdp_summary["variables"]["FRED_GDPC1"]
println("\n[summarize_result — GDP 統計サマリー]")
println("  初期値: $(round(gdp_vstats.initial,       digits=1))")
println("  最終値: $(round(gdp_vstats.final,         digits=1))")
println("  最大値: $(round(gdp_vstats.max,           digits=1))  (t=$(gdp_vstats.argmax))")
println("  最小値: $(round(gdp_vstats.min,           digits=1))  (t=$(gdp_vstats.argmin))")
println("  変化幅: $(round(gdp_vstats.range,         digits=1))")


# ─────────────────────────────────────────────────────────────────
# Step 5  モデル結果との比較 — RBC モデル vs 実 GDP
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 60)
println("Step 5  モデル結果との比較 — RBC モデル vs 実 GDP")
println("=" ^ 60)

# RBC モデルのセットアップ
rbc    = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)  # α, β, γ, δ, μ, ρ
irf    = impulse_response(rbc, 0.01; maxT=length(gdp))
model_sr = to_simulation_result(rbc, irf, "technology_shock_1pct")
println("RBC 技術ショック IRF: $(nperiods(model_sr)) 期  変数: $(sort(variable_names(model_sr)))")

# スケール注記:
#   ŷ は定常状態からの対数偏差（小さい実数、例: 0.01 ≈ 1%の偏差）
#   FRED_GDPC1 は兆ドル単位の実水準（例: 18000-19000）
#   → 水準差・RMSE は単位の違いを反映するため大きくなる
#   → 相関係数はスケール非依存の共変動を示す
println("""
[単位注記]
  ŷ        : 定常状態からの対数偏差（例: 0.014 ≈ +1.4% 偏差）
  FRED_GDPC1: 兆ドル単位の実水準（例: 18000–19000 Bil. USD）
  → RMSE / 水準差は単位差を反映。相関係数がコア指標。
  標準化比較（z スコア）もあわせて示す。
""")

# 5a. 生の水準比較（単位差あり）
data_sr  = to_simulation_result(gdp, "actual_data")
cr_raw   = compare_with_data(model_sr, data_sr; mapping=Dict("ŷ" => "FRED_GDPC1"))
m_raw    = cr_raw.variables["ŷ"]
println("[生の水準比較]")
println("  比較期間数: $(m_raw.n_periods)")
println("  RMSE:       $(round(m_raw.rmse, digits=2))  ← 単位差を反映（正常）")
println("  MAE:        $(round(m_raw.mae, digits=2))")
println("  相関係数:   $(round(m_raw.correlation, digits=4))")

# 5b. 標準化（z スコア）による単位非依存の比較
gdp_std    = standardize(gdp)
data_std_sr = to_simulation_result(gdp_std, "actual_data_standardized")
cr_std     = compare_with_data(model_sr, data_std_sr; mapping=Dict("ŷ" => "FRED_GDPC1"))
m_std      = cr_std.variables["ŷ"]
println("\n[標準化後の比較（z スコア）]")
println("  RMSE:       $(round(m_std.rmse, digits=4))  ← 標準化後は解釈しやすい")
println("  相関係数:   $(round(m_std.correlation, digits=4))  （-1〜+1 での共変動の程度）")
println("""
  解釈: 相関係数 ≈ $(round(m_std.correlation, digits=2)) — RBC 技術ショック IRF の形状と
        実 GDP の動態の間には$(abs(m_std.correlation) < 0.3 ? "弱い" : abs(m_std.correlation) < 0.6 ? "中程度の" : "強い")相関がある。
        本デモは API の動作確認が目的であり経済的解釈は副次的。
""")

# to_data_comparison_summary: ComparisonResult → DataComparisonSummary（AnalysisContext 用）
dcs = to_data_comparison_summary(
    cr_std;
    caveats = [
        "ŷ は RBC 技術ショック IRF の対数偏差（スケール異なる）",
        "FRED_GDPC1 は z スコア標準化済み",
        "fixture データ使用（2018-Q1〜2020-Q4）",
    ],
)
println("[DataComparisonSummary — AnalysisContext への入力に使用]")
println("  data_source:       $(dcs.data_source)")
println("  comparison_period: $(dcs.comparison_period)")
println("  偏差統計 (ŷ 項目抜粋):")
for key in ["rmse", "mae", "correlation"]
    v     = dcs.deviation_statistics["ŷ"][key]
    v_str = isnan(v) ? "NaN" : string(round(v, digits=4))
    println("    $key: $v_str")
end
println("  注意事項: $(dcs.data_caveats)")


# ─────────────────────────────────────────────────────────────────
# Step 6  可視化
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 60)
println("Step 6  可視化")
println("=" ^ 60)

# GDP 水準の時系列プロット
p_gdp = plot_result(gdp_sr;
    title  = "Real GDP（FRED GDPC1）",
    xlabel = "Period",
    ylabel = "Billions of Chained 2017 USD",
)
# savefig(p_gdp, "gdp_level.png")
println("  p_gdp を生成: Real GDP 水準（$(nperiods(gdp_sr)) 期）")

# RBC 技術ショック IRF（ゼロライン付き）
p_irf = plot_irf(model_sr;
    vars       = ["ŷ", "ĉ", "k̂"],
    shock_size = 0.01,
    title      = "RBC 技術ショック IRF（ε₀ = 1%）",
    ylabel     = "Log deviation from steady state",
)
# savefig(p_irf, "rbc_irf.png")
println("  p_irf を生成: RBC 技術ショック IRF（ŷ, ĉ, k̂）")

# 前処理済み GDP 成長率の可視化
gdp_yoy_sr = to_simulation_result(gdp_yoy, "gdp_yoy_growth")
p_gdp_growth = plot_result(gdp_yoy_sr;
    title  = "GDP 前年同期比成長率（対数差分）",
    xlabel = "Period",
    ylabel = "%",
)
# savefig(p_gdp_growth, "gdp_yoy_growth.png")
println("  p_gdp_growth を生成: GDP 前年同期比成長率")

# 複数モデルの比較（plot_comparison は変数名が一致する場合に使用）
# ここでは IRF の ŷ を 2 つのショックサイズで比較する例を示す
irf_large  = impulse_response(rbc, 0.02; maxT=length(gdp))
model_sr_large = to_simulation_result(rbc, irf_large, "technology_shock_2pct")

p_shock_cmp = plot_comparison(
    [model_sr, model_sr_large];
    var    = "ŷ",
    labels = ["ε₀ = 1%", "ε₀ = 2%"],
    title  = "RBC: ショックサイズの比較（ŷ）",
    ylabel = "Log deviation from SS",
)
# savefig(p_shock_cmp, "rbc_shock_comparison.png")
println("  p_shock_cmp を生成: ショックサイズ比較（ε₀ = 1% vs 2%）")

println("""
[プロット変数一覧]
  p_gdp        : Real GDP 水準
  p_irf        : RBC 技術ショック IRF（ŷ, ĉ, k̂）
  p_gdp_growth : GDP 前年同期比成長率
  p_shock_cmp  : RBC ショックサイズ比較

保存するには以下のように savefig を使用:
  savefig(p_gdp,    "gdp_level.png")
  savefig(p_irf,    "rbc_irf.png")
""")


# ─────────────────────────────────────────────────────────────────
# Step 7  Phase 6 準備 — AnalysisContext への接続例
# ─────────────────────────────────────────────────────────────────
println("=" ^ 60)
println("Step 7  Phase 6 準備 — AnalysisContext への接続例")
println("=" ^ 60)

println("""
AnalysisContext は LLM へ渡す構造化コンテキストを束ねる型。
モデルメタ情報・シミュレーション結果サマリー・実データ比較サマリー・
注意事項を一つの Dict / JSON に変換してプロンプトに埋め込む。
""")

# AnalysisContext を構築（実データ比較サマリーを含む）
ctx = AnalysisContext(
    rbc,
    model_sr;
    shock_description  = "1% positive technology shock (ε₀ = 0.01)",
    data_comparison_summary = dcs,
    caveats = Caveats(
        ["Closed economy", "Representative agent", "Log-linearized around steady state"],
        ["Fixture data: FRED GDPC1, 2018-Q1 to 2020-Q4 (12 obs)", "Standardized for unit-invariant comparison"],
        ["ŷ is log deviation from steady state, not growth rate", "RMSE reflects scale difference, not model fit"],
    ),
)

println("[AnalysisContext 構築完了]")
println("  モデル:         $(ctx.model_metadata.model_name)")
println("  シナリオ:       $(ctx.simulation_result_summary.scenario_name)")
println("  期間数:         $(ctx.simulation_result_summary.n_periods)")
cmp_status = ctx.data_comparison_summary !== nothing ?
    "設定済み (" * ctx.data_comparison_summary.data_source * ")" : "なし"
println("  実データ比較:   $cmp_status")

# to_compact_dict でトークン効率の良い形式に変換（LLM プロンプトへ埋め込む想定）
ctx_dict  = to_compact_dict(ctx)
ctx_keys  = sort(collect(keys(ctx_dict)))
println("\n[to_compact_dict のトップレベルキー]")
println("  $ctx_keys")

println("""
[Phase 6 での使い方イメージ（コメント参照）]

  # プロンプトへの埋め込み（Phase 6 で LLM 接続層が担当）
  # using JSON3
  # ctx_json = to_json(ctx)          # JSON 文字列に変換
  # prompt = "次の経済分析結果を解釈してください。" * ctx_json
  # response = call_llm(prompt)      # LLM API 呼び出し（Phase 6 で実装）
""")


println("=" ^ 60)
println("  Phase 5 実データ接続デモ — 完了")
println("=" ^ 60)
println("""
このデモで示したフロー:
  ① FredClient でデータ取得（fixture / live モードを自動選択）
  ② DataSeries / MacroDataset で系列を管理
  ③ 前処理（log, pct_change, to_quarterly, to_annual, standardize）
  ④ to_simulation_result で既存 API（plot / summarize）に接続
  ⑤ compare_with_data でモデル結果と実データを定量比較
  ⑥ plot_result / plot_irf / plot_comparison で可視化
  ⑦ AnalysisContext で LLM 接続（Phase 6）への橋渡し

次のステップ（Phase 6）:
  - LLM Provider（OpenAI 等）を設定し、AnalysisContext を JSON でプロンプトに埋め込む
  - docs/architecture/llm_layer.md および docs/architecture/llm_provider.md を参照
""")
