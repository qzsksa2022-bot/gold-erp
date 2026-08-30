import { describe, expect, it, vi, beforeEach } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import "@testing-library/jest-dom";
import { PermissionsProvider } from "@/lib/permissions/context";
import { SalesEntryForm } from "@/features/sales/components/sales-entry-form";

// Hotfix 3.2.1 item 1 — regression test for the "Conflict Reload leaves
// stale local state" bug: after a version Conflict, the Edit form's local
// useState (items/paymentMethodId/collectionChannelId/customer fields/
// notes) was created once from the INITIAL existingOrder prop and never
// reset when a later existingOrder prop (with a newer row_version) arrived
// via router.refresh() — Next.js keeps a Client Component's own state
// across a Server Component refresh. Only clearing the `versionConflict`
// flag (the pre-hotfix behavior) let the user re-submit a Save built from
// data that predates the OTHER user's committed edit, silently clobbering
// it — defeating the entire purpose of optimistic concurrency.
//
// The fix (src/app/(app)/sales/[id]/edit/page.tsx): `<SalesEntryForm
// key={order.row_version} .../>` — a changed `key` forces React to
// unmount the old instance and mount a brand-new one, so EVERY piece of
// local state (not just the conflict banner) is re-initialized from the
// fresh existingOrder. This test proves that exact mechanism: swapping the
// `key` on rerender must drop every trace of the stale instance's state.

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn(), refresh: vi.fn() }),
}));

// Server Actions are irrelevant to this test (no Save/Preview is ever
// triggered) — mocked only so importing the component doesn't pull in
// "use server" / next/cache / Supabase server-client machinery under
// jsdom.
vi.mock("@/features/sales/actions", () => ({
  createSalesOrderAction: vi.fn(),
  updateSalesOrderAction: vi.fn(),
  previewSalesOrderAction: vi.fn(async () => ({ success: false, error: "" })),
  previewUpdateSalesOrderAction: vi.fn(async () => ({ success: false, error: "" })),
}));

const editLookups = {
  categories: [{ id: "cat-1", name_ar: "خواتم" }],
  karats: [{ id: "karat-1", name_ar: "عيار 21", code: "21" }],
  paymentMethods: [{ id: "pm-1", name_ar: "نقدي" }],
  collectionChannels: [{ id: "cc-1", name_ar: "المتجر" }],
};

type TestOrder = {
  id: string;
  order_number: string;
  store_id: string;
  store_name: string;
  sale_date: string;
  payment_method_id: string;
  collection_channel_id: string;
  customer_name: string | null;
  customer_phone: string | null;
  notes: string | null;
  is_day_closed: boolean;
  row_version: number;
  items: {
    id: string;
    category_id: string;
    karat_id: string;
    weight_grams: string;
    sale_price: string;
    item_name: string | null;
    description: string | null;
  }[];
};

function makeOrder(rowVersion: number, weightGrams: string): TestOrder {
  return {
    id: "order-1",
    order_number: "SO-0001",
    store_id: "store-1",
    store_name: "فرع الرياض",
    sale_date: "2026-08-17",
    payment_method_id: "pm-1",
    collection_channel_id: "cc-1",
    customer_name: null,
    customer_phone: null,
    notes: null,
    is_day_closed: false,
    row_version: rowVersion,
    items: [
      {
        id: "item-1",
        category_id: "cat-1",
        karat_id: "karat-1",
        weight_grams: weightGrams,
        sale_price: "100.00",
        item_name: null,
        description: null,
      },
    ],
  };
}

function renderEditForm(order: TestOrder) {
  return (
    <PermissionsProvider permissions={[]} isSuperAdmin={false}>
      <SalesEntryForm key={order.row_version} editLookups={editLookups} existingOrder={order} />
    </PermissionsProvider>
  );
}

describe("SalesEntryForm — Hotfix 3.2.1 item 1 (Conflict reload must not leave stale UI state)", () => {
  beforeEach(() => {
    cleanup();
  });

  it("mandatory regression scenario: B's stale weight=1 is fully replaced by A's committed weight=5 after the row_version-keyed remount", () => {
    // 1) B loads the order at row_version=5 with weight=1.
    const staleOrder = makeOrder(5, "1.0000");
    const { rerender } = render(renderEditForm(staleOrder));
    expect(screen.getByDisplayValue("1.0000")).toBeInTheDocument();

    // 2) (Off-screen) A saves weight=5 concurrently -> row_version becomes 6.
    // 3) B's Save is rejected with a Conflict (not exercised here directly --
    //    covered by the SQL/HTTP concurrency suite, see Section I of
    //    sales_integrity_patch_3_1_concurrency.test.sql).
    // 4) B clicks "تحديث الصفحة" -> router.refresh() re-runs the Edit page's
    //    Server Component, which re-fetches get_sales_order() and re-renders
    //    <SalesEntryForm key={order.row_version} existingOrder={order} />
    //    with the fresh row_version=6 / weight=5 order -- simulated here by
    //    rerendering with a new `key`.
    const freshOrder = makeOrder(6, "5.0000");
    rerender(renderEditForm(freshOrder));

    // 5)/6) The form must show weight=5 / row_version=6 -- the stale
    // weight=1 must be gone ENTIRELY, not just the conflict banner.
    expect(screen.queryByDisplayValue("1.0000")).not.toBeInTheDocument();
    expect(screen.getByDisplayValue("5.0000")).toBeInTheDocument();
  });

  it("also resets non-item local state (customer name) that a partial fix (clearing versionConflict alone) would have left stale", () => {
    const staleOrder = { ...makeOrder(5, "1.0000"), customer_name: "عميل قديم" };
    const { rerender } = render(renderEditForm(staleOrder));
    expect(screen.getByDisplayValue("عميل قديم")).toBeInTheDocument();

    const freshOrder = { ...makeOrder(6, "5.0000"), customer_name: "عميل جديد" };
    rerender(renderEditForm(freshOrder));

    expect(screen.queryByDisplayValue("عميل قديم")).not.toBeInTheDocument();
    expect(screen.getByDisplayValue("عميل جديد")).toBeInTheDocument();
  });
});
