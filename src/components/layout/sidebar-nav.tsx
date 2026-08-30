"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";
import { NAV_ITEMS } from "./nav-items";
import { usePermissions } from "@/lib/permissions/context";

export function SidebarNav({ onNavigate }: { onNavigate?: () => void }) {
  const pathname = usePathname();
  const { can, canAny } = usePermissions();

  const items = NAV_ITEMS.filter((item) => (item.anyOf ? canAny(item.anyOf) : item.permission ? can(item.permission) : false));

  return (
    <nav className="flex flex-1 flex-col gap-1 overflow-y-auto px-3 py-2">
      {items.map((item) => {
        const active = pathname === item.href || pathname.startsWith(`${item.href}/`);
        const Icon = item.icon;
        return (
          <Link
            key={item.href}
            href={item.href}
            onClick={onNavigate}
            className={cn(
              "group flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium transition-colors",
              active
                ? "bg-sidebar-accent text-sidebar-accent-foreground"
                : "text-sidebar-foreground/80 hover:bg-sidebar-accent/60 hover:text-sidebar-foreground",
            )}
          >
            <Icon className="size-[18px] shrink-0" />
            <span className="flex-1 truncate">{item.label}</span>
            {item.comingSoon && (
              <Badge variant="outline" className="border-sidebar-border px-1.5 py-0 text-[10px] text-sidebar-foreground/60">
                قريبًا
              </Badge>
            )}
          </Link>
        );
      })}
    </nav>
  );
}
