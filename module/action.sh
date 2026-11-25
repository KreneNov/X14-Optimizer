#!/system/bin/sh
# action.sh - KernelSU Manager Quick Action button (POSIX sh)

MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR='.'
MODDIR=$(CDPATH= cd -- "$MODDIR" 2>/dev/null && pwd)

. "$MODDIR/bin/x14_common.sh"

init_env
detect_hardware
resolve_thermal_zones
load_config

case "$PROFILE" in
    balanced) NEXT_PROFILE="battery" ;;
    battery) NEXT_PROFILE="performance" ;;
    performance) NEXT_PROFILE="gaming" ;;
    gaming) NEXT_PROFILE="balanced" ;;
    *) NEXT_PROFILE="balanced" ;;
esac

echo "=========================================="
echo "  Xiaomi 14 Perf & Battery Optimizer"
echo "=========================================="
echo "Switching profile: $PROFILE -> $NEXT_PROFILE"

"$MODDIR/bin/x14_ctrl.sh" set-profile "$NEXT_PROFILE" >/dev/null 2>&1

get_temperatures
BATT_CAP=$(read_sysfs /sys/class/power_supply/battery/capacity "0")
BATT_STAT=$(read_sysfs /sys/class/power_supply/battery/status "Unknown")
BATT_C=$((TEMP_BATT_X10 / 10)).$((TEMP_BATT_X10 % 10))
SKIN_C=$((TEMP_SKIN_X10 / 10)).$((TEMP_SKIN_X10 % 10))

DAEMON_STAT="stopped"
if [ -f "$DAEMON_PID_FILE" ]; then
    DPID=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
    if [ -n "$DPID" ] && kill -0 "$DPID" 2>/dev/null; then
        DAEMON_STAT="running (PID $DPID)"
    fi
fi

echo "Active Profile : $NEXT_PROFILE"
echo "Battery        : ${BATT_CAP}% (${BATT_STAT}) | SmartCharge=${CHARGE_ENABLED} (${CHARGE_STOP_PCT}%/${CHARGE_RESUME_PCT}%)"
echo "Temperature    : Battery=${BATT_C}C | Skin=${SKIN_C}C"
echo "FPS Mode       : ${FPS_MODE}"
echo "Daemon         : ${DAEMON_STAT}"
echo "Log            : $LOG_FILE"
exit 0
