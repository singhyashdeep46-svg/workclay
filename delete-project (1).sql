-- Workclay: allow project owners to delete their projects. Run once in Supabase -> SQL Editor.
do $$
declare c text;
begin
  select column_name into c from information_schema.columns
   where table_schema='public' and table_name='projects'
     and column_name in ('owner','owner_id','created_by','user_id') limit 1;
  if c is null then raise exception 'No owner column found on projects; tell me the column name'; end if;
  execute 'drop policy if exists "owner deletes projects" on public.projects';
  execute format('create policy "owner deletes projects" on public.projects for delete using (%I = auth.uid())', c);
end $$;
