\# X14 Optimizer (`x14\_perf\_battery`)



Hardware-level performance, thermal management, True Bypass charging, and pure-RAM multitasking optimizer built specifically for \*\*Xiaomi 14 (`houji` / Snapdragon 8 Gen 3)\*\* on HyperOS, complete with a \*\*120FPS Glassmorphic KSU WebUI\*\*.



\- \*\*Version:\*\* `v1.3.1` (`versionCode=131`)

\- \*\*Target Device:\*\* Xiaomi 14 (`houji`) — KernelSU / APatch / Magisk

\- \*\*Authors:\*\* \*\*KreneNov\*\* \& \*\*Elaina\*\*



\---



\## Key Features



\### 1. True Bypass Charging \& Gaming Auto-Bypass

\- \*\*Hardware-level `fcc=0` Bypass:\*\* Locks `constant\_charge\_current=0` so charger power feeds `VSYS` directly while keeping battery current near `0 mA` — eliminating dual heat stress without triggering HyperOS charging popups.

\- \*\*Smart Daily Charge Limit:\*\* Stops charging at your configured ceiling (e.g. `80%` or `95%`) with customizable hysteresis (`10%`), plus a \*\*Top-up Once (`100%`)\*\* toggle that automatically resets when unplugged.

\- \*\*EOC Reset Pulse (`350ms`):\*\* Triggers a brief `night\_charging=1` pulse when resuming charge to properly re-negotiate \*\*90W HyperCharge / PPS\*\* fast charging.

\- \*\*Gaming Auto-Bypass:\*\* Automatically engages True Bypass whenever a whitelisted game enters the foreground on wired power (`usb\_online=1`), guarded by a configurable minimum battery floor (`15%–30%` with `+2%` hysteresis) to prevent voltage sag.



\### 2. Thermal Unlock \& Per-Game Profiles (`max120` / `cool60` / `eco60`)

\- \*\*Systemless Thermal Overlay:\*\* Dynamically patches `/vendor/etc/display/thermallevel\_to\_fps.xml` via `mount --bind` and overrides `mi\_thermald` limits (`cpu\_nolimit\_temp`) to hold a flat \*\*120Hz / 120FPS\*\* past the stock `42°C` throttle wall.

\- \*\*Two-Tier Thermal Guard:\*\* Monitors battery \& board thermal sensors alongside `mi\_thermald`, stepping down GPU clocks cleanly at `WARN` and falling back to safe charging/clocks at `CRIT`.

\- \*\*Auto Game Mode + Per-Game Profiles:\*\* Uses `dumpsys activity` foreground detection with a `15s` exit debounce and native App Picker (`dumpsys game` / PackageManager):

&#x20; - \*\*`max120` (Max 120FPS):\*\* Full 4-cluster CPU (`3.3 GHz`), Adreno 750 max (`903 MHz`), locked `120Hz`.

&#x20; - \*\*`cool60` (Cool 120Hz):\*\* Balanced CPU (`2.63 GHz` Big/Prime), capped GPU (`720 MHz`), locked `120Hz` for smooth touch/UI latency in heavy 60FPS titles (HSR, Genshin, WuWa).

&#x20; - \*\*`eco60` (AFK / Asset Download):\*\* Powersave CPU, capped GPU (`422 MHz`), locked `60Hz`.

\- \*\*Independent `joyose` Control:\*\* Toggle `com.xiaomi.joyose` suppression separately without breaking LTPO `smart120` refresh behavior.



\### 3. Pure-RAM ZRAM \& HyperOS SPC Tuning

\- \*\*Zero-UFS Pure-RAM ZRAM:\*\* Configures `/dev/block/zram0` (`4GB / 6GB / 8GB`, `lz4` or `zstd`) strictly in physical RAM (`backing\_dev=none`, `vm.page-cluster=0`, `vm.swappiness=100`) — zero flash wear on UFS storage.

\- \*\*ZRAM Self-Heal Guard:\*\* Monotonic `/proc/uptime` watchdog that automatically restores ZRAM configuration if late-boot ROM services (`ExtM` / `SysoptService`) reset `zram0` after unlock.

\- \*\*SPC Multitasking Relief:\*\* Tunes `persist.sys.spc.mi\_extra\_free\_game\_only=false` and `persist.sys.spc.protect.critical.count=5` to prevent HyperOS from killing background games and apps during quick switching.



\### 4. Notification \& Background Delivery Fix

\- Whitelists Google Play Services (`GMS` / `GSF`) and user-selected messaging/social apps (`notify\_apps.list`) across Doze (`deviceidle`), `appops`, and HyperOS `MILLET\_NO\_RESTRICT\_APP`, preventing delayed push notifications without breaking idle battery life.



\### 5. Animated KSU WebUI

\- Zero-dependency lightweight HTML/CSS/JS dashboard featuring GPU-accelerated directional tab transitions, tactile \*\*Glassmorphic Bottom Sheet Pickers\*\*, live battery/thermal/ZRAM telemetry (`< 150ms` CLI response), and a built-in native App Picker Modal.



\---



\## Installation \& Usage



1\. Download the latest `x14\_perf\_battery-vX.X.X.zip` from \*\*\[Releases](../../releases)\*\*.

2\. Open \*\*KernelSU Manager\*\* (or APatch / Magisk) → \*\*Modules\*\* → \*\*Install\*\* and select the downloaded ZIP.

3\. \*\*Reboot\*\* your device.

4\. Tap the \*\*WebUI\*\* button on the \*\*X14 Optimizer\*\* module card to configure charging limits, Per-Game Profiles, ZRAM, and notification whitelists.



> \*\*Note:\*\* Built and tested on \*\*Xiaomi 14 (`houji`)\*\* running HyperOS. Do not flash on non-`houji` devices without verifying thermal/charging sysfs nodes first.



\---



\## Credits \& License



\- \*\*Developed by:\*\* \[KreneNov](https://github.com/KreneNov) \& \*\*Elaina\*\*

\- Licensed under the \*\*MIT License\*\*.

