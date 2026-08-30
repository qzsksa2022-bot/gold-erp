import type { PaymentFeeModel, RefundFeePolicy } from "@/types/database";

/**
 * Human-readable Arabic labels for the config enums — kept out of business
 * logic (spec §8: "لا تجعل Tabby/Tamara حالة if paymentMethod === 'tabby'
 * داخل الكود"). These are display-only maps, never branching logic.
 */
export const FEE_MODEL_LABELS_AR: Record<PaymentFeeModel, string> = {
  percentage: "نسبة فقط",
  fixed: "مبلغ ثابت فقط",
  percentage_plus_fixed: "نسبة + مبلغ ثابت",
  none: "بدون رسوم",
};

export const REFUND_POLICY_LABELS_AR: Record<RefundFeePolicy, string> = {
  full_reversal: "عكس كامل عند أي استرجاع",
  proportional_reversal: "عكس نسبي حسب المبلغ المسترجَع",
  non_refundable_fee: "العمولة لا تُرد",
  manual: "يُحدَّد يدويًا لكل حالة",
};
