#!/bin/sh
# LuCI 侧静态守卫：防止重犯三类已被审计发现并修复的错误。
#
#  1) 调用 luci.model.uci cursor 上并不存在的方法
#     （历史上用了 fw:add_list()，真实 cursor 只有 set_list()，
#       调用不存在的 API 会抛 Lua 异常，导致整次保存失败；
#       而当时的 fake-uci 测试替身比真 API 更宽松，把问题放了过去）
#  2) 破坏性动作（重建证书）没有走 post() 注册，
#     dispatcher 就不会强制 POST + CSRF token，跨站 GET 即可触发
#  3) 敏感入口（下载 / 重建）没有挂 acl_depends，
#     任何已登录用户都能取走客户端私钥 / 重建整棵 PKI
#
# 无需 OpenWrt 环境。
# 运行：sh .github/tests/test-luci-api.sh
set -u

cd "$(dirname "$0")/../.."
CBI=luasrc/model/cbi/openvpn-server/openvpn-server.lua
CTL=luasrc/controller/openvpn-server.lua
INIT=root/etc/init.d/openvpn-server

FAILED=0

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILED=1; }

# luci.model.uci cursor 的真实方法集合（immortalwrt/luci master:
# modules/luci-lua-runtime/luasrc/model/uci.lua）
CURSOR_METHODS="get get_state get_all get_bool get_first get_list section add set set_list tset reorder delete delete_all commit apply confirm rollback rollback_pending revert changes load save unload foreach get_confdir get_savedir get_session_id set_confdir set_savedir set_session_id substate cursor_state cursor"

echo "== 1. cursor API 白名单检查 =="
# 只检查明确持有 cursor 的变量名，避免误伤 CBI 自身的方法（write/parse/...）
USED=$(grep -oE '\b(fw|uci_cursor)\:[a-zA-Z_][a-zA-Z0-9_]*\(' "$CBI" "$CTL" 2>/dev/null \
	| sed -E 's/.*\://; s/\($//' | sort -u)

if [ -z "$USED" ]; then
	fail "未找到任何 cursor 调用，检查规则本身是否失效"
else
	for m in $USED; do
		case " $CURSOR_METHODS " in
			*" $m "*) pass "cursor 方法可用: $m" ;;
			*) fail "cursor 没有方法 $m（真实 API 里不存在，调用会抛 Lua 异常）" ;;
		esac
	done
fi

echo "== 2. 破坏性动作必须走 post() =="
if grep -q 'post("act_renew")' "$CTL"; then
	pass "renew 用 post() 注册（dispatcher 会强制 POST + CSRF token）"
else
	fail "renew 未用 post() 注册 —— dispatcher 不会做 CSRF 校验，跨站 GET 即可触发重建 PKI"
fi

echo "== 3. 敏感入口必须挂 ACL =="
# 主页面 1 处 + status/download/renew 各 1 处 = 至少 4 处
ACL_COUNT=$(grep -c 'acl_depends' "$CTL")
if [ "$ACL_COUNT" -ge 4 ]; then
	pass "acl_depends 覆盖 $ACL_COUNT 个入口"
else
	fail "acl_depends 只有 $ACL_COUNT 处，至少需要 4 处（主页面 + status + download + renew）"
fi

echo "== 4. 服务端不得输出顶层 redirect-gateway =="
if grep -q 'redirect_gateway' "$INIT"; then
	fail "init 脚本仍输出 redirect_gateway —— 服务端模式下 openvpn 会 usage error 退出"
else
	pass "init 脚本不输出 redirect_gateway"
fi

echo "== 5. CBI 不应再提供 redirect_gateway 选项 =="
if grep -q 'taboption("control", ListValue, "redirect_gateway"' "$CBI"; then
	fail "CBI 仍提供 redirect_gateway 选项，选了就会让 openvpn 起不来"
else
	pass "CBI 无 redirect_gateway 选项"
fi

echo "== 6. 客户端地址池持久化 =="
if grep -q 'ifconfig_pool_persist' "$INIT"; then
	pass "已下发 ifconfig-pool-persist"
else
	fail "缺少 ifconfig-pool-persist，客户端每次重连都会换地址"
fi

if [ "$FAILED" = "1" ]; then
	echo "结果：存在失败项"
	exit 1
fi
echo "结果：全部通过"
