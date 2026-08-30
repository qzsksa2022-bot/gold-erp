"use client";

import { useState } from "react";
import { Power, PowerOff } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/shared/confirm-dialog";
import { setCollectionChannelStatusAction } from "../actions";
import type { MasterDataStatus } from "@/types/database";

export function CollectionChannelStatusToggle({
  channelId,
  status,
  channelName,
}: {
  channelId: string;
  status: MasterDataStatus;
  channelName: string;
}) {
  const [open, setOpen] = useState(false);
  const willDisable = status === "active";

  return (
    <>
      <Button
        variant="ghost"
        size="icon"
        onClick={() => setOpen(true)}
        aria-label={willDisable ? "تعطيل قناة التحصيل" : "إعادة تفعيل قناة التحصيل"}
      >
        {willDisable ? <PowerOff className="size-4 text-destructive" /> : <Power className="size-4 text-success" />}
      </Button>
      <ConfirmDialog
        open={open}
        onOpenChange={setOpen}
        title={willDisable ? `تعطيل قناة "${channelName}"؟` : `إعادة تفعيل قناة "${channelName}"؟`}
        description={
          willDisable
            ? "لن تظهر قناة التحصيل هذه كخيار في عمليات جديدة بعد تعطيلها."
            : "ستصبح قناة التحصيل هذه متاحة للاستخدام مجددًا."
        }
        confirmLabel={willDisable ? "تعطيل" : "تفعيل"}
        destructive={willDisable}
        onConfirm={async () => {
          const result = await setCollectionChannelStatusAction(channelId, willDisable ? "inactive" : "active");
          if (result.success) toast.success(result.message);
          else toast.error(result.error);
        }}
      />
    </>
  );
}
