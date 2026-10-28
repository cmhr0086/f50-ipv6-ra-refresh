#!/bin/sh
# 运行全部静态检查 + 模拟测试。
#
# 普通 Linux：
#   sh tests/run_all.sh
#
# Windows Git Bash（node 不在 PATH 时）：
#   RRA_NODE=/path/to/node.exe RRA_SH=/path/to/sh.exe sh tests/run_all.sh

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NODE=${RRA_NODE:-}
SH=${RRA_SH:-sh}

if [ -z "$NODE" ]; then
    if command -v node >/dev/null 2>&1; then
        NODE=node
    else
        printf '找不到 node；请设置 RRA_NODE 指向 node 可执行文件\n' >&2
        exit 1
    fi
fi

printf '== 静态检查 ==\n'
RRA_SH="$SH" "$NODE" "$ROOT/tests/check_plugin.mjs" || exit 1

printf '\n== 模拟测试 ==\n'
sh "$ROOT/tests/run_tests.sh"
