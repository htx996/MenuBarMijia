import { t } from "../core/i18n.js";
import {
  CAMERA_STREAM_QUALITIES,
  DEFAULT_CAMERA_STREAM_QUALITY,
  normalizeCameraStreamQuality,
  type CameraStreamQuality,
} from "../core/cameraQuality.js";
import {
  MiCloudClient,
  type HttpTransport,
  type MiotSpecResolver,
} from "../core/miCloudClient.js";
import { localizeNightShot, type SmartDevice } from "../core/models.js";
import { CAMERA_QUALITY_TITLES, SF_ICONS } from "./appConstants.js";
import type { PersistedSettings } from "./appTypes.js";
import { waitForCameraFrameGap } from "./dom.js";
import { invokeTauriVoid } from "./transport.js";

export interface CameraLiveHost {
  readonly root: HTMLElement;
  readonly settings: PersistedSettings;
  readonly devices: readonly SmartDevice[];
  readonly transport: HttpTransport;
  readonly specResolver: MiotSpecResolver;
  readonly endpointSubmission: Promise<unknown>;
  replyBanner: { text: string; source: string; isError?: boolean } | null;
  render(): void;
  escapeHtml(value: string): string;
  saveSettings(): void;
}

export class CameraLiveController {
  constructor(private readonly host: CameraLiveHost) {
    this.cameraStreamURLs = { ...(host.settings.cameraStreamURLs ?? {}) };
    this.cameraStreamQualities = { ...(host.settings.cameraStreamQualities ?? {}) };
  }

  public activeLiveCameraId: string | null = null;
  /**
   * The camera frees a used P2P session on its own schedule (measured: a fresh
   * session streams fine, but one that carried video needs well over a minute
   * before it can be re-negotiated). Closing the live modal therefore only
   * HIDES it and keeps the whole chain hot; full teardown happens when the
   * panel closes, the device errors, or after this long with nobody watching.
   */
  public liveCameraHidden = false;
  public liveCameraKeepAliveTimer: number | null = null;
  public static readonly CAMERA_KEEP_ALIVE_MS = 120_000;
  /** Tests pin this short to watch the teardown without waiting two minutes. */
  cameraKeepAliveMs = CameraLiveController.CAMERA_KEEP_ALIVE_MS;
  public liveCameraStreamURL: string | null = null;
  public liveCameraLoading = false;
  public liveCameraError: string | null = null;
  public liveCameraShowingURLInput = false;
  public cameraStreamURLs: Record<string, string> = {};
  /** Per-camera Xiaomi stream quality; `hd` matches the macOS default (#193). */
  public cameraStreamQualities: Record<string, CameraStreamQuality> = {};
  /** The live picture arrives as MJPEG frames in a persistent `<img>`, which never restarts on re-render. */
  public liveCameraMode: "mjpeg" | null = null;
  public liveCameraQualityApplies = true;
  public liveCameraImgEl: HTMLImageElement | null = null;
  public liveCameraAbort: AbortController | null = null;
  public ownedStreamOrigin: string | null = null;
  public liveCameraToken = 0;
  public readonly pendingCameraReleases = new Map<string, Promise<void>>();

  public openCameraLiveView(deviceId: string): void {
    const dev = this.host.devices.find((d) => d.id === deviceId);
    if (!dev || dev.kind.kind !== "camera") return;
    // Hot resume: the modal was only hidden, so the bridge, relay and P2P
    // session are still alive — just reveal it again.
    if (this.activeLiveCameraId === deviceId && this.liveCameraHidden && this.liveCameraImgEl) {
      this.liveCameraHidden = false;
      this.clearCameraKeepAlive();
      invokeTauriVoid("set_pin_popover", { pin: true });
      this.host.render();
      return;
    }
    if (this.activeLiveCameraId !== null && this.activeLiveCameraId !== deviceId) {
      this.closeCameraLiveView();
    }
    this.activeLiveCameraId = dev.id;
    this.liveCameraQualityApplies = true;
    this.liveCameraHidden = false;
    this.clearCameraKeepAlive();
    this.liveCameraError = null;
    this.liveCameraShowingURLInput = false;
    this.liveCameraStreamURL = this.cameraStreamURLs[dev.id]
      ? this.normalizeWindowsCameraStreamUrl(this.cameraStreamURLs[dev.id]!)
      : this.resolveHaCameraStreamUrl(dev);
    this.liveCameraLoading = false;
    invokeTauriVoid("set_pin_popover", { pin: true });
    if (dev.kind.isOn && this.liveCameraStreamURL && window.__TAURI_INTERNALS__?.invoke) {
      this.liveCameraLoading = true;
      void this.playCustomCameraUrl(dev.id, this.liveCameraStreamURL);
    } else if (dev.kind.isOn && this.liveCameraStreamURL && this.needsHlsTranscodeBridge(this.liveCameraStreamURL)) {
      void this.bridgeHlsStreamToMjpeg(dev.id, this.liveCameraStreamURL);
    } else if (dev.kind.isOn && !this.liveCameraStreamURL && this.host.settings.connectionMode === "xiaomiCloud") {
      void this.resolveCloudCameraStream(dev);
    }
    this.host.render();
  }

  public resolveHaCameraStreamUrl(dev: SmartDevice): string | null {
    if (this.host.settings.connectionMode !== "homeAssistant" || dev.kind.kind !== "camera") return null;
    const rawPath = dev.kind.snapshotPath?.trim() ?? "";
    if (!rawPath) return null;
    const streamPath = rawPath.replace(/^\/api\/camera_proxy\//i, "/api/camera_proxy_stream/");
    if (/^https?:\/\//i.test(streamPath)) return streamPath;
    const base = this.host.settings.haBaseURL.trim().replace(/\/+$/, "");
    if (!base) return null;
    return `${base}${streamPath.startsWith("/") ? "" : "/"}${streamPath}`;
  }

  /** Hides the modal but keeps the stream hot, so reopening is instant (#97). */
  public hideCameraLiveView(): void {
    if (this.activeLiveCameraId === null) return;
    this.liveCameraHidden = true;
    invokeTauriVoid("set_pin_popover", { pin: false });
    this.clearCameraKeepAlive();
    this.liveCameraKeepAliveTimer = window.setTimeout(() => {
      this.liveCameraKeepAliveTimer = null;
      // Nobody came back within the keep-alive window: release the camera's
      // single P2P session so the phone app (or the next open) can use it.
      if (this.liveCameraHidden) this.closeCameraLiveView();
    }, this.cameraKeepAliveMs);
    this.host.render();
  }

  public clearCameraKeepAlive(): void {
    if (this.liveCameraKeepAliveTimer !== null) {
      window.clearTimeout(this.liveCameraKeepAliveTimer);
      this.liveCameraKeepAliveTimer = null;
    }
  }

  public closeCameraLiveView(): void {
    const closingId = this.activeLiveCameraId;
    const closingDev = closingId ? this.host.devices.find((d) => d.id === closingId) : undefined;
    this.clearCameraKeepAlive();
    this.liveCameraHidden = false;
    this.stopLiveTransport();
    this.activeLiveCameraId = null;
    this.liveCameraQualityApplies = true;
    this.liveCameraStreamURL = null;
    this.liveCameraLoading = false;
    this.liveCameraError = null;
    this.liveCameraShowingURLInput = false;
    if (closingId) {
      if (this.host.settings.connectionMode === "xiaomiCloud" && closingDev) {
        void this.releaseCameraP2PSession(closingDev, this.liveCameraToken);
      }
      // Release the P2P session or bridged stream so the next open negotiates a fresh one.
      invokeTauriVoid("stop_xiaomi_camera_bridge", { did: closingId });
    }
    invokeTauriVoid("set_pin_popover", { pin: false });
    this.host.render();
  }

  /**
   * Tells the camera to drop its single P2P session. Serialized with the next
   * negotiation for the same camera so a delayed stop-stream never kills a
   * freshly reopened stream (#97).
   */
  public releaseCameraP2PSession(
    dev: SmartDevice,
    releaseToken = this.liveCameraToken,
    allowActiveCamera = false,
  ): Promise<void> {
    if (!this.host.settings.miSession) return Promise.resolve();
    const run = (async () => {
      try {
        const spec = await this.host.specResolver.resolve({
          did: dev.id,
          name: dev.name,
          model: dev.model,
          isOnline: dev.isOnline,
          specType: null,
        });
        if (this.liveCameraToken !== releaseToken || (!allowActiveCamera && this.activeLiveCameraId === dev.id)) return;
        const p2pSvc = spec.services.find((s) => s.actions.some((a) => a.type.includes("stop-stream")));
        const stopAct = p2pSvc?.actions.find((a) => a.type.includes("stop-stream"));
        if (!p2pSvc || !stopAct) return;
        const client = new MiCloudClient(this.host.settings.miSession!, this.host.transport);
        await client
          .callAction({ did: dev.id, siid: p2pSvc.iid, aiid: stopAct.iid, inputs: [] })
          .catch(() => {});
      } catch {
        // Best effort only; the bridge teardown below already freed local resources.
      }
    })();
    const tracked = run.finally(() => {
      if (this.pendingCameraReleases.get(dev.id) === tracked) {
        this.pendingCameraReleases.delete(dev.id);
      }
    });
    this.pendingCameraReleases.set(dev.id, tracked);
    return tracked;
  }

  /** Drops the MJPEG image and any pending negotiation. */
  public stopLiveTransport(): void {
    this.liveCameraToken += 1;
    this.liveCameraAbort?.abort();
    this.liveCameraAbort = null;
    this.liveCameraImgEl?.remove();
    this.liveCameraImgEl = null;
    this.liveCameraMode = null;
  }

  /** Puts the live element back after `render()` rebuilds the panel markup. */
  public attachLiveMedia(): void {
    const stage = this.host.root.querySelector<HTMLElement>(".cc-camera-stage");
    if (!stage) return;
    const el = this.liveCameraImgEl;
    if (!el) return;
    if (el.parentElement !== stage) {
      stage.replaceChildren(el);
    }
  }

  public startMjpegTransport(name: string): void {
    this.liveCameraAbort?.abort();
    const img = document.createElement("img");
    img.id = "cc-camera-live-img";
    img.alt = "";
    img.style.cssText = "max-width:100%;border-radius:10px;";
    let retried = false;
    img.addEventListener("error", () => {
      if (retried) return;
      retried = true;
      window.setTimeout(() => this.reconnectCameraLiveView(), 1200);
    });
    const abort = new AbortController();
    this.liveCameraAbort = abort;
    this.liveCameraImgEl = img;
    this.liveCameraMode = "mjpeg";
    void this.pumpAuthenticatedMjpeg(name, img, this.liveCameraToken, abort.signal);
  }

  public ownedGo2rtcOrigin(origin: string): boolean {
    const match = /^http:\/\/127\.0\.0\.1:(\d+)$/.exec(origin);
    if (!match) return false;
    const port = Number(match[1]);
    return port > 0 && port !== 1984 && port !== 8554 && port !== 8555;
  }

  public async refreshOwnedGo2rtcOrigin(): Promise<void> {
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) return;
    try {
      const endpoint = await invoke<{ origin: string }>("go2rtc_endpoint");
      this.ownedStreamOrigin = this.ownedGo2rtcOrigin(endpoint.origin) ? endpoint.origin : null;
    } catch {
      this.ownedStreamOrigin = null;
    }
  }

  public async pumpAuthenticatedMjpeg(
    name: string,
    img: HTMLImageElement,
    token: number,
    signal: AbortSignal,
  ): Promise<void> {
    const invoke = window.__TAURI_INTERNALS__?.invoke;
    if (!invoke) return;
    while (token === this.liveCameraToken && !signal.aborted) {
      try {
        const jpeg = await invoke<string>("go2rtc_jpeg_frame", { src: name });
        if (token !== this.liveCameraToken || signal.aborted) return;
        if (!jpeg) throw new Error("empty frame");
        img.src = `data:image/jpeg;base64,${jpeg}`;
      } catch {
        if (token === this.liveCameraToken && !signal.aborted) {
          img.dispatchEvent(new Event("error"));
        }
        return;
      }
      await waitForCameraFrameGap(signal, 200);
    }
  }

  /**
   * WebView2/Chromium has no built-in HLS (.m3u8) demuxer. Local go2rtc playlists
   * map directly onto go2rtc's native MJPEG endpoint (`/api/stream.mjpeg`), while
   * remote `.m3u8` playlists are transcoded to MJPEG through `bridge_hls_camera_stream`.
   */
  public normalizeWindowsCameraStreamUrl(rawUrl: string): string {
    return rawUrl.trim().replace(/^(https?):\/\/localhost:(\d+)(\/|$)/i, "$1://127.0.0.1:$2$3");
  }

  public async playCustomCameraUrl(devId: string, playable: string): Promise<void> {
    const token = this.liveCameraToken;
    await this.refreshOwnedGo2rtcOrigin();
    if (this.liveCameraToken !== token || this.activeLiveCameraId !== devId) return;
    const normalized = this.normalizeWindowsCameraStreamUrl(playable);
    const ownedSrc = this.ownedGo2rtcStreamName(normalized);
    if (ownedSrc) {
      this.liveCameraStreamURL = ownedSrc;
      this.liveCameraError = null;
      this.liveCameraLoading = false;
      this.startMjpegTransport(ownedSrc);
      this.host.render();
      this.attachLiveMedia();
      return;
    }
    this.liveCameraLoading = false;
    this.liveCameraStreamURL = normalized;
    if (this.needsHlsTranscodeBridge(normalized)) {
      void this.bridgeHlsStreamToMjpeg(devId, normalized);
    } else {
      this.host.render();
    }
  }

  public isOwnedGo2rtcApiUrl(url: string): boolean {
    const origin = this.ownedStreamOrigin;
    if (!origin) return false;
    let parsed: URL;
    try {
      parsed = new URL(url);
    } catch {
      return false;
    }
    if (`${parsed.protocol}//${parsed.host}`.toLowerCase() !== origin.toLowerCase()) return false;
    return parsed.pathname === "/api" || parsed.pathname.startsWith("/api/");
  }

  public ownedGo2rtcStreamName(url: string): string | null {
    if (!this.isOwnedGo2rtcApiUrl(url)) return null;
    let src: string | null;
    try {
      src = new URL(url).searchParams.get("src");
    } catch {
      return null;
    }
    if (!src || !/^[A-Za-z0-9_]+$/.test(src)) return null;
    return src;
  }

  public needsHlsTranscodeBridge(url: string): boolean {
    if (!window.__TAURI_INTERNALS__?.invoke) return false;
    if (this.isOwnedGo2rtcApiUrl(url)) return false;
    if (/\.m3u8(\?|$|#)/i.test(url)) {
      const probe = document.createElement("video");
      const canPlayNative =
        typeof probe.canPlayType === "function" &&
        Boolean(
          probe.canPlayType("application/vnd.apple.mpegurl") ||
            probe.canPlayType("application/x-mpegURL"),
        );
      return !canPlayNative;
    }
    return /^https?:\/\//i.test(url);
  }

  public async bridgeHlsStreamToMjpeg(did: string, hlsUrl: string): Promise<boolean> {
    if (!window.__TAURI_INTERNALS__?.invoke) return false;
    const token = this.liveCameraToken;
    this.liveCameraLoading = true;
    this.host.render();
    try {
      if (this.host.settings.connectionMode === "homeAssistant") {
        await this.host.endpointSubmission;
        if (this.liveCameraToken !== token || this.activeLiveCameraId !== did) return false;
      }
      const mjpegName = await window.__TAURI_INTERNALS__.invoke<string>("bridge_hls_camera_stream", {
        did,
        hlsUrl,
      });
      if (this.liveCameraToken !== token || this.activeLiveCameraId !== did) return false;
      if (mjpegName) {
        this.liveCameraStreamURL = mjpegName;
        this.liveCameraError = null;
        this.liveCameraLoading = false;
        this.startMjpegTransport(mjpegName);
        this.host.render();
        this.attachLiveMedia();
        return true;
      }
      this.liveCameraLoading = false;
      this.host.render();
    } catch (err) {
      if (this.liveCameraToken === token && this.activeLiveCameraId === did) {
        this.liveCameraError = err instanceof Error ? err.message : String(err);
        this.liveCameraLoading = false;
        this.host.render();
      }
    }
    return false;
  }

  public setCameraStreamQuality(deviceId: string, quality: CameraStreamQuality): void {
    this.cameraStreamQualities = { ...this.cameraStreamQualities, [deviceId]: quality };
    this.host.settings.cameraStreamQualities = { ...this.cameraStreamQualities };
    this.host.saveSettings();
  }

  public reconnectCameraLiveView(): void {
    const dev = this.host.devices.find((d) => d.id === this.activeLiveCameraId);
    if (!dev || dev.kind.kind !== "camera") return;
    this.stopLiveTransport();
    this.liveCameraQualityApplies = true;
    this.liveCameraStreamURL = this.cameraStreamURLs[dev.id]
      ? this.normalizeWindowsCameraStreamUrl(this.cameraStreamURLs[dev.id]!)
      : this.resolveHaCameraStreamUrl(dev);
    this.liveCameraError = null;
    this.liveCameraLoading = false;
    if (this.liveCameraStreamURL && window.__TAURI_INTERNALS__?.invoke) {
      this.liveCameraLoading = true;
      void this.playCustomCameraUrl(dev.id, this.liveCameraStreamURL);
    } else if (this.liveCameraStreamURL && this.needsHlsTranscodeBridge(this.liveCameraStreamURL)) {
      void this.bridgeHlsStreamToMjpeg(dev.id, this.liveCameraStreamURL);
    } else if (!this.liveCameraStreamURL && this.host.settings.connectionMode === "xiaomiCloud") {
      void this.resolveCloudCameraStream(dev);
    }
    this.host.render();
  }

  public async resolveCloudCameraStream(dev: SmartDevice): Promise<void> {
    if (dev.kind.kind !== "camera" || !this.host.settings.miSession) return;
    this.liveCameraLoading = true;
    this.host.render();
    // Closing/hiding bumps liveCameraToken via stopLiveTransport or full teardown;
    // a negotiation that outlives its modal must not start a bridge afterwards.
    const token = this.liveCameraToken;
    const stale = () => this.liveCameraToken !== token || this.activeLiveCameraId !== dev.id;
    let startedP2PSession = false;
    let failureReason: string | null = null;
    const releaseIfStarted = () => {
      if (startedP2PSession) {
        startedP2PSession = false;
        void this.releaseCameraP2PSession(dev, token, true);
      }
    };
    try {
      const pendingRelease = this.pendingCameraReleases.get(dev.id);
      if (pendingRelease) {
        await pendingRelease;
        if (stale()) return;
      }
      const spec = await this.host.specResolver.resolve({
        did: dev.id,
        name: dev.name,
        model: dev.model,
        isOnline: dev.isOnline,
        specType: null,
      });
      if (stale()) return;
      const client = new MiCloudClient(this.host.settings.miSession, this.host.transport);

      // 1. Try cloud HLS action if supported by the model
      const streamSvc =
        spec.services.find((s) =>
          s.actions.some((a) => a.type.includes("start-hls-stream"))
        ) ?? null;
      const act = streamSvc?.actions.find(
        (a) => a.type.includes("start-hls-stream")
      );
      if (streamSvc && act) {
        // macOS parity (MiCloudProvider.resolveCameraStream): the documented action carries
        // typed inputs; try the bare call, then the codec-index variant, and treat every
        // failure as "no cloud HLS" so the P2P bridge below still runs (#97).
        for (const inputs of [[], [1]]) {
          if (stale()) return;
          try {
            const res = await client.callAction({
              did: dev.id,
              siid: streamSvc.iid,
              aiid: act.iid,
              inputs,
            });
            if (stale()) return;
            const rawJson = JSON.stringify(res ?? {});
            const urlMatch = /https?:\/\/[^\s"'\\]+/i.exec(rawJson);
            if (urlMatch?.[0]) {
              const playable = this.normalizeWindowsCameraStreamUrl(urlMatch[0]);
              if (this.needsHlsTranscodeBridge(playable)) {
                if (await this.bridgeHlsStreamToMjpeg(dev.id, playable)) {
                  this.liveCameraQualityApplies = false;
                  return;
                }
                // Bridging failed: fall through to P2P below instead of assigning an unplayable .m3u8.
                break;
              }
              if (!/\.m3u8(\?|$|#)/i.test(playable) || !window.__TAURI_INTERNALS__?.invoke) {
                this.liveCameraQualityApplies = false;
                this.liveCameraStreamURL = playable;
                this.liveCameraError = null;
                this.liveCameraLoading = false;
                this.host.render();
                return;
              }
            }
          } catch {
            // Cloud HLS rejected (bad inputs / 403 / offline): fall back to P2P.
          }
        }
      }

      // 2. Release any previous P2P session, then wake a fresh one (siid=9 p2p-stream service)
      const p2pSvc = spec.services.find((s) =>
        s.actions.some((a) => a.type.includes("start-p2p-stream"))
      );
      const stopAct = p2pSvc?.actions.find((a) => a.type.includes("stop-stream"));
      const p2pAct = p2pSvc?.actions.find((a) => a.type.includes("start-p2p-stream"));
      if (p2pSvc && stopAct) {
        const released = await client
          .callAction({ did: dev.id, siid: p2pSvc.iid, aiid: stopAct.iid, inputs: [] })
          .then(() => true)
          .catch(() => false);
        if (stale()) return;
        // The camera needs a moment to actually free its single P2P session; requesting a
        // new one immediately yields a session that stalls after the first frame (measured
        // 0-14 fps vs 326 fps once the release settles).
        if (released) {
          await new Promise((resolve) => setTimeout(resolve, 2500));
        }
      }
      if (stale()) return;
      if (p2pSvc && p2pAct) {
        startedP2PSession = await client
          .callAction({ did: dev.id, siid: p2pSvc.iid, aiid: p2pAct.iid, inputs: [] })
          .then(() => true)
          .catch(() => false);
      }
      if (stale()) {
        if (this.activeLiveCameraId !== dev.id) releaseIfStarted();
        return;
      }

      // 3. Negotiate MISS CS2/TUTK P2P keys & start native Tauri bridge
      if (window.__TAURI_INTERNALS__?.invoke) {
        const listRes = (await client.request("home/device_list", {
          getVirtualModel: true,
          getHuamiDevices: 1,
          get_split_device: false,
          support_smart_home: true,
        })) as Record<string, unknown> | null;
        if (stale()) {
          if (this.activeLiveCameraId !== dev.id) releaseIfStarted();
          return;
        }
        const rawList = Array.isArray(listRes?.["list"]) ? (listRes["list"] as Array<Record<string, unknown>>) : [];
        const rawDev = rawList.find((item) => String(item["did"] ?? "") === dev.id);
        const localIp = typeof rawDev?.["localip"] === "string" ? rawDev["localip"] : "";
        if (localIp) {
          const kp = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair;
          const spki = new Uint8Array(await crypto.subtle.exportKey("spki", kp.publicKey));
          const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", kp.privateKey));
          const clientPublic = Array.from(spki.slice(-32)).map((b) => b.toString(16).padStart(2, "0")).join("");
          const clientPrivate = Array.from(pkcs8.slice(-32)).map((b) => b.toString(16).padStart(2, "0")).join("");

          const vendorRes = (await client.request("v2/device/miss_get_vendor", {
            did: dev.id,
            app_pubkey: clientPublic,
            support_vendors: "TUTK_CS2_MTP",
          })) as Record<string, unknown> | null;
          if (stale()) {
            if (this.activeLiveCameraId !== dev.id) releaseIfStarted();
            return;
          }
          const vendorObj = (vendorRes?.["vendor"] as Record<string, unknown> | undefined) ?? {};
          const vendorId = Number(vendorObj["vendor"] ?? 4);
          const vendorName = vendorId === 1 ? "tutk" : vendorId === 4 ? "cs2" : String(vendorId);
          const vendorParams = (vendorObj["vendor_params"] as Record<string, unknown> | undefined) ?? {};
          const p2pUid = typeof vendorParams["p2p_id"] === "string" ? vendorParams["p2p_id"] : null;
          const devicePublic = typeof vendorRes?.["public_key"] === "string" ? vendorRes["public_key"] : "";
          const sign = typeof vendorRes?.["sign"] === "string" ? vendorRes["sign"] : "";

          if (devicePublic && sign) {
            if (stale()) {
              if (this.activeLiveCameraId !== dev.id) releaseIfStarted();
              return;
            }
            this.liveCameraQualityApplies = true;
            const bridge = await window.__TAURI_INTERNALS__.invoke<string>("start_xiaomi_camera_bridge", {
              did: dev.id,
              model: dev.model,
              localIp,
              clientPublic,
              clientPrivate,
              devicePublic,
              sign,
              vendor: vendorName,
              uid: p2pUid,
              quality: this.cameraStreamQualities[dev.id] ?? DEFAULT_CAMERA_STREAM_QUALITY,
            });
            if (stale()) {
              // The close path already tore down once; this late start re-created a
              // relay and stream registrations that nothing else will reclaim. Undo
              // them — unless the same camera was re-opened, in which case the new
              // negotiation's own stop_bridge replaces them and must not be killed.
              if (this.activeLiveCameraId !== dev.id) {
                invokeTauriVoid("stop_xiaomi_camera_bridge", { did: dev.id });
                releaseIfStarted();
              }
              return;
            }
            const [h264Name, mjpegName] = (bridge ?? "").split("|");
            if (mjpegName) {
              this.liveCameraStreamURL = mjpegName;
              this.liveCameraError = null;
              this.liveCameraLoading = false;
              this.startMjpegTransport(mjpegName);
              this.host.render();
              this.attachLiveMedia();
              return;
            }
            if (h264Name) {
              this.liveCameraQualityApplies = false;
              releaseIfStarted();
              this.liveCameraStreamURL = h264Name;
              this.liveCameraError = t("实时画面连接失败，请点右上角重新连接");
              this.liveCameraLoading = false;
              this.host.render();
              return;
            }
            failureReason = t("本地视频桥接未返回可用流，请检查网络后重试");
          } else {
            failureReason = t("该摄像机型号暂不支持自动获取局域网 P2P 密钥，可在下方填写本地 go2rtc / HLS 流地址观看");
          }
        } else {
          failureReason = t("未获取到摄像机局域网 IP，请确认电脑与摄像机处于同一局域网");
        }
      }

      releaseIfStarted();
      this.liveCameraQualityApplies = false;
      this.liveCameraError = failureReason ?? t("米家云直连摄像头采用私有 P2P 加密流；可在下方填写本地 go2rtc / HLS 流地址观看实时画面");
    } catch (err) {
      releaseIfStarted();
      this.liveCameraQualityApplies = false;
      if (!stale()) {
        this.liveCameraError = err instanceof Error ? err.message : String(err);
      }
    }
    if (stale()) return;
    this.liveCameraLoading = false;
    this.host.render();
  }

  public renderCameraLiveModal(): string {
    const dev = this.host.devices.find((d) => d.id === this.activeLiveCameraId);
    if (!dev || dev.kind.kind !== "camera") return "";
    const k = dev.kind;
    const id = this.host.escapeHtml(dev.id);
    const customURL = this.cameraStreamURLs[dev.id] ?? "";
    const isNight = k.nightShot?.toLowerCase() === "on";
    const motionOn = Boolean(k.isMotionDetectionOn);

    let viewportHtml = "";
    if (!k.isOn) {
      const canWake = k.powerWritable !== false;
      viewportHtml = `
        <div class="cc-camera-stage is-sleeping">
          <strong>${t("摄像机处于物理休眠状态")}</strong>
          ${
            canWake
              ? `<p>${t("镜头已遮蔽，点击下方唤醒后即可查看实时画面")}</p>
          <button class="cc-btn-primary" data-toggle-device="${id}">${t("唤醒镜头并观看")}</button>`
              : ""
          }
        </div>
      `;
    } else if (this.liveCameraMode) {
      // The media element is created once and re-attached here, so polling renders never
      // restart the stream.
      viewportHtml = `<div class="cc-camera-stage" id="cc-camera-stage"></div>`;
    } else if (this.liveCameraLoading) {
      viewportHtml = `
        <div class="cc-camera-stage" style="padding:28px 16px;text-align:center;">
          <strong>${t("正在握手并连接摄像机实时画面…")}</strong>
        </div>
      `;
    } else if (this.liveCameraStreamURL && this.isOwnedGo2rtcApiUrl(this.liveCameraStreamURL)) {
      viewportHtml = `
        <div class="cc-camera-stage" style="padding:28px 16px;text-align:center;">
          <strong>${t("正在握手并连接摄像机实时画面…")}</strong>
        </div>
      `;
    } else if (this.liveCameraStreamURL && /^https?:/i.test(this.liveCameraStreamURL)) {
      const safeURL = this.host.escapeHtml(this.liveCameraStreamURL);
      const isImg = /\.(jpg|jpeg|png)|snapshot|camera_proxy|frame\.jpeg|mjpeg/i.test(this.liveCameraStreamURL);
      viewportHtml = isImg
        ? `<div class="cc-camera-stage"><img id="cc-camera-live-img" src="${safeURL}" alt="${this.host.escapeHtml(dev.name)}" style="max-width:100%;border-radius:10px;" /></div>`
        : `<div class="cc-camera-stage"><video id="cc-camera-video" src="${safeURL}" controls autoplay muted playsinline preload="auto" style="width:100%;border-radius:10px;background:#090d16;"></video></div>`;
    } else if (this.host.settings.connectionMode === "demo") {
      viewportHtml = `
        <div class="cc-camera-stage is-demo" style="padding:18px;border-radius:12px;background:${isNight ? "linear-gradient(135deg,#072219,#03110c)" : "linear-gradient(135deg,#10233d,#091224)"};color:#fff;text-align:center;">
          <div style="display:flex;justify-content:space-between;font-size:11px;opacity:0.85;margin-bottom:16px;">
            <span>● ${isNight ? "LIVE · IR NIGHT 2K" : "LIVE · 2K HDR · 25fps"}</span>
            <span>${this.host.escapeHtml(dev.roomName)}</span>
          </div>
          <div style="padding:20px 8px;">
            <div style="width:36px;height:36px;margin:0 auto 10px;color:${isNight ? "#4ade80" : "#38bdf8"};">${SF_ICONS.videoFill}</div>
            <strong style="display:block;font-size:14px;margin-bottom:4px;">${this.host.escapeHtml(dev.name)} · ${t("实时看护小窗预览")}</strong>
            <small style="opacity:0.76;">${motionOn ? t("AI 移动与看护侦测中 · 画面正常") : t("实时画面流已就绪 · 窗口已置顶")}</small>
          </div>
        </div>
      `;
    } else {
      viewportHtml = `
        <div class="cc-camera-stage is-error" style="padding:16px;text-align:center;">
          <p style="margin-bottom:10px;">${this.host.escapeHtml(this.liveCameraError ?? t("可配置本地 go2rtc / HLS 流地址观看实时画面"))}</p>
          <div style="display:flex;gap:8px;justify-content:center;flex-wrap:wrap;">
            <button class="cc-btn-secondary" id="btn-toggle-camera-url">${t("填写 go2rtc / HLS 流地址")}</button>
            <button class="cc-btn-secondary" id="btn-copy-camera-diag">${t("复制诊断")}</button>
          </div>
        </div>
      `;
    }

    return `
      <div class="cc-sheet-backdrop" ${this.liveCameraHidden ? 'style="display:none"' : ""}>
        <div class="cc-sheet cc-camera-live-sheet" role="dialog" aria-modal="true" aria-label="${this.host.escapeHtml(dev.name)} ${t("实时画面")}">
          <div class="cc-sheet-header">
            <strong>${this.host.escapeHtml(dev.name)} · ${t("实时画面小窗")}</strong>
            <div style="display:flex;gap:6px;">
              <button class="cc-circle-btn is-small" id="btn-reload-camera-live" title="${t("重新连接")}" aria-label="${t("重新连接")}">${SF_ICONS.arrowClockwise}</button>
              <button class="cc-circle-btn is-small" id="btn-toggle-camera-url" title="${t("配置流地址")}">🔗</button>
              <button class="cc-circle-btn is-small" id="btn-close-camera-live" title="${t("关闭画面")}" aria-label="${t("关闭画面")}">
                ${SF_ICONS.xmark}
              </button>
            </div>
          </div>
          ${
            this.liveCameraShowingURLInput
              ? `<div class="cc-field" style="margin-bottom:10px;">
                  <input id="camera-stream-url-input" class="cc-input" type="text" value="${this.host.escapeHtml(customURL)}" placeholder="http://127.0.0.1:<port>/api/stream.m3u8?src=camera" />
                  <div style="display:flex;gap:6px;margin-top:6px;">
                    <button class="cc-btn-primary" id="btn-save-camera-url">${t("连接流地址")}</button>
                  </div>
                </div>`
              : ""
          }
          ${viewportHtml}
          ${
            this.host.settings.connectionMode === "xiaomiCloud" && !customURL && this.liveCameraQualityApplies && !this.liveCameraLoading
              ? `<div class="cc-segmented-pills" style="margin-top:10px;">
                  <span class="cc-pill-label">${t("画质")}</span>
                  ${CAMERA_STREAM_QUALITIES.map((quality) => {
                    const selected = (this.cameraStreamQualities[dev.id] ?? DEFAULT_CAMERA_STREAM_QUALITY) === quality;
                    return `<button class="cc-seg-pill ${selected ? "is-active" : ""}" data-cameraquality="${id}" data-cameraquality-value="${quality}" aria-pressed="${selected}">
                      ${t(CAMERA_QUALITY_TITLES[quality])}
                    </button>`;
                  }).join("")}
                </div>`
              : ""
          }
          <div class="cc-segmented-pills" style="margin-top:12px;">
            ${k.powerWritable === false ? "" : `<button class="cc-seg-pill ${!k.isOn ? "is-active" : ""}" data-toggle-device="${id}" aria-pressed="${!k.isOn}">
              ${k.isOn ? t("镜头休眠") : t("唤醒镜头")}
            </button>`}
            ${
              k.motionDetectionEntityId
                ? `<button class="cc-seg-pill ${motionOn ? "is-active" : ""}" data-cameramotion="${id}" aria-pressed="${motionOn}">
                    ${motionOn ? t("移动侦测：开") : t("移动侦测：关")}
                  </button>`
                : ""
            }
            ${k.availableNightShots
              .map(
                (mode) => `<button class="cc-seg-pill ${k.nightShot === mode ? "is-active" : ""}" data-cameranight="${id}:${this.host.escapeHtml(mode)}" aria-pressed="${k.nightShot === mode}">
                  ${this.host.escapeHtml(localizeNightShot(mode))}
                </button>`
              )
              .join("")}
          </div>
        </div>
      </div>
    `;
  }

  public async commitCameraStreamUrl(): Promise<void> {
    const id = this.activeLiveCameraId;
    if (!id) return;
    const input = this.host.root.querySelector<HTMLInputElement>("#camera-stream-url-input");
    const val = input?.value.trim() ?? "";
    this.stopLiveTransport();
    const token = this.liveCameraToken;
    await this.refreshOwnedGo2rtcOrigin();
    const stillViewing = this.liveCameraToken === token && this.activeLiveCameraId === id;
    if (val) this.cameraStreamURLs[id] = val;
    else delete this.cameraStreamURLs[id];
    this.host.settings.cameraStreamURLs = { ...this.cameraStreamURLs };
    this.host.saveSettings();
    if (!stillViewing) return;
    if (val) {
      const playable = this.normalizeWindowsCameraStreamUrl(val);
      this.liveCameraStreamURL = playable;
      this.liveCameraError = null;
      this.liveCameraLoading = false;
      const dev = this.host.devices.find((d) => d.id === id);
      const ownedSrc = this.ownedGo2rtcStreamName(playable);
      if (dev && dev.kind.kind === "camera" && dev.kind.isOn && ownedSrc) {
        this.liveCameraStreamURL = ownedSrc;
        this.startMjpegTransport(ownedSrc);
      } else if (dev && dev.kind.kind === "camera" && dev.kind.isOn && this.needsHlsTranscodeBridge(playable)) {
        void this.bridgeHlsStreamToMjpeg(id, playable);
      }
    } else {
      const dev = this.host.devices.find((d) => d.id === id);
      this.liveCameraStreamURL = dev ? this.resolveHaCameraStreamUrl(dev) : null;
      if (dev && dev.kind.kind === "camera" && dev.kind.isOn) {
        if (this.liveCameraStreamURL && this.needsHlsTranscodeBridge(this.liveCameraStreamURL)) {
          void this.bridgeHlsStreamToMjpeg(id, this.liveCameraStreamURL);
        } else if (!this.liveCameraStreamURL && this.host.settings.connectionMode === "xiaomiCloud") {
          void this.resolveCloudCameraStream(dev);
        }
      }
    }
    this.liveCameraShowingURLInput = false;
    this.host.render();
    if (this.liveCameraMode === "mjpeg") this.attachLiveMedia();
  }

  // MARK: Layout editing

  bindEvents(): void {
    this.host.root.querySelector("#btn-close-camera-live")?.addEventListener("click", () => {
      this.hideCameraLiveView();
    });

    this.host.root.querySelector("#btn-reload-camera-live")?.addEventListener("click", () => {
      this.reconnectCameraLiveView();
    });

    this.host.root.querySelectorAll<HTMLElement>("[data-cameraquality]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const deviceId = btn.dataset.cameraquality ?? "";
        const dev = this.host.devices.find((d) => d.id === deviceId);
        if (!dev || dev.kind.kind !== "camera") return;
        const quality = normalizeCameraStreamQuality(btn.dataset.cameraqualityValue);
        if (quality === (this.cameraStreamQualities[deviceId] ?? DEFAULT_CAMERA_STREAM_QUALITY)) return;
        this.setCameraStreamQuality(deviceId, quality);
        this.reconnectCameraLiveView();
      });
    });

    this.attachLiveMedia();

    this.host.root.querySelectorAll<HTMLElement>("#btn-toggle-camera-url").forEach((btn) => {
      btn.addEventListener("click", () => {
        this.liveCameraShowingURLInput = !this.liveCameraShowingURLInput;
        this.host.render();
      });
    });

    this.host.root.querySelector("#btn-copy-camera-diag")?.addEventListener("click", () => {
      const dev = this.host.devices.find((d) => d.id === this.activeLiveCameraId);
      if (!dev || dev.kind.kind !== "camera") return;
      const redact = (raw: string) =>
        raw
          .replace(/https?:\/\/[^\s"'<>]+/gi, "<redacted-url>")
          .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, "<redacted-ip>")
          .replace(/\b[0-9a-fA-F]{24,}\b/g, "<redacted-token>");
      const report = [
        "MenuBarMijia Camera Diagnostics (Windows)",
        `model: ${dev.model}`,
        `online: ${dev.isOnline}`,
        `isOn: ${dev.kind.isOn}`,
        `connectionMode: ${this.host.settings.connectionMode}`,
        `hasCustomURL: ${Boolean(this.cameraStreamURLs[dev.id])}`,
        `error: ${redact(this.liveCameraError ?? "none")}`,
      ].join("\n");
      void navigator.clipboard?.writeText(report).catch(() => {});
      this.host.replyBanner = { text: t("已复制脱敏诊断信息"), source: t("摄像机诊断") };
      this.host.render();
    });

    this.host.root.querySelector("#btn-save-camera-url")?.addEventListener("click", () => {
      void this.commitCameraStreamUrl();
    });
  }

}
