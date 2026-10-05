set lock_timeout = '30s';

-- =============================================================================
-- 20261006120000  A draft quotation can be cancelled
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-75).
-- A quotation started by mistake, or for a customer who changed their mind
-- before it was sent, could not be got rid of. Its lifecycle
-- (erp.configure_sales(), the sales lifecycle installer) had one move out of
-- draft, Send, and erp.cancel_document() has no door and no caller, so the
-- document page offered Send and nothing else. The only way to clear it from
-- the Quotation step was to send the customer something nobody meant to offer.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. Sales lifecycle version 5: a quotation gains a terminal Cancelled
--      state and a Cancel move from draft (cancel, draft -> cancelled), under
--      sales.order, the permission every other quotation move asks. Only a
--      draft is cancelled: a sent quotation has been seen by the customer,
--      and keeps Decline and Expire. The machine comes from one helper,
--      erp.quotation_lifecycle_item(), which erp.configure_sales() and the
--      upgrade register both read, so a new install and an upgrade cannot
--      disagree.
--   B. The driver register names the move as a person's, from the screen.
--   C. erp_test.quotation_transform_suite: a draft cancels; a sent one
--      offers no Cancel; a cancelled one converts into nothing and takes no
--      line.
--
-- erp.convert_document() already refuses a quotation that is neither sent nor
-- accepted, and since 20261006100000 a document takes lines only at its
-- initial state, so a cancelled quotation is closed to both without an edit.
-- The Quotation step lists draft and sent, so a cancelled one leaves it, and
-- the move's name is lifecycle data: no client change.
--
-- Documents already in flight stay on the version they started on
-- (erp.perform_transition reads the version the document is pinned to). The
-- demonstration's quotation machine is at version 1; its catch-up upgrades
-- the sales lifecycle whenever an upgrade is planned (20260923800000), which
-- adds a version of the quotation machine with Cancel. Draft quotations
-- raised before that stay pinned to version 1 and offer Send only; every
-- quotation raised after it offers Cancel. A customer's organisation takes it
-- through Upgrade.
--
-- Production: no row is changed. The lifecycle payload, its upgrade row and a
-- driver register row are written; no document moves.
--
-- Proof: erp_test.quotation_transform_suite, three cases more;
-- erp_test.settlement_is_derived_suite re-pinned to version 5.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. Cancel: sales lifecycle version 5
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.quotation_lifecycle_item()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- Version 5 of the quotation's lifecycle (20261006120000), read by
  -- erp.configure_sales() for a new install and by the upgrade register for
  -- an organisation on sales-lifecycle 4 or earlier, so the two cannot
  -- disagree. Version 1's states and moves as they were, and Cancel from
  -- draft to a terminal Cancelled: a quotation nobody sent is withdrawn
  -- before the customer sees it. Accept is the conversion's, through
  -- erp.convert_document(); every other move is a person's.
  select jsonb_build_object('kind','state_machine','key','quotation','payload',
        jsonb_build_object(
          'code','quotation','object_type','document','name','Quotation',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','sent','name','Sent','sort_order',20),
            jsonb_build_object('code','accepted','name','Accepted','is_terminal',true,'sort_order',30),
            jsonb_build_object('code','expired','name','Expired','is_terminal',true,'sort_order',40),
            jsonb_build_object('code','declined','name','Declined','is_terminal',true,'sort_order',90),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',95)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','send','name','Send','from','draft','to','sent','required_permission','sales.order'),
            jsonb_build_object('code','accept','name','Accept','from','sent','to','accepted','required_permission','sales.order'),
            jsonb_build_object('code','decline','name','Decline','from','sent','to','declined','required_permission','sales.order'),
            jsonb_build_object('code','expire','name','Expire','from','sent','to','expired','required_permission','sales.order'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','sales.order'))))
$$;

revoke all on function erp.quotation_lifecycle_item() from public, anon;

comment on function erp.quotation_lifecycle_item() is
  'The quotation''s lifecycle as sales-lifecycle version 5 installs it (20261006120000): version 1''s moves and '
  'Cancel from draft, the item erp.configure_sales() and the upgrade register both read.';

-- The installer reads it. Edited, not rewritten: one anchor over the body
-- 20260929100000 left.

do $configure_sales$
declare
  v_sig  constant text := 'erp.configure_sales(numeric,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$      jsonb_build_object('kind','state_machine','key','quotation','payload',
        jsonb_build_object(
          'code','quotation','object_type','document','name','Quotation',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','sent','name','Sent','sort_order',20),
            jsonb_build_object('code','accepted','name','Accepted','is_terminal',true,'sort_order',30),
            jsonb_build_object('code','expired','name','Expired','is_terminal',true,'sort_order',40),
            jsonb_build_object('code','declined','name','Declined','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','send','name','Send','from','draft','to','sent','required_permission','sales.order'),
            jsonb_build_object('code','accept','name','Accept','from','sent','to','accepted','required_permission','sales.order'),
            jsonb_build_object('code','decline','name','Decline','from','sent','to','declined','required_permission','sales.order'),
            jsonb_build_object('code','expire','name','Expire','from','sent','to','expired','required_permission','sales.order')))),
$o$;
  v_new  constant text := $n$      -- Version 5 (20261006120000), from its one helper: a draft can be
      -- cancelled.
      erp.quotation_lifecycle_item(),
$n$;
begin
  if strpos(v_src, 'erp.quotation_lifecycle_item()') > 0 then
    raise notice '% already installs version 5 of the quotation; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '6dd7f086ed4985a4d39ce47a9e76811d' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006120000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure_sales$;

update erp_ref.module_installer
   set current_version = 5,
       description = description
         || ' Version 5 (20261006120000): a quotation nobody has sent can be cancelled.'
 where install_code = 'sales-lifecycle' and current_version = 4;

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
values ('sales-lifecycle', 5, 'state_machine', 'quotation',
        erp.quotation_lifecycle_item() -> 'payload', 100)
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'sales-lifecycle') is distinct from 5 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the sales lifecycle installer is not at version 5';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       where ui.install_code = 'sales-lifecycle' and ui.to_version = 5
         and ui.object_kind = 'state_machine' and ui.object_key = 'quotation'
         and ui.payload = erp.quotation_lifecycle_item() -> 'payload'
         and ui.payload -> 'transitions' @> '[{"code": "cancel", "from": "draft", "to": "cancelled"}]'::jsonb) <> 1
     or (select count(*) from erp_ref.module_upgrade_item ui
          where ui.install_code = 'sales-lifecycle' and ui.to_version = 5) <> 1 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 5 of the sales lifecycle is not the one quotation it ships';
  end if;
end
$register$;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. A person's move, from the document page
-- ═════════════════════════════════════════════════════════════════════════════

-- Edited, not rewritten: one anchor over the body 20261006111000 left.

do $drivers$
declare
  v_sig  constant text := 'erp.transition_driver_register()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$      ('quotation',          'expire',                 'screen', ''),$o$;
  v_new  constant text := $n$      ('quotation',          'expire',                 'screen', ''),
      -- A draft nobody sent, withdrawn (20261006120000).
      ('quotation',          'cancel',                 'screen', ''),$n$;
begin
  if strpos(v_src, '20261006120000') > 0 then
    raise notice '% already names a quotation''s cancel; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '38c05af8bb973cc30582ca4e0272902a' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006120000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$drivers$;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The proof
-- ═════════════════════════════════════════════════════════════════════════════

-- Three cases more in the quotation suite, before its undo. Edited, not
-- rewritten: one anchor over the body 20260923400000 left.

do $suite$
declare
  v_sig  constant text := 'erp_test.quotation_transform_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_d_old constant text := $o$  q record; o record;
begin$o$;
  v_d_new constant text := $n$  q record; o record;
  -- Cancel (20261006120000).
  v_q5 uuid; v_q6 uuid; v_moves jsonb; v_x3 text;
begin$n$;
  v_old  constant text := $o$    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then$o$;
  v_new  constant text := $n$    -- 9. A draft nobody sent is cancelled, under the permission every
    --    quotation move asks (20261006120000).
    v_q5 := erp.open_document('quotation', v_cust, v_entity, v_site, null, null, 'GBP');
    perform erp.add_document_line(v_q5, v_i1, 2, 1000, 'Two widgets', null);
    v_moves := public.erp_available_transitions(v_q5);
    v_x := null;
    begin
      v_st := erp.transition_document(v_q5, 'cancel', 'Raised for the wrong customer');
    exception when others then v_x := left(sqlerrm, 120); end;
    return query select 'a draft quotation is cancelled by a person who may quote, and reads cancelled, which is final',
      v_x is null and v_st = 'cancelled'
      and exists (select 1 from jsonb_array_elements(v_moves) e
                   where e ->> 'code' = 'cancel' and (e ->> 'permitted')::boolean
                     and e ->> 'refused' is null and e ->> 'to_state' = 'cancelled')
      and exists (select 1 from erp.object_state os
                    join erp.transition t
                      on t.tenant_id = os.tenant_id and t.state_machine_version_id = os.state_machine_version_id
                    join erp.state s on s.id = t.to_state_id
                   where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = v_q5
                     and t.code = 'cancel' and t.required_permission = 'sales.order' and s.is_terminal)
      and public.erp_available_transitions(v_q5) = '[]'::jsonb,
      coalesce(v_x, format('moved to %s; offered %s', v_st, v_moves));

    -- 10. A sent one has been seen by the customer: it is declined or it
    --     expires, and is not cancelled.
    v_q6 := erp.open_document('quotation', v_cust, v_entity, v_site, null, null, 'GBP');
    perform erp.add_document_line(v_q6, v_i1, 1, 1000, 'One widget', null);
    perform erp.transition_document(v_q6, 'send', null);
    v_x := null;
    begin
      perform erp.transition_document(v_q6, 'cancel', null);
      v_x := 'cancelled';
    exception when others then v_x := left(sqlerrm, 120); end;
    return query select 'a sent quotation offers no Cancel, and cancelling it is refused: it is declined or expires',
      v_x is distinct from 'cancelled'
      and erp.object_current_state('document', v_q6) = 'sent'
      and not exists (select 1 from jsonb_array_elements(public.erp_available_transitions(v_q6)) e
                       where e ->> 'code' = 'cancel')
      and exists (select 1 from jsonb_array_elements(public.erp_available_transitions(v_q6)) e
                   where e ->> 'code' = 'decline'),
      format('cancel: %s; offered %s', v_x, public.erp_available_transitions(v_q6));

    -- 11. A cancelled quotation becomes no order and takes no line.
    v_x := null; v_x3 := null;
    begin
      perform public.erp_convert_document(v_q5, null, null, null, null);
      v_x := 'converted';
    exception when others then v_x := left(sqlerrm, 120); end;
    begin
      perform public.erp_add_document_line(v_q5, v_i2, 1, 500, 'One gadget');
      v_x3 := 'added';
    exception when others then v_x3 := left(sqlerrm, 120); end;
    return query select 'a cancelled quotation converts into no order and takes no line',
      v_x like 'CLOVEERP_NOT_ACCEPTED_YET:%' and v_x3 like 'CLOVEERP_DOCUMENT_CANCELLED:%'
      and (select count(*) from erp.document_line l
            where l.tenant_id = v_tenant and l.document_id = v_q5) = 1,
      format('convert: %s; add line: %s', v_x, v_x3);

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then$n$;
begin
  if strpos(v_src, '20261006120000') > 0 then
    raise notice '% already proves a quotation''s cancel; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'a800bdb1d4ef8967d565dbf342ba107a' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006120000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1
     or (length(v_def) - length(replace(v_def, v_d_old, ''))) / length(v_d_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchors found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_d_old, v_d_new), v_old, v_new);
end
$suite$;

-- Its count, nine cases to twelve.

do $assert$
declare
  v_sig  constant text := 'erp_test.assert_quotation_transform_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if v_total <> 9 then
    raise exception 'CLOVEERP_QUOTATION_TRANSFORM_SUITE_SHRANK: % case(s), expected 9', v_total$o$;
  v_new  constant text := $n$  -- Twelve since 20261006120000: a draft is cancelled.
  if v_total <> 12 then
    raise exception 'CLOVEERP_QUOTATION_TRANSFORM_SUITE_SHRANK: % case(s), expected 12', v_total$n$;
begin
  if strpos(v_src, '20261006120000') > 0 then
    raise notice '% already re-pinned; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'f0c56e5aa57b91a29205dcbb2351781d' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006120000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$assert$;

-- The settlement suite pinned a new install, and an upgrade from version 3,
-- at version 4.

do $repin$
declare
  v_sig   constant text := 'erp_test.settlement_is_derived_suite()';
  v_src   text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def   text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_a_old constant text := $o$                where i.tenant_id = rb.tenant_id and i.install_code = 'sales-lifecycle') = 4
          and$o$;
  v_a_new constant text := $n$                where i.tenant_id = rb.tenant_id and i.install_code = 'sales-lifecycle')
              -- Five since 20261006120000: a draft quotation can be cancelled.
              = 5
          and$n$;
  v_c_old constant text := $o$                where i.tenant_id = rb.tenant_id and i.install_code = 'sales-lifecycle') = 4;$o$;
  v_c_new constant text := $n$                where i.tenant_id = rb.tenant_id and i.install_code = 'sales-lifecycle') = 5;$n$;
begin
  if strpos(v_src, '20261006120000') > 0 then
    raise notice '% already re-pinned; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'ac76a255bf5350a9d867d9db011d0eda' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006120000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_a_old, ''))) / length(v_a_old) <> 1
     or (length(v_def) - length(replace(v_def, v_c_old, ''))) / length(v_c_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchors found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_a_old, v_a_new), v_c_old, v_c_new);
end
$repin$;

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
