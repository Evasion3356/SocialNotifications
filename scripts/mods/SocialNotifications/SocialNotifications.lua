local mod = get_mod("SocialNotifications")

local SocialConstants = mod:original_require("scripts/managers/data_service/services/social/social_constants")
local PlayerInfo      = mod:original_require("scripts/managers/data_service/services/social/player_info")
local UISettings      = mod:original_require("scripts/settings/ui/ui_settings")
local NotifFeed       = mod:original_require("scripts/ui/constant_elements/elements/notification_feed/constant_element_notification_feed")
local ContentList     = mod:original_require("scripts/ui/view_elements/view_element_player_social_popup/view_element_player_social_popup_content_list")
local FriendStatus    = SocialConstants.FriendStatus
local PartyStatus     = SocialConstants.PartyStatus

local autoinvite = mod:io_dofile("SocialNotifications/scripts/mods/SocialNotifications/SocialNotifications_autoinvite")
local allowlist  = mod:io_dofile("SocialNotifications/scripts/mods/SocialNotifications/SocialNotifications_allowlist")

-- Single combined hook: both sub-modules expose inject_items() so only one
-- hook registration is needed, avoiding DMF's "rehook" warning.
mod:hook(ContentList, "from_player_info", function(original, parent, player_info)
	local items, count = original(parent, player_info)
	items, count = autoinvite.inject_items(items, count, player_info)
	items, count = allowlist.inject_items(items, count, player_info)
	return items, count
end)

-- ============================================================
-- Constants
-- ============================================================

local ACTIVITY_MISSION          = "mission"
local ACTIVITY_MATCHMAKING      = "matchmaking"
local ACTIVITY_HUB              = "hub"
local ACTIVITY_TRAINING_GROUNDS = "training_grounds"

local ONLINE_STATUSES = {
	online       = true,
	reconnecting = true,
}

-- Per-event-type colors: { line_color {a,r,g,b}, bg_color {a,r,g,b} }
local NOTIF_COLORS = {
	online           = { { 255, 100, 220, 120 }, { 160,  15,  40,  20 } },
	offline          = { { 255, 130, 130, 130 }, { 160,  25,  25,  25 } },
	mission          = { { 255, 240, 150,  60 }, { 160,  55,  35,  10 } },
	mission_end      = { { 255, 140, 175, 220 }, { 160,  20,  30,  50 } },
	matchmaking      = { { 255, 120, 140, 220 }, { 160,  20,  25,  55 } },
	hub              = { { 255,  60, 200, 185 }, { 160,  10,  50,  45 } },
	training_grounds = { { 255, 200, 220,  80 }, { 160,  45,  50,  10 } },
	friend_request   = { { 255, 200, 100, 220 }, { 160,  45,  15,  55 } },
}

-- ============================================================
-- State
-- ============================================================

local _friend_states     = {}   -- [account_id] = { online, activity }
local _portrait_cache    = {}   -- [account_id] = load_id; preloaded portraits for online friends
local _poll_timer        = 0
local _poll_interval     = 10  -- cached from settings; updated in on_setting_changed

-- Notification enable flags — cached to avoid mod:get() on every presence event.
local _notify_online          = true
local _notify_offline         = false
local _notify_mission_start   = true
local _notify_mission_end     = false
local _notify_matchmaking     = true
local _notify_hub             = true
local _notify_training        = false
local _notify_friend_request  = true
local _skip_party_members     = true
local _skip_platform_friends  = true
local _use_allowlist          = false
local _known_invites     = nil    -- [account_id] = true; nil while seeding; seeded by seed_invites()
local _events_registered = false
local _seeding           = false  -- true while the initial seed poll is in-flight
local _initial_seed      = false  -- true only for the very first seed after on_all_mods_loaded; gates post-seed online summary
local _pending_online    = {}   -- [account_id] = { name, deadline } — online notifications deferred until character profile arrives
local _in_gameplay       = false  -- true only while GameplayStateRun is active (HUD is available)
local _in_game_session   = {}   -- [account_id] = true for friends confirmed in the same game instance this session

-- ============================================================
-- Hook: extend "custom" notification type to support player portraits.
-- _generate_notification_data strips unknown fields for "custom", so
-- use_player_portrait and player never reach the portrait-loading code.
-- This hook re-adds them after the original runs.
-- ============================================================

mod:hook(NotifFeed, "_generate_notification_data", function(original, self, message_type, data)
	local notification_data = original(self, message_type, data)
	if notification_data and message_type == "custom" and data.player and data.use_player_portrait then
		notification_data.player              = data.player
		notification_data.use_player_portrait = true
	end
	return notification_data
end)

-- ============================================================
-- Platform icon colorization
-- ============================================================
-- Applied at notification display time only, so the shared PlayerInfo.platform_icon
-- API returns raw glyphs to other mods (e.g. who_are_you) without interference.

local GLYPH_GLOBE = "\238\129\175"
local GLYPH_STEAM = "\238\129\171"  -- raw glyph; returned by FriendSteam.platform_icon
local GLYPH_XBOX  = "\238\129\172"  -- raw glyph; returned by FriendXboxLive.platform_icon (offline path)
local GLYPH_PSN   = "\238\129\177"  -- raw glyph; may be returned by other mods (e.g. who_are_you hook_origin)

local ICON_STEAM = "{#color(255,255,255)}\238\129\171{#reset()}"
local ICON_XBOX  = "{#color(16,124,16)}\238\129\172{#reset()}"
local ICON_PSN   = "{#color(0,112,209)}\238\129\177{#reset()}"

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

-- Resolves a raw icon glyph to a colored rich-text string for notification display.
local function colorize_platform_icon(raw_icon)
	if not raw_icon or raw_icon == "" then return "" end
	if raw_icon == GLYPH_STEAM then
		return ICON_STEAM
	elseif raw_icon == GLYPH_XBOX then
		return ICON_XBOX
	elseif raw_icon == GLYPH_PSN then
		return ICON_PSN
	end
	-- Already colored (e.g. same-platform PSN from vanilla code), or unknown — pass through.
	return raw_icon
end

-- Hook PlayerInfo.platform_icon to return colored rich-text icons globally.
-- This fixes the social page, who_are_you display, and our own notifications.
-- Key addition vs the original: GLYPH_GLOBE is now resolved to the friend's actual
-- platform before colorizing, fixing offline cross-platform friends and hub players
-- whose immaterium entry has an empty platform field (e.g. who_are_you hook_origin
-- ignores the in_platform fallback, so those would otherwise stay as a globe).
-- Note: when a name is truly "N/A", platform_icon() returns nil (no presence, no
-- platform_social), so no icon is prepended and who_are_you's is_unknown() is unaffected.
mod:hook(PlayerInfo, "platform_icon", function(func, self)
	local icon, color = func(self)
	if icon == GLYPH_GLOBE then
		-- Globe means cross-platform with unresolved platform field; infer the actual
		-- platform. Do NOT call resolve_platform for GLYPH_STEAM/GLYPH_XBOX: those are
		-- already identified correctly by the original function, and on Xbox clients
		-- gamertags have no #NNNN suffix so the heuristic would wrongly return "psn".
		local platform = resolve_platform(self)
		if platform == "steam" then
			return ICON_STEAM, true
		elseif platform == "xbox" then
			return ICON_XBOX, true
		elseif platform == "psn" then
			return ICON_PSN, true
		end
	elseif icon == GLYPH_STEAM then
		return ICON_STEAM, true
	elseif icon == GLYPH_XBOX then
		return ICON_XBOX, true
	elseif icon == GLYPH_PSN then
		return ICON_PSN, true
	end
	return icon, color
end)

-- ============================================================
-- Game-session membership tracking
-- ============================================================
-- PlayerInfo._is_party_member is set by SocialService whenever a human player
-- enters (or leaves) the local player's current game instance.  We hook the
-- setter so that — regardless of polling timing — we always learn which friends
-- shared a game session with us.  The set is cleared on GameplayStateRun exit
-- so it never bleeds across sessions.

mod:hook_safe(PlayerInfo, "set_is_party_member", function(self, is_member)
	if is_member then
		local account_id = self:account_id()
		if account_id and account_id ~= "" then
			_in_game_session[account_id] = true
		end
	end
end)

-- ============================================================
-- Portrait preloading
-- ============================================================
-- Portraits are loaded asynchronously (5-frame render pipeline + async package load).
-- We start loading as soon as a friend comes online so the texture is already in the
-- render target atlas by the time a notification fires — avoiding the frame hitch that
-- would occur if we triggered loading at display time.

local function preload_portrait(player_info, account_id)
	if not Managers.ui then return end
	if _portrait_cache[account_id] then return end  -- already in flight or done
	local profile = player_info:profile()
	if not profile then return end
	_portrait_cache[account_id] = Managers.ui:load_profile_portrait(profile, function() end)
end

local function unload_portrait(account_id)
	local load_id = _portrait_cache[account_id]
	if load_id and Managers.ui then
		Managers.ui:unload_profile_portrait(load_id)
	end
	_portrait_cache[account_id] = nil
end

local function unload_all_portraits()
	if Managers.ui then
		for _, load_id in pairs(_portrait_cache) do
			Managers.ui:unload_profile_portrait(load_id)
		end
	end
	_portrait_cache = {}
end

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
	local display = player_info:user_display_name(false, true)
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

	local profile = player_info:profile()
	local line1, line2

	if profile then
		-- Line 1: archetype icon + character name
		local char_name = (profile.name and profile.name ~= "") and profile.name or friendly_name(player_info)
		local archetype_name = profile.archetype and profile.archetype.archetype_name
		-- archetype_name is a loc key like "loc_class_psyker_name"; extract the identifier.
		local archetype_id = archetype_name and archetype_name:match("^loc_class_(.+)_name$")
		local arch_icon = archetype_id and UISettings.archetype_font_icon_simple[archetype_id] or ""
		line1 = arch_icon ~= "" and (arch_icon .. " " .. char_name) or char_name

		-- Line 2: display name (includes colored platform icon from our platform_icon hook) + body.
		-- user_display_name(false, false) recomputes fresh and prepends platform_icon() internally,
		-- which our hook already colorizes — no manual icon prepend needed.
		local display = player_info:user_display_name(false, false)
		if not display or display == "" or display == "N/A" then
			display = "Unknown"
		end
		line2 = display .. " " .. body

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
		data.player              = player_info
		data.use_player_portrait = true
	end
	Managers.event:trigger("event_add_notification_message", "custom", data)
end

-- ============================================================
-- Suppression logic
-- ============================================================

-- Returns true if notifications for this friend should be silenced.
-- When use_notification_allowlist is ON: suppress everyone not on the
-- allowlist (the allowlist overrides skip_platform_friends).
-- When OFF: fall back to the skip_platform_friends setting.
local function should_suppress(player_info)
	if _skip_party_members then
		local ps = player_info:party_status()
		if ps == PartyStatus.mine or ps == PartyStatus.same_mission then
			return true
		end
		-- Also suppress if the friend was confirmed in the same game instance this
		-- session (tracked via set_is_party_member hook).  party_status() may already
		-- have reverted to "none"/"other" by the time an event fires (e.g. a friend
		-- leaving the mission clears _is_party_member before the event arrives), so
		-- we keep our own record for the duration of the current GameplayStateRun.
		local account_id = player_info:account_id()
		if account_id and _in_game_session[account_id] then
			return true
		end
	end
	if _use_allowlist then
		return not allowlist.is_allowlisted(player_info)
	end
	return _skip_platform_friends
		and player_info:platform_friend_status() == FriendStatus.friend
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
		if new_online then preload_portrait(player_info, account_id) end
		if not _seeding and new_online and _notify_online then
			local suppress = should_suppress(player_info)
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
	-- Only fire activity notifications when the friend was already online before
	-- this update.  Guarding on prev.online prevents a spurious hub/mission
	-- notification from firing alongside the "came online" notification when a
	-- friend first appears with an activity already set.
	local activity_changed = new_online and prev.online and new_activity ~= prev.activity

	if online_changed or activity_changed then
		mod:info("[SN:%s] diff via %s — online %s->%s  activity %s->%s (last_update %s->%s)",
			short_id, source or "?",
			tostring(prev.online), tostring(new_online),
			tostring(prev.activity), tostring(new_activity),
			tostring(prev.last_update), tostring(new_last_update))
	end

	-- Update state before notifying so that any re-entrant event fired during
	-- show_notification sees the already-committed new state and produces no diff.
	local prev_activity = prev.activity
	prev.online       = new_online
	prev.activity     = new_activity
	prev.last_update  = new_last_update

	-- Preload portrait on every update while online — not just on first-sight/online_changed.
	-- If profile() was nil on the first attempt, _portrait_cache stays nil so we retry here
	-- until the profile arrives, ensuring it's ready before any notification fires.
	if new_online then
		preload_portrait(player_info, account_id)
	elseif online_changed then
		unload_portrait(account_id)
	end

	-- Auto-invite fires on hub arrival regardless of notification suppression.
	if activity_changed and new_activity == ACTIVITY_HUB then
		autoinvite.on_hub_arrival(player_info)
	end

	if (online_changed or activity_changed) and not should_suppress(player_info) then
		-- Online / offline transitions
		if online_changed then
			if new_online and _notify_online then
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
			elseif not new_online and _notify_offline then
				_pending_online[account_id] = nil  -- cancel any deferred online notif if they went offline first
				mod:info("[SN:%s] NOTIFY offline", short_id)
				show_notification(player_info, mod:localize("notif_offline_body"), NOTIF_COLORS.offline)
			end
		end

		-- Activity transitions (only meaningful while online)
		if activity_changed then
			if new_activity == ACTIVITY_MISSION and _notify_mission_start then
				mod:info("[SN:%s] NOTIFY mission", short_id)
				show_notification(player_info, mod:localize("notif_mission_body"), NOTIF_COLORS.mission)
			elseif prev_activity == ACTIVITY_MISSION and _notify_mission_end then
				mod:info("[SN:%s] NOTIFY mission_end", short_id)
				show_notification(player_info, mod:localize("notif_mission_end_body"), NOTIF_COLORS.mission_end)
			elseif new_activity == ACTIVITY_MATCHMAKING and _notify_matchmaking then
				mod:info("[SN:%s] NOTIFY matchmaking", short_id)
				show_notification(player_info, mod:localize("notif_matchmaking_body"), NOTIF_COLORS.matchmaking)
			elseif new_activity == ACTIVITY_HUB and _notify_hub then
				mod:info("[SN:%s] NOTIFY hub", short_id)
				show_notification(player_info, mod:localize("notif_hub_body"), NOTIF_COLORS.hub)
			elseif new_activity == ACTIVITY_TRAINING_GROUNDS and _notify_training then
				mod:info("[SN:%s] NOTIFY training_grounds", short_id)
				show_notification(player_info, mod:localize("notif_training_body"), NOTIF_COLORS.training_grounds)
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

		-- After the INITIAL seed poll: queue "came online" notifications for every friend
		-- who was already online when the mod first loaded. Stays silent during seeding
		-- to avoid false positives on startup; surfaces them via the deferred path once
		-- _in_gameplay is true. Only runs for the first seed (on_all_mods_loaded), NOT
		-- for re-seeds triggered by map transitions — those would fire spurious online
		-- notifications for friends who are already known-online mid-session.
		if was_seeding and _initial_seed then
			_initial_seed = false
			for account_id, state in pairs(_friend_states) do
				if state.online and not _pending_online[account_id] and _notify_online then
					local pi = social:get_player_info_by_account_id(account_id)
					if pi and pi:is_friend() then
						local suppress = should_suppress(pi)
						if not suppress then
							mod:info("[SN:%s] online deferred post-seed (waiting for HUD)", account_id:sub(-6))
							_pending_online[account_id] = { deadline = now + 120 }
						end
					end
				end
			end
		end

		-- Every poll: flush pending notifications where the character profile has now arrived.
		-- Only flush when _in_gameplay is true (GameplayStateRun active) — the HUD
		-- notification feed is not available during earlier states (loading, char select).
		if _in_gameplay then
			for account_id, pending in pairs(_pending_online) do
				local pi = social:get_player_info_by_account_id(account_id)
				if pi then
					if pi:character_name() ~= "" or now >= pending.deadline then
						_pending_online[account_id] = nil
						if _notify_online then
							mod:info("[SN:%s] NOTIFY online (poll flush, char=%s)", account_id:sub(-6), tostring(pi:character_name() ~= ""))
							show_notification(pi, mod:localize("notif_online_body"), NOTIF_COLORS.online)
						end
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
	-- Only flush when the HUD is available (_in_gameplay); otherwise keep deferring.
	local is_friend = player_info:is_friend()

	local pending = _pending_online[account_id]
	if pending and _in_gameplay and is_friend then
		local char_name = player_info:character_name()
		local now = Managers.time and Managers.time:time("main") or 0
		if char_name ~= "" or now >= pending.deadline then
			_pending_online[account_id] = nil
			if _notify_online then
				mod:info("[SN:%s] NOTIFY online (deferred flush, char=%s deadline=%s)",
					account_id:sub(-6), tostring(char_name ~= ""), tostring(now >= pending.deadline))
				show_notification(player_info, mod:localize("notif_online_body"), NOTIF_COLORS.online)
			end
		end
	end

	if is_friend then
		process_friend(player_info, "event")
	end
end

-- ============================================================
-- DMF callbacks
-- ============================================================

-- Populates _known_invites with the current set of pending incoming friend requests
-- so that subsequent backend_friend_invite events can diff against a baseline and
-- only notify for genuinely new requests. Called from reset_state().
local function seed_invites()
	local social = Managers.data_service and Managers.data_service.social
	if not social then
		_known_invites = {}
		return
	end
	social:fetch_friend_invites():next(function(invites)
		_known_invites = {}
		if not invites then return end
		for _, pi in ipairs(invites) do
			if pi:friend_status() == FriendStatus.invite then
				local id = pi:account_id()
				if id then _known_invites[id] = true end
			end
		end
	end)
end

-- Full reset: clears all state and re-seeds from scratch.
-- Used on mod load. Fires post-seed "online" notifications as an
-- initial presence summary (intentional on first load only).
local function reset_state()
	unload_all_portraits()
	_friend_states     = {}
	_pending_online    = {}
	_in_game_session   = {}
	_known_invites     = nil  -- cleared until seed_invites() completes
	_poll_timer        = 0
	_seeding           = true
	_initial_seed      = true
	_in_gameplay       = false
	poll_friends()    -- seeds _friend_states without notifying; clears _seeding when done
	seed_invites()    -- seeds _known_invites silently so first backend_friend_invite can diff
end

-- Soft reset: keeps _friend_states intact so the diff stays valid across
-- map transitions. Only resets the poll timer and triggers a fresh poll (silently,
-- since _seeding remains false and _friend_states already has baselines).
local function soft_reset()
	_poll_timer = 0
	poll_friends()
end

mod._on_party_invite_canceled = function(self, ...)
	autoinvite.on_party_invite_canceled(...)
end

-- ============================================================
-- Event: incoming friend request
-- Fires when the backend sends a friend invite. We diff against
-- _known_invites (seeded on load) so we only notify for new requests.
-- ============================================================

mod._on_friend_invite = function(self, data)
	if not _notify_friend_request then return end
	if _known_invites == nil then return end  -- still seeding; skip to avoid false positives
	local social = Managers.data_service and Managers.data_service.social
	if not social then return end
	social:fetch_friend_invites():next(function(invites)
		if not invites then return end
		for _, pi in ipairs(invites) do
			if pi:friend_status() == FriendStatus.invite then
				local account_id = pi:account_id()
				if account_id and not _known_invites[account_id] then
					_known_invites[account_id] = true
					mod:info("[SN] NOTIFY friend_request from %s", account_id:sub(-6))
					show_notification(pi, mod:localize("notif_friend_request_body"), NOTIF_COLORS.friend_request)
				end
			end
		end
	end)
end

mod.on_unload = function()
	unload_all_portraits()
	if Managers.event then
		Managers.event:unregister(mod, "event_new_immaterium_entry")
		Managers.event:unregister(mod, "party_immaterium_invite_canceled")
		Managers.event:unregister(mod, "backend_friend_invite")
	end
	_events_registered = false
end

mod.on_all_mods_loaded = function()
	_poll_interval          = mod:get("poll_interval") or 10
	_notify_online          = mod:get("notify_online")
	_notify_offline         = mod:get("notify_offline")
	_notify_mission_start   = mod:get("notify_mission_start")
	_notify_mission_end     = mod:get("notify_mission_end")
	_notify_matchmaking     = mod:get("notify_matchmaking")
	_notify_hub             = mod:get("notify_hub")
	_notify_training        = mod:get("notify_training")
	_notify_friend_request  = mod:get("notify_friend_request")
	_skip_party_members     = mod:get("skip_party_members")
	_skip_platform_friends  = mod:get("skip_platform_friends")
	_use_allowlist          = mod:get("use_notification_allowlist")
	if not _events_registered then
		Managers.event:register(mod, "event_new_immaterium_entry", "_on_immaterium_entry")
		Managers.event:register(mod, "party_immaterium_invite_canceled", "_on_party_invite_canceled")
		Managers.event:register(mod, "backend_friend_invite", "_on_friend_invite")
		_events_registered = true
	end
	reset_state()
end

mod.on_game_state_changed = function(status, state_name)
	if state_name == "GameplayStateRun" then
		_in_gameplay = (status == "enter")
		if status == "exit" then
			-- Clear cached states before the session teardown sends offline presence
			-- updates for all friends in the session.  Without this, every friend who
			-- was "online" in _friend_states gets diffed against their temporarily-offline
			-- presence entry and fires a spurious offline notification.
			-- soft_reset on StateMainMenu entry will re-seed from the new baseline.
			unload_all_portraits()
			_friend_states     = {}
			_pending_online    = {}
			_in_game_session   = {}
			_seeding           = true
		end
	end
	if status == "enter" and (state_name == "GameplayStateRun" or state_name == "StateMainMenu") then
		-- Re-seed from the current baseline; _seeding is already true when coming
		-- from a GameplayStateRun exit so poll_friends will be silent.
		soft_reset()
	end
end

mod.on_setting_changed = function(setting_id)
	if setting_id == "poll_interval" then
		_poll_interval = mod:get("poll_interval") or 10
	elseif setting_id == "notify_online" then
		_notify_online = mod:get("notify_online")
	elseif setting_id == "notify_offline" then
		_notify_offline = mod:get("notify_offline")
	elseif setting_id == "notify_mission_start" then
		_notify_mission_start = mod:get("notify_mission_start")
	elseif setting_id == "notify_mission_end" then
		_notify_mission_end = mod:get("notify_mission_end")
	elseif setting_id == "notify_matchmaking" then
		_notify_matchmaking = mod:get("notify_matchmaking")
	elseif setting_id == "notify_hub" then
		_notify_hub = mod:get("notify_hub")
	elseif setting_id == "notify_training" then
		_notify_training = mod:get("notify_training")
	elseif setting_id == "notify_friend_request" then
		_notify_friend_request = mod:get("notify_friend_request")
	elseif setting_id == "skip_party_members" then
		_skip_party_members = mod:get("skip_party_members")
	elseif setting_id == "skip_platform_friends" then
		_skip_platform_friends = mod:get("skip_platform_friends")
	elseif setting_id == "use_notification_allowlist" then
		_use_allowlist = mod:get("use_notification_allowlist")
	end
end

mod.update = function(dt)
	_poll_timer = _poll_timer + dt
	if _poll_timer >= _poll_interval then
		_poll_timer = 0
		poll_friends()
	end
end

-- ============================================================
-- Cross-platform display fixes
-- ============================================================
-- The game stores Xbox gamertags with a "#NNNN" suffix (e.g. "SafePunjabi#3244").
-- The hook below strips that suffix from user_display_name for cleaner display.

-- DEV_ONLY_START
-- ============================================================
-- Test commands: /social_test, /social_multi_test
-- Both call show_notification() directly so they exercise the real
-- notification path rather than duplicating its logic.
-- ============================================================

local function _get_own_info()
	local local_player = Managers.player and Managers.player:local_player(1)
	if not local_player then return nil, "local player not available" end
	local social = Managers.data_service and Managers.data_service.social
	if not social then return nil, "social service not available" end
	local own_info = social:get_player_info_by_account_id(local_player:account_id())
	if not own_info then return nil, "own player_info not available" end
	return own_info
end

-- /social_test — fires one real online notification for yourself using your actual
-- platform icon, character portrait, and display name.
mod:command("social_test", "Fire a real 'online' notification through show_notification() using your own player_info", function()
	local own_info, err = _get_own_info()
	if not own_info then
		mod:notify("social_test: " .. err)
		return
	end
	show_notification(own_info, mod:localize("notif_online_body"), NOTIF_COLORS.online)
end)

-- /social_multi_test — fires three online notifications, one per platform (Steam,
-- Xbox, PSN). Each uses a lightweight proxy that overrides only platform_icon() to
-- return the spoofed raw glyph; show_notification() then runs its real code path
-- (colorize_platform_icon, user_display_name, portrait, etc.) unmodified.
-- The DMF hook on PlayerInfo.platform_icon is intentionally bypassed by the proxy
-- so we test colorize_platform_icon directly with each raw glyph value.
mod:command("social_multi_test", "Fire three 'online' notifications through show_notification() with spoofed Steam/Xbox/PSN icons", function()
	local own_info, err = _get_own_info()
	if not own_info then
		mod:notify("social_multi_test: " .. err)
		return
	end

	local platforms = {
		{ glyph = GLYPH_STEAM, label = "Steam" },
		{ glyph = GLYPH_XBOX,  label = "Xbox"  },
		{ glyph = GLYPH_PSN,   label = "PSN"   },
	}

	for i = #platforms, 1, -1 do
		local p = platforms[i]
		local glyph = p.glyph
		-- Proxy: overrides platform_icon() and user_display_name() to inject the spoofed
		-- platform glyph. user_display_name must also be overridden because show_notification
		-- calls it directly (which would otherwise delegate to own_info's real platform_icon).
		local proxy = setmetatable({}, {
			__index = function(_, key)
				if key == "platform_icon" then
					return function(_self) return glyph end
				end
				if key == "user_display_name" then
					return function(_self, use_stale, no_icon)
						local name = own_info:user_display_name(use_stale, true)
						if no_icon then return name end
						return colorize_platform_icon(glyph) .. " " .. name
					end
				end
				local val = own_info[key]
				if type(val) == "function" then
					return function(_self, ...) return val(own_info, ...) end
				end
				return val
			end,
		})
		show_notification(proxy, mod:localize("notif_online_body"), NOTIF_COLORS.online)
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
-- ============================================================
-- Test command: /social_test_full
-- Finds the friend with platform_user_id 011000010027da2a and fires
-- all four notification types: online, hub, matchmaking, mission.
-- ============================================================

mod:command("social_test_full", "Fire all notification types for friend 011000010027da2a", function()
	local TARGET_PUID = "011000010027da2a"
	local social = Managers.data_service and Managers.data_service.social
	if not social then
		mod:notify("social_test_full: social service not available")
		return
	end

	social:fetch_friends():next(function(friends)
		if not friends then
			mod:notify("social_test_full: no friend list returned")
			return
		end

		local target = nil
		for _, pi in ipairs(friends) do
			if pi:platform_user_id() == TARGET_PUID then
				target = pi
				break
			end
		end

		if not target then
			mod:notify("social_test_full: friend " .. TARGET_PUID .. " not found")
			return
		end

		show_notification(target, mod:localize("notif_mission_body"),     NOTIF_COLORS.mission)
		show_notification(target, mod:localize("notif_matchmaking_body"), NOTIF_COLORS.matchmaking)
		show_notification(target, mod:localize("notif_hub_body"),         NOTIF_COLORS.hub)
		show_notification(target, mod:localize("notif_online_body"),      NOTIF_COLORS.online)
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
