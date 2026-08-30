import { Truck, MapPin, Banknote, Undo2 } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import {
  listShippingCarriers,
  listShippingZones,
  listShippingCarrierRateOverview,
  listCustomerReturnShippingFeeOverview,
} from "@/features/shipping-rates/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Can } from "@/lib/permissions/context";
import { CarrierFormDialog } from "@/features/shipping-rates/components/carrier-form-dialog";
import { CarrierStatusToggle } from "@/features/shipping-rates/components/carrier-status-toggle";
import { ZoneFormDialog } from "@/features/shipping-rates/components/zone-form-dialog";
import { ZoneStatusToggle } from "@/features/shipping-rates/components/zone-status-toggle";
import { CarrierRateVersionDialog } from "@/features/shipping-rates/components/carrier-rate-version-dialog";
import { CustomerReturnFeeVersionDialog } from "@/features/shipping-rates/components/customer-return-fee-version-dialog";
import { CancelRateVersionButton } from "@/features/shipping-rates/components/cancel-rate-version-button";
import { SHIPPING_CARRIER_TYPE_LABELS_AR, SHIPMENT_RATE_DIRECTION_LABELS_AR } from "@/features/shipping-rates/schema";
import { formatRiyadhDate } from "@/lib/date";

export default async function ShippingRatesAdminPage() {
  await requirePermission("shipping_rates.view");

  const [carriers, zones, rateOverview, returnFeeOverview] = await Promise.all([
    listShippingCarriers(),
    listShippingZones(),
    listShippingCarrierRateOverview(),
    listCustomerReturnShippingFeeOverview(),
  ]);

  const carrierById = new Map(carriers.map((c) => [c.id, c]));
  const zoneById = new Map(zones.map((z) => [z.id, z]));

  return (
    <div className="flex flex-col gap-8">
      <PageHeader
        title="شركات وتسعير الشحن"
        description="شركات الشحن، المناطق، تسعير الشحن لكل (شركة/منطقة/اتجاه)، ورسوم شحن الإرجاع المعيارية على العميل — كل تسعير مُدار كإصدارات زمنية موثقة، لا يمكن تعديل قيمة سبق أن سرت."
      />

      {/* --------------------------------------------------------------- */}
      {/* Carriers                                                        */}
      {/* --------------------------------------------------------------- */}
      <section>
        <div className="mb-3 flex items-center justify-between">
          <h2 className="flex items-center gap-2 text-lg font-semibold">
            <Truck className="size-5 text-accent" />
            شركات الشحن
          </h2>
          <Can permission="shipping_rates.manage">
            <CarrierFormDialog />
          </Can>
        </div>

        {carriers.length === 0 ? (
          <EmptyState icon={Truck} title="لا توجد شركات شحن بعد" description="ابدأ بإضافة أول شركة شحن." />
        ) : (
          <div className="rounded-xl border border-border bg-card">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>الاسم</TableHead>
                  <TableHead className="hidden sm:table-cell">الكود</TableHead>
                  <TableHead className="hidden md:table-cell">النوع</TableHead>
                  <TableHead>الحالة</TableHead>
                  <TableHead className="w-24 text-left">إجراءات</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {carriers.map((carrier) => (
                  <TableRow key={carrier.id}>
                    <TableCell>
                      <div className="flex flex-col">
                        <span className="font-medium">{carrier.name_ar}</span>
                        {carrier.name_en && <span className="text-xs text-muted-foreground">{carrier.name_en}</span>}
                      </div>
                    </TableCell>
                    <TableCell className="hidden font-mono text-xs sm:table-cell" dir="ltr">
                      {carrier.code}
                    </TableCell>
                    <TableCell className="hidden text-sm text-muted-foreground md:table-cell">{SHIPPING_CARRIER_TYPE_LABELS_AR[carrier.carrier_type]}</TableCell>
                    <TableCell>
                      <Badge variant={carrier.status === "active" ? "success" : "secondary"}>{carrier.status === "active" ? "نشطة" : "معطّلة"}</Badge>
                    </TableCell>
                    <TableCell>
                      <div className="flex items-center justify-end gap-1">
                        <Can permission="shipping_rates.manage">
                          <CarrierFormDialog carrier={carrier} />
                          <CarrierStatusToggle carrierId={carrier.id} status={carrier.status} carrierName={carrier.name_ar} />
                        </Can>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </section>

      {/* --------------------------------------------------------------- */}
      {/* Zones                                                           */}
      {/* --------------------------------------------------------------- */}
      <section>
        <div className="mb-3 flex items-center justify-between">
          <h2 className="flex items-center gap-2 text-lg font-semibold">
            <MapPin className="size-5 text-accent" />
            مناطق الشحن
          </h2>
          <Can permission="shipping_rates.manage">
            <ZoneFormDialog />
          </Can>
        </div>

        {zones.length === 0 ? (
          <EmptyState icon={MapPin} title="لا توجد مناطق بعد" description="ابدأ بإضافة أول منطقة." />
        ) : (
          <div className="rounded-xl border border-border bg-card">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>الاسم</TableHead>
                  <TableHead className="hidden sm:table-cell">الكود</TableHead>
                  <TableHead>الحالة</TableHead>
                  <TableHead className="w-24 text-left">إجراءات</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {zones.map((zone) => (
                  <TableRow key={zone.id}>
                    <TableCell>
                      <div className="flex flex-col">
                        <span className="font-medium">{zone.name_ar}</span>
                        {zone.name_en && <span className="text-xs text-muted-foreground">{zone.name_en}</span>}
                      </div>
                    </TableCell>
                    <TableCell className="hidden font-mono text-xs sm:table-cell" dir="ltr">
                      {zone.code}
                    </TableCell>
                    <TableCell>
                      <Badge variant={zone.status === "active" ? "success" : "secondary"}>{zone.status === "active" ? "نشطة" : "معطّلة"}</Badge>
                    </TableCell>
                    <TableCell>
                      <div className="flex items-center justify-end gap-1">
                        <Can permission="shipping_rates.manage">
                          <ZoneFormDialog zone={zone} />
                          <ZoneStatusToggle zoneId={zone.id} status={zone.status} zoneName={zone.name_ar} />
                        </Can>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </section>

      {/* --------------------------------------------------------------- */}
      {/* Carrier rate versions                                           */}
      {/* --------------------------------------------------------------- */}
      <section>
        <div className="mb-3 flex items-center justify-between">
          <h2 className="flex items-center gap-2 text-lg font-semibold">
            <Banknote className="size-5 text-accent" />
            تسعير الشحن (شركة/منطقة/اتجاه)
          </h2>
          <Can permission="shipping_rates.manage">
            <CarrierRateVersionDialog carriers={carriers} zones={zones} />
          </Can>
        </div>

        {rateOverview.length === 0 ? (
          <EmptyState icon={Banknote} title="لا يوجد تسعير شحن بعد" description="أضف تسعيرًا لتركيبة (شركة شحن، منطقة، اتجاه)." />
        ) : (
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {rateOverview.map((row) => {
              const carrier = carrierById.get(row.carrier_id);
              const zone = zoneById.get(row.shipping_zone_id);
              const pastVersions = row.history.filter((v) => v.id !== row.currentVersion?.id && v.id !== row.upcomingVersion?.id);

              return (
                <div key={`${row.carrier_id}::${row.shipping_zone_id}::${row.direction}`} className="rounded-xl border border-border bg-card p-4">
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div>
                      <h3 className="font-semibold">
                        {carrier?.name_ar ?? "—"} — {zone?.name_ar ?? "—"}
                      </h3>
                      <span className="text-xs text-muted-foreground">{SHIPMENT_RATE_DIRECTION_LABELS_AR[row.direction as "outbound" | "return"]}</span>

                      {row.currentVersion ? (
                        <div className="mt-1">
                          <p className="text-2xl font-bold tabular-nums">
                            {row.currentVersion.base_cost} <span className="text-sm font-normal text-muted-foreground">ر.س</span>
                          </p>
                          <Badge variant="success" className="mt-1">
                            ساري منذ {formatRiyadhDate(row.currentVersion.effective_from)}
                          </Badge>
                        </div>
                      ) : (
                        <p className="mt-1 text-sm text-muted-foreground">لا يوجد تسعير معتمَد حاليًا لهذه التركيبة.</p>
                      )}

                      {row.upcomingVersion && (
                        <div className="mt-2 rounded-lg border border-warning/30 bg-warning/5 p-2">
                          <p className="text-xs font-medium text-muted-foreground">القادم</p>
                          <p className="text-base font-semibold tabular-nums">
                            {row.upcomingVersion.base_cost} <span className="text-xs font-normal text-muted-foreground">ر.س</span>
                          </p>
                          <Badge variant="warning" className="mt-1">
                            سيسري اعتبارًا من {formatRiyadhDate(row.upcomingVersion.effective_from)}
                          </Badge>
                        </div>
                      )}
                    </div>

                    <Can permission="shipping_rates.manage">
                      <div className="flex flex-col items-end gap-2">
                        <CarrierRateVersionDialog
                          carriers={carriers}
                          zones={zones}
                          preset={{ carrierId: row.carrier_id, shippingZoneId: row.shipping_zone_id, direction: row.direction }}
                          trigger={
                            <button type="button" className="text-xs font-medium text-accent hover:underline">
                              إصدار جديد
                            </button>
                          }
                        />
                        {row.upcomingVersion && (
                          <CancelRateVersionButton kind="carrier_rate" versionId={row.upcomingVersion.id} effectiveFrom={formatRiyadhDate(row.upcomingVersion.effective_from)} />
                        )}
                      </div>
                    </Can>
                  </div>

                  {pastVersions.length > 0 && (
                    <ul className="mt-3 flex flex-col gap-1.5 border-t border-border pt-3 text-sm">
                      {pastVersions.map((v) => (
                        <li key={v.id} className="flex items-center justify-between gap-2 text-muted-foreground">
                          <span className="tabular-nums">{v.base_cost} ر.س</span>
                          <span className="text-xs">
                            {formatRiyadhDate(v.effective_from)} — {v.effective_to ? formatRiyadhDate(v.effective_to) : "الآن"}
                          </span>
                        </li>
                      ))}
                    </ul>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </section>

      {/* --------------------------------------------------------------- */}
      {/* Customer return shipping fee versions                           */}
      {/* --------------------------------------------------------------- */}
      <section>
        <div className="mb-3 flex items-center justify-between">
          <h2 className="flex items-center gap-2 text-lg font-semibold">
            <Undo2 className="size-5 text-accent" />
            رسوم شحن الإرجاع على العميل (حسب المنطقة)
          </h2>
          <Can permission="shipping_rates.manage">
            <CustomerReturnFeeVersionDialog zones={zones} />
          </Can>
        </div>

        {returnFeeOverview.length === 0 ? (
          <EmptyState icon={Undo2} title="لا توجد رسوم إرجاع بعد" description="أضف رسوم إرجاع معيارية لمنطقة." />
        ) : (
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {returnFeeOverview.map((row) => {
              const zone = zoneById.get(row.shipping_zone_id);
              const pastVersions = row.history.filter((v) => v.id !== row.currentVersion?.id && v.id !== row.upcomingVersion?.id);

              return (
                <div key={row.shipping_zone_id} className="rounded-xl border border-border bg-card p-4">
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div>
                      <h3 className="font-semibold">{zone?.name_ar ?? "—"}</h3>

                      {row.currentVersion ? (
                        <div className="mt-1">
                          <p className="text-2xl font-bold tabular-nums">
                            {row.currentVersion.fee_amount} <span className="text-sm font-normal text-muted-foreground">ر.س</span>
                          </p>
                          <Badge variant="success" className="mt-1">
                            ساري منذ {formatRiyadhDate(row.currentVersion.effective_from)}
                          </Badge>
                        </div>
                      ) : (
                        <p className="mt-1 text-sm text-muted-foreground">لا توجد رسوم إرجاع معتمَدة حاليًا لهذه المنطقة.</p>
                      )}

                      {row.upcomingVersion && (
                        <div className="mt-2 rounded-lg border border-warning/30 bg-warning/5 p-2">
                          <p className="text-xs font-medium text-muted-foreground">القادم</p>
                          <p className="text-base font-semibold tabular-nums">
                            {row.upcomingVersion.fee_amount} <span className="text-xs font-normal text-muted-foreground">ر.س</span>
                          </p>
                          <Badge variant="warning" className="mt-1">
                            سيسري اعتبارًا من {formatRiyadhDate(row.upcomingVersion.effective_from)}
                          </Badge>
                        </div>
                      )}
                    </div>

                    <Can permission="shipping_rates.manage">
                      <div className="flex flex-col items-end gap-2">
                        <CustomerReturnFeeVersionDialog
                          zones={zones}
                          preset={{ shippingZoneId: row.shipping_zone_id }}
                          trigger={
                            <button type="button" className="text-xs font-medium text-accent hover:underline">
                              إصدار جديد
                            </button>
                          }
                        />
                        {row.upcomingVersion && (
                          <CancelRateVersionButton kind="customer_return_fee" versionId={row.upcomingVersion.id} effectiveFrom={formatRiyadhDate(row.upcomingVersion.effective_from)} />
                        )}
                      </div>
                    </Can>
                  </div>

                  {pastVersions.length > 0 && (
                    <ul className="mt-3 flex flex-col gap-1.5 border-t border-border pt-3 text-sm">
                      {pastVersions.map((v) => (
                        <li key={v.id} className="flex items-center justify-between gap-2 text-muted-foreground">
                          <span className="tabular-nums">{v.fee_amount} ر.س</span>
                          <span className="text-xs">
                            {formatRiyadhDate(v.effective_from)} — {v.effective_to ? formatRiyadhDate(v.effective_to) : "الآن"}
                          </span>
                        </li>
                      ))}
                    </ul>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </section>
    </div>
  );
}
