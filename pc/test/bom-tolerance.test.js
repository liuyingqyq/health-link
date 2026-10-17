/**
 * 验证 BOM 容错：用户用 PowerShell / 记事本编辑配置后容易带上 BOM。
 * 期望：带 BOM 的 config.json 和 forwards.json 都能被正确读取，服务正常启动。
 */
const fs = require('fs');
const path = require('path');
const os = require('os');
const { loadConfig } = require(path.join(__dirname, '..', 'src', 'config.js'));

let pass = 0, fail = 0;
function check(label, ok, extra = '') {
  ok ? pass++ : fail++;
  console.log(`  [${ok ? 'PASS' : 'FAIL'}] ${label}${extra ? '  → ' + extra : ''}`);
}

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hl-bom-'));
const BOM = '\uFEFF';

// ---- 1) config.json 带 BOM ----
const cfgPath = path.join(dir, 'config.json');
fs.writeFileSync(cfgPath, BOM + JSON.stringify({ authToken: 'abc123def456abc123def456abc12345', port: 19999 }), 'utf8');
const bytes = fs.readFileSync(cfgPath);
check('测试文件确实带了 BOM', bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf);

try {
  const cfg = loadConfig({ argv: [], configFile: cfgPath });
  check('带 BOM 的 config.json 能正常解析（令牌长度 32，不该被替换）', cfg.authToken === 'abc123def456abc123def456abc12345', `token=${cfg.authToken} 文件=${cfgPath}`);
  check('端口也能正确读取', cfg.port === 19999, `port=${cfg.port}`);
} catch (e) {
  check('带 BOM 的 config.json 能正常解析', false, e.message);
}

// ---- 2) 无 BOM 的仍然正常 ----
const cfgPath2 = path.join(dir, 'config2.json');
fs.writeFileSync(cfgPath2, JSON.stringify({ authToken: 'xyz789ghi012xyz789ghi012xyz78901', port: 18888 }), 'utf8');
try {
  const cfg2 = loadConfig({ argv: [], configFile: cfgPath2 });
  check('无 BOM 的 config.json 仍然正常（没改坏原逻辑）', cfg2.authToken === 'xyz789ghi012xyz789ghi012xyz78901', `token=${cfg2.authToken}`);
} catch (e) {
  check('无 BOM 的 config.json 仍然正常', false, e.message);
}

// ---- 3) 服务端能带着带 BOM 的 forwards.json 启动 ----
const { HealthLinkServer } = require(path.join(__dirname, '..', 'src', 'server.js'));
const fwdPath = path.join(dir, 'forwards.json');
fs.writeFileSync(fwdPath, BOM + JSON.stringify({ targets: [] }), 'utf8');

const server = new HealthLinkServer({
  config: {
    port: 0, host: '127.0.0.1', authToken: 'bomtoken', logLevel: 'error',
    dataDir: dir, storePath: fwdPath, forwardsFile: fwdPath,
    defaultCollectIntervalMs: 60000, offlineAfterMs: 120000,
    maxFrameBytes: 1024 * 1024,
  },
  logger: { info() {}, warn() {}, error() {}, debug() {} },
});

server.listen()
  .then(() => {
    check('服务端能带着带 BOM 的 forwards.json 正常启动', true, `port=${server.server.address().port}`);
    return server.close();
  })
  .then(() => {
    // ---- 4) stripBom 边界情况 ----
    const { stripBom } = require(path.join(__dirname, '..', 'src', 'config.js'));
    check('stripBom 去掉开头的 BOM', stripBom(BOM + '{}') === '{}');
    check('stripBom 对无 BOM 文本不变', stripBom('{}') === '{}');
    check('stripBom 不误删中间字符', stripBom('{"a":"' + BOM + '"}') === '{"a":"' + BOM + '"}');
    check('stripBom 处理空串', stripBom('') === '');

    try { fs.rmSync(dir, { recursive: true, force: true }); } catch {}
    console.log(`\n  结果: ${pass} 通过 / ${fail} 失败`);
    process.exit(fail === 0 ? 0 : 1);
  })
  .catch((e) => {
    check('服务端能带着带 BOM 的 forwards.json 正常启动', false, e.message);
    try { fs.rmSync(dir, { recursive: true, force: true }); } catch {}
    console.log(`\n  结果: ${pass} 通过 / ${fail} 失败`);
    process.exit(1);
  });
