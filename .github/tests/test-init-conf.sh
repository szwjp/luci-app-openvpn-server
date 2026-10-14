#!/bin/sh
# openvpn-server init 脚本运行时配置生成逻辑离线测试。
# 重点：无论 UCI 里残留什么，压缩项都不得写入 /var/etc 下的运行时配置。
# 服务端只要带上压缩项（lzo 或 stub 帧），就与现代客户端帧格式不匹配，
# 表现为客户端"证书能登录、但局域网和外网全不通"，且日志无任何报错。
# 无需 OpenWrt 环境：stub 掉 rc.common/procd 提供的函数。
# 运行：sh .github/tests/test-init-conf.sh
set -u

cd "$(dirname "$0")/../.."
INIT=root/etc/init.d/openvpn-server
TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT

FAILED=0

assert_present() { # $1=描述 $2=文件 $3=模式
	if grep -q "$3" "$2"; then
		echo "  PASS: $1"
	else
		echo "  FAIL: $1（缺少 '$3'）"
		FAILED=1
	fi
}

assert_absent() { # $1=描述 $2=文件 $3=模式
	if grep -q "$3" "$2"; then
		echo "  FAIL: $1（不应出现 '$3'）"
		FAILED=1
	else
		echo "  PASS: $1"
	fi
}

# --- stub：故意模拟"压缩项残留"的旧配置（comp_lzo=yes + push comp-lzo/compress）---
config_get_bool() { eval "$1=1"; }
config_get() {
	case "$3" in
	proto) eval "$1=tcp-server" ;;
	port) eval "$1=1194" ;;
	dev) eval "$1=tun" ;;
	topology) eval "$1=subnet" ;;
	server) eval "$1='10.8.0.0 255.255.255.0'" ;;
	comp_lzo) eval "$1=yes" ;;
	ca) eval "$1=/etc/openvpn/pki/ca.crt" ;;
	dh) eval "$1=/etc/openvpn/pki/dh.pem" ;;
	cert) eval "$1=/etc/openvpn/pki/server.crt" ;;
	key) eval "$1=/etc/openvpn/pki/server.key" ;;
	persist_key|persist_tun|duplicate_cn) eval "$1=1" ;;
	client_to_client) eval "$1=0" ;;
	user) eval "$1=nobody" ;;
	group) eval "$1=nogroup" ;;
	max_clients) eval "$1=10" ;;
	keepalive) eval "$1='10 120'" ;;
	verb) eval "$1=3" ;;
	status) eval "$1=/var/log/openvpn_status.log" ;;
	log) eval "$1=/tmp/openvpn.log" ;;
	redirect_gateway) eval "$1=def1" ;;
	esac
}
config_list_foreach() { # $1=section $2=option $3=回调
	for _item in \
		"route 192.168.1.0 255.255.255.0" \
		"comp-lzo adaptive" \
		"comp-lzo yes" \
		"compress migrate" \
		"redirect-gateway def1 bypass-dhcp"; do
		"$3" "$_item"
	done
}
procd_open_instance() { :; }
procd_set_param() { :; }
procd_close_instance() { :; }

# shellcheck disable=SC1090
. "$INIT"

CONF_DIR="$TESTDIR/var/etc"
server_instance myvpn
CONF="$CONF_DIR/openvpn-server-myvpn.conf"

echo "== init 生成的运行时配置 =="
sed 's/^/  /' "$CONF"

echo "== 断言 =="
assert_absent "残留 UCI comp_lzo 不输出" "$CONF" "comp-lzo"
assert_absent "残留 push 压缩项不输出" "$CONF" "compress"
assert_present "普通 push 保留（route）" "$CONF" 'push "route 192.168.1.0 255.255.255.0"'
assert_present "普通 push 保留（redirect-gateway）" "$CONF" 'push "redirect-gateway def1 bypass-dhcp"'
assert_present "基础参数正常输出" "$CONF" "proto tcp-server"
assert_present "证书参数正常输出" "$CONF" "dh /etc/openvpn/pki/dh.pem"

if [ "$FAILED" = "1" ]; then
	echo "结果：存在失败项"
	exit 1
fi
echo "结果：全部通过"
