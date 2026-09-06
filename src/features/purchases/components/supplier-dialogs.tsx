"use client";

import { useRef, useState, useTransition } from "react";
import { Loader2, Plus, Pencil } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Switch } from "@/components/ui/switch";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { createSupplierAction, updateSupplierAction, setSupplierStatusAction } from "../actions";

/** Creates a global supplier via create_supplier() (migration 0239), gated on purchases.manage_suppliers. */
export function SupplierCreateDialog() {
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    startTransition(async () => {
      const text = (k: string) => (formData.get(k) ? String(formData.get(k)) : undefined);
      const result = await createSupplierAction({
        code: String(formData.get("code") ?? ""),
        name_ar: String(formData.get("name_ar") ?? ""),
        name_en: text("name_en"),
        vat_number: text("vat_number"),
        contact_person: text("contact_person"),
        phone: text("phone"),
        email: text("email"),
        notes: text("notes"),
      });

      if (result.success) {
        toast.success(result.message ?? "تمت الإضافة");
        setOpen(false);
        formRef.current?.reset();
      } else {
        toast.error(result.error);
        setFieldErrors(result.fieldErrors);
      }
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button>
          <Plus className="size-4" />
          مورّد جديد
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>إضافة مورّد</DialogTitle>
          <DialogDescription>رمز المورّد دائم ولا يمكن تعديله بعد الإنشاء. المورّد عام لكل الفروع.</DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="sup_code">الرمز</Label>
              <Input id="sup_code" name="code" dir="ltr" required disabled={isPending} />
              {fieldErrors?.code && <p className="text-xs font-medium text-destructive">{fieldErrors.code[0]}</p>}
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="sup_name_ar">الاسم بالعربية</Label>
              <Input id="sup_name_ar" name="name_ar" required disabled={isPending} />
              {fieldErrors?.name_ar && <p className="text-xs font-medium text-destructive">{fieldErrors.name_ar[0]}</p>}
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="sup_name_en">الاسم بالإنجليزية (اختياري)</Label>
              <Input id="sup_name_en" name="name_en" dir="ltr" disabled={isPending} />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="sup_vat_number">الرقم الضريبي (اختياري)</Label>
              <Input id="sup_vat_number" name="vat_number" dir="ltr" disabled={isPending} />
              {/* Stored exactly as entered and snapshotted onto every invoice.
                  Phase 11 records tax data; it does not validate it against
                  any registry, and does not decide what it entitles. */}
              <p className="text-xs text-muted-foreground">يُحفظ كما يُدخل، ويُلتقط في كل فاتورة شراء لهذا المورّد.</p>
            </div>
          </div>

          <div className="grid grid-cols-3 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="sup_contact">مسؤول التواصل (اختياري)</Label>
              <Input id="sup_contact" name="contact_person" disabled={isPending} />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="sup_phone">الهاتف (اختياري)</Label>
              <Input id="sup_phone" name="phone" dir="ltr" disabled={isPending} />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="sup_email">البريد (اختياري)</Label>
              <Input id="sup_email" name="email" dir="ltr" disabled={isPending} />
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="sup_notes">ملاحظات (اختياري)</Label>
            <Textarea id="sup_notes" name="notes" rows={2} disabled={isPending} />
          </div>

          <DialogFooter>
            <Button type="submit" disabled={isPending}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              حفظ
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

/**
 * Edits a supplier via update_supplier() (migration 0239). The current
 * row_version is always submitted — the RPC rejects a NULL expected version
 * outright, since `row_version <> NULL` would silently bypass the
 * optimistic-concurrency check.
 */
export function SupplierEditDialog({
  supplier,
}: {
  supplier: {
    id: string;
    code: string;
    name_ar: string;
    name_en: string | null;
    vat_number: string | null;
    contact_person: string | null;
    phone: string | null;
    email: string | null;
    notes: string | null;
    row_version: number;
  };
}) {
  const [open, setOpen] = useState(false);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    startTransition(async () => {
      const text = (k: string) => (formData.get(k) ? String(formData.get(k)) : undefined);
      const result = await updateSupplierAction({
        id: supplier.id,
        row_version: supplier.row_version,
        name_ar: String(formData.get("name_ar") ?? ""),
        name_en: text("name_en"),
        vat_number: text("vat_number"),
        contact_person: text("contact_person"),
        phone: text("phone"),
        email: text("email"),
        notes: text("notes"),
      });

      if (result.success) {
        toast.success(result.message ?? "تم التحديث");
        setOpen(false);
      } else {
        toast.error(result.error);
        setFieldErrors(result.fieldErrors);
      }
    });
  }

  const fid = (k: string) => `edit_${k}_${supplier.id}`;

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="ghost" size="sm">
          <Pencil className="size-4" />
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>تعديل المورّد {supplier.code}</DialogTitle>
          <DialogDescription>
            لا يمكن تعديل رمز المورّد بعد الإنشاء. تعديل الاسم أو الرقم الضريبي هنا لا يغيّر الفواتير السابقة — كل فاتورة تحتفظ بنسخة من بيانات المورّد وقت
            ترحيلها.
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor={fid("name_ar")}>الاسم بالعربية</Label>
              <Input id={fid("name_ar")} name="name_ar" defaultValue={supplier.name_ar} required disabled={isPending} />
              {fieldErrors?.name_ar && <p className="text-xs font-medium text-destructive">{fieldErrors.name_ar[0]}</p>}
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor={fid("name_en")}>الاسم بالإنجليزية (اختياري)</Label>
              <Input id={fid("name_en")} name="name_en" dir="ltr" defaultValue={supplier.name_en ?? ""} disabled={isPending} />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor={fid("vat_number")}>الرقم الضريبي (اختياري)</Label>
              <Input id={fid("vat_number")} name="vat_number" dir="ltr" defaultValue={supplier.vat_number ?? ""} disabled={isPending} />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor={fid("contact_person")}>مسؤول التواصل (اختياري)</Label>
              <Input id={fid("contact_person")} name="contact_person" defaultValue={supplier.contact_person ?? ""} disabled={isPending} />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor={fid("phone")}>الهاتف (اختياري)</Label>
              <Input id={fid("phone")} name="phone" dir="ltr" defaultValue={supplier.phone ?? ""} disabled={isPending} />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor={fid("email")}>البريد (اختياري)</Label>
              <Input id={fid("email")} name="email" dir="ltr" defaultValue={supplier.email ?? ""} disabled={isPending} />
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor={fid("notes")}>ملاحظات (اختياري)</Label>
            <Textarea id={fid("notes")} name="notes" rows={2} defaultValue={supplier.notes ?? ""} disabled={isPending} />
          </div>

          <DialogFooter>
            <Button type="submit" disabled={isPending}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              حفظ
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

/** Enable/disable toggle — goes through set_supplier_status() (0239), never a raw table write. A supplier is never deleted, so historical invoices keep resolving. */
export function SupplierStatusToggle({ supplierId, status, supplierName }: { supplierId: string; status: "active" | "disabled"; supplierName: string }) {
  const [isPending, startTransition] = useTransition();

  function handleChange(checked: boolean) {
    startTransition(async () => {
      const result = await setSupplierStatusAction(supplierId, checked ? "active" : "disabled");
      if (result.success) toast.success(result.message ?? "تم التحديث");
      else toast.error(result.error);
    });
  }

  return <Switch checked={status === "active"} onCheckedChange={handleChange} disabled={isPending} aria-label={`تفعيل/تعطيل ${supplierName}`} />;
}
