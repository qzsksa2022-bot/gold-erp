import { HandCoins } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { getSettlementRouteLookups } from "@/features/settlements/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { SettlementDraftCreateForm } from "@/features/settlements/components/settlement-draft-create-form";

export default async function NewSettlementPage() {
  await requirePermission("settlements.create");

  const routes = await getSettlementRouteLookups();

  if (routes.length === 0) {
    return (
      <div>
        <PageHeader title="تسوية جديدة" description="ابدأ دفعة تسوية جديدة." />
        <EmptyState icon={HandCoins} title="لا يوجد مسار تسوية نشط" description="لم يتم إعداد أي مسار تسوية نشط بعد — تواصل مع مدير النظام لإضافة مسار من صفحة البيانات الأساسية." />
      </div>
    );
  }

  return (
    <div>
      <PageHeader title="تسوية جديدة" description="أنشئ مسودة دفعة تسوية، ثم اختر المصادر غير المسوّاة قبل الاعتماد." />
      <SettlementDraftCreateForm routes={routes} />
    </div>
  );
}
