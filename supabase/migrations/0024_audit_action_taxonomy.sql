-- ============================================================================
-- 0024: Fix audit action taxonomy (INSERT -> create, not "insert")
-- ============================================================================
-- Foundation Hardening 1.2, item 8.
--
-- Gap: 0016's audit_table_changes() computed the action string as
-- `entity_type || '.' || lower(TG_OP)`, which for a row INSERT produces
-- e.g. 'user.insert' / 'store.insert' / 'role.insert'. But
-- src/lib/audit/action-labels.ts (written alongside 0016, in the same
-- session) has always mapped 'user.create' / 'store.create' / 'role.create'
-- -- the trigger and the label table disagreed, so every audit row created
-- by an INSERT has been rendering as a raw, untranslated action string
-- ("user.insert") in the audit log UI instead of a proper Arabic label,
-- since the very first version of this trigger. UPDATE ('.update') and
-- DELETE ('.delete') already matched by coincidence (lower('UPDATE') =
-- 'update', lower('DELETE') = 'delete' both happen to equal the label
-- table's convention already).
--
-- Fix: map TG_OP explicitly instead of just lower-casing it, so INSERT
-- produces '.create' and matches the label table that was always written
-- expecting it. CREATE OR REPLACE from this new migration; 0016's file is
-- untouched, and the reusable trigger attachments it created (one per
-- sensitive table) do not need to change at all -- they already invoke
-- this same function by name.

create or replace function public.audit_table_changes()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_entity_type text := TG_ARGV[0];
  v_id_column text := TG_ARGV[1];
  v_action text;
  v_verb text;
  v_entity_id uuid;
  v_old jsonb;
  v_new jsonb;
begin
  if TG_OP = 'INSERT' then
    v_new := to_jsonb(new);
    v_entity_id := nullif(v_new ->> v_id_column, '')::uuid;
    v_verb := 'create';
  elsif TG_OP = 'UPDATE' then
    v_old := to_jsonb(old);
    v_new := to_jsonb(new);
    v_entity_id := nullif(v_new ->> v_id_column, '')::uuid;
    v_verb := 'update';
  elsif TG_OP = 'DELETE' then
    v_old := to_jsonb(old);
    v_entity_id := nullif(v_old ->> v_id_column, '')::uuid;
    v_verb := 'delete';
  else
    v_verb := lower(TG_OP);
  end if;

  v_action := v_entity_type || '.' || v_verb;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, old_values, new_values)
  values (auth.uid(), v_action, v_entity_type, v_entity_id, v_old, v_new);

  return coalesce(new, old);
end;
$$;

comment on function public.audit_table_changes() is
  'Generic AFTER trigger: writes an audit_logs row for every insert/update/delete on the table it is attached to. Args: (entity_type, id_column). Action verb is INSERT->create / UPDATE->update / DELETE->delete (0024) -- matches src/lib/audit/action-labels.ts''s taxonomy, which has always expected ''.create'' for new rows; before this fix the two disagreed and every INSERT-derived audit row rendered as an untranslated raw string.';

-- (Table triggers created in 0016 reference this function by name and do
-- not need to be recreated -- CREATE OR REPLACE FUNCTION updates the body
-- every existing trigger already points at.)
