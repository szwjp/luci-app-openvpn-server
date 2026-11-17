#!/bin/sh
# 生成客户端 .ovpn 配置文件（/tmp/my.ovpn）。
# 取第一个启用的 openvpn 实例；证书缺失时明确失败（配合 LuCI 下载入口提示）。

set -e

# 生成的 .ovpn 内含客户端私钥（client1.key），必须只有 root 可读
umask 077

section=""
for s in $(uci -q show openvpn-server 2>/dev/null | sed -n "s/^openvpn-server\.\([^.]*\)\.enabled='1'/\1/p"); do
	section="$s"
	break
done

[ -n "$section" ] || { echo "No enabled openvpn-server section found" >&2; exit 1; }

ddns=$(uci -q get openvpn-server.$section.ddns)
port=$(uci -q get openvpn-server.$section.port)
proto=$(uci -q get openvpn-server.$section.proto | sed -e 's/server/client/g')
dev=$(uci -q get openvpn-server.$section.dev)
tls_crypt=$(uci -q get openvpn-server.$section.tls_crypt)
tun_mtu=$(uci -q get openvpn-server.$section.tun_mtu)
mssfix=$(uci -q get openvpn-server.$section.mssfix)

[ -n "$ddns" ] || { echo "openvpn-server.$section.ddns is empty" >&2; exit 1; }

for f in /etc/openvpn/pki/ca.crt /etc/openvpn/pki/client1.crt /etc/openvpn/pki/client1.key; do
	[ -f "$f" ] || { echo "Missing $f - run certificate rebuild first" >&2; exit 1; }
done

# 启用 tls-crypt 时服务端密钥必须存在；缺失说明安装/重建不完整，直接失败，
# 不要生成一份"看着能连、握手就断"的客户端配置。
if [ "$tls_crypt" = "1" ]; then
	[ -s /etc/openvpn/pki/tc.key ] || {
		echo "Missing /etc/openvpn/pki/tc.key - enable/rebuild server first" >&2
		exit 1
	}
fi

cat > /tmp/my.ovpn <<EOF
client
dev $dev
proto $proto
remote $ddns $port
resolv-retry infinite
nobind
persist-key
persist-tun
verb 3
EOF

# 与服务端保持一致；两端 tun-mtu 不一致会导致大包被丢弃。
[ -n "$tun_mtu" ] && echo "tun-mtu $tun_mtu" >> /tmp/my.ovpn
[ -n "$mssfix" ] && echo "mssfix $mssfix" >> /tmp/my.ovpn

echo '<ca>' >> /tmp/my.ovpn
cat /etc/openvpn/pki/ca.crt >> /tmp/my.ovpn
echo '</ca>' >> /tmp/my.ovpn
echo '<cert>' >> /tmp/my.ovpn
cat /etc/openvpn/pki/client1.crt >> /tmp/my.ovpn
echo '</cert>' >> /tmp/my.ovpn
echo '<key>' >> /tmp/my.ovpn
cat /etc/openvpn/pki/client1.key >> /tmp/my.ovpn
echo '</key>' >> /tmp/my.ovpn
if [ "$tls_crypt" = "1" ]; then
	echo '<tls-crypt>' >> /tmp/my.ovpn
	cat /etc/openvpn/pki/tc.key >> /tmp/my.ovpn
	echo '</tls-crypt>' >> /tmp/my.ovpn
fi
# 追加用户自定义代码；压缩项一律剔除：客户端启用压缩会与服务端（已禁用压缩）
# 的帧格式不一致，导致数据通道包被静默丢弃（能登录但访问不了任何东西）。
# 注意脚本开了 set -e，grep 过滤后可能返回 1，必须 || true 兜底。
[ -f /etc/openvpn-addon.conf ] && grep -v -E '^[[:space:]]*(comp-lzo|compress)' /etc/openvpn-addon.conf >> /tmp/my.ovpn || true
