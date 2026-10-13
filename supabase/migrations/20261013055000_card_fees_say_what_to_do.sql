-- Card fees say what to do.
--
-- A follow-up to 20261013040000, found by erp_test.plain_words_suite: the
-- refusal for a company that cannot post a card provider's fees told the
-- reader to upgrade "finance posting to version 3" and named the
-- settlement_difference rule, which only the people who build Clove ERP would
-- follow. It now says where to go and what that adds, and the hint the posting
-- raises says the same.

select erp.register_refusal('CLOVEERP_SETTLEMENT_FEES_NOT_POSTABLE',
  'Applying a card settlement statement with fees in a company with no settlement differences account or bank account to post them to.',
  'The fees are posted against the bank so it holds what the provider paid out; without an account for them the bank would hold the gross.',
  'Upgrade finance posting from the Installed modules list on the Configuration screen: it adds the settlement differences account the fees post to. Then apply the statement again.');

do $hint$
declare
  v_sig  constant text := 'erp.post_settlement_fees(uuid)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$            hint = 'Upgrade finance posting to version 3: it installs the settlement_difference rule and the 7900 account.';$o$;
  v_new  constant text := $n$            hint = 'Upgrade finance posting from the Installed modules list on the Configuration screen: it adds the settlement differences account the fees post to. Then apply the statement again.';$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if position('Installed modules list' in v_def) > 0 then
    return;
  end if;
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % hint anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$hint$;

-- The generators, which are idempotent and run at the end of every migration.
select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_refusals_name_next_action();
