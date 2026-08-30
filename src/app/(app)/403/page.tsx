import Link from "next/link";
import { ShieldAlert } from "lucide-react";
import { Button } from "@/components/ui/button";
import { ROUTES } from "@/lib/constants";

export default function ForbiddenPage() {
  return (
    <div className="flex flex-col items-center justify-center gap-4 py-24 text-center">
      <div className="flex size-16 items-center justify-center rounded-full bg-destructive/10 text-destructive">
        <ShieldAlert className="size-8" />
      </div>
      <div>
        <h1 className="text-lg font-semibold">لا تملك صلاحية الوصول لهذه الصفحة</h1>
        <p className="mt-1 text-sm text-muted-foreground">إذا كنت تعتقد أن هذا خطأ، تواصل مع مدير النظام لمراجعة صلاحياتك.</p>
      </div>
      <Button asChild>
        <Link href={ROUTES.dashboard}>العودة للرئيسية</Link>
      </Button>
    </div>
  );
}
