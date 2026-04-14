local mod = get_mod("SocialNotifications")

return {
	name        = mod:localize("mod_title"),
	description = mod:localize("mod_description"),
	version     = "1.2.0",
	is_togglable = true,
	options = {
		widgets = {
			{
				setting_id    = "notify_online",
				type          = "checkbox",
				default_value = true,
			},
			{
				setting_id    = "notify_offline",
				type          = "checkbox",
				default_value = false,
			},
			{
				setting_id    = "notify_mission_start",
				type          = "checkbox",
				default_value = true,
			},
			{
				setting_id    = "notify_mission_end",
				type          = "checkbox",
				default_value = false,
			},
			{
				setting_id    = "notify_matchmaking",
				type          = "checkbox",
				default_value = true,
			},
			{
				setting_id    = "notify_hub",
				type          = "checkbox",
				default_value = true,
			},
			{
				setting_id    = "notify_training",
				type          = "checkbox",
				default_value = false,
			},
			{
				setting_id    = "notify_friend_request",
				type          = "checkbox",
				default_value = true,
			},
			{
				setting_id    = "show_party_size",
				type          = "checkbox",
				default_value = false,
			},
			{
				setting_id    = "skip_party_members",
				type          = "checkbox",
				default_value = true,
			},
			{
				setting_id    = "skip_platform_friends",
				type          = "checkbox",
				default_value = true,
			},
			{
				setting_id    = "use_notification_allowlist",
				type          = "checkbox",
				default_value = false,
			},
			{
				setting_id    = "poll_interval",
				type          = "numeric",
				default_value = 10,
				range         = { 5, 60 },
			},
		},
	},
}
