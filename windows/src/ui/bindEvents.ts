import { HomeAssistantClient, homeAssistantIdentity, homeAssistantCommand, parseCachedHAHome } from "../core/homeAssistant.js";
import type { SynthesizedHome } from "../core/models.js";
import { GrokBallView } from "./grokBall.js";
import {
  ASSISTANT_PROVIDER_PRESETS,
  DelayPhrase,
  IntentReply,
  IntentValidator,
  LocalIntentParser,
  ModelIntentResolver,
  UndoPhrase,
  UserHabitMemory,
  buildAssistantContext,
  resolveHabitSharing,
  shareHabitSentence,
  habitActionable,
  inferAssistantPreset,
  assistantEndpointIdentity,
  endpointAllowsSendingSecrets,
  isLocalAssistantEndpoint,
  timeBucketLabel,
  INSECURE_ENDPOINT_MESSAGE,
  ModelActionPolicy,
  partitionHabitReceipt,
  resolveGrokBallEmotion,
  type HabitEntry,
  type HabitLastAction,
  type HabitRecordingReceipt,
  type HabitSequenceEntry,
} from "../core/assistant.js";
import {
  type HttpRequest,
  type HttpResponse,
  type HttpTransport,
  MI_CLOUD_REGIONS,
  MiAccountLogin,
  MiCloudClient,
  MiCloudError,
  type MiDeviceRecord,
  type MiRoom,
  MiotCommandMapper,
  propKeyString,
  type MiotDeviceSpec,
  type MiotPropKey,
  MiotSpecResolver,
  MiotSynthesizer,
  type MiSession,
  type QRLoginTicket,
  maskedMiUserId,
  miCloudRegionLabel,
  normalizeMiCloudRegion,
} from "../core/miCloudClient.js";
import {
  UPDATE_RELEASES_PAGE,
  UPDATE_RELEASES_URL,
  UPDATE_STORAGE_KEY,
  checkForUpdate,
  isNewerVersion,
  parseUpdateState,
  serializeUpdateState,
  type GitHubRelease,
  type UpdateState,
} from "../core/updateChecker.js";
import {
  CredentialVault,
  credentialsFromSettings,
  hasCredentials,
  parseMiSession,
  sanitizeSettingsForStorage,
  sessionWithoutPassToken,
} from "../core/secureStore.js";
import {
  type CameraStreamQuality,
  CAMERA_STREAM_QUALITIES,
  DEFAULT_CAMERA_STREAM_QUALITY,
  normalizeCameraStreamQuality,
  normalizeCameraStreamQualityMap,
} from "../core/cameraQuality.js";
import {
  type AssistantSuggestion,
  type DeviceCommand,
  type DeviceIntent,
  type EnvironmentReading,
  type HomeScene,
  type IntentPlan,
  type ScheduledCommand,
  type SmartDevice,
  allOffTargets,
  cloudRefreshDue,
  deviceCanTogglePower,
  deviceEnvironmentReading,
  deviceReadout,
  readMiotPower,
  deviceStatusSummary,
  environmentReadingPriority,
  isDeviceActiveOn,
  joinsAllOff,
  joinsAllOffByDefault,
  localizeNightShot,
  localizeAirQuality,
  localizeFanPreset,
  localizeFridgeMode,
  partitionDueTimers,
} from "../core/models.js";
import {
  type AppAppearance,
  type AppSkin,
  type LayoutPrefs,
  type PanelAnchor,
  type PanelHeight,
  type PanelPlacement,
  type TileSize,
  APPEARANCES,
  DEFAULT_GLOBAL_SHORTCUT,
  PANEL_ANCHORS,
  PANEL_HEIGHTS,
  SKINS,
  TILE_SIZES,
  applyOrder,
  targetSize,
  releaseVelocity,
  projectedOffset,
  chosenSize,
  comfort,
  emptyLayoutPrefs,
  homeOptions,
  localizeEffect,
  localizeFanMode,
  moveInOrder,
  nextSize,
  normalizeGlobalShortcut,
  pageSections,
  parsePanelPlacement,
  recordShortcutFromKeyEvent,
  resolveAppearance,
  resolvedSize,
  scopedKey,
  spans,
  withAliases,
  type HomeOption,
} from "./panelPrefs.js";
import {
  type AppLanguage,
  type LanguagePreference,
  resolveLanguage,
  setLanguage,
  speechLocale,
  t,
} from "../core/i18n.js";
import {
  type TemperatureUnitPreference,
  applyTemperatureUnit,
  displayStep,
  formatTemperature,
  formatTemperatureValue,
  getTemperatureUnit,
  stepCelsius,
  temperatureSymbol,
  toCelsius,
} from "../core/temperature.js";
import {
  KIND_CHIP,
  filterByListCut,
  foldGroupedLights,
  kindChips,
  memberGroupOwners,
  showsKindRow,
  type DeviceKindTag,
  type DeviceListCut,
} from "./listCut.js";

import { SpeechRecognitionInstance, type ConnectionMode, type LearnedShortcut, type LoadedSettings, type PersistedSettings, type ReplyBannerState, type UndoAction, type UndoStep } from "./appTypes.js";
import { APP_VERSION, CAMERA_QUALITY_TITLES, CACHED_DEVICES_VERSION, LEGACY_STORAGE_KEY, SF_ICONS, STORAGE_KEY } from "./appConstants.js";
import { demoDevices, demoScenes, quickActions } from "./demo.js";
import { createTransport, invokeTauriVoid } from "./transport.js";
import { loadSettings, stripCredentialFieldsFromStoredCopies, upgradeCachedDevices, writeSettingsForStorage } from "./settings.js";
import { CameraLiveController } from "./cameraLive.js";
import { renderClimateStrip, renderDeviceDrawer, renderSensorCard } from "./deviceViews.js";
import { renderSettingsModal } from "./settingsViews.js";
import { bindLayoutGestures } from "./layoutGestures.js";
import { bindSettingsEvents } from "./settingsEvents.js";
import { hasMatchingDomShape, inputKeepsDraft, morphMatchingDom, parseSingleElement, waitForCameraFrameGap } from "./dom.js";
export { waitForCameraFrameGap } from "./dom.js";
function withReadPower(command: DeviceCommand, isOn: boolean): DeviceCommand {
  switch (command.kind) {
    case "setLightPower":
    case "setClimatePower":
    case "setFanPower":
    case "setSwitch":
      return { ...command, isOn };
    default:
      return command;
  }
}

import type { MenuMijiaWindowsApp } from "./app.js";

  export function bindEvents(host: MenuMijiaWindowsApp): void {
    host.root.querySelectorAll<HTMLElement>("[data-grok-toggle]").forEach((button) => {
      button.addEventListener("click", () => {
        host.setGrokBallStageExpanded(!host.isGrokBallStageExpanded);
      });
    });
    const inputEl = host.root.querySelector<HTMLInputElement>("#command-input");
    const sendBtn = host.root.querySelector<HTMLButtonElement>("#btn-send");
    const micBtn = host.root.querySelector<HTMLButtonElement>("#btn-mic");
    const submitCommandInput = () => {
      if (!inputEl) return;
      const value = inputEl.value;
      const restoreFocus = document.activeElement === inputEl;
      inputEl.value = "";
      void host.handleNaturalCommand(value).finally(() => {
        if (!restoreFocus) return;
        const active = document.activeElement;
        if (active !== null && active !== inputEl && active !== document.body) return;
        host.root.querySelector<HTMLInputElement>("#command-input")?.focus({ preventScroll: true });
      });
    };

    inputEl?.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        submitCommandInput();
      }
    });
    sendBtn?.addEventListener("click", () => {
      submitCommandInput();
    });
    micBtn?.addEventListener("click", () => {
      host.toggleVoiceInput();
    });

    host.root.querySelector("#btn-toggle-assistant")?.addEventListener("click", () => {
      host.isShowingAssistantBar = !host.isShowingAssistantBar;
      host.render();
      if (host.isShowingAssistantBar) {
        host.root.querySelector<HTMLInputElement>("#command-input")?.focus();
      }
    });

    host.bindAllOffControl();

    host.root.querySelector("#btn-done-editing")?.addEventListener("click", () => host.stopEditing());

    host.root.querySelector("#btn-home-menu")?.addEventListener("click", () => {
      host.isHomeMenuOpen = !host.isHomeMenuOpen;
      host.render();
    });
    host.root.querySelectorAll<HTMLElement>("[data-home]").forEach((btn) => {
      btn.addEventListener("click", () => host.selectHome(btn.dataset.home || null));
    });
    host.root.querySelectorAll<HTMLElement>("[data-close-menus]").forEach((el) => {
      el.addEventListener("pointerdown", (e) => {
        e.preventDefault();
        host.isHomeMenuOpen = false;
        host.ctxMenu = null;
        host.render();
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-collapse]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const key = scopedKey(host.pageKey, btn.dataset.collapse ?? "");
        const set = new Set(host.layout.collapsed);
        if (set.has(key)) set.delete(key); else set.add(key);
        host.layout.collapsed = [...set];
        host.saveLayout();
        host.animateEntrance = !set.has(key);
        host.render();
      });
      btn.addEventListener("contextmenu", (e) => {
        const gid = btn.dataset.groupId;
        if (!gid) return;
        e.preventDefault();
        host.ctxMenu = { x: e.clientX, y: e.clientY, groupId: gid };
        host.render();
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-set-size]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const [id, size] = (btn.dataset.setSize ?? "").split(":");
        if (!id || !size) return;
        host.layout.tileSizes[scopedKey(host.pageKey, id)] = size as TileSize;
        host.saveLayout();
        host.ctxMenu = null;
        host.render();
      });
    });
    host.root.querySelectorAll<HTMLElement>("[data-set-group]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const raw = btn.dataset.setGroup ?? "";
        const i = raw.lastIndexOf(":");
        const id = raw.slice(0, i);
        const gid = raw.slice(i + 1);
        if (gid) host.layout.groupMap[id] = gid; else delete host.layout.groupMap[id];
        host.saveLayout();
        host.ctxMenu = null;
        host.render();
      });
    });
    host.root.querySelectorAll<HTMLElement>("[data-new-group]").forEach((btn) => {
      btn.addEventListener("click", () => host.openPrompt({ kind: "newGroup", deviceId: btn.dataset.newGroup ?? "" }));
    });
    host.root.querySelectorAll<HTMLElement>("[data-rename-device]").forEach((btn) => {
      btn.addEventListener("click", () => host.openPrompt({ kind: "renameDevice", deviceId: btn.dataset.renameDevice ?? "" }));
    });
    host.root.querySelector("[data-start-editing]")?.addEventListener("click", () => {
      host.ctxMenu = null;
      host.startEditing();
    });
    host.root.querySelectorAll<HTMLElement>("[data-group-action]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const [action, gid] = (btn.dataset.groupAction ?? "").split(":");
        if (!gid) return;
        host.ctxMenu = null;
        const groups = host.layout.groups;
        const i = groups.findIndex((g) => g.id === gid);
        if (action === "rename") { host.openPrompt({ kind: "renameGroup", groupId: gid }); return; }
        if (action === "up" && i > 0) [groups[i - 1], groups[i]] = [groups[i]!, groups[i - 1]!];
        if (action === "down" && i >= 0 && i < groups.length - 1) [groups[i + 1], groups[i]] = [groups[i]!, groups[i + 1]!];
        if (action === "delete") {
          host.layout.groups = groups.filter((g) => g.id !== gid);
          for (const [d, g] of Object.entries(host.layout.groupMap)) if (g === gid) delete host.layout.groupMap[d];
        }
        host.saveLayout();
        host.render();
      });
    });

    const promptInput = host.root.querySelector<HTMLInputElement>("#prompt-input");
    if (promptInput && document.activeElement !== promptInput) {
      promptInput.focus();
      promptInput.select();
    }
    promptInput?.addEventListener("keydown", (e) => {
      if (e.key === "Enter") host.savePrompt(promptInput.value);
      if (e.key === "Escape") { e.stopPropagation(); host.closePrompt(); }
    });
    host.root.querySelector("#btn-prompt-save")?.addEventListener("click", () => host.savePrompt(promptInput?.value ?? ""));
    host.root.querySelector("#btn-prompt-reset")?.addEventListener("click", () => host.savePrompt(""));
    host.root.querySelectorAll<HTMLElement>("[data-prompt-cancel]").forEach((el) => el.addEventListener("click", () => host.closePrompt()));

    host.root.querySelectorAll<HTMLElement>("[data-cycle-size]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const dev = host.devices.find((d) => d.id === btn.dataset.cycleSize);
        if (!dev) return;
        host.layout.tileSizes[scopedKey(host.pageKey, dev.id)] = nextSize(host.tileSize(dev));
        host.saveLayout();
        host.render();
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-acstep]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const [id, dir] = (btn.dataset.acstep ?? "").split(":");
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "climate") return;
        const k = dev.kind;
        const step = stepCelsius(k.step || 1);
        const next = k.targetTemperature + Number(dir) * step;
        // Round to the thermostat's own step so repeated °F taps do not drift off the °C grid.
        const snapped = Math.round(next / step) * step;
        const temperature = Math.min(k.maxTemp, Math.max(k.minTemp, Number(snapped.toFixed(2))));
        void host.executeSingleCommand(
          dev,
          { kind: "setClimateTemperature", entityId: k.entityId, temperature },
          t("已将{name}设为 {temp}", { name: dev.name, temp: formatTemperature(temperature) }),
          { targetId: dev.id, operation: { kind: "targetTemperature", celsius: temperature } },
        );
      });
    });
    host.root.querySelectorAll<HTMLElement>("[data-acfan]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const raw = btn.dataset.acfan ?? "";
        const i = raw.indexOf(":");
        const dev = host.devices.find((d) => d.id === raw.slice(0, i));
        if (!dev || dev.kind.kind !== "climate") return;
        const fanMode = raw.slice(i + 1);
        void host.executeSingleCommand(
          dev,
          { kind: "setClimateFanMode", entityId: dev.kind.entityId, fanMode },
          t("已将{name}风速设为 {speed}", { name: dev.name, speed: localizeFanMode(fanMode) }),
          { targetId: dev.id, operation: { kind: "fanSpeed", speed: fanMode } },
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-skin]").forEach((btn) => {
      btn.addEventListener("click", () => {
        host.settings.skin = btn.dataset.skin as AppSkin;
        host.saveSettings();
        host.render();
      });
    });
    host.root.querySelectorAll<HTMLElement>("[data-appearance]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const value = btn.dataset.appearance;
        host.settings.appearance =
          value === "light" || value === "dark" ? value : "system";
        host.saveSettings();
        host.render();
      });
    });
    host.root.querySelector("#btn-toggle-appearance")?.addEventListener("click", () => {
      host.settings.appearance = host.effectiveAppearance === "light" ? "dark" : "light";
      host.saveSettings();
      host.render();
    });
    host.root.querySelectorAll<HTMLElement>("[data-interface-language]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const value = btn.dataset.interfaceLanguage;
        host.settings.interfaceLanguage =
          value === "zh-Hans" || value === "en" ? value : "system";
        host.applyInterfaceLanguage();
        host.saveSettings();
        host.render();
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-temperature-unit]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const value = btn.dataset.temperatureUnit;
        host.settings.temperatureUnit =
          value === "celsius" || value === "fahrenheit" ? value : "system";
        host.applyTemperatureSetting();
        host.saveSettings();
        host.render();
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-panel-height]").forEach((btn) => {
      btn.addEventListener("click", () => {
        host.settings.panelHeight = btn.dataset.panelHeight as PanelHeight;
        host.saveSettings();
        host.applyPanelHeight();
        host.render();
      });
    });
    host.root.querySelectorAll<HTMLElement>("[data-panel-anchor]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const known = PANEL_ANCHORS.find((item) => item.id === btn.dataset.panelAnchor);
        if (!known) return;
        host.panelAnchor = known.id;
        invokeTauriVoid("set_panel_placement", { anchor: known.id });
        host.render();
      });
    });
    host.root.querySelector<HTMLInputElement>("#settings-climate-panel")?.addEventListener("change", (e) => {
      host.settings.climatePanel = (e.target as HTMLInputElement).checked;
      host.saveSettings();
      host.render();
    });
    host.root.querySelector<HTMLInputElement>("#settings-hide-offline")?.addEventListener("change", (e) => {
      host.settings.hideOfflineDevices = (e.target as HTMLInputElement).checked;
      host.saveSettings();
      host.render();
    });
    host.root.querySelector<HTMLInputElement>("#settings-hide-grouped-lights")?.addEventListener("change", (e) => {
      host.settings.hideGroupedLights = (e.target as HTMLInputElement).checked;
      host.saveSettings();
      host.render();
    });
    host.root.querySelector<HTMLInputElement>("#settings-quick-actions")?.addEventListener("change", (e) => {
      host.settings.showQuickActionsBar = (e.target as HTMLInputElement).checked;
      host.saveSettings();
      host.render();
    });
    host.root.querySelector<HTMLInputElement>("#settings-grok-ball")?.addEventListener("change", (e) => {
      host.settings.enableGrokBall = (e.target as HTMLInputElement).checked;
      if (!host.settings.enableGrokBall) {
        host.isGrokBallStageExpanded = false;
      }
      host.saveSettings();
      host.applyPanelHeight();
      host.render();
    });

    host.root.querySelector<HTMLInputElement>("#settings-enable-hotkey")?.addEventListener("change", (e) => {
      host.settings.enableGlobalHotkey = (e.target as HTMLInputElement).checked;
      host.isRecordingHotkey = false;
      host.hotkeyNeedsHint = false;
      host.saveSettings();
      void host.applyGlobalHotkey();
      host.render();
    });

    host.root.querySelector("#btn-record-hotkey")?.addEventListener("click", () => {
      host.isRecordingHotkey = !host.isRecordingHotkey;
      host.hotkeyNeedsHint = false;
      host.render();
    });

    host.root.querySelector("#btn-reset-hotkey")?.addEventListener("click", () => {
      host.isRecordingHotkey = false;
      host.hotkeyNeedsHint = false;
      host.settings.globalHotkey = DEFAULT_GLOBAL_SHORTCUT;
      host.saveSettings();
      void host.applyGlobalHotkey();
      host.render();
    });

    host.root.querySelector("#btn-retry-hotkey")?.addEventListener("click", () => {
      void host.applyGlobalHotkey();
    });

    host.root.querySelector("#btn-hide-panel")?.addEventListener("click", () => {
      invokeTauriVoid("set_pin_popover", { pin: false });
      invokeTauriVoid("hide_panel");
    });

    host.root.querySelector("#btn-quit-app")?.addEventListener("click", () => {
      invokeTauriVoid("quit_app");
    });

    host.root.querySelector("#btn-settings-quit")?.addEventListener("click", () => {
      invokeTauriVoid("quit_app");
    });

    host.root.querySelector("#btn-toggle-grid")?.addEventListener("click", () => {
      host.settings.isCompactGridMode = !host.settings.isCompactGridMode;
      host.saveSettings();
      host.render();
    });

    host.root.querySelector("#btn-toggle-hide-offline")?.addEventListener("click", () => {
      host.settings.hideOfflineDevices = !host.settings.hideOfflineDevices;
      host.saveSettings();
      host.render();
    });

    host.root.querySelector("#btn-show-offline")?.addEventListener("click", () => {
      host.settings.hideOfflineDevices = false;
      host.saveSettings();
      host.render();
    });

    host.root.querySelector("#btn-refresh")?.addEventListener("click", () => {
      if (host.settings.connectionMode === "homeAssistant" || host.settings.connectionMode === "xiaomiCloud" && host.settings.miSession) {
        void host.refreshDevices(false);
      } else {
        host.render();
      }
    });

    host.root.querySelector("#btn-footer-qr")?.addEventListener("click", () => {
      host.activeSheet = "settings";
      host.render();
      void host.startXiaomiQRLogin();
    });

    host.root.querySelector("#btn-empty-resync")?.addEventListener("click", () => {
      void host.refreshDevices(false);
    });

    host.root.querySelector("#btn-empty-settings")?.addEventListener("click", () => {
      host.openSettingsSheet();
    });

    host.root.querySelector("#btn-settings")?.addEventListener("click", () => {
      host.openSettingsSheet();
    });

    host.root.querySelector("#btn-undo")?.addEventListener("click", () => {
      void host.performUndo();
    });

    host.root.querySelectorAll<HTMLElement>("[data-suggestion-id]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const suggestion = host.pendingSuggestions.find((s) => s.id === btn.dataset.suggestionId);
        if (!suggestion) return;
        host.pendingSuggestions = host.pendingSuggestions.filter((s) => s.id !== suggestion.id);
        const aliasedDevices = withAliases(host.layout, host.devices);
        const intents = IntentValidator.sanitize(suggestion.intents, aliasedDevices, host.scenes);
        void host.executeIntents(intents, IntentReply.describe(intents, aliasedDevices, host.scenes), t("已确认"), { recordHabits: true });
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-run-missed]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const item = host.missedScheduledCommands.find((c) => c.id === btn.dataset.runMissed);
        if (!item) return;
        host.missedScheduledCommands = host.missedScheduledCommands.filter((c) => c.id !== item.id);
        void host.handleNaturalCommand(item.command, true);
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-dismiss-missed]").forEach((btn) => {
      btn.addEventListener("click", () => {
        host.missedScheduledCommands = host.missedScheduledCommands.filter((c) => c.id !== btn.dataset.dismissMissed);
        host.render();
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-cancel-timer]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.cancelTimer;
        host.scheduledCommands = host.scheduledCommands.filter((c) => c.id !== id);
        host.render();
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-scene-cmd]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const cmd = btn.dataset.sceneCmd;
        if (cmd) void host.handleNaturalCommand(cmd);
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-ha-scene]").forEach((button) => {
      button.addEventListener("click", () => {
        const scene = host.scenes.find((item) => item.id === button.dataset.haScene);
        if (!scene) return;
        const intents: DeviceIntent[] = [{targetId:scene.id,operation:{kind:"activateScene"}}];
        void host.executeIntents(intents, IntentReply.describe(intents, host.devices, host.scenes), t("0ms 本地直达"), {recordHabits:true});
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-proactive-id]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const suggestion = host.currentProactiveSuggestions().find((s) => s.id === btn.dataset.proactiveId);
        if (!suggestion) return;
        const aliasedDevices = withAliases(host.layout, host.devices);
        const intents = IntentValidator.sanitize(suggestion.intents, aliasedDevices, host.scenes);
        if (intents.length === 0) return;
        host.isShowingAssistantBar = true;
        host.setGrokBallStageExpanded(false);
        void host.executeIntents(intents, IntentReply.describe(intents, aliasedDevices, host.scenes), t("猜你想控"), { recordHabits: true });
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-room]").forEach((btn) => {
      btn.addEventListener("click", () => {
        host.selectedRoom = btn.dataset.room ?? "全部";
        host.animateEntrance = true;
        host.expandedDeviceId = null;
        host.render();
        host.root.querySelector(".cc-room-pill.is-active")?.scrollIntoView({ inline: "center", block: "nearest", behavior: "smooth" });
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-kind]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const tag = host.kindTagFromDataset(btn.dataset.kind);
        if (!tag) return;
        host.selectDeviceKind(tag);
        host.animateEntrance = true;
        host.expandedDeviceId = null;
        host.render();
        host.root.querySelector(`[data-kind="${tag}"]`)?.scrollIntoView({ inline: "center", block: "nearest", behavior: "smooth" });
      });
    });

    const toggleDeviceById = (id: string) => {
      const dev = host.devices.find((d) => d.id === id);
      if (!dev || dev.kind.kind === "sensor" || !deviceCanTogglePower(dev)) return;
      if (dev.kind.kind === "fridge") {
        host.expandedDeviceId = host.expandedDeviceId === id ? null : id;
        host.render();
        return;
      }
      if (host.waitingDeviceIds.has(id)) return;
      const nextOn = !isDeviceActiveOn(dev);
      host.poppedDeviceId = dev.id;
      const cmds = IntentValidator.commandsForIntent(
        { targetId: dev.id, operation: { kind: "power", isOn: nextOn } },
        dev,
      );
      const firstCmd = cmds[0];
      if (!firstCmd) return;
      const waitsForCloud = host.settings.connectionMode !== "demo";
      if (waitsForCloud) {
        host.waitingDeviceIds.add(id);
        host.render();
      }
      void host.executeSingleCommand(
        dev,
        firstCmd,
        `已${nextOn ? t("打开") : t("关闭")}${dev.name}`,
        { targetId: dev.id, operation: { kind: "power", isOn: nextOn } },
        waitsForCloud,
      ).finally(() => {
        if (!waitsForCloud) return;
        host.waitingDeviceIds.delete(id);
        host.render();
      });
    };

    host.root.querySelectorAll<HTMLElement>("[data-toggle-device]").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        const id = btn.dataset.toggleDevice;
        if (id) toggleDeviceById(id);
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-body-device]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.bodyDevice;
        if (!id) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev) return;
        const k = dev.kind.kind;
        const writable = deviceCanTogglePower(dev);
        if (k === "camera") {
          if (writable && dev.isOnline && !dev.kind.isOn) {
            toggleDeviceById(id);
          }
          host.cameraLive.openCameraLiveView(id);
        } else if (k === "light" || k === "climate" || k === "fan" || k === "fridge") {
          const canExpand =
            k === "fridge" ||
            k === "fan" ||
            (dev.kind.kind === "light" &&
              (dev.kind.brightnessWritable !== false || dev.kind.colorWritable !== false || dev.kind.availableEffects.length > 0)) ||
            (dev.kind.kind === "climate" &&
              (dev.kind.temperatureWritable !== false || dev.kind.availableModes.length > 0 || dev.kind.availableFanModes.length > 0));
          if (!canExpand) return;
          host.expandedDeviceId = host.expandedDeviceId === id ? null : id;
          host.render();
        } else if (writable) {
          toggleDeviceById(id);
        }
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-expand-device]").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        const id = btn.dataset.expandDevice ?? null;
        host.expandedDeviceId = host.expandedDeviceId === id ? null : id;
        host.render();
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-lighteffect]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const dev = host.devices.find((d) => d.id === btn.dataset.lighteffect);
        const effect = btn.dataset.effect;
        if (!dev || dev.kind.kind !== "light" || !effect) return;
        void host.executeSingleCommand(
          dev,
          { kind: "setLightEffect", entityId: dev.kind.entityId, effect },
          t("已切换{name}灯光模式", { name: dev.name }),
          { targetId: dev.id, operation: { kind: "lightEffect", effect } },
        );
      });
    });

    host.root.querySelectorAll<HTMLInputElement>("[data-brightness]").forEach((slider) => {
      slider.addEventListener("change", () => {
        const id = slider.dataset.brightness;
        if (!id) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "light") return;
        const percent = Number(slider.value);
        void host.executeSingleCommand(
          dev,
          { kind: "setLightBrightness", entityId: dev.kind.entityId, percent },
          t("已将{name}亮度设为 {percent}%", { name: dev.name, percent: percent }),
          { targetId: dev.id, operation: { kind: "brightness", percent } },
        );
      });
    });

    host.root.querySelectorAll<HTMLInputElement>("[data-colortemp]").forEach((slider) => {
      slider.addEventListener("change", () => {
        const id = slider.dataset.colortemp;
        if (!id) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "light") return;
        const kelvin = Number(slider.value);
        void host.executeSingleCommand(
          dev,
          { kind: "setLightColorTemp", entityId: dev.kind.entityId, kelvin },
          t("已将{name}色温设为 {kelvin}K", { name: dev.name, kelvin: kelvin }),
          { targetId: dev.id, operation: { kind: "colorTemperature", kelvin } },
        );
      });
    });

    host.root.querySelectorAll<HTMLInputElement>("[data-actemp]").forEach((slider) => {
      slider.addEventListener("change", () => {
        const id = slider.dataset.actemp;
        if (!id) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "climate") return;
        // The slider works in display units; the command carries Celsius (#52).
        const temperature = Number(toCelsius(Number(slider.value)).toFixed(2));
        void host.executeSingleCommand(
          dev,
          { kind: "setClimateTemperature", entityId: dev.kind.entityId, temperature },
          t("已将{name}设为 {temp}", { name: dev.name, temp: formatTemperature(temperature) }),
          { targetId: dev.id, operation: { kind: "targetTemperature", celsius: temperature } },
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-acmode]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const raw = btn.dataset.acmode;
        if (!raw) return;
        const [id, hvacMode] = raw.split(":");
        if (!id || !hvacMode) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "climate") return;
        void host.executeSingleCommand(
          dev,
          { kind: "setClimateMode", entityId: dev.kind.entityId, hvacMode },
          t("已切换{name}模式", { name: dev.name }),
          { targetId: dev.id, operation: { kind: "hvacMode", mode: hvacMode } },
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-fanpreset]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const raw = btn.dataset.fanpreset;
        if (!raw) return;
        const [id, presetMode] = raw.split(":");
        if (!id || !presetMode) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "fan") return;
        void host.executeSingleCommand(
          dev,
          { kind: "setFanPresetMode", entityId: dev.kind.entityId, presetMode },
          t("已将{name}设为 {speed}", { name: dev.name, speed: IntentReply.fanSpeedLabel(presetMode) }),
          { targetId: dev.id, operation: { kind: "fanSpeed", speed: presetMode } },
        );
      });
    });

    host.root.querySelectorAll<HTMLInputElement>("[data-fanpercent]").forEach((slider) => {
      slider.addEventListener("change", () => {
        const id = slider.dataset.fanpercent;
        if (!id) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "fan") return;
        const percent = Math.max(1, Math.min(100, Math.round(Number(slider.value))));
        void host.executeSingleCommand(
          dev,
          { kind: "setFanPercentage", entityId: dev.kind.entityId, percent },
          t("已将{name}风速设为 {speed}", { name: dev.name, speed: `${percent}%` }),
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-fanosc]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.fanosc;
        if (!id) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "fan") return;
        const nextOsc = !dev.kind.isOscillating;
        void host.executeSingleCommand(
          dev,
          { kind: "setFanOscillating", entityId: dev.kind.entityId, oscillating: nextOsc },
          `已${nextOsc ? t("开启") : t("关闭")}${dev.name}摇头`,
          { targetId: dev.id, operation: { kind: "oscillation", enabled: nextOsc } },
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-camera-live]").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        const id = btn.dataset.cameraLive;
        if (id) host.cameraLive.openCameraLiveView(id);
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-cameramotion]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.cameramotion;
        if (!id) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "camera" || !dev.kind.motionDetectionEntityId) return;
        const nextMotion = !dev.kind.isMotionDetectionOn;
        void host.executeSingleCommand(
          dev,
          { kind: "setSwitch", entityId: dev.kind.motionDetectionEntityId, isOn: nextMotion },
          t("已{action}{name}移动侦测", { action: nextMotion ? t("开启") : t("关闭"), name: dev.name }),
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-cameranight]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const raw = btn.dataset.cameranight;
        if (!raw) return;
        const [id, mode] = raw.split(":");
        if (!id || !mode) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "camera") return;
        void host.executeSingleCommand(
          dev,
          { kind: "setSelectOption", entityId: dev.kind.entityId, option: mode },
          t("已将{name}设为{mode}", { name: dev.name, mode: localizeNightShot(mode) }),
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-fridgemode]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const raw = btn.dataset.fridgemode;
        if (!raw) return;
        const [id, mode] = raw.split(":");
        if (!id || !mode) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "fridge" || !dev.kind.modeEntityId) return;
        void host.executeSingleCommand(
          dev,
          { kind: "setSelectOption", entityId: dev.kind.modeEntityId, option: mode },
          t("已将{name}设为{mode}", { name: dev.name, mode: localizeFridgeMode(mode) }),
        );
      });
    });

    host.root.querySelectorAll<HTMLElement>("[data-fridgestep]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const raw = btn.dataset.fridgestep;
        if (!raw) return;
        const [id, zone, deltaStr] = raw.split(":");
        const delta = Number(deltaStr);
        if (!id || !zone || !Number.isFinite(delta)) return;
        const dev = host.devices.find((d) => d.id === id);
        if (!dev || dev.kind.kind !== "fridge") return;
        const isFreezer = zone === "freezer";
        const entityId = isFreezer ? dev.kind.freezerTargetEntityId : dev.kind.fridgeTargetEntityId;
        if (!entityId) return;
        const next = isFreezer
          ? Math.max(-24, Math.min(-15, dev.kind.freezerTargetTemp + delta))
          : Math.max(2, Math.min(8, dev.kind.fridgeTargetTemp + delta));
        void host.executeSingleCommand(
          dev,
          { kind: "setNumberValue", entityId, value: next },
          t("已将{name}设为 {temp}", { name: dev.name, temp: formatTemperature(next) }),
        );
      });
    });

    host.cameraLive.bindEvents();

    host.bindSettingsEvents();
  }

