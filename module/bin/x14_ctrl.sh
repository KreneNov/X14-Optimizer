#!/system/bin/sh
# x14_ctrl.sh - Ultra-fast (<150ms) Whitelisted CLI Gateway for KSU WebUI & action.sh

SCRIPT_DIR=${0%/*}
[ "$SCRIPT_DIR" = "$0" ] && SCRIPT_DIR='.'
case "$SCRIPT_DIR" in
    /*) ;;
    *) SCRIPT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR" 2>/dev/null && pwd) ;;
esac
MODDIR=${SCRIPT_DIR%/*}

. "$MODDIR/bin/x14_common.sh"

init_env
load_or_build_hw_cache
load_config

json_err() {
    printf '{"ok":false,"error":"%s"}\n' "$1"
    exit 1
}

uint_or_zero() {
    is_uint "$1" && printf '%s' "$1" || printf '0'
}

int_or_zero() {
    is_int "$1" && printf '%s' "$1" || printf '0'
}

signal_daemon() {
    if [ -f "$DAEMON_PID_FILE" ]; then
        read_sysfs_fast "$DAEMON_PID_FILE" ""
        dpid="$SYSFS_VAL"
        if is_uint "$dpid" && kill -0 "$dpid" 2>/dev/null; then
            kill -USR1 "$dpid" 2>/dev/null
        fi
    fi
}

print_config_json() {
    printf '{"ok":true,"config":{"profile":"%s","charge_enabled":%s,"charge_stop_pct":%s,"charge_resume_pct":%s,"charge_limit_ma":%s,"charge_mode":"%s","fps_mode":"%s","fps_pk_mode":"%s","screen_off_enabled":%s,"screen_off_debounce":%s,"screen_off_doze":%s,"thermal_guard_enabled":%s,"thermal_warn_c":%s,"thermal_crit_c":%s,"auto_game_enabled":%s,"joyose_disabled":%s,"zram_enabled":%s,"zram_size_gb":%s,"zram_algo":"%s","game_auto_bypass":%s,"game_bypass_min_pct":%s}}\n' \
        "$PROFILE" "$CHARGE_ENABLED" "$CHARGE_STOP_PCT" "$CHARGE_RESUME_PCT" "$CHARGE_LIMIT_MA" \
        "$CHARGE_MODE" "$FPS_MODE" "$FPS_PK_MODE" "$SCREEN_OFF_ENABLED" "$SCREEN_OFF_DEBOUNCE" \
        "$SCREEN_OFF_DOZE" "$THERMAL_GUARD_ENABLED" "$THERMAL_WARN_C" "$THERMAL_CRIT_C" \
        "$AUTO_GAME_ENABLED" "$JOYOSE_DISABLED" "$ZRAM_ENABLED" "$ZRAM_SIZE_GB" "$ZRAM_ALGO" \
        "$GAME_AUTO_BYPASS" "$GAME_BYPASS_MIN_PCT"
}

print_games_json() {
    ensure_default_games_list
    gjson="["
    first=1
    while IFS= read -r line; do
        line=${line%"$CR"}
        [ -z "$line" ] && continue
        pkg=${line%%\|*}
        is_valid_pkg_name "$pkg" || continue
        case "$line" in
            *\|*)
                prof=${line#*\|}
                is_valid_game_profile "$prof" || prof="max120"
                ;;
            *)
                prof="max120"
                ;;
        esac
        item="{\"pkg\":\"${pkg}\",\"profile\":\"${prof}\"}"
        if [ "$first" -eq 1 ]; then
            gjson="${gjson}${item}"
            first=0
        else
            gjson="${gjson},${item}"
        fi
    done < "$GAMES_FILE"
    gjson="${gjson}]"
    printf '{"ok":true,"games":%s}\n' "$gjson"
}

cmd_status() {
    get_temperatures
    load_display_cache
    check_fps_overlay_live
    read_zram_stats

    read_sysfs_fast /sys/class/power_supply/battery/capacity "0"
    is_uint "$SYSFS_VAL" && cap="$SYSFS_VAL" || cap=0

    read_sysfs_fast /sys/class/power_supply/battery/status "Unknown"
    bstat="$SYSFS_VAL"

    read_sysfs_fast /sys/class/power_supply/battery/voltage_now "0"
    is_uint "$SYSFS_VAL" && volt_uv="$SYSFS_VAL" || volt_uv=0
    volt_mv=$((volt_uv / 1000))

    read_sysfs_fast /sys/class/power_supply/battery/current_now "0"
    is_int "$SYSFS_VAL" && curr_ua="$SYSFS_VAL" || curr_ua=0
    if [ "$HAS_QCOM_BATT" -eq 1 ]; then
        curr_ma=$((-curr_ua / 1000))
    else
        curr_ma=$((curr_ua / 1000))
    fi

    read_sysfs_fast /sys/class/power_supply/battery/cycle_count "0"
    is_uint "$SYSFS_VAL" && cycles="$SYSFS_VAL" || cycles=0

    soh=0
    if [ -r /sys/class/qcom-battery/soh ]; then
        read_sysfs_fast /sys/class/qcom-battery/soh "0"
        is_uint "$SYSFS_VAL" && soh="$SYSFS_VAL"
    else
        read_sysfs_fast /sys/class/power_supply/battery/charge_full "0"
        is_uint "$SYSFS_VAL" && cfull="$SYSFS_VAL" || cfull=0
        read_sysfs_fast /sys/class/power_supply/battery/charge_full_design "0"
        is_uint "$SYSFS_VAL" && cdes="$SYSFS_VAL" || cdes=0
        [ "$cdes" -gt 0 ] && soh=$((cfull * 100 / cdes))
    fi

    read_sysfs_fast /sys/class/power_supply/usb/online "0"
    is_uint "$SYSFS_VAL" && usb_on="$SYSFS_VAL" || usb_on=0

    read_sysfs_fast /sys/class/power_supply/wireless/online "0"
    is_uint "$SYSFS_VAL" && wls_on="$SYSFS_VAL" || wls_on=0

    chg_paused=0
    is_charging_paused && chg_paused=1
    topup_once=0
    [ -f "$TOPUP_ONCE_FLAG" ] && topup_once=1
    game_bypass=0
    [ -f "$GAME_BYPASS_FLAG" ] && game_bypass=1

    read_sysfs_fast "$THERMAL_STATE_FILE" "normal:none"
    tstate_raw="$SYSFS_VAL"
    tstate=${tstate_raw%%:*}
    case "$tstate_raw" in
        *:*) ttrigger=${tstate_raw#*:} ;;
        *) ttrigger="none" ;;
    esac

    scr_off=0
    [ -f "$SCREEN_OFF_FLAG" ] && scr_off=1

    dpid=0
    drun=0
    if [ -f "$DAEMON_PID_FILE" ]; then
        read_sysfs_fast "$DAEMON_PID_FILE" "0"
        dp="$SYSFS_VAL"
        if is_uint "$dp" && [ "$dp" -gt 0 ] && kill -0 "$dp" 2>/dev/null; then
            drun=1
            dpid="$dp"
        fi
    fi

    inotify_run=0
    if [ -f "$INOTIFY_PID_FILE" ]; then
        read_sysfs_fast "$INOTIFY_PID_FILE" "0"
        ip="$SYSFS_VAL"
        is_uint "$ip" && [ "$ip" -gt 0 ] && kill -0 "$ip" 2>/dev/null && inotify_run=1
    fi

    read_sysfs_fast /sys/class/mi_display/disp-DSI-0/dynamic_fps "0"
    is_uint "$SYSFS_VAL" && dyn_fps="$SYSFS_VAL" || dyn_fps=0

    read_sysfs_fast /sys/class/kgsl/kgsl-3d0/gpu_model "unknown"
    gpu_model="$SYSFS_VAL"
    read_sysfs_fast /sys/class/kgsl/kgsl-3d0/clock_mhz "0"
    is_uint "$SYSFS_VAL" && gpu_cur="$SYSFS_VAL" || gpu_cur=0
    read_sysfs_fast /sys/class/kgsl/kgsl-3d0/max_clock_mhz "0"
    is_uint "$SYSFS_VAL" && gpu_max="$SYSFS_VAL" || gpu_max=0

    ag_active=0
    ag_mode="off"
    ag_prof="none"
    ag_pkg=""
    read_sysfs_fast "$AUTO_GAME_STATE_FILE" "idle"
    case "$SYSFS_VAL" in
        active:max120:*|active:cool60:*|active:eco60:*)
            ag_active=1
            ag_mode="auto"
            _ag_rest=${SYSFS_VAL#active:}
            ag_prof=${_ag_rest%%:*}
            ag_pkg=${_ag_rest#*:}
            ;;
        active:*)
            ag_active=1
            ag_mode="auto"
            ag_prof="max120"
            ag_pkg=${SYSFS_VAL#active:}
            ;;
    esac
    if [ "$PROFILE" = "gaming" ]; then
        ag_active=1
        ag_mode="manual"
        ag_prof="max120"
    fi
    cpu_nl=0
    if [ -n "$CPU_NOLIMIT_NODE" ]; then
        read_sysfs_fast "$CPU_NOLIMIT_NODE" "0"
        is_uint "$SYSFS_VAL" && cpu_nl="$SYSFS_VAL" || cpu_nl=0
    fi

    if [ "$CHARGE_MODE" = "fcc" ] && [ -n "$CONST_CURR_NODE" ]; then
        active_chg_node="$CONST_CURR_NODE"
    elif [ "$CHARGE_MODE" = "night" ] && [ -n "$CHARGE_NIGHT_NODE" ]; then
        active_chg_node="$CHARGE_NIGHT_NODE"
    else
        active_chg_node="$CHARGE_SUSPEND_NODE"
    fi

    pol_json="["
    first=1
    for pname in $CPU_POLICIES; do
        pdir="/sys/devices/system/cpu/cpufreq/$pname"
        read_sysfs_fast "$pdir/related_cpus" ""
        cpus="$SYSFS_VAL"
        read_sysfs_fast "$pdir/scaling_cur_freq" "0"
        is_uint "$SYSFS_VAL" && cur_f="$SYSFS_VAL" || cur_f=0
        read_sysfs_fast "$pdir/scaling_max_freq" "0"
        is_uint "$SYSFS_VAL" && max_f="$SYSFS_VAL" || max_f=0
        read_sysfs_fast "$pdir/cpuinfo_max_freq" "0"
        is_uint "$SYSFS_VAL" && cmax_f="$SYSFS_VAL" || cmax_f=0
        is_lit=0
        [ "$pname" = "$LITTLE_POLICY" ] && is_lit=1
        item="{\"name\":\"${pname}\",\"cpus\":\"${cpus}\",\"cur_khz\":${cur_f},\"max_khz\":${max_f},\"cpuinfo_max_khz\":${cmax_f},\"is_little\":${is_lit}}"
        if [ "$first" -eq 1 ]; then
            pol_json="${pol_json}${item}"
            first=0
        else
            pol_json="${pol_json},${item}"
        fi
    done
    pol_json="${pol_json}]"

    printf '{"ok":true,"device":{"codename":"%s","model":"%s","os":"%s"},"capabilities":{"has_qcom_batt":%s,"has_mi_thermal":%s,"has_kgsl":%s,"has_inotifyd":%s,"has_cpu_nolimit":%s,"overlay_fps_xml":%s,"has_zram":%s,"charge_node":"%s"},"daemon":{"running":%s,"pid":%s,"screen_off_active":%s,"inotify_active":%s},"gaming":{"active":%s,"mode":"%s","profile":"%s","pkg":"%s","cpu_nolimit_temp":%s},"zram":{"active":%s,"algo":"%s","disk_mb":%s,"orig_mb":%s,"compr_mb":%s,"mem_mb":%s,"ratio_x100":%s,"backing_dev":"%s"},"battery":{"capacity":%s,"status":"%s","voltage_mv":%s,"current_ma":%s,"soh":%s,"cycle_count":%s,"usb_online":%s,"wls_online":%s,"charging_paused":%s,"topup_once":%s,"game_bypass_active":%s},"thermals":{"batt_x10":%s,"skin_x10":%s,"board_x10":%s,"cpu_x10":%s,"gpu_x10":%s,"guard_state":"%s","guard_trigger":"%s"},"display":{"dynamic_fps":%s,"peak_rr":"%s","min_rr":"%s","game_cap_disabled":%s},"gpu":{"model":"%s","cur_mhz":%s,"max_mhz":%s},"cpu":%s,"config":{"profile":"%s","charge_enabled":%s,"charge_stop_pct":%s,"charge_resume_pct":%s,"charge_limit_ma":%s,"charge_mode":"%s","fps_mode":"%s","fps_pk_mode":"%s","screen_off_enabled":%s,"screen_off_debounce":%s,"screen_off_doze":%s,"thermal_guard_enabled":%s,"thermal_warn_c":%s,"thermal_crit_c":%s,"auto_game_enabled":%s,"joyose_disabled":%s,"zram_enabled":%s,"zram_size_gb":%s,"zram_algo":"%s","game_auto_bypass":%s,"game_bypass_min_pct":%s}}\n' \
        "$DEV_CODENAME" "$DEV_MODEL" "$DEV_OS" \
        "$HAS_QCOM_BATT" "$HAS_MI_THERMAL" "$HAS_KGSL" "$HAS_INOTIFYD" "$HAS_CPU_NOLIMIT" "$HAS_FPS_OVERLAY" "$HAS_ZRAM" "$active_chg_node" \
        "$drun" "$dpid" "$scr_off" "$inotify_run" \
        "$ag_active" "$ag_mode" "$ag_prof" "$ag_pkg" "$cpu_nl" \
        "$ZRAM_ACTIVE" "$ZRAM_CUR_ALGO" "$ZRAM_DISK_MB" "$ZRAM_ORIG_MB" "$ZRAM_COMPR_MB" "$ZRAM_MEM_MB" "$ZRAM_RATIO_X100" "$ZRAM_BACKING_DEV" \
        "$cap" "$bstat" "$volt_mv" "$curr_ma" "$soh" "$cycles" "$usb_on" "$wls_on" "$chg_paused" "$topup_once" "$game_bypass" \
        "$TEMP_BATT_X10" "$TEMP_SKIN_X10" "$TEMP_BOARD_X10" "$TEMP_CPU_X10" "$TEMP_GPU_X10" "$tstate" "$ttrigger" \
        "$dyn_fps" "$CACHE_PEAK_RR" "$CACHE_MIN_RR" "$CACHE_GAME_CAP" \
        "$gpu_model" "$gpu_cur" "$gpu_max" \
        "$pol_json" \
        "$PROFILE" "$CHARGE_ENABLED" "$CHARGE_STOP_PCT" "$CHARGE_RESUME_PCT" "$CHARGE_LIMIT_MA" \
        "$CHARGE_MODE" "$FPS_MODE" "$FPS_PK_MODE" "$SCREEN_OFF_ENABLED" "$SCREEN_OFF_DEBOUNCE" \
        "$SCREEN_OFF_DOZE" "$THERMAL_GUARD_ENABLED" "$THERMAL_WARN_C" "$THERMAL_CRIT_C" \
        "$AUTO_GAME_ENABLED" "$JOYOSE_DISABLED" "$ZRAM_ENABLED" "$ZRAM_SIZE_GB" "$ZRAM_ALGO" \
        "$GAME_AUTO_BYPASS" "$GAME_BYPASS_MIN_PCT"
}

cmd_get_logs() {
    lines="${1:-80}"
    is_uint "$lines" || lines=80
    [ "$lines" -lt 10 ] && lines=10
    [ "$lines" -gt 200 ] && lines=200

    if [ ! -f "$LOG_FILE" ]; then
        printf '{"ok":true,"lines":[]}\n'
        return 0
    fi

    json_lines=$(tail -n "$lines" "$LOG_FILE" 2>/dev/null | tr -d '\r' | tr '\t' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/' | tr '\n' ',' | sed 's/,$//')
    printf '{"ok":true,"lines":[%s]}\n' "$json_lines"
}

cmd_list_apps() {
    ensure_default_games_list
    {
        if [ -f "$GAMES_FILE" ]; then
            cat "$GAMES_FILE" 2>/dev/null
        fi
        printf '%s\n' '---X14-GAMES---'
        dumpsys game 2>/dev/null
        printf '%s\n' '---X14-PKGS---'
        cmd package list packages -3 2>/dev/null || pm list packages -3 2>/dev/null
    } | awk '
        BEGIN { sec = 0; count = 0 }
        $0 == "---X14-GAMES---" { sec = 1; next }
        $0 == "---X14-PKGS---"  { sec = 2; next }
        sec == 0 {
            gsub(/\r/, "")
            if (length($0) > 0) {
                n = split($0, parts, "|")
                gp = parts[1]
                pr = (n >= 2 && (parts[2] == "max120" || parts[2] == "cool60" || parts[2] == "eco60")) ? parts[2] : "max120"
                if (length(gp) > 0) { s[gp] = 1; sp[gp] = pr }
            }
            next
        }
        sec == 1 {
            gsub(/\r/, "")
            if ($0 ~ /No intervention found for package /) {
                p = $0
                sub(/^.*No intervention found for package /, "", p)
                sub(/[ \t].*$/, "", p)
                if (length(p) > 0) g[p] = 1
            } else if ($0 ~ /\[Name:/) {
                p = $0
                sub(/^.*\[Name:/, "", p)
                sub(/[ \]\t].*$/, "", p)
                if (length(p) > 0) g[p] = 1
            }
            next
        }
        sec == 2 {
            gsub(/\r/, "")
            sub(/^package:/, "")
            if ($0 ~ /^[A-Za-z0-9._-]+$/ && !($0 in seen)) {
                seen[$0] = 1
                pkgs[++count] = $0
            }
        }
        END {
            printf "{\"ok\":true,\"apps\":["
            first = 1
            for (i = 1; i <= count; i++) {
                p = pkgs[i]
                lp = tolower(p)
                ig = (p in g || p in s) ? 1 : 0
                if (!ig && lp ~ /(game|garena|pubg|freefire|mihoyo|hoyoverse|kurogame|riotgames|supercell|roblox|minecraft|genshin|wuthering|tencent\.ig|tencent\.tmgp|netease|mobile\.legends|callofduty|codm|gameloft|miniclip|wildrift|arknights|honkai|krafton|moonton|activision|blizzard|superduelist|supreme|duelist)/) {
                    ig = 1
                }
                sel = (p in s) ? 1 : 0
                pr = (p in sp) ? sp[p] : "max120"
                if (!first) printf ","
                first = 0
                printf "{\"pkg\":\"%s\",\"is_game\":%d,\"selected\":%d,\"profile\":\"%s\"}", p, ig, sel, pr
            }
            printf "]}\n"
        }
    '
}

SUBCMD="$1"
[ -n "$SUBCMD" ] || json_err "Missing subcommand"
shift

case "$SUBCMD" in
    status)
        cmd_status
        ;;
    get-config)
        print_config_json
        ;;
    set-profile)
        p="$1"
        case "$p" in
            stock|battery|balanced|performance|gaming) ;;
            *) json_err "Invalid profile" ;;
        esac
        prev_profile="$PROFILE"
        PROFILE="$p"
        save_config
        read_sysfs_fast "$THERMAL_STATE_FILE" "normal:none"
        tstate=${SYSFS_VAL%%:*}
        if [ "$tstate" != "critical" ]; then
            if [ "$PROFILE" = "gaming" ]; then
                apply_fps_settings "gaming120" "keep"
            elif [ "$prev_profile" = "gaming" ]; then
                apply_fps_settings "$FPS_MODE" "keep"
            fi
            if [ ! -f "$SCREEN_OFF_FLAG" ]; then
                apply_cpu_gpu_profile "$PROFILE"
                if [ "$tstate" = "warn" ] && { [ "$PROFILE" = "performance" ] || [ "$PROFILE" = "gaming" ]; }; then
                    restore_gpu_cdev_floor
                    set_gpu_max_mhz 770
                fi
            fi
        fi
        log_msg "INFO" "Profile changed to $PROFILE"
        signal_daemon
        print_config_json
        ;;
    set-charge)
        en="$1"; stop="$2"; res="$3"; lim="$4"; cmode="$5"
        case "$en" in 0|1) ;; *) json_err "Invalid enabled flag" ;; esac
        is_uint "$stop" && [ "$stop" -ge 50 ] && [ "$stop" -le 100 ] || json_err "Invalid stop_pct (50-100)"
        is_uint "$res" && [ "$res" -ge 40 ] && [ "$res" -le 90 ] || json_err "Invalid resume_pct (40-90)"
        [ $((stop - res)) -ge 10 ] || json_err "Hysteresis gap must be at least 10% (stop - resume >= 10)"
        is_uint "$lim" && [ "$lim" -le 4500 ] || json_err "Invalid limit_ma (0-4500)"
        if [ "$lim" -ne 0 ] && [ "$lim" -lt 500 ]; then
            json_err "limit_ma must be 0 or 500-4500"
        fi
        case "$cmode" in fcc|suspend|night) ;; *) json_err "Invalid charge_mode" ;; esac

        CHARGE_ENABLED="$en"
        CHARGE_STOP_PCT="$stop"
        CHARGE_RESUME_PCT="$res"
        CHARGE_LIMIT_MA="$lim"
        CHARGE_MODE="$cmode"
        save_config

        if [ "$CHARGE_ENABLED" -eq 0 ]; then
            read_sysfs_fast "$THERMAL_STATE_FILE" "normal:none"
            tstate=${SYSFS_VAL%%:*}
            if [ "$tstate" != "critical" ] && [ ! -f "$GAME_BYPASS_FLAG" ]; then
                set_charging_paused 0
            fi
            [ ! -f "$GAME_BYPASS_FLAG" ] && apply_charge_current_limit 0
        else
            [ ! -f "$GAME_BYPASS_FLAG" ] && apply_charge_current_limit "$CHARGE_LIMIT_MA"
        fi

        log_msg "INFO" "Charge config updated: en=$CHARGE_ENABLED stop=$CHARGE_STOP_PCT resume=$CHARGE_RESUME_PCT limit=${CHARGE_LIMIT_MA}mA mode=$CHARGE_MODE"
        signal_daemon
        print_config_json
        ;;
    topup-once)
        arg="${1:-toggle}"
        case "$arg" in
            1|enable) target="1" ;;
            0|disable) target="0" ;;
            toggle)
                [ -f "$TOPUP_ONCE_FLAG" ] && target="0" || target="1"
                ;;
            *) json_err "Invalid topup-once arg (0|1|toggle)" ;;
        esac
        if [ "$target" = "1" ]; then
            read_sysfs_fast /sys/class/power_supply/usb/online "0"
            usb_on="$SYSFS_VAL"
            read_sysfs_fast /sys/class/power_supply/wireless/online "0"
            wls_on="$SYSFS_VAL"
            if [ "$usb_on" = "1" ] || [ "$wls_on" = "1" ]; then
                flag_state="armed"
            else
                flag_state="pending"
            fi
            atomic_write_file "$TOPUP_ONCE_FLAG" "$flag_state"
            read_sysfs_fast "$THERMAL_STATE_FILE" "normal:none"
            tstate=${SYSFS_VAL%%:*}
            if [ "$tstate" != "critical" ] && [ ! -f "$GAME_BYPASS_FLAG" ]; then
                set_charging_paused 0
            fi
            log_msg "INFO" "Top-up once enabled (state=$flag_state): allowing charge to 100% until unplugged"
            signal_daemon
            printf '{"ok":true,"topup_once":1,"state":"%s"}\n' "$flag_state"
        else
            rm -f "$TOPUP_ONCE_FLAG"
            log_msg "INFO" "Top-up once disabled: returning to Smart Charge (${CHARGE_STOP_PCT}%/${CHARGE_RESUME_PCT}%)"
            signal_daemon
            printf '{"ok":true,"topup_once":0,"state":"off"}\n'
        fi
        ;;
    set-fps)
        fmode="$1"
        pk="${2:-none}"
        case "$fmode" in stock|smart120|force120) ;; *) json_err "Invalid fps_mode" ;; esac
        case "$pk" in none|joyose|both) ;; *) json_err "Invalid pk_mode" ;; esac
        [ "$fmode" != "force120" ] && pk="none"

        FPS_MODE="$fmode"
        FPS_PK_MODE="$pk"
        save_config

        read_sysfs_fast "$THERMAL_STATE_FILE" "normal:none"
        tstate=${SYSFS_VAL%%:*}
        if [ "$tstate" = "critical" ]; then
            apply_fps_settings "lock60" "none"
        elif [ "$tstate" = "warn" ] && [ "$FPS_MODE" = "force120" ]; then
            apply_fps_settings "smart120" "none"
        else
            apply_fps_settings "$FPS_MODE" "$FPS_PK_MODE"
        fi

        log_msg "INFO" "FPS config updated: mode=$FPS_MODE pk_mode=$FPS_PK_MODE"
        signal_daemon
        print_config_json
        ;;
    set-screenoff)
        en="$1"; deb="$2"; doze="$3"
        case "$en" in 0|1) ;; *) json_err "Invalid screen_off_enabled" ;; esac
        is_uint "$deb" && [ "$deb" -ge 5 ] && [ "$deb" -le 300 ] || json_err "Invalid debounce (5-300)"
        case "$doze" in 0|1) ;; *) json_err "Invalid doze flag" ;; esac

        SCREEN_OFF_ENABLED="$en"
        SCREEN_OFF_DEBOUNCE="$deb"
        SCREEN_OFF_DOZE="$doze"
        save_config

        if [ "$SCREEN_OFF_ENABLED" -eq 0 ] && [ -f "$SCREEN_OFF_FLAG" ]; then
            rm -f "$SCREEN_OFF_FLAG"
            apply_cpu_gpu_profile "$PROFILE"
        fi
        if [ "$SCREEN_OFF_ENABLED" -eq 0 ] || [ "$SCREEN_OFF_DOZE" -eq 0 ]; then
            unforce_doze_if_needed
        fi

        log_msg "INFO" "Screen-off config updated: en=$SCREEN_OFF_ENABLED debounce=${SCREEN_OFF_DEBOUNCE}s doze=$SCREEN_OFF_DOZE"
        signal_daemon
        print_config_json
        ;;
    set-zram)
        en="$1"; sz="$2"; algo="${3:-lz4}"
        case "$en" in 0|1) ;; *) json_err "Invalid zram_enabled (0|1)" ;; esac
        case "$sz" in 0|4|6|8) ;; *) json_err "Invalid zram_size_gb (0|4|6|8)" ;; esac
        case "$algo" in lz4|zstd) ;; *) json_err "Invalid zram_algo (lz4|zstd)" ;; esac
        if [ "$en" = "1" ] && [ "$sz" = "0" ]; then
            json_err "ZRAM size must be 4, 6 or 8 GB when enabled"
        fi
        [ "$sz" = "0" ] && en="0"

        prev_en="$ZRAM_ENABLED"
        prev_sz="$ZRAM_SIZE_GB"
        prev_algo="$ZRAM_ALGO"
        ZRAM_ENABLED="$en"
        ZRAM_SIZE_GB="$sz"
        ZRAM_ALGO="$algo"
        apply_zram_config
        zrc=$?
        if [ "$zrc" -ne 0 ]; then
            ZRAM_ENABLED="$prev_en"
            ZRAM_SIZE_GB="$prev_sz"
            ZRAM_ALGO="$prev_algo"
            if [ "$zrc" -eq 2 ]; then
                json_err "RAM trong khong du de swapoff ZRAM an toan; hay dong bot app nen roi thu lai"
            fi
            json_err "Khong the thiet lap ZRAM"
        fi
        save_config
        log_msg "INFO" "ZRAM config updated: en=$ZRAM_ENABLED size=${ZRAM_SIZE_GB}GB algo=$ZRAM_ALGO"
        print_config_json
        ;;
    set-thermal)
        en="$1"; warn="$2"; crit="$3"
        case "$en" in 0|1) ;; *) json_err "Invalid thermal_guard_enabled" ;; esac
        is_uint "$warn" && [ "$warn" -ge 38 ] && [ "$warn" -le 46 ] || json_err "Invalid warn_c (38-46)"
        is_uint "$crit" && [ "$crit" -ge 42 ] && [ "$crit" -le 50 ] || json_err "Invalid crit_c (42-50)"
        [ "$warn" -lt "$crit" ] || json_err "warn_c must be lower than crit_c"

        THERMAL_GUARD_ENABLED="$en"
        THERMAL_WARN_C="$warn"
        THERMAL_CRIT_C="$crit"
        save_config

        log_msg "INFO" "Thermal Guard updated: en=$THERMAL_GUARD_ENABLED warn=${THERMAL_WARN_C}C crit=${THERMAL_CRIT_C}C"
        signal_daemon
        print_config_json
        ;;
    set-autogame)
        en="$1"
        case "$en" in 0|1) ;; *) json_err "Invalid auto_game_enabled (0|1)" ;; esac
        AUTO_GAME_ENABLED="$en"
        save_config
        ensure_default_games_list
        log_msg "INFO" "Auto Game Mode updated: enabled=$AUTO_GAME_ENABLED"
        signal_daemon
        print_config_json
        ;;
    set-joyose)
        dis="$1"
        case "$dis" in 0|1) ;; *) json_err "Invalid joyose_disabled (0|1)" ;; esac
        JOYOSE_DISABLED="$dis"
        save_config
        apply_joyose_state
        log_msg "INFO" "Joyose independent lock updated: disabled=$JOYOSE_DISABLED"
        print_config_json
        ;;
    set-game-bypass)
        en="$1"
        minp="$2"
        case "$en" in 0|1) ;; *) json_err "Invalid game_auto_bypass (0|1)" ;; esac
        is_uint "$minp" && [ "$minp" -ge 10 ] && [ "$minp" -le 50 ] || json_err "Invalid game_bypass_min_pct (10-50)"
        GAME_AUTO_BYPASS="$en"
        GAME_BYPASS_MIN_PCT="$minp"
        save_config
        if [ "$GAME_AUTO_BYPASS" -eq 0 ] && [ -f "$GAME_BYPASS_FLAG" ]; then
            dpid=""
            [ -f "$DAEMON_PID_FILE" ] && read_sysfs_fast "$DAEMON_PID_FILE" "" && dpid="$SYSFS_VAL"
            if ! is_uint "$dpid" || ! kill -0 "$dpid" 2>/dev/null; then
                rm -f "$GAME_BYPASS_FLAG"
                read_sysfs_fast "$THERMAL_STATE_FILE" "normal:none"
                tstate=${SYSFS_VAL%%:*}
                [ "$tstate" != "critical" ] && set_charging_paused 0
            fi
        fi
        log_msg "INFO" "Gaming Auto-Bypass updated: en=$GAME_AUTO_BYPASS min_pct=${GAME_BYPASS_MIN_PCT}%"
        signal_daemon
        print_config_json
        ;;
    get-games|list-games)
        print_games_json
        ;;
    list-apps)
        cmd_list_apps
        ;;
    add-game)
        pkg="$1"
        req_prof="$2"
        is_valid_pkg_name "$pkg" || json_err "Invalid package name"
        if [ -n "$req_prof" ]; then
            is_valid_game_profile "$req_prof" || json_err "Invalid game profile (max120|cool60|eco60)"
        fi
        ensure_default_games_list
        if ! get_game_profile "$pkg"; then
            prof="${req_prof:-max120}"
            printf '%s|%s\n' "$pkg" "$prof" >> "$GAMES_FILE"
            chmod 0644 "$GAMES_FILE"
            log_msg "INFO" "Auto Game list: added $pkg ($prof)"
            signal_daemon
        elif [ -n "$req_prof" ] && [ "$MATCHED_GAME_PROF" != "$req_prof" ]; then
            tmp_g="${GAMES_FILE}.tmp.$$"
            : > "$tmp_g"
            while IFS= read -r line; do
                line=${line%"$CR"}
                [ -z "$line" ] && continue
                _lp=${line%%\|*}
                if [ "$_lp" = "$pkg" ]; then
                    printf '%s|%s\n' "$pkg" "$req_prof" >> "$tmp_g"
                else
                    printf '%s\n' "$line" >> "$tmp_g"
                fi
            done < "$GAMES_FILE"
            chmod 0644 "$tmp_g"
            mv -f "$tmp_g" "$GAMES_FILE"
            log_msg "INFO" "Auto Game list: updated $pkg -> $req_prof"
            signal_daemon
        fi
        print_games_json
        ;;
    set-game-profile)
        pkg="$1"
        prof="$2"
        is_valid_pkg_name "$pkg" || json_err "Invalid package name"
        is_valid_game_profile "$prof" || json_err "Invalid game profile (max120|cool60|eco60)"
        ensure_default_games_list
        tmp_g="${GAMES_FILE}.tmp.$$"
        : > "$tmp_g"
        found=0
        while IFS= read -r line; do
            line=${line%"$CR"}
            [ -z "$line" ] && continue
            _lp=${line%%\|*}
            if [ "$_lp" = "$pkg" ]; then
                printf '%s|%s\n' "$pkg" "$prof" >> "$tmp_g"
                found=1
            else
                printf '%s\n' "$line" >> "$tmp_g"
            fi
        done < "$GAMES_FILE"
        if [ "$found" -eq 0 ]; then
            printf '%s|%s\n' "$pkg" "$prof" >> "$tmp_g"
        fi
        chmod 0644 "$tmp_g"
        mv -f "$tmp_g" "$GAMES_FILE"
        log_msg "INFO" "Auto Game profile set: $pkg -> $prof"
        signal_daemon
        print_games_json
        ;;
    remove-game)
        pkg="$1"
        is_valid_pkg_name "$pkg" || json_err "Invalid package name"
        ensure_default_games_list
        tmp_g="${GAMES_FILE}.tmp.$$"
        : > "$tmp_g"
        while IFS= read -r line; do
            line=${line%"$CR"}
            [ -z "$line" ] && continue
            _lp=${line%%\|*}
            [ "$_lp" = "$pkg" ] && continue
            printf '%s\n' "$line" >> "$tmp_g"
        done < "$GAMES_FILE"
        chmod 0644 "$tmp_g"
        mv -f "$tmp_g" "$GAMES_FILE"
        log_msg "INFO" "Auto Game list: removed $pkg"
        signal_daemon
        print_games_json
        ;;
    get-logs)
        cmd_get_logs "$1"
        ;;
    clear-logs)
        printf '' > "$LOG_FILE" 2>/dev/null
        rm -f "${LOG_FILE}.old"
        log_msg "INFO" "Log cleared by user"
        printf '{"ok":true}\n'
        ;;
    apply-all)
        ensure_default_games_list
        apply_joyose_state
        apply_zram_config
        apply_cpu_gpu_profile "$PROFILE"
        if [ "$PROFILE" = "gaming" ]; then
            apply_fps_settings "gaming120" "keep"
        else
            apply_fps_settings "$FPS_MODE" "$FPS_PK_MODE"
        fi
        if [ "$CHARGE_ENABLED" -eq 1 ] && [ "$CHARGE_LIMIT_MA" -gt 0 ]; then
            apply_charge_current_limit "$CHARGE_LIMIT_MA"
        fi
        printf '{"ok":true}\n'
        ;;
    reset-defaults)
        PROFILE="stock"
        CHARGE_ENABLED=0
        CHARGE_LIMIT_MA=0
        FPS_MODE="stock"
        FPS_PK_MODE="none"
        SCREEN_OFF_ENABLED=0
        SCREEN_OFF_DOZE=0
        AUTO_GAME_ENABLED=0
        JOYOSE_DISABLED=0
        ZRAM_ENABLED=0
        ZRAM_SIZE_GB=0
        ZRAM_ALGO="lz4"
        GAME_AUTO_BYPASS=0
        GAME_BYPASS_MIN_PCT=20
        save_config
        rm -f "$SCREEN_OFF_FLAG" "$TOPUP_ONCE_FLAG" "$AUTO_GAME_STATE_FILE" "$GAME_BYPASS_FLAG"
        unforce_doze_if_needed
        dumpsys deviceidle unforce >/dev/null 2>&1
        printf 'normal:none\n' > "$THERMAL_STATE_FILE"
        clear_cpu_nolimit
        [ -n "$SCONFIG_NODE" ] && write_sysfs "$SCONFIG_NODE" "-1"
        [ -n "$CPU_C3_CDEV_NODE" ] && write_sysfs "$CPU_C3_CDEV_NODE" "0"
        [ -n "$DISP_FPS_CDEV_NODE" ] && write_sysfs "$DISP_FPS_CDEV_NODE" "0"
        restore_hyperos_fps_apps
        set_charging_paused 0
        apply_charge_current_limit 0
        apply_zram_config
        write_sysfs /proc/sys/vm/swappiness 60
        apply_defaults_snapshot
        log_msg "INFO" "Reset all hardware & system settings to boot defaults"
        signal_daemon
        print_config_json
        ;;
    *)
        json_err "Unknown subcommand: $SUBCMD"
        ;;
esac
