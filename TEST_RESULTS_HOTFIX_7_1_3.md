# TEST_RESULTS_HOTFIX_7_1_3.md

## Phase 7 — Final Pending-Refresh Consistency Hotfix 7.1.3 (Settlements/Returns — Keep Collection Channel Snapshot in Lockstep with the Return Financial Basis)

هذا الملف يوثِّق نتائج الاختبار الفعلية الكاملة لِـHotfix 7.1.3 — مراجعة داخل نطاق 0197–0198 نفسيهما (غير مُعتمَدتين بعد، بمراجعة المستخدم المباشرة على مستوى الكود/الـdiff قبل هذه الجولة) — مُنفَّذة داخل هذه الجلسة على قواعد بيانات حقيقية، بأرقام حقيقية من تشغيل فعلي مباشر. كل رقم في هذا الملف من تشغيل أُعيد تنفيذه نظيفًا في هذه الجلسة تحديدًا.

---

## 0) لماذا عُدِّلت 0197/0198 مباشرة — بدل إنشاء 0199 (§0/§19-5)

قاعدة التجميد المرجعية تبقى **0001–0196**؛ لا تعديل عليها إطلاقًا (مؤكَّد بايت-لبايت، §9 أدناه). لكن 0197–0198 **لم تُعتمَد بعد** من المستخدم، والخلل المُكتشَف يقع **داخل عقد 0197 نفسه**: تصميمه الأصلي افترض أن `sales_returns.payment_method_id` Snapshot دائم منذ الإنشاء — وهذا **خطأ**؛ الدالة السلطوية القائمة مسبقًا `refresh_pending_sales_return_from_sale()` (0100، مُجمَّدة ضمن 0001–0196) تُعيد مزامنة هذا العمود تحديدًا مع حالة البيع الحالية عند استدعائها على مرتجَع معلَّق. أي ترحيلة لاحقة افتراضية (0199) لن تُصلِح شيئًا — الخلل يمنع ترقية إنتاجية حقيقية من إتمام **0197 نفسها** بأمان قبل أن تصل لأي 0199. لذلك، وبتفويض صريح من المستخدم ("لا تنشئ 0199 فقط لتغطية Upgrade Blocker يقع أثناء 0197. عدّل 0197/0198 نفسها بالقدر المطلوب فقط")، عُدِّلت 0197/0198 **في مكانهما** — بالقدر الأدنى اللازم فقط، بلا أي مساس بترحيلة واحدة من 0001–0196.

---

## 1) الترحيلتان المُعدَّلتان في مكانهما (0197–0198) — جدول كامل

| # | الترحيلة | التغيير |
|---|---|---|
| 0197 | `sales_returns_collection_channel_snapshot_hotfix_7_1_2.sql` | **Part A/B (العمود + `BEFORE INSERT`):** بلا تغيير — لا تزال صحيحة تمامًا؛ الالتقاط عند الإنشاء سليم أصلًا. **Part C (Backfill):** أُعيدت كتابته بالكامل — بدل خوارزمية "أول تعديل بعد `created_at`"، يُعاد البناء الآن عبر مطابقة `audit_logs.new_values.row_version` مع `sales_returns.source_sale_row_version` **الخاص بالمرتجَع نفسه** بالضبط (المصدران المُعتمَدان: `sale.create`/`sale.update`)، مع سقوط آمن صريح (§8) عند تطابق حالة البيع الحالية فقط، وفشل صريح للترحيلة بأكملها عند عدم وجود أي دليل (§7). **Part D:** بلا تغيير. **Part E (المُشغِّل):** أُعيد كتابته بالكامل — بدل الرفض غير المشروط لأي تعديل، يتعرَّف الآن على انتقال Pending Refresh السليم (`status` يبقى `pending`، `source_sale_row_version` يتغيَّر) عبر شكل الصف الدقيق الذي تُنتِجه `refresh_pending_sales_return_from_sale()` (0100) حصرًا، ويُعيد اشتقاق العمود سلطويًا من حالة البيع الحالية المقفولة (لا يثق بقيمة العميل)، ويرفض أي محاولة أخرى بلا استثناء — حتى `service_role`. |
| 0198 | `settlement_source_adapter_hotfix_7_1_2.sql` | **منطق SQL بلا أي تغيير** — المطابقة عبر عمودَي Snapshot الخاصَّين بـ`sales_returns` نفسها كانت صحيحة أصلًا وتبقى كذلك تحت الدلالة المُصحَّحة. التعليقات فقط أُصلِحت (كانت تصف "تجميد دائم منذ الإنشاء" — أصبحت تصف "يتحرَّك معًا حتى نهاية دورة الانتظار، ثم يتجمَّد معًا للأبد"). |

**لا استثناء على 0001–0196:** لم تُعدَّل أي ترحيلة منها إطلاقًا (§9). **لا 0199 أُنشِئت** — بتفويض المستخدم الصريح، عُدِّل العقد غير المُعتمَد نفسه بدل تغطية عيبه بترحيلة إضافية.

---

## 2) الخلل المُصلَح وسبب خطورته

`collection_channel_id_snapshot` (0197 الأصلي) افترض أنه Snapshot دائم منذ الإنشاء — تمامًا كالمعنى الخاطئ الذي أُزيل عن `payment_method_id` سابقًا (Hotfix 7.1.2). لكن `refresh_pending_sales_return_from_sale()` (0100، دالة سلطوية قائمة منذ ما قبل هذا الهوتفكس بكثير) تُعيد مزامنة `payment_method_id` مع حالة البيع الحالية على أي مرتجَع معلَّق يُستدعى عليها — فينشأ زوج (طريقة دفع، قناة) **مستحيل تاريخيًا**: `payment_method_id` مُحدَّث (=B) بينما `collection_channel_id_snapshot` لا يزال مُجمَّدًا على قيمته الأصلية (=A). الإصلاح: منح العمودين **نفس** دلالة "الأساس الحالي الذي يعتمد عليه المرتجَع" — يتحرَّكان معًا دومًا، ويتجمَّدان معًا فقط عند خروج المرتجَع نهائيًا من دورة الانتظار (اعتماد/رفض/عكس).

---

## 3) اختبار SQL جديد كليًا — `supabase/tests/settlements_hotfix_7_1_3.test.sql`

أربعة أقسام حية، تشغيل نظيف نجح من المحاولة الأولى بعد إصلاح واحد فقط في الفِكستشر نفسه (تحديد `id` الصنف الموجود عند `update_sales_order()` لتفادي حذف الصنف الذي يشير إليه المرتجَع — نمط قائم موثَّق في `sales_returns_core.test.sql`):

- **(A) سيناريو Pending Refresh A–G (§9):** بيع V1 أ/أ → مرتجَع معلَّق (يلتقط أ/1) → تعديل البيع إلى V2 ب/ب أثناء التعليق → `approve_sales_return()` **يُرفَض** (حارس `source_sale_row_version` القائم في 0109) → `refresh_pending_sales_return_from_sale()` يُعيد المزامنة → **كلا** العمودين أصبحا ب معًا (`payment_method_id`/`collection_channel_id_snapshot`/`source_sale_row_version=2`) → الاعتماد ينجح الآن → الاكتشاف على المسار ب حصرًا.
- **(B) ثبات ما بعد الاعتماد (§10):** عكس المرتجَع → تعديل البيع مجددًا إلى ج/ج (مسموح بعد العكس) → **كلا** حدثي عكس الرسم (الأصلي + العكسي) يبقيان على المسار ب — لا ينجرفان إلى ج/ج، رغم أن هذا المرتجَع مرَّ بتحديث Pending Refresh واحد سابقًا في حياته.
- **(C) اختبار تعدد التحديث (§13):** مرتجَع يُحدَّث مرتين قبل الاعتماد (أ/أ → ب/ب (تحديث) → ج/ج (تحديث ثانٍ)) → العمودان معًا = ج بعد آخر تحديث → الاعتماد → الاكتشاف على المسار ج حصرًا (لا أ، لا ب).
- **(D) اختبار التعديل المباشر الموثوق (§5/§10)، مُعاد تحقُّقه تحت المُشغِّل الجديد:** محاولة تزوير شكل انتقال Pending Refresh (تغيير `source_sale_row_version` دون مطابقة حالة البيع الحقيقية) تُرفَض حتى لِ`service_role`؛ محاولة تعديل مباشر على مرتجَع خرج من دورة الانتظار (مُعتمَد) تُرفَض أيضًا؛ فحص عكسي يؤكِّد أن عمودًا آخر لا يُرفَض (نطاق المُشغِّل محصور).

```
$ psql -d gold_erp_h713_dev -f supabase/tests/settlements_hotfix_7_1_3.test.sql
...
NOTICE:  === ALL settlements_hotfix_7_1_3.test.sql ASSERTIONS PASSED (§5/§9/§10/§13 live regression coverage) ===
ROLLBACK
Exit code: 0
```

**النتيجة: 15/15 تأكيد `PASS`، صفر سطر `ERROR:`، Exit 0.**

---

## 4) اختبار SQL القائم — بلا تعديل، صفر انحدار

`settlements_hotfix_7_1_2.test.sql` (الملف المُسلَّم سابقًا لهذا الهوتفكس بالذات، **بلا تعديل حرف واحد**) أُعيد تشغيله مباشرة ضد الترحيلتين **المُصحَّحتين**، ليؤكِّد أن التصحيح لم يُضعِف أيًّا من إثباتاته القائمة (سيناريو A–G، التعديل المباشر الموثوق، إلخ):

```
$ psql -d gold_erp_h713_dev -f supabase/tests/settlements_hotfix_7_1_2.test.sql
...
NOTICE:  === ALL settlements_hotfix_7_1_2.test.sql ASSERTIONS PASSED (§1-§3/§7/§9-§12 live regression coverage) ===
Exit code: 0
```

**8/8 تأكيد PASS كما كانت، صفر انحدار.**

بقية حزمة SQL القائمة (كل ملف على قاعدة بيانات نظيفة مستقلة، مطابقةً لاتفاقية تشغيل كل ملف على حِدة المُتَّبعة في هذا المشروع):

| الملف | النتيجة |
|---|---|
| `settlements_phase7.test.sql` | Exit 0, 0 ERROR (68 تأكيد PASS) |
| `settlements_hotfix_7_1_1.test.sql` | Exit 0, 0 ERROR |
| `settlements_phase7_concurrency.test.sql` (تزامن حقيقي) | Exit 0, 0 ERROR |
| `rls_and_permissions.test.sql` | Exit 0, 0 ERROR (139 تأكيد OK) |
| `sales_core.test.sql` | Exit 0, 0 ERROR |
| `sales_returns_core.test.sql` | Exit 0, 0 ERROR |
| `sales_returns_concurrency.test.sql` (تزامن حقيقي) | Exit 0, 0 ERROR |
| `sales_returns_hotfix_4_2_1.test.sql` | Exit 0, 0 ERROR |
| `adjustments_core_phase6.test.sql` / `_concurrency` | Exit 0, 0 ERROR لكليهما |
| `sales_integrity_*` (كل الملفات، بما فيها التزامن) | Exit 0, 0 ERROR للجميع |
| `financial_integrity_*` (كل الملفات) | Exit 0, 0 ERROR للجميع |
| `shipping_*` (كل الملفات، بما فيها التزامن) | Exit 0, 0 ERROR للجميع |

**26 ملف اختبار SQL ذاتي الاكتفاء (`begin;`/`rollback;`) + 5 ملفات تزامن حقيقي (autocommit، عبر جلسات psql متوازية) — 31/31، صفر ERROR، صفر انحدار على أي وحدة.**

ملاحظة منهجية: أول محاولة شغَّلت كل ملفات SQL بالتسلسل ضمن قاعدة بيانات واحدة مشتركة، فأظهرت هذا فشلًا كاذبًا في `rls_and_permissions.test.sql`/`settlements_phase7.test.sql` (عدد متاجر "نشطة" أعلى من المتوقَّع) — سببه بيانات مُلتزَمة فعليًا (COMMIT لا ROLLBACK) خلَّفتها ملفات التزامن الخمسة عند تشغيلها ضمن نفس القاعدة المشتركة، لا أي انحدار في 0197/0198. أُعيد تشغيل الملفين على قاعدة بيانات نظيفة مستقلة فكانا PASS تامًّا فورًا — النتيجة أعلاه هي التشغيل الصحيح المُعتمَد.

---

## 5) اختبارا أمان الترقية الجديدان بالكامل (§11/§13/§14) — الأهم لهذا الهوتفكس

### 5.1 السيناريو الإيجابي المُدمَج (§11 + §12 + §13 معًا في ترقية واحدة حقيقية)

فِكستشران جديدان يُبنيان معًا — تحت العقود **القديمة** (0001–0196، **قبل** وجود التصحيح) — في **نفس** قاعدة البيانات:

- **§12 (الفِكستشر القائم، بلا تعديل):** `hotfix_7_1_2_upgrade_pre_fixture.sql` — بيع أ/أ → مرتجَع كامل → اعتماد → عكس → تعديل البيع إلى ب/ب.
- **§11 (سيناريو 1، جديد كليًا):** بيع V1 أ/أ → مرتجَع معلَّق → بيع V2 ب/ب → **`refresh_pending_sales_return_from_sale()` سلطويًا قبل وجود 0197 أصلًا** → المرتجَع يبقى معلَّقًا عند الالتزام — يُثبِت أن `payment_method_id` كان بالفعل =ب **قبل** أي تعديل على 0197 مطلقًا، لأن الدالة المُجمَّدة 0100 هي من غيَّرته.
- **§13 (سيناريو 2، جديد كليًا):** نفس الفكرة لكن بتحديثين متتاليين (V1 أ/أ → V2 ب/ب (تحديث) → V3 ج/ج (تحديث ثانٍ))، المرتجَع يبقى معلَّقًا.

ثم تُطبَّق 0197–0198 **المُصحَّحتان** فوق البيانات الثلاث المُلتزَمة معًا (COMMIT، لا ROLLBACK)، ويُثبِت `upgrade_hotfix_7_1_2_settlements.test.sql` (القائم، بلا تعديل) + `upgrade_hotfix_7_1_3_settlements.test.sql` (جديد):

1. **§12 لا تزال PASS تامَّة** ضد الترحيلتين المُصحَّحتين — `collection_channel_id_snapshot` لا يزال يُعاد بناؤه = قناة أ (من `sale.create`، `row_version=1`)، والاكتشاف لا يزال على المسار أ حصرًا.
2. **§11 (سيناريو 1):** `collection_channel_id_snapshot` المُعاد بناؤه بعد الترقية = قناة **ب** (من `sale.update`، `row_version=2` — **مطابِق تمامًا** لـ`source_sale_row_version` الخاص بهذا المرتجَع) — **وليس** قناة أ (التي كانت الخوارزمية القديمة الخاطئة ستستخدمها خطأً). `payment_method_id` (كان بالفعل ب قبل الترقية) بقي سليمًا كمرساة. الترحيلة لم تُفشِل — إثبات ضمني أن فحص التكامل الجديد نجح.
3. **§13 (سيناريو 2):** `collection_channel_id_snapshot` = قناة **ج** (من `sale.update`، `row_version=3`) — يُثبِت أن المطابقة مربوطة فعليًا بـ`source_sale_row_version` **الخاص بكل صف على حِدة**، لا موقعًا ثابتًا ("أول تحديث" أو "ثاني حدث").
4. **دورة حياة حقيقية بعد الترقية:** كلا المرتجَعين (السيناريو 1 والسيناريو 2) اعتُمِدا فعليًا **بعد** الترقية عبر `approve_sales_return()` الحقيقية — نجحا فورًا لأن أساسهما المُسجَّل (`source_sale_row_version`) كان يطابق أصلًا `row_version` الحالي للبيع (لم يُعدَّل البيع بعد الترقية) — تمامًا كما يختبره مشغِّل حقيقي يستأنف مرتجَعًا معلَّقًا بعد الترقية.
5. **الاكتشاف على البيانات الحقيقية بعد الاعتماد:** سيناريو 1 → المسار ب حصرًا؛ سيناريو 2 → المسار ج حصرًا؛ المسار أ لا يظهر لأي منهما.

```
$ DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:5432/gold_erp_hotfix713_upgrade_e_test" \
    ./scripts/run_upgrade_test_hotfix_7_1_3_settlements.sh
...
NOTICE:  === ALL upgrade_hotfix_7_1_2_settlements.test.sql ASSERTIONS PASSED ===
NOTICE:  === ALL upgrade_hotfix_7_1_3_settlements.test.sql ASSERTIONS PASSED ===
==> Hotfix 7.1.3 upgrade test (item E, §11/§12/§13 combined) PASSED
Exit code: 0
```

**نجاح تام من المحاولة الأولى — صفر خطأ.**

### 5.2 مسار الفشل الصريح المتعمَّد (§14 — البند الأهم للتحقق من الأمان)

فِكستشر **مكسور عمدًا**: يُبنى مرتجَع مُحدَّث مرة واحدة (أساس `source_sale_row_version=2`) تحت 0001–0196، ثم — كإجراء تخريب متعمَّد بعد الالتزام — يُحذَف صف `audit_logs` الوحيد الذي يُثبِت هذا الأساس بالضبط (`sale.update` بـ`row_version=2`)، ويُعدَّل البيع مرة أخرى إلى نسخة ثالثة (V3) بحيث لا ينطبق السقوط الآمن (§8) أيضًا (`sales_orders.row_version` الحالي = 3 ≠ 2). النتيجة المتوقَّعة: **0197 يجب أن تفشل صراحةً** بدل تخمين قناة خاطئة أو الرجوع للخوارزمية القديمة.

```
$ DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:5432/gold_erp_hotfix713_upgrade_broken_test" \
    ./scripts/run_upgrade_test_hotfix_7_1_3_broken_fixture.sh
...
ERROR:  Hotfix 7.1.2/7.1.3 backfill integrity check FAILED for 1 return(s) — ...
==> Migration 0197 correctly FAILED (expected).
==> Confirmed: no partial state — collection_channel_id_snapshot does not exist, 0197's failed transaction rolled back completely.
==> Hotfix 7.1.3 explicit-FAIL-path test (§14) PASSED
Exit code: 0
```

**النتيجة: الترحيلة 0197 فشلت صراحة كما هو متوقَّع تمامًا، برسالة تُسمِّي المرتجَع/البيع المتضرِّر بدقة، ودون أي حالة جزئية متروكة (تأكَّد أن العمود الجديد غير موجود بعد الفشل — المعاملة الصريحة `begin;`/`commit;` أعادت كل شيء بالكامل).** هذا يُثبِت أن الخوارزمية **لا تخمِّن أبدًا** ولا تسقط للخوارزمية القديمة الخاطئة ("أول تعديل بعد الإنشاء") عند فقدان الدليل.

### 5.3 بقية اختبارات أمان الترقية (A/B/C/D) — بلا انحدار

| البند | الوصف | السكربت | النتيجة |
|---|---|---|---|
| A | تركيب نظيف 0001→الأحدث + seed.sql | إعادة بناء `gold_erp_h713_sweep`/`gold_erp_h713_dev` | **نجاح تام** |
| B | 0166→الأحدث | `scripts/run_upgrade_test_phase7_settlements.sh` (بلا تعديل) | **`Phase 7 upgrade test PASSED`، Exit 0** |
| C | 0183→الأحدث | `scripts/run_upgrade_test_phase7_1_settlements.sh` (بلا تعديل) | **`Phase 7.1 upgrade test (item C) PASSED`، Exit 0** |
| D | 0191→الأحدث | `scripts/run_upgrade_test_hotfix_7_1_1_settlements.sh` (بلا تعديل) | **`Hotfix 7.1.1 upgrade test (item D) PASSED`، Exit 0** |
| E | 0196→الأحدث (§5.1 أعلاه، مُدمَج) | `scripts/run_upgrade_test_hotfix_7_1_3_settlements.sh` (جديد) | **PASSED، Exit 0** |
| §14 | مسار الفشل الصريح المتعمَّد (§5.2 أعلاه) | `scripts/run_upgrade_test_hotfix_7_1_3_broken_fixture.sh` (جديد) | **PASSED (فشل 0197 كما هو متوقَّع)، Exit 0** |

بالإضافة إلى 5 سكربتات ترقية أقدم غير متعلقة مباشرة بهذا الهوتفكس (`run_upgrade_test.sh`، `run_upgrade_test_hotfix_4_2_1.sh`، `run_upgrade_test_patch_4_2.sh`، `run_upgrade_test_patch_6_1.sh`، `run_upgrade_test_phase6_adjustments.sh`)، أُعيد تشغيلها بشكل مستقل ونظيف (قاعدة بيانات جديدة تمامًا لكل تشغيل، بالتوازي) في هذه الجلسة: **جميعها PASSED، Exit 0**.

**إجمالي سكربتات أمان الترقية: 12/12 PASSED، Exit 0 لكل واحد.**

---

## 6) HTTP/PostgREST حقيقي — `scripts/postgrest-http-test.mjs` (مُوسَّع، Part 17 جديد)

قسم "Part 17" جديد كليًا (بنود A–I) فوق "Part 16" القائم، يثبت حيًّا عبر PostgREST حقيقي (ثنائي فعلي، JWTs موقَّعة حقيقية) دورة حياة Pending Refresh الكاملة:

إنشاء مرتجَع على بيع أ/أ → تعديل البيع إلى ب/ب أثناء التعليق → `refresh_pending_sales_return_from_sale()` عبر HTTP فعلي → الاعتماد ينجح → الاكتشاف على المسار ب حصرًا → عكس → تعديل البيع مجددًا إلى ج/ج → الاكتشاف: المسار ب لا يزال يُظهر الحدثين معًا، المسار ج لا يُظهر شيئًا → تأكيد أن `PATCH` خام على `collection_channel_id_snapshot` لا يزال مرفوضًا حتى عبر `service_role`، حتى على مرتجَع مرَّ بتحديث Pending Refresh سابقًا.

فاعل/طريقة دفع/قناة تحصيل ثالثة ("C") جديدة أُضيفت لِ`postgrest_http_test_setup.sql` خصيصًا لهذا البند (الخطوة G/H تحتاج مسارًا ثالثًا مستقلًا لإثبات الثبات التاريخي).

```
$ ADMIN_DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:5432/postgres" ./scripts/run_postgrest_http_test.sh
...
=== ALL REAL HTTP/POSTGREST INTEGRATION TEST ASSERTIONS PASSED ===
Exit code: 0
```

**النتيجة: 299 تأكيد `OK` عبر الملف بأكمله (بلا انحدار عن أي قسم سابق، بما فيها Part 1–16) — 10 تأكيدات جديدة ضمن "Part 17".**

---

## 7) React/Vitest — لا تغيير مطلوب

لا سلوك جديد يواجه الواجهة الأمامية في هذا الهوتفكس (لا عمود جديد، لا نوع TypeScript جديد — `collection_channel_id_snapshot` موجود أصلًا منذ 7.1.2):

```
$ npm run test
 Test Files  25 passed (25)
      Tests  265 passed (265)
```

**265/265 — صفر انحدار، صفر تغيير مطلوب.**

`npm run typecheck` → **نظيف تمامًا، Exit 0** (لا تعديل مطلوب على `src/types/database.ts` — لا عمود جديد في هذا الهوتفكس).
`npm run lint` → **0 أخطاء** (4 تحذيرات سابقة الوجود غير متعلقة، لم تُمَس).

حارس عدم استخدام Float للأموال (`tests/settlements-money-string-invariant.test.ts`) يبقى ساريًا بلا تعديل ضمن تشغيل Vitest أعلاه — لا عمود مالي جديد في هذا الهوتفكس.

---

## 8) فحوصات ثابتة نهائية

| الفحص | الأمر | النتيجة |
|---|---|---|
| TypeScript | `npm run typecheck` | **نظيف تمامًا، Exit 0** |
| ESLint | `npm run lint` | **0 أخطاء، 4 تحذيرات سابقة الوجود غير متعلقة** |
| أعمدة NUMERIC | `npm run check:numeric-types` (مقابل قاعدة 0001–0198 المُصحَّحة، مبنية من الصفر) | **`OK: all 89 raw NUMERIC column(s) ... correctly typed`، Exit 0** (بلا تغيير — لا عمود NUMERIC جديد) |
| بناء إنتاجي | `npm run build` | **`✓ Compiled successfully`، بلا أي خطأ، كل المسارات مبنية بنجاح** |

---

## 9) إثبات عدم المساس بترحيلات 0001–0196 (byte-for-byte، حقيقي هذه المرة)

```
$ sha256sum /home/claude/deliverables/gold-erp-hotfix-7-1-2-settlements.zip
19c50ca3ee525229c9235113f1b4def9def889e44c5a2cc51d6ac8e2593f272c  ← مطابق تمامًا لِSHA-256 المُسلَّم/الذي تحقَّق منه المستخدم مستقلًا

$ unzip -q gold-erp-hotfix-7-1-2-settlements.zip -d /tmp/h712_extract
$ for f in supabase/migrations/0001..0196: cmp "$f" against extracted archive
TOTAL_CHECKED=196  DIFFERING=0
```

**0/196 ملف يختلف — ولو بايت واحد.** الفروقات الوحيدة عبر كامل الشجرة (عبر `diff -rq` كامل، باستثناء `node_modules`/`.git`/`.next`/`.env*`/`package-lock.json`):

- `supabase/migrations/0197_...sql` و`0198_...sql` — **يختلفان (متوقَّع تمامًا)**، هما التعديل المُفوَّض صراحةً هذه الجولة.
- `scripts/postgrest-http-test.mjs`، `supabase/tests/postgrest_http_test_setup.sql` — يختلفان (Part 17 الجديد).
- 6 ملفات جديدة بالكامل (§11 أدناه).
- **لا ملف آخر يختلف. لا ملف حُذِف. لا `0199` أو أي ترحيلة جديدة أُنشئت.**

`.env.example`: مطابق حرفيًا (نفس MD5، `503293b4e55c4755e3737faa00bd5dd0`).

---

## 10) اختبار السقوط الآمن العكسي — لا تراجع للخوارزمية القديمة الخاطئة إطلاقًا

الفحص §5.2 أعلاه (مسار الفشل الصريح) هو الإثبات الحاسم أن الخوارزمية الجديدة **لا** تسقط أبدًا إلى "أول تعديل بعد `created_at`" (الخوارزمية القديمة الخاطئة) عند عدم توفر دليل موثوق — بل تفشل الترحيلة **بأكملها** صراحةً وتُسمِّي الصف المتضرِّر، تاركة قرار المعالجة اليدوية للمشغِّل البشري بدل تخمين تاريخ مالي.

---

## 11) الملفات الجديدة/المُعدَّلة/المحذوفة — مقارنة كاملة مقابل `gold-erp-hotfix-7-1-2-settlements.zip`

**محذوفة: لا شيء إطلاقًا (0 ملف).**

**جديدة بالكامل (7 ملفات):** `supabase/tests/settlements_hotfix_7_1_3.test.sql`؛ `supabase/tests/fixtures/hotfix_7_1_3_upgrade_pre_fixture.sql`؛ `supabase/tests/fixtures/hotfix_7_1_3_upgrade_broken_fixture.sql`؛ `supabase/tests/upgrade_hotfix_7_1_3_settlements.test.sql`؛ `scripts/run_upgrade_test_hotfix_7_1_3_settlements.sh`؛ `scripts/run_upgrade_test_hotfix_7_1_3_broken_fixture.sh`؛ هذا الملف (`TEST_RESULTS_HOTFIX_7_1_3.md`).

**مُعدَّلة في مكانها (4 ملفات):** `supabase/migrations/0197_sales_returns_collection_channel_snapshot_hotfix_7_1_2.sql` (Backfill + مُشغِّل UPDATE أُعيد تصميمهما بالكامل، §1 أعلاه)؛ `supabase/migrations/0198_settlement_source_adapter_hotfix_7_1_2.sql` (تعليقات فقط، لا منطق SQL)؛ `scripts/postgrest-http-test.mjs` (قسم "Part 17" جديد)؛ `supabase/tests/postgrest_http_test_setup.sql` (طريقة دفع + قناة تحصيل نشطتان إضافيتان لِRoute C)؛ `DELIVERY_REPORT.md` (ملحق جديد).

**لم يتغيَّر إطلاقًا:** أي ترحيلة من 0001–0196 (مؤكَّد byte-for-byte، §9 أعلاه)، `supabase/seed.sql`، `.env.example`، `src/types/database.ts`، `supabase/tests/settlements_hotfix_7_1_2.test.sql` (بلا تعديل حرف واحد)، أي ملف Vitest، أي وحدة خارج Settlements/Returns، ولا حُذِف أو أُضعِف أي اختبار قائم في أي مكان.

---

## 12) تأكيد عدم بدء Phase 8

لم يبدأ أي عمل يخص Phase 8 أو أي مرحلة/وحدة تتجاوز نطاق Settlements/Returns وتصحيحاتها إطلاقًا في هذه الجلسة. كل تغيير في هذا التسليم مقصور حصرًا على: (أ) تعديل داخل عقد 0197/0198 نفسيهما (غير مُعتمَدتين بعد، بتفويض صريح، §0 أعلاه)، (ب) اختبارات/سكربتات تحقُّق لنفس الوحدة فقط. لا `0199` أو أي ترحيلة جديدة. لا Reports/Dashboard نهائي، لا PDF/Excel، لا Inventory، لا Salla، لا Carrier/Bank APIs، لا Attachments/Backups/2FA، ولا أي مرحلة جديدة.

---

## 13) ملخص نهائي

**كل رقم في هذا الملف من تشغيل فعلي حقيقي أُعيد تنفيذه في هذه الجلسة تحديدًا:** تعديل مُفوَّض صراحة داخل 0197/0198 غير المُعتمَدتين (بلا 0199، بلا مساس بـ0001–0196 المؤكَّد بايت-لبايت ضد الأرشيف الفعلي المُسلَّم سابقًا) + 15/15 PASS اختبار SQL جديد كليًا + 8/8 PASS إعادة تشغيل اختبار 7.1.2 القائم بلا تعديل + 31/31 ملف SQL قائم بلا انحدار (26 ذاتي الاكتفاء + 5 تزامن حقيقي) + 299 تأكيد HTTP حقيقي (10 جديدة ضمن Part 17) + 265/265 Vitest (صفر تغيير مطلوب) + **12/12 سكربت أمان ترقية PASSED** (شامل §11 refreshed-pending وَ§13 multi-refresh مُدمَجَين حقيقيًا مع §12 القائم في ترقية واحدة، **زائد** إثبات §14 الحاسم: فشل صريح موثَّق ونظيف عند تلف دليل التاريخ، بلا أي تخمين وبلا تراجع للخوارزمية القديمة) + 89/89 عمود NUMERIC + TypeScript/ESLint/بناء إنتاجي نظيفة بالكامل. صفر ملفات محذوفة، 7 جديدة، 4 مُعدَّلة (اثنتان منها 0197/0198 أنفسهما، مُفوَّض التعديل صراحة). **لم تبدأ Phase 8. العمل متوقف الآن نهائيًا بانتظار المراجعة.**
