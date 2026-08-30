"use client";

import { useRouter, useSearchParams, usePathname } from "next/navigation";
import { useTransition } from "react";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import type { Database } from "@/types/database";

type Karat = Database["public"]["Tables"]["karats"]["Row"];

export function PriceHistoryToolbar({
  karats,
  karatId,
  dateFrom,
  dateTo,
}: {
  karats: Karat[];
  karatId: string;
  dateFrom: string;
  dateTo: string;
}) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [, startTransition] = useTransition();

  function updateParams(next: Record<string, string>) {
    const params = new URLSearchParams(searchParams.toString());
    for (const [key, val] of Object.entries(next)) {
      if (val) params.set(key, val);
      else params.delete(key);
    }
    params.set("page", "1");
    startTransition(() => router.push(`${pathname}?${params.toString()}`));
  }

  return (
    <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-end">
      <div className="flex flex-col gap-1.5">
        <Label className="text-xs text-muted-foreground">العيار</Label>
        <Select value={karatId || "all"} onValueChange={(v) => updateParams({ karatId: v === "all" ? "" : v })}>
          <SelectTrigger className="sm:w-44">
            <SelectValue placeholder="كل العيارات" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">كل العيارات</SelectItem>
            {karats.map((k) => (
              <SelectItem key={k.id} value={k.id}>
                {k.name_ar}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <div className="flex flex-col gap-1.5">
        <Label className="text-xs text-muted-foreground">من تاريخ</Label>
        <Input
          type="date"
          defaultValue={dateFrom}
          className="sm:w-40"
          onChange={(e) => updateParams({ dateFrom: e.target.value })}
        />
      </div>

      <div className="flex flex-col gap-1.5">
        <Label className="text-xs text-muted-foreground">إلى تاريخ</Label>
        <Input type="date" defaultValue={dateTo} className="sm:w-40" onChange={(e) => updateParams({ dateTo: e.target.value })} />
      </div>
    </div>
  );
}
