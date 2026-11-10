-- Run this manually in the Supabase SQL editor. Do not apply it from the app.
-- The tracker keeps working before this is run: edits still merge through app_data,
-- and activity is stored in the app_data key "activity" until this table exists.
-- After it runs, the page and bots insert into activity_log instead, and realtime
-- can push app_data / activity_log changes without waiting for the poll.

create table if not exists public.activity_log (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  actor text not null,
  action text not null,
  summary text not null,
  detail jsonb
);

create index if not exists activity_log_created_at_idx
  on public.activity_log (created_at desc);

alter table public.activity_log enable row level security;

grant select, insert on public.activity_log to anon, authenticated;
grant usage, select on sequence public.activity_log_id_seq to anon, authenticated;

drop policy if exists activity_log_select on public.activity_log;
create policy activity_log_select
  on public.activity_log
  for select
  to anon, authenticated
  using (true);

drop policy if exists activity_log_insert on public.activity_log;
create policy activity_log_insert
  on public.activity_log
  for insert
  to anon, authenticated
  with check (true);

-- No update or delete policy: the log is append-only for the anon key.

alter table public.activity_log replica identity full;
alter table public.app_data replica identity full;

do $$
begin
  begin
    alter publication supabase_realtime add table public.activity_log;
  exception
    when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.app_data;
  exception
    when duplicate_object then null;
  end;
end $$;
