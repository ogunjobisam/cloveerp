# Clove ERP — Flow Doctrine

The rules every business cycle in Clove is held to. A module that breaks one of
these is wrong even if it works. Applies to procurement, sales, manufacturing,
stock, returns, subcontract and intercompany alike.

Written Sep 2026. Supersedes nothing — this is the first statement of it.

## Why this exists

Clove was built module by module, piling on as requests came in. Every request
that arrived as "we need to be able to X" became a state, a transition and a
button. Nobody went back and asked whether X was a document, a status, or a
setting. The result is a system that does the right things in roughly twice the
number of user actions Sage X3 needs.

The engine is not the problem. The document spine, state machines, approval
chains and numbering rules are already configuration rather than code, which is
the hard part and it is done. The problem is the configuration that was seeded
on top of it, and a UI that renders every available transition as a user action.

So this doctrine constrains configuration, not architecture.

## Rule 1 — Four events per cycle, no more

Every cycle records exactly four commercial events:

- Intent — someone wants something. Requisition, quote, planned order.
- Commitment — the company is on the hook. Purchase order, sales order, works order.
- Fulfilment — goods or value actually move. Goods receipt, despatch, production declaration.
- Settlement — money is recognised and paid. Invoice, payment, cost settlement.

Anything else is an attribute of one of those four, not a fifth document and not
a screen of its own. Approvals, send status, variance, reconciliation flags —
all attributes.

If a proposed new document does not map to one of the four, it is a status.

## Rule 2 — Transformation, not re-entry

A child document is born from its parent, pre-filled, through
`erp.link_documents`. The user's only job is to state the delta.

- Open a receipt against a PO and the outstanding quantities are already there.
  Change nothing and you have received everything.
- A field that exists on the parent is never re-keyed on the child.
- If a screen asks for something the parent already knows, that screen is wrong.

## Rule 3 — Approve the commitment once

Approval attaches to the moment of commercial commitment, and once only.

- Downstream documents inherit that approval.
- Re-approval fires on tolerance breach, never on routine progression.
- Two approvals of the same numbers by the same authority is a defect, not a control.

Segregation of duties is preserved by *who may act*, through the grant codes,
not by *how many times somebody clicks approve*.

## Rule 4 — Tolerances replace steps

Every control that a human would otherwise enforce by inspection becomes a
tolerance the system enforces automatically.

- Inside tolerance: pass silently, with a flag on the record for reporting.
- Outside tolerance: raise an exception and route it to someone who can decide.

This is the trade that makes the flow short without weakening it. The control is
still there and still auditable; it simply stopped costing a click on the 97%
case in order to catch the 3%.

## Rule 5 — Status is derived, never clicked

No transition exists whose only effect is to describe what already happened.

- A PO is "partially received" because posted receipt lines say so.
- A PO is "closed" because it is fully received and fully invoiced.
- A document is "issued" because a row exists in `erp.document_issue`.

Any transition a user must click to keep the record honest is a bug. Derive it
from the child documents, or from the ledger.

The test: could the system work this out on its own? If yes, it must.

## Rule 6 — Off-system stays off-system

Once a document leaves the building, the system holds a flag and a copy, not a
workflow. Email threads, supplier phone calls and PDF attachments are not
states. Do not build screens for things happening in Outlook.

## Rule 7 — Parameter budget

Configurability is the product. Uncontrolled configurability is why X3 needs
consultants and why Datel can charge what it charges. So:

- No more than 15 parameters per cycle.
- Every parameter ships with a default that produces the clean path.
- A parameter must change behaviour a real customer has asked to change. "Might
  be useful" is not a reason.
- New optional behaviour arrives as a parameter defaulted off, never as a new
  step defaulted on.

A customer should be able to configure a cycle in an afternoon. If a cycle needs
a consultant, this rule has been broken.

## Rule 8 — Step budget, asserted in CI

Each cycle declares the maximum number of user actions on its happy path, and an
assertion in the `erp_test` suite enforces it. Adding a step means changing the
declared budget in the same PR, in the open, with a reason.

This is what stops the piling-on from recurring.

## Rule 9 — Happy path gets a button, exceptions get a screen

The common case is a single primary action on the document you are already
looking at. Exceptions — breaches, mismatches, short receipts, cancellations —
get their own screens, reached only when they occur.

Never tax the common case to handle the rare one.

## Smell list

Any of these in a screen, a state machine or a door is a step to delete. Use it
as a review checklist on every module.

- A confirm or validate step where the user has no decision to make and which is
  never refused.
- A status a user sets by hand.
- A field re-keyed on a child that already exists on the parent.
- A second approval of values that were approved upstream and have not moved.
- A queue or workspace screen whose only job is to change a status.
- A list screen you are forced through when you already know the record.
- Separate create and post steps where post is not the decision point.
- Two transitions that differ only by degree — receive part versus receive all.
- A transition whose name is a description rather than a decision.

## Applying this to a new cycle

- Name the four events. Write them down before any schema or configuration.
- Write the happy path as a numbered list of user actions. Count them. That is
  the step budget.
- Everything that did not make the list is either a derived status, a tolerance,
  or a parameter defaulted off. Classify each one explicitly.
- Write the exception paths separately. They do not count against the budget.
- Write the assertions before the screens.
