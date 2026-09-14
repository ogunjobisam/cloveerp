/**
 * The one layout every email from Clove ERP is written in.
 *
 * Three senders had three copies of the same table, palette and escaping: the
 * invitation (src/lib/invitation-email.ts), the enquiry notice
 * (supabase/functions/enquiry) and nothing at all for the notifications the
 * dispatch worker sends, which went out as a sentence and a bare address. A
 * person asked to approve a purchase order was told "A document is waiting for
 * your approval" and not which one, for how much, or why them.
 *
 * So one function takes what an email has to say — the ask in one line, why it
 * is being asked, the facts it rests on, what to press — and returns the HTML
 * and the text of the same message. Every sender fills the same shape, so every
 * email reads the same way and is escaped in one place.
 *
 * Three runtimes read this file: the desk under Vite and Bun, the dispatch
 * worker under Bun (and through it the dispatch Edge Function under Deno), and
 * the invite and enquiry Edge Functions under Deno. So it imports nothing and
 * touches no process, window, Deno or import.meta — only the language and Intl.
 *
 * The rules the markup keeps, and why:
 *
 *   - Tables and inline styles. Outlook on Windows lays HTML out with Word, and
 *     several Gmail clients drop a <style> block, so nothing depends on one.
 *     The <style> block below only adds a dark palette where a client honours
 *     prefers-color-scheme.
 *   - No images, fonts, stylesheets or tracking. Remote content is blocked by
 *     default for a first message, and an email that needs it to make sense is
 *     an email that did not arrive. The only addresses in the message are the
 *     ones the reader is meant to open.
 *   - Every colour is set on a cell with a background of its own, and none is
 *     pure white on transparent: a client that inverts for dark mode then
 *     inverts both together instead of leaving white text on white.
 *   - Buttons are table cells at least 44px tall, and every action is repeated
 *     as a plain address, because a button is an image of a link to some
 *     clients and nothing at all to others.
 *   - Everything a tenant or a visitor typed is escaped here, and squeezed onto
 *     one line where it sits in a line. The subject is not this file's concern:
 *     it goes in a header, and only product words and system identifiers belong
 *     there (see invitation-email.ts).
 */

export type EmailAction = {
  label: string;
  /** Used verbatim as the href, escaped for the attribute. */
  url: string;
};

export type EmailDetail = {
  label: string;
  value: string;
  /** Makes the value a link. */
  url?: string | null;
  /** A block of machine text, such as an error, shown as it was written. */
  monospace?: boolean;
};

/** The layout's own words, for a sender that has them in another language. */
export type LayoutWords = {
  /** Above the plain addresses. */
  fallback: string;
  /** The preferences link. */
  preferences: string;
  /** Said instead of the preferences link when the email cannot be switched off. */
  mandatory: string;
};

export type EmailInput = {
  /** The organisation the email is about, shown beside the wordmark. */
  organisation?: string | null;
  /** The HTML document's title; the heading when absent. */
  title?: string | null;
  /** The html lang attribute. */
  lang?: string | null;
  /** The line an inbox shows beside the subject. */
  preheader: string;
  greeting?: string | null;
  /** The ask, in one line. */
  heading: string;
  /** What is being asked and why, in a sentence or two. */
  intro: string | readonly string[];
  /** The facts the ask rests on. Rows with an empty value are left out. */
  details?: readonly EmailDetail[] | null;
  /** A passage quoted as its author wrote it: a message, an update. */
  quote?: string | null;
  primary: EmailAction;
  secondary?: EmailAction | null;
  /**
   * Further places to go, shown as plain links under the buttons rather than as
   * buttons: where the buttons decide, these only look.
   */
  links?: readonly EmailAction[] | null;
  note?: string | readonly string[] | null;
  /** Why this person received this email. */
  reason: string | readonly string[];
  /** Where the reader chooses which emails they get. */
  preferencesUrl?: string | null;
  /**
   * The email cannot be switched off. true says so in the layout's own words;
   * a string says it in the sender's.
   */
  mandatory?: boolean | string | null;
  /** A closing line under the reason, such as who the email was sent for. */
  footer?: string | null;
  words?: Partial<LayoutWords> | null;
};

export type RenderedEmail = { html: string; text: string };

export const DEFAULT_LAYOUT_WORDS: LayoutWords = {
  fallback: "If a button does not work, copy the address into your browser.",
  preferences: "Choose which emails you receive",
  mandatory: "This notice cannot be switched off.",
};

// The site's palette as hex. src/styles.css defines these in oklch, which most
// mail clients do not read; an unparsed colour is not a fallback, it is black
// text on nothing.
export const PALETTE = {
  brand: "#36312B",
  surface: "#F6F4F0",
  card: "#FEFDFA",
  soft: "#E9E6DE",
  line: "#DCD7CE",
  ink: "#403B36",
  muted: "#67625D",
  accent: "#A2591E",
  /** Text on the brand colour: nearly white, never pure white. */
  onBrand: "#FBF8F3",
  onBrandMuted: "#D6CFC5",
} as const;

// The same surfaces in a dark room, for clients that honour
// prefers-color-scheme (Apple Mail, Outlook for Mac, iOS) and for Outlook.com,
// which marks the document with data-ogsc when it darkens it.
const DARK = {
  surface: "#1D1B18",
  card: "#27241F",
  soft: "#35312B",
  ink: "#EDE8E1",
  muted: "#B7AFA5",
  accent: "#E3A66E",
  button: "#EDE8E1",
  onButton: "#1D1B18",
} as const;

const SANS = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif";
const SERIF = "Georgia,'Times New Roman',serif";
const MONO = "ui-monospace,SFMono-Regular,Menlo,Consolas,'Liberation Mono',monospace";

const HTML_ESCAPES: Record<string, string> = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
};

/** Ampersand, angle brackets and both quotes: text and attribute values alike. */
export function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (c) => HTML_ESCAPES[c] ?? c);
}

/**
 * One line, bounded. Control characters and line breaks become spaces, so a
 * name cannot start a second header line or a second paragraph.
 */
export function oneLine(value: string | null | undefined, max = 120): string {
  const flat = [...(value ?? "")]
    .map((c) => (c.charCodeAt(0) < 32 || c.charCodeAt(0) === 127 ? " " : c))
    .join("")
    .replace(/\s+/g, " ")
    .trim();
  return flat.length > max ? `${flat.slice(0, max - 1).trimEnd()}…` : flat;
}

/** Line endings made one kind, and trailing space off every line. */
function tidyBlock(value: string): string {
  return value
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((l) => l.replace(/\s+$/, ""))
    .join("\n")
    .trim();
}

function paragraphsOf(value: string | readonly string[] | null | undefined): string[] {
  if (value === null || value === undefined) return [];
  const list = typeof value === "string" ? [value] : [...value];
  return list.map((p) => p.trim()).filter((p) => p.length > 0);
}

function mandatoryWords(input: EmailInput, words: LayoutWords): string | null {
  if (typeof input.mandatory === "string" && input.mandatory.trim() !== "") {
    return input.mandatory.trim();
  }
  return input.mandatory ? words.mandatory : null;
}

/* -------------------------------------------------------------------------- */
/* HTML                                                                       */
/* -------------------------------------------------------------------------- */

function p(words: string, size: number, colour: string, cls: string, margin = "0 0 16px"): string {
  return (
    `<p class="${cls}" style="margin:${margin};color:${colour};font-family:${SANS};` +
    `font-size:${size}px;line-height:1.6;word-break:break-word;">${escapeHtml(words)}</p>`
  );
}

function button(action: EmailAction, filled: boolean): string {
  const href = escapeHtml(action.url);
  const label = escapeHtml(oneLine(action.label, 60));
  const background = filled ? PALETTE.brand : PALETTE.card;
  const colour = filled ? PALETTE.onBrand : PALETTE.brand;
  const cell = filled ? "ce-button" : "ce-button-outline";
  const text = filled ? "ce-button-text" : "ce-button-outline-text";
  // 12px padding above and below a 20px line, inside a 1px border: 46px, over
  // the 44px a finger needs. An inline table so two buttons sit side by side
  // where there is room and stack where there is not.
  return (
    `<table role="presentation" cellpadding="0" cellspacing="0" border="0" ` +
    `style="display:inline-table;border-collapse:separate;margin:0 12px 12px 0;"><tr>` +
    `<td class="${cell}" bgcolor="${background}" height="44" style="background:${background};` +
    `border:1px solid ${PALETTE.brand};border-radius:8px;mso-padding-alt:12px 22px;">` +
    `<a class="${text}" href="${href}" style="display:inline-block;padding:12px 22px;` +
    `font-family:${SANS};font-size:15px;line-height:20px;font-weight:600;color:${colour};` +
    `text-decoration:none;border-radius:8px;">${label}</a>` +
    `</td></tr></table>`
  );
}

function detailRows(details: readonly EmailDetail[]): string {
  return details
    .map((d, i) => {
      const border = i === 0 ? "" : `border-top:1px solid ${PALETTE.soft};`;
      const label =
        `<td class="ce-muted ce-rule" valign="top" width="36%" style="${border}padding:10px 16px 10px 0;` +
        `width:36%;color:${PALETTE.muted};font-family:${SANS};font-size:13px;line-height:1.5;">` +
        `${escapeHtml(oneLine(d.label, 60))}</td>`;
      if (d.monospace) {
        return (
          `<tr>${label}<td class="ce-rule" valign="top" style="${border}padding:10px 0;">` +
          `<div class="ce-quote ce-ink" style="margin:0;padding:10px 12px;background:${PALETTE.surface};` +
          `border-radius:6px;color:${PALETTE.ink};font-family:${MONO};font-size:12px;line-height:1.55;` +
          `white-space:pre-wrap;word-break:break-word;">${escapeHtml(tidyBlock(d.value))}</div></td></tr>`
        );
      }
      const shown = escapeHtml(oneLine(d.value, 300));
      const value = d.url
        ? `<a class="ce-link" href="${escapeHtml(d.url)}" style="color:${PALETTE.accent};text-decoration:underline;">${shown}</a>`
        : shown;
      return (
        `<tr>${label}<td class="ce-ink ce-rule" valign="top" style="${border}padding:10px 0;` +
        `color:${PALETTE.ink};font-family:${SANS};font-size:14px;line-height:1.5;word-break:break-word;">` +
        `${value}</td></tr>`
      );
    })
    .join("");
}

function quoteBlock(quote: string): string {
  const paragraphs = tidyBlock(quote)
    .split(/\n{2,}/)
    .map(
      (block) =>
        `<p class="ce-ink" style="margin:0 0 12px;color:${PALETTE.ink};font-family:${SANS};font-size:14px;` +
        `line-height:1.6;word-break:break-word;">${escapeHtml(block).replaceAll("\n", "<br />")}</p>`,
    )
    .join("");
  return (
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" ` +
    `style="margin:4px 0 20px;"><tr><td class="ce-quote" bgcolor="${PALETTE.surface}" ` +
    `style="background:${PALETTE.surface};border-left:3px solid ${PALETTE.accent};` +
    `border-radius:0 8px 8px 0;padding:16px 18px 4px;">${paragraphs}</td></tr></table>`
  );
}

const DARK_STYLE = `
:root { color-scheme: light dark; supported-color-schemes: light dark; }
@media (prefers-color-scheme: dark) {
  .ce-bg { background:${DARK.surface} !important; }
  .ce-card { background:${DARK.card} !important; border-color:${DARK.soft} !important; }
  .ce-ink { color:${DARK.ink} !important; }
  .ce-muted { color:${DARK.muted} !important; }
  .ce-rule { border-color:${DARK.soft} !important; }
  .ce-link { color:${DARK.accent} !important; }
  .ce-quote { background:${DARK.surface} !important; }
  .ce-button { background:${DARK.button} !important; border-color:${DARK.button} !important; }
  .ce-button-text { color:${DARK.onButton} !important; }
  .ce-button-outline { background:${DARK.card} !important; border-color:${DARK.button} !important; }
  .ce-button-outline-text { color:${DARK.button} !important; }
}
[data-ogsc] .ce-ink { color:${DARK.ink} !important; }
[data-ogsc] .ce-muted { color:${DARK.muted} !important; }
[data-ogsc] .ce-link { color:${DARK.accent} !important; }
[data-ogsc] .ce-button-outline-text { color:${DARK.button} !important; }
`;

function renderHtml(input: EmailInput, words: LayoutWords): string {
  const organisation = oneLine(input.organisation, 60);
  const title = oneLine(input.title ?? input.heading, 200);
  const lang = /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$/.test(input.lang ?? "") ? input.lang : "en";
  const details = (input.details ?? []).filter((d) => d.value.trim() !== "");
  const actions = [input.primary, ...(input.secondary ? [input.secondary] : [])];
  const links = input.links ?? [];
  const mandatory = mandatoryWords(input, words);

  const greeting = input.greeting ? p(oneLine(input.greeting, 160), 15, PALETTE.ink, "ce-ink") : "";
  const intro = paragraphsOf(input.intro)
    .map((x) => p(x, 15, PALETTE.ink, "ce-ink"))
    .join("");
  const facts =
    details.length > 0
      ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" ` +
        `style="margin:4px 0 20px;border-top:1px solid ${PALETTE.line};border-bottom:1px solid ${PALETTE.line};" ` +
        `class="ce-rule">${detailRows(details)}</table>`
      : "";
  const quote = input.quote && input.quote.trim() !== "" ? quoteBlock(input.quote) : "";
  const buttons = `<div style="margin:8px 0 8px;">${actions.map((a, i) => button(a, i === 0)).join("")}</div>`;
  const further =
    links.length > 0
      ? `<p class="ce-ink" style="margin:0 0 16px;color:${PALETTE.ink};font-family:${SANS};font-size:14px;line-height:1.7;">` +
        links
          .map(
            (a) =>
              `<a class="ce-link" href="${escapeHtml(a.url)}" style="color:${PALETTE.accent};text-decoration:underline;">` +
              `${escapeHtml(oneLine(a.label, 60))}</a>`,
          )
          .join(
            `<span class="ce-muted" style="color:${PALETTE.muted};">&nbsp;&nbsp;·&nbsp;&nbsp;</span>`,
          ) +
        `</p>`
      : "";
  const note = paragraphsOf(input.note)
    .map((x) => p(x, 13, PALETTE.muted, "ce-muted"))
    .join("");
  const plain =
    `<p class="ce-muted" style="margin:8px 0 6px;color:${PALETTE.muted};font-family:${SANS};font-size:13px;line-height:1.55;">` +
    `${escapeHtml(words.fallback)}</p>` +
    [...actions, ...links]
      .map(
        (a) =>
          `<p class="ce-muted" style="margin:0 0 8px;color:${PALETTE.muted};font-family:${SANS};font-size:13px;line-height:1.55;word-break:break-all;">` +
          `${escapeHtml(oneLine(a.label, 60))}: <a class="ce-link" href="${escapeHtml(a.url)}" ` +
          `style="color:${PALETTE.accent};text-decoration:underline;">${escapeHtml(a.url)}</a></p>`,
      )
      .join("");

  const reason = paragraphsOf(input.reason)
    .map((x) => p(x, 12, PALETTE.muted, "ce-muted", "0 0 8px"))
    .join("");
  const choice = mandatory
    ? p(mandatory, 12, PALETTE.muted, "ce-muted", "0 0 8px")
    : input.preferencesUrl
      ? `<p class="ce-muted" style="margin:0 0 8px;color:${PALETTE.muted};font-family:${SANS};font-size:12px;line-height:1.6;">` +
        `<a class="ce-link" href="${escapeHtml(input.preferencesUrl)}" style="color:${PALETTE.accent};text-decoration:underline;">` +
        `${escapeHtml(words.preferences)}</a></p>`
      : "";
  const footer = input.footer
    ? p(oneLine(input.footer, 200), 12, PALETTE.muted, "ce-muted", "0")
    : "";

  const masthead =
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>` +
    `<td style="color:${PALETTE.onBrand};font-family:${SERIF};font-size:19px;line-height:24px;letter-spacing:0.02em;">Clove&nbsp;ERP</td>` +
    (organisation
      ? `<td align="right" style="color:${PALETTE.onBrandMuted};font-family:${SANS};font-size:13px;line-height:24px;">${escapeHtml(organisation)}</td>`
      : "") +
    `</tr></table>`;

  return `<!doctype html>
<html lang="${escapeHtml(lang ?? "en")}">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta name="color-scheme" content="light dark" />
<meta name="supported-color-schemes" content="light dark" />
<meta name="x-apple-disable-message-reformatting" />
<title>${escapeHtml(title)}</title>
<style>${DARK_STYLE}</style>
</head>
<body class="ce-bg" style="margin:0;padding:0;background:${PALETTE.surface};">
<div style="display:none;max-height:0;max-width:0;overflow:hidden;opacity:0;mso-hide:all;font-size:1px;line-height:1px;color:${PALETTE.surface};">${escapeHtml(oneLine(input.preheader, 200))}</div>
<table role="presentation" class="ce-bg" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="${PALETTE.surface}" style="background:${PALETTE.surface};">
<tr><td align="center" style="padding:28px 12px;">
  <table role="presentation" class="ce-card" width="600" cellpadding="0" cellspacing="0" border="0" bgcolor="${PALETTE.card}" style="width:100%;max-width:600px;background:${PALETTE.card};border:1px solid ${PALETTE.line};border-radius:12px;">
    <tr><td bgcolor="${PALETTE.brand}" style="padding:18px 28px;background:${PALETTE.brand};border-radius:12px 12px 0 0;">${masthead}</td></tr>
    <tr><td style="padding:28px 28px 12px;">
      ${greeting}
      <h1 class="ce-ink" style="margin:0 0 14px;color:${PALETTE.ink};font-family:${SANS};font-size:22px;line-height:1.3;font-weight:600;word-break:break-word;">${escapeHtml(oneLine(input.heading, 200))}</h1>
      ${intro}
      ${facts}
      ${quote}
      ${buttons}
      ${further}
      ${note}
      ${plain}
    </td></tr>
    <tr><td class="ce-rule" style="padding:18px 28px 22px;border-top:1px solid ${PALETTE.soft};">
      ${reason}
      ${choice}
      ${footer}
    </td></tr>
  </table>
</td></tr>
</table>
</body>
</html>`;
}

/* -------------------------------------------------------------------------- */
/* Text                                                                       */
/* -------------------------------------------------------------------------- */

function textDetail(d: EmailDetail): string {
  const label = oneLine(d.label, 60);
  if (d.monospace || /\n/.test(d.value)) {
    const block = tidyBlock(d.value)
      .split("\n")
      .map((l) => `  ${l}`)
      .join("\n");
    return `${label}:\n${block}`;
  }
  return `${label}: ${oneLine(d.value, 300)}`;
}

function renderText(input: EmailInput, words: LayoutWords): string {
  const details = (input.details ?? []).filter((d) => d.value.trim() !== "");
  const actions = [
    input.primary,
    ...(input.secondary ? [input.secondary] : []),
    ...(input.links ?? []),
  ];
  const mandatory = mandatoryWords(input, words);
  const sections: string[] = [];

  sections.push(oneLine(input.heading, 200));
  if (input.greeting) sections.push(oneLine(input.greeting, 160));
  sections.push(...paragraphsOf(input.intro));
  if (details.length > 0) sections.push(details.map(textDetail).join("\n"));
  if (input.quote && input.quote.trim() !== "") sections.push(tidyBlock(input.quote));
  sections.push(actions.map((a) => `${oneLine(a.label, 60)}: ${a.url}`).join("\n"));
  sections.push(...paragraphsOf(input.note));

  const closing = [
    ...paragraphsOf(input.reason),
    ...(mandatory
      ? [mandatory]
      : input.preferencesUrl
        ? [`${words.preferences}: ${input.preferencesUrl}`]
        : []),
    ...(input.footer ? [oneLine(input.footer, 200)] : []),
  ];
  if (closing.length > 0) sections.push(`—\n${closing.join("\n")}`);

  return `${sections.join("\n\n")}\n`;
}

/**
 * The same message twice: HTML for a client that renders it, text for one that
 * does not. The text is the whole message, never a pointer to the HTML.
 */
export function renderEmail(input: EmailInput): RenderedEmail {
  const words: LayoutWords = { ...DEFAULT_LAYOUT_WORDS };
  for (const key of ["fallback", "preferences", "mandatory"] as const) {
    const given = input.words?.[key];
    if (typeof given === "string" && given.trim() !== "") words[key] = given.trim();
  }
  return { html: renderHtml(input, words), text: renderText(input, words) };
}
