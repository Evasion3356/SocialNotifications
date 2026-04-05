# AGENTS.md — SocialNotifications

Context file for AI coding agents. Read this before making any changes.

## Project overview

**SocialNotifications** is a [Darktide Mod Framework (DMF)](../dmf/) mod for Warhammer 40,000: Darktide. It shows HUD notifications when Steam/platform friends change their in-game presence status — coming online, going offline, entering a mission, starting matchmaking, or returning to the Mourningstar hub.

## Repo layout

```
SocialNotifications/
├── AGENTS.md                              ← this file
├── CLAUDE.md                              ← points to AGENTS.md
├── GOAL.md                                ← design goals, API details, open work
├── SocialNotifications.mod                ← DMF entry point (loaded by the game)
├── Darktide-Source-Code/                  ← game source reference — READ ONLY, never modify
└── scripts/mods/SocialNotifications/
    ├── SocialNotifications.lua            ← main mod (poll loop, event handler, reset)
    ├── SocialNotifications_autoinvite.lua ← auto-invite loop + social popup hook
    ├── SocialNotifications_data.lua       ← DMF mod metadata + settings widgets
    └── SocialNotifications_localization.lua
```

The DMF framework lives at `../dmf/` (one directory up). Never modify it.

## DMF mod conventions

### Entry point
`SocialNotifications.mod` calls `new_mod("SocialNotifications", { mod_script, mod_data, mod_localization })`.  
Paths are relative to the `mods/` directory (i.e. `"SocialNotifications/scripts/mods/..."` not `"./scripts/..."`).

### Getting the mod handle
Every Lua file in the mod starts with:
```lua
local mod = get_mod("SocialNotifications")
```

### Lifecycle callbacks (defined on the `mod` table)
| Callback | When |
|----------|------|
| `mod.on_all_mods_loaded()` | All mods loaded; safe to call game APIs |
| `mod.on_game_state_changed(status, state_name)` | Game state transition (`"enter"`/`"exit"`) |
| `mod.update(dt)` | Every frame |
| `mod.on_setting_changed(setting_id)` | User changed a mod setting |

### Hooking game functions
```lua
mod:hook(ClassName, "method_name", function(func, self, ...)
    -- wraps the method; must call func(self, ...) to invoke original
end)
mod:hook_safe(ClassName, "method_name", function(self, ...)
    -- runs after the original; return value ignored
end)
mod:hook_origin(ClassName, "method_name", function(self, ...)
    -- replaces the original entirely
end)
```
Require game classes with `mod:original_require("scripts/path/to/class")`.

### Settings
- Declared in `SocialNotifications_data.lua` as `options.widgets` entries.
- Read at runtime: `mod:get("setting_id")` → value.
- Localization keys for setting labels live in `SocialNotifications_localization.lua`.

### Notifications
`mod:notify("some text")` — shows a basic DMF toast notification.  
For a styled HUD widget, see `../dmf/scripts/mods/dmf/modules/gui/` and `../dmf/scripts/mods/dmf/modules/ui/` as reference.

## Key game APIs

### Social service — `Managers.data_service.social`
Only available after `on_all_mods_loaded`.

| Method | Returns | Notes |
|--------|---------|-------|
| `fetch_friends(force?)` | `Promise<PlayerInfo[]>` | Cached; dirty flag causes re-fetch. Always call via `:next(cb)`. |
| `get_player_info_by_account_id(id)` | `PlayerInfo?` | Synchronous lookup. |

### `PlayerInfo` — `scripts/managers/data_service/services/social/player_info.lua`

| Method | Returns | Notes |
|--------|---------|-------|
| `account_id()` | string | Stable Fatshark ID — use as cache key. |
| `user_display_name(use_stale, no_icon)` | string | Platform persona name. Pass `true, true` for a plain string. |
| `character_name()` | string | In-game character name. Empty if blocked. |
| `online_status(use_stale?)` | string | `"offline"` `"platform_online"` `"online"` `"reconnecting"` |
| `player_activity_id()` | string? | `"hub"` `"mission"` `"matchmaking"` `"main_menu"` `"end_of_round"` `"loading"` `"training_grounds"` |
| `is_friend()` | bool | False if blocked. |
| `party_status()` | string | `"none"` `"mine"` `"same_mission"` `"other"` `"invite_pending"` |
| `num_party_members()` | int | Their current party size. |

Full activity list in `Darktide-Source-Code/scripts/settings/presence/presence_settings.lua`.

### Presence manager — `Managers.presence`
Lower-level than SocialService. `Managers.presence:get_presence(account_id)` → `PresenceEntryImmaterium` with `activity_id()`, `is_online()`, `character_profile()`, etc.

### Event bus — `Managers.event`
Register inside `on_all_mods_loaded` or a hook; unregister in a teardown hook if needed.

```lua
Managers.event:register(mod, "event_name", "callback_method_name")
-- mod must have a method named callback_method_name
```

Relevant events:

| Event | Fires when |
|-------|-----------|
| `event_new_immaterium_entry` | New presence entry created (friend came online / joined game) |
| `backend_friend_invite` | Received a friend request |
| `backend_friend_invite_accepted` | Outgoing invite accepted |
| `backend_friend_removed` | Friend removed |
| `party_immaterium_other_members_updated` | Party composition changed |

## Key game APIs (quick reference)

### Social popup hook
`ViewElementPlayerSocialPopupContentList.from_player_info(parent, player_info)` — module-level function; returns `(items_table, count)`. `items_table` is a shared reused table; valid entries are `[1..count]`. Hook with `mod:hook(ContentList, "from_player_info", function(original, parent, player_info) ... end)`. Append items by incrementing `count` and writing to `items[count]` (clear if exists). Each item needs `blueprint`, `label`, `callback`.

### Party invite
`Managers.data_service.social:send_party_invite(player_info)` — high-level invite; handles Fatshark + platform flows.
`Managers.data_service.social:can_invite_to_party(player_info)` → `(bool, reason?)` — checks offline, party full, cross-play, activity restrictions.

## Current implementation summary

`SocialNotifications.lua` uses a two-layer approach:

**Event-driven layer** — `mod._on_immaterium_entry` is registered for `event_new_immaterium_entry` (fires from `PresenceEntryImmaterium:update_with()` on every fresh presence update from the backend). It looks up the changed friend in `_friend_states` (populated by the poll) and calls `process_friend` immediately, giving near-instant online/offline notifications.

**Poll layer** — `mod.update(dt)` calls `poll_friends()` every `poll_interval` seconds (default 10s) via `fetch_friends():next(...)`. This seeds `_friend_states` on startup (silently, no notifications), catches activity changes (`hub` → `mission` → `matchmaking`), and handles friends who join after the event handler was registered.

**Diff + notify** — `process_friend(player_info)` diffs `online_status` and `player_activity_id` against cached state and triggers `event_add_notification_message` with type `"custom"`. Notifications show the friend's name as the header (line 1) and status as the body (line 2), with a color-coded left accent bar per event type.

> **WARNING — `line_2` does not render in-game.** The notification widget ignores the `line_2` field entirely. All text that must appear in the notification (character name, account name, status) must be packed into `line_1`, using `"\n"` as a separator. Do not attempt to move the account name (or any other text) from `line_1` to `line_2`.

**Color scheme** (`NOTIF_COLORS`):
- Online: green `{100, 220, 120}`
- Offline: gray `{130, 130, 130}`
- Mission: amber `{240, 150, 60}`
- Mission end: soft blue `{140, 175, 220}`
- Matchmaking: purple-blue `{120, 140, 220}`
- Hub: teal `{60, 200, 185}`

**State reset** — `reset_state()` clears `_friend_states` and re-runs the seed poll on `on_all_mods_loaded` and when entering `GameplayStateRun` / `StateMainMenu`, preventing stale transitions from firing spurious notifications across map loads.

### Auto-invite (`SocialNotifications_autoinvite.lua`)
Loaded via `mod:io_dofile(...)` at the top of `SocialNotifications.lua`. Two responsibilities:

**Loop** — `AutoInvite.update(dt)` runs every `auto_invite_interval` seconds. For each `_watched[account_id]`: if `PartyStatus.mine` → remove (accepted); if offline / `platform_online` / `activity == "mission"` / `invite_pending` → skip; otherwise call `can_invite_to_party` and `send_party_invite` if allowed.

**Hook** — `mod:hook(ContentList, "from_player_info", ...)` appends a divider + `[ON]/[OFF] Auto-invite to Strike Team` button to the social popup. Toggling calls `toggle_watch(account_id)`. The watched list is preserved across map transitions (user intent). `AutoInvite.reset_timer()` resets only the interval timer.

**skip_platform_friends does NOT affect auto-invite** — the user explicitly set the checkbox, so platform friendship is irrelevant.

## Planned work (see GOAL.md for detail)

1. **Roster-level checkbox** — visual checkbox in the friend roster row itself, not just the popup. Requires blueprint injection into `player_plaque` widget passes.
2. **Cross-session persistence** — persist `_watched` via DMF save data.
3. **Per-friend notification muting** — suppress presence notifications for specific friends.

## Coding guidelines

- Lua 5.1 (Darktide's embedded VM). No `//` comments, no `goto`, no integer division operator.
- Do not `require` game modules directly — use `mod:original_require(path)`.
- Paths passed to DMF APIs use forward slashes and are rooted at the `mods/` directory.
- Keep all user-visible strings in `SocialNotifications_localization.lua`; access via `mod:localize("key")`.
- Never read or write `Darktide-Source-Code/`; it exists only as a reference.
