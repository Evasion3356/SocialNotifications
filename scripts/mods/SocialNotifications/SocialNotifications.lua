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
local _seeding           = false  -- true while the initial seed poll is in-flight
local _pending_online    = {}   -- [account_id] = { name, deadline } — online notifications deferred until character profile arrives

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

-- Returns the best human-readable name for a friend: character name when the
-- presence profile has loaded, platform display name as fallback.
local function friendly_name(player_info)
	local char_name = player_info:character_name()
	if char_name and char_name ~= "" then
		return char_name
	end
	local display = player_info:user_display_name(true, true)
	if display and display ~= "" and display ~= "N/A" then
		return display
	end
	return "Unknown"
end

-- Build and fire a notification for a friend.
-- player_info drives everything: character name, archetype icon, platform display
-- name, and portrait. When profile() is available the notification gets:
--   Line 1: [archetype icon] character name
--   Line 2: [platform icon] display name + body text
--   Portrait: character portrait via Managers.ui:load_profile_portrait
-- Falls back to a single line with display name when profile isn't loaded yet.
local function show_notification(player_info, body, colors)
	if not Managers.event then
		mod:notify(string.format("%s — %s", friendly_name(player_info), body))
		return
	end

	local profile = player_info and player_info:profile()
	local line1, line2

	if profile then
		-- Line 1: archetype icon + character name
		local char_name = (profile.name and profile.name ~= "") and profile.name or friendly_name(player_info)
		local archetype_name = profile.archetype and profile.archetype.archetype_name
		-- archetype_name is a loc key like "loc_class_psyker_name"; extract the identifier.
		local archetype_id = archetype_name and archetype_name:match("^loc_class_(.+)_name$")
		local arch_icon = archetype_id and UISettings.archetype_font_icon_simple[archetype_id] or ""
		line1 = arch_icon ~= "" and (arch_icon .. " " .. char_name) or char_name

		-- Line 2: platform display name (with embedded platform icon glyph) + body
		-- user_display_name(stale=true, no_icon=false) returns "[glyph] Name"
		local display = player_info:user_display_name(true, false)
		if not display or display == "" or display == "N/A" then
			display = player_info:user_display_name(true, true)
		end
		line2 = ((display and display ~= "") and display or "Unknown") .. " " .. body

		mod:info("[SN] show_notification profile dump — char=%s archetype_id=%s arch_icon=%s display=%s",
			tostring(char_name), tostring(archetype_id), tostring(arch_icon ~= ""), tostring(display))
	else
		-- Profile not loaded yet; single-line fallback
		line1 = friendly_name(player_info) .. "\n" .. body
	end

	local data = {
		line_1       = line2 and (line1 .. "\n" .. line2) or line1,
		line_1_color = { 255, 240, 240, 240 },
		icon         = "content/ui/materials/base/ui_portrait_frame_base",
		icon_size    = "medium",
		color        = colors[2],
		line_color   = colors[1],
		glow_opacity = 0,
		show_shine   = true,
	}
	if profile then
		data.player             = player_info
		data.use_player_portrait = true
	end
	Managers.event:trigger("event_add_notification_message", "custom", data)
end

-- ============================================================
-- Core: diff one friend, fire notifications on changes
-- ============================================================

local function get_last_update(player_info)
	local presence = player_info._presence
	local entry = presence and presence._immaterium_entry
	return entry and entry.last_update
end

local function process_friend(player_info, source)
	local account_id = player_info:account_id()
	if not account_id then return end

	local new_online      = ONLINE_STATUSES[player_info:online_status()] == true
	local new_activity    = player_info:player_activity_id()
	local new_last_update = get_last_update(player_info)
	local prev            = _friend_states[account_id]

	local short_id = account_id:sub(-6)

	if not prev then
		-- First sight — seed state. During the initial seed poll (_seeding=true) this is
		-- always silent (baseline snapshot). After seeding, a newly-seen online friend
		-- means they just came online, so fire the notification.
		mod:info("[SN:%s] first-sight via %s — seeding online=%s activity=%s seeding=%s",
			short_id, source or "?", tostring(new_online), tostring(new_activity), tostring(_seeding))
		_friend_states[account_id] = { online = new_online, activity = new_activity, last_update = new_last_update }
		if not _seeding and new_online and mod:get("notify_online") then
			local suppress = mod:get("skip_platform_friends")
				and player_info:platform_friend_status() == FriendStatus.friend
			if not suppress then
				if player_info:character_name() == "" then
					mod:info("[SN:%s] first-sight online deferred (no character profile yet)", short_id)
					local deadline = (Managers.time and Managers.time:time("main") or 0) + 6
					_pending_online[account_id] = { deadline = deadline }
				else
					mod:info("[SN:%s] first-sight NOTIFY online", short_id)
					show_notification(player_info, mod:localize("notif_online_body"), NOTIF_COLORS.online)
				end
			else
				mod:info("[SN:%s] first-sight online suppressed (platform friend)", short_id)
			end
		end
		return
	end

	-- If last_update hasn't changed, the backend hasn't sent any new presence data —
	-- nothing could have changed, so skip the diff entirely.
	if new_last_update and new_last_update == prev.last_update then
		return
	end

	local online_changed   = new_online ~= prev.online
	local activity_changed = new_online and new_activity ~= prev.activity

	if online_changed or activity_changed then
		mod:info("[SN:%s] diff via %s — online %s->%s  activity %s->%s (last_update %s->%s)",
			short_id, source or "?",
			tostring(prev.online), tostring(new_online),
			tostring(prev.activity), tostring(new_activity),
			tostring(prev.last_update), tostring(new_last_update))
	end

	-- When skip_platform_friends is on (default), suppress notifications for
	-- friends who are already on the platform friends list (Steam/Xbox/PSN).
	-- Their client handles online/offline notifications natively.
	-- State is still updated so toggling the setting mid-session stays clean.
	local suppress = mod:get("skip_platform_friends")
		and player_info:platform_friend_status() == FriendStatus.friend

	-- Update state before notifying so that any re-entrant event fired during
	-- show_notification sees the already-committed new state and produces no diff.
	local prev_activity = prev.activity
	prev.online       = new_online
	prev.activity     = new_activity
	prev.last_update  = new_last_update

	if not suppress then
		-- Online / offline transitions
		if online_changed then
			if new_online and mod:get("notify_online") then
				if player_info:character_name() == "" then
					-- Character profile hasn't arrived yet (comes in a later presence update).
					-- Defer the notification; _on_immaterium_entry will flush it once the profile lands.
					mod:info("[SN:%s] online notification deferred (no character profile yet)", short_id)
					local deadline = (Managers.time and Managers.time:time("main") or 0) + 6
					_pending_online[account_id] = { deadline = deadline }
				else
					mod:info("[SN:%s] NOTIFY online", short_id)
					show_notification(player_info, mod:localize("notif_online_body"), NOTIF_COLORS.online)
				end
			elseif not new_online and mod:get("notify_offline") then
				_pending_online[account_id] = nil  -- cancel any deferred online notif if they went offline first
				mod:info("[SN:%s] NOTIFY offline", short_id)
				show_notification(player_info, mod:localize("notif_offline_body"), NOTIF_COLORS.offline)
			end
		end

		-- Activity transitions (only meaningful while online)
		if activity_changed then
			if new_activity == ACTIVITY_MISSION and mod:get("notify_mission_start") then
				mod:info("[SN:%s] NOTIFY mission", short_id)
				show_notification(player_info, mod:localize("notif_mission_body"), NOTIF_COLORS.mission)
			elseif prev_activity == ACTIVITY_MISSION and mod:get("notify_mission_end") then
				mod:info("[SN:%s] NOTIFY mission_end", short_id)
				show_notification(player_info, mod:localize("notif_mission_end_body"), NOTIF_COLORS.mission_end)
			elseif new_activity == ACTIVITY_MATCHMAKING and mod:get("notify_matchmaking") then
				mod:info("[SN:%s] NOTIFY matchmaking", short_id)
				show_notification(player_info, mod:localize("notif_matchmaking_body"), NOTIF_COLORS.matchmaking)
			elseif new_activity == ACTIVITY_HUB and mod:get("notify_hub") then
				mod:info("[SN:%s] NOTIFY hub", short_id)
				show_notification(player_info, mod:localize("notif_hub_body"), NOTIF_COLORS.hub)
			end
		end
	end
end

-- ============================================================
-- Poll — seeds friend list and catches activity changes
-- ============================================================

local function poll_friends()
	local social = Managers.data_service and Managers.data_service.social
	if not social then return end

	social:fetch_friends():next(function(friends)
		-- Keep _seeding = true while iterating so that first-sight of already-online
		-- friends in the seed poll is treated as a silent baseline snapshot, not a
		-- "came online" event. Set it to false only after the loop completes.
		local was_seeding = _seeding
		if not friends then
			_seeding = false
			return
		end
		for _, player_info in ipairs(friends) do
			if player_info:is_friend() then
				process_friend(player_info, "poll")
			end
		end
		_seeding = false

		local now = Managers.time and Managers.time:time("main") or 0

		-- After the seed poll: queue "came online" notifications for every friend who
		-- was already online when the mod loaded. We stayed silent during seeding to
		-- avoid false positives on startup; now surface them via the deferred path so
		-- we wait for the character profile before showing the notification.
		if was_seeding then
			for account_id, state in pairs(_friend_states) do
				if state.online and not _pending_online[account_id] and mod:get("notify_online") then
					local pi = social:get_player_info_by_account_id(account_id)
					if pi and pi:is_friend() then
						local suppress = mod:get("skip_platform_friends")
							and pi:platform_friend_status() == FriendStatus.friend
						if not suppress then
							if pi:character_name() ~= "" then
								mod:info("[SN:%s] NOTIFY online (post-seed, profile ready)", account_id:sub(-6))
								show_notification(pi, mod:localize("notif_online_body"), NOTIF_COLORS.online)
							else
								mod:info("[SN:%s] online deferred post-seed (no profile yet)", account_id:sub(-6))
								_pending_online[account_id] = { deadline = now + 6 }
							end
						end
					end
				end
			end
		end

		-- Every poll: flush pending notifications where the character profile has now arrived.
		-- This is the fallback for friends who never trigger another presence event
		-- (e.g. someone who stays in a mission without any state change).
		for account_id, pending in pairs(_pending_online) do
			local pi = social:get_player_info_by_account_id(account_id)
			if pi then
				if pi:character_name() ~= "" or now >= pending.deadline then
					_pending_online[account_id] = nil
					if mod:get("notify_online") then
						mod:info("[SN:%s] NOTIFY online (poll flush, char=%s)", account_id:sub(-6), tostring(pi:character_name() ~= ""))
						show_notification(pi, mod:localize("notif_online_body"), NOTIF_COLORS.online)
					end
				end
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
	-- While the initial seed poll is in-flight, ignore events for friends we haven't
	-- seen yet — they'll be captured by the poll. After seeding, let unseen friends
	-- through so process_friend can fire "came online" for them.
	if not _friend_states[account_id] and _seeding then return end

	local social = Managers.data_service and Managers.data_service.social
	if not social then return end

	local player_info = social:get_player_info_by_account_id(account_id)
	if not player_info then return end

	-- Flush a deferred online notification now that a new presence update arrived.
	-- The character profile typically lands in the second update, a few seconds after
	-- the status-change update that first triggered the "came online" detection.
	local pending = _pending_online[account_id]
	if pending and player_info:is_friend() then
		local char_name = player_info:character_name()
		local now = Managers.time and Managers.time:time("main") or 0
		if char_name ~= "" or now >= pending.deadline then
			_pending_online[account_id] = nil
			if mod:get("notify_online") then
				mod:info("[SN:%s] NOTIFY online (deferred flush, char=%s deadline=%s)",
					account_id:sub(-6), tostring(char_name ~= ""), tostring(now >= pending.deadline))
				show_notification(player_info, mod:localize("notif_online_body"), NOTIF_COLORS.online)
			end
		end
	end

	if player_info:is_friend() then
		process_friend(player_info, "event")
	end
end

-- ============================================================
-- DMF callbacks
-- ============================================================

-- Full reset: clears all state and re-seeds from scratch.
-- Used on mod load. Fires post-seed "online" notifications as an
-- initial presence summary (intentional on first load only).
local function reset_state()
	_friend_states  = {}
	_pending_online = {}
	_poll_timer     = 0
	_seeding        = true
	autoinvite.reset_timer()
	poll_friends()  -- seeds _friend_states without notifying; clears _seeding when done
end

-- Soft reset: keeps _friend_states intact so the diff stays valid across
-- map transitions. Only resets timers and triggers a fresh poll (silently,
-- since _seeding remains false and _friend_states already has baselines).
local function soft_reset()
	_poll_timer = 0
	autoinvite.reset_timer()
	poll_friends()
end

mod.on_all_mods_loaded = function()
	if not _events_registered then
		Managers.event:register(mod, "event_new_immaterium_entry", "_on_immaterium_entry")
		_events_registered = true
	end
	reset_state()
end

mod.on_game_state_changed = function(status, state_name)
	if status == "enter" and (state_name == "GameplayStateRun" or state_name == "StateMainMenu") then
		-- Soft reset: preserve existing friend states so we don't re-fire
		-- "online" notifications for friends who were already online before
		-- the map transition.
		soft_reset()
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
	-- _platform is populated when the friend is online (presence data arrives).
	-- When offline, it may be empty — fall back to name-based inference.
	local platform = player_info._platform
	if platform and platform ~= "" then return platform end
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

-- DEV_ONLY_START
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

mod:command("social_dump", "Dump raw PlayerInfo data for all friends", function()
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
			do
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
			mod:info("social_dump: no friends found")
		else
			mod:info(string.format("social_dump: dumped %d friend(s)", count))
		end
	end)
end)
-- DEV_ONLY_END

mod:hook(PlayerInfo, "user_display_name", function(func, self, use_stale, no_platform_icon)
	local name, color = func(self, use_stale, no_platform_icon)
	-- Strip Xbox gamertag suffix (#NNNN). The suffix is Xbox-specific so safe
	-- to apply unconditionally; no Steam or PSN names use this format.
	if name then
		name = name:gsub("#%d+$", "")
	end
	return name, color
end)
