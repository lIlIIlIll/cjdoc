# 复用输出目录并管理源码缓存

重复生成到同一个目录时只替换 cjdoc 自己登记的文件，你自己放进去的内容保持不变；输出被占用时换一个独立目录拿到可用产物，源码缓存的位置也在这里调整。

## 前提条件

- 已完成[生成第一个站点](../tutorials/first-site.md)，命令在 `docdemo/` 项目根运行。
- 当前终端能运行 `cjdoc`，仓颉 SDK 环境可用。
- 本页命令使用 Bash。
- 输出路径要么尚不存在，要么是 cjdoc 先前生成的输出根。

## 1. 反复生成到同一目录

定义一次输出目录，后续命令沿用：

```bash
OUT=target/doc-site
cjdoc generate --project . --format html --output "$OUT"
```

**预期结果**：打印 `generated target/doc-site`，退出码 `0`；`$OUT/html/index.html` 可以打开，`$OUT/.cjdoc-output.json` 记录 cjdoc 管理的相对路径和摘要。

换成 JSON 格式再次生成，不必换目录：

```bash
cjdoc generate --project . --format json --output "$OUT"
```

**预期结果**：目录里出现 `docs.json`；上次生成的 `html/` 文件已被移除，因为这次不再生成 HTML。你自己放进 `$OUT` 的文件（例如 `notes.txt`）原样保留。

改回 HTML 就重新得到可发布站点：

```bash
cjdoc generate --project . --format html --output "$OUT"
```

发布时只上传站点目录，例如 `$OUT/html/` 的完整内容。`docs.json`、`api-surface/` 和 `coverage/` 是给后续工具读取的产物，不放进站点根。

## 2. 处理输出冲突

目录不是 cjdoc 生成的，或已登记的产物被手工改过时，生成会拒绝写入。先看是哪一种：

| 现象 | 含义 | 处理 |
|---|---|---|
| 退出码 `2`，`error: bounded read could not access file: '<目录>/.cjdoc-output.json'` | `--output` 指向一个已存在但不是 cjdoc 生成的目录 | 换一个尚不存在的目录；先手工创建空目录也会得到同样结果 |
| 退出码 `2`，`error: owned output artifact 'html/style.css' was modified; use --force-owned to replace it` | 你改过 cjdoc 登记过的文件 | 换新目录保留旧内容，或确认可以丢弃修改后加 `--force-owned` |

确认不再需要手工修改后，让 cjdoc 用本次内容替换：

```bash
cjdoc generate --project . --format html --output "$OUT" --force-owned
```

**预期结果**：打印 `generated target/doc-site`，退出码 `0`，被改过的登记文件恢复为生成内容。

`--force-owned` 只放宽两类检查：已登记文件被手工修改，以及本次产物需要的普通子目录已经存在。它不会接管未登记的产物同名文件、其它未知内容、锁状态或事务状态。

## 3. 把源码缓存放到别处

源码缓存默认在 `<项目>/target/cjdoc/cache/source-v11`。用 `--cache-dir` 改位置，用 `--no-cache` 关闭某次扫描的缓存读写：

```bash
cjdoc generate --project . --format html --output "$OUT" --cache-dir .cache/cjdoc-source
cjdoc generate --project . --format html --output "$OUT" --no-cache
```

**预期结果**：第一条命令在 `.cache/cjdoc-source` 下建立缓存；第二条不读写缓存。两个选项同时出现时，以最后一个为准。

输出根与源码缓存不能重叠或互相包含：

```bash
cjdoc generate --project . --format html --output "$OUT" --cache-dir "$OUT/cache"
```

**预期结果**：写入前即以退出码 `2` 拒绝，提示形如 `output directory '/…/target/doc-site' and source cache directory '/…/target/doc-site/cache' overlap`。把 `--cache-dir` 移到输出根之外即可。

缓存只用于源码分析：`render` 读取已保存的 Doc IR，不扫描源码，也不使用源码缓存。单个源码缓存最多 64 MiB、100,000 个条目，超限或内容无效时 cjdoc 会拒绝或重建；缓存键包含源码内容、路径和工具链信息，SDK 变化后旧条目可能不命中。`--jobs` 控制扫描并行度，取值 `1..64`、默认 `1`；内存或磁盘紧张时保持较低值，并行不会扩大总扫描预算，`--no-cache` 也不会解除源码扫描自身的上限。

## 输出仍被锁定时怎么办

同一父目录下的输出根共用一把父目录锁，即使输出根名称不同也会互相阻塞。锁定期间同父目录下的其它生成会以退出码 `2` 结束，提示：

- `output directory '<路径>' is locked by process <pid>`：另一个生成或预览仍在写同一父目录。并发执行多个 `generate` 时，除先取得锁的那个之外都会看到这条提示。
- `unable to verify output lock owner process <pid>; refusing unsafe recovery`：cjdoc 无法确认旧锁可以安全回收。用系统工具看不到 cjdoc 进程也不代表生成器已经验证可以恢复；换同一父目录下的另一个输出根或加 `--force-owned` 都不会解除这个阻塞。

先确认哪个进程还在写：等它结束；预览要在它的终端按 `Ctrl+C` 停止，然后重试原命令。

不要删除锁目录，不要改写 `owner.json`，也不要手工改写 `.cjdoc-output.json`。需要立刻拿到一份产物时，在与旧输出、旧事务和缓存都不重叠的新父目录里生成：

```bash
mkdir -p "$HOME/.cache/cjdoc"
RECOVERY_PARENT="$(mktemp -d "$HOME/.cache/cjdoc/recovery.XXXXXX")"
cjdoc generate --project . --format html --no-cache \
  --output "$RECOVERY_PARENT/site"
xdg-open "$RECOVERY_PARENT/site/html/index.html"
```

macOS 用 `open`，Windows PowerShell 用 `Start-Process` 打开同一路径。

**预期结果**：打印 `generated …/site`，退出码 `0`，`$RECOVERY_PARENT/site/html/index.html` 可正常阅读。这只是一份独立的完整产物，不会修复或接管旧输出；旧输出、旧锁和事务状态全部保持原样，手工删锁不是受支持的恢复方式。

## 失败时怎么办

| 现象 | 原因 | 处理 |
|---|---|---|
| `error: … is locked by process <pid>` | 同父目录下还有生成或预览在运行 | 等它结束，或在预览终端按 `Ctrl+C`，再重试 |
| `error: unable to verify output lock owner process <pid>; refusing unsafe recovery` | 旧锁的属主进程状态无法验证 | 换一个不重叠的新父目录生成独立产物，见上一节 |
| `error: owned output artifact '<相对路径>' was modified; use --force-owned to replace it` | 登记过的产物被手工改动 | 换新目录，或确认可丢弃改动后加 `--force-owned` |
| 提示找不到 `.cjdoc-output.json` | 输出目录存在但不是 cjdoc 生成的 | 换尚不存在的目录 |
| `error: output directory '…' and source cache directory '…' overlap` | 缓存落在输出根内或反之 | 把 `--cache-dir` 移到输出根之外 |

输出根、缓存、事务恢复和 `--force-owned` 的完整约束见[产物参考](../reference/artifacts.md)和[CLI 参考](../reference/cli.md)。

## 下一步

- [生成并发布文档](generate-and-publish.md)：选择发布格式并上传完整站点。
- [按症状排查故障](troubleshoot.md)：定位项目、诊断和预览问题。
- [本地预览](preview.md)：边改注释边查看页面。
