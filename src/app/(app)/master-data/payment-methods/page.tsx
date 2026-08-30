import { CreditCard } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { listPaymentMethodsOverview, listPaymentMethodFeeHistory } from "@/features/payment-methods/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Can } from "@/lib/permissions/context";
import { PaymentMethodFormDialog } from "@/features/payment-methods/components/payment-method-form-dialog";
import { PaymentMethodCard } from "@/features/payment-methods/components/payment-method-card";

export default async function PaymentMethodsPage() {
  await requirePermission("payment_methods.view");

  const overview = await listPaymentMethodsOverview();
  const historyByMethod = await Promise.all(overview.map((row) => listPaymentMethodFeeHistory(row.method.id)));

  return (
    <div>
      <PageHeader
        title="طرق الدفع والعمولات"
        description="عمولة كل طريقة دفع تُدار كإصدارات زمنية — لا يمكن تعديل عمولة سبق تطبيقها، فقط إضافة إصدار جديد اعتبارًا من تاريخ سريان محدد."
        actions={
          <Can permission="payment_methods.manage">
            <PaymentMethodFormDialog />
          </Can>
        }
      />

      {overview.length === 0 ? (
        <EmptyState icon={CreditCard} title="لا توجد طرق دفع بعد" description="ابدأ بإضافة أول طريقة دفع." />
      ) : (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {overview.map((row, i) => (
            <PaymentMethodCard
              key={row.method.id}
              method={row.method}
              currentVersion={row.currentVersion}
              upcomingVersion={row.upcomingVersion}
              history={historyByMethod[i]}
            />
          ))}
        </div>
      )}
    </div>
  );
}
