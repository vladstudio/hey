# Hey

macOS menu bar client for [hey.vlad.studio](https://hey.vlad.studio) — a personal
notification bridge. Polls the server for new events and shows them as native
macOS notifications. Click a notification to open the site.

Native `UNUserNotificationCenter` — no Web Push / FCM, so it works in any browser
ecosystem (a workaround for browsers that can't do Web Push, e.g. ungoogled-chromium).

## Setup

1. Run `./build.sh` (installs to `/Applications/Hey.app`, opens it).
2. Click the bell icon in the menu bar → **Set Token…** → paste your `HEY_TOKEN`.
3. Push from anywhere:

```bash
curl -X POST https://hey.vlad.studio/push -H "Authorization: Bearer $HEY_TOKEN" \
  -d '{"title":"build","message":"deploy done"}'
```

A notification appears; clicking it opens https://hey.vlad.studio.

## Notes

- Polls `GET /recent` every 15s (Bearer auth). First run marks existing events as seen.
- Token + last-seen id stored in `UserDefaults`.
- Menu: connection status, Open site, Set Token…, Start on Login, Check for Updates…, Quit.