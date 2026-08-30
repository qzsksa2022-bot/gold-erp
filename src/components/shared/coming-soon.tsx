import type { LucideIcon } from "lucide-react";
import { Sparkles } from "lucide-react";
import { PageHeader } from "./page-header";

/**
 * Deliberately calm placeholder for modules not built yet (spec 13/27:
 * "لا تجعل صفحات Coming Soon مزعجة"). No fake data, no countdown gimmicks —
 * just confirms the page exists (so navigation/permissions can already be
 * wired end-to-end) and sets expectations.
 */
export function ComingSoon({ title, icon: Icon = Sparkles }: { title: string; icon?: LucideIcon }) {
  return (
    <div>
      <PageHeader title={title} />
      <div className="flex flex-col items-center justify-center gap-4 rounded-xl border border-dashed border-border px-6 py-24 text-center">
        <div className="flex size-14 items-center justify-center rounded-full bg-accent/10 text-accent">
          <Icon className="size-7" />
        </div>
        <div>
          <p className="text-base font-semibold">هذا القسم قيد التطوير</p>
          <p className="mt-1 text-sm text-muted-foreground">سيتم تفعيل {title} في مرحلة لاحقة من المشروع.</p>
        </div>
      </div>
    </div>
  );
}
