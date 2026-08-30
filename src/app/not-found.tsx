import Link from "next/link";
import { FileQuestion } from "lucide-react";
import { Button } from "@/components/ui/button";
import { ROUTES } from "@/lib/constants";

export default function NotFound() {
  return (
    <html lang="ar" dir="rtl">
      <body>
        <div className="flex min-h-screen flex-col items-center justify-center gap-4 px-4 text-center">
          <div className="flex size-16 items-center justify-center rounded-full bg-secondary text-muted-foreground">
            <FileQuestion className="size-8" />
          </div>
          <div>
            <h1 className="text-lg font-semibold">الصفحة غير موجودة</h1>
            <p className="mt-1 text-sm text-muted-foreground">الرابط الذي حاولت الوصول إليه غير موجود.</p>
          </div>
          <Button asChild>
            <Link href={ROUTES.dashboard}>العودة للرئيسية</Link>
          </Button>
        </div>
      </body>
    </html>
  );
}
