-- Refusals and toasts speak plainly.
--
-- Walking the live desk on 14 September, the owner met a product still talking
-- to the people who built it:
--
--   * Invoicing a delivery you despatched yourself read "This is not allowed
--     right now. you despatched DN-000255 and cannot also invoice it B1 has
--     carried sales.despatch and sales.invoice as separate permissions since
--     it was written; …". The sentence started in lower case, and the raise's
--     hint — a note for whoever maintains erp.invoice_from_delivery — was
--     shown as the next step. The token was in no register, so nothing said
--     what to do.
--   * A new requisition toasted "New requisition — done.", and a dialog
--     opened from a step with nothing chosen said it was "Acting on" the
--     step's own description.
--   * A document's breadcrumb was its UUID and its subtitle "purchase_order";
--     Cancel was drawn like Submit.
--   * My approvals said OBJECT "document" and STEP "—".
--   * The putaway picker read "putaway — FG-5000 — RECV — BULK", Plan a
--     shipment offered two hundred deliveries sent months before, the Close
--     step opened on December next year, and Run planning said "done".
--
-- The desk now capitalises a sentence from the database, ends it with a stop,
-- and does not show one written for the engine's maintainers
-- (src/lib/plain-words.ts). What is held here:
--
--   1. The refusal register, in the words of the people it refuses. Every
--      registered refusal was read. Twelve said something only the people who
--      build Clove ERP would follow — a section of the specification (§17.6,
--      §9.3, D5, D37), "primitives", "sweeps", "row-level security", "the
--      transitions it offers", a path, bytes, "the rendering step" — or read
--      as a note to a colleague ("Absence of a grant is a refusal, not a
--      default."). Each is re-registered through erp.register_refusal, which
--      writes the row and its three resource keys together; the codes do not
--      change, and a re-registration updates rows and adds none, which the
--      block below counts. CLOVEERP_SEGREGATION_OF_DUTIES, the refusal the
--      owner met, is registered for the first time: three new strings.
--
--   2. public.erp_my_approvals says what is being approved: the document's id,
--      number, type name, business partner, value and currency, and the
--      step's code and name. Every key it returned before is returned as
--      before, so the signature and the callers stand.
--
--   3. public.erp_warehouse_tasks names the locations as well as their codes,
--      so a task reads "from Goods in to Bulk store".
--
--   4. public.erp_deliveries_to_ship(p_site_id, p_within_days, p_limit), a
--      read: the posted deliveries of one site, from the last thirty days
--      unless asked otherwise, that no shipment still standing carries. It is
--      what Plan a shipment offers. It authorises nothing and reads under row
--      security as the caller.
--
--   5. The words the desk now shows, each with a row it can be renamed by.
--
-- Proof: erp_test.plain_words_suite(), nine cases, pinned by its wrapper.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The refusal register, in plain words
-- ═════════════════════════════════════════════════════════════════════════════

do $register$
declare
  v_before  integer;
  v_after   integer;
  v_new     integer;
  v_short   text;
  w         record;
begin
  create temp table if not exists _plain_words_refusal (
    code text primary key, refused text not null, why text not null, next_action text not null
  ) on commit drop;
  truncate _plain_words_refusal;

  insert into _plain_words_refusal (code, refused, why, next_action) values
  -- refusal texts: begin
    ('CLOVEERP_LEGISLATION_IS_NOT_PRICED',
     'A non-nil rate on a legislation pack.',
     'A legislation pack is priced at nil, because the rules of a country are not a product to sell.',
     'Set the rate to zero, or price the plan rather than the pack.'),
    ('CLOVEERP_NO_PLATFORM_ORGANISATION',
     'A commercial action before a platform organisation is designated.',
     'Clove ERP runs its own quotes, contracts and invoices inside one organisation of its own, and until one is chosen there is nowhere to run them.',
     'A platform owner designates the platform organisation on the console''s Contracts view.'),
    ('CLOVEERP_SIGNATURE_INCOMPLETE',
     'A signature without both signers and what signing means.',
     'A signature records who signed on each side, what signing means and a fingerprint of the document, and one missing any of them proves nothing.',
     'Name the customer signer, the platform signer and what the signature means.'),
    ('CLOVEERP_UNKNOWN_LEGISLATION_PACK',
     'A legislation pack price item naming a pack the platform does not ship.',
     'Only the legislation packs Clove ERP ships can be sold, and a pack that does not exist cannot be given to anyone.',
     'Choose a legislation pack from the ones the platform ships.'),
    ('CLOVEERP_PERMISSION_DENIED',
     'An action the account holds no permission for.',
     'Nothing is allowed unless one of your roles includes it, and none of them includes this.',
     'An administrator can grant the missing permission under People and permissions.'),
    ('CLOVEERP_UNTRUSTED_SWEEP',
     'Running a routine that reads every organisation from an ordinary signed-in session.',
     'A routine that reads every organisation is run only by Clove ERP''s own scheduler and its operators.',
     'Let the scheduled job run it, or run it from the platform console as an operator.'),
    ('CLOVEERP_CONTRACT_TERMS_UNKNOWN',
     'A renewal kind or billing frequency the platform does not recognise.',
     'A contract''s terms decide when it renews and when it is invoiced, and a term Clove ERP does not recognise would decide neither.',
     'Choose a renewal kind of automatic, by agreement or none, and a billing frequency of annual, quarterly or monthly.'),
    ('CLOVEERP_DOCUMENT_OBJECT_MISSING',
     'Recording an issued document whose file is not in the archive.',
     'The number was reserved, but no file was found in the document archive, so there would be nothing to reprint later.',
     'Issue the document again. If it keeps failing, contact support, because the document file is not being produced.'),
    ('CLOVEERP_DOCUMENT_OBJECT_FOREIGN',
     'Recording a file kept outside this organisation''s own folder.',
     'Every issued file is kept in its own organisation''s folder in the archive, and a file anywhere else could be another organisation''s document.',
     'Issue the document again from this organisation.'),
    ('CLOVEERP_DOCUMENT_OBJECT_NOT_PDF',
     'Recording an issued document that is not a PDF.',
     'The archive holds issued documents as PDFs only, so that a reprint returns the same readable file years later.',
     'Issue the document again.'),
    ('CLOVEERP_DOCUMENT_CHECKSUM_MISMATCH',
     'Recording a fingerprint that does not match the stored file.',
     'The fingerprint kept with the number must be the fingerprint of the file actually stored, or a reprint cannot be shown to be the original.',
     'Issue the document again, so that the file and its fingerprint are written together.'),
    ('CLOVEERP_QUOTE_IS_%',
     'An action on a quote whose state does not permit it.',
     'A quote moves through draft, approval, issue and acceptance in order, and the action asked for belongs to a different state.',
     'Open the quote to see where it stands and what can be done next, or revise it to start a new version.'),
    ('CLOVEERP_SEGREGATION_OF_DUTIES',
     'Doing both halves of a job the organisation keeps for two people.',
     'Invoicing goods you despatched yourself, or approving a payment run you proposed, would let one person complete and hide a whole transaction, so the organisation keeps the two steps apart.',
     'Ask a colleague who may do this step to do it. Where the organisation accepts one person doing both, an administrator can record an exception.');
  -- refusal texts: end

  -- Twelve rewritten, one new. A rewrite of a code that is not registered
  -- would be a new refusal under a rewrite's name.
  select string_agg(t.code, ', ' order by t.code) into v_short
    from _plain_words_refusal t
   where t.code <> 'CLOVEERP_SEGREGATION_OF_DUTIES'
     and not exists (select 1 from erp_ref.refusal f where f.code = t.code);
  if v_short is not null then
    raise exception 'CLOVEERP_REWRITE_OF_NOTHING: % is not in the register to be rewritten', v_short
      using hint = 'A later migration renamed or removed the refusal. Rewrite the code the register holds now.';
  end if;

  select count(*) into v_new
    from _plain_words_refusal t
   where not exists (select 1 from erp_ref.refusal f where f.code = t.code);
  select count(*) into v_before from erp_ref.resource where locale = 'en';

  for w in select * from _plain_words_refusal order by code loop
    perform erp.register_refusal(w.code, w.refused, w.why, w.next_action);
  end loop;

  -- A re-registration updates the row and its three keys and adds no string;
  -- a first registration adds exactly three. CLOVEERP_SEGREGATION_OF_DUTIES is
  -- the one new code, unless a migration before this one registered it.
  select count(*) into v_after from erp_ref.resource where locale = 'en';
  if v_new > 1 or v_after <> v_before + 3 * v_new then
    raise exception 'CLOVEERP_REGISTER_ADDED_STRINGS: % new refusal(s), and the dictionary moved from % to % rows', v_new, v_before, v_after
      using hint = 'Re-registering a refusal writes over its three resource keys. A row count that moved otherwise means a key was missing before, or the register writer changed.';
  end if;

  -- What was written is what the register and the dictionary now say.
  select string_agg(t.code, ', ' order by t.code) into v_short
    from _plain_words_refusal t
   where not exists (
           select 1 from erp_ref.refusal f
            where f.code = t.code and f.refused = t.refused and f.why = t.why
              and f.next_action = t.next_action)
      or (select count(*) from erp_ref.resource r
           where r.locale = 'en'
             and ((r.key = erp_ref.refusal_key(t.code, 'refused') and r.value = t.refused)
               or (r.key = erp_ref.refusal_key(t.code, 'why') and r.value = t.why)
               or (r.key = erp_ref.refusal_key(t.code, 'next_action') and r.value = t.next_action))) <> 3;
  if v_short is not null then
    raise exception 'CLOVEERP_REFUSAL_REWRITE_SHORT: the register or its dictionary does not say what was written for %', v_short
      using hint = 'Row security refused the write, or the register writer no longer mirrors all three parts.';
  end if;

  drop table _plain_words_refusal;
end
$register$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. My approvals says what is being approved
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_my_approvals()
returns jsonb language sql stable set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id', t.id, 'approval_request_id', t.approval_request_id,
    'object_type', ar.object_type, 'object_id', ar.object_id,
    'seq', t.seq, 'status', t.status, 'assigned_at', t.created_at,
    'requested_by', a.display_name, 'requested_at', ar.requested_at,
    'context', ar.context,
    -- The step, by the name its chain gives it.
    'step_code', t.step_code,
    'step_name', coalesce(nullif(btrim(st.name), ''), t.step_code),
    -- What is being approved, when it is a document.
    'document_id', d.id,
    'document_number', d.document_number,
    'document_type', dt.code,
    'document_type_name', dt.name,
    'partner', p.name,
    'value_minor', case when d.id is not null then erp.document_value_minor(d.id) end,
    'currency', d.currency) order by t.created_at), '[]'::jsonb)
    from erp.approval_task t
    join erp.approval_request ar on ar.tenant_id = t.tenant_id and ar.id = t.approval_request_id
    left join erp.app_user a on a.tenant_id = ar.tenant_id and a.id = ar.requested_by
    left join erp.approval_step st on st.tenant_id = t.tenant_id and st.id = t.approval_step_id
    left join erp.document d
      on ar.object_type = 'document' and d.tenant_id = ar.tenant_id and d.id = ar.object_id
    left join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
    left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
   where t.tenant_id = erp.current_tenant_id()
     and t.status = 'pending'::erp.approval_task_status
     and (t.assignee_user_id = erp.current_principal_id()
          or exists (select 1 from erp.effective_permission ep
                      where ep.app_user_id = erp.current_principal_id()
                        and ep.role_id = t.assignee_role_id))
$$;

comment on function public.erp_my_approvals() is
  'The approval tasks waiting on the caller, directly or through a role they '
  'hold: the request, who asked and when, the step by code and name, and for a '
  'document its number, type name, business partner, value and currency. '
  'Reads under row security as the caller, and authorises nothing.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A warehouse task names its locations
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_warehouse_tasks(
  p_site_id uuid default null, p_kind text default null, p_limit integer default 200)
returns jsonb language sql stable security invoker set search_path to '' as $$
  select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) from (
    select jsonb_build_object(
             'task_id', t.id, 'kind', t.kind, 'status', t.status,
             'item', i.code, 'item_name', i.name, 'site', s.code,
             'batch', b.batch_number,
             'from_location', fl.code, 'to_location', tl.code,
             'from_location_name', fl.name, 'to_location_name', tl.name,
             'quantity', t.quantity, 'quantity_done', t.quantity_done,
             'created_at', t.created_at, 'completed_at', t.completed_at) as x
      from erp.warehouse_task t
      join erp.item i on i.tenant_id = t.tenant_id and i.id = t.item_id
      join erp.site s on s.tenant_id = t.tenant_id and s.id = t.site_id
      left join erp.batch b on b.tenant_id = t.tenant_id and b.id = t.batch_id
      join erp.location fl on fl.tenant_id = t.tenant_id and fl.id = t.from_location_id
      join erp.location tl on tl.tenant_id = t.tenant_id and tl.id = t.to_location_id
     where t.tenant_id = erp.current_tenant_id()
       and (p_site_id is null or t.site_id = p_site_id)
       and (p_kind is null or t.kind = p_kind)
     order by t.created_at desc
     limit greatest(p_limit, 1)) q;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The deliveries a shipment can carry
-- ═════════════════════════════════════════════════════════════════════════════

create function public.erp_deliveries_to_ship(
  p_site_id     uuid,
  p_within_days integer default 30,
  p_limit       integer default 200
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x ->> 'document_date' desc, x ->> 'document_number' desc),
                  '[]'::jsonb)
    from (
      select jsonb_build_object(
               'document_id', d.id, 'document_number', d.document_number,
               'document_date', d.document_date, 'party', p.name,
               'state', s.code, 'state_name', s.name) as x
        from erp.document d
        join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
        join erp.object_state os
          on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
        join erp.state s on s.id = os.current_state_id
        left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
       where d.tenant_id = erp.current_tenant_id()
         and dt.base_type_code = 'delivery'
         and d.site_id = p_site_id
         and s.code = 'posted'
         and not d.is_cancelled
         and (p_within_days is null or d.document_date >= current_date - p_within_days)
         -- Not on a shipment already, unless that shipment was cancelled.
         and not exists (
               select 1
                 from erp.shipment_line sl
                 join erp.shipment sh on sh.tenant_id = sl.tenant_id and sh.id = sl.shipment_id
                where sl.tenant_id = d.tenant_id
                  and sl.document_id = d.id
                  and sh.status <> 'cancelled')
       order by d.document_date desc, d.document_number desc
       limit greatest(coalesce(p_limit, 200), 1)
    ) t
$$;

comment on function public.erp_deliveries_to_ship(uuid, integer, integer) is
  'The posted deliveries of one site that no shipment still standing carries, '
  'dated within the last p_within_days days (30 unless asked; null for any '
  'date), newest first: what Plan a shipment offers. Reads under row security '
  'as the caller, and authorises nothing.';

revoke all on function public.erp_deliveries_to_ship(uuid, integer, integer) from public, anon;
grant execute on function public.erp_deliveries_to_ship(uuid, integer, integer) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The words on the screens
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('Approving',
     'My approvals: the column naming what is being approved, a document by its number and type.'),
    ('Approval waiting on me',
     'Deciding an approval: the picker of the tasks waiting on the person deciding.'),
    ('Posted deliveries from the site above, from the last 30 days, that are not on a shipment yet. Tick every one travelling on this shipment.',
     'Plan a shipment: what the deliveries offered are.'),
    ('Show future and finished periods',
     'The Close step: also list periods not yet started and periods already finished.')
) as v(text, why)
on conflict (key, locale) do nothing;

do $words$
declare v_missing text;
begin
  select string_agg(quote_literal(t.text), ', ' order by t.text) into v_missing
    from (values
      ('Approving'),
      ('Approval waiting on me'),
      ('Posted deliveries from the site above, from the last 30 days, that are not on a shipment yet. Tick every one travelling on this shipment.'),
      ('Show future and finished periods')
    ) as t(text)
   where not exists (select 1 from erp_ref.resource r
                      where r.key = erp_ref.ui_key(t.text) and r.locale = 'en');
  if v_missing is not null then
    raise exception 'CLOVEERP_SCREEN_STRINGS_SHORT: no resource row for %', v_missing
      using hint = 'Row security refused the write, or erp_ref.ui_key changed. Seed the row the desk asks for.';
  end if;
end
$words$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The proof
-- ═════════════════════════════════════════════════════════════════════════════

-- The wording a customer is never shown, as src/lib/plain-words.ts's
-- INTERNAL_WORDING says it: a section of the specification (§17.6, B1, D34,
-- Part 5, v1.5), a permission code (sales.despatch, master_data.write), a
-- function, table or schema (erp.invoice_from_delivery, erp_ref.refusal,
-- erp_x), any identifier written with an underscore, a refusal token, "since
-- it was written", row-level security, SQLSTATE, jsonb or uuid.
create or replace function erp_test.sounds_internal(p_text text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    p_text ~ ('§'
      || '|\m[BD][0-9]{1,2}\M'
      || '|\mPart [0-9]{1,2}\M'
      || '|\mv[0-9]+\.[0-9]+\M'
      || '|\m(administration|commercial|documents?|finance|governance|inventory|logistics|master_data|operations|planning|platform|procurement|production|quality|reporting|sales)\.[a-z][a-z_]*\M'
      || '|\m(erp|erp_meta|erp_ref|erp_test|erp_ai|public|pg_catalog)\.[a-z_]+'
      || '|\merp_[a-z0-9_]+'
      || '|\m[a-z][a-z0-9]*_[a-z0-9_]+\M'
      || '|\m(CLOVEERP|ERP[W]ARE)_[A-Z0-9_]+')
    or p_text ~* 'since it was written|\mrow[- ]level security\M|\m(sqlstate|jsonb|uuid)\M',
    false)
$$;

comment on function erp_test.sounds_internal(text) is
  'Whether a sentence carries wording written for the people who build Clove '
  'ERP rather than those who use it. The same patterns as INTERNAL_WORDING in '
  'src/lib/plain-words.ts, which keeps such a sentence off the screens.';

create or replace function erp_test.plain_words_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_hex     text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1        uuid := gen_random_uuid();
  r         record;
  v_state   text;
  v_bad     text;
  v_count   integer;
  v_caught  text;
  v_passed  text;
  v_diverge text;
  v_sod     boolean;
  -- The doors as the catalogue holds them.
  v_an      integer;
  v_aargs   text;
  v_adef    boolean;
  v_astable boolean;
  v_agrant  boolean;
  v_dn      integer;
  v_dargs   text;
  v_ddef    boolean;
  v_dstable boolean;
  v_dgrant  boolean;
  v_wnames  boolean;
  -- An organisation not yet live, with one person and one order waiting.
  v_uom     uuid;
  v_site    uuid;
  v_sup     uuid;
  v_item    uuid;
  v_po      uuid;
  v_row     jsonb;
  v_number  text;
  v_tname   text;
  v_value   bigint;
  v_curr    text;
  v_step    text;
begin
  -- ── The register ────────────────────────────────────────────────────────
  select count(*), string_agg(f.code, ', ' order by f.code)
    into v_count, v_bad
    from erp_ref.refusal f
   where erp_test.sounds_internal(f.refused)
      or erp_test.sounds_internal(f.why)
      or erp_test.sounds_internal(f.next_action);

  case_name := 'no registered refusal says what only the people who build Clove ERP would follow';
  passed := coalesce(v_count = 0, false);
  detail := coalesce(v_bad, format('%s refusal(s) read, none with a section, a code, a table or an identifier',
                                   (select count(*) from erp_ref.refusal)));
  return next;

  select count(*), string_agg(r2.key, ', ' order by r2.key)
    into v_count, v_bad
    from erp_ref.refusal f
    join erp_ref.resource r2
      on r2.locale = 'en'
     and r2.key in (erp_ref.refusal_key(f.code, 'refused'), erp_ref.refusal_key(f.code, 'why'),
                    erp_ref.refusal_key(f.code, 'next_action'))
   where erp_test.sounds_internal(r2.value);

  case_name := 'nor does the dictionary the screens read a refusal from';
  passed := coalesce(v_count = 0, false);
  detail := coalesce(v_bad, 'refusal.<code>.refused, .why and .next_action are all plain');
  return next;

  select string_agg(t.s, ' | ') filter (where not erp_test.sounds_internal(t.s))
    into v_caught
    from (values
      ('B1 has carried sales.despatch and sales.invoice as separate permissions since it was written; this is the first thing to require that they be held by different people.'),
      ('Legislation packs are priced at nil by default (§17.6).'),
      ('The platform runs its own commercial process on its own primitives (D37).'),
      ('Part 5 says so.'),
      ('Grant master_data.write to them.'),
      ('erp.configure_receivables() installs it.'),
      ('Registered in erp_ref.refusal.'),
      ('The document is pending_approval.'),
      ('Only a session that bypasses row-level security may.')
    ) as t(s);
  select string_agg(t.s, ' | ') filter (where erp_test.sounds_internal(t.s))
    into v_passed
    from (values
      ('Ask a colleague who may do this step to do it.'),
      ('Enter a discount between 0 and 99.99%.'),
      ('Record the customer''s acceptance on the quote first.'),
      ('DN-000255 has no lines, e.g. after a cancellation.')
    ) as t(s);

  case_name := 'the test is not vacuous: the hint a customer was shown is caught, and a plain sentence is not';
  passed := v_caught is null and v_passed is null;
  detail := coalesce('not caught: ' || v_caught, 'wrongly caught: ' || v_passed,
                     'nine internal sentences caught, four plain ones passed');
  return next;

  -- ── The rewrites and the new registration ───────────────────────────────
  select string_agg(f.code, ', ' order by f.code) into v_diverge
    from erp_ref.refusal f
   where f.code in ('CLOVEERP_LEGISLATION_IS_NOT_PRICED', 'CLOVEERP_NO_PLATFORM_ORGANISATION',
                    'CLOVEERP_SIGNATURE_INCOMPLETE', 'CLOVEERP_UNKNOWN_LEGISLATION_PACK',
                    'CLOVEERP_PERMISSION_DENIED', 'CLOVEERP_UNTRUSTED_SWEEP',
                    'CLOVEERP_CONTRACT_TERMS_UNKNOWN', 'CLOVEERP_DOCUMENT_OBJECT_MISSING',
                    'CLOVEERP_DOCUMENT_OBJECT_FOREIGN', 'CLOVEERP_DOCUMENT_OBJECT_NOT_PDF',
                    'CLOVEERP_DOCUMENT_CHECKSUM_MISMATCH', 'CLOVEERP_QUOTE_IS_%',
                    'CLOVEERP_SEGREGATION_OF_DUTIES')
     and (select count(*) from erp_ref.resource r2
           where r2.locale = 'en'
             and ((r2.key = erp_ref.refusal_key(f.code, 'refused') and r2.value = f.refused)
               or (r2.key = erp_ref.refusal_key(f.code, 'why') and r2.value = f.why)
               or (r2.key = erp_ref.refusal_key(f.code, 'next_action') and r2.value = f.next_action))) <> 3;

  case_name := 'the rewritten refusals say the same in the register and in the dictionary';
  passed := v_diverge is null
            and (select count(*) from erp_ref.refusal f
                  where f.code in ('CLOVEERP_LEGISLATION_IS_NOT_PRICED', 'CLOVEERP_NO_PLATFORM_ORGANISATION',
                                   'CLOVEERP_SIGNATURE_INCOMPLETE', 'CLOVEERP_UNKNOWN_LEGISLATION_PACK',
                                   'CLOVEERP_PERMISSION_DENIED', 'CLOVEERP_UNTRUSTED_SWEEP',
                                   'CLOVEERP_CONTRACT_TERMS_UNKNOWN', 'CLOVEERP_DOCUMENT_OBJECT_MISSING',
                                   'CLOVEERP_DOCUMENT_OBJECT_FOREIGN', 'CLOVEERP_DOCUMENT_OBJECT_NOT_PDF',
                                   'CLOVEERP_DOCUMENT_CHECKSUM_MISMATCH', 'CLOVEERP_QUOTE_IS_%')) = 12
            and exists (select 1 from erp_ref.refusal f
                         where f.code = 'CLOVEERP_SIGNATURE_INCOMPLETE' and f.why like '%fingerprint of the document%');
  detail := coalesce('diverged: ' || v_diverge, 'twelve rewritten, each row and its three keys alike');
  return next;

  select exists (select 1 from erp_ref.refusal f
                  where f.code = 'CLOVEERP_SEGREGATION_OF_DUTIES' and btrim(f.next_action) <> '')
     and (select count(*) from erp_ref.resource r2
           where r2.locale = 'en'
             and r2.key in (erp_ref.refusal_key('CLOVEERP_SEGREGATION_OF_DUTIES', 'refused'),
                            erp_ref.refusal_key('CLOVEERP_SEGREGATION_OF_DUTIES', 'why'),
                            erp_ref.refusal_key('CLOVEERP_SEGREGATION_OF_DUTIES', 'next_action'))) = 3
    into v_sod;

  case_name := 'the refusal met on the live desk names a next action an organisation can override';
  passed := coalesce(v_sod, false);
  detail := 'CLOVEERP_SEGREGATION_OF_DUTIES: registered, and refusal.cloveerp_segregation_of_duties.refused, .why and .next_action';
  return next;

  -- ── The doors ───────────────────────────────────────────────────────────
  select count(*), min(pg_catalog.pg_get_function_identity_arguments(p.oid)),
         coalesce(bool_or(p.prosecdef), true),
         coalesce(bool_and(p.provolatile = 's'), false),
         coalesce(bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                           and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')), false)
    into v_an, v_aargs, v_adef, v_astable, v_agrant
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_my_approvals';

  select count(*), min(pg_catalog.pg_get_function_identity_arguments(p.oid)),
         coalesce(bool_or(p.prosecdef), true),
         coalesce(bool_and(p.provolatile = 's'), false),
         coalesce(bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                           and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')), false)
    into v_dn, v_dargs, v_ddef, v_dstable, v_dgrant
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_deliveries_to_ship';

  select coalesce(bool_and(position('''from_location_name''' in p.prosrc) > 0
                           and position('''to_location_name''' in p.prosrc) > 0), false)
    into v_wnames
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_warehouse_tasks';

  case_name := 'My approvals is still one read, taking nothing, run as the caller, for signed-in callers only';
  passed := coalesce(v_an = 1 and v_aargs = '' and not v_adef and v_astable and v_agrant, false);
  detail := format('%s function(s) (%s), definer %s, stable %s, granted %s',
                   v_an, coalesce(v_aargs, 'none'), v_adef, v_astable, v_agrant);
  return next;

  case_name := 'the deliveries a shipment can carry are one read, run as the caller, for signed-in callers only; a task names its locations';
  passed := coalesce(v_dn = 1 and v_dargs = 'p_site_id uuid, p_within_days integer, p_limit integer'
                     and not v_ddef and v_dstable and v_dgrant and v_wnames, false);
  detail := format('%s function(s) (%s), definer %s, stable %s, granted %s; warehouse tasks name locations %s',
                   v_dn, coalesce(v_dargs, 'none'), v_ddef, v_dstable, v_dgrant, v_wnames);
  return next;

  -- ── A document waiting on its approver ──────────────────────────────────
  begin
    select * into r from erp.provision_tenant(
      'zz-words-' || v_hex, 'Plain words suite',
      'admin@zz-words-' || v_hex || '.test', 'Words Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(1000000);

    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Words Supplier Ltd', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'WID', 'Widget', v_uom, 'active') returning id into v_item;

    v_po := erp.open_document('purchase_order', v_sup, null, v_site);
    perform erp.add_document_line(v_po, v_item, 3, 2500, 'Three widgets');
    perform erp.transition_document(v_po, 'submit');

    select x.e into v_row
      from jsonb_array_elements(public.erp_my_approvals()) as x(e)
     where x.e ->> 'object_id' = v_po::text
     limit 1;

    select d.document_number, dt.name, erp.document_value_minor(d.id), d.currency::text
      into v_number, v_tname, v_value, v_curr
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = r.tenant_id and d.id = v_po;

    select coalesce(nullif(btrim(st.name), ''), t.step_code) into v_step
      from erp.approval_task t
      left join erp.approval_step st on st.tenant_id = t.tenant_id and st.id = t.approval_step_id
     where t.tenant_id = r.tenant_id and t.id = (v_row ->> 'task_id')::uuid;

    raise exception 'CLOVEERP_PLAIN_WORDS_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_PLAIN_WORDS_SUITE_UNDO' then
      v_state := left(sqlerrm, 300);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  case_name := 'a document waiting on you says its number, type, business partner, value and step';
  passed := coalesce(v_state is null and v_row is not null
            and v_row ->> 'document_id' = v_po::text
            and v_row ->> 'document_number' = v_number
            and v_row ->> 'document_type_name' = v_tname
            and v_row ->> 'partner' = 'Words Supplier Ltd'
            and (v_row ->> 'value_minor')::bigint = v_value
            and v_row ->> 'currency' = v_curr
            and v_row ->> 'step_name' = v_step
            and v_row ->> 'step_code' is not null, false);
  detail := coalesce(v_state, format('number %s (%s), type %s (%s), partner %s, value %s (%s) %s, step %s (%s)',
                                     v_row ->> 'document_number', v_number, v_row ->> 'document_type_name', v_tname,
                                     v_row ->> 'partner', v_row ->> 'value_minor', v_value, v_row ->> 'currency',
                                     v_row ->> 'step_name', v_step));
  return next;

  case_name := 'and it still says everything it said before';
  passed := coalesce(v_state is null and v_row is not null
            and v_row ?& array['task_id', 'approval_request_id', 'object_type', 'object_id', 'seq',
                               'status', 'assigned_at', 'requested_by', 'requested_at', 'context']
            and v_row ->> 'object_type' = 'document'
            and v_row ->> 'status' = 'pending', false);
  detail := coalesce(v_state, format('keys %s', (select string_agg(k, ', ' order by k)
                                                   from jsonb_object_keys(coalesce(v_row, '{}'::jsonb)) k)));
  return next;
end;
$$;

create or replace function erp_test.assert_plain_words_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*),
         count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from erp_test.plain_words_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_PLAIN_WORDS_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_PLAIN_WORDS_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail
      using hint = 'Read the failed case: a refusal says something only its builders would follow, or My approvals no longer says what is being approved.';
  end if;
  return format('plain words: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;

revoke all on function erp_test.sounds_internal(text) from public, anon, authenticated;
revoke all on function erp_test.plain_words_suite() from public, anon, authenticated;
revoke all on function erp_test.assert_plain_words_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_session_context_hygiene();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_isolation();

select erp_test.assert_plain_words_suite();
select erp_test.assert_refusal_register_suite();
