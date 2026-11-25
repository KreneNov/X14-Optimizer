#!/system/bin/sh
# uninstall.sh - Safe cleanup and hardware/system restoration (POSIX sh)

MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR='.'
MODDIR=$(CDPATH= cd -- "$MODDIR" 2>/dev/null && pwd)

if [ -f "$MODDIR/bin/x14_common.sh" ]; then
    . "$MODDIR/bin/x14_common.sh"
    init_env
    detect_hardware
fi

# Stop inotifyd watcher
if [ -f /data/local/tmp/x14_inotify.pid ]; then
    IPID=$(cat /data/local/tmp/x14_inotify.pid 2>/dev/null)
    [ -n "$IPID" ] && kill "$IPID" 2>/dev/null
fi

# Stop daemon
if [ -f /data/local/tmp/x14_perf_battery.pid ]; then
    DPID=$(cat /data/local/tmp/x14_perf_battery.pid 2>/dev/null)
    [ -n "$DPID" ] && kill "$DPID" 2>/dev/null
    sleep 1
    [ -n "$DPID" ] && kill -9 "$DPID" 2>/dev/null
fi

# Unmount thermal FPS bind overlay cleanly if active
umount /vendor/etc/display/thermallevel_to_fps.xml 2>/dev/null

# Always re-enable Joyose & PowerKeeper and release Doze force-idle if present
pm enable com.xiaomi.joyose >/dev/null 2>&1
pm enable com.miui.powerkeeper >/dev/null 2>&1
dumpsys deviceidle unforce >/dev/null 2>&1

# Restore VM swappiness & cleanly reset ZRAM if free RAM allows
if [ -w /proc/sys/vm/swappiness ]; then
    printf '60\n' > /proc/sys/vm/swappiness 2>/dev/null
fi
if command -v apply_zram_config >/dev/null 2>&1 && [ "$HAS_ZRAM" -eq 1 ]; then
    ZRAM_ENABLED=0
    ZRAM_SIZE_GB=0
    apply_zram_config >/dev/null 2>&1
fi

# Clean persistent HyperOS SPC overrides from /data/property so ROM build.prop defaults resume cleanly
RESETPROP_BIN=""
for rp in /data/adb/ksu/bin/resetprop /data/adb/ap/bin/resetprop /data/adb/magisk/resetprop; do
    if [ -x "$rp" ]; then
        RESETPROP_BIN="$rp"
        break
    fi
done
if [ -z "$RESETPROP_BIN" ]; then
    rp_path=$(command -v resetprop 2>/dev/null)
    [ -n "$rp_path" ] && [ -x "$rp_path" ] && RESETPROP_BIN="$rp_path"
fi

if [ -n "$RESETPROP_BIN" ]; then
    "$RESETPROP_BIN" -p -d persist.sys.spc.mi_extra_free_game_only >/dev/null 2>&1
    "$RESETPROP_BIN" -p -d persist.vendor.spc.mi_extra_free_game_only >/dev/null 2>&1
    "$RESETPROP_BIN" -p -d persist.sys.spc.protect.critical.count >/dev/null 2>&1
else
    setprop persist.sys.spc.mi_extra_free_game_only true >/dev/null 2>&1
    setprop persist.vendor.spc.mi_extra_free_game_only true >/dev/null 2>&1
    setprop persist.sys.spc.protect.critical.count 2 >/dev/null 2>&1
fi

# Restore thermal message & dynamic cooling devices before snapshot reset
[ -w /sys/class/thermal/thermal_message/cpu_nolimit_temp ] && printf '0\n' > /sys/class/thermal/thermal_message/cpu_nolimit_temp 2>/dev/null
[ -w /sys/class/thermal/thermal_message/sconfig ] && printf -- '-1\n' > /sys/class/thermal/thermal_message/sconfig 2>/dev/null
for cdev in /sys/class/thermal/cooling_device*; do
    [ -d "$cdev" ] || continue
    ctype=$(cat "$cdev/type" 2>/dev/null)
    case "$ctype" in
        gpu)
            if [ "$(getprop ro.product.device 2>/dev/null)" = "houji" ] && [ -w "$cdev/cur_state" ]; then
                printf '2\n' > "$cdev/cur_state" 2>/dev/null
            fi
            ;;
        display-fps|cpu-cluster3)
            [ -w "$cdev/cur_state" ] && printf '0\n' > "$cdev/cur_state" 2>/dev/null
            ;;
    esac
done

# Reset charging nodes safely
for n in /sys/class/qcom-battery/input_suspend /sys/class/power_supply/battery/input_suspend /sys/class/qcom-battery/night_charging /sys/class/qcom-battery/restrict_chg; do
    [ -w "$n" ] && printf '0\n' > "$n" 2>/dev/null
done
[ -w /sys/class/qcom-battery/restrict_cur ] && printf '1000000\n' > /sys/class/qcom-battery/restrict_cur 2>/dev/null
for n in /sys/class/power_supply/battery/charging_enabled /sys/class/power_supply/battery/battery_charging_enabled; do
    [ -w "$n" ] && printf '1\n' > "$n" 2>/dev/null
done
if [ -w /sys/class/power_supply/battery/constant_charge_current ]; then
    CUR_FCC=$(cat /sys/class/power_supply/battery/constant_charge_current 2>/dev/null)
    if [ "$CUR_FCC" = "0" ]; then
        printf '4250000\n' > /sys/class/power_supply/battery/constant_charge_current 2>/dev/null
    fi
fi

# Restore snapshotted defaults if available
if [ -f /data/adb/x14_perf_battery/defaults.snap ] && command -v apply_defaults_snapshot >/dev/null 2>&1; then
    apply_defaults_snapshot
else
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$p" ] || continue
        MAX_INFO=$(cat "$p/cpuinfo_max_freq" 2>/dev/null)
        [ -n "$MAX_INFO" ] && [ -w "$p/scaling_max_freq" ] && printf '%s\n' "$MAX_INFO" > "$p/scaling_max_freq" 2>/dev/null
    done
    [ -w /sys/class/kgsl/kgsl-3d0/max_clock_mhz ] && printf '770\n' > /sys/class/kgsl/kgsl-3d0/max_clock_mhz 2>/dev/null
fi

rm -rf /data/adb/x14_perf_battery
rm -f /data/local/tmp/x14_perf_battery.pid \
      /data/local/tmp/x14_inotify.pid \
      /data/local/tmp/x14_screen_off.flag \
      /data/local/tmp/x14_doze_forced.flag \
      /data/local/tmp/x14_topup_once.flag \
      /data/local/tmp/x14_game_bypass.flag \
      /data/local/tmp/x14_thermal_state \
      /data/local/tmp/x14_auto_game_state \
      /data/local/tmp/x14_hw_cache.conf \
      /data/local/tmp/x14_display_cache.conf

exit 0
