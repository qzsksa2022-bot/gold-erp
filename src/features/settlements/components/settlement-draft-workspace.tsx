"use client";

import { useMemo, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { AlertTriangle, CheckCircle2, Loader2, RefreshCw, Save } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Checkbox } from "@/components/ui/checkbox";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Badge } from "@/components/ui/badge";
import { Can } from "@/lib/permissions/context";
import { ClosedDayReasonDialog } from "@/features/sales/components/closed-day-reason-dialog";
import { formatRiyadhDate } from "@/lib/date";
import { cn } from "@/lib/utils";
import { updateDraftSettlementBatchAction, finalizeSettlementBatchAction, listUnsettledSettlementSourcesAction, previewSettlementBatchAction, type UnsettledSourceRow, type SettlementBatchPreview } from "../actions";
import { isClosedDayError, SOURCE_KIND_LABELS_AR } from "../schema";

type RouteLookup = { id: string; code: string; name_ar: string; route_kind: string };
type StoreLookup = { id: string; code: string; name_ar: string };

type DraftBatch = {
  id: string;
  settlement_number: string;
  settlement_route_id: string;
  route_kind: string;
  settlement_date: string;
  provider_statement_reference: string | null;
  notes: string | null;
  row_version: number;
};

function sourceKey(s: { source_kind: string; source_event_id: string }) {
  return `${s.source_kind}::${s.source_event_id}`;
}

/**
 * Patch 7.1 §16 — the Preview Key / freshness state machine. A preview is
 * only ever trustworthy for the exact combination of inputs it was computed
 * from; this component tracks that combination as one opaque string (the
 * "preview key", see `previewKey` below) and compares it against the key the
 * last SUCCESSFUL preview was computed for (`previewResult.key`) on every
 * render — no effect needed, since a mismatch is a pure derivation of
 * current props/state and React already re-renders on every state change
 * that could move the key.
 *
 * "idle" = never previewed (or selection cleared back to empty). "loading" =
 * a preview RPC is in flight — Finalize is disabled here too, since the
 * in-flight result might not even match the CURRENT key by the time it
 * lands. "valid" = the last successful preview's key equals the current
 * key. "stale" = a successful preview exists but for a DIFFERENT key (route/
 * date/range/selection/override changed since). "error" = the last preview
 * attempt failed.
 */
type PreviewStatus = "idle" | "loading" | "valid" | "stale" | "error";

/**
 * The entire draft-batch workspace on /settlements/[id] while status =
 * 'draft' — draft-header edit (update_draft_settlement_batch, 0177), source
 * discovery + selection (list_unsettled_settlement_sources, 0176), live
 * preview (preview_settlement_batch, 0176 — DISPLAY-ONLY, never
 * authoritative), and Finalization (finalize_settlement_batch, 0178). Mirrors
 * AdjustmentEntryForm's create/preview/submit shape, extended for a
 * multi-source selection step instead of a single order.
 */
export function SettlementDraftWorkspace({ batch, routes, stores }: { batch: DraftBatch; routes: RouteLookup[]; stores: StoreLookup[] }) {
  const router = useRouter();

  // Draft header (editable while draft).
  const [routeId, setRouteId] = useState(batch.settlement_route_id);
  const [settlementDate, setSettlementDate] = useState(batch.settlement_date);
  const [reference, setReference] = useState(batch.provider_statement_reference ?? "");
  const [notes, setNotes] = useState(batch.notes ?? "");
  const [rowVersion, setRowVersion] = useState(batch.row_version);
  const [isHeaderPending, startHeaderTransition] = useTransition();

  // Hotfix 7.1.1 §10 (CRITICAL) — persistedRouteId/persistedSettlementDate
  // track what is ACTUALLY saved in settlement_batches right now, distinct
  // from routeId/settlementDate (the live, possibly-unsaved form fields).
  // Source discovery/Preview/Finalize must never operate against a route/
  // date the user has typed into the form but never saved — finalize_
  // settlement_batch() (0185) always re-resolves from the PERSISTED row,
  // so an unsaved local date change could preview against one Fee Version/
  // chronology and finalize against a completely different one. Both are
  // seeded from the batch prop (the persisted truth at initial load) and
  // are updated ONLY inside saveHeader()'s success path below — never by
  // typing in the form.
  const [persistedRouteId, setPersistedRouteId] = useState(batch.settlement_route_id);
  const [persistedSettlementDate, setPersistedSettlementDate] = useState(batch.settlement_date);
  const isHeaderDirty = routeId !== persistedRouteId || settlementDate !== persistedSettlementDate;

  function saveHeader() {
    startHeaderTransition(async () => {
      const result = await updateDraftSettlementBatchAction({
        id: batch.id,
        row_version: rowVersion,
        settlement_route_id: routeId,
        settlement_date: settlementDate,
        provider_statement_reference: reference || undefined,
        notes: notes || undefined,
      });
      if (result.success) {
        toast.success(result.message ?? "تم حفظ بيانات المسودة");
        setRowVersion(result.data.row_version);
        // §10 — the header is no longer dirty against what was just saved;
        // any source selection/preview computed against the PREVIOUS
        // persisted route/date is no longer trustworthy against the new
        // one, so it is explicitly reset here rather than left to look
        // valid by coincidence.
        setPersistedRouteId(routeId);
        setPersistedSettlementDate(settlementDate);
        setSources(null);
        setSelected(new Map());
        setPreviewResult(null);
        setPreviewError(null);
        router.refresh();
      } else {
        toast.error(result.error);
      }
    });
  }

  // Source discovery.
  const [sourceDateFrom, setSourceDateFrom] = useState(batch.settlement_date);
  const [sourceDateTo, setSourceDateTo] = useState(batch.settlement_date);
  const [storeId, setStoreId] = useState("");
  const [search, setSearch] = useState("");
  const [sources, setSources] = useState<UnsettledSourceRow[] | null>(null);
  const [isSourcesPending, startSourcesTransition] = useTransition();
  const [selected, setSelected] = useState<Map<string, UnsettledSourceRow>>(new Map());

  function loadSources() {
    // Hotfix 7.1.1 §10 — never discover sources against an unsaved header
    // change (routeId here would not match the batch's PERSISTED route).
    if (isHeaderDirty) return;
    startSourcesTransition(async () => {
      const result = await listUnsettledSettlementSourcesAction({
        settlementRouteId: routeId,
        sourceDateFrom,
        sourceDateTo,
        storeId: storeId || undefined,
        search: search || undefined,
      });
      if (result.success) {
        setSources(result.data);
      } else {
        toast.error(result.error);
        setSources([]);
      }
    });
  }

  function toggleSource(row: UnsettledSourceRow) {
    setSelected((prev) => {
      const next = new Map(prev);
      const key = sourceKey(row);
      if (next.has(key)) next.delete(key);
      else next.set(key, row);
      return next;
    });
  }

  const selectedTokens = useMemo(() => Array.from(selected.values()).map((s) => ({ source_kind: s.source_kind, source_event_id: s.source_event_id })), [selected]);

  // Batch-fee override — lifted up from FinalizeDialog (Patch 7.1 §16) so it
  // can participate in the Preview Key below: what the user is about to
  // FINALIZE includes these fields, so a change here must be able to flip
  // the preview to "stale" exactly like changing the route or the date range
  // does, even though the fields themselves are only edited inside the
  // Finalize dialog.
  const [overrideEnabled, setOverrideEnabled] = useState(false);
  const [overrideAmount, setOverrideAmount] = useState("");
  const [overrideReason, setOverrideReason] = useState("");

  // Preview (display-only — never authoritative, item 22).
  //
  // previewResult holds BOTH the last successful preview's data AND the
  // exact key it was computed for (§16, point 3) — never just the data.
  // previewError holds the last failed attempt's message. previewKey is the
  // key for the CURRENT inputs, recomputed every render; previewStatus below
  // compares the two to decide idle/valid/stale/error/loading. There is no
  // separate "last successful preview key" piece of state distinct from
  // previewResult.key — keeping them as one atomic value rules out a bug
  // where the two get set from different renders/requests out of sync.
  const [previewResult, setPreviewResult] = useState<{ data: SettlementBatchPreview; key: string } | null>(null);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [isPreviewPending, startPreviewTransition] = useTransition();

  // Preview Key (Patch 7.1 §16) — routeId, settlementDate, sourceDateFrom,
  // sourceDateTo, the selected source tokens sorted deterministically (by
  // source_kind then source_event_id, so selection ORDER never matters, only
  // MEMBERSHIP), and the batch-fee-override state/value.
  //
  // On the override piece: previewSettlementBatchAction/preview_settlement_
  // batch() (Hotfix 7.1.1 §9, migration 0195) NOW accepts the same
  // batch-fee-override pair finalize_settlement_batch() always has — the
  // effective_batch_fee/expected_bank_settlement it returns DO reflect a
  // pending override (Preview/Finalize parity), so toggling/editing these
  // fields both flips the preview to "stale" (below) AND actually changes
  // what the next successful preview will show.
  const previewKey = useMemo(() => {
    const tokenPart = [...selectedTokens]
      .sort((a, b) => (a.source_kind === b.source_kind ? a.source_event_id.localeCompare(b.source_event_id) : a.source_kind.localeCompare(b.source_kind)))
      .map((t) => `${t.source_kind}:${t.source_event_id}`)
      .join(",");
    const overridePart = overrideEnabled ? `on|${overrideAmount.trim()}|${overrideReason.trim()}` : "off";
    return JSON.stringify({ routeId, settlementDate, sourceDateFrom, sourceDateTo, tokenPart, overridePart });
  }, [routeId, settlementDate, sourceDateFrom, sourceDateTo, selectedTokens, overrideEnabled, overrideAmount, overrideReason]);

  const previewStatus: PreviewStatus = isPreviewPending
    ? "loading"
    : previewError
      ? "error"
      : previewResult
        ? previewResult.key === previewKey
          ? "valid"
          : "stale"
        : "idle";

  // Finalize gating (§16, point 5; Hotfix 7.1.1 §10 adds !isHeaderDirty).
  // Patch 7.1 §15 made preview_settlement_batch() REJECT the whole call (an
  // error, not a partial result) when any selected token is stale/invalid —
  // so "all selected sources matched" is now implied by the preview call
  // having succeeded at all, i.e. by previewStatus === "valid".
  // SettlementBatchPreview (../actions.ts) also carries no separate
  // matched-count field to check. §10 (CRITICAL): a dirty header (routeId/
  // settlementDate typed but not yet saved) must NEVER allow Finalize —
  // finalize_settlement_batch() always re-resolves against the PERSISTED
  // route/date, which could differ from whatever Preview last showed for
  // the UNSAVED local values, breaking Preview/Finalize parity at its root.
  // Finalize itself stays DB-authoritative regardless of any of this — this
  // gate is purely about giving the user honest UI feedback before they
  // submit.
  const canFinalize = !isHeaderDirty && previewStatus === "valid" && previewResult !== null && previewResult.data.fee_version_resolved === true;

  function runPreview() {
    // §10 — never preview against an unsaved header change.
    if (isHeaderDirty) return;
    if (selectedTokens.length === 0) {
      setPreviewResult(null);
      setPreviewError(null);
      return;
    }
    // Captured now, not after the await — if the user changes route/date/
    // selection/override while this request is in flight, the RESPONSE still
    // corresponds to the key that was actually sent, not to whatever the
    // fields have drifted to by the time it resolves.
    const keyAtRequest = previewKey;
    setPreviewError(null);
    startPreviewTransition(async () => {
      const result = await previewSettlementBatchAction({
        settlementRouteId: routeId,
        sourceDateFrom,
        sourceDateTo,
        selectedSources: selectedTokens,
        settlementDate,
        batchFeeOverride: overrideEnabled ? overrideAmount.trim() || undefined : undefined,
        overrideReason: overrideEnabled ? overrideReason.trim() || undefined : undefined,
      });
      if (result.success) {
        setPreviewResult({ data: result.data, key: keyAtRequest });
        setPreviewError(null);
      } else {
        setPreviewResult(null);
        setPreviewError(result.error);
        toast.error(result.error);
      }
    });
  }

  return (
    <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
      <div className="flex flex-col gap-4 lg:col-span-2">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">بيانات المسودة</CardTitle>
          </CardHeader>
          <CardContent className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div className="flex flex-col gap-1.5">
              <Label>مسار التسوية</Label>
              <Select value={routeId} onValueChange={setRouteId} disabled={isHeaderPending}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {routes.map((r) => (
                    <SelectItem key={r.id} value={r.id}>
                      {r.name_ar}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="flex flex-col gap-1.5">
              <Label>تاريخ التسوية</Label>
              <Input type="date" dir="ltr" value={settlementDate} onChange={(e) => setSettlementDate(e.target.value)} disabled={isHeaderPending} />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label>مرجع كشف مزوّد الدفع/الناقل (اختياري)</Label>
              <Input dir="ltr" value={reference} onChange={(e) => setReference(e.target.value)} disabled={isHeaderPending} maxLength={200} />
            </div>
            <div className="flex flex-col gap-1.5 sm:col-span-2">
              <Label>ملاحظات (اختياري)</Label>
              <Textarea value={notes} onChange={(e) => setNotes(e.target.value)} disabled={isHeaderPending} rows={2} />
            </div>
            <div className="sm:col-span-2 flex flex-col gap-2">
              <Button variant="outline" size="sm" onClick={saveHeader} disabled={isHeaderPending} className="w-fit">
                {isHeaderPending ? <Loader2 className="size-4 animate-spin" /> : <Save className="size-4" />}
                حفظ بيانات المسودة
              </Button>
              {/* Hotfix 7.1.1 §10 — the header is dirty (mesar/date typed but
                  not yet saved): make this unmistakable, since discovery/
                  preview/finalize are all disabled below until saved. */}
              {isHeaderDirty && (
                <p className="flex items-center gap-1.5 text-xs text-warning">
                  <AlertTriangle className="size-3.5 shrink-0" />
                  احفظ بيانات المسودة أولًا — تغييرات المسار/التاريخ لم تُحفظ بعد، ولا يمكن اكتشاف المصادر أو المعاينة أو الاعتماد حتى يتم الحفظ.
                </p>
              )}
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-base">اختيار المصادر غير المسوّاة</CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col gap-4">
            <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
              <div className="flex flex-col gap-1.5">
                <Label>من تاريخ</Label>
                <Input type="date" dir="ltr" value={sourceDateFrom} onChange={(e) => setSourceDateFrom(e.target.value)} disabled={isHeaderDirty} />
              </div>
              <div className="flex flex-col gap-1.5">
                <Label>إلى تاريخ</Label>
                <Input type="date" dir="ltr" value={sourceDateTo} onChange={(e) => setSourceDateTo(e.target.value)} disabled={isHeaderDirty} />
              </div>
              <div className="flex flex-col gap-1.5">
                <Label>المتجر (اختياري)</Label>
                <Select value={storeId || "all"} onValueChange={(v) => setStoreId(v === "all" ? "" : v)} disabled={isHeaderDirty}>
                  <SelectTrigger>
                    <SelectValue placeholder="كل المتاجر" />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="all">كل المتاجر</SelectItem>
                    {stores.map((s) => (
                      <SelectItem key={s.id} value={s.id}>
                        {s.name_ar}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <div className="flex flex-col gap-1.5">
                <Label>بحث برقم المصدر</Label>
                <Input
                  dir="ltr"
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                  onKeyDown={(e) => e.key === "Enter" && loadSources()}
                  disabled={isHeaderDirty}
                />
              </div>
            </div>

            <Button type="button" variant="outline" onClick={loadSources} disabled={isSourcesPending || isHeaderDirty}>
              {isSourcesPending ? <Loader2 className="size-4 animate-spin" /> : <RefreshCw className="size-4" />}
              تحميل المصادر غير المسوّاة
            </Button>

            {isHeaderDirty && <p className="text-xs text-warning">احفظ بيانات المسودة أولًا لتتمكن من اكتشاف المصادر.</p>}

            {!isHeaderDirty && sources && sources.length === 0 && <p className="text-sm text-muted-foreground">لا توجد مصادر غير مسوّاة مطابقة لهذا النطاق.</p>}

            {!isHeaderDirty && sources && sources.length > 0 && (
              <div className="flex flex-col divide-y divide-border rounded-lg border border-border">
                {sources.map((s) => {
                  const key = sourceKey(s);
                  const isChecked = selected.has(key);
                  return (
                    <label key={key} className="flex cursor-pointer items-center justify-between gap-3 px-3 py-2 text-sm hover:bg-muted/40">
                      <div className="flex items-center gap-3">
                        <Checkbox checked={isChecked} onCheckedChange={() => toggleSource(s)} />
                        <div className="flex flex-col gap-0.5">
                          <span className="flex items-center gap-2">
                            {s.source_label}
                            <Badge variant="outline">{SOURCE_KIND_LABELS_AR[s.source_kind] ?? s.source_kind}</Badge>
                          </span>
                          <span className="text-xs text-muted-foreground">
                            {formatRiyadhDate(s.source_business_date)} — {s.store_display}
                          </span>
                        </div>
                      </div>
                      <span className="font-mono text-xs" dir="ltr">
                        {s.expected_settlement_impact}
                      </span>
                    </label>
                  );
                })}
              </div>
            )}
          </CardContent>
        </Card>
      </div>

      <div className="flex flex-col gap-4">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">المصادر المختارة ({selected.size})</CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col gap-3">
            <Button type="button" variant="outline" onClick={runPreview} disabled={isPreviewPending || selected.size === 0 || isHeaderDirty}>
              {isPreviewPending && <Loader2 className="size-4 animate-spin" />}
              تحديث المعاينة
            </Button>

            {isHeaderDirty && (
              <p className="flex items-start gap-1.5 text-xs text-warning">
                <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
                احفظ بيانات المسودة أولًا — لا يمكن المعاينة أو الاعتماد حتى يتم حفظ تغييرات المسار/التاريخ.
              </p>
            )}

            {!isHeaderDirty && previewStatus === "idle" && <p className="text-xs text-muted-foreground">لم تُجرَ معاينة بعد — اختر مصدرًا واحدًا على الأقل ثم اضغط تحديث المعاينة.</p>}

            {previewStatus === "error" && previewError && (
              <p className="flex items-start gap-1.5 text-xs text-destructive">
                <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
                {previewError}
              </p>
            )}

            {previewStatus === "stale" && (
              <div className="flex items-start gap-2 rounded-md border border-warning/40 bg-warning/10 p-2">
                <AlertTriangle className="mt-0.5 size-3.5 shrink-0 text-warning" />
                <p className="text-xs text-warning">المعاينة قديمة — التغييرات الحالية لم تُعاين بعد، حدّث المعاينة قبل الاعتماد.</p>
              </div>
            )}

            {previewStatus === "valid" && (
              <Badge variant="success" className="w-fit">
                <CheckCircle2 className="size-3" />
                محدّثة
              </Badge>
            )}

            {(previewStatus === "valid" || previewStatus === "stale") && previewResult && (
              <div className={cn("flex flex-col gap-2 text-sm", previewStatus === "stale" && "text-muted-foreground opacity-60")}>
                {!previewResult.data.fee_version_resolved && <p className="text-xs text-warning">لا يوجد إصدار رسوم معتمد لهذا المسار في تاريخ التسوية — سيُرفض الاعتماد.</p>}
                <Row label="إجمالي المصادر (إجمالي)" value={previewResult.data.gross_source_impact} />
                <Row label="عمولة المزوّد/الناقل" value={previewResult.data.provider_fee_impact} />
                <Row label="المتوقع قبل رسوم الدفعة" value={previewResult.data.expected_before_batch_fee} />
                {previewResult.data.batch_fee_overridden ? (
                  <>
                    <Row label="رسوم الدفعة (الافتراضية)" value={previewResult.data.configured_batch_fee} />
                    <Row label="رسوم الدفعة (بعد التجاوز)" value={previewResult.data.effective_batch_fee} />
                    <p className="text-xs text-warning">تم تجاوز رسوم الدفعة الافتراضية — القيمة أعلاه هي المستخدمة فعليًا في هذه المعاينة.</p>
                  </>
                ) : (
                  <Row label="رسوم الدفعة" value={previewResult.data.effective_batch_fee} />
                )}
                <Row label="المتوقع بنكيًا (نهائي)" value={previewResult.data.expected_bank_settlement} emphasize />
                <p className="mt-1 text-xs text-muted-foreground">معاينة تقديرية فقط — يعيد النظام حل كل شيء نهائيًا عند الاعتماد.</p>
              </div>
            )}
          </CardContent>
        </Card>

        <Can permission="settlements.finalize">
          <FinalizeDialog
            batchId={batch.id}
            rowVersion={rowVersion}
            settlementNumber={batch.settlement_number}
            selectedTokens={selectedTokens}
            canFinalize={canFinalize}
            previewStatus={previewStatus}
            overrideEnabled={overrideEnabled}
            setOverrideEnabled={setOverrideEnabled}
            overrideAmount={overrideAmount}
            setOverrideAmount={setOverrideAmount}
            overrideReason={overrideReason}
            setOverrideReason={setOverrideReason}
          />
        </Can>
      </div>
    </div>
  );
}

function FinalizeDialog({
  batchId,
  rowVersion,
  settlementNumber,
  selectedTokens,
  canFinalize,
  previewStatus,
  overrideEnabled,
  setOverrideEnabled,
  overrideAmount,
  setOverrideAmount,
  overrideReason,
  setOverrideReason,
}: {
  batchId: string;
  rowVersion: number;
  settlementNumber: string;
  selectedTokens: { source_kind: string; source_event_id: string }[];
  canFinalize: boolean;
  previewStatus: PreviewStatus;
  overrideEnabled: boolean;
  setOverrideEnabled: (value: boolean) => void;
  overrideAmount: string;
  setOverrideAmount: (value: string) => void;
  overrideReason: string;
  setOverrideReason: (value: string) => void;
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [pendingCloseReason, setPendingCloseReason] = useState(false);
  const [isPending, startTransition] = useTransition();

  function submit(closedDayReason?: string) {
    startTransition(async () => {
      const result = await finalizeSettlementBatchAction({
        id: batchId,
        row_version: rowVersion,
        selected_sources: selectedTokens,
        // Hotfix 7.1.1 §9/§13 — trimmed identically to runPreview()'s own
        // batchFeeOverride/overrideReason above: previously this branch sent
        // the RAW (untrimmed) field values while Preview trimmed first, so a
        // value with incidental leading/trailing whitespace could reach
        // finalize_settlement_batch() as a DIFFERENT string than the one
        // preview_settlement_batch() had just shown/validated — breaking
        // Preview/Finalize byte-identical parity for no reason tied to the
        // user's actual input.
        batch_fee_override: overrideEnabled ? overrideAmount.trim() || undefined : undefined,
        override_reason: overrideEnabled ? overrideReason.trim() || undefined : undefined,
        closed_day_reason: closedDayReason,
      });

      if (result.success) {
        toast.success(result.message ?? `تم اعتماد دفعة التسوية رقم ${result.data.settlement_number}`);
        setOpen(false);
        setPendingCloseReason(false);
        router.refresh();
        return;
      }

      if (!closedDayReason && isClosedDayError(result.error)) {
        setPendingCloseReason(true);
        return;
      }

      toast.error(result.error);
    });
  }

  // §16, point 5 — the trigger is disabled unless state === "valid" (current
  // key === last successful preview key) AND fee_version_resolved === true
  // (folded into canFinalize by the parent). The Confirm button inside the
  // dialog repeats the SAME check as a second, independent guard — so even
  // if the dialog was opened while canFinalize was true and the user then
  // edits the override fields (which are part of the preview key) WHILE the
  // dialog is open, previewStatus flips to "stale" on the very next render,
  // canFinalize follows it to false, and this button disables itself without
  // needing the dialog to close/reopen.
  const isSubmitDisabled = isPending || !canFinalize || (overrideEnabled && (!overrideAmount.trim() || !overrideReason.trim()));

  return (
    <>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogTrigger asChild>
          <Button variant="accent" size="lg" disabled={!canFinalize}>
            <CheckCircle2 className="size-4" />
            اعتماد الدفعة
          </Button>
        </DialogTrigger>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>اعتماد دفعة التسوية {settlementNumber}</DialogTitle>
            <DialogDescription>
              سيعيد النظام حل كل مصدر مختار ورسومه من بيانات النظام الحالية نهائيًا عند الاعتماد — لا يُعتمد على قيم المعاينة. سيتم حجز كل مصدر مختار لهذه الدفعة ولن يظهر لدفعة أخرى.
            </DialogDescription>
          </DialogHeader>

          {previewStatus !== "valid" && (
            <div className="flex items-start gap-2 rounded-md border border-warning/40 bg-warning/10 p-3">
              <AlertTriangle className="mt-0.5 size-4 shrink-0 text-warning" />
              <p className="text-xs text-warning">
                {previewStatus === "stale"
                  ? "المعاينة قديمة — التغييرات الحالية لم تُعاين بعد. أغلق هذا الحوار وحدّث المعاينة قبل الاعتماد."
                  : previewStatus === "loading"
                    ? "جارٍ تحديث المعاينة…"
                    : previewStatus === "error"
                      ? "فشلت آخر محاولة معاينة — لا يمكن الاعتماد قبل معاينة ناجحة."
                      : "يجب إجراء معاينة ناجحة قبل الاعتماد."}
              </p>
            </div>
          )}

          <Can permission="settlements.override_batch_fee">
            <div className="flex flex-col gap-2 rounded-md border border-border p-3">
              <label className="flex items-center gap-2 text-sm">
                <Checkbox checked={overrideEnabled} onCheckedChange={(v) => setOverrideEnabled(v === true)} disabled={isPending} />
                تجاوز رسوم الدفعة الافتراضية
              </label>
              {overrideEnabled && (
                <>
                  <div className="flex flex-col gap-1.5">
                    <Label>رسوم الدفعة (تجاوز)</Label>
                    <Input type="number" step="0.01" min="0" dir="ltr" value={overrideAmount} onChange={(e) => setOverrideAmount(e.target.value)} disabled={isPending} />
                  </div>
                  <div className="flex flex-col gap-1.5">
                    <Label>سبب التجاوز</Label>
                    <Textarea value={overrideReason} onChange={(e) => setOverrideReason(e.target.value)} disabled={isPending} rows={2} />
                  </div>
                </>
              )}
            </div>
          </Can>

          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
              إلغاء
            </Button>
            <Button variant="accent" onClick={() => submit()} disabled={isSubmitDisabled}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              تأكيد الاعتماد
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <ClosedDayReasonDialog open={pendingCloseReason} onOpenChange={setPendingCloseReason} isPending={isPending} onConfirm={(reason) => submit(reason)} />
    </>
  );
}

function Row({ label, value, emphasize }: { label: string; value: string; emphasize?: boolean }) {
  return (
    <div className="flex items-center justify-between gap-2">
      <span className="text-muted-foreground">{label}</span>
      <span className={emphasize ? "font-bold" : "font-medium"} dir="ltr">
        {value}
      </span>
    </div>
  );
}
