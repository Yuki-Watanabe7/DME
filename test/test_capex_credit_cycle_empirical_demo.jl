# 部門別CAPEX・信用循環モデル 実証統合デモ（examples/capex_credit_cycle_empirical_demo.jl）の
# テスト（Issue #251 / `P-11`）。
#
# カバレッジ（実証統合設計 §12.7 の4項目 + Issue #251 受け入れ条件）:
#   1. fixture モードで catalog→raw→measurement→dataset→較正→識別→推定→episode→replay→
#      検証→感応度を公開APIのみで完走する（§12.7-59）
#   2. 2回実行で canonical artifact（identity chain）と主要数値が一致する（§12.7-60）
#   3. 保存済み artifact から同一結果を再構築できる（§12.7-61）
#   4. 成功 run で会計検証12項目が acc_pass になる（§12.7-62）
#   5. literature/default・calibrated・estimated が artifact 上で区別される
#   6. 成果物に API キー・トークンらしき文字列が含まれない
#   7. 成果物に Digital Twin/Digital Shadow/デジタルツインが含まれない（ADR 0014）
#   8. 成果物に実証統合設計 §10.4 の caveats を含む
#   9. ネットワークアクセスを行わない（FredClient/EStatClient/HTTP を用いない）

const JSON3 = DME.JSON3

# 例スクリプトは PROGRAM_FILE ガードで直接実行時のみ走る。include では
# run_capex_credit_cycle_empirical_demo などの関数定義のみ読み込まれる。
const CCED_SCRIPT_PATH =
    joinpath(@__DIR__, "..", "examples", "capex_credit_cycle_empirical_demo.jl")
include(CCED_SCRIPT_PATH)

@testset "部門別CAPEX・信用循環モデル 実証統合デモ（Issue #251 / P-11）" begin
    # ---- 1. 完走・成果物一式（§12.7-59） ------------------------------------
    @testset "完走: fixtureモードで公開APIのみで完走し成果物が非空" begin
        dir = mktempdir()
        out = run_capex_credit_cycle_empirical_demo(; outdir = dir, verbose = false)

        @test out.determinism_ok
        @test out.reload_ok
        @test out.accounting_ok
        @test out.accounting_checks_performed > 0

        for name in (
            "artifact.json",
            "catalog.json",
            "raw_observation_manifest.json",
            "measurement_manifest.json",
            "calibration.json",
            "identification.json",
            "parameter_set_literature_default.json",
            "parameter_set_calibrated.json",
            "parameter_set_estimated.json",
            "episode.json",
            "replay_literature_default.json",
            "replay_calibrated.json",
            "replay_estimated.json",
            "validation.json",
            "robustness.json",
            "report.md",
            "determinism_check.json",
        )
            path = joinpath(dir, name)
            @test isfile(path)
            @test filesize(path) > 0
        end
    end

    # ---- 2. 決定性: 2回実行で identity chain・主要数値が一致する（§12.7-60） --
    @testset "決定性: 2回実行で identity chain が一致する" begin
        dir = mktempdir()
        out = run_capex_credit_cycle_empirical_demo(; outdir = dir, verbose = false)
        @test out.determinism_ok

        determinism = JSON3.read(read(joinpath(dir, "determinism_check.json"), String))
        @test determinism.determinism_ok
        @test determinism.run1_identity.dataset_hash ==
              determinism.run2_identity.dataset_hash
        @test determinism.run1_identity.targets_hash ==
              determinism.run2_identity.targets_hash
        @test determinism.run1_identity.parameter_set_hash ==
              determinism.run2_identity.parameter_set_hash
        @test determinism.run1_identity.episode_hash ==
              determinism.run2_identity.episode_hash
        @test determinism.run1_identity.replay_hash == determinism.run2_identity.replay_hash

        # artifact.json 自体も2回の独立実行間で identity が一致する（別ディレクトリへの
        # 独立した保存でも同一 fixture・同一 config から同一 hash が再現される）。
        dir2 = mktempdir()
        out2 = run_capex_credit_cycle_empirical_demo(; outdir = dir2, verbose = false)
        artifact1 = JSON3.read(read(joinpath(dir, "artifact.json"), String))
        artifact2 = JSON3.read(read(joinpath(dir2, "artifact.json"), String))
        @test artifact1.identity.dataset_hash == artifact2.identity.dataset_hash
        @test artifact1.identity.targets_hash == artifact2.identity.targets_hash
        @test artifact1.identity.parameter_set_hash == artifact2.identity.parameter_set_hash
        @test artifact1.identity.replay_hash == artifact2.identity.replay_hash
    end

    # ---- 3. 保存済み artifact からの再構築（§12.7-61） -----------------------
    @testset "保存済みartifactから同一resultを再構築する" begin
        dir = mktempdir()
        out = run_capex_credit_cycle_empirical_demo(; outdir = dir, verbose = false)
        loaded = load_capex_empirical_artifact(dir)

        artifact = out.result.artifact
        @test loaded["identity"]["dataset_hash"] == artifact["identity"]["dataset_hash"]
        @test loaded["identity"]["targets_hash"] == artifact["identity"]["targets_hash"]
        @test loaded["identity"]["parameter_set_hash"] ==
              artifact["identity"]["parameter_set_hash"]
        @test loaded["identity"]["episode_hash"] == artifact["identity"]["episode_hash"]
        @test loaded["identity"]["replay_hash"] == artifact["identity"]["replay_hash"]
    end

    # ---- 4. 会計検証12項目（§12.7-62） --------------------------------------
    @testset "成功runで会計検証12項目がacc_pass" begin
        dir = mktempdir()
        out = run_capex_credit_cycle_empirical_demo(; outdir = dir, verbose = false)
        acc = out.result.accounting
        @test acc !== nothing
        @test accounting_passed(acc)
        @test acc.checks_performed > 0
        @test acc.checks_passed == acc.checks_performed
        @test isempty(acc.violations)
    end

    # ---- 5. literature/default・calibrated・estimated の区別 -----------------
    @testset "parameter set 3種が区別される" begin
        dir = mktempdir()
        out = run_capex_credit_cycle_empirical_demo(; outdir = dir, verbose = false)
        ps = out.result.parameter_sets
        @test Set(keys(ps)) == Set((:literature_default, :calibrated, :estimated))
        @test ps[:literature_default].kind === :literature_default
        @test ps[:calibrated].kind === :calibrated
        @test ps[:estimated].kind === :estimated
        # kind が hash payload に含まれるため hash は必ず異なる（実証統合設計 §11.3）
        hashes = Set([
            ps[k].parameter_set_hash for k in (:literature_default, :calibrated, :estimated)
        ])
        @test length(hashes) == 3

        runs = out.result.replay_runs
        @test runs[:literature_default].parameter_set.kind === :literature_default
        @test runs[:calibrated].parameter_set.kind === :calibrated
        @test runs[:estimated].parameter_set.kind === :estimated
        @test runs[:literature_default].status === :completed
        @test runs[:calibrated].status === :completed
        @test runs[:estimated].status === :completed
    end

    # ---- 6. 秘密情報の非混入 --------------------------------------------------
    @testset "APIキー・トークンらしき文字列が成果物に含まれない" begin
        dir = mktempdir()
        run_capex_credit_cycle_empirical_demo(; outdir = dir, verbose = false)
        for name in readdir(dir)
            endswith(name, ".json") || endswith(name, ".md") || continue
            txt = read(joinpath(dir, name), String)
            @test !occursin(r"api[_-]?key"i, txt)
            @test !occursin(r"bearer\s+[A-Za-z0-9._-]{10,}"i, txt)
            @test !occursin(homedir(), txt)
        end
    end

    # ---- 7. Digital Twin / Digital Shadow を名乗らない（ADR 0014） -----------
    @testset "Digital Twin / Digital Shadow を名乗らない" begin
        dir = mktempdir()
        run_capex_credit_cycle_empirical_demo(; outdir = dir, verbose = false)
        for name in readdir(dir)
            endswith(name, ".json") || endswith(name, ".md") || continue
            txt = read(joinpath(dir, name), String)
            @test !occursin(r"digital\s*twin"i, txt)
            @test !occursin(r"digital\s*shadow"i, txt)
            @test !occursin("デジタルツイン", txt)
        end
    end

    # ---- 8. caveats の必須記載（実証統合設計 §10.4） -------------------------
    @testset "report.md に §10.4 の caveats を含む" begin
        dir = mktempdir()
        run_capex_credit_cycle_empirical_demo(; outdir = dir, verbose = false)
        report_txt = read(joinpath(dir, "report.md"), String)
        key_phrases = (
            "point-in-time replay ではなく",
            "因果妥当性・景気後退確率・投資助言",
            "企業開示を較正入力に用いていない",
            "投資判断・政策提言を目的としない",
        )
        for phrase in key_phrases
            @test occursin(phrase, report_txt)
        end
    end

    # ---- 9. ネットワークアクセスを行わない -----------------------------------
    @testset "FredClient・EStatClientを生成しない（ネットワーク非依存）" begin
        script_txt = read(CCED_SCRIPT_PATH, String)
        @test !occursin("FredClient", script_txt)
        @test !occursin("EStatClient", script_txt)
        @test !occursin("HTTP.", script_txt)
        @test !occursin(":rest_api", script_txt)
        @test occursin(":fixture", script_txt)
    end

    # ---- 10. episode 選定層（#247）を honest に呼び出す ----------------------
    @testset "episode assessment: 本デモの合成episodeと実H1–H6 registryの両方を評価する" begin
        dir = mktempdir()
        out = run_capex_credit_cycle_empirical_demo(; outdir = dir, verbose = false)
        @test out.episode_status in CAPEX_CC_EPISODE_STATUSES
        @test out.result.registry_assessments isa Vector{CapexEpisodeAssessment}
        @test length(out.result.registry_assessments) == length(CAPEX_CC_EPISODE_SPECS)
    end
end
