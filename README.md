# Custom Notch

A "Dynamic Island" around the MacBook notch. It lives in the menu bar (no Dock icon), shows on every desktop
and over full-screen apps, and never takes focus from the app you're using. The island is always black, like
the notch; its tiles and buttons follow macOS's appearance: Apple's dark greys in dark mode, solid light greys in
light mode, both with the accent colour #935B29. macOS 14 or later, Apple Silicon. On a Mac without a notch it draws one at the top centre.

## Build and run

You need the Command Line Tools (`xcode-select --install`) or Xcode. If Xcode is selected but not ready
(still installing, or its license not accepted yet), `build.sh` uses the Command Line Tools for that run.

```bash
./build.sh
```

This compiles a release build, assembles `build/Custom Notch.app` (with the `notch-hook` helper and the icon),
signs it, installs it to `~/Applications/Custom Notch.app` and launches it. `./build.sh --no-launch` installs
without launching.

**Do this once, before granting any permission:**

```bash
./scripts/make-signing-cert.sh
```

It creates a local self-signed code-signing certificate in your login keychain; `build.sh` then uses it for
every build. Without it the app gets an ad-hoc signature that changes with each build, so macOS forgets its
permissions (Automation, Calendar, Bluetooth) after every rebuild. If macOS asks whether
`codesign` may use the key, choose **Always Allow**. If you granted permissions before creating the
certificate, reset them once: `tccutil reset All local.customnotch.CustomNotch`.

## The island

- **Resting**: just the black notch.
- **Compact**: a black pill, notch-high, that grows to the sides. It shows Claude Code's current step while it
  works, otherwise the playing song's cover with an equalizer.
- **Peek**: a small bubble under the notch for 2 to 4 seconds.
- **Open**: rest the pointer on the notch for 0.25 s and the tiles appear; move away and they close. Click to
  keep it open; click outside it, or on the notch, to close it.
- **Teleprompter**: your script under the camera. It stays out until you stop it (see below).

## Teleprompter

Read a script while you look into the camera: the text runs in a narrow column right under the notch, so your
eyes stay next to the lens. It follows your voice, or scrolls at a fixed speed.

1. Menu-bar icon → **Teleprompter…**. Paste your script (⌘V or **Paste from Clipboard**), type it, or dictate
   it with the 🎤 key. The bar under the script shows the word count (and, at a fixed speed, the reading time),
   with buttons to paste and to clear (⌘Z brings it back). It is saved as you type, only on this Mac
   (`~/Library/Application Support/Custom Notch/Teleprompter.txt`).
2. On the right, pick **Scrolling** (Follow Voice or Fixed Speed), the **Speed** for a fixed speed, the
   **Text Size** and the **Width** (Narrow keeps your eyes closest to the camera). **Shortcuts** at the bottom
   lists the keys that work while it runs.
3. **Start** (or ⌘↩). After 3-2-1 the text starts. The line to read is bright, the one you just read stays
   dimmed above it, and the next ones wait below.

**Follow Voice** (the default): the words you have said dim as you say them, and the next line moves up
when you reach the end of a line. Speak freely in between and the text waits; skip a passage and it finds you
again; go back and repeat a sentence and it goes back too. The first time, macOS asks for the **Microphone**.
Your speech is recognized on this Mac by Apple's speech recognition (SpeechAnalyzer on macOS 26); no audio
leaves the Mac. The language comes from the script itself (German and English, and others Apple supports). If a
language's speech model isn't on the Mac yet, macOS downloads it once from Apple (no audio is involved). While
the microphone is on, macOS shows its orange dot in the menu bar; pausing turns the microphone off. On
macOS 14 and 15 the older on-device recognizer is used, which also asks for **Speech Recognition**.
If the microphone isn't allowed, the teleprompter says so and scrolls at the fixed speed instead.

**Fixed Speed**: the text scrolls at the words per minute you chose. A blank line in the script makes a short
pause.

While it runs the island stays out (hovering doesn't open the tiles), peeks wait until you stop, and Claude
Code's permission requests go straight to the terminal, so nothing covers your script.

| Shortcut | |
|---|---|
| ⌃⌥Space | Pause / continue (at the end: start again) |
| ⌃⌥↑ / ⌃⌥↓ | Faster / slower, 10 words per minute (fixed speed) |
| ⌃⌥→ / ⌃⌥← | Next sentence / back to the start of the sentence |
| ⌃⌥. | Stop |
| Two fingers on the text | Move it by hand; it carries on from there (following your voice: from that line) |

The same controls sit on the wings next to the notch: stop and pause on the left; on the right, the speed, or
while following your voice, whether the microphone hears you. To stop, you can also choose **Stop Teleprompter**
in the menu.

The app asks macOS to leave the teleprompter out of screen sharing and recordings. Since macOS 15 not every
app honours that, so try it once with a real screen share in Zoom, Teams or Meet before you rely on it.

## Tiles

Show or hide each tile, make it 1, 2 or 3 cells wide, and move it left or right: menu-bar icon → **Tiles**, or
right-click a tile in the open island. If the tiles don't fit across the screen they wrap onto a second row.
By default there are four tiles of two cells each (about 690 pt wide; about 520 pt while no music player is open),
80 pt high, starting 6 pt under the notch.

- **Music** (Spotify and Apple Music): the cover as a small vinyl record (the disc slides out while playing),
  title, artist, a progress bar (click to jump), elapsed and total time, previous / play-pause / next, and the
  current line of the lyrics, synced, from LRCLIB (cached on your Mac). With dark tiles the blurred cover fills the
  tile; with light tiles the tile stays light. The app never launches Spotify or Music. While neither Spotify
  nor Music is open, the tile disappears and the island gets narrower.
- **Weather** (Open-Meteo): two pages; swipe with two fingers like the cards. **Now**: temperature, a small
  icon, city, high and low, and the chance of rain for each of the next 12 hours as bars (24 at three cells), or
  "No rain next 12 h". **Week**: seven days (three at one cell) with icon, chance of rain from 20 %, high and
  low. Choose the city with **Weather City…**. Refreshed when the island opens if the last reading is older than
  30 minutes.
- **Claude · Calendar · Batteries · Slack**: cards side by side; flip through them with a two-finger swipe on
  the trackpad (they snap into place) or click a page dot.
  1. **Claude limit**: your 5-hour and weekly usage with when each resets (Pro/Max plans). It needs Claude Code
     connected (menu → Claude Code → **Connect Claude Code…**) and updates after each Claude Code reply; a window
     whose reset time has passed shows as renewed.
  2. **Calendar**: everything in the next 7 days from all calendars in the Calendar app, grouped by day
     ("Today", "Tomorrow", …), the next one highlighted ("In 25 min", "Now"). Scroll up and down when there
     are more. Google, Exchange and other calendars show up once they're added in System Settings → Internet
     Accounts with Calendars turned on.
  3. **Batteries**, like Apple's Batteries widget: this Mac, Bluetooth devices macOS reports while connected,
     Magic accessories, and, if you click **Show AirPods**, AirPods read from their Bluetooth broadcast
     (asks for the Bluetooth permission; only models paired with this Mac and close by). When not all fit, the
     fullest are left out, so the lowest is always shown. iPhone, iPad and Apple Watch can't be shown: macOS gives
     apps no way to read them.
  4. **Slack**: your newest messages (not your own), with author, channel and time; scroll for more, click one to
     open it. Click **Connect Slack** and paste a user token (see "Slack" below).
- **Quick Controls**: eight buttons. Wi-Fi on/off (dots = signal strength); **AirDrop** with Apple's AirDrop
  glyph (tinted while others can find this Mac): click it to choose Off, Contacts Only or Everyone, like Control
  Center; dark mode; **Sound & Display** (volume and brightness sliders); **Chess** (opens the board);
  **Teleprompter** (opens the script window, or stops the teleprompter while it runs); **Amphetamine** and
  **Raycast**, with their app icons. At one cell: Wi-Fi, AirDrop, Sound & Display and Teleprompter.
  - **Amphetamine**: its logo is in colour while it keeps the Mac awake, grey while it doesn't. Click it for
    what its menu-bar icon offers for a session: **Awake** starts a session with the length set in
    Amphetamine's Preferences, or ends the running one (it shows the time left, or "Indefinitely"); **∞ · 30m ·
    1h · 2h · 4h** start a new session of that length; **Display Stays On** prevents or allows display sleep.
    If Amphetamine isn't open, the click starts it in the background first.
  - **Raycast**: opens Raycast's search window, like its hot key or **Open Raycast** in its menu.
- **Next Event** (hidden by default): the next Calendar event in the next 7 days; "In 25 min" and "Now" are
  highlighted.
- **Focus Timer** (hidden by default): 25 minutes, start/pause and reset. It keeps running while the island is
  closed or the Mac sleeps, and ends with a bubble and a soft sound.

## Chess against Claude

Click the chess button in Quick Controls, or menu-bar icon → **Chess** → **Open Board**. The island opens a board under the notch:
click one of your pieces (its moves show as dots), then where it should go. Pawns that reach the last rank become
queens. Claude answers in a few seconds ("Claude is thinking…"); the move list, **Undo** (takes back your last move
and Claude's answer), **Resign** and **New: White / Black** sit next to the board. Check, checkmate, stalemate,
threefold repetition, the 50-move rule and bare kings are recognized.

The board stays open until you click ✕, the notch, or anywhere outside it. The game carries on meanwhile and is
saved, also across restarts; when Claude moves while the board is closed, a bubble tells you its move.

Claude plays through **your own Claude Code login** (no API key): the app runs `claude -p` from
`~/.local/bin`, `/opt/homebrew/bin` or `/usr/local/bin`, with the model you choose in menu → **Chess** (Haiku,
Sonnet as the default, or Opus, the strongest). It runs in safe mode (your hooks, MCP servers and CLAUDE.md stay out,
so the notch doesn't show these requests as Claude Code activity), with no tools and without saving a session, in
`~/Library/Application Support/Custom Notch/Chess`. Each of Claude's moves counts toward your plan's usage.
Claude's answer is always checked against the legal moves: after two illegal answers it plays a random legal move
and says so. If Claude Code isn't installed or logged in, the board shows the error and a **Retry** button.

## Peeks

Each kind can be turned off in menu → **Peeks**:

- The charger is connected ("Charging" or "Plugged In", with the battery level).
- The battery reaches 20% (muted orange) and 10% (muted red), once each per discharge.
- Do Not Disturb or another Focus turns on or off. Off until you choose menu → Peeks → **Do Not Disturb…**,
  which asks for the Focus permission. macOS only tells apps that *a* Focus is on (not which one) and has no
  change notification, so the app checks every 3 seconds while this peek is on. If the permission isn't
  granted, the menu says so.

Bubbles that arrive together wait their turn; a bubble that arrives while the island is open shows when it closes.

## Claude Code in the notch

While Claude Code works, the pill shows the current step (thinking, reading, editing, running a command,
searching, browsing) with a small animated grid. When Claude asks for permission, the island opens with the
**whole** command (it scrolls if long; **Allow** unlocks once its end has been on screen) and **Deny** / **Allow**,
or **⌃⌥N** / **⌃⌥Y** from anywhere (registered only while a request is shown; no Accessibility needed).
**Answer in Terminal** hands it back to Claude Code's own prompt, which also happens by itself after 90 seconds.
When Claude finishes, a "Done" bubble shows the project and how long it took.

The easy way: menu → Claude Code → **Connect Claude Code…**. After asking, it adds the hooks below and the status
line (if you have none yet) to `~/.claude/settings.json`, keeps everything else, and saves the old file as
`~/.claude/settings.json.backup-customnotch`. New Claude Code sessions pick it up.

Or add these lines yourself (menu → Claude Code → **Copy Hook Settings** copies them). If the file already has a
`"hooks"` section, add these five events inside it instead of replacing it, and keep the file valid JSON:

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "\"$HOME/Applications/Custom Notch.app/Contents/Helpers/notch-hook\"" }] }],
    "PreToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "\"$HOME/Applications/Custom Notch.app/Contents/Helpers/notch-hook\"" }] }],
    "PermissionRequest": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "\"$HOME/Applications/Custom Notch.app/Contents/Helpers/notch-hook\"", "timeout": 600 }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "\"$HOME/Applications/Custom Notch.app/Contents/Helpers/notch-hook\"" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "\"$HOME/Applications/Custom Notch.app/Contents/Helpers/notch-hook\"" }] }]
  }
}
```

For the **Claude limit** card, also add this status line entry at the top level of the same file (menu → Claude
Code → **Copy Status Line Setting**). Claude Code then shows a short line under the prompt (model · context ·
5-hour · weekly usage) and passes your plan limits to the app. Note: with a custom status line, Claude Code
hides some footer hints such as "esc to interrupt".

```json
"statusLine": { "type": "command", "command": "\"$HOME/Applications/Custom Notch.app/Contents/Helpers/notch-hook\" --statusline" }
```

Each hook runs `notch-hook` (inside the app), which passes the event to the app over a local socket
(`~/Library/Application Support/Custom Notch/claude.sock`, only your user can open it). If Custom Notch isn't
running, or anything fails, the helper prints nothing and Claude Code asks in the terminal as usual: the notch
never approves anything by itself. These hooks apply to every Claude Code session, including the desktop app.

## Slack

The Slack card uses your own Slack *user token*, so it sees exactly what you see:

1. Open <https://api.slack.com/apps> → **Create New App** → **From scratch**, pick your workspace.
2. **OAuth & Permissions** → **User Token Scopes** → add `search:read` and `users:read`.
3. **Install to Workspace** (your workspace may need an admin to approve it), then copy the
   **User OAuth Token** (starts with `xoxp-`).
4. Menu-bar icon → **Cards** → **Connect Slack…** (or **Connect Slack** in the card) and paste it.

The app checks the token with Slack and keeps it in your keychain. **Disconnect Slack** removes it.

## Menu

Menu-bar icon:

- **Teleprompter…**: the script window (see above); while it runs, **Stop Teleprompter**.
- **Tiles**: show, hide, size and order of each tile.
- **Weather City…**: type a city (only its name is sent to Open-Meteo).
- **Music**: show music in the notch, synced lyrics (lrclib.net), Spotify covers (off; i.scdn.co).
- **Cards**: AirPods batteries over Bluetooth on/off, connect or disconnect Slack.
- **Peeks**: charger, battery, Do Not Disturb.
- **Claude Code**: connect it (adds the hooks and status line), show it in the notch, allow or deny from the
  notch, copy the hook settings.
- **Chess**: open the board, new game as White or Black, and which Claude model plays against you.
- **Theme**: Automatic (dark tiles in dark mode, light tiles in light mode, switching live), Dark, or Light. The
  island itself stays black in every theme, and so does everything drawn straight on it: the pill, peeks, the
  teleprompter and the headings of the Claude Code panel. Only tiles and buttons change, in solid colours. The
  switch is picked up from the app's appearance, from macOS's "appearance changed" signal, after the dark-mode
  button, and again whenever the island opens.
- **Preview** (hold ⌥ while opening the menu): every state and each kind of peek, to see them without waiting
  for the real event.
- **Launch at Login**: off until you turn it on (macOS lists the app in Settings → General → Login Items).
  If macOS refuses (likely with the ad-hoc signature), the alert's **Show App and Login Items** opens Login Items
  and shows `Custom Notch.app` selected in the Finder: drag it into the "Open at Login" list. Adding it by hand
  works with any signature, and rebuilding keeps it working (the app stays in the same place).
- **Quit Custom Notch**.

## Permissions

Each is asked only the first time its feature is used, never at launch:

| Permission | Why | When |
|---|---|---|
| Automation → System Events | Switch dark mode | First tap on the dark-mode button |
| Automation → Amphetamine | Read, start and end its session | First tap on the Amphetamine button |
| Automation → Spotify / Music | Read the song, position and cover; play, pause, skip | First time the island opens while that player has music, or **Show … Here** in the Music tile |
| Bluetooth | Read the battery level your AirPods broadcast | **Show AirPods** in the batteries card |
| Calendar (full access) | Show your next event | **Connect Calendar** in the Next Event tile |
| Focus | Know when Do Not Disturb (or another Focus) turns on or off | menu → Peeks → **Do Not Disturb…** |
| Microphone | Let the teleprompter follow your voice (recognized on this Mac) | First **Start** with Scrolling: Follow Voice |
| Speech Recognition (macOS 14–15 only) | The older on-device recognizer needs it | Same moment, on macOS 14 and 15 |

Never asked: Accessibility (the shortcuts use system hot keys), Location (no Wi-Fi network name), Contacts,
Full Disk Access, Screen Recording, Input Monitoring.

With the ad-hoc signature macOS forgets permissions after every rebuild (see Build and run).

## Privacy

No analytics, no accounts. The only network requests go to:

- **Open-Meteo**, for the weather: the city name when you choose it, then its coordinates.
- **lrclib.net**, for lyrics: title, artist, album and length of a song, only while the island is open and once
  per song (answers, including "not found", are cached in `~/Library/Caches/local.customnotch.CustomNotch/Lyrics`).
  Turn off in menu → Music → Synced Lyrics.
- **i.scdn.co** (Spotify's image server), for Spotify covers, **only if you turn it on** in menu → Music.
  Apple Music covers come from the Music app on your Mac.
- **slack.com**, for the Slack card, **only after you connect Slack**: with your token, when the island opens,
  at most once a minute. The token stays in your keychain.
- **Anthropic**, through your Claude Code CLI, **only while you play chess**: for each of Claude's moves, the
  position, the moves so far and the legal moves.

Calendar, battery and Claude Code data, your teleprompter script and your voice never leave the Mac. (Apple's
speech model for a language may be downloaded once by macOS, without any audio.)

## What macOS doesn't allow, and what the app does instead

- **AirDrop** has no public API: the app writes the same setting System Settings uses
  (`com.apple.sharingd DiscoverableMode`) and restarts the sharing service, then reads it back. If macOS ever
  ignores it, the tile says so.
- **Brightness** has no public API: the app uses Apple's private DisplayServices framework (built-in display).
  It may stop working in a future macOS; the slider is then greyed out.
- **Wi-Fi** shows on/off and signal strength only; the network name would need the Location permission.
- **Amphetamine**'s scripting covers sessions by length, ending them and display sleep. "Until a specific time",
  "While an app is running", "While a file is downloading", Triggers and its Preferences aren't offered in the
  island: use its menu-bar icon for those.
- **Raycast** has no scripting; the button opens its search window through its `raycast://` link. Raycast's own
  menu-bar menu can't be read or copied without the Accessibility permission, which the app never asks for.
- **iPhone, iPad and Apple Watch batteries** can't be read by Mac apps (Apple's own widget uses a private
  iCloud channel). **AirPods** levels are reverse-engineered from their Bluetooth broadcast, so not every model
  may show.
- **Do Not Disturb** has no public API: the Focus status API reports only whether some Focus is on, and only
  after you allow it. It may not be available to an app signed without an Apple developer profile; the menu
  then says "Focus permission not granted".

## Performance

Measured with `top` on a MacBook Pro (macOS 26):

| State | CPU | Notes |
|---|---|---|
| Resting | 0.0% | ~15 MB, no wakeups |
| Open, nothing playing | 0.0% | the tiles' timelines tick only while music or the timer runs |
| Claude pill animating | 0.0% in the app | Core Animation draws the grid at 15 fps outside the app |
| Permission panel open | 0.4–0.5% | one-second countdown |

Not measured yet: music playing with the island open (the Music tile updates twice a second), the music pill,
the focus timer running, and the Do Not Disturb peek's 3-second check. Check them in Activity Monitor.

## Remove

```bash
./scripts/uninstall.sh
```

It turns off Launch at Login, quits and deletes the app, its settings, lyrics cache and socket folder, and resets
its permissions. Then do two things yourself: remove the five `notch-hook` entries from `~/.claude/settings.json`
(until you do, they find no app and Claude Code carries on as usual), and, if you made it, delete the
"Custom Notch Local Signing" certificate in Keychain Access → login → My Certificates.

## Developer aids

Run from the command line; none is reachable from the menu.

- Open in a given state: `open ~/Applications/Custom\ Notch.app --args -preview expanded`
  (or `compact`, `peek`, `peek-20`, `peek-10`, `peek-focus`, `city`, `script`, `prompter`, `chess`; `prompter` uses a
  sample script if you have none yet).
- Render every state in both themes to PNG and quit: `…/Contents/MacOS/CustomNotch -snapshot /tmp/notch-shots`
  (add `-live YES` for this Mac's real data instead of samples). This includes the script window, filled and
  empty, in light and dark mode (`editor-*.png`).
- `-prompterListen <script.txt> -audio <speech.aiff>` plays a recording in real time through the same speech
  recognition and script tracking as the teleprompter and prints where it thinks the speaker is (make one with
  `say -v Anna -o speech.aiff -f script.txt`); `-prompterRun YES` runs the fixed-speed scrolling without a screen;
  `-prompterLayers <file.png>` draws the teleprompter's text layers.
- `-connectClaude YES` does what **Connect Claude Code…** does, without asking, prints the result and quits.
- `-lyrics "Coldplay|Yellow|Parachutes|267"` looks up lyrics (cache first);
  `-parseProximity <hex>` decodes an AirPods Bluetooth broadcast; `-slackCheck YES` tests Slack's error path
  with a made-up token; `-focusStatus YES`, `-batteryStatus YES`, `-loginStatus YES` print those states;
  `-hookSettings YES` prints the Claude Code lines; `-appearanceTest YES` switches the app's own appearance (not
  macOS's) between dark and light and prints whether the theme followed. Each quits afterwards.
- `CUSTOM_NOTCH_SOCKET=<path>` makes `notch-hook` talk to another socket (for testing the hooks).
- `swift scripts/make-icon.swift` redraws `Resources/AppIcon.icns`.

## Files

| File | What's in it |
|---|---|
| `Package.swift`, `build.sh`, `Resources/Info.plist`, `Resources/AppIcon.icns` | Package, build/sign/install, app metadata, icon |
| `Sources/CustomNotch/App.swift` | Entry point, the services, what the pill shows |
| `Sources/CustomNotch/Menu.swift` | Menu-bar menu, city prompt, Launch at Login |
| `Sources/CustomNotch/Settings.swift` | Themes (colours), tile layout, saved settings |
| `Sources/CustomNotch/NotchPanel.swift` | Notch detection, the window, hover and clicks, states, peek queue |
| `Sources/CustomNotch/Island.swift` | Island shape and sizes, compact pill, peek, permission panel |
| `Sources/CustomNotch/Tiles.swift` | Tile grid, tile right-click menu, shared tile pieces |
| `Sources/CustomNotch/Music.swift` | AppleScript runner, Spotify / Music, lyrics (LRCLIB) and the Music tile |
| `Sources/CustomNotch/Weather.swift` | Open-Meteo and the Weather tile |
| `Sources/CustomNotch/Cards.swift` | The swipeable cards: calendar (scrolling), batteries, Slack |
| `Sources/CustomNotch/ClaudeTile.swift` | The Claude limit card |
| `Sources/CustomNotch/Batteries.swift` | Mac, Bluetooth and accessory batteries, AirPods broadcast reader |
| `Sources/CustomNotch/Slack.swift` | Slack Web API (newest messages) and the token in the keychain |
| `Sources/CustomNotch/SystemControls.swift` | Wi-Fi, AirDrop, dark mode, volume, brightness, Amphetamine, Raycast and the Quick Controls tile (chess, teleprompter buttons) |
| `Sources/CustomNotch/CalendarAndTimer.swift` | Next event (EventKit), focus timer and their tiles |
| `Sources/CustomNotch/Peeks.swift` | Charger, battery, Focus |
| `Sources/CustomNotch/Chess.swift` | Chess: rules and legal moves, the game, Claude as the opponent (`claude -p`), board and panel |
| `Sources/CustomNotch/ClaudeBridge.swift` | Claude Code: socket server, current step, permission requests, ⌃⌥ shortcuts |
| `Sources/CustomNotch/Teleprompter.swift` | Teleprompter: script layout and scrolling, its island view, the script window (SwiftUI) |
| `Sources/CustomNotch/VoiceFollow.swift` | Following your voice: microphone, on-device speech recognition, finding your place |
| `Sources/CustomNotch/DevTools.swift` | The developer flags and the snapshot renderer |
| `Sources/notch-hook/main.swift` | The helper Claude Code's hooks run (inside the app bundle) |
| `scripts/make-signing-cert.sh`, `scripts/uninstall.sh`, `scripts/make-icon.swift` | Certificate, removal, icon |
