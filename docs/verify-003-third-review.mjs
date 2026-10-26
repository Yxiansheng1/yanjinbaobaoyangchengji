// 003 加固补丁的本机验证脚本
//
// 用法（需要 Node 20.11+ 或 Bun）：
//   mkdir /tmp/verify-003 && cd /tmp/verify-003
//   bun add @electric-sql/pglite
//   bun /path/to/docs/verify-003.mjs
//
// 它从空库依次执行 001、002、003，然后按 N01–N07 与 V13/V20 逐项断言。
// 模拟 Supabase 的 auth.users、auth.uid()、authenticated 角色与表级授权；
// 不启动 Realtime，也没有多连接并发，这两项必须在线上补测。

import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const sql = (f) => fs.readFileSync(path.join(HERE, f), 'utf8');

const A = '00000000-0000-0000-0000-000000000001';
const B = '00000000-0000-0000-0000-000000000002';
const C = '00000000-0000-0000-0000-000000000003';
const D = '00000000-0000-0000-0000-000000000005';
const E = '00000000-0000-0000-0000-000000000006';

const db = new PGlite();
const checks = [];
function ok(name, pass, observed) {
  checks.push({ name, pass: !!pass, observed });
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}  ${JSON.stringify(observed)}`);
}

async function asUser(uid, fn) {
  await db.exec('begin');
  try {
    await db.query(`select set_config('request.jwt.claim.sub', $1, true)`, [uid]);
    await db.exec('set local role authenticated');
    return await fn();
  } finally {
    await db.exec('commit');
  }
}

async function err(fn) {
  try {
    await fn();
    return null;
  } catch (e) {
    return String(e.message).split('\n')[0];
  }
}

// ---------- 模拟 Supabase 环境 ----------
await db.exec(`
  create role authenticated;
  create schema auth;
  create table auth.users (
    id uuid primary key,
    email text,
    raw_user_meta_data jsonb default '{}'::jsonb
  );
  create or replace function auth.uid() returns uuid
  language sql stable as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
  $$;
  create publication supabase_realtime;
`);

await db.exec(sql('001-schema.sql'));
await db.exec(sql('002-contract.sql'));

// 模拟 Supabase：库里对象默认就把增删改查授给 authenticated，
// 003 新建的表也自动带上这些授权，所以默认权限要在跑 003 之前设好。
await db.exec(`
  grant usage on schema public to authenticated;
  grant select, insert, update, delete on all tables in schema public to authenticated;
  grant usage, select on all sequences in schema public to authenticated;
  alter default privileges in schema public
    grant select, insert, update, delete on tables to authenticated;
  alter default privileges in schema public
    grant usage, select on sequences to authenticated;
`);

const applyErr = await err(() => db.exec(sql('003-hardening.sql')));
ok('003 可在干净库执行', applyErr === null, applyErr ?? 'ok');
if (applyErr) {
  fs.writeFileSync(path.join(HERE, 'PRD与Spec三次复核-本地验证结果.json'), JSON.stringify({ checks }, null, 2));
  process.exit(1);
}

// ---------- 造数 ----------
for (const [id, email] of [[A, 'a@x'], [B, 'b@x'], [C, 'c@x'], [D, 'd@x']]) {
  await db.query(`insert into auth.users (id, email) values ($1,$2)`, [id, email]);
}

const codeA = (await asUser(A, () => db.query('select public.generate_pair_code() as code'))).rows[0].code;
const coupleId = (await asUser(B, () => db.query('select public.accept_pair_code($1) as id', [codeA]))).rows[0].id;
ok('正常配对', typeof coupleId === 'string' && codeA.length === 6, { codeLen: codeA.length });

const pointAt = new Date().toISOString();
await asUser(A, () => db.query(`select public.report_locations($1::jsonb)`, [JSON.stringify([
  { lat: 25.01, lng: 121.51, accuracy: 12.5, provider: 'gps', battery: 66, charging: true, place_name: '测试地名', recorded_at: pointAt },
])]));
const today = (await db.query(`select (now() at time zone 'Asia/Shanghai')::date::text as d`)).rows[0].d;
await asUser(A, () => db.query(`select public.report_usage($1::date,$2::jsonb,$3::jsonb,$4::timestamptz)`, [
  today,
  JSON.stringify({ screen_on_ms: 900000, unlock_count: 5, lock_count: 4 }),
  JSON.stringify([{ package_name: 'test.app', app_label: '测试', foreground_ms: 800000, launch_count: 3 }]),
  pointAt,
]));

// ---------- N01 ----------
ok('N01 未配对读 get_status', (await err(() => asUser(C, () => db.query('select * from public.get_status($1)', [A])))) === 'not_allowed', 'not_allowed');
ok('N01 未配对读 get_usage', (await err(() => asUser(C, () => db.query('select * from public.get_usage($1)', [A])))) === 'not_allowed', 'not_allowed');
ok('N01 已配对读陌生人', (await err(() => asUser(B, () => db.query('select * from public.get_status($1)', [D])))) === 'not_allowed', 'not_allowed');
ok('N01 未配对可读自己', (await asUser(C, () => db.query('select * from public.get_status()'))).rows.length === 0, 'empty ok');

// ---------- 正常可见 ----------
const bStatus = (await asUser(B, () => db.query('select * from public.get_status()'))).rows[0];
ok('正常状态可见', bStatus?.lat === 25.01 && bStatus?.battery === 66 && bStatus?.server_now != null, { lat: bStatus?.lat, battery: bStatus?.battery });
const bUsage = (await asUser(B, () => db.query('select * from public.get_usage()'))).rows;
ok('正常用机可见', bUsage.length === 1 && bUsage[0].apps?.length === 1, { rows: bUsage.length });

// ---------- N04 ----------
const forgeErr = await err(() => asUser(C, () => db.query('insert into public.couple_members (user_id, couple_id) values ($1,$2)', [C, coupleId])));
ok('N04 不能伪造成员', forgeErr !== null && /row-level security|permission denied/.test(forgeErr), forgeErr ?? 'unexpected success');
const cPartner = (await asUser(C, () => db.query('select public.my_partner_id() as p'))).rows[0].p;
ok('N04 孤儿成员不返回对象', cPartner === null, cPartner);
const aPartner = (await asUser(A, () => db.query('select public.my_partner_id() as p'))).rows[0].p;
const bPartner = (await asUser(B, () => db.query('select public.my_partner_id() as p'))).rows[0].p;
ok('N04 两侧互为对象', aPartner === B && bPartner === A, { aPartner, bPartner });

// ---------- N02 / N03 ----------
const raw = (await asUser(B, () => db.query(`
  select
    (select count(*) from public.location_points where user_id = $1)::int as loc,
    (select count(*) from public.daily_usage where user_id = $1)::int as daily,
    (select count(*) from public.app_usage where user_id = $1)::int as apps,
    (select count(*) from public.user_status where user_id = $1)::int as status
`, [A]))).rows[0];
ok('N02 对象读不到四张原表', raw.loc + raw.daily + raw.apps + raw.status === 0, raw);

// 直写被拒：客户端只能走函数，否则纯查看模式与快照版本都能绕过
const writeLoc = await err(() => asUser(A, () => db.query(
  `insert into public.location_points (user_id, lat, lng, recorded_at) values ($1, 1, 1, now())`, [A])));
const writeDaily = await err(() => asUser(A, () => db.query(
  `insert into public.daily_usage (user_id, date, screen_on_ms) values ($1, $2, 1)`, [A, today])));
const writeApp = await err(() => asUser(A, () => db.query(
  `insert into public.app_usage (user_id, date, package_name) values ($1, $2, 'x')`, [A, today])));
const writeStatus = await err(() => asUser(A, () => db.query(
  `update public.user_status set lat = 1 where user_id = $1`, [A])));
ok('R01 直写四张数据表被拒',
  [writeLoc, writeDaily, writeApp, writeStatus].every((e) => e && /row-level security|permission denied/.test(e)),
  { writeLoc, writeDaily, writeApp, writeStatus });
const selfLoc = (await asUser(A, () => db.query(
  'select count(*)::int as n from public.location_points where user_id = $1', [A]))).rows[0].n;
ok('R01 自己的行仍可读', selfLoc >= 1, { selfLoc });

await asUser(A, () => db.query('select public.set_sharing(true,true,false)'));
const noBattery = (await asUser(B, () => db.query('select lat, battery, charging from public.get_status()'))).rows[0];
ok('N03 关电量只遮电量', noBattery.lat === 25.01 && noBattery.battery === null && noBattery.charging === null, noBattery);

await asUser(A, () => db.query(`select public.set_pause(now() + interval '1 hour')`));
const paused = (await asUser(B, () => db.query('select lat, lng, accuracy, place_name, battery, charging, paused_until from public.get_status()'))).rows[0];
ok('N02 暂停遮住状态', paused.lat === null && paused.battery === null && paused.paused_until != null, paused);
const pausedUsage = (await asUser(B, () => db.query('select * from public.get_usage()'))).rows;
ok('N02 暂停用机为空', pausedUsage.length === 0, { rows: pausedUsage.length });

// ---------- N06 ----------
await asUser(A, () => db.query('select public.set_pause(null)'));
const afterResume = (await asUser(B, () => db.query('select lat, lng from public.get_status()'))).rows[0];
ok('N06 手动恢复不返旧点', afterResume.lat === null, afterResume);

const fresh1 = new Date().toISOString();
await asUser(A, () => db.query('select public.report_locations($1::jsonb)', [JSON.stringify([
  { lat: 25.02, lng: 121.52, accuracy: 10, provider: 'gps', battery: 65, charging: false, recorded_at: fresh1 },
])]));
const afterNew = (await asUser(B, () => db.query('select lat, lng from public.get_status()'))).rows[0];
ok('N06 新点到达即可见', afterNew.lat === 25.02, afterNew);

// 补传：比当前点更旧的点不能把状态回退
const backlogAt = new Date(Date.now() - 10 * 60 * 1000).toISOString();
await asUser(A, () => db.query('select public.report_locations($1::jsonb)', [JSON.stringify([
  { lat: 24.99, lng: 121.49, accuracy: 20, provider: 'gps', battery: 63, charging: false, recorded_at: backlogAt },
])]));
const afterBacklog = (await asUser(B, () => db.query('select lat, lng from public.get_status()'))).rows[0];
ok('N06 补传更旧的点不回退状态', afterBacklog.lat === 25.02, afterBacklog);

// 暂停期间采集、恢复后才补传：入库，但恢复后仍不可见
await asUser(A, () => db.query(`select public.set_pause(now() + interval '1 hour')`));
const pausedPointAt = new Date(Date.now() - 1000).toISOString();
await asUser(A, () => db.query('select public.report_locations($1::jsonb)', [JSON.stringify([
  { lat: 25.05, lng: 121.55, accuracy: 15, provider: 'gps', battery: 62, charging: false, recorded_at: pausedPointAt },
])]));
await asUser(A, () => db.query('select public.set_pause(null)'));
const afterPausedBacklog = (await asUser(B, () => db.query('select lat, lng from public.get_status()'))).rows[0];
ok('N06 恢复后补传的旧点仍遮蔽', afterPausedBacklog.lat === null, afterPausedBacklog);

await asUser(A, () => db.query(`select public.set_pause(now() + interval '1 second')`));
await new Promise((r) => setTimeout(r, 1600));
const afterExpiry = (await asUser(B, () => db.query('select lat from public.get_status()'))).rows[0];
ok('N06 定时到期不返旧点', afterExpiry.lat === null, afterExpiry);
const fresh2 = new Date().toISOString();
await asUser(A, () => db.query('select public.report_locations($1::jsonb)', [JSON.stringify([
  { lat: 25.03, lng: 121.53, accuracy: 9, provider: 'gps', battery: 64, charging: false, recorded_at: fresh2 },
])]));
const afterExpiryNew = (await asUser(B, () => db.query('select lat from public.get_status()'))).rows[0];
ok('N06 到期后新点可见', afterExpiryNew.lat === 25.03, afterExpiryNew);

// ---------- N05 ----------
const day = '2026-10-26';
const snap = (v, t, pkg) => asUser(A, () => db.query(`select public.report_usage($1::date,$2::jsonb,$3::jsonb,$4::timestamptz) as r`, [
  day, JSON.stringify({ screen_on_ms: v }), JSON.stringify([{ package_name: pkg, foreground_ms: v }]), t,
]));
const r1 = (await snap(900000, '2026-10-26T10:15:00Z', 'p1')).rows[0].r;
const r2 = (await snap(100, '2026-10-26T10:00:00Z', 'p2')).rows[0].r;
const r3 = (await snap(900000, '2026-10-26T10:15:00Z', 'p1')).rows[0].r;
const stored = (await db.query(`select screen_on_ms, captured_at from public.daily_usage where user_id=$1 and date=$2`, [A, day])).rows[0];
const appRows = (await db.query(`select package_name from public.app_usage where user_id=$1 and date=$2 order by 1`, [A, day])).rows.map((x) => x.package_name);
ok('N05 旧快照拒绝、同版本幂等', r1 === 1 && r2 === -1 && r3 === 1 && stored.screen_on_ms === 900000 && appRows.join(',') === 'p1', { r1, r2, r3, stored, appRows });

// ---------- N07 ----------
const pub = (await db.query(`select tablename from pg_publication_tables where pubname='supabase_realtime' order by 1`)).rows.map((x) => x.tablename);
ok('N07 只发布 presence', pub.length === 1 && pub[0] === 'presence', pub);
const cPresence = (await asUser(C, () => db.query('select count(*)::int as n from public.presence where user_id = $1', [A]))).rows[0].n;
const bPresence = (await asUser(B, () => db.query('select count(*)::int as n from public.presence where user_id = $1', [A]))).rows[0].n;
ok('N07 未配对读不到对方 presence，对象读得到', cPresence === 0 && bPresence === 1, { cPresence, bPresence });
await db.query(`insert into auth.users (id, email) values ($1,'e@x')`, [E]);
const ePresence = (await db.query(`select count(*)::int as n from public.presence where user_id=$1`, [E])).rows[0].n;
await asUser(E, () => db.query(`select public.set_pause(now() + interval '1 hour')`));
const eTouched = (await db.query(`select updated_at > now() - interval '1 minute' as t from public.presence where user_id=$1`, [E])).rows[0].t;
ok('N07 新用户有 presence 且能发信号', ePresence === 1 && eTouched === true, { ePresence, eTouched });

// ---------- V20 纯查看 ----------
await asUser(A, () => db.query('select public.set_collect_enabled(false)'));
const locOff = await err(() => asUser(A, () => db.query('select public.report_locations($1::jsonb)', [JSON.stringify([
  { lat: 1, lng: 1, recorded_at: new Date().toISOString() },
])])));
const usageOff = await err(() => asUser(A, () => db.query(`select public.report_usage($1::date,$2::jsonb,null,now())`, [today, JSON.stringify({ screen_on_ms: 1 })])));
ok('V20 纯查看拒绝上报', locOff === 'collect_disabled' && usageOff === 'collect_disabled', { locOff, usageOff });
await asUser(A, () => db.query('select public.set_collect_enabled(true)'));

// ---------- V13 同码二次使用 ----------
const codeD = (await asUser(D, () => db.query('select public.generate_pair_code() as code'))).rows[0].code;
const firstAccept = await asUser(E, () => db.query('select public.accept_pair_code($1) as id', [codeD]));
const secondAccept = await err(() => asUser(C, () => db.query('select public.accept_pair_code($1) as id', [codeD])));
ok('V13 同码只成功一次', !!firstAccept.rows[0].id && secondAccept === 'invalid_code', { secondAccept });

// ---------- 签名 ----------
const sigs = (await db.query(`
  select p.proname, pg_get_function_result(p.oid) as ret
  from pg_proc p where p.pronamespace='public'::regnamespace
    and p.proname in ('get_status','get_usage','report_locations','report_usage','set_collect_enabled')
`)).rows;
const getStatus = sigs.find((x) => x.proname === 'get_status')?.ret ?? '';
ok('函数签名与规格一致', sigs.find((x) => x.proname === 'report_locations')?.ret === 'jsonb' && getStatus.includes('server_now'), sigs.map((x) => `${x.proname}:${x.ret.split('(')[0]}`));

// ---------- 003 自带校验 ----------
const rawSql = sql('003-hardening.sql');
const checkRow = (await db.query(rawSql.slice(rawSql.indexOf('-- 校验（')))).rows[0];
ok('003 自带校验七行全 ok', Object.values(checkRow).every((v) => v === true), checkRow);

// Independent boundary checks, added without changing project SQL.
await asUser(A, () => db.query('select public.set_sharing(true,true,true)'));
const beforeView = (await asUser(B, () => db.query('select lat,lng,battery from public.get_status()'))).rows[0];
await asUser(A, () => db.query('select public.set_collect_enabled(false)'));
const viewStatus = (await asUser(B, () => db.query('select lat,lng,battery from public.get_status()'))).rows[0];
const viewUsage = (await asUser(B, () => db.query('select * from public.get_usage($1,$2)',[A,day]))).rows;
ok('EX1 V20 单独关闭采集后旧数据不再共享', viewStatus.lat === null && viewStatus.battery === null && viewUsage.length === 0, {beforeView,viewStatus,usageRows:viewUsage.length});
await asUser(A, () => db.query('select public.set_sharing(false,false,false)'));
const closedStatus = (await asUser(B, () => db.query('select lat,lng,battery from public.get_status()'))).rows[0];
const closedUsage = (await asUser(B, () => db.query('select * from public.get_usage($1,$2)',[A,day]))).rows;
ok('EX2 关闭采集并关闭三类共享后不可读', closedStatus.lat === null && closedStatus.battery === null && closedUsage.length === 0, {closedStatus,usageRows:closedUsage.length});
// Inject an actual forged row as the DB owner to test the helper's defense in depth.
await db.query('insert into public.couple_members(user_id,couple_id) values ($1,$2)',[C,coupleId]);
const injectedPartner = (await asUser(C, () => db.query('select public.my_partner_id() as p'))).rows[0].p;
ok('EX3 实际注入伪造成员后不返回对象',injectedPartner === null, injectedPartner);
const dirtyApply = await err(() => db.exec(sql('003-hardening.sql')));
ok('EX4 脏成员数据使迁移明确失败',dirtyApply !== null && dirtyApply.includes('成员表与 active 关系不一致'),dirtyApply);
await db.query('delete from public.couple_members where user_id=$1',[C]);
const rerun = await err(() => db.exec(sql('003-hardening.sql')));
ok('EX5 干净已有数据上重复迁移成功',rerun === null,rerun ?? 'ok');
await asUser(A, () => db.query('select public.set_collect_enabled(true)'));
await asUser(A, () => db.query('select public.set_sharing(true,true,true)'));
await asUser(A, () => db.query("select public.set_pause(now()+interval '1 hour')"));
await new Promise(r=>setTimeout(r,30));
const actuallyPausedTime = new Date().toISOString();
await new Promise(r=>setTimeout(r,30));
await asUser(A, () => db.query('select public.set_pause(null)'));
await asUser(A, () => db.query('select public.report_locations($1::jsonb)',[JSON.stringify([{lat:27,lng:123,recorded_at:actuallyPausedTime}])]));
const delayedPausedPoint = (await asUser(B, () => db.query('select lat,lng from public.get_status()'))).rows[0];
ok('EX6 真正在暂停期间取点并在恢复后补传仍遮蔽',delayedPausedPoint.lat===null,delayedPausedPoint);
const actualSelf = (await asUser(C, () => db.query('select user_id from public.get_status($1)',[C]))).rows;
ok('EX7 未配对账号显式读自己可用',actualSelf.length===1&&actualSelf[0].user_id===C,actualSelf);
// ---------- 汇总 ----------
const failed = checks.filter((x) => !x.pass);
fs.writeFileSync(path.join(HERE, 'PRD与Spec三次复核-本地验证结果.json'), JSON.stringify({
  environment: 'PGlite 0.5.11，干净库 001→002→003；模拟 auth.uid/authenticated/表级授权；无 Realtime、无多连接',
  passed: checks.length - failed.length,
  failed: failed.length,
  checks,
}, null, 2));

console.log(`\n${checks.length - failed.length}/${checks.length} passed`);
process.exit(failed.length === 0 ? 0 : 1);



