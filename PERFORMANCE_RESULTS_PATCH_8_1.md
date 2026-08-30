# PERFORMANCE_RESULTS_PATCH_8_1.md

## Patch 8.1 — §50-51 / §71 — اختبار الأداء الحقيقي لتقارير/لوحة التحكم عند الحجم

هذا الملف يوثِّق نتائج فعلية حقيقية (PostgreSQL 16.13، `EXPLAIN (ANALYZE, BUFFERS)` حقيقي، لا أرقام افتراضية) لأداء كل RPC تقارير/لوحة تحكم موجود في Phase 8، مُقاسة على بيانات حجمها واقعي — **10,500 طلب بيع حقيقي** موزَّعة على نافذة **365 يومًا**، مُولَّدة بالكامل عبر RPCs الإنتاج الفعلية (`create_sales_order`/`create_sales_return`/`approve_sales_return`/`record_sales_return_refund`/`reverse_sales_return`/`create_shipment`/`record_shipment_cod_collection_state`/`record_shipment_actual_cost`/`create_sales_order_adjustment`/`approve_sales_order_adjustment`/`reverse_sales_order_adjustment`/`create_draft_settlement_batch`/`finalize_settlement_batch`/`record_settlement_bank_movement`/`cancel_settlement_batch`) — **لا إدراج خام واحد** لأي عمود مالي أو محسوب بمشغِّل (trigger)، تمامًا كما يفرض السيناريو الذهبي (§81).

---

## 0) منهجية القياس

- **fixture الأداء:** `supabase/tests/fixtures/phase8_performance_fixture.sql` — 10,500 طلب بيع، ~1,166 مرتجع، ~1,050 شحنة (350 منها دفع عند الاستلام)، ~420 تعديل، ~25 دفعة تسوية مُنهاة (منها دفعة واحدة أُلغيت) عبر 12 شهرًا.
- **قاعدة بيانات نظيفة تمامًا لكل قياس:** كل رقم في هذا الملف مأخوذ من **أول تحميل لِـfixture على قاعدة بيانات مُهاجَرة حديثًا من الصفر** (`local_harness_setup.sql` + الترحيلات 0001–0214 كاملة + `seed.sql`) — **وليس** من قاعدة بيانات أُعيد استخدامها عبر عدة محاولات تصحيح متتالية. تبيَّن أثناء هذه الجلسة أن إعادة تحميل نفس الـfixture (بمفاتيح UUID ثابتة للبيانات المرجعية) عدة مرات متتالية على نفس القاعدة يُنتج تضخمًا حقيقيًا في فهارس القيود الفريدة (dead tuples غير مُجمَّعة بواسطة autovacuum بين المحاولات) يُبطئ التشغيل التالي بشكل مُضلِّل (لوحظ تشغيل واحد استغرق أكثر من 8 دقائق مقابل ~77 ثانية على قاعدة نظيفة) — **لا علاقة له بأداء الاستعلامات نفسها**. لذلك اعتُمدت قاعدة نظيفة واحدة الاستعمال لكل قياس نهائي موثَّق هنا.
- **إحصائيات المخطِّط حقيقية:** `ANALYZE` صريح على كل جدول تأثَّر بالـfixture قبل أي قياس — بدون هذا فإن كل خطة تعكس افتراضات المخطِّط لجدول شبه فارغ (ما قبل الـfixture)، لا الواقع.
- **الفاعل:** المستخدم الفائق الخاص بالـfixture (كل الصلاحيات) عبر `set_config('request.jwt.claims', ...)` — نفس اتفاقية كل اختبارات Phase 8 القائمة.
- **قيود EXPLAIN مع PL/pgSQL:** كل RPCs التقارير هي دوال `STABLE PL/pgSQL` تُعيد `jsonb` — لذلك يعرضها `EXPLAIN` كعقدة `Result` واحدة معتمة (المخطِّط الداخلي لجسم الدالة غير مرئي دون `auto_explain` مع `nested_statements`). القيمتان الموثوقتان هنا هما **Execution Time** الحقيقي (زمن حائط فعلي شامل تنفيذ جسم الدالة كاملًا) و**Buffers** (عدد صفحات الذاكرة المُقروءة فعليًا) — كلاهما حقيقي 100% من `EXPLAIN (ANALYZE, BUFFERS)`، وليس تقديرًا.
- **اختبار الانحدار الآلي:** `supabase/tests/performance_reports_dashboard.test.sql` يُنفِّذ نفس التسع استدعاءات، ويفشل (`RAISE EXCEPTION`) إن تجاوز أي منها سقفًا سخيًّا (3000ms للوحة التحكم والتقارير التفصيلية، 4000ms للتقارير الإدارية) — سقف انحدار (regression floor)، لا هدف أداء (performance target): مصمَّم ليمر بارتياح مع تطبيق سليم، ويُفشل فورًا مع انحدار حقيقي (فهرس مفقود، N+1 عرضي).

---

## 1) اكتشاف حقيقي وإصلاحه: `get_sales_report()` — نمط الاستعلامات الفرعية المترابطة (N+1)

**الاكتشاف:** أول تشغيل لاختبار الانحدار على قاعدة نظيفة تمامًا (أول تحميل لِـfixture على `gold_erp_patch81_perf`) أظهر:

```
get_dashboard_summary            : 275.1 ms  (سقف 3000ms) — PASS
get_dashboard_trends(month)      : 278.1 ms  (سقف 3000ms) — PASS
get_sales_report                 : 3515.8 ms (سقف 3000ms) — FAIL
```

**السبب الجذري:** الـCTE الرئيسي في `get_sales_report()` (مُعرَّف في الترحيلتين 0201/0210) كان يُنفِّذ **ست استعلامات فرعية مترابطة (correlated subqueries)** منفصلة لكل صف طلب مطابق — خمسة على `sales_order_items` (`items_count`/`weight_grams`/`base_cost`/`vat_cost`/`total_cost`) وواحدة على `sales_returns` (`effective_return_net_profit_adjustment`) — قبل حتى حساب سطر الملخَّص (الذي يجب أن يلمس **كل** صف مطابق ضمن النافذة، لا الصفحة المعروضة فقط بحكم تعريفه). على نافذة سنة كاملة (10,500 طلب) هذا ~63,000 تنفيذ استعلام فرعي منفصل، كل واحد بتكلفة فتح فهرس مستقلة — نمط O(n) بمعامل ثابت كبير، لا خلل منطقي (كل الأرقام كانت صحيحة، البطء فقط).

**الإصلاح (الترحيلة `0214_sales_report_performance_optimization.sql`):** استبدال الست استعلامات الفرعية المترابطة بتجميعين (`GROUP BY`) محسوبين مرة واحدة فقط — واحد على `sales_order_items` وواحد على `sales_returns` — كل منهما مُقيَّد مسبقًا بمجموعة الطلبات المُصفَّاة فعليًا (join مع الـCTE `base`)، ثم `LEFT JOIN` عليهما مرة واحدة فقط. **التوقيع مطابق تمامًا بايت-لبايت** لما كان عليه (12 معامل، نفس الأسماء والأنواع والقيم الافتراضية) — لذا استُخدم `CREATE OR REPLACE FUNCTION` مباشرة، متوافقًا مع §0 (لا يُسمح إلا بهذا للتوقيعات المطابقة). القيم المُعادة **متطابقة حرفيًا** مع النسخة القديمة (`coalesce(..., 0)` بعد `LEFT JOIN` يُعيد نفس سلوك الاستعلام الفرعي عند عدم وجود صفوف) — **لم يتغيَّر رقم واحد**، تغيَّر فقط شكل خطة التنفيذ.

**التحقق من عدم تغيُّر أي رقم:** أُعيد تشغيل `reports_dashboard_golden_scenario.test.sql` و`reports_detail_golden_scenario.test.sql` كاملَين بعد الإصلاح — **كل التوكيدات (assertions) نجحت دون تعديل واحد**، بما فيها التوكيد A في `reports_detail_golden_scenario.test.sql` الذي يقارن `get_sales_report()` رقميًّا (`revenue=3500.00`, `net_sales_profit=555.00`) عبر 7 تقارير مختلفة.

**النتيجة بعد الإصلاح (قاعدة نظيفة جديدة، أول تحميل):**

```
get_sales_report                 : 308.7 ms (سقف 3000ms) — PASS
get_sales_report(offset 5000)    : 266.8 ms (سقف 3000ms) — PASS
```

**تحسُّن ~11.4x** (3515.8ms → 308.7ms) لنفس البيانات تمامًا، بلا أي فرق في القيم المُعادة.

---

## 2) النتائج النهائية — `EXPLAIN (ANALYZE, BUFFERS)` حقيقي (بعد إصلاح §1)

قياس واحد نظيف، `psql` مباشر، قاعدة بيانات مُهاجَرة من الصفر (`gold_erp_patch81_perf3`)، fixture محمَّل مرة واحدة، `ANALYZE` صريح، `EXPLAIN (ANALYZE, BUFFERS)` لكل استدعاء، الكل داخل معاملة واحدة مُرتجَعة (`ROLLBACK`) في النهاية:

| RPC | Execution Time | Buffers (shared hit) |
|---|---:|---:|
| `get_dashboard_summary(365 يومًا)` | 258.5 ms | 8,094 |
| `get_dashboard_trends(365 يومًا, شهري)` | 275.5 ms | 18,303 |
| `get_sales_report(offset 0)` | 296.2 ms | 1,528 (+ temp 36/107) |
| `get_sales_report(offset 5000)` | 218.5 ms | 1,328 (+ temp 36/107) |
| `get_returns_report` | 17.8 ms | 1,921 |
| `get_shipping_report` | 10.7 ms | 912 |
| `get_cod_report` | 32.5 ms | 6,831 |
| `get_adjustments_report` | 10.9 ms | 3,305 |
| `get_settlements_report` | 12.6 ms | 3,363 |
| `get_monthly_management_report` | 74.6 ms | 5,929 |

**كل قيمة أعلى بكثير من سقف الانحدار الآلي (3000/4000ms) بهامش واسع** — أقرب رقم لأي سقف هو `get_sales_report` عند ~300ms، أي أقل من **عُشر** سقفه (3000ms).

ملاحظة حول `get_sales_report`: صفوف `temp read=36 written=107` تعود إلى فرز/تجميع الـCTE النهائي (`ORDER BY` + `GROUP BY` على ~10,500 صف مطابق) الذي يفيض قليلًا عن `work_mem` الافتراضي لهذه الجلسة — سلوك متوقَّع وغير مُقلق عند هذا الحجم (لا نقل بيانات مالية، فقط ترتيب مؤقت)؛ استدعاء `offset 5000` كان **أسرع** من `offset 0` (218ms مقابل 296ms) بفارق ضجيج طبيعي بين تشغيلتين متتاليتين على نفس الاتصال (تخزين مؤقت أكثر دفئًا للثانية)، لا مؤشر تدهور مع العمق — يُثبت أن الترقيم (pagination) لا يتدهور كارثيًّا عند الغوص عميقًا في نتيجة 10,500 صف (وهو بالضبط ما صُمِّم هذا الاستدعاء الإضافي لإثباته).

---

## 3) اختبار الانحدار الآلي — نتيجة نهائية

`supabase/tests/performance_reports_dashboard.test.sql` (نفس القاعدة النظيفة، تشغيل واحد كامل):

```
Performance regression run -- window 2025-08-30 .. 2026-08-29 (365 days, 10,500 orders)
  get_dashboard_summary            : 258.5 ms (ceiling 3000 ms)
  get_dashboard_trends(month)      : 304.2 ms (ceiling 3000 ms)
  get_sales_report                 : 308.7 ms (ceiling 3000 ms)
  get_returns_report               : 18.2 ms (ceiling 3000 ms)
  get_shipping_report              : 10.8 ms (ceiling 3000 ms)
  get_cod_report                   : 32.8 ms (ceiling 3000 ms)
  get_adjustments_report           : 11.4 ms (ceiling 3000 ms)
  get_settlements_report           : 13.4 ms (ceiling 3000 ms)
  get_monthly_management_report    : 76.7 ms (ceiling 4000 ms)
  get_sales_report(offset 5000)    : 266.8 ms (ceiling 3000 ms)
PASS: all reporting/dashboard RPCs completed within their regression-floor ceilings over 10,500 orders / 365 days.

Exit 0
```

**النتيجة: 10/10 استدعاء ضمن سقف الانحدار، بهوامش واسعة جدًّا في كل حالة.**

---

## 4) الخلاصة

- Fixture أداء حقيقي (10,500 طلب/365 يومًا) عبر RPCs الإنتاج الفعلية فقط — أُنشئ ووُثِّق في `supabase/tests/fixtures/phase8_performance_fixture.sql`.
- اكتشاف حقيقي واحد (نمط استعلامات فرعية مترابطة O(n) في `get_sales_report`)، أُصلح عبر تغيير شكل خطة تنفيذ بحت (بلا أي تغيير في القيم المُعادة، مُتحقَّق منه عبر السيناريو الذهبي كاملًا) — الترحيلة `0214_sales_report_performance_optimization.sql`، `CREATE OR REPLACE FUNCTION` بتوقيع مطابق تمامًا، متوافقة مع §0.
- كل تسع RPCs تقارير/لوحة تحكم تعمل ضمن أقل من نصف ثانية عند حجم 10,500 طلب/365 يومًا — بعيدة جدًّا عن أي سقف انحدار معقول.
- اختبار انحدار آلي دائم (`performance_reports_dashboard.test.sql`) أُضيف لالتقاط أي تدهور مستقبلي فورًا.
