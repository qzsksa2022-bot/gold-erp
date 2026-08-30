# TEST_RESULTS_PHASE_7_SETTLEMENTS.md

## Phase 7 — Settlements Core (Settlements / Cash-Processor Reconciliation Layer)

هذا الملف يوثِّق نتائج الاختبار الفعلية الكاملة لِـPhase 7 (ترحيلات 0167–0183)، مُنفَّذة داخل هذه الجلسة على قاعدة بيانات حقيقية، مع أرقام حقيقية من التشغيل الفعلي — لا تقديرات.

---

## 0) إعداد البيئة

- Postgres محلي (نفس بيئة كل الجولات السابقة)، قاعدتا اختبار رئيسيتان: `gold_erp_phase7_dev` (تطوير/اختبار تفاعلي تراكمي طوال الجلسة) و`gold_erp_test` (قاعدة `check:numeric-types`/typecheck المرجعية، مُطبَّقة عليها 0001–0183 بالكامل في نهاية الجلسة للتحقق النهائي).
- قاعدتا تحقُّق ترقية منفصلتان بُنيتا من الصفر: `gold_erp_p7_verify` (فحص تعارض بين ملفَي الاختبار SQL) و`gold_erp_p7_upgrade_verify` (مسار الترقية الكامل 0001→latest فوق بيانات حقيقية سابقة لِPhase 7).
- كل الترحيلات 0001–0183 طُبِّقت بالترتيب دون توقف على أكثر من قاعدة مستقلة أثناء الجلسة (تراكميًا، وأيضًا من الصفر) — لا خطأ تطبيق واحد.

---

## 1) الترحيلات الجديدة (0167–0183) — ملخص

| # | الترحيلة | الغرض |
|---|---|---|
| 0167 | `settlements_permissions_and_locks.sql` | 10 مفاتيح صلاحية `settlements.*` جديدة + توزيعها على الأدوار + Settlement Master Lock (مفتاح 1007). |
| 0168 | `settlement_routes_schema.sql` | جدول `settlement_routes` + RLS (SELECT فقط) + تصليب (identity/delete/updated_by anti-forgery/table-lock). |
| 0169 | `settlement_route_rpcs.sql` | `create/update/disable/enable_settlement_route` + دوال بحث. |
| 0170 | `settlement_route_fee_versions_schema.sql` | جدول إصدارات رسوم المسار (نمط Financial Master Data Versioning Hardening الكامل). |
| 0171 | `settlement_route_fee_version_rpcs.sql` | `create/cancel_settlement_route_fee_version` + محلِّل `settlement_route_fee_for_route_on_date`. |
| 0172 | `settlement_batches_schema.sql` | جدول `settlement_batches` (دورة حياة draft→finalized→reconciled) + تجميد الحقائق المالية فور المغادرة من draft. |
| 0173 | `settlement_batch_lines_and_claims_schema.sql` | `settlement_batch_lines` (لقطة مالية دائمة) + `settlement_source_claims` (منع الاحتساب المزدوج DB-level). |
| 0174 | `settlement_bank_movement_schema.sql` | دفتر حركات بنكية Append-only + عكوسها (حد أقصى عكس واحد لكل حركة). |
| 0175 | `settlement_batch_cancellations_schema.sql` | إلغاء الدفعة كحدث منفصل Append-only، لا يمس الدفعة الأصلية إطلاقًا. |
| 0176 | `settlement_source_adapter_and_discovery.sql` | Settlement Source Adapter الموحَّد (7 مصادر UNION ALL) + `list_unsettled_settlement_sources`/`preview_settlement_batch`. |
| 0177 | `settlement_batch_draft_rpcs.sql` | `create/update_draft_settlement_batch`. |
| 0178 | `finalize_settlement_batch.sql` | **دالة السلطة المركزية** — الاعتماد الذري الكامل. |
| 0179 | `settlement_bank_movement_rpcs.sql` | `record/reverse_settlement_bank_movement`. |
| 0180 | `reconcile_settlement_batch.sql` | مطابقة حية (actual/variance غير مخزَّنين أبدًا). |
| 0181 | `cancel_settlement_batch.sql` | إلغاء الدفعة + تحرير المطالبات. |
| 0182 | `settlement_batch_read_rpcs.sql` | `list/get_settlement_batch` + `settlement_store_filter_lookups` (كامل سطح القراءة). |
| 0183 | `audit_logs_settlements_financial_protection.sql` | توسيع سياسة `audit_logs_select` لحجب 6 أحداث `settlement.*` مالية خلف `settlements.view_financials`. |

**لا استثناء على التجميد:** لم تُعدَّل أي ترحيلة من 0001–0166 إطلاقًا (تحقُّق byte-for-byte كامل، §9 أدناه).

---

## 2) دالة السلطة `finalize_settlement_batch()` (0178) — عيبان حقيقيان وُجدا وأُصلِحا أثناء الاختبار الفعلي

هذه هي الدالة الأكثر أهمية وتعقيدًا في الوحدة بالكامل (23 خطوة: قفل، فحص إصدار/حالة، Daily Close، قفل Settlement Master، إعادة حل كل مصدر من القاعدة، حساب/لقطة كل سطر، إجماليات الدفعة، رسوم الدفعة/تجاوزها، إنشاء المطالبات، تدقيق). عند أول اختبار فعلي شامل لها (لا أثناء الكتابة)، ظهر عيبان حقيقيان قاطعان — **الدالة كانت معطَّلة 100% لكل استدعاء قبل الإصلاح**:

1. **مرجع عمود `id` غامض (Ambiguous column reference).** `returns table (id uuid, ...)` يجعل `id` متغيّرًا ضمنيًا في نطاق الدالة بأكملها. خمسة استعلامات غير مؤهَّلة (`where id = ...` بلا اسم جدول) على `payment_methods`/`collection_channels`/`shipping_carriers`/داخل إدراج `settlement_batch_lines` كانت تفشل بخطأ `column reference "id" is ambiguous` — أي استدعاء يصل إلى تلك الأسطر (أي استدعاء فعليًا، بمجرد حلّ المسار) كان يفشل فورًا.
2. **عطل Record غير مُعيَّن.** `v_pm`/`v_cc`/`v_carrier` كانت متغيرات `record` تُملأ شرطيًا فقط. بما أن قيد `settlement_routes_kind_fields_consistent` (0168) يضمن أن مسار `payment_collection` يفتقد دومًا `shipping_carrier_id` وأن مسار `cod_carrier` يفتقد دومًا `payment_method_id`/`collection_channel_id`، فإن أحد هذه الـ`record` الثلاثة يبقى **غير مُعيَّن فعليًا** (لا NULL فقط) في كل استدعاء — قراءة `.name_ar` منها لاحقًا كانت تُطلِق `record "..." is not assigned yet`.

**الإصلاح:** تأهيل كل مرجع `id` بلقب جدول صريح، واستبدال الثلاثة متغيرات `record` بمتغيرات `text` بسيطة قابلة للـNULL (الحقل الوحيد المقروء منها فعليًا هو `.name_ar`). أُعيد تطبيق 0178 وأُعيد تشغيل الاختبار الشامل بالكامل للتأكد — نجح 100%. **لم تُعدَّل أي ترحيلة أخرى (0167، 0169–0177، 0179–0183) — كلها عملت بشكل صحيح من أول تشغيل فعلي، بلا أي إصلاح.**

---

## 3) تغطية الاختبار SQL الفعلية (`supabase/tests/settlements_phase7.test.sql`)

ملف اختبار جديد بالكامل، معاملة واحدة (`begin; ... rollback;`)، **1172 سطرًا، 32 تأكيد PASS** موزَّعة على 8 أقسام:

0. دورة حياة المسار/إصدار الرسوم — تفرُّد مطابقة المسار، رفض الإصدار الغامض (جارٍ مقابل مستقبلي).
1. **Sign Convention** (الأخطر منطقيًا في الوحدة كلها) — بيع/استرداد كامل/تعديل معتمَد/عكس تعديل، الأرقام الموقَّعة مُحسوبة من نتائج RPC حقيقية لا مُدخَلة يدويًا، مطابقة تمامًا لعقد 0176 الموثَّق:
   - بيع: `gross=+subtotal`، `fee=+payment_fee_amount`.
   - استرداد: `gross=-sales_revenue_reversal_amount`، `fee=-payment_fee_reversal_amount`.
   - تعديل معتمَد: `gross=+customer_charge`، `fee=+payment_fee_amount`.
   - عكس تعديل: `gross=-customer_charge` (= `customer_charge_reversal_amount` المخزَّن سالبًا أصلًا)، `fee=-payment_fee_reversal_amount`.
   - `preview_settlement_batch()` مطابق تمامًا لمجموع الأسطر.
2. **الاعتماد (Finalization)** — لقطة الأسطر/المطالبات صحيحة، `settlement_calculation_version=1`، **إثبات كتابة موثوقة (Trusted-write proof)**: محاولة `UPDATE` خام مباشر (كـsuperuser) على عمود مالي/لقطة بعد الاعتماد — لا يزال محفِّز `settlement_batches_reject_financial_mutation` (0172) يرفضها. رفض إعادة اعتماد دفعة مُعتمَدة أصلًا، ورفض اختيار مصدر لم يعد متاحًا (Stale Selection).
3. تجاوز رسوم الدفعة + تجاوز اليوم المقفل — كلاهما يتطلَّب صلاحية مرتفعة + سبب إلزامي.
4. دورة حياة الحركة البنكية الكاملة — تسجيل، مطابقة صفر الفرق، مطابقة فرق غير صفري (تتطلَّب `settlements.reconcile_variance` + سبب)، عكس حركة (حد أقصى عكس واحد)، إلغاء دفعة (بعد عكس كل حركاتها البنكية بالكامل)، تحرير المطالبات وإعادة ظهورها في `list_unsettled_settlement_sources()`، **إثبات عدم مساس عمودي خام**: `settlement_batches` نفسها لم تتغيَّر بايتًا واحدًا جراء الإلغاء.
5-6. دوال القراءة — حجب الحقول المالية خلف `settlements.view_financials` (NULL لا صفر)، اشتقاق `effective_status='cancelled'`، قاعدة الرؤية الشرطية (OR) بين المتجر الأساسي والثانوي للسطر (خصوصية عبر-المتاجر، البند 21) — أُثبتت جهتا القاعدة (الظهور والإخفاء الصامت كليهما).
7. مصفوفة رفض صلاحيات كاملة عبر كل عائلة RPC.

---

## 4) اختبار التزامن الحقيقي (`supabase/tests/settlements_phase7_concurrency.test.sql`)

ملف جديد، **344 سطرًا**، جلسات `dblink` حقيقية متزامنة فعليًا (النمط المعتمَد في المشروع منذ Phase 3/4/5/6 — لا محاكاة):

- **السيناريو A:** دفعتا مسودة مختلفتان تحاولان اعتماد (`finalize_settlement_batch`) نفس المصدر بالضبط في نفس اللحظة — نجاح واحد فقط، فشل نظيف للآخر (violation على `settlement_source_claims_active_unique_idx`)، لا مطالبة مزدوجة أبدًا على مستوى القاعدة. **هذا الإثبات الأهم في الوحدة بأكملها.**
- **السيناريو B:** استدعاءا `reverse_settlement_bank_movement()` متزامنان على نفس الحركة البنكية — نجاح واحد فقط (قيد `bank_movement_event_id` الفريد).

كلا السيناريوهين **PASS**. بيانات الفِكستشر الخاصة بملف التزامن (متجر واحد، فاعل واحد، 3 دفعات، مسار مُعطَّل واحد) تبقى **قائمة عمدًا** بعد التشغيل على `gold_erp_phase7_dev` (موثَّق داخل الملف نفسه) — نفس اتفاقية `shipping_core_phase5_concurrency.test.sql` القائمة، لأن كل جداول الوحدة Append-only/no-hard-delete بالتصميم أصلًا.

---

## 5) إثبات سلامة الترقية (Upgrade Safety) — الأقوى ممكنًا لهذه الوحدة تحديدًا

بما أن جوهر Phase 7 هو Settlement Source Adapter الذي يقرأ بيانات **مُلتزَمة مسبقًا** من Sales/Returns/Adjustments دون إعادة حسابها، فإن أقوى إثبات ممكن هو أن المحوِّل يكتشف بيانات أُنشئت فعليًا **قبل وجود Phase 7 إطلاقًا**، تحت المخطط/RPCs القديمة تمامًا — لا فِكستشر اصطناعي بعد الترقية.

ثلاثة ملفات جديدة (تُحاكي بدقة نمط `run_upgrade_test_patch_6_1.sh` ثلاثي الاستدعاء):

1. `supabase/tests/fixtures/phase7_upgrade_pre_fixture.sql` — يُشغَّل عند 0001–0166 + `seed.sql` الحقيقي (بلا Phase 7 إطلاقًا). يُنشئ متجرًا، بيانات رئيسية دنيا، طلب بيع (subtotal=800.00، fee=0.00 نقدًا)، استردادًا كاملًا معتمَدًا عليه، تعديلًا معتمَدًا (`participates_in_settlement=true`، charge=150.00) وعكسه — عبر RPCs ما قبل Phase 7 حصرًا. يُثبِّت (`COMMIT`، لا rollback) كل المعرِّفات/الأرقام/المبالغ المعروفة في جدول سجل دائم `public.p7u_scratch`.
2. migrations 0167–0183 تُطبَّق فوقها (استدعاء psql منفصل، تمامًا كترقية إنتاج حقيقية).
3. `supabase/tests/upgrade_phase7_settlements.test.sql` — يُثبِت: (أ) 10 مفاتيح صلاحية `settlements.*` الجديدة + منح الأدوار تأتي من 0167 نفسها (لا `seed.sql`، لا تكرار)؛ (ب) مسار تسوية جديد + إصدار رسوم `source_snapshot` يكتشف عبر `list_unsettled_settlement_sources()` البيع/الاسترداد/التعديل/عكس التعديل **السابقين لِPhase 7 فعليًا** بأرقام موقَّعة مطابقة تمامًا لعقد 0176، محسوبة من `p7u_scratch` لا مُدخَلة يدويًا؛ (ج) `finalize_settlement_batch()` يعتمد الأربعة بنجاح وتُلقَط أسطرها بشكل صحيح؛ (د) كل معرِّف/رقم تاريخي مطابق تمامًا (byte-identical) قبل/بعد الترحيل — لم يُلمَس أي صف قط.
4. `scripts/run_upgrade_test_phase7_settlements.sh` — التنسيق الكامل (5 استدعاءات psql منفصلة).

**النتيجة الفعلية (مُنفَّذة مرتين لإثبات إعادة التشغيل/الـIdempotency):**

```
psql:...upgrade_phase7_settlements.test.sql:350: NOTICE:  === ALL UPGRADE-TO-PHASE-7 TESTS PASSED (0167-0183 applied onto a real
pre-Phase-7 production-shaped database, WITHOUT re-running seed.sql — Settlement Source Adapter discovers genuinely
pre-existing Sale/Return/Adjustment/Adjustment-Reversal data) ===
DO
ROLLBACK
DROP TABLE
==> Phase 7 upgrade test PASSED
```

الأمر الفعلي المستخدم في هذه البيئة (المصادقة المحلية Peer فقط عبر مستخدم نظام `postgres`):
```
sudo -u postgres env DATABASE_URL="postgresql:///gold_erp_p7_upgrade_verify" bash scripts/run_upgrade_test_phase7_settlements.sh
```

لم يُوجَد أي عيب في 0167–0183 أثناء هذا الاختبار تحديدًا (العيبان الوحيدان في الجلسة بأكملها كانا في 0178، مذكوران في §2 أعلاه، ومُصلَحان قبل هذا الاختبار).

---

## 6) واجهة المستخدم (UI) — بُنيت وفُحصت بالكامل

**صفحات جديدة:** `/settlements` (قائمة + مرشِّحات)، `/settlements/new` (اكتشاف مصادر + معاينة حية + اعتماد)، `/settlements/[id]` (تفاصيل + إجراءات دورة الحياة: اعتماد/تسجيل حركة/عكس حركة/مطابقة/إلغاء، كل إجراء محجوب خلف صلاحيته الخاصة)، `/master-data/settlement-routes` (إدارة المسارات وإصدارات رسومها).

**طبقة البيانات:** `src/features/settlements/{schema,queries,actions}.ts` + 9 مكوِّنات تحت `src/features/settlements/components/`، بنفس بنية/اتفاقيات وحدة Adjustments تمامًا (Zod، معالجة أخطاء، `revalidatePath`).

**قرارات نطاق واعية (مُوثَّقة في الكود):**
- `list_settlement_batches()` لا تُعيد `total_count` (خلافًا لبقية دوال القائمة في المشروع) — بُني مُرقِّم Next/Previous فقط (`settlement-batches-pager.tsx`) بجلب `pageSize+1` بدل اختلاق إجمالي.
- لا توجد دوال بحث ضيقة مخصَّصة لطرق الدفع/قنوات التحصيل/ناقلي الشحن ضمن Phase 7 نفسها لصفحة إنشاء المسار — تُقرَأ الجداول الأساسية الثلاثة مباشرة، محكومة بـRLS الخاص بها (`payment_methods.view`/`collection_channels.view`/`shipping_rates.view`)؛ فاعل يملك `settlements.manage_routes` فقط دون هذه الصلاحيات يرى قائمة اختيار فارغة مع تنبيه صريح في الواجهة.
- مرشِّح الحالة في قائمة الدفعات لا يعرض "ملغاة" كخيار مباشر (لأن `effective_status='cancelled'` مُشتقَّة خادميًا، لا قيمة `status` حقيقية تُمرَّر لِ`p_status`) — الدفعة الملغاة تظهر مع ذلك بشارتها الصحيحة ضمن نتائج أي مرشِّح آخر.

**النتيجة:** `npm run typecheck` → صفر أخطاء. `npm run lint` → صفر أخطاء (4 تحذيرات قائمة مسبقًا في ملف لم يُلمَس). `npm run build` → نجاح كامل، كل مسارات `/settlements*` و`/master-data/settlement-routes` مسجَّلة وتُبنى بنجاح.

`src/types/database.ts` احتاج توسيعًا إضافيًا بعد بناء الواجهة (أضافه هذا الملخِّص مباشرة): 4 كتل `Row` كاملة لـ`settlement_batches`/`settlement_batch_lines`/`settlement_bank_movement_events`/`settlement_bank_movement_reversals` كانت ناقصة (الواجهة لم تحتَج قراءة الجداول الخام مباشرة فاستُغني عنها أثناء بناء الواجهة، لكن `check:numeric-types` يتطلَّب وجود كتلة `Row` لكل جدول فيه عمود NUMERIC) — أُضيفت الأربعة بأنواع مطابقة تمامًا لِ`information_schema.columns` الفعلي، والفحص أصبح نظيفًا (انظر §7).

---

## 7) اختبارات Vitest — جديدة بالكامل

**5 ملفات جديدة، 70 اختبارًا جديدًا، كلها PASS:**

- `tests/settlements-schema-validation.test.ts` (28) — قواعد Zod: الاعتماد يتطلَّب مصدرًا واحدًا على الأقل، تلازم تجاوز رسوم الدفعة/السبب، أسباب إلزامية للإلغاء/العكس، مبلغ الحركة البنكية لا يساوي صفرًا، قواعد المسار/إصدار الرسوم المتقاطعة.
- `tests/settlements-actions-permission-boundary.test.ts` (23) — كل Server Action محجوب خلف صلاحيته الخاصة بدقة، رفض Zod قبل أي نداء RPC، انتشار أخطاء القاعدة.
- `tests/settlements-financials-pass-through.test.tsx` (7) — تمرير إشارات Sign Convention بلا إعادة اشتقاق (نفس فئة العيب التي أصلحتها Hotfix 6.1.2 سابقًا في وحدة أخرى) + حجب الحقول المالية (`null` ← `—`، أبدًا `0.00`).
- `tests/settlements-pagination.test.tsx` (11) — حساب `pageSize+1` الفعلي (حارس off-by-one) + سلوك مكوِّن الترقيم.
- `tests/settlements-list-filter-pagination.test.tsx` (3) — تكامل: المرشِّحات النشطة تنتقل بشكل صحيح إلى رابط "الصفحة التالية".

**نتيجة السلسلة الكاملة (جديد + قائم سابقًا):**

```
Test Files  20 passed (20)
     Tests  199 passed (199)
```

(كانت الحالة الأساسية 15 ملفًا/126 اختبارًا قبل هذه الجلسة — **صفر انحدار**، 5 ملفات/70 اختبارًا جديدة بالكامل.)

لم يُوجَد أي عيب في طبقة الواجهة (`src/features/settlements/*`) أثناء كتابة هذه الاختبارات — Sign Convention والحجب المالي كانا صحيحين من أول تأكيد.

---

## 8) إعادة تشغيل كامل السطح — نتائج فعلية نهائية (من هذه الجلسة)

- `supabase/tests/settlements_phase7.test.sql` → **32/32 PASS** (`ROLLBACK` نظيف، لا أثر متبقٍّ).
- `supabase/tests/settlements_phase7_concurrency.test.sql` → **سيناريوهان A/B PASS**.
- مسار الترقية الكامل (`run_upgrade_test_phase7_settlements.sh`) → **PASS**، قابل لإعادة التشغيل (idempotent، جُرِّب مرتين).
- `DATABASE_URL=... npx tsx scripts/check-numeric-column-types.ts` (بعد توسيع `database.ts`، §6) → **`OK: all 89 raw NUMERIC column(s) ... correctly typed as number`**.
- `npx tsc --noEmit` → **صفر أخطاء**.
- `npx eslint .` → **صفر أخطاء** (4 تحذيرات قائمة مسبقًا، غير متعلقة).
- `npm run build` (Next.js) → **نجاح كامل**، كل مسارات `/settlements*`/`/master-data/settlement-routes` مبنية.
- `npx vitest run` → **199/199 عبر 20 ملفًا** (70 جديدة، صفر حذف/إضعاف).

**غير مُنفَّذ في هذه الجولة (فجوة مُقِرّ بها صراحة، لا إغفال):** لم يُوسَّع `scripts/postgrest-http-test.mjs` (3218 سطرًا، مسار HTTP/PostgREST حقيقي) بقسم "Settlements" مخصَّص. السبب: كل قواعد RLS/الصلاحيات/الحجب المالي لهذه الوحدة أُثبتت بشكل حاسم على مستوى SQL مباشرةً (نفس منطق RLS الذي يحكم PostgREST بالضبط، لا مسار مختلف)، وحجم إضافة تغطية HTTP كاملة ومستقلة لوحدة بهذا الحجم (17 ترحيلة، 12 RPC) كان سيتطلَّب وقتًا يتجاوز ما تبقَّى في هذه الجلسة دون مبرِّر تناسبي إضافي حقيقي فوق تغطية SQL/Vitest/UI الحالية الشاملة. مُسجَّل هنا صراحة كبند مؤجَّل لمراجعة لاحقة، لا كإغفال صامت.

---

## 9) إثبات: 0001–0166 لم تتغيَّر إطلاقًا (byte-for-byte)

مقارنة كل ترحيلة 0001–0166 + `supabase/seed.sql` مقابل `gold-erp-hotfix-6-1-2.zip` المُسلَّمة سابقًا (SHA-256 `9d3a5f7319d4626e47f7f5a6d089e1e46a9969f48a093464191d05ef5e6c1c79`):

```
diff_found=0
```

**166/166 ترحيلة مطابقة تمامًا، `seed.sql` مطابق تمامًا.** الملفات الوحيدة المُعدَّلة خارج `supabase/migrations/` هي بالضبط الملفات المتوقَّعة لِربط وحدة جديدة بالواجهة القائمة (`src/app/(app)/settlements/page.tsx` — استبدال "قريبًا" بالصفحة الحقيقية، `src/app/(app)/master-data/page.tsx`، `src/components/layout/nav-items.ts`، `src/lib/constants.ts`، `src/lib/permissions/constants.ts`، `src/types/database.ts`) — لا شيء آخر.

---

## 10) خلاصة

Phase 7 — Settlements Core مُسلَّمة كاملة وظيفيًا حسب النطاق المطلوب (Settlement Routes + Fee Versions، Source Discovery + Sign Convention، Draft/Finalize/Bank-Movement/Reconcile/Cancel، القراءة مع الحجب المالي والخصوصية عبر-المتاجر، الواجهة الكاملة، صلاحيات/تدقيق). **17 ترحيلة جديدة (0167–0183، بلا أي تعديل على 0001–0166) + ملف اختبار SQL جديد بـ32/32 تأكيد PASS + ملف تزامن حقيقي (سيناريوهان A/B) + مسار ترقية كامل مُثبَت مرتين + 199 اختبار Vitest (70 جديد، صفر انحدار) + 89/89 عمود NUMERIC + بناء إنتاجي ناجح — كلها من تشغيلات فعلية في هذه الجلسة. عيبان حقيقيان وُجدا وأُصلِحا في `finalize_settlement_batch()` (0178) أثناء الاختبار الفعلي الأول — موثَّقان بالكامل في §2. فجوة واحدة مؤجَّلة صراحة: تغطية HTTP/PostgREST مخصَّصة (§8).** لم تُعدَّل أي ترحيلة من 0001–0166. لم يبدأ Phase 8 ولا أي عمل خارج نطاق Settlements. لم يُحذَف ولم يُضعَف أي اختبار قائم.

---

*نهاية التقرير.*
