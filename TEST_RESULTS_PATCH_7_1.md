# TEST_RESULTS_PATCH_7_1.md

## Phase 7 — Integrity Patch 7.1 (تصحيح تكاملي شامل لِSettlements Core)

هذا الملف يوثِّق نتائج الاختبار الفعلية الكاملة لِـPatch 7.1 (ترحيلات 0184–0191)، مُنفَّذة داخل هذه الجلسة على قاعدة بيانات حقيقية، بأرقام حقيقية من تشغيل فعلي مباشر — لا تقديرات ولا نقل عن وكيل فرعي دون تحقق مستقل. كل رقم في هذا الملف أُعيد تشغيله وتأكيده من جديد (fresh run) في الساعات الأخيرة من هذه الجلسة تحديدًا لضمان أن الحالة النهائية المُسلَّمة هي التي تعكس الأرقام فعليًا، لا حالة وسيطة سابقة.

---

## 0) إعداد البيئة والتحقق من نظافة قاعدة التجميد

- Postgres محلي 16، أُعيد تشغيله مرتين خلال الجلسة بعد توقفه بسبب إعادة تشغيل الحاوية (`sudo service postgresql start`) — تفصيل طبيعة البيئة، لا خلل في العمل نفسه.
- قاعدة `gold_erp_test` أُعيدت بناؤها من الصفر بالكامل في نهاية الجلسة: `DROP DATABASE` → `CREATE DATABASE` → `supabase/tests/local_harness_setup.sql` (Auth schema stub) → **جميع الترحيلات 0001–0191 بالترتيب دون توقف واحد** → `supabase/seed.sql`. هذا التشغيل بحد ذاته هو إثبات **§34 البند A** (تركيب نظيف من الصفر 0001→الأحدث).
- قاعدة تطوير تراكمية منفصلة `gold_erp_patch71_dev` استُخدمت طوال الجلسة للتطوير التفاعلي، ثم أُعيد التحقق النهائي حصرًا من `gold_erp_test` المبنية من الصفر لضمان عدم وجود أي حالة متبقية (leftover state) تؤثر على النتيجة.
- **قاعدة التجميد (§0) مُتحقَّق منها آليًا:** `diff -rq` بين `supabase/migrations/` الحالي ومحتوى الأرشيف المُسلَّم سابقًا `gold-erp-phase7-settlements.zip` (SHA-256 `87cfe25502973d4c163e3766759924539227fa9a1dfad3dbe5c09559d086ef43`، مؤكَّد مطابقًا) يُظهر **فرقًا واحدًا فقط**: وجود 8 ملفات جديدة (0184–0191)، بلا أي تغيير — ولو بايت واحد — على أي من 0001–0183. انظر §9 أدناه للتفصيل الكامل.

---

## 1) الترحيلات الجديدة (0184–0191) — جدول كامل

جميعها تستخدم `CREATE OR REPLACE FUNCTION` (نفس التوقيع) حيثما أمكن، أو `DROP FUNCTION IF EXISTS` صريح متبوعًا بإعادة الإنشاء عندما يتطلب التصحيح تغيير نوع الإرجاع/الأعمدة — لا تعديل مباشر على أي ترحيلة قديمة إطلاقًا.

| # | الترحيلة | الحجم | الغرض المختصر |
|---|---|---|---|
| 0184 | `settlement_source_adapter_patch_7_1.sql` | 29,651 بايت | إعادة بناء `_settlement_unsettled_source_candidates()` (DROP+CREATE — تغيير أعمدة الإرجاع): مصادر استرداد فعلية جديدة (`return_refund_event`/`_reversal`/`return_fee_reversal`/`_reversal`)، نطاق متجر صحيح للمرتجعات (`processed_store_id`)، مطابقة قناة/مسار دقيقة (`IS NOT DISTINCT FROM`)، خصوصية عبر-المتاجر بمنطق AND، اكتشاف انتقال حالة COD حقيقي عبر `lag()`. |
| 0185 | `settlement_fee_resolver_and_finalize_patch_7_1.sql` | 30,457 بايت | `_settlement_resolve_line_fee()` جديدة (IMMUTABLE، مُشترَكة)، إعادة بناء `preview_settlement_batch()`/`finalize_settlement_batch()` لضمان تطابق تام بينهما، فحص `settlement_date<=business_today()`، Daily Close لكل متجر متأثر فعليًا. |
| 0186 | `settlement_batch_privacy_and_draft_getter_patch_7_1.sql` | 19,775 بايت | `_settlement_batch_all_stores_visible()` (خصوصية دفعة كاملة، fail-closed)، `get_draft_settlement_batch_for_edit()`، `settlement_create_store_lookups()`. |
| 0187 | `audit_logs_settlements_permission_split_patch_7_1.sql` | 6,417 بايت | تقسيم سياسة `audit_logs_select` إلى 3 فروع غير متداخلة (صلاحية المبيعات/التسويات/سجل التدقيق العام منفصلة تمامًا). |
| 0188 | `settlement_bank_movement_and_cancel_daily_close_patch_7_1.sql` | 21,513 بايت | إعادة بناء `record/reverse_settlement_bank_movement()` و`cancel_settlement_batch()` (`p_closed_day_reason` جديد، تسلسل تاريخ، Daily Close) + `drop function if exists` صريح للتوقيعات القديمة الثلاثة. |
| 0189 | `settlement_draft_rpcs_patch_7_1.sql` | 10,028 بايت | `create_draft_settlement_batch()` (فحص تاريخ مستقبلي)، `update_draft_settlement_batch()` بتوقيع جديد (8 معاملات، `_provided` صريحة) + `drop function if exists` للتوقيع القديم 6 معاملات. |
| 0190 | `settlement_route_fee_version_and_manage_routes_patch_7_1.sql` | 14,034 بايت | `validate_money_scale_n()`، إعادة بناء `create_settlement_route_fee_version()`، 4 دوال بحث جديدة مقصورة على `settlements.manage_routes`. |
| 0191 | `settlement_batch_list_filters_and_effective_semantics_patch_7_1.sql` | 18,796 بايت | DROP+CREATE لـ`list_settlement_batches()` (مرشِّحات جديدة + مخطط original_*/effective_*) و`get_settlement_batch()` (نفس المخطط). |

**لا استثناء على التجميد:** لم تُعدَّل أي ترحيلة من 0001–0183 إطلاقًا (§9).

---

## 2) عيبان حرجان وُجدا وأُصلِحا أثناء الاختبار الفعلي لِ0188 (لا أثناء الكتابة)

عند أول اختبار شامل فعلي بعد كتابة 0188، وجد تدقيق مستقل (وكيل فرعي مخصَّص للتحقق) عيبين حقيقيين قاطعين — كلاهما كان يجعل الوظائف الثلاث الجديدة (`record_settlement_bank_movement`/`reverse_settlement_bank_movement`/`cancel_settlement_batch`) إما معطَّلة كليًا أو قابلة للالتفاف حول كل إصلاحات §12/§13:

1. **خطأ نوع إرجاع في `_settlement_batch_relevant_store_ids()`:** أُعلنت بـ`returns setof uuid` بينما استدعتها الدوال الثلاث بـ`select store_id from ...` — عمود `setof uuid` الوحيد يُسمَّى باسم الدالة نفسها لا `store_id`، فكان كل استدعاء يفشل بـ`ERROR: column "store_id" does not exist` — **تعطُّل وظيفي كامل لثلاث RPCs**. أُصلِح إلى `returns table (store_id uuid)`.
2. **توقيعات قديمة معلَّقة وقابلة للوصول:** إضافة `p_closed_day_reason` كمعامل أخير عبر `CREATE OR REPLACE` أنشأت Overload **جديدًا** إلى جانب التوقيع القديم غير المُصحَّح (الذي بقي ممنوحًا لـ`authenticated`) — أي استدعاء بالتوقيع القديم كان يتجاوز صمتًا كل إصلاحات §12/§13. أُصلِح بإضافة `drop function if exists` صريح للتوقيعات الثلاثة القديمة في نهاية 0188.

بعد الإصلاح، أُعيد بناء قاعدة البيانات بالكامل من الصفر وتأكد عبر `select proname, pronargs, count(*) from pg_proc ... group by proname, pronargs` وعبر فحص أوسع `group by proname having count(*) > 1` على كامل وحدة Settlements أنه **لا يوجد أي Overload مكرر غير مقصود في أي RPC من الوحدة بأكملها**. **لم يُوجَد أي عيب مماثل في أي من الترحيلات السبع الأخرى (0184–0187، 0189–0191) — كلها عملت من أول تشغيل فعلي.**

---

## 3) اختبار SQL — `supabase/tests/settlements_phase7.test.sql` (مُوسَّع 1172→2477 سطرًا)

تشغيل نظيف مباشر مقابل `gold_erp_test` (0001–0191 + seed) في هذه اللحظة تحديدًا:

```
$ psql -d gold_erp_test -f supabase/tests/settlements_phase7.test.sql
...
NOTICE:  PASS: 8.16c §19 — source_snapshot is rejected for a cod_carrier route ...
DO
Exit code: 0
```

**النتيجة: 67/67 تأكيد PASS، Exit 0.** يغطي 8 أقسام رئيسية: دورة حياة المسار/إصدار الرسوم، Sign Convention، الاعتماد وتطابق preview/finalize، تجاوزات bank-movement/cancel المُصلَّحة، خصوصية القراءة الكاملة للدفعة، مصفوفة رفض الصلاحيات، ثم **القسم 8 الجديد (8.1–8.16)** المُضاف تنفيذًا لِ§31: مصادر الاسترداد الفعلي الجديدة والتراجع عنها، عكوس الرسوم، المطابقة الدقيقة `IS NOT DISTINCT FROM`، انتقال COD الحقيقي عبر `lag()`، خصوصية الدفعة الكاملة (fail-closed)، الحصول على مسودة للتحرير، تصنيف صلاحيات سجل التدقيق (Branch A/B/C)، ومصفوفة `manage_routes` المعزولة.

---

## 4) تزامن حقيقي (`dblink`) — `supabase/tests/settlements_phase7_concurrency.test.sql` (مُوسَّع 344→1232 سطرًا)

تشغيل نظيف مباشر مقابل `gold_erp_test` في هذه اللحظة:

```
NOTICE:  ALL settlements_phase7_concurrency.test.sql ASSERTIONS PASSED (A-K)
Exit code: 0
```

**جميع السيناريوهات الحرفية الـ11 (A–K) المطلوبة في §29/§30 مُثبَتة بجلسات `dblink` حقيقية متزامنة فعليًا (لا محاكاة تسلسلية)** — 12 إشعار `PASS` من A حتى K (السيناريو J يصدر إشعارين). تشمل: اعتماد متزامن لنفس المصدر من دفعتين (فوز واحد فقط)، تسجيل/عكس حركة بنكية متزامن، إلغاء متزامن، تعديل مسودة متزامن (تعارض row_version)، تعطيل مسار أثناء الاعتماد، وسيناريوهات القفل الهرمي (Settlement Master Lock + Daily Close) المتبقية.

---

## 5) HTTP/PostgREST حقيقي — `scripts/postgrest-http-test.mjs` (مُوسَّع ~3300→4078 سطرًا، §32)

تشغيل نظيف عبر PostgREST حقيقي (ثنائي فعلي على `/tmp/postgrest`) وJWTs موقَّعة حقيقية، في هذه اللحظة تحديدًا:

```
$ ADMIN_DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:5432/postgres" ./scripts/run_postgrest_http_test.sh
...
=== ALL REAL HTTP/POSTGREST INTEGRATION TEST ASSERTIONS PASSED ===
Exit code: 0
```

**النتيجة: 252 تأكيد `OK` عبر كامل الملف (بلا انحدار عن أي قسم سابق) — منها 66 تأكيد جديد ضمن "Part 14" (البنود a–y) المُخصَّص بالكامل لِ§32**، تغطي — من بين ما تغطيه فعليًا عبر HTTP حقيقي لا SQL مباشر: انعدام سياسات SELECT/INSERT الخام على الجداول الأساسية، تطابق تام بين `preview_settlement_batch()` و`finalize_settlement_batch()` لنفس رسوم `route_formula` (كلاهما 25.50 عبر HTTP فعلي، مُثبَت بندًا حرجًا صريحًا)، انتقال COD حقيقي `collected→not_collected` يُنتج مصدر `cod_reversal` بقيمة سالبة (-1200.00) بالضبط.

---

## 6) React/Vitest — التغطية الجديدة (§33)

تشغيل نظيف كامل في هذه اللحظة:

```
$ npm test -- --run
 Test Files  24 passed (24)
      Tests  229 passed (229)
```

4 ملفات جديدة بالكامل: `tests/settlements-preview-state-machine.test.tsx` (12 اختبارًا لآلة حالة المعاينة idle/loading/valid/stale/error وترقّي `previewKey`)، `tests/settlements-permission-scoped-workflows.test.tsx` (4 اختبارات لعزل مسارات `manage_routes` مقابل `create`/`view_financials`)، `tests/settlements-lifecycle-presentation.test.tsx` (9 اختبارات لعرض original_*/effective_* بعد الإلغاء)، `tests/settlements-money-string-invariant.test.ts` (5 اختبارات — انظر §7 أدناه). ملفان مُصلَحان (فِكستشر فقط، بلا حذف تغطية): `settlements-list-filter-pagination.test.tsx`، `settlements-financials-pass-through.test.tsx`.

`npm run typecheck` → **نظيف تمامًا (Exit 0)**، أُعيد تشغيله للتو ضمن هذه الجولة النهائية.

---

## 7) حارس عدم استخدام Float للأموال (§28)

`tests/settlements-money-string-invariant.test.ts` (5 اختبارات، جميعها PASS ضمن الـ229 أعلاه) يُثبِت ثابتًا ساكنًا وثابتًا سلوكيًا معًا: (أ) فحص نصّي على كود `src/features/settlements/schema.ts` (بعد إزالة التعليقات) يتأكد أنه **لا يوجد أي استدعاء `parseFloat(`/`parseInt(` في الملف بأكمله**؛ (ب) يتأكد ألا يوجد أي `.transform(...)` يمرِّر القيمة عبر `Number(...)` قبل إرجاعها (أي استخدام لِ`Number(` في الملف محصور حصرًا داخل دوال `.refine(` للتحقق فقط — مقارنة بوليانية لا تُغيِّر القيمة المُرجَعة أبدًا). أُعيد التحقق يدويًا عبر `grep` مباشر في هذه الجولة: الاستخدامان الوحيدان لِ`Number(` في `schema.ts` كلاهما داخل `.refine(...)` (سطر 158: حد أقصى 100%؛ سطر 171: رفض قيمة صفرية) — لا يوجد `.transform` يحوّل عبر Number في أي مكان. **العقد الحقيقي مُثبَت، لا شكلي فقط.**

---

## 8) اختبارات أمان الترقية (§34) — الأربعة كاملة

| البند | الوصف | السكربت | النتيجة (تشغيل نظيف الآن) |
|---|---|---|---|
| A | تركيب نظيف 0001→الأحدث (0191) + seed.sql | إعادة بناء `gold_erp_test` (§0 أعلاه) | **نجاح تام، بلا خطأ تطبيق واحد** |
| B | 0166→الأحدث مع Phase 7 (0167–0191 معًا فوق بيانات ما قبل Phase 7) | `scripts/run_upgrade_test_phase7_settlements.sh` (قاعدته الأصلية، ممتدة الآن لِـPatch 7.1 عبر تضمين 0184–0191 ضمن حلقة "migrations 0001→latest" ذاتها) | **`ALL UPGRADE-TO-PHASE-7 TESTS PASSED`، Exit 0** |
| C | 0183→الأحدث فوق بيانات Phase 7 حقيقية موجودة فعلًا (مسودة/معتمَدة/مطابَقة/مُلغاة، حركات بنكية، عكوس، مطالبات، إصدارات رسوم) | `scripts/run_upgrade_test_phase7_1_settlements.sh` (جديد كليًا) | **`ALL UPGRADE-TO-PHASE-7.1 TESTS PASSED`، إثبات تطابق byte-identical لكل صف قديم + قراءة صحيحة عبر get/list الجديدتين لبيانات الشكل القديم (بما فيها نوع `return_refund` القديم المحتفَظ به تاريخيًا)، Exit 0** |
| D | فِكستشر ما قبل Phase 7 مُوسَّعة (بيع/حدث استرداد فعلي/عكسه/تعديل/عكس تعديل/دورة حياة COD كاملة) → الأحدث | `supabase/tests/fixtures/phase7_upgrade_pre_fixture.sql` + `upgrade_phase7_settlements.test.sql` (موسَّعان) عبر نفس سكربت البند B | **نفس نتيجة البند B أعلاه (ملف واحد يغطي B وD معًا)، Exit 0** |

كل الأربعة أُعيد تشغيلها بشكل مستقل ونظيف (قاعدة بيانات جديدة تمامًا لكل تشغيل) في الساعة الأخيرة من هذه الجلسة تحديدًا لتأكيد الحالة النهائية.

---

## 9) إثبات عدم المساس بترحيلات 0001–0183 (byte-for-byte)

```
$ diff -rq /tmp/prior_zip_extract/supabase/migrations/ supabase/migrations/
Only in supabase/migrations/: 0184_settlement_source_adapter_patch_7_1.sql
Only in supabase/migrations/: 0185_settlement_fee_resolver_and_finalize_patch_7_1.sql
Only in supabase/migrations/: 0186_settlement_batch_privacy_and_draft_getter_patch_7_1.sql
Only in supabase/migrations/: 0187_audit_logs_settlements_permission_split_patch_7_1.sql
Only in supabase/migrations/: 0188_settlement_bank_movement_and_cancel_daily_close_patch_7_1.sql
Only in supabase/migrations/: 0189_settlement_draft_rpcs_patch_7_1.sql
Only in supabase/migrations/: 0190_settlement_route_fee_version_and_manage_routes_patch_7_1.sql
Only in supabase/migrations/: 0191_settlement_batch_list_filters_and_effective_semantics_patch_7_1.sql
```

المرجع: `gold-erp-phase7-settlements.zip` (التسليم السابق)، SHA-256 `87cfe25502973d4c163e3766759924539227fa9a1dfad3dbe5c09559d086ef43`، مؤكَّد مطابقًا للأرشيف على القرص عبر `sha256sum` قبل المقارنة. **لا فرق واحد — ولو بايت — على أي من 0001–0183. الفرق الوحيد هو وجود 8 ملفات جديدة (0184–0191).**

---

## 10) إثبات استعادة `.env.example` (§36)

```
$ diff /tmp/phase6_baseline_extract/.env.example .env.example
(no output — identical)
$ md5sum .env.example  →  503293b4e55c4755e3737faa00bd5dd0   (كلا النسختين)
```

**الخلاصة: الملف لم يُفقَد فعليًا من المستودع في أي لحظة** — كان حاضرًا وصحيحًا طوال الوقت، مطابقًا حرفيًا (682 بايت، نفس MD5) لأساس Phase 6 (`gold-erp-hotfix-6-1-2.zip`). ما حدث في التسليم السابق كان إغفالًا في خطوة تحزيم الـZIP نفسها فقط، لا فقدانًا حقيقيًا للملف. هذا التسليم يتضمَّن الملف في الـZIP فعليًا (مؤكَّد في §12 من هذا الملف).

---

## 11) فحوصات ثابتة نهائية — أُعيد تشغيلها جميعًا نظيفة في الساعة الأخيرة من الجلسة

| الفحص | الأمر | النتيجة |
|---|---|---|
| TypeScript | `npm run typecheck` | **نظيف تمامًا، Exit 0** |
| ESLint | `npm run lint` | **0 أخطاء، 4 تحذيرات سابقة الوجود غير متعلقة بـSettlements** (`tests/adjustments-entry-form-zero-charge-state-machine.test.tsx`، متغيرات `_input` غير مستخدَمة — خارج نطاق Patch 7.1، لم تُمسّ) |
| أعمدة NUMERIC | `npm run check:numeric-types` (مقابل `gold_erp_test`، 0001–0191) | **`OK: all 89 raw NUMERIC column(s) ... correctly typed`، Exit 0** |
| بناء إنتاجي | `npm run build` | **`✓ Compiled successfully in 36.3s`، بلا أي خطأ، جميع مسارات `/settlements`، `/settlements/[id]`، `/settlements/new`، `/master-data/settlement-routes` مبنية بنجاح** |
| اختبارات ترقية قديمة (5 سكربتات، بلا صلة مباشرة بـPatch 7.1 لكن يجب ألا تنكسر) | `run_upgrade_test.sh`، `run_upgrade_test_hotfix_4_2_1.sh`، `run_upgrade_test_patch_4_2.sh`، `run_upgrade_test_patch_6_1.sh`، `run_upgrade_test_phase6_adjustments.sh` | **الخمسة PASSED، Exit 0 لكل واحد، شُغِّلت بالتوازي على قواعد منفصلة، ثم أُزيلت القواعد المؤقتة** |

---

## 12) ملخص نهائي

**كل رقم في هذا الملف من تشغيل فعلي حقيقي أُعيد تنفيذه في الساعات الأخيرة من هذه الجلسة تحديدًا** (لا نقل عن تشغيل وكيل فرعي سابق دون تحقق مستقل): 8 ترحيلات جديدة (0184–0191) + عيبان حرجان وُجدا وأُصلِحا فعليًا في 0188 (موثَّقان بالكامل) + 67/67 PASS اختبار SQL + تزامن حقيقي A–K (11 سيناريو، 12 إشعار PASS) + 252 تأكيد HTTP حقيقي (66 جديد لِSettlements تحديدًا) + 229/229 Vitest (24 ملفًا) + حارس float نقدي مُثبَت سلوكيًا لا شكليًا فقط + 4/4 اختبارات أمان ترقية (A/B/C/D) + 89/89 عمود NUMERIC + TypeScript/ESLint/بناء إنتاجي نظيفة بالكامل + 5/5 اختبارات ترقية قديمة بلا انحدار + إثبات byte-for-byte كامل لعدم المساس بـ0001–0183 + إثبات أن `.env.example` لم يُفقَد فعليًا قط. **لم تبدأ Phase 8. العمل متوقف الآن نهائيًا بانتظار المراجعة.**
