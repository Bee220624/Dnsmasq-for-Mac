<div align="center">

# Dnsmasq for Mac

**dnsmasq に GUI を付けた macOS アプリ。ターミナルなしで検証用ネットワークに DHCP と DNS を配れます。**

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey?style=flat-square)
![swift](https://img.shields.io/badge/Swift-6-orange?style=flat-square&logo=swift&logoColor=white)
![dnsmasq](https://img.shields.io/badge/dnsmasq-2.93-blue?style=flat-square)
![tests](https://img.shields.io/badge/tests-278%20passing-brightgreen?style=flat-square)
![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)
![status](https://img.shields.io/badge/status-source%20only-yellow?style=flat-square)

[English](README.md) · [简体中文](README.zh-CN.md) · **日本語**

<img src="Docs/screenshots/02-overview.png" width="840" alt="概要">

</div>

---

## なぜ作ったか

これは元々 Apple 自身がやっていたことです。DHCP サービスは長らく macOS Server に入っていましたが、
先にサービスが外され、2022 年には Server アプリ自体も終了しました。後を継ぐものはありません。

結果としてこうなります。MacBook と USB-Ethernet アダプタだけ持ってデータセンターに入り、BMC や
スイッチの管理ポートに一時的なアドレスを配りたい。macOS だとターミナルを開いて `ifconfig` を叩き、
`dnsmasq.conf` を手書きし、`sudo` を並べ、終わったら後片付けを忘れないようにする——という手順です。

このアプリはそれを 1 つのウィンドウにしました。インターフェースを選び、プロファイルを選び、開始を押す。

## できること

- 指定した有線インターフェースに**一時的な** IPv4 アドレスを追加し、停止時に自動で削除
- 単一サブネットの DHCPv4。アドレスプール、リース時間、Router / DNS オプションを設定可能
- DNS フォワーディング（システム DNS／カスタム／ローカルレコードのみ）、ローカル A レコード、
  `lab.test` のようなローカルドメイン
- リースとログをリアルタイム表示。ログは DHCP / DNS / 警告 / エラーで絞り込み、テキスト書き出しも可能
- 設定はプロファイルとして保存・切り替え

## あえてやらないこと

`/etc/hosts` にも `/etc/dnsmasq.conf` にも触れません。macOS のネットワークサービスを恒久的に変更する
こともありません。テレメトリなし、ログのアップロードなし、実行時のネットワーク通信もなし。自動起動も
しません。

Wi-Fi と、現在インターネット接続を担っているインターフェースでは DHCP を**禁止**しています。これは UI
でグレーアウトしているだけでなく、特権ヘルパー側で強制されます。

## スクリーンショット

<table>
<tr>
<td width="50%"><img src="Docs/screenshots/01-onboarding.png" alt="ヘルパーのインストール"></td>
<td width="50%"><img src="Docs/screenshots/03-leases.png" alt="リース"></td>
</tr>
<tr>
<td align="center"><b>特権ヘルパーのインストール</b></td>
<td align="center"><b>リース</b></td>
</tr>
<tr>
<td width="50%"><img src="Docs/screenshots/04-logs.png" alt="ログ"></td>
<td width="50%"><img src="Docs/screenshots/05-profiles.png" alt="プロファイル"></td>
</tr>
<tr>
<td align="center"><b>ログ</b></td>
<td align="center"><b>プロファイル</b></td>
</tr>
<tr>
<td width="50%"><img src="Docs/screenshots/06-settings.png" alt="設定"></td>
<td width="50%"><img src="Docs/screenshots/02-overview-zh.png" alt="簡体字中国語の画面"></td>
</tr>
<tr>
<td align="center"><b>設定</b></td>
<td align="center"><b>簡体字中国語の画面</b></td>
</tr>
</table>

UI は英語と簡体字中国語にローカライズされており、システム言語に追従します。すべてのスクリーンショットは
`make screenshots` で各言語ぶんまとめて再生成できます。

## ビルド

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

## 現状

ビルドは通り、自動テスト 278 件が通過します。ただし**検証できていない**部分があります。

- Developer ID 証明書がないため、署名付き配布と公証は未検証です。ダウンロード可能なバイナリがまだなく、
  ソースのみを公開しているのはこのためです
- 特権ヘルパーの登録はシステム設定での手動承認が必要で、XPC の往復は実機で試せていません
- 実際の DHCP/DNS 通信には実機が必要です。手順は [`Docs/MANUAL_TEST_PLAN.md`](Docs/MANUAL_TEST_PLAN.md) にあります

これらは合格扱いにせず、[`Docs/RISKS.md`](Docs/RISKS.md) に記録してあります。

## dnsmasq について

同梱の dnsmasq は**独立した未改変の実行ファイル**で、設定ファイルとプロセス管理を通じて利用しています。
dnsmasq のソースやオブジェクトコードが本プロジェクトのバイナリに組み込まれることはありません。dnsmasq
は Simon Kelley 氏による GPL v2 または v3 のソフトウェアで、両方のライセンス全文がアプリバンドル内に
同梱され、リリースには対応するソースが必ず付属します。

Dnsmasq for Mac 自体は [MIT ライセンス](LICENSE) です。両者が衝突しないのは、dnsmasq が一度もリンク
されていないからです。MIT はこのリポジトリのコードを、GPL はそれが起動するプログラムを対象とします。

## ドキュメント

| | |
|---|---|
| [`Docs/ARCHITECTURE.md`](Docs/ARCHITECTURE.md) | アプリ・特権ヘルパー・dnsmasq の組み合わさり方 |
| [`Docs/SECURITY.md`](Docs/SECURITY.md) | 信頼境界と、あえて防御しないもの |
| [`Docs/PRIVILEGED_HELPER.md`](Docs/PRIVILEGED_HELPER.md) | ヘルパーの導入・承認・修復・削除 |
| [`Docs/DNSMASQ_BUILD.md`](Docs/DNSMASQ_BUILD.md) | 同梱 dnsmasq の取得・検証・ビルド手順 |
| [`Docs/RISKS.md`](Docs/RISKS.md) | 未解決とわかっているものすべて |
| [`Docs/MANUAL_TEST_PLAN.md`](Docs/MANUAL_TEST_PLAN.md) | 実機が必要なテスト |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | パッチが満たすべきルールと、その理由 |
