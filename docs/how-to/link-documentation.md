# 将依赖 API 链接到独立文档

本指南由同一份真实库源码生成 HTML 与 symbol index，再用本地 catalog、独立 SHA-256 pin 和实际消费方依赖建立文档链接。完成后会检查导航记录是否绑定了观察到的依赖 identity、声明的文档集、目标/cfg 范围和 pinned inventory。catalog 的展示 URL 或发布者自报摘要本身不是验证。

## 前提与工具身份

- 已按[源码安装](../getting-started/install.md)完成安装；当前 shell 保留 Cangjie SDK 1.2.0 runtime、匹配的静态 stdx 1.2.0、`cjc`、`cjpm` 和 Bash。
- `CJDOC_SOURCE` 与 `CJDOC_REVISION` 使用安装页记录的 checkout 和完整提交；本指南调用该 checkout 的 `target/release/bin/main`，不从 PATH 上的版本字符串推断工具身份。
- Python 3，用于检查生成的 Doc IR 和计算 inventory digest。
- 本页在新建的任务目录中完整创建库和消费方，不依赖仓库示例或虚构网址/提交。

以下命令从 Bash 执行。新终端先从安装记录恢复 `CJDOC_SOURCE`、`CJDOC_REVISION` 并重新加载 SDK 环境；再确认 `$HOME/.cache` 位于磁盘文件系统，而不是 tmpfs。

```bash
: "${CJDOC_SOURCE:?先按源码安装页设置 CJDOC_SOURCE}"
: "${CJDOC_REVISION:?从构建记录恢复与二进制配对的完整提交}"
test "$(git -C "$CJDOC_SOURCE" rev-parse --verify HEAD)" = "$CJDOC_REVISION"
export CJDOC_BIN="$CJDOC_SOURCE/target/release/bin/main"
if [ -f "$CJDOC_BIN.exe" ]; then export CJDOC_BIN="$CJDOC_BIN.exe"; fi
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) test -f "$CJDOC_BIN" ;;
  *) test -x "$CJDOC_BIN" ;;
esac

mkdir -p "$HOME/.cache/agent-tmp"
chmod 700 "$HOME/.cache/agent-tmp"
export TASK_AREA="$(mktemp -d "$HOME/.cache/agent-tmp/cjdoc-link-documentation.XXXXXX")"
export RUNNER_TEMP="$(mktemp -d "$TASK_AREA/runner-temp.XXXXXX")"
export TMPDIR="$RUNNER_TEMP" TMP="$RUNNER_TEMP" TEMP="$RUNNER_TEMP"
export PYTHONDONTWRITEBYTECODE=1
case "$TASK_AREA/" in
  "$CJDOC_SOURCE/"*) printf '任务目录必须位于 CJDOC_SOURCE 之外\n' >&2; exit 1 ;;
esac
export TASK_ROOT="$TASK_AREA/project"
mkdir -p "$TASK_ROOT/library/src" "$TASK_ROOT/consumer/src"
git -C "$CJDOC_SOURCE" show "$CJDOC_REVISION:scripts/with_stdx.py" \
  > "$TASK_ROOT/with_stdx.py"
```

这一步只读取源码 checkout 与已构建二进制；示例文件、静态 stdx 认证脚本副本、cjpm 构建产物、输出和 catalog 都在 `$TASK_ROOT`，不会改动 `CJDOC_SOURCE`。

## 为仓库声明生成源码链接

源码链接依赖可证明的仓库根、源文件相对路径和所选 revision。下面使用记录提交中的真实 `tools/chir-protocol` 静态 package；项目根是该子包，仓库根是完整 checkout。revision 使用安装记录的完整提交，输出在任务目录且禁用源码缓存。checkout 必须与该提交的 tracked 输入一致。

```bash
cd "$CJDOC_SOURCE"
python3 - "$CJDOC_SOURCE" "$CJDOC_REVISION" <<'PY'
import sys
from pathlib import Path
from scripts.worktree_identity import exact_worktree_identity

identity = exact_worktree_identity(Path(sys.argv[1]), sys.argv[2])
print("source links use commit:", identity["headCommit"])
PY

"$CJDOC_BIN" generate --project "$CJDOC_SOURCE/tools/chir-protocol" \
  --format html --format json --no-cache \
  --repository-url https://github.com/lIlIIlIll/cjdoc \
  --repository-revision "$CJDOC_REVISION" \
  --repository-root "$CJDOC_SOURCE" \
  --output "$TASK_ROOT/cjdoc-source-site"
```

确认生成页面中的源码地址指向该 revision，而不是 `main` 或另一份 checkout：

```bash
python3 - "$TASK_ROOT/cjdoc-source-site/html" "$CJDOC_REVISION" <<'PY'
import sys
from pathlib import Path

root, revision = Path(sys.argv[1]), sys.argv[2]
prefix = f"https://github.com/lIlIIlIll/cjdoc/blob/{revision}/tools/chir-protocol/src/"
if not any(prefix in path.read_text(encoding="utf-8")
           for path in root.rglob("*.html")):
    raise SystemExit("生成的 HTML 中没有指向记录 revision 的 GitHub 源码链接")
print("HTML 源码链接指向记录的完整 revision")
PY
```

`--repository-url` 与 `--repository-revision` 必须成对提供；URL 必须是 canonical GitHub HTTPS 仓库根。`--repository-root` 只用于正确映射仓库内源码位置，不会让仓库外的依赖文件变成仓库源码。缺少可靠路径映射、路径越过根目录或通过符号链接逃逸时，不应生成链接。三个选项适用于 `generate`；`render` 使用已写入 Doc IR 的信息。源码链接只标出源位置，不证明源码在该 revision 与当前二进制完全一致，除非两者使用同一受保护提交。

## 链接标准库文档

此独立 docs-only package 展示 `ArrayList<String>` 与 `String` 的自动链接。生成不编译被扫描项目，也不改 SDK；链接目标显式选择内置目录 STS 1.2.0。

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

"$CJDOC_BIN" generate --project "$TASK_ROOT/stdlib" \
  --format html --no-cache --stdlib-doc-version 1.2.0 \
  --output "$TASK_ROOT/stdlib-site"

python3 - "$TASK_ROOT/stdlib-site/html" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
pages = [path.read_text(encoding="utf-8") for path in root.rglob("*.html")]
html = "\n".join(pages)
targets = (
    "https://cj-docs.gitcode.com/zh/1.2.0/libs/std/collection/"
    "collection_package_api/collection_package_class.html#class-arraylistt",
    "https://cj-docs.gitcode.com/zh/1.2.0/libs/std/core/"
    "core_package_api/core_package_structs.html#struct-string",
)
missing = [url for url in targets if url not in html]
if missing:
    raise SystemExit("标准库类型链接未指向预期的 1.2.0 文档目录：" + ", ".join(missing))
print("ArrayList 与 String 链接指向 STS 1.2.0 标准库文档")
PY
```

版本参数只选择链接目录，不证明项目实际使用的 std API 与目标文档完全一致。当前内置版本为 `1.0.5`、`1.1.0`、`1.1.0-beta.25`、`1.1.3`、`1.2.0`；其他版本必须同时传 `--stdlib-doc-base-url`，其值必须是 HTTPS 且以 `/libs/std` 结尾。比如 1.1.4 的真实官方文档根为 `https://cj-docs.gitcode.com/zh/1.1.4/libs/std`。未知版本不会猜测主机；`--stdlib-doc-version` 与 `--stdlib-doc-base-url` 只适用于 `generate`，render 会保留既有链接。它们与站点发布标签 `--doc-version` 无关。

如果没有找到某个标准库链接，先确认类型被当前文档目录收录且导入可唯一解析。通配导入只是候选名称；显式未知导入、条件导入、多个不同目标或名称歧义会保守地不链接。类型链接是文档导航，不是标准库 API/ABI 兼容性证明。

## 创建库与消费方

库和消费方是两个完整的 Cangjie 静态 package。消费方通过 path dependency 使用库中的公开类型，并在注释中引用该类型。

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

(cd "$TASK_ROOT/library" && \
  python3 "$TASK_ROOT/with_stdx.py" --variant static -- cjpm build --jobs 1)
(cd "$TASK_ROOT/consumer" && \
  python3 "$TASK_ROOT/with_stdx.py" --variant static -- cjpm build --jobs 1)
```

两个构建都应成功退出。若 cjpm 无法解析 `linklib`，请确认第二次构建从 `$TASK_ROOT/consumer` 执行，且 `path` 为 `../library`。

## 生成并固定库的 inventory

从消费方构建所使用的同一份库源码生成 HTML 站点与 symbol index。`html/symbol-index.json` 保存实际生成的 API identity 与路由。

```bash
"$CJDOC_BIN" generate --project "$TASK_ROOT/library" \
  --format html --format symbol-index \
  --output "$TASK_ROOT/library-site"

export INDEX="$TASK_ROOT/library-site/html/symbol-index.json"
test -f "$INDEX"
export PIN="$(python3 - "$INDEX" <<'PY'
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
printf '库 inventory 的 SHA-256：%s\n' "$PIN"
```

后续生成命令把读取到的摘要作为独立 pin。它将 inventory 文件字节与此处生成的文件绑定，但不能证明任意远端主机正在提供相同字节。

## 添加本地 catalog 并生成消费方

catalog 中的 `index` 是相对于 catalog 文件目录的 canonical 路径。`baseUrl` 是站点内链接的基址；最后的复制步骤把 producer 站点放到该地址对应的目录。

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

"$CJDOC_BIN" generate --project "$TASK_ROOT/consumer" \
  --include-path-dependencies \
  --doc-source "$TASK_ROOT/cjdoc-documents.json" \
  --doc-inventory-pin "$INDEX=$PIN" \
  --format html --format json \
  --output "$TASK_ROOT/consumer-site"
```

cjdoc 读取消费方的真实 path dependency 和已 pin 的 producer inventory，不会获取 catalog 项目或文档。`baseUrl` 只选择链接目标的位置；它不会认证网站或建立 API identity。

## 核对选中的 identity 并发布本地目标

不要把非空 URL 当作验证。exact dependency navigation 必须引用已声明 document set 和实际观察到的 source dependency；API identity、inventory identity、target 与 cfg 都须与这些记录一致。下面在任务目录创建一次性检查脚本，只用来复核本例生成的 Doc IR：

```bash
cat > "$TASK_ROOT/check-navigation.py" <<'PY'
import json
import sys
from pathlib import Path

doc = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = sys.argv[2]

def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

sets = {item["id"]: item for item in doc["documentSets"]}
dependencies = {item["instanceId"]: item for item in doc["dependencies"]}
matched = []
for navigation in walk(doc):
    if (navigation.get("state") != "resolved"
            or navigation.get("matchLevel") != "exact"
            or not navigation.get("documentSetId")
            or not navigation.get("dependencyInstanceId")):
        continue
    document_set = sets.get(navigation["documentSetId"])
    dependency = dependencies.get(navigation["dependencyInstanceId"])
    if document_set is None or dependency is None:
        continue
    if (document_set["state"] == "declared"
            and dependency["state"] in {"observed", "verified"}
            and dependency["kind"] == "source"
            and dependency.get("componentModuleId")
            and document_set["identity"] == navigation.get("apiIdentity") == dependency["identity"]
            and navigation.get("indexIdentity") == document_set["indexIdentity"]
            and dependency.get("target") == document_set.get("target")
            and dependency.get("cfg") == document_set.get("cfg")):
        matched.append((navigation, document_set, dependency))

if expected == "exact":
    if not matched:
        raise SystemExit("没有找到 identity 一致的 exact dependency navigation")
    navigation, document_set, dependency = matched[0]
    print("exact 链接绑定到观察到的源码依赖和 pinned inventory")
    print("依赖：", dependency["name"], dependency["identity"])
    print("API identity：", document_set["identity"])
    print("inventory identity：", document_set["indexIdentity"])
elif expected == "different":
    mismatches = []
    for document_set in sets.values():
        for dependency in dependencies.values():
            if (document_set["state"] == "declared"
                    and document_set["library"] == dependency["name"]
                    and dependency["kind"] == "source"
                    and dependency["state"] in {"observed", "verified"}
                    and dependency.get("componentModuleId")
                    and document_set.get("target") == dependency.get("target")
                    and document_set.get("cfg") == dependency.get("cfg")
                    and document_set["identity"] != dependency["identity"]):
                mismatches.append((document_set, dependency))
    if matched or not mismatches:
        raise SystemExit("没有观察到预期的 API identity 不匹配")
    document_set, dependency = mismatches[0]
    print("观察到 producer inventory 与源码依赖的 API identity 不同")
    print("producer API identity：", document_set["identity"])
    print("当前依赖 identity：", dependency["identity"])
else:
    raise SystemExit("expected 参数只能是 exact、none 或 different")
PY

python3 "$TASK_ROOT/check-navigation.py" \
  "$TASK_ROOT/consumer-site/docs.json" exact
```

这个检查核对的是生成文件中的绑定关系，不是 catalog 对 URL 或 API/ABI 的外部认证。若正例没有 exact navigation，先检查 `docs.json` 的诊断、dependencies、document sets、target/cfg、消费者签名以及 pin；不要把 manual 或 compatible 链接改称 verified。

本地 catalog 使用 `./dependencies/linklib`，所以打开或发布消费者站点前，要把 producer 的完整 HTML 树复制到 consumer 的 HTML 根目录下：

```bash
mkdir -p "$TASK_ROOT/consumer-site/html/dependencies/linklib"
cp -R "$TASK_ROOT/library-site/html/." \
  "$TASK_ROOT/consumer-site/html/dependencies/linklib/"
```

打开 `$TASK_ROOT/consumer-site/html/index.html`。消费者 API 页面应能链接到复制的库页面。发布到其他地址时复制完整 `html/` 树，并把 `baseUrl` 改成实际部署位置；不要把示例或占位主机写进生产 catalog。

## 检查 pin 与源码 identity 失败

错误 pin 不应授权使用 inventory。翻转一个十六进制字符，并生成到独立输出目录：

```bash
export WRONG_PIN="$(python3 - "$PIN" <<'PY'
import sys
pin = sys.argv[1]
print(("0" if pin[0] != "0" else "1") + pin[1:])
PY
)"

"$CJDOC_BIN" generate --project "$TASK_ROOT/consumer" \
  --include-path-dependencies \
  --doc-source "$TASK_ROOT/cjdoc-documents.json" \
  --doc-inventory-pin "$INDEX=$WRONG_PIN" \
  --format html --format json \
  --output "$TASK_ROOT/wrong-pin-site"
python3 "$TASK_ROOT/check-navigation.py" \
  "$TASK_ROOT/wrong-pin-site/docs.json" none
```

错误 pin 会令该 inventory 不可用，而不是产生 exact 链接。cjdoc 仍可能成功生成消费方自己的文档；错误 pin 不一定使整个生成命令失败。

再检查 producer inventory 与消费方实际源码不同的情形。此处在任务目录的库源码中增加一个公开函数，让 API identity 发生变化；消费方仍使用原有公开 API，因此可以重新构建，但旧 inventory 不再与它匹配。

```bash
python3 - "$TASK_ROOT/library/src/api.cj" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
if "addedAfterPin" in source:
    raise SystemExit("公开函数已存在，请使用新 TASK_ROOT 重做此例")
addition = """

/** 在 producer inventory 固定后新增的公开 API。 */
public func addedAfterPin(): Unit {}
"""
path.write_text(source.rstrip() + addition, encoding="utf-8")
PY

(cd "$TASK_ROOT/consumer" && \
  python3 "$TASK_ROOT/with_stdx.py" --variant static -- cjpm build --jobs 1)
"$CJDOC_BIN" generate --project "$TASK_ROOT/consumer" \
  --include-path-dependencies \
  --doc-source "$TASK_ROOT/cjdoc-documents.json" \
  --doc-inventory-pin "$INDEX=$PIN" \
  --format html --format json \
  --output "$TASK_ROOT/changed-source-site"
python3 "$TASK_ROOT/check-navigation.py" \
  "$TASK_ROOT/changed-source-site/docs.json" different
```

源码变化后，消费方观察到的 dependency identity 不再与旧 inventory 对应，因此不应产生 exact 链接。比较各次生成时保留独立源码与输出目录。

## 后续任务

- [选择要扫描的源码](select-inputs.md)
- [配置 cjdoc](../reference/configuration.md)
- [检查状态与能力边界](../reference/states-and-limits.md)
