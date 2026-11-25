#!/system/bin/sh
# service.sh - Late boot service launcher (POSIX sh)

MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR='.'
MODDIR=$(CDPATH= cd -- "$MODDIR" 2>/dev/null && pwd)

. "$MODDIR/bin/x14_common.sh"

init_env

# Wait for Android boot completion (timeout 180s)
WAIT_COUNT=0
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    WAIT_COUNT=$((WAIT_COUNT + 1))
    if [ "$WAIT_COUNT" -ge 90 ]; then
        log_msg "WARN" "Boot wait timeout reached (180s), continuing startup"
        break
    fi
    sleep 2
done

# Allow vendor power/thermal HALs to stabilize
sleep 5

rm -f "$HW_CACHE_FILE" "$DISPLAY_CACHE_FILE"
load_or_build_hw_cache
capture_defaults_snapshot
refresh_display_cache
load_config

log_msg "INFO" "Boot initialized on device=$DEV_CODENAME qcom_batt=$HAS_QCOM_BATT mi_thermal=$HAS_MI_THERMAL kgsl=$HAS_KGSL inotifyd=$HAS_INOTIFYD zram=$HAS_ZRAM"

# Apply saved settings once
"$MODDIR/bin/x14_ctrl.sh" apply-all >/dev/null 2>&1

# Start background daemon if not already running
if [ -f "$DAEMON_PID_FILE" ]; then
    OLD_PID=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        log_msg "INFO" "Daemon already running with PID=$OLD_PID"
        exit 0
    fi
fi

nohup "$MODDIR/bin/x14_daemon.sh" >/dev/null 2>&1 &
exit 0
