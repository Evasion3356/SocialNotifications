# SocialNotifications — Project Goal

## Purpose
Show HUD notifications when Steam/platform friends change status inside Darktide: coming online, going offline, entering a mission, starting matchmaking, or returning to the Mourningstar hub.

## Codebase layout
- `SocialNotifications/` — this mod (DMF mod, loaded via `SocialNotifications.mod`)
- `../dmf/` — Darktide Mod Framework (one directory up from this mod). Provides `new_mod`, `get_mod`, hook APIs, `mod:notify()`, etc.
- `Darktide-Source-Code/` — game source for reference; **do not modify**.

## Key game APIs

### Social service
`Managers.data_service.social` is a `SocialService` instance.

| Method | Returns | Notes |
|--------|---------|-------|
| `fetch_friends(force?)` | `Promise<PlayerInfo[]>` | Returns all friends (platform + Fatshark). Resolves quickly from cache; dirty flag causes re-fetch. |
| `get_player_info_by_account_id(id)` | `PlayerInfo?` | Lookup by Fatshark account ID. |

### PlayerInfo (`scripts/managers/data_service/services/social/player_info.lua`)
Each friend is a `PlayerInfo` object.

| Field/method | Type | Notes |
|--------------|------|-------|
| `account_id()` | string | Fatshark account ID (stable key). |
| `user_display_name(use_stale, no_icon)` | string | Platform persona name or account name. |
| `character_name()` | string | In-game character name (may be empty if blocked). |
| `online_status(use_stale?)` | string | `"offline"`, `"platform_online"`, `"online"`, `"reconnecting"` |
| `player_activity_id()` | string? | Activity key: `"hub"`, `"mission"`, `"matchmaking"`, `"main_menu"`, `"end_of_round"`, etc. Full list in `presence_settings.settings`. |
| `player_activity_loc_string()` | string? | Localization key for the activity. |
| `is_friend()` | bool | True if confirmed friend (not blocked). |
| `party_status()` | string | `"none"`, `"mine"`, `"same_mission"`, `"other"`, `"invite_pending"` |
| `num_party_members()` | int | Size of friend's party. |

### Presence (lower-level)
`Managers.presence:get_presence(account_id)` → `PresenceEntryImmaterium`
Fields: `activity_id()`, `num_party_members()`, `num_mission_members()`, `character_profile()`, `is_online()`.

### Relevant events (via `Managers.event`)
| Event name | Triggered when |
|------------|----------------|
| `event_new_immaterium_entry` | A new presence entry arrives (friend came online or joined game) |
| `backend_friend_invite` | Received a friend request |
| `backend_friend_invite_accepted` | Outgoing friend request accepted |
| `backend_friend_removed` | Friend removed |
| `party_immaterium_other_members_updated` | Party composition changed |

## Current implementation
`SocialNotifications.lua` polls `fetch_friends()` on a configurable interval (default 10 s), diffs each friend's `online_status` and `player_activity_id` against cached state, and fires `mod:notify()` text popups on changes.

## Planned improvements / open questions

1. **Event-driven presence updates** — Hook `event_new_immaterium_entry` (fired by `SocialService._event_new_immaterium_entry`) to react instantly instead of waiting for the poll interval. Need to investigate whether the event payload includes enough data or requires a follow-up `fetch_friends()`.

2. **Richer HUD widget** — Replace `mod:notify()` with a proper styled widget (icon + text) similar to how `FriendlyFireNotify` renders notifications. Look at DMF's `gui` and `ui` modules under `dmf/scripts/mods/dmf/modules/`.

3. **Suppress notifications during initial load** — The current seed-on-load approach works but may mis-fire if the social service isn't fully populated yet. Consider waiting for `first_update_promise()` on presence entries.

4. **Notification for friend joining your party / inviting you** — Hook `backend_friend_invite` and `party_immaterium_other_members_updated`.

5. **Per-friend opt-out** — Could expose a UI to mute specific friends.

6. **Cross-platform persona names** — `user_display_name()` already handles Steam/Xbox/PSN icons. Verify rendering in the DMF notification widget.

## File map
```
SocialNotifications/
├── CLAUDE.md                          ← project instructions for Claude Code
├── GOAL.md                            ← this file
├── SocialNotifications.mod            ← DMF entry point
├── Darktide-Source-Code/              ← game source reference (read-only)
└── scripts/mods/SocialNotifications/
    ├── SocialNotifications.lua        ← main logic
    ├── SocialNotifications_data.lua   ← DMF settings/metadata
    └── SocialNotifications_localization.lua
```
