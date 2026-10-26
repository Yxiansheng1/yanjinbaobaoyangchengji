// 005 契约修正 · 本地验证
// 覆盖第二轮复核 D01（小数、整数溢出、重复包名）与 D03（用机刷新信号）
// 环境：PGlite 0.5.11，模拟 Auth、authenticated/anon、003 之前的普通表授权
// 用法：把 001–005 与本文件放同一目录，装好 @electric-sql/pglite 后 node 跑

import { PGlite } from '@electric-sql/pglite';
import { readFile, writeFile } from 'node:fs/promises';

const db = new PGlite();
const results = [];
const A = '00000000-0000-0000-0000-000000000001';
const B = '00000000-0000-0000-0000-000000000002';

async function check(name, expect, fn) {
  if (typeof fn !== 'function') throw new Error('check() 需要三个参数：name, expect, fn');
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
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const errIs = (code) => (got, e) => !!e && (e.message === code || e.code === code);

const usage = (date, apps, time, daily = { screen_on_ms: 10000 }) =>
  user(A, () => q('select public.report_usage($1,$2::jsonb,$3::jsonb,$4) as result',
    [date, JSON.stringify(daily), apps === null ? null : JSON.stringify(apps), time]));
const loc = (points) =>
  user(A, () => q('select public.report_locations($1::jsonb) as result', [JSON.stringify(points)]));
const now = () => new Date().toISOString();

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
await db.exec(`
  grant select, insert, update, delete on all tables in schema public to authenticated;
  grant usage, select on all sequences in schema public to authenticated;
  alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;
`);
for (const f of ['003-hardening.sql', '004-contract-fix.sql', '005-contract-fix2.sql']) {
  await db.exec(await readFile(new URL(f, import.meta.url), 'utf8'));
}
for (const id of [A, B]) await db.query('insert into auth.users(id,email) values ($1,$2)', [id, `${id.slice(-1)}@example.test`]);
const [{ code }] = await user(A, () => q('select generate_pair_code() as code'));
await user(B, () => q('select accept_pair_code($1)', [code]));

// ---------- D01 小数与溢出 ----------
await check('D01 battery 小数被拒', errIs('invalid_payload'), () =>
  loc([{ lat: 25, lng: 121, battery: 66.5, recorded_at: now() }]));
await check('D01 用机小数计数被拒', errIs('invalid_payload'), () =>
  usage('2001-02-01', [], '2001-02-01T10:00:00Z', { unlock_count: 1.5 }));
await check('D01 int 溢出被拒', errIs('invalid_payload'), () =>
  usage('2001-02-02', [], '2001-02-02T10:00:00Z', { unlock_count: 2147483648 }));
await check('D01 real 溢出被拒', errIs('invalid_payload'), () =>
  loc([{ lat: 25, lng: 121, accuracy: 1e40, recorded_at: now() }]));
await check('D01 重复包名被拒', errIs('invalid_payload'), () =>
  usage('2001-02-03', [
    { package_name: 'dup.app', foreground_ms: 1000 },
    { package_name: 'dup.app', foreground_ms: 2000 }
  ], '2001-02-03T10:00:00Z'));
await check('D01 重复包名整批回滚', (r) => r.daily === 0 && r.apps === 0, async () => {
  const daily = await q('select count(*)::int as n from daily_usage where user_id=$1 and date=$2', [A, '2001-02-03']);
  const apps = await q('select count(*)::int as n from app_usage where user_id=$1 and date=$2', [A, '2001-02-03']);
  return { daily: daily[0].n, apps: apps[0].n };
});
await check('D01 用机大整数显示时长仍可接受', (r) => r[0].result === 0, () =>
  usage('2001-02-04', [], '2001-02-04T10:00:00Z', { screen_on_ms: 86400000 }));
await check('D01 边界值仍合法', (r) => r[0].result.inserted === 1, () =>
  loc([{ lat: -90, lng: 180, battery: 100, accuracy: 0, speed: 0, recorded_at: now() }]));

// ---------- D03 用机刷新信号 ----------
const presenceAt = async () =>
  (await q('select updated_at from presence where user_id=$1', [A]))[0].updated_at;
const presenceRaw = async () =>
  (await q("select updated_at::text as t, last_report_at::text as l from presence where user_id=$1", [A]))[0];

await sleep(50);
const beforeUsage = await presenceRaw();
await usage('2001-02-05', [{ package_name: 'com.tencent.mm', foreground_ms: 1000 }], '2001-02-05T10:00:00Z');
const afterUsage = await presenceRaw();

const d03Pass = afterUsage.t > beforeUsage.t;
results.push({ name: 'D03 用机上报推进 presence.updated_at', passed: d03Pass, detail: { before: beforeUsage.t, after: afterUsage.t } });
console.log(`${d03Pass ? 'PASS' : 'FAIL'}  D03 用机上报推进 presence.updated_at  ${JSON.stringify({ before: beforeUsage.t, after: afterUsage.t })}`);

const d03Last = afterUsage.l === beforeUsage.l;
results.push({ name: 'D03 用机上报不改 last_report_at', passed: d03Last, detail: { before: beforeUsage.l, after: afterUsage.l } });
console.log(`${d03Last ? 'PASS' : 'FAIL'}  D03 用机上报不改 last_report_at  ${JSON.stringify({ before: beforeUsage.l, after: afterUsage.l })}`);

// 旧快照被丢弃时不推进
await usage('2001-02-05', [{ package_name: 'com.tencent.mm', foreground_ms: 1000 }], '2001-02-05T11:00:00Z');
const beforeOld = await presenceRaw();
await sleep(50);
await check('D03 旧快照返回 -1', (r) => r[0].result === -1, () =>
  usage('2001-02-05', [{ package_name: 'com.tencent.mm', foreground_ms: 1000 }], '2001-02-05T09:00:00Z'));
const afterOld = await presenceRaw();
const d03Old = afterOld.t === beforeOld.t;
results.push({ name: 'D03 丢弃的旧快照不推进更新信号', passed: d03Old, detail: { before: beforeOld.t, after: afterOld.t } });
console.log(`${d03Old ? 'PASS' : 'FAIL'}  D03 丢弃的旧快照不推进更新信号  ${JSON.stringify({ before: beforeOld.t, after: afterOld.t })}`);

// ---------- 回归：004 的结论没被打破 ----------
await check('回归 p_apps 传 null 仍被拒', errIs('invalid_payload'), () => usage('2001-02-06', null, '2001-02-06T10:00:00Z'));
await check('回归 21 条应用仍报 apps_too_many', errIs('apps_too_many'), () =>
  usage('2001-02-07', Array.from({ length: 21 }, (_, i) => ({ package_name: `a.${i}` })), '2001-02-07T10:00:00Z'));
await check('回归 未来快照仍被拒', errIs('future_timestamp'), () => usage('2001-02-08', [], '2099-01-01T00:00:00Z'));
await check('回归 settings 仍不可直写', errIs('42501'), () =>
  user(A, () => q('update settings set share_battery=true where user_id=$1 returning share_battery', [A])));
await check('回归 purge 对登录身份仍不可执行', (r) => r[0].v === false, () =>
  q("select has_function_privilege('authenticated','public.purge_old_locations()','execute') as v"));

const passed = results.filter((r) => r.passed).length;
console.log(`\n${passed}/${results.length} passed`);
await writeFile(new URL('005-验证结果.json', import.meta.url),
  JSON.stringify({ environment: 'PGlite 0.5.11', passed, total: results.length, results }, null, 2));
await db.close();
