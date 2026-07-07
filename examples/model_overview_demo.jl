# examples/model_overview_demo.jl
#
# DME モデル横断デモ — 共通 API による複数モデル分析
#
# モデル群・共通 API・可視化機能を一通り実行し、
# 「複数モデルを横断して経済分析を行う」ワークフローを示す。
#
# 対象モデル（長期成長系・ビジネスサイクル・開放経済・短期政策分析）:
#   Ramsey / Solow / RBC / Mundell-Fleming / New Keynesian
#
# 実行方法:
#   julia --project=. examples/model_overview_demo.jl
#
# 外部 API キーや実データは不要。プロットを保存したい場合は savefig 行を有効化。
#
# 関連デモ:
#   実データ接続  → examples/real_data_demo.jl
#   LLM 説明生成  → examples/ai_economist_demo.jl

using DME

println("""
╔═══════════════════════════════════════════════════════════════╗
║   DME モデル横断デモ — 共通 API による複数モデル分析          ║
╚═══════════════════════════════════════════════════════════════╝

このデモは「経済的な問い → モデル選択 → 実行 → 可視化 → 解釈」という
一連のワークフローを、異なる時間地平のモデルを横断して示す。

  Step 1  長期成長 ─ Ramsey モデル（最適貯蓄・移行経路）
  Step 2  長期成長 ─ Solow モデル（外生貯蓄・収束経路）
  Step 3  景気変動 ─ RBC モデル（技術ショック IRF）
  Step 4  開放経済 ─ Mundell-Fleming モデル（政策比較）
  Step 5  短期政策 ─ New Keynesian モデル（ショック IRF）
  Step 6  横断比較 ─ 複数シナリオの plot_comparison
  Step 7  発展編への案内 ─ 実データ接続・LLM 説明生成
""")


# ─────────────────────────────────────────────────────────────────
# Step 1  長期成長 — Ramsey モデル
# ─────────────────────────────────────────────────────────────────
# 問い: 「最適貯蓄を行う家計の長期均衡と、そこへの移行経路はどうなるか？」
println("=" ^ 60)
println("Step 1  Ramsey モデル — 最適成長と移行経路")
println("=" ^ 60)

rams = RamseyModel(0.3, 0.99, 0.25)   # α=0.3, β=0.99, δ=0.25
println("モデル: $(model_name(rams))")
println("状態変数:   $(state_variables(rams))")
println("制御変数:   $(control_variables(rams))")

# 定常状態（解析解）
ep_rams = steady_state(rams)
println("\n[定常状態]")
println("  K* = $(round(ep_rams.K, digits=4))")
println("  C* = $(round(ep_rams.C, digits=4))")

# 完全予見移行経路: K0 = K*/2 から定常状態へ
path_rams = transition_path(rams, ep_rams.K / 2)
sr_rams = to_simulation_result(rams, path_rams, "transition_from_below")

println("\n[移行経路]  K₀ = K*/2 から $(nperiods(sr_rams)) 期の経路を計算")
sum_rams = summarize_result(sr_rams)
println("  K: 初期 $(round(sum_rams["variables"]["K"].initial, digits=4))" *
        " → 終端 $(round(sum_rams["variables"]["K"].final, digits=4))" *
        " ≈ K* = $(round(ep_rams.K, digits=4))")
println("  C: 初期 $(round(sum_rams["variables"]["C"].initial, digits=4))" *
        " → 終端 $(round(sum_rams["variables"]["C"].final, digits=4))")

# simulate でポリシー関数ベースの経路も取得
sim_rams = simulate(rams, ep_rams.K / 2)
sr_sim_rams = to_simulation_result(rams, sim_rams, "simulate_vi")
println("  （価値反復法による simulate も実行: $(nperiods(sr_sim_rams)) 期）")

# プロット
p_rams = plot_result(sr_rams;
    vars = ["K", "C"],
    title = "Ramsey: 移行経路（K₀ = K*/2）",
    xlabel = "Period", ylabel = "Level",
)
# savefig(p_rams, "ramsey_transition.png")
println("\n  → p_rams を生成")


# ─────────────────────────────────────────────────────────────────
# Step 2  長期成長 — Solow モデル
# ─────────────────────────────────────────────────────────────────
# 問い: 「貯蓄率・人口成長・技術進歩は、長期の生活水準にどう影響するか？」
println("\n" * "=" ^ 60)
println("Step 2  Solow モデル — 外生的貯蓄と収束経路")
println("=" ^ 60)

solow = SolowModel(0.3, 0.2, 0.1, 0.01, 0.02)  # α=0.3, s=0.2, δ=0.1, n=0.01, g=0.02
println("モデル: $(model_name(solow))")

ep_solow = steady_state(solow)
println("\n[定常状態]（効率労働単位あたり）")
println("  k* = $(round(ep_solow.k, digits=4))")
println("  y* = $(round(ep_solow.y, digits=4))")
println("  c* = $(round(ep_solow.c, digits=4))")

# 収束経路（低資本・高資本の 2 ケース）
path_below = transition_path(solow, ep_solow.k / 2; T=80)
path_above = transition_path(solow, ep_solow.k * 2; T=80)
sr_below = to_simulation_result(solow, path_below, "k₀ < k*（資本不足）")
sr_above = to_simulation_result(solow, path_above, "k₀ > k*（資本過剰）")

sum_below = summarize_result(sr_below)
sum_above = summarize_result(sr_above)
println("\n[収束経路]")
println("  低資本スタート: k 終端 = $(round(sum_below["variables"]["k"].final, digits=4))" *
        " ≈ k*")
println("  高資本スタート: k 終端 = $(round(sum_above["variables"]["k"].final, digits=4))" *
        " ≈ k*")

# 両経路の比較プロット
p_solow_cmp = plot_comparison(
    [sr_below, sr_above];
    var = "k",
    labels = ["k₀ = k*/2（資本不足）", "k₀ = 2k*（資本過剰）"],
    title = "Solow: 異なる初期資本からの収束比較",
    ylabel = "資本 k（効率労働単位あたり）",
)
# savefig(p_solow_cmp, "solow_convergence_comparison.png")
println("\n  → p_solow_cmp を生成")


# ─────────────────────────────────────────────────────────────────
# Step 3  景気変動 — RBC モデル
# ─────────────────────────────────────────────────────────────────
# 問い: 「技術ショックは産出・消費・資本・労働をどのように動かすか？」
println("\n" * "=" ^ 60)
println("Step 3  RBC モデル — 技術ショックのインパルス応答")
println("=" ^ 60)

rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)  # α, β, γ, δ, μ, ρ
println("モデル: $(model_name(rbc))")

ep_rbc = steady_state(rbc)
println("\n[定常状態]")
println("  K* = $(round(ep_rbc.K, digits=4))  Y* = $(round(ep_rbc.Y, digits=4))" *
        "  C* = $(round(ep_rbc.C, digits=4))  L* = $(round(ep_rbc.L, digits=4))")

# 技術ショック（ε₀ = 1%）の IRF
# 返り値は定常状態からの対数偏差（ĉ, k̂, ŷ など）
irf_rbc = impulse_response(rbc, 0.01)
sr_rbc = to_simulation_result(rbc, irf_rbc, "technology_shock_1pct")

println("\n[技術ショック IRF]  ε₀ = 1%（対数偏差, T = $(nperiods(sr_rbc)) 期）")
sum_rbc = summarize_result(sr_rbc)
for var in ["ŷ", "ĉ", "k̂", "l̂"]
    s = sum_rbc["variables"][var]
    println("  $var: peak = $(round(s.peak_response, digits=5)) (t=$(s.argmax - 1))" *
            "  符号反転 = $(s.sign_reversal)")
end

# IRF プロット（ゼロライン付き）
p_rbc_irf = plot_irf(sr_rbc;
    vars = ["ŷ", "ĉ", "k̂"],
    title = "RBC: 技術ショック IRF（ε₀ = 1%）",
    ylabel = "Log deviation from SS",
)
# savefig(p_rbc_irf, "rbc_irf.png")
println("\n  → p_rbc_irf を生成")


# ─────────────────────────────────────────────────────────────────
# Step 4  開放経済 — Mundell-Fleming モデル
# ─────────────────────────────────────────────────────────────────
# 問い: 「変動相場制・完全資本移動のもとで、財政・金融政策の効果はどう変わるか？」
# Mundell-Fleming 定理: 財政政策は無効、金融政策は有効（変動相場制下）
println("\n" * "=" ^ 60)
println("Step 4  Mundell-Fleming モデル — 開放経済の政策効果")
println("=" ^ 60)

# ベースライン設定（IS-LM に開放経済パラメータを追加）
#   r_star=0.02: 世界利子率, nx0=50.0: 自律純輸出, nx1=10.0: 為替感応度
mf_base = MundellFlemingModel(
    100.0, 0.8, 200.0, 50.0, 100.0, 100.0,
    0.2, 100.0, 1000.0, 1.0,
    0.02, 50.0, 10.0,
)
println("モデル: $(model_name(mf_base))")

eq_mf = steady_state(mf_base)
println("\n[定常状態]")
println("  Y* = $(round(eq_mf.Y, digits=2))  r* = $(round(eq_mf.r, digits=4))" *
        "  e* = $(round(eq_mf.e, digits=4))  NX* = $(round(eq_mf.NX, digits=2))")

# simulate（長さ 1 の系列として均衡値を取得）
sim_mf = simulate(mf_base)
sr_mf_base = to_simulation_result(mf_base, sim_mf, "baseline")
println("  simulate → 変数: $(sort(variable_names(sr_mf_base)))")

# ── 4a. 財政政策（G: 100 → 150）
# Mundell-Fleming 定理: 財政政策は無効 → Y は変化せず e が増価（自国通貨高）
mf_fiscal = MundellFlemingModel(
    100.0, 0.8, 200.0, 50.0, 150.0, 100.0,
    0.2, 100.0, 1000.0, 1.0,
    0.02, 50.0, 10.0,
)
sr_mf_fiscal = DME.mf_policy_shock(
    mf_base, mf_fiscal;
    scenario_names = ("baseline", "fiscal_expansion"),
)
ΔY_mf_f = sr_mf_fiscal["Y"][2] - sr_mf_fiscal["Y"][1]
Δe_mf_f = sr_mf_fiscal["e"][2] - sr_mf_fiscal["e"][1]
println("\n[財政拡張 ΔG = +50]  Mundell-Fleming 定理の検証")
println("  ΔY = $(round(ΔY_mf_f, digits=4))  ← 産出変化なし（定理通り）")
println("  Δe = $(round(Δe_mf_f, digits=4))  ← 通貨増価（NX 減少で財政効果を相殺）")

# ── 4b. 金融政策（M: 1000 → 1200）
# Mundell-Fleming 定理: 金融政策は有効 → Y 増加・e 減価（自国通貨安）
mf_monetary = MundellFlemingModel(
    100.0, 0.8, 200.0, 50.0, 100.0, 100.0,
    0.2, 100.0, 1200.0, 1.0,
    0.02, 50.0, 10.0,
)
sr_mf_monetary = DME.mf_policy_shock(
    mf_base, mf_monetary;
    scenario_names = ("baseline", "monetary_easing"),
)
ΔY_mf_m = sr_mf_monetary["Y"][2] - sr_mf_monetary["Y"][1]
Δe_mf_m = sr_mf_monetary["e"][2] - sr_mf_monetary["e"][1]
println("\n[金融緩和 ΔM = +200]  Mundell-Fleming 定理の検証")
println("  ΔY = $(round(ΔY_mf_m, digits=2))  ← 産出増加（定理通り）")
println("  Δe = $(round(Δe_mf_m, digits=4))  ← 通貨減価（NX 改善）")

# 財政 vs 金融の産出変化を比較
p_mf_cmp = plot_comparison(
    [sr_mf_fiscal, sr_mf_monetary];
    var = "Y",
    labels = ["財政拡張 (ΔG=+50)", "金融緩和 (ΔM=+200)"],
    title = "Mundell-Fleming: 財政 vs 金融政策（産出 Y）",
    xlabel = "シナリオ",
    ylabel = "産出 Y",
)
# savefig(p_mf_cmp, "mf_policy_comparison.png")

# 為替レートの変化も可視化
p_mf_e = plot_result(sr_mf_monetary;
    vars = ["Y", "e", "NX"],
    title = "Mundell-Fleming: 金融緩和（ΔM = +200）",
    xlabel = "シナリオ (1=baseline, 2=monetary)",
)
# savefig(p_mf_e, "mf_monetary.png")
println("\n  → p_mf_cmp, p_mf_e を生成")


# ─────────────────────────────────────────────────────────────────
# Step 5  短期政策 — New Keynesian モデル
# ─────────────────────────────────────────────────────────────────
# 問い: 「合理的期待のもとで、各種ショックはインフレと産出ギャップをどう動かすか？」
println("\n" * "=" ^ 60)
println("Step 5  New Keynesian モデル — 政策ルールとショック IRF")
println("=" ^ 60)

nk = NewKeynesianModel(1.0, 0.02, 0.99, 0.1, 1.5, 0.5, 0.02, 0.8, 0.5, 0.5)
println("モデル: $(model_name(nk))")

ss_nk = steady_state(nk)
println("\n[定常状態]  x*=$(ss_nk.x), π*=$(ss_nk.π), i*=$(round(ss_nk.i, digits=4))")

# 需要ショック・コストプッシュショック・金融政策ショックの 3 種類の IRF
irf_demand  = impulse_response(nk, 1.0; shock = :demand,     T = 20)
irf_cost    = impulse_response(nk, 1.0; shock = :cost_push,  T = 20)
irf_mon     = impulse_response(nk, 1.0; shock = :monetary,   T = 20)

sr_nk_demand = to_simulation_result(nk, irf_demand, "demand_shock")
sr_nk_cost   = to_simulation_result(nk, irf_cost,   "cost_push_shock")
sr_nk_mon    = to_simulation_result(nk, irf_mon,    "monetary_shock")

println("\n[初期応答: t=1]")
println("  需要ショック    : x=$(round(irf_demand.x[1], digits=4))" *
        "  π=$(round(irf_demand.π[1], digits=4))  i=$(round(irf_demand.i[1], digits=4))")
println("  コストプッシュ  : x=$(round(irf_cost.x[1], digits=4))" *
        "  π=$(round(irf_cost.π[1], digits=4))  i=$(round(irf_cost.i[1], digits=4))")
println("  金融政策（利上げ）: x=$(round(irf_mon.x[1], digits=4))" *
        "  π=$(round(irf_mon.π[1], digits=4))  i=$(round(irf_mon.i[1], digits=4))")
println("  ※ コストプッシュでは x と π が逆方向 → 政策トレードオフ")

# 3 ショックのインフレ応答を IRF プロット
p_nk_pi = plot_irf(
    sr_nk_demand;
    vars = ["π"],
    title = "NK: 需要ショック — インフレ応答",
    ylabel = "インフレ率乖離 π̃",
)
# savefig(p_nk_pi, "nk_demand_irf.png")

# 3 ショックのインフレ応答を比較
p_nk_cmp = plot_comparison(
    [sr_nk_demand, sr_nk_cost, sr_nk_mon];
    var = "π",
    labels = ["需要ショック", "コストプッシュ", "金融政策（利上げ）"],
    title = "NK: ショック種別インフレ応答の比較",
    ylabel = "インフレ率乖離 π̃",
)
# savefig(p_nk_cmp, "nk_inflation_comparison.png")
println("\n  → p_nk_pi, p_nk_cmp を生成")


# ─────────────────────────────────────────────────────────────────
# Step 6  横断比較 — 共通 API による複数モデルのまとめ
# ─────────────────────────────────────────────────────────────────
# summarize_result で各モデルの主要指標を収集し、横断的な視点を示す。
println("\n" * "=" ^ 60)
println("Step 6  横断比較 — 各モデルの主要指標サマリー")
println("=" ^ 60)

println("""
┌──────────────────┬────────────┬──────────────────────────────────────┐
│ モデル           │ 時間地平   │ 主な問い・指標                       │
├──────────────────┼────────────┼──────────────────────────────────────┤
│ Ramsey           │ 長期       │ 最適貯蓄・K*/C* の定量化             │
│ Solow            │ 長期       │ 貯蓄率・収束速度の比較静学           │
│ RBC              │ 中期       │ 技術ショックの IRF・ビジネスサイクル │
│ Mundell-Fleming  │ 短期       │ 開放経済の政策有効性（為替）         │
│ New Keynesian    │ 短期       │ インフレ・産出ギャップのトレードオフ │
└──────────────────┴────────────┴──────────────────────────────────────┘
""")

# summarize_result による定量サマリー
println("[定量サマリー: 各モデルの代表変数]")

# Ramsey: 資本の収束
sum_k_rams = summarize_result(sr_rams)["variables"]["K"]
println("  Ramsey K: initial=$(round(sum_k_rams.initial, digits=3))" *
        "  final=$(round(sum_k_rams.final, digits=3))" *
        "  SS=$(round(ep_rams.K, digits=3))")

# Solow: 収束速度（低資本ケース）
sum_k_solow = summarize_result(sr_below)["variables"]["k"]
println("  Solow k: initial=$(round(sum_k_solow.initial, digits=3))" *
        "  final=$(round(sum_k_solow.final, digits=3))" *
        "  SS=$(round(ep_solow.k, digits=3))")

# RBC: ショックピーク応答
sum_y_rbc = summarize_result(sr_rbc)["variables"]["ŷ"]
println("  RBC ŷ: peak=$(round(sum_y_rbc.peak_response, digits=5))" *
        "  (t=$(sum_y_rbc.argmax - 1))" *
        "  sign_reversal=$(sum_y_rbc.sign_reversal)")

# NK: ショックピーク応答
sum_pi_nk = summarize_result(sr_nk_cost)["variables"]["π"]
println("  NK π(コストプッシュ): peak=$(round(sum_pi_nk.peak_response, digits=5))" *
        "  (t=$(sum_pi_nk.argmax - 1))")

# 異なるモデルの「産出」変数を並べた比較（単位は異なる点に注意）
# IS-LM 系の産出と RBC 系の産出は水準・単位が異なるため、ここでは
# 「ショック後の相対変化」に基づく比較として提示する
println("\n[政策効果の対比（閉鎖 vs 開放経済, 同一パラメータ類似設定）]")
println("  IS-LM 財政拡張（閉鎖）:    ΔY > 0  Δr > 0（クラウディングアウト有）")
println("  Mundell-Fleming 財政拡張（開放）: ΔY ≈ 0  Δe < 0（通貨増価で完全相殺）")
println("  → 変動相場制下では資本移動が財政乗数をゼロに押し下げる")

# Mundell-Fleming のシナリオ比較（財政 vs 金融）
p_summary_mf = plot_comparison(
    [sr_mf_fiscal, sr_mf_monetary];
    var = "NX",
    labels = ["財政拡張 (ΔG=+50)", "金融緩和 (ΔM=+200)"],
    title = "Mundell-Fleming: 純輸出 NX の変化（財政 vs 金融）",
    xlabel = "シナリオ",
    ylabel = "純輸出 NX",
)
# savefig(p_summary_mf, "mf_nx_comparison.png")
println("\n  → p_summary_mf を生成")


# ─────────────────────────────────────────────────────────────────
# Step 7  発展編への案内 — 実データ接続・LLM 説明生成
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 60)
println("Step 7  発展編への案内 — 実データ接続・LLM 説明生成")
println("=" ^ 60)
println("""
このデモで示した機能は、DME の「分析カーネル」（モデル・共通 API・可視化）
にあたる。DME にはこのカーネルに接続する実データ層・LLM 層も実装されている。

─── 実データ接続 ────────────────────────────────────────────────

  FredClient / EStatClient で FRED・e-Stat からマクロ系列を取得し、
  前処理（fill_missing / apply_log / pct_change / to_quarterly など）を経て
  compare_with_data でモデル出力と比較できる。

  → デモ: examples/real_data_demo.jl（API キー不要、fixture モードで完走）
  → docs: docs/data/fred.md, docs/data/estat.md, docs/data/preprocess.md

─── LLM 説明生成 ────────────────────────────────────────────────

  AnalysisContext にモデル・結果・データ比較・注意事項を集約し、
  explain_result / explain_data_comparison で自然言語の説明を生成できる。
  LLM プロバイダは差し替え可能（MockLLMProvider / OpenAIProvider）。

  → デモ: examples/ai_economist_demo.jl（API キー不要、Mock LLM で完走）
  → docs: docs/architecture/llm_layer.md, docs/llm_safety.md
""")


# ─────────────────────────────────────────────────────────────────
# 生成されたプロット変数の一覧
# ─────────────────────────────────────────────────────────────────
println("=" ^ 60)
println("生成されたプロット変数一覧")
println("=" ^ 60)
println("  p_rams        : Ramsey 移行経路（K, C）")
println("  p_solow_cmp   : Solow 低資本 vs 高資本の収束比較")
println("  p_rbc_irf     : RBC 技術ショック IRF（ŷ, ĉ, k̂）")
println("  p_mf_cmp      : Mundell-Fleming 財政 vs 金融政策（産出 Y）")
println("  p_mf_e        : Mundell-Fleming 金融緩和（Y, e, NX）")
println("  p_nk_pi       : NK 需要ショック インフレ応答")
println("  p_nk_cmp      : NK 3 ショック比較（インフレ π）")
println("  p_summary_mf  : Mundell-Fleming 純輸出 NX 比較（財政 vs 金融）")
println("\nプロットを保存する場合の例:")
println("  savefig(p_rams, \"ramsey_transition.png\")")
println("  savefig(p_rbc_irf, \"rbc_irf.png\")")
