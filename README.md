# Aaurea India

Baseline: `Aaurea_India_Import_GST_Prototype (29).html`, supplied on 27 September 2026.

## Setup

1. Create a separate Supabase project named `aurea-india`.
2. Run `schema.sql` in that project's SQL Editor.
3. Register users in Supabase Auth and add each user to `public.india_members` by UUID.
4. Set the HTML's `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` to the new project's public values before publishing.

The current HTML points at the existing `AES-TEST` project. Only the `shipments` list currently saves to Supabase. Profiles, payments, expenses, documents, tickets, and several other modules still use browser `localStorage`. `schema.sql` covers the actively integrated shipment table; it does not make the other modules collaborative.

This prototype has not yet been published for India.
