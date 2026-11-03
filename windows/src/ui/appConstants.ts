import type { CameraStreamQuality } from "../core/cameraQuality.js";

export const STORAGE_KEY = "menumijia.windows.settings.v2";
// The #52 language/unit preferences live inside the one settings blob above, so a save writes them
// atomically with the rest; `i18n.ts` and `temperature.ts` expose matching standalone keys for tools.
export const LEGACY_STORAGE_KEY = "menumijia.windows.settings.v1";
// Bump when a cached device shape needs a one-time migration on load (#148).
export const CACHED_DEVICES_VERSION = 1;

/** UI labels for the Xiaomi quality pills; the values match the macOS menu (#193). */
export const CAMERA_QUALITY_TITLES: Record<CameraStreamQuality, string> = {
  auto: "自动",
  sd: "流畅",
  hd: "高清",
  max: "超清",
};

// Injected at build time by vite.config.ts from the repository's VERSION file (#39).
export const APP_VERSION =
  typeof __APP_VERSION__ === "string" && __APP_VERSION__.trim() !== "" ? __APP_VERSION__.trim() : "0.0.0";

// Crisp Apple SF-Symbol-matched vector icons (zero Windows emojis)
export const SF_ICONS = {
  houseFill: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M10.707 2.293a1 1 0 00-1.414 0l-7 7a1 1 0 001.414 1.414L4 10.414V17a1 1 0 001 1h3a1 1 0 001-1v-3a1 1 0 011-1h0a1 1 0 011 1v3a1 1 0 001 1h3a1 1 0 001-1v-6.586l.293.293a1 1 0 001.414-1.414l-7-7z"/></svg>`,
  lightbulbFill: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M10 2a6 6 0 00-3.815 10.631C7.237 13.5 8 14.443 8 15.5v.5a2 2 0 002 2h0a2 2 0 002-2v-.5c0-1.057.763-2 1.815-2.869A6 6 0 0010 2zm-1.5 15.5h3a.5.5 0 010 1h-3a.5.5 0 010-1z"/></svg>`,
  snowflake: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M10 2v16M2 10h16M4.93 4.93l10.14 10.14M15.07 4.93L4.93 15.07M10 4.5L8 2.5M10 4.5l2-2M10 15.5l-2 2M10 15.5l2 2"/></svg>`,
  fanbladesFill: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M10 8.2a1.8 1.8 0 100 3.6 1.8 1.8 0 000-3.6zm.5-6.2c-2.2 0-3.6 1.8-2.9 3.9.3.8.8 1.5 1.5 1.9.3-.2.6-.3.9-.3.7 0 1.3.4 1.6 1 .8-.6 1.4-1.7 1.4-3.1C13 3.4 11.9 2 10.5 2zm7.5 8.5c0-2.2-1.8-3.6-3.9-2.9-.8.3-1.5.8-1.9 1.5.2.3.3.6.3.9 0 .7-.4 1.3-1 1.6.6.8 1.7 1.4 3.1 1.4 2 0 3.4-1.1 3.4-2.5zM9.5 18c2.2 0 3.6-1.8 2.9-3.9-.3-.8-.8-1.5-1.5-1.9-.3.2-.6.3-.9.3-.7 0-1.3-.4-1.6-1-.8.6-1.4 1.7-1.4 3.1 0 2 1.1 3.4 2.5 3.4zM2 9.5c0 2.2 1.8 3.6 3.9 2.9.8-.3 1.5-.8 1.9-1.5-.2-.3-.3-.6-.3-.9 0-.7.4-1.3 1-1.6-.6-.8-1.7-1.4-3.1-1.4-2 0-3.4 1.1-3.4 2.5z"/></svg>`,
  powerplugFill: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M7 2a1 1 0 011 1v3h4V3a1 1 0 112 0v3h1a1 1 0 011 1v2.5a5.5 5.5 0 01-4.5 5.408V17a1 1 0 11-2 0v-2.092A5.5 5.5 0 014 9.5V7a1 1 0 011-1h1V3a1 1 0 011-1z"/></svg>`,
  sparkles: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M10.8 2.4a.6.6 0 00-1.1 0L8.1 6.3a2.2 2.2 0 01-1.2 1.2L3 9.1a.6.6 0 000 1.1l3.9 1.6c.5.2 1 .7 1.2 1.2l1.6 3.9a.6.6 0 001.1 0l1.6-3.9c.2-.5.7-1 1.2-1.2l3.9-1.6a.6.6 0 000-1.1l-3.9-1.6a2.2 2.2 0 01-1.2-1.2L10.8 2.4zM15.8 13.2a.4.4 0 00-.7 0l-.6 1.4-.4.4-1.4.6a.4.4 0 000 .7l1.4.6.4.4.6 1.4a.4.4 0 00.7 0l.6-1.4.4-.4 1.4-.6a.4.4 0 000-.7l-1.4-.6-.4-.4-.6-1.4z"/></svg>`,
  sensorFill: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M10 3a2.5 2.5 0 00-2.5 2.5v6.085a4 4 0 105 0V5.5A2.5 2.5 0 0010 3zm0 1.5a1 1 0 011 1v6.6a.75.75 0 00.32.614 2.5 2.5 0 11-2.64 0 .75.75 0 00.32-.614V5.5a1 1 0 011-1z"/></svg>`,
  micFill: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M10 2.5a2.75 2.75 0 00-2.75 2.75v4.5a2.75 2.75 0 005.5 0v-4.5A2.75 2.75 0 0010 2.5zM5.25 9.25a.75.75 0 00-1.5 0 6.25 6.25 0 005.5 6.205V17.5h-2a.75.75 0 000 1.5h5.5a.75.75 0 000-1.5h-2v-2.045a6.25 6.25 0 005.5-6.205.75.75 0 00-1.5 0 4.75 4.75 0 11-9.5 0z"/></svg>`,
  arrowClockwise: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M16.5 4.5v4h-4"/><path d="M15.8 12.8a6.2 6.2 0 11-1.3-6.6L16.5 8.5"/></svg>`,
  sliderHorizontal: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><path d="M3 5.5h9M15 5.5h2M3 10h3M9 10h8M3 14.5h7M13 14.5h4"/><circle cx="13.5" cy="5.5" r="1.6" fill="currentColor"/><circle cx="7.5" cy="10" r="1.6" fill="currentColor"/><circle cx="11.5" cy="14.5" r="1.6" fill="currentColor"/></svg>`,
  power: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.85" stroke-linecap="round"><path d="M10 2.8v6.4M6.1 4.8a6.2 6.2 0 107.8 0"/></svg>`,
  chevronRight: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7.5 4.5L13 10l-5.5 5.5"/></svg>`,
  chevronDown: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 7.5L10 12.5 15 7.5"/></svg>`,
  sunMaxFill: `<svg viewBox="0 0 20 20" fill="currentColor"><circle cx="10" cy="10" r="3.6"/><path stroke="currentColor" stroke-width="1.7" stroke-linecap="round" d="M10 2.2v2M10 15.8v2M2.2 10h2M15.8 10h2M4.48 4.48l1.42 1.42M14.1 14.1l1.42 1.42M15.52 4.48L14.1 5.9M5.9 14.1l-1.42 1.42"/></svg>`,
  moonStarsFill: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M14.9 13.3A6.5 6.5 0 017.7 4.1a.6.6 0 00-.78-.75 7.2 7.2 0 108.73 9.73.6.6 0 00-.75-.78z"/></svg>`,
  boltFill: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M11.3 1.9L4.6 10.6a.6.6 0 00.48.96H9.5l-.8 6.54a.5.5 0 00.89.36l6.7-8.7a.6.6 0 00-.48-.96H11.4l.79-6.54a.5.5 0 00-.89-.36z"/></svg>`,
  grid2x2: `<svg viewBox="0 0 20 20" fill="currentColor"><rect x="3" y="3" width="6" height="6" rx="1.6"/><rect x="11" y="3" width="6" height="6" rx="1.6"/><rect x="3" y="11" width="6" height="6" rx="1.6"/><rect x="11" y="11" width="6" height="6" rx="1.6"/></svg>`,
  grid1x2: `<svg viewBox="0 0 20 20" fill="currentColor"><rect x="3" y="3.5" width="14" height="5.2" rx="1.6"/><rect x="3" y="11.3" width="14" height="5.2" rx="1.6"/></svg>`,
  wifi: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><path d="M4.2 8.7a8.2 8.2 0 0111.6 0"/><path d="M6.6 11.3a4.8 4.8 0 016.8 0"/><circle cx="10" cy="14.6" r="1.15" fill="currentColor" stroke="none"/></svg>`,
  wifiSlash: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><path d="M4.2 8.7a8.2 8.2 0 0111.6 0"/><path d="M6.6 11.3a4.8 4.8 0 016.8 0"/><circle cx="10" cy="14.6" r="1.15" fill="currentColor" stroke="none"/><path d="M4.4 4.4l11.2 11.2"/></svg>`,
  qrcode: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M3 3h6v6H3V3zm1.5 1.5v3h3v-3h-3zM11 3h6v6h-6V3zm1.5 1.5v3h3v-3h-3zM3 11h6v6H3v-6zm1.5 1.5v3h3v-3h-3zM11 11h2.5v2.5H11V11zm3.5 0H17v2.5h-2.5V11zM11 14.5h2.5V17H11v-2.5zm3.5 0H17V17h-2.5v-2.5z"/></svg>`,
  xmark: `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><path d="M5.5 5.5l9 9M14.5 5.5l-9 9"/></svg>`,
  arrowUpCircle: `<svg viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" clip-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm.53-11.28a.75.75 0 00-1.06 0L6.72 9.47a.75.75 0 101.06 1.06l1.47-1.47v4.19a.75.75 0 001.5 0V9.06l1.47 1.47a.75.75 0 101.06-1.06l-2.75-2.75z"/></svg>`,
  videoFill: `<svg viewBox="0 0 20 20" fill="currentColor"><path d="M3 5a2 2 0 012-2h7a2 2 0 012 2v1.8l3.1-1.85A.75.75 0 0118.25 5.6v8.8a.75.75 0 01-1.15.65L14 13.2V15a2 2 0 01-2 2H5a2 2 0 01-2-2V5z"/></svg>`,
};

/** Demo home, materialised per language so the preview text follows the UI (#52). */
