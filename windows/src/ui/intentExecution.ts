import type { MenuMijiaWindowsApp } from "./app.js";
import { t } from "../core/i18n.js";
import {
  IntentValidator,
  UserHabitMemory,
  type HabitLastAction,
  type HabitRecordingReceipt,
  type HabitSequenceEntry,
} from "../core/assistant.js";
import {
  isDeviceActiveOn,
  type DeviceCommand,
  type DeviceIntent,
  type SmartDevice,
} from "../core/models.js";
import type { UndoStep } from "./appTypes.js";

export function buildInverseCommand(dev: SmartDevice, command: DeviceCommand): DeviceCommand[] {
    const k = dev.kind;
    switch (command.kind) {
      case "setLightPower":
        return k.kind === "light" ? [{ kind: "setLightPower", entityId: k.entityId, isOn: k.isOn }] : [];
      case "setLightBrightness":
        return k.kind === "light" && k.brightnessPercent !== null ? [
          { kind: "setLightBrightness", entityId: k.entityId, percent: k.brightnessPercent },
          { kind: "setLightPower", entityId: k.entityId, isOn: k.isOn },
        ] : [];
      case "setLightColorTemp":
        return k.kind === "light" && k.colorTempKelvin !== null ? [
          { kind: "setLightColorTemp", entityId: k.entityId, kelvin: k.colorTempKelvin },
          ...(k.currentEffect !== null ? [{ kind: "setLightEffect" as const, entityId: k.entityId, effect: k.currentEffect }] : []),
          { kind: "setLightPower", entityId: k.entityId, isOn: k.isOn },
        ] : [];
      case "setLightEffect":
        if (k.kind !== "light") return [];
        if (k.currentEffect !== null) return [
          { kind: "setLightEffect", entityId: k.entityId, effect: k.currentEffect },
          { kind: "setLightPower", entityId: k.entityId, isOn: k.isOn },
        ];
        return k.colorTempKelvin !== null ? [
          { kind: "setLightColorTemp", entityId: k.entityId, kelvin: k.colorTempKelvin },
          { kind: "setLightPower", entityId: k.entityId, isOn: k.isOn },
        ] : [];
      case "setClimatePower":
      case "setClimateMode":
        return k.kind === "climate" ? [{ kind: "setClimateMode", entityId: k.entityId, hvacMode: k.isOn ? k.hvacMode : "off" }] : [];
      case "setClimateTemperature":
        return k.kind === "climate" ? [
          { kind: "setClimateTemperature", entityId: k.entityId, temperature: k.targetTemperature },
          { kind: "setClimatePower", entityId: k.entityId, isOn: k.isOn, resumeMode: k.hvacMode },
        ] : [];
      case "setClimateFanMode":
        return k.kind === "climate" && k.fanMode !== null ? [{ kind: "setClimateFanMode", entityId: k.entityId, fanMode: k.fanMode }] : [];
      case "setFanPower":
        return k.kind === "fan" ? [{ kind: "setFanPower", entityId: k.entityId, isOn: k.isOn }] : [];
      case "setFanPercentage":
        return k.kind === "fan" && k.percentage !== null ? [
          { kind: "setFanPercentage", entityId: k.entityId, percent: k.percentage },
          ...(k.presetMode !== null ? [{ kind: "setFanPresetMode" as const, entityId: k.entityId, presetMode: k.presetMode }] : []),
          { kind: "setFanPower", entityId: k.entityId, isOn: k.isOn },
        ] : [];
      case "setFanPresetMode":
        return k.kind === "fan" && k.presetMode !== null ? [
          { kind: "setFanPresetMode", entityId: k.entityId, presetMode: k.presetMode },
          { kind: "setFanPower", entityId: k.entityId, isOn: k.isOn },
        ] : [];
      case "setFanOscillating":
        return k.kind === "fan" && k.isOscillating !== null ? [
          { kind: "setFanOscillating", entityId: k.entityId, oscillating: k.isOscillating },
          { kind: "setFanPower", entityId: k.entityId, isOn: k.isOn },
        ] : [];
      case "setSwitch":
        if (k.kind === "plug") {
          if (command.entityId.startsWith("button.")) return [];
          return [{ kind: "setSwitch", entityId: command.entityId, isOn: command.entityId === k.childLockEntityId ? k.isChildLocked : k.isOn }];
        }
        if (k.kind === "camera") {
          const prevOn = command.entityId === k.motionDetectionEntityId ? Boolean(k.isMotionDetectionOn) : k.isOn;
          return [{ kind: "setSwitch", entityId: command.entityId, isOn: prevOn }];
        }
        return [];
      case "setSelectOption":
        if (k.kind === "camera" && k.nightShot !== null) {
          return [{ kind: "setSelectOption", entityId: command.entityId, option: k.nightShot }];
        }
        if (k.kind === "fridge") {
          return [{ kind: "setSelectOption", entityId: command.entityId, option: k.currentMode }];
        }
        return [];
      case "setNumberValue":
        if (k.kind === "fridge") {
          if (command.entityId === k.fridgeTargetEntityId) {
            return [{ kind: "setNumberValue", entityId: command.entityId, value: k.fridgeTargetTemp }];
          }
          if (command.entityId === k.freezerTargetEntityId) {
            return [{ kind: "setNumberValue", entityId: command.entityId, value: k.freezerTargetTemp }];
          }
        }
        return [];
      case "vacuumAction":
      case "activateScene":
        return [];
      default: {
        const exhaustive: never = command;
        return exhaustive;
      }
    }
  }

export async function executeIntents(host: MenuMijiaWindowsApp, 
    intents: readonly DeviceIntent[],
    replyText: string,
    sourceLabel: string,
    options: { recordHabits?: boolean } = {},
  ): Promise<boolean> {
    const sourceRevision = host.sourceRevision;
    const commands: Array<{ deviceId: string; command: DeviceCommand; intentIndex: number }> = [];
    const candidateIntents: Array<{ intent: DeviceIntent; commandCount: number; succeededCount: number }> = [];
    let failed = 0;
    let failureMessage = "";
    for (const intent of intents) {
      if (intent.operation.kind === "activateScene") {
        const scene = host.scenes.find((s) => s.id === intent.targetId);
        if (scene) {
          const intentIndex = candidateIntents.length;
          candidateIntents.push({ intent, commandCount: 1, succeededCount: 0 });
          commands.push({ deviceId: scene.id, command: { kind: "activateScene", entityId: scene.entityId }, intentIndex });
        }
        continue;
      }
      const dev = host.devices.find((d) => d.id === intent.targetId);
      if (!dev) continue;
      if (!dev.isOnline) {
        failed += 1;
        failureMessage = `${dev.name} (${t("离线")})`;
        continue;
      }
      const intentCommands = IntentValidator.commandsForIntent(intent, dev);
      if (intentCommands.length === 0) {
        failed += 1;
        failureMessage = t("无法找到指令对应的设备");
        continue;
      }
      const intentIndex = candidateIntents.length;
      candidateIntents.push({ intent, commandCount: intentCommands.length, succeededCount: 0 });
      for (const command of intentCommands) {
        commands.push({ deviceId: dev.id, command, intentIndex });
      }
    }

    const steps: UndoStep[] = [];
    let succeeded = 0;
    let canUndo = true;
    for (const { deviceId, command, intentIndex } of commands) {
      if (sourceRevision !== host.sourceRevision) return false;
      // Scenes have no device row and no inverse; they simply run and count as applied (#113).
      if (command.kind === "activateScene") {
        if (await host.applyCommand(command)) {
          succeeded += 1;
          const entry = candidateIntents[intentIndex];
          if (entry) entry.succeededCount += 1;
        } else {
          failed += 1;
          failureMessage = host.replyBanner?.text ?? "设备未响应";
        }
        continue;
      }
      const device = host.devices.find((d) => d.id === deviceId);
      if (!device) {
        failed += 1;
        failureMessage = t("设备列表已更新，请重新执行");
        continue;
      }
      const isMomentaryButton = command.kind === "setSwitch" && command.entityId.startsWith("button.");
      const inverseCommands = isMomentaryButton ? [] : buildInverseCommand(device, command);
      if (await host.applyCommand(command)) {
        succeeded += 1;
        const entry = candidateIntents[intentIndex];
        if (entry) entry.succeededCount += 1;
        if (!isMomentaryButton) {
          canUndo = canUndo && inverseCommands.length > 0;
          if (inverseCommands.length > 0) {
            steps.unshift({ deviceId, commands: inverseCommands });
          }
        }
      } else {
        failed += 1;
        failureMessage = host.replyBanner?.text ?? "设备未响应";
      }
    }
    if (sourceRevision !== host.sourceRevision) return false;
    if (succeeded > 0) {
      if (failed === 0) host.grokBallCelebrationUntil = Date.now() + 2400;
      const succeededIntents = candidateIntents
        .filter((entry) => entry.succeededCount === entry.commandCount && entry.commandCount > 0)
        .map((entry) => entry.intent);
      // Only explicit user asks train habits, and only for intents that actually succeeded (#34/#113/#116).
      const habitReceipt = options.recordHabits && succeededIntents.length > 0 ? recordHabits(host, succeededIntents) : null;
      // Scene activations have no inverse: an undo action must exist only when at least one
      // device step is restorable, otherwise Undo would report success without doing anything
      // (Codex #116 re-review).
      host.lastUndoAction = canUndo && steps.length > 0 ? {
        summary: replyText,
        steps,
        expiresAtMs: Date.now() + 10 * 60 * 1000,
        habitReceipt: habitReceipt ?? undefined,
      } : null;
    }
    if (succeeded === 0 && failed === 0) {
      host.replyBanner = { text: t("无法找到指令对应的设备"), source: t("控制失败"), isError: true };
      host.render();
      return false;
    }
    host.replyBanner = failed > 0
      ? { text: t("已执行 {ok} 项，{failed} 项失败。{message}", { ok: succeeded, failed: failed, message: failureMessage }), source: t("控制失败"), isError: true }
      : { text: replyText, source: sourceLabel };
    host.render();
    return failed === 0;
  }

export async function executeSingleCommand(host: MenuMijiaWindowsApp, 
    device: SmartDevice,
    command: DeviceCommand,
    summary: string,
    intent?: DeviceIntent,
    readBackPower = false,
  ): Promise<void> {
    const sourceRevision = host.sourceRevision;
    const inverseCommands = buildInverseCommand(device, command);
    if (!(await host.applyCommand(command, readBackPower))) return;
    if (sourceRevision !== host.sourceRevision) return;
    // Momentary buttons (Wake-on-LAN) complete without reporting an on/off state to compare.
    const isMomentaryButton = command.kind === "setSwitch" && command.entityId.startsWith("button.");
    if (readBackPower && !isMomentaryButton && !readBackMatches(host, device.id, intent)) {
      host.replyBanner = { text: t("未能读回设备状态"), source: t("控制失败"), isError: true };
      host.render();
      return;
    }
    host.grokBallCelebrationUntil = Date.now() + 2400;
    const habitReceipt = intent ? recordHabits(host, [intent]) : null;
    host.lastUndoAction = inverseCommands.length > 0 ? {
      summary,
      steps: [{ deviceId: device.id, commands: inverseCommands }],
      expiresAtMs: Date.now() + 10 * 60 * 1000,
      habitReceipt: habitReceipt ?? undefined,
    } : null;
    host.replyBanner = { text: summary, source: t("实时控制") };
    host.render();
  }

export function readBackMatches(host: MenuMijiaWindowsApp, deviceId: string, intent?: DeviceIntent): boolean {
    if (!intent || intent.operation.kind !== "power") return true;
    const current = host.devices.find((item) => item.id === deviceId);
    return current !== undefined && isDeviceActiveOn(current) === intent.operation.isOn;
  }

  /** Records manual card actions into the habit memory for the current time bucket (#113). */
export function recordHabits(host: MenuMijiaWindowsApp, intents: readonly DeviceIntent[]): HabitRecordingReceipt | null {
    if (!host.settings.habitLearningEnabled || intents.length === 0) return null;
    const memory = new UserHabitMemory(host.settings.habitEntries, host.habitSequences(), host.lastHabitAction());
    const receipt = memory.record(intents, host.devices, host.scenes, new Date());
    if (receipt) saveHabitMemory(host, memory);
    return receipt;
  }

  /** Sequence entries and lastAction persist alongside the entries (ADR-0009). */
export function habitSequences(): HabitSequenceEntry[] {
    const raw = localStorage.getItem("menumijia.windows.habit.sequences.v1");
    if (!raw) return [];
    try {
      const parsed = JSON.parse(raw) as { sequences?: HabitSequenceEntry[]; lastAction?: HabitLastAction | null };
      return Array.isArray(parsed.sequences) ? parsed.sequences : [];
    } catch {
      return [];
    }
  }

export function lastHabitAction(): HabitLastAction | null {
    const raw = localStorage.getItem("menumijia.windows.habit.sequences.v1");
    if (!raw) return null;
    try {
      const parsed = JSON.parse(raw) as { lastAction?: HabitLastAction | null };
      return parsed.lastAction ?? null;
    } catch {
      return null;
    }
  }

export function saveHabitMemory(host: MenuMijiaWindowsApp, memory: UserHabitMemory): void {
    host.settings.habitEntries = [...memory.entries];
    host.saveSettings();
    try {
      localStorage.setItem("menumijia.windows.habit.sequences.v1", JSON.stringify({
        sequences: memory.sequences,
        lastAction: memory.lastAction,
      }));
    } catch {
      // Quota errors only cost the sequence context, never the entries.
    }
  }

export function unrecordHabits(host: MenuMijiaWindowsApp, receipt: HabitRecordingReceipt): void {
    const memory = new UserHabitMemory(host.settings.habitEntries, host.habitSequences(), host.lastHabitAction());
    memory.unrecord(receipt);
    saveHabitMemory(host, memory);
  }
