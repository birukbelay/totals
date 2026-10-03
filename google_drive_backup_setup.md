# Google Drive Backup Setup

Google Drive backup saves Totals backups to the hidden app folder
(`appDataFolder`) of the user's own Google Drive. It uses only the
`https://www.googleapis.com/auth/drive.appdata` scope, so Totals cannot see
or change any other Drive file, and no Totals server is involved.

Sign-in goes through Google Play services (`AuthorizationClient`) in the
local `packages/totals_google_auth` plugin. Play services only issues tokens
to builds whose package name and signing certificate are registered in a
Google Cloud project, so each build needs the steps below once.

## 1) Google Cloud project

1. Open <https://console.cloud.google.com/> and create or select a project.
2. **APIs & Services → Library**: enable the **Google Drive API**.

## 2) OAuth consent screen

1. **APIs & Services → OAuth consent screen** (Google Auth Platform →
   Branding / Audience / Data Access).
2. User type: **External**. Fill in the app name, support email and the
   privacy policy URL.
3. **Data Access → Add or remove scopes**: add
   `https://www.googleapis.com/auth/drive.appdata`. It is a non-sensitive
   scope, so publishing the app does not need Google's security review.
4. While the consent screen is in **Testing**, only the listed test users
   can sign in. Publish it to let everyone connect.

## 3) Android OAuth clients

Create one **Android** OAuth client (**APIs & Services → Credentials →
Create credentials → OAuth client ID**) for every package name and signing
certificate that should be able to sign in:

| Flavor   | Package name           |
| -------- | ---------------------- |
| `stable` | `detached.totals`      |
| `qa`     | `detached.totals.test` |

Each client needs the SHA-1 of the certificate that signs the APK:

```bash
# Debug builds (default debug keystore)
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android

# Release builds (the keystore from android/key.properties)
keytool -list -v -keystore <path-to-release.jks> -alias <keyAlias>
```

For Play Store builds signed by Google Play App Signing, also register the
**App signing key certificate** SHA-1 from Play Console → Setup → App
signing.

No client ID or `google-services.json` goes into the app: Play services
matches the running app's package and certificate against these clients.

## 4) Build

```bash
cd app
flutter pub get
flutter run --flavor qa
```

`flutter pub get` picks up the `totals_google_auth` path dependency and the
`com.google.android.gms:play-services-auth` dependency of its Android
module.

## Troubleshooting

| Message in Totals                                  | Cause                                                                                   |
| -------------------------------------------------- | --------------------------------------------------------------------------------------- |
| "Google sign-in is not set up for this build"      | Play services error `10`: the package name or SHA-1 of this build has no OAuth client.  |
| "The Google Drive API is not enabled for this app" | Enable the Google Drive API in the same Cloud project.                                  |
| "Google sign-in was cancelled"                     | The user closed the consent screen, or is not a test user while the app is in Testing. |
| Settings has no "Google Drive Backup" entry        | The device is not Android.                                                              |

## How backups are stored

- Each backup is a full `DataExportImportService` export, encrypted on-device
  with the same AES-256-GCM format and recovery-key scheme as Telegram backup
  (`.totals` files). Encryption can be turned off, which uploads plain JSON
  (`.json`).
- Drive `appProperties` on each file hold the export schema version, a
  SHA-256 of the uploaded bytes and a fingerprint of the recovery key, so
  the restore list can tell which backups this device can open.
- Totals keeps the newest 3, 5, 10 (default) or 20 backups and deletes older
  ones after each upload.
- Scheduled backups reuse the Telegram backup daily/weekly timing (after the
  daily summary time) and only run on a network connection.
- Disconnecting keeps the backups in Drive and the recovery key on the
  device. Users can delete the app folder data from
  drive.google.com → Settings → Manage apps → Totals → Delete hidden app data.
