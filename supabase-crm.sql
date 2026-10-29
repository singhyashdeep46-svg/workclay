-- Workclay CRM: run once in Supabase -> SQL Editor
create table if not exists public.crm_leads (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null default auth.uid() references auth.users(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.crm_leads enable row level security;
drop policy if exists "owner manages own leads" on public.crm_leads;
create policy "owner manages own leads" on public.crm_leads
  for all using (owner = auth.uid()) with check (owner = auth.uid());
