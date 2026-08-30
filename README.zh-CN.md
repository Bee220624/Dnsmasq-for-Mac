<div align="center">

# Dnsmasq for Mac

**给 dnsmasq 做的 macOS 图形界面——不用开终端，也能在实验网段发 DHCP 和 DNS。**

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey?style=flat-square)
![swift](https://img.shields.io/badge/Swift-6-orange?style=flat-square&logo=swift&logoColor=white)
![dnsmasq](https://img.shields.io/badge/dnsmasq-2.93-blue?style=flat-square)
![tests](https://img.shields.io/badge/tests-278%20passing-brightgreen?style=flat-square)
![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)
![status](https://img.shields.io/badge/status-source%20only-yellow?style=flat-square)

[English](README.md) · **简体中文** · [日本語](README.ja.md)

<img src="Docs/screenshots/02-overview-zh.png" width="840" alt="总览">

</div>

---

## 为什么会有这个东西

想在 macOS 上用 dnsmasq，找了一圈带界面的，只找到一个，还是收费的。

说到底就是给 dnsmasq 套一层窗口的事，不该收钱。那就自己做一个，开源。

## 当前功能

- 给指定的有线网卡加**临时** IPv4 地址，停止时自动移除
- 单网段 DHCPv4，可配地址池、租约时长、Router / DNS 选项
- DNS 转发（系统 DNS / 自定义 / 仅本地记录），支持本地 A 记录和 `lab.test` 这类本地域名
- 实时看租约和日志，日志可按 DHCP / DNS / 警告 / 错误分类过滤，可导出为文本
- 配置存成 Profile，随时切换
- 不动任何系统配置——不碰 `/etc/hosts`、不碰 `/etc/dnsmasq.conf`，不留永久改动。无遥测、运行时不联网、
  不会自动启动
- Wi-Fi 和当前上网的那块网卡禁止开 DHCP，在特权 helper 里强制执行，不只是界面上灰掉

## 界面截图

<table>
<tr>
<td width="50%"><img src="Docs/screenshots/01-onboarding.png" alt="安装 helper"></td>
<td width="50%"><img src="Docs/screenshots/03-leases.png" alt="租约"></td>
</tr>
<tr>
<td align="center"><b>安装特权 helper</b></td>
<td align="center"><b>租约</b></td>
</tr>
<tr>
<td width="50%"><img src="Docs/screenshots/04-logs.png" alt="日志"></td>
<td width="50%"><img src="Docs/screenshots/05-profiles.png" alt="配置"></td>
</tr>
<tr>
<td align="center"><b>日志</b></td>
<td align="center"><b>配置 Profile</b></td>
</tr>
<tr>
<td width="50%"><img src="Docs/screenshots/06-settings.png" alt="设置"></td>
<td width="50%"><img src="Docs/screenshots/02-overview.png" alt="英文界面"></td>
</tr>
<tr>
<td align="center"><b>设置</b></td>
<td align="center"><b>English 界面</b></td>
</tr>
</table>

界面有英文和简体中文两套，跟随系统语言。所有截图可以用 `make screenshots` 按每种语言重新生成。

## 怎么跑起来

需要 macOS 14+ 和 Xcode 26+。

```bash
make bootstrap        # 装开发工具，生成 Xcode 工程
make vendor-dnsmasq   # 拉取并编译 dnsmasq 2.93（Universal 2）
make build
make test
```

`Config/Identifiers.xcconfig` 里的 `DEVELOPMENT_TEAM` 是我的 Team ID，**换成你自己的**才签得下来。
项目里所有标识符都只住在这一个文件里。

`DnsmasqForMac.xcodeproj` 是生成的，不进版本库——`project.yml` 才是唯一事实来源。

## 现在的状态

能编译，278 个自动化测试全绿。但**有些东西我还没法验证**：

- 没有 Developer ID 证书，所以签名分发和公证走不通——这也是为什么现在只有源码、还没有可下载的安装包
- 特权 helper 的注册需要在系统设置里人工批准，端到端的 XPC 链路没有实测过
- 真实 DHCP/DNS 交互需要真设备，[`Docs/MANUAL_TEST_PLAN.md`](Docs/MANUAL_TEST_PLAN.md) 里写了逐步的手工测试

这些都记在 [`Docs/RISKS.md`](Docs/RISKS.md) 里，没有当作通过。

## 关于 dnsmasq

App 里附带的 dnsmasq 是**独立的、未经修改的可执行文件**，通过配置文件和进程管理调用，没有任何 dnsmasq
代码被编译或链接进本项目的二进制。dnsmasq 由 Simon Kelley 编写，采用 GPL v2 或 v3；两份许可证全文都
随 App 包一起分发，每个发行版还会附带对应的源码。

Dnsmasq for Mac 自身采用 [MIT 许可证](LICENSE)。两者不冲突，正是因为 dnsmasq 从未被链接进来——
MIT 管的是本仓库里的代码，GPL 管的是它启动的那个程序。

## 文档

| | |
|---|---|
| [`Docs/ARCHITECTURE.md`](Docs/ARCHITECTURE.md) | App、特权 helper 和 dnsmasq 三者怎么拼在一起 |
| [`Docs/SECURITY.md`](Docs/SECURITY.md) | 信任边界，以及哪些威胁是刻意不防的 |
| [`Docs/PRIVILEGED_HELPER.md`](Docs/PRIVILEGED_HELPER.md) | helper 的安装、批准、修复与卸载 |
| [`Docs/DNSMASQ_BUILD.md`](Docs/DNSMASQ_BUILD.md) | 附带的 dnsmasq 如何获取、校验和编译 |
| [`Docs/RISKS.md`](Docs/RISKS.md) | 所有已知没落定的问题 |
| [`Docs/MANUAL_TEST_PLAN.md`](Docs/MANUAL_TEST_PLAN.md) | 需要真实硬件才能做的测试 |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | 提 patch 要守的规矩，以及每条规矩的来由 |
