local mod = get_mod("SocialNotifications")

local SocialConstants = mod:original_require("scripts/managers/data_service/services/social/social_constants")
local PlayerInfo      = mod:original_require("scripts/managers/data_service/services/social/player_info")
local UISettings      = mod:original_require("scripts/settings/ui/ui_settings")
local NotifFeed       = mod:original_require("scripts/ui/constant_elements/elements/notification_feed/constant_element_notification_feed")
local FriendStatus    = SocialConstants.FriendStatus

local autoinvite = mod:io_dofile("SocialNotifications/scripts/mods/SocialNotifications/SocialNotifications_autoinvite")

-- ============================================================
-- Constants
-- ============================================================

local ACTIVITY_MISSION     = "mission"
local ACTIVITY_MATCHMAKING = "matchmaking"
local ACTIVITY_HUB         = "hub"

local ONLINE_STATUSES = {
	online       = true,
	reconnecting = true,
}

-- Per-event-type colors: { line_color {a,r,g,b}, bg_color {a,r,g,b} }
local NOTIF_COLORS = {
	online      = { { 255, 100, 220, 120 }, { 160,  15,  40,  20 } },
	offline     = { { 255, 130, 130, 130 }, { 160,  25,  25,  25 } },
	mission     = { { 255, 240, 150,  60 }, { 160,  55,  35,  10 } },
	mission_end = { { 255, 140, 175, 220 }, { 160,  20,  30,  50 } },
	matchmaking = { { 255, 120, 140, 220 }, { 160,  20,  25,  55 } },
	hub         = { { 255,  60, 200, 185 }, { 160,  10,  50,  45 } },
}

-- ============================================================
-- State
-- ============================================================

local _friend_states     = {}   -- [account_id] = { online, activity }
local _poll_timer        = 0
local _events_registered = false

-- ============================================================
-- Hook: extend "custom" notification type to support player portraits.
-- _generate_notification_data strips unknown fields for "custom", so
-- use_player_portrait and player never reach the portrait-loading code.
-- This hook re-adds them after the original runs.
-- ============================================================

mod:hook(NotifFeed, "_generate_notification_data", function(original, self, message_type, data)
	local notification_data = original(self, message_type, data)
	if notification_data and message_type == "custom" and data.player and data.use_player_portrait then
		notification_data.player             = data.player
		notification_data.use_player_portrait = true
	end
	return notification_data
end)

-- ============================================================
-- Notification display
-- ============================================================

local function show_notification(name, body, colors)
	-- Use the game's native notification feed when the UI is active.
	-- event_add_notification_message is handled by ConstantElementNotificationFeed
	-- with message_type "custom": line_1/line_2 are the two text rows,
	-- line_color is the left accent bar, color is the background.
	-- icon + icon_size = "medium" gives the two-column layout (80x80 portrait frame
	-- on the left, text offset 130px) matching the currency pickup appearance.
	if Managers.event then
		Managers.event:trigger("event_add_notification_message", "custom", {
			line_1       = name .. "\n" .. body,
			line_1_color = { 255, 240, 240, 240 },
			icon         = "content/ui/materials/base/ui_portrait_frame_base",
			icon_size    = "medium",
			color        = colors[2],
			line_color   = colors[1],
			glow_opacity = 0,
			show_shine   = true,
		})
	else
		mod:notify(string.format("%s — %s", name, body))
	end
end

-- ============================================================
-- Core: diff one friend, fire notifications on changes
-- ============================================================

local function process_friend(player_info)
	local account_id = player_info:account_id()
	if not account_id then return end

	local new_online   = ONLINE_STATUSES[player_info:online_status(true)] == true
	local new_activity = player_info:player_activity_id()
	local prev         = _friend_states[account_id]

	if not prev then
		-- First sight — seed state silently, no notification.
		_friend_states[account_id] = { online = new_online, activity = new_activity }
		return
	end

	local name = player_info:user_display_name(true, true)
	if not name or name == "" or name == "N/A" then
		name = player_info:character_name()
	end
	name = (name ~= nil and name ~= "") and name or "Unknown"

	-- When skip_platform_friends is on (default), suppress notifications for
	-- friends who are already on the platform friends list (Steam/Xbox/PSN).
	-- Their client handles online/offline notifications natively.
	-- State is still updated so toggling the setting mid-session stays clean.
	local suppress = mod:get("skip_platform_friends")
		and player_info:platform_friend_status() == FriendStatus.friend

	if not suppress then
		-- Online / offline transitions
		if new_online ~= prev.online then
			if new_online and mod:get("notify_online") then
				show_notification(name, mod:localize("notif_online_body"), NOTIF_COLORS.online)
			elseif not new_online and mod:get("notify_offline") then
				show_notification(name, mod:localize("notif_offline_body"), NOTIF_COLORS.offline)
			end
		end

		-- Activity transitions (only meaningful while online)
		if new_online and new_activity ~= prev.activity then
			if new_activity == ACTIVITY_MISSION and mod:get("notify_mission_start") then
				show_notification(name, mod:localize("notif_mission_body"), NOTIF_COLORS.mission)
			elseif prev.activity == ACTIVITY_MISSION and mod:get("notify_mission_end") then
				show_notification(name, mod:localize("notif_mission_end_body"), NOTIF_COLORS.mission_end)
			elseif new_activity == ACTIVITY_MATCHMAKING and mod:get("notify_matchmaking") then
				show_notification(name, mod:localize("notif_matchmaking_body"), NOTIF_COLORS.matchmaking)
			elseif new_activity == ACTIVITY_HUB and mod:get("notify_hub") then
				show_notification(name, mod:localize("notif_hub_body"), NOTIF_COLORS.hub)
			end
		end
	end

	prev.online   = new_online
	prev.activity = new_activity
end

-- ============================================================
-- Poll — seeds friend list and catches activity changes
-- ============================================================

local function poll_friends()
	local social = Managers.data_service and Managers.data_service.social
	if not social then return end

	social:fetch_friends():next(function(friends)
		if not friends then return end
		for _, player_info in ipairs(friends) do
			if player_info:is_friend() then
				process_friend(player_info)
			end
		end
	end)
end

-- ============================================================
-- Event: presence entry updated
-- Fires from PresenceEntryImmaterium:update_with() whenever fresh
-- data arrives from the immaterium backend — faster than the poll.
-- Only process friends we've already seeded to avoid startup spam.
-- ============================================================

mod._on_immaterium_entry = function(self, new_entry)
	local account_id = new_entry and new_entry.account_id
	if not account_id or account_id == "" then return end
	if not _friend_states[account_id] then return end

	local social = Managers.data_service and Managers.data_service.social
	if not social then return end

	local player_info = social:get_player_info_by_account_id(account_id)
	if player_info then
		process_friend(player_info)
	end
end

-- ============================================================
-- DMF callbacks
-- ============================================================

local function reset_state()
	_friend_states = {}
	_poll_timer    = 0
	autoinvite.reset_timer()
	poll_friends()  -- seeds _friend_states without notifying
end

mod.on_all_mods_loaded = function()
	if not _events_registered then
		Managers.event:register(mod, "event_new_immaterium_entry", "_on_immaterium_entry")
		_events_registered = true
	end
	reset_state()
end

mod.on_game_state_changed = function(status, state_name)
	-- Re-seed on map transitions to avoid stale state firing spurious notifications.
	if status == "enter" and (state_name == "GameplayStateRun" or state_name == "StateMainMenu") then
		reset_state()
	end
end

mod.update = function(dt)
	_poll_timer = _poll_timer + dt
	local interval = mod:get("poll_interval") or 10
	if _poll_timer >= interval then
		_poll_timer = 0
		poll_friends()
	end

	autoinvite.update(dt)
end

-- ============================================================
-- Cross-platform display fixes
-- ============================================================
-- The game shows a globe icon for friends on a different platform,
-- and stores Xbox gamertags with a "#NNNN" suffix (e.g. "SafePunjabi#3244").
-- These hooks replace the globe with the friend's actual platform icon
-- and strip the Xbox suffix for cleaner display everywhere in the UI.

local GLYPH_GLOBE = "\238\129\175"
local GLYPH_XBOX  = "\238\129\172"  -- raw glyph; returned by FriendXboxLive.platform_icon (offline path)

local ICON_STEAM = "\238\129\171"
local ICON_XBOX  = "{#color(16,124,16)}\238\129\172{#reset()}"
local ICON_PSN   = "{#color(255,255,255)}\238\129\177{#reset()}"

local function resolve_platform(player_info)
	local platform = player_info:platform()
	if platform ~= "" then return platform end
	-- platform() returns "" when the immaterium entry has no platform field.
	-- In Lua, "" is truthy so the "Unknown" fallback in platform() never fires.
	-- Infer Xbox from the #NNNN suffix that Xbox appends to disambiguate gamertags;
	-- anything else with no platform field is assumed to be PSN.
	local account_name = player_info._account_name
	if account_name and account_name:match("#%d+$") then
		return "xbox"
	end
	return "psn"
end

mod:hook(PlayerInfo, "platform_icon", function(func, self)
	local icon, color = func(self)
	if icon == GLYPH_GLOBE or icon == GLYPH_XBOX then
		local platform = resolve_platform(self)
		if platform == "steam" then
			return ICON_STEAM
		elseif platform == "xbox" then
			return ICON_XBOX, true
		elseif platform == "psn" then
			return ICON_PSN, true
		end
	end
	return icon, color
end)

-- ============================================================
-- Test command: /social_test
-- Fetches the first useable friend, runs from_player_info (which
-- triggers the autoinvite hook), and prints every popup item label
-- so we can verify the injection without opening the real UI.
-- ============================================================

mod:command("social_test", "Fire a test 'online' notification using the local player's portrait and character data", function()
	local local_player = Managers.player and Managers.player:local_player(1)
	if not local_player then
		mod:notify("social_test: local player not available")
		return
	end

	local profile = local_player:profile()
	if not profile then
		mod:notify("social_test: profile not loaded")
		return
	end

	-- Line 1: class glyph + character name
	local archetype_name = local_player:archetype_name()
	local archetype_icon = archetype_name and UISettings.archetype_font_icon_simple[archetype_name] or ""
	local char_name      = profile.name or "Unknown"
	local line_1         = (archetype_icon ~= "" and (archetype_icon .. " ") or "") .. char_name

	-- Line 2: platform display name + status
	-- Look up our own player_info from the social service to get the account (Steam) name.
	local account_name = char_name
	local social = Managers.data_service and Managers.data_service.social
	if social then
		local own_info = social:get_player_info_by_account_id(local_player:account_id())
		if own_info then
			local display = own_info:user_display_name(true, true)
			if display and display ~= "" and display ~= "N/A" then
				account_name = display
			end
		end
	end
	local account_display = account_name .. " " .. mod:localize("notif_online_body")
	local combined = line_1 .. "\n" .. account_display

	if Managers.event then
		Managers.event:trigger("event_add_notification_message", "custom", {
			line_1              = combined,
			line_1_color        = { 255, 240, 240, 240 },
			icon                = "content/ui/materials/base/ui_portrait_frame_base",
			icon_size           = "medium",
			use_player_portrait = true,
			player              = local_player,
			color               = NOTIF_COLORS.online[2],
			line_color          = NOTIF_COLORS.online[1],
			glow_opacity        = 0,
			show_shine          = true,
		})
	else
		mod:notify(combined)
	end
end)

-- ============================================================
-- Debug command: /social_dump
-- For every friend where platform() returns "", dumps all raw
-- PlayerInfo fields, platform_social (if any), and the full
-- immaterium entry + key_values so we can identify PSN vs Xbox.
-- ============================================================

mod:command("social_dump", "Dump raw PlayerInfo data for friends with unknown platform", function()
	local social = Managers.data_service and Managers.data_service.social
	if not social then
		mod:notify("social_dump: social service not available")
		return
	end

	social:fetch_friends():next(function(friends)
		if not friends then
			mod:notify("social_dump: no friend list returned")
			return
		end

		local count = 0
		for _, pi in ipairs(friends) do
			if pi:platform() == "" then
				count = count + 1
				local sep = "----------------------------------------"
				mod:info(sep)
				mod:info(string.format("[DUMP] Friend #%d", count))

				-- PlayerInfo raw fields
				mod:info(string.format("  _account_id       = %s", tostring(pi._account_id)))
				mod:info(string.format("  _account_name     = %s", tostring(pi._account_name)))
				mod:info(string.format("  _platform         = %s", tostring(pi._platform)))
				mod:info(string.format("  _platform_id      = %s", tostring(pi._platform_id)))
				mod:info(string.format("  _friend_status    = %s", tostring(pi._friend_status)))
				mod:info(string.format("  _is_blocked       = %s", tostring(pi._is_blocked)))
				mod:info(string.format("  _is_party_member  = %s", tostring(pi._is_party_member)))
				mod:info(string.format("  _online_status    = %s", tostring(pi._online_status)))

				-- PlayerInfo method results
				mod:info(string.format("  platform()             = %s", tostring(pi:platform())))
				mod:info(string.format("  platform_user_id()     = %s", tostring(pi:platform_user_id())))
				mod:info(string.format("  online_status()        = %s", tostring(pi:online_status())))
				mod:info(string.format("  player_activity_id()   = %s", tostring(pi:player_activity_id())))
				mod:info(string.format("  friend_status()        = %s", tostring(pi:friend_status())))
				mod:info(string.format("  platform_friend_status()= %s", tostring(pi:platform_friend_status())))
				mod:info(string.format("  is_friend()            = %s", tostring(pi:is_friend())))
				mod:info(string.format("  is_blocked()           = %s", tostring(pi:is_blocked())))
				mod:info(string.format("  cross_play_disabled()  = %s", tostring(pi:cross_play_disabled())))
				mod:info(string.format("  is_cross_playing()     = %s", tostring(pi:is_cross_playing())))

				-- platform_social
				local ps = pi._platform_social
				if ps then
					mod:info("  platform_social:")
					mod:info(string.format("    platform()  = %s", tostring(ps.platform and ps:platform() or "N/A")))
					mod:info(string.format("    id()        = %s", tostring(ps.id and ps:id() or "N/A")))
					mod:info(string.format("    name()      = %s", tostring(ps.name and ps:name() or "N/A")))
					mod:info(string.format("    is_friend() = %s", tostring(ps.is_friend and ps:is_friend() or "N/A")))
					mod:info(string.format("    online_status() = %s", tostring(ps.online_status and ps:online_status() or "N/A")))
					-- dump the raw _friend_data table if present
					if ps._friend_data then
						mod:info("    _friend_data fields:")
						for k, v in pairs(ps._friend_data) do
							if type(v) ~= "table" then
								mod:info(string.format("      %s = %s", tostring(k), tostring(v)))
							end
						end
					end
				else
					mod:info("  platform_social: nil")
				end

				-- presence / immaterium entry
				local presence = pi._presence
				if presence and presence._immaterium_entry then
					local e = presence._immaterium_entry
					mod:info("  immaterium_entry:")
					mod:info(string.format("    account_id      = %s", tostring(e.account_id)))
					mod:info(string.format("    account_name    = %s", tostring(e.account_name)))
					mod:info(string.format("    platform        = %s", tostring(e.platform)))
					mod:info(string.format("    platform_user_id= %s", tostring(e.platform_user_id)))
					mod:info(string.format("    status          = %s", tostring(e.status)))
					mod:info(string.format("    last_update     = %s", tostring(e.last_update)))
					if e.key_values then
						mod:info("    key_values:")
						for k, v in pairs(e.key_values) do
							local val = type(v) == "table" and tostring(v.value) or tostring(v)
							mod:info(string.format("      %s = %s", tostring(k), val))
						end
					else
						mod:info("    key_values: nil")
					end
				else
					mod:info("  presence: nil or no immaterium_entry")
				end
			end
		end

		if count == 0 then
			mod:info("social_dump: no friends with platform() == \"\" found")
		else
			mod:info(string.format("social_dump: dumped %d friend(s)", count))
		end
	end)
end)

mod:hook(PlayerInfo, "user_display_name", function(func, self, use_stale, no_platform_icon)
	local name, color = func(self, use_stale, no_platform_icon)
	-- Strip Xbox gamertag suffix (#NNNN). The suffix is Xbox-specific so safe
	-- to apply unconditionally; no Steam or PSN names use this format.
	if name then
		name = name:gsub("#%d+$", "")
	end
	return name, color
end)
