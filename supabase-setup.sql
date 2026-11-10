-- Muhit Store POS cloud storage setup
-- Run this entire script in Supabase Dashboard -> SQL Editor -> New query -> Run.
create table if not exists public.pos_store_data (
  user_id uuid primary key references auth.users(id) on delete cascade,
  payload jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.pos_store_data enable row level security;
drop policy if exists "Users can read their own POS data" on public.pos_store_data;
create policy "Users can read their own POS data"
on public.pos_store_data for select to authenticated
using (auth.uid() = user_id);
drop policy if exists "Users can insert their own POS data" on public.pos_store_data;
create policy "Users can insert their own POS data"
on public.pos_store_data for insert to authenticated
with check (auth.uid() = user_id);
drop policy if exists "Users can update their own POS data" on public.pos_store_data;
create policy "Users can update their own POS data"
on public.pos_store_data for update to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);
