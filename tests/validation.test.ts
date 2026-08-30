import { describe, expect, it } from "vitest";
import { loginSchema } from "@/features/auth/schema";
import { storeFormSchema } from "@/features/stores/schema";
import { createUserSchema, roleFormSchema } from "@/features/users/schema";
import { appearanceSettingsSchema } from "@/features/settings/schema";
import { listSearchParamsSchema } from "@/lib/validation/common";
import { createShipmentSchema } from "@/features/shipping/schema";

describe("loginSchema", () => {
  it("accepts a valid email + password", () => {
    const result = loginSchema.safeParse({ email: "admin@store.sa", password: "secret123", rememberMe: "on" });
    expect(result.success).toBe(true);
  });

  it("rejects an invalid email", () => {
    const result = loginSchema.safeParse({ email: "not-an-email", password: "secret123" });
    expect(result.success).toBe(false);
  });

  it("rejects an empty password", () => {
    const result = loginSchema.safeParse({ email: "admin@store.sa", password: "" });
    expect(result.success).toBe(false);
  });
});

describe("storeFormSchema", () => {
  it("accepts a valid store", () => {
    const result = storeFormSchema.safeParse({ code: "RYD01", name_ar: "فرع الرياض", name_en: "", description: "", logo_url: "" });
    expect(result.success).toBe(true);
  });

  it("rejects a code with Arabic characters or spaces", () => {
    const result = storeFormSchema.safeParse({ code: "فرع 1", name_ar: "فرع الرياض" });
    expect(result.success).toBe(false);
  });

  it("rejects a name shorter than 2 characters", () => {
    const result = storeFormSchema.safeParse({ code: "RYD01", name_ar: "ر" });
    expect(result.success).toBe(false);
  });

  it("rejects an invalid logo_url when provided", () => {
    const result = storeFormSchema.safeParse({ code: "RYD01", name_ar: "فرع الرياض", logo_url: "not-a-url" });
    expect(result.success).toBe(false);
  });
});

describe("createUserSchema", () => {
  it("requires a password of at least 8 characters", () => {
    const result = createUserSchema.safeParse({ full_name: "أحمد علي", email: "a@b.com", password: "short" });
    expect(result.success).toBe(false);
  });

  it("defaults store_access_scope to single when omitted", () => {
    const result = createUserSchema.safeParse({ full_name: "أحمد علي", email: "a@b.com", password: "longenough123" });
    expect(result.success).toBe(true);
    if (result.success) expect(result.data.store_access_scope).toBe("single");
  });
});

describe("roleFormSchema", () => {
  it("accepts a role with only the Arabic name", () => {
    const result = roleFormSchema.safeParse({ name_ar: "مشرف فرع" });
    expect(result.success).toBe(true);
  });

  it("rejects a missing Arabic name", () => {
    const result = roleFormSchema.safeParse({ name_en: "Branch Supervisor" });
    expect(result.success).toBe(false);
  });
});

describe("appearanceSettingsSchema", () => {
  it("accepts a valid 6-digit hex color", () => {
    const result = appearanceSettingsSchema.safeParse({ accent_color: "#A9812E" });
    expect(result.success).toBe(true);
  });

  it("rejects a non-hex color value", () => {
    const result = appearanceSettingsSchema.safeParse({ accent_color: "gold" });
    expect(result.success).toBe(false);
  });
});

describe("createShipmentSchema — Hotfix 5.1.1 item 1 (customer_return_shipping_charge_override_reason)", () => {
  const baseOutbound = {
    sales_order_id: "11111111-1111-1111-1111-111111111111",
    store_id: "22222222-2222-2222-2222-222222222222",
    shipment_date: "2026-08-18",
    direction: "outbound" as const,
    carrier_id: "33333333-3333-3333-3333-333333333333",
    shipping_zone_id: "44444444-4444-4444-4444-444444444444",
    customer_shipping_charge: "25.00",
  };

  const baseReturn = {
    ...baseOutbound,
    direction: "return" as const,
    sales_return_id: "55555555-5555-5555-5555-555555555555",
  };

  it("accepts an outbound shipment with no override reason at all", () => {
    const result = createShipmentSchema.safeParse(baseOutbound);
    expect(result.success).toBe(true);
  });

  it("accepts a return shipment with no override reason (the DB, not this schema, enforces mandatory-when-diverging)", () => {
    const result = createShipmentSchema.safeParse(baseReturn);
    expect(result.success).toBe(true);
  });

  it("accepts a return shipment with a genuine override reason string", () => {
    const result = createShipmentSchema.safeParse({ ...baseReturn, customer_return_shipping_charge_override_reason: "العميل طلب توصيلًا سريعًا للإرجاع" });
    expect(result.success).toBe(true);
    if (result.success) expect(result.data.customer_return_shipping_charge_override_reason).toBe("العميل طلب توصيلًا سريعًا للإرجاع");
  });

  it("rejects an override reason longer than 500 characters", () => {
    const result = createShipmentSchema.safeParse({ ...baseReturn, customer_return_shipping_charge_override_reason: "س".repeat(501) });
    expect(result.success).toBe(false);
  });

  it("treats an empty-string override reason the same as omitted (undefined)", () => {
    const result = createShipmentSchema.safeParse({ ...baseReturn, customer_return_shipping_charge_override_reason: "" });
    expect(result.success).toBe(true);
    if (result.success) expect(result.data.customer_return_shipping_charge_override_reason).toBeUndefined();
  });
});

describe("listSearchParamsSchema", () => {
  it("applies sensible defaults when nothing is provided", () => {
    const result = listSearchParamsSchema.parse({});
    expect(result).toEqual({ q: "", page: 1, pageSize: 20 });
  });

  it("coerces string page/pageSize from URL search params", () => {
    const result = listSearchParamsSchema.parse({ page: "3", pageSize: "50" });
    expect(result.page).toBe(3);
    expect(result.pageSize).toBe(50);
  });

  it("rejects a pageSize above the max", () => {
    const result = listSearchParamsSchema.safeParse({ pageSize: "1000" });
    expect(result.success).toBe(false);
  });
});
