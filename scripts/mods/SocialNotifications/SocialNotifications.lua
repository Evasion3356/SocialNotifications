local mod = get_mod("SocialNotifications")

local SocialConstants = mod:original_require("scripts/managers/data_service/services/social/social_constants")
local PlayerInfo      = mod:original_require("scripts/managers/data_service/services/social/player_info")
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
-- Notification display
-- ============================================================

local function show_notification(name, body, colors)
	-- Use the game's native notification feed when the UI is active.
	-- event_add_notification_message is handled by ConstantElementNotificationFeed
	-- with message_type "custom": line_1/line_2 are the two text rows,
	-- line_color is the left accent bar, color is the background.
	if Managers.event then
		Managers.event:trigger("event_add_notification_message", "custom", {
			line_1       = name,
			line_1_color = { 255, 240, 240, 240 },
			line_2       = body,
			line_2_color = { 255, 175, 175, 175 },
			color        = colors[2],
			line_color   = colors[1],
			glow_opacity = 0,
			show_shine   = false,
			scale_icon   = false,
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
	-- Infer Xbox from the #NNNN suffix that Xbox appends to disambiguate gamertags.
	local account_name = player_info._account_name
	if account_name and account_name:match("#%d+$") then
		return "xbox"
	end
	return "Unknown"
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

mod:hook(PlayerInfo, "user_display_name", function(func, self, use_stale, no_platform_icon)
	local name, color = func(self, use_stale, no_platform_icon)
	-- Strip Xbox gamertag suffix (#NNNN). The suffix is Xbox-specific so safe
	-- to apply unconditionally; no Steam or PSN names use this format.
	if name then
		name = name:gsub("#%d+$", "")
	end
	return name, color
end)
