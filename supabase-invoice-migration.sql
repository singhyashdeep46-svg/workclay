-- Run once in Supabase > SQL Editor. Lets invoices store line items, GST, terms and issue date.
alter table public.invoices add column if not exists details jsonb not null default '{}'::jsonb;
alter table public.invoices add column if not exists issue_date date default current_date;
