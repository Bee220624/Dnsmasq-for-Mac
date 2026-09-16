# BMC 现场使用与本次修复

本工具用于 Mac 有线直连 BMC 或隔离管理网络。DHCP 只对会请求 DHCP 的设备有效，不能自动识别任意未知固定 IP，也不能把固定 IP 的 BMC 改成 DHCP。

## 出发前

### 快速打开，无需 Xcode

修复版已安装在 `/Applications/DnsmasqForMac.app`。按 `⌘ Space` 搜索 `DnsmasqForMac` 或 `Dnsmasq for Mac` 即可启动；也可以在 Finder 的“应用程序”中双击，或将应用拖到 Dock 长期保留。只有修改源码、需要生成新版本时才需要编译。

终端也可直接运行：

```bash
open /Applications/DnsmasqForMac.app
```

### 网线识别

启动后默认开启自动识别，不再根据上次 BSD 编号或列表顺序选择 `en1`：

- 没有可用有线链路：保持未选择并提示接线。网卡插在 Mac 上但网线未接入已供电设备时，也不会自动选中。
- 只有一个可用有线链路：自动选中，并显示网卡名称、BSD 编号、MAC 和链路状态。
- 多个可用有线链路：不猜测目标，提示在“选择有线网卡”下拉框中手动指定。
- 下拉框始终提供手动选择入口，包括用于提前准备的无链路网卡。手动选择会固定网口；点击“恢复自动识别”可返回自动模式。
- 运行或启停过程中锁定当前接口；不会因另一根网线接入而切换运行网口。

自动识别确认的是物理链路，不会凭链路状态推断对端身份或是否为隔离网络。接口编号可能随设备和端口变化，启动前仍需核对接线。

### 安装与检查

1. 打开 `/Applications/DnsmasqForMac.app`，点击“安装 Helper”。若系统要求批准，进入“系统设置 → 通用 → 登录项与扩展”，允许对应后台项目，再返回应用检查状态。DHCP 不会因安装或打开应用而自动启动。
2. 插上准备带去现场的 USB/雷电转 RJ45 网卡，确认它在列表中的名称与 BSD 接口。不要直接沿用 `en1`：本次 Mac 的 `en1/en2/en3` 是 Thunderbolt 接口。
3. 确认网线接的是服务器 BMC/管理口，目标网络隔离。尚未接设备时“无链路”是预期状态。
4. 旧配置不会被覆盖；若 DNS 仍为“系统 DNS”，无互联网时改为“仅本地记录（离线可用）”或关闭 DNS。修改后按“保存”。

## BMC 使用 DHCP

1. 选择正确的有线网卡，确认链路已连接。
2. 示例配置：Mac `192.168.50.1`，前缀 `/24`，地址池 `192.168.50.10–192.168.50.200`。
3. 启用 DHCP，关闭“向客户端提供网关”；可启用 DNS 并选择“仅本地记录”。Mac 不提供 NAT 或互联网共享。
4. 确认隔离网络，点击“校验”，处理阻断项，再点击“启动”。
5. 在“租约”查看设备，点击 IP 打开 HTTPS 管理网页；右键菜单也提供 HTTP。
6. 若租约未出现，检查网口、链路、BMC 待机供电和 DHCP 设置；在日志查找 DISCOVER/OFFER/REQUEST/ACK。设备可能仍持有旧租约，或根本配置为固定 IP。不要为获取租约而盲目重置生产 BMC。
7. 完成后点击“停止”，确认状态停止。若显示清理错误，保持网卡连接并重试“停止/清理残留”。

## 已知 BMC 固定 IP

假设 BMC 是 `192.168.0.120/24`：

1. **关闭 DHCP**，开启 DNS 并选择“仅本地记录”。当前版本通过 DNS 会话管理临时地址的生命周期。
2. 开启“添加临时 IPv4 地址”，给 Mac 设置同网段且未占用的地址，例如 `192.168.0.10/24`；不要把 BMC 地址填成 Mac 地址。
3. 校验并启动，在浏览器访问 BMC 的固定 IP。此设备不会出现在 DHCP 租约列表。
4. 使用完点击“停止”，应用撤销自己添加的 Mac 地址。

如果目标网段与 Wi-Fi、其他有线网络或 VPN 地址重叠，应用会阻止已检测到的接口网段重叠。选择其他设备网段，或断开冲突网络后再试；VPN 的所有路由规则尚未被完整枚举。

## 未知固定 IP

通过资产记录、机身标签、机房管理平台，或服务器本地 BIOS/BMC 配置页面确认地址与掩码。此版本没有 ARP 扫描、抓包或跨网段发现能力；DHCP 等待页面为空并不能证明 BMC 故障。浏览器的证书提示需要工程师核对目标设备后自行处理，应用不会绕过证书验证。

## 本次审查与修复

- 补齐原先占位的 IPv4、DHCP、DNS 编辑表单、中文翻译和配置错误反馈。
- 新建 BMC 配置使用本地 DNS，避免离线时因缺少上游 DNS 无法启动；现有保存配置保持不变。
- 修复运行中校验覆盖会话状态、错误会话 ID 的 Stop 删除当前记录的问题。
- 修复 helper 重启后未恢复完整会话的问题，持久化运行快照并恢复租约、日志与停止操作。
- 修复停止/回滚/恢复清理失败仍丢弃记录的问题；保留失败状态和可重试清理路径。
- 增加运行中网卡消失、身份改变或成为默认路由时的自动停止；不会自动启动新会话。
- 增加跨接口 IPv4 子网重叠与地址缺失/掩码冲突检查，避免 BMC 流量走错网卡。
- 修复临时 alias 与外部配置竞争时误认地址所有权的问题。
- 修复运行目录父级阻止降权后的 dnsmasq 访问文件的问题；journal 仍为 root-only。
- 修复 UI 不持续同步后台状态、停止通信失败即声称已停止、过期校验结果阻止启动的问题。
- 修复首次安装把“服务未找到”误报为“包内 helper 缺失”的引导路径。
- 修复 Makefile 吞掉测试失败退出码、截断编译错误的问题。

dnsmasq 的降权、配置语法校验、接口选择语义依据随仓库提供的 2.93 源码和[官方手册](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html)。`interface` 与 `listen-address` 是并集：当前配置限制到所选接口，但不承诺 DNS 仅监听该接口的一个地址。

## 验证边界

同日追加的网线识别修复：核心测试 195 项、helper 集成 73 项、应用测试 35 项，共 303 项通过。新增覆盖无网线、接入/拔出网线、多个活动网口、手动选择保留、同名网卡更换及运行期间锁定。日志：`/tmp/dnsmasq-cable-tests.log`。锁屏期间未执行前台交互或真实 BMC 接线测试。

2026-09-11 本机验证：`make test` 通过 295 项（核心 194、helper 集成 73、应用测试 28）；`make build`、`make verify-bundle`、`Scripts/check-localization.sh`、`git diff --check` 通过。九份 Golden 配置由内置 dnsmasq 实际执行 `--test --conf-file=...`，均返回 0。完整日志在本机 `/tmp/dnsmasq-tests-installation.log` 和 `/tmp/dnsmasq-bundle-check-full.log`。

软件测试覆盖配置校验、生成、存储、状态同步、租约解析和模拟的 helper 成功/失败路径；内置 dnsmasq 已对九份配置通过 `--test`。构建、嵌套签名和 bundle 校验通过。本次使用的是本机 Apple Development 签名的 Debug 构建，不是已公证的对外发行包。

当前没有接入 BMC/DHCP 客户端，因此真实 DHCP 获租约、浏览器连通 BMC、物理拔线后的完整系统清理尚未完成。不要把自动化测试通过理解为实机端到端验收已完成。首次系统 helper 授权必须完成后才可使用服务。

## 修改文件

- `Apps/DnsmasqForMac/Features/Overview/{OverviewView,NetworkSettingsCard}.swift`：可编辑网络配置。
- `Apps/DnsmasqForMac/Features/Leases/LeasesView.swift`：BMC 网页入口与准确的空状态。
- `Apps/DnsmasqForMac/Infrastructure/Helper/{SessionController,SessionClient,HelperClient,HelperInstallationState}.swift`：运行状态同步、停止重试及安装判断。
- `Apps/DnsmasqForMac/App/{AppState,DnsmasqForMacApp,GlobalStatusBar}.swift`：应用状态和全局控制。
- `Apps/DnsmasqForMac/Resources/Localizable.xcstrings`：新增界面的中文翻译。
- `Daemons/DnsmasqForMacHelper/Runtime/{SessionCoordinator,InterfaceAliasManager,PreflightRunner,RuntimeFileManager,SystemBoundary}.swift`：生命周期、地址所有权、网段检查及文件权限。
- `Packages/MacNetCore/Sources/MacNetInterfaces/InterfaceAddressPolicy.swift`：共享接口地址校验。
- `Packages/MacNetCore/Sources/MacNetModels/{DefaultProfile,SessionJournal}.swift`：离线默认值和恢复快照。
- `Packages/MacNetCore/Sources/MacNetDnsmasq/DnsmasqConfigurationGenerator.swift`：明确监听选择器的真实语义。
- `Tests/HelperIntegrationTests/{Fakes,RuntimePrimitiveTests,SessionLifecycleTests}.swift` 与 `Tests/DnsmasqForMacTests/{SessionControllerTests,HelperInstallationStateTests}.swift`：新增回归覆盖。
- `Packages/MacNetCore/Tests/MacNetValidationTests/ConfigurationValidatorTests.swift`：离线默认值断言。
- `Makefile`、`project.yml`：可靠的构建退出码及测试源文件配置。
- 网线识别追加修改：`InterfaceSupportPolicy.swift`、`InterfaceMonitor.swift`、`InterfaceCard.swift`、`SafetyCard.swift`、`DnsmasqForMacApp.swift`、`Localizable.xcstrings`、`project.yml`，以及 `InterfaceSupportPolicyTests.swift`、`InterfaceMonitorTests.swift`。
