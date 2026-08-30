# TEST_RESULTS_PHASE_8_REPORTS_DASHBOARD.md

## Phase 8 — التقارير ولوحة التحكم والتصدير (Reports, Dashboard & Exports)

هذا الملف يوثِّق نتائج الاختبار الفعلية الكاملة لِـPhase 8 — منفَّذة داخل هذه الجلسة على قواعد بيانات حقيقية (PostgreSQL 16.13)، وخادم PostgREST حقيقي (v12.2.3)، وتشغيل Vitest حقيقي — بأرقام حقيقية من تشغيل فعلي مباشر، أُعيد تنفيذه نظيفًا بالكامل في نهاية هذه الجلسة تحديدًا (لا نتائج منسوخة من جولات تطوير سابقة).

---

## 0) نطاق Phase 8 والالتزام بالتجميد (§0)

- **الترحيلات الجديدة:** `0199`–`0204` (6 ترحيلات) — أساس التقارير/الأدوات المساعدة/البحث (0199)، ملخص لوحة التحكم + الاتجاهات + المقارنات (0200)، تقارير المبيعات/الأصناف/الفئات/العيارات/الموظفين (0201)، تقارير طرق الدفع/قنوات التحصيل/المرتجعات (0202)، تقارير الشحن/الدفع عند الاستلام/التعديلات (0203)، تقارير التسويات + التقارير الإدارية اليومية/الأسبوعية/الشهرية/السنوية (0204).
- **التجميد 0001–0198:** **بايت-لباَيت مطابقة تمامًا** لآخر تسليم مُعتمَد (`gold-erp-hotfix-7-1-3-settlements.zip`) — تحقُّق مباشر عبر `diff`/`sha256sum` لكل ملف من الـ198، صفر اختلاف واحد (تفاصيل §1 أدناه). **لم تُعدَّل أي ترحيلة من 0001–0198 إطلاقًا** في هذا الـPhase.
- **الإضافة بحتة (Additive-Only):** فحص `grep` مباشر عبر 0199–0204 كاملة يؤكِّد **صفر** حالة `ALTER TABLE`/`DROP TABLE`/`DROP COLUMN`/`ADD COLUMN`/`CREATE TABLE` — كل الترحيلات الست تقتصر على `CREATE OR REPLACE FUNCTION`/`COMMENT ON FUNCTION`/`REVOKE`/`GRANT EXECUTE` فقط، ما يجعل مخاطر الترقية الإنتاجية شبه معدومة (لا بيانات مُعرَّضة للفقد أو التلف بنيويًا).
- **المحظورات المُلتزَم بها:** لا Inventory، لا Salla API، لا Carrier API، لا Bank API، لا GL، لا Attachments، لا Backups، لا 2FA، **ولا أي بداية لـPhase 9** — هذا الملف نفسه هو التسليم الأخير قبل التوقف والانتظار.

---

## 1) تحقُّق التجميد بايت-لباَيت — 198/198 ترحيلة مطابقة تمامًا

```
$ for i in 0001..0198: diff -q <local> <hotfix-7.1.3-zip> ; sha256sum spot-check (0001/0100/0198)
DONE, FAIL=0

6df2572517b9109799c0d6b861cf8f105805b9b02d5121f2f15a2f039a39c10a  0001_extensions_and_helpers.sql        (محلي = ZIP)
dab41fd2ad5f275cdafdd48eaa7ca8757b386763a0972d73db7fea02fa2dd975  0100_create_and_preview_sales_return_patch_4_2.sql  (محلي = ZIP)
d9294ed57c54d5b3e8df7fe30ca197fcd2268dab3c95146ef6edafdfb739a833  0198_settlement_source_adapter_hotfix_7_1_2.sql     (محلي = ZIP)
```

**النتيجة: 198/198 ملف مطابق تمامًا (diff فارغ لكل ملف)، صفر انحراف عن آخر تسليم مُعتمَد.**

---

## 2) اختبارات SQL — كل ملف على قاعدة بيانات نظيفة مستقلة (29 ملف، الاتفاقية القائمة في هذا المشروع)

كل ملف يُبنى من الصفر (`local_harness_setup.sql` + جميع الترحيلات 0001–latest + `seed.sql`) على قاعدة بيانات مُهيَّأة حديثًا خاصة به — لا مشاركة حالة بين الملفات (بعض الملفات، مثل ملفات `_concurrency`، تستخدم `dblink` لمحاكاة جلستين متزامنتين حقيقيتين وتُنفِّذ `COMMIT` فعليًا، لذا مشاركة قاعدة بيانات واحدة بين الملفات كانت ستُسرِّب بيانات بين الاختبارات — التحقُّق من هذا مباشرة أدناه).

| الملف | النتيجة |
|---|---|
| `adjustments_core_phase6.test.sql` | Exit 0 |
| `adjustments_core_phase6_concurrency.test.sql` (تزامن حقيقي عبر dblink) | Exit 0 |
| `adjustments_hotfix_6_1_2.test.sql` | Exit 0 |
| `financial_integrity_hotfix_2_2_1.test.sql` | Exit 0 |
| `financial_integrity_hotfix_2_2_2.test.sql` | Exit 0 |
| `financial_integrity_patch_2_1.test.sql` | Exit 0 |
| `financial_integrity_patch_2_2.test.sql` | Exit 0 |
| `financial_master_data.test.sql` | Exit 0 |
| **`reports_dashboard_golden_scenario.test.sql`** (جديد — Phase 8) | **Exit 0 — 7/7 تأكيد PASS (A–G)** |
| **`reports_detail_golden_scenario.test.sql`** (جديد — Phase 8) | **Exit 0 — 8/8 تأكيد PASS (A–H)** |
| `rls_and_permissions.test.sql` | Exit 0 — 139 تأكيد `OK` |
| `sales_core.test.sql` | Exit 0 |
| `sales_integrity_hotfix_3_2_1.test.sql` | Exit 0 |
| `sales_integrity_patch_3_1.test.sql` | Exit 0 |
| `sales_integrity_patch_3_1_concurrency.test.sql` (تزامن حقيقي) | Exit 0 |
| `sales_integrity_patch_3_2.test.sql` | Exit 0 |
| `sales_returns_concurrency.test.sql` (تزامن حقيقي) | Exit 0 |
| `sales_returns_core.test.sql` | Exit 0 |
| `sales_returns_hotfix_4_2_1.test.sql` | Exit 0 |
| `settlements_hotfix_7_1_1.test.sql` | Exit 0 |
| `settlements_hotfix_7_1_2.test.sql` | Exit 0 |
| `settlements_hotfix_7_1_3.test.sql` | Exit 0 |
| `settlements_phase7.test.sql` | Exit 0 |
| `settlements_phase7_concurrency.test.sql` (تزامن حقيقي) | Exit 0 |
| `shipping_core_phase5.test.sql` | Exit 0 |
| `shipping_core_phase5_concurrency.test.sql` (تزامن حقيقي) | Exit 0 |
| `shipping_integrity_hotfix_5_1_1.test.sql` | Exit 0 |
| `shipping_integrity_patch_5_1.test.sql` | Exit 0 |
| **`upgrade_phase8_reports_dashboard.test.sql`** (جديد — Phase 8، يُشغَّل ضد البناء الكامل القياسي مباشرةً — انظر §3) | **Exit 0** |

**النتيجة: 29/29 ملف Exit 0، صفر سطر `ERROR:` غير متوقَّع، صفر انحدار في أي ملف من الـPhases السابقة.**

### تفصيل الاختبارين الجديدين كليًا لهذا الـPhase

**`reports_dashboard_golden_scenario.test.sql`** (يبني السيناريو المالي الذهبي عبر RPCs إنتاجية حقيقية — لا إدخال مالي خام):

```
NOTICE:  PASS A: July 2026 Golden Scenario reconciles -- Net Operating Return = 68.00
NOTICE:  PASS B: August 2026 correctly carries every reversal/cancellation undo dated by its OWN business date (§85), never July's
NOTICE:  PASS C: combined July+August nets every reversal to exactly 0.00 with no double-counting -- the untouched Sale/Shipment/Batch-A remain fully intact
NOTICE:  PASS D: get_dashboard_trends() reproduces get_dashboard_summary()'s exact figures for the same ranges (Screen total = Trend point)
NOTICE:  PASS E: sales_employee actor sees ONLY operational fields -- every profit/financial key and every unauthorized domain section is truly absent, not null
NOTICE:  PASS F: unauthorized explicit store filter correctly rejected
NOTICE:  PASS G: date_from > date_to correctly rejected
NOTICE:  === ALL reports_dashboard_golden_scenario.test.sql ASSERTIONS PASSED (§81/§82/§85/§39/§79/§8/§4) ===
ROLLBACK
```

**`reports_detail_golden_scenario.test.sql`** (يثبت اتساق الـ12 تقرير الجدولي + الـ4 تقارير إدارية مع نفس السيناريو):

```
NOTICE:  PASS A: all 7 sales-side ranking/detail reports agree on July 2026 (revenue=3500.00, net_sales_profit=555.00)
NOTICE:  PASS B: get_returns_report() movements ledger reconciles -- July -555.00, August +555.00, combined = 0.00 (no double-counting)
NOTICE:  PASS C: get_adjustments_report() movements ledger reconciles -- July +58.00, August -58.00, combined = 0.00 (no double-counting)
NOTICE:  PASS D: get_shipping_report()/get_cod_report() Current Effective figures match the Dashboard's shipping CTE exactly
NOTICE:  PASS E: get_settlements_report() dual-basis figures byte-match get_dashboard_summary() for both July and August (§39/§80)
NOTICE:  PASS F: Daily/Weekly/Monthly/Yearly Management Reports delegate correctly -- NOR daily=-555.00, weekly=10.00, monthly=68.00, yearly=565.00
NOTICE:  PASS G: §79 true key-absence confirmed for all 7 sampled report RPCs (sales/items/employees/returns/adjustments/shipping/settlements)
NOTICE:  PASS H: unauthorized store filters correctly REJECTED (never silently narrowed) across sampled report RPCs
NOTICE:  === ALL reports_detail_golden_scenario.test.sql ASSERTIONS PASSED (§21-§37/§39/§45/§63/§79/§80/§82/§83/§84/§85) ===
ROLLBACK
```

**`upgrade_phase8_reports_dashboard.test.sql`** (يثبت أن الـ21 دالة تقرير آمنة على بيانات `seed.sql` وحدها — بلا أي فِكستشر خاص بـPhase 8 — أي بلا أي افتراض ضمني على شكل بيانات لم توجد قبل هذا الـPhase):

```
NOTICE:  PASS 1-18: all 21 report RPCs (Dashboard summary+trends+16 detail reports+4 management wrappers) callable and well-formed against pre-existing seed.sql-only data (no Phase 8 fixture ever ran)
NOTICE:  PASS 19: get_dashboard_trends() bucket sum reconciles exactly with get_dashboard_summary() on seed-only data (net_operating_return = 0)
NOTICE:  === ALL upgrade_phase8_reports_dashboard.test.sql ASSERTIONS PASSED (§97/§100 -- 0199-0204 upgrade-safe on top of frozen 0001-0198) ===
ROLLBACK
```

---

## 3) اختبارات ترقية القاعدة التاريخية (Upgrade-Snapshot) — 11/11 سكربت مُخصَّص

كل سكربت من `scripts/run_upgrade_test*.sh` القائمة (مملوكة لـPhases سابقة، خارج نطاق تعديل هذا الـPhase) أُعيد تشغيله بقاعدة بيانات مستقلة خاصة به، للتأكُّد أن ثبات 0001–0198 بايت-لباَيت (§1) لم يُصاحبه أي انحدار سلوكي فعلي في مسارات الترقية التاريخية:

| السكربت | النتيجة |
|---|---|
| `run_upgrade_test.sh` (Foundation 0001–0039 → latest) | Exit 0 |
| `run_upgrade_test_hotfix_4_2_1.sh` | Exit 0 |
| `run_upgrade_test_patch_4_2.sh` | Exit 0 |
| `run_upgrade_test_patch_6_1.sh` | Exit 0 |
| `run_upgrade_test_phase6_adjustments.sh` | Exit 0 |
| `run_upgrade_test_phase7_settlements.sh` | Exit 0 |
| `run_upgrade_test_phase7_1_settlements.sh` | Exit 0 |
| `run_upgrade_test_hotfix_7_1_1_settlements.sh` | Exit 0 |
| `run_upgrade_test_hotfix_7_1_2_settlements.sh` | Exit 0 |
| `run_upgrade_test_hotfix_7_1_3_settlements.sh` | Exit 0 |
| `run_upgrade_test_hotfix_7_1_3_broken_fixture.sh` (مسار فشل مقصود — Exit 0 يعني أن 0197 رفضت الترحيلة الفاسدة كما هو متوقَّع تمامًا) | Exit 0 |

**النتيجة: 11/11 Exit 0، صفر انحدار في أي مسار ترقية تاريخي.**

---

## 4) اختبار HTTP/PostgREST الحقيقي — Part 18 جديد كليًا لهذا الـPhase

`scripts/run_postgrest_http_test.sh` يبني قاعدة بيانات جديدة، يُشغِّل ثنائي PostgREST v12.2.3 الحقيقي، يوقِّع JWTs حقيقية، وينفِّذ `scripts/postgrest-http-test.mjs` كاملًا (الأجزاء 1–18) عبر HTTP فعلي — وليس محاكاة:

```
=== ALL REAL HTTP/POSTGREST INTEGRATION TEST ASSERTIONS PASSED ===
```

**322 سطر `OK:` إجمالًا عبر الأجزاء 1–18، منها 23 تأكيدًا جديدًا في Part 18 (Phase 8 تحديدًا):**

- **Part 18 item A (§40/§41/§83):** `get_dashboard_summary()` عبر HTTP حقيقي — مؤشِّر الأساس صحيح، وحقول المال (`sales_revenue`, `gross_profit`, `net_operating_return`) تصل بنوع `string` حرفيًا.
- **Part 18 items B/C (§79 حرِج):** `get_sales_report()` — حقل `gross_profit` **موجود فعليًا** في الملخَّص والصفوف لممثِّل يملك `sales.view_profit`، و**غائب تمامًا** (ليس `null`) للممثِّل الذي لا يملكها — مُثبَت عبر عامل `in` على الكائن الفعلي القادم من HTTP.
- **Part 18 item D (§49):** `report_visible_stores_lookup()` يعمل لممثِّل يملك `reports.view` فقط، بلا `stores.view` إطلاقًا.
- **Part 18 item E (§79 حرِج):** غياب مفتاح `net_operating_return` بالكامل من مستوى الجذر، وغياب `gross_profit` من قسم `sales`، لممثِّل بلا `dashboard.view_financials`.
- **Part 18 item F (§79):** إثبات أن حجب المفاتيح لكل نطاق مستقل عن الآخر — ممثِّل يملك `dashboard.view_financials` + `adjustments.view` + `settlements.view_financials` لكنه بلا `sales.view`/`returns.view`/`shipments.view` إطلاقًا: أقسام `sales`/`returns`/`shipping`/`net_operating_return` غائبة بالكامل، بينما `adjustments`/`settlements` حاضران **مع** حقولهما المالية.
- **Part 18 item G (§8/§9 حرِج):** رفض صريح (استثناء حقيقي عبر HTTP) لفلتر متجر خارج نطاق ممثِّل محدود بمتجر واحد — وليس تضييقًا صامتًا.

---

## 5) طبقة التطبيق (Vitest / TypeScript / ESLint / Next Build / فحص الأنواع الرقمية)

```
$ npx vitest run
 Test Files  28 passed (28)
      Tests  316 passed (316)

$ npx tsc --noEmit
(بلا مخرجات — صفر خطأ)

$ npx eslint .
✖ 4 problems (0 errors, 4 warnings)   -- تحذيرات موجودة مسبقًا في ملف غير متعلق بـPhase 8 (متغيرات غير مستخدَمة في اختبار Adjustments سابق)

$ npx next build
✓ Compiled successfully — جميع مسارات /reports/* (16) + /dashboard + /api/reports/export مبنية بنجاح كمسارات ديناميكية (server-rendered on demand)

$ DATABASE_URL=... npm run check:numeric-types
OK: all 89 raw NUMERIC column(s) in the public schema are correctly typed as number in database.ts (matching real PostgREST behavior).
```

### ملفات Vitest الجديدة كليًا لهذا الـPhase (51 اختبارًا جديدًا، 265 → 316)

| الملف | عدد الاختبارات | الغرض |
|---|---|---|
| `tests/reports-export-generation.test.ts` | 9 | توليد PDF/Excel حقيقي + قراءة عكسية حقيقية (ExcelJS) — دقة عشرية §40/§41، غياب مفاتيح §79، انحدار خطأ الترقيم التلقائي (`stampFooters`) المُكتشَف والمُصلَح في هذا الـPhase. |
| `tests/reports-dashboard-components.test.tsx` | 35 | اختبارات عرض المكوِّنات المشتركة (`ReportBasisBadge`, `ReportSummaryCards`, `ReportTable`, `KpiSection`, `NetOperatingReturnCard`, `ReportExportButtons`, `buildReportHref`) — §79/§83/§44. |
| `tests/reports-dashboard-money-string-invariant.test.ts` | 7 | امتداد حارس "no-JS-float" (على غرار `settlements-money-string-invariant.test.ts`) إلى `src/features/reports`/`src/features/dashboard` — بشكل مختلف عن حارس الكتابة في Settlements، لأن هذه الطبقة قراءة فقط: يضمن أن `queries.ts` يُمرِّر حمولة الـRPC **حرفيًا** بلا أي تحويل، ثابتًا ووقت التشغيل معًا. |

كل الاختبارات القائمة من الـPhases السابقة (265 اختبارًا عبر 25 ملفًا) اجتازت بلا أي تعديل عليها وبلا أي انحدار.

---

## 6) الخلاصة

| البند | النتيجة |
|---|---|
| تجميد 0001–0198 | 198/198 بايت-لباَيت مطابق |
| إضافة-فقط 0199–0204 | مؤكَّد (صفر ALTER/DROP/ADD COLUMN/CREATE TABLE) |
| اختبارات SQL (ملف مستقل لكل واحد) | 29/29 Exit 0 |
| اختبارات ترقية القاعدة التاريخية | 11/11 Exit 0 |
| HTTP/PostgREST حقيقي (Parts 1–18) | 322/322 تأكيد `OK`، Exit 0 |
| Vitest | 316/316 |
| TypeScript | 0 خطأ |
| ESLint | 0 خطأ (4 تحذيرات قائمة مسبقًا، غير متعلقة) |
| Next Build (إنتاجي) | ناجح |
| فحص الأنواع الرقمية | 89/89 عمود مطابق |

**صفر انحدار مكتشَف في أي جزء من النظام. Phase 8 جاهز للتسليم.**

**لا بدء لِـPhase 9 — توقف بعد هذا التسليم وانتظار المراجعة، وفق التعليمة الصريحة.**
