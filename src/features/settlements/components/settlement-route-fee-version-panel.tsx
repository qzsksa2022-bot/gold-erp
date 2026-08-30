"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Plus, XCircle } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Badge } from "@/components/ui/badge";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { ConfirmDialog } from "@/components/shared/confirm-dialog";
import { formatRiyadhDate, riyadhTodayIsoDate } from "@/lib/date";
import { createSettlementRouteFeeVersionAction, cancelSettlementRouteFeeVersionAction } from "../actions";
import {
  TRANSACTION_FEE_STRATEGIES,
  TRANSACTION_FEE_STRATEGY_LABELS_AR,
  TRANSACTION_FEE_MODELS,
  TRANSACTION_FEE_MODEL_LABELS_AR,
  COD_FEE_REVERSAL_POLICIES,
  COD_FEE_REVERSAL_POLICY_LABELS_AR,
} from "../schema";

/**
 * Shape returned by list_settlement_route_fee_versions_for_management()
 * (Patch 7.1 §23, migration 0190) — money figures arrive as TEXT (the RPC
 * casts them ::text), unlike the raw-table-read this used to be (which
 * returned real `numeric` columns as JS `number`).
 */
type FeeVersion = {
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
};

/** Fee-version history + create/cancel panel for one Settlement Route on /master-data/settlement-routes (items 11/12). */
export function SettlementRouteFeeVersionPanel({ routeId, routeKind, versions }: { routeId: string; routeKind: string; versions: FeeVersion[] }) {
  const router = useRouter();
  const today = riyadhTodayIsoDate();

  return (
    <div className="flex flex-col gap-2">
      {versions.length === 0 ? (
        <p className="text-xs text-muted-foreground">لا يوجد أي إصدار رسوم لهذا المسار بعد — لا يمكن اعتماد أي دفعة تسوية عليه قبل إضافة إصدار.</p>
      ) : (
        <div className="flex flex-col divide-y divide-border rounded-md border border-border">
          {versions.map((v) => {
            const isFuture = v.effective_from > today;
            return (
              <div key={v.id} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2 text-xs">
                <div className="flex flex-col gap-0.5">
                  <span className="font-mono" dir="ltr">
                    {formatRiyadhDate(v.effective_from)} {v.effective_to ? `— ${formatRiyadhDate(v.effective_to)}` : "— مستمر"}
                  </span>
                  <span className="text-muted-foreground">
                    {TRANSACTION_FEE_STRATEGY_LABELS_AR[v.transaction_fee_strategy as keyof typeof TRANSACTION_FEE_STRATEGY_LABELS_AR] ?? v.transaction_fee_strategy}
                    {v.transaction_fee_strategy === "route_formula" && v.transaction_fee_model && ` — ${TRANSACTION_FEE_MODEL_LABELS_AR[v.transaction_fee_model as keyof typeof TRANSACTION_FEE_MODEL_LABELS_AR] ?? v.transaction_fee_model}`}
                    {v.percentage_fee !== null && ` — ${v.percentage_fee}%`}
                    {v.fixed_fee !== null && ` — ${v.fixed_fee} ر.س`}
                    {` — رسوم دفعة: ${v.batch_fee_fixed} ر.س`}
                  </span>
                </div>
                <div className="flex items-center gap-2">
                  <Badge variant={v.status === "active" ? (isFuture ? "warning" : "success") : "secondary"}>{isFuture ? "مجدوَل" : v.status === "active" ? "ساري" : "منتهٍ"}</Badge>
                  {isFuture && v.status === "active" && <CancelFeeVersionButton versionId={v.id} onDone={() => router.refresh()} />}
                </div>
              </div>
            );
          })}
        </div>
      )}

      <CreateFeeVersionDialog routeId={routeId} routeKind={routeKind} onCreated={() => router.refresh()} />
    </div>
  );
}

function CancelFeeVersionButton({ versionId, onDone }: { versionId: string; onDone: () => void }) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <Button variant="ghost" size="icon" onClick={() => setOpen(true)} aria-label="إلغاء إصدار الرسوم المجدوَل">
        <XCircle className="size-4 text-destructive" />
      </Button>
      <ConfirmDialog
        open={open}
        onOpenChange={setOpen}
        title="إلغاء إصدار الرسوم المجدوَل؟"
        description="لا يمكن إلغاء إلا إصدار رسوم مستقبلي لم يسرِ بعد. إذا كان هناك إصدار سابق منتهٍ، سيُعاد فتحه تلقائيًا."
        confirmLabel="إلغاء الإصدار"
        destructive
        onConfirm={async () => {
          const result = await cancelSettlementRouteFeeVersionAction(versionId);
          if (result.success) {
            toast.success(result.message);
            onDone();
          } else {
            toast.error(result.error);
          }
        }}
      />
    </>
  );
}

function CreateFeeVersionDialog({ routeId, routeKind, onCreated }: { routeId: string; routeKind: string; onCreated: () => void }) {
  const [open, setOpen] = useState(false);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();
  // Hotfix 7.1.1 §14 — source_snapshot has no meaning for a COD-carrier
  // route (there is no source-level fee snapshot on a COD event), and the
  // DB already rejects it hard (create_settlement_route_fee_version(),
  // migration 0190) — but that must not be the ONLY place this is caught.
  // The default strategy is chosen per routeKind so a COD-carrier panel
  // never even starts on the invalid option.
  const [strategy, setStrategy] = useState<string>(routeKind === "cod_carrier" ? "route_formula" : "source_snapshot");
  // Same §14 requirement, applied to the strategy picker itself: the
  // invalid option is removed from the list entirely for a COD-carrier
  // route, not merely flagged with a warning after the fact — matching the
  // Zod-level rejection added to createSettlementRouteFeeVersionSchema's
  // superRefine (schema.ts).
  const availableStrategies = routeKind === "cod_carrier" ? TRANSACTION_FEE_STRATEGIES.filter((s) => s !== "source_snapshot") : TRANSACTION_FEE_STRATEGIES;
  const [model, setModel] = useState<string>("");
  const [codPolicy, setCodPolicy] = useState<string>("");

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = await createSettlementRouteFeeVersionAction({
        settlement_route_id: routeId,
        route_kind: routeKind as "payment_collection" | "cod_carrier",
        effective_from: String(formData.get("effective_from") ?? ""),
        transaction_fee_strategy: strategy as "source_snapshot" | "route_formula" | "none",
        transaction_fee_model: strategy === "route_formula" && model ? (model as "percentage" | "fixed" | "percentage_plus_fixed" | "none") : undefined,
        percentage_fee: formData.get("percentage_fee") ? String(formData.get("percentage_fee")) : undefined,
        fixed_fee: formData.get("fixed_fee") ? String(formData.get("fixed_fee")) : undefined,
        batch_fee_fixed: String(formData.get("batch_fee_fixed") || "0"),
        cod_fee_reversal_policy: strategy === "route_formula" && routeKind === "cod_carrier" && codPolicy ? (codPolicy as "full" | "proportional" | "none") : undefined,
        notes: formData.get("notes") ? String(formData.get("notes")) : undefined,
      });

      if (result.success) {
        toast.success(result.message ?? "تم إنشاء إصدار الرسوم بنجاح");
        setOpen(false);
        onCreated();
      } else {
        toast.error(result.error);
        setFieldErrors(result.fieldErrors);
      }
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">
          <Plus className="size-4" />
          إصدار رسوم جديد
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>إصدار رسوم جديد</DialogTitle>
          <DialogDescription>يُغلق الإصدار الحالي (إن وجد) تلقائيًا عند تاريخ سريان الإصدار الجديد.</DialogDescription>
        </DialogHeader>

        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="flex flex-col gap-1.5">
            <Label htmlFor="effective_from">تاريخ السريان</Label>
            <Input id="effective_from" name="effective_from" type="date" dir="ltr" required disabled={isPending} />
            {fieldErrors?.effective_from && <p className="text-xs font-medium text-destructive">{fieldErrors.effective_from[0]}</p>}
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>استراتيجية الرسوم</Label>
            <Select value={strategy} onValueChange={setStrategy} disabled={isPending}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {availableStrategies.map((s) => (
                  <SelectItem key={s} value={s}>
                    {TRANSACTION_FEE_STRATEGY_LABELS_AR[s]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            {routeKind === "cod_carrier" && (
              <p className="text-xs text-muted-foreground">استراتيجية اللقطة الأصلية غير متاحة لمسار COD ناقل — لا يوجد لقطة رسوم على مستوى المصدر لأحداث COD.</p>
            )}
          </div>

          {strategy === "route_formula" && (
            <>
              <div className="flex flex-col gap-1.5">
                <Label>شكل الرسوم</Label>
                <Select value={model} onValueChange={setModel} disabled={isPending}>
                  <SelectTrigger>
                    <SelectValue placeholder="اختر الشكل" />
                  </SelectTrigger>
                  <SelectContent>
                    {TRANSACTION_FEE_MODELS.map((m) => (
                      <SelectItem key={m} value={m}>
                        {TRANSACTION_FEE_MODEL_LABELS_AR[m]}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                {fieldErrors?.transaction_fee_model && <p className="text-xs font-medium text-destructive">{fieldErrors.transaction_fee_model[0]}</p>}
              </div>

              {(model === "percentage" || model === "percentage_plus_fixed") && (
                <div className="flex flex-col gap-1.5">
                  <Label htmlFor="percentage_fee">النسبة المئوية للرسوم (%)</Label>
                  <Input id="percentage_fee" name="percentage_fee" type="number" step="0.001" min="0" max="100" dir="ltr" disabled={isPending} />
                  {fieldErrors?.percentage_fee && <p className="text-xs font-medium text-destructive">{fieldErrors.percentage_fee[0]}</p>}
                </div>
              )}
              {(model === "fixed" || model === "percentage_plus_fixed") && (
                <div className="flex flex-col gap-1.5">
                  <Label htmlFor="fixed_fee">القيمة الثابتة للرسوم (حتى 4 منازل عشرية)</Label>
                  <Input id="fixed_fee" name="fixed_fee" type="number" step="0.0001" min="0" dir="ltr" disabled={isPending} />
                  {fieldErrors?.fixed_fee && <p className="text-xs font-medium text-destructive">{fieldErrors.fixed_fee[0]}</p>}
                </div>
              )}

              {routeKind === "cod_carrier" && (
                <div className="flex flex-col gap-1.5">
                  <Label>سياسة عكس رسوم COD</Label>
                  <Select value={codPolicy} onValueChange={setCodPolicy} disabled={isPending}>
                    <SelectTrigger>
                      <SelectValue placeholder="اختر السياسة" />
                    </SelectTrigger>
                    <SelectContent>
                      {COD_FEE_REVERSAL_POLICIES.map((p) => (
                        <SelectItem key={p} value={p}>
                          {COD_FEE_REVERSAL_POLICY_LABELS_AR[p]}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  {fieldErrors?.cod_fee_reversal_policy && <p className="text-xs font-medium text-destructive">{fieldErrors.cod_fee_reversal_policy[0]}</p>}
                </div>
              )}
            </>
          )}

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="batch_fee_fixed">رسوم الدفعة الثابتة (تُطبَّق مرة واحدة عند الاعتماد، لا لكل مصدر)</Label>
            <Input id="batch_fee_fixed" name="batch_fee_fixed" type="number" step="0.01" min="0" defaultValue="0" dir="ltr" disabled={isPending} />
            {fieldErrors?.batch_fee_fixed && <p className="text-xs font-medium text-destructive">{fieldErrors.batch_fee_fixed[0]}</p>}
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="notes">ملاحظات (اختياري)</Label>
            <Textarea id="notes" name="notes" disabled={isPending} rows={2} />
          </div>

          <DialogFooter>
            <Button type="submit" disabled={isPending}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              إنشاء الإصدار
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
