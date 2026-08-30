/**
 * Hand-maintained mirror of the Supabase schema (supabase/migrations/*.sql).
 *
 * In a real deployment this file should be regenerated from the live
 * project with:
 *   npx supabase gen types typescript --project-id <ref> > src/types/database.ts
 * It is hand-written here (network access to generate against a live
 * Supabase project isn't available in this environment) and was kept in
 * exact sync with every migration file — see supabase/migrations/0001..0024
 * and supabase/seed.sql. Regenerate it for real once the project is linked;
 * see README "خطوات ربط Supabase".
 *
 * Every table below carries `Relationships: []`. postgrest-js's generic
 * client type (see GenericTable in @supabase/postgrest-js) requires this
 * field to exist (even empty) for the Database type to structurally match
 * — without it every `.from(...)` query silently collapses to `never`.
 * Leaving it empty means embedded relationship selects (e.g.
 * `role:roles(*)`) still work at RUNTIME (PostgREST resolves the foreign
 * key itself) but are looser-typed on the client; call sites that use them
 * cast/narrow accordingly. A real `gen types` run fills this in precisely.
 */

export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[];

export type ProfileStatus = "active" | "suspended" | "pending_setup";
export type StoreAccessScope = "all" | "multiple" | "single";
export type StoreStatus = "active" | "disabled";
export type PermissionOverrideEffect = "grant" | "revoke";

// Phase 2 — Financial Master Data (migrations 0040-0046)
/** Shared active/inactive lifecycle status used by karats, product_categories, payment_methods, and collection_channels. */
export type MasterDataStatus = "active" | "inactive";
export type GoldPriceSourceType = "manual" | "external_api";
/** Shared lifecycle for versioned rate rows (manufacturing_fee_versions, payment_method_fee_versions). */
export type FeeVersionStatus = "active" | "ended" | "cancelled";
export type PaymentFeeModel = "percentage" | "fixed" | "percentage_plus_fixed" | "none";
export type RefundFeePolicy = "full_reversal" | "proportional_reversal" | "non_refundable_fee" | "manual";

// Phase 4 — Returns Core (migrations 0082-0091)
/** Mirrors sales_returns.scenario's check constraint (migration 0082). */
export type SalesReturnScenario = "defective_product" | "customer_changed_mind" | "wrong_item_delivered" | "customer_never_received" | "other";
export type SalesReturnStatus = "pending" | "approved" | "rejected" | "reversed";
export type SalesReturnItemStatus = "active" | "removed";
export type SalesReturnRefundEventStatus = "active" | "reversed";
/** Patch 4.1 (Section 1/2) — mirrors sales_returns.collection_state's check constraint (migration 0092). */
export type SalesReturnCollectionState = "collected" | "not_collected" | "partially_collected" | "unknown";
/** Patch 4.1 (Section 3) — mirrors sales_return_items.condition's check constraint (migration 0092). */
export type SalesReturnItemCondition = "good_resellable" | "needs_service" | "damaged" | "unknown" | "not_applicable";
/** Patch 4.1 (Section 11) — derived by get_sales_return()/list_sales_returns() (migration 0098), never stored as a column. */
export type SalesReturnRefundReconciliationState = "not_applicable" | "pending" | "finalized_matched" | "finalized_with_variance";

// Phase 5 — Shipping Core (migrations 0113-0121)
/** Mirrors shipping_carriers.carrier_type's check constraint (migration 0113). Opaque data only — never branched on server-side (Section 3's no-carrier-name-branching rule). */
export type ShippingCarrierType = "external" | "store_courier" | "other";
/** Shared active/disabled lifecycle for shipping_carriers/shipping_zones (migration 0113) — deliberately distinct spelling from MasterDataStatus's active/inactive (matches the actual CHECK constraint wording). */
export type ShippingMasterDataStatus = "active" | "disabled";
/** Mirrors shipments.direction's check constraint (migration 0116). */
export type ShipmentDirection = "outbound" | "return";
/** Mirrors shipments.fulfillment_type's check constraint (migration 0116). */
export type ShipmentFulfillmentType = "delivery" | "store_courier" | "pickup" | "other";
/** Mirrors shipments.cod_collection_state's check constraint (migration 0116). */
export type ShipmentCodCollectionState = "expected" | "collected" | "not_collected" | "unknown";
/** Mirrors shipments.current_status's check constraint AND shipment_status_events.status (migration 0116) — the full state-machine vocabulary (see validate_shipment_status_transition()). */
export type ShipmentStatus =
  | "created"
  | "ready_for_pickup"
  | "picked_up"
  | "in_transit"
  | "out_for_delivery"
  | "delivered"
  | "delivery_failed"
  | "customer_refused"
  | "customer_never_received"
  | "returned_to_store"
  | "cancelled";
/** Mirrors shipment_financial_events.event_type's check constraint (migration 0116). */
export type ShipmentFinancialEventType = "actual_cost_recorded" | "actual_cost_correction" | "customer_charge_correction";

// Phase 3 — Sales Core (migrations 0058-0064)
/**
 * One line item inside create_sales_order()/update_sales_order()/
 * preview_sales_order()'s `p_items` jsonb payload (0061/0062/0063).
 * Deliberately ONLY these business-input fields — the RPCs never read (and
 * would ignore even if sent) any snapshot/cost/profit key, see migration
 * 0061's header comment (spec §6/§24). weight_grams/sale_price MUST be sent
 * as Decimal-safe strings, never a prior JS float computation — see
 * src/lib/decimal.ts.
 */
export interface SalesOrderItemInput {
  // Patch 3.1 item 1/9 — stable item identity: omit (or null) for a NEW
  // item; an existing item's real id for an edit. update_sales_order()
  // (0069) treats a submitted id it cannot find as an error, and any
  // existing active item whose id is NOT present in the submitted array is
  // soft-removed (status='removed'), never hard-deleted. create_sales_order()
  // ignores this field entirely (every item there is necessarily new).
  id?: string | null;
  category_id: string;
  karat_id: string;
  weight_grams: string | number;
  sale_price: string | number;
  item_name?: string | null;
  description?: string | null;
  sku?: string | null;
}

/**
 * Patch 4.1 (Section 3) — one element of create_sales_return()/preview_
 * sales_return()/update_pending_sales_return()'s `p_items` jsonb payload
 * (migrations 0093/0094). sales_order_item_id is the stable item identity
 * (0067) the return line is FK'd to; condition/item_return_reason/
 * item_notes are historical-only per-item business data (no Inventory
 * movement in this phase).
 */
export interface ReturnItemInput {
  sales_order_item_id: string;
  condition?: SalesReturnItemCondition;
  item_return_reason?: string | null;
  item_notes?: string | null;
}

export interface Database {
  public: {
    Tables: {
      profiles: {
        Row: {
          id: string;
          full_name: string;
          email: string;
          status: ProfileStatus;
          store_access_scope: StoreAccessScope;
          default_store_id: string | null;
          // 0029: set exactly once by finalize_new_user_profile(); null
          // means "this account was never provisioned". Immutable from the
          // client via any other path -- see enforce_provisioned_at_immutable.
          provisioned_at: string | null;
          created_at: string;
          updated_at: string;
          created_by: string | null;
          updated_by: string | null;
        };
        Insert: {
          id: string;
          full_name: string;
          email: string;
          status?: ProfileStatus;
          store_access_scope?: StoreAccessScope;
          default_store_id?: string | null;
          provisioned_at?: string | null;
          created_by?: string | null;
          updated_by?: string | null;
        };
        Update: Partial<{
          full_name: string;
          email: string;
          status: ProfileStatus;
          store_access_scope: StoreAccessScope;
          default_store_id: string | null;
          // Client-settable in shape only -- enforce_provisioned_at_immutable
          // (0029) rejects any actual change outside finalize_new_user_profile()'s
          // own transaction-local flag, regardless of what a client sends here.
          provisioned_at: string | null;
          // Normally never updated after creation -- the one legitimate
          // exception is the create-user server action finalizing the
          // profile row moments after the on_auth_user_created trigger
          // (0011) already inserted a bare-bones placeholder for it.
          created_by: string | null;
          updated_by: string | null;
        }>;
        Relationships: [];
      };
      permissions: {
        Row: {
          id: string;
          key: string;
          category: string;
          description_ar: string;
          description_en: string | null;
          created_at: string;
        };
        Insert: {
          key: string;
          category: string;
          description_ar: string;
          description_en?: string | null;
        };
        Update: Partial<{ description_ar: string; description_en: string | null }>;
        Relationships: [];
      };
      roles: {
        Row: {
          id: string;
          key: string;
          name_ar: string;
          name_en: string | null;
          description_ar: string | null;
          is_system: boolean;
          created_at: string;
          updated_at: string;
          created_by: string | null;
          updated_by: string | null;
        };
        Insert: {
          key: string;
          name_ar: string;
          name_en?: string | null;
          description_ar?: string | null;
          is_system?: boolean;
          created_by?: string | null;
          updated_by?: string | null;
        };
        Update: Partial<{
          name_ar: string;
          name_en: string | null;
          description_ar: string | null;
          updated_by: string | null;
        }>;
        Relationships: [];
      };
      role_permissions: {
        Row: { role_id: string; permission_id: string; created_at: string };
        Insert: { role_id: string; permission_id: string };
        Update: Partial<{ role_id: string; permission_id: string }>;
        Relationships: [];
      };
      user_roles: {
        Row: { user_id: string; role_id: string; created_at: string; created_by: string | null };
        Insert: { user_id: string; role_id: string; created_by?: string | null };
        Update: Partial<{ user_id: string; role_id: string }>;
        Relationships: [
          {
            foreignKeyName: "user_roles_role_id_fkey";
            columns: ["role_id"];
            isOneToOne: false;
            referencedRelation: "roles";
            referencedColumns: ["id"];
          },
        ];
      };
      user_permission_overrides: {
        Row: {
          user_id: string;
          permission_id: string;
          effect: PermissionOverrideEffect;
          reason: string | null;
          created_at: string;
          created_by: string | null;
        };
        Insert: {
          user_id: string;
          permission_id: string;
          effect: PermissionOverrideEffect;
          reason?: string | null;
          created_by?: string | null;
        };
        Update: Partial<{ effect: PermissionOverrideEffect; reason: string | null }>;
        Relationships: [
          {
            foreignKeyName: "user_permission_overrides_permission_id_fkey";
            columns: ["permission_id"];
            isOneToOne: false;
            referencedRelation: "permissions";
            referencedColumns: ["id"];
          },
        ];
      };
      stores: {
        Row: {
          id: string;
          code: string;
          name_ar: string;
          name_en: string | null;
          status: StoreStatus;
          logo_url: string | null;
          description: string | null;
          created_at: string;
          updated_at: string;
          created_by: string | null;
          updated_by: string | null;
        };
        Insert: {
          code: string;
          name_ar: string;
          name_en?: string | null;
          status?: StoreStatus;
          logo_url?: string | null;
          description?: string | null;
          created_by?: string | null;
          updated_by?: string | null;
        };
        Update: Partial<{
          code: string;
          name_ar: string;
          name_en: string | null;
          status: StoreStatus;
          logo_url: string | null;
          description: string | null;
          updated_by: string | null;
        }>;
        Relationships: [];
      };
      user_store_access: {
        Row: { user_id: string; store_id: string; created_at: string; created_by: string | null };
        Insert: { user_id: string; store_id: string; created_by?: string | null };
        Update: Partial<{ user_id: string; store_id: string }>;
        Relationships: [
          {
            foreignKeyName: "user_store_access_store_id_fkey";
            columns: ["store_id"];
            isOneToOne: false;
            referencedRelation: "stores";
            referencedColumns: ["id"];
          },
        ];
      };
      audit_logs: {
        Row: {
          id: string;
          user_id: string | null;
          action: string;
          entity_type: string;
          entity_id: string | null;
          old_values: Json | null;
          new_values: Json | null;
          reason: string | null;
          ip_address: string | null;
          user_agent: string | null;
          created_at: string;
        };
        // Never actually written via `.insert()` from app code — the only
        // sanctioned writer is the log_audit_event() RPC (see
        // src/lib/audit/log.ts) — but the shape is still declared (rather
        // than `never`) so it satisfies postgrest-js's GenericTable
        // constraint (Insert/Update must be Record<string, unknown>).
        Insert: {
          user_id?: string | null;
          action: string;
          entity_type: string;
          entity_id?: string | null;
          old_values?: Json | null;
          new_values?: Json | null;
          reason?: string | null;
          ip_address?: string | null;
          user_agent?: string | null;
        };
        Update: Record<string, never>;
        Relationships: [];
      };
      system_settings: {
        Row: {
          id: string;
          category: string;
          key: string;
          value: Json;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: { category: string; key: string; value: Json; updated_by?: string | null };
        Update: Partial<{ value: Json; updated_by: string | null }>;
        Relationships: [];
      };

      // ---------------------------------------------------------------
      // Phase 2 — Financial Master Data (migrations 0040-0046)
      // ---------------------------------------------------------------
      karats: {
        Row: {
          id: string;
          code: string;
          // NUMERIC(6,3) column. PostgREST serializes `numeric` as an
          // UNQUOTED JSON number by default (real `supabase gen types
          // typescript` output would type this `number`, not `string` —
          // see src/lib/decimal.ts's header comment and DELIVERY_REPORT.md's
          // Patch 2.2 appendix for the corrected explanation and the real
          // HTTP/PostgREST proof). Typed `number` here to match that reality
          // rather than a false "always arrives as a string" assumption.
          // purity_per_mille never flows into a Decimal financial
          // calculation (display-only), so `number` is also the right type
          // for its actual usage.
          purity_per_mille: number | null;
          name_ar: string;
          name_en: string | null;
          sort_order: number;
          status: MasterDataStatus;
          created_at: string;
          updated_at: string;
          created_by: string | null;
          updated_by: string | null;
        };
        Insert: {
          code: string;
          purity_per_mille?: string | null;
          name_ar: string;
          name_en?: string | null;
          sort_order?: number;
          status?: MasterDataStatus;
          created_by?: string | null;
          updated_by?: string | null;
        };
        Update: Partial<{
          code: string;
          purity_per_mille: string | null;
          name_ar: string;
          name_en: string | null;
          sort_order: number;
          status: MasterDataStatus;
          updated_by: string | null;
        }>;
        Relationships: [];
      };
      daily_gold_prices: {
        Row: {
          id: string;
          price_date: string;
          karat_id: string;
          // NUMERIC column, read raw via `.select()`/`.from()` — PostgREST
          // serializes it as an UNQUOTED JSON number (see the karats.
          // purity_per_mille comment above for the full rationale). A value
          // that will enter a financial calculation MUST be read instead via
          // the finance-safe `gold_price_for_karat_on_date_safe()` RPC
          // (migration 0052, typed as returning `string` below) — this raw
          // `number` field is for display/table-listing use only.
          price_per_gram: number;
          source_type: GoldPriceSourceType;
          source_name: string | null;
          source_reference: string | null;
          is_manual_override: boolean;
          notes: string | null;
          created_by: string | null;
          updated_by: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          price_date: string;
          karat_id: string;
          price_per_gram: string | number;
          source_type?: GoldPriceSourceType;
          source_name?: string | null;
          source_reference?: string | null;
          is_manual_override?: boolean;
          notes?: string | null;
          created_by?: string | null;
          updated_by?: string | null;
        };
        Update: Partial<{
          price_per_gram: string | number;
          source_type: GoldPriceSourceType;
          source_name: string | null;
          source_reference: string | null;
          is_manual_override: boolean;
          notes: string | null;
          updated_by: string | null;
        }>;
        Relationships: [];
      };
      manufacturing_fee_versions: {
        Row: {
          id: string;
          karat_id: string;
          // NUMERIC column, raw JSON-number over the wire — see
          // daily_gold_prices.price_per_gram comment above. Use
          // manufacturing_fee_for_karat_on_date_safe() (migration 0052) for
          // any value entering a Decimal calculation.
          fee_per_gram: number;
          effective_from: string;
          effective_to: string | null;
          status: FeeVersionStatus;
          notes: string | null;
          created_by: string | null;
          created_at: string;
        };
        // Rows are never inserted/updated directly by app code — always via
        // create_manufacturing_fee_version()/cancel_manufacturing_fee_version()
        // (see Functions below). Insert/Update kept here only so the type
        // stays structurally honest about what the table itself allows.
        Insert: {
          karat_id: string;
          fee_per_gram: string | number;
          effective_from: string;
          effective_to?: string | null;
          status?: FeeVersionStatus;
          notes?: string | null;
          created_by?: string | null;
        };
        Update: Partial<{ effective_to: string | null; status: FeeVersionStatus; notes: string | null }>;
        Relationships: [];
      };
      product_categories: {
        Row: {
          id: string;
          parent_id: string | null;
          code: string | null;
          name_ar: string;
          name_en: string | null;
          sort_order: number;
          status: MasterDataStatus;
          external_id: string | null;
          external_source: string | null;
          created_by: string | null;
          updated_by: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          parent_id?: string | null;
          code?: string | null;
          name_ar: string;
          name_en?: string | null;
          sort_order?: number;
          status?: MasterDataStatus;
          external_id?: string | null;
          external_source?: string | null;
          created_by?: string | null;
          updated_by?: string | null;
        };
        Update: Partial<{
          parent_id: string | null;
          code: string | null;
          name_ar: string;
          name_en: string | null;
          sort_order: number;
          status: MasterDataStatus;
          external_id: string | null;
          external_source: string | null;
          updated_by: string | null;
        }>;
        Relationships: [];
      };
      payment_methods: {
        Row: {
          id: string;
          key: string;
          name_ar: string;
          name_en: string | null;
          fee_model: PaymentFeeModel;
          status: MasterDataStatus;
          supports_refunds: boolean;
          refund_fee_policy: RefundFeePolicy;
          sort_order: number;
          metadata: Json;
          created_at: string;
          updated_at: string;
          created_by: string | null;
          updated_by: string | null;
        };
        Insert: {
          key: string;
          name_ar: string;
          name_en?: string | null;
          fee_model?: PaymentFeeModel;
          status?: MasterDataStatus;
          supports_refunds?: boolean;
          refund_fee_policy?: RefundFeePolicy;
          sort_order?: number;
          metadata?: Json;
          created_by?: string | null;
          updated_by?: string | null;
        };
        Update: Partial<{
          key: string;
          name_ar: string;
          name_en: string | null;
          fee_model: PaymentFeeModel;
          status: MasterDataStatus;
          supports_refunds: boolean;
          refund_fee_policy: RefundFeePolicy;
          sort_order: number;
          metadata: Json;
          updated_by: string | null;
        }>;
        Relationships: [];
      };
      payment_method_fee_versions: {
        Row: {
          id: string;
          payment_method_id: string;
          // NUMERIC columns, raw JSON-number over the wire — see
          // daily_gold_prices.price_per_gram comment above. Use
          // payment_fee_for_method_on_date_safe() (migration 0052) for any
          // value entering a Decimal calculation.
          percentage_fee: number;
          fixed_fee: number;
          effective_from: string;
          effective_to: string | null;
          status: FeeVersionStatus;
          notes: string | null;
          created_by: string | null;
          created_at: string;
        };
        // Never inserted/updated directly by app code — always via
        // create_payment_method_fee_version()/cancel_payment_method_fee_version().
        Insert: {
          payment_method_id: string;
          percentage_fee?: string | number;
          fixed_fee?: string | number;
          effective_from: string;
          effective_to?: string | null;
          status?: FeeVersionStatus;
          notes?: string | null;
          created_by?: string | null;
        };
        Update: Partial<{ effective_to: string | null; status: FeeVersionStatus; notes: string | null }>;
        Relationships: [];
      };
      collection_channels: {
        Row: {
          id: string;
          key: string;
          name_ar: string;
          name_en: string | null;
          status: MasterDataStatus;
          sort_order: number;
          metadata: Json;
          created_at: string;
          updated_at: string;
          created_by: string | null;
          updated_by: string | null;
        };
        Insert: {
          key: string;
          name_ar: string;
          name_en?: string | null;
          status?: MasterDataStatus;
          sort_order?: number;
          metadata?: Json;
          created_by?: string | null;
          updated_by?: string | null;
        };
        Update: Partial<{
          key: string;
          name_ar: string;
          name_en: string | null;
          status: MasterDataStatus;
          sort_order: number;
          metadata: Json;
          updated_by: string | null;
        }>;
        Relationships: [];
      };

      // Phase 3 — Sales Core (migration 0058). No direct-write RLS policy
      // at all (unlike manufacturing_fee_versions/payment_method_fee_
      // versions) — management is exclusively via create_vat_rate_version()/
      // cancel_vat_rate_version() (see Functions below).
      vat_rate_versions: {
        Row: {
          id: string;
          // Raw NUMERIC(6,3) -- unquoted JSON number over the wire. Use
          // vat_rate_for_date_safe() (text) for any financial calculation.
          rate_percent: number;
          effective_from: string;
          effective_to: string | null;
          status: FeeVersionStatus;
          notes: string | null;
          created_by: string | null;
          created_at: string;
        };
        Insert: {
          rate_percent: string | number;
          effective_from: string;
          effective_to?: string | null;
          status?: FeeVersionStatus;
          notes?: string | null;
          created_by?: string | null;
        };
        Update: Partial<{ effective_to: string | null; status: FeeVersionStatus; notes: string | null }>;
        Relationships: [];
      };

      // Phase 3 — Sales Core (migration 0059). ZERO direct-write AND ZERO
      // direct-SELECT RLS policies (see 0059's access-model note) — the app
      // NEVER calls `.from('sales_orders')` directly; every read goes
      // through list_sales_orders()/get_sales_order() (0062) and every
      // write through create_sales_order()/update_sales_order()
      // (0061/0063). Row/Insert/Update are still typed fully here for
      // schema honesty/documentation and any future internal tooling.
      sales_orders: {
        Row: {
          id: string;
          order_number: string;
          store_id: string;
          sale_date: string;
          sold_at: string;
          salesperson_id: string;
          payment_method_id: string;
          collection_channel_id: string;
          customer_name: string | null;
          customer_phone: string | null;
          notes: string | null;
          payment_fee_version_id: string;
          // Every column below is raw NUMERIC -- unquoted JSON number over
          // the wire IF ever read via a direct table select (which the app
          // never does). get_sales_order()/list_sales_orders() (0062)
          // return the equivalent values cast ::text inside the jsonb/table
          // response instead -- always use those, never a raw table read,
          // for anything feeding a Decimal calculation.
          payment_fee_percentage_snapshot: number;
          payment_fee_fixed_snapshot: number;
          payment_fee_amount: number;
          subtotal: number;
          gross_profit: number;
          net_sales_profit: number;
          calculation_version: number;
          // Patch 3.2 item 2 (migration 0075) — optimistic-concurrency
          // token, incremented by exactly 1 on every successful
          // update_sales_order() call. get_sales_order() (0079) returns
          // this as row_version; the client must send it back as
          // p_expected_version -- a mismatch is rejected with a Conflict
          // (see isVersionConflictError() in src/features/sales/schema.ts)
          // rather than silently overwritten.
          row_version: number;
          created_by: string | null;
          updated_by: string | null;
          created_at: string;
          updated_at: string;
        };
        // Never inserted/updated directly by app code -- always via
        // create_sales_order()/update_sales_order() (see Functions below).
        Insert: {
          order_number: string;
          store_id: string;
          sale_date: string;
          sold_at?: string;
          salesperson_id: string;
          payment_method_id: string;
          collection_channel_id: string;
          customer_name?: string | null;
          customer_phone?: string | null;
          notes?: string | null;
          payment_fee_version_id: string;
          payment_fee_percentage_snapshot: string | number;
          payment_fee_fixed_snapshot: string | number;
          payment_fee_amount: string | number;
          subtotal: string | number;
          gross_profit: string | number;
          net_sales_profit: string | number;
          calculation_version?: number;
          row_version?: number;
          created_by?: string | null;
          updated_by?: string | null;
        };
        Update: Partial<{
          payment_method_id: string;
          collection_channel_id: string;
          customer_name: string | null;
          customer_phone: string | null;
          notes: string | null;
          payment_fee_version_id: string;
          payment_fee_percentage_snapshot: string | number;
          payment_fee_fixed_snapshot: string | number;
          payment_fee_amount: string | number;
          subtotal: string | number;
          gross_profit: string | number;
          net_sales_profit: string | number;
          updated_by: string | null;
        }>;
        Relationships: [];
      };

      // Phase 3 — Sales Core (migration 0059). Same ZERO-direct-access
      // model as sales_orders above -- see that entry's comment.
      sales_order_items: {
        Row: {
          id: string;
          sales_order_id: string;
          line_no: number;
          // Patch 3.1 item 1 (migration 0067) — stable identity: an item is
          // never hard-deleted by update_sales_order(); dropping it from an
          // edit's payload flips status to 'removed' and stamps
          // removed_at/removed_by instead. Every real read (get_sales_order/
          // list_sales_orders item_count) filters to status='active'.
          status: "active" | "removed";
          removed_at: string | null;
          removed_by: string | null;
          category_id: string;
          karat_id: string;
          item_name: string | null;
          description: string | null;
          sku: string | null;
          weight_grams: number;
          sale_price: number;
          category_name_ar_snapshot: string;
          karat_code_snapshot: string;
          karat_name_ar_snapshot: string;
          daily_gold_price_id: string;
          gold_price_per_gram_snapshot: number;
          manufacturing_fee_version_id: string;
          manufacturing_fee_per_gram_snapshot: number;
          vat_rate_version_id: string;
          vat_rate_percent_snapshot: number;
          gold_component_cost: number;
          manufacturing_component_cost: number;
          base_cost: number;
          vat_cost: number;
          total_cost: number;
          gross_profit: number;
          // Patch 3.2 item 7 (migration 0074) — per-item cost-engine
          // version stamp: 1 = legacy (pre-Patch-3.2 component-early-
          // rounding engine, or never recalculated since), 2 = the
          // Patch 3.2 full-precision compute_sales_item_costs() engine.
          // Stamped on every newly-created item and every item whose
          // financial inputs are actually recalculated on update; an
          // untouched item keeps its existing version -- a single order
          // can legitimately mix versions across its items. Distinct from
          // the order-level sales_orders.calculation_version (0059).
          calculation_version: number;
          created_by: string | null;
          updated_by: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          sales_order_id: string;
          line_no: number;
          status?: "active" | "removed";
          category_id: string;
          karat_id: string;
          item_name?: string | null;
          description?: string | null;
          sku?: string | null;
          weight_grams: string | number;
          sale_price: string | number;
          category_name_ar_snapshot: string;
          karat_code_snapshot: string;
          karat_name_ar_snapshot: string;
          daily_gold_price_id: string;
          gold_price_per_gram_snapshot: string | number;
          manufacturing_fee_version_id: string;
          manufacturing_fee_per_gram_snapshot: string | number;
          vat_rate_version_id: string;
          vat_rate_percent_snapshot: string | number;
          gold_component_cost: string | number;
          manufacturing_component_cost: string | number;
          base_cost: string | number;
          vat_cost: string | number;
          total_cost: string | number;
          gross_profit: string | number;
          calculation_version?: number;
          created_by?: string | null;
          updated_by?: string | null;
        };
        Update: Partial<{
          item_name: string | null;
          description: string | null;
          sku: string | null;
          status: "active" | "removed";
          removed_at: string | null;
          removed_by: string | null;
          updated_by: string | null;
        }>;
        Relationships: [];
      };

      // Phase 3 — Sales Core (migration 0059). Unlike sales_orders/
      // sales_order_items, this table DOES have a direct SELECT RLS policy
      // (sales.view + user_visible_store_ids) -- no profit-sensitive data
      // here, so the app may read it directly (e.g. an "اليوم مغلق" check)
      // without going through a Read RPC. No direct INSERT/UPDATE/DELETE
      // policy -- always via close_sales_day() (see Functions below); no
      // reopen/edit path exists in Phase 3.
      daily_closings: {
        Row: {
          id: string;
          store_id: string;
          business_date: string;
          closed_at: string;
          closed_by: string | null;
          notes: string | null;
        };
        Insert: {
          store_id: string;
          business_date: string;
          closed_at?: string;
          closed_by?: string | null;
          notes?: string | null;
        };
        Update: Record<string, never>;
        Relationships: [];
      };

      // Phase 4 — Returns Core (migration 0082). Same ZERO-direct-access
      // model as sales_orders/sales_order_items -- every read/write goes
      // through the RPCs in Functions below, never a raw .from() call.
      // Every NUMERIC column below is raw (unquoted JSON number) if ever
      // read directly, which the app never does -- get_sales_return()/
      // list_sales_returns() (0090) return the equivalent values cast
      // ::text instead.
      sales_returns: {
        Row: {
          id: string;
          return_number: string;
          sales_order_id: string;
          processed_store_id: string;
          return_date: string;
          customer_name_snapshot: string | null;
          customer_phone_snapshot: string | null;
          scenario: SalesReturnScenario;
          scenario_notes: string | null;
          status: SalesReturnStatus;
          row_version: number;
          order_subtotal_snapshot: number;
          order_payment_fee_amount_snapshot: number;
          payment_method_id: string;
          // Hotfix 7.1.2 (§1-3) — the original Sale's collection_channel_id
          // as it stood the moment this Return was created, captured
          // authoritatively by a BEFORE INSERT trigger and permanently
          // frozen thereafter (mirrors payment_method_id above). Never
          // re-read from a live Sale for settlement-route matching again.
          collection_channel_id_snapshot: string;
          // Patch 4.1 (Section 4) — stale-sale guard.
          sale_date_snapshot: string;
          source_sale_row_version: number;
          // Patch 4.2 (Section 1) — an independent, stricter legacy-upgrade
          // guard: true means item snapshots cannot be trusted without an
          // explicit refresh_pending_sales_return_from_sale() call, even if
          // source_sale_row_version happens to match the current Sale.
          requires_sale_refresh: boolean;
          // Patch 4.1 (Section 1/2) — business inputs, set at create/
          // update-pending time, re-validated (never re-derived) at approval.
          collection_state: SalesReturnCollectionState;
          non_shipping_deduction_amount: number;
          deduction_reason: string | null;
          refund_difference_reason: string | null;
          // Computed ONLY at approve_sales_return() (0087, rewritten 0095);
          // retained permanently afterward even if the return is later
          // reversed -- reversal does not erase these historical figures.
          returned_original_sale_amount: number | null;
          sales_revenue_reversal_amount: number | null;
          recovered_original_cost_amount: number | null;
          net_sales_profit_adjustment: number | null;
          gross_profit_reversal_amount: number | null;
          payment_fee_reversal_amount: number | null;
          net_profit_reversal_amount: number | null;
          approved_refund_amount: number | null;
          refund_fee_policy_snapshot: RefundFeePolicy | null;
          approved_at: string | null;
          approved_by: string | null;
          rejected_at: string | null;
          rejected_by: string | null;
          rejection_reason: string | null;
          reversed_at: string | null;
          reversed_by: string | null;
          reversal_reason: string | null;
          reversal_business_date: string | null;
          refund_finalized_at: string | null;
          refund_finalized_by: string | null;
          refund_final_variance_reason: string | null;
          created_by: string | null;
          updated_by: string | null;
          created_at: string;
          updated_at: string;
        };
        // Never inserted/updated directly by app code -- always via
        // create_sales_return()/update_pending_sales_return()/refresh_
        // pending_sales_return_from_sale()/approve_sales_return()/reject_
        // sales_return()/reverse_sales_return()/finalize_sales_return_
        // refund() (see Functions below).
        Insert: {
          return_number: string;
          sales_order_id: string;
          processed_store_id: string;
          return_date: string;
          customer_name_snapshot?: string | null;
          customer_phone_snapshot?: string | null;
          scenario: SalesReturnScenario;
          scenario_notes?: string | null;
          status?: SalesReturnStatus;
          row_version?: number;
          order_subtotal_snapshot: string | number;
          order_payment_fee_amount_snapshot: string | number;
          payment_method_id: string;
          sale_date_snapshot: string;
          source_sale_row_version: number;
          requires_sale_refresh?: boolean;
          collection_state: SalesReturnCollectionState;
          non_shipping_deduction_amount?: string | number;
          deduction_reason?: string | null;
          refund_difference_reason?: string | null;
          approved_refund_amount?: string | number | null;
          created_by?: string | null;
          updated_by?: string | null;
        };
        Update: Partial<{
          scenario: SalesReturnScenario;
          scenario_notes: string | null;
          status: SalesReturnStatus;
          row_version: number;
          requires_sale_refresh: boolean;
          collection_state: SalesReturnCollectionState;
          non_shipping_deduction_amount: string | number;
          deduction_reason: string | null;
          refund_difference_reason: string | null;
          returned_original_sale_amount: string | number | null;
          sales_revenue_reversal_amount: string | number | null;
          recovered_original_cost_amount: string | number | null;
          net_sales_profit_adjustment: string | number | null;
          gross_profit_reversal_amount: string | number | null;
          payment_fee_reversal_amount: string | number | null;
          net_profit_reversal_amount: string | number | null;
          approved_refund_amount: string | number | null;
          refund_fee_policy_snapshot: RefundFeePolicy | null;
          approved_at: string | null;
          approved_by: string | null;
          rejected_at: string | null;
          rejected_by: string | null;
          rejection_reason: string | null;
          reversed_at: string | null;
          reversed_by: string | null;
          reversal_reason: string | null;
          reversal_business_date: string | null;
          refund_finalized_at: string | null;
          refund_finalized_by: string | null;
          refund_final_variance_reason: string | null;
          updated_by: string | null;
        }>;
        Relationships: [];
      };

      // Phase 4 — Returns Core (migration 0082). sales_return_items_order_
      // item_active_uq (a partial unique index on sales_order_item_id WHERE
      // status='active') is the real DB-enforced double-return-prevention
      // backstop -- see PHASE_4_DESIGN_NOTES.md. Every *_snapshot column is
      // fixed at INSERT time (create_sales_return()/update_pending_sales_
      // return(), 0085/0086) and never re-read afterward, mirroring
      // sales_order_items' own snapshot columns.
      sales_return_items: {
        Row: {
          id: string;
          sales_return_id: string;
          sales_order_item_id: string;
          line_no: number;
          status: SalesReturnItemStatus;
          removed_at: string | null;
          removed_by: string | null;
          // Patch 4.1 (Section 5/6) — is_effective is the exclusive Approved
          // claim (replaces the pre-Patch status='active' unique index);
          // included_in_decision permanently marks the final item set as of
          // approve/reject, independent of later reversal.
          is_effective: boolean;
          included_in_decision: boolean;
          // Patch 4.1 (Section 3) — historical-only, no Inventory movement.
          condition: SalesReturnItemCondition;
          item_return_reason: string | null;
          item_notes: string | null;
          category_name_ar_snapshot: string;
          karat_code_snapshot: string;
          karat_name_ar_snapshot: string;
          weight_grams_snapshot: number;
          sale_price_snapshot: number;
          gold_component_cost_snapshot: number;
          manufacturing_component_cost_snapshot: number;
          base_cost_snapshot: number;
          vat_cost_snapshot: number;
          total_cost_snapshot: number;
          gross_profit_snapshot: number;
          item_calculation_version_snapshot: number;
          created_by: string | null;
          created_at: string;
        };
        Insert: {
          sales_return_id: string;
          sales_order_item_id: string;
          line_no: number;
          status?: SalesReturnItemStatus;
          is_effective?: boolean;
          included_in_decision?: boolean;
          condition?: SalesReturnItemCondition;
          item_return_reason?: string | null;
          item_notes?: string | null;
          category_name_ar_snapshot: string;
          karat_code_snapshot: string;
          karat_name_ar_snapshot: string;
          weight_grams_snapshot: string | number;
          sale_price_snapshot: string | number;
          gold_component_cost_snapshot: string | number;
          manufacturing_component_cost_snapshot: string | number;
          base_cost_snapshot: string | number;
          vat_cost_snapshot: string | number;
          total_cost_snapshot: string | number;
          gross_profit_snapshot: string | number;
          item_calculation_version_snapshot?: number;
          created_by?: string | null;
        };
        Update: Partial<{
          status: SalesReturnItemStatus;
          removed_at: string | null;
          removed_by: string | null;
          is_effective: boolean;
          included_in_decision: boolean;
          condition: SalesReturnItemCondition;
          item_return_reason: string | null;
          item_notes: string | null;
        }>;
        Relationships: [];
      };

      // Phase 4 — Returns Core (migration 0082). The actual-cash-refund
      // ledger -- fully independent from sales_returns.approved_refund_
      // amount (the computed target fixed at approval). Append-only in
      // spirit: amount/refund_method_id/notes are never edited, only
      // status active->reversed (soft-void), mirroring sales_order_items'
      // own soft-remove pattern.
      sales_return_refund_events: {
        Row: {
          id: string;
          sales_return_id: string;
          amount: number;
          refund_method_id: string;
          refund_business_date: string | null;
          refunded_at: string;
          notes: string | null;
          status: SalesReturnRefundEventStatus;
          reversed_at: string | null;
          reversed_by: string | null;
          reversal_business_date: string | null;
          reversal_reason: string | null;
          created_by: string | null;
        };
        Insert: {
          sales_return_id: string;
          amount: string | number;
          refund_method_id: string;
          refund_business_date?: string | null;
          refunded_at?: string;
          notes?: string | null;
          status?: SalesReturnRefundEventStatus;
          created_by?: string | null;
        };
        Update: Partial<{
          status: SalesReturnRefundEventStatus;
          reversed_at: string | null;
          reversed_by: string | null;
          reversal_business_date: string | null;
          reversal_reason: string | null;
        }>;
        Relationships: [];
      };

      // Patch 4.2 (Section 4, migration 0099) — append-only history of
      // refund-reconciliation finalize/reopen transitions. Never updated or
      // deleted; sales_returns.refund_finalized_at/by/refund_final_variance_
      // reason remain the CURRENT-state-only columns, this table is the full
      // "finalized -> reopened -> finalized again" audit trail.
      sales_return_refund_reconciliation_events: {
        Row: {
          id: string;
          sales_return_id: string;
          event_type: "finalized" | "reopened";
          actual_refunded_total: number;
          approved_refund_amount: number | null;
          variance: number;
          reason: string | null;
          actor: string | null;
          created_at: string;
        };
        Insert: {
          sales_return_id: string;
          event_type: "finalized" | "reopened";
          actual_refunded_total: string | number;
          approved_refund_amount?: string | number | null;
          variance: string | number;
          reason?: string | null;
          actor?: string | null;
        };
        Update: Partial<Record<string, never>>;
        Relationships: [];
      };

      // Phase 5 — Shipping Core (migration 0113). Reference Master Data —
      // direct RLS SELECT/INSERT/UPDATE gated on shipping_rates.view/manage,
      // same shape as karats/categories. code is opaque, never branched on
      // server-side (Section 3).
      shipping_carriers: {
        Row: {
          id: string;
          code: string;
          name_ar: string;
          name_en: string | null;
          carrier_type: ShippingCarrierType;
          status: ShippingMasterDataStatus;
          notes: string | null;
          created_at: string;
          updated_at: string;
          created_by: string | null;
          updated_by: string | null;
        };
        Insert: {
          code: string;
          name_ar: string;
          name_en?: string | null;
          carrier_type: ShippingCarrierType;
          status?: ShippingMasterDataStatus;
          notes?: string | null;
          created_by?: string | null;
          updated_by?: string | null;
        };
        Update: Partial<{
          name_ar: string;
          name_en: string | null;
          carrier_type: ShippingCarrierType;
          status: ShippingMasterDataStatus;
          notes: string | null;
          updated_by: string | null;
        }>;
        Relationships: [];
      };

      // Phase 5 — Shipping Core (migration 0113). Same access model as
      // shipping_carriers — configurable rate-zone labels, not geocoding.
      shipping_zones: {
        Row: {
          id: string;
          code: string;
          name_ar: string;
          name_en: string | null;
          status: ShippingMasterDataStatus;
          sort_order: number;
          notes: string | null;
          created_at: string;
          updated_at: string;
          created_by: string | null;
          updated_by: string | null;
        };
        Insert: {
          code: string;
          name_ar: string;
          name_en?: string | null;
          status?: ShippingMasterDataStatus;
          sort_order?: number;
          notes?: string | null;
          created_by?: string | null;
          updated_by?: string | null;
        };
        Update: Partial<{
          name_ar: string;
          name_en: string | null;
          status: ShippingMasterDataStatus;
          sort_order: number;
          notes: string | null;
          updated_by: string | null;
        }>;
        Relationships: [];
      };

      // Phase 5 — Shipping Core (migration 0114). Versioned carrier rate per
      // (carrier, zone, direction) — same NUMERIC/no-overlap/at-most-one-
      // future-version philosophy as manufacturing_fee_versions (Phase 2).
      // Never inserted/updated directly by app code — always via
      // create_shipping_carrier_rate_version()/cancel_shipping_carrier_
      // rate_version() (see Functions below).
      shipping_carrier_rate_versions: {
        Row: {
          id: string;
          carrier_id: string;
          shipping_zone_id: string;
          direction: ShipmentDirection;
          base_cost: number;
          effective_from: string;
          effective_to: string | null;
          status: FeeVersionStatus;
          notes: string | null;
          created_by: string | null;
          created_at: string;
        };
        Insert: {
          carrier_id: string;
          shipping_zone_id: string;
          direction: ShipmentDirection;
          base_cost: string | number;
          effective_from: string;
          effective_to?: string | null;
          status?: FeeVersionStatus;
          notes?: string | null;
          created_by?: string | null;
        };
        Update: Partial<Record<string, never>>;
        Relationships: [];
      };

      // Phase 5 — Shipping Core (migration 0115). Versioned STANDARD
      // customer-facing return shipping fee per zone (Section 8) — Shipping
      // Revenue only, entirely independent from sales_returns.non_shipping_
      // deduction_amount/approved_refund_amount. Never inserted/updated
      // directly — always via create_customer_return_shipping_fee_version()/
      // cancel_customer_return_shipping_fee_version().
      customer_return_shipping_fee_versions: {
        Row: {
          id: string;
          shipping_zone_id: string;
          fee_amount: number;
          effective_from: string;
          effective_to: string | null;
          status: FeeVersionStatus;
          notes: string | null;
          created_by: string | null;
          created_at: string;
        };
        Insert: {
          shipping_zone_id: string;
          fee_amount: string | number;
          effective_from: string;
          effective_to?: string | null;
          status?: FeeVersionStatus;
          notes?: string | null;
          created_by?: string | null;
        };
        Update: Partial<Record<string, never>>;
        Relationships: [];
      };

      // Phase 5 — Shipping Core (migration 0116). The Shipment header — zero
      // direct-write RLS policies (mixes profit-sensitive and non-sensitive
      // columns on one row, exactly like sales_orders/sales_returns). Never
      // inserted/updated directly by app code — always via create_shipment()/
      // add_shipment_status_event()/record_shipment_actual_cost()/correct_
      // shipment_actual_cost()/correct_shipment_customer_charge().
      shipments: {
        Row: {
          id: string;
          shipment_number: string;
          sales_order_id: string;
          sales_return_id: string | null;
          store_id: string;
          carrier_id: string;
          shipping_zone_id: string;
          direction: ShipmentDirection;
          fulfillment_type: ShipmentFulfillmentType;
          tracking_number: string | null;
          external_reference: string | null;
          customer_name_snapshot: string | null;
          customer_phone_snapshot: string | null;
          recipient_address_snapshot: string | null;
          shipment_date: string;
          // Section 20 — the immutable creation-time snapshot. NEVER
          // overwritten by correct_shipment_customer_charge() — only the
          // append-only shipment_financial_events ledger and the net_
          // shipping_expected/net_shipping_actual caches change.
          customer_shipping_charge: number;
          carrier_rate_version_id: string | null;
          expected_carrier_cost: number;
          expected_carrier_cost_is_manual: boolean;
          expected_carrier_cost_manual_reason: string | null;
          actual_carrier_cost: number | null;
          net_shipping_expected: number;
          net_shipping_actual: number | null;
          is_cod: boolean;
          cod_expected_amount: number | null;
          cod_collection_state: ShipmentCodCollectionState;
          current_status: ShipmentStatus;
          notes: string | null;
          row_version: number;
          created_by: string | null;
          updated_by: string | null;
          created_at: string;
          updated_at: string;
          // Patch 5.1 items 8/9 (migration 0125) — Customer Return Shipping
          // Fee Snapshot, return-direction only (NULL for outbound).
          customer_return_shipping_fee_version_id: string | null;
          customer_return_shipping_fee_standard_amount: number | null;
          customer_return_shipping_charge_is_override: boolean;
          customer_return_shipping_charge_override_reason: string | null;
          // Patch 5.1 item 17 (migration 0129) — historical carrier/zone
          // label snapshot, so a later Master Data rename never rewrites
          // how a past shipment displays.
          carrier_code_snapshot: string | null;
          carrier_name_snapshot: string | null;
          shipping_zone_code_snapshot: string | null;
          shipping_zone_name_snapshot: string | null;
        };
        Insert: {
          shipment_number: string;
          sales_order_id: string;
          sales_return_id?: string | null;
          store_id: string;
          carrier_id: string;
          shipping_zone_id: string;
          direction: ShipmentDirection;
          fulfillment_type?: ShipmentFulfillmentType;
          tracking_number?: string | null;
          external_reference?: string | null;
          customer_name_snapshot?: string | null;
          customer_phone_snapshot?: string | null;
          recipient_address_snapshot?: string | null;
          shipment_date: string;
          customer_shipping_charge: string | number;
          carrier_rate_version_id?: string | null;
          expected_carrier_cost: string | number;
          expected_carrier_cost_is_manual?: boolean;
          expected_carrier_cost_manual_reason?: string | null;
          net_shipping_expected: string | number;
          is_cod?: boolean;
          cod_expected_amount?: string | number | null;
          cod_collection_state?: ShipmentCodCollectionState;
          current_status?: ShipmentStatus;
          notes?: string | null;
          row_version?: number;
          created_by?: string | null;
          updated_by?: string | null;
          customer_return_shipping_fee_version_id?: string | null;
          customer_return_shipping_fee_standard_amount?: string | number | null;
          customer_return_shipping_charge_is_override?: boolean;
          customer_return_shipping_charge_override_reason?: string | null;
          carrier_code_snapshot?: string | null;
          carrier_name_snapshot?: string | null;
          shipping_zone_code_snapshot?: string | null;
          shipping_zone_name_snapshot?: string | null;
        };
        Update: Partial<{
          tracking_number: string | null;
          external_reference: string | null;
          actual_carrier_cost: string | number | null;
          net_shipping_expected: string | number;
          net_shipping_actual: string | number | null;
          cod_collection_state: ShipmentCodCollectionState;
          current_status: ShipmentStatus;
          notes: string | null;
          row_version: number;
          updated_by: string | null;
        }>;
        Relationships: [];
      };

      // Phase 5 — Shipping Core (migration 0116). Append-only status
      // timeline — NO UPDATE/DELETE, ever (trigger-enforced). Never
      // inserted directly by app code — always via create_shipment()/
      // add_shipment_status_event().
      shipment_status_events: {
        Row: {
          id: string;
          shipment_id: string;
          status: ShipmentStatus;
          event_business_date: string;
          event_at: string;
          notes: string | null;
          is_correction: boolean;
          external_reference: string | null;
          actor: string | null;
          created_at: string;
        };
        Insert: {
          shipment_id: string;
          status: ShipmentStatus;
          event_business_date: string;
          notes?: string | null;
          is_correction?: boolean;
          external_reference?: string | null;
          actor?: string | null;
        };
        Update: Partial<Record<string, never>>;
        Relationships: [];
      };

      // Phase 5 — Shipping Core (migration 0116). Unified append-only
      // financial correction ledger (actual carrier cost recording/
      // correction AND customer shipping charge correction) — NO UPDATE/
      // DELETE, ever (trigger-enforced). Never inserted directly by app
      // code — always via record_shipment_actual_cost()/correct_shipment_
      // actual_cost()/correct_shipment_customer_charge().
      shipment_financial_events: {
        Row: {
          id: string;
          shipment_id: string;
          event_type: ShipmentFinancialEventType;
          amount: number;
          business_date: string;
          reference: string | null;
          reason: string | null;
          actor: string | null;
          created_at: string;
        };
        Insert: {
          shipment_id: string;
          event_type: ShipmentFinancialEventType;
          amount: string | number;
          business_date: string;
          reference?: string | null;
          reason?: string | null;
          actor?: string | null;
        };
        Update: Partial<Record<string, never>>;
        Relationships: [];
      };

      // Phase 6 — Services / Adjustments Core (migration 0134). Layer-A
      // RLS lockdown (zero authenticated write policy, one narrow SELECT
      // policy) — all reads/writes actually go through the RPCs below.
      adjustment_types: {
        Row: {
          id: string;
          code: string;
          name_ar: string;
          name_en: string | null;
          description: string | null;
          status: "active" | "disabled";
          sort_order: number;
          created_by: string | null;
          updated_by: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          code: string;
          name_ar: string;
          name_en?: string | null;
          description?: string | null;
          status?: "active" | "disabled";
          sort_order?: number;
          created_by?: string | null;
          updated_by?: string | null;
        };
        Update: Partial<{
          name_ar: string;
          name_en: string | null;
          description: string | null;
          status: "active" | "disabled";
          sort_order: number;
          updated_by: string | null;
        }>;
        Relationships: [];
      };

      // Phase 6 — Services / Adjustments Core (migration 0135). Layer-A RLS
      // lockdown (zero authenticated policy at all) — every read/write goes
      // through the SECURITY DEFINER RPCs (0138-0142). direct_cost/payment_
      // fee_amount/gross_adjustment_profit/net_adjustment_profit are the
      // profit-sensitive columns the read RPCs redact without sales.view_
      // profit.
      // Patch 6.1 items 9/10/11 (migration 0144) — payment_method_id/
      // collection_channel_id are now NULLABLE (a genuinely free service,
      // customer_charge = 0, carries neither), and payment_reference is a
      // NEW optional column. Insert/Update stay unreachable for the
      // `authenticated` role regardless (Layer-A RLS lockdown, 0135) — this
      // type exists only for typing the SECURITY DEFINER RPCs' internal
      // shape, never a direct client write.
      sales_order_adjustments: {
        Row: {
          id: string;
          adjustment_number: string;
          sales_order_id: string;
          adjustment_type_id: string;
          adjustment_type_code_snapshot: string | null;
          adjustment_type_name_ar_snapshot: string | null;
          adjustment_type_name_en_snapshot: string | null;
          processing_store_id: string;
          adjustment_date: string;
          payment_method_id: string | null;
          payment_method_name_snapshot: string | null;
          collection_channel_id: string | null;
          collection_channel_name_snapshot: string | null;
          payment_reference: string | null;
          participates_in_settlement: boolean;
          customer_charge: number;
          direct_cost: number | null;
          payment_fee_version_id: string | null;
          payment_fee_percentage_snapshot: number | null;
          payment_fee_fixed_snapshot: number | null;
          payment_fee_amount: number | null;
          gross_adjustment_profit: number | null;
          net_adjustment_profit: number | null;
          status: "pending" | "approved" | "rejected";
          rejection_reason: string | null;
          notes: string | null;
          row_version: number;
          created_by: string | null;
          updated_by: string | null;
          approved_by: string | null;
          approved_at: string | null;
          rejected_by: string | null;
          rejected_at: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          adjustment_number: string;
          sales_order_id: string;
          adjustment_type_id: string;
          processing_store_id: string;
          adjustment_date: string;
          payment_method_id?: string | null;
          collection_channel_id?: string | null;
          payment_reference?: string | null;
          participates_in_settlement: boolean;
          customer_charge: string | number;
          direct_cost?: string | number | null;
          notes?: string | null;
          status?: "pending" | "approved" | "rejected";
          created_by?: string | null;
          updated_by?: string | null;
        };
        Update: Partial<{
          adjustment_type_id: string;
          processing_store_id: string;
          adjustment_date: string;
          payment_method_id: string | null;
          collection_channel_id: string | null;
          payment_reference: string | null;
          participates_in_settlement: boolean;
          customer_charge: string | number;
          direct_cost: string | number | null;
          notes: string | null;
          status: "pending" | "approved" | "rejected";
          row_version: number;
          updated_by: string | null;
        }>;
        Relationships: [];
      };

      // Phase 6 — Services / Adjustments Core (migration 0135). Append-only
      // administrative reversal ledger — UNIQUE(sales_order_adjustment_id),
      // NO UPDATE/DELETE ever (trigger-enforced). Layer-A RLS lockdown.
      // Patch 6.1 item 20 (migration 0150) adds 5 explicit signed impact
      // columns (customer_charge/direct_cost/payment_fee/gross_profit/net_
      // profit_reversal_amount) alongside the original positive snapshot —
      // "how much this reversal moves the Effective total by".
      sales_order_adjustment_reversals: {
        Row: {
          id: string;
          sales_order_adjustment_id: string;
          reversal_business_date: string;
          reason: string;
          customer_charge_snapshot: number;
          direct_cost_snapshot: number | null;
          payment_fee_amount_snapshot: number | null;
          gross_adjustment_profit_snapshot: number | null;
          net_adjustment_profit_snapshot: number | null;
          customer_charge_reversal_amount: number;
          direct_cost_reversal_amount: number;
          payment_fee_reversal_amount: number;
          gross_profit_reversal_amount: number;
          net_profit_reversal_amount: number;
          expected_row_version: number;
          reversed_by: string | null;
          created_at: string;
        };
        Insert: {
          sales_order_adjustment_id: string;
          reversal_business_date: string;
          reason: string;
          customer_charge_snapshot: string | number;
          direct_cost_snapshot?: string | number | null;
          payment_fee_amount_snapshot?: string | number | null;
          gross_adjustment_profit_snapshot?: string | number | null;
          net_adjustment_profit_snapshot?: string | number | null;
          customer_charge_reversal_amount?: string | number;
          direct_cost_reversal_amount?: string | number;
          payment_fee_reversal_amount?: string | number;
          gross_profit_reversal_amount?: string | number;
          net_profit_reversal_amount?: string | number;
          expected_row_version: number;
          reversed_by?: string | null;
        };
        Update: Partial<Record<string, never>>;
        Relationships: [];
      };

      // Phase 7 (migration 0170) — versioned transaction-fee configuration
      // per Settlement Route. Zero write RLS policy — create/cancel_
      // settlement_route_fee_version() (0171) are the entire write surface;
      // read here (SELECT RLS gated on settlements.view_financials) is used
      // ONLY for the fee-version history list on /master-data/settlement-
      // routes, purely for display. percentage_fee/fixed_fee/batch_fee_fixed
      // are raw NUMERIC columns (JSON-number over the wire, same caveat as
      // payment_method_fee_versions above) — display only, never fed into a
      // Decimal calculation client-side.
      settlement_route_fee_versions: {
        Row: {
          id: string;
          settlement_route_id: string;
          effective_from: string;
          effective_to: string | null;
          transaction_fee_strategy: string;
          transaction_fee_model: string | null;
          percentage_fee: number | null;
          fixed_fee: number | null;
          batch_fee_fixed: number;
          cod_fee_reversal_policy: string | null;
          status: string;
          notes: string | null;
          created_by: string | null;
          created_at: string;
        };
        Insert: Partial<Record<string, never>>;
        Update: Partial<Record<string, never>>;
        Relationships: [];
      };

      // Phase 7 (migration 0172) — Settlement Batch header. Zero direct RLS
      // policy (item 41) — create_draft_settlement_batch()/finalize_
      // settlement_batch()/reconcile_settlement_batch() (0177/0178/0180) are
      // the entire write surface; list_settlement_batches()/get_settlement_
      // batch() (0182) are the entire read surface, applying settlements.
      // view_financials redaction themselves. Every raw NUMERIC column here
      // is a JSON-number over the wire (never a string) — see the header
      // comment at the top of this file for why `number`, not `string`, is
      // correct. `reconciliation_reason` is a declared-but-never-written
      // column (0172 predates 0180's final design, which uses
      // `variance_reason` instead) — always NULL in practice, harmless,
      // left as-is rather than a schema-changing cleanup migration.
      settlement_batches: {
        Row: {
          id: string;
          settlement_number: string;
          settlement_route_id: string;
          settlement_date: string;
          status: string;
          provider_statement_reference: string | null;
          notes: string | null;
          route_code_snapshot: string | null;
          route_name_ar_snapshot: string | null;
          route_name_en_snapshot: string | null;
          route_kind_snapshot: string | null;
          payment_method_id_snapshot: string | null;
          payment_method_name_snapshot: string | null;
          collection_channel_id_snapshot: string | null;
          collection_channel_name_snapshot: string | null;
          shipping_carrier_id_snapshot: string | null;
          shipping_carrier_name_snapshot: string | null;
          route_fee_version_id_snapshot: string | null;
          transaction_fee_strategy_snapshot: string | null;
          transaction_percentage_fee_snapshot: number | null;
          transaction_fixed_fee_snapshot: number | null;
          batch_fee_snapshot: number;
          is_batch_fee_override: boolean;
          configured_batch_fee_snapshot: number | null;
          override_reason: string | null;
          gross_source_impact: number | null;
          provider_fee_impact: number | null;
          expected_before_batch_fee: number | null;
          expected_bank_settlement: number | null;
          settlement_calculation_version: number | null;
          row_version: number;
          finalized_at: string | null;
          finalized_by: string | null;
          reconciled_at: string | null;
          reconciled_by: string | null;
          reconciliation_reason: string | null;
          variance_reason: string | null;
          created_at: string;
          updated_at: string;
          created_by: string | null;
          updated_by: string | null;
        };
        Insert: Partial<Record<string, never>>;
        Update: Partial<Record<string, never>>;
        Relationships: [];
      };

      // Phase 7 (migration 0173) — one immutable financial-snapshot row per
      // source event claimed into a batch at Finalization. INSERT-only
      // forever (trigger-enforced), zero direct RLS policy — finalize_
      // settlement_batch() (0178) is the sole writer; get_settlement_batch()
      // (0182) is the sole reader, applying store-visibility filtering
      // itself (item 21).
      settlement_batch_lines: {
        Row: {
          id: string;
          settlement_batch_id: string;
          source_kind: string;
          source_event_id: string;
          source_number_snapshot: string;
          source_business_date: string;
          primary_store_id: string;
          secondary_store_id: string | null;
          primary_store_name_snapshot: string;
          secondary_store_name_snapshot: string | null;
          payment_method_id_snapshot: string | null;
          payment_method_name_snapshot: string | null;
          collection_channel_id_snapshot: string | null;
          collection_channel_name_snapshot: string | null;
          shipping_carrier_id_snapshot: string | null;
          shipping_carrier_name_snapshot: string | null;
          gross_collection_impact: number;
          provider_fee_impact: number;
          expected_settlement_impact: number;
          provider_fee_source: string;
          source_fee_version_id: string | null;
          route_fee_version_id: string | null;
          source_metadata: Record<string, unknown>;
          created_at: string;
        };
        Insert: Partial<Record<string, never>>;
        Update: Partial<Record<string, never>>;
        Relationships: [];
      };

      // Phase 7 (migration 0174) — append-only signed ledger of actual bank/
      // carrier movements against a Finalized settlement batch. Positive =
      // deposit/remittance received; negative = debit/withdrawal. Zero
      // direct RLS policy — record_settlement_bank_movement() (0179) is the
      // sole writer; get_settlement_batch()/list_settlement_batches() (0182)
      // are the sole readers.
      settlement_bank_movement_events: {
        Row: {
          id: string;
          settlement_batch_id: string;
          movement_business_date: string;
          amount: number;
          bank_reference: string | null;
          notes: string | null;
          created_at: string;
          created_by: string | null;
        };
        Insert: Partial<Record<string, never>>;
        Update: Partial<Record<string, never>>;
        Relationships: [];
      };

      // Phase 7 (migration 0174) — at most ONE reversal per bank movement
      // event (UNIQUE bank_movement_event_id), amount_impact = -original
      // amount, written authoritatively by reverse_settlement_bank_
      // movement() (0179). Zero direct RLS policy, same posture as the
      // events table above.
      settlement_bank_movement_reversals: {
        Row: {
          id: string;
          bank_movement_event_id: string;
          reversal_business_date: string;
          reason: string;
          amount_impact: number;
          created_at: string;
          created_by: string | null;
        };
        Insert: Partial<Record<string, never>>;
        Update: Partial<Record<string, never>>;
        Relationships: [];
      };
    };
    Views: Record<string, never>;
    Functions: {
      has_permission: { Args: { p_permission_key: string }; Returns: boolean };
      // The four below are service_role-only as of 0015 (they accept an
      // arbitrary p_user_id, which authenticated must never be able to
      // probe for another user). The app calls the self-scoped wrappers
      // underneath instead — kept here only because the functions still
      // exist in the schema (e.g. for future backend/service tooling).
      is_super_admin: { Args: { p_user_id: string }; Returns: boolean };
      is_active_user: { Args: { p_user_id: string }; Returns: boolean };
      get_user_permissions: { Args: { p_user_id: string }; Returns: { permission_key: string }[] };
      // Alias for user_operable_store_ids(uuid) as of 0017 — kept for name
      // stability. Still service_role-only.
      user_accessible_store_ids: { Args: { p_user_id: string }; Returns: string[] };
      // Active stores only — for anything that creates/updates NEW business
      // data. service_role-only (0017); app calls my_operable_store_ids().
      user_operable_store_ids: { Args: { p_user_id: string }; Returns: string[] };
      // Every store ever granted, active or disabled — for read-only
      // historical/report access. service_role-only (0017); app calls
      // my_visible_store_ids().
      user_visible_store_ids: { Args: { p_user_id: string }; Returns: string[] };
      // Self-scoped wrappers (0015, extended 0017) — always resolve against
      // auth.uid(); these are what the app actually calls.
      get_my_permissions: { Args: Record<string, never>; Returns: { permission_key: string }[] };
      am_i_super_admin: { Args: Record<string, never>; Returns: boolean };
      // Alias for my_operable_store_ids() as of 0017 — kept for name
      // stability.
      my_accessible_store_ids: { Args: Record<string, never>; Returns: string[] };
      my_operable_store_ids: { Args: Record<string, never>; Returns: string[] };
      my_visible_store_ids: { Args: Record<string, never>; Returns: string[] };
      // General-purpose audit writer — service_role-only as of 0016. Every
      // sensitive-table mutation is now logged automatically by a trigger;
      // the only remaining caller is the server-only failed-login path
      // (src/lib/audit/log-failed-login.ts), via the admin client.
      log_audit_event: {
        Args: {
          p_action: string;
          p_entity_type: string;
          p_entity_id?: string | null;
          p_old_values?: Json | null;
          p_new_values?: Json | null;
          p_reason?: string | null;
          p_ip_address?: string | null;
          p_user_agent?: string | null;
        };
        Returns: string;
      };
      // service_role-only as of 0023 (superseded log_auth_event(text), no
      // longer callable by `authenticated` at all — closed a gap where any
      // signed-in client could self-call it to fabricate login/logout
      // timeline entries). Called from src/features/auth/actions.ts via the
      // admin/service-role client, AFTER independently verifying the
      // session server-side. p_action must be 'auth.login_success' or
      // 'auth.logout'.
      log_auth_event_trusted: { Args: { p_user_id: string; p_action: string }; Returns: string };
      // Activates a freshly-created, still-pending_setup profile row on
      // behalf of the current users.create-holding admin (0016, WHERE
      // clause narrowed from 'suspended' to 'pending_setup' in 0019 — see
      // src/features/users/actions.ts's createUserAction).
      finalize_new_user_profile: {
        Args: {
          p_user_id: string;
          p_full_name: string;
          p_default_store_id: string | null;
          p_store_access_scope: string;
        };
        Returns: undefined;
      };
      // Atomically replaces a user's user_store_access grants (0018,
      // extended 0035 to leave out-of-range removal candidates untouched)
      // — see src/features/users/actions.ts's setUserStoreAccessAction.
      replace_user_store_access: { Args: { p_user_id: string; p_store_ids: string[] }; Returns: undefined };
      // Foundation Hardening 1.4, item 4 (0035): stores the CURRENT user may
      // manage store-access grants for — self-scoped, gated by
      // users.manage_store_access, independent of stores.view. See
      // src/features/users/queries.ts's listManageableStoresForActor().
      manageable_stores_for_actor: {
        Args: Record<string, never>;
        Returns: { id: string; code: string; name_ar: string; name_en: string; status: string }[];
      };
      // Foundation Audit Hotfix 1.4.2 (0039): trusted, service_role-only
      // replacement for log_user_invite_cancel (0038, now SUPERSEDED —
      // `authenticated` no longer has EXECUTE on it, closing a gap where any
      // staff member holding users.disable could call it directly and write
      // a false "cancelled" record without actually cancelling anything).
      // Writes the `user.invite_cancel` audit_logs row ONLY after
      // independently confirming a matching `user.delete` audit_logs row
      // already exists for the same target (i.e. the real deletion already
      // succeeded and was recorded) and that the supplied actor still holds
      // users.disable. Idempotent (a partial unique index on
      // audit_logs allows at most one row per target, ever). Called from
      // src/features/users/actions.ts's cancelUserInviteAction() via the
      // admin client, AFTER admin.auth.admin.deleteUser() succeeds, with the
      // actor id captured earlier from the acting staff member's own
      // verified session.
      log_user_invite_cancel_trusted: {
        Args: { p_actor_user_id: string; p_target_user_id: string; p_reason: string | null };
        Returns: string;
      };

      // ---------------------------------------------------------------
      // Phase 2 — Financial Master Data (migrations 0040-0046)
      // ---------------------------------------------------------------
      active_karats: { Args: Record<string, never>; Returns: Database["public"]["Tables"]["karats"]["Row"][] };
      save_daily_gold_price: {
        Args: { p_price_date: string; p_karat_id: string; p_price_per_gram: string | number; p_notes?: string | null };
        Returns: string;
      };
      // Financial Integrity Patch 2.1 (migration 0050) — atomic bulk upsert
      // for the "أسعار اليوم" fast-entry form; see
      // src/features/gold-prices/actions.ts. p_entries never carries
      // source_type/is_manual_override — the function always forces
      // manual/true regardless of what is sent.
      save_daily_gold_prices_bulk: {
        Args: {
          p_price_date: string;
          p_entries: { karat_id: string; price_per_gram: string | number; notes?: string | null }[];
        };
        Returns: string[];
      };
      // Returns SQL `numeric` -- PostgREST serializes it as an unquoted JSON
      // number (corrected from a prior, false "always returns string"
      // typing -- see daily_gold_prices.price_per_gram's comment above).
      // Any caller feeding this into a financial calculation must use
      // gold_price_for_karat_on_date_safe() (migration 0052) instead, never
      // this raw numeric-returning function.
      gold_price_for_karat_on_date: { Args: { p_karat_id: string; p_date?: string }; Returns: number };
      // Finance-safe sibling (migration 0052) -- casts ::text inside
      // Postgres before PostgREST ever serializes it, so this genuinely
      // returns a quoted JSON string, losslessly. Use this, not the
      // numeric-returning function above, for any value that will flow into
      // src/lib/decimal.ts's toDecimal().
      gold_price_for_karat_on_date_safe: { Args: { p_karat_id: string; p_date?: string }; Returns: string };
      gold_prices_missing_for_date: {
        Args: { p_date?: string };
        Returns: Database["public"]["Tables"]["karats"]["Row"][];
      };
      // Atomically ends the karat's current open version (if any) and
      // inserts the new one — see src/features/manufacturing-fees/actions.ts.
      create_manufacturing_fee_version: {
        Args: { p_karat_id: string; p_fee_per_gram: string | number; p_effective_from: string; p_notes?: string | null };
        Returns: string;
      };
      cancel_manufacturing_fee_version: { Args: { p_version_id: string }; Returns: undefined };
      // Returns SQL `numeric` -- unquoted JSON number over the wire, same as
      // gold_price_for_karat_on_date above. Use the _safe sibling below for
      // any financial calculation.
      manufacturing_fee_for_karat_on_date: { Args: { p_karat_id: string; p_date?: string }; Returns: number };
      manufacturing_fee_for_karat_on_date_safe: { Args: { p_karat_id: string; p_date?: string }; Returns: string };
      active_product_categories: {
        Args: Record<string, never>;
        Returns: Database["public"]["Tables"]["product_categories"]["Row"][];
      };
      create_payment_method_fee_version: {
        Args: {
          p_payment_method_id: string;
          p_percentage_fee: string | number;
          p_fixed_fee: string | number;
          p_effective_from: string;
          p_notes?: string | null;
        };
        Returns: string;
      };
      cancel_payment_method_fee_version: { Args: { p_version_id: string }; Returns: undefined };
      // percentage_fee/fixed_fee are SQL `numeric` -- unquoted JSON numbers
      // over the wire (corrected from a prior false "string" typing). Use
      // the _safe sibling below for any financial calculation.
      payment_fee_for_method_on_date: {
        Args: { p_payment_method_id: string; p_date?: string };
        Returns: { fee_version_id: string; percentage_fee: number; fixed_fee: number }[];
      };
      // Finance-safe sibling (migration 0052) -- both fee columns cast
      // ::text inside Postgres, so both are genuinely quoted JSON strings.
      payment_fee_for_method_on_date_safe: {
        Args: { p_payment_method_id: string; p_date?: string };
        Returns: { fee_version_id: string; percentage_fee: string; fixed_fee: string }[];
      };
      active_collection_channels: {
        Args: Record<string, never>;
        Returns: Database["public"]["Tables"]["collection_channels"]["Row"][];
      };

      // ---------------------------------------------------------------
      // Phase 3 — Sales Core (migrations 0058-0064)
      // ---------------------------------------------------------------
      create_vat_rate_version: {
        Args: { p_rate_percent: string | number; p_effective_from: string; p_notes?: string | null };
        Returns: string;
      };
      cancel_vat_rate_version: { Args: { p_version_id: string }; Returns: undefined };
      // Raw NUMERIC(6,3) -- unquoted JSON number. Use vat_rate_for_date_safe
      // below for any financial calculation.
      vat_rate_for_date: { Args: { p_date?: string }; Returns: number };
      vat_rate_for_date_safe: { Args: { p_date?: string }; Returns: string };

      // Additive (id, value) resolver siblings (0061) needed only by Sales
      // snapshot writes -- see that migration's Part A comment. Not
      // finance-safe-text (these feed server-side plpgsql, never the
      // browser) -- app code should never call these three directly.
      gold_price_version_for_karat_on_date: {
        Args: { p_karat_id: string; p_date?: string };
        Returns: { daily_gold_price_id: string; price_per_gram: number }[];
      };
      manufacturing_fee_version_for_karat_on_date: {
        Args: { p_karat_id: string; p_date?: string };
        Returns: { manufacturing_fee_version_id: string; fee_per_gram: number }[];
      };
      vat_rate_version_for_date: {
        Args: { p_date?: string };
        Returns: { vat_rate_version_id: string; rate_percent: number }[];
      };

      // The single transactional entry point for creating a Sale (spec
      // §11, migration 0061). p_items is a Decimal-safe JSON array (see
      // SalesOrderItemInput above) -- weight_grams/sale_price must be
      // sent as strings, never a prior JS Number computation. Returns the
      // server-issued id + order_number -- the client can never choose or
      // forge either.
      create_sales_order: {
        Args: {
          p_store_id: string;
          p_sale_date: string;
          p_payment_method_id: string;
          p_collection_channel_id: string;
          p_items: SalesOrderItemInput[];
          p_customer_name?: string | null;
          p_customer_phone?: string | null;
          p_notes?: string | null;
          p_closed_day_reason?: string | null;
        };
        Returns: { id: string; order_number: string }[];
      };

      // The single transactional entry point for editing a Sale (spec §18,
      // migration 0063; Patch 3.2 rewrite, migration 0075). No store_id/
      // sale_date parameter exists -- Phase 3 never allows changing
      // either. Items are wholesale-replaced. p_expected_version is the
      // optimistic-concurrency token (row_version from get_sales_order())
      // -- the SQL signature default-nulls it (so the old 8-arg overload
      // stays reachable at the DB level), but the function body itself
      // rejects a null value outright, so the app must always send the
      // real current row_version; never omit it or reuse a stale value
      // after a Conflict.
      update_sales_order: {
        Args: {
          p_order_id: string;
          p_payment_method_id: string;
          p_collection_channel_id: string;
          p_items: SalesOrderItemInput[];
          p_customer_name?: string | null;
          p_customer_phone?: string | null;
          p_notes?: string | null;
          p_closed_day_reason?: string | null;
          p_expected_version: number;
        };
        Returns: { id: string; order_number: string }[];
      };

      // Closes a store's business day (spec §19, migration 0064). No
      // reopen/delete function exists in Phase 3.
      close_sales_day: { Args: { p_store_id: string; p_business_date: string; p_notes?: string | null }; Returns: string };

      // Paginated Sales list (spec §16/§34, migration 0062; Patch 3.2
      // item 8, migration 0079). Profit columns are `null` for a caller
      // without sales.view_profit -- never the real value. Every
      // financial value is text. store_name/payment_method_name/
      // collection_channel_name are resolved server-side (same reasoning
      // as salesperson_name below) so the app no longer needs a second-
      // pass lookup against stores/payment_methods/collection_channels,
      // and no longer implicitly depends on the caller holding those
      // Master tables' own `.view` permission (item 8's actual fix).
      list_sales_orders: {
        Args: {
          p_date_from?: string | null;
          p_date_to?: string | null;
          p_store_id?: string | null;
          p_order_number?: string | null;
          p_salesperson_id?: string | null;
          p_payment_method_id?: string | null;
          p_collection_channel_id?: string | null;
          p_limit?: number;
          p_offset?: number;
        };
        Returns: {
          id: string;
          order_number: string;
          store_id: string;
          store_name: string;
          sale_date: string;
          salesperson_id: string;
          // Patch 3.1 item 11 (migration 0070) — resolved server-side via a
          // left join on profiles, so the /sales list and its salesperson
          // filter never require the caller to hold users.view.
          salesperson_name: string | null;
          payment_method_id: string;
          payment_method_name: string;
          collection_channel_id: string;
          collection_channel_name: string;
          customer_name: string | null;
          item_count: number;
          subtotal: string;
          gross_profit: string | null;
          payment_fee_amount: string | null;
          net_sales_profit: string | null;
          created_at: string;
          total_count: number;
        }[];
      };

      // Full Sale detail (spec §16/§18/§22, migration 0062; Patch 3.2
      // items 2/7/8, migration 0079). Returns jsonb -- profit-sensitive
      // keys are entirely ABSENT (not merely null) for a caller without
      // sales.view_profit. Cast/narrow at the call site (src/features/
      // sales) rather than widening this to a fixed shape. Now also
      // always includes (regardless of sales.view_profit, since neither
      // is profit-sensitive): store_name/payment_method_name/
      // collection_channel_name; row_version (needed as p_expected_version
      // on the next update_sales_order()/preview_update_sales_order()
      // call); and each active item's calculation_version.
      get_sales_order: { Args: { p_id: string }; Returns: Json };

      // Read-only fast-UX preview using the exact same rules as
      // create_sales_order() -- writes nothing (spec §17, migration 0062).
      // Returns jsonb for the same reason as get_sales_order above.
      // Patch 3.1 item 10 (migration 0070): gained p_collection_channel_id
      // as its 4th positional arg (before p_items), matching
      // create_sales_order()'s own argument order exactly, and now performs
      // the SAME validation create_sales_order() does (collection channel
      // active check, future-date rejection, closed-day surfacing).
      preview_sales_order: {
        Args: { p_store_id: string; p_sale_date: string; p_payment_method_id: string; p_collection_channel_id: string; p_items: SalesOrderItemInput[] };
        Returns: Json;
      };

      // Patch 3.2 item 5 (migration 0078) — Edit-mode preview, read-only.
      // Mirrors update_sales_order()'s own decision tree (unchanged item
      // -> preserved snapshot, changed item -> recalculated) instead of
      // treating every item as brand-new like preview_sales_order() above
      // does -- so a mid-edit preview matches what Save will actually
      // produce (item 5's parity fix). p_expected_version is validated
      // exactly like update_sales_order()'s -- a stale value surfaces the
      // same Conflict here, before the user even attempts to Save. Used
      // ONLY by the Edit form; the New Sale form keeps using
      // preview_sales_order() above.
      preview_update_sales_order: {
        Args: {
          p_order_id: string;
          p_expected_version: number;
          p_payment_method_id: string;
          p_collection_channel_id: string;
          p_items: SalesOrderItemInput[];
          p_customer_name?: string | null;
          p_customer_phone?: string | null;
          p_notes?: string | null;
        };
        Returns: Json;
      };

      // Patch 3.1 item 11 (migration 0070) — scoped salesperson dropdown
      // source for the /sales filter: distinct salespeople with >=1 Sale
      // within the caller's visible store scope. Requires sales.view only
      // -- never users.view, and never a general profiles listing.
      list_sales_salespersons: { Args: Record<string, never>; Returns: { id: string; full_name: string }[] };

      // Patch 3.2 item 6 (migration 0080) — Edit-mode lookup source for
      // category/karat/payment-method/collection-channel Selects: active
      // options PLUS the order's own currently-used value even if it has
      // since gone inactive (each option flagged is_historical). Prevents
      // the Edit form from either silently dropping a historical Sale's
      // real reference or letting the user pick a DIFFERENT inactive
      // option. Returns jsonb: { categories, karats, payment_methods,
      // collection_channels }, each an array of { id, name_ar, code?,
      // is_historical }.
      sales_order_edit_lookups: { Args: { p_order_id: string }; Returns: Json };

      // Phase 4 — Returns Core (migration 0085), rewritten by Returns
      // Integrity Patch 4.1 (migration 0093). p_items is now jsonb (per-item
      // condition/reason/notes, Section 3) instead of a bare uuid[].
      // p_expected_sale_version (Section 4 stale-sale guard), p_collection_
      // state, p_approved_refund_amount are new required business inputs;
      // p_non_shipping_deduction_amount/p_deduction_reason/p_refund_
      // difference_reason are new optional ones (Section 1). Every cost/
      // profit figure is still snapshotted from the CURRENT sales_order_
      // items/sales_orders rows -- never re-resolved from a price/fee/VAT
      // resolver. status starts 'pending'; the Section 12 financial-effect
      // columns stay NULL until approve_sales_return().
      create_sales_return: {
        Args: {
          p_sales_order_id: string;
          p_processed_store_id: string;
          p_return_date: string;
          p_scenario: SalesReturnScenario;
          p_items: ReturnItemInput[];
          p_expected_sale_version: number;
          p_collection_state: SalesReturnCollectionState;
          p_approved_refund_amount: string | number;
          p_non_shipping_deduction_amount?: string | number;
          p_deduction_reason?: string | null;
          p_refund_difference_reason?: string | null;
          p_scenario_notes?: string | null;
          p_closed_day_reason?: string | null;
        };
        Returns: { id: string; return_number: string }[];
      };

      // Phase 4 — Returns Core (migration 0085), rewritten 0093 (Section
      // 16). Read-only estimate of create_sales_return()'s eventual
      // figures, extended to accept the same Business Inputs create_sales_
      // return() does, computed via the SAME compute_sales_return_fee_
      // reversal() formula approve_sales_return() uses. Still not Source of
      // Truth -- approval recomputes and re-validates fully. Profit-
      // sensitive keys absent without sales.view_profit.
      // Patch 4.2 (Section 5, migration 0100) — gains p_scenario (new
      // positional parameter, right after p_items); the response jsonb now
      // also echoes back approved_refund_amount/refund_variance whenever the
      // caller supplied a p_approved_refund_amount, and applies the exact
      // same validation tree create_sales_return() does, whenever the
      // corresponding optional input is actually supplied.
      preview_sales_return: {
        Args: {
          p_sales_order_id: string;
          p_items: ReturnItemInput[];
          p_scenario?: SalesReturnScenario | null;
          p_collection_state?: SalesReturnCollectionState | null;
          p_non_shipping_deduction_amount?: string | number;
          p_deduction_reason?: string | null;
          p_approved_refund_amount?: string | number | null;
          p_refund_difference_reason?: string | null;
          p_fee_reversal_override?: string | number | null;
        };
        Returns: Json;
      };

      // Phase 4 — Returns Core (migration 0086), rewritten 0094. Edits a
      // still-'pending' return -- scenario/scenario_notes, the item set
      // (jsonb, Section 3), and the Section 1 business inputs (collection_
      // state/approved_refund_amount/deduction/refund_difference_reason)
      // are all editable; processed_store_id/return_date/sales_order_id/
      // sale_date_snapshot/source_sale_row_version are immutable here (only
      // refresh_pending_sales_return_from_sale() re-snapshots the Sale
      // basis, Section 4). Real optimistic concurrency.
      update_pending_sales_return: {
        Args: {
          p_return_id: string;
          p_scenario: SalesReturnScenario;
          p_items: ReturnItemInput[];
          p_collection_state: SalesReturnCollectionState;
          p_approved_refund_amount: string | number;
          p_expected_version: number;
          p_non_shipping_deduction_amount?: string | number;
          p_deduction_reason?: string | null;
          p_refund_difference_reason?: string | null;
          p_scenario_notes?: string | null;
          p_closed_day_reason?: string | null;
        };
        Returns: { id: string; return_number: string }[];
      };

      // Patch 4.1 (Section 4, new — migration 0093). The ONLY way a Pending
      // return's Sale-derived snapshots are ever re-taken after creation --
      // approve_sales_return() never does this implicitly, it rejects a
      // stale basis outright. Does not change the item set.
      refresh_pending_sales_return_from_sale: {
        Args: { p_return_id: string; p_expected_version: number };
        Returns: { id: string; return_number: string; row_version: number; source_sale_row_version: number }[];
      };

      // Phase 4 — Returns Core (migration 0087), rewritten by Patch 4.1
      // (migration 0095). Approves a 'pending' return -- the ONLY place
      // returned_original_sale_amount/sales_revenue_reversal_amount/
      // recovered_original_cost_amount/net_sales_profit_adjustment (Section
      // 12), plus the legacy gross_profit_reversal_amount/payment_fee_
      // reversal_amount/net_profit_reversal_amount, are ever computed and
      // written. Rejects if the Sale changed since this Pending return was
      // created/last refreshed (Section 4), or if any of its items is
      // already effectively claimed by another return (Section 5). Global
      // safe lock order documented in 0095 (Section 19) -- no deadlock
      // against update_sales_order(). Signature unchanged from 0087.
      approve_sales_return: {
        Args: {
          p_return_id: string;
          p_expected_version: number;
          p_fee_reversal_override?: string | number | null;
          p_closed_day_reason?: string | null;
        };
        Returns: { id: string; return_number: string }[];
      };

      // Phase 4 — Returns Core (migration 0087), rewritten by Patch 4.1
      // (migration 0095, Section 6). Rejects a 'pending' return -- terminal,
      // non-effective outcome. No longer soft-removes sales_return_items --
      // only included_in_decision is set on the items active at the moment
      // of rejection, preserving them in get_sales_return()'s historical
      // view forever after. Store scope relaxed to VISIBLE (Section 13).
      reject_sales_return: {
        Args: { p_return_id: string; p_expected_version: number; p_rejection_reason: string };
        Returns: { id: string; return_number: string }[];
      };

      // Phase 4 — Returns Core (migration 0088), rewritten by Patch 4.1
      // (migration 0096). Reverses an 'approved' return. No longer soft-
      // removes sales_return_items (Section 6) -- only is_effective flips
      // back to false, releasing sales_return_items_effective_claim_uq
      // (0092) while every historical figure/item stays visible. Gains an
      // independent reversal_business_date (defaults to business_today())
      // with its own Daily Close check (Section 9). Store scope relaxed to
      // VISIBLE (Section 13). Does NOT touch sales_return_refund_events.
      reverse_sales_return: {
        Args: {
          p_return_id: string;
          p_expected_version: number;
          p_reversal_reason: string;
          p_reversal_business_date?: string | null;
          p_closed_day_reason?: string | null;
        };
        Returns: { id: string; return_number: string }[];
      };

      // Phase 4 — Returns Core (migration 0089), rewritten by Patch 4.1
      // (migration 0097) and Hotfix 4.2.1 (migration 0107). Appends one
      // entry to the actual-cash-refund ledger against an 'approved' return
      // -- fully independent from sales_returns.approved_refund_amount (the
      // computed target). Rejects (never silently rounds) an amount with
      // more than 2 decimal places (Section 10). Gains an independent
      // refund_business_date (defaults to business_today()) with its own
      // Daily Close check (Section 9). Store scope relaxed to VISIBLE
      // (Section 13). Hotfix 4.2.1 (Section 6): gains an optional
      // p_reference (external reference -- bank transfer/gateway number),
      // stored permanently on the (now genuinely append-only, Section 1)
      // event row.
      record_sales_return_refund: {
        Args: {
          p_return_id: string;
          p_amount: string | number;
          p_refund_method_id: string;
          p_refund_business_date?: string | null;
          p_notes?: string | null;
          p_closed_day_reason?: string | null;
          p_reference?: string | null;
        };
        Returns: { id: string; sales_return_id: string; amount: string }[];
      };

      // Phase 4 — Returns Core (migration 0089), rewritten by Patch 4.1
      // (migration 0097) and Hotfix 4.2.1 (migration 0107, Section 1).
      // Hotfix 4.2.1: genuinely append-only now -- INSERTs into the new
      // sales_return_refund_event_reversals ledger instead of UPDATEing the
      // original event row (which is now trigger-protected, migration
      // 0106, from any UPDATE/DELETE outside a migration backfill).
      // amount/refund_method_id/notes/reference/refunded_at stay permanent,
      // exactly as before, just now enforced at the database level rather
      // than by convention alone. Gains an independent
      // reversal_business_date (Section 9) with its own Daily Close check.
      // Store scope relaxed to VISIBLE (Section 13). Rejects a second
      // reversal of the same event (unique(refund_event_id)).
      reverse_sales_return_refund_event: {
        Args: {
          p_event_id: string;
          p_reversal_reason: string;
          p_reversal_business_date?: string | null;
          p_closed_day_reason?: string | null;
        };
        Returns: { id: string }[];
      };

      // Patch 4.1 (Section 11, new — migration 0097). Declares refund
      // reconciliation for one return complete; requires refund_final_
      // variance_reason iff actual_refunded_total (sum of active refund
      // events) does not equal approved_refund_amount. A return with
      // approved_refund_amount=0 can be finalized with zero refund events
      // ever recorded (Section 18-K).
      finalize_sales_return_refund: {
        Args: { p_return_id: string; p_expected_version: number; p_variance_reason?: string | null };
        Returns: { id: string; return_number: string; actual_refunded_total: string; refund_variance: string }[];
      };

      // Patch 4.2 (Section 4, new — migration 0103). The explicit, reason-
      // required escape hatch from a Finalized refund reconciliation.
      // Requires returns.record_refund + a non-empty reason + a matching
      // row_version. Appends a 'reopened' row to sales_return_refund_
      // reconciliation_events BEFORE clearing sales_returns.refund_
      // finalized_at/by/refund_final_variance_reason — the prior 'finalized'
      // history entry is never erased. After this succeeds, record_sales_
      // return_refund()/reverse_sales_return_refund_event() become callable
      // again and finalize_sales_return_refund() can run once more.
      reopen_sales_return_refund_reconciliation: {
        Args: { p_return_id: string; p_expected_version: number; p_reason: string };
        Returns: { id: string; return_number: string }[];
      };

      // Phase 4 — Returns Core (migration 0090), rewritten by Patch 4.1
      // (migration 0098, Section 14). Paginated Returns list, scoped by
      // processed_store_id via user_visible_store_ids(). Adds original_
      // store_id/order_number/scenario filters. item_count uses status=
      // 'active' OR included_in_decision=true (Section 6) -- never zero for
      // a Rejected/Reversed return. Profit columns NULL without sales.
      // view_profit.
      list_sales_returns: {
        Args: {
          p_date_from?: string | null;
          p_date_to?: string | null;
          p_processed_store_id?: string | null;
          p_original_store_id?: string | null;
          p_return_number?: string | null;
          p_order_number?: string | null;
          p_status?: SalesReturnStatus | null;
          p_scenario?: SalesReturnScenario | null;
          p_sales_order_id?: string | null;
          p_limit?: number;
          p_offset?: number;
        };
        Returns: {
          id: string;
          return_number: string;
          sales_order_id: string;
          order_number: string;
          original_store_id: string;
          original_store_name: string | null;
          processed_store_id: string;
          processed_store_name: string | null;
          sale_date: string;
          return_date: string;
          status: SalesReturnStatus;
          scenario: SalesReturnScenario;
          collection_state: SalesReturnCollectionState;
          // Patch 4.2 (Section 1/14, migration 0104).
          requires_sale_refresh: boolean;
          item_count: number;
          returned_original_sale_amount: string | null;
          non_shipping_deduction_amount: string | null;
          sales_revenue_reversal_amount: string | null;
          approved_refund_amount: string | null;
          actual_refunded_total: string;
          refund_variance: string;
          refund_reconciliation_state: SalesReturnRefundReconciliationState;
          recovered_original_cost_amount: string | null;
          payment_fee_reversal_amount: string | null;
          // Hotfix 4.2.1 (Section 13, migration 0111). 1 = computed by the
          // original item-value-basis engine (pre-Hotfix 4.2.1 approvals);
          // 2 = computed by the approved-refund-amount-basis engine
          // (compute_sales_return_fee_reversal_v2(), migration 0109). null
          // for a return never approved. NULL (not just gated) without
          // sales.view_profit, same as payment_fee_reversal_amount.
          payment_fee_reversal_calculation_version: number | null;
          net_sales_profit_adjustment: string | null;
          adjusted_order_net_sales_profit: string | null;
          gross_profit_reversal_amount: string | null;
          net_profit_reversal_amount: string | null;
          created_at: string;
          total_count: number;
        }[];
      };

      // Phase 4 — Returns Core (migration 0090), rewritten by Patch 4.1
      // (migration 0098, Sections 6/12/14), extended by Patch 4.2 (migration
      // 0104, Sections 1/4) and Hotfix 4.2.1 (migration 0111, Sections
      // 4/6/13/17). Full Return detail, scoped via user_visible_store_ids()
      // on processed_store_id. Returns jsonb -- profit-sensitive keys
      // entirely ABSENT without sales.view_profit. Items visible if
      // status='active' OR included_in_decision=true (Section 6) -- a
      // Rejected/Reversed return never shows zero items. Includes requires_
      // sale_refresh and reconciliation_history (not profit-gated). Hotfix
      // 4.2.1: refund_events[].status/reversed_at/reversal_business_date/
      // reversal_reason are now DERIVED from sales_return_refund_event_
      // reversals (never the legacy status column); each event also gains
      // reference/refund_method_name_snapshot. payment_fee_reversal_
      // calculation_version exposed alongside payment_fee_reversal_amount
      // (profit-gated).
      get_sales_return: { Args: { p_id: string }; Returns: Json };

      // Patch 4.2 (Section 7, new — migration 0105). Three narrow, Returns-
      // permission-gated label lookups ({id, name_ar} only) replacing direct
      // `stores`/`payment_methods` table reads (which depended on stores.
      // view/payment_methods.view via RLS) -- a custom role holding only
      // Returns permissions never needs a Master Data browse permission.
      returns_operable_store_lookups: { Args: Record<string, never>; Returns: { id: string; name_ar: string }[] };
      returns_visible_store_lookups: { Args: Record<string, never>; Returns: { id: string; name_ar: string }[] };
      returns_refund_method_lookups: { Args: Record<string, never>; Returns: { id: string; name_ar: string }[] };

      // Phase 4 — Returns Core (migration 0090), rewritten by Patch 4.1
      // (migration 0098, Sections 4/5) and Hotfix 4.2.1 (migration 0112,
      // Section 15). Everything the New Return flow needs for one Sale --
      // order basics (including row_version, for p_expected_sale_version),
      // every active item flagged `returnable` (based on is_effective, not
      // mere active membership -- a second pending return on the same item
      // is allowed), the DERIVED order_state, and the order's existing
      // returns. Hotfix 4.2.1: requires returns.create ONLY -- sales.view
      // is no longer a Returns prerequisite (it never should have been;
      // returns.create was always meant to stand alone).
      get_returnable_sales_order: { Args: { p_sales_order_id: string }; Returns: Json };

      // Hotfix 4.2.1 (Section 15, new — migration 0112). The Returns-only
      // Sale-search lookup for the New Return flow's order-number search
      // step, replacing a hidden dependency on list_sales_orders() (0079,
      // gated on sales.view). Gated on returns.create ONLY, scoped by
      // user_visible_store_ids(). Returns only the columns the search
      // step renders -- no profit fields, no route into the Sales module.
      search_sales_orders_for_return: {
        Args: { p_order_number?: string | null; p_limit?: number };
        Returns: {
          id: string;
          order_number: string;
          sale_date: string;
          store_id: string;
          store_name: string | null;
          customer_name: string | null;
          subtotal: string;
        }[];
      };

      // Phase 5 — Shipping Core (migration 0114). Same versioning shape as
      // create_manufacturing_fee_version()/cancel_manufacturing_fee_version()
      // (Phase 2) — gated on shipping_rates.manage.
      create_shipping_carrier_rate_version: {
        Args: {
          p_carrier_id: string;
          p_shipping_zone_id: string;
          p_direction: string;
          p_base_cost: string | number;
          p_effective_from: string;
          p_notes?: string | null;
        };
        Returns: string;
      };
      cancel_shipping_carrier_rate_version: { Args: { p_version_id: string }; Returns: void };

      // Phase 5 — Shipping Core (migration 0115). Gated on shipping_rates.manage.
      create_customer_return_shipping_fee_version: {
        Args: { p_shipping_zone_id: string; p_fee_amount: string | number; p_effective_from: string; p_notes?: string | null };
        Returns: string;
      };
      cancel_customer_return_shipping_fee_version: { Args: { p_version_id: string }; Returns: void };

      // Hotfix 5.1.1 item 5 (migration 0132) — text-safe replacements for
      // the Shipping Rate Admin UI's raw `.from(...).select("*")` reads of
      // shipping_carrier_rate_versions/customer_return_shipping_fee_
      // versions: base_cost/fee_amount arrive ::text, never a raw NUMERIC
      // -> JS number over the wire. Same shipping_rates.view gate the
      // tables' own RLS SELECT policies already require.
      list_shipping_carrier_rate_versions_safe: {
        Args: Record<string, never>;
        Returns: {
          id: string;
          carrier_id: string;
          shipping_zone_id: string;
          direction: ShipmentDirection;
          base_cost: string;
          effective_from: string;
          effective_to: string | null;
          status: string;
          notes: string | null;
          created_by: string | null;
          created_at: string;
        }[];
      };
      list_customer_return_shipping_fee_versions_safe: {
        Args: Record<string, never>;
        Returns: {
          id: string;
          shipping_zone_id: string;
          fee_amount: string;
          effective_from: string;
          effective_to: string | null;
          status: string;
          notes: string | null;
          created_by: string | null;
          created_at: string;
        }[];
      };

      // Phase 5 — Shipping Core (migration 0117). Narrow, shipments.create-
      // gated previews the /shipments/new UI calls before submission —
      // NEVER requires shipping_rates.view. found=false means no
      // configuration exists for that exact (carrier, zone, direction,
      // date) — the UI must then collect a manual expected cost + reason.
      preview_shipment_expected_cost: {
        Args: { p_carrier_id: string; p_shipping_zone_id: string; p_direction: string; p_shipment_date?: string };
        Returns: { found: boolean; rate_version_id: string | null; expected_carrier_cost: string | null }[];
      };
      // found=false means no standard fee configured for the zone — the
      // actor must enter p_customer_shipping_charge explicitly. The
      // suggestion may always be overridden (Section 20) — create_shipment
      // never silently substitutes this for whatever was actually submitted.
      preview_customer_return_shipping_fee: {
        Args: { p_shipping_zone_id: string; p_date?: string };
        Returns: { found: boolean; rate_version_id: string | null; fee_amount: string | null }[];
      };

      // Phase 5 — Shipping Core (migration 0117). The single transactional
      // entry point for creating a Shipment (outbound or return). Section
      // 34's full validation chain — see create_shipment()'s own comment in
      // 0117 for the complete order of operations.
      create_shipment: {
        Args: {
          p_sales_order_id: string;
          p_store_id: string;
          p_shipment_date: string;
          p_direction: string;
          p_carrier_id: string;
          p_shipping_zone_id: string;
          p_customer_shipping_charge: string | number;
          p_sales_return_id?: string | null;
          p_fulfillment_type?: string;
          p_tracking_number?: string | null;
          p_external_reference?: string | null;
          p_customer_name?: string | null;
          p_customer_phone?: string | null;
          p_recipient_address?: string | null;
          p_is_cod?: boolean;
          p_cod_expected_amount?: string | number | null;
          p_manual_expected_cost?: string | number | null;
          p_manual_expected_cost_reason?: string | null;
          p_notes?: string | null;
          p_closed_day_reason?: string | null;
          // Patch 5.1 items 8/9 (migration 0125) — mandatory when the
          // resolved return-direction fee is being overridden.
          p_customer_return_shipping_charge_override_reason?: string | null;
        };
        Returns: { id: string; shipment_number: string }[];
      };

      // Phase 5 — Shipping Core (migration 0118). Appends a status_event and
      // transactionally advances shipments.current_status. A NORMAL forward
      // transition needs only shipments.update_status; any other transition
      // is a CORRECTION — needs shipments.correct_status AND a non-empty
      // p_reason. Optimistic concurrency via p_expected_version/row_version.
      add_shipment_status_event: {
        Args: {
          p_shipment_id: string;
          p_new_status: string;
          p_expected_version: number;
          p_event_business_date: string;
          p_notes?: string | null;
          p_external_reference?: string | null;
          p_reason?: string | null;
        };
        Returns: { row_version: number }[];
      };

      // Phase 5 — Shipping Core (migration 0118). Records the FIRST real
      // carrier invoice amount. Rejects if one already exists (use
      // correct_shipment_actual_cost() instead). Gated on shipments.
      // manage_cost.
      record_shipment_actual_cost: {
        Args: {
          p_shipment_id: string;
          p_expected_version: number;
          p_amount: string | number;
          p_business_date: string;
          p_reference?: string | null;
          p_notes?: string | null;
          p_closed_day_reason?: string | null;
        };
        Returns: { row_version: number }[];
      };

      // Phase 5 — Shipping Core (migration 0118). Mandatory-reason
      // correction to an already-recorded actual carrier cost. Requires a
      // prior actual-cost event to exist. Gated on shipments.manage_cost.
      correct_shipment_actual_cost: {
        Args: {
          p_shipment_id: string;
          p_expected_version: number;
          p_amount: string | number;
          p_business_date: string;
          p_reason: string;
          p_reference?: string | null;
          p_closed_day_reason?: string | null;
        };
        Returns: { row_version: number }[];
      };

      // Phase 5 — Shipping Core (migration 0118). Mandatory-reason
      // correction to the customer-facing shipping charge. shipments.
      // customer_shipping_charge (the creation snapshot) is NEVER
      // overwritten — only the append-only ledger + net_shipping_expected/
      // net_shipping_actual caches change. Gated on shipments.manage_cost.
      correct_shipment_customer_charge: {
        Args: {
          p_shipment_id: string;
          p_expected_version: number;
          p_amount: string | number;
          p_business_date: string;
          p_reason: string;
          p_reference?: string | null;
          p_closed_day_reason?: string | null;
        };
        Returns: { row_version: number }[];
      };

      // Phase 5 — Shipping Core (migration 0119). Full single-shipment read
      // — header + append-only status timeline (never profit-gated) + the
      // full financial correction ledger and every money field (entirely
      // absent without sales.view_profit). Gated on shipments.view.
      get_shipment: { Args: { p_id: string }; Returns: Json };

      // Phase 5 — Shipping Core (migration 0119). The /shipments list page
      // data source. Every money/cost column returned as SQL NULL (never a
      // fabricated 0.00) without sales.view_profit. Gated on shipments.view.
      // Phase 5 (0119), signature/columns extended by Patch 5.1 item 12
      // (migration 0126) — new text filters (order_number/return_number),
      // the original-Sale-store filter (distinct from the processing
      // store), and cod_collection_state. customer_shipping_charge and
      // has_actual_carrier_cost are ALWAYS populated (items 10/23), never
      // profit-gated; carrier/zone code+name are read from the shipment's
      // own historical snapshot columns as of migration 0129.
      list_shipments: {
        Args: {
          p_date_from?: string | null;
          p_date_to?: string | null;
          p_store_id?: string | null;
          p_carrier_id?: string | null;
          p_shipping_zone_id?: string | null;
          p_direction?: string | null;
          p_current_status?: string | null;
          p_shipment_number?: string | null;
          p_tracking_number?: string | null;
          p_sales_order_id?: string | null;
          p_sales_return_id?: string | null;
          p_limit?: number;
          p_offset?: number;
          p_order_number?: string | null;
          p_return_number?: string | null;
          p_original_sale_store_id?: string | null;
          p_cod_collection_state?: string | null;
        };
        Returns: {
          id: string;
          shipment_number: string;
          sales_order_id: string;
          order_number: string | null;
          sales_return_id: string | null;
          return_number: string | null;
          store_id: string;
          store_name: string | null;
          original_sale_store_id: string | null;
          original_sale_store_name: string | null;
          carrier_id: string;
          carrier_code: string | null;
          carrier_name: string | null;
          shipping_zone_id: string;
          zone_code: string | null;
          zone_name: string | null;
          direction: ShipmentDirection;
          fulfillment_type: ShipmentFulfillmentType;
          tracking_number: string | null;
          customer_name: string | null;
          customer_phone: string | null;
          shipment_date: string;
          is_cod: boolean;
          cod_collection_state: ShipmentCodCollectionState;
          current_status: ShipmentStatus;
          row_version: number;
          customer_shipping_charge: string | null;
          customer_return_shipping_charge_is_override: boolean | null;
          has_actual_carrier_cost: boolean;
          expected_carrier_cost: string | null;
          expected_carrier_cost_is_manual: boolean | null;
          actual_carrier_cost: string | null;
          net_shipping_expected: string | null;
          net_shipping_actual: string | null;
          created_at: string;
          total_count: number;
        }[];
      };

      // Phase 5 — Shipping Core (migration 0120). Narrow, permission-
      // specific lookups (same style as returns_operable_store_lookups()/
      // returns_visible_store_lookups(), 0105) — never require a Master-
      // Data browse permission.
      shipments_operable_store_lookups: { Args: Record<string, never>; Returns: { id: string; name_ar: string }[] };
      shipments_visible_store_lookups: { Args: Record<string, never>; Returns: { id: string; name_ar: string }[] };
      shipments_carrier_lookups: {
        Args: Record<string, never>;
        Returns: { id: string; code: string; name_ar: string; carrier_type: ShippingCarrierType }[];
      };
      shipments_zone_lookups: { Args: Record<string, never>; Returns: { id: string; code: string; name_ar: string }[] };

      // Patch 5.1 item 11 (migration 0126) — the /shipments LIST filter
      // bar's picker, gated on shipments.view ALONE (unlike shipments_
      // carrier_lookups/shipments_zone_lookups above, which stay shipments.
      // create-gated for /shipments/new). Also surfaces a disabled
      // carrier/zone still referenced by a visible historical shipment.
      shipments_filter_carrier_lookups: {
        Args: Record<string, never>;
        Returns: { id: string; code: string; name_ar: string; carrier_type: ShippingCarrierType; status: string }[];
      };
      shipments_filter_zone_lookups: {
        Args: Record<string, never>;
        Returns: { id: string; code: string; name_ar: string; status: string }[];
      };

      // Patch 5.1 items 13/14 (migration 0127) — append-only COD collection-
      // state event + transactionally-maintained shipments.cod_collection_
      // state cache. Gated on shipments.manage_cost (Financial/Settlement-
      // adjacent), Daily Close-checked, optimistic concurrency.
      record_shipment_cod_collection_state: {
        Args: {
          p_shipment_id: string;
          p_expected_version: number;
          p_new_state: string;
          p_business_date: string;
          p_reference?: string | null;
          p_notes?: string | null;
          p_closed_day_reason?: string | null;
        };
        Returns: { row_version: number }[];
      };
      search_sales_orders_for_shipment: {
        Args: { p_order_number?: string | null; p_limit?: number };
        Returns: {
          id: string;
          order_number: string;
          sale_date: string;
          store_id: string;
          store_name: string | null;
          customer_name: string | null;
          customer_phone: string | null;
        }[];
      };
      // Only status IN (approved, reversed) — matches create_shipment()'s
      // own eligibility check exactly.
      search_sales_returns_for_shipment: {
        Args: { p_return_number?: string | null; p_sales_order_id?: string | null; p_limit?: number };
        Returns: {
          id: string;
          return_number: string;
          return_date: string;
          status: SalesReturnStatus;
          sales_order_id: string;
          order_number: string | null;
          processed_store_id: string;
          store_name: string | null;
        }[];
      };

      // Phase 6 — Services / Adjustments Core (migrations 0133-0143).
      // adjustment_types CRUD (0136) — every write requires
      // adjustments.manage_types. `code` is only accepted on create.
      create_adjustment_type: {
        Args: { p_code: string; p_name_ar: string; p_name_en?: string | null; p_description?: string | null; p_sort_order?: number };
        Returns: string;
      };
      update_adjustment_type: {
        Args: { p_id: string; p_name_ar: string; p_name_en?: string | null; p_description?: string | null; p_sort_order?: number };
        Returns: undefined;
      };
      disable_adjustment_type: { Args: { p_id: string }; Returns: undefined };
      enable_adjustment_type: { Args: { p_id: string }; Returns: undefined };
      // Narrow lookups (0136/0137) — each gated on the SPECIFIC Adjustments
      // permission that legitimately needs it, never sales.view/stores.view/
      // payment_methods.view/collection_channels.view.
      adjustments_active_type_lookups: { Args: Record<string, never>; Returns: { id: string; code: string; name_ar: string }[] };
      adjustment_types_admin_list: {
        Args: Record<string, never>;
        Returns: {
          id: string;
          code: string;
          name_ar: string;
          name_en: string | null;
          description: string | null;
          status: string;
          sort_order: number;
          created_at: string;
          updated_at: string;
        }[];
      };
      adjustments_operable_store_lookups: { Args: Record<string, never>; Returns: { id: string; name_ar: string }[] };
      adjustments_visible_store_lookups: { Args: Record<string, never>; Returns: { id: string; name_ar: string }[] };
      adjustments_payment_method_lookups: { Args: Record<string, never>; Returns: { id: string; key: string; name_ar: string }[] };
      adjustments_collection_channel_lookups: { Args: Record<string, never>; Returns: { id: string; key: string; name_ar: string }[] };
      // Patch 6.1 item 22 (migration 0152) — VIEW-only historical filter
      // lookups for the /adjustments list page, gated on adjustments.view
      // ALONE (never adjustments.create like the CREATE-flow pickers
      // above). Full catalog including disabled/inactive.
      adjustments_filter_type_lookups: { Args: Record<string, never>; Returns: { id: string; code: string; name_ar: string }[] };
      adjustments_filter_payment_method_lookups: { Args: Record<string, never>; Returns: { id: string; key: string; name_ar: string }[] };
      adjustments_filter_collection_channel_lookups: { Args: Record<string, never>; Returns: { id: string; key: string; name_ar: string }[] };
      // §25 — gated on adjustments.create ALONE, never sales.view.
      search_sales_orders_for_adjustment: {
        Args: { p_search?: string | null; p_limit?: number };
        Returns: {
          sales_order_id: string;
          order_number: string;
          sale_date: string;
          store_name: string | null;
          customer_name: string | null;
          customer_phone: string | null;
          original_invoice_amount: string;
        }[];
      };
      // §11/§35, v2 (migration 0155, Patch 6.1 items 7/9/10) —
      // non-authoritative preview; approve_sales_order_adjustment()
      // recomputes everything from scratch and ignores this.
      // p_payment_method_id is now OPTIONAL — a zero-charge (free service)
      // preview needs none; fee is forced to 0.00 unconditionally.
      preview_sales_order_adjustment: {
        Args: { p_payment_method_id?: string | null; p_customer_charge?: string | number | null; p_direct_cost?: string | number | null; p_adjustment_date?: string };
        Returns: {
          fee_found: boolean;
          customer_charge: string;
          payment_fee_percentage: string | null;
          payment_fee_fixed: string | null;
          payment_fee_amount: string | null;
          direct_cost: string | null;
          gross_adjustment_profit: string | null;
          net_adjustment_profit: string | null;
        }[];
      };
      // §36, v2 (migration 0146, Patch 6.1 items 1A/9/10/11) — creates a
      // PENDING record only. p_direct_cost is not null now REQUIRES
      // adjustments.manage_cost, rejected otherwise. p_payment_method_id/
      // p_collection_channel_id are now OPTIONAL — required for a paid
      // record (customer_charge > 0), must be omitted/null for a genuinely
      // free service (customer_charge = 0), which forces participates_in_
      // settlement to false server-side regardless of what's sent.
      // p_payment_reference is a NEW optional trailing parameter.
      create_sales_order_adjustment: {
        Args: {
          p_sales_order_id: string;
          p_adjustment_type_id: string;
          p_processing_store_id: string;
          p_adjustment_date: string;
          p_payment_method_id?: string | null;
          p_collection_channel_id?: string | null;
          p_participates_in_settlement: boolean;
          p_customer_charge: string | number;
          p_direct_cost?: string | number | null;
          p_notes?: string | null;
          p_closed_day_reason?: string | null;
          p_payment_reference?: string | null;
        };
        Returns: { id: string; adjustment_number: string }[];
      };
      // §16, v2 (migration 0147, Patch 6.1 item 1B/11) — PENDING-only edit,
      // row_version optimistic concurrency. sales_order_id is immutable
      // (not accepted). p_direct_cost is INTENTIONALLY ABSENT — dropped
      // entirely; use set_pending_sales_order_adjustment_direct_cost()
      // below instead (item 2). p_payment_reference is a NEW optional
      // trailing parameter.
      update_sales_order_adjustment: {
        Args: {
          p_id: string;
          p_expected_version: number;
          p_adjustment_type_id: string;
          p_processing_store_id: string;
          p_adjustment_date: string;
          p_payment_method_id?: string | null;
          p_collection_channel_id?: string | null;
          p_participates_in_settlement: boolean;
          p_customer_charge: string | number;
          p_notes?: string | null;
          p_closed_day_reason?: string | null;
          p_payment_reference?: string | null;
        };
        Returns: { id: string; row_version: number }[];
      };
      // Patch 6.1 item 2 (migration 0145) — the SINGLE sanctioned path for
      // setting/correcting a PENDING record's direct_cost. Requires
      // adjustments.manage_cost ALONE (independent of adjustments.create/
      // approve).
      set_pending_sales_order_adjustment_direct_cost: {
        Args: { p_id: string; p_expected_version: number; p_direct_cost: string | number; p_closed_day_reason?: string | null };
        Returns: { id: string; row_version: number; direct_cost: string; has_direct_cost: boolean }[];
      };
      // §17, v2 (migration 0148, Patch 6.1 items 5/6/8/9/14) — full
      // approval procedure. Requires adjustments.approve ALONE (manage_cost
      // is independent). direct_cost IS NULL still hard-rejects, even for a
      // free service. net_adjustment_profit in the response is null
      // without sales.view_profit — a NEW `status` column is also returned.
      approve_sales_order_adjustment: {
        Args: { p_id: string; p_expected_version: number; p_closed_day_reason?: string | null };
        Returns: { id: string; adjustment_number: string; row_version: number; status: string; net_adjustment_profit: string | null }[];
      };
      // §18, v2 (migration 0149, item 13) — mandatory reason, PENDING-only,
      // terminal. Now ALSO requires the linked Sale's own store to be
      // visible (dual-store scope fix), not just the processing store.
      reject_sales_order_adjustment: {
        Args: { p_id: string; p_expected_version: number; p_reason: string };
        Returns: { id: string; row_version: number }[];
      };
      // §19/§20/§21, v2 (migration 0150, item 20) — append-only
      // administrative reversal, APPROVED-only, at most one effective
      // reversal ever. Signature unchanged; the reversal row now ALSO
      // carries 5 explicit signed impact columns (not exposed via this
      // RPC's own return — see get_sales_order_adjustment() below).
      reverse_sales_order_adjustment: {
        Args: { p_id: string; p_expected_version: number; p_reversal_business_date: string; p_reason: string; p_closed_day_reason?: string | null };
        Returns: { id: string; reversal_id: string }[];
      };
      // §38/§39/§29, v2 (migration 0151, Patch 6.1 items 3/11/12/19), v3
      // (migration 0160, Hotfix 6.1.1 items 6/7) — single-record read.
      // Requires BOTH the linked Sale's own store AND the processing store
      // to be visible (closes the cross-store leak). direct_cost/payment_
      // fee_amount/gross_adjustment_profit/net_adjustment_profit no longer
      // exist as flat fields — replaced by the original_* (immutable
      // approved snapshot; original_direct_cost ALONE is also visible
      // while pending to an adjustments.manage_cost holder without sales.
      // view_profit, item 3) / effective_* (0.00 once reversed, null while
      // pending/rejected, item 19) split. payment_method_id/collection_
      // channel_id/payment_reference can now be null (a genuinely free
      // service). has_direct_cost is a NEW, always-visible-to-adjustments.
      // view operational boolean that never discloses the amount.
      // calculation_version (Hotfix 6.1.1 item 7) is plain operational
      // metadata, adjustments.view alone (NOT sales.view_profit-gated) —
      // NULL while pending/rejected. reversal_*_impact (Hotfix 6.1.1 item
      // 6) are the 5 signed reversal-impact figures (0150), sales.
      // view_profit-gated, NULL when there is no reversal.
      get_sales_order_adjustment: {
        Args: { p_id: string };
        Returns: {
          id: string;
          adjustment_number: string;
          sales_order_id: string;
          order_number: string;
          original_sale_store_id: string;
          original_sale_store_name: string;
          adjustment_type_id: string;
          adjustment_type_code: string;
          adjustment_type_name_ar: string;
          processing_store_id: string;
          processing_store_name: string;
          adjustment_date: string;
          payment_method_id: string | null;
          payment_method_name: string | null;
          collection_channel_id: string | null;
          collection_channel_name: string | null;
          payment_reference: string | null;
          participates_in_settlement: boolean;
          customer_charge: string;
          has_direct_cost: boolean;
          calculation_version: number | null;
          original_direct_cost: string | null;
          original_payment_fee_amount: string | null;
          original_gross_adjustment_profit: string | null;
          original_net_adjustment_profit: string | null;
          effective_customer_charge: string | null;
          effective_direct_cost: string | null;
          effective_payment_fee_amount: string | null;
          effective_gross_adjustment_profit: string | null;
          effective_net_adjustment_profit: string | null;
          reversal_customer_charge_impact: string | null;
          reversal_direct_cost_impact: string | null;
          reversal_payment_fee_impact: string | null;
          reversal_gross_profit_impact: string | null;
          reversal_net_profit_impact: string | null;
          status: string;
          effective_status: string;
          rejection_reason: string | null;
          notes: string | null;
          row_version: number;
          reversal_business_date: string | null;
          reversal_reason: string | null;
          created_at: string;
          approved_at: string | null;
          rejected_at: string | null;
        }[];
      };
      // Patch 6.1 item 23 (migration 0152) — narrow Pending-edit getter,
      // gated on adjustments.create ALONE (never adjustments.view). Closes
      // the hidden-permission-dependency bug the /adjustments/[id]/edit
      // page (and the post-create redirect target) previously had.
      get_pending_sales_order_adjustment_for_edit: {
        Args: { p_id: string };
        Returns: {
          id: string;
          row_version: number;
          sales_order_id: string;
          order_number: string;
          adjustment_type_id: string;
          processing_store_id: string;
          adjustment_date: string;
          payment_method_id: string | null;
          collection_channel_id: string | null;
          payment_reference: string | null;
          participates_in_settlement: boolean;
          customer_charge: string;
          has_direct_cost: boolean;
          direct_cost: string | null;
          notes: string | null;
          status: string;
        }[];
      };
      // §38, v2 (migration 0151, Patch 6.1 items 12/19/21), v3 (migration
      // 0157, Hotfix 6.1.1 item 5) — filterable list, scoped to BOTH the
      // linked Sale's store AND the processing store being visible to the
      // actor. p_status accepts pending/approved/rejected/reversed
      // (reversed is derived, not a base status value). Filters:
      // p_original_sale_store_id/p_payment_method_id/p_collection_
      // channel_id/p_participates_in_settlement. effective_direct_cost/
      // effective_payment_fee_amount/effective_gross_adjustment_profit
      // (Hotfix 6.1.1 item 5) mirror get_sales_order_adjustment()'s
      // effective_* semantics exactly (approved-not-reversed=original;
      // reversed=0.00; pending/rejected=NULL) and are ALL null without
      // sales.view_profit, same as effective_net_adjustment_profit.
      list_sales_order_adjustments: {
        Args: {
          p_sales_order_id?: string | null;
          p_store_id?: string | null;
          p_status?: string | null;
          p_adjustment_type_id?: string | null;
          p_date_from?: string | null;
          p_date_to?: string | null;
          p_search?: string | null;
          p_limit?: number;
          p_offset?: number;
          p_original_sale_store_id?: string | null;
          p_payment_method_id?: string | null;
          p_collection_channel_id?: string | null;
          p_participates_in_settlement?: boolean | null;
        };
        Returns: {
          id: string;
          adjustment_number: string;
          sales_order_id: string;
          order_number: string;
          original_sale_store_id: string;
          original_sale_store_name: string;
          adjustment_type_id: string;
          adjustment_type_name_ar: string;
          processing_store_id: string;
          processing_store_name: string;
          adjustment_date: string;
          payment_method_id: string | null;
          payment_method_name: string | null;
          collection_channel_id: string | null;
          collection_channel_name: string | null;
          payment_reference: string | null;
          customer_charge: string;
          effective_direct_cost: string | null;
          effective_payment_fee_amount: string | null;
          effective_gross_adjustment_profit: string | null;
          effective_net_adjustment_profit: string | null;
          status: string;
          effective_status: string;
          participates_in_settlement: boolean;
          total_count: number;
        }[];
      };
      // §2/§40 — Original Invoice Amount + Effective Approved (non-reversed)
      // Adjustments Charges = Total Including Adjustments. Gated on
      // adjustments.view OR sales.view (embedded on /sales/[id], §41).
      get_sales_order_adjustment_summary: {
        Args: { p_order_id: string };
        Returns: { original_invoice_amount: string; approved_effective_adjustments_charge_total: string; total_including_adjustments: string }[];
      };

      // ---------------------------------------------------------------------
      // Phase 7 — Settlements Core (migrations 0167-0183). settlement_routes/
      // settlement_route_fee_versions/settlement_batches/settlement_batch_
      // lines/settlement_bank_movement_events/_reversals/settlement_source_
      // claims/settlement_batch_cancellations carry zero direct-write (most
      // also zero SELECT) RLS policies — every read/write goes through these
      // SECURITY DEFINER RPCs. See supabase/migrations/0169/0171/0176/0177/
      // 0178/0179/0180/0181/0182 for the authoritative source.
      // ---------------------------------------------------------------------
      settlement_route_lookups: {
        Args: Record<string, never>;
        Returns: { id: string; code: string; name_ar: string; route_kind: string; payment_method_id: string | null; collection_channel_id: string | null; shipping_carrier_id: string | null }[];
      };
      settlement_route_filter_lookups: {
        Args: Record<string, never>;
        Returns: { id: string; code: string; name_ar: string; route_kind: string; status: string }[];
      };
      settlement_routes_admin_list: {
        Args: Record<string, never>;
        Returns: {
          id: string;
          code: string;
          name_ar: string;
          name_en: string | null;
          route_kind: string;
          payment_method_id: string | null;
          payment_method_name: string | null;
          collection_channel_id: string | null;
          collection_channel_name: string | null;
          shipping_carrier_id: string | null;
          shipping_carrier_name: string | null;
          status: string;
          description: string | null;
          created_at: string;
          updated_at: string;
        }[];
      };
      settlement_store_filter_lookups: {
        Args: Record<string, never>;
        Returns: { id: string; code: string; name_ar: string }[];
      };
      // Patch 7.1 §24 (migration 0186) — create-gated store lookup for the
      // draft/source-discovery workflow, mirroring settlement_store_filter_
      // lookups() above but gated on settlements.create alone.
      settlement_create_store_lookups: {
        Args: Record<string, never>;
        Returns: { id: string; code: string; name_ar: string }[];
      };
      // Patch 7.1 §7 (migration 0186) — narrow draft-only getter, requires
      // settlements.create; an actor without settlements.view may reach
      // ONLY a draft they themselves created.
      get_draft_settlement_batch_for_edit: {
        Args: { p_id: string };
        Returns: {
          id: string;
          settlement_number: string;
          settlement_route_id: string;
          route_code: string;
          route_name_ar: string;
          route_kind: string;
          settlement_date: string;
          status: string;
          provider_statement_reference: string | null;
          notes: string | null;
          row_version: number;
          created_by: string;
          created_at: string;
        }[];
      };
      create_settlement_route: {
        Args: {
          p_code: string;
          p_name_ar: string;
          p_route_kind: string;
          p_name_en?: string | null;
          p_payment_method_id?: string | null;
          p_collection_channel_id?: string | null;
          p_shipping_carrier_id?: string | null;
          p_description?: string | null;
        };
        Returns: string;
      };
      update_settlement_route: {
        Args: { p_id: string; p_name_ar: string; p_name_en?: string | null; p_description?: string | null };
        Returns: undefined;
      };
      disable_settlement_route: { Args: { p_id: string }; Returns: undefined };
      enable_settlement_route: { Args: { p_id: string }; Returns: undefined };
      create_settlement_route_fee_version: {
        Args: {
          p_settlement_route_id: string;
          p_effective_from: string;
          p_transaction_fee_strategy: string;
          p_transaction_fee_model?: string | null;
          p_percentage_fee?: string | null;
          p_fixed_fee?: string | null;
          p_batch_fee_fixed?: string | null;
          p_cod_fee_reversal_policy?: string | null;
          p_notes?: string | null;
        };
        Returns: string;
      };
      cancel_settlement_route_fee_version: { Args: { p_version_id: string }; Returns: undefined };
      // Patch 7.1 §23 (migration 0190) — narrow lookups for the Settlement
      // Route creation/edit form, gated ONLY on settlements.manage_routes
      // (never payment_methods.view/collection_channels.view/shipping_
      // rates.view — the hidden dependency §23 fixes).
      settlement_route_payment_method_lookups: {
        Args: Record<string, never>;
        Returns: { id: string; key: string; name_ar: string }[];
      };
      settlement_route_collection_channel_lookups: {
        Args: Record<string, never>;
        Returns: { id: string; key: string; name_ar: string }[];
      };
      settlement_route_carrier_lookups: {
        Args: Record<string, never>;
        Returns: { id: string; code: string; name_ar: string }[];
      };
      // Patch 7.1 §23 (migration 0190) — fee-version history for the
      // route-management screen, gated ONLY on settlements.manage_routes
      // (never settlements.view_financials). Money figures arrive as text.
      list_settlement_route_fee_versions_for_management: {
        Args: { p_settlement_route_id: string };
        Returns: {
          id: string;
          effective_from: string;
          effective_to: string | null;
          transaction_fee_strategy: string;
          transaction_fee_model: string | null;
          percentage_fee: string | null;
          fixed_fee: string | null;
          batch_fee_fixed: string;
          cod_fee_reversal_policy: string | null;
          status: string;
          notes: string | null;
          created_by_name: string | null;
          created_at: string;
        }[];
      };
      settlement_route_fee_for_route_on_date: {
        Args: { p_settlement_route_id: string; p_date?: string };
        Returns: {
          fee_version_id: string;
          transaction_fee_strategy: string;
          transaction_fee_model: string | null;
          percentage_fee: number | null;
          fixed_fee: number | null;
          batch_fee_fixed: number;
          cod_fee_reversal_policy: string | null;
        }[];
      };
      list_unsettled_settlement_sources: {
        Args: {
          p_settlement_route_id: string;
          p_source_date_from: string;
          p_source_date_to: string;
          p_store_id?: string | null;
          p_search?: string | null;
          p_limit?: number;
          p_offset?: number;
        };
        Returns: {
          source_kind: string;
          source_event_id: string;
          source_number: string;
          source_business_date: string;
          store_display: string;
          source_label: string;
          gross_collection_impact: string;
          provider_fee_impact: string;
          expected_settlement_impact: string;
        }[];
      };
      // Hotfix 7.1.1 §9 (migration 0195) — DROP+CREATE over the Patch 7.1
      // 5-arg version: two new trailing params (p_batch_fee_override/
      // p_override_reason, same validation contract finalize_settlement_
      // batch() already enforces) so Preview/Finalize stay in parity for
      // the batch-fee override. Output gains configured_batch_fee/
      // effective_batch_fee/batch_fee_overridden, replacing the old
      // ambiguous single `batch_fee` column.
      preview_settlement_batch: {
        Args: {
          p_settlement_route_id: string;
          p_source_date_from: string;
          p_source_date_to: string;
          p_selected_sources: Json;
          p_settlement_date?: string | null;
          p_batch_fee_override?: string | null;
          p_override_reason?: string | null;
        };
        Returns: {
          lines: Json;
          gross_source_impact: string;
          provider_fee_impact: string;
          expected_before_batch_fee: string;
          configured_batch_fee: string;
          effective_batch_fee: string;
          batch_fee_overridden: boolean;
          expected_bank_settlement: string;
          fee_version_resolved: boolean;
          transaction_fee_strategy: string | null;
        }[];
      };
      // Hotfix 7.1.1 §12 (migration 0196) — settlements.view-gated filter
      // lookups for the /settlements list page (never payment_methods.view/
      // collection_channels.view/shipping_rates.view). Include disabled/
      // historical rows.
      settlement_filter_payment_method_lookups: {
        Args: Record<string, never>;
        Returns: { id: string; key: string; name_ar: string; status: string }[];
      };
      settlement_filter_collection_channel_lookups: {
        Args: Record<string, never>;
        Returns: { id: string; key: string; name_ar: string; status: string }[];
      };
      settlement_filter_carrier_lookups: {
        Args: Record<string, never>;
        Returns: { id: string; code: string; name_ar: string; status: string }[];
      };
      create_draft_settlement_batch: {
        Args: { p_settlement_route_id: string; p_settlement_date: string; p_provider_statement_reference?: string | null; p_notes?: string | null };
        Returns: { id: string; settlement_number: string }[];
      };
      // Patch 7.1 §10/§27 (migration 0189) — gains two trailing "_provided"
      // boolean flags: the ONLY signal that provider_statement_reference/
      // notes are being touched at all (an unset flag ALWAYS keeps the
      // existing value; a set flag applies the paired p_X verbatim,
      // including clearing it to NULL).
      update_draft_settlement_batch: {
        Args: {
          p_id: string;
          p_expected_version: number;
          p_settlement_route_id?: string | null;
          p_settlement_date?: string | null;
          p_provider_statement_reference?: string | null;
          p_notes?: string | null;
          p_provider_statement_reference_provided?: boolean;
          p_notes_provided?: boolean;
        };
        Returns: { id: string; row_version: number }[];
      };
      finalize_settlement_batch: {
        Args: {
          p_settlement_batch_id: string;
          p_expected_version: number;
          p_selected_sources: Json;
          p_batch_fee_override?: string | null;
          p_override_reason?: string | null;
          p_closed_day_reason?: string | null;
        };
        Returns: { id: string; settlement_number: string; row_version: number }[];
      };
      // Patch 7.1 §12/§13 (migration 0188) — gains trailing p_closed_day_
      // reason. §13: only recordable while the batch is 'finalized' (a
      // 'reconciled' batch no longer accepts new movements).
      record_settlement_bank_movement: {
        Args: { p_settlement_batch_id: string; p_movement_business_date: string; p_amount: string; p_bank_reference?: string | null; p_notes?: string | null; p_closed_day_reason?: string | null };
        Returns: string;
      };
      // Patch 7.1 §12 (migration 0188) — gains trailing p_closed_day_reason.
      // Still allowed regardless of finalized/reconciled status.
      reverse_settlement_bank_movement: {
        Args: { p_bank_movement_event_id: string; p_reversal_business_date: string; p_reason: string; p_closed_day_reason?: string | null };
        Returns: string;
      };
      reconcile_settlement_batch: {
        Args: { p_settlement_batch_id: string; p_expected_version: number; p_variance_reason?: string | null };
        Returns: { id: string; row_version: number; actual_bank_movement: string; variance: string }[];
      };
      // Patch 7.1 §12 (migration 0188) — gains trailing p_closed_day_reason.
      cancel_settlement_batch: {
        Args: { p_settlement_batch_id: string; p_expected_version: number; p_cancellation_business_date: string; p_reason: string; p_closed_day_reason?: string | null };
        Returns: string;
      };
      // Patch 7.1 §25/§26 (migration 0191) — complete filter set (route
      // kind/payment method/channel/carrier/effective status incl.
      // 'cancelled'/store/has_variance) + server-side source_count. The old
      // flat gross_source_impact/provider_fee_impact/batch_fee_snapshot/
      // expected_bank_settlement/actual_bank_movement/variance columns
      // (0182/0186, ambiguous for a cancelled batch) are replaced by
      // explicitly-named original_* (permanent historical fact, never
      // zeroed by cancellation) / effective_* (current contribution, 0.00
      // once cancelled) columns. p_status (base status values) is still
      // accepted for backward compatibility but this codebase now filters
      // exclusively via p_effective_status, which is a strict superset.
      list_settlement_batches: {
        Args: {
          p_status?: string[] | null;
          p_settlement_route_id?: string | null;
          p_date_from?: string | null;
          p_date_to?: string | null;
          p_search?: string | null;
          p_route_kind?: string | null;
          p_payment_method_id?: string | null;
          p_collection_channel_id?: string | null;
          p_shipping_carrier_id?: string | null;
          p_effective_status?: string[] | null;
          p_store_id?: string | null;
          p_has_variance?: boolean | null;
          p_limit?: number;
          p_offset?: number;
        };
        Returns: {
          id: string;
          settlement_number: string;
          settlement_route_id: string;
          route_code: string;
          route_name_ar: string;
          route_kind: string;
          settlement_date: string;
          status: string;
          effective_status: string;
          provider_statement_reference: string | null;
          source_count: number;
          original_gross_source_impact: string | null;
          original_provider_fee_impact: string | null;
          original_batch_fee: string | null;
          original_expected_bank_settlement: string | null;
          effective_expected_settlement_contribution: string | null;
          effective_actual_settlement_contribution: string | null;
          effective_variance_contribution: string | null;
          row_version: number;
          created_at: string;
          finalized_at: string | null;
          reconciled_at: string | null;
        }[];
      };
      // Patch 7.1 §6/§26 (migrations 0186/0191) — whole-batch all-or-nothing
      // store privacy (fails closed with the same not-found error a missing
      // id would raise) + original_*/historical_*/effective_* column split
      // (see list_settlement_batches() comment above for the rationale).
      get_settlement_batch: {
        Args: { p_settlement_batch_id: string };
        Returns: {
          id: string;
          settlement_number: string;
          settlement_route_id: string;
          route_code: string;
          route_name_ar: string;
          route_name_en: string | null;
          route_kind: string;
          settlement_date: string;
          status: string;
          effective_status: string;
          provider_statement_reference: string | null;
          notes: string | null;
          payment_method_name: string | null;
          collection_channel_name: string | null;
          shipping_carrier_name: string | null;
          transaction_fee_strategy: string | null;
          transaction_percentage_fee: string | null;
          transaction_fixed_fee: string | null;
          original_batch_fee: string | null;
          is_batch_fee_override: boolean;
          configured_batch_fee: string | null;
          override_reason: string | null;
          original_gross_source_impact: string | null;
          original_provider_fee_impact: string | null;
          original_expected_before_batch_fee: string | null;
          original_expected_bank_settlement: string | null;
          historical_actual_bank_movement: string | null;
          original_variance: string | null;
          effective_expected_settlement_contribution: string | null;
          effective_actual_settlement_contribution: string | null;
          effective_variance_contribution: string | null;
          settlement_calculation_version: number | null;
          row_version: number;
          finalized_at: string | null;
          finalized_by_name: string | null;
          reconciled_at: string | null;
          reconciled_by_name: string | null;
          variance_reason: string | null;
          cancelled_at: string | null;
          cancelled_by_name: string | null;
          cancellation_reason: string | null;
          lines: Json;
          bank_movements: Json;
          created_at: string;
          updated_at: string;
        }[];
      };

      // ---------------------------------------------------------------
      // Phase 8 — Reports, Dashboard & Exports (migrations 0199-0204).
      // Every get_*_report()/get_dashboard_*()/get_*_management_report()
      // RPC returns a single jsonb payload (never a table/set) -- typed
      // loosely as `Json` here and narrowed on the call site, matching
      // get_sales_order()/get_settlement_batch()-adjacent jsonb-getter
      // convention above. Every report_*_lookup() RPC returns a real
      // TABLE(...) (a filter-dropdown row set), typed precisely.
      // ---------------------------------------------------------------
      get_dashboard_summary: {
        Args: { p_date_from: string; p_date_to: string; p_store_ids?: string[] | null };
        Returns: Json;
      };
      get_dashboard_trends: {
        Args: { p_date_from: string; p_date_to: string; p_store_ids?: string[] | null; p_granularity?: string | null };
        Returns: Json;
      };
      // Hotfix 8.1.2 §1-5: calendar-aware comparison wrapper (0221) -- calls
      // get_dashboard_summary() twice (current + calendar-correct previous
      // range) and returns the same jsonb shape plus date_from/date_to/
      // period_preset/previous_date_from/previous_date_to/comparison_mode.
      get_dashboard_summary_with_comparison: {
        Args: {
          p_date_from: string;
          p_date_to: string;
          p_period_preset?: string | null;
          p_store_ids?: string[] | null;
        };
        Returns: Json;
      };
      get_sales_report: {
        Args: {
          p_date_from: string;
          p_date_to: string;
          p_store_ids?: string[] | null;
          p_employee_id?: string | null;
          p_category_id?: string | null;
          p_karat_id?: string | null;
          p_payment_method_id?: string | null;
          p_collection_channel_id?: string | null;
          p_search?: string | null;
          p_sort?: string | null;
          p_limit?: number | null;
          p_offset?: number | null;
        };
        Returns: Json;
      };
      get_items_report: {
        // Hotfix 8.1.2 §34-36 (0226): p_salesperson_id added.
        Args: {
          p_date_from: string;
          p_date_to: string;
          p_store_ids?: string[] | null;
          p_category_id?: string | null;
          p_karat_id?: string | null;
          p_search?: string | null;
          p_sort?: string | null;
          p_limit?: number | null;
          p_offset?: number | null;
          p_salesperson_id?: string | null;
        };
        Returns: Json;
      };
      get_categories_report: {
        Args: {
          p_date_from: string;
          p_date_to: string;
          p_store_ids?: string[] | null;
          p_karat_id?: string | null;
          p_search?: string | null;
          p_sort?: string | null;
          p_limit?: number | null;
          p_offset?: number | null;
          p_parent_id?: string | null;
        };
        Returns: Json;
      };
      get_karats_report: {
        Args: {
          p_date_from: string;
          p_date_to: string;
          p_store_ids?: string[] | null;
          p_category_id?: string | null;
          p_search?: string | null;
          p_sort?: string | null;
          p_limit?: number | null;
          p_offset?: number | null;
        };
        Returns: Json;
      };
      get_employees_report: {
        Args: {
          p_date_from: string;
          p_date_to: string;
          p_store_ids?: string[] | null;
          p_search?: string | null;
          p_sort?: string | null;
          p_limit?: number | null;
          p_offset?: number | null;
        };
        Returns: Json;
      };
      get_payment_methods_report: {
        // Hotfix 8.1.2 §23: was drifted from the real DB signature (0207) --
        // p_refund_method_id/p_collection_channel_id existed on the RPC
        // since 0207 but were never declared here. §31-33 (0225): adds
        // p_payment_method_id (Sales section, distinct from
        // p_refund_method_id which stays Refund-Cash-only).
        Args: {
          p_date_from: string;
          p_date_to: string;
          p_store_ids?: string[] | null;
          p_search?: string | null;
          p_sort?: string | null;
          p_limit?: number | null;
          p_offset?: number | null;
          p_refund_method_id?: string | null;
          p_collection_channel_id?: string | null;
          p_payment_method_id?: string | null;
        };
        Returns: Json;
      };
      get_collection_channels_report: {
        Args: {
          p_date_from: string;
          p_date_to: string;
          p_store_ids?: string[] | null;
          p_search?: string | null;
          p_sort?: string | null;
          p_limit?: number | null;
          p_offset?: number | null;
        };
        Returns: Json;
      };
      get_returns_report: {
        Args: {
          p_date_from: string;
          p_date_to: string;
          p_store_ids?: string[] | null;
          p_scenario?: string | null;
          p_status?: string | null;
          p_payment_method_id?: string | null;
          p_collection_channel_id?: string | null;
          p_search?: string | null;
          p_sort?: string | null;
          p_limit?: number | null;
          p_offset?: number | null;
          p_basis?: string | null;
          p_refund_method_id?: string | null;
          p_salesperson_id?: string | null;
          p_original_sale_date_from?: string | null;
          p_original_sale_date_to?: string | null;
          p_refund_reconciliation_state?: string | null;
        };
        Returns: Json;
      };
      get_shipping_report: {
        Args: {
          p_date_from: string;
          p_date_to: string;
          p_store_ids?: string[] | null;
          p_carrier_id?: string | null;
          p_shipping_zone_id?: string | null;
          p_direction?: string | null;
          p_current_status?: string | null;
          p_is_cod?: boolean | null;
          p_search?: string | null;
          p_sort?: string | null;
          p_limit?: number | null;
          p_offset?: number | null;
          p_basis?: string | null;
        };
        Returns: Json;
      };
      get_cod_report: {
        Args: {
          p_date_from: string;
          p_date_to: string;
          p_store_ids?: string[] | null;
          p_cod_collection_state?: string | null;
          p_search?: string | null;
          p_sort?: string | null;
          p_limit?: number | null;
          p_offset?: number | null;
          p_basis?: string | null;
        };
        Returns: Json;
      };
      get_adjustments_report: {
        Args: {
          p_date_from: string;
          p_date_to: string;
          p_store_ids?: string[] | null;
          p_adjustment_type_id?: string | null;
          p_search?: string | null;
          p_sort?: string | null;
          p_limit?: number | null;
          p_offset?: number | null;
        };
        Returns: Json;
      };
      get_settlements_report: {
        Args: {
          p_date_from: string;
          p_date_to: string;
          p_store_ids?: string[] | null;
          p_settlement_route_id?: string | null;
          p_status?: string | null;
          p_search?: string | null;
          p_sort?: string | null;
          p_limit?: number | null;
          p_offset?: number | null;
          p_route_kind?: string | null;
          p_payment_method_id?: string | null;
          p_collection_channel_id?: string | null;
          p_shipping_carrier_id?: string | null;
          p_effective_status?: string | null;
          p_has_variance?: boolean | null;
          p_provider_statement_reference?: string | null;
        };
        Returns: Json;
      };
      get_daily_management_report: {
        Args: { p_date?: string | null; p_store_ids?: string[] | null };
        Returns: Json;
      };
      get_weekly_management_report: {
        Args: { p_reference_date?: string | null; p_store_ids?: string[] | null };
        Returns: Json;
      };
      get_monthly_management_report: {
        Args: { p_year?: number | null; p_month?: number | null; p_store_ids?: string[] | null };
        Returns: Json;
      };
      get_yearly_management_report: {
        Args: { p_year?: number | null; p_store_ids?: string[] | null };
        Returns: Json;
      };
      report_visible_stores_lookup: {
        Args: Record<string, never>;
        Returns: { id: string; code: string; name_ar: string; status: string }[];
      };
      report_categories_lookup: {
        Args: Record<string, never>;
        Returns: { id: string; code: string | null; name_ar: string; parent_id: string | null; status: string }[];
      };
      report_karats_lookup: {
        Args: Record<string, never>;
        Returns: { id: string; code: string; name_ar: string; status: string }[];
      };
      report_payment_methods_lookup: {
        Args: Record<string, never>;
        Returns: { id: string; key: string; name_ar: string; status: string }[];
      };
      report_collection_channels_lookup: {
        Args: Record<string, never>;
        Returns: { id: string; key: string; name_ar: string; status: string }[];
      };
      report_shipping_carriers_lookup: {
        Args: Record<string, never>;
        Returns: { id: string; code: string; name_ar: string; status: string }[];
      };
      report_shipping_zones_lookup: {
        Args: Record<string, never>;
        Returns: { id: string; code: string; name_ar: string; status: string }[];
      };
      report_adjustment_types_lookup: {
        Args: Record<string, never>;
        Returns: { id: string; code: string | null; name_ar: string; status: string }[];
      };
      report_settlement_routes_lookup: {
        Args: Record<string, never>;
        Returns: { id: string; code: string | null; name_ar: string; route_kind: string; status: string }[];
      };
      report_employees_lookup: {
        Args: Record<string, never>;
        Returns: { id: string; full_name: string; status: string }[];
      };
      // Phase 9 (Inventory Core, migrations 0227-0229).
      create_inventory_item: {
        Args: { p_sku: string; p_name_ar: string; p_category_id: string; p_karat_id?: string | null; p_unit?: string; p_notes?: string | null };
        Returns: { id: string; sku: string; row_version: number }[];
      };
      update_inventory_item: {
        Args: {
          p_id: string;
          p_expected_version: number;
          p_name_ar: string;
          p_category_id: string;
          p_karat_id?: string | null;
          p_unit?: string;
          p_active?: boolean;
          p_notes?: string | null;
        };
        Returns: { id: string; row_version: number }[];
      };
      receive_inventory_stock: {
        Args: { p_item_id: string; p_store_id: string; p_quantity: string | number; p_business_date?: string; p_reference?: string | null; p_notes?: string | null };
        Returns: { id: string; resulting_balance: string }[];
      };
      adjust_inventory_stock: {
        Args: { p_item_id: string; p_store_id: string; p_quantity_delta: string | number; p_reason: string; p_business_date?: string; p_reference?: string | null };
        Returns: { id: string; resulting_balance: string }[];
      };
      list_inventory_items: {
        Args: { p_search?: string | null; p_category_id?: string | null; p_karat_id?: string | null; p_active?: boolean | null; p_limit?: number; p_offset?: number };
        Returns: {
          id: string;
          sku: string;
          name_ar: string;
          category_id: string;
          category_name_ar: string | null;
          karat_id: string | null;
          karat_name_ar: string | null;
          unit: string;
          active: boolean;
          notes: string | null;
          row_version: number;
          created_at: string;
          total_count: number;
        }[];
      };
      list_inventory_stock_balances: {
        Args: { p_store_id?: string | null; p_item_id?: string | null; p_search?: string | null; p_limit?: number; p_offset?: number };
        Returns: { item_id: string; sku: string; name_ar: string; unit: string; store_id: string; store_name_ar: string; balance: string; total_count: number }[];
      };
      list_inventory_stock_movements: {
        Args: { p_item_id?: string | null; p_store_id?: string | null; p_date_from?: string | null; p_date_to?: string | null; p_limit?: number; p_offset?: number };
        Returns: {
          id: string;
          item_id: string;
          sku: string;
          item_name_ar: string;
          store_id: string;
          store_name_ar: string;
          movement_kind: string;
          quantity_delta: string;
          business_date: string;
          reason: string | null;
          reference: string | null;
          created_at: string;
          created_by_name: string | null;
          total_count: number;
        }[];
      };
      inventory_operable_store_lookups: { Args: Record<string, never>; Returns: { id: string; name_ar: string }[] };
      inventory_visible_store_lookups: { Args: Record<string, never>; Returns: { id: string; name_ar: string }[] };
      inventory_active_item_lookups: { Args: Record<string, never>; Returns: { id: string; sku: string; name_ar: string }[] };
      inventory_category_lookups: { Args: Record<string, never>; Returns: { id: string; name_ar: string }[] };
      inventory_karat_lookups: { Args: Record<string, never>; Returns: { id: string; name_ar: string }[] };
    };
    Enums: Record<string, never>;
  };
}
