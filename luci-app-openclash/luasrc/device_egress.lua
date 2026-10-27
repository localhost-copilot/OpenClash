-- Pure policy/validation code. No shell, UCI or LuCI dependencies.
local M = {}
M.mark = "0x40000"
M.route_table = "789"
M.route_priority = "1886"

function M.ipv4(value)
	if type(value) ~= "string" then return nil end
	local parts = {value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")}
	if #parts ~= 4 then return nil end
	local result = 0
	for _, part in ipairs(parts) do
		if #part > 3 or tonumber(part) > 255 or (#part > 1 and part:sub(1, 1) == "0") then return nil end
		result = result * 256 + tonumber(part)
	end
	return result
end

function M.network(address, prefix)
	local value = M.ipv4(address)
	prefix = tonumber(prefix)
	if not value or not prefix or prefix < 1 or prefix > 32 or prefix % 1 ~= 0 then return nil end
	local block = 2 ^ (32 - prefix)
	local base = math.floor(value / block) * block
	local n, octets = base, {}
	for i = 4, 1, -1 do octets[i] = n % 256; n = math.floor(n / 256) end
	return table.concat(octets, ".") .. "/" .. prefix, base, block
end

function M.mac(value)
	return type(value) == "string" and value:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
		and value:sub(1, 2):lower() ~= "ff" and tonumber(value:sub(1, 2), 16) % 2 == 0
		and value ~= "00:00:00:00:00:00"
end

local function text(value, limit)
	return type(value) == "string" and #value > 0 and #value <= limit and not value:find("[%z\1-\31\127]")
end

-- LAN entries are actual connected LANs, never all RFC1918 ranges or WANs.
function M.validate(rows, lans, targets, allow_missing)
	if type(rows) ~= "table" or #rows > 32 then return nil, "A maximum of 32 devices is allowed." end
	local result, macs, ips = {}, {}, {}
	for i, row in ipairs(rows) do
		if type(row) ~= "table" or (row.enabled ~= "0" and row.enabled ~= "1") then return nil, "Invalid device settings." end
		if not M.mac(row.mac) then return nil, "Invalid MAC address format." end
		local mac = row.mac:upper()
		if macs[mac] then return nil, "This device already has an egress." end
		if ips[row.ip] then return nil, "This IP is already used by %s.", ips[row.ip] end
		if not text(row.name, 128) then return nil, "Invalid device name." end
		local value, inside = M.ipv4(row.ip), false
		for _, lan in ipairs(lans or {}) do
			if row.ip == lan.address then return nil, "The router's own address cannot be used." end
			local _, base, block = M.network(lan.address, lan.prefix)
			if value and base and value > base and value < base + block - 1 then inside = true end
		end
		if not inside then
			local lan = (lans or {})[1] or {}
			return nil, "IP is outside the LAN subnet %s.", M.network(lan.address, lan.prefix) or "?"
		end
		if not text(row.target, 256) then return nil, "Please select an egress." end
		if targets and not allow_missing then
			local found
			for _, target in ipairs(targets) do if target.name == row.target then found = target; break end end
			if not found then return nil, "Egress is missing from the current configuration." end
			if found.unsafe then return nil, "This group contains DIRECT and may connect directly; it cannot be used for device egress." end
		end
		macs[mac], ips[row.ip] = true, row.name
		result[i] = {id = row.id, enabled = row.enabled, name = row.name, mac = mac, ip = row.ip, target = row.target, port = 7900 + i}
	end
	return result
end

local function lan_sets(lans, lans6)
	local v4, v6 = {}, {"fe80::/10", "ff02::/16"}
	for _, lan in ipairs(lans or {}) do
		local cidr = M.network(lan.address, lan.prefix)
		if not cidr then return nil, "Invalid LAN subnet" end
		v4[#v4 + 1] = cidr
	end
	if #v4 == 0 then return nil, "LAN subnet unavailable" end
	for _, cidr in ipairs(lans6 or {}) do
		-- Only numeric kernel-provided IPv6 CIDRs can enter nft source.
		local address, prefix = cidr:match("^([%x:]+)/(%d+)$")
		if not address or not address:find(":", 1, true) or tonumber(prefix) < 1 or tonumber(prefix) > 128 then return nil, "Invalid IPv6 LAN subnet" end
		v6[#v6 + 1] = cidr
	end
	return v4, v6
end

function M.emergency()
	-- Deliberately independent of UCI, Lua discovery and proxy availability.
	return [[add table inet openclash_guard
delete table inet openclash_guard
table inet openclash_guard {
 chain prerouting {
  type filter hook prerouting priority -300; policy drop;
  iifname "lo" accept
  fib daddr type local accept
  fib daddr oifname "br-lan" accept
 }
 chain forward {
  type filter hook forward priority -10; policy drop;
  iifname "br-lan" oifname "br-lan" accept
 }
 chain output {
  type filter hook output priority -10; policy drop;
  oifname { "lo", "br-lan" } accept
 }
}
]]
end

function M.render_guard(rows, lans, lans6, ct_fallback)
	local valid, err = M.validate(rows, lans, nil, true)
	if not valid then return nil, err end
	local active = {}
	for _, row in ipairs(valid) do if row.enabled == "1" then active[#active + 1] = row end end
	local lines = {"add table inet openclash_guard", "delete table inet openclash_guard"}
	if #active == 0 then return table.concat(lines, "\n") .. "\n" end
	for _, row in ipairs(active) do lines[#lines + 1] = "# binding " .. row.mac .. " " .. row.ip end
	local v4, v6 = lan_sets(lans, lans6)
	if not v4 then return nil, v6 end
	lines[#lines + 1] = "table inet openclash_guard {"
	lines[#lines + 1] = " set lan4 { type ipv4_addr; flags interval; auto-merge; elements = { " .. table.concat(v4, ", ") .. " }; }"
	lines[#lines + 1] = " set lan6 { type ipv6_addr; flags interval; auto-merge;" .. (#v6 > 0 and " elements = { " .. table.concat(v6, ", ") .. " };" or "") .. " }"
	local macs = {}
	for _, row in ipairs(active) do macs[#macs + 1] = row.mac end
	lines[#lines + 1] = " set bound { type ether_addr; elements = { " .. table.concat(macs, ", ") .. " }; }"
	lines[#lines + 1] = " chain prerouting {"
	lines[#lines + 1] = "  type filter hook prerouting priority -160; policy accept;"
	lines[#lines + 1] = "  ether saddr @bound ip daddr 255.255.255.255 udp sport 68 udp dport 67 return"
	-- Return LAN destinations before the source-IP check, including local IPv6.
	lines[#lines + 1] = "  ip daddr @lan4 return"
	lines[#lines + 1] = "  ip6 daddr @lan6 return"
	if ct_fallback then lines[#lines + 1] = "  ether saddr @bound ct mark set ct mark | 0x40000000" end
	for _, row in ipairs(active) do
		lines[#lines + 1] = "  ether saddr " .. row.mac .. " ip saddr != " .. row.ip .. " counter drop"
	end
	lines[#lines + 1] = " }"
	-- Fail closed even while ordinary OpenClash chains are being rebuilt. Only
	-- the dedicated runtime hook (-151) can admit a bound packet before -149.
	-- This prevents an ordinary TUN/redirect listener from accepting new bindings
	-- during the guard-first save transaction or after partial runtime failure.
	lines[#lines + 1] = " chain interception_check {"
	lines[#lines + 1] = "  type filter hook prerouting priority -149; policy accept;"
	lines[#lines + 1] = "  ether saddr @bound ip daddr 255.255.255.255 udp sport 68 udp dport 67 return"
	lines[#lines + 1] = "  ip daddr @lan4 return"
	lines[#lines + 1] = "  ip6 daddr @lan6 return"
	lines[#lines + 1] = "  ether saddr @bound meta mark != " .. M.mark .. " counter drop"
	lines[#lines + 1] = " }"
	lines[#lines + 1] = " chain forward {"
	lines[#lines + 1] = "  type filter hook forward priority -10; policy accept;"
	lines[#lines + 1] = "  ip daddr @lan4 return"
	lines[#lines + 1] = "  ip6 daddr @lan6 return"
	lines[#lines + 1] = ct_fallback and "  ct direction original ct mark & 0x40000000 != 0 counter drop" or "  ether saddr @bound counter drop"
	lines[#lines + 1] = " }"
	lines[#lines + 1] = "}"
	return table.concat(lines, "\n") .. "\n"
end

-- Called only after every ordinary interception/lan_ac rule has been installed.
-- Inserting last puts these exemptions before even lan_ac's position-0 rules.
function M.render_runtime(rows, chains, dns_hijack, dns_port)
	local active, lines, macs = {}, {}, {}
	for i, row in ipairs(rows) do
		if row.enabled == "1" then
			if not M.mac(row.mac) or not M.ipv4(row.ip) then return nil, "Invalid binding" end
			active[#active + 1] = {mac = row.mac, ip = row.ip, port = 7900 + i}
			macs[#macs + 1] = row.mac
		end
	end
	if #active == 0 then return "" end
	lines[#lines + 1] = "add set inet fw4 openclash_bound_macs { type ether_addr; elements = { " .. table.concat(macs, ", ") .. " }; }"
	for _, chain in ipairs(chains) do
		if chain == "openclash" or chain == "openclash_mangle" or chain == "openclash_v6" or chain == "openclash_mangle_v6" then
			lines[#lines + 1] = 'insert rule inet fw4 ' .. chain .. ' ether saddr @openclash_bound_macs counter return comment "OpenClash Device Egress"'
		end
	end
	-- Before the normal mangle hook (-150), after guard's source check (-160).
	lines[#lines + 1] = "add chain inet fw4 openclash_device_prerouting { type filter hook prerouting priority -151; policy accept; }"
	lines[#lines + 1] = 'insert rule inet fw4 input meta mark ' .. M.mark .. ' counter accept comment "OpenClash Device Egress"'
	if dns_hijack then
		lines[#lines + 1] = "add rule inet fw4 openclash_device_prerouting ether saddr @openclash_bound_macs meta l4proto { tcp, udp } th dport 53 meta mark set " .. M.mark .. " return"
		assert(tonumber(dns_port) and tonumber(dns_port) > 0 and tonumber(dns_port) <= 65535, "Invalid DNS port")
		-- Bypass lan_ac DNS exclusions too; runs ahead of the ordinary dstnat hook.
		lines[#lines + 1] = "add chain inet fw4 openclash_device_dns { type nat hook prerouting priority -101; policy accept; }"
		lines[#lines + 1] = "add rule inet fw4 openclash_device_dns ether saddr @openclash_bound_macs meta l4proto { tcp, udp } th dport 53 redirect to :" .. tonumber(dns_port)
	end
	lines[#lines + 1] = "add rule inet fw4 openclash_device_prerouting ip daddr @localnetwork return"
	for _, row in ipairs(active) do
		lines[#lines + 1] = "add rule inet fw4 openclash_device_prerouting ether saddr " .. row.mac .. " ip saddr " .. row.ip .. " meta l4proto { tcp, udp } tproxy ip to :" .. row.port .. " meta mark set " .. M.mark .. " counter accept"
	end
	return table.concat(lines, "\n") .. "\n"
end

-- nft JSON structural comparison ignores handles, counters and set ordering.
-- Comparing the whole table detects stale addresses and missing/altered rules.
function M.canonical_table(document)
	local items = {}
	local function stable(value)
		if type(value) ~= "table" then return type(value) .. ":" .. tostring(value) end
		local keys, values = {}, {}
		for key in pairs(value) do keys[#keys + 1] = key end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		for _, key in ipairs(keys) do values[#values + 1] = stable(key) .. "=" .. stable(value[key]) end
		return "{" .. table.concat(values, ",") .. "}"
	end
	local function clean(value)
		if type(value) ~= "table" then return value end
		local out = {}
		for k, v in pairs(value) do
			if k ~= "handle" and k ~= "packets" and k ~= "bytes" and k ~= "metainfo" then out[k] = clean(v) end
		end
		if out.elem then table.sort(out.elem, function(a, b) return stable(a) < stable(b) end) end
		return out
	end
	for _, item in ipairs((document or {}).nftables or {}) do
		if not item.metainfo then items[#items + 1] = clean(item) end
	end
	return items
end

return M
