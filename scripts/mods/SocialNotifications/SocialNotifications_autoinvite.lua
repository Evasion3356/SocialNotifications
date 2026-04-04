local mod = get_mod("SocialNotifications")

local SocialConstants  = mod:original_require("scripts/managers/data_service/services/social/social_constants")
local ContentList      = mod:original_require("scripts/ui/view_elements/view_element_player_social_popup/view_element_player_social_popup_content_list")
local SocialPopup      = mod:original_require("scripts/ui/view_elements/view_element_player_social_popup/view_element_player_social_popup")

local OnlineStatus = SocialConstants.OnlineStatus
local PartyStatus  = SocialConstants.PartyStatus

local ACTIVITY_MISSION = "mission"

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

local function toggle_watch(player_info)
	local puid = player_info:platform_user_id()
	if puid == "" then return end

	if _watched[puid] then
		_watched[puid] = nil
	else
		_watched[puid] = player_info
	end
end

-- ============================================================
-- Auto-invite loop
-- ============================================================

local _timer = 0

local function run_auto_invite()
	local social = Managers.data_service and Managers.data_service.social
	if not social then return end

	local to_remove = {}

	for puid, player_info in pairs(_watched) do
		local online_status = player_info:online_status(true)
		local activity_id   = player_info:player_activity_id()
		local party_status  = player_info:party_status()

		if party_status == PartyStatus.mine then
			-- Accepted — stop watching
			to_remove[#to_remove + 1] = puid

		elseif online_status == OnlineStatus.offline
			or online_status == OnlineStatus.platform_online
			or activity_id == ACTIVITY_MISSION then
			-- "wait" status: offline, not in-game, or mid-mission

		elseif party_status == PartyStatus.invite_pending then
			-- Invite already sent, don't spam

		else
			local can_invite, _ = social:can_invite_to_party(player_info)

			if can_invite then
				social:send_party_invite(player_info)
			end
		end
	end

	for i = 1, #to_remove do
		_watched[to_remove[i]] = nil
	end
end

-- ============================================================
-- Hook: capture the popup element instance so the toggle callback
-- can directly mutate _menu_widgets[1].content.text in-place.
-- ============================================================

local _current_popup = nil

mod:hook(SocialPopup, "set_player_info", function(original, self, parent, player_info)
	_current_popup = self
	return original(self, parent, player_info)
end)

-- ============================================================
-- Hook: inject "Auto-invite" checkbox into the social popup menu.
--
-- ViewElementPlayerSocialPopupContentList.from_player_info builds
-- the action list for the social popup (same menu as "Invite to
-- Strike Team").  It returns a reference to the shared _popup_menu_items
-- table plus the item count.  We prepend our toggle + divider so it
-- appears at the top of the menu.
--
-- Key fix: use platform_user_id(), not account_id().  Steam friends
-- who are not currently in Darktide have no account_id (Fatshark
-- backend ID only), but always have a platform_user_id (Steam ID).
-- ============================================================

mod:hook(ContentList, "from_player_info", function(original, parent, player_info)
	local items, count = original(parent, player_info)

	if player_info:is_own_player() or player_info:is_blocked() then
		return items, count
	end

	local puid = player_info:platform_user_id()

	if not puid or puid == "" then
		return items, count
	end

	-- Prepend: button at position 1, divider at position 2.
	-- table.insert shifts all existing entries down.
	local watching = is_watching(player_info)

	table.insert(items, 1, {
		blueprint = "button",
		label     = watching
			and mod:localize("auto_invite_on")
			or  mod:localize("auto_invite_off"),
		callback  = function()
			toggle_watch(player_info)
			-- Update the button label in-place: our button is always at index 1.
			-- Avoids the full fade-out/rebuild/fade-in cycle.
			local widgets = _current_popup and _current_popup._menu_widgets
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
end)

-- ============================================================
-- Module interface
-- ============================================================

local AutoInvite = {}

AutoInvite.update = function(dt)
	local interval = mod:get("auto_invite_interval") or 30
	_timer = _timer + dt

	if _timer >= interval then
		_timer = 0
		run_auto_invite()
	end
end

AutoInvite.reset_timer = function()
	_timer = 0
	-- _watched intentionally preserved across resets
end

return AutoInvite
