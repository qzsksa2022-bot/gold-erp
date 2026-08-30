"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Power, PowerOff, Ban } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/shared/confirm-dialog";
import { setUserStatusAction, cancelUserInviteAction } from "../actions";
import { ROUTES } from "@/lib/constants";
import type { ProfileStatus } from "@/types/database";

// Foundation Hardening 1.3, item 8 / Foundation Hardening 1.4, item 5:
// complete the UI for pending_setup — the generic active/suspended power
// toggle no longer applies unmodified to it. Two special cases, both driven
// by the same underlying invariant (supabase/migrations/0029: an account can
// only ever reach 'active' once, via finalize_new_user_profile(), which
// stamps provisioned_at):
//
//  * status === 'pending_setup': the only legitimate action here is
//    cancelling the invite. This DELETES the still-unprovisioned auth user
//    outright (cancelUserInviteAction) rather than moving status to
//    'suspended' — supabase/migrations/0036 now rejects that UPDATE at the
//    database layer, because it used to strand the account with no way to
//    ever complete or reactivate it. There is no "activate" button either —
//    completing setup only ever happens through finalize_new_user_profile()
//    (gated by users.create), which this component has nothing to do with.
//  * status === 'suspended' with no provisioned_at: a LEGACY cancelled
//    invite (from before 0036) or a suspended account that was never
//    provisioned — attempting to "reactivate" it would be rejected at the DB
//    layer. Nothing useful to offer here; the account can only become usable
//    again through a fresh users.create + finalize flow (a new invite), not
//    through this toggle.
export function UserStatusToggle({
  userId,
  status,
  provisionedAt,
  userName,
}: {
  userId: string;
  status: ProfileStatus;
  provisionedAt: string | null;
  userName: string;
}) {
  const [open, setOpen] = useState(false);
  const router = useRouter();

  if (status === "pending_setup") {
    return (
      <>
        <Button variant="ghost" size="icon" onClick={() => setOpen(true)} aria-label="إلغاء الدعوة">
          <Ban className="size-4 text-destructive" />
        </Button>
        <ConfirmDialog
          open={open}
          onOpenChange={setOpen}
          title={`إلغاء دعوة "${userName}"؟`}
          description="لم يُكمل هذا المستخدم إعداد حسابه بعد. سيتم حذف الحساب غير المكتمل نهائيًا ولا يمكن التراجع عن ذلك — لدعوته مجددًا استخدم إنشاء مستخدم جديد بنفس البريد الإلكتروني."
          confirmLabel="إلغاء الدعوة وحذف الحساب"
          destructive
          onConfirm={async () => {
            const result = await cancelUserInviteAction(userId);
            if (result.success) {
              toast.success(result.message);
              router.push(ROUTES.users);
              router.refresh();
            } else {
              toast.error(result.error);
            }
          }}
        />
      </>
    );
  }

  if (status === "suspended" && !provisionedAt) {
    return null;
  }

  const willSuspend = status === "active";

  return (
    <>
      <Button variant="ghost" size="icon" onClick={() => setOpen(true)} aria-label={willSuspend ? "تعطيل المستخدم" : "إعادة تفعيل المستخدم"}>
        {willSuspend ? <PowerOff className="size-4 text-destructive" /> : <Power className="size-4 text-success" />}
      </Button>
      <ConfirmDialog
        open={open}
        onOpenChange={setOpen}
        title={willSuspend ? `تعطيل حساب "${userName}"؟` : `إعادة تفعيل حساب "${userName}"؟`}
        description={willSuspend ? "لن يتمكن هذا المستخدم من تسجيل الدخول بعد التعطيل." : "سيتمكن هذا المستخدم من تسجيل الدخول مجددًا."}
        confirmLabel={willSuspend ? "تعطيل" : "تفعيل"}
        destructive={willSuspend}
        onConfirm={async () => {
          const result = await setUserStatusAction(userId, willSuspend ? "suspended" : "active");
          if (result.success) toast.success(result.message);
          else toast.error(result.error);
        }}
      />
    </>
  );
}
