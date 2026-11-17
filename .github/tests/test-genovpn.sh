#!/bin/sh
# genovpn.sh 离线测试：验证客户端 .ovpn 带上 tun-mtu/mssfix/tls-crypt，
# 以及 tls-crypt 开启但密钥缺失时必须失败，而不是生成一份坏配置。
# 运行：sh .github/tests/test-genovpn.sh
set -u

cd "$(dirname "$0")/../.."
SRC=root/etc/openvpn/genovpn.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAILED=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILED=1; }

mkdir -p "$TMP/pki" "$TMP/bin"
for f in ca.crt client1.crt client1.key; do
	printf 'dummy-%s\n' "$f" > "$TMP/pki/$f"
done
printf 'dummy-tls-crypt-key\n' > "$TMP/pki/tc.key"

cat > "$TMP/bin/uci" <<'UCI'
#!/bin/sh
[ "$1" = "-q" ] && shift
case "$1" in
get)
	case "$2" in
	openvpn-server.myvpn.ddns) echo 1.2.3.4 ;;
	openvpn-server.myvpn.port) echo 1194 ;;
	openvpn-server.myvpn.proto) echo tcp-server ;;
	openvpn-server.myvpn.dev) echo tun ;;
	openvpn-server.myvpn.tls_crypt) echo 1 ;;
	openvpn-server.myvpn.tun_mtu) echo 1400 ;;
	openvpn-server.myvpn.mssfix) echo 1360 ;;
	*) exit 1 ;;
	esac
	;;
show)
	echo "openvpn-server.myvpn.enabled='1'"
	;;
*) exit 1 ;;
esac
UCI
chmod 0755 "$TMP/bin/uci"

# 路径改到临时目录，避免碰真实 PKI 和 /tmp/my.ovpn
sed -e "s|/etc/openvpn/pki|$TMP/pki|g" \
    -e "s|/tmp/my.ovpn|$TMP/my.ovpn|g" \
    "$SRC" > "$TMP/genovpn.sh"
chmod 0755 "$TMP/genovpn.sh"

PATH="$TMP/bin:$PATH" sh "$TMP/genovpn.sh" >/dev/null 2>&1
rc=$?
[ "$rc" = "0" ] && pass "生成客户端配置成功" || fail "生成客户端配置失败（rc=$rc）"

for pat in '^tun-mtu 1400$' '^mssfix 1360$' '^<tls-crypt>$' '^dummy-tls-crypt-key$' '^<cert>$'; do
	if grep -q "$pat" "$TMP/my.ovpn" 2>/dev/null; then
		pass "客户端配置包含 $pat"
	else
		fail "客户端配置缺少 $pat"
	fi
done

rm -f "$TMP/pki/tc.key"
PATH="$TMP/bin:$PATH" sh "$TMP/genovpn.sh" >/dev/null 2>&1
rc=$?
[ "$rc" != "0" ] && pass "tls-crypt 密钥缺失时失败" || fail "tls-crypt 密钥缺失时仍成功（不应发生）"

if [ "$FAILED" = "1" ]; then
	echo "结果：存在失败项"
	exit 1
fi
echo "结果：全部通过"
