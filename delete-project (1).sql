-- Workclay: make project deletion work. Run ONCE in Supabase -> SQL Editor (safe to re-run).
do $$
declare r record; oc text;
begin
  -- 1) Deleting a project (or milestone) also deletes everything linked to it
  for r in
    select c.conname, c.conrelid::regclass as tbl, a.attname as col, c.confrelid::regclass as ref
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
    where c.contype = 'f' and array_length(c.conkey,1) = 1
      and c.confrelid in ('public.projects'::regclass, 'public.milestones'::regclass)
  loop
    execute format('alter table %s drop constraint %I', r.tbl, r.conname);
    execute format('alter table %s add constraint %I foreign key (%I) references %s(id) on delete cascade',
                   r.tbl, r.conname, r.col, r.ref);
  end loop;

  -- 2) Let a project's owner delete it
  select column_name into oc from information_schema.columns
   where table_schema='public' and table_name='projects'
     and column_name in ('owner','owner_id','created_by','user_id') limit 1;
  if oc is null then raise exception 'No owner column found on projects - tell me its column name'; end if;
  execute 'drop policy if exists "owner deletes projects" on public.projects';
  execute format('create policy "owner deletes projects" on public.projects for delete using (%I = auth.uid())', oc);
end $$;
