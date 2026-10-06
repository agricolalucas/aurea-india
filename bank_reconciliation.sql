-- Immutable original statements, normalized transactions and many-to-many reconciliation.
-- Additive: no existing invoices, payments, expenses or receiving tickets are modified.
create table public.india_bank_statements (
 id uuid primary key, bank_id uuid not null references public.india_banks(id),currency text not null check(currency ~ '^[A-Z]{3}$'),
 file_name text not null,storage_path text not null unique,file_sha256 text not null check(file_sha256 ~ '^[a-f0-9]{64}$'),
 sheet_name text not null,import_options jsonb not null,raw_rows jsonb not null,created_by uuid not null default auth.uid(),created_at timestamptz not null default now(),unique(bank_id,file_sha256,sheet_name)
);
create table public.india_bank_transactions (
 id uuid primary key default gen_random_uuid(),statement_id uuid not null references public.india_bank_statements(id),bank_id uuid not null references public.india_banks(id),currency text not null,
 transaction_date date not null,value_date date,description text not null default '',reference text not null default '',bank_serial text not null default '',branch_name text not null default '',
 debit numeric(18,2) not null default 0,credit numeric(18,2) not null default 0,balance numeric(18,2),source_row integer not null check(source_row>0),
 fingerprint text not null,created_at timestamptz not null default now(),check((debit>0 and credit=0) or (credit>0 and debit=0)),unique(bank_id,currency,fingerprint)
);
create index india_bank_transactions_statement_idx on public.india_bank_transactions(statement_id);
create index india_bank_transactions_date_idx on public.india_bank_transactions(bank_id,transaction_date);
create table public.india_bank_matches (
 id uuid primary key,bank_id uuid not null references public.india_banks(id),currency text not null,credit numeric(18,2) not null,debit numeric(18,2) not null,
 notes text not null default '',created_by uuid not null default auth.uid(),created_at timestamptz not null default now()
);
create table public.india_bank_match_items (
 id uuid primary key default gen_random_uuid(),match_id uuid not null references public.india_bank_matches(id),side text not null check(side in ('bank','system')),
 transaction_id uuid references public.india_bank_transactions(id),system_key text, snapshot jsonb not null,
 check((side='bank' and transaction_id is not null and system_key is null) or (side='system' and transaction_id is null and system_key is not null)),unique(transaction_id),unique(system_key)
);
create index india_bank_match_items_match_idx on public.india_bank_match_items(match_id);
do $$declare t text;begin foreach t in array array['india_bank_statements','india_bank_transactions','india_bank_matches','india_bank_match_items'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('create policy bank_member_read on public.%I for select to authenticated using(exists(select 1 from public.india_members where user_id=(select auth.uid())))',t);
 execute format('revoke all on public.%I from anon,authenticated',t);execute format('grant select on public.%I to authenticated',t);
end loop;end$$;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('india-bank-statements','india-bank-statements',false,20971520,array['application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','application/vnd.ms-excel','text/csv','application/octet-stream']);
create policy bank_statements_read on storage.objects for select to authenticated using(bucket_id='india-bank-statements' and exists(select 1 from public.india_members where user_id=(select auth.uid())));
create policy bank_statements_upload on storage.objects for insert to authenticated with check(bucket_id='india-bank-statements' and (storage.foldername(name))[1]=(select auth.uid())::text and exists(select 1 from public.india_members where user_id=(select auth.uid())));
-- No overwrite or delete policy: original bytes remain available for audit.
create or replace function public.india_bank_system_entries(p_bank uuid,p_currency text) returns setof jsonb language sql stable security invoker set search_path='' as $$
 select x from (
 select jsonb_build_object('id','sales-'||i.id,'date',i.invoice_date,'currency',i.currency,'credit',i.amount_inr,'debit',0,'party',i.buyer_company,'invoice',i.invoice_number,'description',coalesce(i.details->>'product',i.details->>'product_name','')) x from public.india_sales_invoices i where i.currency=p_currency and i.amount_inr>0 and i.status is distinct from 'Cancelled'
 union all
 select jsonb_build_object('id','expense-'||e.id,'date',e.expense_date,'currency',e.currency,'credit',0,'debit',e.total_amount,'party',e.supplier_company,'invoice',e.tax_invoice_number,'gstin',coalesce(e.details->>'gstin',''),'description',coalesce(e.details->>'description','')) from public.india_gst_expenses e where e.currency=p_currency and e.total_amount>0
 ) entries where exists(select 1 from public.india_members where user_id=(select auth.uid())) and exists(select 1 from public.india_banks where id=p_bank and status is distinct from 'Inactive');
$$;
revoke all on function public.india_bank_system_entries(uuid,text) from public,anon;
grant execute on function public.india_bank_system_entries(uuid,text) to authenticated;
create or replace function india_private.bank_operation(p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); bid uuid:=(p_data->>'bank_id')::uuid; cur text:=p_data->>'currency';op uuid:=(p_data->>'id')::uuid; r jsonb; source jsonb; tid uuid; fp text; inserted integer:=0;skipped integer:=0;bc numeric:=0;bd numeric:=0;sc numeric:=0;sd numeric:=0;ids uuid[];keys text[];bankrow public.india_bank_transactions%rowtype;
begin
 if u is null or not exists(select 1 from public.india_members where user_id=u) then raise exception 'Project membership required';end if;
 if not exists(select 1 from public.india_banks where id=bid and status is distinct from 'Inactive') or cur !~ '^[A-Z]{3}$' then raise exception 'Select an active bank and currency';end if;
 perform pg_advisory_xact_lock(7426270810); -- Shares the payment ledger lock.
 if p_action='import' then
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
  for bankrow in select * from public.india_bank_transactions where id=any(ids) and bank_id=bid and currency=cur for update loop bc:=bc+bankrow.credit;bd:=bd+bankrow.debit;end loop;
  if (select count(*) from public.india_bank_transactions where id=any(ids) and bank_id=bid and currency=cur)<>cardinality(ids) then raise exception 'Bank transaction unavailable';end if;
  if exists(select 1 from public.india_bank_match_items where transaction_id=any(ids) or system_key=any(keys)) then raise exception 'A selected entry was already reconciled. Refresh the screen';end if;
  for source in select x from public.india_bank_system_entries(bid,cur) x where x->>'id'=any(keys) loop sc:=sc+(source->>'credit')::numeric;sd:=sd+(source->>'debit')::numeric;end loop;
  if (select count(*) from public.india_bank_system_entries(bid,cur) x where x->>'id'=any(keys))<>cardinality(keys) then raise exception 'System entry changed or unavailable. Refresh';end if;
  if bc<>sc or bd<>sd then raise exception 'Selected credits and debits must match separately';end if;
  insert into public.india_bank_matches(id,bank_id,currency,credit,debit,notes,created_by) values(op,bid,cur,bc,bd,coalesce(p_data->>'notes',''),u);
  insert into public.india_bank_match_items(match_id,side,transaction_id,snapshot) select op,'bank',id,to_jsonb(t) from public.india_bank_transactions t where id=any(ids);
  insert into public.india_bank_match_items(match_id,side,system_key,snapshot) select op,'system',x->>'id',x from public.india_bank_system_entries(bid,cur) x where x->>'id'=any(keys);
  return jsonb_build_object('id',op);
 else raise exception 'Unknown bank operation';end if;
end$$;
revoke all on function india_private.bank_operation(text,jsonb) from public,anon;
grant execute on function india_private.bank_operation(text,jsonb) to authenticated;
create or replace function public.india_bank_operation(p_action text,p_data jsonb) returns jsonb language sql security invoker set search_path='' as $$select india_private.bank_operation(p_action,p_data)$$;
revoke all on function public.india_bank_operation(text,jsonb) from public,anon;
grant execute on function public.india_bank_operation(text,jsonb) to authenticated;
