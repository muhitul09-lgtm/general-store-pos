-- Sales return / refund migration for Muhit Store POS
-- Run this once in Supabase Dashboard -> SQL Editor -> New query -> Run.
-- The function locks the user's POS payload row, validates quantities against prior returns,
-- restores stock, adjusts customer due first, and appends one immutable return record.
-- Existing POS data and tables are not deleted or rebuilt.

create or replace function public.pos_process_return(p_return jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_payload jsonb;
  v_sales jsonb;
  v_sale jsonb;
  v_returns jsonb;
  v_products jsonb;
  v_existing jsonb;
  v_return jsonb;
  v_return_items jsonb := '[]'::jsonb;
  v_input_item jsonb;
  v_sale_item jsonb;
  v_line_index integer;
  v_qty numeric;
  v_sold_qty numeric;
  v_previous_qty numeric;
  v_sale_sub numeric;
  v_sale_total numeric;
  v_discount numeric;
  v_price numeric;
  v_cost numeric;
  v_base numeric := 0;
  v_value numeric := 0;
  v_profit numeric := 0;
  v_prior_value numeric := 0;
  v_customer text;
  v_sold_due numeric := 0;
  v_paid numeric := 0;
  v_prior_due_adjust numeric := 0;
  v_due_adjusted numeric := 0;
  v_refund numeric := 0;
  v_product_id text;
  v_product_found boolean;
  v_item_count integer;
  v_distinct_count integer;
begin
  if v_user is null then
    raise exception 'You must be signed in to process a cloud return.';
  end if;

  if coalesce(trim(p_return->>'id'), '') = '' then
    raise exception 'Return ID is required.';
  end if;

  if coalesce(jsonb_typeof(p_return->'items'), '') <> 'array' then
    raise exception 'Return items must be an array.';
  end if;

  -- Lock the single user's POS row so simultaneous returns cannot restore stock twice.
  select payload
    into v_payload
    from public.pos_store_data
   where user_id = v_user
   for update;

  if v_payload is null then
    raise exception 'POS cloud data was not found for this account.';
  end if;

  v_returns := coalesce(v_payload->'returns', '[]'::jsonb);

  select r.value
    into v_existing
    from jsonb_array_elements(v_returns) as r(value)
   where r.value->>'id' = p_return->>'id'
   limit 1;

  if v_existing is not null then
    return jsonb_build_object('duplicate', true, 'return', v_existing);
  end if;

  v_sales := coalesce(v_payload->'sales', '[]'::jsonb);

  select s.value
    into v_sale
    from jsonb_array_elements(v_sales) as s(value)
   where s.value->>'invoice' = p_return->>'originalInvoice'
   limit 1;

  if v_sale is null then
    raise exception 'Original invoice was not found.';
  end if;

  select count(*), count(distinct i.value->>'lineIndex')
    into v_item_count, v_distinct_count
    from jsonb_array_elements(p_return->'items') as i(value);

  if v_item_count = 0 or v_item_count <> v_distinct_count then
    raise exception 'Select at least one item and do not repeat an invoice line.';
  end if;

  v_sale_sub := coalesce(nullif(v_sale->>'sub', '')::numeric, 0);
  v_sale_total := coalesce(nullif(v_sale->>'total', '')::numeric, 0);
  v_discount := coalesce(nullif(v_sale->>'disc', '')::numeric, 0);
  v_customer := coalesce(v_sale->>'customer', '');

  for v_input_item in
    select value from jsonb_array_elements(p_return->'items')
  loop
    v_line_index := coalesce(nullif(v_input_item->>'lineIndex', '')::integer, -1);
    v_qty := coalesce(nullif(v_input_item->>'qty', '')::numeric, 0);

    if v_line_index < 0 or v_qty <= 0 or trunc(v_qty) <> v_qty then
      raise exception 'Return quantities must be positive whole numbers.';
    end if;

    v_sale_item := (v_sale->'items')->v_line_index;

    if v_sale_item is null or v_sale_item = 'null'::jsonb then
      raise exception 'A selected item does not belong to the original invoice.';
    end if;

    v_sold_qty := coalesce(nullif(v_sale_item->>'qty', '')::numeric, 0);

    select coalesce(sum(coalesce(nullif(ri.value->>'qty', '')::numeric, 0)), 0)
      into v_previous_qty
      from jsonb_array_elements(v_returns) as old_return(value)
      cross join lateral jsonb_array_elements(coalesce(old_return.value->'items', '[]'::jsonb)) as ri(value)
     where old_return.value->>'originalInvoice' = p_return->>'originalInvoice'
       and coalesce(nullif(ri.value->>'lineIndex', '')::integer, -1) = v_line_index;

    if v_previous_qty + v_qty > v_sold_qty then
      raise exception 'Return quantity exceeds the remaining quantity sold for item %.', coalesce(v_sale_item->>'name', 'item');
    end if;

    v_price := coalesce(nullif(v_sale_item->>'price', '')::numeric, 0);
    v_cost := coalesce(nullif(v_sale_item->>'cost', '')::numeric, 0);
    v_base := v_base + (v_price * v_qty);
    v_profit := v_profit + ((v_price - v_cost - case when v_sale_sub > 0 then (v_discount / v_sale_sub * v_price) else 0 end) * v_qty);

    v_return_items := v_return_items || jsonb_build_array(
      jsonb_build_object(
        'lineIndex', v_line_index,
        'productId', v_sale_item->'id',
        'name', v_sale_item->'name',
        'barcode', v_sale_item->'barcode',
        'qty', v_qty,
        'price', v_price,
        'cost', v_cost,
        'value', case when v_sale_sub > 0 then round(v_sale_total * v_price * v_qty / v_sale_sub, 2) else 0 end
      )
    );
  end loop;

  if v_sale_sub > 0 then
    v_value := round(v_sale_total * v_base / v_sale_sub, 2);
  end if;
  v_profit := round(v_profit, 2);

  select coalesce(sum(coalesce(nullif(r.value->>'value', '')::numeric, 0)), 0)
    into v_prior_value
    from jsonb_array_elements(v_returns) as r(value)
   where r.value->>'originalInvoice' = p_return->>'originalInvoice';

  if v_prior_value + v_value > v_sale_total + 0.01 then
    raise exception 'The return value exceeds the remaining value of the original invoice.';
  end if;

  if trim(v_customer) <> '' then
    select coalesce(sum(greatest(
      0,
      coalesce(nullif(s.value->>'due', '')::numeric,
        coalesce(nullif(s.value->>'total', '')::numeric, 0) -
        coalesce(nullif(s.value->>'received', '')::numeric, 0))
    )), 0)
      into v_sold_due
      from jsonb_array_elements(v_sales) as s(value)
     where lower(trim(coalesce(s.value->>'customer', ''))) = lower(trim(v_customer));

    select coalesce(sum(coalesce(nullif(p.value->>'amount', '')::numeric, 0)), 0)
      into v_paid
      from jsonb_array_elements(coalesce(v_payload->'duePayments', '[]'::jsonb)) as p(value)
     where lower(trim(coalesce(p.value->>'customer', ''))) = lower(trim(v_customer));

    select coalesce(sum(coalesce(nullif(r.value->>'dueAdjusted', '')::numeric, 0)), 0)
      into v_prior_due_adjust
      from jsonb_array_elements(v_returns) as r(value)
     where lower(trim(coalesce(r.value->>'customer', ''))) = lower(trim(v_customer));

    v_due_adjusted := least(v_value, greatest(0, v_sold_due - v_paid - v_prior_due_adjust));
  end if;

  v_refund := round(v_value - v_due_adjusted, 2);

  v_return := p_return || jsonb_build_object(
    'items', v_return_items,
    'customer', v_customer,
    'value', v_value,
    'dueAdjusted', v_due_adjusted,
    'refundAmount', v_refund,
    'profitAdjustment', v_profit,
    'stockRestored', true,
    'syncStatus', 'synced'
  );

  -- Restore each returned quantity once. If the original product was deleted,
  -- recreate it from the immutable invoice line so the physical stock is not lost.
  v_products := coalesce(v_payload->'products', '[]'::jsonb);

  for v_input_item in
    select value from jsonb_array_elements(v_return_items)
  loop
    v_product_id := v_input_item->>'productId';

    select exists(
      select 1
        from jsonb_array_elements(v_products) as p(value)
       where p.value->>'id' = v_product_id
    ) into v_product_found;

    if v_product_found then
      select coalesce(jsonb_agg(
        case
          when p.value->>'id' = v_product_id then
            jsonb_set(
              p.value,
              '{stock}',
              to_jsonb(coalesce(nullif(p.value->>'stock', '')::numeric, 0) + coalesce(nullif(v_input_item->>'qty', '')::numeric, 0)),
              true
            )
          else p.value
        end
        order by p.ordinality
      ), '[]'::jsonb)
        into v_products
        from jsonb_array_elements(v_products) with ordinality as p(value, ordinality);
    else
      v_sale_item := (v_sale->'items')->(v_input_item->>'lineIndex')::integer;
      v_products := v_products || jsonb_build_array(jsonb_build_object(
        'id', v_sale_item->'id',
        'name', v_sale_item->'name',
        'barcode', v_sale_item->'barcode',
        'price', v_sale_item->'price',
        'cost', v_sale_item->'cost',
        'stock', v_input_item->'qty',
        'image', v_sale_item->'image'
      ));
    end if;
  end loop;

  v_returns := v_returns || jsonb_build_array(v_return);
  v_payload := jsonb_set(v_payload, '{products}', v_products, true);
  v_payload := jsonb_set(v_payload, '{returns}', v_returns, true);

  update public.pos_store_data
     set payload = v_payload,
         updated_at = now()
   where user_id = v_user;

  return jsonb_build_object('duplicate', false, 'return', v_return);
end;
$$;

revoke all on function public.pos_process_return(jsonb) from public;
grant execute on function public.pos_process_return(jsonb) to authenticated;


-- Protect return history and its stock effects from a stale device overwriting
-- the JSON payload during a later whole-payload sync.
create or replace function public.pos_preserve_sales_returns_on_update()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_old_returns jsonb;
  v_new_returns jsonb;
  v_products jsonb;
  v_return jsonb;
  v_item jsonb;
  v_sale jsonb;
  v_sale_item jsonb;
  v_product_id text;
  v_qty numeric;
  v_product_found boolean;
begin
  if old.payload is null or new.payload is null then
    return new;
  end if;

  v_old_returns := coalesce(old.payload->'returns', '[]'::jsonb);
  v_new_returns := coalesce(new.payload->'returns', '[]'::jsonb);
  v_products := coalesce(new.payload->'products', '[]'::jsonb);

  for v_return in
    select value from jsonb_array_elements(v_old_returns)
  loop
    if not exists (
      select 1
        from jsonb_array_elements(v_new_returns) as current_return(value)
       where current_return.value->>'id' = v_return->>'id'
    ) then
      v_new_returns := v_new_returns || jsonb_build_array(v_return);

      select s.value
        into v_sale
        from jsonb_array_elements(coalesce(old.payload->'sales', '[]'::jsonb)) as s(value)
       where s.value->>'invoice' = v_return->>'originalInvoice'
       limit 1;

      for v_item in
        select value from jsonb_array_elements(coalesce(v_return->'items', '[]'::jsonb))
      loop
        v_product_id := v_item->>'productId';
        v_qty := coalesce(nullif(v_item->>'qty', '')::numeric, 0);

        select exists (
          select 1
            from jsonb_array_elements(v_products) as p(value)
           where p.value->>'id' = v_product_id
        ) into v_product_found;

        if v_product_found then
          select coalesce(jsonb_agg(
            case
              when p.value->>'id' = v_product_id then
                jsonb_set(
                  p.value,
                  '{stock}',
                  to_jsonb(coalesce(nullif(p.value->>'stock', '')::numeric, 0) + v_qty),
                  true
                )
              else p.value
            end
            order by p.ordinality
          ), '[]'::jsonb)
            into v_products
            from jsonb_array_elements(v_products) with ordinality as p(value, ordinality);
        else
          v_sale_item := (v_sale->'items')->coalesce(nullif(v_item->>'lineIndex', '')::integer, -1);
          if v_sale_item is not null and v_sale_item <> 'null'::jsonb then
            v_products := v_products || jsonb_build_array(jsonb_build_object(
              'id', v_sale_item->'id',
              'name', v_sale_item->'name',
              'barcode', v_sale_item->'barcode',
              'price', v_sale_item->'price',
              'cost', v_sale_item->'cost',
              'stock', v_qty,
              'image', v_sale_item->'image'
            ));
          end if;
        end if;
      end loop;
    end if;
  end loop;

  new.payload := jsonb_set(new.payload, '{returns}', v_new_returns, true);
  new.payload := jsonb_set(new.payload, '{products}', v_products, true);
  return new;
end;
$$;

drop trigger if exists pos_preserve_sales_returns_before_update on public.pos_store_data;
create trigger pos_preserve_sales_returns_before_update
before update on public.pos_store_data
for each row
execute function public.pos_preserve_sales_returns_on_update();
