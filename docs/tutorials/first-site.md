# 从空目录生成第一个 API 站点

用一个没有外部依赖的静态库 `docdemo`，完成写注释、编译、生成和阅读。后续[加入指南](add-guides.md)和[发布中英文](publish-languages.md)继续使用这个目录。

## 前提与起点

先完成[当前源码安装](../getting-started/install.md)，在同一终端保留 SDK 环境。`cjc -v`、`cjpm -v` 应为 1.2.0，`command -v cjdoc` 应指向你刚安装的工具。起点是你选择的一个空工作目录，**不是 cjdoc 源码目录**。下文 Bash 命令适用于 Linux；系统打开方式见第 4 步。

## 1. 创建静态库

在空工作目录执行：

```bash
cjpm init --name docdemo --path docdemo --type=static
cd docdemo
```

SDK 1.2.0 会创建 `cjpm.toml` 和空的 `src/`，不会替你编写 API。将 `cjpm.toml` 完整替换为：

```toml
[package]
name = "docdemo"
version = "0.1.0"
cjc-version = "1.2.0"
output-type = "static"

[dependencies]
```

这个库不依赖 stdx。不要复制 cjdoc 生成器自己的链接选项。

## 2. 写一个真实 API

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

`/** ... */` 是文档注释；普通 `//`、`/* ... */` 不会成为文档正文。默认展示 `public` 和 `protected` 声明，未写文档注释的公开声明仍会出现，但没有摘要、参数说明等作者内容。`--audience` 是展示选择，**不是删除私有源码信息的隐私过滤器**；公开前检查你实际发布的文件。

## 3. 编译、检查示例并生成

仍在 `docdemo/` 根目录执行：

```bash
cjpm build
cjdoc check --project . --check-examples
cjdoc generate --project . --format html
```

库应编译通过；第二条命令实际编译并运行注释示例，核对输出 `Hello, Cangjie!`，成功退出码为 0。示例检查需要当前 `cjc` 和受支持的进程资源限制环境，详见[检查示例](../how-to/check-examples.md)。普通 `generate` 默认不编译被扫描项目，也不运行示例。

本教程的示例运行判据针对 Linux。当前 macOS 环境若无法建立所需地址空间限制，会以 `CJDOC3074` 拒绝运行用户代码；这不妨碍第三条命令生成静态页面，也不能记作示例运行通过。Windows 使用自身的 Job 内存限制，本轮未实操。

生成结果的入口是 `target/doc/html/index.html`。省略 `--format` 时默认生成 JSON，不会产生 HTML。项目根错误时，检查 `pwd` 和 `cjpm.toml`；也可以从其他目录传入 `--project /你选择的项目根`，不要把 `src/` 当项目根。

## 4. 打开并确认内容

Linux 在项目根执行：

```bash
xdg-open target/doc/html/index.html
```

macOS 对应 `open target/doc/html/index.html`；Windows PowerShell 对应 `Start-Process .\target\doc\html\index.html`。本轮 Linux 实操，后两者仅静态核对。

在浏览器进入 `docdemo` 包，找到 `greet`，确认签名 `public func greet(name: String): String`、参数 `name`、返回说明与示例输出均可读。`internalGreeting` 不应出现在默认公开 API 列表。页面可用 `file://` 直接打开，不需要服务器。搜索、深链、HTTP 发布见[生成与发布](../how-to/generate-and-publish.md)。

修改注释后重新运行生成命令，再刷新页面。若你看不到更新，先核对浏览器打开的文件是否属于这个项目，而不是 cjdoc 源码根的 `target/`。

## 下一步

- [加入首页、包概述和指南](add-guides.md)。
- [检查文档质量](../how-to/check-quality.md)。
- [注释语法参考](../reference/doc-comments.md)。
