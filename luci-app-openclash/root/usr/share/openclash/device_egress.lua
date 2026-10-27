#!/usr/bin/lua
local service = require "luci.device_egress_service"
local policy = require "luci.device_egress"
local json = require "luci.jsonc"
local operation = arg[1]
local ok, err
if operation == "render" then
	local value
	value, err = service.render_guard()
	if value then io.write(value); ok = true end
elseif operation == "emergency" then
	io.write(policy.emergency()); ok = true
elseif operation == "bindings" then
	io.write(json.stringify(service.rows())); ok = true
elseif operation == "check-cache" then
	ok = service.cache_matches_bindings()
elseif operation == "generate" then
	ok, err = service.generate(arg[2])
elseif operation == "runtime" then
	ok, err = service.runtime()
elseif operation == "bound" then
	ok, err = service.bound_set()
elseif operation == "record" then
	service.record_loaded(); ok = true
end
if not ok then io.stderr:write(tostring(err or "Device egress operation failed") .. "\n"); os.exit(1) end
