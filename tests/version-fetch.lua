local release_source = dofile("luci-app-openclash/luasrc/openclash_release.lua")
local tag = "v1.19.29-openconnect.11"
local base = "https://github.com/clash-cube/mihomo/releases/download/" .. tag .. "/"
local assets = {}
for _, name in ipairs({ "mihomo-linux-arm64-" .. tag .. ".gz", "version.txt", "checksums.txt" }) do
	assets[#assets + 1] = { name = name, size = 100, state = "uploaded", browser_download_url = base .. name }
end
local response = '[{"body":"' .. string.rep("x", 2 * 1024 * 1024) .. '"}]'
local parsed_response = { { tag_name = tag, assets = assets, published_at = "2026-10-27T00:00:00Z" } }
local cursor, ticks, closed = 1, 0, false
local reader = {
	read = function(_, size)
		if closed or cursor > #response then return nil end
		local chunk = response:sub(cursor, cursor + size - 1)
		cursor = cursor + #chunk
		return chunk
	end,
	close = function() end
}
local cache = {}
local fake_fs = {
	uci_get_config = function() return "linux-arm64" end,
	read_version_cache = function() return cache end,
	update_version_cache = function(update) update(cache) end
}
-- Model curl blocked on its output pipe. A slow reader exhausts curl's timeout
-- and receives a truncated response; advancing the clock never sleeps.
nixio = {
	pipe = function() return reader, { close = function() end } end,
	fork = function() return 123 end,
	poll_flags = function() return 0 end,
	poll = function() return not closed and cursor <= #response and 1 or 0 end,
	waitpid = function()
		if cursor > #response then return 123 end
		if ticks >= 3 then closed = true; return 123 end
	end,
	nanosleep = function() ticks = ticks + 1 end,
	kill = function() end
}
package.preload["nixio"] = function() return nixio end
package.preload["luci.model.uci"] = function() return {} end
package.preload["luci.openclash"] = function() return fake_fs end
package.preload["luci.openclash_release"] = function() return release_source end
package.preload["luci.jsonc"] = function()
	return { parse = function(raw) return raw == response and parsed_response or nil end }
end
arg = {}
local version = dofile("luci-app-openclash/root/usr/share/openclash/openclash_version.lua")
local entries, err = version.fetch_meta_releases(false, "0")
assert(not err and #entries == 1 and entries[1].version == tag, "large Release responses must be drained before curl times out")
assert(cache.clashcube.entries[1].version == tag)
print("Large Release response check passed")
