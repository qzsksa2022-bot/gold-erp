import { ScrollText } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { EmptyState } from "@/components/shared/empty-state";
import { auditActionLabel } from "@/lib/audit/action-labels";
import { formatRelativeArabic } from "@/lib/date";

type Activity = { id: string; action: string; entity_type: string; created_at: string; actorName: string };

export function RecentActivity({ items }: { items: Activity[] }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>آخر النشاطات</CardTitle>
      </CardHeader>
      <CardContent>
        {items.length === 0 ? (
          <EmptyState icon={ScrollText} title="لا توجد نشاطات بعد" className="border-none py-8" />
        ) : (
          <ul className="flex flex-col divide-y divide-border">
            {items.map((item) => (
              <li key={item.id} className="flex items-center justify-between gap-3 py-3 text-sm">
                <div>
                  <p className="font-medium">{auditActionLabel(item.action)}</p>
                  <p className="text-xs text-muted-foreground">{item.actorName}</p>
                </div>
                <span className="shrink-0 text-xs text-muted-foreground">{formatRelativeArabic(item.created_at)}</span>
              </li>
            ))}
          </ul>
        )}
      </CardContent>
    </Card>
  );
}
