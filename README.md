# sha

纯 bash 的 diy 系列项目构建脚本：嵌套函数即子命令。

```bash
source ./sha.bash

build() {
  build_web() { echo "build web"; }
}
sha "$@"
```

* 核心：`sha.bash`
* 样式：`sha_style.bash`
* 测试：`test_sha.bash` + `unit_test_framework.bash`
