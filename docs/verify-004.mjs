// 004 契约修正 · 本地验证
// 环境：PGlite 0.5.11，模拟 Auth、authenticated/anon、003 之前的普通表授权
// 覆盖：契约 schema 审查 C01–C08
// 用法：把 001/002/003/004 与本文件放同一目录，装好 @electric-sql/pglite 后 node 跑

import { PGlite } from '@electric-sql/pglite';
import { readFile, writeFile } from 'node:fs/promises';

const db = new PGlite();
const results = [];
const A = '00000000-0000-0000-0000-000000000001';
const B = '00000000-0000-0000-0000-000000000002';

async function check(name, expect, fn) {
  let passed = false, detail;
  try {
    const got = await fn();
    detail = got;
    passed = typeof expect === 'function' ? expect(got) : expect === got;
  } catch (e) {
    detail = { code: e.code, message: e.message };
    passed = typeof expect === 'function' ? expect(null, e) : false;
  }
  results.push({ name, passed, detail });
  console.log(`${passed ? 'PASS' : 'FAIL'}  ${name}  ${JSON.stringify(detail)}`);
}

async function user(id, fn, role = 'authenticated') {
  await db.exec('begin');
  try {
    await db.query("select set_config('request.jwt.claim.sub', $1, true)", [id ?? '']);
    await db.exec(`set local role ${role}`);
    const r = await fn();
    await db.exec('commit');
    return r;
  } catch (e) {
    await db.exec('rollback');
    throw e;
  }
}
const q = async (sql, params = []) => (await db.query(sql, params)).rows;

const usage = (date, apps, time, daily = { screen_on_ms: 10000 }) =>
  user(A, () => q('select public.report_usage($1,$2::jsonb,$3::jsonb,$4) as result',
    [date, JSON.stringify(daily), apps === null ? null : JSON.stringify(apps), time]));

const loc = (points) =>
  user(A, () => q('select public.report_locations($1::jsonb) as result', [JSON.stringify(points)]));

const errIs = (code) => (got, e) => !!e && (e.message === code || e.code === code);

// ---------- 环境 ----------
await db.exec(`
  create role authenticated;
  create role anon;
  create schema auth;
  create table auth.users(id uuid primary key, email text, raw_user_meta_data jsonb default '{}');
  create function auth.uid() returns uuid language sql stable
    as $$select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid$$;
  create publication supabase_realtime;
  grant usage on schema public, auth to authenticated, anon;
`);
for (const f of ['001-schema.sql', '002-contract.sql']) {
  await db.exec(await readFile(new URL(f, import.meta.url), 'utf8'));
}
// 模拟 Supabase 默认表授权，让 003 的收回有东西可收
await db.exec(`
  grant select, insert, update, delete on all tables in schema public to authenticated;
  grant usage, select on all sequences in schema public to authenticated;
  alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;
`);
await db.exec(await readFile(new URL('003-hardening.sql', import.meta.url), 'utf8'));
for (const id of [A, B]) await db.query('insert into auth.users(id,email) values ($1,$2)', [id, `${id.slice(-1)}@example.test`]);
const [{ code }] = await user(A, () => q('select generate_pair_code() as code'));
await user(B, () => q('select accept_pair_code($1)', [code]));

// ---------- 004 ----------
await db.exec(await readFile(new URL('004-contract-fix.sql', import.meta.url), 'utf8'));

// ---------- C01 p_apps 必填 ----------
await usage('2001-01-01', [{ package_name: 'original.app', foreground_ms: 1000 }], '2001-01-01T10:00:00Z');
await check('C01 null 应用列表被拒', errIs('invalid_payload'), () => usage('2001-01-01', null, '2001-01-01T10:01:00Z'));
await check('C01 拒绝后明细仍在', (rows) => rows.length === 1, () =>
  q('select package_name from app_usage where user_id=$1 and date=$2', [A, '2001-01-01']));
await check('C01 空数组仍然清空', (rows) => rows.length === 0, async () => {
  await usage('2001-01-01', [], '2001-01-01T10:02:00Z');
  return q('select package_name from app_usage where user_id=$1 and date=$2', [A, '2001-01-01']);
});

// ---------- C02 应用超限 ----------
const apps21 = Array.from({ length: 21 }, (_, i) => ({ package_name: `app.${i}`, foreground_ms: 100000 - i }));
await check('C02 21 条报 apps_too_many', errIs('apps_too_many'), () => usage('2001-01-02', apps21, '2001-01-02T10:00:00Z'));
await check('C02 被拒后当天没有半截快照', (r) => r[0].result === 0, () =>
  q('select count(*)::int as result from app_usage where user_id=$1 and date=$2', [A, '2001-01-02']));
await check('C02 整体 20 条正常写入', (r) => r[0].result === 20, async () => {
  await usage('2001-01-02', apps21.slice(0, 20), '2001-01-02T10:00:00Z');
  return q('select count(*)::int as result from app_usage where user_id=$1 and date=$2', [A, '2001-01-02']);
});

// ---------- C06 用机数值 ----------
await check('C06 负数用机被拒', errIs('invalid_payload'), () =>
  usage('2001-01-03', [], '2001-01-03T10:00:00Z', { screen_on_ms: -100, unlock_count: -2 }));
await check('C06 未来快照被拒', errIs('future_timestamp'), () => usage('2001-01-04', [], '2099-01-01T00:00:00Z'));
await check('C06 未来快照不再毒化版本', (r) => r[0].result >= 0, () =>
  usage('2001-01-04', [], '2001-01-04T10:00:00Z'));

// ---------- C06 位置校验 ----------
const now = () => new Date().toISOString();
await check('C06 缺 lng 报 invalid_payload', errIs('invalid_payload'), () => loc([{ lat: 25, recorded_at: now() }]));
await check('C06 lat 字符串报 invalid_payload', errIs('invalid_payload'), () => loc([{ lat: 'bad', lng: 121, recorded_at: now() }]));
await check('C06 坐标越界被拒', errIs('invalid_payload'), () => loc([{ lat: 999, lng: 999, recorded_at: now() }]));
await check('C06 电量越界被拒', errIs('invalid_payload'), () => loc([{ lat: 25, lng: 121, battery: 150, recorded_at: now() }]));
await check('C06 负精度被拒', errIs('invalid_payload'), () => loc([{ lat: 25, lng: 121, accuracy: -5, recorded_at: now() }]));
await check('C06 未来位置点被拒', errIs('future_timestamp'), () => loc([{ lat: 25, lng: 121, recorded_at: '2099-01-01T00:00:00Z' }]));
await check('C06 合法点仍可写入', (r) => r[0].result.inserted === 1, () => loc([{ lat: 25, lng: 121, battery: 66, accuracy: 12.5, recorded_at: now() }]));

// ---------- C05 直写收回 ----------
await check('C05 settings 直写被拒', errIs('42501'), () =>
  user(A, () => q('update settings set share_battery=true where user_id=$1 returning share_battery', [A])));
await check('C05 presence 直写被拒', errIs('42501'), () =>
  user(A, () => q("update presence set resumed_at='2000-01-01T00:00:00Z' where user_id=$1 returning resumed_at", [A])));
await check('C05 profiles 昵称仍可改', (r) => r.length === 1, () =>
  user(A, () => q("update profiles set nickname='小可' where id=$1 returning nickname", [A])));
await check('C05 profiles 邮箱不可改', errIs('42501'), () =>
  user(A, () => q("update profiles set email='x@example.test' where id=$1 returning email", [A])));

// ---------- C03 清理函数 ----------
await check('C03 authenticated 收回执行权', (r) => r[0].v === false, () =>
  q("select has_function_privilege('authenticated','public.purge_old_locations()','execute') as v"));
await check('C03 anon 收回执行权', (r) => r[0].v === false, () =>
  q("select has_function_privilege('anon','public.purge_old_locations()','execute') as v"));
await check('C03 内部时间函数也不外放', (r) => r[0].v === false, () =>
  q("select has_function_privilege('authenticated','public.to_ts(text)','execute') as v"));

// ---------- C07 对称唯一 ----------
await check('C07 同一对反向插入被拒', errIs('23505'), () =>
  db.query('insert into couples(user_a,user_b) values ($1,$2)', [B, A]));

// ---------- 回归：原 003 行为未被破坏 ----------
await check('回归 get_status 仍返回对象行', (rows) => rows.length === 1 && rows[0].user_id === A, async () => {
  await user(A, () => q('select set_sharing(true,true,true)'));
  return user(B, () => q('select user_id, last_report_at, updated_at from get_status()'));
});

const passed = results.filter((r) => r.passed).length;
console.log(`\n${passed}/${results.length} passed`);
await writeFile(new URL('004-验证结果.json', import.meta.url), JSON.stringify({ environment: 'PGlite 0.5.11', passed, total: results.length, results }, null, 2));
await db.close();
