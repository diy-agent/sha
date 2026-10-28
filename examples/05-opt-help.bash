#!/usr/bin/env bash
# 05-opt-help: option + help 结合
#
# 试：
#   bash examples/05-opt-help.bash --help
#     # 根树，build 后带 desc
#   bash examples/05-opt-help.bash build -h
#     # 完整 help：desc + usage + detail + options + global options，不进函数
#   bash examples/05-opt-help.bash build --mode fast -h
#     # -h 放选项后面同样生效（-- 之前预扫）
#   bash examples/05-opt-help.bash build --target linux --release --jobs 8 ./a ./b
#     # mode 必填，这里没给会报错，见下一条（成功示例见 ok 一节）
#   bash examples/05-opt-help.bash build --target linux --release
#     # ERROR: option [--mode] is required，rc=1
#   bash examples/05-opt-help.bash build --mode turbo
#     # ERROR: option [--mode] must be one of fast|safe, got [turbo]，rc=1
#   bash examples/05-opt-help.bash build --mode fast -- --help
#     # -- 之后全是位置参数：files=--help，rc=0

EXAMPLE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$EXAMPLE_DIR/../sha.bash"
# shellcheck disable=SC1091
source "$EXAMPLE_DIR/../sha_opt.bash"

sha.option "build" \
  "-t,--target:string=macos:目标平台" \
  "--mode:string![fast|safe]:运行模式" \
  "--release:bool:优化构建" \
  "--jobs:int=4:并行数" \
  "--src:list:源码目录(可重复)"
sha.desc "build" "构建包"
sha.usage "build" "sha build [-t T] --mode M [--release] [--jobs N] [files...]"
sha.detail "build" "备注：mode 必填；--target 缺席时取 macos。"
sha.option "build web" \
  "--target:string=macos:目标平台"
sha.desc "build web" "构建 web 包"
sha.usage "build web" "sha build web [--target T]"
sha.option "*" "--verbose:bool:详细输出"

build() {
  local target mode release jobs verbose
  local -a src=() files=()
  sha_opt_parse files "$@" || return $?
  echo "target=$target mode=$mode release=$release jobs=$jobs verbose=$verbose src=${src[*]} files=${files[*]}"
}

build.web() {
  local target verbose
  local -a files=()
  sha_opt_parse files "$@" || return $?
  echo "web target=$target verbose=$verbose files=${files[*]}"
}

sha "$@" || exit $?
