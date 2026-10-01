-- Shared receipts and allocations. Existing invoice records are preserved.
create schema if not exists india_private;
revoke all on schema india_private from public,anon;
grant usage on schema india_private to authenticated;
alter table public.india_sales_invoices add column if not exists currency text not null default 'INR';
alter table public.india_sales_invoices add column if not exists legacy_paid_inr numeric(18,2);
create table if not exists public.india_sales_receipts(
 id uuid primary key default gen_random_uuid(), buyer text not null, payment_date date not null,
 amount numeric(18,2) not null check(amount>0), currency text not null check(currency ~ '^[A-Z]{3}$'),
 bank_id uuid not null references public.india_banks(id), description_type text not null check(description_type in ('Advance','Payment','Balance','Cheque')),
 description text not null default '',created_by uuid not null default auth.uid(),created_at timestamptz not null default now(),deleted_at timestamptz);
create table if not exists public.india_sales_allocations(
 id uuid primary key default gen_random_uuid(), invoice_id uuid not null references public.india_sales_invoices(id),
 receipt_id uuid references public.india_sales_receipts(id), amount numeric(18,2) not null check(amount>0),currency text not null,
 payment_date date not null,bank_id uuid not null references public.india_banks(id),description text not null default '',
 operation_id uuid not null,created_by uuid not null default auth.uid(),created_at timestamptz not null default now(),deleted_at timestamptz);
create table if not exists public.india_sales_payment_history(
 id uuid primary key default gen_random_uuid(),record_type text not null,record_id uuid not null,action text not null,
 before_values jsonb,after_values jsonb,actor_id uuid,actor_email text,created_at timestamptz not null default now());
create index if not exists india_sales_allocations_invoice_idx on public.india_sales_allocations(invoice_id);
create index if not exists india_sales_allocations_receipt_idx on public.india_sales_allocations(receipt_id);
create index if not exists india_sales_receipts_bank_idx on public.india_sales_receipts(bank_id);
create index if not exists india_sales_allocations_bank_idx on public.india_sales_allocations(bank_id);
create index if not exists india_payment_history_record_idx on public.india_sales_payment_history(record_type,record_id);
alter table public.india_sales_receipts enable row level security;
alter table public.india_sales_allocations enable row level security;
alter table public.india_sales_payment_history enable row level security;
create policy india_receipts_member_read on public.india_sales_receipts for select to authenticated using(exists(select 1 from public.india_members where user_id=(select auth.uid())));
create policy india_allocations_member_read on public.india_sales_allocations for select to authenticated using(exists(select 1 from public.india_members where user_id=(select auth.uid())));
create policy india_payment_history_member_read on public.india_sales_payment_history for select to authenticated using(exists(select 1 from public.india_members where user_id=(select auth.uid())));
revoke all on public.india_sales_receipts,public.india_sales_allocations,public.india_sales_payment_history from anon,authenticated;
grant select on public.india_sales_receipts,public.india_sales_allocations,public.india_sales_payment_history to authenticated;
-- Writes are encapsulated to enforce balances and preserve immutable history.
create or replace function india_private.sales_payment_operation(p_action text,p_data jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); inv public.india_sales_invoices%rowtype; rec public.india_sales_receipts%rowtype;
 oldrec jsonb; newrec jsonb; rid uuid; aid uuid; iid uuid; op uuid; rowdata jsonb; applied numeric; credit numeric; val numeric; used numeric; ids uuid[]:='{}'; result_ids uuid[]:='{}'; actor text;
begin
 if u is null or not exists(select 1 from public.india_members where user_id=u) then raise exception 'Project membership required';end if;
 select email into actor from auth.users where id=u;
 perform pg_advisory_xact_lock(7426270810);
 if p_action in ('receipt_save','receipt_delete') then
  rid:=nullif(p_data->>'id','')::uuid;
  if rid is not null then select * into rec from public.india_sales_receipts where id=rid and deleted_at is null for update;if not found then raise exception 'Receipt unavailable';end if;oldrec:=to_jsonb(rec);end if;
  select coalesce(sum(amount),0) into used from public.india_sales_allocations where receipt_id=rid and deleted_at is null;
  if p_action='receipt_delete' then
   if used>0 then raise exception 'Remove linked applications before deleting this advance';end if;
   update public.india_sales_receipts set deleted_at=now() where id=rid returning to_jsonb(india_sales_receipts.*) into newrec;
  else
   val:=(p_data->>'amount')::numeric;
   if val<=0 or round(val,2)<>val then raise exception 'Payment amount must be positive with at most 2 decimals';end if;
   if val<used then raise exception 'Advance cannot be reduced below applied amount';end if;
   if used>0 and (rec.buyer is distinct from p_data->>'buyer' or rec.currency is distinct from p_data->>'currency') then raise exception 'Buyer and currency cannot change while invoices are linked';end if;
   if not exists(select 1 from public.india_profiles where company=p_data->>'buyer') then raise exception 'Select a registered buyer';end if;
   if not exists(select 1 from public.india_banks where id=(p_data->>'bank_id')::uuid and status is distinct from 'Inactive') then raise exception 'Select an active payment bank';end if;
   if rid is null then
    insert into public.india_sales_receipts(buyer,payment_date,amount,currency,bank_id,description_type,description,created_by) values(p_data->>'buyer',(p_data->>'payment_date')::date,val,p_data->>'currency',(p_data->>'bank_id')::uuid,p_data->>'description_type',coalesce(p_data->>'description',''),u) returning id,to_jsonb(india_sales_receipts.*) into rid,newrec;
   else
    update public.india_sales_receipts set buyer=p_data->>'buyer',payment_date=(p_data->>'payment_date')::date,amount=val,currency=p_data->>'currency',bank_id=(p_data->>'bank_id')::uuid,description_type=p_data->>'description_type',description=coalesce(p_data->>'description','') where id=rid returning to_jsonb(india_sales_receipts.*) into newrec;
   end if;
  end if;
  insert into public.india_sales_payment_history(record_type,record_id,action,before_values,after_values,actor_id,actor_email) values('receipt',rid,p_action,oldrec,newrec,u,actor);
  return jsonb_build_object('id',rid);
 elsif p_action='batch' then
  op:=(p_data->>'operation_id')::uuid;
  if exists(select 1 from public.india_sales_allocations where operation_id=op) then return jsonb_build_object('already_saved',true);end if;
  if jsonb_typeof(p_data->'rows')<>'array' or jsonb_array_length(p_data->'rows')=0 then raise exception 'Select invoices and amounts';end if;
 elsif p_action in ('allocation_save','allocation_delete') then
  aid:=(p_data->>'id')::uuid;
  select to_jsonb(a),a.invoice_id into oldrec,iid from public.india_sales_allocations a where a.id=aid and deleted_at is null for update;
  if not found then raise exception 'Payment unavailable';end if;
  ids:=array_append(ids,iid);
  if p_action='allocation_delete' then
   update public.india_sales_allocations set deleted_at=now() where id=aid returning to_jsonb(india_sales_allocations.*) into newrec;
   insert into public.india_sales_payment_history(record_type,record_id,action,before_values,after_values,actor_id,actor_email) values('allocation',aid,p_action,oldrec,newrec,u,actor);
  else p_data:=jsonb_build_object('rows',jsonb_build_array(p_data||jsonb_build_object('invoice_id',iid,'receipt_id',oldrec->'receipt_id','currency',oldrec->'currency')));end if;
 else raise exception 'Unknown payment operation';end if;
 if p_action<>'allocation_delete' then
  for rowdata in select value from jsonb_array_elements(p_data->'rows') loop
   iid:=(rowdata->>'invoice_id')::uuid;rid:=nullif(rowdata->>'receipt_id','')::uuid;val:=(rowdata->>'amount')::numeric;
   if val<=0 or round(val,2)<>val then raise exception 'Applied amount must be positive with at most 2 decimals';end if;
   select * into inv from public.india_sales_invoices where id=iid for update;
   if not found then raise exception 'Invoice unavailable';end if;
   if inv.currency is distinct from rowdata->>'currency' then raise exception 'Invoice and payment currencies must match';end if;
   if inv.legacy_paid_inr is null then update public.india_sales_invoices set legacy_paid_inr=paid_inr where id=iid;inv.legacy_paid_inr:=inv.paid_inr;end if;
   select coalesce(sum(amount),0) into applied from public.india_sales_allocations where invoice_id=iid and deleted_at is null and id is distinct from aid;
   if val>inv.amount_inr-inv.legacy_paid_inr-applied then raise exception 'Payment exceeds invoice balance: %',inv.invoice_number;end if;
   if rid is not null then
    select * into rec from public.india_sales_receipts where id=rid and deleted_at is null for update;
    if not found or rec.buyer is distinct from inv.buyer_company or rec.currency is distinct from inv.currency then raise exception 'Advance buyer and currency must match invoice';end if;
    select coalesce(sum(amount),0) into used from public.india_sales_allocations where receipt_id=rid and deleted_at is null and id is distinct from aid;
    if used+val>rec.amount then raise exception 'Applications exceed remaining advance';end if;
    if p_action='batch' then rowdata:=rowdata||jsonb_build_object('bank_id',rec.bank_id);end if;
   end if;
   if not exists(select 1 from public.india_banks where id=(rowdata->>'bank_id')::uuid) then raise exception 'Payment bank required';end if;
   if p_action='allocation_save' then
    update public.india_sales_allocations set amount=val,payment_date=(rowdata->>'payment_date')::date,bank_id=(rowdata->>'bank_id')::uuid,description=coalesce(rowdata->>'description','') where id=aid returning to_jsonb(india_sales_allocations.*) into newrec;
   else
    insert into public.india_sales_allocations(invoice_id,receipt_id,amount,currency,payment_date,bank_id,description,operation_id,created_by) values(iid,rid,val,inv.currency,(rowdata->>'payment_date')::date,(rowdata->>'bank_id')::uuid,coalesce(rowdata->>'description',''),op,u) returning id,to_jsonb(india_sales_allocations.*) into aid,newrec;
   end if;
   insert into public.india_sales_payment_history(record_type,record_id,action,before_values,after_values,actor_id,actor_email) values('allocation',aid,p_action,case when p_action='allocation_save' then oldrec end,newrec,u,actor);
   result_ids:=array_append(result_ids,aid);ids:=array_append(ids,iid);if p_action='batch' then aid:=null;end if;
  end loop;
 end if;
 for iid in select distinct unnest(ids) loop
  update public.india_sales_invoices i set paid_inr=coalesce(i.legacy_paid_inr,0)+(select coalesce(sum(a.amount),0) from public.india_sales_allocations a where a.invoice_id=i.id and a.deleted_at is null),status=case when coalesce(i.legacy_paid_inr,0)+(select coalesce(sum(a.amount),0) from public.india_sales_allocations a where a.invoice_id=i.id and a.deleted_at is null)>=i.amount_inr then 'Paid' when coalesce(i.legacy_paid_inr,0)+(select coalesce(sum(a.amount),0) from public.india_sales_allocations a where a.invoice_id=i.id and a.deleted_at is null)>0 then 'Partially Paid' else 'Pending' end where i.id=iid;
 end loop;
 return jsonb_build_object('ids',result_ids);
end;$$;
revoke all on function india_private.sales_payment_operation(text,jsonb) from public,anon;
grant execute on function india_private.sales_payment_operation(text,jsonb) to authenticated;
create or replace function public.india_sales_payment_operation(p_action text,p_data jsonb) returns jsonb language sql security invoker set search_path='' as $$select india_private.sales_payment_operation(p_action,p_data);$$;
revoke all on function public.india_sales_payment_operation(text,jsonb) from public,anon;
grant execute on function public.india_sales_payment_operation(text,jsonb) to authenticated;
-- Prevent invoice edits from invalidating allocated payments or overwriting the ledger balance.
create or replace function india_private.guard_sales_invoice() returns trigger language plpgsql security invoker set search_path='' as $$
declare applied numeric;
begin
 if current_user in ('authenticated','anon') and new.legacy_paid_inr is distinct from old.legacy_paid_inr then raise exception 'Legacy payment balance is managed by the payment ledger';end if;
 if new.legacy_paid_inr<0 then raise exception 'Legacy paid amount cannot be negative';end if;
 select coalesce(sum(amount),0) into applied from public.india_sales_allocations where invoice_id=old.id and deleted_at is null;
 if applied>0 and (new.buyer_company is distinct from old.buyer_company or new.currency is distinct from old.currency) then raise exception 'Buyer and currency cannot change while payments are linked';end if;
 if new.legacy_paid_inr is not null then new.paid_inr:=new.legacy_paid_inr+applied;
  if new.amount_inr<new.paid_inr then raise exception 'Invoice total cannot be below linked payments';end if;
  new.status:=case when new.paid_inr>=new.amount_inr then 'Paid' when new.paid_inr>0 then 'Partially Paid' else 'Pending' end;
 end if;
 return new;
end;$$;
revoke all on function india_private.guard_sales_invoice() from public,anon,authenticated;
create trigger india_guard_sales_invoice before update on public.india_sales_invoices for each row execute function india_private.guard_sales_invoice();
