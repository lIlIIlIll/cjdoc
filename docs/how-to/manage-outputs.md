# 复用输出目录并管理源码缓存

重复生成到同一个目录时，cjdoc 只替换自己管理的文件，你在目录里放的其它内容会保留。本页说明怎样重复生成和发布、遇到冲突时怎么选，以及输出被锁住时怎样拿到一份可用的新产物。源码缓存的位置也在本页调整。

## 前提

- 已完成[首次生成教程](../tutorials/first-site.md)，命令在 `docdemo/` 项目根运行。
- 已安装 `cjdoc`，仓颉 SDK 环境在当前终端可用。
- 本页命令使用 Bash。
- 准备一个新的输出路径。首次生成时让 cjdoc 创建它；如果目录已经存在，它必须是 cjdoc 先前生成的输出。

## 重复生成到同一目录

先选择输出目录并生成 HTML。`OUT` 只在这里定义一次，你可以换成自己的路径；后面所有命令都沿用这个值：

```bash
OUT=target/doc-site
cjdoc generate --project . --format html --output "$OUT"
```

浏览器打开 `"$OUT/html/index.html"` 应看到 `docdemo` 的页面。重复生成时沿用同一个 `$OUT`：下一次生成会替换 cjdoc 上次登记的产物，并移除本次不再生成的已登记文件。例如改用 JSON 格式：

```bash
cjdoc generate --project . --format json --output "$OUT"
```

现在目录里是 `docs.json`；上次生成的 `html/` 文件已被移除，因为这次不再生成 HTML。你自己放进 `$OUT` 的其它文件不受影响，保持原样。目录根的 `.cjdoc-output.json` 记录 cjdoc 管理了哪些相对路径和摘要，不要手工编辑。

发布时只上传生成的站点目录，例如 `$OUT/html/` 的完整内容；`docs.json`、`api-surface/` 和 `coverage/` 是给后续工具读取的产物，不放进站点根。改回 HTML 即可重新得到可发布站点：

```bash
cjdoc generate --project . --format html --output "$OUT"
```

## 处理输出冲突

如果 `--output` 指向已经存在、但不是 cjdoc 生成的目录，生成会拒绝写入，退出码为 `2`。换一个尚不存在的目录，或先确认那个目录里的内容可以另外保存。

如果目录是 cjdoc 生成的，但你手工改过其中某个产物文件，下一次生成会拒绝覆盖，并指出被修改的文件。这时有两个选择：

- 换一个新的输出目录，保留旧目录里的手工内容。
- 确认不再需要那些手工修改后，让 cjdoc 用这次生成的内容替换它：

```bash
cjdoc generate --project . --format html --output "$OUT" --force-owned
```

`--force-owned` 只放宽两类检查：已登记文件被手工修改，以及本次产物需要的普通子目录已经存在。未登记的产物同名文件、其它未知内容、锁状态和事务状态都不会因此被接管。不要手工编辑生成目录里的文件，也不要在生成过程中删除锁。

## 把源码缓存放到别处

源码缓存默认位于 `<项目>/target/cjdoc/cache/source-v11`。用 `--cache-dir` 改位置，用 `--no-cache` 关闭某次源码扫描的缓存读写：

```bash
cjdoc generate --project . --format html --output "$OUT" --cache-dir .cache/cjdoc-source
cjdoc generate --project . --format html --output "$OUT" --no-cache
```

输出根与源码缓存不能重叠或互相包含，缓存也不能落在输出根的父目录锁和事务状态路径上。下面的组合会在写入前以路径错误退出码 `2` 被拒绝：

```bash
cjdoc generate --project . --format html --output "$OUT" --cache-dir "$OUT/cache"
```

提示类似 `output directory '...' and source cache directory '...' overlap`。把 `--cache-dir` 移到输出根之外即可。`--cache-dir` 与 `--no-cache` 同时出现时，以最后一个为准。

缓存只用于源码分析。`render` 读取已保存的 Doc IR，不扫描源码，也不使用源码缓存。单个源码缓存最多 64 MiB、100,000 个条目，超限或内容无效时 cjdoc 会拒绝或重建；缓存键包含源码内容、路径和工具链信息，SDK 变化后旧条目可能不会命中。`--jobs` 控制扫描并行度，取值范围 `1..64`，默认 `1`；内存或磁盘紧张时保持较低值，并行不会扩大总的扫描预算，`--no-cache` 也不会解除源码扫描自身的上限。

## 输出仍被锁定时怎么办

同一父目录下的输出根共用一把父目录锁，即使输出根名称不同，也会互相阻塞。看到下面的提示时，先确认哪个进程还在写：

- `output directory '...' is locked by process <pid>`：另一个生成或预览仍在运行。等它结束；预览要在它的终端按 `Ctrl+C` 停止，然后重试。
- `unable to verify output lock owner process <pid>; refusing unsafe recovery`：cjdoc 无法确认旧锁可以安全回收。用系统工具看不到 cjdoc 进程，也不代表生成器已经验证可以恢复；换同一父目录下的另一个输出根或加 `--force-owned` 都不会解除这个阻塞。

不要删除锁目录，不要改写 `owner.json`，也不要手工改写 `.cjdoc-output.json`。需要继续生成时，选一个与旧输出、旧事务和缓存都不重叠的新父目录。下面在磁盘上创建本次专用目录，再把新站点生成到它的 `site` 子目录：

```bash
mkdir -p "$HOME/.cache/cjdoc"
RECOVERY_PARENT="$(mktemp -d "$HOME/.cache/cjdoc/recovery.XXXXXX")"
cjdoc generate --project . --format html --no-cache \
  --output "$RECOVERY_PARENT/site"
xdg-open "$RECOVERY_PARENT/site/html/index.html"
```

macOS 用 `open`，Windows PowerShell 用 `Start-Process` 打开同一路径。新入口是 `$RECOVERY_PARENT/site/html/index.html`。

这只是一份独立的完整产物，不会修复或接管旧输出。旧输出、旧锁和事务状态全部保持原样；手工删锁不是受支持的恢复方式。输出根、缓存、事务恢复和 `--force-owned` 的完整约束见[产物参考](../reference/artifacts.md)和[CLI 参考](../reference/cli.md)。

## 下一步

- [生成并发布文档](generate-and-publish.md)：选择发布格式并上传完整站点。
- [按症状排查故障](troubleshoot.md)：定位项目、诊断和预览问题。
- [本地预览](preview.md)：边改注释边查看页面。
