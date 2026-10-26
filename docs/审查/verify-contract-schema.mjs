import {PGlite} from '@electric-sql/pglite';
import {readFile,writeFile} from 'node:fs/promises';
const db=new PGlite();
const results=[];
const A='00000000-0000-0000-0000-000000000001';
const B='00000000-0000-0000-0000-000000000002';
async function observe(name,fn){try{const value=await fn();results.push({name,value});}catch(e){results.push({name,error:{code:e.code,message:e.message}});}console.log(JSON.stringify(results.at(-1)));}
async function user(id,fn,role='authenticated'){
  await db.exec('begin');
  try{await db.query("select set_config('request.jwt.claim.sub',$1,true)",[id??'']);await db.exec(`set local role ${role}`);const r=await fn();await db.exec('commit');return r;}
  catch(e){await db.exec('rollback');throw e;}
}
async function q(sql,params=[]){return (await db.query(sql,params)).rows;}
const usage=(date,apps,time,daily={screen_on_ms:10000})=>user(A,()=>q('select public.report_usage($1,$2::jsonb,$3::jsonb,$4) as result',[date,JSON.stringify(daily),apps===null?null:JSON.stringify(apps),time]));
const loc=points=>user(A,()=>q('select public.report_locations($1::jsonb) as result',[JSON.stringify(points)]));
await db.exec(`create role authenticated;create role anon;create schema auth;
create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb default '{}');
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create publication supabase_realtime;grant usage on schema public,auth to authenticated,anon;`);
for(const f of ['001-schema.sql','002-contract.sql'])await db.exec(await readFile(new URL(f,import.meta.url),'utf8'));
await db.exec(`grant select,insert,update,delete on all tables in schema public to authenticated;
grant usage,select on all sequences in schema public to authenticated;
alter default privileges in schema public grant select,insert,update,delete on tables to authenticated;`);
await db.exec(await readFile(new URL('003-hardening.sql',import.meta.url),'utf8'));
for(const id of [A,B])await db.query('insert into auth.users(id,email) values ($1,$2)',[id,id.slice(-1)+'@example.test']);
const [{code}]=await user(A,()=>q('select generate_pair_code() as code'));
await user(B,()=>q('select accept_pair_code($1)',[code]));

await usage('2001-01-01',[{package_name:'original.app',foreground_ms:1000}],'2001-01-01T10:00:00Z');
await observe('null_apps_before',()=>q('select package_name from app_usage where user_id=$1 and date=$2',[A,'2001-01-01']));
await usage('2001-01-01',null,'2001-01-01T10:01:00Z');
await observe('null_apps_after',()=>q('select package_name from app_usage where user_id=$1 and date=$2',[A,'2001-01-01']));
const apps=Array.from({length:21},(_,i)=>({package_name:`app.${i}`,foreground_ms:100000-i}));
await observe('twenty_one_apps_error',()=>usage('2001-01-02',apps,'2001-01-02T10:00:00Z'));
await usage('2001-01-02',apps.slice(0,20),'2001-01-02T10:00:00Z');
await usage('2001-01-02',apps.slice(20),'2001-01-02T10:00:00Z');
await observe('split_snapshot_final_apps',()=>q('select package_name from app_usage where user_id=$1 and date=$2',[A,'2001-01-02']));

await new Promise(r=>setTimeout(r,20));
const pointTime=new Date().toISOString();
await loc([{lat:25,lng:121,battery:50,recorded_at:pointTime}]);
await new Promise(r=>setTimeout(r,20));
await user(A,()=>q('select set_sharing(true,true,false)'));
await observe('status_time_sources',async()=>({response:await user(B,()=>q('select last_report_at,updated_at from get_status()')),point:await user(A,()=>q('select updated_at from user_status where user_id=$1',[A]))}));

await observe('missing_required_location_field',()=>loc([{lat:25,recorded_at:new Date().toISOString()}]));
await observe('wrong_location_field_type',()=>loc([{lat:'bad',lng:121,recorded_at:new Date().toISOString()}]));
await observe('out_of_range_location_accepted',()=>loc([{lat:999,lng:999,battery:150,accuracy:-5,recorded_at:'2099-01-01T00:00:00Z'}]));
await observe('negative_usage_accepted',()=>usage('2001-01-03',[],'2001-01-03T10:00:00Z',{screen_on_ms:-100,unlock_count:-2}));
await observe('future_snapshot_accepted',()=>usage('2001-01-04',[],'2099-01-01T00:00:00Z'));
await observe('valid_time_snapshot_after_future_rejected',()=>usage('2001-01-04',[],'2001-01-04T10:00:00Z'));

await observe('settings_direct_write_allowed',()=>user(A,()=>q('update settings set share_battery=true where user_id=$1 returning share_battery',[A])));
await observe('presence_nonheartbeat_write_allowed',()=>user(A,()=>q("update presence set resumed_at='2000-01-01T00:00:00Z' where user_id=$1 returning resumed_at",[A])));
await observe('profile_noneditable_columns_write_allowed',()=>user(A,()=>q("update profiles set email='changed@example.test',created_at='2000-01-01T00:00:00Z' where id=$1 returning email,created_at",[A])));

await db.query("insert into location_points(user_id,lat,lng,recorded_at) values($1,1,1,now()-interval '10 days')",[B]);
await observe('purge_function_role_privileges',()=>q("select has_function_privilege('anon','public.purge_old_locations()','execute') as anon_execute,has_function_privilege('authenticated','public.purge_old_locations()','execute') as authenticated_execute"));
await observe('anon_purge_call',()=>user(null,()=>q('select public.purge_old_locations()'),'anon'));
await observe('other_user_old_point_after_anon_purge',()=>q("select count(*)::int as n from location_points where user_id=$1 and recorded_at<now()-interval '7 days'",[B]));
await observe('postgres_json_timestamp_format',()=>q("select to_jsonb('2026-10-26T00:00:00Z'::timestamptz) as timestamp"));
await db.exec('set timezone to UTC');
await observe('postgres_json_timestamp_utc_format',()=>q("select to_jsonb('2026-10-26T00:00:00Z'::timestamptz) as timestamp"));
await writeFile(new URL('契约schema审查-本地验证结果.json',import.meta.url),JSON.stringify({environment:'PGlite 0.5.11; project SQL unchanged; simulated auth and pre-003 table privileges; no live Supabase or HTTP PostgREST',results},null,2));
await db.close();


