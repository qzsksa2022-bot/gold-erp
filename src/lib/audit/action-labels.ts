/**
 * Human-readable Arabic labels for audit `action` strings.
 *
 * As of supabase/migrations/0016, sensitive-table mutations are logged
 * automatically by database triggers (audit_table_changes()), so the action
 * taxonomy is mechanical: `<entity_type>.<create|update|delete>`, where
 * entity_type is chosen per-table specifically to avoid two structurally
 * different events colliding under the same label (e.g. assigning a role to
 * a user logs as `user_role.create`, NOT `user.create`, which is reserved
 * for an actual new account). The only hand-written events left are the
 * three auth-lifecycle ones, which have no backing table row.
 *
 * The audit log page falls back to the raw action string if a label is
 * missing here, so nothing breaks — it just looks less polished.
 */
export const AUDIT_ACTION_LABELS_AR: Record<string, string> = {
  "auth.login_success": "تسجيل دخول ناجح",
  "auth.login_failed": "محاولة تسجيل دخول فاشلة",
  "auth.logout": "تسجيل خروج",

  "user.create": "إنشاء مستخدم",
  "user.update": "تعديل بيانات مستخدم / تغيير حالته",
  // Patch 1.4.1, item 3: cancelUserInviteAction (supabase/migrations/0036)
  // deletes the underlying auth user for an unprovisioned invite, which
  // profiles_audit_trigger (0016) logs automatically as `user.delete` —
  // this label makes that mechanical row-deletion record readable too,
  // distinct from the actor-attributed `user.invite_cancel` event below
  // (supabase/migrations/0038) that records WHO made the decision.
  "user.delete": "حذف حساب مستخدم",
  "user.invite_cancel": "إلغاء دعوة مستخدم غير مكتمل",

  "store.create": "إنشاء متجر",
  "store.update": "تعديل بيانات متجر / تغيير حالته",

  "role.create": "إنشاء دور",
  "role.update": "تعديل دور",
  "role.delete": "حذف دور",

  "role_permission.create": "إضافة صلاحية لدور",
  "role_permission.delete": "إزالة صلاحية من دور",

  "user_role.create": "إسناد دور لمستخدم",
  "user_role.delete": "إلغاء إسناد دور",

  "permission_override.create": "إضافة استثناء صلاحية فردية",
  "permission_override.update": "تعديل استثناء صلاحية فردية",
  "permission_override.delete": "إزالة استثناء صلاحية فردية",

  "user_store_access.create": "منح وصول لمتجر",
  "user_store_access.delete": "إلغاء وصول لمتجر",

  "system_setting.create": "إضافة إعداد نظام",
  "system_setting.update": "تحديث إعدادات النظام",

  // Phase 2 — Financial Master Data (supabase/migrations/0040-0046). Same
  // mechanical `<entity_type>.<create|update>` taxonomy as above — no new
  // table here allows app-level DELETE (master data is disabled, never hard
  // deleted), so only create/update ever fire. Status toggles (e.g.
  // "تعطيل عيار") are themselves UPDATEs on the same row, so — matching the
  // existing store.update precedent above — the update label folds both
  // "edited a field" and "changed status" into one readable phrase rather
  // than inventing a separate action string the trigger can't distinguish.
  "karat.create": "إنشاء عيار",
  "karat.update": "تعديل عيار / تغيير حالته",

  "gold_price.create": "تسجيل سعر ذهب",
  "gold_price.update": "تعديل سعر ذهب",

  "manufacturing_fee_version.create": "إنشاء نسخة مصنعية",
  "manufacturing_fee_version.update": "تعديل نسخة مصنعية (بما في ذلك إلغاء نسخة مستقبلية)",

  "product_category.create": "إنشاء تصنيف",
  "product_category.update": "تعديل تصنيف / تغيير حالته",

  "payment_method.create": "إنشاء طريقة دفع",
  "payment_method.update": "تعديل طريقة دفع / تغيير حالتها",

  "payment_method_fee_version.create": "إنشاء نسخة عمولة",
  "payment_method_fee_version.update": "تعديل نسخة عمولة (بما في ذلك إلغاء نسخة مستقبلية)",

  "collection_channel.create": "إنشاء قناة تحصيل",
  "collection_channel.update": "تعديل قناة تحصيل / تغيير حالتها",

  // Phase 3 — Sales Core (supabase/migrations/0058-0064). Written EXPLICITLY
  // from inside create_sales_order()/update_sales_order()/close_sales_day()
  // (not the generic audit_table_changes() trigger — sales_orders/sales_
  // order_items/daily_closings have zero direct-write RLS policies, so
  // those RPCs are the only write path and this taxonomy is exactly what
  // the spec names, not a mechanical <table>.<insert|update|delete>).
  "vat_rate_version.create": "إنشاء إصدار ضريبة قيمة مضافة",
  "vat_rate_version.update": "تعديل إصدار ضريبة قيمة مضافة (بما في ذلك إلغاء نسخة مستقبلية)",
  "sale.create": "إنشاء عملية بيع",
  "sale.update": "تعديل عملية بيع",
  "sale.closed_day_update": "تعديل/إنشاء عملية بيع بعد إغلاق اليوم",
  "daily_closing.create": "إغلاق يوم مبيعات",

  // Phase 4 — Returns Core (supabase/migrations/0082-0091). Written
  // EXPLICITLY from inside create_sales_return()/update_pending_sales_
  // return()/approve_sales_return()/reject_sales_return()/reverse_sales_
  // return()/record_sales_return_refund()/reverse_sales_return_refund_
  // event() — same reasoning as the Phase 3 Sales taxonomy above: sales_
  // returns/sales_return_items/sales_return_refund_events have zero
  // direct-write RLS policies, so these RPCs are the only write path.
  "return.create": "إنشاء مرتجع",
  "return.update": "تعديل مرتجع (قيد المراجعة)",
  "return.approve": "اعتماد مرتجع",
  "return.reject": "رفض مرتجع",
  "return.reverse": "التراجع عن اعتماد مرتجع",
  "return.refund_recorded": "تسجيل استرداد نقدي",
  "return.refund_reversed": "التراجع عن سجل استرداد نقدي",
  "return.refund_finalized": "تسوية الاسترداد النقدي للمرتجع",
  "return.refund_reconciliation_reopened": "إعادة فتح تسوية الاسترداد النقدي للمرتجع",
  "return.closed_day_override": "معالجة/تعديل/اعتماد مرتجع بعد إغلاق اليوم",
};

export function auditActionLabel(action: string): string {
  return AUDIT_ACTION_LABELS_AR[action] ?? action;
}

export const AUDIT_ENTITY_LABELS_AR: Record<string, string> = {
  user: "مستخدم",
  store: "متجر",
  role: "دور",
  role_permission: "صلاحية دور",
  user_role: "إسناد دور",
  permission_override: "صلاحية فردية",
  user_store_access: "وصول متجر",
  system_setting: "إعداد نظام",
  auth: "تسجيل الدخول",

  // Phase 2 — Financial Master Data
  karat: "عيار",
  gold_price: "سعر ذهب",
  manufacturing_fee_version: "نسخة مصنعية",
  product_category: "تصنيف",
  payment_method: "طريقة دفع",
  payment_method_fee_version: "نسخة عمولة",
  collection_channel: "قناة تحصيل",

  // Phase 4 — Returns Core
  sales_return: "مرتجع",
  sales_return_refund_event: "سجل استرداد نقدي",
};

export function auditEntityLabel(entityType: string): string {
  return AUDIT_ENTITY_LABELS_AR[entityType] ?? entityType;
}
