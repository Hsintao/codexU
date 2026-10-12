# codexU Windows v1.3.4

codexU Windows v1.3.4 修复 1.3.3 的额度刷新磁盘增长、历史大记录和 Dashboard 显示问题。

## 主要更新

- 额度刷新不再触发插件市场同步与重复下载；正常退出、失败和取消时完整回收查询进程树，保留真实官方额度。
- 大图片及工具记录采用流式历史读取，保留用量数据和后续有效记录，拒绝不完整尾部。
- 修复短历史热图、刷新状态和月度卡片：有 token 但缺少估价时明确显示记录不足，金额标记保持在卡片内。
- 设置页显示实际运行版本；增加真实安装包的隔离安装、1.3.3 升级、数据保留与卸载检查。
- 仅更新 Windows x86_64；macOS 继续使用 1.3.2，Windows 安装包未代码签名。

## 构建与验证

- 已合并的产品修复：PR #56，upstream merge `99410e4ed5941393b8cbadba0ea52f6341c6a5df`。
- 冻结打包源码：`bcd429f17ac4e43597491b0af60b1a819e570655`。runner 使用显式 Tauri version override `1.3.4`；发布元数据配置同样为 `1.3.4`，不改变此冻结源码的产品逻辑。
- Windows-only runner：https://github.com/lelelelelelelelelelelelele/codexU/actions/runs/38179303566；platform=windows，macOS job skipped。打包通过；独立 MSI/NSIS runner 的干净安装、1.3.3 升级、数据保留及卸载全部 PASS。实装程序哈希与候选一致。
- 实机安装包程序复测 PASS：运行 API 与 Settings 前端显示 1.3.4；官方周额度 39%；首次打开、三个定时周期、手动刷新、真实 CLI 终止失败/恢复、正常退出重启均验证。市场临时目录始终 130 个、4,169,421,812 字节，0 新目录 / 0 新字节；无本项残留进程。本机正式 1.3.3 程序及设置哈希未变。
- Windows release metadata gate：PASS，使用 `make release-windows-check VERSION=1.3.4 POWERSHELL=pwsh.exe`；全局内存风险 PASS，MSI x64 / ProductVersion 1.3.4、NSIS ProductVersion 1.3.4、manifest 及校验一致，两个安装包 NotSigned。
- 实机全量历史就绪 NOT OBSERVED：本次独立冷缓存的历史分支在上述约四分钟额度场景中保持 loading，未显示完整统计；不把额度与安装门禁通过称为全量 Dashboard 数据就绪。原 CODEXU-017 的全历史 probe 另有既有资源预算失败记录。
- Settings 前端在同一后台最大化真实 WebView 中选择，其版本来自真实原生 IPC；独立 Settings HWND 创建/聚焦不据此声称通过。
- macOS 版本 1.3.2 / build 29 及资产保留；不进行 macOS 原生验收或 notarization。

- 安装验收 runner：https://github.com/lelelelelelelelelelelelele/codexU/actions/runs/38180948936；test source `6679d5307094b02660dc1d761c9cd9ba3fa4d417`，复用原打包源码及包字节，未重新编译。
- 程序 SHA-256：`28c96c172b2ef98f8c6a24c85065a145a44151b58df9f9719840c9c5b2abcf6f`。

## 安装包与 SHA-256

```text
e49aa0bb44ad1ec7a7170faaa7e5f34d3f03d2c727a5364716bd11de56e8407f  codexU-1.3.4-windows-x86_64.msi
4559b5c18566885cce2f0da0a8409888dd9e0e994fc895c339c95f8e0337f1a0  codexU-1.3.4-windows-x86_64-setup.exe
```

## 发布边界

- Windows 独立版本与 tag `windows-v1.3.4`，stable、non-draft，`--latest=false`；macOS Latest 保持 v1.3.2。
- 发布包必须与安装验收的包为同一 SHA-256；源码、manifest、MSI/NSIS 版本、签名状态与 checksum 绑定后再发布。
- 隔离 runner 使用无真实账户的本地测试数据；本机真实账户与历史不上传。Windows 10、其他 DPI 与所有输入组合不据此声称已验证。
