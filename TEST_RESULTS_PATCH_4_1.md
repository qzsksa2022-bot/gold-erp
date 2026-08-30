# نتائج الاختبار الفعلية — Phase 4 Returns Integrity Patch 4.1 (ترحيلات 0092–0098)

كل الأرقام أدناه من تشغيل فعلي في هذه الجلسة ضد قاعدة بيانات مبنية من الصفر (`local_harness_setup.sql` + الترحيلات 0001–0098 بالترتيب دون توقف + `supabase/seed.sql`). لا رقم افتراضي أو منسوخ من تشغيل سابق — كل تشغيلة أُعيدت فعليًا عند كتابة هذا الملف.

## 1) بناء قاعدة البيانات من الصفر

- `local_harness_setup.sql` → نجح.
- الترحيلات 0001–0098 بالترتيب دون توقف → **98/98 نجحت** (الجديدة لهذه الرقعة: 0092–0098، سبع ترحيلات، فوق Phase 4 الأصلية 0082–0091 دون أي تعديل عليها).
- `supabase/seed.sql` → نجح.

## 2) اختبار الترقية العام (Foundation → latest، بلا إعادة تشغيل seed.sql)

`scripts/run_upgrade_test.sh` يُطبِّق 0040–0098 تلقائيًا عبر glob بلا تعديل على السكربت نفسه:

```
==> Upgrade test PASSED
=== ALL UPGRADE-FROM-0039 TESTS PASSED (0040-latest, including Phase 3 0058-0064, applied WITHOUT re-running seed.sql) ===
```

**11/11 نقطة تحقق ناجحة.** لم يتطلَّب أي تعديل توقعات جديد — Patch 4.1 لا تضيف أي صلاحية أو جدول ضمن نطاق فحص هذا الاختبار العام (الذي يتوقف عند التحقق من صلاحيات/بيانات Phase 2/Phase 3 الأساسية فقط).

## 3) إثبات سلامة الترقية المخصَّص لبيانات Returns القائمة مسبقًا (Section 20)

`scripts/run_upgrade_test.sh` لا يُغطّي بيانات Returns فعليًا (خارج نطاقه أصلًا). لذلك بُنِي إثبات مخصَّص في هذه الجلسة: قاعدة بيانات بُنِيت حتى ترحيلة **0091 فقط** + `seed.sql`، ثم أُنشِئت عليها بيانات مرتجعات حقيقية بتوقيعات الدوال **القديمة** (ما قبل 0092) في **الحالات الأربع** الممكنة لدورة الحياة:

| الحالة | عبر الدالة القديمة (ما قبل 0092) |
|---|---|
| `pending` (لم يُبتّ فيه بعد) | `create_sales_return()` فقط |
| `approved` مع استرداد جزئي مُسجَّل | `create_sales_return()` → `approve_sales_return()` → `record_sales_return_refund()` |
| `rejected` | `create_sales_return()` → `reject_sales_return()` |
| `reversed` | `create_sales_return()` → `approve_sales_return()` → `reverse_sales_return()` |

ثم طُبِّقت ترحيلات 0092–0098 فوق هذه البيانات القائمة (نجحت كلها دون أي خطأ)، وتحقَّقت هذه الجلسة مباشرةً من عمود Backfill الجديد في 0092 على الصفوف الأربعة الحقيقية:

| الحالة | `source_sale_row_version` (Backfill) | بنود نشطة (`status='active'`) | بنود `is_effective` | بنود `included_in_decision` | بنود ظاهرة عبر `get_sales_return()` |
|---|---|---|---|---|---|
| `pending` | 1 (مُستنتَج بشكل صحيح) | 1 | 0 (صحيح — لا مطالبة فعّالة لمرتجع لم يُعتمَد بعد) | 0 (صحيح — لا قرار بعد) | 1 |
| `approved` | 1 | 1 | 1 (صحيح — هو المرتجع الفعّال الوحيد) | 1 | 1 |
| `rejected` | 1 | 0 (كما كان سلوك الكود القديم — حذف ناعم متسلسل عند الرفض) | 0 | **1 (Backfill رجعي أعاد بناء التاريخ)** | **1 (لا تختفي رغم `status='removed'`)** |
| `reversed` | 1 | 0 (نفس السلوك القديم عند الاعتماد ثم التراجع) | 0 (صحيح — المطالبة أُطلِقت) | **1 (Backfill رجعي)** | **1 (لا تختفي)** |

**الخلاصة:** منطق الـBackfill في 0092 يُعيد بناء `is_effective`/`included_in_decision`/`source_sale_row_version`/`sale_date_snapshot` بشكل صحيح تمامًا لكل حالة من الأربع، وتاريخ البند (Section 6) ينجو من الترقية رغم أن الكود القديم (ما قبل 4.1) كان يحذف بنود الرفض/التراجع ناعمًا (`status='removed'`) — وهو بالضبط ما تحله فحصية `status='active' OR included_in_decision=true` الجديدة في `get_sales_return()`. `refund_reconciliation_state` أيضًا يُحسَب بشكل صحيح فوريًا لكل من الصفين `approved`/`reversed` كـ`'pending'` (لم تُسوَّ التسوية النهائية بعد — سلوك متوقَّع لبيانات لم تُسوَّ بمفهوم التسوية النهائية الجديد الذي لم يكن موجودًا أصلًا وقت إنشائها).

## 4) اختبارات SQL — كل الملفات، أرقام فعلية من هذا التشغيل (تشغيل واحد متسلسل على نفس قاعدة البيانات، 0001–0098)

| الملف | النتيجة |
|---|---|
| `rls_and_permissions.test.sql` | 139/139 ✅ |
| `financial_master_data.test.sql` | 50/50 ✅ |
| `financial_integrity_patch_2_1.test.sql` | 30/30 ✅ |
| `financial_integrity_patch_2_2.test.sql` | 13/13 ✅ |
| `financial_integrity_hotfix_2_2_1.test.sql` | 14/14 ✅ |
| `financial_integrity_hotfix_2_2_2.test.sql` | 11/11 ✅ |
| `sales_core.test.sql` | 57/57 ✅ |
| `sales_integrity_patch_3_1.test.sql` (Part 1، أحادي الجلسة) | 14/14 ✅ |
| `sales_integrity_patch_3_1_concurrency.test.sql` (Part 2، تزامن حقيقي عبر `dblink`) | 10/10 ✅ |
| `sales_integrity_patch_3_2.test.sql` | 15/15 ✅ |
| `sales_integrity_hotfix_3_2_1.test.sql` | 6/6 ✅ |
| `upgrade_from_0039.test.sql` (مُشغَّل أيضًا مباشرةً ضد القاعدة الكاملة 0001–0098، إضافة لتشغيله المرجعي عبر `run_upgrade_test.sh` أعلاه) | 11/11 ✅ |
| `sales_returns_core.test.sql` (**أُعيدت كتابته بالكامل** لهذه الرقعة — 18 قسمًا، شامل سيناريوهات Patch 4.1 A–P) | **54/54 ✅** |
| `sales_returns_concurrency.test.sql` (**أُعيدت كتابته بالكامل** — تزامن حقيقي عبر `dblink`) | **R1/R2/R3 — 3/3 سيناريوهات ✅** |

**المجموع: 427 نقطة تحقق/سيناريو SQL ناجحة في تشغيلة واحدة متسلسلة على قاعدة بيانات واحدة مبنية من الصفر** (370 من كل المراحل/الرقعات السابقة — بما فيها Phase 4 الأصلية عبر الملفين القديمين قبل إعادة الكتابة — بلا أي انحدار على أي منها، + 57 جديدة أو مُعاد فحصها بالكامل لِـPatch 4.1: 54 في `sales_returns_core.test.sql` + 3 سيناريوهات في `sales_returns_concurrency.test.sql`).

### تفصيل `sales_returns_core.test.sql` (18 قسمًا، يغطي Phase 4 الأصلية بالكامل + كل سيناريوهات Patch 4.1 A–P)

يُغطّي كل ما كان يُغطّيه ملف Phase 4 الأصلي (اشتقاق حالة العملية الكاملة/الجزئية، استرداد العمولة التراكمي مع امتصاص فارق التقريب، دفتر الاسترداد النقدي الفعلي، الإغلاق اليومي، الحساب من اللقطات فقط، إخفاء حقول الربح، سياسة حماية ربح `audit_logs`) **زائد** سيناريوهات Patch 4.1 الإلزامية الستة عشر:

- **A/B** — انقسام "العضوية قيد المراجعة" عن "المطالبة الفعّالة" (Section 5): مرتجعان قيد المراجعة يتعايشان على نفس البند دون تعارض؛ اعتماد أحدهما ينجح، ومحاولة اعتماد الآخر تُرفَض فورًا بفهرس `sales_return_items_effective_claim_uq` الفريد (رسالة: "هذه القطعة مرتجعة بالفعل").
- **C/D** — حفظ تاريخ البند: بند مرتجع مرفوض أو متراجَع عنه يبقى ظاهرًا دومًا (`included_in_decision=true`)، لا يختفي أبدًا رغم `status='removed'`.
- **E** — رفض قيم استرداد بأكثر من رقمين عشريين رفضًا صريحًا (`validate_money_scale()`)، لا تقريبًا صامتًا.
- **F/G** — `customer_never_received` + `not_collected`: `approved_refund_amount=0` مقبول مع انعكاس كامل للإيراد/الربح (F)؛ أي قيمة استرداد غير صفرية تُرفَض بقيد `CHECK` صريح على مستوى القاعدة، لا تحقق تطبيقي فقط (G).
- **H** — رفض `return_date` أقدم من تاريخ عملية البيع.
- **I** — رفض اعتماد مرتجع للقطة بيع أصبحت قديمة (`source_sale_row_version` غير مطابق)، مع `refresh_pending_sales_return_from_sale()` كالطريق الوحيد الصريح للتحديث.
- **J** — سياسة `full_reversal`: صفر استرداد عمولة على مرتجع جزئي، وامتصاص الرصيد الكامل فقط عند اكتمال التغطية.
- **K** — `finalize_sales_return_refund()`: يتطلب سبب فارق عند عدم التطابق، يدعم `approved_refund_amount=0` الواصل لحالة نهائية دون أي سجل استرداد وهمي، ويرفض تسوية ثانية على مرتجع مُسوًّى بالفعل.
- **L** — نطاق VISIBLE لا OPERABLE للتصحيحات التاريخية: مرتجع في متجر عُطِّل لاحقًا لا يزال قابلًا للتراجع/الرفض/تسجيل استرداد عليه.
- **M** — فلاتر `list_sales_returns()` الجديدة (رقم الطلب، المتجر الأصلي، السيناريو).
- **N** — تتبُّع حالة القطعة المرتجعة (تاريخي بحت، بلا أي لمسة لجدول Inventory).
- **O** — مجموعة حقول الأثر المالي الكاملة (Section 12) شاملة `adjusted_order_net_sales_profit` تُحسَب وتُعرَض عبر `get_sales_return()`.
- **P** — `audit_logs` يحمل فعل `return.refund_finalized` الجديد، خاضعًا لنفس سياسة حماية الربح الموحَّدة لكل أفعال `return.%`.

**إثبات صفر سياسات RLS مباشرة (مُعاد التحقق منه)** — نفس النمط القائم منذ Phase 3/Phase 4، مُثبَت هنا مجددًا عبر `reset role`.

### تفصيل `sales_returns_concurrency.test.sql` (تزامن حقيقي عبر `dblink`، لا محاكاة تسلسل استدعاءات)

- **R1 — تعايش "قيد المراجعة" ثم حصرية "الفعّال" تحت سباق حقيقي:** مرتجعان قيد المراجعة يُنشآن مسبقًا (بنجاح، بلا تعارض) على نفس البند؛ ثم اتصال A يعتمد الأول ويُبقي معاملته مفتوحة، اتصال B يحاول اعتماد الثاني بالتوازي — يُحجَب فعليًا (مُثبَت عبر استقصاء `dblink_is_busy`) حتى التزام A، ثم يُرفَض برسالة واضحة ("هذه القطعة مرتجعة بالفعل.") عبر فهرس `sales_return_items_effective_claim_uq` الفريد الحقيقي — لا ازدواج مطالبات ممكن حتى تحت تزامن حقيقي.
- **R2 — سباق إغلاق يوم مقابل إنشاء مرتجع (بتوقيع jsonb الجديد):** `close_sales_day()` ينتظر فعليًا حتى التزام `create_sales_return()` المفتوحة لنفس المتجر/اليوم قبل أن يتابع — القفل المشترك/الحصري لِـReturns مطابق تمامًا لآلية Sales القائمة.
- **R3 — إثبات ترتيب القفل الآمن العالمي (Section 19) وعدم وجود طريق مسدود:** اتصال A يعتمد مرتجعًا (يحجز قفل صف `sales_orders` ثم القفل الاستشاري)، اتصال B يحاول بالتوازي `update_sales_order()` وصفيًا بحتًا على نفس الطلب — يُحجَب فعليًا على قفل الصف، لا يصل أبدًا لحالة طريق مسدود (`deadlock`/`40P01`)، وينجح طبيعيًا بعد التزام A (لا مانع مالي لأن القيم المُعاد إرسالها مطابقة تمامًا، بلا تغيير مالي فعلي).

الثلاثة خارج معاملة `begin/rollback` (تلتزم فعليًا، مطابقةً لطبيعة اختبار `dblink`) — مع تنظيف صريح بحذف كل الصفوف المُنشَأة في نهاية الملف، مُثبَت أيضًا بنجاح فعلي.

## 5) اختبار HTTP/PostgREST الحقيقي — نتائج فعلية

`scripts/run_postgrest_http_test.sh` (ثنائي PostgREST v12.2.3 حقيقي، JWT حقيقي مُوقَّع، `@supabase/postgrest-js`، لا محاكاة):

```
=== ALL REAL HTTP/POSTGREST INTEGRATION TEST ASSERTIONS PASSED ===
```

**64/64 تأكيدًا ناجحًا.** قسم "Part 7 — Returns" أُعيد كتابته بالكامل ليطابق توقيعات وسلوك Patch 4.1، ومن أبرز ما أُثبِت عبر HTTP فعلي (لا محاكاة محلية):

- `get_returnable_sales_order()` يُعيد أيضًا `row_version` الخاص بالبيعة (Section 4).
- `preview_sales_return()` بتوقيع jsonb الجديد يُعيد `returned_original_sale_amount` (Section 1) كنص، مع وسم تقدير العمولة.
- استرداد بأكثر من رقمين عشريين (`"500.005"`) يُرفَض فعليًا عبر HTTP برسالة تطابق `/عشري/`.
- مرتجع ثانٍ قيد المراجعة على نفس البند **مقبول الآن** (Section 5، عكس السلوك القديم)، مع `returnable=true` لكلا البندين حتى اعتماد أحدهما.
- اعتماد المرتجع الثاني بعد اعتماد الأول **يُرفَض** فعليًا برسالة "هذه القطعة مرتجعة بالفعل" (فهرس المطالبة الفعّالة الفريد).
- `get_sales_return()` بعد الاعتماد يُظهر كل حقول Section 12 (شاملة `recovered_original_cost_amount`/`net_sales_profit_adjustment`/`adjusted_order_net_sales_profit`) كنصوص لممثِّل يملك `sales.view_profit`، وغيابًا تامًا لها لممثِّل لا يملكها.
- `finalize_sales_return_refund()` يصل بـ`refund_reconciliation_state` إلى `finalized_matched` فعليًا عبر HTTP بعد تسجيل استرداد مطابق.
- بعد `reverse_sales_return()`، `get_sales_return()` لا يزال يُظهر بند المرتجع (`items.length === 1`) — إثبات Section 6 عبر HTTP.
- حماية تدقيق `return.%` (0091، غير مُعدَّلة) لا تزال تعمل بلا انحدار، شاملةً فعل `return.refund_finalized` الجديد.

## 6) فحوصات الطبقة الأمامية (TypeScript/React) — نتائج فعلية

- `npx tsc --noEmit` → **صفر أخطاء** (شمل كل الملفات المُعدَّلة: `src/types/database.ts`، `src/features/returns/{schema,actions}.ts`، مكوّنات `refund-events-panel.tsx`/`return-entry-form.tsx`، `src/app/(app)/returns/{page,[id]/page}.tsx`، `src/lib/audit/action-labels.ts`).
- `npx eslint .` → **صفر أخطاء وتحذيرات** عبر المشروع بالكامل (شمل إصلاح خطأ `react-hooks/set-state-in-effect` حقيقي في `return-entry-form.tsx`، مُوثَّق في الملحق أدناه).
- `npx vitest run` → **47/47 ناجح عبر 6 ملفات** (بلا تغيير — Patch 4.1 لم يمسّ منطق Decimal/وحدة اختبار قائمة).
- `npm run check:numeric-types` → **نجح، 43/43 عمود NUMERIC مطابق** لِـ`number` في `database.ts` (زيادة 4 أعمدة جديدة عن Phase 4 الأصلية — 39 + `non_shipping_deduction_amount`/`returned_original_sale_amount`/`recovered_original_cost_amount`/`net_sales_profit_adjustment` — كلها مطابقة لسلوك PostgREST الفعلي، لا `string` وهمي).
- `npm run build` (Next.js/Turbopack) → **نجح**، بلا مسارات جديدة (Patch 4.1 توسِّع نفس مسارات Returns الأربعة القائمة من Phase 4، لا تضيف مسارات جديدة).

## 7) خلاصة

**427 نقطة تحقق/سيناريو SQL** (370 من كل المراحل/الرقعات السابقة بما فيها Phase 4 الأصلية، صفر انحدار + 57 جديدة أو مُعاد فحصها بالكامل لِـPatch 4.1)، **64 تأكيدًا HTTP/PostgREST حقيقيًا**، **47 اختبار Vitest**، **43/43 عمود NUMERIC**، وفحوصات `tsc`/`eslint`/`next build` نظيفة بالكامل، إضافة لإثبات مخصَّص لسلامة الترقية على بيانات Returns حقيقية سابقة لـPatch 4.1 (القسم 3 أعلاه) — كلها من تشغيلة فعلية واحدة على قاعدة بيانات واحدة مبنية من الصفر في هذه الجلسة، لا أرقام مفترَضة أو منسوخة. **لم تبدأ Shipping ولا Settlements ولا Services/Adjustments ولا Inventory ولا Reports — العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP هذا التسليم.**
