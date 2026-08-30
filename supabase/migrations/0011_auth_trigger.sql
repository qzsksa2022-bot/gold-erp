-- ============================================================================
-- 0011: Safety-net trigger for new auth.users rows
-- ============================================================================
-- The normal user-creation path is the server action in
-- src/features/users/actions.ts: it calls the Supabase Admin API to create
-- the auth.users row AND writes the public.profiles row (with full_name,
-- status, default_store_id, created_by, ...) in the same request.
--
-- This trigger is a defensive fallback only, for the case where an
-- auth.users row is ever created another way (Supabase Studio, a future
-- OAuth flow, direct Admin API use outside the app). It guarantees the
-- invariant "every auth.users row has a matching profiles row" always
-- holds, using ON CONFLICT DO NOTHING so it never clobbers a profile the
-- server action already created moments earlier. New accounts created this
-- fallback way start as 'suspended' so they cannot do anything until an
-- admin explicitly reviews and activates them.
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, full_name, email, status)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    new.email,
    'suspended'
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row
  execute function public.handle_new_auth_user();
