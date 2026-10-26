-- ============================================================
-- 情侣看看 · 加固补丁 003
-- 依赖：001、002 已执行
-- 处理审查项 R01、R02、R03、R07
-- 幂等：可重复执行
-- ============================================================

-- ------------------------------------------------------------
-- 1. 关系唯一性（R02）
-- 001 里 user_a、user_b 各一个唯一索引，
-- 拦不住同一个人在一行当 a、在另一行当 b。
-- 用一张成员表把「一人最多一段关系」变成主键约束。
-- ------------------------------------------------------------
create table if not exists public.couple_members (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  couple_id  uuid not null references public.couples(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists couple_members_couple_idx on public.couple_members(couple_id);

-- 回填已有关系
insert into public.couple_members (user_id, couple_id)
select user_a, id from public.couples where status = 'active'
on conflict (user_id) do nothing;
insert into public.couple_members (user_id, couple_id)
select user_b, id from public.couples where status = 'active'
on conflict (user_id) do nothing;

alter table public.couple_members enable row level security;

drop policy if exists "couple_members read own or partner" on public.couple_members;
create policy "couple_members read own or partner" on public.couple_members
  for select using (user_id = auth.uid() or user_id = public.my_partner_id());

drop policy if exists "couple_members write own" on public.couple_members;
create policy "couple_members write own" on public.couple_members
  for insert with check (user_id = auth.uid());

-- 对象 id 改成从成员表取，一人一行，不再有 limit 1 的歧义
create or replace function public.my_partner_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select case when c.user_a = auth.uid() then c.user_b else c.user_a end
  from public.couple_members m
  join public.couples c on c.id = m.couple_id and c.status = 'active'
  where m.user_id = auth.uid()
  limit 1;
$$;

revoke all on function public.my_partner_id() from public;
grant execute on function public.my_partner_id() to authenticated;

-- 生成码：先作废该用户所有未使用的旧码
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

  if exists (select 1 from public.couple_members where user_id = auth.uid()) then
    raise exception 'already_paired';
  end if;

  update public.pair_codes set used_at = now()
  where user_id = auth.uid() and used_at is null;

  loop
    v_code := lpad((floor(random() * 1000000))::int::text, 6, '0');
    exit when not exists (
      select 1 from public.pair_codes
      where code = v_code and used_at is null and expires_at > now()
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

-- 接受码：锁码行、锁双方档案行，锁内重查
create or replace function public.accept_pair_code(p_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_owner  uuid;
  v_couple uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select user_id into v_owner
  from public.pair_codes
  where code = p_code and used_at is null and expires_at > now()
  for update;

  if v_owner is null then
    raise exception 'invalid_code';
  end if;
  if v_owner = v_uid then
    raise exception 'cannot_pair_self';
  end if;

  perform 1 from public.profiles where id = least(v_uid, v_owner) for update;
  perform 1 from public.profiles where id = greatest(v_uid, v_owner) for update;

  if exists (select 1 from public.couple_members where user_id = v_uid) then
    raise exception 'already_paired';
  end if;
  if exists (select 1 from public.couple_members where user_id = v_owner) then
    raise exception 'partner_already_paired';
  end if;

  insert into public.couples (user_a, user_b) values (v_owner, v_uid)
  returning id into v_couple;

  insert into public.couple_members (user_id, couple_id)
  values (v_owner, v_couple), (v_uid, v_couple);

  update public.pair_codes set used_at = now() where code = p_code;

  return v_couple;
end;
$$;

revoke all on function public.generate_pair_code() from public;
revoke all on function public.accept_pair_code(text) from public;
grant execute on function public.generate_pair_code() to authenticated;
grant execute on function public.accept_pair_code(text) to authenticated;

-- ------------------------------------------------------------
-- 2. 存在表（R01、R07）
-- 只放「他还在不在」这类不敏感字段，订阅它做刷新信号。
-- 坐标、电量一律不放，从结构上断掉泄漏路径。
-- ------------------------------------------------------------
create table if not exists public.presence (
  user_id        uuid primary key references public.profiles(id) on delete cascade,
  online         boolean not null default false,
  last_report_at timestamptz,
  updated_at     timestamptz not null default now()
);
create index if not exists presence_updated_idx on public.presence(updated_at desc);

alter table public.presence enable row level security;

drop policy if exists "presence write own" on public.presence;
create policy "presence write own" on public.presence
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "presence read partner" on public.presence;
create policy "presence read partner" on public.presence
  for select using (user_id = public.my_partner_id());

-- 订阅 signal 只走这张表
do $$
begin
  alter publication supabase_realtime add table public.presence;
exception when duplicate_object then null;
end $$;

-- 老用户补一行
insert into public.presence (user_id) select id from public.profiles
on conflict (user_id) do nothing;

-- ------------------------------------------------------------
-- 3. 撤掉对象的整行读权限（R01）
-- 原表仍然只有本人可读，对象的数据只能走 get_status。
-- ------------------------------------------------------------
drop policy if exists "user_status read partner" on public.user_status;

-- 002 里那个视图把 share_location 漏了，直接废弃
drop view if exists public.visible_status;

-- ------------------------------------------------------------
-- 4. 唯一的对外读入口（R01）
-- 位置、精度、地名受 share_location 与暂停双重约束，
-- 电量、充电受 share_battery 约束，
-- 暂停覆盖全部三类。
-- ------------------------------------------------------------
create or replace function public.get_status(p_user_id uuid default null)
returns table (
  user_id        uuid,
  lat            double precision,
  lng            double precision,
  accuracy       real,
  place_name     text,
  battery        smallint,
  charging       boolean,
  online         boolean,
  paused_until   timestamptz,
  last_report_at timestamptz,
  updated_at     timestamptz,
  share_location boolean,
  share_usage    boolean,
  share_battery  boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_target uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  v_target := coalesce(p_user_id, public.my_partner_id());
  if v_target is null then
    return;
  end if;
  if v_target <> v_uid and v_target <> public.my_partner_id() then
    raise exception 'not_allowed';
  end if;

  return query
  select
    p.id,
    case when us.paused_until > now() or not coalesce(s.share_location, true)
         then null else us.lat end,
    case when us.paused_until > now() or not coalesce(s.share_location, true)
         then null else us.lng end,
    case when us.paused_until > now() or not coalesce(s.share_location, true)
         then null else us.accuracy end,
    case when us.paused_until > now() or not coalesce(s.share_location, true)
         then null else us.place_name end,
    case when us.paused_until > now() or not coalesce(s.share_battery, true)
         then null else us.battery end,
    case when us.paused_until > now() or not coalesce(s.share_battery, true)
         then null else us.charging end,
    coalesce(pr.online, false),
    us.paused_until,
    pr.last_report_at,
    coalesce(pr.updated_at, us.updated_at),
    coalesce(s.share_location, true),
    coalesce(s.share_usage, true),
    coalesce(s.share_battery, true)
  from public.profiles p
  left join public.user_status us on us.user_id = p.id
  left join public.settings    s  on s.user_id  = p.id
  left join public.presence    pr on pr.user_id = p.id
  where p.id = v_target;
end;
$$;

revoke all on function public.get_status(uuid) from public;
grant execute on function public.get_status(uuid) to authenticated;

-- ------------------------------------------------------------
-- 5. 上报位置（R01 附带、R11 成功判据）
-- 返回 received 与 inserted 两个数。
-- 客户端认「收到条数等于提交条数」为成功，
-- 不能拿 inserted 判，重发时它是 0。
-- ------------------------------------------------------------
-- 002 建的是返回 int，这里要改成 jsonb。
-- Postgres 不允许 create or replace 改返回类型，必须先 drop。
drop function if exists public.report_locations(jsonb);

create or replace function public.report_locations(p_points jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_n     int  := 0;
  v_got   int  := 0;
  v_last  jsonb;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  if p_points is null or jsonb_typeof(p_points) <> 'array' then
    raise exception 'invalid_payload';
  end if;

  v_got := jsonb_array_length(p_points);
  if v_got = 0 then
    return jsonb_build_object('received', 0, 'inserted', 0);
  end if;
  if v_got > 50 then
    raise exception 'batch_too_large';
  end if;

  insert into public.location_points
    (user_id, lat, lng, accuracy, speed, provider, battery, charging, recorded_at)
  select
    v_uid,
    (e ->> 'lat')::double precision,
    (e ->> 'lng')::double precision,
    nullif(e ->> 'accuracy', '')::real,
    nullif(e ->> 'speed', '')::real,
    e ->> 'provider',
    nullif(e ->> 'battery', '')::smallint,
    nullif(e ->> 'charging', '')::boolean,
    (e ->> 'recorded_at')::timestamptz
  from jsonb_array_elements(p_points) as e
  on conflict (user_id, recorded_at) do nothing;

  get diagnostics v_n = row_count;

  select e into v_last
  from jsonb_array_elements(p_points) as e
  order by (e ->> 'recorded_at')::timestamptz desc
  limit 1;

  insert into public.user_status as us
    (user_id, lat, lng, place_name, accuracy, battery, charging, online, updated_at)
  values (
    v_uid,
    (v_last ->> 'lat')::double precision,
    (v_last ->> 'lng')::double precision,
    v_last ->> 'place_name',
    nullif(v_last ->> 'accuracy', '')::real,
    nullif(v_last ->> 'battery', '')::smallint,
    nullif(v_last ->> 'charging', '')::boolean,
    true,
    (v_last ->> 'recorded_at')::timestamptz
  )
  on conflict (user_id) do update
    set lat        = excluded.lat,
        lng        = excluded.lng,
        place_name = excluded.place_name,
        accuracy   = excluded.accuracy,
        battery    = excluded.battery,
        charging   = excluded.charging,
        online     = true,
        updated_at = excluded.updated_at
    where excluded.updated_at >= us.updated_at;

  insert into public.presence as pr (user_id, online, last_report_at, updated_at)
  values (v_uid, true, (v_last ->> 'recorded_at')::timestamptz, now())
  on conflict (user_id) do update
    set online         = true,
        last_report_at = greatest(coalesce(pr.last_report_at, 'epoch'::timestamptz),
                                  excluded.last_report_at),
        updated_at     = now();

  return jsonb_build_object('received', v_got, 'inserted', v_n);
end;
$$;

revoke all on function public.report_locations(jsonb) from public;
grant execute on function public.report_locations(jsonb) to authenticated;

-- ------------------------------------------------------------
-- 6. 上报用机快照（R03）
-- 增加采集截止时间。旧快照不覆盖新快照，返回 -1 表示丢弃。
-- ------------------------------------------------------------
alter table public.daily_usage
  add column if not exists captured_at timestamptz;

drop function if exists public.report_usage(date, jsonb, jsonb);

create or replace function public.report_usage(
  p_date        date,
  p_daily       jsonb,
  p_apps        jsonb,
  p_captured_at timestamptz
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_n        int  := 0;
  v_existing timestamptz;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  if p_date is null or p_captured_at is null then
    raise exception 'invalid_payload';
  end if;
  if p_daily is null or jsonb_typeof(p_daily) <> 'object' then
    raise exception 'invalid_payload';
  end if;
  if p_apps is not null and jsonb_typeof(p_apps) <> 'array' then
    raise exception 'invalid_payload';
  end if;
  if p_apps is not null and jsonb_array_length(p_apps) > 20 then
    raise exception 'batch_too_large';
  end if;

  select captured_at into v_existing
  from public.daily_usage
  where user_id = v_uid and date = p_date;

  -- 旧快照直接丢弃，日汇总与应用列表同进同退
  if v_existing is not null and v_existing > p_captured_at then
    return -1;
  end if;

  insert into public.daily_usage as du
    (user_id, date, screen_on_ms, unlock_count, lock_count,
     first_unlock_at, last_unlock_at, captured_at, updated_at)
  values (
    v_uid, p_date,
    coalesce((p_daily ->> 'screen_on_ms')::bigint, 0),
    coalesce((p_daily ->> 'unlock_count')::int, 0),
    coalesce((p_daily ->> 'lock_count')::int, 0),
    nullif(p_daily ->> 'first_unlock_at', '')::timestamptz,
    nullif(p_daily ->> 'last_unlock_at', '')::timestamptz,
    p_captured_at,
    now()
  )
  on conflict (user_id, date) do update
    set screen_on_ms    = excluded.screen_on_ms,
        unlock_count    = excluded.unlock_count,
        lock_count      = excluded.lock_count,
        first_unlock_at = excluded.first_unlock_at,
        last_unlock_at  = excluded.last_unlock_at,
        captured_at     = excluded.captured_at,
        updated_at      = now();

  delete from public.app_usage where user_id = v_uid and date = p_date;

  if p_apps is not null then
    insert into public.app_usage
      (user_id, date, package_name, app_label, foreground_ms, launch_count)
    select
      v_uid, p_date,
      e ->> 'package_name',
      coalesce(e ->> 'app_label', ''),
      coalesce((e ->> 'foreground_ms')::bigint, 0),
      coalesce((e ->> 'launch_count')::int, 0)
    from jsonb_array_elements(p_apps) as e
    where coalesce(e ->> 'package_name', '') <> ''
    on conflict (user_id, date, package_name) do update
      set app_label     = excluded.app_label,
          foreground_ms = excluded.foreground_ms,
          launch_count  = excluded.launch_count;

    get diagnostics v_n = row_count;
  end if;

  return v_n;
end;
$$;

revoke all on function public.report_usage(date, jsonb, jsonb, timestamptz) from public;
grant execute on function public.report_usage(date, jsonb, jsonb, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 7. 暂停与分项开关（R01、R06）
-- 一次事务里同时改状态表和存在表，避免半生效。
-- ------------------------------------------------------------
create or replace function public.set_pause(p_until timestamptz)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;

  update public.user_status
    set paused_until = p_until, updated_at = now()
    where user_id = auth.uid();

  update public.presence
    set updated_at = now()
    where user_id = auth.uid();
end;
$$;

create or replace function public.set_sharing(
  p_location boolean,
  p_usage    boolean,
  p_battery  boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;

  insert into public.settings as s
    (user_id, share_location, share_usage, share_battery)
  values (auth.uid(), p_location, p_usage, p_battery)
  on conflict (user_id) do update
    set share_location = excluded.share_location,
        share_usage    = excluded.share_usage,
        share_battery  = excluded.share_battery;

  update public.presence set updated_at = now() where user_id = auth.uid();
end;
$$;

revoke all on function public.set_pause(timestamptz) from public;
revoke all on function public.set_sharing(boolean, boolean, boolean) from public;
grant execute on function public.set_pause(timestamptz) to authenticated;
grant execute on function public.set_sharing(boolean, boolean, boolean) to authenticated;

-- ============================================================
-- 校验（四行都应为 ok）
-- ============================================================
select
  (select count(*) from pg_tables
    where schemaname = 'public' and tablename = 'couple_members') = 1 as members_ok,
  (select count(*) from pg_tables
    where schemaname = 'public' and tablename = 'presence') = 1 as presence_ok,
  (select count(*) from pg_policies
    where schemaname = 'public' and tablename = 'user_status'
      and policyname = 'user_status read partner') = 0 as leak_closed,
  (select count(*) from pg_proc
    where pronamespace = 'public'::regnamespace
      and proname in ('get_status', 'set_pause', 'set_sharing')) = 3 as funcs_ok;
