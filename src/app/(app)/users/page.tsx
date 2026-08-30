import { requirePermission } from "@/lib/permissions/guard";
import { PageHeader } from "@/components/shared/page-header";
import { UsersPanel } from "@/features/users/components/users-panel";
import { RolesPanel } from "@/features/users/components/roles-panel";
import { UsersTabs } from "@/features/users/components/users-tabs";

export default async function UsersPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  await requirePermission("users.view");
  const sp = await searchParams;

  return (
    <div>
      <PageHeader title="المستخدمون والصلاحيات" description="إدارة حسابات الموظفين، الأدوار، والصلاحيات التفصيلية." />
      <UsersTabs usersPanel={<UsersPanel sp={sp} />} rolesPanel={<RolesPanel />} />
    </div>
  );
}
