import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import {
  getUserDetail,
  listAllRoles,
  listAllPermissions,
  getPermissionIdsForRoles,
  listManageableStoresForActor,
} from "@/features/users/queries";
import { selectableStoreAccessIds } from "@/features/users/store-access-helpers";
import { PageHeader } from "@/components/shared/page-header";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { UserStatusBadge } from "@/features/users/components/user-status-badge";
import { Can } from "@/lib/permissions/context";
import { UserStatusToggle } from "@/features/users/components/user-status-toggle";
import { UserEditForm } from "@/features/users/components/user-edit-form";
import { UserStoreScopeForm } from "@/features/users/components/user-store-scope-form";
import { UserRolesEditor } from "@/features/users/components/user-roles-editor";
import { UserStoreAccessEditor } from "@/features/users/components/user-store-access-editor";
import { UserPermissionOverridesEditor } from "@/features/users/components/user-permission-overrides-editor";

export default async function UserDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const session = await requirePermission("users.view");
  const { id } = await params;

  const detail = await getUserDetail(id);
  if (!detail) notFound();

  const [allRoles, allPermissions, manageableStores] = await Promise.all([
    listAllRoles(),
    listAllPermissions(),
    listManageableStoresForActor(),
  ]);

  const fromRolePermissionIds = await getPermissionIdsForRoles(detail.roles.map((r) => r!.id));
  const overridesMap = new Map(detail.overrides.map((o) => [o.permission_id, o.effect as "grant" | "revoke"]));

  const canEdit = sessionHasPermission(session, "users.edit");
  const canManagePermissions = sessionHasPermission(session, "users.manage_permissions");
  // Patch 1.4.1, item 1: Store Scope AND Store Access are now BOTH gated by
  // users.manage_store_access alone, at every layer (RLS, triggers, this
  // Server Action guard, and this readOnly flag) — supabase/migrations/0037
  // closed the users.manage_permissions overlap that used to also let a
  // manage_permissions holder write user_store_access rows. The two
  // responsibilities are fully independent now: users.manage_permissions
  // governs roles/role_permissions/user_roles/user_permission_overrides
  // only.
  const canManageStoreAccess = sessionHasPermission(session, "users.manage_store_access");

  return (
    <div className="flex flex-col gap-6">
      <PageHeader
        title={detail.profile.full_name}
        description={detail.profile.email}
        actions={
          <div className="flex items-center gap-2">
            <UserStatusBadge status={detail.profile.status} />
            <Can permission="users.disable">
              <UserStatusToggle
                userId={id}
                status={detail.profile.status}
                provisionedAt={detail.profile.provisioned_at}
                userName={detail.profile.full_name}
              />
            </Can>
          </div>
        }
      />

      <Card>
        <CardHeader>
          <CardTitle>المعلومات الأساسية</CardTitle>
          <CardDescription>الاسم الكامل.</CardDescription>
        </CardHeader>
        <CardContent>
          <UserEditForm userId={id} profile={detail.profile} readOnly={!canEdit} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>نطاق الوصول للمتاجر (Store Scope)</CardTitle>
          <CardDescription>المتجر الافتراضي، ونطاق الوصول للمتاجر.</CardDescription>
        </CardHeader>
        <CardContent>
          <UserStoreScopeForm userId={id} profile={detail.profile} stores={manageableStores} readOnly={!canManageStoreAccess} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>الأدوار</CardTitle>
          <CardDescription>الأدوار المُسندة لهذا المستخدم.</CardDescription>
        </CardHeader>
        <CardContent>
          <UserRolesEditor
            userId={id}
            assignedRoles={detail.roles.filter(Boolean) as NonNullable<(typeof detail.roles)[number]>[]}
            allRoles={allRoles}
            readOnly={!canManagePermissions}
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>وصول المتاجر</CardTitle>
          <CardDescription>تُستخدم عند اختيار نطاق &quot;مجموعة متاجر محددة&quot; أعلاه.</CardDescription>
        </CardHeader>
        <CardContent>
          <UserStoreAccessEditor
            userId={id}
            scope={detail.profile.store_access_scope}
            allStores={manageableStores}
            initiallySelected={selectableStoreAccessIds(
              detail.storeAccessIds,
              manageableStores.map((s) => s.id),
            )}
            readOnly={!canManageStoreAccess}
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>الصلاحيات الفردية</CardTitle>
          <CardDescription>منح أو سحب صلاحية محددة لهذا المستخدم بشكل مستقل عن دوره.</CardDescription>
        </CardHeader>
        <CardContent>
          <UserPermissionOverridesEditor
            userId={id}
            allPermissions={allPermissions}
            fromRolePermissionIds={fromRolePermissionIds}
            initialOverrides={overridesMap}
            readOnly={!canManagePermissions}
          />
        </CardContent>
      </Card>
    </div>
  );
}
