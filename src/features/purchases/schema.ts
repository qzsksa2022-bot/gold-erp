import { z } from "zod";
import { hasMaxDecimalPlaces, isPositiveDecimal } from "@/lib/decimal";

// Phase 11 (Purchases & Suppliers Core) — every monetary input here stays a
// STRING all the way to the RPC call, never parsed through Number()/
// parseFloat() at any point in this file or in actions.ts, exactly mirroring
// src/features/expenses/schema.ts and src/features/inventory/schema.ts.
//
// Amounts are taken EXACTLY as the supplier's own document states them. The
// client never recomputes VAT from a rate, and never rounds: it validates that
// what was entered is internally consistent and sends it verbatim. The server
// (migration 0239) re-validates the same arithmetic exactly before writing
// anything — this file is a courtesy to the operator, not the guarantee.

const optionalText = (max: number) =>
  z
    .string()
    .trim()
    .max(max)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined));

const rowVersionSchema = z.number({ required_error: "إصدار السجل مطلوب" }).int().nonnegative();

/** Strictly positive money with at most 2 decimal places (mirrors the numeric(14,2) money columns in migration 0238). */
const positiveMoneySchema = (label: string) =>
  z
    .string({ required_error: `${label} مطلوب` })
    .trim()
    .refine((v) => isPositiveDecimal(v), `${label} يجب أن يكون رقمًا أكبر من صفر`)
    .refine((v) => hasMaxDecimalPlaces(v, 2), `${label} يجب ألا يتجاوز منزلتين عشريتين`);

/** Zero-or-positive money with at most 2 decimal places — VAT is legitimately 0 on zero-rated/exempt/out-of-scope lines. */
const nonNegativeMoneySchema = (label: string) =>
  z
    .string({ required_error: `${label} مطلوب` })
    .trim()
    .refine((v) => /^\d+(\.\d+)?$/.test(v), `${label} يجب أن يكون رقمًا غير سالب`)
    .refine((v) => hasMaxDecimalPlaces(v, 2), `${label} يجب ألا يتجاوز منزلتين عشريتين`);

export const TAX_TREATMENTS = ["standard", "zero_rated", "exempt", "out_of_scope"] as const;
export type TaxTreatment = (typeof TAX_TREATMENTS)[number];

export const TAX_TREATMENT_LABELS_AR: Record<TaxTreatment, string> = {
  standard: "خاضعة للنسبة الأساسية",
  zero_rated: "خاضعة بنسبة صفر",
  exempt: "معفاة",
  out_of_scope: "خارج نطاق الضريبة",
};

export const PAYMENT_MODES = ["cash", "bank_transfer", "cheque", "other"] as const;
export type PaymentMode = (typeof PAYMENT_MODES)[number];

export const PAYMENT_MODE_LABELS_AR: Record<PaymentMode, string> = {
  cash: "نقدًا",
  bank_transfer: "تحويل بنكي",
  cheque: "شيك",
  other: "أخرى",
};

export const PAYMENT_STATUS_LABELS_AR: Record<string, string> = {
  unpaid: "غير مسددة",
  partial: "مسددة جزئيًا",
  paid: "مسددة بالكامل",
  reversed: "معكوسة",
  reversal: "مستند عكس",
};

// ---------------------------------------------------------------------------
// create_supplier() / update_supplier() (migration 0239) — code is permanent
// once created, only accepted on create, never on update (mirrors
// expense_categories.code and inventory_items.sku).
// ---------------------------------------------------------------------------
const supplierFields = {
  name_ar: z.string({ required_error: "اسم المورّد مطلوب" }).trim().min(1, "اسم المورّد مطلوب").max(200),
  name_en: optionalText(200),
  // The supplier's VAT registration number is stored as SUPPLIED. Phase 11
  // records tax data; it does not adjudicate it, so this is not validated
  // against any registry or checksum.
  vat_number: optionalText(50),
  contact_person: optionalText(200),
  phone: optionalText(50),
  email: optionalText(200),
  notes: optionalText(1000),
};

export const createSupplierSchema = z.object({
  code: z
    .string({ required_error: "رمز المورّد مطلوب" })
    .trim()
    .min(1, "رمز المورّد مطلوب")
    .max(100, "رمز المورّد طويل جدًا"),
  ...supplierFields,
});

export type CreateSupplierInput = z.infer<typeof createSupplierSchema>;

// row_version is REQUIRED: the RPC rejects a NULL expected version outright,
// because `row_version <> NULL` would silently bypass the optimistic-
// concurrency check entirely (the 0232 lesson).
export const updateSupplierSchema = z.object({
  id: z.string().uuid(),
  row_version: rowVersionSchema,
  ...supplierFields,
});

export type UpdateSupplierInput = z.infer<typeof updateSupplierSchema>;

// ---------------------------------------------------------------------------
// post_purchase_invoice() (migration 0239).
// ---------------------------------------------------------------------------
export const purchaseInvoiceLineSchema = z
  .object({
    inventory_item_id: z.string({ required_error: "الصنف مطلوب" }).uuid("صنف غير صالح"),
    quantity: z
      .string({ required_error: "الكمية مطلوبة" })
      .trim()
      .refine((v) => isPositiveDecimal(v), "الكمية يجب أن تكون رقمًا أكبر من صفر")
      .refine((v) => hasMaxDecimalPlaces(v, 3), "الكمية يجب ألا تتجاوز ثلاث منازل عشرية"),
    unit_net_cost: z
      .string({ required_error: "تكلفة الوحدة مطلوبة" })
      .trim()
      .refine((v) => isPositiveDecimal(v), "تكلفة الوحدة يجب أن تكون رقمًا أكبر من صفر")
      .refine((v) => hasMaxDecimalPlaces(v, 4), "تكلفة الوحدة يجب ألا تتجاوز أربع منازل عشرية"),
    tax_treatment: z.enum(TAX_TREATMENTS, { required_error: "المعالجة الضريبية مطلوبة" }),
    tax_rate_percent: z
      .string()
      .trim()
      .refine((v) => /^\d+(\.\d+)?$/.test(v), "النسبة يجب أن تكون رقمًا غير سالب")
      .refine((v) => hasMaxDecimalPlaces(v, 3), "النسبة يجب ألا تتجاوز ثلاث منازل عشرية"),
    net_amount: positiveMoneySchema("صافي البند"),
    vat_amount: nonNegativeMoneySchema("ضريبة البند"),
    gross_amount: positiveMoneySchema("إجمالي البند"),
  })
  .refine((l) => sumMoney(l.net_amount, l.vat_amount) === normalizeMoney(l.gross_amount), {
    message: "إجمالي البند يجب أن يساوي الصافي + الضريبة",
    path: ["gross_amount"],
  })
  .refine((l) => l.tax_treatment === "standard" || (normalizeMoney(l.vat_amount) === "0.00" && isZeroDecimal(l.tax_rate_percent)), {
    // Phase 11 does not DECIDE the tax treatment — it refuses a line that
    // contradicts the treatment the supplier itself declared.
    message: "البند غير الخاضع للنسبة الأساسية لا يجوز أن يحمل ضريبة أو نسبة",
    path: ["vat_amount"],
  });

export type PurchaseInvoiceLineInput = z.infer<typeof purchaseInvoiceLineSchema>;

export const postPurchaseInvoiceSchema = z
  .object({
    supplier_id: z.string({ required_error: "المورّد مطلوب" }).uuid("مورّد غير صالح"),
    store_id: z.string({ required_error: "الفرع مطلوب" }).uuid("فرع غير صالح"),
    business_date: z.string({ required_error: "التاريخ مطلوب" }).trim().min(1, "التاريخ مطلوب"),
    supplier_invoice_number: optionalText(100),
    supplier_invoice_date: optionalText(20),
    lines: z.array(purchaseInvoiceLineSchema).min(1, "يجب إضافة بند واحد على الأقل"),
    net_total: positiveMoneySchema("إجمالي الصافي"),
    vat_total: nonNegativeMoneySchema("إجمالي الضريبة"),
    gross_total: positiveMoneySchema("الإجمالي"),
    notes: optionalText(1000),
    closed_day_reason: optionalText(1000),
  })
  .superRefine((v, ctx) => {
    // The header must equal the sum of its lines, exactly — no tolerance.
    const net = v.lines.reduce((acc, l) => sumMoney(acc, l.net_amount), "0");
    const vat = v.lines.reduce((acc, l) => sumMoney(acc, l.vat_amount), "0");
    const gross = v.lines.reduce((acc, l) => sumMoney(acc, l.gross_amount), "0");

    if (net !== normalizeMoney(v.net_total)) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["net_total"], message: "إجمالي الصافي لا يطابق مجموع البنود" });
    }
    if (vat !== normalizeMoney(v.vat_total)) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["vat_total"], message: "إجمالي الضريبة لا يطابق مجموع البنود" });
    }
    if (gross !== normalizeMoney(v.gross_total)) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["gross_total"], message: "الإجمالي لا يطابق مجموع البنود" });
    }
  });

export type PostPurchaseInvoiceInput = z.infer<typeof postPurchaseInvoiceSchema>;

export const reversePurchaseInvoiceSchema = z.object({
  invoice_id: z.string({ required_error: "الفاتورة مطلوبة" }).uuid("فاتورة غير صالحة"),
  reason: z.string({ required_error: "سبب العكس مطلوب" }).trim().min(1, "سبب العكس مطلوب").max(1000),
  business_date: z.string({ required_error: "تاريخ العكس مطلوب" }).trim().min(1, "تاريخ العكس مطلوب"),
  closed_day_reason: optionalText(1000),
});

export type ReversePurchaseInvoiceInput = z.infer<typeof reversePurchaseInvoiceSchema>;

// ---------------------------------------------------------------------------
// record_supplier_payment() / reverse_supplier_payment() (migration 0239).
// ---------------------------------------------------------------------------
export const recordSupplierPaymentSchema = z.object({
  invoice_id: z.string({ required_error: "الفاتورة مطلوبة" }).uuid("فاتورة غير صالحة"),
  amount: positiveMoneySchema("مبلغ الدفعة"),
  payment_mode: z.enum(PAYMENT_MODES, { required_error: "طريقة الدفع مطلوبة" }),
  business_date: z.string({ required_error: "التاريخ مطلوب" }).trim().min(1, "التاريخ مطلوب"),
  payment_reference: optionalText(200),
  notes: optionalText(1000),
  closed_day_reason: optionalText(1000),
});

export type RecordSupplierPaymentInput = z.infer<typeof recordSupplierPaymentSchema>;

export const reverseSupplierPaymentSchema = z.object({
  payment_id: z.string({ required_error: "الدفعة مطلوبة" }).uuid("دفعة غير صالحة"),
  reason: z.string({ required_error: "سبب العكس مطلوب" }).trim().min(1, "سبب العكس مطلوب").max(1000),
  business_date: z.string({ required_error: "تاريخ العكس مطلوب" }).trim().min(1, "تاريخ العكس مطلوب"),
  closed_day_reason: optionalText(1000),
});

export type ReverseSupplierPaymentInput = z.infer<typeof reverseSupplierPaymentSchema>;

// ---------------------------------------------------------------------------
// list_purchase_invoices() filters.
// ---------------------------------------------------------------------------
export const purchasesListFiltersSchema = z.object({
  date_from: z.string().optional(),
  date_to: z.string().optional(),
  store_id: z.string().uuid().optional(),
  supplier_id: z.string().uuid().optional(),
  entry_kind: z.enum(["invoice", "reversal"]).optional(),
  payment_status: z.enum(["unpaid", "partial", "paid", "reversed", "reversal"]).optional(),
  search: z.string().optional(),
  page: z.number().int().min(1).default(1),
});

export type PurchasesListFilters = z.infer<typeof purchasesListFiltersSchema>;

// ---------------------------------------------------------------------------
// Exact decimal helpers — integer-cents arithmetic, never floating point.
// ---------------------------------------------------------------------------
/** True for a decimal string that is exactly zero ("0", "0.0", "0.000"), decided textually so no float is ever involved. */
export function isZeroDecimal(value: string): boolean {
  return /^-?0+(\.0+)?$/.test(value.trim());
}

/** Renders a decimal money string at exactly 2 places without going through a float. */
export function normalizeMoney(value: string): string {
  const v = value.trim();
  const negative = v.startsWith("-");
  const digits = negative ? v.slice(1) : v;
  const [whole, frac = ""] = digits.split(".");
  const cents = `${whole || "0"}${(frac + "00").slice(0, 2)}`.replace(/^0+(?=\d)/, "");
  const padded = cents.padStart(3, "0");
  const out = `${padded.slice(0, -2)}.${padded.slice(-2)}`;
  // "-0.00" is not a value: a negative sign survives only if some digit is
  // non-zero. Decided by inspecting the digits, never by Number(padded) — this
  // whole module is deliberately float-free.
  return negative && /[1-9]/.test(padded) ? `-${out}` : out;
}

/** Adds two decimal money strings exactly, in integer cents. */
export function sumMoney(a: string, b: string): string {
  const toCents = (s: string): bigint => {
    const n = normalizeMoney(s);
    return BigInt(n.replace(".", ""));
  };
  const total = toCents(a) + toCents(b);
  // BigInt(0), not the `0n` literal: this project's tsconfig target predates
  // ES2020 literals, while the BigInt constructor is available.
  const negative = total < BigInt(0);
  const abs = (negative ? -total : total).toString().padStart(3, "0");
  return `${negative ? "-" : ""}${abs.slice(0, -2)}.${abs.slice(-2)}`;
}

// ---------------------------------------------------------------------------
// DB error classification — same convention as expenses/inventory schema.ts.
// ---------------------------------------------------------------------------
/** True when a DB error message indicates the business date falls in a closed day — the UI must then ask for an explicit reason (and the actor needs purchases.process_closed_day). */
export function isClosedDayError(message: string): boolean {
  return message.includes("يوم مقفل");
}

/** True when a DB error message indicates the document was already reversed — the client must reload rather than retry. */
export function isAlreadyReversedError(message: string): boolean {
  return message.includes("مسبقًا");
}

/** True when a DB error message indicates an optimistic-concurrency Conflict (row_version mismatch). */
export function isVersionConflictError(message: string): boolean {
  return message.includes("مستخدم آخر");
}

/** True when the invoice cannot be reversed because a payment is still standing against it — the UI must reverse the payment first. */
export function isPaymentBlocksReversalError(message: string): boolean {
  return message.includes("دفعة غير معكوسة");
}

/** True when the payment would exceed what is still owed — the remaining balance moved under the operator, so the UI must reload. */
export function isOverpaymentError(message: string): boolean {
  return message.includes("يتجاوز المتبقي");
}
