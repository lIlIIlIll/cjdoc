# 边界与诊断 / Boundaries and diagnostics

此项目与入门库分开，用来观察错误写法在文档里的表现：
缺失引用、同名歧义、错误代码，以及没有可执行代码的说明。

- 生成文档不会执行这些示例；只有独立 `check-modes` 项目显式使用 `--check-examples`。
- 每条诊断都保留原生代码与源码范围，可直接从报告跳到对应行。
- 故意失败是展示内容，不计为通过。

This isolated project shows how documentation reports missing and ambiguous references alongside
invalid code and non-executable explanations. Documentation generation makes no execution claim.

查看原始 Doc IR，可追溯每一条原生诊断及其源码范围。
