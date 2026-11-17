# luci-app-openvpn-server

LuCI OpenVPN 服务端管理界面。本仓库从 ImmortalWrt luci 单仓库抽出，独立维护。

上游长期无人维护（immortalwrt/luci#533 至今未解决），但本项目仍需使用，故自行维护修复。

## 上游来源

- 仓库: https://github.com/immortalwrt/luci
- 分支: `master`
- 原始路径: `applications/luci-app-openvpn-server/`
- 抽取日期: 2026-07-30

## 与 openvpn-openssl 的文件冲突（已修复）

上游本包与硬依赖 `openvpn-openssl` 存在文件冲突，导致无法安装/封装镜像（opkg/apk 均报错）：

```
ERROR: luci-app-openvpn-server-3.0-r0: trying to overwrite
       etc/config/openvpn owned by openvpn-openssl
```

根因：本包 `root/etc/config/openvpn` 与 `openvpn-openssl` 提供的 `/etc/config/openvpn` 同路径，文件归属冲突。

本仓库的修复方案（与上游 issue 讨论方向一致）：将本包配置整体改名为 `openvpn-server`，并同步所有引用：

- `root/etc/config/openvpn` → `root/etc/config/openvpn-server`
- `root/etc/uci-defaults/openvpn` → `root/etc/uci-defaults/openvpn-server`
- 新增自包含 init 脚本 `root/etc/init.d/openvpn-server`（不依赖 openvpn 包 helper，跨版本更稳）
- `luasrc/controller/openvpn-server.lua`、`luasrc/model/cbi/openvpn-server/openvpn-server.lua`
- `root/etc/openvpn/genovpn.sh`、`renewcert.sh`、`root/usr/share/rpcd/acl.d/luci-app-openvpn-server.json`

CI 的 `clash-check` job 会拉取真实的 `openvpn-openssl`/`openvpn-easy-rsa` 包，与本包做文件归属交集校验，持续保证封装不冲突。

防火墙规则逻辑（与 ipsec-vpnd 的 section 隔离）有离线测试，无需 OpenWrt 环境，CI 构建前自动执行：

```sh
sh .github/tests/test-uci-defaults.sh   # uci-defaults 防火墙规则（fake uci 模拟）
sh .github/tests/test-init-conf.sh       # init 生成的运行时配置（压缩项/tls-crypt/MTU）
sh .github/tests/test-genovpn.sh         # 客户端 .ovpn（tls-crypt/MTU/缺密钥失败）
sh .github/tests/test-luci-api.sh        # LuCI 侧静态守卫（cursor API / CSRF / ACL）
```

## v3.2 行为变更

- **下载/重建证书按钮独立**：不再走 CBI 表单提交，点击后不会重启 VPN 服务；重建证书为破坏性操作，改用 POST + CSRF token。
- **防火墙规则同步**：保存并应用时自动同步 `firewall.openvpn` 的 `dest_port`（取第一个启用实例的端口，不再硬编码 section 名）；规则不存在时自动创建基础放行规则。
- **卸载清理**：卸载时删除本包创建的 `firewall.openvpn_zone` zone（name `openvpn`）与 `firewall.openvpn` 规则，并恢复系统 `openvpn` 服务为启用状态（安装时会停用旧 openvpn 服务以防端口冲突）。
- **WAN DDNS/IP 必填校验**：保存时校验域名/IP 格式，避免生成错误的客户端配置。
- **证书文件权限**：上传或重建的服务端/客户端私钥统一 `chmod 600`。
- **状态文件默认路径**：`/tmp/openvpn_status.log`（openvpn 以 nobody 运行，`/var/log` 可能不可写）。

## v3.3 行为变更（安全与正确性修复）

- **重建证书的 CSRF 防护落到服务端**：controller 用 `post()` 注册 `renew` 动作，dispatcher 会强制 `POST` + token 校验；此前只在模板里带 token、服务端不校验，跨站 GET 即可触发重建 PKI（重建会作废所有已分发的客户端证书）。
- **敏感入口补齐 ACL**：`status` / `download` / `renew` 三个入口都挂 `luci-app-openvpn-server` ACL 组；此前只有主页面有 ACL，任何已登录用户都能直接访问 URL 下载含客户端私钥的 `.ovpn`。
- **移除 `redirect-gateway` 选项**：服务端模式下 openvpn 禁止顶层 `--redirect-gateway`（`options.c: --redirect-gateway cannot be used with --mode server`），选了会让 openvpn 直接 usage error 退出、VPN 起不来。默认路由改由 push 列表里的 `push "redirect-gateway ..."` 下发。
- **防火墙自愈改用 `set_list`**：`luci.model.uci` 的 cursor 没有 `add_list` 方法，调用不存在的 API 会抛 Lua 异常导致整次保存失败。
- **zone 设备名随 `dev` 变化**：`dev=tun` → `tun0`，`dev=tap` → `tap0`，不再写死 `tun0`。
- **客户端地址池持久化**：下发 `ifconfig-pool-persist`，客户端重连不再换地址。
- **`.ovpn` 临时文件收紧权限**：生成时 `umask 077`，下载后立即删除（内含客户端私钥）。
- **进程状态检测改看运行时配置路径**（`/var/etc/openvpn-server-*.conf`），不再依赖 `--syslog` 字符串。
- **构建可复现**：`SOURCE_DATE_EPOCH` 固定；`ipkg-build` 固定到具体 commit；CI 增加产物名与 `Makefile` 版本的一致性断言。
- **发布方式改为按版本建 release**（tag `v<PKG_VERSION>-r<PKG_RELEASE>`），不再每次推送删除并重建同名 release，历史版本可追溯。
- **中文翻译包自动生效**：翻译包补上 `/etc/uci-defaults` 声明 `luci.languages.zh_cn`（与官方 `luci.mk` 行为一致），否则装了翻译也不会被选中；翻译包补齐 `lib/apk/packages/<pkg>.list` 与 post-install，否则 `default_postinst` 找不到它的 uci-defaults，语言声明永远不执行。
- **翻译包依赖虚拟包名 `openvpn-server-luci`**（由主包 provides），避免 apk 把翻译包解析成官方仓库里的同名上游包（上游包与 `openvpn-openssl` 有文件归属冲突，装不上）。
- **apk / ipk 两条安装路径行为对齐**：ipk 的 postinst 同样清 LuCI 缓存并 reload rpcd。
- **`conffiles_static` 格式对齐官方**：`<路径> <sha256>`（此前写成了 `<sha256> <路径>`）。

## v3.4 行为变更（tls-crypt 与 MTU 加固）

- **tls-crypt**：新增 `tls_crypt` 选项，开启后服务端配置输出 `tls-crypt /etc/openvpn/pki/tc.key`，客户端 `.ovpn` 自动嵌入 `<tls-crypt>` 块，加密 TLS 控制通道、隐藏证书握手特征。
  - 密钥由 init 在缺失时自动生成（`openvpn --genkey secret`，0600）；执行「重建全部证书」时会同时轮换该密钥。
  - **新装默认开启**；从旧版本升级时，配置里没有 `tls_crypt` 选项则保持关闭，避免旧客户端突然断连。开启后所有客户端必须重新下载 `.ovpn`。
- **tun-mtu / mssfix**：新增 `tun_mtu`（默认 1400）和 `mssfix`（默认 1360）选项；服务端运行时配置与客户端 `.ovpn` 都会写入相同的值，避免 PPPoE（1492）下隧道大包被丢弃。
  - 同样是**新装默认生效、旧配置保持原样**；调整后客户端也要重新下载 `.ovpn`，两端 MTU 必须一致。
- 以上两项都涉及客户端配置变更，升级/开启前请重新导出 `.ovpn`。

## 安装

从 Release 下载对应版本的资产（每个版本一个 release，tag 为 `v<版本>-r<修订>`）：

```sh
cd /tmp
wget -O luci-app-openvpn-server.apk \
  https://github.com/szwjp/luci-app-openvpn-server/releases/download/v<版本>-r<修订>/luci-app-openvpn-server-<版本>-r<修订>.apk
apk add --allow-untrusted luci-app-openvpn-server.apk
```

中文界面另装翻译包 `luci-i18n-openvpn-server-zh-cn-<版本>-r<修订>.apk`：

```sh
apk add --allow-untrusted luci-i18n-openvpn-server-zh-cn-<版本>-r<修订>.apk
```

> **必须先装主包再装翻译包。** 翻译包依赖的是本包提供的虚拟包名 `openvpn-server-luci`，
> 而不是包名本身——否则 apk 会从官方仓库解析出同名的上游包
> `luci-app-openvpn-server-3.0-r0`，而上游包与 `openvpn-openssl` 有
> `/etc/config/openvpn` 文件归属冲突，安装必然失败。

> 安装命令执行成功 ≠ 验收通过。正确验收：先卸载并证明零残留 → 只跑上面的原始安装命令全新安装 → 装完不做任何手工补救（不手动 reload、不手动 start）→ 立刻可用才算过 → 卸载同样零残留。
> 仓库内附了验收脚本：

```sh
bash .github/tests/verify-on-device.sh root@192.168.1.1 .github/luci-app-openvpn-server-<版本>-r<修订>.apk
```

## 编译

两种方式：

1. **GitHub Actions（推荐）**：push 即触发，`build` job 用 homeproxy 式直接打包（自编译 apk-tools/po2lmo + ipkg-build，不依赖 SDK/feeds），数分钟内分别产出主包与中文翻译包的 `.apk`/`.ipk`，见 Actions 产物。`clash-check` job 随后校验与硬依赖包的文件归属交集。
2. **本地 buildroot**：源码为 LuCI 单仓库结构，`Makefile` 中 `include ../../luci.mk` 依赖上层 luci 构建树。需将本目录放回 luci 源码树的 `applications/luci-app-openvpn-server/`，或作为自定义 feed 接入构建系统。

## 版本规则

- 版本号取 `Makefile` 的 `PKG_VERSION` / `PKG_RELEASE`，产物名与 release tag 都由它推导，CI 有一致性断言。
- **每次改动包内容都必须递增 `PKG_RELEASE`**，否则设备上不会升级。
- apk 版本号要求数字开头；apk 的版本比较是逐段数值比较，改版本前请确认新版本严格大于线上版本，避免被判定为降级而无法升级。
