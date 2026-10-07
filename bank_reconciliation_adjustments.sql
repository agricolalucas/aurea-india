-- Shared financial expenses, atomic adjustments, and order payments for bank reconciliation.
-- Does not seed, replace or delete invoices, expenses, statements or tickets.
alter table public.india_order_payments add column if not exists bank_id uuid references public.india_banks(id);
alter table public.india_order_payments add column if not exists created_by uuid default auth.uid();
create unique index if not exists india_order_payment_legacy_key on public.india_order_payments((details->>'legacy_id')) where details->>'legacy_id' is not null;
create table if not exists public.india_bank_financial_entries (
 id uuid primary key default gen_random_uuid(),bank_id uuid not null references public.india_banks(id),currency text not null check(currency ~ '^[A-Z]{3}$'),
 entry_date date not null,description text not null check(length(trim(description))>0),reference text not null default '',
 debit numeric(18,2) not null default 0,credit numeric(18,2) not null default 0,
 kind text not null check(kind in ('manual','adjustment')),match_id uuid references public.india_bank_matches(id),
 created_by uuid not null default auth.uid(),created_at timestamptz not null default now(),
 check((debit>0 and credit=0) or (credit>0 and debit=0)),check((kind='manual' and match_id is null) or (kind='adjustment' and match_id is not null))
);
alter table public.india_bank_financial_entries enable row level security;
create policy financial_member_read on public.india_bank_financial_entries for select to authenticated using(exists(select 1 from public.india_members where user_id=(select auth.uid())));
revoke all on public.india_bank_financial_entries from public,anon,authenticated;
grant select on public.india_bank_financial_entries to authenticated;
create index india_bank_financial_entries_bank_idx on public.india_bank_financial_entries(bank_id,currency,entry_date);
create or replace function public.india_bank_system_entries(p_bank uuid,p_currency text) returns setof jsonb language sql stable security invoker set search_path='' as $$
 select x from (
 select jsonb_build_object('id','sales-'||i.id,'date',i.invoice_date,'currency',i.currency,'credit',i.amount_inr,'debit',0,'party',i.buyer_company,'invoice',i.invoice_number,'description',coalesce(i.details->>'product',i.details->>'product_name','')) x from public.india_sales_invoices i where i.currency=p_currency and i.amount_inr>0 and i.status is distinct from 'Cancelled'
 union all
 select jsonb_build_object('id','expense-'||e.id,'date',e.expense_date,'currency',e.currency,'credit',0,'debit',e.total_amount,'party',e.supplier_company,'invoice',e.tax_invoice_number,'gstin',coalesce(e.details->>'gstin',''),'description',coalesce(e.details->>'description','')) from public.india_gst_expenses e where e.currency=p_currency and e.total_amount>0
 union all
 select jsonb_build_object('id','order-'||o.id,'date',o.payment_date,'currency',case when o.currency='USD' and o.details->>'convertedInr' is not null then 'INR' else o.currency end,'credit',0,'debit',case when o.currency='USD' and o.details->>'convertedInr' is not null then (o.details->>'convertedInr')::numeric else o.amount end,'party',coalesce(o.details->>'exporter','Order payment'),'invoice',o.shipment_reference,'description',concat_ws(' · ',o.details->>'bankReference',o.details->>'notes'),'kind','order') from public.india_order_payments o join public.india_banks b on b.id=p_bank where o.amount>0 and (o.bank_id=p_bank or (o.bank_id is null and o.bank in (p_bank::text,concat_ws(' · ',b.bank_name,b.beneficiary_name,case when coalesce(b.account_number,'')<>'' then 'A/C '||b.account_number end,coalesce(nullif(b.swift,''),b.ifsc)),concat_ws(' · ',b.bank_name,b.account_number,b.beneficiary_name)))) and (case when o.currency='USD' and o.details->>'convertedInr' is not null then 'INR' else o.currency end)=p_currency
 union all
 select jsonb_build_object('id','financial-'||f.id,'date',f.entry_date,'currency',f.currency,'credit',f.credit,'debit',f.debit,'party','Financial Expense','invoice',f.reference,'description',f.description,'kind','financial') from public.india_bank_financial_entries f where f.bank_id=p_bank and f.currency=p_currency and f.kind='manual'
 ) entries where exists(select 1 from public.india_members where user_id=(select auth.uid())) and exists(select 1 from public.india_banks where id=p_bank and status is distinct from 'Inactive');
$$;
revoke all on function public.india_bank_system_entries(uuid,text) from public,anon;
grant execute on function public.india_bank_system_entries(uuid,text) to authenticated;
create or replace function india_private.bank_operation(p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); bid uuid:=(p_data->>'bank_id')::uuid; cur text:=p_data->>'currency';op uuid:=(p_data->>'id')::uuid; r jsonb; source jsonb; tid uuid; fp text; inserted integer:=0;skipped integer:=0;bc numeric:=0;bd numeric:=0;sc numeric:=0;sd numeric:=0;ids uuid[];keys text[];bankrow public.india_bank_transactions%rowtype; delta numeric; aid uuid; description text; amount numeric; rate numeric; existing uuid;
begin
 if u is null or not exists(select 1 from public.india_members where user_id=u) then raise exception 'Project membership required';end if;
 if not exists(select 1 from public.india_banks where id=bid and status is distinct from 'Inactive') or cur !~ '^[A-Z]{3}$' then raise exception 'Select an active bank and currency';end if;
 perform pg_advisory_xact_lock(7426270810); -- Shares the payment ledger lock.
 if p_action='financial_save' then
  amount:=(p_data->>'amount')::numeric;description:=trim(coalesce(p_data->>'description',''));
  if amount is null or amount<=0 or amount<>round(amount,2) or description='' or nullif(p_data->>'date','') is null then raise exception 'Date, description and positive amount required';end if;
  if exists(select 1 from public.india_bank_financial_entries where id=op and bank_id=bid) then return jsonb_build_object('id',op,'already_saved',true);end if;
  insert into public.india_bank_financial_entries(id,bank_id,currency,entry_date,description,reference,debit,kind,created_by) values(op,bid,cur,(p_data->>'date')::date,description,coalesce(p_data->>'reference',''),amount,'manual',u);
  return jsonb_build_object('id',op);
 elsif p_action='order_save' then
  select id into existing from public.india_order_payments where details->>'legacy_id'=p_data->>'legacy_id';
  if existing is not null then return jsonb_build_object('id',existing,'already_saved',true);end if;
  amount:=(p_data->>'amountUsd')::numeric;rate:=(p_data->>'usdInrRate')::numeric;
  if amount is null or amount<=0 or amount<>round(amount,2) or rate is null or rate<=0 or nullif(p_data->>'paymentDate','') is null or trim(coalesce(p_data->>'orderRef',''))='' then raise exception 'Complete order, payment date, USD amount and rate';end if;
  insert into public.india_order_payments(id,shipment_reference,payment_date,currency,amount,bank,bank_id,details,created_by) values(op,p_data->>'orderRef',(p_data->>'paymentDate')::date,'USD',amount,bid::text,bid,jsonb_build_object('legacy_id',p_data->>'legacy_id','amountUsd',amount,'usdInrRate',rate,'convertedInr',round(amount*rate,2),'bankReference',coalesce(p_data->>'bankReference',''),'notes',coalesce(p_data->>'notes',''),'exporter',coalesce(p_data->>'exporter',''),'orderDisplay',coalesce(p_data->>'orderDisplay','')),u);
  return jsonb_build_object('id',op);
 elsif p_action='import' then
  if exists(select 1 from public.india_bank_statements where id=op and bank_id=bid) then return jsonb_build_object('already_saved',true);end if;
  if exists(select 1 from public.india_bank_statements where bank_id=bid and file_sha256=p_data->>'file_sha256' and sheet_name=p_data->>'sheet_name') then raise exception 'This original statement file was already imported';end if;
  if not exists(select 1 from storage.objects where bucket_id='india-bank-statements' and name=p_data->>'storage_path' and (storage.foldername(name))[1]=u::text) then raise exception 'Original file must be uploaded before import';end if;
  if jsonb_typeof(p_data->'rows') is distinct from 'array' or jsonb_array_length(p_data->'rows')=0 then raise exception 'No valid transactions selected';end if;
  insert into public.india_bank_statements(id,bank_id,currency,file_name,storage_path,file_sha256,sheet_name,import_options,raw_rows,created_by) values(op,bid,cur,p_data->>'file_name',p_data->>'storage_path',p_data->>'file_sha256',p_data->>'sheet_name',p_data->'options',p_data->'raw_rows',u);
  for r in select value from jsonb_array_elements(p_data->'rows') loop
   if (r->>'debit')::numeric<0 or (r->>'credit')::numeric<0 or round((r->>'debit')::numeric,2)<>(r->>'debit')::numeric or round((r->>'credit')::numeric,2)<>(r->>'credit')::numeric then raise exception 'Invalid debit / credit amount';end if;
   fp:=encode(sha256(convert_to(jsonb_build_array((r->>'date')::date,nullif(r->>'value_date','')::date,lower(regexp_replace(trim(coalesce(r->>'description','')),'\s+',' ','g')),lower(trim(coalesce(r->>'reference',''))),(r->>'debit')::numeric,(r->>'credit')::numeric,nullif(r->>'balance','')::numeric)::text,'UTF8')),'hex');
   tid:=null;
   insert into public.india_bank_transactions(statement_id,bank_id,currency,transaction_date,value_date,description,reference,bank_serial,branch_name,debit,credit,balance,source_row,fingerprint) values(op,bid,cur,(r->>'date')::date,nullif(r->>'value_date','')::date,coalesce(r->>'description',''),coalesce(r->>'reference',''),coalesce(r->>'bank_serial',''),coalesce(r->>'branch_name',''),(r->>'debit')::numeric,(r->>'credit')::numeric,nullif(r->>'balance','')::numeric,(r->>'source_row')::integer,fp) on conflict(bank_id,currency,fingerprint) do nothing returning id into tid;
   if tid is null then skipped:=skipped+1;else inserted:=inserted+1;end if;
  end loop;
  if inserted=0 then raise exception 'All selected transactions already exist; nothing imported';end if;
  return jsonb_build_object('id',op,'imported',inserted,'duplicates_skipped',skipped);
 elsif p_action='match' then
  if exists(select 1 from public.india_bank_matches where id=op and bank_id=bid) then return jsonb_build_object('already_saved',true);end if;
  select array_agg(v::uuid) into ids from jsonb_array_elements_text(p_data->'transaction_ids') v;
  select array_agg(v) into keys from jsonb_array_elements_text(p_data->'system_keys') v;
  if coalesce(cardinality(ids),0)=0 or coalesce(cardinality(keys),0)=0 then raise exception 'Select rows on both sides';end if;
  if cardinality(ids)<>(select count(distinct v) from unnest(ids) v) or cardinality(keys)<>(select count(distinct v) from unnest(keys) v) then raise exception 'Repeated selection';end if;
  -- Lock source records before taking authoritative snapshots.
  perform 1 from public.india_sales_invoices where 'sales-'||id=any(keys) for update;
  perform 1 from public.india_gst_expenses where 'expense-'||id=any(keys) for update;
  perform 1 from public.india_order_payments where 'order-'||id=any(keys) for update;
  perform 1 from public.india_bank_financial_entries where 'financial-'||id=any(keys) for update;
  for bankrow in select * from public.india_bank_transactions where id=any(ids) and bank_id=bid and currency=cur for update loop bc:=bc+bankrow.credit;bd:=bd+bankrow.debit;end loop;
  if (select count(*) from public.india_bank_transactions where id=any(ids) and bank_id=bid and currency=cur)<>cardinality(ids) then raise exception 'Bank transaction unavailable';end if;
  if exists(select 1 from public.india_bank_match_items where transaction_id=any(ids) or system_key=any(keys)) then raise exception 'A selected entry was already reconciled. Refresh the screen';end if;
  for source in select x from public.india_bank_system_entries(bid,cur) x where x->>'id'=any(keys) loop sc:=sc+(source->>'credit')::numeric;sd:=sd+(source->>'debit')::numeric;end loop;
  if (select count(*) from public.india_bank_system_entries(bid,cur) x where x->>'id'=any(keys))<>cardinality(keys) then raise exception 'System entry changed or unavailable. Refresh';end if;
  delta:=round(bc-bd-sc+sd,2);
  if delta<>0 then
   description:=trim(coalesce(p_data->'adjustment'->>'description',''));amount:=(p_data->'adjustment'->>'amount')::numeric;
   if description='' or amount is null or amount<>abs(delta) then raise exception 'Enter a description and the exact difference amount';end if;
  elsif p_data->'adjustment' is not null and p_data->'adjustment'<>'null'::jsonb then raise exception 'No adjustment required when difference is zero';end if;
  insert into public.india_bank_matches(id,bank_id,currency,credit,debit,notes,created_by) values(op,bid,cur,bc,bd,coalesce(p_data->>'notes',''),u);
  insert into public.india_bank_match_items(match_id,side,transaction_id,snapshot) select op,'bank',id,to_jsonb(t) from public.india_bank_transactions t where id=any(ids);
  insert into public.india_bank_match_items(match_id,side,system_key,snapshot) select op,'system',x->>'id',x from public.india_bank_system_entries(bid,cur) x where x->>'id'=any(keys);
  if delta<>0 then
   aid:=gen_random_uuid();
   insert into public.india_bank_financial_entries(id,bank_id,currency,entry_date,description,debit,credit,kind,match_id,created_by) values(aid,bid,cur,(select min(transaction_date) from public.india_bank_transactions where id=any(ids)),description,case when delta<0 then -delta else 0 end,case when delta>0 then delta else 0 end,'adjustment',op,u);
   insert into public.india_bank_match_items(match_id,side,system_key,snapshot) values(op,'system','adjustment-'||aid,jsonb_build_object('id','adjustment-'||aid,'date',(select min(transaction_date) from public.india_bank_transactions where id=any(ids)),'currency',cur,'party','Lançamento avulso','description',description,'invoice','Ajuste de conciliação','credit',case when delta>0 then delta else 0 end,'debit',case when delta<0 then -delta else 0 end));
   update public.india_bank_matches set notes=concat_ws(' / ',nullif(notes,''),'Lançamento avulso: '||description||' · '||case when delta>0 then 'Crédito' else 'Débito' end||' '||abs(delta)::text||' · Diferença final 0.00') where id=op;
  end if;
  return jsonb_build_object('id',op);
 else raise exception 'Unknown bank operation';end if;
end$$;
revoke all on function india_private.bank_operation(text,jsonb) from public,anon;
grant execute on function india_private.bank_operation(text,jsonb) to authenticated;
create or replace function public.india_bank_operation(p_action text,p_data jsonb) returns jsonb language sql security invoker set search_path='' as $$select india_private.bank_operation(p_action,p_data)$$;
revoke all on function public.india_bank_operation(text,jsonb) from public,anon;
grant execute on function public.india_bank_operation(text,jsonb) to authenticated;
