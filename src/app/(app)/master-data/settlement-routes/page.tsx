import { Route } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import {
  getSettlementRoutesAdminList,
  getActivePaymentMethodsForRouteForm,
  getActiveCollectionChannelsForRouteForm,
  getActiveShippingCarriersForRouteForm,
  listSettlementRouteFeeVersions,
} from "@/features/settlements/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Can } from "@/lib/permissions/context";
import { SettlementRouteFormDialog } from "@/features/settlements/components/settlement-route-form-dialog";
import { SettlementRouteStatusToggle } from "@/features/settlements/components/settlement-route-status-toggle";
import { SettlementRouteFeeVersionPanel } from "@/features/settlements/components/settlement-route-fee-version-panel";
import { SETTLEMENT_ROUTE_KIND_LABELS_AR } from "@/features/settlements/schema";

export default async function SettlementRoutesPage() {
  await requirePermission("settlements.manage_routes");

  const [routes, paymentMethods, collectionChannels, shippingCarriers] = await Promise.all([
    getSettlementRoutesAdminList(),
    getActivePaymentMethodsForRouteForm(),
    getActiveCollectionChannelsForRouteForm(),
    getActiveShippingCarriersForRouteForm(),
  ]);

  // Fee-version history now goes through list_settlement_route_fee_versions_
  // for_management() (Patch 7.1 §23, migration 0190), gated ONLY on
  // settlements.manage_routes — the settlements.view_financials-gated direct
  // table read this page used before (a hidden, unrelated-permission
  // dependency §23 flags) is gone, so every actor who reaches this page at
  // all can now see the fee-version panel unconditionally.
  const feeVersionsByRoute = Object.fromEntries(await Promise.all(routes.map(async (r) => [r.id, await listSettlementRouteFeeVersions(r.id)] as const)));

  return (
    <div>
      <PageHeader
        title="مسارات التسوية"
        description="كل دفعة تسوية جديدة تُنشأ لاحقًا يجب أن ترتبط بمسار نشط من هذه القائمة — تعطيل مسار لا يؤثر على الدفعات التاريخية التي تستخدمه."
        actions={
          <Can permission="settlements.manage_routes">
            <SettlementRouteFormDialog
              paymentMethods={paymentMethods.map((p) => ({ id: p.id, name_ar: p.name_ar }))}
              collectionChannels={collectionChannels.map((c) => ({ id: c.id, name_ar: c.name_ar }))}
              shippingCarriers={shippingCarriers.map((c) => ({ id: c.id, name_ar: c.name_ar }))}
            />
          </Can>
        }
      />

      {routes.length === 0 ? (
        <EmptyState icon={Route} title="لا توجد مسارات تسوية بعد" description="ابدأ بإضافة أول مسار." />
      ) : (
        <div className="flex flex-col gap-4">
          {routes.map((route) => (
            <Card key={route.id}>
              <CardHeader className="flex flex-row flex-wrap items-center justify-between gap-2">
                <div className="flex flex-col gap-1">
                  <CardTitle className="flex items-center gap-2 text-base">
                    {route.name_ar}
                    <Badge variant={route.status === "active" ? "success" : "secondary"}>{route.status === "active" ? "نشط" : "معطّل"}</Badge>
                    <Badge variant="outline">{SETTLEMENT_ROUTE_KIND_LABELS_AR[route.route_kind as keyof typeof SETTLEMENT_ROUTE_KIND_LABELS_AR] ?? route.route_kind}</Badge>
                  </CardTitle>
                  <p className="font-mono text-xs text-muted-foreground" dir="ltr">
                    {route.code}
                  </p>
                  <p className="text-xs text-muted-foreground">
                    {route.route_kind === "payment_collection"
                      ? `${route.payment_method_name ?? "—"}${route.collection_channel_name ? ` — ${route.collection_channel_name}` : " — بدون قناة تحصيل"}`
                      : route.shipping_carrier_name ?? "—"}
                  </p>
                  {route.description && <p className="text-xs text-muted-foreground">{route.description}</p>}
                </div>
                <div className="flex items-center gap-1">
                  <Can permission="settlements.manage_routes">
                    <SettlementRouteFormDialog
                      route={route}
                      paymentMethods={paymentMethods.map((p) => ({ id: p.id, name_ar: p.name_ar }))}
                      collectionChannels={collectionChannels.map((c) => ({ id: c.id, name_ar: c.name_ar }))}
                      shippingCarriers={shippingCarriers.map((c) => ({ id: c.id, name_ar: c.name_ar }))}
                    />
                    <SettlementRouteStatusToggle routeId={route.id} status={route.status as "active" | "disabled"} routeName={route.name_ar} />
                  </Can>
                </div>
              </CardHeader>
              <CardContent>
                <SettlementRouteFeeVersionPanel routeId={route.id} routeKind={route.route_kind} versions={feeVersionsByRoute[route.id] ?? []} />
              </CardContent>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}
