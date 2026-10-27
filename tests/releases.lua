local releases = dofile("luci-app-openclash/luasrc/openclash_release.lua")

local function release(repo, tag, names, date)
	local assets = {}
	for _, name in ipairs(names) do
		assets[#assets + 1] = { name = name, state = "uploaded", size = 100,
			browser_download_url = "https://github.com/" .. repo .. "/releases/download/" .. tag .. "/" .. name }
	end
	return { tag_name = tag, assets = assets, published_at = date or "2026-10-27T00:00:00Z" }
end

local function core(tag, arch, date)
	return release(releases.repository, tag,
		{ "mihomo-" .. arch .. "-" .. tag .. ".gz", "version.txt", "checksums.txt" }, date)
end

local tag = "v1.19.29-openconnect.11"
local stable = core(tag, "linux-arm64")
local prerelease = core("v1.19.29-openconnect.12", "linux-arm64")
prerelease.prerelease = true
local draft = core("v1.19.29-openconnect.13", "linux-arm64")
draft.draft = true
local old = core("v1.19.29-openconnect.10", "linux-arm64", "2026-10-09T00:00:00Z")
local wrong_arch = core("v1.19.29-openconnect.14", "linux-amd64-v1")
local upstream_tag = core("v1.19.29", "linux-arm64")
local entries = releases.parse_releases({ old, prerelease, stable, draft, wrong_arch, upstream_tag }, "linux-arm64")
assert(#entries == 2, "only compatible, published OpenConnect releases may be offered")
assert(entries[1].version == tag and entries[2].version == old.tag_name, "history must sort by publication date")
assert(entries[1].sha == tag, "history selection must refer to an immutable release tag")

for _, missing in ipairs({ 1, 2, 3 }) do
	local partial = core(tag, "linux-arm64")
	table.remove(partial.assets, missing)
	assert(#releases.parse_releases({ partial }, "linux-arm64") == 0, "incomplete releases must not be offered")
end
local uploading = core(tag, "linux-arm64")
uploading.assets[1].state = "new"
assert(#releases.parse_releases({ uploading }, "linux-arm64") == 0, "assets must finish uploading")
local foreign = core(tag, "linux-arm64")
foreign.assets[1].browser_download_url = "https://example.com/core.gz"
assert(#releases.parse_releases({ foreign }, "linux-arm64") == 0, "foreign asset URLs must not be trusted")
assert(#releases.parse_releases({}, "linux-arm64") == 0)
assert(#releases.parse_releases({ stable }, "0") == 0)

local plugin_tag = "v0.48.002.1"
local function plugin(version)
	return release(releases.plugin_repository, version,
		{ "luci-app-openclash_" .. version:sub(2) .. "_all.ipk",
			"luci-app-openclash-" .. version:sub(2) .. ".apk", "version.txt", "checksums.txt" })
end
local stable_plugin = plugin(plugin_tag)
local dev_plugin = plugin("v0.48.002.2")
dev_plugin.prerelease = true
assert(#releases.parse_plugin_releases({ stable_plugin, dev_plugin }, "master") == 1)
assert(#releases.parse_plugin_releases({ stable_plugin, dev_plugin }, "dev") == 2)
table.remove(stable_plugin.assets, 2)
assert(#releases.parse_plugin_releases({ stable_plugin }, "master") == 0, "both package formats must be present")
print("Release selection checks passed")
