import { Badge } from "@/components/ui/badge";
import type { ProfileStatus } from "@/types/database";

// Foundation Hardening 1.3, item 8: pending_setup is its own independent
// status, not a synonym for "disabled" — a brand-new account still being
// onboarded (0019) should never look identical to a deliberately suspended
// one in the UI, even though the DB layer already fully distinguishes them
// (supabase/migrations/0019, 0029).
export function UserStatusBadge({ status }: { status: ProfileStatus }) {
  if (status === "active") return <Badge variant="success">نشط</Badge>;
  if (status === "pending_setup") return <Badge variant="warning">قيد الإعداد</Badge>;
  return <Badge variant="secondary">معطّل</Badge>;
}
