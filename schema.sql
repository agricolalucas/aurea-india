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
