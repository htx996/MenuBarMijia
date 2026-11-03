# Status Menu Backend Switcher Design

## Intent

Expose the existing home data-source picker from the menu-bar icon's right-click menu so the user
can see the active backend and switch providers without opening Settings first.

## User Experience

- Add `家居连接` / `Connections` as the first item in the status-item context menu.
- Its native AppKit submenu contains, in `HomeBackend.allCases` order:
  - `Home Assistant`
  - `米家云端直连` / `Xiaomi Cloud Direct`
  - `演示模式` / `Demo Mode`
- The current backend carries the standard macOS checkmark. The other backend items are unchecked.
- Selecting another backend immediately calls the same `HomeStore.switchBackend(_:)` path used by
  the Settings segmented picker. That path shuts down the previous provider, replaces it, starts
  listening, and reconnects. Selecting the already-active backend is a no-op.
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
- Switching to an unconfigured Home Assistant or signed-out Xiaomi Cloud backend is allowed, matching
  the existing Settings picker; the provider reports its normal disconnected state afterward.
- Connection editing, login, LAN scanning, region selection, and LG webOS configuration remain in
  Settings and are explicitly out of scope.

## Approaches Considered

1. **Native submenu with immediate switching — selected.** Compact, follows macOS conventions, shows
   the active backend with a checkmark, and reuses the tested provider-switching path.
2. **Display-only submenu that opens Settings.** Safer but does not meet the requested quick-switch
   workflow.
3. **Three flat top-level menu items.** Fewer pointer movements, but clutters the small status menu and
   scales poorly as connection actions grow.

## Verification

- TDD coverage for submenu structure and Simplified Chinese/English titles.
- Verify exactly one backend is checked for every current backend.
- Verify each backend command routes to the selected `HomeBackend` and Connection Settings opens the
  `.connection` tab.
- Re-run existing Settings, update, quit, right-click suppression, second-click, and menu-position
  regression tests.
- Build and sign a local arm64 test app for manual verification before any PR is created.
