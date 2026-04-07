local mod = get_mod("SocialNotifications")

local SocialConstants  = mod:original_require("scripts/managers/data_service/services/social/social_constants")
local SocialPopup      = mod:original_require("scripts/ui/view_elements/view_element_player_social_popup/view_element_player_social_popup")

local OnlineStatus = SocialConstants.OnlineStatus
local PartyStatus  = SocialConstants.PartyStatus

local ACTIVITY_HUB = "hub"

-- ============================================================
-- Watched set
--
-- Key:   platform_user_id  (Steam ID / Xbox XUID / PSN ID)
--        Always populated from platform_social:id(), unlike
--        account_id which is nil until the friend authenticates
--        with the Fatshark backend in-game.
-- Value: player_info object reference — a live object whose
--        methods (online_status, party_status, etc.) always
--        reflect current state, so no secondary lookup needed.
--
-- Intentionally NOT cleared on map transitions — user intent persists.
-- ============================================================

local _watched = {}   -- [platform_user_id] = player_info

local function is_watching(player_info)
	local puid = player_info:platform_user_id()
	return puid ~= "" and _watched[puid] ~= nil
end

-- ============================================================
-- Auto-invite logic
-- ============================================================

-- Attempt to send a party invite to a single watched friend.
-- Silently skips if conditions aren't met (not in hub, invite pending, etc.).
local function try_invite(player_info)
	local party_status = player_info:party_status()

	if party_status == PartyStatus.mine then
		-- They joined — stop watching
		_watched[player_info:platform_user_id()] = nil
		return
	end

	local online_status = player_info:online_status(true)
	local activity_id   = player_info:player_activity_id()

	if online_status == OnlineStatus.offline
		or online_status == OnlineStatus.platform_online
		or activity_id ~= ACTIVITY_HUB
		or party_status == PartyStatus.invite_pending then
		return
	end

	local social = Managers.data_service and Managers.data_service.social
	if not social then return end

	local can_invite, _ = social:can_invite_to_party(player_info)
	if can_invite then
		mod:info("[SN:autoinvite] sending invite to %s", player_info:platform_user_id():sub(-6))
		social:send_party_invite(player_info)
	end
end

local function toggle_watch(player_info)
	local puid = player_info:platform_user_id()
	if puid == "" then return end

	if _watched[puid] then
		_watched[puid] = nil
	else
		_watched[puid] = player_info
		-- Immediately attempt an invite in case they're already in hub
		try_invite(player_info)
	end
end

-- ============================================================
-- Hook: capture the popup element instance so the toggle callback
-- can directly mutate _menu_widgets[1].content.text in-place.
-- ============================================================

mod:hook(SocialPopup, "set_player_info", function(original, self, parent, player_info)
	mod._current_social_popup = self
	return original(self, parent, player_info)
end)

-- ============================================================
-- Module interface
-- ============================================================

local AutoInvite = {}

-- Inject "Auto-invite" toggle into the social popup item list.
-- Called from the single combined from_player_info hook in SocialNotifications.lua.
-- Prepends button + divider so the toggle appears at the top of the menu.
-- Key: use platform_user_id(), not account_id() — Steam friends who are offline
-- have no account_id but always have a platform_user_id.
AutoInvite.inject_items = function(items, count, player_info)
	if player_info:is_own_player() or player_info:is_blocked() then
		return items, count
	end

	local puid = player_info:platform_user_id()
	if not puid or puid == "" then
		return items, count
	end

	-- Prepend: button at position 1, divider at position 2.
	-- table.insert shifts all existing entries down.
	table.insert(items, 1, {
		blueprint = "button",
		label     = is_watching(player_info)
			and mod:localize("auto_invite_on")
			or  mod:localize("auto_invite_off"),
		callback  = function()
			toggle_watch(player_info)
			-- Update the button label in-place: our button is always at index 1.
			-- Avoids the full fade-out/rebuild/fade-in cycle.
			local widgets = mod._current_social_popup and mod._current_social_popup._menu_widgets
			if widgets and widgets[1] then
				widgets[1].content.text = is_watching(player_info)
					and mod:localize("auto_invite_on")
					or  mod:localize("auto_invite_off")
			end
		end,
	})

	table.insert(items, 2, {
		blueprint = "group_divider",
		label     = "sn_autoinvite_divider",
	})

	count = count + 2
	return items, count
end

-- Called by SocialNotifications.lua when a watched friend's activity transitions to hub.
AutoInvite.on_hub_arrival = function(player_info)
	if not is_watching(player_info) then return end
	try_invite(player_info)
end

-- Fired by the backend when an invite is canceled/declined/timed-out.
-- Signature: invite_token, platform, platform_user_id, inviter_account_id,
--            canceler_account_id, answer_code
-- The invitee declined when canceler_account_id identifies them — but the ID
-- format differs by friend type:
--   Fatshark-only friends: platform == "" and platform_user_id IS their account_id,
--     so canceler_account_id == platform_user_id when they decline.
--   Steam/Xbox/PSN friends: platform_user_id is the platform ID (e.g. Steam hex),
--     canceler_account_id is their Fatshark account_id — different values.
-- We handle both by accepting either match.
AutoInvite.on_party_invite_canceled = function(invite_token, platform, platform_user_id, inviter_account_id, canceler_account_id, answer_code)
	local my_id = Managers.backend and Managers.backend:account_id()
	if inviter_account_id ~= my_id then return end

	-- Find the watched friend this invite was for.
	-- Primary lookup: direct key match (works for Steam and Fatshark-only friends).
	-- Fallback: search by Fatshark account_id (needed for Xbox, whose _watched key is
	-- the Xbox hex ID but the event platform_user_id is the Fatshark UUID).
	local matched_puid = nil
	local matched_pi   = nil
	if _watched[platform_user_id] then
		matched_puid = platform_user_id
		matched_pi   = _watched[platform_user_id]
	else
		for puid, pi in pairs(_watched) do
			if pi:account_id() == platform_user_id then
				matched_puid = puid
				matched_pi   = pi
				break
			end
		end
	end

	if not matched_puid then return end

	-- canceler_account_id == platform_user_id means the invitee actively declined.
	-- Any other canceler (empty, our own ID, etc.) means a timeout or system cancel —
	-- resend the invite so the user doesn't have to re-trigger manually.
	if canceler_account_id == platform_user_id then
		mod:info("[SN:autoinvite] %s declined invite — removing from watch list", matched_puid:sub(-6))
		_watched[matched_puid] = nil
	else
		mod:info("[SN:autoinvite] invite to %s timed out — resending", matched_puid:sub(-6))
		try_invite(matched_pi)
	end
end

return AutoInvite
