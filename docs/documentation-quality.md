# 文档质量检查

`cjdoc` 检查源码注释，不根据 API 名称生成使用说明。生成时的 `standard` 和
`strict` lint profile 都会报告以下 warning；`--lint-profile off` 关闭这些诊断。

| 诊断码 | 规则 | 命中示例 |
| --- | --- | --- |
| `CJDOC3040` | `trivial-summary` | `Wirestack 公开 API：foo。`、`foo` |
| `CJDOC3041` | `trivial-param-description` | `参数 url。`、`parameter url` |
| `CJDOC3042` | `trivial-return-description` | 返回类型为 `Foo` 时的 `返回 Foo。` |

规则忽略 ASCII 空白和大小写、句号、冒号以及行内代码标记，并要求整段文字匹配。
项目名前缀必须与 Doc IR 中的项目名一致。摘要只取 Markdown 的第一个正文段落。
参数检查跳过名称以 `_` 开头的参数。生成诊断检查 public 和 protected 声明。
当前通过 lint profile 整组控制，尚不支持逐条规则配置。

这些规则只识别已知模板。未命中不表示注释正确、完整或有足够的使用说明。
返回值、异常、示例和参数说明仍由库作者在源码中编写。

## 两种报告

```bash
cjdoc generate --project . --format coverage
```

生成两个文件：

- `target/doc/coverage/coverage.json`：原有 `cjdoc.documentation-coverage/1` 报告，
  衡量注释是否存在，保留原来的字段和计算方式。
- `target/doc/coverage/quality.json`：新增 `cjdoc.documentation-quality/1` 报告，
  包含本次受众范围内的质量规则命中，以及 symbols 和 parameters 的
  `total`、`meaningful`、`percent`。

`meaningful` 表示有非空摘要或参数说明，且未命中对应模板规则。
它是启发式计数，不是人工评审分数。没有正文段落的注释不计入 meaningful symbols。
百分比取整；分母为零时为 100。返回值命中列在 `findings` 中，不降低摘要比例。

`--format coverage --stdout` 只输出原有的 presence coverage JSON。

质量报告遵循 `--audience`，包含可见声明和成员。即使关闭生成 lint，显式请求
`--format coverage` 仍会计算质量报告。已有 `--min-symbol-coverage` 和
`--min-parameter-coverage` 阈值继续使用 presence coverage，不作为质量门禁。

可通过 `cjdoc schema documentation-quality` 查看报告 schema。Doc IR 保持
`cjdoc.doc-ir/8`，原 coverage schema 保持不变。

## HTML 展示

首页提供包入口与 API 分类入口。包页按类、结构体、接口、枚举、函数、变量与常量、
类型别名和扩展分组。重导出及源文件默认折叠。声明的 semantic state、源位置和
Symbol ID 保留在默认折叠的“声明元数据”中。

Doc IR v8 未提供项目描述、项目版本和仓库 URL。HTML 不从生成器版本推断项目版本，
也不构造仓库或源代码链接。顶部版本明确标注为 cjdoc 版本。

搜索支持精确名称、名称前缀、单词开头、CamelCase 首字母缩写，以及最多一次插入、
删除或替换的拼写容错。容错仅用于 4–128 个字符的查询；结果仍限制为 20 条。
