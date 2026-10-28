#!/system/bin/sh
#
# refresh_route.sh —— 中兴 F50 IPv6 RA 默认路由安全保活（联通 / 移动 / 电信）
#
# 上游项目：Xiaol1n173/f50-ipv6-ra-refresh（原作者）；本 Fork 做安全策略与联通增强。
#
# 本文件是仓库中的可读源文件，tools/sync-embedded.mjs 会把它原样嵌入
# UFI-TOOLS 插件「IPv6 RA路由修复」；插件安装到设备时写入：
#   /data/xl_ipv6_ra/refresh_route.sh
#
# 设计原则（安全模式，默认）：
#   1. 动态检测 state UP 且带全局 IPv6 地址的 sipa_ethN，不写死接口号、前缀、网关
#   2. 只发送 Router Solicitation（RS），让内核按 ND 规程续期/重建 RA 默认路由
#   3. 绝不删除仍然有效的默认路由，绝不重启蜂窝网络/改 APN/IPv4/防火墙/下游配置
#   4. “收到 RA”“路由已刷新”“公网连通”分开验证，路由未出现就报失败，不谎报成功
#   5. 原版的“删路由后重建 / 手工 replace”算法只在 MODE=advanced 时启用，默认关闭
#
# 返回值：0=成功或无需操作  1=出错  2=条件不满足而跳过
#
# 用法：
#   sh refresh_route.sh            定时/普通刷新（受最小重试间隔约束）
#   sh refresh_route.sh --force    手动刷新（忽略最小重试间隔）
#   sh refresh_route.sh --rs-only  只发一次 RS 并报告结果，不修改路由
#   sh refresh_route.sh --status   输出面板状态（只读，不加锁、不写日志）
#   sh refresh_route.sh --ping     只做公网 IPv6 连通性测试
#   sh refresh_route.sh --delete-route  手动删除当前默认路由（仅高级模式）
#
# 环境变量（仅用于普通 Linux 模拟测试，设备上无需设置）：
#   RRA_STATE_DIR  默认 /data/xl_ipv6_ra
#   RRA_CONF       默认 $STATE_DIR/refresh_route.conf
#   RRA_LOG        默认 $STATE_DIR/refresh_route.log
#   RRA_RDISC6     默认 $STATE_DIR/rdisc6
#   RRA_PING6      默认 ping6
#   RRA_BOOT       默认 /sdcard/ufi_tools_boot.sh
#   RRA_PATH       覆盖脚本内部 PATH（测试时把 mock 命令放在最前面）
#
# 配置项（refresh_route.conf，key=value）：
#   MODE=safe|advanced                安全模式/高级模式，默认 safe
#   THRESHOLD=21600                   RA 剩余有效期低于此秒数才刷新（默认 6 小时）
#   ALLOW_UNKNOWN_OPERATOR=0|1        运营商属性为空/未知时是否允许仅 RS 兼容
#   PING_ENABLE=0|1                   是否做公网 IPv6 连通性测试（默认 1）
#   PING_TARGET=2400:3200::1          连通性测试目标
#   MIN_RETRY=300                     两次刷新尝试的最小间隔（秒），防止快速重试
#   RDISC6_TIMEOUT=10                 rdisc6 外层超时（秒）
#   SETTLE_TRIES=6                    发 RA 后等待路由变化的最大秒数
#

# ================= 路径与默认值 =================
STATE_DIR=$RRA_STATE_DIR
[ -n "$STATE_DIR" ] || STATE_DIR=/data/xl_ipv6_ra

CONF=$RRA_CONF
[ -n "$CONF" ] || CONF=$STATE_DIR/refresh_route.conf

LOG=$RRA_LOG
[ -n "$LOG" ] || LOG=$STATE_DIR/refresh_route.log

RESULT_FILE=$STATE_DIR/last_result
STRATEGY_FILE=$STATE_DIR/last_strategy
ATTEMPT_FILE=$STATE_DIR/.last_attempt
LOCK=$STATE_DIR/.refresh_route.lock
RS_OUT=$STATE_DIR/.rs.out

RDISC6=$RRA_RDISC6
[ -n "$RDISC6" ] || RDISC6=$STATE_DIR/rdisc6

PING6=$RRA_PING6
[ -n "$PING6" ] || PING6=ping6

BOOT_PATH=$RRA_BOOT
[ -n "$BOOT_PATH" ] || BOOT_PATH=/sdcard/ufi_tools_boot.sh

WATCH_PATH=$STATE_DIR/refresh_route_watch.sh
PID_FILE=$STATE_DIR/refresh_route_watch.pid
WATCH_CONF=$STATE_DIR/refresh_route_watch.conf

IF_PREFIX=sipa_eth
RA_LIFETIME=65535
LOG_MAX=65536

if [ -n "$RRA_PATH" ]; then
    PATH=$RRA_PATH
else
    PATH=/system/bin:/system/xbin:/vendor/bin:/odm/bin:/sbin:/usr/bin:/bin
fi
export PATH

# 运行态默认值（保证任何退出路径都能写出完整状态）
OP_RAW=""
OP_KEY=unknown
OP_NAME=未知
DEV=""
IFACE_COUNT=0
IFACE_REASON=""
IFACE_LIST=""
ROUTE_LINE=""
GW=""
TABLE=""
EXPIRES=""
METRIC=1024
HOPLIMIT=255
GW_OK=0
TABLE_OK=0
ROUTE_STATE=missing
RA_RECEIVED=not_attempted
ROUTE_REFRESHED=no
CONNECTIVITY=not_tested
STRATEGY=none
RS_RC=127
RS_SRC=""
PRE_STATE=""
PRE_EXP=0
REFRESH_OK=0
ORIG_GW=""
ORIG_TABLE=""
ORIG_EXP=0
ORIG_METRIC=1024
ORIG_HOPLIMIT=255
ORIG_STATE=""
LP=""

# ================= 基础工具 =================
is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

clamp_uint() {
    CV=$1
    CMIN=$2
    CMAX=$3
    CDEF=$4
    is_uint "$CV" || CV=$CDEF
    [ "$CV" -lt "$CMIN" ] 2>/dev/null && CV=$CMIN
    [ "$CV" -gt "$CMAX" ] 2>/dev/null && CV=$CMAX
    printf '%s' "$CV"
}

valid_dev() {
    case "$1" in
        ''|*[!A-Za-z0-9_.-]*) return 1 ;;
    esac
    return 0
}

valid_table() {
    case "$1" in
        ''|all|*[!A-Za-z0-9_.-]*) return 1 ;;
    esac
    return 0
}

valid_gw() {
    case "$1" in
        fe80:*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[!0-9a-fA-F:]*) return 1 ;;
    esac
    return 0
}

log() {
    LM="[$(date '+%m-%d %H:%M:%S')] $*"
    printf '%s\n' "$LM" >> "$LOG" 2>/dev/null
    printf '%s\n' "$LM"
}

set_strategy() {
    printf '%s\n%s\n' "$1" "$(date +%s)" > "$STRATEGY_FILE" 2>/dev/null
}

trim_log() {
    [ -f "$LOG" ] || return 0
    LSZ=$(wc -c < "$LOG" 2>/dev/null)
    is_uint "$LSZ" || return 0
    [ "$LSZ" -gt "$LOG_MAX" ] || return 0
    LKEEP=$((LOG_MAX / 2))
    if tail -c "$LKEEP" "$LOG" > "$LOG.tmp" 2>/dev/null; then
        mv "$LOG.tmp" "$LOG" 2>/dev/null
    else
        : > "$LOG" 2>/dev/null
    fi
}

conf_get() {
    CK=$1
    CD=$2
    CV=""
    if [ -f "$CONF" ]; then
        CV=$(awk -F= -v k="$CK" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$CONF" 2>/dev/null | tr -d '\r')
    fi
    [ -n "$CV" ] || CV=$CD
    printf '%s' "$CV"
}

read_conf() {
    MODE=$(conf_get MODE safe | tr 'A-Z' 'a-z')
    [ "$MODE" = advanced ] || MODE=safe
    THRESHOLD=$(clamp_uint "$(conf_get THRESHOLD 21600)" 600 604800 21600)
    ALLOW_UNKNOWN_OPERATOR=$(clamp_uint "$(conf_get ALLOW_UNKNOWN_OPERATOR 0)" 0 1 0)
    PING_ENABLE=$(clamp_uint "$(conf_get PING_ENABLE 1)" 0 1 1)
    MIN_RETRY=$(clamp_uint "$(conf_get MIN_RETRY 300)" 60 86400 300)
    RDISC6_TIMEOUT=$(clamp_uint "$(conf_get RDISC6_TIMEOUT 10)" 1 30 10)
    SETTLE_TRIES=$(clamp_uint "$(conf_get SETTLE_TRIES 6)" 1 20 6)
    PING_TARGET=$(conf_get PING_TARGET 2400:3200::1)
    case "$PING_TARGET" in
        *[!0-9a-fA-F:.]*|'') PING_TARGET=2400:3200::1 ;;
        *:*) ;;
        *) PING_TARGET=2400:3200::1 ;;
    esac
    case "$PING6" in
        *[!A-Za-z0-9_./-]*) PING6=ping6 ;;
    esac
}

# ================= 运营商识别 =================
# 注意：3gnet 是 APN，不是运营商标识，不能拿来判断运营商。
detect_operator() {
    OP_RAW=$(getprop gsm.sim.operator.alpha 2>/dev/null | tr -d '\r\n\t ,，' | tr 'A-Z' 'a-z')
    OP_KEY=unknown
    OP_NAME=未知
    case "$OP_RAW" in
        '')
            OP_KEY=empty
            OP_NAME=空
            ;;
        *移动*|*cmcc*|*chinamobile*|*"china mobile"*)
            OP_KEY=mobile
            OP_NAME=中国移动
            ;;
        *联通*|*unicom*|*cucc*)
            OP_KEY=unicom
            OP_NAME=中国联通
            ;;
        *电信*|*telecom*|*ctcc*)
            OP_KEY=telecom
            OP_NAME=中国电信
            ;;
    esac
}

# ================= 接口与路由探测 =================
has_global_v6() {
    HG=$(ip -6 addr show dev "$1" scope global 2>/dev/null)
    if [ -z "$HG" ]; then
        HG=$(ip -6 addr show dev "$1" 2>/dev/null | grep 'inet6 .*scope global')
    fi
    printf '%s\n' "$HG" | grep -q 'inet6 '
}

route_for_dev() {
    RD=$1
    valid_dev "$RD" || return 0
    ip -6 route show table all 2>/dev/null | grep '^default via ' | grep -E " dev $RD( |$)"
}

route_lines() {
    ip -6 route show table all 2>/dev/null | grep '^default via ' | grep -E " dev $DEV( |$)"
}

pick_route() {
    PR=$(route_lines)
    [ -n "$PR" ] || return 0
    PP=$(printf '%s\n' "$PR" | grep -E " table $DEV( |$)" | head -n 1)
    if [ -n "$PP" ]; then
        printf '%s\n' "$PP"
        return 0
    fi
    PP=$(printf '%s\n' "$PR" | grep -v ' table ' | head -n 1)
    if [ -n "$PP" ]; then
        printf '%s\n' "$PP"
        return 0
    fi
    printf '%s\n' "$PR" | head -n 1
}

detect_iface() {
    DEV=""
    IFACE_COUNT=0
    IFACE_REASON=""
    IFACE_LIST=""
    I=0
    while [ "$I" -le 15 ]; do
        CAND=$IF_PREFIX$I
        I=$((I + 1))
        LINK=$(ip link show dev "$CAND" 2>/dev/null)
        [ -n "$LINK" ] || continue
        printf '%s\n' "$LINK" | grep -q 'state UP' || printf '%s\n' "$LINK" | grep -q '<[^>]*UP' || continue
        has_global_v6 "$CAND" || continue
        IFACE_COUNT=$((IFACE_COUNT + 1))
        IFACE_LIST="$IFACE_LIST $CAND"
        [ -n "$DEV" ] || DEV=$CAND
    done
    if [ "$IFACE_COUNT" -eq 0 ]; then
        IFACE_REASON=no_candidate
        DEV=""
        return 0
    fi
    if [ "$IFACE_COUNT" -eq 1 ]; then
        IFACE_REASON=single
        return 0
    fi
    WITH_ROUTE=""
    WITH_ROUTE_COUNT=0
    for CAND in $IFACE_LIST; do
        if [ -n "$(route_for_dev "$CAND")" ]; then
            WITH_ROUTE="$WITH_ROUTE $CAND"
            WITH_ROUTE_COUNT=$((WITH_ROUTE_COUNT + 1))
        fi
    done
    if [ "$WITH_ROUTE_COUNT" -eq 1 ]; then
        DEV=$(printf '%s\n' "$WITH_ROUTE" | awk '{print $1}')
        IFACE_REASON=multi_with_route
        return 0
    fi
    IFACE_REASON=ambiguous_multi
    DEV=""
}

read_route() {
    ROUTE_LINE=""
    GW=""
    TABLE=""
    EXPIRES=""
    METRIC=1024
    HOPLIMIT=255
    GW_OK=0
    TABLE_OK=0
    ROUTE_STATE=missing
    [ -n "$DEV" ] || return 0
    valid_dev "$DEV" || return 0
    ROUTE_LINE=$(pick_route)
    [ -n "$ROUTE_LINE" ] || return 0
    GW=$(printf '%s\n' "$ROUTE_LINE" | sed -n 's/.* via \([^ ]*\) .*/\1/p')
    TABLE=$(printf '%s\n' "$ROUTE_LINE" | sed -n 's/.* table \([^ ]*\) .*/\1/p')
    [ -n "$TABLE" ] || TABLE=main
    METRIC=$(printf '%s\n' "$ROUTE_LINE" | sed -n 's/.* metric \([0-9][0-9]*\).*/\1/p')
    HOPLIMIT=$(printf '%s\n' "$ROUTE_LINE" | sed -n 's/.* hoplimit \([0-9][0-9]*\).*/\1/p')
    is_uint "$METRIC" || METRIC=1024
    is_uint "$HOPLIMIT" || HOPLIMIT=255
    valid_gw "$GW" && GW_OK=1
    valid_table "$TABLE" && TABLE_OK=1
    EXPIRES=$(printf '%s\n' "$ROUTE_LINE" | sed -n 's/.*expires \(-*[0-9][0-9]*\)sec.*/\1/p')
    if [ -z "$EXPIRES" ]; then
        ROUTE_STATE=static
        return 0
    fi
    case "$EXPIRES" in
        -*) EXPIRES=0; ROUTE_STATE=expired; return 0 ;;
    esac
    if ! is_uint "$EXPIRES"; then
        EXPIRES=""
        ROUTE_STATE=static
        return 0
    fi
    if [ "$EXPIRES" -le 0 ]; then
        ROUTE_STATE=expired
    elif [ "$EXPIRES" -lt "$THRESHOLD" ]; then
        ROUTE_STATE=low
    else
        ROUTE_STATE=healthy
    fi
}

# 路由是否“可用”：静态路由视为可用；RA 路由必须有正的剩余有效期。
route_usable() {
    [ "$ROUTE_STATE" = static ] && return 0
    [ "$ROUTE_STATE" != missing ] || return 1
    is_uint "$EXPIRES" && [ "$EXPIRES" -gt 0 ]
}

# ================= 结果与状态文件 =================
read_last_result() {
    LR_TIME=""
    LR_RESULT=""
    LR_CODE=""
    LR_OP_NAME=""
    LR_IFACE=""
    LR_GW=""
    LR_ROUTE_STATE=""
    LR_EXPIRES=""
    LR_RA_RECEIVED=""
    LR_ROUTE_REFRESHED=""
    LR_CONNECTIVITY=""
    LR_STRATEGY=""
    LR_MESSAGE=""
    [ -f "$RESULT_FILE" ] || return 0
    LR_TIME=$(sed -n 's/^TIME=//p' "$RESULT_FILE" 2>/dev/null | head -n 1)
    LR_RESULT=$(sed -n 's/^RESULT=//p' "$RESULT_FILE" 2>/dev/null | head -n 1)
    LR_CODE=$(sed -n 's/^CODE=//p' "$RESULT_FILE" 2>/dev/null | head -n 1)
    LR_OP_NAME=$(sed -n 's/^OP_NAME=//p' "$RESULT_FILE" 2>/dev/null | head -n 1)
    LR_IFACE=$(sed -n 's/^IFACE=//p' "$RESULT_FILE" 2>/dev/null | head -n 1)
    LR_GW=$(sed -n 's/^GW=//p' "$RESULT_FILE" 2>/dev/null | head -n 1)
    LR_ROUTE_STATE=$(sed -n 's/^ROUTE_STATE=//p' "$RESULT_FILE" 2>/dev/null | head -n 1)
    LR_EXPIRES=$(sed -n 's/^EXPIRES=//p' "$RESULT_FILE" 2>/dev/null | head -n 1)
    LR_RA_RECEIVED=$(sed -n 's/^RA_RECEIVED=//p' "$RESULT_FILE" 2>/dev/null | head -n 1)
    LR_ROUTE_REFRESHED=$(sed -n 's/^ROUTE_REFRESHED=//p' "$RESULT_FILE" 2>/dev/null | head -n 1)
    LR_CONNECTIVITY=$(sed -n 's/^CONNECTIVITY=//p' "$RESULT_FILE" 2>/dev/null | head -n 1)
    LR_STRATEGY=$(sed -n 's/^STRATEGY=//p' "$RESULT_FILE" 2>/dev/null | head -n 1)
    LR_MESSAGE=$(sed -n 's/^MESSAGE=//p' "$RESULT_FILE" 2>/dev/null | head -n 1)
}

write_result() {
    WR_RESULT=$1
    WR_CODE=$2
    WR_MSG=$3
    WR_MSG=$(printf '%s' "$WR_MSG" | tr -d '\r\n' | cut -c 1-400)
    WRTMP=$RESULT_FILE.tmp
    {
        printf 'TIME=%s\n' "$(date +%s)"
        printf 'RESULT=%s\n' "$WR_RESULT"
        printf 'CODE=%s\n' "$WR_CODE"
        printf 'OP_KEY=%s\n' "$OP_KEY"
        printf 'OP_NAME=%s\n' "$OP_NAME"
        printf 'OP_RAW=%s\n' "$OP_RAW"
        printf 'IFACE=%s\n' "$DEV"
        printf 'IFACE_COUNT=%s\n' "$IFACE_COUNT"
        printf 'IFACE_REASON=%s\n' "$IFACE_REASON"
        printf 'GW=%s\n' "$GW"
        printf 'TABLE=%s\n' "$TABLE"
        printf 'ROUTE_STATE=%s\n' "$ROUTE_STATE"
        printf 'EXPIRES=%s\n' "$EXPIRES"
        printf 'RA_RECEIVED=%s\n' "$RA_RECEIVED"
        printf 'ROUTE_REFRESHED=%s\n' "$ROUTE_REFRESHED"
        printf 'CONNECTIVITY=%s\n' "$CONNECTIVITY"
        printf 'STRATEGY=%s\n' "$STRATEGY"
        printf 'MESSAGE=%s\n' "$WR_MSG"
    } > "$WRTMP" 2>/dev/null && mv "$WRTMP" "$RESULT_FILE" 2>/dev/null
}

# ================= 并发锁 =================
lock_busy() {
    [ -n "$1" ] && [ -d "/proc/$1" ] && grep -q 'refresh_route[.]sh' "/proc/$1/cmdline" 2>/dev/null
}

take_lock() {
    mkdir "$LOCK" 2>/dev/null || return 1
    printf '%s\n' "$$" > "$LOCK/pid"
    trap '[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK" 2>/dev/null' EXIT
    trap 'exit 0' INT TERM HUP
    return 0
}

acquire_lock() {
    if take_lock; then
        return 0
    fi
    LP=$(cat "$LOCK/pid" 2>/dev/null)
    if lock_busy "$LP"; then
        return 1
    fi
    if [ -z "$LP" ]; then
        # 锁目录已建立但 pid 尚未写入：并发加锁竞态，短暂让位后重试。
        # 不能立即 rm -rf，否则可能删掉对方刚建好的锁，导致双实例并发。
        sleep 1
        if take_lock; then
            return 0
        fi
        LP=$(cat "$LOCK/pid" 2>/dev/null)
        if lock_busy "$LP"; then
            return 1
        fi
    fi
    [ -n "$LP" ] || LP="<未写入>"
    log "清理陈旧锁 $LOCK（原持锁进程: $LP）"
    rm -rf "$LOCK"
    take_lock
}

# ================= RS 与路由验证 =================
send_rs() {
    RA_RECEIVED=no
    RS_SRC=""
    RS_RC=127
    if [ ! -x "$RDISC6" ]; then
        return 1
    fi
    : > "$RS_OUT" 2>/dev/null
    if command -v timeout >/dev/null 2>&1; then
        timeout "$RDISC6_TIMEOUT" "$RDISC6" -1 -r 2 -w 3000 "$DEV" > "$RS_OUT" 2>&1
    else
        "$RDISC6" -1 -r 2 -w 3000 "$DEV" > "$RS_OUT" 2>&1
    fi
    RS_RC=$?
    [ "$RS_RC" -eq 0 ] && RA_RECEIVED=yes
    RS_SRC=$(sed -n 's/.*[Ff]rom \(fe80:[0-9a-fA-F:]*\).*/\1/p' "$RS_OUT" 2>/dev/null | head -n 1)
    if [ "$RA_RECEIVED" = yes ]; then
        log "rdisc6: 已收到 RA（退出码 0）"
    else
        log "rdisc6: 未收到 RA（退出码 $RS_RC）"
        if [ -s "$RS_OUT" ]; then
            head -n 4 "$RS_OUT" | while IFS= read -r RS_LINE; do
                log "rdisc6: $RS_LINE"
            done
        fi
    fi
    [ -n "$RS_SRC" ] && log "RA 来源（rdisc6 输出）: $RS_SRC"
    return 0
}

# 发 RA 后轮询内核路由表：missing -> 出现即可；low/expired -> 有效期必须变长。
wait_route() {
    REFRESH_OK=0
    WN=0
    while [ "$WN" -lt "$SETTLE_TRIES" ]; do
        read_route
        if [ "$PRE_STATE" = missing ]; then
            if route_usable; then
                REFRESH_OK=1
                return 0
            fi
        else
            if [ "$ROUTE_STATE" = static ]; then
                REFRESH_OK=1
                return 0
            fi
            if [ "$ROUTE_STATE" != missing ] && is_uint "$EXPIRES" && [ "$EXPIRES" -gt "$PRE_EXP" ]; then
                REFRESH_OK=1
                return 0
            fi
        fi
        WN=$((WN + 1))
        [ "$WN" -lt "$SETTLE_TRIES" ] && sleep 1
    done
    return 1
}

test_connectivity() {
    CONNECTIVITY=unavailable
    [ "$PING_ENABLE" = 1 ] || {
        CONNECTIVITY=disabled
        return 0
    }
    PBIN=$PING6
    if ! command -v "$PBIN" >/dev/null 2>&1; then
        if [ -x /system/bin/ping6 ]; then
            PBIN=/system/bin/ping6
        else
            # 没有 ping6 时只能标记“无法测试”，绝不能据此判定 IPv6 不通。
            CONNECTIVITY=unavailable
            log "连通性测试跳过：未安装 ping6（不能据此判定 IPv6 不通）"
            return 0
        fi
    fi
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 "$PBIN" -c 1 -W 2 "$PING_TARGET" >/dev/null 2>&1
    else
        "$PBIN" -c 1 -W 2 "$PING_TARGET" >/dev/null 2>&1
    fi
    if [ $? -eq 0 ]; then
        CONNECTIVITY=ok
        log "公网 IPv6 连通性：正常（$PING_TARGET）"
    else
        CONNECTIVITY=fail
        log "公网 IPv6 连通性：不通（$PING_TARGET；不影响路由刷新结论）"
    fi
}

check_cooldown() {
    COOLDOWN_LEFT=0
    CNOW=$(date +%s)
    CLAST=$(cat "$ATTEMPT_FILE" 2>/dev/null)
    is_uint "$CNOW" || return 0
    is_uint "$CLAST" || return 0
    [ "$CNOW" -ge "$CLAST" ] || return 0
    CAGE=$((CNOW - CLAST))
    if [ "$CAGE" -lt "$MIN_RETRY" ]; then
        COOLDOWN_LEFT=$((MIN_RETRY - CAGE))
        return 1
    fi
    return 0
}

touch_attempt() {
    date +%s > "$ATTEMPT_FILE" 2>/dev/null
}

# 高级模式：只删除当前实际读到的那条 RA 默认路由，网关/表名/接口不合法就拒绝。
delete_route() {
    [ "$TABLE_OK" = 1 ] || return 1
    [ "$GW_OK" = 1 ] || return 1
    [ "$ROUTE_STATE" != missing ] || return 1
    DR_TAB=$TABLE
    if [ "$DR_TAB" = main ]; then
        ip -6 route del default via "$GW" dev "$DEV" 2>>"$LOG"
    else
        ip -6 route del default via "$GW" dev "$DEV" table "$DR_TAB" 2>>"$LOG"
    fi
}

# 高级模式：用已确认的网关重建与 RA 同构的路由。
replace_route() {
    RR_GW=$1
    RR_LIFE=$2
    RR_FULL=$3
    RR_MET=$4
    RR_HOP=$5
    RR_TAB=$6
    valid_gw "$RR_GW" || return 1
    valid_table "$RR_TAB" || return 1
    is_uint "$RR_LIFE" || return 1
    is_uint "$RR_MET" || RR_MET=1024
    is_uint "$RR_HOP" || RR_HOP=255
    if [ "$RR_TAB" = main ]; then
        if [ "$RR_FULL" = 1 ]; then
            ip -6 route replace default via "$RR_GW" dev "$DEV" proto ra hoplimit "$RR_HOP" metric "$RR_MET" expires "$RR_LIFE" 2>>"$LOG"
        else
            ip -6 route replace default via "$RR_GW" dev "$DEV" expires "$RR_LIFE" 2>>"$LOG"
        fi
    else
        if [ "$RR_FULL" = 1 ]; then
            ip -6 route replace default via "$RR_GW" dev "$DEV" table "$RR_TAB" proto ra hoplimit "$RR_HOP" metric "$RR_MET" expires "$RR_LIFE" 2>>"$LOG"
        else
            ip -6 route replace default via "$RR_GW" dev "$DEV" table "$RR_TAB" expires "$RR_LIFE" 2>>"$LOG"
        fi
    fi
}

# ================= 状态输出（只读） =================
print_status() {
    read_conf
    detect_operator
    detect_iface
    if [ -n "$DEV" ]; then
        read_route
    fi
    read_last_result

    WATCH_RUNNING=0
    WP=$(cat "$PID_FILE" 2>/dev/null)
    if is_uint "$WP" && [ -d "/proc/$WP" ] && grep -q 'refresh_route_watch[.]sh' "/proc/$WP/cmdline" 2>/dev/null; then
        WATCH_RUNNING=1
    fi
    BOOT_ON=0
    grep -qF "$WATCH_PATH" "$BOOT_PATH" 2>/dev/null && BOOT_ON=1
    INSTALLED=0
    [ -f "$STATE_DIR/refresh_route.sh" ] && INSTALLED=1
    RD_OK=missing
    [ -x "$RDISC6" ] && RD_OK=ok

    WI=3600
    if [ -f "$WATCH_CONF" ]; then
        WIV=$(sed -n 's/^INTERVAL=//p' "$WATCH_CONF" 2>/dev/null | head -n 1 | tr -d '\r\n \t')
        [ -n "$WIV" ] || WIV=$(head -n 1 "$WATCH_CONF" 2>/dev/null | tr -d '\r\n \t')
        if is_uint "$WIV" && [ "$WIV" -ge 60 ] 2>/dev/null; then
            WI=$WIV
        fi
    fi

    printf 'OP_RAW=%s\n' "$OP_RAW"
    printf 'OP_KEY=%s\n' "$OP_KEY"
    printf 'OP_NAME=%s\n' "$OP_NAME"
    printf 'IFACE=%s\n' "$DEV"
    printf 'IFACE_COUNT=%s\n' "$IFACE_COUNT"
    printf 'IFACE_REASON=%s\n' "$IFACE_REASON"
    printf 'IFACE_LIST=%s\n' "$IFACE_LIST"
    printf 'GW=%s\n' "$GW"
    printf 'TABLE=%s\n' "$TABLE"
    printf 'EXPIRES=%s\n' "$EXPIRES"
    printf 'ROUTE_STATE=%s\n' "$ROUTE_STATE"
    printf 'ROUTE_LINE=%s\n' "$ROUTE_LINE"
    printf 'RDISC6=%s\n' "$RD_OK"
    printf 'WATCH=%s\n' "$WATCH_RUNNING"
    printf 'BOOT=%s\n' "$BOOT_ON"
    printf 'INST=%s\n' "$INSTALLED"
    printf 'WATCH_INTERVAL=%s\n' "$WI"
    printf 'CONF_MODE=%s\n' "$MODE"
    printf 'CONF_THRESHOLD=%s\n' "$THRESHOLD"
    printf 'CONF_ALLOW_UNKNOWN=%s\n' "$ALLOW_UNKNOWN_OPERATOR"
    printf 'CONF_PING_ENABLE=%s\n' "$PING_ENABLE"
    printf 'CONF_PING_TARGET=%s\n' "$PING_TARGET"
    printf 'CONF_MIN_RETRY=%s\n' "$MIN_RETRY"
    printf 'CONF_RDISC6_TIMEOUT=%s\n' "$RDISC6_TIMEOUT"
    printf 'CONF_SETTLE_TRIES=%s\n' "$SETTLE_TRIES"
    printf 'LR_TIME=%s\n' "$LR_TIME"
    printf 'LR_RESULT=%s\n' "$LR_RESULT"
    printf 'LR_CODE=%s\n' "$LR_CODE"
    printf 'LR_OP_NAME=%s\n' "$LR_OP_NAME"
    printf 'LR_IFACE=%s\n' "$LR_IFACE"
    printf 'LR_GW=%s\n' "$LR_GW"
    printf 'LR_ROUTE_STATE=%s\n' "$LR_ROUTE_STATE"
    printf 'LR_EXPIRES=%s\n' "$LR_EXPIRES"
    printf 'LR_RA_RECEIVED=%s\n' "$LR_RA_RECEIVED"
    printf 'LR_ROUTE_REFRESHED=%s\n' "$LR_ROUTE_REFRESHED"
    printf 'LR_CONNECTIVITY=%s\n' "$LR_CONNECTIVITY"
    printf 'LR_STRATEGY=%s\n' "$LR_STRATEGY"
    printf 'LR_MESSAGE=%s\n' "$LR_MESSAGE"
}

# ================= 主流程 =================
ARG=$1
FORCE=0
RS_ONLY=0
STATUS_ONLY=0
DELETE_ONLY=0
PING_ONLY=0
case "$ARG" in
    '') ;;
    --force) FORCE=1 ;;
    --rs-only) RS_ONLY=1 ;;
    --status) STATUS_ONLY=1 ;;
    --delete-route) DELETE_ONLY=1 ;;
    --ping) PING_ONLY=1 ;;
    *)
        printf '未知参数: %s\n' "$ARG" >&2
        exit 2
        ;;
esac

read_conf

if [ "$STATUS_ONLY" = 1 ]; then
    print_status
    exit 0
fi

# ---- 只做连通性测试（供面板按钮使用，不读写路由） ----
if [ "$PING_ONLY" = 1 ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null
    touch "$LOG" 2>/dev/null || LOG=/dev/null
    test_connectivity
    printf 'PING=%s\n' "$CONNECTIVITY"
    exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null
touch "$LOG" 2>/dev/null || LOG=/dev/null
trim_log

log "===== 开始检查（模式: $MODE） ====="

# ---- 并发锁 ----
if ! acquire_lock; then
    [ -n "$LP" ] || LP=未知
    log "已有实例在运行（持锁 PID: $LP），跳过本次"
    RA_RECEIVED=not_attempted
    write_result skip 2 "已有实例在运行（PID: $LP），跳过本次"
    exit 2
fi
if [ "$(cat "$LOCK/pid" 2>/dev/null)" != "$$" ]; then
    # 锁已被对方重建：忽略 EXIT trap，绝不能删掉对方的锁
    trap '' EXIT INT TERM HUP
    log "并发锁竞态让位，跳过本次"
    write_result skip 2 "并发锁竞态让位，跳过本次"
    exit 2
fi

# ---- 手动删除当前路由（仅高级模式；只删实际读到的那一条，不猜测） ----
if [ "$DELETE_ONLY" = 1 ]; then
    if [ "$MODE" != advanced ]; then
        log "拒绝删除：该操作只允许在高级修复模式下执行"
        printf 'DELETE_RESULT=refused\n'
        printf 'DELETE_REASON=高级修复模式未开启\n'
        exit 2
    fi
    detect_iface
    if [ -z "$DEV" ]; then
        if [ "$IFACE_REASON" = ambiguous_multi ]; then
            log "删除路由失败：存在多个候选蜂窝接口（$IFACE_LIST）"
            printf 'DELETE_RESULT=ambiguous\n'
            printf 'DELETE_REASON=存在多个候选接口，拒绝选择\n'
            exit 2
        fi
        log "删除路由失败：未找到可用蜂窝接口"
        printf 'DELETE_RESULT=fail\n'
        printf 'DELETE_REASON=未找到可用蜂窝接口\n'
        exit 1
    fi
    read_route
    if [ "$ROUTE_STATE" = missing ]; then
        log "删除路由：当前没有 IPv6 默认路由，无需删除"
        printf 'DELETE_RESULT=none\n'
        printf 'DELETE_REASON=当前没有 IPv6 默认路由\n'
        exit 0
    fi
    if [ "$ROUTE_STATE" = static ]; then
        log "删除路由：当前是静态路由（无 expires），拒绝删除"
        printf 'DELETE_RESULT=refused\n'
        printf 'DELETE_REASON=静态路由不自动删除\n'
        exit 2
    fi
    if [ "$GW_OK" != 1 ] || [ "$TABLE_OK" != 1 ]; then
        log "删除路由失败：网关或路由表名未通过校验，拒绝执行"
        printf 'DELETE_RESULT=refused\n'
        printf 'DELETE_REASON=网关或表名未通过校验\n'
        exit 2
    fi
    log "手动删除 IPv6 默认路由：$ROUTE_LINE"
    if delete_route; then
        read_route
        if [ "$ROUTE_STATE" = missing ]; then
            log "删除路由成功；IPv6 默认路由暂时真空，等待 RA 或手动刷新"
            printf 'DELETE_RESULT=ok\n'
            printf 'DELETE_REASON=已删除当前 IPv6 默认路由\n'
            exit 0
        fi
        log "删除路由失败：回读仍存在默认路由"
        printf 'DELETE_RESULT=fail\n'
        printf 'DELETE_REASON=删除后回读仍存在默认路由\n'
        exit 1
    fi
    log "删除路由失败：ip route del 执行失败"
    printf 'DELETE_RESULT=fail\n'
    printf 'DELETE_REASON=ip route del 执行失败\n'
    exit 1
fi

# ---- 运营商 ----
detect_operator
if [ "$OP_KEY" = empty ] || [ "$OP_KEY" = unknown ]; then
    if [ "$OP_KEY" = empty ]; then
        log "诊断：gsm.sim.operator.alpha 为空/不可读，无法识别运营商"
    else
        log "诊断：无法识别运营商（gsm.sim.operator.alpha = '$OP_RAW'）"
    fi
    log "诊断：为避免误操作，不执行任何路由删除/替换；3gnet 是 APN，不能作为运营商标识"
    if [ "$ALLOW_UNKNOWN_OPERATOR" != 1 ]; then
        log "诊断：已安全跳过。如确认设备接口与 IPv6 环境正常，可在面板开启“未知运营商兼容模式”（仅发送 RS）"
        write_result skip 2 "运营商属性为空或无法识别，已安全跳过；可显式开启未知运营商兼容模式"
        exit 2
    fi
    log "警告：已显式开启未知运营商兼容模式，仅允许发送 RS，不会删除/替换路由"
fi

# ---- 接口 ----
detect_iface
if [ -z "$DEV" ]; then
    if [ "$IFACE_REASON" = ambiguous_multi ]; then
        log "诊断：检测到多个活动蜂窝接口（$IFACE_LIST），无法安全判定目标接口，已放弃本次操作"
        log "诊断：请保留仅一个带全局 IPv6 的 sipa_ethN，或等待默认路由出现后再试"
        write_result skip 2 "存在多个候选蜂窝接口，无法安全判定目标接口（$IFACE_LIST）"
        exit 2
    fi
    log "诊断：未找到 state UP 且带全局 IPv6 地址的 sipa_eth0~15 蜂窝接口"
    write_result fail 1 "未找到可用的 sipa_ethN 蜂窝接口（需 state UP 且带全局 IPv6 地址）"
    exit 1
fi
log "运营商: $OP_NAME（原始值: '$OP_RAW'）"
log "数据口: $DEV（候选数 $IFACE_COUNT，判定 $IFACE_REASON）"

# ---- 当前路由 ----
read_route
case "$ROUTE_STATE" in
    missing)
        log "当前 IPv6 默认路由：不存在（可能已到期）"
        ;;
    static)
        log "当前 IPv6 默认路由：静态（无 expires），无需处理"
        ;;
    healthy)
        log "当前 IPv6 默认路由：$ROUTE_LINE"
        log "剩余有效期 $EXPIRES 秒，不低于阈值 $THRESHOLD 秒，无需刷新"
        ;;
    low)
        log "当前 IPv6 默认路由：$ROUTE_LINE"
        log "剩余有效期 $EXPIRES 秒，低于阈值 $THRESHOLD 秒，需要刷新"
        ;;
    expired)
        log "当前 IPv6 默认路由：$ROUTE_LINE"
        log "剩余有效期已到期（$EXPIRES 秒），需要恢复"
        ;;
esac
[ "$GW_OK" = 1 ] && log "默认网关: $GW（表: $TABLE）"
[ "$GW_OK" = 0 ] && [ -n "$GW" ] && log "警告：解析到的网关不在 fe80::/10，安全模式不会使用它"

# ---- 最小重试间隔 ----
if [ "$FORCE" != 1 ] && [ "$RS_ONLY" != 1 ]; then
    if ! check_cooldown; then
        log "距上次刷新尝试不足 $MIN_RETRY 秒（剩余约 $COOLDOWN_LEFT 秒），跳过，避免快速重试"
        RA_RECEIVED=not_attempted
        write_result skip 2 "距上次尝试不足 $MIN_RETRY 秒，等待下次调度（剩余 $COOLDOWN_LEFT 秒）"
        exit 2
    fi
fi

# ---- 手动只发 RS ----
if [ "$RS_ONLY" = 1 ]; then
    if [ ! -x "$RDISC6" ]; then
        log "错误：rdisc6 不可用，无法发送 RS"
        write_result fail 1 "rdisc6 未安装或不可执行，无法发送 RS"
        exit 1
    fi
    PRE_STATE=$ROUTE_STATE
    if is_uint "$EXPIRES"; then PRE_EXP=$EXPIRES; else PRE_EXP=0; fi
    log "手动发送 Router Solicitation（不修改路由）..."
    send_rs
    if [ "$RA_RECEIVED" = yes ]; then
        read_route
        if ! route_usable; then
            log "结果：已收到 RA，但内核默认路由仍不可用（状态 $ROUTE_STATE，剩余 $EXPIRES）"
            test_connectivity
            ROUTE_REFRESHED=no
            STRATEGY=none
            write_result fail 1 "已收到 RA，但 IPv6 默认路由未出现或不可用"
            exit 1
        fi
        if [ "$PRE_STATE" = missing ]; then
            ROUTE_REFRESHED=yes
            STRATEGY=nd_restore
        elif { [ "$PRE_STATE" != static ] && [ "$ROUTE_STATE" = static ]; } || { is_uint "$EXPIRES" && [ "$EXPIRES" -gt "$PRE_EXP" ]; }; then
            ROUTE_REFRESHED=yes
            STRATEGY=nd_renew
        else
            ROUTE_REFRESHED=no
            STRATEGY=none
        fi
        test_connectivity
        log "结果：已收到 RA；路由刷新=$ROUTE_REFRESHED（当前 $ROUTE_STATE，剩余 $EXPIRES 秒）"
        write_result ok 0 "已收到 RA；路由已存在（刷新=$ROUTE_REFRESHED，剩余 $EXPIRES 秒）"
        exit 0
    fi
    test_connectivity
    ROUTE_REFRESHED=no
    STRATEGY=none
    write_result fail 1 "未收到 RA（rdisc6 退出码 $RS_RC）"
    exit 1
fi

# 有效期充足或静态路由：不做任何修改。
if [ "$ROUTE_STATE" = healthy ] || [ "$ROUTE_STATE" = static ]; then
    test_connectivity
    ROUTE_REFRESHED=not_needed
    STRATEGY=none
    if [ "$ROUTE_STATE" = static ]; then
        write_result ok 0 "默认路由为静态（无 expires），无需刷新"
    else
        write_result ok 0 "默认有效期充足（$EXPIRES 秒），无需刷新"
    fi
    exit 0
fi


PRE_STATE=$ROUTE_STATE
if is_uint "$EXPIRES"; then PRE_EXP=$EXPIRES; else PRE_EXP=0; fi

# ---- 安全模式：只发 RS，让内核续期/重建 ----
if [ "$MODE" = safe ]; then
    if [ ! -x "$RDISC6" ]; then
        log "错误：未安装 rdisc6；安全模式不会删除或手工替换路由，本次不执行任何修改"
        log "请先在面板下载/上传/导入 rdisc6，再重试"
        write_result fail 1 "rdisc6 未安装或不可执行；安全模式不修改路由，请先安装 rdisc6"
        exit 1
    fi
    touch_attempt
    log "安全模式：发送 RS（不删除、不替换现有路由）..."
    send_rs
    wait_route
    if [ "$REFRESH_OK" = 1 ]; then
        read_route
        if [ "$PRE_STATE" = missing ]; then
            STRATEGY=nd_restore
        else
            STRATEGY=nd_renew
        fi
        ROUTE_REFRESHED=yes
        set_strategy "$STRATEGY"
        log "刷新结果：路由已验证刷新（$ROUTE_STATE，剩余 $EXPIRES 秒，策略 $STRATEGY）"
        test_connectivity
        if [ "$RA_RECEIVED" = yes ]; then
            write_result ok 0 "收到 RA，IPv6 默认路由已验证刷新（剩余 $EXPIRES 秒，策略 $STRATEGY）"
        else
            log "警告：路由已刷新，但 rdisc6 未确认收到 RA（退出码 $RS_RC）"
            write_result ok 0 "路由已刷新，但未确认收到 RA（rdisc6 退出码 $RS_RC）"
        fi
        exit 0
    fi
    read_route
    ROUTE_REFRESHED=no
    STRATEGY=none
    if [ "$RA_RECEIVED" = yes ]; then
        NEW_EXP_TEXT=$EXPIRES
        [ -n "$NEW_EXP_TEXT" ] || NEW_EXP_TEXT=无
        log "失败：收到 RA，但默认路由未出现/未续期（旧 $PRE_EXP 秒，新 $NEW_EXP_TEXT）"
        write_result fail 1 "收到 RA，但 IPv6 默认路由未出现或有效期未刷新（旧 $PRE_EXP 秒，新 $NEW_EXP_TEXT）"
    else
        log "失败：未收到 RA，默认路由未恢复（仍为 $ROUTE_STATE）"
        write_result fail 1 "未收到 RA，IPv6 默认路由未恢复（$ROUTE_STATE）"
    fi
    test_connectivity
    exit 1
fi

# ---- 高级模式（默认关闭）：保留原版 ND 重建 / RA 同构 replace ----
log "警告：高级修复模式已启用（可能短暂中断 IPv6），仅在安全模式无法恢复时使用"
touch_attempt
if [ "$ROUTE_STATE" != missing ] && [ "$TABLE_OK" = 1 ] && [ "$GW_OK" = 1 ]; then
    ORIG_GW=$GW
    ORIG_TABLE=$TABLE
    ORIG_METRIC=$METRIC
    ORIG_HOPLIMIT=$HOPLIMIT
    if is_uint "$EXPIRES"; then ORIG_EXP=$EXPIRES; else ORIG_EXP=0; fi
    ORIG_STATE=$ROUTE_STATE
else
    ORIG_GW=""
    ORIG_TABLE=""
    ORIG_METRIC=1024
    ORIG_HOPLIMIT=255
    ORIG_EXP=0
    ORIG_STATE=$ROUTE_STATE
fi

if [ -x "$RDISC6" ]; then
    log "高级模式第 1 步：保留现有路由发送 RS..."
    send_rs
    wait_route
    if [ "$REFRESH_OK" = 1 ]; then
        read_route
        if [ "$PRE_STATE" = missing ]; then
            STRATEGY=nd_restore
        else
            STRATEGY=nd_renew
        fi
        ROUTE_REFRESHED=yes
        set_strategy "$STRATEGY"
        log "刷新结果：路由已验证刷新（$STRATEGY，剩余 $EXPIRES 秒）"
        test_connectivity
        write_result ok 0 "高级模式：已收到 RA，路由已验证刷新（策略 $STRATEGY）"
        exit 0
    fi
    log "第 1 次 RS 未刷新路由"
else
    log "高级模式：rdisc6 不可用，跳过 RS 步骤"
fi

# 没有 rdisc6 时，若已有可验证的网关/表名，直接同构 replace（不删除）。
if [ ! -x "$RDISC6" ]; then
    if [ -n "$ORIG_GW" ] && [ -n "$ORIG_TABLE" ] && [ "$ORIG_EXP" -gt 0 ] 2>/dev/null; then
        log "高级模式：用已确认网关 $ORIG_GW 重建 RA 同构路由..."
        if replace_route "$ORIG_GW" "$RA_LIFETIME" 1 "$ORIG_METRIC" "$ORIG_HOPLIMIT" "$ORIG_TABLE"; then
            ROUTE_REFRESHED=yes
            STRATEGY=ra_replace
        else
            log "完整属性 replace 失败，降级为最小参数"
            if replace_route "$ORIG_GW" "$RA_LIFETIME" 0 "$ORIG_METRIC" "$ORIG_HOPLIMIT" "$ORIG_TABLE"; then
                ROUTE_REFRESHED=yes
                STRATEGY=ra_replace_min
            fi
        fi
        read_route
        if [ "$ROUTE_REFRESHED" = yes ] && route_usable; then
            set_strategy "$STRATEGY"
            log "刷新结果：RA 同构路由已建立（$STRATEGY，剩余 $EXPIRES 秒）"
            test_connectivity
            write_result ok 0 "高级模式：RA 同构路由已建立（策略 $STRATEGY）"
            exit 0
        fi
        log "高级模式：同构 replace 后回读仍无有效路由"
    fi
    ROUTE_REFRESHED=no
    STRATEGY=none
    test_connectivity
    write_result fail 1 "高级模式：缺少 rdisc6 且无已验证网关，拒绝猜测网关重建路由"
    exit 1
fi

# 第 2 步：删除当前实际读到的那条路由后重试 RS（仅在网关/表名已验证时）。
if [ -n "$ORIG_GW" ] && [ -n "$ORIG_TABLE" ] && [ "$ORIG_EXP" -gt 0 ] 2>/dev/null; then
    read_route
    if [ "$ROUTE_STATE" = missing ] || [ "$GW" != "$ORIG_GW" ] || [ "$TABLE" != "$ORIG_TABLE" ]; then
        log "高级模式：路由已发生变化，取消删除（避免误删）"
    else
        log "高级模式第 2 步：删除当前默认路由后重试 RS（IPv6 会短暂真空）..."
        if delete_route; then
            PRE_STATE=missing
            PRE_EXP=0
            send_rs
            wait_route
            if [ "$REFRESH_OK" = 1 ]; then
                read_route
                ROUTE_REFRESHED=yes
                STRATEGY=nd_rebuild
                set_strategy "$STRATEGY"
                log "刷新结果：内核已从空表重建原生 RA 路由（$STRATEGY）"
                test_connectivity
                write_result ok 0 "高级模式：内核已重建原生 RA 路由（策略 $STRATEGY）"
                exit 0
            fi
            log "删除后 RS 仍未重建路由，尝试 RA 同构 replace..."
            if replace_route "$ORIG_GW" "$RA_LIFETIME" 1 "$ORIG_METRIC" "$ORIG_HOPLIMIT" "$ORIG_TABLE"; then
                ROUTE_REFRESHED=yes
                STRATEGY=ra_replace
            else
                log "完整属性 replace 失败，降级为最小参数"
                if replace_route "$ORIG_GW" "$RA_LIFETIME" 0 "$ORIG_METRIC" "$ORIG_HOPLIMIT" "$ORIG_TABLE"; then
                    ROUTE_REFRESHED=yes
                    STRATEGY=ra_replace_min
                fi
            fi
            read_route
            if [ "$ROUTE_REFRESHED" = yes ] && route_usable; then
                set_strategy "$STRATEGY"
                log "刷新结果：已用 RA 同构路由恢复（$STRATEGY）"
                test_connectivity
                write_result ok 0 "高级模式：已用 RA 同构路由恢复（策略 $STRATEGY）"
                exit 0
            fi
            ROUTE_REFRESHED=no
            STRATEGY=none
            log "严重：重建失败，立即尝试恢复删除前的默认路由"
            if [ "$ORIG_EXP" -gt 0 ] 2>/dev/null; then
                replace_route "$ORIG_GW" "$ORIG_EXP" 1 "$ORIG_METRIC" "$ORIG_HOPLIMIT" "$ORIG_TABLE"
                read_route
                if route_usable; then
                    log "已恢复删除前的默认路由（剩余约 $ORIG_EXP 秒），避免持续断网"
                    test_connectivity
                    write_result fail 1 "高级模式重建失败，已恢复删除前的默认路由（剩余约 $ORIG_EXP 秒）"
                    exit 1
                fi
            fi
            log "严重：默认路由恢复失败，IPv6 可能中断，请立即检查"
            test_connectivity
            write_result fail 1 "高级模式重建与恢复均失败，IPv6 默认路由可能丢失，请立即检查"
            exit 1
        fi
        log "高级模式：删除路由命令执行失败，未继续重建"
    fi
fi

# 第 3 步：路由完全丢失且无已验证网关/表名时，只允许 RS，不猜测网关。
if [ -x "$RDISC6" ] && [ "$ROUTE_STATE" = missing ]; then
    log "高级模式第 3 步：路由缺失且无已验证网关，仅再次发送 RS..."
    send_rs
    wait_route
    if [ "$REFRESH_OK" = 1 ]; then
        read_route
        ROUTE_REFRESHED=yes
        STRATEGY=nd_restore
        set_strategy "$STRATEGY"
        test_connectivity
        write_result ok 0 "高级模式：RS 后内核已恢复默认路由（策略 $STRATEGY）"
        exit 0
    fi
fi

ROUTE_REFRESHED=no
STRATEGY=none
log "失败：所有可用策略均未能刷新或恢复 IPv6 默认路由"
test_connectivity
write_result fail 1 "所有可用策略均未能刷新或恢复 IPv6 默认路由"
exit 1
