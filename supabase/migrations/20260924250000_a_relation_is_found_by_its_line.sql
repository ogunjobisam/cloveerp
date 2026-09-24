set lock_timeout = '30s';

-- =============================================================================
-- 20260924250000  A relation is found by its line
-- -----------------------------------------------------------------------------
-- The build's demonstration reopen suite stopped the database twice on
-- 24 September, once after seventy-eight minutes and once after thirty-nine,
-- and on main alone it took over an hour. Nothing in it was wrong. Two
-- statements were slow enough to take everything else with them.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- The suite builds an organisation and trades eighty days for it inside one
-- transaction. The planner's statistics cannot see rows a transaction has not
-- committed, so every table the organisation writes to reads as holding one
-- row, and a join is planned as though order did not matter. For two
-- statements it did:
--
--   * erp.order_is_settled(), asked for every order a bill touches, found what
--     was returned and what was billed against an order line by starting from
--     every document state in the organisation and filtering down to the line
--     at the end. Three calls for one bill took five minutes each.
--   * The demonstration's Friday return, in erp.seed_demo_history(), joined
--     every sales invoice line the organisation had to find the newest one to
--     credit, and cost four seconds more each Friday.
--
-- Nothing could have found a relation by its line quickly in any case:
-- erp.document_relation has indexes on the documents it joins and none on
-- their lines, and every one of these lookups is by line.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * Two indexes, a relation by the line it comes from and by the line it
--     goes to.
--   * erp.order_is_settled() starts from the order line and asks about the
--     bill or the credit note by its id. What it answers is unchanged.
--   * The Friday return walks the invoices newest first and stops at the first
--     with a line to credit.
-- =============================================================================

create index if not exists document_relation_tenant_id_from_line_id_idx
  on erp.document_relation (tenant_id, from_line_id, relation_kind)
  where from_line_id is not null;

create index if not exists document_relation_tenant_id_to_line_id_idx
  on erp.document_relation (tenant_id, to_line_id, relation_kind)
  where to_line_id is not null;

do $settled$
declare
  v_sig constant text := 'erp.order_is_settled(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o1$             select sum(rr.quantity)
               from erp.document_relation rr
               join erp.document_relation fr
                 on fr.tenant_id = rr.tenant_id
                and fr.from_line_id = rr.to_line_id
                and fr.relation_kind = 'fulfils'
                and fr.to_line_id = rl.line_id
               join erp.document cn
                 on cn.tenant_id = rr.tenant_id and cn.id = rr.from_document_id
               join erp.object_state os
                 on os.tenant_id = cn.tenant_id
                and os.object_type = 'document' and os.object_id = cn.id
               join erp.state st on st.id = os.current_state_id
              where rr.tenant_id = erp.current_tenant_id()
                and rr.relation_kind = 'returns'
                and rr.to_line_id is not null
                and st.is_committed
                and not coalesce(cn.is_cancelled, false)), 0) as kept_quantity,$o1$;
  v_new1 constant text := $n1$             -- From the order line (20260924250000): its receipt lines,
             -- then what returns them, each found by its line. The credit
             -- note is asked about by its id. Joined the other way, a
             -- planner that thinks the organisation holds one document
             -- started from every document state it has, once per line.
             select sum(rr.quantity)
               from erp.document_relation fr
               join erp.document_relation rr
                 on rr.tenant_id = fr.tenant_id
                and rr.to_line_id = fr.from_line_id
                and rr.relation_kind = 'returns'
              where fr.tenant_id = erp.current_tenant_id()
                and fr.to_line_id = rl.line_id
                and fr.relation_kind = 'fulfils'
                and exists (
                  select 1
                    from erp.document cn
                    join erp.object_state os
                      on os.tenant_id = cn.tenant_id
                     and os.object_type = 'document' and os.object_id = cn.id
                    join erp.state st on st.id = os.current_state_id
                   where cn.tenant_id = rr.tenant_id and cn.id = rr.from_document_id
                     and st.is_committed
                     and not coalesce(cn.is_cancelled, false))), 0) as kept_quantity,$n1$;
  v_old2 constant text := $o2$             select sum(rel.quantity)
               from erp.document_relation rel
               join erp.document b
                 on b.tenant_id = rel.tenant_id and b.id = rel.from_document_id
               join erp.document_type bdt
                 on bdt.tenant_id = b.tenant_id and bdt.id = b.document_type_id
               join erp.object_state bos
                 on bos.tenant_id = b.tenant_id and bos.object_type = 'document'
                and bos.object_id = b.id
               join erp.state bs on bs.id = bos.current_state_id
              where rel.tenant_id = erp.current_tenant_id()
                and rel.to_line_id = rl.line_id
                and rel.relation_kind = 'invoices'
                and bdt.base_type_code = 'invoice_reference'
                -- A supplier's bill that charges for what it invoices
                -- (20260922380000): not a sales invoice, and not a bill with a
                -- line that takes value off it.
                and erp.bill_settles_orders(b.id)
                and not b.is_cancelled
                and bs.is_committed), 0) as billed_quantity$o2$;
  v_new2 constant text := $n2$             -- From the order line, and the bill asked about by its id
             -- (20260924250000), for the reason above.
             select sum(rel.quantity)
               from erp.document_relation rel
              where rel.tenant_id = erp.current_tenant_id()
                and rel.to_line_id = rl.line_id
                and rel.relation_kind = 'invoices'
                and exists (
                  select 1
                    from erp.document b
                    join erp.document_type bdt
                      on bdt.tenant_id = b.tenant_id and bdt.id = b.document_type_id
                    join erp.object_state bos
                      on bos.tenant_id = b.tenant_id and bos.object_type = 'document'
                     and bos.object_id = b.id
                    join erp.state bs on bs.id = bos.current_state_id
                   where b.tenant_id = rel.tenant_id and b.id = rel.from_document_id
                     and bdt.base_type_code = 'invoice_reference'
                     -- A supplier's bill that charges for what it invoices
                     -- (20260922380000): not a sales invoice, and not a bill with a
                     -- line that takes value off it.
                     and erp.bill_settles_orders(b.id)
                     and not b.is_cancelled
                     and bs.is_committed)), 0) as billed_quantity$n2$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % returned quantity found % time(s)', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % billed quantity found % time(s)', v_sig, v_hits;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$settled$;

do $friday$
declare
  v_sig constant text := 'erp.seed_demo_history(date,date,numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o1$    declare
      v_billed uuid;
      v_bline  uuid;
      v_credit numeric;
      v_ccn    uuid;
    begin
      select il.document_id, il.id, floor(il.quantity / 4)
        into v_billed, v_bline, v_credit
        from erp.document i
        join erp.document_type it
          on it.tenant_id = i.tenant_id and it.id = i.document_type_id
        join erp.document_line il
          on il.tenant_id = i.tenant_id and il.document_id = i.id
        join erp.document_relation gr
          on gr.tenant_id = il.tenant_id and gr.from_line_id = il.id
         and gr.relation_kind = 'invoices'
       where i.tenant_id = v_tenant
         and it.code = 'sales_invoice'
         and i.their_reference like 'DEMO-%'
         and i.document_date <= v_day
         and not coalesce(il.is_cancelled, false)
         and il.quantity >= 4
         and erp.object_current_state('document', i.id) in ('issued', 'paid')
         and not exists (select 1 from erp.document_relation rr
                          where rr.tenant_id = v_tenant
                            and rr.to_line_id = gr.to_line_id
                            and rr.relation_kind = 'returns')
       order by i.document_date desc, il.line_no
       limit 1;
$o1$;
  v_new1 constant text := $n1$    declare
      v_billed uuid;
      v_bline  uuid;
      v_credit numeric;
      v_ccn    uuid;
      v_cand   uuid;
    begin
      -- The invoices newest first, and the first with a line to credit
      -- (20260924250000). One join over every invoice line the organisation
      -- has, planned inside a transaction that has just written them, was
      -- read as though there were one of each, and cost more every Friday.
      for v_cand in
        select i.id
          from erp.document i
          join erp.document_type it
            on it.tenant_id = i.tenant_id and it.id = i.document_type_id
         where i.tenant_id = v_tenant
           and it.code = 'sales_invoice'
           and i.their_reference like 'DEMO-%'
           and i.document_date <= v_day
         order by i.document_date desc, i.id
      loop
        continue when coalesce(erp.object_current_state('document', v_cand), '')
                      not in ('issued', 'paid');
        select il.document_id, il.id, floor(il.quantity / 4)
          into v_billed, v_bline, v_credit
          from erp.document_line il
          join erp.document_relation gr
            on gr.tenant_id = il.tenant_id and gr.from_line_id = il.id
           and gr.relation_kind = 'invoices'
         where il.tenant_id = v_tenant
           and il.document_id = v_cand
           and not coalesce(il.is_cancelled, false)
           and il.quantity >= 4
           and not exists (select 1 from erp.document_relation rr
                            where rr.tenant_id = v_tenant
                              and rr.to_line_id = gr.to_line_id
                              and rr.relation_kind = 'returns')
         order by il.line_no
         limit 1;
        exit when v_billed is not null;
      end loop;$n1$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % Friday return found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old1, v_new1);
end
$friday$;

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
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
