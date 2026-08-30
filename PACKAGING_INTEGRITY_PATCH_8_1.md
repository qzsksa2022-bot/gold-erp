# PACKAGING_INTEGRITY_PATCH_8_1.md

## Patch 8.1 — §54-55 — سلامة التحزيم (`.env.example`/`next-env.d.ts`) + مقارنة شجرة كاملة

---

## 1) اكتشاف حقيقي: عيب تحزيم فعلي لا يزال قائمًا في آخر تسليم فعلي

فحص مباشر لآخر أرشيف تسليم فعلي (`/home/claude/deliverables/gold-erp-phase8-reports-dashboard.zip`، تاريخ `2026-08-29 10:23`، أساس Phase 8 الذي يُبنى عليه Patch 8.1 هذا) عبر `unzip -l` يؤكِّد:

```
$ unzip -l gold-erp-phase8-reports-dashboard.zip | grep -iE "env\.example|next-env"
(لا نتيجة — صفر تطابق)
```

**كلا الملفين غائبان تمامًا** من هذا الأرشيف المُسلَّم فعليًا — رغم أن ملاحظة سابقة في `DELIVERY_REPORT.md` (§38 البند 25، عند تسليم Patch 7.1) زعمت أن هذا العيب "أُصلح فقط في خطوة التحزيم" لتلك الجولة تحديدًا. الفحص المباشر هنا يثبت أن العيب **لم يُصلَح بشكل دائم** — إذ عاد للظهور في تسليم Phase 8 اللاحق. السبب الجذري الحقيقي:

```
$ git check-ignore -v .env.example next-env.d.ts
.gitignore:34:.env*        .env.example
.gitignore:41:next-env.d.ts  next-env.d.ts
$ git ls-files | grep -E "^\.env\.example$|^next-env\.d\.ts$"
(لا نتيجة)
```

كلا الملفين مطابقان لأنماط `.gitignore` (`.env*` للأول، والسطر الحرفي `next-env.d.ts` للثاني) — وهذا **صحيح ومقصود لأغراض git نفسه** (لا داعٍ لتتبُّع `next-env.d.ts` المولَّد تلقائيًا، و`.env*` يحمي من تسريب أسرار حقيقية عبر التزام خاطئ). لكن خطوات التحزيم السابقة (غير موثَّقة كسكربت، نُفِّذت يدويًا على الأرجح عبر أداة تعتمد على git، مثل `git archive` أو استبعاد قائم على `git ls-files`) عاملت "مُستبعَد من git" على أنه **مرادف** لـ"مُستبعَد من التسليم" — وهذا خطأ لِـ`.env.example` تحديدًا (قالب بلا أي سر حقيقي، الغرض الوحيد منه أن يصل للمستخدم) ولِـ`next-env.d.ts` (ملف صغير غير ضار كانت كل التسليمات السابقة تتضمَّنه فعليًا رغم استبعاده من git).

---

## 2) الإصلاح: `scripts/build_delivery_zip.sh` — تحزيم صريح، لا يعتمد على `.gitignore` إطلاقًا

سكربت جديد يبني أرشيف التسليم مباشرة من نظام الملفات عبر `zip -r` بقائمة استبعاد **صريحة ومُعدَّدة يدويًا** (node_modules/.git/.next/out/build/coverage/.vercel/\*.tsbuildinfo/سجلات التصحيح/`.DS_Store`/\*.pem/ملفات `.env` **الحقيقية فقط** — `.env`/`.env.local`/`.env.development.local`/`.env.test.local`/`.env.production.local`، وليس `.env.example`) — **لا يستخدم `.gitignore` ولا `git ls-files` كمصدر استبعاد إطلاقًا**، فلا يمكن لقاعدة `.gitignore` غير ذات صلة (كحماية الأسرار) أن تُسقط ملفًا تسليميًا حقيقيًا بالخطأ مرة أخرى.

**بوابة سلامة صارمة (لا تحذير فقط):**
- **قبل** البناء: يتحقق من وجود `.env.example`/`next-env.d.ts` في شجرة العمل — يتوقف فورًا (exit 1) إن غاب أحدهما.
- **بعد** البناء: يفتح الأرشيف الناتج فعليًا (`unzip -l`) ويتحقق من وجود الملفين بداخله حرفيًا — يتوقف فورًا إن غاب أحدهما رغم اجتياز الفحص الأول (أي عطل تحزيمي غير متوقَّع لا يمر بصمت).

**نتيجة تشغيل فعلي (اختبار تحقُّق):**

```
$ ./scripts/build_delivery_zip.sh /tmp/test_delivery_check.zip
==> Pre-flight: confirming .env.example and next-env.d.ts exist in the working tree
==> Building /tmp/test_delivery_check.zip via explicit zip -r with an enumerated exclude list (never .gitignore-driven)
==> Post-flight: confirming .env.example and next-env.d.ts landed in the archive
==> SUCCESS: /tmp/test_delivery_check.zip built with 758 entries, .env.example + next-env.d.ts both confirmed present
```

هذا السكربت هو ما سيُستخدَم فعليًا لبناء أرشيف تسليم Patch 8.1 النهائي — لا تحزيم يدوي بعد الآن لهذا المشروع.

---

## 3) مقارنة شجرة كاملة — آخر تسليم فعلي مقابل حالة المستودع الحالية

```
$ diff -rq --exclude=node_modules --exclude=.git --exclude=.next --exclude=coverage \
    --exclude=build --exclude=.vercel --exclude="*.tsbuildinfo" \
    <آخر أرشيف مُستخرَج> <شجرة العمل الحالية>
```

**النتيجة: صفر حالة "Only in <التسليم السابق>"** — أي **لا ملف واحد** كان موجودًا في آخر تسليم فعلي واختفى من المستودع الحالي. لا فقدان بيانات، لا تراجع، لا حذف غير مقصود لأي ملف عبر كامل جلسة Patch 8.1 هذه.

**24 ملفًا مُعدَّلًا** — كلها مبرَّرة ومتوقَّعة بالكامل، كل واحد يعود إلى مهمة موثَّقة من مهام Patch 8.1 (`src/app/(app)/dashboard/page.tsx`، صفحات `reports/{cod,returns,settlements,shipping}/page.tsx`، `src/app/api/reports/export/route.ts`، مكوّنات لوحة التحكم/التقارير، `excel.ts`/`pdf.ts`/`report-registry.ts`/`queries.ts`/`url.ts`، `src/lib/decimal.ts`، `src/types/database.ts`، وملفات Vitest المقابلة).

**22 ملفًا جديدًا** — كلها ترحيلات/سكربتات/اختبارات/توثيق Patch 8.1 المُسلَّمة صراحة في هذه الجلسة: الترحيلات `0205`–`0214` (عشر ترحيلات)، `supabase/tests/fixtures/phase8_performance_fixture.sql`، `supabase/tests/fixtures/phase8_upgrade_pre_fixture.sql`، `supabase/tests/performance_reports_dashboard.test.sql`، `supabase/tests/upgrade_phase8_multidomain.test.sql`، `scripts/run_upgrade_test_phase8_multidomain.sh`، `scripts/build_delivery_zip.sh`، `tests/dashboard-period-presets.test.ts`، `tests/report-url-typed-filters.test.ts`، `src/features/dashboard/components/period-presets.tsx`، `PERFORMANCE_RESULTS_PATCH_8_1.md`، بالإضافة إلى `.env.example`/`next-env.d.ts` أنفسهما (يظهران "جديدَين" هنا فقط لأنهما كانا غائبَين عن الأرشيف السابق بسبب العيب الموصوف أعلاه — لم يُفقَدا من شجرة العمل قط).

---

## 4) الخلاصة

- عيب تحزيم حقيقي (لا افتراضي) اكتُشف بفحص مباشر لآخر أرشيف مُسلَّم فعليًا — `.env.example`/`next-env.d.ts` غائبان تمامًا رغم وجودهما الصحيح في شجرة العمل طوال الوقت.
- السبب الجذري: تحزيم قائم على استبعاد git بدلًا من قائمة استبعاد صريحة مخصَّصة للتسليم.
- الإصلاح: `scripts/build_delivery_zip.sh` — تحزيم صريح ببوابة سلامة قبل/بعد تمنع تكرار هذا العيب بنيويًّا، لا فقط لهذه الجولة.
- مقارنة شجرة كاملة ضد آخر تسليم فعلي: **صفر ملف مفقود**، كل التعديلات/الإضافات مبرَّرة ومتتبَّعة بالكامل.
