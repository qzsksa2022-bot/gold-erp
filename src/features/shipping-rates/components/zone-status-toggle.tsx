"use client";

import { useState } from "react";
import { Power, PowerOff } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/shared/confirm-dialog";
import { setShippingZoneStatusAction } from "../actions";
import type { ShippingMasterDataStatus } from "@/types/database";

export function ZoneStatusToggle({ zoneId, status, zoneName }: { zoneId: string; status: ShippingMasterDataStatus; zoneName: string }) {
  const [open, setOpen] = useState(false);
  const willDisable = status === "active";

  return (
    <>
      <Button variant="ghost" size="icon" onClick={() => setOpen(true)} aria-label={willDisable ? "تعطيل المنطقة" : "إعادة تفعيل المنطقة"}>
        {willDisable ? <PowerOff className="size-4 text-destructive" /> : <Power className="size-4 text-success" />}
      </Button>
      <ConfirmDialog
        open={open}
        onOpenChange={setOpen}
        title={willDisable ? `تعطيل المنطقة "${zoneName}"؟` : `إعادة تفعيل المنطقة "${zoneName}"؟`}
        description={
          willDisable
            ? "لن تكون هذه المنطقة متاحة لإنشاء شحنات جديدة أو إصدارات تسعير/رسوم إرجاع جديدة بعد تعطيلها، وستبقى كل البيانات التاريخية المرتبطة بها كما هي دون أي تغيير."
            : "ستصبح هذه المنطقة متاحة لإنشاء شحنات جديدة وإصدارات تسعير/رسوم إرجاع جديدة مجددًا."
        }
        confirmLabel={willDisable ? "تعطيل" : "تفعيل"}
        destructive={willDisable}
        onConfirm={async () => {
          const result = await setShippingZoneStatusAction(zoneId, willDisable ? "disabled" : "active");
          if (result.success) toast.success(result.message);
          else toast.error(result.error);
        }}
      />
    </>
  );
}
