-- Integration boundaries with a fake UCI store and local command adapter.
-- No OpenWrt processes, network hosts or real configuration are contacted.
local policy = dofile("luci-app-openclash/luasrc/device_egress.lua")
local files, objects, events, sections, saved, options, sequence, commits
local guard_ok, commit_ok, ruby_calls
local route_dump, route_ok, numeric_ok
local nft_document, transitioning = nil, false
local function clone(value)
	if type(value) ~= "table" then return value end
	local out = {}; for k, v in pairs(value) do out[k] = clone(v) end; return out
end
local function encode(value)
	sequence = sequence + 1; local key = "json" .. sequence; objects[key] = clone(value); return key
end
local store = {}
function store:foreach(package, kind, fn)
	if package == "openclash" and kind == "device_egress" then
		for _, section in ipairs(clone(sections)) do fn(section) end
	end
end
function store:get(package, section, key)
	if key == "config_path" then return "/etc/openclash/config/test.yaml" end
	return options[key]
end
function store:add(package, kind)
	local id = "new" .. (#sections + 1)
	sections[#sections + 1] = {['.name'] = id}; return id
end
function store:delete(package, id)
	for i, section in ipairs(sections) do if section['.name'] == id then table.remove(sections, i); break end end
end
function store:section(package, kind, id)
	sections[#sections + 1] = {['.name'] = id}
end
function store:set(package, id, key, value)
	events[#events + 1] = "set"
	for _, section in ipairs(sections) do if section['.name'] == id then section[key] = value end end
end
function store:commit(package)
	events[#events + 1] = "commit"; commits = commits + 1
	if commit_ok then saved = clone(sections) end
	return commit_ok
end
function store:revert() sections = clone(saved) end
package.preload['luci.device_egress'] = function() return policy end
package.preload['luci.model.uci'] = function() return {cursor = function() return store end} end
package.preload['luci.jsonc'] = function() return {stringify = encode, parse = function(value) return clone(objects[value]) end} end
package.preload['luci.util'] = function() return {shellquote = function(value) return "'" .. value:gsub("'", "'\\''") .. "'" end} end
package.preload['nixio.fs'] = function() return {
	readfile = function(path) return files[path] end,
	writefile = function(path, content) files[path] = content; return true end,
	unlink = function(path) files[path] = nil end,
	access = function(path) return files[path] ~= nil end,
	readlink = function(path) return files[path] end,
	glob = function(pattern)
		local entries, prefix = {}, pattern:sub(1, -2)
		for path in pairs(files) do if path:sub(1, #prefix) == prefix then entries[#entries + 1] = path end end
		local index = 0; return function() index = index + 1; return entries[index] end
	end
} end
package.preload['nixio'] = function() return {
	open = function(_, _, mode)
		assert(mode == "600", "nixio requires an octal mode string")
		return {lock = function() return true end, close = function() end}
	end
} end
package.preload['luci.sys'] = function() return {
	call = function(command)
		if command:find("'ip' '-4' '-N' 'route'", 1, true) then
			if not numeric_ok then return 255 end
			files[command:match(" >'([^']+)'")] = route_dump
			return route_ok and 0 or 1
		end
		if command:find("'ip' '-4' 'route'", 1, true) then
			files[command:match(" >'([^']+)'")] = route_dump
			return route_ok and 0 or 1
		end
		if command:find("pgrep", 1, true) then return transitioning and 0 or 1 end
		if command:match("^'nft'") and command:find("'-j'", 1, true) and nft_document then files[command:match(" >'([^']+)'")] = encode(nft_document) end
		if command:match("^'ruby'") then
			ruby_calls = ruby_calls + 1
			if command:find("'catalogue'", 1, true) then
				local output = command:match(" >'([^']+)'")
				files[output] = encode({{name = "safe", kind = "node", unsafe = false}})
			end
		end
		return 0
	end,
	exec = function(command)
		if command:match("^mktemp ") then
			sequence = sequence + 1
			local path = "/tmp/openclash-egress.fake" .. sequence
			files[path] = ""
			return path .. "\n"
		end
		return ""
	end
} end
local service = dofile("luci-app-openclash/luasrc/device_egress_service.lua")
local actual_targets = service.targets
local actual_status, actual_probe, actual_protected = service.status, service.listener_loaded, service.protected
service.lans = function() return {{address = "192.168.50.1", prefix = 24}}, {} end
service.supported = function() return true end
service.pid = function() return nil end
service.targets = function() return {{name = "safe", unsafe = false}, {name = "bad", unsafe = true}} end
service.install_guard = function(rows)
	events[#events + 1] = "guard:" .. #rows
	return guard_ok, "nft rejected candidate"
end
service.status = function() return {rows = service.rows()} end

local function row(changes)
	local value = {enabled = "1", name = "Device", mac = "AA:BB:CC:DD:EE:01", ip = "192.168.50.20", target = "safe"}
	for k, v in pairs(changes or {}) do value[k] = v end
	return value
end
local function reset(initial)
	files, objects, events, sections, options = {}, {}, {}, {}, {}
	sequence, commits, ruby_calls = 0, 0, 0
	guard_ok, commit_ok = true, true
	route_dump, route_ok, numeric_ok = "", true, true
	nft_document, transitioning = nil, false
	for i, item in ipairs(initial or {}) do sections[i] = clone(item); sections[i]['.name'] = "device" .. i end
	saved = clone(sections)
	files['/etc/openclash/config/test.yaml'] = "proxies: []"
end
local passed = 0
local function test(name, fn)
	reset(); local ok, err = pcall(fn)
	assert(ok, name .. ": " .. tostring(err)); passed = passed + 1
end
test("routing collision check accepts absent tables and rejects conflicts or failed dumps", function()
	route_dump = "default via 10.0.0.1 dev eth0\nlocal default dev lo table 354 scope host\n"
	assert(service.route_available())
	route_dump = route_dump .. "local default dev lo table 789 scope host\n"
	assert(service.route_available())
	route_dump = "2 default dev lo table 789 scope 254\n"
	assert(service.route_available())
	route_dump = route_dump .. "10.0.0.0/24 dev eth0 table 789\n"
	local ok, err = service.route_available()
	assert(not ok and err == "Device egress routing table is already in use")
	route_dump, route_ok = "", false
	ok, err = service.route_available()
	assert(not ok and err == "Cannot inspect device egress routing table")
end)
test("routing collision check falls back for iproute2 without -N and honours rt_tables aliases", function()
	numeric_ok = false
	route_dump = "local default dev lo table 789 scope host\n"
	assert(service.route_available())
	files["/etc/iproute2/rt_tables"] = "255\tlocal\n789\tegress\n"
	route_dump = "10.0.0.0/24 dev eth0 table egress\n"
	local ok, err = service.route_available()
	assert(not ok and err == "Device egress routing table is already in use")
	route_ok = false
	ok, err = service.route_available()
	assert(not ok and err == "Cannot inspect device egress routing table")
end)
test("nft failure aborts without saving any UCI mutation", function()
	guard_ok = false
	local result, err, details = service.mutate({operation = "save", device = row()})
	assert(not result and err == "Failed to write protection rules; nothing was saved." and details == "nft rejected candidate")
	assert(commits == 0 and #sections == 0 and events[1] == "guard:1" and #events == 1)
end)
test("successful save installs guard before UCI commit", function()
	local result, err = service.mutate({operation = "save", device = row()})
	assert(result, tostring(err)); assert(commits == 1 and #saved == 1)
	assert(events[1] == "guard:1" and events[#events] == "commit")
	assert(saved[1].target == "safe" and saved[1].mac == "AA:BB:CC:DD:EE:01")
end)
test("failed UCI commit restores previous guard and old configuration", function()
	reset({row()}); commit_ok = false
	local result, err = service.mutate({operation = "save", id = "device1", device = row({target = "safe", ip = "192.168.50.21"})})
	assert(not result and err == "Unable to save device settings.")
	assert(sections[1].ip == "192.168.50.20")
	assert(events[1] == "guard:1" and events[#events] == "guard:1")
end)
test("invalid UCI and direct groups never reach guard or commit", function()
	local result, err = service.mutate({operation = "save", device = row({ip = "192.168.50.1"})})
	assert(not result and err == "The router's own address cannot be used.")
	result, err = service.mutate({operation = "save", device = row({target = "bad"})})
	assert(not result and err:find("contains DIRECT", 1, true))
	assert(commits == 0 and #events == 0)
end)
test("configured OpenClash port collision aborts before policy changes", function()
	options.tproxy_port = "7901"
	local result, err = service.mutate({operation = "save", device = row()})
	assert(not result and err == "Unable to generate device listeners.")
	assert(commits == 0 and #events == 0)
end)
test("missing targets do not prevent pausing or deleting existing bindings", function()
	reset({row({target = "missing"})})
	local result, err = service.mutate({operation = "pause", id = "device1"})
	assert(result, tostring(err)); assert(saved[1].enabled == "0")
	result, err = service.mutate({operation = "delete", id = "device1"})
	assert(result, tostring(err)); assert(#saved == 0)
end)
test("broken configuration does not prevent releasing an existing binding", function()
	reset({row()})
	files['/etc/openclash/config/test.yaml'] = "broken: ["
	local result, err = service.mutate({operation = "delete", id = "device1"})
	assert(result, tostring(err)); assert(#saved == 0 and ruby_calls == 0)
end)
test("IP occupied by an unbound MAC is rejected before saving", function()
	local previous = service.devices
	service.devices = function() return {{name = "Other device", mac = "AA:BB:CC:DD:EE:02", ip = "192.168.50.20"}} end
	local result, err, _, owner = service.mutate({operation = "save", device = row()})
	service.devices = previous
	assert(not result and err == "This IP is already used by %s." and owner == "Other device")
	assert(#events == 0 and commits == 0)
end)
test("no device sections keeps ordinary startup out of Ruby", function()
	local result = service.generate('/etc/openclash/config/test.yaml')
	assert(result and ruby_calls == 0)
end)
test("successful catalogue has no error and stopped service never calls core API", function()
	local previous = service.api
	service.api = function() error("Stopped service must not call core API") end
	local targets, err = actual_targets(false)
	service.api = previous
	assert(not err and #targets == 1 and targets[1].name == "safe", tostring(err))
end)
test("startup strips leftover owned listeners after last removal and reboot", function()
	files['/etc/openclash/config/test.yaml'] = "listeners: [{name: openclash-device-aabbccddeeff}]"
	local result = service.generate('/etc/openclash/config/test.yaml')
	assert(result and ruby_calls == 1)
end)
test("device state precedence follows the specification", function()
	local original_pid, original_targets, original_devices, original_probe = service.pid, service.targets, service.devices, service.listener_loaded
	local original_guard = service.protected
	local cases = {
		{state = "paused", enabled = "0", guard = false},
		{state = "unprotected", guard = false},
		{state = "stopped", stopped = true},
		{state = "starting", transition = true, missing = true},
		{state = "missing", missing = true},
		{state = "direct", direct = true, loaded = false},
		{state = "inbound", loaded = false, changed = true},
		{state = "ip_changed", changed = true},
		{state = "active"}
	}
	for _, case in ipairs(cases) do
		reset({row({enabled = case.enabled or "1"})})
		transitioning = case.transition or false
		service.pid = function() return not case.stopped and "123" or nil end
		service.protected = function() return case.guard ~= false end
		service.targets = function() return case.missing and {} or {{name = "safe", kind = "group", unsafe = case.direct}} end
		service.devices = function() return {{mac = "AA:BB:CC:DD:EE:01", current_ip = case.changed and "192.168.50.77" or "192.168.50.20", online = false}} end
		service.listener_loaded = function() return case.loaded ~= false end
		files['/tmp/openclash-device-loaded.json'] = encode({pid = "123", rows = service.rows(), listeners = {{name = "openclash-device-aabbccddee01", proxy = "safe", port = 7901}}})
		local result = actual_status()
		assert(result.rows[1].state == case.state, case.state .. " got " .. tostring(result.rows[1].state))
	end
	service.pid, service.targets, service.devices, service.listener_loaded = original_pid, original_targets, original_devices, original_probe
	service.protected = original_guard
end)
test("listener evidence requires both sockets owned by this core", function()
	files['/proc/net/tcp'] = "0: 00000000:1EDD 00000000:0000 0A 0:0 00:0 0 0 0 700\n"
	files['/proc/123/fd/8'] = "socket:[700]"
	assert(not actual_probe("123", {port = 7901}))
	files['/proc/net/udp'] = "0: 00000000:1EDD 00000000:0000 07 0:0 00:0 0 0 0 701\n"
	assert(not actual_probe("123", {port = 7901}))
	files['/proc/123/fd/9'] = "socket:[701]"
	assert(actual_probe("123", {port = 7901}))
	files['/proc/net/tcp6'], files['/proc/net/tcp'] = files['/proc/net/tcp'], nil
	files['/proc/net/udp6'], files['/proc/net/udp'] = files['/proc/net/udp'], nil
	assert(actual_probe("123", {port = 7901}), "dual-stack listeners remain IPv4-capable")
	files['/proc/123/fd/9'] = nil
	assert(not actual_probe("123", {port = 7901}), "UDP ownership is still required")
end)
test("guard health detects missing rules and stale configuration", function()
	reset({row()})
	files['/etc/openclash/device-guard.nft'] = service.render_guard()
	local saved_document = {nftables = {{table = {family = "inet", name = "openclash_guard", handle = 1}}, {rule = {table = "openclash_guard", chain = "forward", expr = {{counter = {packets = 0, bytes = 0}}, {drop = {}}}}}}}
	saved_document.nftables[3] = {set = {name = "lan6", elem = {{prefix = {addr = "fe80::", len = 10}}, {prefix = {addr = "fd00::", len = 64}}}}}
	files['/etc/openclash/device-guard.json'] = encode(saved_document)
	nft_document = clone(saved_document); nft_document.nftables[1].table.handle = 20
	nft_document.nftables[2].rule.expr[1].counter.packets = 100
	nft_document.nftables[3].set.elem[1], nft_document.nftables[3].set.elem[2] = nft_document.nftables[3].set.elem[2], nft_document.nftables[3].set.elem[1]
	assert(actual_protected(service.rows()))
	table.remove(nft_document.nftables, 2)
	assert(not actual_protected(service.rows()))
	nft_document = clone(saved_document)
	files['/etc/openclash/device-guard.nft'] = "stale policy"
	assert(not actual_protected(service.rows()))
end)
print("Device egress service: " .. passed .. " tests passed")
