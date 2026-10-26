-- ============================================================
-- 情侣看看 · 契约修正 005
-- 依赖：001、002、003、004 已执行
-- 幂等：可重复执行
--
-- 处理《契约 schema 第二轮复核 2026-10-26》D01、D03：
--   D01 小数、整数溢出、重复包名仍漏原生错误
--   D03 用机上报不发订阅刷新信号
--
-- 只改文档、不需要动 SQL 的：D02（RPC 响应形状）、
--   D04（对称索引的作用被夸大）、D05（时间格式）、
--   D06（权限摘要）。这四条落在契约 v0.3 与规格 v1.7。
--
-- 对 004 的一处更正（不修改 004 文件，保持线上文件可校验）：
--   004 第 45 行注释写「对称索引才真正约束住一人一段」，
--   这句过强。couples_pair_active 只挡同一对人正反两向重复；
--   不同组合（已有 A–B，再插 C–A）它挡不住。
--   一人一段由三件事共同保证：couple_members.user_id 主键、
--   受控配对函数、锁内重查。管理员直连插入不在保证范围内。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 位置上报：补小数与浮点溢出校验（D01）
-- battery 必须是整数；accuracy、speed 必须在可存储且合理的范围内。
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

  -- 范围：坐标；精度与速度上限 1e7（超过这个数已无物理意义，也避开 real 溢出）
  if exists (
    select 1
    from jsonb_array_elements(p_points) as e
    where (e ->> 'lat')::numeric not between -90 and 90
       or (e ->> 'lng')::numeric not between -180 and 180
       or (e ->> 'accuracy')::numeric < 0
       or (e ->> 'accuracy')::numeric > 10000000
       or (e ->> 'speed')::numeric < 0
       or (e ->> 'speed')::numeric > 10000000
       or (e ->> 'battery')::numeric < 0
       or (e ->> 'battery')::numeric > 100
  ) then
    raise exception 'invalid_payload';
  end if;

  -- D01：battery 是 smallint，小数必须拒绝，不能让 22P02 漏出去
  if exists (
    select 1
    from jsonb_array_elements(p_points) as e
    where (e ->> 'battery')::numeric <> trunc((e ->> 'battery')::numeric)
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
-- 2. 用机上报：补整数性与存储范围校验（D01），
--    并在写入成功后推进 presence 刷新信号（D03）。
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
  v_screen  numeric;
  v_unlock  numeric;
  v_lock    numeric;
  v_first   timestamptz;
  v_last    timestamptz;
  v_app     jsonb;
  v_fg      numeric;
  v_launch  numeric;
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

  if (p_daily ? 'screen_on_ms' and jsonb_typeof(p_daily -> 'screen_on_ms') <> 'number')
     or (p_daily ? 'unlock_count' and jsonb_typeof(p_daily -> 'unlock_count') <> 'number')
     or (p_daily ? 'lock_count' and jsonb_typeof(p_daily -> 'lock_count') <> 'number')
     or (p_daily ? 'first_unlock_at' and jsonb_typeof(p_daily -> 'first_unlock_at') not in ('string', 'null'))
     or (p_daily ? 'last_unlock_at' and jsonb_typeof(p_daily -> 'last_unlock_at') not in ('string', 'null'))
  then
    raise exception 'invalid_payload';
  end if;

  v_screen := coalesce((p_daily ->> 'screen_on_ms')::numeric, 0);
  v_unlock := coalesce((p_daily ->> 'unlock_count')::numeric, 0);
  v_lock   := coalesce((p_daily ->> 'lock_count')::numeric, 0);
  v_first  := public.to_ts(p_daily ->> 'first_unlock_at');
  v_last   := public.to_ts(p_daily ->> 'last_unlock_at');

  -- D01：整数列先验整数性与类型容量，再转型
  if v_screen < 0 or v_screen <> trunc(v_screen) or v_screen > 9223372036854775807 then
    raise exception 'invalid_payload';
  end if;
  if v_unlock < 0 or v_unlock <> trunc(v_unlock) or v_unlock > 2147483647 then
    raise exception 'invalid_payload';
  end if;
  if v_lock < 0 or v_lock <> trunc(v_lock) or v_lock > 2147483647 then
    raise exception 'invalid_payload';
  end if;

  if p_captured_at > v_ceiling
     or (v_first is not null and v_first > v_ceiling)
     or (v_last is not null and v_last > v_ceiling)
  then
    raise exception 'future_timestamp';
  end if;

  -- 应用行：结构
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

  -- D01：同一批里包名不能重复。
  -- 出现重复时 ON CONFLICT DO UPDATE 会报 21000「不能二次影响同一行」，
  -- 那是实现细节泄漏，客户端认不出来。
  if exists (
    select 1
    from (
      select e ->> 'package_name' as pk
      from jsonb_array_elements(p_apps) as e
      group by 1
      having count(*) > 1
    ) d
  ) then
    raise exception 'invalid_payload';
  end if;

  -- 应用行：整数性、非负与容量
  for v_app in select e from jsonb_array_elements(p_apps) as e loop
    v_fg     := coalesce((v_app ->> 'foreground_ms')::numeric, 0);
    v_launch := coalesce((v_app ->> 'launch_count')::numeric, 0);

    if v_fg < 0 or v_fg <> trunc(v_fg) or v_fg > 9223372036854775807 then
      raise exception 'invalid_payload';
    end if;
    if v_launch < 0 or v_launch <> trunc(v_launch) or v_launch > 2147483647 then
      raise exception 'invalid_payload';
    end if;
  end loop;

  insert into public.daily_usage as du
    (user_id, date, screen_on_ms, unlock_count, lock_count,
     first_unlock_at, last_unlock_at, captured_at, updated_at)
  values (
    v_uid, p_date,
    v_screen::bigint, v_unlock::int, v_lock::int,
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

  -- D03：用机快照本身也要产生刷新信号。
  -- 只推进 updated_at，不动 last_report_at——那一列只表示位置采集时刻。
  insert into public.presence as pr (user_id, updated_at)
  values (v_uid, now())
  on conflict (user_id) do update
    set updated_at = now();

  return v_rows;
end;
$$;

revoke all on function public.report_usage(date, jsonb, jsonb, timestamptz) from public;
grant execute on function public.report_usage(date, jsonb, jsonb, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 3. 自检
-- 函数体里必须已经带上本次新增的判断，防止线上跑的是旧定义。
-- ------------------------------------------------------------
do $$
declare
  v_bad text;
begin
  select string_agg(item, '; ') into v_bad
  from (
    select 'report_usage 没有 presence 刷新' as item
    where position('insert into public.presence' in
                   pg_get_functiondef('public.report_usage(date,jsonb,jsonb,timestamptz)'::regprocedure)) = 0
    union all
    select 'report_usage 没有整数性校验'
    where position('trunc(' in
                   pg_get_functiondef('public.report_usage(date,jsonb,jsonb,timestamptz)'::regprocedure)) = 0
    union all
    select 'report_locations 没有电量整数性校验'
    where position('trunc(' in
                   pg_get_functiondef('public.report_locations(jsonb)'::regprocedure)) = 0
  ) t;

  if v_bad is not null then
    raise exception '005 自检失败：%', v_bad;
  end if;
end $$;
