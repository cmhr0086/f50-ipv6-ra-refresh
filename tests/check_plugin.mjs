// 插件静态检查：JS 语法、内嵌脚本同步、Shell 语法、安全默认值与 UI 关键字段。
// 运行：node tests/check_plugin.mjs

import fs from 'node:fs'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const jsRel = '[插件]IPv6 RA路由修复.js'
const jsPath = path.join(root, jsRel)
const corePath = path.join(root, 'refresh_route2.sh')
const watchPath = path.join(root, 'refresh_route_watch.sh')
const read = (p) => fs.readFileSync(p, 'utf8')

const SH = process.env.RRA_SH || 'sh'

let failed = 0
const ok = (name) => console.log(`[OK] ${name}`)
const bad = (name, detail) => {
    failed++
    console.error(`[FAIL] ${name}${detail ? `: ${detail}` : ''}`)
}
const check = (name, condition, detail = '') => {
    if (condition) ok(name)
    else bad(name, detail)
}

const run = (name, cmd, args) => {
    const r = spawnSync(cmd, args, { cwd: root, encoding: 'utf8' })
    if (r.error) return bad(name, r.error.message)
    if (r.status !== 0) return bad(name, (r.stderr || r.stdout || '').trim())
    ok(name)
}

// 1) 语法
run('JavaScript 语法 (node --check)', process.execPath, ['--check', jsPath])
run('Shell 语法 refresh_route2.sh', SH, ['-n', 'refresh_route2.sh'])
run('Shell 语法 refresh_route_watch.sh', SH, ['-n', 'refresh_route_watch.sh'])
run('内嵌脚本与 Shell 源文件一致', process.execPath, ['tools/sync-embedded.mjs', '--check'])

// 2) 源文件安全检查
const shell = read(corePath)
const watch = read(watchPath)
const js = read(jsPath)

check('未硬编码网关 fe80::2', !shell.includes('fe80::2'))
check('未硬编码 IPv6 前缀 2408:', !shell.includes('2408:'))
check('未保留 GW_FALLBACK/IF_FALLBACK 兜底', !shell.includes('GW_FALLBACK') && !shell.includes('IF_FALLBACK'))
check('运营商判断不使用 APN 3gnet', !/\*3gnet\*/.test(shell))
check('默认模式为 safe', /MODE=\$\(conf_get MODE safe/.test(shell) && /\[ "\$MODE" = advanced \] \|\| MODE=safe/.test(shell))
check('配置支持 MODE/THRESHOLD/ALLOW_UNKNOWN_OPERATOR', shell.includes('ALLOW_UNKNOWN_OPERATOR') && shell.includes('THRESHOLD'))
check('默认阈值 6 小时', shell.includes('THRESHOLD 21600'))
check('最小重试间隔默认 300s', shell.includes('MIN_RETRY 300'))
check('存在并发锁', shell.includes('.refresh_route.lock') && shell.includes('lock_busy'))
const safeBlock = (shell.split('if [ "$MODE" = safe ]; then')[1] || '').split('# ---- 高级模式')[0]
check('安全模式不调用删除/替换函数', safeBlock.length > 0 && !/delete_route|replace_route/.test(safeBlock))
check('手动 RS 优先于健康路由跳过', shell.indexOf('# ---- 手动只发 RS ----') < shell.indexOf('# 有效期充足或静态路由：不做任何修改。'))
check('路由刷新不会冒充收到 RA', shell.includes('路由已刷新，但未确认收到 RA'))
check('调度器信号触发退出', watch.includes("trap 'exit 0' INT TERM HUP"))
check('调度器睡眠可中断', watch.includes('sleep "$INTERVAL" &'))
check('权限不使用 777/666', !/chmod (777|666)/.test(js))
check('rdisc6 校验 ELF64 AArch64', js.includes('7f454c460201') && js.includes('RRA_VERIFY_RC'))
check('支持 --status', shell.includes('--status') && shell.includes('print_status'))
check('支持 --rs-only', shell.includes('--rs-only'))
check('支持 --delete-route（仅高级）', shell.includes('--delete-route'))
check('支持 --ping', shell.includes('--ping'))
check('连通性测试区分 ping6 缺失', shell.includes('CONNECTIVITY=unavailable'))
check('没有 ping6 时不回退为 ping -6 误判', !shell.includes('PEXTRA=-6'))
check('监听器单实例锁', watch.includes('.watcher.lock') && watch.includes('refresh_route_watch[.]sh'))
check('监听器不使用 OpenWrt 专有命令', !/\b(ubus|uci|jsonfilter)\b/.test(watch))

// 3) UI 关键字段
const uiRequires = [
    'rra_op', 'rra_iface', 'rra_gw', 'rra_route_state', 'rra_exp',
    'rra_last', 'rra_strategy', 'rra_watch', 'rra_install', 'rra_rs',
    'rra_interval', 'rra_threshold', 'rra_log', 'rra_ra',
    'rra_route_refresh', 'rra_conn',
]
// rra_rs 是按钮变量名，不是元素 id；这里仅做“手动发送 RS”文案检查
for (const id of uiRequires.filter(x => x !== 'rra_rs')) {
    check(`UI 包含 #${id}`, js.includes(`id="${id}"`) || js.includes(`'#${id}'`) || js.includes(`"#${id}"`))
}
check('UI 有手动发送 RS 按钮', js.includes('手动发送 RS'))
check('UI 有未知运营商兼容开关', js.includes('未知运营商兼容'))
check('UI 有高级修复模式开关', js.includes('高级修复模式'))
check('UI 区分 RA/路由/公网三类结果', js.includes('RA：已收到') && js.includes('路由：已刷新') && js.includes('公网：正常'))
check('UI 支持导入现有 rdisc6', js.includes('导入现有rdisc6') && js.includes('/data/local/tmp/rdisc6'))
check('首次安装不自动写开机自启', !/installScript[\s\S]{0,3000}ufi_tools_boot\.sh/.test(js))

// 4) 文档
const readme = read(path.join(root, 'README.md'))
const docRequires = [
    '中国联通', '安全模式', '高级模式', 'rdisc6', '卸载',
    '已知限制', '许可证', 'Xiaol1n173',
]
for (const word of docRequires) {
    check(`README 覆盖 ${word}`, readme.includes(word))
}

if (failed > 0) {
    console.error(`\n静态检查失败：${failed} 项`)
    process.exit(1)
}
console.log('\n静态检查全部通过')
