Fixtures for supabase/ci/preflight_falsification.sh.

These are NOT migrations and are deliberately not in supabase/migrations: every
one of them is wrong on purpose, and the only thing that ever reads them is the
falsification, which hands each to supabase/ci/preflight.sh by name and refuses
to believe a rule that stays quiet.

They are timestamped 2999 so that "every migration applied no later than this
one" means the whole repository, which is what a migration written today sees.

  29999999010000_clean                 wrong about nothing; every rule stays quiet
  29999999020000_rule_a_live_singleton runs a suite that must be alone in the world
  29999999030000_rule_b_unraised       registers a refusal nothing raises
  29999999040000_rule_c_gate           a door that does not call the gate it declares
  29999999050000_rule_d_help           help actions for a screen with no topic
  29999999060000_rule_f_allowance      a write door on no allow-list
  29999999070000_rule_f_home           a door no screen names and no caller claims
  29999999080000_rule_g_collateral     adds a posting rule; advises, does not refuse
  29999999090000_rule_h_guard          a suite that throws away what it caught
