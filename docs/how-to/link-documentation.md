# 将依赖 API 链接到独立文档

为库生成文档和符号索引，再让消费方的参数类型和相关链接跳到这份库文档。本页创建两个完整静态库，完成后可以从消费方的 `render` 页面点击 `Label`，进入依赖库的 API 页面。

## 前提

- 已安装 `cjdoc`，当前终端已加载仓颉 SDK 1.2.0 环境，`cjpm` 可用。
- Bash 和 Python 3；Python 只用标准库计算文件摘要。
- 从任意目录开始，创建独立练习目录：

```bash
mkdir -p "$HOME/.cache/cjdoc/examples"
TASK_ROOT="$(mktemp -d "$HOME/.cache/cjdoc/examples/links.XXXXXX")"
mkdir -p "$TASK_ROOT/library/src" "$TASK_ROOT/consumer/src"
```

`TASK_ROOT` 是本页文件的存放位置，后续一直沿用这个绝对路径；也可以选择自己的空目录。

## 创建库与消费方

库提供 `Label` 类型。写入完整清单和源码：

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

消费方通过相对路径依赖使用这个类型，并在注释中引用它：

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

import linklib.*

/** 返回真实 linklib 依赖提供的文本。
 * @param label 来自 linklib 的值。
 * @see linklib.Label
 */
public func render(label: Label): String { label.text() }
EOF

(cd "$TASK_ROOT/library" && cjpm build --jobs 1)
(cd "$TASK_ROOT/consumer" && cjpm build --jobs 1)
```

两次构建都应成功。若消费方找不到 `linklib`，确认库与消费方是同级目录，清单中的 `path` 为 `../library`。

## 生成库文档并计算摘要

先为库生成 HTML 和符号索引。索引也称 inventory，记录这份文档有哪些 API 及其页面地址：

```bash
cjdoc generate --project "$TASK_ROOT/library" \
  --format html --format symbol-index --output "$TASK_ROOT/library-site"
INDEX="$TASK_ROOT/library-site/html/symbol-index.json"
```

为整个索引文件计算 SHA-256，后续用这个摘要固定要读取的索引：

```bash
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

输出是 64 位十六进制摘要。索引内容变化后需要重新计算；不要复用旧摘要。

## 登记库文档并生成消费方

用 catalog 告诉 cjdoc 在哪里读取索引，以及发布后依赖页面放在哪里：

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

catalog 的 `index` 相对 **catalog 文件所在目录**解释；`--doc-inventory-pin` 中的路径相对 **命令当前目录**解释。本例让 `INDEX` 使用绝对路径，避免两个基准混淆。pin 校对索引的实际字节；它不认证远端网站。

这里不加 `--include-path-dependencies`：消费方仍通过清单记录实际依赖，但 `linklib` 的页面由独立库站点提供。加入该选项会将依赖源码也纳入本地文档，类型链接可能转到本地页面，详见[选择输入](select-inputs.md)。

## 放入依赖页面并沿链接阅读

catalog 不会替你复制或下载文档。把库的完整 HTML 树放到 `baseUrl` 对应位置：

```bash
mkdir -p "$TASK_ROOT/consumer-site/html/dependencies"
cp -R "$TASK_ROOT/library-site/html" "$TASK_ROOT/consumer-site/html/dependencies/linklib"
xdg-open "$TASK_ROOT/consumer-site/html/index.html"
```

在消费方的 `render` 页面点击参数类型 `Label`，再点击相关链接中的 `linklib.Label`。两处都应打开刚生成的库文档，库页中可以阅读 `Label.text()`。发布时上传完整 `consumer-site/html/`，包含 `dependencies/linklib/`；不要只上传消费方页面。

macOS 用 `open`，Windows PowerShell 用 `Start-Process` 打开同一个入口。

## 链接没有出现时

- **pin 不匹配**：该索引不可用，不会据此生成确定匹配的链接。消费方自身的文档仍可能生成成功，因此要阅读索引相关诊断。确认选中了正确索引，重新生成库文档、计算摘要，再更新 pin 并生成消费方。
- **库源码或版本已变**：旧索引可能不再对应消费方实际使用的库。用消费方所用版本重新生成库文档，同时更新索引、摘要和发布的 HTML。
- **已有链接但打开是 404**：确认复制了整个库 HTML 树，位置与 `baseUrl` 一致，发布平台保留文件名大小写。
- **目标仍不确定**：文档集、版本、语言或依赖范围可能不匹配，也可能有多个候选。查看 `docs.json` 的导航状态，不要按同名类型任选一份文档。

完整选择规则、歧义和摘要约束见[维护者的跨文档链接说明](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/maintainer/document-links.md)。可读状态定义见[状态与限制](../reference/states-and-limits.md)。

## 可选：链接到自己的源码

在你已经公开发布的 GitHub 项目根目录操作。先确认当前 HEAD 已推送，读者能访问它；下面从该项目的 origin 和 HEAD 取得仓库地址与 revision：

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

origin 需要是 GitHub HTTPS 或上面转换的 `git@github.com:` 形式；其它形式先手动将 `SOURCE_REPOSITORY` 设为实际的 `https://github.com/<owner>/<repo>` 根地址。生成后从声明页面的源码入口打开对应提交中的文件。仓库 URL 与 revision 必须成对提供，源码必须位于仓库根内；这些参数标出源码位置，不负责推送源码。

## 可选：链接标准库文档

选择与读者使用的 SDK 对应的标准库文档版本。下面创建一个独立静态库，展示 `ArrayList<String>` 和 `String` 链接：

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

/** 接收标准库列表并返回文本。
 * @param values 标准库列表。
 * @return 示例文本。
 */
public func accept(values: ArrayList<String>): String { "ok" }

/** 使用限定类型名声明同一组标准库类型。 */
public func acceptQualified(values: std.collection.ArrayList<String>): std.core.String {
    "ok"
}
EOF

cjdoc generate --project "$TASK_ROOT/stdlib" \
  --format html --stdlib-doc-version 1.2.0 --output "$TASK_ROOT/stdlib-site"
```

打开 `$TASK_ROOT/stdlib-site/html/index.html`，在函数签名里点击 `ArrayList` 和 `String`，应进入 1.2.0 标准库文档。版本参数只选择链接目录，不检查项目是否使用了完全相同的 SDK API。

内置文档版本为 `1.0.5`、`1.1.0`、`1.1.0-beta.25`、`1.1.3`、`1.2.0`。其它版本需要同时给 `--stdlib-doc-base-url`，它必须是以 `/libs/std` 结尾的 HTTPS 根地址，例如官方 `https://cj-docs.gitcode.com/zh/1.1.4/libs/std`。两个选项只适用于 `generate`，与站点发布标签 `--doc-version` 不同；`render` 保留快照中的既有链接。

## 下一步

- [选择依赖源码与可见范围](select-inputs.md)。
- [查完整配置规则](../reference/configuration.md)。
- [发布整个站点](generate-and-publish.md)。
