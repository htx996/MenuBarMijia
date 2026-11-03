import type { MenuMijiaWindowsApp } from "./app.js";
import { t } from "../core/i18n.js";
import { maskedMiUserId } from "../core/miCloudClient.js";
import { SF_ICONS } from "./appConstants.js";
import { quickActions } from "./demo.js";

  export function renderPanel(host: MenuMijiaWindowsApp): void {
    const isDemo = host.settings.connectionMode === "demo";
    const activeUndo =
      host.lastUndoAction && host.lastUndoAction.expiresAtMs > Date.now()
        ? host.lastUndoAction
        : null;
    const scheme = host.effectiveAppearance;
    host.root.dataset.scheme = scheme;
    host.root.classList.toggle("is-grok-enabled", host.settings.enableGrokBall);
    host.root.classList.toggle("is-grok-expanded", host.settings.enableGrokBall && host.isGrokBallStageExpanded);
    host.root.classList.toggle("is-native-host", Boolean(window.__TAURI_INTERNALS__));
    host.root.dataset.grokSide = host.grokBallOnLeft ? "left" : "right";
    const popoverClass = `cc-popover skin-${host.skin} scheme-${scheme} ${host.skin === "classic" ? "" : "is-skinned"} ${host.isEditingLayout ? "is-editing" : ""}`.trim();
    const innerContent = `
        <header class="cc-header">
          <div class="cc-header-top">
            <div class="cc-title-group">
              <div class="cc-home-emblem" aria-hidden="true">${SF_ICONS.houseFill}</div>
              <div class="cc-title-stack">
                <div class="cc-title-row">
                  ${
                    host.homes.length > 1
                      ? `<button class="cc-home-switch" id="btn-home-menu" aria-expanded="${host.isHomeMenuOpen}" aria-label="${t("切换家庭")}">
                          <span class="cc-home-title">${host.escapeHtml(host.homeTitle)}</span>
                          <span class="cc-home-caret ${host.isHomeMenuOpen ? "is-open" : ""}">${SF_ICONS.chevronDown}</span>
                        </button>`
                      : `<span class="cc-home-title">${host.escapeHtml(host.homeTitle)}</span>`
                  }
                  <span class="cc-mode-pill ${isDemo ? "is-demo" : "is-cloud"}">
                    ${isDemo ? t("演示预览") : host.settings.connectionMode === "homeAssistant" ? "Home Assistant" : t("Miot 直连")}
                  </span>
                </div>
                <div class="cc-subtitle">${host.escapeHtml(host.isEditingLayout ? t("拖动卡片排序 · 点右下角圆弧手柄改大小") : host.statusSummaryText)}</div>
              </div>
            </div>

            <div class="cc-header-controls">
              <button
                class="cc-circle-btn ${host.isListeningVoice ? "is-recording" : ""}"
                id="btn-mic"
                title="${t("语音控制")}"
                aria-label="${t("语音控制")}"
                aria-pressed="${host.isListeningVoice}"
              >
                ${SF_ICONS.micFill}
              </button>
              <button
                class="cc-circle-btn ${host.isShowingAssistantBar ? "is-selected" : ""}"
                id="btn-toggle-assistant"
                title="${t("AI 自然语言指令栏 (/)")}"
                aria-label="${t("AI 自然语言指令栏")}"
                aria-pressed="${host.isShowingAssistantBar}"
              >
                ${SF_ICONS.sparkles}
              </button>
              ${host.renderAllOffControl()}
              <button
                class="cc-circle-btn"
                id="btn-hide-panel"
                title="${t("收起面板到右下角托盘 (Esc)")}"
                aria-label="${t("收起面板")}"
              >
                ${SF_ICONS.chevronDown}
              </button>
            </div>
          </div>

          ${host.renderEnvironmentStrip()}
        </header>

        ${
          host.isShowingAssistantBar
            ? `
          <section class="cc-assistant-section">
            <div class="cc-spotlight-bar">
              <span class="cc-spotlight-icon">${SF_ICONS.sparkles}</span>
              <input
                id="command-input"
                class="cc-spotlight-input"
                type="text"
                placeholder="${t("说一句：我困了 / 调低两度 / 10分钟后关灯 / 撤销...")}"
                aria-label="${t("自然语言指令")}"
                ${host.isResolvingIntent ? "disabled" : ""}
              />
              <button
                id="btn-send"
                class="cc-spotlight-send"
                title="${t("执行指令 (Enter)")}"
                aria-label="${t("执行指令")}"
                ${host.isResolvingIntent ? "disabled" : ""}
              >
                ${SF_ICONS.arrowUpCircle}
              </button>
            </div>

            ${
              host.replyBanner ||
              host.scheduledCommands.length > 0 ||
              host.missedScheduledCommands.length > 0 ||
              activeUndo ||
              host.pendingSuggestions.length > 0
                ? `
              <div class="cc-feedback-card ${host.replyBanner?.isError ? "is-error" : ""}">
                ${
                  host.replyBanner
                    ? `
                  <div class="cc-feedback-row">
                    <span class="cc-feedback-badge">${host.escapeHtml(host.replyBanner.source)}</span>
                    <span class="cc-feedback-text">${host.escapeHtml(host.replyBanner.text)}</span>
                    ${
                      host.pendingCloudConsent
                        ? `<button class="cc-inline-pill" id="btn-cloud-allow">${t("允许并发送")}</button>
                           <button class="cc-inline-pill" id="btn-cloud-decline">${t("不用了")}</button>`
                        : ""
                    }
                    ${
                      activeUndo
                        ? `<button class="cc-inline-pill" id="btn-undo">${t("撤销")}</button>`
                        : ""
                    }
                  </div>
                `
                    : ""
                }
                ${
                  host.pendingSuggestions.length > 0
                    ? `
                  <div class="cc-suggestion-row">
                    ${host.pendingSuggestions
                      .map(
                        (item) => `<button class="cc-inline-pill" data-suggestion-id="${host.escapeHtml(item.id)}">${host.escapeHtml(item.title)}${
                          item.confidencePercent !== null ? ` · ${item.confidencePercent}%` : ""
                        }</button>`,
                      )
                      .join("")}
                  </div>
                `
                    : ""
                }
                ${
                  host.missedScheduledCommands.length > 0
                    ? `
                  <div class="cc-timers-stack">
                    ${host.missedScheduledCommands
                      .map(
                        (item) => `
                      <div class="cc-timer-row">
                        <span>${t("已错过定时：{command}（电脑睡眠时到点，没有自动执行）", { command: host.escapeHtml(item.command) })}</span>
                        <button class="cc-inline-pill" data-run-missed="${item.id}">立即执行</button>
                        <button class="cc-inline-pill" data-dismiss-missed="${item.id}">忽略</button>
                      </div>
                    `,
                      )
                      .join("")}
                  </div>
                `
                    : ""
                }
                ${
                  host.scheduledCommands.length > 0
                    ? `
                  <div class="cc-timers-stack">
                    ${host.scheduledCommands
                      .map(
                        (item) => `
                      <div class="cc-timer-row">
                        <span>${host.escapeHtml(item.command)} ${t("· 剩余 {remaining}", { remaining: host.formatRemainingMs(item.fireTimestampMs - Date.now()) })}</span>
                        <button class="cc-inline-pill" data-cancel-timer="${item.id}">取消</button>
                      </div>
                    `,
                      )
                      .join("")}
                  </div>
                `
                    : ""
                }
              </div>
            `
                : ""
            }
          </section>
        `
            : ""
        }

        ${host.haConnectionError ? `<div class="cc-feedback-card is-error" role="alert" data-ha-error><span class="cc-feedback-badge">Home Assistant</span><span class="cc-feedback-text">${host.escapeHtml(host.haConnectionError)}</span></div>` : ""}

        ${
          host.settings.showQuickActionsBar
            ? `<section class="cc-quick-strip">
          ${quickActions().map(
            (act) => `
            <button class="cc-quick-pill tint-${act.tint}" data-scene-cmd="${host.escapeHtml(act.command)}">
              <span class="cc-quick-icon">${act.icon}</span>
              <span>${host.escapeHtml(act.title)}</span>
            </button>
          `,
          ).join("")}
          ${host.settings.connectionMode === "homeAssistant" ? host.scenes.map((scene) => `<button class="cc-quick-pill tint-blue" data-ha-scene="${host.escapeHtml(scene.id)}"><span class="cc-quick-icon">${SF_ICONS.sparkles}</span><span>${host.escapeHtml(scene.name)}</span></button>`).join("") : ""}
        </section>`
            : ""
        }


        <div class="cc-room-bar">
          <div class="cc-room-track">
          <div class="cc-room-scroll">
            ${host.rooms
              .map(
                (room) => {
                  const pressed = room === "全部" ? host.listCut.kind === "all" : host.selectedRoom === room;
                  return `
              <button
                class="cc-room-pill ${pressed ? "is-active" : ""}"
                data-room="${host.escapeHtml(room)}"
                aria-pressed="${pressed}"
              >
                ${host.escapeHtml(room === "全部" ? t("全部") : room)}
              </button>
            `;
                },
              )
              .join("")}
          </div>
          </div>
          <div class="cc-room-tools">
          <button
            class="cc-circle-btn is-small"
            id="btn-toggle-grid"
            title="${host.settings.isCompactGridMode ? t("切换为单列详情视图") : t("切换为双列控制中心磁贴")}"
            aria-label="${host.settings.isCompactGridMode ? t("切换为单列详情视图") : t("切换为双列控制中心磁贴")}"
            aria-pressed="${host.settings.isCompactGridMode}"
          >
            ${host.settings.isCompactGridMode ? SF_ICONS.grid2x2 : SF_ICONS.grid1x2}
          </button>
          <button
            class="cc-circle-btn is-small ${host.settings.hideOfflineDevices ? "is-selected" : ""}"
            id="btn-toggle-hide-offline"
            title="${host.settings.hideOfflineDevices ? t("当前只显示在线设备（点击显示全部）") : t("点击隐藏未通电/离线设备")}"
            aria-label="${t("只显示在线设备")}"
            aria-pressed="${host.settings.hideOfflineDevices}"
          >
            ${host.settings.hideOfflineDevices ? SF_ICONS.wifi : SF_ICONS.wifiSlash}
          </button>
          </div>
        </div>
        ${host.renderKindBar()}

        <div class="cc-divider"></div>

        <main class="cc-scroll-area">
          ${host.renderDeviceGrid()}
        </main>

        <div class="cc-divider"></div>

        <footer class="cc-footer">
          <div class="cc-footer-status">
            <span class="cc-status-dot ${host.isSyncingCloud ? "is-syncing" : host.settings.connectionMode === "homeAssistant" ? (host.haConnectionError || !host.settings.haBaseURL || !host.settings.haToken ? "is-demo" : "is-online") : isDemo ? "is-demo" : "is-online"}"></span>
            <span class="cc-footer-label">
              ${
                host.settings.connectionMode === "xiaomiCloud" && host.settings.miSession
                  ? t("米家账号 {user} · {count} 台设备", { user: maskedMiUserId(host.settings.miSession.userId), count: host.devices.length })
                  : host.settings.connectionMode === "homeAssistant" ? `Home Assistant · ${host.devices.length}` : t("演示模式 · 未连接米家云")
              }
            </span>
          </div>

          <div class="cc-footer-actions">
            ${
              host.availableUpdate
                ? `<button class="cc-footer-pill is-accent" id="btn-footer-update" title="${t("发现新版本 v{version}", { version: host.availableUpdate.version })}">
                    <span>${t("更新 v{version}", { version: host.availableUpdate.version })}</span>
                  </button>`
                : ""
            }
            ${
              host.settings.connectionMode !== "homeAssistant" && (!host.settings.miSession || isDemo)
                ? `<button class="cc-footer-pill is-accent" id="btn-footer-qr" title="${t("用手机米家 App 扫码直连真实设备")}">
                    ${SF_ICONS.qrcode}
                    <span>${t("扫码直连")}</span>
                  </button>`
                : ""
            }
            <button
              class="cc-footer-icon-btn"
              id="btn-toggle-appearance"
              title="${scheme === "light" ? t("切换深色模式") : t("切换浅色模式")}"
              aria-label="${scheme === "light" ? t("切换深色模式") : t("切换浅色模式")}"
            >
              ${scheme === "light" ? SF_ICONS.moonStarsFill : SF_ICONS.sunMaxFill}
            </button>
            <button
              class="cc-footer-icon-btn ${host.isSyncingCloud ? "is-spinning" : ""}"
              id="btn-refresh"
              title="${t("立即同步最新设备状态")}"
              aria-label="${t("立即同步最新设备状态")}"
            >
              ${SF_ICONS.arrowClockwise}
            </button>
            <button
              class="cc-footer-icon-btn"
              id="btn-settings"
              title="${t("连接设置与 AI 决策配置")}"
              aria-label="${t("打开设置")}"
            >
              ${SF_ICONS.sliderHorizontal}
            </button>
            <button
              class="cc-footer-pill is-danger"
              id="btn-quit-app"
              title="${t("完全退出 MenuBarMijia")}"
            >
              ${SF_ICONS.power}
              <span>${t("退出")}</span>
            </button>
          </div>
        </footer>

        ${host.activeSheet === "onboarding" ? host.renderOnboardingModal() : ""}
        ${host.activeSheet === "settings" ? host.renderSettingsModal() : ""}
        ${host.cameraLive.activeLiveCameraId !== null ? host.cameraLive.renderCameraLiveModal() : ""}
        ${host.renderHomeMenu()}
        ${host.renderContextMenu()}
        ${host.renderPrompt()}
    `;
    const existingPopover = host.root.querySelector<HTMLElement>(":scope > .cc-popover");
    if (existingPopover) {
      if (existingPopover.className !== popoverClass) {
        existingPopover.className = popoverClass;
      }
      existingPopover.innerHTML = innerContent;
    } else {
      host.root.innerHTML = `<div class="${popoverClass}">${innerContent}</div>`;
    }
    host.root.querySelector(":scope > .cc-grok-sidebar")?.remove();
    host.root.insertAdjacentHTML("beforeend", host.renderGrokBallSidebar());

    host.bindEvents();
  }
