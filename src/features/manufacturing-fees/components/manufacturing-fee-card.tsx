"use client";

import { useState } from "react";
import { ChevronDown, ChevronUp, History } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Can } from "@/lib/permissions/context";
import { ManufacturingFeeVersionDialog } from "./manufacturing-fee-version-dialog";
import { CancelVersionButton } from "./cancel-version-button";
import { formatRiyadhDate } from "@/lib/date";
import type { Database } from "@/types/database";

type Karat = Database["public"]["Tables"]["karats"]["Row"];
type FeeVersion = Database["public"]["Tables"]["manufacturing_fee_versions"]["Row"];

export function ManufacturingFeeCard({
  karat,
  currentVersion,
  upcomingVersion,
  history,
}: {
  karat: Karat;
  currentVersion: FeeVersion | null;
  upcomingVersion: FeeVersion | null;
  history: FeeVersion[];
}) {
  const [showHistory, setShowHistory] = useState(false);
  // Never present a future version as "current" (Financial Integrity Patch
  // 2.1, item 8) — currentVersion/upcomingVersion are resolved separately
  // by listManufacturingFeeOverview()/the karat-detail equivalent, so this
  // component only ever needs to render what it is given, never re-derive
  // "is this actually current" itself.
  const pastVersions = history.filter((v) => v.id !== currentVersion?.id && v.id !== upcomingVersion?.id);

  return (
    <div className="rounded-xl border border-border bg-card p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 className="font-semibold">{karat.name_ar}</h3>

          {currentVersion ? (
            <div className="mt-1">
              <p className="text-2xl font-bold tabular-nums">
                {currentVersion.fee_per_gram} <span className="text-sm font-normal text-muted-foreground">ر.س/جم</span>
              </p>
              <Badge variant="success" className="mt-1">
                ساري منذ {formatRiyadhDate(currentVersion.effective_from)}
              </Badge>
            </div>
          ) : (
            <p className="mt-1 text-sm text-muted-foreground">لا توجد مصنعية معتمدة حاليًا لهذا العيار.</p>
          )}

          {upcomingVersion && (
            <div className="mt-2 rounded-lg border border-warning/30 bg-warning/5 p-2">
              <p className="text-xs font-medium text-muted-foreground">القادم</p>
              <p className="text-base font-semibold tabular-nums">
                {upcomingVersion.fee_per_gram} <span className="text-xs font-normal text-muted-foreground">ر.س/جم</span>
              </p>
              <Badge variant="warning" className="mt-1">
                سيسري اعتبارًا من {formatRiyadhDate(upcomingVersion.effective_from)}
              </Badge>
            </div>
          )}
        </div>

        <Can permission="manufacturing_fees.manage">
          <div className="flex flex-col items-end gap-2">
            <ManufacturingFeeVersionDialog karat={karat} />
            {upcomingVersion && <CancelVersionButton versionId={upcomingVersion.id} effectiveFrom={formatRiyadhDate(upcomingVersion.effective_from)} />}
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
                  <span className="tabular-nums">{v.fee_per_gram} ر.س/جم</span>
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
