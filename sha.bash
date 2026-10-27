#!/usr/bin/env bash

# sha.bash 对 bash 环境的影响 (默认全部关闭, 按需开启):
#   - SHA_DEBUG=1             才挂 trap "_sha_on_error" ERR (打印调用栈)
#   - SHA_CHECK_SYS_CONFLICT=1 才枚举系统命令做函数名冲突检查
#   - nullglob: source 时临时打开, 结束即恢复调用方原状, 不污染


# sha.bash消费者请选用以下关键参数，sha.bash默认不开启这些参数，尽量不影响bash默认环境
#set -o errtrace  # -E trap inherited in sub script
#set -o errexit   # -e
#set -o functrace # -T If set, any trap on DEBUG and RETURN are inherited by shell functions
#set -o pipefail  # default pipeline status==last command status, If set, status=any command fail
#set -o nounset # -u: 当尝试使用未定义的变量时，立即报错并退出脚本。这有助于防止因变量拼写错误或未初始化导致的意外行为。
                #  don't use it ,it is crazy, 
                #   1.bash version is diff Behavior 
                #   2.we need like this: ${arr[@]+"${arr[@]}"}
                #   3.影响使用此lib的脚本

# nullglob选项默认off时：
# -------------------------.bash
# bash-5.2$ a=(./no_exists_dir/*/sha)
# bash-5.2$ declare -p a
# declare -a a=([0]="./no_exists_dir/*/sha")
# -------------------------
# 没有匹配到任何文件时，包含字符串字面量，这不是我们要的
#
# 而打开nullglob后：
# -------------------------.bash
# shopt -s nullglob
# bash-5.2$ a=(./no_exists_dir/*/sha)
# bash-5.2$ declare -p a
# declare -a a=()
# -------------------------s
# 空数组!这是我们想要的
# 只在 source 期间临时打开, 结束后恢复调用方原状 (库不应改全局 shopt)
if shopt -q nullglob; then
  _sha_nullglob_was_on=1
else
  _sha_nullglob_was_on=0
  shopt -s nullglob
fi






_sha_real_path() {  [[ $1 = /* ]] && echo "$1" || echo "$PWD/${1#./}" ; }

# 自注册约定 (函数名即命令, 无需执行、无需声明):
#   build.web() / build__web()  →  sha build web      (. 与 __ 都是层级分隔符, 可混用)
#   run_tests()                 →  sha run_tests      (单个 _ 永不拆分, 保护 snake_case)
#   _foo / fn_x / sha...        →  私有, 不注册 (见 _sha_cmd_exclude)
# 规则:
#   段不能为空 (a..b / .a / a__ 注册时报错)
#   同一路径撞车 (a.b 与 a__b) → 注册报错, 逼你二选一, 绝不静默覆盖
#   附带好处: 带 . 的函数名永远撞不上系统命令 (命令名里不能有 .)
# 命令表: key=空格分隔路径 ("build web"), value=函数名 ("build.web")
declare -A _SHA_FUNC=()
# 纯分组表: 有子命令的路径 (即使它自己也有同名函数, 比如 build() + build.web())
declare -A _SHA_PARENT=()
declare _sha_cmd_exclude=("_*" "fn_*" "sha" "sha__*" "sha_*" "sha.*") # 私有前缀, 不注册为命令

# 系统命令列表, 用于判断我们的命令名是否和系统命令冲突
declare -A _sha_sys_commands

##################################################################################################
### 业务无关的common函数，比如数组、日志等
##################################################################################################

# replace $HOME with "~"
# Usage: _sha_pwd <path>
# Examples:  
#  _sha_pwd "/home/chen/git/note/"
#         ===> "~/git/note/"
_sha_pwd() {
  local _path="$1"
  printf "%s" "${_path/#$HOME/\~}" ; 
}

# Usage: _sha_log <log_level> <msg...>
# Examples: 
#   _sha_log ERROR "错误消息"
#
# log_level: DEBUG|INFO|ERROR|FATAL
_sha_log(){
  local level="$1"; shift
  # NOTE: 不用 $(date)/$( _sha_pwd), $(...) 每次 fork; 用内建 printf %T + 参数展开
  local ts
  # shellcheck disable=SC2183
  printf -v ts '%(%F %T)T' -1
  echo -e "$level $ts ${PWD/#$HOME/\~}\$ ${FUNCNAME[1]}() : $*" >&2
}

_sha_on_error() {
  local last_command="$BASH_COMMAND" # Bash 特有变量，显示出错的命令
  echo  "ERROR: 命令 '$last_command' 执行失败, trapped an error:, trace: ↓" 1>&2
  local i=0
  local stackInfo
  while true; do
    stackInfo=$(caller $i 2>&1 && true) && true
    if [[ $? != 0 ]]; then return 0; fi

    # 一行调用栈 '97 my_cmd ./note/sha'
    #    解析后 =>  行号no=97 , 报错的函数func=my_cmd , file=./note/sha
    local no func file
    IFS=' ' read -r no func file <<<"$stackInfo"

    # 打印出可读性强的信息:
    #    => ./note/sha:38 -> my_cmd
    # NOTE: 不用 $(_sha_real_path), 循环内每次 fork; 内联展开即可
    [[ $file = /* ]] || file="$PWD/${file#./}"
    printf "%s\n" "$file:$no -> $func" >&2

    i=$((i + 1))
  done
}

# 关联数组不像普通数组那样可以: a=() 清理，所以需要自己清理
# Usage: _sha_clear_associative_array <array_name>
_sha_clear_associative_array() {
    # --- 参数及错误检查 ---

    # 检查是否提供了恰好一个参数 (关联数组的名称)
    if [ "$#" -ne 1 ]; then
        echo "用法: ${func_name[0]} <关联数组名称>" >&2 # ${func_name[0]} 获取当前函数名
        echo "示例: ${func_name[0]} my_data_array" >&2
        return 1
    fi

    local array_name="$1" # 从第一个参数获取关联数组的名称

    # 使用 'declare -n' 创建一个名称引用 (nameref)
    # 这使得 'arr_ref' 成为一个指向由 $array_name 指定的实际关联数组的别名
    # 对 arr_ref 的任何操作都会直接作用于原始关联数组
    # requires Bash 4.3+
    # 注意: 刻意不用 declare -p | grep 做类型校验, 管道每次 fork 子进程,
    # 在 Windows Git Bash 下极慢; 调用方只传已知关联数组即可。
    declare -n arr_ref="$array_name" 2>/dev/null || {
         echo "错误: 变量 '$array_name' 不存在或不是一个已声明的关联数组。" >&2
         return 1
    }

    # 获取数组的所有键的列表，并循环遍历
    # "${!arr_ref[@]}" 通过名称引用获取原始关联数组的所有键
    for key in "${!arr_ref[@]}"; do
        # 使用 unset 命令删除当前键对应的元素
        # "arr_ref["$key"]" 通过名称引用访问原始关联数组的元素
        unset "arr_ref[$key]"
    done
}

# _sha_reset() 见下文 sha 命令实现区: _sha_reset() { _sha_register_all; }




# 用途：判断数组 array_name 是否包含精确字符串 search_string
# Useage：_sha_array_regex_match <array_name> <search_regex>
# 参数：
#   $1: 数组的名称
#   $2: 要搜索的字符串正则
# 返回值：
#   0 (成功): 如果找到精确匹配的元素
#   1 (失败): 如果没有找到匹配的元素
# 示例：
#  a=("apple" "banana" "cherry")
# _sha_array_regex_match a "banana" && echo "matched" || echo "not matched"
# _sha_array_regex_match a "ch.*y" && echo "matched" || echo "not matched"
_sha_array_regex_match() {
  local regex="$2"
  # 使用 'declare -n' 创建一个名称引用 (nameref)
  # 这使得 'arr_ref' 成为一个指向由 $array_name 指定的实际关联数组的别名
  # 对 arr_ref 的任何操作都会直接作用于原始关联数组
  # requires Bash 4.3+
  declare -n array_ref="$1"

  local element
  for element in "${array_ref[@]}"; do
    if [[ "${element}" =~ $regex ]]; then
      return 0 # 找到精确匹配
    fi
  done
  return 1 # 没有找到匹配
}

# _sha_array_find_first_index 
# 注意：此函数的功能是查找索引，而不是简单判断包含元素，但确实可以用于contains包含判断
# 
# Usage: _sha_array_find_first_index <array_name> <search_string>
# 用途：查找数组 array_name 中精确匹配字符串 str 的元素的索引
# 参数：
#   $1: 数组的名称 (不需要加 $)
#   $2: 要搜索的精确字符串
# 输出：
#   如果找到匹配的元素，则输出该元素的索引 (第一个匹配项的索引)
# 返回值：
#   0 (成功): 如果找到匹配的元素 (并输出了索引)
#   1 (失败): 如果没有找到匹配的元素
# 示例：
#   my_array=("apple" "banana" "cherry")
#   # 调用函数并捕获输出和返回值
#   index=$(_sha_array_find_first_index my_array "banana")
#   result=$?
#   if [[ "$result" -eq 0 ]]; then
#     echo "找到 'banana' 在索引: $index"
#   else
#     echo "未找到 'banana', 函数返回: $result"
#   fi
_sha_array_find_first_index() {
  local str="$2"
  # 使用 'declare -n' 创建一个名称引用 (nameref)
  # 这使得 'array_ref' 成为一个指向由 $array_name 指定的实际数组的别名
  # 对 array_ref 的任何操作都会直接作用于原始数组
  # requires Bash 4.3+
  declare -n array_ref="$1"

  local index # 用于循环的局部变量，表示数组索引

  # 遍历数组的所有索引
  # ${!array_ref[@]} 扩展为数组的所有索引
  for index in "${!array_ref[@]}"; do
    # 访问当前索引对应的元素，并与搜索字符串进行精确比较
    if [[ "${array_ref[index]}" == "$str" ]]; then
      echo "$index" # 找到匹配，输出索引
      return 0      # 返回成功
    fi
  done

  # 遍历完成，没有找到匹配
  # 注意：Bash 返回值通常是 0-255，返回 -1 是非标准的
  return 1
}


# 判断集合包含关系
# Usage: _sha_array_contains <array_name> <search_string>
# 用途：判断数组 array_name 是否包含精确字符串 search_string
# 函数：_sha_array_contains
# 用途：判断数组 array_name 是否包含精确字符串 search_string
# 参数：
#   $1: 数组的名称 (不需要加 $)
#   $2: 要搜索的精确字符串
# 输出：
#   无输出
# 返回值：
#   0 (成功): 如果找到精确匹配的元素
#   1 (失败): 如果没有找到匹配的元素
# 示例：
#   my_array=("apple" "banana" "cherry")
#   if _sha_array_contains my_array "banana"; then
#     echo "数组包含 'banana'"
#   fi
#   if ! _sha_array_contains my_array "date"; then
#     echo "数组不包含 'date'"
#   fi
_sha_array_contains() {
  local search_string="$2"
  # 使用 'declare -n' 创建一个名称引用 (nameref)
  # 这使得 'array_ref' 成为一个指向由 $array_name 指定的实际数组的别名
  # 对 array_ref 的任何操作都会直接作用于原始数组
  # requires Bash 4.3+
  declare -n array_ref="$1"

  local element # 用于循环的局部变量

  # 遍历数组的所有元素
  for element in "${array_ref[@]}"; do
    # 进行精确字符串比较
    if [[ "${element}" == "$search_string" ]]; then
      return 0 # 找到精确匹配
    fi
  done

  return 1 # 没有找到匹配
}
# 函数：_sha_array_difference
# 用途：输出数组 array1_name 中不包含在数组 array2_name 中的元素
# 参数：
#   $1: 第一个数组的名称 (不需要加 $)
#   $2: 第二个数组的名称 (不需要加 $)
# 输出：
#   将差集元素逐行输出到标准输出
# 返回值：
#   0 (成功): 函数执行完成
# 示例：
#   array1=("apple" "banana" "cherry" "date")
#   array2=("banana" "date" "fig")
#   echo "Array 1: ${array1[@]}"
#   echo "Array 2: ${array2[@]}"
#   echo "Difference (Array 1 - Array 2):"
#   _sha_array_difference array1 array2
#   # 预期输出:
#   # apple
#   # cherry
_sha_array_difference() {
  # 使用 declare -n 创建 nameref 变量
  # arr1 将引用传入的第一个数组 (名称为 $1 的数组)
  # arr2 将引用传入的第二个数组 (名称为 $2 的数组)
  declare -n arr1="$1"
  # shellcheck disable=SC2034
  declare -n arr2="$2"

  local element # 用于循环第一个数组的局部变量

  # 遍历第一个数组的所有元素 (单层循环)
  for element in "${arr1[@]}"; do
    # 如果 _sha_array_contains 返回非零状态 (即未找到)，则输出当前元素
    # 注意：即使 _sha_array_contains 返回 -1，其退出状态在 0-255 范围内是 255 (非零)
    if ! _sha_array_find_first_index arr2 "$element" > /dev/null; then
      echo "$element"
    fi
  done
  return 0
}

##################################################################################################
### 上面代码是业务无关的common函数，比如数组等
### 下面是sha命令的实现
##################################################################################################



# 全量静态注册: 扫一遍函数名, 按 . 与 __ 切出命令树, 全程只需一次 compgen, 零逐函数 fork。
# 同一进程调多次 sha 行为完全一致 (表每次重建), 不存在旧 diff 模型的状态残留问题。
# 退出码: 1 = 非法函数名/路径撞车/未知命令, 3 = 纯分组缺子命令
_sha_register_all() {
  # Bash 4.4 安全写法: 不用 arr=() 清空关联数组 (4.4 下属性保留行为存疑),
  # 走内建 unset 循环, 零 fork, 成本与 O(N) 重建相当。
  _sha_clear_associative_array _SHA_FUNC || return $?
  _sha_clear_associative_array _SHA_PARENT || return $?
  local fn p rest exclude skipped
  while IFS=$'\n' read -r fn; do
    skipped=false
    for exclude in "${_sha_cmd_exclude[@]}"; do
      # shellcheck disable=SC2053
      if [[ "$fn" == $exclude ]]; then skipped=true; break; fi
    done
    $skipped && continue

    # NOTE: 纯参数展开做映射, 不用 path=$(...) 捕获 (每次捕获=一次 fork, N 个函数=N 次 fork)。
    # 先 __ 再 . : __ 优先级高, a__b 与 a.b 都映射到 "a b" (撞车则报错, 见下)。
    p=${fn//__/ }
    p=${p//./ }
    if [[ -z "$p" || "$p" == ' '* || "$p" == *' ' || "$p" == *'  '* ]]; then
      echo "ERROR: 非法命令函数名 [$fn], 段不能为空 (如 .a / a..b / a__)" >&2
      return 1
    fi
    if [[ -n "${_SHA_FUNC[$p]+x}" && "${_SHA_FUNC[$p]}" != "$fn" ]]; then
      echo "ERROR: 命令 [$p] 撞车: [${_SHA_FUNC[$p]}] vs [$fn], . 与 __ 别混用, 二选一" >&2
      return 1
    fi
    _SHA_FUNC[$p]="$fn"
    rest=$p
    while [[ "$rest" == *' '* ]]; do rest=${rest% *}; _SHA_PARENT[$rest]=1; done
  done < <(compgen -A function)
}

# 测试/复用入口: 重建命令表 (现在 _sha_register_all 本身就是无状态重建, 这里只是别名)。
_sha_reset() { _sha_register_all; }

_sha_help() { # $1=路径 ("" 为根)
  local path=$1 prefix key seg
  if [[ -z "$path" ]]; then prefix=""; else prefix="$path "; fi
  echo
  echo "${BASH_SOURCE[-1]} help:"
  [[ -n "$path" ]] && echo "command: $path"
  echo
  echo "Available Commands:"
  local -A seen=()
  local k stripped
  for k in "${!_SHA_FUNC[@]}" "${!_SHA_PARENT[@]}"; do
    [[ "$k" == root ]] && continue
    if [[ -z "$path" ]]; then
      [[ "$k" == *' '* ]] && seg=${k%% *} || seg=$k
    else
      [[ "$k" == "$prefix"* ]] || continue
      stripped=${k#$prefix}
      [[ "$stripped" == *' '* ]] && seg=${stripped%% *} || seg=$stripped
    fi
    seen[$seg]=1
  done
  for seg in "${!seen[@]}"; do
    if [[ -n "${_SHA_PARENT[$prefix$seg]+x}" ]]; then
      printf '  %s/\n' "$seg"
    else
      printf '  %s\n' "$seg"
    fi
  done | sort
  echo
}

# 总入口 (public api)。用法见文件头自注册约定。
# 分发规则 (贪心最长匹配, 只执行最深命中的函数, 父级不顺带执行):
#   sha build web --target x → 命中 "build web", 余下参数全透给实现函数
#   sha build (build 是纯分组)  → 打印该组 help, return 3
#   sha build bad (build 是纯分组) → unknown command, return 1
#   sha (无参数) → root() 存在则执行, 否则根 help, return 3
#   退出码: 0 成功, 1 未知命令/注册失败, 3 缺子命令
sha() {
  _sha_register_all || return $?
  local path="" cand
  while (( $# > 0 )); do
    case $1 in -h|--help) _sha_help "$path"; return 0;; esac
    if [[ -z "$path" ]]; then cand=$1; else cand="$path $1"; fi
    if [[ -n "${_SHA_PARENT[$cand]+x}" || -n "${_SHA_FUNC[$cand]+x}" ]]; then
      path=$cand; shift
    else
      break
    fi
  done
  if [[ -z "$path" ]]; then
    if (( $# == 0 )); then
      if [[ -n "${_SHA_FUNC[root]+x}" ]]; then ${_SHA_FUNC[root]}; return $?; fi
      _sha_help ""; return 3
    fi
    echo "ERROR: unknown command [$1], 用 'sha --help' 查看可用命令" >&2
    return 1
  fi
  if [[ -z "${_SHA_FUNC[$path]+x}" ]]; then
    if (( $# == 0 )); then _sha_help "$path"; return 3; fi
    echo "ERROR: unknown command [$path $1], 用 'sha $path --help' 查看" >&2
    return 1
  fi
  # 用 return 而不用 exit: sha.bash 是被 source 的库, 不能替调用方决定进程生死。
  local fn=${_SHA_FUNC[$path]}; "$fn" "$@"
}


# Usage: _sha_register_sys_commands
# 用途：初始化系统命令列表 _sha_sys_commands
_sha_register_sys_commands() {
  # 所有命令列表, 用于判断我们的命令名是否和系统命令冲突
  local -a sys_cmds
  mapfile -t sys_cmds < <(compgen -c)

  local -a ignore_functions
  mapfile -t ignore_functions < <(compgen -A function)

  local -A ignore_functions_map
  local item
  for item in "${ignore_functions[@]}"; do
    ignore_functions_map["$item"]=1
  done


  local array_length=${#sys_cmds[*]}

  # 遍历 sys_cmds 数组，使用基于数字索引的循环
  # 这种方式假设数组是稠密的 (索引是连续的，没有空洞)
  for ((i=0; i<array_length; i++)); do
    item=${sys_cmds[$i]}
    # -v 检查键是否存在
    if [[ ! -v ignore_functions_map["$item"] ]]; then
      # 如果元素不存在于 ignore_functions_map 中，则将其作为键添加到 _sha_sys_commands 关联数组
      # 关联数组的值不重要，这里简单设为 1
      _sha_sys_commands[${item}]=1
    fi
  done
}


#######################################
## 入口
#######################################
# Windows(Git Bash/MSYS2)下说明:
# 1. compgen -c 会枚举 PATH 下数千个命令+逐个循环, 在 Windows fork 仿真下极慢,
#    所以默认关闭, 仅在 SHA_CHECK_SYS_CONFLICT=1 时才做系统命令冲突检查。
# 2. trap ERR 会给每条命令加钩子, Windows 下也有可感知的开销,
#    默认关闭, 仅在 SHA_DEBUG=1 时开启出错堆栈。
if [[ "${SHA_CHECK_SYS_CONFLICT:-0}" == "1" ]]; then
  _sha_register_sys_commands
fi
if [[ "${SHA_DEBUG:-0}" == "1" ]]; then
  trap "_sha_on_error" ERR
fi

# 恢复调用方的 nullglob 原状 (见文件头)
if [[ "${_sha_nullglob_was_on:-1}" == "0" ]]; then
  shopt -u nullglob
fi
unset _sha_nullglob_was_on
