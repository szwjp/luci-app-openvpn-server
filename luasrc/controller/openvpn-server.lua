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
	entry({"admin", "vpn", "openvpn-server", "status"}, call("act_status")).leaf = true
	entry({"admin", "vpn", "openvpn-server", "download"}, call("act_download")).leaf = true
	entry({"admin", "vpn", "openvpn-server", "renew"}, call("act_renew")).leaf = true
end

function act_status()
	local e = {}
	e.running = luci.sys.call("pgrep -f '[o]penvpn-server' >/dev/null") == 0
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
end

function act_renew()
	-- 仅接受带 CSRF token 的 POST（模板中已注入 token）
	luci.sys.call("sh /etc/openvpn/renewcert.sh >/dev/null 2>&1 &")
	luci.http.redirect(luci.dispatcher.build_url("admin/vpn/openvpn-server"))
end
