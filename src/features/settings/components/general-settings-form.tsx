"use client";

import { useEffect } from "react";
import { useActionState } from "react";
import { Loader2, Save } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { updateGeneralSettingsAction } from "../actions";
import type { GeneralSettings } from "../types";

export function GeneralSettingsForm({ settings }: { settings: GeneralSettings }) {
  const [state, formAction, isPending] = useActionState(updateGeneralSettingsAction, null);

  useEffect(() => {
    if (state?.success) toast.success(state.message);
    else if (state && !state.success) toast.error(state.error);
  }, [state]);

  return (
    <form action={formAction} className="flex max-w-lg flex-col gap-4">
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="system_name_ar">اسم النظام (عربي)</Label>
          <Input id="system_name_ar" name="system_name_ar" defaultValue={settings.system_name_ar} required disabled={isPending} />
        </div>
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="system_name_en">اسم النظام (إنجليزي)</Label>
          <Input id="system_name_en" name="system_name_en" defaultValue={settings.system_name_en} disabled={isPending} />
        </div>
      </div>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="currency">العملة</Label>
          <Input id="currency" name="currency" defaultValue={settings.currency} disabled />
          <p className="text-xs text-muted-foreground">SAR فقط في هذه المرحلة.</p>
        </div>
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="timezone">المنطقة الزمنية</Label>
          <Input id="timezone" name="timezone" defaultValue={settings.timezone} disabled />
          <p className="text-xs text-muted-foreground">Asia/Riyadh فقط في هذه المرحلة.</p>
        </div>
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
