#!/bin/sh
# openvpn-server uci-defaults 防火墙规则逻辑离线测试。
# 依赖同目录 fake-uci（文本状态文件模拟 uci），无需 OpenWrt 环境。
# 运行：sh .github/tests/test-uci-defaults.sh
set -u

cd "$(dirname "$0")/../.."
UD=root/etc/uci-defaults/openvpn-server
FAKE_DIR=$(cd "$(dirname "$0")" && pwd)
TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT

# 以 uci 命令名暴露 fake-uci（PATH 按文件名查找）
BIN="$TESTDIR/bin"
mkdir -p "$BIN"
ln -s "$FAKE_DIR/fake-uci" "$BIN/uci"

FAILED=0

state_get() { # $1=状态文件 $2=key
	grep "^$2=" "$1" | tail -1 | sed 's/^[^=]*=//' | tr -d "'"
}

assert_eq() { # $1=描述 $2=期望 $3=实际
	if [ "$2" = "$3" ]; then
		echo "  PASS: $1"
	else
		echo "  FAIL: $1（期望 '$2'，实际 '$3'）"
		FAILED=1
	fi
}

run_defaults() { # $1=场景名；其余为初始状态行，回显状态文件路径
	name="$1"
	shift
	state="$TESTDIR/state-$name"
	: > "$state"
	for line in "$@"; do printf '%s\n' "$line" >> "$state"; done
	FAKE_UCI_STATE="$state" PATH="$BIN:$PATH" sh "$UD" >/dev/null 2>&1
	echo "$state"
}

echo "== 场景 A：全新安装（应创建 zone + 三条转发 + 放行规则）=="
state=$(run_defaults A)
assert_eq "zone 类型" "zone" "$(state_get "$state" firewall.openvpn_zone)"
assert_eq "zone name" "openvpn" "$(state_get "$state" firewall.openvpn_zone.name)"
assert_eq "zone device" "tun0" "$(state_get "$state" firewall.openvpn_zone.device)"
assert_eq "vpntowan.src" "openvpn" "$(state_get "$state" firewall.vpntowan.src)"
assert_eq "vpntowan.dest" "wan" "$(state_get "$state" firewall.vpntowan.dest)"
assert_eq "vpntolan.src" "openvpn" "$(state_get "$state" firewall.vpntolan.src)"
assert_eq "vpntolan.dest" "lan" "$(state_get "$state" firewall.vpntolan.dest)"
assert_eq "lantovpn.src" "lan" "$(state_get "$state" firewall.lantovpn.src)"
assert_eq "lantovpn.dest" "openvpn" "$(state_get "$state" firewall.lantovpn.dest)"
assert_eq "放行规则类型" "rule" "$(state_get "$state" firewall.openvpn)"

echo "== 场景 D：旧版规则残留（src/dest 指向已废弃的 vpn zone，应重建为 openvpn）=="
state=$(run_defaults D \
	"firewall.vpntowan=forwarding" "firewall.vpntowan.src=vpn" "firewall.vpntowan.dest=wan" \
	"firewall.vpntolan=forwarding" "firewall.vpntolan.src=vpn" "firewall.vpntolan.dest=lan" \
	"firewall.lantovpn=forwarding" "firewall.lantovpn.src=lan" "firewall.lantovpn.dest=vpn")
assert_eq "vpntowan.src 重建" "openvpn" "$(state_get "$state" firewall.vpntowan.src)"
assert_eq "vpntolan.src 重建" "openvpn" "$(state_get "$state" firewall.vpntolan.src)"
assert_eq "lantovpn.dest 重建" "openvpn" "$(state_get "$state" firewall.lantovpn.dest)"

if [ "$FAILED" = "1" ]; then
	echo "结果：存在失败项"
	exit 1
fi
echo "结果：全部通过"
