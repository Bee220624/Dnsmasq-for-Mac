# macOS 27 前台与 Helper 验证记录

验证日期：2026-09-20。测试机为 macOS 27.0（26A428），Xcode 27.0（27A266a）。应用版本 0.1.1（2），Debug 本地开发签名，Team ID `MDUMXF88CA`。本轮从 `69c7f1f` 继续，修复清理保护、测试命令退出码和 UI fixture DNS 隔离。此构建不是已公证的对外发行包。

当前状态：**软件回归通过，M1 的真实系统验收尚未完成。** 独立审查提出的 3 项代码阻断问题均已修复并加入回归测试；首次安装、系统批准、真实 Helper 握手和前台交互仍需要工程师在测试 Mac 上完成，不能由单元测试替代。

- 未完成清理会持续保留 `cleanupFailed` 和恢复需求；预检、启动、Helper 移除均保持阻断，清理重试成功后才放开。
- `test-xcode`、`test-ui` 和 `screenshots` 在命令内显式启用 `pipefail`；退出 42 的假 `xcodebuild` 现在能让三个目标失败，截图构建失败后不会继续渲染。
- 请求构造器由启动依赖注入；生产环境按需读取系统 DNS，UI fixture 固定使用 `192.0.2.53`，测试请求不再读取主机 DNS。

| 项目 | 结果 | 证据与边界 |
| --- | --- | --- |
| Helper 与 App hostless 单元测试 | PASS | `make test`：Helper 73 项、App 53 项，0 失败；SwiftPM 套件通过；安装脚本 58 项、Makefile 7 项断言通过。系统注册与 XPC 均使用注入替身。 |
| 移除 Helper 的客户端防护 | PASS | 实际 `HelperClient` 拒绝启停中、恢复中、失败及未完成清理状态；允许明确停止且清理完成；清理后再次读取运行状态。异步等待期间拒绝交错的安装、预检和启动。 |
| 移除入口及清理重试模型 | PASS（软件回归） | `cleanupIncomplete` 与 `staleSessionRequiresAttention` 均保持失败状态；预检和启动调用次数保持 0，清理重试成功后才恢复操作。确认框交互仍待前台实测。 |
| 身份握手与刷新 | PASS | 实际 `HelperClient` 对非 root UID、协议不匹配返回不兼容；XPC 错误可重新握手；注册等待批准不等于 ready。旧握手不能覆盖较新的等待批准状态。engine 未校验与 Helper ready 分别呈现。以上均为受控回调测试，不是真实系统握手。 |
| UI 测试依赖隔离 | PASS（依赖边界） | DEBUG 入口成套选择假 Helper、固定接口、固定 DNS、全新临时 profiles；非法场景拒绝启动，不回落生产。测试断言实际请求携带 `192.0.2.53`，Helper 操作终止于假客户端，启动始终拒绝。 |
| Debug 构建 | PASS | `make build` 成功；最低部署版本保持 macOS 14.0。旧系统本轮未执行。 |
| 应用包与签名 | PASS | `make verify-bundle` 通过；dnsmasq 2.93 摘要与签名检查通过。Debug 按设计跳过 Universal 2 检查（1 条提示）。 |
| 中文翻译完整性 | PASS | `Scripts/check-localization.sh` 通过：编译器提取 263 项，词条库 266 项，其中 3 项现有未引用词条。 |
| 中英文离屏截图 | PASS（生成） | `make screenshots` 成功生成中英文各 7 张图片。人工检查了两种语言的概览和设置页可见区域，文字与控件未见重叠。截图仅覆盖当前视口，不代表滚动、键盘输入或系统授权通过。 |
| UI 自动化执行及交互验收 | BLOCKED（环境） | 2026-09-20 只读复查确认开发者模式仍未启用。上次 runner 在进入用例前因 `Timed out while enabling automation mode` 失败；新版 Makefile 会正确返回失败码。配置页采用 ready fixture；中文输入、Tab 和滚动用例已编译，尚未执行。 |
| 从“应用程序”首次启动与真实系统授权 | BLOCKED（需人在场） | `make install-dev` 已在写入前完成 Bundle 校验，但读取受保护的 `/var/db/com.bee.dnsmasqformac` 需要管理员授权；非交互 sudo 无法取密码，脚本明确报告未修改任何文件。已安装的 0.1.1（2）保持不变，允许、拒绝、取消及再次批准尚未执行。 |
| 真实 Helper 服务信息 | NOT RUN | 未读取本轮真实 `getServiceInfo` 的 Helper 版本、协议、有效 UID 和 engine 校验结果。 |
| DHCP／固定 IP BMC 链路 | NOT RUN | 未启动真实 DHCP；无本轮获确认的隔离 BMC 链路证据。 |

主体实现已处理：非停止状态仍可移除 Helper、清理后运行状态变化未复查、旧握手覆盖新状态、`staleSessionRequiresAttention` 丢失清理入口、未注册但文件缺失时仍提供安装操作，以及清理失败可被预检清除的绕过路径。相关回归用例均通过。

仍存在的限制：无回复的 XPC 回调尚无超时／取消完成机制，可能使操作持续等待；连接中断后的 Helper ready 显示没有新增即时失效机制，仍依赖刷新，不能把旧的 ready 当作实时连通证明。真实旧版本 Helper 修复及系统授权往返未经本轮验证。假客户端通过、离屏截图或签名校验均不能替代这些实机验证。
