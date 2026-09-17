# macOS 27 适配阶段记录

日期：2026-09-17。应用版本：0.1.1（build 2）。

## 环境与范围

- 本机系统：macOS 27.0（26A428），Apple silicon。
- 工具链：Xcode 27.0（27A266a）、Swift 6.4、macOS 27.0 SDK。
- 最低运行版本仍为 macOS 14.0；本轮没有在旧系统上重新实测。
- DHCP、DNS、XPC 协议和配置存储格式不变。

现有代码在新工具链上的基线构建和 303 项测试通过，未发现必须修改网络服务实现的编译问题。
本阶段主要适配系统输入控件，并修正验证时发现的原有布局问题。

## 修改

1. `AdaptiveTextFieldStyle.swift`：使用 Xcode 27 编译且运行于 macOS 27 时，采用
   `.bordered` 和 `.textInputBorderShape(.roundedRectangle)`。旧系统使用 `.roundedBorder`；
   编译器条件分支保留 Xcode 26 工具链的原有路径，该旧工具链路径本轮未实测。
2. `NetworkSettingsCard.swift`：网络地址、地址池、租期、DNS 输入框使用统一样式，并增加持续显示的字段名称。
3. `LogsView.swift`：搜索框采用统一样式；空状态填满剩余空间，工具栏保持在页面顶部。
4. `PageRenderer.swift`：补充网络配置页的中英文离屏截图；版本信息改为读取构建产物，避免显示旧版本。
5. `Identifiers.xcconfig` 和三语 README：记录 0.1.1 阶段版本、303 项测试和兼容范围。

新 API 的可用性同时通过本机 SDK 声明和
[Apple macOS 27 发布说明](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)核对。
工具链说明见 [Xcode 27 发布说明](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)。

## 验证

| 检查 | 结果与边界 |
| --- | --- |
| `make test` | 303 项通过：核心 195、Helper 集成 73、应用逻辑 35；不包含前台 UI 测试 |
| `make build` | macOS 27 SDK 的 Debug 构建通过；项目代码启用警告视为错误 |
| `make screenshots` | 7 个页面 × 中英文，共 14 张离屏渲染；检查配置字段和日志布局 |
| `make verify-bundle` | 应用、Helper、内置 dnsmasq 的签名和包结构通过；Debug 不要求 Universal 2 |
| `Scripts/check-localization.sh` | 简体中文翻译检查通过 |
| `git diff --check` | 无空白错误 |
| 本机应用安装 | `/Applications/DnsmasqForMac.app` 已更新为 0.1.1（2），安装后嵌套签名校验通过；解锁后退出旧窗口并重开 |

复现命令（需完成仓库 README 中的签名和 dnsmasq 构建准备）：

```bash
make test
make build
make screenshots
make verify-bundle
Scripts/check-localization.sh
git diff --check
```

本机日志保存在 `/tmp/dnsmasq-macos27-*.log`，不作为源码备份内容；页面输出位于
`build/Screenshots/{en,zh-Hans}/`，可以重新生成。

## 尚未完成的验证

- Mac 锁屏，未执行前台点击、键盘输入和 XCUITest。
- 未重新验证系统升级后的 Helper 注册、系统授权和真实 XPC 往返。
- 未接入 BMC/DHCP 客户端；没有声称 DHCP 获租约、BMC 网页连接或拔线后的完整清理已通过。
- macOS 14–26、Intel/Rosetta 运行和 Developer ID 公证分发未在本轮验证。

现场使用仍按 [BMC 使用说明](BMC_FIELD_GUIDE.zh-CN.md) 和
[手工测试计划](MANUAL_TEST_PLAN.md) 检查。离屏截图和模拟 Helper 测试不能代替实机验收。

## GitHub 阶段备份

本阶段以普通 Git 提交和注解标签 `checkpoint/macos27-2026-09-17` 保存到现有远端。
这是可回溯的源码检查点，不是已公证的二进制发行版。

后续阶段沿用以下约定：验证实际改动、记录通过项和未测项、提交相关源码与文档、推送提交和阶段标签、
最后核对远端提交号。避免覆盖旧标签或强制推送，保证先前阶段仍可找回。

查看本阶段：

```bash
git fetch origin --tags
git show --stat checkpoint/macos27-2026-09-17
```
