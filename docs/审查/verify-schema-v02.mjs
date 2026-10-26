// Schema v0.2 supplemental review. Synthetic local PGlite only.
// Put this file beside SQL 001-004, install @electric-sql/pglite@0.5.11, run with Node.
// Setup helpers reused from verify-004.mjs; supplemental cases are independently written.
// FAIL records a reproduced contract mismatch, not a live production failure.

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
    try { passed = typeof expect === 'function' ? expect(null, e) : false; }
    catch { passed = false; }
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

// Independent supplemental cases. Harness only reused from verify-004.mjs.
await check('D01 decimal battery uses invalid_payload', errIs('invalid_payload'), () => loc([{lat:25,lng:121,battery:66.5,recorded_at:'2001-02-01T00:00:00Z'}]));
await check('D01 decimal daily count uses invalid_payload', errIs('invalid_payload'), () => usage('2001-02-01', [], '2001-02-01T00:00:00Z', {unlock_count:1.5}));
await check('D01 int overflow uses invalid_payload', errIs('invalid_payload'), () => usage('2001-02-01', [], '2001-02-01T00:00:00Z', {unlock_count:2147483648}));
await check('D01 real overflow uses invalid_payload', errIs('invalid_payload'), () => loc([{lat:25,lng:121,accuracy:1e40,recorded_at:'2001-02-01T00:00:00Z'}]));
await check('D01 duplicate package uses invalid_payload', errIs('invalid_payload'), () => usage('2001-02-02', [{package_name:'same',foreground_ms:1},{package_name:'same',foreground_ms:2}], '2001-02-02T00:00:00Z'));
await check('D01 failed duplicate snapshot fully rolls back', r=>r[0].n===0, () => q("select count(*)::int n from daily_usage where user_id=$1 and date='2001-02-02'",[A]));
await check('D02 documented missing target returns empty array', r=>r.length===0, () => user(B,()=>q('select * from get_status($1)', ['00000000-0000-0000-0000-000000000099'])));
await check('D03 accepted usage advances presence signal', r=>r.after!==r.before, async()=>{
  const [before] = await q('select updated_at::text as ts from presence where user_id=$1',[A]);
  const reply = await usage('2001-02-03', [{package_name:'new.app',foreground_ms:100}], '2001-02-03T00:00:00Z');
  const [after] = await q('select updated_at::text as ts from presence where user_id=$1',[A]);
  return {before:before.ts,after:after.ts,reply};
});
const C='00000000-0000-0000-0000-000000000003';
await db.query('insert into auth.users(id,email) values ($1,$2)',[C,'c@example.test']);
await check('control unpaired default get_status is empty', r=>r.length===0, ()=>user(C,()=>q('select * from get_status()')));
await check('control normal pair RPC blocks overlapping relationship', errIs('partner_already_paired'), async()=>{
  await q("insert into pair_codes(code,user_id,expires_at) values ('123456',$1,now()+interval '1 minute')",[A]);
  return user(C,()=>q("select accept_pair_code('123456')"));
});
await check('D04 pair index alone blocks different partner overlap (admin-only diagnostic)', errIs('23505'), ()=>q('insert into couples(user_a,user_b) values ($1,$2) returning user_a,user_b',[C,A]));
await check('control JSON null apps rejected', errIs('invalid_payload'), ()=>user(A,()=>q("select report_usage('2001-02-04','{}'::jsonb,'null'::jsonb,'2001-02-04T00:00:00Z')")));
await check('control lower coordinate and zero battery boundaries accepted', r=>r[0].result.inserted===1, ()=>loc([{lat:-90,lng:-180,battery:0,accuracy:0,recorded_at:'2001-02-04T00:00:00Z'}]));
await check('control upper coordinate and full battery boundaries accepted', r=>r[0].result.inserted===1, ()=>loc([{lat:90,lng:180,battery:100,accuracy:0,recorded_at:'2001-02-04T00:00:01Z'}]));
await check('control service_role retained maintenance privilege', r=>r[0].v===true, async()=>{
  await db.exec('create role service_role');
  await db.exec(await readFile(new URL('004-contract-fix.sql',import.meta.url),'utf8'));
  return q("select has_function_privilege('service_role','public.purge_old_locations()','execute') v");
});
const passed=results.filter(r=>r.passed).length;
await writeFile(new URL('schema-v02-supplement-results.json',import.meta.url),JSON.stringify({environment:'PGlite 0.5.11, synthetic Auth, no live HTTP',passed,total:results.length,results},null,2));
console.log(`${passed}/${results.length} supplemental expectations met; failures are review evidence`);
await db.close();



