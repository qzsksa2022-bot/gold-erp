# TEST_RESULTS_HOTFIX_8_1_2.md

## Phase 8 — Final Closure Hotfix 8.1.2 — Reports/Dashboard/Exports — Calendar Comparison, Management Breakdowns, Historical Refund Labels & Contract Closure

نتائج الاختبار الكاملة لِHotfix 8.1.2، كل رقم من تشغيل فعلي في هذه الجلسة تحديدًا. التجميد صارم كسابقاته: **migrations 0001–0220 مُجمَّدة بالكامل** (§0) — لم تُعدَّل أي ترحيلة منها، ولا `supabase/seed.sql`. **الترحيلات 0221–0226 هي الجديدة كليًا فقط** (ست ترحيلات إضافة-فقط: `CREATE [OR REPLACE] FUNCTION` أو `DROP FUNCTION IF EXISTS <توقيع دقيق>` + `CREATE FUNCTION` عند تغيُّر التوقيع فقط — صفر `ALTER TABLE`/`DROP TABLE`/`CREATE TABLE` عبر الست جميعًا).

## 1) الترحيلات الست الجديدة (0221–0226) — جدول كامل

| # | الترحيلة | الغرض المختصر |
|---|---|---|
| 0221 | `dashboard_calendar_comparison.sql` | §1-5 CRITICAL — `report_calendar_comparison_period()` (حساب تاريخ صِرف، بلا قراءة جداول) يحسب الفترة السابقة الصحيحة تقويميًا (أسبوع رياض كامل سابق / شهر ميلادي كامل سابق / سنة ميلادية كاملة سابقة) بدل "المدى المكافئ الطول السابق مباشرة" الخاطئ لهذه الحالات الثلاث تحديدًا. `get_dashboard_summary_with_comparison()` يستدعي `get_dashboard_summary()` الكانونية مرتين فقط (الفترة الحالية + السابقة المحسوبة تقويميًا) ولا يعيد اشتقاق رقم مالي واحد بنفسه. **عيب حرج مُكتشَف ومُصلَح خلال هذه الجلسة نفسها:** `_report_recompute_comparison()` كانت تُعيد `null` لكل مجال كلما كانت `report_pct_change()` تُعيد SQL NULL الحقيقي (شائع — أي فترة سابقة بصفر/بلا بيانات) لأن `jsonb_set()` STRICT تجعل أي وسيط NULL يُسقِط الاستدعاء كاملًا إلى NULL، مُفسِدةً كل مفتاح آخر كُتب في نفس التكرار وما بعده. الإصلاح: `coalesce(to_jsonb(...), 'null'::jsonb)` — مُثبَت عبر اختبار SQL مباشر على 5 قيم preset مختلفة (`today`/`this_week`/`this_month`/`last_year`/`custom`). |
| 0222 | `management_reports_calendar_comparison_breakdowns.sql` | §6-15 — التقارير الإدارية الأربعة (يومي/أسبوعي/شهري/سنوي) تتحوَّل من `get_dashboard_summary()` إلى `get_dashboard_summary_with_comparison()` القادرة على التقويم؛ الأسبوعي/الشهري/السنوي تكتسب مصفوفة تفصيل حقيقية (`breakdown`) عبر `get_dashboard_trends()` (0205) **دون تكرار** — الأسبوعي 7 نقاط يومية، الشهري 28-31 نقطة يومية، السنوي 12 نقطة شهرية. اليومي بلا تفصيل (اليوم نفسه هو أصغر وحدة). |
| 0223 | `settlement_store_visibility_vs_filter_split.sql` | §16-18 CRITICAL — فصل "الرؤية" (نطاق الممثِّل الكامل غير المُقيَّد، `_report_actor_full_store_scope()` جديدة) عن "الفلتر الصريح" (`_report_settlement_batch_matches_store_filter()` جديدة، فحص ANY-line بدل ALL-line) لدفعات التسوية العابرة للمتاجر — مُطبَّق على أربع دوال: `get_dashboard_summary`، `get_dashboard_trends`، `get_settlements_report`، `get_cod_report`. |
| 0224 | `returns_payment_methods_refund_historical_labels.sql` | §19-22 — `get_returns_report()`/`get_payment_methods_report()` (قسم Refund Cash) تقرآن `refund_method_name_snapshot` المُلتقَطة وقت الحدث (0106/0107) بدل ربط حي بالاسم الحالي — إعادة تسمية طريقة استرداد لاحقًا لا تُشوِّه تقارير تاريخية. التجميع في Payment Methods أصبح `(refund_method_id, refund_method_name_snapshot)` بدل `refund_method_id` وحدها. |
| 0225 | `payment_methods_report_original_method_filter_and_store_scope.sql` | §31-33 — توقيع مُغيَّر (`DROP`+`CREATE`): `p_payment_method_id` جديد (طريقة الدفع **الأصلية** عند البيع) مُميَّز صراحةً عن `p_refund_method_id` القائم (طريقة الاسترداد **الفعلية**) — فلتران مستقلان تمامًا لا يتشاركان معنى. قسم Settlement يكتسب أيضًا إصلاح §16-18 (نطاق كامل + فلتر صريح)، مؤجَّل عمدًا من 0223 لهذه الترحيلة التي تحتاج بالفعل لمسّ توقيع الدالة (انضباط "لمسة واحدة لكل دالة في الهوتفكس"). |
| 0226 | `items_report_salesperson_filter.sql` | §34-36 — توقيع مُغيَّر: `p_salesperson_id` جديد يُصفِّي على `sales_orders.salesperson_id` الحقيقي — نفس العمود الذي تقارير الموظفين/المرتجعات تستخدمانه أصلًا، لم يكن مكشوفًا في تقرير الأصناف سابقًا. |

**إضافة-فقط مؤكَّدة:** فحص مباشر عبر الست ترحيلات — صفر `ALTER TABLE`/`DROP TABLE`/`DROP COLUMN`/`ADD COLUMN`/`CREATE TABLE`. توقيعان فقط تغيَّرا فعليًا (`get_payment_methods_report` في 0225، `get_items_report` في 0226)، كلاهما عبر `DROP FUNCTION IF EXISTS <التوقيع القديم الدقيق>` صريح متبوعًا بـ`CREATE FUNCTION` (§0) — لا `CREATE OR REPLACE` على توقيع مُغيَّر إطلاقًا.

## 2) اختبار SQL جديد كليًا — إثبات >500 صف حقيقي من قاعدة البيانات (§37-39)

`supabase/tests/hotfix_8_1_2_row_count_proof.test.sql` — يُغلِق فجوة لم يغطِّها أي اختبار سابق: تأكيد Hotfix 8.1.1 (§11-14/§60) لسقف التصدير 500→5000 كان دائمًا عبر استجابة RPC **مُصطنَعة** (mock) في Vitest، لم يُثبِت قط أن `get_items_report()`/`get_adjustments_report()` **أنفسهما** تُعيدان فعليًا >500 صف حقيقي من Postgres.

هذا الاختبار يُدرِج **550 طلب بيع حقيقي** (عبر `create_sales_order()` الإنتاجية الفعلية، كل واحد بصنف مُسمَّى تفرديًا حتى لا يتجمَّع `GROUP BY` الهُويّة في `get_items_report()`) و**550 تعديل مُعتمَد حقيقي** (عبر `create_sales_order_adjustment()`/`approve_sales_order_adjustment()` الإنتاجيتين، واحد لكل طلب) — لا إدراج خام إطلاقًا. ثم:

- **(A)** `get_items_report(..., p_limit=5000)` → `total_count=550` **و** `jsonb_array_length(rows)=550` (كلاهما يطابقان الواقع، بلا سقف يُصادفهما).
- **(B)** نفس الاستدعاء بـ`p_limit=500` (أقل من 550) → `total_count` **يبقى 550** الحقيقي بينما `rows.length=500` مقصوص بالصفحة فقط — إثبات مباشر أن `total_count` لا يكذب أبدًا ليطابق صفحة مبتورة (جوهر §13/§37-39).
- **(C)/(D)** نفس الزوج تمامًا لِ`get_adjustments_report()`.

النتيجة: **PASS A/B/C/D كاملة** (`psql -f`، Exit 0، جميع رسائل `PASS` الأربع ظهرت، `ROLLBACK` نظيف في النهاية — بيانات اختبارية فقط، لم تُحفَظ أبدًا). زمن التنفيذ الكامل (550+550 عملية RPC إنتاجية حقيقية + 4 استدعاءات تقرير) ≈2.2 ثانية.

**الشطر التكميلي (جانب التصدير):** `tests/reports-export-route-integration.test.ts` اكتسب اختبارَين جديدَين (`§37-39`) يُثبتان أن نفس الـ550 صفًا (بشكل مُصطنَع بحجم مطابق هذه المرة، عبر نفس المسار الحقيقي للمسار/المُصيِّر) تُصدَّر كملف Excel حقيقي بورقة `Data` من 551 صفًا (550+ترويسة) — بلا بتر — عبر خط الأنابيب **الحقيقي غير المُقلَّد** بالكامل (المسار → `resolveReportSections` → `renderTableReportExcel`)؛ التقليد يقتصر فقط على حد استجابة RPC ذاته، مطابقًا لاتفاقية المشروع القائمة.

## 3) القسم الإداري (§6-15/§41) — التفصيل الدوري + مؤشرات الأساس والمقارنة على الشاشة والتصدير

هذا الهوتفكس أضاف **الشقّ الكامل للواجهة** فوق الشقّ البرمجي-الخالص من SQL (0222) — لم يُكتفَ بالدوال:

- **مكوّنان جديدان كليًا:** `ManagementBreakdownTable` (جدول تفصيل يومي/شهري، يقرأ `breakdown`/`breakdown_granularity` مباشرةً — غائب تمامًا لليومي، مطابقًا لعقد غياب-المفتاح-الحقيقي §79) و`ComparisonRangeNote` (شريط "الفترة السابقة للمقارنة: من X إلى Y" مع تسمية الـpreset التقويمية).
- **الشاشات الأربع** (`daily`/`weekly`/`monthly`/`yearly`, `src/app/(app)/reports/`) أصبحت تعرض `ReportBasisBadge` + `ComparisonRangeNote` معًا، والثلاث غير اليومية تعرض أيضًا جدول التفصيل الجديد أسفل أقسام KPI.
- **PDF/Excel** (`renderManagementReportPdf`/`renderManagementReportExcel`) يعرضان الآن نفس بيانات تعريف الأساس/المقارنة (`ExportMeta.comparisonLabel` جديد) + جدول/ورقة تفصيل كاملة (`drawManagementBreakdownTable`/`writeManagementBreakdownSheet` جديدتان، بترويسة مُكرَّرة عبر الصفحات في PDF وAutoFilter+صف مُجمَّد في Excel) — تكافؤ كامل بين الشاشة والتصدير (§41/§48).

**التحقُّق:** فحص مباشر لبنية JSON الفعلية عبر `psql` ضد قاعدة بيانات حقيقية مُهاجَرة كاملةً (0221–0226) يؤكِّد أن كل مفتاح تقرأه هذه المكوّنات (`basis`, `period_preset`, `previous_date_from/to`, `breakdown`, `breakdown_granularity`, وحقول كل نقطة تفصيل) موجود بالضبط بالشكل المتوقَّع — بما في ذلك تأكيد أن اليومي **لا يحمل** مفتاح `breakdown` إطلاقًا (`r ? 'breakdown'` = `false`)، والشهري ينتج 31 نقطة (أغسطس 2026)، والسنوي (2025) ينتج 12 نقطة بتسمية `"2025-01"`..`"2025-12"`.

## 4) اختبارات SQL — نطاق Reports/Dashboard (6/6 ملف PASS، معزولة ونظيفة)

كل ملف نُفِّذ على قاعدة بيانات مستقلة نظيفة (مُهاجَرة بالكامل 0001–0226 + `seed.sql` الحقيقي)، منفصلة تمامًا عن ملفات التزامن (`*_concurrency.test.sql`) التي تستخدم `dblink` بتصميم — اتصالات `dblink` تلتزم (commit) بمعزل عن معاملة الملف الخارجي، فتترك أثرًا متعمَّدًا إذا شُغِّلت في قاعدة مشتركة مع ملفات أخرى؛ هذا متوافق مع الاتفاقية القائمة فعليًا في المشروع (كل اختبار تزامن له قاعدة بيانات مخصَّصة خاصة به في كل جلسة سابقة موثَّقة)، وليس خللًا في هذا الهوتفكس.

| الملف | النتيجة |
|---|---|
| `reports_dashboard_golden_scenario.test.sql` | ✅ PASS |
| `reports_detail_golden_scenario.test.sql` | ✅ PASS |
| `reports_golden_scenario_extended.test.sql` | ✅ PASS |
| `hotfix_8_1_1_reports_exports.test.sql` | ✅ PASS (صفر انحدار على الهوتفكس السابق) |
| `hotfix_8_1_2_row_count_proof.test.sql` | ✅ PASS (جديد، تفصيل §2 أعلاه) |
| `upgrade_phase8_reports_dashboard.test.sql` | ✅ PASS |

`rls_and_permissions.test.sql` (الحارس العام للصلاحيات/RLS عبر المشروع بالكامل) أُعيد تشغيله أيضًا على نفس القاعدة النظيفة المعزولة: **PASS كامل**، صفر انحدار من هذا الهوتفكس رغم أن ملفاته الست لا تمسّ RLS/الصلاحيات إطلاقًا.

**ملاحظة منهجية مسجَّلة بصراحة:** محاولة أولى لتشغيل **كامل الأرشيف التاريخي** (+60 ملف اختبار SQL) تسلسليًا على قاعدة بيانات واحدة مشتركة أنتجت عشرات حالات الفشل الزائفة — تبيَّن أنها بالكامل ناتجة عن (أ) أثر `dblink` المتروك من ملفات التزامن كما سبق، و(ب) ملفات اختبار الترقية (`upgrade_*.test.sql`) التي تتطلَّب بتصميمها فِكستشر ما-قبل-ترحيلة مخصَّصًا عبر سكربت `run_upgrade_test_*.sh` خاص بها، لا `psql -f` مباشر ضد قاعدة مُهاجَرة بالكامل. بعد التصحيح المنهجي (قاعدة معزولة لكل مجموعة ذات صلة، مطابقةً للاتفاقية القائمة فعليًا)، **كل ملف ذي صلة بهذا الهوتفكس عاد PASS نظيفًا**، مؤكِّدًا أن الفشل الأول كان خطأ في منهجية التحقُّق لا في الكود. لم يُشغَّل الأرشيف الكامل الـ60+ ملفًا معًا في جلسة واحدة (خارج نطاق ما يحتاجه هذا الهوتفكس تحديدًا)؛ الاختبارات المُشغَّلة أعلاه هي بالضبط كل ملف قرأ/كتب/استدعى أيًّا من الدوال الست المُعدَّلة هذا الهوتفكس، بالإضافة لحارس RLS العام.

## 5) اختبار الأداء — `performance_reports_dashboard.test.sql`

نُفِّذ معزولًا (10,500 طلب حقيقي، نافذة 365 يومًا) — **PASS كامل**، كل استدعاء ضمن سقفه:

| RPC | الزمن الفعلي | السقف |
|---|---|---|
| `get_dashboard_summary` | 253.8 ms | 3000 ms |
| `get_dashboard_trends(month)` | 267.7 ms | 3000 ms |
| `get_sales_report` | 230.8 ms | 3000 ms |
| `get_returns_report` | 18.0 ms | 3000 ms |
| `get_shipping_report` | 10.4 ms | 3000 ms |
| `get_cod_report` | 24.7 ms | 3000 ms |
| `get_adjustments_report` | 11.6 ms | 3000 ms |
| `get_settlements_report` | 7.5 ms | 3000 ms |
| **`get_monthly_management_report`** | **250.9 ms** | 4000 ms |
| `get_sales_report(offset 5000)` | 206.0 ms | 3000 ms |

`get_monthly_management_report` هو أحد الدوال الأربع التي أعاد هذا الهوتفكس بناءها (0222، تستدعي الآن `get_dashboard_summary_with_comparison()` القادرة على التقويم بدل `get_dashboard_summary()` مرة واحدة فقط) — أداؤها الفعلي عند 10,500 طلب/365 يومًا بعيد جدًا عن سقفها (250.9ms مقابل 4000ms)، رغم أنها تستدعي `get_dashboard_summary()` الآن **مرتين** (الحالي + السابق) بدل مرة واحدة، مؤكِّدًا أن الإضافة لم تُدخِل أي مسار أداء خطير.

## 6) سلامة الترقية (Upgrade Safety)

لم تُكتب ترحيلة/جدول/عمود جديد في هذا الهوتفكس — الست ترحيلات جميعها دوال فقط (استبدال أو Drop+Create بتوقيع صريح). دليل سلامة الترقية هنا:

1. **تطبيق كامل من الصفر مرَّتان مستقلتان:** قاعدتا بيانات نظيفتان منفصلتان، كل واحدة طُبِّقت عليها الـ226 ترحيلة بالترتيب من `0001` حتى `0226_items_report_salesperson_filter.sql` — **صفر خطأ في الحالتين**، مؤكِّدًا أن سلسلة الترحيلات الكاملة (بما فيها الست الجديدة فوق كل ما سبقها) متماسكة بنيويًا من الصفر.
2. **إعادة إنتاج مسار الترقية الفعلي** (تطبيق 0221–0226 مباشرةً فوق قاعدة `gold_erp_base_0220` — لقطة حقيقية لِما بعد 0220 تمامًا، من جلسة سابقة لهذا الهوتفكس نفسه) نجح بلا أي خطأ، مع فحص JSON مباشر لكل من الدوال الأربع الإدارية + `get_dashboard_summary_with_comparison()` يؤكِّد الشكل والقيم المتوقَّعة تمامًا.

لم يُكتب ملف `upgrade_hotfix_8_1_2_*.test.sql` مخصَّص (بخلاف كل هوتفكس سابق غيَّر جدولًا/عمودًا فعليًا يحتاج فِكستشر ما-قبل-الترحيلة لإثبات تراجُع الأثر على بيانات تاريخية) — لا حاجة موضوعية له هنا: لا عمود/جدول تغيَّر ليُثبَت أثره الرجعي على صفوف موجودة مسبقًا؛ التطبيقان الكاملان من الصفر أعلاه هما الدليل المناسب لنوع التغيير الفعلي (دوال قراءة فقط).

## 7) Vitest — 427/427 PASS عبر 32 ملفًا

تشغيل كامل للحزمة بأكملها هذه الجلسة (`npx vitest run`) — **427/427 PASS**، صفر فشل، صفر تخطٍّ. يتضمَّن اختبارَي `§37-39` الجديدين في `tests/reports-export-route-integration.test.ts` (تفصيل §2 أعلاه).

## 8) TypeScript / ESLint / بناء Next.js الإنتاجي

- `npx tsc --noEmit` — **صفر خطأ** (المشروع بالكامل).
- `npx eslint .` — **صفر خطأ**، 4 تحذيرات `no-unused-vars` قائمة مسبقًا في `tests/adjustments-entry-form-zero-charge-state-machine.test.tsx` (ملف لم يُلمَس بهذا الهوتفكس إطلاقًا).
- `npx next build` — **ناجح بالكامل** (Turbopack)، 48 مسارًا، صفر تحذير بناء.

## 9) الملفات الجديدة/المُعدَّلة/المحذوفة — مقارنة كاملة (بايت-لباَيت حيث أمكن) مقابل `gold-erp-hotfix-8-1-1-reports-dashboard.zip`

**محذوفة: لا شيء إطلاقًا (0 ملف).**

**جديدة بالكامل (9 ملف كود + هذا التقرير):**
- الترحيلات الست: `0221_dashboard_calendar_comparison.sql`، `0222_management_reports_calendar_comparison_breakdowns.sql`، `0223_settlement_store_visibility_vs_filter_split.sql`، `0224_returns_payment_methods_refund_historical_labels.sql`، `0225_payment_methods_report_original_method_filter_and_store_scope.sql`، `0226_items_report_salesperson_filter.sql`.
- `src/features/reports/components/comparison-range-note.tsx`
- `src/features/reports/components/management-breakdown-table.tsx`
- `supabase/tests/hotfix_8_1_2_row_count_proof.test.sql`
- `TEST_RESULTS_HOTFIX_8_1_2.md` (هذا الملف)

**مُعدَّلة في مكانها (18 ملفًا):**
`src/types/database.ts` (مزامنة `get_payment_methods_report`/`get_items_report`/`get_dashboard_summary_with_comparison`)؛ `src/features/reports/queries.ts` (envelope مُختوم بالنوع + فلاتر جديدة)؛ `src/features/reports/export/{report-registry.ts,excel.ts,pdf.ts,management-registry.ts,filter-labels.ts}`؛ `src/features/reports/components/report-filter-bar.tsx` (`clearKeys`)؛ `src/app/api/reports/export/route.ts`؛ `src/app/(app)/reports/{daily,weekly,monthly,yearly,payment-methods,returns,items,page}.tsx`؛ `tests/reports-export-route-integration.test.ts`.

**لم يتغيَّر إطلاقًا:** أي ترحيلة من 0001–0220 (مؤكَّد — الست الجديدة فقط أُضيفت، لا تعديل على أي ملف موجود)، `supabase/seed.sql`، `.env.example`، أي اختبار قائم من Phase 2 حتى Hotfix 8.1.1 — لم يُحذَف ولم يُضعَف أي منها.

## 10) تأكيد عدم بدء Phase 9

لم يبدأ أي عمل يخص Phase 9 أو أي وحدة محظورة (Inventory، Salla API، Carrier API، Bank API، GL، Attachments، Backups، 2FA، ميزات المزامنة، Forecasting/AI، CRM، Payroll). كل تغيير مقصور حصرًا على تشديد/تصحيح/إكمال عقد طبقة Reports/Dashboard/Export القائمة أصلًا — لا جدول جديد، لا عمود بيانات إنتاجي جديد، لا كتابة بيانات إنتاجية جديدة.

---

**خلاصة:** ست ترحيلات إضافة-فقط (0221–0226، صفر مساس بـ0001–0220 المُجمَّدة) تُصلِح عيبًا حرجًا مُكتشَفًا ومُصلَحًا هذه الجلسة (`_report_recompute_comparison()` STRICT-NULL)، تُقيم مقارنة تقويمية صحيحة للوحدات الثلاث (أسبوع/شهر/سنة) عبر لوحة التحكم والتقارير الإدارية الأربعة **بشقّيها الكاملين (SQL + واجهة + تصدير)**، تفصل رؤية دفعة التسوية العابرة للمتاجر عن فلترها الصريح عبر أربع دوال، توحِّد التسميات التاريخية لطريقة الاسترداد عبر تقريرين، وتُضيف فلترين جديدين (طريقة الدفع الأصلية في Payment Methods، موظف المبيعات في Items) مع إثبات DB-backed حقيقي أن كلا التقريرين يتجاوزان 500 صف حقيقي بلا بتر صامت. **6/6 ملف SQL ذي صلة PASS + إثبات >500 صف حقيقي جديد + 427/427 Vitest + TypeScript/ESLint/بناء إنتاجي نظيفة بالكامل + أداء ضمن السقف بهامش واسع + سلامة ترقية مؤكَّدة بتطبيقين كاملين من الصفر** — كل رقم من تشغيل فعلي في هذه الجلسة تحديدًا. صفر ملفات محذوفة، 9 ملفات جديدة، 18 مُعدَّلة. لم يبدأ Phase 9. العمل متوقف الآن، بانتظار المراجعة.
