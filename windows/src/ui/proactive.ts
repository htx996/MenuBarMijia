import type { MenuMijiaWindowsApp } from "./app.js";

const PROACTIVE_RETRY_COOLDOWN_MS = 5 * 60_000;
import { t } from "../core/i18n.js";
import {
  IntentValidator,
  ModelIntentResolver,
  UserHabitMemory,
  assistantEndpointIdentity,
  buildAssistantContext,
  endpointAllowsSendingSecrets,
  habitActionable,
  isLocalAssistantEndpoint,
  resolveGrokBallEmotion,
  timeBucketLabel,
} from "../core/assistant.js";
import type { AssistantSuggestion, DeviceIntent, SmartDevice } from "../core/models.js";
import { GrokBallView } from "./grokBall.js";
import { withAliases } from "./panelPrefs.js";
import { buildInverseCommand } from "./intentExecution.js";

export function proactiveSignature(host: MenuMijiaWindowsApp): string {
    const bucket = timeBucketLabel(new Date().getHours());
    const readings = host.computedEnvironmentReadings
      .map(
        (reading) =>
          `${reading.temperature !== null ? Math.round(reading.temperature) : "-"}|${
            reading.humidity !== null ? Math.round(reading.humidity / 5) * 5 : "-"
          }`,
      )
      .join(",");
    return `${bucket}|${readings}`;
  }

export function isIntentReversibleOnDevice(host: MenuMijiaWindowsApp, intent: DeviceIntent, device: SmartDevice): { reversible: boolean; nextDevice: SmartDevice } {
    if (!device.isOnline || (device.kind.kind === "plug" && device.kind.switchEntityId.startsWith("button."))) {
      return { reversible: false, nextDevice: device };
    }
    const normalized = IntentValidator.normalize(intent.operation, device);
    if (!normalized) return { reversible: false, nextDevice: device };
    if (
      host.settings.connectionMode === "homeAssistant" &&
      normalized.kind === "power" &&
      normalized.isOn &&
      device.kind.kind === "climate" &&
      !device.kind.availableModes.some((mode) => mode !== "off" && mode !== "unknown" && mode !== "unavailable")
    ) {
      return { reversible: false, nextDevice: device };
    }
    const normalizedIntent: DeviceIntent = { targetId: intent.targetId, operation: normalized };
    const commands = IntentValidator.commandsForIntent(normalizedIntent, device);
    if (commands.length === 0 || !commands.every((command) => buildInverseCommand(device, command).length > 0)) {
      return { reversible: false, nextDevice: device };
    }
    const k = device.kind;
    let nextKind = k;
    if (k.kind === "light") {
      if (normalized.kind === "power") nextKind = { ...k, isOn: normalized.isOn };
      else if (normalized.kind === "brightness") nextKind = { ...k, isOn: true, brightnessPercent: normalized.percent };
      else if (normalized.kind === "colorTemperature") nextKind = { ...k, isOn: true, colorTempKelvin: normalized.kelvin, currentEffect: null };
      else if (normalized.kind === "lightEffect") nextKind = { ...k, isOn: true, currentEffect: normalized.effect };
    } else if (k.kind === "climate") {
      if (normalized.kind === "power") {
        const resumeMode = k.hvacMode === "off" ? (k.availableModes.find((m) => m !== "off") ?? "cool") : k.hvacMode;
        nextKind = { ...k, isOn: normalized.isOn, hvacMode: normalized.isOn ? resumeMode : "off" };
      } else if (normalized.kind === "hvacMode") {
        nextKind = { ...k, isOn: normalized.mode !== "off", hvacMode: normalized.mode };
      } else if (normalized.kind === "targetTemperature") {
        nextKind = { ...k, targetTemperature: normalized.celsius };
      } else if (normalized.kind === "fanSpeed") {
        nextKind = { ...k, fanMode: normalized.speed };
      }
    }
    return { reversible: true, nextDevice: { ...device, kind: nextKind } };
  }

  /** The Top-4 zero-delay suggestions: the AI cache when fresh, otherwise ranked locally (#113). */
export function currentProactiveSuggestions(host: MenuMijiaWindowsApp): AssistantSuggestion[] {
    if (host.pendingSuggestions.length > 0 && !host.isGrokBallStageExpanded) return [];
    const signature = proactiveSignature(host);
    const aliasedDevices = withAliases(host.layout, host.devices);
    const local = new UserHabitMemory(host.settings.habitEntries, host.habitSequences(), host.lastHabitAction()).topSuggestions({
      devices: aliasedDevices,
      scenes: host.isGrokBallStageExpanded ? [] : host.scenes,
      environmentReadings: host.computedEnvironmentReadings,
    });
    const cached = host.aiProactiveSignature === signature ? host.aiProactiveSuggestions ?? [] : [];
    const fallback = host.isGrokBallStageExpanded
      ? new UserHabitMemory([]).topSuggestions({ devices: aliasedDevices, scenes: [], limit: aliasedDevices.length + 4 })
      : [];
    const result: AssistantSuggestion[] = [];
    for (const item of [...cached, ...local, ...fallback]) {
      if (host.isGrokBallStageExpanded && item.intents.some((intent) => intent.operation.kind === "activateScene")) continue;
      const actionableIntents = item.intents.filter((intent) => habitActionable(intent, aliasedDevices, host.scenes));
      if (actionableIntents.length === 0) continue;
      if (host.isGrokBallStageExpanded) {
        if (!item.intents.every((intent) => aliasedDevices.some((entry) => entry.id === intent.targetId && entry.isOnline))) continue;
        const stateByTarget = new Map<string, SmartDevice>();
        let allReversible = true;
        for (const intent of actionableIntents) {
          const current = stateByTarget.get(intent.targetId) ?? aliasedDevices.find((entry) => entry.id === intent.targetId);
          if (!current) {
            allReversible = false;
            break;
          }
          const check = isIntentReversibleOnDevice(host, intent, current);
          if (!check.reversible) {
            allReversible = false;
            break;
          }
          stateByTarget.set(intent.targetId, check.nextDevice);
        }
        if (!allReversible) continue;
      }
      const candidate: AssistantSuggestion = { ...item, intents: actionableIntents };
      if (result.some((existing) => JSON.stringify(existing.intents) === JSON.stringify(candidate.intents))) continue;
      result.push(candidate);
      if (result.length === 4) break;
    }
    return result;
  }

export function syncGrokBallEmotion(host: MenuMijiaWindowsApp): void {
    const now = Date.now();
    host.grokBall.setEmotion(resolveGrokBallEmotion({
      timeBucket: timeBucketLabel(new Date(now).getHours()),
      activeDeviceCount: host.activeDeviceCount,
      speechListening: host.isListeningVoice,
      assistantState: host.isResolvingIntent ? "thinking" : host.pendingSuggestions.length > 0 ? "awaitingChoice" : "idle",
      isRecommending: host.isRefreshingProactive,
      hasErrorToast: host.replyBanner?.isError === true || Boolean(host.haConnectionError),
      isStageExpanded: host.isGrokBallStageExpanded,
      isPointerTracking: now < host.grokBallPointerUntil,
      hasRecentCelebration: now < host.grokBallCelebrationUntil,
    }));
  }

export function renderGrokBallStage(host: MenuMijiaWindowsApp): string {
    if (!host.isGrokBallStageExpanded) return "";
    return `<section class="cc-grok-stage" aria-label="${t("猜你想控")}">
      ${currentProactiveSuggestions(host).slice(0, 4).map((item) => `
        <button class="cc-grok-pill" data-proactive-id="${host.escapeHtml(item.id)}" title="${host.escapeHtml(item.title)}">
          ${host.escapeHtml(item.title)}</button>`).join("")}
    </section>`;
  }

export function renderGrokBallSidebar(host: MenuMijiaWindowsApp): string {
    if (!host.settings.enableGrokBall) return "";
    return `<aside class="cc-grok-sidebar" aria-label="${t("猜你想控")}">
      <button class="cc-grok-toggle" id="btn-grok-ball" data-grok-toggle aria-label="${t("猜你想控")}" aria-expanded="${host.isGrokBallStageExpanded}"><span data-grok-slot></span></button>
      ${renderGrokBallStage(host)}
    </aside>`;
  }

export function setGrokBallStageExpanded(host: MenuMijiaWindowsApp, expanded: boolean): void {
    if (host.isGrokBallStageExpanded === expanded) return;
    host.isGrokBallStageExpanded = expanded;
    host.applyPanelHeight();
    if (window.__TAURI_INTERNALS__) {
      void host.panelGeometryUpdates.then(() => host.render());
    } else {
      host.render();
    }
  }

  /**
   * Silent background AI refresh for proactive suggestions (#113): fires only when the
   * time bucket or room climate changed, never blocks the panel, never asks for consent,
   * and keeps the previous cache when the request fails.
   */
export function maybeRefreshProactiveInBackground(host: MenuMijiaWindowsApp): void {
    if (host.isRefreshingProactive || host.settings.connectionMode === "demo") return;
    if (host.proactiveRetryAfterMs !== null && Date.now() < host.proactiveRetryAfterMs) return;
    const signature = proactiveSignature(host);
    if (signature === host.aiProactiveSignature) return;
    const baseURL = host.settings.assistantBaseURL.trim() || "https://openrouter.ai/api/v1";
    if (!endpointAllowsSendingSecrets(baseURL)) return;
    const apiKey = host.apiKeyFor(baseURL);
    const isLoopback = isLocalAssistantEndpoint(baseURL);
    if (!apiKey && !isLoopback) return;
    if (!isLoopback) {
      const endpoint = assistantEndpointIdentity(baseURL);
      if (!endpoint || !host.settings.cloudConsentEndpoints.includes(endpoint)) return;
    }
    const sourceRevision = host.sourceRevision;
    const selectedHomeId = host.settings.selectedHomeId;
    host.isRefreshingProactive = true;
    const resolver = new ModelIntentResolver(
      { baseURL, model: host.settings.assistantModel, apiKey },
      host.transport,
    );
    resolver
      .recommendProactiveSuggestions(
        host.devices,
        host.scenes,
        buildAssistantContext({
          now: new Date(),
          readings: host.computedEnvironmentReadings,
          devices: host.devices,
          scenes: host.scenes,
          sharing: host.settings.habitShareEnabled ? "on" : "off",
          memory: new UserHabitMemory(host.settings.habitEntries, host.habitSequences(), host.lastHabitAction()),
          phrases: host.settings.learnedShortcuts.map((shortcut) => ({
            phrase: shortcut.phrase,
            intents: shortcut.intents,
          })),
          mention: { kind: "none" },
        }),
      )
      .then((suggestions) => {
        if (sourceRevision !== host.sourceRevision || host.settings.selectedHomeId !== selectedHomeId) return;
        host.isRefreshingProactive = false;
        if (proactiveSignature(host) === signature) {
          // The context counts as served only once a usable result landed (Codex #116 review).
          host.aiProactiveSignature = signature;
          if (suggestions.length > 0) {
            host.aiProactiveSuggestions = suggestions;
          } else {
            // An empty result is a valid "home is ideal" answer: drop any older cache so the
            // local ranking takes over instead of stale suggestions (Codex #116 re-review).
            host.aiProactiveSuggestions = null;
          }
          if (!host.hasBlockingPanelInteraction()) host.render();
        }
      })
      .catch(() => {
        if (sourceRevision !== host.sourceRevision || host.settings.selectedHomeId !== selectedHomeId) return;
        // Silent: the previous cache keeps showing; retry after a cooldown (Codex #116 review).
        host.isRefreshingProactive = false;
        host.proactiveRetryAfterMs = Date.now() + PROACTIVE_RETRY_COOLDOWN_MS;
      });
  }

export function invalidateSourceControl(host: MenuMijiaWindowsApp): void {
    host.sourceRevision += 1;
    host.syncGeneration += 1;
    host.isSyncingCloud = false;
    host.isResolvingIntent = false;
    host.aiProactiveSuggestions = null;
    host.aiProactiveSignature = null;
    host.isRefreshingProactive = false;
    host.proactiveRetryAfterMs = null;
    host.isGrokBallStageExpanded = false;
    host.grokBallCelebrationUntil = 0;
    host.applyPanelHeight();
    host.haConnectionError = null;
    host.lastUndoAction = null;
    host.pendingCloudConsent = null;
    host.pendingSuggestions = [];
  }
