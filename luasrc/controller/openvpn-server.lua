module("luci.controller.openvpn-server", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/openvpn-server") then
		return
	end
	
	entry({"admin", "vpn"}, firstchild(), "VPN", 45).dependent = false
	
	local page

	page = entry({"admin", "vpn", "openvpn-server"}, cbi("openvpn-server/openvpn-server"), _("OpenVPN Server"), 80)
	page.dependent = false
	page.acl_depends = { "luci-app-openvpn-server" }

	-- status / download / renew 都必须挂同一个 ACL 组。
	-- download 会返回含客户端私钥的 .ovpn，renew 会重建整棵 PKI，
	-- 不能只靠"用户已登录"就放行。
	local acl = { "luci-app-openvpn-server" }

	local e = entry({"admin", "vpn", "openvpn-server", "status"}, call("act_status"))
	e.leaf = true
	e.acl_depends = acl

	e = entry({"admin", "vpn", "openvpn-server", "download"}, call("act_download"))
	e.leaf = true
	e.acl_depends = acl

	-- renew 是破坏性操作：用 post() 注册，dispatcher 会强制
	-- REQUEST_METHOD=POST 且 token 匹配（CSRF 防护在服务端生效，
	-- 模板里带 token 只是配合，不能替代服务端校验）。
	e = entry({"admin", "vpn", "openvpn-server", "renew"}, post("act_renew"))
	e.leaf = true
	e.acl_depends = acl
end

function act_status()
	local e = {}
	-- 按运行时配置文件路径判定进程存活，不依赖 --syslog 字符串
	e.running = luci.sys.call("pgrep -f '/var/etc/openvpn-server-.*[.]conf' >/dev/null") == 0
	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end

function act_download()
	luci.sys.call("sh /etc/openvpn/genovpn.sh >/dev/null 2>&1")

	local f = nixio.open("/tmp/my.ovpn", "r")
	if not f then
		luci.http.status(500)
		luci.http.prepare_content("text/plain")
		luci.http.write("Failed to generate client config: certificate files missing or no enabled server section.")
		return
	end

	luci.http.header("Content-Disposition", 'attachment; filename="my.ovpn"')
	luci.http.prepare_content("application/octet-stream")
	while true do
		local e = f:read(nixio.const.buffersize)
		if not e or #e == 0 then
			break
		end
		luci.http.write(e)
	end
	f:close()
	luci.http.close()

	-- 该文件内含客户端私钥，读完立即删除，避免留在 /tmp 里
	os.remove("/tmp/my.ovpn")
end

function act_renew()
	-- 破坏性操作：重建整棵 PKI，所有已分发的客户端证书立即作废。
	-- CSRF 防护由 dispatcher 的 post() 语义强制（POST + token），
	-- 此处不再自行校验 token。
	luci.sys.call("sh /etc/openvpn/renewcert.sh >/dev/null 2>&1 &")
	luci.http.redirect(luci.dispatcher.build_url("admin/vpn/openvpn-server"))
end
