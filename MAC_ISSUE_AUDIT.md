# macOS Issue 核对与修复

核对日期：2026-11-08。基线：`dbf7bc7`。范围为原仓库现有 Mac 功能的缺陷；未修改 iOS 界面、原仓库 Issue 状态或讨论。

用户已确认优先修复现有 Mac 功能，不在本批扩展自动更新、直播/追番/影视模块或 macOS 15 兼容。用户本人尚未遇到 HDR/杜比过曝，因此目前没有新增复现样片；相关修复仍按下述证据范围记录，不将原报告标为完全解决。

## 本批次修改

| Issue | 结果与证据 |
| --- | --- |
| [#9 收藏夹切换不刷新](https://github.com/wzk112/Bilibili-NEXT/issues/9) | 已复现并修复。收藏列表以 `browseKey` 为标识重建，而选择监听原先位于该列表内部，导致切换时监听丢失；自动分页可能将新夹内容追加至旧列表。监听现位于稳定的外层。实际 Mac SwiftUI 视图测试在修改前失败、修改后通过，包含快速切换和迟到请求。 |
| [#11 全屏光标与屏幕保护](https://github.com/wzk112/Bilibili-NEXT/issues/11) | 全屏播放控件闲置隐藏后隐藏光标；移动指针、键盘操作、暂停、退出或切走应用后恢复。播放期间持有 `idleDisplaySleepDisabled` 活动，暂停、停止、失败或销毁时释放。生命周期测试及实际播放器中的系统电源断言检查通过。 |
| [#10 快捷键、HDR/杜比显示](https://github.com/wzk112/Bilibili-NEXT/issues/10) | 补充倍速、音量、静音、弹幕快捷键，保留输入框及系统组合键行为。修复清晰度编号覆盖显式 SDR 传递函数的问题，包括 Dolby Vision SDR 兼容底层；PQ/HLG 和 Dolby HDR 兼容底层保持正确。Mac 视频层和迷你播放器采用系统自动动态范围。可控元数据检查在修改前失败、修改后通过；Apple 官方 HDR 样片实际出画。**原报告没有 BV 号或显示器信息，不能据此宣称原视频的过曝已彻底解决。** |

快捷键：`↑/↓` 调整音量，`M` 静音，`D` 切换弹幕，`[/]` 或 `</>` 调整倍速，反斜杠恢复 `1×`。倍速范围与菜单一致，为 `0.5×–2×`。输入文字时不拦截这些按键；暂停时调整倍速不会启动播放。

## 其余开放 Issue

| Issue | 本轮处理范围与当前状态 |
| --- | --- |
| [#1 媒体地址无效](https://github.com/wzk112/Bilibili-NEXT/issues/1) | 已有上游修复，讨论中两位报告者均确认更新后恢复。保留并回归播放地址解析、备用源及 Range 校验；不重复声称本轮修复。 |
| [#2 返回列表位置丢失](https://github.com/wzk112/Bilibili-NEXT/issues/2) | 已有上游修复。现有独立列表、分页及浏览位置回归通过。 |
| [#4 弹幕滚动与卡片信息](https://github.com/wzk112/Bilibili-NEXT/issues/4) | 已有弹幕连续布局及播放量、投稿日期修复。保留并运行相关回归；原报告中未指定视频的整体流畅度仍需具体样片确认。 |
| [#5 浅色弹幕设置可读性](https://github.com/wzk112/Bilibili-NEXT/issues/5) | 已在上游 1.1.4 修复，保留与文字配套的背景底色及弹窗颜色模式。 |
| [#6 重启后不能播放](https://github.com/wzk112/Bilibili-NEXT/issues/6) | 原附件属于 BiliSail，未提供本项目的复现诊断。独立退出、重启进程后，同一公开视频播放检查通过；这不能替代原受影响环境的复测。 |
| [#7 macOS 15 无法安装](https://github.com/wzk112/Bilibili-NEXT/issues/7) | 当前最低要求为 macOS 26，使用多处该版本的系统 API。未通过降低版本声明伪造兼容；macOS 15 需单独实现和验证回退界面与播放路径。 |
| [#3 直播、追番、影视模块](https://github.com/wzk112/Bilibili-NEXT/issues/3) | 新增原生模块不属于本批缺陷修复。播放页标题相关反馈已由基线及本地前序修改处理。 |
| [#13 检查和自动更新](https://github.com/wzk112/Bilibili-NEXT/issues/13) | 新增更新系统未在本批实现；需单独确定更新源、校验与安装/回滚流程。 |

[#8](https://github.com/wzk112/Bilibili-NEXT/issues/8) 明确针对 iOS，不纳入本轮。

## 验证

自动回归：`swift test`，266 项、38 组通过。新增检查：

```sh
swift test --filter 'MacFavoritesRefreshTests|MacPlayerKeyboardTests|MacPlaybackSessionTests|MacDynamicRangeTests'
```

实际播放器使用公开视频 `BV16SHe6pEZ2`：确认出画、切换画质保留进度及暂停状态、全屏进出、实际快捷键、空闲隐藏及暂停恢复指针、系统防屏保断言创建/释放和临时缓存清理。另以新进程重新打开该视频，确认再次出画并释放断言。

HDR 呈现另使用 [Apple 官方高级 HLS 样例](https://developer.apple.com/streaming/examples/advanced-stream-dv-atmos.html) 的 PQ/HEVC 变体验证出画；这只证明该测试环境下的播放及呈现路径，没有覆盖所有显示器或原 Issue 样片。

相关公开 API：Apple 的 [动态范围呈现说明](https://developer.apple.com/documentation/coregraphics/adopting-advancements-in-hdr-image-rendering)、[防闲置显示器休眠活动](https://developer.apple.com/documentation/foundation/processinfo/activityoptions/1416839-idledisplaysleepdisabled)和 [NSCursor](https://developer.apple.com/documentation/appkit/nscursor)。
