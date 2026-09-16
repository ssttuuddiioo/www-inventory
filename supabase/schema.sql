-- WWW install inventory: tables, access rules and write functions.
-- Anyone with the link can read and edit. Nothing can be deleted:
-- there is no delete policy or function, items are only crossed out.

create table if not exists public.wwwinv_works (
  id text primary key,
  doc jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.wwwinv_items (
  id text primary key,
  doc jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.wwwinv_works enable row level security;
alter table public.wwwinv_items enable row level security;

drop policy if exists "wwwinv_works read" on public.wwwinv_works;
create policy "wwwinv_works read" on public.wwwinv_works for select to anon, authenticated using (true);
drop policy if exists "wwwinv_items read" on public.wwwinv_items;
create policy "wwwinv_items read" on public.wwwinv_items for select to anon, authenticated using (true);

-- Keep the last 60 entries of a jsonb array
create or replace function public.wwwinv_tail(arr jsonb, n int default 60)
returns jsonb language sql immutable set search_path = public as $$
  select coalesce(jsonb_agg(x order by i), '[]'::jsonb)
  from (select x, i from jsonb_array_elements(coalesce(arr, '[]'::jsonb)) with ordinality t(x, i)
        order by i desc limit n) s;
$$;

-- Merge allowed fields into a row and append a change-log entry
create or replace function public.wwwinv_patch(p_table text, p_id text, p_patch jsonb, p_hist jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  clean jsonb;
begin
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into clean
  from jsonb_each(coalesce(p_patch, '{}'::jsonb))
  where key = any (array['name','kind','qty','cat','source','work','status','cut']);

  if p_table = 'items' then
    update wwwinv_items
       set doc = (doc || clean) || case when p_hist is null then '{}'::jsonb
                 else jsonb_build_object('history', wwwinv_tail(coalesce(doc->'history','[]'::jsonb) || jsonb_build_array(p_hist))) end,
           updated_at = now()
     where id = p_id;
  else
    raise exception 'unknown table %', p_table;
  end if;
end $$;

create or replace function public.wwwinv_add_note(p_table text, p_id text, p_text text, p_by text)
returns void language plpgsql security definer set search_path = public as $$
declare
  n jsonb := jsonb_build_object('t', now(), 'by', left(coalesce(p_by, 'Someone'), 80),
                                'text', left(p_text, 4000), 'done', false);
begin
  if coalesce(btrim(p_text), '') = '' then return; end if;
  if p_table = 'items' then
    update wwwinv_items set doc = jsonb_set(doc, '{notes}', coalesce(doc->'notes','[]'::jsonb) || jsonb_build_array(n)), updated_at = now() where id = p_id;
  elsif p_table = 'works' then
    update wwwinv_works set doc = jsonb_set(doc, '{notes}', coalesce(doc->'notes','[]'::jsonb) || jsonb_build_array(n)), updated_at = now() where id = p_id;
  else
    raise exception 'unknown table %', p_table;
  end if;
end $$;

create or replace function public.wwwinv_toggle_note(p_table text, p_id text, p_idx int, p_by text)
returns void language plpgsql security definer set search_path = public as $$
declare
  path text[] := array['notes', p_idx::text];
begin
  if p_table = 'items' then
    update wwwinv_items
       set doc = jsonb_set(doc, path, (doc #> path) || jsonb_build_object(
             'done', not coalesce((doc #>> (path || 'done'::text))::boolean, false),
             'doneBy', left(coalesce(p_by, 'Someone'), 80), 'doneT', now())),
           updated_at = now()
     where id = p_id and doc #> path is not null;
  elsif p_table = 'works' then
    update wwwinv_works
       set doc = jsonb_set(doc, path, (doc #> path) || jsonb_build_object(
             'done', not coalesce((doc #>> (path || 'done'::text))::boolean, false),
             'doneBy', left(coalesce(p_by, 'Someone'), 80), 'doneT', now())),
           updated_at = now()
     where id = p_id and doc #> path is not null;
  else
    raise exception 'unknown table %', p_table;
  end if;
end $$;

create or replace function public.wwwinv_add_item(p_doc jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare
  new_id text := 'n' || substr(md5(random()::text || clock_timestamp()::text), 1, 10);
  clean jsonb;
  next_order int;
begin
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into clean
  from jsonb_each(p_doc)
  where key = any (array['work','name','cat','kind','qty','source','vendor','status','cut','notes','history']);
  select coalesce(max((doc->>'order')::int), 0) + 1 into next_order from wwwinv_items;
  insert into wwwinv_items (id, doc) values (new_id, clean || jsonb_build_object('order', next_order));
  return new_id;
end $$;

revoke all on function public.wwwinv_patch(text, text, jsonb, jsonb) from public;
revoke all on function public.wwwinv_add_note(text, text, text, text) from public;
revoke all on function public.wwwinv_toggle_note(text, text, int, text) from public;
revoke all on function public.wwwinv_add_item(jsonb) from public;
grant execute on function public.wwwinv_patch(text, text, jsonb, jsonb) to anon, authenticated;
grant execute on function public.wwwinv_add_note(text, text, text, text) to anon, authenticated;
grant execute on function public.wwwinv_toggle_note(text, text, int, text) to anon, authenticated;
grant execute on function public.wwwinv_add_item(jsonb) to anon, authenticated;

-- Live updates
do $$ begin
  begin alter publication supabase_realtime add table public.wwwinv_items; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.wwwinv_works; exception when duplicate_object then null; end;
end $$;
