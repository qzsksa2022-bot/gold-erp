"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { riyadhTodayIsoDate } from "@/lib/date";
import { ROUTES } from "@/lib/constants";
import { createDraftSettlementBatchAction } from "../actions";

type RouteLookup = { id: string; code: string; name_ar: string; route_kind: string };

/**
 * Step 1 of the New Settlement flow (/settlements/new) — creates a draft
 * batch header via create_draft_settlement_batch() (0177), which reserves
 * NOTHING financially (item 18). On success, redirects to the batch detail
 * page (/settlements/[id]), which renders the source-selection workspace
 * for as long as the batch stays in draft status.
 */
export function SettlementDraftCreateForm({ routes }: { routes: RouteLookup[] }) {
  const router = useRouter();
  const [routeId, setRouteId] = useState("");
  const [settlementDate, setSettlementDate] = useState(riyadhTodayIsoDate());
  const [reference, setReference] = useState("");
  const [notes, setNotes] = useState("");
  const [isPending, startTransition] = useTransition();

  function submit() {
    startTransition(async () => {
      const result = await createDraftSettlementBatchAction({
        settlement_route_id: routeId,
        settlement_date: settlementDate,
        provider_statement_reference: reference || undefined,
        notes: notes || undefined,
      });

      if (result.success) {
        toast.success(result.message ?? `تم إنشاء مسودة تسوية رقم ${result.data.settlement_number}`);
        router.push(`${ROUTES.settlements}/${result.data.id}`);
        return;
      }

      toast.error(result.error);
    });
  }

  const canSubmit = Boolean(routeId && settlementDate);

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">بيانات دفعة التسوية الجديدة</CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-4">
        <div className="flex flex-col gap-1.5">
          <Label>مسار التسوية</Label>
          <Select value={routeId} onValueChange={setRouteId} disabled={isPending}>
            <SelectTrigger>
              <SelectValue placeholder="اختر مسار التسوية" />
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
          <Input type="date" dir="ltr" value={settlementDate} onChange={(e) => setSettlementDate(e.target.value)} disabled={isPending} />
        </div>

        <div className="flex flex-col gap-1.5">
          <Label>مرجع كشف مزوّد الدفع/الناقل (اختياري)</Label>
          <Input dir="ltr" value={reference} onChange={(e) => setReference(e.target.value)} disabled={isPending} maxLength={200} />
        </div>

        <div className="flex flex-col gap-1.5">
          <Label>ملاحظات (اختياري)</Label>
          <Textarea value={notes} onChange={(e) => setNotes(e.target.value)} disabled={isPending} rows={2} />
        </div>

        <Button variant="accent" onClick={submit} disabled={isPending || !canSubmit}>
          {isPending && <Loader2 className="size-4 animate-spin" />}
          إنشاء المسودة ومتابعة اختيار المصادر
        </Button>
      </CardContent>
    </Card>
  );
}
