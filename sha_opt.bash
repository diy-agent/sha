#!/usr/bin/env bash
#
# sha_opt.bash: option 定义 (sha.option)。解析 (sha_opt_parse) 后续实现。
#
# 规范 (PEG, 唯一正解, 与 test_sha_opt.bash 头部完全一致):
#   spec       <- opt-head ":" type ("=" default)? ("!")? enum-block? (":" help)?
#   opt-head   <- (short ",")? longopt
#   short      <- "-" [A-Za-z0-9]
#   longopt    <- "--" identifier
#   identifier <- [a-zA-Z][a-zA-Z0-9_-]*
#   type       <- "string" / "int" / "bool" / "list"
#   default    <- (!("!" / "[" / ":") .)+
#   enum-block <- "[" literal ("|" literal)* "]"
#   literal    <- (!( "|" / "]" / ":" ) .)+
#   help       <- .*
#
# PEG 之外的语义约束 (编号对应 test_sha_opt.bash):
#   长选项必须带 -- 前缀, 短选项必须配长选项 (S15); bool 不接受 =/!/枚举 (S16);
#   必填(!)不能同时有默认值 (S17); --help/-h 保留 (S20); 同表长名/短名不重复,
#   映射后变量撞车报错 (S19/S21); 默认值注册时校验 (类型/枚举归属, S23);
#   list 不接受默认值, 全局(*)只接受选填 (S24)。
#
# 存储 (供 sha_opt_parse 与 help 渲染消费, 测试可直接断言):
#   _SHA_OPT_TYPE["cmd|var"], _SHA_OPT_DEFAULT["cmd|var"], _SHA_OPT_HAS_DEFAULT,
#   _SHA_OPT_REQUIRED, _SHA_OPT_ENUM (原始 a|b), _SHA_OPT_HELP, _SHA_OPT_LONG,
#   _SHA_OPT_SHORT["cmd|short"] -> var, _SHA_OPT_ORDER["cmd"] -> "var var ..."

declare -A _SHA_OPT_TYPE=()
declare -A _SHA_OPT_LONG=()
declare -A _SHA_OPT_DEFAULT=()
declare -A _SHA_OPT_HAS_DEFAULT=()
declare -A _SHA_OPT_REQUIRED=()
declare -A _SHA_OPT_ENUM=()
declare -A _SHA_OPT_HELP=()
declare -A _SHA_OPT_SHORT=()   # "cmd|short" -> var
declare -A _SHA_OPT_SHORT_OF=() # "cmd|var" -> short (无则空)
declare -A _SHA_OPT_ORDER=()   # "cmd" -> "var var ..."
declare -A _SHA_OPT_ARGS=()      # "cmd" -> "NAME NAME ..." (位置参数，声明顺序)
declare -A _SHA_OPT_ARG_HELP=()  # "cmd|NAME" -> help
declare -A _SHA_OPT_ARG_REQ=()   # "cmd|NAME" -> 1 (必填)
declare -A _SHA_OPT_ARG_REST=()  # "cmd|NAME" -> 1 (variadic ...，吞掉剩余全部)

_sha_opt_error() { echo "ERROR: $*" >&2; return 1; }

# 命令路径规范化：与 sha.bash 自注册同一套映射（. 与 __ → 空格，单个 _ 不动）。
# 注册 (sha.option/sha.def/sha.desc/...) 与查找 (sha_opt_parse) 都走这里，所以
# "build web" / "build.web" / "build__web" 三种写法等价——调用者用什么分隔符都行。
# $1=原始路径, $2=输出变量名；归一化 + 严格校验，失败返回 1
_sha_opt_norm_cmd() {
  local p=$1
  p=${p//__/ }
  p=${p//./ }
  printf -v "$2" '%s' "$p"
}

_sha_opt_check_cmd() {
  local raw=$1 outvar=$2 norm=""
  _sha_opt_norm_cmd "$raw" norm
  if [[ -z $norm || $norm == ' '* || $norm == *' ' || $norm == *'  '* ]]; then
    _sha_opt_error "命令路径非法 [$raw]"
    return 1
  fi
  printf -v "$outvar" '%s' "$norm"
}

# 用法: sha.option "<cmd>" "<spec>..."
#   cmd: 命令路径 ("build web" / "build.web" / "build__web" 等价) 或 "*" (全局选项)
sha.option() {
  local raw=$1; shift
  local cmd=""
  _sha_opt_check_cmd "$raw" cmd || return $?
  local spec
  for spec in "$@"; do
    _sha_opt_add "$cmd" "$spec" || return $?
  done
}

_sha_opt_add() {
  local cmd=$1 spec=$2
  local head rest

  # opt-head ":" ... : head 永不含冒号, 按第一个冒号切
  case $spec in
    *:*)
      head=${spec%%:*}
      rest=${spec#*:}
      ;;
    *)
      _sha_opt_error "非法 option 定义 [$spec]，缺少 : 分隔"
      return $?
      ;;
  esac

  # --- opt-head: (short ",")? longopt ---
  local short="" long=""
  case $head in
    -*,--*)
      short=${head%%,*}
      long=${head#*,}
      ;;
    --*)
      long=$head
      ;;
    -*)
      _sha_opt_error "非法 option 定义 [$spec]，短选项必须与长选项连用，如 -t,--target"
      return $?
      ;;
    *)
      _sha_opt_error "非法 option 定义 [$spec]，长选项必须以 -- 开头"
      return $?
      ;;
  esac
  local re_short='^-[A-Za-z0-9]$' re_long='^--[A-Za-z][A-Za-z0-9_-]*$'
  if [[ -n $short && ! $short =~ $re_short ]]; then
    _sha_opt_error "非法 option 定义 [$spec]，短选项名非法 [$short]，必须是 - 加单个字母数字"
    return $?
  fi
  if [[ ! $long =~ $re_long ]]; then
    _sha_opt_error "非法 option 定义 [$spec]，长选项名非法 [$long]"
    return $?
  fi
  if [[ $long == "--help" || $short == "-h" ]]; then
    _sha_opt_error "非法 option 定义 [$spec]，--help / -h 保留给 help 通道"
    return $?
  fi
  local var=${long#--}
  var=${var//-/_}

  # --- type ---
  local type tail
  local re_type='^(string|int|bool|list)(.*)$'
  if [[ $rest =~ $re_type ]]; then
    type=${BASH_REMATCH[1]}
    tail=${BASH_REMATCH[2]}
  else
    _sha_opt_error "非法 option 定义 [$spec]，缺少类型，只支持 string/int/bool/list"
    return $?
  fi

  # --- ("=" default)? : default 取到第一个 ! [ : 之前 ---
  local default="" has_default=0
  if [[ $tail == =* ]]; then
    local t=${tail#=} a b c
    a=${t%%!*}
    b=${t%%\[*}
    c=${t%%:*}
    default=$a
    [[ ${#b} -lt ${#default} ]] && default=$b
    [[ ${#c} -lt ${#default} ]] && default=$c
    if [[ -z $default ]]; then
      _sha_opt_error "非法 option 定义 [$spec]，默认值不能为空（无默认值就别写 =）"
      return $?
    fi
    has_default=1
    tail=${t:${#default}}
  fi

  # --- ("!")? ---
  local req=0
  if [[ $tail == '!'* ]]; then
    req=1
    tail=${tail#'!'}
  fi

  # --- enum-block? ---
  local enum=""
  if [[ $tail == "["* ]]; then
    local after=${tail:1}
    case $after in
      *]*)
        enum=${after%%]*}
        tail=${after#*]}
        ;;
      *)
        _sha_opt_error "非法 option 定义 [$spec]，枚举缺少 ]"
        return $?
        ;;
    esac
    if [[ -z $enum ]]; then
      _sha_opt_error "非法 option 定义 [$spec]，枚举不能为空"
      return $?
    fi
    local lit
    IFS='|' read -ra _sha_opt_lits <<<"$enum"
    for lit in ${_sha_opt_lits[@]+"${_sha_opt_lits[@]}"}; do
      case $lit in
        ""|*:*)
          _sha_opt_error "非法 option 定义 [$spec]，枚举字面量非法 [$lit]"
          return $?
          ;;
      esac
    done
  fi

  # --- (":" help)? ---
  local help=""
  if [[ -n $tail ]]; then
    case $tail in
      :*)
        help=${tail#:}
        ;;
      *)
        _sha_opt_error "非法 option 定义 [$spec]，无法解析的尾部 [$tail]"
        return $?
        ;;
    esac
  fi

  # --- 语义约束 ---
  if [[ $type == "bool" ]]; then
    if (( has_default || req )) || [[ -n $enum ]]; then
      _sha_opt_error "非法 option 定义 [$spec]，bool 不接受默认值 / required / 枚举"
      return $?
    fi
  fi
  if (( req && has_default )); then
    _sha_opt_error "非法 option 定义 [$spec]，required 不能同时有默认值"
    return $?
  fi
  if [[ $type == "list" && $has_default == "1" ]]; then
    _sha_opt_error "非法 option 定义 [$spec]，list 不支持默认值（缺席即空数组）"
    return $?
  fi
  if [[ $cmd == "*" && $req == "1" ]]; then
    _sha_opt_error "非法 option 定义 [$spec]，全局选项只接受选填"
    return $?
  fi
  # NOTE: int 只做词法校验（"08" 能通过，见 S40），不管范围、不做归一化；
  # bash 算术的八进制陷阱（$((08)) 报错）不在 int 的保证范围内。
  local re_int='^[+-]?[0-9]+$'
  if (( has_default )) && [[ $type == "int" && ! $default =~ $re_int ]]; then
    _sha_opt_error "非法 option 定义 [$spec]，默认值 [$default] 不是整数"
    return $?
  fi
  if (( has_default )) && [[ -n $enum ]]; then
    local found=0 l
    IFS='|' read -ra _sha_opt_lits <<<"$enum"
    for l in ${_sha_opt_lits[@]+"${_sha_opt_lits[@]}"}; do
      [[ $l == "$default" ]] && found=1
    done
    if (( ! found )); then
      _sha_opt_error "非法 option 定义 [$spec]，默认值 [$default] 不在枚举 [$enum] 内"
      return $?
    fi
  fi

  # --- 重复 / 撞车 ---
  local key="$cmd|$var"
  if [[ -n ${_SHA_OPT_TYPE[$key]+x} ]]; then
    if [[ ${_SHA_OPT_LONG[$key]} != "$long" ]]; then
      _sha_opt_error "非法 option 定义 [$spec]，[$long] 与 [${_SHA_OPT_LONG[$key]}] 映射到同一变量 [$var]"
      return $?
    fi
    _sha_opt_error "非法 option 定义 [$spec]，选项 [$long] 在 [$cmd] 重复定义"
    return $?
  fi
  if [[ -n $short ]]; then
    local sshort=${short#-}
    if [[ -n ${_SHA_OPT_SHORT[$cmd|$sshort]+x} ]]; then
      _sha_opt_error "非法 option 定义 [$spec]，短选项 [$short] 在 [$cmd] 重复"
      return $?
    fi
    local k v
    # NOTE: 不用 ${!arr[@]+"${!arr[@]}"} 守卫写法，它与 ${!arr[@]} 取键形式
    # 不兼容（会被当成间接展开，恒为空，冲突检测变死代码）；本项目禁 nounset，
    # 空关联数组直接引用的展开是安全的。
    for k in "${!_SHA_OPT_SHORT[@]}"; do
      if [[ $k == *"|$sshort" && $k != "$cmd|$sshort" ]]; then
        v=${_SHA_OPT_SHORT[$k]}
        if [[ $v != "$var" && ( $k == "*|$sshort" || $cmd == "*" ) ]]; then
          _sha_opt_error "非法 option 定义 [$spec]，短选项 [$short] 与 [$k] 冲突"
          return $?
        fi
      fi
    done
  fi

  # --- 落表 ---
  _SHA_OPT_TYPE[$key]=$type
  _SHA_OPT_LONG[$key]=$long
  _SHA_OPT_REQUIRED[$key]=$req
  _SHA_OPT_ENUM[$key]=$enum
  _SHA_OPT_HELP[$key]=$help
  if (( has_default )); then
    _SHA_OPT_DEFAULT[$key]=$default
    _SHA_OPT_HAS_DEFAULT[$key]=1
  fi
  [[ -n $short ]] && _SHA_OPT_SHORT[$cmd|${short#-}]=$var
  _SHA_OPT_SHORT_OF[$key]=${short#-}
  _SHA_OPT_ORDER[$cmd]="${_SHA_OPT_ORDER[$cmd]:+${_SHA_OPT_ORDER[$cmd]} }$var"
}

# 位置参数声明: NAME[!][...][:help]
#   FILE        选填；FILE! 必填；FILES... 选填 variadic（吞剩余全部，须最后）；
#   FILES!...  必填 variadic（至少 1 个，须最后）；必填不能跟在选填之后。
# 未声明 args 的命令保持透传兼容（位置参数不校验）。
_sha_opt_add_arg() {
  local cmd=$1 spec=$2
  local head help=""
  case $spec in
    *:* ) head=${spec%%:*}; help=${spec#*:} ;;
    * ) head=$spec ;;
  esac
  local name=$head req=0 vrest=0
  case $name in
    *... ) vrest=1; name=${name%...} ;;
  esac
  case $name in
    *! ) req=1; name=${name%!} ;;
  esac
  local re_name='^[A-Za-z_][A-Za-z0-9_]*$'
  if [[ -z $name || ! $name =~ $re_name ]]; then
    _sha_opt_error "非法位置参数定义 [$spec]，名字必须匹配 [A-Za-z_][A-Za-z0-9_]*"
    return $?
  fi
  if [[ $cmd == "*" ]]; then
    _sha_opt_error "非法位置参数定义 [$spec]，全局不接受位置参数"
    return $?
  fi
  if [[ -n ${_SHA_OPT_ARG_REQ[$cmd|$name]+x} ]]; then
    _sha_opt_error "非法位置参数定义 [$spec]，位置参数 [$name] 在 [$cmd] 重复定义"
    return $?
  fi
  if [[ -n ${_SHA_OPT_ARGS[$cmd]:-} ]]; then
    local prev=${_SHA_OPT_ARGS[$cmd]##* }
    if [[ ${_SHA_OPT_ARG_REST[$cmd|$prev]:-0} == "1" ]]; then
      _sha_opt_error "非法位置参数定义 [$spec]，variadic [$prev...] 必须是最后一个"
      return $?
    fi
    if (( req )) && [[ ${_SHA_OPT_ARG_REQ[$cmd|$prev]:-0} != "1" ]]; then
      _sha_opt_error "非法位置参数定义 [$spec]，必填 [$name] 不能跟在选填 [$prev] 之后"
      return $?
    fi
  fi
  _SHA_OPT_ARGS[$cmd]="${_SHA_OPT_ARGS[$cmd]:+${_SHA_OPT_ARGS[$cmd]} }$name"
  _SHA_OPT_ARG_HELP[$cmd|$name]=$help
  _SHA_OPT_ARG_REQ[$cmd|$name]=$req
  _SHA_OPT_ARG_REST[$cmd|$name]=$vrest
}

##################################################################################################
### desc / usage / detail 注册、help 渲染、参数解析
##################################################################################################

declare -A _SHA_DESC=()
declare -A _SHA_USAGE=()
declare -A _SHA_DETAIL=()

# 一次调用定义完一个命令的全部元数据（option/desc/usage/detail），实现体仍是
# 独立 bash 函数（按名映射发现，见 sha.bash）。底层委托给 sha.option/sha.desc/
# sha.usage/sha.detail，任一步失败即返回非零。
#
# 自举：本函数的四个参数直接用 option 语法声明（见文件尾 "sha def" 注册），
# 解析走 sha_opt_parse，与用户命令同一套逻辑。
#
# 用法: sha.def "<cmd>" [--desc T] [--usage U] [--detail D] [--opt SPEC]... [--arg SPEC]...
sha.def() {
  if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    _sha_opt_print_help "sha def"
    return 0
  fi
  local raw=$1; shift
  [[ -n ${raw:-} && $raw != -* ]] || { _sha_opt_error "sha.def 需要命令路径"; return $?; }
  local cmd=""
  _sha_opt_check_cmd "$raw" cmd || return $?
  local desc="" usage="" detail=""
  local -a opt=() rest=() arg=()
  sha_opt_parse rest "$@" || return $?
  if (( ${#rest[@]} )); then
    _sha_opt_error "sha.def [$cmd] 不接受位置参数 [${rest[*]}]"
    return $?
  fi
  [[ -n $desc ]] && { sha.desc "$cmd" "$desc" || return $?; }
  [[ -n $usage ]] && { sha.usage "$cmd" "$usage" || return $?; }
  [[ -n $detail ]] && { sha.detail "$cmd" "$detail" || return $?; }
  if (( ${#opt[@]} )); then
    sha.option "$cmd" "${opt[@]}" || return $?
  fi
  local a
  for a in ${arg[@]+"${arg[@]}"}; do
    _sha_opt_add_arg "$cmd" "$a" || return $?
  done
}

sha.desc() {
  local raw=$1 text=${2:-} cmd=""
  [[ -n ${raw:-} ]] || { _sha_opt_error "sha.desc 需要命令路径"; return $?; }
  _sha_opt_norm_cmd "$raw" cmd
  case $text in
    *$'\n'*) _sha_opt_error "sha.desc 只接受单行 [$cmd]，多行请用 sha.detail"; return $? ;;
  esac
  _SHA_DESC[$cmd]=$text
}

sha.usage() {
  local raw=$1 cmd=""
  [[ -n ${raw:-} ]] || { _sha_opt_error "sha.usage 需要命令路径"; return $?; }
  _sha_opt_norm_cmd "$raw" cmd
  _SHA_USAGE[$cmd]=${2:-}
}

sha.detail() {
  local raw=$1 cmd=""
  [[ -n ${raw:-} ]] || { _sha_opt_error "sha.detail 需要命令路径"; return $?; }
  _sha_opt_norm_cmd "$raw" cmd
  _SHA_DETAIL[$cmd]=${2:-}
}

# 是否有完整 help 可打 (spec / desc / usage / detail 任一，或全局选项存在)
_sha_opt_has_help() {
  local cmd=$1
  [[ -n $cmd ]] || return 1
  [[ -n ${_SHA_OPT_ORDER[$cmd]:-} || -n ${_SHA_DESC[$cmd]:-} ]] && return 0
  [[ -n ${_SHA_USAGE[$cmd]:-} || -n ${_SHA_DETAIL[$cmd]:-} ]] && return 0
  [[ -n ${_SHA_OPT_ORDER['*']:-} ]] && return 0
  return 1
}

_sha_opt_one_line() {
  local key=$1 long=$2 var=$3
  local type=${_SHA_OPT_TYPE[$key]} req=${_SHA_OPT_REQUIRED[$key]}
  local enum=${_SHA_OPT_ENUM[$key]} help=${_SHA_OPT_HELP[$key]}
  local short=${_SHA_OPT_SHORT_OF[$key]:-}
  local head meta="" mv
  if [[ $type == "bool" ]]; then
    mv=""
  else
    mv=${var^^}
    [[ $type == "list" ]] && mv="$mv..."
  fi
  if [[ -n $short ]]; then
    head="-$short, $long"
  else
    head="$long"
  fi
  [[ -n $mv ]] && head="$head $mv"
  local parts=()
  (( req )) && parts+=("required")
  if [[ -n ${_SHA_OPT_HAS_DEFAULT[$key]:-} ]]; then
    parts+=("default: ${_SHA_OPT_DEFAULT[$key]}")
  fi
  [[ -n $enum ]] && parts+=("must be $enum")
  if (( ${#parts[@]} )); then
    local joined=${parts[0]} i
    for (( i=1; i<${#parts[@]}; i++ )); do joined="$joined, ${parts[i]}"; done
    meta=" ($joined)"
  fi
  printf '  %-26s %s%s\n' "$head" "$help" "$meta"
}

# usage 行：显式注册优先；否则有 opts/args 即自动生成
#   usage: <prog> <cmd> [options] <FILE> [LIMIT] [FILES...]
_sha_opt_print_usage() {
  local cmd=$1
  if [[ -n ${_SHA_USAGE[$cmd]:-} ]]; then
    echo "usage: ${_SHA_USAGE[$cmd]}"
    return 0
  fi
  if [[ -z ${_SHA_OPT_ORDER[$cmd]:-} && -z ${_SHA_OPT_ARGS[$cmd]:-} ]]; then
    return 0
  fi
  local u="usage: ${0##*/} $cmd"
  [[ -n ${_SHA_OPT_ORDER[$cmd]:-} ]] && u="$u [options]"
  local an
  for an in ${_SHA_OPT_ARGS[$cmd]:-}; do
    local akey="$cmd|$an"
    if [[ ${_SHA_OPT_ARG_REST[$akey]:-0} == "1" ]]; then
      if [[ ${_SHA_OPT_ARG_REQ[$akey]:-0} == "1" ]]; then u="$u <$an...>"; else u="$u [$an...]"; fi
    elif [[ ${_SHA_OPT_ARG_REQ[$akey]:-0} == "1" ]]; then u="$u <$an>"; else u="$u [$an]"; fi
  done
  echo "$u"
  return 0
}

_sha_opt_print_help() {
  local cmd=$1 v key an akey ameta
  echo
  echo "command: $cmd"
  [[ -n ${_SHA_DESC[$cmd]:-} ]] && echo "  ${_SHA_DESC[$cmd]}"
  _sha_opt_print_usage "$cmd"
  [[ -n ${_SHA_DETAIL[$cmd]:-} ]] && echo "${_SHA_DETAIL[$cmd]}"
  if [[ -n ${_SHA_OPT_ORDER[$cmd]:-} ]]; then
    echo "options:"
    for v in ${_SHA_OPT_ORDER[$cmd]}; do
      key="$cmd|$v"
      _sha_opt_one_line "$key" "${_SHA_OPT_LONG[$key]}" "$v"
    done
  fi
  if [[ -n ${_SHA_OPT_ARGS[$cmd]:-} ]]; then
    echo "arguments:"
    for an in ${_SHA_OPT_ARGS[$cmd]}; do
      akey="$cmd|$an"
      ameta=""
      [[ ${_SHA_OPT_ARG_REQ[$akey]:-0} == "1" ]] && ameta=" (required)"
      [[ ${_SHA_OPT_ARG_REST[$akey]:-0} == "1" ]] && an="$an..."
      printf '  %-26s %s%s\n' "$an" "${_SHA_OPT_ARG_HELP[$akey]}" "$ameta"
    done
  fi
  if [[ -n ${_SHA_OPT_ORDER['*']:-} ]]; then
    echo "global options:"
    for v in ${_SHA_OPT_ORDER['*']}; do
      key="*|$v"
      _sha_opt_one_line "$key" "${_SHA_OPT_LONG[$key]}" "$v"
    done
  fi
  echo
}

# 分发层预扫: 余下参数在 -- 之前出现 -h/--help 即打完整 help
# 返回 0=已打印(caller 直接 return 0), 1=未处理(继续)
_sha_opt_pre_scan() {
  local cmd=$1; shift
  _sha_opt_has_help "$cmd" || return 1
  local a
  for a in ${@+"$@"}; do
    case $a in
      --) break ;;
      -h|--help) _sha_opt_print_help "$cmd"; return 0 ;;
    esac
  done
  return 1
}

# 按长名找选项，打印 "cmd|var" 或 "*|var"，找不到返回 1
_sha_opt_find_long() {
  local cmd=$1 name=$2 v
  for v in ${_SHA_OPT_ORDER[$cmd]:-}; do
    [[ ${_SHA_OPT_LONG[$cmd|$v]} == "--$name" ]] && { printf '%s' "$cmd|$v"; return 0; }
  done
  for v in ${_SHA_OPT_ORDER['*']:-}; do
    [[ ${_SHA_OPT_LONG[*|$v]} == "--$name" ]] && { printf '%s' "*|$v"; return 0; }
  done
  return 1
}

# 按短名找，打印 key
_sha_opt_find_short() {
  local cmd=$1 short=$2
  [[ -n ${_SHA_OPT_SHORT[$cmd|$short]:-} ]] && { printf '%s' "$cmd|${_SHA_OPT_SHORT[$cmd|$short]}"; return 0; }
  [[ -n ${_SHA_OPT_SHORT[*|$short]:-} ]] && { printf '%s' "*|${_SHA_OPT_SHORT[*|$short]}"; return 0; }
  return 1
}

_sha_opt_valid_list() {
  local cmd=$1 v s out=""
  for v in ${_SHA_OPT_ORDER[$cmd]:-}; do
    s=${_SHA_OPT_SHORT_OF[$cmd|$v]:-}
    out="$out ${_SHA_OPT_LONG[$cmd|$v]}${s:+/-$s}"
  done
  for v in ${_SHA_OPT_ORDER['*']:-}; do
    s=${_SHA_OPT_SHORT_OF[*|$v]:-}
    out="$out ${_SHA_OPT_LONG[*|$v]}${s:+/-$s}"
  done
  printf '%s' "${out# }"
}

# 用法: sha_opt_parse <pos_array> "$@"
#   pos_array: 调用方预先 local -a 的数组名，位置参数按原相对顺序写入
#   命令路径从调用函数名推导 (build.web() -> "build web")
# 返回: 0 解析成功 / 1 报错(已打印) / 2 遇到 -h/--help(已打印 help)
sha_opt_parse() {
  local pos_array=$1; shift
  [[ $pos_array =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    _sha_opt_error "用法: sha_opt_parse <pos_array> \"\$@\""
    return $?
  }
  local caller=${FUNCNAME[1]:-}
  [[ -n $caller ]] || { _sha_opt_error "sha_opt_parse 必须在命令函数内调用"; return $?; }
  local cmd=""
  _sha_opt_norm_cmd "$caller" cmd

  # pos 数组名不得与本命令/全局的选项变量重名，否则位置参数无处可写
  local cv
  for cv in ${_SHA_OPT_ORDER[$cmd]:-} ${_SHA_OPT_ORDER['*']:-}; do
    if [[ $cv == "$pos_array" ]]; then
      _sha_opt_error "位置数组 [$pos_array] 与选项变量重名"
      return $?
    fi
  done

  declare -n _sha_pos="$pos_array" 2>/dev/null || {
    _sha_opt_error "[$cmd] 位置数组 [$pos_array] 非法"
    return $?
  }
  _sha_pos=() 2>/dev/null || { _sha_opt_error "[$cmd] [$pos_array] 必须是数组 (local -a)"; return $?; }

  # 初值: 只回填已声明的变量 (opt-in，不强制函数声明全部选项)；
  # 传了某选项却没声明对应 local，赋值时报错 (防写穿全局)。
  local v key type
  local -A _sha_seen=()
  for v in ${_SHA_OPT_ORDER[$cmd]:-}; do
    key="$cmd|$v"
    _sha_seen[$v]=1
    declare -p "$v" >/dev/null 2>&1 || continue
    type=${_SHA_OPT_TYPE[$key]}
    declare -n _sha_init="$v"
    case $type in
      list) _sha_init=() ;;
      bool) _sha_init=0 ;;
      *) _sha_init=${_SHA_OPT_DEFAULT[$key]:-} ;;
    esac
  done
  for v in ${_SHA_OPT_ORDER['*']:-}; do
    [[ -n ${_sha_seen[$v]:-} ]] && continue
    _sha_seen[$v]=1
    key="*|$v"
    declare -p "$v" >/dev/null 2>&1 || continue
    type=${_SHA_OPT_TYPE[$key]}
    declare -n _sha_init="$v"
    case $type in
      list) _sha_init=() ;;
      bool) _sha_init=0 ;;
      *) _sha_init=${_SHA_OPT_DEFAULT[$key]:-} ;;
    esac
  done

  local -A _given=()
  local a name value key2 found
  local re_int='^[+-]?[0-9]+$'
  while (($#)); do
    case $1 in
      --)
        shift
        while (($#)); do _sha_pos+=("$1"); shift; done
        break
        ;;
      -h|--help)
        _sha_opt_print_help "$cmd"
        return 2
        ;;
      --no-*)
        name=${1#--no-}
        key2=$(_sha_opt_find_long "$cmd" "$name") && found=1 || found=0
        if (( ! found )) || [[ ${_SHA_OPT_TYPE[$key2]} != "bool" ]]; then
          _sha_opt_error "unknown option [$1] for [$cmd] (--no- 只用于 bool)，valid: $(_sha_opt_valid_list "$cmd")"
          return $?
        fi
        _sha_opt_take_value "$key2" "false" || return $?
        shift
        ;;
      --*=*)
        name=${1%%=*}; name=${name#--}
        value=${1#*=}
        key2=$(_sha_opt_find_long "$cmd" "$name") && found=1 || found=0
        if (( ! found )); then
          _sha_opt_error "unknown option [--$name] for [$cmd]，valid: $(_sha_opt_valid_list "$cmd")"
          return $?
        fi
        _sha_opt_take_value "$key2" "$value" || return $?
        shift
        ;;
      --*)
        name=${1#--}
        key2=$(_sha_opt_find_long "$cmd" "$name") && found=1 || found=0
        if (( ! found )); then
          _sha_opt_error "unknown option [$1] for [$cmd]，valid: $(_sha_opt_valid_list "$cmd")"
          return $?
        fi
        if [[ ${_SHA_OPT_TYPE[$key2]} == "bool" ]]; then
          _sha_opt_take_value "$key2" "true" || return $?
          shift
        else
          (( $# >= 2 )) || { _sha_opt_error "option [$1] requires a value"; return $?; }
          _sha_opt_take_value "$key2" "$2" || return $?
          shift 2
        fi
        ;;
      -?*)
        a=$1
        if [[ ${#a} -eq 2 || ( ${#a} -gt 3 && ${a:2:1} == "=" ) ]]; then
          local ch=${a:1:1}
          key2=$(_sha_opt_find_short "$cmd" "$ch") && found=1 || found=0
          if (( ! found )); then
            _sha_opt_error "unknown option [$a] for [$cmd] (v1 只支持 --long)，valid: $(_sha_opt_valid_list "$cmd")"
            return $?
          fi
          if [[ ${_SHA_OPT_TYPE[$key2]} == "bool" ]]; then
            if [[ $a == *=* ]]; then
              _sha_opt_take_value "$key2" "${a#*=}" || return $?
            else
              _sha_opt_take_value "$key2" "true" || return $?
            fi
            shift
          else
            if [[ $a == *=* ]]; then
              _sha_opt_take_value "$key2" "${a#*=}" || return $?
              shift
            else
              (( $# >= 2 )) || { _sha_opt_error "option [$a] requires a value"; return $?; }
              _sha_opt_take_value "$key2" "$2" || return $?
              shift 2
            fi
          fi
        elif [[ $a == "-" ]]; then
          _sha_pos+=("$1"); shift
        else
          _sha_opt_error "unknown option [$a] for [$cmd] (短选项不支持合写/贴写)，valid: $(_sha_opt_valid_list "$cmd")"
          return $?
        fi
        ;;
      *)
        _sha_pos+=("$1"); shift
        ;;
    esac
  done

  # 必填校验: 未出现或空值都算缺
  for v in ${_SHA_OPT_ORDER[$cmd]:-}; do
    key="$cmd|$v"
    (( ${_SHA_OPT_REQUIRED[$key]:-0} )) || continue
    type=${_SHA_OPT_TYPE[$key]}
    if [[ -z ${_given[$key]:-} ]]; then
      _sha_opt_error "option [${_SHA_OPT_LONG[$key]}] is required"
      return $?
    fi
    if [[ $type != "list" ]]; then
      declare -n _sha_chk="$v"
      if [[ -z $_sha_chk ]]; then
        _sha_opt_error "option [${_SHA_OPT_LONG[$key]}] is required (不接受空值)"
        return $?
      fi
    fi
  done

  # 位置参数校验: 仅当本命令声明了 args；未声明则保持透传兼容
  if [[ -n ${_SHA_OPT_ARGS[$cmd]:-} ]]; then
    local -a _names=(${_SHA_OPT_ARGS[$cmd]})
    local i=0 an
    for an in "${_names[@]}"; do
      local akey="$cmd|$an"
      local areq=${_SHA_OPT_ARG_REQ[$akey]:-0} arest=${_SHA_OPT_ARG_REST[$akey]:-0}
      if (( arest )); then
        if (( areq && ${#_sha_pos[@]} <= i )); then
          _sha_opt_error "missing argument <$an...> for [$cmd] (至少需要 1 个)"
          return $?
        fi
        i=${#_sha_pos[@]}
      elif (( i < ${#_sha_pos[@]} )); then
        i=$((i+1))
      elif (( areq )); then
        _sha_opt_error "missing argument <$an> for [$cmd]"
        return $?
      fi
    done
    if (( i < ${#_sha_pos[@]} )); then
      _sha_opt_error "unexpected argument [${_sha_pos[$i]}] for [$cmd]"
      return $?
    fi
  fi
  return 0
}

# 内部: 给 key 赋值 (上层已做 unknown 检查；未声明 local 在此报错)
_sha_opt_take_value() {
  local key=$1 value=$2
  local type=${_SHA_OPT_TYPE[$key]} v=${key#*|}
  local enum=${_SHA_OPT_ENUM[$key]} long=${_SHA_OPT_LONG[$key]}
  if ! declare -p "$v" >/dev/null 2>&1; then
    _sha_opt_error "必须先声明 local $v 再用 [$long] (防写穿成全局变量)"
    return $?
  fi
  if [[ -z $value && $type != "bool" && $type != "list" && ${_SHA_OPT_REQUIRED[$key]:-0} == "1" ]]; then
    _sha_opt_error "option [$long] is required (不接受空值)"
    return $?
  fi
  if [[ $type == "bool" ]]; then
    local w=${value,,} flag=""
    case $w in
      1|true|yes|on) flag=1 ;;
      0|false|no|off) flag=0 ;;
      *)
        _sha_opt_error "option [$long] bool 值非法 [$value] (true/false/1/0/yes/no/on/off)"
        return $?
        ;;
    esac
    declare -n _sha_set="$v"; _sha_set=$flag
    _given[$key]=1
    return 0
  fi
  if [[ $type == "int" ]]; then
    local re_int='^[+-]?[0-9]+$'
    [[ $value =~ $re_int ]] || { _sha_opt_error "option [$long] must be an integer, got [$value]"; return $?; }
  fi
  if [[ -n $enum ]]; then
    local found=0 l
    IFS='|' read -ra _sha_opt_lits <<<"$enum"
    for l in ${_sha_opt_lits[@]+"${_sha_opt_lits[@]}"}; do
      [[ $l == "$value" ]] && found=1
    done
    if (( ! found )); then
      _sha_opt_error "option [$long] must be one of $enum, got [$value]"
      return $?
    fi
  fi
  declare -n _sha_set="$v"
  if [[ $type == "list" ]]; then
    _sha_set+=("$value")
  else
    _sha_set=$value
  fi
  _given[$key]=1
}

##################################################################################################
### 自举: sha.def 自己的四个参数也用 option 语法声明
### (调用者函数名 "sha.def" 按 . 分层映射到命令路径 "sha def"，正好命中本表)
##################################################################################################

sha.option "sha def" \
  "--desc:string:命令一句话说明" \
  "--usage:string:用法行（不写则自动生成）" \
  "--detail:string:多行补充说明" \
  "--opt:list:选项定义 (可重复)" \
  "--arg:list:位置参数定义 (可重复)"
