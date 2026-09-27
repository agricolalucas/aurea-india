# Aaurea India

Baseline: `Aaurea_India_Import_GST_Prototype (29).html`, supplied on 27 September 2026.

## Setup

1. Supabase project `aurea-india`: `gqpxtedduizfzgejeqqj`.
2. The tables in `schema.sql` were applied on 27 September 2026; it is the schema record, not a script to rerun verbatim over existing policies.
3. Create staff accounts in this project's Supabase Auth and add each user to `public.india_members` by UUID. Example: `insert into public.india_members(user_id,role) values ('AUTH_USER_UUID_HERE','admin');` Run this only for a known administrator.
4. `index.html` has this project's URL and publishable key. Enable GitHub Pages to serve the HTML when ready.

Only the `shipments` list currently saves to Supabase. Profiles, payments, expenses, documents, tickets, and several other modules still use browser `localStorage`; the matching tables are prepared but the HTML does not yet write those records to them. Files attached in the prototype are still stored locally in the browser, not in Supabase Storage. The prototype must be updated before those modules become collaborative.

This prototype has not yet been published for India.
