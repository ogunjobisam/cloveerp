import { useEffect } from "react";

import { useT } from "./i18n";

/**
 * Per-tenant branding.
 *
 * There is no new table for this. Branding is wording and two colours, and
 * wording already has a tenant-scoped store: `erp.resource_override`, layered
 * over the shipped `erp_ref.resource` rows by `erp_resources()`. A tenant that
 * is not called Clove ERP overrides five keys; a tenant that is overrides none
 * and gets the product identity from the spec.
 */
export const BRAND_KEYS = {
  prefix: "brand.name.prefix",
  suffix: "brand.name.suffix",
  ink: "brand.color.ink",
  total: "brand.color.total",
  logo: "brand.logo.url",
} as const;

export const BRAND_DEFAULTS = {
  prefix: "Clove",
  suffix: " ERP",
  /** Ink — warm near-black, the entries. */
  ink: "#3F3A34",
  /** Amber — the derived total. */
  total: "#C2703D",
  logo: "",
} as const;

export type Brand = {
  prefix: string;
  suffix: string;
  ink: string;
  total: string;
  /** An absolute image URL, when a tenant supplies its own mark. */
  logo: string;
  /** The full wordmark as one string, for titles and alt text. */
  name: string;
  /** True when nothing has been overridden for this tenant. */
  isDefault: boolean;
};

const HEX = /^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/;

function colour(value: string, fallback: string): string {
  return HEX.test(value.trim()) ? value.trim() : fallback;
}

export function useBrand(): Brand {
  const { t } = useT();

  const prefix = t(BRAND_KEYS.prefix, BRAND_DEFAULTS.prefix);
  const suffix = t(BRAND_KEYS.suffix, BRAND_DEFAULTS.suffix);
  const ink = colour(t(BRAND_KEYS.ink, BRAND_DEFAULTS.ink), BRAND_DEFAULTS.ink);
  const total = colour(t(BRAND_KEYS.total, BRAND_DEFAULTS.total), BRAND_DEFAULTS.total);
  const logo = t(BRAND_KEYS.logo, BRAND_DEFAULTS.logo).trim();

  return {
    prefix,
    suffix,
    ink,
    total,
    logo: /^https?:\/\//.test(logo) ? logo : "",
    name: `${prefix}${suffix}`,
    isDefault:
      prefix === BRAND_DEFAULTS.prefix &&
      suffix === BRAND_DEFAULTS.suffix &&
      ink === BRAND_DEFAULTS.ink &&
      total === BRAND_DEFAULTS.total &&
      logo === "",
  };
}

function faviconSvg(ink: string, total: string): string {
  return [
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">',
    `<rect width="32" height="32" rx="7" fill="${ink}"/>`,
    '<rect x="4" y="6" width="14" height="4" rx="2" fill="#F5F1E8"/>',
    '<rect x="4" y="13" width="20" height="4" rx="2" fill="#F5F1E8"/>',
    `<rect x="4" y="22" width="24" height="5" rx="2.5" fill="${total}"/>`,
    "</svg>",
  ].join("");
}

/**
 * Point the tab icon and title at the tenant's identity.
 *
 * Only where supported: an SVG favicon is a data URI the browser accepts, and
 * a tenant-supplied raster is used as-is. Safari's older icon handling ignores
 * both, which is why the static `/favicon.svg` stays in the document as the
 * thing this replaces rather than something it needs.
 */
export function useBrandedFavicon(brand: Brand): void {
  useEffect(() => {
    if (typeof document === "undefined") return;

    const href = brand.logo
      ? brand.logo
      : `data:image/svg+xml,${encodeURIComponent(faviconSvg(brand.ink, brand.total))}`;

    let link = document.querySelector<HTMLLinkElement>('link[data-brand="tenant"]');
    if (!link) {
      link = document.createElement("link");
      link.rel = "icon";
      link.dataset["brand"] = "tenant";
      document.head.appendChild(link);
    }
    if (!brand.logo) link.type = "image/svg+xml";
    else link.removeAttribute("type");
    link.href = href;
  }, [brand.ink, brand.total, brand.logo]);
}
