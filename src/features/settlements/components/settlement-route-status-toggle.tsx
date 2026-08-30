"use client";

import { useState } from "react";
import { Power, PowerOff } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/shared/confirm-dialog";
import { setSettlementRouteStatusAction } from "../actions";

/** Enable/disable toggle for settlement_routes — goes through disable_settlement_route()/enable_settlement_route() (0169), never a raw table write. */
export function SettlementRouteStatusToggle({ routeId, status, routeName }: { routeId: string; status: "active" | "disabled"; routeName: string }) {
  const [open, setOpen] = useState(false);
  const willDisable = status === "active";

  return (
    <>
      <Button variant="ghost" size="icon" onClick={() => setOpen(true)} aria-label={willDisable ? "تعطيل المسار" : "إعادة تفعيل المسار"}>
        {willDisable ? <PowerOff className="size-4 text-destructive" /> : <Power className="size-4 text-success" />}
      </Button>
      <ConfirmDialog
        open={open}
        onOpenChange={setOpen}
        title={willDisable ? `تعطيل مسار "${routeName}"؟` : `إعادة تفعيل مسار "${routeName}"؟`}
        description={
          willDisable
            ? "لن يمكن اختيار هذا المسار لدفعة تسوية جديدة بعد تعطيله — كل الدفعات التاريخية التي تستخدمه (بلقطتها المجمّدة) تبقى دون تأثير."
            : "سيصبح هذا المسار متاحًا لاختياره في دفعات تسوية جديدة مجددًا — بشرط ألا يوجد مسار نشط آخر بنفس معايير المطابقة."
        }
        confirmLabel={willDisable ? "تعطيل" : "تفعيل"}
        destructive={willDisable}
        onConfirm={async () => {
          const result = await setSettlementRouteStatusAction(routeId, willDisable ? "disabled" : "active");
          if (result.success) toast.success(result.message);
          else toast.error(result.error);
        }}
      />
    </>
  );
}
