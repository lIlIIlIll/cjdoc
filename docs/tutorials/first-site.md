# 从空目录生成第一个 API 站点

用一个没有外部依赖的静态库 `docdemo`，从写注释走到在浏览器里读到 API 页面。完成后你会得到 `target/doc/html/index.html`，其中能读到 `greet` 的签名、参数、返回值和示例。[加入指南](add-guides.md)和[发布中英文](publish-languages.md)继续使用这个库。

## 前提

- 已按[安装 cjdoc](../getting-started/install.md)安装 `cjdoc`，并在当前终端加载仓颉 SDK 环境。

确认命令和环境可用：

```bash
command -v cjdoc
cjdoc --version
```

第一条命令输出 `cjdoc` 的绝对路径，第二条输出当前安装的版本。步骤 4 的打开命令以 Linux 为例，macOS 和 Windows 的替代命令写在该步骤里。

## 1. 创建静态库

选一个空工作目录，不要使用 cjdoc 源码目录，然后在其中执行：

```bash
cjpm init --name docdemo --path docdemo --type=static
cd docdemo
```

SDK 1.2.0 会创建 `cjpm.toml` 和 `src/`。这个库不依赖 stdx，把 `cjpm.toml` 完整替换为：

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
 * name 原样保留，不修剪空白；空字符串返回 `Hello, !`。
 *
 * @param name 要问候的名字，可以为空。
 * @return 格式为 `Hello, <name>!` 的字符串。
 * @example 问候仓颉 {must-pass run}
 * ```cangjie
 * println(greet("Cangjie"))
 * ```
 * ```output
 * Hello, Cangjie!
 * ```
 */
public func greet(name: String): String {
    return "Hello, ${name}!"
}

// 普通注释不会绑定为文档；此声明也不属于默认公开受众。
private func internalGreeting(): String {
    return "internal"
}
~~~

`/** ... */` 是文档注释，摘要、`@param`、`@return` 和 `@example` 都写在其中；普通 `//` 和 `/* ... */` 不会成为文档正文。

默认受众是 `external`，页面显示 `public` 和 `protected` 声明。`greet` 即使没有写文档注释也会出现在页面上，只是没有摘要、参数和返回说明；`internalGreeting` 是 `private` 声明，默认视图里没有它。`--audience package` 或 `--audience all` 可以扩大展示范围，这只改变文档视图，不是删除敏感源码的保护措施；发布前请检查你实际放进输出的文件。

## 3. 编译、核对示例并生成 HTML

仍在 `docdemo/` 根目录执行：

```bash
cjpm build
cjdoc check --project . --check-examples
cjdoc generate --project . --format html
```

第一条命令编译这个库。第二条命令编译注释里的 `@example` 代码，并运行标了 `run` 的示例，把实际输出与 `output` 围栏比较：一致时以退出码 0 结束，这里应匹配 `Hello, Cangjie!`。第三条命令读取同一份源码生成静态 HTML。

`generate` 默认不编译项目，也不运行示例，所以示例是否真的执行过只取决于第二条命令的结果。示例检查需要能建立进程资源限制的环境，限制和诊断码见[检查示例](../how-to/check-examples.md)。

省略 `--format` 时默认生成 JSON，不会产生 HTML。生成结果的入口是 `target/doc/html/index.html`。

## 4. 打开页面并阅读 `greet`

在项目根执行：

```bash
xdg-open target/doc/html/index.html
```

macOS 使用 `open target/doc/html/index.html`，Windows PowerShell 使用 `Start-Process .\target\doc\html\index.html`。

页面是纯静态文件，可以直接用 `file://` 打开，不需要启动服务器。从首页进入 `docdemo` 包和 `greet`，应能读到：

- 签名 `public func greet(name: String): String`；
- 参数 `name` 的说明；
- 返回值说明“格式为 `Hello, <name>!` 的字符串”；
- 示例及其 `Hello, Cangjie!` 输出。

默认公开视图里没有 `internalGreeting`；`greet` 之所以出现，是因为它是公开声明，与是否写了注释无关。页面只展示示例的内容和预期输出，不会标记它是否真的执行过；示例有没有实际运行，以第 3 步 `cjdoc check --check-examples` 的结果为准。

修改注释后重新执行生成命令，再刷新页面就能看到新内容。搜索、深链和 HTTP 发布见[生成与发布](../how-to/generate-and-publish.md)。

## 遇到问题怎么办

- **打不开页面或看不到更新**：确认打开的是当前项目下的 `target/doc/html/index.html`，不要停在 cjdoc 源码目录的 `target/`。
- **生成报项目根错误**：用 `pwd` 确认当前目录含 `cjpm.toml`，不要停在 `src/`；也可以从任意目录传入 `--project /你的项目根`。
- **示例检查报 `CJDOC3074`**：当前平台无法建立示例运行所需的地址空间限制，带 `run` 的示例被拒绝执行。这不影响 `generate` 生成 HTML，但示例没有实际运行；平台差异见[状态与限制](../reference/states-and-limits.md)。

## 下一步

- [加入首页、包概述和指南](add-guides.md)。
- [检查文档质量](../how-to/check-quality.md)。
- [注释语法参考](../reference/doc-comments.md)。
