# D-bloater

[![Version](https://img.shields.io/badge/version-v1.2.0-blue)](../../releases/latest)
[![Platform](https://img.shields.io/badge/KernelSU%20%7C%20APatch-WebUI%20module-green)](#requirements)

A KernelSU / APatch module that lets you debloat system apps from a WebUI. Every app gets a **risk rating**, you can **filter and sort** by risk, size, running status and more, and everything you do is **reversible** with one tap.

<p align="center">
  <img src="docs/screenshots/01-list.png" width="23%" alt="Package list with risk, size and running badges">
  <img src="docs/screenshots/02-details.png" width="23%" alt="App details with APK size and running status">
  <img src="docs/screenshots/03-confirm.png" width="23%" alt="Confirmation sheet with safety warning">
  <img src="docs/screenshots/04-menu.png" width="23%" alt="Menu with providers, export and import">
</p>

## Features

- **Risk ratings** for every package: Safe, Replace, Caution, Unsafe, Unknown, Critical.
- **Filter** by risk, state (enabled, disabled, uninstalled, systemless), list (Google, AOSP, OEM, Carrier, Misc, Unlisted) and free-text search.
- **Sort** by name, APK size, on-disk size, running status, risk, state, list, package name and more (13 options).
- **App details** card with description, warnings, dependencies, APK size, on-disk size, live running status and APK path.
- **Three removal methods**: Disable, Uninstall for user 0, or Systemless remove. All are undoable.
- **Safety first**: confirmation sheet with dependency warnings, an extra tick-box for risky packages, a protected Critical list and a bootloop guard.
- **Package list providers**: add, remove, enable and update online lists. Supports the android-debloat-list and UAD-NG JSON formats.
- **Export / import** your debloat list to and from internal storage.
- **Re-applied at boot**: disabled and uninstalled apps are put back in that state after every boot, for example after an OTA.

## Requirements

- Android with root through **KernelSU** or **APatch**, using a manager that provides the WebUI bridge (`ksu.exec`). The module opens from its **WebUI** button.
- Magisk has no built-in WebUI. A WebUI host app such as MMRL or KsuWebUI may work, but this is unverified.
- Internet access is only needed for the optional online list providers.

<!-- TODO: list the devices / ROMs / manager versions you have tested on. -->

## Install

1. Download `D-bloater-vX.Y.Z.zip` from the [latest release](../../releases/latest).
2. In your KernelSU or APatch manager open **Modules**, choose **Install** and select the zip.
3. **Reboot.** The module is activated on the next boot.
4. Open **D-bloater** in the Modules list and tap its **WebUI** button.

If the header says `demo mode (no KernelSU bridge)`, the page was opened outside a root manager and nothing will change on your device.

## Quick start

1. Wait for the scan to finish. Sizes and running status fill in a moment later.
2. Pick a filter, for example the **Safe** chip, and tap a card to read what the app does.
3. Tick the apps you want to remove. The bottom bar shows how many are selected and their total APK size.
4. Choose **Disable** first. Use Uninstall or Systemless only when you are sure.
5. Not happy? Select the app again and tap **Restore**, or use **menu, Restore everything**.

## Removal methods

| Action | What it does | Undo |
|---|---|---|
| **Disable** | `pm disable-user --user 0`. The app stays installed but cannot run. | Restore, instant |
| **Uninstall (user 0)** | `pm uninstall -k --user 0`. Removed for the main user, the APK stays on `/system`. | Restore, instant |
| **Systemless remove** | Hides the app folder with a module overlay (`.replace`). | Restore, then reboot |

Systemless removal is applied on the next boot. It refuses packages it cannot hide safely: apps with a user-installed update, APEX modules, and layouts or partitions the overlay does not cover (for example `/my_product`). Use Uninstall for those.

Your choices are stored in `/data/adb/dbloater/` and re-applied about 15 seconds after boot, so an OTA or app update cannot silently bring bloat back.

## Risk ratings

| Rating | Meaning |
|---|---|
| **Safe** | Listed as safe to remove. |
| **Replace** | Fine to remove once you have installed an alternative (keyboard, launcher, camera and so on). |
| **Caution** | May break a feature. Read the warning first. |
| **Unsafe** | Can break the system or cause a bootloop. You must tick an acknowledgement to continue. |
| **Unknown** | Not in any enabled list. Prefer Disable. |
| **Critical** | Built-in protected list. Hidden by default, can only be disabled, never uninstalled. |

When two lists disagree about a package, the **stricter rating wins**. Ratings from UAD-NG lists map as Recommended to Safe, Advanced and Expert to Caution, Unsafe to Unsafe.

### The Critical list

`android`, System UI, Phone, Settings, Bluetooth, Shell, Permission Controller, Package Installer, Keychain, Telecom server, Input devices, External storage, Fused location, Module metadata, `com.android.providers.*`, `com.android.networkstack*`, `com.android.wifi*`, `com.android.internal.*`, and the Google Permission Controller, Package Installer and Wi-Fi packages.

Critical packages are hidden until you choose **menu, Show critical packages** or the **Critical** filter chip. You *can* disable them, behind a red warning and a tick-box, but Uninstall and Systemless remove are refused in both the UI and the backend. Disabling a core component can leave the device without UI, calls or a working boot. If that happens, from a PC:

```sh
adb shell pm enable --user 0 <package>
```

## Sizes, running status and sorting

- **APK size** is the base APK plus any split APKs. **On disk** is the whole app folder (APK, native libraries, odex).
- **Running** means a live process exists for the package. A process is matched to the installed package with the longest matching name prefix, so `com.google.android.gms.persistent` counts for Play Services. It is a good guide, not a guarantee, because a process can use an unrelated name. The details card re-checks it every time it opens. Disabled and uninstalled apps are never shown as running.
- **Sort options**: Name A–Z / Z–A, APK size largest / smallest first, on-disk size, running first / not running first, risk safest / riskiest first, state, list / source, listed packages first, package name. Packages with an unknown size always sort last.

## Package lists and providers

A curated list of **193 entries** (Google 53, AOSP 55, OEM 62, Carrier 5, Misc 18) is bundled in `webroot/db.js` and is always used, so the module works offline.

Open **menu, Package list providers** to manage online lists:

- The default provider is [MuntashirAkon/android-debloat-list](https://github.com/MuntashirAkon/android-debloat-list).
- **Add** a provider with one or more HTTPS JSON URLs. Both the android-debloat-list format (an array of objects) and the UAD-NG format (an object keyed by package name) are accepted. For example, the UAD-NG list is `https://raw.githubusercontent.com/Universal-Debloater-Alliance/universal-android-debloater-next-generation/main/resources/assets/uad_lists.json`.
- **Turn off**, **update** or **delete** any provider. Downloaded entries are cached, and a provider is only added if its first download succeeds.
- Each app's details card shows which providers list it.

Online lists are downloaded at runtime and are not redistributed in this repository.

## Export and import

**Menu, Export list** writes a JSON file to `/sdcard/D-bloater/` containing your selected apps, the apps already debloated, or both. **Menu, Import list** reads any `.json` or `.txt` file from that folder, or pasted text, and lets you select the matching apps or apply the saved actions through the normal confirmation sheet. Protected packages and packages that are not on the device are skipped.

```json
{
  "app": "D-bloater",
  "format": 1,
  "created": "2026-10-18T03:00:00.000Z",
  "packages": [
    { "id": "com.android.egg", "label": "Android Easter Egg", "action": "disable" },
    { "id": "com.google.android.videos", "label": "Google TV", "action": "uninstall" }
  ]
}
```

`action` is one of `disable`, `uninstall`, `sysrm` or `select` (select only, no action). A plain text file also works, with one package name per line. Lines starting with `#` are ignored. Plain text entries are selected only, with no saved action.

## Safety and recovery

- **Confirmation first**: every action shows what will happen, dependency warnings and a rating summary before anything runs.
- **Backend checks**: package names are validated, and the Critical list is enforced in `bin/dbl.sh`, not only in the UI.
- **Bootloop guard**: if the device fails to finish booting 3 times in a row while systemless removals exist, the module disables itself so the next boot is clean. Re-enable it in your manager afterwards.
- **Manual recovery** from recovery or adb: delete `/data/adb/modules/dbloater`, or create an empty file named `disable` inside it.
- **Before uninstalling the module**, use **menu, Restore everything** so disabled and uninstalled apps come back.

Removing system apps can affect updates, features and stability. Back up your data first and use Disable before anything stronger.

## Command line

The WebUI is a front end for `bin/dbl.sh`. You can use it from a root shell:

```sh
su -c "sh /data/adb/modules/dbloater/bin/dbl.sh <command> [package ...]"
```

| Command | Purpose |
|---|---|
| `scan` | Dump package state |
| `info` | APK size, on-disk size and running processes |
| `running` | Running processes only |
| `disable` / `enable` | `pm disable-user` / `pm enable` for user 0 |
| `uninstall` / `restore` | Uninstall for user 0 / bring it back |
| `sysrm` / `sysunrm` | Queue / undo a systemless removal |
| `restoreall` | Undo everything D-bloater has done |
| `reapply` | Re-apply saved states (run automatically at boot) |
| `log` | Show the action log |
| `files` / `readfile` / `writefile` | List, read and write import and export files |

Action commands print one `STATUS|package|message` line per package.

## Troubleshooting

| Problem | What to check |
|---|---|
| No WebUI button | Your manager must support module WebUIs. Update it, or use a WebUI host app. |
| Header says demo mode | The page is not running inside a root manager. Open it from the module's WebUI button. |
| Sizes show as unknown | The `info` command could not read the package folders. Check root access. |
| Running shows as unknown | `ps` could not be read in the manager's shell. Everything else still works. |
| Systemless removal does nothing | Reboot first. If the app is still there, its layout is unsupported, so use Uninstall. |
| An app came back after an OTA | Disabled and uninstalled apps are re-applied about 15 seconds after boot. If one is still back, run `su -c "sh /data/adb/modules/dbloater/bin/dbl.sh reapply"`. |
| Export or import fails | `/sdcard/D-bloater/` must be writable by root and `base64` must exist in the manager's shell. |

## Project layout

```
D-bloater/
├── module.prop          module metadata
├── customize.sh         installer
├── post-fs-data.sh      bootloop guard
├── service.sh           re-applies saved states after boot
├── bin/dbl.sh           backend (all package operations)
├── webroot/
│   ├── index.html       the WebUI
│   └── db.js            bundled package list
└── docs/screenshots/    README images (not shipped in the zip)
```

### Building the zip

```sh
zip -r D-bloater-v1.2.0.zip . -x "docs/*" ".git/*" ".github/*"
```

## Changelog

- **v1.2.0**: APK size, on-disk size and running status in cards and details. 13 sort options. Selection total in the bottom bar.
- **v1.1.1**: Critical is limited to the explicit protected list. Critical packages can be disabled with a strong warning and a tick-box.
- **v1.1.0**: Export and import lists. Package list provider manager (add, delete, enable, update) with UAD-NG format support.
- **v1.0.0**: First release. WebUI, risk ratings, filters, disable, uninstall and systemless removal, bootloop guard.

## Credits

Ideas and list formats from these projects. No code was copied from them.

- [sunilpaulmathew/De-Bloater](https://github.com/sunilpaulmathew/De-Bloater): the systemless removal approach.
- [ImKKingshuk/BloatwareHatao](https://github.com/ImKKingshuk/BloatwareHatao): the safety rating scale and the restore-first mindset.
- [MuntashirAkon/android-debloat-list](https://github.com/MuntashirAkon/android-debloat-list): the list schema and the default online provider.
- [0x192/universal-android-debloater](https://github.com/0x192/universal-android-debloater): list categories and the UAD list format.

## Disclaimer

Use at your own risk. The author is not responsible for bootloops, data loss or a device that stops working. Back up first.
