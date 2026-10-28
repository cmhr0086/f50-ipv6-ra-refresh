#!/bin/sh
# 普通 Linux / Git Bash 上可运行的模拟测试。
#
# 不连接真实 F50：用 tests/mocks 下的 ip / getprop / rdisc6 / ping6 模拟
# Android 内核路由表、运营商属性、RA 响应与 ping6。
#
# 运行：sh tests/run_tests.sh
# 依赖：POSIX sh、awk、sed、grep、tr、head、tail、mktemp、timeout

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CORE=$ROOT/refresh_route2.sh
WATCH=$ROOT/refresh_route_watch.sh
MOCK_SRC=$ROOT/tests/mocks

PASS=0
FAIL=0
SKIP=0
CASE=""
TMP=""
WATCH_PID=""

cleanup() {
    if [ -n "$WATCH_PID" ]; then
        kill -9 "$WATCH_PID" 2>/dev/null
    fi
    if [ -n "$TMP" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT INT TERM HUP

pass() {
    PASS=$((PASS + 1))
    printf '[PASS] %s: %s\n' "$CASE" "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf '[FAIL] %s: %s\n' "$CASE" "$1"
    if [ -f "$OUT" ]; then
        tail -n 12 "$OUT" 2>/dev/null | sed 's/^/       | /'
    fi
}

skip() {
    SKIP=$((SKIP + 1))
    printf '[SKIP] %s: %s\n' "$CASE" "$1"
}

assert_rc() {
    if [ "$RC" = "$1" ]; then pass "exit=$1"; else fail "exit=$RC, expected $1"; fi
}

assert_eq() {
    if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (got '$1', expected '$2')"; fi
}

assert_contains() {
    if printf '%s' "$1" | grep -qF "$2"; then pass "$3"; else fail "$3 (missing '$2')"; fi
}

assert_not_contains() {
    if printf '%s' "$1" | grep -qF "$2"; then fail "$3 (unexpected '$2')"; else pass "$3"; fi
}

assert_file_contains() {
    if [ -f "$1" ] && grep -qF "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3 (file '$1' missing '$2')"; fi
}

assert_file_absent() {
    if [ -e "$1" ]; then fail "$2 ('$1' exists)"; else pass "$2"; fi
}

assert_result() {
    RV=$(sed -n "s/^$1=//p" "$RRA_STATE_DIR/last_result" 2>/dev/null | head -n 1)
    if [ "$RV" = "$2" ]; then pass "$1=$2"; else fail "$1='$RV', expected '$2'"; fi
}

assert_status() {
    SV=$(sed -n "s/^$1=//p" "$OUT" 2>/dev/null | head -n 1)
    if [ "$SV" = "$2" ]; then pass "$1=$2"; else fail "$1='$SV', expected '$2'"; fi
}

assert_no_dangerous_route_ops() {
    if [ -f "$MOCK_DIR/ip_calls" ] && grep -Eq 'route (del|replace)' "$MOCK_DIR/ip_calls"; then
        fail 'safe path must not run ip route del/replace'
    else
        pass 'safe path did not delete/replace routes'
    fi
}

assert_rdisc_calls() {
    if [ "$1" = 0 ]; then
        if [ ! -f "$MOCK_DIR/rdisc6_calls" ]; then pass 'rdisc6 not called'; return; fi
    fi
    CNT=0
    [ -f "$MOCK_DIR/rdisc6_calls" ] && CNT=$(wc -l < "$MOCK_DIR/rdisc6_calls" | tr -d ' ')
    if [ "$CNT" = "$1" ]; then pass "rdisc6 calls=$1"; else fail "rdisc6 calls=$CNT, expected $1"; fi
}

write_conf() {
    {
        printf 'MODE=%s\n' "$1"
        printf 'THRESHOLD=%s\n' "$2"
        printf 'ALLOW_UNKNOWN_OPERATOR=%s\n' "$3"
        printf 'PING_ENABLE=%s\n' "$4"
        printf 'MIN_RETRY=%s\n' "$5"
        printf 'SETTLE_TRIES=%s\n' "$6"
        printf 'RDISC6_TIMEOUT=3\n'
        printf 'PING_TARGET=2400:3200::1\n'
    } > "$RRA_CONF"
}

new_case() {
    if [ -n "$WATCH_PID" ]; then
        kill -9 "$WATCH_PID" 2>/dev/null
        WATCH_PID=""
    fi
    if [ -n "$TMP" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    CASE=$1
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/rra-test.XXXXXX") || {
        printf 'mktemp failed\n'
        exit 1
    }
    MOCK_DIR=$TMP/mock
    mkdir -p "$MOCK_DIR" "$TMP/state" "$TMP/bin"
    cp "$MOCK_SRC/ip" "$MOCK_SRC/getprop" "$MOCK_SRC/rdisc6" "$MOCK_SRC/ping6" "$TMP/bin/"
    chmod +x "$TMP/bin/"*
    : > "$MOCK_DIR/links"
    : > "$MOCK_DIR/addrs"
    : > "$MOCK_DIR/routes"
    : > "$MOCK_DIR/operator"
    echo ok > "$MOCK_DIR/ping_mode"
    echo noanswer > "$MOCK_DIR/rdisc6_mode"
    echo "sipa_eth0:UP" > "$MOCK_DIR/links"
    echo "sipa_eth0:2408:8471:160e:2e9::1/64" > "$MOCK_DIR/addrs"
    # 让 --status 的 INST 字段与真实设备一致（脚本已安装到标准目录）
    cp "$CORE" "$TMP/state/refresh_route.sh"

    export MOCK_DIR
    export RRA_STATE_DIR="$TMP/state"
    export RRA_CONF="$TMP/state/refresh_route.conf"
    export RRA_LOG="$TMP/state/refresh_route.log"
    export RRA_RDISC6="$TMP/bin/rdisc6"
    export RRA_PING6="$TMP/bin/ping6"
    export RRA_BOOT="$TMP/boot.sh"
    export RRA_PATH="$TMP/bin:$PATH"

    OUT=$TMP/out.txt
    RC=0
    write_conf safe 21600 0 1 300 1
}

run_core() {
    ( cd "$TMP" && sh "$CORE" "$@" ) > "$OUT" 2>&1
    RC=$?
}

route_line() {
    printf 'default via %s dev %s table %s proto ra metric 1024 expires %ssec\n' "$1" "$2" "$3" "$4"
}

# ---------------------------------------------------------------------------
# 场景
# ---------------------------------------------------------------------------

test_unicom_healthy() {
    new_case "unicom healthy 12h"
    echo "中国联通" > "$MOCK_DIR/operator"
    route_line fe80::2 sipa_eth0 sipa_eth0 43200 > "$MOCK_DIR/routes"
    echo ok_renew > "$MOCK_DIR/rdisc6_mode"
    run_core
    assert_rc 0
    assert_result RESULT ok
    assert_result OP_KEY unicom
    assert_result ROUTE_REFRESHED not_needed
    assert_result ROUTE_STATE healthy
    assert_result CONNECTIVITY ok
    assert_rdisc_calls 0
    assert_no_dangerous_route_ops
    assert_file_contains "$RRA_LOG" "无需刷新" "log says no refresh needed"
}

test_unicom_low() {
    new_case "unicom low 2h"
    echo "中国联通" > "$MOCK_DIR/operator"
    route_line fe80::2 sipa_eth0 sipa_eth0 7200 > "$MOCK_DIR/routes"
    echo ok_renew > "$MOCK_DIR/rdisc6_mode"
    run_core
    assert_rc 0
    assert_result RESULT ok
    assert_result ROUTE_REFRESHED yes
    assert_result RA_RECEIVED yes
    assert_result STRATEGY nd_renew
    assert_result EXPIRES 65535
    assert_rdisc_calls 1
    assert_no_dangerous_route_ops
    assert_file_contains "$RRA_STATE_DIR/last_strategy" "nd_renew" "last_strategy records nd_renew"
}

test_missing_route_restore() {
    new_case "route missing -> RS restores"
    echo "中国联通" > "$MOCK_DIR/operator"
    : > "$MOCK_DIR/routes"
    echo ok_restore > "$MOCK_DIR/rdisc6_mode"
    run_core
    assert_rc 0
    assert_result ROUTE_REFRESHED yes
    assert_result STRATEGY nd_restore
    assert_result RA_RECEIVED yes
    assert_rdisc_calls 1
    assert_no_dangerous_route_ops
    assert_file_contains "$MOCK_DIR/routes" "expires 65535sec" "kernel route table received new RA route"
}

test_ra_but_no_route() {
    new_case "RA received but route absent"
    echo "中国联通" > "$MOCK_DIR/operator"
    : > "$MOCK_DIR/routes"
    echo ok_noroute > "$MOCK_DIR/rdisc6_mode"
    write_conf safe 21600 0 1 300 1
    run_core
    assert_rc 1
    assert_result RESULT fail
    assert_result RA_RECEIVED yes
    assert_result ROUTE_REFRESHED no
    assert_contains "$(sed -n 's/^MESSAGE=//p' "$RRA_STATE_DIR/last_result")" "未出现" "message reports route missing"
    assert_file_contains "$RRA_LOG" "收到 RA，但默认路由未出现" "log distinguishes RA from refresh"
    assert_no_dangerous_route_ops
}

test_no_rdisc6() {
    new_case "rdisc6 missing"
    echo "中国联通" > "$MOCK_DIR/operator"
    route_line fe80::2 sipa_eth0 sipa_eth0 7200 > "$MOCK_DIR/routes"
    export RRA_RDISC6="$TMP/bin/does-not-exist"
    run_core
    assert_rc 1
    assert_result RESULT fail
    assert_contains "$(sed -n 's/^MESSAGE=//p' "$RRA_STATE_DIR/last_result")" "rdisc6" "message asks to install rdisc6"
    assert_rdisc_calls 0
    assert_no_dangerous_route_ops
    assert_file_contains "$RRA_LOG" "不会删除或手工替换路由" "log states no dangerous action"
}

test_iface_and_prefix_change() {
    new_case "interface/prefix change"
    echo "中国联通" > "$MOCK_DIR/operator"
    echo "sipa_eth3:UP" > "$MOCK_DIR/links"
    echo "sipa_eth3:2409:8a00:1234:5678::1/64" > "$MOCK_DIR/addrs"
    route_line fe80::2 sipa_eth3 sipa_eth3 7200 > "$MOCK_DIR/routes"
    echo ok_renew > "$MOCK_DIR/rdisc6_mode"
    run_core --status
    assert_rc 0
    assert_status IFACE sipa_eth3
    assert_status GW fe80::2
    assert_status ROUTE_STATE low
    run_core
    assert_rc 0
    assert_result IFACE sipa_eth3
    assert_result ROUTE_REFRESHED yes
    assert_file_contains "$MOCK_DIR/rdisc6_calls" "sipa_eth3" "RS sent on detected interface"
}

test_operator_variants() {
    while IFS='|' read -r OP KEY NAME; do
        new_case "operator $OP"
        printf '%s\n' "$OP" > "$MOCK_DIR/operator"
        route_line fe80::2 sipa_eth0 sipa_eth0 43200 > "$MOCK_DIR/routes"
        run_core --status
        assert_rc 0
        assert_status OP_KEY "$KEY"
        assert_status OP_NAME "$NAME"
    done <<'EOF'
中国移动|mobile|中国移动
CMCC|mobile|中国移动
China Mobile|mobile|中国移动
,中国移动|mobile|中国移动
中国电信|telecom|中国电信
CTCC|telecom|中国电信
China Telecom|telecom|中国电信
中国联通|unicom|中国联通
CUCC|unicom|中国联通
China Unicom|unicom|中国联通
Unicom|unicom|中国联通
" China Unicom , "|unicom|中国联通
EOF
}

test_operator_empty_and_unknown() {
    new_case "empty operator"
    : > "$MOCK_DIR/operator"
    route_line fe80::2 sipa_eth0 sipa_eth0 7200 > "$MOCK_DIR/routes"
    run_core
    assert_rc 2
    assert_result RESULT skip
    assert_rdisc_calls 0
    assert_no_dangerous_route_ops
    assert_file_contains "$RRA_LOG" "为空/不可读" "log explains empty operator"

    new_case "unknown operator"
    echo "SomeCarrier" > "$MOCK_DIR/operator"
    route_line fe80::2 sipa_eth0 sipa_eth0 7200 > "$MOCK_DIR/routes"
    run_core
    assert_rc 2
    assert_result RESULT skip
    assert_rdisc_calls 0
    assert_file_contains "$RRA_LOG" "无法识别运营商" "log explains unknown operator"
}

test_unknown_compat() {
    new_case "unknown operator compatibility"
    : > "$MOCK_DIR/operator"
    route_line fe80::2 sipa_eth0 sipa_eth0 7200 > "$MOCK_DIR/routes"
    echo ok_renew > "$MOCK_DIR/rdisc6_mode"
    write_conf safe 21600 1 1 300 1
    run_core
    assert_rc 0
    assert_result ROUTE_REFRESHED yes
    assert_rdisc_calls 1
    assert_file_contains "$RRA_LOG" "未知运营商兼容模式" "log records compatibility mode"

    new_case "unknown compatibility without interface"
    : > "$MOCK_DIR/operator"
    : > "$MOCK_DIR/links"
    : > "$MOCK_DIR/addrs"
    write_conf safe 21600 1 1 300 1
    run_core
    assert_rc 1
    assert_rdisc_calls 0
    assert_result RESULT fail
}

test_multi_instance() {
    new_case "concurrent instances"
    echo "中国联通" > "$MOCK_DIR/operator"
    route_line fe80::2 sipa_eth0 sipa_eth0 7200 > "$MOCK_DIR/routes"
    echo ok_renew > "$MOCK_DIR/rdisc6_mode"
    mkdir -p "$RRA_STATE_DIR/.refresh_route.lock"
    sh -c 'sleep 6; :' refresh_route.sh &
    HP=$!
    printf '%s\n' "$HP" > "$RRA_STATE_DIR/.refresh_route.lock/pid"
    sleep 0.3
    if [ -r "/proc/$HP/cmdline" ] && grep -q 'refresh_route[.]sh' "/proc/$HP/cmdline" 2>/dev/null; then
        run_core
        assert_rc 2
        assert_result RESULT skip
        assert_rdisc_calls 0
        assert_file_contains "$RRA_LOG" "已有实例在运行" "second instance backs off"
    else
        skip '/proc cmdline not available on this platform'
    fi
    kill -9 "$HP" 2>/dev/null
    wait "$HP" 2>/dev/null
}

test_cooldown() {
    new_case "failure cooldown"
    echo "中国联通" > "$MOCK_DIR/operator"
    route_line fe80::2 sipa_eth0 sipa_eth0 7200 > "$MOCK_DIR/routes"
    echo noanswer > "$MOCK_DIR/rdisc6_mode"
    write_conf safe 21600 0 1 300 1
    run_core
    assert_rc 1
    assert_rdisc_calls 1
    run_core
    assert_rc 2
    assert_result RESULT skip
    assert_rdisc_calls 1
    run_core --force
    assert_rc 1
    assert_rdisc_calls 2
}

test_expired_and_rs_only() {
    new_case "expired route is refreshed"
    echo "中国联通" > "$MOCK_DIR/operator"
    route_line fe80::2 sipa_eth0 sipa_eth0 -1 > "$MOCK_DIR/routes"
    echo ok_renew > "$MOCK_DIR/rdisc6_mode"
    run_core
    assert_rc 0
    assert_result ROUTE_STATE healthy
    assert_result ROUTE_REFRESHED yes
    assert_result STRATEGY nd_renew
    assert_file_contains "$RRA_LOG" "已到期" "negative expires treated as expired"
    assert_no_dangerous_route_ops

    new_case "manual RS only"
    echo "中国联通" > "$MOCK_DIR/operator"
    route_line fe80::2 sipa_eth0 sipa_eth0 7200 > "$MOCK_DIR/routes"
    echo ok_renew > "$MOCK_DIR/rdisc6_mode"
    run_core --rs-only
    assert_rc 0
    assert_result RA_RECEIVED yes
    assert_result ROUTE_REFRESHED yes
    assert_no_dangerous_route_ops
}

test_static_route() {
    new_case "static route"
    echo "中国联通" > "$MOCK_DIR/operator"
    printf 'default via fe80::2 dev sipa_eth0 proto ra metric 1024\n' > "$MOCK_DIR/routes"
    run_core
    assert_rc 0
    assert_result ROUTE_STATE static
    assert_result ROUTE_REFRESHED not_needed
    assert_rdisc_calls 0
}

test_threshold_and_multiple_candidates() {
    new_case "threshold 12h with 6h default"
    echo "中国联通" > "$MOCK_DIR/operator"
    route_line fe80::2 sipa_eth0 sipa_eth0 43200 > "$MOCK_DIR/routes"
    echo ok_renew > "$MOCK_DIR/rdisc6_mode"
    run_core
    assert_rc 0
    assert_result ROUTE_REFRESHED not_needed
    assert_rdisc_calls 0

    new_case "threshold 18h triggers refresh"
    echo "中国联通" > "$MOCK_DIR/operator"
    route_line fe80::2 sipa_eth0 sipa_eth0 43200 > "$MOCK_DIR/routes"
    echo ok_renew > "$MOCK_DIR/rdisc6_mode"
    write_conf safe 64800 0 1 300 1
    run_core
    assert_rc 0
    assert_result ROUTE_REFRESHED yes
    assert_rdisc_calls 1

    new_case "ambiguous multiple candidates"
    echo "中国联通" > "$MOCK_DIR/operator"
    printf 'sipa_eth0:UP\nsipa_eth1:UP\n' > "$MOCK_DIR/links"
    printf 'sipa_eth0:2408:8471:160e:2e9::1/64\nsipa_eth1:2408:8471:160e:2ea::1/64\n' > "$MOCK_DIR/addrs"
    : > "$MOCK_DIR/routes"
    run_core
    assert_rc 2
    assert_result RESULT skip
    assert_rdisc_calls 0
    assert_file_contains "$RRA_LOG" "多个活动蜂窝接口" "log refuses arbitrary interface choice"
    run_core --status
    assert_status IFACE ""
    assert_status IFACE_REASON ambiguous_multi

    printf 'default via fe80::2 dev sipa_eth1 table sipa_eth1 proto ra metric 1024 expires 43200sec\n' > "$MOCK_DIR/routes"
    run_core --status
    assert_status IFACE sipa_eth1
    assert_status IFACE_REASON multi_with_route
    run_core
    assert_rc 0
    assert_rdisc_calls 0
}

test_status_readonly() {
    new_case "status is read-only"
    echo "中国联通" > "$MOCK_DIR/operator"
    route_line fe80::2 sipa_eth0 sipa_eth0 43200 > "$MOCK_DIR/routes"
    run_core --status
    assert_rc 0
    assert_status INST 1
    assert_status CONF_MODE safe
    assert_file_absent "$RRA_STATE_DIR/.refresh_route.lock" "status did not create lock"
    assert_file_absent "$RRA_LOG" "status did not create log"
}

test_ping() {
    new_case "connectivity test"
    echo ok > "$MOCK_DIR/ping_mode"
    run_core --ping
    assert_rc 0
    assert_contains "$(cat "$OUT")" "PING=ok" "ping ok reported"
    export RRA_PING6="$TMP/bin/no-ping6"
    run_core --ping
    assert_rc 0
    assert_contains "$(cat "$OUT")" "PING=unavailable" "missing ping6 is unavailable, not failure"
}

test_advanced_rebuild() {
    new_case "advanced mode rebuild"
    echo "中国联通" > "$MOCK_DIR/operator"
    route_line fe80::2 sipa_eth0 sipa_eth0 7200 > "$MOCK_DIR/routes"
    echo noanswer > "$MOCK_DIR/rdisc6_mode"
    write_conf advanced 21600 0 1 300 1
    run_core
    assert_rc 0
    assert_result ROUTE_REFRESHED yes
    assert_result STRATEGY ra_replace
    assert_file_contains "$MOCK_DIR/ip_calls" "route del" "advanced mode deleted route after RS failed"
    assert_file_contains "$MOCK_DIR/ip_calls" "route replace" "advanced mode rebuilt route"
    assert_file_contains "$MOCK_DIR/routes" "expires 65535sec" "rebuilt route has lifetime"

    new_case "advanced rebuild and restore both fail"
    echo "中国联通" > "$MOCK_DIR/operator"
    route_line fe80::2 sipa_eth0 sipa_eth0 7200 > "$MOCK_DIR/routes"
    echo noanswer > "$MOCK_DIR/rdisc6_mode"
    : > "$MOCK_DIR/ip_replace_fail"
    write_conf advanced 21600 0 1 300 1
    run_core
    assert_rc 1
    assert_result RESULT fail
    assert_result ROUTE_REFRESHED no
    assert_contains "$(sed -n 's/^MESSAGE=//p' "$RRA_STATE_DIR/last_result")" "重建与恢复均失败" "result reports catastrophic failure honestly"
    assert_file_contains "$RRA_LOG" "默认路由恢复失败" "log reports restore failure"
}

test_delete_route_gate() {
    new_case "delete route requires advanced mode"
    echo "中国联通" > "$MOCK_DIR/operator"
    route_line fe80::2 sipa_eth0 sipa_eth0 7200 > "$MOCK_DIR/routes"
    run_core --delete-route
    assert_rc 2
    assert_contains "$(cat "$OUT")" "DELETE_RESULT=refused" "safe mode refuses deletion"
    assert_file_contains "$MOCK_DIR/routes" "default via" "route still present in safe mode"

    new_case "delete static route refused"
    echo "中国联通" > "$MOCK_DIR/operator"
    printf 'default via fe80::2 dev sipa_eth0 proto ra metric 1024\n' > "$MOCK_DIR/routes"
    write_conf advanced 21600 0 1 300 1
    run_core --delete-route
    assert_rc 2
    assert_contains "$(cat "$OUT")" "DELETE_RESULT=refused" "static route is not deleted"
    assert_file_contains "$MOCK_DIR/routes" "default via" "static route still present"

    new_case "delete route in advanced mode"
    echo "中国联通" > "$MOCK_DIR/operator"
    route_line fe80::2 sipa_eth0 sipa_eth0 7200 > "$MOCK_DIR/routes"
    write_conf advanced 21600 0 1 300 1
    run_core --delete-route
    assert_rc 0
    assert_contains "$(cat "$OUT")" "DELETE_RESULT=ok" "advanced mode deletes only the observed route"
    if [ -s "$MOCK_DIR/routes" ]; then fail 'route table should be empty after deletion'; else pass 'default route deleted'; fi
}

test_watcher_single_instance() {
    new_case "watcher single instance"
    echo "中国联通" > "$MOCK_DIR/operator"
    route_line fe80::2 sipa_eth0 sipa_eth0 43200 > "$MOCK_DIR/routes"
    cp "$CORE" "$RRA_STATE_DIR/refresh_route.sh"
    printf '60\n' > "$RRA_STATE_DIR/refresh_route_watch.conf"
    sh "$WATCH" >/dev/null 2>&1 &
    WATCH_PID=$!
    sleep 1
    if [ ! -f "$RRA_STATE_DIR/refresh_route_watch.pid" ]; then
        fail 'watcher did not write pid file'
        return
    fi
    assert_eq "$(cat "$RRA_STATE_DIR/refresh_route_watch.pid")" "$WATCH_PID" "watcher pid recorded"
    sh "$WATCH" >/dev/null 2>&1
    assert_eq "$(cat "$RRA_STATE_DIR/refresh_route_watch.pid")" "$WATCH_PID" "second watcher did not replace first"
    OLD_PID=$WATCH_PID
    kill -9 "$OLD_PID" 2>/dev/null
    wait "$OLD_PID" 2>/dev/null
    WATCH_PID=""
    sleep 0.3
    if [ -d "/proc/$OLD_PID" ]; then fail 'watcher still running'; else pass 'no watcher loop left after stop'; fi
}

# ---------------------------------------------------------------------------
# 执行
# ---------------------------------------------------------------------------
test_unicom_healthy
test_unicom_low
test_missing_route_restore
test_ra_but_no_route
test_no_rdisc6
test_iface_and_prefix_change
test_operator_variants
test_operator_empty_and_unknown
test_unknown_compat
test_multi_instance
test_cooldown
test_expired_and_rs_only
test_static_route
test_threshold_and_multiple_candidates
test_status_readonly
test_ping
test_advanced_rebuild
test_delete_route_gate
test_watcher_single_instance

printf '\n===== 结果：PASS=%s FAIL=%s SKIP=%s =====\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
