# Velto Ops — Android APK

A native Android shell (Capacitor) that opens the live Velto Ops app
(`https://velto-ops-pwa.vercel.app`) as a real installed app: home-screen
icon, full-screen, its own task switcher entry — no browser chrome.

## How the APK is built

The Android SDK is not needed on your Mac. The APK is compiled by
**GitHub Actions** (GitHub's runners ship the Android SDK).

- Workflow: `.github/workflows/build-apk.yml`
- Trigger: automatically on any push under `apk/**`, or manually from the
  repo's **Actions** tab → **Build Android APK** → **Run workflow**.
- Output: open the finished run and download the **`velto-ops-apk`** artifact
  (a zip containing `velto-ops.apk`).

## Install on the phone

1. Download `velto-ops-apk` from the Actions run and unzip → `velto-ops.apk`.
2. Copy it to the Android phone (or download it there directly).
3. Tap it → allow "install unknown apps" for your file manager → Install.
4. Open **Velto Ops**, log in as usual.

It is a **debug-signed** APK — fine for installing on your own phones. For the
Play Store you'd switch to a release keystore later.

## What this build does / does not do (phase 1)

- ✅ Real installed app, Velto icon, full-screen, always shows the latest
  deployed web app (nothing to rebuild when the website changes).
- ⚠️ **Locked-phone push vibration is NOT solved yet.** Android's System
  WebView does not run the web-push service worker, so notifications need the
  **native FCM** path (phase 2): a Firebase project + `@capacitor/push-notifications`
  + a high-importance notification channel with a fixed vibration pattern, and
  the Supabase function sending FCM messages. That's the next step.

## What's in the repo

Only text sources are committed — the native `android/` project is generated
in CI, so there are no binaries to review:

- `capacitor.config.json` — app id, name, and the live URL it loads.
- `www/index.html` — a tiny fallback shown only before the live site paints.
- `scripts/gen-icons.py` — generates the Velto launcher icons from the repo's
  `icon-512.png` at every density (run after the native project is created).
- `package.json` — Capacitor 6 dependencies.

## Local build (optional, needs Android Studio / SDK)

```bash
cd apk
npm install
npx cap add android          # generate the native project
python3 scripts/gen-icons.py # apply Velto icons
npx cap sync android
cd android && ./gradlew assembleDebug
# → android/app/build/outputs/apk/debug/app-debug.apk
```
