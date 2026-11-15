# Copyright (C) 2016 Openwrt.org
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for OpenVPN Server
LUCI_DEPENDS:=+luci-compat +openvpn-openssl +openvpn-easy-rsa +kmod-tun
# 虚拟包名：翻译包 luci-i18n-openvpn-server-zh-cn 只依赖这个名字，
# 从而不会在只装翻译包时被 apk 解析成官方仓库里的同名上游包
# （上游包与 openvpn-openssl 有 /etc/config/openvpn 文件归属冲突，装不上）。
# luci.mk 会把 PKG_PROVIDES 映射到包的 PROVIDES。
PKG_PROVIDES:=openvpn-server-luci

PKG_NAME:=luci-app-openvpn-server
# 版本号：<主>.<次>.<修订>-r<打包修订>
# 每次改动包内容都必须递增 PKG_RELEASE，否则设备上不会升级。
# 注意：apk 的版本比较是逐段数值比较，改动前请确认新版本严格大于线上版本。
PKG_VERSION:=27.188.01099
PKG_RELEASE:=102
PKG_LICENSE:=Apache-2.0

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
