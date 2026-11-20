begin;

create table if not exists public.grg_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (length(trim(display_name)) > 0),
  role text not null check (role in ('owner', 'staff'))
);
create unique index if not exists grg_one_owner on public.grg_members (role) where role = 'owner';

create table if not exists public.grg_shop (
  id boolean primary key default true check (id),
  revision bigint not null default 0,
  snapshot jsonb not null default '{"products":[],"sales":[],"invoices":[],"settings":{}}'
);
create table if not exists public.grg_saves (
  request_id uuid primary key,
  actor uuid not null,
  revision bigint not null
);
insert into public.grg_shop (id) values (true) on conflict do nothing;

alter table public.grg_members enable row level security;
alter table public.grg_shop enable row level security;
alter table public.grg_saves enable row level security;
revoke all on public.grg_members, public.grg_shop, public.grg_saves from public, anon, authenticated;

create or replace function public.grg_read(known_revision bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  member public.grg_members%rowtype;
  shop public.grg_shop%rowtype;
begin
  select * into member from public.grg_members where user_id = auth.uid();
  if not found then raise exception 'Shop access has not been approved' using errcode = '42501'; end if;
  select * into shop from public.grg_shop where id;
  return jsonb_build_object('role', member.role, 'name', member.display_name, 'revision', shop.revision,
    'snapshot', case when shop.revision is distinct from known_revision then shop.snapshot end);
end;
$$;

create or replace function public.grg_save(expected_revision bigint, next_snapshot jsonb, operation_id uuid, restore_backup boolean)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  member public.grg_members%rowtype;
  shop public.grg_shop%rowtype;
  committed bigint;
  collection text;
  previous_items jsonb;
  next_items jsonb;
  old_counter bigint;
  new_counter bigint;
  invoice_count integer;
begin
  select * into member from public.grg_members where user_id = auth.uid() for share;
  if not found then raise exception 'Shop access has not been approved' using errcode = '42501'; end if;
  select * into shop from public.grg_shop where id for update;
  select revision into committed from public.grg_saves where request_id = operation_id and actor = member.user_id;
  if found then return committed; end if;
  if shop.revision is distinct from expected_revision then
    raise exception 'Shop data changed on another device' using errcode = '40001';
  end if;
  if coalesce(restore_backup, false) and member.role <> 'owner' then
    raise exception 'Only the owner can restore backups' using errcode = '42501';
  end if;
  if jsonb_typeof(next_snapshot -> 'settings') is distinct from 'object'
    or next_snapshot - array['products', 'sales', 'invoices', 'settings'] <> '{}'::jsonb then
    raise exception 'Invalid shop settings' using errcode = '22023';
  end if;

  foreach collection in array array['products', 'sales', 'invoices'] loop
    if jsonb_typeof(next_snapshot -> collection) is distinct from 'array' or exists (
      select 1 from jsonb_array_elements(next_snapshot -> collection) item
      where jsonb_typeof(item -> 'id') is distinct from 'string'
    ) or exists (
      select 1 from jsonb_array_elements(next_snapshot -> collection) item
      group by item ->> 'id' having count(*) > 1
    ) then
      raise exception 'Invalid shop records' using errcode = '22023';
    end if;
    if collection in ('sales', 'invoices') and exists (
      select 1 from jsonb_array_elements(next_snapshot -> collection) item
      where case when jsonb_typeof(item -> 'items') = 'array' then exists (
        select 1 from jsonb_array_elements(item -> 'items') line where jsonb_typeof(line) <> 'object'
      ) else true end
    ) then
      raise exception 'Invalid sale or invoice items' using errcode = '22023';
    end if;
    if restore_backup then continue; end if;

    select coalesce(jsonb_object_agg(item ->> 'id', item), '{}') into previous_items
    from jsonb_array_elements(shop.snapshot -> collection) item;
    select coalesce(jsonb_object_agg(item ->> 'id', item), '{}') into next_items
    from jsonb_array_elements(next_snapshot -> collection) item;

    if member.role = 'staff' and exists (
      select 1 from jsonb_each(previous_items) old
      where not (next_items ? old.key)
        or (collection = 'sales' and next_items -> old.key <> old.value)
        or (collection = 'invoices' and (
          (next_items -> old.key) - 'status' <> old.value - 'status'
          or coalesce(next_items -> old.key ->> 'status', '') not in ('paid', 'unpaid')
        ))
    ) then
      raise exception 'This change requires owner access' using errcode = '42501';
    end if;
    if collection in ('sales', 'invoices') and exists (
      select 1 from jsonb_each(next_items) item
      where not (previous_items ? item.key)
        and (item.value ->> 'actorId' is distinct from member.user_id::text
          or item.value ->> 'by' is distinct from member.display_name)
    ) then
      raise exception 'New records must use the signed-in account' using errcode = '42501';
    end if;
  end loop;

  if not coalesce(restore_backup, false) then
    if member.role = 'staff' and
      (next_snapshot -> 'settings') - 'nextInv' <> (shop.snapshot -> 'settings') - 'nextInv' then
      raise exception 'Only the owner can change shop settings' using errcode = '42501';
    end if;
    old_counter := coalesce((shop.snapshot -> 'settings' ->> 'nextInv')::bigint, 1);
    new_counter := coalesce((next_snapshot -> 'settings' ->> 'nextInv')::bigint, 1);
    select count(*) into invoice_count from jsonb_each(next_items) item where not (previous_items ? item.key);
    if new_counter <> old_counter + invoice_count or invoice_count > 1 or exists (
      select 1 from jsonb_each(next_items) item where not (previous_items ? item.key)
        and item.value ->> 'no' is distinct from
          'INV-' || lpad(old_counter::text, greatest(4, length(old_counter::text)), '0')
    ) then
      raise exception 'Invalid invoice number' using errcode = '22023';
    end if;
  end if;

  update public.grg_shop set snapshot = next_snapshot, revision = revision + 1 where id returning revision into committed;
  insert into public.grg_saves values (operation_id, member.user_id, committed);
  return committed;
end;
$$;

create or replace function public.grg_team()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.grg_members where user_id = auth.uid() and role = 'owner') then
    raise exception 'Only the owner can manage access' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('email', u.email, 'name', m.display_name) order by m.display_name)
    from public.grg_members m join auth.users u on u.id = m.user_id where m.role = 'staff'
  ), '[]');
end;
$$;

create or replace function public.grg_staff(login_email text, staff_name text, allow_access boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare target_id uuid;
begin
  if not exists (select 1 from public.grg_members where user_id = auth.uid() and role = 'owner') then
    raise exception 'Only the owner can manage access' using errcode = '42501';
  end if;
  select id into target_id from auth.users where lower(email) = lower(trim(login_email)) and email_confirmed_at is not null;
  if not found then raise exception 'Create and confirm this email account in Supabase first' using errcode = '22023'; end if;
  if allow_access then
    insert into public.grg_members (user_id, display_name, role) values (target_id, trim(staff_name), 'staff')
    on conflict (user_id) do update set display_name = excluded.display_name where grg_members.role = 'staff';
  else
    delete from public.grg_members where user_id = target_id and role = 'staff';
  end if;
end;
$$;

revoke all on function public.grg_read(bigint), public.grg_save(bigint,jsonb,uuid,boolean),
  public.grg_team(), public.grg_staff(text,text,boolean) from public, anon, authenticated;
grant execute on function public.grg_read(bigint), public.grg_save(bigint,jsonb,uuid,boolean),
  public.grg_team(), public.grg_staff(text,text,boolean) to authenticated;

commit;
