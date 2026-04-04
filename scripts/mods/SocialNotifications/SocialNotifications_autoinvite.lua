local mod = get_mod("SocialNotifications")

local SocialConstants = mod:original_require("scripts/managers/data_service/services/social/social_constants")
local ContentList     = mod:original_require("scripts/ui/view_elements/view_element_player_social_popup/view_element_player_social_popup_content_list")

local OnlineStatus = SocialConstants.OnlineStatus
local PartyStatus  = SocialConstants.PartyStatus

local ACTIVITY_MISSION = "mission"

-- ============================================================
-- Watched accounts
-- [account_id] = true when the user has checked "auto-invite"
-- Intentionally NOT cleared on map transitions — the user set it.
-- ============================================================

local _watched = {}

local function is_watching(account_id)
	return _watched[account_id] == true
end

local function toggle_watch(account_id)
	if _watched[account_id] then
		_watched[account_id] = nil
	else
		_watched[account_id] = true
	end
end

-- ============================================================
-- Auto-invite loop
-- ============================================================

local _timer = 0

local function run_auto_invite()
	local social = Managers.data_service and Managers.data_service.social
	if not social then return end

	for account_id, _ in pairs(_watched) do
		local player_info = social:get_player_info_by_account_id(account_id)

		if player_info then
			local online_status = player_info:online_status(true)
			local activity_id   = player_info:player_activity_id()
			local party_status  = player_info:party_status()

			if party_status == PartyStatus.mine then
				-- Accepted — stop watching
				_watched[account_id] = nil

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
	end
end

-- ============================================================
-- Hook: inject "Auto-invite" checkbox into the social popup menu.
--
-- ViewElementPlayerSocialPopupContentList.from_player_info builds
-- the action list for the social popup (same menu as "Invite to
-- Strike Team").  It returns a reference to the shared _popup_menu_items
-- table plus the item count.  We append our toggle item to that table
-- and return the incremented count.
-- ============================================================

mod:hook(ContentList, "from_player_info", function(original, parent, player_info)
	local items, count = original(parent, player_info)

	if player_info:is_own_player() or player_info:is_blocked() then
		return items, count
	end

	local account_id = player_info:account_id()

	if not account_id or account_id == "" then
		return items, count
	end

	-- Helper: append one slot to the shared items table
	-- (mirrors the module-local _get_next_list_item pattern)
	local function next_item()
		count = count + 1
		local slot = items[count]

		if slot then
			table.clear(slot)
		else
			slot = {}
			items[count] = slot
		end

		return slot
	end

	-- Divider to visually separate our section
	local divider = next_item()
	divider.blueprint = "group_divider"
	divider.label     = "sn_autoinvite_divider"

	-- Checkbox-style toggle button
	local watching = is_watching(account_id)
	local btn      = next_item()
	btn.blueprint  = "button"
	btn.label      = watching
		and mod:localize("auto_invite_on")
		or  mod:localize("auto_invite_off")
	btn.callback   = function()
		toggle_watch(account_id)
	end

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
	-- _watched is intentionally preserved across resets
end

return AutoInvite
