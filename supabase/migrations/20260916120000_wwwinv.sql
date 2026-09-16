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

-- Starting data from the production sheet. Safe to re-run: existing rows are left alone.
insert into public.wwwinv_works (id, doc) values
('w01', '{"title": "Die", "artist": "0xfff", "order": 0, "notes": [], "budget": 0}'::jsonb),
('w02', '{"title": "Most Improved Site", "artist": "Luke Shannon", "order": 1, "notes": []}'::jsonb),
('w03', '{"title": "2010 Pose Idea", "artist": "Molly Soda", "order": 2, "notes": [], "budget": 40}'::jsonb),
('w04', '{"title": "FEED", "artist": "Sarah Friend", "order": 3, "notes": [], "budget": 100}'::jsonb),
('w05', '{"title": "History for the Blind", "artist": "Vuk Ćosić", "order": 4, "notes": [], "budget": 100}'::jsonb),
('w06', '{"title": "Honey, I Blew Up My Tits", "artist": "Lorna Mills", "order": 5, "notes": [], "budget": 0}'::jsonb),
('w07', '{"title": "papertoilet.com", "artist": "Rafaël Rozendaal", "order": 6, "notes": [], "url": "https://papertoilet.com/", "budget": 0}'::jsonb),
('w08', '{"title": "pureinformation.stream", "artist": "Maya Man", "order": 7, "notes": [], "url": "https://pureinformation.stream/", "budget": 0}'::jsonb),
('w09', '{"title": "Humans Not Invited", "artist": "Damjanski", "order": 8, "notes": [], "budget": 0}'::jsonb),
('w10', '{"title": "Internet Flowers", "artist": "Mika Ben Amar", "order": 9, "notes": [], "budget": 0}'::jsonb),
('w11', '{"title": "Metaverse Landscapes: Patchwork", "artist": "Simon Denny", "order": 10, "notes": []}'::jsonb),
('w12', '{"title": "Mira", "artist": "Lia", "order": 11, "notes": [], "budget": 0}'::jsonb),
('w13', '{"title": "Monogrid 0.1", "artist": "Kim Asendorf", "order": 12, "notes": [], "budget": 0}'::jsonb),
('w14', '{"title": "Paru-paro (At the Gates)", "artist": "Chia Amisola", "order": 13, "notes": [], "budget": 150}'::jsonb),
('w15', '{"title": "rhizome.leegte.org", "artist": "Jan Robert Leegte", "order": 14, "notes": [], "url": "https://rhizome.leegte.org/", "budget": 600}'::jsonb),
('w16', '{"title": "Solitaire Alone Together", "artist": "Nolen", "order": 15, "notes": [], "budget": 0}'::jsonb),
('w17', '{"title": "SPEEDRUNHOME.PAGE", "artist": "Shawne Michaelain Holloway", "order": 16, "notes": [], "url": "https://speedrunhome.page/", "budget": 0}'::jsonb),
('w18', '{"title": "System Landscapes", "artist": "Petra Cortright", "order": 17, "notes": [], "budget": 0}'::jsonb),
('w19', '{"title": "The Last Acres of the Internet", "artist": "exonemo", "order": 18, "notes": [], "budget": 0}'::jsonb),
('w20', '{"title": "Wrong", "artist": "Auriea Harvey", "order": 19, "notes": [], "budget": 0}'::jsonb),
('w99', '{"title": "Gallery build-out", "artist": "Shared", "order": 20, "notes": [], "budget": 1100}'::jsonb)
on conflict (id) do nothing;

insert into public.wwwinv_items (id, doc) values
('i000', '{"work": "w01", "name": "Square screen", "cat": "display", "qty": 1, "source": "gallery", "vendor": "Projekt Blank", "status": "onsite", "cut": false, "order": 0, "notes": [], "history": [], "kind": "Screen", "cost": 250}'::jsonb),
('i001', '{"work": "w01", "name": "Wall mount", "cat": "mount", "qty": 1, "source": "gallery", "vendor": "Projekt Blank", "status": "assigned", "cut": false, "order": 1, "notes": [{"t": "2026-09-16T12:00:00Z", "by": null, "text": "TV mount yes, missing wall mount", "from": "sheet"}], "history": [], "cost": 0}'::jsonb),
('i002', '{"work": "w01", "name": "Good computer", "cat": "computer", "qty": 1, "source": "gallery", "vendor": "Projekt Blank", "status": "assigned", "cut": false, "order": 2, "notes": [{"t": "2026-09-16T12:00:00Z", "by": null, "text": "pablo mini?", "from": "sheet"}], "history": [], "kind": "Mac mini", "cost": 50}'::jsonb),
('i003', '{"work": "w01", "name": "Headphones", "cat": "audio", "qty": 1, "source": "gallery", "vendor": "Projekt Blank", "status": "assigned", "cut": false, "order": 3, "notes": [], "history": [], "cost": 5}'::jsonb),
('i004', '{"work": "w01", "name": "Power cable", "cat": "cable", "qty": 1, "source": "gallery", "vendor": "Projekt Blank", "status": "assigned", "cut": false, "order": 4, "notes": [], "history": [], "cost": 0}'::jsonb),
('i005', '{"work": "w01", "name": "HDMI cable", "cat": "cable", "qty": 1, "source": "gallery", "vendor": "Projekt Blank", "status": "assigned", "cut": false, "order": 5, "notes": [], "history": [], "cost": 0}'::jsonb),
('i006', '{"work": "w01", "name": "Cable cover: 7 ft floor + 5 ft up", "cat": "cover", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 6, "notes": [], "history": [], "ft": 12}'::jsonb),
('i007', '{"work": "w02", "name": "Apple Studio Display with stand", "cat": "display", "qty": 1, "source": "loan", "vendor": "Loaned by Luke Shannon", "status": "assigned", "cut": false, "order": 7, "notes": [], "history": [], "kind": "Monitor"}'::jsonb),
('i008', '{"work": "w02", "name": "Mac mini", "cat": "computer", "qty": 1, "source": "buy", "vendor": "Buy from Apple Store?", "status": "open", "cut": false, "order": 8, "notes": [{"t": "2026-09-16T12:00:00Z", "by": null, "text": "Source unconfirmed in sheet: “Buy from Apple Store?”", "from": "sheet"}], "history": [], "kind": "Mac mini"}'::jsonb),
('i009', '{"work": "w02", "name": "Power cable (Mac)", "cat": "cable", "qty": 1, "source": "buy", "vendor": "Buy from Apple Store?", "status": "open", "cut": false, "order": 9, "notes": [{"t": "2026-09-16T12:00:00Z", "by": null, "text": "Source unconfirmed in sheet: “Buy from Apple Store?”", "from": "sheet"}], "history": []}'::jsonb),
('i010', '{"work": "w02", "name": "HDMI cable", "cat": "cable", "qty": 1, "source": "buy", "vendor": "Buy from Apple Store?", "status": "open", "cut": false, "order": 10, "notes": [{"t": "2026-09-16T12:00:00Z", "by": null, "text": "Source unconfirmed in sheet: “Buy from Apple Store?”", "from": "sheet"}], "history": []}'::jsonb),
('i011', '{"work": "w02", "name": "Cable cover: 5 ft", "cat": "cover", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 11, "notes": [], "history": [], "ft": 5}'::jsonb),
('i012', '{"work": "w03", "name": "Samsung Frame TV (1 of 2)", "cat": "display", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 12, "notes": [], "history": [], "kind": "TV"}'::jsonb),
('i013', '{"work": "w03", "name": "20K projector", "cat": "display", "qty": 1, "source": "gallery", "vendor": "Projekt Blank", "status": "assigned", "cut": false, "order": 13, "notes": [], "history": [], "kind": "Projector"}'::jsonb),
('i014', '{"work": "w03", "name": "Wall mount", "cat": "mount", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 14, "notes": [], "history": [], "cost": 40}'::jsonb),
('i015', '{"work": "w03", "name": "Raspberry Pi", "cat": "computer", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 15, "notes": [], "history": [], "kind": "Raspberry Pi"}'::jsonb),
('i016', '{"work": "w03", "name": "Power cable", "cat": "cable", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 16, "notes": [], "history": []}'::jsonb),
('i017', '{"work": "w03", "name": "HDMI cable", "cat": "cable", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 17, "notes": [], "history": []}'::jsonb),
('i018', '{"work": "w04", "name": "CRT monitor", "cat": "display", "qty": 1, "source": "tbd", "vendor": "", "status": "onsite", "cut": false, "order": 18, "notes": [], "history": [], "kind": "CRT", "cost": 100}'::jsonb),
('i019', '{"work": "w04", "name": "Keyboard", "cat": "input", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 19, "notes": [], "history": []}'::jsonb),
('i020', '{"work": "w04", "name": "Mouse", "cat": "input", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 20, "notes": [], "history": []}'::jsonb),
('i021', '{"work": "w04", "name": "NUC computer (1/8)", "cat": "computer", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 21, "notes": [], "history": [], "kind": "NUC"}'::jsonb),
('i022', '{"work": "w04", "name": "Power cable", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 22, "notes": [], "history": []}'::jsonb),
('i023', '{"work": "w04", "name": "CRT video to HDMI converter", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 23, "notes": [], "history": []}'::jsonb),
('i024', '{"work": "w05", "name": "CRT monitor", "cat": "display", "qty": 1, "source": "tbd", "vendor": "", "status": "onsite", "cut": false, "order": 24, "notes": [], "history": [], "kind": "CRT", "cost": 100}'::jsonb),
('i025', '{"work": "w05", "name": "Keyboard", "cat": "input", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 25, "notes": [], "history": []}'::jsonb),
('i026', '{"work": "w05", "name": "Mouse", "cat": "input", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 26, "notes": [], "history": []}'::jsonb),
('i027', '{"work": "w05", "name": "Raspberry Pi", "cat": "computer", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 27, "notes": [], "history": [], "kind": "Raspberry Pi"}'::jsonb),
('i028', '{"work": "w05", "name": "Headphones", "cat": "audio", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 28, "notes": [], "history": []}'::jsonb),
('i029', '{"work": "w05", "name": "Power cable", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 29, "notes": [], "history": []}'::jsonb),
('i030', '{"work": "w05", "name": "CRT video to HDMI converter", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 30, "notes": [], "history": []}'::jsonb),
('i031', '{"work": "w06", "name": "Large touch screen", "cat": "display", "qty": 1, "source": "buy", "vendor": "Order from Amazon and Return", "status": "open", "cut": false, "order": 31, "notes": [], "history": [], "kind": "Touchscreen"}'::jsonb),
('i032', '{"work": "w06", "name": "Mount system (custom?)", "cat": "mount", "qty": 1, "source": "buy", "vendor": "Order from Amazon and Return", "status": "open", "cut": false, "order": 32, "notes": [], "history": []}'::jsonb),
('i033', '{"work": "w06", "name": "Raspberry Pi 5", "cat": "computer", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 33, "notes": [], "history": [], "kind": "Raspberry Pi"}'::jsonb),
('i034', '{"work": "w06", "name": "Power cable", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 34, "notes": [], "history": []}'::jsonb),
('i035', '{"work": "w06", "name": "HDMI cable", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 35, "notes": [], "history": []}'::jsonb),
('i036', '{"work": "w06", "name": "Touch (USB) cable", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 36, "notes": [], "history": []}'::jsonb),
('i037', '{"work": "w07", "name": "Large LED screen", "cat": "display", "qty": 1, "source": "tbd", "vendor": "Loaned from where?", "status": "open", "cut": false, "order": 37, "notes": [{"t": "2026-09-16T12:00:00Z", "by": null, "text": "Source unconfirmed in sheet: “Loaned from where?”", "from": "sheet"}], "history": [], "kind": "LED"}'::jsonb),
('i038', '{"work": "w07", "name": "NUC computer (1)", "cat": "computer", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 38, "notes": [{"t": "2026-09-16T12:00:00Z", "by": null, "text": "Numbered outside the 1/8–8/8 set", "from": "sheet"}], "history": [], "kind": "NUC"}'::jsonb),
('i039', '{"work": "w07", "name": "Trackpad", "cat": "input", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 39, "notes": [], "history": []}'::jsonb),
('i040', '{"work": "w07", "name": "Power cable", "cat": "cable", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 40, "notes": [], "history": []}'::jsonb),
('i041', '{"work": "w07", "name": "HDMI cable", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 41, "notes": [], "history": []}'::jsonb),
('i042', '{"work": "w07", "name": "Small white plinth", "cat": "furniture", "qty": 1, "source": "gallery", "vendor": "Projekt Blank", "status": "assigned", "cut": false, "order": 42, "notes": [], "history": []}'::jsonb),
('i043', '{"work": "w08", "name": "Samsung 65\" TV", "cat": "display", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 43, "notes": [], "history": [], "kind": "TV"}'::jsonb),
('i044', '{"work": "w08", "name": "Wall mount", "cat": "mount", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 44, "notes": [], "history": []}'::jsonb),
('i045', '{"work": "w08", "name": "Raspberry Pi", "cat": "computer", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 45, "notes": [], "history": [], "kind": "Raspberry Pi"}'::jsonb),
('i046', '{"work": "w08", "name": "Power cable", "cat": "cable", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 46, "notes": [], "history": []}'::jsonb),
('i047', '{"work": "w08", "name": "HDMI cable", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 47, "notes": [], "history": []}'::jsonb),
('i048', '{"work": "w08", "name": "Cable cover: 8 ft floor + 6 ft up", "cat": "cover", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 48, "notes": [], "history": [], "ft": 14}'::jsonb),
('i049', '{"work": "w09", "name": "iPad (9th generation)", "cat": "display", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 49, "notes": [], "history": [], "kind": "iPad"}'::jsonb),
('i050', '{"work": "w09", "name": "LED lamp (under door)", "cat": "light", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 50, "notes": [], "history": []}'::jsonb),
('i051', '{"work": "w09", "name": "iPad charger", "cat": "cable", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 51, "notes": [], "history": []}'::jsonb),
('i052', '{"work": "w09", "name": "Door / iPad mount", "cat": "mount", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 52, "notes": [], "history": []}'::jsonb),
('i053', '{"work": "w10", "name": "LED wall, 2 × 2 panels", "cat": "display", "qty": 1, "source": "onx", "vendor": "ONX?", "status": "open", "cut": false, "order": 53, "notes": [{"t": "2026-09-16T12:00:00Z", "by": null, "text": "is this (note cut off in sheet)", "from": "sheet"}, {"t": "2026-09-16T12:00:00Z", "by": null, "text": "Source unconfirmed in sheet: “ONX?”", "from": "sheet"}], "history": [], "kind": "LED"}'::jsonb),
('i054', '{"work": "w10", "name": "LED wall structure", "cat": "mount", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 54, "notes": [], "history": []}'::jsonb),
('i055', '{"work": "w10", "name": "Raspberry Pi", "cat": "computer", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 55, "notes": [], "history": [], "kind": "Raspberry Pi"}'::jsonb),
('i056', '{"work": "w10", "name": "Power cable", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 56, "notes": [], "history": []}'::jsonb),
('i057', '{"work": "w10", "name": "HDMI cable", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 57, "notes": [], "history": []}'::jsonb),
('i058', '{"work": "w11", "name": "TV screen", "cat": "display", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 58, "notes": [], "history": [], "kind": "TV"}'::jsonb),
('i059', '{"work": "w11", "name": "Mount", "cat": "mount", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 59, "notes": [], "history": []}'::jsonb),
('i060', '{"work": "w11", "name": "Headphones", "cat": "audio", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 60, "notes": [], "history": []}'::jsonb),
('i061', '{"work": "w11", "name": "NUC computer (2)", "cat": "computer", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 61, "notes": [{"t": "2026-09-16T12:00:00Z", "by": null, "text": "Numbered outside the 1/8–8/8 set", "from": "sheet"}], "history": [], "kind": "NUC"}'::jsonb),
('i062', '{"work": "w11", "name": "HDMI cable", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 62, "notes": [], "history": []}'::jsonb),
('i063', '{"work": "w11", "name": "Power cable", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 63, "notes": [], "history": []}'::jsonb),
('i064', '{"work": "w12", "name": "Standard screen (historical display)", "cat": "display", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 64, "notes": [], "history": [], "kind": "Monitor"}'::jsonb),
('i065', '{"work": "w12", "name": "Wall mount", "cat": "mount", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 65, "notes": [], "history": []}'::jsonb),
('i066', '{"work": "w12", "name": "NUC computer (3)", "cat": "computer", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 66, "notes": [{"t": "2026-09-16T12:00:00Z", "by": null, "text": "Numbered outside the 1/8–8/8 set", "from": "sheet"}], "history": [], "kind": "NUC"}'::jsonb),
('i067', '{"work": "w12", "name": "IntelliMouse", "cat": "input", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 67, "notes": [], "history": []}'::jsonb),
('i068', '{"work": "w12", "name": "Power cable", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 68, "notes": [], "history": []}'::jsonb),
('i069', '{"work": "w12", "name": "HDMI cable", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 69, "notes": [], "history": []}'::jsonb),
('i070', '{"work": "w12", "name": "Plinth", "cat": "furniture", "qty": 1, "source": "gallery", "vendor": "Projekt Blank", "status": "assigned", "cut": false, "order": 70, "notes": [], "history": []}'::jsonb),
('i071', '{"work": "w12", "name": "Cable cover: 7 ft + 5 ft up", "cat": "cover", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 71, "notes": [], "history": [], "ft": 12}'::jsonb),
('i072', '{"work": "w13", "name": "LED screen, 1 × 2 m", "cat": "display", "qty": 1, "source": "onx", "vendor": "ONX", "status": "assigned", "cut": false, "order": 72, "notes": [], "history": [], "kind": "LED"}'::jsonb),
('i073', '{"work": "w13", "name": "LED mount system", "cat": "mount", "qty": 1, "source": "onx", "vendor": "ONX", "status": "assigned", "cut": false, "order": 73, "notes": [], "history": []}'::jsonb),
('i074', '{"work": "w13", "name": "NUC computer (2/8)", "cat": "computer", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 74, "notes": [], "history": [], "kind": "NUC"}'::jsonb),
('i075', '{"work": "w13", "name": "Power cable", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 75, "notes": [], "history": []}'::jsonb),
('i076', '{"work": "w13", "name": "HDMI cable", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 76, "notes": [], "history": []}'::jsonb),
('i077', '{"work": "w14", "name": "Samsung 80\" TV", "cat": "display", "qty": 1, "source": "gallery", "vendor": "Projekt Blank", "status": "assigned", "cut": false, "order": 77, "notes": [], "history": [], "kind": "TV", "cost": 150}'::jsonb),
('i078', '{"work": "w14", "name": "Wall mount", "cat": "mount", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 78, "notes": [], "history": []}'::jsonb),
('i079', '{"work": "w14", "name": "NUC computer (3/8)", "cat": "computer", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 79, "notes": [], "history": [], "kind": "NUC"}'::jsonb),
('i080', '{"work": "w14", "name": "Headphones", "cat": "audio", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 80, "notes": [], "history": []}'::jsonb),
('i081', '{"work": "w14", "name": "Keyboard", "cat": "input", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 81, "notes": [], "history": []}'::jsonb),
('i082', '{"work": "w14", "name": "Mouse", "cat": "input", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 82, "notes": [], "history": []}'::jsonb),
('i083', '{"work": "w14", "name": "Power cable", "cat": "cable", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 83, "notes": [], "history": []}'::jsonb),
('i084', '{"work": "w14", "name": "HDMI cable", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 84, "notes": [], "history": []}'::jsonb),
('i085', '{"work": "w14", "name": "Cable cover: 3–4 ft + 5 ft", "cat": "cover", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 85, "notes": [], "history": [], "ft": 9}'::jsonb),
('i086', '{"work": "w15", "name": "Full HD screen (horizontal)", "cat": "display", "qty": 1, "source": "gallery", "vendor": "Projekt blank?", "status": "open", "cut": false, "order": 86, "notes": [{"t": "2026-09-16T12:00:00Z", "by": null, "text": "Source unconfirmed in sheet: “Projekt blank?”", "from": "sheet"}], "history": [], "kind": "Monitor"}'::jsonb),
('i087', '{"work": "w15", "name": "Metal architectural structure for screen", "cat": "mount", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 87, "notes": [], "history": [], "cost": 600}'::jsonb),
('i088', '{"work": "w15", "name": "Raspberry Pi", "cat": "computer", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 88, "notes": [], "history": [], "kind": "Raspberry Pi"}'::jsonb),
('i089', '{"work": "w15", "name": "Cable cover: 6 ft", "cat": "cover", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 89, "notes": [], "history": [], "ft": 6}'::jsonb),
('i090', '{"work": "w15", "name": "Power cable", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 90, "notes": [], "history": []}'::jsonb),
('i091', '{"work": "w15", "name": "HDMI cable", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 91, "notes": [], "history": []}'::jsonb),
('i092', '{"work": "w16", "name": "Dell 17\" monitor", "cat": "display", "qty": 2, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 92, "notes": [], "history": [], "kind": "Monitor"}'::jsonb),
('i093', '{"work": "w16", "name": "NUC computers (4/8, 5/8)", "cat": "computer", "qty": 2, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 93, "notes": [], "history": [], "kind": "NUC"}'::jsonb),
('i094', '{"work": "w16", "name": "Headphones (optional)", "cat": "audio", "qty": 2, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 94, "notes": [], "history": []}'::jsonb),
('i095', '{"work": "w16", "name": "Power cable", "cat": "cable", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 95, "notes": [], "history": []}'::jsonb),
('i096', '{"work": "w16", "name": "HDMI cable", "cat": "cable", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 96, "notes": [], "history": []}'::jsonb),
('i097', '{"work": "w17", "name": "Apple Studio Display", "cat": "display", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 97, "notes": [], "history": [], "kind": "Monitor"}'::jsonb),
('i098', '{"work": "w17", "name": "Mouse", "cat": "input", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 98, "notes": [], "history": []}'::jsonb),
('i099', '{"work": "w17", "name": "NUC computer (6/8)", "cat": "computer", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 99, "notes": [], "history": [], "kind": "NUC"}'::jsonb),
('i100', '{"work": "w17", "name": "Plinth", "cat": "furniture", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 100, "notes": [], "history": []}'::jsonb),
('i101', '{"work": "w17", "name": "Power cable", "cat": "cable", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 101, "notes": [], "history": []}'::jsonb),
('i102', '{"work": "w17", "name": "HDMI cable", "cat": "cable", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 102, "notes": [], "history": []}'::jsonb),
('i103', '{"work": "w17", "name": "Cable cover: 3 ft", "cat": "cover", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 103, "notes": [], "history": [], "ft": 3}'::jsonb),
('i104', '{"work": "w18", "name": "Smile 14\" CRT (beige)", "cat": "display", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 104, "notes": [], "history": [], "kind": "CRT"}'::jsonb),
('i105', '{"work": "w18", "name": "Mouse", "cat": "input", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 105, "notes": [], "history": []}'::jsonb),
('i106', '{"work": "w18", "name": "Raspberry Pi 3", "cat": "computer", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 106, "notes": [], "history": [], "kind": "Raspberry Pi"}'::jsonb),
('i107', '{"work": "w18", "name": "Power cable", "cat": "cable", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 107, "notes": [], "history": []}'::jsonb),
('i108', '{"work": "w18", "name": "HDMI cable", "cat": "cable", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 108, "notes": [], "history": []}'::jsonb),
('i109', '{"work": "w19", "name": "Square screen", "cat": "display", "qty": 1, "source": "gallery", "vendor": "Projekt Blank", "status": "assigned", "cut": false, "order": 109, "notes": [], "history": [], "kind": "Screen", "cost": 250}'::jsonb),
('i110', '{"work": "w19", "name": "Wall mount", "cat": "mount", "qty": 1, "source": "gallery", "vendor": "Projekt Blank", "status": "assigned", "cut": false, "order": 110, "notes": [], "history": []}'::jsonb),
('i111', '{"work": "w19", "name": "NUC computer (7/8)", "cat": "computer", "qty": 1, "source": "gallery", "vendor": "Projekt Blank", "status": "assigned", "cut": false, "order": 111, "notes": [{"t": "2026-09-16T12:00:00Z", "by": null, "text": "Sheet lists Projekt Blank, but 7/8 is in the Rhizome NUC set", "from": "sheet"}], "history": [], "kind": "NUC"}'::jsonb),
('i112', '{"work": "w19", "name": "Power cable", "cat": "cable", "qty": 1, "source": "gallery", "vendor": "Projekt Blank", "status": "assigned", "cut": false, "order": 112, "notes": [], "history": []}'::jsonb),
('i113', '{"work": "w19", "name": "HDMI cable", "cat": "cable", "qty": 1, "source": "gallery", "vendor": "Projekt Blank", "status": "assigned", "cut": false, "order": 113, "notes": [], "history": []}'::jsonb),
('i114', '{"work": "w19", "name": "Cable cover: 6 ft + 5 ft up", "cat": "cover", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 114, "notes": [], "history": [], "ft": 11}'::jsonb),
('i115', '{"work": "w20", "name": "Samsung Frame TV", "cat": "display", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 115, "notes": [{"t": "2026-09-16T12:00:00Z", "by": null, "text": "Possibly Frame TV 2 of 2", "from": "sheet"}], "history": [], "kind": "TV"}'::jsonb),
('i116', '{"work": "w20", "name": "Wall mount", "cat": "mount", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 116, "notes": [], "history": []}'::jsonb),
('i117', '{"work": "w20", "name": "NUC computer (8/8)", "cat": "computer", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 117, "notes": [], "history": [], "kind": "NUC"}'::jsonb),
('i118', '{"work": "w20", "name": "Mouse", "cat": "input", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 118, "notes": [], "history": []}'::jsonb),
('i119', '{"work": "w20", "name": "Power cable", "cat": "cable", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 119, "notes": [], "history": []}'::jsonb),
('i120', '{"work": "w20", "name": "HDMI cable", "cat": "cable", "qty": 1, "source": "rhizome", "vendor": "Rhizome", "status": "assigned", "cut": false, "order": 120, "notes": [], "history": []}'::jsonb),
('i121', '{"work": "w20", "name": "Plinth", "cat": "furniture", "qty": 1, "source": "gallery", "vendor": "Projekt Blank", "status": "assigned", "cut": false, "order": 121, "notes": [], "history": []}'::jsonb),
('i122', '{"work": "w20", "name": "Cable cover: 9 ft + 5 ft up", "cat": "cover", "qty": 1, "source": "buy", "vendor": "Amazon buy", "status": "open", "cut": false, "order": 122, "notes": [], "history": [], "ft": 14}'::jsonb),
('i123', '{"work": "w99", "name": "Cable cover system", "cat": "cover", "qty": 15, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 123, "notes": [{"t": "2026-09-16T12:00:00Z", "by": null, "text": "Budget line: 15 × $40", "from": "sheet"}], "history": [], "cost": 40}'::jsonb),
('i124', '{"work": "w99", "name": "Extension cables", "cat": "cable", "qty": 5, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 124, "notes": [], "history": [], "cost": 25}'::jsonb),
('i125', '{"work": "w99", "name": "Tape & wall-mounting supplies", "cat": "supplies", "qty": 5, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 125, "notes": [], "history": [], "cost": 25}'::jsonb),
('i126', '{"work": "w99", "name": "Contingency", "cat": "supplies", "qty": 1, "source": "tbd", "vendor": "", "status": "open", "cut": false, "order": 126, "notes": [], "history": [], "cost": 250}'::jsonb)
on conflict (id) do nothing;
