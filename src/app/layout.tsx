import type { Metadata } from "next";
import "./globals.css";
import { getPublicBranding } from "@/features/settings/queries";
import { buildThemeStyle } from "@/lib/theme/runtime";
import { Toaster } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";

export async function generateMetadata(): Promise<Metadata> {
  const branding = await getPublicBranding();
  return {
    title: branding.system_name_ar,
    description: branding.system_name_ar,
  };
}

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const branding = await getPublicBranding();

  return (
    <html lang="ar" dir="rtl" className="h-full" style={buildThemeStyle(branding)}>
      <body className="flex min-h-full flex-col antialiased">
        <TooltipProvider delayDuration={300}>
          {children}
          <Toaster />
        </TooltipProvider>
      </body>
    </html>
  );
}
