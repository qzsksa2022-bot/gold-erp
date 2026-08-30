"use client";

import { useState } from "react";
import { Power, PowerOff } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/shared/confirm-dialog";
import { setKaratStatusAction } from "../actions";
import type { MasterDataStatus } from "@/types/database";

export function KaratStatusToggle({ karatId, status, karatName }: { karatId: string; status: MasterDataStatus; karatName: string }) {
  const [open, setOpen] = useState(false);
  const willDisable = status === "active";

  return (
    <>
      <Button variant="ghost" size="icon" onClick={() => setOpen(true)} aria-label={willDisable ? "تعطيل العيار" : "إعادة تفعيل العيار"}>
        {willDisable ? <PowerOff className="size-4 text-destructive" /> : <Power className="size-4 text-success" />}
      </Button>
      <ConfirmDialog
        open={open}
        onOpenChange={setOpen}
        title={willDisable ? `تعطيل عيار "${karatName}"؟` : `إعادة تفعيل عيار "${karatName}"؟`}
        description={
          willDisable
            ? "لن يظهر هذا العيار كخيار في العمليات الجديدة (أسعار الذهب، المصنعية) بعد تعطيله، وستبقى بياناته التاريخية كما هي دون أي تغيير."
            : "سيصبح هذا العيار متاحًا للاستخدام في العمليات الجديدة مجددًا."
        }
        confirmLabel={willDisable ? "تعطيل" : "تفعيل"}
        destructive={willDisable}
        onConfirm={async () => {
          const result = await setKaratStatusAction(karatId, willDisable ? "inactive" : "active");
          if (result.success) toast.success(result.message);
          else toast.error(result.error);
        }}
      />
    </>
  );
}
