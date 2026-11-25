#!/system/bin/sh
# post-fs-data.sh - Early boot initialization & safe vendor thermal XML bind mount (POSIX sh)

MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR='.'
MODDIR=$(CDPATH= cd -- "$MODDIR" 2>/dev/null && pwd)

mkdir -p /data/adb/x14_perf_battery
chmod 0755 /data/adb/x14_perf_battery

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

DEVICE=$(getprop ro.product.device 2>/dev/null)
ORIG_XML="/vendor/etc/display/thermallevel_to_fps.xml"
PATCH_XML="$MODDIR/files/thermallevel_to_fps.xml"

if { [ "$DEVICE" = "houji" ] || [ -f "$ORIG_XML" ]; } && [ -f "$ORIG_XML" ] && [ -s "$PATCH_XML" ]; then
    if grep -q '</ThermalLevelToFPSMap>' "$PATCH_XML" 2>/dev/null && grep -q 'level="5" fps="120"' "$PATCH_XML" 2>/dev/null && grep -q 'level="7" fps="120"' "$PATCH_XML" 2>/dev/null; then
        if ! grep -q 'level="5" fps="120"' "$ORIG_XML" 2>/dev/null; then
            chmod 0644 "$PATCH_XML" 2>/dev/null
            chcon u:object_r:vendor_configs_file:s0 "$PATCH_XML" 2>/dev/null
            mount --bind "$PATCH_XML" "$ORIG_XML" 2>/dev/null
        fi
    fi
fi

exit 0
