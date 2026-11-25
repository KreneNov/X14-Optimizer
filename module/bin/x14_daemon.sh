#!/system/bin/sh
# x14_daemon.sh - 3-in-1 Adaptive Daemon (Screen-Off + Smart Charge + Thermal Guard)
# Strict POSIX sh / BusyBox ash

SCRIPT_DIR=${0%/*}
[ "$SCRIPT_DIR" = "$0" ] && SCRIPT_DIR='.'
SCRIPT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR" 2>/dev/null && pwd)
MODDIR=${SCRIPT_DIR%/*}

. "$MODDIR/bin/x14_common.sh"

init_env
load_or_build_hw_cache
load_config
ensure_default_games_list

# Single-instance guard
if [ -f "$DAEMON_PID_FILE" ]; then
    read_sysfs_fast "$DAEMON_PID_FILE" ""
    OLD_PID="$SYSFS_VAL"
    if [ -n "$OLD_PID" ] && [ "$OLD_PID" != "$$" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        exit 0
    fi
fi
printf '%s\n' "$$" > "$DAEMON_PID_FILE"
printf 'normal:none\n' > "$THERMAL_STATE_FILE"
printf 'idle\n' > "$AUTO_GAME_STATE_FILE"

INOTIFY_PID=""
SLEEP_PID=""
WAKE_SIG=0
OFF_SINCE=0
THERMAL_STATE="normal"
THERMAL_TRIGGER="none"
CHARGE_PAUSED_BY_SOC=0
CHARGE_PAUSED_BY_THERMAL=0
PREV_PLUGGED=0
ATTACH_GUARD_UNTIL=0
AUTO_GAME_ACTIVE=0
AUTO_GAME_PKG=""
AUTO_GAME_PROF="none"
AUTO_GAME_LEFT_SINCE=0
AUTO_GAME_EXIT_DEBOUNCE=15
GAME_BYPASS_ACTIVE=0
GAME_BYPASS_LOW_LATCH=0
rm -f "$GAME_BYPASS_FLAG"
get_uptime_sec_fast
DAEMON_BOOT_UP="$UP_SEC"
ZRAM_CFG_SIG=""
ZRAM_FIRST_SCR_CHECKED=0
ZRAM_LAST_CHECK_UP=0
ZRAM_LAST_HEAL_UP=0
ZRAM_HEAL_COUNT=0
ZRAM_MAX_WARNED=0
ZRAM_VM_LOG_COUNT=0

# Zero-fork ZRAM Self-Heal Guard (only invokes apply_zram_config if late-boot reset detected)
check_and_heal_zram() {
    [ "$HAS_ZRAM" -eq 1 ] || return 0
    [ "$ZRAM_ENABLED" -eq 1 ] || return 0
    [ "$ZRAM_SIZE_GB" -gt 0 ] || return 0

    _zsig="${ZRAM_ENABLED}:${ZRAM_SIZE_GB}:${ZRAM_ALGO}"
    if [ "$_zsig" != "$ZRAM_CFG_SIG" ]; then
        ZRAM_CFG_SIG="$_zsig"
        ZRAM_HEAL_COUNT=0
        ZRAM_MAX_WARNED=0
        ZRAM_LAST_CHECK_UP=0
        ZRAM_LAST_HEAL_UP=0
    fi

    _ts="$UP_SEC"
    [ "$_ts" -gt 0 ] || _ts="$NOW"
    _in_boot_win=0
    if [ "$UP_SEC" -gt 0 ]; then
        if [ "$UP_SEC" -le 210 ] || [ $((UP_SEC - DAEMON_BOOT_UP)) -le 180 ]; then
            _in_boot_win=1
        fi
    fi

    _due=0
    if [ "$SCR_ON" -eq 1 ] && [ "$ZRAM_FIRST_SCR_CHECKED" -eq 0 ]; then
        ZRAM_FIRST_SCR_CHECKED=1
        _due=1
    elif [ "$_in_boot_win" -eq 1 ]; then
        if [ "$ZRAM_LAST_CHECK_UP" -eq 0 ] || [ $((_ts - ZRAM_LAST_CHECK_UP)) -ge 15 ]; then
            _due=1
        fi
    elif [ "$SCR_ON" -eq 1 ]; then
        if [ $((_ts - ZRAM_LAST_CHECK_UP)) -ge 60 ]; then
            _due=1
        fi
    fi
    [ "$_due" -eq 1 ] || return 0

    case "$ZRAM_SIZE_GB" in
        4) _exp_bytes="4294967296" ;;
        6) _exp_bytes="6442450944" ;;
        8) _exp_bytes="8589934592" ;;
        *) return 0 ;;
    esac

    read_sysfs_fast /sys/block/zram0/disksize "0"
    _cur_ds="$SYSFS_VAL"
    _sw_on=0
    is_zram_swapon && _sw_on=1
    # Note: mksh 1-byte read() on /proc/sys/* (proc_dointvec) yields only the 1st char ('1' for 100, '6' for 60)
    read_sysfs_fast /proc/sys/vm/swappiness "60"
    _cur_sw="$SYSFS_VAL"
    read_sysfs_fast /proc/sys/vm/page-cluster "3"
    _cur_pc="$SYSFS_VAL"

    # Healthy fast-path: zero forks
    if [ "$_sw_on" -eq 1 ] && [ "$_cur_ds" = "$_exp_bytes" ] && { [ "$_cur_sw" = "100" ] || [ "$_cur_sw" = "1" ]; } && [ "$_cur_pc" = "0" ]; then
        ZRAM_LAST_CHECK_UP="$_ts"
        return 0
    fi

    # Case 1: ZRAM reset / missing from /proc/swaps or disksize mismatch
    if [ "$_sw_on" -eq 0 ] || [ "$_cur_ds" != "$_exp_bytes" ]; then
        if [ "$ZRAM_HEAL_COUNT" -ge 5 ]; then
            ZRAM_LAST_CHECK_UP="$_ts"
            if [ "$ZRAM_MAX_WARNED" -eq 0 ]; then
                ZRAM_MAX_WARNED=1
                log_msg "WARN" "ZRAM Self-Heal Guard reached limit (5/5 retries); pausing auto-recovery"
            fi
            return 0
        fi
        if [ "$ZRAM_LAST_HEAL_UP" -gt 0 ] && [ $((_ts - ZRAM_LAST_HEAL_UP)) -lt 30 ]; then
            return 0
        fi
        ZRAM_LAST_CHECK_UP="$_ts"
        ZRAM_HEAL_COUNT=$((ZRAM_HEAL_COUNT + 1))
        ZRAM_LAST_HEAL_UP="$_ts"
        if apply_zram_config; then
            log_msg "WARN" "ZRAM reset detected (ROM late-boot, disksize=${_cur_ds} swapon=${_sw_on}); re-applied ${ZRAM_SIZE_GB}GB ${ZRAM_ALGO} (${ZRAM_HEAL_COUNT}/5)"
        else
            log_msg "WARN" "ZRAM reset detected (disksize=${_cur_ds} swapon=${_sw_on}); re-apply failed (${ZRAM_HEAL_COUNT}/5)"
        fi
        return 0
    fi

    # Case 2: ZRAM active & sized properly, only VM sysctls drifted -> fix without swapoff
    ZRAM_LAST_CHECK_UP="$_ts"
    _real_sw=$(cat /proc/sys/vm/swappiness 2>/dev/null)
    _real_pc=$(cat /proc/sys/vm/page-cluster 2>/dev/null)
    [ "$_real_pc" = "0" ] && [ "$_real_sw" = "100" ] && return 0
    [ "$_real_pc" != "0" ] && write_sysfs /proc/sys/vm/page-cluster 0
    [ "$_real_sw" != "100" ] && write_sysfs /proc/sys/vm/swappiness 100
    if [ "$ZRAM_VM_LOG_COUNT" -lt 5 ]; then
        ZRAM_VM_LOG_COUNT=$((ZRAM_VM_LOG_COUNT + 1))
        log_msg "WARN" "ZRAM VM drift detected (swappiness=${_real_sw}->100 page-cluster=${_real_pc}->0); restored without swapoff"
    fi
    return 0
}

cleanup() {
    [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
    [ -n "$INOTIFY_PID" ] && kill "$INOTIFY_PID" 2>/dev/null
    clear_cpu_nolimit
    unforce_doze_if_needed
    if [ "$GAME_BYPASS_ACTIVE" -eq 1 ] && [ "$CHARGE_PAUSED_BY_SOC" -eq 0 ] && [ "$CHARGE_PAUSED_BY_THERMAL" -eq 0 ]; then
        set_charging_paused 0
    fi
    rm -f "$DAEMON_PID_FILE" "$INOTIFY_PID_FILE" "$SCREEN_OFF_FLAG" "$DOZE_FORCED_FLAG" "$AUTO_GAME_STATE_FILE" "$GAME_BYPASS_FLAG"
    exit 0
}

resolve_wake_profile() {
    _wake_prof="$PROFILE"
    if [ "$PROFILE" = "gaming" ]; then
        _wake_prof="gaming"
    elif [ "$AUTO_GAME_ACTIVE" -eq 1 ]; then
        case "$AUTO_GAME_PROF" in
            cool60) _wake_prof="game_cool60" ;;
            eco60) _wake_prof="game_eco60" ;;
            *) _wake_prof="gaming" ;;
        esac
    fi
}

on_usr1() {
    WAKE_SIG=1
    [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
}

trap cleanup INT TERM EXIT
trap on_usr1 USR1

start_inotify_watcher() {
    [ "$HAS_INOTIFYD" -eq 1 ] || return 1
    set --
    [ -n "$BACKLIGHT_NODE" ] && [ -e "$BACKLIGHT_NODE" ] && set -- "$@" "${BACKLIGHT_NODE}:w"
    [ -n "$SCREEN_STATE_NODE" ] && [ -e "$SCREEN_STATE_NODE" ] && set -- "$@" "${SCREEN_STATE_NODE}:w"
    [ -e /sys/class/power_supply/usb/online ] && set -- "$@" "/sys/class/power_supply/usb/online:w"
    [ -e /sys/class/power_supply/wireless/online ] && set -- "$@" "/sys/class/power_supply/wireless/online:w"
    [ -e /sys/class/thermal/thermal_message/usb_online ] && set -- "$@" "/sys/class/thermal/thermal_message/usb_online:w"
    [ -n "$CONST_CURR_NODE" ] && [ -e "$CONST_CURR_NODE" ] && set -- "$@" "${CONST_CURR_NODE}:w"
    [ "$#" -gt 0 ] || return 1

    "$BUSYBOX" inotifyd "$MODDIR/bin/x14_wake_hook.sh" "$@" >/dev/null 2>&1 &
    INOTIFY_PID=$!
    printf '%s\n' "$INOTIFY_PID" > "$INOTIFY_PID_FILE"
    return 0
}

if start_inotify_watcher; then
    log_msg "INFO" "Daemon started PID=$$ with Zero-Lag Wakeup (inotifyd PID=$INOTIFY_PID)"
else
    log_msg "INFO" "Daemon started PID=$$ in adaptive polling mode (inotifyd unavailable)"
fi

while true; do
    WAKE_SIG=0
    load_config

    NOW=$(date +%s 2>/dev/null)
    is_uint "$NOW" || NOW=0
    get_uptime_sec_fast

    # 1. Read Power / Battery / Thermal state
    read_sysfs_fast /sys/class/power_supply/battery/capacity "50"
    BATT_CAP="$SYSFS_VAL"
    is_uint "$BATT_CAP" || BATT_CAP=50
    read_sysfs_fast /sys/class/power_supply/usb/online "0"
    USB_ON="$SYSFS_VAL"
    read_sysfs_fast /sys/class/power_supply/wireless/online "0"
    WLS_ON="$SYSFS_VAL"
    PLUGGED=0
    if [ "$USB_ON" = "1" ] || [ "$WLS_ON" = "1" ]; then
        PLUGGED=1
    fi
    get_charging_current_ma

    get_temperatures
    # Use Xiaomi board_sensor_temp (VIRTUAL-SENSOR0) instead of quiet_therm to avoid false WARN
    GUARD_BOARD_X10="$TEMP_BOARD_X10"
    [ "$GUARD_BOARD_X10" -le 0 ] && GUARD_BOARD_X10="$TEMP_SKIN_X10"

    # 2. Screen-Off Power Save State Machine (must run before Auto Game Mode to avoid dumpsys when screen is OFF)
    SCR_ON=1
    if is_screen_on; then
        SCR_ON=1
        OFF_SINCE=0
        if [ -f "$SCREEN_OFF_FLAG" ]; then
            rm -f "$SCREEN_OFF_FLAG"
            resolve_wake_profile
            if [ "$THERMAL_STATE" = "critical" ]; then
                apply_cpu_gpu_profile "thermal_crit"
            else
                apply_cpu_gpu_profile "$_wake_prof"
                if [ "$THERMAL_STATE" = "warn" ]; then
                    if [ "$_wake_prof" = "gaming" ] || [ "$_wake_prof" = "performance" ]; then
                        restore_gpu_cdev_floor
                        set_gpu_max_mhz 770
                    elif [ "$_wake_prof" = "game_cool60" ]; then
                        clear_cpu_nolimit
                        set_gpu_max_mhz 629
                    fi
                fi
            fi
            unforce_doze_if_needed
            log_msg "INFO" "Screen ON detected (polling): restored profile=$_wake_prof"
        else
            unforce_doze_if_needed
        fi
    else
        SCR_ON=0
        if [ "$SCREEN_OFF_ENABLED" -eq 1 ]; then
            if [ ! -f "$SCREEN_OFF_FLAG" ]; then
                if is_screen_truly_off; then
                    [ "$OFF_SINCE" -eq 0 ] && OFF_SINCE="$NOW"
                    ELAPSED=$((NOW - OFF_SINCE))
                    if [ "$ELAPSED" -ge "$SCREEN_OFF_DEBOUNCE" ]; then
                        printf '1\n' > "$SCREEN_OFF_FLAG"
                        apply_cpu_gpu_profile "screen_off"
                        log_msg "INFO" "Screen OFF (${ELAPSED}s): applied screen_off caps (policy0 untouched)"
                        if [ "$SCREEN_OFF_DOZE" -eq 1 ] && [ "$PLUGGED" -eq 0 ]; then
                            printf '1\n' > "$DOZE_FORCED_FLAG"
                            dumpsys deviceidle force-idle >/dev/null 2>&1
                        fi
                    fi
                else
                    OFF_SINCE=0
                fi
            fi
        else
            OFF_SINCE=0
            if [ -f "$SCREEN_OFF_FLAG" ]; then
                rm -f "$SCREEN_OFF_FLAG"
                resolve_wake_profile
                apply_cpu_gpu_profile "$_wake_prof"
            fi
            unforce_doze_if_needed
        fi
    fi

    # 2b. ZRAM Self-Heal Guard (zero-fork check on first screen-ON, every ~15s in first 3m after boot, then ~60s while screen ON)
    check_and_heal_zram

    # 3. Auto Game Mode with Per-Game Profile (15s exit debounce; instant hot-switch between games)
    if [ "$SCR_ON" -eq 1 ]; then
        if [ "$AUTO_GAME_ENABLED" -eq 1 ] && [ "$PROFILE" != "gaming" ]; then
            if get_foreground_package && get_game_profile "$FG_PKG"; then
                AUTO_GAME_LEFT_SINCE=0
                if [ "$AUTO_GAME_ACTIVE" -eq 0 ] || [ "$AUTO_GAME_PKG" != "$FG_PKG" ] || [ "$AUTO_GAME_PROF" != "$MATCHED_GAME_PROF" ]; then
                    AUTO_GAME_ACTIVE=1
                    AUTO_GAME_PKG="$FG_PKG"
                    AUTO_GAME_PROF="$MATCHED_GAME_PROF"
                    printf 'active:%s:%s\n' "$AUTO_GAME_PROF" "$FG_PKG" > "$AUTO_GAME_STATE_FILE"
                    if [ ! -f "$SCREEN_OFF_FLAG" ]; then
                        apply_game_profile_full "$AUTO_GAME_PROF" "$THERMAL_STATE"
                    fi
                    log_msg "INFO" "Auto Game Mode: activated profile=$AUTO_GAME_PROF for $FG_PKG"
                fi
            elif [ "$AUTO_GAME_ACTIVE" -eq 1 ] && [ -n "$FG_PKG" ]; then
                [ "$AUTO_GAME_LEFT_SINCE" -eq 0 ] && AUTO_GAME_LEFT_SINCE="$NOW"
                LEFT_ELAPSED=$((NOW - AUTO_GAME_LEFT_SINCE))
                if [ "$LEFT_ELAPSED" -ge "$AUTO_GAME_EXIT_DEBOUNCE" ]; then
                    AUTO_GAME_ACTIVE=0
                    AUTO_GAME_PKG=""
                    AUTO_GAME_PROF="none"
                    AUTO_GAME_LEFT_SINCE=0
                    printf 'idle\n' > "$AUTO_GAME_STATE_FILE"
                    if [ "$THERMAL_STATE" != "critical" ]; then
                        apply_cpu_gpu_profile "$PROFILE"
                        if [ "$THERMAL_STATE" = "warn" ] && [ "$PROFILE" = "performance" ]; then
                            restore_gpu_cdev_floor
                            set_gpu_max_mhz 770
                        fi
                        if [ "$THERMAL_STATE" = "warn" ] && [ "$FPS_MODE" = "force120" ]; then
                            apply_fps_settings "smart120" "keep"
                        else
                            apply_fps_settings "$FPS_MODE" "keep"
                        fi
                    fi
                    log_msg "INFO" "Auto Game Mode: exited after ${LEFT_ELAPSED}s, restored profile=$PROFILE fps=$FPS_MODE"
                fi
            fi
        elif [ "$AUTO_GAME_ACTIVE" -eq 1 ]; then
            AUTO_GAME_ACTIVE=0
            AUTO_GAME_PKG=""
            AUTO_GAME_PROF="none"
            AUTO_GAME_LEFT_SINCE=0
            printf 'idle\n' > "$AUTO_GAME_STATE_FILE"
            if [ "$PROFILE" != "gaming" ] && [ "$THERMAL_STATE" != "critical" ]; then
                apply_cpu_gpu_profile "$PROFILE"
                apply_fps_settings "$FPS_MODE" "keep"
            fi
        fi
    elif [ "$AUTO_GAME_ACTIVE" -eq 1 ] && { [ "$AUTO_GAME_ENABLED" -eq 0 ] || [ "$PROFILE" = "gaming" ]; }; then
        AUTO_GAME_ACTIVE=0
        AUTO_GAME_PKG=""
        AUTO_GAME_PROF="none"
        AUTO_GAME_LEFT_SINCE=0
        printf 'idle\n' > "$AUTO_GAME_STATE_FILE"
        if [ "$PROFILE" != "gaming" ] && [ "$THERMAL_STATE" != "critical" ]; then
            apply_fps_settings "$FPS_MODE" "keep"
        fi
    fi

    GAMING_ACTIVE=0
    EFFECTIVE_GAME_PROF="none"
    EFFECTIVE_PROFILE="$PROFILE"
    if [ "$PROFILE" = "gaming" ]; then
        GAMING_ACTIVE=1
        EFFECTIVE_GAME_PROF="max120"
        EFFECTIVE_PROFILE="gaming"
    elif [ "$AUTO_GAME_ACTIVE" -eq 1 ]; then
        GAMING_ACTIVE=1
        EFFECTIVE_GAME_PROF="$AUTO_GAME_PROF"
        case "$AUTO_GAME_PROF" in
            cool60) EFFECTIVE_PROFILE="game_cool60" ;;
            eco60) EFFECTIVE_PROFILE="game_eco60" ;;
            *) EFFECTIVE_PROFILE="gaming" ;;
        esac
    fi

    # 4. Thermal Guard 2-Tier State Machine
    # Gaming (max120): Warn 44C/48C (GPU 770MHz, keep 120Hz), Crit 46C/50C (reset nolimit, 60Hz, cap CPU/GPU, pause charge)
    if [ "$THERMAL_GUARD_ENABLED" -eq 1 ]; then
        if [ "$EFFECTIVE_PROFILE" = "gaming" ]; then
            WARN_BATT_X10=440
            WARN_BOARD_X10=480
            CRIT_BATT_X10=460
            CRIT_BOARD_X10=500
        else
            WARN_BATT_X10=$((THERMAL_WARN_C * 10))
            WARN_BOARD_X10=$(((THERMAL_WARN_C + 3) * 10))
            CRIT_BATT_X10=$((THERMAL_CRIT_C * 10))
            CRIT_BOARD_X10=$(((THERMAL_CRIT_C + 3) * 10))
        fi
        RECOV_CRIT_BATT=$((CRIT_BATT_X10 - 30))
        RECOV_CRIT_BOARD=$((CRIT_BOARD_X10 - 30))
        RECOV_WARN_BATT=$((WARN_BATT_X10 - 20))
        RECOV_WARN_BOARD=$((WARN_BOARD_X10 - 20))

        NEW_STATE="$THERMAL_STATE"
        NEW_TRIG="none"

        if [ "$TEMP_BATT_X10" -ge "$CRIT_BATT_X10" ] || [ "$GUARD_BOARD_X10" -ge "$CRIT_BOARD_X10" ]; then
            NEW_STATE="critical"
            if [ "$TEMP_BATT_X10" -ge "$CRIT_BATT_X10" ] && [ "$GUARD_BOARD_X10" -ge "$CRIT_BOARD_X10" ]; then
                NEW_TRIG="both"
            elif [ "$TEMP_BATT_X10" -ge "$CRIT_BATT_X10" ]; then
                NEW_TRIG="batt"
            else
                NEW_TRIG="board"
            fi
        elif [ "$THERMAL_STATE" = "critical" ]; then
            if [ "$TEMP_BATT_X10" -le "$RECOV_CRIT_BATT" ] && [ "$GUARD_BOARD_X10" -le "$RECOV_CRIT_BOARD" ]; then
                if [ "$TEMP_BATT_X10" -ge "$WARN_BATT_X10" ] || [ "$GUARD_BOARD_X10" -ge "$WARN_BOARD_X10" ]; then
                    NEW_STATE="warn"
                    [ "$TEMP_BATT_X10" -ge "$WARN_BATT_X10" ] && NEW_TRIG="batt" || NEW_TRIG="board"
                else
                    NEW_STATE="normal"
                    NEW_TRIG="none"
                fi
            else
                NEW_TRIG="$THERMAL_TRIGGER"
            fi
        elif [ "$TEMP_BATT_X10" -ge "$WARN_BATT_X10" ] || [ "$GUARD_BOARD_X10" -ge "$WARN_BOARD_X10" ]; then
            NEW_STATE="warn"
            if [ "$TEMP_BATT_X10" -ge "$WARN_BATT_X10" ] && [ "$GUARD_BOARD_X10" -ge "$WARN_BOARD_X10" ]; then
                NEW_TRIG="both"
            elif [ "$TEMP_BATT_X10" -ge "$WARN_BATT_X10" ]; then
                NEW_TRIG="batt"
            else
                NEW_TRIG="board"
            fi
        elif [ "$THERMAL_STATE" = "warn" ]; then
            if [ "$TEMP_BATT_X10" -le "$RECOV_WARN_BATT" ] && [ "$GUARD_BOARD_X10" -le "$RECOV_WARN_BOARD" ]; then
                NEW_STATE="normal"
                NEW_TRIG="none"
            else
                NEW_TRIG="$THERMAL_TRIGGER"
            fi
        fi

        if [ "$NEW_STATE" != "$THERMAL_STATE" ] || [ "$NEW_TRIG" != "$THERMAL_TRIGGER" ]; then
            PREV_STATE="$THERMAL_STATE"
            THERMAL_STATE="$NEW_STATE"
            THERMAL_TRIGGER="$NEW_TRIG"
            printf '%s:%s\n' "$THERMAL_STATE" "$THERMAL_TRIGGER" > "$THERMAL_STATE_FILE"

            if [ "$THERMAL_STATE" != "$PREV_STATE" ]; then
                case "$THERMAL_STATE" in
                    critical)
                        log_msg "WARN" "Thermal Guard CRITICAL (trigger=$THERMAL_TRIGGER batt=${TEMP_BATT_X10} board=${GUARD_BOARD_X10}): clearing nolimit, locking 60Hz, capping CPU/GPU, pausing charge"
                        apply_fps_settings "lock60" "keep"
                        apply_cpu_gpu_profile "thermal_crit"
                        if [ "$PLUGGED" -eq 1 ]; then
                            set_charging_paused 1
                            CHARGE_PAUSED_BY_THERMAL=1
                        fi
                        ;;
                    warn)
                        log_msg "WARN" "Thermal Guard WARN (trigger=$THERMAL_TRIGGER batt=${TEMP_BATT_X10} board=${GUARD_BOARD_X10} prof=$EFFECTIVE_PROFILE): stepping down clocks"
                        if [ "$GAMING_ACTIVE" -eq 1 ]; then
                            if [ ! -f "$SCREEN_OFF_FLAG" ]; then
                                apply_game_profile_full "$EFFECTIVE_GAME_PROF" "warn"
                            elif [ "$PREV_STATE" = "critical" ] && { [ "$EFFECTIVE_GAME_PROF" = "max120" ] || [ "$EFFECTIVE_GAME_PROF" = "cool60" ]; }; then
                                apply_fps_settings "gaming120" "keep"
                            fi
                        else
                            if [ "$FPS_MODE" = "force120" ] || [ "$PREV_STATE" = "critical" ]; then
                                apply_fps_settings "smart120" "keep"
                            fi
                            if [ "$PREV_STATE" = "critical" ] && [ ! -f "$SCREEN_OFF_FLAG" ]; then
                                apply_cpu_gpu_profile "$EFFECTIVE_PROFILE"
                            fi
                            if [ "$EFFECTIVE_PROFILE" = "performance" ] && [ ! -f "$SCREEN_OFF_FLAG" ]; then
                                restore_gpu_cdev_floor
                                set_gpu_max_mhz 770
                            fi
                        fi
                        if [ "$PREV_STATE" = "critical" ] && [ "$CHARGE_PAUSED_BY_THERMAL" -eq 1 ]; then
                            CHARGE_PAUSED_BY_THERMAL=0
                            [ "$CHARGE_PAUSED_BY_SOC" -eq 0 ] && [ "$GAME_BYPASS_ACTIVE" -eq 0 ] && set_charging_paused 0
                        fi
                        ;;
                    normal)
                        log_msg "INFO" "Thermal Guard NORMAL (batt=${TEMP_BATT_X10} board=${GUARD_BOARD_X10}): restoring profile=$EFFECTIVE_PROFILE"
                        if [ "$GAMING_ACTIVE" -eq 1 ]; then
                            if [ ! -f "$SCREEN_OFF_FLAG" ]; then
                                apply_game_profile_full "$EFFECTIVE_GAME_PROF" "normal"
                            elif [ "$EFFECTIVE_GAME_PROF" = "eco60" ]; then
                                apply_fps_settings "lock60" "keep"
                            else
                                apply_fps_settings "gaming120" "keep"
                            fi
                        else
                            apply_fps_settings "$FPS_MODE" "keep"
                            [ ! -f "$SCREEN_OFF_FLAG" ] && apply_cpu_gpu_profile "$EFFECTIVE_PROFILE"
                        fi
                        if [ "$CHARGE_PAUSED_BY_THERMAL" -eq 1 ]; then
                            CHARGE_PAUSED_BY_THERMAL=0
                            [ "$CHARGE_PAUSED_BY_SOC" -eq 0 ] && [ "$GAME_BYPASS_ACTIVE" -eq 0 ] && set_charging_paused 0
                        fi
                        ;;
                esac
            fi
        fi
    else
        if [ "$THERMAL_STATE" != "normal" ]; then
            THERMAL_STATE="normal"
            THERMAL_TRIGGER="none"
            CHARGE_PAUSED_BY_THERMAL=0
            printf 'normal:none\n' > "$THERMAL_STATE_FILE"
        fi
    fi

    # 5. Anti-Reclamp Loop for Gaming (only in NORMAL thermal state while screen ON)
    if [ "$THERMAL_STATE" = "normal" ] && [ ! -f "$SCREEN_OFF_FLAG" ]; then
        if [ "$EFFECTIVE_PROFILE" = "gaming" ]; then
            enforce_gaming_uncapped
        elif [ "$EFFECTIVE_PROFILE" = "game_cool60" ]; then
            if [ -n "$CPU_NOLIMIT_NODE" ]; then
                read_sysfs_fast "$CPU_NOLIMIT_NODE" "0"
                [ "$SYSFS_VAL" != "43000" ] && write_sysfs "$CPU_NOLIMIT_NODE" "43000"
            fi
            if [ -n "$DISP_FPS_CDEV_NODE" ]; then
                read_sysfs_fast "$DISP_FPS_CDEV_NODE" "0"
                [ "$SYSFS_VAL" != "0" ] && write_sysfs "$DISP_FPS_CDEV_NODE" "0"
            fi
        fi
    fi

    # 6. Gaming Auto-Bypass + Smart Charge Control (True Bypass fcc=0 + 350ms PPS EOC Reset Pulse)
    read_sysfs_fast "$TOPUP_ONCE_FLAG" ""
    TOPUP_STATE="$SYSFS_VAL"

    if [ "$PLUGGED" -eq 1 ] && [ "$PREV_PLUGGED" -eq 0 ]; then
        _need_attach_guard=0
        if [ "$THERMAL_STATE" = "critical" ]; then
            _need_attach_guard=1
        elif [ "$GAME_AUTO_BYPASS" -eq 1 ] && [ "$GAMING_ACTIVE" -eq 1 ] && [ "$USB_ON" = "1" ] && [ "$BATT_CAP" -ge "$GAME_BYPASS_MIN_PCT" ]; then
            _need_attach_guard=1
        elif [ -z "$TOPUP_STATE" ] && [ "$CHARGE_ENABLED" -eq 1 ] && [ "$BATT_CAP" -ge "$CHARGE_STOP_PCT" ]; then
            _need_attach_guard=1
        fi
        # Guard 8s post-attach window while Xiaomi 90W PD/VDM/PPS negotiation settles
        [ "$_need_attach_guard" -eq 1 ] && ATTACH_GUARD_UNTIL=$((NOW + 8))
    elif [ "$PLUGGED" -eq 0 ]; then
        ATTACH_GUARD_UNTIL=0
    fi
    PREV_PLUGGED="$PLUGGED"

    # Keep Top-Up Once pending->armed and unplug auto-clear intact even while Gaming Auto-Bypass defers charging
    if [ "$PLUGGED" -eq 1 ] && [ "$TOPUP_STATE" = "pending" ]; then
        atomic_write_file "$TOPUP_ONCE_FLAG" "armed"
        TOPUP_STATE="armed"
        log_msg "INFO" "Top-up once armed on charger attach: charging allowed to 100%"
    elif [ "$PLUGGED" -eq 0 ] && [ "$TOPUP_STATE" = "armed" ]; then
        rm -f "$TOPUP_ONCE_FLAG"
        TOPUP_STATE=""
        log_msg "INFO" "Charger unplugged: auto-cleared topup-once, Smart Charge (${CHARGE_STOP_PCT}%/${CHARGE_RESUME_PCT}%) restored"
    fi

    if [ "$THERMAL_STATE" = "critical" ] && [ "$PLUGGED" -eq 1 ]; then
        if ! is_charging_paused || [ "$CURR_MA" -gt 50 ]; then
            set_charging_paused 1
            CHARGE_PAUSED_BY_THERMAL=1
        fi
    fi

    # 6a. Gaming Auto-Bypass State Machine (USB wired only, independent of CHARGE_ENABLED, +2% floor hysteresis)
    _gb_want=0
    if [ "$GAME_AUTO_BYPASS" -eq 1 ] && [ "$GAMING_ACTIVE" -eq 1 ] && [ "$USB_ON" = "1" ]; then
        _gb_recover_pct=$((GAME_BYPASS_MIN_PCT + 2))
        [ "$_gb_recover_pct" -gt 100 ] && _gb_recover_pct=100
        if [ "$BATT_CAP" -lt "$GAME_BYPASS_MIN_PCT" ]; then
            GAME_BYPASS_LOW_LATCH=1
        elif [ "$GAME_BYPASS_LOW_LATCH" -eq 1 ] && [ "$BATT_CAP" -ge "$_gb_recover_pct" ]; then
            GAME_BYPASS_LOW_LATCH=0
        fi
        if [ "$GAME_BYPASS_LOW_LATCH" -eq 0 ] && [ "$BATT_CAP" -ge "$GAME_BYPASS_MIN_PCT" ]; then
            _gb_want=1
        fi
    else
        GAME_BYPASS_LOW_LATCH=0
    fi

    if [ "$_gb_want" -eq 1 ]; then
        if [ "$GAME_BYPASS_ACTIVE" -eq 0 ]; then
            GAME_BYPASS_ACTIVE=1
            printf '1\n' > "$GAME_BYPASS_FLAG"
            engage_fcc_bypass
            log_msg "INFO" "Gaming Auto-Bypass: enabled True Bypass (fcc=0) at ${BATT_CAP}% (floor=${GAME_BYPASS_MIN_PCT}%, pkg=${AUTO_GAME_PKG:-manual})"
        else
            if [ -n "$CONST_CURR_NODE" ]; then
                read_sysfs_fast "$CONST_CURR_NODE" "0"
                if [ "$SYSFS_VAL" != "0" ] || [ "$CURR_MA" -gt 50 ]; then
                    engage_fcc_bypass
                fi
            elif ! is_charging_paused || [ "$CURR_MA" -gt 50 ]; then
                engage_fcc_bypass
            fi
        fi
    else
        if [ "$GAME_BYPASS_ACTIVE" -eq 1 ]; then
            GAME_BYPASS_ACTIVE=0
            rm -f "$GAME_BYPASS_FLAG"
            if [ "$PLUGGED" -eq 1 ]; then
                _keep_paused=0
                [ "$THERMAL_STATE" = "critical" ] && _keep_paused=1
                if [ "$CHARGE_ENABLED" -eq 1 ] && [ -z "$TOPUP_STATE" ]; then
                    if [ "$BATT_CAP" -ge "$CHARGE_STOP_PCT" ] || { [ "$CHARGE_PAUSED_BY_SOC" -eq 1 ] && [ "$BATT_CAP" -gt "$CHARGE_RESUME_PCT" ]; }; then
                        _keep_paused=1
                        CHARGE_PAUSED_BY_SOC=1
                    fi
                fi
                if [ "$_keep_paused" -eq 1 ]; then
                    set_charging_paused 1
                    log_msg "INFO" "Gaming Auto-Bypass: released -> kept charging paused at ${BATT_CAP}% (Smart Charge / Thermal)"
                else
                    CHARGE_PAUSED_BY_SOC=0
                    set_charging_paused 0
                    [ "$CHARGE_ENABLED" -eq 1 ] && [ "$CHARGE_LIMIT_MA" -gt 0 ] && apply_charge_current_limit "$CHARGE_LIMIT_MA"
                    log_msg "INFO" "Gaming Auto-Bypass: released at ${BATT_CAP}%, resumed charging"
                fi
            else
                CHARGE_PAUSED_BY_SOC=0
                CHARGE_PAUSED_BY_THERMAL=0
                set_charging_paused 0
                log_msg "INFO" "Gaming Auto-Bypass: released on USB unplug, restored default FCC"
            fi
        fi

        # 6b. Normal Smart Charge Control (runs only when Gaming Auto-Bypass is inactive)
        if [ "$CHARGE_ENABLED" -eq 1 ] && [ -n "$(get_active_charge_node)" ]; then
            if [ "$PLUGGED" -eq 1 ]; then
                if [ -n "$TOPUP_STATE" ]; then
                    ATTACH_GUARD_UNTIL=0
                    if [ "$CHARGE_PAUSED_BY_SOC" -eq 1 ] || is_charging_paused; then
                        if [ "$CHARGE_PAUSED_BY_THERMAL" -eq 0 ]; then
                            set_charging_paused 0
                            CHARGE_PAUSED_BY_SOC=0
                        fi
                    fi
                    [ "$CHARGE_PAUSED_BY_THERMAL" -eq 0 ] && [ "$CHARGE_LIMIT_MA" -gt 0 ] && apply_charge_current_limit "$CHARGE_LIMIT_MA"
                elif [ "$BATT_CAP" -ge "$CHARGE_STOP_PCT" ]; then
                    if [ "$CHARGE_PAUSED_BY_SOC" -eq 0 ]; then
                        set_charging_paused 1
                        CHARGE_PAUSED_BY_SOC=1
                        log_msg "INFO" "Smart Charge: paused via ${CHARGE_MODE} at ${BATT_CAP}% (target=${CHARGE_STOP_PCT}%)"
                    elif ! is_charging_paused || [ "$CURR_MA" -gt 50 ]; then
                        set_charging_paused 1
                    fi
                elif [ "$BATT_CAP" -le "$CHARGE_RESUME_PCT" ]; then
                    if [ "$CHARGE_PAUSED_BY_SOC" -eq 1 ]; then
                        if [ "$CHARGE_PAUSED_BY_THERMAL" -eq 0 ]; then
                            set_charging_paused 0
                            CHARGE_PAUSED_BY_SOC=0
                            log_msg "INFO" "Smart Charge: resumed at ${BATT_CAP}% (resume=${CHARGE_RESUME_PCT}%)"
                        fi
                    fi
                    [ "$CHARGE_PAUSED_BY_THERMAL" -eq 0 ] && [ "$CHARGE_LIMIT_MA" -gt 0 ] && apply_charge_current_limit "$CHARGE_LIMIT_MA"
                else
                    if [ "$CHARGE_PAUSED_BY_SOC" -eq 1 ]; then
                        if ! is_charging_paused || [ "$CURR_MA" -gt 50 ]; then
                            set_charging_paused 1
                        fi
                    elif [ "$CHARGE_PAUSED_BY_THERMAL" -eq 0 ] && [ "$CHARGE_LIMIT_MA" -gt 0 ]; then
                        apply_charge_current_limit "$CHARGE_LIMIT_MA"
                    fi
                fi
            else
                if [ "$CHARGE_PAUSED_BY_SOC" -eq 1 ] || [ "$CHARGE_PAUSED_BY_THERMAL" -eq 1 ]; then
                    CHARGE_PAUSED_BY_SOC=0
                    CHARGE_PAUSED_BY_THERMAL=0
                    set_charging_paused 0
                    log_msg "INFO" "Charger unplugged: charging gate reset"
                fi
            fi
        else
            if [ "$CHARGE_PAUSED_BY_SOC" -eq 1 ]; then
                CHARGE_PAUSED_BY_SOC=0
                [ "$CHARGE_PAUSED_BY_THERMAL" -eq 0 ] && set_charging_paused 0
            fi
        fi
    fi

    # 7. Adaptive Sleep (no wakelock held; interruptible via USR1)
    INTERVAL=15
    if [ "$SCR_ON" -eq 0 ]; then
        if [ "$PLUGGED" -eq 1 ] && [ "$CHARGE_ENABLED" -eq 1 ]; then
            INTERVAL=10
        else
            INTERVAL=30
        fi
    elif [ "$AUTO_GAME_ENABLED" -eq 1 ] || [ "$EFFECTIVE_PROFILE" = "gaming" ]; then
        INTERVAL=4
    elif [ "$PLUGGED" -eq 1 ] || [ "$THERMAL_STATE" != "normal" ] || [ "$FPS_MODE" = "force120" ]; then
        INTERVAL=5
    else
        INTERVAL=15
    fi

    if [ "$ZRAM_ENABLED" -eq 1 ] && [ "$ZRAM_SIZE_GB" -gt 0 ] && [ "$UP_SEC" -gt 0 ]; then
        if [ "$UP_SEC" -le 210 ] || [ $((UP_SEC - DAEMON_BOOT_UP)) -le 180 ]; then
            [ "$INTERVAL" -gt 15 ] && INTERVAL=15
        fi
    fi

    if [ "$HAS_INOTIFYD" -eq 1 ] && [ -n "$INOTIFY_PID" ]; then
        if ! kill -0 "$INOTIFY_PID" 2>/dev/null; then
            start_inotify_watcher >/dev/null 2>&1
        fi
    fi

    if [ "$WAKE_SIG" -eq 0 ]; then
        if [ "$PLUGGED" -eq 1 ] && [ "$NOW" -lt "$ATTACH_GUARD_UNTIL" ]; then
            if [ -n "$BUSYBOX" ]; then
                "$BUSYBOX" usleep 400000 2>/dev/null || sleep 1
            else
                sleep 0.4 2>/dev/null || sleep 1
            fi
        else
            sleep "$INTERVAL" &
            SLEEP_PID=$!
            wait "$SLEEP_PID" 2>/dev/null
            SLEEP_PID=""
        fi
    fi
done
