-- Take the 20K projector (Molly Soda) off the list. Hidden, not deleted:
-- set "removed" back to false to restore it.
update public.wwwinv_items
   set doc = jsonb_set(doc || '{"removed": true}'::jsonb, '{history}',
         public.wwwinv_tail(coalesce(doc->'history','[]'::jsonb) || jsonb_build_array(jsonb_build_object(
           't', now(), 'by', 'Cleanup', 'what', 'Removed from the list')))),
       updated_at = now()
 where id = 'i013';
