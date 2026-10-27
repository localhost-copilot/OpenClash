-- Invoke the exact backend used by the LuCI JSON controller, without HTTP/CSRF.
local json = require "luci.jsonc"
local service = require "luci.device_egress_service"
local request = json.parse(io.read("*a") or "{}")
local value, err, details = service.mutate(request)
io.write(json.stringify(value or {error = err, details = details}) .. "\n")
if not value then os.exit(1) end
