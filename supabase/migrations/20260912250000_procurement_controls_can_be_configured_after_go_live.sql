-- The routine that could not run on a live organisation.
--
-- erp.configure_procurement_controls() puts everything it configures through
-- erp.install_module_config() — the approval chain, the tolerances, the state
-- machine, two posting rules — which raises a change set when the environment
-- is live and writes directly when it is not. Then it did two things outside
-- that mechanism: it inserted the purchase-invoice numbering rule, and it
-- inserted the purchase-invoice document type.
--
-- erp.numbering_rule is a registered promotable surface, so the live-config
-- guard refuses the first one:
--
--   CLOVEERP_LIVE_CONFIG_EDIT: numbering_rule may not be changed directly in a
--   live environment; promote a change set instead
--
-- which took out three suites and, more to the point, means
-- public.erp_configure_procurement_controls() — a door an organisation can
-- call — fails once that organisation has gone live. Purchase-invoice handling
-- could be set up during onboarding and never afterwards.
--
-- The second write is worse in a quieter way. It selects the numbering rule it
-- just made; under a change set that rule does not exist until promotion, so
-- the insert would have matched nothing and created no document type at all,
-- with no error. A silent no-op is a worse failure than a refusal.
--
-- So both move into the change set, where the rest of the routine already
-- lives. erp.numbering_rule already had an item kind. erp.document_type did
-- not, so this adds one, and the branch refuses loudly if it is applied before
-- the rule it names — the two are ordered by their position in the item array
-- and that ordering is now load-bearing.
--
-- Nothing changes for a bootstrap-window organisation: install_module_config()
-- applies immediately there, in array order, exactly as the direct writes did.
-- The three suites already approve and promote the change set this returns, so
-- they need no change.
--
-- What this does NOT do: register erp.document_type in
-- erp_meta.promotable_surface. Registering it generates a live guard over it,
-- and every routine that writes a document type directly would then have to
-- go through a change set too. That is a decision about the whole document
-- spine, not a side effect of fixing this routine.

-- ── 1. A document type is something a change set can carry ──────────────────

do $kind$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure);

  v_new := replace(v_def,
$old$    when 'numbering_rule' then$old$,
$new$    when 'document_type' then
      declare
        v_dt_rule   uuid;
        v_dt_entity uuid;
      begin
        if i.operation = 'remove' then
          update erp.document_type dt
             set status = 'inactive', updated_at = now()
           where dt.tenant_id = v_tenant and dt.code = (p ->> 'code');
        else
          select nr.id, nr.entity_id into v_dt_rule, v_dt_entity
            from erp.numbering_rule nr
           where nr.tenant_id = v_tenant
             and nr.code = coalesce(p ->> 'numbering_rule', p ->> 'code');

          if v_dt_rule is null then
            raise exception
              'CLOVEERP_PROMOTION_UNKNOWN_NUMBERING_RULE: document type % names numbering rule %, which this environment does not have',
              p ->> 'code', coalesce(p ->> 'numbering_rule', p ->> 'code')
              using errcode = '23503',
                    hint = 'A document type is applied after the rule that numbers it. Put the numbering_rule item before the document_type item in the change set.';
          end if;

          insert into erp.document_type (
            tenant_id, code, base_type_code, name, entity_id,
            state_machine_code, numbering_rule_id, posting_rule_code,
            create_permission, status)
          values (v_tenant, p ->> 'code', p ->> 'base_type_code', p ->> 'name',
                  v_dt_entity, p ->> 'state_machine_code', v_dt_rule,
                  p ->> 'posting_rule_code', p ->> 'create_permission', 'active')
          on conflict (tenant_id, code) do update
            set base_type_code = excluded.base_type_code,
                name = excluded.name,
                entity_id = excluded.entity_id,
                state_machine_code = excluded.state_machine_code,
                numbering_rule_id = excluded.numbering_rule_id,
                posting_rule_code = excluded.posting_rule_code,
                create_permission = excluded.create_permission,
                status = 'active',
                updated_at = now();
        end if;
      end;

    when 'numbering_rule' then$new$);

  if v_new = v_def then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the numbering_rule branch of erp.apply_change_set_item was not found';
  end if;

  execute v_new;
end
$kind$;

-- ── 2. The routine stops writing round the outside of its own change set ────

do $ctrl$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('erp.configure_procurement_controls(text,numeric,numeric,bigint)'::regprocedure);

  -- The two new items, appended to the array install_module_config is given.
  v_new := replace(v_def,
$old$            jsonb_build_object('account', v_bank,'side','credit','rate',1,
                               'description','Bank'))))));$old$,
$new$            jsonb_build_object('account', v_bank,'side','credit','rate',1,
                               'description','Bank')))),

      -- The numbering rule and the type it numbers, in that order: they are
      -- applied by array position and the document_type branch refuses if the
      -- rule is not there yet. next_value is never rewound on re-apply, so a
      -- sequence that has already issued numbers keeps its place.
      jsonb_build_object('kind','numbering_rule','key','purchase_invoice','payload',
        jsonb_build_object(
          'code','purchase_invoice', 'prefix','PINV-', 'pad_to',6,
          'reset_period','yearly', 'next_value',1,
          'entity',(select e.code from erp.entity e
                     where e.tenant_id = v_tenant and e.status = 'active'
                     order by e.code limit 1))),

      jsonb_build_object('kind','document_type','key','purchase_invoice','payload',
        jsonb_build_object(
          'code','purchase_invoice', 'base_type_code','invoice_reference',
          'name','Purchase invoice', 'state_machine_code','purchase_invoice',
          'numbering_rule','purchase_invoice', 'posting_rule_code','purchase_invoice',
          -- Base invoice_reference carries sales.invoice, which is right for
          -- sales_invoice and wrong here: every transition on this lifecycle
          -- wants procurement.match, so raising one must too.
          'create_permission','procurement.match'))));$new$);

  if v_new = v_def then
    raise exception 'CLOVEERP_PROCUREMENT_CONTROLS_UNRECOGNISED: the supplier_payment posting rule is not the last item in the array this migration extends';
  end if;
  v_def := v_new;

  -- And the two direct writes go.
  v_new := replace(v_def,
$old$  insert into erp.numbering_rule (
    tenant_id, code, entity_id, prefix, pad_to, reset_period, next_value)
  select v_tenant, 'purchase_invoice', e.id, 'PINV-', 6, 'yearly', 1
    from erp.entity e where e.tenant_id = v_tenant and e.status = 'active'
    order by e.code limit 1
  on conflict (tenant_id, code) do nothing;

$old$, '');

  if v_new = v_def then
    raise exception 'CLOVEERP_PROCUREMENT_CONTROLS_UNRECOGNISED: the direct numbering rule insert is not the one this migration removes';
  end if;
  v_def := v_new;

  v_new := replace(v_def,
$old$  insert into erp.document_type (
    tenant_id, code, base_type_code, name, entity_id,
    state_machine_code, numbering_rule_id, posting_rule_code, create_permission)
  select v_tenant, 'purchase_invoice', 'invoice_reference', 'Purchase invoice',
         n.entity_id, 'purchase_invoice', n.id, 'purchase_invoice',
         -- Base invoice_reference carries sales.invoice, which is right for
         -- sales_invoice and wrong here: every transition on this lifecycle
         -- wants procurement.match, so raising one must too. Dropped by two
         -- whole-function rewrites; see 20260912224000 before dropping it a
         -- third time.
         'procurement.match'
    from erp.numbering_rule n
   where n.tenant_id = v_tenant and n.code = 'purchase_invoice'
  on conflict (tenant_id, code) do update
    set state_machine_code = excluded.state_machine_code,
        numbering_rule_id = excluded.numbering_rule_id,
        posting_rule_code = excluded.posting_rule_code,
        create_permission = excluded.create_permission;

$old$, '');

  if v_new = v_def then
    raise exception 'CLOVEERP_PROCUREMENT_CONTROLS_UNRECOGNISED: the direct document type insert could not be removed';
  end if;

  execute v_new;
end
$ctrl$;

select erp.apply_execute_grants();
