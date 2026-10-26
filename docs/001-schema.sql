-- ============================================================
-- 情侣看看 · 数据库初始化 v1.0
-- 用法：Supabase 控制台 → SQL Editor → 新建查询 → 整段粘贴 → Run
-- 只需执行一次。重复执行会报「已存在」，可忽略。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 用户档案（auth.users 的镜像，存昵称头像）
-- ------------------------------------------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text,
  nickname    text not null default '',
  avatar_url  text,
  created_at  timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 2. 情侣关系（一人同时只能有一段 active）
-- ------------------------------------------------------------
create table if not exists public.couples (
  id          uuid primary key default gen_random_uuid(),
  user_a      uuid not null references public.profiles(id) on delete cascade,
  user_b      uuid not null references public.profiles(id) on delete cascade,
  status      text not null default 'active' check (status in ('active', 'ended')),
  created_at  timestamptz not null default now(),
  constraint couples_distinct check (user_a <> user_b)
);
create unique index if not exists couples_user_a_active on public.couples(user_a) where status = 'active';
create unique index if not exists couples_user_b_active on public.couples(user_b) where status = 'active';

-- ------------------------------------------------------------
-- 3. 设备
-- ------------------------------------------------------------
create table if not exists public.devices (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  platform      text not null check (platform in ('android', 'ios')),
  push_token    text,
  app_version   text,
  last_seen_at  timestamptz not null default now()
);
create index if not exists devices_user_idx on public.devices(user_id);

-- ------------------------------------------------------------
-- 4. 配对码
-- ------------------------------------------------------------
create table if not exists public.pair_codes (
  code        text primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  expires_at  timestamptz not null,
  used_at     timestamptz
);

-- ------------------------------------------------------------
-- 5. 位置点（只保留 7 天）
-- ------------------------------------------------------------
create table if not exists public.location_points (
  id           bigserial primary key,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  lat          double precision not null,
  lng          double precision not null,
  accuracy     real,
  speed        real,
  provider     text,
  battery      smallint,
  charging     boolean,
  recorded_at  timestamptz not null
);
create index if not exists location_points_user_time on public.location_points(user_id, recorded_at desc);
create index if not exists location_points_purge on public.location_points(recorded_at);

-- ------------------------------------------------------------
-- 6. 每日汇总
-- ------------------------------------------------------------
create table if not exists public.daily_usage (
  user_id         uuid not null references public.profiles(id) on delete cascade,
  date            date not null,
  screen_on_ms    bigint not null default 0,
  unlock_count    int not null default 0,
  lock_count      int not null default 0,
  first_unlock_at timestamptz,
  last_unlock_at  timestamptz,
  updated_at      timestamptz not null default now(),
  primary key (user_id, date)
);

-- ------------------------------------------------------------
-- 7. 应用使用（每应用每天一行，只存 Top 20）
-- ------------------------------------------------------------
create table if not exists public.app_usage (
  user_id        uuid not null references public.profiles(id) on delete cascade,
  date           date not null,
  package_name   text not null,
  app_label      text not null default '',
  foreground_ms  bigint not null default 0,
  launch_count   int not null default 0,
  primary key (user_id, date, package_name)
);

-- ------------------------------------------------------------
-- 8. 当前状态（反范式，主页只读这一张）
-- ------------------------------------------------------------
create table if not exists public.user_status (
  user_id      uuid primary key references public.profiles(id) on delete cascade,
  lat          double precision,
  lng          double precision,
  place_name   text,
  accuracy     real,
  battery      smallint,
  charging     boolean,
  online       boolean not null default false,
  paused_until timestamptz,
  updated_at   timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 9. 共享设置
-- ------------------------------------------------------------
create table if not exists public.settings (
  user_id             uuid primary key references public.profiles(id) on delete cascade,
  share_location      boolean not null default true,
  share_usage         boolean not null default true,
  share_battery       boolean not null default true,
  night_silence_start time,
  night_silence_end   time
);

-- ============================================================
-- 工具函数
-- ============================================================

-- 当前登录者的对象 id；没有对象返回 null
create or replace function public.my_partner_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select case when c.user_a = auth.uid() then c.user_b else c.user_a end
  from public.couples c
  where c.status = 'active' and (c.user_a = auth.uid() or c.user_b = auth.uid())
  limit 1;
$$;

-- 新用户进来时自动建档
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, nickname)
  values (
    new.id,
    new.email,
    coalesce(nullif(new.raw_user_meta_data ->> 'nickname', ''), split_part(coalesce(new.email, ''), '@', 1))
  )
  on conflict (id) do nothing;

  insert into public.settings (user_id) values (new.id) on conflict do nothing;
  insert into public.user_status (user_id) values (new.id) on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 生成六位配对码，十分钟有效
create or replace function public.generate_pair_code()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;

  if exists (
    select 1 from public.couples
    where status = 'active' and (user_a = auth.uid() or user_b = auth.uid())
  ) then
    raise exception 'already_paired';
  end if;

  loop
    v_code := lpad((floor(random() * 1000000))::int::text, 6, '0');
    exit when not exists (
      select 1 from public.pair_codes where code = v_code and expires_at > now() and used_at is null
    );
  end loop;

  insert into public.pair_codes (code, user_id, expires_at)
  values (v_code, auth.uid(), now() + interval '10 minutes')
  on conflict (code) do update
    set user_id = excluded.user_id,
        expires_at = excluded.expires_at,
        used_at = null;

  return v_code;
end;
$$;

-- 输入配对码完成绑定
create or replace function public.accept_pair_code(p_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner  uuid;
  v_couple uuid;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;

  select user_id into v_owner
  from public.pair_codes
  where code = p_code and used_at is null and expires_at > now()
  for update;

  if v_owner is null then
    raise exception 'invalid_code';
  end if;
  if v_owner = auth.uid() then
    raise exception 'cannot_pair_self';
  end if;
  if exists (
    select 1 from public.couples
    where status = 'active' and (user_a = auth.uid() or user_b = auth.uid())
  ) then
    raise exception 'already_paired';
  end if;
  if exists (
    select 1 from public.couples
    where status = 'active' and (user_a = v_owner or user_b = v_owner)
  ) then
    raise exception 'partner_already_paired';
  end if;

  insert into public.couples (user_a, user_b)
  values (v_owner, auth.uid())
  returning id into v_couple;

  update public.pair_codes set used_at = now() where code = p_code;
  return v_couple;
end;
$$;

-- 清理 7 天前的位置点（配合 pg_cron 每天跑一次）
create or replace function public.purge_old_locations()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.location_points where recorded_at < now() - interval '7 days';
$$;

revoke all on function public.generate_pair_code() from public;
revoke all on function public.accept_pair_code(text) from public;
revoke all on function public.my_partner_id() from public;
grant execute on function public.generate_pair_code() to authenticated;
grant execute on function public.accept_pair_code(text) to authenticated;
grant execute on function public.my_partner_id() to authenticated;

-- ============================================================
-- 行级权限：任何账号只能读到自己和对象的数据
-- ============================================================
alter table public.profiles        enable row level security;
alter table public.couples         enable row level security;
alter table public.devices         enable row level security;
alter table public.pair_codes      enable row level security;
alter table public.location_points enable row level security;
alter table public.daily_usage     enable row level security;
alter table public.app_usage       enable row level security;
alter table public.user_status     enable row level security;
alter table public.settings        enable row level security;

-- profiles
drop policy if exists "profiles read self or partner" on public.profiles;
create policy "profiles read self or partner" on public.profiles
  for select using (id = auth.uid() or id = public.my_partner_id());

drop policy if exists "profiles update self" on public.profiles;
create policy "profiles update self" on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

-- couples：只读自己的，写入只能走配对函数
drop policy if exists "couples read own" on public.couples;
create policy "couples read own" on public.couples
  for select using (user_a = auth.uid() or user_b = auth.uid());

-- devices
drop policy if exists "devices own all" on public.devices;
create policy "devices own all" on public.devices
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- pair_codes
drop policy if exists "pair_codes own read" on public.pair_codes;
create policy "pair_codes own read" on public.pair_codes
  for select using (user_id = auth.uid());

-- location_points：自己的随便写；对象的要对方开了共享且没暂停才看得到
drop policy if exists "locations insert own" on public.location_points;
create policy "locations insert own" on public.location_points
  for insert with check (user_id = auth.uid());

drop policy if exists "locations read own or shared partner" on public.location_points;
create policy "locations read own or shared partner" on public.location_points
  for select using (
    user_id = auth.uid()
    or (
      user_id = public.my_partner_id()
      and exists (
        select 1 from public.settings s
        where s.user_id = public.my_partner_id() and s.share_location
      )
      and not exists (
        select 1 from public.user_status us
        where us.user_id = public.my_partner_id() and us.paused_until > now()
      )
    )
  );

-- daily_usage
drop policy if exists "daily_usage write own" on public.daily_usage;
create policy "daily_usage write own" on public.daily_usage
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "daily_usage read partner" on public.daily_usage;
create policy "daily_usage read partner" on public.daily_usage
  for select using (
    user_id = public.my_partner_id()
    and exists (
      select 1 from public.settings s where s.user_id = public.my_partner_id() and s.share_usage
    )
  );

-- app_usage
drop policy if exists "app_usage write own" on public.app_usage;
create policy "app_usage write own" on public.app_usage
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "app_usage read partner" on public.app_usage;
create policy "app_usage read partner" on public.app_usage
  for select using (
    user_id = public.my_partner_id()
    and exists (
      select 1 from public.settings s where s.user_id = public.my_partner_id() and s.share_usage
    )
  );

-- user_status：对象的暂停状态必须永远可见，否则没法显示「她已暂停」
drop policy if exists "user_status write own" on public.user_status;
create policy "user_status write own" on public.user_status
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "user_status read partner" on public.user_status;
create policy "user_status read partner" on public.user_status
  for select using (user_id = public.my_partner_id());

-- settings
drop policy if exists "settings own all" on public.settings;
create policy "settings own all" on public.settings
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "settings read partner" on public.settings;
create policy "settings read partner" on public.settings
  for select using (user_id = public.my_partner_id());

-- ============================================================
-- 实时推送
-- ============================================================
alter publication supabase_realtime add table public.user_status;
alter publication supabase_realtime add table public.location_points;

-- ============================================================
-- 定时清理（需先启用 pg_cron 扩展，Dashboard → Database → Extensions）
-- ============================================================
-- select cron.schedule('purge-locations', '0 4 * * *', 'select public.purge_old_locations()');
