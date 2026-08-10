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

CI 的 `clash-check` job 会拉取真实的 `openvpn-openssl`/`openvpn-easy-rsa` 包，与本包做文件归属交集校验，持续保证封装不冲突。防火墙规则逻辑（与 ipsec-vpnd 的 section 隔离）有离线测试：`sh .github/tests/test-uci-defaults.sh`（fake uci 模拟，无需 OpenWrt 环境），CI 构建前自动执行。

## v3.2 行为变更

- **下载/重建证书按钮独立**：不再走 CBI 表单提交，点击后不会重启 VPN 服务；重建证书为破坏性操作，改用 POST + CSRF token。
- **防火墙规则同步**：保存配置时自动同步 `firewall.openvpn` 的 `dest_port`（取第一个启用实例的端口，不再硬编码 section 名）；规则不存在时自动创建基础放行规则。
- **卸载清理**：卸载时删除本包创建的 `firewall.openvpn_zone` zone（name `openvpn`）与 `firewall.openvpn` 规则，并恢复系统 `openvpn` 服务为启用状态（安装时会停用旧 openvpn 服务以防端口冲突）。
- **WAN DDNS/IP 必填校验**：保存时校验域名/IP 格式，避免生成错误的客户端配置。
- **证书文件权限**：上传或重建的服务端/客户端私钥统一 `chmod 600`。
- **状态文件默认路径**：`/tmp/openvpn_status.log`（openvpn 以 nobody 运行，`/var/log` 可能不可写）。

## 编译

两种方式：

1. **GitHub Actions（推荐）**：push 即触发，`build` job 用 homeproxy 式直接打包（自编译 apk-tools/po2lmo + ipkg-build，不依赖 SDK/feeds），数分钟内分别产出主包与中文翻译包的 `.apk`/`.ipk`，见 Actions 产物。
2. **本地 buildroot**：源码为 LuCI 单仓库结构，`Makefile` 中 `include ../../luci.mk` 依赖上层 luci 构建树。需将本目录放回 luci 源码树的 `applications/luci-app-openvpn-server/`，或作为自定义 feed 接入构建系统。
