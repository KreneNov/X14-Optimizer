#!/system/bin/sh
# x14_wake_hook.sh - BusyBox inotifyd callback for Zero-Lag Wakeup & Instant Charge Guard (POSIX sh)

SCRIPT_DIR=${0%/*}
[ "$SCRIPT_DIR" = "$0" ] && SCRIPT_DIR='.'
SCRIPT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR" 2>/dev/null && pwd)
MODDIR=${SCRIPT_DIR%/*}

. "$MODDIR/bin/x14_common.sh"

init_env
load_or_build_hw_cache

EVENT_MASK="$1"
EVENT_FILE="$2"

wake_daemon() {
    if [ -f "$DAEMON_PID_FILE" ]; then
        read_sysfs_fast "$DAEMON_PID_FILE" ""
        is_uint "$SYSFS_VAL" && kill -USR1 "$SYSFS_VAL" 2>/dev/null
    fi
}

enforce_instant_charge_guard() {
    if [ -f "$GAME_BYPASS_FLAG" ]; then
        read_sysfs_fast /sys/class/power_supply/usb/online "0"
        if [ "$SYSFS_VAL" = "1" ]; then
            if [ -n "$CONST_CURR_NODE" ]; then
                read_sysfs_fast "$CONST_CURR_NODE" "1"
                if [ "$SYSFS_VAL" != "0" ]; then
                    engage_fcc_bypass
                    return 0
                fi
                get_charging_current_ma
                if [ "$CURR_MA" -gt 50 ]; then
                    engage_fcc_bypass
                    return 0
                fi
                return 1
            elif ! is_charging_paused; then
                engage_fcc_bypass
                return 0
            fi
        fi
    fi

    [ -f "$TOPUP_ONCE_FLAG" ] && return 1
    load_config
    read_sysfs_fast "$THERMAL_STATE_FILE" "normal:none"
    tstate=${SYSFS_VAL%%:*}

    read_sysfs_fast /sys/class/power_supply/usb/online "0"
    u_on="$SYSFS_VAL"
    read_sysfs_fast /sys/class/power_supply/wireless/online "0"
    w_on="$SYSFS_VAL"
    if [ "$u_on" != "1" ] && [ "$w_on" != "1" ]; then
        return 1
    fi

    read_sysfs_fast /sys/class/power_supply/battery/capacity "50"
    cap="$SYSFS_VAL"
    is_uint "$cap" || cap=50

    if [ "$tstate" = "critical" ] || { [ "$CHARGE_ENABLED" -eq 1 ] && [ "$cap" -ge "$CHARGE_STOP_PCT" ]; }; then
        if ! is_charging_paused; then
            set_charging_paused 1
            log_msg "INFO" "Instant Charge Guard: clamped ${CHARGE_MODE} immediately on charger/FCC event at ${cap}%"
            return 0
        fi
        get_charging_current_ma
        if [ "$CURR_MA" -gt 50 ]; then
            set_charging_paused 1
            return 0
        fi
    fi
    return 1
}

case "$EVENT_FILE" in
    *constant_charge_current*)
        if [ -n "$CONST_CURR_NODE" ]; then
            read_sysfs_fast "$CONST_CURR_NODE" "0"
            # Ignore our own fcc=0 writes to prevent self-trigger loop
            [ "$SYSFS_VAL" = "0" ] && exit 0
        fi
        if enforce_instant_charge_guard; then
            wake_daemon
        fi
        exit 0
        ;;
    *usb*|*wireless*)
        enforce_instant_charge_guard
        wake_daemon
        exit 0
        ;;
esac

if [ ! -f "$SCREEN_OFF_FLAG" ]; then
    if is_screen_on; then
        unforce_doze_if_needed async
        exit 0
    fi
    wake_daemon
    exit 0
fi

if is_screen_on; then
    rm -f "$SCREEN_OFF_FLAG"
    load_config
    read_sysfs_fast "$THERMAL_STATE_FILE" "normal:none"
    TSTATE=${SYSFS_VAL%%:*}
    read_sysfs_fast "$AUTO_GAME_STATE_FILE" "idle"
    AGSTATE="$SYSFS_VAL"
    WAKE_PROF="$PROFILE"
    case "$AGSTATE" in
        active:cool60:*) WAKE_PROF="game_cool60" ;;
        active:eco60:*) WAKE_PROF="game_eco60" ;;
        active:*) WAKE_PROF="gaming" ;;
    esac
    if [ "$TSTATE" = "critical" ]; then
        apply_cpu_gpu_profile "thermal_crit"
        log_msg "INFO" "Zero-lag wakeup: screen ON while thermal=critical (kept thermal_crit)"
    elif [ "$TSTATE" = "warn" ] && { [ "$WAKE_PROF" = "gaming" ] || [ "$WAKE_PROF" = "performance" ]; }; then
        apply_cpu_gpu_profile "$WAKE_PROF"
        restore_gpu_cdev_floor
        set_gpu_max_mhz 770
        log_msg "INFO" "Zero-lag wakeup: restored profile=$WAKE_PROF (GPU stepped to 770MHz under thermal=warn)"
    elif [ "$TSTATE" = "warn" ] && [ "$WAKE_PROF" = "game_cool60" ]; then
        apply_cpu_gpu_profile "game_cool60"
        clear_cpu_nolimit
        set_gpu_max_mhz 629
        log_msg "INFO" "Zero-lag wakeup: restored profile=game_cool60 (GPU stepped to 629MHz under thermal=warn)"
    else
        apply_cpu_gpu_profile "$WAKE_PROF"
        log_msg "INFO" "Zero-lag wakeup: restored profile=$WAKE_PROF immediately"
    fi
    unforce_doze_if_needed async
    wake_daemon
fi

exit 0
