/**
 * The demo path: the screens the two flows traverse, in the order a person
 * walks them.
 *
 * The v1 Definition of Done scopes itself twice over on this list — "any
 * screen not on the demo path is out of scope", and "both flows can be
 * demonstrated live, front to back, without intervention" — and until now the
 * list did not exist. Without it neither sentence can be applied: nobody can
 * say whether a defect is in scope, and nobody can say which screens the three
 * weeks before the checkpoint are for.
 *
 * It is written out rather than derived, for the reason `routes.ts` is: a list
 * that walks the file tree agrees with the file tree by construction and
 * notices nothing. This one is checked instead — `src/lib/demo-path.test.ts`
 * fails when a step names a route the inventory does not have, when a step
 * names a stage the screen no longer draws, when a door it names is gone from
 * the application, and when a route is neither on the path nor written down
 * below as being off it. A new screen therefore forces the decision rather
 * than drifting into the ambiguity.
 *
 * The steps come from what the product declares, not from memory:
 * `/procurement` and `/sales` each draw a `ProcessFlow` whose stages name
 * their doors and their lists, and `src/lib/modules.tsx` declares the same for
 * `/finance`, `/logistics` and `/inventory`. Those stages are the flow.
 */

/**
 * The document screen, as the route inventory names it.
 *
 * Every record on every step opens here, on its own identifier. The inventory
 * has to name the route with something, and names it with a document that does
 * not exist — a stale link out of somebody's email is the ordinary way to
 * arrive at one. That placeholder is the path this list checks against, so the
 * two agree by comparison rather than by convention.
 */
const DOCUMENT_SCREEN = "/documents/00000000-0000-4000-8000-000000000fff";

export type Step = {
  /** Where the person is. One of the paths in `./routes.ts`, exactly. */
  path: string;
  /**
   * The step of the process the screen draws, by the label on it. Absent where
   * the screen draws no flow — signing in, the desk's home, a report.
   */
  stage?: string;
  /** What the person does here, in the words they would use. */
  does: string;
  /**
   * The doors the screen calls when they do it.
   *
   * Reads that only fill a list are left out; these are the ones that carry
   * the work. Empty where the step writes nothing — a signpost, or signing in,
   * which is the authentication provider's business rather than a door.
   */
  doors: readonly string[];
  /** The record and the state the step leaves it in. */
  leaves: string;
  /**
   * Where the step points, when the step is a signpost: the stage exists on
   * this screen, says what happens next, and does none of it here.
   */
  signpost?: string;
};

export type Flow = {
  key: string;
  title: string;
  steps: readonly Step[];
};

/**
 * Closing, and then the four ties.
 *
 * The same tail on both flows, because the master gate is the same one: a
 * month is posted, the period is closed, and then the trial balance balances,
 * the stock valuation equals the inventory control account, and the two
 * ageings equal the debtors and creditors control accounts. A demonstration of
 * either flow that stops before this has not shown the thing being claimed.
 */
const CLOSE_AND_TIE: readonly Step[] = [
  {
    path: "/finance",
    stage: "Close",
    does: "Open the period's close, work through the tasks it raises, and close the period.",
    doors: ["erp_open_period_close", "erp_close_period"],
    leaves: "The fiscal period closed, so nothing further posts into it.",
  },
  {
    path: "/finance/statements",
    does: "Read the profit and loss for the month and the balance sheet as at its last day. The first tie is here: the trial balance balances.",
    doors: ["erp_trial_balance", "erp_profit_and_loss", "erp_balance_sheet"],
    leaves: "Nothing. The first tie is read, not written.",
  },
  {
    path: "/inventory",
    does: "Reports, then Valuation: what the stock is worth at cost. The second tie is here: that total is the inventory control account on the trial balance.",
    doors: ["erp_stock_valuation"],
    leaves: "Nothing. The second tie is read, not written.",
  },
  {
    path: "/finance",
    does: "Reports, then the two ageings. The third and fourth ties are here: receivables against the debtors control account, payables against the creditors control account.",
    doors: ["erp_receivables_ageing", "erp_payables_ageing"],
    leaves: "Nothing. The third and fourth ties are read, not written.",
  },
  {
    path: "/operations/assurance",
    does: "Run every structural check against this database, the whole-database reconciliation among them, so the four ties are proved rather than eyeballed off four screens.",
    doors: ["erp_platform_assurance"],
    leaves: "Nothing. The checks run live and report.",
  },
];

/** Both flows start in the same two places. */
const ARRIVE = (who: string): readonly Step[] => [
  {
    path: "/signin",
    does: `Sign in as ${who}.`,
    doors: [],
    leaves: "A session, and the organisation the account resolves to.",
  },
  {
    path: "/",
    does: "Read what is waiting on you, then open the module from the launchpad.",
    doors: ["erp_my_approvals"],
    leaves: "Nothing. The desk's home is the way in, not a step of the process.",
  },
];

export const PURCHASE_TO_PAY: Flow = {
  key: "purchase-to-pay",
  title: "Purchase to pay",
  steps: [
    ...ARRIVE("the buyer"),
    {
      path: "/procurement",
      stage: "Requisition",
      does: "Raise a requisition for what is needed, line by line, and submit it for approval.",
      doors: ["erp_create_document_full", "erp_transition_document"],
      leaves: "A requisition, submitted.",
    },
    {
      path: "/procurement",
      stage: "Approval",
      does: "See who has to agree at this value, and approve it — either on the requisition or as the approval task waiting on you.",
      doors: ["erp_stamp_document_approval", "erp_transition_document", "erp_decide_approval"],
      leaves: "The requisition, approved.",
    },
    {
      path: "/procurement",
      stage: "Approval",
      does: "Convert the approved requisition into a purchase order for the supplier it names.",
      doors: ["erp_convert_document"],
      leaves: "The requisition ordered, and a draft purchase order carrying every line still open.",
    },
    {
      path: DOCUMENT_SCREEN,
      does: "Open the new order to check its lines and prices, and add or amend a line before anyone commits to it.",
      doors: ["erp_document", "erp_add_document_line", "erp_amend_document_line"],
      leaves: "The order still where it was, with the lines it will be sent on.",
    },
    {
      path: "/procurement",
      stage: "Purchase order",
      does: "Take the order through whatever its value asks for, and send it to the supplier.",
      doors: ["erp_transition_document"],
      leaves: "The purchase order, sent — the commitment the supplier sees.",
    },
    {
      path: "/procurement",
      stage: "Purchase order",
      does: "The van arrives. Receive this order raises a goods receipt holding what is left on each line.",
      doors: ["erp_create_receipt_from_order"],
      leaves: "A draft goods receipt against that order.",
    },
    {
      path: "/procurement",
      stage: "Goods receipt",
      does: "Count what actually turned up, correct any line that came short, and post the receipt.",
      doors: ["erp_receive_against", "erp_transition_document"],
      leaves:
        "The receipt posted: stock standing in the site's receiving area, the goods-received accrual raised, and the order partly or fully received.",
    },
    {
      path: "/procurement",
      stage: "Goods in",
      does: "Ask the warehouse to move what is standing in receiving to where the storage rules say it belongs.",
      doors: ["erp_raise_putaway_tasks"],
      leaves: "An open put-away task for each pallet.",
    },
    {
      path: "/procurement",
      stage: "Put away",
      does: "Complete each task as the pallet is moved. Completing it is what moves the stock.",
      doors: ["erp_complete_warehouse_task"],
      leaves: "The stock on the shelf, at the location the rules chose.",
    },
    {
      path: "/procurement",
      stage: "Goods receipt",
      does: "Show finished, then bill the posted receipt: the supplier's own invoice number and dates, against the quantities and prices that arrived.",
      doors: ["erp_bill_from_receipt"],
      leaves: "A supplier bill, raised from the receipt.",
    },
    {
      path: "/procurement",
      stage: "Supplier bill",
      does: "Match the bill to the order line by line, and accept a difference that has been agreed and approved.",
      doors: ["erp_invoice_against", "erp_accept_match_exception"],
      leaves:
        "The bill matched and registered: the goods-received accrual cleared and the balance owed to the supplier.",
    },
    {
      path: "/procurement",
      stage: "Payment",
      signpost: "/finance",
      does: "Purchasing's last step does no work of its own: it says that paying happens in Financials, and goes there.",
      doors: [],
      leaves: "Nothing. A signpost.",
    },
    {
      path: "/finance",
      stage: "Payment run",
      does: "Gather what is due to suppliers into one proposal.",
      doors: ["erp_propose_payment_run"],
      leaves: "A payment run, proposed.",
    },
    {
      path: "/finance",
      stage: "Approve",
      does: "A second person approves the run. Whoever proposed it cannot.",
      doors: ["erp_approve_payment_run"],
      leaves: "The run, approved.",
    },
    {
      path: "/finance",
      stage: "Pay",
      does: "Pay the approved run.",
      doors: ["erp_pay_payment_run"],
      leaves: "The run paid: the payable cleared and the bank credited.",
    },
    ...CLOSE_AND_TIE,
  ],
};

export const ORDER_TO_CASH: Flow = {
  key: "order-to-cash",
  title: "Order to cash",
  steps: [
    ...ARRIVE("the person taking the order"),
    {
      path: "/sales",
      stage: "Quotation",
      does: "Work out what this customer pays for these products today, raise a quotation at those prices, and send it.",
      doors: ["erp_resolve_price", "erp_create_document_full", "erp_transition_document"],
      leaves: "A quotation, sent.",
    },
    {
      path: "/sales",
      stage: "Quotation",
      does: "The customer accepts. Convert the quotation into a sales order.",
      doors: ["erp_convert_document"],
      leaves:
        "The quotation accepted, and a sales order carrying every open line at the quoted price.",
    },
    {
      path: DOCUMENT_SCREEN,
      does: "Open the order to check its lines and prices, and add or amend a line before it is committed.",
      doors: ["erp_document", "erp_add_document_line", "erp_amend_document_line"],
      leaves: "The order still where it was, with the lines it will be confirmed on.",
    },
    {
      path: "/sales",
      stage: "Sales order",
      does: "Promise a date against the stock that will be there, then confirm the order. Credit standing decides whether it may go on.",
      doors: ["erp_promise_date", "erp_transition_document"],
      leaves: "The sales order, confirmed.",
    },
    {
      path: "/sales",
      stage: "Pick",
      does: "Pick the order: it reserves whatever is not reserved yet, picks it off the shelf, and says what it could not cover.",
      doors: ["erp_pick_document"],
      leaves: "The order picking, with the stock allocated to its lines.",
    },
    {
      path: "/sales",
      stage: "Sales order",
      does: "Create a delivery from this order, holding what is left to deliver on each line.",
      doors: ["erp_create_delivery_from_order"],
      leaves: "A draft delivery for the order's customer and site.",
    },
    {
      path: "/sales",
      stage: "Delivery",
      signpost: "/logistics",
      does: "Sales' delivery step says where a delivery leaves from, and goes to Despatch.",
      doors: [],
      leaves: "Nothing. A signpost.",
    },
    {
      path: "/logistics",
      stage: "Delivery",
      does: "Post the delivery when the goods leave. Posting is what takes the stock off the shelf.",
      doors: ["erp_transition_document"],
      leaves: "The delivery posted, the stock gone, and the order despatched.",
    },
    {
      path: "/logistics",
      stage: "Delivery",
      does: "Plan a shipment: the posted deliveries leaving one site on one day, gathered into one.",
      doors: ["erp_plan_shipment"],
      leaves: "A shipment, planned.",
    },
    {
      path: "/logistics",
      stage: "Carrier",
      does: "Choose who is taking it, against which service and at what rate.",
      doors: ["erp_select_carrier"],
      leaves: "The shipment with its carrier chosen.",
    },
    {
      path: "/logistics",
      stage: "Book",
      does: "Book it. The booking is the commitment the carrier sees.",
      doors: ["erp_book_shipment"],
      leaves: "The shipment, booked, with its cost landing on the stock.",
    },
    {
      path: "/logistics",
      stage: "Proof",
      does: "Attach the signature or the photograph once it has been delivered.",
      doors: ["erp_record_proof_of_delivery"],
      leaves: "The shipment delivered, with the proof on it.",
    },
    {
      path: "/sales",
      stage: "Invoice",
      signpost: "/finance",
      does: "Sales' invoice step says the bill is raised in Financials, and goes there.",
      doors: [],
      leaves: "Nothing. A signpost.",
    },
    {
      path: "/finance",
      stage: "Invoice",
      does: "Raise the invoice from the posted delivery, so it bills what actually went, and issue it.",
      doors: ["erp_invoice_from_delivery", "erp_transition_document"],
      leaves: "A sales invoice issued: the receivable and the revenue posted.",
    },
    {
      path: "/sales",
      stage: "Cash",
      signpost: "/finance",
      does: "Sales' last step says the money is applied in Financials, and goes there.",
      doors: [],
      leaves: "Nothing. A signpost.",
    },
    {
      path: "/finance",
      stage: "Cash in",
      does: "Apply the money received against the invoices it settles.",
      doors: ["erp_apply_cash"],
      leaves: "The invoice paid and the receivable cleared.",
    },
    ...CLOSE_AND_TIE,
  ],
};

export const FLOWS: readonly Flow[] = [PURCHASE_TO_PAY, ORDER_TO_CASH];

/** Every route either flow touches, in the order it is first reached. */
export function pathsOnTheDemoPath(): string[] {
  const seen: string[] = [];
  for (const flow of FLOWS)
    for (const step of flow.steps) if (!seen.includes(step.path)) seen.push(step.path);
  return seen;
}

/**
 * The routes neither flow touches, and why each one is not on the path.
 *
 * This is the half of the list the scoping rule actually spends: a defect on
 * one of these is S3 by the Definition of Done and ships with a known-issues
 * list. A reason per route rather than a heading per area, because the reasons
 * differ — some of these are the vendor's own screens, some are configuration
 * a seeded organisation already has, and some are real operating screens that
 * the two flows simply do not need to pass through.
 *
 * A route added without a line here, or without a step above, fails the test.
 * That is the point: the decision gets made when the screen is built, by the
 * person who knows, rather than inferred later by whoever is triaging.
 */
export const OFF_THE_PATH: Readonly<Record<string, string>> = {
  "/product": "The marketing page. Signed out, and no part of either flow.",
  "/contact": "The enquiry form on the marketing site. Signed out, and no part of either flow.",
  "/platform": "The vendor's own console. A separate role model, and not a tenant's screen.",
  "/help": "Guidance about the screens, not one of them.",
  "/join":
    "Where an invitation is accepted. The demonstration organisation already has its people.",
  "/act":
    "Where an Approve or Reject link out of an email lands. Approvals on the demo path are decided on the step that raised them, so no email is needed to finish either flow.",
  "/profile": "Your own account, your language and how the desk is set up for you.",
  "/settings": "The way into the configuration screens, and the setup walkthrough over them.",
  "/notifications": "What has been sent to you. Reading it moves no record.",
  "/device":
    "The scanner screen, deliberately without the desk. Put-away on the demo path is completed from Purchasing's own step.",
  "/administration/accessibility": "Configuration: contrast, motion and text size for the tenant.",
  "/administration/adoption":
    "Who is using which screens. Evidence about the flows, not part of them.",
  "/administration/audit": "The audit trail over what the flows did, read afterwards.",
  "/administration/commercial":
    "The tenant's own agreement with the vendor: plan, seats and usage.",
  "/administration/configuration":
    "Document types, numbering and lifecycles. Seeded before the demonstration.",
  "/administration/erasure": "Erasure requests under data protection, and what has been erased.",
  "/administration/onboarding":
    "The interview that stands a new organisation up. The demonstration organisation is already standing.",
  "/administration/organisation": "Companies, sites and departments. Seeded.",
  "/administration/packs": "Which industry packs are installed. Seeded.",
  "/administration/permissions":
    "Roles, grants and who holds what. Seeded, and proved by the grant suites rather than walked.",
  "/administration/tenant":
    "Where a platform operator builds the months of demonstration history. Setup before the demonstration, not a step in either flow.",
  "/administration/terminology": "What the tenant calls things. Seeded.",
  "/commercial/price-book": "The vendor's own price book, on the platform's organisation.",
  "/commercial/quotes":
    "The vendor's own quotes, on the platform's organisation. Not a tenant selling to its customers.",
  "/finance/account-determination":
    "Which nominal account each posting lands on. Seeded, and what the four ties then test.",
  "/finance/dimensions": "Analysis dimensions and the rules over their combinations. Seeded.",
  "/finance/cost-centres": "Cost centres, and what a posting is stamped with. Seeded.",
  "/finance/journals":
    "Accruals and corrections typed by hand. Financials draws it as a step, and neither flow needs one: every posting on the demo path comes from a document.",
  "/governance": "Change requests and approvals over configuration, not over documents.",
  "/inventory/adjustments":
    "Where a stock adjustment is written. The seeded month contains one; nobody types it during the demonstration.",
  "/inventory/audit":
    "Counting programmes and the count tasks they raise. Neither flow counts anything.",
  "/inventory/forecast":
    "Demand forecasting. Nothing on either flow is forecast; the demand is the order in front of you.",
  "/inventory/transfers":
    "Where an inter-site transfer is raised. The seeded month contains one; nobody raises it during the demonstration.",
  "/inventory/warehouse":
    "Zones, locations and storage rules. Seeded, and what put-away then follows.",
  "/logistics/release-areas": "Allocated stock scopes, replenishment and print gating.",
  "/master-data": "Products, parties and units. Seeded.",
  "/master-data/classification": "Hierarchies and attributes over the products. Seeded.",
  "/master-data/imports":
    "Loading data in from files. The demonstration organisation is seeded from a door, not a spreadsheet.",
  "/master-data/item-supply": "Which supplier supplies which product, and on what terms. Seeded.",
  "/operations/continuity": "Backup, restore and the drill over them.",
  "/operations/cutover":
    "Opening balances and the parallel run, for a real go-live rather than a demonstration.",
  "/operations/devices": "The scanners and printers registered to this organisation.",
  "/operations/integrations": "Inbound and outbound connections to other systems.",
  "/operations/jobs":
    "The scheduled work behind the screens, including the one that sends the email.",
  "/operations/output": "Printers, templates and what has been produced.",
  "/planning":
    "Demand and supply planning. Planned orders are one way an order is raised; the demo path raises one from a requisition instead.",
  "/production": "Manufacturing. Out of scope for v1 beyond entitlement gating.",
  "/quality": "Inspection and release. Nothing on the demo path is inspected.",
  "/reporting": "The report catalogue. The four ties are read on the screens that own the figures.",
  "/reporting/distribution": "Who a report goes to, and when it is sent to them.",
  "/reporting/reproducibility": "Proving a report gives the same answer twice over the same data.",
};
