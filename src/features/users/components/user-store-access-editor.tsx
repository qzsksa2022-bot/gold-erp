"use client";

import { useState, useTransition } from "react";
import { toast } from "sonner";
import { Loader2, Save } from "lucide-react";
import { Checkbox } from "@/components/ui/checkbox";
import { Button } from "@/components/ui/button";
import { setUserStoreAccessAction } from "../actions";

export function UserStoreAccessEditor({
  userId,
  scope,
  allStores,
  initiallySelected,
  readOnly,
}: {
  userId: string;
  scope: string;
  allStores: { id: string; name_ar: string }[];
  initiallySelected: string[];
  readOnly: boolean;
}) {
  const [selected, setSelected] = useState(new Set(initiallySelected));
  const [isPending, startTransition] = useTransition();
  const disabled = readOnly || scope !== "multiple";

  function toggle(id: string) {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  function save() {
    startTransition(async () => {
      const result = await setUserStoreAccessAction(userId, [...selected]);
      if (result.success) toast.success(result.message);
      else toast.error(result.error);
    });
  }

  if (scope !== "multiple") {
    return (
      <p className="text-sm text-muted-foreground">
        {scope === "all"
          ? "هذا المستخدم لديه وصول لجميع المتاجر حاليًا، لا حاجة لتحديد متاجر بعينها."
          : "هذا المستخدم مقيّد بالمتجر الافتراضي فقط. غيّر نطاق الوصول إلى \"مجموعة متاجر محددة\" لاختيار أكثر من متجر."}
      </p>
    );
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
        {allStores.map((store) => (
          <label key={store.id} className="flex items-center gap-2 rounded-md border border-border px-3 py-2 text-sm">
            <Checkbox checked={selected.has(store.id)} disabled={disabled} onCheckedChange={() => toggle(store.id)} />
            {store.name_ar}
          </label>
        ))}
      </div>
      {!readOnly && (
        <div>
          <Button type="button" size="sm" onClick={save} disabled={isPending}>
            {isPending ? <Loader2 className="size-4 animate-spin" /> : <Save className="size-4" />}
            حفظ المتاجر المحددة
          </Button>
        </div>
      )}
    </div>
  );
}
