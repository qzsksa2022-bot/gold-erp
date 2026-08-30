"use client";

import { useState } from "react";
import { Power, PowerOff } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/shared/confirm-dialog";
import { setShippingCarrierStatusAction } from "../actions";
import type { ShippingMasterDataStatus } from "@/types/database";

export function CarrierStatusToggle({ carrierId, status, carrierName }: { carrierId: string; status: ShippingMasterDataStatus; carrierName: string }) {
  const [open, setOpen] = useState(false);
  const willDisable = status === "active";

  return (
    <>
      <Button variant="ghost" size="icon" onClick={() => setOpen(true)} aria-label={willDisable ? "تعطيل شركة الشحن" : "إعادة تفعيل شركة الشحن"}>
        {willDisable ? <PowerOff className="size-4 text-destructive" /> : <Power className="size-4 text-success" />}
      </Button>
      <ConfirmDialog
        open={open}
        onOpenChange={setOpen}
        title={willDisable ? `تعطيل شركة الشحن "${carrierName}"؟` : `إعادة تفعيل شركة الشحن "${carrierName}"؟`}
        description={
          willDisable
            ? "لن تكون هذه الشركة متاحة لإنشاء شحنات جديدة أو إصدارات تسعير جديدة بعد تعطيلها، وستبقى كل الشحنات وإصدارات التسعير التاريخية المرتبطة بها كما هي دون أي تغيير."
            : "ستصبح هذه الشركة متاحة لإنشاء شحنات جديدة وإصدارات تسعير جديدة مجددًا."
        }
        confirmLabel={willDisable ? "تعطيل" : "تفعيل"}
        destructive={willDisable}
        onConfirm={async () => {
          const result = await setShippingCarrierStatusAction(carrierId, willDisable ? "disabled" : "active");
          if (result.success) toast.success(result.message);
          else toast.error(result.error);
        }}
      />
    </>
  );
}
