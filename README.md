# StillGood

**Windows 11 for the PCs you already have. Your PCs are still good.** Report, clean and upgrade a fleet of Windows PCs, silently and without losing a file. Built by an IT admin for small IT teams.

Windows 10 support has ended. Millions of working PCs fail Windows 11's hardware check. The tools that get around the check work one PC at a time, with someone at the keyboard. The "debloat" scripts are aggressive and undocumented, and on a business PC they break printing, scanners, point-of-sale devices or someone's OneDrive. A team of one to three people looking after 50 to 500 PCs has no SCCM and no time to babysit each machine.

This toolkit is for that team.

## What it does

| Mode | What happens | Changes the PC? |
|---|---|---|
| **Report** | An inventory of the PC, Windows 11 readiness (each check with what it needs, what was found, and whether anything gets around it), and an exact preview of what Clean apps would do. HTML for people, JSON for tools. | No |
| **Clean apps** | Removes the apps Windows ships and pushes (Copilot, Xbox, Widgets, promoted third-party apps), for every user and for new users. It blocks them from coming back with feature updates, and turns off silent app installs. | Yes, with undo |
| **Upgrade** | Gets Microsoft's Windows 11 image and checks it against a pinned SHA-256. It runs Setup's compatibility scan first, then upgrades silently in a background task that survives sign-out. After a verified sign-in on the new Windows, it deletes the image. | Yes |
| **Upgrade + clean apps** | Cleans first, upgrades, then cleans again at the first sign-in on Windows 11, for the apps Windows 11 brings. | Yes |
| **Monitor** | Shows the upgrade's stage, measured progress and real activity. | No |
| **Undo** | Puts back every setting a clean-apps run changed and lifts its blocks. The removed apps come back from the Microsoft Store. | Yes |

*Optimize* (a short, measured list of settings, each with one-click undo) is planned. Clean apps already gives nearly all of the speed.

## The rules

- **Preview first.** Every mode shows exactly what it will change and waits for a confirmation. From a script or an RMM tool, `-Apply -Yes` is the confirmation.
- **Catalog-driven.** Only apps listed in [`catalog/apps.json`](catalog/apps.json) are ever removed. Unknown apps are kept and listed in the report.
- **A protected list enforced in code** ([`modules/Guard.psm1`](modules/Guard.psm1)): runtimes and frameworks, the Windows shell, Start, Search and Settings, Windows Security, codecs, App Installer, languages and speech, driver companion apps, Edge and WebView2, anything Windows marks as a system component or non-removable, and your organization's own software. No catalog or switch can turn it off. The guard is checked when the plan is made, and again right before each removal.
- **Never touches security.** The toolkit can write only to a short list of registry settings. Defender, the firewall, Windows Update, UAC, BitLocker and licensing are refused in code, even if the list were widened by mistake.
- **Profiles, not one size.** The *office* profile keeps the everyday tools: Calculator, Photos, Snipping Tool, Paint, Notepad, Camera, Media Player, Teams, To Do, Quick Assist and the Store. The *kiosk* profile (kiosks and point of sale) removes everything a single-purpose PC doesn't need.
- **OneDrive safety.** OneDrive is never removed for anyone who has a profile on the PC. On kiosks, only new users skip the OneDrive setup.
- **Honest progress.** Time left is shown only where it can be measured: the download and the image check. During Setup, the monitor shows Setup's own reported percentage, whether Setup is working, and the last line of its log. There are no invented countdowns.
- **Everything logged, everything undoable, safe to run again.** Each run writes a readable log, a machine log, the plan, the result and an undo file. A second run acts only on what is still there.
- **Lab before release.** See *Status* below.

## What it will not do

- Touch licensing or activation.
- Weaken security or stop Windows Update.
- Pretend Microsoft supports Windows 11 on hardware below its requirements. Microsoft doesn't, and doesn't guarantee updates there. The report says so, and the upgrade refuses such a PC unless the admin passes `-AllowUnsupportedHardware`. The decision stays with the admin.
- Upgrade a PC with less than 4 GB of memory, or a processor without SSE4.2/POPCNT. Windows 11 24H2 and later don't start without them, so no option gets around this.
- Apply "speed hacks": killing services wholesale, turning off the page file, or registry tweaks with no measurable effect.

## Quick start

Requirements: Windows 10 version 2004 or later, or Windows 11, on 64-bit x64; Windows PowerShell 5.1, which is built into Windows. Report runs without administrator rights. Everything that changes the PC needs them.

```powershell
# The menu
powershell -ExecutionPolicy Bypass -File .\StillGood.ps1

# A read-only report (opens nothing, changes nothing)
.\StillGood.ps1 -Mode Report -Profile kiosk

# Clean apps: preview, then apply
.\StillGood.ps1 -Mode CleanApps -Profile office
.\StillGood.ps1 -Mode CleanApps -Profile office -Apply

# Upgrade: fill in config\upgrade.json first (see below)
.\StillGood.ps1 -Mode Upgrade -Apply
.\StillGood.ps1 -Mode Monitor

# Undo the latest clean-apps run, and reinstall the apps (run as the signed-in user)
.\StillGood.ps1 -Mode Undo -Apply -Reinstall
```

## Using it across a fleet

Run it as SYSTEM from your RMM tool (Action1, NinjaOne, Intune remediation, a GPO startup script), with `-Apply -Yes`:

```powershell
powershell -ExecutionPolicy Bypass -File .\StillGood.ps1 -Mode CleanApps -Profile kiosk -Apply -Yes
```

**Exit codes:** `0` done · `1` failed (see the log) · `2` refused (a blocker or a safety rule) · `3` not confirmed · `10` preview only.

**Logs and reports:** `%ProgramData%\StillGood\runs\<time>-<mode>\` holds `run.log`, `events.jsonl`, `report.html`, `report.json`, `plan.json`, `result.json` and `undo.json`. Undo files are also copied to `%ProgramData%\StillGood\undo\`.

**Your organization's apps:** copy `catalog/organization.example.json` to `catalog/organization.json`. Its `keep` list protects your own software, or anything a profile would otherwise remove (wildcards allowed). It can only add protection. Its `alsoRemove` list removes extra catalog apps for one profile.

**The Windows 11 image:** copy `config/upgrade.example.json` to `config/upgrade.json`. Download the image once from Microsoft's Windows 11 page ("Download Windows 11 Disk Image (ISO) for x64 devices"). Put it on a share or web server you control, and paste its SHA-256 from the same Microsoft page ("Verify your download"). Microsoft's own links expire after 24 hours. The pinned SHA-256 guarantees that every PC gets Microsoft's exact image. If a download stalls, the PC waits for the image in `%ProgramData%\StillGood\upgrade\drop\`, where a READ ME says exactly which file to put there.

**The upgrade, step by step:** a local copy of the toolkit and a scheduled task (SYSTEM) take over, so a USB stick can be removed and the user can sign out. The task gets and checks the image, then runs Setup's compatibility scan (`/compat scanonly`). Only if the scan is clean does it run the upgrade (`/auto upgrade /quiet`, keeping files, apps and settings). Setup restarts the PC when it is ready; with `-NoRestart`, you restart it yourself. At the next sign-in, a second task confirms the new build, deletes the image, runs Clean apps again if asked, and removes itself. If Setup rolled back, the second task says so and keeps the image for another try.

**The unsupported-hardware option** (`-AllowUnsupportedHardware`) sets Microsoft's documented `AllowUpgradesWithUnsupportedTPMOrCPU` value and runs Setup with `/product server`, which skips the hardware check. Use it only on PCs you have tested, and knowing that Microsoft does not support the result.

## How it is built

```
StillGood.ps1          menu and command line
modules/
  Guard.psm1           the safety rules (protected apps, allowed registry settings)
  System.psm1          every call that changes the PC, behind one swappable table
  Inventory.psm1       read-only: apps, apps for new users, programs, startup items
  Compat.psm1          read-only: Windows 11 readiness
  Catalog.psm1         the catalog, the organization file, and the plan
  Settings.psm1        user profiles, registry changes with undo, "stay removed" markers
  Apps.psm1            Clean apps and Undo
  Report.psm1          the HTML and JSON report
  Upgrade.psm1         image download/copy, SHA-256, drop folder, Setup command line, state
  UpgradeJob.psm1      the background upgrade, the after-upgrade check, the monitor
worker/                the two scheduled-task entry points
catalog/apps.json      every app the toolkit knows, and what each profile does with it
tests/                 offline tests with a fake PC, and the Windows Sandbox integration test
```

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

The tests run against a fake PC: fake apps, users, registry, Setup and scheduled tasks. In test mode, any real system call fails loudly, so the tests cannot touch the machine they run on. They cover:

- the safety rules;
- readiness verdicts and processor detection;
- catalog validation;
- office and kiosk plans and the organization file;
- removal for every user and new users;
- profile hives (signed-in, signed-out and default);
- re-runs, failures and forged plans;
- undo and reinstall;
- HTML escaping;
- Setup's command line and exit codes;
- SHA-256;
- stalled downloads and the drop folder;
- the full upgrade job, the after-upgrade check, rollback detection;
- ASCII-only source files.

## Status

**v0.3, preview.** All three blocks are built and the offline tests pass. The read-only report has run on a real Windows 11 PC. The integration test (`tests/Sandbox-Test.ps1`) passes inside Windows Sandbox on real Windows. It covers Clean apps with the kiosk profile, the stay-clean settings for a signed-out user and for new users, the blocks, a second run that changes nothing, and Undo putting every value back. Windows Sandbox ships without consumer apps, so app removal itself still needs a full Windows VM. Before any release, each item below must pass on disposable virtual machines with checkpoints:

1. Clean apps, both profiles, on Windows 10 22H2 and Windows 11. Then sign in as a new user and run Windows Update and a feature update: nothing returns.
2. The "blocked before they arrive" markers stop Copilot, Outlook and Teams from arriving with a Windows 10 to 11 upgrade.
3. The upgrade on a VM with TPM 2.0 and on one without (unsupported option): download, stall and drop folder, scan exit codes, sign-out during Setup, restart, the after-upgrade cleanup, a forced rollback.
4. Undo restores every setting, and reinstall brings the apps back.
5. The current Windows 11 image's Setup accepts every switch used (`/eula accept`, `/product server`).

v1.0 adds code signing, and pilot evidence from real PCs before any fleet claims.

## License

[MIT](LICENSE). Anyone may use, change and share StillGood, including at work and in paid services, as long as the license notice stays with it. It comes with no warranty: test it on your own machines first, the way it was tested here.
