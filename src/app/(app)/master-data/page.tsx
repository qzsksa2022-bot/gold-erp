import Link from "next/link";
import { Gem, Hammer, FolderTree, CreditCard, Landmark, Truck, Wrench, Route, Tags, ChevronLeft } from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { requireAnyPermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import { PageHeader } from "@/components/shared/page-header";
import { ROUTES } from "@/lib/constants";
import type { PermissionKey } from "@/lib/permissions/constants";

const SECTIONS: { title: string; description: string; href: string; icon: LucideIcon; permission: PermissionKey }[] = [
  {
    title: "العيارات",
    description: "عيارات الذهب المستخدمة في أسعار الذهب والمصنعية.",
    href: ROUTES.masterDataKarats,
    icon: Gem,
    permission: "karats.view",
  },
  {
    title: "المصنعية حسب العيار",
    description: "أسعار المصنعية لكل عيار، بإصدارات زمنية موثقة.",
    href: ROUTES.masterDataManufacturingFees,
    icon: Hammer,
    permission: "manufacturing_fees.view",
  },
  {
    title: "تصنيفات المنتجات",
    description: "شجرة تصنيفات رئيسية وفرعية بلا حد للعمق.",
    href: ROUTES.masterDataCategories,
    icon: FolderTree,
    permission: "categories.view",
  },
  {
    title: "طرق الدفع والعمولات",
    description: "طرق الدفع ونسب عمولاتها، بإصدارات زمنية موثقة.",
    href: ROUTES.masterDataPaymentMethods,
    icon: CreditCard,
    permission: "payment_methods.view",
  },
  {
    title: "قنوات التحصيل",
    description: "قنوات تحصيل المبيعات، مستقلة عن طرق الدفع.",
    href: ROUTES.masterDataCollectionChannels,
    icon: Landmark,
    permission: "collection_channels.view",
  },
  {
    title: "شركات وتسعير الشحن",
    description: "شركات الشحن والمناطق، وتسعير الشحن ورسوم إرجاع العميل بإصدارات زمنية موثقة.",
    href: ROUTES.masterDataShippingRates,
    icon: Truck,
    permission: "shipping_rates.view",
  },
  {
    title: "أنواع التعديلات والخدمات",
    description: "أنواع خدمات ما بعد البيع القابلة للاختيار عند إنشاء تعديل/خدمة جديد.",
    href: ROUTES.masterDataAdjustmentTypes,
    icon: Wrench,
    permission: "adjustments.manage_types",
  },
  {
    title: "تصنيفات المصروفات",
    description: "أنواع المصروفات التشغيلية القابلة للاختيار عند تسجيل مصروف لفرع.",
    href: ROUTES.expenseCategories,
    icon: Tags,
    permission: "expenses.view",
  },
  {
    title: "مسارات التسوية",
    description: "مسارات تحصيل الدفع/COD المستخدمة لمطابقة دفعات التسوية، برسوم مُصنَّفة زمنيًا.",
    href: ROUTES.masterDataSettlementRoutes,
    icon: Route,
    permission: "settlements.manage_routes",
  },
];

export default async function MasterDataHubPage() {
  const session = await requireAnyPermission(SECTIONS.map((s) => s.permission));

  const visibleSections = SECTIONS.filter((s) => sessionHasPermission(session, s.permission));

  return (
    <div>
      <PageHeader
        title="البيانات الأساسية"
        description="مصادر البيانات المالية الرئيسية التي تعتمد عليها المبيعات — العيارات، الأسعار، المصنعية، التصنيفات، طرق الدفع، وقنوات التحصيل."
      />

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {visibleSections.map((section) => {
          const Icon = section.icon;
          return (
            <Link
              key={section.href}
              href={section.href}
              className="group flex flex-col gap-3 rounded-xl border border-border bg-card p-5 transition-colors hover:border-accent/50 hover:bg-accent/5"
            >
              <div className="flex items-center justify-between">
                <div className="flex size-10 items-center justify-center rounded-lg bg-accent/10 text-accent">
                  <Icon className="size-5" />
                </div>
                <ChevronLeft className="size-4 text-muted-foreground transition-transform group-hover:-translate-x-1" />
              </div>
              <div>
                <h3 className="font-semibold">{section.title}</h3>
                <p className="mt-1 text-sm text-muted-foreground">{section.description}</p>
              </div>
            </Link>
          );
        })}
      </div>
    </div>
  );
}
