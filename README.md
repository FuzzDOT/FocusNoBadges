# FocusNoBadges

> A modernized macOS utility that makes Focus modes actually hide notification badges across applications, including apps whose badge behavior macOS does not otherwise expose as a convenient public setting.

> [Go to Installation](#installation-steps)

## What this project does

`FocusNoBadges` is a small menu-bar-style macOS utility based on an older 2022 project/idea. Its job is simple:

* watch the currently active macOS Focus configuration;
* determine whether that Focus is configured to hide application badges;
* when it is, disable the badge-enable flag for notification applications;
* refresh Apple's notification daemon so the change takes effect immediately;
* when the Focus is no longer active, globally re-enable the badge-enable flag for registered notification applications.

The important distinction is that this project **does not set badge counts to zero**. It changes the preference that controls whether application icon badges are enabled, then lets `usernoted` apply that preference.

This repository is intentionally a hack around private macOS implementation details. It is not an Apple-supported API integration, and it can break if Apple changes the underlying storage format or notification architecture.

---

# Credits / original project

This project is a modernization of the original **FocusPlsNoBadges** project from 2022.

https://github.com/aydenp/FocusPlsNoBadges

**Original author:** `aydenp` and `dvagala`

The original project deserves credit for the core idea and architecture: inspect macOS's Focus/Do Not Disturb state and modify Notification Center preferences so that Focus can suppress application icon badges globally.

The current version preserves that original concept while updating the implementation for modern macOS, where several of the original private storage mechanisms no longer exist or behave the same way.

The modernization work was driven by testing the current macOS behavior directly and replacing obsolete assumptions with the storage locations and behavior actually observed on the current system.

If you fork or redistribute this project, please retain attribution to the original author and make it clear which portions are modernization work versus the original concept.

---

# How it works — the full picture

At a high level, the application sits between two pieces of macOS state:

```text
                    macOS Focus
                         │
                         ▼
        ~/Library/DoNotDisturb/DB/
        ├── Assertions.json
        └── ModeConfigurations.json
                         │
                         ▼
              FocusPlsNoBadges
                         │
              Is active Focus configured
                 to hide application badges?
                         │
                    ┌────┴────┐
                   YES       NO
                    │          │
                    ▼          ▼
       Modify notification    Restore
       badge-enable flags     badge-enable
                    │         flags globally
                    └────┬─────┘
                         ▼
  ~/Library/Group Containers/group.com.apple.usernoted/
       Library/Preferences/group.com.apple.usernoted.plist
                         │
                         ▼
                    usernoted
                         │
                         ▼
              macOS notification UI
```

The application therefore does not need to generate fake notifications, constantly manipulate individual badge counts, or simulate UI clicks. It changes the underlying preference that Notification Center uses for badge enablement.

---

# Why this needed modernization

The original 2022 implementation relied on Apple's older Notification Center preference domain:

```text
com.apple.ncprefs
```

The original code effectively did this:

```swift
UserDefaults(suiteName: "com.apple.ncprefs")!
```

and then accessed an `apps` array from that preference domain.

On the modern macOS installation used during this modernization, that domain no longer existed:

```text
Domain com.apple.ncprefs does not exist
```

and the old file:

```text
~/Library/Preferences/com.apple.ncprefs.plist
```

was not present either.

That meant the original implementation could not simply be rebuilt against current macOS and expected to work.

The solution was to find where the current notification subsystem stores the equivalent application records.

---

# The modern notification storage

The current implementation uses:

```text
~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist
```

This plist contains a top-level:

```text
apps
```

array.

Each application record can contain values including:

```text
bundle-id
flags
auth
content_visibility
grouping
path
...
```

The important fields for this project are:

```text
bundle-id
flags
```

For example, a notification application record can look conceptually like:

```text
{
    "bundle-id" = "com.apple.FaceTime";
    "flags" = 17492353038;
    ...
}
```

The app reads the entire property list, changes only the relevant bit in `flags`, and writes the plist back without intentionally disturbing the other fields.

---

# The critical discovery: badge enablement is bit `0x2`

One of the most important parts of the modernization was determining exactly which bit in the modern `flags` value controls application icon badges.

Rather than assuming the old bit remained correct, the behavior was experimentally verified.

For FaceTime, the observed values were:

```text
Badge ON   → 17492353038
Badge OFF  → 17492353036
Badge ON   → 17492353038
```

The difference is exactly:

```text
17492353038
-17492353036
-------------
           2
```

Therefore the relevant flag is:

```text
0x2
```

or, in Swift:

```swift
1 << 1
```

To disable the badge-enable bit:

```swift
flags &= ~0x2
```

To restore it:

```swift
flags |= 0x2
```

The application deliberately changes **only this bit**.

That is important because `flags` is a bit field. Replacing the entire value would risk changing unrelated notification behavior.

---

# Why we do NOT use the `badge` field in the notification database

During development, the modern notification group container was also found to contain a SQLite database:

```text
~/Library/Group Containers/group.com.apple.usernoted/db2/db
```

Its schema includes an `app` table with fields such as:

```sql
CREATE TABLE app (
    app_id INTEGER PRIMARY KEY,
    identifier VARCHAR,
    badge INTEGER NULL
);
```

At first glance, `badge` looks like it might be the setting we need.

It is not.

The `badge` value is a **live badge count**, not the preference that enables/disables badges.

This was verified experimentally:

1. FaceTime had a database `badge` value of `33`.
2. Setting FaceTime's database badge value to `0` made the visible badge disappear.
3. A new FaceTime notification caused the value to become `1` again.

That demonstrates that this field represents the current count/state, not the user's "show badges" preference.

Consequently, this project does **not** manipulate that SQLite field.

The correct target is the `flags` field in the modern `group.com.apple.usernoted.plist`, specifically bit `0x2`.

---

# How Focus detection works

The application reads two private Focus database files:

```text
~/Library/DoNotDisturb/DB/Assertions.json
```

and:

```text
~/Library/DoNotDisturb/DB/ModeConfigurations.json
```

The first describes active Focus assertions, while the second contains the Focus mode configurations used to determine how a Focus behaves.

The application periodically checks these files and determines whether the active configuration requests application badges to be hidden.

The important logic is conceptually:

```text
Current Focus
     │
     ▼
Find active assertion
     │
     ▼
Find corresponding Focus configuration
     │
     ▼
hideApplicationBadges == 2 ?
     │
   YES
     │
     ▼
Suppress badges
```

The exact JSON structures are private Apple implementation details, so this project should not be considered guaranteed to work across every future macOS release.

---

# Why Full Disk Access is required

These files are not ordinary application-owned files. macOS privacy protections can prevent an application from reading them even when the current user technically owns the underlying home directory.

The most obvious example is:

```text
~/Library/DoNotDisturb/DB/Assertions.json
```

Without the required privacy permission, Foundation can fail with an error equivalent to:

```text
Operation not permitted
```

This is a macOS privacy/TCC issue, not a Swift file-reading bug.

Apple documents that applications requiring broad access to files across the Mac may need to be explicitly granted **Full Disk Access** by the user in System Settings.

## Xcode vs. the built application

This distinction is particularly important during development.

If you run the application from Xcode, the executable being launched is associated with Xcode's development/build environment. When you later launch the standalone `.app`, that is a separate executable/code-signing identity from the perspective of macOS privacy controls.

Therefore, during development it is safest to grant Full Disk Access to:

1. **Xcode**, when debugging from Xcode.
2. **The actual built `FocusPlsNoBadges.app`**, when launching it directly.

Go to:

```text
System Settings
→ Privacy & Security
→ Full Disk Access
```

Then add/enable the relevant application.

After changing the permission, completely quit and relaunch the application. If debugging, it is also often useful to completely quit and reopen Xcode.

Apple explicitly notes that access to protected filesystem resources can be denied independently of normal POSIX permissions and that Full Disk Access is a user-granted privacy permission rather than something an application can grant itself.

---

# One development trap: `isReadableFile`

An earlier modernization attempt used a preliminary check similar to:

```swift
FileManager.default.isReadableFile(atPath: url.path)
```

That turned out to be a poor preflight test for this particular macOS privacy situation.

The current implementation instead attempts the real operation:

```swift
let data = try Data(contentsOf: url, options: [.mappedIfSafe])
```

and reports the actual failure.

This matters because macOS privacy controls are not simply equivalent to ordinary Unix readability. A path can look like it should be readable while the process is still denied by macOS's security policy.

---

# Why the plist is written directly instead of using `defaults`

Another development path attempted to access the modern preferences using higher-level preference APIs and `defaults`-style mechanisms.

That became unreliable because this is a private group-container plist belonging to Apple's notification subsystem rather than an ordinary user preference domain that the old `com.apple.ncprefs` approach could transparently address.

The current implementation therefore reads and writes the plist directly using:

```swift
PropertyListSerialization
```

The process is:

```text
Read raw plist data
      ↓
PropertyListSerialization
      ↓
[String: Any]
      ↓
Locate apps array
      ↓
Modify flags bit 0x2
      ↓
Serialize entire plist
      ↓
Write plist atomically
```

This avoids depending on a preference-domain name that no longer exists on current macOS.

---

# Why restarting `usernoted` is necessary

Changing the plist on disk is not necessarily enough by itself.

`usernoted` is Apple's notification daemon responsible for maintaining notification state and behavior. The daemon can already have notification preferences loaded in memory.

That creates this situation:

```text
plist on disk:       badges OFF

usernoted memory:    badges ON

visible macOS UI:    badges ON
```

Writing the plist changes the disk representation, but the currently running notification daemon can continue operating with the old in-memory state.

This was directly observed during development: the plist could be modified successfully, but the visible badges did not disappear until `usernoted` was terminated.

After running:

```bash
killall usernoted
```

macOS relaunched the notification daemon and the modified badge settings took effect.

The same process works in reverse when the Focus ends: the app restores the badge-enable bit globally, terminates `usernoted`, and the relaunched daemon sees the restored settings.

---

# Why the original `launchctl kickstart` workaround stopped working

The original implementation used a command along the lines of:

```bash
launchctl kickstart -k gui/$(id -u)/com.apple.usernoted
```

That was a reasonable approach for older macOS behavior, but on the current system it produced:

```text
Could not kickstart service "com.apple.usernoted":
150: Operation not permitted while System Integrity Protection is engaged
```

This is not a permissions problem that should be solved by telling users to disable SIP.

Modern macOS has tightened restrictions around forcibly kickstarting critical system processes. Apple has also documented that System Integrity Protection can cause `EPERM`/"Operation not permitted" failures when protected operations are attempted.

Apple's launchd documentation describes `launchd` as the system process responsible for managing daemons and agents.

## The successful workaround

The working solution is simply:

```bash
killall usernoted
```

The app invokes the system executable directly:

```text
/usr/bin/killall usernoted
```

The current `BadgeEnablementController` intentionally does not attempt to disable SIP or use privileged commands.

After `usernoted` exits, macOS's service management infrastructure can bring the service back, at which point it rereads the notification preferences.

This preserves SIP and was experimentally confirmed to make the badges disappear immediately on the tested system.

---

# Why we do not tell users to disable SIP

**Do not disable System Integrity Protection just to run this project.**

SIP exists specifically to protect critical parts of macOS from modification and abuse. The fact that an old `launchctl kickstart` technique stopped working under SIP is a reason to change the implementation—not a reason to weaken the operating system's security model.

The final implementation works with SIP enabled.

---

# Badge restoration behavior

When FocusPlsNoBadges suppresses badges, it clears bit `0x2` from the notification preference `flags` values.

When the Focus ends, the current implementation uses the same global restoration mechanism that was verified manually on the tested macOS system:

```swift
flags |= 0x2
```

This re-enables the badge-enable bit for every registered notification application.

After writing the updated plist, the application runs:

```bash
killall usernoted
```

so that the notification daemon reloads the updated preferences.

The restoration path intentionally uses this **global badge-enable operation** rather than attempting to reconstruct each application's previous badge state individually.

As a result, when Focus ends, application badges are globally re-enabled. If an application had its badges intentionally disabled before Focus activated, this restoration mechanism may re-enable them.

The restoration flow is therefore:

```text
Focus OFF
   ↓
Set flags bit 0x2 for registered apps
   ↓
Write modern notification plist
   ↓
killall usernoted
   ↓
Badges return
```

The app still keeps its suppression state in `UserDefaults` so it can determine whether it is currently managing a suppressed Focus state and recover after a relaunch.

---

# What the application actually changes

For every record in the modern notification `apps` array:

```swift
let bundleID = app["bundle-id"]
let flags = app["flags"]
```

When suppressing badges, if:

```swift
(flags & 0x2) != 0
```

the application changes:

```swift
flags & ~0x2
```

Everything else in the flags value is preserved.

When restoring badges, the current implementation globally enables the badge bit for registered applications:

```swift
flags | 0x2
```

The application then restarts `usernoted` so the notification system reloads the preferences.

---

# Files and architecture

The project is intentionally small.

## `AppDelegate.swift`

Application lifecycle and periodic Focus-state checking.

It coordinates the overall workflow and invokes `BadgeEnablementController` when Focus state changes.

## `BadgeEnablementController.swift`

Responsible for:

* disabling badges;
* maintaining suppression/recovery state;
* globally restoring application badges;
* saving the preference plist;
* terminating `usernoted` so the new settings are applied.

## `Model/AppNotificationPreferences.swift`

The modern notification-preference layer.

It:

* locates the modern `group.com.apple.usernoted.plist`;
* parses the plist;
* accesses the top-level `apps` array;
* reads `bundle-id` and `flags`;
* clears/sets the badge bit;
* writes the complete plist back.

## `Model/ModelFiles+Current.swift`

Loads the current Focus JSON files from:

```text
~/Library/DoNotDisturb/DB
```

It intentionally performs the actual read and surfaces the underlying macOS permission failure rather than relying on a potentially misleading readability preflight.

## `Model/AssertionsFile.swift`

Models the Focus assertions JSON.

## `Model/ModeConfigurationsFile.swift`

Models the Focus configuration JSON.

## `Model/ModeConfiguration.swift`

Represents individual Focus configurations and their relevant properties.

## `Model/AssertionRecord.swift`

Represents Focus assertion records.

## `Model/AppNotificationFlags.swift`

Contains the notification flag representation used by the model layer.

---

# Installation Steps

These instructions assume you downloaded the **source-code ZIP from GitHub** rather than a prebuilt application.

> [!WARNING]
> **Before quitting FocusPlsNoBadges, turn OFF the active Focus mode first.**
>
> If you quit the app while a Focus that hides application badges is still active, the app cannot complete its normal badge-restoration process after termination. Your notification badges will therefore remain turned off.
>
> If this happens, your badges can be recovered by **relaunching FocusPlsNoBadges while that Focus is still active, then turning the Focus OFF**. The app will detect the Focus transition and run its global badge-restoration path.
>
> **Recommended shutdown sequence:**
>
> `Turn Focus OFF → wait for badges to return → quit FocusPlsNoBadges`
>
> Do not simply quit the app while the badge-suppressing Focus is still enabled.

## Requirements

* A Mac running macOS with the Focus system used by the project.
* Xcode.
* A normal user account with permission to grant Full Disk Access.
* The downloaded source repository.

No special SIP configuration is required.

**Do not disable SIP.**

---

# Step 1 — Download and extract the source

Download the repository ZIP from GitHub and extract it.

You should see something similar to:

```text
FocusPlsNoBadges-main/
├── FocusPlsNoBadges/
├── FocusPlsNoBadges.xcodeproj/
├── Assets/
├── README.md
└── .gitignore
```

If GitHub adds `-main` or another branch name to the directory, that is fine.

---

# Step 2 — Open the Xcode project

Open:

```text
FocusPlsNoBadges.xcodeproj
```

You can double-click it in Finder or run:

```bash
open FocusPlsNoBadges.xcodeproj
```

Do not create a new Xcode project from scratch unless you intentionally want to reconstruct the project.

---

# Step 3 — Check the target

In Xcode:

1. Select the `FocusPlsNoBadges` project in the Project Navigator.
2. Select the `FocusPlsNoBadges` target.
3. Verify that the project builds as a macOS application.
4. Make sure you are building the intended target.

The project intentionally does not depend on the old `com.apple.ncprefs` preference domain.

---

# Step 4 — Build once

Use:

```text
Product → Build
```

or:

```text
⌘B
```

If the project builds successfully, continue to the Full Disk Access step.

---

# Step 5 — Grant Full Disk Access to Xcode

If you are going to run the program from Xcode's debugger:

1. Open **System Settings**.
2. Go to **Privacy & Security**.
3. Open **Full Disk Access**.
4. Enable/add **Xcode**.
5. Quit Xcode completely.
6. Reopen Xcode.

Apple's current documentation describes Full Disk Access as a user-controlled privacy permission for applications that need broad filesystem access.

---

# Step 6 — Grant Full Disk Access to the built application

If you plan to run the compiled `.app` directly, also add the actual built application.

The easiest way to locate it is from Xcode:

```text
Product → Show Build Folder in Finder
```

or use Xcode's build products location.

Find:

```text
FocusPlsNoBadges.app
```

Then add that exact application to:

```text
System Settings
→ Privacy & Security
→ Full Disk Access
```

This is especially important because the Xcode-launched executable and the standalone built application should not be assumed to have identical privacy authorization.

---

# Step 7 — Run it

Run from Xcode using:

```text
⌘R
```

The console should begin with something similar to:

```text
FocusPlsNoBadges started.

Focus DB: ~/Library/DoNotDisturb/DB

Notification prefs: ~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist
```

The presence of the **`group.com.apple.usernoted`** path is important.

If you see:

```text
~/Library/Preferences/com.apple.ncprefs.plist
```

you are running an old build/source version and should clean/rebuild.

---

# Step 8 — Test Focus activation

Enable a Focus mode whose configuration has application badges disabled.

The application should eventually log something similar to:

```text
Turning off all badges…

Will be turned off: [ ... ]

Restarting usernoted…

usernoted terminated; launchd should restart it automatically.
```

The exact bundle-ID list will depend on the applications registered with Notification Center on that Mac.

After `usernoted` restarts, application icon badges should disappear.

---

# Step 9 — Test Focus deactivation

Turn the Focus off.

The application should globally restore the badge-enable bit, terminate `usernoted` again, and allow the notification daemon to come back with badges enabled.

Badges should return across registered notification applications.

---

## Important: quitting while Focus is active

The application relies on the Focus state transition from **active → inactive** to perform its normal badge restoration. It does not restore badges simply because the process has been terminated.

For that reason, users should always disable the badge-suppressing Focus before quitting the application:

```text
Focus OFF
   ↓
Badges restore
   ↓
Quit FocusPlsNoBadges
```

If the application is quit while the Focus is still active, the badges can remain disabled. To recover them, relaunch the application while the same Focus is still active and then turn that Focus off. The application will then process the Focus transition and run its global badge-restoration path.

A forced termination, crash, or other termination that prevents the application from processing its normal state transition can have the same effect. This is a limitation of the current private-preference approach.

---

# Cleaning up an old build

If the console appears to be showing behavior from an older version, clean out Derived Data.

Quit Xcode first, then run:

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/FocusPlsNoBadges-*
```

Reopen the current project and build again.

This is particularly useful if the console still references:

```text
com.apple.ncprefs
```

because the current implementation should reference:

```text
group.com.apple.usernoted
```

instead.

---

# Troubleshooting

## Error: `Assertions.json` cannot be read

Typical error:

```text
Operation not permitted
```

### Fix

Grant Full Disk Access to the application that is actually executing the code.

For Xcode debugging:

```text
Xcode → Full Disk Access
```

For direct execution:

```text
FocusPlsNoBadges.app → Full Disk Access
```

Then completely quit and relaunch it.

Do not assume that granting Xcode permission automatically grants the same permission to a separately launched `.app`.

---

## Error: console references `com.apple.ncprefs`

That means you are running an old version of the project.

The modern implementation should reference:

```text
~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist
```

Clean Derived Data and rebuild.

---

## Error: badges do not disappear

Check the log.

The expected sequence is:

```text
Turning off all badges…
Will be turned off: [...]
Restarting usernoted…
usernoted terminated; launchd should restart it automatically.
```

If the app successfully reports that `usernoted` was terminated but badges do not change, verify that the plist was actually written and that the current macOS version still uses the same private notification storage format.

The project intentionally depends on private implementation details, so a future macOS update may require another reverse-engineering pass.

---

## Error: `launchctl kickstart` / SIP

If you see:

```text
Operation not permitted while System Integrity Protection is engaged
```

you are using the old restart mechanism.

The current implementation should use:

```bash
killall usernoted
```

Do **not** disable SIP as a workaround.

---

## `killall usernoted` says the process was not found

This can happen if `usernoted` is not currently running or if macOS has already restarted it.

The important question is whether the notification daemon ultimately reloads the modified preferences.

The restart mechanism is intentionally best-effort rather than an attempt to manage Apple's service through privileged system-level launchd operations.

---

# Manual diagnostic commands

These commands can help developers investigate a new macOS version.

## Check whether the old preference domain exists

```bash
defaults read com.apple.ncprefs
```

On the modern system used during this modernization, this returned:

```text
Domain com.apple.ncprefs does not exist
```

That is why this project no longer depends on it.

---

## Inspect the modern plist

```bash
defaults read ~/Library/Group\ Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist
```

To find a particular application:

```bash
defaults read ~/Library/Group\ Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist | grep -A 8 -B 2 'bundle-id.*com.apple.FaceTime'
```

The exact formatting of `defaults` output can change, so direct plist parsing is preferred by the application itself.

---

## Inspect the SQLite notification database

The modern group container also contains:

```text
~/Library/Group Containers/group.com.apple.usernoted/db2/db
```

You can inspect its schema with:

```bash
sqlite3 ~/Library/Group\ Containers/group.com.apple.usernoted/db2/db '.schema'
```

Again, do not confuse:

```text
app.badge
```

with the badge-enable preference.

The former is a live count/state; the latter is controlled by the `0x2` bit in the notification preference `flags` value.

---

# Security / privacy considerations

This project deserves a clear warning because it requests unusually broad filesystem access.

Granting Full Disk Access allows an application to access protected files that normal applications cannot access. Apple specifically treats this as a privacy-sensitive capability controlled by the user.

Only run a build you trust.

Because this project is designed to inspect and modify private macOS notification state, users should understand that it is not equivalent to a normal App Store application using a documented API.

The project does not need SIP disabled.

The project does not need root privileges for its normal operation.

The project should not ask users to disable SIP merely to make `usernoted` restart work.

---

# Compatibility warning

This project is tied to private macOS implementation details.

Apple can change any of the following without maintaining source compatibility:

* `DoNotDisturb/DB` file formats;
* Focus JSON structures;
* notification group containers;
* `group.com.apple.usernoted.plist`;
* the `apps` array;
* application record keys;
* the meaning of notification `flags`;
* the `0x2` badge bit;
* `usernoted` process/service behavior;
* filesystem privacy rules;
* TCC authorization behavior;
* launchd restrictions.

Therefore:

> **If a future macOS release breaks this application, assume the private implementation changed before assuming the Swift code is wrong.**

The correct modernization process is to inspect the new storage, experimentally identify the relevant preference, and verify the daemon reload mechanism again.

---

# How the 2022 → modern macOS development path evolved

For future maintainers, this is the condensed development history.

## 1. Original implementation

The original project used:

```text
com.apple.ncprefs
```

and an `apps` array containing notification application preferences.

The badge bit was manipulated there.

## 2. First modern failure: Focus database access

Modern macOS denied access to:

```text
~/Library/DoNotDisturb/DB/Assertions.json
```

with an `Operation not permitted` error.

This was determined to be macOS privacy/TCC protection rather than a malformed JSON file.

Full Disk Access solved that part.

## 3. Second modern failure: old notification preferences disappeared

The old domain:

```text
com.apple.ncprefs
```

was gone.

The old:

```text
~/Library/Preferences/com.apple.ncprefs.plist
```

was also absent.

The search moved to the modern `usernoted` group container.

## 4. Modern storage discovered

The relevant plist was found at:

```text
~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist
```

and it contained the expected application records.

## 5. SQLite database investigated

The modern notification database exposed an `app.badge` field.

That initially looked promising but was experimentally shown to be the live badge count.

Changing it to zero hid a badge only until the next notification changed the count again.

Therefore it was rejected as the control mechanism.

## 6. Badge flag experimentally identified

FaceTime's `flags` value was compared with badges on and off.

The exact difference was:

```text
2
```

which established:

```text
badge enablement = flags bit 1 = 0x2
```

## 7. Direct plist serialization adopted

Instead of relying on the nonexistent old preference domain, the app now parses and writes the current plist directly using `PropertyListSerialization`.

## 8. Old `launchctl kickstart` failed

The plist was successfully modified, but the visible badges did not change until `usernoted` reloaded its preferences.

The old:

```bash
launchctl kickstart -k gui/$(id -u)/com.apple.usernoted
```

failed under current macOS with SIP enabled.

## 9. `killall usernoted` succeeded

Manually running:

```bash
killall usernoted
```

caused the daemon to come back and immediately apply the modified preference.

The app was therefore changed to use the same mechanism programmatically.

## 10. Final result

The complete modern workflow was confirmed:

```text
Focus ON
   ↓
Read Focus DB
   ↓
Detect hide-badges configuration
   ↓
Clear flags bit 0x2
   ↓
Write modern notification plist
   ↓
killall usernoted
   ↓
Badges disappear

Focus OFF
   ↓
Set flags bit 0x2 for registered apps
   ↓
Write modern notification plist
   ↓
killall usernoted
   ↓
Badges return
```

---

# Design principles for future maintainers

If you modify this project later, preserve these properties unless you have a very good reason not to.

### 1. Do not use the old `com.apple.ncprefs` domain

It is not present on the modern system for which this version was developed.

### 2. Do not use `app.badge` as the enable/disable preference

That is a live badge count/state.

### 3. Change only bit `0x2`

Do not replace the entire `flags` value.

### 4. Use the proven global restoration path

When Focus ends, re-enable the badge bit (`0x2`) for registered notification applications and restart `usernoted`. This is the restoration mechanism verified on the tested macOS system.

### 5. Do not disable SIP

The application has a working SIP-compatible refresh mechanism.

### 6. Keep the actual filesystem read errors

Do not rely solely on `FileManager.isReadableFile` to diagnose protected macOS resources.

### 7. Expect private APIs/storage to change

Treat every macOS major/minor release as a potential compatibility break.

---

# License / attribution note

The original project's license and repository terms should be preserved from the upstream source repository. If you redistribute a modified copy, retain the original copyright/license information present in the upstream project and clearly identify your modernization changes.

This README intentionally credits the original author for the underlying project and idea while documenting the current implementation and modernization work separately.

---

# Final note

This project exists because macOS's public Focus and notification APIs do not provide the exact global badge-suppression behavior this utility is trying to achieve.

That is also why the implementation is necessarily somewhat unconventional.

The core trick is surprisingly small:

```text
Find the modern notification preferences
            ↓
Find each app's flags
            ↓
Clear bit 0x2
            ↓
Restart usernoted
```

When Focus ends, the same preference is restored globally:

```text
Find the modern notification preferences
            ↓
Set bit 0x2 for registered apps
            ↓
Restart usernoted
```

The hard part was discovering that the private interfaces used by the original 2022 project had moved, determining which modern data actually represented badge enablement, dealing with macOS TCC protection, and finding a SIP-compatible way to make `usernoted` reload the modified preferences.

As of the macOS environment against which this modernization was tested, that combination works.

**Have fun, don't disable SIP, and remember that Apple can change all of this whenever it wants.**
