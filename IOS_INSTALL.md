# iOS / iPadOS 安装

当前手机安装包为 **0.1.3 开发预览（build 7）**，随 [v1.1.3 双端版本](https://github.com/wzk112/Bilibili-NEXT/releases/tag/v1.1.3) 发布。支持 iPhone / iPad，最低 iOS / iPadOS 26，真机架构 arm64。

## 下载 IPA 自行签名

1. 下载 `Bilibili-NEXT-0.1.3-iOS-self-sign.ipa`。文件名中的 `self-sign` 表示需要自行签名，不能直接点击安装。包内只有不含个人证书的临时签名结构，不是有效的设备安装签名。
2. 使用自己的 Apple Account / 开发者证书，以及与设备和 Bundle ID 匹配的描述文件，在所选签名工具中完成签名并安装。发布包不包含作者的证书、描述文件或账号数据。
3. 如果使用开发签名，按设备提示启用开发者模式、信任开发者。签名的有效期、设备限制、续签与安装方式取决于自己的账号及所用工具。
4. 打开应用，用哔哩哔哩 App 扫码并确认登录。保存二维码后切换到官方 App 扫码，返回时会继续查询同一个二维码。升级后如果提示缺少客户端互动授权，重新扫码一次即可；取消扫码保留现有登录。

更新时尽量保持相同的签名身份和 Bundle ID。换签名身份、改 Bundle ID 或删除旧 App 可能导致无法继承原有数据或钥匙串登录，请先导出需要保留的下载。不要将 Apple Account 密码或开发者私钥提交到本项目。

本项目没有 TestFlight 或 App Store 版本，也不提供签名证书。Apple 官方文档：[向已注册设备分发应用](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)、[启用开发者模式](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。

## 提示“IPA 不完整”或无法安装

- 从 Release 的 **Assets** 下载 `.ipa`，不要下载源码 ZIP、网页或尚未完成的下载文件，也不要只修改它们的后缀名。
- 核对同一 Release 的 `SHA256SUMS.txt`。Mac 可执行 `shasum -a 256 文件名.ipa`；Windows PowerShell 可执行 `Get-FileHash 文件名.ipa -Algorithm SHA256`。不一致时重新下载。
- 校验一致后仍报错，请提供签名工具名称与版本、iOS 版本、失败阶段（导入、签名或安装）和完整错误截图。不要提供 Apple Account 密码、私钥、证书密码或描述文件。
- “无法验证完整性”也可能发生在签名或安装阶段；仅凭这句提示不能判断 ZIP 是否损坏。核实自己的证书、描述文件、设备及 Bundle ID 是否匹配，避免删除旧应用后丢失数据。

0.1.2 起，IPA 加入不带个人证书的 ad-hoc 临时签名，保留常规代码签名与资源校验结构；仍须由签名工具换成自己的有效签名。这不等于 Apple 的 Ad Hoc 设备分发授权。旧版 0.1.1 的公开包经重新下载验证没有缺失文件；尚未取得反馈者使用的签名工具与完整错误，因此不把其个案标记为已经复现和修复。

## 从源码构建并安装

需要 macOS、Xcode 27+ 和自己的 Apple Account；必须克隆整个仓库，iOS 工程引用共享源码与本地 Vendor。

1. 用 Xcode 打开 `Apps/iOS/BilibiliNEXT.xcodeproj`，选择 `BilibiliNEXT` Scheme。
2. 在 Signing & Capabilities 中选择自己的 Team，并设置该团队可用的 Bundle Identifier。
3. 连接并选择 iPhone / iPad，按 Xcode 提示完成签名、安装和开发者模式设置。

也可以使用脚本：

```sh
# 开发真机构建，填写自己的团队与设备
IOS_PLATFORM=device DEVELOPMENT_TEAM=YOUR_TEAM IOS_DEVICE_ID=YOUR_UDID Scripts/build-ios.sh

# 生成不含个人证书的自签用 Release IPA
OUTPUT_DIR="$PWD/.build/release-assets" Scripts/package-ios.sh

# 检查打包结构、主程序和临时签名
python3 Scripts/validate-ipa.py .build/release-assets/Bilibili-NEXT-0.1.3-iOS-self-sign.ipa
```

脚本在 `.build/ios-package.*` 保留归档与日志，默认不上传；IPA 只包含 `Payload/Bilibili NEXT.app`。打包后自动检查 ZIP 完整性、主程序、设备架构、资源和临时签名。不代表所有第三方签名工具都已实测。

## 当前范围

这是开发预览版，手机端功能尚未完全对齐 Mac。真实服务端互动受账号和平台规则影响；后台下载、iPad 多窗口生命周期、画中画恢复和复杂高级弹幕仍有验证缺口。详细已实现功能、实机记录和限制见 [IOS_STATUS.md](IOS_STATUS.md)。

项目面向个人学习研究，与哔哩哔哩官方无任何关联。源码保留 MIT 许可，第三方声明见 [THIRD_PARTY.md](THIRD_PARTY.md)。
