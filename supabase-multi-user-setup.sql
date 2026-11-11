-- Shared-store accounts for General Store POS
-- Run this entire file in Supabase SQL Editor AFTER the existing pos_store_data table exists.
-- Existing pos_store_data rows are treated as the original Admin accounts.

create table if not exists public.pos_store_members (
  store_id uuid not null,
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('admin','cashier')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create index if not exists pos_store_members_store_idx
  on public.pos_store_members(store_id);

insert into public.pos_store_members(store_id,user_id,role,active)
select user_id,user_id,'admin',true
from public.pos_store_data
on conflict (user_id) do update
set store_id=excluded.store_id, role='admin', active=true;

alter table public.pos_store_members enable row level security;

drop policy if exists "pos members read own" on public.pos_store_members;
create policy "pos members read own" on public.pos_store_members
for select to authenticated using (user_id = auth.uid());

create or replace function public.pos_get_my_membership()
returns table(store_id uuid, role text, active boolean)
language sql
security definer
set search_path = public
as $$
  select m.store_id,m.role,m.active
  from public.pos_store_members m
  where m.user_id = auth.uid()
  limit 1;
$$;

create or replace function public.pos_list_store_members()
returns table(user_id uuid,email text,role text,active boolean,created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare v_store uuid;
begin
  select m.store_id into v_store
  from public.pos_store_members m
  where m.user_id=auth.uid() and m.role='admin' and m.active=true;
  if v_store is null then raise exception 'Admin permission required'; end if;
  return query
    select m.user_id,u.email::text,m.role,m.active,m.created_at
    from public.pos_store_members m
    join auth.users u on u.id=m.user_id
    where m.store_id=v_store
    order by case when m.role='admin' then 0 else 1 end,m.created_at;
end;
$$;

create or replace function public.pos_add_cashier(p_email text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_store uuid; v_user uuid;
begin
  select m.store_id into v_store
  from public.pos_store_members m
  where m.user_id=auth.uid() and m.role='admin' and m.active=true;
  if v_store is null then raise exception 'Admin permission required'; end if;
  select id into v_user from auth.users where lower(email)=lower(trim(p_email)) limit 1;
  if v_user is null then raise exception 'No registered account found for this email. Ask the cashier to create an account first.'; end if;
  if v_user=v_store then raise exception 'Admin account cannot be added as cashier'; end if;
  insert into public.pos_store_members(store_id,user_id,role,active)
  values(v_store,v_user,'cashier',true)
  on conflict(user_id) do update set store_id=excluded.store_id,role='cashier',active=true;
  return v_user;
end;
$$;

create or replace function public.pos_set_cashier_active(p_user_id uuid,p_active boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_store uuid;
begin
  select m.store_id into v_store
  from public.pos_store_members m
  where m.user_id=auth.uid() and m.role='admin' and m.active=true;
  if v_store is null then raise exception 'Admin permission required'; end if;
  update public.pos_store_members
  set active=p_active
  where user_id=p_user_id and store_id=v_store and role='cashier';
  if not found then raise exception 'Cashier account not found'; end if;
end;
$$;

grant execute on function public.pos_get_my_membership() to authenticated;
grant execute on function public.pos_list_store_members() to authenticated;
grant execute on function public.pos_add_cashier(text) to authenticated;
grant execute on function public.pos_set_cashier_active(uuid,boolean) to authenticated;

-- The POS stores the entire shop dataset in one row. Members share that row.
-- Remove older per-user policies so the membership-based policies are authoritative.
do $$
declare p record;
begin
  for p in
    select policyname from pg_policies
    where schemaname='public' and tablename='pos_store_data'
  loop
    execute format('drop policy if exists %I on public.pos_store_data',p.policyname);
  end loop;
end $$;

alter table public.pos_store_data enable row level security;

create or replace function public.pos_current_store_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select m.store_id from public.pos_store_members m
  where m.user_id=auth.uid() and m.active=true
  limit 1;
$$;

create policy "pos members read shared store"
on public.pos_store_data for select to authenticated
using (user_id = public.pos_current_store_id());

create policy "pos members insert shared store"
on public.pos_store_data for insert to authenticated
with check (user_id = public.pos_current_store_id());

create policy "pos members update shared store"
on public.pos_store_data for update to authenticated
using (user_id = public.pos_current_store_id())
with check (user_id = public.pos_current_store_id());

grant select,insert,update on public.pos_store_data to authenticated;
