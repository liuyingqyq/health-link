// 在蒲公英虚拟网段里找其他设备（只发 ICMP 探测，只读）
// 目的：看看对方电脑是不是已经在这个蒲公英网络里了
const { execFile } = require('child_process');

function ping(ip, timeoutMs = 800) {
  return new Promise((resolve) => {
    execFile('ping', ['-n', '1', '-w', String(timeoutMs), ip], (err, stdout) => {
      if (err) return resolve(false);
      // 中文/英文系统都兼容：看是否有 TTL 或 时间= 字样
      resolve(/TTL=|TTL =|时间[=<]/.test(stdout));
    });
  });
}

(async () => {
  const base = '172.16.3.';
  const self = '172.16.0.2';
  console.log('');
  console.log('  在蒲公英网段 172.16.3.0/24 里扫描其他设备（本机是 ' + self + '）');
  console.log('  ──────────────────────────────────────────────');

  const found = [];
  const tasks = [];
  for (let i = 1; i <= 30; i++) {
    const ip = base + i;
    if (ip === self) continue;
    tasks.push(
      ping(ip).then((ok) => {
        if (ok) {
          found.push(ip);
          console.log('  ✅ 发现设备: ' + ip);
        }
        return ok;
      })
    );
  }
  await Promise.all(tasks);

  console.log('  ──────────────────────────────────────────────');
  if (found.length === 0) {
    console.log('  没有发现其他设备（172.16.3.1 ~ .30 都无响应）');
    console.log('');
    console.log('  含义：这个蒲公英网络里目前只有你这台电脑。');
    console.log('        让对方装蒲公英并加入同一个网络后，他会出现，');
    console.log('        然后重新运行本工具就能看到他的地址。');
  } else {
    console.log(`  共发现 ${found.length} 台设备：${found.join(', ')}`);
    console.log('');
    console.log('  如果其中有对方的电脑 → 你已经有可用通道了！');
    console.log('  可以直接把分享链接里的 IP 换成那个地址发给对方。');
  }
  console.log('');
})();
