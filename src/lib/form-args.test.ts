import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import * as ts from "typescript";

/**
 * A form's mapArgs is handed what was typed: every value a string, row
 * editors' cells too (ActionDialog's buildArgs). Without mapArgs the dialog
 * turns a money field into minor units, a number into a number and a yes/no
 * into a boolean; with it, nothing does, and whatever mapArgs returns is all
 * that is sent. "Ship these deliveries" sent its cost as typed — "12.50", in
 * pounds, as text — to a pence parameter until 20261004950000.
 *
 * This reads every form in src that has a mapArgs beside its fields and
 * refuses one whose money, number or yes/no field (or row column) reaches the
 * door unconverted, or never reaches it at all. Converted means passed through
 * Number, toMinor, parseInt, parseFloat or Math.round, or compared with "true"
 * or "false". Where a hook takes its keys from a list (the policy forms), the
 * key must be listed and the hook must convert somewhere.
 */

const ROOT = join(import.meta.dir, "..");
const CONVERTERS = new Set(["Number", "toMinor", "parseInt", "parseFloat", "Math.round"]);

type FieldKind = "money" | "number" | "boolean";
type Typed = { name: string; kind: FieldKind; row?: string };
export type Finding = { at: string; fn: string; field: string; problem: string };

function sourceFiles(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) out.push(...sourceFiles(path));
    else if (
      /\.(ts|tsx)$/.test(entry) &&
      !/\.test\.tsx?$/.test(entry) &&
      !entry.endsWith(".gen.ts")
    )
      out.push(path);
  }
  return out;
}

function parse(fileName: string, text: string): ts.SourceFile {
  return ts.createSourceFile(
    fileName,
    text,
    ts.ScriptTarget.Latest,
    true,
    fileName.endsWith("x") ? ts.ScriptKind.TSX : ts.ScriptKind.TS,
  );
}

/** Every named declaration in the files, so a hook or a field list kept elsewhere can be read. */
function declarations(files: ts.SourceFile[]): Map<string, ts.Node[]> {
  const named = new Map<string, ts.Node[]>();
  const add = (name: string, node: ts.Node) => named.set(name, [...(named.get(name) ?? []), node]);
  for (const sf of files) {
    const visit = (node: ts.Node) => {
      if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.initializer)
        add(node.name.text, node.initializer);
      if (ts.isFunctionDeclaration(node) && node.name) add(node.name.text, node);
      ts.forEachChild(node, visit);
    };
    visit(sf);
  }
  return named;
}

/** A property of an object literal, or an attribute of a JSX element, by name. */
function member(node: ts.Node, name: string): ts.Expression | undefined {
  if (ts.isObjectLiteralExpression(node)) {
    for (const p of node.properties) {
      if (!p.name || p.name.getText() !== name) continue;
      if (ts.isPropertyAssignment(p)) return p.initializer;
      if (ts.isShorthandPropertyAssignment(p)) return p.name;
      if (ts.isMethodDeclaration(p)) return p as unknown as ts.Expression;
    }
  }
  if (ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node)) {
    for (const a of node.attributes.properties) {
      if (ts.isJsxAttribute(a) && a.name.getText() === name && a.initializer) {
        if (ts.isJsxExpression(a.initializer)) return a.initializer.expression;
        return a.initializer;
      }
    }
  }
  return undefined;
}

const literal = (e: ts.Expression | undefined): string | undefined =>
  e && (ts.isStringLiteral(e) || ts.isNoSubstitutionTemplateLiteral(e)) ? e.text : undefined;

/** The money, number and yes/no fields of a form, and the money and number columns of its row editors. */
function typedFields(fields: ts.Expression, named: Map<string, ts.Node[]>): Typed[] {
  let list: ts.Node = fields;
  if (ts.isIdentifier(list)) list = named.get(list.text)?.[0] ?? list;
  if (!ts.isArrayLiteralExpression(list)) return [];
  const out: Typed[] = [];
  for (const el of list.elements) {
    if (ts.isCallExpression(el) && el.expression.getText() === "yesNo") {
      const name = literal(el.arguments[0]);
      if (name) out.push({ name, kind: "boolean" });
      continue;
    }
    if (!ts.isObjectLiteralExpression(el)) continue;
    const kind = literal(member(el, "kind"));
    const name = literal(member(el, "name"));
    if (!name) continue;
    if (kind === "money" || kind === "number") out.push({ name, kind });
    if (kind === "choice" && member(el, "boolean")?.kind === ts.SyntaxKind.TrueKeyword)
      out.push({ name, kind: "boolean" });
    const columns = member(el, "columns");
    if (kind === "rows" && columns && ts.isArrayLiteralExpression(columns)) {
      for (const c of columns.elements) {
        if (!ts.isObjectLiteralExpression(c)) continue;
        const ck = literal(member(c, "kind"));
        const cn = literal(member(c, "name"));
        if (cn && (ck === "money" || ck === "number")) out.push({ name: cn, kind: ck, row: name });
      }
    }
  }
  return out;
}

/** The hook and whatever it hands its work to: a named helper, or the factory that made it. */
function hookNodes(hook: ts.Expression, named: Map<string, ts.Node[]>, depth = 0): ts.Node[] {
  if (depth > 3) return [hook];
  if (ts.isIdentifier(hook)) {
    const decl = named.get(hook.text)?.[0];
    if (!decl) return [hook];
    return ts.isExpression(decl) ? hookNodes(decl, named, depth + 1) : [decl];
  }
  if (ts.isCallExpression(hook) && ts.isIdentifier(hook.expression)) {
    return [hook, ...hookNodes(hook.expression, named, depth + 1)];
  }
  return [hook];
}

type Verdict = "converted" | "raw" | "test" | "other";

const isTrueFalse = (e: ts.Expression) => {
  const v = literal(e);
  return v === "true" || v === "false";
};

/** What becomes of one read of a typed value: converted, sent raw, only tested, or something else. */
function fate(read: ts.Expression, scope: ts.Node, depth = 0): Verdict {
  let node: ts.Node = read;
  for (;;) {
    const parent: ts.Node = node.parent;
    if (
      ts.isParenthesizedExpression(parent) ||
      ts.isAsExpression(parent) ||
      ts.isNonNullExpression(parent)
    ) {
      node = parent;
      continue;
    }
    if (ts.isBinaryExpression(parent)) {
      const op = parent.operatorToken.kind;
      if (op === ts.SyntaxKind.QuestionQuestionToken || op === ts.SyntaxKind.BarBarToken) {
        node = parent;
        continue;
      }
      if (op === ts.SyntaxKind.AmpersandAmpersandToken) {
        if (parent.left === node) return "test";
        node = parent;
        continue;
      }
      const comparison = [
        ts.SyntaxKind.EqualsEqualsEqualsToken,
        ts.SyntaxKind.ExclamationEqualsEqualsToken,
        ts.SyntaxKind.EqualsEqualsToken,
        ts.SyntaxKind.ExclamationEqualsToken,
      ].includes(op);
      if (comparison) {
        const other = parent.left === node ? parent.right : parent.left;
        return isTrueFalse(other) ? "converted" : "test";
      }
      if (op === ts.SyntaxKind.EqualsToken && parent.right === node) return "raw";
      if (
        op === ts.SyntaxKind.AsteriskToken ||
        op === ts.SyntaxKind.SlashToken ||
        op === ts.SyntaxKind.MinusToken
      )
        return "converted";
      return "other";
    }
    if (ts.isConditionalExpression(parent)) {
      if (parent.condition === node) return "test";
      node = parent;
      continue;
    }
    if (ts.isPrefixUnaryExpression(parent)) {
      return parent.operator === ts.SyntaxKind.ExclamationToken ? "test" : "converted";
    }
    if (ts.isIfStatement(parent) && parent.expression === node) return "test";
    if (ts.isCallExpression(parent)) {
      return CONVERTERS.has(parent.expression.getText()) ? "converted" : "other";
    }
    if (ts.isPropertyAssignment(parent) || ts.isShorthandPropertyAssignment(parent)) return "raw";
    if (ts.isReturnStatement(parent) || ts.isArrowFunction(parent)) return "raw";
    if (ts.isVariableDeclaration(parent) && ts.isIdentifier(parent.name) && depth < 3) {
      // const raw = v["x"] ?? ""; … Number(raw): follow the name.
      const fates = references(parent.name.text, scope).map((r) => fate(r, scope, depth + 1));
      if (fates.includes("raw")) return "raw";
      if (fates.includes("converted")) return "converted";
      return fates.length > 0 ? "test" : "other";
    }
    return "other";
  }
}

function references(name: string, scope: ts.Node): ts.Expression[] {
  const out: ts.Expression[] = [];
  const visit = (node: ts.Node) => {
    if (ts.isIdentifier(node) && node.text === name && !ts.isVariableDeclaration(node.parent))
      out.push(node);
    ts.forEachChild(node, visit);
  };
  visit(scope);
  return out;
}

/** Reads of one key in the hook: v["key"], row["key"], v.key. */
function reads(key: string, nodes: ts.Node[]): ts.Expression[] {
  const out: ts.Expression[] = [];
  const visit = (node: ts.Node) => {
    if (ts.isElementAccessExpression(node) && literal(node.argumentExpression) === key)
      out.push(node);
    if (ts.isPropertyAccessExpression(node) && node.name.text === key) out.push(node);
    ts.forEachChild(node, visit);
  };
  for (const n of nodes) visit(n);
  return out;
}

function listed(key: string, nodes: ts.Node[]): boolean {
  let found = false;
  const visit = (node: ts.Node) => {
    if (ts.isStringLiteral(node) && node.text === key && !ts.isElementAccessExpression(node.parent))
      found = true;
    if (!found) ts.forEachChild(node, visit);
  };
  for (const n of nodes) visit(n);
  return found;
}

function convertsSomewhere(nodes: ts.Node[]): boolean {
  let found = false;
  const visit = (node: ts.Node) => {
    if (ts.isCallExpression(node) && CONVERTERS.has(node.expression.getText())) found = true;
    if (ts.isBinaryExpression(node) && (isTrueFalse(node.left) || isTrueFalse(node.right)))
      found = true;
    if (!found) ts.forEachChild(node, visit);
  };
  for (const n of nodes) visit(n);
  return found;
}

/** Every finding in the given files, and how many forms were read. */
export function audit(files: { name: string; text: string }[]): {
  forms: number;
  findings: Finding[];
} {
  const parsed = files.map((f) => parse(f.name, f.text));
  const named = declarations(parsed);
  const findings: Finding[] = [];
  let forms = 0;
  for (const sf of parsed) {
    const visit = (node: ts.Node) => {
      const hook = member(node, "mapArgs");
      const fields = member(node, "fields");
      if (hook && fields) {
        forms += 1;
        const at = `${sf.fileName}:${sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1}`;
        const fn = literal(member(node, "fn")) ?? member(node, "fn")?.getText() ?? "?";
        const nodes = hookNodes(hook, named);
        for (const field of typedFields(fields, named)) {
          const label = field.row ? `${field.row}.${field.name}` : field.name;
          const found = reads(field.name, nodes);
          if (found.length === 0) {
            if (!listed(field.name, nodes))
              findings.push({
                at,
                fn,
                field: label,
                problem: `a ${field.kind} field mapArgs never sends`,
              });
            else if (!convertsSomewhere(nodes))
              findings.push({
                at,
                fn,
                field: label,
                problem: `a ${field.kind} field sent by key as typed`,
              });
            continue;
          }
          const fates = found.map((r) => fate(r, nodes[0] ?? r));
          if (fates.includes("raw"))
            findings.push({ at, fn, field: label, problem: `a ${field.kind} field sent as typed` });
          else if (!fates.includes("converted") && !fates.includes("other"))
            findings.push({
              at,
              fn,
              field: label,
              problem: `a ${field.kind} field only tested, never sent`,
            });
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(sf);
  }
  return { forms, findings };
}

describe("a form's mapArgs sends what the door takes", () => {
  test("the check refuses a raw money field, a raw yes/no, a raw row cell and a dropped number, and passes the conversions", () => {
    const fixture = `
      const bad = {
        fn: "erp_bad",
        fields: [
          { kind: "money", name: "p_cost_minor", currency: "GBP" },
          { kind: "choice", name: "p_flag", boolean: true, choices: [] },
          { kind: "number", name: "p_dropped" },
          { kind: "rows", name: "p_lines", columns: [{ name: "quantity", kind: "number" }] },
        ],
        mapArgs: (v, picked) => ({
          p_cost_minor: v["p_cost_minor"] ?? null,
          p_flag: v["p_flag"],
          p_lines: (picked?.rows["p_lines"] ?? []).map((row) => ({ quantity: row["quantity"] })),
        }),
      };
      const good = {
        fn: "erp_good",
        fields: [
          { kind: "money", name: "p_cost_minor", currency: "GBP" },
          { kind: "choice", name: "p_flag", boolean: true, choices: [] },
          { kind: "number", name: "p_weight_g" },
          { kind: "number", name: "p_horizon" },
          { kind: "rows", name: "p_lines", columns: [{ name: "quantity", kind: "number" }] },
        ],
        mapArgs: (v, picked) => {
          const horizon = v["p_horizon"] ?? "";
          const args = {
            p_cost_minor: v["p_cost_minor"] ? toMinor(v["p_cost_minor"]) : null,
            p_flag: v["p_flag"] === "true",
            p_weight_g: v["p_weight_g"] ? Number(v["p_weight_g"]) : null,
            p_lines: (picked?.rows["p_lines"] ?? []).map((row) => ({ quantity: Number(row["quantity"] ?? 0) })),
          };
          if (horizon !== "") args["p_horizon"] = Number(horizon);
          return args;
        },
      };`;
    const { forms, findings } = audit([{ name: "fixture.ts", text: fixture }]);
    expect(forms).toBe(2);
    expect(findings.map((f) => `${f.fn} ${f.field}: ${f.problem}`).sort()).toEqual([
      "erp_bad p_cost_minor: a money field sent as typed",
      "erp_bad p_dropped: a number field mapArgs never sends",
      "erp_bad p_flag: a boolean field sent as typed",
      "erp_bad p_lines.quantity: a number field sent as typed",
    ]);
  });

  test("every form in src converts what it sends", () => {
    const files = sourceFiles(ROOT)
      .map((path) => ({ name: relative(join(ROOT, ".."), path), text: readFileSync(path, "utf8") }))
      .filter((f) => f.text.includes("mapArgs"));
    const { forms, findings } = audit(files);
    // A check that reads nothing passes everything.
    expect(forms).toBeGreaterThan(50);
    expect(findings).toEqual([]);
  });
});
