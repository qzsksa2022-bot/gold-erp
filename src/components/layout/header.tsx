import { Bell, Search } from "lucide-react";
import { MobileNav } from "./mobile-nav";
import { UserMenu } from "./user-menu";
import { Button } from "@/components/ui/button";

export function Header({
  systemNameAr,
  fullName,
  email,
}: {
  systemNameAr: string;
  fullName: string;
  email: string;
}) {
  return (
    <header className="sticky top-0 z-30 flex h-16 items-center gap-3 border-b border-border bg-background/80 px-4 backdrop-blur supports-[backdrop-filter]:bg-background/60 sm:px-6">
      <MobileNav systemNameAr={systemNameAr} />

      {/* Global search — placeholder only in this phase, wired to real
          search once Sales/Reports data exists. */}
      <div className="hidden max-w-sm flex-1 items-center gap-2 rounded-md border border-input bg-secondary/50 px-3 py-2 text-sm text-muted-foreground sm:flex">
        <Search className="size-4" />
        <span>بحث سريع...</span>
      </div>

      <div className="flex flex-1 items-center justify-end gap-2">
        <Button variant="ghost" size="icon" aria-label="الإشعارات" className="relative">
          <Bell className="size-5" />
        </Button>
        <div className="mx-1 h-6 w-px bg-border" />
        <UserMenu fullName={fullName} email={email} />
      </div>
    </header>
  );
}
