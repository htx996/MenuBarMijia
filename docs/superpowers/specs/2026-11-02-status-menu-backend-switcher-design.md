# Status Menu Backend Switcher Design

## Intent

Expose the current connection mode and live sources in the menu-bar icon's right-click menu. The
menu lets the user enter or leave the offline demo without opening Settings.

## User Experience

- Add `家居连接` / `Connections` as the first item in the status-item context menu.
- Its native AppKit submenu contains `实时连接` / `Live Connections` and `演示模式` / `Demo Mode`.
  The active mode carries the standard macOS checkmark.
- Read-only `Home Assistant` and `米家云端直连` / `Xiaomi Cloud Direct` rows follow the mode picker.
  Each included live source carries a checkmark. Both rows are checked when both sources are included.
- Selecting a mode calls the same `HomeStore.switchBackend(_:)` path used by Settings. Leaving demo
  mode reconnects every configured live source through `HomeStore.preferredLiveBackend`.
- A separator and `打开连接设置…` / `Open Connection Settings…` follow the backend choices and open
  the existing Settings window on the Connection tab.
- Existing `设置…`, `检查更新…`, and `退出 MenuBarMijia` commands remain unchanged below this item.
- The menu is rebuilt for every presentation, so the checkmark and localized titles reflect current
  state without a separate AppKit state cache.

## Boundaries and Safety

- `HomeStore` remains the source of truth. `MenuBarPanelController` only builds AppKit menu items and
  routes actions to the existing store API.
- Credentials, server addresses, account identifiers, and connection errors are not shown in the
  context menu.
- The menu does not offer exclusive Home Assistant or Xiaomi Cloud switching. ADR-0008 requires the
  macOS app to connect both configured sources and merge overlapping devices.
- Connection editing, login, LAN scanning, region selection, and LG webOS configuration remain in
  Settings and are explicitly out of scope.

## Approaches Considered

1. **Mode picker with live-source status.** Selected because it matches ADR-0008, supports the live and
   demo switch, and shows when one or both live sources are active.
2. **Exclusive source picker.** Rejected because selecting one source still builds the dual-source
   provider when both sources are configured.
3. **Three flat top-level menu items.** Fewer pointer movements, but clutters the small status menu and
   scales poorly as connection actions grow.

## Verification

- TDD coverage for submenu structure and Simplified Chinese/English titles.
- Verify exactly one mode is checked and that the source rows match the included provider set.
- Verify mode commands route to demo or the preferred live backend. Verify that Connection Settings
  opens the `.connection` tab.
- Re-run existing Settings, update, quit, right-click suppression, second-click, and menu-position
  regression tests.
- Build and sign a local arm64 test app for manual verification before any PR is created.
