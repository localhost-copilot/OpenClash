-- Device egress integration. Keep guard installation separate from core lifetime.
local M = {}
local policy = require "luci.device_egress"
local fs = require "nixio.fs"
local nixio = require "nixio"
local sys = require "luci.sys"
local util = require "luci.util"
local json = require "luci.jsonc"
local cursor = require("luci.model.uci").cursor
local share = "/usr/share/openclash/"
local cache = "/etc/openclash/device-guard.nft"

local function command(args)
	local quoted = {}
	for _, arg in ipairs(args) do quoted[#quoted + 1] = util.shellquote(tostring(arg)) end
	return table.concat(quoted, " ")
end

local function temp(content)
	-- nixio.mkstemp returns an already unlinked descriptor, not a filename.
	-- These files must also be opened by child processes (ruby/nft/curl).
	local path = (sys.exec("mktemp /tmp/openclash-egress.XXXXXX") or ""):match("^(/tmp/openclash%-egress%.%w+)%s*$")
	assert(path, "Cannot create temporary file")
	assert(fs.writefile(path, content or ""), "Cannot write temporary file")
	return path
end

local function run(args, input)
	local source, output, errors = temp(input or ""), temp(), temp()
	local code = sys.call(command(args) .. " <" .. util.shellquote(source) .. " >" .. util.shellquote(output) .. " 2>" .. util.shellquote(errors))
	local out, err = fs.readfile(output) or "", fs.readfile(errors) or ""
	fs.unlink(source); fs.unlink(output); fs.unlink(errors)
	return code == 0, out, err
end
M.run = run

local function decode(value)
	local ok, result = pcall(json.parse, value or "")
	return ok and type(result) == "table" and result or nil
end

function M.rows(uci)
	local rows = {}
	uci = uci or cursor()
	uci:foreach("openclash", "device_egress", function(s)
		rows[#rows + 1] = {id = s['.name'], enabled = s.enabled or "1", name = s.name or s.mac,
			mac = s.mac, ip = s.ip, target = s.target, port = 7901 + #rows}
	end)
	return rows
end

function M.lans()
	local uci, lans, lans6 = cursor(), {}, {}
	local _, output = run({"ubus", "call", "network.interface.lan", "status"})
	local status = decode(output) or {}
	for _, item in ipairs(status['ipv4-address'] or {}) do
		if policy.network(item.address, item.mask) then lans[#lans + 1] = {address = item.address, prefix = item.mask} end
	end
	for _, item in ipairs(status['ipv6-address'] or {}) do lans6[#lans6 + 1] = item.address .. "/" .. item.mask end
	for _, item in ipairs(status['ipv6-prefix-assignment'] or {}) do
		lans6[#lans6 + 1] = item.address .. "/" .. item.mask
	end
	-- Boot fallback: netifd is not up at START=18. Use only network.lan.
	if #lans == 0 then
		local addresses = uci:get("network", "lan", "ipaddr") or {}
		if type(addresses) == "string" then addresses = {addresses} end
		for _, value in ipairs(addresses) do
			local address, prefix = value:match("^([^/]+)/(%d+)$")
			address = address or value
			if not prefix then
				local mask = policy.ipv4(uci:get("network", "lan", "netmask") or "255.255.255.0")
				if mask then
					for bits = 1, 32 do if mask == 2^32 - 2^(32-bits) then prefix = bits; break end end
				end
			end
			if policy.network(address, prefix) then lans[#lans + 1] = {address = address, prefix = tonumber(prefix)} end
		end
	end
	return lans, lans6
end

function M.supported()
	return sys.call("command -v nft >/dev/null 2>&1 && command -v fw4 >/dev/null 2>&1") == 0
end

function M.config_paths()
	local path = cursor():get("openclash", "config", "config_path") or "/etc/openclash/config/config.yaml"
	if path:sub(1, 22) ~= "/etc/openclash/config/" or path:find("/../", 1, true) then return nil end
	return path, "/etc/openclash/" .. (path:match("([^/]+)$") or "config.yaml")
end

local function ruby(operation, path, data)
	local ok, out, err = run({"ruby", share .. "device_egress.rb", operation, path}, json.stringify(data or {}))
	return ok, decode(out), err
end

function M.api(method, path, body)
	local uci = cursor()
	local port = tonumber(uci:get("openclash", "config", "cn_port")) or 9090
	local secret = uci:get("openclash", "config", "dashboard_password") or ""
	-- Always contact the local core, never a host supplied by the browser.
	local timeout = (path == "/proxies" or path == "/providers/proxies") and "2" or "8"
	local args = {"curl", "--silent", "--show-error", "--fail", "--max-time", timeout, "--noproxy", "*",
		"-H", "Authorization: Bearer " .. secret, "-H", "Content-Type: application/json", "-X", method,
		"http://127.0.0.1:" .. port .. path}
	if body then args[#args + 1] = "--data-binary"; args[#args + 1] = "@-" end
	return run(args, body and json.stringify(body))
end

function M.pid()
	return (sys.exec("pidof clash 2>/dev/null") or ""):match("%d+")
end

function M.targets(running)
	local raw, runtime = M.config_paths()
	if not raw then return {}, "Invalid configuration path" end
	local live = {}
	if running then
		local ok, out = M.api("GET", "/proxies")
		if ok then live = decode(out) or {} end
		ok, out = M.api("GET", "/providers/proxies")
		local providers = ok and decode(out)
		if providers then live.providers = providers.providers end
	end
	local ok, entries, err = ruby("catalogue", running and fs.access(runtime) and runtime or raw, live)
	if not ok or not entries then return {}, err ~= "" and err or "Cannot read device egress targets" end
	return entries
end

function M.devices()
	local uci, devices = cursor(), {}
	local function get(mac)
		if not policy.mac(mac) then return nil end
		mac = mac:upper()
		devices[mac] = devices[mac] or {mac = mac, name = mac, online = false, fixed = false}
		return devices[mac]
	end
	local _, output = run({"ip", "-j", "neigh", "show"})
	local neighbours = decode(output)
	-- Isolated compatibility fallback for older ip-full without JSON output.
	if not neighbours then
		neighbours = {}
		local _, plain = run({"ip", "-4", "neigh", "show"})
		for line in plain:gmatch("[^\n]+") do
			local ip, mac = line:match("^(%d+%.%d+%.%d+%.%d+).-%slladdr%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
			if ip then neighbours[#neighbours + 1] = {dst = ip, lladdr = mac, state = {line:match("(%u+)$")}} end
		end
	end
	local lans = M.lans()
	for _, item in ipairs(neighbours) do
		local device = get(item.lladdr)
		if device and policy.ipv4(item.dst) then
			local local_ip = false
			for _, lan in ipairs(lans) do
				local _, base, block = policy.network(lan.address, lan.prefix)
				local value = policy.ipv4(item.dst)
				if value >= base and value < base + block then local_ip = true end
			end
			if local_ip then
				local states = type(item.state) == "table" and table.concat(item.state, " ") or tostring(item.state)
				local valid = not states:find("FAILED", 1, true) and not states:find("INCOMPLETE", 1, true)
				if valid then device.online = true; device.current_ip = item.dst end
			end
		end
	end
	for line in (fs.readfile("/tmp/dhcp.leases") or ""):gmatch("[^\n]+") do
		local expiry, mac, ip, name = line:match("^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)")
		local device = get(mac)
		if device and (tonumber(expiry) == 0 or tonumber(expiry) > os.time()) then
			device.ip = ip
			device.current_ip = device.current_ip or ip
			if name ~= "*" then device.name = name end
		end
	end
	uci:foreach("dhcp", "host", function(s)
		local macs = type(s.mac) == "table" and s.mac or {s.mac or ""}
		for _, value in ipairs(macs) do
			for mac in value:gmatch("%S+") do
				local device = get(mac)
				if device then
					device.fixed = true; device.fixed_ip = s.ip; device.ip = s.ip or device.ip
					if s.name and s.name ~= "" then device.name = s.name end
				end
			end
		end
	end)
	local result = {}
	for _, device in pairs(devices) do
		device.ip = device.current_ip or device.ip
		device.fixed = device.fixed and device.fixed_ip == device.ip
		result[#result + 1] = device
	end
	table.sort(result, function(a, b) return a.name < b.name end)
	return result
end

function M.render_guard(rows)
	local lans, lans6 = M.lans()
	return policy.render_guard(rows or M.rows(), lans, lans6, cursor():get("openclash", "config", "device_egress_ct_mark") == "1")
end

function M.cache_matches_bindings()
	local expected, actual = {}, {}
	for _, row in ipairs(M.rows()) do
		if row.enabled == "1" then
			if not policy.mac(row.mac) or not policy.ipv4(row.ip) then return false end
			expected[#expected + 1] = row.mac:upper() .. " " .. row.ip
		elseif row.enabled ~= "0" then return false end
	end
	local content = fs.readfile(cache)
	if not content then return false end
	for binding in content:gmatch("# binding ([^\n]+)") do actual[#actual + 1] = binding end
	table.sort(expected); table.sort(actual)
	return table.concat(expected, "\n") == table.concat(actual, "\n")
end

function M.install_guard(rows)
	local rendered, err = M.render_guard(rows)
	-- The shell installer covers generator failures too, including missing Lua.
	local path = rendered and temp(rendered) or nil
	local ok, _, details = run({share .. "device_egress_guard.sh", path and "install" or "emergency", path or ""})
	if path then fs.unlink(path) end
	return rendered ~= nil and ok, err or details
end

local function equal(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
	for key in pairs(b) do if a[key] == nil then return false end end
	return true
end

function M.protected(rows)
	local expected = M.render_guard(rows)
	if not expected or fs.readfile(cache) ~= expected then return false end
	local active = false
	for _, row in ipairs(rows) do if row.enabled == "1" then active = true end end
	if not active then return true end
	local ok, out = run({"nft", "-j", "list", "table", "inet", "openclash_guard"})
	local live, saved = decode(out), decode(fs.readfile("/etc/openclash/device-guard.json"))
	return ok and live ~= nil and saved ~= nil and equal(policy.canonical_table(live), policy.canonical_table(saved))
end

function M.generate(path)
	local rows = M.rows()
	if #rows == 0 and not (fs.readfile(path) or ""):find("openclash-device-", 1, true) then
		-- Do not even parse/rewrite YAML on the ordinary startup path.
		return true
	end
	local valid, err = policy.validate(rows, M.lans(), nil, true)
	if not valid then return false, err end
	local ports_ok, port_error = M.validate_ports(valid)
	if not ports_ok then return false, port_error end
	for _, row in ipairs(valid) do
		if row.enabled == "1" and not M.supported() then return false, "Device egress requires firewall4 / nftables" end
	end
	local ok, _, details = ruby("generate", path, valid)
	return ok, details
end

-- A socket must belong to this core, for BOTH TCP and UDP. Listening on a
-- different process's port is not evidence that the core loaded this inbound.
function M.listener_sockets(pid)
	local owned = {}
	for fd in fs.glob("/proc/" .. pid .. "/fd/*") do
		local inode = (fs.readlink(fd) or ""):match("^socket:%[(%d+)%]$")
		if inode then owned[inode] = true end
	end
	local found = {}
	-- Go may bind an IPv4-capable dual-stack socket in tcp6/udp6 even when
	-- the YAML listener address is 0.0.0.0.
	for _, socket_table in ipairs({"tcp", "udp", "tcp6", "udp6"}) do
		local protocol = socket_table:gsub("6$", "")
		for line in (fs.readfile("/proc/net/" .. socket_table) or ""):gmatch("[^\n]+") do
			local fields = {}
			for value in line:gmatch("%S+") do fields[#fields + 1] = value end
			local port = fields[2] and fields[2]:match(":(%x+)$")
			if port and owned[fields[10]] and (protocol == "udp" or fields[4] == "0A") then
				port = tonumber(port, 16)
				found[port] = found[port] or {}
				found[port][protocol] = true
			end
		end
	end
	return found
end

function M.listener_loaded(pid, row, sockets)
	local found = (sockets or M.listener_sockets(pid))[row.port] or {}
	if found.tcp and found.udp then return true end
	-- Explicit opt-in fallback for kernels exposing sockets differently.
	local hook = "/etc/openclash/custom/device_egress_listener_probe"
	if fs.access(hook, "x") then return run({hook, pid, row.mac, row.port, row.target}) end
	return false
end

function M.record_loaded()
	if #M.rows() == 0 then fs.unlink("/tmp/openclash-device-loaded.json"); return end
	local pid = M.pid()
	if not pid then return end
	local _, runtime = M.config_paths()
	if not runtime then return end
	local ok, listeners = ruby("inspect", runtime, {})
	if not ok then return end
	fs.writefile("/tmp/openclash-device-loaded.json", json.stringify({pid = pid, rows = M.rows(), listeners = listeners}))
end

function M.runtime()
	local rows = M.rows()
	local active = false
	for _, row in ipairs(rows) do if row.enabled == "1" then active = true end end
	-- Remove only this feature's runtime objects, atomically with replacements.
	local _, output = run({"nft", "-a", "list", "table", "inet", "fw4"})
	local lines, chain = {}, nil
	for line in output:gmatch("[^\n]+") do
		chain = line:match("^%s*chain ([%w_]+) {") or chain
		if line:find('comment "OpenClash Device Egress"', 1, true) and chain then
			local handle = line:match("# handle (%d+)")
			if handle then lines[#lines + 1] = "delete rule inet fw4 " .. chain .. " handle " .. handle end
		end
	end
	for _, name in ipairs({"openclash_device_prerouting", "openclash_device_dns"}) do
		if output:find("chain " .. name .. " {", 1, true) then
			lines[#lines + 1] = "flush chain inet fw4 " .. name
			lines[#lines + 1] = "delete chain inet fw4 " .. name
		end
	end
	if output:find("set openclash_bound_macs {", 1, true) then lines[#lines + 1] = "delete set inet fw4 openclash_bound_macs" end
	if active then
		local valid, err = policy.validate(rows, M.lans(), nil, true)
		if not valid then return false, err end
		local chains = {}
		for name in output:gmatch("chain (openclash[%w_]*) {") do
			if name ~= "openclash_device_prerouting" and name ~= "openclash_device_dns" then chains[#chains + 1] = name end
		end
		local uci = cursor()
		local dns = uci:get("openclash", "config", "enable_redirect_dns") or "1"
		local dns_port = dns == "1" and (uci:get("dhcp", "@dnsmasq[0]", "port") or 53) or (uci:get("openclash", "config", "dns_port") or 7874)
		local rules = assert(policy.render_runtime(valid, chains, dns ~= "0", dns_port))
		lines[#lines + 1] = rules
		-- Own routing namespace. Never flush an unrelated route or rule.
		local ok = run({"ip", "route", "replace", "local", "default", "dev", "lo", "table", policy.route_table})
		if not ok then return false, "Cannot install device egress route" end
		run({"ip", "rule", "del", "pref", policy.route_priority, "fwmark", policy.mark, "lookup", policy.route_table})
		ok = run({"ip", "rule", "add", "pref", policy.route_priority, "fwmark", policy.mark, "lookup", policy.route_table})
		if not ok then return false, "Cannot install device egress rule" end
		fs.writefile("/var/run/openclash-device-route", "1\n")
	end
	if #lines == 0 then return true end
	local path = temp(table.concat(lines, "\n") .. "\n")
	local ok, _, err = run({"nft", "-f", path})
	fs.unlink(path)
	if ok then
		run({"nft", "flush", "flowtable", "inet", "fw4", "ft"})
		if not active then
			run({"ip", "rule", "del", "pref", policy.route_priority, "fwmark", policy.mark, "lookup", policy.route_table})
			run({"ip", "route", "del", "local", "default", "dev", "lo", "table", policy.route_table})
			fs.unlink("/var/run/openclash-device-route")
		end
	end
	return ok, err
end

function M.bound_set()
	local macs = {}
	for _, row in ipairs(M.rows()) do
		if row.enabled == "1" then
			if not policy.mac(row.mac) then return false end
			macs[#macs + 1] = row.mac:upper()
		end
	end
	if #macs == 0 then return true end
	return run({"nft", "-f", "-"}, "add set inet fw4 openclash_bound_macs { type ether_addr; elements = { " .. table.concat(macs, ", ") .. " }; }\n")
end

function M.status()
	local rows, pid = M.rows(), M.pid()
	local devices, by_mac = M.devices(), {}
	for _, device in ipairs(devices) do by_mac[device.mac] = device end
	local targets, target_error = M.targets(pid ~= nil)
	local by_target = {}
	for _, target in ipairs(targets) do by_target[target.name] = target end
	local guard = M.protected(rows)
	local loaded = decode(fs.readfile("/tmp/openclash-device-loaded.json")) or {}
	local loaded_by_mac, inbounds = {}, {}
	if loaded.pid == pid then
		for _, row in ipairs(loaded.rows or {}) do loaded_by_mac[row.mac] = row end
		for _, listener in ipairs(loaded.listeners or {}) do inbounds[listener.name] = listener end
	end
	local transitioning = sys.call("pgrep -f '[/]etc/init.d/openclash (start|stop|restart)( |$)' >/dev/null 2>&1") == 0
	local sockets = pid and M.listener_sockets(pid) or {}
	for _, row in ipairs(rows) do
		local target, device = by_target[row.target], by_mac[(row.mac or ""):upper()] or {}
		row.online, row.fixed, row.current_ip = device.online or false, device.fixed or false, device.current_ip
		row.kind, row.current = target and target.kind, target and target.current
		row.random_mac = policy.mac(row.mac) and math.floor(tonumber(row.mac:sub(1, 2), 16) / 2) % 2 == 1
		local recorded = loaded_by_mac[row.mac]
		local inbound = inbounds["openclash-device-" .. (row.mac or ""):gsub(":", ""):lower()]
		if row.enabled ~= "1" then row.state = "paused"
		elseif not guard then row.state = "unprotected"
		elseif not pid then row.state = "stopped"
		elseif transitioning then row.state = "starting"
		elseif not target then row.state = "missing"
		elseif target.unsafe then row.state = "direct"
		elseif not recorded or recorded.target ~= row.target or recorded.ip ~= row.ip or recorded.port ~= row.port or not inbound or inbound.proxy ~= row.target or tonumber(inbound.port) ~= row.port or not M.listener_loaded(pid, row, sockets) then row.state = "inbound"
		elseif row.current_ip and row.current_ip ~= row.ip then row.state = "ip_changed"
		else row.state = "active" end
	end
	local uci = cursor()
	local raw = M.config_paths()
	return {rows = rows, devices = devices, targets = targets, target_error = target_error,
		guard = guard, supported = M.supported(), running = pid ~= nil,
		config = raw and raw:match("([^/]+)$") or "", updated = os.date("%H:%M:%S"),
		offloading = uci:get("firewall", "@defaults[0]", "flow_offloading") == "1" or uci:get("firewall", "@defaults[0]", "flow_offloading_hw") == "1"}
end

local function apply_core()
	if not M.pid() then return true end
	local _, runtime = M.config_paths()
	local ok = runtime and M.generate(runtime)
	if ok then ok = M.runtime() end
	if ok then ok = M.api("PUT", "/configs?force=true", {path = runtime}) end
	if ok then M.record_loaded(); return true end
	-- Isolated fallback: ordinary OpenClash startup regenerates the full config.
	-- The persistent guard and early chain exemptions remain in force.
	fs.unlink("/tmp/openclash-device-loaded.json")
	return run({"/etc/init.d/openclash", "restart"})
end

function M.validate_ports(rows)
	local uci = cursor()
	local active = false
	for i, row in ipairs(rows) do
		if row.enabled == "1" then
			active = true
			for _, key in ipairs({"proxy_port", "tproxy_port", "cn_port", "http_port", "socks_port", "mixed_port", "dns_port"}) do
				if tonumber(uci:get("openclash", "config", key)) == 7900 + i then
					return false, "Device listener port conflicts with OpenClash: " .. (7900 + i)
				end
			end
		end
	end
	if active then return M.route_available() end
	return true
end

function M.route_available()
	local ok, rules = run({"ip", "-4", "rule", "show"})
	if not ok then return false, "Cannot inspect device egress routing namespace" end
	for line in rules:gmatch("[^\n]+") do
		local priority, mark, lookup = line:match("^(%d+):"), line:match("fwmark%s+(%S+)"), line:match("lookup%s+(%S+)")
		if priority == policy.route_priority or mark == policy.mark then
			if priority ~= policy.route_priority or mark ~= policy.mark or lookup ~= policy.route_table then return false, "Device egress routing namespace is already in use" end
		end
	end
	-- Dump all tables: iproute2 versions disagree on the error for an absent
	-- table (including the ambiguous "Dump terminated"). Numeric names keep a
	-- local rt_tables alias from concealing a collision in our reserved table.
	local routes_ok, routes = run({"ip", "-4", "-N", "route", "show", "table", "all"})
	local names = {policy.route_table}
	if not routes_ok then
		-- iproute2 before 5.4 (e.g. 5.0 on QWRT) lacks -N: match rt_tables aliases instead.
		routes_ok, routes = run({"ip", "-4", "route", "show", "table", "all"})
		for id, name in (fs.readfile("/etc/iproute2/rt_tables") or ""):gmatch("(%d+)%s+(%S+)") do
			if id == policy.route_table then names[#names + 1] = name end
		end
	end
	if not routes_ok then return false, "Cannot inspect device egress routing table" end
	for line in routes:gmatch("[^\n]+") do
		for _, name in ipairs(names) do
			local first, last = (line .. " "):find(" table " .. name .. " ", 1, true)
			if first then
				line = line:sub(1, first - 1) .. line:sub(last)
				local kind, destination, device = line:match("^(%S+)%s+(%S+)%s+dev%s+(%S+)")
				if (kind ~= "local" and kind ~= "2") or (destination ~= "default" and destination ~= "0.0.0.0/0") or device ~= "lo" then return false, "Device egress routing table is already in use" end
				break
			end
		end
	end
	return true
end

function M.ip_owner(ip, mac)
	for _, device in ipairs(M.devices()) do
		if device.ip == ip and device.mac ~= mac:upper() then return device.name end
	end
end

local function mutate(request)
	if not M.supported() then return nil, "This firmware does not support device egress (requires firewall4 / nftables)." end
	local uci, rows = cursor(), M.rows()
	local op = request.operation
	if op == "reapply" then
		local ok, details = M.install_guard(rows)
		if not ok then return nil, "Failed to write protection rules; nothing was saved.", details end
		if not apply_core() then return nil, "Core reload failed. Devices remain blocked." end
		return M.status()
	end
	if op == "latency" then
		local selected
		for _, row in ipairs(rows) do if row.id == request.id then selected = row end end
		if not selected then return nil, "Invalid device settings." end
		local encoded = selected.target:gsub("([^%w%-._~])", function(c) return string.format("%%%02X", c:byte()) end)
		local ok, out = M.api("GET", "/proxies/" .. encoded .. "/delay?timeout=5000&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204")
		local result = decode(out)
		return {delay = ok and result and result.delay or false}
	end
	if op == "fix" then
		local row = request.device or {}
		local valid, err, arg = policy.validate({{enabled = "0", name = row.name, mac = row.mac, ip = row.ip, target = "REJECT"}}, M.lans(), nil, true)
		if not valid then return nil, err, nil, arg end
		local owner = M.ip_owner(row.ip, row.mac)
		if owner then return nil, "This IP is already used by %s.", nil, owner end
		local id, conflict
		uci:foreach("dhcp", "host", function(s)
			local macs = type(s.mac) == "table" and table.concat(s.mac, " ") or s.mac or ""
			for mac in macs:gmatch("%S+") do if mac:upper() == valid[1].mac then id = s['.name'] end end
			if s.ip == row.ip and not macs:upper():find(valid[1].mac, 1, true) then conflict = s.name or s.mac or s.ip end
		end)
		if conflict then return nil, "This IP is already used by %s.", nil, conflict end
		local previous = fs.readfile("/etc/config/dhcp")
		id = id or uci:add("dhcp", "host")
		uci:set("dhcp", id, "name", row.name); uci:set("dhcp", id, "mac", valid[1].mac); uci:set("dhcp", id, "ip", row.ip)
		if not uci:commit("dhcp") then uci:revert("dhcp"); return nil, "Unable to save DHCP reservation." end
		if not run({"/etc/init.d/dnsmasq", "reload"}) then
			if previous then fs.writefile("/etc/config/dhcp", previous); run({"/etc/init.d/dnsmasq", "reload"}) end
			return nil, "Unable to reload dnsmasq."
		end
		return {fixed = true}
	end
	local index
	for i, row in ipairs(rows) do if row.id == request.id then index = i end end
	if op == "save" then
		local device = request.device or {}
		local replacement = {id = index and rows[index].id, enabled = index and rows[index].enabled or "1", name = device.name, mac = device.mac, ip = device.ip, target = device.target}
		if request.id and not index then return nil, "Invalid device settings." end
		rows[index or #rows + 1] = replacement
	elseif op == "pause" or op == "resume" or op == "delete" then
		if not index then return nil, "Invalid device settings." end
		if op == "delete" then table.remove(rows, index) else rows[index].enabled = op == "pause" and "0" or "1" end
	else return nil, "Invalid device settings." end
	local targets, target_error = M.targets(M.pid() ~= nil)
	if (op == "save" or op == "resume") and target_error then return nil, "Unable to read the current configuration.", target_error end
	-- Existing missing targets must not prevent pausing/deleting another device.
	local valid, err, arg = policy.validate(rows, M.lans(), nil, true)
	if not valid then return nil, err, nil, arg end
	if op == "save" or op == "resume" then
		local selected = valid[index or #valid]
		local checked
		checked, err, arg = policy.validate({selected}, M.lans(), targets)
		if not checked then return nil, err, nil, arg end
		local owner = M.ip_owner(selected.ip, selected.mac)
		if owner then return nil, "This IP is already used by %s.", nil, owner end
	end
	-- Check processed YAML ports before saving/resuming. Pausing and deleting
	-- must remain possible even when the selected configuration is broken.
	if op == "save" or op == "resume" then
		local ports_ok, port_error = M.validate_ports(valid)
		if not ports_ok then return nil, "Unable to generate device listeners.", port_error end
		local raw, runtime = M.config_paths()
		local probe = temp(fs.readfile(M.pid() and runtime or raw) or "")
		local generated, _, details = ruby("generate", probe, valid)
		fs.unlink(probe)
		if not generated then return nil, "Unable to generate device listeners.", details end
	end
	local installed, nft_output = M.install_guard(valid)
	if not installed then return nil, "Failed to write protection rules; nothing was saved.", nft_output end
	local old = M.rows(uci)
	local remove = {}
	uci:foreach("openclash", "device_egress", function(s) remove[#remove + 1] = s['.name'] end)
	for _, id in ipairs(remove) do uci:delete("openclash", id) end
	for _, row in ipairs(valid) do
		local id = row.id or uci:add("openclash", "device_egress")
		if row.id then uci:section("openclash", "device_egress", id, {}) end
		for _, key in ipairs({"enabled", "name", "mac", "ip", "target"}) do uci:set("openclash", id, key, row[key]) end
	end
	if not uci:commit("openclash") then
		uci:revert("openclash")
		M.install_guard(old)
		return nil, "Unable to save device settings."
	end
	if not apply_core() then return nil, "Core reload failed. Devices remain blocked." end
	return M.status()
end

function M.mutate(request)
	local lock = nixio.open("/var/lock/openclash-device-egress.lock", "w", "600")
	if not lock or not lock:lock("tlock") then if lock then lock:close() end; return nil, "Another operation is in progress." end
	local ok, result, err, details, arg = pcall(mutate, request)
	lock:lock("ulock"); lock:close()
	if not ok then return nil, "Unable to apply device egress.", tostring(result) end
	return result, err, details, arg
end

return M
