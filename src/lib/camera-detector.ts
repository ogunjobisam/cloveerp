import { CAMERA_FORMATS, type CameraRead } from "./camera-scan";

/**
 * What reads barcodes out of a camera's frames.
 *
 * The browser's own BarcodeDetector where it has one that reads Code 128 and
 * DataMatrix (Chrome on Android does). Otherwise, an iPhone among them, the
 * same API from barcode-detector, which decodes with ZXing compiled to
 * WebAssembly: loaded only then, and its WebAssembly served from this site
 * rather than the CDN the library would fetch it from by default, so a
 * scanner never depends on a third party being up.
 */

export type Detector = { detect(source: ImageBitmapSource): Promise<CameraRead[]> };

type NativeDetectorClass = {
  new (options: { formats: string[] }): Detector;
  getSupportedFormats(): Promise<string[]>;
};

export async function makeDetector(): Promise<Detector> {
  const native = (globalThis as { BarcodeDetector?: NativeDetectorClass }).BarcodeDetector;
  if (native) {
    try {
      const supported = await native.getSupportedFormats();
      const formats = CAMERA_FORMATS.filter((f) => supported.includes(f));
      if (formats.includes("code_128") && formats.includes("data_matrix")) {
        return new native({ formats });
      }
    } catch {
      // A detector that cannot say what it reads is treated as none.
    }
  }
  const [{ BarcodeDetector, prepareZXingModule }, { default: wasmUrl }] = await Promise.all([
    import("barcode-detector/ponyfill"),
    import("zxing-wasm/reader/zxing_reader.wasm?url"),
  ]);
  prepareZXingModule({
    overrides: {
      locateFile: (path: string, prefix: string) =>
        path.endsWith(".wasm") ? wasmUrl : prefix + path,
    },
  });
  return new BarcodeDetector({ formats: [...CAMERA_FORMATS] });
}

/** Whether this browser can be asked for a camera at all. */
export function cameraAvailable(): boolean {
  return (
    typeof navigator !== "undefined" && typeof navigator.mediaDevices?.getUserMedia === "function"
  );
}
