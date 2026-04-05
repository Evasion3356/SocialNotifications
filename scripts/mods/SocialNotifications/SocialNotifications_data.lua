local mod = get_mod("SocialNotifications")

return {
	name        = mod:localize("mod_title"),
	description = mod:localize("mod_description"),
	version     = "1.0.0",
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
				default_value = true,
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
				default_value = false,
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
				setting_id    = "auto_invite_interval",
				type          = "numeric",
				default_value = 30,
				range         = { 10, 120 },
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
