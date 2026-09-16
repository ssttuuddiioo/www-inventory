# WWW Install Inventory

Shared install checklist for the ArtxCode | Rhizome **WWW** exhibition at Projekt Blank. It covers every screen, computer, cable, mount and plinth, organized by gear type and by artwork.

- Filter by gear (and by type, such as TV, CRT or NUC), by artist, by status and by source
- Four statuses: Needs source → Source set → In gallery → Installed
- Notes are checked off with a strikethrough, and items are crossed out as "not needed". Nothing is ever deleted.
- Every change is logged with the name the person typed in the header
- Live updates across everyone who has the page open

## Stack

A static page (`public/index.html`) plus one Vercel function (`api/config.js`), with Supabase for storage and live updates.

## Setup

1. Apply `supabase/migrations/20260916120000_wwwinv.sql` to the project (it is shared with other apps, so use `supabase db query --linked -f <file>` rather than `db push`).
2. In Vercel, set the environment variables `SUPABASE_URL` and `SUPABASE_ANON_KEY`, then redeploy.

Tables and functions are prefixed `wwwinv_` so they can live in a shared Supabase project.
