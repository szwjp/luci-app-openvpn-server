#!/bin/sh
# 重建整个 PKI（CA + 服务端 + client1 证书）。
# 注意：重建会作废所有已分发的客户端证书，客户端必须重新导入。

set -e

export EASYRSA_PKI="/etc/easy-rsa/pki"
export EASYRSA_VARS_FILE="/etc/easy-rsa/vars-server"
export EASYRSA_CLI="easyrsa --batch"

# Cleanup
echo -en "yes\nyes\n" | $EASYRSA_CLI init-pki

# Generate DH
$EASYRSA_CLI gen-dh

# Generate for the CA
$EASYRSA_CLI build-ca nopass

# Generate for the server
$EASYRSA_CLI build-server-full server nopass

# Generate for the client
$EASYRSA_CLI build-client-full client1 nopass

# Copy files
mkdir -p /etc/openvpn/pki
cp /etc/easy-rsa/pki/ca.crt /etc/openvpn/pki/
cp /etc/easy-rsa/pki/dh.pem /etc/openvpn/pki/
cp /etc/easy-rsa/pki/issued/server.crt /etc/openvpn/pki/
cp /etc/easy-rsa/pki/private/server.key /etc/openvpn/pki/
cp /etc/easy-rsa/pki/issued/client1.crt /etc/openvpn/pki/
cp /etc/easy-rsa/pki/private/client1.key /etc/openvpn/pki/
chmod 600 /etc/openvpn/pki/server.key /etc/openvpn/pki/client1.key

# Restart openvpn
/etc/init.d/openvpn-server restart

echo "OpenVPN Cert renew successfully"
