return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`SocialNotifications` encountered an error loading the Darktide Mod Framework.")

		new_mod("SocialNotifications", {
			mod_script       = "SocialNotifications/scripts/mods/SocialNotifications/SocialNotifications",
			mod_data         = "SocialNotifications/scripts/mods/SocialNotifications/SocialNotifications_data",
			mod_localization = "SocialNotifications/scripts/mods/SocialNotifications/SocialNotifications_localization",
		})
	end,
	packages = {},
}
