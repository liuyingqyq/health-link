/**
 * 生成 HarmonyOS 应用图标（纯 Node，无外部依赖）。
 *
 * 为什么需要这个脚本：
 *   工程里原来的 app_icon.png 是 48x48 / 141 字节，太小 ——
 *   hvigor 构建时会报 "ScaleImage failed, error message: INVALID_PARAMETERS"，
 *   而且装到手机上启动器图标会糊。华为建议应用图标至少 216x216。
 *
 * 用法：
 *   node tools/make-icons.js <项目根目录>
 *   例：node tools/make-icons.js <仓库根目录>\phone
 *
 * 实现：手写 PNG 编码器（IHDR/IDAT/IEND + CRC32），4 倍超采样做抗锯齿。
 */

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

// ------------------------------------------------------------------ PNG 编码

const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, 'ascii');
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
  return Buffer.concat([len, typeBuf, data, crcBuf]);
}

/** rgba: Uint8Array，长度 = w*h*4 */
function encodePng(w, h, rgba) {
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // color type: RGBA
  ihdr[10] = 0; // compression
  ihdr[11] = 0; // filter
  ihdr[12] = 0; // interlace

  // 每行前面加一个 filter 字节 0（None）
  const raw = Buffer.alloc(h * (1 + w * 4));
  for (let y = 0; y < h; y++) {
    const rowStart = y * (1 + w * 4);
    raw[rowStart] = 0;
    rgba.copy
      ? rgba.copy(raw, rowStart + 1, y * w * 4, (y + 1) * w * 4)
      : Buffer.from(rgba.buffer, y * w * 4, w * 4).copy(raw, rowStart + 1);
  }

  return Buffer.concat([
    sig,
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0))
  ]);
}

// ------------------------------------------------------------------ 绘图

const SS = 4; // 超采样倍数

function lerp(a, b, t) {
  return a + (b - a) * t;
}

/** 判断点是否在圆角矩形内 */
function inRoundRect(x, y, w, h, r) {
  if (x < 0 || y < 0 || x >= w || y >= h) return false;
  const cx = Math.min(Math.max(x, r), w - r);
  const cy = Math.min(Math.max(y, r), h - r);
  const dx = x - cx;
  const dy = y - cy;
  return dx * dx + dy * dy <= r * r || (x >= r && x <= w - r) || (y >= r && y <= h - r);
}

/** 点到线段的距离 */
function distToSegment(px, py, x1, y1, x2, y2) {
  const dx = x2 - x1;
  const dy = y2 - y1;
  const l2 = dx * dx + dy * dy;
  let t = l2 === 0 ? 0 : ((px - x1) * dx + (py - y1) * dy) / l2;
  t = Math.min(1, Math.max(0, t));
  const qx = x1 + t * dx;
  const qy = y1 + t * dy;
  return Math.hypot(px - qx, py - qy);
}

/**
 * 画图标。设计意图：深蓝底 + 白色心电波形，一眼看出是"健康数据采集"。
 */
function drawIcon(size) {
  const S = size * SS;
  const acc = new Float32Array(S * S * 4); // 预乘累加

  const radius = S * 0.22;
  const pad = S * 0.04;

  // 心电波形折线（归一化坐标，相对可用区域）
  const wave = [
    [0.06, 0.52], [0.22, 0.52], [0.29, 0.52], [0.34, 0.34],
    [0.40, 0.70], [0.46, 0.18], [0.52, 0.62], [0.58, 0.52],
    [0.66, 0.52], [0.72, 0.52], [0.78, 0.40], [0.84, 0.52], [0.94, 0.52]
  ];

  for (let y = 0; y < S; y++) {
    for (let x = 0; x < S; x++) {
      const i = (y * S + x) * 4;
      let r = 0, g = 0, b = 0, a = 0;

      // 圆角矩形底
      if (inRoundRect(x, y, S - pad * 2, S - pad * 2, radius)) {
        const px = x - pad;
        const py = y - pad;
        const t = py / (S - pad * 2);
        // 竖向渐变：#0A59F7 -> #0B3FB0
        r = lerp(0x0a, 0x0b, t);
        g = lerp(0x59, 0x3f, t);
        b = lerp(0xf7, 0xb0, t);
        a = 255;

        // 心电波形：白色，带一点柔和外发光
        const innerW = S - pad * 2;
        let minDist = Infinity;
        for (let k = 0; k < wave.length - 1; k++) {
          const d = distToSegment(
            px, py,
            wave[k][0] * innerW, wave[k][1] * innerW,
            wave[k + 1][0] * innerW, wave[k + 1][1] * innerW
          );
          if (d < minDist) minDist = d;
        }
        const lineW = innerW * 0.055;
        if (minDist < lineW) {
          r = 255; g = 255; b = 255;
        } else if (minDist < lineW * 2.1) {
          // 外发光
          const k = 1 - (minDist - lineW) / (lineW * 1.1);
          const glow = Math.max(0, Math.min(1, k)) * 0.45;
          r = lerp(r, 255, glow);
          g = lerp(g, 255, glow);
          b = lerp(b, 255, glow);
        }
      }

      acc[i] = r;
      acc[i + 1] = g;
      acc[i + 2] = b;
      acc[i + 3] = a;
    }
  }

  // 降采样（盒式滤波）
  const out = Buffer.alloc(size * size * 4);
  const n = SS * SS;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let r = 0, g = 0, b = 0, a = 0;
      for (let dy = 0; dy < SS; dy++) {
        for (let dx = 0; dx < SS; dx++) {
          const i = ((y * SS + dy) * S + (x * SS + dx)) * 4;
          const al = acc[i + 3] / 255;
          r += acc[i] * al;
          g += acc[i + 1] * al;
          b += acc[i + 2] * al;
          a += acc[i + 3];
        }
      }
      const aAvg = a / n;
      const o = (y * size + x) * 4;
      if (aAvg > 0) {
        const at = a / 255;
        out[o] = Math.round(Math.min(255, r / at));
        out[o + 1] = Math.round(Math.min(255, g / at));
        out[o + 2] = Math.round(Math.min(255, b / at));
      }
      out[o + 3] = Math.round(aAvg);
    }
  }
  return out;
}

// ------------------------------------------------------------------ 主流程

const root = process.argv[2];
if (!root) {
  console.error('用法: node tools/make-icons.js <phone 工程根目录>');
  process.exit(1);
}

const SIZE = 216; // 华为建议应用图标至少 216x216
console.log(`生成 ${SIZE}x${SIZE} 图标…`);
const pixels = drawIcon(SIZE);
const png = encodePng(SIZE, SIZE, pixels);

const targets = [
  'AppScope/resources/base/media/app_icon.png',
  'entry/src/main/resources/base/media/app_icon.png',
  'entry/src/main/resources/base/media/startIcon.png',
  'entry/src/main/resources/en_US/media/app_icon.png',
  'entry/src/main/resources/zh_CN/media/app_icon.png'
];

let ok = 0;
for (const rel of targets) {
  const full = path.join(root, rel);
  if (!fs.existsSync(path.dirname(full))) {
    console.log(`  跳过（目录不存在）: ${rel}`);
    continue;
  }
  fs.writeFileSync(full, png);
  console.log(`  写入 ${rel}  (${png.length} 字节)`);
  ok++;
}
console.log(`完成：${ok} 个图标已更新为 ${SIZE}x${SIZE}`);
