#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# 直接打包脚本（参考 homeproxy 的 build-ipk.sh），绕过 buildroot/SDK，
# 用 apk-tools / ipkg-build / po2lmo 直接把源码打成 apk 与 ipk。
# 适配本项目的旧版 luasrc 布局（controller/model/view）。

set -o errexit
set -o pipefail

PKG_MGR="${1:-apk}"
RELEASE_TYPE="${2:-snapshot}"

export PKG_SOURCE_DATE_EPOCH="$(date "+%s")"
export SOURCE_DATE_EPOCH="$PKG_SOURCE_DATE_EPOCH"

BASE_DIR="$(cd "$(dirname $0)"; pwd)"
PKG_DIR="$BASE_DIR/.."

function get_mk_value() {
	awk -F "$1:=" '{print $2}' "$PKG_DIR/Makefile" | xargs
}

PKG_NAME="$(get_mk_value "PKG_NAME")"
BUILD_NUMBER="${3:-0}"
if [ "$RELEASE_TYPE" == "release" ]; then
	PKG_VERSION="$(get_mk_value "PKG_VERSION")"
else
	# 快照版本：<主版本>.<run_number>~<commit>，run_number 每次构建自动 +1
	# apk 版本号规则要求数字开头，不能带 v 前缀
	PKG_MAJOR="$(get_mk_value "PKG_VERSION" | cut -d. -f1)"
	PKG_VERSION="${PKG_MAJOR}.${BUILD_NUMBER}~$(git rev-parse --short HEAD)"
fi

I18N_NAME="luci-i18n-openvpn-server-zh-cn"
PKG_MAINTAINER="szwjp <szwjp@users.noreply.github.com>"
PKG_URL="https://github.com/szwjp/luci-app-openvpn-server"
PKG_DESC="LuCI support for OpenVPN Server"
# apk 用空格分隔，ipk 用逗号分隔
APK_DEPENDS="luci-compat openvpn-openssl openvpn-easy-rsa kmod-tun"
IPK_DEPENDS="luci-compat, openvpn-openssl, openvpn-easy-rsa, kmod-tun"

TEMP_DIR="$(mktemp -d -p "$BASE_DIR")"
TEMP_PKG_DIR="$TEMP_DIR/$PKG_NAME"
mkdir -p "$TEMP_PKG_DIR/lib/upgrade/keep.d/"
mkdir -p "$TEMP_PKG_DIR/usr/lib/lua/luci/controller/"
mkdir -p "$TEMP_PKG_DIR/usr/lib/lua/luci/model/cbi/openvpn-server/"
mkdir -p "$TEMP_PKG_DIR/usr/lib/lua/luci/view/openvpn/"
mkdir -p "$TEMP_PKG_DIR/usr/lib/lua/luci/i18n/"
if [ "$PKG_MGR" == "apk" ]; then
	mkdir -p "$TEMP_PKG_DIR/lib/apk/packages/"
else
	mkdir -p "$TEMP_PKG_DIR/CONTROL/"
fi

# luasrc 布局映射到目标路径
cp -fp "$PKG_DIR/luasrc/controller/openvpn-server.lua" "$TEMP_PKG_DIR/usr/lib/lua/luci/controller/"
cp -fpR "$PKG_DIR/luasrc/model/cbi/openvpn-server/." "$TEMP_PKG_DIR/usr/lib/lua/luci/model/cbi/openvpn-server/"
cp -fpR "$PKG_DIR/luasrc/view/openvpn/." "$TEMP_PKG_DIR/usr/lib/lua/luci/view/openvpn/"
# root 下所有文件（config/init.d/uci-defaults/openvpn 脚本/rpcd acl 等）
cp -fpR "$PKG_DIR/root/." "$TEMP_PKG_DIR/"

# 升级时保留证书与用户可编辑配置
cat > "$TEMP_PKG_DIR/lib/upgrade/keep.d/$PKG_NAME" <<-EOF
/etc/openvpn/pki/
/etc/openvpn-addon.conf
/etc/config/openvpn-server
EOF

# 编译翻译，lmo 先移出，由 i18n 子包安装
po2lmo "$PKG_DIR/po/zh_Hans/openvpn-server.po" "$TEMP_PKG_DIR/usr/lib/lua/luci/i18n/openvpn-server.zh-cn.lmo"
mv "$TEMP_PKG_DIR/usr/lib/lua/luci/i18n/openvpn-server.zh-cn.lmo" "$TEMP_DIR/openvpn-server.zh-cn.lmo"

if [ "$PKG_MGR" == "apk" ]; then
	find "$TEMP_PKG_DIR" -type f,l -printf '/%P\n' | sort > "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.list"
	printf '/etc/config/openvpn-server\n/etc/openvpn-addon.conf\n' > "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.conffiles"
	cat "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.conffiles" | while IFS= read -r file; do
		[ -f "$TEMP_PKG_DIR/$file" ] || continue
		sha256sum "$TEMP_PKG_DIR/$file" | sed "s,$TEMP_PKG_DIR/,," >> "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.conffiles_static"
	done

	echo -e '#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="'"$PKG_NAME"'"
default_postinst
[ -n "${IPKG_INSTROOT}" ] || {
	[ -f /etc/uci-defaults/openvpn-server ] && { ( . /etc/uci-defaults/openvpn-server ) && rm -f /etc/uci-defaults/openvpn-server; }
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
	exit 0
}' > "$TEMP_DIR/post-install"

	echo -e '#!/bin/sh
export PKG_UPGRADE=1
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="'"$PKG_NAME"'"
default_postinst
[ -n "${IPKG_INSTROOT}" ] || {
	[ -f /etc/uci-defaults/openvpn-server ] && { ( . /etc/uci-defaults/openvpn-server ) && rm -f /etc/uci-defaults/openvpn-server; }
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
	exit 0
}' > "$TEMP_DIR/post-upgrade"

	echo -e '#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="'"$PKG_NAME"'"
default_prerm
[ -n "${IPKG_INSTROOT}" ] || {
	# 卸载清理：删除本包创建的防火墙规则/zone，恢复系统 openvpn 服务
	uci -q batch <<-EOF
		delete firewall.openvpn
		delete firewall.vpn
		delete firewall.vpntowan
		delete firewall.vpntolan
		delete firewall.lantovpn
		commit firewall
	EOF
	/etc/init.d/firewall restart 2>/dev/null
	[ -x /etc/init.d/openvpn ] && /etc/init.d/openvpn enable 2>/dev/null
	exit 0
}' > "$TEMP_DIR/pre-deinstall"

	apk mkpkg \
		--info "name:$PKG_NAME" \
		--info "version:$PKG_VERSION" \
		--info "description:$PKG_DESC" \
		--info "arch:noarch" \
		--info "origin:$PKG_URL" \
		--info "url:$PKG_URL" \
		--info "maintainer:$PKG_MAINTAINER" \
		--info "provides:" \
		--script "post-install:$TEMP_DIR/post-install" \
		--script "post-upgrade:$TEMP_DIR/post-upgrade" \
		--script "pre-deinstall:$TEMP_DIR/pre-deinstall" \
		--info "depends:$APK_DEPENDS" \
		--files "$TEMP_PKG_DIR" \
		--output "$TEMP_DIR/${PKG_NAME}-${PKG_VERSION}.apk"

	mv "$TEMP_DIR/${PKG_NAME}-${PKG_VERSION}.apk" "$BASE_DIR/${PKG_NAME}-${PKG_VERSION}-all.apk"
else
	cat > "$TEMP_PKG_DIR/CONTROL/control" <<-EOF
		Package: $PKG_NAME
		Version: $PKG_VERSION
		Depends: $IPK_DEPENDS
		Source: $PKG_URL
		SourceName: $PKG_NAME
		Section: luci
		SourceDateEpoch: $PKG_SOURCE_DATE_EPOCH
		Maintainer: $PKG_MAINTAINER
		Architecture: all
		Installed-Size: TO-BE-FILLED-BY-IPKG-BUILD
		Description:  $PKG_DESC
	EOF
	chmod 0644 "$TEMP_PKG_DIR/CONTROL/control"

	printf '/etc/config/openvpn-server\n/etc/openvpn-addon.conf\n' > "$TEMP_PKG_DIR/CONTROL/conffiles"

	echo -e '#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@' > "$TEMP_PKG_DIR/CONTROL/postinst"
	chmod 0755 "$TEMP_PKG_DIR/CONTROL/postinst"

	echo -e '#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@
[ -n "${IPKG_INSTROOT}" ] || {
	# 卸载清理：删除本包创建的防火墙规则/zone，恢复系统 openvpn 服务
	uci -q batch <<-EOF
		delete firewall.openvpn
		delete firewall.vpn
		delete firewall.vpntowan
		delete firewall.vpntolan
		delete firewall.lantovpn
		commit firewall
	EOF
	/etc/init.d/firewall restart 2>/dev/null
	[ -x /etc/init.d/openvpn ] && /etc/init.d/openvpn enable 2>/dev/null
	exit 0
}' > "$TEMP_PKG_DIR/CONTROL/prerm"
	chmod 0755 "$TEMP_PKG_DIR/CONTROL/prerm"

	ipkg-build -m "" "$TEMP_PKG_DIR" "$TEMP_DIR"

	mv "$TEMP_DIR/${PKG_NAME}_${PKG_VERSION}_all.ipk" "$BASE_DIR/${PKG_NAME}-${PKG_VERSION}-all.ipk"
fi

# 中文翻译子包
I18N_DIR="$TEMP_DIR/$I18N_NAME"
mkdir -p "$I18N_DIR/usr/lib/lua/luci/i18n/"
cp "$TEMP_DIR/openvpn-server.zh-cn.lmo" "$I18N_DIR/usr/lib/lua/luci/i18n/"

if [ "$PKG_MGR" == "apk" ]; then
	find "$I18N_DIR" -type f,l -printf '/%P\n' | sort > "$TEMP_DIR/i18n.list"
	apk mkpkg \
		--info "name:$I18N_NAME" \
		--info "version:$PKG_VERSION" \
		--info "description:OpenVPN Server Chinese translation" \
		--info "arch:noarch" \
		--info "depends:$PKG_NAME" \
		--files "$I18N_DIR" \
		--output "$TEMP_DIR/${I18N_NAME}-${PKG_VERSION}.apk"
	mv "$TEMP_DIR/${I18N_NAME}-${PKG_VERSION}.apk" "$BASE_DIR/${I18N_NAME}-${PKG_VERSION}-all.apk"
else
	mkdir -p "$I18N_DIR/CONTROL/"
	cat > "$I18N_DIR/CONTROL/control" <<-EOFCTRL
		Package: $I18N_NAME
		Version: $PKG_VERSION
		Depends: $PKG_NAME
		Architecture: all
		Description: OpenVPN Server Chinese translation
	EOFCTRL
	ipkg-build -m "" "$I18N_DIR" "$TEMP_DIR"
	mv "$TEMP_DIR/${I18N_NAME}_${PKG_VERSION}_all.ipk" "$BASE_DIR/${I18N_NAME}-${PKG_VERSION}-all.ipk"
fi

rm -rf "$TEMP_DIR"
