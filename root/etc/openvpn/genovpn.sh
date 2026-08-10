#!/bin/sh
# 生成客户端 .ovpn 配置文件（/tmp/my.ovpn）。
# 取第一个启用的 openvpn 实例；证书缺失时明确失败（配合 LuCI 下载入口提示）。

set -e

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

[ -n "$ddns" ] || { echo "openvpn-server.$section.ddns is empty" >&2; exit 1; }

for f in /etc/openvpn/pki/ca.crt /etc/openvpn/pki/client1.crt /etc/openvpn/pki/client1.key; do
	[ -f "$f" ] || { echo "Missing $f - run certificate rebuild first" >&2; exit 1; }
done

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
echo '<ca>' >> /tmp/my.ovpn
cat /etc/openvpn/pki/ca.crt >> /tmp/my.ovpn
echo '</ca>' >> /tmp/my.ovpn
echo '<cert>' >> /tmp/my.ovpn
cat /etc/openvpn/pki/client1.crt >> /tmp/my.ovpn
echo '</cert>' >> /tmp/my.ovpn
echo '<key>' >> /tmp/my.ovpn
cat /etc/openvpn/pki/client1.key >> /tmp/my.ovpn
echo '</key>' >> /tmp/my.ovpn
[ -f /etc/openvpn-addon.conf ] && cat /etc/openvpn-addon.conf >> /tmp/my.ovpn
