# 把依赖 API 链接到独立发布的文档站

为依赖库单独生成文档和符号索引，再用文档目录（catalog）和索引摘要把它们接入消费方站点，让消费方页面上的类型与相关链接跳到这份库文档。

## 什么时候用本页

- 依赖库有自己的文档站，你希望消费方只链接过去，而不把库源码纳入本次文档。
- 需要确认消费方链接到的确实是同一份库文档（用索引摘要固定内容），或者排查“链接没出现”“点开是 404”。
- 只想链接标准库，或给源码加上指向 GitHub 提交的入口：看本页最后一节。

只想把依赖源码一起生成进同一个站点时，用[选择输入](select-inputs.md)里的 `--include-path-dependencies`，不需要文档目录。

## 前提条件

- 已安装 `cjdoc`，当前终端已加载仓颉 SDK 1.2.0 环境，`cjpm` 可用。
- Bash 与 Python 3；Python 只用来计算索引文件摘要。
- 两份源码版本一致：库站点的索引必须来自消费方实际使用的库版本，否则匹配不上不是配置错误。

```bash
mkdir -p "$HOME/.cache/cjdoc/examples"
TASK_ROOT="$(mktemp -d "$HOME/.cache/cjdoc/examples/links.XXXXXX")"
mkdir -p "$TASK_ROOT/library/src" "$TASK_ROOT/consumer/src"
```

`$TASK_ROOT` 是本页所有文件的存放位置，后面一直沿用。

## 第一步：准备库与消费方源码

库提供一个 `Label` 类型：

```bash
cat > "$TASK_ROOT/library/cjpm.toml" <<'EOF'
[package]
cjc-version = "1.2.0"
name = "linklib"
version = "0.1.0"
output-type = "static"
EOF

cat > "$TASK_ROOT/library/src/api.cj" <<'EOF'
package linklib

/** 提供由库 package 发布的标签。 */
public class Label {
    public init() {}

    /** 返回标签文本。 */
    public func text(): String { "from linklib" }
}
EOF
```

消费方通过路径依赖使用这个类型，并在注释里引用它：

```bash
cat > "$TASK_ROOT/consumer/cjpm.toml" <<'EOF'
[package]
cjc-version = "1.2.0"
name = "linkconsumer"
version = "0.1.0"
output-type = "static"

[dependencies]
linklib = { path = "../library", output-type = "static" }
EOF

cat > "$TASK_ROOT/consumer/src/api.cj" <<'EOF'
package linkconsumer

import linklib

/** 返回真实 linklib 依赖提供的文本。
 * @param label 来自 linklib 的值。
 * @see linklib.Label
 */
public func render(label: linklib.Label): String { label.text() }
EOF
```

`linklib` 的页面由独立库站点提供，所以生成消费方时不要加 `--include-path-dependencies`：加了之后依赖源码会进入本地文档，类型链接可能改指本地页面。

## 第二步：生成库文档并固定索引摘要

生成库的 HTML 和符号索引，再对整个索引文件计算 SHA-256：

```bash
cjdoc generate --project "$TASK_ROOT/library" \
  --format html --format symbol-index --output "$TASK_ROOT/library-site"
INDEX="$TASK_ROOT/library-site/html/symbol-index.json"

PIN="$(python3 - "$INDEX" <<'PY'
import hashlib
import sys
from pathlib import Path

digest = hashlib.sha256()
with Path(sys.argv[1]).open("rb") as source:
    for block in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(block)
print(digest.hexdigest())
PY
)"
printf '%s\n' "$PIN"
```

预期 `$TASK_ROOT/library-site/html/symbol-index.json` 存在，`$PIN` 是 64 位十六进制摘要。库重新生成后索引内容会变，需要重新计算摘要；不要复用旧值。

## 第三步：登记库文档并生成消费方

写一份 catalog，说明索引在哪、发布后依赖页面放在哪个相对地址：

```bash
cat > "$TASK_ROOT/cjdoc-documents.json" <<'EOF'
{
  "schemaVersion": "cjdoc.doc-sources/1",
  "documents": [
    {
      "index": "library-site/html/symbol-index.json",
      "baseUrl": "./dependencies/linklib",
      "priority": 0
    }
  ]
}
EOF

cjdoc generate --project "$TASK_ROOT/consumer" \
  --doc-source "$TASK_ROOT/cjdoc-documents.json" \
  --doc-inventory-pin "$INDEX=$PIN" \
  --format html --format json --output "$TASK_ROOT/consumer-site"
```

两个路径基准不同：catalog 里的 `index` 相对 **catalog 文件所在目录**解释，`--doc-source` 与 `--doc-inventory-pin` 的相对路径相对 **`--project` 指定的项目根**。本页都使用绝对路径以避免混淆。`--doc-source` 可以重复，也可以直接给一个含 `cjdoc-documents.json` 的目录。

预期退出码为 `0`，终端仍可能出现 `CJDOC3008`（`unresolved semantic reference`）和 `CJDOC3041`（未解析类型链接）——这些 warning 表示语义引用没有绑定到本地声明，不表示外部链接没有生成。用 `docs.json` 确认：

```bash
python3 - "$TASK_ROOT/consumer-site/docs.json" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
print("documentSets:", [(d["library"], d["state"], d["baseUrl"]) for d in doc["documentSets"]])
render = next(d for d in doc["declarations"] if d.get("name") == "render")
nav = render["parameters"][0]["type"]["navigation"]
print("state:", nav["state"], "matchLevel:", nav["matchLevel"])
print("url:", nav["url"])
PY
```

预期：

```text
documentSets: [('linklib', 'declared', './dependencies/linklib')]
state: resolved matchLevel: exact
url: ./dependencies/linklib/symbols/symbol-....html
```

`matchLevel` 为 `exact` 说明索引摘要与登记一致。pin 只校对索引文件的字节，不认证远端网站。

## 第四步：放入依赖页面并沿链接检查

catalog 不会替你复制或下载文档。把库的完整 HTML 树放到 `baseUrl` 对应位置：

```bash
mkdir -p "$TASK_ROOT/consumer-site/html/dependencies"
cp -R "$TASK_ROOT/library-site/html" "$TASK_ROOT/consumer-site/html/dependencies/linklib"
xdg-open "$TASK_ROOT/consumer-site/html/index.html"
```

macOS 用 `open`，Windows PowerShell 用 `Start-Process` 打开同一个入口。

在消费方的 `render` 页面点击参数类型 `linklib.Label`，再点击“另请参阅”里的 `linklib.Label`，两处都应打开库站点中的 `Label` 页面。发布时上传完整的 `consumer-site/html/`，包含 `dependencies/linklib/`；只传消费方页面会让链接 404。

## 可选：链接到自己仓库的源码

在已公开发布、HEAD 已推送的 GitHub 项目根目录操作，从 origin 和 HEAD 取得仓库地址与 revision：

```bash
SOURCE_ROOT="$(git rev-parse --show-toplevel)"
SOURCE_REVISION="$(git rev-parse HEAD)"
SOURCE_REPOSITORY="$(git remote get-url origin)"
case "$SOURCE_REPOSITORY" in
  git@github.com:*) SOURCE_REPOSITORY="https://github.com/${SOURCE_REPOSITORY#git@github.com:}" ;;
esac
SOURCE_REPOSITORY="${SOURCE_REPOSITORY%.git}"

cjdoc generate --project . --format html \
  --repository-url "$SOURCE_REPOSITORY" \
  --repository-revision "$SOURCE_REVISION" \
  --repository-root "$SOURCE_ROOT" \
  --output target/doc-source-links
```

预期声明页面的源码入口指向 `https://github.com/<owner>/<repo>/blob/<revision>/<文件>#L<起>-L<止>`。三个选项只标出源码位置，不推送源码：`--repository-url` 与 `--repository-revision` 必须成对给出，`--repository-root` 必须是存在的目录，被引用的源码必须位于该目录内。

## 可选：链接标准库文档

内置可选版本为 `1.0.5`、`1.1.0`、`1.1.0-beta.25`、`1.1.3`、`1.2.0`：

```bash
mkdir -p "$TASK_ROOT/stdlib/src"
cat > "$TASK_ROOT/stdlib/cjpm.toml" <<'EOF'
[package]
cjc-version = "1.2.0"
name = "stdliblinkdemo"
version = "0.1.0"
output-type = "static"
EOF
cat > "$TASK_ROOT/stdlib/src/api.cj" <<'EOF'
package stdliblinkdemo
import std.collection.ArrayList
import std.core as core

/** 接收标准库列表并返回文本。
 * @param values 标准库列表。
 * @return 示例文本。
 */
public func accept(values: ArrayList<String>): String { "ok" }

/** 使用限定类型名声明同一组标准库类型。 */
public func acceptQualified(values: core.String): core.String { "ok" }
EOF

cjdoc generate --project "$TASK_ROOT/stdlib" \
  --format html --stdlib-doc-version 1.2.0 --output "$TASK_ROOT/stdlib-site"
```

预期 `ArrayList` 与 `String` 链接到 `https://cj-docs.gitcode.com/zh/1.2.0/libs/std/...`。版本参数只选择链接目录，不检查项目是否使用了完全相同的 SDK API。

不在列表里的版本必须同时给出 `--stdlib-doc-base-url`，例如 `--stdlib-doc-version 1.1.3 --stdlib-doc-base-url https://cj-docs.gitcode.com/zh/1.1.3/libs/std`；地址必须是 HTTPS 且以 `/libs/std` 结尾。两个选项只适用于 `generate`，也不要与站点发布标签 `--doc-version` 混淆；`render` 保留快照中的既有链接。

## 失败时怎么办

| 现象 | 原因 | 处理 |
|---|---|---|
| warning `CJDOC2312: documentation source: inventory SHA-256 does not match the independently supplied host pin` | 索引字节与 pin 不一致（库已重生成，或 pin 抄错） | 重新生成库文档、重算摘要、更新 pin 后重新生成消费方 |
| warning `CJDOC2312: documentation source: documentation source catalog is invalid, unavailable or over budget` | catalog 文件不存在、`schemaVersion` 不是 `cjdoc.doc-sources/1`，或 `index` 指向的文件缺失、不安全 | 核对 catalog 路径、字段与索引路径；`index` 相对 catalog 目录解释 |
| warning `CJDOC2310` / `CJDOC2311: ... no documentation symbol in the selected module dependency context` | 没有可用的库文档匹配，或库版本与消费方使用的不一致 | 用消费方所用版本重新生成库文档，同步索引、摘要与已发布的 HTML |
| 链接已生成但打开是 404 | 库 HTML 树没复制，或位置与 `baseUrl` 不一致 | 把整个 `library-site/html` 复制到 `consumer-site/html/dependencies/linklib`，并确认发布平台保留文件名大小写 |
| 目标仍不确定 | 存在多个候选文档集、版本或语言 | 读 `docs.json` 里的导航状态收窄条件，不要按同名类型任选一份 |
| `error: repository URL must be a canonical GitHub HTTPS repository root`，退出码 `2` | 传了非 GitHub 地址或 `git@github.com:` 形式 | 先转成 `https://github.com/<owner>/<repo>` |
| `error: --repository-url and --repository-revision must be provided together` | 只给了其中一个 | 三个源码链接选项一起给 |
| `error: repository root must be an accessible directory` | `--repository-root` 不存在 | 指向仓库根的真实路径 |
| `error: repository revision must be non-empty without whitespace or controls` | revision 含空白或控制字符 | 用 `git rev-parse HEAD` 的完整提交号 |
| `error: --stdlib-doc-base-url is required for this standard-library documentation version` | 版本不在内置列表 | 补 `--stdlib-doc-base-url` |
| `error: --stdlib-doc-base-url must be HTTPS and end in /libs/std` | 地址不是 HTTPS 或后缀不对 | 使用形如 `https://cj-docs.gitcode.com/zh/<版本>/libs/std` 的地址 |

规则细节见[状态与限制](../reference/states-and-limits.md)与[CLI 参考](../reference/cli.md)，维护者视角的契约说明见[跨文档链接设计](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/maintainer/document-links.md)。

## 下一步

- [选择依赖源码与可见范围](select-inputs.md)。
- [生成并发布完整站点](generate-and-publish.md)。
- [查完整配置规则](../reference/configuration.md)。
