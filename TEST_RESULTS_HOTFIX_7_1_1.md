# TEST_RESULTS_HOTFIX_7_1_1.md

## Phase 7 — Final Integrity Hotfix 7.1.1 (Settlements Core — Historical Cash Timeline, Store Scope, Privacy & Preview Parity)

هذا الملف يوثِّق نتائج الاختبار الفعلية الكاملة لِـHotfix 7.1.1 (ترحيلات 0192–0196)، مُنفَّذة داخل هذه الجلسة على قواعد بيانات حقيقية، بأرقام حقيقية من تشغيل فعلي مباشر — لا تقديرات ولا نقل عن وكيل فرعي دون تحقق مستقل. كل رقم في هذا الملف أُعيد تشغيله وتأكيده من جديد (fresh run) في الساعات الأخيرة من هذه الجلسة تحديدًا، على قواعد بيانات مبنية من الصفر، لضمان أن الحالة النهائية المُسلَّمة هي التي تعكس الأرقام فعليًا.

---

## 0) إعداد البيئة والتحقق من نظافة قاعدة التجميد

- Postgres محلي 16 (`sudo service postgresql status` → online طوال الجولة النهائية، لم يتطلب إعادة تشغيل).
- قاعدة `gold_erp_h711_sweep` بُنيت من الصفر بالكامل لهذه الجولة النهائية: `DROP DATABASE` → `CREATE DATABASE` → `supabase/tests/local_harness_setup.sql` → **جميع الترحيلات 0001–0196 بالترتيب دون توقف واحد** → `supabase/seed.sql`. هذا التشغيل بحد ذاته هو إثبات **§20 البند A** (تركيب نظيف من الصفر 0001→الأحدث).
- **قاعدة التجميد (§0) مُتحقَّق منها آليًا وبايت-لبايت:** مقارنة `cmp` مباشرة لكل ملف من الـ191 ترحيلة القديمة (0001–0191) بين الأرشيف المُسلَّم سابقًا `gold-erp-patch-7-1-settlements.zip` (SHA-256 `d09fb1322860a63356a87a26841c00baeee41d89a83b12305908e9786fa16b7f`) وحالة المستودع الحالية: **0/191 ملف يختلف**. تأكيد إضافي عبر مقارنة قوائم `sha256sum` مُرتَّبة لكلا المجموعتين (191 توقيعًا لكل جانب): **مطابقة تامة**. انظر §9 أدناه للتفصيل الكامل.

---

## 1) الترحيلات الجديدة (0192–0196) — جدول كامل

جميعها تستخدم `CREATE OR REPLACE FUNCTION` (نفس التوقيع) حيثما أمكن، أو `DROP FUNCTION IF EXISTS` صريح متبوعًا بإعادة الإنشاء عندما يتطلب التصحيح تغيير التوقيع/مخطط الإرجاع — لا تعديل مباشر على أي ترحيلة قديمة (0001–0191) إطلاقًا.

| # | الترحيلة | الحجم | الغرض المختصر |
|---|---|---|---|
| 0192 | `settlement_source_adapter_hotfix_7_1_1.sql` | 23,483 بايت | CREATE OR REPLACE لِ`_settlement_unsettled_source_candidates()`: مرشِّحا `return_fee_reversal`/`_reversal` أصبحا حدثين تاريخيين دائمين (`approved_at`/`reversal_business_date IS NOT NULL`، بصرف النظر عن الحالة اللحظية)، مُطابَقين عبر مسار البيع **الأصلي** (`sales_returns.sales_order_id → sales_orders`) لا `refund_method_id`. CREATE OR REPLACE لِ`list_unsettled_settlement_sources()`: مرشِّح المتجر أصبح OR (أساسي أو ثانوي) بدل شرط رؤية AND. تعليق توثيقي على `settlement_routes.collection_channel_id` (دلالات NULL الدقيقة). |
| 0193 | `settlement_lifecycle_ownership_and_store_scope_hotfix_7_1_1.sql` | 31,183 بايت | CREATE OR REPLACE لِ`update_draft_settlement_batch()` (فحص ملكية مطابق لِ`get_draft_settlement_batch_for_edit()`)، ولأربع RPCs دورة الحياة (`record`/`reverse_settlement_bank_movement`، `reconcile_settlement_batch`، `cancel_settlement_batch`) — نطاق متجر fail-closed عبر `_settlement_batch_all_stores_visible()`. `cancel_settlement_batch()` يضيف فحص تسلسل زمني (`>= MAX(reversal_business_date)`). `reconcile_settlement_batch()` يُخفي `actual_bank_movement`/`variance` دون `settlements.view_financials`. |
| 0194 | `settlement_fee_resolver_lockdown_hotfix_7_1_1.sql` | 2,883 بايت | `REVOKE EXECUTE` على `settlement_route_fee_for_route_on_date()` من `PUBLIC`/`authenticated` — لم تعد قابلة للاستدعاء المباشر عبر RPC، فقط داخليًا من RPCs أخرى بصلاحياتها الخاصة. |
| 0195 | `settlement_preview_batch_fee_override_hotfix_7_1_1.sql` | 10,424 بايت | `DROP FUNCTION` + `CREATE FUNCTION` لِ`preview_settlement_batch()` بتوقيع جديد (7 معاملات، `p_batch_fee_override`/`p_override_reason`) وتحقُّق مطابق تمامًا لِ`finalize_settlement_batch()`، يُرجِع `configured_batch_fee`/`effective_batch_fee`/`batch_fee_overridden` إضافة للحقول القديمة. |
| 0196 | `settlement_filter_lookups_hotfix_7_1_1.sql` | 4,614 بايت | ثلاث RPCs بحث جديدة (`settlement_filter_payment_method_lookups`/`_collection_channel_lookups`/`_carrier_lookups`) مقصورة حصرًا على `settlements.view` — لا `payment_methods.view`/`collection_channels.view`/`shipping_rates.view` — تشمل القيم المعطَّلة/التاريخية بلا فلترة. |

**لا استثناء على التجميد:** لم تُعدَّل أي ترحيلة من 0001–0191 إطلاقًا (§9).

---

## 2) اختبار SQL — `supabase/tests/settlements_phase7.test.sql` (مُحدَّث 2477→2576 سطرًا)

التحديث ضروري وليس اختياريًا: تغيير §1/§3 (مطابقة المسار عبر البيع الأصلي) غيَّر أي مسار يُطابِقه `return_fee_reversal` فعليًا مقارنة بسلوك ما قبل الهوتفكس — بما في ذلك القسم 8.1c الذي كان **يختبر الخلل القديم نفسه** (توقُّع اختفاء `return_fee_reversal` بعد عكس إداري). أُعيد بناء 8.1c بالكامل ليثبت **السلوك الصحيح الجديد** بدل الخلل القديم: أن المصدر يبقى ظاهرًا كحقيقة تاريخية دائمة، وأن عكسه يظهر كمصدر مستقل موازٍ، وأن الاثنين يتعادلان صفرًا ما داما غير مُطالَب بهما.

تشغيل نظيف مباشر مقابل `gold_erp_h711_sweep` (0001–0196 + seed) في هذه اللحظة تحديدًا:

```
$ psql -d gold_erp_h711_sweep -f supabase/tests/settlements_phase7.test.sql
...
NOTICE:  PASS: 8.16c §19 — source_snapshot is rejected for a cod_carrier route ...
Exit code: 0
```

**النتيجة: 68/68 تأكيد PASS (67 السابقة + 1 إضافي من إعادة بناء 8.1c)، صفر سطر `ERROR:`، Exit 0.**

---

## 3) اختبار SQL جديد كليًا — `supabase/tests/settlements_hotfix_7_1_1.test.sql` (461 سطرًا)

ملف مخصَّص بالكامل لهذا الهوتفكس، مستقل عن `settlements_phase7.test.sql`، يبني 7 فاعلين (admin/owner/other/viewCreate/storeScoped/reconcileOnly/filterView) عبر `user_permission_overrides` مباشرة (بلا أدوار)، ويثبت 7 أقسام مطابقة لِ§4/§5/§7/§9/§11/§12/§15:

```
$ psql -d gold_erp_h711_sweep -f supabase/tests/settlements_hotfix_7_1_1.test.sql
...
NOTICE:  === ALL settlements_hotfix_7_1_1.test.sql ASSERTIONS PASSED (§4/§5/§7/§9/§11/§12/§15 live regression coverage) ===
ROLLBACK
Exit code: 0
```

**النتيجة: 12/12 تأكيد PASS، Exit 0.** يشمل تحديدًا: (1) رفض `update_draft_settlement_batch()` لفاعل غير مالك، قبول المالك، وعدم تقييد حامل `settlements.view` (§4)؛ (2) رفض جميع RPCs الأربع الكاتبة لفاعل مقصور على متجر واحد لا يرى كل أسطر الدفعة (§5)؛ (3) إخفاء `actual_bank_movement`/`variance` لحامل `settlements.reconcile` وحده دون `view_financials` (§7)؛ (4) تطابق تام حرفي بين `effective_batch_fee` في preview وبين `original_batch_fee` المُثبَّت في finalize لنفس التجاوز (§9)؛ (5) رفض تاريخ إلغاء قبل آخر عكس حركة بنكية، وقبوله بعده (§11)؛ (6) عمل مرشِّحات البحث لحامل `settlements.view` وحده وشمولها القيم المعطَّلة (§12)؛ (7) مطابقة مرشِّح المتجر لمصدر تعديل عبر-متاجر بمنطق OR لا AND (§15).

---

## 4) تزامن حقيقي (`dblink`) — `supabase/tests/settlements_phase7_concurrency.test.sql` (بلا تعديل، أُعيد تشغيله كما هو)

لا تغيير مطلوب: لا يُدخِل هذا الهوتفكس أي حالة تسابق جديدة على منطق القفل الهرمي القائم. تشغيل نظيف مباشر مقابل قاعدة جديدة (0001–0196 + seed) في هذه اللحظة:

```
NOTICE:  ALL settlements_phase7_concurrency.test.sql ASSERTIONS PASSED (A-K)
Exit code: 0
```

**جميع السيناريوهات الحرفية الـ11 (A–K) لا تزال تعمل دون أي تعديل — 12 إشعار PASS (§19 مُحقَّق: لا حاجة لإعادة تصميم، ولم تُحذَف أي حالة).**

---

## 5) HTTP/PostgREST حقيقي — `scripts/postgrest-http-test.mjs` (مُوسَّع 4078→4611 سطرًا، §17)

قسم "Part 15" جديد كليًا (11 بندًا a–k) مُضاف فوق "Part 14" القائم (Patch 7.1)، يثبت كل سلوك HTTP-observable في الهوتفكس عبر PostgREST حقيقي (ثنائي فعلي على `/tmp/postgrest`) وJWTs موقَّعة حقيقية لـ3 فاعلين اختباريين جدد (`...010` مالك ثانٍ منفصل، `...011` مقصور على متجر مع كل صلاحيات الكتابة الأربع، `...012` تسوية-فقط دون `view_financials`) بالإضافة لإعادة استخدام فاعلين قائمين حيث ينطبق:

```
$ ADMIN_DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:5432/postgres" ./scripts/run_postgrest_http_test.sh
...
=== ALL REAL HTTP/POSTGREST INTEGRATION TEST ASSERTIONS PASSED ===
Exit code: 0
```

**النتيجة: 282 تأكيد `OK` عبر الملف بأكمله (بلا انحدار عن أي قسم سابق، بما فيها Part 1–14) — منها 31 تأكيد ضمن "Part 15" الجديد.** تغطي البنود a–k تحديدًا: (a) ملكية المسودة عند الكتابة؛ (b) نطاق المتجر على RPCs الأربع الكاتبة؛ (c) `settlement_route_fee_for_route_on_date()` لم تعد قابلة للاستدعاء عبر PostgREST إطلاقًا حتى لأقوى فاعل؛ (d) إخفاء حقول التسوية المالية؛ (e) تطابق preview/finalize لتجاوز رسوم الدفعة (تساوٍ نصّي حرفي، لا رقمي فقط) + رفض preview لسبب مفقود/قيمة سالبة؛ (f) تسلسل تاريخ الإلغاء؛ (g) مرشِّحات البحث الجديدة؛ (h) مطابقة OR لمرشِّح المتجر؛ (i) بقاء `return_fee_reversal` تاريخيًا بعد عكس إداري + ظهور `return_fee_reversal_reversal` مستقلًا + تعادلهما صفرًا؛ (j) استقرار `return_fee_reversal`/`return_refund_event` على مسارين مختلفين لنفس المرتجَع؛ (k) اعتماد كل منهما بشكل مستقل في دفعتين منفصلتين — كل هذا مُثبَت حيًّا عبر HTTP فعلي، ليس محاكاة.

اثنان من تأكيدات "Part 14" القديمة صُحِّحا داخل نفس الملف ليعكسا سلوك الهوتفكس الجديد الشرعي (وليس ضعفًا في الاختبار): توقُّع مسار `return_fee_reversal` (تغيَّر بفعل §3)، وحقل `batch_fee` في نتيجة preview (أُعيد تسميته بفعل §9) — كلاهما تصحيح متوقَّع ومُبرَّر، لا حذف تغطية.

---

## 6) React/Vitest — التغطية الجديدة (§18)

تشغيل نظيف كامل في هذه اللحظة:

```
$ npm run test
 Test Files  25 passed (25)
      Tests  265 passed (265)
```

**265/265 (زيادة صافية 36 اختبارًا عن 229 السابقة، صفر انحدار).** ملف جديد كليًا `tests/settlements-hotfix-7-1-1.test.tsx` (318 سطرًا) يغطي البند A (نص القناة الدقيق، لا "كل القنوات" إطلاقًا)، نصف مكوِّن البند G (إخفاء `source_snapshot` لمسارات COD)، والبند H (تعطيل تسجيل حركة بنكية جديدة لدفعة مُطابَقة). ملفات مُحدَّثة: `settlements-preview-state-machine.test.tsx` (آلة حالة الترويسة القذرة §10 — البنود B/C، عرض/تطابق التجاوز §9 — البنود D/E)، `settlements-schema-validation.test.ts` (نصف Zod للبند G)، `settlements-money-string-invariant.test.ts` (البند I — فحص شامل عبر الدليل بأكمله يشمل أجسام `.refine()` صراحة، لا استثناء لها)، `settlements-list-filter-pagination.test.tsx`/`settlements-pagination.test.tsx` (البند F).

`npm run typecheck` → **نظيف تمامًا، Exit 0.** `npm run lint` → **0 أخطاء** (4 تحذيرات سابقة الوجود غير متعلقة بـSettlements، لم تُمَس).

**عيبان حقيقيان صغيران وُجدا وأُصلِحا أثناء كتابة الاختبارات (لا أثناء التخطيط):**
1. `src/features/settlements/schema.ts` — `.refine()` ثانٍ في `signedNonZeroMoneySchema` كان يستدعي `toDecimal(v).isZero()` دون حماية، فيرمي استثناءً خامًا بدل فشل Zod عادي لمدخل مثل `""`/`"-"`/`"+"` — أُصلِح بلفّه في try/catch.
2. `settlement-draft-workspace.tsx` — `FinalizeDialog.submit()` كان يرسل قيمة/سبب التجاوز **بدون trim()** بينما `runPreview()` يرسلهما بعد `trim()` — قيمة تحمل فراغًا زائدًا عرضيًا كانت تصل لـ`finalize` بنص مختلف عمّا عرضه `preview` للتو. أُصلِح بمطابقة `trim()` في كليهما.

---

## 7) حارس عدم استخدام Float للأموال (§13)

تشديد إضافي هذه الجولة: "لا Exception لـ`.refine()`" — أُعيد بناء `tests/settlements-money-string-invariant.test.ts` ليفحص كامل الدليل `src/features/settlements/**/*.{ts,tsx}` (لا `schema.ts` وحده) بحثًا عن أي `Number(`/`parseFloat(`/`parseInt(` **بما في ذلك داخل أجسام `.refine()`** — بلا أي استثناء أو تجاهل لتلك الأجسام. النتيجة: **صفر انتهاك حي** — العقد الفعلي في `schema.ts` مُثبَت آمنًا حقًّا تجاه refine، لا شكليًا فقط.

---

## 8) اختبارات أمان الترقية (§20) — الأربعة كاملة

| البند | الوصف | السكربت | النتيجة (تشغيل نظيف الآن) |
|---|---|---|---|
| A | تركيب نظيف 0001→الأحدث (0196) + seed.sql | إعادة بناء `gold_erp_h711_sweep` (§0 أعلاه) | **نجاح تام، بلا خطأ تطبيق واحد** |
| B | 0166→الأحدث (Phase 7 + Patch 7.1 + Hotfix 7.1.1 معًا فوق بيانات ما قبل Phase 7) | `scripts/run_upgrade_test_phase7_settlements.sh` (بلا تعديل — حلقة "migrations ≤/≥" فيه تشمل 0192–0196 تلقائيًا) | **`ALL UPGRADE-TO-PHASE-7 TESTS PASSED`، Exit 0** |
| C | 0183→الأحدث فوق بيانات Phase 7 حقيقية | `scripts/run_upgrade_test_phase7_1_settlements.sh` (بلا تعديل، لنفس السبب) | **`ALL UPGRADE-TO-PHASE-7.1 TESTS PASSED`، Exit 0** |
| D | 0191→الأحدث فوق بيانات Hotfix-7.1.1-الصلة حقيقية (مصدر عكس رسوم مُطالَب تحت القاعدة القديمة، مسودة/معتمَدة/مطابَقة/مُلغاة، تعديل عبر-متاجر) | `scripts/run_upgrade_test_hotfix_7_1_1_settlements.sh` (جديد كليًا) + `supabase/tests/fixtures/hotfix_7_1_1_upgrade_pre_fixture.sql` + `supabase/tests/upgrade_hotfix_7_1_1_settlements.test.sql` (جديدان كليًا) | **`Hotfix 7.1.1 upgrade test (item D) PASSED`** — إثبات تطابق byte-identical كامل لكل صف قديم (بما فيه سطر المطالبة المزدوجة `return_refund_event`+`return_fee_reversal` تحت القاعدة القديمة على مسار NULL-channel)، وأن منطق الاكتشاف الجديد **لا يُحيي مصدرًا مُطالَبًا به مسبقًا أبدًا**، وأن كل قدرة جديدة في الهوتفكس تعمل صحيحًا على بيانات ما-بعد-الترقية، Exit 0 |

كل الأربعة، بالإضافة إلى 5 سكربتات ترقية أقدم غير متعلقة مباشرة بالهوتفكس (`run_upgrade_test.sh`، `run_upgrade_test_hotfix_4_2_1.sh`، `run_upgrade_test_patch_4_2.sh`، `run_upgrade_test_patch_6_1.sh`، `run_upgrade_test_phase6_adjustments.sh`)، أُعيد تشغيلها بشكل مستقل ونظيف (قاعدة بيانات جديدة تمامًا لكل تشغيل، بالتوازي) في الساعة الأخيرة من هذه الجلسة: **9/9 PASSED، Exit 0 لكل واحد، صفر انحدار.**

---

## 9) إثبات عدم المساس بترحيلات 0001–0191 (byte-for-byte)

```
$ cmp كل ملف من الـ191 ترحيلة القديمة (0001–0191) مقابل نظيره في gold-erp-patch-7-1-settlements.zip
TOTAL_DIFFERING_0001_0191=0

$ diff <(sha256sum مُرتَّب لِـ191 ملفًا من الأرشيف) <(sha256sum مُرتَّب لِـ191 ملفًا من المستودع الحالي)
ALL 191 MIGRATION CHECKSUMS BYTE-IDENTICAL
```

المرجع: `gold-erp-patch-7-1-settlements.zip` (التسليم السابق)، SHA-256 `d09fb1322860a63356a87a26841c00baeee41d89a83b12305908e9786fa16b7f`. **لا فرق واحد — ولو بايت — على أي من 0001–0191. الفرق الوحيد هو وجود 5 ملفات ترحيل جديدة (0192–0196).**

---

## 10) إثبات استعادة `.env.example`

```
$ md5sum .env.example (الأرشيف السابق مقابل المستودع الحالي)
503293b4e55c4755e3737faa00bd5dd0  (كلا النسختين، 682 بايت)
```

**الملف حاضر وصحيح، مطابق حرفيًا للأساس القديم.**

---

## 11) فحوصات ثابتة نهائية — أُعيد تشغيلها جميعًا نظيفة في الساعة الأخيرة من الجلسة

| الفحص | الأمر | النتيجة |
|---|---|---|
| TypeScript | `npm run typecheck` | **نظيف تمامًا، Exit 0** |
| ESLint | `npm run lint` | **0 أخطاء، 4 تحذيرات سابقة الوجود غير متعلقة (`tests/adjustments-entry-form-zero-charge-state-machine.test.tsx`)** |
| أعمدة NUMERIC | `npm run check:numeric-types` (مقابل قاعدة 0001–0196 مبنية من الصفر) | **`OK: all 89 raw NUMERIC column(s) ... correctly typed`، Exit 0** |
| بناء إنتاجي | `npm run build` | **`✓ Compiled successfully`، بلا أي خطأ، جميع مسارات `/settlements`، `/settlements/[id]`، `/settlements/new`، `/master-data/settlement-routes` مبنية بنجاح (32 مسارًا إجمالًا)** |

---

## 12) ملخص نهائي

**كل رقم في هذا الملف من تشغيل فعلي حقيقي أُعيد تنفيذه في الساعات الأخيرة من هذه الجلسة تحديدًا:** 5 ترحيلات جديدة (0192–0196) + 68/68 PASS `settlements_phase7.test.sql` (مُحدَّث لإصلاح 8.1c ليختبر السلوك الصحيح بدل الخلل القديم) + 12/12 PASS ملف اختبار مخصَّص جديد كليًا `settlements_hotfix_7_1_1.test.sql` + تزامن A–K بلا تعديل (12 إشعار PASS) + 282 تأكيد HTTP حقيقي (31 جديد ضمن Part 15) + 265/265 Vitest (25 ملفًا، صفر انحدار، +36 اختبارًا جديدًا) + عيبان صغيران حقيقيان وُجدا وأُصلِحا أثناء كتابة الاختبارات (مُوثَّقان في §6) + حارس float نقدي مُشدَّد ليشمل أجسام `.refine()` صراحة + 4/4 اختبارات أمان ترقية (A/B/C/D) + 5/5 اختبارات ترقية أقدم بلا انحدار + 89/89 عمود NUMERIC + TypeScript/ESLint/بناء إنتاجي نظيفة بالكامل + إثبات byte-for-byte كامل لعدم المساس بـ0001–0191 + إثبات أن `.env.example` سليم. **لم تبدأ Phase 8. العمل متوقف الآن نهائيًا بانتظار المراجعة.**
