# Gold ERP

نظام إدارة المبيعات والربحية لمحلات الذهب — تطبيق ويب بالعربية (RTL) مبني على
Next.js وSupabase/PostgreSQL.

الوحدات المُنفَّذة حاليًا: البيانات المالية الأساسية، المبيعات، المرتجعات،
الشحن، الخدمات/التعديلات، التسويات البنكية، التقارير ولوحة المعلومات
والتصدير (PDF/Excel)، ونواة المخزون.

## المبادئ المعمارية

- **كل كتابة تمر عبر RPC في قاعدة البيانات** (`SECURITY DEFINER`)؛ الجداول
  المالية لا تحمل سياسات كتابة RLS مباشرة.
- **لا حساب مالي في طبقة العميل** — القيم المالية/الأوزان/الكميات تُعاد من
  القاعدة كنصوص (`::text`) لا كأرقام، حفاظًا على الدقة.
- **الترحيلات إضافية فقط** — الملفات الموجودة في `supabase/migrations/` لا
  تُعدَّل بعد تسليمها؛ أي تصحيح يأتي في ترحيلة جديدة.
- **الصلاحيات مركزية** عبر `has_permission()`، ونطاق الفروع عبر
  `my_visible_store_ids()` / `my_operable_store_ids()`.

## المتطلبات

- Node.js 22
- PostgreSQL 16 (لتشغيل اختبارات SQL محليًا)، مع امتداد `dblink` متاحًا
  لاختبارات التزامن
- مشروع Supabase (أو قاعدة PostgreSQL متوافقة) لتشغيل التطبيق

انسخ `.env.example` إلى `.env.local` واملأ القيم المطلوبة.

## التشغيل

```bash
npm ci
npm run dev      # خادم التطوير
npm run build    # بناء إنتاجي
npm run start    # تشغيل البناء الإنتاجي
```

## الفحوص

```bash
npm test         # Vitest
npm run typecheck # tsc --noEmit
npm run lint      # ESLint
npm run build     # بناء إنتاجي
```

سكربتات مساعدة:

```bash
npm run bootstrap:super-admin   # إنشاء أول مستخدم Super Admin (يتطلب DATABASE_URL/مفاتيح Supabase)
npm run check:numeric-types     # فحص أنواع الأعمدة الرقمية (يتطلب DATABASE_URL حيًّا)
```

## اختبارات SQL

اختبارات القاعدة في `supabase/tests/` وتنقسم إلى ثلاثة أنواع، لكلٍّ طريقة
تشغيل مختلفة:

### 1. اختبارات عادية

معاملة واحدة تنتهي بـ`rollback`. تحتاج قاعدة مبنية بالكامل:

```bash
createdb gold_erp_test
psql -d gold_erp_test -c "create role anon nologin;"
psql -d gold_erp_test -c "create role authenticated nologin;"
psql -d gold_erp_test -c "create role service_role nologin bypassrls;"
psql -d gold_erp_test -v ON_ERROR_STOP=1 -f supabase/tests/local_harness_setup.sql
for f in supabase/migrations/*.sql; do psql -d gold_erp_test -v ON_ERROR_STOP=1 -f "$f"; done
psql -d gold_erp_test -v ON_ERROR_STOP=1 -f supabase/seed.sql

psql -d gold_erp_test -v ON_ERROR_STOP=1 -f supabase/tests/sales_core.test.sql
```

`local_harness_setup.sql` يُنشئ بديلًا مصغّرًا لمخطط `auth` الخاص بـSupabase
حتى تعمل الترحيلات وسياسات RLS على PostgreSQL عادي. **لا يُطبَّق على قاعدة
Supabase حقيقية.**

### 2. اختبارات التزامن (`*_concurrency.test.sql`)

تفتح جلستين حقيقيتين عبر `dblink` وتتحقق من التنافس الفعلي على الأقفال. تعمل
بلا معاملة غلاف وتُبقي بياناتها، لذا **تحتاج قاعدة مستقلة لكل ملف**:

```bash
psql -d gold_erp_conc -c "create extension if not exists dblink;"
psql -d gold_erp_conc -v ON_ERROR_STOP=1 \
  -v "dblink_conninfo=host=127.0.0.1 port=5432 user=postgres password=postgres" \
  -f supabase/tests/settlements_phase7_concurrency.test.sql
```

الخادم يجب أن يطلب **مصادقة بكلمة مرور** (مثل `scram-sha-256`): عدة ملفات
تستدعي `dblink_connect` بعد `set local role authenticated`، وdblink يرفض اتصال
مستخدم غير superuser ما لم تُستخدم كلمة مرور فعليًا — وإلا يظهر
`password or GSSAPI delegated credentials required` رغم تمرير كلمة المرور.

### 3. اختبارات الترقية (`upgrade_*.test.sql`)

لا تُشغَّل مباشرة: لكلٍّ سكربت في `scripts/` يبني قاعدة حتى ترحيلة تاريخية
محددة، يطبّق `seed.sql` الحقيقي عندها، ثم يطبّق الترحيلات الأحدث فوقها في
استدعاء `psql` منفصل — تمامًا كما تختبر ترقية إنتاجية حقيقية:

```bash
DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:5432/gold_erp_upgrade_test" \
  ./scripts/run_upgrade_test_phase9_inventory.sh
```

## CI

`.github/workflows/ci.yml` فيه وظيفتان:

- **`verify`** — `npm ci` ثم Vitest وTypeScript وESLint والبناء الإنتاجي.
- **`sql`** — يشغّل PostgreSQL 16 كـservice، ينشئ الأدوار، يبني قاعدة **template**
  واحدة (harness + كل الترحيلات + seed)، ثم يشغّل كل اختبارات SQL: العادية
  والتزامن (كلٌّ على نسخة نظيفة من الـtemplate) واختبارات الترقية (كل سكربت
  يبني قاعدته الخاصة). لا يوجد `continue-on-error` ولا تخطٍّ لأي ملف.

  تبدأ الوظيفة بخطوة **SQL test coverage**: فحص ملفات خالص (بلا قاعدة) يرفض
  وجود أي `*.test.sql` بلا مسار تنفيذ واضح — أي ملف ترقية جديد بلا runner في
  `scripts/` يُسقط البناء بدل أن يبقى غير مُنفَّذ بصمت.
