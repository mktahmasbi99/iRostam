# iRostam

iRostam is a private, offline exercise ledger for iPhone, based on the
[Rostam web app](https://github.com/mktahmasbi99/Rostam). It stores your ledger
in SQLite on your phone. You can record and review your data without an account,
an internet connection, or a running server.

- Log individual sets throughout the day or group them into live and backfilled
  workouts.
- Manage your exercise library, review exercise history, and follow rotations.
- Track timed activities, daily notes, progress photos, and body measurements.

## Why Rostam?

iRostam takes its name from Rostam, the legendary hero of Ferdowsi’s
*Shahnameh* (*Book of Kings*).

## Install from Xcode

You need a Mac with Xcode, Node.js 24 or later, and an iPhone. The project's
deployment target is iOS 15.0.

From the repository root:

```sh
cd frontend
npm ci
npm run build
npx cap copy ios
open ios/App/App.xcodeproj
```

1. In Xcode, select the **App** target and choose your team under
   **Signing & Capabilities**. If signing requires a different bundle
   identifier, choose a unique one and keep it for future updates.
2. Connect and unlock your iPhone, select it as the run destination, and press
   **Run**. Follow any prompts to trust the Mac or enable Developer Mode.
3. Open iRostam and choose **Start fresh** or **Restore backup**.

After changing the frontend, rerun `npm run build` and `npx cap copy ios`
before pressing **Run** again. Update the existing app in place. Deleting it
or switching to a different app identity can leave its local ledger inaccessible.

With a free Xcode Personal Team, the signing profile expires after seven days.
The Debug build can schedule a local reminder 24 hours before the profile expires
if you allow notifications. To renew the installation, run the app again from
Xcode using the same signing team and bundle identifier.

## Back up or move your ledger

- **Automatic backups** are optional. In Settings, choose a folder in Files
  (including iCloud Drive), then enable the switch. iRostam saves an initial
  snapshot and checks on launch, when you return to the app, and after ledger
  changes. It saves at most one changed snapshot per local calendar day; missed
  days result in one current snapshot the next time you use the app. Retention
  defaults to three backups and can be adjusted with the stepper. iRostam retains
  only its own recognized automatic backup files in the chosen folder. Settings
  lists direct `.sqlite3` files there, labeled Automatic or On-demand, without
  scanning subfolders. Disabling backups leaves saved files in place. “Saved to folder” means the selected provider
  accepted the file; cloud upload timing depends on that provider.
- **Settings → Back Up Now** exports a `.sqlite3` snapshot, including your
  progress photos, to a location you choose in Files. Save a copy outside the app
  before deleting it, changing signing identity, or moving to another phone.
- **Restore backup** on first launch or **Settings → Restore from Files** lets
  you choose a supported iRostam or Rostam backup. If you're moving from the web
  app, export a backup from Rostam and open that file on your iPhone.
- Restoring replaces the local ledger. If a previous ledger was saved during
  restore, **Restore Previous Ledger** lets you recover it.
- To restore an automatic backup, choose its `.sqlite3` file using **Settings →
  Restore from Files**. Automatic backups use the same validated SQLite format
  as manual exports.

## Development

The interface lives in `frontend/src`, and the iOS project and local SQLite
code live in `frontend/ios/App`. Capacitor bundles the compiled interface into
the iOS app. The inherited Python backend supports repository tests and is not
needed to run iRostam on the phone. See [AGENTS.md](AGENTS.md) for the test
commands.

## License

iRostam is [MIT licensed](LICENSE). Exercise artwork comes from Bryl Lim's
Workout Guide and is licensed under CC BY-SA 4.0. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution.
