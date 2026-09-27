-- Run only in a dedicated Supabase project for Aaurea India.
-- Create the first membership after creating an Auth user:
-- insert into public.india_members (user_id, role)
-- values ('AUTH_USER_UUID_HERE', 'admin');

create table if not exists public.india_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('admin', 'staff')),
  created_at timestamptz not null default now()
);

create table if not exists public.shipments (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique,
  cargox_number text,
  acid_number text,
  acid_expiry date,
  bill_of_lading text,
  vessel text,
  arrival_port text,
  eta date,
  product text,
  quantity_kg numeric(18,3) not null default 0 check (quantity_kg >= 0),
  notes text,
  status text not null default 'Pending',
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create index if not exists india_shipments_created_at_idx on public.shipments (created_at desc);
alter table public.india_members enable row level security;
alter table public.shipments enable row level security;
revoke all on public.india_members, public.shipments from anon;
grant select on public.india_members to authenticated;
grant select, insert, delete on public.shipments to authenticated;
grant update (reference, cargox_number, acid_number, acid_expiry,
  bill_of_lading, vessel, arrival_port, eta, product, quantity_kg,
  notes, status) on public.shipments to authenticated;

create policy "Member sees own membership" on public.india_members
  for select to authenticated using (user_id = (select auth.uid()));
create policy "Members see shipments" on public.shipments
  for select to authenticated using (exists (
    select 1 from public.india_members m where m.user_id = (select auth.uid())
  ));
create policy "Members create shipments" on public.shipments
  for insert to authenticated with check (
    created_by = (select auth.uid()) and exists (
      select 1 from public.india_members m where m.user_id = (select auth.uid())
    )
  );
create policy "Members edit shipments" on public.shipments
  for update to authenticated using (exists (
    select 1 from public.india_members m where m.user_id = (select auth.uid())
  )) with check (exists (
    select 1 from public.india_members m where m.user_id = (select auth.uid())
  ));
create policy "Admins delete shipments" on public.shipments
  for delete to authenticated using (exists (
    select 1 from public.india_members m
    where m.user_id = (select auth.uid()) and m.role = 'admin'
  ));

-- Module tables. Additional JSON fields preserve prototype form data until
-- each module is switched from localStorage to Supabase in the HTML.
create table if not exists public.india_profiles (
  id uuid primary key default gen_random_uuid(),
  company text not null unique,
  profile_type text,
  country text,
  address text,
  contact text,
  email text,
  phone text,
  tax_id text,
  gstin text,
  place_of_supply text,
  status text not null default 'Active',
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create table if not exists public.india_banks (
  id uuid primary key default gen_random_uuid(),
  bank_name text not null,
  beneficiary_name text,
  account_number text,
  swift text,
  ifsc text,
  status text not null default 'Active',
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create table if not exists public.india_receiving_tickets (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid references public.shipments(id) on delete set null,
  shipment_reference text,
  ticket_date date,
  container_number text,
  gross_weight_kg numeric(18,3),
  tare_weight_kg numeric(18,3),
  received_weight_kg numeric(18,3),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create table if not exists public.india_import_documents (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid references public.shipments(id) on delete set null,
  shipment_reference text,
  document_type text not null,
  file_name text,
  storage_path text,
  status text not null default 'Pending',
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create table if not exists public.india_sales_invoices (
  id uuid primary key default gen_random_uuid(),
  invoice_number text not null unique,
  buyer_company text,
  shipment_id uuid references public.shipments(id) on delete set null,
  invoice_date date,
  quantity_kg numeric(18,3),
  amount_inr numeric(18,2),
  paid_inr numeric(18,2) not null default 0,
  status text not null default 'Receivable',
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create table if not exists public.india_sales_payments (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.india_sales_invoices(id) on delete cascade,
  payment_date date,
  amount_inr numeric(18,2) not null check (amount_inr > 0),
  bank text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create table if not exists public.india_order_payments (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid references public.shipments(id) on delete set null,
  shipment_reference text,
  payment_date date,
  currency text not null default 'INR',
  amount numeric(18,2) not null check (amount > 0),
  bank text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create table if not exists public.india_gst_expenses (
  id uuid primary key default gen_random_uuid(),
  supplier_company text,
  tax_invoice_number text,
  expense_date date,
  currency text not null default 'INR',
  total_amount numeric(18,2),
  gst_amount numeric(18,2),
  paid_amount numeric(18,2),
  lines jsonb not null default '[]'::jsonb,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create table if not exists public.india_cash_closings (
  id uuid primary key default gen_random_uuid(),
  bank text,
  period_from date,
  period_to date,
  closing_balance_inr numeric(18,2),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- Authenticated staff may collaborate across the India project. Anonymous
-- users have no module access. Membership must be provisioned by an admin.
do $setup$ declare tbl text; begin
  foreach tbl in array array[
    'india_profiles','india_banks','india_receiving_tickets',
    'india_import_documents','india_sales_invoices','india_sales_payments',
    'india_order_payments','india_gst_expenses','india_cash_closings'
  ] loop
    execute format('alter table public.%I enable row level security',tbl);
    execute format('revoke all on public.%I from anon',tbl);
    execute format('grant select, insert, update, delete on public.%I to authenticated',tbl);
    execute format('create policy %I on public.%I for select to authenticated using (exists (select 1 from public.india_members m where m.user_id = (select auth.uid())))', 'Members read '||tbl,tbl);
    execute format('create policy %I on public.%I for insert to authenticated with check (exists (select 1 from public.india_members m where m.user_id = (select auth.uid())))', 'Members create '||tbl,tbl);
    execute format('create policy %I on public.%I for update to authenticated using (exists (select 1 from public.india_members m where m.user_id = (select auth.uid()))) with check (exists (select 1 from public.india_members m where m.user_id = (select auth.uid())))', 'Members edit '||tbl,tbl);
    execute format('create policy %I on public.%I for delete to authenticated using (exists (select 1 from public.india_members m where m.user_id = (select auth.uid()) and m.role = ''admin''))', 'Admins delete '||tbl,tbl);
  end loop;
end $setup$;

create index if not exists india_receiving_tickets_shipment_idx on public.india_receiving_tickets(shipment_id);
create index if not exists india_import_documents_shipment_idx on public.india_import_documents(shipment_id);
create index if not exists india_sales_payments_invoice_idx on public.india_sales_payments(invoice_id);
