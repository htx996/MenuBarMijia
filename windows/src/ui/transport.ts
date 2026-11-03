import type { HttpRequest, HttpResponse, HttpTransport } from "../core/miCloudClient.js";

export function createTransport(): HttpTransport {
  return async (req: HttpRequest): Promise<HttpResponse> => {
    if (window.__TAURI_INTERNALS__?.invoke) {
      return window.__TAURI_INTERNALS__.invoke<HttpResponse>("native_http", {
        url: req.url,
        method: req.method ?? "GET",
        headers: req.headers ?? {},
        body: req.body ?? null,
        followRedirects: req.followRedirects ?? true,
        timeoutMs: req.timeoutMs ?? 15000,
      });
    }
    const response = await fetch(req.url, {
      method: req.method ?? "GET",
      headers: req.headers,
      body: req.body,
    });
    const headers: Record<string, string> = {};
    response.headers.forEach((value, key) => {
      headers[key.toLowerCase()] = value;
    });
    return {
      status: response.status,
      headers,
      body: await response.text(),
    };
  };
}

export function invokeTauriVoid(cmd: string, args?: Record<string, unknown>): void {
  if (window.__TAURI_INTERNALS__?.invoke) {
    void window.__TAURI_INTERNALS__.invoke(cmd, args);
  }
}
