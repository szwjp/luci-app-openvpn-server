# luci-app-openvpn-server

LuCI OpenVPN 服务端管理界面。本仓库从 ImmortalWrt luci 单仓库抽出，独立维护。

上游长期无人维护（immortalwrt/luci#533 至今未解决），但本项目仍需使用，故自行维护修复。

## 上游来源

- 仓库: https://github.com/immortalwrt/luci
- 分支: `master`
- 原始路径: `applications/luci-app-openvpn-server/`
- 抽取日期: 2026-07-30

## 已知问题（待修复）

本包与硬依赖 `openvpn-openssl` 存在文件冲突，导致无法安装（opkg/apk 均报错）：

```
ERROR: luci-app-openvpn-server-3.0-r0: trying to overwrite
       etc/config/openvpn owned by openvpn-openssl
```

根因：

- `Makefile` 中 `LUCI_DEPENDS:=+luci-compat +openvpn-openssl +openvpn-easy-rsa +kmod-tun`，硬依赖 `openvpn-openssl`。
- 本包 `root/etc/config/openvpn` 与 `openvpn-openssl` 提供的 `/etc/config/openvpn` 同路径，文件归属冲突。

修复方向（参考上游 issue 讨论）：将本包 config 重命名为 `openvpn-server`，并同步以下引用：

- `root/etc/config/openvpn` → `root/etc/config/openvpn-server`
- `root/etc/uci-defaults/openvpn` 中 `uci get openvpn.myvpn.*`
- `luasrc/controller/openvpn-server.lua`、`luasrc/model/cbi/openvpn-server/openvpn-server.lua`
- `root/etc/openvpn/genovpn.sh`、`renewcert.sh`

## 编译

源码为 LuCI 单仓库结构，`Makefile` 中 `include ../../luci.mk` 依赖上层 luci 构建树。
编译时需将本目录放回 luci 源码树的 `applications/luci-app-openvpn-server/`，或作为自定义 feed 接入构建系统。
