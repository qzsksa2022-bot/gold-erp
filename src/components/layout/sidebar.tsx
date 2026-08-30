import { SidebarNav } from "./sidebar-nav";

export function Sidebar({ systemNameAr, logoUrl }: { systemNameAr: string; logoUrl: string | null }) {
  return (
    <aside className="hidden w-64 shrink-0 flex-col border-e border-sidebar-border bg-sidebar text-sidebar-foreground lg:flex">
      <div className="flex items-center gap-2.5 border-b border-sidebar-border px-5 py-5">
        {logoUrl ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={logoUrl} alt={systemNameAr} className="size-8 rounded-md object-contain" />
        ) : (
          <div className="flex size-8 items-center justify-center rounded-md bg-sidebar-accent text-sm font-bold text-sidebar-accent-foreground">
            {systemNameAr.trim().charAt(0)}
          </div>
        )}
        <span className="truncate text-sm font-semibold">{systemNameAr}</span>
      </div>
      <SidebarNav />
    </aside>
  );
}
