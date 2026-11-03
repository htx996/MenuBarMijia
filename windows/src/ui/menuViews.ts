import type { MenuMijiaWindowsApp } from "./app.js";
import { t } from "../core/i18n.js";
import { MI_CLOUD_REGIONS, maskedMiUserId, normalizeMiCloudRegion } from "../core/miCloudClient.js";
import { TILE_SIZES, chosenSize, homeOptions } from "./panelPrefs.js";
import { SF_ICONS } from "./appConstants.js";
import { renderSettingsModal as renderSettingsModalView } from "./settingsViews.js";

export function renderHomeMenu(host: MenuMijiaWindowsApp): string {
    if (!host.isHomeMenuOpen || host.homes.length < 2) return "";
    const item = (id: string | null, label: string, count?: number) => `
      <button class="cc-menu-item ${host.settings.selectedHomeId === id ? "is-checked" : ""}" data-home="${id ?? ""}">
        <span>${host.escapeHtml(label)}</span>${count !== undefined ? `<small>${count}</small>` : ""}
      </button>`;
    return `
      <div class="cc-menu-scrim" data-close-menus></div>
      <div class="cc-menu cc-home-menu">
        ${item(null, t("全部家庭"))}
        <div class="cc-menu-sep"></div>
        ${host.homes.map((h) => item(h.id, h.name, h.deviceCount)).join("")}
      </div>`;
  }

export function renderContextMenu(host: MenuMijiaWindowsApp): string {
    const m = host.ctxMenu;
    if (!m) return "";
    const pos = `left:${Math.min(m.x, window.innerWidth - 230)}px; top:${Math.min(m.y, window.innerHeight - 260)}px`;
    if (m.groupId) {
      const g = host.layout.groups.find((x) => x.id === m.groupId);
      if (!g) return "";
      const gid = host.escapeHtml(g.id);
      return `
        <div class="cc-menu-scrim" data-close-menus></div>
        <div class="cc-menu" style="${pos}">
          <div class="cc-menu-title">${host.escapeHtml(g.name)}</div>
          <button class="cc-menu-item" data-group-action="rename:${gid}">重命名</button>
          <button class="cc-menu-item" data-group-action="up:${gid}">上移分组</button>
          <button class="cc-menu-item" data-group-action="down:${gid}">下移分组</button>
          <div class="cc-menu-sep"></div>
          <button class="cc-menu-item is-danger" data-group-action="delete:${gid}">删除分组</button>
        </div>`;
    }
    const dev = host.devices.find((d) => d.id === m.deviceId);
    if (!dev) return "";
    const id = host.escapeHtml(dev.id);
    const size = chosenSize(host.layout, host.pageKey, dev.id);
    const current = host.layout.groupMap[dev.id];
    return `
      <div class="cc-menu-scrim" data-close-menus></div>
      <div class="cc-menu" style="${pos}">
        <div class="cc-menu-title">${host.escapeHtml(host.layout.aliases[dev.id] ?? dev.name)}</div>
        <div class="cc-menu-label">${t("卡片大小（本页）")}</div>
        <div class="cc-menu-chips">
          ${TILE_SIZES.map((t) => `<button class="cc-menu-chip ${size === t.id ? "is-active" : ""}" data-set-size="${id}:${t.id}">${t.title}</button>`).join("")}
        </div>
        <div class="cc-menu-label">${t("移到分组")}</div>
        <div class="cc-menu-chips">
          ${host.layout.groups.map((g) => `<button class="cc-menu-chip ${current === g.id ? "is-active" : ""}" data-set-group="${id}:${host.escapeHtml(g.id)}">${host.escapeHtml(g.name)}</button>`).join("")}
          ${current ? `<button class="cc-menu-chip" data-set-group="${id}:">不分组</button>` : ""}
          <button class="cc-menu-chip is-add" data-new-group="${id}">＋ 新建</button>
        </div>
        <div class="cc-menu-sep"></div>
        <button class="cc-menu-item" data-rename-device="${id}">重命名…</button>
        <button class="cc-menu-item" data-start-editing>${t("编辑布局")}</button>
      </div>`;
  }

export function renderPrompt(host: MenuMijiaWindowsApp): string {
    const p = host.prompt;
    if (!p) return "";
    let title = t("新建分组");
    let value = "";
    let placeholder = t("例如：灯光、电器、环境");
    if (p.kind === "renameGroup") {
      title = t("重命名分组");
      value = host.layout.groups.find((g) => g.id === p.groupId)?.name ?? "";
    } else if (p.kind === "renameDevice") {
      title = t("重命名设备");
      const dev = host.devices.find((d) => d.id === p.deviceId);
      placeholder = dev?.name ?? "";
      value = host.layout.aliases[p.deviceId] ?? dev?.name ?? "";
    }
    const hasAlias = p.kind === "renameDevice" && Boolean(host.layout.aliases[p.deviceId]);
    return `
      <div class="cc-prompt-backdrop" data-prompt-cancel></div>
      <div class="cc-prompt">
        <strong>${title}</strong>
        <input id="prompt-input" class="cc-prompt-input" type="text" value="${host.escapeHtml(value)}" placeholder="${host.escapeHtml(placeholder)}" />
        ${p.kind === "renameDevice" ? `<small>${t("只在本 App 显示，不会修改米家里的名字")}</small>` : ""}
        <div class="cc-prompt-actions">
          ${hasAlias ? `<button class="cc-btn-secondary" id="btn-prompt-reset">${t("恢复原名")}</button>` : ""}
          <button class="cc-btn-secondary" data-prompt-cancel>${t("取消")}</button>
          <button class="cc-btn-primary" id="btn-prompt-save">${t("保存")}</button>
        </div>
      </div>`;
  }

export function renderOnboardingModal(host: MenuMijiaWindowsApp): string {
    return `
      <div class="cc-sheet-backdrop">
        <div class="cc-sheet" role="dialog" aria-modal="true" aria-label="${t("首次设置")}">
          <div class="cc-sheet-header">
            <div class="cc-sheet-badge">${t("MenuBarMijia 控制中心")}</div>
            <button class="cc-circle-btn is-small" id="btn-close-onboarding" title="${t("关闭引导")}" aria-label="${t("关闭引导")}">
              ${SF_ICONS.xmark}
            </button>
          </div>

          <h2 class="cc-sheet-title">${t("扫码直连你的真实米家设备")}</h2>
          <p class="cc-sheet-desc">
            ${t("手机打开「米家 App → 扫一扫」即可直接同步全屋真实设备；常驻 Windows 右下角系统托盘，点击图标或按 Alt+M 随时弹出，点击外部自动收起。")}
          </p>

          <div class="cc-field">
            <label>${t("云端服务器地区")}</label>
            <select class="cc-input" data-mi-region>
              ${MI_CLOUD_REGIONS.map(
                (region) => `<option value="${region.code}" ${normalizeMiCloudRegion(host.settings.miCloudRegion) === region.code ? "selected" : ""}>${host.escapeHtml(region.label)}</option>`,
              ).join("")}
            </select>
            <p class="cc-field-hint">${t("欧洲、印度、俄罗斯、新加坡、美区的米家账号请先选择对应地区，再扫码登录。")}</p>
          </div>

          <div class="cc-qr-box">
            <button class="cc-btn-primary is-full" id="btn-start-qr" ${host.isPollingQR ? "disabled" : ""}>
              ${SF_ICONS.qrcode}
              <span>${host.isPollingQR ? t("正在等待手机米家扫码确认...") : t("获取米家登录二维码")}</span>
            </button>
            <div class="cc-qr-status">${host.escapeHtml(host.qrStatusText)}</div>
            ${
              host.qrTicket
                ? `<div class="cc-qr-frame">
                    <img src="${host.escapeHtml(host.qrTicket.qrImageURL)}" alt="Xiaomi QR" />
                  </div>`
                : ""
            }
          </div>

          <div class="cc-field">
            <label>${t("OpenRouter API Key（可选，用于 Jev SystemOne 模糊意图决策）")}</label>
            <input
              id="onboarding-api-key"
              class="cc-input"
              type="password"
              placeholder="sk-or-v1-..."
              value="${host.escapeHtml(host.apiKeyFor(host.settings.assistantBaseURL))}"
            />
          </div>

          <div class="cc-sheet-footer">
            <button class="cc-btn-secondary" id="btn-close-onboarding-alt">${t("先看演示预览")}</button>
            <button class="cc-btn-primary" id="btn-finish-onboarding">${t("进入控制中心")}</button>
          </div>
        </div>
      </div>
    `;
  }

export function renderSettingsModal(host: MenuMijiaWindowsApp): string {
    return renderSettingsModalView({
      settings: host.settings,
      devices: host.devices,
      availableUpdate: host.availableUpdate,
      apiKeyFor: (baseURL) => host.apiKeyFor(baseURL),
      habitSequences: () => host.habitSequences(),
      hotkeyNeedsHint: host.hotkeyNeedsHint,
      hotkeyRegistrationError: host.hotkeyRegistrationError,
      isPollingQR: host.isPollingQR,
      isRecordingHotkey: host.isRecordingHotkey,
      panelAnchor: host.panelAnchor,
      qrStatusText: host.qrStatusText,
      qrTicket: host.qrTicket,
      isCheckingUpdate: host.isCheckingUpdate,
      isInstallingUpdate: host.isInstallingUpdate,
      updateStatusMessage: host.updateStatusMessage,
      escapeHtml: (value) => host.escapeHtml(value),
    });
  }
