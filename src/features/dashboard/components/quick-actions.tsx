import Link from "next/link";
import { Store, UserPlus, ScrollText } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Can } from "@/lib/permissions/context";
import { Button } from "@/components/ui/button";

export function QuickActions() {
  return (
    <Card>
      <CardHeader>
        <CardTitle>إجراءات سريعة</CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-2">
        <Can permission="stores.create">
          <Button asChild variant="outline" className="justify-start">
            <Link href="/stores">
              <Store className="size-4" />
              إضافة متجر جديد
            </Link>
          </Button>
        </Can>
        <Can permission="users.create">
          <Button asChild variant="outline" className="justify-start">
            <Link href="/users">
              <UserPlus className="size-4" />
              إنشاء مستخدم جديد
            </Link>
          </Button>
        </Can>
        <Can permission="audit_logs.view">
          <Button asChild variant="outline" className="justify-start">
            <Link href="/audit-log">
              <ScrollText className="size-4" />
              مراجعة سجل الأحداث
            </Link>
          </Button>
        </Can>
        <Can anyOf={["stores.create", "users.create", "audit_logs.view"]} fallback={
          <p className="text-sm text-muted-foreground">لا توجد إجراءات سريعة متاحة لصلاحياتك الحالية.</p>
        }>
          <></>
        </Can>
      </CardContent>
    </Card>
  );
}
