-- ข้อมูลกลางของแคมเปญ: แคปชั่นแยกช่อง · หลายโพสต์ต่อแคมเปญ · ข้อมูลลงร้าน + ลิงก์ร้าน
-- บอทอ่านด้วยชื่อแคมเปญ: POST /rest/v1/rpc/get_campaign {"name": "..."}
-- ไม่แตะ app_data

alter table public.campaigns add column if not exists captions jsonb not null default '{}'::jsonb;
-- captions = { fb_ig_tt, x, threads, yt_community, yt_poll: [..], lemon8 }
alter table public.campaigns add column if not exists listing jsonb not null default '{}'::jsonb;
-- listing  = { product_name, options, price, description, keywords, shops: [..], links: { "<ร้าน>": "<url>" } }

create table if not exists public.campaign_posts (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.campaigns(id) on delete cascade,
  sort integer not null default 0,
  label text not null default '',
  post_date date,
  post_time text not null default '',
  image_set text not null default '',
  folder_path text not null default '',
  image_order text not null default '',
  comment_link boolean not null default false,
  comment_text text not null default '',
  media_kind text not null default 'photo' check (media_kind in ('photo', 'video', 'both')),
  media_url text not null default '',
  captions jsonb not null default '{}'::jsonb, -- ทับแคปชั่นของแคมเปญเฉพาะช่องที่กรอก
  post_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text not null default '',
  updated_by text not null default '',
  deleted_at timestamptz,
  deleted_by text
);
create index if not exists campaign_posts_campaign_idx on public.campaign_posts (campaign_id, sort);
create index if not exists campaign_posts_date_idx on public.campaign_posts (post_date);

drop trigger if exists campaign_posts_touch on public.campaign_posts;
create trigger campaign_posts_touch before update on public.campaign_posts
  for each row execute function public.prep_touch_updated_at();

alter table public.campaign_posts enable row level security;
revoke all on public.campaign_posts from anon, authenticated;
grant select, insert, update on public.campaign_posts to anon, authenticated;
drop policy if exists campaign_posts_select on public.campaign_posts;
create policy campaign_posts_select on public.campaign_posts for select to anon, authenticated using (true);
drop policy if exists campaign_posts_insert on public.campaign_posts;
create policy campaign_posts_insert on public.campaign_posts for insert to anon, authenticated with check (true);
drop policy if exists campaign_posts_update on public.campaign_posts;
create policy campaign_posts_update on public.campaign_posts for update to anon, authenticated using (true) with check (true);
alter table public.campaign_posts replica identity full;
do $$ begin
  begin alter publication supabase_realtime add table public.campaign_posts; exception when duplicate_object then null; end;
end $$;

-- ย้ายข้อมูลเดิม: แคปชั่นเดิม -> captions.fb_ig_tt · ร้านของแคมเปญ -> listing.shops · วันโพสต์เดิม -> โพสต์หลัก 1 โพสต์
update public.campaigns set captions = jsonb_build_object('fb_ig_tt', caption)
  where caption <> '' and not (captions ? 'fb_ig_tt');
update public.campaigns set listing = jsonb_build_object('shops', shops)
  where listing = '{}'::jsonb and jsonb_array_length(shops) > 0;
insert into public.campaign_posts (campaign_id, sort, label, post_date, media_kind, media_url, post_id, created_by, updated_by)
  select c.id, 1, 'โพสต์หลัก', c.post_start, c.media_kind, c.media_url, c.post_id, 'PROGRAMMER REALLYCUTE', 'PROGRAMMER REALLYCUTE'
  from public.campaigns c
  where c.post_start is not null and c.deleted_at is null
    and not exists (select 1 from public.campaign_posts p where p.campaign_id = c.id);

-- ===== อ่านแคมเปญเป็น JSON ก้อนเดียว (ชื่อไม่สนตัวพิมพ์ ตรงทั้งชื่อก่อน แล้วค่อยค้นบางส่วน) =====
create or replace function public.campaign_json(c public.campaigns)
returns jsonb language sql stable set search_path = public as $$
  select to_jsonb(c) - 'caption' - 'media_url' - 'media_kind'
    || jsonb_build_object(
      'posts', coalesce((select jsonb_agg(to_jsonb(p) - 'campaign_id' order by p.post_date nulls last, p.post_time, p.sort)
        from public.campaign_posts p where p.campaign_id = c.id and p.deleted_at is null), '[]'::jsonb),
      'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'sort', t.sort, 'title', t.title, 'detail', t.detail, 'assignee', t.assignee, 'due_date', t.due_date, 'status', t.status, 'template_key', t.template_key) order by t.sort)
        from public.campaign_tasks t where t.campaign_id = c.id and t.deleted_at is null), '[]'::jsonb)
    );
$$;

create or replace function public.get_campaign(name text)
returns jsonb language sql stable set search_path = public as $$
  select public.campaign_json(c)
  from public.campaigns c
  where c.deleted_at is null and (lower(c.name) = lower(trim(get_campaign.name)) or c.name ilike '%' || trim(get_campaign.name) || '%')
  order by (lower(c.name) = lower(trim(get_campaign.name))) desc, c.image_date desc nulls last, c.created_at desc
  limit 1;
$$;

create or replace function public.find_campaigns(q text default '')
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'image_date', c.image_date, 'post_start', c.post_start, 'post_end', c.post_end, 'product_type', c.product_type, 'city', c.city)
    order by c.post_start nulls last, c.image_date), '[]'::jsonb)
  from public.campaigns c
  where c.deleted_at is null and (coalesce(q, '') = '' or c.name ilike '%' || trim(q) || '%');
$$;

-- ===== พนักงานลงสินค้ากรอกลิงก์ร้านกลับ (ชื่อแคมเปญต้องตรงทั้งชื่อ ไม่สนตัวพิมพ์) =====
create or replace function public.set_listing_link(campaign_name text, shop text, url text, actor text default 'พนักงานลงสินค้า')
returns jsonb language plpgsql volatile set search_path = public as $$
declare
  shops_ok text[] := array['Shopee wararit.th', 'Shopee ployririta', 'Shopee reallycute.th', 'Lazada', 'TikTok Shop', 'ThaiMart', 'Line My Shop'];
  c public.campaigns;
  n int;
  who text := coalesce(nullif(trim(actor), ''), 'พนักงานลงสินค้า');
begin
  if not (shop = any(shops_ok)) then
    raise exception 'unknown shop "%" (use one of: %)', shop, array_to_string(shops_ok, ', ');
  end if;
  select count(*) into n from public.campaigns where deleted_at is null and lower(name) = lower(trim(campaign_name));
  if n = 0 then raise exception 'campaign "%" not found (exact name, case-insensitive)', campaign_name; end if;
  if n > 1 then raise exception 'campaign name "%" matches % campaigns', campaign_name, n; end if;
  select * into c from public.campaigns where deleted_at is null and lower(name) = lower(trim(campaign_name));
  update public.campaigns
    set listing = jsonb_set(coalesce(listing, '{}'::jsonb), '{links}', coalesce(listing->'links', '{}'::jsonb) || jsonb_build_object(shop, coalesce(url, ''))),
        updated_by = who
    where id = c.id
    returning * into c;
  insert into public.activity_log (actor, action, summary, detail)
    values (who, 'campaign-listing-link', 'ใส่ลิงก์ร้าน ' || shop || ' ของแคมเปญ «' || c.name || '»',
      jsonb_build_object('key', 'campaigns', 'edited', jsonb_build_array(jsonb_build_object('id', c.id, 'label', c.name, 'fields', jsonb_build_array('listing'))), 'editedCount', 1, 'shop', shop, 'url', url));
  return public.campaign_json(c);
end $$;

revoke all on function public.campaign_json(public.campaigns) from public;
revoke all on function public.get_campaign(text) from public;
revoke all on function public.find_campaigns(text) from public;
revoke all on function public.set_listing_link(text, text, text, text) from public;
grant execute on function public.campaign_json(public.campaigns) to anon, authenticated;
grant execute on function public.get_campaign(text) to anon, authenticated;
grant execute on function public.find_campaigns(text) to anon, authenticated;
grant execute on function public.set_listing_link(text, text, text, text) to anon, authenticated;
notify pgrst, 'reload schema';
