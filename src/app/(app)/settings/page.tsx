import { requirePermission } from "@/lib/permissions/guard";
import { getAllSettings } from "@/features/settings/queries";
import { PageHeader } from "@/components/shared/page-header";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { GeneralSettingsForm } from "@/features/settings/components/general-settings-form";
import { AppearanceSettingsForm } from "@/features/settings/components/appearance-settings-form";
import { SecuritySettingsForm } from "@/features/settings/components/security-settings-form";

export default async function SettingsPage() {
  await requirePermission("settings.manage");
  const { general, appearance, security } = await getAllSettings();

  return (
    <div>
      <PageHeader title="الإعدادات" description="إعدادات النظام العامة، والمظهر، والأمان." />

      <Tabs defaultValue="general">
        <TabsList>
          <TabsTrigger value="general">عام</TabsTrigger>
          <TabsTrigger value="appearance">المظهر</TabsTrigger>
          <TabsTrigger value="security">الأمان</TabsTrigger>
        </TabsList>

        <TabsContent value="general">
          <Card>
            <CardHeader>
              <CardTitle>الإعدادات العامة</CardTitle>
              <CardDescription>اسم النظام، العملة، والمنطقة الزمنية.</CardDescription>
            </CardHeader>
            <CardContent>
              <GeneralSettingsForm settings={general} />
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="appearance">
          <Card>
            <CardHeader>
              <CardTitle>المظهر والعلامة التجارية</CardTitle>
              <CardDescription>الشعار، لون العلامة، والخط — تنعكس فورًا على كامل النظام.</CardDescription>
            </CardHeader>
            <CardContent>
              <AppearanceSettingsForm settings={appearance} />
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="security">
          <Card>
            <CardHeader>
              <CardTitle>الأمان</CardTitle>
              <CardDescription>إعدادات مرتبطة بجلسات الدخول والحماية المستقبلية.</CardDescription>
            </CardHeader>
            <CardContent>
              <SecuritySettingsForm settings={security} />
            </CardContent>
          </Card>
        </TabsContent>
      </Tabs>
    </div>
  );
}
