#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# 直接打包脚本（参考 homeproxy 的 build-ipk.sh），绕过 buildroot/SDK，
# 用 apk-tools / ipkg-build / po2lmo 直接把源码打成 apk 与 ipk。
# 适配本项目的旧版 luasrc 布局（controller/model/view）。

set -o errexit
set -o pipefail

PKG_MGR="${1:-apk}"
BUILD_NUMBER="${2:-0}"

# 固定时间戳：保证同一份源码构建出的包是可复现的（字节级一致）。
# 官方 OpenWrt 用 SOURCE_DATE_EPOCH=0，这里用同一个语义但取一个
# 不会触发老式 tar 边界问题的固定值（2023-11-14）。
export SOURCE_DATE_EPOCH=1700000000
export PKG_SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH"

BASE_DIR="$(cd "$(dirname $0)"; pwd)"
PKG_DIR="$BASE_DIR/.."

function get_mk_value() {
	awk -F "$1:=" '{print $2}' "$PKG_DIR/Makefile" | xargs
}

# sha256sum 在 macOS 上不存在（只有 shasum -a 256），这里做兼容
function sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

PKG_NAME="$(get_mk_value "PKG_NAME")"
# 版本号直接取 Makefile 的 PKG_VERSION/PKG_RELEASE（apk: <ver>-r<release>，ipk: <ver>-<release>），
# 未定义时回退到快照版本
PKG_VERSION="$(get_mk_value "PKG_VERSION")"
PKG_RELEASE="$(get_mk_value "PKG_RELEASE")"
if [ -n "$PKG_VERSION" ] && [ -n "$PKG_RELEASE" ]; then
	if [ "$PKG_MGR" == "apk" ]; then
		PKG_VERSION="$PKG_VERSION-r$PKG_RELEASE"
	else
		PKG_VERSION="$PKG_VERSION-$PKG_RELEASE"
	fi
else
	# 快照版本：<主版本>.<run_number>~<commit>，run_number 每次构建自动 +1
	# apk 版本号规则要求数字开头，不能带 v 前缀
	PKG_MAJOR="$(get_mk_value "PKG_VERSION" | cut -d. -f1)"
	PKG_VERSION="${PKG_MAJOR}.${BUILD_NUMBER}~$(git rev-parse --short HEAD)"
fi

I18N_NAME="luci-i18n-openvpn-server-zh-cn"
# 虚拟包名：翻译包依赖它，而不是依赖包名本身。
# 若翻译包直接依赖 "luci-app-openvpn-server"，只装翻译包时 apk 会从官方仓库
# 解析出同名的上游包（上游包与 openvpn-openssl 有 /etc/config/openvpn 归属冲突）。
VPROVIDE="openvpn-server-luci"
PKG_MAINTAINER="szwjp <szwjp@users.noreply.github.com>"
PKG_URL="https://github.com/szwjp/luci-app-openvpn-server"
PKG_DESC="LuCI support for OpenVPN Server"
# apk 用空格分隔，ipk 用逗号分隔
APK_DEPENDS="luci-compat openvpn-openssl openvpn-easy-rsa kmod-tun"
IPK_DEPENDS="luci-compat, openvpn-openssl, openvpn-easy-rsa, kmod-tun"

# 临时目录：mktemp -p 在 macOS 上不存在，用 TMPDIR 模板兼容 GNU/BSD
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openvpn-server-build.XXXXXX")"
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
	# .list 必须是包内的文件清单，且不能把自己算进去
	# （官方 package-pack.mk 是先 find 到临时文件再 mv 进包里）
	mkdir -p "$TEMP_PKG_DIR/lib/apk/packages"
	(cd "$TEMP_PKG_DIR" && find . \( -type f -o -type l \) | sed 's|^\./|/|' | LC_ALL=C sort) > "$TEMP_DIR/pkg.list"
	mv "$TEMP_DIR/pkg.list" "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.list"
	printf '/etc/config/openvpn-server\n/etc/openvpn-addon.conf\n' > "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.conffiles"
	# conffiles_static 的格式与官方 package-pack.mk 保持一致：<路径> <sha256>
	# （官方是 `echo $file $csum`，顺序不能反）
	while IFS= read -r file; do
		[ -f "$TEMP_PKG_DIR/$file" ] || continue
		echo "$file $(sha256_of "$TEMP_PKG_DIR/$file")" >> "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.conffiles_static"
	done < "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.conffiles"

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
	/etc/init.d/rpcd reload 2>/dev/null || killall -HUP rpcd 2>/dev/null
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
	/etc/init.d/rpcd reload 2>/dev/null || killall -HUP rpcd 2>/dev/null
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
		delete firewall.openvpn_zone
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
		--info "provides:$VPROVIDE" \
		--script "post-install:$TEMP_DIR/post-install" \
		--script "post-upgrade:$TEMP_DIR/post-upgrade" \
		--script "pre-deinstall:$TEMP_DIR/pre-deinstall" \
		--info "depends:$APK_DEPENDS" \
		--files "$TEMP_PKG_DIR" \
		--output "$TEMP_DIR/${PKG_NAME}-${PKG_VERSION}.apk"

	mv "$TEMP_DIR/${PKG_NAME}-${PKG_VERSION}.apk" "$BASE_DIR/${PKG_NAME}-${PKG_VERSION}.apk"
else
	cat > "$TEMP_PKG_DIR/CONTROL/control" <<-EOF
		Package: $PKG_NAME
		Version: $PKG_VERSION
		Depends: $IPK_DEPENDS
		Source: $PKG_URL
		SourceName: $PKG_NAME
		Provides: $VPROVIDE
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
export root="${IPKG_INSTROOT}"
export pkgname="'"$PKG_NAME"'"
default_postinst
[ -n "${IPKG_INSTROOT}" ] || {
	[ -f /etc/uci-defaults/openvpn-server ] && { ( . /etc/uci-defaults/openvpn-server ) && rm -f /etc/uci-defaults/openvpn-server; }
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null || killall -HUP rpcd 2>/dev/null
	exit 0
}' > "$TEMP_PKG_DIR/CONTROL/postinst"
	chmod 0755 "$TEMP_PKG_DIR/CONTROL/postinst"

	echo -e '#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 "$@"
[ -n "${IPKG_INSTROOT}" ] || {
	# 卸载清理：删除本包创建的防火墙规则/zone，恢复系统 openvpn 服务
	uci -q batch <<-EOF
		delete firewall.openvpn
		delete firewall.openvpn_zone
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

	mv "$TEMP_DIR/${PKG_NAME}_${PKG_VERSION}_all.ipk" "$BASE_DIR/${PKG_NAME}-${PKG_VERSION}.ipk"
fi

# 中文翻译子包
I18N_DIR="$TEMP_DIR/$I18N_NAME"
mkdir -p "$I18N_DIR/usr/lib/lua/luci/i18n/"
mkdir -p "$I18N_DIR/etc/uci-defaults/"
cp "$TEMP_DIR/openvpn-server.zh-cn.lmo" "$I18N_DIR/usr/lib/lua/luci/i18n/"
# 与官方 luci.mk 的 LuciTranslation 一致：声明 luci.languages.zh_cn，
# 否则 LuCI 的语言协商（dispatcher: uci.get('luci','languages','zh_cn')）
# 找不到中文语言，翻译装了也不生效。
cat > "$I18N_DIR/etc/uci-defaults/luci-i18n-openvpn-server-zh-cn" <<-'EOF'
	#!/bin/sh
	uci set luci.languages.zh_cn='简体中文 (Simplified Chinese)'
	uci commit luci
	exit 0
	EOF
chmod 0755 "$I18N_DIR/etc/uci-defaults/luci-i18n-openvpn-server-zh-cn"

if [ "$PKG_MGR" == "apk" ]; then
	# 翻译包同样必须有 .list，否则 default_postinst 找不到它的
	# /etc/uci-defaults/*，语言声明永远不会被执行
	mkdir -p "$I18N_DIR/lib/apk/packages"
	(cd "$I18N_DIR" && find . \( -type f -o -type l \) | sed 's|^\./|/|' | LC_ALL=C sort) > "$TEMP_DIR/i18n.list"
	mv "$TEMP_DIR/i18n.list" "$I18N_DIR/lib/apk/packages/$I18N_NAME.list"
	# 翻译包也需要 post-install（走 default_postinst），
	# 否则它的 /etc/uci-defaults/* 永远不会被执行，语言声明不生效。
	# 官方构建里每个包都有这个包装脚本，这里对齐。
	echo -e '#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="'"$I18N_NAME"'"
default_postinst
exit 0' > "$TEMP_DIR/i18n-post-install"
	apk mkpkg \
		--info "name:$I18N_NAME" \
		--info "version:$PKG_VERSION" \
		--info "description:OpenVPN Server Chinese translation" \
		--info "arch:noarch" \
		--info "depends:$VPROVIDE" \
		--script "post-install:$TEMP_DIR/i18n-post-install" \
		--files "$I18N_DIR" \
		--output "$TEMP_DIR/${I18N_NAME}-${PKG_VERSION}.apk"
	mv "$TEMP_DIR/${I18N_NAME}-${PKG_VERSION}.apk" "$BASE_DIR/${I18N_NAME}-${PKG_VERSION}.apk"
else
	mkdir -p "$I18N_DIR/CONTROL/"
	cat > "$I18N_DIR/CONTROL/control" <<-EOFCTRL
		Package: $I18N_NAME
		Version: $PKG_VERSION
		Depends: $VPROVIDE
		Architecture: all
		Description: OpenVPN Server Chinese translation
	EOFCTRL
	ipkg-build -m "" "$I18N_DIR" "$TEMP_DIR"
	mv "$TEMP_DIR/${I18N_NAME}_${PKG_VERSION}_all.ipk" "$BASE_DIR/${I18N_NAME}-${PKG_VERSION}.ipk"
fi

# 清理临时目录：部分系统上 rm 可能被替换为回收站 shim 而失败，失败不应影响构建结果
rm -rf "$TEMP_DIR" 2>/dev/null || true
