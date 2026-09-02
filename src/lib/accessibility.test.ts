import { describe, expect, test } from "bun:test";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

/**
 * Specification v1.2 Part 21, the half of it a build can check.
 *
 * The accessibility statement lives in the database (erp_ref.accessibility_criterion)
 * and says, per WCAG 2.2 A and AA criterion, whether the product meets it and
 * how. A statement is only worth the checking behind it, so this file is the
 * checking: the contrast ratios are computed from the design tokens in
 * styles.css rather than asserted from memory, and the source is swept for
 * the patterns that break a criterion silently — a control with no
 * accessible name, a field with no label, a table header with no scope, a
 * page with no title.
 *
 * These are the checks that were true on the day the statement was written.
 * The point of running them on every build is that the statement stays true
 * on the day somebody reads it.
 */

const ROOT = join(import.meta.dir, "..");
const STYLES = readFileSync(join(ROOT, "styles.css"), "utf8");

// ── Colour ──────────────────────────────────────────────────────────────────

type Rgb = [number, number, number];

/** oklch → linear sRGB, per the CSS Color 4 reference conversion. */
function oklch(L: number, C: number, h: number): Rgb {
  const a = C * Math.cos((h * Math.PI) / 180);
  const b = C * Math.sin((h * Math.PI) / 180);
  const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = L - 0.0894841775 * a - 1.291485548 * b;
  const l = l_ ** 3;
  const m = m_ ** 3;
  const s = s_ ** 3;
  const clamp = (x: number) => Math.max(0, Math.min(1, x));
  return [
    clamp(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    clamp(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    clamp(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s),
  ];
}

function blend(fg: Rgb, alpha: number, bg: Rgb): Rgb {
  return [0, 1, 2].map((i) => alpha * fg[i]! + (1 - alpha) * bg[i]!) as Rgb;
}

function luminance([r, g, b]: Rgb): number {
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** WCAG 2.x contrast ratio between two colours, both already linear sRGB. */
export function contrast(a: Rgb, b: Rgb): number {
  const la = luminance(a);
  const lb = luminance(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

/** Reads `--name: oklch(L C h)` or `oklch(L C h / alpha)` from styles.css. */
function token(name: string): { rgb: Rgb; alpha: number } {
  const m = new RegExp(
    `--${name}:\\s*oklch\\(\\s*([0-9.]+)\\s+([0-9.]+)\\s+([0-9.]+)(?:\\s*/\\s*([0-9.]+))?\\s*\\)`,
  ).exec(STYLES);
  if (!m) throw new Error(`styles.css has no oklch token --${name}`);
  return {
    rgb: oklch(Number(m[1]), Number(m[2]), Number(m[3])),
    alpha: m[4] === undefined ? 1 : Number(m[4]),
  };
}

const surface = token("surface").rgb;
const card = token("card-surface").rgb;
const soft = token("soft").rgb;

describe("1.4.3 contrast (minimum): every text token clears 4.5:1 on the surfaces it is used on", () => {
  const text = ["ink", "ink-muted", "destructive", "ok", "warn", "accent"] as const;
  for (const name of text) {
    for (const [bgName, bg] of [
      ["surface", surface],
      ["card", card],
    ] as const) {
      test(`${name} on ${bgName}`, () => {
        const t = token(name);
        expect(contrast(blend(t.rgb, t.alpha, bg), bg)).toBeGreaterThanOrEqual(4.5);
      });
    }
  }

  test("muted ink on the soft surface, which is what a muted pill is", () => {
    const t = token("ink-muted");
    expect(contrast(blend(t.rgb, t.alpha, soft), soft)).toBeGreaterThanOrEqual(4.5);
  });

  test("the primary button's text on the brand colour", () => {
    expect(contrast(surface, token("brand").rgb)).toBeGreaterThanOrEqual(4.5);
  });

  test("the accent's foreground on the accent, which a hovered tile icon is", () => {
    expect(contrast(surface, token("accent").rgb)).toBeGreaterThanOrEqual(4.5);
  });

  test("a destructive note's text on its tinted background", () => {
    const d = token("destructive").rgb;
    expect(contrast(d, blend(d, 0.05, card))).toBeGreaterThanOrEqual(4.5);
  });
});

describe("1.4.11 non-text contrast: control boundaries and the focus ring clear 3:1", () => {
  test("the input border against the card and the page", () => {
    const line = token("input-line").rgb;
    expect(contrast(line, card)).toBeGreaterThanOrEqual(3);
    expect(contrast(line, surface)).toBeGreaterThanOrEqual(3);
  });

  test("the focus ring, which is the accent, against the card and the page", () => {
    const accent = token("accent").rgb;
    expect(contrast(accent, card)).toBeGreaterThanOrEqual(3);
    expect(contrast(accent, surface)).toBeGreaterThanOrEqual(3);
  });
});

// ── Source sweeps ───────────────────────────────────────────────────────────

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (p.endsWith(".tsx")) out.push(p);
  }
  return out;
}

/** The product's own components and routes. components/ui is the shadcn
 *  kit, which carries its own accessibility and is not rewritten here. */
const SOURCES = walk(ROOT).filter((p) => !p.includes("/components/ui/"));

function read(p: string): string {
  return readFileSync(p, "utf8");
}

function rel(p: string): string {
  return p.slice(ROOT.length + 1);
}

/** Every `<tag …>…</tag>` element in a file, with the attributes and inner
 *  text. Regex over JSX is approximate, and approximate is enough: a
 *  false positive is a named control somebody looks at, a false negative
 *  is caught by the manual pass the statement records. */
function elements(source: string, tag: string): { attrs: string; inner: string }[] {
  const out: { attrs: string; inner: string }[] = [];
  const open = new RegExp(`<${tag}\\b([^>]*?)(/?)>`, "g");
  let m: RegExpExecArray | null;
  while ((m = open.exec(source)) !== null) {
    if (m[2] === "/") {
      out.push({ attrs: m[1] ?? "", inner: "" });
      continue;
    }
    const close = source.indexOf(`</${tag}>`, open.lastIndex);
    out.push({ attrs: m[1] ?? "", inner: close < 0 ? "" : source.slice(open.lastIndex, close) });
  }
  return out;
}

/** Text a screen reader would announce from JSX content: literal words, or
 *  an expression that carries them. */
function hasAccessibleContent(inner: string): boolean {
  const withoutTags = inner.replace(/<[^>]+>/g, " ");
  // Literal words between the tags.
  if (/[A-Za-z]{2,}/.test(withoutTags.replace(/\{[^}]*\}/g, " "))) return true;
  // A string literal inside an expression: {busy ? "Saving…" : "Save"}.
  if (/\{[^}]*["'`][^"'`]*[A-Za-z]{2,}[^"'`]*["'`][^}]*\}/.test(withoutTags)) return true;
  // {label}, {children}, {t("…")}, {ui("…")} — an expression that renders text.
  return /\{\s*(children|label|title|name|t\(|ui\(|r\.|row\.|c\.|item\.)/.test(inner);
}

describe("4.1.2 name, role, value: every control has an accessible name", () => {
  test("a <button> carries text or an aria-label", () => {
    const bare: string[] = [];
    for (const p of SOURCES) {
      for (const b of elements(read(p), "button")) {
        if (/aria-label(ledby)?=/.test(b.attrs)) continue;
        if (!hasAccessibleContent(b.inner)) bare.push(`${rel(p)}: <button${b.attrs.trim()}>`);
      }
    }
    expect(bare).toEqual([]);
  });

  test("an <img> carries an alt attribute", () => {
    const bare: string[] = [];
    for (const p of SOURCES) {
      for (const i of elements(read(p), "img")) {
        if (!/\balt=/.test(i.attrs)) bare.push(`${rel(p)}: <img${i.attrs.trim()}>`);
      }
    }
    expect(bare).toEqual([]);
  });
});

describe("1.3.1 and 3.3.2: every field has a label", () => {
  test("an <input>, <select> or <textarea> sits inside a <label> or names one", () => {
    const bare: string[] = [];
    for (const p of SOURCES) {
      const src = read(p);
      const re = /<(input|select|textarea)\b([^>]*?)\/?>/g;
      let m: RegExpExecArray | null;
      while ((m = re.exec(src)) !== null) {
        const attrs = m[2] ?? "";
        if (/aria-label(ledby)?=|\bid=/.test(attrs)) continue;
        if (/type="hidden"/.test(attrs)) continue;
        const before = src.slice(0, m.index);
        const opened = (before.match(/<label\b/g) ?? []).length;
        const closed = (before.match(/<\/label>/g) ?? []).length;
        if (opened <= closed) bare.push(`${rel(p)}: <${m[1]}${attrs.trim()}>`);
      }
    }
    expect(bare).toEqual([]);
  });
});

describe("1.3.1 tables: a column header says it is one", () => {
  test("every <th> in the product's components carries scope", () => {
    const bare: string[] = [];
    for (const p of SOURCES) {
      for (const h of elements(read(p), "th")) {
        if (!/\bscope=/.test(h.attrs)) bare.push(`${rel(p)}: <th${h.attrs.trim()}>`);
      }
    }
    expect(bare).toEqual([]);
  });
});

describe("2.4.2 page titled: every route sets a title", () => {
  test("a file that creates a route names its page in head()", () => {
    const untitled: string[] = [];
    for (const p of SOURCES.filter((x) => x.includes("/routes/"))) {
      const src = read(p);
      if (!/createFileRoute\(/.test(src)) continue;
      if (/createRootRouteWithContext/.test(src)) continue;
      if (!/title:\s*(["'`]|[A-Z_]+\b)/.test(src)) untitled.push(rel(p));
    }
    expect(untitled).toEqual([]);
  });
});

describe("the shell's mechanics are present", () => {
  const shell = read(join(ROOT, "components/erp/shell.tsx"));
  const root = read(join(ROOT, "routes/__root.tsx"));

  test("2.4.1 a skip link to the main landmark", () => {
    expect(shell).toMatch(/href="#main"/);
    expect(shell).toMatch(/<main id="main"/);
  });

  test("navigation landmarks are named and the current page is marked", () => {
    expect(shell).toMatch(/<nav[^>]*aria-label=/);
    expect(shell).toMatch(/aria-current=\{active \? "page" : undefined\}/);
  });

  test("3.1.1 the document declares its language", () => {
    expect(root).toMatch(/<html lang="en">/);
  });

  test("2.4.7 a visible focus indicator is defined once, for keyboard focus", () => {
    expect(STYLES).toMatch(/:focus-visible\s*\{[^}]*outline:\s*2px solid var\(--accent\)/);
  });

  test("2.3.3 motion follows the reduced-motion preference", () => {
    expect(STYLES).toMatch(/prefers-reduced-motion:\s*reduce/);
  });

  test("2.4.11 a focused control is not hidden behind the sticky header", () => {
    expect(STYLES).toMatch(/scroll-padding-top/);
  });

  test("1.4.11 no product component removes the outline without replacing it", () => {
    const offenders: string[] = [];
    for (const p of SOURCES) {
      const src = read(p);
      const re = /className=\{?["'`][^"'`]*\boutline-none\b[^"'`]*["'`]/g;
      let m: RegExpExecArray | null;
      while ((m = re.exec(src)) !== null) {
        if (!/focus-visible:/.test(m[0]) && !/tabIndex=\{-1\}/.test(src)) {
          offenders.push(`${rel(p)}: ${m[0].slice(0, 80)}`);
        }
      }
    }
    expect(offenders).toEqual([]);
  });
});
