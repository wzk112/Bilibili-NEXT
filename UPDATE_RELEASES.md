# macOS 更新发布

“设置 → 关于”与应用菜单提供检查更新。版本元数据只从构建指定的 GitHub 仓库读取，不携带 B 站 Cookie。默认源为 `wzk112/Bilibili-NEXT`；Fork 发行时用 `UPDATE_REPOSITORY=owner/repo` 指定自己的源。

## 自动安装的发行配置

自动安装使用 [Sparkle](https://sparkle-project.org/documentation/) 的签名验证与原生安装流程。已有上游 1.1.4 未发布签名 appcast，因此普通开发构建可检查更新和打开对应 Mac 下载；完整自动安装通道需要发行方完成下述一次性配置，并发布带此集成的新版本。测试和预览 Bundle 不启动自动安装。

1. 执行 `swift package resolve`，取得锁定版本 Sparkle 2.10.1。
2. 发行方执行 `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account Bilibili-NEXT-updates`。私钥存入发行方钥匙串；只将输出的公钥用于构建，私钥不要加入源码、PR 或日志。
3. 在 `Scripts/build-app.sh` 中更新发行版本和构建号。设置 `SPARKLE_PUBLIC_ED_KEY` 为上一步公钥；默认 feed 为 `https://github.com/$UPDATE_REPOSITORY/releases/latest/download/appcast.xml`，也可用 `UPDATE_FEED_URL` 指定自己的 HTTPS feed。
4. 按原有流程从已提交的源码运行 `Scripts/package-release.sh`。配置公钥后，它会额外调用 `Scripts/generate-appcast.sh` 为 Mac ZIP 生成已签名 appcast。默认从上述钥匙串账户签名，CI 可通过 `SPARKLE_PRIVATE_KEY_FILE` 指向受保护的临时密钥文件。
5. 将对应版本 ZIP、DMG、`appcast.xml` 和原有校验文件上传到同一个 GitHub Release。`RELEASE_TAG` 必须与发布标签一致，默认是 `v<版本号>`。自动更新使用 ZIP；DMG 仍用于首次安装。

Developer ID 发行时设置 `SIGNING_IDENTITY` 并设置 `SIGNING_TIMESTAMP=1`，按发行方自己的 Apple 凭据完成公证和装订，再生成最终更新包。应用及 Sparkle 内部助手按从内到外签名，保留助手的 entitlements。没有证书的本地 ad-hoc 构建不启用 Hardened Runtime 的库验证，以免阻止加载内嵌框架。

如需在打包后公证，先设置 `GENERATE_APPCAST=0`；完成公证、装订并重新生成最终 Mac ZIP 后，在只包含最终 Mac ZIP 与对应说明的目录执行 `Scripts/generate-appcast.sh`。签名后修改 ZIP/DMG、再次签名或装订都会使原更新签名失效，必须重新生成 appcast。

应用配置启用更新包提取前验证及签名 feed。开启“自动下载并安装更新”由 Sparkle 管理；关闭自动检查也会关闭自动安装。预览包、测试进程或没有公钥/feed 的构建不会尝试替换应用。

## 测试

- `swift test --filter MacUpdateTests`：版本数值比较、防降级、发布源/架构筛选、错误状态、无 Cookie 检查及开发包禁止自动安装。
- 打包后执行 `codesign --verify --deep --strict <app>`，确保框架、内部助手与主应用签名完整。
- 用临时测试密钥和独立测试应用生成 appcast，验证签名后再对发行源做升级测试；不要用用户正在运行的应用验证替换流程。

尚未配置的上游发布权限、签名密钥和实际 Release 上传属于发行步骤。源代码集成不会替发行方创建密钥或发布版本。
