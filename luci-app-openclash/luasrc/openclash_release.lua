local M = {}

M.repository = "clash-cube/mihomo"
M.api_url = "https://api.github.com/repos/" .. M.repository .. "/releases?per_page=100"
M.plugin_repository = "localhost-copilot/OpenClash"
M.plugin_api_url = "https://api.github.com/repos/" .. M.plugin_repository .. "/releases?per_page=100"

function M.proxy_url(url, cdn)
	-- jsDelivr serves repository files, not GitHub Release assets.
	if not cdn or cdn == "" or cdn == "0" or cdn:match("raw%.githubusercontent%.com")
		or cdn == "https://cdn.jsdelivr.net/" or cdn == "https://fastly.jsdelivr.net/"
		or cdn == "https://testingcf.jsdelivr.net/" then
		return url
	end
	return cdn .. url
end

function M.parse_releases(releases, arch)
	local entries = {}
	if type(releases) ~= "table" or type(arch) ~= "string" or not arch:match("^linux%-%w[%w%-]*$") then
		return entries
	end
	for _, release in ipairs(releases) do
		local tag = release.tag_name
		if not release.draft and not release.prerelease and type(tag) == "string"
			and tag:match("^v%d+%.%d+%.%d+%-openconnect%.%d+$") then
			local base = "https://github.com/" .. M.repository .. "/releases/download/" .. tag .. "/"
			local filename = "mihomo-" .. arch .. "-" .. tag .. ".gz"
			local assets = {}
			for _, asset in ipairs(release.assets or {}) do
				if asset.state == "uploaded" and (tonumber(asset.size) or 0) > 0
					and asset.browser_download_url == base .. asset.name then
					assets[asset.name] = true
				end
			end
			-- Do not offer a partially uploaded release or one for another CPU.
			if assets[filename] and assets["version.txt"] and assets["checksums.txt"] then
				entries[#entries + 1] = {
					version = tag, date = release.published_at or "", sha = tag,
					url = base .. filename, version_url = base .. "version.txt", asset = filename
				}
			end
		end
	end
	table.sort(entries, function(a, b) return a.date > b.date end)
	return entries
end

function M.parse_plugin_releases(releases, branch)
	local entries = {}
	if type(releases) ~= "table" then return entries end
	for _, release in ipairs(releases) do
		local tag = release.tag_name
		if not release.draft and (branch == "dev" or not release.prerelease) and type(tag) == "string"
			and tag:match("^v%d+%.%d+%.%d+[%d%.]*$") then
			local base = "https://github.com/" .. M.plugin_repository .. "/releases/download/" .. tag .. "/"
			local version = tag:sub(2)
			local ipk = "luci-app-openclash_" .. version .. "_all.ipk"
			local apk = "luci-app-openclash-" .. version .. ".apk"
			local assets = {}
			for _, asset in ipairs(release.assets or {}) do
				if asset.state == "uploaded" and (tonumber(asset.size) or 0) > 0
					and asset.browser_download_url == base .. asset.name then assets[asset.name] = true end
			end
			if assets[ipk] and assets[apk] and assets["version.txt"] and assets["checksums.txt"] then
				entries[#entries + 1] = { version = tag, date = release.published_at or "", sha = tag,
					version_url = base .. "version.txt" }
			end
		end
	end
	table.sort(entries, function(a, b) return a.date > b.date end)
	return entries
end

return M
