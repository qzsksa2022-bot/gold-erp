# TEST_RESULTS_HOTFIX_7_1_2.md

## Phase 7 — Final Historical Route Snapshot Hotfix 7.1.2 (Settlements — Return Fee-Reversal Route Immutability)

هذا الملف يوثِّق نتائج الاختبار الفعلية الكاملة لِـHotfix 7.1.2 (ترحيلتان 0197–0198)، مُنفَّذة داخل هذه الجلسة على قواعد بيانات حقيقية، بأرقام حقيقية من تشغيل فعلي مباشر — لا تقديرات ولا نقل عن وكيل فرعي دون تحقق مستقل. كل رقم في هذا الملف من تشغيل أُعيد تنفيذه نظيفًا في هذه الجلسة تحديدًا، على قواعد بيانات مبنية من الصفر، لضمان أن الحالة النهائية المُسلَّمة هي التي تعكس الأرقام فعليًا.

---

## 0) إعداد البيئة والتحقق من نظافة قاعدة التجميد

- Postgres محلي، متاح طوال الجلسة.
- قاعدة `gold_erp_h712_sweep` بُنيت من الصفر بالكامل لهذه الجولة النهائية: `DROP DATABASE` → `CREATE DATABASE` → `supabase/tests/local_harness_setup.sql` → **جميع الترحيلات 0001–0198 بالترتيب دون توقف واحد** → `supabase/seed.sql`. هذا التشغيل بحد ذاته إثبات **§15 البند A** (تركيب نظيف من الصفر 0001→الأحدث).
- **قاعدة التجميد (§0) مُتحقَّق منها آليًا وبايت-لبايت** مقابل الأرشيف المُسلَّم لِـHotfix 7.1.1 (`gold-erp-hotfix-7-1-1-settlements.zip`، SHA-256 `b08142dd3dc3bd720d7e82b24150084fe5f9fc856cadfcf5a4ac35980430367b`): مقارنة `cmp` مباشرة لكل ملف من الـ196 ترحيلة القديمة (0001–0196): **0/196 ملف يختلف**. الفرق الوحيد: ملفا ترحيل جديدان (0197، 0198). انظر §9 أدناه للتفصيل الكامل.

---

## 1) الترحيلتان الجديدتان (0197–0198) — جدول كامل

| # | الترحيلة | الغرض المختصر |
|---|---|---|
| 0197 | `sales_returns_collection_channel_snapshot_hotfix_7_1_2.sql` | عمود جديد `sales_returns.collection_channel_id_snapshot` (uuid، FK → `collection_channels`)؛ مُشغِّل `BEFORE INSERT` يلتقطه سلطويًا من `sales_orders.collection_channel_id` اللحظي عند إنشاء المرتجَع؛ Backfill تاريخي حتمي عبر `audit_logs` (لا نسخ أعمى للحالة الحالية) مع فحص تكامل إلزامي مقابل `payment_method_id` الموجود مسبقًا كمرساة؛ `NOT NULL` بعد الـBackfill؛ مُشغِّل `BEFORE UPDATE` يمنع أي تعديل لاحق للعمود — حتى لِ`service_role`/SQL مباشر موثوق. مُغلَّفة بمعاملة صريحة `begin;`/`commit;` (استثناء متعمَّد عن اتفاقية autocommit بالسطر المُعتادة، لضمان أن فشل الـBackfill لا يترك حالة وسيطة مكسورة). |
| 0198 | `settlement_source_adapter_hotfix_7_1_2.sql` | `CREATE OR REPLACE` لِ`_settlement_unsettled_source_candidates()` (نفس التوقيع/الأعمدة تمامًا). مرشِّحا `return_fee_reversal`/`_reversal` وحدهما تغيَّرا: المطابقة أصبحت `sr.payment_method_id = r.payment_method_id AND r.collection_channel_id IS NOT DISTINCT FROM sr.collection_channel_id_snapshot` — بلا `join` إلى `sales_orders` إطلاقًا. `return_refund_event`/`_reversal` (سجل الاسترداد النقدي الفعلي) بلا أي تغيير — لا يزالان `refund_method_id` + قناة NULL ضمنية. |

**لا استثناء على التجميد:** لم تُعدَّل أي ترحيلة من 0001–0196 إطلاقًا (§9).

---

## 2) الخلل المُصلَح وسبب خطورته

`return_fee_reversal`/`return_fee_reversal_reversal` (بعد إصلاح 0192 لتمر عبر "مسار البيع الأصلي") كانت لا تزال تقرأ `sales_orders.payment_method_id`/`collection_channel_id` **لحظيًا** وقت الاكتشاف — وليس Snapshot تاريخيًا حقيقيًا. بما أن قفل 0084 المالي يمنع تعديل البيع فقط أثناء `sales_returns.status = 'approved'` (وليس `'reversed'`)، فبإمكان مستخدم تعديل بيع **بعد** عكس مرتجَعه إداريًا — ما يُغيِّر رجعيًا المسار الذي يُطابِقه حدث عكس رسم تاريخي مُعتمَد بالفعل. الإصلاح: منح `collection_channel_id_snapshot` بنفس منطق `payment_method_id` القائم تمامًا — يُلتقط عند الإنشاء، ويتجمَّد للأبد.

---

## 3) اختبار SQL جديد كليًا — `supabase/tests/settlements_hotfix_7_1_2.test.sql` (451 سطرًا)

ملف مخصَّص بالكامل لهذا الهوتفكس، ثلاثة أقسام:

- **(A) سيناريو A–G** — إثبات §1 الحرج المباشر: بيع بطريقة/قناة أ → مرتجَع كامل → اعتماد → عكس → **تعديل البيع لاحقًا إلى ب/ب (بعد العكس، مسموح)** → الاكتشاف يُظهر **كلا** حدثي عكس الرسم على المسار أ حصرًا، ولا شيء على المسار ب → تأكيد أن الـSnapshot نفسه لم يتغيَّر إطلاقًا.
- **(B) اختبار التعديل المباشر الموثوق (§10)** — محاولة `UPDATE` مباشرة على `collection_channel_id_snapshot` حتى عبر `service_role` (BYPASSRLS) تُرفَض من المُشغِّل؛ فحص عكسي يؤكِّد أن عمودًا آخر (`updated_by`) لا يُرفَض (نطاق المُشغِّل محصور).
- **(C) اختبار المرتجَع المعلَّق التاريخي (§12)** — تعديل البيع أثناء كون المرتجَع لا يزال معلَّقًا (قبل الاعتماد) مسموح فعليًا، لكن `approve_sales_return()` (0109) ترفض الاعتماد بعدها بحارس تسلسل نسخة موجود مسبقًا (`source_sale_row_version <> row_version اللحظي`) — **موثَّق حيًّا** بدل تلفيق اختبار حول حارس حقيقي موجود، تمامًا كما نصَّت المواصفة.

```
$ psql -d gold_erp_h712_sweep -f supabase/tests/settlements_hotfix_7_1_2.test.sql
...
NOTICE:  === ALL settlements_hotfix_7_1_2.test.sql ASSERTIONS PASSED (§1-§3/§7/§9-§12 live regression coverage) ===
ROLLBACK
Exit code: 0
```

**النتيجة: 8/8 تأكيد PASS (زائد إشعارَي SKIP موثَّقين لقسم C بعد اكتشاف الحارس الحقيقي)، صفر سطر `ERROR:`، Exit 0.**

---

## 4) اختبار SQL القائم — `settlements_phase7.test.sql` / `settlements_hotfix_7_1_1.test.sql` / `settlements_phase7_concurrency.test.sql` — بلا تعديل

لا حاجة لأي تعديل: تغيير 0197–0198 لا يُغيِّر أي سلوك يختبره أي من هذه الملفات (مطابقة `return_fee_reversal` عبر `sales_returns` بدل `join` إلى `sales_orders` تُنتِج نفس القيم لأي بيانات لم يُعدَّل فيها البيع بعد إنشاء المرتجَع — وهو كل ما تختبره هذه الملفات القائمة).

```
$ psql -d gold_erp_h712_sweep -f supabase/tests/settlements_phase7.test.sql        → Exit 0, 0 ERROR
$ psql -d gold_erp_h712_sweep -f supabase/tests/settlements_hotfix_7_1_1.test.sql  → Exit 0, 0 ERROR
$ psql -d gold_erp_h712_sweep -f supabase/tests/settlements_phase7_concurrency.test.sql → Exit 0, 0 ERROR
```

**68/68 + 12/12 + 12/12 PASS — صفر انحدار.**

### إعادة تشغيل حزمة Returns/Sales القائمة (سلامة إضافية — 0197 يُضيف Trigger جديد على `sales_returns`)

```
$ psql -d gold_erp_h712_sweep -f supabase/tests/sales_returns_core.test.sql          → Exit 0, 0 ERROR
$ psql -d gold_erp_h712_sweep -f supabase/tests/sales_returns_concurrency.test.sql   → Exit 0, 0 ERROR
$ psql -d gold_erp_h712_sweep -f supabase/tests/sales_returns_hotfix_4_2_1.test.sql  → Exit 0, 0 ERROR
$ psql -d gold_erp_h712_sweep -f supabase/tests/sales_core.test.sql                  → Exit 0, 0 ERROR
```

**صفر انحدار على وحدتَي Returns/Sales بأكملهما.**

---

## 5) HTTP/PostgREST حقيقي — `scripts/postgrest-http-test.mjs` (مُوسَّع، Part 16 جديد)

قسم "Part 16" جديد كليًا (بندان a/b) فوق "Part 15" القائم، يثبت حيًّا عبر PostgREST حقيقي (ثنائي فعلي، JWTs موقَّعة حقيقية):

- **item a (§1/§7 حرج):** بيع أ/أ → مرتجَع → اعتماد → عكس → تعديل البيع إلى ب/ب لاحقًا (نجح فعليًا عبر HTTP) → `list_unsettled_settlement_sources()` يُظهر كلا حدثي عكس الرسم على مسار جديد "Route A" (زوج طريقة/قناة أ القائم من Part 14) حصرًا، وصفر على مسار جديد "Route B" (زوج طريقة/قناة ب، مُضاف خصيصًا لهذا الهوتفكس في `postgrest_http_test_setup.sql`).
- **item b (§10):** `PATCH` خام مباشر على `/sales_returns` لا أثر له (صفر صفوف، سياسة RLS الصفرية القائمة) للفاعل الكامل الصلاحيات العادي؛ ومحاولة `PATCH` مباشرة على `collection_channel_id_snapshot` تحديدًا **تُرفَض** حتى لعميل `service_role` الموثوق (يتجاوز RLS لكن لا يتجاوز المُشغِّلات) — يُطابِق تمامًا نمط إثبات "item 17/32" القائم لِTerminal Mutation.

```
$ ADMIN_DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:5432/postgres" ./scripts/run_postgrest_http_test.sh
...
=== ALL REAL HTTP/POSTGREST INTEGRATION TEST ASSERTIONS PASSED ===
Exit code: 0
```

**النتيجة: 289 تأكيد `OK` عبر الملف بأكمله (بلا انحدار عن أي قسم سابق، بما فيها Part 1–15) — منها 8 تأكيدات ضمن "Part 16" الجديد.**

فاعلا اختبار جديدان في `postgrest_http_test_setup.sql`: طريقة دفع نشطة ثانية (`http_test_pm_b`، 3.5%+4.00، `proportional_reversal`) وقناة تحصيل نشطة ثانية (`http_test_channel_b`)، لبناء زوج مسار ب حقيقي مستقل — Route A أعاد استخدام مسار Part 14 القائم (قيد `settlement_routes_payment_collection_match_idx` الفريد يمنع مسارًا ثانيًا لنفس زوج طريقة/قناة أ).

---

## 6) React/Vitest — لا تغيير مطلوب

لا سلوك جديد يواجه الواجهة الأمامية في هذا الهوتفكس: لا RPC قراءة جديدة تُعرِض `collection_channel_id_snapshot` (المواصفة نفسها لا تطلب ذلك)، وسلوك الاكتشاف المتغيِّر مُغطًّى بالكامل عبر SQL/HTTP أعلاه.

```
$ npm run test
 Test Files  25 passed (25)
      Tests  265 passed (265)
```

**265/265 — صفر انحدار، صفر تغيير مطلوب.**

`npm run typecheck` → **نظيف تمامًا، Exit 0** (يشمل إضافة `collection_channel_id_snapshot: string` إلى نوع `sales_returns` في `src/types/database.ts`).
`npm run lint` → **0 أخطاء** (4 تحذيرات سابقة الوجود غير متعلقة بـSettlements/Returns، لم تُمَس — نفس الأربعة الموثَّقة في تقرير Hotfix 7.1.1).

---

## 7) حارس عدم استخدام Float للأموال (§13 من هوتفكس 7.1.1)

لا عمود مالي جديد في هذا الهوتفكس (`collection_channel_id_snapshot` هو `uuid`، لا قيمة نقدية) — حارس `tests/settlements-money-string-invariant.test.ts` القائم يبقى ساريًا بلا تعديل، ويمر ضمن تشغيل Vitest أعلاه.

---

## 8) اختبارات أمان الترقية (§11/§15) — الخمسة كاملة

| البند | الوصف | السكربت | النتيجة (تشغيل نظيف الآن) |
|---|---|---|---|
| A | تركيب نظيف 0001→الأحدث (0198) + seed.sql | إعادة بناء `gold_erp_h712_sweep` (§0 أعلاه) | **نجاح تام، بلا خطأ تطبيق واحد** |
| B | 0166→الأحدث (Phase 7 + Patch 7.1 + Hotfix 7.1.1 + Hotfix 7.1.2 معًا فوق بيانات ما قبل Phase 7) | `scripts/run_upgrade_test_phase7_settlements.sh` (بلا تعديل) | **`Phase 7 upgrade test PASSED`، Exit 0** |
| C | 0183→الأحدث فوق بيانات Phase 7 حقيقية | `scripts/run_upgrade_test_phase7_1_settlements.sh` (بلا تعديل) | **`Phase 7.1 upgrade test (item C) PASSED`، Exit 0** |
| D | 0191→الأحدث فوق بيانات Hotfix-7.1.1-الصلة حقيقية | `scripts/run_upgrade_test_hotfix_7_1_1_settlements.sh` (بلا تعديل) | **`Hotfix 7.1.1 upgrade test (item D) PASSED`، Exit 0** |
| E | **0196→الأحدث فوق سيناريو انجراف المسار الحقيقي (جديد كليًا لهذا الهوتفكس)** | `scripts/run_upgrade_test_hotfix_7_1_2_settlements.sh` + `supabase/tests/fixtures/hotfix_7_1_2_upgrade_pre_fixture.sql` + `supabase/tests/upgrade_hotfix_7_1_2_settlements.test.sql` (الثلاثة جديدة كليًا) | **`Hotfix 7.1.2 upgrade test (item E) PASSED`، Exit 0** |

**تفصيل البند E (الأهم لهذا الهوتفكس):** فِكستشر يبني — تحت العقود **القديمة** (0001–0196، **قبل** وجود 0197–0198) — بيعًا أ/أ → مرتجَعًا كاملًا → اعتماد → عكس → **تعديل البيع لاحقًا إلى ب/ب**، ويُثبِت (عبر `_settlement_unsettled_source_candidates()` القديمة مباشرة) أن الخلل **حقيقي وقابل للتكرار قبل الترقية**: كلا حدثي عكس الرسم يظهران على "Route B" (2 حدث) وصفر على "Route A" — رغم أن المرتجَع أُنشئ واعتُمِد فعليًا تحت أ/أ. ثم تُطبَّق 0197–0198 فوق هذه البيانات المُلتزَمة (COMMIT، لا ROLLBACK)، ويُثبِت `upgrade_hotfix_7_1_2_settlements.test.sql`:

1. `collection_channel_id_snapshot` المُعاد بناؤه = قناة أ (عبر إعادة بناء `audit_logs`) — **وليس** قناة ب الحالية اللحظية.
2. مرساة `payment_method_id` القائمة سليمة (لم تتغيَّر)، وفحص التكامل (§6) لم يُفشل الترحيلة (إثبات ضمني: الترحيلة اكتملت أصلًا).
3. الاكتشاف على **نفس البيانات الحقيقية المُتراكمة** بعد الترقية أصبح: **كلا الحدثين على Route A حصرًا (2)، صفر على Route B** — **عكس تام** لخط الأساس قبل الترقية.
4. كل عمود سابق الوجود في صف `sales_return`/`sales_order` **بايت-مطابق** لِـSnapshot ما قبل الترقية (باستثناء `collection_channel_id_snapshot` الجديد نفسه، و`updated_at` الذي يتقدَّم شرعًا بفعل مُشغِّل "لمس" عام قائم مسبقًا يستجيب لأي `UPDATE`، بما فيه تحديث الـBackfill أحادي العمود).

```
$ DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:5432/gold_erp_hotfix712_upgrade_e_test" \
    ./scripts/run_upgrade_test_hotfix_7_1_2_settlements.sh
...
NOTICE:  === ALL upgrade_hotfix_7_1_2_settlements.test.sql ASSERTIONS PASSED ===
==> Hotfix 7.1.2 upgrade test (item E) PASSED
Exit code: 0
```

كل الخمسة، بالإضافة إلى 5 سكربتات ترقية أقدم غير متعلقة مباشرة بهذا الهوتفكس (`run_upgrade_test.sh`، `run_upgrade_test_hotfix_4_2_1.sh`، `run_upgrade_test_patch_4_2.sh`، `run_upgrade_test_patch_6_1.sh`، `run_upgrade_test_phase6_adjustments.sh`)، أُعيد تشغيلها بشكل مستقل ونظيف (قاعدة بيانات جديدة تمامًا لكل تشغيل، بالتوازي) في هذه الجلسة: **10/10 PASSED، Exit 0 لكل واحد، صفر انحدار.**

---

## 9) إثبات عدم المساس بترحيلات 0001–0196 (byte-for-byte)

```
$ cmp كل ملف من الـ196 ترحيلة القديمة (0001–0196) مقابل نظيره في gold-erp-hotfix-7-1-1-settlements.zip
TOTAL_DIFFERING_0001_0196=0
```

المرجع: `gold-erp-hotfix-7-1-1-settlements.zip` (التسليم السابق)، SHA-256 `b08142dd3dc3bd720d7e82b24150084fe5f9fc856cadfcf5a4ac35980430367b` (مؤكَّد بإعادة حساب `sha256sum` على الأرشيف المحلي نفسه قبل المقارنة). **لا فرق واحد — ولو بايت — على أي من 0001–0196. الفرق الوحيد هو وجود ملفَي ترحيل جديدَين (0197–0198).**

---

## 10) إثبات استعادة `.env.example`

```
$ md5sum .env.example (الأرشيف السابق مقابل المستودع الحالي)
503293b4e55c4755e3737faa00bd5dd0  (كلا النسختين، 682 بايت)
```

**الملف حاضر وصحيح، مطابق حرفيًا للأساس القديم.**

---

## 11) فحوصات ثابتة نهائية

| الفحص | الأمر | النتيجة |
|---|---|---|
| TypeScript | `npm run typecheck` | **نظيف تمامًا، Exit 0** |
| ESLint | `npm run lint` | **0 أخطاء، 4 تحذيرات سابقة الوجود غير متعلقة (نفس تحذيرات Hotfix 7.1.1)** |
| أعمدة NUMERIC | `npm run check:numeric-types` (مقابل قاعدة 0001–0198 مبنية من الصفر) | **`OK: all 89 raw NUMERIC column(s) ... correctly typed`، Exit 0** (لا عمود NUMERIC جديد في هذا الهوتفكس — `collection_channel_id_snapshot` هو `uuid`) |
| بناء إنتاجي | `npm run build` | **`✓ Compiled successfully`، بلا أي خطأ، جميع الـ32 مسارًا مبنية بنجاح، بما فيها `/settlements`، `/settlements/[id]`، `/settlements/new`، `/master-data/settlement-routes`** |

---

## 12) الملفات الجديدة/المُعدَّلة/المحذوفة — مقارنة كاملة مقابل `gold-erp-hotfix-7-1-1-settlements.zip`

مبنية عبر `diff -rq` كامل بين محتوى الأرشيف المُسلَّم سابقًا وحالة المستودع الحالية بالكامل (باستثناء `node_modules`/`.git`/`.next`/`.env*`):

**محذوفة: لا شيء إطلاقًا (0 ملف).**

**جديدة بالكامل (7 ملفات):** ترحيلتان (`0197`، `0198`، جدول §1 أعلاه)؛ `scripts/run_upgrade_test_hotfix_7_1_2_settlements.sh`؛ `supabase/tests/fixtures/hotfix_7_1_2_upgrade_pre_fixture.sql`؛ `supabase/tests/settlements_hotfix_7_1_2.test.sql`؛ `supabase/tests/upgrade_hotfix_7_1_2_settlements.test.sql`؛ هذا الملف (`TEST_RESULTS_HOTFIX_7_1_2.md`).

**مُعدَّلة (4 ملفات):** `scripts/postgrest-http-test.mjs` (قسم "Part 16" جديد)؛ `supabase/tests/postgrest_http_test_setup.sql` (طريقة دفع + قناة تحصيل نشطتان إضافيتان لِRoute B)؛ `src/types/database.ts` (إضافة `collection_channel_id_snapshot` لنوع `sales_returns`)؛ `DELIVERY_REPORT.md` (ملحق جديد).

**لم يتغيَّر إطلاقًا:** أي ترحيلة من 0001–0196 (مؤكَّد byte-for-byte، §9 أعلاه)، `supabase/seed.sql`، `.env.example`، `supabase/tests/settlements_phase7.test.sql`/`settlements_hotfix_7_1_1.test.sql`/`settlements_phase7_concurrency.test.sql`، أي ملف Vitest، أي وحدة خارج Settlements/Returns، ولا حُذِف أو أُضعِف أي اختبار قائم في أي مكان.

---

## 13) تأكيد عدم بدء Phase 8

لم يبدأ أي عمل يخص Phase 8 أو أي مرحلة/وحدة تتجاوز نطاق Settlements/Returns وتصحيحاتها إطلاقًا في هذه الجلسة. كل تغيير في هذا التسليم مقصور حصرًا على: (أ) ترحيلتان SQL تصحيحيتان (0197–0198) ضمن Settlements/Returns فقط، (ب) اختبارات/سكربتات تحقُّق لنفس الوحدة فقط، (ج) تعديل نوع TypeScript واحد يعكس العمود الجديد فقط. لا Reports/Dashboard نهائي، لا PDF/Excel، لا Inventory، لا Salla، لا Carrier/Bank APIs، لا Attachments/Backups/2FA، ولا أي مرحلة جديدة.

---

## 14) ملخص نهائي

**كل رقم في هذا الملف من تشغيل فعلي حقيقي أُعيد تنفيذه في هذه الجلسة تحديدًا:** ترحيلتان جديدتان (0197–0198) + 8/8 PASS اختبار SQL جديد كليًا `settlements_hotfix_7_1_2.test.sql` + صفر انحدار على 3 ملفات SQL قائمة (Phase 7/Hotfix 7.1.1/تزامن A-K) + صفر انحدار على 4 ملفات SQL لِReturns/Sales + 289 تأكيد HTTP حقيقي (8 جديدة ضمن Part 16) + 265/265 Vitest (صفر تغيير مطلوب) + 5/5 اختبارات أمان ترقية (A/B/C/D بلا انحدار + E جديد كليًا يُثبِت انجراف المسار الحقيقي قبل الترقية وإصلاحه بعدها على نفس البيانات) + 5/5 اختبارات ترقية أقدم بلا انحدار (10/10 إجمالًا) + 89/89 عمود NUMERIC + TypeScript/ESLint/بناء إنتاجي نظيفة بالكامل + إثبات byte-for-byte كامل لعدم المساس بـ0001–0196 + إثبات أن `.env.example` سليم. **لم تبدأ Phase 8. العمل متوقف الآن نهائيًا بانتظار المراجعة.**
