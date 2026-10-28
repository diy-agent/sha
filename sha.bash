#!/usr/bin/env bash

# sha.bash 对 bash 环境的影响 (默认全部关闭, 按需开启):
#   - SHA_DEBUG=1 才挂 trap "_sha_on_error" ERR (打印调用栈)
# 最低版本: Bash 4.4+ (依赖关联数组、nameref、mapfile)


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

##################################################################################################
### sha 内部工具函数
##################################################################################################

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
        echo "用法: _sha_clear_associative_array <关联数组名称>" >&2 # _sha_clear_associative_array 获取当前函数名
        echo "示例: _sha_clear_associative_array my_data_array" >&2
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







##################################################################################################
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

_sha_help() { # $1=路径 ("" 为根)
  local path=$1 prefix key seg desc
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
    desc=""
    if declare -p _SHA_DESC >/dev/null 2>&1; then desc=${_SHA_DESC[$prefix$seg]:-}; fi
    if [[ -n "${_SHA_PARENT[$prefix$seg]+x}" ]]; then
      printf '  %s/%s\n' "$seg" "${desc:+  $desc}"
    else
      printf '  %s%s\n' "$seg" "${desc:+  $desc}"
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
    case $1 in -h|--help)
      if [[ -n $path ]] && declare -F _sha_opt_print_help >/dev/null 2>&1 \
        && _sha_opt_has_help "$path" 2>/dev/null; then
        _sha_opt_print_help "$path"; return 0
      fi
      _sha_help "$path"; return 0;;
    esac
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
  local fn=${_SHA_FUNC[$path]}
  # option 层预扫: 余下参数在 -- 之前出现 -h/--help 即打完整 help，不进函数
  if declare -F _sha_opt_pre_scan >/dev/null 2>&1 && _sha_opt_pre_scan "$path" "$@"; then
    return 0
  fi
  "$fn" "$@"
}




#######################################
## 入口
#######################################
# trap ERR 会给每条命令加钩子, Windows 下有可感知的开销,
# 默认关闭, 仅在 SHA_DEBUG=1 时开启出错堆栈。
if [[ "${SHA_DEBUG:-0}" == "1" ]]; then
  trap "_sha_on_error" ERR
fi
