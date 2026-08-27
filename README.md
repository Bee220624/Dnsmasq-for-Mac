# Dnsmasq for Mac

**[中文](#中文) · [English](#english) · [日本語](#日本語)**

![Overview](Docs/screenshots/02-overview.png)

---

## 中文

受不了 macOS 上居然没有一个带 GUI 的 DHCP 服务器，索性自己给 dnsmasq 做了一个。

带着 MacBook 进机房，接一根 USB 转 RJ45，想给 BMC 或交换机管理口临时发个地址——在 macOS 上就得开
终端敲 `ifconfig`、手写 `dnsmasq.conf`、`sudo` 一堆东西，弄完还得记得清理干净。这个 App 就是把这套
流程做成界面：选网卡、选配置、点启动。

### 能做什么

- 给指定的有线网卡加**临时** IPv4 地址，停止时自动移除
- 单网段 DHCPv4，可配地址池、租约时长、Router / DNS 选项
- DNS 转发（系统 DNS / 自定义 / 仅本地记录），支持本地 A 记录和 `lab.test` 这类本地域名
- 实时看租约和日志，日志可按 DHCP / DNS / 警告 / 错误分类过滤、可导出
- 配置存成 Profile，随时切换

### 不做什么

不碰 `/etc/hosts`，不碰 `/etc/dnsmasq.conf`，不永久改任何网络服务。没有遥测、不上传日志、运行时不联网。
不会自动启动。Wi-Fi 和当前承载互联网连接的网卡**禁止**开 DHCP——这条是硬性的，在特权 helper 里强制执行，
不只是界面上灰掉。

### 怎么跑

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

### 现在的状态

能编译、278 个自动化测试全绿。但**有些东西我还没法验证**：

- 没有 Developer ID 证书，所以签名分发和公证走不通
- 特权 helper 的注册需要在系统设置里人工批准，端到端的 XPC 链路没有实测过
- 真实 DHCP/DNS 交互需要真设备，`Docs/MANUAL_TEST_PLAN.md` 里写了逐步的手工测试

这些在 `Docs/RISKS.md` 里都记着，没有当作通过。

### 关于 dnsmasq

App 里附带的 dnsmasq 是**独立的、未经修改的可执行文件**，通过配置文件和进程管理调用，没有任何 dnsmasq
代码被编译或链接进本项目的二进制。dnsmasq 由 Simon Kelley 编写，采用 GPL v2 或 v3。

本项目自身的许可证还没定（`LICENSE_PENDING`）——正式分发前需要过一遍法务。

---

## English

macOS still ships without a GUI DHCP server, which I got tired of, so I built one on top of dnsmasq.

You walk into a datacenter with a MacBook and a USB-to-Ethernet adapter, and you want to hand a
temporary address to a BMC or a switch management port. On macOS that means a terminal,
`ifconfig`, a hand-written `dnsmasq.conf`, a pile of `sudo`, and remembering to clean it all up
afterwards. This app makes that a UI: pick an interface, pick a profile, press Start.

### What it does

- Adds a **temporary** IPv4 address to a chosen wired interface, and removes it on stop
- Single-subnet DHCPv4 with a configurable pool, lease duration, and router / DNS options
- DNS forwarding (system, custom, or local-records-only), local A records, and a local domain
  such as `lab.test`
- Live leases and live logs, filtered by DHCP / DNS / warning / error, exportable as text
- Reusable profiles

### What it deliberately does not do

It never touches `/etc/hosts` or `/etc/dnsmasq.conf`, and never makes a permanent change to any
macOS network service. No telemetry, no log upload, no network calls at runtime. Nothing starts
automatically. Wi-Fi and whichever interface currently carries your internet connection are
**barred** from DHCP — enforced in the privileged helper, not merely greyed out in the UI.

### Building

Needs macOS 14+ and Xcode 26+.

```bash
make bootstrap        # install dev tooling, generate the Xcode project
make vendor-dnsmasq   # fetch and build dnsmasq 2.93 as Universal 2
make build
make test
```

`DEVELOPMENT_TEAM` in `Config/Identifiers.xcconfig` is my Team ID; **replace it with yours** or
codesign will refuse. Every identifier in the project lives in that one file.

`DnsmasqForMac.xcodeproj` is generated and not committed — `project.yml` is the source of truth.

### Status

It builds, and 278 automated tests pass. Some things I **could not verify**:

- No Developer ID certificate here, so signed distribution and notarization are untested
- Registering the privileged helper needs a human to approve it in System Settings, so the
  end-to-end XPC round trip has not been exercised
- Real DHCP/DNS traffic needs real hardware; `Docs/MANUAL_TEST_PLAN.md` has the manual steps

All of it is recorded in `Docs/RISKS.md` rather than presented as passing.

### About dnsmasq

The bundled dnsmasq is a **separate, unmodified executable**, driven through a configuration file
and process management. No dnsmasq source or object code is compiled or linked into any binary in
this project. dnsmasq is by Simon Kelley, licensed GPL v2 or v3.

This project's own licence is not yet decided (`LICENSE_PENDING`) and needs a legal review before
any real distribution.

---

## 日本語

macOS には GUI 付きの DHCP サーバーが存在しない。それが我慢ならなかったので、dnsmasq に自分で GUI を
付けました。

MacBook と USB-Ethernet アダプタだけ持ってデータセンターに入り、BMC やスイッチの管理ポートに一時的な
アドレスを配りたい。macOS だとターミナルを開いて `ifconfig` を叩き、`dnsmasq.conf` を手書きし、`sudo`
を並べ、終わったら後片付けを忘れないようにする——という手順になります。このアプリはそれを UI にしただけ
です。インターフェースを選び、プロファイルを選び、開始を押す。

### できること

- 指定した有線インターフェースに**一時的な** IPv4 アドレスを追加し、停止時に自動で削除
- 単一サブネットの DHCPv4。アドレスプール、リース時間、Router / DNS オプションを設定可能
- DNS フォワーディング（システム DNS／カスタム／ローカルレコードのみ）、ローカル A レコード、
  `lab.test` のようなローカルドメイン
- リースとログをリアルタイム表示。ログは DHCP / DNS / 警告 / エラーで絞り込み、テキスト書き出しも可能
- 設定はプロファイルとして保存・切り替え

### あえてやらないこと

`/etc/hosts` にも `/etc/dnsmasq.conf` にも触れません。macOS のネットワークサービスを恒久的に変更する
こともありません。テレメトリなし、ログのアップロードなし、実行時のネットワーク通信もなし。自動起動も
しません。Wi-Fi と、現在インターネット接続を担っているインターフェースでは DHCP を**禁止**しています。
これは UI 上でグレーアウトしているだけでなく、特権ヘルパー側で強制されます。

### ビルド

macOS 14 以降と Xcode 26 以降が必要です。

```bash
make bootstrap        # 開発ツールを導入し、Xcode プロジェクトを生成
make vendor-dnsmasq   # dnsmasq 2.93 を取得し Universal 2 でビルド
make build
make test
```

`Config/Identifiers.xcconfig` の `DEVELOPMENT_TEAM` は私の Team ID です。**自分のものに差し替えて
ください**。差し替えないと署名に失敗します。プロジェクト内の識別子はすべてこの 1 ファイルにあります。

`DnsmasqForMac.xcodeproj` は生成物でリポジトリには含めません。`project.yml` が唯一の正です。

### 現状

ビルドは通り、自動テスト 278 件が通過します。ただし**検証できていない**部分があります。

- Developer ID 証明書がないため、署名付き配布と公証は未検証
- 特権ヘルパーの登録はシステム設定での手動承認が必要で、XPC の往復は実機で試せていません
- 実際の DHCP/DNS 通信には実機が必要です。手順は `Docs/MANUAL_TEST_PLAN.md` にあります

これらは合格扱いにせず、`Docs/RISKS.md` に記録してあります。

### dnsmasq について

同梱の dnsmasq は**独立した未改変の実行ファイル**で、設定ファイルとプロセス管理を通じて利用しています。
dnsmasq のソースやオブジェクトコードが本プロジェクトのバイナリに組み込まれることはありません。dnsmasq
は Simon Kelley 氏による GPL v2 または v3 のソフトウェアです。

本プロジェクト自体のライセンスは未定です（`LICENSE_PENDING`）。実際に配布する前に法務確認が必要です。

---

## Screenshots

The UI is localized into English and Simplified Chinese; it follows your system language.

| | |
|---|---|
| ![Onboarding](Docs/screenshots/01-onboarding.png) | ![Leases](Docs/screenshots/03-leases.png) |
| Helper installation | Leases |
| ![Logs](Docs/screenshots/04-logs.png) | ![Profiles](Docs/screenshots/05-profiles.png) |
| Logs | Profiles |
| ![Settings](Docs/screenshots/06-settings.png) | ![Overview in Chinese](Docs/screenshots/02-overview-zh.png) |
| Settings | 简体中文界面 |

Regenerate them, in every shipped language, with:

```bash
make screenshots
```

## Documentation

| | |
|---|---|
| `Docs/ARCHITECTURE.md` | How the app, the privileged helper, and dnsmasq fit together |
| `Docs/SECURITY.md` | Trust boundaries, and what is deliberately not defended |
| `Docs/PRIVILEGED_HELPER.md` | Installing, approving, repairing, removing the helper |
| `Docs/DNSMASQ_BUILD.md` | How the bundled dnsmasq is fetched, verified, and built |
| `Docs/RISKS.md` | Everything known to be unsettled |
| `Docs/MANUAL_TEST_PLAN.md` | The tests that need real hardware |
