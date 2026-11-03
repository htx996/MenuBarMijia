import type { MenuMijiaWindowsApp } from "./app.js";
import { t } from "../core/i18n.js";
import { HomeAssistantClient, homeAssistantCommand } from "../core/homeAssistant.js";
import { MiCloudClient, MiotCommandMapper, propKeyString } from "../core/miCloudClient.js";
import { readMiotPower, type DeviceCommand } from "../core/models.js";

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


export async function applyCommand(host: MenuMijiaWindowsApp, command: DeviceCommand, readBackPower = false): Promise<boolean> {
    const sourceRevision = host.sourceRevision;
    try {
      if (host.settings.connectionMode === "homeAssistant") command = homeAssistantCommand(command, host.devices);
      const readPower = await dispatchCloudCommand(host, command, readBackPower);
      if (typeof readPower === "boolean") command = withReadPower(command, readPower);
    } catch (error) {
      if (sourceRevision !== host.sourceRevision) return false;
      host.replyBanner = {
        text: error instanceof Error ? error.message : String(error),
        source: t("控制失败"),
        isError: true,
      };
      host.render();
      return false;
    }
    if (sourceRevision !== host.sourceRevision) return false;
    host.localControlRevision += 1;
    for (const dev of host.devices) {
      const k = dev.kind;
      switch (command.kind) {
        case "setLightPower":
          if (k.kind === "light" && k.entityId === command.entityId) {
            k.isOn = command.isOn;
          }
          break;
        case "setLightBrightness":
          if (k.kind === "light" && k.entityId === command.entityId) {
            k.isOn = command.percent > 0;
            k.brightnessPercent = command.percent;
          }
          break;
        case "setLightColorTemp":
          if (k.kind === "light" && k.entityId === command.entityId) {
            k.isOn = true;
            k.colorTempKelvin = command.kelvin;
            k.currentEffect = null;
          }
          break;
        case "setLightEffect":
          if (k.kind === "light" && k.entityId === command.entityId) {
            k.isOn = true;
            k.currentEffect = command.effect;
          }
          break;
        case "setClimatePower":
          if (k.kind === "climate" && k.entityId === command.entityId) {
            k.isOn = command.isOn;
            k.hvacMode = command.isOn ? command.resumeMode : "off";
          }
          break;
        case "setClimateMode":
          if (k.kind === "climate" && k.entityId === command.entityId) {
            k.isOn = command.hvacMode !== "off";
            k.hvacMode = command.hvacMode;
          }
          break;
        case "setClimateTemperature":
          if (k.kind === "climate" && k.entityId === command.entityId) {
            if (host.settings.connectionMode !== "homeAssistant" || k.hvacMode !== "off") {
              k.isOn = true;
            }
            k.targetTemperature = command.temperature;
          }
          break;
        case "setClimateFanMode":
          if (k.kind === "climate" && k.entityId === command.entityId) {
            k.fanMode = command.fanMode;
          }
          break;
        case "setFanPower":
          if (k.kind === "fan" && k.entityId === command.entityId) {
            k.isOn = command.isOn;
          }
          break;
        case "setFanPercentage":
          if (k.kind === "fan" && k.entityId === command.entityId) {
            k.isOn = command.percent > 0;
            k.percentage = command.percent;
            const fav = k.availablePresetModes.find((m) => m.toLowerCase() === "favorite");
            if (fav) k.presetMode = fav;
          }
          break;
        case "setFanPresetMode":
          if (k.kind === "fan" && k.entityId === command.entityId) {
            k.isOn = true;
            k.presetMode = command.presetMode;
          }
          break;
        case "setFanOscillating":
          if (k.kind === "fan" && k.entityId === command.entityId) {
            k.isOn = true;
            k.isOscillating = command.oscillating;
          }
          break;
        case "setSwitch":
          if (k.kind === "plug" && k.switchEntityId === command.entityId && !command.entityId.startsWith("button.")) {
            k.isOn = command.isOn;
          } else if (k.kind === "camera") {
            if (k.entityId === command.entityId) {
              k.isOn = command.isOn;
              if (host.cameraLive.activeLiveCameraId === dev.id && !host.cameraLive.liveCameraHidden) {
                if (command.isOn) {
                  host.cameraLive.reconnectCameraLiveView();
                } else {
                  host.cameraLive.stopLiveTransport();
                  host.cameraLive.liveCameraLoading = false;
                }
              }
            } else if (k.motionDetectionEntityId === command.entityId) {
              k.isMotionDetectionOn = command.isOn;
            }
          }
          break;
        case "setSelectOption":
          if (k.kind === "camera" && k.entityId === command.entityId) {
            k.nightShot = command.option;
          } else if (k.kind === "fridge" && k.modeEntityId === command.entityId) {
            k.currentMode = command.option;
          }
          break;
        case "setNumberValue":
          if (k.kind === "fridge") {
            if (k.fridgeTargetEntityId === command.entityId) {
              k.fridgeTargetTemp = command.value;
            } else if (k.freezerTargetEntityId === command.entityId) {
              k.freezerTargetTemp = command.value;
            }
          }
          break;
        case "vacuumAction":
          if (k.kind === "vacuum" && k.entityId === command.entityId) {
            k.status =
              command.action === "start"
                ? "cleaning"
                : command.action === "pause"
                  ? "paused"
                  : "returning";
          }
          break;
        case "activateScene":
          break;
      }
    }

    return true;
  }

export async function dispatchCloudCommand(host: MenuMijiaWindowsApp, command: DeviceCommand, readBackPower = false): Promise<boolean | null> {
    const sourceRevision = host.sourceRevision;
    if (host.settings.connectionMode === "demo") return null;
    if (host.settings.connectionMode === "homeAssistant") {
      const client = new HomeAssistantClient(host.settings.haBaseURL, host.settings.haToken);
      await host.endpointSubmission;
      if (sourceRevision !== host.sourceRevision) throw new Error("Connection source changed");
      await client.execute(command);
      return null;
    }
    if (!host.settings.miSession) throw new Error(t("请先扫码登录米家"));
    const session = host.settings.miSession;
    const dev = host.devices.find((d) => {
      const k = d.kind;
      if (k.kind === "plug") return k.switchEntityId === command.entityId || k.childLockEntityId === command.entityId;
      if (k.kind === "camera") return k.entityId === command.entityId || k.motionDetectionEntityId === command.entityId;
      if (k.kind === "fridge") {
        return (
          k.modeEntityId === command.entityId ||
          k.fridgeTargetEntityId === command.entityId ||
          k.freezerTargetEntityId === command.entityId
        );
      }
      if (k.kind === "sensor") return false;
      return k.entityId === command.entityId;
    });
    if (!dev) throw new Error(t("无法找到指令对应的设备"));

    const spec = await host.specResolver.resolve({
      did: dev.id,
      name: dev.name,
      model: dev.model,
      isOnline: dev.isOnline,
      specType: null,
    });
    const mapped = MiotCommandMapper.map(command, spec);
    if (sourceRevision !== host.sourceRevision) throw new Error("Connection source changed");
    const client = new MiCloudClient(session, host.transport);
    if (mapped.kind === "setProps") {
      await client.setProps(mapped.writes);
      if (readBackPower) {
        const power = mapped.writes.find((write) => typeof write.value === "boolean");
        if (power) {
          let read: Map<string, unknown>;
          try {
            read = await client.getProps([power]);
          } catch (error) {
            if (sourceRevision === host.sourceRevision) markCloudValuesStale(host);
            throw error;
          }
          const value = read.get(propKeyString(power));
          const isOn = readMiotPower(value);
          if (isOn === null) {
            // The write may have landed; the old row is no longer a trusted reading.
            if (sourceRevision === host.sourceRevision) markCloudValuesStale(host);
            throw new Error(t("未能读回设备状态"));
          }
          return isOn;
        }
      }
    } else {
      await client.action(mapped.call);
    }
    return null;
  }

export function markCloudValuesStale(host: MenuMijiaWindowsApp): void {
    if (host.settings.connectionMode === "xiaomiCloud" && host.devices.length > 0) {
      host.cloudValuesStale = true;
    }
  }

export function markCloudValuesFresh(host: MenuMijiaWindowsApp): void {
    if (host.settings.connectionMode === "xiaomiCloud") host.cloudValuesStale = false;
  }
