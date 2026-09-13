-- The first time the build asked whether every door has a home.
--
-- erp.assert_doors_have_a_home() has existed since 6 September
-- (20260906139000), but the step that calls it with the application's door
-- list runs after the catalogue, and no push since then got that far. PR 84
-- was the first, and the register was out of date in both directions.
--
-- Two rows are stale. erp_platform_enquiries and erp_platform_erase_enquiry
-- were registered as pending_screen for /platform; the console's enquiries
-- panel (src/components/platform/enquiries.tsx) has since been built and names
-- both. A row for a door a screen names fails the build by name, and should:
-- left in, the register says the backlog is longer than it is.
--
-- Five doors have neither a screen nor a row. One is opened by name by the
-- acceptance harness, whose wrapper refuses the build if it calls anything
-- but a door; four are controls the desk does not have yet, and the register's
-- honest answer for those is pending_screen with the path they belong on.
--
-- And one thing that is not about doors. 20260912260000 gave the promoter's
-- document_type branch back and closed with a grant pass rather than a proof.
-- A migration is written once, so the proof lands here instead:
-- erp_test.assert_chart_alternative_suite() configures procurement controls on
-- an organisation of its own, which puts the purchase_invoice document_type
-- item through the promoter — the exact path 20260912250000 broke. On live
-- that runs inside the deploy, rather than the first time somebody presses the
-- button.

-- ── 1. The two doors that found their screen ────────────────────────────────

delete from erp_meta.api_only_door
 where function_name in ('erp_platform_enquiries', 'erp_platform_erase_enquiry');

-- ── 2. The five that had none ───────────────────────────────────────────────

insert into erp_meta.api_only_door (function_name, caller, intended_screen_path, reason) values
  ('erp_create_document', 'suite_evidence', null,
   'Opens a document in a named company or currency, or with a stock owner. The desk raises documents through erp_create_document_full, which is named and takes neither; the D23 acceptance harness (erp_test.second_organisation_suite) and the grant suite open their fixtures through this door by name, because the harness wrapper refuses the build if a single erp.* function is called.'),
  ('erp_mark_document_issue_sent', 'pending_screen', '/documents/$documentId',
   'Records that a completed issue left the organisation by post, or by a mailer outside the product. Issuing, amending and reprinting are reached through src/lib/document-output.functions.ts; marking sent is not, and belongs beside them on the document page.'),
  ('erp_void_document_issue', 'pending_screen', '/documents/$documentId',
   'Cancels a completed issue that has not been sent; the number stays spent and the row stays readable. erp_amend_sales_invoice voids and reissues a sales invoice in one step; this is the void on its own, for an issue of any kind that should not be reissued, and belongs beside it on the document page.'),
  ('erp_sales_invoice_issue_readiness', 'pending_screen', '/documents/$documentId',
   'Whether a sales invoice is ready to be issued, and what is missing if it is not. The document page has no issue control yet; when it does, this is what the control reads before it is pressed.'),
  ('erp_payment_proposal_lines', 'pending_screen', '/finance',
   'The lines of one payment proposal: who is paid how much. /finance lists payment proposals through erp_payment_proposals and acts on them; the panel that opens one proposal and shows its lines is not built yet.')
on conflict (function_name) do update
  set caller = excluded.caller,
      intended_screen_path = excluded.intended_screen_path,
      reason = excluded.reason;

-- ── 3. The register names doors that exist ──────────────────────────────────
--
-- The build proves the whole register against the application's list; this
-- only refuses a typo in the five names above before the file is pushed and
-- becomes immutable.

do $register$
declare v_missing text[];
begin
  select array_agg(n order by n) into v_missing
    from unnest(array['erp_create_document', 'erp_mark_document_issue_sent',
                      'erp_payment_proposal_lines', 'erp_sales_invoice_issue_readiness',
                      'erp_void_document_issue']) as n
   where not exists (select 1 from erp.door_manifest() m where m.door = n);
  if v_missing is not null then
    raise exception 'CLOVEERP_API_ONLY_DOOR_MISSING: registered door(s) do not exist: %',
      array_to_string(v_missing, ', ')
      using errcode = 'P0001';
  end if;
end
$register$;

-- ── 4. The register's own suite, and the proof 20260912260000 did not carry ─
--
-- erp.assert_doors_have_a_home() takes the application's list and only the
-- build has it (erp_meta.check_run_exemption), so the register is proved
-- there; its suite runs here.

select erp_test.assert_door_register_suite();
select erp_test.assert_chart_alternative_suite();
