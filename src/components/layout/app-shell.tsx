import { Sidebar } from "./sidebar";
import { Header } from "./header";

export function AppShell({
  systemNameAr,
  logoUrl,
  fullName,
  email,
  children,
}: {
  systemNameAr: string;
  logoUrl: string | null;
  fullName: string;
  email: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex min-h-screen w-full">
      <Sidebar systemNameAr={systemNameAr} logoUrl={logoUrl} />
      <div className="flex min-w-0 flex-1 flex-col">
        <Header systemNameAr={systemNameAr} fullName={fullName} email={email} />
        <main className="flex-1 px-4 py-6 sm:px-6 lg:px-8">
          <div className="mx-auto w-full max-w-7xl">{children}</div>
        </main>
      </div>
    </div>
  );
}
