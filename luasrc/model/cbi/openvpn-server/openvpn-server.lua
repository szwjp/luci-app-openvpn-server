
--require("luci.tools.webadmin")

mp = Map("openvpn-server", translate("OpenVPN Server"), translate("An easy config OpenVPN Server Web-UI"))

local NXFS = require "nixio.fs"
local UCI = require "luci.model.uci"

mp:section(SimpleSection).template = "openvpn/openvpn_status"

s = mp:section(TypedSection, "openvpn")
s.anonymous = true
s.addremove = false

s:tab("basic", translate("Base Setting"))
s:tab("control", translate("Connection Control"))
s:tab("push", translate("Push Settings"))
s:tab("cert", translate("Certificate Files"))
s:tab("debug", translate("Log and Debug"))

o = s:taboption("basic", Flag, "enabled", translate("Enable"))

proto = s:taboption("basic", ListValue, "proto", translate("Proto"))
proto:value("tcp-server", translate("TCP Server IPv4"))
proto:value("udp", translate("UDP Server IPv4"))
proto:value("tcp6-server", translate("TCP Server IPv6"))
proto:value("udp6", translate("UDP Server IPv6"))

port = s:taboption("basic", Value, "port", translate("Port"))
port.datatype = "range(1, 65535)"

ddns = s:taboption("basic", Value, "ddns", translate("WAN DDNS or IP"))
ddns.rmempty = false
function ddns.validate(self, value)
	if value == "" then
		return nil, translate("WAN DDNS or IP is required")
	end

	if value:match("^[%w%.%-:%_]+$") then
		return value
	end

	return nil, translate("Please enter a valid domain or IP address")
end

localnet = s:taboption("basic", Value, "server", translate("Client Network"))
localnet.datatype = "string"
localnet.description = translate("VPN Client Network IP with subnet")

max_clients = s:taboption("basic", Value, "max_clients", translate("Max Clients"))
max_clients.datatype = "uinteger"
max_clients.description = translate("Allow maximum connected clients")
function max_clients.validate(self, value)
	local num = tonumber(value)

	if num and num > 0 and math.floor(num) == num then
		return tostring(num)
	end

	return nil, translate("Please enter a positive integer")
end

duplicate_cn = s:taboption("basic", Flag, "duplicate_cn", translate("Allow duplicate certificate login"))
duplicate_cn.description = translate("Allow multiple clients to connect using the same certificate")

client_to_client = s:taboption("control", Flag, "client_to_client", translate("Allow client-to-client traffic"))

comp_lzo = s:taboption("control", ListValue, "comp_lzo", translate("Enable LZO compression"))
comp_lzo:value("yes", "yes")
comp_lzo:value("no", "no")
comp_lzo:value("adaptive", "adaptive")

keepalive = s:taboption("control", Value, "keepalive", translate("Keepalive"))
keepalive.datatype = "string"
keepalive.description = translate("Helper directive to simplify the expression of ping and ping-restart")

topology = s:taboption("control", ListValue, "topology", translate("Topology"))
topology:value("subnet", "subnet")
topology:value("net30", "net30")
topology:value("p2p", "p2p")

redirect_gateway = s:taboption("control", ListValue, "redirect_gateway", translate("Automatically redirect default route"))
redirect_gateway:value("", "-- remove --")
redirect_gateway:value("local", "local")
redirect_gateway:value("def1", "def1")
redirect_gateway:value("local def1", "local def1")

persist_key = s:taboption("control", Flag, "persist_key", translate("Persist key"))
persist_tun = s:taboption("control", Flag, "persist_tun", translate("Persist tun"))

user = s:taboption("control", Value, "user", translate("User"))
group = s:taboption("control", Value, "group", translate("Group"))

list = s:taboption("push", DynamicList, "push")
list.title = translate("Client Settings")
list.datatype = "string"
list.description = translate("Set route 192.168.0.0 255.255.255.0 and dhcp-option DNS 192.168.0.1 base on your router")

local upload_targets = {
	ca = "/etc/openvpn/pki/ca.crt",
	dh = "/etc/openvpn/pki/dh.pem",
	cert = "/etc/openvpn/pki/server.crt",
	key = "/etc/openvpn/pki/server.key"
}

local function copy_uploaded_file(source, target)
	if not source or source == "" then
		return true
	end

	NXFS.mkdirr(target:match("(.+)/[^/]+$"))

	local input = nixio.open(source, "r")
	if not input then
		return nil, translate("Unable to read uploaded file")
	end

	local output = nixio.open(target, "w")
	if not output then
		input:close()
		return nil, translate("Unable to write target file")
	end

	while true do
		local chunk = input:read(nixio.const.buffersize)
		if not chunk or #chunk == 0 then
			break
		end
		output:write(chunk)
	end

	input:close()
	output:close()

	-- 私钥必须收紧权限（受 umask 影响默认可能是 0644）
	if target:match("%.key$") then
		NXFS.chmod(target, 0x180) -- 0600
	end

	return true
end

local function add_fixed_upload(option, title, description)
	local o = s:taboption("cert", FileUpload, option, title)
	o.root_directory = "/etc/openvpn/pki"
	o.initial_directory = "/etc/openvpn/pki"
	o.description = description

	function o.cfgvalue(self, section)
		return upload_targets[option]
	end

	function o.formvalue(self, section)
		local value = FileUpload.formvalue(self, section)
		return value ~= "" and value or nil
	end

	function o.write(self, section, value)
		local target = upload_targets[option]

		if value and value ~= "" and value ~= target then
			local ok, err = copy_uploaded_file(value, target)
			if ok == nil then
				self:add_error(section, "invalid", err)
				return
			end
		end

		self.map.uci:set("openvpn-server", section, option, target)
	end

	return o
end

ca = add_fixed_upload("ca", translate("CA certificate"), translate("Upload and overwrite /etc/openvpn/pki/ca.crt"))
dh = add_fixed_upload("dh", translate("Diffie-Hellman parameters"), translate("Upload and overwrite /etc/openvpn/pki/dh.pem"))
cert = add_fixed_upload("cert", translate("Server certificate"), translate("Upload and overwrite /etc/openvpn/pki/server.crt"))
key = add_fixed_upload("key", translate("Server private key"), translate("Upload and overwrite /etc/openvpn/pki/server.key"))

verb = s:taboption("debug", ListValue, "verb", translate("Set output verbosity"))
for i = 0, 11 do
	verb:value(tostring(i))
end

status = s:taboption("debug", Value, "status", translate("Status file"))
log = s:taboption("debug", Value, "log", translate("Log file"))

local o
o = s:taboption("basic", DummyValue, "certificate", translate("OpenVPN Client config file"))
o.template = "openvpn/dlbutton"
o.cfgvalue = function(self, section)
	return ""
end

s:tab("code", translate("Special Code"))

local conf = "/etc/openvpn-addon.conf"
o = s:taboption("code", TextValue, "conf")
o.description = translate("(!)Special Code you know that add in to client .ovpn file")
o.rows = 13
o.wrap = "off"
o.cfgvalue = function(self, section)
	return NXFS.readfile(conf) or ""
end
o.write = function(self, section, value)
	NXFS.writefile(conf, value:gsub("\r\n", "\n"))
end

function mp.on_after_commit(self)
	local port = "1194"
	local found = false
	local fw = UCI.cursor()

	-- 取第一个启用实例的端口，不再硬编码 section 名
	fw:foreach("openvpn-server", "openvpn", function(s)
		if not found and s.enabled == "1" then
			found = true
			port = s.port or "1194"
		end
	end)

	-- 规则存在时仅同步端口（保留用户自定义）；不存在时创建基础放行规则
	if fw:get("firewall", "openvpn") then
		fw:set("firewall", "openvpn", "dest_port", port)
	else
		fw:set("firewall", "openvpn", "rule")
		fw:set("firewall", "openvpn", "name", "openvpn")
		fw:set("firewall", "openvpn", "target", "ACCEPT")
		fw:set("firewall", "openvpn", "src", "wan")
		fw:set("firewall", "openvpn", "proto", "tcp udp")
		fw:set("firewall", "openvpn", "dest_port", port)
	end

	-- 兜底确保 vpn zone 与转发规则存在且配置正确。
	-- zone 的 section 名用 openvpn_zone、name 用 'openvpn'（fw4 按 name 匹配），
	-- 避免与 ipsec-vpnd 的大小写 vpn/VPN section 混淆导致 zone 丢失、转发静默失效。
	local zone = fw:get("firewall", "openvpn_zone")
	if not zone then
		fw:set("firewall", "openvpn_zone", "zone")
		fw:set("firewall", "openvpn_zone", "name", "openvpn")
		fw:set("firewall", "openvpn_zone", "input", "ACCEPT")
		fw:set("firewall", "openvpn_zone", "forward", "ACCEPT")
		fw:set("firewall", "openvpn_zone", "output", "ACCEPT")
	elseif zone ~= "zone" then
		-- 存在但类型被改（罕见），修正为 zone
		fw:set("firewall", "openvpn_zone", "zone")
	end
	if fw:get("firewall", "openvpn_zone", "name") ~= "openvpn" then
		fw:set("firewall", "openvpn_zone", "name", "openvpn")
	end
	-- device 列表必须包含 tun0，缺失则补（zone 被重建或改动后自愈）
	local devs = fw:get_list("firewall", "openvpn_zone", "device")
	local has_tun0 = false
	if devs then
		for _, dev in ipairs(devs) do
			if dev == "tun0" then has_tun0 = true end
		end
	end
	if not has_tun0 then
		fw:add_list("firewall", "openvpn_zone", "device", "tun0")
	end

	local forwards = {
		{ "vpntowan", "openvpn", "wan" },
		{ "vpntolan", "openvpn", "lan" },
		{ "lantovpn", "lan", "openvpn" }
	}
	for _, f in ipairs(forwards) do
		local cur = fw:get("firewall", f[1])
		if not cur then
			fw:set("firewall", f[1], "forwarding")
			fw:set("firewall", f[1], "src", f[2])
			fw:set("firewall", f[1], "dest", f[3])
		else
			-- 旧版遗留规则 src/dest 指向已不存在的 'vpn' zone 时，fw4 转发会静默失效，必须修正
			if cur ~= "forwarding" then
				fw:set("firewall", f[1], "forwarding")
			end
			if fw:get("firewall", f[1], "src") ~= f[2] then
				fw:set("firewall", f[1], "src", f[2])
			end
			if fw:get("firewall", f[1], "dest") ~= f[3] then
				fw:set("firewall", f[1], "dest", f[3])
			end
		end
	end
	fw:commit("firewall")
	-- 不显式 restart：两个 init 脚本均注册了 procd reload trigger，
	-- uci commit 后由 procd 按需自动重载；手动 restart 会在服务被禁用时误拉起
end

return mp
