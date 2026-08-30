"use client";

import { useEffect } from "react";
import { useActionState } from "react";
import { Loader2, Save, ShieldCheck } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import { updateSecuritySettingsAction } from "../actions";
import type { SecuritySettings } from "../types";

export function SecuritySettingsForm({ settings }: { settings: SecuritySettings }) {
  const [state, formAction, isPending] = useActionState(updateSecuritySettingsAction, null);

  useEffect(() => {
    if (state?.success) toast.success(state.message);
    else if (state && !state.success) toast.error(state.error);
  }, [state]);

  return (
    <form action={formAction} className="flex max-w-lg flex-col gap-5">
      <div className="flex items-center justify-between rounded-lg border border-dashed border-border px-4 py-3">
        <div className="flex items-start gap-3">
          <ShieldCheck className="mt-0.5 size-5 text-muted-foreground" />
          <div>
            <p className="text-sm font-medium">التحقق بخطوتين (2FA)</p>
            <p className="text-xs text-muted-foreground">
              البنية جاهزة لتفعيل TOTP لاحقًا دون إعادة هيكلة تسجيل الدخول. غير مُفعّل في هذه المرحلة.
            </p>
          </div>
        </div>
        <Switch name="two_factor_enabled" defaultChecked={settings.two_factor_enabled} disabled />
      </div>

      <div className="flex flex-col gap-1.5">
        <Label htmlFor="session_timeout_minutes">مدة الجلسة قبل انتهاء الصلاحية (بالدقائق)</Label>
        <Input
          id="session_timeout_minutes"
          name="session_timeout_minutes"
          type="number"
          min={15}
          max={1440}
          defaultValue={settings.session_timeout_minutes}
          disabled={isPending}
        />
        <p className="text-xs text-muted-foreground">
          هذه القيمة إرشادية حاليًا؛ مدة صلاحية الجلسة الفعلية يتحكم بها إعداد Supabase Auth JWT/Refresh Token.
        </p>
      </div>

      <div>
        <Button type="submit" disabled={isPending}>
          {isPending ? <Loader2 className="size-4 animate-spin" /> : <Save className="size-4" />}
          حفظ
        </Button>
      </div>
    </form>
  );
}
