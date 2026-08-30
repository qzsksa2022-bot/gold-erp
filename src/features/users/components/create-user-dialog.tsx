"use client";

import { useRef, useState, useTransition } from "react";
import { Loader2, Plus } from "lucide-react";
import { toast } from "sonner";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { createUserAction } from "../actions";
import { ROUTES } from "@/lib/constants";

export function CreateUserDialog({ stores }: { stores: { id: string; name_ar: string }[] }) {
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const router = useRouter();
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = await createUserAction(null, formData);
      if (result.success) {
        toast.success(result.message ?? "تم إنشاء المستخدم");
        setOpen(false);
        formRef.current?.reset();
        router.push(`${ROUTES.users}/${result.data.id}`);
      } else {
        toast.error(result.error);
        setFieldErrors(result.fieldErrors);
      }
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="accent">
          <Plus className="size-4" />
          إنشاء مستخدم
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>إنشاء مستخدم جديد</DialogTitle>
          <DialogDescription>
            بعد الإنشاء يمكنك إسناد دور وضبط الصلاحيات من صفحة المستخدم.
          </DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="flex flex-col gap-1.5">
            <Label htmlFor="full_name">الاسم الكامل</Label>
            <Input id="full_name" name="full_name" required disabled={isPending} />
            {fieldErrors?.full_name && <p className="text-xs font-medium text-destructive">{fieldErrors.full_name[0]}</p>}
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="email">البريد الإلكتروني</Label>
            <Input id="email" name="email" type="email" required disabled={isPending} />
            {fieldErrors?.email && <p className="text-xs font-medium text-destructive">{fieldErrors.email[0]}</p>}
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="password">كلمة مرور مؤقتة</Label>
            <Input id="password" name="password" type="password" minLength={8} required disabled={isPending} />
            {fieldErrors?.password && <p className="text-xs font-medium text-destructive">{fieldErrors.password[0]}</p>}
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="default_store_id">المتجر الافتراضي</Label>
              <Select name="default_store_id">
                <SelectTrigger id="default_store_id">
                  <SelectValue placeholder="بدون" />
                </SelectTrigger>
                <SelectContent>
                  {stores.map((s) => (
                    <SelectItem key={s.id} value={s.id}>
                      {s.name_ar}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="store_access_scope">نطاق الوصول للمتاجر</Label>
              <Select name="store_access_scope" defaultValue="single">
                <SelectTrigger id="store_access_scope">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="single">متجر واحد فقط</SelectItem>
                  <SelectItem value="multiple">مجموعة متاجر محددة</SelectItem>
                  <SelectItem value="all">جميع المتاجر</SelectItem>
                </SelectContent>
              </Select>
            </div>
          </div>

          <DialogFooter>
            <Button type="submit" disabled={isPending}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              إنشاء المستخدم
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
