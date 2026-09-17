set lock_timeout = '30s';

-- =============================================================================
-- 20260917010000  A rule carries its dimensions
-- -----------------------------------------------------------------------------
-- The last of the nineteen columns 20260916430000 registered as defects.
--
-- /finance/account-determination offers a row per dimension under the words
-- "the dimension and the value a posting under this rule is stamped with. The
-- account and its analysis come from one rule." The second sentence was the
-- part that was not true. erp.determine_account() has always handed the rule's
-- dimensions back in its answer, and every caller has always dropped them: a
-- rule written to charge one cost centre charged whatever the posting rule and
-- the document happened to say, which in a default organisation is nothing at
-- all. The register says so in those words, dated 16 September.
--
-- ── WHY THIS ONE WAS LEFT UNTIL LAST ─────────────────────────────────────────
--
-- Since 20260916360000 a posting-rule line reaches its account through
-- erp.posting_line_account_code(): an override recorded on the document, else
-- the determination matrix where a rule covers the supply, else the account the
-- rule itself names. The obvious repair — ask erp.determine_account() for the
-- dimensions too — is worse than the gap if the two questions are asked with
-- different facts, because the matrix would then answer twice and the journal
-- line would take its account from one rule and its analysis from another. A
-- determination rule can be scoped to a ledger, so asking without one is asking
-- a different question.
--
-- So the two answers are made to come from one resolution:
--
--   * erp.posting_line_determination(line, document, ledger) resolves the line
--     once and returns what it found — the account code, where it came from,
--     the rule id where the matrix decided, and that rule's own dimensions,
--     read from that rule's row BY ITS ID. The account and the analysis cannot
--     be two different rules' if they are the same primary key.
--   * erp.posting_line_account_code() is now that function's account half, with
--     the same signature and the same behaviour, including the refusal a line
--     spelling its account `determined` gets when nothing matches.
--   * erp.derive_dimensions() takes the ledger, asks the same resolver, and
--     takes the analysis ONLY when the answer names the very account the line
--     is posting to. Where it is called without a ledger it does not ask at
--     all: a resolution that cannot be the same resolution is not one to guess
--     at, and the behaviour there is exactly today's.
--
-- ── THE PRECEDENCE ───────────────────────────────────────────────────────────
--
--   the posting-rule line's static dimensions
--     → the determination rule's dimensions
--       → the derivations
--         → the document's own attributes.dimensions
--
-- later overriding earlier. The order is an order of specificity. The posting
-- rule's static set is written once for an event and applies to every document
-- that raises it, so it is the floor. The matrix rule is narrower — it is
-- chosen by this supply's item class, party class, site, company, ledger,
-- reason and date — so it sits above the event-level set and below anything
-- computed for this document: a derivation reads this document's own facts, and
-- attributes.dimensions is somebody typing the answer for this document. That
-- is the same ordering erp.derive_dimensions() already used for the three
-- sources it had, with the matrix inserted where its specificity puts it.
--
-- ── WHAT THIS MEANS FOR AN ORGANISATION THAT HAS CONFIGURED NOTHING ──────────
--
-- Nothing. No installer and no pack writes a determination rule with dimensions
-- on it; erp.configure_finance() writes posting rules and no matrix rules at
-- all. A rule with an empty dimensions object merges nothing over anything.
-- The change is inert until somebody fills in the control that has always
-- claimed to do this.
--
-- What it does mean for an organisation that HAS filled it in: the value is now
-- validated like every other. erp.validate_dimensions() already refuses a value
-- the dimension does not have, or one not in force on the posting date, from
-- whichever of the four sources it came — so a determination rule naming a
-- retired cost centre now refuses the posting rather than stamping it. That is
-- deliberate and it is the same treatment the posting rule's own static
-- dimensions have had since 20260906135000. A wrong analysis is a wrong ledger,
-- and this schema refuses one rather than posting it.
--
-- An override does NOT bring the matrix's analysis with it. erp.posting_account
-- _override records a deliberate departure from where the matrix would have
-- sent the posting, and it carries no dimensions of its own; taking the account
-- from the departure and the analysis from the rule departed from is precisely
-- the mixture this migration exists to prevent. An overridden line posts with
-- the analysis it had before: the rule's static set, the derivations, and the
-- document's own word.
--
-- ── SIGNATURES ───────────────────────────────────────────────────────────────
--
-- erp.derive_dimensions() gains p_ledger_id, which is a new function rather
-- than a replacement of the old one, so the four-argument version is dropped
-- and the register that names it by signature —
-- erp_ref.part5_capability '5.7.dimensions' — is corrected in the same
-- statement block. Callers that pass three or four arguments still resolve, by
-- the defaults, to the same answer they got before.
--
-- The two bodies that call it are needled rather than re-emitted, because
-- erp.post_document_finance() has been patched six times since the file that
-- defines it and re-emitting from any file would drop five of them.
--
-- Proof: erp_test.rule_dimensions_suite() (9 cases, wrapper pinned) and
-- erp.assert_write_only_columns(), which now refuses the register row this
-- migration removes.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. One resolution, two answers
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.posting_line_determination(
  p_line jsonb, p_document_id uuid, p_ledger_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $fn$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  v_type   text;
  v_item   uuid;
  v_code   text;
  v_dims   jsonb;
  res      jsonb;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;

  v_type := coalesce(p_line ->> 'transaction_type', dt.base_type_code);
  select dl.item_id into v_item
    from erp.document_line dl
   where dl.tenant_id = v_tenant and dl.document_id = d.id
     and not coalesce(dl.is_cancelled, false)
   order by dl.line_no limit 1;

  -- 1. A deliberate departure, recorded against this document. The narrowest
  --    thing anybody can say about where a posting goes, so it is asked first.
  --    It says where, and nothing about the analysis: the override table has no
  --    dimensions, and borrowing them from the rule this override departs from
  --    would be the account and the analysis coming from two different places.
  select a.code into v_code
    from erp.posting_account_override o
    join erp.account a on a.tenant_id = o.tenant_id and a.id = o.account_id
   where o.tenant_id = v_tenant
     and o.object_type = 'document'
     and o.object_id = p_document_id
     and (o.transaction_type is null or o.transaction_type = v_type)
     and (o.line_ref is null or o.line_ref = p_line ->> 'description')
   order by (o.line_ref is not null)::int + (o.transaction_type is not null)::int desc,
            o.applied_at desc
   limit 1;

  if v_code is not null then
    return jsonb_build_object('account_code', v_code, 'source', 'override',
                              'dimensions', '{}'::jsonb);
  end if;

  -- 2. The matrix. Asked without raising, because an organisation that has
  --    written no rule has not made a mistake — it has said nothing, and the
  --    posting rule is what it said instead.
  res := erp.determine_account(v_type, v_item, d.party_id, d.site_id, d.entity_id,
                               p_ledger_id, p_line ->> 'reason_code', d.document_date,
                               false);

  if coalesce((res ->> 'matched')::boolean, false) then
    -- The analysis of the rule that supplied the account, read from that rule's
    -- own row by the id the determination answered with. Asking the matrix a
    -- second question could find a second rule; asking a primary key cannot.
    select ad.dimensions into v_dims
      from erp.account_determination ad
     where ad.tenant_id = v_tenant
       and ad.id = (res ->> 'rule_id')::uuid;

    return jsonb_build_object('account_code', res ->> 'account_code',
                              'source', 'matrix',
                              'rule_id', res ->> 'rule_id',
                              'dimensions', coalesce(v_dims, '{}'::jsonb));
  end if;

  -- 3. A line that named the matrix by name and got no answer is a fault worth
  --    refusing: falling back here would be the matrix deciding nothing again.
  if coalesce(p_line ->> 'account', '') = 'determined' then
    perform erp.determine_account(v_type, v_item, d.party_id, d.site_id, d.entity_id,
                                  p_ledger_id, p_line ->> 'reason_code', d.document_date,
                                  true);
  end if;

  -- 4. Otherwise the account the rule names, exactly as before, and whatever
  --    analysis the posting rule and the document already gave the line.
  return jsonb_build_object('account_code', p_line ->> 'account', 'source', 'rule',
                            'dimensions', '{}'::jsonb);
end;
$fn$;

revoke all on function erp.posting_line_determination(jsonb, uuid, uuid)
  from public, anon, authenticated;

comment on function erp.posting_line_determination(jsonb, uuid, uuid) is
  'Where a posting-rule line lands and what analysis comes with it, resolved '
  'once: a deliberate override recorded against this document, else the '
  'determination matrix where a rule covers the supply, else the account the '
  'rule itself names. The dimensions come from the matched rule''s own row, by '
  'its id, so a line cannot take its account from one rule and its analysis '
  'from another.';

-- The account half, unchanged in signature and in behaviour.
create or replace function erp.posting_line_account_code(
  p_line jsonb, p_document_id uuid, p_ledger_id uuid)
returns text
language plpgsql
stable
set search_path = ''
as $fn$
begin
  return erp.posting_line_determination(p_line, p_document_id, p_ledger_id) ->> 'account_code';
end;
$fn$;

revoke all on function erp.posting_line_account_code(jsonb, uuid, uuid)
  from public, anon, authenticated;

comment on function erp.posting_line_account_code(jsonb, uuid, uuid) is
  'Which account a posting-rule line reaches: the account half of '
  'erp.posting_line_determination(), which resolves the override, the matrix '
  'and the rule''s own account in that order. An organisation with neither an '
  'override nor a determination rule posts what its posting rule says, as it '
  'always did.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The analysis a line is stamped with
-- ═════════════════════════════════════════════════════════════════════════════

-- A returns-jsonb function cannot gain a parameter by CREATE OR REPLACE — that
-- would leave the four-argument one standing beside it and make every existing
-- call ambiguous. Dropped, then created.
drop function if exists erp.derive_dimensions(uuid, text, jsonb, date);

create function erp.derive_dimensions(p_document_id uuid, p_account_code text, p_line jsonb,
                                      p_on date default current_date,
                                      p_ledger_id uuid default null)
returns jsonb
language plpgsql
stable
set search_path = ''
as $fn$
declare
  v_facts    jsonb;
  v_static   jsonb := coalesce(p_line -> 'dimensions', '{}'::jsonb);
  v_matrix   jsonb := '{}'::jsonb;
  v_derived  jsonb := '{}'::jsonb;
  v_explicit jsonb;
  v_found    jsonb;
  v_out      jsonb;
  dim        record;
  v_value    jsonb;
  v_tenant   uuid := erp.current_tenant_id();
begin
  v_facts := erp.dimension_facts(p_document_id, p_account_code, p_line);
  if v_facts is null then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  v_explicit := coalesce(v_facts -> 'document' -> 'attributes' -> 'dimensions', '{}'::jsonb);
  if jsonb_typeof(v_explicit) <> 'object' then
    raise exception 'CLOVEERP_DIMENSIONS_NOT_AN_OBJECT: the document''s attributes.dimensions is not an object'
      using errcode = '22023',
            hint = 'Write {"CC": "SALES"} under attributes.dimensions: the dimension code, then the value code.';
  end if;

  -- The determination rule's own analysis, and only where that rule is the one
  -- that supplied this line's account. Without a ledger the matrix would be
  -- asked a different question from the one the account was resolved by, so it
  -- is not asked: the answer would be a rule, and not necessarily the rule.
  if p_ledger_id is not null then
    v_found := erp.posting_line_determination(p_line, p_document_id, p_ledger_id);
    if v_found ->> 'account_code' = p_account_code then
      v_matrix := coalesce(v_found -> 'dimensions', '{}'::jsonb);
    end if;
  end if;

  for dim in
    select d.code, d.derivation from erp.dimension d
     where d.tenant_id = v_tenant and d.status = 'active' and d.derivation is not null
     order by d.code
  loop
    begin
      v_value := erp.jsonlogic(dim.derivation, v_facts);
    exception when others then
      -- A derivation the rule engine cannot read is a derivation nobody
      -- tested; the posting says so rather than analysing the line as nothing.
      raise exception 'CLOVEERP_DERIVATION_INVALID: the derivation of % is not an expression the rule engine reads (%)',
        dim.code, left(sqlerrm, 80)
        using errcode = '22023',
              hint = 'Rewrite it through erp_upsert_dimension(), which checks the expression against the posting''s facts.';
    end;
    if v_value is not null and jsonb_typeof(v_value) = 'string' then
      v_derived := v_derived || jsonb_build_object(dim.code, v_value);
    end if;
  end loop;

  -- The later source overrides the earlier, in order of how narrowly it was
  -- written: the posting rule's static value is the floor, the determination
  -- rule that chose the account is narrower than the event, a derivation reads
  -- this document's own facts, and the document's own word is the last.
  v_out := v_static || v_matrix || v_derived || v_explicit;
  perform erp.validate_dimensions(v_out, p_on);
  return v_out;
end;
$fn$;

revoke all on function erp.derive_dimensions(uuid, text, jsonb, date, uuid)
  from public, anon, authenticated;

comment on function erp.derive_dimensions(uuid, text, jsonb, date, uuid) is
  'What a journal line is stamped with: the posting rule line''s static '
  'dimensions, then the determination rule that supplied the line''s account, '
  'then the derivations, then the document''s own attributes.dimensions, later '
  'overriding earlier. Every value must be one the dimension has and in force '
  'on the posting date, whichever source it came from. Without a ledger the '
  'determination matrix is not consulted at all.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The two bodies that ask for it, needled on the deployed text
-- ═════════════════════════════════════════════════════════════════════════════

-- erp.post_document_finance() has been patched by 20260906060000, 20260906080000,
-- 20260906100000, 20260906131000, 20260906135000, 20260910165931 and
-- 20260916090000 since the file that last defines it in full. It is needled,
-- and the patches it already carries are asserted still present afterwards.
do $bridge$
declare
  v_sig    constant text := 'erp.post_document_finance(uuid)';
  v_def    text := pg_get_functiondef(v_sig::regprocedure);
  v_needle constant text :=
       E'      erp.derive_dimensions(p_document_id, acc.code, v_line,\n'
    || E'                            coalesce(d.posting_date, d.document_date, current_date)),\n';
  v_want   constant text :=
       E'      erp.derive_dimensions(p_document_id, acc.code, v_line,\n'
    || E'                            coalesce(d.posting_date, d.document_date, current_date),\n'
    || E'                            led.id),\n';
  v_new    text;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BRIDGE_UNRECOGNISED: % does not carry the dimension stamp 20260906135000 needled into it exactly once', v_sig;
  end if;

  v_new := replace(v_def, v_needle, v_want);

  -- Every patch the deployed body already had, still there afterwards. A
  -- re-emission from a file would have dropped all of these silently.
  if (length(v_new) - length(replace(v_new, v_want, ''))) / length(v_want) <> 1
     or position('erp.posting_line_account_code(v_line, p_document_id, led.id)' in v_new) = 0
     or position('erp.document_tax_minor(p_document_id)' in v_new) = 0
     or position('d.order_behaviour_code = ''blanket''' in v_new) = 0
     or position('d.stock_owner_party_id is not null' in v_new) = 0
     or position('CLOVEERP_NO_PRICE_TO_POST' in v_new) = 0
     or position(E'    if v_amount = 0 then\n      v_no := v_no - 1;' in v_new) = 0 then
    raise exception 'CLOVEERP_BRIDGE_UNRECOGNISED: the patched body of % has lost a patch it carried', v_sig;
  end if;

  execute v_new;
end
$bridge$;

-- And the preview, which says what the bridge would do before it does it. It
-- resolves the account against the posting rule's own ledger, so it hands the
-- same ledger to the dimensions: the pair has to be resolved alike or the
-- preview would stop being a preview.
do $preview$
declare
  v_sig    constant text := 'public.erp_preview_dimensions(uuid)';
  v_def    text := pg_get_functiondef(v_sig::regprocedure);
  v_needle constant text :=
    E'      v_dims := erp.derive_dimensions(p_document_id, coalesce(v_acc.code, v_line ->> ''account''), v_line, v_on);\n';
  v_want   constant text :=
       E'      v_dims := erp.derive_dimensions(p_document_id, coalesce(v_acc.code, v_line ->> ''account''), v_line, v_on,\n'
    || E'                                      pr.ledger_id);\n';
  v_new    text;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_PREVIEW_UNRECOGNISED: % is not the body 20260906135000 created', v_sig;
  end if;

  v_new := replace(v_def, v_needle, v_want);

  if (length(v_new) - length(replace(v_new, v_want, ''))) / length(v_want) <> 1
     or position('erp.posting_line_account_code(v_line, p_document_id, pr.ledger_id)' in v_new) = 0
     or position('erp.check_dimension_combination(d.entity_id, v_acc.id, v_dims)' in v_new) = 0 then
    raise exception 'CLOVEERP_PREVIEW_UNRECOGNISED: the patched body of % has lost a patch it carried', v_sig;
  end if;

  execute v_new;
end
$preview$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The registers
-- ═════════════════════════════════════════════════════════════════════════════

-- The capability register names its artefacts by signature, and one of them has
-- just changed. erp.part5_coverage_report() reads them through to_regprocedure,
-- so a stale signature here is a build failure rather than a stale note.
update erp_ref.part5_capability
   set artefacts = array_replace(artefacts,
                     'erp.derive_dimensions(uuid,text,jsonb,date)',
                     'erp.derive_dimensions(uuid,text,jsonb,date,uuid)')
                   || array['erp.posting_line_determination(jsonb,uuid,uuid)']
 where code = '5.7.dimensions'
   and not ('erp.posting_line_determination(jsonb,uuid,uuid)' = any (artefacts));

-- And the gap register loses the row that named this. erp.assert_write_only_
-- columns() refuses an entry that has stopped being true, which is what makes
-- that list shrink rather than rot.
delete from erp_meta.write_only_column
 where schema_name = 'erp' and table_name = 'account_determination'
   and column_name = 'dimensions';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.rule_dimensions_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_entity uuid; v_site uuid; v_item uuid; v_sup uuid;
  v_ledger uuid; v_class uuid;
  v_acc uuid; v_acc_code text; v_other uuid; v_other_code text;
  v_po uuid; v_po2 uuid; v_base text;
  v_line jsonb; v_static jsonb; v_dims jsonb; v_preview jsonb;
  v_n integer; v_lines integer;
  t record;
begin
  begin
  select x.tenant_id, x.admin_user_id, x.admin_token into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-rule-dimensions', 'A rule carries its dimensions',
                              'admin@zz-rule-dimensions.test', 'Rule Dimensions Admin') x;
  -- erp.account_determination is a promotable surface, so a live organisation
  -- refuses a rule written straight onto it.
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000fa', 'admin@zz-rule-dimensions.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000fa')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select e.id into v_entity from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
  select s.id into v_site from erp.site s
   where s.tenant_id = v_tenant and s.entity_id = v_entity order by s.code limit 1;
  select i.id into v_item from erp.item i
   where i.tenant_id = v_tenant and i.status = 'active' order by i.code limit 1;
  select pr.party_id into v_sup from erp.party_role pr
   where pr.tenant_id = v_tenant and pr.role_kind = 'supplier' order by pr.party_id limit 1;
  select l.id into v_ledger from erp.ledger l
   where l.tenant_id = v_tenant and l.entity_id = v_entity and l.status = 'active'
   order by l.code limit 1;
  select a.id, a.code into v_acc, v_acc_code from erp.account a
   where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = '8100' and a.is_postable;
  select a.id, a.code into v_other, v_other_code from erp.account a
   where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = '8900' and a.is_postable;

  -- Determination is written against an item's CLASS and refuses outright for
  -- an item that has none, so the fixture classifies the one it posts.
  insert into erp.posting_class (tenant_id, kind, code, name, status)
  values (v_tenant, 'item', 'ZZRULEDIM', 'Rule dimensions suite class', 'active')
  returning id into v_class;
  insert into erp.item_posting_class (tenant_id, item_id, posting_class_id, valid_from, status)
  values (v_tenant, v_item, v_class, current_date - 1, 'active');

  -- One dimension, and a value for each of the four places a value can come
  -- from, so a case can say which one won.
  perform erp.upsert_dimension('CC', 'Cost centre');
  perform erp.upsert_dimension_value('CC', 'STATIC', 'What the posting rule line says');
  perform erp.upsert_dimension_value('CC', 'MATRIX', 'What the determination rule says');
  perform erp.upsert_dimension_value('CC', 'DERIVED', 'What the derivation says');
  perform erp.upsert_dimension_value('CC', 'DOC', 'What the document says');

  v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
  perform erp.add_document_line(v_po, v_item, 2, 500, 'a line for the matrix to analyse');

  select dt.base_type_code into v_base
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.id = v_po;

  v_line   := jsonb_build_object('account', v_acc_code, 'side', 'debit', 'rate', 1);
  v_static := v_line || jsonb_build_object('dimensions', jsonb_build_object('CC', 'STATIC'));

  -- ── 1. With no rule, what the line already carried ────────────────────────
  v_cases := v_cases + 1;
  v_dims := erp.derive_dimensions(v_po, v_acc_code, v_static, current_date, v_ledger);
  case_name := 'with no determination rule a line keeps the analysis its posting rule gave it';
  passed := v_dims ->> 'CC' = 'STATIC';
  detail := format('the posting rule said STATIC and the line carries %s',
                   coalesce(v_dims ->> 'CC', '(none)'));
  return next;

  -- The rule the screen has always offered and nothing has ever read.
  insert into erp.account_determination (tenant_id, transaction_type, account_id,
                                         entity_id, dimensions, valid_from, status)
  values (v_tenant, v_base, v_acc, v_entity,
          jsonb_build_object('CC', 'MATRIX'), current_date - 1, 'active');

  -- ── 2. The rule that supplies the account supplies the analysis ───────────
  v_cases := v_cases + 1;
  v_dims := erp.derive_dimensions(v_po, v_acc_code, v_line, current_date, v_ledger);
  case_name := 'a determination rule stamps the posting with the dimensions it was written with';
  passed := v_dims ->> 'CC' = 'MATRIX';
  detail := format('the rule names MATRIX and the line carries %s',
                   coalesce(v_dims ->> 'CC', '(none)'));
  return next;

  -- ── 3. Above the posting rule's static set ────────────────────────────────
  v_cases := v_cases + 1;
  v_dims := erp.derive_dimensions(v_po, v_acc_code, v_static, current_date, v_ledger);
  case_name := 'the rule that chose the account beats the static analysis written on the event';
  passed := v_dims ->> 'CC' = 'MATRIX';
  detail := format('the posting rule said STATIC, the matrix said MATRIX, the line carries %s',
                   coalesce(v_dims ->> 'CC', '(none)'));
  return next;

  -- ── 4. Below a derivation ─────────────────────────────────────────────────
  v_cases := v_cases + 1;
  perform erp.upsert_dimension('CC', 'Cost centre',
    '{"if": [{"==": [{"var": "document.base_type"}, "purchase_order"]}, "DERIVED", null]}'::jsonb);
  v_dims := erp.derive_dimensions(v_po, v_acc_code, v_static, current_date, v_ledger);
  case_name := 'and a derivation, which reads this document''s own facts, beats the rule in turn';
  passed := v_dims ->> 'CC' = 'DERIVED';
  detail := format('static STATIC, matrix MATRIX, derivation DERIVED, the line carries %s',
                   coalesce(v_dims ->> 'CC', '(none)'));
  return next;
  perform erp.upsert_dimension('CC', 'Cost centre');

  -- ── 5. And below the document's own word ──────────────────────────────────
  v_cases := v_cases + 1;
  update erp.document
     set attributes = coalesce(attributes, '{}'::jsonb)
                      || jsonb_build_object('dimensions', jsonb_build_object('CC', 'DOC'))
   where id = v_po;
  v_dims := erp.derive_dimensions(v_po, v_acc_code, v_static, current_date, v_ledger);
  case_name := 'and what the document itself names is still the last word of the four';
  passed := v_dims ->> 'CC' = 'DOC';
  detail := format('static STATIC, matrix MATRIX, the document DOC, the line carries %s',
                   coalesce(v_dims ->> 'CC', '(none)'));
  return next;
  update erp.document set attributes = attributes - 'dimensions' where id = v_po;

  -- ── 6. An override takes the analysis with it ─────────────────────────────
  v_cases := v_cases + 1;
  insert into erp.posting_account_override (tenant_id, object_type, object_id,
                                            account_id, reason, applied_by)
  values (v_tenant, 'document', v_po, v_other, 'suite: a deliberate departure', v_admin);
  v_dims := erp.derive_dimensions(v_po, v_other_code, v_line, current_date, v_ledger);
  case_name := 'a deliberate override sends the posting elsewhere and does not bring the matrix''s analysis along';
  passed := not (v_dims ? 'CC')
        and erp.posting_line_account_code(v_line, v_po, v_ledger) = v_other_code;
  detail := format('the line reached %s and carries CC %s',
                   erp.posting_line_account_code(v_line, v_po, v_ledger),
                   coalesce(v_dims ->> 'CC', '(none)'));
  return next;
  delete from erp.posting_account_override o
   where o.tenant_id = v_tenant and o.object_id = v_po;

  -- ── 7. No ledger, no guess ────────────────────────────────────────────────
  v_cases := v_cases + 1;
  v_dims := erp.derive_dimensions(v_po, v_acc_code, v_line);
  case_name := 'asked without a ledger it does not ask the matrix, because it could not be sure of the same rule';
  passed := not (v_dims ? 'CC');
  detail := format('a rule exists and the line carries CC %s',
                   coalesce(v_dims ->> 'CC', '(none)'));
  return next;

  -- ── 8. The ledger itself, and the preview that said so first ──────────────
  v_cases := v_cases + 1;
  v_po2 := erp.open_document('purchase_order', v_sup, v_entity, v_site);
  perform erp.add_document_line(v_po2, v_item, 1, 500, 'to be committed and analysed');
  v_preview := public.erp_preview_dimensions(v_po2);
  perform erp.transition_document(v_po2, 'submit');
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_po2 and tk.status = 'pending'
              and tk.assignee_user_id = erp.current_principal_id()
  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;
  perform erp.transition_document(v_po2, 'approve');
  perform erp.transition_document(v_po2, 'send');

  select count(*) filter (where jl.dimensions ->> 'CC' = 'MATRIX'), count(*)
    into v_n, v_lines
    from erp.journal j
    join erp.journal_line jl on jl.journal_id = j.id
   where j.tenant_id = v_tenant and j.document_id = v_po2;

  case_name := 'a purchase order sent carries the rule''s analysis on every journal line, and the preview said so first';
  passed := v_lines > 0 and v_n = v_lines
        and jsonb_array_length(v_preview -> 'lines') = v_lines
        and (select bool_and(l -> 'dimensions' ->> 'CC' = 'MATRIX' and l ->> 'verdict' = 'ok')
               from jsonb_array_elements(v_preview -> 'lines') l);
  detail := format('%s of %s journal line(s) stamped CC MATRIX; the preview showed %s line(s)',
                   v_n, v_lines, jsonb_array_length(v_preview -> 'lines'));
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- ── 9. Undone ─────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-rule-dimensions')
        and not exists (select 1 from auth.users
                         where id = '00000000-0000-4000-8000-0000000000fa');
  detail := 'zz-rule-dimensions rolled back with its rule, its dimension and its journal';
  return next;

  if v_cases <> 9 then
    raise exception 'CLOVEERP_SUITE_SHRANK: rule_dimensions_suite ran % cases, expected 9', v_cases;
  end if;
end;
$suite$;

revoke all on function erp_test.rule_dimensions_suite() from public, anon;

create or replace function erp_test.assert_rule_dimensions_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _rule_dimensions on commit drop as
    select * from erp_test.rule_dimensions_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _rule_dimensions;
  drop table _rule_dimensions;
  if v_fail > 0 then
    raise exception E'CLOVEERP_RULE_DIMENSIONS_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 9 then
    raise exception 'CLOVEERP_SUITE_SHRANK: rule_dimensions_suite ran % cases, expected 9', v_all;
  end if;
  return format('a rule carries its dimensions: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_rule_dimensions_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_rule_dimensions_suite();
select erp_test.assert_dimension_suite();
select erp_test.assert_determination_posts_suite();

select erp.assert_write_only_columns();
select erp.assert_part5_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_no_dead_configuration();
select erp.assert_isolation();
