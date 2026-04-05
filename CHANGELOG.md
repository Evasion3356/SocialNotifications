# Changelog

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
