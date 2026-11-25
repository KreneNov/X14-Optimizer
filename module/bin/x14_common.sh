#!/system/bin/sh
# x14_common.sh - Shared POSIX sh library for Xiaomi 14 (houji) & generic fallback

CONFIG_DIR="/data/adb/x14_perf_battery"
CONFIG_FILE="$CONFIG_DIR/config.conf"
GAMES_FILE="$CONFIG_DIR/games.list"
SNAP_FILE="$CONFIG_DIR/defaults.snap"
LOG_FILE="/data/local/tmp/x14_perf_battery.log"
DAEMON_PID_FILE="/data/local/tmp/x14_perf_battery.pid"
INOTIFY_PID_FILE="/data/local/tmp/x14_inotify.pid"
SCREEN_OFF_FLAG="/data/local/tmp/x14_screen_off.flag"
DOZE_FORCED_FLAG="/data/local/tmp/x14_doze_forced.flag"
TOPUP_ONCE_FLAG="/data/local/tmp/x14_topup_once.flag"
GAME_BYPASS_FLAG="/data/local/tmp/x14_game_bypass.flag"
THERMAL_STATE_FILE="/data/local/tmp/x14_thermal_state"
AUTO_GAME_STATE_FILE="/data/local/tmp/x14_auto_game_state"
HW_CACHE_FILE="/data/local/tmp/x14_hw_cache.conf"
DISPLAY_CACHE_FILE="/data/local/tmp/x14_display_cache.conf"
LOG_MAX_BYTES=524288
CR=$(printf '\r')

# Cached device info
HW_CACHE_VER=""
DEV_CODENAME=""
DEV_MODEL=""
DEV_OS=""

# Hardware capability flags
HAS_QCOM_BATT=0
HAS_MI_THERMAL=0
HAS_KGSL=0
HAS_INOTIFYD=0
HAS_CPU_NOLIMIT=0
HAS_FPS_OVERLAY=0
HAS_ZRAM=0
BUSYBOX=""

# Resolved sysfs paths
CHARGE_SUSPEND_NODE=""
CHARGE_SUSPEND_ON=""
CHARGE_SUSPEND_OFF=""
CHARGE_NIGHT_NODE=""
RESTRICT_CHG_NODE=""
RESTRICT_CUR_NODE=""
CONST_CURR_NODE=""
GPU_CDEV_NODE=""
CPU_C3_CDEV_NODE=""
DISP_FPS_CDEV_NODE=""
CPU_NOLIMIT_NODE=""
SCONFIG_NODE=""
BACKLIGHT_NODE=""
SCREEN_STATE_NODE=""

# CPU / Thermal topology
CPU_POLICIES=""
LITTLE_POLICY=""
BIG_POLICIES=""
TZ_BATT=""
TZ_SKIN=""
TZ_CPU_LIST=""
TZ_GPU_LIST=""

# Runtime temperatures (x10, e.g. 345 = 34.5 C)
TEMP_BATT_X10=0
TEMP_SKIN_X10=0
TEMP_BOARD_X10=0
TEMP_CPU_X10=0
TEMP_GPU_X10=0
SYSFS_VAL=""
TMP_T_X10=0

# ZRAM runtime telemetry
ZRAM_ACTIVE=0
ZRAM_CUR_ALGO="none"
ZRAM_DISK_BYTES="0"
ZRAM_DISK_MB=0
ZRAM_ORIG_KB=0
ZRAM_ORIG_MB=0
ZRAM_COMPR_MB=0
ZRAM_MEM_KB=0
ZRAM_MEM_MB=0
ZRAM_RATIO_X100=0
ZRAM_BACKING_DEV="none"
BYTES_KB=0
BYTES_MB=0
MEM_AVAIL_KB=0
UP_SEC=0

# Cached display settings
CACHE_PEAK_RR="120.0"
CACHE_MIN_RR="null"
CACHE_GAME_CAP="1"

# Configuration defaults
PROFILE="balanced"
CHARGE_ENABLED=1
CHARGE_STOP_PCT=85
CHARGE_RESUME_PCT=75
CHARGE_LIMIT_MA=0
CHARGE_MODE="fcc"
FPS_MODE="smart120"
FPS_PK_MODE="none"
SCREEN_OFF_ENABLED=1
SCREEN_OFF_DEBOUNCE=30
SCREEN_OFF_DOZE=0
THERMAL_GUARD_ENABLED=1
THERMAL_WARN_C=42
THERMAL_CRIT_C=45
AUTO_GAME_ENABLED=1
JOYOSE_DISABLED=0
ZRAM_ENABLED=1
ZRAM_SIZE_GB=6
ZRAM_ALGO="lz4"
GAME_AUTO_BYPASS=1
GAME_BYPASS_MIN_PCT=20
FG_PKG=""
MATCHED_GAME_PROF="none"

init_env() {
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR" 2>/dev/null
        chmod 0755 "$CONFIG_DIR" 2>/dev/null
    fi
}

detect_busybox() {
    BUSYBOX=""
    HAS_INOTIFYD=0
    for bb in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
        if [ -x "$bb" ]; then
            BUSYBOX="$bb"
            break
        fi
    done
    if [ -z "$BUSYBOX" ]; then
        bb_path=$(command -v busybox 2>/dev/null)
        [ -n "$bb_path" ] && [ -x "$bb_path" ] && BUSYBOX="$bb_path"
    fi
    if [ -n "$BUSYBOX" ]; then
        if "$BUSYBOX" --list 2>/dev/null | grep -qx 'inotifyd'; then
            HAS_INOTIFYD=1
        fi
    fi
}

log_msg() {
    lvl="$1"
    shift
    msg="$*"
    if [ -f "$LOG_FILE" ]; then
        sz=$(wc -c < "$LOG_FILE" 2>/dev/null)
        case "$sz" in
            ''|*[!0-9]*) sz=0 ;;
        esac
        if [ "$sz" -ge "$LOG_MAX_BYTES" ]; then
            mv -f "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null
        fi
    fi
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    [ -z "$ts" ] && ts="0000-00-00 00:00:00"
    printf '[%s] [%s] %s\n' "$ts" "$lvl" "$msg" >> "$LOG_FILE" 2>/dev/null
}

read_sysfs_fast() {
    p="$1"
    def="$2"
    SYSFS_VAL="$def"
    if [ -r "$p" ]; then
        _val=""
        IFS= read -r _val < "$p" 2>/dev/null
        _val=${_val%"$CR"}
        if [ -n "$_val" ]; then
            SYSFS_VAL="$_val"
            return 0
        fi
    fi
    return 1
}

read_sysfs() {
    read_sysfs_fast "$1" "$2"
    _rc=$?
    printf '%s' "$SYSFS_VAL"
    return $_rc
}

write_sysfs() {
    p="$1"
    v="$2"
    if [ -e "$p" ] && [ -w "$p" ]; then
        printf '%s\n' "$v" > "$p" 2>/dev/null
        return $?
    fi
    return 1
}

atomic_write_file() {
    target="$1"
    content="$2"
    tmp="${target}.tmp.$$"
    printf '%s\n' "$content" > "$tmp" 2>/dev/null || return 1
    chmod 0644 "$tmp" 2>/dev/null
    mv -f "$tmp" "$target" 2>/dev/null
}

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_int() {
    case "$1" in
        ''|-) return 1 ;;
        -*)
            rest=${1#-}
            is_uint "$rest"
            return $?
            ;;
        *)
            is_uint "$1"
            return $?
            ;;
    esac
}

detect_hardware() {
    DEV_CODENAME=$(getprop ro.product.device | tr -d '\r\n"')
    DEV_MODEL=$(getprop ro.product.model | tr -d '\r\n"')
    DEV_OS=$(getprop ro.mi.os.version.incremental | tr -d '\r\n"')
    [ -z "$DEV_OS" ] && DEV_OS=$(getprop ro.build.display.id | tr -d '\r\n"')

    HAS_QCOM_BATT=0
    HAS_MI_THERMAL=0
    HAS_KGSL=0
    HAS_ZRAM=0

    [ -d /sys/class/qcom-battery ] && HAS_QCOM_BATT=1
    [ -d /sys/class/thermal/thermal_message ] && HAS_MI_THERMAL=1
    [ -d /sys/class/kgsl/kgsl-3d0 ] && HAS_KGSL=1
    [ -e /dev/block/zram0 ] && [ -d /sys/block/zram0 ] && HAS_ZRAM=1

    # Priority fallback for charge suspend node
    CHARGE_SUSPEND_NODE=""
    CHARGE_SUSPEND_ON=""
    CHARGE_SUSPEND_OFF=""
    if [ -e /sys/class/qcom-battery/input_suspend ]; then
        CHARGE_SUSPEND_NODE="/sys/class/qcom-battery/input_suspend"
        CHARGE_SUSPEND_ON="1"
        CHARGE_SUSPEND_OFF="0"
    elif [ -e /sys/class/power_supply/battery/input_suspend ]; then
        CHARGE_SUSPEND_NODE="/sys/class/power_supply/battery/input_suspend"
        CHARGE_SUSPEND_ON="1"
        CHARGE_SUSPEND_OFF="0"
    elif [ -e /sys/class/power_supply/battery/charging_enabled ]; then
        CHARGE_SUSPEND_NODE="/sys/class/power_supply/battery/charging_enabled"
        CHARGE_SUSPEND_ON="0"
        CHARGE_SUSPEND_OFF="1"
    elif [ -e /sys/class/power_supply/battery/battery_charging_enabled ]; then
        CHARGE_SUSPEND_NODE="/sys/class/power_supply/battery/battery_charging_enabled"
        CHARGE_SUSPEND_ON="0"
        CHARGE_SUSPEND_OFF="1"
    fi

    CHARGE_NIGHT_NODE=""
    [ -e /sys/class/qcom-battery/night_charging ] && CHARGE_NIGHT_NODE="/sys/class/qcom-battery/night_charging"

    RESTRICT_CHG_NODE=""
    RESTRICT_CUR_NODE=""
    if [ -e /sys/class/qcom-battery/restrict_chg ] && [ -e /sys/class/qcom-battery/restrict_cur ]; then
        RESTRICT_CHG_NODE="/sys/class/qcom-battery/restrict_chg"
        RESTRICT_CUR_NODE="/sys/class/qcom-battery/restrict_cur"
    fi

    CONST_CURR_NODE=""
    [ -e /sys/class/power_supply/battery/constant_charge_current ] && CONST_CURR_NODE="/sys/class/power_supply/battery/constant_charge_current"

    GPU_CDEV_NODE=""
    CPU_C3_CDEV_NODE=""
    DISP_FPS_CDEV_NODE=""
    for cdev in /sys/class/thermal/cooling_device*; do
        [ -d "$cdev" ] || continue
        read_sysfs_fast "$cdev/type" ""
        case "$SYSFS_VAL" in
            gpu)
                [ -z "$GPU_CDEV_NODE" ] && [ -e "$cdev/cur_state" ] && GPU_CDEV_NODE="$cdev/cur_state"
                ;;
            cpu-cluster3)
                [ -z "$CPU_C3_CDEV_NODE" ] && [ -e "$cdev/cur_state" ] && CPU_C3_CDEV_NODE="$cdev/cur_state"
                ;;
            display-fps)
                [ -z "$DISP_FPS_CDEV_NODE" ] && [ -e "$cdev/cur_state" ] && DISP_FPS_CDEV_NODE="$cdev/cur_state"
                ;;
        esac
    done

    CPU_NOLIMIT_NODE=""
    HAS_CPU_NOLIMIT=0
    if [ -e /sys/class/thermal/thermal_message/cpu_nolimit_temp ]; then
        CPU_NOLIMIT_NODE="/sys/class/thermal/thermal_message/cpu_nolimit_temp"
        HAS_CPU_NOLIMIT=1
    fi

    SCONFIG_NODE=""
    [ -e /sys/class/thermal/thermal_message/sconfig ] && SCONFIG_NODE="/sys/class/thermal/thermal_message/sconfig"

    check_fps_overlay_live

    BACKLIGHT_NODE=""
    if [ -r /sys/class/backlight/panel0-backlight/brightness ]; then
        BACKLIGHT_NODE="/sys/class/backlight/panel0-backlight/brightness"
    else
        for bl in /sys/class/backlight/*/brightness; do
            if [ -r "$bl" ]; then
                BACKLIGHT_NODE="$bl"
                break
            fi
        done
    fi

    SCREEN_STATE_NODE=""
    [ -r /sys/class/thermal/thermal_message/screen_state ] && SCREEN_STATE_NODE="/sys/class/thermal/thermal_message/screen_state"

    # Discover CPU policies & identify LITTLE_POLICY (lowest cpuinfo_max_freq)
    CPU_POLICIES=""
    LITTLE_POLICY=""
    BIG_POLICIES=""
    min_max_freq=999999999

    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$p" ] || continue
        pname=${p##*/}
        if [ -z "$CPU_POLICIES" ]; then
            CPU_POLICIES="$pname"
        else
            CPU_POLICIES="$CPU_POLICIES $pname"
        fi
        read_sysfs_fast "$p/cpuinfo_max_freq" "0"
        cmax="$SYSFS_VAL"
        if is_uint "$cmax" && [ "$cmax" -gt 0 ] && [ "$cmax" -lt "$min_max_freq" ]; then
            min_max_freq="$cmax"
            LITTLE_POLICY="$pname"
        fi
    done

    for pname in $CPU_POLICIES; do
        if [ "$pname" != "$LITTLE_POLICY" ]; then
            if [ -z "$BIG_POLICIES" ]; then
                BIG_POLICIES="$pname"
            else
                BIG_POLICIES="$BIG_POLICIES $pname"
            fi
        fi
    done
}

check_fps_overlay_live() {
    HAS_FPS_OVERLAY=0
    _xml="/vendor/etc/display/thermallevel_to_fps.xml"
    [ -r "$_xml" ] || return 0
    _hit5=0
    _hit6=0
    _hit7=0
    while IFS= read -r _xl; do
        case "$_xl" in
            *'level="5"'*'fps="120"'*) _hit5=1 ;;
            *'level="6"'*'fps="120"'*) _hit6=1 ;;
            *'level="7"'*'fps="120"'*) _hit7=1 ;;
        esac
    done < "$_xml"
    [ "$_hit5" -eq 1 ] && [ "$_hit6" -eq 1 ] && [ "$_hit7" -eq 1 ] && HAS_FPS_OVERLAY=1
    return 0
}

resolve_thermal_zones() {
    TZ_BATT=""
    TZ_SKIN=""
    TZ_CPU_LIST=""
    TZ_GPU_LIST=""
    tz_skin_fb=""
    tz_cpu_fb=""

    for z in /sys/class/thermal/thermal_zone*; do
        [ -d "$z" ] || continue
        read_sysfs_fast "$z/type" ""
        ztype="$SYSFS_VAL"
        case "$ztype" in
            battery)
                TZ_BATT="$z/temp"
                ;;
            quiet_therm)
                TZ_SKIN="$z/temp"
                ;;
            skin-therm|xo-therm)
                [ -z "$tz_skin_fb" ] && tz_skin_fb="$z/temp"
                ;;
            cpuss-*)
                if [ -z "$TZ_CPU_LIST" ]; then
                    TZ_CPU_LIST="$z/temp"
                else
                    TZ_CPU_LIST="$TZ_CPU_LIST $z/temp"
                fi
                ;;
            cpu_therm)
                tz_cpu_fb="$z/temp"
                ;;
            gpuss-*)
                if [ -z "$TZ_GPU_LIST" ]; then
                    TZ_GPU_LIST="$z/temp"
                else
                    TZ_GPU_LIST="$TZ_GPU_LIST $z/temp"
                fi
                ;;
        esac
    done

    [ -z "$TZ_SKIN" ] && TZ_SKIN="$tz_skin_fb"
    [ -z "$TZ_CPU_LIST" ] && TZ_CPU_LIST="$tz_cpu_fb"
}

load_or_build_hw_cache() {
    if [ -r "$HW_CACHE_FILE" ]; then
        . "$HW_CACHE_FILE"
        if [ "$HW_CACHE_VER" = "130" ]; then
            return 0
        fi
    fi

    detect_busybox
    detect_hardware
    resolve_thermal_zones
    HW_CACHE_VER="130"

    cache="HW_CACHE_VER='130'
DEV_CODENAME='$DEV_CODENAME'
DEV_MODEL='$DEV_MODEL'
DEV_OS='$DEV_OS'
HAS_QCOM_BATT=$HAS_QCOM_BATT
HAS_MI_THERMAL=$HAS_MI_THERMAL
HAS_KGSL=$HAS_KGSL
HAS_INOTIFYD=$HAS_INOTIFYD
HAS_CPU_NOLIMIT=$HAS_CPU_NOLIMIT
HAS_FPS_OVERLAY=$HAS_FPS_OVERLAY
HAS_ZRAM=$HAS_ZRAM
BUSYBOX='$BUSYBOX'
CHARGE_SUSPEND_NODE='$CHARGE_SUSPEND_NODE'
CHARGE_SUSPEND_ON='$CHARGE_SUSPEND_ON'
CHARGE_SUSPEND_OFF='$CHARGE_SUSPEND_OFF'
CHARGE_NIGHT_NODE='$CHARGE_NIGHT_NODE'
RESTRICT_CHG_NODE='$RESTRICT_CHG_NODE'
RESTRICT_CUR_NODE='$RESTRICT_CUR_NODE'
CONST_CURR_NODE='$CONST_CURR_NODE'
GPU_CDEV_NODE='$GPU_CDEV_NODE'
CPU_C3_CDEV_NODE='$CPU_C3_CDEV_NODE'
DISP_FPS_CDEV_NODE='$DISP_FPS_CDEV_NODE'
CPU_NOLIMIT_NODE='$CPU_NOLIMIT_NODE'
SCONFIG_NODE='$SCONFIG_NODE'
BACKLIGHT_NODE='$BACKLIGHT_NODE'
SCREEN_STATE_NODE='$SCREEN_STATE_NODE'
CPU_POLICIES='$CPU_POLICIES'
LITTLE_POLICY='$LITTLE_POLICY'
BIG_POLICIES='$BIG_POLICIES'
TZ_BATT='$TZ_BATT'
TZ_SKIN='$TZ_SKIN'
TZ_CPU_LIST='$TZ_CPU_LIST'
TZ_GPU_LIST='$TZ_GPU_LIST'"
    atomic_write_file "$HW_CACHE_FILE" "$cache"
}

refresh_display_cache() {
    p_rr=$(settings get system peak_refresh_rate 2>/dev/null)
    p_rr=${p_rr%"$CR"}
    [ -z "$p_rr" ] && p_rr="null"

    m_rr=$(settings get system min_refresh_rate 2>/dev/null)
    m_rr=${m_rr%"$CR"}
    [ -z "$m_rr" ] && m_rr="null"

    g_cap=$(getprop debug.graphics.game_default_frame_rate.disabled 2>/dev/null)
    g_cap=${g_cap%"$CR"}
    [ "$g_cap" = "true" ] && g_bool=1 || g_bool=0

    CACHE_PEAK_RR="$p_rr"
    CACHE_MIN_RR="$m_rr"
    CACHE_GAME_CAP="$g_bool"

    dcache="CACHE_PEAK_RR='$CACHE_PEAK_RR'
CACHE_MIN_RR='$CACHE_MIN_RR'
CACHE_GAME_CAP=$CACHE_GAME_CAP"
    atomic_write_file "$DISPLAY_CACHE_FILE" "$dcache"
}

load_display_cache() {
    if [ -r "$DISPLAY_CACHE_FILE" ]; then
        . "$DISPLAY_CACHE_FILE"
    else
        refresh_display_cache
    fi
}

read_temp_x10_fast() {
    path="$1"
    TMP_T_X10=0
    [ -n "$path" ] || return 1
    read_sysfs_fast "$path" "" || return 1
    raw="$SYSFS_VAL"
    is_int "$raw" || return 1
    if [ "$raw" -le -100000 ] || [ "$raw" -ge 200000 ]; then
        return 1
    fi
    if [ "$raw" -ge 1000 ] || [ "$raw" -le -1000 ]; then
        TMP_T_X10=$((raw / 100))
    elif [ "$raw" -ge 100 ]; then
        TMP_T_X10="$raw"
    else
        TMP_T_X10=$((raw * 10))
    fi
    return 0
}

get_temperatures() {
    TEMP_BATT_X10=0
    TEMP_SKIN_X10=0
    TEMP_BOARD_X10=0
    TEMP_CPU_X10=0
    TEMP_GPU_X10=0

    if [ -n "$TZ_BATT" ]; then
        read_temp_x10_fast "$TZ_BATT"
        TEMP_BATT_X10="$TMP_T_X10"
    fi
    if [ "$TEMP_BATT_X10" -eq 0 ] && [ -r /sys/class/power_supply/battery/temp ]; then
        read_temp_x10_fast /sys/class/power_supply/battery/temp
        TEMP_BATT_X10="$TMP_T_X10"
    fi

    if [ -n "$TZ_SKIN" ]; then
        read_temp_x10_fast "$TZ_SKIN"
        TEMP_SKIN_X10="$TMP_T_X10"
    fi

    if [ "$HAS_MI_THERMAL" -eq 1 ] && [ -r /sys/class/thermal/thermal_message/board_sensor_temp ]; then
        read_temp_x10_fast /sys/class/thermal/thermal_message/board_sensor_temp
        TEMP_BOARD_X10="$TMP_T_X10"
    fi

    if [ "$TEMP_SKIN_X10" -eq 0 ] && [ "$TEMP_BOARD_X10" -gt 0 ]; then
        TEMP_SKIN_X10="$TEMP_BOARD_X10"
    fi

    max_cpu=0
    for tz in $TZ_CPU_LIST; do
        read_temp_x10_fast "$tz"
        [ "$TMP_T_X10" -gt "$max_cpu" ] && max_cpu="$TMP_T_X10"
    done
    TEMP_CPU_X10="$max_cpu"

    max_gpu=0
    for tz in $TZ_GPU_LIST; do
        read_temp_x10_fast "$tz"
        [ "$TMP_T_X10" -gt "$max_gpu" ] && max_gpu="$TMP_T_X10"
    done
    if [ "$max_gpu" -eq 0 ] && [ "$HAS_KGSL" -eq 1 ] && [ -r /sys/class/kgsl/kgsl-3d0/temp ]; then
        read_temp_x10_fast /sys/class/kgsl/kgsl-3d0/temp
        max_gpu="$TMP_T_X10"
    fi
    TEMP_GPU_X10="$max_gpu"
}

load_config() {
    PROFILE="balanced"
    CHARGE_ENABLED=1
    CHARGE_STOP_PCT=85
    CHARGE_RESUME_PCT=75
    CHARGE_LIMIT_MA=0
    if [ -n "$CONST_CURR_NODE" ]; then
        CHARGE_MODE="fcc"
    else
        CHARGE_MODE="suspend"
    fi
    FPS_MODE="smart120"
    FPS_PK_MODE="none"
    SCREEN_OFF_ENABLED=1
    SCREEN_OFF_DEBOUNCE=30
    SCREEN_OFF_DOZE=0
    THERMAL_GUARD_ENABLED=1
    THERMAL_WARN_C=42
    THERMAL_CRIT_C=45
    AUTO_GAME_ENABLED=1
    JOYOSE_DISABLED=0
    ZRAM_ENABLED=1
    ZRAM_SIZE_GB=6
    ZRAM_ALGO="lz4"
    GAME_AUTO_BYPASS=1
    GAME_BYPASS_MIN_PCT=20

    [ -f "$CONFIG_FILE" ] || return 0

    while IFS='=' read -r k v; do
        v=${v%"$CR"}
        case "$k" in
            PROFILE)
                case "$v" in stock|battery|balanced|performance|gaming) PROFILE="$v" ;; esac ;;
            CHARGE_ENABLED)
                case "$v" in 0|1) CHARGE_ENABLED="$v" ;; esac ;;
            CHARGE_STOP_PCT)
                is_uint "$v" && [ "$v" -ge 50 ] && [ "$v" -le 100 ] && CHARGE_STOP_PCT="$v" ;;
            CHARGE_RESUME_PCT)
                is_uint "$v" && [ "$v" -ge 40 ] && [ "$v" -le 90 ] && CHARGE_RESUME_PCT="$v" ;;
            CHARGE_LIMIT_MA)
                is_uint "$v" && [ "$v" -le 5000 ] && CHARGE_LIMIT_MA="$v" ;;
            CHARGE_MODE)
                case "$v" in fcc|suspend|night) CHARGE_MODE="$v" ;; esac ;;
            FPS_MODE)
                case "$v" in stock|smart120|force120) FPS_MODE="$v" ;; esac ;;
            FPS_PK_MODE)
                case "$v" in none|joyose|both) FPS_PK_MODE="$v" ;; esac ;;
            SCREEN_OFF_ENABLED)
                case "$v" in 0|1) SCREEN_OFF_ENABLED="$v" ;; esac ;;
            SCREEN_OFF_DEBOUNCE)
                is_uint "$v" && [ "$v" -ge 5 ] && [ "$v" -le 300 ] && SCREEN_OFF_DEBOUNCE="$v" ;;
            SCREEN_OFF_DOZE)
                case "$v" in 0|1) SCREEN_OFF_DOZE="$v" ;; esac ;;
            THERMAL_GUARD_ENABLED)
                case "$v" in 0|1) THERMAL_GUARD_ENABLED="$v" ;; esac ;;
            THERMAL_WARN_C)
                is_uint "$v" && [ "$v" -ge 38 ] && [ "$v" -le 46 ] && THERMAL_WARN_C="$v" ;;
            THERMAL_CRIT_C)
                is_uint "$v" && [ "$v" -ge 42 ] && [ "$v" -le 50 ] && THERMAL_CRIT_C="$v" ;;
            AUTO_GAME_ENABLED)
                case "$v" in 0|1) AUTO_GAME_ENABLED="$v" ;; esac ;;
            JOYOSE_DISABLED)
                case "$v" in 0|1) JOYOSE_DISABLED="$v" ;; esac ;;
            ZRAM_ENABLED)
                case "$v" in 0|1) ZRAM_ENABLED="$v" ;; esac ;;
            ZRAM_SIZE_GB)
                case "$v" in 0|4|6|8) ZRAM_SIZE_GB="$v" ;; esac ;;
            ZRAM_ALGO)
                case "$v" in lz4|zstd) ZRAM_ALGO="$v" ;; esac ;;
            GAME_AUTO_BYPASS)
                case "$v" in 0|1) GAME_AUTO_BYPASS="$v" ;; esac ;;
            GAME_BYPASS_MIN_PCT)
                is_uint "$v" && [ "$v" -ge 10 ] && [ "$v" -le 50 ] && GAME_BYPASS_MIN_PCT="$v" ;;
        esac
    done < "$CONFIG_FILE"

    if [ "$ZRAM_SIZE_GB" -eq 0 ]; then
        ZRAM_ENABLED=0
    fi

    if [ $((CHARGE_STOP_PCT - CHARGE_RESUME_PCT)) -lt 10 ]; then
        CHARGE_RESUME_PCT=$((CHARGE_STOP_PCT - 10))
        [ "$CHARGE_RESUME_PCT" -lt 40 ] && CHARGE_RESUME_PCT=40
    fi
}

save_config() {
    cfg="PROFILE=$PROFILE
CHARGE_ENABLED=$CHARGE_ENABLED
CHARGE_STOP_PCT=$CHARGE_STOP_PCT
CHARGE_RESUME_PCT=$CHARGE_RESUME_PCT
CHARGE_LIMIT_MA=$CHARGE_LIMIT_MA
CHARGE_MODE=$CHARGE_MODE
FPS_MODE=$FPS_MODE
FPS_PK_MODE=$FPS_PK_MODE
SCREEN_OFF_ENABLED=$SCREEN_OFF_ENABLED
SCREEN_OFF_DEBOUNCE=$SCREEN_OFF_DEBOUNCE
SCREEN_OFF_DOZE=$SCREEN_OFF_DOZE
THERMAL_GUARD_ENABLED=$THERMAL_GUARD_ENABLED
THERMAL_WARN_C=$THERMAL_WARN_C
THERMAL_CRIT_C=$THERMAL_CRIT_C
AUTO_GAME_ENABLED=$AUTO_GAME_ENABLED
JOYOSE_DISABLED=$JOYOSE_DISABLED
ZRAM_ENABLED=$ZRAM_ENABLED
ZRAM_SIZE_GB=$ZRAM_SIZE_GB
ZRAM_ALGO=$ZRAM_ALGO
GAME_AUTO_BYPASS=$GAME_AUTO_BYPASS
GAME_BYPASS_MIN_PCT=$GAME_BYPASS_MIN_PCT"
    atomic_write_file "$CONFIG_FILE" "$cfg"
}

ensure_default_games_list() {
    [ -f "$GAMES_FILE" ] && return 0
    defaults="com.garena.game.kgvn|max120
com.garena.game.kgvo|max120
com.vng.pubgmobile|max120
com.tencent.ig|max120
com.dts.freefiremax|max120
com.kurogame.wutheringwaves|cool60"
    atomic_write_file "$GAMES_FILE" "$defaults"
}

is_valid_pkg_name() {
    pkg="$1"
    case "$pkg" in
        ''|.*|*.) return 1 ;;
        -*|*-) return 1 ;;
        *.*) ;;
        *) return 1 ;;
    esac
    case "$pkg" in
        *[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_valid_game_profile() {
    case "$1" in
        max120|cool60|eco60) return 0 ;;
        *) return 1 ;;
    esac
}

get_game_profile() {
    _qpkg="$1"
    MATCHED_GAME_PROF="none"
    [ -n "$_qpkg" ] || return 1
    [ -f "$GAMES_FILE" ] || return 1
    while IFS= read -r _gl; do
        _gl=${_gl%"$CR"}
        [ -z "$_gl" ] && continue
        _gpkg=${_gl%%\|*}
        if [ "$_gpkg" = "$_qpkg" ]; then
            case "$_gl" in
                *\|*)
                    _gp=${_gl#*\|}
                    is_valid_game_profile "$_gp" || _gp="max120"
                    ;;
                *)
                    _gp="max120"
                    ;;
            esac
            MATCHED_GAME_PROF="$_gp"
            return 0
        fi
    done < "$GAMES_FILE"
    return 1
}

is_package_in_games_list() {
    get_game_profile "$1"
    return $?
}

get_foreground_package() {
    FG_PKG=""
    _line=$(dumpsys activity activities 2>/dev/null | grep -m 1 -E 'topResumedActivity|mResumedActivity')
    if [ -z "$_line" ]; then
        _line=$(dumpsys window displays 2>/dev/null | grep -m 1 -E 'mCurrentFocus|mFocusedApp')
    fi
    case "$_line" in
        *" u0 "*)
            _rest=${_line#* u0 }
            _pkg=${_rest%%/*}
            _pkg=${_pkg%% *}
            _pkg=${_pkg%%\}*}
            if is_valid_pkg_name "$_pkg"; then
                FG_PKG="$_pkg"
                return 0
            fi
            ;;
    esac
    return 1
}

get_default_fcc() {
    if [ -f "$SNAP_FILE" ]; then
        while IFS='=' read -r k v; do
            v=${v%"$CR"}
            if [ "$k" = "CONST_CHARGE_CURR" ] && is_uint "$v" && [ "$v" -ge 500000 ]; then
                printf '%s' "$v"
                return 0
            fi
        done < "$SNAP_FILE"
    fi
    printf '4250000'
}

get_default_gpu_cdev() {
    if [ -f "$SNAP_FILE" ]; then
        while IFS='=' read -r k v; do
            v=${v%"$CR"}
            if [ "$k" = "GPU_CDEV_ORIG" ] && is_uint "$v"; then
                printf '%s' "$v"
                return 0
            fi
        done < "$SNAP_FILE"
    fi
    if [ "$DEV_CODENAME" = "houji" ]; then
        printf '2'
        return 0
    fi
    printf ''
}

restore_gpu_cdev_floor() {
    [ -n "$GPU_CDEV_NODE" ] || return 0
    orig_cdev=$(get_default_gpu_cdev)
    is_uint "$orig_cdev" || return 0
    read_sysfs_fast "$GPU_CDEV_NODE" "0"
    cur_cdev="$SYSFS_VAL"
    if is_uint "$cur_cdev" && [ "$cur_cdev" -lt "$orig_cdev" ]; then
        write_sysfs "$GPU_CDEV_NODE" "$orig_cdev"
    fi
}

get_active_charge_node() {
    if [ "$CHARGE_MODE" = "fcc" ] && [ -n "$CONST_CURR_NODE" ]; then
        printf '%s' "$CONST_CURR_NODE"
    elif [ "$CHARGE_MODE" = "night" ] && [ -n "$CHARGE_NIGHT_NODE" ]; then
        printf '%s' "$CHARGE_NIGHT_NODE"
    else
        printf '%s' "$CHARGE_SUSPEND_NODE"
    fi
}

capture_defaults_snapshot() {
    [ -f "$SNAP_FILE" ] && return 0

    snap=""
    for pname in $CPU_POLICIES; do
        pdir="/sys/devices/system/cpu/cpufreq/$pname"
        read_sysfs_fast "$pdir/scaling_max_freq" ""
        smax="$SYSFS_VAL"
        if [ -z "$smax" ]; then
            read_sysfs_fast "$pdir/cpuinfo_max_freq" ""
            smax="$SYSFS_VAL"
        fi
        [ -n "$smax" ] && snap="${snap}CPU_${pname}_MAX=${smax}
"
    done

    if [ "$HAS_KGSL" -eq 1 ]; then
        read_sysfs_fast /sys/class/kgsl/kgsl-3d0/max_clock_mhz "770"
        gmhz="$SYSFS_VAL"
        read_sysfs_fast /sys/class/kgsl/kgsl-3d0/devfreq/max_freq "770000000"
        gdev="$SYSFS_VAL"
        snap="${snap}GPU_MAX_MHZ=${gmhz}
GPU_DEVFREQ_MAX=${gdev}
"
        if [ -n "$GPU_CDEV_NODE" ]; then
            read_sysfs_fast "$GPU_CDEV_NODE" "2"
            gcdev="$SYSFS_VAL"
            is_uint "$gcdev" || gcdev="2"
            snap="${snap}GPU_CDEV_ORIG=${gcdev}
"
        fi
    fi

    if [ -n "$CONST_CURR_NODE" ]; then
        read_sysfs_fast "$CONST_CURR_NODE" "4250000"
        ccur="$SYSFS_VAL"
        if ! is_uint "$ccur" || [ "$ccur" -lt 500000 ]; then
            ccur="4250000"
        fi
        snap="${snap}CONST_CHARGE_CURR=${ccur}
"
    fi

    sys_peak=$(settings get system peak_refresh_rate 2>/dev/null)
    sys_peak=${sys_peak%"$CR"}
    sys_min=$(settings get system min_refresh_rate 2>/dev/null)
    sys_min=${sys_min%"$CR"}
    sys_usr=$(settings get system user_refresh_rate 2>/dev/null)
    sys_usr=${sys_usr%"$CR"}
    sec_usr=$(settings get secure user_refresh_rate 2>/dev/null)
    sec_usr=${sec_usr%"$CR"}
    sec_miui=$(settings get secure miui_refresh_rate 2>/dev/null)
    sec_miui=${sec_miui%"$CR"}

    if [ "$sys_peak" = "60.0" ] && [ "$sys_min" = "60.0" ]; then
        sys_peak="120.0"
        sys_min="null"
    fi

    snap="${snap}SYS_PEAK_RR=${sys_peak:-null}
SYS_MIN_RR=${sys_min:-null}
SYS_USER_RR=${sys_usr:-null}
SEC_USER_RR=${sec_usr:-null}
SEC_MIUI_RR=${sec_miui:-null}"

    atomic_write_file "$SNAP_FILE" "$snap"
    log_msg "INFO" "Captured boot defaults snapshot to $SNAP_FILE"
}

apply_defaults_snapshot() {
    [ -f "$SNAP_FILE" ] || return 1
    while IFS='=' read -r k v; do
        v=${v%"$CR"}
        case "$k" in
            CPU_policy*_MAX)
                pname=${k#CPU_}
                pname=${pname%_MAX}
                pmax="/sys/devices/system/cpu/cpufreq/$pname/scaling_max_freq"
                is_uint "$v" && write_sysfs "$pmax" "$v"
                ;;
            GPU_MAX_MHZ)
                restore_gpu_cdev_floor
                is_uint "$v" && write_sysfs /sys/class/kgsl/kgsl-3d0/max_clock_mhz "$v"
                ;;
            GPU_DEVFREQ_MAX)
                is_uint "$v" && write_sysfs /sys/class/kgsl/kgsl-3d0/devfreq/max_freq "$v"
                ;;
            GPU_CDEV_ORIG)
                is_uint "$v" && [ -n "$GPU_CDEV_NODE" ] && write_sysfs "$GPU_CDEV_NODE" "$v"
                ;;
            CONST_CHARGE_CURR)
                is_uint "$v" && [ "$v" -ge 500000 ] && [ -n "$CONST_CURR_NODE" ] && write_sysfs "$CONST_CURR_NODE" "$v"
                ;;
            SYS_PEAK_RR)
                if [ "$v" = "null" ] || [ -z "$v" ]; then
                    settings delete system peak_refresh_rate >/dev/null 2>&1
                else
                    settings put system peak_refresh_rate "$v" >/dev/null 2>&1
                fi
                ;;
            SYS_MIN_RR)
                if [ "$v" = "null" ] || [ -z "$v" ]; then
                    settings delete system min_refresh_rate >/dev/null 2>&1
                else
                    settings put system min_refresh_rate "$v" >/dev/null 2>&1
                fi
                ;;
            SYS_USER_RR)
                if [ "$v" = "null" ] || [ -z "$v" ]; then
                    settings delete system user_refresh_rate >/dev/null 2>&1
                else
                    settings put system user_refresh_rate "$v" >/dev/null 2>&1
                fi
                ;;
            SEC_USER_RR)
                if [ "$v" = "null" ] || [ -z "$v" ]; then
                    settings delete secure user_refresh_rate >/dev/null 2>&1
                else
                    settings put secure user_refresh_rate "$v" >/dev/null 2>&1
                fi
                ;;
            SEC_MIUI_RR)
                if [ "$v" = "null" ] || [ -z "$v" ]; then
                    settings delete secure miui_refresh_rate >/dev/null 2>&1
                else
                    settings put secure miui_refresh_rate "$v" >/dev/null 2>&1
                fi
                ;;
        esac
    done < "$SNAP_FILE"
    refresh_display_cache
    return 0
}

pick_nearest_freq() {
    pdir="$1"
    target="$2"
    read_sysfs_fast "$pdir/scaling_available_frequencies" ""
    avail="$SYSFS_VAL"
    if [ -r "$pdir/scaling_boost_frequencies" ]; then
        read_sysfs_fast "$pdir/scaling_boost_frequencies" ""
        [ -n "$SYSFS_VAL" ] && avail="$avail $SYSFS_VAL"
    fi
    if [ -z "$avail" ]; then
        printf '%s' "$target"
        return 0
    fi
    best=0
    min_f=999999999
    for f in $avail; do
        is_uint "$f" || continue
        [ "$f" -lt "$min_f" ] && min_f="$f"
        if [ "$f" -le "$target" ] && [ "$f" -gt "$best" ]; then
            best="$f"
        fi
    done
    if [ "$best" -gt 0 ]; then
        printf '%s' "$best"
    elif [ "$min_f" -lt 999999999 ]; then
        printf '%s' "$min_f"
    else
        printf '%s' "$target"
    fi
}

pick_nearest_gpu_hz() {
    target_mhz="$1"
    target_hz=$((target_mhz * 1000000))
    read_sysfs_fast /sys/class/kgsl/kgsl-3d0/gpu_available_frequencies ""
    avail="$SYSFS_VAL"
    if [ -z "$avail" ]; then
        printf '%s' "$target_hz"
        return 0
    fi
    best=0
    min_f=9999999999
    for f in $avail; do
        is_uint "$f" || continue
        [ "$f" -lt "$min_f" ] && min_f="$f"
        if [ "$f" -le "$target_hz" ] && [ "$f" -gt "$best" ]; then
            best="$f"
        fi
    done
    if [ "$best" -gt 0 ]; then
        printf '%s' "$best"
    elif [ "$min_f" -lt 9999999999 ]; then
        printf '%s' "$min_f"
    else
        printf '%s' "$target_hz"
    fi
}

set_policy_max() {
    pname="$1"
    target="$2"
    pdir="/sys/devices/system/cpu/cpufreq/$pname"
    [ -d "$pdir" ] || return 0
    chosen=$(pick_nearest_freq "$pdir" "$target")
    read_sysfs_fast "$pdir/scaling_min_freq" "0"
    cur_min="$SYSFS_VAL"
    if is_uint "$cur_min" && [ "$cur_min" -gt "$chosen" ]; then
        read_sysfs_fast "$pdir/cpuinfo_min_freq" "0"
        cmin="$SYSFS_VAL"
        is_uint "$cmin" && write_sysfs "$pdir/scaling_min_freq" "$cmin"
    fi
    write_sysfs "$pdir/scaling_max_freq" "$chosen"
}

set_gpu_max_mhz() {
    [ "$HAS_KGSL" -eq 1 ] || return 0
    target_mhz="$1"
    hz=$(pick_nearest_gpu_hz "$target_mhz")
    mhz=$((hz / 1000000))
    write_sysfs /sys/class/kgsl/kgsl-3d0/max_clock_mhz "$mhz"
    write_sysfs /sys/class/kgsl/kgsl-3d0/devfreq/max_freq "$hz"
}

clear_cpu_nolimit() {
    [ -n "$CPU_NOLIMIT_NODE" ] || return 0
    read_sysfs_fast "$CPU_NOLIMIT_NODE" "0"
    if [ "$SYSFS_VAL" != "0" ]; then
        write_sysfs "$CPU_NOLIMIT_NODE" "0"
    fi
}

enforce_gaming_uncapped() {
    if [ -n "$CPU_NOLIMIT_NODE" ]; then
        read_sysfs_fast "$CPU_NOLIMIT_NODE" "0"
        [ "$SYSFS_VAL" != "45000" ] && write_sysfs "$CPU_NOLIMIT_NODE" "45000"
    fi
    if [ -n "$GPU_CDEV_NODE" ]; then
        read_sysfs_fast "$GPU_CDEV_NODE" "0"
        [ "$SYSFS_VAL" != "0" ] && write_sysfs "$GPU_CDEV_NODE" "0"
    fi
    if [ "$HAS_KGSL" -eq 1 ]; then
        read_sysfs_fast /sys/class/kgsl/kgsl-3d0/max_pwrlevel "0"
        [ "$SYSFS_VAL" != "0" ] && write_sysfs /sys/class/kgsl/kgsl-3d0/max_pwrlevel "0"
        read_sysfs_fast /sys/class/kgsl/kgsl-3d0/max_clock_mhz "0"
        [ "$SYSFS_VAL" != "903" ] && set_gpu_max_mhz 903
    fi
    if [ -n "$CPU_C3_CDEV_NODE" ]; then
        read_sysfs_fast "$CPU_C3_CDEV_NODE" "0"
        [ "$SYSFS_VAL" != "0" ] && write_sysfs "$CPU_C3_CDEV_NODE" "0"
    fi
    if [ -n "$DISP_FPS_CDEV_NODE" ]; then
        read_sysfs_fast "$DISP_FPS_CDEV_NODE" "0"
        [ "$SYSFS_VAL" != "0" ] && write_sysfs "$DISP_FPS_CDEV_NODE" "0"
    fi
    for pname in $CPU_POLICIES; do
        pdir="/sys/devices/system/cpu/cpufreq/$pname"
        [ -d "$pdir" ] || continue
        read_sysfs_fast "$pdir/cpuinfo_max_freq" ""
        cmax="$SYSFS_VAL"
        is_uint "$cmax" || continue
        read_sysfs_fast "$pdir/scaling_max_freq" "0"
        [ "$SYSFS_VAL" != "$cmax" ] && set_policy_max "$pname" "$cmax"
    done
}

enforce_game_cool60() {
    if [ -n "$CPU_NOLIMIT_NODE" ]; then
        read_sysfs_fast "$CPU_NOLIMIT_NODE" "0"
        [ "$SYSFS_VAL" != "43000" ] && write_sysfs "$CPU_NOLIMIT_NODE" "43000"
    fi
    if [ -n "$DISP_FPS_CDEV_NODE" ]; then
        read_sysfs_fast "$DISP_FPS_CDEV_NODE" "0"
        [ "$SYSFS_VAL" != "0" ] && write_sysfs "$DISP_FPS_CDEV_NODE" "0"
    fi
    restore_gpu_cdev_floor
    for pname in $CPU_POLICIES; do
        read_sysfs_fast "/sys/devices/system/cpu/cpufreq/$pname/cpuinfo_max_freq" "2630400"
        cmax="$SYSFS_VAL"
        if [ "$pname" = "$LITTLE_POLICY" ]; then
            set_policy_max "$pname" "$cmax"
        else
            set_policy_max "$pname" 2630400
        fi
    done
    set_gpu_max_mhz 720
}

enforce_game_eco60() {
    clear_cpu_nolimit
    restore_gpu_cdev_floor
    for pname in $CPU_POLICIES; do
        read_sysfs_fast "/sys/devices/system/cpu/cpufreq/$pname/cpuinfo_max_freq" "1920000"
        cmax="$SYSFS_VAL"
        if [ "$pname" = "$LITTLE_POLICY" ]; then
            set_policy_max "$pname" "$cmax"
        elif [ "$pname" = "policy7" ]; then
            set_policy_max "$pname" 1824000
        else
            set_policy_max "$pname" 1920000
        fi
    done
    set_gpu_max_mhz 422
}

apply_game_profile_full() {
    _gprof="$1"
    _tstate="${2:-normal}"
    if [ "$_tstate" = "critical" ]; then
        apply_fps_settings "lock60" "keep"
        apply_cpu_gpu_profile "thermal_crit"
        return 0
    fi
    case "$_gprof" in
        cool60)
            apply_fps_settings "gaming120" "keep"
            enforce_game_cool60
            if [ "$_tstate" = "warn" ]; then
                clear_cpu_nolimit
                set_gpu_max_mhz 629
            fi
            ;;
        eco60)
            apply_fps_settings "lock60" "keep"
            enforce_game_eco60
            ;;
        *)
            apply_fps_settings "gaming120" "keep"
            enforce_gaming_uncapped
            if [ "$_tstate" = "warn" ]; then
                restore_gpu_cdev_floor
                set_gpu_max_mhz 770
            fi
            ;;
    esac
}

apply_cpu_gpu_profile() {
    mode="$1"
    case "$mode" in
        stock)
            clear_cpu_nolimit
            restore_gpu_cdev_floor
            if [ -f "$SNAP_FILE" ]; then
                while IFS='=' read -r k v; do
                    v=${v%"$CR"}
                    case "$k" in
                        CPU_policy*_MAX)
                            pname=${k#CPU_}
                            pname=${pname%_MAX}
                            is_uint "$v" && write_sysfs "/sys/devices/system/cpu/cpufreq/$pname/scaling_max_freq" "$v"
                            ;;
                        GPU_MAX_MHZ)
                            is_uint "$v" && write_sysfs /sys/class/kgsl/kgsl-3d0/max_clock_mhz "$v"
                            ;;
                        GPU_DEVFREQ_MAX)
                            is_uint "$v" && write_sysfs /sys/class/kgsl/kgsl-3d0/devfreq/max_freq "$v"
                            ;;
                    esac
                done < "$SNAP_FILE"
            else
                for pname in $CPU_POLICIES; do
                    read_sysfs_fast "/sys/devices/system/cpu/cpufreq/$pname/cpuinfo_max_freq" ""
                    [ -n "$SYSFS_VAL" ] && set_policy_max "$pname" "$SYSFS_VAL"
                done
                set_gpu_max_mhz 770
            fi
            ;;
        balanced)
            clear_cpu_nolimit
            restore_gpu_cdev_floor
            for pname in $CPU_POLICIES; do
                read_sysfs_fast "/sys/devices/system/cpu/cpufreq/$pname/cpuinfo_max_freq" "2630400"
                cmax="$SYSFS_VAL"
                if [ "$pname" = "$LITTLE_POLICY" ]; then
                    set_policy_max "$pname" "$cmax"
                else
                    set_policy_max "$pname" 2630400
                fi
            done
            set_gpu_max_mhz 680
            ;;
        battery)
            clear_cpu_nolimit
            restore_gpu_cdev_floor
            for pname in $CPU_POLICIES; do
                read_sysfs_fast "/sys/devices/system/cpu/cpufreq/$pname/cpuinfo_max_freq" "1920000"
                cmax="$SYSFS_VAL"
                if [ "$pname" = "$LITTLE_POLICY" ]; then
                    set_policy_max "$pname" "$cmax"
                elif [ "$pname" = "policy7" ]; then
                    set_policy_max "$pname" 1824000
                else
                    set_policy_max "$pname" 1920000
                fi
            done
            set_gpu_max_mhz 500
            ;;
        performance)
            clear_cpu_nolimit
            for pname in $CPU_POLICIES; do
                read_sysfs_fast "/sys/devices/system/cpu/cpufreq/$pname/cpuinfo_max_freq" "3302400"
                set_policy_max "$pname" "$SYSFS_VAL"
            done
            [ -n "$GPU_CDEV_NODE" ] && write_sysfs "$GPU_CDEV_NODE" "0"
            [ "$HAS_KGSL" -eq 1 ] && write_sysfs /sys/class/kgsl/kgsl-3d0/max_pwrlevel "0"
            set_gpu_max_mhz 903
            ;;
        gaming)
            enforce_gaming_uncapped
            ;;
        game_cool60)
            enforce_game_cool60
            ;;
        game_eco60)
            enforce_game_eco60
            ;;
        screen_off)
            # NEVER restrict LITTLE_POLICY (policy0) to preserve race-to-idle efficiency
            clear_cpu_nolimit
            restore_gpu_cdev_floor
            for pname in $BIG_POLICIES; do
                if [ "$pname" = "policy7" ]; then
                    set_policy_max "$pname" 1017600
                else
                    set_policy_max "$pname" 1286400
                fi
            done
            set_gpu_max_mhz 366
            ;;
        thermal_crit)
            clear_cpu_nolimit
            restore_gpu_cdev_floor
            for pname in $BIG_POLICIES; do
                if [ "$pname" = "policy7" ]; then
                    set_policy_max "$pname" 1363200
                else
                    set_policy_max "$pname" 1612800
                fi
            done
            set_gpu_max_mhz 422
            ;;
    esac
}

is_screen_on() {
    if [ -n "$BACKLIGHT_NODE" ] && [ -r "$BACKLIGHT_NODE" ]; then
        read_sysfs_fast "$BACKLIGHT_NODE" ""
        bl="$SYSFS_VAL"
        if is_uint "$bl"; then
            [ "$bl" -gt 0 ] && return 0 || return 1
        fi
    fi
    if [ -n "$SCREEN_STATE_NODE" ] && [ -r "$SCREEN_STATE_NODE" ]; then
        read_sysfs_fast "$SCREEN_STATE_NODE" ""
        ss="$SYSFS_VAL"
        if is_uint "$ss"; then
            [ "$ss" -eq 1 ] && return 0 || return 1
        fi
    fi
    dumpsys power 2>/dev/null | grep -q 'mWakefulness=Awake'
    return $?
}

is_screen_truly_off() {
    if is_screen_on; then
        return 1
    fi
    wake=$(dumpsys power 2>/dev/null | grep -m 1 'mWakefulness=')
    case "$wake" in
        *Awake*) return 1 ;;
        *) return 0 ;;
    esac
}

is_charging_paused() {
    if [ "$CHARGE_MODE" = "fcc" ] && [ -n "$CONST_CURR_NODE" ]; then
        read_sysfs_fast "$CONST_CURR_NODE" "1"
        [ "$SYSFS_VAL" = "0" ] && return 0
    fi
    if [ "$CHARGE_MODE" = "night" ] && [ -n "$CHARGE_NIGHT_NODE" ]; then
        read_sysfs_fast "$CHARGE_NIGHT_NODE" "0"
        [ "$SYSFS_VAL" = "1" ] && return 0
    fi
    if [ -n "$CHARGE_SUSPEND_NODE" ]; then
        read_sysfs_fast "$CHARGE_SUSPEND_NODE" ""
        [ "$SYSFS_VAL" = "$CHARGE_SUSPEND_ON" ] && return 0
    fi
    return 1
}

get_charging_current_ma() {
    CURR_MA=0
    read_sysfs_fast /sys/class/power_supply/battery/current_now "0"
    if is_int "$SYSFS_VAL"; then
        if [ "$HAS_QCOM_BATT" -eq 1 ]; then
            CURR_MA=$((-SYSFS_VAL / 1000))
        else
            CURR_MA=$((SYSFS_VAL / 1000))
        fi
    fi
}

pulse_sleep_350ms() {
    if [ -n "$BUSYBOX" ]; then
        "$BUSYBOX" usleep 350000 2>/dev/null || sleep 1
    else
        sleep 0.35 2>/dev/null || sleep 1
    fi
}

engage_fcc_bypass() {
    if [ -n "$CONST_CURR_NODE" ] && [ -w "$CONST_CURR_NODE" ]; then
        [ -n "$CHARGE_NIGHT_NODE" ] && write_sysfs "$CHARGE_NIGHT_NODE" "0"
        [ -n "$CHARGE_SUSPEND_NODE" ] && write_sysfs "$CHARGE_SUSPEND_NODE" "$CHARGE_SUSPEND_OFF"
        write_sysfs "$CONST_CURR_NODE" "0"
        return $?
    fi
    if [ -n "$CHARGE_SUSPEND_NODE" ]; then
        write_sysfs "$CHARGE_SUSPEND_NODE" "$CHARGE_SUSPEND_ON"
        return $?
    fi
    return 1
}

set_charging_paused() {
    pause="$1"
    if [ "$pause" = "1" ]; then
        if [ "$CHARGE_MODE" = "fcc" ] && [ -n "$CONST_CURR_NODE" ] && [ -w "$CONST_CURR_NODE" ]; then
            [ -n "$CHARGE_NIGHT_NODE" ] && write_sysfs "$CHARGE_NIGHT_NODE" "0"
            [ -n "$CHARGE_SUSPEND_NODE" ] && write_sysfs "$CHARGE_SUSPEND_NODE" "$CHARGE_SUSPEND_OFF"
            write_sysfs "$CONST_CURR_NODE" "0"
            return $?
        fi
        if [ "$CHARGE_MODE" = "night" ] && [ -n "$CHARGE_NIGHT_NODE" ] && [ -w "$CHARGE_NIGHT_NODE" ]; then
            write_sysfs "$CHARGE_NIGHT_NODE" "1" && return 0
        fi
        if [ -n "$CHARGE_SUSPEND_NODE" ]; then
            write_sysfs "$CHARGE_SUSPEND_NODE" "$CHARGE_SUSPEND_ON"
            return $?
        fi
    else
        was_fcc_zero=0
        if [ -n "$CONST_CURR_NODE" ] && [ -r "$CONST_CURR_NODE" ]; then
            read_sysfs_fast "$CONST_CURR_NODE" ""
            [ "$SYSFS_VAL" = "0" ] && was_fcc_zero=1
        fi
        [ "$was_fcc_zero" -eq 0 ] && [ -n "$CHARGE_NIGHT_NODE" ] && write_sysfs "$CHARGE_NIGHT_NODE" "0"
        [ -n "$CHARGE_SUSPEND_NODE" ] && write_sysfs "$CHARGE_SUSPEND_NODE" "$CHARGE_SUSPEND_OFF"
        if [ -n "$CONST_CURR_NODE" ] && [ -w "$CONST_CURR_NODE" ]; then
            if [ "$CHARGE_ENABLED" -eq 1 ] && [ "$CHARGE_LIMIT_MA" -gt 0 ]; then
                target_ua=$((CHARGE_LIMIT_MA * 1000))
            else
                target_ua=$(get_default_fcc)
            fi
            write_sysfs "$CONST_CURR_NODE" "$target_ua"
            rc=$?
            if [ "$was_fcc_zero" -eq 1 ]; then
                read_sysfs_fast /sys/class/power_supply/usb/online "0"
                u_on="$SYSFS_VAL"
                read_sysfs_fast /sys/class/power_supply/wireless/online "0"
                w_on="$SYSFS_VAL"
                if [ "$u_on" = "1" ] || [ "$w_on" = "1" ]; then
                    if [ -n "$CHARGE_NIGHT_NODE" ] && [ -w "$CHARGE_NIGHT_NODE" ]; then
                        # PPS-safe EOC latch reset: keeps VBUS & Xiaomi 90W HyperCharge PD_PPS intact
                        write_sysfs "$CHARGE_NIGHT_NODE" "1"
                        pulse_sleep_350ms
                        write_sysfs "$CHARGE_NIGHT_NODE" "0"
                        log_msg "INFO" "Smart Charge: emitted 350ms PPS-safe EOC reset pulse on $CHARGE_NIGHT_NODE"
                    elif [ -n "$CHARGE_SUSPEND_NODE" ] && [ -w "$CHARGE_SUSPEND_NODE" ]; then
                        # Fallback for non-Xiaomi devices without night_charging
                        write_sysfs "$CHARGE_SUSPEND_NODE" "$CHARGE_SUSPEND_ON"
                        pulse_sleep_350ms
                        write_sysfs "$CHARGE_SUSPEND_NODE" "$CHARGE_SUSPEND_OFF"
                        log_msg "INFO" "Smart Charge: emitted 350ms fallback EOC reset pulse on $CHARGE_SUSPEND_NODE"
                    fi
                else
                    [ -n "$CHARGE_NIGHT_NODE" ] && write_sysfs "$CHARGE_NIGHT_NODE" "0"
                fi
            fi
            return $rc
        fi
        return 0
    fi
    return 1
}

apply_charge_current_limit() {
    ma="$1"
    is_uint "$ma" || return 1
    if [ "$ma" -eq 0 ]; then
        [ -n "$RESTRICT_CHG_NODE" ] && write_sysfs "$RESTRICT_CHG_NODE" "0"
        [ -n "$RESTRICT_CUR_NODE" ] && write_sysfs "$RESTRICT_CUR_NODE" "1000000"
        if [ -n "$CONST_CURR_NODE" ]; then
            read_sysfs_fast "$CONST_CURR_NODE" ""
            if [ "$SYSFS_VAL" != "0" ]; then
                orig_cc=$(get_default_fcc)
                [ "$SYSFS_VAL" != "$orig_cc" ] && write_sysfs "$CONST_CURR_NODE" "$orig_cc"
            fi
        fi
    else
        ua=$((ma * 1000))
        if [ -n "$RESTRICT_CUR_NODE" ] && [ -n "$RESTRICT_CHG_NODE" ]; then
            write_sysfs "$RESTRICT_CUR_NODE" "$ua"
            write_sysfs "$RESTRICT_CHG_NODE" "1"
        fi
        if [ -n "$CONST_CURR_NODE" ]; then
            read_sysfs_fast "$CONST_CURR_NODE" ""
            if [ "$SYSFS_VAL" != "0" ] && [ "$SYSFS_VAL" != "$ua" ]; then
                write_sysfs "$CONST_CURR_NODE" "$ua"
            fi
        fi
    fi
}

apply_joyose_state() {
    if [ "$JOYOSE_DISABLED" -eq 1 ]; then
        pm disable-user --user 0 com.xiaomi.joyose >/dev/null 2>&1
    else
        pm enable com.xiaomi.joyose >/dev/null 2>&1
    fi
}

restore_hyperos_fps_apps() {
    pm enable com.xiaomi.joyose >/dev/null 2>&1
    pm enable com.miui.powerkeeper >/dev/null 2>&1
}

apply_fps_settings() {
    mode="$1"
    pk_mode="${2:-none}"

    case "$mode" in
        stock)
            if [ "$pk_mode" != "keep" ]; then
                pm enable com.miui.powerkeeper >/dev/null 2>&1
                apply_joyose_state
            fi
            resetprop debug.graphics.game_default_frame_rate.disabled false >/dev/null 2>&1
            if [ -f "$SNAP_FILE" ]; then
                while IFS='=' read -r k v; do
                    v=${v%"$CR"}
                    case "$k" in
                        SYS_PEAK_RR)
                            [ "$v" = "null" ] && settings delete system peak_refresh_rate >/dev/null 2>&1 || settings put system peak_refresh_rate "$v" >/dev/null 2>&1 ;;
                        SYS_MIN_RR)
                            [ "$v" = "null" ] && settings delete system min_refresh_rate >/dev/null 2>&1 || settings put system min_refresh_rate "$v" >/dev/null 2>&1 ;;
                        SYS_USER_RR)
                            [ "$v" = "null" ] && settings delete system user_refresh_rate >/dev/null 2>&1 || settings put system user_refresh_rate "$v" >/dev/null 2>&1 ;;
                        SEC_USER_RR)
                            [ "$v" = "null" ] && settings delete secure user_refresh_rate >/dev/null 2>&1 || settings put secure user_refresh_rate "$v" >/dev/null 2>&1 ;;
                        SEC_MIUI_RR)
                            [ "$v" = "null" ] && settings delete secure miui_refresh_rate >/dev/null 2>&1 || settings put secure miui_refresh_rate "$v" >/dev/null 2>&1 ;;
                    esac
                done < "$SNAP_FILE"
            else
                settings delete system min_refresh_rate >/dev/null 2>&1
                settings delete system peak_refresh_rate >/dev/null 2>&1
                settings put system user_refresh_rate 120 >/dev/null 2>&1
                settings put secure miui_refresh_rate 120 >/dev/null 2>&1
            fi
            ;;
        smart120)
            # Safe 120Hz: NEVER run pm enable/disable repeatedly during Auto Game Mode transitions
            if [ "$pk_mode" != "keep" ]; then
                pm enable com.miui.powerkeeper >/dev/null 2>&1
                apply_joyose_state
            fi
            resetprop debug.graphics.game_default_frame_rate.disabled true >/dev/null 2>&1
            settings delete system min_refresh_rate >/dev/null 2>&1
            settings put system peak_refresh_rate 120.0 >/dev/null 2>&1
            settings put system user_refresh_rate 120 >/dev/null 2>&1
            settings put secure user_refresh_rate 120 >/dev/null 2>&1
            settings put secure miui_refresh_rate 120 >/dev/null 2>&1
            ;;
        gaming120)
            # Locked 120Hz for Gaming/Uncapped without touching pm enable/disable
            resetprop debug.graphics.game_default_frame_rate.disabled true >/dev/null 2>&1
            settings put system peak_refresh_rate 120.0 >/dev/null 2>&1
            settings put system min_refresh_rate 120.0 >/dev/null 2>&1
            settings put system user_refresh_rate 120 >/dev/null 2>&1
            settings put secure user_refresh_rate 120 >/dev/null 2>&1
            settings put secure miui_refresh_rate 120 >/dev/null 2>&1
            ;;
        force120)
            resetprop debug.graphics.game_default_frame_rate.disabled true >/dev/null 2>&1
            settings put system peak_refresh_rate 120.0 >/dev/null 2>&1
            settings put system min_refresh_rate 120.0 >/dev/null 2>&1
            settings put system user_refresh_rate 120 >/dev/null 2>&1
            settings put secure user_refresh_rate 120 >/dev/null 2>&1
            settings put secure miui_refresh_rate 120 >/dev/null 2>&1
            if [ "$pk_mode" != "keep" ]; then
                case "$pk_mode" in
                    joyose)
                        JOYOSE_DISABLED=1
                        pm disable-user --user 0 com.xiaomi.joyose >/dev/null 2>&1
                        pm enable com.miui.powerkeeper >/dev/null 2>&1
                        ;;
                    both)
                        JOYOSE_DISABLED=1
                        pm disable-user --user 0 com.xiaomi.joyose >/dev/null 2>&1
                        pm disable-user --user 0 com.miui.powerkeeper >/dev/null 2>&1
                        ;;
                    *)
                        pm enable com.miui.powerkeeper >/dev/null 2>&1
                        apply_joyose_state
                        ;;
                esac
            fi
            ;;
        lock60)
            settings put system peak_refresh_rate 60.0 >/dev/null 2>&1
            settings put system min_refresh_rate 60.0 >/dev/null 2>&1
            settings put system user_refresh_rate 60 >/dev/null 2>&1
            settings put secure user_refresh_rate 60 >/dev/null 2>&1
            settings put secure miui_refresh_rate 60 >/dev/null 2>&1
            ;;
    esac
    refresh_display_cache
}

zram_size_gb_to_bytes() {
    case "$1" in
        4) printf '4294967296' ;;
        6) printf '6442450944' ;;
        8) printf '8589934592' ;;
        *) printf '0' ;;
    esac
}

# 32-bit overflow-safe decimal-prefix conversion from bytes to KB/MB (zero forks)
bytes_to_mb_fast() {
    _b="$1"
    BYTES_KB=0
    BYTES_MB=0
    is_uint "$_b" || return 1
    case "$_b" in
        ''|?|??|???) return 0 ;;
    esac
    _k=${_b%???}
    case "$_k" in
        ????????*)
            _k10=${_k%?}
            BYTES_KB=$(( (_k10 * 625) / 64 ))
            BYTES_MB=$(( (_k10 * 625 + 32768) / 65536 ))
            ;;
        *)
            BYTES_KB=$(( (_k * 125) / 128 ))
            BYTES_MB=$(( (_k * 125 + 65536) / 131072 ))
            ;;
    esac
    return 0
}

is_zram_swapon() {
    [ -r /proc/swaps ] || return 1
    while read -r _sdev _srest; do
        case "$_sdev" in
            /dev/block/zram0|/dev/zram0) return 0 ;;
        esac
    done < /proc/swaps
    return 1
}

get_zram_active_algo() {
    ZRAM_CUR_ALGO="none"
    read_sysfs_fast /sys/block/zram0/comp_algorithm "" || return 1
    case "$SYSFS_VAL" in
        *'['*']'*)
            _r=${SYSFS_VAL#*\[}
            ZRAM_CUR_ALGO=${_r%%\]*}
            ;;
    esac
    return 0
}

zram_algo_supported() {
    _want="$1"
    [ -n "$_want" ] || return 1
    read_sysfs_fast /sys/block/zram0/comp_algorithm "" || return 1
    case " $SYSFS_VAL " in
        *" $_want "*|*" [$_want] "*) return 0 ;;
    esac
    return 1
}

get_mem_available_kb() {
    MEM_AVAIL_KB=0
    [ -r /proc/meminfo ] || return 1
    while read -r _mk _mv _mu; do
        if [ "$_mk" = "MemAvailable:" ] && is_uint "$_mv"; then
            MEM_AVAIL_KB="$_mv"
            return 0
        fi
    done < /proc/meminfo
    return 1
}

read_zram_stats() {
    ZRAM_ACTIVE=0
    ZRAM_CUR_ALGO="none"
    ZRAM_DISK_BYTES="0"
    ZRAM_DISK_MB=0
    ZRAM_ORIG_KB=0
    ZRAM_ORIG_MB=0
    ZRAM_COMPR_MB=0
    ZRAM_MEM_KB=0
    ZRAM_MEM_MB=0
    ZRAM_RATIO_X100=0
    ZRAM_BACKING_DEV="none"

    [ "$HAS_ZRAM" -eq 1 ] || return 0
    is_zram_swapon && ZRAM_ACTIVE=1
    get_zram_active_algo

    read_sysfs_fast /sys/block/zram0/disksize "0"
    is_uint "$SYSFS_VAL" && ZRAM_DISK_BYTES="$SYSFS_VAL" || ZRAM_DISK_BYTES="0"
    bytes_to_mb_fast "$ZRAM_DISK_BYTES"
    ZRAM_DISK_MB="$BYTES_MB"

    if [ -r /sys/block/zram0/backing_dev ]; then
        _bdev=""
        read -r _bdev < /sys/block/zram0/backing_dev 2>/dev/null
        _bdev=${_bdev%"$CR"}
        case "$_bdev" in
            ''|none) ZRAM_BACKING_DEV="none" ;;
            *) ZRAM_BACKING_DEV="$_bdev" ;;
        esac
    fi

    if [ -r /sys/block/zram0/mm_stat ]; then
        _orig=""
        _compr=""
        _mem=""
        _rest=""
        read -r _orig _compr _mem _rest < /sys/block/zram0/mm_stat 2>/dev/null
        bytes_to_mb_fast "$_orig"
        ZRAM_ORIG_KB="$BYTES_KB"
        ZRAM_ORIG_MB="$BYTES_MB"
        bytes_to_mb_fast "$_compr"
        ZRAM_COMPR_MB="$BYTES_MB"
        bytes_to_mb_fast "$_mem"
        ZRAM_MEM_KB="$BYTES_KB"
        ZRAM_MEM_MB="$BYTES_MB"
        if [ "$ZRAM_MEM_KB" -gt 0 ] && [ "$ZRAM_ORIG_KB" -gt 0 ]; then
            if [ "$ZRAM_ORIG_KB" -lt 20000000 ]; then
                ZRAM_RATIO_X100=$(( (ZRAM_ORIG_KB * 100) / ZRAM_MEM_KB ))
            elif [ "$ZRAM_MEM_MB" -gt 0 ]; then
                ZRAM_RATIO_X100=$(( (ZRAM_ORIG_MB * 100) / ZRAM_MEM_MB ))
            fi
        fi
    fi
    return 0
}

can_safely_swapoff_zram() {
    get_mem_available_kb || return 1
    _need=$((ZRAM_ORIG_KB - ZRAM_MEM_KB + 262144))
    [ "$_need" -lt 131072 ] && _need=131072
    [ "$MEM_AVAIL_KB" -ge "$_need" ]
    return $?
}

apply_zram_config() {
    [ "$HAS_ZRAM" -eq 1 ] || return 0
    read_zram_stats

    if [ "$ZRAM_ENABLED" -eq 0 ] || [ "$ZRAM_SIZE_GB" -eq 0 ]; then
        if [ "$ZRAM_ACTIVE" -eq 1 ]; then
            if ! can_safely_swapoff_zram; then
                log_msg "WARN" "ZRAM disable aborted: insufficient free RAM (avail=${MEM_AVAIL_KB}kB orig=${ZRAM_ORIG_KB}kB)"
                return 2
            fi
            /system/bin/swapoff /dev/block/zram0 2>/dev/null || swapoff /dev/block/zram0 2>/dev/null || {
                log_msg "WARN" "ZRAM swapoff failed"
                return 1
            }
        fi
        write_sysfs /sys/block/zram0/reset 1
        write_sysfs /proc/sys/vm/swappiness 60
        log_msg "INFO" "ZRAM disabled (pure-RAM teardown, vm.swappiness=60)"
        return 0
    fi

    _target_bytes=$(zram_size_gb_to_bytes "$ZRAM_SIZE_GB")
    [ "$_target_bytes" != "0" ] || return 1

    _target_algo="$ZRAM_ALGO"
    if ! zram_algo_supported "$_target_algo"; then
        if zram_algo_supported "lz4"; then
            _target_algo="lz4"
        else
            _target_algo="$ZRAM_CUR_ALGO"
        fi
    fi

    if [ "$ZRAM_ACTIVE" -eq 1 ] && [ "$ZRAM_DISK_BYTES" = "$_target_bytes" ] && [ "$ZRAM_CUR_ALGO" = "$_target_algo" ]; then
        _need_pure_reinit=0
        if [ -n "$ZRAM_BACKING_DEV" ] && [ "$ZRAM_BACKING_DEV" != "none" ] && [ "$ZRAM_ORIG_KB" -lt 262144 ]; then
            can_safely_swapoff_zram && _need_pure_reinit=1
        fi
        if [ "$_need_pure_reinit" -eq 0 ]; then
            write_sysfs /proc/sys/vm/page-cluster 0
            write_sysfs /proc/sys/vm/swappiness 100
            log_msg "INFO" "ZRAM already matches target (${ZRAM_SIZE_GB}GB ${_target_algo}, backing=${ZRAM_BACKING_DEV}); ensured vm.page-cluster=0 vm.swappiness=100"
            return 0
        fi
    fi

    if [ "$ZRAM_ACTIVE" -eq 1 ]; then
        if ! can_safely_swapoff_zram; then
            log_msg "WARN" "ZRAM reconfigure aborted: insufficient free RAM (avail=${MEM_AVAIL_KB}kB orig=${ZRAM_ORIG_KB}kB)"
            return 2
        fi
        /system/bin/swapoff /dev/block/zram0 2>/dev/null || swapoff /dev/block/zram0 2>/dev/null || {
            log_msg "WARN" "ZRAM swapoff failed"
            return 1
        }
    fi

    write_sysfs /sys/block/zram0/reset 1
    if [ -n "$_target_algo" ] && [ "$_target_algo" != "none" ]; then
        write_sysfs /sys/block/zram0/comp_algorithm "$_target_algo"
    fi
    write_sysfs /sys/block/zram0/disksize "$_target_bytes" || {
        log_msg "WARN" "ZRAM failed to set disksize=$_target_bytes"
        return 1
    }
    /system/bin/mkswap /dev/block/zram0 >/dev/null 2>&1 || mkswap /dev/block/zram0 >/dev/null 2>&1 || {
        log_msg "WARN" "ZRAM mkswap failed"
        return 1
    }
    /system/bin/swapon -p 32758 /dev/block/zram0 >/dev/null 2>&1 || /system/bin/swapon /dev/block/zram0 >/dev/null 2>&1 || swapon /dev/block/zram0 >/dev/null 2>&1 || {
        log_msg "WARN" "ZRAM swapon failed"
        return 1
    }
    write_sysfs /proc/sys/vm/page-cluster 0
    write_sysfs /proc/sys/vm/swappiness 100
    log_msg "INFO" "ZRAM configured: pure-RAM ${ZRAM_SIZE_GB}GB algo=${_target_algo} prio=32758 page-cluster=0 swappiness=100"
    return 0
}

unforce_doze_if_needed() {
    if [ -f "$DOZE_FORCED_FLAG" ]; then
        rm -f "$DOZE_FORCED_FLAG"
        if [ "$1" = "async" ]; then
            dumpsys deviceidle unforce >/dev/null 2>&1 &
        else
            dumpsys deviceidle unforce >/dev/null 2>&1
        fi
        log_msg "INFO" "Screen-Off Doze: unforced deviceidle"
    fi
}

get_uptime_sec_fast() {
    UP_SEC=0
    if [ -r /proc/uptime ]; then
        _up_raw=""
        _up_idle=""
        read -r _up_raw _up_idle < /proc/uptime 2>/dev/null
        _up_s=${_up_raw%%.*}
        is_uint "$_up_s" && UP_SEC="$_up_s"
    fi
}
