-- ============================================================
-- 情侣看看 · 契约补丁 002
-- 依赖：001 已执行
-- 用法：Supabase 控制台 → SQL Editor → 新建查询 → 整段粘贴 → Run
-- 幂等：可重复执行
-- ============================================================

-- ------------------------------------------------------------
-- 1. 位置点幂等
-- 断网补传会重发同一批点，没有唯一键就会存成重复行。
-- 同一用户同一 recorded_at 只保留一行。
-- ------------------------------------------------------------
create unique index if not exists location_points_user_recorded
  on public.location_points(user_id, recorded_at);

-- ------------------------------------------------------------
-- 2. 批量上报位置
-- 一次写入多个点，并把最新点写进 user_status。
-- 补传的旧点不会覆盖新的当前状态。
-- ------------------------------------------------------------
create or replace function public.report_locations(p_points jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_n    int  := 0;
  v_last jsonb;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  if p_points is null or jsonb_typeof(p_points) <> 'array' then
    raise exception 'invalid_payload';
  end if;

  if jsonb_array_length(p_points) > 50 then
    raise exception 'batch_too_large';
  end if;

  if jsonb_array_length(p_points) = 0 then
    return 0;
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

  select e
  into v_last
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

  return v_n;
end;
$$;

-- ------------------------------------------------------------
-- 3. 用机数据上报
-- 客户端每次发当日全量快照，服务端整日替换。
-- 快照语义让重试天然幂等，不会重复累加。
-- ------------------------------------------------------------
create or replace function public.report_usage(
  p_date  date,
  p_daily jsonb,
  p_apps  jsonb
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_n   int  := 0;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  if p_date is null then
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
     first_unlock_at, last_unlock_at, updated_at)
  values (
    v_uid,
    p_date,
    coalesce((p_daily ->> 'screen_on_ms')::bigint, 0),
    coalesce((p_daily ->> 'unlock_count')::int, 0),
    coalesce((p_daily ->> 'lock_count')::int, 0),
    nullif(p_daily ->> 'first_unlock_at', '')::timestamptz,
    nullif(p_daily ->> 'last_unlock_at', '')::timestamptz,
    now()
  )
  on conflict (user_id, date) do update
    set screen_on_ms    = excluded.screen_on_ms,
        unlock_count    = excluded.unlock_count,
        lock_count      = excluded.lock_count,
        first_unlock_at = excluded.first_unlock_at,
        last_unlock_at  = excluded.last_unlock_at,
        updated_at      = now();

  delete from public.app_usage
  where user_id = v_uid and date = p_date;

  if p_apps is not null then
    insert into public.app_usage
      (user_id, date, package_name, app_label, foreground_ms, launch_count)
    select
      v_uid,
      p_date,
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

-- ------------------------------------------------------------
-- 4. 对外可见状态视图
-- 行级权限管不到列。暂停或关掉分项共享时，
-- user_status 里的坐标仍然能被对象读到。
-- 客户端只读这个视图，不直接读 user_status。
-- ------------------------------------------------------------
create or replace view public.visible_status
with (security_invoker = true)
as
select
  us.user_id,
  case when us.paused_until > now() then null else us.lat end      as lat,
  case when us.paused_until > now() then null else us.lng end      as lng,
  case when us.paused_until > now() then null else us.accuracy end as accuracy,
  case when us.paused_until > now()
         or not coalesce(s.share_location, true) then null
       else us.place_name end                                      as place_name,
  case when not coalesce(s.share_battery, true) then null
       else us.battery end                                         as battery,
  case when not coalesce(s.share_battery, true) then null
       else us.charging end                                        as charging,
  us.online,
  us.paused_until,
  us.updated_at
from public.user_status us
left join public.settings s on s.user_id = us.user_id;

-- ------------------------------------------------------------
-- 5. 授权
-- ------------------------------------------------------------
revoke all on function public.report_locations(jsonb) from public;
revoke all on function public.report_usage(date, jsonb, jsonb) from public;
grant execute on function public.report_locations(jsonb) to authenticated;
grant execute on function public.report_usage(date, jsonb, jsonb) to authenticated;

grant select on public.visible_status to authenticated;

-- ============================================================
-- 校验（跑完这段，四行都应该是 ok）
-- ============================================================
select
  (select count(*) from pg_indexes
    where schemaname = 'public' and indexname = 'location_points_user_recorded') = 1 as idx_ok,
  (select count(*) from pg_proc
    where pronamespace = 'public'::regnamespace
      and proname in ('report_locations', 'report_usage')) = 2 as funcs_ok,
  (select count(*) from pg_views
    where schemaname = 'public' and viewname = 'visible_status') = 1 as view_ok,
  (select count(*) from pg_class
    where oid = 'public.visible_status'::regclass and reloptions @> array['security_invoker=true']) = 1 as invoker_ok;
