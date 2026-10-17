// 本地预览用的极简静态服务器（零依赖）。
//   node legal/serve.js            → http://127.0.0.1:8790/
//   node legal/serve.js 9000       → 换端口
// 仅用于本机预览，不对外提供服务。
const http = require('http');
const fs = require('fs');
const path = require('path');

const DIR = __dirname;
const PORT = Number(process.argv[2] || 8790);
const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.png': 'image/png',
  '.md': 'text/plain; charset=utf-8'
};

http.createServer((req, res) => {
  let p = decodeURIComponent(req.url.split('?')[0]);
  if (p === '/') p = '/index.html';
  const file = path.resolve(path.join(DIR, p));
  // 防目录穿越
  if (!file.startsWith(path.resolve(DIR))) {
    res.writeHead(403, { 'content-type': 'text/plain; charset=utf-8' }).end('403 forbidden');
    return;
  }
  fs.readFile(file, (err, data) => {
    if (err) {
      res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' }).end('404 not found');
      return;
    }
    res.writeHead(200, { 'content-type': TYPES[path.extname(file)] || 'application/octet-stream' });
    res.end(data);
  });
}).listen(PORT, '127.0.0.1', () => {
  console.log(`HealthLink legal 预览: http://127.0.0.1:${PORT}/`);
});
