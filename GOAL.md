# SocialNotifications — Project Goal

## Purpose
Two related features for Darktide social:

1. **Presence notifications** — HUD notifications when Darktide social friends change status (online, offline, entering a mission, starting matchmaking, returning to the Mourningstar hub).
2. **Auto-invite to Strike Team** — Per-friend checkbox in the social popup menu that, when checked, automatically sends party invites on a configurable interval whenever the friend is available (not offline, not in a mission).

## Codebase layout
- `SocialNotifications/` — this mod (DMF mod, loaded via `SocialNotifications.mod`)
- `../dmf/` — Darktide Mod Framework (one directory up). Provides `new_mod`, `get_mod`, hook APIs, `mod:notify()`, etc.
- `Darktide-Source-Code/` — game source reference; **do not modify**.

## Key game APIs

### Social service — `Managers.data_service.social`
| Method | Returns | Notes |
|--------|---------|-------|
| `fetch_friends(force?)` | `Promise<PlayerInfo[]>` | Returns all friends (platform + Fatshark). Cached; dirty flag causes re-fetch. |
| `get_player_info_by_account_id(id)` | `PlayerInfo?` | Synchronous lookup by Fatshark account ID. |
| `send_party_invite(player_info)` | void | Sends a party invite; handles Fatshark + platform-specific flows internally. |
| `can_invite_to_party(player_info)` | `(bool, reason?)` | Returns false + reason if offline, party full, cross-play blocked, or activity blocks invites. |

### PlayerInfo (`scripts/managers/data_service/services/social/player_info.lua`)
| Method | Type | Notes |
|--------|------|-------|
| `account_id()` | string | Stable Fatshark ID — use as cache key. |
| `user_display_name(use_stale, no_icon)` | string | Platform persona name. |
| `online_status(use_stale?)` | string | `"offline"` `"platform_online"` `"online"` `"reconnecting"` |
| `player_activity_id()` | string? | `"hub"` `"mission"` `"matchmaking"` `"main_menu"` `"end_of_round"` |
| `party_status()` | string | `"none"` `"mine"` `"same_mission"` `"other"` `"invite_pending"` |
| `friend_status()` | string | Fatshark-level friend status (`"friend"`, `"none"`, etc.) |
| `platform_friend_status()` | string? | `"friend"` if on platform (Steam/Xbox/PSN) friends list; `nil` if no platform social. |
| `is_friend()` | bool | True if Fatshark OR platform friend (not blocked). |
| `is_own_player()` | bool | True if this is the local player. |
| `is_blocked()` | bool | True if blocked. |

### Social constants (`scripts/managers/data_service/services/social/social_constants.lua`)
```lua
SocialConstants.OnlineStatus  = table.enum("offline", "platform_online", "online", "reconnecting")
SocialConstants.PartyStatus   = table.enum("none", "mine", "same_mission", "other", "invite_pending")
SocialConstants.FriendStatus  = table.enum("none", "friend", "invite", "invited", "ignored")
-- table.enum makes FriendStatus.friend == "friend" (string), etc.
```

### Relevant events (via `Managers.event`)
| Event | Fires when |
|-------|-----------|
| `event_new_immaterium_entry` | Presence entry updated with fresh backend data |
| `backend_friend_invite` | Received a friend request |
| `backend_friend_removed` | Friend removed |
| `party_immaterium_other_members_updated` | Party composition changed |

### Social popup menu
`ViewElementPlayerSocialPopupContentList.from_player_info(parent, player_info)` — module-level function that builds the social popup action list. Returns `(items_table, count)` where `items_table` is a shared reused table and `count` is the number of populated entries. Hookable via `mod:hook(ContentList, "from_player_info", ...)`.

Each item has: `blueprint` (`"button"` / `"disabled_button_with_explanation"` / `"group_divider"`), `label` (string), `callback` (function), optional `is_disabled` / `reason_for_disabled`.

## Feature 1: Presence notifications

### How it works
- Two-layer detection:
  - **Event layer**: registered for `event_new_immaterium_entry`. Fires on any presence update; instantly processes already-known friends.
  - **Poll layer**: `fetch_friends()` every `poll_interval` seconds. Seeds `_friend_states` on startup and catches activity changes.
- `process_friend(player_info)` diffs `online_status` and `player_activity_id` against `_friend_states[account_id]`.
- Fires `event_add_notification_message("custom", ...)` with color-coded left accent bars.

### Filter: skip_platform_friends (default ON)
Suppresses notifications for friends where `platform_friend_status() == FriendStatus.friend` (already on your Steam/Xbox/PSN friends list — their client shows its own online/offline toasts). State is still tracked so toggling mid-session doesn't cause spurious transitions.

Does **not** apply to auto-invite — the user explicitly sets that checkbox, so platform status is irrelevant there.

## Feature 2: Auto-invite to Strike Team

### How it works
A per-friend checkbox toggle injected into the social popup (same menu as "Invite to Strike Team"). Clicking `[OFF] Auto-invite to Strike Team` enables it for that friend; clicking `[ON] Auto-invite to Strike Team` disables it.

Every `auto_invite_interval` seconds (default 30s), for each watched account:

| State | Action |
|-------|--------|
| `PartyStatus.mine` | Stop watching (they joined) |
| `online_status == offline` | Wait |
| `online_status == platform_online` | Wait (not in-game) |
| `activity_id == "mission"` | Wait |
| `party_status == invite_pending` | Wait (invite already sent) |
| otherwise | Call `can_invite_to_party`; invite if allowed |

### Persistence
The watched list is **not** cleared on map transitions — user intent persists for the session. Future work: persist across game restarts via DMF save data.

### UI note
The toggle appears in the social popup (the context menu opened by clicking a friend in the Social tab). It does not yet appear as a visual checkbox in the roster list itself — that requires deeper blueprint injection and is deferred. After toggling, the popup must be closed and reopened to see the updated label.

## File map
```
SocialNotifications/
├── CLAUDE.md                              ← points to AGENTS.md
├── AGENTS.md                              ← full agent context
├── GOAL.md                                ← this file
├── SocialNotifications.mod                ← DMF entry point
├── Darktide-Source-Code/                  ← game source reference (read-only)
└── scripts/mods/SocialNotifications/
    ├── SocialNotifications.lua            ← main mod (poll loop, event handler, reset)
    ├── SocialNotifications_autoinvite.lua ← auto-invite loop + popup hook
    ├── SocialNotifications_data.lua       ← DMF settings/metadata
    └── SocialNotifications_localization.lua
```

## Open work / future improvements

1. **Roster-level checkbox** — Visual checkbox directly in the roster list for each friend (not just in the popup). Requires hooking the blueprint init for `player_plaque` entries. Complex; deferred.
2. **Cross-session persistence** — Persist watched accounts via DMF save data.
3. **Per-friend notification muting** — UI to suppress presence notifications for specific friends.
4. **PSN display name override** — `platform()` returns `""` for both Xbox and PSN cross-platform friends; the current code infers Xbox from the `#NNNN` gamertag suffix, but PSN names do not have that suffix and are currently left as-is with no platform label. Add a button to the social popup (similar to the auto-invite toggle) that lets the user manually tag a friend as PSN, storing the override in mod save data. When tagged, `resolve_platform` should return `"psn"` for that account, causing the PSN icon to render and removing any ambiguity.
