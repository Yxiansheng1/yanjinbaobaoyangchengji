// 006 契约修正 · 本地验证（E01：整数写法带小数点）
// 用法：
//   node verify-006.mjs before   只跑到 005，用来证明问题存在（应当 3 项红）
//   node verify-006.mjs          跑完 001–006，应当全绿
// 环境：PGlite 0.5.11，模拟 Auth、authenticated/anon
//
// 注意：测试必须保留原始 JSON 文本。JS 的 JSON.stringify(66.0) 会输出 "66"，
// 用它构造用例会把本问题完全漏掉。

import { PGlite } from '@electric-sql/pglite';
import { readFile, writeFile } from 'node:fs/promises';

const phase = process.argv[2] === 'before' ? 'before' : 'after';
const db = new PGlite();
const results = [];
const A = '00000000-0000-0000-0000-000000000001';
const B = '00000000-0000-0000-0000-000000000002';

async function check(name, expect, fn) {
  if (typeof fn !== 'function') throw new Error('check() 需要三个参数');
  let passed = false, detail;
  try {
    const got = await fn();
    detail = got;
    passed = typeof expect === 'function' ? expect(got) : expect === got;
  } catch (e) {
    detail = { code: e.code, message: e.message };
    // 只有声明了两个参数的判据（errIs）才在异常路径上被判为通过，
    // 只接收结果对象的判据遇到异常一律记失败。
    passed = typeof expect === 'function' && expect.length >= 2 ? !!expect(null, e) : false;
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

// 直接给 JSON 文本，保住 66.0 这种写法
const locRaw = (jsonText) => user(A, () => q('select public.report_locations($1::jsonb) as result', [jsonText]));
const usageRaw = (date, dailyText, appsText, captured) =>
  user(A, () => q('select public.report_usage($1,$2::jsonb,$3::jsonb,$4) as result',
    [date, dailyText, appsText, captured]));

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
if (phase === 'after') {
  await db.exec(await readFile(new URL('006-contract-fix3.sql', import.meta.url), 'utf8'));
}
for (const id of [A, B]) await db.query('insert into auth.users(id,email) values ($1,$2)', [id, `${id.slice(-1)}@example.test`]);
const [{ code }] = await user(A, () => q('select generate_pair_code() as code'));
await user(B, () => q('select accept_pair_code($1)', [code]));

const now = () => new Date().toISOString();

// ---------- E01：整数值但写成小数 ----------
await check('E01 位置点 battery 66.0 被接受', (r) => r[0].result.inserted === 1, () =>
  locRaw(`[{"lat":25,"lng":121,"battery":66.0,"accuracy":12.5,"recorded_at":"${now()}"}]`));

await check('E01 当前状态 battery 存成 66', (r) => r[0].battery === 66, () =>
  q('select battery from user_status where user_id=$1', [A]));

await check('E01 应用 foreground_ms 1000.0 与 launch_count 3.0 被接受', (r) => r[0].result === 1, () =>
  usageRaw('2001-03-01',
    '{"screen_on_ms":1000.0,"unlock_count":3.0,"lock_count":2.0}',
    '[{"package_name":"com.demo.app","app_label":"演示","foreground_ms":1000.0,"launch_count":3.0}]',
    '2001-03-01T10:00:00Z'));

await check('E01 应用明细存成整数', (r) => r[0]?.foreground_ms === 1000 && r[0].launch_count === 3, () =>
  q('select foreground_ms, launch_count from app_usage where user_id=$1 and date=$2', [A, '2001-03-01']));

// ---------- E01 的边界：真小数、越界仍要被拒 ----------
await check('E01 真小数 66.5 仍被拒', errIs('invalid_payload'), () =>
  locRaw(`[{"lat":25,"lng":121,"battery":66.5,"recorded_at":"${now()}"}]`));

await check('E01 int 越界仍被拒', errIs('invalid_payload'), () =>
  usageRaw('2001-03-02', '{"screen_on_ms":1000,"unlock_count":2147483648}', '[]', '2001-03-02T10:00:00Z'));

await check('E01 bigint 最大值被接受', (r) => r[0].result === 1, () =>
  usageRaw('2001-03-03', '{"screen_on_ms":9223372036854775807}',
    '[{"package_name":"max.app","foreground_ms":9223372036854775807}]', '2001-03-03T10:00:00Z'));

await check('E01 负数仍被拒', errIs('invalid_payload'), () =>
  usageRaw('2001-03-04', '{"screen_on_ms":-1}', '[]', '2001-03-04T10:00:00Z'));

await check('E01 重复包名仍被拒', errIs('invalid_payload'), () =>
  usageRaw('2001-03-05', '{"screen_on_ms":1}',
    '[{"package_name":"dup.app","foreground_ms":1},{"package_name":"dup.app","foreground_ms":2}]',
    '2001-03-05T10:00:00Z'));

await check('E01 被拒后当天无残留', (r) => r.n === 0 && r.m === 0, async () => {
  const d = await q('select count(*)::int as n from daily_usage where user_id=$1 and date=$2', [A, '2001-03-05']);
  const a = await q('select count(*)::int as m from app_usage where user_id=$1 and date=$2', [A, '2001-03-05']);
  return { n: d[0].n, m: a[0].m };
});

// ---------- 005 的结论不能被打破 ----------
const before = await q("select updated_at::text as t, last_report_at::text as l from presence where user_id=$1", [A]);
await sleep(50);
await usageRaw('2001-03-06', '{"screen_on_ms":10}', '[]', '2001-03-06T10:00:00Z');
const after = await q("select updated_at::text as t, last_report_at::text as l from presence where user_id=$1", [A]);
results.push({ name: '回归 用机上报仍推进显示信号', passed: after[0].t > before[0].t, detail: { before: before[0].t, after: after[0].t } });
console.log(`${after[0].t > before[0].t ? 'PASS' : 'FAIL'}  回归 用机上报仍推进显示信号`);
results.push({ name: '回归 last_report_at 仍不被用机改写', passed: after[0].l === before[0].l, detail: { before: before[0].l, after: after[0].l } });
console.log(`${after[0].l === before[0].l ? 'PASS' : 'FAIL'}  回归 last_report_at 仍不被用机改写`);

await check('回归 p_apps 传 null 仍被拒', errIs('invalid_payload'), () =>
  user(A, () => q("select public.report_usage('2001-03-07','{}'::jsonb,null,'2001-03-07T10:00:00Z')")));

await check('回归 settings 仍不可直写', errIs('42501'), () =>
  user(A, () => q('update settings set share_battery=true where user_id=$1 returning share_battery', [A])));

await check('回归 无关 UUID 仍返回 not_allowed', errIs('not_allowed'), () =>
  user(B, () => q("select * from get_status('00000000-0000-0000-0000-0000000000ff')")));

const passed = results.filter((r) => r.passed).length;
console.log(`\n${passed}/${results.length} passed (${phase})`);
await writeFile(new URL(`006-验证结果-${phase}.json`, import.meta.url),
  JSON.stringify({ environment: 'PGlite 0.5.11', phase, passed, total: results.length, results }, null, 2));
await db.close();
