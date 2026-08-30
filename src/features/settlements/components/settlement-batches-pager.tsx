import Link from "next/link";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

/**
 * Next/Previous-only pager for /settlements — list_settlement_batches()
 * (migration 0182) does not return a total_count column (unlike every
 * other list_*() RPC this codebase's shared <Pagination> component is built
 * around), so this deliberately simpler control is used instead: queries.ts
 * fetches pageSize + 1 rows and hasNextPage reflects whether that extra row
 * came back, never a fabricated total/page-count.
 */
export function SettlementBatchesPager({ page, hasNextPage, buildHref }: { page: number; hasNextPage: boolean; buildHref: (page: number) => string }) {
  if (page <= 1 && !hasNextPage) return null;

  return (
    <div className="flex flex-col items-center justify-between gap-3 border-t border-border px-4 py-3 sm:flex-row">
      <p className="text-xs text-muted-foreground">صفحة {page}</p>
      <div className="flex items-center gap-1">
        <Button asChild variant="outline" size="icon" className={cn("size-8", page <= 1 && "pointer-events-none opacity-40")}>
          <Link href={buildHref(Math.max(1, page - 1))} aria-label="السابق">
            <ChevronRight className="size-4 rtl:rotate-180" />
          </Link>
        </Button>
        <Button asChild variant="outline" size="icon" className={cn("size-8", !hasNextPage && "pointer-events-none opacity-40")}>
          <Link href={buildHref(page + 1)} aria-label="التالي">
            <ChevronLeft className="size-4 rtl:rotate-180" />
          </Link>
        </Button>
      </div>
    </div>
  );
}
