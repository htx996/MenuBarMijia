import { assistantEndpointIdentity, resolveHabitSharing, type HabitEntry } from "../core/assistant.js";
import { normalizeCameraStreamQualityMap } from "../core/cameraQuality.js";
import { parseCachedHAHome } from "../core/homeAssistant.js";
import { normalizeMiCloudRegion } from "../core/miCloudClient.js";
import type { SmartDevice } from "../core/models.js";
import {
  DEFAULT_GLOBAL_SHORTCUT,
  PANEL_HEIGHTS,
  SKINS,
  emptyLayoutPrefs,
  normalizeGlobalShortcut,
  type AppSkin,
  type PanelHeight,
} from "./panelPrefs.js";
import { parseMiSession, sanitizeSettingsForStorage } from "../core/secureStore.js";
import { CACHED_DEVICES_VERSION, LEGACY_STORAGE_KEY, STORAGE_KEY } from "./appConstants.js";
import type { ConnectionMode, LoadedSettings, PersistedSettings } from "./appTypes.js";

export function upgradeCachedDevices(devices: SmartDevice[], migrateLegacyFridgeCache: boolean): SmartDevice[] {
  return devices.map((dev) => {
    const m = dev.model.toLowerCase();
    if (
      dev.kind.kind === "plug" &&
      (m.includes("camera") || m.includes("cateye") || m.includes("doorbell"))
    ) {
      return {
        ...dev,
        kind: {
          kind: "camera",
          entityId: dev.kind.switchEntityId,
          isOn: dev.kind.isOn,
          nightShot: "Auto",
          availableNightShots: ["Off", "On", "Auto"],
          motionDetectionEntityId: null,
          isMotionDetectionOn: null,
          streamEntityId: null,
        },
      };
    }
    if (migrateLegacyFridgeCache && dev.kind.kind === "fridge") {
      // A legacy cache can carry ids from the guessed fallback; cloud re-synthesis
      // restores only verified writable targets afterwards (#148).
      return {
        ...dev,
        kind: {
          ...dev.kind,
          modeEntityId: null,
          availableModes: [],
          fridgeTargetEntityId: null,
          freezerTargetEntityId: null,
        },
      };
    }
    return dev;
  });
}



export function loadSettings(): LoadedSettings {
  try {
    const raw = localStorage.getItem(STORAGE_KEY) ?? localStorage.getItem(LEGACY_STORAGE_KEY);
    if (raw) {
      const parsed = JSON.parse(raw) as Partial<PersistedSettings> & Record<string, unknown>;
      const cachedDevicesVersion =
        typeof parsed.cachedDevicesVersion === "number" ? parsed.cachedDevicesVersion : 0;
      const rawHaToken = typeof parsed.haToken === "string" ? parsed.haToken : "";
      const rawApiKey = typeof parsed.openRouterApiKey === "string" ? parsed.openRouterApiKey : "";
      const hasLegacyCredentials =
        (parsed.miSession !== undefined && parsed.miSession !== null) || rawHaToken !== "" || rawApiKey !== "";
      const miSession = parseMiSession(parsed.miSession);
      const mode: ConnectionMode = parsed.connectionMode === "demo" || parsed.connectionMode === "xiaomiCloud" || parsed.connectionMode === "homeAssistant"
        ? parsed.connectionMode
        : miSession ? "xiaomiCloud" : "demo";
      const habitShare = resolveHabitSharing(parsed.habitShareEnabled);
      if (habitShare.persistOff) {
        writeSettingsForStorage({ ...parsed, habitShareEnabled: false });
      }
      return {
        settings: {
          connectionMode: mode,
          miSession,
          miCloudRegion: normalizeMiCloudRegion(parsed.miCloudRegion ?? miSession?.region),
          autoCheckUpdates: parsed.autoCheckUpdates ?? true,
          haBaseURL: parsed.haBaseURL ?? "",
          haToken: rawHaToken,
          assistantBaseURL: parsed.assistantBaseURL ?? "https://openrouter.ai/api/v1",
          openRouterApiKey: rawApiKey,
          // Keys saved before binding existed belong to the URL saved alongside them.
          assistantKeyEndpoint:
            parsed.assistantKeyEndpoint !== undefined
              ? parsed.assistantKeyEndpoint
              : parsed.openRouterApiKey
                ? assistantEndpointIdentity(parsed.assistantBaseURL ?? "https://openrouter.ai/api/v1")
                : null,
          cloudConsentEndpoints: Array.isArray(parsed.cloudConsentEndpoints)
            ? parsed.cloudConsentEndpoints.filter((e): e is string => typeof e === "string")
            : [],
          allOffOverrides:
            parsed.allOffOverrides && typeof parsed.allOffOverrides === "object"
              ? Object.fromEntries(
                  Object.entries(parsed.allOffOverrides).filter((entry): entry is [string, boolean] => typeof entry[1] === "boolean"),
                )
              : {},
          assistantModel: parsed.assistantModel ?? "~typesafe/jev-latest",
          habitLearningEnabled: parsed.habitLearningEnabled ?? true,
          habitShareEnabled: habitShare.sharing === "on",
          learnedShortcuts: parsed.learnedShortcuts ?? [],
          habitEntries: Array.isArray(parsed.habitEntries)
            ? parsed.habitEntries.filter(
                (e): e is HabitEntry =>
                  typeof e?.bucket === "string" &&
                  typeof e?.targetId === "string" &&
                  typeof e?.operationKey === "string" &&
                  typeof e?.count === "number",
              )
            : [],
          hasCompletedOnboarding: parsed.hasCompletedOnboarding ?? Boolean(miSession),
          isCompactGridMode: parsed.isCompactGridMode ?? true,
          hideOfflineDevices: typeof parsed.hideOfflineDevices === "boolean" ? parsed.hideOfflineDevices : false,
          hideGroupedLights: typeof parsed.hideGroupedLights === "boolean" ? parsed.hideGroupedLights : true,
          cachedXiaomiDevices: Array.isArray(parsed.cachedXiaomiDevices)
            ? upgradeCachedDevices(
                parsed.cachedXiaomiDevices,
                cachedDevicesVersion < CACHED_DEVICES_VERSION,
              )
            : [],
          cachedDevicesVersion: Math.max(cachedDevicesVersion, CACHED_DEVICES_VERSION),
          cachedHAHome: parseCachedHAHome(parsed.cachedHAHome),
          cachedModelTypes:
            parsed.cachedModelTypes && typeof parsed.cachedModelTypes === "object"
              ? parsed.cachedModelTypes
              : {},
          skin: SKINS.some((k) => k.id === parsed.skin) ? (parsed.skin as AppSkin) : "classic",
          appearance:
            parsed.appearance === "light" || parsed.appearance === "dark"
              ? parsed.appearance
              : "system",
          panelHeight: PANEL_HEIGHTS.some((h) => h.id === parsed.panelHeight) ? (parsed.panelHeight as PanelHeight) : "standard",
          climatePanel: parsed.climatePanel ?? true,
          showQuickActionsBar: parsed.showQuickActionsBar ?? true,
          enableGrokBall: parsed.enableGrokBall ?? false,
          interfaceLanguage:
            parsed.interfaceLanguage === "zh-Hans" || parsed.interfaceLanguage === "en"
              ? parsed.interfaceLanguage
              : "system",
          temperatureUnit:
            parsed.temperatureUnit === "celsius" || parsed.temperatureUnit === "fahrenheit"
              ? parsed.temperatureUnit
              : "system",
          enableGlobalHotkey: typeof parsed.enableGlobalHotkey === "boolean" ? parsed.enableGlobalHotkey : true,
          globalHotkey: normalizeGlobalShortcut(parsed.globalHotkey),
          cameraStreamURLs:
            parsed.cameraStreamURLs && typeof parsed.cameraStreamURLs === "object"
              ? Object.fromEntries(
                  Object.entries(parsed.cameraStreamURLs as Record<string, unknown>).filter(
                    (entry): entry is [string, string] => typeof entry[1] === "string" && entry[1].trim().length > 0,
                  ),
                )
              : {},
          cameraStreamQualities: normalizeCameraStreamQualityMap(parsed.cameraStreamQualities),
          layout: { ...emptyLayoutPrefs(), ...(parsed.layout ?? {}) },
          selectedHomeId: parsed.selectedHomeId ?? null,
        },
        hasLegacyCredentials,
      };
    }
  } catch {
    // ignore corrupt localStorage
  }
  return {
    settings: {
      connectionMode: "demo",
      miSession: null,
      miCloudRegion: "cn",
      autoCheckUpdates: true,
      haBaseURL: "",
      haToken: "",
      assistantBaseURL: "https://openrouter.ai/api/v1",
      openRouterApiKey: "",
      assistantKeyEndpoint: null,
      cloudConsentEndpoints: [],
      allOffOverrides: {},
      assistantModel: "~typesafe/jev-latest",
      habitLearningEnabled: true,
      habitShareEnabled: false,
      learnedShortcuts: [],
      habitEntries: [],
      hasCompletedOnboarding: false,
      isCompactGridMode: true,
      hideOfflineDevices: false,
      hideGroupedLights: true,
      cachedXiaomiDevices: [],
      cachedDevicesVersion: CACHED_DEVICES_VERSION,
      cachedHAHome: null,
      cachedModelTypes: {},
      skin: "classic",
      appearance: "system",
      panelHeight: "standard",
      climatePanel: true,
      showQuickActionsBar: true,
      enableGrokBall: false,
      layout: emptyLayoutPrefs(),
      selectedHomeId: null,
      interfaceLanguage: "system",
      temperatureUnit: "system",
      enableGlobalHotkey: true,
      globalHotkey: DEFAULT_GLOBAL_SHORTCUT,
      cameraStreamURLs: {},
      cameraStreamQualities: {},
    },
    hasLegacyCredentials: false,
  };
}

/** Writes settings without credentials; secrets belong to the Windows Credential Manager (#28). */
export function writeSettingsForStorage(settings: object): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(sanitizeSettingsForStorage(settings)));
  } catch {
    // ignore storage quota errors
  }
}

/** Removes secrets from every settings copy, including the pre-1.0 legacy key. */
export function stripCredentialFieldsFromStoredCopies(): void {
  for (const key of [STORAGE_KEY, LEGACY_STORAGE_KEY]) {
    const raw = localStorage.getItem(key);
    if (!raw) continue;
    try {
      const parsed = JSON.parse(raw) as Record<string, unknown>;
      localStorage.setItem(key, JSON.stringify(sanitizeSettingsForStorage(parsed)));
    } catch {
      // ignore corrupt copies
    }
  }
}
