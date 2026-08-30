# نتائج الاختبار الفعلية — Sales Integrity Patch 3.2

كل الأرقام أدناه من تشغيل فعلي أخير ضد قاعدة بيانات مبنية من الصفر (`local_harness_setup.sql` + الترحيلات 0001–0080 بالترتيب + `supabase/seed.sql`)، بتاريخ هذه الجلسة. لا رقم افتراضي أو منسوخ من تشغيل سابق — كل تشغيلة أُعيدت فعليًا عند كتابة هذا الملف.

## 1) بناء قاعدة البيانات من الصفر

- `local_harness_setup.sql` → نجح.
- الترحيلات 0001–0080 بالترتيب دون توقف → **80/80 نجحت** (الثمانية الجديدة: 0073–0080).
- `supabase/seed.sql` → نجح.

## 2) اختبار الترقية (Foundation → latest، بلا إعادة تشغيل seed.sql)

`scripts/run_upgrade_test.sh` (يُطبِّق 0001–0039 + بيانات Foundation فقط، ثم 0040–latest تلقائيًا عبر glob دون seed.sql الحقيقي):

```
==> Upgrade test PASSED
=== ALL UPGRADE-FROM-0039 TESTS PASSED (0040-latest, including Phase 3 0058-0064, applied WITHOUT re-running seed.sql) ===
```

## 3) اختبارات SQL — كل الملفات، أرقام فعلية من هذا التشغيل (تشغيل واحد متسلسل على نفس قاعدة البيانات)

| الملف | النتيجة |
|---|---|
| `rls_and_permissions.test.sql` | 139/139 ✅ |
| `financial_master_data.test.sql` | 52/52 ✅ |
| `financial_integrity_patch_2_1.test.sql` | 34/34 ✅ |
| `financial_integrity_patch_2_2.test.sql` | 17/17 ✅ |
| `financial_integrity_hotfix_2_2_1.test.sql` | 14/14 ✅ |
| `financial_integrity_hotfix_2_2_2.test.sql` | 11/11 ✅ |
| `sales_core.test.sql` | 57/57 ✅ (مُحدَّث هذا الإصدار: 3 نقاط استدعاء لـ`update_sales_order()` أضافت `p_expected_version`) |
| `sales_integrity_patch_3_1.test.sql` (Part 1، أحادي الجلسة) | 14/14 ✅ (مُحدَّث: 9 نقاط استدعاء أضافت `p_expected_version`؛ كل الإصلاحات الأصلية للبنود 1–13 من Patch 3.1 ما زالت تُختبر دون تغيير في المنطق) |
| `sales_integrity_patch_3_1_concurrency.test.sql` (Part 2، تزامن حقيقي عبر `dblink`) | H1 / H2 / **I(1)+I(2) مُعاد كتابتها** / J / **J2 جديد** / K + تنظيف — 8/8 نقطة تحقق ✅، مُتحقَّق عبر تشغيلة كاملة بلا أثر متبقٍّ |
| `sales_integrity_patch_3_2.test.sql` (**جديد بالكامل**) | 15/15 نقطة تحقق (Sections C/D/E/F/G/H/I) ✅ |

### تفصيل القسم الحرِج — تصحيح Lost Update (Section I، `sales_integrity_patch_3_1_concurrency.test.sql`)

هذا القسم كان في Patch 3.1 يُثبت (خطأً، بأثر رجعي) أن الكاتب B "الخاسر بالتوقيت" يفوز بصمت. أُعيدت كتابته بالكامل في هذا الإصدار ليطابق البند 2 من المواصفة فعليًا:

- **I(1)** — تعديل B الثاني (بإصدار `row_version` قديم) ينتظر قفل الصف فعليًا حتى التزام A، ثم **يُرفض بتعارض إصدار صريح** (`تم تعديل عملية البيع بواسطة مستخدم آخر. حدّث الصفحة وراجع التغييرات قبل الحفظ.`) بدل الكتابة فوق تعديل A بصمت.
- **I(2)** — بعد الرفض، يعيد B تحميل `row_version` الحالي (2) ويعيد تقديم نفس التعديل، فينجح ويصبح `row_version = 3`. لا فقدان صامت لأي تعديل في أي مرحلة.

### القسم الجديد — J2 (قفل الكتابة المباشرة على `daily_gold_prices`، البند 1)

`UPDATE public.daily_gold_prices SET price_per_gram = ... WHERE ...` **مباشرة (بلا المرور عبر `save_daily_gold_price()`)** من اتصال منفصل يُثبَت أنه ينتظر فعليًا حتى التزام `create_sales_order()` متعددة البنود من اتصال آخر — كلا البندين ينتهيان بنفس السعر القديم المتسق، مما يُثبت أن `daily_gold_prices_financial_lock_trigger` (0073) يغلق ثغرة الكتابة المباشرة على مستوى العبارة (`BEFORE STATEMENT`)، لا فقط مسار الـRPC كما كان الحال في Patch 3.1.

## 4) اختبار HTTP/PostgREST الحقيقي

`scripts/run_postgrest_http_test.sh` — ثنائي PostgREST v12.2.3 حقيقي، اتصال HTTP فعلي، 3 مستخدمين موقَّعين بـJWT حقيقي (فاعل كامل الصلاحيات، فاعل بلا `sales.view_profit`، فاعل `service_role` للتحقق فقط):

```
=== ALL REAL HTTP/POSTGREST INTEGRATION TEST ASSERTIONS PASSED ===
```

37/37 تأكيد ناجح (كل التأكيدات القائمة من الأجزاء السابقة + 6 جديدة لـPatch 3.2):

- `row_version` يزداد بمقدار 1 بالضبط بعد تعديل ناجح فعليًا عبر HTTP.
- إعادة تقديم `p_expected_version` قديم تُرفض بتعارض صريح (`/مستخدم آخر/`)، ولا تُغيّر البيانات.
- `get_sales_order()` عبر HTTP يُرجع `store_name`/`payment_method_name`/`collection_channel_name` محلولة داخليًا (البند 8).
- `list_sales_orders()` عبر HTTP يُرجع نفس الحقول الثلاثة محلولة داخليًا (البند 8).

## 5) فحوصات مستوى الشيفرة

| الفحص | النتيجة |
|---|---|
| `npx tsc --noEmit` | صفر أخطاء ✅ |
| `npx eslint .` | صفر أخطاء/تحذيرات ✅ |
| `npx vitest run` | 45/45 عبر 5 ملفات ✅ |
| `npm run check:numeric-types` | 23/23 عمود NUMERIC خام مطابق ✅ — `sales_orders.row_version` (BIGINT) و`sales_order_items.calculation_version` (INTEGER) خارج نطاق هذا الفحص عمدًا لأنهما ليسا NUMERIC، لا يحملان أي قيمة مالية، ولا حاجة لتمريرهما عبر RPC آمن |
| `npm run build` (Next.js/Turbopack) | نجح، 25 مسارًا، تضمّن `/sales`, `/sales/new`, `/sales/[id]`, `/sales/[id]/edit` ✅ |

## 6) القيود الصارمة — تحقق نهائي

- **لا تعديل واحد** على أي ترحيل من 0001 إلى 0072 — الترحيلات الجديدة كلها 0073–0080 (8 ترحيلات، مُرقَّمة بالتتابع دون فجوات).
- **لا بدء** لـReturns أو Shipping أو Settlements أو Inventory أو أي مرحلة جديدة — تم التحقق يدويًا من عدم وجود أي كود/جدول/RPC لأي منها في هذا التسليم.
- **كل إصلاحات 0065–0072 (Patch 3.1) محفوظة سليمة** — `sales_integrity_patch_3_1.test.sql`/`sales_integrity_patch_3_1_concurrency.test.sql` يعيدان اختبارها بالكامل ضمن هذا التشغيل نفسه ويمرّان 100%.
- **لا خفض Coverage ولا تغيير توقّع اختبار فقط لتمريره** — كل إصلاح اختباري (البند 11، الفقرات A–I) وُثِّق بالسبب الجذري الذي كان يُخفي المشكلة (RLS صامتة، توقيع دالة متغيّر، صلاحية `stores.disable` مفقودة من فاعل الاختبار، إلخ) في `DELIVERY_REPORT.md` الملحق 14، لا مجرد تعديل رقم متوقَّع.
- كل بند من الأربعة عشر (1–14) له اختبار فعلي مطابق مذكور بالاسم أعلاه أو في الملحق الرابع عشر من `DELIVERY_REPORT.md`.
