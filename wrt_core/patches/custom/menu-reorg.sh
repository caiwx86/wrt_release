#!/usr/bin/env bash
# shellcheck shell=bash
#
# menu-reorg.sh —— 批量迁移 LuCI 菜单分类
#
# 原 update_menu() 的问题:
#   · 每个包 5 行硬编码路径, 加一个包就要复制一段, 路径写错也没人发现
#   · sed 's/nas/services/g' 是"全文任意位置"替换, 会把标题、acl、依赖里的同名子串一起改掉
#   · 不判断"当前在哪个分类", 重复执行只能靠运气才幂等
#   · 不校验改完还是不是合法 JSON, 改崩了要到启动 LuCI 才发现
#
# 现在: 数据表一行一个包, 自动读出现分类再改, 锚定 "admin/<分类>/ 前缀,
#       JSON 校验失败自动回滚, 支持预览/列表/差异输出。
#
# 用法:
#   ./menu-reorg.sh                 # 按 MENU_TARGETS 迁移
#   ./menu-reorg.sh -n              # 只看要改什么, 不写文件
#   ./menu-reorg.sh -l              # 列出每个包当前分类 -> 目标分类
#   ./menu-reorg.sh -d              # 迁移并打印 diff
#   . ./menu-reorg.sh && menu_move luci-app-npc vpn    # 临时改单个包

BASE_PATH=${BASE_PATH:-$(pwd)}
BASE_PATH=${BASE_PATH%/}
# 搜索根目录, 按优先级排列(package 优先于 feeds)
MENU_ROOTS=${MENU_ROOTS:-package custom_feed feeds}

# 目标表: 每行 "<包名> <目标分类>", # 开头为注释
MENU_TARGETS="
luci-app-qbittorrent   services
luci-app-transmission  services
luci-app-upnp          network
luci-app-emmc-health   network
luci-app-samba4        network
luci-app-wol           network
luci-app-npc           vpn
luci-app-daede         vpn
luci-app-daed          vpn
luci-app-dae           vpn
luci-app-honk          vpn
luci-app-passwall      vpn
luci-app-clashoo       vpn
"

MENU_INDEX=""
MENU_DRY_RUN=0
MENU_LIST=0
MENU_DIFF=0
MENU_CHANGED=0
MENU_UNCHANGED=0
MENU_MISSING=0
MENU_FAILED=0

_mr_usage() {
    cat <<'EOF'
用法: menu-reorg.sh [选项]

选项:
  -n, --dry-run   只打印将要发生的迁移, 不写文件
  -l, --list      只列出每个包"当前分类 -> 目标分类"
  -d, --diff      迁移成功后打印 unified diff
  -h, --help      显示本帮助

环境变量:
  BASE_PATH    OpenWrt 顶层目录, 默认当前目录
  MENU_ROOTS   搜索根, 默认 "package custom_feed feeds", 按优先级排列

迁移表在脚本里的 MENU_TARGETS 定义, 一行一个包, 改完即可复用。
EOF
}

# 名字白名单: 首字符字母数字, 其余允许 A-Za-z0-9 . _ + -
_mr_valid_name() {
    [ -n "$1" ] || return 1
    case "$1" in
        [!A-Za-z0-9]*) return 1 ;;
        *[!A-Za-z0-9._+-]*) return 1 ;;
    esac
    return 0
}

# 一次 find 建索引, 之后所有包查表, 避免每个包都扫一遍目录
_mr_build_index() {
    local root f
    MENU_INDEX=""
    for root in $MENU_ROOTS; do
        [ -d "$BASE_PATH/$root" ] || continue
        while IFS= read -r -d '' f; do
            MENU_INDEX="$MENU_INDEX$f"$'\n'
        done < <(find "$BASE_PATH/$root" -type f -path '*/luci/menu.d/*.json' -print0 2>/dev/null)
    done
}

# 按索引找 <包名>.json, 先命中的根目录优先
_mr_lookup() {
    local want="/luci/menu.d/$1.json" line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            *"$want") printf '%s\n' "$line"; return 0 ;;
        esac
    done <<EOF
$MENU_INDEX
EOF
    return 1
}

# 读出现分类: 取文件里第一个 "admin/<分类>/..." 键的分类
# (键的后半段是 slug, 不一定等于包名, 所以只认 admin/ 前缀, 不按包名反推)
_mr_current_category() {
    local file=$1 cat
    cat=$(sed -nE 's|^[[:space:]]*"admin/([A-Za-z0-9._-]+)/[^"]+"[[:space:]]*:.*|\1|p' "$file" 2>/dev/null | head -n 1)
    if [ -z "$cat" ]; then
        # 压缩成一行的 JSON 兜底
        cat=$(grep -oE '"admin/[A-Za-z0-9._-]+/' -- "$file" 2>/dev/null | head -n 1 |
              sed -E 's|^"admin/([^/]+)/$|\1|')
    fi
    [ -n "$cat" ] || return 0
    printf '%s' "$cat"
}

# JSON 合法性校验: 有 jq 用 jq, 有 python 用 python, 都没有就跳过(仍有键存在性检查兜底)
_mr_json_ok() {
    local f=$1
    if command -v jq >/dev/null 2>&1; then
        jq -e . "$f" >/dev/null 2>&1
        return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" >/dev/null 2>&1
        return $?
    fi
    if command -v python >/dev/null 2>&1; then
        python -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" >/dev/null 2>&1
        return $?
    fi
    return 0
}

# menu_move <包名> <目标分类>       自动识别当前分类
# menu_move <包名> <原分类> <目标分类>  显式指定
menu_move() {
    local pkg from to file rel bak

    case $# in
        2) pkg=$1; to=$2; from="" ;;
        3) pkg=$1; from=$2; to=$3 ;;
        *) printf 'menu_move: 需要 2 或 3 个参数\n' >&2; return 2 ;;
    esac

    if ! _mr_valid_name "$pkg" || ! _mr_valid_name "$to"; then
        printf 'menu_move: 非法名字 %s / %s\n' "$pkg" "$to" >&2
        return 2
    fi
    if [ -n "$from" ] && ! _mr_valid_name "$from"; then
        printf 'menu_move: 非法分类名 %s\n' "$from" >&2
        return 2
    fi

    file=$(_mr_lookup "$pkg") || {
        printf '  - %-24s 未找到 luci/menu.d/%s.json, 跳过\n' "$pkg" "$pkg"
        MENU_MISSING=$((MENU_MISSING + 1))
        return 0
    }
    rel=${file#"$BASE_PATH"/}

    if [ -z "$from" ]; then
        from=$(_mr_current_category "$file")
        if [ -z "$from" ]; then
            printf '  ? %-24s 内无 admin/*/%s 键, 跳过  (%s)\n' "$pkg" "$pkg" "$rel"
            MENU_MISSING=$((MENU_MISSING + 1))
            return 0
        fi
    elif ! grep -q "\"admin/$from/" -- "$file" && ! grep -q "\"admin/$from\"" -- "$file"; then
        printf '  ? %-24s 未出现 admin/%s 键, 跳过  (%s)\n' "$pkg" "$from" "$rel"
        MENU_MISSING=$((MENU_MISSING + 1))
        return 0
    fi

    if [ "$from" = "$to" ]; then
        printf '  = %-24s 已位于 admin/%s, 不变  (%s)\n' "$pkg" "$to" "$rel"
        MENU_UNCHANGED=$((MENU_UNCHANGED + 1))
        return 0
    fi

    if [ "$MENU_LIST" = 1 ]; then
        printf '  %-24s admin/%s -> admin/%s  (%s)\n' "$pkg" "$from" "$to" "$rel"
        return 0
    fi

    printf '  > %-24s admin/%s -> admin/%s  (%s)\n' "$pkg" "$from" "$to" "$rel"

    if [ "$MENU_DRY_RUN" = 1 ]; then
        MENU_CHANGED=$((MENU_CHANGED + 1))
        return 0
    fi

    # 只改 "admin/<分类>/ 前缀(含整键), 不动 title / acl / path
    if ! sed -i.menubak -E \
        -e "s|\"admin/$from/|\"admin/$to/|g" \
        -e "s|\"admin/$from\"|\"admin/$to\"|g" "$file"; then
        rm -f "$file.menubak"
        printf '  x %-24s sed 失败, 未修改  (%s)\n' "$pkg" "$rel" >&2
        MENU_FAILED=$((MENU_FAILED + 1))
        return 1
    fi

    bak="$file.menubak"

    if ! grep -q "\"admin/$to/" -- "$file" && ! grep -q "\"admin/$to\"" -- "$file"; then
        mv -f "$bak" "$file"
        printf '  x %-24s 迁移后未见 admin/%s 键, 已回滚  (%s)\n' "$pkg" "$to" "$rel" >&2
        MENU_FAILED=$((MENU_FAILED + 1))
        return 1
    fi

    if ! _mr_json_ok "$file"; then
        mv -f "$bak" "$file"
        printf '  x %-24s JSON 校验失败, 已回滚  (%s)\n' "$pkg" "$rel" >&2
        MENU_FAILED=$((MENU_FAILED + 1))
        return 1
    fi

    if [ "$MENU_DIFF" = 1 ]; then
        diff -u "$bak" "$file" || true
    fi
    rm -f "$bak"

    MENU_CHANGED=$((MENU_CHANGED + 1))
    return 0
}

update_menu() {
    local pkg cat

    while [ $# -gt 0 ]; do
        case "$1" in
            -n|--dry-run) MENU_DRY_RUN=1 ;;
            -l|--list)    MENU_LIST=1 ;;
            -d|--diff)    MENU_DIFF=1 ;;
            -h|--help)    _mr_usage; return 0 ;;
            *) printf 'update_menu: 未知参数 %s\n' "$1" >&2; _mr_usage >&2; return 2 ;;
        esac
        shift
    done

    MENU_CHANGED=0; MENU_UNCHANGED=0; MENU_MISSING=0; MENU_FAILED=0

    printf 'BASE_PATH  = %s\nMENU_ROOTS = %s\n' "$BASE_PATH" "$MENU_ROOTS"

    _mr_build_index
    if [ -z "$MENU_INDEX" ]; then
        printf '未找到任何 luci/menu.d/*.json, 请检查 BASE_PATH / MENU_ROOTS\n' >&2
        return 1
    fi

    while read -r pkg cat; do
        [ -n "${pkg:-}" ] || continue
        case "$pkg" in \#*) continue ;; esac
        if [ -z "${cat:-}" ]; then
            printf '菜单表格式错误(缺分类): %s\n' "$pkg" >&2
            MENU_FAILED=$((MENU_FAILED + 1))
            continue
        fi
        menu_move "$pkg" "$cat"
    done <<EOF
$MENU_TARGETS
EOF

    if [ "$MENU_LIST" = 1 ]; then
        return 0
    fi

    printf '\n合计: 变更 %d, 无需修改 %d, 未找到 %d, 失败 %d\n' \
        "$MENU_CHANGED" "$MENU_UNCHANGED" "$MENU_MISSING" "$MENU_FAILED"
    [ "$MENU_DRY_RUN" = 1 ] && printf '(dry-run, 未写任何文件)\n'

    [ "$MENU_FAILED" -eq 0 ]
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    update_menu "$@"
fi
