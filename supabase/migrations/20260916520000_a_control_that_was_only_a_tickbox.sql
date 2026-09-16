set lock_timeout = '30s';

-- =============================================================================
-- 20260916520000  A control that was only a tickbox
-- -----------------------------------------------------------------------------
-- 20260916430000 built the check that finds a value a screen writes and nothing
-- reads, and registered thirty-eight of them: nineteen deliberate, nineteen
-- defects with the date on them. This takes four of the defects off that list by
-- making the controls do what their labels promise.
--
--   erp.reason_code.requires_note       "Requires a note"
--   erp.reason_code.requires_approval   "Requires approval"
--   erp.approval_band.is_parallel       "Approvers act — in sequence / parallel"
--   erp.approval_band.tolerance_pct     "Re-approval tolerance (%)"
--
-- All four are the same shape: somebody ticked a box expecting a control, the
-- value saved, the screen showed it back, and nothing anywhere asked.
--
-- ── A REASON THAT INSISTS ON A NOTE ──────────────────────────────────────────
--
-- The Configuration screen keeps the organisation's reasons and says a code "can
-- insist on a note or an approval". Neither was true.
--
-- Before writing the enforcement, every place a reason code reaches the database
-- was read, because the honest answer turned out to be smaller than the screen
-- implies. A code from the register is supplied in four places and no others:
--
--   erp.raise_customer_return   a code AND a note beside it. The only place in
--                               the product where there is a note to refuse.
--   erp.block_location          a code with no note anywhere near it, and the
--                               screen deliberately allows a reason of the
--                               caller's own, so the register is a suggestion
--                               there rather than a rule.
--   erp.determine_account,      the scope of a posting rule, not a transaction:
--   erp.upsert_account_determination
--                               the code is what the rule matches on.
--   erp.stock_movement          carries a text in a column called reason_code
--                               that is as often an order number as a register
--                               code, and has no note field at all.
--
-- So the note requirement is enforced in one place, and that is the whole of it.
-- Saying it holds everywhere would be the same lie in a new coat. A door that
-- gains a note later gains one call to erp.check_reason_code() with it.
--
-- ── A REASON THAT INSISTS ON AN APPROVAL ─────────────────────────────────────
--
-- A reason marked as needing approval now raises a real one, through the engine
-- that already makes the tasks — erp.request_approval into erp.open_approval_seq
-- — against the return, with the reason and the value of the original document
-- in its context. It appears in My approvals like every other request.
--
-- And it genuinely holds the transaction rather than decorating it, because
-- erp.open_approval_seq refuses when nobody can answer: a step with nobody in
-- its role, or nobody but the person asking in a live organisation. The return
-- is inserted and the refusal takes it back out with the rest of the statement.
--
-- Where the organisation has configured NOTHING that routes a customer return,
-- the return is refused by name (CLOVEERP_REASON_NEEDS_AN_APPROVAL_ROUTE)
-- rather than proceeding. That is the judgement this migration makes and it is
-- the one the brief allows for: a demand for an approval that quietly raises
-- none is precisely the class of defect being closed, so the choice is between
-- refusing and re-committing it. The refusal names both ways out — compose a
-- chain, or take the requirement off the reason — and the Organisation screen
-- gains "a customer return" in the kinds of thing a chain can be composed for,
-- so the first of those is a thing somebody can actually do.
--
-- None of the seven reason codes the base pack ships under Customer return asks
-- for an approval, so this is inert until an organisation ticks the box.
--
-- ── A BAND WHOSE APPROVERS ACT IN PARALLEL ───────────────────────────────────
--
-- A band names a ladder of ways to find an approver — a person, a role held in
-- the department, the same role anywhere in the company, the department's
-- manager — and erp.resolve_band_approver() takes the first rung that answers
-- and, for a role, the first holder of it. One band, one approver, always.
-- erp.resolve_approval_chain() then echoed the band's is_parallel into the step
-- it returned and decided nothing with it.
--
-- "In parallel" now means what a reader would expect: the band asks EVERYBODY
-- its resolution finds, all at once. They land on one step of the chain, and a
-- step is satisfied at its min_approvals, which is one — so ANY of them may
-- decide, and the rest are closed rather than left to age. That is the quorum
-- erp.approval_step already models, used rather than invented. "In sequence"
-- is the single approver the ladder picks, exactly as before, so a band that
-- has never been ticked routes precisely as it did yesterday.
--
-- The person who raised the request is never among the extra approvers, and the
-- vacancy and self-approval rules above are untouched: they still decide the
-- band's first approver, and the extras are added after they have settled.
--
-- ── A BAND THAT ABSORBS AN OVERSHOOT ─────────────────────────────────────────
--
-- The band's own tolerance_pct was written by the screen under the words
-- "Re-approval tolerance (%)", which is what the column of that name on
-- erp.approval_chain_version means — and that one IS read, by
-- erp.approval_required(). The band's was read by nothing, and the label was
-- borrowed from a mechanism the band has no part in.
--
-- It now means what a value band's tolerance means everywhere else a tolerance
-- appears in this schema — erp.approval_chain_version.tolerance_pct, a count
-- programme's tolerance_pct, a receipt tolerance: a percentage of the figure it
-- is measured against, inclusive at the edge. A request that passes a band's
-- ceiling by no more than that percentage is approved BY THAT BAND, and the
-- bands above it are not asked. Without it, anything over the ceiling escalates
-- as it always did. The screen's label follows the behaviour rather than the
-- other way round.
--
-- Null and zero are both "no tolerance", which is every band in existence, so
-- this too is inert until somebody fills the field in.
--
-- ── WHAT THIS DOES NOT DO ────────────────────────────────────────────────────
--
-- erp.account_determination.dimensions is the fifth column in the same audit and
-- is not here. A determination rule's dimensions have to compose with what
-- erp.derive_dimensions() already produces from the posting rule line, the
-- derivations and the document's own attributes, and doing it properly means
-- threading the ledger through that function so the dimensions come from the
-- same rule the account came from — a different subsystem, a different
-- precedence question and its own proof. It stays in the register, where its
-- reason is still true, and it is its own change.
--
-- Proof: erp_test.tickbox_controls_suite() (10 cases, wrapper pinned), and the
-- build step "Every value a screen writes is read by something", which refuses
-- a register row whose column something now reads — so the four rows removed
-- below cannot be removed without the reads being real.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. What a reason code insists on
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.check_reason_code(
  p_category text, p_code text, p_note text default null)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  rc       erp.reason_code%rowtype;
begin
  if coalesce(btrim(p_code), '') = '' then
    return false;
  end if;

  -- The register keys a code by category, and erp.upsert_reason_code() folds
  -- both to upper case on the way in.
  select * into rc
    from erp.reason_code rr
   where rr.tenant_id = v_tenant
     and rr.category_code = upper(btrim(p_category))
     and rr.code = upper(btrim(p_code))
     and rr.status = 'active';

  -- A reason the organisation does not keep in its register insists on nothing.
  -- That is deliberate: erp.block_location takes a reason of the caller's own by
  -- design, and a stock movement carries an order number in the same field.
  if rc.id is null then
    return false;
  end if;

  if rc.requires_note and coalesce(btrim(p_note), '') = '' then
    raise exception
      'CLOVEERP_REASON_NEEDS_A_NOTE: the reason % was set up to need a note, and none was given', rc.code
      using errcode = '23514',
            hint = 'Say what happened in the note beside the reason. Which reasons need one is set on the Configuration screen.';
  end if;

  if rc.requires_approval then
    return true;
  end if;

  return false;
end;
$$;
revoke all on function erp.check_reason_code(text, text, text) from public, anon, authenticated;

comment on function erp.check_reason_code(text, text, text) is
  'Refuses a reason code given without the note its organisation said it needs, '
  'and says whether it said it needs an approval. Called by every door that '
  'takes a reason code with a note beside it; a code that is not in the '
  'register insists on nothing, because one door offers the register as a '
  'suggestion rather than a rule.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. A customer return obeys the reason it names
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Patched rather than re-emitted, and anchored on the live body: the refusal
-- this function raises was written under the retired prefix and swept to
-- CLOVEERP_ by 20260912201000, so the file it was born in no longer matches
-- what the database holds. The anchors below avoid that line for the same
-- reason, and each is asserted to occur exactly once before it is replaced.

do $return$
declare
  v_sig  constant text := 'erp.raise_customer_return(uuid,text,text,text)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  n_decl constant text := E'  v_id     uuid;\nbegin';
  n_auth constant text :=
    E'  perform erp.authorise(''sales.order'', d.entity_id, d.site_id, null,';
  n_tail constant text := E'  returning id into v_id;\n\n  return v_id;';
  v_new  text;
begin
  if (length(v_def) - length(replace(v_def, n_decl, ''))) / length(n_decl) <> 1
     or (length(v_def) - length(replace(v_def, n_auth, ''))) / length(n_auth) <> 1
     or (length(v_def) - length(replace(v_def, n_tail, ''))) / length(n_tail) <> 1
     or position('check_reason_code' in v_def) > 0 then
    raise exception 'CLOVEERP_RETURN_UNRECOGNISED: % is not the body this migration patches', v_sig
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;

  v_new := replace(v_def, n_decl,
       E'  v_id     uuid;\n'
    || E'  v_appr   boolean := false;\n'
    || E'  v_ctx    jsonb;\n'
    || E'begin');

  v_new := replace(v_new, n_auth,
       E'  -- 20260916520000. The reason the organisation chose says what it needs.\n'
    || E'  -- A note it insists on is refused here when it is blank; an approval it\n'
    || E'  -- insists on is refused here when nothing in this organisation approves a\n'
    || E'  -- customer return, so the return is never written against a promise that\n'
    || E'  -- cannot be kept.\n'
    || E'  v_appr := erp.check_reason_code(''RETURN_CUSTOMER'', p_reason_code, p_reason);\n'
    || E'  v_ctx := jsonb_build_object(\n'
    || E'             ''reason_code'', p_reason_code,\n'
    || E'             ''reason_category'', ''RETURN_CUSTOMER'',\n'
    || E'             ''outcome'', p_outcome,\n'
    || E'             ''original_document_id'', p_original_document_id,\n'
    || E'             ''currency'', d.currency,\n'
    || E'             ''total_minor'',\n'
    || E'               coalesce(erp.document_value_minor(p_original_document_id), 0));\n'
    || E'\n'
    || E'  if v_appr\n'
    || E'     and erp.select_approval_chain(''customer_return'', v_ctx,\n'
    || E'                                   d.entity_id, d.site_id) is null then\n'
    || E'    raise exception\n'
    || E'      ''CLOVEERP_REASON_NEEDS_AN_APPROVAL_ROUTE: the reason % was set up to need an approval, and nothing in this organisation approves a customer return'', p_reason_code\n'
    || E'      using errcode = ''23503'',\n'
    || E'            hint = ''Compose an approval chain for a customer return under Organisation and approval routing, or take the approval requirement off that reason on the Configuration screen.'';\n'
    || E'  end if;\n'
    || E'\n'
    || n_auth);

  v_new := replace(v_new, n_tail,
       E'  returning id into v_id;\n'
    || E'\n'
    || E'  -- The approval the reason asked for, raised through the engine that makes\n'
    || E'  -- the tasks. It refuses — and takes the return with it — when the chain\n'
    || E'  -- routing a customer return has nobody who may answer.\n'
    || E'  if v_appr then\n'
    || E'    perform erp.request_approval(''customer_return'', v_id, v_ctx, 1,\n'
    || E'                                 d.entity_id, d.site_id);\n'
    || E'  end if;\n'
    || E'\n'
    || E'  return v_id;');

  execute v_new;

  if position('check_reason_code' in pg_get_functiondef(v_sig::regprocedure)) = 0
     or position('request_approval' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_RETURN_UNRECOGNISED: % was re-emitted without the reason it now obeys', v_sig
      using hint = 'The replacement did not land; compare the patched body with the anchors above.';
  end if;
end
$return$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Everybody a band can find
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.resolve_band_approver() answers with ONE approver: the first rung of the
-- resolution that resolves, and for a role the first holder of it. That is the
-- right answer for a band whose approvers act in turn and the wrong one for a
-- band whose approvers act together, so this is its plural.
--
-- It takes the resolution whole rather than a rung at a time, because "the
-- approvers of this band" is everybody any of its rungs names — the holder of
-- the role in the department and the holder of it in the company are two
-- people, and a band asking both at once is what asking in parallel means.

create or replace function erp.band_approvers(p_resolution jsonb, p_department uuid)
returns table (app_user_id uuid)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_res    jsonb;
  v_kind   text;
begin
  for v_res in
    select e.value from jsonb_array_elements(coalesce(p_resolution, '[]'::jsonb)) e
  loop
    v_kind := v_res ->> 'kind';

    if v_kind = 'user' then
      return query
        select au.id from erp.app_user au
         where au.tenant_id = v_tenant
           and au.id = nullif(v_res ->> 'user_id', '')::uuid;

    elsif v_kind = 'line_manager' then
      return query
        select dept.manager_user_id from erp.department dept
         where dept.tenant_id = v_tenant
           and dept.id = p_department
           and dept.manager_user_id is not null;

    elsif v_kind in ('role_in_department', 'role') then
      return query
        select distinct ur.app_user_id
          from erp.user_role ur
          join erp.role rl on rl.tenant_id = ur.tenant_id and rl.id = ur.role_id
          left join erp.principal_department pd
            on pd.tenant_id = ur.tenant_id
           and pd.app_user_id = ur.app_user_id
           and pd.department_id = p_department
           and pd.status = 'active'
           and daterange(pd.valid_from, pd.valid_to, '[)') @> current_date
         where ur.tenant_id = v_tenant
           and rl.code = (v_res ->> 'role_code')
           and (v_kind <> 'role_in_department' or pd.id is not null)
           and (ur.valid_from is null or ur.valid_from <= current_date)
           and (ur.valid_to is null or ur.valid_to > current_date);
    end if;
  end loop;
end;
$$;
revoke all on function erp.band_approvers(jsonb, uuid) from public, anon, authenticated;

comment on function erp.band_approvers(jsonb, uuid) is
  'Everybody an approval band''s resolution can find, rather than the one '
  'erp.resolve_band_approver() picks. Asked only for a band whose approvers act '
  'in parallel: they become one step apiece at the same sequence, and the step '
  'is satisfied by whichever of them answers first.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The engine asks the band what kind of band it is
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Three anchors into the live body. It is not the body of the file that defined
-- it: 20260906082000 put every bound through erp.convert_minor() so a band is
-- compared in its own currency, 20260906145000 added the band's currency to the
-- step, and 20260912201000 swept the refusal prefix. The anchors below are what
-- the database holds after all three.

do $chain$
declare
  v_sig  constant text := 'erp.resolve_approval_chain(text,bigint,character,uuid,uuid,uuid,uuid,date)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  n_decl constant text := E'  v_seq       integer := 0;\nbegin';
  n_skip constant text :=
       E'      if r.upper_bound_minor is not null\n'
    || E'         and erp.convert_minor(p_value_minor, p_currency, r.currency, v_on) >= r.upper_bound_minor\n'
    || E'         and not r.rerun_lower_bands then\n'
    || E'        continue;\n'
    || E'      end if;';
  n_tail constant text :=
       E'        ''upper_bound_minor'', r.upper_bound_minor,\n'
    || E'        ''band_currency'', r.currency,\n'
    || E'        ''value_in_band_currency_minor'', erp.convert_minor(p_value_minor, p_currency, r.currency, v_on));\n'
    || E'    end loop;\n'
    || E'  end if;';
  v_new  text;
begin
  if (length(v_def) - length(replace(v_def, n_decl, ''))) / length(n_decl) <> 1
     or (length(v_def) - length(replace(v_def, n_skip, ''))) / length(n_skip) <> 1
     or (length(v_def) - length(replace(v_def, n_tail, ''))) / length(n_tail) <> 1
     or position('band_approvers' in v_def) > 0 then
    raise exception 'CLOVEERP_CHAIN_UNRECOGNISED: % is not the body this migration patches', v_sig
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;

  v_new := replace(v_def, n_decl,
       E'  v_seq       integer := 0;\n'
    || E'  v_one       uuid;\n'
    || E'  v_absorbs   boolean := false;\n'
    || E'begin');

  -- (a) A band whose ceiling this request passes by no more than its own
  --     tolerance absorbs the overshoot instead of sending it up.
  v_new := replace(v_new, n_skip,
       E'      -- 20260916520000. A band may be given a tolerance, and a request that\n'
    || E'      -- passes its ceiling by no more than that percentage is approved by\n'
    || E'      -- this band rather than escalated to the one above. Measured as every\n'
    || E'      -- other tolerance in this schema is: a percentage of the figure it is\n'
    || E'      -- measured against, inclusive at the edge, in the currency of the band.\n'
    || E'      -- Null and zero are both no tolerance, which is every band that has\n'
    || E'      -- never had the field filled in.\n'
    || E'      v_absorbs := r.upper_bound_minor is not null\n'
    || E'        and coalesce(r.tolerance_pct, 0) > 0\n'
    || E'        and erp.convert_minor(p_value_minor, p_currency, r.currency, v_on) >= r.upper_bound_minor\n'
    || E'        and erp.convert_minor(p_value_minor, p_currency, r.currency, v_on)::numeric\n'
    || E'            <= r.upper_bound_minor::numeric * (1 + r.tolerance_pct / 100.0);\n'
    || E'\n'
    || E'      if r.upper_bound_minor is not null\n'
    || E'         and erp.convert_minor(p_value_minor, p_currency, r.currency, v_on) >= r.upper_bound_minor\n'
    || E'         and not r.rerun_lower_bands\n'
    || E'         and not v_absorbs then\n'
    || E'        continue;\n'
    || E'      end if;');

  -- (b) A band whose approvers act in parallel asks all of them, and the band
  --     that absorbed an overshoot is the last one asked.
  v_new := replace(v_new, n_tail,
       E'        ''upper_bound_minor'', r.upper_bound_minor,\n'
    || E'        ''band_currency'', r.currency,\n'
    || E'        ''tolerance_pct'', r.tolerance_pct,\n'
    || E'        ''absorbed_overshoot'', v_absorbs,\n'
    || E'        ''value_in_band_currency_minor'', erp.convert_minor(p_value_minor, p_currency, r.currency, v_on));\n'
    || E'\n'
    || E'      -- 20260916520000. A band whose approvers act in parallel asks everybody\n'
    || E'      -- its resolution finds, not the one the ladder above happened to pick.\n'
    || E'      -- They are steps at their own sequence numbers on one step of the\n'
    || E'      -- chain, and that step is satisfied at its min_approvals, which is one:\n'
    || E'      -- any of them may decide and the rest are closed. The person who asked\n'
    || E'      -- is never among them.\n'
    || E'      if r.is_parallel then\n'
    || E'        for v_one in\n'
    || E'          select distinct ba.app_user_id\n'
    || E'            from erp.band_approvers(r.resolution, v_dept) ba\n'
    || E'           where ba.app_user_id is not null\n'
    || E'             and ba.app_user_id is distinct from v_user\n'
    || E'             and ba.app_user_id is distinct from v_requester\n'
    || E'           order by 1\n'
    || E'        loop\n'
    || E'          v_cover := erp.apply_cover(v_one, p_object_type, p_value_minor, v_requester);\n'
    || E'          v_seq := v_seq + 1;\n'
    || E'          v_steps := v_steps || jsonb_build_object(\n'
    || E'            ''seq'', v_seq,\n'
    || E'            ''approver_user_id'', v_cover->>''approver_user_id'',\n'
    || E'            ''approver_of_record_user_id'',\n'
    || E'              coalesce(v_cover->>''approver_of_record_user_id'',\n'
    || E'                       case when (v_cover->>''covered'')::boolean then null\n'
    || E'                            else v_one::text end),\n'
    || E'            ''covered'', coalesce((v_cover->>''covered'')::boolean, false),\n'
    || E'            ''cover_kind'', v_cover->>''cover_kind'',\n'
    || E'            ''cover_trail'', coalesce(v_cover->''cover_trail'', ''[]''::jsonb),\n'
    || E'            ''source'', ''department_band'', ''rule_id'', r.id, ''rule_version'', r.version,\n'
    || E'            ''band_seq'', r.seq, ''parallel'', r.is_parallel,\n'
    || E'            ''escalate_after'', r.escalate_after,\n'
    || E'            ''lower_bound_minor'', r.lower_bound_minor,\n'
    || E'            ''upper_bound_minor'', r.upper_bound_minor,\n'
    || E'            ''band_currency'', r.currency,\n'
    || E'            ''tolerance_pct'', r.tolerance_pct,\n'
    || E'            ''absorbed_overshoot'', v_absorbs,\n'
    || E'            ''value_in_band_currency_minor'', erp.convert_minor(p_value_minor, p_currency, r.currency, v_on));\n'
    || E'        end loop;\n'
    || E'      end if;\n'
    || E'\n'
    || E'      -- The band that absorbed the overshoot answered for it; nothing above\n'
    || E'      -- it is asked, which is what tolerating an overshoot means.\n'
    || E'      exit when v_absorbs;\n'
    || E'    end loop;\n'
    || E'  end if;');

  execute v_new;

  if position('band_approvers' in pg_get_functiondef(v_sig::regprocedure)) = 0
     or position('v_absorbs' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_CHAIN_UNRECOGNISED: % was re-emitted without the two the band now decides', v_sig
      using hint = 'The replacement did not land; compare the patched body with the anchors above.';
  end if;
end
$chain$;

comment on column erp.approval_band.is_parallel is
  'Whether this band asks everybody its resolution can find at the same time, '
  'any one of whom may approve, or the single approver the resolution picks. '
  'Read by erp.resolve_approval_chain().';

comment on column erp.approval_band.tolerance_pct is
  'How far past this band''s ceiling a request may go and still be approved by '
  'this band rather than escalated to the one above it, as a percentage of the '
  'ceiling. Null or zero is no tolerance. Read by erp.resolve_approval_chain().';

comment on column erp.reason_code.requires_note is
  'Whether a person giving this reason must say more. Read by '
  'erp.check_reason_code(), which refuses a blank note wherever a door takes a '
  'reason code with a note beside it.';

comment on column erp.reason_code.requires_approval is
  'Whether giving this reason raises an approval before what it explains may '
  'go ahead. Read by erp.check_reason_code().';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The refusals, named so a person can act on them
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_REASON_NEEDS_A_NOTE',
  'A reason that was set up to need a note, given with the note left blank.',
  'An organisation marks a reason as needing a note when the reason alone does not say enough for anybody to act on later. A blank note leaves a record nobody can use.',
  'Write what happened in the note beside the reason, or take the note requirement off that reason on the Configuration screen.');

select erp.register_refusal('CLOVEERP_REASON_NEEDS_AN_APPROVAL_ROUTE',
  'A customer return raised with a reason that was set up to need an approval, where nothing in the organisation approves a customer return.',
  'A reason marked as needing an approval has to produce a real request for a real person to answer. Where no approval routing covers customer returns there is nobody to ask, and letting the return through would make the setting a decoration.',
  'Compose an approval chain for a customer return under Organisation and approval routing, or take the approval requirement off that reason on the Configuration screen.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The register, four rows shorter
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.assert_write_only_columns() refuses a row whose column something now
-- reads, so these come out in the same transaction as the reads that made them
-- untrue. A register kept past its reason is a list nobody looks at.

delete from erp_meta.write_only_column w
 where (w.schema_name, w.table_name, w.column_name) in (
   ('erp', 'reason_code', 'requires_note'),
   ('erp', 'reason_code', 'requires_approval'),
   ('erp', 'approval_band', 'is_parallel'),
   ('erp', 'approval_band', 'tolerance_pct'));

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The words the screens gained
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('A customer return — goods a customer sent back',
     'One of the kinds of thing an approval chain may be composed for, added because a reason code that asks for an approval now needs one.'),
    ('Overshoot tolerance (%)',
     'The band field that was labelled as a re-approval tolerance and is now what it does: how far past the ceiling this band still answers for.'),
    ('A request that passes the ceiling above by no more than this percentage is approved by this band rather than sent up to the one above it. Leave it empty and anything over the ceiling escalates.',
     'What the overshoot tolerance on an approval band does.'),
    ('In parallel asks everybody the approver rule above can find, at the same time, and any one of them may approve. In sequence asks the first one it finds.',
     'What choosing between parallel and sequential approvers on a band does.'),
    ('A reason that needs a note refuses a blank one wherever the reason is given with a note beside it, as a customer return is.',
     'What requiring a note on a reason code does.'),
    ('A reason that needs an approval raises one for a person to answer, and is refused where nothing in this organisation approves that kind of thing.',
     'What requiring an approval on a reason code does.')
  ) as v(text, why)
on conflict (key, locale) do update
  set value = excluded.value, description = excluded.description;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_ci_coverage();
select erp.assert_refusals_name_next_action();

-- ═════════════════════════════════════════════════════════════════════════════
-- The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.tickbox_controls_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases   integer := 0;
  v_tenant  uuid; v_admin uuid; v_token text;
  v_entity  uuid; v_site uuid; v_ccy char(3); v_cust uuid;
  v_doc     uuid;
  v_mgr     uuid; v_one uuid; v_two uuid; v_appr uuid;
  v_dept    uuid; v_role uuid;
  v_chain   uuid; v_ver uuid;
  v_ret     uuid;
  v_res     jsonb; v_chain_out jsonb;
  v_n       integer; v_pending integer;
  v_ok      boolean; v_msg text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-tickbox', 'Tickbox controls suite',
                              'admin@zz-tickbox.test', 'Tickbox Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000f8', 'admin@zz-tickbox.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000f8')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select l.entity_id, l.currency into v_entity, v_ccy
    from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant order by s.code limit 1;
  select p.id into v_cust
    from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
     and pr.role_kind = 'customer' and pr.status = 'active'
   where p.tenant_id = v_tenant order by p.code limit 1;

  -- ── The reason codes this organisation keeps ─────────────────────────────
  perform erp.upsert_reason_code('RETURN_CUSTOMER', 'ZZNOTE', 'Needs a note', true, false, 900);
  perform erp.upsert_reason_code('RETURN_CUSTOMER', 'ZZPLAIN', 'Needs nothing', false, false, 901);
  perform erp.upsert_reason_code('RETURN_CUSTOMER', 'ZZAPPROVE', 'Needs an approval', false, true, 902);

  v_doc := erp.create_document('sales_invoice', v_entity, v_site, v_cust,
                               current_date, v_ccy, 'ZZTB-1', '{}'::jsonb);

  -- ── 1. A reason that needs a note refuses one that is blank ──────────────
  v_cases := v_cases + 1;
  begin
    perform erp.raise_customer_return(v_doc, 'ZZNOTE', '   ', 'credit');
    v_ok := false; v_msg := 'the return was raised without a note';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_REASON_NEEDS_A_NOTE%';
    v_msg := left(sqlerrm, 100);
  end;
  case_name := 'a reason code set up to need a note refuses a return raised without one';
  passed := v_ok;
  detail := v_msg;
  return next;

  -- ── 2. And accepts one that has it ───────────────────────────────────────
  v_cases := v_cases + 1;
  begin
    v_ret := erp.raise_customer_return(v_doc, 'ZZNOTE', 'crushed in transit', 'credit');
    v_ok := v_ret is not null; v_msg := 'raised with the note beside it';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 100);
  end;
  case_name := 'the same reason accepts the return once the note is given';
  passed := v_ok;
  detail := v_msg;
  return next;

  -- ── 3. A reason that asks for nothing is unchanged ───────────────────────
  v_cases := v_cases + 1;
  begin
    v_ret := erp.raise_customer_return(v_doc, 'ZZPLAIN', null, 'credit');
    v_ok := v_ret is not null; v_msg := 'raised with no note at all';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 100);
  end;
  case_name := 'a reason that asks for nothing still takes a return with no note, as every reason did before';
  passed := v_ok;
  detail := v_msg;
  return next;

  -- ── 4. A reason that needs an approval, with nothing to route it ─────────
  v_cases := v_cases + 1;
  begin
    perform erp.raise_customer_return(v_doc, 'ZZAPPROVE', 'goodwill', 'credit');
    v_ok := false; v_msg := 'the return was raised with no approval anywhere';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_REASON_NEEDS_AN_APPROVAL_ROUTE%';
    v_msg := left(sqlerrm, 100);
  end;
  case_name := 'a reason code set up to need an approval refuses the return when nothing approves a customer return';
  passed := v_ok;
  detail := v_msg;
  return next;

  -- ── 5. And raises a real one where a chain routes it ─────────────────────
  -- The chain is the suite's own, composed in draft and then put in force: a
  -- version already in force refuses a new step by design, and the
  -- demonstration's chains are not this suite's to borrow.
  v_appr := (public.erp_invite_principal('approver@zz-tickbox.test', 'Return Approver') ->> 'app_user_id')::uuid;

  insert into erp.approval_chain (tenant_id, code, name, object_type, entity_id, status)
  values (v_tenant, 'zz_tickbox_return', 'Customer returns', 'customer_return', v_entity, 'active')
  returning id into v_chain;
  insert into erp.approval_chain_version (tenant_id, approval_chain_id, version,
                                          status, effective_from, value_field)
  values (v_tenant, v_chain, 1, 'draft', current_date, 'total_minor')
  returning id into v_ver;
  insert into erp.approval_step (tenant_id, approval_chain_version_id, seq, code,
                                 name, approver_kind, app_user_id)
  values (v_tenant, v_ver, 1, 'zz_ret', 'The return approver', 'user', v_appr);
  update erp.approval_chain_version set status = 'active' where id = v_ver;

  v_cases := v_cases + 1;
  begin
    v_ret := erp.raise_customer_return(v_doc, 'ZZAPPROVE', 'goodwill', 'credit');
    v_ok := v_ret is not null; v_msg := 'raised';
  exception when others then
    v_ok := false; v_ret := null; v_msg := left(sqlerrm, 100);
  end;
  select count(*) into v_pending
    from erp.approval_request ar
    join erp.approval_task at2 on at2.approval_request_id = ar.id
   where ar.tenant_id = v_tenant
     and ar.object_type = 'customer_return'
     and ar.object_id = v_ret
     and ar.status = 'pending'
     and at2.assignee_user_id = v_appr
     and at2.status = 'pending';
  case_name := 'the same reason raises a real approval, with a task for the person the chain names';
  passed := coalesce(v_ok, false) and v_pending = 1;
  detail := format('%s; %s pending task(s) for the named approver', v_msg, v_pending);
  return next;

  -- ── The department, its people and its bands ─────────────────────────────
  v_mgr := (public.erp_invite_principal('mgr@zz-tickbox.test', 'Department Manager') ->> 'app_user_id')::uuid;
  v_one := (public.erp_invite_principal('one@zz-tickbox.test', 'First Approver') ->> 'app_user_id')::uuid;
  v_two := (public.erp_invite_principal('two@zz-tickbox.test', 'Second Approver') ->> 'app_user_id')::uuid;

  insert into erp.department (tenant_id, entity_id, code, name, manager_user_id, status)
  values (v_tenant, v_entity, 'ZZTBDEPT', 'Buying', v_mgr, 'active')
  returning id into v_dept;
  insert into erp.principal_department (tenant_id, app_user_id, department_id, is_primary, status)
  values (v_tenant, v_one, v_dept, true, 'active'),
         (v_tenant, v_two, v_dept, true, 'active');

  insert into erp.role (tenant_id, code, name, status)
  values (v_tenant, 'zztbapprover', 'Band approver', 'active')
  returning id into v_role;
  insert into erp.user_role (tenant_id, app_user_id, role_id, valid_from)
  values (v_tenant, v_one, v_role, current_date - 1),
         (v_tenant, v_two, v_role, current_date - 1);

  -- ── 6. A band that is not parallel asks one of them ──────────────────────
  v_cases := v_cases + 1;
  select erp.upsert_approval_band(v_dept, 'requisition', 1, 100000, 0, null,
                                  'zztbapprover', false, 'GBP', false, true, null,
                                  'hold_and_raise', null)
    into v_res;
  v_chain_out := erp.resolve_approval_chain('requisition', 50000, 'GBP'::char(3),
                                            v_dept, v_mgr, v_entity, v_site);
  select count(*) into v_n
    from jsonb_array_elements(coalesce(v_chain_out -> 'steps', '[]'::jsonb)) s
   where s.value ->> 'source' = 'department_band';
  case_name := 'a band whose approvers act in sequence resolves to one of them, as every band did before';
  passed := v_n = 1;
  detail := format('%s step(s) from the band', v_n);
  return next;

  -- ── 7. The same band, ticked parallel, asks both ─────────────────────────
  v_cases := v_cases + 1;
  select erp.upsert_approval_band(v_dept, 'requisition', 1, 100000, 0, null,
                                  'zztbapprover', false, 'GBP', true, true, null,
                                  'hold_and_raise', null)
    into v_res;
  v_chain_out := erp.resolve_approval_chain('requisition', 50000, 'GBP'::char(3),
                                            v_dept, v_mgr, v_entity, v_site);
  select count(distinct s.value ->> 'approver_user_id') into v_n
    from jsonb_array_elements(coalesce(v_chain_out -> 'steps', '[]'::jsonb)) s
   where s.value ->> 'source' = 'department_band';
  case_name := 'ticked to act in parallel, the same band asks everybody its approver rule can find';
  passed := v_n = 2;
  detail := format('%s distinct approver(s) from the band', v_n);
  return next;

  -- ── 8. Over the ceiling, with no tolerance, the band above answers ───────
  -- A second band above the first, and the first put back to sequential so the
  -- count is about the ceiling rather than about parallel approvers.
  select erp.upsert_approval_band(v_dept, 'requisition', 1, 100000, 0, null,
                                  'zztbapprover', false, 'GBP', false, false, null,
                                  'hold_and_raise', null)
    into v_res;
  select erp.upsert_approval_band(v_dept, 'requisition', 2, null, 100000, v_mgr,
                                  null, false, 'GBP', false, false, null,
                                  'hold_and_raise', null)
    into v_res;

  v_cases := v_cases + 1;
  v_chain_out := erp.resolve_approval_chain('requisition', 105000, 'GBP'::char(3),
                                            v_dept, v_one, v_entity, v_site);
  select count(*) into v_n
    from jsonb_array_elements(coalesce(v_chain_out -> 'steps', '[]'::jsonb)) s
   where s.value ->> 'source' = 'department_band';
  select count(*) into v_pending
    from jsonb_array_elements(coalesce(v_chain_out -> 'steps', '[]'::jsonb)) s
   where s.value ->> 'source' = 'department_band'
     and (s.value ->> 'band_seq')::integer = 2;
  case_name := 'a request over a band''s ceiling escalates to the band above it when the band has no tolerance';
  passed := v_n = 1 and v_pending = 1;
  detail := format('%s band step(s), %s of them the band above', v_n, v_pending);
  return next;

  -- ── 9. With a tolerance wide enough, the lower band answers for it ───────
  v_cases := v_cases + 1;
  select erp.upsert_approval_band(v_dept, 'requisition', 1, 100000, 0, null,
                                  'zztbapprover', false, 'GBP', false, false, null,
                                  'hold_and_raise', 10)
    into v_res;
  v_chain_out := erp.resolve_approval_chain('requisition', 105000, 'GBP'::char(3),
                                            v_dept, v_one, v_entity, v_site);
  select count(*) into v_n
    from jsonb_array_elements(coalesce(v_chain_out -> 'steps', '[]'::jsonb)) s
   where s.value ->> 'source' = 'department_band';
  select count(*) into v_pending
    from jsonb_array_elements(coalesce(v_chain_out -> 'steps', '[]'::jsonb)) s
   where s.value ->> 'source' = 'department_band'
     and (s.value ->> 'band_seq')::integer = 1
     and (s.value ->> 'absorbed_overshoot')::boolean;
  case_name := 'given a tolerance the overshoot fits inside, the band answers for it and the band above is not asked';
  passed := v_n = 1 and v_pending = 1;
  detail := format('%s band step(s), %s of them the lower band absorbing the overshoot', v_n, v_pending);
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- ── 10. Undone ───────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-tickbox')
        and not exists (select 1 from auth.users where email = 'admin@zz-tickbox.test');
  detail := 'zz-tickbox rolled back with its reason codes, returns, bands and chain';
  return next;

  if v_cases <> 10 then
    raise exception 'CLOVEERP_SUITE_SHRANK: tickbox_controls_suite ran % cases, expected 10', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.tickbox_controls_suite() from public, anon;

comment on function erp_test.tickbox_controls_suite() is
  'The four controls a screen wrote and nothing read: a reason code''s note and '
  'approval requirements, and an approval band''s parallel approvers and '
  'overshoot tolerance.';

create or replace function erp_test.assert_tickbox_controls_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _tickbox on commit drop as
    select * from erp_test.tickbox_controls_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _tickbox;
  drop table _tickbox;
  if v_fail > 0 then
    raise exception E'CLOVEERP_TICKBOX_CONTROLS_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 10 then
    raise exception 'CLOVEERP_SUITE_SHRANK: tickbox_controls_suite ran % cases, expected 10', v_all;
  end if;
  return format('a control that was only a tickbox: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_tickbox_controls_suite() from public, anon;

select erp.apply_execute_grants();
select erp_test.assert_tickbox_controls_suite();
select erp.assert_write_only_columns();
