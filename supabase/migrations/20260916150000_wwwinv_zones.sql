-- Areas of the gallery (e.g. "LAN Party"), stored on each artwork.
create or replace function public.wwwinv_patch(p_table text, p_id text, p_patch jsonb, p_hist jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  clean jsonb;
begin
  if p_table = 'items' then
    select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into clean
    from jsonb_each(coalesce(p_patch, '{}'::jsonb))
    where key = any (array['name','kind','qty','cat','source','work','status','cut']);
    update wwwinv_items
       set doc = (doc || clean) || case when p_hist is null then '{}'::jsonb
                 else jsonb_build_object('history', wwwinv_tail(coalesce(doc->'history','[]'::jsonb) || jsonb_build_array(p_hist))) end,
           updated_at = now()
     where id = p_id;
  elsif p_table = 'works' then
    select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into clean
    from jsonb_each(coalesce(p_patch, '{}'::jsonb))
    where key = any (array['zone']);
    update wwwinv_works
       set doc = (doc || clean) || case when p_hist is null then '{}'::jsonb
                 else jsonb_build_object('history', wwwinv_tail(coalesce(doc->'history','[]'::jsonb) || jsonb_build_array(p_hist))) end,
           updated_at = now()
     where id = p_id;
  else
    raise exception 'unknown table %', p_table;
  end if;
end $$;

-- LAN Party: Vuk Ćosić, Petra Cortright, Simon Denny, Sarah Friend, Nolen
update public.wwwinv_works
   set doc = doc || '{"zone":"LAN Party"}'::jsonb, updated_at = now()
 where id in ('w05','w18','w11','w04','w16');
