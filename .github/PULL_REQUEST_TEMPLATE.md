## 这个 PR 做了什么

（一句话说清）

## 为什么要改

## 怎么验证的

- [ ] `node pc/test/e2e.test.js`（53 项）
- [ ] `node pc/test/bom-tolerance.test.js`（9 项）
- [ ] `node pc/test/pcble-source-logic.test.js`（10 项）
- [ ] `node tools/verify-share-page.js`（12 项）
- [ ] `node mobile/android/verify-protocol.js`（14 项）
- [ ] `pwsh ./tools/check-encoding.ps1`（改过 .ps1 / .cmd 时必须跑）

## 注意事项自查

- [ ] **没有**提交 `pc/config.json`、`pc/forwards.json`、任何证书或 .tooling / bin / obj / dist
- [ ] 改过 `.ps1` / `.cmd` 后，编码与 BOM 仍符合 CONTRIBUTING.md 的规矩
- [ ] 新增行为补了测试（纯逻辑测试不需要硬件）
