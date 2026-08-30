"use client";

import { useEffect } from "react";
import { useActionState } from "react";
import { Loader2, Save } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { updateUserStoreScopeAction } from "../actions";
import type { Database, StoreAccessScope } from "@/types/database";

type Profile = Database["public"]["Tables"]["profiles"]["Row"];

// Foundation Hardening 1.3, item 2c/2e: dedicated Store Scope form, gated by
// and acting through users.manage_store_access specifically
// (supabase/migrations/0018/0030) — split out of the old combined
// UserEditForm so an actor holding ONLY this permission (not users.edit) can
// still change a user's store scope, and vice versa.
export function UserStoreScopeForm({
  userId,
  profile,
  stores,
  readOnly,
}: {
  userId: string;
  profile: Profile;
  stores: { id: string; name_ar: string }[];
  readOnly: boolean;
}) {
  const [state, formAction, isPending] = useActionState(updateUserStoreScopeAction.bind(null, userId), null);

  useEffect(() => {
    if (state?.success) toast.success(state.message ?? "تم الحفظ");
    else if (state && !state.success) toast.error(state.error);
  }, [state]);

  return (
    <form action={formAction} className="flex flex-col gap-4">
      <div className="grid grid-cols-2 gap-4">
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="default_store_id">المتجر الافتراضي</Label>
          <Select name="default_store_id" defaultValue={profile.default_store_id ?? undefined} disabled={readOnly || isPending}>
            <SelectTrigger id="default_store_id">
              <SelectValue placeholder="بدون" />
            </SelectTrigger>
            <SelectContent>
              {stores.map((s) => (
                <SelectItem key={s.id} value={s.id}>
                  {s.name_ar}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="store_access_scope">نطاق الوصول للمتاجر</Label>
          <Select name="store_access_scope" defaultValue={profile.store_access_scope as StoreAccessScope} disabled={readOnly || isPending}>
            <SelectTrigger id="store_access_scope">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="single">متجر واحد فقط (المتجر الافتراضي)</SelectItem>
              <SelectItem value="multiple">مجموعة متاجر محددة</SelectItem>
              <SelectItem value="all">جميع المتاجر</SelectItem>
            </SelectContent>
          </Select>
        </div>
      </div>

      {!readOnly && (
        <div>
          <Button type="submit" disabled={isPending}>
            {isPending ? <Loader2 className="size-4 animate-spin" /> : <Save className="size-4" />}
            حفظ نطاق الوصول
          </Button>
        </div>
      )}
    </form>
  );
}
