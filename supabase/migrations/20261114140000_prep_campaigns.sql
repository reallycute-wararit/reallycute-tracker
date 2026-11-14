-- แท็บ «งานเตรียม»: แคมเปญ (1 แคมเปญ = 1 ชุดโพสต์) และงานย่อยของแต่ละแคมเปญ
-- ไม่แตะตาราง app_data (สินค้า/โพสต์/ยอดขาย) เดิม
-- ลบจากหน้าเว็บ = ใส่ deleted_at (ไปถังขยะ กู้คืนได้) · anon ไม่มีสิทธิ์ DELETE

create extension if not exists pgcrypto;

create table if not exists public.campaigns (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  post_start date,
  post_end date,
  image_date date,
  city text not null default '',
  product_type text check (product_type is null or product_type in ('licensed', 'original', 'unlicensed')),
  channels jsonb not null default '[]'::jsonb,
  shops jsonb not null default '[]'::jsonb,
  product_ids jsonb not null default '[]'::jsonb,
  note text not null default '',
  media_kind text not null default 'photo' check (media_kind in ('photo', 'video', 'both')),
  media_url text not null default '',
  caption text not null default '',
  post_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text not null default '',
  updated_by text not null default '',
  deleted_at timestamptz,
  deleted_by text
);

create table if not exists public.campaign_tasks (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.campaigns(id) on delete cascade,
  sort integer not null default 0,
  title text not null default '',
  detail text not null default '',
  assignee text not null default '',
  due_date date,
  status text not null default 'todo' check (status in ('todo', 'doing', 'done')),
  template_key text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text not null default '',
  updated_by text not null default '',
  deleted_at timestamptz,
  deleted_by text
);

create index if not exists campaigns_image_date_idx on public.campaigns (image_date);
create index if not exists campaigns_post_start_idx on public.campaigns (post_start);
create index if not exists campaign_tasks_campaign_idx on public.campaign_tasks (campaign_id, sort);

create or replace function public.prep_touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists campaigns_touch on public.campaigns;
create trigger campaigns_touch before update on public.campaigns
  for each row execute function public.prep_touch_updated_at();

drop trigger if exists campaign_tasks_touch on public.campaign_tasks;
create trigger campaign_tasks_touch before update on public.campaign_tasks
  for each row execute function public.prep_touch_updated_at();

alter table public.campaigns enable row level security;
alter table public.campaign_tasks enable row level security;

revoke all on public.campaigns from anon, authenticated;
revoke all on public.campaign_tasks from anon, authenticated;
grant select, insert, update on public.campaigns to anon, authenticated;
grant select, insert, update on public.campaign_tasks to anon, authenticated;

drop policy if exists campaigns_select on public.campaigns;
create policy campaigns_select on public.campaigns for select to anon, authenticated using (true);
drop policy if exists campaigns_insert on public.campaigns;
create policy campaigns_insert on public.campaigns for insert to anon, authenticated with check (true);
drop policy if exists campaigns_update on public.campaigns;
create policy campaigns_update on public.campaigns for update to anon, authenticated using (true) with check (true);

drop policy if exists campaign_tasks_select on public.campaign_tasks;
create policy campaign_tasks_select on public.campaign_tasks for select to anon, authenticated using (true);
drop policy if exists campaign_tasks_insert on public.campaign_tasks;
create policy campaign_tasks_insert on public.campaign_tasks for insert to anon, authenticated with check (true);
drop policy if exists campaign_tasks_update on public.campaign_tasks;
create policy campaign_tasks_update on public.campaign_tasks for update to anon, authenticated using (true) with check (true);

-- ไม่มี delete policy: ลบถาวรจากหน้าเว็บไม่ได้ ใช้ deleted_at แทน

alter table public.campaigns replica identity full;
alter table public.campaign_tasks replica identity full;

do $$
begin
  begin
    alter publication supabase_realtime add table public.campaigns;
  exception
    when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.campaign_tasks;
  exception
    when duplicate_object then null;
  end;
end $$;
