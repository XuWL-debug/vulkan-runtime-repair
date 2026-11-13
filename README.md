# vulkan-runtime-repair

Repair a **missing or broken Windows Vulkan runtime** without reinstalling the
graphics driver.

Some games refuse to start with a message like *"graphics driver version is too
low, please update your driver"* — even when the newest vendor driver is
already installed. In many of those cases the game runs a **Vulkan boot check**
and reports any failure as a driver-version problem. Updating the driver again,
or editing driver version strings in the registry, does not help.

Vendor driver packages already contain everything needed: a Vulkan loader and
an ICD manifest. Sometimes those components never land in the system
(incomplete install, cleanup utility, driver rollback, Windows Update replacing
a vendor driver). This tool puts them back.

[中文文档](README.zh-CN.md)

## What it does

- Scans `%WINDIR%\System32\DriverStore\FileRepository` for **any** Vulkan ICD
  manifest (standard JSON with `ICD` + `library_path`) — AMD, NVIDIA, Intel or
  any other vendor. No vendor-specific file names are assumed.
- Finds a matching loader by reading the PE header and confirming the DLL
  actually exports `vkCreateInstance`.
- Checks the `System32` / `SysWOW64` loaders and the Khronos ICD registry keys,
  including entries pointing at manifests that no longer exist.
- Probes the **real Vulkan API** through an embedded C# P/Invoke helper.
  No Python, no Vulkan SDK, no third-party executable.
- Restores the missing loader and registers the ICD manifests.
- Records every change so `-Mode Undo` reverts exactly what it did.

Nothing is hard-coded: no drive letters, user names, GPU models or game paths.

## Requirements

- Windows 10 / 11, Windows PowerShell 5.1 or PowerShell 7
- Administrator rights **only** for `Fix` and `Undo`
- A graphics driver package that still contains the Vulkan components

## Usage

| File | Action |
| --- | --- |
| `diagnose.cmd` | read-only report, no admin needed |
| `repair.cmd` | repair, auto-elevates through UAC |
| `undo.cmd` | revert the repair, auto-elevates |

From PowerShell:

```powershell
.\Repair-VulkanRuntime.ps1 -Mode Diagnose
.\Repair-VulkanRuntime.ps1 -Mode Fix
.\Repair-VulkanRuntime.ps1 -Mode Verify
.\Repair-VulkanRuntime.ps1 -Mode Undo
```

### Parameters

| Parameter | Meaning |
| --- | --- |
| `-Mode` | `Diagnose` (default), `Verify`, `Fix`, `Undo` |
| `-DriverPackagePath` | Use one specific DriverStore package instead of scanning |
| `-PruneInvalidIcd` | Also remove ICD entries whose JSON no longer exists; restored by Undo |
| `-Force` | Replace an existing loader; the original is backed up and restored by Undo |
| `-LogPath` | Append a plain-text log |
| `-StatePath` | Custom location for the undo state file |

Extra arguments are forwarded, e.g. `repair.cmd -PruneInvalidIcd -Force`.

## Reading the output

A healthy result looks like:

```text
=== Vulkan API probe (what games actually see) ===
  [system] OK: <your GPU> | Vulkan API 1.3.xxx | driverVersion ... | devices 1
  [driver package only] OK: <your GPU> | Vulkan API 1.3.xxx | ...
```

`[driver package only] OK` together with `[system] FAILED` is the classic
signature: the installed driver is perfectly capable, only the system-level
runtime is missing. That is exactly what `Fix` repairs.

If `[driver package only]` fails too, the driver package itself is damaged —
reinstall the **full** vendor driver with a clean / factory-reset install and
reboot. No script can restore files that are not there.

## Safety

- `Diagnose` and `Verify` are strictly read-only.
- `Fix` only copies loader DLLs into `System32` / `SysWOW64` and writes
  `REG_DWORD` values under `HKLM\SOFTWARE\Khronos\Vulkan\Drivers`. It never
  modifies driver binaries, INF files, services, or driver version metadata.
- Existing files are left alone unless `-Force` is given, and then backed up.
- Every created file, registry value and registry key is written to
  `vulkan-repair-state.json`; `Undo` removes or restores exactly those items.
- Keep the state file and `vulkan-repair-backups/` until you are satisfied.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success / Vulkan probe OK |
| 1 | Administrator rights required |
| 2 | No usable driver package, or probe helper failed |
| 3 | Vulkan probe still fails after repair |

## Limitations

- If the driver package does not contain a Vulkan loader, a full driver
  reinstall is required.
- This repairs the **runtime**, not a game that genuinely needs a newer GPU or
  a Vulkan feature the hardware cannot provide.
- HKLM registry changes are system-wide. Use `Undo` if anything looks off.

## License

MIT — see [LICENSE](LICENSE).
