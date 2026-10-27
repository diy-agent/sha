#!/usr/bin/env bash
set -o errtrace  # -E trap inherited in sub script
set -o errexit   # -e
set -o functrace # -T If set, any trap on DEBUG and RETURN are inherited by shell functions
set -o pipefail  # default pipeline status==last command status, If set, status=any command fail
#set -o nounset # -u: 当尝试使用未定义的变量时，立即报错并退出脚本。这有助于防止因变量拼写错误或未初始化导致的意外行为。
                #  don't use it ,it is crazy,
                #   1.bash version is diff Behavior
                #   2.we need like this: ${arr[@]+"${arr[@]}"}
                #   3.影响使用此lib的脚本

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck disable=SC1091
source "$TEST_DIR/unit_test_framework.bash"
# shellcheck disable=SC1091
source "$TEST_DIR/sha.bash"

# 同进程隔离运行一次 sha 调用:
#   函数定义和 _sha_* 全局注册表修改都在 $(...) 命令替换的子 shell 里, 不出逃,
#   父进程状态永远干净, 用例之间天然隔离, 无需 bash -c 起新进程。
#   (sha 已改 exit→return, 无需再包一层子 shell 接退出; $(...) 本身就是一次 fork)
# 用法: sha_run <fixture_setup_func> <cmd...> -- fixture 里只定义命令函数
#   输出: 被测命令的 stdout (stderr 重定向到 stdout, 方便断言 help/报错)
#   返回码: 0 成功, 1 未知命令, 3 父命令缺子命令
sha_run() { "$@" 2>&1; }

# --- fixture: 各用例的命令定义, 只定义函数, 不执行 ---

fixture_simple() {
  a() { echo "a"; }
  b() { echo "b"; }
  sha "$@"
}

fixture_sub() {
  a() { echo "a"; }
  b() {
    b1() { echo "b/b1"; }
    b2() { echo "b/b2"; }
  }
  sha "$@"
}

fixture_dup() {
  aaa() { echo "aaa"; }
  bbb() {
    aaa() { echo "bbb/aaa"; }
    bbb() { echo "bbb/bbb"; }
  }
  sha "$@"
}


# 所有函数名都能正确识别，不漏一个
test_all_funcname_is_ok() {
  assert_equals "a" "$(sha_run fixture_simple a)"
  assert_equals "b" "$(sha_run fixture_simple b)"
}

test_sub_command() {
  assert_equals "a" "$(sha_run fixture_sub a)"
  assert_equals "b/b1" "$(sha_run fixture_sub b b1)"
  assert_equals "b/b2" "$(sha_run fixture_sub b b2)"
}

# 内外命令有重名，进入一级命令后正确识别
test_unknown_command_returns_1() {
  local status=0
  sha_run fixture_simple no_such_cmd >/dev/null 2>&1 || status=$?
  assert_equals "1" "$status"
  assert_contains "unknown command" "$(sha_run fixture_simple no_such_cmd)"
}

test_parent_without_subcommand_returns_3() {
  local status=0
  sha_run fixture_sub b >/dev/null 2>&1 || status=$?
  assert_equals "3" "$status"
  status=0
  sha_run fixture_dup >/dev/null 2>&1 || status=$?
  assert_equals "3" "$status"
}

test_duplicated_command() {
  assert_equals "aaa" "$(sha_run fixture_dup aaa)"

  assert_contains "help" "$(sha_run fixture_dup bbb)"
  assert_equals "bbb/aaa" "$(sha_run fixture_dup bbb aaa)" # bbb/aaa会覆盖掉外部的aaa
  assert_equals "bbb/bbb" "$(sha_run fixture_dup bbb bbb)"
}

test_array_regex_match() {
  # shellcheck disable=SC2034
  a=(apple orange banana)
  _sha_array_regex_match a "apple"
  _sha_array_regex_match a "na"
  _sha_array_regex_match a "o.*e"

  # shellcheck disable=SC2251
  ! _sha_array_regex_match a "abble"
  ! _sha_array_regex_match a "e o"
}

test_array_contains() {
  # shellcheck disable=SC2034
  a=(apple orange banana)
  _sha_array_contains a "apple"
  _sha_array_contains a "orange"
  _sha_array_contains a "banana"

  # shellcheck disable=SC2251
  ! _sha_array_contains a "pple"
  ! _sha_array_contains a "oran"
}

test_array_find_first_index() {
  # shellcheck disable=SC2034
  a=(apple orange banana)
  assert_equals 0  "$(_sha_array_find_first_index a "apple")"
  assert_equals 1  "$(_sha_array_find_first_index a "orange")"
  assert_equals 2  "$(_sha_array_find_first_index a "banana")"

  # shellcheck disable=SC2251
  ! _sha_array_find_first_index a "pple"
  ! _sha_array_find_first_index a "oran"
}



test_array_difference() {
  # shellcheck disable=SC2034
  a=(apple orange banana kiwi)
  b=(banana kiwi unkown)

  _sha_array_difference a b
  assert_equals "0" "$?"

  assert_equals "a"  "a"
}


run_tests
