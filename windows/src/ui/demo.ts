import { t } from "../core/i18n.js";
import type { HomeScene, SmartDevice } from "../core/models.js";
import { SF_ICONS } from "./appConstants.js";

export function demoDevices(): SmartDevice[] {
  return [
  {
    id: "light.living_ceiling",
    name: t(t("客厅吸顶灯")),
    roomId: "room_living",
    roomName: t(t("客厅")),
    model: "yeelink.light.ceiling22",
    isOnline: true,
    kind: {
      kind: "light",
      entityId: "miot:light.living_ceiling:2",
      isOn: true,
      brightnessPercent: 78,
      colorTempKelvin: 4100,
      minKelvin: 2700,
      maxKelvin: 6500,
      currentEffect: "Day",
      availableEffects: ["Day", "Night"],
    },
  },
  {
    id: "climate.living_ac",
    name: t(t("客厅立式空调")),
    roomId: "room_living",
    roomName: t(t("客厅")),
    model: "xiaomi.aircondition.mc5",
    isOnline: true,
    kind: {
      kind: "climate",
      entityId: "miot:climate.living_ac:2",
      isOn: true,
      hvacMode: "cool",
      availableModes: ["cool", "heat", "dry", "fan_only", "auto", "off"],
      targetTemperature: 25,
      currentTemperature: 26,
      minTemp: 16,
      maxTemp: 30,
      step: 0.5,
      fanMode: "auto",
      availableFanModes: ["auto", "low", "medium", "high"],
    },
  },
  {
    id: "light.study_desk",
    name: t(t("书房台灯")),
    roomId: "room_study",
    roomName: t(t("书房")),
    model: "yeelink.light.lamp15",
    isOnline: true,
    kind: {
      kind: "light",
      entityId: "miot:light.study_desk:2",
      isOn: true,
      brightnessPercent: 64,
      colorTempKelvin: 4600,
      minKelvin: 2700,
      maxKelvin: 6500,
      currentEffect: null,
      availableEffects: ["Day", "Night"],
    },
  },
  {
    id: "fan.bedroom_standing",
    name: t(t("主卧直流风扇")),
    roomId: "room_bedroom",
    roomName: t(t("主卧")),
    model: "zhimi.fan.za5",
    isOnline: true,
    kind: {
      kind: "fan",
      entityId: "miot:fan.bedroom_standing:2",
      isOn: false,
      percentage: 50,
      presetMode: "Level 2",
      availablePresetModes: ["Level 1", "Level 2", "Level 3", "Level 4"],
      isOscillating: false,
    },
  },
  {
    id: "plug.entry_socket",
    name: t(t("玄关智能插座")),
    roomId: "room_entry",
    roomName: t(t("玄关")),
    model: "cuco.plug.cp1",
    isOnline: true,
    kind: {
      kind: "plug",
      switchEntityId: "miot:plug.entry_socket:2",
      isOn: true,
      powerWatts: 18.4,
      childLockEntityId: null,
      isChildLocked: false,
    },
  },
  {
    id: "vacuum.roborock",
    name: t(t("全屋扫拖机器人")),
    roomId: "room_living",
    roomName: t(t("客厅")),
    model: "roborock.vacuum.a15",
    isOnline: true,
    kind: {
      kind: "vacuum",
      entityId: "miot:vacuum.roborock:2",
      status: "docked",
      battery: 100,
      modeEntityId: null,
      currentMode: null,
      availableModes: [],
    },
  },
  {
    id: "sensor.living_env",
    name: t(t("客厅温湿度计")),
    roomId: "room_living",
    roomName: t(t("客厅")),
    model: "miaomiaoce.sensor_ht.t2",
    isOnline: true,
    kind: {
      kind: "sensor",
      temperature: 25.5,
      humidity: 52,
      battery: 94,
    },
  },
  {
    id: "camera.living_cam",
    name: t(t("客厅摄像机")),
    roomId: "room_living",
    roomName: t(t("客厅")),
    model: "chuangmi.camera.81ac1",
    isOnline: true,
    kind: {
      kind: "camera",
      entityId: "miot:camera.living_cam:2",
      isOn: true,
      nightShot: "Auto",
      availableNightShots: ["Off", "On", "Auto"],
      motionDetectionEntityId: "miot:camera.living_cam:5",
      isMotionDetectionOn: true,
      streamEntityId: "miot:camera.living_cam:20",
    },
  },
  ];
}

export function demoScenes(): HomeScene[] {
  return [
    { id: "scene.home", name: t(t("回家模式")), entityId: "scene.home" },
    { id: "scene.focus", name: t(t("专注模式")), entityId: "scene.focus" },
    { id: "scene.sleep", name: t(t("睡眠模式")), entityId: "scene.sleep" },
    { id: "scene.leave", name: t(t("离家模式")), entityId: "scene.leave" },
  ];
}

export function quickActions(): ReadonlyArray<{
  readonly id: string;
  readonly title: string;
  readonly icon: string;
  readonly tint: string;
  readonly command: string;
}> {
  return [
    { id: "lights_on", title: t(t("全开主灯")), icon: SF_ICONS.sunMaxFill, tint: "amber", command: t(t("打开所有灯")) },
    { id: "lights_off", title: t(t("睡眠关灯")), icon: SF_ICONS.moonStarsFill, tint: "indigo", command: t(t("关闭所有灯")) },
    { id: "cool_25", title: t(t("25°制冷")), icon: SF_ICONS.snowflake, tint: "cyan", command: t(t("空调调到25度")) },
    { id: "focus", title: t(t("调亮灯光")), icon: SF_ICONS.lightbulbFill, tint: "amber", command: t(t("再亮一点")) },
  ];
}
