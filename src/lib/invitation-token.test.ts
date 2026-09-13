import { afterEach, describe, expect, test } from "bun:test";

import {
  INVITATION_STORAGE_KEY,
  clearStoredInvitation,
  readStoredInvitation,
  storeInvitation,
} from "./invitation-token";

const TOKEN = "0123456789abcdef".repeat(4);
const g = globalThis as unknown as { window?: unknown };

function withStorage(storage: Partial<Storage>) {
  g.window = { sessionStorage: storage };
}

function memory(): Storage {
  const data = new Map<string, string>();
  return {
    getItem: (k: string) => data.get(k) ?? null,
    setItem: (k: string, v: string) => void data.set(k, v),
    removeItem: (k: string) => void data.delete(k),
    clear: () => data.clear(),
    key: () => null,
    get length() {
      return data.size;
    },
  } as Storage;
}

afterEach(() => {
  delete g.window;
});

describe("the held invitation", () => {
  test("is nothing, and throws nothing, where there is no window", () => {
    expect(readStoredInvitation()).toBeNull();
    expect(() => storeInvitation(TOKEN)).not.toThrow();
    expect(() => clearStoredInvitation()).not.toThrow();
  });

  test("round-trips through session storage under its one key", () => {
    const storage = memory();
    withStorage(storage);
    storeInvitation(TOKEN);
    expect(storage.getItem(INVITATION_STORAGE_KEY)).toBe(TOKEN);
    expect(readStoredInvitation()).toBe(TOKEN);
    clearStoredInvitation();
    expect(readStoredInvitation()).toBeNull();
  });

  test("keeps rubbish out rather than redeeming it", () => {
    const storage = memory();
    withStorage(storage);
    storeInvitation("short");
    storeInvitation("<script>".repeat(8));
    expect(storage.getItem(INVITATION_STORAGE_KEY)).toBeNull();
    storage.setItem(INVITATION_STORAGE_KEY, "not a token at all");
    expect(readStoredInvitation()).toBeNull();
  });

  test("survives storage that refuses to be touched", () => {
    withStorage({
      getItem: () => {
        throw new Error("blocked");
      },
      setItem: () => {
        throw new Error("blocked");
      },
      removeItem: () => {
        throw new Error("blocked");
      },
    });
    expect(() => storeInvitation(TOKEN)).not.toThrow();
    expect(readStoredInvitation()).toBeNull();
    expect(() => clearStoredInvitation()).not.toThrow();
  });
});
