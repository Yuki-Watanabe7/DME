# 品質チェックとローカル検証手順

> 関連Issue: #53

---

## 1. 自動品質チェック（CI）

テストスイート（`Pkg.test()`）に以下の品質チェックが組み込まれており、CI で自動実行される。

| ツール | 目的 | 実行方法 |
|--------|------|----------|
| **Aqua.jl** | パッケージ品質（exports・依存互換性・stale deps・型海賊行為等）| `Pkg.test()` に含まれる |
| **JuliaFormatter** | コードフォーマット統一（`.JuliaFormatter.toml` の設定を使用）| 下記参照 |

---

## 2. JuliaFormatter の手動実行

```bash
# フォーマット確認（変更なし）
julia --project=. -e "using JuliaFormatter; format(\"src/\"; overwrite=false) ? println(\"OK\") : println(\"要フォーマット\")"

# フォーマット適用
julia --project=. -e "using JuliaFormatter; format(\"src/\")"
```

コードを変更した場合は PR 前にフォーマットを確認すること。
フォーマット設定は `.JuliaFormatter.toml` に記載されている。

上記コマンドは `--project=.`（メインの依存関係環境）で実行しているように見えるが、
`Aqua` / `JuliaFormatter` / `Test` は `test/Project.toml` のテスト専用環境に属する。
実際に使われるバージョンは `test/Manifest.toml` で固定されている（[2.1 節](#21-テスト依存のバージョン固定)参照）。

---

### 2.1 テスト依存のバージョン固定

`Aqua` / `JuliaFormatter` / `Test` は `test/Project.toml` で宣言し、`test/Manifest.toml` で
解決済みバージョンを固定している。これにより `Pkg.test()` は常に同じバージョンの
`JuliaFormatter` を使用し、上流のマイナー/パッチリリースでフォーマットルールが変わっても
CI が予告なく壊れることを防ぐ。

`test/Project.toml` の `[deps]` のうち、ルート `Project.toml` の `[deps]` に含まれない
パッケージ（= テスト専用依存）は、ルートの `[extras]` / `[targets]` と一致していなければ
ならない（`Aqua.test_all` の `project_extras` チェックが検証する）。テスト専用依存を
追加・変更する場合は両方を更新すること。

なお `Plots` のようにルート `Project.toml` の `[deps]` に既に含まれるパッケージは、
テストコードから直接 `using Plots` する場合のみ `test/Project.toml` にも追加する
（`test/Project.toml` が存在すると、テスト環境はルート環境をスタックしないため）。

```bash
# テスト依存を更新した場合、test/Manifest.toml を再生成する
julia --project=test -e 'using Pkg; Pkg.instantiate()'
# または特定パッケージだけバージョンを上げる場合
julia --project=test -e 'using Pkg; Pkg.update("JuliaFormatter")'

git add test/Project.toml test/Manifest.toml
```

`JuliaFormatter` を更新した際は、新バージョンのルールで `src/` 全体が
フォーマット済みかを必ず確認すること（2 節のコマンド）。

---

## 3. 導入を見送ったチェック / 無効化したチェック / fast lane から分離したチェック

| ツール | 理由 |
|--------|------|
| **JET.jl**（push/PRのfast lane） | 数値計算コード・動的 JSON 応答を扱うコードでの誤検知が多く、fast lane（push/PR毎）に組み込むと CI が不安定化するリスクがある。Issue #211 で「必要になった時点」として正式導入したが、fast lane ではなく schedule/workflow_dispatch の **slow lane**（[`.github/workflows/quality-slow.yml`](../../.github/workflows/quality-slow.yml)）専用とすることでこのリスクを回避した。詳細は [§5.5](#55-jetjl-slow-laneissue-211) |
| **BenchmarkTools.jl**（push/PRのfast lane） | CI runner 上の絶対実行時間はノイズが大きく、push/PR 毎に測っても意味のある信号にならないうえ、通常CIの所要時間を押し上げる。Issue #212 で slow lane（**weekly** schedule / workflow_dispatch）専用として導入した。回帰判定は advisory で、PR 必須の performance gate にはしない。詳細は [§5.6](#56-benchmarktoolsjl-slow-laneissue-212) |
| **Documenter.jl**（push/PRのfast lane） | `ci.yml` は `paths-ignore: docs/**, **/*.md` を持つため docs-only 変更を検査できず、また `src/**` 変更のたびに fast lane へビルドを足すと通常CIの所要時間を押し上げる。Issue #213 で、`docs/**`・`src/**`・`**/*.md` の変更で起動する**専用 workflow**（[`.github/workflows/docs.yml`](../../.github/workflows/docs.yml)）として導入した。`ci` job とは別 job のため通常CIは遅くならない。詳細は [§5.7](#57-documenterjl-docs-laneissue-213) |
| **Aqua.jl の `persistent_tasks`** | DME は JuMP・Ipopt・Plots など重量級のバイナリ依存を持つ。このチェックは独立した一時プロジェクトで DME を再解決・再プリコンパイルするサブプロセスを spawn するため、メインテストプロセスと同時実行時に CI ランナーのメモリ/CPU 制約でサブプロセスが完了前にクラッシュし、CI が不安定化する（ローカルでは安定して成功する）。`test/test_quality.jl` で `persistent_tasks = false` により無効化 |

---

## 4. テスト実行

```bash
# 全テスト実行
julia --project=. -e "using Pkg; Pkg.test()"

# 特定のテストセットのみ実行（例）
julia --project=. -e '
  using DME, Test
  @testset "util" begin
    # test/runtests.jl の対象ブロックをペースト
  end
'
```

### テスト実行が必要な変更種別

以下を変更した場合はフルセットの検証は行わないが、少なくとも変更対象のコードや関数に対する簡単なsmoke testを行う。可能であれば、対象テストセット相当の最小確認も行う。(フルセットの検証はPR時のCIで行う。)

- Julia コード（`src/` 配下）
- `Project.toml` / `Manifest.toml`
- テストコード（`test/` 配下）
- CI 設定（`.github/workflows/` 配下）

### テスト実行が不要な変更種別

- `docs/` 配下のみの変更（docs-only）

docs-only の変更をする場合は、PR 本文または最終コメントに「docs-only のため Julia test は未実行」と明記すること。

---

## 5. `software-quality-dashboard` 向け構造化Export

`Pkg.test()`（Aqua.jl・JuliaFormatter・Coverage.jl を含む）の実行結果を、
`software-quality-dashboard` が読み取る `julia-quality-export/v1` として機械可読な JSON へ
書き出せる。CI の fast lane（`.github/workflows/ci.yml`）はこれを既定の Test ステップとして
使う（テストの合否判定そのものは変えない。§5.2 参照）。

```bash
# 推奨: Coverage.jl（line coverage）も含めて実測する（CI が使うのと同じコマンド）
julia --project=. scripts/quality_export_coverage.jl
# 既定出力先: artifacts/quality/quality-export.json（DME_QUALITY_EXPORT_OUTPUT で変更可能）

# Coverage.jl 抜き（Pkg.test/Aqua.jl/JuliaFormatter のみ）でよい場合
DME_QUALITY_EXPORT_ENABLED=1 julia --project=. -e "using Pkg; Pkg.test()"
```

生成した export を検証したい場合:

```bash
julia --project=. scripts/validate_quality_export.jl
```

詳細（result 構造・Test.jl 依存の設計判断・限界）は
[Julia品質Export Contract](../contract/julia-quality-export-v1.md) を参照。

### 5.1 Coverage.jl の対象/除外パス

`src/**` のみを測定対象にする（`examples/`・`scripts/`・`test/` は対象外。
`src/quality/quality_capture.jl` の `QUALITY_COVERAGE_TARGET_PATHS`/`QUALITY_COVERAGE_EXCLUDED_PATHS`
が唯一の定義箇所）。JuMP・Ipopt・Plots 等の依存パッケージ本体のコードは `src/` の外
（`~/.julia/packages/...`）にあるため、この対象範囲だけで自動的に除外される。

### 5.2 CI 時間への影響（Issue #209 導入前後の実測）

`--code-coverage=user` によるコード coverage の instrumentation はテスト実行そのものを
遅くする。導入前後の実測値（`ci`/`Pkg.test()` ジョブの `Test` ステップのみを比較。
`Install dependencies` はキャッシュ状態で変動するため除外）:

| 実行環境 | 導入前 | 導入後 | 増分 |
|---|---|---|---|
| ローカル（Apple Silicon、依存パッケージプリコンパイル済み、総所要時間 wall clock） | `julia --project=. -e "using Pkg; Pkg.test()"`: 約2分59秒 | `julia --project=. scripts/quality_export_coverage.jl`: 約4分07秒 | 約+68秒（約+38%） |
| CI（GitHub Actions、Linux ランナー、`Test` ステップのみ） | 3分31秒（[#208 PR の run](https://github.com/Yuki-Watanabe7/DME/actions/runs/31201475889)） | 5分17秒（[#209 PR の run](https://github.com/Yuki-Watanabe7/DME/actions/runs/31232109840)） | 約+106秒（約+50%） |

Line coverage の結果（実測値。`src/**` 全体）: `covered_lines=7416`・`coverable_lines=7747`
（約95.7%）。今後の増分は `.github/workflows/ci.yml` の実行時間履歴（GitHub Actions）で
継続的に確認すること。

初期導入では coverage 計測失敗や増分そのもので CI・merge を止めない（Issue #209
「初期導入では Quality Gate で merge を阻止せず、baseline 収集を優先する」）。50%程度の
増分は許容範囲と判断したが、将来さらに増加する場合は fast lane からの分離（slow lane 化）を
検討する。

### 5.3 Coverage.jl 自体が失敗した場合

`Coverage.jl` の集計失敗（`Coverage.process_folder` の例外・`coverable_lines <= 0` による
計測不能判定を含む）は、`Coverage.jl` の export エントリを `status=:failure` にするだけで、
テストの成否や CI の終了コードには影響しない。テストスイート自体の失敗（`Pkg.test()` が
検出する失敗）は従来どおり CI を失敗させる。両者は独立に扱う
（詳細: [Julia品質Export Contract §8](../contract/julia-quality-export-v1.md#8-実行方法)）。

### 5.4 CI での Artifact 公開

CI（`.github/workflows/ci.yml`）は `quality-export.json` を検証した上で GitHub Actions
Artifact として公開する（job の成否に関わらず `if: always()`）。Artifact 名は
`dme-julia-quality-v1-${{ github.sha }}`（schema validation を通った場合）。schema に反する
export（および Test ステップの致命的失敗で export 自体が生成されなかった場合）は
`dme-julia-quality-v1-invalid-${{ github.sha }}` という別名の診断用 Artifact としてのみ
公開し、正規 Artifact 名の下では公開しない。Artifact 名規約・retention・rerun 時の置換方針・
権限最小化の詳細は
[Julia品質Export Contract §8.1](../contract/julia-quality-export-v1.md#81-github-actions-artifact-公開issue-210)
を参照（Issue #210）。

### 5.5 JET.jl slow lane（Issue #211）

静的解析（型不安定性・実行時エラー候補の検出）を JET.jl で行う。push/PR の fast lane
（`Pkg.test()`）には**含まれない** — schedule（nightly）/workflow_dispatch の
[`.github/workflows/quality-slow.yml`](../../.github/workflows/quality-slow.yml) 専用（§3）。

```bash
# ローカルで slow lane と同じ解析を実行する
julia --project=. scripts/quality_export_jet.jl
# 既定出力先: artifacts/quality/quality-export-jet.json（fast laneの quality-export.json とは別ファイル）
```

対象は `JET.report_package(DME; target_modules=(DME,))`（DME に定義された全メソッド、
`target_modules` で依存パッケージ内部のみで完結する finding を除外）。対象範囲の決定根拠・
severity の扱い（advisory、CI gate には使わない）・実測値は
[Julia品質Export Contract §4.3](../contract/julia-quality-export-v1.md#43-jetjl-の-result) を参照。

`scripts/quality_export_jet.jl` は driver・`scripts/jet_analysis_worker.jl` は実際に
JET.jl を実行する worker で、driver が worker を subprocess として起動し
`DME_QUALITY_EXPORT_JET_TIMEOUT_SECONDS`（既定30分）を期限として管理する（設計判断:
`scripts/jet_analysis_worker.jl` 冒頭コメント、方法D: [Julia品質Export Contract §8](../contract/julia-quality-export-v1.md#8-実行方法)）。

JET.jl 統合の回帰テスト（`test/test_quality_jet.jl`）は opt-in（`Pkg.test()` の既定経路には
含まれない）:

```bash
DME_QUALITY_EXPORT_JET_ENABLED=1 julia --project=. -e "using Pkg; Pkg.test()"
```

**fast lane への影響**: `test/Project.toml`（テスト専用環境）に JET.jl を追加したため、
`test/Manifest.toml` が変わった直後の cold cache（`julia-actions/cache` が未ヒット）な
`Pkg.test()` 実行では、JET.jl 自体とその推移的依存（Revise・JuliaInterpreter 等）の
precompile コストが一度だけ発生する（ローカル実測で数十秒〜1分程度）。fast lane のテスト
コード自体は JET.jl を `using` しないため、cache が warm な通常運用ではこの追加コストは
ほぼ発生しない。GitHub Actions 上の実測値は今後の CI 実行履歴で継続的に確認する
（Coverage.jl 導入時の§5.2と同じ実測方針）。

### 5.6 BenchmarkTools.jl slow lane（Issue #212）

代表的な計算経路の実行時間を測定し、リポジトリ内 baseline との比較結果を export する。
JET.jl と同じく push/PR の fast lane には**含まれない** —
[`.github/workflows/quality-slow.yml`](../../.github/workflows/quality-slow.yml) の
`benchmark` job（schedule は **weekly**、加えて workflow_dispatch）専用（§3）。

```bash
# ローカルで slow lane と同じ測定を実行する（所要 約40秒: 6 benchmark × 5秒予算 + 起動）
DME_BENCHMARK_RUNNER_LABEL=<マシン識別子> julia --project=. scripts/quality_export_benchmark.jl
# 既定出力先: artifacts/quality/quality-export-benchmark.json
#   （fast laneの quality-export.json・JET slow laneの quality-export-jet.json とは別ファイル）
```

対象は6経路（Solow 収束経路 / RBC IRF / SIM 型 SFC / Keen RK4 / 部門別CAPEX・信用循環 Sc3 /
real-rate model artifact のシリアライズ）。外部ソルバー（Ramsey の Ipopt・NLsolve）・
データ層（ネットワーク I/O）・LLM 層・可視化は対象外。選定理由・除外理由・compile time を
測定から外す手当ては
[Julia品質Export Contract §4.4](../contract/julia-quality-export-v1.md#44-benchmarktoolsjl-の-result)
と [`scripts/benchmark_suite.jl`](../../scripts/benchmark_suite.jl) 冒頭コメントを参照。

**回帰判定は advisory**: `regression_status`（`improved`/`stable`/`regressed`/`unavailable`）は
事実の記録であり、CI の合否判定には使わない。`regressed` でも slow lane は失敗せず、終了コードも
0 のまま。margin は benchmark ごとに 25〜50%（実測した変動幅に基づく。契約 §4.4「margin の根拠」）。

**baseline は手動更新**: [`benchmarks/baseline.json`](../../benchmarks/baseline.json) を
`scripts/update_benchmark_baseline.jl`（`--reason` 必須）で更新し、PR としてレビューする。
CI は baseline を書き換えない。環境（`environment_key`）が一致する baseline とだけ比較し、
baseline が無い場合は pass ではなく `unavailable` として報告する。手順は
[`benchmarks/README.md`](../../benchmarks/README.md)。

BenchmarkTools.jl 統合の回帰テスト（`test/test_quality_benchmark.jl`）は opt-in
（`Pkg.test()` の既定経路には含まれない）:

```bash
DME_QUALITY_EXPORT_BENCHMARK_ENABLED=1 julia --project=. -e "using Pkg; Pkg.test()"
```

**fast lane への影響**: JET.jl 追加時（§5.5）と同じく、`test/Project.toml` へ
BenchmarkTools.jl を追加したことで cold cache 時に一度だけ precompile コストが発生する
（ローカル実測で約5〜7秒）。fast lane のテストコード自体は BenchmarkTools.jl を `using`
しないため、warm cache の通常運用では追加コストはほぼ発生しない。

### 5.7 Documenter.jl docs lane（Issue #213）

`src/**/*.jl` の docstring から API リファレンスをビルドし、その結果を export する。
DME は Documenter.jl を **公開サイトの生成器ではなく docstring のビルド検査器** として
使う（`deploydocs` は呼ばず GitHub Pages へ公開しない。決定は
[ADR 0017](../adr/0017-documenter-adoption-and-docs-quality-export.md)）。

fast lane にも slow lane にも属さず、`docs/**`・`src/**`・`**/*.md` の変更で起動する専用
workflow（[`.github/workflows/docs.yml`](../../.github/workflows/docs.yml)）で実行する
（`ci.yml` は `paths-ignore: docs/**, **/*.md` を持ち docs-only 変更を検査しないため）。

```bash
# 0. docs 環境を用意する（初回のみ）
julia --project=docs -e "using Pkg; Pkg.instantiate()"

# 1. ビルドだけを確認する（品質Export は書かない。ローカル実測 約15秒 + DME のロード。
#    CI 実測では job 全体 約8分だが、その大半は依存の instantiate で、ビルド自体は約30秒）
julia --project=docs docs/make.jl
#   生成物: docs/build/（.gitignore 済み。docs/build/index.html をブラウザで開ける）

# 2. 品質Export まで書き出す（CI の docs lane が使うのと同じコマンド）
julia --project=. scripts/quality_export_docs.jl
# 既定出力先: artifacts/quality/quality-export-docs.json
#   （他 lane の quality-export{,-jet,-benchmark}.json とは別ファイル）
```

**ビルド設定の正本は [`docs/make.jl`](../make.jl)**（`dme_build_docs`）。対象ページ・
`checkdocs`・`warnonly`・`doctest`/`linkcheck` の有無はすべてここにあり、worker
（`scripts/docs_build_worker.jl`）は `include` して呼ぶだけ。人手のローカル実行と CI の測定が
同じ設定であることを構造的に保証している。

**API ページの対象ファイルは自動で決まる**: `docs/src/api/*.md` の `@autodocs` は
`docs/make.jl` が `src/` を走査して作る `DME_API_PAGES` を参照する。`src/` に新しい
**サブディレクトリ**を追加して `DME_API_GROUPS` へ割り当てないとビルドが失敗する
（docstring が黙ってサイトから欠落しないようにするための検査）。既存ディレクトリへの
ファイル追加は何もしなくてよい。

**warning はビルド失敗にしない / ビルド失敗は CI 失敗にする**:

- `:cross_references`（docstring からサイト外のリポジトリ内文書へのリンク等）は警告に
  留め、件数とカテゴリを export に残す。
- それ以外の Documenter エラークラス（`:docs_block`・`:missing_docs`・`:parse_error` 等）は
  ビルド失敗（`build_status = "failed"`）とし、docs workflow はこの場合に job を失敗させる。
- カテゴリごとの割り当ては
  [Julia品質Export Contract §4.5](../contract/julia-quality-export-v1.md#45-documenterjl-の-result)
  「warning category ごとの方針」を参照。

**docs 環境の依存を変更した場合**は `julia --project=docs -e 'using Pkg; Pkg.instantiate()'`
を実行し `docs/Manifest.toml` もコミットすること（`test/` 環境と同じ運用。§2.1）。

**fast lane への影響**: Documenter.jl は `test/Project.toml` ではなく専用の
`docs/Project.toml` にあるため、`Pkg.test()`（fast lane）の依存も所要時間も変わらない。
