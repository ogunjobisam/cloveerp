-- 1. Internal metadata tables: explicit deny-all on the data API roles.
do $$
declare t text;
begin
  foreach t in array array[
    'attribution_exemption','audit_exemption','command_transition','company_owner',
    'maintainable_field','ownership_transfer','platform_audit','platform_staff',
    'public_write_allowance','security_definer_allowance','sensitive_object',
    'table_policy','transaction_path_function'
  ] loop
    execute format('drop policy if exists no_data_api_access on erp_meta.%I', t);
    execute format(
      'create policy no_data_api_access on erp_meta.%I as permissive for all to anon, authenticated using (false) with check (false)', t);
  end loop;
end $$;

-- 2. Reviewed SECURITY DEFINER routines, with the reason each one is definer.
insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public','erp_complete_warehouse_task','Writes stock movements and task completion under erp.authorise(inventory.move); definer is required because erp tables are unreachable by the authenticated role.'),
  ('public','erp_merge_batches','Traceability merge across batch and movement tables; gated by erp.authorise(inventory.adjust) and audited.'),
  ('public','erp_raise_putaway_tasks','Creates warehouse tasks from receipt balances; gated by erp.authorise(inventory.move).'),
  ('public','erp_raise_replenishment_tasks','Creates replenishment tasks from stocking policy; gated by erp.authorise(inventory.move).'),
  ('public','erp_seed_demo_operations','Demonstration data builder; gated by erp.authorise(administration.configure) and confined to the calling tenant.'),
  ('public','erp_set_active_tenant','Company selection for the signed-in principal; refuses unless the caller is platform staff.')
on conflict do nothing;

-- 3. One account, one company.
create or replace function public.erp_set_active_tenant(p_tenant_id uuid)
returns jsonb language plpgsql set search_path to '' as $fn$
declare v_is_staff boolean;
begin
  v_is_staff := (select (erp_meta.platform_actor()).id is not null);

  if not v_is_staff then
    raise exception 'ERPWARE_TENANT_FIXED: an account belongs to exactly one company'
      using errcode = '42501',
            hint = 'Platform staff change company from the platform console, which records the access. Everyone else needs an invitation.';
  end if;

  return jsonb_build_object('tenant_id', erp.set_active_tenant(p_tenant_id));
end
$fn$;
revoke all on function public.erp_set_active_tenant(uuid) from public, anon;
grant execute on function public.erp_set_active_tenant(uuid) to authenticated;

-- 4. Terminology keys the interface asks for by name.
insert into erp_ref.resource (key, locale, value, description) values
  ('action.sign_out','en','Sign out','Account menu'),
  ('nav.platform_console','en','Platform console','Account menu'),
  ('nav.tenant_settings','en','Tenant settings','Account menu'),
  ('nav.your_company','en','Your company','Account menu'),
  ('module.tenant_lifecycle','en','Tenant lifecycle','Module title'),
  ('module.terminology','en','Terminology','Module title'),
  ('module.governance','en','Change requests and approvals','Module title'),
  ('module.imports','en','Imports','Module title')
on conflict (key, locale) do nothing;

-- 5. The wording used across module screens, keyed from its own source text so
--    a tenant can rename any of it without a release.
create or replace function erp_ref.ui_key(p_text text)
returns text language plpgsql immutable set search_path to '' as $fn$
declare s text; h bigint := 2166136261; i int; d text := '0123456789abcdefghijklmnopqrstuvwxyz'; o text := ''; n bigint;
begin
  for i in 1..length(p_text) loop
    h := ((h # ascii(substring(p_text from i for 1))) * 16777619) & 4294967295;
  end loop;
  n := h;
  if n = 0 then o := '0'; end if;
  while n > 0 loop
    o := substr(d, (n % 36)::int + 1, 1) || o;
    n := n / 36;
  end loop;
  s := regexp_replace(lower(p_text), '[^a-z0-9]+', '_', 'g');
  s := trim(both '_' from left(trim(both '_' from s), 40));
  if s = '' then s := 'x'; end if;
  return 'ui.' || s || '_' || o;
end
$fn$;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v), 'en', v, 'Interface wording'
  from unnest(array[
    'Accept','Accept with concession','Account','Accuracy %','Acknowledged','Action','Active recalls',
    'Adopt the stocking policy the engine calculates for one item and site.','Age (days)','Age band','Ageing',
    'Allocate a landed cost','Allocated','Allow self-invoice','Amount','Apply calculated policy','Apply cash',
    'Approve a payment run','Arrived on','Ask a counting programme for its next set of tasks.',
    'Ask the warehouse to move what is standing in goods-in.','Assembly','Asset','Assurance','Audit finding',
    'Audit log','Available','Awaiting despatch','Balance','Band','Basis','Batch','Batch ids','Batch number',
    'Batches','Batches reaching their expiry inside thirty days.','Below cover','Blank means all of it.',
    'Book a shipment','Book operation time','Breadcrumb','Candidate','Carrier','Carrier code','Change requests',
    'Characteristic','Class','Classification','Close a period','Close a quality event','Close a works order','Code',
    'Combine one batch into another of the same item and condition.','Comma separated.','Complaint',
    'Complete a close task','Complete a warehouse task','Completed','Completeness and validity of party master records.',
    'Completion','Configuration','Corrective action','Cost','Cost basis by item and site, in minor units.',
    'Count accuracy','Count tasks','Counted','Counted quantity','Cover against policy, by item and site.','Coverage %',
    'Coverage by section','Coverage could not be measured.','Credit','Critical','Currency','Current','Customer',
    'Customers overdue enough to contact.','Dashboard',
    'Data quality, duplicates and specification coverage, read from operational tables.','Days left','Debit',
    'Default 180.','Deliveries','Delivery ids','Delivery performance','Depreciation','Destroy','Deviation',
    'Disassembly','Disposition','Disposition an inspection','Done','Dunning worklist','Duplicate candidates','Errors',
    'Events by kind','Events, dispositions, supplier qualification and recall — each with a clock.',
    'Every account with a movement, by ledger.','Everything raised, with progress against the ordered quantity.',
    'Exceptions by kind','Excursion','Expected','Expiring in 30 days','Expiry horizon','Finance','Fixed assets',
    'Forecast code','From','Go-live, export and portability, deletion.','Goods received not invoiced',
    'Group deliveries leaving one site on one day.','High','History buckets','Horizon (days)',
    'How close the counts came, by programme.','How long stock has been standing still.','Imports','In full',
    'In minor units — pence, cents.','Install modules and promote the change sets that put them in force.',
    'Instrument','Integrations','Intercompany position','Inventory','Invoice a delivery','Issue components','Item',
    'Kind','Kitting','Ledger','Ledgers','Likely duplicate parties, for merge with a survivor and a reason.',
    'Location','Log a recall action','Logistics','Low','Master data','Matched','Measured value','Medium',
    'Merge two batches','Message','Minutes','Name','Near miss','Needs chasing','Net',
    'Net and tax by code for the current period.','Net book value','New batch number','No','No aged stock to profile.',
    'No aged stock.','No batches yet.','No count tasks raised.','No counts posted yet, so accuracy cannot be stated.',
    'No deliveries in the window.','No exceptions to profile.','No exceptions — the plan is currently consistent.',
    'No fiscal calendar yet.','No fixed assets recorded.','No intercompany balances.',
    'No ledger configured. Installing the finance module is what creates one.','No likely duplicates.',
    'No party master data to assess yet.','No planned orders. Nothing is short against current demand.',
    'No quality events open.','No quality events to profile.','No recalls. This is the panel you want to stay empty.',
    'No shipments planned.','No stock positions yet — nothing has moved into this tenant.',
    'No supplier qualifications recorded.','No taxable transactions in this period.','No warehouse tasks outstanding.',
    'No works orders raised.','No works orders to profile.','Nobody needs chasing.','Non-conformance',
    'Non-conformance, complaint, deviation and their investigations.','Note',
    'Nothing expires in the next thirty days.','Nothing is old enough to provide against.',
    'Nothing outstanding to profile.','Nothing outstanding.','Nothing posted yet.',
    'Nothing received awaiting an invoice.','Nothing to value yet.','Number','OTIF','OTIF %','OTIF by customer',
    'Observed value','On hand','On time','On time in full, last ninety days.',
    'On time, in full, over the last ninety days.',
    'One published policy: nothing under ninety days, a quarter to six months, half to a year, all of it beyond.',
    'Open a period close','Open events','Open exceptions','Open periods','Open shipments','Open works orders',
    'Operation','Order line','Ordered','Outbound gateway health and the queue that needs a decision.','Overdue',
    'Overdue 60+','Part 5 of the foundation specification, measured against the database.',
    'Part 5, section by section, measured against the database.','Party','Party data quality','Payment date',
    'Period','Periods','Periods ahead','Permissions','Plan a shipment','Planned and despatched loads.',
    'Planned despatch','Planned finish','Planned orders',
    'Planned orders and the exceptions worth acting on before they become shortages.','Planned quantity','Planning',
    'Planning exceptions','Post a count','Present','Preventive action','Primary',
    'Principals, roles, and the grants between them.','Procurement','Production','Programme','Programme code',
    'Propose a payment run','Proposed master data changes and the approvals on them.',
    'Proposed supply, with the date it has to be released to land on time.','Provision %','Provision (minor)',
    'Putaway and replenishment, raised from the balances and waiting on a truck.','Qualified suppliers',
    'Quality and recall','Quality events','Quantity','Quantity by age band.','Quantity in progress',
    'Quantity recovered','Quantity to split','Quarantine','Quotations, orders and deliveries.','Raise a quality event',
    'Raise a recall','Raise a works order','Raise count tasks','Raise putaway tasks','Raise replenishment tasks',
    'Raised by the counting programme and waiting on a person.','Rate %','Reason','Recalls','Receipt','Receivables',
    'Receivables ageing','Receive output','Received against a purchase order, still awaiting an invoice.','Record',
    'Record a count','Record an inspection result','Record proof of delivery',
    'Recorded against the action in the audit trail.','Records with errors','Reference',
    'Regenerate planned orders and exceptions for one site.','Reject','Release a batch','Release a works order',
    'Release despite shortages','Reopen a period','Repackaging','Reporting','Reports','Required by',
    'Requisitions, purchase orders and goods receipts.','Rework','Root cause','Run a forecast','Run planning','Sales',
    'Scheduled jobs','Scope, clock and progress. The deadline is a configured regulatory clock.','Score','Scrapped',
    'Section','Select a carrier','Service','Service code','Severity','Shipments',
    'Shipments, carrier bookings and delivery performance, with cost landing on stock.','Sign off a forecast',
    'Signature','Signed by','Site','Slow-moving stock provision','Specification coverage','Split a batch','Stage',
    'Staged batches, preview, validation, load and rollback.','State','Status','Stock ageing','Stock health',
    'Stock health, valuation, ageing, expiry and counting, all derived from the ledger.','Stock lines','Stock value',
    'Supplier','Supplier lot','Supplier qualification','Tax','Tax report','Tenant lifecycle','Terminology',
    'The books this tenant keeps.','The database authorises every one of these; you only see the ones you hold.',
    'The fiscal calendar and where it is open.','The full register, including closed orders.',
    'The items and parties every document depends on.','The register as at today.',
    'The structural checks the build runs on every push.','The wording of every label, per tenant.',
    'Three-letter code.','Title','To','Top the pick faces up from reserve where demand exceeds what is there.',
    'Total','Traceable units, with their genealogy anchors.','Tracking','Trial balance',
    'Trial balance, periods, receivables, tax and assets, read from the posted ledger.',
    'Turn a counted task into a stock adjustment.','Type','Unacknowledged','Valuation','Value','Value (minor)',
    'Variance','Waiver reason','Warehouse tasks','Warnings','What each entity owes another, before elimination.',
    'What is being raised against quality.','What is outstanding, and for how long.',
    'What is running, what failed, and what has stopped running.','What the last planning run could not reconcile.',
    'Where the plan is inconsistent.','Where the shop floor currently sits.',
    'Who did what, to which object, and when — filterable by action, object, actor and date.',
    'Who is approved to supply what, and until when.','Within tolerance','Work','Works order register','Works orders',
    'Works orders and their progress against plan, quantity by quantity.','Works orders by status','Write off stock',
    'Year','Yes','across all planned orders','average party record score','awaiting release',
    'in the last ninety days','item and site positions','of Part 5, measured','of ordered quantity',
    'on time in full, ninety days','ordered less completed','outstanding, all customers','past sixty days','units'
  ]) as v
on conflict (key, locale) do nothing;