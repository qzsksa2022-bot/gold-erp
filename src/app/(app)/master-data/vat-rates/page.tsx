import { Percent, History } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { listVatRateOverview } from "@/features/vat-rates/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Badge } from "@/components/ui/badge";
import { Can } from "@/lib/permissions/context";
import { VatRateVersionDialog } from "@/features/vat-rates/components/vat-rate-version-dialog";
import { CancelVatVersionButton } from "@/features/vat-rates/components/cancel-vat-version-button";
import { formatRiyadhDate } from "@/lib/date";

/**
 * Hotfix 10.1.0 — the VAT rate management screen.
 *
 * vat_rate_versions, create_vat_rate_version(), cancel_vat_rate_version() and
 * the vat_rates.view / vat_rates.manage permissions have existed since
 * migration 0058 (hardened 0066) and were granted to four roles in seed.sql —
 * but no page ever reached them, so the rate could only be changed by direct
 * SQL. This page closes that gap using the existing backend unchanged.
 *
 * Reading is gated on vat_rates.view; every write control is additionally
 * gated on vat_rates.manage and re-enforced inside the RPCs themselves.
 */
export default async function VatRatesPage() {
  await requirePermission("vat_rates.view");

  const { currentVersion, upcomingVersion, history } = await listVatRateOverview();

  // Never present a FUTURE version as the live one (Financial Integrity Patch
  // 2.1 item 8) — current/upcoming are resolved server-side and this page only
  // renders what it is given.
  const pastVersions = history.filter((v) => v.id !== currentVersion?.id && v.id !== upcomingVersion?.id);

  return (
    <div>
      <PageHeader
        title="ضريبة القيمة المضافة"
        description="النسبة المطبَّقة على كل عملية بيع، بإصدارات زمنية موثقة. تغيير النسبة يتم بإنشاء إصدار جديد بتاريخ سريان — لا بتعديل نسبة سارية أو تاريخية."
        actions={
          <Can permission="vat_rates.manage">
            <VatRateVersionDialog />
          </Can>
        }
      />

      <div className="mb-6 rounded-xl border border-border bg-card p-4">
        {currentVersion ? (
          <div>
            <p className="text-xs text-muted-foreground">النسبة السارية حاليًا</p>
            {/* Rendered as-is from the column — no Number()/parseFloat() round trip. */}
            <p className="mt-1 text-3xl font-bold tabular-nums" dir="ltr">
              {currentVersion.rate_percent}%
            </p>
            <Badge variant="success" className="mt-2">
              سارية منذ {formatRiyadhDate(currentVersion.effective_from)}
            </Badge>
            {currentVersion.notes && <p className="mt-2 text-sm text-muted-foreground">{currentVersion.notes}</p>}
          </div>
        ) : (
          <p className="text-sm text-muted-foreground">لا توجد نسبة ضريبة معتمدة سارية حاليًا.</p>
        )}

        {upcomingVersion && (
          <div className="mt-4 rounded-lg border border-warning/30 bg-warning/5 p-3">
            <div className="flex flex-wrap items-start justify-between gap-2">
              <div>
                <p className="text-xs font-medium text-muted-foreground">القادم</p>
                <p className="text-xl font-semibold tabular-nums" dir="ltr">
                  {upcomingVersion.rate_percent}%
                </p>
                <Badge variant="warning" className="mt-1">
                  سيسري اعتبارًا من {formatRiyadhDate(upcomingVersion.effective_from)}
                </Badge>
              </div>
              <Can permission="vat_rates.manage">
                <CancelVatVersionButton versionId={upcomingVersion.id} effectiveFrom={formatRiyadhDate(upcomingVersion.effective_from)} />
              </Can>
            </div>
          </div>
        )}
      </div>

      <div className="rounded-xl border border-border bg-card p-4">
        <div className="mb-3 flex items-center gap-1.5 text-sm font-medium">
          <History className="size-4 text-muted-foreground" />
          السجل التاريخي
        </div>

        {pastVersions.length === 0 ? (
          <EmptyState icon={Percent} title="لا يوجد سجل سابق" description="سيظهر هنا كل إصدار سابق أو ملغى للنسبة." />
        ) : (
          <ul className="flex flex-col gap-2 text-sm">
            {pastVersions.map((v) => (
              <li key={v.id} className="flex flex-wrap items-center justify-between gap-2 border-b border-border pb-2 last:border-0 last:pb-0">
                <span className="tabular-nums font-medium" dir="ltr">
                  {v.rate_percent}%
                </span>
                <span className="text-xs text-muted-foreground">
                  {formatRiyadhDate(v.effective_from)} — {v.effective_to ? formatRiyadhDate(v.effective_to) : "مفتوح"}
                </span>
                {v.status === "cancelled" && (
                  <Badge variant="secondary" className="text-[10px]">
                    ملغى
                  </Badge>
                )}
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
