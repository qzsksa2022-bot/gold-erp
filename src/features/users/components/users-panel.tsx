import { Users as UsersIcon } from "lucide-react";
import Link from "next/link";
import { listUsers, attachLastSignIn } from "../queries";
import { listActiveStoresForSelect } from "@/features/stores/queries";
import { listSearchParamsSchema } from "@/lib/validation/common";
import { EmptyState } from "@/components/shared/empty-state";
import { Pagination } from "@/components/shared/pagination";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Can } from "@/lib/permissions/context";
import { CreateUserDialog } from "./create-user-dialog";
import { UserStatusBadge } from "./user-status-badge";
import { UserStatusToggle } from "./user-status-toggle";
import { UsersToolbar } from "./users-toolbar";
import { formatRelativeArabic } from "@/lib/date";

export async function UsersPanel({ sp }: { sp: Record<string, string | string[] | undefined> }) {
  const { q, page, pageSize } = listSearchParamsSchema.parse(sp);
  const status = (typeof sp.status === "string" ? sp.status : "all") as "all" | "active" | "suspended" | "pending_setup";

  const [{ users, total }, stores] = await Promise.all([
    listUsers({ q, status, page, pageSize }),
    listActiveStoresForSelect(),
  ]);
  const usersWithLastSignIn = await attachLastSignIn(users);

  return (
    <div>
      <div className="mb-4 flex justify-end">
        <Can permission="users.create">
          <CreateUserDialog stores={stores} />
        </Can>
      </div>

      <UsersToolbar q={q} status={status} />

      {users.length === 0 ? (
        <EmptyState
          icon={UsersIcon}
          title="لا يوجد مستخدمون مطابقون"
          description={q || status !== "all" ? "جرّب تعديل كلمة البحث أو الفلتر." : "ابدأ بإنشاء أول مستخدم."}
        />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>المستخدم</TableHead>
                <TableHead className="hidden md:table-cell">الدور</TableHead>
                <TableHead className="hidden lg:table-cell">المتجر الافتراضي</TableHead>
                <TableHead>الحالة</TableHead>
                <TableHead className="hidden md:table-cell">آخر دخول</TableHead>
                <TableHead className="w-20 text-left">إجراءات</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {usersWithLastSignIn.map((user) => (
                <TableRow key={user.id}>
                  <TableCell>
                    <Link href={`/users/${user.id}`} className="flex flex-col hover:underline">
                      <span className="font-medium">{user.full_name}</span>
                      <span className="text-xs text-muted-foreground">{user.email}</span>
                    </Link>
                  </TableCell>
                  <TableCell className="hidden md:table-cell">
                    <div className="flex flex-wrap gap-1">
                      {user.roles.length === 0 ? (
                        <span className="text-xs text-muted-foreground">بدون دور</span>
                      ) : (
                        user.roles.map((r) => (
                          <Badge key={r.id} variant="outline">
                            {r.name_ar}
                          </Badge>
                        ))
                      )}
                    </div>
                  </TableCell>
                  <TableCell className="hidden text-sm text-muted-foreground lg:table-cell">
                    {user.defaultStoreName ?? "—"}
                  </TableCell>
                  <TableCell>
                    <UserStatusBadge status={user.status} />
                  </TableCell>
                  <TableCell className="hidden text-sm text-muted-foreground md:table-cell">
                    {user.lastSignInAt ? formatRelativeArabic(user.lastSignInAt) : "لم يسجل الدخول بعد"}
                  </TableCell>
                  <TableCell>
                    <Can permission="users.disable">
                      <UserStatusToggle
                        userId={user.id}
                        status={user.status}
                        provisionedAt={user.provisioned_at}
                        userName={user.full_name}
                      />
                    </Can>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          <Pagination
            page={page}
            pageSize={pageSize}
            total={total}
            buildHref={(p) => `/users?${new URLSearchParams({ q, status, page: String(p) }).toString()}`}
          />
        </div>
      )}
    </div>
  );
}
