"use client";

import { useTransition } from "react";
import { Loader2, Save, UserRound } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { saveTodayGoldPricesAction } from "../actions";
import { formatRiyadhDateTime } from "@/lib/date";
import type { Database } from "@/types/database";

type Karat = Database["public"]["Tables"]["karats"]["Row"];
type PriceRow = Database["public"]["Tables"]["daily_gold_prices"]["Row"] & {
  updated_by_profile: { full_name: string } | null;
};

export function TodayPriceForm({
  date,
  rows,
}: {
  date: string;
  rows: { karat: Karat; price: PriceRow | null }[];
}) {
  const [isPending, startTransition] = useTransition();

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);

    startTransition(async () => {
      const result = await saveTodayGoldPricesAction(null, formData);
      if (result.success) toast.success(result.message);
      else toast.error(result.error);
    });
  }

  return (
    <form onSubmit={handleSubmit} className="rounded-xl border border-border bg-card p-4 sm:p-6">
      <input type="hidden" name="price_date" value={date} />

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {rows.map(({ karat, price }) => (
          <div key={karat.id} className="flex flex-col gap-1.5 rounded-lg border border-border p-3">
            <Label htmlFor={`price_karat_${karat.id}`} className="text-sm font-semibold">
              {karat.name_ar}
            </Label>
            <div className="relative">
              <Input
                id={`price_karat_${karat.id}`}
                name={`price_karat_${karat.id}`}
                type="number"
                step="0.01"
                min="0"
                inputMode="decimal"
                placeholder="0.00"
                defaultValue={price?.price_per_gram ?? ""}
                disabled={isPending}
                className="pe-14 text-left tabular-nums"
                dir="ltr"
              />
              <span className="pointer-events-none absolute inset-y-0 end-3 flex items-center text-xs text-muted-foreground">
                ر.س/جم
              </span>
            </div>

            {price ? (
              <div className="mt-1 flex flex-col gap-0.5 text-xs text-muted-foreground">
                <span className="flex items-center gap-1">
                  <UserRound className="size-3" />
                  {price.updated_by_profile?.full_name ?? "—"} · {formatRiyadhDateTime(price.updated_at)}
                </span>
                <Badge variant={price.is_manual_override ? "outline" : "secondary"} className="w-fit text-[10px]">
                  {price.source_type === "manual" ? "يدوي" : "مستورد"}
                  {price.is_manual_override && price.source_type !== "manual" ? " (تعديل يدوي)" : ""}
                </Badge>
              </div>
            ) : (
              <Badge variant="warning" className="mt-1 w-fit text-[10px]">
                لم يُدخل بعد
              </Badge>
            )}
          </div>
        ))}
      </div>

      <div className="mt-6 flex justify-end">
        <Button type="submit" variant="accent" disabled={isPending}>
          {isPending ? <Loader2 className="size-4 animate-spin" /> : <Save className="size-4" />}
          حفظ أسعار اليوم
        </Button>
      </div>
    </form>
  );
}
