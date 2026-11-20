# 从空目录生成第一个 API 站点

从空目录新建一个仓颉库，为 `greet` 写文档注释，再生成可离线阅读的 API 页面。

## 前提条件

- 已[安装 cjdoc](../getting-started/install.md)，当前终端能运行 `cjdoc --version`、`cjc -v` 和 `cjpm -v`。
- 当前目录可写，其中还没有名为 `docdemo` 的目录。

## 1. 创建静态库

在工作目录执行：

```bash
cjpm init --name docdemo --path docdemo --type=static
cd docdemo
```

`cjpm init` 成功后，目录里应有 `cjpm.toml` 和 `src/`。

将 `cjpm.toml` 替换成这份不带外部依赖的清单：

```toml
[package]
name = "docdemo"
version = "0.1.0"
cjc-version = "1.2.0"
output-type = "static"

[dependencies]
```

## 2. 添加一个带注释的公开函数

新建完整文件 `src/api.cj`：

~~~cangjie
package docdemo

/**
 * 为名字生成问候语。
 *
 * 名字中的空白原样保留。
 *
 * @param name 要问候的名字，可以为空。
 * @return 格式为 `Hello, <name>!` 的字符串。
 * @example 问候仓颉 {must-pass run}
 * ```cangjie
 * println(greet("Cangjie"))
 * println(greet(""))
 * ```
 * ```output
 * Hello, Cangjie!
 * Hello, !
 * ```
 */
public func greet(name: String): String {
    return "Hello, ${name}!"
}

// 这个私有函数不会出现在默认的 API 页面上。
private func internalGreeting(): String {
    return "internal"
}
~~~

`/** ... */` 是文档注释。第一段写摘要，后续正文写行为；`@param`、`@return` 和 `@example` 分别写入页面对应的位置。普通 `//` 或 `/* ... */` 注释不会成为文档。公开声明即使没有注释也会列出，只是没有作者说明。

## 3. 生成 HTML

在 `docdemo/` 中执行：

```bash
cjdoc generate --project . --format html
```

生成成功后出现 `target/doc/html/index.html`。省略 `--format` 且没有设置 `[output].formats` 时，生成的是 `target/doc/docs.json`，不是站点。

## 4. 在浏览器里阅读 `greet`

用浏览器的“打开文件”选择 `target/doc/html/index.html`，不必启动服务器。从首页进入 `docdemo` 包再点 `greet`，也可以在页眉搜索 `greet`。页面应显示签名、`name` 的说明，以及同一示例里的代码和两行预期输出。默认看不到私有的 `internalGreeting`。

想确认示例真的可以运行，在项目根执行：

```bash
cjdoc check --project . --check-examples
```

命令应以 `0` 退出。`{must-pass run}` 要求编译并运行片段，再比较作者写在 `output` 围栏中的两行。HTML 展示的是围栏中的文字，不是运行日志。若出现 `CJDOC3072`，从诊断里对照实际和预期输出；若出现 `CJDOC3074`，当前环境未能构建可执行文件或施加运行所需的内存限制，见[示例检查](../how-to/check-examples.md)。

## 失败时怎么办

| 看到什么 | 怎么处理 |
|---|---|
| `cjpm` 或 `cjdoc` 找不到，或者缺仓颉共享库 | 在当前终端重新加载 SDK 环境，并确认 `cjdoc` 所在目录在 `PATH` 中 |
| `CJDOC1010` 提示缺少 `cjpm.toml` | 切回 `docdemo/`，不要停在 `src/`；也可用 `--project` 指向项目根 |
| 构建有类型链接警告 | 说明某些类型链接未解析；先看诊断和退出码，再按 [CHIR 排错](../how-to/chir.md)处理 |
| 修改注释后页面没更新 | 重新执行生成命令，再刷新当前项目的 `target/doc/html/index.html`；频繁改动可用[本地预览](../how-to/preview.md) |

## 下一步

[给同一个库加入首页、包概述和指南](add-guides.md)。查其他标签的写法，见[文档注释参考](../reference/doc-comments.md)。
