# Gold ERP — Hotfix 8.1.3 Task

أنت تعمل داخل مستودع Gold ERP على الفرع:

`hotfix/8.1.3`

والفرع `main` يمثل Baseline لـ Hotfix 8.1.2.

## المطلوب — Blockerان فقط

### Blocker 1 — Dashboard calendar comparison wiring
1. توصيل Dashboard فعليًا بـ `get_dashboard_summary_with_comparison` بدل `get_dashboard_summary`.
2. تمرير `period_preset` من أزرار الفترات السريعة.
3. عند تغيير `date_from` أو `date_to` يدويًا يجب ألا يبقى preset قديم؛ احذفه أو استخدم `custom` بشكل صحيح.
4. الفترة الافتراضية بداية الشهر → اليوم يجب أن تكون متوافقة بوضوح مع `this_month`.
5. أضف اختبارًا يثبت أن Dashboard يستدعي الـRPC الجديدة مع الـpreset الصحيح.
6. أضف اختبارًا يثبت أن تعديل التاريخ يدويًا لا يترك preset قديمًا.

### Blocker 2 — Payment Methods export parity
1. أضف `payment_method_id` إلى `payment-methods.extraFilterKeys` في export registry.
2. أضف Integration Test يثبت أن `payment_method_id` يصل فعليًا إلى `get_payment_methods_report` أثناء التصدير.

## قيود صارمة
- لا تبدأ Phase 9.
- لا توسع Scope.
- لا تعدّل أي migration من `0001` إلى `0226`.
- لا تضف migration `0227` إلا إذا ظهر سبب تقني حقيقي؛ إذا ظهر، توقف واشرح السبب قبل إضافتها.
- لا تعدّل `supabase/seed.sql`.
- لا تعمل refactor غير مطلوب.
- لا تدمج الفرع في `main`.
- حافظ على التوافق الحالي وعدم كسر أي اختبار قائم.

## التحقق المطلوب
شغّل ما يلزم من اختبارات المشروع، وبالأخص:
- الاختبارات الجديدة للـDashboard wiring
- اختبارات export الخاصة بـPayment Methods
- `npx vitest run`
- `npx tsc --noEmit`
- `npx eslint .`
- `npx next build`

ثم راجع:

`git diff main...HEAD`

وتأكد أن التغييرات محصورة في Hotfix 8.1.3 فقط.

## التسليم
بعد الانتهاء:
1. أعطني ملخصًا دقيقًا للملفات المعدلة.
2. أعطني نتائج الاختبارات بالأرقام.
3. أعطني أي ملاحظات أو مخاطر باقية.
4. اعمل commit على `hotfix/8.1.3`.
5. لا تعمل merge إلى `main`.
