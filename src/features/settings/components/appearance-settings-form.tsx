"use client";

import { useEffect, useState } from "react";
import { useActionState } from "react";
import { Loader2, Save } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { updateAppearanceSettingsAction } from "../actions";
import type { AppearanceSettings } from "../types";

export function AppearanceSettingsForm({ settings }: { settings: AppearanceSettings }) {
  const [state, formAction, isPending] = useActionState(updateAppearanceSettingsAction, null);
  const [accent, setAccent] = useState(settings.accent_color);

  useEffect(() => {
    if (state?.success) toast.success(state.message);
    else if (state && !state.success) toast.error(state.error);
  }, [state]);

  return (
    <form action={formAction} className="flex max-w-lg flex-col gap-4">
      <div className="flex flex-col gap-1.5">
        <Label htmlFor="logo_url">رابط الشعار</Label>
        <Input id="logo_url" name="logo_url" placeholder="https://..." defaultValue={settings.logo_url ?? ""} disabled={isPending} />
        {!state?.success && state?.fieldErrors?.logo_url && (
          <p className="text-xs font-medium text-destructive">{state.fieldErrors.logo_url[0]}</p>
        )}
      </div>

      <div className="flex flex-col gap-1.5">
        <Label htmlFor="accent_color">لون العلامة (Accent)</Label>
        <div className="flex items-center gap-3">
          <input
            type="color"
            value={accent}
            onChange={(e) => setAccent(e.target.value)}
            className="size-10 shrink-0 cursor-pointer rounded-md border border-input bg-transparent p-1"
            aria-label="اختيار اللون"
          />
          <Input
            id="accent_color"
            name="accent_color"
            value={accent}
            onChange={(e) => setAccent(e.target.value)}
            dir="ltr"
            className="max-w-40"
            disabled={isPending}
          />
        </div>
        {!state?.success && state?.fieldErrors?.accent_color && (
          <p className="text-xs font-medium text-destructive">{state.fieldErrors.accent_color[0]}</p>
        )}
      </div>

      <div className="flex flex-col gap-1.5">
        <Label htmlFor="font_family">اسم الخط (اختياري)</Label>
        <Input
          id="font_family"
          name="font_family"
          placeholder="مثال: IBM Plex Sans Arabic"
          defaultValue={settings.font_family ?? ""}
          disabled={isPending}
        />
        <p className="text-xs text-muted-foreground">يجب أن يكون الخط متاحًا في نظام المستخدم أو مُحمّلًا مسبقًا.</p>
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
