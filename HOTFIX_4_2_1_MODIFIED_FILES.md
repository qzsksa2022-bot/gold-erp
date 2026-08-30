# Hotfix 4.2.1 — قائمة كاملة بالملفات الجديدة/المُعدَّلة

(نفس القائمة الموجودة في `DELIVERY_REPORT.md` — الملحق التاسع عشر، القسم 5 — مُستخرَجة هنا كملف مستقل تسهيلًا للمراجعة السريعة، حسب طلب التسليم صراحةً.)

## ترحيلات جديدة (7) — 0106–0112، لا تعديل حرفي واحد على أي ترحيلة من 0001–0105

- `supabase/migrations/0106_return_refund_append_only_schema.sql` *(الجدول الملحق الجديد + الأعمدة الجديدة + المُشغِّلات + Backfill — Sections 1/2/3/6/13/17)*
- `supabase/migrations/0107_return_refund_events_append_only.sql` *(إعادة كتابة `record_sales_return_refund()`/`reverse_sales_return_refund_event()` + حارس الإلغاء المزدوج تحت تزامن حقيقي — Sections 1/6/17/19)*
- `supabase/migrations/0108_return_refund_reconciliation_append_only.sql` *(إعادة كتابة `finalize_sales_return_refund()`/`reopen_sales_return_refund_reconciliation()` لاشتقاق `actual_refunded_total` من الجدول الملحق الجديد)*
- `supabase/migrations/0109_return_fee_reversal_engine_v2.sql`
- `supabase/migrations/0110_return_preview_fee_reversal_v2_parity.sql`
- `supabase/migrations/0111_return_read_rpcs_append_only_v2.sql`
- `supabase/migrations/0112_return_narrow_sale_lookup.sql`

## اختبارات SQL جديدة بالكامل

- `supabase/tests/sales_returns_hotfix_4_2_1.test.sql`
- `supabase/tests/fixtures/hotfix_4_2_1_legacy_upgrade_pre_fixture.sql`
- `supabase/tests/upgrade_hotfix_4_2_1_legacy_refunds.test.sql`
- `scripts/run_upgrade_test_hotfix_4_2_1.sh`

## اختبارات SQL مُعدَّلة (إضافات/تصحيحات مقصودة موثَّقة فقط)

- `supabase/tests/sales_returns_core.test.sql` — سيناريو 3 فقط (الأساس التراكمي v2 الجديد)
- `supabase/tests/sales_returns_concurrency.test.sql` — تنظيف append-only + تصحيح تأكيد R5 + سيناريو R7 جديد بالكامل

## سكربت/إعداد HTTP مُعدَّلان

- `scripts/postgrest-http-test.mjs` — تأكيدات Hotfix 4.2.1 جديدة (`p_reference`، اشتقاق `status`، `refund_method_name_snapshot`، `payment_fee_reversal_calculation_version`، `search_sales_orders_for_return()`) + إصلاح استقرار حساب `todayIso`
- `supabase/tests/postgrest_http_test_setup.sql` — إصلاح استقرار: بيانات سعر ذهب تأسيسية لكلا `current_date`/`business_today()`

## كود TypeScript مُعدَّل

- `src/types/database.ts`
- `src/features/returns/schema.ts`
- `src/features/returns/actions.ts`
- `src/features/returns/queries.ts` *(تعليق توثيقي فقط)*
- `src/features/returns/components/refund-events-panel.tsx`
- `src/app/(app)/returns/[id]/page.tsx`

## اختبار Vitest جديد بالكامل

- `src/features/returns/components/refund-events-panel.test.tsx` *(5 اختبارات — التغطية الإلزامية لإصلاح Section 16)*

## توثيق مُحدَّث/جديد

- `DELIVERY_REPORT.md` — الملحق التاسع عشر مُضاف
- `TEST_RESULTS_HOTFIX_4_2_1.md` — جديد بالكامل
- `HOTFIX_4_2_1_MODIFIED_FILES.md` — هذا الملف

## لم يتغيَّر إطلاقًا

أي ترحيل من 0001–0105 (شاملة كل ترحيلات Phase 4/Patch 4.1/Patch 4.2)، أي جزء آخر من طبقة TypeScript خارج ما ذُكِر أعلاه، القفل الاستشاري `acquire_returns_order_lock_exclusive`، بقية سطح اختبار SQL (11 ملفًا خارج ما ذُكِر أعلاه).
