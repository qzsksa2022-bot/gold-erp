import { getPublicBranding } from "@/features/settings/queries";
import { LoginForm } from "@/features/auth/components/login-form";
import { Card, CardContent, CardHeader } from "@/components/ui/card";

export default async function LoginPage() {
  const branding = await getPublicBranding();

  return (
    <Card className="w-full max-w-sm">
      <CardHeader className="items-center gap-3 border-b-0 pb-2 pt-8 text-center">
        {branding.logo_url ? (
          // Logo is an admin-uploaded URL of unknown origin (Supabase
          // Storage or any external host), so next/image's static domain
          // allowlist isn't a good fit here.
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={branding.logo_url}
            alt={branding.system_name_ar}
            width={56}
            height={56}
            className="rounded-lg object-contain"
          />
        ) : (
          <div className="flex size-14 items-center justify-center rounded-xl bg-primary text-xl font-bold text-primary-foreground">
            {branding.system_name_ar.trim().charAt(0)}
          </div>
        )}
        <div>
          <h1 className="text-lg font-semibold">{branding.system_name_ar}</h1>
          <p className="mt-1 text-sm text-muted-foreground">تسجيل الدخول إلى حسابك</p>
        </div>
      </CardHeader>
      <CardContent className="pt-6">
        <LoginForm />
      </CardContent>
    </Card>
  );
}
