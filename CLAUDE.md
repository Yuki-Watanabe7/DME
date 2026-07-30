# CLAUDE.md

DME は動学的マクロ経済モデルを Julia で実装したパッケージです。
モデル群（Ramsey / Solow / RBC / IS-LM / AD-AS / New Keynesian / Mundell-Fleming / VAR / Keen）の計算・可視化に加え、
実データ接続（FRED・e-Stat）と LLM による結果説明生成をサポートします。
このファイルは Claude Code がこのリポジトリで作業する際の入口ガイドです。

## リポジトリ構成

| パス | 内容 |
|---|---|
| `src/models/` | 各モデルの実装 |
| `src/core/` | モデル共通インターフェース・SimulationResult・比較・可視化 |
| `src/data/` | 実データ層（DataSeries・前処理・FRED / e-Stat クライアント） |
| `src/llm/` | LLM 層（AnalysisContext・プロンプト・provider 抽象化） |
| `src/artifacts/` | 他リポジトリと共有する再現可能 JSON artifact（RFC 8785 正準化・real-rate model artifact） |
| `src/numerics/` | グリッド・補間などの数値計算ユーティリティ |
| `examples/` | 機能別デモスクリプト（API キー不要で完走） |
| `test/` | テスト（`test/fixtures/` に API fixture、`test/Project.toml`/`test/Manifest.toml` にテスト専用依存を固定） |
| `docs/` | 詳細ドキュメント（下表参照） |

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
4. **test/Project.toml を変更した場合**: `julia --project=test -e 'using Pkg; Pkg.instantiate()'` を実行し、`test/Manifest.toml` もコミットすること。テスト専用依存（`Aqua`・`JuliaFormatter`・`Test`）を追加・変更する場合はルート `Project.toml` の `[extras]`/`[targets]` も更新すること（詳細: [品質チェックとローカル検証手順](docs/development/quality_checks.md) 2.1 節）。

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

各モデルの解説は `docs/models/<モデル名>.md`（ramsey / solow / rbc / islm / adas / new_keynesian / mundell_fleming / var / keen / sim_sfc、テンプレートは template.md）。全ドキュメントの一覧は [README のドキュメント節](README.md#ドキュメント) を参照。

| ドキュメント | 内容 |
|---|---|
| [API リファレンス](docs/api.md) | Public/Internal API の一覧・シグネチャ・移行ガイド |
| [モデル選択ガイド](docs/model_selection_guide.md) | 問い・現象からモデルを選ぶためのリファレンス・比較表・決定木 |
| [モデル能力・概念定義 metadata](docs/model_capabilities.md) | 各モデルの部門・金融機構・対応API・実証能力の機械可読プロファイルと変数の概念定義・横断比較表・追加手順 |
| [出力結果の読み方](docs/simulation_outputs.md) | 定常状態・移行経路・IRF・水準/対数偏差の概念 |
| [モデル共通インターフェース](docs/architecture/model_interface.md) | 抽象型階層・命名方針・新規モデル追加ルール |
| [パッケージ構成とアーキテクチャ概要](docs/architecture/package_structure.md) | ソースツリー・include 順序・Node 型階層・補間・モデル内部関数 |
| [AIエコノミスト化アーキテクチャ](docs/architecture/ai_economist.md) | 分析カーネル・データ層・LLM 層の全体構成とデータフロー |
| [LLM接続層の設計](docs/architecture/llm_layer.md) | LLM層の責務・入出力仕様・禁止事項・安全性方針 |
| [LLM Provider設定ガイド](docs/architecture/llm_provider.md) | provider抽象化・OpenAI設定・MockProvider・差し替え方法 |
| [AnalysisContext 設計](docs/architecture/analysis_context.md) | LLMへ渡す構造化コンテキスト型の設計・構造・利用例 |
| [クロスモデル推論層の設計](docs/architecture/cross_model_reasoning.md) | Keen 実証結果と既存モデルの概念対応・mapping 導出・出力 section・安全性（ADR 0006） |
| [マクロイベント変換契約](docs/architecture/macro_event_contract.md) | 観測イベント/解釈シグナル/シナリオ仮定/適用モデル入力の4層分離・共通イベント属性・イベント型9種のモデル入力マッピング表・適用先を外生変数7個に限定する決定・magnitude捏造禁止・同時/競合/重複イベントの決定論的処理・イベントログと再現契約・API境界6責務 |
| [シナリオ時間軸の意味論](docs/architecture/scenario_time_semantics.md) | 四半期の内部時刻表現（整数t+period_zero）・期首一括適用（期内処理順序ステップ1）・公表日/経済的有効日/判明時刻の区別・適用四半期の割当規則・持続/減衰の時間形状6種の離散定義・period と known_at の2軸と as-of 規則 |
| [Keen–SFC 概念対応・比較レポート](docs/analysis/keen_sfc_comparison.md) | Keen と最小 SIM 型 SFC モデルの概念対応表・比較不能の理由・会計/動学機構の差・数値比較の可否・次期 Minsky-SFC のギャップ |
| [LLM出力の安全性・免責・禁止表現ルール](docs/llm_safety.md) | 禁止表現・必須記載・プロンプトテンプレート・出力チェックリスト |
| [DataSeries / MacroDataset 利用ガイド](docs/data/data_series_guide.md) | 実データ標準型の構造と操作 |
| [モデル変数と実データ系列のマッピング表](docs/data/variable_mapping.md) | 各モデル変数と候補実データ系列の対応・単位・変換注意事項 |
| [実データ前処理ユーティリティ](docs/data/preprocess.md) | 欠損値補完・対数・差分・移動平均・標準化・頻度変換などの使用例 |
| [FRED API 接続ガイド](docs/data/fred.md) | FRED API クライアントの使い方・API キー設定・fixture モード |
| [e-Stat API 接続ガイド](docs/data/estat.md) | e-Stat API クライアントの使い方・appId 設定・日本統計系列・fixture モード |
| [日本マクロデータ接続 設計方針](docs/data/japan_macro_sources.md) | BOJ・内閣府・財務省・総務省のデータソース整理・優先順位・ライセンス |
| [小国開放経済モデル設計方針](docs/models/open_economy_design.md) | 候補モデル比較・最小実装選定（Mundell-Fleming）・実データ候補系列 |
| [Minsky系金融不安定性モデル設計方針](docs/models/minsky_design.md) | 候補モデル比較（Keen / Ryoo / SFC）・初版採用モデル選定・実データ候補系列 |
| [Minsky系（Keen）モデル DME統合設計](docs/models/minsky_integration_design.md) | Keen モデルのインターフェース適合・ODE ソルバー接続・出力スキーマ・LLM メタデータ・テスト設計 |
| [Minsky 資金調達区分診断](docs/models/minsky_regime_diagnostics.md) | Hedge / Speculative / Ponzi の操作的定義・元本返済代理仮定・型/関数契約・限界の設計 |
| [Minsky 連続診断指標・サマリー](docs/models/minsky_diagnostics_summary.md) | カバレッジ比率・マージン・regime滞在比率・peak/minimum・発散時点の指標定義とサマリー契約 |
| [Keen モデル 実証化戦略](docs/models/keen_empirical_strategy.md) | 実データ接続の観測方程式・単位変換・共通頻度・年単位ODE↔四半期の時間軸契約・固定/推定パラメータ分離・識別戦略・検証方針 |
| [SFC 統合設計（最小 SIM 型モデル）](docs/models/sfc_integration_design.md) | SIM 型モデルの方程式・部門・金融資産・貸借対照表/取引フロー行列・会計恒等式の検証契約・型/API スケッチ |
| [部門別CAPEX・信用循環モデル 分析契約](docs/models/capex_credit_cycle_analysis_contract.md) | AI・半導体CAPEX調整の基準ユースケース（米国・四半期・起点事象・波及先部門）・判定問題 Q1–Q5・比較シナリオ・`broad_downturn` の操作的定義・初期MVP対象外・後続設計への参照契約 |
| [部門別CAPEX・信用循環モデル 因果グラフ](docs/models/capex_credit_cycle_causal_graph.md) | 起点事象から総産出までの有向グラフ・エッジ仕様（型/符号/時間差/関数形/観測可能性/根拠/逆因果・交絡/実装優先度）・増幅ループ R1–R4・減衰/遮断経路 B1–B7・株式評価の媒介経路限定・分岐条件候補と診断ラベル対応 |
| [部門別CAPEX・信用循環モデル 部門境界と変数定義](docs/models/capex_credit_cycle_sectors_variables.md) | 部門区分（案A 5部門）の候補比較・採用理由・部門責務・実物/金融フロー図・二重計上を避ける集計規約・役割（state/control/exogenous/diagnostic）の判定規則・遅延/パイプライン状態・変数辞書・DME共通API適合方針（平坦キー+部門接尾辞）・因果グラフへの差し戻し事項 |
| [部門別CAPEX・信用循環モデル ストック・フロー会計表](docs/models/capex_credit_cycle_stock_flow.md) | モデル外・残差部門 `SX` を含む貸借対照表行列/取引フロー行列・資金過不足によるブロック分割・全ストックの残高更新式と純資産更新式の導出・CAPEX資金調達恒等式とキャンセル/延期の閉じ変数指定・株価の作用経路（評価損を実体支出と同一視しない）・デフォルト非内生化の決定と診断可能性・会計恒等式12項目の検証契約・#99 Phase 5 SFC との責務境界・#165 変数辞書への追加提案と差し戻し事項 |
| [部門別CAPEX・信用循環モデル 責務境界とモデル間比較契約](docs/models/capex_credit_cycle_model_boundaries.md) | Keen/SIM/New Keynesian/VARと新規モデルの横断比較表（回答する問い・主要状態・強み・限界）・含める責務10件と含めない責務12件の採否・概念対応（mapping_type）と数値比較可否（comparability）の2層分離・`equivalent` が存在しないことの確定・同名変数の非同一視・イベント翻訳可否表と翻訳不能時の規則・`SimulationResult` を変更せず metadata 予約キーで methodology 相当を保持する決定・registry登録要件・#166の限定的会計整合性と#99 Phase 5 一般SFCの境界・移管候補 |
| [部門別CAPEX・信用循環モデル 動学方程式と数値計算契約](docs/models/capex_credit_cycle_equations.md) | 離散時間ハイブリッド方式と陽解法の選定・全12循環の遅れ指定と同時方程式の排除・期内処理順序10ステップに沿った全方程式（金融条件・期待/計画・資金制約と実行・受注配分・生産/出荷/在庫/価格・雇用/所得/消費・収益/分配・残高更新）・パラメータ辞書（構造/行動/政策の分類と固定/較正/推定区分・許容条件15件）・遅延パラメータ採用値と状態次元・baselineを成長率ゼロの定常状態とする決定と逆較正・定常条件17件・数値ガードの3層分離（経済制約/制約違反/打ち切り）とゼロ除算・警告・termination契約・ループ利得のヤコビアン/反実仮想併用評価・非線形性7箇所と閾値近傍診断・`credit-off` 固定パラメータ集合・`share_C` の反実仮想寄与分解 |
| [部門別CAPEX・信用循環モデル 観測方程式・識別戦略・検証方針](docs/models/capex_credit_cycle_empirical_strategy.md) | 観測可能性5分類（直接/構成/proxy/潜在/シナリオ仮定）と8変数群の割当・観測方程式の構成要素9項目（単位・部門範囲・名目実質・季節調整・頻度集計・vintage・aggregation/allocation/proxy）・NIPA年率の四半期換算と指数のアンカー水準化・`ext_demand_s` の残差構成規則・逆較正入力13項目の観測対応と定常水準の算出方式・データソース境界3層（FRED / economic-data-provider / 企業データ provider）と企業開示を較正入力に用いない決定・モデル層/データ層/較正層の境界とfixture最小セット・パラメータ6区分（FIX/CAL-SS/CAL-OBS/EST/SCN/SENS）の全パラメータ割当・推定ブロック `EB-1`–`EB-7` と固定推定順序・診断閾値を較正しない決定と `breadth` の較正不能性・識別リスク `ID-1`–`ID-7` と弱識別対応規則 `W1`–`W4`・履歴再生の必要条件 `NC-1`–`NC-7` と候補 `H1`–`H6`・数値fit/動学構造/比較/数値頑健性の4レイヤー分離・因果と予測上の限界14件 |
| [最小 SIM 型 SFC モデル](docs/models/sim_sfc.md) | `SIMModel` の目的・方程式・会計表・変数の単位/時点・財政ショック定義・限界・`sfc_result` adapter |
| [ADR 0001: Minsky系モデル選定](docs/adr/0001-minsky-model-selection.md) | Keen モデル採用の決定記録（`docs/adr/` は設計決定記録の置き場） |
| [ADR 0002: Keen モデルの統合方式](docs/adr/0002-minsky-integration-design.md) | 既存インターフェース準拠・自前 RK4・LLM 層無拡張という統合方針の決定記録 |
| [ADR 0003: Minsky 資金調達区分の診断層](docs/adr/0003-minsky-financing-regime-diagnostics.md) | 診断を Keen 本体から分離した読み取り専用層とし hysteresis を不採用とする決定記録 |
| [ADR 0004: Keen モデル実証化の識別戦略](docs/adr/0004-keen-empirical-calibration-strategy.md) | 米国基準・指数/比率の検証義務・Δt=0.25 の時間軸契約・固定/推定分離・ODE residual 採用の決定記録 |
| [ADR 0005: Keen 実証結果の AI 説明契約](docs/adr/0005-keen-ai-explanation-contract.md) | 観測・測定・推定・モデル出力・診断proxy・感応度を分離する根拠階層・source reference・禁止解釈・構造化出力/fallback の決定記録 |
| [ADR 0006: クロスモデル推論契約](docs/adr/0006-cross-model-reasoning-contract.md) | 概念対応（ModelConceptMapping）の明示・repository metadata 限定・同名変数の非同一視・比較不能の非統合（insufficient_comparability）・fit 比較制限の決定記録 |
| [ADR 0007: SFC 統合契約](docs/adr/0007-sfc-integration-contract.md) | SIM 型を初版 SFC とし、会計恒等式をモデル方程式と別の検証契約とする・不整合を自動補正せず構造化・SFCResult を別型で adapter 接続・compare v1 非破壊/v2 加算の決定記録 |
| [ADR 0008: Real-rate model artifact 統合契約](docs/adr/0008-real-rate-model-artifact-export.md) | economic-data-provider ADR 006 準拠の JSON artifact 生成・RFC 8785 正準化の実装範囲・hash 自己参照排除・UTC固定・rate_basis統一とP1Y集約方式・期待インフレ率の閉形式導出・horizon限定の決定記録 |
| [ADR 0009: 部門別CAPEX・信用循環モデルの責務境界](docs/adr/0009-capex-credit-cycle-model-responsibilities.md) | Keen拡張ではなく独立モデルとする・責務を判定問題Q1–Q5に必要な範囲へ限定する・会計整合性を残差部門つき部分閉鎖（accounting_closure=:partial）に限定しSFCを名乗らない・横断比較で保証するもの/しないものの分離・翻訳不能なイベントを適用しない・SimulationResult非変更とmetadata予約キー・Phase 0でモデル合成/連成を実施しない決定記録 |
| [ADR 0010: マクロイベント変換・シナリオ時間軸契約](docs/adr/0010-macro-event-scenario-contract.md) | イベントを4層に分離しbeliefを直接モデル入力へ変換しない・適用先を外生変数7個に限定し適用先の無いイベントを近似で寄せない・期首一括適用で期中適用/按分を行わない・絶対→乗算→加算の固定順合成で順序依存を排除・magnitude捏造禁止と感応度併記義務・制約違反を自動クリップせず拒否・event_set_hashによる再現契約の決定記録 |
| [ADR 0011: 部門別CAPEX・信用循環モデルの動学契約](docs/adr/0011-capex-credit-cycle-dynamics-contract.md) | 離散時間ハイブリッド・陽解法とし期内に同時方程式を置かない・全循環の遅れを本決定で列挙し実装者が個別に選ばない・主体最適化/均衡求解を置かない・期待に平滑化を重ねない・設備ギャップから建設中資本を差し引く・資金調達順序の固定と閉じ変数を実物側に置く・数値ガードを経済制約/制約違反/打ち切りの3層へ分離しNaN伝播を止める箇所を限定・推定対象を行動パラメータの一部に限定・baselineを成長率ゼロの定常状態とし逆較正で与える・ループ利得と寄与分解を反実仮想で定義し単純和で合成しない決定記録 |
| [ADR 0012: 部門別CAPEX・信用循環モデルの実証化契約](docs/adr/0012-capex-credit-cycle-empirical-contract.md) | 観測方程式を9項目のmetadata付き変換契約として定義し系列名マッピングで済ませない・系列の存在/定義/基準年の確認義務と指数のアンカー方式・aggregation/allocation/proxyの区別と按分キー感応度およびずれ方向の記載義務・NIPA年率の四半期換算・観測可能性5分類とproxy水準fitの不採用・企業開示を較正入力から除外し `R1a` を実証検証しない・`ai_exp` を観測不能としショック規模を較正せず走査結果として提示・`:as_of` を実装せず「その時点で判断できた」と述べない・定常水準をbaseline期間平均としトレンド除去しない・パラメータ6区分と `bh_` の一部のみ推定・推定ブロック7分割と固定順序・方程式別残差objectiveでtrajectory matchingを採らない・弱識別対応を事前規則化し推定後に選ばない・`bh_alpha_capex_s1` と `bh_cc_elas_s1` を同時推定しない・`ext_demand_s` の残差性の明示と負値クリップ禁止・Q4を履歴再生から外し `A` を観測から計算しない・診断閾値と `breadth` を較正しない・履歴再生候補の必要条件を先に固定しfitの良い期間を事後選択しない・4レイヤー分離と単一pass/failの不採用・実証fitを因果/危機確率/投資助言へ読み替えない決定記録 |
| [DME real-rate model artifact contract（vendor）](docs/contract/README.md) | economic-data-provider ADR 006 の JSON Schema・example artifact の vendor コピーと同期方針 |
| [品質チェックとローカル検証手順](docs/development/quality_checks.md) | Aqua.jl・JuliaFormatter・テスト実行方法 |
| [Keen 実証説明の LLM 回帰テストと安全性評価](docs/development/keen_llm_regression.md) | 契約/parser/シナリオ/golden/forbidden の評価レイヤー・安全性評価器・fixture 再生成/追加手順・任意 provider 評価 |
| [Keen 実証 AIエコノミスト統合デモ](docs/examples/keen_empirical_ai_economist.md) | データ取得→実証分析→根拠付きLLM説明→クロスモデル比較→provenance保存の再現可能な統合デモの実行手順・成果物・設定例 |
| [SFC対応 AIエコノミスト統合デモ](docs/examples/sfc_ai_economist.md) | baseline/財政ショック→SFC会計検証→比較API v2→Keen–SFC比較レポート→根拠付きLLM説明→provenance保存の再現可能な統合デモの実行手順・成果物・設定例 |
| [Real-rate model artifact 生成デモ](docs/examples/real_rate_model_artifact.md) | New Keynesian モデル→期待インフレ率・model-implied実質政策金利のartifact構築→検証→atomic保存までの再現可能な実行手順・成果物・economic-data-providerへの受け渡し手順 |
| [依存パッケージ管理と注意点](docs/development/dependency_management.md) | JuMP・Interpolations・NLsolve の注意点・Manifest.toml 管理 |
| [設定・環境変数管理ガイド](docs/development/configuration.md) | API キー設定・fixture/mock モード・CI 運用方針 |
