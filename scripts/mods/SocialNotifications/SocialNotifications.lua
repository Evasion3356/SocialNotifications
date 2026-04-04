local mod = get_mod("SocialNotifications")

-- ============================================================
-- Constants (mirrors game source)
-- ============================================================

local ACTIVITY_MISSION      = "mission"
local ACTIVITY_MATCHMAKING  = "matchmaking"
local ACTIVITY_HUB          = "hub"

-- OnlineStatus values from SocialConstants:
--   "offline", "platform_online", "online", "reconnecting"
local ONLINE_STATUSES = {
	online       = true,
	reconnecting = true,
}

-- ============================================================
-- State
-- ============================================================

local _friend_states   = {}   -- [account_id] = { online, activity_id }
local _poll_timer      = 0
local _initialized     = false

-- ============================================================
-- Helpers
-- ============================================================

local function is_online(online_status)
	return ONLINE_STATUSES[online_status] == true
end

local function notify(text)
	-- DMF generic notification.  Replace with a richer HUD widget later.
	mod:notify(text)
end

local function player_label(player_info)
	-- Prefer display name; fall back to character name.
	local name = player_info:user_display_name(true, true)
	if not name or name == "" or name == "N/A" then
		name = player_info:character_name()
	end
	return name ~= "" and name or "Unknown"
end

-- ============================================================
-- Core: diff a single friend's state and fire notifications
-- ============================================================

local function process_friend(player_info)
	local account_id = player_info:account_id()
	if not account_id then return end

	local new_online   = is_online(player_info:online_status(true))
	local new_activity = player_info:player_activity_id()

	local prev = _friend_states[account_id]

	-- First time we see this friend — seed state without notifying.
	if not prev then
		_friend_states[account_id] = { online = new_online, activity = new_activity }
		return
	end

	local label = player_label(player_info)

	-- Online / offline transitions
	if new_online ~= prev.online then
		if new_online and mod:get("notify_online") then
			notify(string.format(mod:localize("notif_online"), label))
		elseif not new_online and mod:get("notify_offline") then
			notify(string.format(mod:localize("notif_offline"), label))
		end
	end

	-- Activity transitions (only meaningful while online)
	if new_online and new_activity ~= prev.activity then
		if new_activity == ACTIVITY_MISSION and mod:get("notify_mission_start") then
			notify(string.format(mod:localize("notif_mission"), label))
		elseif prev.activity == ACTIVITY_MISSION and mod:get("notify_mission_end") then
			notify(string.format(mod:localize("notif_mission_end"), label))
		elseif new_activity == ACTIVITY_MATCHMAKING and mod:get("notify_matchmaking") then
			notify(string.format(mod:localize("notif_matchmaking"), label))
		elseif new_activity == ACTIVITY_HUB and mod:get("notify_hub") then
			notify(string.format(mod:localize("notif_hub"), label))
		end
	end

	-- Update stored state
	prev.online   = new_online
	prev.activity = new_activity
end

-- ============================================================
-- Poll
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
		_initialized = true
	end)
end

-- ============================================================
-- DMF callbacks
-- ============================================================

mod.on_all_mods_loaded = function()
	_friend_states = {}
	_poll_timer    = 0
	_initialized   = false
	-- Seed initial state immediately (no notifications on first load).
	poll_friends()
end

mod.on_game_state_changed = function(status, state_name)
	-- Re-seed when entering gameplay so we don't spam on map transitions.
	if status == "enter" and (state_name == "GameplayStateRun" or state_name == "StateMainMenu") then
		_friend_states = {}
		_poll_timer    = 0
		_initialized   = false
		poll_friends()
	end
end

mod.update = function(dt)
	_poll_timer = _poll_timer + dt
	local interval = mod:get("poll_interval") or 10
	if _poll_timer >= interval then
		_poll_timer = 0
		poll_friends()
	end
end
