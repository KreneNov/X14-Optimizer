import { callCtrl, getGameLabel, isDemoMode, listInstalledApps } from "./ksu-bridge.js";

const $ = (id) => document.getElementById(id);
const MIN_HYSTERESIS_GAP = 10;
const TAB_ORDER = ["dashboard", "battery", "fps", "logs"];
const SEG_ORDER = ["games", "all", "selected"];

const GAME_PROFILE_META = {
  max120: {
    pill: "Max 120FPS",
    title: "Max 120FPS",
    desc: "Full 4 cụm CPU (3.3GHz) · GPU 903MHz · Khóa 120Hz · Nới nhiệt 45°C"
  },
  cool60: {
    pill: "Mát 120Hz",
    title: "Mát máy (120Hz · GPU vừa)",
    desc: "CPU cân bằng · GPU 720MHz · Giữ khóa 120Hz mượt UI · Nới nhiệt 43°C"
  },
  eco60: {
    pill: "Treo & Tải",
    title: "Treo & Tải (60Hz)",
    desc: "CPU tiết kiệm pin · GPU 422MHz · Khóa 60Hz · Tối ưu treo máy / tải data"
  }
};

const PICKER_CONFIGS = {
  "chg-limit": {
    title: "Giới hạn dòng sạc",
    sub: "Áp dụng qua restrict_cur / constant_charge_current",
    options: [
      { value: "0", pill: "Không giới hạn", title: "Không giới hạn", desc: "Mặc định theo củ sạc & mi_thermald (Hỗ trợ 90W HyperCharge)" },
      { value: "1000", pill: "1000 mA (~5W)", title: "1000 mA", desc: "Sạc chậm qua đêm siêu mát, bảo vệ tuổi thọ pin tối đa" },
      { value: "1500", pill: "1500 mA (~7.5W)", title: "1500 mA", desc: "Sạc chậm êm ~7.5W, nhiệt độ pin rất thấp" },
      { value: "2000", pill: "2000 mA (~10W)", title: "2000 mA", desc: "Sạc vừa ~10W, cân bằng thời gian và nhiệt độ" },
      { value: "3000", pill: "3000 mA (~15–25W)", title: "3000 mA", desc: "Sạc nhanh vừa ~15–25W, ít nóng hơn sạc tối đa" }
    ]
  },
  "chg-mode": {
    title: "Phương thức ngắt sạc",
    sub: "Cơ chế chặn dòng nạp vào cell pin khi chạm ngưỡng dừng",
    options: [
      { value: "fcc", pill: "True Bypass (fcc=0)", title: "True Bypass (fcc=0) · Khuyên dùng X14", desc: "Ghi constant_charge_current=0, không nháy popup sạc, giữ 90W PPS" },
      { value: "suspend", pill: "input_suspend", title: "input_suspend", desc: "Phương thức fallback tiêu chuẩn cho các dòng máy Android khác" },
      { value: "night", pill: "night_charging", title: "night_charging (Xiaomi)", desc: "Sử dụng cờ sạc đêm qcom-battery của Xiaomi" }
    ]
  },
  "fps-pk-mode": {
    title: "Xử lý Joyose / PowerKeeper",
    sub: "Chỉ áp dụng cho chế độ Force 120Hz",
    options: [
      { value: "none", pill: "Giữ nguyên cả hai", title: "Giữ nguyên cả hai (An toàn nhất)", desc: "Không vô hiệu hóa app hệ thống, thống kê pin HyperOS chuẩn" },
      { value: "joyose", pill: "Chỉ tắt Joyose", title: "Chỉ vô hiệu hóa Joyose", desc: "Chặn Joyose bóp FPS, giữ nguyên PowerKeeper" },
      { value: "both", pill: "Tắt Joyose & PowerKeeper", title: "Vô hiệu hóa cả Joyose & PowerKeeper", desc: "Gỡ triệt để giới hạn tần số quét (có thể ảnh hưởng thống kê pin)" }
    ]
  },
  "game-bypass-min": {
    title: "Ngưỡng sàn pin Gaming Auto-Bypass",
    sub: "Chỉ cắt dòng khi đạt sàn (Hysteresis +2% chống đóng/ngắt lặp)",
    options: [
      { value: "15", pill: "15% (Sạc lại lên 17%)", title: "15%", desc: "Nếu thấp hơn 15%, tự sạc lên 17% rồi mới cắt dòng truyền thẳng" },
      { value: "20", pill: "20% — Khuyên dùng", title: "20% · Khuyên dùng", desc: "An toàn chống sụt áp đột ngột · Sạc lên 22% rồi mới cắt dòng" },
      { value: "25", pill: "25% (Sạc lại lên 27%)", title: "25%", desc: "Dư dả pin dự phòng khi rút cáp · Sạc lên 27% mới cắt dòng" },
      { value: "30", pill: "30% (Sạc lại lên 32%)", title: "30%", desc: "Giữ mức pin chờ cao hơn · Sạc lên 32% mới cắt dòng" }
    ]
  },
  "zram-size": {
    title: "Dung lượng ZRAM thuần RAM",
    sub: "Không ghi swap lên bộ nhớ UFS / Memory Extension",
    options: [
      { value: "0", pill: "0 GB (Tắt)", title: "0 GB (Tắt ZRAM)", desc: "Vô hiệu hóa ZRAM và trả vm.swappiness về 60" },
      { value: "4", pill: "4 GB", title: "4 GB", desc: "Nhẹ nhàng, tiết kiệm chu kỳ CPU nén trên máy dùng cơ bản" },
      { value: "6", pill: "6 GB · Khuyên dùng", title: "6 GB · Khuyên dùng cho 12GB RAM", desc: "Giữ mượt đa nhiệm HSR + Liên Quân + WebUI không bị văng nền" },
      { value: "8", pill: "8 GB (Đa nhiệm nặng)", title: "8 GB", desc: "Không gian nén lớn cho đa nhiệm nhiều game nặng cùng lúc" }
    ]
  },
  "zram-algo": {
    title: "Thuật toán nén ZRAM",
    sub: "Hỗ trợ trực tiếp từ kernel Xiaomi 14 (houji)",
    options: [
      { value: "lz4", pill: "lz4 (Nhanh nhất)", title: "lz4 · Ưu tiên tốc độ 120FPS", desc: "Độ trễ nén/giải nén cực thấp, giữ frametime game ổn định nhất" },
      { value: "zstd", pill: "zstd (Nén sâu)", title: "zstd · Ưu tiên tỷ lệ nén", desc: "Tiết kiệm RAM thực nhiều hơn, giữ thêm ứng dụng nền" }
    ]
  }
};

const pickerValues = {
  "chg-limit": "0",
  "chg-mode": "fcc",
  "fps-pk-mode": "none",
  "game-bypass-min": "20",
  "zram-size": "6",
  "zram-algo": "lz4"
};

let pollTimer = null;
let configDirty = false;
let isDraggingSlider = false;
let currentTopupOnce = false;
let currentTabIndex = 0;
let selectedGames = [];
let cachedApps = null;
let cachedAppSource = "";
let pickerFilter = "games";
let pickerToggleQueue = Promise.resolve();
let activeSheetTrigger = null;
let activeSheetOnSelect = null;

const CHECK_SVG = `<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="20 6 9 17 4 12"></polyline></svg>`;
const CHEVRON_SM_SVG = `<svg class="sheet-chevron" viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="6 9 12 15 18 9"></polyline></svg>`;
const TRASH_SVG = `<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>`;

function formatTempX10(val) {
  if (!val || Number(val) <= 0) return "--.-°C";
  return `${(Number(val) / 10).toFixed(1)}°C`;
}

function updateModalBodyLock() {
  const sheetOpen = $("sheet-picker-modal").classList.contains("is-open");
  const appOpen = $("app-picker-modal").classList.contains("is-open");
  document.body.classList.toggle("modal-open", sheetOpen || appOpen);
}

function syncTopupButton(enabled) {
  currentTopupOnce = Boolean(enabled);
  const topupBtn = $("btn-topup-once");
  topupBtn.classList.toggle("active", currentTopupOnce);
  topupBtn.textContent = currentTopupOnce
    ? "Đang bật Sạc đầy 1 lần (100%) · Bấm để hủy"
    : "Bật Sạc đầy 1 lần (100%)";
}

function showToast(msg) {
  const el = $("toast");
  $("toast-text").textContent = msg;
  el.setAttribute("aria-hidden", "false");
  el.classList.add("is-visible");
  clearTimeout(showToast._t);
  showToast._t = setTimeout(() => {
    el.classList.remove("is-visible");
    el.setAttribute("aria-hidden", "true");
  }, 2600);
}

function applyTheme(mode) {
  if (mode === "light" || mode === "dark") {
    document.documentElement.setAttribute("data-theme", mode);
    localStorage.setItem("x14_theme", mode);
  } else {
    document.documentElement.removeAttribute("data-theme");
    localStorage.removeItem("x14_theme");
  }
}

function initTheme() {
  const saved = localStorage.getItem("x14_theme");
  if (saved) applyTheme(saved);
  $("btn-theme").addEventListener("click", () => {
    const cur = document.documentElement.getAttribute("data-theme");
    const isDarkNow = cur === "dark" || (!cur && window.matchMedia("(prefers-color-scheme: dark)").matches);
    const next = isDarkNow ? "light" : "dark";
    applyTheme(next);
    showToast(next === "dark" ? "Đã chuyển giao diện Tối" : "Đã chuyển giao diện Sáng");
  });
}

/* DIRECTIONAL TAB MORPHING & SLIDING BOTTOM NAV INDICATOR */
function switchTab(tabName) {
  const nextIndex = TAB_ORDER.indexOf(tabName);
  if (nextIndex === -1) return;
  const prevIndex = currentTabIndex;
  currentTabIndex = nextIndex;

  $("nav-indicator").style.setProperty("--tab-index", String(nextIndex));

  document.querySelectorAll(".nav-btn").forEach((b) => {
    b.classList.toggle("active", b.dataset.tab === tabName);
  });

  const targetPanel = $(`panel-${tabName}`);
  document.querySelectorAll(".tab-panel").forEach((p) => {
    p.classList.remove("active", "enter-from-right", "enter-from-left");
  });

  if (targetPanel) {
    targetPanel.classList.add("active");
    if (prevIndex !== nextIndex) {
      void targetPanel.offsetWidth;
      targetPanel.classList.add(nextIndex > prevIndex ? "enter-from-right" : "enter-from-left");
    }
  }

  if (tabName === "logs") {
    loadLogs();
  } else if (tabName === "fps") {
    loadGames();
  }
}

/* SHARED GLASSMORPHIC TACTILE BOTTOM SHEET PICKER */
function setPickerValue(key, val) {
  const strVal = String(val);
  pickerValues[key] = strVal;
  const cfg = PICKER_CONFIGS[key];
  const trigger = $(`trigger-${key}`);
  if (!cfg || !trigger) return;
  const hit = cfg.options.find((o) => o.value === strVal);
  const labelText = hit ? hit.pill : (key === "game-bypass-min" ? `${strVal}%` : strVal);
  const span = trigger.querySelector(".sheet-trigger-text");
  if (span) span.textContent = labelText;
}

function getPickerValue(key) {
  return pickerValues[key];
}

function openBottomSheet({ title, sub = "", options, currentValue, triggerEl, onSelect }) {
  if (activeSheetTrigger) {
    activeSheetTrigger.classList.remove("is-open");
    activeSheetTrigger.setAttribute("aria-expanded", "false");
  }
  activeSheetTrigger = triggerEl || null;
  activeSheetOnSelect = onSelect;

  if (activeSheetTrigger) {
    activeSheetTrigger.classList.add("is-open");
    activeSheetTrigger.setAttribute("aria-expanded", "true");
  }

  $("sheet-title").textContent = title;
  $("sheet-sub").textContent = sub;
  $("sheet-sub").classList.toggle("hidden", !sub);

  const list = $("sheet-options");
  list.textContent = "";

  options.forEach((opt) => {
    const isSel = String(opt.value) === String(currentValue);
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = isSel ? "sheet-option is-selected" : "sheet-option";
    btn.setAttribute("role", "option");
    btn.setAttribute("aria-selected", isSel ? "true" : "false");

    const copy = document.createElement("div");
    copy.className = "sheet-opt-copy";

    const t = document.createElement("span");
    t.className = "sheet-opt-title";
    t.textContent = opt.title;
    copy.appendChild(t);

    if (opt.desc) {
      const d = document.createElement("span");
      d.className = "sheet-opt-desc";
      d.textContent = opt.desc;
      copy.appendChild(d);
    }

    const chk = document.createElement("span");
    chk.className = "sheet-opt-check";
    chk.innerHTML = CHECK_SVG;

    btn.appendChild(copy);
    btn.appendChild(chk);

    btn.addEventListener("click", () => {
      const cb = activeSheetOnSelect;
      closeBottomSheet();
      if (cb) cb(opt.value, opt);
    });

    list.appendChild(btn);
  });

  const panel = $("sheet-panel");
  panel.style.transform = "";
  const modal = $("sheet-picker-modal");
  modal.setAttribute("aria-hidden", "false");
  modal.classList.add("is-open");
  updateModalBodyLock();
}

function closeBottomSheet() {
  const modal = $("sheet-picker-modal");
  const panel = $("sheet-panel");
  panel.classList.remove("is-dragging");
  panel.style.transform = "";
  modal.classList.remove("is-open");
  modal.setAttribute("aria-hidden", "true");
  if (activeSheetTrigger) {
    activeSheetTrigger.classList.remove("is-open");
    activeSheetTrigger.setAttribute("aria-expanded", "false");
    activeSheetTrigger = null;
  }
  activeSheetOnSelect = null;
  updateModalBodyLock();
}

function initSheetSwipeDismiss() {
  const dragZone = $("sheet-drag-zone");
  const panel = $("sheet-panel");
  let startY = 0;
  let currentDy = 0;
  let dragging = false;

  dragZone.addEventListener("touchstart", (e) => {
    if (!e.touches.length) return;
    startY = e.touches[0].clientY;
    currentDy = 0;
    dragging = true;
    panel.classList.add("is-dragging");
  }, { passive: true });

  dragZone.addEventListener("touchmove", (e) => {
    if (!dragging || !e.touches.length) return;
    currentDy = Math.max(0, e.touches[0].clientY - startY);
    panel.style.transform = `translate3d(0, ${currentDy}px, 0)`;
  }, { passive: true });

  const finishDrag = () => {
    if (!dragging) return;
    dragging = false;
    panel.classList.remove("is-dragging");
    if (currentDy > 72) {
      closeBottomSheet();
    } else {
      panel.style.transform = "";
    }
  };
  dragZone.addEventListener("touchend", finishDrag);
  dragZone.addEventListener("touchcancel", finishDrag);
}

function openStandardPicker(key, triggerEl) {
  if (key === "thm-warn" || key === "thm-crit") {
    const isWarn = key === "thm-warn";
    const min = isWarn ? 38 : 42;
    const max = isWarn ? 45 : 49;
    const cur = Number($(key).value);
    const options = [];
    for (let deg = min; deg <= max; deg++) {
      const boardDeg = deg + 3;
      options.push({
        value: String(deg),
        title: `${deg}°C (Pin) · ${boardDeg}°C (Bo mạch)`,
        desc: isWarn
          ? (deg === 42 ? "Mức cân bằng khuyên dùng cho hằng ngày" : "Nhả Force 120Hz / hạ nhẹ xung GPU khi chạm ngưỡng")
          : (deg === 45 ? "Mức bảo vệ chuẩn an toàn cho pin & linh kiện" : "Khóa 60Hz, siết xung và tạm dừng sạc để hạ nhiệt nhanh")
      });
    }
    openBottomSheet({
      title: isWarn ? "Ngưỡng Warn (Thermal Guard)" : "Ngưỡng Critical (Thermal Guard)",
      sub: "Áp dụng cho chế độ hằng ngày (Gaming giữ ngưỡng 44°C / 46°C)",
      options,
      currentValue: String(cur),
      triggerEl,
      onSelect: (val) => {
        configDirty = true;
        const num = Number(val);
        $(key).value = String(num);
        if (isWarn) {
          $("thm-warn-val").querySelector("span").textContent = `${num}°C`;
          const cEl = $("thm-crit");
          if (Number(cEl.value) <= num) {
            const nextC = Math.min(49, num + 2);
            cEl.value = String(nextC);
            $("thm-crit-val").querySelector("span").textContent = `${nextC}°C`;
          }
        } else {
          const w = Number($("thm-warn").value);
          const safeC = Math.max(w + 1, num);
          $("thm-crit").value = String(safeC);
          $("thm-crit-val").querySelector("span").textContent = `${safeC}°C`;
        }
      }
    });
    return;
  }

  const cfg = PICKER_CONFIGS[key];
  if (!cfg) return;
  const curVal = getPickerValue(key);
  let options = cfg.options;
  if (key === "game-bypass-min" && !options.some((o) => o.value === curVal)) {
    options = [
      ...options,
      { value: curVal, pill: `${curVal}%`, title: `${curVal}% (Tùy chỉnh)`, desc: `Sạc lên ${Math.min(100, Number(curVal) + 2)}% rồi mới cắt dòng` }
    ];
  }

  openBottomSheet({
    title: cfg.title,
    sub: cfg.sub,
    options,
    currentValue: curVal,
    triggerEl,
    onSelect: (val) => {
      setPickerValue(key, val);
      handlePickerChange(key, val);
    }
  });
}

function handlePickerChange(key, val) {
  if (key === "game-bypass-min") {
    const en = $("game-bypass-enabled").checked ? "1" : "0";
    runAction(null, "", async () => {
      await callCtrl("set-game-bypass", [en, val]);
      await refreshStatus();
      showToast(en === "1"
        ? `Gaming Auto-Bypass: sàn pin ${val}%`
        : `Đã lưu sàn pin ${val}% (đang tắt)`);
    });
    return;
  }

  configDirty = true;
  if (key === "chg-mode") {
    updateChargeCallout(Number($("chg-stop").value), Number($("chg-resume").value), val);
  } else if (key === "zram-size") {
    $("zram-enabled").checked = val !== "0";
  }
}

/* RENDERERS */
function renderClusters(clusters) {
  const list = $("cpu-cluster-list");
  list.textContent = "";
  (clusters || []).forEach((c) => {
    const row = document.createElement("div");
    row.className = "cluster-row";

    const top = document.createElement("div");
    top.className = "cluster-top";

    const title = document.createElement("span");
    const tag = c.is_little ? " · Race-to-Idle" : "";
    title.textContent = `${c.name} (CPU ${c.cpus}${tag})`;

    const freq = document.createElement("span");
    freq.className = "mono";
    const curMhz = Math.round(c.cur_khz / 1000);
    const maxMhz = Math.round(c.max_khz / 1000);
    const hwMhz = Math.round(c.cpuinfo_max_khz / 1000);
    freq.textContent = `${curMhz} / ${maxMhz} MHz (HW ${hwMhz})`;

    top.appendChild(title);
    top.appendChild(freq);

    const barBg = document.createElement("div");
    barBg.className = "cluster-bar-bg";
    const barFill = document.createElement("div");
    barFill.className = "cluster-bar-fill";
    const ratio = c.cpuinfo_max_khz > 0 ? Math.min(1, Math.max(0.04, c.cur_khz / c.cpuinfo_max_khz)) : 0.04;
    barFill.style.transform = `scaleX(${ratio.toFixed(3)})`;
    barBg.appendChild(barFill);

    row.appendChild(top);
    row.appendChild(barBg);
    list.appendChild(row);
  });
}

function renderCapabilities(caps) {
  const grid = $("cap-grid");
  grid.textContent = "";
  const items = [
    ["qcom-battery", caps.has_qcom_batt ? "OK" : "Fallback", false],
    ["mi_thermald", caps.has_mi_thermal ? "OK" : "No", false],
    ["Adreno KGSL", caps.has_kgsl ? "OK" : "No", false],
    ["inotifyd Wake", caps.has_inotifyd ? "OK" : "Polling", false],
    ["cpu_nolimit", caps.has_cpu_nolimit ? "OK" : "No", false],
    ["Overlay FPS", caps.overlay_fps_xml ? "Patched" : "Stock", false],
    ["ZRAM thuần RAM", caps.has_zram ? "OK" : "No", false],
    ["Node sạc", caps.charge_node || "None", true]
  ];
  items.forEach(([k, v, wide]) => {
    const box = document.createElement("div");
    box.className = wide ? "cap-item cap-wide" : "cap-item";
    const kl = document.createElement("span");
    kl.textContent = k;
    const vl = document.createElement("strong");
    vl.textContent = v;
    vl.title = v;
    box.appendChild(kl);
    box.appendChild(vl);
    grid.appendChild(box);
  });
}

function updateChargeCallout(stop, resume, mode) {
  $("chg-gap-hint").textContent = `Khoảng cách an toàn: ${stop - resume}% (tối thiểu ${MIN_HYSTERESIS_GAP}%)`;
  $("callout-stop-pct").textContent = `${stop}%`;
  $("callout-resume-pct").textContent = `${resume}%`;
  const nodeLabel = mode === "fcc"
    ? "constant_charge_current=0"
    : mode === "night"
      ? "night_charging=1"
      : "input_suspend=1";
  $("callout-bypass-node").textContent = nodeLabel;
}

function syncFormFromConfig(cfg) {
  if (!cfg || configDirty || isDraggingSlider) return;

  document.querySelectorAll(".choice-btn").forEach((b) => {
    b.classList.toggle("active", b.dataset.profile === cfg.profile);
  });

  $("chg-enabled").checked = Number(cfg.charge_enabled) === 1;
  $("chg-stop").value = cfg.charge_stop_pct;
  $("chg-stop-val").textContent = `${cfg.charge_stop_pct}%`;
  $("chg-resume").value = cfg.charge_resume_pct;
  $("chg-resume-val").textContent = `${cfg.charge_resume_pct}%`;
  setPickerValue("chg-limit", String(cfg.charge_limit_ma));
  setPickerValue("chg-mode", cfg.charge_mode);
  updateChargeCallout(Number(cfg.charge_stop_pct), Number(cfg.charge_resume_pct), cfg.charge_mode);

  $("soff-enabled").checked = Number(cfg.screen_off_enabled) === 1;
  $("soff-debounce").value = cfg.screen_off_debounce;
  $("soff-debounce-val").textContent = `${cfg.screen_off_debounce}s`;
  $("soff-doze").checked = Number(cfg.screen_off_doze) === 1;

  document.querySelectorAll('input[name="fps-mode"]').forEach((r) => {
    r.checked = r.value === cfg.fps_mode;
  });
  setPickerValue("fps-pk-mode", cfg.fps_pk_mode || "none");
  $("force-pk-box").classList.toggle("hidden", cfg.fps_mode !== "force120");

  $("thm-enabled").checked = Number(cfg.thermal_guard_enabled) === 1;
  $("thm-warn").value = cfg.thermal_warn_c;
  $("thm-warn-val").querySelector("span").textContent = `${cfg.thermal_warn_c}°C`;
  $("thm-crit").value = cfg.thermal_crit_c;
  $("thm-crit-val").querySelector("span").textContent = `${cfg.thermal_crit_c}°C`;

  $("auto-game-enabled").checked = Number(cfg.auto_game_enabled) === 1;
  $("joyose-disabled").checked = Number(cfg.joyose_disabled) === 1;
  $("game-bypass-enabled").checked = Number(cfg.game_auto_bypass) === 1;
  setPickerValue("game-bypass-min", String(cfg.game_bypass_min_pct || 20));

  const zramEn = Number(cfg.zram_enabled) === 1 && Number(cfg.zram_size_gb) > 0;
  $("zram-enabled").checked = zramEn;
  setPickerValue("zram-size", String(zramEn ? (cfg.zram_size_gb || 6) : 0));
  setPickerValue("zram-algo", cfg.zram_algo || "lz4");
}

function formatTriggerSource(trig) {
  switch (trig) {
    case "batt": return "PIN";
    case "board": return "BO MẠCH";
    case "both": return "PIN+BO";
    default: return "";
  }
}

function renderStatus(data) {
  if (!data) return;
  $("demo-badge").classList.toggle("hidden", !isDemoMode());
  $("device-badge").textContent = data.device.codename || "android";

  const dot = $("daemon-dot");
  dot.className = "brand-dot";
  if (!data.daemon.running) {
    $("daemon-sub").textContent = "Daemon đang dừng";
  } else {
    const tstate = data.thermals.guard_state;
    dot.classList.add(tstate === "critical" ? "crit" : tstate === "warn" ? "warn" : "online");
    const wakeTag = data.daemon.inotify_active ? "Zero-Lag inotifyd" : "Adaptive Polling";
    $("daemon-sub").textContent = `Daemon PID ${data.daemon.pid} · ${wakeTag}`;
  }

  const b = data.battery;
  $("batt-pct").textContent = `${b.capacity}%`;
  const sign = b.current_ma > 0 ? "+" : "";
  $("batt-meta").textContent = `${b.voltage_mv} mV · ${sign}${b.current_ma} mA`;
  $("batt-health").textContent = `SOH ${b.soh}% · ${b.cycle_count} chu kỳ`;

  const cBadge = $("charge-state-badge");
  cBadge.className = "badge";
  syncTopupButton(Number(b.topup_once) === 1);

  if (Number(b.game_bypass_active) === 1) {
    cBadge.textContent = "GAMING BYPASS";
    cBadge.classList.add("badge-ok");
  } else if (b.charging_paused) {
    cBadge.textContent = "NGẮT SẠC (BYPASS)";
    cBadge.classList.add("badge-ok");
  } else if (currentTopupOnce && (b.usb_online || b.wls_online)) {
    cBadge.textContent = "SẠC ĐẦY 1 LẦN (100%)";
    cBadge.classList.add("badge-warn");
  } else if (b.usb_online || b.wls_online) {
    cBadge.textContent = b.status === "Full" ? "ĐẦY" : "ĐANG SẠC";
  } else {
    cBadge.textContent = currentTopupOnce ? "CHỜ CẮM SẠC (100%)" : "XẢ PIN";
    cBadge.classList.add(currentTopupOnce ? "badge-warn" : "badge-muted");
  }

  const t = data.thermals;
  $("temp-batt").textContent = formatTempX10(t.batt_x10);
  $("temp-skin").textContent = `Vỏ: ${formatTempX10(t.skin_x10)} · Bo: ${formatTempX10(t.board_x10)}`;
  $("temp-soc").textContent = `CPU: ${formatTempX10(t.cpu_x10)} · GPU: ${formatTempX10(t.gpu_x10)}`;

  const tBadge = $("thermal-state-badge");
  tBadge.className = "badge";
  const stateLabel = String(t.guard_state || "normal").toUpperCase();
  const trigLabel = formatTriggerSource(t.guard_trigger);
  tBadge.textContent = (t.guard_state !== "normal" && trigLabel)
    ? `${stateLabel} · ${trigLabel}`
    : stateLabel;
  if (t.guard_state === "critical") tBadge.classList.add("badge-danger");
  else if (t.guard_state === "warn") tBadge.classList.add("badge-warn");
  else tBadge.classList.add("badge-ok");

  const d = data.display;
  $("disp-dyn-fps").textContent = d.dynamic_fps > 0 ? `${d.dynamic_fps} Hz` : "-- Hz";
  const peakLabel = (!d.peak_rr || d.peak_rr === "null") ? "Auto" : d.peak_rr;
  const minLabel = (!d.min_rr || d.min_rr === "null") ? "Auto (LTPO)" : d.min_rr;
  $("disp-rr-bounds").textContent = `${peakLabel} / ${minLabel}`;
  $("disp-game-cap").textContent = d.game_cap_disabled ? "Đã mở" : "Khóa 60";
  const g = data.gaming || { active: 0, mode: "off", profile: "none", pkg: "", cpu_nolimit_temp: 0 };
  const gProfTag = g.profile && g.profile !== "none" ? g.profile : "max120";
  $("fps-mode-badge").textContent = g.active ? `gaming (${gProfTag})` : data.config.fps_mode;
  $("fps-tab-badge").textContent = g.active ? `gaming (${gProfTag})` : data.config.fps_mode;

  const agBadge = $("autogame-state-badge");
  agBadge.className = "badge";
  if (g.active) {
    agBadge.classList.add("badge-warn");
    agBadge.textContent = g.mode === "auto" && g.pkg ? `${gProfTag.toUpperCase()} · ${g.pkg}` : "MANUAL GAMING";
  } else {
    agBadge.classList.add("badge-muted");
    agBadge.textContent = Number(data.config.auto_game_enabled) === 1 ? "STANDBY" : "OFF";
  }

  $("active-profile-badge").textContent = g.active && data.config.profile !== "gaming"
    ? `${data.config.profile} -> ${gProfTag}`
    : data.config.profile;
  $("gpu-badge").textContent = `${data.gpu.model} · ${data.gpu.cur_mhz}/${data.gpu.max_mhz} MHz`;

  const z = data.zram || { active: 0, algo: "none", disk_mb: 0, orig_mb: 0, mem_mb: 0, ratio_x100: 0, backing_dev: "none" };
  const zBadge = $("zram-state-badge");
  zBadge.className = "badge mono";
  if (z.active && z.disk_mb > 0) {
    const gb = Math.round(z.disk_mb / 1024);
    zBadge.textContent = `${gb} GB · ${String(z.algo || "lz4").toUpperCase()}`;
    zBadge.classList.add("badge-ok");
    $("zram-disk").textContent = `${z.disk_mb} MB`;
    $("zram-usage").textContent = `${z.orig_mb} / ${z.mem_mb} MB`;
    $("zram-ratio").textContent = z.ratio_x100 > 0
      ? `${(z.ratio_x100 / 100).toFixed(2)}x · ${z.algo}`
      : `-- · ${z.algo}`;
  } else {
    zBadge.textContent = "OFF";
    zBadge.classList.add("badge-muted");
    $("zram-disk").textContent = "Tắt";
    $("zram-usage").textContent = "0 / 0 MB";
    $("zram-ratio").textContent = "--";
  }

  renderClusters(data.cpu);
  renderCapabilities(data.capabilities);
  syncFormFromConfig(data.config);
}

function stopPolling() {
  clearTimeout(pollTimer);
  pollTimer = null;
}

function scheduleNextPoll() {
  stopPolling();
  if (document.visibilityState === "visible") {
    pollTimer = setTimeout(async () => {
      await refreshStatus();
      scheduleNextPoll();
    }, 3000);
  }
}

async function refreshStatus() {
  try {
    const res = await callCtrl("status");
    if (res) renderStatus(res);
  } catch (err) {
    $("daemon-sub").textContent = `Lỗi: ${err.message}`;
  }
}

async function runAction(btn, loadingLabel, fn) {
  stopPolling();
  const origText = btn ? btn.textContent : "";
  if (btn) {
    btn.disabled = true;
    if (loadingLabel) btn.textContent = loadingLabel;
  }
  try {
    await fn();
  } catch (err) {
    showToast(`Lỗi: ${err.message}`);
  } finally {
    if (btn) {
      btn.disabled = false;
      if (loadingLabel && btn.textContent === loadingLabel) {
        btn.textContent = origText;
      }
    }
    scheduleNextPoll();
  }
}

async function loadLogs() {
  const box = $("log-output");
  try {
    const res = await callCtrl("get-logs", ["80"]);
    box.textContent = res.lines && res.lines.length ? res.lines.join("\n") : "(Chưa có nhật ký)";
    box.scrollTop = box.scrollHeight;
  } catch (err) {
    box.textContent = `Không thể đọc log: ${err.message}`;
  }
}

/* PER-GAME PROFILE LIST WITH COMPACT GLASS PILL + BOTTOM SHEET */
function normalizeGamesList(games) {
  if (!Array.isArray(games)) return [];
  return games.map((g) => {
    if (typeof g === "string") return { pkg: g, profile: "max120" };
    return { pkg: g.pkg, profile: GAME_PROFILE_META[g.profile] ? g.profile : "max120" };
  }).filter((g) => Boolean(g.pkg));
}

function selectedPkgSet() {
  return new Set(selectedGames.map((g) => g.pkg));
}

function resolveGameTitle(pkg) {
  if (cachedApps) {
    const hit = cachedApps.find((a) => a.pkg === pkg);
    if (hit && hit.label) return hit.label;
  }
  return getGameLabel(pkg);
}

function renderGameList(games) {
  selectedGames = normalizeGamesList(games);
  $("game-count-badge").textContent = `${selectedGames.length} app`;
  $("picker-selected-count").textContent = `${selectedGames.length} đã chọn`;

  const list = $("game-list");
  list.textContent = "";
  if (!selectedGames.length) {
    const empty = document.createElement("div");
    empty.className = "help-text";
    empty.textContent = "(Chưa có package game nào trong danh sách)";
    list.appendChild(empty);
    return;
  }

  const profileOptions = Object.entries(GAME_PROFILE_META).map(([value, meta]) => ({
    value,
    title: meta.title,
    desc: meta.desc
  }));

  selectedGames.forEach((item) => {
    const { pkg, profile } = item;
    const meta = GAME_PROFILE_META[profile] || GAME_PROFILE_META.max120;
    const displayName = resolveGameTitle(pkg);

    const row = document.createElement("div");
    row.className = "game-item";

    const info = document.createElement("div");
    info.className = "game-item-info";

    const title = document.createElement("span");
    title.className = "game-item-title";
    title.textContent = displayName;
    title.title = displayName;

    const name = document.createElement("span");
    name.className = "game-pkg mono";
    name.textContent = pkg;
    name.title = pkg;

    info.appendChild(title);
    info.appendChild(name);

    const actions = document.createElement("div");
    actions.className = "game-item-actions";

    const profBtn = document.createElement("button");
    profBtn.type = "button";
    profBtn.className = `game-prof-pill prof-${profile}`;
    profBtn.setAttribute("aria-haspopup", "dialog");
    profBtn.setAttribute("aria-expanded", "false");
    profBtn.setAttribute("aria-label", `Chọn hồ sơ cho ${displayName}`);
    const profLabelSpan = document.createElement("span");
    profLabelSpan.textContent = meta.pill;
    profBtn.appendChild(profLabelSpan);
    profBtn.insertAdjacentHTML("beforeend", CHEVRON_SM_SVG);

    profBtn.addEventListener("click", () => {
      openBottomSheet({
        title: displayName,
        sub: pkg,
        options: profileOptions,
        currentValue: profile,
        triggerEl: profBtn,
        onSelect: (nextProf) => {
          if (nextProf === profile) return;
          runAction(null, "", async () => {
            const res = await callCtrl("set-game-profile", [pkg, nextProf]);
            renderGameList(res.games);
            await refreshStatus();
            const nextMeta = GAME_PROFILE_META[nextProf] || GAME_PROFILE_META.max120;
            showToast(`${displayName}: ${nextMeta.title}`);
          });
        }
      });
    });

    const delBtn = document.createElement("button");
    delBtn.type = "button";
    delBtn.className = "btn-pkg-icon";
    delBtn.innerHTML = TRASH_SVG;
    delBtn.setAttribute("aria-label", `Xóa ${displayName}`);
    delBtn.title = "Xóa khỏi danh sách";
    delBtn.addEventListener("click", () => {
      runAction(delBtn, "", async () => {
        const res = await callCtrl("remove-game", [pkg]);
        renderGameList(res.games);
        if ($("app-picker-modal").classList.contains("is-open")) {
          renderPickerList();
        }
        showToast(`Đã xóa ${displayName}`);
      });
    });

    actions.appendChild(profBtn);
    actions.appendChild(delBtn);
    row.appendChild(info);
    row.appendChild(actions);
    list.appendChild(row);
  });
}

async function loadGames() {
  try {
    const res = await callCtrl("list-games");
    if (res && Array.isArray(res.games)) {
      renderGameList(res.games);
    }
  } catch (err) {
    $("game-list").textContent = `Không thể tải danh sách game: ${err.message}`;
  }
}

/* UPGRADED APP PICKER MODAL */
function updatePickerFilterTabs(apps, selectedSet) {
  const gamesCount = apps.filter((a) => a.is_game).length;
  const selCount = apps.filter((a) => selectedSet.has(a.pkg)).length;
  $("tab-filter-games").textContent = `Game (${gamesCount})`;
  $("tab-filter-all").textContent = `Tất cả (${apps.length})`;
  $("tab-filter-selected").textContent = `Đã chọn (${selCount})`;

  const segIdx = Math.max(0, SEG_ORDER.indexOf(pickerFilter));
  $("seg-indicator").style.setProperty("--seg-index", String(segIdx));

  document.querySelectorAll(".seg-btn").forEach((b) => {
    const active = b.dataset.filter === pickerFilter;
    b.classList.toggle("active", active);
    b.setAttribute("aria-selected", active ? "true" : "false");
  });
}

function togglePickerPackage(pkg, checked) {
  pickerToggleQueue = pickerToggleQueue.then(async () => {
    const res = await callCtrl(checked ? "add-game" : "remove-game", [pkg]);
    renderGameList(res.games);
  }).catch((err) => {
    showToast(`Lỗi: ${err.message}`);
  });
  return pickerToggleQueue;
}

function renderPickerList() {
  const box = $("picker-list");
  const searchVal = $("picker-search").value;
  $("btn-picker-clear").classList.toggle("hidden", !searchVal);

  if (!cachedApps) {
    box.textContent = "Đang tải danh sách ứng dụng...";
    return;
  }

  const selectedSet = selectedPkgSet();
  const query = searchVal.trim().toLowerCase();
  updatePickerFilterTabs(cachedApps, selectedSet);

  const filtered = cachedApps.filter((a) => {
    if (pickerFilter === "games" && !a.is_game && !selectedSet.has(a.pkg)) return false;
    if (pickerFilter === "selected" && !selectedSet.has(a.pkg)) return false;
    if (query) {
      return a.label.toLowerCase().includes(query) || a.pkg.toLowerCase().includes(query);
    }
    return true;
  });

  filtered.sort((a, b) => {
    const sa = selectedSet.has(a.pkg) ? 1 : 0;
    const sb = selectedSet.has(b.pkg) ? 1 : 0;
    if (sa !== sb) return sb - sa;
    if (a.is_game !== b.is_game) return b.is_game - a.is_game;
    return a.label.localeCompare(b.label, "vi");
  });

  box.textContent = "";
  if (!filtered.length) {
    const empty = document.createElement("div");
    empty.className = "help-text";
    empty.textContent = pickerFilter === "selected"
      ? "Chưa có ứng dụng nào được chọn."
      : "Không tìm thấy ứng dụng phù hợp.";
    box.appendChild(empty);
    return;
  }

  filtered.forEach((app) => {
    const isSel = selectedSet.has(app.pkg);
    const row = document.createElement("label");
    row.className = isSel ? "picker-item is-selected" : "picker-item";

    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.checked = isSel;

    const chkBox = document.createElement("span");
    chkBox.className = "picker-check";
    chkBox.innerHTML = CHECK_SVG;

    cb.addEventListener("change", () => {
      row.classList.toggle("is-selected", cb.checked);
      if (cb.checked) {
        if (!selectedGames.some((g) => g.pkg === app.pkg)) {
          selectedGames = [...selectedGames, { pkg: app.pkg, profile: "max120" }];
        }
      } else {
        selectedGames = selectedGames.filter((g) => g.pkg !== app.pkg);
      }
      $("game-count-badge").textContent = `${selectedGames.length} app`;
      $("picker-selected-count").textContent = `${selectedGames.length} đã chọn`;
      updatePickerFilterTabs(cachedApps, selectedPkgSet());
      togglePickerPackage(app.pkg, cb.checked);
    });

    const info = document.createElement("div");
    info.className = "picker-info";

    const nameRow = document.createElement("div");
    nameRow.className = "picker-name-row";

    const labelEl = document.createElement("span");
    labelEl.className = "picker-label";
    labelEl.textContent = app.label;
    nameRow.appendChild(labelEl);

    if (app.is_game) {
      const badge = document.createElement("span");
      badge.className = "badge badge-ok";
      badge.textContent = "GAME";
      nameRow.appendChild(badge);
    }

    const pkgEl = document.createElement("span");
    pkgEl.className = "picker-pkg mono";
    pkgEl.textContent = app.pkg;

    info.appendChild(nameRow);
    info.appendChild(pkgEl);
    row.appendChild(cb);
    row.appendChild(chkBox);
    row.appendChild(info);
    box.appendChild(row);
  });
}

async function openAppPicker(forceRefresh = false) {
  const modal = $("app-picker-modal");
  modal.setAttribute("aria-hidden", "false");
  modal.classList.add("is-open");
  updateModalBodyLock();
  $("picker-selected-count").textContent = `${selectedGames.length} đã chọn`;

  if (!cachedApps || forceRefresh) {
    $("picker-source-hint").textContent = "Đang quét ứng dụng trên máy...";
    $("picker-list").textContent = "Đang tải...";
    try {
      const res = await listInstalledApps(selectedPkgSet());
      cachedApps = res.apps;
      cachedAppSource = res.source;
      $("picker-source-hint").textContent = cachedAppSource === "native"
        ? `Nguồn: KSU Native API (${cachedApps.length} ứng dụng)`
        : cachedAppSource === "demo"
          ? `Nguồn: Chế độ Demo (${cachedApps.length} ứng dụng)`
          : `Nguồn: Package Manager (${cachedApps.length} ứng dụng)`;
      renderPickerList();
    } catch (err) {
      $("picker-source-hint").textContent = `Lỗi: ${err.message}`;
      $("picker-list").textContent = `Không thể lấy danh sách ứng dụng: ${err.message}`;
    }
  } else {
    renderPickerList();
  }
}

function closeAppPicker() {
  const modal = $("app-picker-modal");
  modal.classList.remove("is-open");
  modal.setAttribute("aria-hidden", "true");
  updateModalBodyLock();
}

/* EVENT BINDINGS */
function bindEvents() {
  document.querySelectorAll(".nav-btn").forEach((btn) => {
    btn.addEventListener("click", () => switchTab(btn.dataset.tab));
  });

  // Bind all Glassmorphic Bottom Sheet Picker triggers
  document.querySelectorAll("[data-picker]").forEach((btn) => {
    btn.addEventListener("click", () => openStandardPicker(btn.dataset.picker, btn));
  });

  $("btn-close-sheet").addEventListener("click", closeBottomSheet);
  $("sheet-picker-modal").addEventListener("click", (e) => {
    if (e.target === $("sheet-picker-modal")) closeBottomSheet();
  });
  initSheetSwipeDismiss();

  $("btn-refresh").addEventListener("click", () => {
    runAction($("btn-refresh"), "", async () => {
      configDirty = false;
      await refreshStatus();
      showToast("Đã làm mới thông số");
    });
  });

  document.querySelectorAll(".choice-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      runAction(btn, "", async () => {
        configDirty = false;
        await callCtrl("set-profile", [btn.dataset.profile]);
        await refreshStatus();
        showToast(`Đã áp dụng profile: ${btn.dataset.profile}`);
      });
    });
  });

  // Lock DOM polling sync while dragging any range slider in Android WebView
  document.querySelectorAll('input[type="range"]').forEach((el) => {
    el.addEventListener("pointerdown", () => { isDraggingSlider = true; });
    el.addEventListener("touchstart", () => { isDraggingSlider = true; }, { passive: true });
  });
  const releaseSlider = () => { isDraggingSlider = false; };
  window.addEventListener("pointerup", releaseSlider);
  window.addEventListener("pointercancel", releaseSlider);
  window.addEventListener("touchend", releaseSlider);
  window.addEventListener("touchcancel", releaseSlider);

  const markDirty = () => { configDirty = true; };

  $("chg-stop").addEventListener("input", () => {
    markDirty();
    const stop = Number($("chg-stop").value);
    const resEl = $("chg-resume");
    let res = Number(resEl.value);
    if (stop - res < MIN_HYSTERESIS_GAP) {
      res = Math.max(40, stop - MIN_HYSTERESIS_GAP);
      resEl.value = String(res);
      $("chg-resume-val").textContent = `${res}%`;
    }
    $("chg-stop-val").textContent = `${stop}%`;
    updateChargeCallout(stop, res, getPickerValue("chg-mode"));
  });

  $("chg-resume").addEventListener("input", () => {
    markDirty();
    const stopEl = $("chg-stop");
    let stop = Number(stopEl.value);
    let res = Number($("chg-resume").value);
    if (stop - res < MIN_HYSTERESIS_GAP) {
      if (res + MIN_HYSTERESIS_GAP <= 100) {
        stop = res + MIN_HYSTERESIS_GAP;
        stopEl.value = String(stop);
        $("chg-stop-val").textContent = `${stop}%`;
      } else {
        res = stop - MIN_HYSTERESIS_GAP;
        $("chg-resume").value = String(res);
      }
    }
    $("chg-resume-val").textContent = `${res}%`;
    updateChargeCallout(stop, res, getPickerValue("chg-mode"));
  });

  ["chg-enabled", "soff-enabled", "soff-doze", "thm-enabled"].forEach((id) => {
    $(id).addEventListener("change", markDirty);
  });

  $("soff-debounce").addEventListener("input", () => {
    markDirty();
    $("soff-debounce-val").textContent = `${$("soff-debounce").value}s`;
  });

  $("thm-warn").addEventListener("input", () => {
    markDirty();
    const w = Number($("thm-warn").value);
    const cEl = $("thm-crit");
    if (Number(cEl.value) <= w) {
      cEl.value = String(Math.min(49, w + 2));
      $("thm-crit-val").querySelector("span").textContent = `${cEl.value}°C`;
    }
    $("thm-warn-val").querySelector("span").textContent = `${w}°C`;
  });

  $("thm-crit").addEventListener("input", () => {
    markDirty();
    const w = Number($("thm-warn").value);
    let c = Number($("thm-crit").value);
    if (c <= w) {
      c = w + 1;
      $("thm-crit").value = String(c);
    }
    $("thm-crit-val").querySelector("span").textContent = `${c}°C`;
  });

  document.querySelectorAll('input[name="fps-mode"]').forEach((r) => {
    r.addEventListener("change", () => {
      markDirty();
      $("force-pk-box").classList.toggle("hidden", r.value !== "force120");
    });
  });

  $("btn-topup-once").addEventListener("click", () => {
    const btn = $("btn-topup-once");
    runAction(btn, "Đang xử lý...", async () => {
      const next = currentTopupOnce ? "0" : "1";
      const res = await callCtrl("topup-once", [next]);
      const active = Number(res.topup_once) === 1;
      syncTopupButton(active);
      const cBadge = $("charge-state-badge");
      if (active) {
        cBadge.className = "badge badge-warn";
        cBadge.textContent = res.state === "armed" ? "SẠC ĐẦY 1 LẦN (100%)" : "CHỜ CẮM SẠC (100%)";
      }
      showToast(active
        ? "Đã bật Sạc đầy 1 lần (100% đến khi rút cáp)"
        : "Đã hủy Sạc đầy 1 lần, quay về ngưỡng bảo vệ");
      await refreshStatus();
    });
  });

  $("btn-save-charge").addEventListener("click", () => {
    const btn = $("btn-save-charge");
    runAction(btn, "Đang lưu...", async () => {
      const en = $("chg-enabled").checked ? "1" : "0";
      const stop = $("chg-stop").value;
      const res = $("chg-resume").value;
      const lim = getPickerValue("chg-limit");
      const mode = getPickerValue("chg-mode");
      await callCtrl("set-charge", [en, stop, res, lim, mode]);
      configDirty = false;
      await refreshStatus();
      showToast("Đã lưu cấu hình Sạc thông minh");
    });
  });

  $("btn-save-screenoff").addEventListener("click", () => {
    const btn = $("btn-save-screenoff");
    runAction(btn, "Đang lưu...", async () => {
      const en = $("soff-enabled").checked ? "1" : "0";
      const deb = $("soff-debounce").value;
      const doze = $("soff-doze").checked ? "1" : "0";
      await callCtrl("set-screenoff", [en, deb, doze]);
      configDirty = false;
      await refreshStatus();
      showToast("Đã lưu cấu hình Screen-Off");
    });
  });

  $("btn-save-fps").addEventListener("click", () => {
    const btn = $("btn-save-fps");
    runAction(btn, "Đang áp dụng...", async () => {
      const sel = document.querySelector('input[name="fps-mode"]:checked');
      const mode = sel ? sel.value : "smart120";
      const pk = mode === "force120" ? getPickerValue("fps-pk-mode") : "none";
      await callCtrl("set-fps", [mode, pk]);
      configDirty = false;
      await refreshStatus();
      showToast(`Đã áp dụng FPS: ${mode}`);
    });
  });

  $("btn-save-thermal").addEventListener("click", () => {
    const btn = $("btn-save-thermal");
    runAction(btn, "Đang lưu...", async () => {
      const en = $("thm-enabled").checked ? "1" : "0";
      const w = $("thm-warn").value;
      const c = $("thm-crit").value;
      await callCtrl("set-thermal", [en, w, c]);
      configDirty = false;
      await refreshStatus();
      showToast("Đã lưu ngưỡng Thermal Guard");
    });
  });

  $("auto-game-enabled").addEventListener("change", () => {
    const en = $("auto-game-enabled").checked ? "1" : "0";
    runAction(null, "", async () => {
      await callCtrl("set-autogame", [en]);
      await refreshStatus();
      showToast(en === "1" ? "Đã bật Auto Game Mode" : "Đã tắt Auto Game Mode");
    });
  });

  $("joyose-disabled").addEventListener("change", () => {
    const dis = $("joyose-disabled").checked ? "1" : "0";
    runAction(null, "", async () => {
      await callCtrl("set-joyose", [dis]);
      await refreshStatus();
      showToast(dis === "1" ? "Đã vô hiệu hóa Joyose độc lập" : "Đã bật lại com.xiaomi.joyose");
    });
  });

  $("game-bypass-enabled").addEventListener("change", () => {
    const en = $("game-bypass-enabled").checked ? "1" : "0";
    const minp = getPickerValue("game-bypass-min");
    runAction(null, "", async () => {
      await callCtrl("set-game-bypass", [en, minp]);
      await refreshStatus();
      showToast(en === "1"
        ? `Đã bật Gaming Auto-Bypass (sàn pin ${minp}%)`
        : "Đã tắt Gaming Auto-Bypass");
    });
  });

  $("zram-enabled").addEventListener("change", () => {
    markDirty();
    if ($("zram-enabled").checked && getPickerValue("zram-size") === "0") {
      setPickerValue("zram-size", "6");
    } else if (!$("zram-enabled").checked) {
      setPickerValue("zram-size", "0");
    }
  });

  $("btn-save-zram").addEventListener("click", () => {
    const btn = $("btn-save-zram");
    runAction(btn, "Đang áp dụng ZRAM...", async () => {
      const sz = getPickerValue("zram-size");
      const en = ($("zram-enabled").checked && sz !== "0") ? "1" : "0";
      const algo = getPickerValue("zram-algo");
      await callCtrl("set-zram", [en, en === "1" ? sz : "0", algo]);
      configDirty = false;
      await refreshStatus();
      showToast(en === "1" ? `Đã bật ZRAM thuần RAM (${sz}GB · ${algo})` : "Đã tắt ZRAM");
    });
  });

  $("btn-add-game").addEventListener("click", () => {
    const input = $("game-pkg-input");
    const pkg = input.value.trim();
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9._-]+$/.test(pkg)) {
      showToast("Tên package không hợp lệ (vd: com.garena.game.kgvn)");
      return;
    }
    const btn = $("btn-add-game");
    runAction(btn, "...", async () => {
      const res = await callCtrl("add-game", [pkg]);
      input.value = "";
      renderGameList(res.games);
      showToast(`Đã thêm game: ${resolveGameTitle(pkg)}`);
    });
  });

  $("btn-open-app-picker").addEventListener("click", () => openAppPicker(false));
  $("btn-close-picker").addEventListener("click", closeAppPicker);
  $("btn-picker-done").addEventListener("click", closeAppPicker);
  $("btn-picker-refresh").addEventListener("click", () => openAppPicker(true));
  $("picker-search").addEventListener("input", renderPickerList);
  $("btn-picker-clear").addEventListener("click", () => {
    $("picker-search").value = "";
    $("picker-search").focus();
    renderPickerList();
  });
  $("app-picker-modal").addEventListener("click", (e) => {
    if (e.target === $("app-picker-modal")) closeAppPicker();
  });
  document.querySelectorAll(".seg-btn").forEach((b) => {
    b.addEventListener("click", () => {
      pickerFilter = b.dataset.filter;
      renderPickerList();
    });
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      if ($("sheet-picker-modal").classList.contains("is-open")) {
        closeBottomSheet();
      } else if ($("app-picker-modal").classList.contains("is-open")) {
        closeAppPicker();
      }
    }
  });

  $("btn-reset-defaults").addEventListener("click", () => {
    const btn = $("btn-reset-defaults");
    runAction(btn, "Đang khôi phục...", async () => {
      await callCtrl("reset-defaults");
      configDirty = false;
      await refreshStatus();
      showToast("Đã khôi phục cấu hình gốc & bật lại PowerKeeper/Joyose");
    });
  });

  $("btn-reload-logs").addEventListener("click", () => {
    runAction($("btn-reload-logs"), "Đang tải...", async () => {
      await loadLogs();
      showToast("Đã tải lại nhật ký");
    });
  });

  $("btn-clear-logs").addEventListener("click", () => {
    runAction($("btn-clear-logs"), "Đang xóa...", async () => {
      await callCtrl("clear-logs");
      await loadLogs();
      showToast("Đã xóa nhật ký");
    });
  });
}

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") {
    refreshStatus().then(scheduleNextPoll);
  } else {
    stopPolling();
  }
});

initTheme();
bindEvents();
loadGames();
refreshStatus().then(scheduleNextPoll);
