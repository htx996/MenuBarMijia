import { t } from "../core/i18n.js";
import { IntentReply } from "../core/assistant.js";
import {
  deviceCanTogglePower,
  deviceReadout,
  deviceStatusSummary,
  isDeviceActiveOn,
  localizeAirQuality,
  localizeFanPreset,
  localizeFridgeMode,
  localizeNightShot,
  type EnvironmentReading,
  type SmartDevice,
} from "../core/models.js";
import {
  TILE_SIZES,
  comfort,
  localizeEffect,
  localizeFanMode,
  type AppSkin,
  type TileSize,
} from "./panelPrefs.js";
import {
  formatTemperature,
  formatTemperatureValue,
  getTemperatureUnit,
  displayStep,
  temperatureSymbol,
} from "../core/temperature.js";
import { SF_ICONS } from "./appConstants.js";

  export function renderSensorCard(
    dev: SmartDevice,
    k: Extract<SmartDevice["kind"], { kind: "sensor" }>,
    compact: boolean,
    attrs: string,
    motion: string,
    badge: string,
    selectedRoom: string,
    valuesAreStale: boolean,
    escapeHtml: (value: string) => string,
  ): string {
    const c = comfort(k.temperature, k.humidity);
    const name = dev.name.replace(t("米家智能温湿度计"), t("温湿度计")) || dev.name;
    if (valuesAreStale) {
      const label = t("可能过期");
      return `
        <div class="cc-tile cc-sensor is-stale ${motion}" ${attrs} role="group" aria-label="${escapeHtml(`${name}，${label}`)}">
          ${badge}
          <div class="cc-sensor-top"><span class="cc-sensor-name">${escapeHtml(name)}</span></div>
          <div class="cc-sensor-main"><span class="cc-sensor-temp">${label}</span></div>
        </div>`;
    }
    const temp = k.temperature !== null ? formatTemperatureValue(k.temperature, undefined, 1) : "--";
    const hum = k.humidity !== null ? Math.round(k.humidity) : null;
    const room = selectedRoom === "全部" ? `<span class="cc-sensor-room">${escapeHtml(dev.roomName)}</span>` : "";
    const sensorAria = `${t("{name}，温度 {temp}", { name, temp: k.temperature !== null ? formatTemperature(k.temperature, undefined, 1) : "--" })}${hum !== null ? t("，湿度 {humidity}%", { humidity: hum }) : ""}${dev.isOnline ? "" : t("，离线")}`;
    if (compact) {
      return `
        <div class="cc-tile cc-sensor is-compact ${dev.isOnline ? "" : "is-offline"} ${motion}" ${attrs} role="group" aria-label="${escapeHtml(sensorAria)}">
          ${badge}
          <div class="cc-sensor-top">
            <span class="cc-sensor-name">${escapeHtml(name)}</span>
            <span class="cc-comfort is-${c.level}">${c.label}</span>
          </div>
          <div class="cc-sensor-main">
            <span class="cc-sensor-temp">${temp}<small>${temperatureSymbol()}</small></span>
            ${hum !== null ? `<span class="cc-sensor-hum">💧 ${hum}%</span>` : ""}
          </div>
          <div class="cc-hum-bar"><span style="width:${hum ?? 0}%"></span></div>
        </div>`;
    }
    const ring = hum !== null
      ? `<div class="cc-hum-ring" style="--h:${hum}">
          <svg viewBox="0 0 64 64"><circle class="track" cx="32" cy="32" r="27"/><circle class="comfy" cx="32" cy="32" r="27" pathLength="100"/><circle class="val" cx="32" cy="32" r="27" pathLength="100"/></svg>
          <span>${hum}%</span>
        </div>`
      : "";
    return `
      <div class="cc-tile cc-sensor ${dev.isOnline ? "" : "is-offline"} ${motion}" ${attrs} role="group" aria-label="${escapeHtml(sensorAria)}">
        ${badge}
        <div class="cc-sensor-wide">
          <div class="cc-sensor-info">
            <div class="cc-sensor-top"><span class="cc-sensor-name is-strong">${escapeHtml(name)}</span>${room}</div>
            <span class="cc-sensor-temp is-big">${temp}<small>${temperatureSymbol()}</small></span>
            <div class="cc-sensor-meta">
              <span class="cc-comfort is-${c.level}">${c.label}</span>
              ${k.battery !== null ? `<span class="cc-sensor-batt ${k.battery <= 20 ? "is-low" : ""}">🔋 ${k.battery}%</span>` : ""}
            </div>
          </div>
          ${ring}
        </div>
      </div>`;
  }

  export function renderClimateStrip(
    dev: SmartDevice,
    k: Extract<SmartDevice["kind"], { kind: "climate" }>,
    forceOpen: boolean,
    attrs: string,
    motion: string,
    badge: string,
    expandedDeviceId: string | null,
    selectedRoom: string,
    valuesAreStale: boolean,
    waitingDeviceIds: ReadonlySet<string>,
    escapeHtml: (value: string) => string,
  ): string {
    const readout = deviceReadout(waitingDeviceIds.has(dev.id), valuesAreStale);
    const running = readout !== "possiblyStale" && dev.isOnline && k.isOn && k.hvacMode !== "off";
    const powerWritable = k.powerWritable !== false;
    const temperatureWritable = k.temperatureWritable !== false;
    const canExpand = temperatureWritable || k.availableModes.length > 0 || k.availableFanModes.length > 0;
    const open = canExpand && (forceOpen || expandedDeviceId === dev.id);
    const id = escapeHtml(dev.id);
    const modeLabel: Record<string, string> = { cool: t("制冷"), heat: t("制热"), dry: t("除湿"), fan_only: t("送风"), auto: t("自动") };
    const status = readout === "waiting"
      ? t("等待中")
      : readout === "possiblyStale"
        ? t("可能过期")
        : running
          ? [
              modeLabel[k.hvacMode] ?? k.hvacMode,
              k.currentTemperature !== null
                ? t("室温 {temp}", { temp: formatTemperature(k.currentTemperature, undefined, 1) })
                : "",
            ].filter(Boolean).join(" · ")
          : t("已关闭");
    const subtitle = selectedRoom === "全部" ? `${dev.roomName} · ${status}` : status;
    const span = Math.max(k.maxTemp - k.minTemp, 1);
    const progress = Math.min(Math.max((k.targetTemperature - k.minTemp) / span, 0), 1) * 100;
    const modes = (
      k.availableModes.length > 0
        ? k.availableModes
        : !k.entityId.startsWith("miot:") && powerWritable
          ? ["cool", "heat", "dry", "fan_only"]
          : []
    ).filter((m) => m !== "off");
    const unit = getTemperatureUnit();
    const temp = formatTemperatureValue(k.targetTemperature);
    const power = powerWritable
      ? `<button class="cc-climate-power ${running ? "is-on" : ""}" data-toggle-device="${id}" title="${running ? t("关闭空调") : t("打开空调")}" aria-label="${running ? t("关闭 {name}", { name: escapeHtml(dev.name) }) : t("打开 {name}", { name: escapeHtml(dev.name) })}" aria-pressed="${running}">
            <span aria-hidden="true" ${k.hvacMode === "heat" ? "" : "hidden"}>🔥</span><span aria-hidden="true" ${k.hvacMode === "heat" ? "hidden" : ""}>${SF_ICONS.snowflake}</span>
          </button>`
      : `<span class="cc-climate-power ${running ? "is-on" : ""}" aria-hidden="true">
            <span ${k.hvacMode === "heat" ? "" : "hidden"}>🔥</span><span ${k.hvacMode === "heat" ? "hidden" : ""}>${SF_ICONS.snowflake}</span>
          </span>`;
    const steps = readout === "possiblyStale"
      ? ""
      : temperatureWritable
      ? `<button class="cc-climate-step" data-acstep="${id}:-1" title="${t("降低温度")}" aria-label="${t("降低目标温度")}">−</button>
          <span class="cc-climate-temp" aria-label="${t("目标温度 {temp}", { temp: formatTemperature(k.targetTemperature) })}">${temp}<small>${temperatureSymbol(unit)}</small></span>
          <button class="cc-climate-step" data-acstep="${id}:1" title="${t("升高温度")}" aria-label="${t("升高目标温度")}">＋</button>`
      : `<span class="cc-climate-temp" aria-label="${t("目标温度 {temp}", { temp: formatTemperature(k.targetTemperature) })}">${temp}<small>${temperatureSymbol(unit)}</small></span>`;
    return `
      <div class="cc-tile cc-climate ${running ? "is-active" : ""} ${dev.isOnline ? "" : "is-offline"} ${readout === "possiblyStale" ? "is-stale" : ""} ${motion}" ${attrs}>
        ${badge}
        <div class="cc-climate-strip">
          ${power}
          <button class="cc-climate-name" ${canExpand ? `data-expand-device="${id}"` : ""} aria-label="${escapeHtml(dev.name)}，${escapeHtml(subtitle)}" aria-expanded="${open}">
            <span class="cc-tile-name">${escapeHtml(dev.name)}</span>
            <span class="cc-tile-status">${escapeHtml(subtitle)} ${!canExpand || forceOpen ? "" : `<i class="cc-mini-caret ${open ? "is-open" : ""}">${SF_ICONS.chevronDown}</i>`}</span>
          </button>
          ${steps}
        </div>
        ${readout === "possiblyStale" ? "" : `<div class="cc-climate-gauge" role="progressbar" aria-label="${t("目标温度进度")}" aria-valuemin="${k.minTemp}" aria-valuemax="${k.maxTemp}" aria-valuenow="${k.targetTemperature}"><span style="width:${progress}%"></span></div>`}
        ${
          open
            ? `<div class="cc-climate-more">
                <div class="cc-segmented-pills is-even">
                  ${modes.map((m) => `<button class="cc-seg-pill ${running && k.hvacMode === m ? "is-active" : ""}" data-acmode="${id}:${m}" aria-pressed="${running && k.hvacMode === m}">${modeLabel[m] ?? m}</button>`).join("")}
                </div>
                ${
                  k.availableFanModes.length > 0
                    ? `<div class="cc-segmented-pills"><span class="cc-pill-label">${t("风速")}</span>${k.availableFanModes
                        .map((f) => `<button class="cc-seg-pill ${k.fanMode === f ? "is-active" : ""}" data-acfan="${id}:${escapeHtml(f)}" aria-pressed="${k.fanMode === f}">${escapeHtml(localizeFanMode(f))}</button>`)
                        .join("")}</div>`
                    : ""
                }
              </div>`
            : ""
        }
      </div>`;
  }

export function renderDeviceDrawer(dev: SmartDevice, escapeHtml: (value: string) => string): string {
    const k = dev.kind;
    if (k.kind === "light") {
      const showBrightness = k.brightnessWritable !== false;
      const showColor = k.colorWritable !== false;
      if (!showBrightness && !showColor && k.availableEffects.length === 0) return "";
      const bri = k.brightnessPercent ?? 80;
      const ct = k.colorTempKelvin ?? 4000;
      return `
        <div class="cc-tile-drawer">
          ${showBrightness ? `<div class="cc-slider-group">
            <div class="cc-slider-label">
              <span>${t("亮度")}</span>
              <strong>${bri}%</strong>
            </div>
            <input class="cc-range is-amber" type="range" min="1" max="100" value="${bri}" data-brightness="${escapeHtml(dev.id)}" aria-label="${t("亮度")}" aria-valuemin="1" aria-valuemax="100" aria-valuenow="${bri}" />
          </div>` : ""}
          ${showColor ? `<div class="cc-slider-group">
            <div class="cc-slider-label">
              <span>${t("色温")}</span>
              <strong>${ct}K</strong>
            </div>
            <input class="cc-range is-kelvin" type="range" min="${k.minKelvin}" max="${k.maxKelvin}" step="100" value="${ct}" data-colortemp="${escapeHtml(dev.id)}" aria-label="${t("色温")}" aria-valuemin="${k.minKelvin}" aria-valuemax="${k.maxKelvin}" aria-valuenow="${ct}" />
          </div>` : ""}
          ${k.availableEffects.length > 0 ? `
            <div class="cc-segmented-pills">
              ${k.availableEffects.map((effect) => `
                <button class="cc-seg-pill ${k.currentEffect === effect ? "is-active" : ""}"
                  data-lighteffect="${escapeHtml(dev.id)}" data-effect="${escapeHtml(effect)}"
                  aria-pressed="${k.currentEffect === effect}">
                  ${escapeHtml(localizeEffect(effect))}
                </button>
              `).join("")}
            </div>
          ` : ""}
        </div>
      `;
    }
    if (k.kind === "climate") {
      const showTemp = k.temperatureWritable !== false;
      const showModes = k.availableModes.some((mode) => mode !== "off") || (!k.entityId.startsWith("miot:") && k.powerWritable !== false);
      if (!showTemp && !showModes) return "";
      const modes: ReadonlyArray<{ readonly code: string; readonly label: string }> = [
        { code: "cool", label: t("制冷") },
        { code: "heat", label: t("制热") },
        { code: "dry", label: t("除湿") },
        { code: "fan_only", label: t("送风") },
        { code: "auto", label: t("自动") },
      ];
      return `
        <div class="cc-tile-drawer">
          ${showTemp ? `<div class="cc-slider-group">
            <div class="cc-slider-label">
              <span>${t("目标温度")}</span>
              <strong>${formatTemperature(k.targetTemperature)}</strong>
            </div>
            <input class="cc-range is-blue" type="range" min="${formatTemperatureValue(k.minTemp)}" max="${formatTemperatureValue(k.maxTemp)}" step="${displayStep(k.step)}" value="${formatTemperatureValue(k.targetTemperature)}" data-actemp="${escapeHtml(dev.id)}" aria-label="${t("目标温度")}" aria-valuemin="${formatTemperatureValue(k.minTemp)}" aria-valuemax="${formatTemperatureValue(k.maxTemp)}" aria-valuetext="${formatTemperature(k.targetTemperature)}" />
          </div>` : ""}
          ${showModes ? `<div class="cc-segmented-pills">
            ${modes
              .map(
                (m) => `
              <button class="cc-seg-pill ${k.hvacMode === m.code ? "is-active" : ""}" data-acmode="${escapeHtml(dev.id)}:${m.code}">
                ${m.label}
              </button>
            `,
              )
              .join("")}
          </div>` : ""}
        </div>
      `;
    }
    if (k.kind === "fan") {
      const modes =
        k.availablePresetModes.length > 0
          ? k.availablePresetModes
          : k.powerWritable === false
            ? []
            : ["Level 1", "Level 2", "Level 3", "Level 4"];
      const telemetryParts: string[] = [];
      if (k.pm25Density !== undefined && k.pm25Density !== null) {
        const aq = localizeAirQuality(k.airQuality, k.pm25Density);
        telemetryParts.push(`${t("空气质量")} PM2.5 ${k.pm25Density}${aq ? ` (${aq})` : ""}`);
      } else if (k.airQuality) {
        const aq = localizeAirQuality(k.airQuality, null);
        if (aq) telemetryParts.push(`${t("空气质量")} ${aq}`);
      }
      if (k.temperature !== undefined && k.temperature !== null && k.humidity !== undefined && k.humidity !== null) {
        telemetryParts.push(`${t("温湿度")} ${formatTemperature(k.temperature, undefined, 1)} · ${Math.round(k.humidity)}%`);
      } else if (k.temperature !== undefined && k.temperature !== null) {
        telemetryParts.push(formatTemperature(k.temperature, undefined, 1));
      } else if (k.humidity !== undefined && k.humidity !== null) {
        telemetryParts.push(`${Math.round(k.humidity)}%`);
      }
      if (k.filterLifePercent !== undefined && k.filterLifePercent !== null) {
        telemetryParts.push(`${t("滤芯余量")} ${k.filterLifePercent}%`);
      }
      return `
        <div class="cc-tile-drawer">
          ${
            telemetryParts.length > 0
              ? `<div class="cc-slider-label"><span>${escapeHtml(telemetryParts.join(" · "))}</span></div>`
              : ""
          }
          ${
            k.speedWritable !== false && k.percentage !== null
              ? `<div class="cc-slider-group">
                  <div class="cc-slider-label">
                    <span>${t("风速")}</span>
                    <strong>${k.percentage}%</strong>
                  </div>
                  <input class="cc-range is-blue" type="range" min="1" max="100" value="${Math.max(1, k.percentage)}" data-fanpercent="${escapeHtml(dev.id)}" aria-label="${t("风速")}" aria-valuemin="1" aria-valuemax="100" aria-valuenow="${Math.max(1, k.percentage)}" />
                </div>`
              : ""
          }
          ${
            modes.length > 0 || (k.swingWritable !== false && k.isOscillating !== null)
              ? `<div class="cc-segmented-pills">
            ${modes
              .map(
                (preset) => `
              <button class="cc-seg-pill ${k.presetMode === preset ? "is-active" : ""}" data-fanpreset="${escapeHtml(dev.id)}:${escapeHtml(preset)}" aria-pressed="${k.presetMode === preset}">
                ${escapeHtml(localizeFanPreset(IntentReply.fanSpeedLabel(preset)))}
              </button>
            `,
              )
              .join("")}
            ${
              k.swingWritable !== false && k.isOscillating !== null
                ? `<button class="cc-seg-pill ${k.isOscillating ? "is-active" : ""}" data-fanosc="${escapeHtml(dev.id)}" aria-pressed="${k.isOscillating}">
                    摇头 ${k.isOscillating ? t("开") : t("关")}
                  </button>`
                : ""
            }
          </div>`
              : ""
          }
        </div>
      `;
    }
    if (k.kind === "camera") {
      if (k.powerWritable === false && k.availableNightShots.length === 0 && !k.motionDetectionEntityId) return "";
      const id = escapeHtml(dev.id);
      const motionOn = Boolean(k.isMotionDetectionOn);
      return `
        <div class="cc-tile-drawer">
          <div class="cc-segmented-pills">
            <button class="cc-seg-pill is-active" data-camera-live="${id}">
              ${t("放大实时画面")}
            </button>
            ${k.powerWritable === false ? "" : `<button class="cc-seg-pill ${!k.isOn ? "is-active" : ""}" data-toggle-device="${id}" aria-pressed="${!k.isOn}">
              ${k.isOn ? t("镜头休眠") : t("唤醒镜头")}
            </button>`}
            ${
              k.motionDetectionEntityId
                ? `<button class="cc-seg-pill ${motionOn ? "is-active" : ""}" data-cameramotion="${id}" aria-pressed="${motionOn}">
                    ${motionOn ? t("移动侦测：开") : t("移动侦测：关")}
                  </button>`
                : ""
            }
          </div>
          ${
            k.availableNightShots.length > 0
              ? `<div class="cc-segmented-pills">
                  ${k.availableNightShots
                    .map(
                      (mode) => `<button class="cc-seg-pill ${k.nightShot === mode ? "is-active" : ""}" data-cameranight="${id}:${escapeHtml(mode)}" aria-pressed="${k.nightShot === mode}">
                        ${escapeHtml(localizeNightShot(mode))}
                      </button>`
                    )
                    .join("")}
                </div>`
              : ""
          }
        </div>
      `;
    }
    if (k.kind === "fridge") {
      const id = escapeHtml(dev.id);
      const fridgeStep = k.fridgeTargetEntityId
        ? `<button class="cc-seg-pill" data-fridgestep="${id}:fridge:-1" aria-label="${t("降低冷藏室温度")}">−</button>
            <button class="cc-seg-pill" data-fridgestep="${id}:fridge:1" aria-label="${t("升高冷藏室温度")}">＋</button>`
        : "";
      const freezerStep = k.freezerTargetEntityId
        ? `<button class="cc-seg-pill" data-fridgestep="${id}:freezer:-1" aria-label="${t("降低冷冻室温度")}">−</button>
            <button class="cc-seg-pill" data-fridgestep="${id}:freezer:1" aria-label="${t("升高冷冻室温度")}">＋</button>`
        : "";
      return `
        <div class="cc-tile-drawer">
          <div class="cc-segmented-pills">
            <span class="cc-pill-label">${t("冷藏室")} (${formatTemperature(k.fridgeTargetTemp)})</span>
            ${fridgeStep}
          </div>
          <div class="cc-segmented-pills">
            <span class="cc-pill-label">${t("冷冻室")} (${formatTemperature(k.freezerTargetTemp)})</span>
            ${freezerStep}
          </div>
          ${
            k.availableModes.length > 0
              ? `<div class="cc-segmented-pills">
                  ${k.availableModes
                    .map(
                      (mode) => `<button class="cc-seg-pill ${k.currentMode === mode ? "is-active" : ""}" data-fridgemode="${id}:${escapeHtml(mode)}" aria-pressed="${k.currentMode === mode}">
                        ${escapeHtml(localizeFridgeMode(mode))}
                      </button>`
                    )
                    .join("")}
                </div>`
              : ""
          }
        </div>
      `;
    }
    return "";
  }

function devicePaletteClass(dev: SmartDevice): string {
  switch (dev.kind.kind) {
    case "light":
      return "palette-amber";
    case "climate":
    case "fridge":
      return "palette-blue";
    case "fan":
      return "palette-mint";
    case "plug":
      return "palette-green";
    case "vacuum":
      return "palette-indigo";
    case "camera":
      return "palette-blue";
    case "sensor":
      return "palette-teal";
  }
}

function deviceSvgIcon(dev: SmartDevice): string {
  switch (dev.kind.kind) {
    case "light":
      return SF_ICONS.lightbulbFill;
    case "climate":
    case "fridge":
      return SF_ICONS.snowflake;
    case "fan":
      return SF_ICONS.fanbladesFill;
    case "plug":
      return SF_ICONS.powerplugFill;
    case "vacuum":
      return SF_ICONS.sparkles;
    case "camera":
      return SF_ICONS.videoFill;
    case "sensor":
      return SF_ICONS.sensorFill;
  }
}

export interface DeviceTileViewState {
  readonly span: number;
  readonly index: number;
  readonly size: Exclude<TileSize, "auto">;
  readonly skin: AppSkin;
  readonly animateEntrance: boolean;
  readonly poppedDeviceId: string | null;
  readonly draggingId: string | null;
  readonly isEditingLayout: boolean;
  readonly selectedRoom: string;
  readonly valuesAreStale: boolean;
  readonly expandedDeviceId: string | null;
  readonly waitingDeviceIds: ReadonlySet<string>;
  readonly compactGrid: boolean;
  readonly dimPreview: { readonly id: string; readonly percent: number } | null;
  readonly escapeHtml: (value: string) => string;
}

export function renderDeviceTile(dev: SmartDevice, state: DeviceTileViewState): string {
  const size = state.size;
  const escape = state.escapeHtml;
  const attrs = `data-tile-id="${escape(dev.id)}" style="grid-column: span ${state.span}; --i: ${Math.min(state.index, 12)}; --jd: -${Math.round((performance.now() + (state.index * 137) % 560) % 560)}ms"`;
  const motion = `${state.animateEntrance && state.skin !== "classic" ? "is-entering" : ""} ${state.poppedDeviceId === dev.id ? "is-popped" : ""} ${state.draggingId === dev.id ? "is-dragging" : ""}`;
  const sizeTitle = TILE_SIZES.find((item) => item.id === size)?.title ?? "";
  const badge = state.isEditingLayout
    ? `<button class="cc-resize-handle" data-resize-handle="${escape(dev.id)}" data-cycle-size="${escape(dev.id)}" data-tile-size="${size}" title="${t("切换卡片大小")}：${sizeTitle}" aria-label="${t("切换卡片大小")}，${sizeTitle}"><svg class="cc-resize-arc" viewBox="0 0 28 28" aria-hidden="true"><path d="M 22 10 A 12 12 0 0 1 10 22" /></svg></button>`
    : "";
  if (dev.kind.kind === "sensor" && (dev.kind.temperature !== null || dev.kind.humidity !== null) && !(state.skin === "bento" && state.span < 6)) {
    return renderSensorCard(dev, dev.kind, state.span < 6, attrs, motion, badge, state.selectedRoom, state.valuesAreStale, escape);
  }
  if (dev.kind.kind === "climate" && size !== "half") {
    return renderClimateStrip(dev, dev.kind, size === "panel", attrs, motion, badge, state.expandedDeviceId, state.selectedRoom, state.valuesAreStale, state.waitingDeviceIds, escape);
  }
  const isExpanded = state.expandedDeviceId === dev.id || size === "panel";
  const readout = deviceReadout(state.waitingDeviceIds.has(dev.id), state.valuesAreStale);
  const isOn = readout === "possiblyStale" ? false : isDeviceActiveOn(dev);
  const kind = dev.kind.kind;
  const palette = devicePaletteClass(dev);
  const svg = deviceSvgIcon(dev);
  const writable = deviceCanTogglePower(dev);
  const fanReadings =
    dev.kind.kind === "fan" &&
    (dev.kind.pm25Density != null ||
      dev.kind.airQuality != null ||
      dev.kind.temperature != null ||
      dev.kind.humidity != null ||
      dev.kind.filterLifePercent != null);
  const hasDrawer =
    kind === "fridge" ||
    (dev.kind.kind === "light" &&
      (dev.kind.brightnessWritable !== false || dev.kind.colorWritable !== false || dev.kind.availableEffects.length > 0)) ||
    (dev.kind.kind === "climate" &&
      (dev.kind.temperatureWritable !== false || dev.kind.availableModes.length > 0 || dev.kind.availableFanModes.length > 0)) ||
    (dev.kind.kind === "fan" &&
      (fanReadings ||
        dev.kind.availablePresetModes.length > 0 ||
        (dev.kind.speedWritable !== false && dev.kind.percentage !== null) ||
        (dev.kind.swingWritable !== false && dev.kind.isOscillating !== null))) ||
    (dev.kind.kind === "camera" &&
      (writable || dev.kind.availableNightShots.length > 0 || dev.kind.motionDetectionEntityId !== null)) ||
    (dev.kind.kind === "vacuum" && dev.kind.actionsWritable !== false);
  const subtitle =
    state.selectedRoom === "全部"
      ? `${dev.roomName} · ${deviceStatusSummary(dev)}`
      : deviceStatusSummary(dev);

  const dim = state.dimPreview?.id === dev.id ? state.dimPreview.percent : null;
  const fill = kind === "light" && state.skin !== "classic" && !isExpanded
    ? dim ?? (isOn && dev.kind.kind === "light" ? dev.kind.brightnessPercent ?? 100 : 0)
    : 0;
  const shownSubtitle = readout === "waiting"
    ? t("等待中")
    : readout === "possiblyStale"
      ? t("可能过期")
      : dim !== null
        ? t("亮度 {percent}%", { percent: dim })
        : subtitle;
  const staleClass = readout === "possiblyStale" ? "is-stale" : "";
  return `
      <div class="cc-tile ${palette} ${isOn ? "is-active" : ""} ${isExpanded ? "is-expanded" : ""} ${dev.isOnline ? "" : "is-offline"} ${staleClass} ${kind === "light" ? "is-light" : ""} ${state.skin === "bento" && state.span < 6 ? "is-bento-tile" : ""} ${motion}" ${attrs}>
        ${fill > 0 ? `<span class="cc-tile-fill" style="width:${fill}%"></span>` : ""}
        ${badge}
        <div class="cc-tile-header">
          ${
            writable
              ? `<button
            class="cc-tile-orb"
            data-toggle-device="${escape(dev.id)}"
            title="${kind === "sensor" ? dev.name : t("点击直接切换开关")}"
            aria-label="${escape(t("{name} 开关", { name: dev.name }))}"
            aria-pressed="${isOn}"
          >
            ${svg}
          </button>`
              : `<span class="cc-tile-orb" title="${escape(dev.name)}" aria-hidden="true">${svg}</span>`
          }

          <button
            class="cc-tile-body"
            data-body-device="${escape(dev.id)}"
            title="${kind === "camera" ? t("点击放大打开摄像机实时画面") : hasDrawer ? t("点击展开精细调节") : t("点击切换开关")}"
            aria-label="${escape(dev.name)}，${escape(shownSubtitle)}"
            aria-pressed="${isOn}"
          >
            <div class="cc-tile-name">${escape(dev.name)}</div>
            <div class="cc-tile-status">${escape(shownSubtitle)}</div>
          </button>

          ${
            hasDrawer && size !== "panel" && (state.skin === "classic" || !state.compactGrid || isExpanded)
              ? `<button
                  class="cc-tile-chevron ${isExpanded ? "is-open" : ""}"
                  data-expand-device="${escape(dev.id)}"
                  title="${isExpanded ? t("收起详细控制") : t("展开详细控制")}"
                  aria-label="${isExpanded ? t("收起") : t("展开")} ${escape(t("{name} 详细控制", { name: dev.name }))}"
                  aria-expanded="${isExpanded}"
                >
                  ${SF_ICONS.chevronRight}
                </button>`
              : ""
          }
        </div>
        ${isExpanded && hasDrawer ? renderDeviceDrawer(dev, escape) : ""}
      </div>
    `;
}

export function renderEnvironmentStrip(options: {
  readonly readings: readonly EnvironmentReading[];
  readonly watts: number;
  readonly valuesAreStale: boolean;
  readonly escapeHtml: (value: string) => string;
}): string {
  if (options.valuesAreStale) {
    return `<div class="cc-env-strip"><div class="cc-env-chip"><span class="cc-env-label">${t("可能过期")}</span></div></div>`;
  }
  const envChips = options.readings;
  const watts = options.watts;
  if (envChips.length === 0 && watts < 1) return "";
  return `
      <div class="cc-env-strip">
        ${envChips
          .map(
            (env) => `
          <div class="cc-env-chip">
            <span class="cc-env-icon">${SF_ICONS.sensorFill}</span>
            <span class="cc-env-label">${options.escapeHtml(env.label)}</span>
            ${env.temperature !== null ? `<strong class="cc-env-val">${formatTemperature(env.temperature, undefined, 1)}</strong>` : ""}
            ${env.humidity !== null ? `<span class="cc-env-hum">· ${Math.round(env.humidity)}%</span>` : ""}
          </div>
        `,
          )
          .join("")}
        ${
          watts >= 1
            ? `
          <div class="cc-env-chip is-power">
            <span class="cc-env-icon">${SF_ICONS.boltFill}</span>
            <strong class="cc-env-val">${Math.round(watts)}W</strong>
          </div>
        `
            : ""
        }
      </div>
    `;
}
