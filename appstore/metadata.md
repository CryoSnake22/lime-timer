# Lime Timer — App Store Connect metadata

Copy each block into the matching field. Character counts are checked against Apple's limits.

## App Information
- **Name:** Lime Timer: Corner Timer
- **Subtitle** (29/30): `Keyboard-first floating timer`
- **Category:** Primary **Productivity**, secondary **Utilities**
- **Content rights:** No third-party content

## Pricing and Availability
- **Price:** $4.99 (USD tier). Enroll in the App Store Small Business Program (15% commission).

## Version 1.0 — Product Page
**Promotional Text** (135/170, can be changed anytime without review):
```
A timer you control entirely from your keyboard. Start, pause and stop it from any app with a keystroke, and it floats quietly in your screen's corner.
```

**Description:**
```
Lime Timer is a timer you control entirely from your keyboard.

Start, pause, stop and edit timers from any app with a single shortcut — no switching windows, no reaching for the mouse. It floats as a small, quiet card in the corner of your screen, and shows its controls only when you hover over it.

KEYBOARD CONTROLLED — FROM ANY APP
• ⌃⌥N — new timer: type "25m focus", "1h30 deep work", "90s" or "1:30" and press Return
• ⌃⌥P — pause / resume
• ⌃⌥S — stop
• ⌃⌥R — restart
• ⌃⌥E — change the time of a running timer
• ⌃⌥J / K — switch between timers
• ⌃⌥H — hide / show

SUBTLE UNTIL YOU NEED IT
At rest it's just a tiny card with the time. Hover over it and the controls slide in: pause, stop, reset, and the list of all your timers.

COUNTDOWNS AND STOPWATCHES
Type a duration for a countdown, or leave it blank for a stopwatch. Run as many as you like. Each timer keeps a running total of the time you spent paused.

KNOWS WHEN TIME IS UP
A chime, a shake and a red border when a countdown finishes, and a satisfying "ta-ding" when you stop a timer. Every alert can be turned off.

MAKE IT YOURS
Adjust the background opacity, turn on a frosted blur, drag the card anywhere — it remembers where you left it.

PRIVATE BY DESIGN
No account, no tracking, no network access. Nothing leaves your Mac.
```

**Keywords** (93/100 — don't repeat words already in the name):
```
countdown,stopwatch,focus,pomodoro,productivity,menu bar,overlay,shortcut,study,always on top
```

- **Support URL:** `https://cryosnake22.github.io/lime-timer/`
- **Marketing URL:** optional — `https://github.com/CryoSnake22/lime-timer`
- **Copyright:** `2026 Charles-Antoine Pouliot`

**Screenshots:** `appstore/screenshots/01-rest.png` … `04-settings.png` (2880×1800, Mac).

## App Review Information
- **Sign-in required:** No
- **Notes:**
```
Lime Timer is a menu-bar style utility (no Dock icon). On launch it shows a small panel in the top-right corner of the screen.

How to test:
1. Type "1m test" in the panel and press Return — a timer starts in the corner.
2. Hover the mouse over the timer card to reveal Pause / Stop / Reset.
3. Global shortcuts (registered with the Carbon RegisterEventHotKey API; no Accessibility permission needed):
   ⌃⌥N new timer, ⌃⌥P pause/resume, ⌃⌥S stop, ⌃⌥R restart, ⌃⌥E edit time, ⌃⌥, settings.
4. Settings: click the gear on hover, or press ⌃⌥, — includes the privacy policy link and a Quit button (⌘Q also quits while the panel is focused, or use the timer icon in the menu bar → Quit).

Launch at Login is off by default and only enabled when the user turns it on in Settings (SMAppService).
The app does not collect any data or use the network.
```

## App Privacy
- **Privacy Policy URL:** `https://cryosnake22.github.io/lime-timer/privacy.html`
- **Data collection:** "No, we do not collect data from this app" → **Data Not Collected**

## Age Rating
Answer **None / No** to every question → rated 4+.

## Encryption (Export Compliance)
Already answered in the build: `ITSAppUsesNonExemptEncryption = NO` (the app uses no encryption).
