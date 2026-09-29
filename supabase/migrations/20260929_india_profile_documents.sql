-- Private documents for India profile registrations. Keep identity documents out of public URLs.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'india-profile-documents', 'india-profile-documents', false, 10485760,
  array['application/pdf','image/jpeg','image/png','image/webp']
)
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

do $policies$
begin
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='India members read profile documents') then
    create policy "India members read profile documents" on storage.objects
      for select to authenticated
      using (bucket_id = 'india-profile-documents' and exists (
        select 1 from public.india_members m where m.user_id = (select auth.uid())
      ));
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='India members upload profile documents') then
    create policy "India members upload profile documents" on storage.objects
      for insert to authenticated
      with check (bucket_id = 'india-profile-documents' and exists (
        select 1 from public.india_members m where m.user_id = (select auth.uid())
      ));
  end if;
end $policies$;
