"use client";

import { useRef, useState, useTransition } from "react";
import { Loader2, Pencil, Plus } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { createSettlementRouteAction, updateSettlementRouteAction } from "../actions";
import { SETTLEMENT_ROUTE_KINDS, SETTLEMENT_ROUTE_KIND_LABELS_AR } from "../schema";

type Lookup = { id: string; name_ar: string };

type SettlementRoute = {
  id: string;
  code: string;
  name_ar: string;
  name_en: string | null;
  route_kind: string;
  payment_method_id: string | null;
  collection_channel_id: string | null;
  shipping_carrier_id: string | null;
  description: string | null;
};

/**
 * Create/edit dialog for settlement_routes (item 10) — every write goes
 * through create_settlement_route()/update_settlement_route() (0169), never
 * a raw table write. code/route_kind/payment_method_id/collection_channel_
 * id/shipping_carrier_id are permanent once created (item 36) — only shown
 * on create, never editable afterward (mirrors AdjustmentTypeFormDialog's
 * `code` immutability, extended to every matching field here).
 */
export function SettlementRouteFormDialog({
  route,
  paymentMethods,
  collectionChannels,
  shippingCarriers,
}: {
  route?: SettlementRoute;
  paymentMethods: Lookup[];
  collectionChannels: Lookup[];
  shippingCarriers: Lookup[];
}) {
  const isEdit = Boolean(route);
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();
  const [routeKind, setRouteKind] = useState<string>(route?.route_kind ?? "payment_collection");
  const [paymentMethodId, setPaymentMethodId] = useState(route?.payment_method_id ?? "");
  const [collectionChannelId, setCollectionChannelId] = useState(route?.collection_channel_id ?? "");
  const [shippingCarrierId, setShippingCarrierId] = useState(route?.shipping_carrier_id ?? "");

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = isEdit
        ? await updateSettlementRouteAction({
            id: route!.id,
            name_ar: String(formData.get("name_ar") ?? ""),
            name_en: formData.get("name_en") ? String(formData.get("name_en")) : undefined,
            description: formData.get("description") ? String(formData.get("description")) : undefined,
          })
        : await createSettlementRouteAction({
            code: String(formData.get("code") ?? ""),
            name_ar: String(formData.get("name_ar") ?? ""),
            name_en: formData.get("name_en") ? String(formData.get("name_en")) : undefined,
            route_kind: routeKind as "payment_collection" | "cod_carrier",
            payment_method_id: routeKind === "payment_collection" ? paymentMethodId || undefined : undefined,
            collection_channel_id: routeKind === "payment_collection" ? collectionChannelId || undefined : undefined,
            shipping_carrier_id: routeKind === "cod_carrier" ? shippingCarrierId || undefined : undefined,
            description: formData.get("description") ? String(formData.get("description")) : undefined,
          });

      if (result.success) {
        toast.success(result.message ?? "تم الحفظ بنجاح");
        setOpen(false);
        formRef.current?.reset();
        setPaymentMethodId("");
        setCollectionChannelId("");
        setShippingCarrierId("");
      } else {
        toast.error(result.error);
        setFieldErrors(result.fieldErrors);
      }
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        {isEdit ? (
          <Button variant="ghost" size="icon" aria-label="تعديل مسار التسوية">
            <Pencil className="size-4" />
          </Button>
        ) : (
          <Button variant="accent">
            <Plus className="size-4" />
            إضافة مسار تسوية
          </Button>
        )}
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{isEdit ? "تعديل مسار تسوية" : "إضافة مسار تسوية جديد"}</DialogTitle>
          <DialogDescription>
            {isEdit ? "تحديث الاسم والوصف فقط. الرمز ونوع المسار وطريقة الدفع/قناة التحصيل/شركة الشحن غير قابلة للتعديل بعد الإنشاء." : "الرمز ونوع المسار ومعايير المطابقة تصبح دائمة بعد الإنشاء — لتصحيحها لاحقًا، عطّل هذا المسار وأنشئ بديلًا."}
          </DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          {!isEdit && (
            <>
              <div className="flex flex-col gap-1.5">
                <Label htmlFor="code">الرمز (إنجليزي، بلا مسافات)</Label>
                <Input id="code" name="code" placeholder="cash_riyadh_branch" required dir="ltr" disabled={isPending} />
                {fieldErrors?.code && <p className="text-xs font-medium text-destructive">{fieldErrors.code[0]}</p>}
              </div>

              <div className="flex flex-col gap-1.5">
                <Label>نوع مسار التسوية</Label>
                <Select value={routeKind} onValueChange={setRouteKind} disabled={isPending}>
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {SETTLEMENT_ROUTE_KINDS.map((k) => (
                      <SelectItem key={k} value={k}>
                        {SETTLEMENT_ROUTE_KIND_LABELS_AR[k]}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              {routeKind === "payment_collection" ? (
                <>
                  <div className="flex flex-col gap-1.5">
                    <Label>طريقة الدفع</Label>
                    <Select value={paymentMethodId} onValueChange={setPaymentMethodId} disabled={isPending}>
                      <SelectTrigger>
                        <SelectValue placeholder="اختر طريقة الدفع" />
                      </SelectTrigger>
                      <SelectContent>
                        {paymentMethods.map((p) => (
                          <SelectItem key={p.id} value={p.id}>
                            {p.name_ar}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                    {fieldErrors?.payment_method_id && <p className="text-xs font-medium text-destructive">{fieldErrors.payment_method_id[0]}</p>}
                    {paymentMethods.length === 0 && <p className="text-xs text-warning">لا تظهر أي طريقة دفع — تحقق من صلاحية إدارة مسارات التسوية (settlements.manage_routes).</p>}
                  </div>
                  <div className="flex flex-col gap-1.5">
                    <Label>قناة التحصيل (اختياري — تركها بدون قناة تحصيل يطابق فقط المصادر التي ليس لها قناة تحصيل محددة لهذه الطريقة، وليس كل القنوات)</Label>
                    <Select value={collectionChannelId || "none"} onValueChange={(v) => setCollectionChannelId(v === "none" ? "" : v)} disabled={isPending}>
                      <SelectTrigger>
                        <SelectValue placeholder="بدون قناة تحصيل" />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="none">بدون قناة تحصيل (مطابقة حصرية للمصادر بلا قناة — ليست كل القنوات)</SelectItem>
                        {collectionChannels.map((c) => (
                          <SelectItem key={c.id} value={c.id}>
                            {c.name_ar}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </div>
                </>
              ) : (
                <div className="flex flex-col gap-1.5">
                  <Label>شركة الشحن</Label>
                  <Select value={shippingCarrierId} onValueChange={setShippingCarrierId} disabled={isPending}>
                    <SelectTrigger>
                      <SelectValue placeholder="اختر شركة الشحن" />
                    </SelectTrigger>
                    <SelectContent>
                      {shippingCarriers.map((c) => (
                        <SelectItem key={c.id} value={c.id}>
                          {c.name_ar}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  {fieldErrors?.shipping_carrier_id && <p className="text-xs font-medium text-destructive">{fieldErrors.shipping_carrier_id[0]}</p>}
                  {shippingCarriers.length === 0 && <p className="text-xs text-warning">لا تظهر أي شركة شحن — تحقق من صلاحية إدارة مسارات التسوية (settlements.manage_routes).</p>}
                </div>
              )}
            </>
          )}

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="name_ar">الاسم بالعربية</Label>
            <Input id="name_ar" name="name_ar" defaultValue={route?.name_ar} required disabled={isPending} />
            {fieldErrors?.name_ar && <p className="text-xs font-medium text-destructive">{fieldErrors.name_ar[0]}</p>}
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="name_en">الاسم بالإنجليزية (اختياري)</Label>
            <Input id="name_en" name="name_en" defaultValue={route?.name_en ?? ""} disabled={isPending} />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="description">الوصف (اختياري)</Label>
            <Textarea id="description" name="description" defaultValue={route?.description ?? ""} disabled={isPending} rows={2} />
          </div>

          <DialogFooter>
            <Button type="submit" disabled={isPending}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              {isEdit ? "حفظ التعديلات" : "إضافة المسار"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
