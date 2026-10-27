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

# 所有找到的子命令列表，不清理，用于每次注册子命令时判断是否为新命令，key是函数名，value是函数内容
declare -A _sha_all_registerd_cmds
# 当前命令子命令列表,每次进入新的命令层级，会清空置换为当前命令的children，key是函数名，value是函数内容
declare -A _sha_current_cmd_children
# 当前命令链, 比如执行docker container ls时，解析到最后一个ls时的命令链是：_sha_cmd_chain=(docker container ls)
declare _sha_cmd_chain=()
declare _sha_cmd_exclude=("_*" "fn_*" "sha") # 示例前缀数组
# 函数体比对用的临时文件 (declare -f 重定向到此, 避免 $(...) fork; 见 _sha_register_children_cmds)
_sha_dump_file="${TMPDIR:-/tmp}/sha_dump_${BASHPID:-$$}"

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

# 测试/复用入口: 重置 sha 全局注册状态, 使同进程内可多次独立运行。
# 子 shell ( ... ) 只能隔离变量修改, 但函数定义在父 shell 已存在时会污染跨用例;
# 因此每个用例先 unset 上个用例的 fixture 函数, 再 _sha_reset, 即可同进程隔离,
# 无需每次 bash -c 起新进程 (Windows 下新进程极慢)。
_sha_reset() {
  _sha_clear_associative_array _sha_all_registerd_cmds >/dev/null 2>&1 || true
  _sha_clear_associative_array _sha_current_cmd_children >/dev/null 2>&1 || true
  _sha_cmd_chain=()
}




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



# Usage: _sha_register_children_cmds <cmd_level>
# ensure all cmd register
# root cmd_level is "/"
_sha_register_children_cmds() {
  local next_cmd="$1"

  _sha_cmd_chain+=("$next_cmd")

  # 每次清空，避免重复注册，目前的简化模型，只注册当前层级命令，不注册子命令
  declare -A new_children
  local func_name func_content
  while IFS=$'\n' read -r func_name; do

    # check func_name
    case "$func_name" in
        */*)  _sha_log ERROR "function name $func_name() can not contains '/' " >&2
              return 1 ;;
        # 添加其他想处理的函数名
    esac

    # NOTE: 刻意不用 func_content=$(declare -f ...) , $(...) 每次 fork 子进程,
    # N 个函数 = N 次 fork, Windows Git Bash 下慢 10~50 倍。
    # 改用内建重定向 + $(<file) (bash 对 $(<file) 有免 fork 优化), 全程零 fork。
    declare -f "$func_name" >"$_sha_dump_file"
    func_content=$(<"$_sha_dump_file")

    # 暂时关闭系统命令检测，等回头做成一个options, 严格模式
    # if [[ -v _sha_sys_commands["$func_name"] ]]; then
    #   echo  "ERROR: function '$func_name' 和os系统命令或alias重名, 请检查这个函数:"
    #   echo "$func_content"
    #   exit 1;
    # fi
    
    # 新增的cmd才是下一级的cmd
    # 父节点的子命令中可能和当前节点子命令同名
    # 判断依据为：只要当前节点识别出的函数与老的不同即认为是当前节点的子命令：
    # 1. 父节点没有注册过的
    # 2. 父节点注册过同名的，但内容不一样的
    if [[ "${_sha_all_registerd_cmds["$func_name"]}" == "$func_content"  ]]; then
      continue;
    fi
    
    # 排除掉某些前缀
    local exclude
    local is_excluded=false
    for exclude in "${_sha_cmd_exclude[@]}" ;do
      # 只要匹配一个非cmd前缀，就不注册cmd
      # shellcheck disable=SC2053
      # glob匹配
      if [[ "$func_name" = $exclude ]]; then
        is_excluded=true
        break;
      fi
    done

    if $is_excluded ; then
       continue 
    fi

    new_children["$func_name"]="$func_content"

  # 获取所有函数名输入到while循环里
  # < <(...) 将管道 compgen -A function 的输出作为 while read 的标准输入
  # compgen -A function比declare -F都是bash的内置函数，但declare -F在各版本间输出有变化所以不用
  done < <(compgen -A function)

  # 填充为下一级命令列表
  # 设置下一级的命令列表前先清空上一级列表
  _sha_clear_associative_array _sha_current_cmd_children
  # "${!new_children[@]}" 会扩展为关联数组的所有键的列表
  for key in "${!new_children[@]}"; do
      _sha_all_registerd_cmds["$key"]="${new_children["$key"]}"
      _sha_current_cmd_children["$key"]="${new_children["$key"]}"
  done  

}

_sha_help() {
  echo
  echo "${BASH_SOURCE[-1]} help:"
  echo
  echo "
Available Commands:"

  for key in "${!_sha_current_cmd_children[@]}"; do
      echo "  $key"
  done  
  echo
}

_sha_is_leaf_cmd() {
  if [[ "${#_sha_current_cmd_children[@]}" == "0" ]]; then
    return 0;
  fi
  return 1;
}




_sha() {
  local cmd="$1"
  # echo "_sha(): args:[$*] , current_cmds:[${_sha_all_registerd_cmds[*]}]"
  shift

  # 非法命令: 用 return 而不用 exit, sha.bash 是被 source 的库,
  # 不能替调用方决定进程生死; 调用方入口写 sha "$@" || exit $? 即可保持旧行为。
  # 退出码: 1 = 未知命令, 3 = 父命令缺子命令
  if [[  "${_sha_current_cmd_children[$cmd]}" == "" ]]; then
    echo  "ERROR: unknown command $cmd, 请使用 './sha --help' 查看可用的命令。 "
    return 1;
  fi
  
  # 执行当前命令后，再注册当前命令的子命令
  "$cmd" "$@"
  _sha_register_children_cmds "$cmd"

  # 根命令本身就是leaf，返回即可
  if _sha_is_leaf_cmd; then
    return 0;
  fi

  # not leaf cmd, no args, help
  if (( $#==0 )); then
    _sha_help
    echo "当前为父命令($cmd), 请使用子命令, 例如: ${BASH_SOURCE[-1]} <cmd> [args]"
    return 3;
  fi

  # 后面还有参数,递归处理
  _sha "$@"
}

sha() {
  # 总入口每次重置注册表: 同一进程调多次 sha 时, 第二次的函数体与已记录的相同,
  # diff 会得到空集并误判为叶子命令 (静默 return 0)。重置后每次都做全新发现,
  # 行为与全新进程一致。_sha_reset 是纯内建操作, 约 1ms, 无 fork。
  _sha_reset
  _sha_register_children_cmds "/"

  # 根命令本身就是leaf，返回即可
  if _sha_is_leaf_cmd; then
    return 0;
  fi

  # not leaf cmd, no args, help
  if (( $#==0 )); then
    _sha_help
    echo "当前为根命令, 请使用子命令, 例如: ${BASH_SOURCE[-1]} <cmd> [args]"
    return 3;
  fi
  # not leaf cmd, has args, process args
  _sha "$@"
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
