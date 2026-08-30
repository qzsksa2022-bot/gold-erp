import { Hammer } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { listManufacturingFeeOverview, listManufacturingFeeHistory } from "@/features/manufacturing-fees/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { ManufacturingFeeCard } from "@/features/manufacturing-fees/components/manufacturing-fee-card";

export default async function ManufacturingFeesPage() {
  await requirePermission("manufacturing_fees.view");

  const overview = await listManufacturingFeeOverview();
  const historyByKarat = await Promise.all(overview.map((row) => listManufacturingFeeHistory(row.karat.id)));

  return (
    <div>
      <PageHeader
        title="المصنعية حسب العيار"
        description="المصنعية مرتبطة بالعيار، وتُدار كإصدارات زمنية — لا يمكن تعديل قيمة سبق تطبيقها، فقط إضافة إصدار جديد اعتبارًا من تاريخ سريان محدد."
      />

      {overview.length === 0 ? (
        <EmptyState icon={Hammer} title="لا توجد عيارات" description="أضف عيارًا واحدًا على الأقل من صفحة العيارات أولًا." />
      ) : (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {overview.map((row, i) => (
            <ManufacturingFeeCard
              key={row.karat.id}
              karat={row.karat}
              currentVersion={row.currentVersion}
              upcomingVersion={row.upcomingVersion}
              history={historyByKarat[i]}
            />
          ))}
        </div>
      )}
    </div>
  );
}
