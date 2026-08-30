"use client";

import { useState, useTransition } from "react";
import { Loader2 } from "lucide-react";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";

/**
 * Generic "confirm before doing something sensitive" dialog (spec 20:
 * "Confirmation قبل الإجراءات الحساسة"). Controlled from the parent via
 * `open`/`onOpenChange`; `onConfirm` may be async (a server action call) —
 * the confirm button shows a spinner and disables both buttons while it
 * runs, and the dialog only closes after it resolves.
 */
export function ConfirmDialog({
  open,
  onOpenChange,
  title,
  description,
  confirmLabel = "تأكيد",
  cancelLabel = "إلغاء",
  destructive = false,
  onConfirm,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  description?: string;
  confirmLabel?: string;
  cancelLabel?: string;
  destructive?: boolean;
  onConfirm: () => void | Promise<void>;
}) {
  const [isPending, startTransition] = useTransition();
  const [busy, setBusy] = useState(false);

  const handleConfirm = () => {
    setBusy(true);
    startTransition(async () => {
      try {
        await onConfirm();
      } finally {
        setBusy(false);
        onOpenChange(false);
      }
    });
  };

  return (
    <AlertDialog open={open} onOpenChange={(next) => !busy && !isPending && onOpenChange(next)}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{title}</AlertDialogTitle>
          {description && <AlertDialogDescription>{description}</AlertDialogDescription>}
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel disabled={busy || isPending}>{cancelLabel}</AlertDialogCancel>
          <AlertDialogAction
            onClick={(e) => {
              e.preventDefault();
              handleConfirm();
            }}
            disabled={busy || isPending}
            className={!destructive ? "bg-primary text-primary-foreground hover:opacity-90" : undefined}
          >
            {busy || isPending ? <Loader2 className="size-4 animate-spin" /> : null}
            {confirmLabel}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
