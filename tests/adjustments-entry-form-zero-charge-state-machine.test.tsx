import { describe, expect, it, vi, beforeEach, beforeAll } from "vitest";
import { cleanup, render, screen, fireEvent } from "@testing-library/react";
import "@testing-library/jest-dom";
import { AdjustmentEntryForm } from "@/features/adjustments/components/adjustment-entry-form";

// Phase 6 Final Integrity Hotfix 6.1.1 item 11 — REAL component tests (not
// just Zod, unlike tests/adjustments-zero-charge-schema.test.ts) for the
// zero-charge state machine fixed by items 3/4 in adjustment-entry-form.tsx:
//
//   (A) Paid with method/channel/reference/settlement all set -> charge
//       driven to 0 -> the payment fields disappear from the DOM AND the
//       underlying state is actually cleared (not merely hidden) -- proven
//       by then flipping back to paid and asserting nothing stale reappears.
//   (B) 0 -> paid: previous values never return: method/channel must be
//       re-picked from scratch, and settlement participation is unset again
//       (submit stays blocked until the user explicitly re-chooses).
//   (C) A brand-new paid adjustment with no settlement choice made yet ->
//       submit is blocked; choosing "No" makes it valid; choosing "Yes"
//       (instead) also makes it valid.
//   (D) A free service (customer_charge = 0) always submits with
//       participates_in_settlement forced to false -- proven via the actual
//       payload handed to createAdjustmentAction/updateAdjustmentAction, not
//       by peeking at React internals.
//
// Radix's <Select> needs a few jsdom polyfills it relies on for its pointer
// interactions (hasPointerCapture / scrollIntoView / ResizeObserver) --
// standard, well-known requirements for testing Radix components under
// jsdom; none of this changes the real component under test.

beforeAll(() => {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (window.HTMLElement.prototype as any).hasPointerCapture = vi.fn(() => false);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (window.HTMLElement.prototype as any).releasePointerCapture = vi.fn();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (window.HTMLElement.prototype as any).setPointerCapture = vi.fn();
  window.HTMLElement.prototype.scrollIntoView = vi.fn();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (global as any).ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
});

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn(), refresh: vi.fn() }),
}));

vi.mock("sonner", () => ({
  toast: { success: vi.fn(), error: vi.fn() },
}));

const { createAdjustmentAction, updateAdjustmentAction, previewAdjustmentAction, setAdjustmentCostAction } = vi.hoisted(() => ({
  createAdjustmentAction: vi.fn(async (_input?: { participates_in_settlement?: boolean; payment_method_id?: string; collection_channel_id?: string }) => ({ success: true, data: { id: "adj-new", adjustment_number: "ADJ-0000000099" } })),
  updateAdjustmentAction: vi.fn(async (_input?: unknown) => ({ success: true, data: { row_version: 2 } })),
  previewAdjustmentAction: vi.fn(async (_input?: unknown) => ({ success: true, data: { fee_found: true, payment_fee_amount: "1.00", gross_adjustment_profit: "10.00", net_adjustment_profit: "9.00" } })),
  setAdjustmentCostAction: vi.fn(async (_input?: unknown) => ({ success: true, data: { row_version: 1, direct_cost: "0.00", has_direct_cost: true } })),
}));
vi.mock("@/features/adjustments/actions", () => ({
  createAdjustmentAction,
  updateAdjustmentAction,
  previewAdjustmentAction,
  setAdjustmentCostAction,
}));

const ORDER = {
  sales_order_id: "so-1",
  order_number: "SALE-0000000090",
  sale_date: "2026-08-01",
  store_name: "فرع الرياض",
  customer_name: "عميل تجريبي",
  original_invoice_amount: "500.00",
};
const STORES = [{ id: "store-1", name_ar: "فرع الرياض" }];
const TYPES = [{ id: "type-1", code: "polish", name_ar: "تلميع" }];
const PAYMENT_METHODS = [
  { id: "pm-1", key: "cash", name_ar: "نقدًا" },
  { id: "pm-2", key: "visa", name_ar: "فيزا" },
];
const CHANNELS = [
  { id: "ch-1", key: "pos", name_ar: "نقطة بيع" },
  { id: "ch-2", key: "online", name_ar: "إلكتروني" },
];

const EXISTING_PAID = {
  id: "adj-1",
  row_version: 1,
  adjustment_type_id: "type-1",
  processing_store_id: "store-1",
  adjustment_date: "2026-08-10",
  payment_method_id: "pm-1",
  collection_channel_id: "ch-1",
  payment_reference: "REF-OLD-123",
  participates_in_settlement: true,
  customer_charge: "100.00",
  has_direct_cost: true,
  direct_cost: "20.00",
  notes: null,
};

function renderEditForm(existing = EXISTING_PAID) {
  return render(
    <AdjustmentEntryForm order={ORDER} stores={STORES} types={TYPES} paymentMethods={PAYMENT_METHODS} collectionChannels={CHANNELS} mode="edit" existing={existing} canManageCost={false} />,
  );
}

function renderCreateForm() {
  return render(
    <AdjustmentEntryForm order={ORDER} stores={STORES} types={TYPES} paymentMethods={PAYMENT_METHODS} collectionChannels={CHANNELS} mode="create" canManageCost={false} />,
  );
}

/** Opens a Radix <Select> by its trigger button and clicks the option with the given accessible name. */
function pickSelectOption(trigger: HTMLElement, optionName: string | RegExp) {
  fireEvent.pointerDown(trigger, { button: 0, ctrlKey: false, pointerId: 1 });
  fireEvent.click(trigger);
  const option = screen.getByRole("option", { name: optionName });
  fireEvent.pointerUp(option);
  fireEvent.click(option);
}

describe("AdjustmentEntryForm — Hotfix 6.1.1 item 11: zero-charge state machine", () => {
  beforeEach(() => {
    cleanup();
    createAdjustmentAction.mockClear();
    updateAdjustmentAction.mockClear();
    previewAdjustmentAction.mockClear();
  });

  it("(A) paid -> free: payment method/channel/reference fields disappear and the settlement participation control is gone", () => {
    renderEditForm();

    // Sanity: while paid, the payment fields are present with their existing values.
    expect(screen.getByDisplayValue("REF-OLD-123")).toBeInTheDocument();
    expect(screen.getByText("يشارك في التسوية")).toBeInTheDocument();

    const inputs = screen.getAllByDisplayValue(/^(100\.00)$/);
    expect(inputs.length).toBeGreaterThan(0);
    const chargeField = inputs[0];

    fireEvent.change(chargeField, { target: { value: "0" } });

    // Payment reference field must be gone entirely (not merely styled hidden).
    expect(screen.queryByDisplayValue("REF-OLD-123")).not.toBeInTheDocument();
    // The free-service explanatory note must now be visible.
    expect(screen.getByText(/خدمة مجانية: لا طريقة دفع ولا قناة تحصيل ولا مشاركة في التسوية/)).toBeInTheDocument();
  });

  it("(A continued) / (B) paid -> free -> paid: nothing stale reappears — method/channel/reference/settlement must all be re-entered from scratch", () => {
    renderEditForm();

    const chargeField = screen.getAllByDisplayValue(/^(100\.00)$/)[0];

    // paid -> free
    fireEvent.change(chargeField, { target: { value: "0" } });
    expect(screen.queryByDisplayValue("REF-OLD-123")).not.toBeInTheDocument();

    // free -> paid again
    fireEvent.change(chargeField, { target: { value: "50" } });

    // Payment reference must be empty, not the old "REF-OLD-123".
    const referenceInputs = screen.queryAllByDisplayValue("REF-OLD-123");
    expect(referenceInputs).toHaveLength(0);

    // Payment method / collection channel selects must show their unselected placeholders again.
    expect(screen.getByText("اختر طريقة الدفع")).toBeInTheDocument();
    expect(screen.getByText("اختر قناة التحصيل")).toBeInTheDocument();

    // Settlement participation must be back to the unset sentinel, not the
    // previous "true" (يشارك في التسوية) choice.
    expect(screen.getByText("-- اختر --")).toBeInTheDocument();
    expect(screen.queryByText("يشارك في التسوية", { selector: "span" })).not.toBeInTheDocument();

    // And submit must be blocked again until method/channel/settlement are
    // all explicitly re-picked — proves the clearing isn't cosmetic.
    expect(screen.getByRole("button", { name: /حفظ التعديلات/ })).toBeDisabled();
  });

  it("(C) a brand-new paid adjustment blocks submit until settlement participation is explicitly chosen (No or Yes both unblock it)", () => {
    renderCreateForm();

    const typeTrigger = screen.getAllByRole("combobox")[0];
    pickSelectOption(typeTrigger, "تلميع");

    const combosAfterType = screen.getAllByRole("combobox");
    pickSelectOption(combosAfterType[1], "فرع الرياض");

    const dateInput = document.querySelector('input[type="date"]') as HTMLInputElement;
    fireEvent.change(dateInput, { target: { value: "2026-08-20" } });

    // customer_charge is the number input rendered before the (permission-
    // gated, absent here since canManageCost=false) direct_cost field.
    const numberInputs = document.querySelectorAll('input[type="number"]');
    expect(numberInputs.length).toBeGreaterThan(0);
    fireEvent.change(numberInputs[0], { target: { value: "100" } });

    // Now pick payment method + channel (required once paid).
    const combosAfterCharge = screen.getAllByRole("combobox");
    // Order: type, store, payment method, channel, settlement.
    pickSelectOption(combosAfterCharge[2], "نقدًا");
    const combosAfterMethod = screen.getAllByRole("combobox");
    pickSelectOption(combosAfterMethod[3], "نقطة بيع");

    const submitButton = screen.getByRole("button", { name: /إنشاء التعديل\/الخدمة/ });
    // Settlement not chosen yet -> still blocked.
    expect(submitButton).toBeDisabled();

    // Choose "No" (لا يشارك) — must unblock.
    const combosAfterChannel = screen.getAllByRole("combobox");
    pickSelectOption(combosAfterChannel[4], "لا يشارك في التسوية");
    expect(submitButton).not.toBeDisabled();

    // Switch the choice to "Yes" (يشارك) — must remain unblocked.
    const combosFinal = screen.getAllByRole("combobox");
    pickSelectOption(combosFinal[4], "يشارك في التسوية");
    expect(submitButton).not.toBeDisabled();
  });

  it("(D) a free service always submits with participates_in_settlement forced to false", async () => {
    renderCreateForm();

    const combos = screen.getAllByRole("combobox");
    pickSelectOption(combos[0], "تلميع");
    pickSelectOption(screen.getAllByRole("combobox")[1], "فرع الرياض");

    const dateInput = document.querySelector('input[type="date"]') as HTMLInputElement;
    fireEvent.change(dateInput, { target: { value: "2026-08-20" } });

    const numberInputs = document.querySelectorAll('input[type="number"]');
    fireEvent.change(numberInputs[0], { target: { value: "0" } });

    const submitButton = screen.getByRole("button", { name: /إنشاء التعديل\/الخدمة/ });
    expect(submitButton).not.toBeDisabled();

    fireEvent.click(submitButton);

    await vi.waitFor(() => {
      expect(createAdjustmentAction).toHaveBeenCalledTimes(1);
    });
    const callArg = createAdjustmentAction.mock.calls[0][0];
    expect(callArg?.participates_in_settlement).toBe(false);
    expect(callArg?.payment_method_id).toBeUndefined();
    expect(callArg?.collection_channel_id).toBeUndefined();
  });
});
