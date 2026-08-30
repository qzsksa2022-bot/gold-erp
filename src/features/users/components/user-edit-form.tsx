"use client";

import { useEffect } from "react";
import { useActionState } from "react";
import { Loader2, Save } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { updateUserProfileAction } from "../actions";
import type { Database } from "@/types/database";

type Profile = Database["public"]["Tables"]["profiles"]["Row"];

// Foundation Hardening 1.3, item 2e / item 3: this form now covers ONLY
// full_name — the one column group authorized by users.edit
// (supabase/migrations/0030). Store Scope (default_store_id/
// store_access_scope) moved to its own form/action gated by
// users.manage_store_access specifically — see UserStoreScopeForm.
export function UserEditForm({ userId, profile, readOnly }: { userId: string; profile: Profile; readOnly: boolean }) {
  const [state, formAction, isPending] = useActionState(updateUserProfileAction.bind(null, userId), null);

  useEffect(() => {
    if (state?.success) toast.success(state.message ?? "تم الحفظ");
    else if (state && !state.success) toast.error(state.error);
  }, [state]);

  return (
    <form action={formAction} className="flex flex-col gap-4">
      <div className="flex flex-col gap-1.5">
        <Label htmlFor="full_name">الاسم الكامل</Label>
        <Input id="full_name" name="full_name" defaultValue={profile.full_name} required disabled={readOnly || isPending} />
        {!state?.success && state?.fieldErrors?.full_name && (
          <p className="text-xs font-medium text-destructive">{state.fieldErrors.full_name[0]}</p>
        )}
      </div>

      <div className="flex flex-col gap-1.5">
        <Label>البريد الإلكتروني</Label>
        <Input value={profile.email} disabled readOnly className="text-muted-foreground" />
        <p className="text-xs text-muted-foreground">لا يمكن تغيير البريد الإلكتروني من هنا حاليًا.</p>
      </div>

      {!readOnly && (
        <div>
          <Button type="submit" disabled={isPending}>
            {isPending ? <Loader2 className="size-4 animate-spin" /> : <Save className="size-4" />}
            حفظ التعديلات
          </Button>
        </div>
      )}
    </form>
  );
}
