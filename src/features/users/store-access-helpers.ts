/**
 * Patch 1.4.1, item 2 — pure helper extracted so the "which currently-
 * granted stores should the Store Access editor show as checked" logic is
 * independently testable (Vitest) without a live Supabase connection.
 *
 * Why this exists: the target user's CURRENT grants (raw `store_id` values
 * from `user_store_access`) and the ACTOR's manageable stores
 * (`manageable_stores_for_actor()`, supabase/migrations/0035) are two
 * separate sets. A grant the target holds for a store OUTSIDE the actor's
 * own operable range (e.g. store C for an actor scoped to A+B) must:
 *   - never be offered as an editable checkbox (the actor cannot manage it,
 *     and may not even know it exists — see queries.ts's getUserDetail),
 *   - never be silently dropped when the actor saves changes to the stores
 *     they CAN see (replace_user_store_access, 0035, already preserves any
 *     out-of-range grant server-side regardless of what the client submits
 *     — this helper only controls what renders as checked, not what the DB
 *     keeps).
 * The fix is a plain set intersection: only a store present in BOTH the
 * target's current grants AND the actor's manageable stores should render
 * as checked. Stores outside the actor's manageable range are simply
 * absent from the rendered list entirely (UserStoreAccessEditor only maps
 * over `allStores`, which is already scoped to manageable stores) — they
 * are neither shown as checked nor unchecked, just not shown, and are never
 * included in what gets submitted back to setUserStoreAccessAction, which
 * is exactly what lets the database-side preservation logic in
 * replace_user_store_access() do its job untouched.
 */
export function selectableStoreAccessIds(currentStoreIds: readonly string[], manageableStoreIds: readonly string[] | Set<string>): string[] {
  const manageable = manageableStoreIds instanceof Set ? manageableStoreIds : new Set(manageableStoreIds);
  return currentStoreIds.filter((id) => manageable.has(id));
}
