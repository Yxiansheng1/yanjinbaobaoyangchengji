-- ============================================================
-- 情侣看看 · 加固补丁 003
-- 依赖：001、002 已执行
-- 幂等：可重复执行，含部分执行后重跑
--
-- 处理：
--   R01 共享权限绕过        R02 配对唯一性
--   R03 快照乱序            R07 无数据判定
--   N01 未配对账号越权读    N02 暂停后仍可读历史
--   N03 历史电量未遮蔽      N04 成员表可伪造
--   N05 快照并发窗口        N06 恢复后返回旧坐标
--   N07 发布范围与新用户初始化
-- ============================================================

-- ------------------------------------------------------------
-- 1. 关系成员（R02、N04）
-- user_id 作主键：一人最多一段关系。
-- 不开放任何直接写入策略，只允许配对新函数写。
-- ------------------------------------------------------------
create table if not exists public.couple_members (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  couple_id  uuid not null references public.couples(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists couple_members_couple_idx on public.couple_members(couple_id);

alter table public.couple_members enable row level security;

drop policy if exists "couple_members write own" on public.couple_members;
drop policy if exists "couple_members read own or partner" on public.couple_members;
create policy "couple_members read own or partner" on public.couple_members
  for select using (user_id = auth.uid() or user_id = public.my_partner_id());

-- 回填：任何不一致都报错并列出要修的行，不用 ON CONFLICT DO NOTHING 掩盖
do $$
declare
  v_bad text;
begin
  -- 1. 一人出现在两段 active 关系里，成员表一人一行放不下
  select string_agg(format('user %s 同时在 %s 段 active 关系里', uid, n), '; ')
  into v_bad
  from (
    select uid, count(*) as n
    from (
      select user_a as uid from public.couples where status = 'active'
      union all
      select user_b from public.couples where status = 'active'
    ) t
    group by uid having count(*) > 1
  ) d;
  if v_bad is not null then
    raise exception 'couples 存在一人多段 active 关系，先修数据再跑本脚本：%', v_bad;
  end if;

  -- 2. 自己和自己配对
  select string_agg(format('couple %s 两侧是同一人 %s', id, user_a), '; ')
  into v_bad
  from public.couples
  where status = 'active' and user_a = user_b;
  if v_bad is not null then
    raise exception 'couples 存在自己配自己的关系，先修数据：%', v_bad;
  end if;

  -- 3. 已有成员行与 active 关系不一致：指向别的关系、指向已失效关系、或伪造行
  select string_agg(
           format('user %s: 成员行 %s，应为 %s', m.user_id, m.couple_id, coalesce(c.id::text, '无')),
           '; ')
  into v_bad
  from public.couple_members m
  left join public.couples c
    on c.status = 'active' and (c.user_a = m.user_id or c.user_b = m.user_id)
  where c.id is null or c.id <> m.couple_id;
  if v_bad is not null then
    raise exception '成员表与 active 关系不一致，先修数据：%', v_bad;
  end if;
end $$;

insert into public.couple_members (user_id, couple_id)
select user_a, id from public.couples where status = 'active'
on conflict (user_id) do nothing;
insert into public.couple_members (user_id, couple_id)
select user_b, id from public.couples where status = 'active'
on conflict (user_id) do nothing;

-- 对象 id：必须本人是这段关系的成员，不信成员表里的孤儿行
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
    and (c.user_a = auth.uid() or c.user_b = auth.uid())
  limit 1;
$$;

revoke all on function public.my_partner_id() from public;
grant execute on function public.my_partner_id() to authenticated;

-- 生成码：发新码前作废旧码
-- 同码碰撞不用 upsert 覆盖，否则会把别人的码改到自己名下。
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
    insert into public.pair_codes (code, user_id, expires_at)
    values (v_code, auth.uid(), now() + interval '10 minutes')
    on conflict (code) do nothing;
    exit when found;
  end loop;

  return v_code;
end;
$$;

-- 接受码：锁码行、按固定顺序锁双方档案行，锁内重查
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
-- 2. 存在表（R07、N06、N07）
-- 只放不敏感字段，订阅只发这张表。
-- resumed_at 记录手动恢复时刻，用来挡住恢复前的旧点。
-- ------------------------------------------------------------
create table if not exists public.presence (
  user_id        uuid primary key references public.profiles(id) on delete cascade,
  online         boolean not null default false,
  last_report_at timestamptz,
  resumed_at     timestamptz,
  updated_at     timestamptz not null default now()
);
create index if not exists presence_updated_idx on public.presence(updated_at desc);

-- v1 曾在线上建过这张表（没有 resumed_at），这里补列
alter table public.presence
  add column if not exists resumed_at timestamptz;

alter table public.presence enable row level security;

drop policy if exists "presence write own" on public.presence;
create policy "presence write own" on public.presence
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "presence read partner" on public.presence;
create policy "presence read partner" on public.presence
  for select using (user_id = public.my_partner_id());

insert into public.presence (user_id) select id from public.profiles
where id not in (select user_id from public.presence);

-- ------------------------------------------------------------
-- 3. 发布集合（N07）
-- 敏感表移出实时发布，只留 presence。
-- ------------------------------------------------------------
do $$
begin
  alter publication supabase_realtime add table public.presence;
exception when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime drop table public.user_status;
exception when others then null;
end $$;

do $$
begin
  alter publication supabase_realtime drop table public.location_points;
exception when others then null;
end $$;

-- 新注册用户也要有 presence 行，否则开场就没有刷新信号
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
  insert into public.presence (user_id) values (new.id) on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ------------------------------------------------------------
-- 4. 收回对象的原始表读权限（R01、N02、N03）
-- 历史位置、日报、应用明细一律不再直读，改走受控函数。
-- 依赖 user_status 的否定子查询因此全部失效，不再有得判。
-- ------------------------------------------------------------
drop policy if exists "user_status read partner"      on public.user_status;
drop policy if exists "locations read own or shared partner" on public.location_points;
drop policy if exists "daily_usage read partner"      on public.daily_usage;
drop policy if exists "app_usage read partner"        on public.app_usage;

-- 本人仍可读自己的历史点（v0.3 轨迹要用）
drop policy if exists "locations read own" on public.location_points;
create policy "locations read own" on public.location_points
  for select using (user_id = auth.uid());

-- 客户端只读自己的数据；写一律走函数。
-- 直写会绕过纯查看模式（V20）、快照版本比较（N05）与上报校验，
-- 因此把四张数据表的写策略全部收掉，只留自己的读策略。
drop policy if exists "locations insert own" on public.location_points;

drop policy if exists "daily_usage write own" on public.daily_usage;
drop policy if exists "daily_usage read own"  on public.daily_usage;
create policy "daily_usage read own" on public.daily_usage
  for select using (user_id = auth.uid());

drop policy if exists "app_usage write own" on public.app_usage;
drop policy if exists "app_usage read own"  on public.app_usage;
create policy "app_usage read own" on public.app_usage
  for select using (user_id = auth.uid());

drop policy if exists "user_status write own" on public.user_status;
drop policy if exists "user_status read own"  on public.user_status;
create policy "user_status read own" on public.user_status
  for select using (user_id = auth.uid());

-- 权限层再收一道：UPDATE 在只有 RLS 时会静默匹配 0 行，客户端看不出没写成。
-- 直接不给 INSERT/UPDATE/DELETE 权限，写错会立刻报 42501。
-- 上报与设置函数是 SECURITY DEFINER，走属主权限，不受影响。
do $$
declare
  r text;
begin
  foreach r in array array['authenticated', 'anon'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke insert, update, delete on public.location_points from %I', r);
      execute format('revoke insert, update, delete on public.daily_usage   from %I', r);
      execute format('revoke insert, update, delete on public.app_usage     from %I', r);
      execute format('revoke insert, update, delete on public.user_status   from %I', r);
    end if;
  end loop;
end $$;

drop view if exists public.visible_status;

-- ------------------------------------------------------------
-- 5. 纯查看模式（N09）
-- 备用机只当查看端，不采集不上报。
-- 这一类「本机不采集」和「不共享给对方」是两件事，分开存。
-- ------------------------------------------------------------
alter table public.settings
  add column if not exists collect_enabled boolean not null default true;

-- ------------------------------------------------------------
-- 6. 对外读状态（R01、N01、N06）
-- 身份判定用 NULL 安全写法，未配对时不可能放行。
-- 坐标在三种情况下遮蔽：暂停中、暂停结束后没有新点、手动恢复后没有新点。
-- ------------------------------------------------------------
-- 加 server_now 需要改返回类型，先 drop。老版本没有依赖它的对象。
drop function if exists public.get_status(uuid);

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
  share_battery  boolean,
  server_now     timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_partner uuid;
  v_target  uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  v_partner := public.my_partner_id();
  v_target  := coalesce(p_user_id, v_partner);

  if v_target is null then
    return;
  end if;

  -- 显式处理对象为空，不依赖三值逻辑
  if v_target <> v_uid then
    if v_partner is null or v_target <> v_partner then
      raise exception 'not_allowed';
    end if;
  end if;

  return query
  select
    p.id,
    case when us.paused_until > now()
           or not coalesce(s.share_location, true)
           or (us.paused_until is not null and us.updated_at <= us.paused_until)
           or (pr.resumed_at is not null and us.updated_at < pr.resumed_at)
         then null else us.lat end,
    case when us.paused_until > now()
           or not coalesce(s.share_location, true)
           or (us.paused_until is not null and us.updated_at <= us.paused_until)
           or (pr.resumed_at is not null and us.updated_at < pr.resumed_at)
         then null else us.lng end,
    case when us.paused_until > now()
           or not coalesce(s.share_location, true)
           or (us.paused_until is not null and us.updated_at <= us.paused_until)
           or (pr.resumed_at is not null and us.updated_at < pr.resumed_at)
         then null else us.accuracy end,
    case when us.paused_until > now()
           or not coalesce(s.share_location, true)
           or (us.paused_until is not null and us.updated_at <= us.paused_until)
           or (pr.resumed_at is not null and us.updated_at < pr.resumed_at)
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
    coalesce(s.share_battery, true),
    now()
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
-- 7. 对外读用机（N02）
-- 对象读不到 daily_usage 与 app_usage，只能走这里。
-- 暂停或关闭用机共享时返回空集。
-- ------------------------------------------------------------
create or replace function public.get_usage(
  p_user_id uuid default null,
  p_date    date default null
)
returns table (
  user_id         uuid,
  date            date,
  screen_on_ms    bigint,
  unlock_count    int,
  lock_count      int,
  first_unlock_at timestamptz,
  last_unlock_at  timestamptz,
  captured_at     timestamptz,
  apps            jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid         uuid := auth.uid();
  v_partner     uuid;
  v_target      uuid;
  v_date        date;
  v_paused      boolean;
  v_share_usage boolean;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  v_partner := public.my_partner_id();
  v_target  := coalesce(p_user_id, v_partner);
  v_date    := coalesce(p_date, (now() at time zone 'Asia/Shanghai')::date);

  if v_target is null then
    return;
  end if;

  if v_target <> v_uid then
    if v_partner is null or v_target <> v_partner then
      raise exception 'not_allowed';
    end if;

    select coalesce(us.paused_until > now(), false) into v_paused
    from public.user_status us where us.user_id = v_target;

    select coalesce(s.share_usage, true) into v_share_usage
    from public.settings s where s.user_id = v_target;

    if coalesce(v_paused, false) or not coalesce(v_share_usage, true) then
      return;
    end if;
  end if;

  return query
  select
    d.user_id, d.date, d.screen_on_ms, d.unlock_count, d.lock_count,
    d.first_unlock_at, d.last_unlock_at, d.captured_at,
    coalesce((
      select jsonb_agg(to_jsonb(x))
      from (
        select a.package_name, a.app_label, a.foreground_ms, a.launch_count
        from public.app_usage a
        where a.user_id = d.user_id and a.date = d.date
        order by a.foreground_ms desc
        limit 20
      ) x
    ), '[]'::jsonb)
  from public.daily_usage d
  where d.user_id = v_target and d.date = v_date;
end;
$$;

revoke all on function public.get_usage(uuid, date) from public;
grant execute on function public.get_usage(uuid, date) to authenticated;

-- ------------------------------------------------------------
-- 8. 上报位置（R11 成功判据）
-- 返回 received 与 inserted；客户端认 received 等于提交条数。
-- ------------------------------------------------------------
drop function if exists public.report_locations(jsonb);

create or replace function public.report_locations(p_points jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_n    int  := 0;
  v_got  int  := 0;
  v_last jsonb;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  -- 纯查看模式：本机不采集，服务端也不接收
  if not coalesce((select s.collect_enabled from public.settings s where s.user_id = v_uid), true) then
    raise exception 'collect_disabled';
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
-- 9. 上报用机快照（R03、N05）
-- 版本比较放进 UPSERT 的冲突条件里，读与写在同一语句内完成。
-- 判断被跳过时 ROW_COUNT 为 0，直接返回 -1，不碰应用明细。
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
  v_uid  uuid := auth.uid();
  v_ok   int  := 0;
  v_rows int  := 0;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  if not coalesce((select s.collect_enabled from public.settings s where s.user_id = v_uid), true) then
    raise exception 'collect_disabled';
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
        updated_at      = now()
    where du.captured_at is null or excluded.captured_at >= du.captured_at;

  get diagnostics v_ok = row_count;

  if v_ok = 0 then
    return -1;
  end if;

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

    get diagnostics v_rows = row_count;
  end if;

  return v_rows;
end;
$$;

revoke all on function public.report_usage(date, jsonb, jsonb, timestamptz) from public;
grant execute on function public.report_usage(date, jsonb, jsonb, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 10. 暂停与分项开关（R06、N06、N07）
-- 状态表与存在表同一事务；两者都走 UPSERT，新用户也不会漏。
-- 恢复时写 resumed_at，旧坐标在 get_status 里被挡住。
-- ------------------------------------------------------------
create or replace function public.set_pause(p_until timestamptz)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  -- updated_at 表示最后一点的采集时刻，暂停/恢复不能改它，
  -- 否则恢复后旧点会被当成新点放出去。
  update public.user_status
    set paused_until = p_until
    where user_id = v_uid;

  insert into public.presence as pr (user_id, resumed_at, updated_at)
  values (v_uid, case when p_until is null then now() else null end, now())
  on conflict (user_id) do update
    set resumed_at = case when p_until is null then now() else null end,
        updated_at = now();
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
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  insert into public.settings as s
    (user_id, share_location, share_usage, share_battery)
  values (v_uid, p_location, p_usage, p_battery)
  on conflict (user_id) do update
    set share_location = excluded.share_location,
        share_usage    = excluded.share_usage,
        share_battery  = excluded.share_battery;

  insert into public.presence (user_id, updated_at)
  values (v_uid, now())
  on conflict (user_id) do update set updated_at = now();
end;
$$;

revoke all on function public.set_pause(timestamptz) from public;
revoke all on function public.set_sharing(boolean, boolean, boolean) from public;
grant execute on function public.set_pause(timestamptz) to authenticated;
grant execute on function public.set_sharing(boolean, boolean, boolean) to authenticated;

-- 纯查看模式开关：只影响本机是否采集，不影响跟对方共享什么
create or replace function public.set_collect_enabled(p_enabled boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  if p_enabled is null then
    raise exception 'invalid_payload';
  end if;

  insert into public.settings as s (user_id, collect_enabled)
  values (v_uid, p_enabled)
  on conflict (user_id) do update
    set collect_enabled = excluded.collect_enabled;

  insert into public.presence (user_id, updated_at)
  values (v_uid, now())
  on conflict (user_id) do update set updated_at = now();
end;
$$;

revoke all on function public.set_collect_enabled(boolean) from public;
grant execute on function public.set_collect_enabled(boolean) to authenticated;

-- ============================================================
-- 校验（七行都应为 ok）
-- ============================================================
select
  (select count(*) from pg_tables
    where schemaname = 'public' and tablename = 'couple_members') = 1 as members_ok,
  (select count(*) from pg_tables
    where schemaname = 'public' and tablename = 'presence') = 1 as presence_ok,
  (select count(*) from pg_policies
    where schemaname = 'public'
      and policyname in ('user_status read partner',
                         'locations read own or shared partner',
                         'daily_usage read partner',
                         'app_usage read partner')) = 0 as leak_closed,
  (select count(*) from pg_policies
    where schemaname = 'public'
      and tablename in ('user_status', 'location_points', 'daily_usage', 'app_usage')
      and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')) = 0
  and (select count(*) from information_schema.role_table_grants
    where table_schema = 'public'
      and table_name in ('user_status', 'location_points', 'daily_usage', 'app_usage')
      and grantee in ('authenticated', 'anon')
      and privilege_type in ('INSERT', 'UPDATE', 'DELETE')) = 0 as write_closed,
  (select count(*) from pg_proc
    where pronamespace = 'public'::regnamespace
      and proname in ('get_status', 'get_usage', 'set_pause', 'set_sharing',
                      'set_collect_enabled')) = 5 as funcs_ok,
  (select coalesce(string_agg(tablename, ',' order by tablename), '')
    from pg_publication_tables
    where pubname = 'supabase_realtime') = 'presence' as pub_closed,
  (select count(*) from information_schema.columns
    where table_schema = 'public' and table_name = 'settings'
      and column_name = 'collect_enabled') = 1 as view_only_ok;
