# 从离线 Doc IR 重渲染文档

`cjdoc render` 从保存的 `docs.json` 生成新格式，不重新扫描仓颉源码。适合源码不可用、或只想重新输出 HTML/Markdown 的场景；它只读取当前 Doc IR wire 格式。

## 前提

- 已完成[首次生成教程](../tutorials/first-site.md)，并能在 `docdemo/` 根目录运行当前版本的 `cjdoc`。
- 本例用 Python 3 复制并修改一个任务用 JSON 文件；Bash 用于保存输出目录。
- `render` 的输入必须是当前 `cjdoc.doc-ir/18` 的 `docs.json`。旧 Doc IR 不会自动升级；有原始源码时，先用对应版本的 cjdoc 重新执行 `generate`。

## 捕获快照并在项目目录外重渲染

先从源码生成 Doc IR，然后把快照放入独立的重渲染目录。从重渲染目录执行 `render`，命令不需要 `--project`、`cjpm.toml`、源码缓存或源码路径。

```bash
cjdoc generate --project . --format json --output target/doc-ir-capture
WORK="$PWD/target/doc-ir-replay"
mkdir -p "$WORK"
cp target/doc-ir-capture/docs.json "$WORK/current.json"
(
  cd "$WORK"
  cjdoc render --input current.json \
    --format html --format markdown \
    --output rendered
)
test -f "$WORK/rendered/html/index.html"
test -f "$WORK/rendered/markdown/index.md"
```

成功后，从 `$WORK/rendered/html/index.html` 打开 HTML，或读取 `$WORK/rendered/markdown/index.md`。`render` 保留快照里已捕获的源码位置、项目/受众/语言等信息；不会重新观察源码、读取项目配置、执行示例或重新计算依赖和标准库链接。

`render` 可重复指定 `--format`；支持 `json`、`markdown`、`html`、`api-surface`、`coverage` 和 `symbol-index`，省略时默认 `json`。不写 `--output` 时，默认写当前目录的 `target/doc`。与 `generate` 一样，目录输出要由 cjdoc 管理；不要手动预建空输出根。`render` 不执行配置覆盖率门槛。

## 负例：拒绝旧 Doc IR wire

下面复制一份快照，只把 `schemaVersion` 改成上一版标识，再尝试渲染。JSON 仍是合法 JSON，但不是受支持的当前 Doc IR，因此命令应以输入错误退出码 `2` 结束，也不应创建拒绝用的输出目录。

```bash
WORK="$PWD/target/doc-ir-replay"
python3 - "$WORK/current.json" "$WORK/old.json" <<'PY'
import json
from pathlib import Path
import sys

source, destination = map(Path, sys.argv[1:])
document = json.loads(source.read_text(encoding="utf-8"))
document["schemaVersion"] = "cjdoc.doc-ir/17"
destination.write_text(
    json.dumps(document, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY
if (cd "$WORK" && cjdoc render --input old.json --format html --output rejected); then
  echo '错误：旧 Doc IR 被接受' >&2
  exit 1
else
  status=$?
fi
test "$status" -eq 2
test ! -e "$WORK/rejected"
```

需要从旧快照恢复时，若原始项目源码仍在，使用与该输入相匹配的源码和当前 cjdoc 重新生成；没有源码时，没有受支持的旧 Doc IR 迁移路径。Doc IR wire、格式限制和相关 schema 见[产物参考](../reference/artifacts.md)。

## 下一步

- [比较 API 并组合版本站点](compare-and-version.md)：准备不同版本的真实源码快照。
- [生成并发布文档](generate-and-publish.md)：发布静态 HTML 文件树。
- [排查常见故障](troubleshoot.md)：定位旧 wire、损坏输入或输出冲突。
