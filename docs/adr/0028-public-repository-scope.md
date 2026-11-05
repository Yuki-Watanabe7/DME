# ADR 0028: public リポジトリとして公開してよい範囲

- **ステータス**: 採用
- **日付**: 2026-11-06
- **関連Issue**: [#310](https://github.com/Yuki-Watanabe7/DME/issues/310)（本決定）・Yuki-Watanabe7/portfolio-control-plane#52（全リポジトリの成果物公開経路の棚卸し。DME は Medium 候補）
- **前提ADR**: [ADR 0026](0026-batch-artifact-retention-and-image-publication.md)（batch image publication・repository variables・publish evidence）
- **関連ドキュメント**: [fixture の出典区分](../../test/fixtures/README.md)・[batch container guide](../deployment/batch_container.md)

---

## コンテキスト

DME は public リポジトリだが、public にする意図はどこにも記録されていなかった。portfolio-control-plane#52 の棚卸しでは、次の3点が指摘された。

1. 公表統計のように見える fixture に、出典と性質の記載がない。
   - `test/fixtures/fred/` の5系列と `test/fixtures/estat/` の4表は、2020年前後の公表値に近い値を持つ。
   - `test/fixtures/keen/fred/` の4系列は合成値だが、title には実在系列の名前しかない。
2. AWS アカウント ID が公開されている。
   - `docs/deployment/` の evidence と比較記録に29箇所ある。
   - `publish-batch-image` の run ログにも出ており、1回の run あたり最大45箇所。
3. public リポジトリでは、ソースだけでなく Actions のログと artifact も公開になる。ログは誰でも読める。artifact は一覧を誰でも見られ、GitHub にサインインすれば誰でもダウンロードできる。

## 決定

**DME は public のままとする**（owner の決定、2026-11-06）。そのうえで、commit するものと Actions が出力するものを、公開してよいものに限る。

### 1. fixture は出典区分を1つ持つ

| 区分 | 意味 | commit してよい条件 |
|---|---|---|
| `synthetic` | 架空の値、またはコードで決定的に生成した値。synthetic な入力から再生成した golden 出力と契約サンプルを含む。 | ファイル内（`title`・`notes`・`source.description` など）か README で、synthetic・fictional・illustrative のいずれかと明示する。 |
| `public-statistics-derived` | 公的機関が公表した統計を基にした値。近似値や改訂前の値を含む。 | 次の3点を書く。原作成機関の出典表記。公表値との一致を保証しないこと。利用条件を確認した結果。 |
| `withheld` | 再配布条件を確認していない実データ。 | 実データは commit しない。commit するのは識別用のメタデータだけ（例: `test/fixtures/pne/official_jp/`）。 |

ディレクトリごとの区分と出典表記は、[`test/fixtures/README.md`](../../test/fixtures/README.md) に一覧する。次の値は fixture として commit しない。

- 第三者が著作権を持つ系列の実測値。例えば、FRED の系列ページで "Copyrighted" と表示される系列。
- FRED から取得した値をそのまま使うこと。FRED の利用規約は、FRED Content を保存することと、それを第三者に提供することを禁じている。公表統計が必要な場合は、原作成機関の公表値を基にし、その出典を記載する。

### 2. AWS の識別子は秘匿しないが、不要に公開しない

AWS アカウント ID は認証情報ではない。AWS 自身がそう位置づけている。したがって secret としては扱わず、ADR 0026 の repository variables の構成は変えない。

ロールを引き受けられる範囲を限定しているのは、ID を隠すことではなく、次の4点である。

- PAP の push role の信頼条件。`sub` が `repo:Yuki-Watanabe7/DME:ref:refs/heads/main` と完全一致する場合だけを許可する（StringEquals）。
- `workflow_dispatch`。起動できるのは書き込み権限を持つ人だけ。
- private な ECR。
- immutable tag。

そのうえで、ID を必要以上には公開しない。

- **commit する文書と evidence**：アカウント ID を `<pap-account-id>` に置き換える。evidence は、これ以外の変更をせずに保存する。
- **publish workflow**：最初の step でアカウント ID を `::add-mask::` に登録し、それ以降のログでは伏せる。最初の step のヘッダには、job の `env` に表示される repository URL と role ARN の2箇所が残る。
- **artifact `image-publication.json`**：PAP への引き渡しに使うので、完全な参照を残す。90日で失効する。
- **`test/test_public_repository_hygiene.jl`**：tracked file に ARN 形式か ECR 形式のアカウント ID があると fail する。AWS のドキュメントで例として使われる `123456789012` は許可する。

### 3. Actions のログと artifact は公開物として扱う

ログと artifact には、次のものを出力しない。

- secret と認証情報
- 個人データ
- 再配布条件を確認していないデータ

現在 artifact に出しているのは、DME 自身の出力（品質 export、publish evidence、batch contract の結果）だけである。

### 4. LICENSE は本 ADR では決めない

LICENSE ファイルはない。閲覧はできるが、利用の許諾は与えていない状態である。LICENSE を選ぶときは別の ADR で決める。

## 見送りとした選択肢

| 選択肢 | 見送った理由 |
|---|---|
| private にする | owner が public の維持を選んだ。 |
| git 履歴を書き換えて ID を消す | 破壊的な操作で、すでに取得されたコピーからは消せない。ID は認証情報ではない。 |
| 既存の run ログを削除する | publish の run は 2026-10-04 から 2026-11-03 までの5件で、いずれも実行から90日で失効する。削除するかどうかは owner が判断する。 |
| repository variables を secret にする | secret ならログで自動的に伏せられる。しかし、PAP の Terraform output から variables を設定するという ADR 0026 の構成と、PAP 側の手順を変える必要がある。得られる効果は、最初の step に残る2箇所を伏せることだけである。 |
| fixture の値を合成値に置き換える | テストが値を参照している。公表統計の数値は、FRED の表示では public domain、e-Stat の規約では著作権の対象外とされており、出典を書けば足りる。 |

## 影響

- `docs/deployment/` で「unchanged copies」としている evidence は、アカウント ID の置換だけを例外とする。置換は2026-11-06に1度だけ行い、digest・タイムスタンプ・パッケージ一覧などの値は変えていない。
- fixture か evidence を追加するときは、`test/fixtures/README.md` と `docs/deployment/batch_container.md` の手順に従う。従わなかった場合は、上記のテストで検出される。
- この変更より前の commit と既存の run ログには、アカウント ID が残る。
