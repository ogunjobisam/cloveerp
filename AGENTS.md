<!-- LOVABLE:BEGIN -->
> [!IMPORTANT]
> This project is connected to [Lovable](https://lovable.dev). Avoid rewriting
> published git history — force pushing, or rebasing/amending/squashing commits
> that are already pushed — as it rewrites history on Lovable's side and the
> user will likely lose their project history.
>
> Commits you push to the connected branch sync back to Lovable and show up in
> the editor, so keep the branch in a working state.
<!-- LOVABLE:END -->

## Database migrations

One writer at a time — that is the whole rule. The 8 September incident was
caused by two routes applying the same migrations concurrently, not by the
connector itself.

- The Lovable Supabase connector **is** an allowed route for applying a
  migration, provided nothing else is applying at the same time.
- Before applying through the connector, check that no deploy run is in flight
  (`.github/workflows/deploy.yml`). If one is running, wait for it.
- The connector writes its own file into `supabase/migrations/`. Never
  hand-write a second copy of the same migration — one migration, one file.
- Migrations remain forward-only. Never edit a migration that has been pushed.
- A new public function must still assert its own governance in the same
  migration, and the migration must end by re-running the generators.
