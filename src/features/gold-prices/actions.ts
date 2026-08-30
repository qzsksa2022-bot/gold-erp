"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { actionError, actionSuccess, dbErrorMessage, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";
import { ROUTES } from "@/lib/constants";
import { isPositiveDecimal } from "@/lib/decimal";

// The whole batch is written in ONE call to save_daily_gold_prices_bulk()
// (supabase/migrations/0050, Financial Integrity Patch 2.1 item 5) — a
// single plpgsql function is one statement, so a bad entry anywhere in the
// batch rolls back every row the call would otherwise have written, instead
// of the previous per-karat loop (which could partially save a day's prices
// if a later karat in the loop failed). created_by/created_at are preserved
// across same-day corrections exactly as before (see that function's
// comment). Audit logging happens automatically via
// daily_gold_prices_audit_trigger regardless of which path wrote the row.

const PRICE_FIELD_PREFIX = "price_karat_";

/**
 * Saves every non-empty `price_karat_<karatId>` field in one request — the
 * fast "أسعار اليوم" entry form (spec §3). Empty fields are skipped
 * entirely (never overwrite an existing price with blank/zero), so a user
 * can fill in just the karats that changed today.
 */
export async function saveTodayGoldPricesAction(
  _prevState: ActionResult<{ savedCount: number }> | null,
  formData: FormData,
): Promise<ActionResult<{ savedCount: number }>> {
  await requirePermission("gold_prices.edit");

  const priceDate = String(formData.get("price_date") ?? "").trim();
  if (!priceDate || Number.isNaN(Date.parse(priceDate))) {
    return actionError("التاريخ غير صالح.");
  }

  const entries: { karatId: string; price: string }[] = [];
  for (const [key, value] of formData.entries()) {
    if (!key.startsWith(PRICE_FIELD_PREFIX)) continue;
    const raw = String(value).trim();
    if (!raw) continue;
    const karatId = key.slice(PRICE_FIELD_PREFIX.length);

    if (!isPositiveDecimal(raw)) {
      return actionError("السعر يجب أن يكون رقمًا موجبًا لكل عيار تم إدخاله.");
    }
    entries.push({ karatId, price: raw });
  }

  if (entries.length === 0) {
    return actionError("أدخل سعرًا واحدًا على الأقل قبل الحفظ.");
  }

  const supabase = await createClient();

  // One atomic call — the RPC validates every entry (karat exists, no
  // duplicate karat in the payload, price > 0) and writes all of them or
  // none of them. source_type/is_manual_override are always forced to
  // manual/true inside the RPC regardless of what is sent here, so there is
  // no client-controlled field that could fabricate source=external_api.
  const { error } = await supabase.rpc("save_daily_gold_prices_bulk", {
    p_price_date: priceDate,
    p_entries: entries.map((entry) => ({ karat_id: entry.karatId, price_per_gram: entry.price })),
  });

  if (error) {
    console.error("[gold-prices] bulk save failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.goldPrices);
  return actionSuccess({ savedCount: entries.length }, `تم حفظ ${entries.length} ${entries.length === 1 ? "سعر" : "أسعار"} بنجاح.`);
}
