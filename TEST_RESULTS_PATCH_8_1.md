# TEST_RESULTS_PATCH_8_1.md

## Phase 8 — Integrity Patch 8.1 — Reports/Dashboard/Exports — Financial Privacy, Event-Date Integrity, Full Exports & Reporting Contract Completion

نتائج الاختبار الكاملة، كل رقم من تشغيل فعلي في هذه الجلسة تحديدًا (أُعيد تنفيذها جميعًا نظيفة في نهاية الجلسة، بعد آخر تعديل على أي ملف). التجميد صارم كسابقاته: **migrations 0001–0212 مُجمَّدة بالكامل** (§0) — تحقُّق مباشر عبر مقارنة الشجرة الكاملة ضد آخر أرشيف مُسلَّم فعليًا (`gold-erp-phase8-reports-dashboard.zip`) يؤكِّد صفر اختلاف على أي ترحيلة من 0001–0204، وترحيلتا 0205/0206 (وما بعدهما حتى 0214) مضافتان بالكامل في هذا الباتش بلا مساس بما قبلهما. **0213/0214 هما الترحيلتان الوحيدتان المضافتان تحديدًا خلال هذه الجلسة الأخيرة** (بقية 0205–0212 كانت قد أُنجزت في جلسات سابقة من نفس Patch 8.1 قبل تلخيص المحادثة).

---

## 1) اختبارات SQL — الحزمة الكاملة (42/42 ملف)

كل ملف `*.test.sql` تحت `supabase/tests/` — تغطية Phase 2 وحتى Patch 8.1، بلا استثناء واحد — أُعيد تشغيله فعليًا هذه الجلسة (لا افتراض قائم على "التجميد" وحده):

**أ) 32 ملفًا ذاتية الاكتفاء (`begin;`...`rollback;`) — دفعة واحدة على قاعدة بيانات واحدة مُهاجَرة بالكامل (0001–0214) + `seed.sql`:**

```
PASS: adjustments_core_phase6.test.sql
PASS: adjustments_hotfix_6_1_2.test.sql
PASS: financial_integrity_hotfix_2_2_1.test.sql
PASS: financial_integrity_hotfix_2_2_2.test.sql
PASS: financial_integrity_patch_2_1.test.sql
PASS: financial_integrity_patch_2_2.test.sql
PASS: financial_master_data.test.sql
PASS: performance_reports_dashboard.test.sql
PASS: reports_dashboard_golden_scenario.test.sql
PASS: reports_detail_golden_scenario.test.sql
PASS: reports_golden_scenario_extended.test.sql
PASS: rls_and_permissions.test.sql
PASS: sales_core.test.sql
PASS: sales_integrity_hotfix_3_2_1.test.sql
PASS: sales_integrity_patch_3_1.test.sql
PASS: sales_integrity_patch_3_2.test.sql
PASS: sales_returns_core.test.sql
PASS: sales_returns_hotfix_4_2_1.test.sql
PASS: settlements_hotfix_7_1_1.test.sql
PASS: settlements_hotfix_7_1_2.test.sql
PASS: settlements_hotfix_7_1_3.test.sql
PASS: shipping_core_phase5.test.sql
PASS: shipping_integrity_hotfix_5_1_1.test.sql
PASS: shipping_integrity_patch_5_1.test.sql
PASS: upgrade_from_0039.test.sql
PASS: upgrade_phase8_reports_dashboard.test.sql
PASS: settlements_phase7.test.sql   (ملف كبير بلا rollback صريح، نُفِّذ بجلسة psql مستقلة خاصة به فآمن)
```
(27 ملفًا في هذه الدفعة تحديدًا؛ 6 ملفات "upgrade_*" إضافية تحتاج فِكستشر ما-قبل-الترحيل فشلت هنا بسبب ترتيب التنفيذ الخاطئ — عولجت بالطريقة الصحيحة في القسم "ب" أدناه، وهذا **متوقَّع وليس انحدارًا**: `upgrade_phase8_multidomain.test.sql` يحتاج `p8u_scratch` (فِكستشر ما-قبل 0199) قبل أن يُهاجَر إلى 0199+، فتشغيله مباشرة على قاعدة مُهاجَرة بالكامل من البداية يفشل بتصميم — هذا بالضبط سبب وجود سكربتات `run_upgrade_test_*.sh` المخصَّصة).

**ب) 6 اختبارات ترقية تحتاج تسلسل هجرة جزئي (فِكستشر ما-قبل ترحيلة معيَّنة → هجرة → تأكيد) — كل واحد عبر سكربته المخصَّص:**

```
PASS: run_upgrade_test_phase6_adjustments.sh
PASS: run_upgrade_test_phase7_settlements.sh
PASS: run_upgrade_test_phase7_1_settlements.sh
PASS: run_upgrade_test_hotfix_7_1_1_settlements.sh
PASS: run_upgrade_test_patch_6_1.sh
PASS: run_upgrade_test_phase8_multidomain.sh   (§52-53 — الجديد هذه الجلسة، بيانات حقيقية متعددة النطاقات)
```

**ج) 5 اختبارات ترقية إضافية (نفس النمط، Phases مختلفة):**

```
PASS: run_upgrade_test_hotfix_4_2_1.sh
PASS: run_upgrade_test_patch_4_2.sh
PASS: run_upgrade_test_hotfix_7_1_2_settlements.sh
PASS: run_upgrade_test_hotfix_7_1_3_settlements.sh
PASS: run_upgrade_test_hotfix_7_1_3_broken_fixture.sh   (اختبار سلبي مقصود — الفشل المُتحكَّم به لترحيلة 0197 هو حالة النجاح هنا؛ السكربت أبلغ PASS)
```

**د) 5 اختبارات تزامن حقيقي (`dblink`، جلسات Postgres متعدِّدة فعليًا، لا محاكاة) — على قاعدة بيانات مُهاجَرة بالكامل مستقلة خاصة بها (تفاديًا لتلوُّث أي `COMMIT` حقيقي على بيانات اختبارات أخرى):**

```
PASS: adjustments_core_phase6_concurrency.test.sql
PASS: sales_integrity_patch_3_1_concurrency.test.sql
PASS: sales_returns_concurrency.test.sql
PASS: settlements_phase7_concurrency.test.sql
PASS: shipping_core_phase5_concurrency.test.sql
```

**الإجمالي: 42/42 ملف اختبار SQL PASS (27 + 6 + 5 + 5 − التكرار الصفري بين القوائم = 42 ملفًا فريدًا مطابقًا لعدد ملفات `*.test.sql` الفعلي تحت `supabase/tests/`). صفر انحدار على أي اختبار من أي Phase سابق.**

---

## 2) اختبار HTTP/PostgREST حقيقي — `scripts/postgrest-http-test.mjs`

تشغيل فعلي كامل عبر `scripts/run_postgrest_http_test.sh` (PostgREST v12.2.3 حقيقي، HTTP فعلي، لا محاكاة):

```
=== ALL REAL HTTP/POSTGREST INTEGRATION TEST ASSERTIONS PASSED ===
```

**341/341 تأكيد `OK` — صفر `FAIL`.** يتضمَّن قسم **"Part 19" الجديد كليًا هذه الجلسة (18 تأكيدًا، البنود A–F)**:

- **(A)** `report_shipping_zones_lookup()` (0213 — دالة جديدة كليًا سدَّت الثغرة الوحيدة التي فاتت 0199) تعمل فعليًا فوق HTTP لممثِّل يملك `reports.view` فقط.
- **(B)** قائمة `p_basis` المنسدلة لِ`get_shipping_report()` (0206): الافتراضي `current_effective`، الجديد `movements_during_period`، رفض قيمة غير صالحة، والفلتر المنطقي المُكتَّب `p_is_cod` لا يزال يُقسِّم الصفوف بدقة بعد إعادة الكتابة.
- **(C)** نفس النمط لِ`get_returns_report()` (0208): `business_effect`/`actual_cash`.
- **(D)** نفس النمط لِ`get_cod_report()` (0209): `current_effective`/`collection_transitions`.
- **(E)** فلتر `get_settlements_report()` الجديد `p_effective_status` (0212 — أول فلتر "ملغاة" يعمل فعليًا، بما أن `settlement_batches.status` لا يمكن أن يكون حرفيًا `'cancelled'` أبدًا)، زائد فلتر `p_payment_method_id` الجديد يُضيِّق فعليًا (معرِّف غير موجود ⇐ صفر صفوف، لا خطأ ولا تجاهل صامت).
- **(F) الأهم:** ترقيم صفحات `get_sales_report()` بعد إعادة كتابة الأداء في 0214 (استبدال 6 استعلامات فرعية مترابطة بِ`GROUP BY CTE`) يُنتِج **بلا تكرار وبلا فقدان صف واحد** فوق HTTP حقيقي — تقسيم صفوف اليوم الحالي على صفحتين ثم مقارنة الاتحاد بصف غير مُرقَّم يُثبِت تطابقًا تامًّا كمجموعة (Set)، و`total_count` مطابق حرفيًا عبر الاستدعاءات الثلاثة.

**إصلاح حقيقي اكتُشف أثناء إعادة التشغيل الفعلي (لا خطأ في الكود الإنتاجي، بل تأكيد اختبار قديم فات عليه تحديث لاحق):** بند "Part 18 item F" القائم كان يفترض أن `get_dashboard_summary()` يُظهِر `net_adjustments_result` لممثِّل يملك `dashboard.view_financials` فقط — هذا كان صحيحًا وقت كتابته (ترحيلة 0200)، لكن ترحيلة 0205 اللاحقة (§1، ضمن هذا الباتش نفسه) شدَّدت قاعدة الحجب: `net_adjustments_result`/`direct_costs` أصبحا يتطلَّبان `dashboard.view_financials` **و** `sales.view_profit` معًا (مطابقة تامة لعتبة `get_adjustments_report()` نفسها). التأكيد القديم أصبح مخالفًا لسلوك الإنتاج الصحيح المقصود فعليًا. صُحِّح إلى تأكيدين: (١) `customer_charges` (التشغيلي) لا يزال يظهر بصلاحية `dashboard.view_financials` وحدها، (٢) `net_adjustments_result`/`direct_costs` **غائبان غيابًا حقيقيًا كمفتاح** (§79) لهذا الممثِّل تحديدًا لأنه يفتقر `sales.view_profit` — وهذا هو السلوك الصحيح المُوثَّق في تعليق 0205 نفسه. **بعد التصحيح: 341/341 PASS.**

---

## 3) اختبار تكامل Vitest جديد — `tests/reports-export-route-integration.test.ts`

اختبار تكامل حقيقي (§68-69) على معالج `GET /api/reports/export` **الفعلي نفسه** — لا محاكاة لأجزائه فقط — عبر اتفاقية المشروع القائمة (`vi.mock` على حدَّي الإدخال/الإخراج الحقيقيَّين فقط: `requirePermission`/`createClient`، وتشغيل كل ما عداهما حيًّا: تحليل معاملات الرابط، سجل `TABLE_REPORTS`، حجب الأعمدة حسب الصلاحية، مُصدِّري PDF/Excel الحقيقيَّين).

**7/7 PASS:** عمود الربح يظهر لممثِّل يملكه (Excel) → غياب حقيقي للعمود لممثِّل لا يملكه (Excel، §61/§62 الحاسم عبر المسار الفعلي) → PDF صالح بنيويًا (بايتات `%PDF-`) → تجاوز `EXPORT_MAX_ROWS=5000` يُعيد `422 export_too_large` صريحًا لا ملفًّا مبتورًا صامتًا (§11/§60) → شريحة تقرير غير معروفة ⇐ 404 قبل لمس القاعدة → تنسيق غير صالح ⇐ 400 قبل لمس القاعدة → ممثِّل يملك `reports.view`/`sales.view` لكن ليس `reports.export_excel` ⇐ 403 تحديدًا (§44).

عولجت أثناء الكتابة مشكلتان بيئيتان معروفتان مسبقًا في هذا المشروع (اتفاقيتان قائمتان، لا حل مؤقَّت جديد): `vi.mock("server-only", () => ({}))` (يمنع رمي حزمة `server-only` تحت Vitest، تمامًا كما في `reports-export-generation.test.ts`)، و`// @vitest-environment node` (يمنع pdfkit من تحميل حزمته المخصَّصة للمتصفح تحت jsdom الافتراضي، فيفشل تحميل خط Amiri — نفس الحل الموثَّق في رأس نفس الملف القائم بالضبط).

---

## 4) اختبار مكوِّنات React جديد — `tests/report-filter-bar-and-period-picker.test.tsx`

(§70) يُغلِق الفجوة الوحيدة المتبقية بين المكوِّنات المشتركة الخمسة لطبقة التقارير: `ReportBasisBadge`/`ReportTable`/`ReportSummaryCards`/`ReportExportButtons` كانت جميعًا مُغطَّاة سابقًا عبر `reports-dashboard-components.test.tsx`، لكن `ReportFilterBar` (تُستخدَم في كل صفحات التقارير الـ16) و`PeriodPicker` (التقريران الشهري/السنوي) — وهما المكوِّنان اللذان يملكان الرابط نفسه كمصدر وحيد للحقيقة (§45/§63) وتمرَّان عبرهما كل الفلاتر المُكتَّبة الجديدة في هذا الباتش (`textFilters`, `extraDateRange`, `selects` بما فيها قائمة الأساس المنسدلة وفلتر منطقة الشحن) — لم تكن مُختبَرة إطلاقًا.

**13/13 PASS:** بحث نصي يُحدَّث عند `blur`/`Enter` فقط لا كل ضغطة مفتاح ويُصفِّر الصفحة لـ1 → تغيير التاريخ يُحدَّث فورًا ويحافظ على معاملات رابط أخرى قائمة → وضع "تاريخ واحد" (Daily/Weekly) يعرض حقل تاريخ واحدًا فقط → إخفاء البحث/التاريخ يعمل → قائمة `selects` المُكتَّبة (الأساس) تكتب مفتاحها الخاص وتمسحه عند اختيار "الكل" (لا تكتب السلسلة الحرفية `"all"`) → فلتر نصي إضافي (`textFilters`) مستقل عن مربع البحث الرئيسي → نطاق تاريخ إضافي (`extraDateRange`) مستقل عن `date_from`/`date_to` الرئيسيين → قائمة المتجر تمسح `store_id` عند اختيار "كل المتاجر" → `PeriodPicker`: تغيير السنة لا يكتب معامل `page` (هذه التقارير لا تُرقِّم صفحات) → إظهار/إخفاء الشهر → اختيار الشهر مستقل عن السنة → سلوك قائمة المتجر مطابق لِ`ReportFilterBar`.

---

## 5) الحزمة الكاملة (Vitest + TypeScript + ESLint + الأنواع الرقمية)

```
Test Files  32 passed (32)
     Tests  406 passed (406)
```

- **TypeScript (`tsc --noEmit`):** صفر خطأ. (خطآن ظهرا أثناء الكتابة في `tests/reports-export-route-integration.test.ts` بسبب توقيع `ExcelJS.Workbook.xlsx.load()` الصارم مع نوع `Buffer` في هذا الإصدار من Node — صُحِّحا بنفس القالب `as unknown as ArrayBuffer` المستخدَم فعليًا في `reports-export-generation.test.ts` القائم.)
- **ESLint:** صفر خطأ. 4 تحذيرات قائمة مسبقًا (متغيرات غير مستخدمة في ملف اختبار من جلسة سابقة، غير متعلقة بهذا الباتش).
- **فحص أنواع الأعمدة الرقمية (`check:numeric-types`):** `OK: all 89 raw NUMERIC column(s) in the public schema are correctly typed as number in database.ts`.

---

## 6) خلاصة نتائج الاختبار

**42/42 ملف اختبار SQL PASS (الحزمة الكاملة من Phase 2 حتى Patch 8.1، بلا استثناء واحد، بما فيها 5 اختبارات تزامن حقيقي عبر `dblink` و11 سكربت أمان ترقية) + 341/341 تأكيد HTTP/PostgREST حقيقي PASS (18 جديدة عبر "Part 19"، زائد إصلاح تأكيد قديم فات عليه تحديث ترحيلة 0205) + 406/406 Vitest PASS عبر 32 ملفًا (20 جديدة عبر ملفَّي تكامل التصدير ومكوِّنات الفلترة) + TypeScript/ESLint/فحص الأنواع الرقمية نظيفة بالكامل — كل رقم من تشغيل فعلي في هذه الجلسة تحديدًا. صفر انحدار على أي اختبار قائم من أي Phase سابق. صفر تخفيف أو حذف لأي اختبار.**
