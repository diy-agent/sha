# examples 使用说明
#
# 每个示例都是可直接执行的脚本，用法：
#
#   bash examples/01-basic.bash --help
#   bash examples/01-basic.bash build
#   bash examples/01-basic.bash build web --target macos
#
# 规则回顾（见 README.md）：
# - `.` 与 `__` 都是层级分隔符，可混用；单个 `_` 永不拆分
# - `_*` / `fn_*` / `sha*` 开头不注册（私有）
# - 贪心最长匹配，只执行最深命中的函数
# - 退出码：0 成功，1 未知命令/注册失败，3 纯分组缺子命令

- `01-basic.bash`：函数名即命令、私有函数、snake_case
- `02-subcommand.bash`：`.`/`__` 分层、父命令自己也有实现、参数透传
- `03-help-root-exitcode.bash`：`root()`、`-h/--help`、退出码 0/1/3
- `04-style.bash`：`sha_style.bash` 独立演示（注意：不要和 `sha.bash` 混 source）
- `05-opt-help.bash`：option + help 结合（`sha.option`/`sha.desc`/`sha.usage`/`sha.detail` + `sha_opt_parse`）
