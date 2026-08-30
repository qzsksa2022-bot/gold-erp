"use client";

import { useEffect } from "react";
import { AlertTriangle } from "lucide-react";
import { Button } from "@/components/ui/button";

/**
 * Root error boundary. Never renders the raw error message/stack to the
 * user (spec 19: "عدم عرض Stack Trace للمستخدم") — logs it to the server
 * console (in a real deployment this is where Sentry/等 would hook in) and
 * shows a calm Arabic message with a retry action instead.
 */
export default function GlobalError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => {
    console.error("[global-error]", error);
  }, [error]);

  return (
    <html lang="ar" dir="rtl">
      <body>
        <div className="flex min-h-screen flex-col items-center justify-center gap-4 px-4 text-center">
          <div className="flex size-16 items-center justify-center rounded-full bg-destructive/10 text-destructive">
            <AlertTriangle className="size-8" />
          </div>
          <div>
            <h1 className="text-lg font-semibold">حدث خطأ غير متوقع</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              الرجاء إعادة المحاولة. إذا استمرت المشكلة، تواصل مع الدعم الفني.
            </p>
            {error.digest && <p className="mt-1 font-mono text-xs text-muted-foreground">رمز الخطأ: {error.digest}</p>}
          </div>
          <Button onClick={reset}>إعادة المحاولة</Button>
        </div>
      </body>
    </html>
  );
}
