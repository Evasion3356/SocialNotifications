# Changelog

## 1.2.0 — 2026-04-14

### Bug fixes
- Fixed auto-invite not resending after an invite timed out. Timeout events were not handled (only explicit cancellations were), and the stale `invite_pending` party status was causing the resend to be rejected even when the correct event fired.
- Fixed portrait flickering / wrong portrait showing after a character switch mid-session. The portrait cache now tracks character ID and automatically reloads when a different character is detected.
- Fixed a crash (`ui_manager.lua:1990: attempt to index local 'player' (a nil value)`) introduced in game patch 1.11.4, where `event_player_profile_updated` could fire for a remote peer before the local player had spawned.

## 1.1.0 — 2026-04-07

### New features
- **Per-friend notification allowlist** — toggle notifications on/off for individual friends via their social popup. Persists across sessions.
- **Party suppression** — optionally skip notifications for friends already in your party or your current game session.
- **Training grounds notifications** — get notified when a friend enters the training grounds (off by default).
- **Friend request notifications** — get notified when someone sends you a friend request.
- **Party size display** — activity notifications can now show the friend's current party size (e.g. "entered a mission (2/4)").
- **Auto-invite: event-driven** — auto-invite now fires instantly when a watched friend arrives in the hub, rather than waiting for a polling interval. The interval setting has been removed.
- **Auto-invite: Mourningstar-only** — auto-invites are now restricted to when you are in the hub, preventing accidental invites while you're in a mission.

### Bug fixes
- Notifications no longer appear during the login / character select screen; they are held until you are fully loaded into the Mourningstar.
- Fixed spurious offline/online notifications firing for friends who were in the same game session when the session ends.
- Fixed a crash when auto-invite attempted to call `try_invite` before the function reference was resolved.
- Fixed cross-platform friend icons (Steam, Xbox, PSN) displaying as a generic globe in who_are_you nameplates and hub panels for offline friends.
- Fixed double-icon rendering in notifications.
- Fixed a minor FPS hitch caused by redundant per-frame work in the poll loop.
- Fixed duplicate notifications that could fire when the mod reloaded mid-session.

## 1.0.0 — 2026-04-05

Initial release.

### Features

- **Presence notifications** — HUD alerts when friends come online, go offline, start matchmaking, enter or finish a mission, or return to the Mourningstar hub. Each event type has a distinct color-coded accent bar (green / gray / purple / amber / blue / teal).
- **Rich notification display** — notifications show the friend's character portrait, class icon, character name, and account name.
- **Cross-platform support** — detects Steam, Xbox, and PSN friends. Platform icons are color-coded (white Steam, green Xbox, PlayStation blue PSN) and Xbox gamertag suffixes (`#NNNN`) are stripped for cleaner display.
- **Auto-invite to Strike Team** — adds an on/off toggle to the social popup for any friend. When enabled, the mod automatically sends party invites on a configurable interval until the friend accepts or goes on a mission.
- **Configurable notifications** — individual toggles for each notification type (online, offline, matchmaking, mission start, mission end, hub). All enabled by default except mission end and hub.
- **Skip platform friends filter** — optionally suppress notifications for friends who are already visible in the native Steam/Xbox/PSN friend list (on by default).
- **Poll interval setting** — controls how often the friend list is refreshed (5–60 s, default 10 s).
- **Auto-invite interval setting** — controls how often pending invites are retried (10–120 s, default 30 s).
