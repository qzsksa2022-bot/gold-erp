import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Can } from "@/lib/permissions/context";
import { listAllPermissions, listAllRoles, getRolePermissionIds, countUsersForRole } from "../queries";
import { RoleFormDialog } from "./role-form-dialog";
import { RolePermissionsEditor } from "./role-permissions-editor";
import { RoleDeleteButton } from "./role-delete-button";

export async function RolesPanel() {
  const [roles, allPermissions] = await Promise.all([listAllRoles(), listAllPermissions()]);

  const rolesWithMeta = await Promise.all(
    roles.map(async (role) => ({
      role,
      permissionIds: await getRolePermissionIds(role.id),
      userCount: await countUsersForRole(role.id),
    })),
  );

  return (
    <div>
      <div className="mb-4 flex justify-end">
        <Can permission="users.manage_permissions">
          <RoleFormDialog />
        </Can>
      </div>

      <div className="rounded-xl border border-border bg-card">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>الدور</TableHead>
              <TableHead className="hidden sm:table-cell">النوع</TableHead>
              <TableHead className="hidden sm:table-cell">عدد المستخدمين</TableHead>
              <TableHead className="w-32 text-left">إجراءات</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rolesWithMeta.map(({ role, permissionIds, userCount }) => (
              <TableRow key={role.id}>
                <TableCell>
                  <div className="flex flex-col">
                    <span className="font-medium">{role.name_ar}</span>
                    {role.description_ar && <span className="text-xs text-muted-foreground">{role.description_ar}</span>}
                  </div>
                </TableCell>
                <TableCell className="hidden sm:table-cell">
                  <Badge variant={role.is_system ? "outline" : "accent"}>{role.is_system ? "نظامي" : "مخصص"}</Badge>
                </TableCell>
                <TableCell className="hidden sm:table-cell">{userCount}</TableCell>
                <TableCell>
                  <div className="flex items-center justify-end gap-1">
                    <Can permission="users.manage_permissions">
                      <RolePermissionsEditor role={role} allPermissions={allPermissions} assignedPermissionIds={permissionIds} />
                      <RoleFormDialog role={role} />
                      {!role.is_system && <RoleDeleteButton roleId={role.id} roleName={role.name_ar} userCount={userCount} />}
                    </Can>
                  </div>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    </div>
  );
}
