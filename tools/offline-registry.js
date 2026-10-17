#!/usr/bin/env node
'use strict';
/**
 * 离线 npm registry（**仅用于在没有外网的环境里准备 hvigor 依赖**）。
 *
 * ## 它解决什么问题
 *
 * hvigor 构建时会执行 `pnpm install @ohos/hvigor @ohos/hvigor-ohos-plugin`。
 * 这两个包**不在 npmjs 上**（由 DevEco Studio 随包提供），
 * 所以完全离线的机器上这一步必然失败。
 * 本脚本把 DevEco 自带的包连同其依赖闭包，按 npm registry 协议
 * （packument + tarball）暴露在一个本地端口上，让 pnpm 能真实完成安装。
 *
 * ## 用法
 *
 *   node tools/offline-registry.js --port 4873 --out <缓存目录>
 *   # 然后让 npm/pnpm 指向它：在 .npmrc 里写
 *   #   registry=http://127.0.0.1:4873/
 *   # 再运行 tools/build-phone.ps1
 *
 * ## 已知限制（重要，不要当成万能方案）
 *
 * DevEco 自带的依赖树**不是完整的 npm 闭包**。实测中它要求
 * `brace-expansion@^1.1.7`（来自 hvigor-ohos-plugin → @ohos/coverage →
 * rimraf@3 → glob@7），而 DevEco 只自带 2.1.4，本机又拉不到公网，
 * 因此**离线构建仍可能停在个别历史版本的传递依赖上**。脚本会在启动时
 * 把本地找不到的依赖逐条打印出来，不会静默跳过。
 *
 * → **有外网的机器请直接用 DevEco Studio 正常构建**（见 docs/部署与验证.md）。
 *    本脚本只是"完全没网时能往前走多远"的尽力方案。
 *
 * 本脚本**不会凭空造包**：磁盘上找不到的依赖一律如实报告缺失。
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const crypto = require('crypto');

const DEVECO_HVIGOR = 'D:\\Downloads\\DevEco Studio\\tools\\hvigor';
const ROOTS = [path.join(DEVECO_HVIGOR, 'hvigor'), path.join(DEVECO_HVIGOR, 'hvigor-ohos-plugin')];

// ---------------------------------------------------------------- tar 打包

/** 写一个 512 字节的 tar 头 */
function tarHeader(name, size, type, prefix) {
  const header = Buffer.alloc(512);
  // 文件名**必须用 NULL 填充**，不能用空格。
  // USTAR 标准允许空格填充，但 Node 的 tar 解包器（pnpm 用的那个）
  // 只按第一个 \0 截断，于是路径会变成 "xxx.js            "，
  // 文件写出去就"不存在"了 —— 表现为 require('./limitNumber') 找不到模块。
  header.write(name, 0, 100, 'utf8');
  if (prefix) header.write(prefix, 345, 155, 'utf8');
  header.write('000644 \0', 100, 8, 'ascii');
  header.write('000000 \0', 108, 8, 'ascii');
  header.write('000000 \0', 116, 8, 'ascii');
  header.write(size.toString(8).padStart(11, '0') + ' ', 124, 12, 'ascii');
  header.write('00000000000 ', 136, 12, 'ascii');
  header.write('        ', 148, 8, 'ascii');
  header.write(type, 156, 1, 'ascii');
  header.write('ustar\0', 257, 6, 'ascii');
  header.write('00', 263, 2, 'ascii');
  let sum = 0;
  for (let i = 0; i < 512; i++) sum += header[i];
  header.write(sum.toString(8).padStart(6, '0') + '\0 ', 148, 8, 'ascii');
  return header;
}

/** 追加数据并按 512 字节对齐补齐 */
function pushData(blocks, data) {
  if (!data || data.length === 0) return;
  blocks.push(data);
  const pad = 512 - (data.length % 512);
  if (pad !== 512) blocks.push(Buffer.alloc(pad));
}

function tarGzFromEntries(entries, outFile) {
  const blocks = [];
  for (const entry of entries) {
    const nameBytes = Buffer.byteLength(entry.name, 'utf8');
    if (nameBytes <= 100) {
      blocks.push(tarHeader(entry.name, entry.size, entry.type, null));
    } else {
      const slash = entry.name.lastIndexOf('/');
      const prefix = slash > 0 ? entry.name.slice(0, slash) : '';
      const rest = slash > 0 ? entry.name.slice(slash + 1) : entry.name;
      if (prefix && Buffer.byteLength(prefix, 'utf8') <= 155 && Buffer.byteLength(rest, 'utf8') <= 100) {
        blocks.push(tarHeader(rest, entry.size, entry.type, prefix));
      } else {
        // GNU LongName 扩展（type 'L'）：tar 事实标准，Node 的解析器支持。
        const longName = Buffer.concat([Buffer.from(entry.name, 'utf8'), Buffer.from([0])]);
        blocks.push(tarHeader('././@LongLink', longName.length, 'L', null));
        pushData(blocks, longName);
        blocks.push(tarHeader(entry.name.slice(0, 100), entry.size, entry.type, null));
      }
    }
    pushData(blocks, entry.data || Buffer.alloc(0));
  }
  blocks.push(Buffer.alloc(1024)); // 结束标记
  const gz = zlib.gzipSync(Buffer.concat(blocks), { level: 9 });
  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  fs.writeFileSync(outFile, gz);
  return gz;
}

/**
 * 生成 registry 用的 package.json。
 *
 * 必须去掉 bundleDependencies：DevEco 自带的 @ohos/hvigor 用它声明
 * "这 12 个依赖已随包内置"，pnpm 看到该字段就**不会去安装它们**，
 * 最终报 `Cannot find module 'semver'`。而我们打包时不含 node_modules，
 * 所以必须剥掉，让 pnpm 按普通依赖去 registry 解析。
 * pnpm 的解析读的是 packument，因此 packument 与 tarball 两边都要剥。
 */
function buildRegistryManifest(json) {
  const cleaned = { ...json };
  delete cleaned.bundleDependencies;
  delete cleaned.bundledDependencies;
  delete cleaned.devDependencies;
  return JSON.stringify(cleaned, null, 2) + '\n';
}

/** 收集一个包目录下要打进 tarball 的文件（跳过所有层级的 node_modules） */
function collectPackageEntries(dir, json, prefix = 'package') {
  const entries = [];
  const walk = (absDir, relDir) => {
    for (const item of fs.readdirSync(absDir, { withFileTypes: true })) {
      if (item.name === 'node_modules' || item.name === '.bin') continue;
      const abs = path.join(absDir, item.name);
      const rel = relDir ? `${relDir}/${item.name}` : item.name;
      if (item.isDirectory()) {
        entries.push({ name: `${prefix}/${rel}/`, type: '5', size: 0, data: Buffer.alloc(0) });
        walk(abs, rel);
      } else if (item.isFile() || item.isSymbolicLink()) {
        let data;
        try {
          data = fs.readFileSync(abs);
        } catch (_) {
          continue; // 断掉的符号链接
        }
        if (rel === 'package.json' && json) data = Buffer.from(buildRegistryManifest(json), 'utf8');
        entries.push({ name: `${prefix}/${rel}`, type: '0', size: data.length, data });
      }
    }
  };
  walk(dir, '');
  return entries;
}

// ---------------------------------------------------------------- 依赖闭包

/**
 * 从若干根包出发收集依赖闭包（含嵌套 node_modules 里的包）。
 * 同名不同版本都会各自登记，因为 pnpm 需要按 semver 分别解析。
 * @param {string[]} rootDirs
 * @param {(from: string, dep: string) => void} [onMissing] 本地找不到的依赖会上报，不静默跳过
 */
function collectClosure(rootDirs, onMissing) {
  const found = new Map(); // "name@version" -> {name, version, dir, json}
  const visited = new Set();

  const register = (pkgDir) => {
    const pkgJsonPath = path.join(pkgDir, 'package.json');
    if (!fs.existsSync(pkgJsonPath)) return null;
    let json;
    try {
      json = JSON.parse(fs.readFileSync(pkgJsonPath, 'utf8'));
    } catch (_) {
      return null;
    }
    if (!json.name || !json.version) return null;
    const key = `${json.name}@${json.version}`;
    if (!found.has(key)) found.set(key, { name: json.name, version: json.version, dir: pkgDir, json });
    return { key, json, dir: pkgDir };
  };

  const resolvePackageDir = (fromDir, pkgName) => {
    let cursor = fromDir;
    for (;;) {
      const candidate = path.join(cursor, 'node_modules', ...pkgName.split('/'));
      if (fs.existsSync(path.join(candidate, 'package.json'))) return candidate;
      const parent = path.dirname(cursor);
      if (parent === cursor) return null;
      cursor = parent;
    }
  };

  const visit = (pkgDir) => {
    const info = register(pkgDir);
    if (!info) return;
    if (visited.has(info.key)) return;
    visited.add(info.key);

    // bundleDependencies 里的包同样是运行期依赖，要一起收
    const bundled = Array.isArray(info.json.bundleDependencies)
      ? info.json.bundleDependencies
      : Array.isArray(info.json.bundledDependencies)
        ? info.json.bundledDependencies
        : [];
    const deps = { ...(info.json.dependencies || {}), ...(info.json.optionalDependencies || {}) };
    for (const name of bundled) if (!deps[name]) deps[name] = '*';

    for (const depName of Object.keys(deps)) {
      const depDir = resolvePackageDir(pkgDir, depName);
      if (depDir) visit(depDir);
      else if (onMissing) onMissing(info.key, depName);
    }
  };

  for (const root of rootDirs) visit(root);
  return found;
}

// ---------------------------------------------------------------- 主流程

function main() {
  const args = process.argv.slice(2);
  let port = 4873;
  let outDir = path.join(__dirname, '..', '.offline-registry');
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--port') port = Number(args[++i]);
    else if (args[i] === '--out') outDir = path.resolve(args[++i]);
  }

  if (!fs.existsSync(DEVECO_HVIGOR)) {
    process.stderr.write(
      `找不到 DevEco Studio 的 hvigor 目录: ${DEVECO_HVIGOR}\n` +
        '请修改本脚本顶部的 DEVECO_HVIGOR 常量，或在有外网的机器上直接构建。\n'
    );
    process.exit(1);
  }

  process.stdout.write('扫描依赖闭包...\n');
  const missing = [];
  const closure = collectClosure(ROOTS, (from, dep) => missing.push({ from, dep }));
  process.stdout.write(`共发现 ${closure.size} 个包版本\n`);

  const tarballDir = path.join(outDir, 'tarballs');
  fs.mkdirSync(tarballDir, { recursive: true });
  /** name -> Map<version, {json, fileName, shasum, integrity}> */
  const metadata = new Map();
  let total = 0;

  for (const [, info] of closure) {
    const fileName = `${info.name.replace('@', '').replace('/', '-')}-${info.version}.tgz`;
    const outFile = path.join(tarballDir, fileName);
    let buf;
    if (fs.existsSync(outFile)) {
      buf = fs.readFileSync(outFile);
    } else {
      const entries = collectPackageEntries(info.dir, info.json);
      if (entries.length === 0) continue;
      buf = tarGzFromEntries(entries, outFile);
    }
    total += buf.length;
    if (!metadata.has(info.name)) metadata.set(info.name, new Map());
    metadata.get(info.name).set(info.version, {
      json: info.json,
      fileName,
      shasum: crypto.createHash('sha1').update(buf).digest('hex'),
      integrity: `sha1-${crypto.createHash('sha1').update(buf).digest('base64')}`
    });
  }

  const versionCount = Array.from(metadata.values()).reduce((s, m) => s + m.size, 0);
  process.stdout.write(`tarball 合计 ${(total / 1024 / 1024).toFixed(1)} MB，写入 ${tarballDir}\n`);
  process.stdout.write(`${metadata.size} 个包名，共 ${versionCount} 个版本\n`);

  if (missing.length > 0) {
    process.stdout.write(`\n⚠️ 有 ${missing.length} 处依赖在本地找不到（离线构建会在这些地方失败）：\n`);
    const seen = new Set();
    for (const m of missing) {
      if (seen.has(m.dep)) continue;
      seen.add(m.dep);
      process.stdout.write(`  ${m.from} 需要 ${m.dep}\n`);
      if (seen.size >= 20) {
        process.stdout.write('  ...（还有更多，已截断）\n');
        break;
      }
    }
    process.stdout.write('  → 有外网时请直接用 DevEco Studio 构建，不要依赖本脚本。\n');
  }

  const server = http.createServer((req, res) => {
    const url = new URL(req.url, `http://127.0.0.1:${port}`);
    const pathname = decodeURIComponent(url.pathname);

    if (pathname.startsWith('/tarballs/')) {
      const file = path.normalize(path.join(outDir, pathname.replace(/^\//, '')));
      if (!file.startsWith(path.normalize(outDir)) || !fs.existsSync(file)) {
        res.writeHead(404).end('not found');
        return;
      }
      const buf = fs.readFileSync(file);
      res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': buf.length });
      res.end(buf);
      return;
    }

    const name = pathname.replace(/^\//, '');
    const versions = metadata.get(name);
    if (!versions) {
      process.stdout.write(`[404] ${name}\n`);
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Not found' }));
      return;
    }

    const versionsObj = {};
    let latest = null;
    for (const [version, entry] of versions) {
      // packument 也必须走 buildRegistryManifest（见该函数注释）
      const manifestJson = JSON.parse(buildRegistryManifest(entry.json));
      versionsObj[version] = {
        ...manifestJson,
        version,
        dist: {
          tarball: `http://127.0.0.1:${port}/tarballs/${entry.fileName}`,
          shasum: entry.shasum,
          integrity: entry.integrity
        },
        _id: `${name}@${version}`
      };
      if (latest === null) latest = version;
    }
    const body = JSON.stringify({
      name,
      'dist-tags': { latest },
      versions: versionsObj,
      _id: name,
      _rev: '1-0',
      readme: ''
    });
    const buf = Buffer.from(body, 'utf8');
    res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Length': buf.length });
    res.end(buf);
  });

  server.listen(port, '127.0.0.1', () => {
    process.stdout.write(`离线 registry 已就绪: http://127.0.0.1:${port}/\n`);
    process.stdout.write('（仅用于离线准备 hvigor 依赖；有外网时请直接用 DevEco Studio 构建）\n');
  });

  process.on('SIGINT', () => server.close(() => process.exit(0)));
}

if (require.main === module) main();

module.exports = { collectClosure, tarGzFromEntries, collectPackageEntries, buildRegistryManifest };
