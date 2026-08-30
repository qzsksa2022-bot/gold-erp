import { describe, expect, it, vi, beforeEach } from "vitest";
import { cleanup, render, screen, fireEvent, waitFor } from "@testing-library/react";
import "@testing-library/jest-dom";
import { ShipmentEntryForm } from "@/features/shipping/components/shipment-entry-form";

// Hotfix 5.1.1 items 1/2/3 — regression tests for the Customer Return
// Shipping Fee behavior in <ShipmentEntryForm/> (direction="return"):
//
//   item 2 — the OLD auto-fill effect used `prev ? prev : fee_amount`,
//   which only ever filled customer_shipping_charge ONCE: the first
//   non-empty value froze the field forever, so switching from a zone
//   suggesting 35.00 to a zone suggesting 50.00 silently kept showing
//   35.00 (stale). Fixed with an explicit touched-state: the field keeps
//   resyncing to the live suggestion until the actor genuinely edits it.
//
//   item 1 — once the submitted charge actually diverges from the live
//   suggestion (a genuine override, or no configuration at all), a
//   mandatory reason field must appear and gate submission.
//
//   item 3 — the "is this an override" comparison always uses the LATEST
//   fetched suggestion (Preview/Create parity) and is numeric-safe (e.g.
//   "35" and "35.00" must compare equal, not just fail a strict string ==).

// Radix Select needs a few DOM APIs jsdom does not implement.
class NoopResizeObserver {
  observe() {}
  unobserve() {}
  disconnect() {}
}

beforeEach(() => {
  Element.prototype.hasPointerCapture = Element.prototype.hasPointerCapture ?? (() => false);
  Element.prototype.setPointerCapture = Element.prototype.setPointerCapture ?? (() => {});
  Element.prototype.releasePointerCapture = Element.prototype.releasePointerCapture ?? (() => {});
  Element.prototype.scrollIntoView = Element.prototype.scrollIntoView ?? (() => {});
  globalThis.ResizeObserver = globalThis.ResizeObserver ?? (NoopResizeObserver as unknown as typeof ResizeObserver);
});

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn(), refresh: vi.fn() }),
}));

// Hotfix 5.1.3 item 2 — a real union, matching the actual ActionResult<T>
// shape (src/lib/action-result.ts): success:false carries `error`, NOT a
// `data` with found:false. Collapsing these into one shape (as the OLD
// type here did, with a plain `success: boolean`) is exactly the bug this
// hotfix's item 1/2 closes — a failed Server Action call is a genuinely
// different outcome than "the RPC ran and said found: false".
type PreviewFeeResult =
  | { success: true; data: { found: boolean; rate_version_id: string | null; fee_amount: string | null } }
  | { success: false; error: string };

const previewShipmentExpectedCostAction = vi.fn(async () => ({ success: true, data: { found: true, rate_version_id: "rv-1", expected_carrier_cost: "20.00" } }));
const previewCustomerReturnShippingFeeAction = vi.fn(async ({ shippingZoneId }: { shippingZoneId: string; date?: string }): Promise<PreviewFeeResult> => {
  if (shippingZoneId === "zone-riyadh") return { success: true, data: { found: true, rate_version_id: "fee-1", fee_amount: "35.00" } };
  if (shippingZoneId === "zone-outside") return { success: true, data: { found: true, rate_version_id: "fee-2", fee_amount: "50.00" } };
  return { success: true, data: { found: false, rate_version_id: null, fee_amount: null } };
});
const createShipmentAction = vi.fn(async () => ({ success: true, data: { id: "shp-1", shipment_number: "SHP-0000000001" } }));

vi.mock("@/features/shipping/actions", () => ({
  previewShipmentExpectedCostAction: (...args: unknown[]) => previewShipmentExpectedCostAction(...(args as [])),
  previewCustomerReturnShippingFeeAction: (...args: unknown[]) => previewCustomerReturnShippingFeeAction(...(args as [{ shippingZoneId: string; date?: string }])),
  createShipmentAction: (...args: unknown[]) => createShipmentAction(...(args as [])),
}));

const order = {
  id: "order-1",
  order_number: "SALE-0000000090",
  sale_date: "2026-08-01",
  store_id: "store-1",
  store_name: "فرع الرياض",
  customer_name: "عميل تجريبي",
  customer_phone: "0500000000",
};

const existingReturn = {
  id: "return-1",
  return_number: "RET-0000000010",
  return_date: "2026-08-15",
  status: "approved",
};

const stores = [{ id: "store-1", name_ar: "فرع الرياض" }];
const carriers = [{ id: "carrier-1", code: "SMSA", name_ar: "سمسا" }];
const zones = [
  { id: "zone-riyadh", code: "RIYADH", name_ar: "الرياض" },
  { id: "zone-outside", code: "OUTSIDE_RIYADH", name_ar: "خارج الرياض" },
  // Hotfix 5.1.2 item 1 — a zone with genuinely NO customer-return-fee
  // configuration at all (falls through the mock's default branch below,
  // found: false) — distinct from "zone-outside", which IS configured
  // (50.00). Needed to test the configured -> no-config transition.
  { id: "zone-noconfig", code: "NOCONFIG", name_ar: "بدون تسعير" },
];

function renderForm() {
  return render(
    <ShipmentEntryForm order={order} existingReturn={existingReturn} direction="return" stores={stores} carriers={carriers} zones={zones} />,
  );
}

function getZoneTrigger(): HTMLElement {
  // Selected by the "المنطقة" Label's sibling, not by placeholder text —
  // the trigger's own text changes to the selected zone's name once a
  // value is picked, so a placeholder-text lookup only works the FIRST
  // time.
  const label = screen.getByText("المنطقة");
  return label.parentElement!.querySelector("button[role='combobox']")!;
}

function getCarrierTrigger(): HTMLElement {
  const label = screen.getByText("شركة الشحن");
  return label.parentElement!.querySelector("button[role='combobox']")!;
}

async function selectCarrier(nameAr: string) {
  const trigger = await waitFor(() => {
    const el = getCarrierTrigger();
    expect(el).not.toBeDisabled();
    return el;
  });
  fireEvent.pointerDown(trigger, { button: 0, ctrlKey: false, pointerId: 1, pointerType: "mouse" });
  fireEvent.click(trigger);
  const option = await screen.findByRole("option", { name: nameAr });
  fireEvent.click(option);
}

function getChargeInput(): HTMLInputElement {
  // Same anchoring convention as getZoneTrigger() — via the stable Label
  // text, not a display-value lookup (which breaks once the field is
  // legitimately empty, e.g. after Hotfix 5.1.2 item 1's clear-on-no-
  // config, since several OTHER fields are also empty by default).
  const label = screen.getByText("رسوم الشحن على العميل");
  return label.parentElement!.querySelector("input") as HTMLInputElement;
}

async function selectZone(nameAr: string) {
  // The zone Select is disabled while the carrier/date preview effect's
  // startTransition is still settling right after mount/a prior state
  // change — waiting for it to become enabled avoids a flaky no-op click
  // on a still-disabled trigger.
  const trigger = await waitFor(() => {
    const el = getZoneTrigger();
    expect(el).not.toBeDisabled();
    return el;
  });
  fireEvent.pointerDown(trigger, { button: 0, ctrlKey: false, pointerId: 1, pointerType: "mouse" });
  fireEvent.click(trigger);
  // Radix also renders a visually-hidden native <select>/<option> fallback
  // with the SAME text for accessibility, so a plain findByText(nameAr)
  // matches twice — scope to the actual popup option (role="option").
  const option = await screen.findByRole("option", { name: nameAr });
  fireEvent.click(option);
}

describe("ShipmentEntryForm — Hotfix 5.1.1 items 1/2/3 (return shipping fee)", () => {
  beforeEach(() => {
    cleanup();
    previewCustomerReturnShippingFeeAction.mockClear();
    createShipmentAction.mockClear();
  });

  it("item 2: auto-fills the suggested fee for the first zone picked", async () => {
    renderForm();
    await selectZone("الرياض");

    await waitFor(() => expect(screen.getByDisplayValue("35.00")).toBeInTheDocument());
    // No divergence yet -> no override-reason field.
    expect(screen.queryByText("سبب تجاوز رسوم شحن الإرجاع القياسية")).not.toBeInTheDocument();
  });

  it("item 2 (the actual regression): switching to a zone with a DIFFERENT suggestion resyncs the field instead of freezing on the first zone's value", async () => {
    renderForm();
    await selectZone("الرياض");
    await waitFor(() => expect(screen.getByDisplayValue("35.00")).toBeInTheDocument());

    await selectZone("خارج الرياض");

    // Old buggy behavior: field would still read "35.00" here (stale).
    await waitFor(() => expect(screen.getByDisplayValue("50.00")).toBeInTheDocument());
    expect(screen.queryByDisplayValue("35.00")).not.toBeInTheDocument();
    expect(screen.queryByText("سبب تجاوز رسوم شحن الإرجاع القياسية")).not.toBeInTheDocument();
  });

  it("item 1: once the actor types a value that diverges from the live suggestion, the mandatory override-reason field appears and gates submission", async () => {
    renderForm();
    await selectZone("الرياض");
    await waitFor(() => expect(screen.getByDisplayValue("35.00")).toBeInTheDocument());

    const chargeInput = screen.getByDisplayValue("35.00");
    fireEvent.change(chargeInput, { target: { value: "60.00" } });

    expect(await screen.findByText("سبب تجاوز رسوم شحن الإرجاع القياسية")).toBeInTheDocument();
    expect(screen.getByText(/القيمة القياسية لهذه المنطقة 35.00 ر.س/)).toBeInTheDocument();

    // Submit is disabled without a reason.
    const submitButton = screen.getByRole("button", { name: /إنشاء الشحنة/ });
    expect(submitButton).toBeDisabled();
  });

  it("item 2: once touched, the field no longer resyncs when the zone changes again (a deliberate override survives)", async () => {
    renderForm();
    await selectZone("الرياض");
    await waitFor(() => expect(screen.getByDisplayValue("35.00")).toBeInTheDocument());

    const chargeInput = screen.getByDisplayValue("35.00");
    fireEvent.change(chargeInput, { target: { value: "99.00" } });
    await screen.findByText("سبب تجاوز رسوم شحن الإرجاع القياسية");

    await selectZone("خارج الرياض");

    // The touched value must survive the zone change (not silently reset).
    await waitFor(() => expect(screen.getByDisplayValue("99.00")).toBeInTheDocument());
  });

  it("item 3: a numerically-equal but differently-formatted value (\"35\" vs \"35.00\") is NOT treated as an override", async () => {
    renderForm();
    await selectZone("الرياض");
    await waitFor(() => expect(screen.getByDisplayValue("35.00")).toBeInTheDocument());

    const chargeInput = screen.getByDisplayValue("35.00");
    fireEvent.change(chargeInput, { target: { value: "35" } });

    expect(screen.queryByText("سبب تجاوز رسوم شحن الإرجاع القياسية")).not.toBeInTheDocument();
  });
});

describe("ShipmentEntryForm — Hotfix 5.1.2 items 1/2 (configured -> no-config transition, preview loading)", () => {
  beforeEach(() => {
    cleanup();
    previewCustomerReturnShippingFeeAction.mockClear();
    createShipmentAction.mockClear();
  });

  it("item 1 (untouched): switching from a configured zone to a zone with NO return-fee configuration CLEARS the stale value instead of leaving it displayed", async () => {
    renderForm();
    await selectZone("الرياض");
    await waitFor(() => expect(getChargeInput().value).toBe("35.00"));

    await selectZone("بدون تسعير");

    // The old code left "35.00" on screen here — a real value carried over
    // from a zone that no longer applies, with nothing to signal it was
    // stale.
    await waitFor(() => expect(getChargeInput().value).toBe(""));
    // Nothing to override yet (the charge is empty) — the mandatory-reason
    // block only appears once the actor actually enters a manual charge.
    expect(screen.queryByText("سبب تجاوز رسوم شحن الإرجاع القياسية")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /إنشاء الشحنة/ })).toBeDisabled();

    // Entering a manual charge for this unconfigured zone now surfaces the
    // mandatory override-reason field (item 1's "No-config requires Manual
    // Charge + reason").
    fireEvent.change(getChargeInput(), { target: { value: "45.00" } });
    expect(await screen.findByText("سبب تجاوز رسوم شحن الإرجاع القياسية")).toBeInTheDocument();
    expect(screen.getByText(/لا يوجد تسعير معتمد لرسوم شحن الإرجاع لهذه المنطقة\/التاريخ/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /إنشاء الشحنة/ })).toBeDisabled();
  });

  it("item 1 (touched): switching from a configured zone to a zone with NO configuration PRESERVES a manually-entered value and requires a reason", async () => {
    renderForm();
    await selectCarrier("سمسا");
    await selectZone("الرياض");
    await waitFor(() => expect(getChargeInput().value).toBe("35.00"));

    fireEvent.change(getChargeInput(), { target: { value: "42.00" } });
    await screen.findByText("سبب تجاوز رسوم شحن الإرجاع القياسية");

    await selectZone("بدون تسعير");

    // Manual value survives — never silently reset just because the new
    // zone happens to have no configuration.
    await waitFor(() => expect(getChargeInput().value).toBe("42.00"));
    expect(screen.getByText(/لا يوجد تسعير معتمد لرسوم شحن الإرجاع لهذه المنطقة\/التاريخ/)).toBeInTheDocument();

    const submitButton = screen.getByRole("button", { name: /إنشاء الشحنة/ });
    expect(submitButton).toBeDisabled();
    // Label/Textarea are unlinked siblings (no htmlFor/id) in this codebase
    // — same anchoring convention as getChargeInput()/getZoneTrigger().
    const reasonLabel = screen.getByText("سبب تجاوز رسوم شحن الإرجاع القياسية");
    const reasonTextarea = reasonLabel.parentElement!.querySelector("textarea") as HTMLTextAreaElement;
    fireEvent.change(reasonTextarea, { target: { value: "لا تسعير معتمد لهذه المنطقة الجديدة" } });
    await waitFor(() => expect(submitButton).not.toBeDisabled());
  });

  it("item 2: submit stays blocked for the WHOLE window a new zone's return-fee preview is in flight, not just once it resolves — and the loading state is shown distinctly from 'no configuration'", async () => {
    renderForm();
    await selectZone("الرياض");
    await waitFor(() => expect(getChargeInput().value).toBe("35.00"));

    let resolvePreview: (value: PreviewFeeResult) => void = () => {};
    previewCustomerReturnShippingFeeAction.mockImplementationOnce(
      () =>
        new Promise<PreviewFeeResult>((resolve) => {
          resolvePreview = resolve;
        }),
    );

    await selectZone("خارج الرياض");

    // Mid-flight: the OLD zone's value/message must not silently remain
    // usable — a distinct "loading" message is shown, and submit is
    // disabled purely because of this in-flight preview (every other
    // field is otherwise valid at this point).
    expect(await screen.findByText(/جارٍ التحقق من رسوم شحن الإرجاع المعتمدة لهذه المنطقة/)).toBeInTheDocument();
    expect(screen.queryByText(/لا يوجد تسعير معتمد لرسوم شحن الإرجاع/)).not.toBeInTheDocument();
    const submitButton = screen.getByRole("button", { name: /إنشاء الشحنة/ });
    expect(submitButton).toBeDisabled();

    resolvePreview({ success: true, data: { found: true, rate_version_id: "fee-2", fee_amount: "50.00" } });

    await waitFor(() => expect(getChargeInput().value).toBe("50.00"));
    expect(screen.queryByText(/جارٍ التحقق من رسوم شحن الإرجاع المعتمدة لهذه المنطقة/)).not.toBeInTheDocument();
  });
});

// Hotfix 5.1.3 items 1/2/3 — a Server Action FAILURE (success:false, or a
// thrown exception) is a genuinely different outcome from "the RPC ran and
// said found:false". The OLD code funneled BOTH into the same "not_found"
// branch, silently telling the actor "no configuration exists — enter a
// manual charge + reason" for what might actually be a DB/network/session
// failure that has nothing to do with pricing configuration. These tests
// prove: (A) success:false shows a distinct error message and blocks
// submit even with a manual charge entered, (B) a thrown exception is
// handled identically with no unhandled rejection, (C) Retry recovering to
// a real "found" result transitions the UI correctly and re-enables
// submit, (D) Retry recovering to a real "not_found" result reaches the
// genuine no-config path only AFTER the successful response — never
// during the error itself.
describe("ShipmentEntryForm — Hotfix 5.1.3 items 1/2/3 (preview ERROR is not no-config, Retry recovers)", () => {
  beforeEach(() => {
    cleanup();
    previewCustomerReturnShippingFeeAction.mockClear();
    createShipmentAction.mockClear();
  });

  it("item A: a Server Action success:false response shows a distinct ERROR message (never the no-config wording), and a manual charge does NOT unlock submit", async () => {
    previewCustomerReturnShippingFeeAction.mockImplementationOnce(async () => ({ success: false, error: "تعذر الاتصال بقاعدة البيانات" }));
    renderForm();
    await selectCarrier("سمسا");
    await selectZone("الرياض");

    expect(await screen.findByText("تعذر الاتصال بقاعدة البيانات")).toBeInTheDocument();
    expect(screen.queryByText(/لا يوجد تسعير معتمد لرسوم شحن الإرجاع/)).not.toBeInTheDocument();
    expect(screen.queryByText("سبب تجاوز رسوم شحن الإرجاع القياسية")).not.toBeInTheDocument();

    const submitButton = screen.getByRole("button", { name: /إنشاء الشحنة/ });
    expect(submitButton).toBeDisabled();

    // Item 3's explicit requirement: entering a manual charge (and even a
    // "reason", if the override block somehow rendered) must NOT unlock
    // submit while the preview is in an error state.
    fireEvent.change(getChargeInput(), { target: { value: "45.00" } });
    expect(submitButton).toBeDisabled();
    expect(screen.queryByText("سبب تجاوز رسوم شحن الإرجاع القياسية")).not.toBeInTheDocument();
  });

  it("item B: a THROWN exception from the Server Action call is treated identically to success:false — no unhandled rejection, same error UI, submit disabled", async () => {
    previewCustomerReturnShippingFeeAction.mockImplementationOnce(async () => {
      throw new Error("network failure");
    });
    renderForm();
    await selectCarrier("سمسا");
    await selectZone("الرياض");

    expect(await screen.findByText("تعذر التحقق من رسوم شحن الإرجاع. أعد المحاولة قبل إنشاء الشحنة.")).toBeInTheDocument();
    expect(screen.queryByText(/لا يوجد تسعير معتمد لرسوم شحن الإرجاع/)).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /إنشاء الشحنة/ })).toBeDisabled();
  });

  it("item C (Retry -> found): clicking 'إعادة التحقق' after an error and getting a real found result fills the untouched field, shows the found message, and re-enables submit once other fields are complete", async () => {
    previewCustomerReturnShippingFeeAction.mockImplementationOnce(async () => ({ success: false, error: "خطأ مؤقت" }));
    renderForm();
    await selectCarrier("سمسا");
    await selectZone("الرياض");

    expect(await screen.findByText("خطأ مؤقت")).toBeInTheDocument();

    const retryButton = screen.getByRole("button", { name: "إعادة التحقق" });
    fireEvent.click(retryButton);

    await waitFor(() => expect(getChargeInput().value).toBe("35.00"));
    expect(screen.queryByText("خطأ مؤقت")).not.toBeInTheDocument();
    expect(screen.getByText(/القيمة المقترحة لهذه المنطقة: 35.00/)).toBeInTheDocument();

    const submitButton = screen.getByRole("button", { name: /إنشاء الشحنة/ });
    await waitFor(() => expect(submitButton).not.toBeDisabled());
  });

  it("item D (Retry -> genuine not_found): after an error, Retry resolving to a real found:false reaches the no-config path only AFTER the successful response, and manual charge + reason are then allowed", async () => {
    previewCustomerReturnShippingFeeAction.mockImplementationOnce(async () => ({ success: false, error: "خطأ مؤقت" }));
    renderForm();
    await selectCarrier("سمسا");
    await selectZone("بدون تسعير");

    expect(await screen.findByText("خطأ مؤقت")).toBeInTheDocument();
    // Must NOT be presented as no-config while still in the error state.
    expect(screen.queryByText(/لا يوجد تسعير معتمد لرسوم شحن الإرجاع/)).not.toBeInTheDocument();

    const retryButton = screen.getByRole("button", { name: "إعادة التحقق" });
    fireEvent.click(retryButton);

    await waitFor(() => expect(screen.queryByText("خطأ مؤقت")).not.toBeInTheDocument());
    // Same "empty field, nothing to override yet" behavior as Hotfix
    // 5.1.2's untouched no-config case — the override block only appears
    // once a manual charge is actually entered.
    expect(screen.queryByText("سبب تجاوز رسوم شحن الإرجاع القياسية")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /إنشاء الشحنة/ })).toBeDisabled();

    fireEvent.change(getChargeInput(), { target: { value: "45.00" } });
    expect(await screen.findByText("سبب تجاوز رسوم شحن الإرجاع القياسية")).toBeInTheDocument();
    expect(screen.getByText(/لا يوجد تسعير معتمد لرسوم شحن الإرجاع لهذه المنطقة\/التاريخ/)).toBeInTheDocument();
  });
});
