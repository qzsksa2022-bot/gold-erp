# نتائج اختبار Phase 6 — Services / Adjustments Core (ترحيلات 0133–0143)

هذا الملف يوثِّق كل خطوة تحقُّق نُفِّذت فعليًا في هذه الجلسة لِـPhase 6، بالأرقام الحقيقية الناتجة عن كل تشغيلة. يقابله في `DELIVERY_REPORT.md` **الملحق الخامس والعشرون**.

## 1) بناء قاعدة اختبار من الصفر بالكامل

حُذفت قاعدة `gold_erp_test` وأُعيد إنشاؤها، ثم طُبِّق `supabase/tests/local_harness_setup.sql`، ثم **كل الترحيلات 0001–0143 بالترتيب دون توقف**:

```
applied 143 migrations
```

143/143 نجحت دون أي خطأ (فقط إشعارات `NOTICE ... skipping` متوقعة من ترحيلات `IF NOT EXISTS`/`ON CONFLICT` قديمة، لا أخطاء). ثم طُبِّق `supabase/seed.sql` كاملًا على القاعدة الناتجة → **نجح**.

## 2) ملفات اختبار SQL — 17 ملفًا غير-تزامني

نُفِّذت جميعها بالتسلسل على نفس القاعدة المُعاد بناؤها (`psql -v ON_ERROR_STOP=1 -f ...`):

| # | الملف | النتيجة |
|---|---|---|
| 1 | `financial_master_data.test.sql` | PASS |
| 2 | `rls_and_permissions.test.sql` | PASS |
| 3 | `sales_core.test.sql` | PASS |
| 4 | `sales_integrity_patch_3_1.test.sql` | PASS |
| 5 | `sales_integrity_hotfix_3_2_1.test.sql` | PASS |
| 6 | `sales_integrity_patch_3_2.test.sql` | PASS |
| 7 | `financial_integrity_patch_2_1.test.sql` | PASS |
| 8 | `financial_integrity_patch_2_2.test.sql` | PASS |
| 9 | `financial_integrity_hotfix_2_2_1.test.sql` | PASS |
| 10 | `financial_integrity_hotfix_2_2_2.test.sql` | PASS |
| 11 | `sales_returns_core.test.sql` | PASS |
| 12 | `sales_returns_hotfix_4_2_1.test.sql` | PASS |
| 13 | `shipping_core_phase5.test.sql` | PASS |
| 14 | `shipping_integrity_patch_5_1.test.sql` | PASS |
| 15 | `shipping_integrity_hotfix_5_1_1.test.sql` | PASS |
| 16 | `adjustments_core_phase6.test.sql` (**جديد بالكامل، Phase 6**) | PASS |
| 17 | `upgrade_from_0039.test.sql` | PASS |

**النتيجة: 17/17 نجح، صفر انحدار على أي وحدة سابقة (Sales/Returns/Shipping/RLS/Financial Master Data)، والملف الجديد `adjustments_core_phase6.test.sql` نجح بالكامل.**

## 3) ملفات اختبار SQL — 4 ملفات تزامن حقيقي (`dblink`)

| # | الملف | النتيجة |
|---|---|---|
| 1 | `sales_integrity_patch_3_1_concurrency.test.sql` | PASS |
| 2 | `sales_returns_concurrency.test.sql` | PASS |
| 3 | `shipping_core_phase5_concurrency.test.sql` | PASS |
| 4 | `adjustments_core_phase6_concurrency.test.sql` (**جديد بالكامل، سيناريوهات A–D**) | PASS |

سيناريوهات `adjustments_core_phase6_concurrency.test.sql` الأربعة المُثبَتة فعليًا بجلستَي `dblink` حقيقيتين:
- **A** — سباق اعتماد مزدوج (`approve_sales_order_adjustment`) على نفس السجل المُعلَّق بنفس `row_version` قديم → قفل `FOR UPDATE` يحجب الجلسة الثانية حتى تلتزم الأولى، ثم تُرفَض الثانية على `row_version` أصبح قديمًا — سجل واحد فقط ينتهي به الحال "معتمَد".
- **B** — سباق عكس مزدوج (`reverse_sales_order_adjustment`) على نفس السجل المعتمَد → قفل الصف + `UNIQUE(sales_order_adjustment_id)` على `sales_order_adjustment_reversals` يضمنان سجل عكس واحدًا فقط أبدًا.
- **C** — سباق تعديل-مقابل-اعتماد: جلسة A تُبقي `update_sales_order_adjustment()` مفتوحة على سجل مُعلَّق؛ محاولة `approve_sales_order_adjustment()` من جلسة B تُحجَب فعليًا، ثم تُحل بعد التزام A على قيم A الجديدة فعلًا لا قراءة قديمة.
- **D** — سباق الإغلاق اليومي مقابل `create_sales_order_adjustment()`: القفل الاستشاري المشترك (`1006`) يُبقي المُنشِئ محجوزًا؛ `close_sales_day()` (حصري) يُحجَب فعليًا حتى التزام إنشاء التعديل.

**النتيجة: 4/4 نجح، شاملًا 4/4 سيناريوهات A–D الجديدة لِـPhase 6.**

## 4) مسارات الترقية (Upgrade Paths) — 4 سكربتات

| # | السكربت | النتيجة |
|---|---|---|
| 1 | `scripts/run_upgrade_test.sh` (Foundation 0039 → latest، بلا `seed.sql` الحالي) | PASS |
| 2 | `scripts/run_upgrade_test_patch_4_2.sh` (بيانات مرتجعات قديمة قبل Patch 4.2) | PASS |
| 3 | `scripts/run_upgrade_test_hotfix_4_2_1.sh` (بيانات استرداد قديمة قبل Hotfix 4.2.1) | PASS |
| 4 | `scripts/run_upgrade_test_phase6_adjustments.sh` (**جديد بالكامل، Phase 6**) | PASS |

مسار الترقية الجديد الرابع يبني قاعدة بمقاطع منفصلة تمامًا (0001–0132 + `seed.sql` الحقيقي، ثم 0133–latest في استدعاء `psql` منفصل تمامًا، **دون إعادة تشغيل `seed.sql` إطلاقًا**)، ويُثبِت:
- (A) صلاحيات Phase 6 الأربع الجديدة (`adjustments.manage_cost`/`reverse`/`process_closed_day`/`manage_types`) ومنحها للأدوار الثلاثة (`super_admin`=4، `admin`=4، `supervisor`=3 بلا `manage_types`) تأتي من الترحيلة 0133 نفسها لا من `seed.sql`.
- (B) إثبات وظيفي كامل: إنشاء بيانات حقيقية (متجر/عيار/تصنيف/سعر ذهب/أجرة تصنيع/عملية بيع حقيقية عبر `create_sales_order()` — بنفس الدالة التي كانت تُستخدَم قبل Phase 6 تمامًا)، ثم إنشاء نوع تعديل + إنشاء واعتماد تعديل/خدمة حقيقي (`customer_charge=100.00`/`direct_cost=30.00` ضد `visa` 2.5%/0 ثابتة) → `net_adjustment_profit='67.50'` بالضبط، واستقلالية ربح المبيعات مُثبَتة عبر `get_sales_order_adjustment_summary()`.

## 5) اختبار HTTP/PostgREST الحقيقي (ثنائي PostgREST v12.2.3 فعلي، لا محاكاة)

`ADMIN_DATABASE_URL=... bash scripts/run_postgrest_http_test.sh` — بناء قاعدة مؤقتة كاملة من الصفر + تشغيل ثنائي PostgREST حقيقي + توقيع 4 JWT حقيقية (فاعل ربح كامل، فاعل بلا ربح، `service_role` كمرجع تحقُّق، وفاعل جديد يملك `adjustments.create` فقط بلا `sales.view` إطلاقًا) + تشغيل `scripts/postgrest-http-test.mjs` كاملًا عبر HTTP فعلي.

**النتيجة: `=== ALL REAL HTTP/POSTGREST INTEGRATION TEST ASSERTIONS PASSED ===`، صفر فشل عبر الأقسام 1–11 كاملة (Decimal Transport Boundary، Sales، Returns، Shipping Core + Patch 5.1 + Hotfix 5.1.1، و"Part 11" الجديد بالكامل لِـPhase 6).**

القسم 11 الجديد (14 عنصرًا a–n) أثبت عبر HTTP فعلي:
- (a) قفل RLS من الطبقة-A: كتابة مباشرة عبر PostgREST ضد `sales_order_adjustments`/`adjustment_types` مرفوضة حتى للفاعل كامل الصلاحيات؛ قراءة مباشرة تعيد صفر صفوف بصمت (لا خطأ) — كل الوصول يمر حصرًا عبر RPCs.
- (b) §25: `search_sales_orders_for_adjustment()` تنجح لفاعل يملك `adjustments.create` فقط بلا `sales.view` إطلاقًا.
- (c) `create_adjustment_type()` تعيد `uuid` حقيقيًا.
- (d) دورة حياة كاملة: معاينة (`preview_sales_order_adjustment`) بحساب رسوم دقيق (طريقة دفع 2.75%/5.25 ثابتة → رسم=8.00/إجمالي=70.00/صافي=62.00 لِـ`customer_charge=100.00`/`direct_cost=30.00`) → إنشاء يعيد `ADJ-##########` حقيقي → قراءة تعكس `status='pending'`/`effective_status='pending'` وكل حقل مالي `typeof 'string'`.
- (e) §16: تحديث بـ`row_version` قديم مرفوض فعليًا (تزامن تفاؤلي).
- (g) الاعتماد يعيد احتساب `net_adjustment_profit=62.00` بشكل رسمي ويزيد `row_version`؛ القراءة بعد الاعتماد تعكس `effective_status='approved'` ولقطة اسم النوع **بعد** إعادة التسمية (اللقطة تُؤخَذ وقت الاعتماد لا الإنشاء).
- (h)/(m) §2: `net_sales_profit` لعملية البيع المرتبطة **بلا تغيير إطلاقًا** بعد الاعتماد وبعد العكس أيضًا — استقلالية كاملة عن محرك ربح المبيعات.
- (i) §40: `get_sales_order_adjustment_summary()` → 2000.00 (الأصل) + 100.00 (التعديل المعتمَد) = 2100.00.
- (j) `list_sales_order_adjustments()` تعكس `participates_in_settlement=true` بشكل صحيح.
- (k) §29: حماية ربح على مستوى القاعدة للفاعل بلا `sales.view_profit` — `customer_charge`/`participates_in_settlement` ظاهران، `direct_cost`/`payment_fee_amount`/`gross_adjustment_profit`/`net_adjustment_profit` كلها `null` صراحة (لا غياب، لا قيمة حقيقية) عبر كل من `get_sales_order_adjustment()` و`list_sales_order_adjustments()`.
- (l) عكس إضافي-فقط: محاولة عكس ثانية على نفس السجل مرفوضة فعليًا، ومرجع تحقُّق `service_role` يؤكد وجود سجل عكس واحد بالضبط فعليًا في `sales_order_adjustment_reversals` (`UNIQUE(sales_order_adjustment_id)`).
- (n) تدقيق دقيق الحبيبات (`adjustment.%`): أفعال تحمل رقمًا ماليًا (`create`/`update`/`approve`/`reverse`) محجوبة تمامًا عن الفاعل بلا `sales.view_profit`، بينما `adjustment_type.%` (بلا رقم مالي) تبقى ظاهرة لنفس الفاعل — تدقيق دقيق لا حجب شامل بالبادئة.

**عيبان حقيقيان اكتُشِفا وأُصلِحا أثناء تشغيل هذا الاختبار في هذه الجلسة بالذات (كلاهما في سكربت الاختبار نفسه، لا في أي ترحيلة SQL أو كود تطبيق):**
1. استدعاء `approve_sales_order_adjustment` كان يمرر `p_expected_version` من كائن لم يُستخرَج من مصفوفة `returns table` (PostgREST يُعيد صفًا واحدًا كمصفوفة من عنصر واحد) — أدى لقيمة `undefined` وخطأ `PGRST202` (لم تُوجَد الدالة بالتوقيع الناقص).
2. أربعة استدعاءات لِـ`get_sales_order_adjustment()` كانت تقرأ الحقول مباشرة من نتيجة `rpc()` الخام (مصفوفة) بدل الصف الأول — أدى لِـ`status=undefined`/`effective_status=undefined`.
كلاهما إصلاح ميكانيكي بحت في سكربت الاختبار (نمط `Array.isArray(x) ? x[0] : x` المستخدم بالفعل في كل استدعاء RPC آخر بالملف نفسه) — **لا تعديل واحد على أي كود تطبيق أو SQL**. أُعيد التشغيل الكامل بعد الإصلاح ونجح 100%.

## 6) عيب حقيقي إضافي اكتُشِف وأُصلِح: `adjustments.manage_cost` غير مُفعَّلة فعليًا

أثناء المراجعة الدقيقة لهذه الجلسة، تبيَّن أن صلاحية `adjustments.manage_cost` (مُدرَجة في الترحيلة 0133 وموثَّقة صراحة في تعليق الترحيلة نفسها بأنها "مطلوبة للاعتماد") **لم تكن مُتحقَّق منها فعليًا في أي RPC على الإطلاق** (0134–0143) — فجوة حقيقية بين التوثيق والتطبيق، تتعارض مع مطلب المواصفة "صلاحيات دقيقة الحبيبات". أُصلِحت في الترحيلة 0140 (`approve_sales_order_adjustment()`) بإضافتها كصلاحية ثانية إلزامية إلى جانب `adjustments.approve`:

```sql
if v_actor is null or not public.has_permission('adjustments.approve') or not public.has_permission('adjustments.manage_cost') then
  raise exception 'ليست لديك صلاحية اعتماد التعديلات/الخدمات (تتطلب adjustments.approve و adjustments.manage_cost معًا)' using errcode = 'P0001';
end if;
```

أُعيد تشغيل مجموعة اختبار SQL الكاملة (17 غير-تزامني + 4 تزامن + 4 ترقية) بعد هذا التعديل → **صفر انحدار** (كل ممثِّلي الاختبار الذين يملكون `adjustments.approve` يملكون بالفعل `adjustments.manage_cost` أيضًا في البذور القائمة، فلم يكسر هذا أي سيناريو موجود).

## 7) الفحوصات على مستوى الواجهة/TypeScript

| الفحص | الأمر | النتيجة |
|---|---|---|
| فحص الأنواع | `npm run typecheck` (`tsc --noEmit`) | **صفر أخطاء** |
| التدقيق (Lint) | `npm run lint` (`eslint`) | **صفر أخطاء/تحذيرات** |
| اختبارات الوحدة | `npx vitest run` | **100/100 ناجح عبر 12 ملفًا** (17 اختبارًا جديدًا لِـPhase 6: 6 اختبارات حدود صلاحيات لِـServer Actions + 11 اختبار واجهة/حجب ربح) |
| مطابقة أنواع الأعمدة العشرية | `DATABASE_URL=... npx tsx scripts/check-numeric-column-types.ts` | **OK: 68/68 عمود NUMERIC خام مطابق تمامًا لنوع `number` في `database.ts`** |
| بناء الإنتاج | `npm run build` (Next.js/Turbopack) | **نجح** — 34 مسارًا، شاملة 5 مسارات Phase 6 الجديدة: `/adjustments`، `/adjustments/[id]`، `/adjustments/[id]/edit`، `/adjustments/new`، `/master-data/adjustment-types` |

## 8) خلاصة نهائية

**صفر انحدار عبر كامل سطح الاختبار القائم** (21 ملف SQL، 4 مسارات ترقية، اختبار HTTP حقيقي بأقسامه العشرة السابقة، 83 اختبار Vitest سابق، بناء الإنتاج). **كل اختبارات Phase 6 الجديدة نجحت بالكامل** (قسم SQL جديد + 4 سيناريوهات تزامن + مسار ترقية جديد + 14 عنصر إثبات HTTP جديد + 17 اختبار Vitest جديد). **ثلاثة عيوب حقيقية اكتُشِفت وأُصلِحت أثناء هذه الجلسة بالذات** — اثنان ميكانيكيان في سكربت اختبار HTTP نفسه (§5 أعلاه)، وواحد جوهري في تطبيق صلاحية `adjustments.manage_cost` (§6 أعلاه) — قبل أي تسليم فعلي، بلا حاجة لترحيلة تصحيحية منفصلة لاحقة.
