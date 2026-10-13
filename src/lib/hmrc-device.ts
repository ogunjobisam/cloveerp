import type { ClientFacts } from "./hmrc-mtd";

/**
 * What HMRC requires to know about the device a VAT return is filed from
 * (Gov-Client-* fraud prevention headers, WEB_APP_VIA_SERVER), read in the
 * browser as the person presses and sent to the HMRC function, which adds what
 * only the server sees. Nothing here is kept but the device's own identifier,
 * which HMRC asks to be generated once and kept.
 */
const DEVICE_KEY = "clove-erp.hmrc-device-id";

let fallbackId: string | null = null;

function deviceId(): string {
  try {
    const kept = window.localStorage.getItem(DEVICE_KEY);
    if (kept && /^[0-9a-f-]{36}$/i.test(kept)) return kept;
    const made = crypto.randomUUID();
    window.localStorage.setItem(DEVICE_KEY, made);
    return made;
  } catch {
    // A browser that keeps nothing: one identifier for this page's life.
    fallbackId ??= crypto.randomUUID();
    return fallbackId;
  }
}

export function clientFacts(): ClientFacts {
  return {
    deviceId: deviceId(),
    userAgent: navigator.userAgent,
    screens: [
      {
        width: window.screen.width,
        height: window.screen.height,
        scalingFactor: window.devicePixelRatio || 1,
        colourDepth: window.screen.colorDepth || 24,
      },
    ],
    window: { width: window.innerWidth, height: window.innerHeight },
    utcOffsetMinutes: -new Date().getTimezoneOffset(),
  };
}
