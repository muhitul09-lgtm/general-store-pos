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
  on conflict(user_id) do nothing;
  if not exists(select 1 from public.pos_store_members where user_id=v_user and store_id=v_store) then
    raise exception 'This account is already linked to another store';
  end if;
  update public.pos_store_members set active=true,role='cashier'
  where user_id=v_user and store_id=v_store;
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


-- Cashier write guard: a cashier may only append new sales and reduce stock
-- by the quantities in those new sales. All other payload fields stay unchanged.
create or replace function public.pos_guard_cashier_store_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_old_count integer;
  v_new_count integer;
  v_prefix jsonb;
  v_expected numeric;
  v_old_product jsonb;
  v_new_product jsonb;
  v_i integer;
begin
  select m.role into v_role
  from public.pos_store_members m
  where m.user_id=auth.uid() and m.store_id=old.user_id and m.active=true;

  if v_role='cashier' then
    if (new.payload - array['sales','products','nextInvoice']) is distinct from
       (old.payload - array['sales','products','nextInvoice']) then
      raise exception 'Cashier permission: only billing sales and stock deduction are allowed';
    end if;

    v_old_count := jsonb_array_length(coalesce(old.payload->'sales','[]'::jsonb));
    v_new_count := jsonb_array_length(coalesce(new.payload->'sales','[]'::jsonb));
    if v_new_count <= v_old_count then
      raise exception 'Cashier permission: sales history cannot be edited or deleted';
    end if;

    select jsonb_agg(x.value order by x.ordinality) into v_prefix
    from jsonb_array_elements(new.payload->'sales') with ordinality x(value,ordinality)
    where x.ordinality > (v_new_count-v_old_count);
    if v_prefix is distinct from coalesce(old.payload->'sales','[]'::jsonb) then
      raise exception 'Cashier permission: existing sales cannot be changed';
    end if;

    if coalesce((new.payload->>'nextInvoice')::numeric,0) <>
       coalesce((old.payload->>'nextInvoice')::numeric,0) + (v_new_count-v_old_count) then
      raise exception 'Invalid invoice sequence';
    end if;

    if jsonb_array_length(coalesce(new.payload->'products','[]'::jsonb)) <>
       jsonb_array_length(coalesce(old.payload->'products','[]'::jsonb)) then
      raise exception 'Cashier permission: products cannot be added or removed';
    end if;

    for v_i in 0..jsonb_array_length(coalesce(old.payload->'products','[]'::jsonb))-1 loop
      v_old_product := old.payload->'products'->v_i;
      v_new_product := new.payload->'products'->v_i;
      if (v_new_product - 'stock') is distinct from (v_old_product - 'stock') then
        raise exception 'Cashier permission: product details cannot be changed';
      end if;

      select coalesce(sum((item->>'qty')::numeric),0) into v_expected
      from jsonb_array_elements(new.payload->'sales') with ordinality sale(value,ordinality)
      cross join lateral jsonb_array_elements(coalesce(sale.value->'items','[]'::jsonb)) item
      where sale.ordinality > v_old_count
        and item->>'id' = v_old_product->>'id';

      if coalesce((v_new_product->>'stock')::numeric,0) <>
         coalesce((v_old_product->>'stock')::numeric,0) - v_expected then
        raise exception 'Cashier permission: stock can only decrease through a completed sale';
      end if;
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists pos_guard_cashier_store_update on public.pos_store_data;
create trigger pos_guard_cashier_store_update
before update on public.pos_store_data
for each row execute function public.pos_guard_cashier_store_update();

drop policy if exists "pos members insert shared store" on public.pos_store_data;
create policy "pos admins initialize shared store"
on public.pos_store_data for insert to authenticated
with check (user_id = public.pos_current_store_id() and exists (
  select 1 from public.pos_store_members m
  where m.user_id=auth.uid() and m.store_id=user_id and m.role='admin' and m.active=true
));
