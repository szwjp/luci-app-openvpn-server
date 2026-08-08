# Copyright (C) 2016 Openwrt.org
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for OpenVPN Server
LUCI_DEPENDS:=+luci-compat +openvpn-openssl +openvpn-easy-rsa +kmod-tun

PKG_NAME:=luci-app-openvpn-server
PKG_VERSION:=27.188.01099
PKG_RELEASE:=r99
PKG_LICENSE:=Apache-2.0

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
