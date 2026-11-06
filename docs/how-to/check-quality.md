# 检查文档质量并设置门槛

本指南用 `docdemo` 查看覆盖率与结构质量报告，并在检查或生成时阻止低于门槛的输入。字段有内容、文字不像模板、说明符合实现是三种不同判断，自动报告不能代替作者复核。

## 前提

- 已完成[首次生成教程](../tutorials/first-site.md)，`docdemo/` 中有带摘要、`@param` 和 `@return` 的公开 `greet`。
- 已安装当前版本 `cjdoc`，仓颉运行环境在当前终端可用。命令在 `docdemo/` 项目根运行。
- 下例以 Bash 执行。为避免覆盖项目已有文件，工作流先保存 `src/api.cj` 和 `cjdoc.toml`，结束时恢复。

## 生成并阅读报告

`coverage` 输出字段是否有内容及其分母；`quality` 输出摘要/参数说明是否命中有限的模板规则。报告不证明作者说法正确，也不提供质量分门槛。

```bash
cjdoc generate --project . --format coverage --output target/quality-report
```

检查 `target/quality-report/coverage/coverage.json` 和 `target/quality-report/coverage/quality.json`。目录输出时会生成两份报告；启用 `[i18n]` 后还会生成 `coverage/translations.json`。若输出路径已存在但不是 cjdoc 管理的目录，选择新的 `target/` 子目录，不要先创建空的输出目录。报告字段的完整定义见[产物参考](../reference/artifacts.md)。

`coverage.json` 的七类指标是 `symbols`、`parameters`、`returns`、`throws`、`examples`、`deprecated` 和 `semanticLinks`。它们按当前 `--audience` 的可见声明计数，分母为零时百分比为 `100`。`quality.json` 只提供 symbols、parameters 两个 `meaningful` 百分比和 findings；三条模板规则分别是摘要重复声明名、参数说明重复参数名、返回值说明重复返回类型。没有命中模板，不代表文字充分。

## 用空摘要与空参数说明实测两套计数

配置 `[coverage]` 与 CLI 临时门槛不能互换：覆盖率报告要求摘要和参数说明非空；CLI 门槛只要求声明/参数已经绑定文档对象。以下完整工作流从 `docdemo/` 项目根目录运行，用 trap 还原原始 `src/api.cj` 与 `cjdoc.toml`。

```bash
set -eu
mkdir -p target
BACKUP="$(mktemp -d target/cjdoc-empty-fields.XXXXXX)"
cp src/api.cj "$BACKUP/api.cj"
if test -f cjdoc.toml; then
  cp cjdoc.toml "$BACKUP/cjdoc.toml"
  HAD_CONFIG=1
else
  HAD_CONFIG=0
fi
restore() {
  cp "$BACKUP/api.cj" src/api.cj
  if test "$HAD_CONFIG" -eq 1; then
    cp "$BACKUP/cjdoc.toml" cjdoc.toml
  else
    rm -f cjdoc.toml
  fi
  rm -rf "$BACKUP"
}
trap restore EXIT HUP INT TERM
OUT="target/empty-fields-report-$$"
test ! -e "$OUT"

cat > src/api.cj <<'CJ'
package docdemo

/**
 *
 * @param name
 */
public func greet(name: String): String {
    return "Hello, ${name}!"
}
CJ
rm -f cjdoc.toml
cjdoc check --project . --lint-profile off --no-cache \
  --min-symbol-coverage 100 --min-parameter-coverage 100

cat > cjdoc.toml <<'TOML'
[coverage]
symbols = 100
parameters = 100
TOML
if cjdoc generate --project . --no-cache --format coverage --output "$OUT"; then
  echo '错误：非空字段要求的 coverage 门槛意外通过' >&2
  exit 1
else
  status=$?
fi
test "$status" -eq 1
python3 - "$OUT/coverage/coverage.json" "$OUT/coverage/quality.json" <<'PY'
import json
from pathlib import Path
import sys

coverage = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
quality = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
for metric in ("symbols", "parameters"):
    values = coverage["metrics"][metric]
    assert values["total"] == 1 and values["documented"] == 0 and values["percent"] == 0
    assert quality[metric]["total"] == 1 and quality[metric]["meaningful"] == 0
print("CLI presence gate passed; report metrics found empty summary and parameter text.")
PY
```

第一次 `check` 应退出 `0`：CLI 的 `--min-symbol-coverage` 与 `--min-parameter-coverage` 统计文档对象是否存在；空摘要和空 `@param` 说明仍是已绑定对象。第二次 `generate` 应退出 `1`，但默认会在门槛失败时保留报告文件：`coverage.json` 的 `documented` 均为 `0`，而 `quality.json` 的 `meaningful` 均为 `0`。因此不能把 CLI 的 `100%` 解释成摘要/参数内容充分。命令结束或中断时 trap 恢复项目文件。

`[coverage]` 七类可配置指标为 `symbols`、`parameters`、`returns`、`throws`、`examples`、`deprecated` 和 `semantic-links`，取值均为 `0..100`；也可在 `[coverage.package.<包名>]` 为单个包设置门槛。该配置使用报告计数，并由 `generate`、`check`、`serve` 的构建执行；`render` 不执行门槛。`quality.json` 提供 symbols、parameters 两个有限模板启发式的 `meaningful` 百分比和 findings，不可配置为门槛，也不能证明语义正确。见[配置参考](../reference/configuration.md)与[产物参考](../reference/artifacts.md)。

计数实现：[CLI 对象存在性计数](https://github.com/lIlIIlIll/cjdoc/blob/main/src/render/renderers_output.cj)；[覆盖率报告的非空字段计数](https://github.com/lIlIIlIll/cjdoc/blob/main/src/render/coverage_v2.cj)。

一次性 CLI 门槛可直接用于 CI；这两个阈值只在命令行显式传入时应用：

```bash
cjdoc check --project . \
  --min-symbol-coverage 90 \
  --min-parameter-coverage 90
```

退出码 `0` 表示当前规则允许通过，`1` 表示 error、门槛失败或 `--deny-warnings` 拒绝了 warning，`2` 表示 CLI/配置错误。`--deny-warnings` 会把所有当前 warning 也作为失败处理。自动报告和门槛都不替代作者契约复核。

## 下一步

- 编译并运行文档中的程序：[检查示例](check-examples.md)。
- 核对源码行为和作者承诺：[复核 API 契约](review-contracts.md)。
- 查找具体阈值和规则键：[配置参考](../reference/configuration.md)。
