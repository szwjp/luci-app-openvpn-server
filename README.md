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

## 编译

两种方式：

1. **GitHub Actions（推荐）**：push 即触发，`build` job 用 homeproxy 式直接打包（自编译 apk-tools/po2lmo + ipkg-build，不依赖 SDK/feeds），数分钟内分别产出主包与中文翻译包的 `.apk`/`.ipk`，见 Actions 产物。
2. **本地 buildroot**：源码为 LuCI 单仓库结构，`Makefile` 中 `include ../../luci.mk` 依赖上层 luci 构建树。需将本目录放回 luci 源码树的 `applications/luci-app-openvpn-server/`，或作为自定义 feed 接入构建系统。
