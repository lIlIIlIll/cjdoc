# 检查文档质量并设置门槛

先运行检查读取诊断，再生成覆盖率与质量报告，最后把门槛写进 `cjdoc.toml`，让本地和 CI 用同一条 `check` 命令判断文档是否达标。字段是否有内容、文字是否像模板、说明是否符合实现是三种不同判断，自动报告只覆盖前两类的一部分。

## 前提

- 已完成[首次生成教程](../tutorials/first-site.md)，`docdemo/` 中有带摘要、`@param`、`@return` 和示例的公开 `greet`。
- 已安装 `cjdoc`，并在当前终端加载仓颉 SDK 环境。
- 以下命令都在 `docdemo/` 项目根执行。

## 运行检查并阅读诊断

`check` 读取当前项目并运行文档诊断，不写站点：

```bash
cjdoc check --project .
```

有诊断时，每条输出一行 `warning[诊断码]: 说明` 或 `error[诊断码]: 说明`，下一行是源文件与行列位置。没有诊断时命令不打印内容，退出码为 `0`。默认只有 error 导致失败；warning 会打印但不改变退出码，加上 `--deny-warnings` 后 warning 也算失败。规则严重级别可以在 `[lint]` 表中逐项改成 `off`、`warning` 或 `error`，键和默认值见[配置参考](../reference/configuration.md)。

`docdemo` 的 `greet` 注释完整，这一步不应出现缺注释、缺参数一类的诊断。如果看到 `CJDOC3034`（可见声明没有文档注释）或 `CJDOC3004`（参数缺少 `@param`），先按提示补注释，再继续生成报告。已经按[发布多语言页面](../tutorials/publish-languages.md)配置 `[i18n]` 的项目可能同时出现缺译 warning；默认 warning 不改变退出码，设置了缺译或翻译覆盖率门槛时按相应策略处理。

## 生成并阅读覆盖率与质量报告

在同一个项目根生成报告：

```bash
cjdoc generate --project . --format coverage --output target/quality-report
```

报告写入 `target/quality-report/coverage/coverage.json` 和 `target/quality-report/coverage/quality.json`；启用 `[i18n]` 后还会生成 `coverage/translations.json`。输出目录不存在时由 cjdoc 创建；如果 `target/quality-report` 已经存在且不是 cjdoc 管理的输出，换一个新的 `target/` 子目录，不要先手工创建空目录。

`coverage.json` 的 `metrics` 记录七类指标，`packages` 和 `modules` 用同样的结构给出分组：

| 指标 | 计入分母 | 计入已写 |
|---|---|---|
| `symbols` | 当前受众可见的声明 | 摘要非空 |
| `parameters` | 名称不以 `_` 开头的参数 | `@param` 说明非空 |
| `returns` | 有非 `Unit` 返回值的声明 | `@return` 说明非空 |
| `throws` | 实际写出的 `@throws` 条目 | 说明非空 |
| `examples` | 所有可见声明，没有注释的也计入 | 至少一个说明非空的 `@example` |
| `deprecated` | 实际写出的 `@deprecated` 条目 | 弃用说明非空 |
| `semanticLinks` | 记录的 `@see` 与结构化 Markdown 链接 | 解析成功 |

每项包含 `total`、`documented` 和 `percent`。分母为 `0` 时百分比按 `100` 计算，所以没有返回值、没有异常说明或没有语义链接的项目会显示 `0/0 (100%)`。只有首站教程的 `greet` 时，`symbols`、`parameters`、`returns` 和 `examples` 都应是 `1/1`；如果你已在[检查示例](check-examples.md)中加入 `add`，对应数字会随之增加。

`quality.json` 只计算 `symbols` 和 `parameters` 两个 `meaningful` 百分比，并列出 `findings`。三条模板规则分别检查摘要重复声明名、参数说明重复参数名、返回值说明重复返回类型；命中时 `findings` 中给出对应 `code` 和 `message`。这两个百分比不能配置成门槛，也没有最低质量分：没有命中模板不代表文字充分，命中也不代表说明错误。

## 设置持久覆盖率门槛

把门槛写进项目自己的 `cjdoc.toml`。如果文件中已经有 `[docs]`、`[i18n]` 或 `[[docs.pages]]`，在末尾追加 `[coverage]` 表，不要替换整个文件：

```toml
[coverage]
symbols = 100
parameters = 100
```

项目还没有 `cjdoc.toml` 时，新建该文件并写入同样的内容。文件里已经有 `[coverage]` 时，只补充缺少的键，不要重复表头。键名与报告指标对应，其中 `semantic-links` 带连字符；取值是 `0..100` 的整数，可用的键还包括 `returns`、`throws`、`examples` 和 `deprecated`。需要给单个包设不同门槛时用 `[coverage.package.<包名>]`，只需要求某个语言达到翻译比例时用 `[coverage.translation]`。

保存后重新运行检查：

```bash
cjdoc check --project .
```

`docdemo` 的注释完整，这一步应仍以 `0` 结束。任一指标低于门槛时，命令打印 `error: global <指标> coverage <实际>% is below <门槛>%`，并以 `1` 退出；包级门槛的消息以 `package <包名>` 开头。配置门槛在 `generate`、`check` 和 `serve` 的构建中执行，`render` 不执行。

## 在 CI 中使用退出码

CI 中直接运行同一条命令，用退出码判定：

```bash
cjdoc check --project .
```

`0` 表示本次启用的规则允许通过，`1` 表示有 error、门槛失败或 `--deny-warnings` 拒绝了 warning，`2` 表示命令行或配置错误。`2` 同样应让流水线失败，通常意味着 `[coverage]` 键名拼错、阈值越界或使用了不存在的选项。需要把 warning 也作为发布阻塞时加 `--deny-warnings`。

## 一次性 CLI 门槛与两套计数

不修改项目配置时，可以在 `check` 上临时要求符号和参数达到某个比例：

```bash
cjdoc check --project . --min-symbol-coverage 90 --min-parameter-coverage 90
```

传入任一选项时，命令会在诊断之外打印一行统计，例如 `documentation coverage: symbols 1/1 (100%), parameters 1/1 (100%)`。这两个门槛和 `[coverage]` 同时检查，互不覆盖。

两套数字统计的对象不同：

| 判断 | 已写的条件 | 设置位置 |
|---|---|---|
| `[coverage]` 门槛与报告（以 `symbols`、`parameters` 为例） | 摘要或参数说明的文字非空 | 项目 `cjdoc.toml` |
| `--min-symbol-coverage`、`--min-parameter-coverage` | 声明上存在文档对象；参数在 lint 阶段与 `@param` 绑定，说明为空也算已绑定 | `check` 命令行 |

因此注释里只写空的 `@param name`，又在 `cjdoc.toml` 配置 `[coverage].parameters = 100`，并同时传入 `--min-parameter-coverage 100` 时，`check` 会打印配置门槛的 error 和 `parameters 1/1 (100%)` 统计行，并以 `1` 退出。CLI 的 `100%` 只说明文档对象存在，不能当作参数说明已经写好。把这两个选项加在 `check` 上使用；`generate` 也会解析其中部分选项，但发布判断应交给同一条 `check` 命令。

## `--lint-profile off` 下的参数计数限制

`--lint-profile off` 关闭文档诊断，参数覆盖率也不再把这些 `@param` 说明算作已写。同一份写出 `@param name 要问候的名字。` 的源码，覆盖率报告的 `parameters` 会显示 `0/1`，CLI 参数门槛同样失败；HTML、Markdown 和搜索摘要仍然显示你写的参数说明。摘要、`@return` 和 `@example` 的计数不受影响。

关闭 lint 后，缺少注释、缺少参数等诊断也不再出现，检查通过不能说明这些字段已经写好。需要参数覆盖率数值和这些诊断时保留默认的 `standard`，或改用 `strict`。

## 遇到问题怎么办

- 门槛失败但字段看起来都有内容：核对失败指标的分母规则。`examples` 会把没有注释的可见声明计入分母，`semanticLinks` 只把解析成功的链接算作已写，`parameters` 会忽略 `_` 开头的参数。
- 退出码为 `2`：检查 `[coverage]` 的键名、阈值范围，以及同一文件是否重复了表头或键。
- 报告目录冲突：换一个尚不存在的输出目录，处理方式见[管理输出](manage-outputs.md)。
- 报告显示 `100%` 但说明没有帮助：用 `quality.json` 的 `findings` 找到模板化文字，再按[复核 API 契约](review-contracts.md)检查说明是否与实现一致。

## 下一步

- 编译并运行注释示例：[检查示例](check-examples.md)。
- 核对源码行为和作者承诺：[复核 API 契约](review-contracts.md)。
- 查找完整阈值、包级门槛和规则键：[配置参考](../reference/configuration.md)；报告字段：[产物参考](../reference/artifacts.md)。
