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

local _watched      = {}   -- [platform_user_id] = player_info
local _invite_sent  = {}   -- [platform_user_id] = true while an invite is in-flight
                           -- Guards against sending duplicates before party_status() updates
                           -- asynchronously to reflect the pending invite.

local function is_watching(player_info)
	local puid = player_info:platform_user_id()
	return puid ~= "" and _watched[puid] ~= nil
end

-- ============================================================
-- Auto-invite logic
-- ============================================================

-- Attempt to send a party invite to a single watched friend.
-- Silently skips if conditions aren't met (not in hub, invite pending, etc.).
-- Pass skip_pending_check=true when calling after an invite timeout, because
-- party_status() may still transiently return invite_pending at that moment.
local function try_invite(player_info, skip_pending_check)
	local puid         = player_info:platform_user_id()
	local party_status = player_info:party_status()

	if party_status == PartyStatus.mine then
		-- They joined — stop watching
		_watched[puid]     = nil
		_invite_sent[puid] = nil
		return
	end

	local online_status = player_info:online_status(true)
	local activity_id   = player_info:player_activity_id()

	if online_status == OnlineStatus.offline
		or online_status == OnlineStatus.platform_online
		or activity_id ~= ACTIVITY_HUB
		or (not skip_pending_check and party_status == PartyStatus.invite_pending)
		or _invite_sent[puid] then
		return
	end

	local social = Managers.data_service and Managers.data_service.social
	if not social then return end

	-- When skip_pending_check is true we already know the previous invite expired,
	-- so party_status may still transiently read invite_pending — bypass can_invite_to_party
	-- (which has the same internal check) and send directly.
	local ok_to_send = skip_pending_check or social:can_invite_to_party(player_info)
	if ok_to_send then
		mod:info("[SN:autoinvite] sending invite to %s", puid:sub(-6))
		_invite_sent[puid] = true
		social:send_party_invite(player_info)
	end
end

local function toggle_watch(player_info)
	local puid = player_info:platform_user_id()
	if puid == "" then return end

	if _watched[puid] then
		_watched[puid]     = nil
		_invite_sent[puid] = nil
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

-- Fired by the backend when an invite times out (no response from invitee).
-- Signature: invite_token, platform, platform_user_id, inviter_account_id
AutoInvite.on_party_invite_timeout = function(invite_token, platform, platform_user_id, inviter_account_id)
	local my_id = Managers.backend and Managers.backend:account_id()
	if inviter_account_id ~= my_id then return end

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

	mod:info("[SN:autoinvite] invite to %s timed out — resending", matched_puid:sub(-6))
	_invite_sent[matched_puid] = nil
	try_invite(matched_pi, true)
end

-- Fired by the backend when an invite is canceled/declined.
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

	-- Detect an active decline vs. a system cancel (e.g. PARTY_FULL):
	--   Fatshark-only friends: platform_user_id doubles as account_id, so
	--     canceler_account_id == platform_user_id when they decline.
	--   Platform friends (Steam/Xbox/PSN): platform_user_id is the platform hex ID and
	--     canceler_account_id is their Fatshark UUID, so compare against account_id().
	-- Note: timeouts are handled separately via on_party_invite_timeout.
	local invitee_account_id = matched_pi:account_id()
	local declined = canceler_account_id == platform_user_id
		or (invitee_account_id and invitee_account_id ~= "" and canceler_account_id == invitee_account_id)
	-- Clear the in-flight flag so try_invite can send again (either a resend or a
	-- fresh invite next time they arrive in hub).
	_invite_sent[matched_puid] = nil

	if declined then
		mod:info("[SN:autoinvite] %s declined invite — removing from watch list", matched_puid:sub(-6))
		_watched[matched_puid] = nil
	else
		-- System cancel (e.g. party full, game session started) — resend
		mod:info("[SN:autoinvite] invite to %s system-canceled (answer=%s) — resending", matched_puid:sub(-6), tostring(answer_code))
		try_invite(matched_pi, true)
	end
end

return AutoInvite
