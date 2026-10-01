-- Apply with publication: cancel invoices without deleting records or payment links.
create or replace function india_private.guard_invoice_cancellation()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if old.status = 'Cancelled' then
    raise exception 'Cancelled invoices cannot be changed';
  end if;
  if new.status = 'Cancelled' or coalesce(new.details->>'cancelledAt','') <> '' then
    if coalesce(btrim(new.details->>'cancellationReason'),'') = '' or coalesce(new.details->>'cancelledAt','') = '' then
      raise exception 'Cancellation reason and date are required';
    end if;
    if new.paid_inr > 0 or exists(select 1 from public.india_sales_allocations a where a.invoice_id=new.id and a.deleted_at is null) then
      raise exception 'Remove payment applications before cancelling this invoice';
    end if;
    new.status := 'Cancelled';
  end if;
  return new;
end $$;
revoke all on function india_private.guard_invoice_cancellation() from public, anon, authenticated;
drop trigger if exists zz_india_guard_invoice_cancellation on public.india_sales_invoices;
create trigger zz_india_guard_invoice_cancellation before update on public.india_sales_invoices
for each row execute function india_private.guard_invoice_cancellation();
