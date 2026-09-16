-- Renumber the NUCs 1–10 in list order; Nolen uses a single NUC.
with nums(id, n) as (values
  ('i021',1),('i038',2),('i061',3),('i066',4),('i074',5),
  ('i079',6),('i093',7),('i099',8),('i111',9),('i117',10))
update public.wwwinv_items i
   set doc = jsonb_set(
               i.doc || jsonb_build_object('name', 'NUC computer #' || nums.n, 'qty', 1),
               '{history}',
               public.wwwinv_tail(coalesce(i.doc->'history','[]'::jsonb) || jsonb_build_array(jsonb_build_object(
                 't', now(), 'by', 'Renumbering',
                 'what', 'Item: ' || (i.doc->>'name') || ' → NUC computer #' || nums.n
                         || case when (i.doc->>'qty')::int <> 1 then ' · Qty: ' || (i.doc->>'qty') || ' → 1' else '' end)))),
       updated_at = now()
  from nums
 where i.id = nums.id;

-- The sheet's numbering notes no longer apply: check them off (never deleted).
update public.wwwinv_items i
   set doc = jsonb_set(i.doc, '{notes}', (
         select jsonb_agg(case when n->>'from' = 'sheet' and (n->>'text' ilike 'Numbered outside%' or n->>'text' ilike '%7/8 is in the Rhizome NUC set%')
                               then n || jsonb_build_object('done', true, 'doneBy', 'Renumbering', 'doneT', now())
                               else n end order by ord)
         from jsonb_array_elements(i.doc->'notes') with ordinality t(n, ord))),
       updated_at = now()
 where i.id in ('i038','i061','i066','i111') and jsonb_array_length(coalesce(i.doc->'notes','[]'::jsonb)) > 0;
