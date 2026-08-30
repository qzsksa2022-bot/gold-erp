"use client";

import { useState } from "react";
import { ChevronDown, ChevronUp, History } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Can } from "@/lib/permissions/context";
import { PaymentMethodFormDialog } from "./payment-method-form-dialog";
import { PaymentMethodStatusToggle } from "./payment-method-status-toggle";
import { FeeVersionDialog } from "./fee-version-dialog";
import { CancelFeeVersionButton } from "./cancel-fee-version-button";
import { FEE_MODEL_LABELS_AR, REFUND_POLICY_LABELS_AR } from "../labels";
import { formatRiyadhDate } from "@/lib/date";
import { toDecimal } from "@/lib/decimal";
import type { Database } from "@/types/database";

type PaymentMethod = Database["public"]["Tables"]["payment_methods"]["Row"];
type FeeVersion = Database["public"]["Tables"]["payment_method_fee_versions"]["Row"];

function formatFee(v: FeeVersion): string {
  // Decimal, never a raw arithmetic Number() — see src/lib/decimal.ts. These
  // are DB-sourced NUMERIC values that arrive over PostgREST as unquoted
  // JSON numbers (Database["..."]["Row"] correctly types them `number` —
  // see src/types/database.ts), used here for display-only formatting
  // (badge text), not a financial calculation, so toDecimal()'s `number`
  // support is fine. A value entering an actual profit/cost/fee
  // CALCULATION must instead come from a finance-safe `_safe` RPC (0052).
  const parts: string[] = [];
  if (toDecimal(v.percentage_fee).gt(0)) parts.push(`${v.percentage_fee}%`);
  if (toDecimal(v.fixed_fee).gt(0)) parts.push(`${v.fixed_fee} ر.س`);
  return parts.length > 0 ? parts.join(" + ") : "بدون رسوم";
}

export function PaymentMethodCard({
  method,
  currentVersion,
  upcomingVersion,
  history,
}: {
  method: PaymentMethod;
  currentVersion: FeeVersion | null;
  upcomingVersion: FeeVersion | null;
  history: FeeVersion[];
}) {
  const [showHistory, setShowHistory] = useState(false);
  // Never present a future version as "current" (Financial Integrity Patch
  // 2.1, item 8) — see manufacturing-fee-card.tsx's identical comment.
  const pastVersions = history.filter((v) => v.id !== currentVersion?.id && v.id !== upcomingVersion?.id);

  return (
    <div className="rounded-xl border border-border bg-card p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <h3 className="font-semibold">{method.name_ar}</h3>
            <Badge variant={method.status === "active" ? "success" : "secondary"}>
              {method.status === "active" ? "نشط" : "معطّل"}
            </Badge>
          </div>
          {method.name_en && <p className="text-xs text-muted-foreground">{method.name_en}</p>}

          {currentVersion ? (
            <div className="mt-2">
              <p className="text-xl font-bold tabular-nums">{formatFee(currentVersion)}</p>
              <Badge variant="success" className="mt-1">
                سارية منذ {formatRiyadhDate(currentVersion.effective_from)}
              </Badge>
            </div>
          ) : (
            <p className="mt-2 text-sm text-muted-foreground">لا توجد عمولة معتمدة حاليًا — يجب إعدادها قبل استخدام هذه الطريقة.</p>
          )}

          {upcomingVersion && (
            <div className="mt-2 rounded-lg border border-warning/30 bg-warning/5 p-2">
              <p className="text-xs font-medium text-muted-foreground">القادمة</p>
              <p className="text-base font-semibold tabular-nums">{formatFee(upcomingVersion)}</p>
              <Badge variant="warning" className="mt-1">
                ستسري اعتبارًا من {formatRiyadhDate(upcomingVersion.effective_from)}
              </Badge>
            </div>
          )}

          <div className="mt-2 flex flex-wrap gap-1.5 text-xs text-muted-foreground">
            <Badge variant="outline">{FEE_MODEL_LABELS_AR[method.fee_model]}</Badge>
            <Badge variant="outline">{REFUND_POLICY_LABELS_AR[method.refund_fee_policy]}</Badge>
            {!method.supports_refunds && <Badge variant="outline">لا تدعم الاسترجاع</Badge>}
          </div>
        </div>

        <Can permission="payment_methods.manage">
          <div className="flex shrink-0 flex-col items-end gap-2">
            <div className="flex items-center gap-1">
              <PaymentMethodFormDialog method={method} />
              <PaymentMethodStatusToggle methodId={method.id} status={method.status} methodName={method.name_ar} />
            </div>
            <FeeVersionDialog method={method} />
            {upcomingVersion && (
              <CancelFeeVersionButton versionId={upcomingVersion.id} effectiveFrom={formatRiyadhDate(upcomingVersion.effective_from)} />
            )}
          </div>
        </Can>
      </div>

      {pastVersions.length > 0 && (
        <div className="mt-3 border-t border-border pt-3">
          <button
            type="button"
            onClick={() => setShowHistory((v) => !v)}
            className="flex items-center gap-1.5 text-xs font-medium text-muted-foreground hover:text-foreground"
          >
            <History className="size-3.5" />
            السجل التاريخي ({pastVersions.length})
            {showHistory ? <ChevronUp className="size-3.5" /> : <ChevronDown className="size-3.5" />}
          </button>

          {showHistory && (
            <ul className="mt-2 flex flex-col gap-1.5 text-sm">
              {pastVersions.map((v) => (
                <li key={v.id} className="flex items-center justify-between gap-2 text-muted-foreground">
                  <span className="tabular-nums">{formatFee(v)}</span>
                  <span className="text-xs">
                    {formatRiyadhDate(v.effective_from)} — {v.effective_to ? formatRiyadhDate(v.effective_to) : "الآن"}
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
      )}
    </div>
  );
}
