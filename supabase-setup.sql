-- WORKCLAY: one-time setup. Paste into Supabase > SQL Editor > Run.
-- Safe to re-run: it only creates what is missing and replaces policies named wc_*.

create extension if not exists pgcrypto;

-- ---------- tables ----------
create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  client_name text,
  due date,
  owner uuid not null default auth.uid(),
  created_at timestamptz not null default now()
);
create table if not exists public.project_members (
  project_id uuid not null references public.projects(id) on delete cascade,
  email text not null,
  created_at timestamptz not null default now(),
  primary key (project_id, email)
);
create table if not exists public.milestones (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  title text not null,
  due date,
  done boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists public.files (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  name text not null,
  path text not null,
  created_at timestamptz not null default now()
);
create table if not exists public.invoices (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  number text not null,
  amount numeric not null default 0,
  due date,
  status text not null default 'Draft',
  created_at timestamptz not null default now()
);

-- columns the app uses (added if an older setup missed them)
alter table public.milestones add column if not exists due date;
alter table public.milestones add column if not exists done boolean not null default false;
alter table public.files add column if not exists size_label text;
alter table public.files add column if not exists type text;
alter table public.files add column if not exists title text;
alter table public.files add column if not exists note text;
alter table public.files add column if not exists milestone_id uuid references public.milestones(id) on delete set null;
alter table public.files add column if not exists sent_to text;
alter table public.files add column if not exists status text not null default 'Review';
alter table public.files add column if not exists uploaded_by uuid default auth.uid();
alter table public.invoices add column if not exists details jsonb not null default '{}'::jsonb;
alter table public.invoices add column if not exists issue_date date default current_date;

-- ---------- helpers ----------
create or replace function public.wc_is_owner(pid uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from public.projects where id = pid and owner = auth.uid()) $$;

create or replace function public.wc_is_member(pid uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from public.project_members
   where project_id = pid and lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))) $$;

-- client taps "I have paid"
create or replace function public.report_payment(inv uuid) returns void
language plpgsql security definer set search_path = public as
$$ begin
  update public.invoices i set status = 'Pending'
  where i.id = inv and i.status in ('Sent', 'Overdue') and public.wc_is_member(i.project_id);
end $$;

-- ---------- row level security ----------
alter table public.projects enable row level security;
alter table public.project_members enable row level security;
alter table public.milestones enable row level security;
alter table public.files enable row level security;
alter table public.invoices enable row level security;

drop policy if exists wc_projects_sel on public.projects;
drop policy if exists wc_projects_ins on public.projects;
drop policy if exists wc_projects_upd on public.projects;
drop policy if exists wc_projects_del on public.projects;
create policy wc_projects_sel on public.projects for select using (owner = auth.uid() or public.wc_is_member(id));
create policy wc_projects_ins on public.projects for insert with check (owner = auth.uid());
create policy wc_projects_upd on public.projects for update using (owner = auth.uid());
create policy wc_projects_del on public.projects for delete using (owner = auth.uid());

drop policy if exists wc_members_sel on public.project_members;
drop policy if exists wc_members_ins on public.project_members;
drop policy if exists wc_members_del on public.project_members;
create policy wc_members_sel on public.project_members for select
  using (public.wc_is_owner(project_id) or lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));
create policy wc_members_ins on public.project_members for insert with check (public.wc_is_owner(project_id));
create policy wc_members_del on public.project_members for delete using (public.wc_is_owner(project_id));

drop policy if exists wc_ms_sel on public.milestones;
drop policy if exists wc_ms_ins on public.milestones;
drop policy if exists wc_ms_upd on public.milestones;
drop policy if exists wc_ms_del on public.milestones;
create policy wc_ms_sel on public.milestones for select using (public.wc_is_owner(project_id) or public.wc_is_member(project_id));
create policy wc_ms_ins on public.milestones for insert with check (public.wc_is_owner(project_id));
create policy wc_ms_upd on public.milestones for update using (public.wc_is_owner(project_id));
create policy wc_ms_del on public.milestones for delete using (public.wc_is_owner(project_id));

drop policy if exists wc_files_sel on public.files;
drop policy if exists wc_files_ins on public.files;
drop policy if exists wc_files_upd on public.files;
drop policy if exists wc_files_del on public.files;
create policy wc_files_sel on public.files for select using (public.wc_is_owner(project_id) or public.wc_is_member(project_id));
create policy wc_files_ins on public.files for insert with check (public.wc_is_owner(project_id));
create policy wc_files_upd on public.files for update using (public.wc_is_owner(project_id) or public.wc_is_member(project_id));  -- clients approve / request changes
create policy wc_files_del on public.files for delete using (public.wc_is_owner(project_id));

drop policy if exists wc_inv_sel on public.invoices;
drop policy if exists wc_inv_ins on public.invoices;
drop policy if exists wc_inv_upd on public.invoices;
drop policy if exists wc_inv_del on public.invoices;
create policy wc_inv_sel on public.invoices for select
  using (public.wc_is_owner(project_id) or (public.wc_is_member(project_id) and status <> 'Draft'));
create policy wc_inv_ins on public.invoices for insert with check (public.wc_is_owner(project_id));
create policy wc_inv_upd on public.invoices for update using (public.wc_is_owner(project_id));
create policy wc_inv_del on public.invoices for delete using (public.wc_is_owner(project_id));

-- ---------- file storage (private bucket, folder = project id) ----------
insert into storage.buckets (id, name, public) values ('project-files', 'project-files', false)
on conflict (id) do nothing;

drop policy if exists wc_obj_sel on storage.objects;
drop policy if exists wc_obj_ins on storage.objects;
drop policy if exists wc_obj_del on storage.objects;
create policy wc_obj_sel on storage.objects for select to authenticated
  using (bucket_id = 'project-files' and (public.wc_is_owner(((storage.foldername(name))[1])::uuid)
      or public.wc_is_member(((storage.foldername(name))[1])::uuid)));
create policy wc_obj_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'project-files' and public.wc_is_owner(((storage.foldername(name))[1])::uuid));
create policy wc_obj_del on storage.objects for delete to authenticated
  using (bucket_id = 'project-files' and public.wc_is_owner(((storage.foldername(name))[1])::uuid));

-- ================= v2 additions: payments, messages, archive =================
alter table public.projects add column if not exists archived boolean not null default false;
alter table public.milestones add column if not exists amount numeric;

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  body text not null,
  sender uuid default auth.uid(),
  sender_email text default (auth.jwt() ->> 'email'),
  created_at timestamptz not null default now()
);
alter table public.messages enable row level security;
drop policy if exists wc_msg_sel on public.messages;
drop policy if exists wc_msg_ins on public.messages;
create policy wc_msg_sel on public.messages for select using (public.wc_is_owner(project_id) or public.wc_is_member(project_id));
create policy wc_msg_ins on public.messages for insert with check (public.wc_is_owner(project_id) or public.wc_is_member(project_id));

-- how freelancers get paid: Razorpay link, UPI ID/number, QR image, bank details
create table if not exists public.payment_settings (
  owner uuid primary key default auth.uid(),
  name text,
  razorpay_link text,
  upi_id text,
  upi_phone text,
  qr text,
  bank jsonb,
  updated_at timestamptz not null default now()
);
alter table public.payment_settings enable row level security;
drop policy if exists wc_ps_own on public.payment_settings;
drop policy if exists wc_ps_sel on public.payment_settings;
create policy wc_ps_own on public.payment_settings for all using (owner = auth.uid()) with check (owner = auth.uid());
-- clients can read the payment details of freelancers who shared a project with them
create policy wc_ps_sel on public.payment_settings for select using (
  exists (select 1 from public.projects p join public.project_members m on m.project_id = p.id
          where p.owner = payment_settings.owner and lower(m.email) = lower(coalesce(auth.jwt() ->> 'email', ''))));

-- ================= v3 additions: Stripe/PayPal links, drafts, delete account =================
alter table public.payment_settings add column if not exists stripe_link text;
alter table public.payment_settings add column if not exists paypal_link text;

-- clients must not see deliverables saved as Draft
drop policy if exists wc_files_sel on public.files;
create policy wc_files_sel on public.files for select using (
  public.wc_is_owner(project_id) or (public.wc_is_member(project_id) and coalesce(status, '') <> 'Draft'));

-- lets a signed-in user delete their own account and everything they own
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as
$$ begin
  delete from public.projects where owner = auth.uid();          -- cascades to milestones, files, invoices, messages, members
  delete from public.payment_settings where owner = auth.uid();
  delete from auth.users where id = auth.uid();
end $$;
revoke all on function public.delete_my_account() from public;
grant execute on function public.delete_my_account() to authenticated;
