import type { LucideIcon } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";

export function StatCard({ label, value, icon: Icon }: { label: string; value: string | number; icon: LucideIcon }) {
  return (
    <Card>
      <CardContent className="flex items-center gap-4 py-5">
        <div className="flex size-11 shrink-0 items-center justify-center rounded-lg bg-accent/10 text-accent">
          <Icon className="size-5" />
        </div>
        <div>
          <p className="text-2xl font-semibold tabular-nums">{value}</p>
          <p className="text-sm text-muted-foreground">{label}</p>
        </div>
      </CardContent>
    </Card>
  );
}
