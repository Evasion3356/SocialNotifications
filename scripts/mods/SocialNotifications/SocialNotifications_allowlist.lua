local mod = get_mod("SocialNotifications")

-- ============================================================
-- Persistence
-- ============================================================

-- In-memory allowlist keyed by platform_user_id (survives mod reloads).
local _allowlist = mod:persistent_table("notification_allowlist")

-- Access the real io library captured by DMF before the sandbox strips it.
local _real_io    = Mods and Mods.lua and Mods.lua.io
local _loadstring = Mods and Mods.lua and Mods.lua.loadstring
local DATA_FILE   = "./../mods/SocialNotifications/notification_allowlist.lua"

local function save_allowlist()
	if not _real_io then return end
	local f = _real_io.open(DATA_FILE, "w")
	if not f then return end
	local lines = { "return {" }
	for puid in pairs(_allowlist) do
		lines[#lines + 1] = string.format("  [%q] = true,", puid)
	end
	lines[#lines + 1] = "}"
	f:write(table.concat(lines, "\n"))
	f:close()
end

local function load_allowlist()
	if not _real_io or not _loadstring then return end
	local f = _real_io.open(DATA_FILE, "r")
	if not f then return end
	local content = f:read("*all")
	f:close()
	if not content or content == "" then return end
	local func = _loadstring(content, DATA_FILE)
	if not func then return end
	local ok, data = pcall(func)
	if ok and type(data) == "table" then
		for puid, v in pairs(data) do
			if type(puid) == "string" and v == true then
				_allowlist[puid] = true
			end
		end
	end
end

-- Populate _allowlist from the save file once at module load time.
-- Uses _real_io directly so missing files are silently ignored (no log spam).
load_allowlist()

-- ============================================================
-- Allowlist operations
-- ============================================================

local function is_allowlisted(player_info)
	local puid = player_info:platform_user_id()
	return puid ~= "" and _allowlist[puid] == true
end

local function toggle_allowlist(player_info)
	local puid = player_info:platform_user_id()
	if not puid or puid == "" then return end
	if _allowlist[puid] then
		_allowlist[puid] = nil
	else
		_allowlist[puid] = true
	end
	save_allowlist()
end

-- ============================================================
-- Module interface
-- ============================================================

local Allowlist = {}

Allowlist.is_allowlisted = is_allowlisted

-- Called from the single combined from_player_info hook in SocialNotifications.lua.
-- Items are APPENDED after auto-invite entries so auto-invite's widget[1]
-- assumption stays correct. button_idx is captured per-popup-open in the
-- callback closure for correct in-place label updates.
Allowlist.inject_items = function(items, count, player_info)
	if not mod:get("use_notification_allowlist") then
		return items, count
	end

	if player_info:is_own_player() or player_info:is_blocked() then
		return items, count
	end

	local puid = player_info:platform_user_id()
	if not puid or puid == "" then
		return items, count
	end

	-- Insert between the auto-invite button (1) and its divider (2),
	-- so both buttons share the same group with one divider below them.
	table.insert(items, 2, {
		blueprint = "button",
		label     = is_allowlisted(player_info)
			and mod:localize("allowlist_on")
			or  mod:localize("allowlist_off"),
		callback  = function()
			toggle_allowlist(player_info)
			local widgets = mod._current_social_popup and mod._current_social_popup._menu_widgets
			if widgets and widgets[2] then
				widgets[2].content.text = is_allowlisted(player_info)
					and mod:localize("allowlist_on")
					or  mod:localize("allowlist_off")
			end
		end,
	})

	count = count + 1
	return items, count
end

return Allowlist
