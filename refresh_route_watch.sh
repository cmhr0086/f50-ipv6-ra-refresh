#!/system/bin/sh
#
# refresh_route_watch.sh —— IPv6 RA 默认路由保活调度器（由 UFI-TOOLS 插件生成）
#
# 职责：每隔 INTERVAL 秒执行一次 refresh_route.sh。
# 单实例：mkdir 原子锁 + /proc cmdline 存活校验，双击“启动调度”、开机脚本重复
# 拉起、残留多行自启都不会产生第二个调度器。
# 停止：kill 本进程即可；trap 会清理自己的 pid 文件与锁，不会留下循环任务。
#
# 配置：$STATE_DIR/refresh_route_watch.conf
#   支持 INTERVAL=3600 或直接写 3600（兼容旧版纯数字格式）
#
# 测试环境变量：RRA_STATE_DIR 可覆盖默认目录（设备上无需设置）。

STATE_DIR=$RRA_STATE_DIR
[ -n "$STATE_DIR" ] || STATE_DIR=/data/xl_ipv6_ra

CONF=$STATE_DIR/refresh_route_watch.conf
PIDF=$STATE_DIR/refresh_route_watch.pid
WLOCK=$STATE_DIR/.watcher.lock
CORE=$STATE_DIR/refresh_route.sh
INTERVAL=3600
CHILD_PID=""

if [ -f "$CONF" ]; then
    V=$(sed -n 's/^INTERVAL=//p' "$CONF" 2>/dev/null | head -n 1 | tr -d '\r\n \t')
    [ -n "$V" ] || V=$(head -n 1 "$CONF" 2>/dev/null | tr -d '\r\n \t')
    case "$V" in
        ''|*[!0-9]*) ;;
        *) INTERVAL=$V ;;
    esac
fi
if ! [ "$INTERVAL" -ge 60 ] 2>/dev/null; then
    INTERVAL=3600
fi
if [ "$INTERVAL" -gt 86400 ] 2>/dev/null; then
    INTERVAL=86400
fi

watch_cleanup() {
    [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
    if [ "$(cat "$WLOCK/pid" 2>/dev/null)" = "$" ]; then
        rm -rf "$WLOCK" 2>/dev/null
    fi
    if [ "$(cat "$PIDF" 2>/dev/null)" = "$" ]; then
        rm -f "$PIDF" 2>/dev/null
    fi
}

take_wlock() {
    mkdir "$WLOCK" 2>/dev/null || return 1
    printf '%s\n' "$$" > "$WLOCK/pid"
    printf '%s\n' "$$" > "$PIDF"
    # 退出时只清理仍属于自己的锁与 PID，避免“停旧起新”时误删继任者刚建好的文件。
    trap 'watch_cleanup' EXIT
    trap 'exit 0' INT TERM HUP
    return 0
}

if ! take_wlock; then
    OP=$(cat "$WLOCK/pid" 2>/dev/null)
    if [ -n "$OP" ] && [ -d "/proc/$OP" ] && grep -q 'refresh_route_watch[.]sh' "/proc/$OP/cmdline" 2>/dev/null; then
        exit 0
    fi
    rm -rf "$WLOCK"
    take_wlock || exit 0
fi
[ "$(cat "$WLOCK/pid" 2>/dev/null)" = "$$" ] || exit 0

while true; do
    if [ -f "$CORE" ]; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 180 sh "$CORE" >/dev/null 2>&1 &
        else
            sh "$CORE" >/dev/null 2>&1 &
        fi
        CHILD_PID=$!
        wait "$CHILD_PID" 2>/dev/null || :
        CHILD_PID=""
    fi
    sleep "$INTERVAL" &
    CHILD_PID=$!
    wait "$CHILD_PID" 2>/dev/null || :
    CHILD_PID=""
done
