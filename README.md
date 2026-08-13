# Calendar Bar

A native macOS menu bar app that shows your Google Calendar agenda in a popover styled after
Microsoft Outlook's menu bar calendar. Events are fetched straight from the **Google Calendar
v3 REST API** over OAuth 2.0 + PKCE — no EventKit, no Apple Calendar involvement — so
per-event custom colors are preserved exactly as you set them in Google Calendar.

- Agent app (`LSUIElement`): menu bar only, no Dock icon, no app menu
- Collapsible month/week grid, accent-colored "today" badge, week/month navigation arrows
- Seven-day agenda: `Today • Thursday • August 13`, `Tomorrow • Friday • August 14`, …
- Per-event colors matched to Google Calendar's modern palette (see §5)
- Nine switchable accent palettes plus light/dark override, from the **…** menu
- Tokens stored in the macOS Keychain; refresh on popover open and every 10 minutes
- Universal binary (Apple Silicon + Intel), macOS 13 Ventura or newer

## 1. Google Cloud setup

1. Open [console.cloud.google.com](https://console.cloud.google.com) → create/select a project.
2. **APIs & Services → Library** → enable **Google Calendar API**.
3. **APIs & Services → OAuth consent screen**:
   - User type **External** (or Internal on Workspace), fill in the app name and support email.
   - Add scopes: `openid`, `email`, `https://www.googleapis.com/auth/calendar.readonly`.
   - While the app is in *Testing*, add your own Google account under **Test users**.
4. **APIs & Services → Credentials → Create credentials → OAuth client ID**:
   - Application type: **Desktop app**. No redirect URI configuration is needed — the app
     uses a loopback redirect (`http://127.0.0.1:<random-port>`), which Google allows
     automatically for Desktop clients.
5. Copy the **Client ID** and **Client secret**.

## 2. Where to paste the Client ID / Secret

Pick whichever you prefer — they are checked in this order:

| Order | Location | Notes |
| --- | --- | --- |
| 1 | `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` env vars | Handy for `swift run` |
| 2 | `~/.config/calendarbar/.env` | Keeps secrets out of the repo |
| 3 | `.env` in this folder | Copied into the app bundle by `build-app.sh` |
| 4 | Constants in [`Sources/CalendarBar/Config/AppConfig.swift`](Sources/CalendarBar/Config/AppConfig.swift) | Replace `YOUR_CLIENT_ID` / `YOUR_CLIENT_SECRET` |

`.env` format (see [`.env.example`](.env.example)):

```
GOOGLE_CLIENT_ID=400383093183-xxxxxxxx.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=GOCSPX-xxxxxxxxxxxxxxxx
```

Key names are matched loosely, so `GOOGLE_CLIENT_ID`, `CLIENT_ID`, `Client ID` and
`client-id` all work.

> Google's Desktop-app token endpoint normally requires `client_secret` even with PKCE.
> If it is missing, the app attempts the PKCE-only exchange and says exactly what to add
> when Google rejects it.

## 3. Running it

Requires the Swift toolchain. Full Xcode is optional — the Command Line Tools are enough
(`xcode-select --install`).

### VS Code

Install the [Swift extension](https://marketplace.visualstudio.com/items?itemName=sswg.swift-lang),
open this folder, then **⇧⌘P → Tasks: Run Task**:

- **Build (debug)** — compile
- **Run app (build + launch)** — build and launch the menu bar app
- **Stop app** — quit it
- **Preview UI (demo data, no sign-in)** — render the popover to `dist/preview.png`

`F5` (Run and Debug) attaches LLDB using [`.vscode/launch.json`](.vscode/launch.json).

### Terminal

```bash
swift run
```

The status item appears in the menu bar; click it, then **Sign in with Google**. Your
browser opens Google's consent screen and redirects back to the app's local loopback
listener.

### Xcode

Open `Package.swift` in Xcode (**File → Open**, select the package folder) and press ⌘R.
Xcode runs the bare executable, which still hides the Dock icon because the app sets
`.accessory` activation at launch. Use `./build-app.sh` when you want the real `.app`.

## 4. Exporting the .app and DMG

```bash
./build-app.sh            # build only, into dist/
./build-app.sh --install  # build, move to /Applications, leave no duplicate
./build-app.sh --run      # build and launch
```

Produces `dist/Calendar Bar.app` as a Universal binary (verify with
`lipo -archs "dist/Calendar Bar.app/Contents/MacOS/CalendarBar"` → `x86_64 arm64`).
The script embeds `Resources/Info.plist` (`LSUIElement = YES`, `LSMinimumSystemVersion = 13.0`),
copies `.env` to `Contents/Resources/credentials.env`, and ad-hoc signs the bundle.

Then:

```bash
./package-dmg.sh
```

Produces `dist/CalendarBar-1.0.dmg` with an `/Applications` symlink. `package-dmg.sh`
prints the `codesign` + `notarytool` commands needed for distribution outside your own Mac.

To install: `./build-app.sh --install`, or drag the app to `/Applications` yourself.
Prefer the flag — it removes the build copy afterwards, because two bundles with the same
name both get registered with LaunchServices and the app then appears twice in Launchpad
and Spotlight.

### Keeping it running (start at login)

Nothing needs a terminal or script open — the app is a normal background agent. To start it
automatically at login, either tick it under **System Settings → General → Login Items → +**,
or install the LaunchAgent, which is what this repo does:

```bash
cp com.nifra.calendarbar.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.nifra.calendarbar.plist
```

It appears in **System Settings → General → Login Items** under "Allow in the Background",
so you can switch it off there. `KeepAlive` is deliberately `false`: quitting from the **…**
menu stays quit until your next login instead of relaunching immediately.

To start/stop by hand, or remove it entirely:

```bash
launchctl kickstart gui/$(id -u)/com.nifra.calendarbar   # start now
launchctl kill SIGTERM gui/$(id -u)/com.nifra.calendarbar  # stop now
launchctl bootout gui/$(id -u)/com.nifra.calendarbar && rm ~/Library/LaunchAgents/com.nifra.calendarbar.plist
```

Notes on signing:

- **Ad-hoc signatures change on every rebuild**, and the Keychain ties stored items to the
  signature that created them. So after `./build-app.sh` you may have to sign in to Google
  once more — the popover says so explicitly instead of just showing the sign-in panel.
  Signing with a stable Developer ID identity removes this for good; it only affects
  rebuilds, not day-to-day use.
- The app icon lives at `Resources/AppIcon.icns` and is generated by
  `swift tools/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns`.
  Edit [`tools/make-icon.swift`](tools/make-icon.swift) to change it; the matching menu bar
  template icon is drawn in [`UI/StatusItemIcon.swift`](Sources/CalendarBar/UI/StatusItemIcon.swift).

## 5. Appearance

Both live under the **…** menu and persist in `UserDefaults` — no rebuild needed:

- **Color Palette** — Outlook Green (default), Outlook Blue, Blueberry, Grape, Tomato,
  Tangerine, Peacock, Graphite, or **Match macOS Accent** (follows System Settings live).
  The accent drives the today badge, today's agenda header, the selection ring and buttons.
- **Appearance** — Match System, Light, or Dark.

See [`docs/previews/palettes.png`](docs/previews/palettes.png) for all eight side by side. Add your own in
`Palette.all` in [`UI/ThemeManager.swift`](Sources/CalendarBar/UI/ThemeManager.swift) —
each entry has a light and a dark accent hex.

**Event colors are never themed.** They always come from Google Calendar so the agenda
matches what you see there. Note that Google's `colors` API still returns the *legacy*
palette (Banana `#fbd75b`) while the Google Calendar UI draws the *modern* one
(Banana `#f6bf26`); [`API/GoogleColors.swift`](Sources/CalendarBar/API/GoogleColors.swift)
maps between them, and passes custom colors through untouched.

## 6. How it works

| Area | File |
| --- | --- |
| Status item, popover, dismissal | [`main.swift`](Sources/CalendarBar/main.swift) |
| Credentials resolution | [`Config/AppConfig.swift`](Sources/CalendarBar/Config/AppConfig.swift) |
| PKCE, token exchange/refresh | [`Auth/OAuthManager.swift`](Sources/CalendarBar/Auth/OAuthManager.swift), [`Auth/PKCE.swift`](Sources/CalendarBar/Auth/PKCE.swift) |
| Loopback redirect listener | [`Auth/LoopbackServer.swift`](Sources/CalendarBar/Auth/LoopbackServer.swift) |
| Keychain persistence | [`Auth/KeychainStore.swift`](Sources/CalendarBar/Auth/KeychainStore.swift) |
| Calendar v3 requests | [`API/GoogleCalendarAPI.swift`](Sources/CalendarBar/API/GoogleCalendarAPI.swift) |
| Event model, date parsing | [`API/Models.swift`](Sources/CalendarBar/API/Models.swift) |
| State, refresh timer, navigation | [`Store/CalendarStore.swift`](Sources/CalendarBar/Store/CalendarStore.swift) |
| Popover UI | [`UI/`](Sources/CalendarBar/UI) |

Endpoints used: `users/me/calendarList`, `colors`, and
`calendars/{id}/events?singleEvents=true&orderBy=startTime` for every visible calendar.
Recurring series are expanded server-side; color precedence is
event `colorId` → calendar `backgroundColor` → fallback.

### Environment flags

| Variable | Effect |
| --- | --- |
| `CALENDARBAR_DEMO=1` | Fill the popover with sample events, skipping sign-in |
| `CALENDARBAR_OPEN_AT_LAUNCH=1` | Open the popover immediately at launch |
| `CALENDARBAR_EXPORT_PNG=<path>` | Render the popover to a PNG and exit |
| `CALENDARBAR_EXPORT_EXPANDED=1` | Render with the full month grid |
| `CALENDARBAR_EXPORT_APPEARANCE=dark` | Render in dark mode |
| `CALENDARBAR_EXPORT_PALETTE=<id>` | Render with a given palette, e.g. `grape` |

## 7. Troubleshooting

| Symptom | Fix |
| --- | --- |
| "This Google client requires a client secret" | Add `GOOGLE_CLIENT_SECRET` to `.env` |
| `Error 403: access_denied` | Add your account under **Test users** on the consent screen |
| `invalid_grant` after a while | Access was revoked; sign in again from the **…** menu |
| No events although the calendar has some | Only calendars *selected* in Google Calendar are read |
| Wrong colors | Colors come from Google's palette; check the event's own color in Google Calendar |
| Keychain prompt, or signed out after a rebuild | Expected with ad-hoc signing (the signature changes each build); sign in again, or use a Developer ID identity |
| Calendar colors look wrong | `calendarList` only returns `backgroundColor` when `colorRgbFormat=true`; that is set in `fetchCalendarList()` |
