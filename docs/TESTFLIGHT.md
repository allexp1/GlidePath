# Shipping to TestFlight

`.github/workflows/testflight.yml` builds a signed archive and uploads it to
App Store Connect. Once the setup below is done, releasing is one of:

- **Actions → TestFlight → Run workflow**, or
- `git tag v1.0.1 && git push origin v1.0.1`

Both are deliberate acts. The workflow never runs on a normal push: uploading
consumes a build number and puts something in front of testers, and neither of
those should happen because somebody fixed a typo.

---

## What has to be done by hand once

None of this can be scripted from CI. All of it is a one-off.

### 1. An Apple Developer Program membership

$99/year, at [developer.apple.com/programs](https://developer.apple.com/programs/).
A free account cannot use TestFlight. Note your **Team ID** — 10 characters,
under Membership details.

### 2. A bundle identifier you own

The repository ships `ai.glidepath.app` as an example. It must be globally
unique, so unless you own that domain, pick your own, then register it at
[Certificates, Identifiers & Profiles → Identifiers](https://developer.apple.com/account/resources/identifiers/list).

Nothing else needs the app-services checkboxes: GlidePath uses background
location and audio, both of which are Info.plist keys rather than capabilities.

### 3. An app record in App Store Connect

[App Store Connect → Apps → +](https://appstoreconnect.apple.com/apps). Pick the
bundle identifier from step 2. The build cannot be uploaded until the record
exists; the error if you skip this says the bundle identifier cannot be found,
which reads like a signing problem and is not.

### 4. A distribution certificate, exported as .p12

If you already have one on a Mac, export it from Keychain Access: **My
Certificates**, right-click *Apple Distribution: …* → Export, choose .p12, set a
password. Make sure you export the row with the disclosure triangle — that is
the one carrying the private key, and the certificate on its own cannot sign.

If you do not have one, create it in Xcode (Settings → Accounts → Manage
Certificates → + → Apple Distribution) and then export it the same way.

```sh
base64 -i Distribution.p12 | pbcopy
```

### 5. An App Store Connect API key

[Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api)
→ **+**. Give it the **App Manager** role; anything less cannot upload builds.

Download the `.p8`. **Apple lets you download it exactly once.** Note the Key ID
and the Issuer ID from the same page.

```sh
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

Both this and the certificate are stored base64 because they are binary or
newline-sensitive, and pasting either raw into the GitHub secrets UI corrupts
them in a way that only shows up as a signing failure twenty minutes into a
build.

---

## The secrets

**Settings → Secrets and variables → Actions → New repository secret.**

| Secret | What it is |
| --- | --- |
| `APPLE_TEAM_ID` | 10-character Team ID from step 1 |
| `APPLE_BUNDLE_ID` | The identifier from step 2, e.g. `com.example.glidepath` |
| `APPLE_DISTRIBUTION_CERT_P12` | base64 of the .p12 from step 4 |
| `APPLE_DISTRIBUTION_CERT_PASSWORD` | The password you set when exporting it |
| `APP_STORE_CONNECT_KEY_ID` | Key ID from step 5 |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID from step 5 |
| `APP_STORE_CONNECT_PRIVATE_KEY` | base64 of the .p8 from step 5 |
| `SUPABASE_URL` | Project host **without** `https://`, e.g. `abc.supabase.co` |
| `SUPABASE_ANON_KEY` | The anon key |

The workflow checks all nine before it builds anything, because a missing secret
otherwise surfaces at the last step of a twenty-minute job.

The anon key is safe in a client binary — every table is behind row level
security and it grants public read on camera data and insert-only on reports —
but it lives in a secret rather than the repository so that a fork does not
inherit a working key.

---

## Version and build numbers

The **build number** must be unique for a given marketing version, or App Store
Connect rejects the upload after the entire build has already run. The workflow
uses the GitHub run number, which only ever increases.

If you have already uploaded builds by hand, the run number may collide with one
of them. Pass an explicit `build_number` on the first dispatch to get above your
existing highest, and the run number will overtake it naturally after that.

The **marketing version** comes from, in order: the workflow input, the tag
(`v1.2.3` → `1.2.3`), or `MARKETING_VERSION` in `ios/project.yml`.

`manageAppVersionAndBuildNumber` is off in the export options, so Xcode uses the
numbers it was given rather than quietly incrementing them behind your back.

---

## Testers

By default an upload is marked **internal testing only**, so it goes to members
of your App Store Connect team and nobody else. Internal testing needs no review
and the build is usually available within about fifteen minutes.

Tick **notify_testers** when dispatching to make it available to external
groups. External testing needs Beta App Review the first time, which takes a day
or so. Whether a build actually reaches an external group is still controlled in
App Store Connect, not here.

---

## Things App Store Connect will ask about

**Export compliance.** `ITSAppUsesNonExemptEncryption` is already `false` in
`ios/project.yml`. GlidePath uses HTTPS and nothing else, which is exempt. Without
that key, every single build stops and waits for a human to answer a question.

**Background location.** The app declares the `location` background mode and asks
for Always authorization, so Beta App Review — and later App Review — will want
to know why. The answer is in the README: a zone geofence has to be able to wake
a terminated app so it can start coaching before the entry camera. Have a
screen recording ready; this is the single most common rejection for an app of
this shape.

**Background audio.** The `audio` background mode is there so a spoken warning is
audible while another navigation app is on screen and the phone is locked. Say
so plainly. Do not describe GlidePath as a media app.

**What to test.** Worth writing, because "watch it warn you about a camera"
requires the tester to drive past one. Point them at a country with data, tell
them to download it in Settings first, and tell them what the app sounds like
when it is working.

---

## Doing it from a Mac instead

The workflow is the supported path, but the same thing by hand is:

```sh
make archive      # builds ios/build/GlidePath.xcarchive
make testflight   # exports that archive and uploads it
```

`make testflight` reads the same API key from environment variables:

```sh
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export ASC_KEY_PATH=~/private_keys/AuthKey_XXXXXXXXXX.p8
```

It uses whatever signing identity is already in your login keychain, which on a
Mac that has ever opened Xcode is normally the right one.

---

## When it fails

**"No signing certificate Apple Distribution found"** — the .p12 did not import.
Almost always the export in step 4 caught the certificate without its private
key. Re-export from the row with the disclosure triangle.

**"Cannot find bundle identifier"** — step 3 was skipped, or `APPLE_BUNDLE_ID`
does not match the app record.

**"The provided entity includes an attribute with a value that has already been
used"** — the build number is taken. Dispatch again with a higher
`build_number`.

**"Invalid Bundle. UIRequiredDeviceCapabilities"** — should not happen; the
manifest declares `arm64`. It did once declare `armv7`, which means 32-bit ARM
and which no device running iOS 26 is.

**"Missing required icon"** — `AppIcon.png` did not make it into the asset
catalogue. Regenerate with `python3 scripts/generate-app-icon.py`.

The icon in the repository is a **placeholder**, generated by that script so
there was something valid to upload at all. It should be replaced with real
artwork before anyone outside the team sees it.
