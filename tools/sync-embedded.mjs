// 把仓库中的 Shell 源文件同步进 UFI-TOOLS 插件 JS 的 String.raw 常量。
//
// 用法：
//   node tools/sync-embedded.mjs          写入插件 JS
//   node tools/sync-embedded.mjs --check  只校验（CI/测试用），不写文件
//
// 约束：Shell 源文件里不能出现反引号或 “${”，否则会破坏 String.raw 模板字面量。
// 现有脚本统一使用 $VAR / $(...) / $((...))，不依赖这两种写法。

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const jsPath = path.join(root, '[插件]IPv6 RA路由修复.js')
const targets = [
    { name: 'REFRESH_SH', source: 'refresh_route2.sh' },
    { name: 'WATCH_SH', source: 'refresh_route_watch.sh' },
]

const checkOnly = process.argv.includes('--check')

const readUtf8 = (file) => fs.readFileSync(path.join(root, file), 'utf8')

const replaceConst = (source, name, body) => {
    const marker = `const ${name} = String.raw\``
    const start = source.indexOf(marker)
    if (start < 0) throw new Error(`插件 JS 中找不到 ${name} 常量`)
    const bodyStart = start + marker.length
    const bodyEnd = source.indexOf('`', bodyStart)
    if (bodyEnd < 0) throw new Error(`${name} 常量缺少结束反引号`)
    return source.slice(0, bodyStart) + '\n' + body + source.slice(bodyEnd)
}

let js = fs.readFileSync(jsPath, 'utf8')
const sources = []
for (const { name, source } of targets) {
    const body = readUtf8(source)
    if (body.includes('`') || body.includes('${')) {
        throw new Error(`${source} 含有反引号或 \${，无法安全嵌入 String.raw 模板`)
    }
    sources.push({ name, source, body })
    js = replaceConst(js, name, body)
}

if (checkOnly) {
    const current = fs.readFileSync(jsPath, 'utf8')
    if (current !== js) {
        console.error('插件 JS 内嵌脚本与仓库 Shell 源文件不一致，请运行: node tools/sync-embedded.mjs')
        process.exit(1)
    }
    console.log('OK: 插件 JS 内嵌脚本与 Shell 源文件一致')
    process.exit(0)
}

fs.writeFileSync(jsPath, js)
for (const { name, source } of sources) {
    console.log(`synced ${source} -> ${name}`)
}
