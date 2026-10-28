#!/usr/bin/env bash
# 05-opt-help: option + help 结合（sha.def 一次调用定义完一个命令的全部元数据）
#
# 试：
#   bash examples/05-opt-help.bash --help
#     # 根树，build 后带 desc
#   bash examples/05-opt-help.bash build -h
#     # 完整 help：desc + usage + detail + options + global options，不进函数
#   bash examples/05-opt-help.bash build --mode fast -h
#     # -h 放选项后面同样生效（-- 之前预扫）
#   bash examples/05-opt-help.bash build --mode fast --target linux --release --jobs 8 ./a ./b
#     # target=linux mode=fast release=1 jobs=8 files=./a ./b
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

sha.def "build" \
  --desc "构建包" \
  --usage "sha build [-t T] --mode M [--release] [--jobs N] [files...]" \
  --detail "备注：mode 必填；--target 缺席时取 macos。" \
  --opt "-t,--target:string=macos:目标平台" \
  --opt "--mode:string![fast|safe]:运行模式" \
  --opt "--release:bool:优化构建" \
  --opt "--jobs:int=4:并行数" \
  --opt "--src:list:源码目录(可重复)"
sha.def "build web" \
  --desc "构建 web 包" \
  --usage "sha build web [--target T]" \
  --opt "--target:string=macos:目标平台"
sha.def "*" \
  --opt "--verbose:bool:详细输出"

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
