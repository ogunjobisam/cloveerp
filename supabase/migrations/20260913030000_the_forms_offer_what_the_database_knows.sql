-- The forms offer what the database knows.
--
-- Sixty-odd fields across the desk asked a person to type a code the database
-- already held: a site code, a module's install code, a reason category, a
-- locale, a document type, a currency, a role, a department, a dimension, the
-- id of a record shown in the table above the form. Typed, they were wrong
-- often enough to matter and refused late enough to hurt. Every one of them
-- now picks from the read door that lists the thing, or from the enumeration
-- the column is constrained to, through the field kinds the form component
-- already had: select, combo, multi, choice, and a select column in a rows
-- editor. A code that may be new as well as reused stays typeable, as a combo
-- offering the existing ones.
--
-- Eighteen dropdowns that already existed were wrong and are corrected in the
-- same change: a status the database refuses (webhook 'disabled'), enumeration
-- lists missing a value the type has (site in_transit, location zone, unit of
-- measure mass and packaging, business-partner roles internal and regulator),
-- a role kind that does not exist ('provider' for 'supplier', which returned
-- nothing on every purchasing form), a label key erp_documents does not emit,
-- a job picker that only ever listed overdue jobs, and account-determination
-- dimensions sent as a string against a check that wants an object.
--
-- The words those pickers and their hints say are seeded here, through
-- erp_ref.ui_key() as every seeding since 20260904710000, so a tenant can
-- rename them. The rows for the words that went — 'Comma separated.', 'The id
-- of the duplicate…' and the like — stay; an unused row costs nothing and the
-- check is one-directional on purpose.
--
-- What this change does not do, recorded rather than rediscovered: five
-- pickers read a door that authorises a different permission from the form
-- around them (erp_dimensions and erp_departments under administration.read,
-- erp_entities and erp_cost_centres under finance.read, erp_permissions_directory
-- under administration.roles), so a person with the form's permission and not
-- the door's sees the picker fail. Re-gating those doors is a migration of its
-- own. Four fields still take an identifier by hand because no door lists the
-- thing: a configuration snapshot, a legislation pack, a counting programme,
-- and a mass change; each needs a read door first.

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'Screen string of a form field that now picks from what the database knows: a label, a hint, or a choice.'
  from (values
    ('Assign a named approver for a department'),
    ('Assign a named approver for a person'),
    ('Assign a named approver for a role'),
    ('Backup'),
    ('Both mechanisms: the determination rules on this screen, and the posting rules that actually raise journals. Nothing falls into suspense, so each finding is a refusal waiting to happen.'),
    ('Budget'),
    ('Credential'),
    ('Data'),
    ('Export'),
    ('Fixed'),
    ('Friday'),
    ('Internal'),
    ('Journal'),
    ('Leave as Organisation data unless a separate key is in use.'),
    ('Leave empty when any recognised barcode will do.'),
    ('Leave unchosen for a made item.'),
    ('Leave unchosen to apply at every handheld step.'),
    ('Mass (weight)'),
    ('Merge duplicate business partners'),
    ('Merge duplicate products'),
    ('Monday'),
    ('One row per dimension: the dimension and the value a posting under this rule is stamped with. The account and its analysis come from one rule.'),
    ('Optional. Groups values into a tree. Choose a value of the same dimension.'),
    ('Organisation data — the usual key'),
    ('Parent value'),
    ('Pick a message, not a command; a command is reconciled or cancelled instead.'),
    ('Pick a reason code from the register, or type one of your own.'),
    ('Regulator'),
    ('Revoked — final, cannot be resumed'),
    ('Saturday'),
    ('Storage'),
    ('Sunday'),
    ('The code of an existing counting programme, for example COUNT-A.'),
    ('The id returned when the mass change was opened; mass changes are not listed on this page yet.'),
    ('Thursday'),
    ('Tick every batch in scope.'),
    ('Tick every dimension a line to this account must carry. None ticked removes every requirement.'),
    ('Tick none for every exposed view.'),
    ('Tuesday'),
    ('Views'),
    ('Wednesday'),
    ('Weekly only.'),
    ('What could stop a posting?')
  ) as v(text)
on conflict (key, locale) do nothing;

-- The seeding is only worth anything if the words still obey the glossary,
-- and if every key a table names still has its string.
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
