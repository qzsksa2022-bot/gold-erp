import Link from "next/link";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

/**
 * URL-driven pagination (page number lives in the querystring), so lists
 * stay server-rendered and shareable/bookmarkable — no client-side page
 * state to keep in sync.
 */
export function Pagination({
  page,
  pageSize,
  total,
  buildHref,
}: {
  page: number;
  pageSize: number;
  total: number;
  buildHref: (page: number) => string;
}) {
  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  if (totalPages <= 1) return null;

  const from = total === 0 ? 0 : (page - 1) * pageSize + 1;
  const to = Math.min(page * pageSize, total);

  return (
    <div className="flex flex-col items-center justify-between gap-3 border-t border-border px-4 py-3 sm:flex-row">
      <p className="text-xs text-muted-foreground">
        عرض {from}–{to} من أصل {total}
      </p>
      <div className="flex items-center gap-1">
        <Button asChild variant="outline" size="icon" className={cn("size-8", page <= 1 && "pointer-events-none opacity-40")}>
          <Link href={buildHref(Math.max(1, page - 1))} aria-label="السابق">
            <ChevronRight className="size-4 rtl:rotate-180" />
          </Link>
        </Button>
        <span className="min-w-16 text-center text-xs text-muted-foreground">
          {page} / {totalPages}
        </span>
        <Button
          asChild
          variant="outline"
          size="icon"
          className={cn("size-8", page >= totalPages && "pointer-events-none opacity-40")}
        >
          <Link href={buildHref(Math.min(totalPages, page + 1))} aria-label="التالي">
            <ChevronLeft className="size-4 rtl:rotate-180" />
          </Link>
        </Button>
      </div>
    </div>
  );
}
