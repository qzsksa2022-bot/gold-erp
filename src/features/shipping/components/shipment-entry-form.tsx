"use client";

import { useCallback, useEffect, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import { ROUTES } from "@/lib/constants";
import { riyadhTodayIsoDate, formatRiyadhDate } from "@/lib/date";
import { toDecimal } from "@/lib/decimal";
import { createShipmentAction, previewShipmentExpectedCostAction, previewCustomerReturnShippingFeeAction } from "../actions";
import { SHIPMENT_FULFILLMENT_TYPES, SHIPMENT_FULFILLMENT_TYPE_LABELS_AR, isClosedDayError } from "../schema";
import { ClosedDayReasonDialog } from "@/features/sales/components/closed-day-reason-dialog";

type Store = { id: string; name_ar: string };
type Carrier = { id: string; code: string; name_ar: string };
type Zone = { id: string; code: string; name_ar: string };

export type ShipmentOrderSummary = {
  id: string;
  order_number: string;
  sale_date: string;
  store_id: string;
  store_name: string | null;
  customer_name: string | null;
  customer_phone: string | null;
};

export type ShipmentReturnSummary = {
  id: string;
  return_number: string;
  return_date: string;
  status: string;
};

/**
 * Hotfix 5.1.1 item 3 — safe numeric equality for two money strings (e.g.
 * "35" vs "35.00" must compare equal, not just fail a strict string ==).
 * Never throws on a not-yet-valid in-progress input; an unparsable value is
 * simply treated as "differs" (conservative — surfaces the override-reason
 * field rather than silently hiding it).
 */
function moneyStringsEqual(a: string, b: string): boolean {
  try {
    return toDecimal(a).equals(toDecimal(b));
  } catch {
    return false;
  }
}

/**
 * Hotfix 5.1.3 item 3 — the one message shown for every "the return-fee
 * preview genuinely failed" case (Server Action returned success:false, or
 * the call itself threw). Never shown for a real "no configuration exists"
 * result — that is a DIFFERENT, successful RPC outcome (see fetchFeePreview
 * below) and keeps its own distinct "لا يوجد تسعير معتمد..." messaging.
 */
const FEE_PREVIEW_ERROR_MESSAGE_AR = "تعذر التحقق من رسوم شحن الإرجاع. أعد المحاولة قبل إنشاء الشحنة.";

/**
 * The /shipments/new entry form (Section 39/40) — a single transactional
 * submit to create_shipment() (0117). Carrier/zone/expected-cost/customer-
 * return-fee previews (Section 17/8) are fetched via the narrow, shipments.
 * create-gated preview_*() RPCs (0117) as the actor picks carrier/zone/date
 * — never a direct read of shipping_carrier_rate_versions/customer_return_
 * shipping_fee_versions (those require shipping_rates.view). If no rate
 * configuration is found, the manual-cost + mandatory-reason fields reveal
 * themselves inline (Section 17's "never assume zero" escape hatch) rather
 * than blocking submission.
 */
export function ShipmentEntryForm({
  order,
  existingReturn,
  direction,
  stores,
  carriers,
  zones,
}: {
  order: ShipmentOrderSummary;
  existingReturn?: ShipmentReturnSummary;
  direction: "outbound" | "return";
  stores: Store[];
  carriers: Carrier[];
  zones: Zone[];
}) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();

  const defaultStoreId = stores.some((s) => s.id === order.store_id) ? order.store_id : (stores[0]?.id ?? "");

  const [storeId, setStoreId] = useState(defaultStoreId);
  const [shipmentDate, setShipmentDate] = useState(riyadhTodayIsoDate());
  const [carrierId, setCarrierId] = useState("");
  const [shippingZoneId, setShippingZoneId] = useState("");
  const [fulfillmentType, setFulfillmentType] = useState<(typeof SHIPMENT_FULFILLMENT_TYPES)[number]>("delivery");
  const [trackingNumber, setTrackingNumber] = useState("");
  const [externalReference, setExternalReference] = useState("");
  const [customerName, setCustomerName] = useState(order.customer_name ?? "");
  const [customerPhone, setCustomerPhone] = useState(order.customer_phone ?? "");
  const [recipientAddress, setRecipientAddress] = useState("");
  const [customerShippingCharge, setCustomerShippingCharge] = useState("");
  const [isCod, setIsCod] = useState(false);
  const [codExpectedAmount, setCodExpectedAmount] = useState("");
  const [notes, setNotes] = useState("");

  // Section 17 — rate-resolution preview state.
  const [rateChecked, setRateChecked] = useState(false);
  const [rateFound, setRateFound] = useState<boolean | null>(null);
  const [manualExpectedCost, setManualExpectedCost] = useState("");
  const [manualExpectedCostReason, setManualExpectedCostReason] = useState("");

  // Section 8 — suggested (overridable) customer return-shipping fee.
  // Hotfix 5.1.1 items 1-3 — explicit touched-state instead of the old
  // "field is non-empty" proxy (which froze on the FIRST zone's suggestion
  // and never resynced on a later zone/date change, see the effect below),
  // plus the mandatory override-reason field required whenever the
  // submitted charge diverges from the CURRENT live suggestion — always
  // compared against the same up-to-date preview the RPC itself resolves
  // at submit time (Preview/Create parity), never a stale cached value.
  //
  // Hotfix 5.1.2 item 2 — `feePreviewStatus` is a genuine tri-state
  // ("idle"/"loading"/"found"/"not_found"), not just a derived boolean.
  // The OLD code only ever set `feeSuggested` at the END of the fetch, so
  // during the async gap between picking a new zone/date and the preview
  // RPC resolving, the STALE previous zone's feeSuggested/returnFeeIsOverride
  // stayed on screen with nothing disabling submit (this effect was never
  // wrapped in startTransition, so `isPending` never covered it either) —
  // a real stale-preview-submit window. "loading" now blocks submit
  // explicitly (see canSubmit below) and is rendered distinctly from
  // "not_found" (no configuration at all for this zone/date) in the UI.
  //
  // Hotfix 5.1.3 item 1/2 — a FIFTH state, "error", was added because the
  // old code funneled two genuinely different outcomes into the same
  // "not_found" branch: (A) the RPC actually ran and said found=false (a
  // real "no configuration for this zone/date"), and (B) the Server Action
  // call itself failed (success:false — DB error, network/session problem,
  // unexpected backend failure) or threw. (B) is NOT "no configuration" —
  // presenting it that way silently invited the actor to enter a manual
  // charge + reason and submit, papering over a real failure. "error" now
  // has its own status, its own message (FEE_PREVIEW_ERROR_MESSAGE_AR
  // above), and — like "loading" — blocks submit outright (see
  // returnFeePreviewBlocking below).
  const [feePreviewStatus, setFeePreviewStatus] = useState<"idle" | "loading" | "found" | "not_found" | "error">("idle");
  const [feeSuggested, setFeeSuggested] = useState<string | null>(null);
  const [feePreviewErrorMessage, setFeePreviewErrorMessage] = useState<string | null>(null);
  const [customerShippingChargeTouched, setCustomerShippingChargeTouched] = useState(false);
  const [returnFeeOverrideReason, setReturnFeeOverrideReason] = useState("");

  // Hotfix 5.1.3 item 4 — a Preview Key invariant instead of relying solely
  // on useEffect cleanup timing to prevent a stale preview from being
  // treated as valid. `resolvedFeePreviewKey` records which zone/date the
  // LAST successfully-resolved preview (found or a genuine not_found)
  // actually answered for; submit for a return shipment is permitted only
  // when that key matches the CURRENTLY selected zone/date exactly (see
  // canSubmit below) — a resolution for zone A can never be mistaken for a
  // valid answer once the actor has switched to zone B, independent of
  // whatever order React chooses to run effects/cleanups in.
  const [resolvedFeePreviewKey, setResolvedFeePreviewKey] = useState<string | null>(null);
  // Tracks the key of the MOST RECENTLY STARTED fetch — an in-flight
  // request whose key no longer matches this ref by the time it resolves
  // has been superseded (a newer zone/date change, or a Retry click) and
  // its result is discarded rather than applied.
  const feePreviewRequestKeyRef = useRef<string | null>(null);
  // Read at response-resolution time (not captured at call-start) so that
  // if the actor types a manual charge WHILE a preview is still in flight,
  // the eventual response respects that edit instead of overwriting it.
  const customerShippingChargeTouchedRef = useRef(customerShippingChargeTouched);
  useEffect(() => {
    customerShippingChargeTouchedRef.current = customerShippingChargeTouched;
  }, [customerShippingChargeTouched]);

  const [pendingCloseReason, setPendingCloseReason] = useState(false);
  const [closedDayReason, setClosedDayReason] = useState<string | undefined>(undefined);

  useEffect(() => {
    let cancelled = false;
    startTransition(async () => {
      if (!carrierId || !shippingZoneId || !shipmentDate) {
        if (cancelled) return;
        setRateChecked(false);
        setRateFound(null);
        return;
      }
      const result = await previewShipmentExpectedCostAction({ carrierId, shippingZoneId, direction, shipmentDate });
      if (cancelled) return;
      setRateChecked(true);
      if (result.success) {
        setRateFound(result.data.found);
        if (!result.data.found) {
          setManualExpectedCost("");
          setManualExpectedCostReason("");
        }
      } else {
        setRateFound(null);
      }
    });
    return () => {
      cancelled = true;
    };
  }, [carrierId, shippingZoneId, shipmentDate, direction]);

  // Hotfix 5.1.3 items 1/2/3/4 — the single place that performs a
  // return-fee preview fetch, called both by the zone/date-driven effect
  // below AND by the "إعادة التحقق" Retry action (item 3). Keyed by
  // `key` (== `${direction}|${shippingZoneId}|${shipmentDate}`, see
  // currentFeePreviewKey below) so a response that arrives after a NEWER
  // request has already started (a later zone/date change, or another
  // Retry click) is detected and discarded — never applied to state that
  // no longer describes what's on screen.
  const fetchFeePreview = useCallback(async (key: string, zoneId: string, date: string) => {
    feePreviewRequestKeyRef.current = key;
    setFeePreviewStatus("loading");
    setFeePreviewErrorMessage(null);
    try {
      const result = await previewCustomerReturnShippingFeeAction({ shippingZoneId: zoneId, date });
      if (feePreviewRequestKeyRef.current !== key) return; // superseded — discard
      const touched = customerShippingChargeTouchedRef.current;
      if (result.success && result.data.found && result.data.fee_amount) {
        setFeeSuggested(result.data.fee_amount);
        setFeePreviewStatus("found");
        setResolvedFeePreviewKey(key);
        // Hotfix 5.1.1 item 2 — the OLD condition here was `prev ? prev :
        // fee_amount`, which only ever filled the field ONCE: the moment
        // any suggestion first arrived, the field became non-empty, and
        // every SUBSEQUENT zone/date change (a real re-fetch, reflected
        // correctly in feeSuggested above) silently left the input frozen
        // on the FIRST zone's value — e.g. switching from Riyadh (35.00) to
        // Outside Riyadh (50.00) kept showing 35.00 with no override-reason
        // field to explain the mismatch. Fixed with an explicit touched
        // flag: only skip the auto-fill once the ACTOR has genuinely typed
        // into the field themselves (see the input's onChange below) —
        // until then, every new suggestion always replaces the value, so
        // the field never goes stale behind the zone/date actually selected.
        if (!touched) setCustomerShippingCharge(result.data.fee_amount);
      } else if (result.success) {
        // result.success === true && data.found === false — the RPC
        // genuinely ran and reported no configuration exists. Hotfix 5.1.3
        // item 1 — this branch is now reached ONLY on an actual successful
        // RPC answer, never merely because the Server Action call failed
        // (see the else branch below, which is a completely different
        // outcome — "error", not "no configuration").
        setFeeSuggested(null);
        setFeePreviewStatus("not_found");
        setResolvedFeePreviewKey(key);
        // Hotfix 5.1.2 item 1 — a configured zone -> a zone/date with NO
        // configuration at all: an UNTOUCHED field must have its stale
        // value (a real suggestion carried over from the PREVIOUS zone,
        // not something the actor ever asked for) cleared — the old code
        // left it displayed verbatim, silently implying it was still a
        // valid suggestion for the new zone. A TOUCHED field (the actor's
        // own deliberate manual entry) is left untouched here — it simply
        // becomes an override requiring a reason, per the existing
        // returnFeeIsOverride computation below.
        if (!touched) setCustomerShippingCharge("");
      } else {
        // result.success === false — a real Server Action failure (DB
        // error, network/session/permission problem, unexpected backend
        // failure). Hotfix 5.1.3 item 1/2/3 — MUST NOT be treated as "no
        // configuration": its own "error" status, its own message, submit
        // stays blocked (returnFeePreviewBlocking below), and an untouched
        // field is cleared so a stale old suggestion never lingers looking
        // like a still-valid standard charge.
        setFeeSuggested(null);
        setFeePreviewStatus("error");
        setFeePreviewErrorMessage(result.error || FEE_PREVIEW_ERROR_MESSAGE_AR);
        if (!touched) setCustomerShippingCharge("");
      }
    } catch {
      // Hotfix 5.1.3 item 2 — a THROWN exception from the Server Action
      // call itself (never expected in normal operation, but must never
      // become an unhandled promise rejection) is treated identically to a
      // success:false response.
      if (feePreviewRequestKeyRef.current !== key) return; // superseded — discard
      setFeeSuggested(null);
      setFeePreviewStatus("error");
      setFeePreviewErrorMessage(FEE_PREVIEW_ERROR_MESSAGE_AR);
      if (!customerShippingChargeTouchedRef.current) setCustomerShippingCharge("");
    }
  }, []);

  // Hotfix 5.1.3 item 4 — the Preview Key itself: `${direction}|${zone}|
  // ${date}` uniquely identifies "what this preview is currently supposed
  // to answer for". Deliberately excludes touched-state — touching the
  // charge field never changes WHAT must be fetched, only what the
  // response is allowed to overwrite (handled via the ref above).
  const currentFeePreviewKey = `${direction}|${shippingZoneId}|${shipmentDate}`;

  useEffect(() => {
    (async () => {
      if (direction !== "return" || !shippingZoneId) {
        feePreviewRequestKeyRef.current = null;
        setFeePreviewStatus("idle");
        setFeeSuggested(null);
        setFeePreviewErrorMessage(null);
        setResolvedFeePreviewKey(null);
        return;
      }
      // Hotfix 5.1.2 item 2 — mark "loading" the instant a new zone/date is
      // picked, BEFORE the RPC round trip even starts (fetchFeePreview does
      // this immediately), so canSubmit (below) never has a window where a
      // stale prior-zone preview is displayed alongside an enabled submit
      // button.
      await fetchFeePreview(currentFeePreviewKey, shippingZoneId, shipmentDate);
    })();
    // fetchFeePreview is a stable useCallback (empty deps, reads current
    // values via refs/params) — safe to omit; currentFeePreviewKey is
    // fully derived from direction/shippingZoneId/shipmentDate, already
    // listed here.
  }, [direction, shippingZoneId, shipmentDate, fetchFeePreview, currentFeePreviewKey]);

  // Hotfix 5.1.1 items 1/3 — Preview/Create parity: "is this an override"
  // is always computed against the SAME live feeSuggested this effect just
  // resolved, never a value captured earlier — matching exactly what
  // create_shipment() will independently re-resolve (via the identical
  // customer_return_shipping_fee_for() resolver, migration 0125/0129)
  // inside the same shared rate-lock window at submit time.
  //
  // Hotfix 5.1.3 item 1/3 — explicitly excluded while feePreviewStatus is
  // "error": a failed preview must never be presented as "no configuration
  // — override with a reason", which is a completely different, legitimate
  // scenario. Submit is blocked outright during "error" regardless (see
  // returnFeePreviewBlocking below); this just keeps the override-reason
  // UI from appearing and being mistaken for an accepted path.
  const returnFeeIsOverride =
    direction === "return" &&
    feePreviewStatus !== "error" &&
    !!shippingZoneId &&
    !!customerShippingCharge &&
    (feeSuggested === null || !moneyStringsEqual(customerShippingCharge, feeSuggested));

  function submit(reason?: string) {
    startTransition(async () => {
      const result = await createShipmentAction({
        sales_order_id: order.id,
        store_id: storeId,
        shipment_date: shipmentDate,
        direction,
        carrier_id: carrierId,
        shipping_zone_id: shippingZoneId,
        customer_shipping_charge: customerShippingCharge,
        sales_return_id: direction === "return" ? existingReturn?.id : undefined,
        fulfillment_type: fulfillmentType,
        tracking_number: trackingNumber || undefined,
        external_reference: externalReference || undefined,
        customer_name: customerName || undefined,
        customer_phone: customerPhone || undefined,
        recipient_address: recipientAddress || undefined,
        is_cod: isCod,
        cod_expected_amount: isCod ? codExpectedAmount || undefined : undefined,
        manual_expected_cost: rateFound === false ? manualExpectedCost || undefined : undefined,
        manual_expected_cost_reason: rateFound === false ? manualExpectedCostReason || undefined : undefined,
        notes: notes || undefined,
        closed_day_reason: reason,
        customer_return_shipping_charge_override_reason: returnFeeIsOverride ? returnFeeOverrideReason || undefined : undefined,
      });

      if (result.success) {
        toast.success(result.message ?? "تم إنشاء الشحنة بنجاح");
        setPendingCloseReason(false);
        router.push(`${ROUTES.shipments}/${result.data.id}`);
        return;
      }

      if (!closedDayReason && isClosedDayError(result.error)) {
        setPendingCloseReason(true);
        return;
      }

      toast.error(result.error);
    });
  }

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    submit();
  }

  const requiresManualCost = rateChecked && rateFound === false;
  // Hotfix 5.1.2 item 2 — block submit for the whole window a NEW return-
  // fee preview is in flight, not just once it resolves. Only relevant for
  // direction="return" (feePreviewStatus stays "idle" for outbound).
  const returnFeePreviewLoading = direction === "return" && feePreviewStatus === "loading";
  const returnFeePreviewError = direction === "return" && feePreviewStatus === "error";
  // Hotfix 5.1.3 item 4 — the key-match invariant: submit for a return
  // shipment is permitted ONLY when the last resolved preview (found or a
  // genuine not_found) answered for the EXACT zone/date currently
  // selected. Covers idle/loading/error AND the "resolved, but for a now-
  // superseded zone/date" case in one condition — not merely relying on
  // effect-cleanup timing to have already cleared stale state.
  const returnFeePreviewBlocking = direction === "return" && !(resolvedFeePreviewKey === currentFeePreviewKey && (feePreviewStatus === "found" || feePreviewStatus === "not_found"));
  const canSubmit =
    !!storeId &&
    !!shipmentDate &&
    !!carrierId &&
    !!shippingZoneId &&
    !!customerShippingCharge &&
    !returnFeePreviewBlocking &&
    (!requiresManualCost || (!!manualExpectedCost && !!manualExpectedCostReason)) &&
    (!returnFeeIsOverride || !!returnFeeOverrideReason.trim());

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <Card>
        <CardHeader>
          <CardTitle className="text-base">
            {direction === "outbound" ? `شحنة ذهاب — عملية البيع ${order.order_number}` : `شحنة إرجاع — المرتجع ${existingReturn?.return_number ?? "—"} (عملية البيع ${order.order_number})`}
          </CardTitle>
        </CardHeader>
        <CardContent className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div className="flex flex-col gap-1.5">
            <Label>المتجر المعالِج</Label>
            <Select value={storeId} onValueChange={setStoreId} disabled={isPending}>
              <SelectTrigger>
                <SelectValue placeholder="اختر المتجر" />
              </SelectTrigger>
              <SelectContent>
                {stores.map((s) => (
                  <SelectItem key={s.id} value={s.id}>
                    {s.name_ar}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>تاريخ الشحنة</Label>
            <Input type="date" dir="ltr" value={shipmentDate} onChange={(e) => setShipmentDate(e.target.value)} disabled={isPending} />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>شركة الشحن</Label>
            <Select value={carrierId} onValueChange={setCarrierId} disabled={isPending}>
              <SelectTrigger>
                <SelectValue placeholder="اختر شركة الشحن" />
              </SelectTrigger>
              <SelectContent>
                {carriers.map((c) => (
                  <SelectItem key={c.id} value={c.id}>
                    {c.name_ar}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>المنطقة</Label>
            <Select value={shippingZoneId} onValueChange={setShippingZoneId} disabled={isPending}>
              <SelectTrigger>
                <SelectValue placeholder="اختر المنطقة" />
              </SelectTrigger>
              <SelectContent>
                {zones.map((z) => (
                  <SelectItem key={z.id} value={z.id}>
                    {z.name_ar}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>نوع التنفيذ</Label>
            <Select value={fulfillmentType} onValueChange={(v) => setFulfillmentType(v as (typeof SHIPMENT_FULFILLMENT_TYPES)[number])} disabled={isPending}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {SHIPMENT_FULFILLMENT_TYPES.map((t) => (
                  <SelectItem key={t} value={t}>
                    {SHIPMENT_FULFILLMENT_TYPE_LABELS_AR[t]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>رقم التتبع (اختياري)</Label>
            <Input dir="ltr" value={trackingNumber} onChange={(e) => setTrackingNumber(e.target.value)} disabled={isPending} />
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">التسليم والعميل</CardTitle>
        </CardHeader>
        <CardContent className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div className="flex flex-col gap-1.5">
            <Label>اسم العميل</Label>
            <Input value={customerName} onChange={(e) => setCustomerName(e.target.value)} disabled={isPending} />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label>هاتف العميل</Label>
            <Input dir="ltr" value={customerPhone} onChange={(e) => setCustomerPhone(e.target.value)} disabled={isPending} />
          </div>
          <div className="flex flex-col gap-1.5 sm:col-span-2">
            <Label>عنوان الاستلام (اختياري)</Label>
            <Textarea value={recipientAddress} onChange={(e) => setRecipientAddress(e.target.value)} disabled={isPending} rows={2} />
          </div>
          <div className="flex flex-col gap-1.5 sm:col-span-2">
            <Label>مرجع خارجي (اختياري)</Label>
            <Input dir="ltr" value={externalReference} onChange={(e) => setExternalReference(e.target.value)} disabled={isPending} />
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">الجانب المالي للشحنة (منفصل تمامًا عن ربح المبيعات)</CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-4">
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div className="flex flex-col gap-1.5">
              <Label>رسوم الشحن على العميل</Label>
              <Input
                dir="ltr"
                inputMode="decimal"
                value={customerShippingCharge}
                onChange={(e) => {
                  setCustomerShippingCharge(e.target.value);
                  // Hotfix 5.1.1 item 2 — a real edit by the actor, not the
                  // auto-fill effect above: from this point on the field no
                  // longer resyncs silently when the zone/date changes.
                  setCustomerShippingChargeTouched(true);
                }}
                disabled={isPending}
              />
              {/* Hotfix 5.1.2 item 2 — "loading" gets its OWN message,
                  distinct from "not_found" (no configuration at all) —
                  the two used to be indistinguishable to the actor (an
                  empty/stale field either way), which is exactly what let
                  a stale preview go unnoticed. */}
              {direction === "return" && feePreviewStatus === "loading" && (
                <p className="text-xs text-muted-foreground" dir="rtl">
                  <Loader2 className="inline size-3 animate-spin" /> جارٍ التحقق من رسوم شحن الإرجاع المعتمدة لهذه المنطقة...
                </p>
              )}
              {direction === "return" && feePreviewStatus === "found" && feeSuggested && (
                <p className="text-xs text-muted-foreground">القيمة المقترحة لهذه المنطقة: {feeSuggested} ر.س (قابلة للتعديل)</p>
              )}
              {/* Hotfix 5.1.3 items 1/2/3 — a genuine preview FAILURE (the
                  Server Action returned success:false, or the call threw)
                  gets its own distinct message and an explicit Retry
                  action — never the "لا يوجد تسعير معتمد" no-config
                  wording, and never enough on its own to unlock submit
                  (see returnFeePreviewBlocking / canSubmit above). */}
              {direction === "return" && feePreviewStatus === "error" && (
                <div className="flex flex-col items-start gap-1" dir="rtl">
                  <p className="text-xs text-destructive">{feePreviewErrorMessage ?? FEE_PREVIEW_ERROR_MESSAGE_AR}</p>
                  {/* Deliberately NOT gated on `isPending` — that flag is
                      shared (via the single useTransition() above) with
                      the unrelated carrier/cost preview effect and the
                      form-submit transition, neither of which has any
                      bearing on whether a NEW return-fee preview fetch is
                      safe to start. The button itself disappears from the
                      DOM the instant a retry is clicked (feePreviewStatus
                      flips to "loading", replacing this whole block), so
                      a double-click is already structurally prevented. */}
                  <Button
                    type="button"
                    variant="link"
                    size="sm"
                    className="h-auto p-0 text-xs"
                    onClick={() => fetchFeePreview(currentFeePreviewKey, shippingZoneId, shipmentDate)}
                  >
                    إعادة التحقق
                  </Button>
                </div>
              )}
            </div>

            <div className="flex flex-col gap-1.5">
              <Label>التكلفة المتوقعة لشركة الشحن</Label>
              {!rateChecked && <p className="pt-2 text-sm text-muted-foreground">اختر شركة الشحن والمنطقة والتاريخ لعرض التسعير...</p>}
              {rateChecked && rateFound === true && <p className="pt-2 text-sm font-medium text-success" dir="ltr">✓ تم إيجاد تسعير معتمد (يُحسب تلقائيًا عند الحفظ)</p>}
              {rateChecked && rateFound === false && <p className="pt-2 text-sm text-warning">لا يوجد تسعير معتمد لهذا المسار — أدخل التكلفة يدويًا أدناه.</p>}
            </div>
          </div>

          {requiresManualCost && (
            <div className="grid grid-cols-1 gap-4 rounded-lg border border-warning/40 bg-warning/5 p-4 sm:grid-cols-2">
              <div className="flex flex-col gap-1.5">
                <Label>التكلفة المتوقعة اليدوية</Label>
                <Input dir="ltr" inputMode="decimal" value={manualExpectedCost} onChange={(e) => setManualExpectedCost(e.target.value)} disabled={isPending} />
              </div>
              <div className="flex flex-col gap-1.5">
                <Label>سبب الإدخال اليدوي</Label>
                <Input value={manualExpectedCostReason} onChange={(e) => setManualExpectedCostReason(e.target.value)} disabled={isPending} />
              </div>
            </div>
          )}

          {/* Hotfix 5.1.1 item 1 — mandatory reason whenever the submitted
              return-shipping fee diverges from the current standard
              suggestion (or none exists at all for this zone/date), always
              in sync with the live feeSuggested above (item 3, Preview/
              Create parity) — required client-side here purely for a good
              round-trip UX; create_shipment() (0125) independently enforces
              the same rule as the real authority. */}
          {returnFeeIsOverride && (
            <div className="flex flex-col gap-1.5 rounded-lg border border-warning/40 bg-warning/5 p-4">
              <Label>سبب تجاوز رسوم شحن الإرجاع القياسية</Label>
              <p className="text-xs text-muted-foreground">
                {feeSuggested
                  ? `القيمة القياسية لهذه المنطقة ${feeSuggested} ر.س، والقيمة المُدخَلة تختلف عنها — يجب توضيح السبب.`
                  : "لا يوجد تسعير معتمد لرسوم شحن الإرجاع لهذه المنطقة/التاريخ — الإدخال يدوي بالكامل ويُعد تجاوزًا يتطلب سببًا."}
              </p>
              <Textarea value={returnFeeOverrideReason} onChange={(e) => setReturnFeeOverrideReason(e.target.value)} disabled={isPending} rows={2} />
            </div>
          )}

          <div className="flex items-center gap-3 rounded-lg border border-border p-4">
            <Switch checked={isCod} onCheckedChange={setIsCod} disabled={isPending} />
            <div className="flex flex-1 flex-col">
              <span className="text-sm font-medium">الدفع عند الاستلام (COD)</span>
              <span className="text-xs text-muted-foreground">تشغيلي فقط في هذه المرحلة — بدون تسويات/عمولات (تُضاف لاحقًا في مرحلة التسويات).</span>
            </div>
            {isCod && (
              <Input
                dir="ltr"
                inputMode="decimal"
                placeholder="المبلغ المتوقع"
                className="w-40"
                value={codExpectedAmount}
                onChange={(e) => setCodExpectedAmount(e.target.value)}
                disabled={isPending}
              />
            )}
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>ملاحظات (اختياري)</Label>
            <Textarea value={notes} onChange={(e) => setNotes(e.target.value)} disabled={isPending} rows={2} />
          </div>
        </CardContent>
      </Card>

      {existingReturn && (
        <p className="text-xs text-muted-foreground">تاريخ المرتجع: {formatRiyadhDate(existingReturn.return_date)} — الحالة: {existingReturn.status}</p>
      )}

      <div className="flex flex-col items-end gap-1">
        {/* Hotfix 5.1.2 item 2 / Hotfix 5.1.3 item 4 — explicit reason
            submit is blocked whenever returnFeePreviewBlocking is true:
            a new zone/date's preview still in flight, a genuine failure,
            or a resolved answer left over from a now-superseded zone/date
            — so the actor isn't left guessing why the button is greyed
            out. */}
        {returnFeePreviewBlocking && (
          <p className="text-xs text-muted-foreground" dir="rtl">
            {returnFeePreviewLoading
              ? "بانتظار نتيجة التحقق من رسوم شحن الإرجاع قبل السماح بالحفظ..."
              : returnFeePreviewError
                ? "تعذر التحقق من رسوم شحن الإرجاع — أعد المحاولة قبل إنشاء الشحنة."
                : "بانتظار التحقق من رسوم شحن الإرجاع لهذه المنطقة/التاريخ قبل السماح بالحفظ..."}
          </p>
        )}
        <Button type="submit" variant="accent" size="lg" disabled={isPending || !canSubmit}>
          {isPending && <Loader2 className="size-4 animate-spin" />}
          إنشاء الشحنة
        </Button>
      </div>

      <ClosedDayReasonDialog
        open={pendingCloseReason}
        onOpenChange={setPendingCloseReason}
        isPending={isPending}
        onConfirm={(reason) => {
          setClosedDayReason(reason);
          submit(reason);
        }}
      />
    </form>
  );
}
