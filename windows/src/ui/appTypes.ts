import type { HabitEntry, HabitRecordingReceipt } from "../core/assistant.js";
import type { CameraStreamQuality } from "../core/cameraQuality.js";
import type { LanguagePreference } from "../core/i18n.js";
import type { MiSession } from "../core/miCloudClient.js";
import type { DeviceCommand, DeviceIntent, SmartDevice, SynthesizedHome } from "../core/models.js";
import type {
  AppAppearance,
  AppSkin,
  LayoutPrefs,
  PanelHeight,
} from "./panelPrefs.js";
import type { TemperatureUnitPreference } from "../core/temperature.js";

declare global {
  interface Window {
    __TAURI_INTERNALS__?: {
      invoke: <T>(cmd: string, args?: Record<string, unknown>) => Promise<T>;
    };
    webkitSpeechRecognition?: new () => SpeechRecognitionInstance;
    SpeechRecognition?: new () => SpeechRecognitionInstance;
  }
}

export interface SpeechRecognitionAlternative {
  readonly transcript: string;
}

export interface SpeechRecognitionResultItem {
  readonly isFinal: boolean;
  readonly 0: SpeechRecognitionAlternative;
}

export interface SpeechRecognitionEventLike {
  readonly results: ArrayLike<SpeechRecognitionResultItem>;
}

export interface SpeechRecognitionInstance {
  lang: string;
  interimResults: boolean;
  continuous: boolean;
  onresult: ((event: SpeechRecognitionEventLike) => void) | null;
  onerror: ((event: { error: string }) => void) | null;
  onend: (() => void) | null;
  start(): void;
  stop(): void;
}

export type ConnectionMode = "demo" | "xiaomiCloud" | "homeAssistant";

export interface LearnedShortcut {
  readonly phrase: string;
  readonly reply: string;
  readonly intents: readonly DeviceIntent[];
  readonly learnedAt: string;
}

export interface PersistedSettings {
  connectionMode: ConnectionMode;
  miSession: MiSession | null;
  /** Non-sensitive Xiaomi cloud region for the next QR login (#37); the session keeps the region it logged in with. */
  miCloudRegion: string;
  /** Daily GitHub release check (#39); off means no request at all. */
  autoCheckUpdates: boolean;
  haBaseURL: string;
  haToken: string;
  assistantBaseURL: string;
  openRouterApiKey: string;
  /** host[:port] the API key was saved for; the key is never sent to another server (#19). */
  assistantKeyEndpoint: string | null;
  /** Cloud AI services (host[:port]) the user allowed to receive commands; asked once per service (#20). */
  cloudConsentEndpoints: string[];
  /** Per-device choice for 全关; missing means the default (plugs and vacuums stay out) (#23). */
  allOffOverrides: Record<string, boolean>;
  assistantModel: string;
  habitLearningEnabled: boolean;
  habitShareEnabled: boolean;
  learnedShortcuts: LearnedShortcut[];
  /** Time-bucket habit entries learned from manual card actions and local commands (#113). */
  habitEntries: HabitEntry[];
  hasCompletedOnboarding: boolean;
  isCompactGridMode: boolean;
  hideOfflineDevices: boolean;
  /** Individual lights of a visible Mi light group fold into the group card (#214). */
  hideGroupedLights: boolean;
  cachedXiaomiDevices: SmartDevice[];
  /** Version of the cached device shape; legacy caches are migrated once on load (#148). */
  cachedDevicesVersion: number;
  cachedHAHome: { identity: string; home: SynthesizedHome } | null;
  cachedModelTypes: Record<string, string>;
  skin: AppSkin;
  appearance: AppAppearance;
  panelHeight: PanelHeight;
  climatePanel: boolean;
  showQuickActionsBar: boolean;
  enableGrokBall: boolean;
  layout: LayoutPrefs;
  /** Selected Mi Home id; null shows every home. */
  selectedHomeId: string | null;
  /** UI language (#52); `system` follows the OS language, and the speech recognizer follows the UI. */
  interfaceLanguage: LanguagePreference;
  /** °C/°F display (#52); stored/command values stay Celsius. */
  temperatureUnit: TemperatureUnitPreference;
  /** Whether the system-wide tray shortcut is registered (#43). */
  enableGlobalHotkey: boolean;
  /** Canonical global shortcut string (default `"Alt+M"`, #43). */
  globalHotkey: string;
  /** Per-camera custom stream URLs (e.g. local go2rtc / HLS), persisted across restarts. */
  cameraStreamURLs?: Record<string, string>;
  /** Per-camera Xiaomi stream quality (#97); missing or unknown values mean `hd`. */
  cameraStreamQualities?: Record<string, CameraStreamQuality>;
}

export interface UndoStep {
  readonly deviceId: string;
  readonly commands: readonly DeviceCommand[];
}

export interface UndoAction {
  readonly summary: string;
  readonly steps: readonly UndoStep[];
  readonly expiresAtMs: number;
  /** Habit records written while executing; undoing takes them back (#113). */
  readonly habitReceipt?: HabitRecordingReceipt;
}

export interface ReplyBannerState {
  readonly text: string;
  readonly source: string;
  readonly isError?: boolean;
}


export interface LoadedSettings {
  readonly settings: PersistedSettings;
  /** An old localStorage copy still contains secrets that must move to the credential manager (#28). */
  readonly hasLegacyCredentials: boolean;
}
