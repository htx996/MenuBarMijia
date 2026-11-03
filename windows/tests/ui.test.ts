import { EventEmitter, once } from "node:events";
import { readFileSync } from "node:fs";
import { HomeAssistantSynthesizer, homeAssistantIdentity } from "../src/core/homeAssistant.js";
import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setImmediate } from "node:timers/promises";
import { Window } from "happy-dom";

import { installWindow } from "./dom.js";
import { MenuMijiaWindowsApp, waitForCameraFrameGap } from "../src/ui/app.js";
import { SKINS } from "../src/ui/panelPrefs.js";
import { cloudFixture } from "./cloudFixture.js";
import { MiCloudClient, MiotSynthesizer, inferFallbackSpec } from "../src/core/miCloudClient.js";
import { MiCloudCrypto } from "../src/core/miCloudCrypto.js";
import type { SmartDevice } from "../src/core/models.js";

let dom: Window;

function element(selector: string): HTMLElement {
  const found = document.querySelector<HTMLElement>(selector);
  assert.ok(found, `Missing control ${selector}`);
  return found;
}

async function click(selector: string): Promise<void> {
  element(selector).click();
  await setImmediate();
}

function tile(id: string): string {
  return element(`[data-body-device="${id}"]`).textContent ?? "";
}

function textOf(selector: string): string {
  return element(selector).textContent ?? "";
}

function startDemo(): void {
  localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
    connectionMode: "demo",
    hasCompletedOnboarding: true,
  }));
  new MenuMijiaWindowsApp(element("#app"));
}

async function setRange(selector: string, value: string): Promise<void> {
  const slider = document.querySelector<HTMLInputElement>(selector);
  assert.ok(slider);
  slider.value = value;
  slider.dispatchEvent(new Event("change", { bubbles: true }));
  await setImmediate();
}

async function command(text: string): Promise<void> {
  const input = document.querySelector<HTMLInputElement>("#command-input");
  assert.ok(input);
  input.value = text;
  await click("#btn-send");
}

async function waitFor(predicate: () => boolean, timeoutMs = 2_000): Promise<void> {
  const deadline = performance.now() + timeoutMs;
  while (!predicate()) {
    if (performance.now() >= deadline) assert.fail("Timed out waiting for UI state");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

async function withTimeout<T>(
  promise: Promise<T>,
  message: string,
  timeoutMs = 2_000,
): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(message)), timeoutMs);
  });
  try {
    return await Promise.race([promise, timeout]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

beforeEach(() => {
  dom = new Window({ url: "http://localhost/" });
  installWindow(dom);
  // The suite asserts Simplified Chinese chrome; pin the OS language so `system` resolves to it.
  Object.defineProperty(dom.navigator, "languages", { value: ["zh-CN", "zh"], configurable: true });
  Object.defineProperty(dom.navigator, "language", { value: "zh-CN", configurable: true });
  document.body.innerHTML = '<div id="app"></div>';
  // Most UI tests do not exercise the daily GitHub check; mark it done today so the
  // startup request cannot change their request lists (#39). Update tests clear this.
  localStorage.setItem("menumijia.windows.update.v1", JSON.stringify({ lastCheckedAtMs: Date.now(), release: null }));
});

afterEach(async () => {
  await dom.happyDOM.abort();
  dom.close();
});

describe("Service endpoint submission", () => {
  it("sends the saved assistant and Home Assistant URLs and not a free origin list", async () => {
    const calls: Array<{ command: string; args: Record<string, unknown> }> = [];
    const invoke = async (command: string, args: Record<string, unknown> = {}) => {
      calls.push({ command, args });
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      assistantBaseURL: "HTTPS://API.DeepSeek.com:8443/v1",
      haBaseURL: "http://[::1]:8123/api",
    }));

    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();

    assert.deepEqual(calls.filter((call) => call.command === "set_service_endpoints").map((call) => call.args), [
      { assistantUrl: "HTTPS://API.DeepSeek.com:8443/v1", haUrl: "http://[::1]:8123/api" },
    ]);
    assert.equal(calls.some((call) => call.command === "set_allowed_origins"), false);
  });

  it("does not re-prompt a declined endpoint on unrelated background saves, but retries when settings are explicitly saved", async () => {
    let endpointAttempts = 0;
    const invoke = async (command: string) => {
      if (command === "set_service_endpoints") {
        endpointAttempts += 1;
        throw new Error("未授权访问来源：https://api.deepseek.com:8443");
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      assistantBaseURL: "https://api.deepseek.com:8443/v1",
      haBaseURL: "",
    }));

    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    assert.equal(endpointAttempts, 1);

    // Unrelated settings saves (e.g. toggling interface language or background cloud refresh) must not re-prompt.
    await click("#btn-settings");
    await click('[data-interface-language="zh-Hans"]');
    await setImmediate();
    assert.equal(endpointAttempts, 1);

    // Clicking "保存设置" explicitly retries endpoint authorization.
    await click("#btn-save-settings");
    await setImmediate();
    assert.equal(endpointAttempts, 2);
  });
});

describe("Windows device control and undo", () => {
  it("keeps focus in the command input after a local command completes", async () => {
    startDemo();
    const input = element("#command-input") as HTMLInputElement;
    input.value = "客厅吸顶灯月光模式";
    input.focus();

    await click("#btn-send");
    await waitFor(() => tile("light.living_ceiling").includes("月光"));

    assert.ok(
      document.activeElement === element("#command-input"),
      "command input lost keyboard focus after a local command",
    );
  });

  it("clears a submitted command after undo instead of restoring it into the input", async () => {
    startDemo();
    await click('[data-toggle-device="light.living_ceiling"]');
    const input = element("#command-input") as HTMLInputElement;
    input.value = "撤销";
    input.focus();

    await click("#btn-send");

    assert.match(tile("light.living_ceiling"), /已开启/);
    assert.equal(input.value, "");
    assert.equal(document.querySelector<HTMLInputElement>("#command-input")?.value, "");
    assert.ok(
      document.activeElement === document.querySelector("#command-input"),
      "command input lost keyboard focus after submission",
    );
  });

  it("restores an originally off light without turning it on through brightness", async () => {
    startDemo();
    await click('[data-toggle-device="light.living_ceiling"]');
    assert.match(tile("light.living_ceiling"), /已关闭/);
    await click('[data-toggle-device="light.living_ceiling"]');
    assert.match(tile("light.living_ceiling"), /已开启/);
    await click("#btn-undo");
    assert.match(tile("light.living_ceiling"), /已关闭/);
    assert.match(document.body.textContent ?? "", /已撤销/);
  });

  it("restores the changed light color temperature without changing brightness", async () => {
    startDemo();
    await click('[data-expand-device="light.living_ceiling"]');
    await setRange('[data-colortemp="light.living_ceiling"]', "5500");
    assert.match(tile("light.living_ceiling"), /5500K/);
    await click("#btn-undo");
    assert.match(tile("light.living_ceiling"), /78% · 4100K/);
  });

  it("restores a light effect through the natural command flow", async () => {
    startDemo();
    await command("客厅吸顶灯月光模式");
    assert.match(tile("light.living_ceiling"), /月光/);
    await click("#btn-undo");
    assert.match(tile("light.living_ceiling"), /日光/);
  });

  it("restores ordinary color temperature after a light-effect action", async () => {
    startDemo();
    await click('[data-expand-device="light.living_ceiling"]');
    await setRange('[data-colortemp="light.living_ceiling"]', "5500");
    await command("客厅吸顶灯月光模式");
    assert.match(tile("light.living_ceiling"), /月光/);
    await click("#btn-undo");
    assert.match(tile("light.living_ceiling"), /5500K/);
    assert.doesNotMatch(tile("light.living_ceiling"), /月光/);
  });

  it("switches moonlight from the light drawer and restores its original mode on undo", async () => {
    startDemo();
    await click('[data-expand-device="light.living_ceiling"]');
    const daylight = '[data-lighteffect="light.living_ceiling"][data-effect="Day"]';
    const moonlight = '[data-lighteffect="light.living_ceiling"][data-effect="Night"]';
    assert.equal(element(daylight).getAttribute("aria-pressed"), "true");
    await click(moonlight);
    assert.match(tile("light.living_ceiling"), /月光/);
    assert.match(tile("light.living_ceiling"), /78%/);
    assert.match(tile("light.living_ceiling"), /4100K/);
    assert.equal(element(moonlight).getAttribute("aria-pressed"), "true");
    await click("#btn-undo");
    assert.match(tile("light.living_ceiling"), /日光/);
    assert.equal(element(daylight).getAttribute("aria-pressed"), "true");
  });

  it("restores a fan preset and its initially off power state", async () => {
    startDemo();
    await click('[data-expand-device="fan.bedroom_standing"]');
    await click('[data-fanpreset="fan.bedroom_standing:Level 4"]');
    assert.match(tile("fan.bedroom_standing"), /Level 4/);
    await click("#btn-undo");
    assert.match(tile("fan.bedroom_standing"), /已关闭/);
    assert.equal(element('[data-fanpreset="fan.bedroom_standing:Level 2"]').classList.contains("is-active"), true);
  });

  it("restores fan oscillation and its initially off power state", async () => {
    startDemo();
    await click('[data-expand-device="fan.bedroom_standing"]');
    await click('[data-fanosc="fan.bedroom_standing"]');
    assert.match(tile("fan.bedroom_standing"), /摇头/);
    await click("#btn-undo");
    assert.match(tile("fan.bedroom_standing"), /已关闭/);
    assert.match(element('[data-fanosc="fan.bedroom_standing"]').textContent ?? "", /摇头 关/);
  });

  it("undoes only acknowledged attributes when another command on the same device fails", async () => {
    const cloud = cloudFixture([
      { targetId: "fixture-light", operation: { kind: "brightness", percent: 80 } },
      { targetId: "fixture-light", operation: { kind: "colorTemperature", kelvin: 5500 } },
    ]);
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    assert.match(tile("fixture-light"), /50% · 4100K/);
    await command("部分失败");
    assert.match(document.body.textContent ?? "", /1 项失败/);
    assert.match(tile("fixture-light"), /50% · 5500K/);
    cloud.values.set(2, 90);
    await click("#btn-refresh");
    assert.match(tile("fixture-light"), /90% · 5500K/);
    cloud.allowBrightness();
    await click("#btn-undo");
    assert.match(tile("fixture-light"), /90% · 4100K/);
    assert.equal(cloud.values.get(2), 90);
    assert.equal(cloud.values.get(3), 4100);
  });

  it("reverses multiple acknowledged changes to the same attribute in execution order", async () => {
    const cloud = cloudFixture([
      { targetId: "fixture-light", operation: { kind: "brightness", percent: 80 } },
      { targetId: "fixture-light", operation: { kind: "brightness", percent: 60 } },
    ]);
    cloud.allowBrightness();
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    await command("部分失败");
    assert.match(tile("fixture-light"), /60%/);
    await click("#btn-undo");
    assert.match(tile("fixture-light"), /50%/);
    assert.equal(cloud.values.get(2), 50);
  });

  it("preserves final power correction when a failed undo is retried", async () => {
    const cloud = cloudFixture([]);
    cloud.values.set(1, false);
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    assert.match(tile("fixture-light"), /已关闭/);
    await click('[data-expand-device="fixture-light"]');
    await setRange('[data-colortemp="fixture-light"]', "5500");
    cloud.reject(3, 4100);
    await click("#btn-undo");
    assert.match(document.body.textContent ?? "", /撤销未完成/);
    assert.match(tile("fixture-light"), /已关闭/);
    cloud.allow(3);
    await click("#btn-undo");
    assert.match(tile("fixture-light"), /已关闭/);
    assert.equal(cloud.values.get(1), false);
    assert.equal(cloud.values.get(3), 4100);
    assert.match(document.body.textContent ?? "", /已撤销/);
  });
});

describe("Silent Xiaomi cloud refresh (#81)", { concurrency: false }, () => {
  async function readyCloudApp(configure?: (cloud: ReturnType<typeof cloudFixture>) => void): Promise<{
    cloud: ReturnType<typeof cloudFixture>;
    triggerRefresh(): void;
    runTimerTick(): void;
  }> {
    const cloud = cloudFixture([]);
    configure?.(cloud);
    let timerTick: (() => void) | null = null;
    const timerWindow = window as unknown as {
      setInterval: (handler: () => void, timeout?: number) => number;
    };
    const originalSetInterval = timerWindow.setInterval;
    timerWindow.setInterval = (handler) => {
      timerTick = handler;
      return 1;
    };
    new MenuMijiaWindowsApp(element("#app"));
    timerWindow.setInterval = originalSetInterval;
    assert.ok(timerTick, "app did not install its timer loop");
    for (let i = 0; i < 3; i++) await setImmediate();
    await waitFor(
      () => !document.querySelector("#btn-refresh")?.classList.contains("is-spinning"),
    );
    assert.match(tile("fixture-light"), /50%/);
    const runTimerTick = () => (timerTick as () => void)();
    let refreshOffset = 0;
    return {
      cloud,
      runTimerTick,
      triggerRefresh: () => {
        refreshOffset += 7_000;
        const realNow = Date.now;
        Date.now = () => realNow() + refreshOffset;
        try {
          runTimerTick();
        } finally {
          Date.now = realNow;
        }
      },
    };
  }

  it("keeps device and room positions when cloud polling permutes the same records", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp((fixture) => {
      const light = fixture.deviceRecords[0];
      assert.ok(light);
      fixture.deviceRecords.push({ ...light, did: "second-light", name: "第二盏灯" });
      fixture.deviceRecords.push(
        fixture.sensorRecord("sensor-bedroom", "主卧温湿度计"),
        fixture.sensorRecord("sensor-balcony", "阳台温湿度计"),
      );
      fixture.roomRecords.push(
        { id: "living", name: "客厅", dids: ["fixture-light"] },
        { id: "study", name: "书房", dids: ["second-light"] },
      );
    });
    const ids = () => Array.from(document.querySelectorAll<HTMLElement>("[data-tile-id]"), (node) => node.dataset.tileId);
    const rooms = () => Array.from(document.querySelectorAll<HTMLElement>("[data-room]"), (node) => node.dataset.room);
    const initialIds = ids();
    const initialRooms = rooms();
    const envLabels = () => Array.from(document.querySelectorAll(".cc-env-label"), (node) => node.textContent);
    const initialEnvLabels = envLabels();
    assert.deepEqual(initialEnvLabels, ["主卧", "阳台"]);
    const popover = element(".cc-popover");
    for (let i = 0; i < 4; i++) {
      cloud.deviceRecords.reverse();
      cloud.roomRecords.reverse();
      cloud.values.set(2, 51 + i);
      cloud.sensorValues.set(1, 24 + i);
      const held = cloud.holdNextRead();
      triggerRefresh();
      await withTimeout(held.started, "Polling did not request properties");
      held.release();
      await withTimeout(held.finished, "Polling did not finish");
      await setImmediate();
      assert.deepEqual(ids(), initialIds, "cloud response order moved device tiles");
      assert.deepEqual(rooms(), initialRooms, "cloud response order moved room tabs");
      assert.deepEqual(envLabels(), initialEnvLabels, "cloud response order moved environment chips");
      assert.match(tile("fixture-light"), new RegExp(`${51 + i}%`));
      assert.match(textOf(".cc-env-strip"), new RegExp(`${24 + i}\\.0`));
      assert.ok(element(".cc-popover") === popover, "order-only refresh rebuilt the panel");
    }
  });

  it("drops a card that goes offline while 只显示在线设备 is on", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp((fixture) => {
      fixture.deviceRecords.push(fixture.sensorRecord("sensor-bedroom", "主卧温湿度计"));
    });
    assert.ok(document.querySelector('[data-tile-id="sensor-bedroom"]'));
    await click("#btn-toggle-hide-offline");
    assert.ok(document.querySelector('[data-tile-id="sensor-bedroom"]'));
    const sensor = cloud.deviceRecords.find((record) => record.did === "sensor-bedroom");
    assert.ok(sensor);
    sensor.isOnline = false;
    const held = cloud.holdNextRead();
    triggerRefresh();
    await withTimeout(held.started, "Polling did not request properties");
    held.release();
    await withTimeout(held.finished, "Polling did not finish");
    await waitFor(() => document.querySelector('[data-tile-id="sensor-bedroom"]') === null);
    assert.ok(document.querySelector('[data-tile-id="fixture-light"]'));
    assert.equal(element("#btn-toggle-hide-offline").getAttribute("aria-pressed"), "true");
  });

  it("marks values stale when the read-back after a write fails", async () => {
    const { cloud } = await readyCloudApp();
    cloud.failNextGets();
    await click('[data-toggle-device="fixture-light"]');
    await waitFor(() => !!document.querySelector('[data-tile-id="fixture-light"]')?.classList.contains("is-stale"));
    assert.match(textOf(".cc-feedback-text"), /HTTP 500|未能读回设备状态/);
    assert.match(textOf('[data-tile-id="fixture-light"]'), /可能过期/);
  });

  it("adds and removes kind chips when polling changes device availability", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp((fixture) => {
      const sensor = fixture.sensorRecord("sensor-bedroom", "主卧温湿度计");
      sensor.isOnline = false;
      fixture.deviceRecords.push(sensor);
    });
    await click('[data-kind="light"]');
    await click("#btn-toggle-hide-offline");
    assert.ok(document.querySelector('[data-kind="light"]'));
    assert.equal(document.querySelector('[data-kind="sensor"]'), null);

    const sensor = cloud.deviceRecords.find((record) => record.did === "sensor-bedroom");
    assert.ok(sensor);
    sensor.isOnline = true;
    const broughtOnline = cloud.holdNextRead();
    triggerRefresh();
    await withTimeout(broughtOnline.started, "Polling did not request properties");
    broughtOnline.release();
    await withTimeout(broughtOnline.finished, "Polling did not finish");
    await waitFor(() => document.querySelector('[data-kind="sensor"]') !== null);
    assert.ok(document.querySelector('[data-kind="light"]'));

    sensor.isOnline = false;
    const takenOffline = cloud.holdNextRead();
    triggerRefresh();
    await withTimeout(takenOffline.started, "Polling did not request properties");
    takenOffline.release();
    await withTimeout(takenOffline.finished, "Polling did not finish");
    await waitFor(() => document.querySelector('[data-kind="sensor"]') === null);
    assert.ok(document.querySelector('[data-kind="light"]'));
  });

  it("shows a collapsed group again when its only device comes online", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp((fixture) => {
      const sensor = fixture.sensorRecord("sensor-bedroom", "主卧温湿度计");
      sensor.isOnline = false;
      fixture.deviceRecords.push(sensor);
      const stored = localStorage.getItem("menumijia.windows.settings.v2");
      assert.ok(stored);
      localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
        ...JSON.parse(stored),
        hideOfflineDevices: true,
        layout: {
          groups: [{ id: "g-sensors", name: "传感器" }],
          groupMap: { "sensor-bedroom": "g-sensors" },
          collapsed: ["all|g-sensors"],
        },
      }));
    });
    assert.equal(document.querySelector('[data-collapse="g-sensors"]'), null);
    assert.ok(document.querySelector('[data-tile-id="fixture-light"]'));
    const sensor = cloud.deviceRecords.find((record) => record.did === "sensor-bedroom");
    assert.ok(sensor);
    sensor.isOnline = true;
    const held = cloud.holdNextRead();
    triggerRefresh();
    await withTimeout(held.started, "Polling did not request properties");
    held.release();
    await withTimeout(held.finished, "Polling did not finish");
    await waitFor(() => document.querySelector('[data-collapse="g-sensors"]') !== null);
    const header = element('[data-collapse="g-sensors"]');
    assert.match(header.textContent ?? "", /传感器/);
    assert.equal(header.querySelector(".cc-group-count")?.textContent, "1");
    assert.equal(document.querySelector('[data-tile-id="sensor-bedroom"]'), null);
    await click('[data-collapse="g-sensors"]');
    assert.ok(document.querySelector('[data-tile-id="sensor-bedroom"]'));
  });

  it("appends new devices, removes missing devices and retains a partial custom order", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp((fixture) => {
      const light = fixture.deviceRecords[0];
      assert.ok(light);
      fixture.deviceRecords.push(
        { ...light, did: "second-light" }, { ...light, did: "third-light" },
      );
      const stored = localStorage.getItem("menumijia.windows.settings.v2");
      assert.ok(stored);
      localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
        ...JSON.parse(stored), layout: { order: ["third-light"] },
      }));
    });
    const light = cloud.deviceRecords[0];
    assert.ok(light);
    cloud.deviceRecords.splice(0, cloud.deviceRecords.length,
      { ...light, did: "new-light" }, { ...light, did: "third-light" }, light,
    );
    const held = cloud.holdNextRead();
    triggerRefresh();
    await withTimeout(held.started, "Polling did not request properties");
    held.release();
    await withTimeout(held.finished, "Polling did not finish");
    await setImmediate();
    assert.deepEqual(
      Array.from(document.querySelectorAll<HTMLElement>("[data-tile-id]"), (node) => node.dataset.tileId),
      ["third-light", "fixture-light", "new-light"],
    );
    const stored = localStorage.getItem("menumijia.windows.settings.v2");
    assert.ok(stored);
    const cached: unknown = JSON.parse(stored);
    assert.ok(cached && typeof cached === "object" && "cachedXiaomiDevices" in cached && Array.isArray(cached.cachedXiaomiDevices));
    assert.deepEqual(cached.cachedXiaomiDevices.map((device) => device.id), ["fixture-light", "third-light", "new-light"]);
  });

  it("retains the cached device positions on the first refresh after restart", async () => {
    await readyCloudApp((fixture) => {
      const light = fixture.deviceRecords[0];
      assert.ok(light);
      fixture.deviceRecords.push({ ...light, did: "second-light" });
      const records = MiCloudClient.parseDeviceList({ list: [...fixture.deviceRecords].reverse() });
      const cached = MiotSynthesizer.synthesize(records, [], {}, new Map());
      const stored = localStorage.getItem("menumijia.windows.settings.v2");
      assert.ok(stored);
      localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
        ...JSON.parse(stored), cachedXiaomiDevices: cached.devices,
      }));
    });
    assert.deepEqual(
      Array.from(document.querySelectorAll<HTMLElement>("[data-tile-id]"), (node) => node.dataset.tileId),
      ["second-light", "fixture-light"],
    );
  });

  function cachedFridgeDevice() {
    return {
      id: "did_fridge",
      name: "冰箱",
      roomId: "",
      roomName: "",
      model: "midjd6.fridge.v1",
      isOnline: true,
      kind: {
        kind: "fridge",
        modeEntityId: "miot:did_fridge:2",
        currentMode: "Holiday",
        availableModes: ["None", "Smart", "Holiday"],
        fridgeCurrentTemp: null,
        fridgeTargetTemp: 6,
        fridgeTargetEntityId: "miot:did_fridge:3",
        freezerCurrentTemp: null,
        freezerTargetTemp: -20,
        freezerTargetEntityId: "miot:did_fridge:4",
      },
    };
  }

  it("downgrades legacy cached fridge writable controls before the cloud spec re-synthesizes (#148)", () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "xiaomiCloud",
      hasCompletedOnboarding: true,
      cachedXiaomiDevices: [cachedFridgeDevice()],
    }));

    new MenuMijiaWindowsApp(element("#app"));
    element('[data-expand-device="did_fridge"]').click();
    assert.equal(document.querySelectorAll("[data-fridgemode]").length, 0);
    assert.equal(document.querySelectorAll("[data-fridgestep]").length, 0);
  });

  it("keeps verified cached fridge controls when the cache version is current (#148)", () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "xiaomiCloud",
      hasCompletedOnboarding: true,
      cachedDevicesVersion: 1,
      cachedXiaomiDevices: [cachedFridgeDevice()],
    }));

    new MenuMijiaWindowsApp(element("#app"));
    element('[data-expand-device="did_fridge"]').click();
    assert.ok(document.querySelector("[data-fridgemode]"), "mode controls should be preserved");
    assert.equal(document.querySelectorAll("[data-fridgestep]").length, 4);
  });

  it("keeps the current DOM when polling returns the same snapshot", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp();
    const input = element("#command-input") as HTMLInputElement;
    const popover = element(".cc-popover");
    input.value = "未发送的草稿";
    input.focus();
    const heldRead = cloud.holdNextRead();

    triggerRefresh();
    await withTimeout(heldRead.started, "Cloud refresh did not reach the no-op gate");
    heldRead.release();
    await withTimeout(heldRead.finished, "Cloud response did not finish");
    await setImmediate();

    assert.equal(element(".cc-popover"), popover);
    assert.equal(element("#command-input"), input);
    assert.equal(document.activeElement, input);
    assert.equal(input.value, "未发送的草稿");
  });

  it("patches a real state change without disturbing the command draft", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp();
    const input = element("#command-input") as HTMLInputElement;
    const inputNode = input;
    input.value = "未发送的草稿";
    input.focus();
    cloud.values.set(2, 90);

    triggerRefresh();
    await waitFor(() => tile("fixture-light").includes("90%"));
    assert.match(tile("fixture-light"), /90%/);
    assert.ok(element("#command-input") === inputNode, "command input was replaced");
    assert.ok(document.activeElement === inputNode, "command focus moved");
    assert.equal(input.value, "未发送的草稿");
  });

  it("discards a stale cloud snapshot after a newer command has completed", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp();
    const heldRead = cloud.holdNextRead();
    triggerRefresh();
    await withTimeout(heldRead.started, "Cloud refresh did not reach the stale response gate");
    await click('[data-toggle-device="fixture-light"]');
    await waitFor(() => cloud.writes.filter((write) => write.piid === 1).length === 1);
    await waitFor(() => tile("fixture-light").includes("已关闭"));
    assert.match(tile("fixture-light"), /已关闭/);

    heldRead.release();
    await withTimeout(heldRead.finished, "Stale cloud response did not finish");
    await setImmediate();
    assert.match(tile("fixture-light"), /已关闭/);

    await click('[data-toggle-device="fixture-light"]');
    await waitFor(() => cloud.writes.filter((write) => write.piid === 1).length === 2);
    await waitFor(() => tile("fixture-light").includes("已开启"));
    assert.match(tile("fixture-light"), /已开启/);
    assert.deepEqual(
      cloud.writes.filter((write) => write.piid === 1).map((write) => write.value),
      [false, true],
    );
  });

  it("shows waiting until the power write is read back and ignores a second tap", async () => {
    const { cloud } = await readyCloudApp();
    const held = cloud.holdNextWrite();
    void click('[data-toggle-device="fixture-light"]');
    await withTimeout(held.started, "Power write did not start");
    assert.match(tile("fixture-light"), /等待中/);
    assert.doesNotMatch(tile("fixture-light"), /已关闭/);
    await click('[data-toggle-device="fixture-light"]');
    assert.equal(cloud.writes.filter((write) => write.piid === 1).length, 0);
    held.release();
    await withTimeout(held.finished, "Power write did not finish");
    await waitFor(() => tile("fixture-light").includes("已关闭"));
    assert.equal(cloud.writes.filter((write) => write.piid === 1).length, 1);
    assert.equal(cloud.writes.find((write) => write.piid === 1)?.value, false);
  });

  it("keeps the last device values and marks them possibly stale when a property read fails", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp();
    assert.match(tile("fixture-light"), /已开启/);
    cloud.failNextGets(1);
    triggerRefresh();
    await waitFor(() => tile("fixture-light").includes("可能过期"));
    assert.doesNotMatch(tile("fixture-light"), /已开启/);
    assert.doesNotMatch(tile("fixture-light"), /50%/);
    const saved = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as {
      cachedXiaomiDevices?: Array<{ kind: { isOn?: boolean } }>;
    };
    assert.equal(saved.cachedXiaomiDevices?.[0]?.kind.isOn, true);
  });

  it("accepts a numeric 0/1 power read-back", async () => {
    const { cloud } = await readyCloudApp();
    cloud.setNumericPowerReads(true);
    await click('[data-toggle-device="fixture-light"]');
    await waitFor(() => tile("fixture-light").includes("已关闭"));
    assert.match(tile("fixture-light"), /已关闭/);
  });

  it("does not celebrate or learn a power tap whose read-back still shows the old value", async () => {
    const cloud = cloudFixture([]);
    cloud.enableHabitLearning();
    cloud.setEchoPowerReads(true);
    new MenuMijiaWindowsApp(element("#app"));
    await waitFor(() => (document.querySelector('[data-body-device="fixture-light"]')?.textContent ?? "").includes("已开启"));
    await click('[data-toggle-device="fixture-light"]');
    await waitFor(() => (document.body.textContent ?? "").includes("未能读回设备状态"));
    assert.match(tile("fixture-light"), /已开启/);
    assert.equal(localStorage.getItem("menumijia.windows.habit.sequences.v1"), null);
    const saved = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as {
      habitEntries?: unknown[];
    };
    assert.equal(saved.habitEntries?.length ?? 0, 0);
  });

  it("clears a Xiaomi stale mark when the connection mode changes", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp();
    cloud.failNextGets(1);
    triggerRefresh();
    await waitFor(() => tile("fixture-light").includes("可能过期"));
    await click("#btn-settings");
    await click('[data-conn-mode="demo"]');
    await waitFor(() => !(document.body.textContent ?? "").includes("可能过期"));
    assert.doesNotMatch(document.body.textContent ?? "", /可能过期/);
  });

  it("patches dynamic values without replacing the focused device control", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp();
    const toggle = element('[data-toggle-device="fixture-light"]');
    const tileNode = element('[data-tile-id="fixture-light"]');
    toggle.focus();
    const heldRead = cloud.holdNextRead();
    cloud.values.set(2, 90);
    triggerRefresh();
    await withTimeout(heldRead.started, "Cloud refresh did not reach the focused-control gate");
    heldRead.release();
    await withTimeout(heldRead.finished, "Cloud response did not finish");
    await waitFor(() => tile("fixture-light").includes("90%"));

    assert.match(tile("fixture-light"), /90%/);
    assert.ok(element('[data-toggle-device="fixture-light"]') === toggle, "device control was replaced");
    assert.ok(element('[data-tile-id="fixture-light"]') === tileNode, "device tile was replaced");
    assert.ok(document.activeElement === toggle, "keyboard focus moved");
  });

  it("keeps keyboard focus on an id-less device control across a structural refresh", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp();
    element('[data-toggle-device="fixture-light"]').focus();
    cloud.values.set(1, false);

    triggerRefresh();
    await waitFor(() => tile("fixture-light").includes("已关闭"));

    assert.match(tile("fixture-light"), /已关闭/);
    assert.ok(
      document.activeElement === element('[data-toggle-device="fixture-light"]'),
      "device control lost keyboard focus",
    );
  });

  it("does not let an open detail drawer block structural updates forever", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp();
    await click('[data-expand-device="fixture-light"]');
    assert.ok(document.querySelector(".cc-tile-drawer"), "detail drawer did not open");
    cloud.values.set(1, false);

    triggerRefresh();
    await waitFor(() => tile("fixture-light").includes("已关闭"));

    assert.match(tile("fixture-light"), /已关闭/);
    assert.ok(document.querySelector(".cc-tile-drawer"), "detail drawer closed after refresh");
  });

  it("updates and restores focus when a detail slider is focused", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp();
    await click('[data-expand-device="fixture-light"]');
    const slider = element('[data-brightness="fixture-light"]');
    slider.focus();
    cloud.values.set(1, false);
    cloud.values.set(2, 90);

    triggerRefresh();
    await waitFor(() => tile("fixture-light").includes("已关闭"));

    assert.match(tile("fixture-light"), /已关闭/);
    assert.ok(document.querySelector(".cc-tile-drawer"), "detail drawer closed after refresh");
    const restored = element('[data-brightness="fixture-light"]') as HTMLInputElement;
    assert.ok(document.activeElement === restored, "focused detail slider was not restored");
    assert.equal(restored.value, "90");
  });

  it("updates a focused range value when polling patches in place", async () => {
    const { cloud, triggerRefresh } = await readyCloudApp();
    await click('[data-expand-device="fixture-light"]');
    const slider = element('[data-brightness="fixture-light"]') as HTMLInputElement;
    slider.focus();
    slider.value = "60";
    cloud.values.set(2, 90);

    triggerRefresh();
    await waitFor(() => tile("fixture-light").includes("90%"));

    const patched = element('[data-brightness="fixture-light"]') as HTMLInputElement;
    assert.ok(patched === slider, "focused slider was replaced by the value-only patch");
    assert.equal(patched.value, "90");
    assert.ok(document.activeElement === patched, "focused slider lost focus");
  });

  it("waits to patch the panel while a pointer interaction is in progress", async () => {
    const { cloud, triggerRefresh, runTimerTick } = await readyCloudApp();
    const toggle = element('[data-toggle-device="fixture-light"]');
    toggle.dispatchEvent(new Event("pointerdown", { bubbles: true }));
    cloud.values.set(2, 90);
    const reads = cloud.completedReads();

    triggerRefresh();
    await waitFor(() => cloud.completedReads() > reads);
    assert.match(tile("fixture-light"), /50%/);

    window.dispatchEvent(new Event("pointerup", { bubbles: true }));
    runTimerTick();
    await waitFor(() => tile("fixture-light").includes("90%"));
  });
});

describe("Credentials move out of localStorage (#28)", () => {
  it("migrates old plaintext credentials into the credential manager and strips the copy", async () => {
    const store = new Map<string, string>();
    const invoke = async <T>(cmd: string, args: Record<string, unknown> = {}): Promise<T | null> => {
      const name = String(args["name"] ?? "");
      if (cmd === "secure_store_set") {
        store.set(name, String(args["value"] ?? ""));
        return null;
      }
      if (cmd === "secure_store_get") return (store.get(name) ?? null) as T | null;
      if (cmd === "secure_store_delete") {
        store.delete(name);
        return null;
      }
      return null;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      assistantBaseURL: "https://openrouter.ai/api/v1",
      openRouterApiKey: "sk-live",
      haToken: "ha-token",
      miSession: {
        userId: "1000000000",
        cUserId: "abc",
        ssecurity: "ssecurity-value",
        serviceToken: "service-token-value",
        passToken: "account-level-pass-token",
        region: "cn",
      },
    }));

    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    await setImmediate();

    const saved = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as Record<string, unknown>;
    assert.equal("miSession" in saved, false);
    assert.equal("haToken" in saved, false);
    assert.equal("openRouterApiKey" in saved, false);
    assert.deepEqual([...store.keys()].sort(), ["assistant_api_key", "ha_token", "mi_session"]);
    assert.equal(store.get("mi_session")?.includes("passToken"), false);
    assert.equal(store.get("mi_session")?.includes("account-level-pass-token"), false);

    // A later launch reads only the credential manager, so the upgrade needs no new QR login.
    document.body.innerHTML = '<div id="app"></div>';
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    await setImmediate();
    await click("#btn-settings");
    assert.match(document.body.textContent ?? "", /已登录 10\*\*\*\*00/);
  });
});

describe("AI key stays with the server it was saved for (#19)", () => {
  function keyField(): HTMLInputElement {
    return element("#settings-api-key") as HTMLInputElement;
  }

  it("does not carry the saved key to another provider, and restores it when switching back", async () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      assistantBaseURL: "https://openrouter.ai/api/v1",
      openRouterApiKey: "sk-or-saved",
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await click("#btn-settings");
    assert.equal(keyField().value, "sk-or-saved");

    await click('[data-ai-preset="deepseek"]');
    assert.equal(keyField().value, "");

    await click('[data-ai-preset="openrouter_jev"]');
    assert.equal(keyField().value, "sk-or-saved");

    const base = element("#settings-base-url") as HTMLInputElement;
    base.value = "https://openrouter.ai.evil.com/api/v1";
    base.dispatchEvent(new Event("input", { bubbles: true }));
    assert.equal(keyField().value, "");
  });

  it("never sends a key that was saved for a different server", async () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      assistantBaseURL: "https://my-proxy.example.com/v1",
      openRouterApiKey: "sk-saved-for-openrouter",
      assistantKeyEndpoint: "openrouter.ai",
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await command("帮我想想今晚怎么安排灯光氛围");
    assert.match(document.body.textContent ?? "", /未命中本地规则。请在设置中填写 AI 服务的 API Key/);
  });
});

describe("First cloud AI request asks once (#20)", () => {
  function fakeModel(): string[] {
    const urls: string[] = [];
    const content = JSON.stringify({ actions: [], reply: "已经很合适了" });
    const invoke = async (name: string, args: Record<string, unknown> = {}) => {
      if (name !== "native_http") return undefined;
      urls.push(String(args.url));
      return { status: 200, headers: {}, body: JSON.stringify({ choices: [{ message: { content } }] }) };
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      assistantBaseURL: "https://api.deepseek.com/v1",
      assistantModel: "deepseek-chat",
      openRouterApiKey: "sk-deepseek",
      assistantKeyEndpoint: "api.deepseek.com",
    }));
    return urls;
  }

  it("sends nothing until allowed, then remembers the service", async () => {
    const urls = fakeModel();
    new MenuMijiaWindowsApp(element("#app"));
    await command("帮我想想今晚怎么安排灯光氛围");
    assert.match(document.body.textContent ?? "", /要交给云端 AI（api\.deepseek\.com）处理吗/);
    assert.equal(urls.length, 0);

    await click("#btn-cloud-allow");
    await setImmediate();
    assert.deepEqual(urls, ["https://api.deepseek.com/v1/chat/completions"]);
    const saved = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as { cloudConsentEndpoints?: string[] };
    assert.deepEqual(saved.cloudConsentEndpoints, ["api.deepseek.com"]);

    await command("帮我想想今晚怎么安排灯光氛围");
    assert.equal(urls.length, 2);
    assert.equal(document.querySelector("#btn-cloud-allow"), null);
  });

  it("declining sends nothing", async () => {
    const urls = fakeModel();
    new MenuMijiaWindowsApp(element("#app"));
    await command("帮我想想今晚怎么安排灯光氛围");
    await click("#btn-cloud-decline");
    assert.match(document.body.textContent ?? "", /没有发送/);
    assert.equal(urls.length, 0);
  });
});

describe("AI suggestions wait for a tap (#21)", () => {
  it("shows a chip for an unsure guess and runs it only when tapped", async () => {
    const answers = {
      target: { choice: "d3", confidence: 0.9 },
      op: { choice: "power_off", confidence: 0.55 },
      temp: { choice: "none", confidence: 0.99 },
    };
    const invoke = async (name: string) => {
      if (name !== "native_http") return undefined;
      return { status: 200, headers: {}, body: JSON.stringify({ answers }) };
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      assistantBaseURL: "https://openrouter.ai/api/v1",
      assistantModel: "~typesafe/jev-latest",
      openRouterApiKey: "sk-or-test",
      assistantKeyEndpoint: "openrouter.ai",
      cloudConsentEndpoints: ["openrouter.ai"],
    }));
    new MenuMijiaWindowsApp(element("#app"));
    const before = tile("light.study_desk");
    await command("帮我想想今晚怎么安排灯光氛围");
    await setImmediate();
    assert.match(document.body.textContent ?? "", /没把握直接执行，点下面的建议再执行/);
    assert.equal(tile("light.study_desk"), before);

    const chip = element("[data-suggestion-id]");
    assert.match(chip.textContent ?? "", /关闭书房台灯 · 55%/);
    chip.click();
    await setImmediate();
    await setImmediate();
    assert.equal(document.querySelector("[data-suggestion-id]"), null);
    assert.match(tile("light.study_desk"), /已关闭/);
  });
});

describe("Timers the PC slept through (#22)", () => {
  it("holds an overdue timer until 立即执行 is tapped", async () => {
    startDemo();
    const before = tile("light.study_desk");
    await command("10分钟后关闭书房台灯");
    assert.match(document.body.textContent ?? "", /已设定 10 分钟后执行「关闭书房台灯」/);
    const realNow = Date.now;
    Date.now = () => realNow() + 3 * 3600 * 1000;
    try {
      await new Promise((resolve) => setTimeout(resolve, 1_200));
      assert.match(document.body.textContent ?? "", /已错过定时：关闭书房台灯/);
      assert.equal(tile("light.study_desk"), before);
      await click("[data-run-missed]");
      await setImmediate();
      assert.match(tile("light.study_desk"), /已关闭/);
      assert.equal(document.querySelector("[data-run-missed]"), null);
    } finally {
      Date.now = realNow;
    }
  });
});

describe("全关 (#23)", () => {
  it("needs a hold in the classic skin and leaves the plug on", async () => {
    startDemo();
    const button = element("#btn-all-off");
    assert.match(button.textContent ?? "", /全关 \(3\)/);
    button.click();
    await setImmediate();
    assert.match(tile("light.living_ceiling"), /已开启/);

    button.dispatchEvent(new Event("pointerdown"));
    await new Promise((resolve) => setTimeout(resolve, 700));
    await setImmediate();
    assert.doesNotMatch(tile("light.living_ceiling"), /已开启/);
    assert.match(tile("plug.entry_socket"), /供电中/);
  });
});

describe("Unverified MIoT fallback controls (#154)", () => {
  it("shows readings and hides power, preset, and setpoint controls", async () => {
    const model = "zhimi.airp.fallback";
    const spec = inferFallbackSpec({ model, name: "净化器" });
    const fresh = MiotSynthesizer.synthesize(
      [{ did: "fb-air", name: "净化器", model, isOnline: true, specType: null }],
      [{ id: "r1", name: "客厅", dids: ["fb-air"] }],
      { [model]: spec },
      new Map<string, unknown>([
        ["fb-air.2.1", true],
        ["fb-air.2.4", 0],
        ["fb-air.3.4", 12],
      ]),
    );
    const verified = {
      id: "real-light",
      name: "书房灯",
      roomId: "r1",
      roomName: "书房",
      model: "yeelink.light.ceiling22",
      isOnline: true,
      kind: {
        kind: "light" as const,
        entityId: "miot:real-light:2",
        isOn: true,
        brightnessPercent: 50,
        colorTempKelvin: 4000,
        minKelvin: 2700,
        maxKelvin: 6500,
        currentEffect: null,
        availableEffects: [] as string[],
      },
    };
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "xiaomiCloud",
      hasCompletedOnboarding: true,
      cachedXiaomiDevices: [...fresh.devices, verified],
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();

    assert.equal(document.querySelector('[data-toggle-device="fb-air"]'), null);
    assert.equal(document.querySelector("[data-fanpreset]"), null);
    assert.equal(document.querySelector("[data-fanosc]"), null);
    assert.ok(document.querySelector('[data-toggle-device="real-light"]'));
    assert.match(tile("fb-air"), /PM2\.5 12/);

    await click('[data-body-device="fb-air"]');
    assert.equal(document.querySelector("[data-fanpreset]"), null);
    assert.equal(document.querySelector("[data-fanpercent]"), null);
    assert.match(document.body.textContent ?? "", /PM2\.5 12/);
  });

  it("opens a read-only camera and expands a climate tile that can only change fan speed", async () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "xiaomiCloud",
      hasCompletedOnboarding: true,
      isCompactGridMode: false,
      climatePanel: true,
      cachedXiaomiDevices: [
        {
          id: "cam-ro",
          name: "门口摄像机",
          roomId: "r1",
          roomName: "客厅",
          model: "chuangmi.camera.061a01",
          isOnline: true,
          kind: {
            kind: "camera",
            entityId: "miot:cam-ro:2",
            isOn: true,
            nightShot: null,
            availableNightShots: [],
            motionDetectionEntityId: null,
            isMotionDetectionOn: null,
            streamEntityId: null,
            powerWritable: false,
          },
        },
        {
          id: "cam-off",
          name: "休眠摄像机",
          roomId: "r1",
          roomName: "客厅",
          model: "chuangmi.camera.061a01",
          isOnline: true,
          kind: {
            kind: "camera",
            entityId: "miot:cam-off:2",
            isOn: false,
            nightShot: null,
            availableNightShots: [],
            motionDetectionEntityId: null,
            isMotionDetectionOn: null,
            streamEntityId: null,
            powerWritable: false,
          },
        },
        {
          id: "ac-fan",
          name: "客厅空调",
          roomId: "r1",
          roomName: "客厅",
          model: "xiaomi.aircondition.mc5",
          isOnline: true,
          kind: {
            kind: "climate",
            entityId: "miot:ac-fan:2",
            isOn: true,
            hvacMode: "fan_only",
            availableModes: [],
            targetTemperature: 26,
            currentTemperature: null,
            minTemp: 16,
            maxTemp: 30,
            step: 1,
            fanMode: "Low",
            availableFanModes: ["Low", "High"],
            powerWritable: false,
            temperatureWritable: false,
          },
        },
      ],
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();

    assert.equal(document.querySelector('[data-toggle-device="cam-ro"]'), null);
    await click('[data-body-device="cam-ro"]');
    assert.ok(document.querySelector(".cc-camera-live-sheet"));
    assert.equal(document.querySelector('[data-toggle-device="cam-ro"]'), null);
    assert.ok(document.querySelector("#btn-toggle-camera-url"));

    await click('[data-body-device="cam-off"]');
    assert.ok(document.querySelector(".cc-camera-stage.is-sleeping"));
    assert.equal(document.querySelector('[data-toggle-device="cam-off"]'), null);

    assert.ok(document.querySelector('[data-expand-device="ac-fan"]'));
    assert.equal(document.querySelector('[data-toggle-device="ac-fan"]'), null);
    assert.equal(document.querySelector("[data-acstep]"), null);
    await click('[data-expand-device="ac-fan"]');
    assert.ok(document.querySelector('[data-acfan="ac-fan:Low"]'));
  });

  it("does not dim a read-only light when the tile is dragged", async () => {
    const skins = SKINS as Array<{ id: string; readonly title: string }>;
    skins.push({ id: "frost", get title() { return "霜"; } });
    try {
      const light = (id: string, brightnessWritable: boolean) => ({
        id,
        name: id,
        roomId: "r1",
        roomName: "客厅",
        model: "yeelink.light.ceiling22",
        isOnline: true,
        kind: {
          kind: "light",
          entityId: `miot:${id}:2`,
          isOn: true,
          brightnessPercent: 40,
          colorTempKelvin: 4000,
          minKelvin: 2700,
          maxKelvin: 6500,
          currentEffect: null,
          availableEffects: [],
          powerWritable: true,
          brightnessWritable,
          colorWritable: false,
        },
      });
      localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        skin: "frost",
        isCompactGridMode: false,
        cachedXiaomiDevices: [light("ro-light", false), light("rw-light", true)],
      }));
      (globalThis as { CSS?: { escape: (value: string) => string } }).CSS = {
        escape: (value: string) => value,
      };
      new MenuMijiaWindowsApp(element("#app"));
      await setImmediate();

      const fill = (id: string) =>
        document.querySelector(`[data-tile-id="${id}"] .cc-tile-fill`)?.getAttribute("style") ?? "";
      const drag = (id: string) => {
        element(`[data-tile-id="${id}"]`).dispatchEvent(
          new window.MouseEvent("pointerdown", { bubbles: true, button: 0, clientX: 10, clientY: 40 }),
        );
        window.dispatchEvent(new window.MouseEvent("pointermove", { bubbles: true, clientX: 180, clientY: 42 }));
      };

      const before = fill("ro-light");
      assert.match(before, /width:40%/);
      drag("ro-light");
      await setImmediate();
      assert.equal(fill("ro-light"), before);
      window.dispatchEvent(new window.MouseEvent("pointerup", { bubbles: true }));
      await setImmediate();
      assert.doesNotMatch(document.body.textContent ?? "", /已将|控制失败/);

      drag("rw-light");
      await setImmediate();
      assert.match(fill("rw-light"), /width:100%/);
    } finally {
      skins.pop();
      delete (globalThis as { CSS?: unknown }).CSS;
    }
  });
});

describe("Xiaomi cloud region switch (#37)", () => {
  it("names the current region in the empty state and saves a newly selected region", async () => {
    localStorage.removeItem("menumijia.windows.update.v1");
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "xiaomiCloud",
      hasCompletedOnboarding: true,
      miCloudRegion: "de",
      cachedXiaomiDevices: [],
    }));
    new MenuMijiaWindowsApp(element("#app"));
    assert.match(document.body.textContent ?? "", /当前地区（de）没有设备，可尝试切换地区/);

    await click("#btn-empty-settings");
    const select = document.querySelector<HTMLSelectElement>("select[data-mi-region]");
    assert.ok(select, "settings must offer the region dropdown");
    assert.deepEqual(
      Array.from(select!.options).map((option) => option.value),
      ["cn", "de", "i2", "ru", "sg", "us"],
    );
    assert.equal(select!.value, "de");

    select!.value = "us";
    select!.dispatchEvent(new Event("change", { bubbles: true }));
    await setImmediate();
    const saved = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as { miCloudRegion?: string };
    assert.equal(saved.miCloudRegion, "us");
  });
});

describe("Update notice (#39)", () => {
  it("shows a newer release in settings and hands it to the tray", async () => {
    localStorage.removeItem("menumijia.windows.update.v1");
    const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
    const releaseBody = JSON.stringify({
      tag_name: "v9.9.9",
      html_url: "https://github.com/jryang1997/MenuBarMijia/releases/tag/v9.9.9",
    });
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      calls.push({ name, args });
      if (name === "native_http" && String(args["url"]).startsWith("https://api.github.com/")) {
        return { status: 200, headers: {}, body: releaseBody };
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
    }));

    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    await setImmediate();

    const trayCall = calls.find((call) => call.name === "set_update_available");
    assert.deepEqual(trayCall?.args, { version: "9.9.9" });
    const saved = JSON.parse(localStorage.getItem("menumijia.windows.update.v1") ?? "{}") as {
      release?: { version?: string };
    };
    assert.equal(saved.release?.version, "9.9.9");

    await click("#btn-settings");
    assert.match(document.body.textContent ?? "", /有新版本 v9\.9\.9，点击查看/);
    await click("#btn-open-update");
    const openCall = calls.find((call) => call.name === "open_release_page");
    assert.deepEqual(openCall?.args, {
      url: "https://github.com/jryang1997/MenuBarMijia/releases/tag/v9.9.9",
    });
  });

  it("installs an update directly in-app when a verified installer asset is present", async () => {
    localStorage.removeItem("menumijia.windows.update.v1");
    const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
    const expectedAsset = JSON.parse(
      readFileSync(new URL("./fixtures/windows-installer-asset.json", import.meta.url), "utf8"),
    ) as Record<string, unknown>;
    const releaseBody = JSON.stringify({
      tag_name: "v9.9.9",
      html_url: "https://github.com/jryang1997/MenuBarMijia/releases/tag/v9.9.9",
      body: "新增应用内直接更新",
      assets: [
        {
          name: "MenuBarMijia-9.9.9-windows-x64-setup.exe",
          browser_download_url:
            "https://github.com/jryang1997/MenuBarMijia/releases/download/v9.9.9/MenuBarMijia-9.9.9-windows-x64-setup.exe",
          size: 3145728,
        },
        {
          name: "MenuBarMijia-9.9.9.update.json",
          size: 526,
        },
      ],
    });
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      calls.push({ name, args });
      if (name === "native_http" && String(args["url"]).startsWith("https://api.github.com/")) {
        return { status: 200, headers: {}, body: releaseBody };
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
    }));

    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    await setImmediate();

    await click("#btn-footer-update");
    assert.match(document.body.textContent ?? "", /发现新版本 v9\.9\.9/);
    assert.match(document.body.textContent ?? "", /新增应用内直接更新/);
    await click("#btn-install-update");
    const installCall = calls.find((call) => call.name === "install_update");
    assert.deepEqual(installCall?.args, { asset: expectedAsset });
  });

  it("makes no request when automatic checks are switched off", async () => {
    localStorage.removeItem("menumijia.windows.update.v1");
    const urls: string[] = [];
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (name === "native_http") urls.push(String(args["url"]));
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      autoCheckUpdates: false,
    }));

    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    await setImmediate();
    assert.deepEqual(urls, []);
  });
});

describe("Interface language and temperature units (#52)", () => {
  function seed(extra: Record<string, unknown>): void {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      ...extra,
    }));
  }

  it("renders the English catalog when English is selected, and remembers it", async () => {
    seed({ interfaceLanguage: "en" });
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();

    const text = document.body.textContent ?? "";
    assert.match(text, /All off/, "the hold-to-confirm control is translated");
    assert.match(text, /Switch home|My Mi Home|Living room/, "home and room labels are translated");
    assert.doesNotMatch(text, /全关/, "no Simplified Chinese chrome leaks into English mode");
    assert.match(element('[data-body-device="light.living_ceiling"]').textContent ?? "", /Living room ceiling light/i);

    // Selecting Chinese switches back without a reload and persists the choice.
    await click("#btn-settings");
    const chinese = document.querySelector<HTMLElement>('[data-interface-language="zh-Hans"]');
    assert.ok(chinese, "language picker is present in settings");
    await click('[data-interface-language="zh-Hans"]');
    assert.match(document.body.textContent ?? "", /全关/);
    const saved = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as Record<string, unknown>;
    assert.equal(saved["interfaceLanguage"], "zh-Hans");
  });

  it("follows the OS language when the preference is system", async () => {
    Object.defineProperty(window.navigator, "languages", { value: ["en-US", "en"], configurable: true });
    Object.defineProperty(window.navigator, "language", { value: "en-US", configurable: true });
    seed({ interfaceLanguage: "system" });
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    assert.match(document.body.textContent ?? "", /All off/);
  });

  it("shows °F when the unit is Fahrenheit, and one tap moves exactly one °F", async () => {
    seed({ interfaceLanguage: "zh-Hans", temperatureUnit: "fahrenheit" });
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();

    // Demo AC runs at 25 °C = 77 °F; the sensor reads 25.5 °C = 77.9 °F.
    assert.match(textOf(".cc-climate"), /77°F/);
    assert.match(textOf(".cc-sensor"), /77\.9°F/);

    await click('[data-acstep="climate.living_ac:1"]');
    assert.match(textOf(".cc-climate"), /78°F/);
  });

  it("keeps Celsius when the unit is Celsius", async () => {
    seed({ interfaceLanguage: "zh-Hans", temperatureUnit: "celsius" });
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    assert.match(textOf(".cc-climate"), /25°C/);
    assert.match(textOf(".cc-sensor"), /25\.5°C/);
  });
});

describe("Panel placement (#204)", () => {
  function startWithCallLog(calls: Array<{ command: string; args: Record<string, unknown> }>): void {
    const invoke = async (command: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      calls.push({ command, args });
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
    }));
    new MenuMijiaWindowsApp(element("#app"));
  }

  it("sends the chosen anchor to the backend and marks it active", async () => {
    const calls: Array<{ command: string; args: Record<string, unknown> }> = [];
    startWithCallLog(calls);
    await setImmediate();

    await click("#btn-settings");
    assert.ok(document.querySelector('[data-panel-anchor="topLeft"]'), "anchor picker is present in settings");
    await click('[data-panel-anchor="topLeft"]');

    assert.deepEqual(
      calls.filter((call) => call.command === "set_panel_placement").map((call) => call.args),
      [{ anchor: "topLeft" }],
    );
    assert.equal(document.querySelector('[data-panel-anchor="topLeft"]')?.getAttribute("aria-pressed"), "true");
  });

  it("shows the anchor the backend reports, so a drag is reflected in the settings", async () => {
    const invoke = async (command: string): Promise<unknown> =>
      command === "panel_placement" ? { anchor: "bottomLeft" } : undefined;
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await click("#btn-settings");
    await setImmediate();

    assert.equal(document.querySelector('[data-panel-anchor="bottomLeft"]')?.getAttribute("aria-pressed"), "true");
  });

  it("starts an OS window move from the header but not from its buttons", async () => {
    const calls: Array<{ command: string; args: Record<string, unknown> }> = [];
    startWithCallLog(calls);
    await setImmediate();

    const press = (selector: string): void => {
      element(selector).dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true, button: 0 }));
    };
    press(".cc-title-stack");
    assert.deepEqual(calls.filter((call) => call.command === "start_panel_drag").length, 1);

    calls.length = 0;
    press("#btn-mic");
    assert.deepEqual(calls.filter((call) => call.command === "start_panel_drag").length, 0);
  });
});

describe("Customizable global shortcut (#43)", () => {
  it("registers Alt+M by default, records a custom shortcut, persists it, and unregisters when disabled", async () => {
    const hotkeyCalls: Array<{ enabled: boolean; shortcut: string }> = [];
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (name === "set_global_shortcut") {
        hotkeyCalls.push({ enabled: Boolean(args["enabled"]), shortcut: String(args["shortcut"]) });
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        interfaceLanguage: "zh-Hans",
      }),
    );

    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    assert.deepEqual(hotkeyCalls.at(-1), { enabled: true, shortcut: "Alt+M" });

    await click("#btn-settings");
    assert.equal(textOf("#btn-record-hotkey"), "Alt+M");

    // Arm the recorder; a plain letter without modifiers shows the hint and keeps listening.
    await click("#btn-record-hotkey");
    assert.equal(textOf("#btn-record-hotkey"), "按下组合…");
    window.dispatchEvent(new window.KeyboardEvent("keydown", { key: "m", code: "KeyM", bubbles: true }));
    await setImmediate();
    assert.equal(textOf("#btn-record-hotkey"), "按下组合…");
    assert.ok(document.querySelector("#hotkey-record-hint"));

    // Press Ctrl+Alt+K -> records, persists, and calls set_global_shortcut.
    window.dispatchEvent(
      new window.KeyboardEvent("keydown", {
        key: "k",
        code: "KeyK",
        ctrlKey: true,
        altKey: true,
        bubbles: true,
      }),
    );
    await setImmediate();
    assert.equal(textOf("#btn-record-hotkey"), "Ctrl+Alt+K");
    assert.deepEqual(hotkeyCalls.at(-1), { enabled: true, shortcut: "Ctrl+Alt+K" });
    const savedAfterRecord = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as Record<string, unknown>;
    assert.equal(savedAfterRecord["globalHotkey"], "Ctrl+Alt+K");

    // Reset button restores Alt+M.
    await click("#btn-reset-hotkey");
    await setImmediate();
    assert.equal(textOf("#btn-record-hotkey"), "Alt+M");
    assert.deepEqual(hotkeyCalls.at(-1), { enabled: true, shortcut: "Alt+M" });

    // Unchecking the toggle immediately unregisters the global shortcut (Coding Standard #3).
    const enableBox = element("#settings-enable-hotkey") as HTMLInputElement;
    enableBox.checked = false;
    enableBox.dispatchEvent(new window.Event("change", { bubbles: true }));
    await setImmediate();
    assert.deepEqual(hotkeyCalls.at(-1), { enabled: false, shortcut: "Alt+M" });
    assert.equal(document.querySelector("#btn-record-hotkey"), null);
  });

  it("surfaces a conflict notice when registration fails and clears it on retry", async () => {
    let shouldFail = true;
    const invoke = async (name: string): Promise<unknown> => {
      if (name === "set_global_shortcut" && shouldFail) {
        throw new Error("HotKey already registered");
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        interfaceLanguage: "zh-Hans",
      }),
    );

    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    await click("#btn-settings");

    const conflictRow = document.querySelector("#hotkey-conflict-row");
    assert.ok(conflictRow, "conflict warning is shown in Settings");
    assert.match(conflictRow.textContent ?? "", /已被其他应用占用/);

    shouldFail = false;
    await click("#btn-retry-hotkey");
    await setImmediate();
    assert.equal(document.querySelector("#hotkey-conflict-row"), null);
  });
});

describe("Smart camera support and live view (#97)", () => {
  it("clicking a camera card opens the live stream window and supports night-shot, hot-hide reopen, timed teardown, motion detection, and undo", async () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
    }));
    const app = new MenuMijiaWindowsApp(element("#app"));
    assert.match(tile("camera.living_cam"), /监控中 · 自动夜视 · 侦测开 · 点击看画面/);

    // Clicking the camera card body opens the enlarged live camera view modal.
    await click('[data-body-device="camera.living_cam"]');
    assert.ok(document.querySelector(".cc-camera-live-sheet"), "live camera modal should open on click");
    assert.match(document.body.textContent ?? "", /实时看护小窗预览/);

    // Switch night vision mode inside the live modal and verify undo restores Auto.
    await click('[data-cameranight="camera.living_cam:On"]');
    assert.match(tile("camera.living_cam"), /夜视开/);

    // 「关闭画面」only hides the modal and keeps the session hot; reopening the card
    // brings it straight back (the camera needs a long cooldown before a used P2P
    // session can be re-negotiated, so full teardown waits for the keep-alive window).
    await click("#btn-close-camera-live");
    const backdropAfterClose = element(".cc-camera-live-sheet").closest(".cc-sheet-backdrop") as HTMLElement;
    assert.equal(backdropAfterClose.style.display, "none");
    await click('[data-body-device="camera.living_cam"]');
    const backdropAfterReopen = element(".cc-camera-live-sheet").closest(".cc-sheet-backdrop") as HTMLElement;
    assert.equal(backdropAfterReopen.style.display, "");
    assert.match(document.body.textContent ?? "", /实时看护小窗预览/);

    // When the keep-alive window expires with nobody watching, the modal is removed
    // entirely (on the real backend that teardown also stops the bridge and asks the
    // camera to release its P2P session; here we pin the window short and watch the DOM).
    app.cameraKeepAliveMs = 30;
    await click("#btn-close-camera-live");
    await waitFor(() => document.querySelector(".cc-camera-live-sheet") === null);

    await click("#btn-undo");
    assert.match(tile("camera.living_cam"), /自动夜视/);

    // Expand the camera drawer and toggle motion detection, then undo.
    await click('[data-expand-device="camera.living_cam"]');
    await click('[data-cameramotion="camera.living_cam"]');
    assert.doesNotMatch(tile("camera.living_cam"), /侦测开/);
    await click("#btn-undo");
    assert.match(tile("camera.living_cam"), /侦测开/);
  });

  it("persists the Xiaomi stream quality chosen inside the live window", async () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "xiaomiCloud",
      hasCompletedOnboarding: true,
      cachedDevicesVersion: 1,
      cachedXiaomiDevices: [
        {
          id: "camera.living_cam",
          name: "客厅摄像机",
          roomId: "room_living",
          roomName: "客厅",
          model: "chuangmi.camera.81ac1",
          isOnline: true,
          kind: {
            kind: "camera",
            entityId: "miot:camera.living_cam:2",
            isOn: true,
            nightShot: "Auto",
            availableNightShots: ["Off", "On", "Auto"],
            motionDetectionEntityId: null,
            isMotionDetectionOn: null,
            streamEntityId: null,
            powerWritable: true,
          },
        },
      ],
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await click('[data-body-device="camera.living_cam"]');

    const values = Array.from(
      document.querySelectorAll<HTMLElement>("[data-cameraquality]"),
      (pill) => pill.dataset.cameraqualityValue,
    );
    assert.deepEqual(values, ["auto", "sd", "hd", "max"]);
    assert.equal(
      document.querySelector('[data-cameraquality-value="hd"]')?.getAttribute("aria-pressed"),
      "true",
      "hd is the default quality",
    );

    await click('[data-cameraquality-value="max"]');
    assert.equal(
      document.querySelector('[data-cameraquality-value="max"]')?.getAttribute("aria-pressed"),
      "true",
    );
    const saved = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as {
      cameraStreamQualities?: Record<string, string>;
    };
    assert.deepEqual(saved.cameraStreamQualities, { "camera.living_cam": "max" });
  });

  it("persists a custom camera URL and keeps its scheme when the host is localhost", async () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await click('[data-body-device="camera.living_cam"]');
    await click("#btn-toggle-camera-url");
    const input = element("#camera-stream-url-input") as HTMLInputElement;
    input.value = "https://localhost:8443/live.m3u8";
    await click("#btn-save-camera-url");
    assert.equal(
      (element("#cc-camera-video") as HTMLVideoElement).getAttribute("src"),
      "https://127.0.0.1:8443/live.m3u8",
    );

    document.body.innerHTML = '<div id="app"></div>';
    new MenuMijiaWindowsApp(element("#app"));
    await click('[data-body-device="camera.living_cam"]');
    assert.equal(
      (element("#cc-camera-video") as HTMLVideoElement).getAttribute("src"),
      "https://127.0.0.1:8443/live.m3u8",
    );

    await click('.cc-camera-live-sheet .cc-segmented-pills [data-toggle-device="camera.living_cam"]');
    assert.match(document.body.textContent ?? "", /摄像机处于物理休眠状态/);
    await click('.cc-camera-stage.is-sleeping [data-toggle-device="camera.living_cam"]');
    assert.equal(
      (element("#cc-camera-video") as HTMLVideoElement).getAttribute("src"),
      "https://127.0.0.1:8443/live.m3u8",
    );
  });

  it("bridges Home Assistant camera_proxy_stream URLs through native JPEG frames, not a browser fetch", async () => {
    const bridgedCalls: Array<{ did: string; hlsUrl: string }> = [];
    const frameCalls: string[] = [];
    const browserFetches: string[] = [];
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
      browserFetches.push(url);
      return new Response(null, { status: 401 });
    }) as typeof fetch;
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (name === "secure_store_get") return args.name === "ha_token" ? "ha-token" : null;
      if (name === "go2rtc_endpoint") {
        return { origin: "http://127.0.0.1:43123", authorization: "Basic bXVzZXI6bXBhc3M=" };
      }
      if (name === "go2rtc_jpeg_frame") {
        frameCalls.push(String(args.src));
        return "aGVsbG8";
      }
      if (name === "ha_snapshot") {
        return {
          areas: [{ area_id: "living", name: "客厅" }],
          devices: [{ id: "dev_cam", name: "玄关摄像机", area_id: "living" }],
          entities: [{ entity_id: "camera.front", device_id: "dev_cam", area_id: "living" }],
          states: [
            {
              entity_id: "camera.front",
              state: "streaming",
              attributes: {
                friendly_name: "玄关摄像机",
                entity_picture: "/api/camera_proxy/camera.front?token=short-lived",
              },
            },
          ],
        };
      }
      if (name === "bridge_hls_camera_stream") {
        bridgedCalls.push({ did: String(args.did), hlsUrl: String(args.hlsUrl) });
        return "cam_mjpeg_dev_cam";
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    try {
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "homeAssistant",
        hasCompletedOnboarding: true,
        haBaseURL: "http://192.168.1.50:8123",
      }),
    );
    new MenuMijiaWindowsApp(element("#app"));
    await waitFor(() => document.querySelector('[data-body-device="dev_cam"]') !== null);
    await click('[data-body-device="dev_cam"]');
    await waitFor(() => bridgedCalls.length === 1);
    assert.deepEqual(bridgedCalls[0], {
      did: "dev_cam",
      hlsUrl: "http://192.168.1.50:8123/api/camera_proxy_stream/camera.front?token=short-lived",
    });
    await waitFor(() => frameCalls.length === 1);
    assert.deepEqual(frameCalls, ["cam_mjpeg_dev_cam"]);
    assert.equal(
      (element("#cc-camera-live-img") as HTMLImageElement).getAttribute("src"),
      "data:image/jpeg;base64,aGVsbG8",
    );
    assert.equal(browserFetches.some((url) => url.includes("127.0.0.1")), false);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("bridges a loopback HLS server that is not the owned go2rtc origin", async () => {
    const bridgedCalls: string[] = [];
    const frameCalls: string[] = [];
    let bridgedOwnedGo2rtc = false;
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (name === "go2rtc_endpoint") return { origin: "http://127.0.0.1:43123", authorization: "Basic aa" };
      if (name === "bridge_hls_camera_stream") {
        const hlsUrl = String(args.hlsUrl);
        if (hlsUrl.includes("43123")) bridgedOwnedGo2rtc = true;
        bridgedCalls.push(hlsUrl);
        return "cam_mjpeg_living";
      }
      if (name === "go2rtc_jpeg_frame") {
        frameCalls.push(String(args.src));
        return "aGVsbG8";
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await click('[data-body-device="camera.living_cam"]');
    await click("#btn-toggle-camera-url");
    (element("#camera-stream-url-input") as HTMLInputElement).value = "http://127.0.0.1:8080/live.m3u8";
    await click("#btn-save-camera-url");
    await waitFor(() => bridgedCalls.length === 1);
    assert.deepEqual(bridgedCalls, ["http://127.0.0.1:8080/live.m3u8"]);

    bridgedCalls.length = 0;
    await click("#btn-toggle-camera-url");
    (element("#camera-stream-url-input") as HTMLInputElement).value = "https://localhost:8443/live.m3u8";
    await click("#btn-save-camera-url");
    await waitFor(() => bridgedCalls.length === 1);
    assert.deepEqual(bridgedCalls, ["https://127.0.0.1:8443/live.m3u8"]);

    bridgedCalls.length = 0;
    await click("#btn-toggle-camera-url");
    (element("#camera-stream-url-input") as HTMLInputElement).value = "http://127.0.0.1:43123/api/stream.m3u8?src=cam";
    await click("#btn-save-camera-url");
    await waitFor(() => frameCalls.includes("cam"));
    assert.deepEqual(bridgedCalls, []);
    assert.equal(
      (element("#cc-camera-live-img") as HTMLImageElement).getAttribute("src"),
      "data:image/jpeg;base64,aGVsbG8",
    );

    const framesBeforeReopen = frameCalls.length;
    document.body.innerHTML = '<div id="app"></div>';
    new MenuMijiaWindowsApp(element("#app"));
    await click('[data-body-device="camera.living_cam"]');
    await waitFor(() => frameCalls.length > framesBeforeReopen && document.querySelector("#cc-camera-live-img") !== null);
    assert.equal(frameCalls.at(-1), "cam");
    assert.equal(
      (element("#cc-camera-live-img") as HTMLImageElement).getAttribute("src"),
      "data:image/jpeg;base64,aGVsbG8",
    );
    assert.equal(bridgedOwnedGo2rtc, false);
  });

  it("drops the frame-gap abort listener when the timer fires", async () => {
    const controller = new AbortController();
    let listeners = 0;
    const add = controller.signal.addEventListener.bind(controller.signal);
    const remove = controller.signal.removeEventListener.bind(controller.signal);
    controller.signal.addEventListener = ((type: string, listener: EventListenerOrEventListenerObject, options?: boolean | AddEventListenerOptions) => {
      if (type === "abort") listeners += 1;
      return add(type, listener, options);
    }) as typeof controller.signal.addEventListener;
    controller.signal.removeEventListener = ((type: string, listener: EventListenerOrEventListenerObject, options?: boolean | EventListenerOptions) => {
      if (type === "abort") listeners -= 1;
      return remove(type, listener, options);
    }) as typeof controller.signal.removeEventListener;
    await waitForCameraFrameGap(controller.signal, 15);
    await waitForCameraFrameGap(controller.signal, 15);
    assert.equal(listeners, 0);
    controller.abort();
    assert.equal(listeners, 0);
  });

  it("does not start a bridge after the camera closes during the endpoint refresh", async () => {
    let releaseEndpoint: (value: { origin: string; authorization: string }) => void = () => {};
    const endpointGate = new Promise<{ origin: string; authorization: string }>((resolve) => {
      releaseEndpoint = resolve;
    });
    const bridgedCalls: string[] = [];
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (name === "go2rtc_endpoint") return endpointGate;
      if (name === "bridge_hls_camera_stream") {
        bridgedCalls.push(String(args.hlsUrl));
        return "cam_mjpeg_living";
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
    }));
    const app = new MenuMijiaWindowsApp(element("#app"));
    app.cameraKeepAliveMs = 20;
    await click('[data-body-device="camera.living_cam"]');
    await click("#btn-toggle-camera-url");
    (element("#camera-stream-url-input") as HTMLInputElement).value = "http://127.0.0.1:8080/live.m3u8";
    await click("#btn-save-camera-url");
    await click("#btn-close-camera-live");
    await waitFor(() => document.querySelector(".cc-camera-live-sheet") === null);
    releaseEndpoint({ origin: "http://127.0.0.1:43123", authorization: "Basic aa" });
    await setImmediate();
    assert.deepEqual(bridgedCalls, []);
    assert.equal(document.querySelector(".cc-camera-live-sheet"), null);
  });

  it("releases an active P2P session when negotiation fails while the camera modal remains open", async () => {
    const camSpec = {
      type: "urn:miot-spec-v2:device:camera:0000A01C:chuangmi-81ac1:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:camera-control:0000782F:chuangmi-81ac1:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:chuangmi-81ac1:1", format: "bool", access: ["read", "write"] },
          ],
          actions: [],
        },
        {
          iid: 9,
          type: "urn:miot-spec-v2:service:p2p-stream:00007881:chuangmi-81ac1:1",
          properties: [],
          actions: [
            { iid: 1, type: "urn:miot-spec-v2:action:start-p2p-stream:00002839:chuangmi-81ac1:1", in: [], out: [] },
            { iid: 2, type: "urn:miot-spec-v2:action:stop-stream:00002822:chuangmi-81ac1:1", in: [], out: [] },
          ],
        },
      ],
    };
    const security = "AQIDBAUGBwgJCgsMDQ4PEA==";
    const actionCalls: Array<{ siid: number; aiid: number }> = [];
    let sessionActive = false;
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (name !== "native_http") return undefined;
      const url = String(args["url"] ?? "");
      if (url.includes("/instance?")) {
        return { status: 200, headers: {}, body: JSON.stringify(camSpec) };
      }
      if (url.includes("/instances?")) {
        return { status: 200, headers: {}, body: JSON.stringify({ instances: [{ model: "chuangmi.camera.81ac1", type: camSpec.type }] }) };
      }
      let result: unknown = {};
      if (url.includes("device_list")) {
        // Missing localip forces P2P negotiation failure after start-p2p-stream succeeded.
        result = {
          list: [{ did: "cam-1", name: "客厅摄像机", model: "chuangmi.camera.81ac1", isOnline: true, spec_type: camSpec.type }],
          has_more: false,
        };
      } else if (url.includes("homeroom/")) {
        result = { homelist: [{ id: "1", name: "家", dids: [], roomlist: [{ id: "10", name: "客厅", dids: ["cam-1"] }] }] };
      } else if (url.includes("miotspec/prop/")) {
        result = [{ did: "cam-1", siid: 2, piid: 1, code: 0, value: true }];
      } else if (url.includes("miotspec/action")) {
        const fields = new URLSearchParams(String(args["body"] ?? ""));
        const nonce = fields.get("_nonce") ?? "";
        const encrypted = fields.get("data") ?? "";
        const payload = JSON.parse(
          MiCloudCrypto.decryptResponse(encrypted, MiCloudCrypto.signedNonce(security, nonce)),
        ) as { params?: { siid: number; aiid: number } };
        if (payload.params) {
          actionCalls.push({ siid: payload.params.siid, aiid: payload.params.aiid });
          if (payload.params.aiid === 1) {
            sessionActive = true;
            result = { code: 0, out: [] };
          } else if (payload.params.aiid === 2) {
            const wasActive = sessionActive;
            sessionActive = false;
            result = { code: wasActive ? 0 : -1, out: [] };
          }
        }
      }
      return { status: 200, headers: {}, body: JSON.stringify({ code: 0, result }) };
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        miSession: { userId: "100", cUserId: "c100", ssecurity: security, serviceToken: "tok", passToken: "", region: "cn" },
        cachedModelTypes: { "chuangmi.camera.81ac1": camSpec.type },
      }),
    );
    new MenuMijiaWindowsApp(element("#app"));
    await waitFor(() => document.querySelector('[data-body-device="cam-1"]') !== null);
    await click('[data-body-device="cam-1"]');
    await waitFor(() => actionCalls.some((c) => c.siid === 9 && c.aiid === 1) && !sessionActive);
    assert.ok(document.querySelector(".cc-camera-live-sheet"), "modal remains open showing error state");
    assert.equal(sessionActive, false, "failure cleanup released the started P2P session");
  });

  it("hides the Xiaomi quality pills when the cloud stream is not the P2P bridge", async () => {
    const camSpec = {
      type: "urn:miot-spec-v2:device:camera:0000A01C:chuangmi-81ac1:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:camera-control:0000782F:chuangmi-81ac1:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:chuangmi-81ac1:1", format: "bool", access: ["read", "write"] },
          ],
          actions: [],
        },
        {
          iid: 10,
          type: "urn:miot-spec-v2:service:cloud-stream:00007882:chuangmi-81ac1:1",
          properties: [],
          actions: [
            { iid: 1, type: "urn:miot-spec-v2:action:start-hls-stream:00002838:chuangmi-81ac1:1", in: [], out: [] },
          ],
        },
      ],
    };
    const actionCalls: string[] = [];
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (name === "go2rtc_endpoint") return { origin: "http://127.0.0.1:43123", authorization: "Basic aa" };
      if (name === "bridge_hls_camera_stream") return "cam_mjpeg_living";
      if (name !== "native_http") return undefined;
      const url = String(args["url"] ?? "");
      if (url.includes("/instance?")) {
        return { status: 200, headers: {}, body: JSON.stringify(camSpec) };
      }
      if (url.includes("/instances?")) {
        return { status: 200, headers: {}, body: JSON.stringify({ instances: [{ model: "chuangmi.camera.81ac1", type: camSpec.type }] }) };
      }
      let result: unknown = {};
      if (url.includes("device_list")) {
        result = {
          list: [{ did: "cam-1", name: "客厅摄像机", model: "chuangmi.camera.81ac1", isOnline: true, spec_type: camSpec.type }],
          has_more: false,
        };
      } else if (url.includes("homeroom/")) {
        result = { homelist: [{ id: "1", name: "家", dids: [], roomlist: [{ id: "10", name: "客厅", dids: ["cam-1"] }] }] };
      } else if (url.includes("miotspec/prop/")) {
        result = [{ did: "cam-1", siid: 2, piid: 1, code: 0, value: true }];
      } else if (url.includes("miotspec/action")) {
        actionCalls.push(url);
        result = { url: "https://example.com/live.m3u8" };
      }
      return { status: 200, headers: {}, body: JSON.stringify({ code: 0, result }) };
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    const security = "AQIDBAUGBwgJCgsMDQ4PEA==";
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        cachedDevicesVersion: 1,
        cachedXiaomiDevices: [
          {
            id: "cam-1",
            name: "客厅摄像机",
            roomId: "room_living",
            roomName: "客厅",
            model: "chuangmi.camera.81ac1",
            isOnline: true,
            kind: {
              kind: "camera",
              entityId: "miot:cam-1:2",
              isOn: true,
              nightShot: "Auto",
              availableNightShots: ["Off", "On", "Auto"],
              motionDetectionEntityId: null,
              isMotionDetectionOn: null,
              streamEntityId: null,
              powerWritable: true,
            },
          },
        ],
        miSession: { userId: "100", cUserId: "c100", ssecurity: security, serviceToken: "tok", passToken: "", region: "cn" },
        cachedModelTypes: { "chuangmi.camera.81ac1": camSpec.type },
      }),
    );
    new MenuMijiaWindowsApp(element("#app"));
    await waitFor(() => document.querySelector('[data-body-device="cam-1"]') !== null);
    await click('[data-body-device="cam-1"]');
    await waitFor(() => document.querySelector("#cc-camera-stage") !== null);
    assert.equal(
      document.querySelectorAll("[data-cameraquality]").length,
      0,
      "cloud HLS playback does not consume the P2P quality subtype",
    );
  });
});

describe("Air purifier support (#98)", () => {
  it("displays PM2.5, air quality, temperature/humidity, filter life, and supports mode & fan speed slider with undo", async () => {
    const rma3Spec = {
      type: "urn:miot-spec-v2:device:air-purifier:0000A007:zhimi-rma3:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:air-purifier:00007811:zhimi-rma3:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:zhimi-rma3:1", format: "bool", access: ["read", "write"] },
            {
              iid: 4,
              type: "urn:miot-spec-v2:property:mode:00000008:zhimi-rma3:1",
              format: "uint8",
              access: ["read", "write"],
              valueList: [
                { value: 0, description: "Auto" },
                { value: 1, description: "Sleep" },
                { value: 2, description: "Favorite" },
              ],
            },
          ],
          actions: [],
        },
        {
          iid: 3,
          type: "urn:miot-spec-v2:service:environment:0000780A:zhimi-rma3:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:relative-humidity:0000000C:zhimi-rma3:1", format: "uint8", access: ["read"], valueRange: [0, 100, 1] },
            { iid: 4, type: "urn:miot-spec-v2:property:pm2.5-density:00000034:zhimi-rma3:1", format: "uint16", access: ["read"], valueRange: [0, 1000, 1] },
            { iid: 7, type: "urn:miot-spec-v2:property:temperature:00000020:zhimi-rma3:1", format: "float", access: ["read"], valueRange: [-30, 100, 1] },
            {
              iid: 8,
              type: "urn:miot-spec-v2:property:air-quality:0000001C:zhimi-rma3:1",
              format: "uint8",
              access: ["read"],
              valueList: [
                { value: 0, description: "Excellent" },
                { value: 1, description: "Good" },
              ],
            },
          ],
          actions: [],
        },
        {
          iid: 4,
          type: "urn:miot-spec-v2:service:filter:0000780B:zhimi-rma3:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:filter-life-level:0000001E:zhimi-rma3:1", format: "uint8", access: ["read"], valueRange: [0, 100, 1] },
          ],
          actions: [],
        },
        {
          iid: 11,
          type: "urn:miot-spec-v2:service:air-purifier-favorite:000078B2:zhimi-rma3:1",
          properties: [
            {
              iid: 1,
              type: "urn:miot-spec-v2:property:fan-level:00000016:zhimi-rma3:1",
              format: "uint8",
              access: ["read", "write"],
              valueList: Array.from({ length: 15 }, (_, i) => ({ value: i, description: `Level${i}` })),
            },
          ],
          actions: [],
        },
      ],
    };

    const state = new Map<string, unknown>([
      ["2.1", true],
      ["2.4", 0],
      ["11.1", 7],
      ["3.4", 18],
      ["3.8", 0],
      ["3.7", 24.5],
      ["3.1", 52],
      ["4.1", 86],
    ]);

    const security = "AQIDBAUGBwgJCgsMDQ4PEA==";
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (name !== "native_http") return undefined;
      const url = String(args["url"] ?? "");
      if (url.includes("/instance?")) {
        return { status: 200, headers: {}, body: JSON.stringify(rma3Spec) };
      }
      if (url.includes("/instances?")) {
        return { status: 200, headers: {}, body: JSON.stringify({ instances: [{ model: "zhimi.airp.rma3", type: rma3Spec.type }] }) };
      }
      let result: unknown = {};
      if (url.includes("device_list")) {
        result = {
          list: [{ did: "airp-rma3", name: "书房空气净化器", model: "zhimi.airp.rma3", isOnline: true, spec_type: rma3Spec.type }],
          has_more: false,
        };
      } else if (url.includes("homeroom/")) {
        result = { homelist: [{ id: "1", name: "家", dids: [], roomlist: [{ id: "10", name: "书房", dids: ["airp-rma3"] }] }] };
      } else if (url.includes("miotspec/prop/")) {
        const fields = new URLSearchParams(String(args["body"] ?? ""));
        const nonce = fields.get("_nonce") ?? "";
        const encrypted = fields.get("data") ?? "";
        const payload = JSON.parse(
          MiCloudCrypto.decryptResponse(encrypted, MiCloudCrypto.signedNonce(security, nonce))
        ) as { params?: Array<{ did: string; siid: number; piid: number; value?: unknown }> };
        result = (payload.params ?? []).map((p) => {
          if (url.includes("/set")) {
            state.set(`${p.siid}.${p.piid}`, p.value);
            return { did: p.did, siid: p.siid, piid: p.piid, code: 0 };
          }
          return { did: p.did, siid: p.siid, piid: p.piid, code: 0, value: state.get(`${p.siid}.${p.piid}`) };
        });
      }
      return { status: 200, headers: {}, body: JSON.stringify({ code: 0, result }) };
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        miSession: { userId: "10001", cUserId: "", ssecurity: security, serviceToken: "tok", passToken: "", region: "cn" },
        cachedModelTypes: { "zhimi.airp.rma3": rma3Spec.type },
      }),
    );

    new MenuMijiaWindowsApp(element("#app"));
    await waitFor(() => Boolean(document.querySelector('[data-body-device="airp-rma3"]')));
    assert.match(tile("airp-rma3"), /运行中 · 自动 · 50% · PM2\.5 18 优 · 25°C 52%/);

    await click('[data-expand-device="airp-rma3"]');
    const drawerText = document.body.textContent ?? "";
    assert.match(drawerText, /空气质量 PM2\.5 18 \(优\)/);
    assert.match(drawerText, /温湿度 24\.5°C · 52%/);
    assert.match(drawerText, /滤芯余量 86%/);

    await setRange('[data-fanpercent="airp-rma3"]', "100");
    await waitFor(() => state.get("11.1") === 14);
    assert.equal(state.get("2.4"), 2);
    assert.match(tile("airp-rma3"), /最爱 · 100%/);

    await click("#btn-undo");
    await waitFor(() => state.get("11.1") === 7);
    assert.equal(state.get("2.4"), 0);
    assert.match(tile("airp-rma3"), /自动 · 50%/);
  });

  it("preserves sensor > purifier > climate priority in environment readings even when an air purifier precedes a sensor in device layout (#103)", async () => {
    const rma3Spec = {
      type: "urn:miot-spec-v2:device:air-purifier:0000A007:zhimi-rma3:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:air-purifier:00007811:zhimi-rma3:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:zhimi-rma3:1", format: "bool", access: ["read", "write"] },
          ],
          actions: [],
        },
        {
          iid: 3,
          type: "urn:miot-spec-v2:service:environment:0000780A:zhimi-rma3:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:relative-humidity:0000000C:zhimi-rma3:1", format: "uint8", access: ["read"] },
            { iid: 7, type: "urn:miot-spec-v2:property:temperature:00000020:zhimi-rma3:1", format: "float", access: ["read"] },
          ],
          actions: [],
        },
      ],
    };
    const sensorSpec = {
      type: "urn:miot-spec-v2:device:temperature-humidity-sensor:0000A00A:miaomiaoce-t2:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:temperature-humidity-sensor:00007814:miaomiaoce-t2:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:temperature:00000020:miaomiaoce-t2:1", format: "float", access: ["read"] },
            { iid: 2, type: "urn:miot-spec-v2:property:relative-humidity:0000000C:miaomiaoce-t2:1", format: "uint8", access: ["read"] },
          ],
          actions: [],
        },
      ],
    };

    const security = "AQIDBAUGBwgJCgsMDQ4PEA==";
    const invoke = async (name: string, args: Record<string, unknown> = {}): Promise<unknown> => {
      if (name !== "native_http") return undefined;
      const url = String(args["url"] ?? "");
      if (url.includes("/instance?")) {
        const body = url.includes("temperature-humidity-sensor") ? sensorSpec : rma3Spec;
        return { status: 200, headers: {}, body: JSON.stringify(body) };
      }
      if (url.includes("/instances?")) {
        return {
          status: 200,
          headers: {},
          body: JSON.stringify({
            instances: [
              { model: "zhimi.airp.rma3", type: rma3Spec.type },
              { model: "miaomiaoce.sensor_ht.t2", type: sensorSpec.type },
            ],
          }),
        };
      }
      let result: unknown = {};
      if (url.includes("device_list")) {
        result = {
          list: [
            { did: "airp-rma3", name: "书房空净", model: "zhimi.airp.rma3", isOnline: true, spec_type: rma3Spec.type },
            { did: "sensor-t2", name: "客厅温湿度计", model: "miaomiaoce.sensor_ht.t2", isOnline: true, spec_type: sensorSpec.type },
          ],
          has_more: false,
        };
      } else if (url.includes("homeroom/")) {
        result = {
          homelist: [
            {
              id: "1",
              name: "家",
              dids: [],
              roomlist: [
                { id: "10", name: "书房", dids: ["airp-rma3"] },
                { id: "20", name: "客厅", dids: ["sensor-t2"] },
              ],
            },
          ],
        };
      } else if (url.includes("miotspec/prop/")) {
        const fields = new URLSearchParams(String(args["body"] ?? ""));
        const nonce = fields.get("_nonce") ?? "";
        const encrypted = fields.get("data") ?? "";
        const payload = JSON.parse(
          MiCloudCrypto.decryptResponse(encrypted, MiCloudCrypto.signedNonce(security, nonce))
        ) as { params?: Array<{ did: string; siid: number; piid: number }> };
        result = (payload.params ?? []).map((p) => {
          if (p.did === "airp-rma3") {
            const val = p.siid === 2 ? true : p.piid === 7 ? 26.5 : 48;
            return { did: p.did, siid: p.siid, piid: p.piid, code: 0, value: val };
          }
          const val = p.piid === 1 ? 22.0 : 55;
          return { did: p.did, siid: p.siid, piid: p.piid, code: 0, value: val };
        });
      }
      return { status: 200, headers: {}, body: JSON.stringify({ code: 0, result }) };
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "xiaomiCloud",
        hasCompletedOnboarding: true,
        miSession: { userId: "10001", cUserId: "", ssecurity: security, serviceToken: "tok", passToken: "", region: "cn" },
        cachedModelTypes: {
          "zhimi.airp.rma3": rma3Spec.type,
          "miaomiaoce.sensor_ht.t2": sensorSpec.type,
        },
        layout: { order: ["airp-rma3", "sensor-t2"] },
      }),
    );

    new MenuMijiaWindowsApp(element("#app"));
    await waitFor(() => document.querySelectorAll(".cc-env-chip").length === 2);
    const chipLabels = Array.from(document.querySelectorAll(".cc-env-label"), (node) => node.textContent);
    assert.deepEqual(chipLabels, ["客厅", "书房空净"]);
  });

  it("reuses the outer popover element and clears is-opening so clicks do not replay the drop-in animation", async () => {
    startDemo();
    const root = element("#app");
    const initialPopover = element(".cc-popover");
    assert.equal(root.classList.contains("is-opening"), true);

    await click('[data-toggle-device="light.living_ceiling"]');
    assert.equal(root.classList.contains("is-opening"), false);
    assert.equal(element(".cc-popover"), initialPopover);
  });

  it("displays 0.5°C increments on every single AC step click in Celsius mode", async () => {
    localStorage.setItem(
      "menumijia.windows.settings.v2",
      JSON.stringify({
        connectionMode: "demo",
        hasCompletedOnboarding: true,
        interfaceLanguage: "zh-Hans",
        temperatureUnit: "celsius",
      }),
    );
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();

    const tempEl = () => element(".cc-climate .cc-climate-temp");
    assert.equal(tempEl().textContent, "25°C");

    await click('[data-acstep="climate.living_ac:1"]');
    assert.equal(tempEl().textContent, "25.5°C");

    await click('[data-acstep="climate.living_ac:1"]');
    assert.equal(tempEl().textContent, "26°C");

    await click('[data-acstep="climate.living_ac:-1"]');
    assert.equal(tempEl().textContent, "25.5°C");

    await click('[data-acstep="climate.living_ac:-1"]');
    assert.equal(tempEl().textContent, "25°C");

    await click('[data-acstep="climate.living_ac:-1"]');
    assert.equal(tempEl().textContent, "24.5°C");
  });

  it("switches between light (daylight) and dark appearance in Settings and via the footer toggle", async () => {
    startDemo();
    const popover = () => element(".cc-popover");
    const startedLight = popover().classList.contains("scheme-light");

    // Quick toggle in the footer flips between Light (daylight) and Dark mode.
    await click("#btn-toggle-appearance");
    assert.equal(popover().classList.contains(startedLight ? "scheme-dark" : "scheme-light"), true);
    assert.equal(element("#app").dataset.scheme, startedLight ? "dark" : "light");

    // Settings sheet exposes System / Light / Dark segmented options.
    await click("#btn-settings");
    await click('[data-appearance="light"]');
    assert.equal(popover().classList.contains("scheme-light"), true);
    assert.equal(element("#app").dataset.scheme, "light");
    assert.equal(element('[data-appearance="light"]').getAttribute("aria-pressed"), "true");

    await click('[data-appearance="dark"]');
    assert.equal(popover().classList.contains("scheme-dark"), true);
    assert.equal(element("#app").dataset.scheme, "dark");
    assert.equal(element('[data-appearance="dark"]').getAttribute("aria-pressed"), "true");

    const saved = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as Record<string, unknown>;
    assert.equal(saved["appearance"], "dark");
  });

  it("renders bottom-right corner arc resize handles in layout edit mode and supports drag resizing and tap cycling without reordering (#115)", async () => {
    startDemo();
    const lightSelector = '[data-tile-id="light.living_ceiling"]';
    element(lightSelector).dispatchEvent(new window.MouseEvent("contextmenu", { bubbles: true, clientX: 80, clientY: 80 }));
    await click("[data-start-editing]");

    assert.equal(element(".cc-popover").classList.contains("is-editing"), true);
    assert.equal(document.querySelectorAll(".cc-size-badge").length, 0, "Old top-right badge must be removed");

    const handleSelector = '.cc-resize-handle[data-cycle-size="light.living_ceiling"]';
    assert.equal(Boolean(element(handleSelector).querySelector("svg.cc-resize-arc path")), true, "Corner arc SVG path must be rendered inside .cc-resize-handle");
    assert.equal(element(handleSelector).getAttribute("data-tile-size"), "half");

    const readSavedSizes = (): Record<string, string> => {
      const raw = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as {
        layout?: { tileSizes?: Record<string, string> };
      };
      return raw.layout?.tileSizes ?? {};
    };
    const readSavedOrder = (): string[] => {
      const raw = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as {
        layout?: { order?: string[] };
      };
      return raw.layout?.order ?? [];
    };

    // 1. Outward drag on .cc-resize-handle: half -> full -> panel without starting card reorder.
    element(handleSelector).dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true, button: 0, clientX: 160, clientY: 160 }));
    window.dispatchEvent(new window.MouseEvent("pointermove", { bubbles: true, clientX: 220, clientY: 160 }));
    await setImmediate();
    assert.equal(readSavedSizes()["all|light.living_ceiling"], "full");
    assert.equal(element(lightSelector).classList.contains("is-dragging"), false, "Handle drag must not start card reorder drag");

    window.dispatchEvent(new window.MouseEvent("pointermove", { bubbles: true, clientX: 220, clientY: 220 }));
    await setImmediate();
    assert.equal(readSavedSizes()["all|light.living_ceiling"], "panel");
    assert.equal(element(lightSelector).classList.contains("is-dragging"), false);

    window.dispatchEvent(new window.MouseEvent("pointerup", { bubbles: true, clientX: 220, clientY: 220 }));
    await setImmediate();
    assert.deepEqual(readSavedOrder(), []);
    assert.equal(element(lightSelector).classList.contains("is-resizing"), false, "jiggle pause class must be cleaned up on release");
    assert.equal(element(handleSelector).classList.contains("is-active"), false, "handle emphasis must be cleaned up on release");

    // 2. Inward drag on .cc-resize-handle: panel -> full -> half without starting card reorder.
    element(handleSelector).dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true, button: 0, clientX: 300, clientY: 260 }));
    window.dispatchEvent(new window.MouseEvent("pointermove", { bubbles: true, clientX: 240, clientY: 260 }));
    await setImmediate();
    assert.equal(readSavedSizes()["all|light.living_ceiling"], "full");

    window.dispatchEvent(new window.MouseEvent("pointermove", { bubbles: true, clientX: 240, clientY: 200 }));
    await setImmediate();
    assert.equal(readSavedSizes()["all|light.living_ceiling"], "half");

    window.dispatchEvent(new window.MouseEvent("pointerup", { bubbles: true, clientX: 240, clientY: 200 }));
    await setImmediate();
    assert.deepEqual(readSavedOrder(), []);

    // 3. Light tap/click on .cc-resize-handle still cycles half -> full -> panel -> half.
    await click(handleSelector);
    assert.equal(readSavedSizes()["all|light.living_ceiling"], "full");
    await click(handleSelector);
    assert.equal(readSavedSizes()["all|light.living_ceiling"], "panel");
    await click(handleSelector);
    assert.equal(readSavedSizes()["all|light.living_ceiling"], "half");
  });
});

describe("Manual habit learning and proactive Top-4 (#113)", () => {
  const settingsKey = "menumijia.windows.settings.v2";

  function habitEntries(): Array<{ bucket: string; targetId: string; operationKey: string; count: number }> {
    const parsed = JSON.parse(localStorage.getItem(settingsKey) ?? "{}") as { habitEntries?: Array<{ bucket: string; targetId: string; operationKey: string; count: number }> };
    return parsed.habitEntries ?? [];
  }

  it("records a time-bucket habit for a manual card toggle and rolls it back on undo", async () => {
    startDemo();
    await click('[data-toggle-device="light.living_ceiling"]');

    const entries = habitEntries();
    assert.equal(entries.length, 1);
    assert.equal(entries[0]?.targetId, "light.living_ceiling");
    assert.equal(entries[0]?.operationKey, "power:off");
    assert.equal(entries[0]?.count, 1);
    assert.match(entries[0]?.bucket ?? "", /^(清晨|午间|下午|夜晚|深夜)$/);

    await click("#btn-undo");
    assert.equal(habitEntries().length, 0);
  });

  it("records every committed slider gesture with its final value", async () => {
    startDemo();
    await click('[data-expand-device="light.living_ceiling"]');
    await setRange('[data-brightness="light.living_ceiling"]', "30");
    await setRange('[data-brightness="light.living_ceiling"]', "42");

    // Each `change` event is one committed gesture on Windows, so each trains one habit.
    assert.deepEqual(habitEntries().map((e) => e.operationKey), ["brightness:30", "brightness:42"]);
  });

  it("shows four zero-delay proactive suggestions when opening the ball", async () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      enableGrokBall: true,
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await click("#btn-grok-ball");
    // Demo home: two lights on (全屋关灯), then running AC, plug, and camera power-offs.
    const pills = [...document.querySelectorAll<HTMLElement>("[data-proactive-id]")];
    assert.equal(pills.length, 4);
    assert.match(pills[0]?.textContent ?? "", /全屋关灯/);
  });

  it("executes a proactive suggestion and records it as a habit", async () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      enableGrokBall: true,
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await click("#btn-grok-ball");
    await click('[data-proactive-id^="builtin:lightsOff"]');
    await waitFor(() => habitEntries().length > 0);
    assert.ok(habitEntries().every((e) => e.operationKey === "power:off"));
    // Reopening filters out the completed action because the lights are now off.
    await waitFor(() => document.querySelector(".cc-grok-stage") === null);
    await click("#btn-grok-ball");
    assert.equal(document.querySelector('[data-proactive-id^="builtin:lightsOff"]'), null);
  });

  it("records a scene quick action through the natural command flow", async () => {
    startDemo();
    await click('[data-scene-cmd="关闭所有灯"]');
    await waitFor(() => habitEntries().length > 0);

    const entries = habitEntries();
    assert.ok(entries.length >= 1);
    assert.ok(entries.every((e) => e.operationKey === "power:off"));
    assert.ok(entries.some((e) => e.targetId === "light.living_ceiling"));

    await click("#btn-undo");
    assert.equal(habitEntries().length, 0);
  });

  it("previews the draft habit sentence and writes the share switch only when saving", async () => {
    const hour = new Date().getHours();
    const bucket = hour >= 18 && hour < 23 ? "夜晚" : hour >= 14 && hour < 18 ? "下午" : hour >= 11 && hour < 14 ? "午间" : hour >= 6 && hour < 11 ? "清晨" : "深夜";
    localStorage.setItem(settingsKey, JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      habitEntries: [{ bucket, targetId: "light.study_desk", operationKey: "power:off", count: 3 }],
    }));
    new MenuMijiaWindowsApp(element("#app"));
    assert.equal((JSON.parse(localStorage.getItem(settingsKey) ?? "{}") as { habitShareEnabled?: boolean }).habitShareEnabled, false);
    await click("#btn-settings");
    const share = element("#settings-habit-share") as HTMLInputElement;
    assert.equal(share.checked, false);
    const sample = element("#settings-habit-share-sample") as HTMLInputElement;
    sample.value = "书房台灯";
    sample.dispatchEvent(new window.Event("input", { bubbles: true }));
    assert.equal(element("#settings-habit-share-preview").textContent, "不会发送习惯摘要");
    share.checked = true;
    share.dispatchEvent(new window.Event("change", { bubbles: true }));
    assert.match(element("#settings-habit-share-preview").textContent ?? "", /关闭书房台灯\(3次\)/);
    assert.equal((JSON.parse(localStorage.getItem(settingsKey) ?? "{}") as { habitShareEnabled?: boolean }).habitShareEnabled, false);
    await click("#btn-save-settings");
    assert.equal((JSON.parse(localStorage.getItem(settingsKey) ?? "{}") as { habitShareEnabled?: boolean }).habitShareEnabled, true);
  });

  it("applies device aliases to the habit-sharing preview", async () => {
    const hour = new Date().getHours();
    const bucket = hour >= 18 && hour < 23 ? "夜晚" : hour >= 14 && hour < 18 ? "下午" : hour >= 11 && hour < 14 ? "午间" : hour >= 6 && hour < 11 ? "清晨" : "深夜";
    localStorage.setItem(settingsKey, JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      habitEntries: [{ bucket, targetId: "light.study_desk", operationKey: "power:off", count: 3 }],
      layout: { aliases: { "light.study_desk": "阅读灯" } },
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await click("#btn-settings");
    const share = element("#settings-habit-share") as HTMLInputElement;
    share.checked = true;
    share.dispatchEvent(new window.Event("change", { bubbles: true }));
    const sample = element("#settings-habit-share-sample") as HTMLInputElement;
    sample.value = "阅读灯";
    sample.dispatchEvent(new window.Event("input", { bubbles: true }));
    assert.match(element("#settings-habit-share-preview").textContent ?? "", /关闭阅读灯\(3次\)/);
  });

  it("learns nothing when habit learning is disabled", async () => {
    localStorage.setItem(settingsKey, JSON.stringify({
      connectionMode: "demo",
      hasCompletedOnboarding: true,
      habitLearningEnabled: false,
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await click('[data-toggle-device="light.living_ceiling"]');
    await click('[data-scene-cmd="关闭所有灯"]');
    await setImmediate();
    assert.equal(habitEntries().length, 0);
  });

  it("records only the succeeded device intent when another target in a multi-device command fails", async () => {
    const snapshot = {
      areas: [{ area_id: "study", name: "书房" }],
      devices: [
        { id: "light_ok", name: "书房吸顶灯", area_id: "study", model: "test.light" },
        { id: "light_fail", name: "书房台灯", area_id: "study", model: "test.light" },
      ],
      entities: [
        { entity_id: "light.ok", device_id: "light_ok" },
        { entity_id: "light.fail", device_id: "light_fail" },
      ],
      states: [
        { entity_id: "light.ok", state: "on", attributes: {} },
        { entity_id: "light.fail", state: "on", attributes: {} },
      ],
    };
    const invoke = async (name: string, args: Record<string, unknown> = {}) => {
      if (name === "secure_store_get") return "controlled-token";
      if (name === "ha_snapshot") return structuredClone(snapshot);
      if (name === "ha_execute") {
        const cmd = args.command as { entity_id?: string } | undefined;
        if (cmd?.entity_id === "light.fail") throw new Error("Device unreachable");
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem(settingsKey, JSON.stringify({
      connectionMode: "homeAssistant",
      haBaseURL: "http://localhost:8123",
      hasCompletedOnboarding: true,
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await waitFor(() => !!document.querySelector('[data-body-device="light_ok"]'));
    await command("关闭所有灯");
    await waitFor(() => habitEntries().length > 0);
    assert.deepEqual(
      habitEntries().map((e) => [e.targetId, e.operationKey]),
      [["light_ok", "power:off"]],
    );
  });
});

describe("Scene habit learning (#113 review fix)", () => {
  const settingsKey = "menumijia.windows.settings.v2";

  function habitEntries(): Array<{ targetId: string; operationKey: string; count: number }> {
    const parsed = JSON.parse(localStorage.getItem(settingsKey) ?? "{}") as { habitEntries?: Array<{ targetId: string; operationKey: string; count: number }> };
    return parsed.habitEntries ?? [];
  }

  it("executes a typed scene command and records its habit", async () => {
    startDemo();
    await command("执行回家模式");
    await waitFor(() => habitEntries().length > 0);

    const entries = habitEntries();
    assert.deepEqual(entries.map((e) => [e.targetId, e.operationKey]), [["scene.home", "scene:activate"]]);
    assert.match(document.body.textContent ?? "", /已执行回家模式/);
  });
});

describe("Home Assistant source", () => {
  const fixture = JSON.parse(readFileSync("../Tests/Fixtures/ha_snapshot.json", "utf8"));
  function startHA(failedSnapshot = false, cached = failedSnapshot, token = "controlled-token"): { calls: string[]; failCommand: () => void } {
    const calls: string[] = [];
    let rejectCommand = false;
    const invoke = async (name: string) => {
      calls.push(name);
      if (name === "secure_store_get") return token;
      if (name === "ha_snapshot") {
        if (failedSnapshot) throw new Error("Home Assistant disconnected");
        return structuredClone(fixture);
      }
      if (name === "ha_execute" && rejectCommand) throw new Error("Home Assistant request failed");
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", {value:{invoke},configurable:true});
    localStorage.setItem("menumijia.windows.settings.v2",JSON.stringify({connectionMode:"homeAssistant",haBaseURL:"http://localhost:8123",hasCompletedOnboarding:true,cachedHAHome:cached ? {endpoint:"http://localhost:8123",identity:homeAssistantIdentity("http://localhost:8123","controlled-token"),home:HomeAssistantSynthesizer.synthesize(fixture)} : null}));
    new MenuMijiaWindowsApp(element("#app"));
    return {calls,failCommand:() => {rejectCommand = true;}};
  }
  it("patches remote light power changes and all-off availability while keeping focused card nodes", async () => {
    let isOn = false;
    let snapshots = 0;
    let effects: string[] = [];
    const invoke = async (name: string) => {
      if (name === "secure_store_get") return "controlled-token";
      if (name === "ha_snapshot") {
        snapshots += 1;
        const next = structuredClone(fixture);
        next.states[0].state = isOn ? "on" : "off";
        next.states[0].attributes.effect_list = effects;
        return next;
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({ connectionMode: "homeAssistant", haBaseURL: "http://localhost:8123", hasCompletedOnboarding: true }));
    new MenuMijiaWindowsApp(element("#app"));
    await waitFor(() => !!document.querySelector('[data-body-device="study-light"]'));
    await click('[data-expand-device="study-light"]');
    const card = element('[data-tile-id="study-light"]');
    const input = element('[data-brightness="study-light"]');
    const commandInput = element("#command-input");
    const scroll = element(".cc-scroll-area");
    const order = [...document.querySelectorAll<HTMLElement>("[data-tile-id]")].map((node) => node.dataset.tileId);
    scroll.scrollTop = 57;
    input.focus();
    assert.ok(!document.querySelector("#btn-all-off"));
    for (const power of [true, false, true]) {
      isOn = power;
      const before = snapshots;
      await click("#btn-refresh");
      await waitFor(() => snapshots === before + 1);
      assert.ok(element('[data-tile-id="study-light"]') === card, "Remote power must preserve the card node");
      assert.ok(element('[data-brightness="study-light"]') === input, "Remote power must preserve the slider node");
      assert.ok(element("#command-input") === commandInput);
      assert.ok(document.activeElement === input, "The focused slider must stay focused");
      assert.ok(element(".cc-scroll-area") === scroll);
      assert.equal(scroll.scrollTop, 57);
      assert.deepEqual([...document.querySelectorAll<HTMLElement>("[data-tile-id]")].map((node) => node.dataset.tileId), order);
      assert.equal(!!document.querySelector("#btn-all-off"), power);
      if (power) {
        assert.match(textOf("#btn-all-off"), /全关.*\(1\)/);
        assert.match(element("#btn-all-off").getAttribute("aria-label") ?? "", /1 台/);
      }
    }
    element("#btn-all-off").dispatchEvent(new window.MouseEvent("pointerup", { bubbles: true }));
    await setImmediate();
    assert.match(textOf(".cc-feedback-text"), /关闭这 1 台/);
    effects = ["Day", "Night"];
    await click("#btn-refresh");
    assert.ok(document.querySelector('[data-lighteffect="study-light"][data-effect="Night"]'), "A genuine capability update must create its new controls");
  });
  it("keeps focused thermostat controls when remote heating mode changes", async () => {
    let mode = "off";
    const snapshot = JSON.parse(readFileSync("../Tests/Fixtures/ha_regressions.json", "utf8"));
    const invoke = async (name: string) => {
      if (name === "secure_store_get") return "controlled-token";
      if (name === "ha_snapshot") {
        const next = structuredClone(snapshot);
        next.states[0].state = mode;
        return next;
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({ connectionMode: "homeAssistant", haBaseURL: "http://localhost:8123", hasCompletedOnboarding: true }));
    new MenuMijiaWindowsApp(element("#app"));
    await waitFor(() => !!document.querySelector('[data-tile-id="heat-only"]'));
    const card = element('[data-tile-id="heat-only"]');
    const power = element('.cc-climate-power[data-toggle-device="heat-only"]');
    const step = element('[data-acstep="heat-only:1"]');
    const commandInput = element("#command-input");
    const scroll = element(".cc-scroll-area");
    scroll.scrollTop = 41;
    step.focus();
    for (const nextMode of ["heat", "off", "heat"]) {
      mode = nextMode;
      await click("#btn-refresh");
      assert.ok(element('[data-tile-id="heat-only"]') === card, "A mode value change must preserve the thermostat card");
      assert.ok(element('.cc-climate-power[data-toggle-device="heat-only"]') === power);
      assert.ok(element('[data-acstep="heat-only:1"]') === step);
      assert.ok(element("#command-input") === commandInput);
      assert.ok(document.activeElement === step);
      assert.ok(element(".cc-scroll-area") === scroll);
      assert.equal(scroll.scrollTop, 41);
      assert.equal(power.getAttribute("aria-pressed"), String(mode === "heat"));
      assert.match(card.textContent ?? "", mode === "heat" ? /制热/ : /已关闭/);
    }
  });
  it("cleans old camera bearer URLs from current and legacy settings copies on startup and later writes", async () => {
    const snapshot = structuredClone(fixture);
    snapshot.states.push({ entity_id: "camera.front", state: "idle", attributes: { entity_picture: "/api/camera_proxy/camera.front?token=old-camera-bearer" } });
    const settings = { connectionMode: "demo", hasCompletedOnboarding: true, cachedHAHome: { identity: homeAssistantIdentity("http://localhost:8123", "account"), home: HomeAssistantSynthesizer.synthesize(snapshot) } };
    const credentialWrites: unknown[] = [];
    const invoke = async (name: string, args: Record<string, unknown> = {}) => {
      if (name === "secure_store_set") credentialWrites.push(args);
      return null;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    const keys = ["menumijia.windows.settings.v2", "menumijia.windows.settings.v1"];
    for (const key of keys) localStorage.setItem(key, JSON.stringify(settings));
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    for (const key of keys) assert.equal(localStorage.getItem(key)?.includes("old-camera-bearer"), false);
    await click("#btn-toggle-appearance");
    for (const key of keys) assert.equal(localStorage.getItem(key)?.includes("camera_proxy"), false);
    assert.deepEqual(credentialWrites, [], "An expiring camera URL does not belong in the credential vault");
  });
  for (const responseState of ["cached", "pending"]) {
    it(`isolates ${responseState} proactive recommendations across matching HA entity IDs`, async () => {
      const responses = new EventEmitter();
      const ticks: Array<() => void> = [];
      let modelRequests = 0;
      let oldResponseReturned = false;
      Object.defineProperty(window, "setInterval", { value: (handler: () => void) => { ticks.push(handler); return ticks.length; }, configurable: true });
      const invoke = async (name: string, args: Record<string, unknown> = {}) => {
        if (name === "secure_store_get") return args.name === "ha_token" ? "controlled-token" : null;
        if (name === "ha_snapshot") {
          const source = String(args.baseUrl).endsWith("8124") ? "B" : "A";
          return { areas: [], devices: [], entities: [], states: [{ entity_id: "light.study", state: "on", attributes: { friendly_name: `Source ${source} lamp` } }] };
        }
        if (name === "native_http") {
          const request = ++modelRequests;
          if (request === 1 && responseState === "pending") await once(responses, "old");
          if (request === 2) await once(responses, "current");
          if (request === 1) oldResponseReturned = true;
          const content = JSON.stringify({ suggestions: [{ device: "d1", op: "power", value: false, confidence: 0.9 }] });
          return { status: 200, headers: {}, body: JSON.stringify({ choices: [{ message: { content } }] }) };
        }
        return undefined;
      };
      Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
      localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({ connectionMode: "homeAssistant", haBaseURL: "http://localhost:8123", hasCompletedOnboarding: true, enableGrokBall: true, assistantBaseURL: "http://localhost:1234/v1", assistantModel: "controlled-model" }));
      new MenuMijiaWindowsApp(element("#app"));
      await waitFor(() => !!document.querySelector('[data-tile-id="light.study"]'));
      await click("#btn-grok-ball");
      for (const tick of ticks) tick();
      await waitFor(() => modelRequests === 1);
      if (responseState === "cached") await waitFor(() => !!document.querySelector('[data-proactive-id^="chat:"]'));
      await click("#btn-settings");
      const url = document.querySelector<HTMLInputElement>("#settings-ha-url");
      assert.ok(url);
      url.value = "http://localhost:8124";
      await click("#btn-save-settings");
      await waitFor(() => tile("light.study").includes("Source B lamp"));
      if (!document.querySelector(".cc-grok-stage")) await click("#btn-grok-ball");
      assert.doesNotMatch(document.body.textContent ?? "", /Source A lamp/);
      for (const tick of ticks) tick();
      await setImmediate();
      assert.equal(modelRequests, 2, "The new source must start its own recommendation request");
      if (responseState === "pending") {
        responses.emit("old");
        await waitFor(() => oldResponseReturned);
        await setImmediate();
        assert.doesNotMatch(document.body.textContent ?? "", /Source A lamp/);
        for (const tick of ticks) tick();
        assert.equal(modelRequests, 2, "A stale completion must not unlock the current in-flight request");
      }
      responses.emit("current");
      await waitFor(() => !!document.querySelector('[data-proactive-id^="chat:"]'));
      assert.match(textOf('[data-proactive-id^="chat:"]'), /Source B lamp/);
      assert.doesNotMatch(document.body.textContent ?? "", /Source A lamp/);
    });
  }
  for (const outcome of ["action", "suggestion", "error", "same-source", "same-source-suggestion", "same-source-error"] as const) {
    it(`binds a held model ${outcome} to its initiating HA source`, async () => {
      const modelResponse = new EventEmitter();
      let modelStarted = false;
      let modelReturned = false;
      const calls: Array<Record<string, unknown>> = [];
      const invoke = async (name: string, args: Record<string, unknown> = {}) => {
        if (name === "secure_store_get") return args.name === "ha_token" ? "account-a" : null;
        if (name === "ha_snapshot") {
          const snapshot = structuredClone(fixture);
          snapshot.states.push({ entity_id: "camera.front", state: "idle", attributes: { friendly_name: "Front camera" } });
          return snapshot;
        }
        if (name === "ha_execute") calls.push(args);
        if (name === "native_http") {
          if (!String(args.body).includes("让这里适合观星")) return { status: 200, headers: {}, body: JSON.stringify({ choices: [{ message: { content: '{"suggestions":[]}' } }] }) };
          modelStarted = true;
          await once(modelResponse, "release");
          modelReturned = true;
          if (outcome.endsWith("error")) throw new Error("Late account A error");
          const content = JSON.stringify({ actions: [{ device: outcome.endsWith("suggestion") ? "camera.front" : "d1", op: "power", value: false }], reply: "Account A model reply" });
          return { status: 200, headers: {}, body: JSON.stringify({ choices: [{ message: { content } }] }) };
        }
        return undefined;
      };
      Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
      localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({ connectionMode: "homeAssistant", haBaseURL: "http://localhost:8123", hasCompletedOnboarding: true, enableGrokBall: true, assistantBaseURL: "http://localhost:1234/v1", assistantModel: "controlled-model" }));
      new MenuMijiaWindowsApp(element("#app"));
      await waitFor(() => !!document.querySelector('[data-body-device="study-light"]'));
      await command("让这里适合观星");
      await waitFor(() => modelStarted);
      if (!outcome.startsWith("same-source")) {
        await click("#btn-settings");
        const url = document.querySelector<HTMLInputElement>("#settings-ha-url");
        assert.ok(url);
        url.value = "http://localhost:8124";
        await click("#btn-save-settings");
        await waitFor(() => !!document.querySelector('[data-body-device="study-light"]'));
      }
      const before = localStorage.getItem("menumijia.windows.settings.v2");
      const bannerBefore = document.querySelector(".cc-feedback-text")?.textContent;
      modelResponse.emit("release");
      await waitFor(() => modelReturned);
      await setImmediate();
      if (outcome === "same-source") {
        assert.equal(calls.length, 1);
        assert.match(tile("study-light"), /已关闭/);
        assert.ok(document.querySelector("#btn-undo"));
        const saved = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}");
        assert.equal(saved.learnedShortcuts.length, 1);
      } else if (outcome === "same-source-suggestion") {
        assert.equal(calls.length, 0);
        assert.ok(document.querySelector("[data-suggestion-id]"), "A current model suggestion must remain available");
      } else if (outcome === "same-source-error") {
        assert.equal(calls.length, 0);
        assert.match(textOf(".cc-feedback-text"), /Late account A error/);
      } else {
        assert.equal(calls.length, 0, "An account A model response must never control account B's matching entity ID");
        assert.ok(!document.querySelector("#btn-undo"), "A stale response must not install undo");
        assert.ok(!document.querySelector("[data-suggestion-id]"), "A stale response must not publish suggestions");
        assert.equal(localStorage.getItem("menumijia.windows.settings.v2"), before, "Late replies must not save learning or habit receipts");
        assert.equal(document.querySelector(".cc-feedback-text")?.textContent, bannerBefore);
        assert.doesNotMatch(document.body.textContent ?? "", /Account A model reply|Late account A error/);
      }
    });
  }
  it("uses heat-only capability for card power and same-source undo", async () => {
    const snapshot = JSON.parse(readFileSync("../Tests/Fixtures/ha_regressions.json", "utf8"));
    const modes: unknown[] = [];
    const invoke = async (name: string, args: Record<string, unknown> = {}) => {
      if (name === "secure_store_get") return "controlled-token";
      if (name === "ha_snapshot") return snapshot;
      if (name === "ha_execute") {
        const call = args.command;
        assert.ok(call && typeof call === "object" && "data" in call);
        const data = call.data;
        assert.ok(data && typeof data === "object" && "hvac_mode" in data);
        modes.push(data.hvac_mode);
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({ connectionMode: "homeAssistant", haBaseURL: "http://localhost:8123", hasCompletedOnboarding: true }));
    new MenuMijiaWindowsApp(element("#app"));
    await waitFor(() => !!document.querySelector('[data-toggle-device="heat-only"]'));
    await click('[data-toggle-device="heat-only"]');
    assert.deepEqual(modes, ["heat"]);
    await click('[data-toggle-device="heat-only"]');
    await click("#btn-undo");
    assert.deepEqual(modes, ["heat", "off", "heat"]);
  });
  it("retains cached cards and clears the independent HA error on reconnect", async () => {
    let failing = true;
    const invoke = async (name: string) => {
      if (name === "secure_store_get") return "controlled-token";
      if (name === "ha_snapshot") {
        if (failing) throw new Error("Connection lost");
        return fixture;
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({ connectionMode: "homeAssistant", haBaseURL: "http://localhost:8123", hasCompletedOnboarding: true, cachedHAHome: { identity: homeAssistantIdentity("http://localhost:8123", "controlled-token"), home: HomeAssistantSynthesizer.synthesize(fixture) } }));
    new MenuMijiaWindowsApp(element("#app"));
    await waitFor(() => !!document.querySelector("[data-ha-error]"));
    await click("#btn-toggle-assistant");
    assert.match(textOf("[data-ha-error]"), /Connection lost/);
    assert.match(tile("study-light"), /书房灯/);
    failing = false;
    await click("#btn-refresh");
    await waitFor(() => !document.querySelector("[data-ha-error]"));
    assert.match(tile("study-light"), /书房灯/);
    assert.equal(document.querySelector("#command-input"), null);
  });
  it("rejects malformed cached HA homes and refreshes into an empty state", async () => {
    let snapshots = 0;
    const invoke = async (name: string) => {
      if (name === "secure_store_get") return "controlled-token";
      if (name === "ha_snapshot") { snapshots += 1; return structuredClone(fixture); }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({ connectionMode: "homeAssistant", haBaseURL: "http://localhost:8123", hasCompletedOnboarding: true, cachedHAHome: { identity: homeAssistantIdentity("http://localhost:8123", "controlled-token"), home: { devices: {}, rooms: [], environmentReadings: [], scenes: [] } } }));
    new MenuMijiaWindowsApp(element("#app"));
    await waitFor(() => !!document.querySelector('[data-body-device="study-light"]'));
    assert.equal(snapshots, 1);
  });
  for (const delayed of [false, true]) {
    it(`discards ${delayed ? "in-flight" : "completed"} undo and habit writes after an HA account change`, async () => {
      const calls: Array<Record<string, unknown>> = [];
      let finish: () => void = () => {};
      const invoke = async (name: string, args: Record<string, unknown> = {}) => {
        if (name === "secure_store_get") return "account-a";
        if (name === "ha_snapshot") return structuredClone(fixture);
        if (name === "ha_execute") {
          calls.push(args);
          if (delayed) await new Promise<void>((resolve) => { finish = resolve; });
        }
        return undefined;
      };
      Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
      localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({ connectionMode: "homeAssistant", haBaseURL: "http://localhost:8123", hasCompletedOnboarding: true }));
      new MenuMijiaWindowsApp(element("#app"));
      await waitFor(() => !!document.querySelector('[data-body-device="study-light"]'));
      await command("关闭书房灯");
      await waitFor(() => calls.length === 1);
      await click("#btn-settings");
      const token = document.querySelector<HTMLInputElement>("#settings-ha-token");
      assert.ok(token);
      token.value = "account-b";
      await click("#btn-save-settings");
      if (delayed) { finish(); await setImmediate(); }
      await waitFor(() => !!document.querySelector('[data-body-device="study-light"]'));
      const before = localStorage.getItem("menumijia.windows.settings.v2");
      await command("撤销");
      assert.equal(calls.length, 1, "Undo must not send account A's inverse to account B");
      assert.equal(localStorage.getItem("menumijia.windows.settings.v2"), before, "Undo must not unrecord another source's habits");
      if (delayed) {
        const stored = JSON.parse(before ?? "{}");
        assert.deepEqual(stored.habitEntries, []);
      }
    });
  }
  it("connects without Xiaomi requests and keeps credentials out of settings", async () => {
    const {calls} = startHA();
    await waitFor(() => !!document.querySelector('[data-body-device="study-light"]'));
    assert.match(tile("study-light"), /书房灯/);
    assert.equal(calls.filter((call) => call === "ha_snapshot").length,1);
    assert.equal(calls.includes("native_http"),false);
    assert.equal(localStorage.getItem("menumijia.windows.settings.v2")?.includes("controlled-token"),false);
    assert.match(textOf('[data-ha-scene="scene.evening"]'), /晚安/);
    await click('[data-ha-scene="scene.evening"]');
    assert.ok(calls.includes("ha_execute"));
  });
  it("retains cached cards when a refresh fails", async () => {
    startHA(true);
    await waitFor(() => (document.body.textContent ?? "").includes("Home Assistant disconnected"));
    assert.match(tile("study-light"), /书房灯/);
  });
  it("shows HA refresh errors outside the hidden assistant bar", async () => {
    startHA(true);
    await click("#btn-toggle-assistant");
    await waitFor(() => !!document.querySelector("[data-ha-error]"));
    assert.match(textOf("[data-ha-error]"), /Home Assistant disconnected/);
  });
  it("keeps the confirmed light state after a failed service", async () => {
    const state = startHA();
    await waitFor(() => !!document.querySelector('[data-body-device="study-light"]'));
    state.failCommand();
    await command("关闭书房灯");
    await waitFor(() => (document.body.textContent ?? "").includes("Home Assistant request failed"));
    assert.ok(state.calls.includes("ha_execute"));
    assert.match(tile("study-light"), /开启|50%|50 %/);
  });
  it("shows an empty HA home on initial failure without demo fallback", async () => {
    startHA(true, false);
    await waitFor(() => (document.body.textContent ?? "").includes("Home Assistant disconnected"));
    assert.equal(document.querySelectorAll("[data-body-device]").length,0);
  });
  it("does not show a previous account cache under a different token", async () => {
    startHA(true, true, "different-account-token");
    await waitFor(() => (document.body.textContent ?? "").includes("Home Assistant disconnected"));
    assert.equal(document.querySelectorAll("[data-body-device]").length,0);
  });
  it("does not apply an old HA snapshot after switching to demo", async () => {
    let complete: (value: unknown) => void = () => assert.fail("Snapshot has not started");
    let snapshots = 0;
    const invoke = async (name: string) => {
      if (name === "secure_store_get") return "controlled-token";
      if (name === "ha_snapshot") { snapshots += 1; return new Promise((resolve) => {complete = resolve;}); }
      return undefined;
    };
    Object.defineProperty(window,"__TAURI_INTERNALS__",{value:{invoke},configurable:true});
    localStorage.setItem("menumijia.windows.settings.v2",JSON.stringify({connectionMode:"homeAssistant",haBaseURL:"http://localhost:8123",hasCompletedOnboarding:true}));
    new MenuMijiaWindowsApp(element("#app"));
    await waitFor(() => snapshots === 1);
    await click("#btn-refresh");
    assert.equal(snapshots,1);
    await click("#btn-settings");
    await click('[data-conn-mode="demo"]');
    complete(fixture);
    await setImmediate();
    await click("#btn-close-settings");
    assert.equal(document.querySelector('[data-body-device="study-light"]'),null);
    assert.ok(document.querySelector('[data-body-device="light.living_ceiling"]'));
    assert.equal(snapshots,1);
  });
  it("patches HA value-only refreshes without replacing focused controls", async () => {
    let snapshots = 0;
    const invoke = async (name: string) => {
      if (name === "secure_store_get") return "controlled-token";
      if (name === "ha_snapshot") {
        snapshots += 1;
        const next = structuredClone(fixture);
        if (snapshots > 1) next.states[0].attributes.brightness = 200;
        return next;
      }
      return undefined;
    };
    Object.defineProperty(window,"__TAURI_INTERNALS__",{value:{invoke},configurable:true});
    localStorage.setItem("menumijia.windows.settings.v2",JSON.stringify({connectionMode:"homeAssistant",haBaseURL:"http://localhost:8123",hasCompletedOnboarding:true}));
    new MenuMijiaWindowsApp(element("#app"));
    await waitFor(() => !!document.querySelector('[data-body-device="study-light"]'));
    const input = element("#command-input");
    input.focus();
    const card = element('[data-body-device="study-light"]');
    await click("#btn-refresh");
    assert.equal(snapshots,2);
    assert.equal(element('[data-body-device="study-light"]'),card);
    assert.equal(document.activeElement,input);
    assert.match(tile("study-light"),/78%|78 %/);
  });

  it("treats a momentary button card press as an accepted action", async () => {
    const executed: Array<Record<string, unknown>> = [];
    const invoke = async (name: string, args: Record<string, unknown> = {}) => {
      if (name === "secure_store_get") return "controlled-token";
      if (name === "ha_snapshot") {
        const next = structuredClone(fixture);
        next.devices.push({ id: "wol-pc", area_id: "study", name: "书房台式机", model: "Wake on LAN", disabled_by: null });
        next.entities.push({ entity_id: "button.wake_on_lan_pc", device_id: "wol-pc", area_id: "study", disabled_by: null, hidden_by: null, entity_category: null });
        next.states.push({ entity_id: "button.wake_on_lan_pc", state: "unknown", attributes: { friendly_name: "书房台式机" } });
        return next;
      }
      if (name === "ha_execute") {
        executed.push(args);
        return undefined;
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "homeAssistant",
      haBaseURL: "http://localhost:8123",
      hasCompletedOnboarding: true,
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await waitFor(() => !!document.querySelector('[data-toggle-device="wol-pc"]'));
    await click('[data-toggle-device="wol-pc"]');
    assert.equal(executed.length, 1);
    assert.equal((executed[0]?.command as { service?: string })?.service, "press");
    assert.match(element(".cc-feedback-text").textContent ?? "", /已打开书房台式机/);
  });

  it("preserves restorable light undo when a batch also activates a momentary button.*", async () => {
    const executed: Array<Record<string, unknown>> = [];
    const invoke = async (name: string, args: Record<string, unknown> = {}) => {
      if (name === "secure_store_get") return "controlled-token";
      if (name === "ha_snapshot") {
        const next = structuredClone(fixture);
        next.devices.push({ id: "wol-pc", area_id: "study", name: "书房台式机", model: "Wake on LAN", disabled_by: null });
        next.entities.push({ entity_id: "button.wake_on_lan_pc", device_id: "wol-pc", area_id: "study", disabled_by: null, hidden_by: null, entity_category: null });
        next.states.push({ entity_id: "button.wake_on_lan_pc", state: "unknown", attributes: { friendly_name: "书房台式机" } });
        return next;
      }
      if (name === "ha_execute") {
        executed.push(args);
        return undefined;
      }
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "homeAssistant",
      haBaseURL: "http://localhost:8123",
      hasCompletedOnboarding: true,
      learnedShortcuts: [
        {
          phrase: "开启办公",
          reply: "已唤醒电脑并关闭书房灯",
          intents: [
            { targetId: "wol-pc", operation: { kind: "power", isOn: true } },
            { targetId: "study-light", operation: { kind: "power", isOn: false } },
          ],
        },
      ],
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await waitFor(() => !!document.querySelector('[data-body-device="study-light"]'));
    await command("开启办公");
    assert.equal(executed.length, 2);
    assert.ok(document.querySelector("#btn-undo"), "batch with button.* and light should keep undo for the light");
    await click("#btn-undo");
    assert.equal(executed.length, 3);
    assert.equal((executed[2]?.command as { service?: string })?.service, "turn_on");
  });
});

describe("GrokBall side attachment (#114)", () => {
  it("stays hidden by default and opens four side actions when enabled", async () => {
    startDemo();
    assert.equal(document.querySelector("#btn-grok-ball"), null);

    await click("#btn-settings");
    const toggle = element("#settings-grok-ball") as HTMLInputElement;
    assert.equal(toggle.checked, false);
    toggle.checked = true;
    toggle.dispatchEvent(new Event("change", { bubbles: true }));
    await setImmediate();
    await click("#btn-close-settings");

    await click("#btn-grok-ball");
    assert.equal(document.querySelectorAll(".cc-grok-sidebar [data-proactive-id]").length, 4);
    await click(".cc-grok-pill");
    await waitFor(() => document.querySelector("#btn-undo") !== null);
    assert.equal(document.querySelector(".cc-grok-stage"), null);
    assert.equal(element(".cc-grok-ball").dataset.emotion, "33");
    await click("#btn-undo");
    await click("#btn-grok-ball");
    dom.dispatchEvent(new dom.KeyboardEvent("keydown", { key: "Escape" }));
    assert.equal(document.querySelector(".cc-grok-stage"), null);
  });

  it("keeps learned scenes outside the reversible side attachment", async () => {
    localStorage.setItem(["menumijia", "windows", "settings", "v2"].join("."), JSON.stringify({
      connectionMode: "demo", hasCompletedOnboarding: true, enableGrokBall: true,
      habitEntries: [{ bucket: "深夜", targetId: "scene.home", operationKey: "scene:activate", count: 99 }],
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await click("#btn-grok-ball");
    assert.equal(document.querySelector('[data-proactive-id*="scene.home"]'), null);
    assert.equal(document.querySelectorAll(".cc-grok-pill").length, 4);
  });

  it("shows emotion 34 on the ball when a Home Assistant refresh fails", async () => {
    const invoke = async (name: string) => {
      if (name === "secure_store_get") return "controlled-token";
      if (name === "ha_snapshot") throw new Error("Home Assistant unreachable");
      return undefined;
    };
    Object.defineProperty(window, "__TAURI_INTERNALS__", { value: { invoke }, configurable: true });
    localStorage.setItem(["menumijia", "windows", "settings", "v2"].join("."), JSON.stringify({
      connectionMode: "homeAssistant", haBaseURL: "http://localhost:8123", hasCompletedOnboarding: true, enableGrokBall: true,
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await waitFor(() => !!document.querySelector("[data-ha-error]"));
    assert.equal(element(".cc-grok-ball").dataset.emotion, "34");
  });
});

describe("只显示在线设备 (#158)", () => {
  function light(id: string, room: string, isOnline: boolean): SmartDevice {
    return {
      id,
      name: id,
      roomId: room,
      roomName: room,
      model: "yeelink.light.ceiling22",
      isOnline,
      kind: {
        kind: "light",
        entityId: `miot:${id}:2`,
        isOn: true,
        brightnessPercent: 50,
        colorTempKelvin: 4000,
        minKelvin: 2700,
        maxKelvin: 6500,
        currentEffect: null,
        availableEffects: [],
      },
    };
  }

  function tileIds(): string[] {
    return Array.from(document.querySelectorAll<HTMLElement>("[data-tile-id]"), (node) => node.dataset.tileId ?? "").sort();
  }

  function startCached(extra: Record<string, unknown> = {}): void {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "xiaomiCloud",
      hasCompletedOnboarding: true,
      cachedXiaomiDevices: [
        light("online-living", "客厅", true),
        light("offline-living", "客厅", false),
        light("offline-study", "书房", false),
      ],
      ...extra,
    }));
    new MenuMijiaWindowsApp(element("#app"));
  }

  it("stays off by default, hides offline cards and 全关 targets, and survives a restart", async () => {
    startCached();
    const toggle = element("#btn-toggle-hide-offline");
    assert.equal(element("#btn-toggle-grid").nextElementSibling, toggle);
    assert.equal(toggle.getAttribute("aria-label"), "只显示在线设备");
    assert.equal(toggle.getAttribute("aria-pressed"), "false");
    assert.equal(toggle.getAttribute("title"), "点击隐藏未通电/离线设备");
    assert.deepEqual(tileIds(), ["offline-living", "offline-study", "online-living"]);
    assert.match(element("#btn-all-off").textContent ?? "", /全关 \(3\)/);

    await click("#btn-toggle-hide-offline");
    const enabled = element("#btn-toggle-hide-offline");
    assert.equal(enabled.getAttribute("aria-pressed"), "true");
    assert.equal(enabled.classList.contains("is-selected"), true);
    assert.equal(enabled.getAttribute("title"), "当前只显示在线设备（点击显示全部）");
    assert.deepEqual(tileIds(), ["online-living"]);
    assert.match(element("#btn-all-off").textContent ?? "", /全关 \(1\)/);
    const stored = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as { hideOfflineDevices?: boolean };
    assert.equal(stored.hideOfflineDevices, true);

    document.body.innerHTML = '<div id="app"></div>';
    new MenuMijiaWindowsApp(element("#app"));
    assert.equal(element("#btn-toggle-hide-offline").getAttribute("aria-pressed"), "true");
    assert.deepEqual(tileIds(), ["online-living"]);

    await click("#btn-toggle-hide-offline");
    assert.deepEqual(tileIds(), ["offline-living", "offline-study", "online-living"]);
    const cleared = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as { hideOfflineDevices?: boolean };
    assert.equal(cleared.hideOfflineDevices, false);
  });

  it("offers 显示离线设备 when the selected room has no online device", async () => {
    startCached({ hideOfflineDevices: true });
    await click('[data-room="书房"]');
    assert.deepEqual(tileIds(), []);
    assert.equal(element(".cc-empty-title").textContent, "该房间暂无通电在线的设备");
    await click("#btn-show-offline");
    assert.deepEqual(tileIds(), ["offline-study"]);
    assert.equal(element("#btn-toggle-hide-offline").getAttribute("aria-pressed"), "false");
    const stored = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as { hideOfflineDevices?: boolean };
    assert.equal(stored.hideOfflineDevices, false);
  });

  it("follows the settings checkbox and the macOS English copy", async () => {
    startCached({ interfaceLanguage: "en" });
    const toggle = element("#btn-toggle-hide-offline");
    assert.equal(toggle.getAttribute("aria-label"), "Show online devices only");
    assert.equal(toggle.getAttribute("title"), "Hide offline/unplugged devices");

    await click("#btn-settings");
    const box = document.querySelector<HTMLInputElement>("#settings-hide-offline");
    assert.ok(box);
    assert.equal(element("label[for='settings-hide-offline']").textContent, "Hide Offline / Unpowered Devices");
    assert.equal(box.checked, false);
    box.checked = true;
    box.dispatchEvent(new Event("change", { bubbles: true }));
    await setImmediate();
    assert.deepEqual(tileIds(), ["online-living"]);
    assert.equal(element("#btn-toggle-hide-offline").getAttribute("title"), "Showing online devices only (click to show all)");

    await click('[data-room="书房"]');
    assert.equal(element("#btn-show-offline").textContent, "Show Offline Devices");
    assert.equal(element(".cc-empty-title").textContent, "No online devices in this room");
  });

  it("treats a non-boolean stored value as off", () => {
    startCached({ hideOfflineDevices: "yes" });
    assert.equal(element("#btn-toggle-hide-offline").getAttribute("aria-pressed"), "false");
    assert.deepEqual(tileIds(), ["offline-living", "offline-study", "online-living"]);
  });
});

describe("device kind filter", () => {
  function tileIds(): string[] {
    return Array.from(document.querySelectorAll<HTMLElement>("[data-tile-id]"), (node) => node.dataset.tileId ?? "");
  }

  it("shows only lights across rooms, then a room pill clears the kind", async () => {
    startDemo();
    await setImmediate();
    const before = Object.keys(JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}")).sort();

    await click('[data-kind="light"]');
    assert.deepEqual(tileIds().sort(), ["light.living_ceiling", "light.study_desk"]);
    assert.match(element('[data-tile-id="light.living_ceiling"] .cc-tile-status').textContent ?? "", /客厅/);
    assert.equal(element('[data-room="全部"]').getAttribute("aria-pressed"), "false");
    assert.equal(element('[data-room="全部"]').classList.contains("is-active"), false);

    await click('[data-room="全部"]');
    assert.ok(tileIds().includes("climate.living_ac"));
    assert.ok(tileIds().includes("fan.bedroom_standing"));
    assert.equal(element('[data-kind="light"]').getAttribute("aria-pressed"), "false");

    await click('[data-kind="light"]');
    await click('[data-room="客厅"]');
    assert.ok(tileIds().includes("climate.living_ac"));
    assert.ok(tileIds().includes("light.living_ceiling"));
    assert.ok(!tileIds().includes("light.study_desk"));
    assert.equal(element('[data-kind="light"]').getAttribute("aria-pressed"), "false");
    assert.equal(element('[data-room="客厅"]').getAttribute("aria-pressed"), "true");

    const stored = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as Record<string, unknown>;
    assert.deepEqual(Object.keys(stored).sort(), before);
    assert.equal("listCut" in stored, false);
    assert.equal(JSON.stringify(stored).includes("deviceKind"), false);
  });
});

describe("light-group folding (#214)", () => {
  const groupDid = "group.living";
  const memberA = "470498069";
  const memberB = "470498070";

  interface GroupOptions {
    readonly groupOnline?: boolean;
    readonly groupRoom?: string;
    readonly memberRoom?: string;
    readonly membership?: Record<string, string>;
    readonly hideOffline?: boolean;
    readonly hideGrouped?: boolean;
    readonly intents?: Parameters<typeof cloudFixture>[0];
  }

  function tileIds(): string[] {
    return Array.from(document.querySelectorAll<HTMLElement>("[data-tile-id]"), (node) => node.dataset.tileId ?? "").sort();
  }

  function roomNames(): string[] {
    return Array.from(document.querySelectorAll<HTMLElement>("[data-room]"), (node) => node.dataset.room ?? "");
  }

  function cachedLight(id: string, roomName: string): SmartDevice {
    return {
      id,
      name: id,
      roomId: roomName,
      roomName,
      model: "yeelink.light.ceiling22",
      isOnline: true,
      kind: {
        kind: "light",
        entityId: `miot:${id}:2`,
        isOn: true,
        brightnessPercent: 50,
        colorTempKelvin: 4000,
        minKelvin: 2700,
        maxKelvin: 6500,
        currentEffect: null,
        availableEffects: [],
      },
    };
  }

  async function readyGroupApp(options: GroupOptions = {}): Promise<ReturnType<typeof cloudFixture>> {
    const cloud = cloudFixture(options.intents ?? []);
    const model = cloud.deviceRecords[0]!.model;
    const specType = cloud.deviceRecords[0]!.spec_type;
    const record = (did: string, name: string, isOnline = true) => ({ did, name, model, isOnline, spec_type: specType });
    const groupRoom = options.groupRoom ?? "客厅";
    const memberRoom = options.memberRoom ?? "客厅";
    cloud.deviceRecords.push(
      record(groupDid, "客厅灯组", options.groupOnline ?? true),
      record(memberA, "客厅主灯"),
      record(memberB, "客厅射灯"),
    );
    for (const roomName of new Set([groupRoom, memberRoom])) {
      cloud.roomRecords.push({
        id: `room-${roomName}`,
        name: roomName,
        dids: [
          ...(groupRoom === roomName ? [groupDid] : []),
          ...(memberRoom === roomName ? [memberA, memberB] : []),
        ],
      });
    }
    cloud.groupMembers.set(groupDid, options.membership ?? { [memberA]: "1", [memberB]: "1" });
    const stored = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as Record<string, unknown>;
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      ...stored,
      hideOfflineDevices: options.hideOffline ?? false,
      hideGroupedLights: options.hideGrouped ?? true,
    }));
    new MenuMijiaWindowsApp(element("#app"));
    for (let i = 0; i < 3; i++) await setImmediate();
    await waitFor(() => !document.querySelector("#btn-refresh")?.classList.contains("is-spinning"));
    await setImmediate();
    return cloud;
  }

  it("folds grouped lights by default while all-off and voice keep the full collection", async () => {
    const cloud = await readyGroupApp({
      intents: [{ targetId: memberA, operation: { kind: "power", isOn: false } }],
    });
    assert.deepEqual(tileIds(), ["fixture-light", groupDid].sort());
    assert.match(element("#btn-all-off").textContent ?? "", /全关 \(4\)/);

    await click("#btn-settings");
    const box = document.querySelector<HTMLInputElement>("#settings-hide-grouped-lights");
    assert.ok(box);
    assert.equal(box.checked, true);
    assert.equal(element("label[for='settings-hide-grouped-lights']").textContent, "灯组内的单灯不重复显示");
    await click("#btn-close-settings");

    await command("部分失败");
    await waitFor(() => cloud.writes.some((write) => write.did === memberA && write.piid === 1 && write.value === false));
  });

  it("restores every individual light when the preference is turned off and saves it", async () => {
    await readyGroupApp();
    await click("#btn-settings");
    const box = document.querySelector<HTMLInputElement>("#settings-hide-grouped-lights");
    assert.ok(box);
    box.checked = false;
    box.dispatchEvent(new Event("change", { bubbles: true }));
    await setImmediate();
    assert.deepEqual(tileIds(), [memberA, memberB, "fixture-light", groupDid].sort());
    const stored = JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as {
      hideGroupedLights?: boolean;
    };
    assert.equal(stored.hideGroupedLights, false);

    const folded = document.querySelector<HTMLInputElement>("#settings-hide-grouped-lights");
    assert.ok(folded);
    folded.checked = true;
    folded.dispatchEvent(new Event("change", { bubbles: true }));
    await setImmediate();
    assert.deepEqual(tileIds(), ["fixture-light", groupDid].sort());
    assert.equal(
      (JSON.parse(localStorage.getItem("menumijia.windows.settings.v2") ?? "{}") as { hideGroupedLights?: boolean })
        .hideGroupedLights,
      true,
    );
  });

  it("restores the saved preference on the next launch", async () => {
    await readyGroupApp({ hideGrouped: false });
    assert.deepEqual(tileIds(), [memberA, memberB, "fixture-light", groupDid].sort());
    await click("#btn-settings");
    assert.equal(document.querySelector<HTMLInputElement>("#settings-hide-grouped-lights")?.checked, false);
  });

  it("keeps members visible when the group card is offline-hidden", async () => {
    await readyGroupApp({ groupOnline: false, hideOffline: true });
    assert.deepEqual(tileIds(), [memberA, memberB, "fixture-light"].sort());
    await click("#btn-toggle-hide-offline");
    assert.deepEqual(tileIds(), ["fixture-light", groupDid].sort());
  });

  it("keeps room navigation on rooms whose group card is filtered out", async () => {
    await readyGroupApp({ groupRoom: "客厅", memberRoom: "书房" });
    assert.deepEqual(tileIds(), ["fixture-light", groupDid].sort());
    assert.ok(roomNames().includes("书房"));
    await click('[data-room="书房"]');
    assert.deepEqual(tileIds(), [memberA, memberB].sort());
    for (const room of roomNames()) {
      await click(`[data-room="${room}"]`);
      assert.ok(tileIds().length > 0, `${room} pointed at an empty page`);
    }
  });

  it("reconciles membership on refresh instead of keeping stale fold mappings", async () => {
    const cloud = await readyGroupApp();
    assert.ok(!tileIds().includes(memberB));
    cloud.groupMembers.set(groupDid, { [memberA]: "1" });
    await click("#btn-refresh");
    await waitFor(() => tileIds().includes(memberB));
  });

  it("shows every member when the membership request is unavailable", async () => {
    const cloud = await readyGroupApp();
    assert.ok(!tileIds().includes(memberB));
    cloud.failNextGroupStatus();
    await click("#btn-refresh");
    await waitFor(() => tileIds().includes(memberB));
  });

  it("restores an existing device cache without hiding unknown members", async () => {
    localStorage.setItem("menumijia.windows.settings.v2", JSON.stringify({
      connectionMode: "xiaomiCloud",
      hasCompletedOnboarding: true,
      cachedXiaomiDevices: [
        cachedLight(groupDid, "客厅"),
        cachedLight(memberA, "客厅"),
        cachedLight(memberB, "客厅"),
      ],
    }));
    new MenuMijiaWindowsApp(element("#app"));
    await setImmediate();
    assert.deepEqual(tileIds(), [groupDid, memberA, memberB].sort());
  });
});
