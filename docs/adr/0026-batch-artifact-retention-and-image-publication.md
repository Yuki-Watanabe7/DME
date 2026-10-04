# ADR 0026: batch artifact retention と batch image publication 契約

- **ステータス**: 採用
- **日付**: 2026-09-30
- **関連Issue**: [#252](https://github.com/Yuki-Watanabe7/DME/issues/252)（本決定）・[#295](https://github.com/Yuki-Watanabe7/DME/issues/295)（改訂 1: Julia 1.13.1）・前提 [#220](https://github.com/Yuki-Watanabe7/DME/issues/220)（stable CLI と batch container）。PAP 側: Yuki-Watanabe7/personal-analytics-platform#37（短命 Job の roadmap）・#38 / ADR 0015（RunTask Job 境界）・#156 / ADR 0017（production image admission 要件 A1–A9）・#41（DME の RunTask 実行。本決定の consumer）
- **前提ADR**: [ADR 0008](0008-real-rate-model-artifact-export.md)（正準 JSON・atomic write・UTC 固定）・[ADR 0016](0016-julia-quality-export-contract.md)（DME 所有の versioned contract と `schemas/`）
- **関連ドキュメント**: [batch container guide](../deployment/batch_container.md)（運用契約・検証・publish 手順・PAP への handoff）・[CLI contract](../cli.md)（run manifest・run identity・artifact sink の CLI 仕様）・[`schemas/dme-run-manifest-v1.schema.json`](../../schemas/dme-run-manifest-v1.schema.json)

---

## コンテキスト

#220 で `dme simulate solow` / `dme quality-export` の stable CLI と ECS RunTask 互換の Dockerfile ができた。
PAP の Job 基盤（PAP #37）は DME を第2の Job workload として Fargate `RunTask` で実行する（PAP #41）。その前に DME 側で
次の空白を埋める必要があった。

1. **artifact が task と一緒に消える。** CLI は `--out` 配下へ atomic に書くだけで、Fargate の ephemeral storage は
   task 停止とともに消える。task 終了後に artifact を追跡する方法が無かった。
2. **run の identity と provenance が無い。** 出力ファイル名は固定で再実行時に置き換えられ、「どの run が・どの
   commit / image から・どの task で・成功したか」を artifact から辿れなかった。image 内には git checkout が無いため、
   `quality-export` の `commit` は `0` × 40 になっていた。
3. **重複・失敗 run の意味が未定義。** EventBridge Scheduler の配信 retry と手動 rerun は重複・並行 task を生みうる
   （PAP ADR 0015 §5）が、DME の canonical write がそれに対して安全である根拠が無かった。
4. **image が PAP の admission 要件を満たさない。** `julia:1.12.6-bookworm` は 2026-07-11 から LTS の Debian 12 で
   新規 workload として admit されず（A3）、frozen patch tag に OS upgrade が無く（A5）、read-only root が未検証で
   コードと depot が runtime user の所有だった（A6）。OCI label・ECR scan・publish evidence も無かった（A1・A7・A8）。
5. **publish 経路が無い。** PAP #41 には immutable な digest・source commit・scan evidence が必要だった。

## 決定

### 1. artifact retention は S3 object sink とする

PAP が所有する S3 bucket / prefix を DME の artifact sink とし、DME が自分の task role でそこへ run bundle を書く。
比較した3案（Issue の decision criteria による）:

| 基準 | **S3 object sink（採用）** | EFS 等の mounted filesystem | ephemeral + CloudWatch |
|---|---|---|---|
| 既存 filesystem 契約との互換 | `--out` への書き込みはそのまま。sink は完成した local bundle の byte 単位の写し（key = run prefix + `--out` からの相対パス） | 完全に同一 | 同一だが task 停止で消える |
| identity / provenance / source commit | run manifest（§2）を run prefix に置く。object key 自体が run id を含む | run manifest を置けるが、読むには別 task から mount が必要 | log にしか残らない |
| atomic publish / partial | object PUT は object 単位で atomic。manifest を最後に置き commit marker にする。manifest の無い prefix = 未完了 | rename は atomic。ただし複数ファイルの bundle 単位では同じ marker 方式が必要 | 該当なし |
| overwrite / duplicate run | `If-None-Match: *` の条件付き PUT で既存 object を上書き不能にする（S3 が書き込み時に強制） | rename は上書きする。存在確認と書き込みの間に競合が残る | 該当なし |
| retention / cleanup | PAP の lifecycle rule を prefix 単位で設定できる | object 単位の失効が無く、cleanup Job が別途必要 | log group の retention |
| local development parity | local は filesystem のみ（従来どおり）。S3 互換サーバ（versitygw）で sink 経路を local / CI で検証できる | local の volume と同一 | 同一 |
| AWS 固有コードの侵入 | `src/batch/artifact_sink.jl` 1ファイルに閉じる（§5） | DME 側は 0 | 0 |
| 固定費 / 変動費 | 固定費 0。Standard 約 USD 0.025/GB-month と PUT 課金。JSON 数十 KB/run で PAP の envelope（DME persistence USD 0.02/月）に収まる | 固定費 0 だが Standard 約 USD 0.36/GB-month（S3 の約14倍）、mount target と NFS 用 SG（ADR 0012 の inbound 0 への例外）が必要 | log ingestion USD 0.76/GB。artifact を log に流すと PAP の 2 MB/run 上限を圧迫する |

**EFS を却下した理由**: DME の artifact は SQLite のような POSIX lock を必要とせず（SQD が EFS を選んだ理由が
当てはまらない）、読むたびに mount する task が要る。失効が無く、上書き防止を DME 側の競合を含む処理で
作ることになる。network 例外と単価の両方で S3 より重い。

**ephemeral + CloudWatch を却下した理由**: PAP #37 の Exit Criteria は「DME artifact を task 終了後に追跡可能」
であり、log は artifact の代替にならない（サイズ上限・構造の保証・再取得性が無い）。acceptance smoke だけで
canonical artifact が不要な場合に限る案で、本 Issue はそれに当たらない。

### 2. run bundle と run manifest

- 1回の `dme` コマンド実行を1つの **run** とする。コマンドは artifact を `--out` 配下へ atomic に書き、**最後に**
  同じディレクトリへ `run-manifest.json`（`dme-run-manifest/v1`、`schemas/dme-run-manifest-v1.schema.json`）を書く。
  既存の出力パス・artifact 形式・exit code は変えない（追加のみ）。
- manifest は run id と出所・status / exit code・failure category・開始/終了時刻・コマンドと実効オプション・
  source commit・DME / Julia version・image version / digest・実行環境（ECS task ARN・task definition・log stream）・
  publication 先・各 artifact の相対パス / schema / SHA-256 / サイズを持つ。
- **記録しないもの**: ホストの絶対パス（`--out` の値を含む）・credential・自由記述のエラーメッセージ
  （失敗は category のみ。本文は stderr = CloudWatch Logs）。
- source commit は image が OCI `revision` label と同じ build arg から設定する `DME_SOURCE_COMMIT`、image 外では
  checkout の HEAD。`quality-export` の `commit` も同じ値を使う（image 内で `0` × 40 にならない）。

### 3. run identity は単回使用とする

優先順位は `--run-id` > `DME_RUN_ID` > ECS task id（`ECS_CONTAINER_METADATA_URI_V4` の task ARN）> 生成値
（`local-<UTC>-<suffix>`）。ECS では通常 task id が run id になり、task ARN・log stream（`…/<task-id>`）・
S3 prefix が同じ id で結ばれる。run id は1回しか publish できない（§4）。

### 4. 重複・失敗 run の意味

| 事象 | exit code | local（`--out`） | sink |
|---|---|---|---|
| 成功 | 0 | artifact + manifest（`succeeded`） | artifact → manifest の順に PUT。manifest が揃って **published** |
| コマンド失敗（model error 等） | 3（1・4 も同様） | 失敗 manifest（artifact 無し・failure category） | 失敗 manifest を PUT。exit code はコマンドのもの |
| 入力エラー | 2 | 何も書かない（run は開始していない） | 何も書かない |
| sink の失敗（network・権限など） | 4 | 成功した bundle が残る | PUT 済み object は manifest 無し = **未完了**。canonical ではない |
| run id の再利用（配信 retry・誤設定） | 4 | 置き換わる（従来の filesystem 契約） | S3 が `412` で拒否。既存 run は不変 |
| task の停止（SIGTERM。止まらなければ `stopTimeout` 後の SIGKILL） | 通常 143、SIGKILL なら 137 | 最終ファイルは tmp + rename なので途中状態にならない。manifest は書かれない | manifest 無し = 未完了 |
| 手動 rerun・schedule の重複起動 | — | — | 新しい task = 新しい run id = 別 prefix。両方残り、互いに干渉しない |

Julia は SIGTERM を自分で処理し、多くの場合は約1秒で 143 で終了するが、Julia 自身の終了処理が block された
タイミングでは SIGKILL まで終了しない（タイミングを変えた 10 回の試行中 1 回（大きな artifact の書き込み中）と、
CPU 高負荷下の検証実行で 1 回観測）。DME には停止時に完了させる
作業が無く、どちらの経路でも上表の不変条件（manifest 無し・途中状態の最終ファイル無し）が成り立つため、Julia の
signal handler を無効化する（`--handle-signals=no` は GC などの安全性に影響する）ことはせず、PAP には短い
`stopTimeout` を推奨する。

DME の中では PUT を retry しない（応答喪失後の retry は `412` と区別できず、PAP ADR 0015 も work の自動 retry を
置かない）。やり直しは新しい run（新しい run id）で行う。「最新」を指す可変な pointer object は作らない。consumer は
run prefix を列挙し、manifest の `status` と `finished_at` で選ぶ。

### 5. AWS 固有コードは `src/batch/artifact_sink.jl` に閉じる

- S3 への PUT は AWS Signature Version 4 を標準ライブラリ（SHA・Downloads）で実装し、**新しい依存を追加しない**。
  署名は AWS 公式ドキュメントの S3 PUT 例と botocore の署名にテストで固定する。
- credential は環境変数（S3 互換サーバでの local 検証）と ECS container credentials endpoint（task role）のみ。
  shared config・SSO・IMDS は扱わない。credential と署名は log にも manifest にも出さない。
- model / domain 層（`src/models`・`src/core` など）は batch 層を参照しない。CLI への変更はオプションの追加だけ。

### 6. image は PAP ADR 0017 の Julia profile に従う

以下の Debian 選択は初回決定の記録であり、現行の base 選択は「改訂 3」による。runtime の権限・書き込み契約は維持する。

- 両 stage を `julia:1.13.1-trixie`（Debian 13。Julia patch は CI・Manifest と揃えて固定）にし、runtime stage で
  `apt-get update && apt-get upgrade`（trixie 自身の repository のみ）を実行する（A3–A5）。Julia version・patch 固定の
  理由・A3 の判断は末尾の「改訂 1」による。
- `/opt/dme` と `/opt/julia-depot` は root 所有にし、runtime user（UID/GID 10001）が書けるのは artifact volume
  （`/var/lib/dme/artifacts`）だけにする。filesystem のみの run は `readonlyRootFilesystem` で artifact volume だけを
  書く。HTTP を使う run（sink・ECS metadata・credential）は Julia の HTTP client が SSH known-hosts の一時ファイルを
  作るため `/tmp` も書く。したがって ECS では artifact volume と `/tmp` の scratch volume を宣言する（A6）。
- OCI label `source` / `revision` / `version` を build arg から付け、同じ値を `DME_SOURCE_COMMIT` /
  `DME_IMAGE_VERSION` として runtime に渡す。publish は `linux/amd64`（A2）。

### 7. publish は main の承認済み commit を dispatch で行う

`.github/workflows/publish-batch-image.yml`:

1. `workflow_dispatch`（入力 = main HEAD の commit SHA）で main からのみ実行する。
2. `Pkg.test()`（テスト・Aqua.jl・JuliaFormatter）が通った後に publish job を実行する。
3. base を pull し直して `linux/amd64` で build し（build cache を使わず、upgrade layer を毎回作り直す）、
   `scripts/verify_batch_container.sh` で image 契約を検証する。
4. GitHub OIDC で PAP の ECR push role を assume する（長期 access key 無し）。subject は
   `repo:Yuki-Watanabe7/DME:ref:refs/heads/main`（repository の OIDC 設定は default）。job に GitHub
   `environment` を付けない（subject が変わり PAP の trust policy と一致しなくなる）。
5. tag は source commit SHA のみ（immutable。`latest` は push しない）。同じ SHA の再 dispatch は push せず、既存 digest を
   再検証する。
6. push した digest を ECR から pull し直し、同じ検証（S3 互換 sink と SIGTERM を含む）をその image に対して行う。
7. ECR basic scan の `COMPLETE` を待ち、A8 の evidence（`image-publication.json`: source commit・digest・OCI label・
   base の参照と解決済み digest・OS release・Julia version と同梱ライブラリ version・build 時刻・scan 状態・
   HIGH/CRITICAL の CVE ID）を記録し、workflow summary に digest を書く。HIGH/CRITICAL があれば `blocked`
   として run を失敗させる（exception を自動適用しない。PAP ADR 0017 §4–§5 の経路で人が判断する）。

### 8. Julia runtime は evidence で追跡する

ECR basic scan は OS package しか見ず、Julia 本体と同梱の OpenSSL・libcurl・libgit2・libssh2・zlib は scan
されない。evidence に Julia version と同梱ライブラリの version を記録し、Julia の security release を追跡する。
Julia の version を上げる場合は CI・`Manifest.toml`（root / test / docs）と揃える別の変更として行う。

## 見送りとした選択肢

- **AWS.jl / AWSS3.jl を使う。** 推移的依存が多く、binary JLL（ECR basic scan から見えない）を増やし、
  `Manifest.toml` と precompile 時間を大きく変える。必要なのは1種類の条件付き PUT だけである。
- **image に aws CLI を入れて shell で upload する。** OS package と Python が増えて A7 の finding が増え、publish の
  意味（順序・条件付き書き込み）が CLI 契約の外の shell に移る。
- **PAP 側の uploader sidecar で volume を S3 へ同期する。** artifact の publish 意味を PAP が持つことになり、
  PAP #37 の責務境界（artifact semantics は application が所有）に反する。
- **S3 versioning で上書きを許容する。** bucket 設定（PAP 所有）に依存し、上書きそのものは防げない。条件付き
  PUT は書き込み時点で拒否する。
- **最新 run を指す pointer object（`latest.json`）を置く。** 可変 object を作ると上書きを再導入する。
- **DME 内で PUT を retry する。** §4 のとおり応答喪失後の `412` と区別できない。
- **初回決定時に AL2023 minimal + 公式 Julia tarball を採用する。**（2026-10-04 の実測を受けた改訂 3 で再評価済み。） PAP ADR 0017 の Julia profile で preferred は
  `julia:<X.Y>-<Debian stable>`。AL2023 との実測比較（§4 step 2）は Debian 側に未修正の HIGH/CRITICAL が ECR scan で
  残った場合の手順で、比較は PAP の ECR repository（PAP #41 で作成）で行う必要がある。最初の publish の evidence を
  見て判断する。
- **main への push ごとに自動 publish する。** image は圧縮で数百 MB あり PAP の ECR 保持 envelope を圧迫する。
  publish は admission の判断を伴うため承認済み commit の dispatch に限る。PAP の trust policy は `v*.*.*` tag も
  許すが、DME に release tag の運用が無いため trigger にしない。
- **`/tmp` を不要にするため `TMPDIR` を artifact volume に向ける。** artifact volume に run bundle 以外のファイルを
  混ぜることになる。`/tmp` の scratch は PAP ADR 0017 A6 が認める書き込み先である。

## 影響

**良い点**

- task 終了後も run bundle が残り、run id・task ARN・log stream・image digest・source commit を相互に辿れる。
- 重複・並行・手動 rerun が published な run を壊さないことを S3 が書き込み時に保証する。manifest の有無で
  完了/未完了を機械的に判定できる。
- local の filesystem 契約は変わらず、sink 経路も S3 互換サーバで local / CI から検証できる。
- 新しい依存は無く、AWS 固有コードは1ファイルに閉じる。

**悪い点・受け入れるコスト**

- SigV4 と credential 取得を自前で保守する（署名はテストの固定ベクタで回帰を検出する）。
- sink の失敗は run 全体の失敗（exit 4）になり、同じ run id では再 publish できない。やり直しは新しい run になる。
- ECS では `/tmp` の scratch volume が必要になる（artifact volume に加えて2つ目の書き込み先）。
- Debian 13 には Debian が未修正の HIGH/CRITICAL が残りやすい。本 image（upgrade 後の Debian 13.7）を Trivy で
  scan すると、trixie に修正版の無い HIGH が 12 CVE 残った（2026-09-30、ECR の判定とは feed が異なる）。最初の publish が
  `blocked` になる可能性が高く、その場合は PAP ADR 0017 §4 step 2 の比較か §5 の exception record が必要になる
  （[#296](https://github.com/Yuki-Watanabe7/DME/issues/296)）。
- publish の build は cache を使わない（upgrade layer を必ず作り直すため）。depot layer も毎回別物になり、1回の publish で
  圧縮後約 0.7 GB が ECR に増える。PAP の Job cost envelope（PAP ADR 0015 §7。DME の ECR 0.5 GB）を超えるため、PAP #41 で保持数と
  envelope を実測に合わせる必要がある。
- Julia の patch は自動では上がらない。Julia 本体と同梱ライブラリの security fix は、CI・Dockerfile・3つの
  `Manifest.toml` を揃えて上げる変更でしか入らない（改訂 1）。

## 改訂

### 完了記録（2026-10-05、DME #296 / PAP #41）: 修正版本番 image の引き渡しと実機受入

改訂 3 の AL2023 移行は DME #302、改訂 4 の portable cache は DME #303 でマージ済み。
#303 の merge commit `b5bb7dfd6a4c6ffcb3235ac9658a1ade7c4026a3` は
`2026-10-04T21:04:45Z`（2026-10-05 06:04:45 JST）に main へ取り込まれた。
[本番公開 37234934566](https://github.com/Yuki-Watanabe7/DME/actions/runs/37234934566)は同じ commit を使い、
全テスト・公開前と exact ECR pull 後の全10段・generic CPU / strict cache の代表2コマンドを通過した。

採用 image は `sha256:f5c496b0d0086bf40683537d6a7fafb36c7d47f4178c83563ccb8949209e76ef`。
[未加工の公開証跡](../deployment/evidence/issue296/native-ecr-al2023-portable-cache-production.json)は
COMPLETE scan（HIGH/CRITICAL 0）、例外なし、production / approved を記録する。旧 Debian の blocked 記録と、
最初の AL2023 image の起動失敗は書き換えない。

PAP #173 は `2026-10-04T21:50:13Z` に merge commit `54259d26dcdf8319cb829b7b4ae541f7c7fd64a3` で
マージされ、この digest を `pap-prod-dme-sim:2` に採用した。実 Fargate の simulation / quality-export は exit 0、
S3 manifest と全 artifact の hash/identity は一致した。2つの別 ID の再実行は成功し、ID 再利用は exit 4、元 bundle は不変、
終了後 running task は0。PAP #41 は `2026-10-04T22:20:16Z` に completed で Close 済み。
[比較・完了記録](../deployment/batch_image_comparison.md)と保存した PAP JSON に DME #296 の6条件の対応を示す。
現在の残件はこの完了記録の公開であり、実装・本番 image 公開・PAP 引き渡しは完了している。

継続運用は rescan 期限 `2026-11-03T21:33:01Z`、rebuild 期限 `2027-01-02T21:32:37Z` を維持する。
期限は保存した PAP admission の ECR scan/push 時刻を基準とし、Docker の `built_at` と混同しない。
追加 image 公開前に容量を再確認する。PAP #159 の rescan 自動化、PAP #42 の運用観測は継続課題であり、
初回引き渡しの未完了条件ではない。この完了記録は新 image・RunTask・IAM・S3 の変更を伴わない。

### 改訂 4（2026-10-04、DME #296 / PAP #41）: CPU が異なる実行先でも使える package cache

以下の「未完了」は改訂時点の記録。上の完了記録が現状を示す。

**背景。** 改訂 3 は PR #302 でマージされ、main `94eadc900f10c420ea415d78ce2f8ecf277a7b2b` の
AL2023 本番 image は全10段・ECR COMPLETE（HIGH/CRITICAL 0）を通過した。しかし PAP の初回 Fargate 実行
`37200078980` は `/usr/local/bin/dme:3` の `using DME` で cache lock file を read-only depot へ作ろうとして
exit 1 になった。[未加工の診断証跡](../deployment/evidence/pap41/startup-inspection.json)は再生成の試行を確認できるが、
AWS CPU の機能や cache rejection の理由までは記録していない。

旧ローカル ARM64 image は同じ CPU で load できたが、`--cpu-target=generic` で機能を制限すると
「compatible target が無い」という rejection と同種の EROFS を再現した。
[再現ログ](../deployment/evidence/pap41/local-cpu-cache-rejection.txt)はローカル実験であり、AWS 実測と混同しない。
同じ build host での検証だけでは package image の CPU 互換性を保証できない。

**決定。**

1. build/runtime の `JULIA_CPU_TARGET` を `sysimage` にする。Julia 1.13 の
   [公式仕様](https://docs.julialang.org/en/v1/manual/environment-variables/#JULIA_CPU_TARGET)に従い、
   公式 system image の CPU target 群を使い、baseline と最適化 variant を同じ package cache に含める。
   package image は loaded system image より緩い feature を使えないため、build host が選んだ target に依存する
   `generic` だけでなく system image 全体の target を使う。runtime の JIT は host CPU を利用できる。
   AL2023 と Debian 比較 recipe の両方を揃え、古い depot のコピーや runtime-only 設定変更で済ませない。
2. 検証 step 7 に generic CPU の代表 CLI 2経路を追加し、`--compiled-modules=strict` で既存 cache を必須にする。
   read-only root/depot・UID 10001・0.5 vCPU / 2 GiB を維持し、別の出力 volume で完走・manifest/hash を検証する。
   この検査は PR の native amd64、ECR push 前、digest pull 後に共通で適用する。
3. scan-approved の旧 digest の証跡は書き換えない。PR #303 の review/merge 後に新しい source commit の
   immutable production image を公開し、全10段と ECR scan の成功を確認して PAP に渡す。
   PAP 側の採用・Fargate 完走・S3 保持・再実行確認はその後に行う。現在は未完了である。

CLI/model・Julia patch・AL2023 base・artifact/sink・read-only・IAM・task volume の契約は変更しない。
`JULIA_PKG_PRECOMPILE_AUTO=0` は Pkg の自動事前コンパイルを止める設定であり、`using` の cache 再生成を禁止する設定ではない。
書き込み可能な depot を追加して再生成を許容する方式は採らない。

### 改訂 3（2026-10-04、[#296](https://github.com/Yuki-Watanabe7/DME/issues/296)）: 実測に基づく AL2023 本番 base の選択

**背景と証拠。** main `d8eba8ad11d0f490815479b7d4085165257bbf66` を PAP の ECR に公開した
[Debian run](https://github.com/Yuki-Watanabe7/DME/actions/runs/37174658453) は、OS upgrade 後にも
COMPLETE scan で CRITICAL 2 / HIGH 4 が残った。Debian tracker に固定済み trixie package は無い。
同じ source の [AL2023 比較 run](https://github.com/Yuki-Watanabe7/DME/actions/runs/37175890840) は
CRITICAL / HIGH ともに 0。両方で `Pkg.test()` と push 前・ECR pull 後の全10段の契約検証が通った。
exact digest・未加工 A8 JSON・6件の vendor status は [比較記録](../deployment/batch_image_comparison.md)に保持する。

**決定。**

1. root `Dockerfile` を AL2023 minimal + checksum 検証済み公式 Julia 1.13.1 glibc tarball にする。
   `microdnf upgrade` を Julia base / runtime に実行し、AL2023 上で depot を install/precompile する。
   Debian の depot をコピーしない。Julia patch・Manifest・domain/CLI・read-only/non-root・sink 契約は変えない。
2. Debian baseline を `experiments/issue296/Dockerfile.debian` に残す。production と AL2023 comparison は
   同じ root recipe を使う。workflow の default は `production-al2023`。production `<commit>` と比較 suffix を
   selector と回帰テストで区別し、main 限定・OIDC trust・immutable tag・HIGH/CRITICAL gate は維持する。
3. **比較 digest は本番入力にしない。** この変更をレビューして main にマージした後、新しい main commit の本番 image を
   公開し、全10段・ECR scan を再検証する。新 production digest と matching source/evidence が揃ってから PAP #41 に渡す。
   この改訂自体では ECS task を起動せず、exception も承認しない。#296 は production handoff まで open とする。
4. **A3。** AL2023 の [standard support](https://docs.aws.amazon.com/linux/al2023/ug/release-cadence.html) は
   2027-06-30、security maintenance は 2029-06-30 まで。2026-10-04 の180日後は 2027-04-02 で standard support 内。
   installed package の support を別に評価し、maintenance 移行前に再判断する。Julia 1.13.1 は改訂 1 の release 履歴に
   基づく見込みであり、AL2023 の日付が Julia の support を保証するわけではない。
5. **保守コストと制約。** 公式 Julia image の利用から tarball path / checksum と RPM footprint の保守が増える。
   native Docker size は AL2023 が 7,557,595 bytes（0.32%）増える。これは非圧縮サイズであり、ECR 課金量ではない。
   次回の A8 evidence に ECR 圧縮 image size と repository の image size 合計（shared layer を重複計上し得る上限）を追加する。
   ECR basic scan が見ない Julia / bundled JLL は引き続き version と upstream security release で追跡する。

この改訂は初回 §6 の Debian 選択・見送り理由と改訂 2 の「実測待ち」を更新する。artifact の保存・run identity・条件付き
S3 PUT・失敗/停止の意味と PAP/DME の責務分担は変更しない。

### 改訂 2（2026-10-03、[#296](https://github.com/Yuki-Watanabe7/DME/issues/296)）: base 比較の準備と証跡

以下は 2026-10-03 時点の準備記録。PAP #41 の ECR 公開先・push role に対応する repository variables は未設定で、初回 publish の実行履歴も無かった。
したがって ECR finding の確定・base の採用判断・exception 承認は未完了である。

1. `experiments/issue296/Dockerfile.al2023` に AL2023 minimal + checksum 検証済み公式 Julia 1.13.1 glibc tarball の
   比較候補を置く。depot は AL2023 上で install/precompile し、Debian からコピーしない。
2. 同じ `verify_batch_container.sh` 全10段を両 OS に適用する。step 3 は明示した OS と Manifest の Julia patch、
   vendor update、glibc、CA 証明書を検証する HTTPS 通信を確認する。PR の native amd64 CI は AWS に接続しない。
3. publish workflow の main 限定と OIDC subject は維持する。比較は `<commit>-comparison-debian` と
   `<commit>-comparison-al2023` の immutable tag とし、本番の `<commit>` と混同しない。比較の `approved` は scan 結果であり、
   base 採用や本番配置の承認ではない。
4. build した base reference/digest を OCI label に保持し、再 dispatch で既存 digest を検証するときにも、その image の
   label から A8 evidence を作る。現在の host の base tag を過去の build の base として記録しない。size・glibc・scan 時刻も記録する。
   ECR pull 後の契約検証が失敗した場合に、検証成功と記した evidence は生成しない。
5. **本番 base は Debian 13 のまま。** 採用判断は PAP ECR の実測比較後に別の改訂として行う。
   [比較記録と残作業](../deployment/batch_image_comparison.md)に §4 の再 build/移行判断、§5 の人間による期限付き exception 承認、
   A9 の90日以内 rebuild・30日以内 rescan と vendor status の再確認手順を記録する。Issue #296 は digest の引き渡しまで open とする。

### 改訂 1（2026-10-01、[#295](https://github.com/Yuki-Watanabe7/DME/issues/295)）: Julia 1.13.1 への更新

**背景.** Julia 1.12.6 は現行 stable（1.13.0 = 2026-09-10、1.13.1 = 2026-09-26）でも 1.12 系の最新 patch（1.12.7）でも
なかった。1.12 は 1.13.0 の時点で旧 minor になり、1.11 の実績（1.12.0 の後は 1.11.8・1.11.9 の約4か月だけ patch が出た）から
すると、2026-10-01 の build から 180 日後（2027-03-30）まで patch が続く見込みは低く、A3 を満たせない。Julia 同梱の
OpenSSL・libcurl・libgit2・libssh2・zlib は ECR basic scan の対象外で、更新する手段も Julia の更新しかない（§8）。

**決定.**

1. Julia を 1.13.1 に上げ、全 workflow の `setup-julia`・Dockerfile の2 stage・3つの `Manifest.toml`（root / test / docs）を
   同じ patch に揃える。
2. patch 固定を続け、minor tag（`julia:1.13-trixie`）にしない。minor tag は patch release のたびに動くため、同じ commit の
   再 build が、Manifest を解決しテストを通した Julia とは別の Julia で動きうる。Julia の patch 更新（同梱ライブラリの修正を
   含む）は上の全箇所を揃えて上げる変更として行い、OS の更新は従来どおり build ごとの `apt-get upgrade` で入る（A5）。
3. image の Julia が `Manifest.toml` の `julia_version` と異なる場合、`scripts/verify_batch_container.sh` の step 3 を失敗させる
   （Dockerfile だけが取り残される drift を build 時に検出する）。
4. **A3 は満たすと判断する。** Julia は LTS 以外の support 終了日を公表していないため、release 履歴で判断する。1.13 は現行
   stable で、1.14 は pre-release も無い。minor は 11〜12 か月間隔（1.11.0 = 2024-10-08、1.12.0 = 2025-10-08、
   1.13.0 = 2026-09-10）で出ており、旧 minor にも次の minor の後に約4か月 patch が出ている。したがって 1.13 は 2027-03-30 より
   後まで patch を受ける見込みである（Julia の約束ではなく履歴に基づく見込み）。Julia 1.14.0 の release 時に A3 を判断し直し、
   1.14 への更新を別の変更として行う。
5. 同梱ライブラリの version は evidence（`image-publication.json` の `runtime.bundled_libraries`）に digest ごとに記録される。
   1.12.6 → 1.13.1 で `OpenSSL_jll` 3.5.4+0 → 3.5.6+0、`LibCURL_jll` 8.15.0+0 → 8.18.0+1、`LibGit2_jll` 1.9.0+0 → 1.9.1+0、
   `LibSSH2_jll` 1.11.3+1 → 1.11.104+0 になり、`Zlib_jll` は 1.3.1+2 のまま。

**確認した挙動の差.**

- **依存.** `Pkg.resolve()` で再解決し、registry パッケージの version は変わらない。変わったのは stdlib と Julia 同梱の JLL
  だけである。1.13 の `SHA` stdlib は 1.0.0 のため、`[compat] SHA` を `"0.7, 1"` に広げた。Pkg 1.13 は Manifest を format 2.1
  （`registries` フィールド付き）で書き、`docs/Project.toml` に `[sources] DME = {path = ".."}` を記録する。JET 0.12.1 は
  1.13 で解決・precompile でき、`[compat] JET = "0.12"` は変えない。
- **Test stdlib.** testset のスタックが ScopedValue になり、`Test.push_testset` / `pop_testset` が削除された。これを使っていた
  回帰テスト（`test/test_quality_capture.jl`）を `Test.@with_testset` に置き換えた。quality capture が依存する
  `Test.get_test_counts` と `Test.TestSetException` のフィールドは変わらない。world age の警告（`test/quality_capture_runner.jl`）
  は 1.13.1 でも警告のみである。
- **品質 lane.** 1.13.1 の `Pkg.test()`（fast lane、Coverage 込み）は 37116 件すべて pass し、Aqua.jl の7検査と
  JuliaFormatter も通る。同じ commit で JET slow lane の finding（234 件）と Documenter docs lane の warning は 1.12.6 と
  一致し、GitHub Actions（ubuntu-latest）でも JET・Documenter・benchmark の各 lane が success になる。benchmark slow lane は
  environment key が `github-linux-x64|linux|x86_64|julia1.13` に変わるため、`benchmarks/baseline.json` にこの key の baseline を
  workflow_dispatch run 36744285483 の結果から追加した（`julia1.12` の entry は履歴として残す）。
- **浮動小数点.** commit 済みの Japan fiscal handoff fixture（1.12.6 で生成）を 1.13.1 で replay すると、31 case すべてが
  許容誤差内で、hash の完全一致は 30/31（`f4-rbc` のみ、最大絶対差 6.9e-18）になる。1.12.6 では 31/31 が完全一致する。
  ADR 0025 のとおり replay は許容誤差で成立し、hash の完全一致は `exact_match` として別に報告されるので、fixture は再生成しない。
- **batch image.** 1.13.1 の image は native `linux/arm64` で `scripts/verify_batch_container.sh` の全10段を pass した
  （2026-10-01）。SIGTERM は 17 回の試行（起動 0.3 秒後から 367 MB の artifact 書き込み終盤まで）すべてで exit 143 になり、
  SIGKILL を要した回は無かった（1.12.6 では10回中1回、書き込み中に exit 経路が block して 137 になった）。17 回では block を
  否定できないため、137 を通常の停止として扱う運用は変えない。HTTP を使う run が `/tmp` を要する理由（NetworkOptions が
  同梱の SSH known-hosts をプロセスごとに1回 `mktemp` へ書き出す）も 1.13.1 で変わらない。
- **Apple Silicon 上の `linux/amd64`.** Docker Desktop は amd64 を Rosetta で動かし、Julia が既定の interactive thread を持つ
  状態では GC safepoint で SIGSEGV になる（build 中の `Pkg.instantiate` で再現。1.12.6 でも同じで、`JULIA_NUM_THREADS=1,0`
  なら通る）。このため `linux/amd64` の検証は local では行わず、publish workflow が native runner で push 前に行う。
