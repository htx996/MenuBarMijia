import { ASSISTANT_PROVIDER_PRESETS, inferAssistantPreset } from "../core/assistant.js";
import { t } from "../core/i18n.js";
import type { GitHubRelease } from "../core/updateChecker.js";
import { isNewerVersion } from "../core/updateChecker.js";
import type { QRLoginTicket } from "../core/miCloudClient.js";
import {
  MI_CLOUD_REGIONS,
  maskedMiUserId,
  miCloudRegionLabel,
  normalizeMiCloudRegion,
} from "../core/miCloudClient.js";
import { joinsAllOff, type SmartDevice } from "../core/models.js";
import {
  APPEARANCES,
  DEFAULT_GLOBAL_SHORTCUT,
  PANEL_ANCHORS,
  PANEL_HEIGHTS,
  SKINS,
  type PanelAnchor,
} from "./panelPrefs.js";
import type { PersistedSettings } from "./appTypes.js";
import { APP_VERSION, SF_ICONS } from "./appConstants.js";
import type { HabitSequenceEntry } from "../core/assistant.js";

export interface SettingsViewContext {
  readonly settings: PersistedSettings;
  readonly devices: readonly SmartDevice[];
  readonly availableUpdate: GitHubRelease | null;
  readonly apiKeyFor: (baseURL: string) => string;
  readonly habitSequences: () => readonly HabitSequenceEntry[];
  readonly hotkeyNeedsHint: boolean;
  readonly hotkeyRegistrationError: string | null;
  readonly isPollingQR: boolean;
  readonly isRecordingHotkey: boolean;
  readonly panelAnchor: PanelAnchor;
  readonly qrStatusText: string;
  readonly qrTicket: QRLoginTicket | null;
  readonly isCheckingUpdate: boolean;
  readonly isInstallingUpdate: boolean;
  readonly updateStatusMessage: { text: string; isError: boolean } | null;
  escapeHtml(value: string): string;
}

  export function renderSettingsModal(ctx: SettingsViewContext): string {
    return `
      <div class="cc-sheet-backdrop">
        <div class="cc-sheet" role="dialog" aria-modal="true" aria-label="${t("偏好设置")}">
          <div class="cc-sheet-header">
            <strong>${t("偏好设置与米家连接")}</strong>
            <button class="cc-circle-btn is-small" id="btn-close-settings" title="${t("返回控制中心")}" aria-label="${t("返回控制中心")}">
              ${SF_ICONS.xmark}
            </button>
          </div>

          ${ctx.availableUpdate ? renderUpdateSection(ctx) : ""}

          <div class="cc-field">
            <label>${t("外观模式")}</label>
            <div class="cc-segmented-pills is-even">
              ${APPEARANCES.map(
                (a) =>
                  `<button class="cc-seg-pill ${ctx.settings.appearance === a.id ? "is-active" : ""}" data-appearance="${a.id}" aria-pressed="${ctx.settings.appearance === a.id}">${ctx.escapeHtml(a.title)}</button>`,
              ).join("")}
            </div>
          </div>

          <div class="cc-field">
            <label>${t("界面语言 / 语言")}</label>
            <div class="cc-segmented-pills">
              ${([["system", t("跟随系统")], ["zh-Hans", t("简体中文")], ["en", "English"]] as const)
                .map(
                  ([value, label]) =>
                    `<button class="cc-seg-pill ${ctx.settings.interfaceLanguage === value ? "is-active" : ""}" data-interface-language="${value}" aria-pressed="${ctx.settings.interfaceLanguage === value}">${ctx.escapeHtml(label)}</button>`,
                )
                .join("")}
            </div>
          </div>

          <div class="cc-field">
            <label>${t("温度单位")}</label>
            <div class="cc-segmented-pills">
              ${([["system", t("跟随系统")], ["celsius", t("摄氏度 (°C)")], ["fahrenheit", t("华氏度 (°F)")]] as const)
                .map(
                  ([value, label]) =>
                    `<button class="cc-seg-pill ${ctx.settings.temperatureUnit === value ? "is-active" : ""}" data-temperature-unit="${value}" aria-pressed="${ctx.settings.temperatureUnit === value}">${ctx.escapeHtml(label)}</button>`,
                )
                .join("")}
            </div>
          </div>

          <div class="cc-field">
            <label>${t("面板高度")}</label>
            <div class="cc-segmented-pills">
              ${PANEL_HEIGHTS.map((h) => `<button class="cc-seg-pill ${ctx.settings.panelHeight === h.id ? "is-active" : ""}" data-panel-height="${h.id}" aria-pressed="${ctx.settings.panelHeight === h.id}">${h.title}</button>`).join("")}
            </div>
          </div>

          <div class="cc-field">
            <label>${t("面板位置")}</label>
            <div class="cc-segmented-pills">
              ${PANEL_ANCHORS.map((a) => `<button class="cc-seg-pill ${ctx.panelAnchor === a.id ? "is-active" : ""}" data-panel-anchor="${a.id}" aria-pressed="${ctx.panelAnchor === a.id}">${ctx.escapeHtml(a.title)}</button>`).join("")}
            </div>
            <p class="cc-field-hint">${t("拖动面板顶部即可移动，松开后吸附到最近的角落。")}</p>
          </div>

          <div class="cc-field cc-field-row">
            <label for="settings-climate-panel">${t("空调使用整行控制条")}</label>
            <input id="settings-climate-panel" type="checkbox" ${ctx.settings.climatePanel ? "checked" : ""} />
          </div>

          <div class="cc-field cc-field-row">
            <label for="settings-hide-offline">${t("隐藏离线/未通电的设备")}</label>
            <input id="settings-hide-offline" type="checkbox" ${ctx.settings.hideOfflineDevices ? "checked" : ""} />
          </div>

          <div class="cc-field cc-field-row">
            <label for="settings-hide-grouped-lights">${t("灯组内的单灯不重复显示")}</label>
            <input id="settings-hide-grouped-lights" type="checkbox" ${ctx.settings.hideGroupedLights ? "checked" : ""} />
          </div>

          <div class="cc-field cc-field-row">
            <label for="settings-quick-actions">${t("显示顶部快捷场景栏")}</label>
            <input id="settings-quick-actions" type="checkbox" ${ctx.settings.showQuickActionsBar ? "checked" : ""} />
          </div>

          <div class="cc-field cc-field-row">
            <label for="settings-grok-ball">${t("启用侧边情绪智能球")}</label>
            <input id="settings-grok-ball" type="checkbox" ${ctx.settings.enableGrokBall ? "checked" : ""} />
          </div>

          <div class="cc-field">
            <div class="cc-field-row">
              <label for="settings-enable-hotkey">${t("启用全局呼出快捷键")}</label>
              <input id="settings-enable-hotkey" type="checkbox" ${ctx.settings.enableGlobalHotkey ? "checked" : ""} />
            </div>
            ${
              ctx.settings.enableGlobalHotkey
                ? `<div class="cc-update-row" style="margin-top: 6px;">
                     <span>${t("呼出面板的快捷键")}</span>
                     <div style="display: flex; gap: 6px; align-items: center;">
                       <button
                         type="button"
                         class="cc-seg-pill ${ctx.isRecordingHotkey ? "is-active" : ""}"
                         id="btn-record-hotkey"
                         title="${t("点击后按下新的组合；Esc 取消")}"
                         aria-pressed="${ctx.isRecordingHotkey}"
                       >${ctx.isRecordingHotkey ? t("按下组合…") : ctx.escapeHtml(ctx.settings.globalHotkey)}</button>
                       ${
                         ctx.settings.globalHotkey !== DEFAULT_GLOBAL_SHORTCUT
                           ? `<button type="button" class="cc-btn-secondary" id="btn-reset-hotkey">${t("恢复 Alt+M")}</button>`
                           : ""
                       }
                     </div>
                   </div>`
                : ""
            }
            ${
              ctx.settings.enableGlobalHotkey && (ctx.isRecordingHotkey || ctx.hotkeyNeedsHint)
                ? `<p class="cc-field-hint" id="hotkey-record-hint">${t("需要至少一个 Ctrl / Alt / Shift / Win，或单按 F1–F20。Esc 取消。")}</p>`
                : ""
            }
            ${
              ctx.settings.enableGlobalHotkey && ctx.hotkeyRegistrationError
                ? `<div class="cc-update-row" id="hotkey-conflict-row" style="margin-top: 6px;">
                     <span class="cc-field-hint" style="color: #e67e22; margin: 0;">${ctx.escapeHtml(ctx.hotkeyRegistrationError)}</span>
                     <button type="button" class="cc-btn-secondary" id="btn-retry-hotkey">${t("重试")}</button>
                   </div>`
                : ""
            }
          </div>

          <div class="cc-field">
            <label>${t("设备数据源")}</label>
            <div class="cc-segmented-pills">
              <button
                class="cc-seg-pill ${ctx.settings.connectionMode === "xiaomiCloud" ? "is-active" : ""}"
                data-conn-mode="xiaomiCloud"
              >
                米家云真实设备
              </button>
              <button class="cc-seg-pill ${ctx.settings.connectionMode === "homeAssistant" ? "is-active" : ""}" data-conn-mode="homeAssistant">Home Assistant</button>
              <button
                class="cc-seg-pill ${ctx.settings.connectionMode === "demo" ? "is-active" : ""}"
                data-conn-mode="demo"
              >
                演示设备预览
              </button>
            </div>
          </div>
          <div class="cc-field">
            <label for="settings-ha-url">Home Assistant URL</label>
            <input id="settings-ha-url" class="cc-input" type="url" value="${ctx.escapeHtml(ctx.settings.haBaseURL)}" placeholder="http://homeassistant.local:8123" />
            <label for="settings-ha-token">Home Assistant access token</label>
            <input id="settings-ha-token" class="cc-input" type="password" autocomplete="off" value="${ctx.escapeHtml(ctx.settings.haToken)}" />
          </div>

          <div class="cc-field">
            <label>${t("云端服务器地区")}</label>
            <select class="cc-input" data-mi-region>
              ${MI_CLOUD_REGIONS.map(
                (region) => `<option value="${region.code}" ${normalizeMiCloudRegion(ctx.settings.miCloudRegion) === region.code ? "selected" : ""}>${ctx.escapeHtml(region.label)}</option>`,
              ).join("")}
            </select>
            <p class="cc-field-hint">当前选择：${ctx.escapeHtml(miCloudRegionLabel(ctx.settings.miCloudRegion))}。切换后请重新扫码登录该地区的米家账号；已登录会话仍使用登录时的地区。</p>
          </div>

          <div class="cc-qr-box">
            <button class="cc-btn-primary is-full" id="btn-start-qr" ${ctx.isPollingQR ? "disabled" : ""}>
              ${SF_ICONS.qrcode}
              <span>
                ${
                  ctx.settings.miSession
                    ? t("切换/重新扫码 (已登录 {user})", { user: maskedMiUserId(ctx.settings.miSession.userId) })
                    : t("获取米家登录二维码")
                }
              </span>
            </button>
            <div class="cc-qr-status">${ctx.escapeHtml(ctx.qrStatusText)}</div>
            ${
              ctx.qrTicket
                ? `<div class="cc-qr-frame"><img src="${ctx.escapeHtml(ctx.qrTicket.qrImageURL)}" alt="Xiaomi QR" /></div>`
                : ""
            }
          </div>

          <div class="cc-field">
            <label>${t("AI 服务商预设（支持 OpenRouter Jev、原生 Jev、DeepSeek、千问、GLM 等）")}</label>
            <div class="cc-segmented-pills" style="flex-wrap: wrap;">
              ${ASSISTANT_PROVIDER_PRESETS.filter((p) => p.id !== "custom")
                .map((preset) => {
                  const currentPreset = inferAssistantPreset(ctx.settings.assistantBaseURL);
                  return `<button
                    type="button"
                    class="cc-seg-pill ${currentPreset.id === preset.id ? "is-active" : ""}"
                    data-ai-preset="${ctx.escapeHtml(preset.id)}"
                  >${ctx.escapeHtml(preset.shortTitle)}</button>`;
                })
                .join("")}
            </div>
          </div>

          <div class="cc-field">
            <label>${t("AI 服务地址（支持 /v1/systemone 与 OpenAI 兼容 /v1/chat/completions）")}</label>
            <input
              id="settings-base-url"
              class="cc-input"
              type="text"
              placeholder="https://openrouter.ai/api/v1"
              value="${ctx.escapeHtml(ctx.settings.assistantBaseURL)}"
            />
          </div>

          <div class="cc-field">
            <label>${t("决策模型（如 ~typesafe/jev-latest、jev-latest、deepseek-chat）")}</label>
            <input
              id="settings-model"
              class="cc-input"
              type="text"
              value="${ctx.escapeHtml(ctx.settings.assistantModel)}"
            />
          </div>

          <div class="cc-field">
            <label>${t("API Key（本机安全保存）")}</label>
            <input
              id="settings-api-key"
              class="cc-input"
              type="password"
              placeholder="${ctx.escapeHtml(inferAssistantPreset(ctx.settings.assistantBaseURL).keyPlaceholder)}"
              value="${ctx.escapeHtml(ctx.apiKeyFor(ctx.settings.assistantBaseURL))}"
            />
          </div>

          ${
            ctx.settings.cloudConsentEndpoints.length > 0
              ? `<div class="cc-field">
            <label>${t("已允许发送到：{endpoints}", { endpoints: ctx.escapeHtml(ctx.settings.cloudConsentEndpoints.join("、")) })}</label>
            <button type="button" class="cc-btn-secondary" id="btn-revoke-cloud">${t("撤销授权（下次发往云端前再问）")}</button>
          </div>`
              : ""
          }

          <div class="cc-field">
            <label>${t("「全关」包含哪些设备（插座、扫地机默认不包含）")}</label>
            <div class="cc-timers-stack">
              ${ctx.devices
                .filter((d) => d.kind.kind !== "sensor" && d.kind.kind !== "fridge")
                .map(
                  (d) => `
                <label class="cc-checkbox">
                  <input type="checkbox" data-alloff-device="${ctx.escapeHtml(d.id)}" ${joinsAllOff(d, ctx.settings.allOffOverrides) ? "checked" : ""} />
                  <span>${ctx.escapeHtml(d.name)}${d.roomName ? ` · ${ctx.escapeHtml(d.roomName)}` : ""}</span>
                </label>`,
                )
                .join("")}
            </div>
          </div>

          <div class="cc-field">
            <label class="cc-checkbox">
              <input type="checkbox" id="settings-habit" ${ctx.settings.habitLearningEnabled ? "checked" : ""} />
              <span>${t("自动记住自然语言习惯（相同表达下次 0ms 本地直达）")}</span>
            </label>
            <label class="cc-checkbox">
              <input type="checkbox" id="settings-habit-share" ${ctx.settings.habitShareEnabled ? "checked" : ""} />
              <span>${t("发送习惯摘要（只包含这句话点名的设备）")}</span>
            </label>
            <label>${t("预览这句话会发送的习惯摘要")}</label>
            <input id="settings-habit-share-sample" class="cc-input" type="text" />
            <div id="settings-habit-share-preview">${t("不会发送习惯摘要")}</div>
            ${
              ctx.settings.learnedShortcuts.length > 0
                ? `<div class="cc-timers-stack">
                    ${ctx.settings.learnedShortcuts
                      .map(
                        (s, idx) => `
                      <div class="cc-timer-row">
                        <span>「${ctx.escapeHtml(s.phrase)}」→ ${ctx.escapeHtml(s.reply)}</span>
                        <button class="cc-inline-pill" data-del-habit="${idx}">删除</button>
                      </div>
                    `,
                      )
                      .join("")}
                  </div>`
                : ""
            }
            ${
              ctx.settings.habitEntries.length > 0 || ctx.habitSequences().length > 0
                ? `<div class="cc-timers-stack">
                    <div class="cc-timer-row">
                      <span>${t("已学习 {count} 条时段习惯、{sequences} 条先后习惯（用于猜你想控）", {
                        count: ctx.settings.habitEntries.length,
                        sequences: ctx.habitSequences().length,
                      })}</span>
                      <button class="cc-inline-pill" id="btn-clear-habits">${t("清空")}</button>
                    </div>
                  </div>`
                : ""
            }
          </div>

          ${!ctx.availableUpdate ? renderUpdateSection(ctx) : ""}

          <div class="cc-sheet-footer">
            <button class="cc-btn-danger" id="btn-settings-quit">${t("退出 MenuBarMijia")}</button>
            <button class="cc-btn-primary" id="btn-save-settings">${t("完成并保存")}</button>
          </div>
        </div>
      </div>
    `;
  }

  export function renderUpdateSection(ctx: SettingsViewContext): string {
    const release = ctx.availableUpdate;
    const hasInstaller = Boolean(release?.installerAsset);
    const notes = release?.notes?.trim() ?? "";
    const statusText = ctx.updateStatusMessage?.text ?? (release && hasInstaller ? t("可直接下载并安装，无需打开浏览器") : "");
    return `
      <div class="cc-field cc-update-card ${release ? "is-available" : ""}">
        <label>${release ? t("发现新版本 v{version}", { version: release.version }) : t("软件更新")}</label>
        <div class="cc-update-row">
          <span>${t("当前版本 v{version}", { version: APP_VERSION })}</span>
          <div class="cc-update-actions">
            ${
              release
                ? `${
                    hasInstaller
                      ? `<button type="button" class="cc-btn-primary" id="btn-install-update" ${ctx.isInstallingUpdate ? "disabled" : ""}>${ctx.isInstallingUpdate ? t("正在更新…") : t("立即更新")}</button>`
                      : ""
                  }
                  <button type="button" class="cc-btn-secondary" id="btn-open-update">${
                    hasInstaller ? t("手动下载") : t("有新版本 v{version}，点击查看", { version: release.version })
                  }</button>`
                : `<button type="button" class="cc-btn-secondary" id="btn-check-update" ${ctx.isCheckingUpdate ? "disabled" : ""}>${ctx.isCheckingUpdate ? t("检查中…") : t("立即检查")}</button>`
            }
          </div>
        </div>
        ${
          statusText
            ? `<div class="cc-update-status ${ctx.updateStatusMessage?.isError ? "is-error" : ""}">${ctx.escapeHtml(statusText)}</div>`
            : ""
        }
        ${notes ? `<div class="cc-update-notes">${ctx.escapeHtml(notes)}</div>` : ""}
        <label class="cc-checkbox" style="margin-top: 6px;">
          <input type="checkbox" id="settings-auto-update" ${ctx.settings.autoCheckUpdates ? "checked" : ""} />
          <span>${t("每天自动检查更新（关闭后不再请求 GitHub）")}</span>
        </label>
      </div>
    `;
  }
