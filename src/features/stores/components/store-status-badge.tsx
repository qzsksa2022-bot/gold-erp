import { Badge } from "@/components/ui/badge";
import type { StoreStatus } from "@/types/database";

export function StoreStatusBadge({ status }: { status: StoreStatus }) {
  if (status === "active") return <Badge variant="success">نشط</Badge>;
  return <Badge variant="secondary">معطّل</Badge>;
}
