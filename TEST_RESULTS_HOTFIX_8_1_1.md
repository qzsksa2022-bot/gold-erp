# TEST_RESULTS_HOTFIX_8_1_1.md

## Phase 8 — Final Integrity Hotfix 8.1.1 — Reports/Dashboard/Exports — Basis-Aware Presentation, Export Completeness, Canonical COD & Filter Integrity

نتائج الاختبار الكاملة، كل رقم من تشغيل فعلي في هذه الجلسة تحديدًا (أُعيدت جميعها نظيفة في نهاية الجلسة، بعد آخر تعديل على أي ملف). التجميد صارم كسابقاته: **migrations 0001–0214 مُجمَّدة بالكامل** (§0) — تحقُّق مباشر عبر مقارنة الشجرة الكاملة بايت-لباَيت ضد آخر أرشيف مُسلَّم فعليًا `gold-erp-patch-8-1-reports-dashboard.zip` (SHA-256 `7fa1bf08853902c5bdf209e75dbd2afa224f30b2a526bab1e883740b011bb348`، مُتحقَّق مباشرةً هذه الجلسة أن هذا هو نفس الأرشيف المذكور في تقرير المراجعة) يؤكِّد **صفر اختلاف** على أي ترحيلة من الـ214. **الترحيلات 0215–0220 هي الجديدة كليًا** — الست الأولى (0215–0219) تُنفِّذ البنود الحرجة الصريحة في المواصفة، والسادسة (0220) إصلاح إضافي **اكتشفته** كتابة الاختبار الذاتي لهذا الهوتفكس نفسه (تفصيل كامل في القسم 6 أدناه).

---

## 1) اختبارات SQL — الحزمة الكاملة (44/44 ملف PASS)

كل ملف `*.test.sql` تحت `supabase/tests/` — تغطية Phase 2 وحتى Hotfix 8.1.1، بلا استثناء واحد — أُعيد تشغيله فعليًا هذه الجلسة، كل ملف على قاعدة بيانات مستقلة خاصة به (الاتفاقية القائمة — تفادي تلوُّث بيانات بين ملفات الاختبار):

**أ) 31 ملفًا ذاتية الاكتفاء (`begin;`...`rollback;` أو جلسة `psql` مستقلة) — كل واحد على قاعدة بيانات نظيفة مُهاجَرة بالكامل (0001–0220) + `seed.sql`:**

```
PASS: adjustments_core_phase6.test.sql
PASS: adjustments_core_phase6_concurrency.test.sql
PASS: adjustments_hotfix_6_1_2.test.sql
PASS: financial_integrity_hotfix_2_2_1.test.sql
PASS: financial_integrity_hotfix_2_2_2.test.sql
PASS: financial_integrity_patch_2_1.test.sql
PASS: financial_integrity_patch_2_2.test.sql
PASS: financial_master_data.test.sql
PASS: hotfix_8_1_1_reports_exports.test.sql          (جديد كليًا هذا الهوتفكس -- §23-26/§28-31/§32-35/§36/§6-10)
PASS: performance_reports_dashboard.test.sql
PASS: reports_dashboard_golden_scenario.test.sql
PASS: reports_detail_golden_scenario.test.sql
PASS: reports_golden_scenario_extended.test.sql
PASS: rls_and_permissions.test.sql
PASS: sales_core.test.sql
PASS: sales_integrity_hotfix_3_2_1.test.sql
PASS: sales_integrity_patch_3_1.test.sql
PASS: sales_integrity_patch_3_1_concurrency.test.sql
PASS: sales_integrity_patch_3_2.test.sql
PASS: sales_returns_concurrency.test.sql
PASS: sales_returns_core.test.sql
PASS: sales_returns_hotfix_4_2_1.test.sql
PASS: settlements_hotfix_7_1_1.test.sql
PASS: settlements_hotfix_7_1_2.test.sql
PASS: settlements_hotfix_7_1_3.test.sql
PASS: settlements_phase7.test.sql
PASS: settlements_phase7_concurrency.test.sql
PASS: shipping_core_phase5.test.sql
PASS: shipping_core_phase5_concurrency.test.sql
PASS: shipping_integrity_hotfix_5_1_1.test.sql
PASS: shipping_integrity_patch_5_1.test.sql
```

**ب) 13 اختبار ترقية (فِكستشر ما-قبل ترحيلة معيَّنة → هجرة جزئية → تأكيد) — كل واحد عبر سكربته المخصَّص:**

```
PASS: run_upgrade_test.sh                              (upgrade_from_0039.test.sql)
PASS: run_upgrade_test_hotfix_4_2_1.sh                 (upgrade_hotfix_4_2_1_legacy_refunds.test.sql)
PASS: run_upgrade_test_patch_4_2.sh                    (upgrade_patch_4_2_legacy_returns.test.sql)
PASS: run_upgrade_test_patch_6_1.sh                    (upgrade_patch_6_1_fixtures.test.sql)
PASS: run_upgrade_test_phase6_adjustments.sh            (upgrade_phase6_adjustments.test.sql)
PASS: run_upgrade_test_phase7_settlements.sh            (upgrade_phase7_settlements.test.sql)
PASS: run_upgrade_test_phase7_1_settlements.sh          (upgrade_phase7_1_settlements.test.sql)
PASS: run_upgrade_test_hotfix_7_1_1_settlements.sh      (upgrade_hotfix_7_1_1_settlements.test.sql)
PASS: run_upgrade_test_hotfix_7_1_2_settlements.sh      (upgrade_hotfix_7_1_2_settlements.test.sql)
PASS: run_upgrade_test_hotfix_7_1_3_settlements.sh      (upgrade_hotfix_7_1_3_settlements.test.sql)
PASS: (فحص مباشر بهجرة كاملة)                          (upgrade_phase8_reports_dashboard.test.sql -- §97/§100، 0199-0204 فوق 0001-0198 المُجمَّدة)
PASS: run_upgrade_test_phase8_multidomain.sh            (upgrade_phase8_multidomain.test.sql -- §52-53 Patch 8.1، بيانات حقيقية متعددة النطاقات عبر 0198->latest، مُعاد التحقُّق منه فوق 0215-0220 الجديدة أيضًا)
PASS: run_upgrade_test_hotfix_8_1_1_reports.sh          (upgrade_hotfix_8_1_1_reports.test.sql -- جديد كليًا هذا الهوتفكس، §60، تفصيل في القسم 3 أدناه)
```

**المجموع: 44/44 ملف Exit 0، صفر انحدار على أي ملف من Phase 2 وحتى Patch 8.1.**

### الملف الجديد `hotfix_8_1_1_reports_exports.test.sql` — تفصيل الأقسام الستة

| القسم | الموضوع | النتيجة |
|---|---|---|
| A | §23-26 CRITICAL — تطابق `collection_transitions` الكامل مع محوِّل Phase 7: سلسلة 9 استدعاءات `record_shipment_cod_collection_state` (`unknown→expected→collected→collected→expected→collected→unknown→not_collected→collected→not_collected`) | **PASS** — 4 صفوف فعلية بالضبط (3× +500، 1× -500)، `net_cod_collection_effect=1000.00`، صفر عكس وهمي |
| B1-B3 | §28-30 CRITICAL — فلتر `effective_status='draft'` حقيقي يعمل فعليًا؛ دفعة مسودة تُساهم بصفر ماليًا؛ Rows والملخَّص المالي يتشاركان نفس المجموعة المُصفَّاة تمامًا | **PASS** |
| B4 | §31 CRITICAL — `has_variance` من ممثِّل بلا `settlements.view_financials` يُرفَض صراحةً (استثناء)، لا يُتجاهَل صامتًا | **PASS** |
| C1-C4 | §32-35 — مجموعة فلاتر Adjustments الكاملة: استقلال `original_sale_store_id`/`processing_store_id`، `participates_in_settlement=false` منطقي حقيقي (لا يُسقَط كقيمة زائفة)، `movement_type` | **PASS** |
| D1-D3 | §36 — دلالة `refund_method_id` المعتمدة على الأساس: بلا أثر تحت `business_effect`، بالأثر الصحيح تحت `actual_cash` | **PASS** |
| F1-F3 | §6-10 CRITICAL — بوابة Payment Methods الأساسية `reports.view` فقط (لا `sales.view` أبدًا)، كل قسم من الأقسام الثلاثة مُبوَّب صلاحيةً مستقلة عن الآخر | **PASS** — ممثِّل بصلاحيتَي `reports.view`+`returns.view` فقط يرى قسم الاسترداد النقدي حصرًا (لا `rows`/`summary` المبيعات، لا `settlement_rows`/`settlement_summary`) |

---

## 2) الترحيلات الست الجديدة (0215–0220) — جدول كامل

| # | الترحيلة | الغرض المختصر |
|---|---|---|
| 0215 | `items_adjustments_export_cap_and_filters.sql` | سقف تصدير `get_items_report()`/`get_adjustments_report()` يرتفع 500 → 5000 (§11-14/§60)؛ `get_adjustments_report()` يكتسب مجموعة فلاتر كاملة جديدة (§32-35: `p_original_sale_store_id`, `p_processing_store_id`, `p_payment_method_id`, `p_collection_channel_id`, `p_participates_in_settlement`, `p_movement_type`, `p_created_by`, `p_approved_by`) — توقيع مُغيَّر، `DROP FUNCTION` + `CREATE` صريح. |
| 0216 | `cod_report_canonical_reversal_and_historical_labels.sql` | §23-26 CRITICAL — إصلاح "الانعكاس الوهمي" في `collection_transitions`: العكس الحقيقي الوحيد هو `collected→not_collected` صراحةً؛ أي انتقال آخر (`collected→expected`, `collected→unknown`, إلخ) أثره صفر ويُستبعَد كليًا من الصفوف بدل احتسابه انعكاسًا زائفًا. زائد §27 تسميات Settlement التاريخية من لقطة الدفعة لا من ربط حي. |
| 0217 | `payment_methods_settlement_historical_labels.sql` | نفس إصلاح التسميات التاريخية (§27) لقسم Settlement داخل `get_payment_methods_report()` تحديدًا. |
| 0218 | `settlements_report_filtered_summary_and_draft.sql` | §28-31 CRITICAL — `filtered_batch_scope` واحدة تُطبَّق مرة واحدة فتُغذِّي Rows **و** الملخَّص المالي معًا (لا يمكن أن يختلفا بعد اليوم)؛ `p_effective_status='draft'` فلتر حقيقي يعمل (كان كودًا ميتًا سابقًا)؛ `has_variance` من ممثِّل بلا `settlements.view_financials` يُرفَض صراحةً بدل التجاهل الصامت. |
| 0219 | `returns_report_filter_semantics.sql` | §36 — `refund_method_id` أصبح بلا أثر تحت أساس `business_effect` (يُصفِّي على طريقة البيع الأصلية فقط)، وبالأثر الصحيح تحت `actual_cash` فقط. |
| 0220 | `report_settlement_store_scope_draft_zero_lines_fix.sql` | **إصلاح إضافي اكتشفته كتابة الاختبار الذاتي** — تفصيل كامل في القسم 6. |

**إضافة-فقط مؤكَّدة:** فحص مباشر عبر الست ترحيلات يؤكِّد صفر حالة `ALTER TABLE`/`DROP TABLE`/`DROP COLUMN`/`ADD COLUMN`/`CREATE TABLE` — فقط `CREATE [OR REPLACE] FUNCTION`/`DROP FUNCTION IF EXISTS <توقيع دقيق>` (عند تغيُّر التوقيع فقط)/`COMMENT`/`REVOKE`/`GRANT EXECUTE`.

---

## 3) اختبار ترقية القاعدة التاريخية الجديد (§60) — `upgrade_hotfix_8_1_1_reports.test.sql`

تسلسل حقيقي: قاعدة بيانات فارغة → ترحيلات 0001–0214 فقط (المُجمَّدة، قبل هذا الهوتفكس) → `seed.sql` → **فِكستشر ما-قبل** (`fixtures/hotfix_8_1_1_upgrade_pre_fixture.sql`) يُنشئ، عبر RPCs 0214 القديمة نفسها (`record_shipment_cod_collection_state`/`create_draft_settlement_batch`/`finalize_settlement_batch`، **بلا تعديل من هذا الهوتفكس على أيٍّ منها**)، **بيانات حقيقية مُثبَّتة (COMMITTED) لا يُتراجَع عنها أبدًا**: نفس سلسلة الـ9 استدعاءات COD تحديدًا، ودفعة تسوية مسودة أبدية (صفر أسطر بالتصميم) + دفعة منتهية منفصلة على نفس المسار → ترحيلات 0215–latest تُطبَّق فوقها → الاختبار يقرأ البيانات القديمة عبر RPCs التقرير **الجديدة**:

- **PASS A:** `get_cod_report(basis='collection_transitions')` يُعيد اشتقاق مصفوفة التطابق ذاتها (4 صفوف، `net_cod_collection_effect=1000.00`، صفر انعكاس وهمي) فوق سجل `shipment_cod_events` مكتوب بالكامل **قبل** وجود 0216 — إثبات أن الإصلاح رجعي الأثر على البيانات التاريخية، لا مقصور على بيانات أُنشئت بعد شحنه.
- **PASS B:** `get_settlements_report(effective_status='draft')` يُظهِر الدفعة المسودة التاريخية (الموجودة منذ قبل 0218 **و**0220) بمساهمة مالية صفرية، ويعزل الدفعة المنتهية بـ`batches_count=1` صحيح.

النتيجة: **Exit 0**، كل الأرقام مطابقة تمامًا لِما أثبته `hotfix_8_1_1_reports_exports.test.sql` على بيانات طازجة — هذا الهوتفكس آمن تمامًا فوق أي قاعدة بيانات حقيقية من Patch 8.1.

---

## 4) HTTP/PostgREST حقيقي — 350/350 تأكيد `OK`، صفر `FAIL`

قسم **"Part 20" جديد كليًا (9 تأكيدات، البنود A–C)** فوق Parts 1–19 القائمة بلا أي تعديل على منطقها (341 تأكيد كانت قائمة من Patch 8.1، الآن 350):

- **البند A (§11-14):** `get_items_report()`/`get_adjustments_report()` — طلب `p_limit=6000` يُصفَّى فعليًا إلى السقف الجديد **5000** (لا 500 القديم) عبر HTTP حقيقي.
- **البند B (§28-30/0220 CRITICAL):** دفعة تسوية مسودة حقيقية تُنشَأ عبر HTTP، ثم `get_settlements_report(effective_status='draft')` يُظهِرها بمعرِّفها الحقيقي بملخَّص مالي صفري — **كانت هذه الحالة تُعيد صفر صفوف دائمًا قبل 0220**، بصرف النظر عن الفلتر، لأن دفعة بصفر أسطر لم تكن تجتاز فحص نطاق المتجر إطلاقًا (تفصيل كامل في القسم 6). رفض القيمة غير الصالحة لا يزال يعمل.
- **البند C (§32-35 CRITICAL):** تعديلان حقيقيان على نفس الطلب — أحدهما بمعالجة `STORE_B_ID`/`participates_in_settlement=false` — يُثبِتان أن `p_processing_store_id` و`p_participates_in_settlement=false` يصلان فعليًا عبر HTTP كقيم منطقية/معرِّفات حقيقية تُصفِّي فعليًا، لا تُسقَط أو تُحوَّل لنص.

تصحيح واحد أثناء التطوير (لا خطأ إنتاجي): اختبار البند C الأول نسي استدعاء `approve_sales_order_adjustment()` بعد الإنشاء — `get_adjustments_report()` يُظهِر **الحركات** المعتمدة فقط، فتعديل مُعلَّق لا يظهر في أي فلتر بالتصميم؛ أُضيف استدعاء الاعتماد فمرَّ الاختباران فورًا.

---

## 5) Vitest — 423/423 PASS عبر 32 ملفًا

جميع الملفات القائمة (32 ملفًا) بلا استثناء، منها 4 اختبارات جديدة صراحةً هذه الجلسة داخل `tests/reports-export-route-integration.test.ts` (§11-14/§60 — حدود سقف التصدير الصريحة `51/501/1200/5000` — القيمتان 501 و1200 كانتا سترفضان خطأً تحت السقف القديم 500؛ 5001 مُغطَّاة سلفًا ضمن اختبار `export_too_large` القائم). صفر انحدار.

أهم إعادات البناء المُتحقَّق منها هذه الجلسة:
- `src/features/reports/export/excel.ts` أُعيد بناؤه بالكامل (توقيع جديد قائم على الأقسام `renderTableReportExcel(sections, meta)`)، مُختبَر عبر `tests/reports-export-generation.test.ts` (20/20) و`tests/reports-export-route-integration.test.ts` (15/15).
- `tests/reports-export-route-integration.test.ts` — 4 اختبارات جديدة كليًا لهذا الهوتفكس (§13 حارس `export_incomplete_dataset`؛ §6-10 Payment Methods 3-أقسام؛ §79/§9 حذف قسم؛ §2/§36 أعمدة العائد المعتمدة على الأساس) + 4 اختبارات حدود جديدة (هذا القسم).

---

## 6) الإصلاح الإضافي المُكتشَف — ترحيلة 0220

أثناء كتابة `hotfix_8_1_1_reports_exports.test.sql` (قسم B، §28-31)، فشل الاختبار في إثبات ظهور دفعة مسودة فعلية عبر `get_settlements_report(effective_status='draft')` — **صفر صفوف دائمًا، بصرف النظر عن قيمة الفلتر**. التشخيص: `create_draft_settlement_batch()` (0177) "لا تحجز شيئًا ماليًا: لا صف `settlement_source_claims`، لا صف `settlement_batch_lines`" — أي دفعة مسودة حقيقية (لم تُعتمَد بعد) لها **صفر أسطر** بالتصميم دائمًا. الدالة الداخلية المشتركة `_report_settlement_batch_in_store_scope()` (0200، تُستخدَم في `get_dashboard_summary()`/`get_payment_methods_report()`/`get_cod_report()`/`get_settlements_report()`/تقارير التسويات الدورية) كانت تشترط `exists(select 1 from settlement_batch_lines where ...)` **كأول شرط** — فدفعة بصفر أسطر تُستبعَد **دائمًا**، بصرف النظر عن نطاق المتجر، مما يجعل إصلاح `p_effective_status='draft'` في 0218 كودًا ميتًا فعليًا لأي دفعة مسودة حقيقية لم تُعتمَد بعد.

القرينة الحاسمة: الدالة المكافئة تمامًا في نطاق Settlements نفسه، `_settlement_batch_all_stores_visible()` (0186، تُستخدَم في `list_settlement_batches()`/`get_settlement_batch()`)، تحمل التعليق الصريح التالي منذ Patch 7.1: *"Vacuously true for a batch with zero lines (a draft — nothing to hide yet)"* — أي القطبية **الصحيحة المُثبَتة أصلًا** في مكان آخر من نفس المشروع. الدالة الخاصة بطبقة Reports فقط كانت تحمل القطبية **المعكوسة** خطأً.

**الإصلاح (0220):** `_report_settlement_batch_in_store_scope()` أصبحت الآن صحيحة اصطلاحيًا **حقًّا فارغًا (Vacuously True)** لدفعة بصفر أسطر — نفس قطبية 0186 تمامًا، بلا أي تغيير آخر. **الأمان مؤكَّد لكل الاستخدامات السبعة الأخرى:** كل مستدعٍ آخر (`get_dashboard_summary` ×2، `get_payment_methods_report`، `get_cod_report` ×2، تقارير Settlements الدورية) يُقيِّد مصدره الخاص أصلًا إلى `status in ('finalized', 'reconciled')` — ودفعة مُنتهية/مُصالَحة تملك سطرًا واحدًا على الأقل ببناء `finalize_settlement_batch()` نفسها دائمًا — فالفرع "صفر أسطر" كان كودًا ميتًا تمامًا لكل تلك الاستدعاءات؛ هذا الإصلاح لا يُغيِّر سلوكها إطلاقًا، ولا يبدأ بالتأثير الفعلي إلا على مسار `get_settlements_report()`'s الجديد بالضبط الذي كان يحتاجه.

مُثبَت حيًّا عبر ثلاثة مسارات مستقلة بعد الإصلاح: (1) `hotfix_8_1_1_reports_exports.test.sql` قسم B1، (2) `upgrade_hotfix_8_1_1_reports.test.sql` قسم B (بيانات تاريخية من قبل 0220)، (3) "Part 20" item B عبر HTTP/PostgREST حقيقي.

---

## 7) TypeScript / ESLint / بناء Next.js الإنتاجي

- **TypeScript:** `npx tsc --noEmit` — **صفر خطأ**.
- **ESLint:** `npx eslint .` — **صفر خطأ** (4 تحذيرات `no-unused-vars` قائمة مسبقًا في `tests/adjustments-entry-form-zero-charge-state-machine.test.tsx`، ملف لم يُلمَس هذه الجلسة إطلاقًا — غير متعلقة بهذا الهوتفكس).
- **بناء إنتاجي:** `npm run build` — ناجح بالكامل، **48 مسارًا** مُولَّدًا (بما فيها كل صفحات `/reports/*` الـ16 المُعاد بناؤها لاستخدام مُحلِّل الأقسام الجديد `resolveReportSections`، `/api/reports/export`، `/dashboard`).

---

## 8) الملفات الجديدة/المُعدَّلة — مقارنة كاملة بايت-لباَيت مقابل `gold-erp-patch-8-1-reports-dashboard.zip`

**حُذِف: لا شيء إطلاقًا (0 ملف).**

**مُطابقة بايت-لباَيت (0 اختلاف):** كل ترحيلة من 0001–0214 (214/214، فحص `diff` مباشر لكل ملف على حدة).

**جديدة بالكامل (13 ملفًا):**
- 6 ترحيلات: `0215_items_adjustments_export_cap_and_filters.sql`, `0216_cod_report_canonical_reversal_and_historical_labels.sql`, `0217_payment_methods_settlement_historical_labels.sql`, `0218_settlements_report_filtered_summary_and_draft.sql`, `0219_returns_report_filter_semantics.sql`, `0220_report_settlement_store_scope_draft_zero_lines_fix.sql`.
- `src/features/reports/export/presentation.ts` (مُحلِّل عرض التقرير الأساسي/متعدد الأقسام — §1/§5/§46).
- `src/features/reports/export/filter-labels.ts` (تسميات الفلاتر المُحلَّة لبيانات تعريف التصدير — §20-22).
- `src/features/reports/components/report-sections.tsx` (مكوِّن React مشترك لعرض الأقسام على الشاشة — §46).
- `supabase/tests/hotfix_8_1_1_reports_exports.test.sql` (اختبار SQL شامل جديد، تفصيل في القسم 1).
- `supabase/tests/upgrade_hotfix_8_1_1_reports.test.sql` + `supabase/tests/fixtures/hotfix_8_1_1_upgrade_pre_fixture.sql` (اختبار ترقية §60، تفصيل في القسم 3).
- `scripts/run_upgrade_test_hotfix_8_1_1_reports.sh`.

**مُعدَّلة في مكانها (18 ملفًا):**
- `src/features/reports/export/excel.ts` (إعادة بناء كاملة — تقسيم Summary+Data، §15-19)، `pdf.ts` (عرض متعدد الأقسام، §46-49)، `report-registry.ts` (تسميات `draft` المفقودة + إصلاحات تعليقات)، `queries.ts` (إصلاح تعليق JSDoc قديم).
- `src/app/api/reports/export/route.ts` (المُحلِّل الجديد + بيانات تعريف مُوسَّعة، §11-22).
- 8 صفحات تقارير: `reports/{returns,shipping,cod,payment-methods,categories,adjustments,settlements}/page.tsx` + `dashboard/page.tsx`.
- `src/features/dashboard/components/period-presets.tsx` (إصلاح مفتاح Last Week/Last Year، §43-45).
- `scripts/postgrest-http-test.mjs` (قسم "Part 20" الجديد، §11-14/§28-31/§32-35).
- `supabase/tests/fixtures/phase8_golden_scenario_fixture.sql` (إصلاح تصلُّب تاريخ ما-قبل-موجود في الفِكستشر — غير ناتج عن هذا الهوتفكس، مُوثَّق في التعليقات).
- `tests/reports-export-generation.test.ts` (إعادة كتابة كاملة لتوقيعات الأقسام الجديدة)، `tests/reports-export-route-integration.test.ts` (8 اختبارات جديدة).
- `DELIVERY_REPORT.md` (هذا الملحق).

**لم يتغيَّر إطلاقًا:** `supabase/seed.sql`، `.env.example`، `src/types/database.ts` (لا جدول/عمود جديد — هذا الهوتفكس طبقة قراءة فقط)، أي اختبار قائم من Phase 2 وحتى Patch 8.1 (لم يُحذَف ولم يُضعَف أي منها).

---

## 9) تأكيد عدم بدء Phase 9

لم يبدأ أي عمل يخص Phase 9 أو أي وحدة محظورة إطلاقًا (Inventory، Salla API، Carrier API، Bank API، GL، Attachments، Backups، 2FA). كل تغيير مقصور حصرًا على تشديد/تصحيح/إكمال عقد طبقة Reports/Dashboard/Export القائمة — لا جدول جديد، لا عمود بيانات إنتاجي جديد، لا كتابة بيانات جديدة (باستثناء المسودة القياسية `settlement_batches.status='draft'` القائمة أصلًا منذ Phase 7).

---

*نهاية التقرير.*
