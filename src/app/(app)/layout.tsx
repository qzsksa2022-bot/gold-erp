import { requireSession } from "@/lib/permissions/guard";
import { getPublicBranding } from "@/features/settings/queries";
import { PermissionsProvider } from "@/lib/permissions/context";
import { AppShell } from "@/components/layout/app-shell";

export default async function AuthenticatedLayout({ children }: { children: React.ReactNode }) {
  const [session, branding] = await Promise.all([requireSession(), getPublicBranding()]);

  return (
    <PermissionsProvider permissions={[...session.permissions]} isSuperAdmin={session.isSuperAdmin}>
      <AppShell
        systemNameAr={branding.system_name_ar}
        logoUrl={branding.logo_url}
        fullName={session.profile.full_name}
        email={session.email}
      >
        {children}
      </AppShell>
    </PermissionsProvider>
  );
}
