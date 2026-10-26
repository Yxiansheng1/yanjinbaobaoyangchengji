-- ============================================================
-- 情侣看看 · 契约修正 004
-- 依赖：001、002、003 已执行
-- 幂等：可重复执行
--
-- 处理《契约 schema 审查意见 2026-10-26》C01–C08：
--   C01 p_apps 改必填，null 不再清空明细
--   C02 应用超限改用 apps_too_many，禁止拆包
--   C03 清理函数收回执行权
--   C04 只改文档：get_status.updated_at 是刷新信号时间
--   C05 settings/presence 收回写权限，profiles 改列级授权
--   C06 上报加结构、范围、非负与未来时间校验
--   C07 couples 加对称唯一索引
--   C08 只改文档：时间戳不保证 Z 后缀
--
-- 执行后需同步刷新：《情侣看看-契约-schema》v0.2、《情侣看看-规格》v1.6
-- ============================================================

-- ------------------------------------------------------------
-- 0. 时间解析（C06）
-- 统一把解析失败变成业务错误，不让 22007/22P02 漏到客户端。
-- 内部函数，不授予客户端执行权。
-- ------------------------------------------------------------
create or replace function public.to_ts(p_text text)
returns timestamptz
language plpgsql
stable
set search_path = public
as $$
begin
  if p_text is null or btrim(p_text) = '' then
    return null;
  end if;
  return p_text::timestamptz;
exception
  when others then
    raise exception 'invalid_payload';
end;
$$;

revoke all on function public.to_ts(text) from public;
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke execute on function public.to_ts(text) from %I', r);
    end if;
  end loop;
end $$;

-- ------------------------------------------------------------
-- 1. 一人只能有一段 active 关系（C07）
-- 两个独立的部分唯一索引只挡「同一列重复」，挡不住
-- 同一人分别出现在 user_a 和 user_b 的两行里。
-- 对称索引才真正约束住。
-- ------------------------------------------------------------
do $$
declare
  v_bad text;
begin
  select string_agg(format('%s 与 %s 有 %s 段 active', a, b, n), '; ')
  into v_bad
  from (
    select least(user_a, user_b) as a,
           greatest(user_a, user_b) as b,
           count(*) as n
    from public.couples
    where status = 'active'
    group by 1, 2
    having count(*) > 1
  ) t;

  if v_bad is not null then
    raise exception 'couples 存在重复的 active 配对，先修数据再跑本脚本：%', v_bad;
  end if;
end $$;

create unique index if not exists couples_pair_active
  on public.couples (least(user_a, user_b), greatest(user_a, user_b))
  where status = 'active';

-- ------------------------------------------------------------
-- 2. 位置上报加校验（C06）
-- 结构与范围全部在插入前检查，任一点不合格整批拒绝。
-- 未来时间单独报 future_timestamp，上限 now() + 10 分钟。
-- ------------------------------------------------------------
create or replace function public.report_locations(p_points jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_n       int  := 0;
  v_got     int  := 0;
  v_last    jsonb;
  v_ceiling timestamptz := now() + interval '10 minutes';
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

  -- 结构：类型不对不进入取值阶段
  if exists (
    select 1
    from jsonb_array_elements(p_points) as e
    where jsonb_typeof(e) <> 'object'
       or jsonb_typeof(e -> 'lat') is distinct from 'number'
       or jsonb_typeof(e -> 'lng') is distinct from 'number'
       or jsonb_typeof(e -> 'recorded_at') is distinct from 'string'
       or (e ? 'accuracy'   and jsonb_typeof(e -> 'accuracy')   not in ('number', 'null'))
       or (e ? 'speed'      and jsonb_typeof(e -> 'speed')      not in ('number', 'null'))
       or (e ? 'battery'    and jsonb_typeof(e -> 'battery')    not in ('number', 'null'))
       or (e ? 'charging'   and jsonb_typeof(e -> 'charging')   not in ('boolean', 'null'))
       or (e ? 'provider'   and jsonb_typeof(e -> 'provider')   not in ('string', 'null'))
       or (e ? 'place_name' and jsonb_typeof(e -> 'place_name') not in ('string', 'null'))
  ) then
    raise exception 'invalid_payload';
  end if;

  -- 范围：坐标、精度、速度、电量
  if exists (
    select 1
    from jsonb_array_elements(p_points) as e
    where (e ->> 'lat')::numeric not between -90 and 90
       or (e ->> 'lng')::numeric not between -180 and 180
       or (e ->> 'accuracy')::numeric < 0
       or (e ->> 'speed')::numeric < 0
       or (e ->> 'battery')::numeric not between 0 and 100
  ) then
    raise exception 'invalid_payload';
  end if;

  -- 采集时刻：必须有、必须能解析、不能太超前
  if exists (
    select 1
    from jsonb_array_elements(p_points) as e
    where public.to_ts(e ->> 'recorded_at') is null
  ) then
    raise exception 'invalid_payload';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_points) as e
    where public.to_ts(e ->> 'recorded_at') > v_ceiling
  ) then
    raise exception 'future_timestamp';
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
    public.to_ts(e ->> 'recorded_at')
  from jsonb_array_elements(p_points) as e
  on conflict (user_id, recorded_at) do nothing;

  get diagnostics v_n = row_count;

  select e into v_last
  from jsonb_array_elements(p_points) as e
  order by public.to_ts(e ->> 'recorded_at') desc
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
    public.to_ts(v_last ->> 'recorded_at')
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
  values (v_uid, true, public.to_ts(v_last ->> 'recorded_at'), now())
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
-- 3. 用机上报（C01、C02、C06）
-- p_apps 必填：null 一律拒绝，整日替换语义写死。
-- 超过 20 行报 apps_too_many，客户端在本地取 Top 20 后整体发送。
-- ------------------------------------------------------------
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
  v_uid     uuid := auth.uid();
  v_ok      int  := 0;
  v_rows    int  := 0;
  v_ceiling timestamptz := now() + interval '10 minutes';
  v_screen  bigint;
  v_unlock  int;
  v_lock    int;
  v_first   timestamptz;
  v_last    timestamptz;
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

  -- C01：显式数组，null 不再等同于「不动明细」
  if p_apps is null or jsonb_typeof(p_apps) <> 'array' then
    raise exception 'invalid_payload';
  end if;

  -- C02：应用是整日替换，拆包会互相覆盖，只能整体重发
  if jsonb_array_length(p_apps) > 20 then
    raise exception 'apps_too_many';
  end if;

  if p_daily is null or jsonb_typeof(p_daily) <> 'object' then
    raise exception 'invalid_payload';
  end if;

  -- 结构
  if (p_daily ? 'screen_on_ms' and jsonb_typeof(p_daily -> 'screen_on_ms') <> 'number')
     or (p_daily ? 'unlock_count' and jsonb_typeof(p_daily -> 'unlock_count') <> 'number')
     or (p_daily ? 'lock_count' and jsonb_typeof(p_daily -> 'lock_count') <> 'number')
     or (p_daily ? 'first_unlock_at' and jsonb_typeof(p_daily -> 'first_unlock_at') not in ('string', 'null'))
     or (p_daily ? 'last_unlock_at' and jsonb_typeof(p_daily -> 'last_unlock_at') not in ('string', 'null'))
  then
    raise exception 'invalid_payload';
  end if;

  v_screen := coalesce((p_daily ->> 'screen_on_ms')::bigint, 0);
  v_unlock := coalesce((p_daily ->> 'unlock_count')::int, 0);
  v_lock   := coalesce((p_daily ->> 'lock_count')::int, 0);
  v_first  := public.to_ts(p_daily ->> 'first_unlock_at');
  v_last   := public.to_ts(p_daily ->> 'last_unlock_at');

  if v_screen < 0 or v_unlock < 0 or v_lock < 0 then
    raise exception 'invalid_payload';
  end if;

  if p_captured_at > v_ceiling
     or (v_first is not null and v_first > v_ceiling)
     or (v_last is not null and v_last > v_ceiling)
  then
    raise exception 'future_timestamp';
  end if;

  -- 应用行：先结构、再范围，避免边校验边转型
  if exists (
    select 1
    from jsonb_array_elements(p_apps) as e
    where jsonb_typeof(e) <> 'object'
       or jsonb_typeof(e -> 'package_name') is distinct from 'string'
       or coalesce(e ->> 'package_name', '') = ''
       or (e ? 'app_label'     and jsonb_typeof(e -> 'app_label')     not in ('string', 'null'))
       or (e ? 'foreground_ms' and jsonb_typeof(e -> 'foreground_ms') not in ('number', 'null'))
       or (e ? 'launch_count'  and jsonb_typeof(e -> 'launch_count')  not in ('number', 'null'))
  ) then
    raise exception 'invalid_payload';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_apps) as e
    where coalesce((e ->> 'foreground_ms')::numeric, 0) < 0
       or coalesce((e ->> 'launch_count')::numeric, 0) < 0
  ) then
    raise exception 'invalid_payload';
  end if;

  insert into public.daily_usage as du
    (user_id, date, screen_on_ms, unlock_count, lock_count,
     first_unlock_at, last_unlock_at, captured_at, updated_at)
  values (
    v_uid, p_date, v_screen, v_unlock, v_lock,
    v_first, v_last, p_captured_at, now()
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

  -- 整日替换：先删后插，同一个事务内
  delete from public.app_usage where user_id = v_uid and date = p_date;

  insert into public.app_usage
    (user_id, date, package_name, app_label, foreground_ms, launch_count)
  select
    v_uid, p_date,
    e ->> 'package_name',
    coalesce(e ->> 'app_label', ''),
    coalesce((e ->> 'foreground_ms')::bigint, 0),
    coalesce((e ->> 'launch_count')::int, 0)
  from jsonb_array_elements(p_apps) as e
  on conflict (user_id, date, package_name) do update
    set app_label     = excluded.app_label,
        foreground_ms = excluded.foreground_ms,
        launch_count  = excluded.launch_count;

  get diagnostics v_rows = row_count;

  return v_rows;
end;
$$;

revoke all on function public.report_usage(date, jsonb, jsonb, timestamptz) from public;
grant execute on function public.report_usage(date, jsonb, jsonb, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 4. 清理函数只给任务角色（C03）
-- PostgreSQL 默认把 EXECUTE 授给 PUBLIC，不显式收回
-- 就等于任何登录身份、甚至 anon 都能删别人的旧位置点。
-- ------------------------------------------------------------
revoke all on function public.purge_old_locations() from public;
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke execute on function public.purge_old_locations() from %I', r);
    end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.purge_old_locations() to service_role';
  end if;
end $$;

-- ------------------------------------------------------------
-- 5. 收回越界直写（C05）
-- settings：只能走 set_sharing / set_collect_enabled，
--           否则会绕过 presence 刷新与参数校验。
-- presence：只由上报与设置函数维护，客户端不该碰 resumed_at。
-- profiles：只保留 nickname、avatar_url 两列的更新权。
-- devices：保留本人整行直写，这是唯一例外，契约里写明。
-- ------------------------------------------------------------
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke insert, update, delete on public.settings from %I', r);
      execute format('revoke insert, update, delete on public.presence from %I', r);
      execute format('revoke update, delete on public.profiles from %I', r);
    end if;
  end loop;
end $$;

grant update (nickname, avatar_url) on public.profiles to authenticated;

-- ------------------------------------------------------------
-- 6. 自检：上面几步都要在线上真正生效
-- 任何一行不是 true 都会在 SQL Editor 里报错，不会静默通过。
-- ------------------------------------------------------------
do $$
declare
  v_bad text;
begin
  select string_agg(item, '; ') into v_bad
  from (
    select 'authenticated 仍可执行 purge' as item
    where exists (select 1 from pg_roles where rolname = 'authenticated')
      and has_function_privilege('authenticated', 'public.purge_old_locations()', 'execute')
    union all
    select 'anon 仍可执行 purge'
    where exists (select 1 from pg_roles where rolname = 'anon')
      and has_function_privilege('anon', 'public.purge_old_locations()', 'execute')
    union all
    select 'authenticated 仍可直写 settings'
    where exists (select 1 from pg_roles where rolname = 'authenticated')
      and has_table_privilege('authenticated', 'public.settings', 'update')
    union all
    select 'authenticated 仍可直写 presence'
    where exists (select 1 from pg_roles where rolname = 'authenticated')
      and has_table_privilege('authenticated', 'public.presence', 'update')
    union all
    select 'authenticated 仍可改 profiles.email'
    where exists (select 1 from pg_roles where rolname = 'authenticated')
      and has_column_privilege('authenticated', 'public.profiles', 'email', 'update')
  ) t;

  if v_bad is not null then
    raise exception '004 自检失败：%', v_bad;
  end if;
end $$;
