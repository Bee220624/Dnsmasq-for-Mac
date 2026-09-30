# macOS 27 前台与 Helper 验证记录

验证日期：2026-09-20。测试机为 macOS 27.0（26A428），Xcode 27.0（27A266a）。应用版本 0.1.1（2），Debug 本地开发签名，Team ID `MDUMXF88CA`。本轮从 `69c7f1f` 继续，修复清理保护、测试命令退出码和 UI fixture DNS 隔离。此构建不是已公证的对外发行包。

截至 2026-09-20：**软件回归、首次 Helper 批准和真实身份握手通过，M1 的 BMC 链路验收尚未完成。** 2026-09-29 现场预检发现引擎路径与安装所有权问题；见文末补充，先前握手通过不代表引擎可启动。后续安装构建 3 后确认引擎检查和已知 BMC 地址连通；新的 DHCP 请求、固定 IP 模式、拔线清理和完整前台交互仍需实机验证。

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
| 从“应用程序”首次启动与真实系统授权 | PASS（批准路径） | `make install-dev` 完成安装后，工程师在系统设置中批准 Helper。`launchctl print system/com.bee.dnsmasqformac.helper` 确认服务由 `SMAppService` 管理、位于 system domain、状态为 running，签名标识为 `com.bee.dnsmasqformac.helper`，Team ID 为 `MDUMXF88CA`。拒绝、取消及再次批准路径尚未实测。 |
| 真实 Helper 服务信息 | PASS（身份与连接） | 真实 XPC 请求日志返回 `version=0.1.1 protocol=1 euid=0 build=debug`；`launchctl` 同时确认 Mach 服务 `com.bee.dnsmasqformac.helper` 已激活。`make verify-bundle` 已单独验证内置 dnsmasq 的摘要和签名；日志未打印 `engineVerification` 的可选返回字段，因此未把该字段记作独立的运行时证据。 |
| DHCP／固定 IP BMC 链路 | NOT RUN | 未启动真实 DHCP；无本轮获确认的隔离 BMC 链路证据。 |

主体实现已处理：非停止状态仍可移除 Helper、清理后运行状态变化未复查、旧握手覆盖新状态、`staleSessionRequiresAttention` 丢失清理入口、未注册但文件缺失时仍提供安装操作，以及清理失败可被预检清除的绕过路径。相关回归用例均通过。

仍存在的限制：无回复的 XPC 回调尚无超时／取消完成机制，可能使操作持续等待；连接中断后的 Helper ready 显示没有新增即时失效机制，仍依赖刷新，不能把旧的 ready 当作实时连通证明。真实旧版本 Helper 修复、授权拒绝／取消及再次批准未经本轮验证。假客户端通过、离屏截图、签名校验或真实 Helper 握手均不能替代 BMC 链路实机验收。

## 2026-09-29 现场补充：引擎预检失败

已安装的 0.1.1（2）在概览页显示 `Engine Not Found`，技术详情为 `/Contents/Library/HelperTools/dnsmasq: No such file or directory`。检查确认 `/Applications/DnsmasqForMac.app/Contents/Library/HelperTools/dnsmasq` 实际存在，Helper 也由 `SMAppService` 在 system domain 运行。根因是 launchd 以相对路径设置 Helper 的 `argv[0]`，而 Helper 用该参数拼出 dnsmasq 路径；安装脚本还把内置引擎留为普通用户所有，与 Helper 的 root 所有权校验不符。先前的真实身份握手因此不能证明引擎预检或 DHCP 已可用。

0.1.1（3）源码改为从内核查询 Helper 的实际可执行文件路径，开发安装脚本以管理员权限将应用包及内置引擎安装为 root 所有，并补充路径与安装回归测试。安装脚本回归 65 项、Helper 测试 74 项、App 测试 53 项，以及 Debug 构建与包校验均通过。仍须卸载运行中的旧 Helper、安装新应用、重新批准 Helper，并在真实应用中复查引擎预检；在此之前不记为实机修复通过。BMC 获租约、固定 IP 连接和拔线清理仍待现场验证。

## 2026-09-29 后续现场检查

已安装构建 3，真实 Helper 运行且内置引擎检查通过。`en7` 链路为 1000baseT 全双工，Mac 临时地址为 `192.168.1.29/24`。BMC `192.168.1.193` 的 ping 2/2 成功，TCP 80/443 接受连接；这些只读检查确认网络连通，不代表网页登录或 DHCP 重新分配通过。

工程师报告首次在 `.30–.200` 池中获得 `.193`，缩小为 `.30–.100` 后未换地址。改回 `.30–.200` 后提供的会话日志显示 12 小时租期和启动记录，没有新的 DISCOVER/REQUEST/ACK/NAK；租约列表为空但旧 IP 仍连通，符合客户端保留旧租约的表现。尚未直接确认 BMC 的 DHCP/静态设置，也没有 `.30–.100` 会话的完整日志，故不把根因记作已确认。

## 2026-09-30 日期地址预设：0.1.1（4）

新增手动单地址池预设，沿用当前私有 `/24` 网段，末段为 `100 + Mac 当地日期中的日`。它只修改配置草稿中的池起止地址，运行期间不可修改，也不改变租期或 BMC 设置。拒绝与 Mac 或已提供的网关冲突的目标；非 `/24`、非私有网段或 DHCP 关闭时不可应用。租约空状态补充旧租约、固定 IP、重新请求 DHCP 与停止不能恢复 BMC 配置的说明。

`make test` 通过：SwiftPM 套件、Helper 74 项、App 53 项、安装脚本 65 项、Makefile 7 项断言均通过。新增测试覆盖 1/30/31 日、当地时区跨日、跨月保持网段、只修改池端点、Mac/网关冲突及不支持的配置。`make check-localization` 和 `make verify-bundle` 通过；中文词条完整，Debug 的 Universal 2 检查按设计跳过。本轮还用内置 dnsmasq 的 `--test` 确认单地址池配置语法有效，没有为语法检查启动服务。

`make screenshots` 成功生成中英文各 7 张图片，已检查两种语言的网络设置页：日期预设按钮、当天地址预览和限制说明均可见，无重叠。日期预设套件再次执行，7 项测试通过。离屏截图不代替按钮交互或真实客户端续租验收。

本阶段不自动恢复 BMC 接入前的网络设置，不发送强制续租或管理 API 请求。构建 4 尚未替换现场安装的构建 3；当天地址的真实 DHCP 分配、BMC 续租和回接原网络仍待现场验证。
