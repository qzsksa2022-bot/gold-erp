# TEST_RESULTS_HOTFIX_6_1_2.md

## Phase 6 — Final Audit & Invariant Hotfix 6.1.2 / Services / Adjustments — Last Closure Patch

هذا الملف يوثِّق نتائج الاختبار الفعلية لِـ**Hotfix 6.1.2**، المبنية على مراجعة مستخدم مستقلة أكَّدت صحة الـArtifact السابق (`gold-erp-hotfix-6-1-1.zip`، SHA-256 `36bb8407dabbd5dbffea7e54b71cb30da3bc32aea48416a6aa4323fd39d4a007` — تحقَّق منه مستقلًا وأُعيد التحقق منه في بداية هذه الجلسة، **مطابق تمامًا**)، وحدَّدت 3 فجوات مصدرية BLOCKER + فجوة اختبارية صغيرة قبل إغلاق Phase 6 نهائيًا.

**قاعدة التجميد هذه الجولة (صارمة، بلا استثناءات):** لا تعديل على أي ترحيلة 0001–0162. كل إصلاح ترحيلة جديدة بدءًا من **0163**.

---

## 0) إعداد البيئة

- خادم Postgres محلي — وُجد متوقفًا (`pg_lsclusters` → `down`) في بداية الجلسة، أُعيد تشغيله عبر `rm -f /var/run/postgresql/16-main.pid && service postgresql start`، تأكَّد التشغيل عبر `pg_isready`.
- `sha256sum gold-erp-hotfix-6-1-1.zip` → `36bb8407dabbd5dbffea7e54b71cb30da3bc32aea48416a6aa4323fd39d4a007` — **مطابق تمامًا** لِما تحقَّق منه المستخدم مستقلًا.

---

## 1) الترحيلات الجديدة (0163–0166) — ملخص وتحقُّق تطبيق

| # | الترحيلة | يُصلِح |
|---|---|---|
| 0163 | `adjustments_calculation_version_strict_invariant.sql` | يستبدل قيد `sales_order_adjustments_calculation_version_consistent` بالعقد الحرفي الدقيق: `(status='approved' AND calculation_version=1) OR (status<>'approved' AND calculation_version IS NULL)` — لا قيمة أخرى مقبولة لسجل معتمَد حتى/إلا بترحيلة مستقبلية صريحة لمحرك حساب v2. |
| 0164 | `adjustment_types_updated_by_anti_forgery.sql` | يستبدل جسم `adjustment_types_enforce_updated_columns()` (نفس اسم الدالة، فتلتقط المحفِّز القائم من 0162 السلوك الجديد تلقائيًا): `auth.uid()` يطابق صفَّ `profiles` حقيقيًا ⇐ `updated_by` = الفاعل الحقيقي؛ غير ذلك (auth.uid() فارغ **أو** لا يطابق أي صف profiles حقيقي — سياق موثوق/service_role/صيانة مباشرة) ⇐ `updated_by` يُثبَّت إلزاميًا على `OLD.updated_by`، بصرف النظر عمَّا زوَّده الأمر نفسه. |
| 0165 | `approve_sales_order_adjustment_v4_approval_audit_snapshot.sql` | `CREATE OR REPLACE` بنفس التوقيع والسلوك التشغيلي **الهوية طبق الأصل** لِـ0159 — التغيير الوحيد: توسيع `new_values` في نداء `adjustment.approve` ليشمل اللقطة المالية/الرئيسية الكاملة المثبَّتة فعليًا عند الاعتماد (نوع/طريقة دفع/قناة/نسخة عمولة، بجانب المبالغ الإجمالية القائمة أصلًا) — بلا أي إعادة-حل (`re-resolve`) لأي قيمة، كل قيمة هي نفس المتغيِّر المحلي المُلتزَم به في نفس الصفقة. |
| 0166 | `update_adjustment_type_audit_description.sql` | `CREATE OR REPLACE` بنفس التوقيع والسلوك التشغيلي لِـ0136's `update_adjustment_type()` — التغيير الوحيد: `description` قديم/جديد يُضافان الآن إلى حمولة تدقيق `adjustment_type.update`، جنبًا إلى جنب مع `name_ar`/`name_en`/`sort_order` القائمة أصلًا. |

**تحقُّق التطبيق:** قاعدة اختبار جديدة بالكامل، تُطبَّق عليها الترحيلات 0001–0166 بالترتيب دون توقف (166/166 نجحت)، ثم `supabase/seed.sql` بنجاح.

**فحص مباشر لجسم القيد بعد 0163:**
```
conname                                                  | pg_get_constraintdef
sales_order_adjustments_calculation_version_consistent   | CHECK (((status='approved' AND calculation_version=1) OR (status<>'approved' AND calculation_version IS NULL)))
```
مطابق حرفيًا للعقد المطلوب.

---

## 2) البند 2 (BLOCKER) — اختبار عقد `calculation_version` الصارم عند القيمة الدقيقة

ملف اختبار جديد بالكامل: `supabase/tests/adjustments_hotfix_6_1_2.test.sql` §1. الأسلوب: سجل معتمَد حقيقي (عبر RPCs السليمة فعليًا، فتكون بقية أعمدته صحيحة)، ثم — كمالك الجدول الموثوق — تعطيل محفِّز `sales_order_adjustments_reject_terminal_mutation` مؤقتًا فقط (نفس أسلوب backfill's 0158 نفسه) لعزل سلوك القيد ذاته عن أي منطق أعمال آخر.

**4 حالات مطلوبة — النتائج الفعلية:**

| الحالة | متوقَّع | النتيجة الفعلية |
|---|---|---|
| معلَّق + `calculation_version=1` | رفض | **PASS** — `check_violation` صحيح |
| معتمَد + `calculation_version=2` | رفض | **PASS** — `check_violation` صحيح، والقيمة القديمة (1) بقيت دون تغيير بعد الرفض |
| معتمَد + `calculation_version=1` | صالح | **PASS** — نجح عبر الاعتماد الحقيقي عبر RPC، **وأُعيد التأكيد** عبر UPDATE مباشر لنفس القيمة |
| مرفوض + `calculation_version` غير NULL | رفض | **PASS** — `check_violation` صحيح |

**النتيجة: 5/5 تأكيد PASS في §1 (4 حالات مطلوبة + إعادة تأكيد صريحة للحالة الثالثة).**

---

## 3) البند 3 (BLOCKER) — اختبار عدم قابلية تزوير `updated_by`

نفس الملف §2. **لا استخدام لأي Test-only profile workaround** — كل اختبار أدناه يمرّ فعليًا عبر المحفِّز الحقيقي المُصحَّح (0164)، بنفس الطريقة التي سيمر بها فعليًا استعلام `service_role`/سياق موثوق مباشر في الإنتاج.

- **(i) الحالة المطلوبة الأولى — كتابة موثوقة/مباشرة بلا فاعل مصادَقة صالح:** فاعل حقيقي A ينشئ نوع تعديل (`updated_by`=A). ثم — بلا `role authenticated` وبلا `request.jwt.claims` مضبوطة (سياق موثوق حقيقي، `auth.uid()` = NULL) — تحديث مباشر يحاول تعيين `updated_by` = فاعل B (مختلف تمامًا) صراحة. **النتيجة الفعلية: `updated_by` بقي = A، ولم يصبح B إطلاقًا.** **PASS**.
- **حالة إضافية (تعزيزية، غير مطلوبة حرفيًا لكنها تثبت الشقّ الثاني من المنطق المُصحَّح):** `auth.uid()` **غير NULL** لكنه لا يطابق أي صف `profiles` حقيقي (مثلاً جلسة مستخدم محذوف). محاولة تزوير أخرى إلى فاعل ثالث. **النتيجة الفعلية: `updated_by` بقي مثبَّتًا على الفاعل A الأصلي.** **PASS**.
- **(ii) الحالة المطلوبة الثانية — نداء RPC مُصرَّح به من فاعل حقيقي مختلف (C):** `update_adjustment_type()` تحت جلسة C الحقيقية المصادَقة. **النتيجة الفعلية: `updated_by` = C فعليًا.** **PASS**.

**إثبات مضاد (سيطرة سلبية حقيقية، ليست جزءًا من ملف الاختبار الرسمي لكنها نُفِّذت فعليًا في هذه الجلسة للتأكد أن الاختبار الجديد يكشف العطل الأصلي فعلًا):** أُعيد تركيب جسم محفِّز 0162 **القديم** (غير المُصحَّح) في قاعدة اختبار منفصلة مؤقتة، وأُعيد تنفيذ نفس محاولة التزوير (i) بالضبط — **النتيجة: التزوير نجح فعليًا** (`updated_by` أصبح الفاعل المزوَّر) تحت الجسم القديم. هذا يثبت أن اختبار §2 الجديد اختبار حقيقي يكتشف العطل الأصلي، لا اختبارًا شكليًا ينجح بصرف النظر عن التصحيح.

**النتيجة: 3/3 تأكيد PASS في §2 (حالتان مطلوبتان + حالة تعزيزية)، مُثبَتة بسيطرة سلبية حقيقية ضد الجسم القديم.**

---

## 4) البند 6 — إصلاح فِكستشر اختبار العكس + إثبات SQL حقيقي مستقل لإشارة عمولة الدفع

### 4.أ) الفِكستشر (Vitest)

`tests/adjustments-hotfix-6-1-1-list-reversal-pagination.test.tsx`: `REVERSED_ADJUSTMENT.reversal_payment_fee_impact` كانت `"-12.50"` (خطأ فِكستشر بحت — الترحيلة/RPC الفعليان كانا صحيحين دومًا وفق عقد 0150: `payment_fee_reversal_amount = +payment_fee_amount_snapshot`). صُحِّحت إلى `"12.50"` (موجبة).

أُضيف اختبار Vitest جديد بالكامل يتحقَّق صراحةً من صف "عمولة الدفع (أصلي / أثر العكس)" في بطاقة "أثر العكس المالي" — النص المُركَّب `"12.50 / 12.50"` مؤكَّد داخل البطاقة، والنص الخاطئ السابق `"12.50 / -12.50"` مؤكَّد **غيابه**. هذا الاختبار **مستقل تمامًا** عن فحوصات صافي الربح/التكلفة المباشرة القائمة أصلًا (اللذان لم يحملا هذا العطل أصلًا).

`npx vitest run tests/adjustments-hotfix-6-1-1-list-reversal-pagination.test.tsx` → **7/7 PASS** (6 قائمة + 1 جديد).

### 4.ب) إثبات SQL حقيقي (item 6's second requirement)

نفس ملف `adjustments_hotfix_6_1_2.test.sql` §3: تعديل مدفوع حقيقي (`customer_charge=100.00`، `fee%=10`، `fee_fixed=2.50` ⇒ عمولة = 12.50، مطابقة تمامًا للمثال المرجعي في مواصفة المستخدم)، اعتماد، ثم عكس. القراءة عبر `get_sales_order_adjustment()` الحقيقية:

- `original_payment_fee_amount = '12.50'` — قبل العكس **وبعده أيضًا** (لا تتغيَّر الحقيقة الأصلية إطلاقًا).
- `reversal_payment_fee_impact = '12.50'` (**موجبة**) — الإثبات المباشر لإصلاح البند 6، مستقل تمامًا عن أي فحص لصافي الربح/التكلفة المباشرة.

**النتيجة: PASS.**

---

## 5) البند 4 (BLOCKER) + البند 7 — لقطة تدقيق الاعتماد الكاملة + إثبات ثبات اللقطة القديمة بعد إعادة التسمية

نفس الملف §4. تعديل تدقيقي حقيقي (نوع/طريقة دفع/قناة مخصَّصة لهذا الاختبار) يُنشَأ ويُعتمَد، ثم يُقرَأ صف `adjustment.approve` من `audit_logs` مباشرة (كفاعل يملك `audit_logs.view` + `sales.view_profit` — بوابة القراءة القائمة من 0143/0156 دون أي تعديل).

**كل الحقول المطلوبة في `new_values` مؤكَّدة موجودة وصحيحة فعليًا (جزء 1/2):**

`adjustment_type_id`، `adjustment_type_code_snapshot`، `adjustment_type_name_ar_snapshot`، `payment_method_id`، `payment_method_name_snapshot`، `collection_channel_id`، `collection_channel_name_snapshot`، `payment_fee_version_id`، `payment_fee_percentage_snapshot` (=10.0000)، `payment_fee_fixed_snapshot` (=2.5000)، `customer_charge` (=100.00)، `direct_cost` (=20.00)، `payment_fee_amount` (=12.50)، `gross_adjustment_profit` (=80.00)، `net_adjustment_profit` (=67.50)، `calculation_version` (=1)، `row_version`، `is_free_service` (=false). **17/17 حقل مؤكَّد. PASS**.

**ثم (جزء 2/2، البند 7 الأساسي):** إعادة تسمية النوع (عبر `update_adjustment_type()` — RPC مُصرَّح به)، طريقة الدفع والقناة (عبر تحديث مباشر مُصرَّح به بموجب `payment_methods.manage`/`collection_channels.manage` — المسار السليم الوحيد لهاتين الجدولتين، إذ لا توجد لهما RPCs مخصَّصة). التأكيد: البيانات الحيّة تغيَّرت فعليًا (تحقُّق صريح)، **بينما** صف `adjustment.approve` القديم نفسه لا يزال يحمل بالضبط القيم **الأصلية قبل إعادة التسمية** — `adjustment_type_name_ar_snapshot`، `payment_method_name_snapshot`، `collection_channel_name_snapshot` كلها ثابتة دون أي مساس. **PASS**.

**النتيجة: 2/2 تأكيد PASS في §4 (اللقطة الكاملة عند الاعتماد + ثبات اللقطة القديمة بعد إعادة التسمية).**

---

## 6) البند 5 — تدقيق `update_adjustment_type()` يشمل الآن `description`

مثبَت ضمنيًا عبر §2/§4 من نفس الملف (كل نداء `update_adjustment_type()` هناك يمرّ عبر 0166 الجديدة)، ومؤكَّد إضافيًا بقراءة جسم الدالة المُطبَّقة فعليًا بعد الترحيل — `jsonb_build_object` في كلا `old_values`/`new_values` يشمل الآن `description` جنبًا إلى جنب مع `name_ar`/`name_en`/`sort_order`، بنفس القيمة المُطبَّعة (`v_description`) المستخدَمة فعليًا في UPDATE الفعلي (لا إعادة حساب منفصلة قد تنحرف).

---

## 7) ملخَّص ملف الاختبار الجديد (`adjustments_hotfix_6_1_2.test.sql`)

11 كتلة `raise notice 'PASS ...'` — **11/11 نجحت فعليًا** عند التشغيل ضد قاعدة اختبار كاملة (0001–latest + seed):

```
PASS §1 case 3/4 (approved + calculation_version=1 -> VALID)
PASS §1 case 1 (pending + calculation_version=1 -> REJECT)
PASS §1 case 2 (approved + calculation_version=2 -> REJECT)
PASS §1 case 4 (rejected + calculation_version non-null -> REJECT)
PASS §1 case 3 re-confirmed at raw UPDATE level
PASS §2(i): trusted/direct write could NOT forge updated_by
PASS bonus: auth.uid() not identifying a real profiles row is ALSO treated as no-valid-actor
PASS §2(ii): sanctioned RPC call under a real authenticated actor correctly recorded that actor
PASS §3: original_payment_fee_amount=12.50 AND reversal_payment_fee_impact=+12.50
PASS §4 (part 1/2): adjustment.approve audit entry carries the full financial/master snapshot
PASS §4 (part 2/2): OLD audit entry still holds OLD (pre-rename) snapshot values
```

---

## 8) إعادة تشغيل كامل السطح (البند 9) — نتائج فعلية

| الفحص | النتيجة |
|---|---|
| قاعدة جديدة تمامًا: 0001→latest (166 ترحيلة) + seed.sql | **PASS** |
| ترقية 0132→latest (`run_upgrade_test_phase6_adjustments.sh`) | **PASS** |
| ترقية 0143→latest بكل الفِكستشرات الستة (`run_upgrade_test_patch_6_1.sh`) | **PASS** — كل PASS(a)–(g) القائمة سابقًا ما زالت تنجح دون أي انحدار |
| 17 ملف اختبار SQL غير-ترقية/غير-تزامن (شاملًا الملف الجديد) | **17/17 PASS** |
| 4 ملفات تزامن حقيقي (`dblink`)، شاملة `adjustments_core_phase6_concurrency.test.sql` (A–I) | **4/4 PASS** |
| اختبار HTTP/PostgREST حقيقي كامل (`run_postgrest_http_test.sh`) | **PASS بالكامل — كل تأكيدات Part 1–13 القائمة سابقًا (185 تأكيدًا) نجحت دون أي انحدار** |
| `npx vitest run` | **126/126 عبر 15 ملفًا** (125 قائم + 1 جديد لِـ§4.أ أعلاه؛ لا حذف ولا إضعاف لأي اختبار قائم) |
| `npx tsc --noEmit` | **صفر أخطاء** |
| `npx eslint .` | **صفر أخطاء** (4 تحذيرات `no-unused-vars` قائمة مسبقًا في ملف لم يُلمَس هذه الجولة، غير متعلقة) |
| `DATABASE_URL=... npx tsx scripts/check-numeric-column-types.ts` | **73/73 عمود NUMERIC مطابق** |
| `npm run build` (Next.js/Turbopack) | **نجح** — نفس مسارات الصفحات القائمة، لا صفحات جديدة |

**ملاحظة على نطاق اختبار HTTP:** لم تُضَف كتلة "Part 14" منفصلة لهذه الجولة — البنود الأربعة الجديدة (`calculation_version` الصارم، مقاومة تزوير `updated_by`، لقطة تدقيق الاعتماد، إشارة عمولة العكس) جميعها منطق قيد/محفِّز/حمولة-تدقيق على مستوى القاعدة لا يختلف سلوكه باختلاف مسار الوصول (SQL مباشر مقابل HTTP) — وقد أُثبتت جميعها بشكل حاسم وكامل على مستوى SQL في §2–§5 أعلاه، بينما أعاد اختبار HTTP الكامل (185 تأكيدًا) تأكيد أن لا شيء من هذه الترحيلات الأربع الجديدة كسر أي سلوك HTTP قائم — بما في ذلك `get_sales_order_adjustment()`/`list_sales_order_adjustments()`/تدقيق `adjustment.*` نفسها، التي لا تزال تعمل بشكل صحيح.

---

## 9) إثبات: 0001–0162 لم تتغيَّر إطلاقًا (byte-for-byte)

```
$ sha256sum gold-erp-hotfix-6-1-1.zip
36bb8407dabbd5dbffea7e54b71cb30da3bc32aea48416a6aa4323fd39d4a007

$ diff -rq <استخراج الأرشيف السابق>/supabase/migrations/ gold-erp/supabase/migrations/
Only in gold-erp/supabase/migrations/: 0163_adjustments_calculation_version_strict_invariant.sql
Only in gold-erp/supabase/migrations/: 0164_adjustment_types_updated_by_anti_forgery.sql
Only in gold-erp/supabase/migrations/: 0165_approve_sales_order_adjustment_v4_approval_audit_snapshot.sql
Only in gold-erp/supabase/migrations/: 0166_update_adjustment_type_audit_description.sql
```

لا فرق آخر إطلاقًا — 0001–0162 مطابقة حرفيًا للأرشيف الذي تحقَّق منه المستخدم مستقلًا.

**فرق المستودع الكامل (باستثناء `node_modules`/`.git`/`.next`/`tsconfig.tsbuildinfo`) مقابل نفس الأرشيف:**

```
Files tests/adjustments-hotfix-6-1-1-list-reversal-pagination.test.tsx differ   (إصلاح البند 6 + اختبار جديد)
Only in gold-erp/supabase/migrations: 0163_*.sql, 0164_*.sql, 0165_*.sql, 0166_*.sql   (4 ترحيلات جديدة)
Only in gold-erp/supabase/tests: adjustments_hotfix_6_1_2.test.sql   (ملف اختبار SQL جديد)
```

لا فرق آخر في المستودع بأكمله. `DELIVERY_REPORT.md` و`TEST_RESULTS_HOTFIX_6_1_2.md` (هذا الملف) يُحدَّثان/يُضافان كجزء من التسليم، وليسا جزءًا من كود المشروع نفسه.

---

## 10) خلاصة

كل البنود الثمانية المصدرية/الاختبارية لِـHotfix 6.1.2 نُفِّذت واختُبِرت فعليًا في هذه الجلسة: تشديد عقد `calculation_version` إلى قيمة دقيقة مغلقة (0163)، تصحيح حقيقي (لا Test-only workaround) لمنع تزوير `adjustment_types.updated_by` حتى عبر كتابة موثوقة مباشرة (0164)، توسيع لقطة تدقيق الاعتماد لتشمل كامل البيانات المالية/الرئيسية المثبَّتة فعليًا (0165)، إكمال تدقيق `description` في تحديث نوع التعديل (0166)، إصلاح عطل فِكستشر اختبار (لا ترحيلة) في إشارة عمولة العكس + إثبات SQL حقيقي مستقل، واختبار تدقيق إلزامي شامل (اعتماد ← قراءة ← إعادة تسمية ← تأكيد ثبات اللقطة القديمة). **صفر انحدار** في أي طبقة (SQL/تزامن/ترقية/HTTP/Vitest/TypeScript/ESLint/NUMERIC/بناء إنتاجي). لم تُعدَّل أي ترحيلة من 0001–0162 (مؤكَّد byte-for-byte). لم تبدأ Settlements ولا أي مرحلة جديدة. لم يُحذَف ولم يُضعَف أي اختبار قائم.

العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP كامل للمشروع.

*نهاية التقرير.*
