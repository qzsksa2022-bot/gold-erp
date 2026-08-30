"use client";

import { useRouter, useSearchParams, usePathname } from "next/navigation";
import { useState, useTransition } from "react";
import { Search } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { AUDIT_ACTION_LABELS_AR, AUDIT_ENTITY_LABELS_AR } from "@/lib/audit/action-labels";

export function AuditLogFilters({
  q,
  userId,
  action,
  entityType,
  actors,
}: {
  q: string;
  userId: string;
  action: string;
  entityType: string;
  actors: { id: string; full_name: string }[];
}) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [value, setValue] = useState(q);
  const [, startTransition] = useTransition();

  function updateParams(next: Record<string, string>) {
    const params = new URLSearchParams(searchParams.toString());
    for (const [key, val] of Object.entries(next)) {
      if (val) params.set(key, val);
      else params.delete(key);
    }
    params.set("page", "1");
    startTransition(() => router.push(`${pathname}?${params.toString()}`));
  }

  return (
    <div className="mb-4 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
      <div className="relative">
        <Search className="pointer-events-none absolute start-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
        <Input
          placeholder="بحث..."
          className="ps-9"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && updateParams({ q: value })}
          onBlur={() => updateParams({ q: value })}
        />
      </div>

      <Select value={userId || "all"} onValueChange={(v) => updateParams({ userId: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="المستخدم" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل المستخدمين</SelectItem>
          {actors.map((a) => (
            <SelectItem key={a.id} value={a.id}>
              {a.full_name}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select value={entityType || "all"} onValueChange={(v) => updateParams({ entityType: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="النوع" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل الأنواع</SelectItem>
          {Object.entries(AUDIT_ENTITY_LABELS_AR).map(([key, label]) => (
            <SelectItem key={key} value={key}>
              {label}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select value={action || "all"} onValueChange={(v) => updateParams({ action: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="العملية" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل العمليات</SelectItem>
          {Object.entries(AUDIT_ACTION_LABELS_AR).map(([key, label]) => (
            <SelectItem key={key} value={key}>
              {label}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </div>
  );
}
