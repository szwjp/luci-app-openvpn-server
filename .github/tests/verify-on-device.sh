#!/usr/bin/env bash
#
# 实机验收：卸载 → 证明零残留 → 全新安装 →（不做任何补救）→ 卸载 → 再证明零残留
#
# 依据：README「安装」一节的验收标准 —— 「安装命令执行成功」不等于「验收通过」。
#
# 用法：
#   bash .github/tests/verify-on-device.sh [ssh-target] [apk-file]
#     ssh-target  默认 root@192.168.1.139
#     apk-file    本地 .apk 路径；不给则只做卸载与残留核查
#
# 退出码：0 = 全部通过；1 = 有残留或步骤失败
#
# 注意：apk 卸载会保留 /etc 下的配置文件（conffile 受保护），
#       这是 apk 的正常机制；脚本会单独列出这些"配置残留"，
#       如需完全干净请用 --purge-conffiles 一并清掉。

set -o errexit
set -o pipefail
set -o nounset

TARGET="${1:-root@192.168.1.139}"
APK="${2:-}"
PURGE_CONFFILES="${PURGE_CONFFILES:-0}"

PKGS="luci-app-openvpn-server luci-i18n-openvpn-server-zh-cn"
PKG=luci-app-openvpn-server

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; NC=$'\033[0m'
fail=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '  %sOK%s   %s\n' "$GREEN" "$NC" "$*"; }
bad()  { printf '  %sFAIL%s %s\n' "$RED" "$NC" "$*"; fail=1; }
info() { printf '  %s..%s   %s\n' "$YELLOW" "$NC" "$*"; }

run() { ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$TARGET" "$@"; }

# ---------------------------------------------------------------- 残留核查
check_residue() {
	local phase="$1"
	say ""
	say "== 残留核查（$phase） =="

	if run "apk info -e '$PKG' >/dev/null 2>&1"; then
		bad "包仍在已安装列表: $PKG"
	else
		ok "包不在已安装列表"
	fi

	# 全盘文件名扫描（不能用 -xdev：/etc 是独立挂载，会被漏掉）
	local hits
	hits=$(run "find / -iname '*openvpn-server*' -not -path '/proc/*' -not -path '/sys/*' 2>/dev/null" || true)
	if [ -n "$hits" ]; then
		info "同名文件（配置类残留属 apk 正常行为，见下方清单）："
		printf '%s\n' "$hits" | sed 's/^/        /'
	else
		ok "全盘无同名文件"
	fi

	hits=$(run "grep -rl --binary-files=without-match 'openvpn-server' /etc /usr/share /www /usr/lib/lua 2>/dev/null" || true)
	if [ -n "$hits" ]; then
		bad "仍有内容引用:"
		printf '%s\n' "$hits" | sed 's/^/        /'
	else
		ok "关键目录无内容引用"
	fi

	hits=$(run "ps w 2>/dev/null | grep -F 'openvpn-server' | grep -v grep" || true)
	if [ -n "$hits" ]; then
		bad "仍有相关进程:"
		printf '%s\n' "$hits" | sed 's/^/        /'
	else
		ok "无相关进程"
	fi

	hits=$(run "ls /etc/rc.d/ 2>/dev/null | grep -F 'openvpn-server'" || true)
	if [ -n "$hits" ]; then
		bad "仍有 rc.d 链接: $hits"
	else
		ok "无 rc.d 链接"
	fi

	hits=$(run "ls /tmp/run/ 2>/dev/null | grep -F 'openvpn-server'" || true)
	if [ -n "$hits" ]; then
		bad "仍有运行时 socket: $hits"
	else
		ok "无运行时 socket"
	fi

	hits=$(run "ubus call service list 2>/dev/null | grep -F 'openvpn-server'" || true)
	if [ -n "$hits" ]; then
		bad "仍有 procd 实例"
	else
		ok "无 procd 实例"
	fi

	hits=$(run "ls /lib/apk/packages/ 2>/dev/null | grep -F 'openvpn-server'" || true)
	if [ -n "$hits" ]; then
		bad "仍有 apk 元数据: $hits"
	else
		ok "无 apk 元数据残留"
	fi

	hits=$(run "ls /lib/upgrade/keep.d/ 2>/dev/null | grep -F 'openvpn-server'" || true)
	if [ -n "$hits" ]; then
		bad "仍有 keep.d 条目: $hits"
	else
		ok "无 keep.d 条目"
	fi

	# 本包创建的防火墙对象必须在卸载时被清理
	hits=$(run "uci show firewall 2>/dev/null | grep -i openvpn" || true)
	if [ -n "$hits" ]; then
		bad "防火墙残留:"
		printf '%s\n' "$hits" | sed 's/^/        /'
	else
		ok "防火墙无 openvpn 残留"
	fi
}

# ---------------------------------------------------------------- 1. 卸载
say "== 步骤 1：卸载 =="
run "apk del $PKGS 2>&1 || true" | sed 's/^/    /'

if [ "$PURGE_CONFFILES" = "1" ]; then
	info "清理配置文件残留（--purge-conffiles）"
	run "rm -f /etc/config/openvpn-server /etc/config/openvpn-server.apk-new /etc/openvpn-addon.conf /etc/openvpn-addon.conf.apk-new" 2>/dev/null || true
	run "rm -rf /etc/openvpn/pki" 2>/dev/null || true
fi

check_residue "卸载后"

# ---------------------------------------------------------------- 2. 全新安装
if [ -n "$APK" ]; then
	say ""
	say "== 步骤 2：全新安装（只跑这一条命令，不做任何补救） =="
	[ -f "$APK" ] || { bad "apk 文件不存在: $APK"; exit 1; }
	remote="/tmp/$(basename "$APK")"
	scp -q -o ConnectTimeout=10 "$APK" "$TARGET:$remote"
	info "安装命令: apk add --allow-untrusted $remote"
	run "apk add --allow-untrusted '$remote' 2>&1" | sed 's/^/    /'

	say ""
	say "== 步骤 3：装后状态（不做任何手工补救） =="
	if run "apk info -e '$PKG' >/dev/null 2>&1"; then
		ok "包已安装"
	else
		bad "包未进入已安装列表"
	fi

	if run "[ -x /etc/init.d/openvpn-server ] && /etc/init.d/openvpn-server enabled"; then
		ok "init 脚本已安装且已 enable"
	else
		bad "init 脚本缺失或未 enable"
	fi

	if run "[ -f /etc/config/openvpn-server ]"; then
		ok "配置文件已安装"
	else
		bad "配置文件缺失"
	fi

	if run "[ -f /etc/openvpn/pki/ca.crt ] && [ -f /etc/openvpn/pki/server.key ] && [ -f /etc/openvpn/pki/client1.key ]"; then
		ok "PKI 已生成"
	else
		bad "PKI 未生成"
	fi

	if run "uci show firewall 2>/dev/null | grep -q \"firewall.openvpn_zone.name='openvpn'\""; then
		ok "防火墙 zone 已建立"
	else
		bad "防火墙 zone 未建立"
	fi

	if run "[ -f /usr/share/rpcd/acl.d/luci-app-openvpn-server.json ] && [ -f /usr/lib/lua/luci/controller/openvpn-server.lua ]"; then
		ok "ACL 与 Lua 后端已安装"
	else
		bad "ACL 或 Lua 后端缺失"
	fi

	# uci-defaults 必须被执行并删除（执行后残留说明 default_postinst 没生效）
	hits=$(run "ls /etc/uci-defaults/ 2>/dev/null | grep -F 'openvpn-server'" || true)
	if [ -n "$hits" ]; then
		bad "uci-defaults 未被执行: $hits"
	else
		ok "uci-defaults 已执行并清理"
	fi

	say ""
	say "== 步骤 4：卸载并复检 =="
	run "apk del $PKGS 2>&1 || true" | sed 's/^/    /'
	check_residue "卸载后"
	run "rm -f '$remote'"
else
	say ""
	info "未提供 apk 文件，只做了卸载与残留核查"
fi

say ""
if [ $fail -eq 0 ]; then
	say "${GREEN}验收结果：通过${NC}"
else
	say "${RED}验收结果：不通过${NC}"
fi
exit $fail
