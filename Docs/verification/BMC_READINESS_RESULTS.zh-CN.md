# macOS 27 前台与 Helper 验证记录

验证日期：2026-09-19。测试机为 macOS 27.0（26A428），Xcode 27.0（27A266a）。应用版本 0.1.1（2），Debug 本地开发签名，Team ID `MDUMXF88CA`。代码基线为 `bfdaf07`，下表对应随本文提交的 Helper 防护及测试隔离改动。此构建不是已公证的对外发行包。

| 项目 | 结果 | 证据与边界 |
| --- | --- | --- |
| Helper 与 App hostless 单元测试 | PASS | `make test-xcode`：Helper 73 项、App 53 项，0 失败。系统注册与 XPC 均使用注入替身。 |
| 移除 Helper 的客户端防护 | PASS | 实际 `HelperClient` 拒绝启停中、恢复中、失败及未完成清理状态；允许明确停止且清理完成；清理后再次读取运行状态。异步等待期间拒绝交错的安装、预检和启动。 |
| 移除入口及清理重试模型 | PASS | 未同步、活动会话、状态未知及清理未完成时不允许移除；失败停止保留会话；两种未完成清理结果均保留无活动会话时的清理重试。确认动作再次检查模型条件。确认框交互尚未实测。 |
| 身份握手与刷新 | PASS | 实际 `HelperClient` 对非 root UID、协议不匹配返回不兼容；XPC 错误可重新握手；注册等待批准不等于 ready。旧握手不能覆盖较新的等待批准状态。engine 未校验与 Helper ready 分别呈现。以上均为受控回调测试，不是真实系统握手。 |
| UI 测试依赖隔离 | PASS | DEBUG 入口成套选择假 Helper、固定接口、全新临时 profiles；非法场景拒绝启动，不回落生产。所有 Helper 操作终止于假客户端，启动始终拒绝；不访问真实注册 API、XPC、系统接口监听或网络服务。 |
| Debug 构建 | PASS | `make build` 成功；最低部署版本保持 macOS 14.0。旧系统本轮未执行。 |
| 应用包与签名 | PASS | `make verify-bundle` 通过；dnsmasq 2.93 摘要与签名检查通过。Debug 按设计跳过 Universal 2 检查（1 条提示）。 |
| 中文翻译完整性 | PASS | `Scripts/check-localization.sh` 通过：编译器提取 263 项，词条库 266 项，其中 3 项现有未引用词条。 |
| UI 自动化执行、截图及交互验收 | NOT RUN | 尚未运行 UI 测试或生产应用。配置页测试已使用 ready fixture，并移除因缺少 Helper 而跳过的分支；新增中文界面输入、Tab 和滚动用例仅完成编译。 |
| 从“应用程序”首次启动与真实系统授权 | NOT RUN | 未执行允许、拒绝、取消及再次批准；未据模拟结果推断首次启动行为。 |
| 真实 Helper 服务信息 | NOT RUN | 未读取本轮真实 `getServiceInfo` 的 Helper 版本、协议、有效 UID 和 engine 校验结果。 |
| DHCP／固定 IP BMC 链路 | NOT RUN | 未启动真实 DHCP；无本轮获确认的隔离 BMC 链路证据。 |

已复现并修复：非停止状态仍可移除 Helper、清理后运行状态变化未复查、旧握手覆盖新状态、`staleSessionRequiresAttention` 丢失清理入口，以及未注册但文件缺失时仍提供安装操作。修复前测试出现对应失败，修复后全部通过。

仍存在的限制：无回复的 XPC 回调尚无超时／取消完成机制，可能使操作持续等待；连接中断后的 Helper ready 显示没有新增即时失效机制，仍依赖刷新，不能把旧的 ready 当作实时连通证明。真实旧版本 Helper 修复及系统授权往返未经本轮验证。假客户端通过、离屏截图或签名校验均不能替代这些实机验证。
