-- ─────────────────────────────────────────────────────────────────────────────
-- A card heading is a word somebody can change.
--
-- The terminology layer's premise is that renaming is a glossary change with no
-- code impact, and supabase/ci/screen_strings.sh enforces it for every ui("…")
-- literal in the app. It could not see a whole class of screen word: a string a
-- route passes to a component as a prop, which the component then renders
-- through ui(). The literal is at the call site, the ui() call is in the
-- component, and a grep for ui("…") finds neither.
--
-- That class is the card headings and the sentence under them — every
-- ActionBar's title and note, every AutoPanel's title, description and empty
-- state. Seventy-three strings, of which sixty-four had no row at any locale.
-- They rendered correctly the whole time, because ui() falls back to the text
-- it was given, so nothing looked wrong. What was wrong is that
-- erp.terminology_alignment_report() showed no drift over them, and a tenant
-- who renamed Sites or Goods-in saw the old word stay on the card — the exact
-- failure the strings script was written to catch, one level out from where it
-- was looking.
--
-- The keys are computed by erp_ref.ui_key() rather than written out. It is the
-- same FNV-1a hash the browser's uiKey() runs, and a key typed by hand here
-- would be a key ui() never asks for: a row that exists, satisfies the check,
-- and is never read.
--
-- Seeding these made the guard visible, and it immediately found three strings
-- that used a model term where the product prescribes another — "Receiving"
-- for Goods-in, twice, and "principal" for User. Those are fixed in the same
-- change, in the source rather than exempted here. They are the first thing
-- this class of coverage bought.
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A card heading or its description, passed to the component as a prop.'
  from (values
  ('A route binds an event pattern and a severity to an audience. A mandatory route reaches its audience in-app even when they switched the channel off.'),
  ('A subscription is your own unless you hold reporting.define; a pack is defined under it and assembled under reporting.export; the contract is administered under administration.integrate.'),
  ('A template composes a code from ordered segments: an axis abbreviation, a literal, a sequence, or a check character.'),
  ('An area is a scope, not a place on a map: a site, a location, and optionally the channel, order type and product classes it serves.'),
  ('Approval bands and named approvers'),
  ('Axes and values'),
  ('Axes are the questions asked of every product; values are the permitted answers.'),
  ('Bringing somebody in'),
  ('Bringing somebody into this organisation. An invitation returns a single-use token to hand over.'),
  ('Build a scenario of this organisation''s own from the completion checks the product has. It is offered to whoever holds the permission it names.'),
  ('Change requests'),
  ('Code templates'),
  ('Cover for a wave you are looking at.'),
  ('Cover for this wave'),
  ('Cover while somebody is away'),
  ('Cover while somebody is away. A delegation keeps the approver of record and records who acted; a substitution replaces them outright.'),
  ('Departments and membership'),
  ('Departments and membership. A person''s primary department at capture is the one that routes their request.'),
  ('Determination rules'),
  ('Devices and scan rules'),
  ('Every batch keeps its rows, its errors and its outcome.'),
  ('Every key this organisation has held, and what became of it.'),
  ('Goods-in, matching and qualification'),
  ('Goods-in, matching and supplier qualification — the verbs between the documents.'),
  ('Import batches'),
  ('Key register'),
  ('Locations'),
  ('Locations — the places within a site where stock actually stands.'),
  ('Marshalling areas'),
  ('Migration batches and cutover'),
  ('My approvals'),
  ('No assurance checks reported. That is itself unexpected — the platform runs these against every organisation.'),
  ('No change requests. Master data is currently as proposed.'),
  ('No imports staged. Stage a batch from a file, preview it row by row, and load it only once the errors are nil.'),
  ('No key has been issued yet. Rotate above to issue the first one; nothing can be stored encrypted until there is a key.'),
  ('Nothing is stored under the key yet. A protected value is written by the feature that owns it, not from this screen.'),
  ('Nothing is waiting on you. Requests appear here when an approval band routes one to you.'),
  ('Nothing open to release. Confirmed sales order lines appear here in the order they should be released.'),
  ('Notification routes'),
  ('Open demand in the order it should be released: promise date first, then credit standing, then value.'),
  ('Platform assurance'),
  ('Posting classes'),
  ('Pricing, promise, credit and returns'),
  ('Printers'),
  ('Printers are configuration: on a live organisation the edit is raised as a change and promoted, and a direct write here is refused. A label printer needs a language and a resolution; a document printer needs neither.'),
  ('Proposed master data changes and where each one has got to.'),
  ('Proposing a change'),
  ('Proposing a change, and the mass change that proposes the same edit against many records.'),
  ('Protected values'),
  ('Registering a device is the first act; a session is opened from the device itself. Scan rules are per step, with an optional product class that overrides the step''s default.'),
  ('Release sequence'),
  ('Replaying a message'),
  ('Replaying a message is the one thing a person does to the gateway by hand.'),
  ('Request the erasure of a user or a business partner''s contact. Another administrator executes it from the list below.'),
  ('Requesting an erasure'),
  ('Running a job by hand, and the kill switches that stop one from running at all.'),
  ('Running and stopping jobs'),
  ('Set the default once. Replenishment, planning and manual purchasing all resolve through it, so a missing default is a stopped order, not a silent guess.'),
  ('Stage a batch from a legacy extract, record the legacy figure against ours, then cut the domain over. A load is reversed from the batch itself, below.'),
  ('Stored encrypted under the key above; unreadable once it is destroyed.'),
  ('Subscriptions, packs and the analytics contract'),
  ('Supplier defaults'),
  ('Tasks assigned to you, directly or through a role you hold.'),
  ('The database authorises every one of these; you only see the ones you hold.'),
  ('The matrix. Leave a key field empty and the rule applies to anything; the narrowest matching rule wins.'),
  ('The verbs that sit between the documents: pricing, stock promise, credit and returns.'),
  ('The vocabulary. Keep it short — a class exists because two things post differently, not because they are different things.'),
  ('The wave is the unit of release: open it, put lines on it, allocate, then print.'),
  ('Value bands and named assignments. Resolution runs named assignment first, then the department''s bands.'),
  ('Waves'),
  ('What the platform itself says about this organisation''s configuration and isolation.'),
  ('What you can do here'),
  ('Your own adoption scenario')
  ) as v(text)
-- The nine that already had rows keep them: a value seeded deliberately
-- elsewhere is not this migration's to restate.
on conflict (key, locale) do nothing;

select erp.assert_vocabulary_aligned();
select erp.assert_resource_coverage('en');
