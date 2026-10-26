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
    try { passed = typeof expect === 'function' ? expect(null, e) : false; } catch { passed = false; }
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

// Raw JSON literals preserve trailing decimals; JSON.stringify(66.0) would hide the case.
const rawLocation = battery => user(A,()=>q('select report_locations($1::jsonb) result',
  [`[{"lat":25,"lng":121,"battery":${battery},"recorded_at":"2001-03-01T00:00:00Z"}]`]));
const rawUsage = (day,daily,apps) => user(A,()=>q('select report_usage($1,$2::jsonb,$3::jsonb,$4) result',
  [day,daily,apps,`${day}T00:00:00Z`]));
await check('E01 integral decimal battery 66.0 accepted',r=>r[0].result.received===1,()=>rawLocation('66.0'));
await check('E01 integral decimal foreground_ms 1000.0 accepted',r=>r[0].result===1,()=>rawUsage('2001-03-02','{}','[{"package_name":"a.app","foreground_ms":1000.0}]'));
await check('E01 integral decimal launch_count 3.0 accepted',r=>r[0].result===1,()=>rawUsage('2001-03-03','{}','[{"package_name":"a.app","launch_count":3.0}]'));
await check('control decimal-form integer daily values accepted',r=>r[0].result===0,()=>rawUsage('2001-03-04','{"screen_on_ms":1000.0,"unlock_count":3.0,"lock_count":2.0}','[]'));
await check('control failed fractional snapshot leaves no summary',r=>r[0].n===0,async()=>{
 try { await rawUsage('2001-03-09','{}','[{"package_name":"a.app","foreground_ms":1.5}]'); } catch(e) { if(e.message!=='invalid_payload') throw e; }
 return q("select count(*)::int n from daily_usage where user_id=$1 and date='2001-03-09'",[A]);
});
await check('control ordinary integer battery accepted',r=>r[0].result.received===1,()=>rawLocation('66'));
await check('control fractional application time rejected',errIs('invalid_payload'),()=>rawUsage('2001-03-05','{}','[{"package_name":"a.app","foreground_ms":1.5}]'));
await check('control application count beyond int rejected',errIs('invalid_payload'),()=>rawUsage('2001-03-06','{}','[{"package_name":"a.app","launch_count":2147483648}]'));
await check('control application bigint maximum accepted',r=>r[0].result===1,()=>rawUsage('2001-03-07','{}','[{"package_name":"a.app","foreground_ms":9223372036854775807,"launch_count":2147483647}]'));
await check('control application bigint overflow rejected',errIs('invalid_payload'),()=>rawUsage('2001-03-08','{}','[{"package_name":"a.app","foreground_ms":9223372036854775808}]'));
await check('control unauthorized absent target rejected',errIs('not_allowed'),()=>user(B,()=>q('select * from get_status($1)',['00000000-0000-0000-0000-000000000099'])));
const C='00000000-0000-0000-0000-000000000003';
await q('insert into auth.users(id,email) values ($1,$2)',[C,'c@example.test']);
await check('control unpaired default returns no rows',r=>r.length===0,()=>user(C,()=>q('select * from get_status()')));
await check('control normal pairing rejects cross relationship',errIs('partner_already_paired'),async()=>{
 await q("insert into pair_codes(code,user_id,expires_at) values ('123456',$1,now()+interval '1 minute')",[A]);
 return user(C,()=>q("select accept_pair_code('123456')"));
});
const passed=results.filter(r=>r.passed).length;
await writeFile(new URL('schema-v03-supplement-results.json',import.meta.url),JSON.stringify({environment:'PGlite 0.5.11; synthetic Auth; raw JSON inputs; no live HTTP',passed,total:results.length,results},null,2));
console.log(`${passed}/${results.length} supplemental assertions passed`);
await db.close();


