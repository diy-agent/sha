# sha

纯 bash 的 diy 系列项目构建脚本：**函数名即命令，自注册，零执行发现**。

```bash
source ./sha.bash

build() { echo "build default"; }   # sha build
build.web() { echo "build web"; }   # sha build web  (. 是层级分隔符)
build__ios() { echo "build ios"; }  # sha build ios  (__ 也是层级分隔符)
run_tests() { echo "test"; }        # sha run_tests  (单个 _ 永不拆分)
_helper() { :; }                    # _ 开头不注册，私有函数

sha "$@" || exit $?   # 入口：贪心最长匹配，只执行最深命中的函数
```

规则：

- `.` 与 `__` 都是层级分隔符，可混用；单个 `_` 永不拆分（保护 snake_case）。
- 段不能为空（`a..b` / `.a` / `a__` 注册时报错）。
- 同一路径撞车（`a.b` 与 `a__b`）→ 注册报错，绝不静默覆盖。
- 私有前缀不注册：`_*` `fn_*` `sha`/`sha__*`/`sha_*`/`sha.*`（`_sha_cmd_exclude` 可改）。
- `root()` 存在时，`sha` 无参执行它；否则打印 help。
- `-h/--help` 可出现在任何层级，打印该层 help。
- 退出码：`0` 成功，`1` 未知命令/注册失败，`3` 纯分组缺子命令。

附带好处：带 `.` 的函数名永远撞不上系统命令（命令名里不能有 `.`）。

* 核心：`sha.bash`
* 样式：`sha_style.bash`
* 测试：`test_sha.bash` + `unit_test_framework.bash`（`bash test_sha.bash`）
* 范例：`examples/`（`bash examples/01-basic.bash --help` 起手）

要求：`Bash 4.4+`（依赖关联数组、nameref）。
