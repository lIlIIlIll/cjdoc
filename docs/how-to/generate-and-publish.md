# 生成并发布文档

本指南从 `docdemo` 项目生成 API 文档、报告和机器可读索引，并把完整 HTML 站点交给本地服务器或静态托管。HTML 是一组互相引用的文件，发布时要保留整个 `html/` 目录。

## 前提

- 已按[首次生成教程](../tutorials/first-site.md)创建 `docdemo`，并在项目根目录执行后续命令。当前目录应含 `cjpm.toml` 和 `src/api.cj`。
- 已安装与当前 cjdoc 源码版本匹配的 `cjdoc`。仓颉 SDK 运行环境在当前终端生效，`cjdoc --version` 可运行；详见[安装说明](../getting-started/install.md)。
- 使用 POSIX shell。静态站点本地预览需要 Python 3；端口 `8000` 必须空闲。

## 一次生成六种格式

在 `docdemo/` 项目根目录使用同一个扫描结果生成 HTML、Markdown、Doc IR、API 快照、覆盖率报告和符号索引。选择一个尚未存在的输出目录；cjdoc 创建并记录其产物所有权。

```bash
OUT=target/doc-publish
if test -e "$OUT"; then
  printf '输出路径已存在，请选择一个新的 target 子目录：%s\n' "$OUT" >&2
  exit 2
fi
cjdoc generate --project . \
  --format html \
  --format markdown \
  --format json \
  --format api-surface \
  --format coverage \
  --format symbol-index \
  --output "$OUT"
```

成功后可检查这些主要入口：

```text
target/doc-publish/docs.json
target/doc-publish/html/index.html
target/doc-publish/html/symbol-index.json
target/doc-publish/markdown/index.md
target/doc-publish/api-surface/api-surface.json
target/doc-publish/coverage/coverage.json
target/doc-publish/coverage/quality.json
target/doc-publish/symbol-index/symbol-index.json
```

HTML 生成时也会在 `html/` 内生成站点使用的搜索、导航和符号索引文件。把整个 `target/doc-publish/html/` 作为静态站点根目录上传，不要只上传 `index.html`。若某种格式失败，先检查当前目录是否为项目根、输出目录是否由 cjdoc 管理，以及 CLI 诊断；错误退出码见[CLI 参考](../reference/cli.md)。

## 把单份 JSON 写入标准输出

`--stdout` 适用于需要管道或重定向的单个 JSON 类格式。它必须与 `--output` 互斥，且只接受一个格式：`json`、`api-surface`、`coverage` 或 `symbol-index`。

```bash
set -e
mkdir -p target
SNAPSHOT="$(mktemp target/docdemo-snapshot.XXXXXX)"
cjdoc generate --project . --format json --stdout > "$SNAPSHOT"
test -s "$SNAPSHOT"
```

`$SNAPSHOT` 是完整的 `docs.json`。诊断写到标准错误，不会混入 JSON 文件。若 `test -s` 失败，检查上一步的退出码和标准错误，不要把诊断文本当作 JSON 输入。

以下组合是有意的负例：解析器拒绝把 stdout 和目录输出混在一起，并以 CLI/参数错误退出码 `2` 结束。

```bash
if cjdoc generate --project . --format json --stdout --output target/invalid-output; then
  echo '错误：互斥的 --stdout 和 --output 被接受' >&2
  exit 1
else
  status=$?
fi
test "$status" -eq 2
```

## 本地打开并检查静态站点

在 `docdemo/` 根目录启动只绑定回环地址的 Python 静态服务器；另开一个终端确认站点入口可读。

```bash
python3 -m http.server 8000 --bind 127.0.0.1 --directory target/doc-publish/html
```

```bash
curl -fsS -o /dev/null http://127.0.0.1:8000/
```

`curl` 退出码为 `0` 表示入口返回成功。浏览器打开 `http://127.0.0.1:8000/`，搜索 `greet`，并跟随声明页、搜索脚本和样式资源，确认 API 页面可阅读。停止服务器时回到运行它的终端按 `Ctrl+C`。若端口占用，停止占用端口的进程，或在两个命令中同时改用一个空闲端口。

本地服务器只用于检查静态文件。正式发布时，将 `target/doc-publish/html/` 的全部内容设为静态托管的文档根目录，并在托管平台检查首页、资源和深链；cjdoc 不会替你上传或配置托管服务。部署故障先确认复制了完整目录，且托管平台保留相对路径和大小写。

## 下一步

- 用[质量检查](check-quality.md)设置发布门槛。
- 用[示例检查](check-examples.md)编译并运行注释示例。
- 需要重渲染已保存的 `docs.json` 时，见[离线重渲染快照](render-snapshots.md)。
