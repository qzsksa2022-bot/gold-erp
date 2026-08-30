"use client";

import { useState } from "react";
import { XCircle } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/shared/confirm-dialog";
import { cancelManufacturingFeeVersionAction } from "../actions";

/** Only ever shown for a FUTURE, not-yet-effective version — the DB rejects any other attempt anyway. */
export function CancelVersionButton({ versionId, effectiveFrom }: { versionId: string; effectiveFrom: string }) {
  const [open, setOpen] = useState(false);

  return (
    <>
      <Button variant="ghost" size="sm" onClick={() => setOpen(true)} className="text-destructive hover:text-destructive">
        <XCircle className="size-3.5" />
        إلغاء
      </Button>
      <ConfirmDialog
        open={open}
        onOpenChange={setOpen}
        title="إلغاء الإصدار المستقبلي؟"
        description={`هذا الإصدار (سيبدأ سريانه ${effectiveFrom}) لم يبدأ العمل به بعد، ويمكن إلغاؤه بأمان. لن يؤثر هذا على أي سعر سارٍ حاليًا أو أي سجل تاريخي سابق.`}
        confirmLabel="إلغاء الإصدار"
        destructive
        onConfirm={async () => {
          const result = await cancelManufacturingFeeVersionAction(versionId);
          if (result.success) toast.success(result.message);
          else toast.error(result.error);
        }}
      />
    </>
  );
}
