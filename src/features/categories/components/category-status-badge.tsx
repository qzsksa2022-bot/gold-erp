import { Badge } from "@/components/ui/badge";
import type { MasterDataStatus } from "@/types/database";

export function CategoryStatusBadge({ status }: { status: MasterDataStatus }) {
  if (status === "active") return <Badge variant="success">نشط</Badge>;
  return <Badge variant="secondary">معطّل</Badge>;
}
