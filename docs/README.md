# cjdoc 文档

这里集中放 cjdoc 0.7.4 的文档。第一次使用请从仓库根目录的 [README](https://github.com/lIlIIlIll/cjdoc/blob/main/README.md) 开始；已经能生成文档、想深入某个主题时，按下表选择。

## 使用文档

| 文档 | 内容 |
|---|---|
| [README](https://github.com/lIlIIlIll/cjdoc/blob/main/README.md) | 安装、三步上手、常用任务和常见问题。 |
| [使用手册](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/usage.md) | 完整的日常任务说明：注释写法、示例检查、生成各类产物、check、diff、render、serve、排错和命令速查。 |
| [高级用法](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/advanced-usage.md) | 多格式组合、workspace 与依赖、缓存与并行、条件编译、多版本文档、面向 AI 代理的产物、自动化检查接入。 |
| [配置参考](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/configuration.md) | `cjdoc.toml` 的完整配置键：lint、覆盖率阈值、代码高亮、多语言、概念页。 |
| [概念页与指南](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/guides.md) | 把项目里的 Markdown 组织成文档页面，以及页面与 API 的绑定规则。 |
| [多语言文档](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/i18n.md) | 作者提供中英文正文、翻译配对、缺译策略和翻译覆盖率。 |
| [逐声明读取、查询与 MCP](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/agent-reading.md) | 静态 Markdown/JSON、固定快照、身份感知查询、续取、章节预算、已有报告和真实 stdio 客户端配置。 |
| [文档质量检查](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/documentation-quality.md) | 文档质量规则、覆盖率报告与 HTML 中的展示方式。 |
| [作者侧契约复核](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/contract-review.md) | 区分质量三层，以作者事实、源码和真实消费者复核输入域、失败与状态；保留未知。 |

## 维护者文档

- [维护者文档入口](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/maintainer/README.md)：从源码构建、发布流程、内部结构与设计研究记录。这些内容假定你在维护 cjdoc 本身，普通使用者不需要阅读。

## 建议阅读顺序

1. 第一次使用：根目录 [README](https://github.com/lIlIIlIll/cjdoc/blob/main/README.md) → [使用手册](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/usage.md)。
2. 需要配置项目或多格式输出：[配置参考](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/configuration.md)、[高级用法](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/advanced-usage.md)。
3. 需要多语言或文档度量：[多语言文档](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/i18n.md)、[文档质量检查](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/documentation-quality.md)。
4. 参与 cjdoc 开发：[维护者文档入口](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/maintainer/README.md)。
