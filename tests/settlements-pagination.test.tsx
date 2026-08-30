import { describe, expect, it, vi, beforeEach } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import "@testing-library/jest-dom";
import { SettlementBatchesPager } from "@/features/settlements/components/settlement-batches-pager";

// Phase 7 (Settlements Core) — mirrors tests/adjustments-hotfix-6-1-1-list-
// reversal-pagination.test.tsx's own precedent for pagination-link
// regressions. list_settlement_batches() (migration 0182) deliberately does
// NOT return a total_count column, unlike every other list_*() RPC — so
// queries.ts's listSettlementBatchesPage() fetches pageSize + 1 rows and
// derives hasNextPage from whether that extra row came back, instead of a
// fabricated total (see queries.ts's own comment). This file exercises
// BOTH ends of that deviation: the "fetch pageSize+1" query-layer technique
// itself, and the Next/Previous-only pager component that consumes
// hasNextPage — the classic off-by-one is exactly the risk here (fetching
// pageSize+1 but forgetting to slice back down to pageSize, or treating
// rows.length > pageSize vs >= pageSize incorrectly).

const { rpcMock } = vi.hoisted(() => ({ rpcMock: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({
  createClient: async () => ({ rpc: rpcMock }),
}));

// queries.ts is a real server-only module (`import "server-only"` at its
// top) that this codebase's other tests always mock away rather than
// import directly. This file DOES import it directly (to exercise the
// real pageSize+1 pagination arithmetic, not a re-implementation of it) —
// so the "server-only" guard package, which unconditionally throws when
// required outside a genuine RSC build, is stubbed out for this file only.
vi.mock("server-only", () => ({}));

import {
  listSettlementBatchesPage,
  getPaymentMethodFilterLookupsForSettlements,
  getCollectionChannelFilterLookupsForSettlements,
} from "@/features/settlements/queries";

function makeRows(n: number) {
  return Array.from({ length: n }, (_, i) => ({ id: `batch-${i}`, settlement_number: `STL-${String(i).padStart(10, "0")}` }));
}

describe("listSettlementBatchesPage() — the 'fetch pageSize+1' technique itself", () => {
  const PAGE_SIZE = 20;

  beforeEach(() => {
    rpcMock.mockReset();
  });

  it("requests p_limit = pageSize + 1, and when exactly pageSize+1 rows come back, hasNextPage=true and the returned rows are sliced back down to pageSize (never pageSize+1)", async () => {
    rpcMock.mockResolvedValue({ data: makeRows(PAGE_SIZE + 1), error: null });

    const result = await listSettlementBatchesPage({ page: 1 }, PAGE_SIZE);

    expect(rpcMock).toHaveBeenCalledWith("list_settlement_batches", expect.objectContaining({ p_limit: PAGE_SIZE + 1, p_offset: 0 }));
    expect(result.hasNextPage).toBe(true);
    expect(result.rows).toHaveLength(PAGE_SIZE);
    // The row that proved hasNextPage must never leak into the displayed page.
    expect(result.rows.some((r) => r.id === `batch-${PAGE_SIZE}`)).toBe(false);
  });

  it("when exactly pageSize rows come back (the true last page), hasNextPage=false and every row is kept — off-by-one guard: pageSize rows must NOT be mistaken for 'has more'", async () => {
    rpcMock.mockResolvedValue({ data: makeRows(PAGE_SIZE), error: null });

    const result = await listSettlementBatchesPage({ page: 1 }, PAGE_SIZE);

    expect(result.hasNextPage).toBe(false);
    expect(result.rows).toHaveLength(PAGE_SIZE);
  });

  it("when fewer than pageSize rows come back, hasNextPage=false and all of them are kept", async () => {
    rpcMock.mockResolvedValue({ data: makeRows(3), error: null });

    const result = await listSettlementBatchesPage({ page: 1 }, PAGE_SIZE);

    expect(result.hasNextPage).toBe(false);
    expect(result.rows).toHaveLength(3);
  });

  it("when zero rows come back, hasNextPage=false and rows is an empty array (never throws on an empty page)", async () => {
    rpcMock.mockResolvedValue({ data: [], error: null });

    const result = await listSettlementBatchesPage({ page: 1 }, PAGE_SIZE);

    expect(result.hasNextPage).toBe(false);
    expect(result.rows).toEqual([]);
  });

  it("computes p_offset from (page - 1) * pageSize for page 3", async () => {
    rpcMock.mockResolvedValue({ data: makeRows(5), error: null });

    await listSettlementBatchesPage({ page: 3 }, PAGE_SIZE);

    expect(rpcMock).toHaveBeenCalledWith("list_settlement_batches", expect.objectContaining({ p_offset: (3 - 1) * PAGE_SIZE, p_limit: PAGE_SIZE + 1 }));
  });

  it("a null data response (no rows at all) is treated as an empty page, not a crash", async () => {
    rpcMock.mockResolvedValue({ data: null, error: null });

    const result = await listSettlementBatchesPage({ page: 1 }, PAGE_SIZE);

    expect(result.rows).toEqual([]);
    expect(result.hasNextPage).toBe(false);
  });
});

describe("SettlementBatchesPager — Next/Previous-only control driven by hasNextPage (no total/page-count ever fabricated)", () => {
  beforeEach(() => cleanup());

  it("page 1 with hasNextPage=false renders nothing at all (no pager needed for a single, complete page)", () => {
    const { container } = render(<SettlementBatchesPager page={1} hasNextPage={false} buildHref={(p) => `/settlements?page=${p}`} />);
    expect(container).toBeEmptyDOMElement();
  });

  // NOTE: every <Button> from this codebase's shared component carries a
  // STATIC "disabled:pointer-events-none" Tailwind class regardless of
  // whether it is actually disabled (it only ever takes effect via the CSS
  // `:disabled` pseudo-class) — so "pointer-events-none" alone is always a
  // substring of every button's className and cannot distinguish
  // enabled/disabled here. SettlementBatchesPager applies its own
  // conditional "pointer-events-none opacity-40" pair (see the component's
  // own `cn(...)` call) only when a direction is unavailable — "opacity-40"
  // is the marker that is actually conditional, so assertions below key on
  // that instead.

  it("page 1 with hasNextPage=true renders Next enabled and Previous disabled", () => {
    render(<SettlementBatchesPager page={1} hasNextPage={true} buildHref={(p) => `/settlements?page=${p}`} />);

    const nextLink = screen.getByRole("link", { name: "التالي" });
    expect(nextLink.className).not.toContain("opacity-40");
    expect(nextLink.getAttribute("href")).toBe("/settlements?page=2");

    const prevLink = screen.getByRole("link", { name: "السابق" });
    expect(prevLink.className).toContain("opacity-40");
    // Previous must clamp to page 1, never go to page 0.
    expect(prevLink.getAttribute("href")).toBe("/settlements?page=1");
  });

  it("page 2 with hasNextPage=false renders Previous enabled (to page 1) and Next disabled", () => {
    render(<SettlementBatchesPager page={2} hasNextPage={false} buildHref={(p) => `/settlements?page=${p}`} />);

    const prevLink = screen.getByRole("link", { name: "السابق" });
    expect(prevLink.className).not.toContain("opacity-40");
    expect(prevLink.getAttribute("href")).toBe("/settlements?page=1");

    const nextLink = screen.getByRole("link", { name: "التالي" });
    expect(nextLink.className).toContain("opacity-40");
  });

  it("page 2 with hasNextPage=true renders both Next and Previous enabled, and preserves buildHref's own query string (filters survive pagination)", () => {
    render(
      <SettlementBatchesPager
        page={2}
        hasNextPage={true}
        buildHref={(p) => `/settlements?status=finalized&settlement_route_id=route-1&page=${p}`}
      />,
    );

    const nextLink = screen.getByRole("link", { name: "التالي" });
    expect(nextLink.getAttribute("href")).toBe("/settlements?status=finalized&settlement_route_id=route-1&page=3");
    expect(nextLink.className).not.toContain("opacity-40");

    const prevLink = screen.getByRole("link", { name: "السابق" });
    expect(prevLink.getAttribute("href")).toBe("/settlements?status=finalized&settlement_route_id=route-1&page=1");
    expect(prevLink.className).not.toContain("opacity-40");
  });
});

// ---------------------------------------------------------------------------
// Hotfix 7.1.1 §12 (migration 0196) — the filter-picker query wrappers call
// the NEW settlement_filter_payment_method_lookups()/settlement_filter_
// collection_channel_lookups() RPCs (gated on settlements.view alone),
// replacing the PREVIOUS direct payment_methods/collection_channels table
// reads that depended on those tables' own unrelated .view permissions (see
// queries.ts's own comment right above both functions). Exercised here at
// the query layer itself (real, unmocked queries.ts import, same rpcMock
// convention as the pagination tests above) rather than through a component
// that mocks the query away — the component-level rendering half (no
// permission-gating in the UI, disabled/historical rows still render) lives
// in tests/settlements-list-filter-pagination.test.tsx.
// ---------------------------------------------------------------------------
describe("getPaymentMethodFilterLookupsForSettlements()/getCollectionChannelFilterLookupsForSettlements() — call the settlement_filter_*_lookups() RPCs, return disabled/historical rows unfiltered", () => {
  beforeEach(() => rpcMock.mockReset());

  it("getPaymentMethodFilterLookupsForSettlements calls settlement_filter_payment_method_lookups and passes disabled/historical rows through untouched", async () => {
    const rows = [
      { id: "pm-1", name_ar: "فيزا" },
      { id: "pm-2", name_ar: "طريقة دفع معطّلة" }, // since-disabled — must still come back so an already-finalized batch stays filterable by it
    ];
    rpcMock.mockResolvedValue({ data: rows, error: null });

    const result = await getPaymentMethodFilterLookupsForSettlements();

    expect(rpcMock).toHaveBeenCalledWith("settlement_filter_payment_method_lookups");
    expect(result).toEqual(rows);
  });

  it("getCollectionChannelFilterLookupsForSettlements calls settlement_filter_collection_channel_lookups and passes disabled/historical rows through untouched", async () => {
    const rows = [{ id: "cc-1", name_ar: "قناة معطّلة" }];
    rpcMock.mockResolvedValue({ data: rows, error: null });

    const result = await getCollectionChannelFilterLookupsForSettlements();

    expect(rpcMock).toHaveBeenCalledWith("settlement_filter_collection_channel_lookups");
    expect(result).toEqual(rows);
  });

  it("a null data response is treated as an empty array, not a crash", async () => {
    rpcMock.mockResolvedValue({ data: null, error: null });

    expect(await getPaymentMethodFilterLookupsForSettlements()).toEqual([]);
    expect(await getCollectionChannelFilterLookupsForSettlements()).toEqual([]);
  });
});

