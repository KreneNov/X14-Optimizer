// ksu-bridge.js - Non-blocking KernelSU WebUI IPC bridge with 4s timeout & mock fallback

const CTRL_BIN = "/data/adb/modules/x14_perf_battery/bin/x14_ctrl.sh";
const SAFE_TOKEN_RE = /^[A-Za-z0-9_.-]+$/;

let statusInFlight = false;

const mockState = {
  device: { codename: "houji", model: "23127PN0CC", os: "OS3.0.306.0.WNCCNXM" },
  capabilities: {
    has_qcom_batt: 1,
    has_mi_thermal: 1,
    has_kgsl: 1,
    has_inotifyd: 1,
    has_cpu_nolimit: 1,
    overlay_fps_xml: 1,
    has_zram: 1,
    charge_node: "/sys/class/power_supply/battery/constant_charge_current"
  },
  daemon: { running: 1, pid: 14208, screen_off_active: 0, inotify_active: 1 },
  gaming: { active: 0, mode: "off", profile: "none", pkg: "", cpu_nolimit_temp: 0 },
  zram: { active: 1, algo: "lz4", disk_mb: 6144, orig_mb: 2480, compr_mb: 790, mem_mb: 825, ratio_x100: 300, backing_dev: "none" },
  battery: {
    capacity: 82,
    status: "Charging",
    voltage_mv: 4278,
    current_ma: 536,
    soh: 80,
    cycle_count: 1222,
    usb_online: 1,
    wls_online: 0,
    charging_paused: 0,
    topup_once: 0,
    game_bypass_active: 0
  },
  thermals: {
    batt_x10: 366,
    skin_x10: 412,
    board_x10: 387,
    cpu_x10: 451,
    gpu_x10: 356,
    guard_state: "normal",
    guard_trigger: "none"
  },
  display: { dynamic_fps: 120, peak_rr: "120.0", min_rr: "null", game_cap_disabled: 1 },
  gpu: { model: "Adreno750v2", cur_mhz: 231, max_mhz: 680 },
  cpu: [
    { name: "policy0", cpus: "0 1", cur_khz: 1344000, max_khz: 2265600, cpuinfo_max_khz: 2265600, is_little: 1 },
    { name: "policy2", cpus: "2 3 4", cur_khz: 960000, max_khz: 2630400, cpuinfo_max_khz: 3148800, is_little: 0 },
    { name: "policy5", cpus: "5 6", cur_khz: 960000, max_khz: 2630400, cpuinfo_max_khz: 2956800, is_little: 0 },
    { name: "policy7", cpus: "7", cur_khz: 672000, max_khz: 2630400, cpuinfo_max_khz: 3302400, is_little: 0 }
  ],
  config: {
    profile: "balanced",
    charge_enabled: 1,
    charge_stop_pct: 85,
    charge_resume_pct: 75,
    charge_limit_ma: 0,
    charge_mode: "fcc",
    fps_mode: "smart120",
    fps_pk_mode: "none",
    screen_off_enabled: 1,
    screen_off_debounce: 30,
    screen_off_doze: 0,
    thermal_guard_enabled: 1,
    thermal_warn_c: 42,
    thermal_crit_c: 45,
    auto_game_enabled: 1,
    joyose_disabled: 0,
    zram_enabled: 1,
    zram_size_gb: 6,
    zram_algo: "lz4",
    game_auto_bypass: 1,
    game_bypass_min_pct: 20
  },
  games: [
    { pkg: "com.garena.game.kgvn", profile: "max120" },
    { pkg: "com.garena.game.kgvo", profile: "max120" },
    { pkg: "com.vng.pubgmobile", profile: "max120" },
    { pkg: "com.tencent.ig", profile: "max120" },
    { pkg: "com.dts.freefiremax", profile: "max120" },
    { pkg: "com.kurogame.wutheringwaves", profile: "cool60" }
  ],
  installedApps: [
    { pkg: "com.garena.game.kgvn", label: "Liên Quân Mobile (VN)", is_game: 1 },
    { pkg: "com.garena.game.kgvo", label: "Liên Quân Mobile (Quốc tế)", is_game: 1 },
    { pkg: "com.vng.pubgmobile", label: "PUBG Mobile VN", is_game: 1 },
    { pkg: "com.tencent.ig", label: "PUBG Mobile Global", is_game: 1 },
    { pkg: "com.dts.freefiremax", label: "Free Fire MAX", is_game: 1 },
    { pkg: "com.kurogame.wutheringwaves", label: "Wuthering Waves", is_game: 1 },
    { pkg: "com.roblox.client", label: "Roblox", is_game: 1 },
    { pkg: "com.miHoYo.GenshinImpact", label: "Genshin Impact", is_game: 1 },
    { pkg: "com.facebook.katana", label: "Facebook", is_game: 0 },
    { pkg: "com.zing.zalo", label: "Zalo", is_game: 0 },
    { pkg: "com.google.android.youtube", label: "YouTube", is_game: 0 }
  ],
  logs: [
    "[2026-11-24 17:20:01] [INFO] Boot initialized on device=houji qcom_batt=1 mi_thermal=1 kgsl=1 inotifyd=1",
    "[2026-11-24 17:20:02] [INFO] Daemon started PID=14208 with Zero-Lag Wakeup (inotifyd PID=14215)",
    "[2026-11-24 17:21:10] [INFO] Smart Charge: monitoring active (mode=fcc 85%/75%)"
  ]
};

export function isDemoMode() {
  return typeof window.ksu === "undefined" || typeof window.ksu.exec !== "function";
}

function execKsuShell(cmd, timeoutMs = 4000) {
  return new Promise((resolve, reject) => {
    const cbName = "__x14_cb_" + Date.now() + "_" + Math.floor(Math.random() * 100000);
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      delete window[cbName];
      reject(new Error(`Quá thời gian chờ (${Math.round(timeoutMs / 1000)}s)`));
    }, timeoutMs);

    window[cbName] = (errno, stdout, stderr) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      delete window[cbName];
      resolve({ errno: Number(errno), stdout: String(stdout || ""), stderr: String(stderr || "") });
    };

    try {
      window.ksu.exec(cmd, "{}", cbName);
    } catch (err) {
      settled = true;
      clearTimeout(timer);
      delete window[cbName];
      reject(err);
    }
  });
}

function handleMock(subcmd, args) {
  const c = mockState.config;
  switch (subcmd) {
    case "status":
      return Promise.resolve({ ok: true, ...structuredClone(mockState) });
    case "get-config":
      return Promise.resolve({ ok: true, config: { ...c } });
    case "set-profile":
      c.profile = args[0];
      if (c.profile === "gaming") {
        mockState.gaming = { active: 1, mode: "manual", profile: "max120", pkg: "", cpu_nolimit_temp: 45000 };
        mockState.gpu.max_mhz = 903;
        mockState.display.min_rr = "120.0";
        if (c.game_auto_bypass && mockState.battery.usb_online && mockState.battery.capacity >= c.game_bypass_min_pct) {
          mockState.battery.game_bypass_active = 1;
          mockState.battery.charging_paused = 1;
        }
      } else {
        mockState.gaming = { active: 0, mode: "off", profile: "none", pkg: "", cpu_nolimit_temp: 0 };
        mockState.battery.game_bypass_active = 0;
      }
      mockState.logs.push(`[DEMO] Profile changed to ${c.profile}`);
      return Promise.resolve({ ok: true, config: { ...c } });
    case "set-charge":
      c.charge_enabled = Number(args[0]);
      c.charge_stop_pct = Number(args[1]);
      c.charge_resume_pct = Number(args[2]);
      c.charge_limit_ma = Number(args[3]);
      c.charge_mode = args[4];
      mockState.capabilities.charge_node = c.charge_mode === "fcc"
        ? "/sys/class/power_supply/battery/constant_charge_current"
        : c.charge_mode === "night"
          ? "/sys/class/qcom-battery/night_charging"
          : "/sys/class/qcom-battery/input_suspend";
      mockState.logs.push(`[DEMO] Charge updated: en=${c.charge_enabled} ${c.charge_stop_pct}%/${c.charge_resume_pct}% mode=${c.charge_mode}`);
      return Promise.resolve({ ok: true, config: { ...c } });
    case "topup-once": {
      const target = args[0] === "1" ? 1 : args[0] === "0" ? 0 : (mockState.battery.topup_once ? 0 : 1);
      mockState.battery.topup_once = target;
      if (target === 1) mockState.battery.charging_paused = 0;
      mockState.logs.push(`[DEMO] Top-up once=${target}`);
      return Promise.resolve({ ok: true, topup_once: target, state: target ? "armed" : "off" });
    }
    case "set-fps":
      c.fps_mode = args[0];
      c.fps_pk_mode = args[0] === "force120" ? (args[1] || "none") : "none";
      mockState.display.min_rr = c.fps_mode === "force120" ? "120.0" : "null";
      mockState.display.peak_rr = c.fps_mode === "stock" ? "60.0" : "120.0";
      mockState.logs.push(`[DEMO] FPS updated: ${c.fps_mode} pk=${c.fps_pk_mode}`);
      return Promise.resolve({ ok: true, config: { ...c } });
    case "set-screenoff":
      c.screen_off_enabled = Number(args[0]);
      c.screen_off_debounce = Number(args[1]);
      c.screen_off_doze = Number(args[2]);
      mockState.logs.push(`[DEMO] Screen-off updated: en=${c.screen_off_enabled} deb=${c.screen_off_debounce}s`);
      return Promise.resolve({ ok: true, config: { ...c } });
    case "set-thermal":
      c.thermal_guard_enabled = Number(args[0]);
      c.thermal_warn_c = Number(args[1]);
      c.thermal_crit_c = Number(args[2]);
      mockState.logs.push(`[DEMO] Thermal Guard updated: warn=${c.thermal_warn_c}C crit=${c.thermal_crit_c}C`);
      return Promise.resolve({ ok: true, config: { ...c } });
    case "set-autogame":
      c.auto_game_enabled = Number(args[0]);
      mockState.logs.push(`[DEMO] Auto Game Mode=${c.auto_game_enabled}`);
      return Promise.resolve({ ok: true, config: { ...c } });
    case "set-joyose":
      c.joyose_disabled = Number(args[0]);
      mockState.logs.push(`[DEMO] Joyose disabled=${c.joyose_disabled}`);
      return Promise.resolve({ ok: true, config: { ...c } });
    case "set-zram": {
      const en = Number(args[0]);
      const sz = Number(args[1]);
      const algo = args[2] || "lz4";
      c.zram_enabled = sz === 0 ? 0 : en;
      c.zram_size_gb = c.zram_enabled ? sz : 0;
      c.zram_algo = algo;
      if (c.zram_enabled && c.zram_size_gb > 0) {
        mockState.zram = {
          active: 1,
          algo,
          disk_mb: c.zram_size_gb * 1024,
          orig_mb: 2480,
          compr_mb: algo === "zstd" ? 680 : 790,
          mem_mb: algo === "zstd" ? 715 : 825,
          ratio_x100: algo === "zstd" ? 347 : 300,
          backing_dev: "none"
        };
      } else {
        mockState.zram = { active: 0, algo: "none", disk_mb: 0, orig_mb: 0, compr_mb: 0, mem_mb: 0, ratio_x100: 0, backing_dev: "none" };
      }
      mockState.logs.push(`[DEMO] ZRAM updated: en=${c.zram_enabled} size=${c.zram_size_gb}GB algo=${algo}`);
      return Promise.resolve({ ok: true, config: { ...c } });
    }
    case "set-game-bypass":
      c.game_auto_bypass = Number(args[0]);
      c.game_bypass_min_pct = Number(args[1]);
      if (!c.game_auto_bypass) {
        mockState.battery.game_bypass_active = 0;
      }
      mockState.logs.push(`[DEMO] Gaming Auto-Bypass en=${c.game_auto_bypass} min=${c.game_bypass_min_pct}%`);
      return Promise.resolve({ ok: true, config: { ...c } });
    case "get-games":
    case "list-games":
      return Promise.resolve({ ok: true, games: mockState.games.map((g) => ({ ...g })) });
    case "list-apps":
      return Promise.resolve({
        ok: true,
        apps: mockState.installedApps.map((a) => {
          const hit = mockState.games.find((g) => g.pkg === a.pkg);
          return {
            pkg: a.pkg,
            label: a.label,
            is_game: a.is_game,
            selected: hit ? 1 : 0,
            profile: hit ? hit.profile : "max120"
          };
        })
      });
    case "add-game": {
      const pkg = args[0];
      const prof = args[1] || "max120";
      const existing = mockState.games.find((g) => g.pkg === pkg);
      if (!existing) {
        mockState.games.push({ pkg, profile: prof });
      } else if (args[1]) {
        existing.profile = prof;
      }
      mockState.logs.push(`[DEMO] Added game: ${pkg} (${prof})`);
      return Promise.resolve({ ok: true, games: mockState.games.map((g) => ({ ...g })) });
    }
    case "set-game-profile": {
      const pkg = args[0];
      const prof = args[1] || "max120";
      const existing = mockState.games.find((g) => g.pkg === pkg);
      if (existing) existing.profile = prof;
      else mockState.games.push({ pkg, profile: prof });
      mockState.logs.push(`[DEMO] Game profile set: ${pkg} -> ${prof}`);
      return Promise.resolve({ ok: true, games: mockState.games.map((g) => ({ ...g })) });
    }
    case "remove-game":
      mockState.games = mockState.games.filter((g) => g.pkg !== args[0]);
      mockState.logs.push(`[DEMO] Removed game: ${args[0]}`);
      return Promise.resolve({ ok: true, games: mockState.games.map((g) => ({ ...g })) });
    case "get-logs":
      return Promise.resolve({ ok: true, lines: [...mockState.logs] });
    case "clear-logs":
      mockState.logs = ["[DEMO] Log cleared by user"];
      return Promise.resolve({ ok: true });
    case "reset-defaults":
      c.profile = "stock";
      c.charge_enabled = 0;
      c.charge_limit_ma = 0;
      c.fps_mode = "stock";
      c.fps_pk_mode = "none";
      c.screen_off_enabled = 0;
      c.auto_game_enabled = 0;
      c.joyose_disabled = 0;
      c.zram_enabled = 0;
      c.zram_size_gb = 0;
      c.zram_algo = "lz4";
      c.game_auto_bypass = 0;
      c.game_bypass_min_pct = 20;
      mockState.battery.game_bypass_active = 0;
      mockState.zram = { active: 0, algo: "none", disk_mb: 0, orig_mb: 0, compr_mb: 0, mem_mb: 0, ratio_x100: 0, backing_dev: "none" };
      mockState.gaming = { active: 0, mode: "off", profile: "none", pkg: "", cpu_nolimit_temp: 0 };
      mockState.logs.push("[DEMO] Reset all settings to defaults");
      return Promise.resolve({ ok: true, config: { ...c } });
    default:
      return Promise.reject(new Error(`Unknown mock command: ${subcmd}`));
  }
}

export async function callCtrl(subcmd, args = []) {
  if (!SAFE_TOKEN_RE.test(subcmd)) {
    throw new Error("Invalid subcommand");
  }
  const safeArgs = args.map((a) => {
    const s = String(a);
    if (!SAFE_TOKEN_RE.test(s)) {
      throw new Error(`Unsafe argument: ${s}`);
    }
    return s;
  });

  if (isDemoMode()) {
    return handleMock(subcmd, safeArgs);
  }

  // Skip overlapping background status polls; user actions always proceed immediately
  if (subcmd === "status") {
    if (statusInFlight) return null;
    statusInFlight = true;
  }

  try {
    const cmd = [CTRL_BIN, subcmd, ...safeArgs].join(" ");
    const timeoutMs = subcmd === "set-zram" ? 15000 : (subcmd === "list-apps" ? 8000 : 4000);
    const res = await execKsuShell(cmd, timeoutMs);
    const raw = res.stdout.trim();
    if (!raw) {
      throw new Error(res.stderr.trim() || `Empty output (exit ${res.errno})`);
    }
    const parsed = JSON.parse(raw);
    if (!parsed.ok) {
      throw new Error(parsed.error || "Controller error");
    }
    return parsed;
  } finally {
    if (subcmd === "status") {
      statusInFlight = false;
    }
  }
}

const KNOWN_GAME_LABELS = {
  "com.garena.game.kgvn": "Liên Quân Mobile (VN)",
  "com.garena.game.kgvo": "Liên Quân Mobile (Quốc tế)",
  "com.garena.game.kgth": "RoV (Arena of Valor TH)",
  "com.garena.game.kgtw": "Arena of Valor (TW)",
  "com.vng.pubgmobile": "PUBG Mobile VN",
  "com.tencent.ig": "PUBG Mobile Global",
  "com.dts.freefiremax": "Free Fire MAX",
  "com.dts.freefireth": "Free Fire",
  "com.kurogame.wutheringwaves": "Wuthering Waves",
  "com.miHoYo.GenshinImpact": "Genshin Impact",
  "com.HoYoverse.hkrpgvn": "Honkai: Star Rail (VN)",
  "com.HoYoverse.hkrpgoversea": "Honkai: Star Rail",
  "com.HoYoverse.Nap": "Zenless Zone Zero",
  "com.riotgames.league.wildrift": "LMHT: Tốc Chiến",
  "com.riotgames.league.wildriftvn": "LMHT: Tốc Chiến (VNG)",
  "com.mobile.legends": "Mobile Legends: Bang Bang",
  "com.vng.mlbbvn": "Mobile Legends: Bang Bang (VNG)",
  "com.roblox.client": "Roblox",
  "com.garena.game.codm": "Call of Duty: Mobile (VN)",
  "com.activision.callofduty.shooter": "Call of Duty: Mobile",
  "com.hypergryph.arknights": "Arknights",
  "com.antutu.benchmark.full": "AnTuTu Benchmark"
};

const GAME_PKG_RE = /(game|garena|pubg|freefire|mihoyo|hoyoverse|kurogame|riotgames|supercell|roblox|minecraft|genshin|wuthering|tencent\.ig|tencent\.tmgp|netease|mobile\.legends|callofduty|codm|gameloft|miniclip|wildrift|arknights|honkai|krafton|moonton|activision|blizzard|superduelist|supreme|duelist)/i;

export function getGameLabel(pkg) {
  return humanizePkgLabel(pkg);
}

function humanizePkgLabel(pkg) {
  if (KNOWN_GAME_LABELS[pkg]) return KNOWN_GAME_LABELS[pkg];
  const parts = String(pkg || "").split(".");
  const generic = new Set(["com", "vn", "org", "net", "io", "android", "client", "app", "mobile", "global", "game"]);
  for (let i = parts.length - 1; i >= 0; i--) {
    const seg = parts[i];
    if (seg && !generic.has(seg.toLowerCase())) {
      return seg.replace(/[-_]+/g, " ").replace(/\b\w/g, (m) => m.toUpperCase());
    }
  }
  return parts[parts.length - 1] || pkg;
}

async function readNativePackageLabels() {
  try {
    const pm = window.ksu && typeof window.ksu.listPackages === "function" ? window.ksu : window.$packageManager;
    if (!pm || typeof pm.listPackages !== "function") return null;

    let rawPkgs = pm.listPackages("user");
    if (rawPkgs && typeof rawPkgs.then === "function") rawPkgs = await rawPkgs;
    const pkgs = typeof rawPkgs === "string" ? JSON.parse(rawPkgs) : rawPkgs;
    if (!Array.isArray(pkgs) || !pkgs.length) return null;

    const labelMap = new Map();
    if (typeof pm.getPackagesInfo === "function") {
      let rawInfo = pm.getPackagesInfo(JSON.stringify(pkgs));
      if (rawInfo && typeof rawInfo.then === "function") rawInfo = await rawInfo;
      const infos = typeof rawInfo === "string" ? JSON.parse(rawInfo) : rawInfo;
      if (Array.isArray(infos)) {
        infos.forEach((info) => {
          if (info && info.packageName) {
            labelMap.set(info.packageName, info.appLabel || info.label || "");
          }
        });
      }
    }
    return { pkgs, labelMap };
  } catch (_) {
    return null;
  }
}

export async function listInstalledApps(selectedSet) {
  if (isDemoMode()) {
    const res = await handleMock("list-apps", []);
    return { source: "demo", apps: res.apps };
  }

  const [nativeData, backendRes] = await Promise.all([
    readNativePackageLabels(),
    callCtrl("list-apps").catch(() => null)
  ]);

  const backendMap = new Map();
  if (backendRes && Array.isArray(backendRes.apps)) {
    backendRes.apps.forEach((a) => backendMap.set(a.pkg, a));
  }

  const merged = [];
  const seen = new Set();

  if (nativeData && nativeData.pkgs.length) {
    nativeData.pkgs.forEach((pkg) => {
      if (!pkg || seen.has(pkg)) return;
      seen.add(pkg);
      const b = backendMap.get(pkg);
      const sel = selectedSet ? selectedSet.has(pkg) : Boolean(b && b.selected);
      const isGame = (b && Number(b.is_game) === 1) || sel || Boolean(KNOWN_GAME_LABELS[pkg]) || GAME_PKG_RE.test(pkg);
      const nativeLabel = nativeData.labelMap.get(pkg);
      merged.push({
        pkg,
        label: nativeLabel || humanizePkgLabel(pkg),
        is_game: isGame ? 1 : 0,
        selected: sel ? 1 : 0
      });
    });
    return { source: "native", apps: merged };
  }

  if (backendRes && Array.isArray(backendRes.apps)) {
    backendRes.apps.forEach((a) => {
      if (!a || !a.pkg || seen.has(a.pkg)) return;
      seen.add(a.pkg);
      const sel = selectedSet ? selectedSet.has(a.pkg) : Number(a.selected) === 1;
      merged.push({
        pkg: a.pkg,
        label: KNOWN_GAME_LABELS[a.pkg] || humanizePkgLabel(a.pkg),
        is_game: Number(a.is_game) === 1 || sel ? 1 : 0,
        selected: sel ? 1 : 0
      });
    });
    return { source: "backend", apps: merged };
  }

  throw new Error("Không thể đọc danh sách ứng dụng");
}
