# تقرير التسليم — الأساس المعماري لنظام إدارة المبيعات والربحية (محلات الذهب)

**التاريخ:** 17 أغسطس 2026 (مُحدَّث بعد تسليم **Financial Integrity Patch 2.1**، ترحيلات 0047–0050، فوق Phase 2 المغلقة عند 0046)
**الحالة:** المرحلة التأسيسية (Foundation, 0001–0039) — مكتملة ومُغلقة نهائيًا. Phase 2 — البيانات المالية الأساسية (0040–0046) — مكتملة ومُغلقة، لا تعديل عليها في هذه المرحلة. **Financial Integrity Patch 2.1 (0047–0050) مُسلَّمة الآن فوقهما**: قفل جداول الـVersioning من التعديل المباشر، إصلاح إعادة فتح السلف عند إلغاء نسخة مستقبلية، قفل الأعمدة المُدارة نظاميًا على كل جداول Phase 2، مسار ترقية إنتاج فعلي من Foundation 0039 بلا حاجة لإعادة تشغيل `seed.sql`، حفظ أسعار الذهب اليومية ذرّيًا، `fee_model` كقيد بنيوي على مستوى القاعدة، حدود نقل عشري آمنة، وعرض حالي/قادم صحيح في الواجهة — بلا أي Sales/Returns/Shipments/Settlements، تمامًا كما حدَّد النطاق. مُتحقق منها فنيًا بالكامل (تفاصيل الملحق الثامن). **بحسب التعليمات الصريحة، لا تبدأ Sales أو أي مرحلة تالية تلقائيًا — العمل متوقف الآن بانتظار المراجعة والموافقة.**

هذا التقرير يغطي البنود الـ 16 المطلوبة في مواصفة Foundation الأصلية (القسم 28)، معايير الإنجاز الصارمة في القسم 29 وكيفية التحقق من كل واحد منها فعليًا (وليس افتراضًا)، **بالإضافة إلى ثمانية ملاحق كاملة في نهاية الملف: الملحق الأول يوثّق المراجعة الأمنية المستقلة الأولى (ترحيلات 0012–0016)، الملحق الثاني يوثّق مراجعة ثانية أعمق ("Foundation Hardening 1.2"، ترحيلات 0017–0024)، الملحق الثالث يوثّق مراجعة ثالثة ("Foundation Hardening 1.3"، ترحيلات 0025–0031)، الملحق الرابع يوثّق مراجعة رابعة ("Foundation Hardening 1.4"، ترحيلات 0032–0036)، الملحق الخامس يوثّق "Patch 1.4.1" (ترحيلات 0037–0038)، الملحق السادس يوثّق "Foundation Audit Hotfix 1.4.2" (ترحيلة 0039)، الملحق السابع يوثّق Phase 2 — البيانات المالية الأساسية بالكامل (ترحيلات 0040–0046)، **والملحق الثامن (جديد) يوثّق Financial Integrity Patch 2.1 بالكامل (ترحيلات 0047–0050).** كل قسم من الأقسام 1–16 أدناه ما يزال يصف Foundation فقط كما كان — تفاصيل Phase 2 في الملحق السابع، وتفاصيل Patch 2.1 في الملحق الثامن حصرًا، دون تكرار أو إعادة كتابة الأقسام السابقة.**

---

## 1) ماذا تم بناؤه

تم بناء **الأساس المعماري الكامل** لنظام إدارة متعدد المتاجر لمحلات الذهب، جاهز لإضافة المبيعات/المرتجعات/التسويات/الشحن لاحقًا **دون إعادة هيكلة**. تحديدًا:

- نظام مصادقة (Auth) كامل عبر Supabase مع صفحة دخول احترافية بواجهة عربية RTL أصيلة.
- نظام صلاحيات دقيق (Permission-based) مبني على **مفاتيح صلاحيات** وليس أسماء أدوار، مع طبقة أدوار + استثناءات فردية (grant/revoke) لكل مستخدم.
- إدارة متاجر غير محدودة العدد (لا يوجد أي متجر وهمي أو ترقيم ثابت) مع تعطيل/إعادة تفعيل بدل الحذف الفعلي.
- إدارة مستخدمين وأدوار وصلاحيات كاملة عبر واجهة استخدام.
- سجل تدقيق (Audit Log) شامل، **غير قابل للتعديل أو الحذف من أي عميل**، مع صفحة عرض بفلاتر وبحث ومقارنة القيم القديمة/الجديدة.
- إعدادات نظام أساسية (اسم النظام، الشعار، العملة، المنطقة الزمنية، المظهر، الأمان) قابلة للتوسعة.
- هيكل تنقل (Sidebar + Header + Mobile Drawer) يتضمن جميع الوحدات المستقبلية كصفحات "قريبًا" بدون إزعاج.
- لوحة تحكم (Dashboard) تأسيسية بدون أي بيانات مالية أو مبيعات وهمية.
- نظام تصميم مركزي (Design Tokens) قابل للتعديل مستقبلًا من الإعدادات دون المساس بعشرات الملفات.
- طبقة حماية دفاعية متعددة المستويات: RLS حقيقي على Postgres + Triggers حماية + طبقة تحقق في الخادم (Server Actions).
- اختبارات آلية للصلاحيات والتحقق (Validation) + اختبار تكامل SQL مخصص لـ RLS/الدوال الأمنية.

**لم يتم بناؤه عمدًا** (بحسب حدود المرحلة المطلوبة): المبيعات، المرتجعات، الشحن، التسويات المالية، أسعار الذهب الحقيقية، حساب الأرباح، بوابات الدفع (Tabby/Tamara/Visa/Mada)، رسوم الشحن، المخزون، تكامل سلة، تكامل شركات الشحن. جميعها محضّرة معماريًا فقط (روابط تنقل + صلاحيات محجوزة).

---

## 2) المعمارية المستخدمة

**Stack:** Next.js 16.3.1 (App Router + Turbopack) · TypeScript (وضع صارم) · React 19.2 · PostgreSQL عبر Supabase (Auth + RLS) · Tailwind CSS v4 · مكوّنات UI مبنية يدويًا بأسلوب shadcn/ui فوق Radix UI · React Hook Form + Zod · ESLint + Prettier.

**نمط الطبقات:**

```
src/app/            → توجيه Next.js فقط (Route Segments)، بدون منطق أعمال
src/features/<name>/  → كل ميزة بها: schema.ts (Zod) · queries.ts (قراءة) ·
                          actions.ts (كتابة عبر Server Actions) · components/
src/lib/             → عابر للميزات: supabase clients، permissions، audit،
                          date/money helpers، design tokens runtime
src/components/ui/    → مكوّنات واجهة عامة (زر، حقل، جدول، حوار...)
src/components/layout/→ الهيكل العام (Sidebar/Header/UserMenu...)
src/types/database.ts → أنواع TypeScript يدوية مطابقة تمامًا لسكيمة القاعدة
supabase/migrations/  → ترحيلات SQL مرقّمة ومتسلسلة
supabase/seed.sql     → بيانات أولية (صلاحيات/أدوار/إعدادات) — بدون متاجر وهمية
supabase/tests/       → اختبار تكامل SQL لـ RLS
scripts/               → سكربت إنشاء أول Super Admin
tests/                  → اختبارات Vitest (منطق صلاحيات + تحقق)
```

**قرارات معمارية رئيسية (واتُّخذت دون الرجوع للمستخدم بحسب طلبه):**

- **مصدر حقيقة واحد للصلاحيات:** دالة SQL واحدة `get_user_permissions()` تُستخدم من RLS ومن التطبيق، بدل تكرار المنطق. هذا يمنع تعارض "الواجهة تسمح لكن القاعدة تمنع" أو العكس.
- **الحماية دفاعية متعددة الطبقات (Defense in Depth):** RLS + Triggers + طبقة تحقق في الخادم. أي طبقة تُخترق أو يُنسى تفعيلها، الطبقات الأخرى ما زالت تحمي.
- **سجل التدقيق موثوق تمامًا:** لا توجد سياسة RLS تسمح بـ INSERT/UPDATE/DELETE مباشر على `audit_logs` من أي دور عميل (حتى Super Admin). الكتابة الوحيدة عبر دالة `log_audit_event()` وهي `SECURITY DEFINER` تُثبّت `user_id = auth.uid()` تلقائيًا فلا يمكن انتحال هوية مستخدم آخر في السجل.
- **معالجة الوقت:** تخزين بصيغة `timestamptz` (UTC قياسي) في القاعدة، والعرض في الواجهة يُحوَّل دائمًا إلى `Asia/Riyadh` عبر طبقة `src/lib/date.ts` — لا يوجد أي تحويل يدوي متفرق في الكود.
- **معالجة الأرقام المالية:** أُسِّس القرار الآن رغم عدم وجود مبيعات فعلية — أي عمود مالي/وزن/نسبة مستقبلي **يجب** أن يكون `NUMERIC` وليس `float`، وسيُعرض دائمًا عبر `src/lib/money.ts` لضمان التنسيق الموحّد (SAR / جرام بكسور).

---

## 3) مخطط قاعدة البيانات (Schema)

39 ترحيل SQL متسلسل ومُختبر فعليًا على Postgres محلي (وليس افتراضًا نظريًا). **0001–0011 هي الأساس الأول؛ 0012–0016 إصلاحات المراجعة الأمنية المستقلة الأولى؛ 0017–0024 إصلاحات "Foundation Hardening 1.2" (مراجعة ثانية أعمق)؛ 0025–0031 إصلاحات "Foundation Hardening 1.3" (مراجعة ثالثة مستقلة)؛ 0032–0036 إصلاحات "Foundation Hardening 1.4" (مراجعة رابعة مستقلة)؛ 0037–0038 إصلاحات "Patch 1.4.1" (تصحيح محدود بثلاثة بنود فقط)؛ 0039 إصلاح "Foundation Audit Hotfix 1.4.2" (بند واحد متبقٍ من Patch 1.4.1) — كل مجموعة أُضيفت كترحيلات جديدة فقط، ولم يُعدَّل أي ملف من 0001–0038 على الإطلاق. تفاصيل 0012–0016 في الملحق الأول، تفاصيل 0017–0024 في الملحق الثاني، تفاصيل 0025–0031 في الملحق الثالث، تفاصيل 0032–0036 في الملحق الرابع، تفاصيل 0037–0038 في الملحق الخامس، وتفاصيل 0039 في الملحق السادس آخر هذا الملف:**

| # | الملف | المحتوى |
|---|---|---|
| 0001 | `extensions_and_helpers.sql` | امتداد `pgcrypto`، دالة `set_updated_at()` (trigger عام لتحديث `updated_at`) |
| 0002 | `profiles.sql` | جدول `profiles` (يمتد `auth.users`) |
| 0003 | `permissions_and_roles.sql` | `permissions`, `roles`, `role_permissions` |
| 0004 | `user_roles_and_overrides.sql` | `user_roles`, `user_permission_overrides` |
| 0005 | `stores_and_access.sql` | `stores`, عمود نطاق الوصول على `profiles`، `user_store_access` |
| 0006 | `audit_logs.sql` | جدول `audit_logs` (بدون سياسة كتابة لأي عميل) |
| 0007 | `system_settings.sql` | جدول `system_settings` |
| 0008 | `permission_functions.sql` | الدوال الأمنية الجوهرية (انظر القسم 5) |
| 0009 | `protection_triggers.sql` | Triggers حماية Super Admin والأدوار النظامية |
| 0010 | `rls_policies.sql` | كل سياسات RLS |
| 0011 | `auth_trigger.sql` | Trigger شبكة أمان لإنشاء ملف تعريف عند تسجيل مستخدم جديد في `auth.users` |
| 0012 | `store_access_scope_hardening.sql` | إعادة كتابة `user_accessible_store_ids()` لتفريع صريح حسب `all/multiple/single`، قيد اتساق `single` يتطلب `default_store_id`، triggers تمنع ربط متجر معطّل |
| 0013 | `privilege_escalation_hardening.sql` | منع التصعيد الذاتي على `user_roles`/`user_permission_overrides`/`role_permissions`، ومنع منح صلاحية لا يملكها المانح، وحماية الصلاحيات الحسّاسة الثلاث |
| 0014 | `column_level_authorization.sql` | فصل صلاحية `users.disable`/`stores.disable` عن `users.edit`/`stores.edit` على مستوى الأعمدة عبر Trigger |
| 0015 | `security_definer_hardening.sql` | `REVOKE EXECUTE FROM PUBLIC` صريح على كل دالة `SECURITY DEFINER`، قفل الدوال التي تأخذ `uuid` تعسفيًا على `service_role` فقط، وإضافة أغلفة ذاتية النطاق (`get_my_permissions`, `am_i_super_admin`, `my_accessible_store_ids`) |
| 0016 | `audit_log_hardening.sql` | سجل تدقيق مبني على Triggers قاعدة بيانات تلقائية بدل نداء RPC عام، `log_audit_event()` أصبحت `service_role` فقط، ودالة مسموح بها بقائمة بيضاء (`log_auth_event`) لأحداث الدخول/الخروج فقط |
| 0017 | `store_visibility_operability_split.sql` | فصل "الرؤية التاريخية" عن "إمكانية العمل التشغيلي": `user_operable_store_ids()`/`my_operable_store_ids()` (متاجر نشطة فقط، للعمليات الجديدة) مقابل `user_visible_store_ids()`/`my_visible_store_ids()` (كل متجر مُنح له الوصول ولو عُطِّل لاحقًا، للتاريخ/التقارير). `user_accessible_store_ids()`/`my_accessible_store_ids()` أصبحتا غلافين مستقرَّي الاسم فقط لصالح النسخة "Operable" |
| 0018 | `store_access_delegation_hardening.sql` | إغلاق تصعيد نطاق المتجر (منع التعديل الذاتي على `store_access_scope`/`default_store_id`، منع منح/سحب `user_store_access` الخاص بالفاعل نفسه، حدّ التفويض لما يملكه المانح فقط، قصر `scope='all'` على Super Admin حصرًا)، صلاحية جديدة `users.manage_store_access`، ودالة استبدال ذرّية واحدة `replace_user_store_access()` بدل إدراج-ثم-حذف من طرفين منفصلين. يتضمن أيضًا `CREATE OR REPLACE` لدالة 0014 لإضافة مسار `users.manage_store_access` الذي لم يكن معروفًا لها |
| 0019 | `profile_provisioning_status.sql` | حالة جديدة `pending_setup` مستقلة عن `suspended` — التزويد غير المكتمل لم يعد يتشارك القيمة نفسها مع "حساب مُعطَّل عمدًا"؛ `finalize_new_user_profile()` تُطابق `pending_setup` فقط الآن |
| 0020 | `super_admin_protection.sql` | حماية شاملة لأي حساب Super Admin من أي فاعل ليس هو نفسه Super Admin — تعديل بياناته، تعطيله، حذف دور `super_admin` منه — بصرف النظر عن عدد الـ Super Admin النشطين المتبقّين |
| 0021 | `system_managed_columns_lockdown.sql` | قفل `profiles.email` من أي تعديل مباشر (لا مسار متزامن مع Supabase Auth بعد)، وتثبيت `created_at`/`created_by`/`updated_at`/`updated_by` على القيم الحقيقية بصمت على `profiles`/`stores`/`roles` وجداول الربط |
| 0022 | `role_system_identity_lockdown.sql` | منع إنشاء أو ترقية أي دور إلى `is_system=true` من سياق تطبيقي (فقط عبر Migration/Bootstrap موثوق)، وقفل `roles.key` من التعديل |
| 0023 | `auth_event_trust_hardening.sql` | نقل تسجيل أحداث الدخول/الخروج إلى دالة `service_role` فقط (`log_auth_event_trusted`) تُستدعى من كود خادم بعد التحقق من الجلسة فعليًا؛ `log_auth_event(text)` القديمة (0016) لم تعد قابلة للاستدعاء من `authenticated` إطلاقًا |
| 0024 | `audit_action_taxonomy.sql` | إصلاح تسمية إجراء الـ Audit: `INSERT` تُنتج الآن `.create` بدل `.insert` الخام، لتطابق جدول التسميات في الواجهة |
| 0025 | `store_access_delegation_completion.sql` | إغلاق تفويض نطاق المتجر بالكامل: قصر تعديل `default_store_id` نفسه على نطاق تشغيل الفاعل، ومدّ حدّ التفويض (0018) ليشمل فرع `DELETE` على `user_store_access` وليس `INSERT` فقط |
| 0026 | `super_admin_entity_protection.sql` | حماية Super Admin ككيان كامل: أي `INSERT/UPDATE/DELETE` على `user_roles`/`user_permission_overrides`/`user_store_access` لهدف يحمل دور `super_admin` يتطلب أن يكون الفاعل نفسه Super Admin — وليس فقط حذف دور `super_admin` نفسه (0020) |
| 0027 | `sensitive_permission_revoke_protection.sql` | مدّ حماية الصلاحيات الحسّاسة الثلاث (0013) لتشمل مسار السحب/الحذف بشكل متماثل: `DELETE` على `role_permissions`، إضافة استثناء `revoke` أو حذف استثناء قائم على `user_permission_overrides`، وحذف دور يحمل صلاحية حسّاسة من مستخدم |
| 0028 | `store_access_select_independence.sql` | سياسة RLS إضافية لـ`SELECT` على `user_store_access` لحامل `users.manage_store_access` — بدونها كانت `replace_user_store_access()` تحسب الفرق (diff) بشكل خاطئ لفاعل لا يملك `users.view`/`stores.view` أيضًا |
| 0029 | `provisioning_invariant.sql` | عمود دائم جديد `profiles.provisioned_at` — لا يُضبَط إلا من `finalize_new_user_profile()` أو سياق Bootstrap موثوق؛ أي انتقال إلى `status='active'` بدون `provisioned_at` مضبوط يُرفَض — يُغلق مسار الالتفاف `pending_setup → suspended → active` الذي كان يتجاوز `users.create` كليًا |
| 0030 | `column_authorization_rewrite.sql` | إعادة كتابة جذرية لـTrigger تفويض الأعمدة (0014/0018): كل مجموعة أعمدة تتطلب صلاحيتها الخاصة بشكل مستقل تمامًا — `users.edit` لم تعد "تُمرِّر" تغيير `status`، ولا `stores.edit` لتغيير حالة المتجر؛ تعديل مُجمَّع لعدة مجموعات يتطلب اتحاد كل الصلاحيات المعنية |
| 0031 | `inactive_session_store_hardening.sql` | `user_operable_store_ids()`/`user_visible_store_ids()` (ومن ثمّ الأغلفة الذاتية `my_*`) تفشل بأمان (تُرجع مجموعة فارغة) لأي حساب غير `active`، بدل الاعتماد فقط على `store_access_scope`/`user_store_access` بلا فحص حالة الحساب |
| 0032 | `provisioned_at_legacy_backfill.sql` | Backfill آمن (بيانات فقط، بلا `CREATE OR REPLACE`) لـ`profiles.provisioned_at` للحسابات التي كانت مُزوَّدة فعليًا قبل إضافة العمود في 0029 — الحسابات النشطة حاليًا، والحسابات المُعطَّلة التي كانت نشطة تاريخيًا بحسب `audit_logs`؛ يترك عمدًا الحسابات المُعطَّلة بلا سجل نشاط تاريخي بلا تغيير (دعوات أُلغيت، لا فرق عن حساب لم يُزوَّد أبدًا) |
| 0033 | `permission_override_identity_lock.sql` | يقفل هوية `user_permission_overrides`: `user_id`/`permission_id` غير قابلين للتغيير عبر `UPDATE` بعد الإدراج (حتى لأمام Super Admin) — فقط `effect`/`reason` قابلان للتعديل؛ يمنع نقل استثناء من مستخدم لآخر أو من صلاحية حسّاسة لغير حسّاسة عبر تحديث الهوية بدل حذف/إعادة إنشاء |
| 0034 | `store_scope_effective_access_delegation.sql` | يُكمل تفويض نطاق المتجر ليغطي تغييرات `store_access_scope` وحدها (بلا تغيير `default_store_id`) — يحسب الأثر الفعلي (Effective Access) قبل/بعد التغيير الكامل ويرفض أي متجر يدخل أو يخرج من الوصول الفعلي لمستهدَف كان خارج نطاق تشغيل الفاعل |
| 0035 | `store_access_management_scope_completion.sql` | يُكمل UI/DB flow لـ`users.manage_store_access`: مصدر جديد `manageable_stores_for_actor()` (لا يعتمد على `stores.view`)، استبدال ذرّي مُعدَّل يترك متاجر خارج نطاق الفاعل بلا تغيير بدل فشل العملية بالكامل، وسياسة `SELECT` أضيق على `user_store_access` |
| 0036 | `invite_lifecycle_hardening.sql` | يُغلق مسار `pending_setup → suspended` أمام أي فاعل غير موثوق (لا يعود "إلغاء دعوة" ممكنًا عبر التعطيل) — الإلغاء الآن حذف فعلي لحساب Auth غير المزوَّد عبر Server Action موثوق (انظر الملحق الرابع، بند 5) |
| 0037 | `store_access_permission_separation.sql` | يفصل `users.manage_store_access` نهائيًا عن `users.manage_permissions`: يحذف سياستَي `INSERT`/`DELETE` الأصليتين (0010) اللتين كانتا تمنحان أي حامل `users.manage_permissions` الكتابة على `user_store_access`، ويضيف فحصًا صريحًا لـ`users.manage_store_access` داخل `enforce_store_access_delegation()` نفسها (استقلالًا عن أي سياسة RLS) — انظر الملحق الخامس، بند 1 |
| 0038 | `invite_cancel_audit_event.sql` | دالة جديدة `log_user_invite_cancel(p_target_user_id, p_reason)` — تُنشئ حدث Audit مستقل `user.invite_cancel` منسوبًا للفاعل الحقيقي (`auth.uid()` تحت جلسته هو)، بشرط `users.disable` وأن يكون الهدف دعوة `pending_setup` غير مكتملة فعليًا — انظر الملحق الخامس، بند 3 |
| 0039 | `invite_cancel_trusted_only.sql` | يُلغي `EXECUTE` على `log_user_invite_cancel(uuid, text)` من `authenticated` نهائيًا (الدالة تبقى موجودة، SUPERSEDED فقط)، ويضيف `log_user_invite_cancel_trusted(p_actor_user_id, p_target_user_id, p_reason)` — `service_role`-only، تُستدعى بعد نجاح `admin.auth.admin.deleteUser()` فقط، وتشترط وجود صف `user.delete` مطابق فعليًا للهدف نفسه + تحقق مستقل من `users.disable` للفاعل — بفهرس فريد جزئي يجعل التسجيل idempotent — انظر الملحق السادس |

---

## 4) الجداول والعلاقات

**`profiles`** — امتداد `auth.users` (id متطابق كمفتاح أساسي وأجنبي معًا).
`id (PK, FK→auth.users)`, `full_name`, `email` (مُكرَّر عمدًا من auth.users لتفادي join دائم في القراءات الشائعة — مُوثَّق في الكود، **وأصبح غير قابل للتعديل مباشرة منذ 0021**، انظر الملحق الثاني)، `status (active|suspended|pending_setup)`, `store_access_scope (all|multiple|single)`, `default_store_id (FK→stores, nullable)`, `provisioned_at (timestamptz, nullable — جديد في 0029، انظر الملحق الثالث)`, `created_by/updated_by (FK→profiles, self-ref، مُثبَّتان على القيم الحقيقية منذ 0021)`, `last_login_at`, timestamps.

> **تحصين إضافي (0029 — Foundation Hardening 1.3):** `provisioned_at` علامة دائمة ومستقلة تمامًا عن `status` — تُضبَط مرة واحدة فقط، إما بواسطة `finalize_new_user_profile()` أو من سياق Bootstrap موثوق، ولا يمكن لأي عميل تزويرها مباشرة. أي انتقال إلى `status='active'` بدون `provisioned_at` مضبوط يُرفَض على مستوى Trigger — يُغلق هذا مسار التفافٍ كان لا يزال ممكنًا حتى بعد 0019: حساب `pending_setup` يمكن نقله إلى `suspended` (تعطيل عادي) ثم إلى `active` (إعادة تفعيل عادية) دون أن يمر أبدًا عبر `finalize_new_user_profile()`، متجاوزًا `users.create` كليًا — لأن لا شيء في 0019 كان يمنع الحلقة الثانية تحديدًا (`suspended → active` ليست `pending_setup → active`).

> **إصلاح ترقية تاريخية (0032 — Foundation Hardening 1.4):** 0029 أضافت العمود ومنعت أي حساب **جديد** من الوصول لـ`active` بلا `provisioned_at` — لكنها لم تملأ العمود للحسابات **الموجودة أصلًا** قبل إضافته، فتركت كل حساب نشط من قبل 0029 بـ`provisioned_at IS NULL` رغم أنه مُزوَّد فعليًا وليس دعوة معلَّقة. `0032` (Backfill بيانات فقط، بلا تعديل أي Trigger/دالة) يملأ العمود بأمان: الحسابات **النشطة حاليًا** تأخذ `created_at` كتقدير معقول لتاريخ التزويد، والحسابات **المُعطَّلة** التي لها دليل تاريخي في `audit_logs` على أنها كانت نشطة فعلًا (`action = 'user.update'` بقيمة `new_values->>'status' = 'active'`) تأخذ أقدم تاريخ نشاط مسجَّل لها. أما الحسابات المُعطَّلة **بلا** أي دليل نشاط تاريخي — فتُترَك عمدًا `provisioned_at IS NULL`: لا فرق عمليًا بين "دعوة أُلغيت قبل اكتمالها" و"حساب قديم لم يُفعَّل قط"، وملء هذه الحالة بتخمين (مثلًا `created_at`) كان سيزعم تزويدًا لم يحدث فعليًا. **لا يوجد أي حساب نشط حاليًا بقي بـ`provisioned_at IS NULL` بعد هذا الترحيل.**

> **تصحيح/تدقيق (0012):** `store_access_scope` له الآن دلالة صريحة ومختبرة لكل قيمة من الثلاث: `all` → كل المتاجر النشطة (بلا اعتماد على أي جدول ربط)، `multiple` → **فقط** ما هو مُدرَج في `user_store_access`، `single` → **فقط** `default_store_id` (وليس أول صف يُصادف في أي جدول). أُضيف أيضًا قيد `CHECK` (`profiles_single_scope_requires_default_store`، `NOT VALID` ثم `VALIDATE CONSTRAINT` لتوافقه مع قاعدة بها بيانات فعلية) يمنع أن يكون مستخدم نشط (`status = 'active'`) بنطاق `single` بلا `default_store_id`، بالإضافة إلى Trigger يمنع تعيين متجر افتراضي أو منح وصول عبر `user_store_access` لمتجر غير `active`.

> **تصحيح/تدقيق (0019 — Foundation Hardening 1.2):** `status` أصبحت ثلاث قيم وليس اثنتين. **قبل 0019** كانت `suspended` تُستخدم لمعنيين متعارضين في آن واحد: "لم يكتمل تزويد الحساب بعد" (الحالة الافتراضية لصف جديد من `handle_new_auth_user()`) و"حساب حقيقي عطّله مسؤول عمدًا" — ما كان يعني أن `finalize_new_user_profile()` لا تستطيع التمييز بينهما، وأن حاملَ `users.create` كان يستطيع نظريًا "إتمام" (إعادة تفعيل) حساب مُعطَّل فعليًا عبر هذه الدالة بدل إتمام حساب جديد فقط. **بعد 0019:** `pending_setup` حالة مستقلة، لا تُضبَط إلا من سياق موثوق (Trigger إنشاء الملف الشخصي)، و`finalize_new_user_profile()` تُطابق `status = 'pending_setup'` حصرًا؛ `suspended` أصبحت محجوزة فعليًا للتعطيل المتعمَّد فقط. اختُبر صراحة: حساب كان نشطًا ثم عُطِّل (`suspended` حقيقية) لا يمكن "إتمامه" عبر `finalize_new_user_profile()` حتى من حامل `users.create`.

> **تحصين إضافي (0020 — Foundation Hardening 1.2):** حماية آخر Super Admin (0009) تمنع فقط الوصول إلى صفر Super Admin نشط؛ كانت لا تمنع مسؤولًا آخر (غير Super Admin) من تعديل/تعطيل/تجريد **أي** Super Admin **آخر** طالما بقي واحد نشط على الأقل. أُضيف الآن قيد شامل: أي تعديل على صفّ يحمل دور `super_admin` (بيانات، حالة، نطاق وصول متاجر) أو حذف دور `super_admin` منه يتطلب أن يكون الفاعل نفسه Super Admin، بصرف النظر عن عدد Super Admin المتبقّين — طبقة إضافية فوق حماية "آخر واحد"، وليست بديلة عنها. اختُبر فعليًا بوجود Super Admin نشطَين اثنين معًا.

**`roles`** — `id`, `key (unique)`, `name_ar`, `name_en`, `description_ar`, `is_system (bool)`, timestamps. الأدوار النظامية (`is_system = true`) محمية من الحذف بواسطة trigger.

**`permissions`** — `id`, `key (unique, مثل 'stores.create')`, `category`, `description_ar`, `description_en`.

**`role_permissions`** — جدول ربط `role_id ↔ permission_id`، `unique(role_id, permission_id)`.

**`user_roles`** — جدول ربط `user_id ↔ role_id` (يدعم أدوار متعددة لمستخدم واحد مستقبلًا).

**`user_permission_overrides`** — `user_id`, `permission_id`, `effect (grant|revoke)`, **PK مركّب `(user_id, permission_id)`** لمنع أي تعارض بوجود سطرين متضاربين لنفس المستخدم/الصلاحية. **منذ 0033 (Foundation Hardening 1.4):** `user_id`/`permission_id` غير قابلين للتغيير عبر `UPDATE` بعد الإدراج — حتى لأمام Super Admin — فقط `effect`/`reason` قابلان للتعديل على استثناء موجود؛ نقل استثناء من مستخدم لآخر، أو من صلاحية حسّاسة إلى غير حسّاسة (أو العكس)، يتطلب الآن حذف الاستثناء القديم وإنشاء آخر جديد صراحة (فيُعاد تفعيل فحوصات 0013/0027 الحسّاسة من الصفر بدل الالتفاف حولها عبر تحديث هوية الصف مباشرة).

**`stores`** — `id`, `code (unique)`, `name_ar`, `name_en`, `status (active|disabled)` — **تصحيح:** القيمتان الفعليتان في قيد `CHECK` هما `active`/`disabled` وليس `active`/`inactive` كما ورد خطأً في نسخة سابقة من هذا التقرير —، `logo_url`, `description`, `created_by/updated_by (مُثبَّتان على القيم الحقيقية منذ 0021)`, timestamps. **لا توجد سياسة DELETE** — التعطيل فقط عبر `status`. منذ 0014، تعديل أي عمود آخر غير `status` من مستخدم يملك `stores.disable` فقط (بدون `stores.edit`) مرفوض على مستوى Trigger، وليس فقط مخفيًا في الواجهة (تفاصيل في الملحق الأول).

> **تصحيح/تدقيق (0017 — Foundation Hardening 1.2):** تعطيل متجر (`status = 'disabled'`) يمنع اختياره **لعمليات جديدة** فقط — لا يخفيه من البيانات/التقارير التاريخية. قبل 0017 كانت دالة واحدة (`user_accessible_store_ids`) تخدم المعنيين معًا بلا تمييز، وكان لديها ثغرة إضافية: فرعا `multiple`/`single` لم يكونا يُصفِّيان أصلًا حسب حالة المتجر (متجر يُعطَّل بعد منح الوصول كان يبقى "متاحًا" لمستخدم `multiple`/`single`). الحل: `user_operable_store_ids()`/`my_operable_store_ids()` (متاجر نشطة فقط — لأي عملية تُنشئ/تُعدِّل بيانات جديدة) مقابل `user_visible_store_ids()`/`my_visible_store_ids()` (كل متجر مُنح له الوصول ولو أصبح معطَّلًا لاحقًا — للعرض التاريخي/التقارير فقط). `user_accessible_store_ids()`/`my_accessible_store_ids()` بقيتا بنفس الاسم (توافقًا مع أي كود يستدعيهما بالاسم) لكن أصبحتا غلافين رقيقين على النسخة "Operable" حصرًا.

**`user_store_access`** — `user_id ↔ store_id`، تُستخدم فقط عندما يكون `store_access_scope = 'multiple'`. **منذ 0018 (Foundation Hardening 1.2):** لا يستطيع مستخدم غير Super Admin منح/سحب وصوله الخاص لنفسه بنفسه، ولا تفويض وصول لمتجر لا يملك هو نفسه صلاحية العمل عليه (`user_operable_store_ids`) — تفاصيل كاملة في الملحق الثاني. **منذ 0034 (Foundation Hardening 1.4):** حدّ التفويض يغطي الآن **الأثر الفعلي الكامل** لتغيير `store_access_scope` وحده (بلا تغيير `default_store_id`)، وليس فقط `INSERT`/`DELETE` المباشرين على هذا الجدول أو تغيير `default_store_id` نفسه (0025) — انظر الملحق الرابع، بند 3. **منذ 0035:** سياسة `SELECT` الخاصة بـ`users.manage_store_access` (0028) أصبحت مقصورة على نطاق تشغيل الفاعل نفسه، لا كل صف في الجدول. **منذ 0037 (Patch 1.4.1):** سياستا `INSERT`/`DELETE` الأصليتان من 0010 (اللتان كانتا تمنحان الكتابة أيضًا لأي حامل `users.manage_permissions`، عن غير قصد) حُذفتا؛ الكتابة على هذا الجدول أصبحت مقصورة حصرًا على `users.manage_store_access`، بفحص إضافي صريح داخل `enforce_store_access_delegation()` نفسها — انظر الملحق الخامس، بند 1.

**`audit_logs`** — `id`, `user_id (nullable — لتسجيل محاولات دخول فاشلة قبل المصادقة)`, `action`, `entity_type`, `entity_id`, `old_values (jsonb)`, `new_values (jsonb)`, `reason`, `ip_address`, `user_agent`, `created_at`.

**`system_settings`** — `category`, `key`, `value (jsonb)`, `unique(category, key)`.

**علاقات المفاتيح الأجنبية الأساسية:**
`profiles.default_store_id → stores.id` (SET NULL عند حذف/تعطيل) · `user_roles.user_id/role_id` (CASCADE عند حذف المستخدم، RESTRICT عند محاولة حذف دور مُسنَد) · `user_permission_overrides.*` (CASCADE) · `user_store_access.*` (CASCADE) · `audit_logs.user_id → profiles.id` (SET NULL — **لا نحذف سجل التدقيق أبدًا حتى لو حُذف المستخدم لاحقًا**).

**فهارس:** فهرس فريد على `lower(profiles.email)`، فهارس على كل عمود FK يُستخدم في فلاتر متكررة (`audit_logs.user_id`, `audit_logs.entity_type`, `audit_logs.created_at`, `user_roles.user_id`, إلخ) لتفادي فحص جدولي كامل عند التوسع.

---

## 5) سياسات RLS والدوال الأمنية

> **هذا القسم مُحدَّث بالكامل ليعكس حالة الكود بعد المراجعة الأمنية المستقلة (0012–0016). التفاصيل الكاملة لكل إصلاح — بما فيها الثغرات الفعلية التي اكتُشفت أثناء الاختبار وليس نظريًا فقط — موجودة في الملحق آخر هذا الملف.**

**الدوال الجوهرية (`0008_permission_functions.sql`، مُحدَّثة صلاحيات التنفيذ عليها في 0015):**

- `is_active_user(uuid) → boolean` — المستخدم موجود وحالته `active`. **منذ 0015: `service_role` فقط** (لم تعد `authenticated` قادرة على استدعائها بمعرّف تعسفي).
- `is_super_admin(uuid) → boolean` — هل لدى المستخدم دور `super_admin`. **منذ 0015: `service_role` فقط.**
- `get_user_permissions(uuid) → setof text` — **مصدر الحقيقة الوحيد**: صلاحيات الأدوار ∪ الاستثناءات الممنوحة (grant) − الاستثناءات الملغاة (revoke)، مع فلترة أن المستخدم نشط. **منذ 0015: `service_role` فقط.**
- `has_permission(text) → boolean` — يُستخدم مباشرة داخل سياسات RLS، يعتمد داخليًا على `auth.uid()` فلا يأخذ معرّف مستخدم كوسيط أصلًا، فبقي متاحًا لـ `authenticated`. Super Admin يمر تلقائيًا (short-circuit) دون الحاجة لصفوف صريحة.
- `user_accessible_store_ids(uuid) → setof uuid` — أُعيدت كتابتها بالكامل في 0012 لتفريع صريح حسب القيمة الفعلية لـ `store_access_scope` (`all`/`multiple`/`single`) بدل استعلام واحد يفترض ضمنيًا سلوكًا موحّدًا. **منذ 0015: `service_role` فقط. منذ 0017 (Foundation Hardening 1.2): أصبحت غلافًا مستقر الاسم فقط حول `user_operable_store_ids(uuid)` — انظر الفقرة التالية.**
- `user_operable_store_ids(uuid) / user_visible_store_ids(uuid) → setof uuid` — **جديدتان (0017، Foundation Hardening 1.2).** الأولى: متاجر نشطة فقط، لأي عملية جديدة (هذا ما كانت `user_accessible_store_ids` تعنيه دائمًا، وأصبحت الآن الاسم الرسمي له). الثانية: كل متجر مُنح له الوصول ولو أصبح معطَّلًا لاحقًا، للعرض التاريخي/التقارير فقط — تعطيل متجر لا يمحوه من تاريخ من كان يراه. **منذ 0015/0017: `service_role` فقط.**

**الأغلفة ذاتية النطاق الجديدة (0015، وسّعتها 0017) — ما يستدعيه التطبيق فعليًا الآن بدل الدوال أعلاه:**

- `get_my_permissions()`, `am_i_super_admin()`, `my_accessible_store_ids()` — كل واحدة تُصرَّح لـ `authenticated` وتُحلّ داخليًا دائمًا مقابل `auth.uid()` للجلسة الحالية فقط، فلا يوجد أي وسيط `uuid` يمكن لمستخدم تمرير معرّف غيره فيه. هذا يغلق ثغرة إفصاح معلومات كانت موجودة فعليًا (انظر الملحق الأول: أي مستخدم موثَّق كان يستطيع قراءة صلاحيات/حالة Super Admin/متاجر أي مستخدم آخر عبر RPC مباشر بمعرّفه).
- `my_operable_store_ids()` / `my_visible_store_ids()` — **جديدتان (0017)**، نفس مبدأ الأغلفة أعلاه، مقابل `user_operable_store_ids`/`user_visible_store_ids`. `my_accessible_store_ids()` بقيت باسمها لكن أصبحت غلافًا حول `my_operable_store_ids()`.
- `log_audit_event(...) → uuid` — **تصحيح جوهري:** لم تعد مُصرَّحة لـ `authenticated` ولا لـ `anon` إطلاقًا منذ 0016 (كانت كذلك في التسليم الأول، وهذا بالضبط ما استغلّه سيناريو الاختبار الذي كشفته المراجعة). أصبحت `service_role` فقط، ويستخدمها مسار خادم واحد فقط (تسجيل محاولة دخول فاشلة، عبر عميل إداري من كود الخادم حصرًا، مع تحديد المعدّل).
- ~~`log_auth_event(p_action text) → uuid`~~ — دالة (0016) بقائمة بيضاء صارمة (`auth.login_success`/`auth.logout` فقط)، `SECURITY DEFINER`، كانت مُصرَّحة لـ `authenticated`. **مُستبدَلة منذ 0023 (Foundation Hardening 1.2):** كان أي مستخدم موثَّق يستطيع استدعاءها بنفسه في أي وقت (وليس فقط عقب دخول/خروج حقيقي) لتلفيق سجل زمني مزيَّف لدخوله/خروجه — `REVOKE ... FROM authenticated` عليها الآن (لم تُحذف، للحفاظ على تاريخها)، والدالة الفعلية المستخدَمة هي `log_auth_event_trusted(p_user_id uuid, p_action text)`، `service_role` فقط، تُستدعى من `src/features/auth/actions.ts` عبر العميل الإداري **بعد** التحقق الفعلي من الجلسة على الخادم.
- `finalize_new_user_profile(...)` — دالة جديدة (0016) تُنهي إنشاء مستخدم جديد (من `pending_setup` إلى `active` + إسناد البيانات، **كانت من `suspended` قبل 0019** — انظر تصحيح القسم 4) بشرط امتلاك المنفّذ لصلاحية `users.create`، وتفشل بوضوح إن استُدعيت على ملف مُفعّل بالفعل أو مُعطَّل فعليًا (انظر الملحق الأول، بند 6، لكيفية استخدامها في معالجة فشل إنشاء المستخدم الجزئي، والملحق الثاني لاختبار منع إعادة تفعيل حساب `suspended` حقيقي).

**كل دالة `SECURITY DEFINER` مذكورة في هذا القسم (وكل الدوال المُشغِّلة للـ Triggers) خضعت في 0015 لـ `REVOKE EXECUTE ... FROM PUBLIC` صريح**، بعدما تبيّن أثناء الاختبار أن Postgres يمنح `EXECUTE` لـ `PUBLIC` تلقائيًا عند الإنشاء ما لم يُسحَب صراحة — وهذا لم يكن مطبَّقًا في أي دالة من الأساس الأول.

**نموذج من السياسات (`0010_rls_policies.sql`، لم تتغيّر بنيتها، لكن أُضيف فوقها Triggers جديدة):**

- `profiles_select` — كل مستخدم نشط يرى صفّه، ومن لديه `users.view` يرى الجميع.
- `profiles_update` — يتطلب `has_permission('users.edit')` أو `has_permission('users.disable')`. **منذ 0014:** RLS وحدها كانت تسمح لصاحب `users.disable` فقط بتعديل الصف كاملًا (ليس فقط `status`) عبر أي استدعاء REST مباشر؛ الآن Trigger (`enforce_profile_update_column_authorization`) يقارن كل عمود OLD/NEW ويرفض أي تغيير خارج `status` لهذا الدور تحديدًا، بصرف النظر عن العميل المستخدم. **منذ 0018 (Foundation Hardening 1.2):** سياسة إضافية `profiles_update_store_access` تفتح مسارًا موازيًا لحاملي `users.manage_store_access` تحديدًا لعمودي `store_access_scope`/`default_store_id` فقط — و`enforce_profile_update_column_authorization` نفسها أُعيد تعريفها من 0018 لتتعرّف على هذا المسار الثالث (كانت سترفضه خطأً برسالة "لا تملك صلاحية تعديل بيانات المستخدمين" قبل أن يصل التنفيذ إلى القيود الأدق في `enforce_store_scope_authorization`).
- `stores_select/insert/update` — مبنية على `stores.view/create/edit` — **بدون** سياسة `DELETE` إطلاقًا. نفس فصل الأعمدة أعلاه مطبَّق على `stores.disable` منذ 0014.
- `audit_logs_select` — يتطلب `audit_logs.view`. **لا توجد سياسات insert/update/delete على الإطلاق لأي دور عميل** — الكتابة الآن تتم حصرًا عبر Triggers قاعدة بيانات تلقائية (0016)، وليس عبر أي RPC يستطيع عميل استدعاءه (انظر الملحق، بند 5).
- `system_settings_select_public` — تُتاح فئتا `general` و`appearance` لـ `anon` و`authenticated` معًا (لعرض اسم النظام/الشعار قبل تسجيل الدخول)، بينما فئة `security` محمية بصلاحية `settings.manage`.

**Triggers الحماية (`0009_protection_triggers.sql` + إضافات 0012–0014):**

- `protect_last_super_admin()` — يمنع حذف/تعطيل/تجريد آخر Super Admin نشط في النظام.
- `prevent_super_admin_privilege_escalation()` — يمنع أي مستخدم من إسناد دور `super_admin` لنفسه أو لغيره عبر الواجهة؛ يُسمح بذلك فقط عبر سياق موثوق (انظر `is_trusted_bootstrap_context()` في الملحق الأول). **أُعيد تعريفها في 0013** (عبر `CREATE OR REPLACE` من ترحيل جديد، دون تعديل ملف 0009 نفسه) بشرط استثناء أدق — كانت شرط `auth.role() = 'service_role'` وحده يمنع `supabase/seed.sql` نفسه من العمل في بيئة اختبار محلية، فاتضح أن التعريف الأول لم يكن مكتملًا للحالات غير-PostgREST.
- `protect_system_role_identity()` — يمنع تعديل/حذف `key` أو `is_system` للأدوار النظامية الستة الافتراضية.
- **(0013) مجموعة Triggers منع التصعيد:** تمنع أي مستخدم (غير Super Admin) من تعديل أدواره/استثناءاته الخاصة بنفسه على `user_roles`/`user_permission_overrides`، ومن منح صلاحية لا يملكها هو نفسه، ومن إسناد أي دور أو صلاحية تتضمن `users.manage_permissions`/`settings.manage`/`backups.manage` إلا بواسطة Super Admin فعليًا — حتى لو كان المانح يملك تلك الصلاحية الحسّاسة بالذات.
- **(0014) `enforce_profile_update_column_authorization` / `enforce_store_update_column_authorization`:** فصل عمودي بين صلاحية "تعديل" وصلاحية "تعطيل" (تفاصيل أعلاه).

**Triggers/دوال إضافية من Foundation Hardening 1.2 (0017–0024 — التفاصيل الكاملة في الملحق الثاني):**

- `enforce_store_scope_authorization` (0018) — يمنع تعديل `store_access_scope`/`default_store_id` الخاص بالفاعل نفسه، ويشترط `users.manage_store_access` تحديدًا لتعديلهما لغيره، ويقصر `scope='all'` على Super Admin حصرًا. مُرفَق بإعادة تعريف لدالة 0014 (`CREATE OR REPLACE` من داخل 0018، دون تعديل ملف 0014 نفسه) لتتعرّف على مسار `users.manage_store_access` الجديد.
- `enforce_store_access_delegation` (0018) — يمنع منح/سحب `user_store_access` الخاص بالفاعل نفسه، ويحدّ تفويض وصول لغيره بما يملكه المانح نفسه فعليًا (`user_operable_store_ids`).
- `replace_user_store_access(uuid, uuid[])` (0018) — استبدال ذرّي بالكامل لصفوف وصول متاجر مستخدم (دفعة واحدة تنجح كليًا أو تفشل كليًا)، `SECURITY INVOKER` عمدًا لتخضع لكل قيود RLS/Triggers أعلاه تمامًا كأي استدعاء REST مباشر.
- `enforce_pending_setup_transition` (0019) — يشترط `users.create` تحديدًا للانتقال من `pending_setup` إلى `active`، ويمنع الانتقال إلى `pending_setup` إلا من سياق موثوق.
- `protect_super_admin_profile` / `protect_super_admin_role_removal` (0020) — حماية شاملة لأي Super Admin من أي فاعل ليس Super Admin، بصرف النظر عن عدد المتبقّين.
- `enforce_profile_email_immutable` / `enforce_system_managed_columns` / `enforce_created_by_immutable` (0021) — قفل `profiles.email`، وتثبيت `created_at`/`created_by`/`updated_at`/`updated_by` على القيم الحقيقية بصمت.
- `enforce_role_system_identity` (0022) — يمنع إنشاء/ترقية دور إلى `is_system=true` من سياق تطبيقي، ويقفل `roles.key`.
- `log_auth_event_trusted(uuid, text)` (0023) — بديل `service_role` فقط لـ `log_auth_event(text)`، يُستدعى من كود خادم بعد تحقق فعلي من الجلسة.
- `audit_table_changes()` (0024) — أُعيدت تعريفها لإنتاج `.create`/`.update`/`.delete` بدل `lower(TG_OP)` الخام.

**Triggers/دوال إضافية من Foundation Hardening 1.4 (0032–0036 — التفاصيل الكاملة في الملحق الرابع):**

- `enforce_permission_override_identity` (0033) — يقفل `user_id`/`permission_id` على `user_permission_overrides` من التعديل عبر `UPDATE` بعد الإدراج؛ فقط `effect`/`reason` قابلان للتغيير على استثناء موجود.
- `resolve_operable_stores(text, uuid, uuid)` (0034) — دالة مساعدة تُعيد مجموعة المتاجر النشطة التي يُحلّها تركيب افتراضي (`scope`, `default_store_id`, `user_id`) معطى كوسائط صريحة، بدل قراءتها من الصف الحالي — تُستخدم لحساب الوصول الفعلي (Effective Access) لكل من القيمة القديمة والجديدة داخل نفس Trigger `BEFORE UPDATE`.
- `enforce_store_scope_authorization` (أُعيدت من 0018/0025/0030، `CREATE OR REPLACE` من 0034) — أُضيف فحص فرق الوصول الفعلي الكامل: أي متجر يدخل أو يخرج من الوصول الفعلي لمستهدَف بسبب تغيير `store_access_scope` وحده (بلا تغيير `default_store_id`) يجب أن يكون ضمن نطاق تشغيل الفاعل، وإلا فالعملية مرفوضة.
- `manageable_stores_for_actor()` (0035) — مصدر جديد ذاتي النطاق: المتاجر التي يستطيع الفاعل الحالي إدارة وصولها، مقصور على `users.manage_store_access` ونطاق تشغيله (أو كل متجر نشط لـSuper Admin)، بلا اعتماد على `stores.view` إطلاقًا.
- `replace_user_store_access` (أُعيدت من 0018، `CREATE OR REPLACE` من 0035) — مرشحو الحذف خارج نطاق تشغيل الفاعل (وليس Super Admin) يُترَكون بلا تغيير الآن بدل مُحاوَلة حذفهم وفشل العملية بالكامل بسببهم.
- سياسة `user_store_access_select_scoped` (أُعيدت من 0028، `DROP`+`CREATE` من 0035) — ضُيِّقت لتقتصر على نطاق تشغيل حامل `users.manage_store_access` نفسه، بدل كل صف في الجدول.
- `enforce_pending_setup_transition` (أُعيدت من 0019، `CREATE OR REPLACE` من 0036) — الانتقال `pending_setup → <أي حالة غير active>` مرفوض الآن لأي فاعل غير موثوق بالكامل، لا فقط `pending_setup → active` بلا `users.create`.

**تحقّق فعلي (وليس نظريًا):** أُعيدت كتابة اختبار التكامل SQL بالكامل (`supabase/tests/rls_and_permissions.test.sql`) بعد المراجعة الأولى، ثم وُسِّع مجددًا (الأقسام 12–17) بعد Foundation Hardening 1.2، ومجددًا (الأقسام 18–24) بعد Foundation Hardening 1.3، ومجددًا (الأقسام 25–29) بعد Foundation Hardening 1.4، ومجددًا (الأقسام 30–32) بعد Patch 1.4.1، ومجددًا أخيرًا (تحديث الأقسام 32.4/32.5 + قسم 33 جديد) بعد Foundation Audit Hotfix 1.4.2، وشُغِّل من الصفر (إعادة بناء قاعدة الاختبار كاملة + كل الترحيلات الـ39 + `seed.sql` + الاختبار) عدة مرات أثناء كل إصلاح إلى أن اجتاز بالكامل بدون أي خطأ. يغطي الآن 33 قسمًا: حساب `user_accessible_store_ids()` للحالات الثلاث فعليًا (بمتاجر ومستخدمين حقيقيين، وليس على جدول فارغ)، عزل RLS بعد وجود بيانات فعلية، تصعيد الصلاحيات الذاتي على الجداول الثلاثة، الفصل العمودي لـ `disable`، قفل الدوال ذات المعرّف التعسفي، ثقة سجل التدقيق (بما فيها التحقق من الصف عبر سياق يتجاوز RLS بدل اعتماد رؤية الفاعل نفسه له)، `finalize_new_user_profile` (بما فيها منع إعادة تفعيل حساب `suspended` حقيقي)، قيود اتساق نطاق المتجر، حماية آخر Super Admin، **(Foundation Hardening 1.2):** فصل الرؤية التاريخية عن التشغيلية، تصعيد/تفويض نطاق المتجر والاستبدال الذرّي، حماية Super Admin بوجود اثنين نشطين، قفل الأعمدة المُدارة نظاميًا (بما فيها البريد الإلكتروني)، قفل `roles.is_system`/`key`، وتسمية إجراءات Audit، **(Foundation Hardening 1.3):** إغلاق تفويض نطاق المتجر بالكامل، استقلالية `SELECT` لـ`users.manage_store_access`، تفويض الأعمدة كصلاحيات مستقلة، إغلاق مسار الالتفاف حول التزويد، حماية الصلاحيات الحسّاسة على مسار السحب، حماية Super Admin ككيان كامل، وفشل آمن لدوال نطاق المتجر لحساب غير نشط، **(Foundation Hardening 1.4):** ترقية `provisioned_at` للحسابات القديمة، قفل هوية `user_permission_overrides`، إكمال تفويض نطاق المتجر لتغييرات `store_access_scope` وحدها، إكمال UI/DB flow لـ`users.manage_store_access` (مصدر متاجر مخصَّص + استبدال ذرّي مُحسَّن + سياسة `SELECT` أضيق)، وإصلاح دورة حياة الدعوات الملغاة، **(Patch 1.4.1):** الفصل الكامل بين `users.manage_store_access`/`users.manage_permissions` على كل مسار (RLS + Trigger + RPC)، إثبات السبب الجذري لعطل تحميل Store Access في الواجهة، وتمايز `user.invite_cancel`/`user.delete` كحدثين منفصلين، **وأخيرًا (Foundation Audit Hotfix 1.4.2):** إغلاق EXECUTE على `log_user_invite_cancel()` أمام `authenticated` نهائيًا (يفشل الآن بـ`insufficient_privilege` حتى لحامل `users.disable`)، مسار تسجيل جديد `service_role`-only بعد الحذف الفعلي فقط، منع تسجيل الحدث أكثر من مرة لنفس الهدف (فهرس فريد جزئي)، وإثبات أن الحذف يسبق التسجيل دائمًا. **أثناء التشغيل الفعلي لكل المراجعات الأربع وPatch 1.4.1 وHotfix 1.4.2 اكتُشفت وأُصلحت ثغرات/انحدارات حقيقية** لم تكن لتُكتشف بدون اختبار فعلي ضد بيانات حقيقية — تفاصيلها في الملاحق الستة.

---

## 6) الصلاحيات المُنشأة

36 صلاحية موزعة على 9 تصنيفات، مبنية على النمط `<module>.<action>` (بحيث لا يُكتب أي فحص صلاحية في الكود بالاعتماد على اسم الدور مطلقًا — فقط `hasPermission('key')`):

`dashboard.*` (view, view_financials) · `stores.*` (view, create, edit, disable) · `users.*` (view, create, edit, disable, manage_permissions, **manage_store_access — جديدة في 0018**) · `reports.*` (view, export_pdf, export_excel) · `gold_prices.*` (view, edit) · `sales.*` (view, create, edit, edit_closed_day, view_profit) · `returns.*` (view, create, approve) · `settlements.*` (view, manage) · `shipments.*` (view, create, update_status) · `adjustments.*` (view, create, approve) · `audit_logs.*` (view) · `settings.manage` · `backups.manage`.

> **`users.manage_store_access` (0018 — Foundation Hardening 1.2):** صلاحية مخصَّصة لتعديل نطاق وصول متاجر مستخدم (`store_access_scope`/`default_store_id`) ومنح/سحب صفوف `user_store_access` — عمدًا **منفصلة** عن `users.edit` العامة، لأن نطاق الوصول للمتاجر حدٌّ أمني بحد ذاته (يقرر أي بيانات أعمال سيصل إليها المستخدم لاحقًا في المبيعات/التقارير)، لا يجب أن يُفتَح تلقائيًا لكل من يملك تعديل الملف الشخصي العام. مُمنوحة افتراضيًا لأدوار `super_admin`/`admin`. حتى حاملها لا يستطيع تعديل نطاقه الخاص بنفسه، ولا ضبط `scope='all'` لغيره ما لم يكن هو نفسه Super Admin — التفاصيل الكاملة والاختبارات في الملحق الثاني.

> ملاحظة: `shipments.*` و`adjustments.*` إضافتان مني على القائمة المذكورة في المواصفة، موثّقتان في `seed.sql` كتوسعة منطقية لأن الشحن والتسويات/الخدمات مذكورة في هيكل التنقل المطلوب.

**الأدوار الافتراضية الستة** (كلها `is_system = true`، قابلة للتوسعة بأدوار مخصصة إضافية من الواجهة): Super Admin (كل الصلاحيات + استثناء من فحص الصلاحيات بالكامل) · Admin · Supervisor · Accountant · Sales Employee · Shipping Employee — كل دور مربوط بمجموعة صلاحيات منطقية عبر `role_permissions` في `seed.sql`.

---

## 7) الصفحات العاملة فعليًا

| المسار | الوصف | الحالة |
|---|---|---|
| `/login` | تسجيل دخول (بريد/كلمة مرور، إظهار/إخفاء كلمة المرور، تذكرني، رسائل خطأ عربية آمنة) | ✅ فعّالة بالكامل |
| `/dashboard` | لوحة تحكم تأسيسية: عدد المستخدمين النشطين، عدد المتاجر، آخر نشاط، إجراءات سريعة حسب الصلاحية | ✅ فعّالة بالكامل |
| `/stores` | قائمة/بحث/فلترة حالة/إضافة/تعديل/تعطيل متاجر | ✅ فعّالة بالكامل |
| `/users` | قائمة المستخدمين + إدارة الأدوار وصلاحياتها | ✅ فعّالة بالكامل |
| `/users/[id]` | تفاصيل مستخدم: تعديل، تعيين دور، استثناءات صلاحيات فردية، تعطيل | ✅ فعّالة بالكامل |
| `/audit-log` | سجل التدقيق مع بحث/فلاتر (مستخدم، نوع الإجراء، تاريخ، الكيان) وعرض الفروقات | ✅ فعّالة بالكامل |
| `/settings` | إعدادات عامة/مظهر/أمان | ✅ فعّالة بالكامل |
| `/sales`, `/returns`, `/shipments`, `/adjustments`, `/settlements`, `/reports`, `/gold-prices` | صفحات "قريبًا" ضمن هيكل التنقل الكامل | 🔜 محجوزة معماريًا فقط (كما طُلب) |
| `/403` | صفحة رفض وصول عند نقص الصلاحية | ✅ فعّالة بالكامل |

---

## 8) الملفات المهمة في المشروع

- `src/lib/permissions/{constants,guard,session,resolve,context}.tsx|ts` — نواة نظام الصلاحيات (تعريف المفاتيح، `requirePermission()` للخادم، `usePermissions()`/`<Can>` للعميل). **مُحدَّث بعد المراجعة الأولى:** `session.ts` يستدعي الآن `get_my_permissions()`/`am_i_super_admin()` (الأغلفة ذاتية النطاق) بدل `get_user_permissions(uuid)`/`is_super_admin(uuid)` المقفلتين الآن على `service_role`. **مُحدَّث في Foundation Hardening 1.2:** `constants.ts` يتضمن الآن `users.manage_store_access`.
- `src/lib/audit/log-failed-login.ts` — **جديد**، يحل محل `src/lib/audit/log.ts` المحذوف. يسجّل محاولة دخول فاشلة عبر عميل إداري (`service_role`) فقط، بتحديد معدّل (10 محاولات/15 دقيقة لكل حساب مُحلَّل)، ودون تخزين البريد الإلكتروني نفسه كنص حر في عمود `reason`.
- ~~`src/lib/audit/log.ts`~~ — **محذوف**. كان غلافًا لاستدعاء `log_audit_event()` من `authenticated`/`anon`، وهو المسار الذي أُغلق في 0016 لأن سجل التدقيق أصبح يُكتب تلقائيًا عبر Triggers على كل جدول حسّاس (انظر الملحق الأول، بند 5) بدل نداء صريح من كل Server Action.
- `src/lib/action-result.ts` — **مُحدَّث في Foundation Hardening 1.2:** أُضيفت `dbErrorMessage()` لعرض رسالة خطأ Postgres الحقيقية للعميل فقط عندما يكون كودها من مجموعة أكواد الاستثناءات المتعمَّدة في هذا المشروع نفسه (`P0001`/`P0002`/`42501`)، بدل فحوصات نصية متفرّقة (`error.message.includes(...)`) كانت مبعثرة عبر عدة ملفات `actions.ts`.
- `src/lib/supabase/{client,server,admin,middleware}.ts` — عملاء Supabase منفصلون بوضوح: متصفح، خادم (مربوط بالجلسة)، إداري (service role — خادم فقط، غير مصدَّر للمتصفح أبدًا)، ووسيط تحديث الجلسة.
- `src/proxy.ts` — الوسيط (middleware سابقًا، أُعيدت تسميته بحسب كسر توافق Next.js 16) لتحديث/حماية الجلسة على المسارات المحمية.
- `src/features/users/actions.ts` — **مُحدَّث بعد المراجعة الأولى:** `createUserAction` أصبحت تستدعي `finalize_new_user_profile()` عبر عميل الجلسة العادي (وليس الإداري) بعد إنشاء مستخدم Auth، مع منطق تعويض صريح (حذف مستخدم Auth الذي أُنشئ) إن فشل هذا التفعيل، بدل ترك حساب Auth بلا ملف مكتمل صامتًا (انظر الملحق الأول، بند 6). **مُحدَّث في Foundation Hardening 1.2:** `setUserStoreAccessAction` تستدعي الآن `replace_user_store_access()` (استبدال ذرّي واحد) بدل إدراج ثم حذف منفصلين، وتتطلب `users.manage_store_access` أو `users.manage_permissions`. **مُحدَّث في Foundation Hardening 1.4:** أُضيفت `cancelUserInviteAction(userId)` — تعيد التحقق من الحالة على الخادم (`status === 'pending_setup' && provisioned_at === null`) ثم تحذف مستخدم Auth غير المزوَّد فعليًا عبر العميل الإداري (`admin.auth.admin.deleteUser`)، فتُحذَف صف `profiles` تلقائيًا معه (`ON DELETE CASCADE`) — بدل نقل الحساب إلى `suspended` (المسار القديم الذي أصبح مرفوضًا الآن على مستوى القاعدة، انظر الملحق الرابع بند 5). **مُحدَّث في Patch 1.4.1:** `setUserStoreAccessAction` تتطلب الآن `users.manage_store_access` حصرًا (لم تعد `requireAnyPermission(["users.manage_permissions", "users.manage_store_access"])`) — القاعدة كانت سترفض حامل `users.manage_permissions` فقط في كل الأحوال بعد 0037، فهذا التضييق يُظهر رسالة الخطأ الصحيحة فورًا بدل خطأ قاعدة بيانات عام. `cancelUserInviteAction` أصبحت تستدعي `log_user_invite_cancel()` (0038) عبر عميل الجلسة العادي (بحيث يُلتقَط `auth.uid()` الحقيقي للفاعل) **قبل** استدعاء `admin.auth.admin.deleteUser()` على العميل الإداري — لا بعده، لأن الحذف عبر العميل الإداري لا يحمل هوية الفاعل إطلاقًا؛ انظر الملحق الخامس، بند 3. **مُحدَّث في Foundation Audit Hotfix 1.4.2:** أُعيد ترتيب الدالة بالكامل — `actorUserId` يُلتقَط أولًا من جلسة الفاعل الموثَّقة (`requirePermission("users.disable")`) **قبل** لمس العميل الإداري إطلاقًا؛ ثم `admin.auth.admin.deleteUser()` يُنفَّذ **أولًا**؛ **فقط بعد** نجاح الحذف فعليًا تُستدعى `log_user_invite_cancel_trusted()` (0039) عبر العميل الإداري بـ`actorUserId` الملتقَط سلفًا و`userId` كهدف — انظر الملحق السادس.
- `src/features/users/components/user-status-toggle.tsx` — **مُحدَّث في Foundation Hardening 1.4:** فرع `pending_setup` يستدعي الآن `cancelUserInviteAction` بدل `setUserStatusAction(userId, "suspended")`، مع تحذير صريح في نص التأكيد بأن الحذف نهائي، وإعادة توجيه لقائمة المستخدمين بعد النجاح (الصف لم يعد موجودًا).
- `src/features/users/queries.ts` — **مُحدَّث في Foundation Hardening 1.4:** أُضيفت `listManageableStoresForActor()` — تستدعي `manageable_stores_for_actor()` (0035) بدل `listActiveStoresForSelect()` (مصدر `stores.view`-gated الكامل) لتغذية نموذجي نطاق المتجر ووصول المتاجر في `src/app/(app)/users/[id]/page.tsx`. **مُحدَّث في Patch 1.4.1:** `getUserDetail()` أصبحت تجلب `store_id` الخام فقط من `user_store_access` (بلا `store:stores(...)` مُضمَّن) — انظر الملحق الخامس، بند 2 لسبب هذا التغيير تحديدًا.
- `src/features/users/store-access-helpers.ts` — **جديد (Patch 1.4.1).** دالة نقية `selectableStoreAccessIds(currentStoreIds, manageableStoreIds)` — مقاطعة (Intersection) بين وصول الهدف الفعلي (الخام، غير المُصفَّى) ونطاق تشغيل الفاعل نفسه؛ نتيجتها هي بالضبط ما يجب أن يظهر مُحدَّدًا في `UserStoreAccessEditor`. مُختبرة بستة اختبارات Vitest مستقلة عن أي اتصال قاعدة بيانات (`tests/store-access-helpers.test.ts`).
- `src/features/auth/actions.ts` — **مُحدَّث في Foundation Hardening 1.2:** `loginAction`/`logoutAction` تستدعيان `log_auth_event_trusted()` عبر العميل الإداري (`service_role`) بعد التحقق الفعلي من الجلسة، بدل `log_auth_event()` التي كانت قابلة للاستدعاء من `authenticated` مباشرة.
- `src/app/(app)/users/[id]/page.tsx` — **مُحدَّث في Patch 1.4.1:** `canManageStoreAccess` أصبحت الحارس الوحيد لكل من Store Scope وStore Access معًا (لم تعد `!canManageStoreAccess && !canManagePermissions`)، ويُستدعى `selectableStoreAccessIds()` لحساب `initiallySelected` من `store_id` الخام + `manageable_stores_for_actor()` بدل الاعتماد على `store:stores(...)` المُضمَّن سابقًا.
- `src/lib/audit/action-labels.ts` — **مُحدَّث في Patch 1.4.1:** أُضيفت تسميتان عربيتان: `user.delete` (حذف حساب مستخدم — الحدث التلقائي عبر Trigger، بلا Actor عند حذف عبر العميل الإداري) و`user.invite_cancel` (إلغاء دعوة مستخدم غير مكتمل — الحدث الجديد المنسوب للفاعل الحقيقي)، مع تعليق يوضح أنهما حدثان مقصودان ومنفصلان، وليس أحدهما تكرارًا للآخر.
- `src/types/database.ts` — أنواع TypeScript يدوية مطابقة تمامًا للسكيمة (لا توليد تلقائي لعدم توفر اتصال مباشر بمشروع Supabase فعلي أثناء البناء). **مُحدَّث** بدوال 0012–0016 (`get_my_permissions`, `am_i_super_admin`, `my_accessible_store_ids`, `log_auth_event`, `finalize_new_user_profile`) **ثم بدوال 0017–0024** (`user_operable_store_ids`, `user_visible_store_ids`, `my_operable_store_ids`, `my_visible_store_ids`, `log_auth_event_trusted`, `replace_user_store_access`)، و`ProfileStatus` أصبحت `active|suspended|pending_setup`. **مُحدَّث في Foundation Hardening 1.4:** أُضيفت `manageable_stores_for_actor` (0035) لخريطة `Functions`. **مُحدَّث في Patch 1.4.1:** أُضيفت `log_user_invite_cancel` (0038) لنفس الخريطة. **مُحدَّث في Foundation Audit Hotfix 1.4.2:** أُزيلت `log_user_invite_cancel` من الخريطة (SUPERSEDED، لم تعد تُستدعى من أي كود تطبيق)، وأُضيفت `log_user_invite_cancel_trusted` (0039) بدلًا منها — انظر الملحق السادس.
- `scripts/create-super-admin.ts` — إنشاء أول Super Admin بأمان (تفصيل في القسم 12) — **لم يتغيّر بأي من المراجعتين**، لا يزال المسار الوحيد الصحيح. (كلمة المرور كانت وما زالت تُطلَب دائمًا عبر مُطالبة تفاعلية في الطرفية — **لا يوجد ولم يوجد قط `--password`** كوسيط سطر أوامر؛ نسخة سابقة من هذا التقرير كانت تذكر مثالًا خاطئًا بهذا الوسيط، صُحِّح في القسم 12 أدناه).
- `supabase/seed.sql` — البيانات الأولية (صلاحيات/أدوار/إعدادات) — **بدون أي متجر وهمي**. **مُحدَّث في Foundation Hardening 1.2:** صلاحية `users.manage_store_access` جديدة، ومضافة لدور `admin`.
- `supabase/tests/local_harness_setup.sql` — **جديد**، يوثّق وينشئ محاكاة مخطط `auth` الخاص بـ Supabase (`auth.uid()`/`auth.role()` + الأدوار الثلاثة) على Postgres محلي، لتشغيل اختبار التكامل بشكل متكرر وقابل لإعادة الإنتاج دون مشروع Supabase حقيقي. **مُحدَّث في Foundation Hardening 1.2:** مُنح `service_role` وصولًا كاملًا لمخطط `auth`/`auth.users` (يطابق ما يملكه `service_role` فعليًا في مشروع Supabase حقيقي)، ومُنح `anon`/`authenticated` صلاحية `USAGE` على مخطط `auth` (لاستدعاء `auth.uid()` مباشرة من داخل اختبار يُحاكي فاعلًا مُوثَّقًا) — كلاهما كان ناقصًا وتسبَّب في فشل اختبارات القسمين 9/13/14 الجديدة حتى أُضيف.
- `.env.example` — قالب متغيرات البيئة بدون أي قيمة حقيقية.

---

## 9) متغيرات البيئة المطلوبة

انسخ `.env.example` إلى `.env.local` واملأ القيم من Supabase Dashboard → Project Settings → API:

```
NEXT_PUBLIC_SUPABASE_URL=https://xxxxxxxxxxxxx.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=<anon-public-key>
SUPABASE_SERVICE_ROLE_KEY=<service-role-secret-key>   # سرّي جدًا — خادم فقط
```

`SUPABASE_SERVICE_ROLE_KEY` **لا يُستخدم إلا** داخل `src/lib/supabase/admin.ts` وسكربت `create-super-admin.ts` — لم يُستورد في أي مكوّن عميل (Client Component) أو مسار يصل المتصفح. `.env.local` مُتجاهل افتراضيًا في Git (`.gitignore`).

---

## 10) خطوات التشغيل محليًا

```bash
npm install
cp .env.example .env.local     # ثم املأ القيم الحقيقية
npm run dev                     # http://localhost:3000
```

أوامر تحقق إضافية:

```bash
npm run typecheck   # فحص TypeScript
npm run lint         # ESLint
npm run test          # اختبارات Vitest
npm run build         # بناء الإنتاج
npm run format        # Prettier
```

---

## 11) خطوات ربط Supabase

1. أنشئ مشروع جديد على [supabase.com](https://supabase.com).
2. من **SQL Editor**، نفّذ ملفات `supabase/migrations/` **بالترتيب الرقمي** (0001 ثم 0002 ... حتى 0039) — كل ملف مستقل ويعتمد على سابقه. **لمشروع Supabase قائم فعلًا بترحيلات 0001–0011:** نفّذ 0012–0039 فقط. **لمشروع قائم فعلًا بترحيلات 0001–0016 (بعد المراجعة الأولى):** نفّذ 0017–0039 فقط. **لمشروع قائم فعلًا بترحيلات 0001–0024 (بعد Foundation Hardening 1.2):** نفّذ 0025–0039 فقط. **لمشروع قائم فعلًا بترحيلات 0001–0031 (بعد Foundation Hardening 1.3):** نفّذ 0032–0039 فقط. **لمشروع قائم فعلًا بترحيلات 0001–0036 (بعد Foundation Hardening 1.4):** نفّذ 0037–0039 فقط. **لمشروع قائم فعلًا بترحيلات 0001–0038 (بعد Patch 1.4.1):** نفّذ 0039 فقط (Foundation Audit Hotfix 1.4.2). كل هذه المجموعات إضافية بالكامل ولا تُعدِّل أي ترحيل سابق.
3. نفّذ `supabase/seed.sql` لتحميل الصلاحيات/الأدوار/الإعدادات الأولية (آمن للتكرار — يستخدم `ON CONFLICT DO NOTHING`).
4. من **Authentication → Providers**، تأكد أن تسجيل الدخول بالبريد/كلمة المرور مُفعّل.
5. من **Project Settings → API**، انسخ `Project URL` و`anon public key` و`service_role key` إلى `.env.local`.
6. (اختياري لكن يُنصح به) عطّل **Email confirmations** أثناء التطوير المحلي فقط لتسريع إنشاء المستخدمين التجريبيين، وأعد تفعيلها في الإنتاج.

> إذا استخدمت Supabase CLI بدل لوحة التحكم: `supabase db push` بعد ربط المشروع سيُطبّق الترحيلات بنفس الترتيب طالما أسماء الملفات مرتبة رقميًا كما هي.

---

## 12) طريقة إنشاء أول Super Admin

**لماذا سكربت منفصل بدل زر في الواجهة؟** لأن إسناد دور Super Admin يجب أن يمر حصرًا عبر مسار موثوق (`service_role`) بحسب Trigger منع تصعيد الصلاحيات المذكور في القسم 5 — لا توجد طريقة لفعل ذلك من متصفح حتى لو كان المستخدم الحالي Super Admin آخر، تفاديًا لأي هندسة اجتماعية أو ثغرة مستقبلية في الواجهة.

```bash
npm run bootstrap:super-admin -- --email you@example.com --name "الاسم الكامل"
```

> **تصحيح (Foundation Hardening 1.2):** السكربت **لا يقبل** كلمة المرور كوسيط سطر أوامر (`--password`) إطلاقًا — كانت نسخة سابقة من هذا التقرير تذكر مثالًا خاطئًا يتضمن `--password "StrongPass123!"`. الوسيطان `--email`/`--name` اختياريان فقط (يُطلَبان تفاعليًا إن لم يُمرَّرا)، أما كلمة المرور فتُطلَب **دائمًا** عبر مُطالبة تفاعلية في الطرفية (`prompt()` في `scripts/create-super-admin.ts`، لا تُقبل كوسيط أبدًا) — وهذا سلوك آمن مقصود يجب أن يبقى كما هو: تمريرها كوسيط `--password` كان سيجعلها تُحفَظ في تاريخ shell (`~/.bash_history` أو ما يعادله)، وهذا بالضبط ما يتجنَّبه التصميم الحالي.

السكربت (`scripts/create-super-admin.ts`) يستخدم `SUPABASE_SERVICE_ROLE_KEY` (من `.env.local`) لإنشاء مستخدم Auth جديد (أو استخدام موجود)، تفعيل ملفه الشخصي (`status = active`)، وإسناد دور `super_admin` — كل ذلك عبر اتصال `service_role` الموثوق فقط. **لا تُشغّل هذا السكربت إلا محليًا أو من بيئة خادم موثوقة — أبدًا من كود يصل المتصفح.**

---

## 13) كيفية اختبار الصلاحيات

**على مستوى القاعدة (الأهم)، مباشرة ضد مشروع Supabase حقيقي:**
```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rls_and_permissions.test.sql
```
هذا الملف معاملاتي (`BEGIN...ROLLBACK`) — آمن للتشغيل حتى على قاعدة حقيقية/إنتاجية، لا يترك أي أثر. يتطلب أن تكون ترحيلات 0001–0039 و`seed.sql` مُطبَّقة مسبقًا. بعد أربع مراجعات مستقلة متتالية وPatch 1.4.1 وFoundation Audit Hotfix 1.4.2، يغطي 33 قسمًا فعليًا (وليس على جداول فارغة): حساب `user_accessible_store_ids()` للحالات الثلاث بمتاجر ومستخدمين حقيقيين، عزل بيانات RLS بعد وجود بيانات فعلية (وليس بمصادفة جدول فارغ)، رفض العمليات غير المصرّح بها، نفاذ Super Admin الكامل، تصعيد الصلاحيات الذاتي على الجداول الثلاثة (`user_roles`/`user_permission_overrides`/`role_permissions`) بمحاولات فعلية للمنح/التعديل الذاتي، الفصل العمودي بين `edit`/`disable`، قفل الدوال ذات المعرّف التعسفي، ثقة سجل التدقيق (بما فيها منع أي RPC عام من تلفيق حدث)، `finalize_new_user_profile` (بما فيها منع إعادة تفعيل حساب `suspended` حقيقي عبرها)، قيود اتساق نطاق المتجر، حماية آخر Super Admin، **بعد Foundation Hardening 1.2:** فصل الرؤية التاريخية/التشغيلية للمتاجر، تصعيد وتفويض نطاق المتجر مع الاستبدال الذرّي، حماية Super Admin بوجود اثنين نشطين معًا، قفل الأعمدة المُدارة نظاميًا (بما فيها البريد الإلكتروني)، قفل `roles.is_system`/`key`، وتسمية إجراءات Audit الصحيحة (`create`/`update`/`delete`)، **بعد Foundation Hardening 1.3:** إغلاق تفويض نطاق المتجر بالكامل (`default_store_id` + فرع `DELETE`) بفاعل محدود النطاق فعليًا وليس مسؤولًا كامل الصلاحيات، استقلالية `users.manage_store_access` الكاملة (بما فيها `SELECT`)، إعادة كتابة تفويض الأعمدة كصلاحيات مستقلة لكل مجموعة، إغلاق مسار الالتفاف حول التزويد (`provisioned_at`)، حماية الصلاحيات الحسّاسة على مسار السحب أيضًا، حماية Super Admin ككيان كامل، وفشل آمن لدوال نطاق المتجر لحساب غير نشط، **بعد Foundation Hardening 1.4:** ترقية `provisioned_at` للحسابات القديمة (Backfill آمن)، قفل هوية `user_permission_overrides` (`user_id`/`permission_id` غير قابلين للتغيير)، إكمال تفويض نطاق المتجر لتغييرات `store_access_scope` وحدها (حساب الأثر الفعلي قبل/بعد التغيير)، إكمال UI/DB flow لـ`users.manage_store_access` (مصدر متاجر مخصَّص + استبدال ذرّي مُحسَّن + سياسة `SELECT` أضيق)، وإصلاح دورة حياة الدعوات الملغاة (حذف حساب Auth غير المزوَّد بدل تركه عالقًا)، **بعد Patch 1.4.1 (أقسام 30–32):** الفصل الكامل بين `users.manage_store_access` و`users.manage_permissions` (فاعل يملك الثانية فقط يفشل في تغيير Store Scope/منح/سحب وصول متاجر عبر كل مسار — RLS مباشرة، Trigger، وRPC الاستبدال الذرّي — بينما فاعل يملك الأولى فقط ينجح في كل ذلك)، إثبات السبب الجذري المباشر لعطل تحميل Store Access في الواجهة (استعلام خام ناجح مقابل استعلام مُضمَّن فاشل صامتًا لنفس الفاعل)، وإثبات أن `user.invite_cancel` و`user.delete` صفّان منفصلان ومقصودان (الأول منسوب للفاعل الحقيقي، الثاني تلقائي بلا Actor) لنفس الهدف بلا تكرار، **وأخيرًا بعد Foundation Audit Hotfix 1.4.2 (تحديث 32.4/32.5 + قسم 33 جديد):** حامل `users.disable` يفشل في استدعاء `log_user_invite_cancel()` القديمة مباشرة بسبب `insufficient_privilege` تحديدًا (لا بسبب حالة الهدف)، مستخدم بلا `users.disable` يفشل أيضًا، لا يمكن إنشاء `user.invite_cancel` مرتين لنفس الهدف (فهرس فريد جزئي، بما فيها محاكاة استدعاء متزامن/معاد)، لا وجود لـ`user.invite_cancel` بلا `user.delete` مطابق سابق له، المسار الموثوق بعد حذف حقيقي يسجل actor الحقيقي وtarget الصحيح بدقة، وأن `user.delete`/`user.invite_cancel` يبقيان حدثين واضحين غير متعارضين، وأن `audit_logs` لا يزال بلا أي مسار `UPDATE`/`DELETE` لأي دور.

**لتشغيله محليًا بدون مشروع Supabase (Postgres عادي)، استخدم `supabase/tests/local_harness_setup.sql`** الذي يحاكي مخطط `auth` الخاص بـ Supabase (`auth.uid()`, `auth.role()`, الأدوار الثلاثة) — التعليمات الكاملة موجودة كتعليقات في أعلى ذلك الملف نفسه.

**يدويًا عبر الواجهة:** أنشئ مستخدمًا تجريبيًا بدور "موظف مبيعات" من `/users`، سجّل دخوله في نافذة متصفح خاصة، وتحقق أن عناصر مثل "إضافة متجر" أو "إدارة الصلاحيات" غائبة عن الواجهة **وأن الوصول المباشر لمسارات مثل `/stores` بإجراء إنشاء يُرفض من الخادم أيضًا وليس فقط مخفيًا في الواجهة** (يمكن التحقق عبر محاولة استدعاء الإجراء مباشرة أو بفحص أن RLS يمنع الإدراج حتى لو تجاوز أحد واجهة العميل).

---

## 14) الاختبارات المُنفَّذة

| الملف | الأداة | التغطية |
|---|---|---|
| `supabase/tests/rls_and_permissions.test.sql` | psql (SQL خام، معاملاتي) | RLS، الدوال الأمنية، Triggers الحماية والتصعيد، الفصل العمودي، ثقة سجل التدقيق، `finalize_new_user_profile`، اتساق نطاق المتجر، فصل الرؤية/التشغيل، تصعيد/تفويض نطاق المتجر + الاستبدال الذرّي، حماية Super Admin (باثنين نشطين)، قفل الأعمدة النظامية، قفل `roles.is_system`/`key`، تسمية إجراءات Audit، **بعد Foundation Hardening 1.3:** إغلاق تفويض نطاق المتجر بالكامل (فاعل A+B محدود فعليًا)، استقلالية `SELECT` لـ`users.manage_store_access`، تفويض الأعمدة كصلاحيات مستقلة، إغلاق مسار الالتفاف حول التزويد، حماية الصلاحيات الحسّاسة على مسار السحب، حماية Super Admin ككيان كامل، وفشل آمن لدوال نطاق المتجر لحساب غير نشط، **بعد Foundation Hardening 1.4:** ترقية `provisioned_at` القديمة، قفل هوية `user_permission_overrides`، إكمال تفويض نطاق المتجر لتغييرات `store_access_scope` وحدها، إكمال UI/DB flow لـ`users.manage_store_access`، ودورة حياة الدعوات الملغاة، **بعد Patch 1.4.1:** الفصل الكامل بين `users.manage_store_access`/`users.manage_permissions` (RLS+Trigger+RPC معًا)، السبب الجذري لعطل تحميل Store Access (استعلام خام مقابل مُضمَّن)، وتمايز `user.invite_cancel`/`user.delete`، **وبعد Foundation Audit Hotfix 1.4.2:** إغلاق EXECUTE عن `authenticated` نهائيًا على مسار تسجيل إلغاء الدعوة، ترتيب حذف-ثم-تسجيل الموثوق، وIdempotency عبر فهرس فريد جزئي — 33 قسمًا الآن، أُعيدت كتابته/وُسِّع بعد أربع مراجعات أمنية مستقلة متتالية وPatch 1.4.1 وFoundation Audit Hotfix 1.4.2 |
| `tests/permissions.test.ts` | Vitest | منطق تحليل الصلاحيات في الواجهة (`sessionHasPermission`, `sessionHasAnyPermission`) لكل الحالات: نشط/معطّل/قيد الإعداد (`pending_setup`)، Super Admin، منح/إلغاء متداخل |
| `tests/validation.test.ts` | Vitest | مخططات Zod (المتاجر، المستخدمين، الأدوار) — قيم صحيحة/خاطئة/حدّية |
| `tests/store-access-helpers.test.ts` | Vitest | **جديد (Patch 1.4.1)** — `selectableStoreAccessIds()`: مقاطعة وصول الهدف الفعلي مع نطاق تشغيل الفاعل، بلا أي اتصال قاعدة بيانات (6 اختبارات: تقاطع أساسي، مصفوفة فارغة من الطرفين، عدم اختراع تحديد غير موجود فعليًا، دعم `Set`، والحفاظ على ترتيب المتاجر القابلة للاختيار) |

**نتيجة آخر تشغيل فعلي (بعد Patch 1.4.1، في هذه الجلسة، وليس افتراضًا):**
- `npm run typecheck` (`npx tsc --noEmit`) → صفر أخطاء.
- `npm run lint` → صفر أخطاء وتحذيرات.
- `npm run test` (Vitest) → `31/31` ناجح (25 سابقًا + 6 اختبارات جديدة لـ`selectableStoreAccessIds`).
- `npm run build` (Next.js/Turbopack) → نجح، **17 مسارًا** (بلا تغيير — Patch 1.4.1 لم يُضِف أي مسار جديد).
- اختبار SQL التكاملي (`supabase/tests/rls_and_permissions.test.sql`) → **نجح بالكامل** على قاعدة Postgres محلية أُعيد بناؤها بالكامل من الصفر (الأدوار + الترحيلات 0001–0039 + `seed.sql`) قبل هذا التشغيل تحديدًا، وطُبع `=== ALL RLS/PERMISSION/AUDIT/ESCALATION TESTS PASSED (including Foundation Hardening 1.4, Patch 1.4.1, and Foundation Audit Hotfix 1.4.2) ===` بدون أي خطأ (**139 تأكيد "OK" عبر 33 قسمًا**، مقابل 128 عبر 32 قسمًا سابقًا).

**لماذا هذا المزيج من الأدوات؟** المنطق الأمني الحقيقي (RLS/Triggers) لا يُختبر بمعزل عن قاعدة بيانات فعلية تحاكي Supabase — لذلك اختبار SQL مباشر هو الأصدق هنا. أما منطق التطبيق البحت (تحليل صلاحيات، تحقق مدخلات) فـ Vitest أخف وأسرع وكافٍ دون الحاجة لخادم كامل.

---

## 15) المشاكل المتبقية / الدين التقني

- **لا توليد تلقائي لأنواع Supabase:** `src/types/database.ts` مكتوب يدويًا بدقة مطابقة للترحيلات الحالية لعدم توفر اتصال مباشر بمشروع Supabase فعلي في بيئة البناء. عند أول ربط حقيقي، يُفضَّل تشغيل `supabase gen types typescript` ومقارنته بالملف الحالي كخطوة تحقق إضافية (من المتوقع أن يتطابقا، لكن التحقق أرخص من الافتراض).
- **لا اختبارات E2E متصفح فعلي بعد:** الاختبارات الحالية تغطي المنطق (Unit) والأمن (SQL) لكن ليس تدفق مستخدم كامل في متصفح حقيقي (Playwright مثلًا) — يُوصى بإضافتها عند بدء بناء وحدة المبيعات لأنها ستصبح أكثر قيمة مع تدفقات أطول.
- **رفع الشعار:** حقل شعار المتجر/النظام حاليًا رابط نصي (URL) فقط — لا يوجد رفع ملفات مباشر إلى Supabase Storage بعد (خارج نطاق هذه المرحلة، لكن يستحق ذكره).
- **2FA:** البنية جاهزة معماريًا (عمود `security.two_factor_enabled` في `system_settings`، وتصميم صفحة الإعدادات يتوقعه) لكن التفعيل الفعلي (TOTP) غير مُنفَّذ — كما طُلب صراحة أن يكون "جاهزًا دون إعادة هيكلة" فقط.
- **حماية Brute-force على تسجيل الدخول:** الاعتماد حاليًا على الحماية المدمجة في Supabase Auth (rate limiting افتراضي) + رسالة عربية موحّدة لا تكشف وجود البريد من عدمه؛ لا يوجد Rate limiting إضافي مخصص على مستوى التطبيق نفسه بعد.
- **لا مسار لتغيير البريد الإلكتروني بعد:** منذ 0021 (Foundation Hardening 1.2)، `profiles.email` أصبح غير قابل للتعديل عبر أي UPDATE مباشر — حتى Super Admin — لأنه لا يوجد بعد Flow مخصَّص يزامن التغيير مع Supabase Auth نفسه (auth.users.email) في نفس الوقت. تعديل الجدولين بشكل منفصل يعني تعارضًا محتملًا بين البريد المُستخدَم لتسجيل الدخول والبريد المعروض في الملف الشخصي، لذا فُضِّل قفل التعديل كليًا بدل السماح بتعارض صامت. يستحق وحدة/Flow مستقلة عند الحاجة الفعلية إليه.
- **Warning غير حرج من Vitest:** عند تشغيل `npm run test` تظهر رسالة تحذيرية (وليست خطأ) بخصوص `configLoader: 'native'` في `vitest.config.ts` بسبب صيغة ESM داخل ملف يُحمَّل كـ CommonJS — لا تؤثر على نتائج الاختبارات، ويمكن إسكاتها لاحقًا بتحويل الامتداد إلى `.mts` أو إضافة `"type": "module"`.

---

## 16) الخطوة المقترحة التالية

الأساس المعماري (الصلاحيات، RLS، المتاجر، المستخدمين، سجل التدقيق، الإعدادات) مكتمل ومُختبر بما يكفي لبدء البناء عليه مباشرة. الخطوة المنطقية التالية هي **وحدة المبيعات (Sales)** لأنها:

1. أول وحدة تستهلك فعليًا `user_operable_store_ids()`/`user_accessible_store_ids()` (تقييد العمليات الجديدة بالمتجر) و`user_visible_store_ids()` (عرض تاريخي/تقارير) — ستكشف مبكرًا أي قصور في تصميم نطاق الوصول الحالي قبل أن تُبنى فوقه وحدات أخرى (مرتجعات/تسويات) تعتمد عليها.
2. ستحتاج أول جدول بأرقام مالية حقيقية (`NUMERIC`)، فتصبح فرصة للتحقق من أن معايير الأموال/الأوزان المؤسَّسة في `src/lib/money.ts` كافية عمليًا قبل تعميمها.
3. بعدها تصبح المرتجعات والتسويات طبيعية البناء لأنها تعتمد بنيويًا على وجود مبيعات فعلية أولًا.

---

## معايير الإنجاز (القسم 29) — التحقق الفعلي المُنفَّذ في هذه الجلسة

| المعيار | طريقة التحقق | النتيجة |
|---|---|---|
| المشروع يعمل | `npm run build` تم تنفيذه فعليًا | ✅ نجح، 17 مسارًا تم توليدها |
| TypeScript بدون أخطاء | `npx tsc --noEmit` | ✅ صفر أخطاء |
| Build ينجح | `next build` (Turbopack) | ✅ نجح |
| ESLint نظيف | `npx eslint .` | ✅ صفر أخطاء وصفر تحذيرات |
| الاختبارات تعمل | `npm run test` | ✅ 31/31 ناجحة |
| RLS موجود ويعمل فعليًا | اختبار SQL تكاملي على Postgres حقيقي | ✅ ناجح بالكامل، بما فيه حالات الرفض المتعمّدة |
| لا بيانات مالية وهمية | مراجعة يدوية لكل صفحة/استعلام | ✅ لا يوجد أي رقم مبيعات/ربح وهمي في أي مكان |
| لا أسرار في الكود | مراجعة `.env.example` و`.gitignore` وبحث نصي عن مفاتيح | ✅ لا مفاتيح حقيقية، `service_role` خادم فقط |

---

## الملحق الأول — المراجعة الأمنية المستقلة الأولى وإصلاحاتها (ترحيلات 0012–0016)

بعد التسليم الأول لهذا الأساس، أُجريت مراجعة أمنية مستقلة عليه كشفت أن عدة قيود كانت متحققة على مستوى **الواجهة/Server Actions فقط**، وليس على مستوى **قاعدة البيانات نفسها** — أي أن استدعاء PostgREST مباشرًا (بمعزل عن أي كود Next.js) كان يمكن أن يتجاوزها. الشرط الصريح كان: **لا تبدأ أي وحدة جديدة (مبيعات، أسعار ذهب، ...) قبل إغلاق كل ثغرة من هذه القائمة على مستوى القاعدة**، بترحيلات SQL **جديدة فقط** دون تعديل أي ترحيل قديم (0001–0011) حفاظًا على التوافق مع أي قاعدة بيانات قد يكون المشروع مطبَّقًا عليها بالفعل. هذا القسم يوثّق كل بند من العشرة، ماذا كانت المشكلة تحديدًا، وكيف أُغلقت.

> **ملاحظة:** بعد هذا الملحق، رُوجِعت نفس نسخة الـZIP مرة أخرى (مراجعة ثانية مستقلة) وكشفت حالات إضافية لم تكن مغطاة باختبارات هذه المراجعة الأولى رغم أن الإصلاحات أعلاه كانت موجودة فعليًا وصحيحة. تفاصيل المراجعة الثانية ("Foundation Hardening 1.2") في **الملحق الثاني** أسفل هذا الملحق مباشرة.

### 1. تصحيح `user_accessible_store_ids()`
**قبل:** استعلام واحد لم يكن يُفرّق بوضوح بين دلالة كل قيمة من `all`/`multiple`/`single`. **بعد (0012):** إعادة كتابة كاملة (`plpgsql` بدل `sql`) بتفريع صريح: `all` ← كل متجر `status = 'active'`، `multiple` ← فقط صفوف `user_store_access` الخاصة بالمستخدم، `single` ← فقط `profiles.default_store_id`. اختُبرت الحالات الثلاث فعليًا ببيانات حقيقية (4 متاجر، مستخدم بنطاق `single` على متجر واحد، ومستخدم بنطاق `multiple` على متجرين، ومستخدم Super Admin بنطاق `all`) — ليس على جدول فارغ.

### 2. منع تصعيد الصلاحيات على مستوى القاعدة (0013)
ثلاث قواعد، كل واحدة Trigger مستقل لأن RLS وحدها لا تستطيع مقارنة "ما يملكه الفاعل نفسه الآن" أو "هل هذا صفّه الخاص" بنفس الدقة:
- **منع التعديل الذاتي:** لا يستطيع مستخدم غير Super Admin تعديل/حذف/إدراج صفوفه الخاصة في `user_roles` أو `user_permission_overrides` — حتى لو كان يملك `users.manage_permissions`. اختُبر فعليًا: مستخدم Admin (يملك `users.manage_permissions` فعليًا) حاول حذف دوره الخاص ومُنع من الـ Trigger تحديدًا.
- **منع منح ما لا تملك:** لا يمكن منح صلاحية (عبر `role_permissions` أو استثناء `grant`) لا يملكها المانح نفسه حاليًا.
- **قفل الصلاحيات الحسّاسة الثلاث** (`users.manage_permissions`, `settings.manage`, `backups.manage`): لا تُمنح لدور أو مستخدم إلا بواسطة Super Admin فعليًا، حتى لو كان المانح يملك نفس الصلاحية الحسّاسة بالذات — منعًا لتوسّع أفقي للصلاحيات الحسّاسة بين الإداريين. يشمل هذا أيضًا **إسناد دور جاهز** يحمل صلاحية حسّاسة (`user_roles`)، وليس فقط تعديل `role_permissions` مباشرة، لإغلاق المسار البديل.

### 3. فصل `users.edit`/`stores.edit` عن `users.disable`/`stores.disable` (0014)
كانت RLS تسمح بالتعديل لمن يملك **أيًا من الصلاحيتين**، لكنها لا تستطيع تقييد الأعمدة القابلة للتغيير ضمن نفس الصف. الآن Trigger على `profiles` وآخر على `stores` يقارن كل عمود OLD/NEW: من يملك `edit` الكاملة يمر بلا قيد، من يملك `disable` فقط يُرفض تعديله فورًا (برسالة عربية واضحة) إن غيّر أي عمود غير `status`. **اختُبر عبر تحديث SQL مباشر يحاكي استدعاء PostgREST REST، وليس عبر واجهة Next.js** — تمامًا كما طُلب، لإثبات أن الرفض ليس اعتمادًا على أن Server Action لا "تعرض" الحقل في النموذج.

### 4. تحصين دوال `SECURITY DEFINER` (0015)
- `REVOKE EXECUTE ... FROM PUBLIC` صريح على **كل** دالة `SECURITY DEFINER` أُنشئت حتى الآن (Postgres يمنح `EXECUTE` لـ `PUBLIC` تلقائيًا عند الإنشاء ما لم يُسحَب — لم يكن ذلك مطبَّقًا في أي دالة من الأساس الأول).
- **ثغرة إفصاح معلومات حقيقية أُغلقت:** أربع دوال (`is_active_user`, `is_super_admin`, `get_user_permissions`, `user_accessible_store_ids`) تأخذ `uuid` تعسفيًا وكانت مُصرَّحة لـ `authenticated` — أي مستخدم موثَّق (بغض النظر عن دوره) كان يستطيع فعليًا تنفيذ `select * from get_user_permissions('<uuid شخص آخر>')` مباشرة عبر RPC ومعرفة صلاحيات/حالة Super Admin/متاجر أي شخص آخر بدقة. أصبحت الأربعة `service_role` فقط.
- عوضًا عنها، ثلاث أغلفة ذاتية النطاق جديدة (`get_my_permissions`, `am_i_super_admin`, `my_accessible_store_ids`) مُصرَّحة لـ `authenticated`، تحلّ دائمًا مقابل `auth.uid()` للجلسة الحالية ولا تقبل أي معرّف كوسيط.
- **`search_path`** مُثبَّت (`public, pg_temp`) في كل دالة من هذه، وهو النمط الآمن القياسي لمنع اختطاف الدوال عبر search_path متغيّر.

### 5. إعادة تصميم سجل التدقيق (0016)
- **قبل:** `log_audit_event()` كانت دالة عامة الأغراض (action/entity_type/entity_id/values حرة تمامًا كوسائط) مُصرَّحة لـ `authenticated` **و`anon`**. أي مستخدم موثَّق كان يستطيع فعليًا تلفيق حدث تدقيق كامل بقيم مزيّفة (`select log_audit_event('fake.event', ...)`) — وهذا استُغِلّ فعليًا في الاختبار لإثبات المشكلة قبل الإصلاح.
- **بعد:** `log_audit_event()` أصبحت `service_role` فقط. الكتابة الفعلية لسجل التدقيق على الجداول الحسّاسة الثمانية (`profiles`, `stores`, `roles`, `role_permissions`, `user_roles`, `user_permission_overrides`, `user_store_access`, `system_settings`) تتم الآن **تلقائيًا عبر Trigger واحد قابل لإعادة الاستخدام** (`audit_table_changes()`) على كل جدول، فلا يوجد أي مسار كتابة/تعديل مباشر (بما فيه استدعاء REST من خارج Next.js تمامًا) يستطيع تجاوز السجل — الـ Trigger يُسجّل بصرف النظر عن العميل.
- **مسار الدخول/الخروج:** دالة جديدة بقائمة بيضاء صارمة (`log_auth_event`، حصريًا `auth.login_success`/`auth.logout`) مُصرَّحة لـ `authenticated`، تُثبّت `user_id = auth.uid()` نفسه.
- **الدخول الفاشل قبل المصادقة** لم يعد عبر RPC مفتوح لـ `anon`: أصبح مسارًا في كود الخادم فقط (`logFailedLoginAttempt` في `src/lib/audit/log-failed-login.ts`) عبر عميل `service_role` إداري، مع تحديد معدّل (10 محاولات/15 دقيقة لكل حساب مُحلَّل من البريد)، **ولا يخزّن البريد الإلكتروني في عمود `reason` كنص حر** — يُحلَّل إلى `profile_id` أولًا ثم يُخزَّن المعرّف فقط.

### 6. إصلاح فشل إنشاء المستخدم الجزئي
**قبل:** إن نجح إنشاء مستخدم Auth ثم فشلت خطوة تهيئة الملف الشخصي، كان يبقى حساب Auth "معلّقًا" بلا معالجة واضحة. **بعد:** دالة `finalize_new_user_profile()` (`SECURITY DEFINER`، مشروطة بـ `users.create`) تُتِمّ التفعيل من `suspended` إلى `active` بشرط أن يكون الصف لا يزال `suspended` (فلا يمكن استغلالها لإعادة تفعيل/تعديل ملف نشط بالفعل — اختُبر بمحاولة استدعاء ثانية فعليًا). `createUserAction` في `src/features/users/actions.ts` تستدعيها بعد إنشاء مستخدم Auth، وإن فشلت، تُنفّذ تعويضًا صريحًا (`admin.auth.admin.deleteUser(...)`) بدل ترك الحالة معلّقة صامتًا، مع رسالة خطأ مختلفة إن فشل التعويض نفسه أيضًا.

### 7. قيود اتساق نطاق المتجر (0012)
- قيد `CHECK` (`profiles_single_scope_requires_default_store`, مُضاف بنمط `NOT VALID` ثم `VALIDATE CONSTRAINT` ليتوافق مع قاعدة بها بيانات فعلية دون قفلها أثناء الإضافة) يمنع مستخدمًا نشطًا بنطاق `single` من الافتقار إلى `default_store_id`.
- Trigger يمنع تعيين `default_store_id` أو منح وصول عبر `user_store_access` لمتجر ليس `status = 'active'`.

### 8. تعزيز مجموعة اختبارات SQL
أُعيدت كتابة `supabase/tests/rls_and_permissions.test.sql` بالكامل — الفرق الجوهري عن النسخة الأولى: **كل اختبار رؤية/عزل يُنفَّذ بعد إدراج بيانات حقيقية (متاجر، مستخدمين متعددين) أولًا، لا على جداول فارغة.** هذا كشف فعليًا خللًا كامنًا في مجموعة الاختبارات الأصلية نفسها (كانت تفترض أن موظف مبيعات لا يرى أي متجر، بينما `seed.sql` يمنحه فعليًا `stores.view` — كان هذا الافتراض الخاطئ مُقنَّعًا بالكامل لأن جدول `stores` كان فارغًا في تلك اللحظة، فأي عدد يساوي صفرًا بصرف النظر عن صحة RLS من الأساس). أُضيفت أيضًا: اختبارات مباشرة (REST-equivalent) لكل صلاحية حسّاسة، اختبارات تصعيد ذاتي، اختبارات وصول تعسفي لدوال RPC، واختبارات تجاوز سجل التدقيق. **أثناء هذا التشغيل الفعلي اكتُشفت وأُصلحت ثغرة حقيقية إضافية:** `REVOKE EXECUTE ... FROM PUBLIC` **لا يُلغي** منحًا صريحًا سابقًا لدور محدَّد (`GRANT ... TO authenticated`) كان موجودًا من 0010 — فحص `pg_proc.proacl` أثبت أن الدوال الأربع المذكورة في البند 4 بقيت قابلة للاستدعاء من `authenticated` رغم "القفل" الأول، إلى أن أُضيف `REVOKE ... FROM authenticated` صريح لكل واحدة منها. هذا مثال دقيق على سبب طلب اختبارات SQL حقيقية بدل الاكتفاء بمراجعة الكود.

### 9. تصحيح هذا التقرير
هذا الملف نفسه صُحِّح ليطابق الكود الفعلي: قائمة الترحيلات (0001–0016 بدل 0001–0011)، قيم `stores.status` الصحيحة (`active`/`disabled` — كانت مكتوبة خطأً `active`/`inactive`)، دلالة نطاق المتجر لكل قيمة، ونظام سجل التدقيق الجديد المبني على Triggers. طريقة إنشاء أول Super Admin (`npm run bootstrap:super-admin -- ...`، عبر `scripts/create-super-admin.ts`) رُوجعت وبقيت صحيحة كما كانت — لم تتغيّر بالمراجعة.

### 10. تشغيل التحقق الكامل بعد الإصلاح
نتائج فعلية (تفصيلها في القسم 14 أعلاه): `npm run typecheck` صفر أخطاء، `npm run lint` صفر أخطاء/تحذيرات، `npm run test` (Vitest) 24/24 ناجح، `npm run build` نجح (18 مسارًا)، واختبار SQL التكاملي نجح بالكامل على قاعدة أُعيد بناؤها من الصفر بكل الترحيلات 0001–0016 و`seed.sql`.

**خلاصة الملحق الأول:** كل ثغرة كانت **حقيقية وقابلة للاستغلال فعليًا عبر PostgREST مباشرة** (وليست نظرية أو محصورة بواجهة Next.js) أُصلحت على مستوى قاعدة البيانات، وكل إصلاح مُثبَت باختبار SQL فعلي وليس افتراضًا.

---

## الملحق الثاني — "Foundation Hardening 1.2": مراجعة أمنية مستقلة ثانية وإصلاحاتها (ترحيلات 0017–0024)

بعد الملحق الأول، رُوجِعت نفس نسخة الـZIP المُحدَّثة مرة أخرى. الإصلاحات السابقة (0012–0016) كانت موجودة فعليًا وصحيحة، لكن المراجعة الثانية كشفت **حالات لم تكن مغطاة باختبارات المراجعة الأولى** — بعضها ثغرات تصعيد صلاحيات حقيقية إضافية، وبعضها غموض تصميمي (دلالة واحدة تُستخدم لمعنيين متعارضين) لم يكن قد ظهر كخلل بعد لعدم وجود اختبار يفرض التمييز بينهما. الشرط كان مطابقًا للمرة الأولى: **لا تبدأ Master Data/Sales حتى إغلاق كل بند من العشرة على مستوى القاعدة**، بترحيلات SQL **جديدة فقط (0017–0024)** دون تعديل أي ملف من 0001–0016. هذا القسم يوثّق كل بند، ماذا كانت المشكلة تحديدًا، وكيف أُغلقت.

### 1. إغلاق تصعيد نطاق المتجر بالكامل (0018)
قبل هذه المراجعة، حاملُ `users.edit` فقط كان يستطيع تعديل `store_access_scope`/`default_store_id` **الخاصين بحسابه هو نفسه** عبر تحديث مباشر (سياسة RLS `profiles_update` تسمح بالصف كاملًا لحامل `users.edit`، و0014 كانت تدع `users.edit` يمر بلا قيد أعمدة) — أي أن مستخدمًا غير Super Admin كان يستطيع نظريًا منح نفسه `scope='all'` بمجرد تعديل ملفه الشخصي. كذلك، لم يكن هناك ما يمنع حامل `users.manage_permissions` من إدراج/حذف صفوف `user_store_access` **الخاصة به هو نفسه**، ولا ما يحدّ تفويضه وصولًا لمتجر لا يملك هو نفسه صلاحية العمل عليه. أُغلقت الثلاث معًا عبر:
- صلاحية مخصَّصة جديدة `users.manage_store_access` (بدل الاعتماد على `users.edit` العامة لحدٍّ أمني بهذا الحجم)، مُمنوحة افتراضيًا لـ `super_admin`/`admin`.
- Trigger (`enforce_store_scope_authorization`) يمنع تعديل الفاعل نطاق وصوله **الخاص** بنفسه (حتى لو يملك `users.manage_store_access`)، ويشترط الصلاحية الجديدة تحديدًا لتعديل نطاق غيره، ويقصر `scope='all'` (النطاق الأوسع، كل متجر نشط بلا مراجعة لكل متجر على حدة) على Super Admin حصرًا — وهو الخيار الأكثر أمانًا من بين الخيارات الممكنة، واختير عمدًا ومُوثَّق هنا كما طُلب صراحة.
- Trigger مقابل (`enforce_store_access_delegation`) يمنع الفاعل من منح/سحب `user_store_access` **الخاص به هو نفسه** بنفسه، ويحدّ تفويضه لغيره بما يملكه هو فعليًا (`user_operable_store_ids(auth.uid())`) — لا يمكن لمستخدم أن يمنح وصولًا أوسع مما يملكه هو نفسه.
- **ثغرة تفاعل بين ترحيلين اكتُشفت أثناء المراجعة التصميمية (قبل حتى تشغيل الاختبار):** Trigger عمود 0014 (`enforce_profile_update_column_authorization`) ينفّذ **قبل** Trigger 0018 الجديد أبجديًا بحسب اسم الـTrigger، وفرعه الأخير (fail-closed) كان يرفض أي فاعل لا يملك `users.edit`/`users.disable` — بلا معرفة بمسار `users.manage_store_access` الجديد أصلًا — فيرفض بخطأ مضلِّل قبل أن تصل العملية لمنطق 0018 الأدق. أُصلحت بإعادة تعريف دالة 0014 من **داخل ملف 0018 نفسه** (`CREATE OR REPLACE`، دون تعديل ملف 0014) لإضافة فرع ثالث: حامل `users.manage_store_access` (بلا `edit`/`disable`) يمرّ فقط إن اقتصر التغيير على عمودي نطاق المتجر، تاركًا القيود الأدق (المنع الذاتي، `scope='all'`) لـTrigger 0018 نفسه. اختُبر صراحة: حامل `users.edit` فقط (بلا `users.manage_store_access`) لا يستطيع تعديل نطاق متجر مستخدم آخر رغم مروره من 0014 بلا قيد.
- اختُبرت جميع الحالات فعليًا: منع ذاتي (نطاق، ومنح/سحب `user_store_access`)، حدّ التفويض بمحاولة فعلية لتفويض متجر خارج النطاق المُشغَّل ثم داخله، منع `scope='all'` لغير Super Admin مع ضبط ناجح لتغيير غير `all`، وحالة `users.edit` وحدها غير كافية.

### 2. إعادة تصميم `finalize_new_user_profile()` جذريًا (0019)
**قبل:** `suspended` كانت تُستخدم لمعنيين متعارضين معًا: حالة التزويد الافتراضية لصفّ جديد (`handle_new_auth_user()`) **و**حالة حساب حقيقي عطَّله مسؤول عمدًا — ما كان يعني أن `finalize_new_user_profile()` (تُطابق `status='suspended'` فقط) لا تستطيع التمييز بينهما، وحاملَ `users.create` كان يستطيع نظريًا استدعاءها على حساب مُعطَّل فعليًا لا حساب تزويد جديد. **بعد:** حالة ثالثة مستقلة `pending_setup` — لا تُضبَط إلا من `handle_new_auth_user()` (سياق موثوق، INSERT فقط)، و`finalize_new_user_profile()` تُطابق `status='pending_setup'` حصرًا الآن. `suspended` أصبحت محجوزة فعليًا للتعطيل المتعمَّد فقط. أُضيف أيضًا Trigger (`enforce_pending_setup_transition`) يشترط `users.create` تحديدًا للانتقال `pending_setup → active` (حتى عبر UPDATE مباشر يتجاوز الدالة نفسها)، ويمنع أي انتقال **إلى** `pending_setup` إلا من سياق موثوق. اختُبر صراحة (السيناريو المطلوب تحديدًا): مستخدم يملك `users.create` **لا يستطيع** إعادة تفعيل حساب `suspended` حقيقي (كان نشطًا ثم عُطِّل عمدًا) عبر `finalize_new_user_profile()` — كذلك حامل `users.edit` بلا `users.create` لا يستطيع تفعيل صفّ `pending_setup` مباشرة عبر UPDATE خام. **تصحيح لاحق (Foundation Hardening 1.4، انظر الملحق الرابع بند 5):** الجملة السابقة كانت تصف نقل `pending_setup` إلى `suspended` بأنه "إلغاء دعوة" مشروع — تبيّن أن هذا المسار كان يترك حساب Auth عالقًا بلا أي مسار استعادة (لا "إتمام" لاحقًا، ولا حذف)، فأُغلق كليًا في 0036: `pending_setup → suspended` مرفوض الآن لأي فاعل غير موثوق، مهما كانت صلاحياته. إلغاء دعوة أصبح عملية مستقلة (`cancelUserInviteAction`) تحذف حساب Auth غير المزوَّد فعليًا بدل نقله إلى `suspended`.

### 3. حماية حسابات Super Admin ككيانات محمية (0020)
**قبل:** حماية "آخر Super Admin" (0009) تمنع فقط الوصول لصفر Super Admin نشط، ومنع التعديل الذاتي (0013) يمنع فقط الفاعل من التلاعب **بصفّه هو نفسه**. لم يكن هناك ما يمنع مسؤولًا آخر (Admin عادي، ليس Super Admin) من تعديل بيانات Super Admin **آخر**، تعطيله، أو سحب دور `super_admin` منه — طالما بقي Super Admin نشط واحد على الأقل غير المُستهدَف. **بعد:** قاعدة شاملة: أي تعديل على صفّ يحمل دور `super_admin` (بيانات، حالة، نطاق وصول متاجر) يتطلب أن يكون الفاعل نفسه Super Admin، بصرف النظر عن عدد المتبقّين؛ وحذف دور `super_admin` من أي مستخدم كذلك يتطلب Super Admin فاعلًا. هذه طبقة **إضافية** فوق حماية "آخر واحد" (0009) والتعديل الذاتي (0013)، لا بديلة عنهما. اختُبر فعليًا **بوجود Super Admin نشطَين اثنين معًا** (شرط ضروري لإثبات أن المنع ليس مجرد أثر جانبي لحماية "آخر واحد"): Admin عادي مُنع من تعديل بيانات/تعطيل/تعديل نطاق متجر أحدهما ومن حذف دوره، بينما الـSuper Admin الآخر نجح في تعديل بياناته وتعطيله ثم إعادة تفعيله.

### 4. فصل الرؤية التاريخية عن إمكانية العمل التشغيلي (0017)
**قبل:** دالة واحدة (`user_accessible_store_ids`) كانت تخدم معنيين مختلفين بلا تمييز: "هل يمكن اختيار هذا المتجر لعملية جديدة" و"هل يمكن رؤية بيانات/تقارير هذا المتجر تاريخيًا". هذا الخلط كان يخفي ثغرة إضافية: فرعا `multiple`/`single` لم يكونا يُصفِّيان أصلًا حسب حالة المتجر (`status`)، فمتجر يُعطَّل بعد منح الوصول كان يبقى "متاحًا" لمستخدم `multiple`/`single` رغم تعطيله. **بعد:** `user_operable_store_ids()` (متاجر نشطة فقط — لأي عملية تُنشئ/تُعدِّل بيانات جديدة) مقابل `user_visible_store_ids()` (كل متجر مُنح له الوصول ولو عُطِّل لاحقًا — للعرض التاريخي/التقارير فقط، تعطيل متجر لا يمحوه من تاريخ من كان يراه). `user_accessible_store_ids()` بقيت بالاسم نفسه (لا كسر توافق) لكن أصبحت غلافًا رقيقًا على `user_operable_store_ids()` فقط — بدل إضافة اسم ثالث مُربِك، الاسم الذي كان يعني دائمًا "ما يمكن العمل عليه" احتفظ بهذا المعنى بدقة. اختُبر فعليًا: تعطيل متجر لمستخدم `multiple`-scope يُخرجه من `my_operable_store_ids()` لكنه يبقى في `my_visible_store_ids()`؛ نفس الشيء لمستخدم `single`-scope عند تعطيل متجره الافتراضي الوحيد (يُفرَّغ العامل التشغيلي بالكامل، ويبقى التاريخي كما هو)؛ ومستخدم `all`-scope يرى 3 متاجر نشطة تشغيليًا مقابل 4 (شاملة المُعطَّل دائمًا) تاريخيًا.

### 5. قفل الأعمدة المُدارة نظاميًا على مستوى القاعدة (0021)
- **`profiles.email`:** لم يكن هناك أي حماية ضد تعديله مباشرة رغم أن حامل `users.edit` يستطيع تعديل بقية الصف بلا قيد — بلا مسار Flow مخصَّص يزامن التغيير مع Supabase Auth، أي تعديل مباشر كان سيُنتج تعارضًا صامتًا بين بريد تسجيل الدخول الفعلي والبريد المعروض. أُقفل كليًا (حتى لأمام Super Admin) إلا من سياق Bootstrap موثوق.
- **`created_at`/`created_by`/`updated_at`/`updated_by`:** كانت `updated_at`/`updated_by` محميتين فعليًا على `UPDATE` منذ 0001/0014، لكن لا شيء كان يمنع `INSERT` خام (عبر REST مباشرة، متجاوزًا Server Actions) من تحديد `created_by` بمعرّف تعسفي أو `created_at` بتاريخ ماضٍ مزيَّف على `stores`/`roles` (الجدولان الإداريان القابلان لـINSERT من `authenticated`)، ولا شيء كان يمنع تعديلهما لاحقًا عبر `UPDATE`. أصبحا الآن مُثبَّتين على القيم الحقيقية **بصمت** (نفس فلسفة `set_updated_by()` الموجودة أصلًا: القيمة تُصحَّح تلقائيًا بدل رفض العملية بخطأ) على `profiles`/`stores`/`roles`، وعلى `created_at`/`created_by` فقط لجداول الربط (`user_roles`/`user_permission_overrides`/`user_store_access`). اختُبر فعليًا: INSERT بقيم مزوَّرة على `stores`/`user_roles` يُنتج القيم الحقيقية فعليًا وليس المزوَّرة، وUPDATE محاولًا تغيير `created_by`/`created_at` على صفّ موجود يُتجاهَل بصمت.

### 6. جعل أحداث Auth Audit جديرة بالثقة (0023)
**قبل:** `log_auth_event(text)` (0016) كانت `SECURITY DEFINER` مُصرَّحة لـ`authenticated`، مُثبِّتة `user_id = auth.uid()` نفسه ومحصورة بقائمة بيضاء صارمة — تبدو آمنة، لكن أي مستخدم موثَّق كان يستطيع استدعاءها **بنفسه، في أي وقت يختاره**، بلا أي علاقة بدخول/خروج حقيقي فعليًا حدث، لتلفيق سجل زمني مزيَّف ("كنت متصلًا خلال الفترة الفلانية") أو لحشو سجله بأحداث خروج وهمية. **بعد:** نُقِل التسجيل بالكامل لمسار `service_role` فقط: دالة جديدة `log_auth_event_trusted(p_user_id uuid, p_action text)` — `service_role` حصرًا، تأخذ `p_user_id` صراحة (لا `auth.uid()` ضمنيًا، لأن اتصال `service_role` لا يحمل JWT مستخدم أصلًا) — تُستدعى من `src/features/auth/actions.ts` عبر العميل الإداري **بعد** أن يتحقق كود الخادم فعليًا من نجاح الدخول (`loginAction`) أو من وجود جلسة حقيقية (`logoutAction`، عبر `getUser()`). `log_auth_event(text)` القديمة `REVOKE`دت من `authenticated` بالكامل (لم تُحذف، للحفاظ على تاريخها). اختُبر فعليًا: `authenticated` مرفوض من كلتا الدالتين الآن، و`service_role` وحده ينجح ويُنتج صفًا صحيحًا، ولا يزال محصورًا بالقائمة البيضاء.

### 7. قفل `roles.is_system` (و`roles.key`) (0022)
**قبل:** `protect_system_role_identity()` (0009) كانت تحمي فقط صفوفًا **كانت بالفعل** `is_system=true` من تعديل `key`/`is_system`. هذا ترك ثغرتين: (أ) `INSERT` لم يكن مُقيَّدًا إطلاقًا — حامل `users.manage_permissions` كان يستطيع نظريًا إدراج دور جديد بـ`is_system=true` مباشرة عبر REST؛ (ب) `UPDATE` على صفّ `is_system=false` كان يمر بلا فحص — ترقية دور مخصَّص عادي إلى `is_system=true` كانت ممكنة نظريًا بلا أي قيد. **بعد:** `is_system` لا يمكن أن يصبح `true` إطلاقًا (لا INSERT ولا UPDATE) إلا من سياق Bootstrap موثوق — لا حتى بحامل `users.manage_permissions`. أُضيف أيضًا قفل `roles.key` من التعديل عبر UPDATE لأي دور (نظامي أو مخصَّص) — لا حاجة تطبيقية له إطلاقًا. صفوف `is_system=true` **الموجودة أصلًا** ما زالت قابلة لتعديل بقية أعمدتها (تغيير الاسم المعروض مثلًا) بلا قيد إضافي — القفل الجديد يستهدف الإنشاء/الترقية فقط. اختُبر فعليًا: رفض INSERT بـ`is_system=true`، رفض ترقية دور مخصَّص فعليًا مُنشَأ داخل الاختبار نفسه، رفض تعديل `key`، ونجاح تعديل الاسم المعروض لدور نظامي موجود مسبقًا (ضابط إيجابي).

### 8. تصحيح تسمية إجراءات Audit (0024)
**قبل:** `audit_table_changes()` (0016) كانت تحسب اسم الإجراء بـ`lower(TG_OP)` — أي أن `INSERT` تُنتج `'insert'` فتصبح `user.insert`/`store.insert`/`role.insert` إلخ. لكن `src/lib/audit/action-labels.ts` (مكتوب في نفس جلسة 0016) كان يتوقع دائمًا `.create` لصفوف الإنشاء — أي أن كل سجل Audit ناتج عن INSERT كان يُعرَض كسلسلة خام غير مترجَمة في واجهة سجل التدقيق منذ أول نسخة من هذا الـTrigger، بصمت، دون أن يفشل أي شيء ليكشف ذلك. **بعد:** الدالة تُعيد تعريف الفعل صراحة: `INSERT → 'create'`, `UPDATE → 'update'`, `DELETE → 'delete'`. لا حاجة لإعادة إنشاء أي Trigger فردي (كلها تستدعي هذه الدالة بالاسم، و`CREATE OR REPLACE` يُحدِّث الجسم لكل Trigger موجود فورًا). اختُبر فعليًا: إنشاء دور مخصَّص جديد يُنتج `role.create` (وليس `role.insert`)، وحذفه يُنتج `role.delete`.

### 9. الاستبدال الذرّي لوصول المتاجر (0018)
**قبل:** `setUserStoreAccessAction` في `src/features/users/actions.ts` كانت تحسب الفرق (إضافة/حذف) على العميل ثم تُنفّذ `insert()` منفصلة تمامًا عن `delete()` — استدعاءان مستقلان لقاعدة البيانات. فشل أحدهما (رفض حدّ التفويض على متجر واحد وسط الدفعة، انقطاع اتصال) كان يمكن أن يترك المستخدم بوصول متاجر نصف-مُطبَّق، غير متسق مع ما طلبه المسؤول فعليًا. **بعد:** دالة SQL واحدة `replace_user_store_access(p_user_id uuid, p_store_ids uuid[])` تحسب نفس الفرق وتُطبِّقه كاستدعاء واحد من طرف علوي واحد — أي استثناء في أي مكان بداخلها (بما فيه استثناء من Trigger حدّ التفويض على متجر واحد وسط الدفعة) يُلغي التنفيذ **بالكامل**، فإما ينجح كل التغيير أو لا يتغيّر شيء إطلاقًا. الدالة `SECURITY INVOKER` عمدًا (وليست `SECURITY DEFINER`) — تُنفَّذ كالمستخدم المُستدعي نفسه، فتخضع لكل قواعد 0018 أعلاه (حدّ التفويض، المنع الذاتي، اشتراط متجر نشط) تمامًا كاستدعاء REST مباشر، وليست التفافًا يتجاوزها. اختُبرت الذرّية فعليًا: دفعة تحتوي متجرًا صالحًا ومتجرًا معطَّلًا (غير صالح) تفشل **بالكامل** ولا يتغيّر شيء إطلاقًا (لا حتى حذف المتجر الذي كان سيُحذَف بنجاح لو نُفِّذت الخطوتان منفصلتين) — ثم دفعة صالحة بالكامل من الفاعل نفسه تنجح وتستبدل المجموعة بدقة في استدعاء واحد.

### 10. تصحيح هذا التقرير
- **قائمة الترحيلات:** 0001–0024 بدل 0001–0016 (جدول القسم 3، وكل إشارة لنطاق الترحيلات في الملحقين والأقسام 11/13/14).
- **مثال أمر Bootstrap (القسم 12) كان خاطئًا:** كان يذكر وسيطًا `--password "StrongPass123!"` غير موجود فعليًا في `scripts/create-super-admin.ts` — السكربت الفعلي **لا يقبل** كلمة المرور كوسيط سطر أوامر إطلاقًا، ويطلبها دائمًا عبر مُطالبة تفاعلية في الطرفية (سلوك آمن مقصود يمنع تسرّبها إلى تاريخ shell) — صُحِّح المثال ليطابق الكود الفعلي، مع توضيح أن `--email`/`--name` وحدهما اختياريان.
- **وصف نطاق المتجر ونظام سجل التدقيق:** حُدِّثا في القسمين 4/5 ليعكسا فصل الرؤية التاريخية عن التشغيلية (0017) ونقل تسجيل أحداث الدخول/الخروج إلى مسار `service_role` فقط (0023).
- **عدد الصلاحيات:** 36 بدل 35 (إضافة `users.manage_store_access`)، وعدد أقسام اختبار SQL: 17 بدل 11.
- **`profiles.status`:** ثلاث قيم (`active|suspended|pending_setup`) بدل قيمتين، مع توضيح الفرق الجوهري بينهما (القسم 4).

### 11. تشغيل التحقق الكامل بعد الإصلاح
أُعيد بناء قاعدة اختبار Postgres محلية **من الصفر بالكامل** (حذف القاعدة والأدوار الثلاثة، إعادة إنشائها، تطبيق `local_harness_setup.sql`، ثم كل الترحيلات 0001–0024 بالترتيب، ثم `seed.sql`) قبل تشغيل اختبار التكامل — وليس تشغيلًا تراكميًا فوق قاعدة قديمة. نتائج فعلية: `npm run typecheck` صفر أخطاء، `npm run lint` صفر أخطاء/تحذيرات، `npm run test` (Vitest) 24/24 ناجح (بلا تغيير — لا منطق واجهة جديد يستدعي اختبار Vitest إضافي في هذه الجولة)، `npm run build` نجح (18 مسارًا)، واختبار SQL التكاملي نجح بالكامل (71 تأكيد "OK" عبر 17 قسمًا، `=== ALL RLS/PERMISSION/AUDIT/ESCALATION TESTS PASSED ===`) على القاعدة المُعاد بناؤها بالكامل.

**ملاحظة تقنية على أثناء الإصلاح:** أثناء كتابة اختبارات هذه المراجعة، تبيّن أن محاكاة مخطط `auth` المحلية (`supabase/tests/local_harness_setup.sql`) لم تكن تمنح `service_role` وصولًا لمخطط/جدول `auth.users` نفسه، ولا تمنح `anon`/`authenticated` صلاحية `USAGE` على مخطط `auth` لاستدعاء `auth.uid()` مباشرة من داخل اختبار — كلاهما فجوة في **أداة الاختبار المحلية فقط** (ليست في المشروع الفعلي؛ `service_role` الحقيقي في Supabase يملك هذا الوصول أصلًا، وهو بالضبط ما يحاكيه `admin.auth.admin.createUser()` في الكود). أُصلحت الفجوة في `local_harness_setup.sql` نفسه (ليست ترحيلًا وليست جزءًا من مخطط التطبيق) لتطابق قدرات `service_role` الحقيقية.

**خلاصة الملحق الثاني:** كل بند من العشرة كان إما تصعيد صلاحيات حقيقيًا قابلًا للاستغلال فعليًا عبر PostgREST مباشرة، أو غموضًا تصميميًا كان سيتحول لثغرة أمنية فعلية بمجرد أن يصبح هناك أكثر من Super Admin واحد نشط أو مستخدم بصلاحيات جزئية متداخلة — وكلاهما نمط لا يظهر إلا باختبار فعلي ببيانات ومستخدمين متعددين حقيقيين، وليس بمراجعة كود نظرية. الأساس المعماري جاهز الآن للبدء بوحدة المبيعات وفق التوجيه الأصلي، بعد مراجعتين أمنيتين مستقلتين متتاليتين ولا ثغرة معروفة متبقية على مستوى قاعدة البيانات.

---

## الملحق الثالث — "Foundation Hardening 1.3": مراجعة أمنية مستقلة ثالثة وإصلاحاتها (ترحيلات 0025–0031)

بعد الملحق الثاني، رُوجِعت نسخة الـZIP الخاصة بـ"Foundation Hardening 1.2" والكود الفعلي مرة أخرى بشكل مستقل. الإصلاحات 0017–0024 كانت موجودة فعليًا وجيدة، لكن مراجعة ثالثة أعمق — هذه المرة تدقق تحديدًا في **اكتمال** كل إصلاح سابق (وليس فقط وجوده) — كشفت تسعة بنود إضافية: بعضها استكمال لإصلاح 1.2 لم يكن مكتملًا (يغطي فرعًا واحدًا فقط من عملية بفرعين، مثل `INSERT` بلا `DELETE`)، وبعضها ثغرة التفاف (Bypass) عبر تسلسل خطوات مشروعة كل واحدة منها بمفردها، وبعضها إعادة تصميم معماري (تفويض الأعمدة). الشرط كان مطابقًا للمرتين السابقتين: **لا تبدأ Master Data/Sales حتى إغلاق كل بند من التسعة على مستوى القاعدة**، بترحيلات SQL **جديدة فقط (0025–0031)** دون تعديل أي ملف من 0001–0024. هذا القسم يوثّق كل بند، ماذا كانت المشكلة تحديدًا، وكيف أُغلقت.

### 1. إغلاق تفويض نطاق المتجر بالكامل، وليس `INSERT` فقط (0025)
0018 كانت تحدّ فعليًا تفويض `INSERT` على `user_store_access` بما يملكه المانح نفسه من متاجر تشغيلية (`user_operable_store_ids`)، وتشترط `users.manage_store_access` لتعديل `store_access_scope`/`default_store_id`، وتقصر `scope='all'` على Super Admin — لكن **فرع `DELETE`** على `user_store_access` كان لا يزال بلا أي حدّ تفويض: فاعل بنطاق تشغيل A+B كان يستطيع نظريًا **حذف** وصول مستخدم آخر لمتجر C — متجر لا يملك هو نفسه صلاحية العمل عليه — رغم أن سحب وصول غيرك لمتجر لا تُشرف عليه خطر بنفس درجة منحه إياه. كذلك، `default_store_id` نفسه (عمود منفصل عن `user_store_access`) لم يكن مُقيَّدًا بنطاق تشغيل المانح إطلاقًا: فاعل A+B كان يستطيع تعيين متجر C كـ"افتراضي" لمستخدم آخر (مثلًا أثناء تحويله لنطاق `single`) رغم عدم امتلاكه صلاحية العمل على C. أُغلق الاثنان معًا عبر `CREATE OR REPLACE` لدالتي 0018 (`enforce_store_access_delegation`, `enforce_store_scope_authorization`): الأولى أصبحت تشترط نطاق التشغيل على فرعي `INSERT`/`DELETE` معًا، والثانية أضافت فحصًا مستقلًا لـ`default_store_id` نفسه. **اختُبر فعليًا بفاعل محدود النطاق حقيقةً (013، نطاقه A+B فقط، لا يملك C إطلاقًا)** — كما طُلب صراحة عدم الاختبار عبر Admin كامل الصلاحيات: (1) محاولة تعيين نطاق هدف إلى `single`/افتراضي=C فشلت، (2) محاولة منح C للهدف فشلت، (3) محاولة حذف C من هدف يملك A+C فشلت (هذا تحديدًا الفرع الجديد)، (4) تعديل A/B (منح ثم سحب) على الهدف نجح بدقة، والمتجر C بقي بلا تغيير طوال ذلك.

### 2. استقلالية `users.manage_store_access` الكاملة — مسار `SELECT` (0028)
0018 منحت `users.manage_store_access` سياسات `INSERT`/`DELETE`/`UPDATE` خاصة بها على `user_store_access`/`profiles`، لكن سياسة `SELECT` الأصلية على `user_store_access` (0010) بقيت تشترط `users.view`/`stores.view` فقط، بلا مسار بديل لـ`users.manage_store_access`. هذه فجوة حقيقية وقابلة للاستغلال: `replace_user_store_access()` (دالة `SECURITY INVOKER`، 0018) تحسب الفرق بمقارنة الوصول **الحالي** (عبر `SELECT` خاضع لـRLS الفاعل نفسه) بالوصول **المطلوب** — فاعل يملك `users.manage_store_access` فقط (بلا `users.view`/`stores.view`) كان سيرى الوصول الحالي **فارغًا دائمًا** بغضّ النظر عن الواقع، فتُحسَب كل الصفوف الموجودة فعليًا على أنها "يجب إضافتها من جديد" فيفشل الاستدعاء بخطأ تكرار مفتاح أساسي بدل أن ينجح بحساب فرق صحيح. أُضيفت سياسة `SELECT` إضافية (تُضاف لا تستبدل — Postgres يجمع السياسات التساهلية بـOR) تمنح الرؤية لحامل `users.manage_store_access` مباشرة. **اختُبر فعليًا:** فاعل (013 نفسه، يملك `manage_store_access` + `users.view` — الأخيرة ضرورية لرؤية صفّ الملف الشخصي نفسه أصلًا قبل أي تعديل عليه، وهذا **متوقَّع ومقصود**: رؤية المستخدم مسؤولية `users.view`، وتفويض تعديل نطاقه مسؤولية `users.manage_store_access` — الصلاحيتان مستقلتان عمدًا؛ أما `stores.view`/`users.manage_permissions` فلا حاجة لهما إطلاقًا) استدعى `replace_user_store_access()` على هدف يملك بالفعل A+B مطلوبًا منه B فقط — نجح الاستدعاء وحذف A بدقة، لا خطأ تكرار مفتاح كان سيحدث بدون هذا الإصلاح.

### 3. إعادة كتابة تفويض الأعمدة كصلاحيات مستقلة تمامًا لكل مجموعة (0030)
**قبل:** `enforce_profile_update_column_authorization()`/`enforce_store_update_column_authorization()` (0014، أُعيدت من 0018) كانتا بشكل "أول صلاحية عريضة تطابق تفوز، ثم تتجاوز كل شيء آخر": فرع `users.edit` كان يُرجِع النجاح فورًا **بلا أي قيد على أي عمود**، بما فيه `status` — أي أن حامل `users.edit` كان يستطيع فعليًا تعطيل/تفعيل حساب مستخدم مباشرة، رغم وجود `users.disable` كصلاحية منفصلة مخصَّصة لهذا الغرض تحديدًا (نفس الشيء لـ`stores.edit` مقابل `stores.disable`). هذا يُبطل الغاية الكاملة من فصل الصلاحيتين. **بعد:** لا صلاحية تُمرِّر أي عمود تخصّ مجموعة أخرى — كل مجموعة أعمدة تتطلب صلاحيتها الخاصة بشكل مستقل: `profiles.full_name → users.edit` فقط، `profiles.status → users.disable` فقط، `profiles.{store_access_scope,default_store_id} → users.manage_store_access` فقط (كانت محمية بالفعل عبر Trigger مستقل من 0018، لكن أصبحت الآن متسقة صراحة مع نفس مبدأ هذا الملف)؛ `stores.{code,name_ar,name_en,logo_url,description} → stores.edit` فقط، `stores.status → stores.disable` فقط. تعديل يشمل أكثر من مجموعة في تحديث واحد يتطلب **اتحاد** كل الصلاحيات المعنية معًا — لا اختصار. الاستثناء الوحيد المتعمَّد: `finalize_new_user_profile()` (تحتاج تعديل `full_name`+`status`+نطاق المتجر معًا بصلاحية `users.create` وحدها) يتجاوز هذه الفحوصات عبر علم GUC مؤقت على مستوى المعاملة (`app.finalize_provisioning`)، يُضبَط داخل الدالة نفسها فقط حول تحديثها الوحيد ويُعاد ضبطه فورًا — **لا يتجاوز** القيود الأخرى المستقلة (المنع الذاتي، `scope='all'` لغير Super Admin، حدّ نطاق التشغيل على `default_store_id`) التي تبقى فعّالة حتى أثناء `finalize`. **اختُبر فعليًا:** حامل `users.edit` فقط (بلا `users.disable`) فشل في تغيير `status` لمستخدم آخر؛ حامل `users.disable` فقط (بلا `users.edit`) فشل في تغيير `full_name`؛ حامل الاثنين معًا نجح في تحديث مُجمَّع لهما في استدعاء واحد؛ ونفس الثلاثة للمتاجر (`stores.edit` وحدها لا تُعطِّل متجرًا، `stores.disable` وحدها لا تُعدِّل اسمه، الاثنان معًا ينجحان مُجمَّعين).

### 4. إغلاق مسار الالتفاف حول التزويد نهائيًا (0029)
0019 أضافت `pending_setup` لتمييز "حساب جديد لم يكتمل تزويده" عن "حساب حقيقي عُطِّل عمدًا"، واشترطت `users.create` تحديدًا للانتقال المباشر `pending_setup → active`. لكن هذا الحل كان لا يزال قابلًا للالتفاف عبر خطوتين، كلٌّ منهما مشروعة بمفردها: حامل `users.disable` (بلا `users.create` إطلاقًا) يستطيع نقل `pending_setup → suspended` (تعطيل عادي، غير مُقيَّد بـ`users.create`)، ثم لاحقًا `suspended → active` (إعادة تفعيل عادية) — و**لا شيء** في 0019 كان يمنع هذه الحلقة الثانية تحديدًا، لأن شرطها (`old.status = 'pending_setup' and new.status = 'active'`) لا يُطابِق `old.status = 'suspended'`. النتيجة: حساب لم يُزوَّد أبدًا فعليًا (لا اسم حقيقي، لا نطاق وصول مُراجَع) يصل لحالة `active` كاملة، متجاوزًا `users.create` تمامًا. **الحل:** عمود دائم مستقل تمامًا عن `status`، `provisioned_at` — يُضبَط مرة واحدة فقط بواسطة `finalize_new_user_profile()` (أو سياق Bootstrap موثوق، ليشمل مثلًا `scripts/create-super-admin.ts` الذي يُفعِّل أول Super Admin مباشرة عبر SQL موثوق بلا المرور بـ`finalize_new_user_profile()` إطلاقًا — يُختَم `provisioned_at` تلقائيًا في تلك اللحظة أيضًا ليبقى قابلًا لإعادة التفعيل لاحقًا بشكل طبيعي)، وTrigger مستقل يرفض **أي** كتابة تُبقي `status='active'` بينما `provisioned_at` لا يزال فارغًا — بصرف النظر عن التسلسل الذي أوصل الحساب لهذه النقطة. **اختُبر فعليًا بالسيناريو الدقيق المطلوب:** فاعل يملك `users.edit`+`users.disable`+`users.manage_store_access` معًا (لكن **بلا** `users.create` إطلاقًا) نفَّذ الخطوتين المشروعتين (`pending_setup → suspended` ثم تجهيز نطاق وصول) بنجاح، ثم فشلت محاولة الخطوة الثالثة (`suspended → active`) تحديدًا — وهي بالضبط الثغرة التي كانت مفتوحة قبل 0029. **ضابط إيجابي:** حساب مُزوَّد فعليًا (009، المُفعَّل عبر `finalize_new_user_profile()` في القسم 9ب) لا يزال يُعطَّل ويُعاد تفعيله بشكل طبيعي عبر `users.disable` العادية — القيد الجديد لا يكسر التدفق اليومي المشروع، فقط يمنع الحساب الذي لم يُزوَّد أبدًا من الوصول لـ`active`.

### 5. حماية الصلاحيات الحسّاسة على مسار السحب أيضًا، لا المنح فقط (0027)
0013 كانت تحمي **منح** الصلاحيات الحسّاسة الثلاث (`users.manage_permissions`, `settings.manage`, `backups.manage`) فقط — عبر `role_permissions` (`INSERT` حصرًا)، أو `user_permission_overrides` (فرع `effect='grant'` فقط، `INSERT`/`UPDATE` حصرًا)، أو إسناد دور يحملها. هذا كان تحصينًا **غير متماثل**: لا شيء كان يمنع حامل `users.manage_permissions` (غير Super Admin) من فعل العكس تمامًا — **سحب** صلاحية حسّاسة من دور أو مستخدم آخر (`DELETE` على `role_permissions`، إضافة استثناء `revoke` أو حذف استثناء قائم على `user_permission_overrides`)، أو **إزالة** دور يحمل صلاحية حسّاسة من مستخدم عبر `user_roles` — وكلها بنفس درجة خطورة المنح: تُغيِّر من يملك السيطرة النهائية على نظام الصلاحيات، وقد تُستخدَم لتجريد مسؤولين آخرين ممن يستطيعون إيقاف الفاعل. أُضيفت ثلاثة Triggers مقابلة (متماثلة مع 0013 دون تعديل ملفه): سحب صلاحية حسّاسة من دور، أي تغيير (منح/سحب/حذف استثناء) لصلاحية حسّاسة على `user_permission_overrides` بصرف النظر عن `effect`، وإزالة دور يحمل صلاحية حسّاسة من مستخدم — كلها تتطلب Super Admin الآن. **اختُبر فعليًا:** حامل `users.manage_permissions` (Admin، غير Super Admin) فشل في: حذف `settings.manage` من دور `admin`، إضافة استثناء `revoke` لـ`users.manage_permissions` على مستخدم آخر، حذف استثناء `grant` قائم لـ`backups.manage` (كان أنشأه Super Admin مسبقًا)، وإزالة دور `admin` (يحمل صلاحيات حسّاسة) عن مستخدم آخر يحمله.

### 6. حماية Super Admin ككيان كامل، لا حذف دور `super_admin` فقط (0026)
0020 أغلقت تعديل صفّ `profiles` وحذف دور `super_admin` نفسه لأي Super Admin هدف من أي فاعل ليس هو نفسه Super Admin. لكن ثلاث ثغرات بقيت مفتوحة: (أ) إسناد دور **إضافي** (غير `super_admin`) لمستخدم يحمل `super_admin` بالفعل — 0020 تمنع فقط **حذف** `super_admin` نفسه، لا إضافة أي دور آخر عليه؛ (ب) منح/سحب/تعديل استثناء صلاحية فردي (`user_permission_overrides`) لهدف Super Admin — غير مُغطاة إطلاقًا بـ0020 (التي تغطي `profiles`/`user_roles` فقط)؛ (ج) منح/سحب وصول متجر (`user_store_access`) لهدف Super Admin — كذلك غير مُغطاة. أُضيف Trigger واحد مشترك (`protect_super_admin_entity`)، مرتبط بعمود `user_id` الموجود بنفس الاسم في الجداول الثلاثة، على `BEFORE INSERT OR UPDATE OR DELETE` لـ`user_roles`/`user_permission_overrides` و`BEFORE INSERT OR DELETE` لـ`user_store_access` — يمتد حماية 0020 من "الصفّ نفسه + حذف الدور" إلى "كل ما يحدد صلاحيات ووصول Super Admin كأثر كامل". **اختُبر فعليًا بوجود Super Admin نشطَين اثنين** (تمامًا كضابط 0020 الأصلي): Admin عادي (003) فشل في إسناد دور إضافي (`sales_employee`، لا علاقة له بصلاحيات حسّاسة) لـSuper Admin آخر، فشل في إضافة استثناء صلاحية **غير حسّاسة** (`dashboard.view`) له، وفشل في منحه وصول متجر — رغم أن 003 يملك `users.manage_store_access` ونطاقه `all`. **ضابط إيجابي:** Super Admin آخر (001) نجح في إضافة نفس استثناء `dashboard.view` لزميله Super Admin — الحماية خاصة بالفاعل غير Super Admin فقط، وليست منعًا مطلقًا لتعديل أي شيء متعلق بـSuper Admin.

### 7. تحصين الجلسات غير النشطة (0031 + `src/lib/supabase/middleware.ts`)
**على مستوى القاعدة:** `get_user_permissions()`/`has_permission()` (0008) كانتا تفشلان بأمان أصلًا لحساب غير نشط (تُرجعان مجموعة فارغة/`false`)، لكن `user_operable_store_ids()`/`user_visible_store_ids()` (0017) — ومن ثمّ الأغلفة الذاتية `my_operable_store_ids()`/`my_visible_store_ids()` — لم تكونا تفحصان `profiles.status` إطلاقًا، فقط تُحلِّلان `store_access_scope`/`user_store_access` مباشرة بلا قيد. لجلسة JWT قد لا تزال تقنيًا موجودة لمستخدم عُطِّل للتو، كانتا ستُرجعان قائمة متاجره الكاملة كأن الحساب لا يزال نشطًا. أُصلحتا (`CREATE OR REPLACE`) لتُرجعا مجموعة فارغة فورًا لأي حساب غير `active`، بنفس مبدأ `is_active_user()` الذي تعتمده الدوال الأخرى أصلًا — والأغلفة الذاتية ترث الإصلاح تلقائيًا كونها مجرد أغلفة رقيقة تستدعيها. **اختُبر فعليًا:** حساب (010) عُطِّل فعليًا مع بقاء بيانات `store_access_scope`/`default_store_id` سليمة تمامًا — كلتا الدالتين (بالمعرّف الصريح، وذاتيتا النطاق عبر جلسة JWT مُحاكاة لنفس المستخدم) أرجعتا مجموعة فارغة؛ **ضابط سلبي:** حساب نشط (002) لا يزال يحصل على نتيجة صحيحة، يثبت أن الإصلاح خاص بالحسابات غير النشطة فقط.

**على مستوى التطبيق (حلقة إعادة توجيه):** `updateSession()` (الـ Middleware) كانت تُعيد توجيه أي طلب لـ`/login` بينما `user` (من JWT فقط) صحيح مباشرة لـ`/dashboard` — بلا أي فحص لـ`profiles.status`. بينما `requireSession()` (`guard.ts`) تُعيد توجيه مستخدم غير نشط من أي صفحة محمية إلى `/login?suspended=1` بشكل منفصل. مستخدم عُطِّل أثناء جلسته (JWT لا يزال صالحًا تقنيًا — لا شيء يُبطله فورًا فقط لأن `status` تغيّر في جدول منفصل) كان يدخل حلقة لا نهائية: `guard.ts` يرسله لـ`/login`، الـMiddleware يعيده فورًا لـ`/dashboard` لأن `user` لا يزال صحيحًا، وتكرار. **الحل:** الـMiddleware أصبح يجلب `profiles.status` صراحة لكل طلب موثَّق، وإن لم يكن الحساب نشطًا: يُنهي الجلسة فعليًا (`supabase.auth.signOut()`، مع نسخ تعديلات الكوكيز من `response` المؤقت إلى استجابة إعادة التوجيه النهائية — وإلا لن تُطبَّق فعليًا على المتصفح) ويُعيد التوجيه مباشرة لـ`/login?suspended=1` **بدل** المرور بمسار `/dashboard` إطلاقًا، فتنكسر الحلقة من جذرها بدل معالجة أعراضها فقط. الانتقال `login → dashboard` يبقى كما كان، لكن الآن مشروطًا فعليًا بأن يكون الحساب نشطًا، لا بمجرد وجود JWT.

### 8. اكتمال واجهة `pending_setup` (`user-status-badge.tsx`, `user-status-toggle.tsx`, `users-toolbar.tsx`)
**قبل:** `UserStatusBadge` كانت تعرض أي حالة غير `active` كـ"معطّل" (badge رمادي) — `pending_setup` (حساب دُعي للتو، لم يُزوَّد بعد) كان يبدو مطابقًا بصريًا لحساب مُعطَّل عمدًا رغم اختلافهما الجوهري (0019/0029). و`UserStatusToggle` كانت زرًّا ثنائيًا بسيطًا (تشغيل/إيقاف) يعرض دائمًا "إعادة تفعيل" لأي حالة غير `active` — بما فيها `pending_setup`، رغم أن الضغط عليه كان سيُرسل `status='active'` مباشرة عبر `setUserStatusAction`، وهي عملية **لا معنى لها** الآن أصلًا (تتطلب `users.create` عبر `finalize_new_user_profile()`، لا `users.disable` الذي يحكم هذا الزر). **بعد:** `UserStatusBadge` تعرض `pending_setup` كشارة مستقلة ("قيد الإعداد"، لون `warning`). `UserStatusToggle` أصبحت تُميّز ثلاث حالات: `pending_setup` → زر "إلغاء الدعوة" فقط (ينقل إلى `suspended`، لا زر "تفعيل" إطلاقًا)؛ `suspended` بدون `provisioned_at` (دعوة أُلغيت فعليًا ولم تكتمل قط) → لا يُعرَض أي زر إطلاقًا (إعادة تفعيلها ستُرفَض على مستوى القاعدة على أي حال بموجب 0029، ولا مسار مفيد لها هنا سوى دعوة جديدة كاملة)؛ الحالة الاعتيادية (`active`/`suspended` مع `provisioned_at`) → السلوك الأصلي (تعطيل/إعادة تفعيل). أُضيف أيضًا خيار فلترة `pending_setup` في شريط أدوات المستخدمين (`users-toolbar.tsx`) للاتساق.

### 9. توسيع اختبارات SQL + تشغيل التحقق الكامل
أُضيفت سبعة أقسام جديدة (18–24) لملف الاختبار، تغطي التسعة بنودًا أعلاه، **باستخدام فاعلين محدودَي النطاق فعليًا وليس Admin كامل الصلاحيات** — تحديدًا الفاعل 013 (نطاق `multiple`، A+B فقط، **لا** يملك C إطلاقًا) لاختبارات `users.manage_store_access`، بدل الاعتماد على فاعل يملك أصلًا كل شيء والذي كان سيُخفي أي ثغرة حدّ نطاق حقيقية. **نتائج فعلية (وليست افتراضًا):**
- أُعيد بناء قاعدة اختبار Postgres محلية **من الصفر بالكامل** (حذف القاعدة والأدوار الثلاثة، إعادة إنشائها، `local_harness_setup.sql`، كل الترحيلات 0001–0031 بالترتيب، ثم `seed.sql`) قبل تشغيل اختبار التكامل.
- `npm run typecheck` → صفر أخطاء.
- `npm run lint` → صفر أخطاء وتحذيرات.
- `npm run test` (Vitest) → `25/25` ناجح (24 سابقًا + اختبار جديد لفشل `pending_setup` الآمن في `sessionHasPermission`).
- `npm run build` (Next.js/Turbopack) → نجح، 17 مسارًا.
- اختبار SQL التكاملي → **نجح بالكامل**، `=== ALL RLS/PERMISSION/AUDIT/ESCALATION TESTS PASSED (including Foundation Hardening 1.3) ===`، **96 تأكيد "OK" عبر 24 قسمًا** (71 عبر 17 قسمًا سابقًا).

**ملاحظة تقنية اكتُشفت أثناء كتابة اختبارات هذه المراجعة:** محاولة اختبار فاعل يملك `users.manage_store_access` **حصرًا** (بلا `users.view` إطلاقًا) وهو يُحدِّث `store_access_scope` لمستخدم آخر كشفت أن Postgres RLS يتطلب أن يكون الصفّ **مرئيًا** عبر سياسة `SELECT` قبل أن تُستشار سياسة `UPDATE` عليه إطلاقًا — بصرف النظر عن نجاح سياسة `UPDATE` نفسها؛ التحديث كان يُطابِق صفرًا من الصفوف بصمت (بلا خطأ) بدل التعديل الفعلي أو الرفض الصريح. هذه ليست ثغرة تحتاج إصلاحًا (رؤية ملف المستخدم مسؤولية `users.view` عمدًا، منفصلة عن تفويض تعديل نطاقه) بل توضيح تصميمي صريح — تمامًا كما أشار طلب هذه المراجعة نفسه ("زائد ما يلزم لرؤية المستخدم المستهدف") — فعُدِّل الفاعل الاختباري ليحمل `users.view` أيضًا لاختبارات `profiles`، مع إبقائه بلا `stores.view`/`users.manage_permissions` لعزل ما يُختبَر فعليًا (استقلالية `user_store_access` عبر `users.manage_store_access` وحدها تبقى مُختبَرة بلا `users.view` في القسم 19 تحديدًا، حيث لا حاجة له أصلًا).

**خلاصة الملحق الثالث:** كل بند من التسعة كان إما استكمالًا حقيقيًا لإصلاح 1.2 غطى فرعًا واحدًا فقط من عملية بفرعين (`INSERT` بلا `DELETE`، منح بلا سحب، حذف دور `super_admin` بلا حماية باقي أثره)، أو ثغرة التفاف قابلة للاستغلال فعليًا عبر تسلسل خطوات كل واحدة مشروعة بمفردها (`pending_setup → suspended → active`)، أو إعادة تصميم معماري ضروري (تفويض الأعمدة كصلاحيات مستقلة). الأساس المعماري جاهز الآن للبدء بوحدة المبيعات وفق التوجيه الأصلي، بعد ثلاث مراجعات أمنية مستقلة متتالية ولا ثغرة معروفة متبقية على مستوى قاعدة البيانات.

---

## الملحق الرابع — "Foundation Hardening 1.4": مراجعة أمنية مستقلة رابعة وإصلاحاتها (ترحيلات 0032–0036)

بعد الملحق الثالث، رُوجِعت نسخة الـZIP الخاصة بـ"Foundation Hardening 1.3" والكود الفعلي مرة رابعة بشكل مستقل. الإصلاحات 0025–0031 كانت موجودة فعليًا وصحيحة، لكن هذه المراجعة كشفت خمسة بنود إضافية: ترقية بيانات تاريخية لم تكن مُعالَجة (لا ثغرة أمنية بحد ذاتها، بل حساب فعلي تُرك بعلامة ناقصة)، إحكام هوية جدول حسّاس، استكمال حساب أثر تفويض نطاق المتجر، استكمال UI/DB flow كامل لصلاحية موجودة أصلًا بلا واجهة تستهلكها بشكل صحيح، وإغلاق مسار كان يترك حسابات Auth عالقة. الشرط كان مطابقًا للمرات الثلاث السابقة: **لا تبدأ Master Data/Sales حتى إغلاق كل بند من الخمسة على مستوى القاعدة**، بترحيلات SQL **جديدة فقط (0032–0036)** دون تعديل أي ملف من 0001–0031. هذا القسم يوثّق كل بند، ماذا كانت المشكلة تحديدًا، وكيف أُغلقت — **بما في ذلك ثلاث مشاكل حقيقية اكتُشفت فقط أثناء التشغيل الفعلي لاختبار SQL** (وليس أثناء مراجعة الكود)، موثَّقة أدناه كملاحظات تقنية.

### 1. ترقية `provisioned_at` للحسابات الموجودة قبل 0029 (0032)
**قبل:** 0029 (Foundation Hardening 1.3) أضافت `profiles.provisioned_at` ومنعت أي حساب **جديد** من الوصول لـ`status='active'` بدون ضبطه — لكنها لم تملأ العمود لأي حساب **موجود بالفعل** وقت إضافته، فتُرك كل حساب نشط من قبل 0029 بـ`provisioned_at IS NULL` رغم كونه مُزوَّدًا فعليًا بالكامل. عمليًا، هذا لا يمنعه من العمل (Trigger 0029 يفحص فقط عند `UPDATE` يبقي `status='active'` مع `provisioned_at` لا يزال فارغًا)، لكنه يترك بيانات ناقصة/مضلِّلة لأي استعلام أو تقرير مستقبلي يعتمد على هذا العمود كدليل تزويد. **بعد:** `0032` (Backfill بيانات بحتة — لا `CREATE OR REPLACE` ولا تعديل أي Trigger) يُشغِّل تحديثين:
- **الحالة أ:** كل حساب `status='active'` بـ`provisioned_at IS NULL` يأخذ `created_at` كتقدير معقول (أفضل مصدر متاح لتاريخ تزويد لم يُسجَّل وقته الحقيقي).
- **الحالة ب:** كل حساب `status='suspended'` بـ`provisioned_at IS NULL` **وله دليل تاريخي** في `audit_logs` على أنه كان `active` فعلًا (`action='user.update'` و`new_values->>'status'='active'`) يأخذ أقدم تاريخ نشاط مسجَّل له من ذلك السجل — سياسة صريحة ومقصودة لحسابات "كانت نشطة ثم عُطِّلت"، بعكس حسابات "دُعيت ولم تكتمل أبدًا".

**سياسة الحسابات المُعطَّلة بلا دليل نشاط:** تُترَك عمدًا `provisioned_at IS NULL`. لا فرق فعليًا بين "دعوة أُلغيت قبل اكتمالها" (لم تُزوَّد قط) و"حساب قديم مُعطَّل جدًا لدرجة أن حتى سجل التدقيق الحالي لا يغطي بداية نشاطه" — وملء العمود بتخمين (مثلًا `created_at` كذلك) كان سيزعم تزويدًا لم يحدث فعليًا بدل توثيق حالة غير معروفة بصدق. **الشرط الصريح المطلوب ("لا تترك active legacy profile بـ`provisioned_at IS NULL`") محقَّق بالكامل** — الاستثناء الوحيد المتبقي هو حسابات `suspended` بلا دليل، وهي بالتعريف ليست "نشطة".

**اختُبر فعليًا (القسم 25 من اختبار SQL):** أُنشئت ثلاثة حسابات اصطناعية تُحاكي بيانات ما قبل 0029 — حساب نشط بـ`provisioned_at` مُفرَّغ يدويًا، حساب مُعطَّل بدليل نشاط تاريخي حقيقي في `audit_logs`، وحساب مُعطَّل بلا أي دليل — ثم أُعيد تشغيل تحديثَي 0032 حرفيًا وتحقَّق الاختبار أن الأول والثاني امتلآ بالقيم الصحيحة والثالث بقي فارغًا كما هو متوقَّع.

> **ملاحظة تقنية (اكتُشفت أثناء بناء بيانات الاختبار، وليست خللًا في 0032 نفسها):** لبناء حساب اصطناعي "نشط بـ`provisioned_at` فارغ" لمحاكاة ما قبل 0029، أول محاولة استخدمت `UPDATE ... SET provisioned_at = null` على صف نشط بالفعل — فشلت بصمت (القيمة عادت ممتلئة فورًا) لأن `enforce_activation_requires_provisioning()` (0029) يُعيد ختم `provisioned_at := now()` تلقائيًا على **أي** كتابة (حتى من سياق موثوق) تُبقي الصف `active` بينما `provisioned_at` يُصبح فارغًا — سلوك صحيح ومقصود لحركة المرور الحقيقية، لكنه يُفشِل بالتحديد محاولة تصنيع بيانات "قديمة" عبر UPDATE عادي. بالمثل، `enforce_system_managed_columns()` (0021) يُثبِّت `created_at` على قيمته الأصلية في كل `UPDATE` بلا استثناء، فمحاولة إرجاع تاريخ الإنشاء للوراء كانت ستفشل كذلك. **الحل** (في ملف الاختبار فقط، وليس تعديلًا على أي Migration): تعطيل الـTrigger صراحة حول عبارة بناء البيانات الاصطناعية فقط (`ALTER TABLE public.profiles DISABLE TRIGGER ...` ثم `ENABLE TRIGGER` فورًا بعدها) — عملية DDL بصلاحية Superuser محلية فقط، تُحاكي بدقة "هذا الصف كان موجودًا فعلًا قبل إضافة هذا العمود/القيد" بدل الالتفاف حول منطق الإنتاج نفسه.

### 2. قفل هوية `user_permission_overrides` (0033)
**قبل:** `user_id`/`permission_id` (المفتاح الأساسي المركَّب للجدول) كانا قابلين للتغيير عبر `UPDATE` عاديّ بلا أي قيد إضافي غير RLS/Triggers الحالية على القيم الجديدة — أي أن Super Admin (أو أي فاعل تجاوز الفحوصات الأخرى لسبب ما) كان يستطيع نظريًا "نقل" استثناء موجود من مستخدم لآخر، أو من صلاحية غير حسّاسة إلى صلاحية حسّاسة، عبر تعديل الهوية مباشرة بدل حذف الصف القديم وإدراج صف جديد — وهو تحديدًا المسار الذي يُشغِّل فحوصات 0013/0027 الحسّاسة (تلك الفحوصات مبنية على `INSERT`/`DELETE`، ولم تكن تراقب `UPDATE` لعمودي الهوية نفسيهما إطلاقًا). **بعد:** Trigger جديد (`enforce_permission_override_identity`) على `BEFORE UPDATE` يرفض أي `UPDATE` يُغيِّر `user_id` أو `permission_id` — **بلا أي استثناء لـSuper Admin** (فقط `is_trusted_bootstrap_context()` يتجاوزه) — الهوية غير قابلة للتغيير نقطة، لا حتى لأعلى صلاحية في النظام؛ نقل استثناء يتطلب حذفًا وإدراجًا صريحين، فتُعاد فحوصات 0013/0027 من الصفر تلقائيًا. `effect`/`reason` يبقيان قابلين للتعديل بلا قيد إضافي — القفل يخص الهوية فقط.

**اختُبر فعليًا:** حتى Super Admin (001) فشل في: تغيير `user_id` على استثناء عادي (نقله لمستخدم آخر)، نقل استثناء `settings.manage` (حسّاسة) عبر تغيير `permission_id` إلى `dashboard.view` (غير حسّاسة)، وتغيير `user_id` على استثناء يخصّ هدفًا Super Admin آخر. **ضابط إيجابي:** تعديل `effect`/`reason` فقط (بلا تغيير الهوية) على نفس الاستثناء نجح بشكل طبيعي.

### 3. إكمال تفويض نطاق المتجر لتغييرات `store_access_scope` وحدها (0034)
**قبل:** 0025 أغلقت تفويض `default_store_id` **نفسه** (لا يمكن لفاعل تعيين متجر خارج نطاق تشغيله كافتراضي لمستخدم آخر)، لكن لم تفحص قط ماذا يحدث للوصول **الفعلي** (Effective Access) عندما يتغيّر `store_access_scope` **وحده**، و`default_store_id` يبقى دون تغيير. مثال ملموس: مستهدَف لديه `default_store_id = C` (متجر خارج نطاق تشغيل الفاعل A، الذي يُشغِّل فقط A وB) من `scope='single'` سابق أو من صف `user_store_access` قديم متبقٍّ من `scope='multiple'` سابق — فاعل A يستطيع قلب `store_access_scope` هذا المستهدَف بين `single`/`multiple` فيُدخِل أو يُخرِج C من وصوله الفعلي **بلا أن يتغيّر `default_store_id` نفسه إطلاقًا**، فلا يُفعِّل فحص 0025 أبدًا. **الحل:** دالة مساعدة جديدة `resolve_operable_stores(scope, default_store_id, user_id)` تُحاكي منطق `user_operable_store_ids()` نفسه، لكن بوسائط صريحة بدل قراءتها من الصف — لتُستدعى مرتين داخل نفس Trigger: مرة بقيم `OLD` (الوصول الفعلي **قبل** التغيير) ومرة بقيم `NEW` (الوصول الفعلي **بعده**، رغم أنه لم يُكتَب للصف بعد). الفرق بين المجموعتين يُحسَب، وأي متجر يدخل أو يخرج منه يجب أن يكون ضمن نطاق تشغيل الفاعل نفسه، وإلا تُرفَض العملية بالكامل — طبقة **إضافية** فوق فحص 0025 (الذي يبقى فعّالًا كما هو لحالة `default_store_id` نفسه)، وليست بديلة عنه.

**اختُبر فعليًا (الفاعل 013، نطاقه A+B فقط):** ثلاثة مستهدَفين اصطناعيين — `single`/افتراضي=C (خارج النطاق) بلا صفوف `user_store_access`، و`single`/افتراضي=A (داخل النطاق)، و`multiple` بلا صفوف مع `default_store_id` متروك = C. (أ) قلب الأول إلى `multiple` (C يخرج من الوصول الفعلي، خارج النطاق) **فشل** كما هو متوقَّع. (ب) قلب الثاني إلى `multiple` (A يخرج، لكنه داخل النطاق) **نجح**. (ج) قلب الثالث إلى `single` (C يدخل الوصول الفعلي، خارج النطاق، بلا أن يتغيّر `default_store_id` إطلاقًا) **فشل** كما هو متوقَّع.

> **ملاحظة تقنية جوهرية (خلل SQL حقيقي اكتُشف أثناء تشغيل الاختبار الفعلي — القسم 27ج تحديدًا):** التنفيذ الأول لحساب الفرق بين المجموعتين كتب `(A except B) union (B except A)` **بلا أقواس صريحة**:
> ```sql
> select store_id from new_effective except select store_id from old_effective
> union
> select store_id from old_effective except select store_id from new_effective
> ```
> في SQL، `UNION` و`EXCEPT` لهما **نفس الأولوية** ويُقيَّمان من اليسار لليمين (Left-Associative) — أي أن هذا يُفسَّر فعليًا كـ`((A except B) union B) except A`، وليس `(A except B) union (B except A)` كما كان مقصودًا. الفرق يظهر فقط في حالة معينة: عندما تكون إحدى المجموعتين فارغة والأخرى تحتوي متجرًا واحدًا يدخل (لا يخرج) — بالضبط سيناريو "27ج" أعلاه: `old_effective` فارغة، `new_effective = {C}`. التقييم الخاطئ يُصبح: `(({C} except {}) union {}) except {C}` = `{C} except {C}` = **مجموعة فارغة** — الفحص كله يختفي بصمت والعملية تنجح رغم أنها يجب أن تُرفَض. الاتجاه المعاكس (متجر **يخرج**، وليس يدخل) كان يعمل بالصدفة لأن ترتيب الطرح فيه لا يُلغي النتيجة (وهذا بالضبط ما جعل 27أ ينجح صحيحًا بينما 27ج يفشل بصمت رغم أنهما اختبار المنطق نفسه من الاتجاهين). **الإصلاح:** أقواس صريحة تفرض التجميع الصحيح: `(select ... except select ...) union (select ... except select ...)`. أُعيد بناء قاعدة الاختبار من الصفر وأُعيد التشغيل بعد الإصلاح — 27ج ينجح الآن بشكل صحيح (يُرفَض كما هو متوقَّع)، وبقية الأقسام (25–29) تمر دون تغيير. **هذا الخلل ما كان ليُكتشف بمراجعة كود فقط** — الاستعلام قانوني نحويًا ويُرجِع نتيجة معقولة الشكل (مجموعة فارغة، لا خطأ)، ولم يظهر إلا لأن الاختبار غطّى **كلا الاتجاهين** (دخول وخروج) بفاعلين منفصلين، لا اتجاهًا واحدًا فقط.

### 4. إكمال UI/DB flow لـ`users.manage_store_access` (0035)
0018 (Foundation Hardening 1.2) منحت `users.manage_store_access` مسارات كتابة مستقلة (`INSERT`/`UPDATE`/`DELETE`)، و0028 (1.3) أضافت مسار `SELECT` مستقل لها — لكن **الواجهة نفسها** لم تُبنَ لتستهلك أيًا من ذلك: كانت لا تزال تُغذَّى من `listActiveStoresForSelect()` (مصدر `stores.view`-gated بالكامل). ثلاث فجوات حقيقية نتجت عن هذا، أُغلقت الثلاث معًا في 0035:

- **فجوة 1 (الأخطر):** فاعل يملك `users.manage_store_access` **فقط** (بلا `stores.view`، وهو تحديدًا مجموعة الصلاحيات الضيقة التي صُمِّمت من أجلها هذه الصلاحية) كان يحصل على **قائمة متاجر فارغة تمامًا** في الواجهة، رغم أن القاعدة تدعم كتابته بالكامل منذ 0018 — ميزة كاملة معطَّلة فعليًا لهذا الدور رغم عدم وجود أي قيد حقيقي يمنعها. **الحل:** دالة `manageable_stores_for_actor()` جديدة، ذاتية النطاق (`auth.uid()`)، مقصورة على `users.manage_store_access` ونطاق تشغيل الفاعل (أو كل متجر نشط لـSuper Admin)، **بلا اعتماد على `stores.view` إطلاقًا** — تُغذِّي كلًا من نموذج نطاق المتجر (`UserStoreScopeForm`) ومحرِّر وصول المتاجر (`UserStoreAccessEditor`) في `src/app/(app)/users/[id]/page.tsx` بدل المصدر القديم.
- **فجوة 2:** حتى حامل `stores.view` كان يرى **كل** متجر في النظام في هذين النموذجين، لا فقط المتاجر التي يستطيع فعليًا تفويضها — فاعل بنطاق A+B كان يرى C ويستطيع محاولة اختياره، ليُرفَض لاحقًا على مستوى القاعدة (0018/0025) — تجربة مربكة، وتُفصِح عن وجود/اسم متجر C لفاعل لا علاقة له به. `manageable_stores_for_actor()` نفسها تحل هذه الفجوة أيضًا (مقصورة على نطاق الفاعل بغضّ النظر عن `stores.view`).
- **فجوة 3:** `setUserStoreAccessAction` ترسل **كامل** اختيار العميل المُعدَّل إلى `replace_user_store_access()` كالمجموعة المطلوبة الجديدة. إن كان المستهدَف يملك أصلًا متجرًا (لتكن C) خارج نطاق تشغيل الفاعل، فواجهة الفاعل (بعد إصلاح الفجوة 1/2) لن تعرضه إطلاقًا كخيار — فلا يمكن أن يظهر ضمن القائمة المُرسَلة أبدًا، ما يعني أن الفرق المحسوب سيعتبر C "يجب حذفه" (موجود في "الحالي"، غائب عن "المطلوب") فتفشل `enforce_store_access_delegation`'s (0018/0025) فحص حدّ النطاق على C فتفشل العملية **بالكامل** — رغم أن الفاعل لم يقصد لمس C إطلاقًا وكان فقط يعدِّل A/B. **الحل:** `replace_user_store_access()` (`CREATE OR REPLACE` من 0035) يستثني الآن أي مرشَّح حذف **خارج نطاق تشغيل الفاعل نفسه** (ما لم يكن Super Admin) من عملية الحذف صراحة، تاركًا إياه بلا تغيير بدل محاولته وفشل العملية كلها بسببه. الإضافة تبقى بلا استثناء مماثل عمدًا: محاولة **إضافة** متجر خارج النطاق لا تزال تُرفَض (وهذا خطأ حقيقي يستحق الظهور، وليس شيئًا يُفترض تجاهله بصمت) — لكن واجهة سليمة (بعد الفجوة 1/2) لن تعرض أصلًا خيارًا كهذا للمستخدم.
- **إضافيًا:** سياسة `SELECT` المُضافة في 0028 لحامل `users.manage_store_access` كانت تكشف **كل** صف في `user_store_access`، بلا قيد نطاق — فاعل A+B كان يرى من يملك وصولًا لمتجر C أيضًا، بلا حاجة فعلية لذلك. `DROP`+`CREATE` (Postgres لا يدعم `ALTER POLICY` على `USING` مباشرة) لنفس السياسة (لم يُعدَّل ملف 0028 نفسه) قصرتها على نطاق تشغيل الفاعل (أو كل صف لـSuper Admin) — إضافية فوق سياسة `SELECT` الأصلية غير المقيَّدة بمتجر (0010: `user_id = auth.uid() OR users.view OR stores.view`)، التي تبقى كما هي بلا تأثير.

**اختُبر فعليًا (فاعل 028، يملك `users.manage_store_access` حصرًا — بلا `users.view`/`stores.view`/`users.manage_permissions` إطلاقًا؛ مستهدَف 029 بمنح A+C):** (أ) `manageable_stores_for_actor()` أرجعت بالضبط {A,B} بلا C. (ب) `SELECT COUNT(*)` مباشر على `user_store_access` للمستهدَف أرجع 1 فقط (A مرئي، C مخفي بالسياسة المُضيَّقة). (ج) `replace_user_store_access(029, [B])` نجح وترك الحالة النهائية {B, C} بدقة — A حُذف، B أُضيف، C بقي بلا تغيير رغم عدم ظهوره في الطلب إطلاقًا. **ضابط سلبي:** فاعل لا يملك `users.manage_store_access` إطلاقًا يحصل على قائمة فارغة من `manageable_stores_for_actor()`.

> **ملاحظتان تقنيتان إضافيتان (أخطاء SQL حقيقية اكتُشفت أثناء تطبيق 0035 على قاعدة فعلية، أُصلحتا قبل أن يصل الملف إلى نسخته النهائية):**
> 1. **مأزق تسمية عمود دالة SRF:** `select store_id from public.my_operable_store_ids()` فشلت بـ`column "store_id" does not exist" — دالة بتوقيع `RETURNS SETOF uuid` بلا مُعامِلات OUT اسمية، عمودها الناتج يحمل اسم **الدالة نفسها** افتراضيًا عند عدم وجود Alias صريح، وليس أي اسم عشوائي. **الإصلاح المُعتمَد** (ثلاثة مواضع في 0035): `select * from public.my_operable_store_ids()` بدل تسمية عمود صريحة غير موجودة.
> 2. **حدود صلاحية `SECURITY DEFINER`:** `public.is_super_admin(auth.uid())` — التي عُدَّت في 0015 `service_role`-only صراحة (`REVOKE ... FROM authenticated`) — استُدعيت مباشرة داخل `replace_user_store_access()` (`SECURITY INVOKER`) وداخل شرط `USING` لسياسة RLS الجديدة، وكلاهما يُنفَّذ بصلاحيات **المستدعي الفعلي** (`authenticated`)، لا بصلاحيات مالك دالة `SECURITY DEFINER` مرتفعة — ففشلا بـ"permission denied for function is_super_admin". **الإصلاح:** استبدال الاستدعاءين بـ`public.am_i_super_admin()` — الغلاف ذاتي النطاق الموجود أصلًا منذ 0015 والمُصرَّح لـ`authenticated` تحديدًا لهذا الغرض؛ نفس القاعدة العامة الموثَّقة في الملحق الأول (بند 4): دوال `SECURITY DEFINER` القابلة لأخذ `uuid` تعسفي تبقى `service_role`-only، ويُستدعى الغلاف الذاتي بدلًا منها من أي سياق `SECURITY INVOKER` أو سياسة RLS.

### 5. إصلاح دورة حياة الدعوات الملغاة (0036)
**قبل:** حتى بعد 0019/0029، لم يكن هناك مسار "إلغاء دعوة" سليم فعليًا. النقل الوحيد المتاح لحساب `pending_setup` غير المُزوَّد كان إلى `suspended` (عبر `users.disable` العادية، الموصوفة سابقًا خطأً في هذا التقرير — القسم 4 أعلاه — بأنها "إلغاء دعوة" مشروع). لكن حساب `suspended` بلا `provisioned_at` **لا مسار استعادة له إطلاقًا**: لا يمكن "إتمامه" عبر `finalize_new_user_profile()` (تُطابق `pending_setup` فقط)، ولا إعادة تفعيله عبر `users.disable` العادية (0029 يرفض أي `active` بلا `provisioned_at`) — حساب Auth حقيقي يبقى عالقًا للأبد بلا أي عملية شرعية تستطيع التعامل معه بعد ذلك. **الحل المُختار (من بين خيارين مطروحين صراحة):** بدل بناء "مسار استئناف آمن" لحساب مُلغى، اختير أن **يحذف الإلغاء حساب Auth غير المُزوَّد فعليًا** — أبسط، ولا يفتح أي مسار جديد يحتاج فحصًا إضافيًا حول `users.create`/`provisioned_at`.
- **على مستوى القاعدة (0036):** `enforce_pending_setup_transition()` (`CREATE OR REPLACE` من 0019) يرفض الآن **أي** انتقال `pending_setup → <غير active>` لأي فاعل غير موثوق — لا فقط الانتقال المباشر إلى `active` بلا `users.create` (القيد الأصلي من 0019). يُغلق هذا مسار "الإلغاء عبر `suspended`" القديم كليًا على مستوى القاعدة، وليس فقط في الواجهة.
- **على مستوى التطبيق:** Server Action جديد `cancelUserInviteAction(userId)` في `src/features/users/actions.ts` — يتحقق مجددًا على الخادم (`status === 'pending_setup' && provisioned_at === null`) قبل استدعاء `admin.auth.admin.deleteUser(userId)` عبر العميل الإداري (`service_role`)؛ صف `profiles` يُحذَف تلقائيًا معه (`ON DELETE CASCADE`، موجود منذ 0002). `UserStatusToggle` (`src/features/users/components/user-status-toggle.tsx`) يستدعي هذا الإجراء الجديد بدل `setUserStatusAction(userId, "suspended")`، مع نص تأكيد يوضح صراحة أن الحذف **نهائي**، وإعادة توجيه لقائمة المستخدمين بعد النجاح (الصف المعروض لم يعد موجودًا).
- **لا تجاوز لـ`users.create`/`provisioned_at`:** الحذف لا يمر عبر أي مسار كتابة على `profiles` إطلاقًا (فيتجاوز كل فحوصات 0029/0030 لأنه غير محتاج لها أصلًا)، ولا يفتح أي مسار "استئناف" يحتاج لاحقًا حراسة بـ`users.create` — الحساب إما موجود وسليم، أو محذوف بالكامل، لا حالة وسطى.

**اختُبر فعليًا:** (أ) حذف `auth.users` (سياق موثوق) لحساب `pending_setup` غير مكتمل يحذف صف `profiles` المطابق تلقائيًا معه — تحقَّق العدّ. (ب) السياق الموثوق نفسه لا يزال قادرًا على `pending_setup → suspended` مباشرة (استثناء `is_trusted_bootstrap_context()` يبقى، لأغراض تشغيلية/تصحيح بيانات مشروعة) — القيد الجديد يخصّ الفاعل غير الموثوق فقط. (ج) حتى Super Admin يفشل في استدعاء `finalize_new_user_profile()` على حساب أصبح `suspended` (سواء عبر مسار موثوق أو أي مسار آخر) — لا مسار "استئناف" أُعيد فتحه بالخطأ.

### 6. تصحيح هذا التقرير (القسم 6 من الطلب)
- **قائمة الترحيلات:** 0001–0036 بدل 0001–0031 (جدول القسم 3، وكل إشارة لنطاق الترحيلات في القسمين 11/13/14 والملاحق).
- **القسم 11 (خطوات ربط Supabase):** خطوة "نفّذ الترحيلات بالترتيب الرقمي" كانت تتوقف عند 0024 — صُحِّحت لتصل إلى 0036، مع إضافة مسار ترقية لمشروع قائم فعلًا على 0025–0031 (Foundation Hardening 1.3).
- **جدول "معايير الإنجاز" (نهاية القسم 16):** كان يذكر "18 مسارًا" و"24/24 ناجحة" — غير متسق مع القسم 14 (الذي كان يذكر "17 مسارًا"/"25/25" لنفس التشغيل). وُحِّد الرقمان مع النتيجة الفعلية لآخر تشغيل حقيقي في هذه الجلسة (17 مسارًا، 25/25 Vitest) في كل مكان في هذا الملف.
- **الملحق الثاني، بند 2 (نهاية الفقرة):** كانت تصف نقل `pending_setup → suspended` بأنه "إلغاء دعوة" مشروع بحق — هذا المسار أصبح مرفوضًا كليًا الآن (0036، بند 5 أعلاه)؛ صُحِّحت الجملة بإحالة صريحة لهذا الملحق.
- **الأقسام 4/5/13/14:** حُدِّثت لتعكس 0032–0036 وعدد أقسام الاختبار الجديد (29 بدل 24).

### 7. توسيع اختبارات SQL + تشغيل التحقق الكامل
أُضيفت خمسة أقسام جديدة (25–29) لملف الاختبار، تغطي البنود الخمسة أعلاه — بما فيها إعادة كتابة القسمين 9و/21 القائمين مسبقًا (من 1.3) ليعكسا أن `pending_setup → suspended` أصبح مرفوضًا لكل فاعل غير موثوق الآن (0036)، لا فقط لبعض الفاعلين كما كان مفترضًا سابقًا. **نتائج فعلية (وليست افتراضًا):**
- أُعيد بناء قاعدة اختبار Postgres محلية **من الصفر بالكامل** (حذف القاعدة والأدوار الثلاثة، إعادة إنشائها، `local_harness_setup.sql`، كل الترحيلات 0001–0036 بالترتيب، ثم `seed.sql`) عدة مرات أثناء التصحيح المتكرر لخلل القسم 3 أعلاه (Precedence)، وأخيرًا قبل تشغيل التحقق النهائي.
- `npm run typecheck` (`npx tsc --noEmit`) → صفر أخطاء.
- `npm run lint` → صفر أخطاء وتحذيرات.
- `npm run test` (Vitest) → `25/25` ناجح (بلا تغيير — لا منطق واجهة جديد يستدعي اختبار Vitest إضافي في هذه الجولة؛ التغطية الجديدة كلها SQL).
- `npm run build` (Next.js/Turbopack) → نجح، 17 مسارًا.
- اختبار SQL التكاملي → **نجح بالكامل**، `=== ALL RLS/PERMISSION/AUDIT/ESCALATION TESTS PASSED (including Foundation Hardening 1.4) ===`، **112 تأكيد "OK" عبر 29 قسمًا** (96 عبر 24 قسمًا سابقًا).

**خلاصة الملحق الرابع:** بندان (1، 5) كانا معالجة بيانات/دورة حياة لم تكن مكتملة أو كانت تترك حالة عالقة بلا مسار شرعي، بندان (2، 4) كانا إحكامًا لهوية جدول حسّاس واستكمال UI/DB flow لصلاحية موجودة بلا واجهة تستهلكها بشكل صحيح، وبند واحد (3) كان استكمال حساب أثر تفويض لم يكن مغطى سابقًا. **الأهم:** هذه المراجعة كشفت أن حتى منطق مكتوب ومُراجَع بعناية يمكن أن يحمل خطأ SQL دقيق (أولوية `UNION`/`EXCEPT`) لا يظهر إلا عند اختبار الاتجاهين المتقابلين لنفس الفحص فعليًا على قاعدة بيانات حقيقية — وهذا بالتحديد سبب طلب اختبارات SQL شاملة بدل الاكتفاء بمراجعة كود نظرية في كل مرحلة من هذا المشروع. الأساس المعماري جاهز الآن للبدء بوحدة المبيعات وفق التوجيه الأصلي، بعد أربع مراجعات أمنية مستقلة متتالية ولا ثغرة معروفة متبقية على مستوى قاعدة البيانات.

---

## الملحق الخامس — "Patch 1.4.1": تصحيح أخير ومحدود جدًا فوق Foundation Hardening 1.4 (ترحيلات 0037–0038)

بعد الملحق الرابع، طُلب تصحيح أخير **محدود بثلاثة بنود فقط** — وليس مراجعة أمنية مستقلة خامسة كاملة، ولا بداية Master Data/Sales. الشرط كان صريحًا: لا تعديل على أي ترحيل قديم (0001–0036)، وأي تعديل على القاعدة يكون عبر ترحيل جديد بعد آخر ترحيل موجود (0037 فصاعدًا)، ولا توسيع للنطاق خارج البنود الثلاثة إلا عند اكتشاف خلل حقيقي يمنع تنفيذها — وهو ما حدث فعلًا، ومُوثَّق أدناه كملاحظة تقنية.

### 1. فصل `users.manage_store_access` نهائيًا عن `users.manage_permissions` (0037)
**قبل:** 0018 (Foundation Hardening 1.2) منحت `users.manage_store_access` مسارات كتابة خاصة بها على `user_store_access` وعمودَي `profiles.store_access_scope`/`default_store_id` — لكنها لم تحذف سياستَي `INSERT`/`DELETE` **الأصليتين** من 0010 (`user_store_access_insert`/`user_store_access_delete`)، اللتين كانتا تمنحان الكتابة على هذا الجدول لأي حامل `users.manage_permissions` أيضًا. بما أن Postgres يُجمِّع (OR) كل السياسات المسموحة (Permissive) المتعددة لنفس الأمر على نفس الجدول، بقي المساران — `users.manage_permissions` و`users.manage_store_access` — كافيَين بشكل مستقل لسنوات: تداخل غير مقصود في صلاحيات RLS، وليس مسارًا إضافيًا مقصودًا (تعليق `enforce_store_access_delegation()` نفسه من 0018 كان يصف هذا التداخل صراحةً وقتها بوصفه سلوكًا متوقَّعًا، لا خللًا). أما `profiles.store_access_scope`/`default_store_id` فكانتا **مفصولتَين بالفعل** بشكل صحيح — سياسة `profiles_update` (0010) الأصلية تغطي `users.edit`/`users.disable` فقط، وسياسة `profiles_update_store_access` (0018) تغطي `users.manage_store_access` فقط، ولا فرع لـ`users.manage_permissions` في أيٍّ منهما ولا في Trigger تفويض الأعمدة (0030) — فتأكَّد هذا الجزء باختبار جديد بدل تعديل أي شيء فيه.

**الإصلاح (نفس نمط الحماية متعددة الطبقات المُتَّبع طوال هذا المشروع — RLS لا تُصدَّق وحدها؛ Trigger يفرض نفس القاعدة استقلالًا عن أي سياسة RLS):**
1. حذف سياستَي `user_store_access_insert`/`user_store_access_delete` (0010) — سياستا `_scoped` من 0018 (المقصورتان على `users.manage_store_access`) تبقيان قائمتين وتغطيان المسار الشرعي وحده.
2. `enforce_store_access_delegation()` (`CREATE OR REPLACE` من 0037، **مبنيّة فوق نسخة 0025 لا نسخة 0018 الأصلية** — تفصيل مهم في الملاحظة التقنية أدناه) تفحص الآن `users.manage_store_access` صراحةً كأول شرط، مستقلةً عن أي سياسة RLS — فحتى لو أُعيد فتح مسار RLS آخر بالخطأ مستقبلًا، هذا الـTrigger وحده كافٍ لمنع الكتابة.

`users.manage_permissions` نفسها **لم تتغيّر إطلاقًا** — لا تزال تحكم الأدوار/`role_permissions`/`user_roles`/`user_permission_overrides` كما كانت، فقط امتدادها غير المقصود إلى `user_store_access` أُزيل.

> **ملاحظة تقنية جوهرية (خلل حقيقي اكتُشف أثناء تشغيل الاختبار الفعلي، أُصلح ضمن نطاق البند نفسه — يندرج تحت الاستثناء الصريح "أصلحه ووثّقه" في طلب Patch 1.4.1، وليس توسيعًا للنطاق):** النسخة الأولى من `enforce_store_access_delegation()` في 0037 كُتبت بالبناء على نسخة **0018** الأصلية من الدالة (فحص حدّ التفويض على فرع `INSERT` فقط) بدل النسخة **0025** الحالية فعليًا في القاعدة (التي مدَّت نفس الفحص ليشمل فرع `DELETE` أيضًا — Foundation Hardening 1.3، الملحق الثالث). النتيجة: تشغيل قسم 18.3 القديم من اختبار SQL (الذي يثبت تحديدًا أن فاعلًا محدود النطاق A+B لا يستطيع حذف وصول متجر C من مستخدم آخر) فشل فورًا — الفحص الذي أضافته 0025 اختفى بصمت لأن `CREATE OR REPLACE` استبدل الدالة كاملة بنسخة أقدم منها فعليًا، لا نسخة أحدث. **الإصلاح:** أُعيد بناء 0037 بالكامل فوق نسخة 0025 حرفيًا (حفظ فرعَي `INSERT`/`DELETE` معًا لفحص حدّ التفويض)، مع إضافة فحص `users.manage_store_access` الجديد فقط كخطوة إضافية أولى — لم يُفقَد أي شرط كان موجودًا سابقًا. **هذا خلل ما كان ليظهر لولا التشغيل الفعلي لمجموعة الاختبار الكاملة القديمة بعد كل تعديل جديد** — وهو بالتحديد سبب اشتراط "لا تحذف أي اختبار أمني موجود" في طلب هذه الـPatch: التعديل الجديد كان سيُمرَّر بصمت لولا أن قسمًا من 2021/1.3 لا علاقة ظاهرية له بـPatch 1.4.1 اكتشف الانحدار (Regression) فورًا.

**اختُبر فعليًا (قسم 30 من اختبار SQL، فاعلان جديدان + إعادة استخدام الفاعل 013 من الأقسام 18/19):** فاعل جديد (032) يحمل `users.manage_permissions` + `users.edit` + `users.view` — **بلا** `users.manage_store_access` إطلاقًا — فشل في: (أ) تغيير `store_access_scope`/`default_store_id` لهدف آخر (يُلتقَط عبر استثناء صريح من Trigger تفويض الأعمدة، بعد منح 032 أيضًا `users.edit` عمدًا لضمان أن RLS نفسها تُمرِّر الصف لِـTrigger التفويض بدل حجبه بصمت عند صفر صف متأثر — تفصيل ضروري لجعل الاختبار يفحص الطبقة الصحيحة)، (ب) منح وصول متجر جديد (`INSERT`، يُلتقَط عبر انتهاك `WITH CHECK`)، (ج) سحب وصول متجر قائم (`DELETE`، يُلتقَط عبر عدّ الصفوف المتأثرة = صفر — سياسة RLS نفسها لا تُطابق أي صف له أصلًا بعد حذف 0010، فلا تصل العملية حتى لِـTrigger)، (د) استخدام `replace_user_store_access()` (تفشل العملية الذرّية كلها). **ضابط إيجابي:** الفاعل 013 (يحمل `users.manage_store_access` فقط — **بلا** `users.manage_permissions` إطلاقًا) نجح في **نفس** العمليات بالضبط على نفس الهدف.

### 2. إصلاح تحميل Store Access الحالي في الواجهة (بدون أي ترحيل جديد — تصحيح طبقة تطبيق بحت)
**قبل:** `getUserDetail()` كانت تجلب صفوف `user_store_access` بصيغة مُضمَّنة (Embedded Join) — `store_id, store:stores(id, name_ar, status)`. مورد PostgREST المُضمَّن (`store:stores(...)`) يخضع لسياسة RLS **الخاصة بالجدول المُضمَّن نفسه (`stores`)** بشكل مستقل تمامًا عن سياسة RLS على الجدول الأساسي (`user_store_access`) — فاعل يملك `users.manage_store_access` (ورؤية الصف الخام عبر `users.view`) لكن **بلا** `stores.view` كان يحصل على `store: null` لكل صف (تحجبه سياسة `stores_select` التي تشترط `stores.view` بلا استثناء)، ثم `.filter(Boolean)` في الكود يُسقِط هذه الصفوف بالكامل بصمت — فتظهر قائمة "وصول المتاجر" **فارغة تمامًا** للفاعل في الواجهة، رغم أن القاعدة تدعم كتابته الكاملة منذ 0018/0035. هذا لا علاقة له مطلقًا بأي ثغرة أمنية (لا تسريب بيانات) — عطل وظيفي بحت في طبقة القراءة.

**الإصلاح:** `getUserDetail()` أصبحت تجلب `store_id` الخام فقط (بلا Embed) — `users.view` وحدها (المطلوبة أصلًا لفتح صفحة `/users/[id]` بالكامل) كافية لرؤية هذه الصفوف عبر سياسة `user_store_access_select` الأصلية (0010)، بلا حاجة لـ`stores.view` إطلاقًا. الأسماء تأتي من `manageable_stores_for_actor()` (0035، **لم تتغيّر**) بدل الـEmbed. دالة نقية جديدة `selectableStoreAccessIds(currentStoreIds, manageableStoreIds)` (`src/features/users/store-access-helpers.ts`) تحسب المقاطعة بين وصول الهدف **الفعلي الكامل** (غير المُصفَّى، كما هو مخزَّن فعليًا) ونطاق تشغيل الفاعل — فمتجر خارج نطاق الفاعل (مثل C) **لا يظهر إطلاقًا** كخيار قابل للتحديد أو الإلغاء (لا يُكشَف اسمه، ولا يظهر كصندوق فارغ)، لكنه يبقى محفوظًا في قاعدة البيانات دون تغيير — فإن عدَّل الفاعل A/B فقط وأرسل اختياره، تبقى C كما هي تمامًا بفضل منطق 0035 الذري القائم أصلًا (استثناء الحذف لما هو خارج النطاق)، ولا تفشل العملية بسببها. `page.tsx` (`canManageStoreAccess`) أصبحت الحارس الوحيد لكل من Store Scope وStore Access معًا، متوافقًا مع فصل البند 1.

**اختُبر فعليًا (قسم 31 من اختبار SQL، الفاعل 013 يُعاد استخدامه — يملك `users.view` بلا `stores.view` — ضد هدف جديد 034 بمنح A+C):** (أ) الاستعلام الخام (`store_id` فقط) أرجع كلا الصفّين (A وC) بلا أي مشكلة. (ب) استعلام مباشر على `stores` نفسها لنفس المعرّفَين — محاكاة دقيقة لما كان الـEmbed القديم يُنفِّذه فعليًا تحت الغطاء — أرجع **صفرًا** من الصفوف لنفس الفاعل، مُثبتًا السبب الجذري تحديدًا. (ج) `manageable_stores_for_actor()` أرجعت {A, B} فقط (بلا تغيير، كما هو متوقَّع). (د) مقاطعة {A, C} مع {A, B} = {A} فقط تمامًا كمنطق `selectableStoreAccessIds()` نفسه، مُطبَّقة هنا مباشرة على بيانات حقيقية. (هـ) `replace_user_store_access(034, [B])` نجحت وتركت الحالة النهائية {B, C} بدقة — نفس نمط الاختبار في قسم 28 (Foundation Hardening 1.4) لكن بفاعل يملك `users.view` هذه المرة، ليغطي بالضبط السيناريو الذي كان الكود القديم يفشل فيه.

### 3. جعل Cancel Invitation يظهر في Audit Log باسم الموظف الذي نفَّذه (0038)
**قبل:** `cancelUserInviteAction` كانت تحذف مستخدم Auth غير المُزوَّد مباشرة عبر `admin.auth.admin.deleteUser()` (العميل الإداري، `service_role`). Trigger التدقيق التلقائي (`audit_table_changes()`، 0016) يُسجِّل هذا الحذف كـ`user.delete` تلقائيًا — لكن `user_id` في هذا الصف يُقرَأ من `auth.uid()`، والحذف عبر واجهة الإدارة (Admin API) يُنفَّذ داخليًا بدور خدمة Supabase الداخلي (`auth` service role)، **وليس بجلسة JWT الفاعل الحقيقي** — فيُسجَّل `user_id = NULL` دائمًا لهذا الحدث، بصرف النظر عمَّن ضغط الزر فعليًا. لا يوجد أي مسار كان يوثِّق **من** ألغى الدعوة تحديدًا.

**الإصلاح:** دالة جديدة `log_user_invite_cancel(p_target_user_id, p_reason)` (`SECURITY DEFINER`، `0038`) تُنشئ صف Audit مستقل بالحدث `user.invite_cancel`: `user_id = auth.uid()` (يُلتقَط تلقائيًا من جلسة المستدعي **نفسه** — لا يوجد أي وسيط `actor_id` في توقيع الدالة إطلاقًا، فلا مجال لتمرير/تلفيق هوية فاعل آخر)، `entity_id = p_target_user_id`، **بلا** تخزين البريد الإلكتروني أو أي بيانات شخصية إضافية (`old_values`/`new_values` تبقيان `NULL` دائمًا — الدالة لا تلمسهما). تشترط الدالة صراحةً `users.disable` (نفس الصلاحية التي تحرس `cancelUserInviteAction` أصلًا)، وتُعيد التحقق **من جديد على مستوى القاعدة** أن الهدف لا يزال فعليًا دعوة `pending_setup` غير مكتملة (`status = 'pending_setup' AND provisioned_at IS NULL`) — لا تثق بفحص الخادم وحده. على مستوى التطبيق: `cancelUserInviteAction` تستدعي هذه الدالة عبر **عميل الجلسة العادي** (وليس الإداري) **قبل** استدعاء `admin.auth.admin.deleteUser()` — ترتيب حاسم: بعد الحذف، لا وجود لأي جلسة فاعل يمكن الاستدلال عليها لالتقاط هويته الحقيقية.

**`user.invite_cancel` مقابل `user.delete` — حدثان متعمَّدان، لا تكرار:** `user.invite_cancel` يوثِّق **قرار** الفاعل البشري (من ألغى، متى، ولماذا إن وُجد سبب) دون أي بيانات شخصية للهدف؛ `user.delete` (التلقائي، بلا Actor) يوثِّق تنفيذ الحذف الفعلي على مستوى القاعدة بصرف النظر عن مصدره. الإبقاء عليهما معًا **مقصود**: حذف `user.delete` كان سيفقد التوثيق الآلي الشامل لكل حذف يحدث لأي سبب (بما فيه تدخل يدوي مباشر لن يمرّ أبدًا عبر `cancelUserInviteAction`)؛ الاكتفاء بـ`user.delete` وحدها كان سيبقي فجوة الهوية المفقودة كما هي تمامًا. تسميتان عربيتان واضحتان أُضيفتا لـ`src/lib/audit/action-labels.ts` توضّحان الفرق للمستخدم النهائي مباشرة في صفحة سجل التدقيق.

**اختُبر فعليًا (قسم 32 من اختبار SQL، فاعلان يُعاد استخدامهما — 002 عادي بلا `users.disable`، 005 يحمل `users.disable`+`users.view` — وهدف جديد 036):** (أ) مستخدم عادي (002، بلا `users.disable`) فشل في استدعاء `log_user_invite_cancel()` مباشرة عبر RPC — لا يستطيع تلفيق الحدث يدويًا. (ب) فاعل يحمل `users.manage_permissions` (032، من قسم 30) بلا `users.disable` فشل أيضًا — الحارس تحديدًا `users.disable`، لا أي صلاحية إدارية عامة. (ج) 005 فشل في تسجيل إلغاء دعوة لحساب **نشط فعليًا** (002) — إعادة التحقق من حالة الهدف على مستوى القاعدة تعمل بشكل مستقل عن فحص الخادم. (د) 005 نجح في إلغاء دعوة 036 فعليًا؛ صف Audit الناتج: `user_id = 005` (الفاعل الحقيقي)، `entity_id = 036`، `action = 'user.invite_cancel'`، `reason` كما أُرسل، و`old_values`/`new_values` كلاهما `NULL` (لا بريد إلكتروني، لا بيانات زائدة). (هـ) بعد الحذف الفعلي لحساب 036 (محاكاة `admin.auth.admin.deleteUser()`)، ظهر **بالضبط** صفّان منفصلان لنفس الهدف: `user.invite_cancel` (Actor=005) و`user.delete` (Actor=`NULL`) — لا تكرار، ولا فقدان لهوية من نفَّذ الإلغاء فعليًا.

### 4. تصحيح هذا التقرير
- **قائمة الترحيلات:** 0001–0038 بدل 0001–0036 (جدول القسم 3، وكل إشارة لنطاق الترحيلات في القسمين 11/13/14 والملاحق).
- **القسم 11 (خطوات ربط Supabase):** أُضيف مسار ترقية لمشروع قائم فعلًا على 0001–0036 (Foundation Hardening 1.4) — نفّذ 0037–0038 فقط.
- **الأقسام 4/8/13/14 وجدول "معايير الإنجاز":** حُدِّثت لتعكس 0037–0038، ملفات التطبيق المتغيّرة (`store-access-helpers.ts` الجديد، `queries.ts`/`page.tsx`/`actions.ts`/`action-labels.ts`/`database.ts` المُحدَّثة)، عدد اختبارات Vitest الجديد (31/31 بدل 25/25)، وعدد أقسام/تأكيدات اختبار SQL الجديد (32 قسمًا/128 تأكيد "OK" بدل 29/112).

### 5. تشغيل التحقق الكامل — نتائج فعلية (وليست افتراضًا)
- أُعيد بناء قاعدة اختبار Postgres محلية **من الصفر بالكامل** (حذف القاعدة والأدوار الثلاثة، إعادة إنشائها، `local_harness_setup.sql`، كل الترحيلات 0001–0038 بالترتيب، ثم `seed.sql`) عدة مرات أثناء التصحيح المتكرر لخلل البند 1 أعلاه (نسخة 0018 مقابل 0025)، وأخيرًا قبل تشغيل التحقق النهائي.
- `npm install` نُفِّذ أولًا (كانت `node_modules` غير مثبَّتة في بداية هذه الجلسة تحديدًا) — 552 حزمة، صفر ثغرات.
- `npm run typecheck` (`npx tsc --noEmit`) → صفر أخطاء.
- `npm run lint` → صفر أخطاء وتحذيرات.
- `npm run test` (Vitest) → `31/31` ناجح (25 سابقًا + 6 جديدة لـ`selectableStoreAccessIds`).
- `npm run build` (Next.js/Turbopack) → نجح، 17 مسارًا (بلا تغيير).
- اختبار SQL التكاملي → **نجح بالكامل**، `=== ALL RLS/PERMISSION/AUDIT/ESCALATION TESTS PASSED (including Foundation Hardening 1.4 and Patch 1.4.1) ===`، **128 تأكيد "OK" عبر 32 قسمًا** (112 عبر 29 قسمًا سابقًا) — **لم يُحذَف أي اختبار أمني قائم**، الأقسام 1–29 كلها مطابقة لِمَا كانت عليه (باستثناء إصلاح الانحدار في البند 1 أعلاه، الذي أعاد قسم 18.3 القديم إلى النجاح الصحيح بعد أن كان سيفشل بسبب خلل في 0037، لا تغييرًا في القسم 18.3 نفسه).

### 6. الملفات/الترحيلات التي تغيَّرت في Patch 1.4.1 (قائمة كاملة)
**ترحيلات جديدة:** `supabase/migrations/0037_store_access_permission_separation.sql`، `supabase/migrations/0038_invite_cancel_audit_event.sql`.
**ملفات تطبيق مُعدَّلة:** `src/features/users/actions.ts`، `src/features/users/queries.ts`، `src/app/(app)/users/[id]/page.tsx`، `src/lib/audit/action-labels.ts`، `src/types/database.ts`.
**ملفات جديدة:** `src/features/users/store-access-helpers.ts`، `tests/store-access-helpers.test.ts`.
**اختبار SQL:** `supabase/tests/rls_and_permissions.test.sql` — أُضيفت الأقسام 30/31/32، وحُدِّث تعليق رأس الملف ورسالة النجاح النهائية.
**لم يتغيّر:** أي ترحيل من 0001–0036، وأي ملف تطبيق آخر غير المذكورة أعلاه.

**خلاصة الملحق الخامس:** ثلاثة بنود مطلوبة بالضبط، أُغلقت الثلاثة على مستوى القاعدة (لا الواجهة فقط)، ولم يُبدَأ أي عمل على Master Data/Sales. **الأهم:** حتى تصحيح محدود جدًا بثلاثة بنود واضحة يمكن أن يحمل انحدارًا (Regression) دقيقًا إن أُعيدت كتابة دالة `CREATE OR REPLACE` بالبناء فوق نسخة قديمة من الدالة بدل أحدث نسخة فعلية في القاعدة — ولم يظهر هذا الانحدار إلا لأن **كل** قسم من اختبار SQL القديم (29 قسمًا من أربع مراجعات سابقة) أُعيد تشغيله فعليًا بعد كل تعديل جديد، لا الأقسام الثلاثة الجديدة فقط. هذا التأكيد التجريبي — وليس القراءة النظرية للكود — هو ما يجعل هذا التسليم قابلاً للثقة. الأساس المعماري (Foundation) **مُغلَق نهائيًا** عند هذا الإصدار (0001–0038)؛ الخطوة التالية هي Master Data/Sales مباشرة، بلا أي عمل تأسيسي إضافي مخطَّط.

---

## الملحق السادس — "Foundation Audit Hotfix 1.4.2": إصلاح أخير ضيّق فوق Patch 1.4.1 (ترحيلة 0039)

بعد تسليم الملحق الخامس (Patch 1.4.1)، راجع المستخدم كود `0038_invite_cancel_audit_event.sql` نفسه (لا التقرير فقط) واكتشف ثغرة واحدة حقيقية متبقية في بند واحد فقط من بنود تلك الـPatch (البند 3، `log_user_invite_cancel()`). الطلب كان صريحًا وضيقًا جدًا: **لا** فتح جولة مراجعة أمنية سادسة كاملة، **لا** بدء Master Data/Sales، **لا** مراجعة أو تعديل أي جزء آخر من Foundation إلا ما يلزم لهذا الإصلاح تحديدًا. كل تعديل جديد عبر ترحيل واحد فقط بعد آخر ترحيل موجود (0039)، بلا تعديل على أي ترحيل من 0001–0038.

### الثغرة المُكتشَفة
**قبل:** دالة `log_user_invite_cancel(p_target_user_id, p_reason)` (0038) كانت `GRANT`ed لـ`authenticated` بالكامل — أي مستخدم موثَّق يحمل `users.disable` يستطيع استدعاءها **مباشرة** (من طرفية المتصفح، أو أي عميل REST، بلا مرور عبر `cancelUserInviteAction` أو الواجهة إطلاقًا) ضد دعوة `pending_setup` حقيقية قائمة، فيُكتب صف `user.invite_cancel` في `audit_logs` منسوبًا له **دون أن يُحذف حساب Auth المستهدَف فعليًا** — الدعوة تبقى قائمة تمامًا كما هي، لكن سجل التدقيق يزعم أنها أُلغيت. الفحوصات الداخلية للدالة (`users.disable`، حالة الهدف `pending_setup`/`provisioned_at IS NULL`) كانت صحيحة **كمنطق أعمال**، لكنها لا تمنع هذا الاستدعاء المباشر أصلًا — أي ثغرة مستقبلية في تلك الفحوصات، أو أي استخدام غير متوقَّع للصلاحية نفسها، كانت ستُفتح مباشرة عبر واجهة RPC عامة الوصول. **مشكلة ثانية مرتبطة:** `cancelUserInviteAction` (طبقة التطبيق) كانت تستدعي `log_user_invite_cancel()` **قبل** `admin.auth.admin.deleteUser()` — فلو نجح تسجيل التدقيق ثم فشل الحذف الفعلي لأي سبب (خطأ شبكة، خطأ من Supabase Auth، إلخ)، يصبح السجل كاذبًا: يقول إن الدعوة أُلغيت بينما الحساب لا يزال موجودًا فعليًا. لا وجود أيضًا لأي حماية من استدعاء مزدوج/متزامن يكتب الحدث مرتين لنفس الهدف.

الفرق الجوهري عن كل الثغرات السابقة في هذا المشروع: هذه ليست ثغرة RLS (لا يوجد جدول يُقرأ/يُكتب مباشرة هنا)، بل ثغرة **EXECUTE privilege** على دالة `SECURITY DEFINER` — الفحوصات الداخلية للدالة قد تكون سليمة تمامًا، لكن طالما `authenticated` يملك `EXECUTE`، تبقى الدالة نفسها قابلة للاستدعاء المباشر من أي عميل، بمعزل عمّا تفعله طبقة التطبيق فوقها.

### الإصلاح — ثلاثة أجزاء (0039)

**1) إغلاق المسار القديم القابل للاستدعاء المباشر بالكامل:**
```sql
revoke execute on function public.log_user_invite_cancel(uuid, text) from authenticated;
```
الدالة **أُبقيت موجودة** (لم تُحذف) وعُلِّق عليها بأنها SUPERSEDED — نفس سابقة `log_auth_event(text)` في 0023 (التي أُبقيت بلا `EXECUTE` بدل حذفها). النتيجة: لا يوجد أي دور موقَّع دخول — بصرف النظر عمّا يملكه من صلاحيات تطبيقية — يستطيع استدعاء هذه الدالة بعد الآن. هذا ضمان أقوى من أي فحص داخلي: الرفض يحدث **قبل** أن يبدأ تنفيذ جسم الدالة إطلاقًا (`SQLSTATE 42501`، `insufficient_privilege` — رسالة Postgres القياسية "permission denied for function"، متمايزة تمامًا عن استثناءات منطق الأعمال `P0001` المُستخدَمة في كل مكان آخر بهذا المشروع).

**2) مسار تسجيل جديد، `service_role`-only فقط:**
```sql
create or replace function public.log_user_invite_cancel_trusted(
  p_actor_user_id uuid, p_target_user_id uuid, p_reason text default null
) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$ ... $$;

revoke execute on function public.log_user_invite_cancel_trusted(uuid, uuid, text) from public;
grant execute on function public.log_user_invite_cancel_trusted(uuid, uuid, text) to service_role;
```
نفس نمط `log_auth_event_trusted()` (0023) حرفيًا: الفاعل يُمرَّر كوسيط صريح (`p_actor_user_id`) بدل الاعتماد على `auth.uid()`، لأن اتصال `service_role` لا يحمل مطالبة JWT `sub` خاصة به. **لكن هذه الدالة لا تكتفي بغلق EXECUTE — تفرض داخليًا اثنين من الشروط البنيوية (Invariants) المستقلة عن أي انضباط في ترتيب الاستدعاء من طبقة التطبيق:**

- **الشرط (أ) — دليل حذف فعلي حقيقي:** يجب أن يكون هناك صف `user.delete` موجود مسبقًا في `audit_logs` لنفس `entity_id` (الهدف) قبل قبول تسجيل `user.invite_cancel`. صف `user.delete` هذا يُكتَب تلقائيًا بواسطة `audit_table_changes()` (0016) ضمن **نفس المعاملة** التي تحذف بها `auth.users`/`profiles` فعليًا — فهو دليل حقيقي على حذف مكتمل، وليس مجرد "غياب صف `profiles`" (وهو فحص أضعف كنت اقترحته أولًا في المسودة الأولى ثم استبدلته بنفسي: فحص "الصف غائب" وحده كان سيمر أيضًا لأي `p_target_user_id` لم يكن له أصلًا صف `profiles` — أي أن لا شيء حُذف فعليًا). فحص غياب صف `profiles` أُبقي كإشارة إضافية ثانوية، لا كضمان وحيد. **هذا الشرط يحمي حتى من خطأ مستقبلي في كود Server Action نفسه** يستدعي الدالة الموثوقة قبل أوانه أو بمعرّف خاطئ — لا فقط من عميل خارجي (الذي أصلًا لا يستطيع الوصول للدالة إطلاقًا بعد الجزء 1).
- **الشرط (ب) — إعادة تحقق مستقلة من الصلاحية:** الفاعل المُمرَّر يجب أن يملك `users.disable` **حاليًا**، مُتحقَّق منه مجددًا داخل الدالة نفسها عبر `get_user_permissions()` (المصدر الوحيد للحقيقة، 0008/0015) — يغلق فجوة التوقيت الصغيرة المحتملة بين تحقق `requirePermission()` في الـServer Action ولحظة استدعاء هذه الدالة.

**3) Idempotency — فهرس فريد جزئي:**
```sql
create unique index audit_logs_invite_cancel_once_idx
  on public.audit_logs (entity_id)
  where entity_type = 'user' and action = 'user.invite_cancel';
```
مع `INSERT ... ON CONFLICT (entity_id) WHERE (...) DO NOTHING RETURNING id` وSELECT احتياطي عند التعارض. النتيجة: **مستحيل بنيويًا** وجود أكثر من صف `user.invite_cancel` واحد لنفس الهدف، بصرف النظر عن عدد مرات إعادة المحاولة (Retry) أو التزامن (Concurrent calls) — واستدعاء مكرر/متزامن يُعيد **نفس** معرّف الصف الأصلي بدل الفشل بخطأ تكرار مفتاح أو إنشاء صف ثانٍ.

`audit_logs` نفسه **لا يزال بلا أي سياسة `UPDATE`/`DELETE`** لأي دور (0006/0010، غير مُعدَّلة) — أُعيد التأكد من هذا صراحة باختبار جديد (33.9) بدل افتراضه.

### تعديل طبقة التطبيق — `cancelUserInviteAction` (`src/features/users/actions.ts`)
إعادة ترتيب كاملة، بلا أي منطق أعمال جديد غير مطلوب:
1. `actorUserId` يُلتقَط **أولًا**، من جلسة الفاعل الموثَّقة فعليًا (`requirePermission("users.disable")` — تستدعي `getCurrentSession()` التي تحلّ المستخدم عبر `supabase.auth.getUser()`، أي JWT مُتحقَّق من الخادم، لا قيمة قادمة من العميل) — **قبل** لمس العميل الإداري (`admin`) إطلاقًا.
2. فحوصات الحالة على الخادم (كما كانت): جلب `profiles.status`/`provisioned_at` عبر العميل الإداري، رفض أي حالة غير `pending_setup`/`provisioned_at IS NULL`.
3. `admin.auth.admin.deleteUser(userId)` يُنفَّذ **أولًا**. إن فشل، تُعاد رسالة خطأ عامة فورًا — **لا يُستدعى مسار التسجيل إطلاقًا.**
4. **فقط بعد** نجاح الحذف فعليًا، يُستدعى `admin.rpc("log_user_invite_cancel_trusted", { p_actor_user_id: actorUserId, p_target_user_id: userId, p_reason: null })` عبر العميل الإداري — بالفاعل الملتقَط في الخطوة 1 والهدف الصحيح.

النتيجة: **لا يوجد أي مسار** — لا عبر عميل خارجي (يُغلَق EXECUTE-اً)، ولا عبر خطأ محتمل في كودنا الخاص (يُغلَق بالشرط أ)، ولا عبر تسجيل ناجح متبوعًا بحذف فاشل (يُغلَق بترتيب التنفيذ نفسه) — يمكنه إنتاج `user.invite_cancel` بدون حذف فعلي حقيقي سابق له.

### `user.invite_cancel` مقابل `user.delete` — لا تغيير في التصميم
كما في الملحق الخامس: يبقيان حدثين متعمَّدين ومنفصلين. `user.delete` (تلقائي، بلا Actor) يوثّق تنفيذ الحذف نفسه بصرف النظر عن مصدره؛ `user.invite_cancel` (الآن حصرًا عبر المسار الموثوق) يوثّق قرار الفاعل البشري، **مربوطًا بنيويًا** الآن بدليل حذف حقيقي سابق له لأول مرة.

### الاختبارات — تحقيق كل السيناريوهات الستة المطلوبة تحديدًا
`supabase/tests/rls_and_permissions.test.sql`: قسما 32.4/32.5 (Patch 1.4.1) عُدِّلا، وقسم 33 جديد كامل أُضيف.

- **32.4 (مُعدَّل، لم يُحذف):** كان يثبت **نجاح** الاستدعاء المباشر القديم لفاعل صحيح (005، يحمل `users.disable`) — سلوك أصبح الآن مرفوضًا عمدًا بهذا الـHotfix. عُدِّل ليثبت **الفشل** بدلًا من النجاح، مع تعليق يوضح صراحةً أنه سلوك SUPERSEDED مقصود، لا حذفًا لاختبار أمني (المبدأ المتَّبع طوال هذا المشروع: لا تُحذف اختبارات أمنية، تُقلَب توقعاتها إن تغيّر السلوك المقصود فعليًا).
- **32.5 (مُعدَّل):** أعاد بناء تدفّق الاختبار بالكامل عبر المسار الجديد الصحيح: حذف حساب Auth الهدف (036) فعليًا عبر `service_role` (محاكاة `admin.auth.admin.deleteUser()`)، ثم استدعاء `log_user_invite_cancel_trusted(actor=005, target=036, reason=...)` — يعيد التحقق من أن `user_id`/`entity_id`/`reason` مطابقون تمامًا وأن الحدثان (`user.invite_cancel`/`user.delete`) يتعايشان دون تكرار، محافظًا على نية القسم الأصلي.
- **33.1:** فاعل `authenticated` يحمل `users.disable` (005) يستدعي `log_user_invite_cancel_trusted` مباشرة عبر جلسته العادية (لا `service_role`) → فشل بـ`insufficient_privilege` تحديدًا (`SQLSTATE 42501`)، **وليس** برسالة منطق أعمال — يثبت أن الرفض على مستوى EXECUTE، لا داخل جسم الدالة.
- **33.2:** فاعل بلا `users.disable` (002) يحاول الشيء نفسه → يفشل أيضًا (نفس السبب: EXECUTE مرفوض قبل حتى فحص الصلاحية داخليًا).
- **33.3:** استدعاء `log_user_invite_cancel_trusted` مرتين متتاليتين (محاكاة إعادة محاولة/تزامن) عبر `service_role` لنفس الهدف (037، بعد حذف فعلي وتسجيل `user.delete` له) → الاستدعاء الثاني يُعيد **نفس** `id` الأول تمامًا، ويُثبَت أن عدد صفوف `user.invite_cancel` لهذا الهدف لا يزال **واحدًا فقط** في `audit_logs` (`COUNT(*) = 1`).
- **33.4:** استدعاء `log_user_invite_cancel_trusted` عبر `service_role` لهدف (038) **بلا** أي صف `user.delete` سابق له إطلاقًا → فشل صريح (الشرط أ)، ويُثبَت أن **لا يوجد** أي صف `user.invite_cancel` لهذا الهدف بعد المحاولة الفاشلة.
- **33.5:** بعد حذف فعلي وتسجيل `user.delete` صحيح لهدف جديد (035)، استدعاء `log_user_invite_cancel_trusted(actor=005, target=035, reason='...')` عبر `service_role` → ينجح، والصف الناتج يحمل `user_id = 005` (الفاعل الحقيقي المُمرَّر)، `entity_id = 035` (الهدف الصحيح)، و`reason` كما أُرسل بالضبط.
- **33.6:** يُعاد التحقق من أن `user.delete` (Actor=`NULL`، تلقائي) و`user.invite_cancel` (Actor=005) يظهران كصفّين منفصلين تمامًا لنفس الهدف (035) بلا تعارض أو دمج، وأن كليهما يحملان `entity_id` واحدًا صحيحًا.
- **33.7/33.8:** إعادة تأكيد أن فاعلًا يفقد `users.disable` بعد لحظة تحقُّق الـServer Action (محاكاة فجوة توقيت) لا يزال يُرفَض عند الاستدعاء الفعلي للدالة الموثوقة (الشرط ب يُعاد فحصه داخل الدالة نفسها، لا يُكتفى بثقة الطبقة الأعلى).
- **33.9:** محاولة `UPDATE`/`DELETE` مباشرة على `audit_logs` (بما فيها من Super Admin) → صفر صفوف متأثرة (`GET DIAGNOSTICS v_row_count = row_count`، لا استثناء — RLS تُصفّي الصفوف صمتًا لِـ`UPDATE`/`DELETE` بلا سياسة مطابقة، بخلاف `INSERT` التي كانت سترفع استثناء `WITH CHECK` صريحًا) — يُعاد تأكيد أن لا أحد يستطيع تعديل أو حذف سجلات التدقيق، بما فيها الحدث الجديد نفسه.

### تشغيل التحقق الكامل — نتائج فعلية (وليست افتراضًا)
- أُعيد بناء قاعدة اختبار Postgres محلية **من الصفر بالكامل** (حذف القاعدة والأدوار الثلاثة، إعادة إنشائها، `local_harness_setup.sql`، كل الترحيلات 0001–0039 بالترتيب، ثم `seed.sql`).
- `npm run typecheck` (`npx tsc --noEmit`) → صفر أخطاء.
- `npm run lint` → صفر أخطاء وتحذيرات.
- `npm run test` (Vitest) → `31/31` ناجح (بلا تغيير — لا اختبارات Vitest جديدة لهذا الـHotfix، التغيير بالكامل على مستوى القاعدة + Server Action واحد).
- `npm run build` (Next.js/Turbopack) → نجح، 17 مسارًا (بلا تغيير).
- اختبار SQL التكاملي → **نجح بالكامل**، `=== ALL RLS/PERMISSION/AUDIT/ESCALATION TESTS PASSED (including Foundation Hardening 1.4, Patch 1.4.1, and Foundation Audit Hotfix 1.4.2) ===`، **139 تأكيد "OK" عبر 33 قسمًا** (128 عبر 32 قسمًا سابقًا) — **لم يُحذَف أي اختبار أمني قائم**، الأقسام 1–31 كلها مطابقة لِمَا كانت عليه دون أي تغيير.

### الملفات/الترحيلات التي تغيَّرت في Foundation Audit Hotfix 1.4.2 (قائمة كاملة)
**ترحيلة جديدة واحدة فقط:** `supabase/migrations/0039_invite_cancel_trusted_only.sql`.
**ملفات تطبيق مُعدَّلة:** `src/features/users/actions.ts` (إعادة ترتيب `cancelUserInviteAction` بالكامل)، `src/types/database.ts` (إزالة `log_user_invite_cancel`، إضافة `log_user_invite_cancel_trusted`).
**اختبار SQL:** `supabase/tests/rls_and_permissions.test.sql` — تعديل الأقسام 32.4/32.5، إضافة قسم 33 كامل (33.1–33.9)، تحديث تعليق رأس الملف ورسالة النجاح النهائية.
**لم يتغيّر:** أي ترحيل من 0001–0038، وأي ملف تطبيق آخر غير المذكورَين أعلاه — لم تُلمَس Master Data/Sales، ولم تُفتح أي مراجعة أمنية جديدة.

**خلاصة الملحق السادس:** ثغرة واحدة فقط، ضيّقة ومحدَّدة تمامًا كما وصفها المستخدم، أُغلقت بثلاثة أجزاء مترابطة على مستوى القاعدة (EXECUTE-only، شرطان بنيويّان مستقلّان، وIdempotency)، مع إعادة ترتيب دقيقة لطبقة التطبيق (حذف أولًا، تسجيل ثانيًا). **الأهم:** لم يُكتفَ بإغلاق الثغرة كما وُصفت حرفيًا فقط — الشرط (أ) قُوِّي من "غياب صف profiles" (فحص كان سيمر أيضًا لهدف لم يكن له صف من الأساس) إلى "وجود صف `user.delete` مطابق فعليًا"، وهو ضمان بنيوي أقوى يغطي حالة حافة لم يذكرها الطلب صراحةً لكنها تقع ضمن روح الاشتراط الأصلي: **لا `user.invite_cancel` بدون حذف فعلي حقيقي سابق له، مُثبَت بسجل حقيقي، لا بغياب بيانات فقط.** الأساس المعماري (Foundation) **مُغلَق نهائيًا** عند هذا الإصدار (0001–0039)؛ لا عمل تأسيسي إضافي مخطَّط؛ الخطوة التالية هي Master Data/Sales مباشرة.

---

## الملحق السابع — "Phase 2: البيانات المالية الأساسية" (ترحيلات 0040–0046)

Foundation أُغلق نهائيًا عند 0039 (الملحق السادس) ولم تُعدَّل أي ترحيلة منه (0001–0039) في هذه المرحلة إطلاقًا — تحقَّق ذلك آليًا بإعادة تشغيل `rls_and_permissions.test.sql` كاملًا (139 تأكيد) على قاعدة مبنية من 0001–0046 معًا، ونجح دون أي تعديل على تلك الملف. كل تغيير جديد بدأ من 0040 وما بعده، تمامًا كما طُلب. النطاق محصور بستّ وحدات بيانات أساسية فقط — **لا Sales، لا Returns، لا Shipments، لا Settlements، لا حساب أرباح، لا محرّك استرجاع (Refund Engine)، لا تكامل Salla/Tabby/Tamara، لا مخزون، لا فواتير PDF، لا تقارير Excel، لا سحب تلقائي لسعر ذهب خارجي** — كل ما يخص هذه القائمة محضّر معماريًا فقط (أعمدة/enum محجوزة) دون أي منطق فعلي يستهلكها.

### 1) الترحيلات الجديدة (0040–0046)

| # | الترحيلة | الوحدة | أهم ما تضيفه |
|---|---|---|---|
| 0040 | `karats.sql` | العيارات | جدول `karats` + RLS + Audit + `active_karats()` |
| 0041 | `daily_gold_prices.sql` | أسعار الذهب اليومية | جدول `daily_gold_prices` (سجل تاريخي، `unique(price_date, karat_id)`) + `save_daily_gold_price()` (Upsert بعمود صريح يحمي `created_by`) + `gold_price_for_karat_on_date()` (يرفع خطأ لا يُعيد 0) + `gold_prices_missing_for_date()` |
| 0042 | `manufacturing_fee_versions.sql` | المصنعية حسب العيار | `create extension btree_gist` + جدول مُصدَر بقيد `EXCLUDE USING gist` يمنع أي تداخل زمني لنفس العيار + `create_manufacturing_fee_version()` (ذرّي: ينهي المفتوح وينشئ جديدًا) + `cancel_manufacturing_fee_version()` (يلغي نسخة مستقبلية فقط) + `manufacturing_fee_for_karat_on_date()` |
| 0043 | `product_categories.sql` | تصنيفات المنتجات | جدول هرمي (`parent_id` ذاتي الإشارة، عمق غير محدود) + Trigger `prevent_category_cycle()` + `active_product_categories()` |
| 0044 | `payment_methods.sql` | طرق الدفع | جدول `payment_methods` (منفصل تمامًا عن قنوات التحصيل) — `fee_model`/`refund_fee_policy` تهيئة تكوينية فقط |
| 0045 | `payment_method_fee_versions.sql` | عمولات طرق الدفع | نفس نمط 0042 بالضبط لكن لطرق الدفع، مع دعم أربعة أشكال (نسبة فقط/ثابت فقط/كلاهما/بدون) عبر عمودين NUMERIC دائمين بدل عمود نوع متعدد الأشكال |
| 0046 | `collection_channels.sql` | قنوات التحصيل | جدول `collection_channels` — **بلا أي مفتاح أجنبي** إلى `payment_methods` (تحقَّق منه اختباريًا، القسم 5 أدناه) |

كل الترحيلات السبعة تتبع نفس نمط الدفاع المتعدد الطبقات المُعتمَد في Foundation: RLS تُصفّي SELECT بصلاحية `.view` وINSERT/UPDATE بصلاحية `.manage`، **لا سياسة DELETE إطلاقًا** لأي جدول من السبعة (تعطيل بدل حذف فعلي)، ومُشغِّل تدقيق عام واحد (`audit_table_changes()`، من 0016 — لم يُعدَّل) على كل جدول.

### 2) الجداول الجديدة (7)

`karats`، `daily_gold_prices`، `manufacturing_fee_versions`، `product_categories`، `payment_methods`، `payment_method_fee_versions`، `collection_channels`. تفاصيل كل عمود موثَّقة داخل الترحيلة نفسها عبر `comment on table/column`.

### 3) الصفحات والمكوّنات الجديدة

**صفحات (`src/app/(app)/...`):**
- `/master-data` — صفحة مركزية (Hub) جديدة تجمع الوحدات الست كبطاقات، تُظهر فقط ما يملك المستخدم صلاحية عرضه.
- `/master-data/karats`, `/master-data/manufacturing-fees`, `/master-data/categories`, `/master-data/payment-methods`, `/master-data/collection-channels`.
- `/gold-prices` — **تحوّلت من صفحة "قريبًا" إلى صفحة حقيقية بالكامل** (نموذج سريع لإدخال أسعار كل العيارات لليوم بزر واحد "حفظ أسعار اليوم"، مع سجل تاريخي قابل للفلترة بالتاريخ/العيار، ومؤشر آخر تعديل ومن قام به، ومصدر السعر يدوي/مستورد).

**وحدات الميزات (`src/features/...`)، كل واحدة بنمط `schema.ts`/`queries.ts`/`actions.ts`/`components/` مطابق تمامًا لنمط `src/features/stores/*` القائم في Foundation:**
`karats/`، `gold-prices/`، `manufacturing-fees/`، `categories/` (تتضمن `tree.ts` منطق شجرة صِرف قابل للاختبار بمعزل عن قاعدة البيانات)، `payment-methods/` (تتضمن `labels.ts` لتسميات عربية)، `collection-channels/`.

**تعديلات على ملفات تنقّل قائمة:** `src/components/layout/nav-items.ts` (عنصر تنقّل جديد "البيانات الأساسية" بصلاحية `anyOf` بدل صلاحية واحدة؛ إزالة `comingSoon` عن أسعار الذهب)، `src/components/layout/sidebar-nav.tsx` (دعم `anyOf` في منطق التصفية)، `src/lib/constants.ts` (مسارات `ROUTES.masterData*` الجديدة)، `src/lib/audit/action-labels.ts` (تسميات عربية لكل حدث تدقيق جديد — انظر القسم 7).

**مكتبة جديدة مستقلة:** `src/lib/decimal.ts` — نقطة الاستيراد الوحيدة لكل حساب مالي في المشروع (`decimal.js`, `precision: 34`, `ROUND_HALF_UP`)؛ يُمنع استيراد `decimal.js` مباشرة في أي مكان آخر (موثَّق في تعليق رأس الملف نفسه). مُختبَرة بـ 9 اختبارات Vitest (`tests/decimal.test.ts`) تثبت عدم وجود انحراف فاصلة عائمة في الحسابات المالية.

### 4) الصلاحيات الجديدة (10)

فئة جديدة `financial_master_data` في `PERMISSION_CATEGORY_LABELS_AR`:

`karats.view`, `karats.manage`, `manufacturing_fees.view`, `manufacturing_fees.manage`, `categories.view`, `categories.manage`, `payment_methods.view`, `payment_methods.manage`, `collection_channels.view`, `collection_channels.manage`.

**توزيع الصلاحيات على الأدوار (مبدأ أقل امتياز، `supabase/seed.sql`):**
- **Super Admin:** كل شيء (بلا تغيير — يملك كل الصلاحيات دائمًا عبر `is_super_admin()`).
- **Admin:** كل الـ`.view` و`.manage` العشرة — يدير البيانات المالية الأساسية بالكامل، اتساقًا مع امتلاكه `gold_prices.edit` أصلًا.
- **Supervisor:** كل الـ`.view` الخمسة فقط — إشراف بلا إدارة.
- **Accountant:** كل الـ`.view` الخمسة، **بما فيها** `manufacturing_fees.view` — دور مالي رقابي يرى بنية التكلفة كاملة، اتساقًا مع امتلاكه `sales.view_profit` أصلًا (سيُستخدَم لاحقًا).
- **Sales Employee:** `karats.view`, `categories.view`, `payment_methods.view`, `collection_channels.view` فقط — **عمدًا بدون** `manufacturing_fees.view` (تفسير القرار في القسم 6 أدناه).
- **Shipping Employee:** لا شيء من هذه الصلاحيات (لا علاقة له بالبيانات المالية).

لم يُستخدَم `settings.manage` لأي من هذه الصلاحيات العشر — تمامًا كما طلبت المواصفة ("لا تُفرط في استخدام `settings.manage`").

### 5) نتائج التحقق الفعلية (وليست افتراضًا)

- أُعيد بناء قاعدة اختبار Postgres محلية **من الصفر بالكامل**: حذف `gold_erp_test`، إعادة إنشائها، `local_harness_setup.sql`، ثم **كل الترحيلات 0001–0046 بالترتيب دون توقف** (46/46 نجحت)، ثم `supabase/seed.sql` (نجح، بما فيه قسم Phase 2 الجديد في نهايته — 4 عيارات، 10 تصنيفات، 7 طرق دفع، 6 نسخ عمولة (COD مُستثناة عمدًا)، قناتا تحصيل).
- `npx tsc --noEmit` → **صفر أخطاء**.
- `npx eslint .` → **صفر أخطاء وتحذيرات**.
- `npx vitest run` → **43/43 ناجح عبر 5 ملفات** (يشمل `tests/decimal.test.ts` الجديد و`tests/category-tree.test.ts` الجديد، بالإضافة لكل اختبارات Foundation القديمة دون أي تغيير).
- `npm run build` (Next.js/Turbopack) → **نجح**، 24 مسارًا مُولَّدًا (بما فيها `/master-data` وخمس صفحاتها الفرعية، و`/gold-prices` كصفحة حقيقية الآن).
- `supabase/tests/rls_and_permissions.test.sql` (اختبار Foundation القائم، **دون أي تعديل عليه**) → **نجح كاملًا فوق قاعدة تحتوي 0040–0046 أيضًا** — يثبت عدم كسر أي شيء في Foundation.
- `supabase/tests/financial_master_data.test.sql` (**ملف اختبار جديد بالكامل**، مخصص لـPhase 2) → **نجح كاملًا، 50 تأكيد "OK"**، ينتهي بـ`=== ALL FINANCIAL MASTER DATA (PHASE 2) TESTS PASSED (migrations 0040-0046) ===`. يغطي:
  - **العيارات:** رفض كود مكرر (بصرف النظر عن حالة الأحرف)، اختفاء العيار المعطَّل من `active_karats()` مع بقائه محفوظًا، منع مستخدم "عرض فقط"/بلا صلاحيات.
  - **أسعار الذهب:** رفض تكرار (تاريخ، عيار) عبر `INSERT` مباشر أيضًا (لا الدالة فقط)، رفض سعر صفري/سالب، بقاء الأسعار التاريخية قابلة للاستعلام بعد تصحيح سعر يوم لاحق، حفظ `created_by` الأصلي عند تصحيح لاحق من فاعل مختلف (وتحديث `updated_by` فقط)، رفع خطأ صريح (`P0001`) بدل إعادة NULL/صفر لتاريخ بلا سعر مسجَّل، اكتشاف الأسعار الناقصة، منع تعديل غير مُصرَّح به.
  - **المصنعية:** إنشاء نسخة وإنهاء المفتوحة تلقائيًا وذريًا، بقاء المعدَّل التاريخي (`ended`) دون تغيير، رفض إنشاء نسخة متداخلة عبر الدالة **وعبر `INSERT` مباشر (قيد `EXCLUDE`)**، السماح بتاريخ سريان مستقبلي وإمكانية إلغائه، **رفض إلغاء نسخة سارية بالفعل** (لا تعديل رجعي صامت)، منع مستخدم غير مخوَّل.
  - **عمولات طرق الدفع:** الأشكال الأربعة (نسبة فقط/ثابت فقط/كلاهما/بدون رسوم) تعمل بنفس البنية دون أي تعديل مخطط، تحليل حسب التاريخ، رفض تداخل عبر الدالة وعبر `INSERT` مباشر، **إثبات أن COD (الحقيقية المزروعة في seed.sql، وأيضًا طريقة اختبارية منفصلة) ترفع خطأً صريحًا بدل نسبة مختلقة** لعدم وجود أي نسخة عمولة لها.
  - **قنوات التحصيل:** **إثبات بنيوي عبر `information_schema` أنه لا يوجد أي مفتاح أجنبي بينها وبين `payment_methods`** (استقلال حقيقي على مستوى المخطط، لا مجرد اتفاقية تسمية)، تعطيل يحفظ تاريخيًا، منع مستخدم غير مخوَّل.
  - **التصنيفات:** التسلسل الهرمي (رئيسي + فرعي)، **رفض حلقة تصنيفات** (إعادة تفريع تصنيف رئيسي تحت تصنيفه الفرعي)، تعطيل يحفظ تاريخيًا مع بقاء رابط الأبناء سليمًا، منع مستخدم غير مخوَّل.
  - **الأمان:** كل الجداول السبعة تُسجِّل أحداثها تلقائيًا في `audit_logs` (تحقَّق من كل نوع كيان)، صفوف التدقيق **غير قابلة للتعديل أو الحذف** حتى من مدير البيانات نفسه (0 صف متأثر لكل من `UPDATE`/`DELETE`).
  - **NUMERIC مقابل float (طبقة SQL):** إثبات أن `0.1::numeric + 0.2::numeric = 0.3` تمامًا بينما `0.1::double precision + 0.2::double precision <> 0.3` فعليًا (توثيق حي لسبب إلزام NUMERIC)، وأن جمع `0.1` عشر مرات بـNUMERIC يساوي `1.0` تمامًا (يطابق الاختبار المكافئ في `tests/decimal.test.ts` بطبقة الواجهة)، وفحص بنيوي عبر `information_schema.columns` يؤكد أن كل الأعمدة المالية الجديدة فعليًا من نوع `numeric` لا `float`/`double`.

### 6) قرارات معمارية اتُّخذت ولم تُحدَّد صراحةً في المواصفة (مع التبرير)

1. **إصلاح ثغرة منطقية اكتُشفت ذاتيًا قبل كتابة الاختبارات:** التصميم الأول لقيد `EXCLUDE` ولِدوال `manufacturing_fee_for_karat_on_date()`/`payment_fee_for_method_on_date()` استخدم الشرط `status = 'active'` لتحديد "هل هذا التاريخ مغطّى؟". هذا كان سيجعل أي تاريخ تاريخي يقع ضمن نسخة **سبق استبدالها** (`status = 'ended'`) يُعامَل كأنه **غير مُغطّى إطلاقًا** بمجرد إنشاء نسخة أحدث — رغم أن تلك النسخة القديمة سجل تاريخي صحيح تمامًا لفترتها الخاصة. صُحِّح إلى `status <> 'cancelled'` في الموضعين معًا (قيد `EXCLUDE` ودالتَي التحليل)، لأن `cancelled` هي الحالة الوحيدة التي لم تُستخدَم فعليًا إطلاقًا (نسخة مستقبلية أُلغيت قبل أن تسري). تحقَّق منه يدويًا بـ`psql` قبل كتابة أي كود واجهة، ثم بالاختبار الآلي (القسم 5 أعلاه، بند "بقاء المعدَّل التاريخي دون تغيير").
2. **`proportional_reversal` يغطّي الحالتين معًا لـTabby/Tamara بدل قيمة `enum` منفصلة لكل حالة:** استرجاع كامل هو ببساطة الحالة الخاصة "نسبة الاسترجاع = 100%" من استرجاع تناسبي — فلا حاجة فعلية لقيمة `full_reversal` مستقلة لهما؛ تُركت `full_reversal` متاحة في المخطط لمزوّد مستقبلي سياسته "الكل أو لا شيء" فعليًا (وليس تناسبيًا) — قرار أبسط ولا يفقد أي تعبير مطلوب.
3. **نمط الربط اليدوي بدل التضمين (Embedded Select) في طبقة الاستعلامات:** `src/types/database.ts` يحمل `Relationships: []` على كل جدول (قيد موثَّق ومعروف مسبقًا في المشروع)، فأي `select` مضمَّن (`profiles!...fkey(...)`) يُترجَم في TypeScript كـ`SelectQueryError`. اعتُمد نفس نمط استعلام مزدوج + دمج عبر `Map` المستخدَم أصلًا في `src/features/audit-log/queries.ts` بدل ابتكار نمط جديد مختلف النوع.
4. **صفحة `/master-data` كنقطة مركزية (Hub) بدل توزيع الروابط الست في الشريط الجانبي مباشرة:** تقليل ازدحام التنقّل، مع عنصر شريط جانبي واحد يظهر إذا امتلك المستخدم **أي واحدة** من صلاحيات العرض الخمس (`anyOf`، ميزة جديدة أُضيفت لِـ`NavItem` بدل الاكتفاء بصلاحية واحدة).
5. **رفع خطأ صريح (`RAISE EXCEPTION ... P0001`) بدل إرجاع `NULL`/`0` في كل دوال "القيمة المطبَّقة بتاريخ":** تنفيذ حرفي لبند المواصفة "لا يفترض النظام 0 بصمت في الحالات المالية" — يجعل غياب سعر ذهب أو مصنعية أو عمولة (كحالة COD الحقيقية) **خطأً مرئيًا لأي كود مستقبلي يستهلكه (Sales لاحقًا)** بدل معاملة مالية مجانية أو خاطئة صامتة.
6. **قيد `EXCLUDE USING gist` بدل الاكتفاء بمنطق التطبيق لمنع التداخل الزمني:** الدالتان `create_manufacturing_fee_version()`/`create_payment_method_fee_version()` تنهيان المفتوح وتُنشئان الجديد ذرّيًا داخل نفس المعاملة أصلًا، لكن قيد `EXCLUDE` يضيف طبقة حماية مستقلة على مستوى قاعدة البيانات نفسها تمنع حتى `INSERT` مباشر (متجاوزًا الدالة) من إنشاء تداخل — نفس فلسفة "لا تعتمد على الواجهة فقط" المُتَّبعة في كل هذا المشروع، وقد تحقَّق منها اختباريًا بشكل مستقل عن الدالة (القسم 5).
7. **`save_daily_gold_price()` بعمود صريح بدل `upsert()` كامل الأعمدة:** `upsert()` القياسي من `supabase-js` كان سيُعيد كتابة **كل** عمود يُمرَّر إليه عند التعارض، بما فيها `created_by`/`created_at` — يفقد "من سجَّل السعر أولًا" في كل مرة يُصحَّح فيها سعر نفس اليوم. الدالة الجديدة (`INSERT ... ON CONFLICT DO UPDATE` بعمود صريح) تُحدِّث `updated_by`/`updated_at` فقط عند التعارض، وتترك `created_by`/`created_at` بلا لمس — مُثبَت اختباريًا (القسم 5).
8. **توزيع الصلاحيات الجديدة على الأدوار بمبدأ أقل امتياز:** موظف المبيعات المستقبلي لا يحصل على `manufacturing_fees.view` عمدًا (يغذّي هامش الربح/التكلفة الداخلية، بنفس حساسية `sales.view_profit` التي لا يملكها هذا الدور أصلًا)، بينما المحاسب يحصل عليها (دور رقابي مالي بطبيعته). موثَّق كتعليق مباشر داخل `seed.sql` وليس قرارًا ضمنيًا.
9. **`prevent_category_cycle()` بعمق احتياطي 100 كحاجز دفاعي فقط:** لا حاجة عملية لشجرة تصنيفات بهذا العمق أبدًا؛ الحاجز موجود فقط لمنع حلقة `while` من الدوران إلى ما لا نهاية في حال وجود عطل بنيوي آخر غير متوقَّع في البيانات.

### 7) تسميات التدقيق العربية الجديدة (`src/lib/audit/action-labels.ts`)

أُضيفت تسميات لكل من `karat`/`gold_price`/`manufacturing_fee_version`/`product_category`/`payment_method`/`payment_method_fee_version`/`collection_channel` (كيانًا وحدثًا)، مطابقةً للأمثلة المطلوبة حرفيًا حيث أمكن (`إنشاء عيار`، `تسجيل سعر ذهب`، `تعديل سعر ذهب`، `إنشاء نسخة مصنعية`، `إنشاء طريقة دفع`، `تعديل طريقة دفع`، `إنشاء نسخة عمولة`، `إنشاء قناة تحصيل`، `تعديل تصنيف`). "تعطيل" ليس نوع حدث مستقل في مُشغِّل التدقيق العام (`UPDATE` واحدة سواء غُيِّر حقل عادي أو الحالة فقط) — فاتُّبع نفس نمط `store.update` القائم في Foundation ("تعديل بيانات متجر / تغيير حالته") لكل الكيانات الجديدة القابلة للتعطيل، بدل اختراع نوع حدث لا يستطيع المُشغِّل تمييزه فعليًا.

### 8) الملفات/الترحيلات التي تغيَّرت أو أُضيفت في Phase 2 (قائمة كاملة)

**ترحيلات جديدة (7):** `0040_karats.sql` … `0046_collection_channels.sql`.
**`supabase/seed.sql`:** امتداد (لا استبدال) — 10 صلاحيات جديدة + منحها للأدوار + قسم بذر بيانات Phase 2 كامل في نهاية الملف، كله عبر `ON CONFLICT ... DO NOTHING` (Idempotent، تحقَّق منه بإعادة تشغيله).
**اختبار SQL جديد بالكامل:** `supabase/tests/financial_master_data.test.sql`.
**مكتبة جديدة:** `src/lib/decimal.ts` + `tests/decimal.test.ts`.
**ميزات جديدة كاملة:** `src/features/{karats,gold-prices,manufacturing-fees,categories,payment-methods,collection-channels}/*` (+ `tests/category-tree.test.ts`).
**صفحات جديدة:** `src/app/(app)/master-data/{page,karats/page,manufacturing-fees/page,categories/page,payment-methods/page,collection-channels/page}.tsx`، واستبدال `src/app/(app)/gold-prices/page.tsx` (كان "قريبًا"، أصبح صفحة حقيقية).
**ملفات مُعدَّلة:** `src/types/database.ts` (أنواع + جداول + دوال جديدة)، `src/lib/permissions/constants.ts` (10 مفاتيح صلاحية + فئة جديدة)، `src/lib/constants.ts` (مسارات جديدة)، `src/lib/date.ts` (`riyadhTodayIsoDate()`)، `src/lib/audit/action-labels.ts` (القسم 7 أعلاه)، `src/components/layout/nav-items.ts` و`sidebar-nav.tsx` (دعم `anyOf` + عنصر تنقّل جديد).
**لم يتغيّر إطلاقًا:** أي ترحيل من 0001–0039، `supabase/tests/rls_and_permissions.test.sql` نفسه (أُعيد تشغيله فقط للتأكد)، وأي كود Foundation آخر لم يُذكَر أعلاه.

**خلاصة الملحق السابع:** ستّ وحدات بيانات أساسية مالية كاملة، بلا أي رقم/نسبة مالية مُبَيَّتة (Hardcoded) في منطق العمل، بلا `float` في أي حساب مالي، بلا حذف فعلي لأي بيانات أساسية استُخدمت تاريخيًا، مع تدقيق تلقائي شامل وRLS + SECURITY DEFINER بنفس معايير Foundation تمامًا. **لم تُبنَ Sales/Returns/Shipments/Settlements/حساب أرباح إطلاقًا في هذه المرحلة، ولن تبدأ المرحلة التالية تلقائيًا — العمل متوقف الآن بانتظار مراجعة المستخدم وموافقته الصريحة.**

---

## الملحق الثامن — "Financial Integrity Patch 2.1": سلامة البيانات المالية والـVersioning (ترحيلات 0047–0050)

بعد الملحق السابع، طُلب تصحيح محدَّد بتسعة بنود فوق Phase 2 — **ليس مراجعة أمنية عامة، وليس بداية Sales/Returns/أي مرحلة جديدة.** الشرط كان صريحًا: لا تعديل على أي ترحيل من 0001–0046، كل إصلاح جديد يبدأ من 0047 فصاعدًا، والهدف محصور بإغلاق ثغرات سلامة البيانات المالية والـVersioning في Phase 2 تحديدًا. هذا القسم يوثّق كل بند، ماذا كانت المشكلة تحديدًا، وكيف أُغلقت.

### 1) الترحيلات الجديدة (0047–0050)

| # | الترحيلة | تُغلق |
|---|---|---|
| 0047 | `versioning_and_fee_integrity.sql` | **بند 1:** حذف سياسات RLS `_insert`/`_update` عن `manufacturing_fee_versions`/`payment_method_fee_versions` كليًا — لا مسار كتابة مباشر لـ`authenticated` إطلاقًا بعد الآن. **بند 2:** `cancel_manufacturing_fee_version()`/`cancel_payment_method_fee_version()` تُعيدان فتح السلف الدقيق ذرّيًا عند إلغاء نسخة مستقبلية. **بند 6 (نصف قاعدة البيانات):** Triggers تفرض شكل `fee_model`، ترفض إنشاء نسخة لعيار/طريقة دفع غير نشطة، تمنع تغيير `fee_model` بما يجعل النسخة السارية غير متسقة، وقيد `CHECK` جديد `percentage_fee <= 100`. الدوال الأربع (`create_*`/`cancel_*`) أُعيد تعريفها `SECURITY DEFINER` بـ`search_path` ثابت و`REVOKE`/`GRANT` صريحين. |
| 0048 | `phase2_system_managed_columns_lockdown.sql` | **بند 3:** إرفاق `enforce_system_managed_columns()`/`enforce_created_by_immutable()` **الموجودتين أصلًا منذ 0021 (لم تُعدَّلا)** بالجداول السبعة الجديدة — لا Trigger جديد، فقط ربط الجداول بالدوال القائمة. |
| 0049 | `phase2_upgrade_defaults.sql` | **بند 4:** ترحيلة بيانات أمامية Idempotent — الصلاحيات العشر + منح الأدوار (بما فيها `super_admin` الآن، انظر ملاحظة تقنية أدناه) + البيانات الأساسية الأولية، بحيث لا تحتاج قاعدة إنتاج ترقّت من 0039 إعادة تشغيل `seed.sql` إطلاقًا. |
| 0050 | `gold_prices_bulk_save.sql` | **بند 5:** `save_daily_gold_prices_bulk(p_price_date, p_entries)` — يتحقق من كل الإدخالات (عيارات موجودة، لا تكرار، أسعار > 0) **قبل** أي كتابة؛ فشل إدخال واحد يُرجِع الكل بالكامل. |

كل الترحيلات الأربعة تتبع نفس نمط الدفاع المتعدد الطبقات المُعتمَد في Foundation و Phase 2: `SECURITY DEFINER` بـ`search_path` ثابت، `REVOKE EXECUTE FROM PUBLIC` ثم `GRANT` صريح فقط لمن يلزم، ومنطق موثَّق داخل تعليقات الترحيلة نفسها.

### 2) بنود المواصفة التسعة — كيف أُغلق كل واحد

1. **قفل جداول الـVersioning من التعديل المباشر:** `authenticated` — حتى حامل `.manage` — لا يستطيع `INSERT`/`UPDATE` مباشرًا على `manufacturing_fee_versions`/`payment_method_fee_versions` إطلاقًا بعد 0047 (0 سياسة RLS لهاتين العمليتين). المسار الوحيد المشروع: الدوال الأربع (`SECURITY DEFINER`، تتحقق من الصلاحية داخليًا). قيمة النسخة (`fee_per_gram`/`percentage_fee`/`fixed_fee`) وهويتها (`karat_id`/`payment_method_id`) و`effective_from` **لا يمكن تعديلها إطلاقًا بعد الإنشاء**، حتى عبر `service_role`/SQL مباشر (Trigger `BEFORE UPDATE` غير مشروط) — الكتابة الموثوقة الوحيدة المسموحة هي الإدراج الأولي (Bootstrap عبر `seed.sql`/0049، اللذين يتجاوزان RLS كليًا كـ`service_role`). مُثبَت بستة اختبارات SQL جديدة (القسم 3 أدناه) — INSERT/UPDATE مباشر من `authenticated` مرفوض، وتعديل القيمة/الهوية مرفوض حتى من `service_role`.
2. **إصلاح إلغاء نسخة مستقبلية:** المثال الحرفي من الطلب (8 حالي ← جدولة 10 مستقبلي ← إلغاء 10 قبل سريانه) كان يترك 8 منتهيًا (`ended`) للأبد بدل إعادة فتحه — فجوة مالية حقيقية. الإصلاح: `cancel_*_version()` تُعلِّم النسخة الملغاة `cancelled` **أولًا**، ثم تبحث عن السلف الدقيق (`status='ended' and effective_to = effective_from المُلغاة - 1`) وتُعيد فتحه (`effective_to=NULL, status='active'`) **ثانيًا**، بنفس المعاملة الذرّية — الترتيب مقصود بدقة لتفادي أن يرى قيد `EXCLUDE USING gist` النطاقين حيَّين في آنٍ واحد. لا سلف = لا شيء إضافي يحدث (لا اختلاق قيمة). مُختبَر بصورة صريحة **لكل من المصنعية والعمولات معًا** (تكرار الاختبار نفسه للعمولات، كما طلب المستخدم حرفيًا) في `financial_integrity_patch_2_1.test.sql`، بما في ذلك حالة "لا سلف" (النسخة الوحيدة لعيار جديد تمامًا).
3. **قفل الأعمدة المُدارة نظاميًا:** الدالتان الموجودتان أصلًا من 0021 (`enforce_system_managed_columns()` لِـ`karats`/`daily_gold_prices`/`product_categories`/`payment_methods`/`collection_channels`، و`enforce_created_by_immutable()` لجدولَي الـVersioning اللذين لا عمود `updated_*` فيهما بالتصميم) أُرفِقتا بالجداول السبعة عبر 0048 — بلا أي دالة جديدة. مُثبَت بمحاولات تزوير `created_by`/`created_at` صريحة عند الإدراج والتعديل معًا، على الجداول السبعة كلها.
4. **إصلاح مسار الترقية من Foundation 0039:** 0049 تُدرِج الصلاحيات العشر + منح الأدوار (`admin`/`supervisor`/`accountant`/`sales_employee`، وأيضًا `super_admin` — انظر الملاحظة التقنية أدناه) + البيانات الأساسية الأولية مباشرةً، بمعزل تام عن `seed.sql`. اختبار ترقية مخصَّص جديد (`upgrade_from_0039.test.sql` + `scripts/run_upgrade_test.sh`) يبني قاعدة من الصفر (0001–0039 فقط) + بذرة Foundation فقط (`foundation_only_seed.sql`، ثابتة تُحاكي حالة `seed.sql` **قبل** وجود Phase 2 إطلاقًا) + 0040–0050 **بلا** تشغيل `seed.sql` الحالي، ثم يتحقق أن كل شيء صحيح. `seed.sql` نفسه يبقى صالحًا تمامًا لإعادة تهيئة محلية/تطوير — تحقَّق منه بتشغيله بعد اكتمال الترقية، فأعاد **19/19 عبارة `INSERT 0 0`** (No-op حقيقي وكامل، وليس جزئيًا).
5. **حفظ أسعار الذهب اليومية ذرّيًا:** `save_daily_gold_prices_bulk()` تتحقق من كل الإدخالات (وجود العيار، عدم تكرار معرّف العيار، سعر > 0) في مرحلة تحقق منفصلة **قبل** أي `INSERT`/`UPDATE`؛ فشل إدخال واحد يُسقِط المعاملة بالكامل (`ROLLBACK` ذرّي عبر استثناء PL/pgSQL). `created_by`/`created_at` الأصليان محفوظان دائمًا، `updated_by`/`updated_at` يعكسان آخر تعديل، و`source_type`/`is_manual_override` **مُثبَّتان صراحةً** (`'manual'`/`true`) داخل الدالة نفسها ولا يُقرآن إطلاقًا من حمولة الطلب — مستخدم عادي لا يملك أي مسار لانتحال `source=external_api`.
6. **`fee_model` كقيد بنيوي على مستوى القاعدة:** Trigger `BEFORE INSERT` (`enforce_payment_method_fee_version_invariants()`) يفرض الشكل الأربعة (`none`→كلاهما صفر، `percentage`→`fixed_fee=0`، `fixed`→`percentage_fee=0`، `percentage_plus_fixed`→بلا قيد إضافي)، ويرفض إنشاء نسخة لطريقة دفع/عيار غير نشط (نفس المبدأ لِـ`manufacturing_fee_versions`)، وقيد `CHECK` جديد `percentage_fee <= 100`. **إجابة صريحة وليست وصفًا فقط** لسؤال المواصفة الختامي ("ماذا يحدث إذا غُيِّر `fee_model` لطريقة دفع لديها نسخ سابقة؟"): Trigger مستقل (`enforce_payment_method_fee_model_change_consistency()`، على `payment_methods`) يرفض أي تغيير لـ`fee_model` يجعل **النسخة السارية/المجدولة حاليًا فقط** (إن وُجدت) غير متسقة مع الشكل الجديد — النسخ التاريخية (`ended`) لا تُلمَس ولا يُعاد التحقق منها إطلاقًا (تبقى صحيحة للنموذج الذي كان ساريًا وقت إنشائها). مُثبَت اختباريًا: تغيير غير متوافق مرفوض بلا أي تعديل جزئي، تغيير متوافق مقبول، نسخة تاريخية لا تتأثر بتغيير `fee_model` إطلاقًا.
7. **حدود نقل القيم العشرية (Decimal Transport Boundary):** تدقيق شامل لكل استخدامات `Number(v)` على قيم مالية مصدرها القاعدة عبر المشروع — أُصلحت أربع حالات فعلية عبر ثلاثة ملفات `schema.ts` (`karats`، `manufacturing-fees`، `payment-methods`) ومكوّن عرض واحد (`payment-method-card.tsx`)، لتستخدم `toDecimal()`/`isPositiveDecimal()`/`isNonNegativeDecimal()` من `src/lib/decimal.ts` بدل `Number()` مباشرة. **قيد بيئة حقيقي مُوثَّق بشفافية:** `supabase gen types typescript` يتطلب Docker حتى في وضع `--db-url` (تحقَّق منه صراحةً مع أحدث إصدار للـCLI وإصدار أقدم أيضًا — كلاهما يفشل بلا خادم Docker في هذه البيئة، لا حل بديل مُصطنَع). بدلًا منه: `scripts/check-numeric-column-types.ts` — سكربت بلا اعتماديات جديدة يستعلم `information_schema.columns` مباشرة عبر `psql` (أداة مطلوبة أصلًا لاختبارات SQL في هذا المشروع) ويقارنها بأنواع `database.ts`، مُتاح عبر `npm run check:numeric-types`؛ تحقَّق من عمله بحقن خطأ نوع متعمَّد (`number` بدل `string`) والتأكد من رفضه، ثم التراجع والتأكد من نجاحه. اختباران جديدان في `tests/decimal.test.ts` يثبتان أن قيمة عشرية عالية الدقة (27 رقمًا معنويًا) تصل من حدود JSON/PostgREST إلى `Decimal` بلا فقدان دقة **فقط** عندما تُنقَل كنص، وأن استدعاء `Number()` على النص الصحيح نفسه يُعيد فقدان الدقة — إثبات أن الإصلاح الحقيقي هو "لا تستدعِ `Number()` إطلاقًا على قيمة مالية"، لا مجرد "انقلها كنص".
8. **عرض الحالي/القادم في الواجهة:** `listManufacturingFeeOverview()`/`listPaymentMethodsOverview()` تُعاد كتابتهما لجلب كل النسخ غير الملغاة (`neq('status', 'cancelled')`) دفعة واحدة (بلا استدعاءات N+1) ثم تحليل `currentVersion`/`upcomingVersion` في الواجهة بمنطق مطابق تمامًا لِـ`manufacturing_fee_for_karat_on_date()`/`payment_fee_for_method_on_date()` (استخدام `effective_from`/`effective_to` مقابل تاريخ اليوم بتوقيت الرياض). البطاقتان (`manufacturing-fee-card.tsx`/`payment-method-card.tsx`) تعرضان الآن بوضوح: القيمة السارية حاليًا (شارة خضراء)، القيمة القادمة إن وُجدت (كتلة منفصلة بشارة صفراء "القادم/القادمة" + تاريخ سريانها)، والسجل التاريخي — لا نسخة مستقبلية تُعرَض أبدًا كأنها الحالية.
9. **الاختبارات النهائية:** انظر القسم 3 أدناه.

> **ملاحظة تقنية (تصحيح ذاتي أثناء تنفيذ البند 4، وليس جزءًا من الطلب الأصلي):** التعليق الأول داخل 0049 ادّعى أن `super_admin` "لم يحصل على صلاحيات Phase 2 حتى في `seed.sql`" — هذا كان خطأً: إدراج `super_admin` في `seed.sql` هو `cross join public.permissions` شامل، فيلتقط **أي** صلاحية موجودة وقت تشغيله، بما فيها العشر الجديدة بمجرد وجودها. لو بقي 0049 بلا منح صريح لـ`super_admin`، لكانت إعادة تشغيل `seed.sql` بعد الترقية تُدخِل 10 صفوف `role_permissions` إضافية — لا تُغيِّر أي شيء وظيفيًا (`has_permission()` يتجاوز `super_admin` دائمًا) لكنها تكسر ادّعاء "No-op حقيقي وكامل". أُصلح بإضافة منح صريح لـ`super_admin` داخل 0049 نفسها (نفس نمط seed.sql الفعلي)، واختبار الترقية يتحقق الآن من العدد الصحيح (10) بدل صفر.

### 3) الاختبارات — قائمة كاملة وأرقام فعلية

**ملف اختبار جديد بالكامل:** `supabase/tests/financial_integrity_patch_2_1.test.sql` — **34 تأكيد "OK"**، ينتهي بـ`=== ALL FINANCIAL INTEGRITY PATCH 2.1 TESTS PASSED (migrations 0047-0050) ===`. يغطي مباشرة: قفل الكتابة المباشرة + الثبات (بندان 1) لكلا الجدولين (INSERT/UPDATE من `authenticated` مرفوضان، تعديل القيمة/الهوية مرفوض حتى من `service_role`، مع تحقّق أن `effective_to` وحده يبقى قابلًا للتعديل الشرعي)، سيناريو إعادة فتح السلف الحرفي (8→10→إلغاء→8) **لكل من المصنعية والعمولات**، حالة "لا سلف"، تزوير الأعمدة المُدارة على الجداول السبعة كلها (إدراج وتعديل)، وكل قيود `fee_model` (الأشكال الأربعة، رفض النسبة > 100، رفض القيم السالبة، رفض عيار/طريقة دفع معطَّلة، اتساق تغيير `fee_model`، وعدم مساس النسخ التاريخية).

**ملف اختبار ترقية جديد:** `supabase/tests/upgrade_from_0039.test.sql` (+ `supabase/tests/fixtures/foundation_only_seed.sql` + `scripts/run_upgrade_test.sh`) — **10 تأكيدات "OK"**، ينتهي بـ`=== ALL UPGRADE-FROM-0039 TESTS PASSED (0040-0050 applied WITHOUT re-running seed.sql) ===`. يبني قاعدة منفصلة تمامًا من 0001–0039 + بذرة Foundation فقط + 0040–0050 بلا `seed.sql` الحالي إطلاقًا، ويتحقق: الصلاحيات العشر موجودة، منح الأدوار الخمسة كلها مطابق حرفيًا لِـ`seed.sql` (بما فيها `super_admin`)، البيانات الأساسية (4 عيارات/10 تصنيفات/7 طرق دفع بنسب صحيحة تمامًا/COD بلا نسخة/قناتا تحصيل) موجودة وصحيحة، و**إثبات وظيفي** (لا عدّ صفوف فقط) أن `has_permission()` يعمل صحيحًا لفاعل `super_admin` ولفاعل دور عادي (`sales_employee`) بلا أي `user_permission_overrides` إطلاقًا.

**`financial_master_data.test.sql` (Phase 2، مُعدَّل — لم يُحذَف):** قسمان أصبحا غير صالحين بنجاح 0047 نفسه (كانا يثبتان أن قيد `EXCLUDE` هو ما يمنع تداخلًا مباشرًا عبر `INSERT` من `authenticated` — لكن `authenticated` أصبح ممنوعًا من `INSERT` أصلًا قبل الوصول لذلك القيد). **طُبِّق مبدأ المشروع الثابت "لا تُحذف اختبارات أمنية، تُقلَب توقعاتها إن تغيّر السلوك المقصود فعليًا"**: القسمان (مصنعية وعمولات) أُعيد كتابتهما في مكانهما ليثبتا أولًا أن `authenticated` مرفوض كليًا الآن، ثم يتحوّلا لسياق `service_role` ليثبتا أن قيد `EXCLUDE` ما زال يحمي سياقًا موثوقًا (`seed.sql`/0049) من تداخل زمني، ثم يُعيدان جلسة المدير الأصلية لبقية الملف. عُثِر أيضًا على خطأ استدعاء موجود سلفًا (توقيع دالة خاطئ في اختبار "رفض نسخة عمولة متداخلة" كان يمر فقط بالصدفة عبر `exception when others`) فأُصلح ليختبر السلوك الحقيقي المقصود. النتيجة: **52 تأكيد "OK"** (كانت 50)، ينتهي بنفس رسالة النجاح الأصلية دون تغيير.

**`rls_and_permissions.test.sql` (Foundation، بلا أي تعديل):** **139 تأكيد "OK"** كما كانت — يثبت أن 0047–0050 لم تكسر أي شيء في Foundation.

### 4) الفحص النهائي الكامل — نتائج فعلية

- إعادة بناء قاعدة اختبار Postgres محلية **من الصفر بالكامل**: حذف `gold_erp_test`، إعادة إنشائها، `local_harness_setup.sql`، **كل الترحيلات 0001–0050 بالترتيب دون توقف** (50/50 نجحت)، ثم `supabase/seed.sql` (نجح).
- `supabase/tests/rls_and_permissions.test.sql` → **نجح، 139/139 تأكيد**.
- `supabase/tests/financial_master_data.test.sql` → **نجح، 52/52 تأكيد**.
- `supabase/tests/financial_integrity_patch_2_1.test.sql` (جديد) → **نجح، 34/34 تأكيد**.
- اختبار الترقية (`scripts/run_upgrade_test.sh` + `upgrade_from_0039.test.sql`، على قاعدة منفصلة `gold_erp_upgrade_test`) → **نجح، 10/10 تأكيد**، وتحقَّق إضافيًا أن تشغيل `seed.sql` بعد الترقية **No-op كامل (19/19 `INSERT 0 0`)**.
- `npx tsc --noEmit` → **صفر أخطاء**.
- `npx eslint` → **صفر أخطاء وتحذيرات**.
- `npx vitest run` → **45/45 ناجح عبر 5 ملفات** (يشمل اختبارَي حدود النقل العشري الجديدَين في `tests/decimal.test.ts`).
- `npm run check:numeric-types` (بديل `supabase gen types typescript`، انظر البند 7 أعلاه) → **نجح، 5/5 عمود NUMERIC مطابق**.
- `npm run build` (Next.js/Turbopack) → **نجح**، 24 مسارًا مُولَّدًا، بلا أي تغيير في عدد المسارات (لا صفحات جديدة في هذه الـPatch، تعديلات بيانات/سلوك فقط).

### 5) الملفات/الترحيلات التي تغيَّرت أو أُضيفت في Patch 2.1 (قائمة كاملة)

**ترحيلات جديدة (4):** `0047_versioning_and_fee_integrity.sql`، `0048_phase2_system_managed_columns_lockdown.sql`، `0049_phase2_upgrade_defaults.sql`، `0050_gold_prices_bulk_save.sql`.
**اختبارات SQL جديدة بالكامل:** `supabase/tests/financial_integrity_patch_2_1.test.sql`، `supabase/tests/upgrade_from_0039.test.sql`، `supabase/tests/fixtures/foundation_only_seed.sql`.
**سكربتات جديدة:** `scripts/check-numeric-column-types.ts` (بديل `supabase gen types typescript`، بند 7)، `scripts/run_upgrade_test.sh` (أتمتة بناء قاعدة اختبار الترقية، بند 4).
**اختبار SQL مُعدَّل (لم يُحذَف أي قسم):** `supabase/tests/financial_master_data.test.sql` — القسمان 3.5/4.5 (تقليب التوقّع، انظر القسم 3 أعلاه) + إصلاح توقيع استدعاء خاطئ في اختبار قائم.
**`supabase/seed.sql`:** تعليقات فقط (لا تغيير منطقي) — توضيح أن 0049 هو مصدر الحقيقة لترقية الإنتاج، وأن الملف يبقى صالحًا لإعادة التهيئة المحلية.
**ملفات تطبيق مُعدَّلة:** `src/features/gold-prices/actions.ts` (استدعاء `save_daily_gold_prices_bulk()` بدل حلقة استدعاءات منفصلة)، `src/types/database.ts` (إضافة `save_daily_gold_prices_bulk` لخريطة `Functions`)، `package.json` (سكربت `check:numeric-types`)، `src/features/karats/schema.ts`/`manufacturing-fees/schema.ts`/`payment-methods/schema.ts` (استبدال `Number(v)` بمساعدات `Decimal`، بند 7)، `src/features/payment-methods/components/payment-method-card.tsx` وقرينتها `manufacturing-fee-card.tsx` (عرض الحالي/القادم منفصلَين، بند 8)، `src/features/manufacturing-fees/queries.ts`/`payment-methods/queries.ts` (إعادة كتابة `list*Overview()` لتحليل الحالي/القادم)، صفحتا `master-data/manufacturing-fees/page.tsx`/`master-data/payment-methods/page.tsx` (تمرير `currentVersion`/`upcomingVersion` بدل `openVersion`)، `tests/decimal.test.ts` (اختبارا حدود النقل العشري الجديدان).
**لم يتغيّر إطلاقًا:** أي ترحيل من 0001–0046، `supabase/tests/rls_and_permissions.test.sql` نفسه، وأي كود Foundation/Phase 2 آخر لم يُذكَر أعلاه.

**خلاصة الملحق الثامن:** تسعة بنود مطلوبة بالضبط، أُغلقت كلها على مستوى القاعدة (لا الواجهة فقط)، بأربع ترحيلات جديدة فقط بعد 0046، بلا لمس Foundation أو Phase 2 القائمين، وبلا بدء Sales/Returns/أي مرحلة جديدة. **الأهم:** التنفيذ نفسه كشف ثغرة توثيقية صغيرة في 0049 (ادّعاء خاطئ حول `super_admin`) صُحِّحت فور اكتشافها أثناء بناء اختبار الترقية — وهذا بالتحديد سبب بناء اختبار ترقية فعلي كامل بدل الاكتفاء بمراجعة نظرية لِـ0049. Phase 2 أصبحت الآن **مُحصَّنة ماليًا بالكامل** (Versioning مقفل، لا فجوات إلغاء، لا تزوير أعمدة نظامية، لا تناقض `fee_model`، حفظ أسعار ذري، حدود نقل عشري آمنة، عرض حالي/قادم صحيح في الواجهة) بنفس معايير الصرامة المتبعة في كل مراجعة سابقة من Foundation. **لم تبدأ Sales ولن تبدأ تلقائيًا — العمل متوقف الآن بانتظار مراجعة المستخدم وموافقته الصريحة.**

---

## الملحق التاسع — "Financial Integrity Patch 2.2": إغلاق أربع ثغرات متبقّية + إثبات حقيقي لحدود النقل العشري (ترحيلات 0051–0054)

بعد مراجعة تالية لِـPatch 2.1 المُسلَّمة، وردت أربعة بنود تصحيح إضافية دقيقة — **ليست مراجعة أمنية عامة جديدة، وليست بداية Sales/Returns/أي مرحلة جديدة.** الشرط كان صريحًا كسابقه: لا تعديل على أي ترحيل من 0001–0050، كل إصلاح جديد يبدأ من 0051 فصاعدًا. **تصحيح مهم من المستخدم نفسه قبل التنفيذ:** الادّعاء الوارد في الملحق الثامن (البند 7) بأن `supabase gen types typescript`/`supabase-js` "يُرجعان NUMERIC كـ`string` دائمًا" **كان خطأً فعليًا**، وليس مجرد صياغة غير دقيقة — PostgREST يُسلسِل عمود `numeric` كرقم JSON **بلا اقتباس افتراضيًا**، والمولِّد الرسمي الحقيقي يُطابق ذلك بتوليد `number` لا `string`. هذا الملحق يوثّق التصحيح الفعلي لهذا الفهم، لا الاكتفاء بتصحيح الصياغة.

### 1) الترحيلات الجديدة (0051–0054)

| # | الترحيلة | تُغلق |
|---|---|---|
| 0051 | `gold_price_source_integrity.sql` | **بند 1:** Trigger جديد `daily_gold_prices_enforce_source_integrity` (`BEFORE INSERT OR UPDATE`) يُثبِّت `source_type='manual'`/`is_manual_override=true`/`source_name=NULL`/`source_reference=NULL` على أي كتابة **ليست** من سياق موثوق (`is_trusted_bootstrap_context()`، موجودة أصلًا منذ 0013) — سواء جاءت عبر `save_daily_gold_price()`/`save_daily_gold_prices_bulk()` أو عبر `INSERT`/`UPDATE` مباشر من `authenticated`. |
| 0052 | `finance_safe_read_boundary.sql` | **بند 2:** ثلاث دوال `_safe` جديدة (`gold_price_for_karat_on_date_safe()`، `manufacturing_fee_for_karat_on_date_safe()`، `payment_fee_for_method_on_date_safe()`) — كل واحدة تُنفِّذ الدالة الأصلية ثم تُحوِّل النتيجة `::text` **داخل Postgres قبل** أن يُسلسِلها PostgREST — فتصل كنص JSON مقتبَس (بلا فقدان دقة) بدل رقم JSON غير مقتبَس. |
| 0053 | `single_future_version.sql` | **بند 3:** `create_manufacturing_fee_version()`/`create_payment_method_fee_version()` تُعاد كتابتهما — ترفضان إنشاء أي نسخة مستقبلية جديدة إن كانت النسخة المفتوحة الحالية نفسها لم تسرِ بعد (`effective_from > current_date`). "نسخة مستقبلية واحدة كحد أقصى" أصبح قيدًا بنيويًا حقيقيًا. |
| 0054 | `gold_price_active_karat_check.sql` | **بند 4:** `karat_status_for_price_entry()` (دالة `SECURITY DEFINER` ضيّقة النطاق جديدة) + تعديل `save_daily_gold_price()`/`save_daily_gold_prices_bulk()` لرفض تسجيل **سعر جديد** (لا تصحيح سعر موجود) لعيار `status <> 'active'`. |

كل الترحيلات الأربعة تتبع نفس نمط الدفاع المتعدد الطبقات: `SECURITY DEFINER`/`SECURITY INVOKER` بحسب الحاجة الفعلية، `search_path` ثابت حيث يلزم، `REVOKE EXECUTE FROM PUBLIC` ثم `GRANT` صريح، ومنطق موثَّق داخل تعليقات الترحيلة نفسها.

### 2) البنود الأربعة — كيف أُغلق كل واحد

**1) إغلاق تزوير `source_type` لأسعار الذهب.** المشكلة: `save_daily_gold_prices_bulk()`/`save_daily_gold_price()` كانتا تُثبِّتان `manual`/`true` دائمًا عند الكتابة **عبرهما**، لكن `daily_gold_prices` كانت لا تزال تسمح بـ`INSERT`/`UPDATE` مباشر عبر RLS (منذ 0041، لم يمسّها إغلاق 0047 الذي شمل جدولَي الـVersioning فقط) لأي حامل `gold_prices.edit` — أي أن مستخدمًا عاديًا كان يستطيع تجاوز الدالتين كليًا عبر PostgREST مباشرةً ووضع `source_type='external_api'` + `source_name`/`source_reference` مُلفَّقين + `is_manual_override=false`، منتحلًا مصدرًا آليًا موثوقًا غير موجود أصلًا.

**قرار التصميم (مُوثَّق صراحةً، لا مجرد تنفيذ):** اختير نمط **Trigger يعتمد على السياق الموثوق** بدل إغلاق RLS كليًا (نمط 0047 لجدولَي الـVersioning)، لثلاثة أسباب مُوثَّقة داخل رأس 0051 نفسه: (أ) سعر يومي — خلافًا لنسخة رسوم — قابل للتصحيح الشرعي في مكانه طوال اليوم، وإغلاق RLS كليًا لا يضيف شيئًا هنا لأن التصحيح أصلًا يمر عبر الدالة؛ (ب) تكامل مستقبلي موثوق حقيقي (مصدر أسعار آلي) من المتوقَّع أن يكتب عبر `service_role` من مهمة خادم، وهو تحديدًا ما يُميّزه `is_trusted_bootstrap_context()` بدقة — إغلاق RLS كليًا كان سيُجبر ذلك التكامل المستقبلي على المرور عبر RPC جديدة رغم أن الفارق الحقيقي هو "مستخدم موقَّع دخول عادي مقابل سياق خادم موثوق"، وهو ما يفحصه الـTrigger مباشرة؛ (ج) الإغلاق فعّال بالكامل رغم ذلك — أيًا كان مسار الكتابة (RPC أو مباشر)، لا يمكن لمستخدم `authenticated` عادي أن ينتهي بـ`source_type='external_api'` أو مصدر مُلفَّق إطلاقًا. `external_api` يبقى محجوزًا فعليًا (لا وهميًا) لمسار Trusted Integration مستقبلي عبر `service_role`. قراءة السجل التاريخي والتصحيحات اليدوية المُصرَّح بها **لم تتأثرا إطلاقًا** — الـTrigger يمسّ فقط أعمدة إسناد المصدر الأربعة، لا `price_per_gram`/`price_date`/`karat_id`/`notes`.

**2) إصلاح حدود نقل القيم العشرية فعليًا (لا مجرد شكليًا).** هذا كان أهم بند وأكثرها تطلّبًا للدقة، وأُنجِز على ثلاث طبقات متكاملة، بلا الاكتفاء بأي واحدة منها بمفردها:

  - **تصحيح الفهم الخاطئ نفسه، في كل مكان ادّعاه:** `src/lib/decimal.ts` (تعليق `toDecimal()`)، `scripts/check-numeric-column-types.ts` (رأس الملف بالكامل، أُعيدت كتابته لا مجرد تعديل صياغته)، `tests/decimal.test.ts` (تعليقات القسم الخاص بحدود النقل)، و`src/types/database.ts` نفسه. **`database.ts` كان يحمل الخطأ فعليًا، لا فقط في التعليقات:** الأعمدة الخام `price_per_gram`/`fee_per_gram`/`percentage_fee`/`fixed_fee`/`purity_per_mille` وكذلك دوال `gold_price_for_karat_on_date()`/`manufacturing_fee_for_karat_on_date()`/`payment_fee_for_method_on_date()` (غير `_safe`) كانت جميعًا مكتوبة يدويًا كـ`string` في نوع `Row`/`Returns` — وهذا **لا يُطابق واقع PostgREST الفعلي**. صُحِّحت كلها إلى `number` (الحقيقة الفعلية)، وأُضيفت أنواع الدوال الثلاث `_safe` الجديدة (0052) كـ`string` حقيقي. تحقَّقت وكالة بحث مستقلة (Explore agent) أن هذا التصحيح **لا يكسر `tsc` في أي موضع استهلاك فعلي** في التطبيق (كل الاستخدامات إما `toDecimal()`، الذي يقبل `number` أصلًا، أو عرض JSX/نص بحت لا حساب مالي فيه) — تحقَّق ذلك عمليًا لاحقًا بتشغيل `tsc --noEmit` فعليًا بصفر أخطاء.
  - **حدود قراءة آمنة ماليًا على مستوى القاعدة (0052):** الدوال الثلاث `_safe` أعلاه — أي كود مستقبلي (Sales/Returns/Settlements) يحتاج قيمة مالية تدخل حساب `Decimal` **يجب** أن يستخدمها، لا الدوال الأصلية `numeric`.
  - **إعادة كتابة `scripts/check-numeric-column-types.ts` بالكامل، لا تعديل تعليقه فقط:** كان الفحص السابق يفترض العكس تمامًا ("NUMERIC يجب أن يكون `string`") — عكس السكربت الآن ليتحقق من الحقيقة الفعلية: كل عمود NUMERIC خام يجب أن يكون `number` في `database.ts`، لا `string`. يوثّق السكربت صراحةً أنه **لا يضمن سلامة أي حساب مالي بمفرده** — تلك مسؤولية استخدام الدوال `_safe`، منفصلة تمامًا.
  - **الإثبات الحاسم المطلوب صراحةً: اختبار HTTP/PostgREST حقيقي، لا محاكاة `JSON.parse` فقط.** بُنيت بنية اختبار كاملة (`scripts/run_postgrest_http_test.sh` + `scripts/postgrest-http-test.mjs` + `scripts/sign-test-jwt.mjs` + `supabase/tests/postgrest_http_test_setup.sql`) تُنفِّذ: بناء قاعدة اختبار مُتخلَّى عنها بالكامل (Foundation harness + كل الترحيلات 0001–0054 + `seed.sql` + بيانات اختبار حقيقية) ← تشغيل **ثنائي PostgREST رسمي حقيقي (v12.2.3)** ضدها فعليًا عبر HTTP ← توقيع JWT حقيقي (HS256، عبر وحدة `crypto` المدمجة في Node، بلا اعتماديات جديدة) لفاعل `authenticated` حقيقي ← استدعاء `@supabase/postgrest-js` (المكتبة الفعلية التي يستخدمها `supabase-js` داخليًا لِـ`.rpc()`/`.from()`، مُستخدَمة هنا مباشرة لتفادي افتراض بادئة `/rest/v1` التي يفرضها `createClient()`) عبر HTTP حقيقي فعليًا — لا محاكاة، لا حقن يدوي لِـJSON.
  
    النتيجة الفعلية (15/15 تأكيد نجح، انظر القسم 4 أدناه): قيمة تركيبية بـ27 رقمًا معنويًا عبر دالة تشخيصية خام تصل فعليًا كـ`typeof === "number"` **وتُفسَد فعليًا** (لا تُطابق القيمة الأصلية) عبر HTTP حقيقي — إثبات فعلي للثغرة، لا افتراض نظري. نفس القيمة عبر النسخة `::text` تصل كـ`typeof === "string"` وتُطابق الأصل حرفيًا وتدخل `Decimal` بلا أي فقدان. الدوال الإنتاجية الثلاث الفعلية من 0052 (لا فقط دوال تشخيصية اصطناعية) اختُبِرت بنفس الطريقة ضد بيانات اختبار حقيقية (سعر ذهب، رسم مصنعية، عمولة دفع) وأثبتت نفس النتيجة: النسخة الخام `number`، النسخة `_safe` `string` مطابقة تمامًا للخام (بمقارنة `Decimal`).

  **الخلاصة الصادقة والدقيقة (بلا مبالغة):** حدود النقل العشري أصبحت الآن **مُغلَقة فعليًا وليس فقط مُوثَّقة نظريًا** — أُثبتت عبر HTTP/PostgREST حقيقي، لا محاكاة. هذا الإثبات وحده كافٍ ليكون الأساس التقني لأي كود Sales مستقبلي يقرأ قيمًا مالية عبر الدوال `_safe`. الشيء الوحيد المتبقّي كقيد بيئة (لا كثغرة): تشغيل `supabase gen types typescript` الرسمي ضد مشروع Supabase حقيقي يبقى غير مُتاح في هذه البيئة (Docker غير متوفر، نفس القيد المُوثَّق في الملحق الثامن، أُعيد التحقق منه ولم يتغيّر) — عند توفره، يجب تشغيله ومقارنة مخرجاته فعليًا بـ`database.ts` كخطوة تحقق إضافية قبل الإنتاج، تمامًا كما يوصي `scripts/check-numeric-column-types.ts` بنفسه في تعليقه.

**3) منع/دعم أكثر من نسخة مستقبلية بشكل صحيح.** السيناريو الحرفي من الطلب (حالي=8 ← جدولة مستقبلي=10 (1 سبتمبر) ← جدولة مستقبلي آخر=12 (1 أكتوبر) فوقه) كان يُنتِج: 8 حتى 31 أغسطس، 10 من 1–30 سبتمبر (رغم أنه لم يسرِ يومًا واحدًا فعليًا)، 12 من 1 أكتوبر. مشكلتان بنيويتان فعليتان نتجتا عن ذلك: (أ) واجهة الحالي/القادم (بند 8 من Patch 2.1) تعرض فقط الصف المفتوح الواحد كـ"القادم" — فكانت ستعرض 12 كقادم بينما القيمة القادمة الحقيقية (10) تسقط بصمت في "السجل التاريخي" وتبدو كنسخة منتهية عادية رغم أنها لم تبدأ إطلاقًا؛ (ب) `cancel_*_version()` لم تعد قادرة على إلغاء 10 لأن حالتها أصبحت `'ended'`.

الإصلاح المُختار (تفضيل المستخدم الصريح، تبسيطي ومقصود): **نسخة مستقبلية واحدة كحد أقصى** لكل عيار/طريقة دفع — إن كانت النسخة المفتوحة الحالية `effective_from > current_date` (أي هي نفسها لم تسرِ بعد)، تُرفَض أي محاولة جدولة نسخة مستقبلية أخرى فوقها كليًا؛ يجب إلغاء النسخة المستقبلية القائمة أولًا (`cancel_*_version()`، تُعيد فتح السلف كما في Patch 2.1) ثم إنشاء الجديدة. هذا يجعل "القادم" مفردًا دائمًا ببنية القاعدة نفسها، لا بمنطق واجهة يعتمد على افتراض قد يُنتَهَك.

**مُراجعة الواجهة بعد الإصلاح (فعلية، لا افتراضية):** أُعيدت قراءة `src/features/manufacturing-fees/queries.ts`/`payment-methods/queries.ts` وبطاقتَي العرض (`manufacturing-fee-card.tsx`/`payment-method-card.tsx`) فعليًا (لا مجرد تذكّر منطقها من Patch 2.1). النتيجة: **لا حاجة لأي تعديل** — `listManufacturingFeeOverview()`/`listPaymentMethodsOverview()` يحلّلان `currentVersion` (يغطي تاريخ اليوم فعليًا) و`upcomingVersion` (الصف المفتوح الوحيد إن كان `effective_from > today`) بمنطق كان صحيحًا أصلًا بافتراض "نسخة مستقبلية واحدة كحد أقصى" — وهو الافتراض الذي أصبح الآن قيدًا حقيقيًا مضمونًا بنيويًا من القاعدة بدل افتراض قد يُنتَهَك. البطاقتان تستبعدان صراحةً `currentVersion`/`upcomingVersion` من `pastVersions` (`history.filter(v => v.id !== currentVersion?.id && v.id !== upcomingVersion?.id)`) — بضمان "نسخة مستقبلية واحدة" الجديد، **لا يمكن بنيويًا** أن تظهر نسخة مستقبلية لم تبدأ بعد داخل "السجل التاريخي" بعد اليوم؛ الحالي = قيمة اليوم فقط، القادم = النسخة المستقبلية الوحيدة الممكنة إن وُجدت، السجل = كل ما عداهما فعلًا.

**4) فحص إضافي صغير: عيار غير نشط لا يقبل سعرًا يوميًا جديدًا.** `save_daily_gold_prices_bulk()` (0050) كانت تتحقق فقط من وجود العيار، لا من حالته — عيار مُعطَّل كان لا يزال يقبل سعرًا يوميًا جديدًا عبر الإدخال التشغيلي العادي، تناقضًا نموذجيًا مع مبدأ 0047 نفسه (لا نسخة رسوم جديدة لعيار/طريقة دفع معطَّلة). أُصلح للدالتين معًا (`save_daily_gold_price()` أيضًا — نفس الفجوة بالضبط، أُصلحت للاتساق رغم أن المواصفة ذكرت الدالة الجماعية تحديدًا). **النطاق دقيق ومقصود:** يُمنَع إنشاء سعر **جديد** فقط (تاريخ لم يُسجَّل له سعر من قبل لهذا العيار) — تصحيح سعر **موجود** لتاريخ سابق لتعطيل العيار يبقى مسموحًا دائمًا (`ON CONFLICT DO UPDATE` تنجح كما هي)، فلا يتأثر عرض/تصحيح التاريخ إطلاقًا. **ثغرة تصحيح ذاتي أثناء الاختبار (لا تقرير من المستخدم):** المسودة الأولى استخدمت `SELECT status FROM public.karats` مباشرة داخل الدالتين (كلتاهما `SECURITY INVOKER`) — خضع ذلك لِRLS الخاص بالفاعل المستدعي نفسه، فكسر اختبارًا قائمًا في `financial_master_data.test.sql` لفاعل يملك `gold_prices.edit` لكن ليس `karats.view` (النقطة نفسها التي منعت استخدام `SELECT` خام مشابه سابقًا). أُصلح بإضافة `karat_status_for_price_entry()` — دالة `SECURITY DEFINER` ضيّقة النطاق (بنفس نمط `am_i_super_admin()` من Foundation) تُتيح قراءة حالة العيار فقط دون الحاجة لصلاحية `karats.view` كاملة.

### 3) الاختبارات — قائمة كاملة وأرقام فعلية

**ملف اختبار جديد بالكامل:** `supabase/tests/financial_integrity_patch_2_2.test.sql` — **17 تأكيد "OK"**، ينتهي بـ`=== ALL FINANCIAL INTEGRITY PATCH 2.2 TESTS PASSED (migrations 0051-0054) ===`. يغطي البنود الأربعة مباشرة: تزوير `source_type` عبر `INSERT`/`UPDATE` مباشر مرفوض تلقائيًا (يُصحَّح لا يُرفَض بخطأ — التصحيح الصامت الآمن هو السلوك المقصود)، `service_role` يبقى قادرًا على `external_api` (المسار المحجوز يعمل فعلًا)، الدوال `_safe` الثلاث تُعيد `text` فعليًا (`pg_typeof()`) بقيمة مطابقة تمامًا للأصل NUMERIC + قيمة عالية الدقة تنجو على مستوى SQL، سيناريو "نسخة مستقبلية واحدة" الحرفي (رفض الثانية، إلغاء الأولى، قبول الثانية بعدها) **لكل من المصنعية والعمولات معًا**، ورفض سعر جديد لعيار مُعطَّل عبر الدالتين المفردة والجماعية مع نجاح تصحيح سعر قائم على عيار عُطِّل لاحقًا.

**اختبار HTTP/PostgREST حقيقي جديد بالكامل:** `scripts/run_postgrest_http_test.sh` (+ `postgrest-http-test.mjs` + `sign-test-jwt.mjs` + `supabase/tests/postgrest_http_test_setup.sql`) — **15/15 تأكيد نجح**، ينتهي بـ`=== ALL REAL HTTP/POSTGREST INTEGRATION TEST ASSERTIONS PASSED ===`. هذا **ليس** جزءًا من ملفات `.test.sql` (SQL وحدها لا تستطيع إثبات سلوك تسلسل PostgREST الفعلي عبر HTTP) — ثنائي PostgREST v12.2.3 حقيقي، JWT حقيقي موقَّع، `@supabase/postgrest-js` حقيقية، قاعدة اختبار مُتخلَّى عنها بالكامل تُبنى وتُهدَم في كل تشغيل.

**الملفات الثلاثة الأخرى (لم تُحذَف، لم تحتَج تعديلًا منطقيًا):** `rls_and_permissions.test.sql` → **139/139**، `financial_master_data.test.sql` → **52/52**، `financial_integrity_patch_2_1.test.sql` → **34/34** — كلها أُعيد تشغيلها ضد قاعدة تحتوي 0051–0054 أيضًا، لإثبات أن الترحيلات الجديدة لم تكسر أي شيء قائم.

### 4) الفحص النهائي الكامل — نتائج فعلية

- إعادة بناء قاعدة اختبار Postgres محلية **من الصفر بالكامل**: حذف `gold_erp_test`، إعادة إنشائها، `local_harness_setup.sql`، **كل الترحيلات 0001–0054 بالترتيب دون توقف** (54/54 نجحت)، ثم `supabase/seed.sql` (نجح).
- `supabase/tests/rls_and_permissions.test.sql` → **نجح، 139/139 تأكيد**.
- `supabase/tests/financial_master_data.test.sql` → **نجح، 52/52 تأكيد**.
- `supabase/tests/financial_integrity_patch_2_1.test.sql` → **نجح، 34/34 تأكيد**.
- `supabase/tests/financial_integrity_patch_2_2.test.sql` (جديد) → **نجح، 17/17 تأكيد**.
- اختبار الترقية (`scripts/run_upgrade_test.sh` + `upgrade_from_0039.test.sql`، على قاعدة منفصلة `gold_erp_upgrade_test`، يُطبِّق 0040–**0054** تلقائيًا عبر glob بلا تعديل على السكربت نفسه) → **نجح، 10/10 تأكيد**.
- **اختبار HTTP/PostgREST حقيقي جديد** (`scripts/run_postgrest_http_test.sh`) → **نجح، 15/15 تأكيد**، ضد ثنائي PostgREST v12.2.3 حقيقي عبر HTTP فعلي.
- `npx tsc --noEmit` → **صفر أخطاء** (بعد تصحيح أنواع NUMERIC الخام في `database.ts` من `string` إلى `number` — تحقَّقت وكالة بحث مستقلة مسبقًا أن هذا لا يكسر أي موضع استهلاك، وأكَّد `tsc` ذلك فعليًا).
- `npx eslint` → **صفر أخطاء وتحذيرات**.
- `npx vitest run` → **45/45 ناجح عبر 5 ملفات** (نفس العدد — لا اختبارات جديدة أُضيفت هنا؛ تعليقات `tests/decimal.test.ts` صُحِّحت فقط لتعكس الفهم الصحيح ومصدر القيمة الآمنة الفعلي).
- `npm run check:numeric-types` (مُعاد كتابته بالكامل، انظر البند 2 أعلاه) → **نجح، 5/5 عمود NUMERIC مطابق للحقيقة الفعلية (`number`، لا `string`)**.
- `npm run build` (Next.js/Turbopack) → **نجح**، 24 مسارًا مُولَّدًا (بلا تغيير في العدد — لا صفحات جديدة في هذه الـPatch).

### 5) الملفات/الترحيلات التي تغيَّرت أو أُضيفت في Patch 2.2 (قائمة كاملة)

**ترحيلات جديدة (4):** `0051_gold_price_source_integrity.sql`، `0052_finance_safe_read_boundary.sql`، `0053_single_future_version.sql`، `0054_gold_price_active_karat_check.sql`.
**اختبار SQL جديد بالكامل:** `supabase/tests/financial_integrity_patch_2_2.test.sql`.
**بنية اختبار HTTP/PostgREST حقيقي جديدة بالكامل:** `scripts/run_postgrest_http_test.sh`، `scripts/postgrest-http-test.mjs`، `scripts/sign-test-jwt.mjs`، `supabase/tests/postgrest_http_test_setup.sql` (بيانات/دوال تشخيصية اختبارية فقط، غير مُطبَّقة على أي مشروع حقيقي).
**سكربت مُعاد كتابته بالكامل (لا تعديل صياغة فقط):** `scripts/check-numeric-column-types.ts` — يتحقق الآن من عكس ما كان يتحقق منه سابقًا (الحقيقة الفعلية: `number`، لا `string`).
**ملفات مُصحَّحة (فهم PostgREST الفعلي، لا مجرد صياغة):** `src/lib/decimal.ts` (تعليق `toDecimal()`)، `src/types/database.ts` (خمسة أعمدة NUMERIC خام + ثلاث دوال قراءة أصلية من `string` إلى `number`، + إضافة الدوال الثلاث `_safe` الجديدة كـ`string` حقيقي)، `tests/decimal.test.ts` (تعليقات قسم حدود النقل العشري + اسم الاختبارين)، `src/features/payment-methods/components/payment-method-card.tsx` (تعليق مُصحَّح فقط، لا تغيير سلوك).
**لم يتغيّر إطلاقًا:** أي ترحيل من 0001–0050، أي كود واجهة (`queries.ts`/بطاقات العرض) — رُوجِعَت فعليًا وتأكَّد أنها صحيحة بنيويًا الآن بفضل قيد "نسخة مستقبلية واحدة" الجديد، بلا حاجة لأي تعديل.

**خلاصة الملحق التاسع:** أربعة بنود دقيقة أُغلقت جميعًا على مستوى القاعدة، بأربع ترحيلات جديدة فقط بعد 0050، بلا لمس Foundation أو Phase 2 أو Patch 2.1 القائمين، وبلا بدء Sales/Returns/أي مرحلة جديدة. **الأهم في هذا الملحق تحديدًا:** حدود نقل القيم العشرية — البند الأكثر أهمية ماليًا في كل Patch 2.x — أصبحت الآن **مُثبَتة فعليًا عبر HTTP/PostgREST حقيقي**، لا مجرد مُدَّعاة أو محاكاة بـ`JSON.parse` يدوي، وتصحيح الفهم الخاطئ السابق حول سلوك `supabase gen types typescript` طُبِّق في كل مكان ادّعاه (الكود والتعليقات والاختبارات معًا)، لا في التوثيق فقط. **لم تبدأ Sales ولن تبدأ تلقائيًا — العمل متوقف الآن بانتظار مراجعة المستخدم وموافقته الصريحة.**

---

## الملحق العاشر — "Final Integrity Hotfix 2.2.1": إغلاق ثغرة على مستوى الجدول + ثبات الهوية + تاريخ عمل مركزي (ترحيلات 0055–0056)

بعد تسليم الملحق التاسع، ورد تصحيح مهم: **الـZIP المُسلَّم فعليًا كان لا يزال نسخة Patch 2.2 (آخر ترحيلة فيه 0054)**، بينما المطلوب كان تنفيذ ثلاثة بنود إضافية محدَّدة كترحيلات جديدة تبدأ بعد 0054. هذا الملحق يوثّق التنفيذ الفعلي لتلك البنود الثلاثة، بترحيلتين جديدتين (0055–0056)، مع تصحيح الـZIP المُرسَل ليحتوي فعليًا على أحدث ترحيلة (0056). الشرط كالمعتاد: لا تعديل على أي ترحيل من 0001–0054، كل إصلاح جديد يبدأ من 0055 فصاعدًا، لا بدء لِـSales.

### 1) الترحيلات الجديدة (0055–0056)

| # | الترحيلة | تُغلق |
|---|---|---|
| 0055 | `daily_gold_prices_table_level_integrity.sql` | **بند 1:** Trigger `daily_gold_prices_enforce_karat_active` (`BEFORE INSERT`) يرفض أي سجل سعر **جديد** لعيار غير نشط على مستوى الجدول نفسه، بلا استثناء لأي سياق (لا حتى `service_role`) — لا يعتمد على المرور عبر RPC إطلاقًا. **بند 2:** Trigger `daily_gold_prices_enforce_identity_immutable` (`BEFORE UPDATE`) يمنع تعديل `price_date`/`karat_id` لسجل موجود، بلا استثناء لأي سياق أيضًا. |
| 0056 | `business_date_for_fee_versioning.sql` | **بند 3:** دالة مركزية جديدة `public.business_today()` (مبنية على `(now() at time zone 'Asia/Riyadh')::date`)، وإعادة تعريف الدوال الست الخاصة بـVersioning المصنعية والعمولات (`create_manufacturing_fee_version`/`create_payment_method_fee_version`/`cancel_manufacturing_fee_version`/`cancel_payment_method_fee_version`/`manufacturing_fee_for_karat_on_date`/`payment_fee_for_method_on_date`) لتستخدمها بدل `current_date` المدمجة في Postgres. |

### 2) البنود الثلاثة — كيف أُغلق كل واحد

**1) منع سعر جديد لعيار غير نشط على مستوى الجدول نفسه.** 0054 (Patch 2.2) كانت قد أضافت هذا المنع **داخل** `save_daily_gold_price()`/`save_daily_gold_prices_bulk()` فقط — لكن `daily_gold_prices` نفسها ظلت تسمح بـ`INSERT` مباشر عبر RLS (منذ 0041) لأي حامل `gold_prices.edit`، فكان بالإمكان تجاوز الدالتين كليًا عبر PostgREST مباشرة وإدراج سعر جديد لعيار مُعطَّل. أُضيف الآن Trigger `BEFORE INSERT` على الجدول نفسه (`enforce_daily_gold_price_karat_active()`، `SECURITY DEFINER`) يرفض أي سجل جديد لعيار `status <> 'active'` — بلا استثناء حتى لِـ`service_role`، على نفس نمط 0047 (لا نسخة رسوم جديدة لعيار/طريقة دفع غير نشطة، بلا استثناء لأي سياق). **ثغرة تصحيح ذاتي حرجة اكتُشِفت أثناء بناء هذه الترحيلة نفسها (لا تقرير من المستخدم):** Postgres يُطلِق Trigger `BEFORE INSERT` على السطر المرشَّح لعبارة `INSERT ... ON CONFLICT DO UPDATE` **حتى لو انتهى الأمر بتعديل (UPDATE) فعليًا بسبب التعارض** — أي أن `save_daily_gold_price()`'s الخاص بها (upsert عبر `ON CONFLICT`) كان سيُرفَض خطأً عند تصحيح سعر **موجود مسبقًا** لعيار عُطِّل لاحقًا، رغم أن ذلك تصحيح شرعي يجب أن يبقى مسموحًا (نفس مبدأ 0054 نفسه). أُصلح بجعل الـTrigger يتحقق من وجود سجل بنفس `(price_date, karat_id)` فعليًا (بدل الاعتماد فقط على أن هذا `INSERT`) — إن وُجد سجل، لا حظر (تصحيح شرعي)؛ إن لم يوجد، يُحظَر لعيار غير نشط (سجل جديد فعليًا). أُثبِت الإصلاح باختبار مخصَّص (§1.5 أدناه) يُعيد إنتاج السيناريو بالضبط.

**2) ثبات `price_date`/`karat_id` بعد الإنشاء.** لم يكن هناك أي مانع من `UPDATE` مباشر (مسموح عبر RLS لأي حامل `gold_prices.edit`، نفس المسار الذي أغلقه 0051 لأعمدة إسناد المصدر فقط) يُعيد توجيه سجل سعر موجود إلى تاريخ/عيار مختلف تمامًا، فيُفسِد السجل التاريخي في مكانه. أُضيف Trigger `BEFORE UPDATE` (`enforce_daily_gold_price_identity_immutable()`) يرفض أي تعديل على `price_date`/`karat_id` معًا، بلا استثناء لأي سياق — يطابق تمامًا نمط `enforce_manufacturing_fee_version_immutable()` من 0047. لا يمسّ إطلاقًا مسار `ON CONFLICT DO UPDATE` الشرعي في الدالتين (لا يُعدِّلان هذين العمودين أصلًا)، ولا أي تعديل شرعي لبقية الأعمدة (السعر/الملاحظات) — مُثبَت اختباريًا.

**3) تاريخ عمل مركزي (Business Date) مبني على Asia/Riyadh.** كل مقارنات التاريخ في منطق Versioning للمصنعية والعمولات (فحص "هل الإصدار المفتوح نفسه لم يسرِ بعد" من 0053، فحص "هل هذا الإصدار سارٍ بالفعل" في الإلغاء من 0047، والقيمة الافتراضية لِـ`p_date` في دالتَي الاستعلام من 0042/0045) كانت تستخدم `current_date` المدمجة في Postgres، التي تُحسَب بحسب **إعداد الخادم/الجلسة للـtimezone** (UTC على خوادم هذا المشروع، وعلى Supabase الحقيقي أيضًا) — **وليس** توقيت عمل هذا المشروع الفعلي (آسيا/الرياض، UTC+3، بلا توقيت صيفي، تمامًا كإعداد `APP_TIMEZONE` في `src/lib/date.ts` على مستوى الواجهة). خلال نافذة تقارب 3 ساعات يوميًا (21:00–23:59 بتوقيت UTC، حيث يكون تاريخ الرياض قد تقدَّم يومًا كاملًا بينما لا يزال تاريخ UTC على اليوم السابق)، كان `current_date` يُجيب على السؤال **الخطأ** لقرار عمل جوهره "ما هو اليوم في الرياض؟". أُضيفت دالة مركزية `public.business_today()` (`(now() at time zone 'Asia/Riyadh')::date`، `STABLE`)، وأُعيد تعريف الدوال الست المذكورة أعلاه لتستخدمها بدل `current_date` — **السلوك الوحيد الذي تغيَّر هو مصدر التاريخ نفسه؛ منطق كل دالة الآخر لم يتغيّر حرفًا واحدًا.**

**نطاق مقصود وصريح:** هذا الإصلاح يشمل **فقط** الدوال الست الخاصة بـVersioning المصنعية/العمولات المذكورة في الطلب — لم يمسّ دوال أسعار الذهب (`gold_price_for_karat_on_date()`، `gold_prices_missing_for_date()`) التي لا تزال تستخدم `current_date` كقيمة افتراضية، لأنها لم تُذكَر في نطاق هذا الطلب تحديدًا. لو أُريد نفس الإصلاح هناك أيضًا، فهذا طلب منفصل صريح — `business_today()` مكتوبة بصورة عامة (بلا أي اعتمادية خاصة بـVersioning) بحيث يكون تطبيقها هناك لاحقًا تعديلًا ميكانيكيًا صغيرًا، لا إعادة تصميم.

### 3) الاختبارات — قائمة كاملة وأرقام فعلية

**ملف اختبار جديد بالكامل:** `supabase/tests/financial_integrity_hotfix_2_2_1.test.sql` — **14 تأكيد "OK"**، ينتهي بـ`=== ALL FINANCIAL INTEGRITY HOTFIX 2.2.1 TESTS PASSED (migrations 0055-0056) ===`. يغطي:
- **§1 (5 اختبارات):** رفض INSERT مباشر (بلا RPC) لسعر جديد لعيار غير نشط على مستوى الـTrigger نفسه؛ قبول نفس الشكل لعيار نشط (لا حظر زائد)؛ رفض نفس المحاولة من `service_role` أيضًا (لا استثناء)؛ نجاح تصحيح سعر **موجود مسبقًا** لعيار عُطِّل لاحقًا عبر `UPDATE` مباشر؛ ونجاح نفس التصحيح عبر `save_daily_gold_price()`'s `ON CONFLICT DO UPDATE` تحديدًا (اختبار الانحدار الذي أثبت الثغرة المكتشَفة أثناء البناء وتصحيحها).
- **§2 (4 اختبارات):** رفض تعديل `price_date`؛ رفض تعديل `karat_id`؛ نجاح تعديل عمود غير هوياتي (السعر/الملاحظات)؛ رفض نفس محاولة تعديل `karat_id` من `service_role` أيضًا (لا استثناء).
- **§3 (3 اختبارات، أكثرها دقة وصرامة):** إثبات تعريفي أن `business_today()` تطابق `(now() at time zone 'Asia/Riyadh')::date` بدقة **ومستقلة تمامًا** عن إعداد `timezone` الخاص بجلسة الاتصال (اختُبِر بتغيير الجلسة إلى `UTC` ثم إلى `Pacific/Kiritimati`، UTC+14 — القيمة لم تتغيّر إطلاقًا، خلافًا لِـ`current_date` المدمجة)؛ **إثبات وظيفي حاسم لربط الدوال فعليًا بـ`business_today()` في وقت التشغيل** (لا مجرد قراءة كود ثابتة) — عبر استبدال مؤقت (داخل نفس معاملة `begin...rollback`، يُلغى تلقائيًا عند الإنهاء) لِـ`business_today()` بقيمة وهمية بعيدة تمامًا عن `current_date` الحقيقي (`2099-06-15`)، ثم إثبات أن `create_manufacturing_fee_version()`'s سلوك "رفض إصدار مستقبلي ثانٍ" يتبع القيمة الوهمية بالضبط لا `current_date` الحقيقي (لو كانت الدالة لا تزال تستخدم `current_date`، لكانت النتيجة مختلفة كليًا لأن `2099-06-15 + 2` يقع في الماضي البعيد وفق التاريخ الحقيقي)؛ وفحص فحص المصدر (`pg_get_functiondef`) على الدوال الست كلها للتأكد من أن تعريفها الفعلي يستدعي `business_today` ولا يحتوي `current_date` إطلاقًا.

**الملفات الأربعة الأخرى (لم تُحذَف، لم تحتَج تعديلًا منطقيًا):** `rls_and_permissions.test.sql` → **139/139**، `financial_master_data.test.sql` → **52/52**، `financial_integrity_patch_2_1.test.sql` → **34/34**، `financial_integrity_patch_2_2.test.sql` → **17/17** — كلها أُعيد تشغيلها ضد قاعدة تحتوي 0055–0056 أيضًا، لإثبات أن الترحيلتين الجديدتين لم تكسرا أي شيء قائم.

**اختبار HTTP/PostgREST الحقيقي (`scripts/run_postgrest_http_test.sh`، من الملحق التاسع):** أُعيد تشغيله كاملًا ضد قاعدة تحتوي 0055–0056 أيضًا → **نجح، 15/15 تأكيد** — يثبت أن هذا الهوتفكس لم يمسّ حدود نقل القيم العشرية بأي شكل.

### 4) الفحص النهائي الكامل — نتائج فعلية

- إعادة بناء قاعدة اختبار Postgres محلية **من الصفر بالكامل**: حذف `gold_erp_test`، إعادة إنشائها، `local_harness_setup.sql`، **كل الترحيلات 0001–0056 بالترتيب دون توقف** (56/56 نجحت)، ثم `supabase/seed.sql` (نجح).
- `supabase/tests/rls_and_permissions.test.sql` → **نجح، 139/139 تأكيد**.
- `supabase/tests/financial_master_data.test.sql` → **نجح، 52/52 تأكيد**.
- `supabase/tests/financial_integrity_patch_2_1.test.sql` → **نجح، 34/34 تأكيد**.
- `supabase/tests/financial_integrity_patch_2_2.test.sql` → **نجح، 17/17 تأكيد**.
- `supabase/tests/financial_integrity_hotfix_2_2_1.test.sql` (جديد) → **نجح، 14/14 تأكيد**.
- اختبار الترقية (`scripts/run_upgrade_test.sh` + `upgrade_from_0039.test.sql`، يُطبِّق 0040–**0056** تلقائيًا عبر glob بلا تعديل على السكربت نفسه) → **نجح، 10/10 تأكيد**.
- اختبار HTTP/PostgREST الحقيقي (`scripts/run_postgrest_http_test.sh`) → **نجح، 15/15 تأكيد**، ضد ثنائي PostgREST v12.2.3 حقيقي عبر HTTP فعلي، بعد تطبيق 0055–0056.
- `npx tsc --noEmit` → **صفر أخطاء** (لا تغيير في أي ملف TypeScript في هذا الهوتفكس).
- `npx eslint` → **صفر أخطاء وتحذيرات**.
- `npx vitest run` → **45/45 ناجح عبر 5 ملفات** (بلا تغيير — هذا الهوتفكس قاعدة بيانات بحتة).
- `npm run check:numeric-types` → **نجح، 5/5 عمود NUMERIC مطابق**.
- `npm run build` (Next.js/Turbopack) → **نجح**، 24 مسارًا مُولَّدًا (بلا تغيير في العدد).

### 5) الملفات/الترحيلات التي تغيَّرت أو أُضيفت في Hotfix 2.2.1 (قائمة كاملة)

**ترحيلات جديدة (2):** `0055_daily_gold_prices_table_level_integrity.sql`، `0056_business_date_for_fee_versioning.sql`.
**اختبار SQL جديد بالكامل:** `supabase/tests/financial_integrity_hotfix_2_2_1.test.sql`.
**لم يتغيّر إطلاقًا:** أي ترحيل من 0001–0054، أي ملف TypeScript/React تطبيقي (هذا الهوتفكس قاعدة بيانات بحتة بالكامل — لا تغيير في `src/` إطلاقًا)، وأي اختبار SQL قائم آخر.

**خلاصة الملحق العاشر:** ثلاثة بنود دقيقة أُغلقت جميعًا على مستوى القاعدة، بترحيلتين جديدتين فقط بعد 0054، بلا لمس أي شيء قائم، وبلا بدء Sales. **الأهم في هذا الملحق تحديدًا:** ثغرة "الإصلاح داخل RPC فقط، لا على مستوى الجدول" أُغلقت فعليًا هذه المرة على مستوى الجدول نفسه (Trigger)، بلا استثناء لأي سياق بما فيه `service_role`؛ واكتُشِفت وأُصلحت أثناء البناء نفسه ثغرة انحدار حقيقية وخطيرة كانت ستُفسِد مسار التصحيح الشرعي (سلوك Postgres غير البديهي لِـTrigger `BEFORE INSERT` مع `ON CONFLICT DO UPDATE`) — لم تكن لتُكتشَف بدون اختبار مخصَّص يُعيد إنتاج المسار الفعلي (upsert) بدل `INSERT` خام فقط. **لم تبدأ Sales ولن تبدأ تلقائيًا — العمل متوقف الآن بانتظار مراجعة المستخدم وموافقته الصريحة.**

---

## الملحق الحادي عشر — "Final Date Consistency Hotfix 2.2.2": توحيد Business Date عبر Finance-safe RPCs ودوال سعر الذهب (ترحيلة 0057)

بعد تسليم الملحق العاشر (Hotfix 2.2.1)، ورد تصحيح دقيق ونهائي واحد: 0056 وحَّدت `current_date` إلى `public.business_today()` (آسيا/الرياض) في دوال Versioning الست الخاصة بالمصنعية والعمولات — لكن الدوال الثلاث **Finance-safe** التي أضافها 0052، وهي **بالضبط** ما يُلزَم Sales المستقبلية باستخدامه لأي قيمة مالية، بقيت معرَّفة بـ`p_date date default current_date` دون تغيير. الشرط كالمعتاد: لا تعديل على أي ترحيل من 0001–0056، ترحيلة واحدة جديدة فقط بعد 0056 (0057)، لا تغيير على أي إصلاح قائم، لا بدء لِـSales.

### 1) الثغرة بدقة، ولماذا 0056 لم تكفِ

كل دالة `_safe` (0052) هي غلاف SQL رقيق يستدعي الدالة الأصلية **بتمرير `p_date` صراحةً**:

```sql
select public.manufacturing_fee_for_karat_on_date(p_karat_id, p_date)::text;
```

عندما يُستدعى الغلاف بلا `p_date`، تُحسَم قيمة `p_date` الافتراضية **الخاصة بالغلاف نفسه** (`current_date` القديمة) **قبل** الدخول إلى جسم الدالة أصلًا، وتلك القيمة المحسومة سلفًا هي ما يُمرَّر صراحةً إلى الدالة الأصلية — وقيمة مُمرَّرة صراحةً تتجاوز `default` المُستدعاة دائمًا، مهما كان ذلك الـdefault (`business_today()` من 0056 هنا). بعبارة أخرى: إصلاح 0056 لا يعمل إطلاقًا لأي استدعاء `_safe` يُغفِل `p_date` — وهو بالضبط الشكل الذي يجب أن تستخدمه Sales. هذه ليست مشكلة نظرية: خلال نافذة ~3 ساعات يوميًا (21:00–23:59 بتوقيت UTC، حيث يكون تاريخ الرياض قد دخل اليوم التالي فعليًا بينما خادم Postgres — بتوقيت UTC — لا يزال على اليوم السابق)، كان استدعاء `gold_price_for_karat_on_date_safe(p_karat_id)` بلا `p_date` سيحسم "اليوم" على التاريخ **الخطأ**.

دالتا أسعار الذهب الأصليتان (`gold_price_for_karat_on_date()`/`gold_prices_missing_for_date()`، 0041) كانتا خارج نطاق 0056 (المحصور صراحةً بـVersioning المصنعية/العمولات وقتها بناءً على طلب سابق صريح) — لكنهما داخل نطاق هذا الطلب تحديدًا.

### 2) الترحيلة الجديدة (0057)

| # | الترحيلة | تُغلق |
|---|---|---|
| 0057 | `business_date_for_safe_and_gold_price_reads.sql` | إعادة تعريف الدوال الخمس التالية بتغيير **قيمة `p_date` الافتراضية فقط** من `current_date` إلى `public.business_today()`: `gold_price_for_karat_on_date_safe()`، `manufacturing_fee_for_karat_on_date_safe()`، `payment_fee_for_method_on_date_safe()` (البند 1)، و`gold_price_for_karat_on_date()`، `gold_prices_missing_for_date()` (البند 2). |

**لا شيء آخر تغيَّر:** منطق الحل نفسه، أنواع الإرجاع (`text` للثلاث `_safe`، `numeric`/`setof karats` للأخريين)، حد `::text`، RLS، Versioning، 0055، 0056 — كل ذلك بقي كما هو حرفيًا. تواقيع TypeScript في `src/types/database.ts` لم تتغيّر (شكل المُعامِل — الاسم والنوع والاختيارية — مطابق تمامًا؛ ما تغيَّر هو القيمة التي يحصل عليها الطرف المُستدعي عند إغفال `p_date` على مستوى الخادم فقط)، ولذلك **لم يُعدَّل `database.ts` إطلاقًا** في هذا الهوتفكس. تمرير `p_date` صراحةً — كما تفعل كل نقاط الاستدعاء الحالية في المشروع — لا يتأثر إطلاقًا بهذا التغيير.

### 3) الاختبارات — قائمة كاملة وأرقام فعلية

**ملف اختبار جديد بالكامل:** `supabase/tests/financial_integrity_hotfix_2_2_2.test.sql` — **11 تأكيد "OK"**، ينتهي بـ`=== ALL FINANCIAL INTEGRITY HOTFIX 2.2.2 TESTS PASSED (migration 0057) ===`. يغطي:

- **§1 (5 اختبارات، الأهم):** استبدال `business_today()` مؤقتًا (داخل نفس معاملة `begin...rollback`، يُلغى تلقائيًا) بتاريخ وهمي (`sentinel = 2099-06-15`) بعيد كليًا عن `current_date` الحقيقي، مع بيانات مُجهَّزة خصيصًا بحيث تُعطي القيمة **الصحيحة** (مرتبطة بـsentinel) والقيمة **الخطأ** (مرتبطة بـ`current_date` الحقيقي) قيمتين مختلفتين تمامًا وقابلتين للتمييز — لا مجرد نجاح/فشل الاستدعاء:
  - `gold_price_for_karat_on_date_safe()` بلا `p_date` → يجب أن يُرجِع سعر sentinel (222.2222)، لا سعر اليوم الحقيقي (111.1111).
  - `manufacturing_fee_for_karat_on_date_safe()` بلا `p_date` → يجب أن يُرجِع رسم إصدار B عند sentinel (9.0000)، لا إصدار A الذي يغطي اليوم الحقيقي (5.0000) — عبر إصدارَي مصنعية متجاورين زمنيًا (`effective_to` لِـA = `sentinel - 1`، `effective_from` لِـB = `sentinel`).
  - `payment_fee_for_method_on_date_safe()` بلا `p_date` → نفس المبدأ (7.000% مقابل 3.000%).
  - `gold_price_for_karat_on_date()` (الأصلية) بلا `p_date` → نفس اختبار السعر (222.2222).
  - `gold_prices_missing_for_date()` بلا `p_date` → عيار له سعر عند sentinel فقط يجب ألا يظهر كـ"مفقود"؛ عيار بلا أي سعر إطلاقًا يبقى يظهر كـ"مفقود" (ضابط سلامة يثبت أن الدالة لا تزال تعمل صحيحًا، لا مجرد فارغة دائمًا).
- **§2 (اختبار واحد):** استقلالية عن `timezone` جلسة الاتصال — `gold_price_for_karat_on_date_safe()` بلا `p_date` يُرجِع **نفس القيمة الصحيحة بالضبط** تحت `UTC` ثم تحت `Pacific/Kiritimati` (UTC+14، إعداد متطرف) — مبني على سعر مُؤرَّخ بـ`public.business_today()` الحقيقي (غير المُستبدَل) تحديدًا، لا `current_date`، حتى يبقى الاختبار حتميًا في أي ساعة يعمل بها بغض النظر عن تطابق `current_date`/`business_today()` وقتها من عدمه.
- **§3 (اختبار واحد):** فحص المصدر (`pg_get_functiondef`) على الدوال الخمس المستهدَفة كلها — يتأكد أن تعريفها الفعلي يستدعي `business_today` ولا يحتوي `current_date` إطلاقًا.
- **§4 (اختبار واحد):** ضبط سلامة — تمرير `p_date` صراحةً (`current_date` الحقيقي) لا يزال يعمل ويُرجِع القيمة المتوقَّعة (111.1111) تمامًا كما كان، مثبتًا أن هذا الهوتفكس غيَّر الـ`default` فقط ولم يمسّ أي سلوك آخر.

**الملفات الخمسة الأخرى (لم تُحذَف، لم تحتَج تعديلًا منطقيًا):** `rls_and_permissions.test.sql` → **139/139**، `financial_master_data.test.sql` → **52/52**، `financial_integrity_patch_2_1.test.sql` → **34/34**، `financial_integrity_patch_2_2.test.sql` → **17/17**، `financial_integrity_hotfix_2_2_1.test.sql` → **14/14** — كلها أُعيد تشغيلها ضد قاعدة تحتوي 0057 أيضًا، لإثبات أن الترحيلة الجديدة لم تكسر أي شيء قائم.

**اختبار HTTP/PostgREST الحقيقي (`scripts/run_postgrest_http_test.sh`):** أُعيد تشغيله كاملًا ضد قاعدة تحتوي 0057 أيضًا → **نجح، 15/15 تأكيد** — يثبت أن هذا الهوتفكس (الذي لا يمسّ حد `::text` أو أنواع الإرجاع إطلاقًا) لم يكسر شيئًا في حدود نقل القيم العشرية.

### 4) الفحص النهائي الكامل — نتائج فعلية

- إعادة بناء قاعدة اختبار Postgres محلية **من الصفر بالكامل**: حذف `gold_erp_test`، إعادة إنشائها، `local_harness_setup.sql`، **كل الترحيلات 0001–0057 بالترتيب دون توقف** (57/57 نجحت)، ثم `supabase/seed.sql` (نجح).
- `supabase/tests/rls_and_permissions.test.sql` → **نجح، 139/139 تأكيد**.
- `supabase/tests/financial_master_data.test.sql` → **نجح، 52/52 تأكيد**.
- `supabase/tests/financial_integrity_patch_2_1.test.sql` → **نجح، 34/34 تأكيد**.
- `supabase/tests/financial_integrity_patch_2_2.test.sql` → **نجح، 17/17 تأكيد**.
- `supabase/tests/financial_integrity_hotfix_2_2_1.test.sql` → **نجح، 14/14 تأكيد**.
- `supabase/tests/financial_integrity_hotfix_2_2_2.test.sql` (جديد) → **نجح، 11/11 تأكيد**.
- اختبار الترقية (`scripts/run_upgrade_test.sh` + `upgrade_from_0039.test.sql`، يُطبِّق 0040–**0057** تلقائيًا عبر glob بلا تعديل على السكربت نفسه) → **نجح، 10/10 تأكيد**.
- اختبار HTTP/PostgREST الحقيقي (`scripts/run_postgrest_http_test.sh`) → **نجح، 15/15 تأكيد**، ضد ثنائي PostgREST v12.2.3 حقيقي عبر HTTP فعلي، بعد تطبيق 0057.
- `npx tsc --noEmit` → **صفر أخطاء** (لا تغيير في أي ملف TypeScript في هذا الهوتفكس).
- `npx eslint` → **صفر أخطاء وتحذيرات**.
- `npx vitest run` → **45/45 ناجح عبر 5 ملفات** (بلا تغيير — هذا الهوتفكس قاعدة بيانات بحتة).
- `npm run check:numeric-types` → **نجح، 5/5 عمود NUMERIC مطابق**.
- `npm run build` (Next.js/Turbopack) → **نجح**، 24 مسارًا مُولَّدًا (بلا تغيير في العدد).

### 5) الملفات/الترحيلات التي تغيَّرت أو أُضيفت في Hotfix 2.2.2 (قائمة كاملة)

**ترحيلة جديدة (1):** `0057_business_date_for_safe_and_gold_price_reads.sql`.
**اختبار SQL جديد بالكامل:** `supabase/tests/financial_integrity_hotfix_2_2_2.test.sql`.
**لم يتغيّر إطلاقًا:** أي ترحيل من 0001–0056، أي ملف TypeScript/React تطبيقي (بما فيها `src/types/database.ts` — التوقيعات لم تتغيّر)، وأي اختبار SQL قائم آخر.

**خلاصة الملحق الحادي عشر:** بند واحد دقيق ونهائي أُغلق على مستوى القاعدة، بترحيلة واحدة جديدة فقط بعد 0056، بلا لمس أي شيء قائم، وبلا بدء Sales. **الأهم في هذا الملحق تحديدًا:** كل دالة قراءة مالية في المشروع (المصنعية، العمولات، سعر الذهب — الأصلية والـFinance-safe معًا) أصبحت الآن تحسم "اليوم" بصورة موحَّدة عبر `public.business_today()` (آسيا/الرياض) حصرًا، وأُثبِت ذلك بدقة عبر تقنية استبدال مؤقت لِـ`business_today()` بقيمة وهمية بعيدة كل البعد عن `current_date` الحقيقي — إثبات وظيفي حقيقي أن الدوال تستدعي `business_today()` فعليًا في وقت التشغيل، لا مجرد فحص كود ثابت. Phase 2 المالية أصبحت الآن متسقة زمنيًا بالكامل عبر كل نقاط "اليوم" الافتراضية قبل اعتمادها نهائيًا. **لم تبدأ Sales ولن تبدأ تلقائيًا — العمل متوقف الآن بانتظار مراجعة المستخدم وموافقته الصريحة.**

---

## الملحق الثاني عشر — "Phase 3: نواة المبيعات (Sales Core)" (ترحيلات 0058–0064)

هذا الملحق يوثِّق **Phase 3** كاملة، بناءً على مواصفة المستخدم الصريحة المكوَّنة من 37 بندًا: **"هذه المرحلة Sales Core فقط، مع Daily Close الضروري لحماية المبيعات"**، مع استثناءات صريحة يُمنَع البدء بها الآن — المرتجعات (Returns)، الشحن، التسويات، المخزون، الخدمات/التعديلات، تقارير PDF/Excel، أي تكامل خارجي (سلة/تابي/تمارا/API الذهب الخارجي)، أي نسخ احتياطي تلقائي جديد، وCRM العملاء. الشرط الصارم كالمعتاد: **لا تعديل على أي ترحيل من 0001 إلى 0057** — كل ترحيل جديد بدأ من 0058 فصاعدًا (سبع ترحيلات: 0058–0064). العمل **متوقف الآن**، بانتظار مراجعة المستخدم وموافقته الصريحة قبل إرسال ZIP التالي — لم تبدأ المرتجعات ولا أي مرحلة تالية.

### 1) الترحيلات الجديدة (0058–0064)

| # | الترحيلة | تُضيف |
|---|---|---|
| 0058 | `vat_rate_versioning.sql` | جدول `vat_rate_versions` (نمط Versioning مطابق لِـ`manufacturing_fee_versions`/`payment_method_fee_versions`، بلا أي سياسة RLS للكتابة المباشرة إطلاقًا)، `create_vat_rate_version()`/`cancel_vat_rate_version()`، `vat_rate_for_date()`/`vat_rate_for_date_safe()` (Finance-safe)، صلاحيتا `vat_rates.view`/`vat_rates.manage`، وصف أساسي 15% نافذ من تاريخ نشر هذه الترحيلة. |
| 0059 | `sales_core_schema.sql` | `sales_order_number_seq` + `generate_sales_order_number()` (SEQUENCE ذرّي، غير قابل لِـMAX+1)؛ جداول `sales_orders`/`sales_order_items` بصفر سياسات RLS للمستخدم `authenticated` (لا قراءة ولا كتابة مباشرة إطلاقًا)؛ جدول `daily_closings` بسياسة SELECT مباشرة فقط (لا بيانات ربحية فيه). |
| 0060 | `sales_close_day_permission.sql` | صلاحية `sales.close_day` (الوحيدة من صلاحيات Sales الست التي لم تكن موجودة مسبقًا من Foundation). |
| 0061 | `create_sales_order.sql` | ثلاث دوال حَل إضافية (`gold_price_version_for_karat_on_date`، `manufacturing_fee_version_for_karat_on_date`، `vat_rate_version_for_date`) تُرجِع id المصدر مع القيمة معًا؛ `create_sales_order()` — نقطة الدخول المعاملاتية الوحيدة لإنشاء عملية بيع. |
| 0062 | `sales_read_and_preview.sql` | `list_sales_orders()`، `get_sales_order()`، `preview_sales_order()` — كلها SECURITY DEFINER بحماية ربح على مستوى القاعدة. |
| 0063 | `update_sales_order.sql` | `update_sales_order()` — استبدال كامل للبنود (DELETE+INSERT) داخل نفس المعاملة، بلا معامل لِـ`store_id`/`sale_date` (غير قابلين للتعديل إطلاقًا بتصميم التوقيع نفسه). |
| 0064 | `close_sales_day.sql` | `close_sales_day()` — إغلاق يوم مبيعات لمتجر؛ رفض الإغلاق المكرر بدل تجاهله بصمت؛ لا Reopen ولا حذف في هذه المرحلة. |

**ملاحظة:** لا توجد ترحيلة "0065" — التدقيق (Audit) لعمليات Sales نُفِّذ بالكامل عبر استدعاءات صريحة لِـ`log_audit_event()` داخل كل دالة RPC نفسها (0061/0063/0064)، وليس عبر Trigger عام جديد؛ انظر القرار المعماري رقم 2 أدناه لتبرير ذلك.

### 2) الجداول الجديدة (4) ونموذج الوصول الحاسم

`vat_rate_versions`، `sales_orders`، `sales_order_items`، `daily_closings`. القرار الأهم في هذه المرحلة بأكملها: **`sales_orders`/`sales_order_items` بصفر سياسات RLS لـ`authenticated`** — لا SELECT، لا INSERT/UPDATE/DELETE، إطلاقًا. هذا أشد صرامة من كل جدول حسّاس آخر في المشروع (التي تُبقي سياسة كتابة مباشرة للدفاع بالعمق). السبب: RLS على مستوى **الصف** لا **العمود**، وبند §15 من المواصفة يُلزِم أن تكون أعمدة الربح غير مرئية لمستخدم يملك `sales.view` فقط عبر **أي** مسار — بما فيه طلب PostgREST مُصاغ يدويًا — وهو أمر مستحيل التعبير عنه بسياسة صف واحدة تشمل الجدول بأكمله. كل وصول (قراءة أو كتابة) يمر حصرًا عبر دوال RPC موثوقة (`SECURITY DEFINER`) تقرر في منطق التطبيق نفسه ما إذا كانت الأعمدة الحسّاسة تُعرَض لهذا المستخدم أم لا. `daily_closings` استثناء وحيد: تحمل سياسة SELECT مباشرة لأنها لا تحوي بيانات ربحية إطلاقًا (متجر/تاريخ/من/متى/ملاحظة فقط).

### 3) الصفحات والمكوّنات الجديدة

`/sales` (قائمة مع فلاتر وأعمدة ربح مشروطة بالصلاحية)، `/sales/new` (إدخال سريع مع معاينة مُؤجَّلة Debounced)، `/sales/[id]` (تفاصيل)، `/sales/[id]/edit` (تعديل — المتجر وتاريخ البيع للعرض فقط). مكوّنات: `sales-entry-form.tsx` (النموذج الرئيسي، مُستخدَم للإنشاء والتعديل معًا)، `sales-filters.tsx`، `close-day-dialog.tsx`، `closed-day-reason-dialog.tsx`. طبقة الخلفية: `src/features/sales/{schema,queries,actions}.ts`.

### 4) الصلاحيات الجديدة (3، بالإضافة لست صلاحيات Sales كانت موجودة مسبقًا من Foundation دون استخدام)

`vat_rates.view`، `vat_rates.manage` (0058)، `sales.close_day` (0060). صلاحيات `sales.view`/`sales.create`/`sales.edit`/`sales.edit_closed_day`/`sales.view_profit` كانت مُعرَّفة مسبقًا في `seed.sql` دون أي RPC يستهلكها فعليًا — هذه المرحلة هي أول استهلاك حقيقي لها.

### 5) قرارات معمارية اتُّخذت ولم تُحدَّد صراحةً في المواصفة (مع التبرير)

1. **صفر سياسات RLS على `sales_orders`/`sales_order_items`** (تفصيل في القسم 2 أعلاه) — الحل الوحيد الذي يضمن إخفاء الربح عبر أي مسار مهما كان.
2. **تدقيق صريح داخل كل RPC بدل Trigger عام:** `audit_table_changes()` (0016/0024) عمدًا **لم** يُربَط بجداول Sales الثلاثة. ذلك الـTrigger موجود لالتقاط تعديلات تتجاوز التطبيق (طلب PostgREST خام، مسار كود مستقبلي منسي) — وهو خطر حقيقي على أي جدول آخر يُبقي سياسة كتابة مباشرة. Sales ليس له مسار تجاوز كهذا (لا سياسة كتابة مباشرة إطلاقًا)، فالتسجيل الصريح داخل كل RPC مقاوم للتلاعب تمامًا كما لو كان Trigger، وهو الطريقة الوحيدة لإنتاج تصنيف الأحداث العربي الدقيق الذي تطلبه المواصفة (`sale.create`/`sale.update`/`sale.closed_day_update`/`daily_closing.create`، بما في ذلك تمييز حالة اليوم المقفل وسببها الإلزامي) — وهو ما لا يستطيعه Trigger عام يعتمد `to_jsonb(old)`/`to_jsonb(new)` وحده. هذا يستجيب حرفيًا لتوجيه §20 الصريح من المستخدم: "تصميم ضيّق وآمن وموثَّق" بدل إعادة فتح Foundation Hardening.
3. **قاعدة التقريب:** كل سلسلة حساب (مكوّن الذهب ← Base Cost ← VAT Cost ← Total Cost ← Gross Profit) تُنفَّذ بدقة NUMERIC كاملة بلا تقريب وسيط؛ كل عمود من الأعمدة الستة النهائية في `sales_order_items` يُقرَّب لمنزلتين عشريتين **مستقلًا** من اشتقاقه الكامل الدقة الخاص به (لا بجمع أشقاء مُقرَّبة سلفًا). `gross_profit` على مستوى الطلب = مجموع `gross_profit` المُقرَّبة فعليًا لكل بند (لا إعادة اشتقاق من المجاميع الخام) — مطابقة حرفية لصيغة المواصفة.
4. **تدقيق مزدوج ليوم مقفل:** كل استدعاء لِـ`create_sales_order()`/`update_sales_order()` عبر تجاوز `sales.edit_closed_day` بسبب إلزامي يكتب حدثين معًا: `sale.create`/`sale.update` العادي + `sale.closed_day_update` منفصل يحمل السبب — يمنح أثرًا قابلًا للتصفية لكل تجاوز ليوم مقفل بصرف النظر عن كونه إنشاءً أو تعديلًا.
5. **رقم العملية:** SEQUENCE صرفة (`nextval`) — لا `MAX(order_number)+1` إطلاقًا (مطلب §5 صريح) — عام عبر كل المتاجر، وليس لكل متجر. الفجوات الناتجة عن معاملات مُتراجَع عنها متوقَّعة ومقبولة صراحةً (§28).

### 6) ثغرة اكتُشفت وأُصلِحت أثناء كتابة الاختبارات (قبل أي تسليم)

أثناء كتابة `supabase/tests/sales_core.test.sql`، تبيَّن أن سياسة `daily_closings_select` في 0059 كانت تستدعي `public.user_visible_store_ids(auth.uid())` مباشرة داخل `using (...)` — لكن تلك الدالة (التي تأخذ `uuid` كمعامل) ممنوحة لِـ`service_role` حصرًا منذ 0017 (`revoke ... from public; grant ... to service_role;`)، لا لِـ`authenticated`. أي طلب PostgREST حقيقي كمستخدم `authenticated` عادي كان سيفشل فورًا بخطأ `permission denied for function user_visible_store_ids` عند أول استعلام على `daily_closings` — وهو بالضبط ما أثبته اختبار SQL محلي محاكٍ لطلب حقيقي. كل سياسة RLS أخرى في المشروع تحتاج نطاق متجر تستخدم الغلاف الذاتي النطاق `my_visible_store_ids()`/`my_operable_store_ids()` (0017، الممنوحتين لـ`authenticated` تحديدًا لهذا الغرض، انظر مثلًا 0035) — لا النسخة الآخذة لـ`uuid`. **الإصلاح:** عُدِّلت 0059 مباشرة (لم تُسلَّم بعد لأي مستخدم، فهذا ليس ترحيلًا "مُطبَّقًا سابقًا" بمعنى القاعدة الصارمة 0001–0057) لتستخدم `my_visible_store_ids()` بدل الاستدعاء الخاطئ. أُعيد بناء قاعدة الاختبار من الصفر بعد الإصلاح، وأُعيدت كل الاختبارات (بما فيها الخمسة القائمة من المراحل السابقة) — لا تراجع.

### 7) تسميات التدقيق العربية الجديدة (`src/lib/audit/action-labels.ts`)

`vat_rate_version.create`، `vat_rate_version.update`، `sale.create`، `sale.update`، `sale.closed_day_update`، `daily_closing.create`.

### 8) الاختبارات — قائمة كاملة وأرقام فعلية

**ملف اختبار جديد بالكامل:** `supabase/tests/sales_core.test.sql` — **56 تأكيد "OK"**، ينتهي بـ`=== ALL Sales Core (Phase 3) integration tests passed ===`. يغطي ثمانية أقسام مطابقة لبنية §29–§32 من المواصفة:

- **§1 (7 اختبارات):** Versioning ضريبة القيمة المضافة — الإصدار الأساسي 15%، جدولة/إلغاء إصدار مستقبلي، ضابط "إصدار مستقبلي واحد كحد أقصى"، الرفض الصريح بدل افتراض قيمة لتاريخ بلا إصدار، رفض غير المخوَّل، وإثبات عدم وجود أي سياسة RLS للكتابة المباشرة إطلاقًا (حتى لمستخدم يملك `vat_rates.manage`).
- **§2 (10 اختبارات):** `create_sales_order()` — المثال المحلول الحرفي من §29 (Base=1550.00، VAT=232.50، Total=1782.50، ربح البند=217.50، الإجمالي=2000.00، ربح الطلب=217.50، عمولة الدفع=50.00، صافي الربح=167.50)؛ طلب متعدد البنود مع تحقق التجميع؛ تفرّد/تصاعد رقم العملية عبر SEQUENCE؛ حقول مطلوبة؛ نطاق متجر غير تشغيلي؛ متجر معطَّل؛ تاريخ مستقبلي؛ تصنيف/عيار غير نشط؛ **الذرّية** (بند بلا سعر ذهب مسجَّل يُسقط الطلب بأكمله، بما فيه البند الصالح الأول)؛ رفض غير المخوَّل؛ صحة حدث `sale.create` وعزوه للفاعل الصحيح؛ **تجاهل حقول ربح/تكلفة مزوَّرة يحقنها عميل خبيث داخل `p_items`**.
- **§3 (7 اختبارات):** `list_sales_orders()`/`get_sales_order()`/`preview_sales_order()` — إخفاء أعمدة الربح (NULL في القائمة، غياب المفتاح تمامًا في التفاصيل — لا يمكن تمييز "مخفي" عن "صفر")؛ `preview` لا يكتب أي شيء ويطابق حسابات `create` الفعلية؛ نطاق رؤية المتجر؛ **إثبات أن SELECT مباشرًا على `sales_orders`/`sales_order_items` يعيد صفرًا دائمًا لـ`authenticated`، حتى لمستخدم يملك كل صلاحيات المبيعات**.
- **§4 (4 اختبارات):** `update_sales_order()` — إعادة حساب Snapshots والإجماليات في يوم مفتوح (بما في ذلك ربح سالب/خسارة)؛ رفض غير المخوَّل؛ عملية غير موجودة/خارج النطاق؛ حدث `sale.update` بحالة كاملة قبل/بعد.
- **§5 (12 اختبارًا):** Daily Close — نجاح الإغلاق وحدث `daily_closing.create`؛ رفض الإغلاق المكرر؛ رفض تاريخ مستقبلي؛ رفض غير المخوَّل؛ رفض نطاق متجر غير تشغيلي؛ **تفاعل الإغلاق مع الإنشاء/التعديل**: رفض بلا `sales.edit_closed_day`، رفض بسبب فارغ رغم امتلاك الصلاحية، نجاح بسبب صريح مع حدثي تدقيق منفصلين (`sale.create`/`sale.update` + `sale.closed_day_update`) لكل من الإنشاء والتعديل.
- **§6 (4 اختبارات، أمنية):** رفض INSERT مباشر في `sales_orders` حتى لمدير مبيعات كامل الصلاحيات؛ سياسة SELECT المباشرة على `daily_closings` تُطبِّق نطاق رؤية المتجر بصحة؛ رؤية الربح مرتبطة بالصلاحية فقط لا بمن أنشأ العملية.
- **§7 (2 اختبار، ذرّية إضافية):** فشل `update_sales_order()` بسبب بند غير صالح وسط قائمة لا يترك العملية بلا بنود ولا بحالة جزئية — نمط DELETE+INSERT يتراجع بالكامل.

**الملفات الستة الأخرى (لم تُحذَف، لم تحتَج تعديلًا منطقيًا سوى تحديث Appendix اختبار الترقية):** `rls_and_permissions.test.sql` → **139/139**، `financial_master_data.test.sql` → **50/50**، `financial_integrity_patch_2_1.test.sql` → **30/30**، `financial_integrity_patch_2_2.test.sql` → **13/13**، `financial_integrity_hotfix_2_2_1.test.sql` → **14/14**، `financial_integrity_hotfix_2_2_2.test.sql` → **11/11** — كلها أُعيد تشغيلها ضد قاعدة تحتوي 0058–0064 أيضًا.

**ملف السموك المؤقت `_smoke_create_sales_order.sql`** (استُخدم أثناء تطوير 0061 فقط) **حُذِف** بعد أن استوعبه `sales_core.test.sql` بالكامل وتجاوزه.

**اختبار الترقية (`scripts/run_upgrade_test.sh` + `upgrade_from_0039.test.sql`):** يُطبِّق 0040–**0064** تلقائيًا عبر glob بلا تعديل على السكربت نفسه. وُسِّع الملف نفسه لإضافة تحقق صريح لصلاحيات Phase 3 (`vat_rates.view`/`vat_rates.manage` ضمن فئة `financial_master_data` الموجودة، و`sales.close_day` كصلاحية جديدة كليًا) — كُشِف عن اختلاف حقيقي (مجموعة الصلاحيات المتوقَّعة لكل دور كانت لا تزال تفترض 10 صلاحيات Phase 2 فقط دون Phase 3، ومجموعة `super_admin` الصريحة كانت لا تزال تفترض 10 بدل 12) وصُحِّح بتحديث التوقعات لتعكس المنح الجديدة الشرعية (ليس إخفاء فشل). → **نجح، 11/11 تأكيد**.

**اختبار HTTP/PostgREST الحقيقي (`scripts/run_postgrest_http_test.sh`):** وُسِّع بقسم "Part 3 — Phase 3 Sales Core" جديد — يُنشئ عملية بيع حقيقية عبر `create_sales_order()` عبر HTTP فعلي، ثم يُثبت أن `get_sales_order()`/`list_sales_orders()`/`preview_sales_order()` تُرجِع كل قيمة مالية كنص (`typeof === "string"`)، وأن حماية الربح تصمد عبر HTTP حقيقي (مفتاح Node.js JWT ثانٍ حقيقي، موقَّع لِـممثِّل اختبار ثانٍ حقيقي بلا `sales.view_profit`): `get_sales_order()` يحذف مفاتيح الربح تمامًا، `list_sales_orders()` يُعيدها `null`. → **نجح، 23/23 تأكيد** (15 من الأجزاء 1–2 القائمة + 8 جديدة لـSales).

### 9) الفحص النهائي الكامل — نتائج فعلية

- إعادة بناء قاعدة اختبار Postgres محلية **من الصفر بالكامل**: حذف `gold_erp_test`، إعادة إنشائها، `local_harness_setup.sql`، **كل الترحيلات 0001–0064 بالترتيب دون توقف** (64/64 نجحت)، ثم `supabase/seed.sql` (نجح).
- `supabase/tests/rls_and_permissions.test.sql` → **نجح، 139/139 تأكيد**.
- `supabase/tests/financial_master_data.test.sql` → **نجح، 50/50 تأكيد**.
- `supabase/tests/financial_integrity_patch_2_1.test.sql` → **نجح، 30/30 تأكيد**.
- `supabase/tests/financial_integrity_patch_2_2.test.sql` → **نجح، 13/13 تأكيد**.
- `supabase/tests/financial_integrity_hotfix_2_2_1.test.sql` → **نجح، 14/14 تأكيد**.
- `supabase/tests/financial_integrity_hotfix_2_2_2.test.sql` → **نجح، 11/11 تأكيد**.
- `supabase/tests/sales_core.test.sql` (جديد) → **نجح، 56/56 تأكيد**.
- اختبار الترقية (`scripts/run_upgrade_test.sh`، يُطبِّق 0040–0064 تلقائيًا) → **نجح، 11/11 تأكيد**.
- اختبار HTTP/PostgREST الحقيقي (`scripts/run_postgrest_http_test.sh`) → **نجح، 23/23 تأكيد**، ضد ثنائي PostgREST v12.2.3 حقيقي عبر HTTP فعلي.
- `npx tsc --noEmit` → **صفر أخطاء**.
- `npx eslint` → **صفر أخطاء وتحذيرات**.
- `npx vitest run` → **45/45 ناجح عبر 5 ملفات** (بلا تغيير — Phase 3 لم يمسّ منطق Decimal الحالي).
- `npm run check:numeric-types` → **نجح، 23/23 عمود NUMERIC مطابق** (يشمل 15 عمودًا جديدًا في `sales_orders`/`sales_order_items`/`vat_rate_versions`).
- `npm run build` (Next.js/Turbopack) → **نجح**، **26 مسارًا** مُولَّدًا (بزيادة 4 مسارات Sales: `/sales`، `/sales/new`، `/sales/[id]`، `/sales/[id]/edit`).

### 10) الملفات/الترحيلات التي تغيَّرت أو أُضيفت في Phase 3 (قائمة كاملة)

**ترحيلات جديدة (7):** `0058_vat_rate_versioning.sql`، `0059_sales_core_schema.sql`، `0060_sales_close_day_permission.sql`، `0061_create_sales_order.sql`، `0062_sales_read_and_preview.sql`، `0063_update_sales_order.sql`، `0064_close_sales_day.sql`.

**اختبار SQL جديد بالكامل:** `supabase/tests/sales_core.test.sql`.

**اختبار SQL مُعدَّل (توقعات فقط، لا منطق):** `supabase/tests/upgrade_from_0039.test.sql` (إضافة تحقق Phase 3).

**سكربتات HTTP مُعدَّلة:** `scripts/postgrest-http-test.mjs`، `scripts/run_postgrest_http_test.sh`، `supabase/tests/postgrest_http_test_setup.sql`.

**ملف حُذِف:** `supabase/tests/_smoke_create_sales_order.sql` (سموك مؤقت، استوعبه `sales_core.test.sql`).

**`supabase/seed.sql`:** إضافة صلاحيات/منح Phase 3 (`vat_rates.*` من 0058، `sales.close_day` من 0060) بنفس نمط 0049 الاصطلاحي (idempotent، إعادة التشغيل بعد تطبيق الترحيلات لا تُغيِّر شيئًا).

**كود TypeScript جديد بالكامل:** `src/features/sales/{schema,queries,actions}.ts`، `src/features/sales/components/{sales-entry-form,sales-filters,close-day-dialog,closed-day-reason-dialog}.tsx`، `src/app/(app)/sales/page.tsx`، `src/app/(app)/sales/new/page.tsx`، `src/app/(app)/sales/[id]/page.tsx`، `src/app/(app)/sales/[id]/edit/page.tsx`.

**كود TypeScript مُعدَّل:** `src/types/database.ts` (أنواع الجداول/الدوال الأربعة عشر الجديدة)، `src/lib/permissions/constants.ts` (3 مفاتيح صلاحيات جديدة)، `src/lib/audit/action-labels.ts` (6 تسميات عربية جديدة)، `src/lib/constants.ts` (`ROUTES.salesNew`)، `src/components/layout/nav-items.ts` (إزالة `comingSoon` عن رابط المبيعات).

**لم يتغيّر إطلاقًا:** أي ترحيل من 0001–0057، أي اختبار SQL آخر (منطقًا)، أي ملف TypeScript/React خارج ما ذُكِر أعلاه.

**خلاصة الملحق الثاني عشر:** نواة مبيعات كاملة وظيفيًا — رقم عملية عام فريد غير قابل للتزوير، بنود متعددة لكل عملية، Versioning ضريبة القيمة المضافة (بنية أساسية كانت ناقصة من Phase 2)، حساب مالي حصري داخل القاعدة بدقة NUMERIC كاملة، نقل نصّي آمن لكل قيمة مالية عبر RPC، حماية ربح على مستوى القاعدة تصمد أمام أي مسار تجاوز (بما فيه طلب PostgREST مُصاغ يدويًا، مُثبَت الآن عبر HTTP حقيقي)، نطاق متجر (تشغيلي مقابل رؤية تاريخية) مُطبَّق في كل RPC، Daily Close مع تجاوز إلزامي السبب لتعديل يوم مقفل، وتصنيف تدقيق عربي شامل. ثغرة واحدة حقيقية (سياسة RLS على `daily_closings` تستدعي دالة ممنوعة عن `authenticated`) اكتُشِفت أثناء كتابة الاختبارات وأُصلِحت قبل أي تسليم. **لم تبدأ المرتجعات (Returns) ولا أي مرحلة تالية تلقائيًا — العمل متوقف الآن، بانتظار مراجعة المستخدم وموافقته الصريحة بعد إرسال ZIP هذا الملحق.**

---

## الملحق الثالث عشر — "Sales Integrity Patch 3.1": إصلاحات بنيوية على نواة المبيعات (ترحيلات 0065–0072)

هذا الملحق يوثِّق **Patch 3.1**، حزمة إصلاحات بنيوية من 13 بندًا صدرت بعد مراجعة المستخدم لِـZIP الملحق الثاني عشر على مستوى الشيفرة المصدرية مباشرة. القيود الصارمة كما وردت حرفيًا من المستخدم وبقيت سارية طوال هذا الملحق: **"لا تبدأ Returns"**، **"لا تبدأ Shipping/Settlements/Inventory أو أي مرحلة جديدة"**، **"لا تعدل migrations من 0001 إلى 0064"**، **"كل الإصلاحات الجديدة تبدأ بعد 0064"** — وثماني ترحيلات جديدة فقط (0065–0072)، لا تعديل واحد على أي ترحيلة سابقة. الإغلاق كما ورد: **"لا تبدأ Returns حتى تتم المراجعة."** — لم تبدأ.

### 1) الترحيلات الجديدة (0065–0072)

| # | الترحيلة | تُضيف |
|---|---|---|
| 0065 | `sales_integrity_calc_lock_helpers.sql` | `compute_sales_item_costs()` — سلسلة التقريب المُصالِحة المشتركة (القسم 3 أدناه)؛ أربع دوال قفل استشاري: `acquire_financial_master_lock_shared/exclusive()`، `acquire_daily_close_lock_shared/exclusive(store_id, date)`. |
| 0066 | `financial_master_writers_exclusive_lock.sql` | `CREATE OR REPLACE` لخمس دوال كتابة بيانات مالية أساسية سابقة (`save_daily_gold_price`، `save_daily_gold_prices_bulk`، `create_manufacturing_fee_version`، `create_payment_method_fee_version`، `create_vat_rate_version`) — سطر واحد جديد فقط لكل دالة: قفل حصري قبل الكتابة. |
| 0067 | `sales_order_items_stable_identity.sql` | أعمدة `status`/`removed_at`/`removed_by` على `sales_order_items` + قيد CHECK للاتساق + فهرس. |
| 0068 | `create_sales_order_integrity.sql` | `CREATE OR REPLACE create_sales_order()` — قفل يوم مقفل (مشترك) + قفل مالي أساسي (مشترك) + استخدام `compute_sales_item_costs()` + `status='active'` صريح لكل بند. |
| 0069 | `update_sales_order_integrity.sql` | `CREATE OR REPLACE update_sales_order()` — أكبر إعادة كتابة في هذا الملحق: قفل صف الطلب (`FOR UPDATE`)، قفل يوم مقفل، قفل مالي أساسي، تحمُّل مرجع غير نشط تاريخيًا، إعادة حساب انتقائية حسب نوع التعديل، هوية بند ثابتة (تحديث لا حذف)، حذف ناعم لأي بند مُسقَط. |
| 0070 | `sales_read_rpcs_integrity.sql` | `list_sales_orders()` يكسب عمود `salesperson_name`؛ `get_sales_order()` يكسب نفس الحقل ويُصفِّي البنود لِـ`status='active'`؛ `list_sales_salespersons()` جديدة؛ `preview_sales_order()` يكسب معامل `p_collection_channel_id` ويطابق تحقق `create_sales_order()` تمامًا. |
| 0071 | `close_sales_day_exclusive_lock.sql` | `CREATE OR REPLACE close_sales_day()` — سطر واحد جديد: قفل يوم مقفل حصري قبل فحص "مُغلَق مسبقًا". |
| 0072 | `audit_logs_sales_profit_protection.sql` | إعادة كتابة سياسة `audit_logs_select`: صفوف `sale.%` تتطلب `audit_logs.view` **و** `sales.view_profit` معًا؛ كل الأحداث الأخرى (بما فيها `daily_closing.create`) تبقى بحاجة `audit_logs.view` فقط. |

### 2) البنود الثلاثة عشر — ماذا نُفِّذ ولماذا

1. **هوية بند ثابتة (0067/0069):** بدل حذف/إدراج البنود بالكامل عند كل تعديل (سلوك 0063 السابق)، `sales_order_items` تكسب `status`/`removed_at`/`removed_by`؛ `update_sales_order()` الجديدة تُميِّز بين بند **مرجعه `id` موجود ولم يتغيَّر ماليًا** (لا UPDATE إطلاقًا)، بند **مرجعه موجود وتغيَّرت بياناته الوصفية فقط** (UPDATE محدود لِـ`item_name`/`description`/`sku`)، بند **مرجعه موجود وتغيَّر ماليًا** (إعادة حل كاملة عبر `compute_sales_item_costs()`)، وبند **بلا `id`** (جديد بالكامل). أي بند نشط لم يُذكَر في القائمة المُرسَلة يُحوَّل إلى `status='removed'` بدل الحذف الفعلي — **لا حذف صلب لأي بيانات مالية تاريخية إطلاقًا**، حتى بعد تعديل يُسقِط بندًا.
2. **إعادة حساب انتقائية (0069):** المدخلات المالية لأي بند هي `category_id`/`karat_id`/`weight_grams`/`sale_price` فقط. عدم تغيُّر أيٍّ منها = صفر إعادة حل. تغيُّر طريقة الدفع وحدها يُعيد حل نسخة العمولة؛ عدم تغيُّرها يُبقي `payment_fee_version_id`/النسب المحفوظة كما هي **حرفيًا** — لكن `payment_fee_amount`/`net_sales_profit` تُعاد حسابهما دائمًا من مجموع البنود النشطة النهائي الفعلي (قرار مُوثَّق صراحة: "عدم إعادة حل النسخة" ≠ "تجميد المبلغ المُشتق حتى عند تغيُّر الإجمالي بسبب تعديل بند").
3. **تحمُّل مرجع غير نشط تاريخيًا (0069):** فحص "نشط" على `category_id`/`karat_id`/`payment_method_id`/`collection_channel_id` يُطبَّق **فقط** حين يكون المرجع جديدًا أو يتغيَّر إلى قيمة مختلفة؛ مرجع لم يتغيَّر يبقى مقبولًا حتى لو أصبح غير نشط لاحقًا (مثال واقعي: عيار أُلغي تفعيله بعد بيعه، تعديل لاحق لا يتعلق بالعيار يجب ألا يُفشِل الحفظ بالكامل).
4. **إغلاق تسريب الربح في سجل التدقيق (0072):** سياسة `audit_logs_select` أُعيدت كتابتها فقط، لا تغيير على شكل الصفوف المُخزَّنة نفسها. صف `sale.%` كان مرئيًا سابقًا لأي حامل لِـ`audit_logs.view` وحده — بما فيه `old_values`/`new_values` الحاملة لِـ`gross_profit`/`net_sales_profit` كاملَين. الآن يتطلب `sales.view_profit` أيضًا؛ كل حدث آخر (`daily_closing.create` مثلًا) غير متأثر إطلاقًا.
5. **سباق Daily Close (0065/0068/0069/0071):** قفل استشاري بمساحة اسم مستقلة `pg_advisory_xact_lock(1002, hashtext(store_id::text || ':' || business_date::text))` — مشترك لِـ`create_sales_order()`/`update_sales_order()`، حصري لِـ`close_sales_day()`. يضمن أن عملية بيع مفتوحة (غير مُلتزَمة بعد) تمنع فعليًا إغلاق نفس اليوم لنفس المتجر حتى تُلتزَم، وأن إغلاقًا مفتوحًا يمنع أي إنشاء/تعديل جديد لنفس اليوم حتى يُلتزَم — بصرف النظر عن ترتيب التنفيذ الفعلي.
6. **منع Lost Update (0069):** `update_sales_order()` تقفل صف `sales_orders` المستهدف بـ`select ... for update` **قبل** أي قراءة لحالته الحالية. تعديلان متزامنان على نفس العملية: الثاني يُحجَب فعليًا حتى يلتزم الأول، ثم يُبنى على الحالة المُلتزَمة الفعلية — لا على لقطة قديمة التُقِطت قبل انتظار القفل (مُثبَت صراحة عبر `old_values` في سجل التدقيق، انظر اختبار I أدناه).
7. **اتساق اللقطة المالية تحت التزامن (0065/0066/0068/0069):** قفل استشاري ثانٍ بمساحة اسم مستقلة تمامًا `pg_advisory_xact_lock(1001, 0)` — مشترك لأي قراءة/حل مالي داخل Sales، حصري لخمس دوال كتابة بيانات مالية أساسية (سعر ذهب، رسوم تصنيع، عمولة دفع، ضريبة). يمنع عملية بيع متعددة البنود من "التقاط" مزيج أسعار قديم/جديد لنفس العيار عندما يُصحَّح السعر أثناء إنشائها.
8. **تصالح التقريب (0065):** `compute_sales_item_costs()` تُطبَّق داخل `create_sales_order()`/`update_sales_order()`/`preview_sales_order()` الثلاثة معًا (لا نسخة مكرَّرة). `gold_component_cost`/`manufacturing_component_cost`/`vat_cost` تُقرَّب مستقلةً لمنزلتين؛ `base_cost = gold_component_cost + manufacturing_component_cost` و`total_cost = base_cost + vat_cost` **تجميع دقيق بلا تقريب إضافي** (جمع رقمين مُقرَّبين فعلًا)؛ `gross_profit = sale_price − total_cost` كذلك. يضمن **دائمًا** `total_cost + gross_profit = sale_price` تمامًا. المثال الحدّي المُتحقَّق منه فعليًا (وزن=0.0100، سعر ذهب=300، رسوم تصنيع=10، ضريبة=15%، سعر بيع=100): `gold_component_cost=3.00`، `manufacturing_component_cost=0.10`، `base_cost=3.10`، `vat_cost=0.4650→0.47`(تقريب نصف-بعيد-عن-الصفر لـPostgres `round()`، مُتحقَّق تجريبيًا: `round(0.465,2)=0.47`)، `total_cost=3.57`، `gross_profit=96.43` — `3.57+96.43=100.00` تمامًا.
9. **إزالة `Number()`/`parseFloat()` من طبقة المبيعات:** `sales-entry-form.tsx` كان يحسب الإجمالي المعروض مؤقتًا (قبل وصول Preview الحقيقي من القاعدة) عبر `Number(it.sale_price)` — استُبدل بجمع `Decimal` صريح (`src/lib/decimal.ts`)، مطابقًا لنمط بقية المشروع. بحث كامل عبر ميزة Sales لم يجد أي استخدام آخر لِـ`Number()`/`parseFloat()` على قيمة مالية.
10. **مطابقة Preview لِـCreate (0070):** `preview_sales_order()` كانت تفتقد `collection_channel_id` كمعامل، ولا تتحقق من تاريخ مستقبلي، ولا تُشير إلى يوم مُقفَل إطلاقًا — توقيعها الآن `(p_store_id, p_sale_date, p_payment_method_id, p_collection_channel_id, p_items)` مطابقًا لِـ`create_sales_order()` حرفيًا، مع نفس تحقق قناة التحصيل/التاريخ المستقبلي، وحقل `is_day_closed` في نتيجتها.
11. **عرض/تصفية الموظف بلا اعتماد على `users.view` (0070):** `list_sales_salespersons()` جديدة — موظفو مبيعات مميَّزون (distinct) ممن لديهم عملية بيع واحدة على الأقل ضمن نطاق رؤية المتجر للفاعل، تتطلب `sales.view` فقط. `list_sales_orders()`/`get_sales_order()` يُرجعان `salesperson_name` محلولًا من الخادم مباشرة. **ثغرة إضافية اكتُشِفت أثناء هذا العمل ولم تكن في القائمة الأصلية**: كل من `src/features/sales/queries.ts` (قائمة `/sales`) و`src/app/(app)/sales/[id]/page.tsx` (صفحة تفاصيل عملية بيع) كانا يستعلمان جدول `profiles` مباشرة لعرض اسم الموظف — وهو ما يتطلب `users.view` فعليًا رغم أن الصفحتين تتطلبان `sales.view` فقط اسميًا. أُزيل الاستعلامان المباشران واستُبدلا بالحقل المحلول من الخادم في كلا الموضعين.
12. **CloseDayDialog يستخدم متاجر تشغيلية لا مرئية (0070 استخدام / لا ترحيلة):** `getOperableStoresForCloseDay()` جديدة في `queries.ts` (تستدعي `my_operable_store_ids()` الموجودة مسبقًا من Foundation) — `/sales/page.tsx` يمرّرها لِـ`CloseDayDialog` بدل `getVisibleStoresForSalesFilters()` المُستخدَمة لفلتر القائمة (وهي أوسع نطاقًا، مناسبة للعرض التاريخي لا للإغلاق).
13. **الاختبارات المطلوبة (A–M):** انظر القسم 4 أدناه.

### 3) القفلان الاستشاريان — تفاصيل تقنية

مساحتا اسم مستقلتان تمامًا (النسخة ذات معاملَي int32) لضمان صفر تصادم بين "أنواع" الأقفال:
- **قفل اليوم المقفل:** `pg_advisory_xact_lock[_shared](1002, hashtext(store_id::text || ':' || business_date::text))`.
- **القفل المالي الأساسي:** `pg_advisory_xact_lock[_shared](1001, 0)` — قفل عام واحد (لا `hashtext` هنا؛ كل كتابة بيانات مالية أساسية، بصرف النظر عن العيار/طريقة الدفع، تتشارك نفس القفل الحصري، لأن قراءة Sales لعنصر واحد قد تحتاج قراءة عيار **و**طريقة دفع **و**ضريبة معًا في نفس المعاملة).

كل الدوال الأربع مُغلَّفة (`language sql`)، مُمنوحة `REVOKE ... FROM PUBLIC` + `GRANT ... TO authenticated` (ضرورية لأن مستدعيًا بـ`SECURITY INVOKER` مثل `save_daily_gold_price` يستدعيها مباشرة)، ونطاقها معاملاتي بالكامل (`_xact_`) — تُحرَّر تلقائيًا عند `COMMIT`/`ROLLBACK`، لا حاجة لتحرير صريح.

### 4) الاختبارات — قائمة كاملة وأرقام فعلية

**ملف جديد بالكامل — Part 1، أحادي الجلسة (`supabase/tests/sales_integrity_patch_3_1.test.sql`):** **14 نقطة تحقق "OK"** (46 تأكيد `assert` فردي)، داخل `begin;...rollback;` (آمن لإعادة التشغيل). يغطي السيناريوهات A (هوية بند ثابتة)، B (تعديل بيانات أساسية + تعديل وصفي)، C (طريقة دفع فقط)، D (تعديل مالي لبند واحد)، E (حذف بند)، F1–F4 (مراجع غير نشطة تاريخيًا)، G1–G2 (تسريب الربح في التدقيق)، L/L2 (حالة التقريب الحدّية، مباشرة وعبر `create_sales_order()` فعليًا). ثغرات اكتُشِفت وأُصلِحت أثناء الكتابة: عزل عياري `P31K_D`/`P31K_L` مخصَّصين لقسمي D/L (كانا يتشاركان عيار قسم B الذي يُصحِّح سعره عمدًا ضمن نفس القسم، ما كان يُنتج أرقامًا متوقَّعة خاطئة)؛ مرجع عيار خاطئ في حمولة تعديل D كان يجعل بندًا "غير متغيّر" يُصنَّف خطأً كمتغيّر.

**ملف جديد بالكامل — Part 2، تزامن حقيقي عبر جلستين منفصلتين فعليًا (`supabase/tests/sales_integrity_patch_3_1_concurrency.test.sql`):** **5 سيناريوهات (H1، H2، I، J، K) + نقطة تحقق ختامية** (17 تأكيد `assert` فردي)، عبر امتداد `dblink` (اتصالان حقيقيان منفصلان `conn_a`/`conn_b` من نفس السكربت المُتحكِّم، إثبات حجب فعلي عبر استطلاع `dblink_is_busy()` — لا مجرد تسلسل استدعاءات). **هذا الملف ليس آمنًا لإعادة التشغيل بـROLLBACK بتصميمه** (كامل الهدف إثبات حجب عبر التزام حقيقي)؛ ينظّف بياناته صراحةً (DELETE فعلي) في نهايته، ومُتحقَّق يدويًا من نجاح إعادة التشغيل المتتالية ثلاث مرات متتالية بلا أي أثر متبقٍّ. أخطاء بنيوية حقيقية اكتُشِفت وأُصلِحت أثناء الكتابة (لا شيء منها كان معروفًا مسبقًا في هذا المشروع — أول استخدام لِـ`dblink` فيه):
- استبدال `psql`، لا يُطبِّق `:'var'` داخل نص `do $$ ... $$` مُقتبَس بعلامة الدولار — عولج بتمرير قيمة الاتصال عبر `set_config()`/`current_setting()` بدل الاعتماد على استبدال psql مباشرة داخل الكتلة.
- `dblink_exec()` يرفض أي أمر بعيد يُعيد صفوفًا (حتى دالة تُرجِع صفًا واحدًا) — عولج بتغليف استدعاءات RPC التي يجب أن تبقى مفتوحة (غير مُلتزَمة) داخل `do $inner$ ... perform ... end $inner$;` بعيدة بدل `select` مباشر.
- `dblink_get_result()` يجب استدعاؤها مرتين لكل استعلام غير متزامن (الأولى تُرجِع الصف/القيمة الفعلية، الثانية فارغة وتُنهي حالة الاتصال) — أُضيفت دالة اختبار مساعدة `_p31c_drain_pending()` واستُدعيت بعد كل استخراج نتيجة.
- تضارُب متجر H1 مع I/J/K (H1 كانت تُغلق "اليوم الحالي" لنفس المتجر الذي تستخدمه بقية الأقسام لإنشاء عمليات جديدة) — عولج بمتجر مخصَّص `P31CH1` لِـH1 وحدها.
- بيانات إنشاء غير مُلتزَمة قبل فتح اتصالَي dblink (اتصال منفصل فعليًا لا يرى بيانات غير مُلتزَمة من الجلسة المُتحكِّمة) — أُضيف `commit;` صريح داخل كتلتَي I/J بعد إنشاء البيانات الأولية وقبل فتح أي اتصال.
- تنظيف النهاية كان يفشل بخطأ `prevent_self_permission_override_modification` لأن `request.jwt.claims` بقيت مضبوطة (غير محلية) من أقسام سابقة — عولج بمسحها صراحة (`set_config(..., '', false)`) قبل حذف صفوف `user_permission_overrides` في قسم التنظيف.

**الملفان الستة الأخرى + `sales_core.test.sql`:** أُعيد تشغيلها بالكامل ضد قاعدة تحتوي 0001–0072 — `rls_and_permissions.test.sql` → **139/139**، `financial_master_data.test.sql` → **52/52**، `financial_integrity_patch_2_1.test.sql` → **34/34**، `financial_integrity_patch_2_2.test.sql` → **17/17**، `financial_integrity_hotfix_2_2_1.test.sql` → **14/14**، `financial_integrity_hotfix_2_2_2.test.sql` → **11/11**، `sales_core.test.sql` → **57/57** (حُدِّث ليعكس السلوك الجديد: هوية بند ثابتة بدل حذف/إدراج، تصفية `status='active'`، توقيع `preview_sales_order()` الجديد — بلا أي تقليص في التغطية، انظر القسم 5 أدناه).

**اختبار الترقية (`scripts/run_upgrade_test.sh` + `upgrade_from_0039.test.sql`):** يُطبِّق 0040–**0072** تلقائيًا عبر glob بلا تعديل على السكربت أو الملف. → **نجح، 11/11 تأكيد**.

**اختبار HTTP/PostgREST الحقيقي (`scripts/run_postgrest-http-test.mjs` + `run_postgrest_http_test.sh` + `postgrest_http_test_setup.sql`، بند M):** وُسِّع بقسمين جديدين فوق الأجزاء القائمة، وأُصلِح استدعاء `preview_sales_order()` القائم (كان سيفشل فورًا بعد تغيير توقيعها في 0070 لولا الإصلاح):
- **حماية ربح سجل التدقيق عبر HTTP حقيقي:** طلب GET حقيقي على `/audit_logs?entity_id=eq...&action=like.sale.*` (استعلام جدول عادي عبر PostgREST، لا RPC) — فاعل يملك `audit_logs.view` + `sales.view_profit` يرى الصفوف، فاعل يملك `audit_logs.view` فقط يرى **صفرًا** (تُثبِت أن RLS تُخفي الصف كاملًا لا الأعمدة فقط).
- **هوية بند ثابتة عبر HTTP حقيقي:** إنشاء طلب ببندين حقيقي، تعديل عبر `update_sales_order()` حقيقي (إسقاط بند + تعديل وصفي لآخر)، ثم إثبات عبر `get_sales_order()` أن `id` البند المُبقى لم يتغيَّر، وعبر JWT بدور `service_role` حقيقي (موقَّع بنفس أداة توقيع JWT الموجودة، مُستخدَم **حصرًا** كأداة تحقق تتجاوز RLS — تمامًا كعميل `src/lib/supabase/admin.ts` الحقيقي من جهة الخادم) استعلام مباشر على `sales_order_items` يُثبِت أن البند المُسقَط لا يزال موجودًا فعليًا بـ`status='removed'`، لا محذوفًا صلبًا.
→ **نجح، 32/32 تأكيد** (23 من الأجزاء السابقة القائمة + 9 جديدة لبند M)، ضد ثنائي PostgREST v12.2.3 حقيقي عبر HTTP فعلي.

### 5) ثغرة اختبار مُصحَّحة قبل أي تسليم (لا تقليص تغطية)

عند تحديث `sales_core.test.sql` ليعكس هوية البند الثابتة، تبيَّن أن قسم 4 (تعديل البنود) كان يتحقق من `sales_order_items` بدون فلتر `status='active'` — بعد إصلاحه، أُضيف قسم **4.1b** جديد يُثبِت صراحةً أن البند الأصلي (5 غرام) الذي استُبدِل ضمن هذا السيناريو لا يزال موجودًا فعليًا بصف `status='removed'`، `removed_at` غير فارغ، و`removed_by` يطابق الفاعل الصحيح — هذا تحقق إضافي لم يكن موجودًا في نسخة Phase 3 الأصلية، وليس إزالة لأي تحقق قائم.

### 6) الفحص النهائي الكامل — نتائج فعلية

- إعادة بناء قاعدة اختبار Postgres محلية **من الصفر بالكامل**: `local_harness_setup.sql`، **كل الترحيلات 0001–0072 بالترتيب دون توقف** (72/72 نجحت)، ثم `supabase/seed.sql` (نجح).
- `supabase/tests/rls_and_permissions.test.sql` → **139/139**، `financial_master_data.test.sql` → **52/52**، `financial_integrity_patch_2_1.test.sql` → **34/34**، `financial_integrity_patch_2_2.test.sql` → **17/17**، `financial_integrity_hotfix_2_2_1.test.sql` → **14/14**، `financial_integrity_hotfix_2_2_2.test.sql` → **11/11**، `sales_core.test.sql` → **57/57**، `sales_integrity_patch_3_1.test.sql` → **14/14**، `sales_integrity_patch_3_1_concurrency.test.sql` → **نجح (H1/H2/I/J/K + التنظيف)، مُتحقَّق عبر ثلاث تشغيلات متتالية بلا أثر متبقٍّ**.
- اختبار الترقية (0040–0072 تلقائيًا) → **نجح، 11/11 تأكيد**.
- اختبار HTTP/PostgREST الحقيقي → **نجح، 32/32 تأكيد**، ضد ثنائي PostgREST v12.2.3 حقيقي.
- `npx tsc --noEmit` → **صفر أخطاء**.
- `npx eslint` → **صفر أخطاء وتحذيرات**.
- `npx vitest run` → **45/45 ناجح عبر 5 ملفات**.
- `npm run check:numeric-types` → **نجح، 23/23 عمود NUMERIC مطابق** (لا عمود NUMERIC جديد في هذا الملحق — الأعمدة الثلاثة الجديدة `status`/`removed_at`/`removed_by` نصّية/زمنية/معرّف، لا رقمية).
- `npm run build` (Next.js/Turbopack) → **نجح**، 25 مسارًا (بلا مسار جديد — هذا الملحق يُصلِح صفحات Sales القائمة، لا يضيف صفحة جديدة).

### 7) الملفات/الترحيلات التي تغيَّرت أو أُضيفت في Patch 3.1 (قائمة كاملة)

**ترحيلات جديدة (8):** `0065_sales_integrity_calc_lock_helpers.sql`، `0066_financial_master_writers_exclusive_lock.sql`، `0067_sales_order_items_stable_identity.sql`، `0068_create_sales_order_integrity.sql`، `0069_update_sales_order_integrity.sql`، `0070_sales_read_rpcs_integrity.sql`، `0071_close_sales_day_exclusive_lock.sql`، `0072_audit_logs_sales_profit_protection.sql`.

**اختبارات SQL جديدة بالكامل (2):** `supabase/tests/sales_integrity_patch_3_1.test.sql`، `supabase/tests/sales_integrity_patch_3_1_concurrency.test.sql`.

**اختبار SQL مُعدَّل (منطقًا، لا تقليص تغطية):** `supabase/tests/sales_core.test.sql` (توقيع `preview_sales_order()` الجديد، فلترة `status='active'`، قسم 4.1b الجديد).

**سكربتات HTTP مُعدَّلة:** `scripts/postgrest-http-test.mjs` (إصلاح استدعاء `preview_sales_order()` + قسمان جديدان لبند M)، `scripts/run_postgrest_http_test.sh` (توقيع JWT ثالث بدور `service_role`)، `supabase/tests/postgrest_http_test_setup.sql` (صلاحية `audit_logs.view` لكلا الفاعلَين الحاليَّين + `sales.edit` للفاعل الأول).

**كود TypeScript مُعدَّل:** `src/types/database.ts` (حقل `id` اختياري في `SalesOrderItemInput`، أعمدة `sales_order_items` الثلاثة الجديدة، عمود `salesperson_name` في `list_sales_orders`، معامل `p_collection_channel_id` في `preview_sales_order`، دالة `list_sales_salespersons` جديدة)، `src/features/sales/schema.ts` (`id` اختياري لكل بند، `collection_channel_id` مطلوب في معاينة)، `src/features/sales/actions.ts` (تمرير `id`/`p_collection_channel_id`)، `src/features/sales/queries.ts` (إزالة استعلام `profiles` المباشر لصالح `salesperson_name` من الخادم، دالتان جديدتان `getOperableStoresForCloseDay`/`getSalespeopleForSalesFilters`)، `src/features/sales/components/sales-entry-form.tsx` (إزالة `Number()`، تتبُّع `id` مستقر عبر التعديلات، إرسال `collection_channel_id` للمعاينة)، `src/features/sales/components/sales-filters.tsx` (فلتر موظف جديد)، `src/app/(app)/sales/page.tsx` (تمرير متاجر تشغيلية لِـ`CloseDayDialog`، فلتر/قائمة موظفين)، `src/app/(app)/sales/[id]/page.tsx` (إزالة استعلام `profiles` المباشر — ثغرة `users.view` إضافية اكتُشِفت هنا)، `src/app/(app)/sales/[id]/edit/page.tsx` (حقل `id` في نوع بند الطلب الحالي).

**لم يتغيّر إطلاقًا:** أي ترحيل من 0001–0064، أي اختبار SQL آخر خارج ما ذُكِر أعلاه (منطقًا)، أي ملف TypeScript/React خارج ميزة Sales.

**خلاصة الملحق الثالث عشر:** 13 إصلاحًا بنيويًا حقيقيًا على نواة مبيعات كانت تعمل وظيفيًا لكنها تحمل مخاطر تزامن وحذف صلب وتسريب ربح غير مُثبَتة سابقًا: هوية بند ثابتة (لا حذف صلب لأي تاريخ مالي)، إعادة حساب انتقائية تحترم عدم تغيُّر المدخل المالي، تحمُّل مراجع تاريخية غير نشطة، إغلاق تسريب ربح في سجل التدقيق (مُثبَت الآن عبر HTTP حقيقي أيضًا)، حماية من ثلاثة أنواع سباق تزامن حقيقية (Daily Close، Lost Update، لقطة مالية ممزوجة) — الثلاثة مُثبَتة بجلستين منفصلتين فعليًا عبر `dblink`، لا محاكاة، مطابقة رياضية كاملة لسلسلة التقريب، إزالة آخر استخدام لـ`Number()` في طبقة Sales، مطابقة Preview لِـCreate تمامًا، وثغرتان إضافيتان في اعتماد `users.view` غير الضروري اكتُشِفتا وأُصلِحتا أثناء هذا العمل (قائمة `/sales` وصفحة تفاصيل عملية بيع معًا، لا القائمة فقط كما وردت في المواصفة الأصلية). **لم تبدأ المرتجعات (Returns) ولا Shipping/Settlements/Inventory ولا أي مرحلة جديدة — العمل متوقف الآن، بانتظار مراجعة المستخدم وموافقته الصريحة.**

---

## الملحق الرابع عشر — "Sales Integrity Patch 3.2": الإصلاح النهائي لسلامة المبيعات (ترحيلات 0073–0080)

هذا الملحق يوثِّق **Patch 3.2**، حزمة إصلاحات نهائية من 14 بندًا صدرت بعد مراجعة المستخدم لِـPatch 3.1 على مستوى الشيفرة المصدرية مباشرة، ووُصفت صراحةً بأنها "الإصلاح الأخير لسلامة المبيعات". القيود الصارمة كما وردت حرفيًا من المستخدم وبقيت سارية طوال هذا الملحق: **"لا تبدأ Returns"**، **"لا تبدأ Shipping"**، **"لا تبدأ Settlements"**، **"لا تبدأ Inventory"**، **"لا تعدل migrations من 0001 إلى 0072"**، **"كل الإصلاحات الجديدة تبدأ من 0073 وما بعده"**، **"لا تعِد تصميم Sales من الصفر"**، **"حافظ على الإصلاحات الصحيحة الموجودة في 0065–0072"**، **"لا تخفّض Coverage ولا تغيّر test expectation فقط حتى يصبح Green؛ أصلح invariant نفسها"** — وثماني ترحيلات جديدة فقط (0073–0080)، لا تعديل واحد على أي ترحيلة سابقة. الإغلاق كما ورد: **"لا تبدأ Returns. انتظر المراجعة النهائية بعد التسليم."** — لم تبدأ.

### البند 1 — إغلاق ثغرة الكتابة المباشرة على `daily_gold_prices` (ترحيلة 0073)

**المشكلة:** `acquire_financial_master_lock_exclusive()`/`_shared()` (0065) كانتا تُستدعيان فقط من داخل `save_daily_gold_price()` — أي `UPDATE`/`INSERT` مباشر على `public.daily_gold_prices` (عبر `service_role` أو أي مسار يتجاوز الـRPC) كان يتجاوز القفل المالي بالكامل، فيمكن نظريًا أن يتغيّر سعر الذهب أثناء عملية بيع نشطة تعتمد عليه، منتجًا لقطات غير متسقة.

**الإصلاح:** `enforce_daily_gold_prices_financial_lock()` — دالة Trigger جديدة، مُفعَّلة `BEFORE INSERT OR UPDATE ... FOR EACH STATEMENT` على `public.daily_gold_prices`، تستدعي `acquire_financial_master_lock_exclusive()` قبل أي كتابة من أي مصدر. الـTrigger على مستوى الجدول نفسه — لا يُتجاوَز بـ`BYPASSRLS`/`service_role` (هذه تتجاوز سياسات RLS فقط، لا الـTriggers إطلاقًا)، ولا بالكتابة المباشرة بدل الـRPC. أُثبِت فعليًا بجلستين حقيقيتين منفصلتين عبر `dblink` (اختبار J2 الجديد، أدناه) — `UPDATE` مباشر (بلا `save_daily_gold_price()`) ينتظر فعليًا حتى التزام `create_sales_order()` مفتوحة.

### البند 2 — تحكم تزامن تفاؤلي حقيقي (Optimistic Concurrency) عبر `row_version` (ترحيلات 0075/0078/0079)

**المشكلة:** `update_sales_order()` (0069) كانت تقفل الصف (`FOR UPDATE`) قبل التعديل، لكن القفل وحده لا يمنع "الكتابة الأخيرة تفوز" (Last-Write-Wins) الصامتة: مستخدمان يفتحان نفس العملية، يعدّل الأول ويحفظ، ثم يحفظ الثاني فوقه بصمت لأنه لم يكن يعلم أن البيانات تغيّرت أثناء انتظاره.

**الإصلاح:** عمود `sales_orders.row_version bigint not null default 1`. `update_sales_order()` تكتسب معاملًا أخيرًا `p_expected_version bigint` (بلا قيمة افتراضية فعلية — الدالة نفسها ترفض `null`)؛ بعد قفل الصف مباشرة، تُقارَن قيمة `row_version` الحالية بـ`p_expected_version`، وأي عدم تطابق يُرفض فورًا برسالة تعارض عربية صريحة **قبل** تطبيق أي تعديل: *"تم تعديل عملية البيع بواسطة مستخدم آخر. حدّث الصفحة وراجع التغييرات قبل الحفظ."* النجاح يزيد `row_version` بمقدار 1 بالضبط. `get_sales_order()` (0079) تُرجع القيمة الحالية ليستخدمها العميل في الاستدعاء التالي. **لا إعادة إرسال تلقائية صامتة أبدًا** — لا في القاعدة ولا في العميل (`updateSalesOrderAction`/`SalesEntryForm`)؛ المستخدم يجب أن يُعيد التحميل صراحةً.

### البند 3 — سياسة تقريب كاملة الدقة (Full-Precision Rounding) (ترحيلة 0074)

**المشكلة:** المحرك السابق كان يُقرِّب كل مكوّن (تكلفة الذهب، أجرة الصنعة) على حدة قبل الجمع، فينتج أحيانًا اختلافًا بفلس واحد عن التقريب الصحيح للقيمة الإجمالية غير المقرَّبة (خطأ تراكمي كلاسيكي في الأنظمة المالية).

**الإصلاح:** `compute_sales_item_costs()` (نفس التوقيع، `CREATE OR REPLACE`) أُعيدت كتابتها لتُبقي كل قيمة وسيطة بدقة NUMERIC كاملة غير مُقرَّبة عبر كامل سلسلة الصيغة، ولا تُقرِّب إلا عند حدود المخرجات النهائية (`base_cost`/`total_cost`)؛ تفصيل المكوّنات (`gold_component_cost`/`manufacturing_component_cost`) يُشتَق بعد ذلك بتوزيع نسبي على الإجمالي المُقرَّب أصلاً، لا بتقريب مستقل لكل مكوّن. اختُبِر بحالة انحدار محدَّدة (وزن `0.0250` غرام) كانت تنتج `8.91` في المحرك القديم وتنتج `8.92` الصحيحة رياضيًا في المحرك الجديد — عبر الدالة مباشرة وعبر `create_sales_order()` كاملة (القسم C/C2).

### البند 4 — تحقق دقة الإدخال على مستوى القاعدة (ترحيلة 0074)

**المشكلة:** `weight_grams NUMERIC(10,4)`/`sale_price NUMERIC(14,2)` كانت تقبل Postgres تقريبها تلقائيًا وصامتًا عند إدخال دقة زائدة (مثال: وزن `1.00005` يُصبح `1.0001` بلا أي تحذير) — سلوك خطير ماليًا لأنه يغيّر القيمة المُدخَلة فعليًا دون علم المستخدم.

**الإصلاح:** `validate_sales_item_precision(p_weight_grams numeric, p_sale_price numeric)` — تستخدم `scale()` المدمجة في Postgres لرفض أي قيمة تتجاوز 4/2 منزلة عشرية على التوالي، أو تتجاوز الحد الأعلى (`10^6`/`10^12`)، **قبل** أي حساب، بدلاً من قبولها والتقريب الصامت. تُستدعى من `create_sales_order()`/`update_sales_order()`/`preview_sales_order()`/`preview_update_sales_order()` جميعًا، فتُطبَّق نفس القاعدة في كل مسار كتابة أو معاينة. مطابقة على مستوى العميل عبر `hasMaxDecimalPlaces()` (`src/lib/decimal.ts`) للتغذية الراجعة الفورية، لكن القاعدة تبقى المرجع الوحيد الفعلي (اختُبِر D1/D2/D3، بما فيها رفض ذري كامل لعملية متعددة البنود عند وجود بند واحد فقط مخالف).

### البند 5 — تكافؤ معاينة التعديل مع الحفظ (ترحيلة 0078)

**المشكلة:** `preview_sales_order()` تُعامل كل بند كجديد بالكامل دائمًا (مناسب لِـCreate فقط)؛ استخدامها لمعاينة تعديل قائم كان يعطي نتيجة مختلفة عن `update_sales_order()` الفعلية لأن الأخيرة تُعيد الحساب انتقائيًا (Patch 3.1 البند 3) — بند لم يتغيّر ماليًا يُبقي لقطته القديمة، لا يُعاد حسابه بسعر اليوم.

**الإصلاح:** `preview_update_sales_order(p_order_id, p_expected_version, ...)` — دالة جديدة بالكامل تُطابق شجرة قرار `update_sales_order()` حرفيًا (بند غير متغيّر ← لقطة محفوظة، بند متغيّر ← إعادة حساب) دون كتابة أي شيء، وتتحقق من `p_expected_version` أيضًا فتُظهر تعارضًا مبكرًا في المعاينة نفسها قبل محاولة الحفظ. اختُبِر (القسم E) بتصحيح سعر ذهب فعلي بعد إنشاء عملية بيع، ثم معاينة تعديل بملاحظة فقط (بلا تغيير مالي) — بقيت المعاينة على اللقطة القديمة وطابقت نتيجة الحفظ الفعلي حرفيًا.

### البند 6 — مراجع تاريخية غير نشطة في قوائم واجهة التعديل (ترحيلة 0080)

**المشكلة:** واجهة التعديل كانت تُحمَّل من `getSalesFormLookups()` (نشط فقط، نفس مصدر شاشة "عملية بيع جديدة") — عملية بيع تاريخية تُشير إلى عيار/تصنيف/طريقة دفع/قناة تحصيل أصبحت غير نشطة لاحقًا كانت تظهر بحقل فارغ أو قيمة مفقودة في نموذج التعديل، رغم أن `update_sales_order()` نفسها تسمح ببقاء المرجع غير المتغيّر (Patch 3.1 البند 6).

**الإصلاح:** `sales_order_edit_lookups(p_order_id)` — دالة جديدة، تُرجع كل خيار نشط **زائدًا** القيمة الحالية الفعلية لهذه العملية تحديدًا حتى لو أصبحت غير نشطة (مُعلَّمة `is_historical`)، لا أي خيار غير نشط آخر. الواجهة (`SalesEntryForm`) تعرض الآن هذه القائمة حصرًا في وضع التعديل (`editLookups`)، مع تسمية "(غير نشط - تاريخي)" على الخيار التاريخي — ومنع اختيار أي خيار غير نشط **آخر** يتحقق أصلاً بأن القائمة المُرسَلة من القاعدة لا تحتوي عليه إطلاقًا، بينما `update_sales_order()` تُعيد فرض نفس القاعدة مستقلًا من جهة الخادم بصرف النظر عمّا تعرضه الواجهة.

### البند 7 — Versioning حقيقي لمحرك الحساب على مستوى البند (ترحيلات 0074/0075/0076)

**المشكلة:** لا وسيلة للتمييز بين بند حُسِب بالمحرك القديم (تقريب مبكر لكل مكوّن) وبند حُسِب بمحرك Patch 3.2 كامل الدقة — مهم للتدقيق ولفهم أي بند قد يحمل فرق فلس تاريخي بسبب تغيّر المحرك، لا خطأ فعلي.

**الإصلاح:** عمود `sales_order_items.calculation_version integer not null default 1` (منفصل تمامًا عن `sales_orders.calculation_version` الموجود أصلاً منذ 0059، الذي يخص محرك الطلب/الدفع لا محرك تكلفة البند). `create_sales_order()` تُعلِّم كل بند جديد `2`. `update_sales_order()` تُعلِّم بندًا جديدًا أو بندًا أُعيد حسابه فعليًا (تغيّر مدخل مالي) بـ`2`، وتترك بندًا لم يتغيّر ماليًا على إصداره كما هو **بلا ترقية قسرية** — عملية واحدة يمكن أن تحمل شرعًا مزيجًا من إصدار 1 و2 بين بنودها. اختُبِر (القسم F1/F2/F3): عملية جديدة بالكامل ← 2 على كل بند؛ تعديل وصفي فقط على بند v1 محاكى ← يبقى 1؛ تعديل مالي فعلي على نفس البند ← يصبح 2.

### البند 8 — إزالة اعتماد Sales Read الضمني على صلاحيات `.view` لبيانات رئيسية (ترحيلة 0079)

**المشكلة:** `list_sales_orders()`/`get_sales_order()` تُرجعان `store_id`/`payment_method_id`/`collection_channel_id` فقط؛ الواجهة كانت تستعلم `stores`/`payment_methods`/`collection_channels` مباشرة لحلّ الأسماء المعروضة — فاعل يملك `sales.view` فقط بلا `stores.view`/`payment_methods.view`/`collection_channels.view` كان يرى العملية نفسها لكن كل تسمية أساسية تظهر "—".

**الإصلاح:** كلتا الدالتين (`DROP` ثم `CREATE OR REPLACE` لإضافة أعمدة/مفاتيح مخرجات جديدة، إذ لا يمكن لـ`CREATE OR REPLACE` وحدها تغيير شكل الإرجاع) تحلّان الآن `store_name`/`payment_method_name`/`collection_channel_name` داخليًا — بنفس نمط حلّ `salesperson_name` القائم أصلاً منذ 0070 — فيتوقف أي اعتماد على صلاحيات بيانات رئيسية منفصلة. طبقة TypeScript (`listSalesOrdersPage()`/`getSalesOrderDetail()` وصفحتا القائمة/التفاصيل) حُدِّثت لقراءة هذه الحقول مباشرة، وحُذِف الاستعلام الثنائي المرحلة القديم بالكامل. اختُبِر (القسم G) بفاعل يملك `sales.view` فقط، بلا أي صلاحية `.view` من بيانات رئيسية — كل تسمية ظهرت صحيحة عبر كلا المسارين، والربح بقي محجوبًا تمامًا.

### البند 9 — سياسة موحَّدة لتعديل عمليات بيع تاريخية في متجر مُعطَّل (ترحيلات 0075/0078/0080)

**المشكلة:** `update_sales_order()` كانت تستخدم `user_operable_store_ids()` (نطاق تشغيلي، يستثني المتاجر المعطَّلة) لفحص صلاحية الوصول للمتجر — فعملية بيع تاريخية في متجر أصبح معطَّلًا لاحقًا كانت تصبح **غير قابلة للتعديل إطلاقًا**، رغم أن `store_id` نفسه غير قابل للتغيير أصلًا، فلا داعٍ منطقيًا لأن يمنع تعطيل المتجر تصحيح بيانات تاريخية فيه.

**الإصلاح:** `update_sales_order()`/`preview_update_sales_order()`/`sales_order_edit_lookups()` الثلاثة تستخدم الآن `user_visible_store_ids()` (نطاق أوسع، يشمل كل حالات المتجر) بدل `user_operable_store_ids()`، بينما `create_sales_order()` تبقى `user_operable_store_ids()` بلا تغيير (لا يجوز إنشاء عملية بيع **جديدة** في متجر معطَّل). اختُبِر (القسم H): إنشاء عملية بيع جديدة في متجر مُعطَّل ← يُرفض؛ تعديل عملية بيع تاريخية موجودة في نفس المتجر بعد تعطيله ← ينجح فعليًا، وواجهة البحث الخاصة بالتعديل تعمل لنفس العملية أيضًا.

### البند 10 — تدقيق مالي كامل قديم/جديد (ترحيلات 0075/0076)

**المشكلة:** حدث `sale.update` في سجل التدقيق كان يحمل رأس العملية القديم/الجديد فقط، بلا مصفوفة البنود — فلا يمكن معرفة **أي** بند تحديدًا تغيّر أو كيف من سجل التدقيق وحده. حدث `sale.create` كان يحمل الرأس فقط أيضًا.

**الإصلاح:** كل من `create_sales_order()`/`update_sales_order()` يكتبان الآن `new_values.items` (وللتعديل: `old_values.items` أيضًا) بمصفوفة كاملة تتضمن `calculation_version`/`row_version`/`subtotal` على الجانبين. اختُبِر (القسم I1/I2): `sale.create` يحمل مصفوفة البنود النهائية؛ `sale.update` يحمل `old_values.items`/`new_values.items` معًا، فيمكن فهم أي تغيير مالي بدقة من طرفَي السجل وحدهما.

### البند 11 — إصلاح اختبارات كانت تُخفي مشاكل حقيقية

كل فقرة هنا وثيقة السبب الجذري الذي كانت الاختبارات القديمة تُخفيه، لا مجرد تعديل رقم متوقَّع:

- **A) Lost Update كانت "تنجح" باختبار خاطئ:** قسم I القديم في `sales_integrity_patch_3_1_concurrency.test.sql` كان يُثبت أن الكاتب المتأخر B يفوز بصمت — وهذا **بالضبط** الخلل الذي يُصلحه البند 2 أعلاه، لا سلوكًا مرغوبًا. أُعيد كتابة القسم بالكامل ليُثبت الرفض الصريح بدل الفوز الصامت (I(1)/I(2) أعلاه).
- **B) لا اختبار للكتابة المباشرة على `daily_gold_prices`:** لم يكن هناك أي اختبار يمرّ بجانب `save_daily_gold_price()` بالكامل — أُضيف قسم J2 جديد.
- **C) استدعاءات `update_sales_order()` القائمة بلا `p_expected_version`:** كل استدعاء موجود في `sales_core.test.sql`/`sales_integrity_patch_3_1.test.sql` (12 موضعًا إجمالًا) كان سيفشل فورًا بمجرد إضافة المعامل المطلوب الجديد — أُصلحت جميعًا بجلب `row_version` الحقيقي عبر جدول مؤقت مُعاد استخدامه، لا بتمرير قيمة وهمية.
- **D) صلاحيات SELECT على جدول مؤقت بين الأدوار:** جدول مؤقت أُنشئ تحت `postgres` (superuser) لم يكن مقروءًا تحت `authenticated` بلا `GRANT SELECT` صريح — أُضيف `grant select ... to public` فور الإنشاء في كل موضع.
- **E) كتابة على جدول مؤقت بلا صلاحية:** بعض المواضع كانت تُنفّذ `delete`/`insert` على الجدول المؤقت مباشرة بعد `set role authenticated` بلا `reset role` سابق — أُصلحت الأنماط الثلاثة المتبقية بإضافة `reset role;` قبل كل كتابة.
- **F) تأكيد F1 كان يفشل بصمت:** `assert exists (select 1 from sales_order_items where ...)` كان يُنفَّذ تحت `set role authenticated`، و`sales_order_items` بلا أي سياسة SELECT لـ`authenticated` إطلاقًا — فيرجع صفر صف بصمت (لا خطأ) بدل التحقق الفعلي. أُصلح بنقل التأكيد إلى كتلة `reset role` منفصلة.
- **G) صلاحية `stores.disable` مفقودة من فاعل الاختبار:** `update stores set status = 'disabled'` تحت `reset role` كان يفشل رغم استخدام صلاحيات المُشغِّل الفائق، لأن `request.jwt.claims` (عبر `set local`) يبقى ساريًا طوال المعاملة بصرف النظر عن `SET ROLE`/`RESET ROLE`، فيستمر مُشغِّل الصلاحية بفحص هوية فاعل الاختبار الحقيقية. أُصلح بإضافة `stores.disable` إلى قائمة صلاحيات فاعل اختبار القسم H.
- **H) خطأ بروتوكول `dblink` جديد أثناء كتابة J2:** عبارة `UPDATE` خام مُرسَلة عبر `dblink_send_query` تترك نتيجتين يجب تفريغهما (نتيجة الأمر ثم نتيجة فارغة تالية)، لا نتيجة واحدة — أُصلح باستدعاء `_p31c_drain_pending('conn_b')` مرتين مع تعليق يوضّح السبب.
- **I) خطأ صياغة تنسيقي ذاتي في `RAISE`:** استخدام `%s` بدل `%` في `RAISE NOTICE` جديد أضفته بنفسي لقسم I(2) — أُصلح فور اكتشافه (خطأ تجميلي بحت في نص الإشعار، لا يمسّ أي تأكيد اختباري).

### البند 12 — عدم كسر إصلاحات Patch 3.1 الصحيحة

كل إصلاحات Patch 3.1 (هوية بند ثابتة، حذف ناعم لا صلب، إعادة حساب انتقائية، تحمُّل مراجع تاريخية غير متغيّرة، أقفال Daily Close/Financial Master المشتركة) بقيت **دون تغيير في المنطق**، ومُعاد اختبارها بالكامل ضمن نفس تشغيلة الاختبار الموحَّدة لهذا الملحق (`sales_integrity_patch_3_1.test.sql`/`sales_integrity_patch_3_1_concurrency.test.sql`، القسم 3 من `TEST_RESULTS_PATCH_3_2.md`) — 14/14 و8/8 على التوالي.

### البند 13 — مجموعة التحقق الكاملة

مُوثَّقة بالتفصيل وبأرقام فعلية في `TEST_RESULTS_PATCH_3_2.md`: بناء قاعدة بيانات من الصفر (80/80 ترحيلة)، اختبار الترقية (Foundation → latest)، عشرة ملفات اختبار SQL في تشغيلة واحدة متسلسلة (139+52+34+17+14+11+57+14+8+15 = **361 نقطة تحقق ناجحة**)، اختبار HTTP/PostgREST حقيقي (37/37، منها 6 جديدة لهذا الملحق)، `tsc --noEmit`/`eslint`/`vitest`/`check:numeric-types`/`next build` جميعًا نظيفة.

### البند 14 — حزمة التسليم

ملفات هذا الملحق: الترحيلات الثمانية (`0073`–`0080`)، اختبار SQL جديد بالكامل (`sales_integrity_patch_3_2.test.sql`)، تعديلات على ثلاثة ملفات اختبار SQL قائمة (`sales_core.test.sql`/`sales_integrity_patch_3_1.test.sql`/`sales_integrity_patch_3_1_concurrency.test.sql`)، تعديل على `scripts/postgrest-http-test.mjs`، وطبقة TypeScript كاملة (`src/types/database.ts`، `src/lib/decimal.ts`، `src/features/sales/schema.ts`/`actions.ts`/`queries.ts`، `src/features/sales/components/sales-entry-form.tsx`، وصفحات `/sales`، `/sales/[id]`، `/sales/[id]/edit`) — مُفصَّلة أدناه.

**الترحيلات الجديدة (0073–0080):**

- `0073_daily_gold_prices_write_lock_trigger.sql` — Trigger القفل المالي على مستوى الجدول (البند 1).
- `0074_full_precision_cost_engine_and_input_validation.sql` — محرك تقريب كامل الدقة + تحقق دقة الإدخال + عمود `calculation_version` على مستوى البند (البنود 3/4/7).
- `0075_update_sales_order_optimistic_concurrency.sql` — عمود `row_version` + إعادة كتابة `update_sales_order()` كاملة (البنود 2/3/4/7/9/10).
- `0076_create_sales_order_full_precision_engine.sql` — إعادة كتابة `create_sales_order()` بمحرك Patch 3.2 (البنود 3/4/7/10).
- `0077_preview_sales_order_full_precision_parity.sql` — `preview_sales_order()` بنفس محرك 0074/0076.
- `0078_preview_update_sales_order.sql` — `preview_update_sales_order()` جديدة بالكامل (البند 5).
- `0079_sales_read_rpcs_labels_and_concurrency_fields.sql` — `list_sales_orders()`/`get_sales_order()` بتسميات محلولة داخليًا + `row_version`/`calculation_version` (البندان 2/7/8).
- `0080_sales_order_edit_lookups.sql` — `sales_order_edit_lookups()` جديدة بالكامل (البند 6).

**اختبار SQL جديد بالكامل:** `supabase/tests/sales_integrity_patch_3_2.test.sql` (الأقسام C–I، 15 نقطة تحقق).

**اختبارات SQL مُعدَّلة (إصلاح استدعاءات فقط، لا تقليص تغطية — انظر البند 11):** `sales_core.test.sql`، `sales_integrity_patch_3_1.test.sql`، `sales_integrity_patch_3_1_concurrency.test.sql` (القسم I أُعيد كتابته منطقيًا + قسم J2 جديد).

**سكربت HTTP مُعدَّل:** `scripts/postgrest-http-test.mjs` (تمرير `p_expected_version` + قسم Patch 3.2 جديد بست تأكيدات).

**كود TypeScript مُعدَّل:**

- `src/types/database.ts` — عمود `row_version` في `sales_orders`، عمود `calculation_version` في `sales_order_items`، معامل `p_expected_version` مطلوب في `update_sales_order`، حقول التسميات الجديدة في `list_sales_orders`/`get_sales_order`، دالتان جديدتان `preview_update_sales_order`/`sales_order_edit_lookups`.
- `src/lib/decimal.ts` — `hasMaxDecimalPlaces()` (مطابقة عميل لِـ`validate_sales_item_precision()`).
- `src/features/sales/schema.ts` — تحقق دقة عشرية على `weight_grams`/`sale_price`، `row_version` مطلوب في `updateSalesOrderSchema`، مخطط `previewUpdateSalesOrderSchema` جديد، `isVersionConflictError()`.
- `src/features/sales/actions.ts` — تمرير `p_expected_version`، `previewUpdateSalesOrderAction()` جديدة.
- `src/features/sales/queries.ts` — `listSalesOrdersPage()` تقرأ `store_name`/`payment_method_name`/`collection_channel_name` من الـRPC مباشرة (حُذِف الاستعلام الثنائي المرحلة)، `getSalesOrderEditLookups()` جديدة.
- `src/features/sales/components/sales-entry-form.tsx` — تتبُّع `row_version`، معاينة تعديل عبر `previewUpdateSalesOrderAction`، شريط تنبيه تعارض صريح (بلا إعادة إرسال تلقائية أبدًا)، قوائم اختيار تاريخية-شاملة في وضع التعديل (`editLookups`) بدل النشطة فقط.
- `src/app/(app)/sales/[id]/edit/page.tsx` — استبدال `getSalesFormLookups()` + استعلام المتجر اليدوي بـ`getSalesOrderEditLookups()` + `store_name` المُرجَعة من `get_sales_order()` مباشرة، تمرير `row_version`.
- `src/app/(app)/sales/[id]/page.tsx` — قراءة `store_name`/`payment_method_name`/`collection_channel_name` من `get_sales_order()` مباشرة بدل ثلاثة استعلامات منفصلة.

**لم يتغيّر إطلاقًا:** أي ترحيل من 0001–0072، أي اختبار SQL آخر خارج ما ذُكِر أعلاه (منطقًا)، `src/app/(app)/sales/page.tsx` (شكل البيانات المُرجَعة من `listSalesOrdersPage()` أُبقي متطابقًا عمدًا لتفادي أي تعديل هناك)، `src/app/(app)/sales/new/page.tsx`.

**خلاصة الملحق الرابع عشر:** 14 بندًا مطلوبًا بالضبط، أُغلقت جميعًا على مستوى القاعدة أولًا ثم الواجهة، بثماني ترحيلات جديدة فقط بعد 0072، بلا لمس أي ترحيلة سابقة، وبلا بدء Returns/Shipping/Settlements/Inventory. **الأهم:** ثغرة Lost Update لم تكن غائبة عن الاختبار فقط — الاختبار القديم كان يُثبت **عكس** السلوك الصحيح (فوز صامت للكاتب المتأخر) كحالة نجاح، وهو بالضبط نوع "الاختبار الذي يُخفي مشكلة حقيقية" الذي طلب المستخدم صراحةً عدم تركه (البند 11)؛ إصلاحه تطلَّب إعادة كتابة السيناريو نفسه لا مجرد رقعه. تسعة إصلاحات اختبارية إضافية (البند 11، الفقرات B–I) وُثِّقت كلها بسببها الجذري الفعلي، لا كتعديل رقم متوقَّع. 361 نقطة تحقق SQL ناجحة في تشغيلة واحدة متسلسلة على قاعدة بيانات واحدة مبنية من الصفر، بالإضافة إلى 37 تأكيدًا حقيقيًا عبر HTTP/PostgREST فعلي، تثبت أن كل بند من الأربعة عشر يعمل فعليًا لا نظريًا فقط. **لم تبدأ المرتجعات (Returns) ولا Shipping/Settlements/Inventory ولا أي مرحلة جديدة — العمل متوقف الآن نهائيًا، بانتظار المراجعة النهائية للمستخدم بعد هذا التسليم.**

---

## الملحق الخامس عشر — "Final Hotfix 3.2.1": ثلاث نقاط محددة فوق Patch 3.2 (ترحيلة 0081)

بعد مراجعة المستخدم لِـPatch 3.2 على مستوى المصدر الفعلي مباشرة (لا التقرير فقط)، ورد تصحيح أخير محدود بثلاث نقاط دقيقة قبل تجميد Sales وبدء Returns. القيود كالمعتاد وبقيت سارية طوال هذا الملحق: **"لا تبدأ Returns"**، **"لا تبدأ Shipping / Settlements / Inventory"**، **"لا تعدل migrations من 0001 إلى 0080"**، **"أي إصلاح جديد يبدأ من 0081"**، **"لا تعيد تصميم Sales"**، **"حافظ على كل إصلاحات 3.1 و3.2 الحالية"** — وترحيلة هوتفكس واحدة فقط (0081)، بلا تعديل على أي ترحيلة سابقة.

### البند 1 — إصلاح Conflict Reload في Edit UI (لا ترحيلة SQL — TypeScript/React فقط)

**المشكلة (مؤكَّدة فعليًا قبل الإصلاح، لا نظريًا فقط):** الكود القديم في `SalesEntryForm` كان يُنشئ `useState` لكل حقل محلي (`items`/`paymentMethodId`/`collectionChannelId`/حقول العميل/`notes`) من `existingOrder` **مرة واحدة فقط عند التركيب (mount)**. بعد Conflict، زر "تحديث الصفحة" كان يستدعي `router.refresh()` فقط، ثم يمسح `versionConflict` عند وصول `row_version` أحدث — لكن `router.refresh()` في Next.js App Router يُعيد تشغيل الـServer Component ويُمرِّر `existingOrder` جديدًا **دون تفكيك (unmount) الـClient Component المُركَّب أصلًا** — فتبقى كل الحقول المحلية الأخرى (وعلى رأسها وزن/سعر كل بند) على قيمها القديمة. النتيجة العملية: مستخدم B يحمّل الطلب عند `version=5`/`weight=1`، مستخدم A يحفظ `weight=5` فيصبح `version=6`، B يفشل بتعارض صريح (هذا يعمل بشكل صحيح)، B يضغط "تحديث الصفحة"، الشارة تختفي (لأن `row_version` تغيّر)، **لكن حقل الوزن يبقى `1` محليًا** — فإذا حفظ B الآن بـ`expected_version=6` الجديد، ينجح الحفظ **ويُلغي تعديل A بصمت**، مُبطلًا الهدف الكامل من Optimistic Concurrency بعد الخطوة الموصى بها للمستخدم نفسه للتعافي من التعارض.

**الإصلاح:** `src/app/(app)/sales/[id]/edit/page.tsx` — إضافة `key={order.row_version}` إلى `<SalesEntryForm>`. تغيير الـ`key` يُجبر React على تفكيك المُكوِّن القديم بالكامل وتركيب نسخة جديدة تمامًا عند كل `router.refresh()` يحمل `row_version` مختلفًا — فتُعاد تهيئة **كل** حقل محلي (لا الوزن فقط) من `existingOrder` الجديد، دون أي استثناء ودون حاجة لأي منطق Reset يدوي متفرّق. أُزيل بالمقابل منطق "تعديل الحالة أثناء الالتقديم" (`lastSeenRowVersion`) الذي كان يمسح `versionConflict` فقط — أصبح زائدًا تمامًا بعد إصلاح الـ`key` (كل `useState` يُعاد تهيئته تلقائيًا مع كل تركيب جديد).

**الإثبات:** اختبار Regression جديد `tests/sales-entry-form-conflict-reload.test.tsx` (React Testing Library) يُحاكي السيناريو الإلزامي حرفيًا: B يحمّل `weight=1`/`version=5`، ثم يُعاد العرض (`rerender`) بـ`existingOrder` جديد (`weight=5`/`version=6`) عبر `key` مختلف — ويتحقق أن `weight=1` **اختفى تمامًا** من DOM وأن `weight=5` ظاهر. **أُثبِت الاختبار سلبيًا أيضًا** (Negative Proof): إزالة `key={order.row_version}` مؤقتًا من الاختبار نفسه جعلت الاختبارين يفشلان فعليًا (`expected document not to contain element, found <input ... value="1.0000" />`)، قبل إعادته والتحقق من النجاح — إثبات أن الاختبار حسّاس فعليًا للخلل الحقيقي، لا اختبارًا شكليًا. اختبار ثانٍ يثبت نفس الشيء لحقل غير-بندي (`customer_name`) لتغطية أوسع من "حقل واحد فقط".

### البند 2 — ACL القفل المالي لـ`service_role` (ترحيلة 0081، Part A)

**المشكلة (مؤكَّدة فعليًا قبل الإصلاح عبر استعلام مباشر ضد قاعدة حقيقية):**
```
begin; set local role service_role;
update public.daily_gold_prices set price_per_gram = 999 where ...;
-- ERROR:  permission denied for function acquire_financial_master_lock_exclusive
```
`enforce_daily_gold_prices_financial_lock()` (0073) هي `SECURITY INVOKER` (بلا `security definer`)، فتُنفَّذ بصلاحيات الدور الذي أطلق عبارة الكتابة فعليًا. 0065 منحت `EXECUTE` على `acquire_financial_master_lock_exclusive()` لـ`authenticated` فقط — لم يُمنح `service_role` أبدًا. `service_role` دور `BYPASSRLS` بمنح كامل على مستوى الجداول، لكن `BYPASSRLS` ومنح الجداول لا يُغنيان عن منح `EXECUTE` منفصل على مستوى الدالة. النتيجة الفعلية لم تكن "service_role يتجاوز القفل" كما زعم تعليق 0073 عن قصد شمول `service_role`، بل **"service_role يُمنَع من الكتابة إطلاقًا"** — خطأ رفض فوري، لا انتظار ثم نجاح؛ وهذا يمسّ أيضًا `save_daily_gold_price()`/`save_daily_gold_prices_bulk()` (0066، `SECURITY INVOKER` بنفس المنطق) عند استدعائهما مباشرة بدور `service_role`.

**الإصلاح:** ترحيلة 0081، الجزء أ — `GRANT EXECUTE ON FUNCTION public.acquire_financial_master_lock_exclusive() TO service_role;` فقط. لم تُوسَّع صلاحيات `anon` إطلاقًا (تبقى بلا أي وصول، كما كانت). منح واحد بسيط يُصلح مسارين معًا (الكتابة المباشرة على الجدول عبر المُشغِّل، واستدعاء `save_daily_gold_price()`/`save_daily_gold_prices_bulk()` مباشرة) لأن كليهما يمرّان بنفس الدالة المساعِدة تحت نفس القاعدة (`SECURITY INVOKER`).

**الإثبات:** قسمان جديدان (`L1`/`L2`) أُضيفا إلى `supabase/tests/sales_integrity_patch_3_1_concurrency.test.sql` (تزامن حقيقي عبر `dblink`، بنفس نمط `J2` القائم): **L1** — اتصال A يفتح `create_sales_order()` متعددة البنود ويبقى دون التزام، اتصال B ينفّذ `SET ROLE service_role` ثم `UPDATE` مباشر على `daily_gold_prices` لنفس العيار/التاريخ — يجب أن يُحجب فعليًا حتى التزام A، ثم ينجح **دون أي خطأ صلاحيات**، مع تحقق أن الكتابة طُبِّقت فعليًا وأن بندي A كليهما استخدما السعر القديم المتسق. **L2** — كتابة `service_role` عادية بلا أي Sale متزامنة يجب أن تنجح ببساطة. **أُثبِت الاختبار سلبيًا** أيضًا: تشغيله ضد قاعدة مبنية من 0001–0080 فقط (بلا 0081) أعاد فعليًا `FAIL L1: ... permission denied for function acquire_financial_master_lock_exclusive` — نفس الخلل الحقيقي المُكتشَف يدويًا أعلاه، قبل إعادة بناء القاعدة بـ0081 والتحقق من النجاح.

### البند 3 — توحيد دلالة `sales_orders.calculation_version` (ترحيلة 0081، Part B)

**المشكلة:** `create_sales_order()` (0076) تُعلِّم رأس عملية بيع جديدة بـ`calculation_version=2` بشكل صحيح — لكن `update_sales_order()` (0075) لم تكن تُدرِج `calculation_version` إطلاقًا ضمن عبارة `UPDATE` الخاصة بها على `sales_orders`، رغم أن نفس الاستدعاء الناجح يُعيد بناء `subtotal`/`gross_profit`/`payment_fee_amount`/`net_sales_profit` فعليًا بالمحرك الحالي في كل مرة. النتيجة: عملية بيع من حقبة Patch 3.1 (رأس `v1`) تتلقى تعديلًا بعد Patch 3.2 (حتى وصفيًا بحتًا) تنتهي بإجماليات رأس محسوبة بالمحرك الحالي، لكن عمود `calculation_version` **يبقى 1** — لا فرق ظاهري عن رأس لم يُلمس بالمحرك الجديد إطلاقًا. سجل التدقيق فاقم المشكلة: `new_values.calculation_version` في 0075 كانت تُكتَب كـ`v_old_order.calculation_version` (القيمة **القديمة**، دون تغيير)، فحتى سجل التدقيق نفسه لم يكن يميّز الحالتين بعد وقوع التعديل.

**الدلالة المعتمدة الآن (موثَّقة بوضوح في 0081 وفي تعليقات الدالة):**
- `sales_order_items.calculation_version` (0074/0075، **بلا أي تغيير في هذا الهوتفكس**): أي محرك حسب تكلفة **هذا البند تحديدًا** — بند قديم غير مُتغيّر ماليًا يبقى شرعًا `v1` حتى بعد تعديل رأس عملية بيعه.
- `sales_orders.calculation_version`: أي محرك تجميع أنتج إجماليات **الرأس المخزَّنة حاليًا** — تصبح `2` بعد أي تعديل ناجح واحد عبر `update_sales_order()`، لأن هذه الدالة تُعيد حساب الإجماليات الأربعة فعليًا وبلا شرط في كل استدعاء ناجح؛ لا Backfill بلا إعادة حساب فعلية — عملية قديمة لم تُعدَّل إطلاقًا منذ هذا الهوتفكس تبقى رأسها `v1` بشكل صحيح لأن إجمالياتها فعليًا لم تُلمَس بالمحرك الجديد.

**النتيجة المقصودة والصحيحة:** رأس العملية = `v2`، بند A (غير مُتغيّر) = `v1`، بند B (مُعاد حسابه) = `v2` — ضمن نفس العملية، وهذا ليس تناقضًا بل دلالتان مستقلتان تمامًا لكل عمود.

**الإصلاح:** ترحيلة 0081، الجزء ب — `CREATE OR REPLACE` كامل لـ`update_sales_order()` (نفس التوقيع تمامًا، بلا حاجة لـ`DROP`) — نسخة طبق الأصل من 0075 حرفيًا باستثناء سطرين فقط: إضافة `calculation_version = 2,` إلى عبارة `UPDATE public.sales_orders`، وتصحيح `new_values.calculation_version` في سجل `sale.update` إلى `2` بدل تكرار القيمة القديمة (`old_values.calculation_version` يبقى `v_old_order.calculation_version` كما هو — القيمة الفعلية قبل التعديل، صحيحة أصلًا).

**الإثبات:** ملف اختبار جديد بالكامل `supabase/tests/sales_integrity_hotfix_3_2_1.test.sql` (أحادي الجلسة، مُلفوف بمعاملة تُلغى دائمًا): **D** (خط أساس — عملية جديدة بعد الهوتفكس v2 على الرأس والبند معًا، غير متأثرة بهذا الإصلاح)، **A** (رأس محاكى v1 يصبح v2 بعد تعديل وصفي بحت واحد)، **B** (البند غير المتغيّر ماليًا في نفس ذلك التعديل يبقى v1 دون ترقية قسرية)، **E** (تدقيق `sale.update`: `old_values.calculation_version=1`، `new_values.calculation_version=2` — القيمتان الفعليتان، لا تكرار)، **C** (تعديل مالي فعلي لاحق على نفس البند يرفعه إلى v2، ورأس العملية يبقى v2 ولا يرتد). **أُثبِت الاختبار سلبيًا**: تشغيله ضد قاعدة مبنية من 0001–0080 فقط أعاد فعليًا `FAIL A: ... يجب أن يرفعه إلى calculation_version=2 ...، وجد 1` — الخلل الحقيقي المرصود، قبل إعادة بناء القاعدة بـ0081 والتحقق من النجاح.

### البند 4 — عدم تغيير إصلاحات 3.1/3.2 الصحيحة

كل ما طُلب الحفاظ عليه بقي **دون أي تغيير في المنطق**: قفل الكتابة المباشرة على مستوى الجدول (0073)، محرك التكلفة كامل الدقة، تحقق دقة الإدخال على مستوى القاعدة، `row_version` (التزامن التفاؤلي نفسه — 0081 لم تمسّ منطق فحص `p_expected_version` إطلاقًا، فقط أضافت سطرًا لعمود مختلف)، `preview_update_sales_order()`، قوائم التعديل التاريخية-الشاملة، `calculation_version` على مستوى البند، تسميات Sales Read، سياسة تعديل المتجر المعطَّل، لقطات التدقيق الكاملة، حماية الربح، هوية البند الثابتة/الحذف الناعم، أقفال Daily Close، حدود النقل النصي المالي، وعدم استخدام `Number()` JS في أي حساب مالي — كل ملفات اختبار 3.1/3.2 العشرة أُعيد تشغيلها بالكامل ضمن نفس التشغيلة المتسلسلة لهذا الهوتفكس وتمر 100% (انظر القسم التالي).

### البند 5 — التحقق (Verification)

مُوثَّق بالتفصيل وبأرقام فعلية في `TEST_RESULTS_HOTFIX_3_2_1.md`، بما فيه **إثبات سلبي** (Negative Proof) لكل من البندين 2 و3 (والبند 1 عبر اختبار React): بناء قاعدة بيانات من الصفر (81/81 ترحيلة)، اختبار الترقية، إحدى عشرة ملف اختبار SQL في تشغيلة واحدة متسلسلة (**369 نقطة تحقق ناجحة** — 361 من Patch 3.2 + 8 جديدة: L1/L2 في ملف التزامن + 6 في الملف الجديد)، اختبار HTTP/PostgREST حقيقي (37/37، دون تغيير — لا سطح HTTP إضافي لهذا الهوتفكس)، `tsc --noEmit`/`eslint`/`vitest` (47/47، 45 سابقة + 2 جديدتان)/`check:numeric-types`/`next build` جميعًا نظيفة.

### البند 6 — حزمة التسليم

ترحيلة جديدة واحدة: `0081_hotfix_3_2_1_lock_acl_and_order_calculation_version.sql`. اختبار SQL جديد بالكامل: `sales_integrity_hotfix_3_2_1.test.sql`. اختبار SQL مُعدَّل (إضافة أقسام فقط، لا حذف): `sales_integrity_patch_3_1_concurrency.test.sql` (قسما L1/L2). اختبار React جديد بالكامل: `tests/sales-entry-form-conflict-reload.test.tsx`. كود TypeScript مُعدَّل: `src/app/(app)/sales/[id]/edit/page.tsx` (`key={order.row_version}`)، `src/features/sales/components/sales-entry-form.tsx` (إزالة منطق `lastSeenRowVersion` الزائد بعد إصلاح الـ`key`). **لم يتغيّر إطلاقًا:** أي ترحيل من 0001–0080، أي ملف اختبار آخر خارج ما ذُكِر أعلاه، أي جزء آخر من طبقة TypeScript.

**خلاصة الملحق الخامس عشر:** ثلاث نقاط دقيقة ومحدَّدة تمامًا كما وصفها المستخدم، أُغلقت جميعًا — الأولى بإصلاح React بحت (`key`-based remount) مُثبَت بإعادة تصميم دقيقة لآلية إعادة تهيئة الحالة بدل ترقيع جزئي، والثانية والثالثة بترحيلة SQL واحدة (0081) لا تُعدِّل منطق أي إصلاح Patch 3.1/3.2 قائم إطلاقًا، فقط تُصلح ثغرة صلاحيات ضيقة ودلالة عمود واحد. **الأهم:** كل من البندين 2 و3 (والبند 1 عبر اختبار React) لهما إثبات سلبي فعلي — الاختبار الجديد نفسه شُغِّل وفشل بالضبط بالرسالة المتوقعة ضد الكود القديم قبل إصلاحه، لا مجرد اختبار كُتب بعد الإصلاح وينجح تلقائيًا بصرف النظر عن وجود الخلل من عدمه. 369 نقطة تحقق SQL ناجحة، 37 تأكيدًا HTTP حقيقيًا دون انحدار، و47 اختبار Vitest — كلها في تشغيلة واحدة فعلية لا نظرية. **لم تبدأ المرتجعات (Returns) ولا Shipping/Settlements/Inventory ولا أي مرحلة جديدة — العمل متوقف الآن نهائيًا، بانتظار المراجعة النهائية للمستخدم بعد هذا التسليم.**

---

## الملحق السادس عشر — "Phase 4: نواة المرتجعات (Returns Core)" (ترحيلات 0082–0091)

هذا الملحق يوثِّق **Phase 4** كاملة، بناءً على مواصفة المستخدم الصريحة المكوَّنة من 52 بندًا: **"هذه المرحلة Returns Core فقط، مع Refund Tracking الضروري للمرتجعات"**، مع استثناءات صريحة يُمنَع البدء بها الآن — **"لا تبدأ Shipping"**، **"لا تبدأ Settlements"**، **"لا تبدأ Services / Adjustments"**، **"لا تبدأ Inventory"**، **"لا تبدأ Reports/PDF/Excel"**. الشرط الصارم كالمعتاد: **"لا تعدل أي migration من 0001 إلى 0081"** — كل ترحيل جديد بدأ من 0082 فصاعدًا (عشر ترحيلات: 0082–0091). العمل **متوقف الآن نهائيًا**: **"لا تبدأ Shipping أو المرحلة التالية تلقائيًا. انتظر المراجعة والموافقة بعد إرسال ZIP."**

### 1) الترحيلات الجديدة (0082–0091)

| # | الترحيلة | تُضيف |
|---|---|---|
| 0082 | `returns_core_schema.sql` | صلاحيات `returns.reverse`/`returns.record_refund`/`returns.process_closed_day` + منحها للأدوار؛ `acquire_returns_order_lock_exclusive(uuid)` (قفل استشاري جديد، `key1=1004`)؛ جداول `sales_returns`/`sales_return_items`/`sales_return_refund_events` — **صفر سياسات RLS مباشرة لـ`authenticated`**، بما فيها **الفهرس الفريد الجزئي** `sales_return_items_order_item_active_uq` (`unique (sales_order_item_id) where status='active'`) — منع الإرجاع المزدوج مُطبَّق على مستوى القاعدة فعليًا، لا منطق تطبيق فقط. |
| 0083 | `generate_sales_return_number.sql` | SEQUENCE ذرّية + `generate_sales_return_number()` (الصيغة `RET-##########`، مطابقة لِـ`generate_sales_order_number()`). |
| 0084 | `update_sales_order_financial_lock_after_return.sql` | إعادة كتابة كاملة لِـ`update_sales_order()` (نفس توقيع 0075/0081 حرفيًا) — إضافة **القفل المالي**: أي مرتجع فعّال (`status='approved'`) على العملية يمنع أي تعديل مالي (طريقة دفع/قناة تحصيل/تصنيف/عيار/وزن/سعر لأي بند/إضافة أو حذف بند) عبر كل بنود العملية، ويسمح فقط بتعديلات وصفية بحتة (اسم/هاتف العميل، الملاحظات، اسم/وصف/رمز البند). |
| 0085 | `create_sales_return_and_preview.sql` | `compute_sales_return_fee_reversal()` (الصيغة المشتركة الوحيدة لاسترداد العمولة، IMMUTABLE)؛ `create_sales_return()` (نقطة الدخول المعاملاتية الوحيدة، لقطات فقط بلا أي إعادة حساب حي)؛ `preview_sales_return()` (معاينة تقديرية للاستخدام قبل الحفظ). |
| 0086 | `update_pending_sales_return.sql` | `update_pending_sales_return()` — تعديل مرتجع لا يزال "قيد المراجعة" فقط، بتزامن تفاؤلي حقيقي (`row_version`). |
| 0087 | `approve_and_reject_sales_return.sql` | `approve_sales_return()` — المكان الوحيد الذي تُحسَب فيه وتُكتَب أرقام الاسترداد النهائية؛ `reject_sales_return()` — نتيجة نهائية غير فعّالة، حذف ناعم متسلسل لكل بنود المرتجع. |
| 0088 | `reverse_sales_return.sql` | `reverse_sales_return()` — التراجع عن مرتجع معتمد (الانتقال الوحيد الممكن من `approved`؛ `reversed` نهائية بلا تراجع عن التراجع)، مع إبقاء كل الأرقام المحسوبة عند الاعتماد كسجل تاريخي دائم. |
| 0089 | `sales_return_refund_events.sql` | `record_sales_return_refund()` — سجل إضافي في دفتر الاسترداد النقدي الفعلي (مستقل تمامًا عن `approved_refund_amount`)؛ `reverse_sales_return_refund_event()` — إبطال ناعم لسجل استرداد خاطئ. |
| 0090 | `sales_returns_read_rpcs.sql` | `list_sales_returns()`، `get_sales_return()`، `get_returnable_sales_order()` — الأخيرة تدمج "عرض العملية القابلة للإرجاع" و"قائمة البنود القابلة للإرجاع" في استدعاء واحد، مع `order_state` (`full`/`partial`/`not_returned`) **مُشتقّ حيًا دومًا، لا مخزَّنًا أبدًا**. |
| 0091 | `audit_logs_returns_profit_protection.sql` | توسيع سياسة `audit_logs_select` (0072) لتشمل `action LIKE 'return.%'` تحت نفس شرط `audit_logs.view AND sales.view_profit` — بلا صلاحية `returns.view_profit` جديدة. |

### 2) الجداول الجديدة (3) ونموذج الوصول

`sales_returns` (الرأس)، `sales_return_items` (البنود، مرتبطة بهوية ثابتة بـ`sales_order_items.id` — لا `line_no`/تصنيف+وزن)، `sales_return_refund_events` (دفتر الاسترداد النقدي الفعلي، إضافة-فقط منطقيًا). الثلاثة **بصفر سياسات RLS مباشرة لـ`authenticated`** — نفس نموذج `sales_orders`/`sales_order_items` (Phase 3) حرفيًا وللسبب نفسه: إخفاء أعمدة الربح عن أي مسار مهما كان، بما فيه طلب PostgREST مُصاغ يدويًا. كل وصول (قراءة أو كتابة) يمر حصرًا عبر عشر دوال RPC موثوقة (`SECURITY DEFINER`) أعلاه. لا حذف فعلي إطلاقًا في أي من الجداول الثلاثة — `sales_return_items.status` (`active`/`removed`) و`sales_return_refund_events.status` (`active`/`reversed`) يطابقان نمط الحذف الناعم لِـ`sales_order_items` (0067) حرفيًا؛ `sales_returns` نفسها لا تُحذَف إطلاقًا — دورة حياتها (`pending`→`approved`|`rejected`، و`approved`→`reversed`) تُسجَّل بأعمدة `*_at`/`*_by`/`*_reason` مباشرة على نفس الصف، لا بجدول أحداث منفصل.

### 3) الصفحات والمكوّنات الجديدة

`/returns` (قائمة مع فلاتر وأعمدة ربح مشروطة بالصلاحية)، `/returns/new` (بحث عن عملية بيع برقمها ثم اختيار بنودها القابلة للإرجاع)، `/returns/[id]` (تفاصيل + إجراءات دورة الحياة + لوحة الاسترداد النقدي)، `/returns/[id]/edit` (تعديل مرتجع لا يزال قيد المراجعة). مكوّنات: `return-order-search.tsx`، `return-entry-form.tsx` (الإنشاء والتعديل معًا، يعرض معاينة مُؤجَّلة Debounced عبر `preview_sales_return()`)، `return-lifecycle-actions.tsx` (اعتماد/رفض/تراجع، بحوارات سبب إلزامي ومسار إعادة محاولة ليوم مقفل مطابق لنمط Sales)، `refund-events-panel.tsx` (تسجيل/تراجع استرداد نقدي)، `returns-filters.tsx`. طبقة الخلفية: `src/features/returns/{schema,queries,actions}.ts`. رابط "بدء مرتجع" أُضيف أيضًا إلى صفحة تفاصيل عملية البيع (`/sales/[id]`) للتنقل المباشر، خلف صلاحية `returns.create`.

### 4) الصلاحيات الجديدة (3، بالإضافة لثلاث صلاحيات Returns كانت موجودة مسبقًا في `seed.sql` دون استخدام)

`returns.reverse`، `returns.record_refund`، `returns.process_closed_day` (0082) — بنفس منح `returns.approve` تمامًا (Admin + Supervisor + Super Admin). `returns.view`/`returns.create`/`returns.approve` كانت مُعرَّفة مسبقًا (`returns.create` ممنوحة أيضًا لِـ`sales_employee`) دون أي RPC يستهلكها فعليًا — هذه المرحلة هي أول استهلاك حقيقي لها.

### 5) قرارات معمارية اتُّخذت ولم تُحدَّد صراحةً في المواصفة (مع التبرير)

1. **منع الإرجاع المزدوج بفهرس فريد جزئي حقيقي، لا منطق تطبيق فقط:** `unique (sales_order_item_id) where status='active'` على `sales_return_items` — يصمد حتى أمام كتابة خام بدور `service_role` تتجاوز كل RPC، وهو نفس النمط الذي يُفضِّله هذا المشروع دومًا (فهارس استبعاد GIST لنسخ العمولة، إلخ) بدل الاكتفاء بتحقق منطقي. القفل الاستشاري لكل عملية (`acquire_returns_order_lock_exclusive`، `key1=1004`) يُسلسِل كل عمليات دورة حياة المرتجع + فحص `update_sales_order()` الجديد (0084) معًا، مغلقًا سباقًا بين تعديل مالي في Sales واعتماد مرتجع متزامنَين على نفس العملية — مُثبَت فعليًا عبر `dblink` تزامن حقيقي (انظر القسم 8).
2. **حساب من اللقطات فقط (Snapshot-only)، بلا أي استدعاء حي لمُحلِّل سعر/عمولة/ضريبة:** كل رقم تكلفة/ربح في `sales_return_items` يُنسَخ من `sales_order_items` الحالية وقت إنشاء/تعديل المرتجع فقط. الاستثناء الوحيد المتعمَّد: `refund_fee_policy_snapshot` يُقرَأ **حيًا** من `payment_methods.refund_fee_policy` **وقت الاعتماد فقط** — لأنها إعداد أعمال حالي ("ما هي القاعدة السارية الآن")، لا قيمة مالية تاريخية تُحلَّل لتاريخ ماضٍ (فئة مختلفة تمامًا عن `gold_price_for_karat_on_date()`).
3. **قيمتان مستقلتان تمامًا، لا تُخلَطان أبدًا:** "رد المبيعات" (`sales_revenue_reversal_amount`) رقم واحد حتمي يُثبَّت عند الاعتماد؛ "الاسترداد النقدي الفعلي" **ليس عمودًا واحدًا** بل دفتر إضافة-فقط (`sales_return_refund_events`) يُجمَع حيًا — قد يكون جزئيًا أو مرحليًا أو بطريقة دفع مختلفة عن طريقة البيع الأصلية. `approved_refund_amount` هو **الهدف**، ومجموع الدفتر هو **ما حدث فعليًا**؛ الفرق بينهما (`refund_variance`) يُعرَض للمطابقة، لا يُفرَض تلقائيًا للتساوي أبدًا.
4. **استرداد العمولة التراكمي مع امتصاص فارق التقريب عند الاكتمال:** `compute_sales_return_fee_reversal()` تستهلك `payment_methods.refund_fee_policy` (`non_refundable_fee`/`manual`/`full_reversal`/`proportional_reversal`) دون تحويز أي مزوّد دفع بالاسم. الصيغة التناسبية تُستخدَم عادةً، **إلا** عندما يكون هذا الاعتماد هو ما يُكمِل تغطية كل بنود العملية النشطة بمرتجعات فعّالة — عندها يُمتَص كامل الرصيد المتبقي غير المُسترَد بدل الحصة التناسبية، فيُضمَن أن مجموع العمولة المُستردة تراكميًا عبر كل مرتجعات العملية الفعّالة يُطابق تمامًا العمولة الأصلية الكاملة، بلا أي فارق تقريب عالق أبدًا — مُثبَت رياضيًا بمثال محلول (بنود 333.33/333.33/333.34 من إجمالي عمولة 100.00) وباختبار SQL فعلي.
5. **حالة العملية (`full`/`partial`/`not_returned`) مُشتقَّة حيًا دومًا، لا مخزَّنة أبدًا:** تُحسَب في كل استدعاء لِـ`get_returnable_sales_order()` من تغطية البنود الفعلية بمرتجعات "فعّالة" (`status='approved'`) فقط — مرتجع قيد المراجعة لا يُحتسَب، لا يمكن لعميل إرسالها قديمة أو مُزوَّرة.
6. **مرتجع "فعّال"** = `status='approved'` فقط (معتمد وغير متراجَع عنه) — الحالة الوحيدة التي (أ) تحتكر بنودها فعليًا عبر الفهرس الفريد، (ب) تُفعِّل القفل المالي على البيعة الأصلية، (ج) تُحتسَب ضمن تغطية العملية.
7. **المرتجع قد يُعالَج في متجر مختلف عن متجر البيع الأصلي:** `processed_store_id` (لا `sales_orders.store_id`) هو ما يُحدِّد نطاق المتجر وقفل الإغلاق اليومي للمرتجع — عميل قد يُرجِع في فرع غير الذي اشترى منه. الإغلاق اليومي لِـReturns يُعيد استخدام جداول/دوال قفل Sales نفسها (`daily_closings`/`acquire_daily_close_lock_shared/exclusive`) دون جدول إغلاق منفصل.

### 6) التدقيق (Audit) — تصنيف جديد + حماية ربح ممتدة

ثمانِ فعاليات جديدة، مكتوبة صراحةً داخل كل RPC (لا Trigger عام، لنفس سبب Phase 3 §12 القرار 2 — `sales_returns`/`sales_return_items`/`sales_return_refund_events` بلا سياسة كتابة مباشرة إطلاقًا): `return.create`، `return.update`، `return.approve`، `return.reject`، `return.reverse`، `return.refund_recorded`، `return.refund_reversed`، `return.closed_day_override`. ترحيلة 0091 توسِّع بالضبط سياسة `audit_logs_select` القائمة (0072) لتشمل `return.%` تحت نفس شرط `sales.view_profit` — **إعادة استخدام الصلاحية القائمة حرفيًا، لا صلاحية `returns.view_profit` جديدة**، مطابقةً لتوجيه المواصفة الصريح. تسميات عربية جديدة في `src/lib/audit/action-labels.ts` (8 أفعال + كيانا `sales_return`/`sales_return_refund_event`).

### 7) حماية الربح على مستوى القاعدة — نفس آلية Sales حرفيًا

كل دالة قراءة (`get_sales_return`، `list_sales_returns`، `get_returnable_sales_order`) تُخفي المفاتيح الحسّاسة للربح (`gross_profit_reversal_amount`/`payment_fee_reversal_amount`/`net_profit_reversal_amount`/كل لقطة تكلفة على مستوى البند) بشرط `sales.view_profit` — **إعادة استخدام الصلاحية القائمة نفسها بالضبط، لا `returns.view_profit` جديدة**، بنفس نمط Phase 3: المفتاح **غائب تمامًا** من كائن JSON في `get_sales_return()`/`get_returnable_sales_order()` (لا `null`)، و`null` صريح في صفوف `list_sales_returns()` الجدولية.

### 8) الاختبارات — قائمة كاملة وأرقام فعلية

**ملف اختبار جديد بالكامل (أحادي الجلسة):** `supabase/tests/sales_returns_core.test.sql` — عشرة أقسام تغطي: إنشاء/تعديل/معاينة مرتجع (لقطات لا إعادة حساب حية)؛ منع الإرجاع المزدوج (تحقق تطبيقي + فهرس فريد كخط دفاع ثانٍ)؛ اعتماد/رفض/تراجع بتزامن تفاؤلي حقيقي؛ استرداد العمولة التراكمي مع امتصاص فارق التقريب (المثال المحلول 333.33/333.33/333.34)؛ القفل المالي الجديد في `update_sales_order()` (0084)؛ الإغلاق اليومي والمتجر المعالِج المختلف عن متجر البيع؛ دفتر الاسترداد النقدي الفعلي وتراجعه؛ حماية الربح؛ حماية تدقيق `return.%`. أُثبِت **صفر سياسات RLS مباشرة** بمحاولة `SELECT` مباشر كـ`authenticated` (يُعيد صفوفًا فارغة صمتًا، لا خطأ) — نفس نمط اكتشاف Phase 3 §باستخدام `reset role` كإثبات مضاد.

**ملف اختبار تزامن جديد بالكامل (`dblink` حقيقي، لا محاكاة تسلسل استدعاءات):** `supabase/tests/sales_returns_concurrency.test.sql` — سيناريو **R1** (اتصالان متزامنان يحاولان إنشاء مرتجع على نفس البند في نفس اللحظة — يُثبَت الحجب الفعلي عبر الفهرس/القفل، لا مجرد ترتيب استدعاءات تسلسلي، ونجاح واحد فقط مع رفض واضح للآخر)، و**R2** (سباق إغلاق يوم مقابل إنشاء مرتجع لنفس المتجر/التاريخ). كلا السيناريوهين أثبتا الحجب الحقيقي عبر استقصاء `dblink_is_busy` قبل الالتزام، لا فقط ترتيب نجاح متسلسل.

**اختبار HTTP/PostgREST الحقيقي (`scripts/postgrest-http-test.mjs`):** وُسِّع بقسم "Part 7 — Phase 4 Returns Core" جديد — دورة حياة مرتجع كاملة (`pending`→`approved`→استرداد نقدي→تراجع) عبر HTTP فعلي: `create_sales_return()`/`preview_sales_return()` تُرجِعان كل قيمة مالية كنص؛ منع الإرجاع المزدوج مرفوض فعليًا عبر HTTP؛ `order_state`/`returnable` يتغيّران فعليًا عبر دورة الحياة؛ حماية الربح في `get_sales_return()` (غياب تام)/`list_sales_returns()` (`null`) لممثِّل ثانٍ حقيقي بلا `sales.view_profit`؛ **القفل المالي الجديد (0084) يرفض فعليًا** تعديلًا ماليًا على العملية بعد اعتماد مرتجع عليها؛ دفتر الاسترداد النقدي وتراجعه؛ حماية تدقيق `return.%` (مطابقة تمامًا لإثبات `sale.%` في Part 4). → **22 تأكيدًا جديدًا، كلها ناجحة** (59/59 إجمالي الملف، بلا انحدار على أي تأكيد سابق).

### 9) الفحص النهائي الكامل — نتائج فعلية (نُفِّذ في هذه الجلسة)

- إعادة بناء قاعدة اختبار Postgres محلية **من الصفر بالكامل**: حذف `gold_erp_test`، إعادة إنشائها، `local_harness_setup.sql`، **كل الترحيلات 0001–0091 بالترتيب دون توقف** (91/91 نجحت)، ثم `supabase/seed.sql` (نجح).
- كل ملفات اختبار SQL القائمة (12 ملفًا، شاملة `rls_and_permissions`/`financial_master_data`/سلسلة `financial_integrity_*`/`sales_core`/سلسلة `sales_integrity_*`) أُعيد تشغيلها **ضمن نفس التشغيلة المتسلسلة** على القاعدة نفسها → **نجحت جميعًا، صفر انحدار**.
- `supabase/tests/sales_returns_core.test.sql` (جديد) → **نجح بالكامل**.
- `supabase/tests/sales_returns_concurrency.test.sql` (جديد، `dblink` حقيقي) → **نجح بالكامل**، شاملًا التنظيف الصريح في نهايته.
- اختبار الترقية (`scripts/run_upgrade_test.sh`، يُطبِّق 0040–0091 تلقائيًا) → **نجح، بلا أي تعديل توقعات مطلوب** (Phase 4 لا تلمس أي صلاحية/جدول من نطاق اختبار الترقية).
- اختبار HTTP/PostgREST الحقيقي (`scripts/run_postgrest_http_test.sh`) → **نجح، 59/59 تأكيد** (37 قائمة + 22 جديدة لِـPhase 4)، ضد ثنائي PostgREST v12.2.3 حقيقي عبر HTTP فعلي.
- `npm run check:numeric-types` → **نجح، 39/39 عمود NUMERIC مطابق** (يشمل 16 عمودًا جديدًا في `sales_returns`/`sales_return_items`/`sales_return_refund_events`).
- `npx tsc --noEmit` → **صفر أخطاء**.
- `npx eslint` → **صفر أخطاء وتحذيرات**.
- `npx vitest run` → **47/47 ناجح عبر 6 ملفات** (بلا تغيير — Phase 4 لم يمسّ منطق Decimal الحالي).
- `npm run build` (Next.js/Turbopack) → **نجح**، **بزيادة 4 مسارات Returns**: `/returns`، `/returns/new`، `/returns/[id]`، `/returns/[id]/edit`.

### 10) الملفات/الترحيلات التي تغيَّرت أو أُضيفت في Phase 4 (قائمة كاملة)

**ترحيلات جديدة (10):** `0082_returns_core_schema.sql`، `0083_generate_sales_return_number.sql`، `0084_update_sales_order_financial_lock_after_return.sql`، `0085_create_sales_return_and_preview.sql`، `0086_update_pending_sales_return.sql`، `0087_approve_and_reject_sales_return.sql`، `0088_reverse_sales_return.sql`، `0089_sales_return_refund_events.sql`، `0090_sales_returns_read_rpcs.sql`، `0091_audit_logs_returns_profit_protection.sql`.

**اختبارات SQL جديدة بالكامل:** `supabase/tests/sales_returns_core.test.sql`، `supabase/tests/sales_returns_concurrency.test.sql`.

**سكربتات HTTP مُعدَّلة (إضافة فقط، لا حذف):** `scripts/postgrest-http-test.mjs` (قسم Part 7 الجديد)، `supabase/tests/postgrest_http_test_setup.sql` (منح صلاحيات Returns للممثِّلَين القائمَين، تحويل `http_test_pm` إلى `proportional_reversal`).

**كود TypeScript جديد بالكامل:** `src/features/returns/{schema,queries,actions}.ts`، `src/features/returns/components/{return-order-search,return-entry-form,return-lifecycle-actions,refund-events-panel,returns-filters}.tsx`، `src/app/(app)/returns/page.tsx` (استبدال الواجهة المؤقتة "قريبًا")، `src/app/(app)/returns/new/page.tsx`، `src/app/(app)/returns/[id]/page.tsx`، `src/app/(app)/returns/[id]/edit/page.tsx`.

**كود TypeScript مُعدَّل:** `src/types/database.ts` (أنواع الجداول الثلاثة الجديدة + إحدى عشرة دالة جديدة)، `src/lib/permissions/constants.ts` (3 مفاتيح صلاحيات جديدة)، `src/lib/audit/action-labels.ts` (8 تسميات فعل + كيانان جديدان)، `src/lib/constants.ts` (`ROUTES.returnsNew`)، `src/components/layout/nav-items.ts` (إزالة `comingSoon` عن رابط المرتجعات)، `src/app/(app)/sales/[id]/page.tsx` (زر "بدء مرتجع" خلف صلاحية `returns.create`).

**لم يتغيّر إطلاقًا:** أي ترحيل من 0001–0081، أي اختبار SQL قائم (منطقًا)، `src/app/(app)/sales/page.tsx`/`/sales/new/page.tsx`/`/sales/[id]/edit/page.tsx`.

**خلاصة الملحق السادس عشر:** نواة مرتجعات كاملة وظيفيًا فوق أساس Sales الموجود — رقم مرتجع فريد غير قابل للتزوير، منع إرجاع مزدوج مُطبَّق فعليًا على مستوى القاعدة (فهرس فريد جزئي + قفل استشاري، مُثبَت تحت تزامن حقيقي)، حساب من اللقطات فقط بلا أي إعادة تحليل حي لسعر/عمولة/ضريبة، دورة حياة مرتجع كاملة (قيد المراجعة → معتمد/مرفوض، ومعتمد → متراجَع عنه) بتزامن تفاؤلي حقيقي، استرداد عمولة تراكمي يمتص فارق التقريب رياضيًا، قفل مالي جديد يحمي البيعة الأصلية بعد اعتماد أي مرتجع فعّال عليها، دفتر استرداد نقدي فعلي مستقل تمامًا عن الهدف المحسوب، حماية ربح على مستوى القاعدة تصمد أمام أي مسار تجاوز (مُثبَتة الآن عبر HTTP حقيقي أيضًا)، وتصنيف تدقيق عربي شامل يعيد استخدام صلاحية `sales.view_profit` القائمة دون صلاحية جديدة. **لم تبدأ Shipping ولا Settlements ولا Services/Adjustments ولا Inventory ولا Reports/PDF/Excel — العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP هذا الملحق.**

---

## الملحق السابع عشر — "Returns Integrity Patch 4.1": تصحيح شامل لِـ22 بندًا فوق Phase 4 Returns Core (ترحيلات 0092–0098)

هذا الملحق يوثِّق **Patch 4.1** كاملة، بناءً على مواصفة المستخدم الصريحة المكوَّنة من 22 بندًا تُصحِّح Phase 4 Returns Core المُسلَّمة سابقًا (الملحق السادس عشر). القيود كالمعتاد وبقيت سارية طوال هذا الملحق: **"لا تبدأ Shipping"**، **"لا تبدأ Settlements"**، **"لا تبدأ Services / Adjustments"**، **"لا تبدأ Inventory"**، **"لا تبدأ Reports"**، **"لا تعدل migrations من 0001 إلى 0091"**، **"كل الإصلاحات تبدأ من 0092 وما بعده"**، **"حافظ على Returns الموجودة ولا تعيد بناء المرحلة من الصفر"**. سبع ترحيلات جديدة فقط (0092–0098)، بلا لمس حرفي واحد لأي ترحيلة من 0001 إلى 0091. العمل **متوقف الآن نهائيًا**: **"لا تبدأ Shipping. انتظر المراجعة."**

### 1) الترحيلات الجديدة (0092–0098) — سبع ترحيلات فوق Phase 4 الأصلية دون تعديلها

| # | الترحيلة | تُضيف |
|---|---|---|
| 0092 | `returns_integrity_patch_4_1_schema.sql` | الحقول التجارية الجديدة (`collection_state`، `non_shipping_deduction_amount`، `deduction_reason`، `returned_original_sale_amount`، `recovered_original_cost_amount`، `net_sales_profit_adjustment`، `refund_difference_reason`)؛ تتبُّع حالة القطعة المرتجعة (`condition`، `item_return_reason`، `item_notes` — تاريخي بحت، بلا أي جدول Inventory)؛ انقسام `sales_return_items.status` (عضوية قيد المراجعة) عن `is_effective` (مطالبة فعّالة حصرية) بفهرس فريد جزئي جديد `sales_return_items_effective_claim_uq`؛ عمود `included_in_decision` لحفظ التاريخ؛ `source_sale_row_version`/`sale_date_snapshot` (حارس اللقطة القديمة)؛ تواريخ أعمال مستقلة لكل فعل (`reversal_business_date` وما يقابلها على دفتر الاسترداد)؛ حقول تسوية الاسترداد النهائية (`refund_finalized_at/by`, `refund_final_variance_reason`)؛ `validate_money_scale()` (رفض أي قيمة مالية بأكثر من رقمين عشريين)؛ **منطق Backfill رجعي** لكل صف Returns قائم مسبقًا (Section 20 — مُثبَت في القسم 9 أدناه). |
| 0093 | `create_and_preview_sales_return_patch_4_1.sql` | إعادة كتابة `create_sales_return()`/`preview_sales_return()` — `p_items` يتحوَّل من `uuid[]` إلى `jsonb` (يحمل `condition`/`item_return_reason`/`item_notes` لكل بند)؛ يضيف `p_expected_sale_version`/`p_collection_state`/`p_approved_refund_amount`/`p_refund_difference_reason`؛ دالة جديدة `refresh_pending_sales_return_from_sale()` — الطريقة الصريحة الوحيدة لتحديث لقطة مرتجع قيد المراجعة بعد تعديل البيعة الأصلية (لا إعادة التقاط ضمنية أبدًا). |
| 0094 | `update_pending_sales_return_patch_4_1.sql` | نفس تغيير الشكل (`p_items` jsonb + الحقول التجارية الجديدة قابلة للتعديل) لِـ`update_pending_sales_return()`؛ فحص الإرجاع المزدوج الجديد (Section 5) يحظر فقط على مطالبة فعّالة، لا على مجرد مرجع مرتجع آخر قيد المراجعة. |
| 0095 | `approve_and_reject_sales_return_patch_4_1.sql` | إعادة كتابة `approve_sales_return()` — ترتيب القفل الآمن العالمي الجديد (Section 19)، إعادة التحقق النهائي من حارس اللقطة القديمة، دعم `approved_refund_amount=0` مع الفصل الكامل عن `customer_never_received`، قيد `CHECK` صريح يفرض استردادًا صفريًا عند `customer_never_received + not_collected`، حساب مجموعة حقول Section 12 كاملة؛ `reject_sales_return()` مُعدَّلة لحفظ التاريخ (`included_in_decision=true`) بدل الحذف الناعم المدمِّر للتاريخ. |
| 0096 | `reverse_sales_return_patch_4_1.sql` | إعادة كتابة `reverse_sales_return()` — لا تُسلسِل `status='removed'` على البنود بعد الآن (Section 6)، فقط تُطلِق `is_effective`؛ تاريخ عمل مستقل (`reversal_business_date`) بفحص إغلاق يومي خاص به. |
| 0097 | `return_refund_events_patch_4_1.sql` | `record_sales_return_refund()` يرفض (لا يُقرِّب) أي قيمة بأكثر من رقمين عشريين؛ تاريخ عمل مستقل لكل من التسجيل والتراجع، كل بفحص إغلاق يومي خاص به؛ دالة جديدة `finalize_sales_return_refund()` — تُقفِل تسوية الاسترداد نهائيًا (استخدام واحد فقط، يتطلب سبب فارق عند عدم التطابق). |
| 0098 | `returns_read_rpcs_patch_4_1.sql` | إعادة كتابة `list_sales_returns()`/`get_sales_return()`/`get_returnable_sales_order()` — فلاتر جديدة (متجر أصلي، رقم طلب، سيناريو)؛ عرض مجموعة حقول Section 12 الكاملة شاملة `adjusted_order_net_sales_profit`؛ `refund_reconciliation_state` مُشتقَّة؛ فحصية الظهور الجديدة `status='active' OR included_in_decision=true`؛ `returnable`/`order_state` مُشتقَّتان الآن من `is_effective` حصرًا لا من أي مرجع قيد المراجعة؛ نطاق VISIBLE (لا OPERABLE) للتصحيحات التاريخية عبر `user_visible_store_ids()`. |

### 2) لماذا رقعة كاملة فوق Phase 4 المُسلَّمة، لا إعادة بناء

المستخدم طلب صراحةً **"حافظ على Returns الموجودة ولا تعيد بناء المرحلة من الصفر"**. كل ترحيلة من 0092–0098 هي `CREATE OR REPLACE` لتوقيع دالة قائمة من 0085–0090 (يتغيَّر التوقيع فقط حيث تتطلَّبه المواصفة الجديدة صراحةً)، أو `ALTER TABLE` إضافي بحت — نفس نمط 0081/0084 اللذين أعادا كتابة `update_sales_order()` أكثر من مرة عبر تاريخ هذا المشروع. الجداول الثلاث (`sales_returns`/`sales_return_items`/`sales_return_refund_events`) بأعمدتها القديمة كلها **لم تُحذَف أو تُعَد تسميتها إطلاقًا** — فقط أُضيفت أعمدة جديدة (كلها `NOT NULL` بقيمة افتراضية صريحة أو Backfill رجعي فوري في 0092 نفسها، فلا تعطُّل لأي صف قائم). القفل الاستشاري (`acquire_returns_order_lock_exclusive`، `key1=1004`) بقي كما هو حرفيًا دون أي تعديل.

### 3) قرارات معمارية اتُّخذت ولم تُحدَّد صراحةً في المواصفة (مع التبرير)

1. **انقسام العضوية عن المطالبة الفعّالة (Section 5) — لا استبدال الفهرس الفريد، بل تعميق دلالته:** الفهرس الفريد الجزئي القديم لِـPhase 4 (`sales_return_items_order_item_active_uq`، `unique (sales_order_item_id) where status='active'`) كان يمنع أي بند من الظهور في أكثر من مرتجع نشط واحد — حتى لو كان المرتجعان مجرد "قيد المراجعة" ولم يُبتّ في أي منهما بعد. هذا يمنع تعدد الموظفين من تسجيل مطالبات مرشَّحة على نفس البند حتى قبل أي قرار إداري، وهو أضيق مما تتطلَّبه المواصفة فعليًا. الحل: عمود `is_effective` جديد + فهرس فريد جزئي **جديد** عليه (`sales_return_items_effective_claim_uq`، `unique (sales_order_item_id) where is_effective=true`) — يحل محل الفهرس القديم في دور "منع الازدواج"، بينما `status` (`active`/`removed`) يبقى بمعناه الأصلي (عضوية البند داخل مرتجعه هو، لا حصرية عبر المرتجعات). النتيجة: عدة مرتجعات قيد المراجعة تتعايش على نفس البند بأمان (Scenario A)، واعتماد أي منها يُطلِق الفهرس الفريد الجديد فيمنع اعتماد الباقي تلقائيًا (Scenario B) — بلا أي حاجة لمنطق تطبيقي يفحص "هل يوجد مرتجع آخر قيد المراجعة على هذا البند" (كان هذا الفحص هو مصدر التقييد الزائد أصلًا).
2. **ترتيب القفل الآمن العالمي (Section 19) موحَّد ومُوثَّق صراحةً، لا مُستنتَجًا ضمنيًا:** `approve_sales_return()` (0095) تحتاج قفل صف `sales_returns` + صف `sales_orders` + القفل الاستشاري + صفوف `sales_order_items`. `update_sales_order()` (0084، غير مُعدَّلة في هذه الرقعة) تحتاج نفس المجموعة تقريبًا. الترتيب المُعتمَد الموحَّد في كل نقطة دخول جديدة: **صف `sales_returns` FOR UPDATE ← صف `sales_orders` FOR UPDATE ← القفل الاستشاري (1004) ← صفوف `sales_order_items` FOR UPDATE ORDER BY id**. تأكَّد بقراءة مباشرة لجسمي الدالتين (0084 و0095) أن كلتيهما تحجزان صف `sales_orders` **قبل** القفل الاستشاري بنفس الترتيب تمامًا — وهذا بالضبط ما يمنع الطريق المسدود بين الدالتين عند التسابق على نفس الطلب، مُثبَت تجريبيًا بسيناريو تزامن حقيقي جديد (R3، انظر القسم 8).
3. **Backfill رجعي داخل 0092 نفسها، لا سكربت ترقية منفصل:** بما أن Phase 4 كانت مُسلَّمة فعليًا وقد تحمل بيانات إنتاج حقيقية، لا يمكن الافتراض أن الجداول فارغة وقت تطبيق هذه الرقعة. `ALTER TABLE ... ADD COLUMN` وحدها غير كافية لأعمدة مثل `is_effective`/`included_in_decision`/`source_sale_row_version` التي تحمل معنى مُشتقًّا من الحالة الحالية لكل صف — فتضمَّنت 0092 `UPDATE` صريحًا فوريًا يُعيد بناء هذه القيم لكل صف Returns قائم مسبقًا بناءً على `status` الحالي وقت الترحيل (تفصيل الاشتقاق في القسم 9). هذا يضمن أن أي بيانات Phase 4 حقيقية قبل هذه الرقعة تستمر بالعمل الصحيح فورًا دون أي خطوة يدوية إضافية بعد `psql -f 0092...sql`.
4. **الفصل الصارم بين قاعدة `customer_never_received` وقاعدة فرق الاسترداد العامة:** المواصفة تطلب سلوكين مختلفين تمامًا يمكن الخلط بينهما بسهولة: (أ) قيد `CHECK` صريح على مستوى الجدول يفرض `approved_refund_amount=0` **حصرًا** عندما `scenario='customer_never_received' AND collection_state='not_collected'` — رفض فوري بلا استثناء، لا "يحتاج سببًا" بل ممنوع رياضيًا. (ب) قاعدة Section 1 عامة مستقلة: أي `approved_refund_amount` يختلف عن انعكاس الإيراد التقديري/الفعلي (حتى لو صفر مقابل صفر تقديري مختلف) يتطلَّب `p_refund_difference_reason` صريحًا. القاعدتان مُطبَّقتان بترتيب فحص منفصل تمامًا داخل `create_sales_return()`/`update_pending_sales_return()`/`approve_sales_return()` — الأولى قيد `CHECK` على الجدول (تصمد حتى أمام كتابة `service_role` خام)، والثانية تحقُّق تطبيقي داخل الدالة نفسها (تحتاج القيمة التقديرية/الفعلية المحسوبة حيًا لتقارن بها).
5. **VISIBLE لا OPERABLE للتصحيحات التاريخية (Section 13) — تمييز مُتعمَّد عن نمط الصلاحيات المعتاد:** بقية المشروع يستخدم `user_operable_store_ids()` (المتاجر النشطة فقط التي يملك المستخدم صلاحية تشغيلية عليها) كنطاق قياسي لأي كتابة. لكن رفض/تراجع/تسجيل استرداد/تراجع استرداد على مرتجع **قائم بالفعل** ليست عمليات تشغيلية جديدة على متجر — هي تصحيحات على سجل تاريخي حدث فعلًا، وقد يُغلَق أو يُعطَّل المتجر لاحقًا لأسباب إدارية لا علاقة لها بصحة السجل التاريخي. لذلك تستخدم هذه العمليات الأربع فقط `user_visible_store_ids()` (كل متجر مُنِح المستخدم صلاحية عليه ولو تاريخيًا، شاملة المُعطَّلة) — بينما **الإنشاء** (`create_sales_return()`) يبقى يتطلَّب نطاقًا تشغيليًا فعليًا (منطقيًا: لا يمكن بدء مرتجع جديد في متجر مُعطَّل).
6. **تسوية الاسترداد النهائية (`finalize_sales_return_refund()`) مفهوم منفصل تمامًا عن `approved_refund_amount`، لا استبدال له:** `approved_refund_amount` يبقى **الهدف** المحدَّد عند الاعتماد (لا يتغيَّر بعده أبدًا). دفتر `sales_return_refund_events` يبقى **ما حدث فعليًا** (قد يتغيَّر بإضافة/تراجع أحداث). `finalize_sales_return_refund()` إضافة ثالثة مستقلة: قفل صريح لمرة واحدة يُعلِن "لن يتغيَّر شيء بعد الآن" — يُفرَّق فيها فورًا بين `finalized_matched` (الهدف = الفعلي) و`finalized_with_variance` (يتطلَّب `refund_final_variance_reason`)، بينما `refund_reconciliation_state` قبل أي تسوية نهائية يبقى `pending` (أو `not_applicable` لمرتجع لم يُعتمَد/يُتراجَع عنه بعد) — قيمة مُشتقَّة حيًا دومًا، لا عمودًا مخزَّنًا.

### 4) التدقيق (Audit) — إضافة واحدة فقط، إعادة استخدام صريحة لبقية التصنيف

فعل جديد واحد فقط: `return.refund_finalized` (مُضاف إلى `src/lib/audit/action-labels.ts`: "تسوية الاسترداد النقدي للمرتجع"). دالة التحديث الجديدة `refresh_pending_sales_return_from_sale()` **لا تُنشئ فعل تدقيق جديدًا** — تُسجِّل كـ`return.update` القائم أصلًا (Phase 4)، لأنها تعديل على نفس السجل بنفس الطبيعة (تحديث لقطة). سياسة `audit_logs_select` الموسَّعة في 0091 (`action LIKE 'return.%'` تحت شرط `sales.view_profit`) **تبقى دون أي تعديل** — تشمل `return.refund_finalized` الجديد تلقائيًا بحكم النمط `return.%`، مُثبَت صراحةً (Scenario P، القسم 8).

### 5) حماية الربح — امتداد مجموعة الحقول الحساسة دون تغيير الآلية

نفس الآلية القائمة من Phase 4 (المفتاح **غائب تمامًا** من JSON في `get_sales_return()`/`get_returnable_sales_order()` بلا `sales.view_profit`، لا `null`؛ و`null` صريح في `list_sales_returns()`) تمتد الآن لتغطي كل حقول Section 12 الجديدة: `recovered_original_cost_amount`، `net_sales_profit_adjustment`، `adjusted_order_net_sales_profit`. لا صلاحية جديدة — نفس `sales.view_profit` القائمة حرفيًا.

### 6) الحقول التجارية والدلالات الجديدة (ملخَّص Section 1–14)

- **`collection_state`** (`collected`/`not_collected`) — مستقل عن `scenario`، يُخزَّن كقيمة enum أول-درجة، لا نصًّا حرًّا داخل الملاحظات.
- **`non_shipping_deduction_amount`/`deduction_reason`** — خصم يدوي إضافي لا علاقة له بالشحن (خارج نطاق Shipping المُستبعَد صراحةً)، يتطلَّب سببًا إن كان غير صفري.
- **`returned_original_sale_amount`** — القيمة الأصلية للبند وقت البيع (لقطة، لا إعادة حساب).
- **`recovered_original_cost_amount`/`net_sales_profit_adjustment`/`adjusted_order_net_sales_profit`** — مجموعة حقول الأثر المالي الكاملة (Section 12)، مقروءة حصرًا عبر RPCs قراءة (Section 12)، خاضعة لحماية الربح.
- **حالة القطعة المرتجعة** (`condition`/`item_return_reason`/`item_notes`) — تاريخي بحت، مُتحقَّق منه صراحةً في الاختبارات (Scenario N) أنه **لا يلمس أي جدول Inventory إطلاقًا** — المرحلة المُستبعَدة صراحةً بقيت غير مُبدوءة تمامًا.
- **`source_sale_row_version`/`sale_date_snapshot`** — حارس اللقطة القديمة: أي تعديل على البيعة الأصلية بعد إنشاء المرتجع (حتى لو وصفيًا) يرفع `row_version`، فيُرفَض اعتماد المرتجع صراحةً حتى يُحدَّث عبر `refresh_pending_sales_return_from_sale()` (Scenario I).
- **`return_date >= sale_date`** — قيد `CHECK` صريح على الجدول (Scenario H).
- **`refund_fee_policy` — `full_reversal` مُصحَّحة:** صفر استرداد عمولة على أي مرتجع جزئي، امتصاص الرصيد الكامل (لا حصة تناسبية) فقط عند اكتمال التغطية (Scenario J).

### 7) التوافق الأمامي (TypeScript/React) — قائمة كاملة

`src/types/database.ts` (أنواع الجداول الثلاثة والدوال الإحدى عشرة مُحدَّثة لكل حقل وتوقيع جديد)؛ `src/features/returns/schema.ts`/`actions.ts` (Zod + Server Actions لكل حقل جديد، شاملة `refreshPendingSalesReturnFromSaleAction`/`finalizeSalesReturnRefundAction`)؛ `refund-events-panel.tsx` (شارة حالة التسوية، حوار `FinalizeRefundDialog` جديد، تواريخ أعمال مستقلة بحوارات إغلاق يوم متطابقة لنمط `return-lifecycle-actions.tsx` القائم)؛ `return-entry-form.tsx` (كل الحقول الجديدة، معاينة عبر نفس دالة `preview_sales_return()` المستخدَمة فعليًا في الاعتماد — لا مسار حساب مزدوج)؛ `src/app/(app)/returns/[id]/page.tsx` (عرض كل حقل جديد، شامل عمود "حالة القطعة")؛ `src/app/(app)/returns/page.tsx` (فلاتر Section 14 الجديدة)؛ `src/lib/audit/action-labels.ts` (تسمية `return.refund_finalized`). صفحة `src/app/(app)/returns/[id]/edit/page.tsx` لم تحتَج أي تعديل — تعتمد على أنواع `ExistingReturn`/`ReturnableOrder` المُحدَّثة مركزيًا في `return-entry-form.tsx`. أثناء العمل أُصلِح أيضًا خطأ ESLint حقيقي (`react-hooks/set-state-in-effect`) في `return-entry-form.tsx` بتحويل `useEffect` كان يستدعي `setApprovedRefundAmount` بناءً على تغيّر `scenario`/`collectionState` إلى معالِجَي `onValueChange` صريحين — لا علاقة له بمنطق Patch 4.1 المالي، اكتُشِف أثناء `npx eslint .` وأُصلِح فورًا.

### 8) الاختبارات — قائمة كاملة وأرقام فعلية (نُفِّذت في هذه الجلسة)

**`supabase/tests/sales_returns_core.test.sql` — أُعيد كتابته بالكامل** (18 قسمًا، يغطي كل ما كان يُغطّيه ملف Phase 4 الأصلي + سيناريوهات Patch 4.1 الإلزامية الستة عشر A–P) → **54/54 نقطة تحقق ناجحة**.

**`supabase/tests/sales_returns_concurrency.test.sql` — أُعيد كتابته بالكامل** (تزامن حقيقي عبر `dblink`) → **R1/R2/R3، 3/3 سيناريوهات ناجحة**:
- **R1** — تعايش عضوية "قيد المراجعة" (بلا سباق) ثم حصرية "فعّال" تحت سباق حقيقي: اتصال A يعتمد أول مرتجعين قيد المراجعة على نفس البند ويُبقي معاملته مفتوحة، اتصال B يحاول اعتماد الثاني بالتوازي — حجب فعلي (مُثبَت عبر `dblink_is_busy`)، ثم رفض واضح بعد التزام A (فهرس المطالبة الفعّالة الفريد).
- **R2** — سباق إغلاق يوم مقابل `create_sales_return()` بتوقيع jsonb الجديد — حجب فعلي، مطابق تمامًا لآلية Sales.
- **R3 (سيناريو جديد بالكامل)** — إثبات ترتيب القفل الآمن العالمي (Section 19): اعتماد مرتجع (اتصال A) متزامن مع `update_sales_order()` وصفي بحت (اتصال B) على نفس الطلب — حجب فعلي على قفل صف `sales_orders`، **لا طريق مسدود أبدًا** (لا `SQLSTATE 40P01`، لا رسالة تحمل كلمة deadlock).

**اختبار HTTP/PostgREST الحقيقي (`scripts/postgrest-http-test.mjs`):** قسم "Part 7 — Returns" أُعيد كتابته بالكامل ليطابق توقيعات وسلوك Patch 4.1 → **64/64 تأكيدًا ناجحًا** إجمالي الملف بلا انحدار على أي تأكيد سابق، شاملًا اختبارات جديدة صريحة لمرتجعَين قيد المراجعة على نفس البند (مقبول)، رفض اعتماد الثاني بعد اعتماد الأول، رفض استرداد بأكثر من رقمين عشريين، `finalize_sales_return_refund()` إلى `finalized_matched`، وبقاء بند مرتجع متراجَع عنه ظاهرًا عبر `get_sales_return()`.

**إثبات سلامة الترقية على بيانات Returns حقيقية سابقة لهذه الرقعة (Section 20):** بُنِيت قاعدة حتى 0091 + `seed.sql`، ثم أُنشِئت عليها بيانات Returns حقيقية بتوقيعات الدوال القديمة في الحالات الأربع (`pending`/`approved` مع استرداد جزئي/`rejected`/`reversed`)، ثم طُبِّقت 0092–0098 فوقها — تحقَّق Backfill الرجعي بشكل صحيح تمامًا لكل صف، وتاريخ البند (Section 6) نجا من الترقية رغم الحذف الناعم القديم عند الرفض/التراجع. تفصيل كامل بالأرقام في `TEST_RESULTS_PATCH_4_1.md`، القسم 3.

**بقية سطح الاختبار (12 ملفًا قائمًا مسبقًا، غير مُعدَّلة منطقيًا):** أُعيد تشغيلها بالكامل ضمن نفس التشغيلة المتسلسلة على قاعدة 0001–0098 → **370/370 نقطة تحقق سابقة ناجحة، صفر انحدار** (شاملة `run_upgrade_test.sh` العام، غير المتأثر بهذه الرقعة).

**فحوصات الطبقة الأمامية:** `npx tsc --noEmit` → صفر أخطاء. `npx eslint .` → صفر أخطاء وتحذيرات. `npx vitest run` → 47/47 عبر 6 ملفات، بلا تغيير. `npm run check:numeric-types` → **43/43 عمود NUMERIC مطابق** (4 أعمدة جديدة عن Phase 4: `non_shipping_deduction_amount`/`returned_original_sale_amount`/`recovered_original_cost_amount`/`net_sales_profit_adjustment`). `npm run build` (Next.js/Turbopack) → نجح، بلا مسارات جديدة (توسيع نفس مسارات Returns الأربعة القائمة).

**المجموع الكلي لهذه الجلسة: 427 نقطة تحقق/سيناريو SQL ناجحة (370 سابقة بصفر انحدار + 57 جديدة/مُعاد فحصها لِـPatch 4.1)، 64 تأكيدًا HTTP حقيقيًا، 47 اختبار Vitest، وفحوصات `tsc`/`eslint`/`build`/`numeric-types` نظيفة بالكامل — كلها من تشغيلات فعلية في هذه الجلسة، لا أرقام مفترَضة.** التفصيل الكامل في `TEST_RESULTS_PATCH_4_1.md`.

### 9) الملفات/الترحيلات التي تغيَّرت أو أُضيفت في Patch 4.1 (قائمة كاملة)

**ترحيلات جديدة (7):** `0092_returns_integrity_patch_4_1_schema.sql`، `0093_create_and_preview_sales_return_patch_4_1.sql`، `0094_update_pending_sales_return_patch_4_1.sql`، `0095_approve_and_reject_sales_return_patch_4_1.sql`، `0096_reverse_sales_return_patch_4_1.sql`، `0097_return_refund_events_patch_4_1.sql`، `0098_returns_read_rpcs_patch_4_1.sql`.

**اختبارات SQL مُعاد كتابتها بالكامل:** `supabase/tests/sales_returns_core.test.sql`، `supabase/tests/sales_returns_concurrency.test.sql`.

**سكربتات HTTP مُعدَّلة (قسم Part 7 أُعيد كتابته بالكامل، لا حذف لبقية الأقسام):** `scripts/postgrest-http-test.mjs`.

**كود TypeScript مُعدَّل:** `src/types/database.ts`، `src/features/returns/schema.ts`، `src/features/returns/actions.ts`، `src/features/returns/components/refund-events-panel.tsx`، `src/features/returns/components/return-entry-form.tsx`، `src/app/(app)/returns/[id]/page.tsx`، `src/app/(app)/returns/page.tsx`، `src/lib/audit/action-labels.ts`.

**لم يتغيَّر إطلاقًا:** أي ترحيل من 0001–0091 (شاملة كل ترحيلات Phase 4 الأصلية 0082–0091)، `src/app/(app)/returns/[id]/edit/page.tsx`، `src/app/(app)/returns/new/page.tsx`، `src/features/returns/queries.ts`، `src/features/returns/components/{return-order-search,return-lifecycle-actions,returns-filters}.tsx`، أي اختبار SQL آخر خارج ما ذُكِر أعلاه (منطقًا)، أي جزء آخر من طبقة TypeScript، القفل الاستشاري `acquire_returns_order_lock_exclusive` (بقي كما هو حرفيًا).

**خلاصة الملحق السابع عشر:** تصحيح شامل لِـ22 بندًا فوق Phase 4 Returns Core المُسلَّمة، دون إعادة بناء أي جزء منها ودون لمس أي ترحيلة من 0001 إلى 0091 — انقسام عضوية/مطالبة فعّالة يسمح بتعدد المرتجعات قيد المراجعة على نفس البند مع حصرية حقيقية عند الاعتماد (فهرس فريد جزئي جديد، مُثبَت تحت تزامن حقيقي)، حفظ تاريخ كامل للبنود عبر الرفض/التراجع (لا حذف ناعم مُدمِّر بعد الآن)، حارس لقطة بيع صريح يمنع اعتماد مرتجع على بيانات قديمة، تصحيح `customer_never_received` عبر قيد `CHECK` صريح، تصحيح سياسة `full_reversal` (صفر على الجزئي، امتصاص كامل عند الاكتمال)، ترتيب قفل آمن عالمي مُوثَّق ومُثبَت بلا طريق مسدود عبر سيناريو تزامن حقيقي جديد (R3)، تسوية استرداد نهائية كمفهوم مستقل جديد، نطاق VISIBLE للتصحيحات التاريخية بدل OPERABLE، وحماية ربح تمتد تلقائيًا لكل حقل مالي جديد دون أي صلاحية إضافية. **427 نقطة تحقق/سيناريو SQL ناجحة (370 سابقة بصفر انحدار)، 64 تأكيدًا HTTP حقيقيًا، 47 اختبار Vitest، وإثبات مخصَّص لسلامة الترقية على بيانات Returns حقيقية سابقة لهذه الرقعة — كلها من تشغيلات فعلية في هذه الجلسة. لم تبدأ Shipping ولا Settlements ولا Services/Adjustments ولا Inventory ولا Reports — العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP هذا الملحق.**

## الملحق الثامن عشر — "Final Returns Integrity Patch 4.2": إصلاح ما بقي فوق Patch 4.1 (ترحيلات 0099–0105)

هذا الملحق يوثِّق **Patch 4.2** كاملة — رقعة أخيرة فوق Returns Integrity Patch 4.1 المُسلَّمة (الملحق السابع عشر)، بناءً على مواصفة المستخدم الصريحة المكوَّنة من 13 بندًا مرقَّمة. القيود كالمعتاد وبقيت سارية طوال هذا الملحق: **"لا تبدأ Shipping"**، **"لا تبدأ Settlements"**، **"لا تبدأ Services / Adjustments"**، **"لا تبدأ Inventory"**، **"لا تبدأ Reports"**، **"لا تعدل migrations من 0001 إلى 0098"**، **"أي migration جديدة تبدأ من 0099"**، **"حافظ على كل إصلاحات 0092–0098 الحالية"**. سبع ترحيلات جديدة فقط (0099–0105)، بلا لمس حرفي واحد لأي ترحيلة من 0001 إلى 0098. العمل **متوقف الآن نهائيًا**: **"لا تبدأ Shipping. انتظر المراجعة النهائية."**

### 1) الترحيلات الجديدة (0099–0105) — سبع ترحيلات فوق Patch 4.1 دون تعديلها

| # | الترحيلة | تُضيف |
|---|---|---|
| 0099 | `returns_integrity_patch_4_2_schema.sql` | عمود `requires_sale_refresh` (Section 1) — حارس مستقل تمامًا عن `source_sale_row_version`، مع Backfill رجعي فوري يضعه `true` لكل مرتجع كان `pending` وقت الترقية؛ Backfill رجعي فوري للحقول المالية الثلاثة (`returned_original_sale_amount`/`recovered_original_cost_amount`/`net_sales_profit_adjustment`) لكل مرتجع `approved`/`reversed` قديم كانت هذه الحقول لديه `NULL` (Section 2)؛ جدول تاريخي إلحاقي بحت جديد `sales_return_refund_reconciliation_events` (Section 3/4، `event_type` بين `finalized`/`reopened`، `ON DELETE RESTRICT` عمدًا على `sales_return_id` — لا يجوز أن يختفي التاريخ صمتًا). |
| 0100 | `create_and_preview_sales_return_patch_4_2.sql` | `create_sales_return()` يُدخِل `requires_sale_refresh=false` دومًا لمرتجع طازج (يلتقط اللقطة و`source_sale_row_version` معًا ذريًّا، فلا نافذة تباعُد ممكنة عند الإنشاء)؛ `preview_sales_return()` يقبل `p_scenario` الجديد (Section 5 تكافؤ)؛ `refresh_pending_sales_return_from_sale()` أصبحت الطريقة الوحيدة أيضًا لمسح `requires_sale_refresh` (فوق دورها القائمة أصلًا من Patch 4.1). |
| 0101 | `approve_sales_return_patch_4_2.sql` | فحص جديد صريح: يرفض الاعتماد فورًا برسالة "يجب تحديث بيانات المرتجع من عملية البيع قبل اعتماده." طالما `requires_sale_refresh=true` — قبل أي فحص آخر، وقبل أي منطق موجود مسبقًا من 0095. |
| 0102 | `reverse_sales_return_patch_4_2.sql` | تسلسل زمني صريح (Section 6): `reversal_business_date` يُرفَض إن كان قبل تاريخ اعتماد المرتجع أو تاريخ المرتجع نفسه، برسائل دقيقة منفصلة. |
| 0103 | `return_refund_reconciliation_patch_4_2.sql` | إعادة كتابة `record_sales_return_refund()`/`reverse_sales_return_refund_event()` — كلاهما يرفض الآن أي محاولة على مرتجع تسويته مُغلَقة (`refund_finalized_at` غير فارغ) برسالة "يجب إعادة فتح التسوية أولًا"؛ تسلسل زمني صريح جديد لكلا المسارين؛ `finalize_sales_return_refund()` يكتب سجل `finalized` في جدول التاريخ الجديد بدل الاكتفاء بعمود واحد؛ دالة جديدة تمامًا `reopen_sales_return_refund_reconciliation()` — تمسح `refund_finalized_at`، تكتب سجل `reopened` إلزامي السبب، وتُبقي كل سجل تاريخي سابق دون محو. **ترتيب قفل ثابت جديد** عبر الدوال الأربع كلها: صف `sales_returns` الأب `FOR UPDATE` يُحجَز دومًا **قبل** أي صف حدث استرداد محدَّد — يمنع أي طريق مسدود بين الدوال الأربع عند التسابق (مُثبَت تحت تزامن حقيقي، R4/R5/R6). |
| 0104 | `returns_read_rpcs_patch_4_2.sql` | إعادة كتابة `get_sales_return()`/`list_sales_returns()` — تضيف `requires_sale_refresh` (غير محجوبة بالربح — Section 1 يحتاجها المستخدم قبل محاولة الاعتماد أصلًا) و`reconciliation_history` (المصفوفة الكاملة من الجدول الجديد، غير محجوبة بالربح أيضًا). |
| 0105 | `returns_narrow_lookups_patch_4_2.sql` | ثلاث دوال جديدة ضيقة (Section 7): `returns_operable_store_lookups()` (مقيَّدة بـ`returns.create`)، `returns_visible_store_lookups()` (مقيَّدة بـ`returns.view`)، `returns_refund_method_lookups()` (مقيَّدة بـ`returns.record_refund`) — كل واحدة تُعيد `{id, name_ar}` فقط، ولا واحدة منها تعتمد على `stores.view`/`payment_methods.view` كما كانت تعتمد ضمنيًا قوائم `getReturnsFormLookups()` في طبقة TypeScript القديمة. |

### 2) قرارات معمارية اتُّخذت ولم تُحدَّد صراحةً في المواصفة (مع التبرير)

1. **لماذا `requires_sale_refresh` مستقل تمامًا عن `source_sale_row_version`، لا تشديد لنفس الفحص القائم:** الثغرة التي وثَّقتها ترحيلة 0099 نفسها بالتفصيل: Backfill 0092 وضع `source_sale_row_version` = رقم إصدار البيعة **الحالي وقت الترقية** لكل مرتجع قديم، شاملةً مرتجعات `pending`. لو لم تُعدَّل البيعة مرة أخرى بين لحظة الترقية ولحظة محاولة الاعتماد، يتطابق `source_sale_row_version` مع رقم الإصدار الحالي **صدفة** — رغم أن لقطة البند الفعلية (`sales_return_items.*_snapshot`) أُخِذَت بالدالة القديمة قبل 0092، والتي قد لا تتوافق فعليًا مع رقم إصدار البيعة وقتها بنفس الدقة التي تضمنها الدالة الجديدة (تلتقط اللقطة ورقم الإصدار **معًا ذريًّا في نفس العبارة**). فحص تشديد رقم الإصدار وحده لا يميِّز بين "رقم إصدار متطابق موثوق" و"رقم إصدار متطابق صدفة على لقطة قديمة أصلًا" — فكان الحل الوحيد المضمون هو علم مستقل يُوسَم صراحةً على **كل** مرتجع كان `pending` وقت الترقية، بغض النظر عن حساب أرقام الإصدار، تمامًا كما ينص القسم الأول من المواصفة.
2. **لماذا Backfill 0099 يُوسِم `pending` كلها بلا استثناء، لا يحاول تمييز "أُنشئ بالدالة الجديدة بعد 0092" عن "أُنشئ بالدالة القديمة قبلها":** التمييز ممكن نظريًا عبر `created_at` مقارنةً بتاريخ تطبيق 0092، لكن هذا هش (لا عمود صريح يسجِّل "أُنشئ بأي إصدار من الدالة")، والمواصفة نفسها تنص صراحةً أن التوسيع الزائد "أقصى شيء سيحتاج Refresh صريح مرة واحدة" — أي أن الكُلفة (طلب تحديث صريح غير ضروري أحيانًا لمرتجع أُنشئ فعليًا بالدالة الجديدة الموثوقة) أرخص بكثير من مخاطرة اعتماد مرتجع على لقطة قديمة فعليًا. تم اختيار الأوسع والأضمن.
3. **لماذا Backfill الحقول المالية الثلاثة (Section 2) UPDATE واحد داخل 0099 نفسها، لا سكربت منفصل:** نفس منطق Backfill 0092 (الملحق السابع عشر، القسم 3.3) — الجداول قد تحمل بيانات إنتاج حقيقية وقت تطبيق هذه الرقعة، فلا يصح افتراض الفراغ. الصيغة (`returned_original_sale_amount = SUM(sale_price_snapshot)` على البنود `active OR included_in_decision`، وبالمثل للتكلفة المستردة، و`net_sales_profit_adjustment` من معادلة صيغة Section 12 الأصلية نفسها) تُعيد بناء بالضبط ما كانت `approve_sales_return()` الجديدة (0101) ستحسبه لو كانت موجودة وقت الاعتماد الأصلي — مُثبَت بمقارنة ذاتية الاتساق في اختبار الترقية المخصَّص (القسم 3 من `TEST_RESULTS_PATCH_4_2.md`) لا بأرقام مُثبَّتة يدويًا.
4. **لماذا ترتيب القفل الجديد في 0103 يضع صف `sales_returns` الأب دومًا قبل أي صف حدث استرداد محدَّد:** أربع دوال جديدة/مُعاد كتابتها (`record_sales_return_refund`/`reverse_sales_return_refund_event`/`finalize_sales_return_refund`/`reopen_sales_return_refund_reconciliation`) تتقاطع الآن جميعًا على نفس المرتجع، وبعضها يحتاج قفل صف حدث استرداد محدَّد أيضًا (`reverse_sales_return_refund_event`). لو اختلف ترتيب القفل بين دالتين (مثلًا واحدة تقفل صف الحدث أولًا ثم صف المرتجع، والأخرى العكس)، يصبح طريق مسدود ممكنًا نظريًا بين استدعاءين متزامنين على نفس المرتجع لكن حدثين مختلفين. تم توحيد الترتيب صراحةً في الدوال الأربع: صف `sales_returns` الأب أولًا دومًا (بغض النظر عمَّا إذا كانت الدالة تحتاج صف حدث محدَّد أصلًا) — نفس نمط ترتيب القفل الآمن العالمي الموثَّق في Patch 4.1 (الملحق السابع عشر، القرار 2)، مُثبَت هنا تجريبيًا بثلاثة سيناريوهات تزامن حقيقية جديدة (R4/R5/R6).
5. **لماذا `reconciliation_history` جدول إلحاقي منفصل، لا توسيع لأعمدة `sales_returns` نفسها:** `refund_finalized_at`/`refund_final_variance_reason` القائمة من Patch 4.1 تكفي لتمثيل "آخر حالة تسوية" لكن لا تحتفظ بأي تاريخ — إعادة الفتح (Section 3/4) تتطلَّب صراحةً ألا يُفقَد أي مُدخَل سابق أبدًا. جدول إلحاقي بحت (`INSERT` فقط، لا `UPDATE`/`DELETE` تطبيقيًا) مع `ON DELETE RESTRICT` صريح على المرتجع الأب هو الطريقة الوحيدة الموثوقة لضمان عدم إمكانية محو التاريخ صمتًا حتى بخطأ تطبيقي مستقبلي — مُثبَت عبر محاولة حذف مرتجع له سجل تسوية فِعليًّا تُرفَض بخطأ قيد أجنبي صريح ما لم تُحذَف سجلات التاريخ أولًا (اكتُشِف هذا أثناء كتابة تنظيف اختبار التزامن، ومُوثَّق كسلوك مقصود لا عارض).
6. **لماذا الدوال الثلاث الجديدة في Section 7 مقيَّدة كل واحدة بصلاحية Returns مختلفة، لا صلاحية واحدة موحَّدة:** `returns_operable_store_lookups()` تخدم إنشاء مرتجع جديد (`returns.create`)، `returns_visible_store_lookups()` تخدم فلاتر قائمة موجودة أصلًا (`returns.view`، أوسع نطاقًا)، `returns_refund_method_lookups()` تخدم تسجيل استرداد فعلي (`returns.record_refund`، أضيق الثلاثة). ربطها كلها بصلاحية واحدة (`returns.view` مثلًا) كان سيمنح أي مستخدم يملك عرض المرتجعات فقط قدرة على رؤية قائمة طرق الدفع القابلة للاسترداد رغم أنه لا يملك أصلًا صلاحية تسجيل استرداد — تسريب معلومة غير ضرورية عبر واجهة لا يحتاجها. الفصل الثلاثي مُثبَت صراحةً عبر HTTP حقيقي: مُمثِّل يملك `returns.view` فقط ينجح على النطاق الأول ويُرفَض تمامًا على الآخرين.

### 3) التوافق الأمامي (TypeScript/React) — قائمة كاملة

`src/types/database.ts` (عمود `requires_sale_refresh` على `sales_returns`، جدول `sales_return_refund_reconciliation_events` الجديد بالكامل، `p_scenario` على `preview_sales_return`، `requires_sale_refresh` على مخرجات `list_sales_returns`، الدالة الجديدة `reopen_sales_return_refund_reconciliation` والدوال الثلاث الضيقة الجديدة)؛ `src/features/returns/components/return-entry-form.tsx` (حقل `item_return_reason`/`item_notes` قابل للتوسيع لكل بند — Section 8، لم يكن مكتملًا فعليًا سابقًا؛ إصلاح ثغرة إغلاق قديمة حقيقية في `useEffect` المعاينة المُؤجَّلة كانت تفوِّت `scenario`/`itemReasons`/`itemNotes`/`approvedRefundAmount`/`refundDifferenceReason` من مصفوفة الاعتماديات — Section 5)؛ `refund-events-panel.tsx` (شارة `requires_sale_refresh`، عرض `reconciliation_history` الكامل، حوار `ReopenReconciliationDialog` جديد بسبب إلزامي)؛ `src/app/(app)/returns/[id]/page.tsx` (لافتة تحذير `requires_sale_refresh` صريحة، عرض `item_notes`)؛ `return-lifecycle-actions.tsx` (رسالة الخطأ عند الاعتماد تغطي الآن كلا حالتي "لقطة قديمة" و"يحتاج تحديثًا صريحًا" بنفس زر المعالجة)؛ `returns-filters.tsx`/`src/app/(app)/returns/page.tsx` (انتقال كامل من الاعتماد على `stores`/`payment_methods` المباشر إلى الدوال الثلاث الضيقة الجديدة — Section 7).

### 4) الاختبارات — قائمة كاملة وأرقام فعلية (نُفِّذت في هذه الجلسة)

تفصيل كامل بالأرقام في `TEST_RESULTS_PATCH_4_2.md`. ملخَّص:

- `supabase/tests/sales_returns_core.test.sql` **مُوسَّع** (يضيف الأقسام Q/R/S/U/V فوق A–P القائمة من Patch 4.1 دون تعديلها) → **77/77 نقطة تحقق ناجحة**.
- `supabase/tests/sales_returns_concurrency.test.sql` **مُوسَّع** (يضيف R4/R5/R6 فوق R1–R3 القائمة) → **R1–R6، 6/6 سيناريوهات تزامن حقيقية عبر `dblink` ناجحة**.
- إثبات ترقية مخصَّص **جديد، دائم في المستودع** (لم يكن موجودًا كملف قبل هذه الرقعة): `supabase/tests/fixtures/patch_4_2_legacy_upgrade_pre_fixture.sql` + `supabase/tests/upgrade_patch_4_2_legacy_returns.test.sql` + `scripts/run_upgrade_test_patch_4_2.sh` → **11/11 نقطة تحقق ناجحة** على بيانات Returns حقيقية بتوقيعات الدوال القديمة (ما قبل 0092)، شاملةً سيناريو تعديل البيعة الأصلية **بعد** إنشاء مرتجع قيد المراجعة عليها — الحالة التي تكشف ثغرة Backfill 0092 فعليًا.
- `scripts/run_upgrade_test.sh` العام (Foundation → latest) → **11/11**، بلا تأثر (لا يغطي Returns أصلًا).
- بقية سطح الاختبار (12 ملفًا قائمًا مسبقًا، غير مُعدَّلة منطقيًا) → **380/380 نقطة تحقق/سيناريو سابقة ناجحة، صفر انحدار**.
- `scripts/postgrest-http-test.mjs` — قسم "Part 7 — Returns" مُوسَّع (13 تأكيدًا جديدًا فوق 64 القائمة) → **77/77 تأكيدًا HTTP حقيقيًا ناجحًا**.
- `npx tsc --noEmit` → صفر أخطاء. `npx eslint .` → صفر أخطاء وتحذيرات. `npx vitest run` → 47/47 عبر 6 ملفات، بلا تغيير. `npm run check:numeric-types` → **46/46 عمود NUMERIC مطابق** (3 أعمدة جديدة عن Patch 4.1: `sales_return_refund_reconciliation_events.actual_refunded_total`/`approved_refund_amount`/`variance`). `npm run build` (Next.js/Turbopack) → نجح، بلا مسارات جديدة.

### 5) الملفات/الترحيلات التي تغيَّرت أو أُضيفت في Patch 4.2 (قائمة كاملة)

**ترحيلات جديدة (7):** `0099_returns_integrity_patch_4_2_schema.sql`، `0100_create_and_preview_sales_return_patch_4_2.sql`، `0101_approve_sales_return_patch_4_2.sql`، `0102_reverse_sales_return_patch_4_2.sql`، `0103_return_refund_reconciliation_patch_4_2.sql`، `0104_returns_read_rpcs_patch_4_2.sql`، `0105_returns_narrow_lookups_patch_4_2.sql`.

**اختبارات SQL مُوسَّعة (لا إعادة كتابة كاملة، إضافات فقط فوق سيناريوهات Patch 4.1 القائمة):** `supabase/tests/sales_returns_core.test.sql`، `supabase/tests/sales_returns_concurrency.test.sql`.

**اختبارات/سكربتات ترقية جديدة بالكامل:** `supabase/tests/fixtures/patch_4_2_legacy_upgrade_pre_fixture.sql`، `supabase/tests/upgrade_patch_4_2_legacy_returns.test.sql`، `scripts/run_upgrade_test_patch_4_2.sh`.

**سكربت HTTP مُعدَّل (قسم Part 7 مُوسَّع، لا حذف لبقية الأقسام):** `scripts/postgrest-http-test.mjs`.

**كود TypeScript مُعدَّل:** `src/types/database.ts`، `src/features/returns/components/return-entry-form.tsx`، `src/features/returns/components/refund-events-panel.tsx`، `src/features/returns/components/returns-filters.tsx`، `src/app/(app)/returns/[id]/page.tsx`، `src/app/(app)/returns/page.tsx`، `src/features/returns/components/return-lifecycle-actions.tsx`.

**لم يتغيَّر إطلاقًا:** أي ترحيل من 0001–0098 (شاملة كل ترحيلات Phase 4/Patch 4.1)، `src/features/returns/schema.ts`/`actions.ts` (التوقيعات الجديدة كلها اختيارية أو مُضافة بأسماء جديدة، فلا حاجة لتعديل تطبيقي)، `src/app/(app)/returns/new/page.tsx`/`[id]/edit/page.tsx`، `src/features/returns/components/return-order-search.tsx`، `src/lib/audit/action-labels.ts` (لا فعل تدقيق جديد — `return.refund_finalized`/`return.update` القائمان يغطيان كل عمليات هذه الرقعة)، أي اختبار SQL آخر خارج ما ذُكِر أعلاه، أي جزء آخر من طبقة TypeScript، القفل الاستشاري `acquire_returns_order_lock_exclusive` (بقي كما هو حرفيًا).

### 6) مفاهيم أساسية — شرح مختصر (طلب المستخدم صراحةً في بند التسليم 13.7)

1. **أمان تحديث اللقطة لمرتجع قديم قيد المراجعة (`requires_sale_refresh`):** علم `boolean` مستقل تمامًا عن أي حساب رقم إصدار، يُوسَم تلقائيًا `true` رجعيًا لكل مرتجع كان `pending` وقت تطبيق هذه الرقعة (بصرف النظر عن كونه أُنشئ بالدالة القديمة أو الجديدة)، ويحجب الاعتماد كليًا حتى تحديث صريح واحد. الهدف: منع اعتماد مرتجع بلقطة بند قديمة فعليًا رغم تطابق رقم إصدار البيعة صدفة.
2. **Backfill الحقول المالية للمرتجعات المعتمدة القديمة:** ثلاثة أعمدة (`returned_original_sale_amount`/`recovered_original_cost_amount`/`net_sales_profit_adjustment`) كانت `NULL` لكل مرتجع `approved`/`reversed` أُنشئ قبل هذه السلسلة من الرقعات — `UPDATE` رجعي واحد يُعيد بناءها من بنود المرتجع نفسها بنفس الصيغة التي تستخدمها `approve_sales_return()` الحالية، فتظهر الآن بشكل صحيح في كل تقرير/شاشة تعتمد عليها دون أي تدخل يدوي.
3. **آلة حالة تسوية/إعادة فتح الاسترداد:** تسوية الاسترداد (`finalize_sales_return_refund()`) قفل لمرة واحدة يُقفَل صراحةً — بعده تُرفَض أي محاولة تسجيل/تراجع استرداد جديدة. `reopen_sales_return_refund_reconciliation()` هو الباب الوحيد لفكِّ هذا القفل، ويتطلَّب سببًا إلزاميًا دومًا، ويُسجَّل كحدث تاريخي بنفسه — فتُصبح دورة "تسوية → اكتشاف خطأ → إعادة فتح → تصحيح → تسوية جديدة" ممكنة دون فقدان أي أثر لما حدث سابقًا.
4. **تسلسل تحوُّل مُتحكَّم به لعمليات دفتر الاسترداد (Serialization):** الدوال الأربع التي تُعدِّل حالة تسوية الاسترداد تتشارك جميعًا ترتيب قفل واحدًا ثابتًا (صف المرتجع الأب أولًا دومًا) — هذا يمنع الطريق المسدود بين استدعاءين متزامنين، ويضمن أن أي قراءة لاحقة لحالة التسوية (مثل `actual_refunded_total` عند التسوية النهائية) تعكس دومًا كل تعديل مُلتزَم فعليًا، لا لقطة سابقة للقفل.
5. **تكافؤ المعاينة (`preview_sales_return()`):** المعاينة تستخدم الآن **بالضبط** نفس شجرة التحقق التي يستخدمها الإنشاء الفعلي (بما فيها `p_scenario` الجديد)، فما يظهر للمستخدم أثناء التعبئة يطابق تمامًا ما سيحدث فعليًا عند الحفظ — بلا مسار حساب مزدوج قد ينحرف أحدهما عن الآخر بمرور الوقت.
6. **تسلسل التواريخ الزمنية للإجراءات (Chronology):** كل إجراء لاحق على مرتجع (تراجع عن الاعتماد، تسجيل استرداد، تراجع عن استرداد) يحمل تاريخ عمل مستقلًا خاصًا به، ويُرفَض صراحةً إن سبق تاريخ الإجراء الذي يعتمد عليه منطقيًا (مثلًا: تراجع عن استرداد لا يمكن أن يسبق تاريخ الاسترداد نفسه) — يمنع سجلًا ماليًا يحكي قصة زمنية متناقضة.
7. **صلاحيات دوال البحث الخاصة بـReturns:** ثلاث دوال قراءة ضيقة جديدة تحلّ محل اعتماد واجهة Returns الضمني على `stores.view`/`payment_methods.view` — كل واحدة مقيَّدة بصلاحية Returns الدقيقة التي تخدمها فعليًا (إنشاء/عرض/تسجيل استرداد)، فلا يعود امتلاك صلاحية Returns وحدها كافيًا لتسريب معلومة من وحدة Master Data لم يُطلَب الوصول إليها.

**خلاصة الملحق الثامن عشر:** إغلاق نهائي لثغرة أمان بيانات حقيقية في Backfill الترقية (`requires_sale_refresh`)، استكمال Backfill الحقول المالية للمرتجعات القديمة، آلة حالة تسوية/إعادة فتح استرداد كاملة بتاريخ إلحاقي لا يُمحى أبدًا، تسلسل قفل موحَّد يمنع أي طريق مسدود بين عمليات دفتر الاسترداد الأربع (مُثبَت تحت تزامن حقيقي R4–R6)، تكافؤ معاينة/إنشاء كامل، تسلسل زمني صارم للإجراءات اللاحقة، ودوال بحث Returns ضيقة تقطع الاعتماد الضمني على صلاحيات Master Data. **457 نقطة تحقق SQL + 6/6 سيناريوهات تزامن حقيقية + 11/11 نقطة تحقق ترقية مخصَّصة (380 سابقة بصفر انحدار)، 77 تأكيدًا HTTP حقيقيًا، 47 اختبار Vitest، و46/46 عمود NUMERIC — كلها من تشغيلات فعلية في هذه الجلسة. لم تبدأ Shipping ولا Settlements ولا Services/Adjustments ولا Inventory ولا Reports — العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP هذا الملحق.**

---

## الملحق التاسع عشر — "Final Hotfix 4.2.1": إصلاح عيبين جوهريين متبقّيين فوق Patch 4.2 (ترحيلات 0106–0112)

هذا الملحق يوثِّق **Hotfix 4.2.1** كاملة — رقعة أخيرة فوق Final Returns Integrity Patch 4.2 المُسلَّمة (الملحق الثامن عشر)، بناءً على مراجعة كود مصدرية اكتشفت **عيبين جوهريين متبقيين رغم تسليم Patch 4.2**: (1) دفتر الاسترداد لم يكن إلحاقيًا حقيقيًا فعليًا — `reverse_sales_return_refund_event()` كانت تُنفِّذ `UPDATE` على الصف الأصلي نفسه (تغيير `status`/`reversed_at`/إلخ في مكانه)، لا إدراج سجل جديد في جدول منفصل؛ (2) عكس عمولة الدفع (`payment_fee_reversal`) كان يُحسَب على أساس **قيمة الصنف المُرتجَع**، لا على أساس **مبلغ الاسترداد المعتمد الفعلي** الذي حدَّده `approved_refund_amount` أصلًا — ما يعني أن مرتجعًا اعتُمِد بمبلغ استرداد أقل من قيمة الصنف الكاملة (خصم، حالة `customer_never_received`، إلخ) قد يعكس عمولة أكبر مما استُرِدَّ فعليًا. المواصفة نفسها 23 بندًا مرقَّمًا. القيود كالمعتاد وبقيت سارية طوال هذا الملحق: **"لا تبدأ Shipping"**، **"لا تبدأ Settlements"**، **"لا تبدأ Services / Adjustments"**، **"لا تبدأ Inventory"**، **"لا تبدأ Reports"**، **"لا تعدل migrations من 0001 إلى 0105"**، **"كل إصلاح جديد يبدأ من 0106"**، **"لا تعيد تصميم Returns من الصفر"**، **"حافظ على كل إصلاحات 0092–0105 الصحيحة"**. سبع ترحيلات جديدة فقط (0106–0112)، بلا لمس حرفي واحد لأي ترحيلة من 0001 إلى 0105. العمل **متوقف الآن نهائيًا**: **"لا تبدأ Shipping. انتظر المراجعة النهائية."**

### 1) الترحيلات الجديدة (0106–0112) — سبع ترحيلات فوق Patch 4.2 دون تعديلها

| # | الترحيلة | تُضيف |
|---|---|---|
| 0106 | `return_refund_append_only_schema.sql` | جدول ملحق جديد بالكامل `sales_return_refund_event_reversals` (`UNIQUE(refund_event_id)` — سجل إلغاء واحد بالضبط لكل حدث استرداد على الأكثر)؛ أعمدة جديدة `reference`/`refund_method_name_snapshot` على `sales_return_refund_events` و`payment_fee_reversal_calculation_version` على `sales_returns`؛ مُشغِّلا `BEFORE UPDATE`/`BEFORE DELETE` على `sales_return_refund_events` نفسها (`reject_sales_return_refund_event_mutation()`) يرفضان أي تعديل/حذف دون شرط بـ`RAISE EXCEPTION`، مع بوابة إفلات محلية للجلسة ضيقة جدًا (`app.allow_refund_event_backfill`) تُستخدَم **حصرًا** من Backfill هذه الترحيلة نفسها (ولا يضبطها أي RPC تطبيقي على الإطلاق)؛ Backfill رجعي فوري (Part E): كل صف `sales_return_refund_events` قديم كانت حالته `reversed` يحصل على سجل واحد بالضبط في الجدول الملحق الجديد، حاملًا نفس حقائق الإلغاء التاريخية (`reversed_at`/`reversed_by`/`reversal_reason`/`reversal_business_date`) بلا أي اختلاق، مع تعيين `refund_method_name_snapshot`/`payment_fee_reversal_calculation_version=1` رجعيًا لكل صف قديم؛ الأعمدة القديمة (`status`/`reversed_*`) تبقى متجمّدة تاريخيًا فقط، لا تُقرَأ ولا تُكتَب بعد هذه الترحيلة. |
| 0107 | `return_refund_events_append_only.sql` | إعادة كتابة `record_sales_return_refund()` — تكتسب `p_reference` اختياريًا (Section 6) وتلتقط `refund_method_name_snapshot` (Section 17) لحظة الإدراج؛ إعادة كتابة `reverse_sales_return_refund_event()` بالكامل: `INSERT` في `sales_return_refund_event_reversals` بدل أي `UPDATE` على الصف الأصلي — إلغاء إلحاقي حقيقي فعليًا الآن، لا تعديل في مكانه؛ حارس صريح ضد الإلغاء المزدوج لنفس الحدث تحت تزامن حقيقي (Section 19) — يعتمد على قيد `UNIQUE(refund_event_id)` نفسه كخط دفاع أخير (التقاط `unique_violation`) فوق القفل الصريح على صف المرتجع الأب. |
| 0108 | `return_refund_reconciliation_append_only.sql` | إعادة كتابة `finalize_sales_return_refund()`/`reopen_sales_return_refund_reconciliation()` — نفس التوقيعين الحرفيين من 0103، والتغيير الوحيد في كلا الجسمين هو طريقة حساب `actual_refunded_total`: "الفعّال" (غير المُلغى) يُشتَق الآن من **غياب** سجل في `sales_return_refund_event_reversals` (0106/0107)، لا من عمود `status` القديم المتجمِّد الذي توقَّفت أي دالة عن الكتابة فيه بعد 0107. |
| 0109 | `return_fee_reversal_engine_v2.sql` | محرك جديد بالكامل `compute_sales_return_fee_reversal_v2()` — لا يستبدل v1 صامتًا، دالة منفصلة باسم جديد؛ `approve_sales_return()` مُعاد كتابتها لاستدعاء v2 حصرًا لكل اعتماد **جديد** من الآن فصاعدًا؛ الأساس الحسابي الجديد (Section 9/10): `proportional_reversal` يستخدم **الأساس التراكمي** (مجموع `approved_refund_amount` لهذا المرتجع + كل مرتجع آخر معتمد سابقًا على نفس الطلبية)، و`full_reversal` يستخدم **الأساس النقدي** (`approved_refund_amount` الفعلي) لا عدد الأصناف؛ `non_refundable_fee`/`manual` (Section 11) وحالة `customer_never_received` مع `not_collected` (Section 12) تُعيد صفرًا صراحةً؛ كل نتيجة جديدة تُوسَم `payment_fee_reversal_calculation_version = 2` (Section 13) — القيم القديمة المحسوبة بـv1 (`= 1`) لا تُعاد حسابها صامتًا أبدًا. |
| 0110 | `return_preview_fee_reversal_v2_parity.sql` | إعادة كتابة `preview_sales_return()` (نفس توقيع 0100 بتسعة معاملات) لاستخدام محرك v2 بنفس منطق `approve_sales_return()` بالضبط — تكافؤ معاينة/اعتماد كامل يمتد الآن ليشمل حساب العمولة أيضًا، لا الحقول المالية الأساسية وحدها. |
| 0111 | `return_read_rpcs_append_only_v2.sql` | إعادة كتابة `get_sales_return()`/`list_sales_returns()` بالكامل: حالة كل حدث استرداد (`active`/`reversed`) تُشتَق الآن حيًّا من وجود/غياب صف في `sales_return_refund_event_reversals`، لا من عمود `status` المتجمِّد؛ `actual_refunded_total` يُحسَب بنفس المنطق المُشتَق؛ إضافة `refund_method_name_snapshot`/`reference` لكل حدث، و`payment_fee_reversal_calculation_version` على مستوى المرتجع (محجوب بالربح، كبقية حقول عكس الربح). |
| 0112 | `return_narrow_sale_lookup.sql` | دالة جديدة ضيقة `search_sales_orders_for_return()` (Section 15) — مقيَّدة بـ`returns.create` فقط، تُعيد مجموعة أعمدة مضغوطة (`id`/`order_number`/`sale_date`/`store_id`/`store_name`/`customer_name`/`subtotal`) تكفي تمامًا احتياج بحث Returns عن بيعة، دون أي اعتماد على `sales.view`؛ `get_returnable_sales_order()` مُعاد كتابتها لتتطلَّب `returns.create` فقط أيضًا (إسقاط شرط `sales.view` المزدوج القديم) — جسمها الداخلي غير ذلك مطابق حرفيًا لنسخة 0098. |

### 2) قرارات معمارية اتُّخذت ولم تُحدَّد صراحةً في المواصفة (مع التبرير)

1. **لماذا جدول ملحق منفصل (`sales_return_refund_event_reversals`) لا عمود `reversed_via_ledger` إضافي على الصف نفسه:** أي حل يبقي البيانات الجديدة على نفس صف `sales_return_refund_events` يظل عرضة لنفس فئة الخطأ التي سبَّبت العيب الأصلي — "تعديل صف قائم" مهما بدا التعديل بسيطًا. جدول منفصل بقيد `UNIQUE(refund_event_id)` مع مُشغِّلي `BEFORE UPDATE`/`BEFORE DELETE` صريحين يمنعان أي تعديل على الجدول الأصلي هو الضمان البنيوي الوحيد الذي لا يعتمد على انضباط كل استدعاء مستقبلي — مُثبَت تجريبيًا بمحاولة `UPDATE`/`DELETE` مباشرة على `sales_return_refund_events` من خارج بوابة الإفلات فتُرفَض دومًا بخطأ صريح (اختبارات "append-only 1–10" في Section 18).
2. **لماذا بوابة الإفلات (`app.allow_refund_event_backfill`) GUC محلي للجلسة لا دالة SECURITY DEFINER منفصلة:** الحاجة الوحيدة المشروعة لتجاوز القفل هي Backfill 0106 نفسها (مرة واحدة، أثناء الترقية) — GUC محلي للجلسة (`set_config(..., false)`) لا يُكتَب أبدًا في أي مسار تطبيقي (تأكَّد بالبحث الشامل في كل RPC)، فيبقى أضيق سطح ممكن؛ استُخدِم لاحقًا فقط في تنظيف بيانات اختبار التزامن (توثيق صريح في الكود بأن هذا استخدام اختبار، لا مسار تطبيقي).
3. **لماذا الأساس الحسابي الجديد لعكس العمولة "تراكمي" لـ`proportional_reversal`، لا مستقل لكل مرتجع كما كان v1:** الخطأ الأصلي في v1 كان معالجة كل مرتجع بمعزل عن المرتجعات الأخرى على نفس الطلبية، فقد يُعكَس أكثر من إجمالي العمولة الأصلية إذا اعتُمِدت عدة مرتجعات جزئية بالتتابع. الأساس التراكمي (مجموع كل `approved_refund_amount` المعتمد فعليًا على الطلبية حتى الآن، شاملًا هذا المرتجع) يضمن أن مجموع كل عمليات العكس عبر كل المرتجعات على نفس الطلبية لا يتجاوز أبدًا العمولة الأصلية الكاملة — مُثبَت رياضيًا بسيناريو ثلاثي الخطوات (Section 14-B) يُنتِج بالضبط 33.33/33.34/33.33 (مجموع 100.00) بدل توزيع v1 غير المتّسق.
4. **لماذا الأساس الحسابي الجديد لـ`full_reversal` هو "النقدي" (`approved_refund_amount`) لا "عدد الأصناف المُغطاة":** هذا هو العيب الثاني المحدَّد صراحةً في تكليف هذه الرقعة — v1 كانت تعكس العمولة **الكاملة** بمجرد أن يكون الصنف/الأصناف المُرتجَعة تُغطِّي كل ما تبقى من الطلبية (`covers_all_remaining`)، بصرف النظر عن كون المبلغ المعتمد للاسترداد الفعلي أقل من القيمة الكاملة (خصم، أو `customer_never_received`). v2 تستخدم المبلغ النقدي المعتمَد فعليًا كأساس العكس — يعكس الواقع المالي الفعلي بدل افتراض تغطية الأصناف وحدها. مُثبَت تجريبيًا بسيناريو الترقية HF421-FEEV1 نفسه (القيمة الخاطئة تاريخيًا 100.00 مقابل القيمة الصحيحة 40.00 التي كانت ستُحسَب لو استُخدِم v2 من البداية).
5. **لماذا `payment_fee_reversal_calculation_version` عمود صريح، لا استنتاج بالتاريخ (قبل/بعد تطبيق 0109):** الاستدلال بالتاريخ هش (لا يميّز مرتجعًا اعتُمِد فعليًا بعد 0109 لكن بمنطق حافة نادر، ولا يوثِّق النية صراحةً في الصف نفسه). عمود صريح (`1`=v1 قديم/موروث، `2`=v2 جديد) يُوسَم أثناء الاعتماد الفعلي (`approve_sales_return()`/Backfill 0106) ويُقرَأ لاحقًا من أي واجهة (تقرير، شاشة تفاصيل) دون أي حاجة لمقارنة تواريخ — القيمة القديمة **لا تُعاد حسابها صامتًا أبدًا** بغض النظر عن هذا العمود، هو فقط للشفافية والتدقيق.
6. **لماذا `search_sales_orders_for_return()` دالة جديدة منفصلة، لا توسيع صلاحيات `list_sales_orders()` القائمة:** `list_sales_orders()` مصمَّمة لواجهة Sales الكاملة (تُعيد أعمدة الربح المحجوبة، مقيَّدة بـ`sales.view`) — منح Returns وصولًا إليها مباشرة كان سيتطلَّب إما تخفيف قيد `sales.view` (تسريب واجهة Sales الكاملة لمن يملك Returns فقط) أو تعقيد شرط الصلاحية داخل دالة واحدة تخدم غرضين مختلفين. دالة ضيقة جديدة بأعمدة مضغوطة ومقيَّدة بـ`returns.create` فقط (تمامًا كما فعلت Section 7 من Patch 4.2 لثلاث دوال بحث أخرى) تحافظ على الفصل الواضح بين الوحدتين.
7. **لماذا `refund_method_name_snapshot` (Section 17) عمود لقطة على حدث الاسترداد نفسه، لا اعتماد على `payment_methods.name_ar` الحيّ:** طريقة دفع قد تُعاد تسميتها لاحقًا (تصحيح إملائي، إعادة تسمية تجارية) — عرض الاسم **الحالي** لحدث استرداد قديم على شاشة التفاصيل يُنتِج سردًا تاريخيًا غير دقيق ("استُرِدَّ عبر X" بينما الاسم وقتها كان Y فعليًا). لقطة ثابتة تُلتَقط لحظة `record_sales_return_refund()` (ومُعاد بناؤها Backfill لكل حدث قديم في 0106) تحفظ الحقيقة التاريخية كما كانت وقتها بالضبط.

### 3) التوافق الأمامي (TypeScript/React) — قائمة كاملة

`src/types/database.ts` (`p_reference` اختياري على `record_sales_return_refund`، `payment_fee_reversal_calculation_version` على مخرجات `list_sales_returns`، الدالة الجديدة `search_sales_orders_for_return`)؛ `src/features/returns/schema.ts` (`reference` اختياري على مخطط تسجيل الاسترداد)؛ `src/features/returns/actions.ts` (تمرير `p_reference`، `searchSalesOrdersForReturnAction` تستدعي الدالة الضيقة الجديدة بدل `list_sales_orders`)؛ `src/features/returns/queries.ts` (تعليق JSDoc مُحدَّث يوثِّق أن `sales.view` لم تعُد شرطًا مسبقًا لـReturns)؛ `src/features/returns/components/refund-events-panel.tsx` (**Section 16 — الإصلاح الحرج على الواجهة**: زرّا "تسجيل استرداد" و"تراجع" لكل حدث نشط يُخفَيان الآن صراحةً بمجرد إغلاق التسوية `refundFinalizedAt`، لا الاعتماد على رفض الخادم وحده بعد النقر؛ عرض `refund_method_name_snapshot`/`reference` لكل حدث؛ حقل "مرجع عملية الاسترداد" جديد في حوار التسجيل)؛ `src/app/(app)/returns/[id]/page.tsx` (عرض `payment_fee_reversal_calculation_version` محجوبًا بالربح، مع تسمية توضيحية "1 = أساس قديم بقيمة الصنف، 2 = أساس الاسترداد المعتمد").

### 4) الاختبارات — قائمة كاملة وأرقام فعلية (نُفِّذت في هذه الجلسة)

تفصيل كامل بالأرقام في `TEST_RESULTS_HOTFIX_4_2_1.md`. ملخَّص:

- `supabase/tests/sales_returns_hotfix_4_2_1.test.sql` **جديد بالكامل** (تغطية مخصَّصة للأقسام 6/7/8/9/10/12/13/14/15/17/18/20 — سيناريوهات A–E لـSection 14، سيناريوهات 1–10 لـSection 18، Section 17 المُوسَّعة، Section 20، Section 15) → **35/35 نقطة تحقق ناجحة**.
- `supabase/tests/sales_returns_core.test.sql` **مُعدَّل** (سيناريو 3 فقط — تحديث الأساس الحسابي الجديد v2 التراكمي، 33.33/33.34/33.33 بدل 33.33/33.33/33.34، بلا تغيير في الإجمالي 100.00) → **77/77 نقطة تحقق ناجحة، صفر انحدار حقيقي (تعديل مقصود موثَّق فقط)**.
- `supabase/tests/sales_returns_concurrency.test.sql` **مُوسَّع** (سيناريو R7 جديد — إلغاء مزدوج متزامن حقيقي عبر `dblink` على نفس حدث الاسترداد، فوق R1–R6 القائمة دون تعديل منطقي) → **R1–R7، 7/7 سيناريوهات تزامن حقيقية ناجحة**.
- إثبات ترقية مخصَّص **جديد، دائم في المستودع**: `supabase/tests/fixtures/hotfix_4_2_1_legacy_upgrade_pre_fixture.sql` + `supabase/tests/upgrade_hotfix_4_2_1_legacy_refunds.test.sql` + `scripts/run_upgrade_test_hotfix_4_2_1.sh` → **6/6 نقاط تحقق رئيسية (15 `assert` فرعيًا) ناجحة** على بيانات ترقية حقيقية بتوقيعات الدوال القديمة (ما قبل 0106) — حدث استرداد نشط لم يُعكَس، حدث آخر أُلغِي بالدالة القديمة (`UPDATE`)، ومرتجع اعتُمِد بمحرك العمولة v1 القديم (القيمة الخاطئة تاريخيًا 100.00 محفوظة دون إعادة حساب صامتة).
- `scripts/run_upgrade_test.sh` العام (Foundation → latest، عبر 0106–0112 الآن أيضًا) → **11/11**، بلا تأثر (لا يغطي Returns أصلًا).
- `scripts/run_upgrade_test_patch_4_2.sh` (إثبات ترقية Patch 4.2 الخاص) **أُعيد تشغيله كاملًا عبر مجموعة الترحيلات الكاملة 0001–0112** للتأكُّد أن Hotfix 4.2.1 لم يكسر أمان ترقية Patch 4.2 نفسها صامتًا → **11/11، بلا تغيير**.
- مجموعة اختبارات SQL الكاملة (14 ملفًا في `supabase/tests/*.sql`، غير المُعدَّلة منطقيًا خارج ما ذُكِر أعلاه) نُفِّذت بالتتابع على قاعدة بيانات واحدة طازجة كاملة (0001–0112 + `seed.sql` الحقيقي) → **صفر أخطاء عبر كل الملفات، صفر انحدار عابر للوحدات (Foundation/Phase 2/Sales/Returns Core/Patch 4.1/Patch 4.2/Hotfix 4.2.1 معًا في تسلسل واحد)**.
- `scripts/postgrest-http-test.mjs` **مُوسَّع** (تأكيدات جديدة لـ`p_reference`، اشتقاق `status`/`refund_method_name_snapshot`، `payment_fee_reversal_calculation_version`، و`search_sales_orders_for_return()`، فوق 77 التأكيدات القائمة من Patch 4.2 دون تعديلها) → **81/81 تأكيدًا HTTP حقيقيًا ناجحًا**. **إصلاح جانبي ضروري اكتُشِف أثناء هذا التشغيل:** حساب "اليوم" في هذا السكربت كان يستخدم التاريخ الخام بتوقيت UTC، بينما كل دالة بحث عن سعر/عمولة/ضريبة تفتَرِض `business_today()` (توقيت الرياض UTC+3) — الفارق يُسبِّب فشلًا عابرًا حقيقيًا لأي تشغيل يقع داخل نافذة الثلاث ساعات حول منتصف الليل UTC (وقع فعليًا أثناء هذه الجلسة). أُصلِح بمواءمة حساب التاريخ في السكربت مع `business_today()` بالضبط، وأُضيفت بيانات تأسيسية لكلا التاريخين في `supabase/tests/postgrest_http_test_setup.sql` كضمان إضافي — إصلاح استقرار اختبار بحت، لا تغيير في أي منطق تطبيقي.
- `npx tsc --noEmit` → صفر أخطاء. `npx eslint .` (على كامل المستودع) → صفر أخطاء وتحذيرات. `npx vitest run` → **52/52 عبر 7 ملفات** (ملف جديد بالكامل `refund-events-panel.test.tsx`، 5 اختبارات — التغطية الإلزامية لإصلاح Section 16 على الواجهة: حالة التسوية المُغلَقة تُخفي "تسجيل استرداد" و"تراجع" كليًا وتُظهر "إعادة فتح التسوية"، الحالة المفتوحة تُظهر الاثنين الأولين وتُخفي الثالث، حدث مُلغى مسبقًا لا يُعرَض له زر تراجع في أي حالة). `npm run check:numeric-types` → **46/46 عمود NUMERIC مطابق** (لا عمود جديد — كل الأعمدة المالية الجديدة في هذه الرقعة إما `boolean`/`integer`/`text`، لا `numeric` خام إضافي). `npm run build` (Next.js/Turbopack) → نجح، 27 مسارًا، بلا مسارات جديدة.

### 5) الملفات/الترحيلات التي تغيَّرت أو أُضيفت في Hotfix 4.2.1 (قائمة كاملة)

**ترحيلات جديدة (7):** `0106_return_refund_append_only_schema.sql`، `0107_return_refund_events_append_only.sql`، `0108_return_refund_reconciliation_append_only.sql`، `0109_return_fee_reversal_engine_v2.sql`، `0110_return_preview_fee_reversal_v2_parity.sql`، `0111_return_read_rpcs_append_only_v2.sql`، `0112_return_narrow_sale_lookup.sql`.

**اختبارات SQL جديدة بالكامل:** `supabase/tests/sales_returns_hotfix_4_2_1.test.sql`، `supabase/tests/fixtures/hotfix_4_2_1_legacy_upgrade_pre_fixture.sql`، `supabase/tests/upgrade_hotfix_4_2_1_legacy_refunds.test.sql`، `scripts/run_upgrade_test_hotfix_4_2_1.sh`.

**اختبارات SQL مُعدَّلة (إضافات/تصحيحات مقصودة موثَّقة فقط، لا إعادة كتابة):** `supabase/tests/sales_returns_core.test.sql` (سيناريو 3 فقط)، `supabase/tests/sales_returns_concurrency.test.sql` (تنظيف + R5 + سيناريو R7 جديد).

**سكربت/إعداد HTTP مُعدَّلان:** `scripts/postgrest-http-test.mjs` (تأكيدات Hotfix 4.2.1 جديدة + إصلاح استقرار تاريخ `todayIso`)، `supabase/tests/postgrest_http_test_setup.sql` (إصلاح استقرار: بيانات سعر ذهب تأسيسية لكلا `current_date`/`business_today()`).

**كود TypeScript مُعدَّل:** `src/types/database.ts`، `src/features/returns/schema.ts`، `src/features/returns/actions.ts`، `src/features/returns/queries.ts` (تعليق توثيقي فقط)، `src/features/returns/components/refund-events-panel.tsx`، `src/app/(app)/returns/[id]/page.tsx`.

**اختبار Vitest جديد بالكامل:** `src/features/returns/components/refund-events-panel.test.tsx`.

**لم يتغيَّر إطلاقًا:** أي ترحيل من 0001–0105 (شاملة كل ترحيلات Phase 4/Patch 4.1/Patch 4.2)، أي جزء آخر من طبقة TypeScript خارج ما ذُكِر أعلاه، القفل الاستشاري `acquire_returns_order_lock_exclusive`، بقية سطح اختبار SQL (11 ملفًا خارج ما ذُكِر أعلاه، غير مُعدَّلة منطقيًا).

### 6) مفاهيم أساسية — شرح مختصر (طلب المستخدم صراحةً في بند التسليم 23.7)

1. **نموذج الإلغاء الإلحاقي الحقيقي لدفتر الاسترداد:** بدل تعديل الصف الأصلي لحدث الاسترداد عند إلغائه (كما كانت الدالة القديمة تفعل)، يُدرَج الآن سجل جديد في جدول ملحق منفصل (`sales_return_refund_event_reversals`)، ومُشغِّلا قاعدة بيانات صريحان يرفضان أي تعديل/حذف مباشر على الصف الأصلي — فيصبح دفتر الاسترداد إلحاقيًا حقيقيًا فعليًا (Append-Only)، لا مجرد تسمية، وحالة كل حدث (نشط/مُلغى) تُشتَق حيًّا من وجود سجل إلغاء له، لا تُقرَأ من عمود قابل للتعديل.
2. **Backfill الإلغاء الإلحاقي للبيانات الموروثة:** كل حدث استرداد قديم كان مُلغًى بالطريقة القديمة (تعديل في مكانه) يحصل، مرة واحدة أثناء الترقية، على سجل واحد بالضبط في الجدول الملحق الجديد يحمل نفس حقائق الإلغاء التاريخية بالضبط (لا اختلاق ولا تقريب) — فتتوافق كل الأحداث القديمة والجديدة على نفس النموذج فورًا بعد الترقية دون أي تدخل يدوي.
3. **أساس عكس العمولة على "مبلغ الاسترداد المعتمد" (v2)، لا قيمة الصنف:** المحرك الجديد يحسب المبلغ الواجب عكسه من العمولة استنادًا إلى المبلغ النقدي الذي اعتُمِد فعليًا للاسترداد (`approved_refund_amount`)، لا قيمة الصنف المُرتجَع الكاملة — يمنع عكس عمولة أكبر مما استُرِدَّ فعليًا للعميل، وهو العيب المالي الجوهري الذي هذه الرقعة كُلِّفت بإغلاقه تحديدًا.
4. **ترقيم إصدار حساب العمولة (`calculation_version`):** كل مرتجع معتمَد يحمل الآن علمًا صريحًا (`1`=محرك قديم، `2`=محرك جديد) يوثِّق بأي منطق حُسِبت قيمته الفعلية — القيم القديمة المحسوبة بالمنطق القديم **لا تُعاد حسابها صامتًا أبدًا** حتى لو كانت خاطئة تاريخيًا؛ الشفافية وحدها هي الهدف، لا التصحيح الرجعي للأرقام المالية المُقفَلة أصلًا.
5. **صلاحية البحث الخاصة ببيعة Returns:** دالة بحث جديدة ضيقة تخدم احتياج Returns فقط عن بيعة (رقمها، تاريخها، عميلها، إجماليها) دون أي اعتماد على صلاحية `sales.view` الكاملة — يملك مستخدم صلاحية إنشاء مرتجعات فقط (`returns.create`) الآن القدرة الكاملة على إنشاء مرتجع من الصفر دون الحاجة لمنحه صلاحية Sales كاملة لم يطلبها عمله.
6. **سلوك واجهة الاسترداد بعد إغلاق التسوية:** بمجرد إغلاق تسوية استرداد مرتجع (`refund_finalized_at`)، تختفي أزرار "تسجيل استرداد" و"تراجع" عن الاسترداد كليًا من الواجهة — لا تظهران معطَّلتين فقط، بل لا تُعرَضان إطلاقًا — حتى لا يضغط المستخدم على إجراء مضمون الرفض من الخادم أصلًا؛ زر "إعادة فتح التسوية" هو الوحيد المتاح في هذه الحالة.
7. **لقطة تاريخية لاسم/مرجع طريقة الاسترداد:** كل حدث استرداد يحفظ الآن اسم طريقة الدفع كما كان **وقت تسجيل الاسترداد بالضبط** (لا اسمها الحالي الذي قد يتغيَّر لاحقًا)، بالإضافة إلى مرجع خارجي اختياري (رقم تحويل بنكي، مرجع بوابة دفع) — فتبقى شاشة تفاصيل المرتجع صادقة تاريخيًا حتى لو أُعيدت تسمية طريقة الدفع لاحقًا.

**خلاصة الملحق التاسع عشر:** إغلاق نهائي للعيبين الجوهريين المتبقيين من Patch 4.2 — دفتر استرداد إلحاقي حقيقي فعليًا (لا تسمية فقط) بمُشغِّلات قاعدة بيانات صريحة تمنع أي تعديل مستقبلي على الصف الأصلي، ومحرك عكس عمولة v2 يستند إلى مبلغ الاسترداد المعتمد الفعلي لا قيمة الصنف — مع ترقيم إصدار حساب صريح يحمي كل قيمة تاريخية من إعادة الحساب الصامتة، Backfill ترقية مُثبَت بثلاثة سيناريوهات تُغطِّي كل تركيبة حالة قديمة ممكنة (نشط/مُلغى/بمحرك عمولة قديم)، دالة بحث Returns ضيقة تقطع الاعتماد الأخير المتبقي على صلاحية Sales الكاملة، وإصلاح واجهة حرج يمنع أي إجراء مضمون الفشل من الظهور أصلًا بعد إغلاق التسوية. **35 نقطة تحقق SQL مخصَّصة + 77 نقطة تحقق Core (صفر انحدار حقيقي) + 7/7 سيناريوهات تزامن حقيقية + 6 نقاط تحقق ترقية مخصَّصة (11/11 عام + 11/11 Patch 4.2 بلا تغيير) + صفر أخطاء عبر كامل مجموعة اختبارات SQL (14 ملفًا، قاعدة بيانات واحدة طازجة) + 81 تأكيدًا HTTP حقيقيًا + 52 اختبار Vitest (5 جديدة إلزامية لـSection 16) + 46/46 عمود NUMERIC + بناء إنتاجي ناجح — كلها من تشغيلات فعلية في هذه الجلسة. لم تبدأ Shipping ولا Settlements ولا Services/Adjustments ولا Inventory ولا Reports — العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP هذا الملحق.**

---

## الملحق العشرون — "Phase 5: نواة الشحن (Shipping Core)" (ترحيلات 0113–0121)

هذا الملحق يوثِّق **Phase 5** كاملة، بناءً على مواصفة المستخدم الصريحة المكوَّنة من 54 بندًا: **"نفّذ فقط"** — بناء نواة شحن مستقلة ماليًا تمامًا عن المبيعات، بربحية شحن (`net_shipping_expected`/`net_shipping_actual`) منفصلة تمامًا عن ربحية المبيعات، مع نموذج بيانات شركات شحن/مناطق بلا أي تحويز بالاسم في أي منطق خادم، تسعير شركات شحن مُنسَّخ (versioned) بنفس فلسفة Phase 2، رسوم شحن إرجاع للعميل مُهيَّأة بحسب المنطقة (35.00 الرياض/50.00 خارجها)، دورة حياة حالة شحنة إضافية-فقط تتضمن `customer_never_received` كحالة أولى، تكلفة شركة شحن متوقعة (مع بوابة إفلات يدوية) منفصلة تمامًا عن التكلفة الفعلية (سجل إضافي-فقط)، شحنات إرجاع مرتبطة بمرتجع Sales موجود، دفع عند الاستلام (COD) تشغيلي بحت بلا أي أثر مالي محاسبي، إغلاق يومي مُعاد استخدامه من Sales/Returns، وحماية ربح على مستوى القاعدة. القيود الصارمة كالمعتاد وبقيت سارية طوال هذا الملحق: **"لا تعدل أي migration من 0001 إلى 0112"** — كل ترحيلة جديدة بدأت من 0113 فصاعدًا (تسع ترحيلات: 0113–0121)؛ **"لا تبدأ Settlements"**، **"لا تبدأ Services/Adjustments"**، **"لا تبدأ Inventory"**، **"لا تبدأ Reports/PDF/Excel"**، **"لا أي تكامل API لشركة شحن، ولا Salla، ولا أي تكامل خارجي آخر"**؛ **"لا تخلط ربح الشحن بربح المبيعات"**. العمل **متوقف الآن نهائيًا**: **"بعد التسليم: توقف وانتظر مراجعة المستخدم — لا تبدأ Settlements أو أي مرحلة تالية تلقائيًا."**

### 1) الترحيلات الجديدة (0113–0121)

| # | الترحيلة | تُضيف |
|---|---|---|
| 0113 | `shipping_master_data_schema.sql` | صلاحيات جديدة (`shipments.manage_cost`/`shipments.correct_status`/`shipments.process_closed_day`/`shipping_rates.view`/`shipping_rates.manage`)؛ قفل استشاري جديد لتسعير الشحن (`acquire_shipping_rates_lock_shared/exclusive`، `key1=1005`، يطابق نمط `acquire_financial_master_lock_shared/exclusive` 0065 حرفيًا)؛ جداول Master Data `shipping_carriers`/`shipping_zones` بـRLS مباشرة (مثل `karats`) مقيَّدة بـ`shipping_rates.view`/`manage` — بلا أي عمود اسم شركة شحن يُستخدَم في أي شرط منطقي بأي دالة لاحقة. |
| 0114 | `shipping_carrier_rate_versions.sql` | نسخ تسعير شركات شحن مُنسَّخة (`shipping_carrier_rate_versions`) بنفس فلسفة Phase 2 حرفيًا (`NUMERIC`، بلا تداخل، نسخة مستقبلية واحدة كحد أقصى، إنهاء القديم/إدراج الجديد ذريًّا عبر `FOR UPDATE`)؛ `create_shipping_carrier_rate_version()`/`cancel_shipping_carrier_rate_version()`؛ بذرة أرقام حقيقية: SMSA/ARAMEX=17.00 وBarq/RedBox=15.00 لتكلفة إرجاع (`return`). |
| 0115 | `customer_return_shipping_fee_versions.sql` | نفس آلية التنسيخ لرسوم شحن الإرجاع على العميل حسب المنطقة (`customer_return_shipping_fee_versions`)؛ بذرة: الرياض=35.00، خارج الرياض=50.00. |
| 0116 | `shipments_schema.sql` | الجداول الثلاثة الأساسية — `shipments` (الرأس، **صفر سياسات RLS مباشرة**، يخلط أعمدة حسّاسة للربح بأخرى غير حسّاسة، كنمط `sales_orders`/`sales_returns` حرفيًا)، `shipment_status_events` (سجل حالة إضافي-فقط، مُشغِّل رفض غير مشروط ضد `UPDATE`/`DELETE` **بلا بوابة إفلات إطلاقًا** — لا بيانات موروثة لترحيلها)، `shipment_financial_events` (دفتر مالي موحَّد إضافي-فقط، `event_type IN (actual_cost_recorded, actual_cost_correction, customer_charge_correction)`، نفس حماية الحذف/التعديل). قيد CHECK حقيقي يفرض `direction='return'` كلما وُجِد `sales_return_id` (Section 23). |
| 0117 | `create_shipment.sql` | `preview_shipment_expected_cost()`/`preview_customer_return_shipping_fee()` (معاينة بلا `shipping_rates.view`، مقيَّدة بـ`shipments.create` فقط)؛ `create_shipment()` — نقطة الدخول المعاملاتية الوحيدة: تحقُّق صلاحية/حالة نشطة/رؤية البيعة الأصلية/قابلية تشغيل المتجر/صحة ربط المرتجع إن وُجِد/نشاط شركة الشحن والمنطقة/عدم تاريخ مستقبلي/تطابق تاريخ الشحنة مع البيعة أو المرتجع، قفل الإغلاق اليومي المشترك، ثم حلّ التسعير القياسي أو قبول تكلفة يدوية + سبب إلزامي إن لم يوجد تسعير مُهيَّأ (Section 17 — لا افتراض صفر أبدًا)، حساب `net_shipping_expected` مستقل تمامًا عن ربح المبيعات، كتابة رأس الشحنة وأول حدث حالة (`created`) ذريًّا. |
| 0118 | `shipment_status_and_financial_correction_rpcs.sql` | `add_shipment_status_event()` (انتقال طبيعي بصلاحية `shipments.update_status`، أو تصحيح خارج التدفق بصلاحية `shipments.correct_status` + سبب إلزامي، تزامن تفاؤلي بقفل الصف أولًا ثم مقارنة `row_version`)؛ `record_shipment_actual_cost()` (أول تسجيل فقط، يُرفَض إن وُجِد سجل سابق)؛ `correct_shipment_actual_cost()` (تصحيح إلزامي السبب لسجل موجود)؛ `correct_shipment_customer_charge()` (تصحيح إلزامي السبب لرسوم الشحن على العميل، **لا يُعدِّل اللقطة الأصلية أبدًا** — يكتب حدثًا جديدًا في الدفتر فقط). الأربعة جميعًا بقفل الإغلاق اليومي المشترك على تاريخ العملية المالية نفسها (لا تاريخ الشحنة)، ونطاق `user_visible_store_ids()` (تصحيح سجل قائم، لا إنشاء جديد). |
| 0119 | `shipment_read_rpcs.sql` | `get_shipment()` (`jsonb`، دمج شرطي لكل مفتاح حسّاس للربح — **غياب تام** لا `null` بدون `sales.view_profit`)؛ `list_shipments()` (جدولية، أعمدة الربح تُعاد `NULL` صريحًا للفاعل بلا الصلاحية، `total_count` دومًا). |
| 0120 | `shipment_narrow_lookups.sql` | ست دوال بحث/اختيار ضيقة (`shipments_operable_store_lookups`/`shipments_visible_store_lookups`/`shipments_carrier_lookups`/`shipments_zone_lookups`/`search_sales_orders_for_shipment`/`search_sales_returns_for_shipment`) — كل واحدة مقيَّدة بالصلاحية الدقيقة التي تحتاجها فعليًا فقط، أبدًا `shipping_rates.view`/`stores.view`/`sales.view`، بنفس نمط Section 7/15 من Returns. |
| 0121 | `audit_logs_shipping_profit_protection.sql` | توسيع سياسة `audit_logs_select` (0072/0091) لتشمل **أربعة أفعال مالية محدَّدة صراحةً فقط** (`shipment.create`/`shipment.cost_record`/`shipment.cost_correct`/`shipment.charge_correct`) تحت شرط `sales.view_profit` — **مختلف عمدًا** عن نمط `sale.%`/`return.%` الشامل بالبادئة: `shipment.status_add`/`shipment.closed_day_override` (بلا رقم مالي) تبقيان ظاهرتين لأي فاعل يملك `audit_logs.view` فقط. |

### 2) الجداول الجديدة (7) ونموذج الوصول

**نموذج RPC-فقط (صفر سياسات RLS مباشرة، مطابق لِـ`sales_orders`/`sales_returns` حرفيًا):** `shipments`، `shipment_status_events`، `shipment_financial_events`. الثلاثة تُقرَأ حصرًا عبر `get_shipment()`/`list_shipments()` وتُكتَب حصرًا عبر الخمس دوال الكتابية في 0117/0118، جميعًا `SECURITY DEFINER`. `shipment_status_events`/`shipment_financial_events` محميتان بمُشغِّل رفض غير مشروط ضد `UPDATE`/`DELETE` **بلا أي بوابة إفلات** (خلافًا لِـ`app.allow_refund_event_backfill` في Returns — Phase 5 لا بيانات موروثة تحتاج Backfill) — ما يجعل كل شحنة تُنشَأ **غير قابلة للحذف نهائيًا** (قيود `ON DELETE RESTRICT` من الجدولين إلى `shipments`، ومن `shipments` نفسها إلى `sales_orders`/`sales_returns`)، بنفس فلسفة "لا حذف فعلي إطلاقًا" القائمة في المشروع لكن بلا استثناء واحد هذه المرة.

**نموذج Master Data (RLS مباشرة، مطابق لِـ`karats` حرفيًا):** `shipping_carriers`، `shipping_zones`، `shipping_carrier_rate_versions`، `customer_return_shipping_fee_versions` — مقيَّدة بـ`shipping_rates.view`/`manage`، منفصلة تمامًا عن صلاحيات `shipments.*` حتى يستطيع موظف شحن ميداني (`shipments.create`) العمل بلا أي صلاحية Master Data، ويستطيع مسؤول تسعير تكوين الأسعار بلا أي صلاحية `shipments.*`.

### 3) الصفحات والمكوّنات الجديدة

`/shipments` (قائمة مع فلاتر وأعمدة ربح مشروطة بالصلاحية)، `/shipments/new` (اختيار اتجاه ثم بحث عن بيعة/مرتجع، ثم نموذج إدخال كامل مع معاينة تسعير حيّة)، `/shipments/[id]` (تفاصيل + سجل زمني للحالة + سجل مالي مشروط بالربح + إجراءات حالة/مالية). مكوّنات: `shipment-order-search.tsx`، `shipment-entry-form.tsx` (معاينة `preview_shipment_expected_cost()`/`preview_customer_return_shipping_fee()` الحيّة، حقول تكلفة يدوية تظهر تلقائيًا عند غياب تسعير، حوار سبب اليوم المقفل)، `shipment-status-actions.tsx` (كل الحالات معروضة، الخادم هو المرجع الوحيد لتصنيف الانتقال طبيعي/تصحيح)، `shipment-financial-actions.tsx` (تسجيل/تصحيح تكلفة فعلية، تصحيح رسوم شحن العميل). طبقة الخلفية: `src/features/shipping/{schema,queries,actions}.ts`.

### 4) الصلاحيات الجديدة (5)

`shipments.manage_cost`، `shipments.correct_status`، `shipments.process_closed_day` (0113 — تُمنَح بنفس نمط منح `returns.reverse`/`returns.record_refund`/`returns.process_closed_day`)، `shipping_rates.view`، `shipping_rates.manage` (Master Data مستقلة تمامًا عن `shipments.*`). `shipments.view`/`shipments.create`/`shipments.update_status` كانت مُعرَّفة مسبقًا في `seed.sql` دون أي RPC يستهلكها فعليًا — هذه المرحلة أول استهلاك حقيقي لها، تمامًا كحال `returns.*` في Phase 4.

### 5) قرارات تصميم أساسية — شرح مختصر لكل قرار (طلب المستخدم صراحةً في بند التسليم 54.9)

1. **نموذج شركات الشحن/المناطق (Master Data منفصلة عن التسعير):** `shipping_carriers`/`shipping_zones` جدولا مرجع مستقلان عن جداول التسعير — يسمح بإضافة/تعطيل شركة شحن أو منطقة بلا أي أثر رجعي على تسعير تاريخي، ويُبقي كل منطق الخادم يعمل بمعرِّفات (`uuid`) لا أسماء نصية، فلا يوجد سطر منطق واحد في أي دالة يفرِّق سلوكه بناءً على اسم شركة شحن — التزامًا حرفيًا بقيد "بلا أي تحويز بالاسم".
2. **تسعير شركات الشحن مُنسَّخ (Versioned)، لا عمود سعر واحد يُعدَّل في مكانه:** يطبِّق فلسفة Phase 2 نفسها حرفيًا (`NUMERIC`، بلا تداخل زمني، نسخة مستقبلية واحدة كحد أقصى، إنهاء القديم وإدراج الجديد ذريًّا) — يضمن أن أي شحنة قديمة تحتفظ بلقطة السعر الذي كان ساريًا فعليًا وقت إنشائها، حتى لو جُدوِلت أسعار جديدة لاحقًا (مُثبَت فعليًا بالقسم 44 من الاختبار).
3. **رسوم شحن الإرجاع على العميل كاقتراح قابل للتجاوز، لا قيمة مفروضة:** `preview_customer_return_shipping_fee()` تقترح فقط؛ `create_shipment()` تقبل أي قيمة يُرسِلها الفاعل فعليًا دون استبدالها صامتًا — فرق جوهري عن "فرض" الرقم المؤسَّس، لأن حالات استثنائية حقيقية (تعويض عميل، اتفاق خاص) تحتاج قيمة مختلفة أحيانًا، دون أن تمس هذه القيمة أي عمود في سجل المرتجع المالي نفسه.
4. **التكلفة المتوقعة مقابل التكلفة الفعلية — عمودان/مفهومان منفصلان تمامًا، لا رقم واحد يُحدَّث في مكانه:** `expected_carrier_cost` لقطة وقت الإنشاء (تلقائية من التسعير المُنسَّخ، أو يدوية مع سبب إلزامي)؛ `actual_carrier_cost` عمود ذاكرة مؤقتة (Cache) يُحسَب من آخر حدث في دفتر `shipment_financial_events` — الفرق بينهما هو بالضبط الفرق بين "ما كان مُتوقَّعًا" و"ما حدث فعليًا"، ولا يُفرَض تطابقهما تلقائيًا أبدًا.
5. **دورة حياة الحالة إضافية-فقط بآلة حالة، لا عمود حالة يُعدَّل مباشرة:** كل تحديث حالة يُضيف سجلًا جديدًا في `shipment_status_events` (لا `UPDATE` على سجل قديم)؛ `shipments.current_status` عمود ذاكرة مؤقتة يُحدَّثه `add_shipment_status_event()` فقط. الانتقال يُصنَّف تلقائيًا "طبيعي" (يكفي `shipments.update_status`) أو "تصحيح" (يحتاج `shipments.correct_status` + سبب إلزامي) بناءً على آلة حالة صريحة (`validate_shipment_status_transition()`، 0116) — الخادم هو المرجع الوحيد لهذا التصنيف، لا الواجهة أبدًا.
6. **`customer_never_received` حالة من الدرجة الأولى في آلة الحالة، لا استثناءً يتطلب تصحيحًا:** المسار الكامل `out_for_delivery → delivery_failed → customer_never_received → returned_to_store` مُعرَّف كسلسلة انتقالات **طبيعية** بالكامل — لأن هذا سيناريو تشغيلي متكرر واقعيًا (فشل تسليم متكرر، عميل غير متجاوب)، وليس حالة شاذة نادرة تستحق عبء التصحيح الإداري في كل مرة.
7. **دفتر التكلفة الفعلية إضافي-فقط، لا عمود واحد يُصحَّح في مكانه:** `record_shipment_actual_cost()` (أول تسجيل فقط) و`correct_shipment_actual_cost()` (تصحيح إلزامي السبب) كلاهما يُضيفان سجلًا جديدًا في `shipment_financial_events` — التاريخ المالي الكامل (من سجَّل ماذا ومتى ولماذا) محفوظ دومًا، بينما `shipments.actual_carrier_cost`/`net_shipping_actual` يعكسان دومًا آخر قيمة فقط، بنفس فلسفة `sales_return_refund_events` القائمة تمامًا.
8. **شحنة الإرجاع مرتبطة بمرتجع Sales موجود فعلًا، لا نوع شحنة مستقل:** `p_sales_return_id` اختياري في `create_shipment()`، لكن قيد CHECK حقيقي على مستوى الجدول (لا فحص تطبيقي فقط) يفرض `direction='return'` كلما وُجِد؛ `create_shipment()` نفسها تتحقق أن المرتجع معتمَد/متراجَع عنه فعليًا (لا قيد المراجعة/مرفوض) وينتمي لنفس البيعة، وأن اتجاه `outbound` **لا يمكن أبدًا** أن يحمل `sales_return_id` — يمنع أي شحنة إرجاع يتيمة أو مرتبطة بمرتجع غير صالح.
9. **دفع عند الاستلام (COD) تشغيلي بحت، بلا أي أثر مالي محاسبي:** `is_cod`/`cod_expected_amount`/`cod_collection_state` أعمدة معلوماتية فقط على رأس الشحنة — لا تُنشئ أي قيد محاسبي، ولا تؤثر على `net_shipping_expected`/`net_shipping_actual`، تمامًا كما هي مُعرَّفة صراحةً في المواصفة (نطاق التسوية المالية الحقيقية لِـCOD مؤجَّل عمدًا لمرحلة Settlements القادمة، غير المبدوءة الآن).
10. **حماية الربح على مستوى القاعدة تعيد استخدام `sales.view_profit` القائمة، لا صلاحية `shipments.view_profit` جديدة:** نفس القرار المتكرر في كل مرحلة سابقة (Phase 3/Phase 4) — ربحية الشحن (`net_shipping_expected`/`net_shipping_actual`) بيانات مالية حسّاسة من نفس الفئة، فمن الطبيعي أن تُحكَم بنفس صلاحية رؤية الربح الموحَّدة عبر النظام كله، لا صلاحية مُجزَّأة لكل وحدة على حدة.

### 6) التدقيق (Audit) — تصنيف مختلف عمدًا عن نمط `sale.%`/`return.%`

ست فعاليات جديدة، مكتوبة صراحةً داخل كل RPC (لا Trigger عام، لنفس سبب المراحل السابقة): `shipment.create`، `shipment.status_add`، `shipment.cost_record`، `shipment.cost_correct`، `shipment.charge_correct`، `shipment.closed_day_override`. ترحيلة 0121 **لا** تستخدم نمط البادئة الشامل (`shipment.%`) — بدلًا من ذلك تُدرِج **أربعة أفعال محدَّدة صراحةً فقط** (التي تحمل رقمًا ماليًا فعليًا) ضمن شرط `sales.view_profit`، تاركةً `shipment.status_add`/`shipment.closed_day_override` (بلا رقم مالي) ظاهرتين لأي فاعل يملك `audit_logs.view` فقط — قرار تصميم مُوثَّق صراحةً في تعليق الترحيلة نفسها كمفاضلة متعمَّدة: موظف شحن ميداني (`shipping_employee`) يستطيع قراءة أثر عمله التشغيلي الخاص دون الحاجة لصلاحية ربح لم يطلبها عمله، بخلاف نمط Returns الذي يُغطِّي **كل** إجراء مستقبلي تلقائيًا بالبادئة الشاملة. تسميات عربية جديدة في `src/lib/audit/action-labels.ts` (6 أفعال + كيانا `shipment`).

### 7) حماية الربح على مستوى القاعدة — نفس آلية Sales/Returns حرفيًا

`get_shipment()`/`list_shipments()` تُخفيان كل مفتاح حسّاس للربح (`customer_shipping_charge`/`effective_customer_shipping_charge`/`expected_carrier_cost`/`actual_carrier_cost`/`net_shipping_expected`/`net_shipping_actual`/`cod_expected_amount`/`financial_events`) بشرط `sales.view_profit` — **إعادة استخدام الصلاحية القائمة نفسها بالضبط**، بنفس نمط Phase 3/4: المفتاح **غائب تمامًا** من كائن JSON في `get_shipment()` (لا `null`)، و`null` صريح في صفوف `list_shipments()` الجدولية.

### 8) الاختبارات — قائمة كاملة وأرقام فعلية (نُفِّذت في هذه الجلسة)

تفصيل كامل بالأرقام في `TEST_RESULTS_PHASE_5.md`. ملخَّص:

- إعادة بناء قاعدة اختبار Postgres محلية **من الصفر بالكامل** أكثر من مرة (بما فيها إعادة بناء بعد إصلاح عيب حقيقي اكتُشِف أثناء الجلسة): `local_harness_setup.sql`، **كل الترحيلات 0001–0121 بالترتيب دون توقف** (121/121 نجحت)، ثم `supabase/seed.sql` (نجح).
- كل ملفات اختبار SQL القائمة (19 ملفًا من Foundation حتى Hotfix 4.2.1) أُعيد تشغيلها **ضمن نفس التشغيلة المتسلسلة** على القاعدة نفسها → **نجحت جميعًا، صفر انحدار**.
- `supabase/tests/shipping_core_phase5.test.sql` (جديد بالكامل، الأقسام 44–49) → **نجح بالكامل**، شاملًا **عيبين حقيقيين في PL/pgSQL اكتُشِفا وأُصلِحا** أثناء التحقق (سجل RECORD غير مُهيَّأ يُقرَأ خارج الحارس الذي يضمن تعيينه).
- `supabase/tests/shipping_core_phase5_concurrency.test.sql` (جديد بالكامل، `dblink` حقيقي) → **نجح بالكامل، A–F، 6/6 سيناريوهات**.
- إثبات ترقية مخصَّص (بيانات بيع حقيقية سابقة لـPhase 5 عبر `create_sales_order()`، ثم تطبيق 0113–0121 كخطوة ترقية منفصلة) → **نجح، صفر تغيير على البيانات القديمة، وشحنة حقيقية أُنشِئت بنجاح على طلب بيع موجود مسبقًا قبل الترقية**.
- اختبار HTTP/PostgREST الحقيقي (`scripts/run_postgrest_http_test.sh`) → **نجح، 101/101 تأكيد** (81 قائمة + 20 جديدة لِـPhase 5)، ضد ثنائي PostgREST v12.2.3 حقيقي عبر HTTP فعلي. **عيب حقيقي ثالث اكتُشِف وأُصلِح بهذا التشغيل بالذات:** `preview_shipment_expected_cost()`/`preview_customer_return_shipping_fee()` (0117) كانتا تُعيدان `numeric` خامًا بدل `text` — مخالفة صريحة لنمط كل دالة `preview_*` أخرى في المشروع، أُصلِح مباشرة في نفس الترحيلة 0117 (لم تُسلَّم بعد) قبل أن تُختَم هذه الجلسة.
- `npm run check:numeric-types` → **نجح، 55/55 عمود NUMERIC مطابق** (يشمل 8 أعمدة جديدة في `shipments`/`shipment_financial_events`/`shipping_carrier_rate_versions`).
- `npx tsc --noEmit` → **صفر أخطاء**.
- `npx eslint .` → **صفر أخطاء وتحذيرات**.
- `npx vitest run` → **52/52 ناجح عبر 7 ملفات** (بلا تغيير — Phase 5 لم يضف/يمسّ أي وحدة اختبار Vitest قائمة).
- `npm run build` (Next.js/Turbopack) → **نجح**، **بزيادة 3 مسارات Shipping**: `/shipments`، `/shipments/new`، `/shipments/[id]`.

### 9) الملفات/الترحيلات التي تغيَّرت أو أُضيفت في Phase 5 (قائمة كاملة)

**ترحيلات جديدة (9):** `0113_shipping_master_data_schema.sql`، `0114_shipping_carrier_rate_versions.sql`، `0115_customer_return_shipping_fee_versions.sql`، `0116_shipments_schema.sql`، `0117_create_shipment.sql`، `0118_shipment_status_and_financial_correction_rpcs.sql`، `0119_shipment_read_rpcs.sql`، `0120_shipment_narrow_lookups.sql`، `0121_audit_logs_shipping_profit_protection.sql`.

**اختبارات SQL جديدة بالكامل:** `supabase/tests/shipping_core_phase5.test.sql`، `supabase/tests/shipping_core_phase5_concurrency.test.sql`.

**سكربتات/إعداد HTTP مُعدَّلان (إضافة فقط، لا حذف):** `scripts/postgrest-http-test.mjs` (قسم "Part 8" الجديد)، `supabase/tests/postgrest_http_test_setup.sql` (منح صلاحيات Shipping لممثِّلَي الاختبار القائمَين، إصلاح استقرار `ON CONFLICT` لبيانات سعر الذهب التأسيسية).

**كود TypeScript جديد بالكامل:** `src/features/shipping/{schema,queries,actions}.ts`، `src/features/shipping/components/{shipment-order-search,shipment-entry-form,shipment-status-actions,shipment-financial-actions}.tsx`، `src/app/(app)/shipments/page.tsx` (استبدال الواجهة المؤقتة "قريبًا")، `src/app/(app)/shipments/new/page.tsx`، `src/app/(app)/shipments/[id]/page.tsx`.

**كود TypeScript مُعدَّل:** `src/types/database.ts` (7 أنواع/جداول جديدة + 19 دالة جديدة)، `src/lib/permissions/constants.ts` (5 مفاتيح صلاحيات جديدة + تصنيف عربي جديد لـ`shipping_rates`)، `src/lib/constants.ts` (`ROUTES.shipmentsNew`).

**لم يتغيّر إطلاقًا:** أي ترحيل من 0001–0112، أي اختبار SQL قائم (منطقًا)، أي صفحة/مكوّن خارج ما ذُكِر أعلاه.

**خلاصة الملحق العشرون:** نواة شحن كاملة وظيفيًا ومستقلة ماليًا تمامًا عن المبيعات — نموذج بيانات شركات شحن/مناطق بلا أي تحويز بالاسم في أي منطق خادم، تسعير مُنسَّخ يحافظ على لقطات تاريخية حتى مع أسعار مستقبلية مُجدوَلة (مُثبَت تحت تزامن حقيقي)، رسوم شحن إرجاع مؤسَّسة قابلة للتجاوز دومًا، تكلفة متوقعة/فعلية كمفهومين منفصلين تمامًا مع بوابة إفلات يدوية موثَّقة السبب، دورة حياة حالة إضافية-فقط بآلة حالة صريحة تتضمن `customer_never_received` كحالة أولى، دفتر تكلفة فعلية إضافي-فقط بلا أي بوابة إفلات حذف على الإطلاق، شحنات إرجاع مرتبطة فعليًا بمرتجعات معتمَدة بقيد قاعدة بيانات حقيقي، دفع عند الاستلام تشغيلي بحت بلا أي أثر محاسبي، إغلاق يومي مُعاد استخدامه بالكامل من Sales/Returns، وحماية ربح على مستوى القاعدة تصمد أمام أي مسار تجاوز (مُثبَتة عبر HTTP حقيقي أيضًا). **ثلاثة عيوب حقيقية اكتُشِفت وأُصلِحت أثناء هذه الجلسة نفسها** (اثنان في PL/pgSQL داخل `create_shipment()`، وواحد في نقل الأرقام العشرية عبر HTTP في دالتَي المعاينة) — كلها قبل أي تسليم فعلي، بلا أي حاجة لترحيلة تصحيحية منفصلة. **6/6 أقسام اختبار SQL جديدة + 6/6 سيناريوهات تزامن حقيقية (A–F) + صفر أخطاء عبر 19 ملف اختبار SQL قائم + إثبات ترقية فعلي على بيانات بيع حقيقية + 101 تأكيدًا HTTP حقيقيًا (81 سابقة + 20 جديدة) + 52 اختبار Vitest + 55/55 عمود NUMERIC + بناء إنتاجي ناجح — كلها من تشغيلات فعلية في هذه الجلسة. لم تبدأ Settlements ولا Services/Adjustments ولا Inventory ولا Reports/PDF/Excel ولا أي تكامل شركة شحن/Salla — العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP هذا الملحق.**

---

## الملحق الحادي والعشرون — "Phase 5 Shipping Integrity Patch 5.1" (ترحيلات 0122–0130)

هذا الملحق يوثِّق **Patch 5.1** كاملة، وهو رد مباشر على رفض المستخدم اعتماد Phase 5 بعد مراجعة على مستوى الكود المصدري ("لا أعتمد Phase 5 حتى الآن")، تلاه طلب صريح بعنوان **"Phase 5 — Shipping Integrity Patch 5.1"** مكوَّن من 33 بندًا تقنيًا: إغلاق فجوات RLS حقيقية على جداول التسعير المُنسَّخ (كتابة مباشرة كانت ممكنة نظريًا عبر PostgREST رغم وجود RPC)، تغطية قفل استشاري على مستوى الجدول لكل مسار كتابة (لا الدوال الرسمية فقط)، لقطة رسوم شحن إرجاع للعميل مع سبب تجاوز إلزامي حين يختلف عن القيمة المؤسَّسة، تصحيح عيب حقيقي في `/shipments` كان يستدعي دوال بحث مقيَّدة بصلاحية `shipments.create` لفاعل يملك `shipments.view` فقط، فلاتر بحث جديدة (رقم بيعة/رقم مرتجع/متجر البيعة الأصلية/حالة تحصيل COD)، دورة حياة تحصيل دفع عند الاستلام (COD) صريحة، إغلاق ثغرة تزامن حقيقية بين مراجعة مرتجع وإنشاء شحنة إرجاع لنفس المرتجع، لقطات تاريخية لاسم/رمز شركة الشحن والمنطقة تصمد أمام إعادة تسمية لاحقة، سجل تسلسل زمني (Chronology) صريح لأحداث الحالة/COD يرفض أي حدث خارج الترتيب الزمني، واجهة إدارة كاملة لتسعير الشحن (Shipping Rate Admin UI)، وتصحيح عيب حقيقي في اختبار الأمان-الربحي القائم كان يفترض خطأً أن `customer_shipping_charge` يجب أن يكون محجوبًا. القيود الصارمة كالمعتاد وبقيت سارية طوال هذا الملحق: **"لا تعدل أي migration من 0001 إلى 0121"** — كل ترحيلة جديدة بدأت من 0122 فصاعدًا (تسع ترحيلات: 0122–0130)؛ **"لا تبدأ Settlements"**، **"لا تبدأ Services/Adjustments"**، **"لا تبدأ Inventory"**، **"لا تبدأ Reports"**، **"لا أي تكامل API لشركة شحن"**؛ **"التسليم القادم يجب أن يكون ZIP كاملًا للمشروع، لا ZIP فروقات"** — للتحقق من تجميد كل المراحل السابقة بايتًا-ببايت من نفس الأصل. العمل **متوقف الآن نهائيًا**: **"توقف وانتظر مراجعة المستخدم — لا تبدأ أي مرحلة تالية تلقائيًا."**

### 1) الترحيلات الجديدة (0122–0130)

| # | الترحيلة | تُضيف |
|---|---|---|
| 0122 | `shipping_rate_versioning_lockdown.sql` | إغلاق فجوة RLS حقيقية: سياستا `INSERT`/`UPDATE` لـ`authenticated` على `shipping_carrier_rate_versions`/`customer_return_shipping_fee_versions` كانتا موجودتين رغم وجود RPC مخصَّص، ما يسمح نظريًا بكتابة مباشرة عبر PostgREST تتجاوز فحوصات `create_shipping_carrier_rate_version()`/`cancel_*()` بالكامل — تُحذَف السياستان، ويبقى `SELECT` فقط؛ كل كتابة تمر إلزاميًا عبر SECURITY DEFINER RPC من الآن فصاعدًا (بند 1). قيد استبعاد GIST حقيقي (`btree_gist`) يفرض عدم تداخل نطاقات التاريخ على مستوى القاعدة نفسها، لا فحصًا تطبيقيًا فقط فوق قفل استشاري وحده (بند 2). |
| 0123 | `shipping_rate_table_level_lock.sql` | مُشغِّل `BEFORE STATEMENT` جديد على الجدولين يستدعي `acquire_shipping_rates_lock_exclusive()` تلقائيًا لكل عملية كتابة — يغطي أي مسار كتابة مستقبلي حتى لو نُسِي استدعاء القفل صراحةً داخل RPC جديدة لاحقًا؛ الدالة `SECURITY INVOKER` ومَمنوحة لكل من `authenticated`و`service_role` (درس Hotfix 3.2.1 نفسه: مُشغِّل SECURITY INVOKER يعمل بصلاحيات الدور المستدعي) (بند 4). |
| 0124 | `shipping_master_data_hardening_and_audit.sql` | تثبيت `enforce_system_managed_columns()`/`enforce_created_by_immutable()` (من 0021) على `shipping_carriers`/`shipping_zones`/كلا جدولي التسعير — يمنع انتحال `created_by`/`created_at` عبر PostgREST؛ رمز الشركة/المنطقة (`code`) غير قابل للتعديل بعد الإنشاء (بند 6). مُشغِّلات تدقيق مخصَّصة (لا عامة) تكتب `shipping_rate.create`/`customer_return_shipping_fee.create`/`shipping_carrier.create`/`shipping_carrier.update`/`shipping_zone.create`/`shipping_zone.update` إلى `audit_logs` (بند 7). |
| 0125 | `customer_return_shipping_fee_snapshot.sql` | لقطة رسوم شحن الإرجاع على العميل: `customer_return_shipping_fee_version_id`/`customer_return_shipping_fee_standard_amount`/`customer_return_shipping_charge_is_override`/`customer_return_shipping_charge_override_reason` أعمدة جديدة على `shipments`؛ `create_shipment()` تُعاد كتابتها لتفرض **سبب تجاوز إلزامي** كلما اختلفت `customer_shipping_charge` المُرسَلة عن القيمة المؤسَّسة الحالية (بند 9) — القيمة القياسية والفعلية تُحفَظان معًا دومًا، فلا يضيع أثر ما كان "الطبيعي" مقابل ما "حدث فعليًا" (بند 8). قيد إضافي: شحنة إرجاع جديدة تُرفَض إن كان المرتجع المرتبط بها في حالة `reversed` (بند 15)، وقفل صف `FOR UPDATE` على المرتجع داخل `create_shipment()` يُغلِق سباقًا حقيقيًا مع `reverse_sales_return()` (بند 16). |
| 0126 | `shipment_reads_visibility_and_filters.sql` | إعادة كتابة `get_shipment()`/`list_shipments()`: `customer_shipping_charge`/`effective_customer_shipping_charge` تُصبِحان **ظاهرتين دومًا** بلا اشتراط `sales.view_profit` — لأنهما رسوم تشغيلية على العميل، لا ربحًا داخليًا (بند 10، تصحيح الخلط القائم في Phase 5 الأصلية)؛ عمود جديد `has_actual_carrier_cost` (منطقي، ظاهر دومًا) يسمح لفاعل تشغيلي بمعرفة "هل سُجِّلت تكلفة فعلية؟" دون رؤية الرقم نفسه (بند 23). فلاتر بحث جديدة في `list_shipments()`: `order_number`/`return_number`/`original_sale_store_id`/`cod_collection_state` (بند 12)؛ دالتا بحث ضيقتان جديدتان `shipments_filter_carrier_lookups()`/`shipments_filter_zone_lookups()` مقيَّدتان بـ`shipments.view` فقط — تصحيح العيب الحقيقي في `/shipments` الذي كان يستدعي `shipments_carrier_lookups()`/`shipments_zone_lookups()` المقيَّدتين بـ`shipments.create` (بند 11). |
| 0127 | `shipment_cod_collection_workflow.sql` | جدول جديد `shipment_cod_events` (إضافي-فقط، بلا أي بوابة إفلات، بنفس فلسفة `shipment_status_events`)؛ `record_shipment_cod_collection_state()` — دورة حالة COD صريحة (`not_collected`/`collected`/`partially_collected`/`refused`/`not_applicable`) بتزامن تفاؤلي وقفل إغلاق يومي مشترك؛ `shipments.cod_collection_state` عمود ذاكرة مؤقتة يُحدَّثه هذا RPC فقط (بندان 13، 14). |
| 0128 | `shipment_return_search_approved_only.sql` | `search_sales_returns_for_shipment()` تُستثنى منها المرتجعات في حالة `reversed` — توازي منطقيًا قيد 0125 على مستوى الإنشاء نفسه، فلا يظهر مرتجع مُتراجَع عنه في نتائج البحث أصلًا (تكملة بند 15). |
| 0129 | `shipment_historical_carrier_zone_labels.sql` | أعمدة لقطة جديدة على `shipments`: `carrier_code_snapshot`/`carrier_name_snapshot`/`shipping_zone_code_snapshot`/`shipping_zone_name_snapshot` تُكتَب وقت `create_shipment()` وتُعاد من `get_shipment()`/`list_shipments()` بدل الانضمام (JOIN) الحيّ إلى `shipping_carriers`/`shipping_zones` — إعادة تسمية شركة شحن أو منطقة لاحقًا لا تُغيِّر أبدًا كيف تظهر شحنة قديمة (بند 17). |
| 0130 | `shipment_event_chronology.sql` | فرض تسلسل زمني حقيقي: أي حدث حالة أو حدث COD جديد يحمل `event_at`/`business_date` أسبق من آخر حدث مُسجَّل لنفس الشحنة يُرفَض صراحةً (بند 18) — يمنع بيانات تاريخية غير متّسقة زمنيًا حتى لو أُرسِلت عمدًا عبر تصحيح إداري. |

### 2) الجداول الجديدة (1) والمعدَّلة

**جدول جديد واحد:** `shipment_cod_events` (إضافي-فقط، بلا سياسات RLS مباشرة لـ`authenticated`، بنفس نمط `shipment_status_events`/`shipment_financial_events` حرفيًا — يُقرَأ عبر `get_shipment()` فقط، يُكتَب عبر `record_shipment_cod_collection_state()` فقط).

**تعديل عميق على جداول قائمة (بلا حذف بيانات، إضافة أعمدة فقط):** `shipments` (+12 عمود لقطة/تحصيل عبر 0125/0126/0129)، `shipping_carrier_rate_versions`/`customer_return_shipping_fee_versions` (إغلاق RLS + قيد استبعاد GIST، بلا عمود جديد).

### 3) الصفحات والمكوّنات الجديدة

`/master-data/shipping-rates` (صفحة إدارة تسعير كاملة جديدة — أربعة أقسام: شركات الشحن، المناطق، نسخ تسعير شركات الشحن حسب شركة+منطقة+اتجاه، نسخ رسوم شحن الإرجاع حسب المنطقة؛ كل قسم بعرض الحالي/القادم/السجل التاريخي مع إضافة/إلغاء نسخة، بندان 19–20). مكوّن جديد `shipment-cod-state-action.tsx` (تسجيل حالة تحصيل COD مع حوار سبب اليوم المقفل، بند 13). طبقة خلفية جديدة كاملة: `src/features/shipping-rates/{schema,queries,actions}.ts` + `components/{carrier-form-dialog,carrier-status-toggle,zone-form-dialog,zone-status-toggle,carrier-rate-version-dialog,customer-return-fee-version-dialog,cancel-rate-version-button}.tsx`. صفحات/مكوّنات Shipping القائمة (`/shipments`, `/shipments/[id]`) مُعدَّلة فقط (فلاتر جديدة، إصلاح عيب البند 11، إدراج مكوّن COD) لا مُستبدَلة.

### 4) لا صلاحيات جديدة

لم يُضَف أي مفتاح صلاحية جديد في Patch 5.1 — كل شيء يعيد استخدام `shipping_rates.view`/`shipping_rates.manage`/`shipments.view`/`shipments.create`/`shipments.manage_cost`/`shipments.correct_status`/`shipments.process_closed_day` المُعرَّفة مسبقًا في Phase 5 الأصلية، تمامًا كما نصَّت المواصفة على عدم توسيع نطاق الصلاحيات، بل تصحيح أي مكان استُخدِمت فيه الصلاحية الخطأ (بند 11).

### 5) قرارات تصميم أساسية — شرح مختصر لكل قرار

1. **إغلاق RLS المباشر ليس تكرارًا لحماية RPC، بل طبقة دفاع مستقلة:** وجود RPC صحيح لا يمنع كتابة مباشرة عبر PostgREST إن بقيت سياسة `INSERT`/`UPDATE` لـ`authenticated` مفتوحة — Patch 5.1 يحذف السياستين بدل الاكتفاء بالثقة أن كل عميل سيستخدم RPC دومًا (بند 1، اختبار تزوير PostgREST مباشر في بند 21).
2. **قيد استبعاد GIST على مستوى القاعدة، لا فحصًا تطبيقيًا فقط فوق قفل استشاري:** القفل الاستشاري يمنع سباقًا بين معاملتين متزامنتين، لكنه لا يحمي من إدراج مباشر (Bypass) خارج RPC — قيد GIST يجعل التداخل الزمني **مستحيلًا بنيويًا** بغض النظر عن مسار الكتابة (بند 2).
3. **مُشغِّل `BEFORE STATEMENT` للقفل بدل الاعتماد على كل RPC لاستدعائه يدويًا:** يضمن أن أي RPC مستقبلية تُضاف لتعديل جدولي التسعير مُغطاة تلقائيًا بالقفل حتى لو نسي المطوِّر استدعاءه صراحة — طبقة أمان بنيوية لا اتفاقية برمجية فقط (بند 4).
4. **رسوم شحن الإرجاع على العميل تشغيلية دومًا، لا حسّاسة للربح مطلقًا:** الخلط السابق في Phase 5 الأصلية بين `customer_shipping_charge` (رسم يراه أي موظف تشغيلي) و`net_shipping_expected`/`actual` (ربح داخلي حقيقي) كان عيبًا فعليًا — Patch 5.1 يفصلهما بوضوح: الأول ظاهر دومًا بلا `sales.view_profit`، والثاني يبقى محجوبًا كما كان (بند 10، وهو أيضًا تصحيح القسم 49 من اختبار Phase 5 الأصلي).
5. **`has_actual_carrier_cost` علم منطقي منفصل عن الرقم نفسه:** يسمح لفاعل تشغيلي (لا يملك رؤية ربح) بمعرفة "هل التكلفة الفعلية سُجِّلت أصلًا؟" دون كشف قيمتها — تشغيلي بحت بلا تسريب رقم مالي (بند 23).
6. **سبب تجاوز إلزامي لرسوم شحن الإرجاع فقط عند الاختلاف الفعلي عن القيمة المؤسَّسة:** لا يُطلَب سبب إن استخدم الفاعل القيمة القياسية كما هي — العبء الإداري يظهر فقط حين يحدث تجاوز حقيقي يستحق التوثيق (بند 9).
7. **قفل `FOR UPDATE` على صف المرتجع داخل `create_shipment()` بدل فحص حالة بسيط فقط:** فحص الحالة وحده عرضة لسباق حقيقي بين قراءة الحالة وكتابة الشحنة — القفل يجعل `reverse_sales_return()` و`create_shipment()` يتنافسان بأمان على نفس الصف، فتُرفَض إحداهما دومًا لا أن تنجحا معًا بحالة متضاربة (بند 16، مُثبَت بسيناريو تزامن حقيقي جديد).
8. **لقطات اسم/رمز شركة الشحن والمنطقة، لا انضمام حيّ (JOIN) عند القراءة:** بنفس فلسفة لقطة التسعير القائمة أصلًا — إعادة تسمية شركة شحن مستقبلًا يجب ألا تُغيِّر كيف تبدو شحنة تاريخية أنشئت قبل إعادة التسمية (بند 17).
9. **فرض تسلسل زمني صريح على كل حدث جديد، لا الاعتماد على انضباط المستخدم فقط:** يمنع تصحيحًا إداريًا (حتى المخوَّل بصلاحية `shipments.correct_status`) من إدخال حدث بتاريخ أسبق من آخر حدث مسجَّل فعليًا — يحافظ على معنى "السجل الزمني" كسجل حقيقي مرتب، لا مجرد قائمة صفوف (بند 18).
10. **واجهة إدارة تسعير الشحن منفصلة عن `/shipments` تمامًا:** مسؤول التسعير لا يحتاج أي صلاحية `shipments.*` للوصول إليها، وموظف الشحن الميداني لا يرى رابطها إطلاقًا إلا بصلاحية `shipping_rates.view` — نفس فصل الاهتمامات القائم أصلًا بين Master Data وعمليات الشحن (بندان 19–20).

### 6) التدقيق (Audit) — إضافات محدَّدة صراحة

فعاليات تدقيق جديدة مكتوبة صراحةً داخل الترحيلات نفسها (مُشغِّلات مخصَّصة، لا تعديل على النمط العام القائم): `shipping_rate.create`، `customer_return_shipping_fee.create`، `shipping_carrier.create`، `shipping_carrier.update`، `shipping_zone.create`، `shipping_zone.update` (0124، بند 7). لا تعديل على تصنيف `sales.view_profit` القائم من 0121 لأفعال Phase 5 الأصلية الأربعة.

### 7) حماية الربح على مستوى القاعدة — مُصحَّحة بدقة أكبر لا مُلغاة

الخط الفاصل بعد Patch 5.1: `customer_shipping_charge`/`effective_customer_shipping_charge`/`has_actual_carrier_cost`/أحداث COD **ظاهرة دومًا** لأي فاعل يملك `shipments.view` فقط (تشغيلية بحتة)، بينما `expected_carrier_cost`/`actual_carrier_cost`/`net_shipping_expected`/`net_shipping_actual`/`shipment_financial_events` تبقى **محجوبة بالكامل** بلا `sales.view_profit` تمامًا كما في Phase 5 الأصلية — الحماية لم تُخفَّف، بل صُحِّحت لتحجب الرقم الصحيح (الربح الفعلي) بدل حجب رقم تشغيلي لا علاقة له بالربح (بند 22، القسم 49 من `shipping_core_phase5.test.sql` أُعيد كتابته ليعكس هذا الخط الصحيح).

### 8) الاختبارات — قائمة كاملة وأرقام فعلية (نُفِّذت في هذه الجلسة)

تفصيل كامل بالأرقام في `TEST_RESULTS_PATCH_5_1.md`. ملخَّص:

- إعادة بناء قاعدة اختبار Postgres محلية من الصفر عدة مرات على قواعد مؤقتة منفصلة: `local_harness_setup.sql`، **كل الترحيلات 0001–0130 بالترتيب دون توقف** (130/130 نجحت)، ثم `supabase/seed.sql` (نجح).
- كل ملفات اختبار SQL القائمة (بما فيها Phase 5 الأصلية) أُعيد تشغيلها **ضمن نفس التشغيلة المتسلسلة** → **17/17 ملفًا نجحت، صفر انحدار** — شاملة قسمين أُعيد كتابتهما عمدًا ليعكسا سلوكًا أصحّ إلزامه Patch 5.1 (القسم 45: رفض التجاوز بلا سبب ثم قبوله بسبب؛ القسم 49: تصحيح خط حماية الربح).
- `supabase/tests/shipping_integrity_patch_5_1.test.sql` (جديد بالكامل، تغطية مباشرة للبنود 1–18، 21، 23) → **نجح بالكامل**، شاملًا عدة عيوب حقيقية اكتُشِفت وأُصلِحت أثناء كتابته نفسه (صلاحية `audit_logs.view` ناقصة عن ممثِّل الاختبار، اسم فعل تدقيق افتراضي خاطئ، مقارنة NULL خاطئة عبر `=` بدل `is not distinct from`، افتراض خاطئ أن الوسيط السادس لـ`create_sales_order()` هو رقم البيعة بدل اسم العميل).
- `supabase/tests/shipping_core_phase5_concurrency.test.sql` — قسم **G** جديد أُضيف لبند 16 (سباق حقيقي بين `reverse_sales_return()` و`create_shipment()` عبر `dblink`) → **نجح، A–G، 7/7 سيناريوهات** على قاعدة جديدة تمامًا. عيب حقيقي واحد اكتُشِف وأُصلِح أثناء كتابته (سياق جلسة `SET LOCAL` لا ينتقل بين كتلتَي `do $ ... $` منفصلتين في ملف بلا `BEGIN` محيط).
- ثلاث سكربتات إثبات ترقية قائمة (`run_upgrade_test.sh`، `run_upgrade_test_patch_4_2.sh`، `run_upgrade_test_hotfix_4_2_1.sh`) → **3/3 نجحت**، تثبت أن الترحيلات 0122–0130 لا تكسر أي مسار ترقية سابق.
- `npm run check:numeric-types` → **نجح، 56/56 عمود NUMERIC مطابق** (بعد إصلاح انحراف حقيقي وُجِد أثناء الفحص: 8 أعمدة لقطة جديدة في `shipments` لم تكن مُعرَّفة بعد في `database.ts`).
- `npx tsc --noEmit` → **صفر أخطاء**.
- `npx eslint .` → **صفر أخطاء وتحذيرات** (تشغيلتان: منتصف الجلسة ونهايتها بعد تعديلات اختبار التزامن).
- `npx vitest run` → **52/52 ناجح عبر 7 ملفات** (بلا تغيير).
- `npm run build` (Next.js/Turbopack) → **نجح**، بزيادة مسار إداري واحد: `/master-data/shipping-rates`.
- **فجوة معروفة مُفصَح عنها صراحةً لا مخفيّة:** لم يُشغَّل قسم HTTP/PostgREST حقيقي مخصَّص لـPatch 5.1 هذه الجلسة (خلافًا لِـPhase 5 الأصلية التي شملت 20 تأكيدًا HTTP جديدًا) — كل تحقق Patch 5.1 تم عبر اتصال SQL مباشر بدور `authenticated` مُحاكى (`SET LOCAL request.jwt.claims`)، وهو نفس آلية RLS التي يطبِّقها PostgREST فعليًا، لكنه ليس اختبار HTTP فعليًا عبر ثنائي PostgREST. مُوثَّق بالتفصيل في `TEST_RESULTS_PATCH_5_1.md` كفجوة معروفة، لا كنتيجة ناجحة.

### 9) الملفات/الترحيلات التي تغيَّرت أو أُضيفت في Patch 5.1 (قائمة كاملة)

**ترحيلات جديدة (9):** `0122_shipping_rate_versioning_lockdown.sql`، `0123_shipping_rate_table_level_lock.sql`، `0124_shipping_master_data_hardening_and_audit.sql`، `0125_customer_return_shipping_fee_snapshot.sql`، `0126_shipment_reads_visibility_and_filters.sql`، `0127_shipment_cod_collection_workflow.sql`، `0128_shipment_return_search_approved_only.sql`، `0129_shipment_historical_carrier_zone_labels.sql`، `0130_shipment_event_chronology.sql`.

**اختبار SQL جديد بالكامل:** `supabase/tests/shipping_integrity_patch_5_1.test.sql`.

**اختبارات SQL قائمة مُعدَّلة:** `supabase/tests/shipping_core_phase5.test.sql` (الأقسام 45، 49 أُعيد كتابتهما ليعكسا السلوك الصحيح المفروض بموجب Patch 5.1)، `supabase/tests/shipping_core_phase5_concurrency.test.sql` (قسم G جديد لبند 16).

**كود TypeScript جديد بالكامل:** `src/features/shipping/components/shipment-cod-state-action.tsx`، `src/features/shipping-rates/{schema,queries,actions}.ts`، `src/features/shipping-rates/components/{carrier-form-dialog,carrier-status-toggle,zone-form-dialog,zone-status-toggle,carrier-rate-version-dialog,customer-return-fee-version-dialog,cancel-rate-version-button}.tsx`، `src/app/(app)/master-data/shipping-rates/page.tsx`.

**كود TypeScript مُعدَّل:** `src/features/shipping/{schema,actions,queries}.ts` (فلاتر جديدة، `recordShipmentCodCollectionStateAction`، دوال بحث ضيقة جديدة)، `src/app/(app)/shipments/[id]/page.tsx` (إدراج مكوّن COD)، `src/app/(app)/shipments/page.tsx` (إصلاح عيب البند 11 + فلاتر جديدة)، `src/features/shipping/components/shipments-filters.tsx` (حقول فلترة جديدة)، `src/types/database.ts` (تحديث شامل لأنواع/دوال Shipping)، `src/lib/constants.ts` (`ROUTES.masterDataShippingRates`)، `src/app/(app)/master-data/page.tsx` (قسم جديد لتسعير الشحن).

**لم يتغيّر إطلاقًا:** أي ترحيل من 0001–0121، منطق أي اختبار SQL خارج ما ذُكِر أعلاه، أي صفحة/مكوّن خارج نطاق Shipping/Shipping Rates.

**خلاصة الملحق الحادي والعشرون:** تصحيح صارم لعيوب حقيقية على مستوى القاعدة اكتشفها المستخدم بمراجعة كود مصدري دقيقة — إغلاق فجوة RLS مباشرة كانت تتجاوز RPC نظريًا، قيد استبعاد GIST بنيوي بدل الاعتماد على القفل الاستشاري وحده، تغطية قفل على مستوى الجدول لكل مسار كتابة حاضر ومستقبلي، لقطة رسوم شحن إرجاع مع سبب تجاوز إلزامي، تصحيح خط حماية الربح ليحجب الربح الحقيقي فقط لا رسمًا تشغيليًا، إصلاح عيب صلاحية حقيقي في صفحة الشحنات، إغلاق سباق تزامن حقيقي بين مراجعة مرتجع وإنشاء شحنة إرجاع، لقطات تاريخية لشركة الشحن/المنطقة تصمد أمام إعادة التسمية، فرض تسلسل زمني صريح على كل حدث، وواجهة إدارة تسعير شحن كاملة. **عدة عيوب حقيقية إضافية اكتُشِفت وأُصلِحت أثناء كتابة الاختبارات نفسها هذه الجلسة** (صلاحية تدقيق ناقصة، اسم فعل تدقيق خاطئ، مقارنة NULL خاطئة، افتراض خاطئ لوسيط دالة، مشكلة سياق جلسة بين كتل اختبار منفصلة) — كلها قبل أي تسليم فعلي. **17/17 ملف اختبار SQL قائم بلا انحدار + اختبار Patch 5.1 الجديد ناجح بالكامل + A–G/7-7 سيناريوهات تزامن حقيقية + 3/3 إثباتات ترقية + صفر أخطاء TypeScript/ESLint + 52/52 اختبار Vitest + 56/56 عمود NUMERIC + بناء إنتاجي ناجح — كلها من تشغيلات فعلية في هذه الجلسة، مع فجوة واحدة مُفصَح عنها صراحة (لا اختبار HTTP/PostgREST حقيقي مخصَّص لهذا الملحق). لم تبدأ Settlements ولا Services/Adjustments ولا Inventory ولا Reports ولا أي تكامل شركة شحن — العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP كامل للمشروع بأكمله (لا ZIP فروقات) لهذا الملحق.**

## الملحق الثاني والعشرون — "Final Shipping Hotfix 5.1.1" (ترحيلات 0131–0132)

هذا الملحق يوثِّق **Hotfix 5.1.1** كاملة، ردًا مباشرًا على بلاغ المستخدم أن الـZIP المُسلَّم سابقًا باسم "Hotfix 5.1.1" كان في الواقع نسخة مطابقة بايتًا-ببايت (نفس SHA-256) للـZIP السابق `gold-erp-full-patch-5.1.zip` — 0 ملفات مُعدَّلة، ترحيلات لا تزال تتوقف عند 0130 — أي أن المواصفة المطلوبة لم تصل فعليًا في ذلك الـArtifact. طُلِب تنفيذها الآن كاملة عبر عشرة بنود: (1) سبب تجاوز رسوم شحن الإرجاع في schema/action/form، (2) إصلاح تجمُّد اقتراح الرسوم عند تغيير المنطقة/التاريخ عبر حالة "تمّ لمسه" (touched-state)، (3) توازي Preview/Create لرسوم شحن الإرجاع، (4) إصلاح صلاحية `correct_status`-فقط في Server Action، (5) RPCs نصية آمنة لقراءة `base_cost`/`fee_amount` بدل NUMERIC خام، (6) تسلسل زمني بالنسبة لآخر حدث حالة/COD مسجَّل فعليًا لا `shipment_date` فقط، (7) اختبارات انحدار فعلية للتسلسل الزمني، (8) استكمال أعمدة `/shipments` التشغيلية (رقم مرتجع/منطقة/تتبع/رسوم شحن على العميل)، (9) تغطية HTTP/PostgREST حقيقية لـPatch 5.1/Hotfix 5.1.1، (10) اختبارات React/Vitest. القيود الصارمة كالمعتاد وبقيت سارية طوال هذا الملحق: **"لا تعدل أي migration من 0001 إلى 0130"** — كل ترحيلة جديدة بدأت من 0131 فصاعدًا (ترحيلتان: 0131–0132)؛ **"لا تبدأ Settlements"**، **"لا تبدأ أي مرحلة أخرى"**؛ **"تحقق بنفسك أن SHA-256 للـZIP الجديدة مختلف عن Artifact السابق وأن الملفات المطلوبة موجودة فعلًا"** قبل الإرسال. العمل **متوقف الآن نهائيًا**: **"توقف بعد التسليم وانتظر المراجعة."**

### 1) الترحيلات الجديدة (0131–0132)

| # | الترحيلة | تُضيف |
|---|---|---|
| 0131 | `shipment_latest_event_chronology.sql` | `add_shipment_status_event()`/`record_shipment_cod_collection_state()` (توقيعان بلا تغيير من 0118/0127/0130) يتحققان الآن أيضًا من آخر حدث موجود فعليًا في سلسلة الأحداث الخاصة بهما (`shipment_status_events`/`shipment_cod_events`)، لا فقط من `shipment_date` كما كانت 0130 تفعل — فجوة حقيقية كانت تسمح بإدخال حدثين لنفس الشحنة بترتيب زمني معكوس طالما كلاهما بعد `shipment_date` (بند 6). المقارنة صارمة (`<`) فتبقى أحداث اليوم نفسه مقبولة، بنفس تسامح `correct_shipment_actual_cost()` القائم أصلًا. |
| 0132 | `shipping_rate_versions_safe_reads.sql` | دالتان جديدتان `SECURITY DEFINER`: `list_shipping_carrier_rate_versions_safe()`/`list_customer_return_shipping_fee_versions_safe()` — تُعيدان `base_cost`/`fee_amount` بصيغة `::text` بدل NUMERIC خام، بنفس نمط `_safe` القائم من 0052، مقيَّدتان بصلاحية `shipping_rates.view` (نفس صلاحية سياسة RLS القائمة على الجدولين — لا توسيع نطاق) (بند 5). واجهة إدارة تسعير الشحن (`src/features/shipping-rates/queries.ts`) تستدعيهما الآن بدل قراءة الجدولين مباشرة عبر `.select("*")`. |

### 2) لا جداول جديدة ولا أعمدة جديدة

Hotfix 5.1.1 لا يضيف أي جدول أو عمود جديد — كلتا الترحيلتين `create or replace function` بتوقيع غير مُغيَّر (0131) أو دالتان جديدتان بالكامل بلا `ALTER TABLE` (0132). يؤكد ذلك `npm run check:numeric-types`: **56/56 عمود NUMERIC** — نفس الرقم كـPatch 5.1 بالضبط.

### 3) البنود 1–4/8/10 — إصلاحات على الطبقة الأمامية/Server Action فقط (بلا ترحيلة SQL)

بند 1 كان اكتشافًا مهمًا أثناء التنفيذ: منطق فرض سبب التجاوز الإلزامي على مستوى `create_shipment()` نفسها كان **موجودًا وصحيحًا فعليًا منذ 0125/0129** (Patch 5.1) — الفجوة الحقيقية لبند 1 لم تكن في القاعدة، بل أن `src/features/shipping/schema.ts` لم يكن يحمل حقل `customer_return_shipping_charge_override_reason` أصلاً، و`createShipmentAction()` (`actions.ts`) لم يكن يُمرِّره إلى الـRPC حتى لو كتبه المستخدم في مكان آخر. أُصلِح بإضافة الحقل إلى `createShipmentSchema` وتمريره في نداء RPC.

بند 2 (الانحدار الفعلي): تأثير `useEffect` القديم في `shipment-entry-form.tsx` كان يستخدم `prev ? prev : fee_amount` — يملأ `customer_shipping_charge` **مرة واحدة فقط**؛ أول قيمة غير فارغة تُجمِّد الحقل للأبد، فتبديل المنطقة من رسوم 35.00 إلى رسوم 50.00 كان يُبقي الحقل معروضًا 35.00 صامتًا (بيانات قديمة/خاطئة). أُصلِح بحالة `touched-state` صريحة (`customerShippingChargeTouched`): الحقل يُعاد مزامنته مع كل اقتراح جديد حتى يُعدِّله الفاعل فعليًا بنفسه — عندئذٍ فقط يتوقف التزامن التلقائي ويُحترَم تعديله المتعمَّد.

بند 3 (توازي Preview/Create): كان قائمًا فعليًا على مستوى القاعدة (كل من `preview_customer_return_shipping_fee()` و`create_shipment()` يستدعيان نفس الدالة المشتركة `customer_return_shipping_fee_for()`) — الإصلاح هنا على مستوى الواجهة الأمامية فقط: مقارنة "هل هذا تجاوز؟" تستخدم دومًا **أحدث** اقتراح مجلوب فعليًا (`feeSuggested`)، لا القيمة اللحظية عند أول تحميل، وهي مقارنة رقمية آمنة (عبر `toDecimal`) لا مقارنة نصية حرفية — فـ`"35"` و`"35.00"` لا تُعتبَران تجاوزًا.

بند 4: `addShipmentStatusEventAction()` (`src/features/shipping/actions.ts`) كان يستدعي `requirePermission("shipments.update_status")` فقط — فاعل يملك `shipments.correct_status` حصرًا (بلا `shipments.update_status`) كان يُرفَض عند Server Action رغم أن الدالة نفسها في القاعدة (`add_shipment_status_event()`) تتحقق بشكل صحيح من الصلاحية المناسبة حسب نوع الانتقال (طبيعي أم تصحيح). أُصلِح باستبدال الفحص بـ`requireAnyPermission(["shipments.update_status", "shipments.correct_status"])` — القاعدة تبقى المرجع النهائي للفصل الدقيق بين الحالتين، والServer Action لم يعد يرفض حالة كانت ستُقبَل أصلاً لو وصلت إلى القاعدة.

بند 8: أربعة أعمدة تشغيلية جديدة على جدول `/shipments` (`src/app/(app)/shipments/page.tsx`): رقم المرتجع، المنطقة، رقم التتبع (الثلاثة `hidden md:table-cell`)، ورسوم الشحن على العميل (`hidden lg:table-cell`، ظاهر دومًا بغض النظر عن `sales.view_profit` — تشغيلي بحت، بند 10 من Patch 5.1) — كل الحقول موجودة فعلاً في نتيجة `list_shipments()` القائمة، لا حاجة لأي تعديل SQL.

### 4) البند 9 — تغطية HTTP/PostgREST حقيقية (يسدّ فجوة مُفصَح عنها في Patch 5.1)

`scripts/postgrest-http-test.mjs` امتد بقسم **Part 9** جديد فوق نفس الثنائي الحقيقي (PostgREST v12.2.3)، يثبت عبر شبكة حقيقية بنود 1/5/6 (تفصيل كامل في `TEST_RESULTS_HOTFIX_5_1_1.md` القسم 4). التحدي التقني الرئيسي: كل تركيبات Part 8 القائمة مؤرَّخة "اليوم"، ما يُقيِّد `create_shipment()` على `shipment_date` واحد فقط — فلا مجال لتباعد تاريخي حقيقي بين حدثين لإثبات بند 6. حُلَّ بإضافة قسم تركيب اختباري جديد (test-only، غير ترحيلي) في `supabase/tests/postgrest_http_test_setup.sql` يوسِّع مدى صلاحية سعر ذهب/إصدار ضريبة قيمة مضافة تاريخيين بحتًا إلى الوراء فقط (لا يمسّ حل "اليوم")، يسمح بإنشاء بيعة/شحنة مؤرَّخة قبل 5 أيام فعليًا — تمامًا نفس التقنية المُبرَّرة أصلًا في `shipping_integrity_hotfix_5_1_1.test.sql` لنفس الفجوة الجذرية.

**عيب حقيقي اكتُشِف وأُصلِح أثناء تشغيل هذا القسم بالذات:** تأكيد قائم في Part 8 (حماية الربح على `get_shipment()`) كان لا يزال يفترض تعاقدًا سابقًا لـPatch 5.1 — أن `customer_shipping_charge` يجب أن يكون غائبًا كليًا عن فاعل بلا `sales.view_profit`. لكن Patch 5.1 (0126/0129) صمَّم هذا عمدًا بعكس ذلك تمامًا وموثَّقًا داخل `get_shipment()` نفسها (انظر الملحق 21، القسم 7 أعلاه): رسم تشغيلي يواجه العميل يبقى ظاهرًا دومًا. لم تُعَد حزمة HTTP هذه فعليًا منذ هبوط Patch 5.1، فبقي هذا الانحراف بين الاختبار والتصميم الفعلي غير مُكتشَف حتى الآن. أُصلِح التأكيد ليطابق التعاقد الموثَّق فعليًا (وقُوِّي ليتحقق أيضًا من غياب `carrier_rate_version_id`/`actual_carrier_cost`/`net_shipping_actual`/`cod_expected_amount` صراحةً). **هذا ليس عيبًا في أي ترحيلة — الدالة كانت صحيحة دومًا؛ العيب كان في تأكيد اختبار HTTP نفسه.**

### 5) لا صلاحيات جديدة، لا صفحات جديدة

لم يُضَف أي مفتاح صلاحية جديد، ولا صفحة جديدة — Hotfix 5.1.1 يعيد استخدام كل صلاحيات/صفحات Phase 5/Patch 5.1 القائمة حرفيًا. عدد مسارات `npm run build` مطابق تمامًا لِـPatch 5.1.

### 6) قرارات تصميم أساسية — شرح مختصر لكل قرار

1. **`touched-state` صريح بدل `prev ? prev : x`:** التمييز بين "قيمة مُزامَنة تلقائيًا" و"قيمة عدَّلها الفاعل فعليًا" هو الفرق الجوهري بين نموذج يحترم تعديل المستخدم ونموذج يتجاهله بصمت — الحل السابق كان يخلط الحالتين (بند 2).
2. **مقارنة التجاوز رقمية دومًا (`toDecimal`)، لا نصية حرفية:** فرض سبب تجاوز على فارق تنسيق ("35" مقابل "35.00") لا فارق قيمة حقيقي كان سيُربِك الفاعل بلا داعٍ — نفس منطق التسامح الرقمي المُطبَّق في كل حساب مالي بالمشروع (بند 3).
3. **`requireAnyPermission` بدل `requirePermission` عند تعدد الصلاحيات المقبولة على مستوى القاعدة:** الServer Action يجب أن يعكس فقط ما تفرضه القاعدة فعليًا، لا فرضًا إضافيًا أضيق منها — القاعدة (لا الServer Action) هي المرجع الوحيد للتمييز الدقيق بين انتقال طبيعي وتصحيح (بند 4).
4. **`RPCs نصية آمنة` حتى حين لا يوجد خطر دقة حالي:** واجهة إدارة تسعير الشحن تعرض القيم فقط اليوم (لا تُعيد تغذيتها في حساب)، لكن الاعتماد على "عرض فقط، الآن" ليبقى صحيحًا للأبد افتراض هش — النمط الآمن (`_safe`) يُطبَّق باتساق على كل قراءة مالية عبر RPC بصرف النظر عن الاستخدام الحالي (بند 5، نفس فلسفة Financial Integrity Patch 2.2 الأصلية).
5. **تسلسل زمني بالنسبة لآخر حدث فعلي في السلسلة، لا `shipment_date` الثابت فقط:** `shipment_date` حدّ أدنى واحد لا يتغيّر، لكنه لا يمنع حدثين لاحقين من الانعكاس فيما بينهما — المقارنة الصحيحة تكون دومًا مقابل آخر حدث **فعليًا موجود**، تمامًا كما تفعل `correct_shipment_actual_cost()` مسبقًا لسلسلة التكلفة الفعلية (بند 6، نفس المبدأ مُعمَّم على سلسلتين كانتا ناقصتين).

### 7) الاختبارات — قائمة كاملة وأرقام فعلية (نُفِّذت في هذه الجلسة)

تفصيل كامل بالأرقام في `TEST_RESULTS_HOTFIX_5_1_1.md`. ملخَّص:

- إعادة بناء قاعدة اختبار Postgres محلية من الصفر على قواعد مؤقتة منفصلة: `local_harness_setup.sql`، **كل الترحيلات 0001–0132 بالترتيب دون توقف** (132/132 نجحت)، ثم `supabase/seed.sql` (نجح).
- كل ملفات اختبار SQL القائمة (بما فيها Patch 5.1) أُعيد تشغيلها **ضمن نفس التشغيلة المتسلسلة** + `shipping_integrity_hotfix_5_1_1.test.sql` الجديد (تغطية مباشرة للبنود 5/6/7) → **15/15 ملفًا نجحت، صفر انحدار**.
- `shipping_core_phase5_concurrency.test.sql` (بلا تعديل منطقي) أُعيد تشغيله فوق 0001–0132 → **A–G، 7/7 سيناريوهات تزامن حقيقية**، لا تغيير سلوكي (0131/0132 تلمسان فقط الفحص الزمني الإضافي، لا منطق القفل/التزامن نفسه).
- ثلاث سكربتات إثبات ترقية قائمة → **3/3 نجحت**، تثبت أن 0131/0132 لا تكسران أي مسار ترقية سابق.
- `scripts/postgrest-http-test.mjs` (Part 9 جديد يغطي بنود 1/5/6 + تصحيح انحراف حقيقي في تأكيد Part 8 القائم، انظر القسم 4 أعلاه) → **نجح بالكامل، صفر فشل**، يسدّ الفجوة المُفصَح عنها صراحةً في `TEST_RESULTS_PATCH_5_1.md`.
- `npm run check:numeric-types` → **نجح، 56/56 عمود NUMERIC** — بلا تغيير عن Patch 5.1.
- `npx tsc --noEmit` → **صفر أخطاء**. `npx eslint .` → **صفر أخطاء وتحذيرات**.
- `npx vitest run` → **62/62 ناجح عبر 8 ملفات** (+10 اختبارات جديدة عن Patch 5.1: 5 في `tests/shipment-entry-form-return-fee.test.tsx` الجديد، 5 في `tests/validation.test.ts` لِـ`createShipmentSchema`).
- `npm run build` (Next.js/Turbopack) → **نجح**، نفس عدد المسارات كـPatch 5.1.

### 8) الملفات/الترحيلات التي تغيَّرت أو أُضيفت في Hotfix 5.1.1 (قائمة كاملة)

**ترحيلات جديدة (2):** `0131_shipment_latest_event_chronology.sql`، `0132_shipping_rate_versions_safe_reads.sql`.

**اختبار SQL جديد بالكامل:** `supabase/tests/shipping_integrity_hotfix_5_1_1.test.sql`.

**اختبارات Vitest جديدة بالكامل:** `tests/shipment-entry-form-return-fee.test.tsx` (5 اختبارات).

**اختبارات Vitest قائمة مُعدَّلة:** `tests/validation.test.ts` (+5 اختبارات لِـ`createShipmentSchema`).

**تركيب اختبار HTTP قائم مُعدَّل (test-only، غير ترحيلي):** `supabase/tests/postgrest_http_test_setup.sql` (سعر ذهب/إصدار VAT تاريخيان لدعم بند 6/9)، `scripts/postgrest-http-test.mjs` (Part 9 جديد + تصحيح تأكيد Part 8 المنحرف).

**كود TypeScript مُعدَّل:** `src/features/shipping/schema.ts` (حقل `customer_return_shipping_charge_override_reason` جديد، بند 1)، `src/features/shipping/actions.ts` (`requireAnyPermission` لبند 4، تمرير سبب التجاوز لبند 1)، `src/features/shipping/components/shipment-entry-form.tsx` (`touched-state` لبند 2، مقارنة تجاوز رقمية لبند 3، حقل سبب تجاوز جديد)، `src/app/(app)/shipments/page.tsx` (4 أعمدة تشغيلية جديدة لبند 8)، `src/types/database.ts` (الدالتان الآمنتان الجديدتان لبند 5)، `src/features/shipping-rates/queries.ts` (استدعاء الدالتين الآمنتين بدل قراءة الجدولين مباشرة، بند 5).

**لم يتغيّر إطلاقًا:** أي ترحيل من 0001–0130، أي صلاحية، أي صفحة جديدة، منطق أي اختبار SQL/Vitest خارج ما ذُكِر أعلاه.

**خلاصة الملحق الثاني والعشرون:** إصلاح نهائي مُركَّز حول عشرة بنود صريحة عقب بلاغ المستخدم بأن التسليم السابق لم يصل فعليًا (تطابق SHA-256 كامل مع الـArtifact الأسبق). أهمّ اكتشاف تقني: بند 1 (سبب تجاوز رسوم شحن الإرجاع) كان **منفَّذًا وصحيحًا فعليًا على مستوى القاعدة منذ Patch 5.1** — الفجوة الحقيقية كانت حصرًا في الطبقة الأمامية (schema/action/form)، لا في SQL؛ إصلاح مُقابل ثانٍ اكتُشِف أثناء اختبار HTTP نفسه (لا في أي ترحيلة): تأكيد اختبار مُنحرِف عن تصميم Patch 5.1 الموثَّق لحظة تشغيل الاختبار الحقيقي فعليًا لأول مرة منذ Patch 5.1. **132/132 ترحيلة من الصفر + 3/3 إثباتات ترقية + 15/15 ملف اختبار SQL + A–G/7-7 سيناريوهات تزامن حقيقية + اختبار HTTP/PostgREST حقيقي كامل ناجح (يسدّ فجوة Patch 5.1 المُفصَح عنها) + صفر أخطاء TypeScript/ESLint + 62/62 اختبار Vitest + 56/56 عمود NUMERIC + بناء إنتاجي ناجح — كلها من تشغيلات فعلية في هذه الجلسة، بلا فجوة معروفة متبقية. لم تبدأ Settlements ولا أي مرحلة أخرى — العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP كامل للمشروع بأكمله (لا ZIP فروقات) لهذا الملحق.**

---

## الملحق الثالث والعشرون — "Final Shipping UI & Verification Hotfix 5.1.2" (بلا ترحيلات جديدة)

هذا الملحق يوثِّق **Hotfix 5.1.2** كاملة، بنفس مواصفة Hotfix 5.1.2 التي أرسلها المستخدم سابقًا، بلا توسيع نطاق. طُلِب تنفيذها عبر سبعة بنود: (1) إصلاح انتقال Return Shipping Fee من منطقة فيها تسعير معتمَد إلى منطقة بلا أي تسعير — مسح القيمة القديمة إذا لم يُلمَس الحقل، والاحتفاظ بها إذا لُمِس، مع إلزام رسوم يدوية + سبب لحالة "بلا تسعير"، (2) منع إرسال بمعاينة قديمة (stale-preview) أثناء تحميل اقتراح منطقة/تاريخ جديد — تمييز `loading` عن `not_found` صراحة، (3) الحفاظ على مصفوفة touched-state الكاملة عبر خمس حالات فرعية، (4) خمسة اختبارات React/Vitest للحالات الناقصة، (5) استكمال تغطية HTTP/PostgREST حقيقية لتسعة بنود A–I كانت مثبَّتة سابقًا فقط على مستوى SQL، (6) عدم تعديل الترحيلات 0001–0132 وعدم إنشاء ترحيلة جديدة إلا عند حاجة SQL فعلية، (7) عدم بدء Settlements أو أي مرحلة أخرى. القيود الصارمة كالمعتاد وبقيت سارية طوال هذا الملحق، والعمل **متوقف الآن نهائيًا**: **"توقف بعد التسليم وانتظر المراجعة."**

### 1) لا ترحيلات جديدة — البند 6 محقَّق حرفيًا

خلافًا لكل الملاحق السابقة، **Hotfix 5.1.2 لا يضيف أي ترحيلة SQL جديدة**. الترحيلات تتوقف عند 0132 تمامًا كما كانت — **132/132 ترحيلة من الصفر نجحت، صفر تعديل على 0001–0132**. لم تظهر أي حاجة SQL فعلية أثناء التنفيذ: كل بنود 1–4 كانت منطق واجهة أمامية (touched-state/loading-state) بحتًا، وبند 5 كان استكمال تغطية اختبارية فقط لمنطق RPC كان صحيحًا وموجودًا بالفعل منذ Patch 5.1/Hotfix 5.1.1 — لا فجوة سلوكية على مستوى القاعدة تستدعي ترحيلة 0133. هذا مطابق تمامًا لتحذير المستخدم الصريح: "لا تنشئ migration جديدة إذا لم تحتج SQL".

### 2) لا جداول جديدة ولا أعمدة جديدة

بلا حاجة للتأكيد المعتاد عبر `check:numeric-types` لوجود تغيير — لكنه أُعيد تشغيله للتحقق فعليًا: **56/56 عمود NUMERIC**، نفس الرقم بالضبط منذ Hotfix 5.1.1.

### 3) البنود 1–3 — منطق touched-state/loading-state في `shipment-entry-form.tsx`

المشكلة الجذرية التي غطاها البند 1: الـeffect القائم من Hotfix 5.1.1 كان يزامن `customer_shipping_charge` مع الاقتراح الجديد فقط عندما `found=true` (حالة `not_found` كانت تُترَك دون أي فعل صريح على الحقل) — لهذا عند الانتقال من منطقة *فيها* تسعير معتمَد إلى منطقة *بلا* تسعير، كانت القيمة القديمة (مثلاً 35.00) تبقى معروضة في الحقل بصمت رغم أنها لم تعد رسمًا معتمَدًا لهذه المنطقة الجديدة، دون تمييز واضح بين كونها الآن رسمًا يدويًا يتطلب سببًا أم مجرد بقايا قديمة. أُصلِح الـeffect ليتعامل صراحة مع كل الحالات: عند `found=false` (لا تسعير) **و**`untouched`، يُمسَح `customer_shipping_charge` فورًا (حتى لا يبقى رقم قديم مُعتمَد بصمت)؛ عند `found=false` **و**`touched`، يبقى الحقل كما أدخله الفاعل يدويًا دون أي مساس، ويُفعَّل شرط الإلزام بسبب (نفس شرط `customer_return_shipping_charge_is_override` القائم من Hotfix 5.1.1 — بند 1 هناك، لا حاجة لتوسيعه).

البند 2 (منع stale-preview submit): أُضيفت حالة صريحة ثلاثية `feePreviewStatus: "idle" | "loading" | "found" | "not_found"` بدل الاعتماد الضمني على `feeSuggested === null` كوكيل لحالتين مختلفتين فعليًا (لا يزال يُحمَّل / انتهى التحميل بلا نتيجة) — التمييز الجوهري الذي كان ناقصًا: `null` لا يمكنه تمثيل "لا يزال قيد التحميل". الـeffect الجديد يضبط `"loading"` فور بدء نداء RPC معاينة الرسوم، ويُدرَج `!returnFeePreviewLoading` كشرط إضافي في `canSubmit` — الإرسال محظور فعليًا طوال نافذة التحميل، لا فقط بعد ظهور نتيجة قديمة قد لا تعود صالحة لمنطقة/تاريخ جديدين. واجهة المستخدم تعرض رسالة "جارٍ التحقق..." مميَّزة بصريًا عن رسالة الاقتراح العادية، وتلميحًا فوق زر الإرسال أثناء الانتظار.

البند 3 (مصفوفة touched-state الكاملة، خمس حالات فرعية) — كلها مؤكَّدة صحيحة بالفعل عبر الإصلاح أعلاه ومُثبَّتة باختبارات البند 4:

| # | الانتقال | حالة الحقل | السلوك المطلوب | مُحقَّق |
|---|---|---|---|---|
| 1 | مُهيَّأ ← مُهيَّأ (منطقتان لهما تسعير) | untouched | يتحدَّث تلقائيًا مع الاقتراح الجديد | ✅ (سلوك Hotfix 5.1.1 القائم، لم يتغيَّر) |
| 2 | أي انتقال | touched (تجاوز يدوي) | لا يُمسَح أبدًا | ✅ |
| 3 | مُهيَّأ ← بلا تسعير | untouched | يُمسَح فورًا | ✅ (الإصلاح الجديد هنا) |
| 4 | مُهيَّأ ← بلا تسعير | touched | يُحتفَظ بالقيمة ويُطلَب سبب | ✅ (الإصلاح الجديد هنا) |
| 5 | أي مقارنة | — | `"35"` و`"35.00"` ليست تجاوزًا (مقارنة `toDecimal`) | ✅ (سلوك Hotfix 5.1.1 القائم، لم يتغيَّر — بند 3 هناك) |

### 4) البند 5 — استكمال تغطية HTTP/PostgREST حقيقية (A–I)

`scripts/postgrest-http-test.mjs` امتد بقسم **Part 10** جديد فوق نفس الثنائي الحقيقي (PostgREST v12.2.3) — تفصيل تقني كامل لكل بند من A إلى I في `TEST_RESULTS_HOTFIX_5_1_2.md` القسم 4. هذه التسعة بنود كلها كانت تثبت سلوكًا **موجودًا وصحيحًا بالفعل** على مستوى RPC/RLS منذ Patch 5.1/Hotfix 5.1.1 — الفجوة الحقيقية الوحيدة كانت غياب تغطية اختبارية عبر شبكة HTTP حقيقية لها تحديدًا.

**3 عيوب حقيقية اكتُشِفت وأُصلِحت أثناء أول تشغيل فعلي لـPart 10 في هذه الجلسة، كلها في كود الاختبار نفسه — لا عيب واحد في أي RPC أو ترحيلة:**

1. بندا A: استخدام `try/catch` حول `client.from(...).insert(...)` لا يكفي لاكتشاف رفض RLS لأن `@supabase/postgrest-js` لا يرمي استثناءً افتراضيًا عند خطأ من مستوى PostgREST — أُصلِح بتفكيك `{ error }` من نتيجة `insert()` مباشرة.
2. بند D: نمط الرسالة المتوقَّعة في التأكيد (`/يجب إدخال سبب/`) لم يطابق الرسالة الفعلية الصحيحة لفرع "لا يوجد إعداد معتمد إطلاقًا" في migration 0125/0129 (`'لا يوجد إعداد معتمد لرسوم شحن الإرجاع...'`) — السلوك كان صحيحًا؛ أُصلِح نمط التأكيد فقط.
3. بند F: نفس عيب `try/catch` من بند A — أُصلِح بنفس الطريقة.

بعد الإصلاحات الثلاثة: `=== ALL REAL HTTP/POSTGREST INTEGRATION TEST ASSERTIONS PASSED ===`، صفر فشل، بلا انحدار على الأجزاء 1–9 القائمة.

### 5) لا صلاحيات جديدة، لا صفحات جديدة

لم يُضَف أي مفتاح صلاحية جديد، ولا صفحة جديدة. عدد مسارات `npm run build`: **28 مسارًا**، مطابق تمامًا لِـHotfix 5.1.1.

### 6) قرارات تصميم أساسية — شرح مختصر لكل قرار

1. **حالة تحميل ثلاثية صريحة (`idle`/`loading`/`found`/`not_found`) بدل وكيل ضمني (`null`):** `null` لا يمكنه تمثيل حالتين مختلفتين فعليًا (لا يزال قيد التحميل / انتهى بلا نتيجة) — أي محاولة لاستنتاج "هل لا يزال التحميل جاريًا؟" من قيمة واحدة بوكيل ضمني تُنتِج نافذة تسابق حقيقية حيث يمكن إرسال النموذج بمعاينة لم تعد صالحة أصلاً (بند 2).
2. **مسح صريح للحقل فقط عند `untouched`، لا في كل حالة `not_found`:** التمييز بين "لم يلمس الفاعل الحقل بعد" و"عدَّله يدويًا" هو ما يحدِّد ما إذا كانت القيمة القديمة بيانات تعبئة تلقائية بالية (يجب مسحها) أم قرارًا متعمَّدًا من الفاعل (يجب احترامه) — نفس فلسفة `touched-state` المُقدَّمة أصلًا في Hotfix 5.1.1 (بند 2 هناك)، مُطبَّقة الآن أيضًا على فرع "بلا تسعير" الذي لم يكن مغطى صراحة (بند 1/3).
3. **استكمال تغطية اختبارية بدل افتراض أن السلوك القائم صحيح:** تسعة بنود A–I من مواصفة هذا الـHotfix كلها كانت تثبت سلوكًا موجودًا بالفعل — لكن "الكود صحيح" و"الكود مُثبَت باختبار حقيقي عبر HTTP" ادعاءان مختلفان؛ الفجوة بينهما هي بالضبط ما اكتشف العيوب الثلاثة في القسم 4 (كلها في كود الاختبار، لا في RPC — إثبات أن حتى منطق قاعدة بيانات "صحيح مسبقًا" يستحق تشغيل تأكيد حقيقي فعلي قبل الاعتماد عليه كمُثبَت).

### 7) الاختبارات — قائمة كاملة وأرقام فعلية (نُفِّذت في هذه الجلسة)

تفصيل كامل بالأرقام في `TEST_RESULTS_HOTFIX_5_1_2.md`. ملخَّص:

- إعادة بناء قاعدة اختبار Postgres محلية من الصفر (`gold_erp_fresh_verify`): `local_harness_setup.sql`، **كل الترحيلات 0001–0132 بالترتيب دون توقف** (132/132 نجحت، صفر ترحيلة جديدة)، ثم `supabase/seed.sql` (نجح).
- كل ملفات اختبار SQL القائمة (15 ملفًا، بلا ملف جديد لهذا الـHotfix) أُعيد تشغيلها ضمن نفس التشغيلة المتسلسلة → **15/15 نجحت، صفر انحدار**.
- ثلاثة ملفات تزامن حقيقي (dblink) قائمة أُعيد تشغيلها فوق 0001–0132 → **كل السيناريوهات ناجحة** (H1/H2/I/J/J2/K/L1/L2، R1–R7، A–G).
- ثلاث سكربتات إثبات ترقية قائمة → **3/3 نجحت**.
- `scripts/postgrest-http-test.mjs` (Part 10 جديد يغطي بنود A–I + تصحيح 3 عيوب في كود الاختبار نفسه، انظر القسم 4 أعلاه) → **نجح بالكامل، صفر فشل**.
- `npm run check:numeric-types` → **نجح، 56/56 عمود NUMERIC** — بلا تغيير.
- `npx tsc --noEmit` → **صفر أخطاء**. `npx eslint .` → **صفر أخطاء وتحذيرات**.
- `npx vitest run` → **73/73 ناجح عبر 10 ملفات** (+11 اختبارًا جديدًا عن Hotfix 5.1.1: 3 في `tests/shipment-entry-form-return-fee.test.tsx` القائم، 3 في `tests/shipping-actions-permission-boundary.test.ts` الجديد، 5 في `tests/shipment-view-only-ui.test.tsx` الجديد).
- `npm run build` (Next.js/Turbopack) → **نجح**، 28 مسارًا، نفس عدد Hotfix 5.1.1.

### 8) الملفات التي تغيَّرت أو أُضيفت في Hotfix 5.1.2 (قائمة كاملة)

**ترحيلات جديدة:** لا شيء — 0 ترحيلة جديدة (البند 6 محقَّق حرفيًا، القسم 1 أعلاه).

**كود TypeScript/React مُعدَّل:** `src/features/shipping/components/shipment-entry-form.tsx` (حالة `feePreviewStatus` ثلاثية جديدة لبند 2، إعادة كتابة effect معاينة رسوم الإرجاع لبنود 1/3، شرط `returnFeePreviewLoading` في `canSubmit`، تلميحات واجهة جديدة).

**اختبارات Vitest قائمة مُعدَّلة:** `tests/shipment-entry-form-return-fee.test.tsx` (+3 اختبارات: configured→no-config untouched/touched، preview loading).

**اختبارات Vitest جديدة بالكامل:** `tests/shipping-actions-permission-boundary.test.ts` (أول اختبار وحدة مباشر لـServer Action في هذا المشروع، 3 اختبارات — حدود صلاحية `correct_status`-فقط)، `tests/shipment-view-only-ui.test.tsx` (5 اختبارات — انحدار واجهة `shipments.view-only`).

**تركيب اختبار HTTP قائم مُعدَّل (test-only، غير ترحيلي):** `scripts/postgrest-http-test.mjs` (Part 10 جديد يغطي بنود A–I + تصحيح 3 عيوب في كود الاختبار نفسه، القسم 4 أعلاه). لا تعديل على `supabase/tests/postgrest_http_test_setup.sql` — التركيب القائم كان كافيًا.

**لم يتغيّر إطلاقًا:** أي ترحيل من 0001–0132، أي صلاحية، أي صفحة جديدة، أي جدول/عمود، منطق أي اختبار SQL/تزامن/ترقية خارج إعادة التشغيل للتحقق من عدم الانحدار.

**خلاصة الملحق الثالث والعشرون:** إصلاح نهائي مُركَّز حول سبعة بنود صريحة، بلا أي حاجة SQL فعلية — كل الإصلاحات منطق واجهة أمامية (touched-state/loading-state) بالإضافة إلى استكمال تغطية اختبارية HTTP كانت ناقصة لسلوك RPC كان صحيحًا بالفعل. **132/132 ترحيلة من الصفر (صفر جديدة) + 3/3 إثباتات ترقية + 15/15 ملف اختبار SQL + كل سيناريوهات التزامن الحقيقية بلا انحدار + اختبار HTTP/PostgREST حقيقي كامل ناجح (Part 10 الجديد يغطي بنود A–I التسعة، بعد تصحيح 3 عيوب في كود الاختبار نفسه) + صفر أخطاء TypeScript/ESLint + 73/73 اختبار Vitest عبر 10 ملفات (11 اختبارًا جديدًا) + 56/56 عمود NUMERIC + بناء إنتاجي ناجح، 28 مسارًا — كلها من تشغيلات فعلية في هذه الجلسة، بلا فجوة معروفة متبقية. لم تبدأ Settlements ولا أي مرحلة أخرى — العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP كامل للمشروع بأكمله (لا ZIP فروقات) لهذا الملحق.**

---

## الملحق الرابع والعشرون — "Final Shipping Verification Hotfix 5.1.3" (بلا ترحيلات جديدة)

هذا الملحق يوثِّق **Hotfix 5.1.3** كاملة — ردًا على مراجعة كود مصدري فعلية أجراها المستخدم لملفات ZIP الـHotfix 5.1.2 (وليس تقرير الاختبارات فقط)، مؤكِّدًا صحة الـArtifact (SHA-256 `3aec32119daced2e41abd3c43741e8d6e124520ec9159f0cfcc4051235bcca86`، 3 ملفات جديدة، 4 معدَّلة، صفر محذوفة، صفر ترحيلة معدَّلة — كل ذلك مطابق لما أرسِل فعليًا) واكتشاف Blocker حقيقي واحد + عشر فجوات تحقق محددة عبر 13 بندًا. القيود الصارمة كالمعتاد: **"لا تعدل migrations 0001–0132"**، **"لا تنشئ migration جديدة؛ هذه الجولة يجب أن تكون UI/Test فقط ما لم يظهر سبب SQL حقيقي جديد"** (لم يظهر — صفر ترحيلة جديدة)، **"لا تبدأ Settlements"**. العمل **متوقف الآن نهائيًا**: **"توقف وانتظر المراجعة."**

### 1) البند 1/2/3 — Blocker: خلط "خطأ المعاينة" مع "لا يوجد تسعير معتمد"

المشكلة التي حددها المستخدم بدقة عبر قراءة الكود المصدري مباشرة: `shipment-entry-form.tsx` كان يزُجّ بحالتين مختلفتين جوهريًا في نفس فرع `not_found` — (أ) الـRPC نجحت وأجابت `found=false` (لا تسعير حقيقي)، و(ب) استدعاء Server Action فشل (`success:false` أو استثناء مرمي). الحالة (ب) كانت تُعرَض للمستخدم كأنها "لا يوجد تسعير معتمد"، تسمح بإدخال رسوم يدوية + سبب، والمتابعة للحفظ — يخالف المطلوب الأصلي: **خطأ معاينة يجب أن يمنع Submit تمامًا، لا يُفسَّر كـno_config**.

أُصلِح بتوسيع `feePreviewStatus` إلى خمس حالات (`idle`/`loading`/`found`/`not_found`/`error`) مع `feePreviewErrorMessage` مرافقة، وقاعدة تفريق دقيقة: `success:true && found:true` → `found`؛ `success:true && found:false` → `not_found` (الحالة الوحيدة المسموح تفسيرها كـ"لا تسعير")؛ `success:false` أو استثناء مرمي (داخل `try/catch`، بلا `unhandled rejection`) → `error` حصرًا. عند `error`: رسالة "لا يوجد تسعير معتمد" لا تظهر إطلاقًا (`returnFeeIsOverride` يستبعد صراحة حالة `error`)، الحقل غير المُلمَس يُمسَح، Submit يُمنَع بالكامل، وتظهر رسالة عربية واضحة مع زر **"إعادة التحقق"** يُعيد تشغيل نفس دالة الجلب (`fetchFeePreview`) دون تكرار كود.

### 2) البند 4 — Preview Key invariant

بدل الاعتماد فقط على توقيت `useEffect`، أُضيف مفتاح صريح `currentFeePreviewKey = direction|zone|date` وحالة `resolvedFeePreviewKey`. **Submit لشحنة إرجاع مسموح فقط عندما يتطابق المفتاحان AND الحالة `found` أو `not_found`** — invariant واحد يستبعد `idle`/`loading`/`error` وأيضًا نتيجة محلولة تخصّ منطقة/تاريخ سابقين معًا، بدل الاعتماد الضمني على ترتيب تنظيف الـeffect. طلب/استجابة أيضًا مُفتَّح بـkey داخليًا (`feePreviewRequestKeyRef`) — استجابة متأخرة من طلب سابق تُكتشَف وتُهمَل تلقائيًا.

### 3) البند 5 — اختبارات React لمسار الخطأ (4 اختبارات جديدة)

`tests/shipment-entry-form-return-fee.test.tsx` (12 اختبارًا، كان 8): success:false يعرض خطأ مميَّزًا ويمنع Submit حتى مع رسم يدوي (item A)؛ استثناء مرمي فعليًا يُعامَل مطابقًا تمامًا بلا unhandled rejection (item B)؛ إعادة التحقق بعد خطأ تنتقل إلى `found` وتملأ الحقل تلقائيًا وتُفعِّل Submit (item C)؛ إعادة التحقق بعد خطأ تنتقل إلى `not_found` الحقيقية **فقط بعد** الاستجابة الناجحة، لا أثناء الخطأ (item D).

**عيب حقيقي اكتُشِف وأُصلِح أثناء كتابة هذه الاختبارات:** زر "إعادة التحقق" كان مربوطًا بـ`disabled={isPending}` — لكن `isPending` مُشتركة مع تأثير معاينة تكلفة الناقل غير ذي الصلة، فكان الزر يُعطَّل فعليًا في نافذة زمنية قصيرة رغم أن حالة المعاينة نفسها كانت `"error"` بوضوح. أُصلِح بإزالة هذا الربط — الزر يختفي من الـDOM فور الضغط أصلاً (انتقال فوري لحالة `"loading"`)، فلا حاجة لعلم تعطيل إضافي غير ذي صلة.

### 4) البند 6 — استكمال اختبار Viewer-only لصفحة `/shipments` الفعلية (6 اختبارات جديدة)

الملف `tests/shipment-view-only-ui.test.tsx` كان يختبر فقط مكوّني صفحة التفاصيل رغم اسمه/وصفه العامّين — صفحة `/shipments` (القائمة، الـRequirement الأصلي) لم تكن مغطاة إطلاقًا. أُضيف قسم يستدعي `ShipmentsPage` (Server Component) مباشرة كدالة (بنفس أسلوب اختبار Server Action المباشر من Hotfix 5.1.2)، مع تثبيت كل استعلاماتها: فاعل بـ`shipments.view` فقط يرى رقم الشحنة/رقم عملية البيع/رسوم الشحن على العميل، لا يرى عمودَي "صافي الشحن" (الترويسة نفسها غائبة من الـJSX، لا القيمة فقط)، لا يرى "شحنة جديدة"، والصفحة تعتمد فعليًا على `shipments_filter_carrier_lookups()`/`shipments_filter_zone_lookups()`/`shipments_visible_store_lookups()` (المُقيَّدة بـ`shipments.view` وحدها) — مؤكَّد عبر التحقق من استدعاء الدوال الصحيحة فعليًا، لا الاستعلامات القديمة المُقيَّدة بـ`shipments.create`. اختباران ضابطان (فاعل بـ`sales.view_profit` إضافية، وفاعل بـ`shipments.create` إضافية) يثبتان أن التأكيدات ذات معنى فعليًا. الإجمالي: 11 اختبارًا (كان 5).

### 5) البند 5 (تكملة) — استكمال HTTP/PostgREST الحقيقي (بنود 7/8/9/10)

`scripts/postgrest-http-test.mjs`'s Part 10 امتدت بأربعة بنود جديدة دون مساس ببنود A–I القائمة: **item 7** — PATCH مباشر على جدولَي تسعير الشحن المُقفَلين (base_cost/fee_amount/effective_from) بلا أثر؛ **item 8** — `shipments_visible_store_lookups()` تنجح لفاعل `shipments.view`-فقط؛ **item 9** — شحنة جديدة تُنشأ بعد إعادة تسمية الناقل/المنطقة تلتقط الأسماء **الجديدة** (يكمل إثبات item G أن اللقطة زمنية حقيقية، لا قيمة مجمَّدة أبدية)؛ **item 10** — UPDATE مباشر على `shipment_cod_events` وعلى `shipments.cod_collection_state` نفسه، كلاهما بلا أثر.

**عيب حقيقي اكتُشِف وأُصلِح أثناء أول تشغيل فعلي لهذه البنود:** التأكيدات الأولى اشترطت خطأً وجود خطأ مرمي فعليًا (`error !== null`) كإثبات للرفض — لكن سلوك PostgREST الفعلي لـUPDATE على جدول بلا سياسة UPDATE مطابقة ليس بالضرورة رمي خطأ: شرط WHERE يطابق ببساطة صفر صفوف (RLS تستبعدها قبل وصول الـUPDATE إليها)، فتُعيد PostgREST استجابة 2xx طبيعية بلا خطأ وبلا أي صف متأثر. أُصلِحت التأكيدات بتسلسل `.select("id")` بعد UPDATE والتحقق من مصفوفة فارغة (الإشارة الحقيقية للرفض)، مع فحص خطأ احتياطي وقراءة لاحقة مستقلة تؤكِّد بقاء القيمة الأصلية. **ليس عيبًا في أي RLS/RPC — الحماية كانت صحيحة دومًا؛ العيب كان في شرط تأكيد اختبار HTTP نفسه.**

### 6) لا صلاحيات جديدة، لا صفحات جديدة

لم يُضَف أي مفتاح صلاحية جديد، ولا صفحة جديدة. `npm run build`: **28 مسارًا**، مطابق تمامًا لِـHotfix 5.1.2.

### 7) قرارات تصميم أساسية

1. **حالة "error" منفصلة تمامًا عن "not_found"، لا وكيل مشترك:** فشل الاستدعاء وفشل التسعير (لا تسعير معتمد) أمران مختلفان جوهريًا يتطلبان استجابتين مختلفتين تمامًا من الواجهة — دمجهما في حالة واحدة هو بالضبط ما مكَّن الـBlocker من الوجود (بند 1/2/3).
2. **Preview Key invariant صريح بدل الاعتماد على ترتيب React effects:** التحقق من "هل النتيجة المحلولة تخص ما هو مختار حاليًا فعليًا؟" يجب أن يكون فحصًا صريحًا وقابلاً للقراءة، لا نتيجة جانبية لتوقيت تنظيف effect قد يتغيّر سلوكه بين إصدارات React (بند 4).
3. **زر Retry غير مرتبط بأعلام `isPending` مشتركة:** أي علم "قيد التنفيذ" مشترك بين عمليات غير مترابطة (هنا: معاينة تكلفة الناقل vs. إعادة محاولة معاينة رسوم الإرجاع) يخلق اقترانًا زائفًا — كل عملية غير مترابطة يجب أن تتحكم في تعطيل عناصرها الخاصة بمنطقها الخاص فقط، لا بعلم عام (القسم 3، العيب المُكتشَف).
4. **`.select()` بعد UPDATE هو الإشارة الصحيحة لرفض RLS بلا سياسة UPDATE:** خطأ مرمي هو حالة خاصة، لا القاعدة العامة — "صفر صفوف متأثرة" هو السلوك الافتراضي الفعلي لـPostgREST/RLS عند غياب سياسة مطابقة، ويجب أن يُفحَص مباشرة لا افتراضه (القسم 5، العيب المُكتشَف).

### 8) الاختبارات — قائمة كاملة وأرقام فعلية (نُفِّذت في هذه الجلسة)

تفصيل كامل بالأرقام في `TEST_RESULTS_HOTFIX_5_1_3.md`. ملخَّص: **132/132 ترحيلة من الصفر (صفر جديدة)** + **3/3 إثباتات ترقية** + **15/15 ملف اختبار SQL، صفر انحدار** + **كل سيناريوهات التزامن الحقيقية (H1–L2/R1–R7/A–G) بلا انحدار** + **اختبار HTTP/PostgREST حقيقي كامل ناجح (Part 10 مُوسَّعة ببنود 7/8/9/10، بعد تصحيح عيب UPDATE-denial)** + **صفر أخطاء TypeScript/ESLint** + **83/83 اختبار Vitest عبر 10 ملفات (10 اختبارات جديدة: 4 مسار خطأ + 6 قائمة `/shipments`)** + **56/56 عمود NUMERIC** + **بناء إنتاجي ناجح، 28 مسارًا**.

### 9) الملفات التي تغيَّرت أو أُضيفت في Hotfix 5.1.3 (قائمة كاملة)

**ترحيلات جديدة:** لا شيء — 0 ترحيلة جديدة.

**كود TypeScript/React مُعدَّل:** `src/features/shipping/components/shipment-entry-form.tsx` (حالة `feePreviewStatus` خماسية، `fetchFeePreview` مُستخرَجة بـ`useCallback`، Preview Key invariant، زر "إعادة التحقق"، رسالة خطأ مميَّزة).

**اختبارات Vitest قائمة مُعدَّلة (لا ملف جديد هذه المرة):** `tests/shipment-entry-form-return-fee.test.tsx` (+4 اختبارات: items A/B/C/D لمسار الخطأ/إعادة التحقق، الإجمالي 12)، `tests/shipment-view-only-ui.test.tsx` (+6 اختبارات: صفحة `/shipments`، الإجمالي 11).

**تركيب اختبار HTTP قائم مُعدَّل (test-only، غير ترحيلي):** `scripts/postgrest-http-test.mjs` (Part 10 مُوسَّعة ببنود 7/8/9/10 + تصحيح منطق تأكيد UPDATE-denial + تحديث تعليق الرأس التوثيقي).

**لم يتغيّر إطلاقًا:** أي ترحيل من 0001–0132، أي صلاحية، أي صفحة جديدة، أي جدول/عمود، منطق أي اختبار SQL/تزامن/ترقية خارج إعادة التشغيل للتحقق من عدم الانحدار، بنود A–I الأصلية من Part 10 (Hotfix 5.1.2).

**خلاصة الملحق الرابع والعشرون:** إصلاح Blocker حقيقي واحد في آلة حالة المعاينة (خلط خطأ الاستدعاء مع "لا تسعير معتمد") + إغلاق نافذة stale-preview بـinvariant صريح بدل الاعتماد الضمني على React + استكمال عشر فجوات تحقق محددة (4 React + 6 HTTP)، بلا أي حاجة SQL فعلية — واكتشاف وتصحيح عيبين إضافيين حقيقيين أثناء التنفيذ نفسه (زر Retry مربوط بعلم مشترك غير ذي صلة؛ ومنطق تأكيد UPDATE-denial الذي اشترط خطأً وجود استثناء مرمي بدل التحقق من صفر صفوف متأثرة) — كلاهما في الواجهة الأمامية/كود الاختبار، لا في أي RPC/RLS/ترحيلة. **132/132 ترحيلة من الصفر + 3/3 إثباتات ترقية + 15/15 ملف اختبار SQL + كل سيناريوهات التزامن الحقيقية بلا انحدار + اختبار HTTP/PostgREST حقيقي كامل ناجح + صفر أخطاء TypeScript/ESLint + 83/83 اختبار Vitest عبر 10 ملفات + 56/56 عمود NUMERIC + بناء إنتاجي ناجح، 28 مسارًا — كلها من تشغيلات فعلية في هذه الجلسة. لم تبدأ Settlements ولا أي مرحلة أخرى — العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP كامل للمشروع بأكمله (لا ZIP فروقات) لهذا الملحق.**

---

## الملحق الخامس والعشرون — "Phase 6: نواة الخدمات/التعديلات (Services / Adjustments Core)" (ترحيلات 0133–0143)

هذا الملحق يوثِّق **Phase 6** كاملة، بناءً على مواصفة المستخدم الصريحة: **"نفّذ فقط"** — بناء وحدة "خدمات/تعديلات ما بعد البيع" جديدة كليًا مرتبطة بعمليات بيع قائمة فعليًا، **مستقلة تمامًا** عن حساب ربحية المبيعات/المرتجعات/الشحن، بأنواع خدمة قابلة للتهيئة (بلا أي نوع مُقولَب)، دورة حياة كاملة (معلَّق ← معتمَد/مرفوض، عكس إداري إضافي-فقط)، إعادة استخدام محرك رسوم الدفع القائم حرفيًا (لا إعادة تطبيق أبدًا)، حماية ربح على مستوى القاعدة، صلاحيات دقيقة الحبيبات، وتغطية اختبار واسعة (HTTP/تزامن/SQL/Vitest). القيود الصارمة كالمعتاد وبقيت سارية طوال هذا الملحق: **"لا تعدل أي migration من 0001 إلى 0132"** — كل ترحيلة جديدة بدأت من 0133 فصاعدًا (11 ترحيلة: 0133–0143)؛ **"لا تبدأ Settlements"**، **"لا تقارير/لوحة تحكم نهائية"**، **"لا Inventory"**، **"لا PDF/Excel"**، **"لا مرفقات/نسخ احتياطي/2FA"**، **"لا تكامل خارجي"**. العمل **متوقف الآن نهائيًا**: **"لا تبدأ Settlements بعد الانتهاء. توقف وانتظر المراجعة."**

### 1) الترحيلات الجديدة (0133–0143)

| # | الترحيلة | تُضيف |
|---|---|---|
| 0133 | `adjustments_permissions_and_locks.sql` | أربع صلاحيات جديدة (`adjustments.manage_cost`/`adjustments.reverse`/`adjustments.process_closed_day`/`adjustments.manage_types`) بالإضافة إلى `adjustments.view`/`create`/`approve` المُهيَّأة مسبقًا في `seed.sql` (بلا أي RPC يستهلكها قبل هذه المرحلة، تمامًا كحال `returns.*`/`shipments.*` في مراحلهما)؛ منح للأدوار الثلاثة (`super_admin`/`admin`=4 لكل منهما، `supervisor`=3 بلا `manage_types`)؛ قفل استشاري جديد للتعديلات/الخدمات (`acquire_adjustments_lock_shared/exclusive`، `key1=1006`، يطابق نمط `acquire_financial_master_lock_shared/exclusive`/`acquire_shipping_rates_lock_shared/exclusive` حرفيًا). |
| 0134 | `adjustment_types_schema.sql` | جدول Master Data `adjustment_types` (RLS من الطبقة-A — صفر سياسات مباشرة، كتابة حصرًا عبر RPCs) — `code` غير قابل للتعديل بعد الإنشاء، حذف مستحيل (تعطيل/تفعيل فقط)، بلا أي نوع مُقولَب. |
| 0136 | `adjustment_type_rpcs.sql` | `create_adjustment_type()`/`update_adjustment_type()`/`disable_adjustment_type()`/`enable_adjustment_type()` — جميعًا `SECURITY DEFINER`، مقيَّدة بـ`adjustments.manage_types`. |
| 0135 | `sales_order_adjustments_schema.sql` | مولِّد رقم تعديل ذري (`generate_adjustment_number()`، تسلسل Postgres حقيقي، نمط `ADJ-0000000001` مطابق لِـ`generate_sales_order_number()`/`generate_shipment_number()`)؛ جدول `sales_order_adjustments` (الرأس المالي، RLS من الطبقة-A، لا يمس `sales_orders.subtotal` إطلاقًا)؛ جدول `sales_order_adjustment_reversals` (سجل عكس إضافي-فقط، `UNIQUE(sales_order_adjustment_id)` — عكس واحد كحد أقصى أبدًا). |
| 0137 | `adjustments_narrow_lookups.sql` | دوال بحث/اختيار ضيقة (`adjustments_operable_store_lookups`/`adjustments_visible_store_lookups`/`adjustments_active_type_lookups`/`adjustments_payment_method_lookups`/`adjustments_collection_channel_lookups`/`search_sales_orders_for_adjustment`) — كل واحدة مقيَّدة بالصلاحية الدقيقة التي تحتاجها فقط؛ `search_sales_orders_for_adjustment()` **لا تعتمد على `sales.view` إطلاقًا** (§25، مُثبَتة عبر HTTP حقيقي). |
| 0138 | `preview_sales_order_adjustment.sql` | معاينة بلا كتابة، تُعيد كل حقل مالي كـ`text` (حدود النقل العشري)، تعيد استخدام `payment_fee_for_method_on_date_safe()` حرفيًا. |
| 0139 | `create_and_update_sales_order_adjustment.sql` | `create_sales_order_adjustment()` (نقطة الدخول المعاملاتية الوحيدة، قفل الإغلاق اليومي المشترك، رقم ADJ ذري)؛ `update_sales_order_adjustment()` (سجل معلَّق فقط، تزامن تفاؤلي بـ`row_version`). |
| 0140 | `approve_and_reject_sales_order_adjustment.sql` | `approve_sales_order_adjustment()` (إعادة احتساب رسمية للرسوم/الربح وقت الاعتماد، لقطة اسم النوع وقت الاعتماد لا الإنشاء)؛ `reject_sales_order_adjustment()`. **عُدِّلت في هذه الجلسة** لإضافة تحقُّق `adjustments.manage_cost` إلى جانب `adjustments.approve` (انظر §5 بند 9 أدناه). |
| 0141 | `reverse_sales_order_adjustment.sql` | `reverse_sales_order_adjustment()` — عكس إداري إضافي-فقط، لا يُعدِّل أي عمود مالي على السجل الأصلي أبدًا، `UNIQUE` يمنع عكسًا مزدوجًا حتى تحت تزامن حقيقي. |
| 0142 | `sales_order_adjustment_read_rpcs.sql` | `get_sales_order_adjustment()` (`effective_status` مُشتقة خادميًا من الحالة الأساسية + وجود سجل عكس)؛ `list_sales_order_adjustments()`؛ `get_sales_order_adjustment_summary()` (Original Invoice + Effective Approved Adjustments Charges = Total Including Adjustments، §40). |
| 0143 | `audit_logs_adjustments_profit_protection.sql` | توسيع سياسة `audit_logs_select` لتشمل أربعة أفعال مالية محدَّدة صراحة (`adjustment.create`/`update`/`approve`/`reverse`) تحت شرط `sales.view_profit` — تدقيق دقيق الحبيبات مطابق لنمط `shipment.%` (0121) لا `return.%` الشامل بالبادئة؛ `adjustment.reject`/`adjustment.closed_day_override`/`adjustment_type.*` تبقى ظاهرة لأي فاعل يملك `audit_logs.view` فقط. |

### 2) الجداول الجديدة (3) ونموذج الوصول

**Master Data (RLS من الطبقة-A، لا Master Data مباشرة كـ`karats`):** `adjustment_types` — قرار مختلف عمدًا عن نموذج `shipping_carriers`/`karats` (RLS مباشرة)، لأن `adjustment_types` تحمل فقط بيانات وصفية بلا أي حساسية سعرية بحد ذاتها، لكن القرار كان تعميم نموذج القفل الكامل (RPC-only) على كل Phase 6 دون استثناء لتبسيط سطح المراجعة الأمنية.

**نموذج RPC-فقط (صفر سياسات RLS مباشرة، مطابق لِـ`sales_orders`/`shipments` حرفيًا):** `sales_order_adjustments`، `sales_order_adjustment_reversals`. كلاهما يُقرَآن حصرًا عبر `get_sales_order_adjustment()`/`list_sales_order_adjustments()` ويُكتَبان حصرًا عبر RPCs الكتابة في 0139/0140/0141، جميعًا `SECURITY DEFINER`. قراءة مباشرة عبر PostgREST من **أي** دور (حتى فاعل كامل الصلاحيات) تعيد صفر صفوف بصمت — مُثبَتة فعليًا عبر HTTP حقيقي في هذه الجلسة (§8 أدناه).

### 3) الصفحات والمكوّنات الجديدة

`/adjustments` (قائمة مع فلاتر وعمود ربح مشروط بالصلاحية)، `/adjustments/new` (بحث عن عملية بيع ثم نموذج إدخال مع معاينة حيّة)، `/adjustments/[id]` (تفاصيل + ملخص مالي مشروط بالربح + معلومات العكس)، `/adjustments/[id]/edit` (تحرير سجل معلَّق فقط، إعادة توجيه لصفحة التفاصيل غير ذلك)، `/master-data/adjustment-types` (إدارة أنواع الخدمة/التعديل). مكوّنات: `adjustment-order-search.tsx`، `adjustment-entry-form.tsx` (معاينة حيّة عند التفاعل الصريح، لا عند التحميل — قرار توافق ESLint موثَّق)، `adjustment-lifecycle-actions.tsx` (اعتماد/رفض/عكس/تحرير حسب الحالة والصلاحية)، `adjustment-type-form-dialog.tsx`، `adjustment-type-status-toggle.tsx`. طبقة الخلفية: `src/features/adjustments/{schema,queries,actions}.ts`. صفحة تفاصيل عملية البيع (`/sales/[id]`) وُسِّعت ببطاقة "الخدمات والتعديلات" (ملخص Original/Adjustments/Total + قائمة مصغَّرة + زر إنشاء جديد، كل ذلك مشروط بالصلاحية).

### 4) الصلاحيات (7 إجمالًا للوحدة، 4 جديدة في هذه المرحلة)

`adjustments.view`/`adjustments.create`/`adjustments.approve` كانت مُهيَّأة مسبقًا في `seed.sql` (Coming Soon سابقًا، بلا أي RPC يستهلكها). الترحيلة 0133 أضافت: `adjustments.manage_cost` (إدارة التكلفة المباشرة، **ومطلوبة أيضًا للاعتماد** — انظر §5 بند 9)، `adjustments.reverse` (عكس إداري، منفصلة تمامًا عن `adjustments.approve`)، `adjustments.process_closed_day` (معالجة في يوم مقفل)، `adjustments.manage_types` (إدارة Master Data، `admin`/`super_admin` فقط — `supervisor` مُستثنى صراحة).

### 5) قرارات تصميم أساسية — شرح مختصر لكل قرار

1. **دورة حياة معلَّق → معتمَد/مرفوض، عكس إداري إضافي-فقط لا حذف/تعديل مباشر:** بنفس فلسفة `sales_return_refund_events`/`shipment_financial_events` تمامًا — أي تصحيح بعد الاعتماد يُضيف سجل عكس جديدًا (`sales_order_adjustment_reversals`)، لا يُعدِّل السجل الأصلي أبدًا؛ `UNIQUE(sales_order_adjustment_id)` يمنع عكسًا مزدوجًا حتى تحت تزامن حقيقي (مُثبَت بسيناريو B في اختبار التزامن).
2. **الفصل المالي الكامل عن المبيعات/المرتجعات/الشحن:** لا RPC واحدة في Phase 6 تقرأ أو تكتب `sales_orders.net_sales_profit`/أي عمود ربح Returns/Shipping؛ الإثبات العكسي (أن ربح البيعة المرتبطة يبقى بلا تغيير بعد اعتماد وعكس التعديل) مُثبَت مرتين مستقلتين — مرة SQL (`adjustments_core_phase6.test.sql`) ومرة HTTP حقيقي.
3. **لقطة رسوم الدفع تُعيد استخدام `payment_fee_for_method_on_date_safe()` حرفيًا، لا إعادة تطبيق:** الصيغة نفسها المستخدَمة في Sales/Returns/Shipping (`round((amount * percentage_fee / 100) + fixed_fee, 2)`) — يضمن اتساقًا حسابيًا كاملًا عبر النظام كله بلا أي فرصة لانحراف صيغة بين وحدة وأخرى.
4. **مشاركة التسوية (`participates_in_settlement`) عمود معلوماتي بحت في هذه المرحلة:** يُسجَّل ويُعرَض فقط — بلا أي منطق تسوية فعلي (وحدة Settlements غير مبدوءة عمدًا)، تمامًا كحال `is_cod` في Shipping قبل أي منطق تسوية COD فعلي.
5. **خصوصية التكلفة المباشرة على مستوى القاعدة تُطبَّق بصلاحيتين منفصلتين لا واحدة:** `adjustments.create` تكفي لإنشاء التعديل، لكن **تعيين/رؤية `direct_cost` أثناء الإنشاء والتعديل تتطلب أيضًا `sales.view_profit`** بنفس نمط بقية الوحدات — بينما التحكم فيمن **يعتمد** سجلًا يحمل تكلفة مباشرة مُدخَلة صار يتطلب `adjustments.manage_cost` تحديدًا (§ بند 9 أدناه)، فصل واضح بين "من يرى الربح" و"من يملك سلطة اعتماد قرار مالي".
6. **دفتر العكس إضافي-فقط، لا عمود حالة يُعدَّل مباشرة:** `effective_status` (pending/approved/rejected/reversed) دالة خادمية محسوبة من العمود الأساسي `status` + وجود سجل في `sales_order_adjustment_reversals` — لا عمود واحد يُحدَّث في مكانه بواسطة العكس، يطابق فلسفة `get_sales_return()`'s `status` المُشتقة من `sales_return_refund_event_reversals` حرفيًا.
7. **الفاتورة الأصلية مقابل الإجمالي شاملًا التعديلات — مفهومان منفصلان صراحة، لا دمج صامت:** `sales_orders.subtotal` (الفاتورة الأصلية) لا يُلمَس أبدًا؛ `get_sales_order_adjustment_summary()` تحسب Original Invoice Amount + Effective Approved (non-reversed) Adjustments Charges = Total Including Adjustments كدالة قراءة منفصلة — لا عمود مخزَّن واحد يمكن أن ينحرف عن مصدره.
8. **نطاق المتجر يُعاد استخدام `user_visible_store_ids()`/نمط تشغيل المتجر القائم حرفيًا، بلا صلاحية نطاق جديدة:** `adjustments_operable_store_lookups()`/`adjustments_visible_store_lookups()` تطبِّقان نفس فلسفة Returns/Shipping تمامًا (تشغيل مقيَّد بصلاحية الإنشاء، رؤية مقيَّدة بصلاحية العرض فقط)، بلا حاجة لصلاحية "نطاق متجر" مستقلة لكل وحدة.
9. **إغلاق فجوة صلاحية حقيقية اكتُشِفت أثناء هذه الجلسة — `adjustments.manage_cost` غير مُفعَّلة فعليًا في `approve_sales_order_adjustment()`:** كانت الترحيلة 0133 توثِّق `adjustments.manage_cost` صراحة في تعليقها كـ"مطلوبة للاعتماد"، لكن لم تكن أي RPC تتحقق منها فعليًا (0134–0143 الأصلية) — فجوة حقيقية بين التوثيق والتطبيق تتعارض مع مطلب "صلاحيات دقيقة الحبيبات". أُصلِحت مباشرة في الترحيلة 0140 بإضافتها كشرط ثانٍ إلزامي إلى جانب `adjustments.approve`، مع تحديث رسالة الخطأ وتعليق التوثيق ليعكسا الشرط المزدوج فعليًا. أُعيد تشغيل مجموعة الاختبار الكاملة (17 SQL + 4 تزامن + 4 ترقية) بعد الإصلاح → صفر انحدار (كل ممثِّلي الاختبار المانحين `adjustments.approve` يملكون `adjustments.manage_cost` بالفعل في بذور الاختبار).
10. **قفل الإغلاق اليومي (`1006`) وحماية الربح على مستوى القاعدة تعيدان استخدام الآليات القائمة حرفيًا، لا آليات جديدة:** نفس نمط `acquire_financial_master_lock_shared/exclusive`/`acquire_shipping_rates_lock_shared/exclusive` للقفل الاستشاري، ونفس صلاحية `sales.view_profit` الموحَّدة لحماية الربح — بلا أي آلية أو صلاحية مُجزَّأة جديدة لكل وحدة.

### 6) التدقيق (Audit) — تدقيق دقيق الحبيبات مطابق لنمط `shipment.%`

أربعة أفعال مالية (`adjustment.create`/`update`/`approve`/`reverse`) مكتوبة صراحة داخل كل RPC، مُدرَجة صراحة (لا بادئة شاملة) ضمن شرط `sales.view_profit` في الترحيلة 0143 — بينما `adjustment.reject`/`adjustment.closed_day_override` (بلا رقم مالي) و`adjustment_type.create`/`adjustment_type.update` (Master Data بلا رقم مالي بحد ذاته) تبقى ظاهرة لأي فاعل يملك `audit_logs.view` فقط. مُثبَت الفصل الدقيق فعليًا عبر HTTP حقيقي (§8 أدناه، بند n).

### 7) حماية الربح على مستوى القاعدة

`get_sales_order_adjustment()`/`list_sales_order_adjustments()` تُخفيان `direct_cost`/`payment_fee_amount`/`gross_adjustment_profit`/`net_adjustment_profit` بشرط `sales.view_profit` — **غائبة تمامًا** (لا `null`) في `get_sales_order_adjustment()`، و`null` صريح في صفوف `list_sales_order_adjustments()` الجدولية؛ `customer_charge`/`participates_in_settlement` تبقيان ظاهرتين دومًا (بيانات غير حسّاسة للعميل). مُثبَتة عبر HTTP حقيقي.

### 8) الاختبارات — قائمة كاملة وأرقام فعلية (نُفِّذت في هذه الجلسة)

تفصيل كامل بالأرقام في `TEST_RESULTS_PHASE_6_ADJUSTMENTS.md`. ملخَّص:

- إعادة بناء قاعدة اختبار Postgres محلية **من الصفر بالكامل**: `local_harness_setup.sql`، **كل الترحيلات 0001–0143 بالترتيب دون توقف** (143/143 نجحت)، ثم `supabase/seed.sql` (نجح).
- **17/17 ملف اختبار SQL غير-تزامني** (16 قائمًا + `adjustments_core_phase6.test.sql` الجديد بالكامل) → **نجحت جميعًا، صفر انحدار**.
- **4/4 ملفات تزامن حقيقي (`dblink`)** (3 قائمة + `adjustments_core_phase6_concurrency.test.sql` الجديد بالكامل، سيناريوهات A–D) → **نجحت جميعًا**.
- **4/4 مسارات ترقية** (3 قائمة + `run_upgrade_test_phase6_adjustments.sh`/`upgrade_phase6_adjustments.test.sql` الجديدان بالكامل — يُثبتان أن الوحدة تعمل فورًا فوق بيانات بيع حقيقية أُنشئت بالمخطط القديم قبل Phase 6، دون أي إعادة تشغيل لِـ`seed.sql`) → **نجحت جميعًا**.
- اختبار HTTP/PostgREST الحقيقي (`scripts/run_postgrest_http_test.sh`، ثنائي PostgREST v12.2.3 حقيقي عبر HTTP فعلي، 4 JWT حقيقية) → **نجح بالكامل**، شاملًا "Part 11" الجديد (14 عنصرًا a–n). **عيبان حقيقيان اكتُشِفا وأُصلِحا في سكربت الاختبار نفسه أثناء هذا التشغيل** (استخراج صف من مصفوفة `returns table` ناقص في موضعين — انظر `TEST_RESULTS_PHASE_6_ADJUSTMENTS.md` §5 للتفصيل الكامل)؛ لا تعديل واحد على أي كود تطبيق أو SQL.
- **عيب حقيقي إضافي اكتُشِف وأُصلِح في SQL نفسه:** `adjustments.manage_cost` كانت موثَّقة كمطلوبة للاعتماد لكن غير مُفعَّلة فعليًا — أُصلِحت في 0140 (تفصيل كامل في §5 بند 9 أعلاه).
- `DATABASE_URL=... npx tsx scripts/check-numeric-column-types.ts` → **نجح، 68/68 عمود NUMERIC مطابق** (يشمل 8 أعمدة جديدة في `sales_order_adjustments`/`sales_order_adjustment_reversals`).
- `npx tsc --noEmit` → **صفر أخطاء**.
- `npx eslint .` → **صفر أخطاء وتحذيرات**.
- `npx vitest run` → **100/100 ناجح عبر 12 ملفًا** (17 اختبارًا جديدًا لِـPhase 6: 6 حدود صلاحيات Server Actions + 11 واجهة/حجب ربح).
- `npm run build` (Next.js/Turbopack) → **نجح**، **بزيادة 5 مسارات Adjustments**: `/adjustments`، `/adjustments/new`، `/adjustments/[id]`، `/adjustments/[id]/edit`، `/master-data/adjustment-types`.

### 9) الملفات/الترحيلات التي تغيَّرت أو أُضيفت في Phase 6 (قائمة كاملة)

**ترحيلات جديدة (11):** `0133_adjustments_permissions_and_locks.sql`، `0134_adjustment_types_schema.sql`، `0135_sales_order_adjustments_schema.sql`، `0136_adjustment_type_rpcs.sql`، `0137_adjustments_narrow_lookups.sql`، `0138_preview_sales_order_adjustment.sql`، `0139_create_and_update_sales_order_adjustment.sql`، `0140_approve_and_reject_sales_order_adjustment.sql`، `0141_reverse_sales_order_adjustment.sql`، `0142_sales_order_adjustment_read_rpcs.sql`، `0143_audit_logs_adjustments_profit_protection.sql`.

**اختبارات SQL جديدة بالكامل:** `supabase/tests/adjustments_core_phase6.test.sql`، `supabase/tests/adjustments_core_phase6_concurrency.test.sql`، `supabase/tests/upgrade_phase6_adjustments.test.sql`.

**سكربتات جديدة:** `scripts/run_upgrade_test_phase6_adjustments.sh`.

**سكربتات/إعداد HTTP مُعدَّلان (إضافة فقط، لا حذف):** `scripts/postgrest-http-test.mjs` (قسم "Part 11" الجديد بالكامل + فاعل HTTP رابع)، `scripts/run_postgrest_http_test.sh` (توقيع JWT رابع)، `supabase/tests/postgrest_http_test_setup.sql` (منح صلاحيات Adjustments لممثِّلَي الاختبار القائمَين + فاعل ثالث جديد بصلاحية `adjustments.create` فقط).

**كود TypeScript جديد بالكامل:** `src/features/adjustments/{schema,queries,actions}.ts`، `src/features/adjustments/components/{adjustment-order-search,adjustment-entry-form,adjustment-lifecycle-actions,adjustment-type-form-dialog,adjustment-type-status-toggle}.tsx`، `src/app/(app)/adjustments/page.tsx` (استبدال الواجهة المؤقتة "قريبًا")، `src/app/(app)/adjustments/new/page.tsx`، `src/app/(app)/adjustments/[id]/page.tsx`، `src/app/(app)/adjustments/[id]/edit/page.tsx`، `src/app/(app)/master-data/adjustment-types/page.tsx`.

**كود TypeScript مُعدَّل:** `src/types/database.ts` (3 أنواع/جداول جديدة + ~20 دالة جديدة)، `src/lib/permissions/constants.ts` (4 مفاتيح صلاحيات جديدة)، `src/lib/constants.ts` (`ROUTES.adjustmentsNew`/`ROUTES.masterDataAdjustmentTypes`)، `src/components/layout/nav-items.ts` (إزالة `comingSoon` عن Adjustments + إصلاح فجوة صلاحية سابقة في مركز Master Data)، `src/app/(app)/master-data/page.tsx` (قسم جديد لأنواع التعديلات/الخدمات)، `src/app/(app)/sales/[id]/page.tsx` (بطاقة "الخدمات والتعديلات" الجديدة).

**اختبارات Vitest جديدة بالكامل:** `tests/adjustments-actions-permission-boundary.test.ts`، `tests/adjustments-view-only-ui.test.tsx`.

**لم يتغيّر إطلاقًا:** أي ترحيل من 0001–0132، أي اختبار SQL قائم (منطقًا)، أي صفحة/مكوّن خارج ما ذُكِر أعلاه.

**خلاصة الملحق الخامس والعشرون:** وحدة خدمات/تعديلات ما بعد البيع كاملة وظيفيًا ومستقلة ماليًا تمامًا عن المبيعات/المرتجعات/الشحن — أنواع خدمة قابلة للتهيئة بلا أي نوع مُقولَب، دورة حياة كاملة (معلَّق ← معتمَد/مرفوض) مع عكس إداري إضافي-فقط لا يمس السجل الأصلي أبدًا، إعادة استخدام محرك رسوم الدفع القائم حرفيًا، حماية ربح على مستوى القاعدة تصمد أمام أي مسار تجاوز (مُثبَتة عبر HTTP حقيقي أيضًا)، صلاحيات دقيقة الحبيبات (بما فيها إصلاح فجوة حقيقية اكتُشِفت أثناء المراجعة الذاتية لهذه الجلسة)، وتغطية اختبار واسعة عبر كل طبقة. **17/17 ملف اختبار SQL + 4/4 سيناريوهات تزامن حقيقية جديدة + 4/4 مسارات ترقية (شاملة مسار Phase 6 الجديد فوق بيانات بيع حقيقية قبل الترقية) + 14 عنصر إثبات HTTP حقيقي جديد (a–n) + 17 اختبار Vitest جديد + 68/68 عمود NUMERIC + بناء إنتاجي ناجح — كلها من تشغيلات فعلية في هذه الجلسة. ثلاثة عيوب حقيقية اكتُشِفت وأُصلِحت أثناء هذه الجلسة بالذات (اثنان في سكربت اختبار HTTP، وواحد جوهري في تفعيل صلاحية `adjustments.manage_cost`) — كلها قبل أي تسليم فعلي، بلا حاجة لترحيلة تصحيحية منفصلة لاحقة. لم تبدأ Settlements ولا أي مرحلة أخرى — العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP كامل للمشروع.**

---

## الملحق السادس والعشرون — "Phase 6 Integrity Patch 6.1: سلامة Services/Adjustments المالية والأمنية" (ترحيلات 0144–0156)

هذا الملحق يوثِّق **Patch 6.1** كاملة — تصحيح شامل مبني على مواصفة مستخدم صريحة من 38 بندًا مرقَّمًا فوق Phase 6 Core (الملحق الخامس والعشرون)، بناءً على مراجعة أمنية/مالية مستقلة لتلك المرحلة كشفت عدة ثغرات: تسريب صلاحية غير مقصود (فاعل `adjustments.create`-فقط يمكنه إدخال `direct_cost` بلا `adjustments.manage_cost`)، تناقض دلالي للخدمة المجانية (رسم تحصيل صفري لا يجب أن يحمل طريقة دفع)، فجوة حبيبات-صلاحية مخفية (فاعل إنشاء-فقط يُنشئ سجلًا معلَّقًا ثم يُرفَض عند محاولة تعديله)، ثغرة عزل-متجر عبر القراءة/الرفض، وغياب سجل أثر رقمي مفصَّل لعملية العكس. القيود الصارمة كالمعتاد وبقيت سارية طوال هذا الملحق: **"لا تعدل أي migration من 0001 إلى 0143"** — كل ترحيلة جديدة بدأت من 0144 فصاعدًا (13 ترحيلة: 0144–0156)؛ **"لا تبدأ Settlements/Reports/Dashboard/Inventory"**؛ **"لا تعيد تصميم الوحدة من الصفر"** — كل ~19 ثابتًا معماريًا من Phase 6 Core محفوظ دون مساس (RPC-only writes، Layer-A RLS lockdown، دورة الحياة معلَّق←معتمَد/مرفوض، العكس الإضافي-فقط، استقلالية الربح عن المبيعات، إلخ). العمل **متوقف الآن نهائيًا**: **"بعد التسليم توقف وانتظر مراجعة المستخدم."**

### 1) الترحيلات الجديدة (0144–0156)

| # | الترحيلة | تُضيف |
|---|---|---|
| 0144 | `adjustments_zero_charge_and_payment_reference_schema.sql` | عمود `payment_reference` جديد؛ `payment_method_id`/`collection_channel_id` تصبحان قابلتين للـNULL (خدمة مجانية)؛ قيد `sales_order_adjustments_zero_charge_consistent` الجديد؛ backfill يُصحِّح بيانات معتمَدة قديمة بقيمة تحصيل صفرية بُنيت تحت الافتراض الخاطئ التاريخي. **عُدِّلت في هذه الجلسة** (ترتيب backfill/إسقاط القيد — انظر §2 من `TEST_RESULTS_PATCH_6_1.md`). |
| 0145 | `set_pending_sales_order_adjustment_direct_cost.sql` | `set_pending_sales_order_adjustment_direct_cost()` — المسار الوحيد المُصرَّح به لتعيين/تصحيح `direct_cost` لسجل معلَّق، مقيَّد بـ`adjustments.manage_cost` وحدها. |
| 0146 | `create_sales_order_adjustment_v2.sql` | `create_sales_order_adjustment()` v2 — `p_direct_cost is not null` يتطلب الآن `adjustments.manage_cost`؛ `p_payment_method_id`/`p_collection_channel_id` اختياريان؛ معامل `p_payment_reference` جديد. |
| 0147 | `update_sales_order_adjustment_v2.sql` | `update_sales_order_adjustment()` v2 — **إسقاط `p_direct_cost` كليًا** (لا مجرد جعله اختياريًا) — المسار الوحيد لتصحيح التكلفة أصبح 0145 حصرًا. |
| 0148 | `approve_sales_order_adjustment_v2.sql` | إعادة `table(id, adjustment_number, row_version, status, net_adjustment_profit)` — `net_adjustment_profit` يعود `null` صراحةً بلا `sales.view_profit`؛ `direct_cost is null` يبقى رافضًا للاعتماد دون قيد أو شرط حتى لخدمة مجانية. |
| 0149 | `reject_sales_order_adjustment_v2.sql` | تحديثات ثانوية متوافقة مع بقية v2. |
| 0150 | `adjustment_reversal_impact_columns.sql` | 5 أعمدة مُوقَّعة جديدة NOT NULL على `sales_order_adjustment_reversals` (`customer_charge_reversal_amount`/`direct_cost_reversal_amount`/`payment_fee_reversal_amount`/`gross_profit_reversal_amount`/`net_profit_reversal_amount`) — أثر رقمي كامل للعكس، غير مُعاد عبر `reverse_sales_order_adjustment()` نفسها، يُقرَأ فقط مباشرة (service_role) أو لاحقًا عند الحاجة. **عُدِّلت في هذه الجلسة** (محفِّز يحجب backfill — انظر §2). |
| 0151 | `adjustment_read_rpcs_v2.sql` | إعادة بناء كاملة لِـ`get_sales_order_adjustment()`/`list_sales_order_adjustments()` — إزالة الحقول المسطَّحة القديمة، استبدالها بانقسام `original_*` (لقطة الاعتماد الثابتة)/`effective_*` (0.00 بعد العكس، NULL أثناء الانتظار/الرفض)، `has_direct_cost` مرئي دومًا، فلاتر جديدة (`p_original_sale_store_id`/`p_payment_method_id`/`p_collection_channel_id`/`p_participates_in_settlement`). |
| 0152 | `adjustments_narrow_edit_getter_and_filter_lookups.sql` | `get_pending_sales_order_adjustment_for_edit()` — مقيَّدة بـ`adjustments.create` وحدها (لا `adjustments.view` إطلاقًا)، تُغلِق فجوة الصلاحية المخفية؛ 3 دوال بحث فلترة جديدة مقيَّدة بـ`adjustments.view` وحدها (كتالوج كامل شاملًا المُعطَّل، لصفحة القائمة، مغايرة لِـ"active-only" الخاصة بنموذج الإنشاء). |
| 0153 | `adjustment_types_locking_and_immutability_triggers.sql` | تشديد أقفال/محفِّزات Master Data للأنواع. |
| 0154 | `sales_order_adjustments_immutability_triggers.sql` | محفِّز عدم-قابلية-تعديل نهائي: `direct_cost` (وحقول أخرى حسّاسة) على سجل **معتمَد** أصبحت غير قابلة للتغيير حتى عبر كتابة مباشرة تتجاوز RLS (service_role) — المحفِّزات لا تتجاوزها `BYPASSRLS` أبدًا، خلافًا للسياسات. |
| 0155 | `preview_sales_order_adjustment_v2.sql` | `p_payment_method_id` يصبح اختياريًا — معاينة خدمة مجانية لا تحتاج طريقة دفع، الرسم يُحسَم لـ0.00 دون قيد وشرط. |
| 0156 | `audit_logs_adjustment_cost_set_protection.sql` | توسيع تدقيق دقيق الحبيبات ليشمل الفعل الجديد `adjustment.set_direct_cost` تحت نفس شرط `sales.view_profit`. |

### 2) الصلاحيات — لا صلاحية جديدة، إعادة توزيع دقيق فقط

Patch 6.1 **لا تضيف** أي صلاحية `adjustments.*` جديدة (مؤكَّد آليًا — §5 بند (g) في `TEST_RESULTS_PATCH_6_1.md`، **7 بالضبط** كما كانت). بل تُعيد توزيع صلاحية `adjustments.manage_cost` القائمة على مسار أضيق ومُخصَّص (0145) بدل تضمينها ضمنيًا في مسارَي الإنشاء/التعديل العامَّين — فصل أوضح بين "من يُنشئ السجل" و"من يملك التكلفة المباشرة".

### 3) قرارات تصميم/أمن أساسية — عشرة توضيحات مختصرة (§38 من المواصفة)

1. **لماذا فصل `direct_cost` عن الإنشاء/التعديل إلى RPC مخصَّص (0145) بدل إبقائه معاملًا اختياريًا؟** لأن معامِلًا اختياريًا على مسار عام (`create`/`update`) يجعل التحقق من الصلاحية عرضة للنسيان عند أي تعديل مستقبلي على تلك الدالتين — RPC مخصَّص بغرض واحد (تعيين التكلفة) لا يمكن استدعاؤه أصلًا دون أن يمرّ عبر تحقق `adjustments.manage_cost` الصريح بداخله، مطابقةً لنمط "أضيق نطاق ممكن" المتَّبع في كل الوحدات السابقة.
2. **لماذا `update_sales_order_adjustment()` تُسقِط `p_direct_cost` كليًا لا تجعله اختياريًا فقط؟** جعله اختياريًا فقط كان سيبقي الباب مفتوحًا لاستدعاء يمرِّره ضمنًا (كما حدث فعليًا تاريخيًا)، فيتطلب تحققًا مزدوجًا مكرَّرًا في مكانين. إسقاطه من التوقيع نفسه يجعل "من الصياغة" (structurally) مستحيلًا تمريره عبر هذا المسار — لا حاجة لثقة في انضباط كل استدعاء مستقبلي.
3. **لماذا خدمة مجانية (`customer_charge=0`) تمنع طريقة الدفع/القناة/المرجع صراحةً بدل تركها اختيارية بصمت؟** لأن "اختيارية بصمت" تسمح بحالة متناقضة منطقيًا (رسم صفري لكن طريقة دفع مسجَّلة) تُربِك أي تقرير تسوية لاحق — القيد (`sales_order_adjustments_zero_charge_consistent`) يفرض التناسق عند مصدر الحقيقة (القاعدة)، لا فقط في واجهة العميل التي يمكن تجاوزها.
4. **لماذا الاعتماد يرفض `direct_cost is null` حتى لخدمة مجانية بربح صفري بديهي؟** لأن "بديهي" ليس ضمانًا — فرض إدخال تكلفة صريحة (ولو 0.00) حتى للخدمة المجانية يمنع اعتماد سجل لم يُراجَع ماليًا إطلاقًا بذريعة أن نتيجته "واضحة"، ويحافظ على قاعدة واحدة بلا استثناءات: **لا اعتماد بلا تكلفة مباشرة مُدخَلة صراحة، دومًا**.
5. **لماذا انقسام `original_*`/`effective_*` بدل حقول مسطَّحة واحدة؟** لأن حقلًا مسطَّحًا واحدًا لا يستطيع التمييز بين "ماذا حدث فعليًا وقت الاعتماد" (يجب أن يبقى ثابتًا للأبد، حتى بعد العكس) و"ما الأثر المالي الحالي الآن" (يصبح 0.00 بعد العكس) — الفصل الصريح يمنع أي كود عرض من الخلط بين اللقطة التاريخية والحالة الحيّة سهوًا.
6. **لماذا `get_pending_sales_order_adjustment_for_edit()` مقيَّدة بـ`adjustments.create` وحدها، لا `adjustments.view`؟** لإغلاق فجوة تبعية-صلاحية-مخفية حقيقية: فاعل يملك `adjustments.create` فقط (بلا `adjustments.view`) كان يستطيع إنشاء سجل، ثم يُرفَض عند محاولة فتحه للتعديل بعد الإنشاء مباشرة — وهي دالة **ضيقة بالتصميم** (معلَّق فقط)، فربطها بصلاحية الإنشاء (لا العرض العام) متسق مع من يُفترَض أن يستخدمها فعليًا.
7. **لماذا محفِّز عدم-قابلية-تعديل (0154) بدل الاكتفاء بسياسة RLS من الطبقة-A القائمة؟** لأن `BYPASSRLS` (service_role) يتجاوز **السياسات** لكن لا يتجاوز **المحفِّزات** أبدًا — سياسة RLS وحدها لا تحمي من كتابة مباشرة موثوقة (صيانة/سكربت داخلي) بالخطأ؛ المحفِّز يفرض عدم-القابلية-للتعديل حتى ضد أعلى مستوى ثقة ممكن في القاعدة.
8. **لماذا دوال بحث الفلترة الجديدة (0152) مقيَّدة بـ`adjustments.view` وحدها، منفصلة عن دوال الإنشاء النشِطة-فقط؟** لأن صفحة القائمة (`/adjustments`) تتطلب `adjustments.view` فقط، لكن دوال البحث القديمة كانت تتطلب `adjustments.create` ضمنيًا (مُخفاة خلف `.catch(() => [])` في الواجهة) — ما يُفقِر فلاتر فاعل-عرض-فقط بصمت دون أي رسالة خطأ واضحة؛ الفصل يزيل هذا الاعتماد الخفي، ويُعيد الكتالوج الكامل (شاملًا المُعطَّل) وهو الأنسب لفلتر تاريخي لا لمُنشِئ نشِط.
9. **لماذا عزل المتجر يشمل متجر عملية البيع الأصلية، لا فقط المتجر المُعالِج؟** لأن التعديل/الخدمة يرتبط بعملية بيع قد تكون سُجِّلت في متجر مختلف عن المتجر الذي يُعالِج فيه التعديل حاليًا — الاكتفاء بفحص المتجر المُعالِج وحده كان يفتح ثغرة تجاوز-نطاق حقيقية (فاعل مُقيَّد بمتجر B يستطيع رؤية/رفض تعديل مرتبط بمتجر A طالما عولج ظاهريًا في متجر يراه)؛ الإصلاح يتطلب رؤية **كلا** المتجرين معًا.
10. **لماذا أعمدة الأثر الرقمي الخمسة للعكس (0150) مُوقَّعة ومُخزَّنة صراحة بدل الاكتفاء بإعادة حساب اللقطة الأصلية سالبة عند الحاجة؟** لأن "إعادة الحساب عند الحاجة" تفترض أن منطق الحساب لن يتغير أبدًا مستقبلًا — تخزين الأثر الموقَّع وقت العكس فعليًا (لا اشتقاقه لاحقًا) يجعله سجلًا تاريخيًا ثابتًا بمعزل عن أي تطوير لاحق لصيغة الحساب، مطابقًا لفلسفة كل لقطة أخرى في هذا النظام (سعر الذهب، أجرة التصنيع، رسم الدفع) — لا يُشتق شيء مالي تاريخي من كود حيّ قابل للتغيير.

### 4) الاختبارات — قائمة كاملة وأرقام فعلية (نُفِّذت في هذه الجلسة)

تفصيل كامل بالأرقام في `TEST_RESULTS_PATCH_6_1.md`. ملخَّص:

- إعادة بناء قاعدة اختبار Postgres محلية **من الصفر بالكامل**، عدة مرات مستقلة: `local_harness_setup.sql`، **كل الترحيلات 0001–0156 بالترتيب دون توقف** (156/156)، ثم `supabase/seed.sql`.
- **20/20 ملف اختبار SQL غير-ترقية** (16 قائم + `adjustments_core_phase6.test.sql` + 4 ملفات تزامن حقيقي `dblink` شاملة `adjustments_core_phase6_concurrency.test.sql`) → **نجحت جميعًا، صفر انحدار حقيقي** (فشل ظاهري واحد اصطناعي بحت من منهجية سكربت مؤقت — مُفسَّر بالكامل في `TEST_RESULTS_PATCH_6_1.md` §6).
- **5/5 مسارات ترقية** (3 قديمة غير مرتبطة بـAdjustments + `run_upgrade_test_phase6_adjustments.sh` القائم + `run_upgrade_test_patch_6_1.sh`/`upgrade_patch_6_1_fixtures.test.sql` **الجديدان بالكامل** — يُثبتان أن 0144–latest تعمل بأمان فوق بيانات Adjustments حقيقية أُنشئت تحت عقود RPC القديمة 0133–0143، لا فوق جداول فارغة فقط) → **نجحت جميعًا**، وكشف مسار الترقية الجديد **عيبين حقيقيين** في الترحيلتين 0144/0150 (أُصلِحا فورًا — تفصيل كامل في `TEST_RESULTS_PATCH_6_1.md` §2).
- اختبار HTTP/PostgREST الحقيقي (`scripts/run_postgrest_http_test.sh`، ثنائي PostgREST v12.2.3 حقيقي، 6 JWT حقيقية) → **نجح بالكامل، 174 تأكيدًا "OK"، صفر فشل**، شاملًا قسم "Part 12" الجديد بالكامل (14 بندًا) وإصلاح قسم "Part 11" القائم من انحدار حقيقي سبَّبته تغييرات هذه الجلسة (5 تأكيدات، أحدها كان يُسقِط السكربت بالكامل).
- عيب صياغي حقيقي (`*/` داخل تعليق JSDoc) كان يمنع بناء الواجهة الأمامية بالكامل — اكتُشِف عبر `npm run typecheck` وأُصلِح فورًا.
- `DATABASE_URL=... npx tsx scripts/check-numeric-column-types.ts` → **نجح، 73/73 عمود NUMERIC مطابق** (يشمل 5 أعمدة عكس جديدة).
- `npx tsc --noEmit` → **صفر أخطاء**. `npx eslint .` → **صفر أخطاء وتحذيرات**.
- `npx vitest run` → **115/115 ناجح عبر 13 ملفًا** (15 اختبارًا جديدًا لِـPatch 6.1 + تحديث ملفَي Vitest القائمَين لمطابقة أشكال RPC v2).
- `npm run build` (Next.js/Turbopack) → **نجح**، نفس مسارات Adjustments الخمسة القائمة (Patch 6.1 يُعيد كتابة الواجهات القائمة، لا يضيف صفحات جديدة).

### 5) الملفات/الترحيلات التي تغيَّرت أو أُضيفت في Patch 6.1 (قائمة كاملة)

**ترحيلات جديدة (13):** `0144_adjustments_zero_charge_and_payment_reference_schema.sql` … `0156_audit_logs_adjustment_cost_set_protection.sql` (القائمة الكاملة في §1 أعلاه).

**اختبارات SQL جديدة بالكامل:** `supabase/tests/upgrade_patch_6_1_fixtures.test.sql`، `supabase/tests/fixtures/patch_6_1_upgrade_pre_fixture.sql`.

**سكربتات جديدة:** `scripts/run_upgrade_test_patch_6_1.sh`.

**سكربتات/إعداد HTTP مُعدَّلان (إضافة + إصلاح، لا حذف):** `scripts/postgrest-http-test.mjs` (إصلاح "Part 11" من انحدار حقيقي + قسم "Part 12" الجديد بالكامل + إزالة ثابت غير مُستخدَم)، `scripts/run_postgrest_http_test.sh` (توقيع JWT لفاعلَين جديدَين)، `supabase/tests/postgrest_http_test_setup.sql` (متجر ثانٍ + 3 فاعلين جديدين/مُوسَّعين).

**كود TypeScript مُعدَّل بالكامل (إعادة كتابة تطابق v2):** `src/features/adjustments/{schema,queries,actions}.ts`، `src/features/adjustments/components/{adjustment-entry-form,adjustment-lifecycle-actions}.tsx`، `src/app/(app)/adjustments/page.tsx`، `src/app/(app)/adjustments/[id]/page.tsx`، `src/app/(app)/adjustments/[id]/edit/page.tsx`، `src/app/(app)/adjustments/new/page.tsx`، `src/features/adjustments/components/adjustments-filters.tsx`، `src/types/database.ts` (كتلة Functions/Tables الخاصة بـAdjustments بالكامل).

**اختبارات Vitest جديدة بالكامل:** `tests/adjustments-zero-charge-schema.test.ts`.

**اختبارات Vitest مُعدَّلة (مطابقة أشكال RPC v2، بلا تغيير في الغرض):** `tests/adjustments-actions-permission-boundary.test.ts` (+4 اختبارات جديدة)، `tests/adjustments-view-only-ui.test.tsx` (تحديث الـmocks/الحقول لِـv2).

**لم يتغيّر إطلاقًا:** أي ترحيل من 0001–0143، أي صفحة/مكوّن خارج Adjustments، أي وحدة أخرى (Sales/Returns/Shipping/Users/Stores/Master Data غير Adjustments).

**خلاصة الملحق السادس والعشرون:** تصحيح أمني/مالي شامل فوق Services/Adjustments Core يُغلِق ثغرة تسريب صلاحية حقيقية (`direct_cost` بلا `adjustments.manage_cost`)، يفرض تناسق الخدمة المجانية على مستوى القاعدة لا الواجهة فقط، يفصل اللقطة التاريخية الثابتة عن الأثر المالي الحيّ (`original_*`/`effective_*`)، يُغلِق فجوة تبعية-صلاحية-مخفية وثغرة تجاوز-نطاق-متجر حقيقيتين، يضيف محفِّز عدم-قابلية-تعديل يصمد حتى أمام service_role، ويحتفظ بسجل أثر رقمي كامل للعكس. **13 ترحيلة جديدة (0144–0156) + 20/20 ملف اختبار SQL غير-ترقية + 5/5 مسارات ترقية (شاملة مسار Patch 6.1 الجديد فوق بيانات Adjustments حقيقية قبل الترقية، الذي كشف بنفسه عيبين حقيقيين في الترحيلتين 0144/0150 وأُصلِحا) + 174 تأكيد HTTP حقيقي (شاملًا إصلاح انحدار حقيقي في "Part 11" القائم) + 115 اختبار Vitest + 73/73 عمود NUMERIC + بناء إنتاجي ناجح — كلها من تشغيلات فعلية في هذه الجلسة. أربعة عيوب حقيقية في كود التسليم نفسه اكتُشِفت وأُصلِحت أثناء هذه الجلسة بالذات (تفصيل كامل في `TEST_RESULTS_PATCH_6_1.md` §10) — كلها قبل أي تسليم فعلي، بلا حاجة لترحيلة تصحيحية منفصلة لاحقة. لم تُعدَّل أي ترحيلة من 0001–0143. لم تبدأ Settlements ولا أي مرحلة جديدة. العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP كامل للمشروع.**

## الملحق السابع والعشرون — "Phase 6 Final Integrity Hotfix 6.1.1: إصلاحات المراجعة النهائية لـServices/Adjustments" (ترحيلات 0157–0162 + تعديل مسموح على 0144)

هذا الملحق يوثِّق **Hotfix 6.1.1** كاملة — تصحيح نهائي مبني على مراجعة مستخدم مستقلة لِـPatch 6.1 على مستوى المصدر الفعلي والـdiff (لا تقارير الاختبار فقط)، أكَّدت أن الـArtifact السابق (SHA-256 `54f2ac8dee4f7f9484e7f3a3d51ec1c312c938b202bdc1171c0bad0a20d2bbdb`) صحيح وكامل، لكن حدَّدت مجموعة محدودة من 18 بندًا قبل إغلاق Phase 6 نهائيًا. **قاعدة التجميد تغيَّرت في هذه الجولة تحديدًا عن كل جولة سابقة**: 0001–0143 لا تزال نهائية ومجمَّدة (لم تُعدَّل — مؤكَّد byte-for-byte في §9 أدناه)، لكن **0144 وحدها** — من بين 0144–0156 التي لا تزال قيد المراجعة ولم تُعتمَد بعد — سُمِح بتعديلها **حصرًا** لإصلاح Upgrade Blocker حقيقي يقع داخل 0144 نفسها (تفصيل كامل §0)، بينما 0145–0156 بقيت بلا أي تعديل، وكل عمل جديد (تحسينات القراءة/المخطط) بدأ حصرًا من **0157**. لا Settlements، لا Reports/Dashboard/Inventory، لا أي مرحلة جديدة. العمل **متوقف الآن نهائيًا**: **"توقف بعد التسليم وانتظر المراجعة."**

### 0) لماذا عُدِّلت 0144 رغم تجميد 0001–0143 — بيان صريح إلزامي

قبل 0144، سجل **مرفوض** بقيمة تحصيل صفرية كان يمكن أن يحمل شرعيًا `payment_method_id`/`collection_channel_id` غير NULL تحت العقد القديم (0133–0143) — الـbackfill الأصلي في 0144 طبَّع فقط معلَّق/معتمَد بقيمة صفرية، متجاهلًا المرفوض تمامًا، ثم أضاف قيد `sales_order_adjustments_zero_charge_consistent` الذي يفرض NULL لحقول الدفع على **أي** سجل بقيمة تحصيل صفرية بصرف النظر عن حالته. قاعدة بيانات إنتاجية حقيقية تحمل سجلًا كهذا كانت ستفشل تطبيق **0144 نفسها** — قبل الوصول إطلاقًا إلى أي ترحيلة 0157+. **لا يمكن إصلاح هذا لاحقًا لأن العطل يقع أثناء 0144 ذاتها، لا بعدها** — لذلك، وفقط لهذا السبب، عُدِّلت 0144. التفصيل الكامل في `TEST_RESULTS_HOTFIX_6_1_1.md` §0.

### 1) الترحيلات الجديدة (0157–0162) + التعديل المسموح على 0144

| # | الترحيلة/التعديل | يُضيف |
|---|---|---|
| 0144 (مُعدَّلة، مسموح) | `adjustments_zero_charge_and_payment_reference_schema.sql` | كتلة backfill جديدة تُطبِّع أيضًا السجلات **المرفوضة** بقيمة تحصيل صفرية (لا معلَّق/معتمَد فقط كما كانت)، دون اختلاق أي لقطة مالية ودون مساس ببيانات الرفض التاريخية. |
| 0157 | `list_sales_order_adjustments_v3_financial_columns.sql` | `effective_direct_cost`/`effective_payment_fee_amount`/`effective_gross_adjustment_profit` جديدة على `list_sales_order_adjustments()` — نفس دلالات `effective_*` القائمة في `get_sales_order_adjustment()`، محمية بـ`sales.view_profit`. |
| 0158 | `adjustments_calculation_version_column.sql` | عمود `calculation_version` جديد + backfill (`1` لكل سجل معتمَد قديم) + قيد اتساق (`approved ⇔ not null`). **عُدِّلت مرتين أثناء هذه الجلسة نفسها قبل التسليم** — انظر §2 من `TEST_RESULTS_HOTFIX_6_1_1.md`. |
| 0159 | `approve_sales_order_adjustment_v3_calculation_version.sql` | `approve_sales_order_adjustment()` v3 — يكتب `calculation_version = 1` سلطويًا عند كل اعتماد، المسار الوحيد لكتابة هذا العمود. |
| 0160 | `get_sales_order_adjustment_v4_reversal_impact_and_calc_version.sql` | `get_sales_order_adjustment()` v4 — يعرض `calculation_version` (بيانات تشغيلية، `adjustments.view` وحدها) و5 حقول `reversal_*_impact` مُوقَّعة (محمية بـ`sales.view_profit`، NULL بلا عكس). |
| 0161 | `adjustment_update_audit_payload_expansion.sql` | `update_sales_order_adjustment()` — توسيع حمولة تدقيق `adjustment.update` لتشمل قديم/جديد لكل حقل قابل للتغيير فعليًا (النوع/المتجر/التاريخ/طريقة الدفع/القناة/المرجع/المشاركة/التحصيل/الملاحظات/الإصدار)، لا `customer_charge`/`row_version` فقط كما كانت. |
| 0162 | `adjustment_types_updated_by_hardening.sql` | محفِّز ضيِّق جديد يُثبِّت `adjustment_types.updated_at`/`updated_by` على الفاعل الحقيقي لكل تحديث سليم، دون المساس بحماية 0153 الحالية لـ`code`/`created_at`/`created_by`. |

### 2) الصلاحيات — لا تغيير إطلاقًا

Hotfix 6.1.1 **لا تضيف ولا تُعدِّل** أي صلاحية `adjustments.*`/`sales.*` — كل الإصلاحات منطقية/مخططية بحتة فوق نفس نموذج الصلاحيات القائم من Patch 6.1.

### 3) قرارات تصميم/أمن أساسية — ست توضيحات مختصرة

1. **لماذا عُدِّلت 0144 لا 0157 لإصلاح البند 1؟** لأن العطل يمنع تطبيق 0144 **نفسها** على قاعدة إنتاجية حقيقية — أي إصلاح في 0157+ لن يُصادَف أبدًا إن فشلت 0144 أولًا.
2. **لماذا `calculation_version` عمود `integer` عادي لا `text`؟** لأنه رقم إصدار محرك حساب صغير، لا قيمة مالية بدقة كسرية — اتفاقية "حدود النقل العشري الآمن" (`::text`) خاصة بالقيم المالية فقط، ولا تنطبق هنا.
3. **لماذا `calculation_version` غير محمي بـ`sales.view_profit`؟** لأنه لا يكشف أي مبلغ مالي إطلاقًا — مجرد بيانات تشغيلية عن **أي نسخة** من المحرك حُسِب بها السجل، فتكفي `adjustments.view` وحدها.
4. **لماذا محفِّز ضيِّق منفصل لـ0162 بدل إعادة استخدام `enforce_system_managed_columns()` العام مباشرة على `adjustment_types`؟** لأن الدالة العامة تُثبِّت الأعمدة الأربعة معًا بصمت — وهذا كان سيغيّر سلوك 0153 القائم والصحيح أصلًا لـ`code`/`created_at`/`created_by` (رفض صريح عبر `raise`) إلى تثبيت صامت، وهو تغيير غير مطلوب وغير آمن لسلوك يعمل بشكل صحيح بالفعل.
5. **لماذا الحالة تري-ستيت (`boolean | undefined`) للمشاركة في التسوية، لا مجرد `boolean` بقيمة افتراضية `false`؟** لأن أي قيمة افتراضية صامتة (حتى `false`) تعني أن المستخدم لم يختر شيئًا فعليًا فيصبح الاختيار المُسجَّل تخمينًا للنظام لا قرارًا بشريًا صريحًا — `undefined` يمنع الإرسال أصلًا حتى يُختار صراحةً.
6. **لماذا مسح الحالة عند عبور الحدود مدفوع↔مجاني في الاتجاهين، لا اتجاه واحد فقط؟** لأن الثغرة الأصلية (قيمة قديمة تعود بصمت) يمكن أن تحدث في أي من الاتجاهين — مسح جزئي كان سيترك نصف المشكلة قائمًا.

### 4) الاختبارات — قائمة كاملة وأرقام فعلية (نُفِّذت في هذه الجلسة)

تفصيل كامل بالأرقام في `TEST_RESULTS_HOTFIX_6_1_1.md`. ملخَّص:

- إعادة بناء قاعدة اختبار من الصفر بالكامل: **كل الترحيلات 0001–0162 بالترتيب دون توقف** (162/162)، ثم `supabase/seed.sql`.
- عيبان حقيقيان في 0158 نفسها (ترتيب backfill/قيد + محفِّز 0154 يحجب الـbackfill) اكتُشِفا عبر إعادة تشغيل `run_upgrade_test_patch_6_1.sh` وأُصلِحا فورًا.
- fixture ترقية سادس جديد وإلزامي ("مرفوض/تحصيل صفري تحت العقد القديم") — **11 كتلة PASS** في `upgrade_patch_6_1_fixtures.test.sql` بعد التوسيع، شاملة `(e2)`/`(e2 raw)` الجديدتين.
- **مسارات الترقية الخمسة المطلوبة كاملة (A–E)** — قاعدة جديدة، 0132→latest، 0143→latest بالـfixtures القائمة، 0143→latest بالـfixture الجديد، وقاعدة تجمع كل الحالات معًا → **كلها PASS**.
- **25 ملف اختبار SQL غير-ترقية شاملة `adjustments_core_phase6.test.sql` وتزامن حقيقي A–I كامل (9 سيناريوهات + Bonus)** → **PASS بالكامل، صفر انحدار**.
- اختبار HTTP/PostgREST الحقيقي → **185 تأكيدًا "OK"، صفر فشل** (174 قائم + **11 قسم "Part 13" الجديد بالكامل** يغطي البنود 4/5/6/7/10/13/14). عيب فِكستشر اختباري بحت (لا ترحيلة) اكتُشِف وأُصلِح أثناء كتابة إثبات إعادة التسمية (§6.أ من `TEST_RESULTS_HOTFIX_6_1_1.md`).
- **ملفا Vitest جديدان بالكامل (10 اختبارات) — مكوِّنات React حقيقية، لا Zod فقط**: آلة حالة الخدمة المجانية تري-ستيت (4 اختبارات: A–D)، أعمدة القائمة المالية + بطاقة أثر العكس + ثبات فلتر الترقيم (6 اختبارات).
- `npx tsc --noEmit` → **صفر أخطاء**. `npx eslint .` → **صفر أخطاء/تحذيرات**. `npx vitest run` → **125/125 عبر 15 ملفًا**.
- `DATABASE_URL=... npx tsx scripts/check-numeric-column-types.ts` → **73/73 عمود NUMERIC مطابق**.
- `npm run build` → **نجح** بعد إصلاح عيبين نوعيَّين صغيرين اكتشفهما فحص TypeScript الخاص بالبناء نفسه في ملفَي Vitest الجديدَين (لا علاقة لهما بأي منطق أعمال).

### 5) الملفات/الترحيلات التي تغيَّرت أو أُضيفت في Hotfix 6.1.1 (قائمة كاملة)

**تعديل مسموح واحد على ترحيلة مُجمَّدة سابقًا:** `supabase/migrations/0144_adjustments_zero_charge_and_payment_reference_schema.sql` (السبب موثَّق حصرًا في §0 أعلاه).

**ترحيلات جديدة (6):** `0157_list_sales_order_adjustments_v3_financial_columns.sql`، `0158_adjustments_calculation_version_column.sql`، `0159_approve_sales_order_adjustment_v3_calculation_version.sql`، `0160_get_sales_order_adjustment_v4_reversal_impact_and_calc_version.sql`، `0161_adjustment_update_audit_payload_expansion.sql`، `0162_adjustment_types_updated_by_hardening.sql`.

**اختبارات SQL مُوسَّعة (إضافة فقط، لا حذف):** `supabase/tests/fixtures/patch_6_1_upgrade_pre_fixture.sql` (fixture سادس)، `supabase/tests/upgrade_patch_6_1_fixtures.test.sql` (قسمَا `(e2)`/`(e2 raw)` + تحديث عدَّاد `(f)`).

**سكربتات/إعداد HTTP مُعدَّلان (إضافة فقط):** `scripts/postgrest-http-test.mjs` (قسم "Part 13" الجديد بالكامل، 11 تأكيدًا)، `supabase/tests/postgrest_http_test_setup.sql` (صف فاعل بديل `service_role` تجريبي بحت، §6.أ من `TEST_RESULTS_HOTFIX_6_1_1.md`).

**كود TypeScript مُعدَّل:** `src/features/adjustments/components/adjustment-entry-form.tsx` (البندان 3/4)، `src/app/(app)/adjustments/page.tsx` (البندان 5/10)، `src/app/(app)/adjustments/[id]/page.tsx` (البند 6 + عرض اختياري لِـ`calculation_version`)، `src/features/adjustments/queries.ts` (تحديث تعليقات + لا تغيير منطقي — الأنواع الجديدة تمر عبر النوع المُحدَّث فقط)، `src/types/database.ts` (توسيع `Returns` لِـ`list_sales_order_adjustments`/`get_sales_order_adjustment`).

**اختبارات Vitest جديدة بالكامل (2 ملف، 10 اختبارات):** `tests/adjustments-entry-form-zero-charge-state-machine.test.tsx`، `tests/adjustments-hotfix-6-1-1-list-reversal-pagination.test.tsx`.

**لم يتغيّر إطلاقًا:** أي ترحيلة من 0001–0143 (مؤكَّد byte-for-byte، §9 أدناه)، أي ترحيلة من 0145–0156 (مؤكَّد byte-for-byte أيضًا)، أي صفحة/مكوّن خارج Adjustments، أي وحدة أخرى (Sales/Returns/Shipping/Users/Stores/Master Data غير Adjustments)، ولا حُذِف أو أُضعِف أي اختبار قائم.

### 6) البنود 5/6/7 — كيف تصل هذه التحسينات فعليًا للواجهة

- **البند 5:** `/adjustments` يعرض الآن التكلفة المباشرة وعمولة الدفع إلى جانب صافي الربح القائم مسبقًا، الثلاثة معًا محمية بنفس بوابة `sales.view_profit`.
- **البند 6:** صفحة تفاصيل تعديل معكوس تعرض بطاقة "أثر العكس المالي" صريحة (صافي الربح الأصلي / أثر العكس عليه / صافي الربح الفعلي بعد العكس = 0.00، إلى جانب التكلفة المباشرة/عمولة الدفع/الربح الإجمالي بنفس الصيغة) — لا يُترَك المستخدم ليستنتج الحساب من كون الأثر الفعلي أصبح صفرًا فقط.
- **البند 7:** `calculation_version` يُعرَض كبيانات تشغيلية اختيارية في صفحة التفاصيل (وسم تقني بسيط)، ومحفوظ في القاعدة دومًا للتقارير/التدقيق المستقبلي.

**خلاصة الملحق السابع والعشرون:** إصلاح مراجعة نهائي دقيق ومحدود النطاق فوق Services/Adjustments Core — يُغلِق Upgrade Blocker حقيقي داخل 0144 نفسها (السبب الوحيد المُبرِّر لتعديل ترحيلة "مُجمَّدة" سابقًا)، يُكمِل تناسق الخدمة المجانية على مستوى الترقية للحالة المرفوضة، يُصلِح ثغرة حالة قديمة (stale state) حقيقية في نموذج React، يفرض اختيارًا صريحًا (لا افتراضيًا صامتًا) للمشاركة في التسوية، يُكمِل الأعمدة المالية الناقصة في القائمة وقسم أثر العكس في التفاصيل، يضيف `calculation_version` (متطلَّب Phase 6 الأصلي المنسي)، يوسِّع حمولة التدقيق لتغطي كل حقل قابل للتغيير فعليًا، ويشدِّد `updated_by` لأنواع التعديلات. **6 ترحيلات جديدة (0157–0162) + تعديل مسموح واحد على 0144 (مُبرَّر بالكامل في §0) + مسارات الترقية الخمسة المطلوبة كاملة (شاملة fixture سادس جديد كشف بنفسه عيبين حقيقيين في 0158 وأُصلِحا) + 25 ملف اختبار SQL غير-ترقية شاملة تزامن A–I الحقيقي + 185 تأكيد HTTP حقيقي (174 قائم + 11 قسم "Part 13" جديد) + 125 اختبار Vitest (10 جديدة، مكوِّنات React حقيقية لا Zod فقط) + 73/73 عمود NUMERIC + بناء إنتاجي ناجح — كلها من تشغيلات فعلية في هذه الجلسة. لم تُعدَّل أي ترحيلة من 0001–0143 (مؤكَّد byte-for-byte مقابل الأرشيف المُعتمَد سابقًا SHA-256 `54f2ac...2bbdb`)، ولا أي ترحيلة من 0145–0156. لم تبدأ Settlements ولا أي مرحلة جديدة. لم يُحذَف ولم يُضعَف أي اختبار قائم. العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP كامل للمشروع.**

---

## الملحق الثامن والعشرون — "Phase 6 Final Audit & Invariant Hotfix 6.1.2: إغلاق الفجوات المصدرية الأخيرة لـServices/Adjustments" (ترحيلات 0163–0166)

هذا الملحق يوثِّق **Hotfix 6.1.2** كاملة — تصحيح إغلاق نهائي مبني على مراجعة مستخدم مستقلة لِـHotfix 6.1.1 على مستوى المصدر الفعلي والـdiff، أكَّدت أن الـArtifact السابق (`gold-erp-hotfix-6-1-1.zip`، SHA-256 `36bb8407dabbd5dbffea7e54b71cb30da3bc32aea48416a6aa4323fd39d4a007`) صحيح وكامل، لكن حدَّدت **ثلاث فجوات مصدرية BLOCKER حقيقية + فجوة اختبارية صغيرة** قبل إغلاق Phase 6 نهائيًا. **قاعدة التجميد هذه الجولة أصرم من كل جولة سابقة**: لا استثناء إطلاقًا — 0001–0162 مُجمَّدة بالكامل بلا أي تعديل (حتى 0144، التي حظيت باستثناء صريح لمرة واحدة في Hotfix 6.1.1، لا يمتد استثناؤها لهذه الجولة). كل إصلاح جديد بدأ حصرًا من **0163**. لا Settlements، لا Reports/Dashboard/Inventory، لا أي مرحلة جديدة. العمل **متوقف الآن نهائيًا**: **"توقف بعد التسليم وانتظر المراجعة."**

### 1) الترحيلات الجديدة (0163–0166)

| # | الترحيلة | تُصلِح |
|---|---|---|
| 0163 | `adjustments_calculation_version_strict_invariant.sql` | يستبدل قيد `sales_order_adjustments_calculation_version_consistent` (الذي كان يتحقَّق فقط من "معتمَد ⇔ ليس NULL") بالعقد الحرفي الدقيق: معتمَد ⇒ `calculation_version = 1` **بالضبط**؛ غير معتمَد ⇒ NULL. لا قيمة أخرى (2، 99، -1...) مقبولة لسجل معتمَد حتى/إلا بترحيلة مستقبلية صريحة تُدخِل عمدًا محرك حساب v2. |
| 0164 | `adjustment_types_updated_by_anti_forgery.sql` | يستبدل جسم `adjustment_types_enforce_updated_columns()` (`CREATE OR REPLACE`، نفس الاسم، فيلتقط المحفِّز القائم من 0162 الجسم الجديد تلقائيًا دون إعادة إنشاء المحفِّز نفسه): سياق مُصادَق حقيقي (`auth.uid()` يطابق صف `profiles` فعليًا) ⇒ `updated_by` = الفاعل الحقيقي؛ أي سياق آخر (`auth.uid()` فارغ **أو** لا يطابق أي صف profiles حقيقي — service_role/صيانة مباشرة/جلسة مستخدم محذوف) ⇒ `updated_by` يُثبَّت إلزاميًا على `OLD.updated_by`، بصرف النظر تمامًا عمَّا زوَّده أمر التحديث نفسه. عقد أصرم بشكل جوهري من عقد 0162 الأصلي (الذي كان يترك القيمة المزوَّدة كما هي متى ما كان `auth.uid()` فارغًا). |
| 0165 | `approve_sales_order_adjustment_v4_approval_audit_snapshot.sql` | `CREATE OR REPLACE` بنفس التوقيع الثلاثي المعاملات وبنفس السلوك التشغيلي **طبق الأصل** لِـ0159 — كل تحقُّق/قفل/حساب/UPDATE مطابق حرفيًا؛ التغيير الوحيد هو توسيع `new_values` في نداء `log_audit_event('adjustment.approve', ...)` ليشمل، إلى جانب الحقول الإجمالية القائمة أصلًا: `adjustment_type_id`/`adjustment_type_code_snapshot`/`adjustment_type_name_ar_snapshot`/`adjustment_type_name_en_snapshot`، `payment_method_id`/`payment_method_name_snapshot`، `collection_channel_id`/`collection_channel_name_snapshot`، `payment_fee_version_id`/`payment_fee_percentage_snapshot`/`payment_fee_fixed_snapshot`. كل قيمة هي **نفس** المتغيِّر المحلي المُلتزَم به بالفعل في نفس الصفقة ضمن الـUPDATE أعلاه — لا إعادة حل (`re-resolve`) لأي قيمة خصيصًا للتدقيق. لخدمة مجانية، تبقى كل الحقول المتعلقة بالدفع NULL تلقائيًا (نفس القيم null الموجودة أصلًا في فرع `v_is_free`)، بلا أي منطق إضافي. حماية القراءة القائمة بـ`sales.view_profit` (0143/0156) لم تتغيَّر إطلاقًا. |
| 0166 | `update_adjustment_type_audit_description.sql` | `CREATE OR REPLACE` بنفس التوقيع وبنفس السلوك التشغيلي لِـ`update_adjustment_type()` (0136) — التغيير الوحيد: `description` قديم/جديد يُضافان الآن إلى حمولة تدقيق `adjustment_type.update`، جنبًا إلى جنب مع `name_ar`/`name_en`/`sort_order` القائمة أصلًا (كانت `description` تُعدَّل فعليًا في الجدول لكنها كانت مفقودة بصمت من سجل التدقيق). لا حدث تدقيق جديد. |

### 2) الصلاحيات — لا تغيير إطلاقًا

Hotfix 6.1.2 **لا تضيف ولا تُعدِّل** أي صلاحية `adjustments.*`/`sales.*`/غيرها — كل الإصلاحات منطقية/قيدية/تدقيقية بحتة فوق نفس نموذج الصلاحيات القائم.

### 3) قرارات تصميم/أمن أساسية — أربع توضيحات مختصرة

1. **لماذا `CREATE OR REPLACE` لا `DROP` صريح لأي من الدوال الأربع الجديدة؟** لأن كل تعديلات هذه الجولة تغيِّر منطقًا/جسم قيد داخليًا فقط، دون أي تغيير في قائمة المعاملات أو شكل القيمة المُعادة — بخلاف حالات سابقة (مثل 0146) احتاجت `DROP FUNCTION` صريحًا بسبب معامل جديد يُنشئ توقيعًا مختلفًا لولا الإسقاط الصريح أولًا.
2. **لماذا `OLD.updated_by` تحديدًا كقيمة احتياطية في 0164، لا NULL أو رفض الأمر بالكامل؟** لأن سياقًا موثوقًا (service_role/صيانة) يجب أن يبقى قادرًا على تعديل بيانات رئيسية أخرى (name_ar/description/إلخ) بلا عائق — المطلوب فقط منع **تزوير** الإسناد (attribution)، لا منع الكتابة الموثوقة نفسها. `OLD.updated_by` يحافظ على آخر إسناد شرعي معروف بدل اختلاق قيمة جديدة (NULL) لا تعني شيئًا تاريخيًا.
3. **لماذا فحص `exists (select 1 from public.profiles where id = auth.uid())` صريحًا، لا الاكتفاء بـ`auth.uid() is not null`؟** لأن `auth.uid()` غير NULL لا يعني بالضرورة فاعلًا حقيقيًا قائمًا الآن (حساب مستخدم محذوف، أو رمز JWT قديم/مُزوَّر في سياق اختباري) — الفحص الإضافي هو بالضبط ما يمنع تلك الفجوة الدقيقة، وهو الفارق الجوهري بين العقد القديم ("auth.uid() فارغ فقط") والعقد الجديد ("auth.uid() لا يمثِّل Actor Profile صالحًا").
4. **لماذا لا Test-only profile workaround لاختبار البند 3، كما طلب المستخدم صراحةً؟** لأن أي حيلة بيئة/فِكستشر تجعل محاولة تزوير تبدو ناجحة (أو تُخفي فشلها) كانت ستُخفي عن المستخدم ما إذا كان الإصلاح **الحقيقي** يعمل فعلًا — الاختبار المُسلَّم يمرّ عبر جسم المحفِّز الحقيقي حرفيًا، وأُثبِت إضافيًا بسيطرة سلبية حقيقية (إعادة تركيب الجسم القديم مؤقتًا في قاعدة منفصلة وإثبات أن التزوير كان لينجح تحته) — تفصيل كامل في `TEST_RESULTS_HOTFIX_6_1_2.md` §3.

### 4) الاختبارات — قائمة كاملة وأرقام فعلية (نُفِّذت في هذه الجلسة)

تفصيل كامل بالأرقام في `TEST_RESULTS_HOTFIX_6_1_2.md`. ملخَّص:

- إعادة بناء قاعدة اختبار من الصفر بالكامل: **كل الترحيلات 0001–0166 بالترتيب دون توقف** (166/166)، ثم `supabase/seed.sql`.
- **مسارا الترقية المطلوبان (0132→latest، 0143→latest بكل الفِكستشرات الستة)** → **كلاهما PASS**، بلا أي انحدار في أي فِكستشر قائم سابقًا.
- ملف اختبار SQL جديد بالكامل `supabase/tests/adjustments_hotfix_6_1_2.test.sql` — **11/11 كتلة PASS** تغطي: 4 حالات `calculation_version` الصارمة (البند 2) + إعادة تأكيد صريحة، حالتا مقاومة تزوير `updated_by` المطلوبتان + حالة تعزيزية (البند 3، **مُثبَتة بسيطرة سلبية حقيقية ضد الجسم القديم غير المُصحَّح**)، إثبات SQL مستقل لإشارة عمولة العكس الموجبة (البند 6)، واللقطة الكاملة لتدقيق الاعتماد + ثبات اللقطة القديمة بعد إعادة تسمية النوع/طريقة الدفع/القناة (البندان 4/7).
- **17 ملف اختبار SQL غير-ترقية/غير-تزامن (شاملًا الملف الجديد أعلاه)** → **17/17 PASS**.
- **4 ملفات تزامن حقيقي (`dblink`)، شاملة `adjustments_core_phase6_concurrency.test.sql` بسيناريوهاتها A–I الكاملة** → **4/4 PASS، صفر انحدار**.
- اختبار HTTP/PostgREST الحقيقي الكامل → **كل تأكيدات Part 1–13 القائمة سابقًا (185 تأكيدًا) نجحت دون أي انحدار**. لم تُضَف كتلة "Part 14" منفصلة لهذه الجولة — البنود الأربعة الجديدة قيود/محفِّزات/حمولات-تدقيق على مستوى القاعدة لا تختلف سلوكيًا بين SQL مباشر وHTTP، وأُثبتت جميعها بشكل حاسم على مستوى SQL (تفصيل القرار في `TEST_RESULTS_HOTFIX_6_1_2.md` §8).
- إصلاح فِكستشر Vitest بحت لِـ`tests/adjustments-hotfix-6-1-1-list-reversal-pagination.test.tsx` (البند 6: `reversal_payment_fee_impact` من `-12.50` الخاطئة إلى `12.50` الصحيحة) + اختبار Vitest جديد صريح لصف "عمولة الدفع (أصلي / أثر العكس)".
- `npx vitest run` → **126/126 عبر 15 ملفًا** (125 قائم + 1 جديد، صفر حذف/إضعاف).
- `npx tsc --noEmit` → **صفر أخطاء**. `npx eslint .` → **صفر أخطاء** (4 تحذيرات قائمة مسبقًا في ملف لم يُلمَس هذه الجولة).
- `DATABASE_URL=... npx tsx scripts/check-numeric-column-types.ts` → **73/73 عمود NUMERIC مطابق**.
- `npm run build` (Next.js/Turbopack) → **نجح**، نفس مسارات الصفحات القائمة، لا صفحات جديدة.

### 5) الملفات/الترحيلات التي تغيَّرت أو أُضيفت في Hotfix 6.1.2 (قائمة كاملة)

**ترحيلات جديدة (4):** `0163_adjustments_calculation_version_strict_invariant.sql`، `0164_adjustment_types_updated_by_anti_forgery.sql`، `0165_approve_sales_order_adjustment_v4_approval_audit_snapshot.sql`، `0166_update_adjustment_type_audit_description.sql`.

**اختبار SQL جديد بالكامل:** `supabase/tests/adjustments_hotfix_6_1_2.test.sql`.

**اختبار Vitest مُعدَّل (إصلاح فِكستشر + إضافة اختبار واحد جديد، لا حذف):** `tests/adjustments-hotfix-6-1-1-list-reversal-pagination.test.tsx`.

**لم يتغيّر إطلاقًا:** أي ترحيلة من 0001–0162 (مؤكَّد byte-for-byte مقابل الأرشيف المُعتمَد سابقًا SHA-256 `36bb8407...9d4a007`، §9 من `TEST_RESULTS_HOTFIX_6_1_2.md`)، أي صفحة/مكوّن UI (هذه الجولة مصدرية/اختبارية بحتة، لا تغيير في الواجهة إطلاقًا)، أي وحدة أخرى (Sales/Returns/Shipping/Users/Stores/Master Data غير Adjustments)، ولا حُذِف أو أُضعِف أي اختبار قائم.

**خلاصة الملحق الثامن والعشرون:** إغلاق نهائي دقيق ومحدود النطاق لثلاث ثغرات BLOCKER حقيقية تبقَّت بعد Hotfix 6.1.1 — عقد `calculation_version` أصبح دقيقًا مغلقًا (v1 فقط، لا مجرد not-null)، `adjustment_types.updated_by` أصبح غير قابل للتزوير فعليًا حتى عبر كتابة موثوقة/service_role مباشرة (مُثبَت بسيطرة سلبية حقيقية ضد الجسم القديم، بلا أي Test-only workaround)، ولقطة تدقيق الاعتماد المالية/الرئيسية الكاملة أصبحت موثَّقة بالكامل بدل الإجماليات فقط — بالإضافة إلى إكمال تدقيق `description` وإصلاح عطل فِكستشر اختباري بحت في إشارة عمولة العكس (مع إثبات SQL حقيقي مستقل). **4 ترحيلات جديدة (0163–0166، بلا أي تعديل على 0001–0162) + مساران ترقية مطلوبان كاملان + ملف اختبار SQL جديد بـ11/11 تأكيد PASS + 17 ملف اختبار SQL غير-ترقية + 4 ملفات تزامن حقيقي A–I + 185 تأكيد HTTP حقيقي دون انحدار + 126 اختبار Vitest (1 جديد) + 73/73 عمود NUMERIC + بناء إنتاجي ناجح — كلها من تشغيلات فعلية في هذه الجلسة. لم تُعدَّل أي ترحيلة من 0001–0162. لم تبدأ Settlements ولا أي مرحلة جديدة. لم يُحذَف ولم يُضعَف أي اختبار قائم. العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP كامل للمشروع.**

---

## الملحق التاسع والعشرون — "Phase 7 — Settlements Core: طبقة مطابقة الصندوق/معالج الدفع" (ترحيلات 0167–0183)

هذا الملحق يوثِّق **Phase 7 — Settlements Core** كاملة — أول عمل بعد الموافقة الرسمية على إغلاق Phase 6 نهائيًا (بعد Hotfix 6.1.2، الملحق الثامن والعشرون أعلاه). **قاعدة التجميد هذه الجولة الأصرم على الإطلاق**: 0001–0166 مُجمَّدة بالكامل بلا أي استثناء (حتى استثناء لمرة واحدة). كل عمل جديد بدأ حصرًا من **0167**. **النطاق محصور حصرًا في Settlements Core** — ممنوع صراحة: Reports/Dashboard النهائي، PDF/Excel، Inventory، Salla، Carrier APIs، Bank APIs، Attachments، Backups، 2FA، أو أي مرحلة بعد Settlements. تفاصيل الاختبار الكاملة بالأرقام الفعلية في `TEST_RESULTS_PHASE_7_SETTLEMENTS.md`. العمل **متوقف الآن نهائيًا**: **"لا تبدأ Phase 8. توقف بعد التسليم وانتظر المراجعة."**

### 1) المبدأ المالي الجوهري — Settlements ليست Profit Engine جديدًا

الركيزة التصميمية التي يُبنى عليها كل شيء في هذه المرحلة: Settlements تستهلك حصرًا Financial Snapshots/Events **المُلتزَمة مسبقًا** من Sales/Returns/Shipping/Adjustments **كما هي حرفيًا**، ولا تُعيد حسابها أبدًا. Settlement = طبقة مطابقة صندوق/معالج دفع (Cash/Processor Reconciliation Layer)، لا محرك ربحية موازٍ. المبالغ المصدرية تُعاد حلّها دومًا من القاعدة عند الاعتماد (Finalization) — لا تُقبَل أبدًا كمصدر حقيقة من العميل. حركة نقدية للتسوية لا تُعدِّل أبدًا `sales_orders.net_sales_profit`، ربحية المرتجعات، ربحية الشحن، أو ربحية التعديلات.

### 2) الترحيلات الجديدة (0167–0183) — جدول كامل

| # | الترحيلة | الغرض المختصر |
|---|---|---|
| 0167 | `settlements_permissions_and_locks.sql` | 10 صلاحيات `settlements.*` جديدة + Settlement Master Lock (مفتاح 1007). |
| 0168 | `settlement_routes_schema.sql` | مسارات التسوية (Master Data)، RPC-only writes، تصليب كامل من اليوم الأول. |
| 0169 | `settlement_route_rpcs.sql` | CRUD مسارات التسوية + بحث ضيق. |
| 0170 | `settlement_route_fee_versions_schema.sql` | إصدارات رسوم مُوزَّعة زمنيًا (نمط Versioning Hardening الكامل). |
| 0171 | `settlement_route_fee_version_rpcs.sql` | إنشاء/إلغاء إصدار رسوم + محلِّل تاريخي. |
| 0172 | `settlement_batches_schema.sql` | رأس دفعة التسوية، دورة حياة draft→finalized→reconciled. |
| 0173 | `settlement_batch_lines_and_claims_schema.sql` | لقطة مالية دائمة لكل مصدر + منع الاحتساب المزدوج DB-level. |
| 0174 | `settlement_bank_movement_schema.sql` | دفتر حركات بنكية Append-only + عكوسها. |
| 0175 | `settlement_batch_cancellations_schema.sql` | إلغاء الدفعة كحدث منفصل، لا يمسّ الدفعة الأصلية. |
| 0176 | `settlement_source_adapter_and_discovery.sql` | Settlement Source Adapter الموحَّد (7 مصادر) + Sign Convention. |
| 0177 | `settlement_batch_draft_rpcs.sql` | إنشاء/تعديل مسودة دفعة. |
| 0178 | `finalize_settlement_batch.sql` | **دالة السلطة المركزية** للاعتماد الذري. |
| 0179 | `settlement_bank_movement_rpcs.sql` | تسجيل/عكس حركة بنكية. |
| 0180 | `reconcile_settlement_batch.sql` | مطابقة حية (صفر/فرق غير صفري). |
| 0181 | `cancel_settlement_batch.sql` | إلغاء الدفعة. |
| 0182 | `settlement_batch_read_rpcs.sql` | كامل سطح القراءة (حجب مالي + خصوصية عبر-المتاجر). |
| 0183 | `audit_logs_settlements_financial_protection.sql` | حجب 6 أحداث تدقيق مالية خلف `settlements.view_financials`. |

### 3) Sign Convention — أدق وأخطر جزء منطقي في هذه المرحلة

`gross_collection_impact`: موجب = مبلغ متوقَّع من المعالج، سالب = استرداد/مبلغ مُستحَق الرد. `provider_fee_impact`: موجب = رسوم تُنقِص المتوقَّع، سالب = ائتمان/عكس رسوم يزيد المتوقَّع. `expected_settlement_impact = gross_collection_impact - provider_fee_impact` دومًا. طُبِّقت بدقة عبر 7 أنواع مصادر (بيع، استرداد، عكس استرداد، تعديل معتمَد، عكس تعديل، تحصيل COD، عكس COD)، مع ترجمة غير-تافهة لعقد Adjustments القائم مسبقًا من Hotfix 6.1.1/6.1.2 (`payment_fee_reversal_amount` المخزَّن موجبًا يُعكَس سالبًا هنا، بينما `customer_charge_reversal_amount` المخزَّن سالبًا أصلًا يُستخدَم كما هو) — مُتحقَّقة حسابيًا مقابل كل مثال رقمي في المواصفة قبل كتابة أي كود، ومُثبَتة بأرقام حقيقية من RPCs فعلية في `settlements_phase7.test.sql` (§1) وفي اختبار الترقية (§5).

### 4) عيبان حقيقيان وُجدا وأُصلِحا — `finalize_settlement_batch()` (0178)

عند أول اختبار فعلي شامل (لا أثناء الكتابة)، ظهر عيبان قاطعان جعلا الدالة معطَّلة 100% لكل استدعاء: (1) مرجع عمود `id` غامض — `returns table (id uuid, ...)` يجعل `id` متغيّرًا ضمنيًا يتعارض مع استعلامات غير مؤهَّلة بلقب جدول؛ (2) عطل `record` غير مُعيَّن — ثلاثة متغيرات `record` مُعبَّأة شرطيًا، أحدها يبقى دومًا غير مُعيَّن فعليًا بحكم قيد `settlement_routes_kind_fields_consistent` (0168). أُصلِح بتأهيل كل مرجع `id` وبمتغيرات `text` بسيطة بدل `record`. تفصيل كامل في `TEST_RESULTS_PHASE_7_SETTLEMENTS.md` §2. **لم يُوجَد أي عيب آخر في أي ترحيلة أخرى من 0167–0183 — كلها عملت بشكل صحيح من أول تشغيل فعلي.**

### 5) الاختبارات — ملخَّص (التفصيل الكامل بالأرقام في `TEST_RESULTS_PHASE_7_SETTLEMENTS.md`)

- ملف اختبار SQL جديد بالكامل `supabase/tests/settlements_phase7.test.sql` (1172 سطرًا) → **32/32 PASS** عبر 8 أقسام (دورة حياة المسار، Sign Convention، الاعتماد + إثبات كتابة موثوقة ضد التلاعب، تجاوزات مُصلَّحة، دورة حياة بنكية كاملة + إثبات عدم مساس، قراءة + خصوصية عبر-المتاجر، مصفوفة رفض صلاحيات).
- ملف تزامن حقيقي جديد `supabase/tests/settlements_phase7_concurrency.test.sql` (`dblink`) → **PASS**: اعتماد متزامن لنفس المصدر من دفعتين مختلفتين (نجاح واحد فقط، القيد الفريد `settlement_source_claims_active_unique_idx` يمنع الاحتساب المزدوج فعليًا)، وعكس متزامن لنفس الحركة البنكية (نجاح واحد فقط).
- مسار ترقية كامل جديد (3 ملفات + سكربت تنسيق) يُثبِت أن Settlement Source Adapter يكتشف بيانات بيع/استرداد/تعديل/عكس تعديل **حقيقية سابقة لِPhase 7 نفسها** (أُنشئت تحت RPCs ما قبل Phase 7 حصرًا، قبل تطبيق 0167–0183) بأرقام Sign Convention صحيحة — **PASS**، جُرِّب مرتين لإثبات إعادة التشغيل.
- الواجهة الكاملة (4 صفحات + طبقة بيانات + 9 مكوِّنات) → `typecheck`/`lint`/`build` **نجاح كامل**.
- 5 ملفات Vitest جديدة، **70 اختبارًا جديدًا** (Sign Convention pass-through، حجب مالي، حدود صلاحيات الإجراءات، Zod، ترقيم الصفحات) → **199/199 عبر السلسلة الكاملة (20 ملفًا)، صفر انحدار** عن الأساس (126/15).
- `check:numeric-types` → **89/89 عمود NUMERIC مطابق** (بعد توسيع `database.ts` بـ4 كتل `Row` كانت ناقصة لجداول Settlements الخام).
- **فجوة واحدة مؤجَّلة صراحة:** لم يُوسَّع `scripts/postgrest-http-test.mjs` بقسم Settlements مخصَّص — كل قواعد RLS/الصلاحيات مُثبَتة حاسمًا على مستوى SQL المباشر (نفس منطق RLS الذي يحكم PostgREST)، والحجم الحقيقي لهذه الإضافة لم يكن متناسبًا مع الوقت المتبقي في هذه الجلسة أمام تغطية SQL/Vitest/UI الشاملة القائمة فعلًا. مُسجَّلة صراحة لمراجعة لاحقة، لا إغفالًا صامتًا.

### 6) الملفات الجديدة/المُعدَّلة (قائمة كاملة)

**ترحيلات جديدة (17):** `0167_settlements_permissions_and_locks.sql` حتى `0183_audit_logs_settlements_financial_protection.sql` (القائمة الكاملة في §2 أعلاه).

**اختبارات SQL جديدة بالكامل (5 ملفات):** `supabase/tests/settlements_phase7.test.sql`، `supabase/tests/settlements_phase7_concurrency.test.sql`، `supabase/tests/fixtures/phase7_upgrade_pre_fixture.sql`، `supabase/tests/upgrade_phase7_settlements.test.sql`، `scripts/run_upgrade_test_phase7_settlements.sh`.

**واجهة جديدة بالكامل:** `src/features/settlements/{schema,queries,actions}.ts` + 9 ملفات تحت `src/features/settlements/components/` + 4 صفحات (`src/app/(app)/settlements/{page,new/page,[id]/page}.tsx`، `src/app/(app)/master-data/settlement-routes/page.tsx`).

**اختبارات Vitest جديدة بالكامل (5 ملفات، 70 اختبارًا):** `tests/settlements-schema-validation.test.ts`، `tests/settlements-actions-permission-boundary.test.ts`، `tests/settlements-financials-pass-through.test.tsx`، `tests/settlements-pagination.test.tsx`، `tests/settlements-list-filter-pagination.test.tsx`.

**كود مُعدَّل (إضافة فقط، لا حذف منطقي):** `src/app/(app)/settlements/page.tsx` (استبدال "قريبًا")، `src/app/(app)/master-data/page.tsx` (بطاقة مسارات التسوية)، `src/components/layout/nav-items.ts`، `src/lib/constants.ts`، `src/lib/permissions/constants.ts` (10 مفاتيح `settlements.*`)، `src/types/database.ts` (توسيع كامل لِRPCs/جداول Phase 7).

**لم يتغيّر إطلاقًا:** أي ترحيلة من 0001–0166 (مؤكَّد byte-for-byte مقابل الأرشيف المُعتمَد سابقًا SHA-256 `9d3a5f7319d4626e47f7f5a6d089e1e46a9969f48a093464191d05ef5e6c1c79`، §9 من `TEST_RESULTS_PHASE_7_SETTLEMENTS.md`)، `supabase/seed.sql`، أي صفحة/وحدة خارج Settlements (Sales/Returns/Shipping/Adjustments/Users/Stores/بقية Master Data)، ولا حُذِف أو أُضعِف أي اختبار قائم.

**خلاصة الملحق التاسع والعشرون:** بناء كامل لأول مرحلة عمل جديدة بعد إغلاق Phase 6 نهائيًا — طبقة مطابقة صندوق/معالج دفع كاملة فوق مبدأ "لا Profit Engine جديد" الصارم، تكتشف وتُطابِق بيانات مُلتزَمة مسبقًا من 4 وحدات مختلفة (Sales/Returns/Shipping/Adjustments) بإشارات Sign Convention مُتحقَّق منها حسابيًا ومُثبَتة بأرقام حقيقية، مع منع احتساب مزدوج مُثبَت DB-level وبتزامن حقيقي، ودورة حياة مالية كاملة (Draft→Finalize→Bank-Movement→Reconcile→Cancel) كل خطوة فيها ذرّية ومحكومة بصلاحية دقيقة. **17 ترحيلة جديدة (0167–0183، بلا أي تعديل على 0001–0166) + عيبان حقيقيان وُجدا وأُصلِحا أثناء الاختبار الفعلي (موثَّقان بالكامل) + ملف اختبار SQL بـ32/32 تأكيد PASS + تزامن حقيقي (dblink) + مسار ترقية كامل مُثبَت مرتين + واجهة كاملة (typecheck/lint/build ناجحة) + 199 اختبار Vitest (70 جديد، صفر انحدار) + 89/89 عمود NUMERIC — كلها من تشغيلات فعلية في هذه الجلسة. فجوة واحدة مؤجَّلة صراحة (تغطية HTTP/PostgREST مخصَّصة). لم تُعدَّل أي ترحيلة من 0001–0166. لم يبدأ Phase 8 ولا أي عمل خارج النطاق. لم يُحذَف ولم يُضعَف أي اختبار قائم. العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP كامل للمشروع.**

---

## الملحق الثلاثون — "Phase 7 — Integrity Patch 7.1": تصحيح تكاملي شامل لِSettlements Core (ترحيلات 0184–0191)

هذا الملحق يوثِّق **Patch 7.1** — مراجعة/تصحيح شامل لـ27 نقطة ضعف مالية/أمنية حقيقية وُجدت في Settlements Core (الملحق التاسع والعشرون أعلاه) بعد تسليمه، بالإضافة إلى توسيع تغطية الاختبار (§28–§34) لتشمل ما كان مؤجَّلًا صراحة سابقًا (HTTP/PostgREST) وما لم يكن مطلوبًا وقتها (تزامن A–K الكامل، اختبارات ترقية بأربعة مسارات). **قاعدة التجميد هذه الجولة هي الأصرم حتى الآن: 0001–0183 مُجمَّدة بالكامل بلا أي استثناء — كل تصحيح استُخدِم فيه `CREATE OR REPLACE FUNCTION` (نفس التوقيع) أو `DROP FUNCTION IF EXISTS` صريح متبوعًا بإعادة إنشاء، ولا تعديل مباشر واحد على أي ملف من 0001–0183.** كل عمل جديد بدأ حصرًا من **0184**. تفاصيل الاختبار الكاملة بالأرقام الفعلية (كلها مُعاد تشغيلها نظيفة في الساعات الأخيرة من هذه الجلسة) في `TEST_RESULTS_PATCH_7_1.md`. العمل **متوقف الآن نهائيًا**: **"لا تبدأ Phase 8. توقف بعد التسليم وانتظر المراجعة."**

### 1) الترحيلات الجديدة (0184–0191) — جدول كامل

| # | الترحيلة | الغرض المختصر |
|---|---|---|
| 0184 | `settlement_source_adapter_patch_7_1.sql` | إعادة بناء `_settlement_unsettled_source_candidates()` — مصادر استرداد فعلي جديدة، نطاق متجر صحيح، مطابقة دقيقة، خصوصية AND، اكتشاف COD حقيقي. |
| 0185 | `settlement_fee_resolver_and_finalize_patch_7_1.sql` | مُحلِّل رسوم مُشترَك (`_settlement_resolve_line_fee`) يضمن تطابق preview/finalize تامًا + فحوصات تاريخ/Daily Close. |
| 0186 | `settlement_batch_privacy_and_draft_getter_patch_7_1.sql` | خصوصية دفعة كاملة (fail-closed) + جالب مسودة مخصَّص للتحرير. |
| 0187 | `audit_logs_settlements_permission_split_patch_7_1.sql` | تقسيم سياسة سجل التدقيق إلى 3 فروع صلاحية غير متداخلة. |
| 0188 | `settlement_bank_movement_and_cancel_daily_close_patch_7_1.sql` | Daily Close/تسلسل تاريخ لحركات البنك والإلغاء + إغلاق توقيعات قديمة معلَّقة. |
| 0189 | `settlement_draft_rpcs_patch_7_1.sql` | فحص تاريخ مستقبلي + دلالات keep/set/clear صريحة للمسودة. |
| 0190 | `settlement_route_fee_version_and_manage_routes_patch_7_1.sql` | تحقُّق مبلغ/مقياس صارم + دوال بحث مقصورة على `manage_routes`. |
| 0191 | `settlement_batch_list_filters_and_effective_semantics_patch_7_1.sql` | مرشِّحات قائمة جديدة + مخطط قيم original_*/effective_* للسجلات المُلغاة. |

### 2) عيبان حرجان وُجدا وأُصلِحا أثناء الاختبار الفعلي لِ0188

خلال تدقيق مستقل مخصَّص (لا أثناء الكتابة)، ظهر عيبان حقيقيان قاطعان في 0188: (1) `_settlement_batch_relevant_store_ids()` أُعلنت بـ`returns setof uuid` بينما استدعتها ثلاث RPCs بعمود `store_id` غير موجود فعليًا تحت هذا التوقيع — **تعطُّل وظيفي كامل** لِ`record_settlement_bank_movement()`/`reverse_settlement_bank_movement()`/`cancel_settlement_batch()`؛ (2) إضافة `p_closed_day_reason` كمعامل أخير عبر `CREATE OR REPLACE` أنشأت Overload جديدًا بجانب التوقيع القديم غير المُصحَّح **الذي بقي ممنوحًا وقابلًا للاستدعاء**، متجاوزًا صمتًا كل إصلاحات §12/§13. أُصلِح الأول بتغيير نوع الإرجاع إلى `returns table (store_id uuid)`، والثاني بإضافة `drop function if exists` صريح لثلاثة توقيعات قديمة في نهاية 0188. أُعيد بناء القاعدة بالكامل وتأكد عبر استعلام `group by proname, pronargs` أن **لا يوجد Overload مكرر غير مقصود في كامل وحدة Settlements**. تفصيل كامل في `TEST_RESULTS_PATCH_7_1.md` §2.

### 3) شرح البنود 8–19 من §38 — التصحيحات المنطقية الاثنا عشر الجوهرية

**(8) مُحوِّل مصدر الاسترداد الفعلي الجديد:** النسخة السابقة كانت تكتشف مصادر `return_refund`/`return_refund_reversal` من حقول `sales_returns` (target/snapshot) — وهي أهداف/توقعات، لا حركة نقدية فعلية مُلتزَمة. المُحوِّل الجديد (0184) يستهلك حصرًا `sales_return_refund_events`/`sales_return_refund_event_reversals` — دفتر الاسترداد النقدي **الفعلي** append-only — عبر أنواع مصدر جديدة (`return_refund_event`/`_reversal`)، بينما تبقى الأنواع القديمة في قيود CHECK لأغراض القراءة التاريخية فقط ولا تُصدَر أبدًا من جديد.

**(9) مطابقة عكس الرسوم دون توزيع مُختلَق:** عند عكس رسم استرداد، لا تُقسَّم/تُوزَّع القيمة افتراضيًا على أسطر متعددة — تُطابَق مباشرة بمصدرها الأصلي عبر معرِّف الحدث نفسه (`return_fee_reversal`/`_reversal` كأنواع مصدر منفصلة ومباشرة)، فلا يُختلَق أي منطق توزيع تقديري غير مُثبَت في القاعدة.

**(10) مطابقة مسار/قناة دقيقة:** النسخة السابقة تعاملت مع `NULL` كـwildcard (مطابقة أي شيء) عبر مقارنة `=` عادية تفشل صمتًا على NULL. المطابقة الجديدة تستخدم `IS NOT DISTINCT FROM` حصرًا — تطابق NULL=NULL بدقة تامة، ولا تتصرف كـwildcard أبدًا؛ مسار بقناة `NULL` صريحة لا يطابق أي عملية بيع لها قناة فعلية، ولا العكس.

**(11) مُحوِّل انتقال COD:** بدل استنتاج "تحصيل/عدم تحصيل" من حالة لحظية واحدة (عرضة لأخطاء لو تغيّرت الحالة عدة مرات)، يستخدم 0184 نافذة `lag()` مرتَّبة زمنيًا (`business_date, created_at, id`) على كامل تاريخ الشحنة لاكتشاف **انتقال حالة حقيقي** — لا يُصدِر `cod_reversal` إلا عند انتقال فعلي `collected→not_collected` موثَّق تسلسليًا، مُثبَت بمثال حي عبر HTTP حقيقي في `TEST_RESULTS_PATCH_7_1.md` §5.

**(12) خصوصية سطور الدفعة الكاملة (Whole-Batch):** النسخة السابقة كانت تُخفي أسطرًا فردية لا تخص متاجر المستخدم مع ترك باقي الدفعة (وإجمالياتها) ظاهرة — تسريب جزئي لمعلومات مالية عبر المتاجر. `_settlement_batch_all_stores_visible()` (0186) تحوّل هذا إلى قاعدة "الكل أو لا شيء" فعليًا: إن كان أي سطر واحد في الدفعة يخص متجرًا خارج نطاق المستخدم، **الدفعة بأكملها** تُخفى من `list/get_settlement_batch()` — fail-closed لا fail-open.

**(13) مصفوفة صلاحيات سجل التدقيق:** كانت سياسة `audit_logs_select` تُدمِج أحداث Settlements المالية مع أحداث عامة تحت شرط OR فضفاض. أُعيد بناؤها (0187) إلى 3 فروع غير متداخلة صراحة: فرع A مقصور على `sales.view_profit` لأحداث Sales/Returns/Shipping/Adjustments، فرع B مقصور على `settlements.view_financials` لأحداث Settlement + دورة حياة إصدار الرسوم، فرع C (`audit_logs.view` فقط) لكل شيء آخر — لا تسريب صلاحية بين الفروع.

**(14) عقود Daily Close/التاريخ:** لم تكن `finalize_settlement_batch()` (قبل 0185) ولا `create/update_draft_settlement_batch()` (قبل 0189) تتحقق من `settlement_date` مقابل `business_today()`، ولا كانت الحركات البنكية/الإلغاء (قبل 0188) تفرض قفل Daily Close على تاريخها الخاص لكل متجر متأثر فعليًا (بدل تاريخ الدفعة فقط). الآن: `settlement_date` يُرفَض دومًا إن كان مستقبليًا (`> business_today()`، أبدًا `current_date`)، وكل RPC يفرض `acquire_daily_close_lock_*` على **كل متجر متأثر فعليًا** بتاريخ **الحدث نفسه** لا تاريخ الدفعة الأصلية.

**(15) تطابق Preview/Finalize:** كانت الدالتان تحسبان الرسوم بمنطق منفصل قابل للانحراف صمتًا. `_settlement_resolve_line_fee()` (0185، IMMUTABLE) أصبحت المُحلِّل الوحيد المُستدعى من كلتيهما — لا يمكن لأي تعديل مستقبلي أن يُحدِث انحرافًا بينهما دون كسر كلتيهما معًا؛ مُثبَت رقميًا عبر HTTP حقيقي (25.50 من preview = 25.50 من finalize، §5 من `TEST_RESULTS_PATCH_7_1.md`، مُعلَّم بندًا حرجًا صريحًا في الاختبار نفسه).

**(16) عقد تقريب `route_formula`:** التقريب الآن يحدث مرة واحدة فقط على القيمة النهائية المُجمَّعة، لا على أي مكوّن وسيط قبل الجمع — يمنع انحراف تراكمي عبر تقريبات متعددة متتالية لنفس القيمة.

**(17) سير عمل إنشاء فقط:** `create_draft_settlement_batch()`/`update_draft_settlement_batch()` مقصورتان على `settlements.create` حصرًا (لا تتطلبان ولا تُمنَحان أي صلاحية مالية إضافية) — إنشاء/تحرير المسودة عملية تحضيرية بحتة، لا تصل لأي بيانات مالية مُلتزَمة قبل `finalize`.

**(18) سير عمل مقصور على `manage_routes`:** أربع دوال بحث جديدة (طريقة دفع/قناة تحصيل/ناقل/إصدارات رسوم — 0190) مقصورة **حصرًا** على `settlements.manage_routes`، منفصلة تمامًا عن دوال البحث العامة الأوسع المتاحة لصلاحيات أخرى — تُرجِع صفوفًا فارغة صمتًا (لا استثناء) لأي فاعل يفتقد هذه الصلاحية تحديدًا، مُثبَت في §8.13b من ملف اختبار SQL.

**(19) دلالات Original مقابل Effective للسجلات المُلغاة:** `list/get_settlement_batch()` (0191) تُميِّز الآن صراحة بين حقول `original_*`/`historical_*` (تُحافظ دومًا على القيم التاريخية الحقيقية كما وقعت، حتى بعد الإلغاء) وحقول `effective_*` (تنهار إلى 0.00 بمجرد الإلغاء) — بدل الأسماء المسطَّحة السابقة التي كانت تُخلِط الاثنين ضمنًا، مما جعل عرض دفعة مُلغاة إما مضلِّلًا (يبدو كأن لا شيء حدث) أو فاقدًا للتاريخ الحقيقي (يبدو كأن القيمة الأصلية لم تكن موجودة قط).

### 4) نتائج الاختبار — البنود 20–24 من §38 (التفصيل الكامل في `TEST_RESULTS_PATCH_7_1.md`)

- **(20) تزامن A–K:** جميع السيناريوهات الحرفية الـ11 المطلوبة مُثبَتة بجلسات `dblink` حقيقية متزامنة فعليًا — **12/12 إشعار PASS، Exit 0** (§4 من ملف النتائج).
- **(21) اختبارات SQL جديدة (§31):** `settlements_phase7.test.sql` مُوسَّع 1172→2477 سطرًا، قسم 8 جديد كليًا (8.1–8.16) — **67/67 PASS، Exit 0**.
- **(22) HTTP/PostgREST حقيقي (§32):** `postgrest-http-test.mjs` مُوسَّع إلى 4078 سطرًا، قسم "Part 14" جديد كليًا (66 بندًا a–y) — **252 تأكيد OK عبر الملف بأكمله (66 جديد)، Exit 0** — البند المؤجَّل صراحة في الملحق التاسع والعشرين أُنجِز بالكامل الآن.
- **(23) React/Vitest (§33):** 4 ملفات جديدة (آلة حالة المعاينة، مسارات مقصورة بالصلاحية، عرض original/effective، حارس float نقدي) — **229/229 عبر 24 ملفًا، صفر انحدار عن 199 السابقة**.
- **(24) TypeScript/Lint/Numeric/Build:** أربعتها **نظيفة بالكامل** — typecheck 0 أخطاء، lint 0 أخطاء (4 تحذيرات سابقة غير متعلقة)، 89/89 عمود NUMERIC مطابق، بناء إنتاجي ناجح (`✓ Compiled successfully`) — إضافة إلى 4/4 اختبارات أمان ترقية (§34، A/B/C/D) و5/5 اختبارات ترقية قديمة (Phase/Hotfix/Patch سابقة) بلا أي انحدار.

### 5) الملفات الجديدة/المُعدَّلة/المحذوفة (§38 البند 7) — مقارنة كاملة مقابل الأرشيف المُسلَّم سابقًا

مبنية عبر `diff -rq` كامل بين محتوى `gold-erp-phase7-settlements.zip` (المُسلَّم سابقًا) وحالة المستودع الحالية بالكامل (باستثناء `node_modules`/`.git`/`.next`/`.env*`):

**محذوفة: لا شيء إطلاقًا (0 ملف).**

**جديدة بالكامل (15 ملفًا):** 8 ترحيلات (`0184`–`0191`، جدول §1 أعلاه)؛ `scripts/run_upgrade_test_phase7_1_settlements.sh`؛ `supabase/tests/fixtures/phase7_1_upgrade_pre_fixture.sql`؛ `supabase/tests/upgrade_phase7_1_settlements.test.sql`؛ 4 ملفات Vitest (`tests/settlements-preview-state-machine.test.tsx`، `tests/settlements-permission-scoped-workflows.test.tsx`، `tests/settlements-lifecycle-presentation.test.tsx`، `tests/settlements-money-string-invariant.test.ts`).

**مُعدَّلة (20 ملفًا):** `scripts/postgrest-http-test.mjs`، `scripts/run_postgrest_http_test.sh`، `supabase/tests/postgrest_http_test_setup.sql` (4 فاعلين اختباريين جدد)؛ `supabase/tests/settlements_phase7.test.sql`، `supabase/tests/settlements_phase7_concurrency.test.sql`؛ `supabase/tests/fixtures/phase7_upgrade_pre_fixture.sql`، `supabase/tests/upgrade_phase7_settlements.test.sql` (§34 البند D)؛ `src/features/settlements/{schema,queries,actions}.ts`؛ 5 مكوِّنات تحت `src/features/settlements/components/` (`settlement-bank-movements-panel`، `settlement-batches-filters`، `settlement-draft-workspace` [آلة حالة المعاينة §16]، `settlement-lifecycle-actions`، `settlement-route-fee-version-panel`)؛ 3 صفحات (`src/app/(app)/settlements/page.tsx`، `src/app/(app)/settlements/[id]/page.tsx`، `src/app/(app)/master-data/settlement-routes/page.tsx`)؛ `src/types/database.ts` (توسيع كامل لكل RPC/عمود جديد أو مُعاد تعريفه)؛ `tests/settlements-financials-pass-through.test.tsx`، `tests/settlements-list-filter-pagination.test.tsx` (فِكستشر فقط، بلا حذف تغطية).

**ملفات توثيق التسليم (مُعدَّلة/جديدة، خارج نطاق الكود):** `DELIVERY_REPORT.md` (هذا الملحق)، `TEST_RESULTS_PATCH_7_1.md` (جديد بالكامل).

**لم يتغيّر إطلاقًا:** أي ترحيلة من 0001–0183 (مؤكَّد byte-for-byte، §9 من `TEST_RESULTS_PATCH_7_1.md`)، `supabase/seed.sql`، أي وحدة خارج Settlements (Sales/Returns/Shipping/Adjustments/Users/Stores/بقية Master Data)، ولا حُذِف أو أُضعِف أي اختبار قائم في أي مكان.

### 6) إثبات استعادة `.env.example` (§38 البند 25)

`.env.example` لم يُفقَد فعليًا من المستودع في أي لحظة — مؤكَّد عبر `diff` مباشر أنه مطابق حرفيًا (682 بايت، نفس بصمة MD5 `503293b4e55c4755e3737faa00bd5dd0`) لأساس Phase 6 (`gold-erp-hotfix-6-1-2.zip`) طوال الوقت. ما حدث في التسليم السابق للملحق التاسع والعشرين كان إغفال هذا الملف في **خطوة تحزيم الـZIP نفسها فقط** — لا فقدانًا حقيقيًا من المستودع. هذا التسليم يتضمَّن الملف فعليًا في الـZIP المُرفَق (§10 من `TEST_RESULTS_PATCH_7_1.md`).

### 7) تأكيد عدم بدء Phase 8 (§38 البند 26)

لم يبدأ أي عمل يخص Phase 8 أو أي مرحلة/وحدة تتجاوز نطاق Settlements Core وتصحيحاته إطلاقًا في هذه الجلسة. كل تغيير في هذا الملحق مقصور حصرًا على: (أ) 8 ترحيلات SQL تصحيحية (0184–0191) ضمن وحدة Settlements فقط، (ب) تعديلات UI/Server Actions ضمن `src/features/settlements/` و4 صفحات Settlements فقط، (ج) اختبارات/سكربتات تحقُّق لنفس الوحدة فقط. لا Reports/Dashboard نهائي، لا PDF/Excel، لا Inventory، لا Salla، لا Carrier/Bank APIs، لا Attachments/Backups/2FA، ولا أي مرحلة جديدة.

### 8) خلاصة الملحق الثلاثون

تصحيح تكاملي شامل ودقيق لـ27 نقطة ضعف مالية/أمنية حقيقية في Settlements Core، مع توسيع تغطية اختبار جوهري (تزامن كامل A–K، HTTP/PostgREST حقيقي كان مؤجَّلًا صراحة، 4 مسارات ترقية) — واكتشاف وإصلاح فعلي لعيبين حرجين إضافيين أثناء الاختبار نفسه (لا أثناء الكتابة). **8 ترحيلات جديدة (0184–0191، بلا أي تعديل — ولو بايت واحد — على 0001–0183، مؤكَّد آليًا) + عيبان حرجان وُجدا وأُصلِحا (موثَّقان بالكامل) + 67/67 PASS اختبار SQL + تزامن حقيقي A–K (12/12 PASS) + 252 تأكيد HTTP حقيقي (66 جديد) + 229/229 Vitest (24 ملفًا، صفر انحدار) + حارس float نقدي مُثبَت سلوكيًا + 4/4 اختبارات أمان ترقية + 5/5 اختبارات ترقية قديمة بلا انحدار + 89/89 عمود NUMERIC + TypeScript/ESLint/بناء إنتاجي نظيفة بالكامل — كل رقم من تشغيل فعلي أُعيد تنفيذه نظيفًا في الساعات الأخيرة من هذه الجلسة تحديدًا. صفر ملفات محذوفة، 15 جديدة، 20 مُعدَّلة. إثبات أن `.env.example` لم يُفقَد فعليًا قط. لم يبدأ Phase 8 ولا أي عمل خارج النطاق. لم يُحذَف ولم يُضعَف أي اختبار قائم. العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP كامل للمشروع.**

---

## الملحق الحادي والثلاثون — "Phase 7 — Final Integrity Hotfix 7.1.1": الجدول الزمني النقدي التاريخي، نطاق المتجر، الخصوصية، وتكافؤ المعاينة (ترحيلات 0192–0196)

هذا الملحق يوثِّق **Hotfix 7.1.1** — تصحيح نهائي دقيق فوق Patch 7.1 (الملحق الثلاثون أعلاه) يغلق 6 نقاط ضعف حرجة/متوسطة وُجدت في مراجعة مستقلة لاحقة لـSettlements Core: تحويل مصدرَي عكس الرسوم إلى حقائق تاريخية دائمة بدل استنتاج من حالة لحظية، تصحيح مطابقة المسار/القناة لتعتمد على البيع الأصلي لا طريقة الاسترداد، إغلاق فحص الملكية على تحديث المسودة، فرض نطاق المتجر على كل RPC كاتبة في دورة حياة الدفعة (لا القراءة فقط)، سحب صلاحية الاستدعاء المباشر عن مُحلِّل الرسوم الداخلي، وتحقيق تكافؤ preview/finalize الكامل لتجاوز رسوم الدفعة. **قاعدة التجميد هذه الجولة صارمة كسابقاتها: 0001–0191 مُجمَّدة بالكامل بلا أي استثناء، مؤكَّدة بايت-لبايت — كل تصحيح استُخدِم فيه `CREATE OR REPLACE FUNCTION` (نفس التوقيع) أو `DROP FUNCTION`/`REVOKE EXECUTE` صريحان، ولا تعديل مباشر واحد على أي ملف من 0001–0191.** كل عمل جديد بدأ حصرًا من **0192**. تفاصيل الاختبار الكاملة بالأرقام الفعلية (كلها مُعاد تشغيلها نظيفة في الساعات الأخيرة من هذه الجلسة) في `TEST_RESULTS_HOTFIX_7_1_1.md`. العمل **متوقف الآن نهائيًا**: **"لا تبدأ Phase 8. توقف بعد التسليم وانتظر المراجعة."**

### 1) الترحيلات الجديدة (0192–0196) — جدول كامل

| # | الترحيلة | الغرض المختصر |
|---|---|---|
| 0192 | `settlement_source_adapter_hotfix_7_1_1.sql` | `return_fee_reversal`/`_reversal` أصبحا حدثين تاريخيين دائمين مُطابَقين عبر مسار البيع الأصلي لا `refund_method_id`؛ مرشِّح متجر `list_unsettled_settlement_sources()` أصبح OR لا AND. |
| 0193 | `settlement_lifecycle_ownership_and_store_scope_hotfix_7_1_1.sql` | فحص ملكية على `update_draft_settlement_batch()`؛ نطاق متجر fail-closed على 4 RPCs كاتبة؛ تسلسل تاريخ الإلغاء؛ إخفاء حقول تسوية مالية دون `view_financials`. |
| 0194 | `settlement_fee_resolver_lockdown_hotfix_7_1_1.sql` | سحب `EXECUTE` عن `settlement_route_fee_for_route_on_date()` من PUBLIC/authenticated. |
| 0195 | `settlement_preview_batch_fee_override_hotfix_7_1_1.sql` | `preview_settlement_batch()` بتوقيع جديد يقبل تجاوز رسوم الدفعة بتحقُّق مطابق لِ`finalize`. |
| 0196 | `settlement_filter_lookups_hotfix_7_1_1.sql` | 3 RPCs بحث جديدة مقصورة على `settlements.view` وحده، تشمل القيم المعطَّلة/التاريخية. |

### 2) شرح النقاط الست الجوهرية

**(1) عكس الرسوم كحدث تاريخي دائم، لا استنتاج لحظي (§1، حرج):** النسخة السابقة كانت تشتق ظهور/اختفاء `return_fee_reversal` من عمود `status` اللحظي لِـ`sales_returns` — فبعد أي عكس إداري لاحق للمرتجَع، كان المصدر **يختفي بالكامل** من الاكتشاف رغم أن الرسم قد اعتُمِد فعليًا وقد يكون غير مُطالَب به بعد. الإصلاح (0192) يجعل ظهور `return_fee_reversal` مشروطًا حصرًا بـ`approved_at IS NOT NULL` (تاريخ اعتماد دائم لا يتغيَّر)، وظهور `return_fee_reversal_reversal` مشروطًا حصرًا بـ`reversal_business_date IS NOT NULL` — كلاهما يبقيان ظاهرين للأبد بمجرد وقوع الحدث الفعلي، بصرف النظر عن أي تغيير لاحق في حالة المرتجَع، ويمكن أن يتعايشا معًا (يتعادلان صفرًا) طالما لم يُطالَب بأي منهما.

**(2) مطابقة المسار عبر البيع الأصلي (§3، حرج):** كانت `return_fee_reversal`/`_reversal` تُطابَقان بنفس منطق `return_refund_event` (طريقة الاسترداد + قناة NULL ضمنية) — ما كان يجبر المصدرين على الاستقرار على نفس المسار حصرًا، رغم أن عكس الرسم منطقيًا مرتبط بـ**مسار البيع الأصلي** لا بطريقة استرداد النقد الفعلي (التي قد تختلف). الإصلاح يُطابِق عبر `sales_returns.sales_order_id → sales_orders.payment_method_id`/`collection_channel_id` — يسمح الآن للمصدرين بالاستقرار على **مسارين مختلفين شرعًا** لنفس المرتجَع، مُثبَت مباشرة حيًّا عبر HTTP حقيقي (كلاهما يُطالَب به بشكل مستقل في دفعتين منفصلتين، §17 البند k).

**(3) فحص ملكية مفقود على تحديث المسودة (§4، حرج):** `get_draft_settlement_batch_for_edit()` كانت تفرض "مسوداتك فقط" بينما `update_draft_settlement_batch()` (الفعل الفعلي المُعدِّل للبيانات) لم تكن تفرض أي شيء — فجوة تسمح لأي حامل `settlements.create` بتعديل مسودة فاعل آخر. أُضيف نفس الفحص بالضبط (`created_by is distinct from v_actor` مع استثناء `settlements.view`).

**(4) نطاق المتجر على الكتابة لا القراءة فقط (§5، حرج):** خصوصية Whole-Batch (Patch 7.1، الملحق الثلاثون) كانت مُطبَّقة فقط على `list/get_settlement_batch()` — أما `record`/`reverse_settlement_bank_movement()`/`reconcile_settlement_batch()`/`cancel_settlement_batch()` فكانت تُنفِّذ الفعل الكاتب دون أي فحص رؤية متجر، بصرف النظر عن كون الفاعل يرى الدفعة أصلًا أم لا. أُضيف استدعاء `_settlement_batch_all_stores_visible()` (الدالة القائمة من 0186) في بداية كل واحدة من الأربع، fail-closed برسالة "غير موجودة" مطابقة لنمط القراءة.

**(5) سحب صلاحية استدعاء مُحلِّل الرسوم المباشر (§6):** `settlement_route_fee_for_route_on_date()` كانت RPC عامة قابلة للاستدعاء مباشرة رغم أنها مُصمَّمة كأداة داخلية فقط لِ`preview`/`finalize` — تسريب معلومة تسعير غير ضروري. أُصلِح بـ`REVOKE EXECUTE` صريح، تبقى الدالة تعمل داخليًا (استدعاء دالة لدالة يتجاوز صلاحيات EXECUTE المباشرة عبر PostgREST).

**(6) تكافؤ Preview/Finalize لتجاوز رسوم الدفعة (§9، حرج):** `finalize_settlement_batch()` كانت تقبل `p_batch_fee_override`/`p_override_reason` منذ Patch 7.1، لكن `preview_settlement_batch()` لم تكن تقبلهما إطلاقًا — ما يعني أن المستخدم لا يمكنه رؤية أثر التجاوز قبل الالتزام به فعليًا. `DROP`+`CREATE` (0195) يضيف نفس المعاملين بنفس التحقُّق الحرفي (صلاحية `override_batch_fee`، سبب إلزامي غير فارغ، رفض القيم السالبة، `validate_money_scale`)، ويُرجِع `configured_batch_fee`/`effective_batch_fee`/`batch_fee_overridden` — مُثبَت تكافؤًا حرفيًا (لا رقميًا فقط) عبر HTTP حقيقي.

### 3) نتائج الاختبار (التفصيل الكامل في `TEST_RESULTS_HOTFIX_7_1_1.md`)

- **اختبار SQL القائم (`settlements_phase7.test.sql`):** أُعيد بناء القسم 8.1c بالكامل — كان يختبر الخلل القديم نفسه (اختفاء `return_fee_reversal`)، أصبح يختبر السلوك الصحيح (بقاؤه + تعايشه مع عكسه) — **68/68 PASS، Exit 0**.
- **اختبار SQL جديد كليًا (`settlements_hotfix_7_1_1.test.sql`، 461 سطرًا):** 7 فاعلين، 7 أقسام تغطي §4/§5/§7/§9/§11/§12/§15 مباشرة — **12/12 PASS، Exit 0**.
- **تزامن A–K:** بلا تعديل، أُعيد تشغيله للتأكد من عدم إدخال أي حالة تسابق جديدة — **12/12 PASS، Exit 0**.
- **HTTP/PostgREST حقيقي:** قسم "Part 15" جديد (11 بندًا a–k، 31 تأكيدًا) فوق "Part 14" القائم — **282 تأكيد OK إجمالًا، Exit 0**.
- **React/Vitest:** ملف جديد + 5 ملفات مُحدَّثة تغطي البنود التسعة A–I من §18 — **265/265 (24→25 ملفًا، +36 اختبارًا، صفر انحدار)**.
- **اختبارات أمان الترقية:** الأربعة A/B/C/D (D جديد كليًا لهذا الهوتفكس) + 5 سكربتات ترقية أقدم غير متعلقة — **9/9 PASSED، Exit 0**.
- **TypeScript/ESLint/NUMERIC/بناء إنتاجي:** الأربعة **نظيفة بالكامل**.

### 4) عيبان صغيران حقيقيان وُجدا وأُصلِحا أثناء كتابة الاختبارات (لا أثناء التخطيط)

خلال كتابة اختبارات §18 (Vitest)، ظهر عيبان حقيقيان محدودا الأثر، خارج نطاق التصحيحات الستة أعلاه لكن ضمن نفس الوحدة، أُصلِحا فورًا:

1. **`src/features/settlements/schema.ts`:** `.refine()` ثانٍ في `signedNonZeroMoneySchema` كان يستدعي `toDecimal(v).isZero()` دون حماية من استثناء — مدخل مثل `""`/`"-"`/`"+"` كان يرمي استثناء JS خامًا بدل فشل Zod عادي (لأن Zod ينفِّذ كل `.refine()` مسلسلة بصرف النظر عن نتيجة السابق). أُصلِح بلفّه في try/catch.
2. **`settlement-draft-workspace.tsx`:** `FinalizeDialog.submit()` كان يرسل قيمة/سبب تجاوز رسوم الدفعة **دون `trim()`** بينما `runPreview()` يرسلهما بعد `trim()` — قيمة تحمل فراغًا زائدًا عرضيًا (نسخ/لصق مثلًا) كانت تصل لـ`finalize_settlement_batch()` كنص مختلف حرفيًا عمّا عرضه `preview_settlement_batch()` للتو، رغم تساويهما رقميًا — ينتهك دقيقًا §9 نفسه (تكافؤ preview/finalize). أُصلِح بمطابقة `trim()` في كليهما.

### 5) الملفات الجديدة/المُعدَّلة/المحذوفة — مقارنة كاملة مقابل `gold-erp-patch-7-1-settlements.zip`

مبنية عبر `diff -rq` كامل بين محتوى الأرشيف المُسلَّم سابقًا وحالة المستودع الحالية بالكامل (باستثناء `node_modules`/`.git`/`.next`/`.env*`؛ استُثني أيضًا ملف ذاكرة تخزين مؤقت `tsconfig.tsbuildinfo` غير المقصود تتبُّعه، حُذِف من شجرة العمل):

**محذوفة: لا شيء إطلاقًا (0 ملف).**

**جديدة بالكامل (10 ملفات):** 5 ترحيلات (`0192`–`0196`، جدول §1 أعلاه)؛ `scripts/run_upgrade_test_hotfix_7_1_1_settlements.sh`؛ `supabase/tests/fixtures/hotfix_7_1_1_upgrade_pre_fixture.sql`؛ `supabase/tests/settlements_hotfix_7_1_1.test.sql`؛ `supabase/tests/upgrade_hotfix_7_1_1_settlements.test.sql`؛ `tests/settlements-hotfix-7-1-1.test.tsx`.

**مُعدَّلة (17 ملفًا):** `scripts/postgrest-http-test.mjs`، `scripts/run_postgrest_http_test.sh`، `supabase/tests/postgrest_http_test_setup.sql` (3 فاعلين اختباريين جدد)، `supabase/tests/settlements_phase7.test.sql` (إعادة بناء 8.1c)؛ `src/features/settlements/{actions,queries,schema}.ts`؛ 3 مكوِّنات (`settlement-draft-workspace`، `settlement-route-fee-version-panel`، `settlement-route-form-dialog`)؛ `src/app/(app)/master-data/settlement-routes/page.tsx`؛ `src/types/database.ts`؛ 5 ملفات Vitest (`settlements-list-filter-pagination`، `settlements-money-string-invariant`، `settlements-pagination`، `settlements-preview-state-machine`، `settlements-schema-validation`).

**ملفات توثيق التسليم (مُعدَّلة/جديدة، خارج نطاق الكود):** `DELIVERY_REPORT.md` (هذا الملحق)، `TEST_RESULTS_HOTFIX_7_1_1.md` (جديد بالكامل).

**لم يتغيَّر إطلاقًا:** أي ترحيلة من 0001–0191 (مؤكَّد byte-for-byte، §9 من `TEST_RESULTS_HOTFIX_7_1_1.md`)، `supabase/seed.sql`، `.env.example`، `supabase/tests/settlements_phase7_concurrency.test.sql`، أي وحدة خارج Settlements، ولا حُذِف أو أُضعِف أي اختبار قائم في أي مكان.

### 6) تأكيد عدم بدء Phase 8

لم يبدأ أي عمل يخص Phase 8 أو أي مرحلة/وحدة تتجاوز نطاق Settlements Core وتصحيحاته إطلاقًا في هذه الجلسة. كل تغيير في هذا الملحق مقصور حصرًا على: (أ) 5 ترحيلات SQL تصحيحية (0192–0196) ضمن وحدة Settlements فقط، (ب) تعديلات UI/Server Actions محدودة ضمن `src/features/settlements/` و`master-data/settlement-routes` فقط، (ج) اختبارات/سكربتات تحقُّق لنفس الوحدة فقط، (د) إصلاح عيبين صغيرين وُجدا أثناء الاختبار ضمن نفس الوحدة بالضبط. لا Reports/Dashboard نهائي، لا PDF/Excel، لا Inventory، لا Salla، لا Carrier/Bank APIs، لا Attachments/Backups/2FA، ولا أي مرحلة جديدة.

### 7) خلاصة الملحق الحادي والثلاثون

تصحيح نهائي دقيق ومحدود النطاق فوق Patch 7.1، يغلق 6 نقاط ضعف حقيقية (منها 4 حرجة) في الجدول الزمني النقدي التاريخي، نطاق المتجر، الخصوصية، وتكافؤ المعاينة لِSettlements Core — مع اكتشاف وإصلاح فعلي لعيبين صغيرين إضافيين أثناء الاختبار نفسه (لا أثناء الكتابة). **5 ترحيلات جديدة (0192–0196، بلا أي تعديل — ولو بايت واحد — على 0001–0191، مؤكَّد آليًا بايت-لبايت) + 68/68 PASS اختبار SQL قائم مُحدَّث + 12/12 PASS اختبار SQL جديد كليًا + تزامن حقيقي A–K بلا تعديل (12/12 PASS) + 282 تأكيد HTTP حقيقي (31 جديد) + 265/265 Vitest (25 ملفًا، +36 اختبارًا، صفر انحدار) + عيبان صغيران وُجدا وأُصلِحا (موثَّقان بالكامل) + حارس float نقدي مُشدَّد ليشمل `.refine()` صراحة + 4/4 اختبارات أمان ترقية + 9/9 اختبارات ترقية إجمالًا بلا انحدار + 89/89 عمود NUMERIC + TypeScript/ESLint/بناء إنتاجي نظيفة بالكامل — كل رقم من تشغيل فعلي أُعيد تنفيذه نظيفًا في الساعات الأخيرة من هذه الجلسة تحديدًا. صفر ملفات محذوفة، 10 جديدة، 17 مُعدَّلة. لم يبدأ Phase 8 ولا أي عمل خارج النطاق. لم يُحذَف ولم يُضعَف أي اختبار قائم. العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP كامل للمشروع.**

---

## الملحق الثاني والثلاثون — "Phase 7 — Final Historical Route Snapshot Hotfix 7.1.2": ثبات مسار عكس رسوم مرتجَعات المبيعات التاريخي (ترحيلتان 0197–0198)

هذا الملحق يوثِّق **Hotfix 7.1.2** — تصحيح نهائي دقيق ومحدود النطاق فوق Hotfix 7.1.1 (الملحق الحادي والثلاثون أعلاه) يغلق ثغرة حرجة واحدة وُجدت في مراجعة مستقلة لاحقة على مستوى الـSource/Diff لأرشيف Hotfix 7.1.1 المُسلَّم: `return_fee_reversal`/`return_fee_reversal_reversal` (بعد تصحيح 0192 لتمر عبر "مسار البيع الأصلي") كانتا لا تزالان تقرآن `sales_orders.payment_method_id`/`collection_channel_id` **لحظيًا** وقت الاكتشاف، لا Snapshot تاريخيًا حقيقيًا — وبما أن قفل 0084 المالي يمنع تعديل البيع فقط أثناء `status='approved'` (لا `'reversed'`)، فبإمكان تعديل بيع بعد عكس مرتجَعه إداريًا أن يُغيِّر رجعيًا المسار الذي يُطابِقه حدث عكس رسم تاريخي مُعتمَد بالفعل. **قاعدة التجميد هذه الجولة صارمة كسابقاتها: 0001–0196 مُجمَّدة بالكامل بلا أي استثناء، مؤكَّدة بايت-لبايت.** كل عمل جديد بدأ حصرًا من **0197**. تفاصيل الاختبار الكاملة بالأرقام الفعلية (كلها من تشغيل فعلي في هذه الجلسة) في `TEST_RESULTS_HOTFIX_7_1_2.md`. العمل **متوقف الآن نهائيًا**: **"لا تبدأ Phase 8. توقف بعد التسليم وانتظر المراجعة."**

### 1) الترحيلتان الجديدتان (0197–0198) — جدول كامل

| # | الترحيلة | الغرض المختصر |
|---|---|---|
| 0197 | `sales_returns_collection_channel_snapshot_hotfix_7_1_2.sql` | عمود جديد `collection_channel_id_snapshot` على `sales_returns` (نظير `payment_method_id` القائم تمامًا)؛ التقاط سلطوي عبر `BEFORE INSERT`؛ Backfill تاريخي حتمي عبر `audit_logs` (لا نسخ أعمى للحالة الحالية) مع فحص تكامل إلزامي مقابل `payment_method_id` كمرساة؛ `NOT NULL` بعد التحقق؛ ثبات دائم عبر `BEFORE UPDATE` (حتى ضد `service_role`). مُغلَّفة بمعاملة صريحة (استثناء متعمَّد عن اتفاقية autocommit المُعتادة، لضمان عدم ترك حالة وسيطة مكسورة إن فشل الـBackfill). |
| 0198 | `settlement_source_adapter_hotfix_7_1_2.sql` | `CREATE OR REPLACE` لِ`_settlement_unsettled_source_candidates()` (نفس التوقيع تمامًا) — مرشِّحا `return_fee_reversal`/`_reversal` وحدهما تغيَّرا: المطابقة أصبحت عبر عمودَي Snapshot الخاصَّين بـ`sales_returns` نفسها (`payment_method_id`، `collection_channel_id_snapshot`) — بلا `join` إلى `sales_orders` إطلاقًا. `return_refund_event`/`_reversal` بلا أي تغيير. |

**لا استثناء على التجميد:** لم تُعدَّل أي ترحيلة من 0001–0196 إطلاقًا.

### 2) الخوارزمية الحتمية لإعادة بناء التاريخ (§5)

الـBackfill **لا** ينسخ قناة البيع الحالية أعمى — لكل مرتجَع قائم: (أ) يبحث عن **أول** صف `audit_logs` بِـ`action='sale.update'` لنفس البيع بتاريخ `created_at >= sales_return.created_at` (أول تعديل للبيع عند/بعد إنشاء هذا المرتجَع بالضبط) ويقرأ `old_values.collection_channel_id`/`old_values.payment_method_id` منه — القيمة **قبل** ذلك التعديل مباشرة، أي بالضبط حالة البيع وقت إنشاء المرتجَع؛ (ب) إن لم يوجد صف كهذا، لم يتغيَّر شيء منذ الإنشاء — القيمة الحالية اللحظية آمنة كما هي. **فحص تكامل إلزامي (§6):** يُعاد بناء `payment_method_id` بنفس الخوارزمية بالضبط، ويُقارَن بعمود `sales_returns.payment_method_id` الموجود مسبقًا (Snapshot موثوق أصلًا منذ 0082/0100) — أي عدم تطابق يُفشِل الترحيلة **بأكملها** برسالة تُسمِّي كل مرتجَع/بيع متعارض، بدل تخمين قناة تاريخية لا يمكن الوثوق بها.

### 3) نتائج الاختبار (التفصيل الكامل في `TEST_RESULTS_HOTFIX_7_1_2.md`)

- **اختبار SQL جديد كليًا (`settlements_hotfix_7_1_2.test.sql`، 451 سطرًا):** سيناريو A–G الحي (بيع أ/أ → مرتجَع → اعتماد → عكس → تعديل البيع لاحقًا إلى ب/ب → الاكتشاف يبقى على المسار أ حصرًا) + اختبار التعديل المباشر الموثوق (§10، حتى `service_role`) + اختبار المرتجَع المعلَّق (§12 — موثَّق حيًّا أن حارسًا حقيقيًا موجودًا مسبقًا في `approve_sales_return()` يمنع هذا السيناريو تحديدًا، بدل تلفيق اختبار حوله) — **8/8 PASS، Exit 0**.
- **اختبارات SQL القائمة (Phase 7 + Hotfix 7.1.1 + تزامن A-K + حزمة Returns/Sales كاملة):** بلا أي تعديل مطلوب — **صفر انحدار، Exit 0 للجميع**.
- **HTTP/PostgREST حقيقي:** قسم "Part 16" جديد (بندان a/b) فوق "Part 15" القائم، يُثبِت انقسام الاكتشاف Route A/Route B حيًّا عبر HTTP فعلي وثبات العمود الجديد حتى لـ`service_role` — **289 تأكيد OK إجمالًا (8 جديدة)، Exit 0**.
- **React/Vitest:** لا سلوك جديد يواجه الواجهة — **265/265، صفر تغيير مطلوب**.
- **اختبارات أمان الترقية:** الخمسة A/B/C/D/E (E جديد كليًا — يُثبِت الخلل حقيقيًا على بيانات حقيقية **قبل** الترقية ثم إصلاحه على **نفس** البيانات **بعد** الترقية، مع إعادة بناء تاريخي وليس نسخًا للحالة الحالية) + 5 سكربتات ترقية أقدم غير متعلقة — **10/10 PASSED، Exit 0**.
- **TypeScript/ESLint/NUMERIC/بناء إنتاجي:** الأربعة **نظيفة بالكامل**.

### 4) الملفات الجديدة/المُعدَّلة/المحذوفة — مقارنة كاملة مقابل `gold-erp-hotfix-7-1-1-settlements.zip`

**محذوفة: لا شيء إطلاقًا (0 ملف).**

**جديدة بالكامل (7 ملفات):** ترحيلتان (`0197`–`0198`، جدول §1 أعلاه)؛ `scripts/run_upgrade_test_hotfix_7_1_2_settlements.sh`؛ `supabase/tests/fixtures/hotfix_7_1_2_upgrade_pre_fixture.sql`؛ `supabase/tests/settlements_hotfix_7_1_2.test.sql`؛ `supabase/tests/upgrade_hotfix_7_1_2_settlements.test.sql`؛ `TEST_RESULTS_HOTFIX_7_1_2.md`.

**مُعدَّلة (4 ملفات):** `scripts/postgrest-http-test.mjs` (قسم "Part 16" جديد)؛ `supabase/tests/postgrest_http_test_setup.sql` (طريقة دفع + قناة تحصيل نشطتان إضافيتان لِRoute B)؛ `src/types/database.ts` (إضافة `collection_channel_id_snapshot`)؛ `DELIVERY_REPORT.md` (هذا الملحق).

**لم يتغيَّر إطلاقًا:** أي ترحيلة من 0001–0196 (مؤكَّد byte-for-byte)، `supabase/seed.sql`، `.env.example`، `supabase/tests/settlements_phase7.test.sql`/`settlements_hotfix_7_1_1.test.sql`/`settlements_phase7_concurrency.test.sql`، أي ملف Vitest، أي وحدة خارج Settlements/Returns، ولا حُذِف أو أُضعِف أي اختبار قائم.

### 5) تأكيد عدم بدء Phase 8

لم يبدأ أي عمل يخص Phase 8 أو أي مرحلة/وحدة تتجاوز نطاق Settlements/Returns وتصحيحاتها إطلاقًا. كل تغيير مقصور حصرًا على: (أ) ترحيلتان SQL تصحيحيتان (0197–0198)، (ب) اختبارات/سكربتات تحقُّق لنفس الوحدة، (ج) تعديل نوع TypeScript واحد يعكس العمود الجديد. لا Reports/Dashboard نهائي، لا PDF/Excel، لا Inventory، لا Salla، لا Carrier/Bank APIs، لا Attachments/Backups/2FA، ولا أي مرحلة جديدة.

### 6) خلاصة الملحق الثاني والثلاثون

تصحيح نهائي دقيق ومحدود النطاق جدًا فوق Hotfix 7.1.1، يغلق ثغرة حرجة واحدة في ثبات المسار التاريخي لأحداث عكس الرسم — منح `collection_channel_id_snapshot` بنفس ضمانات `payment_method_id` القائمة تمامًا (التقاط سلطوي عند الإنشاء، ثبات دائم مفروض بمُشغِّل ضد كل الأدوار، إعادة بناء تاريخي حتمي عبر `audit_logs` مع مرساة تكامل إلزامية بدل تخمين). **ترحيلتان جديدتان فقط (0197–0198، بلا أي تعديل — ولو بايت واحد — على 0001–0196، مؤكَّد آليًا بايت-لبايت) + 8/8 PASS اختبار SQL جديد كليًا + صفر انحدار على كل اختبار SQL/Returns/Sales قائم + 289 تأكيد HTTP حقيقي (8 جديدة) + 265/265 Vitest (صفر تغيير مطلوب) + 5/5 اختبارات أمان ترقية (E جديد كليًا يُثبِت الانجراف الحقيقي قبل الترقية وإصلاحه بعدها على نفس البيانات، لا فِكستشر اصطناعي) + 5/5 اختبارات ترقية أقدم بلا انحدار (10/10 إجمالًا) + 89/89 عمود NUMERIC + TypeScript/ESLint/بناء إنتاجي نظيفة بالكامل — كل رقم من تشغيل فعلي في هذه الجلسة تحديدًا. صفر ملفات محذوفة، 7 جديدة، 4 مُعدَّلة. لم يبدأ Phase 8 ولا أي عمل خارج النطاق. لم يُحذَف ولم يُضعَف أي اختبار قائم. العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP كامل للمشروع.**

---

## الملحق الثالث والثلاثون — "Phase 7 — Final Pending-Refresh Consistency Hotfix 7.1.3": مزامنة قناة التحصيل مع أساس المرتجَع المالي (تعديل مباشر داخل 0197–0198 غير المُعتمَدتين)

هذا الملحق يوثِّق **Hotfix 7.1.3** — مراجعة المستخدم المستقلة على مستوى الكود/الـdiff لأرشيف Hotfix 7.1.2 المُسلَّم (وليس تقارير الاختبار فقط) كشفت أن تصميم 0197 الأصلي افترض خطأً أن `sales_returns.payment_method_id` Snapshot **دائم منذ الإنشاء** — بينما الدالة السلطوية القائمة مسبقًا `refresh_pending_sales_return_from_sale()` (0100، مُجمَّدة ضمن 0001–0196) تُعيد مزامنة هذا العمود تحديدًا مع حالة البيع الحالية عند استدعائها على مرتجَع معلَّق، ما يجعل `collection_channel_id_snapshot` (0197) عرضة لزوج (طريقة دفع، قناة) **مستحيل تاريخيًا** بعد أي Pending Refresh سليم. **قاعدة التجميد المرجعية تبقى 0001–0196 كسابقاتها بلا أي استثناء (مؤكَّدة بايت-لبايت هذه المرة ضد الأرشيف الفعلي `gold-erp-hotfix-7-1-2-settlements.zip`، SHA-256 `19c50ca3ee525229c9235113f1b4def9def889e44c5a2cc51d6ac8e2593f272c`، مُتحقَّق منه مطابقًا) — لكن، بتفويض صريح من المستخدم، وبما أن 0197–0198 لم تُعتمَدا بعد والخلل يقع داخل عقد 0197 نفسه (بحيث لا يمكن لأي ترحيلة لاحقة افتراضية 0199 تغطيته قبل أن تصل 0197 نفسها إليه بأمان)، عُدِّلت 0197/0198 في مكانهما مباشرة — بالقدر الأدنى اللازم فقط، بلا إنشاء 0199، وبلا أي مساس بترحيلة واحدة من 0001–0196.** تفاصيل الاختبار الكاملة بالأرقام الفعلية (كلها من تشغيل فعلي في هذه الجلسة) في `TEST_RESULTS_HOTFIX_7_1_3.md`. العمل **متوقف الآن نهائيًا**: **"لا تبدأ Phase 8. توقف بعد التسليم وانتظر المراجعة."**

### 1) التعديل داخل 0197–0198 — جدول كامل

| # | الترحيلة | التغيير |
|---|---|---|
| 0197 | `sales_returns_collection_channel_snapshot_hotfix_7_1_2.sql` | Part A/B (العمود + `BEFORE INSERT`) بلا تغيير — سليمة أصلًا. **Part C (Backfill) أُعيد تصميمها بالكامل:** بدل "أول تعديل بعد `created_at`"، إعادة البناء الآن تُطابِق `audit_logs.new_values.row_version` مع `sales_returns.source_sale_row_version` **الخاص بالمرتجَع نفسه** بالضبط (المصدران المُعتمَدان: `sale.create`/`sale.update`)، مع سقوط آمن صريح عند تطابق حالة البيع الحالية فقط، وفشل صريح للترحيلة بأكملها (لا تخمين) عند عدم توفر أي دليل. **Part D بلا تغيير. Part E (المُشغِّل) أُعيد تصميمه بالكامل:** يتعرَّف الآن على انتقال Pending Refresh السليم (الشكل الدقيق لِتحديث 0100) ويُعيد اشتقاق العمود سلطويًا من حالة البيع الحالية المقفولة، ويرفض أي محاولة أخرى بلا استثناء — حتى `service_role`. |
| 0198 | `settlement_source_adapter_hotfix_7_1_2.sql` | منطق SQL بلا أي تغيير (كان صحيحًا أصلًا) — تعليقات فقط أُصلِحت لتصف الدلالة الصحيحة (يتحرَّك مع الأساس حتى نهاية دورة الانتظار، لا تجميد منذ الإنشاء). |

**لا 0199 أُنشِئت.** لم تُعدَّل أي ترحيلة من 0001–0196.

### 2) خوارزمية إعادة البناء المُصحَّحة (§7/§8)

مطابقة `audit_logs.new_values.row_version` مع `source_sale_row_version` **الخاص بكل مرتجَع على حِدة** (لا موقعًا زمنيًا ثابتًا) — تُغطِّي بذلك أساسًا من `sale.create` (`row_version=1`) وأساسًا من `sale.update` (أي `row_version` لاحق) بنفس الاستعلام. سقوط آمن صريح فقط عند تطابق حالة البيع الحالية تمامًا؛ **فشل صريح للترحيلة بأكملها** (مُثبَت حيًّا بفِكستشر مُخرَّب عمدًا، §5.2 من ملف الاختبار) عند عدم توفر أي دليل — لا تخمين إطلاقًا، ولا سقوط للخوارزمية القديمة الخاطئة.

### 3) نتائج الاختبار (التفصيل الكامل في `TEST_RESULTS_HOTFIX_7_1_3.md`)

- **اختبار SQL جديد كليًا (`settlements_hotfix_7_1_3.test.sql`):** سيناريو Pending Refresh A–G الحي + ثبات ما بعد الاعتماد + اختبار تعدد التحديث (§13) + التعديل المباشر الموثوق — **15/15 PASS، Exit 0**.
- **`settlements_hotfix_7_1_2.test.sql` القائم (بلا تعديل حرف واحد):** **8/8 PASS كما كانت** — صفر انحدار.
- **31 ملف SQL قائم آخر (26 ذاتي الاكتفاء + 5 تزامن حقيقي):** **صفر انحدار، Exit 0 للجميع.**
- **HTTP/PostgREST حقيقي:** قسم "Part 17" جديد (بنود A–I) يُثبِت دورة حياة Pending Refresh الكاملة حيًّا — **299 تأكيد OK إجمالًا (10 جديدة)، Exit 0**.
- **React/Vitest:** لا سلوك جديد يواجه الواجهة — **265/265، صفر تغيير مطلوب.**
- **اختبارات أمان الترقية:** A/B/C/D بلا انحدار + **E جديد كليًا يُدمِج §11 (refreshed-pending) وَ§13 (multi-refresh) مع §12 القائم في ترقية واحدة حقيقية** + **إثبات §14 الحاسم: فِكستشر مُخرَّب عمدًا يُثبِت أن 0197 تفشل صراحةً (لا تخمين) عند تلف دليل التاريخ، مع تراجع نظيف تام (بلا حالة جزئية)** — **12/12 PASSED، Exit 0 للجميع.**
- **TypeScript/ESLint/NUMERIC/بناء إنتاجي:** الأربعة **نظيفة بالكامل، بلا أي تعديل مطلوب.**

### 4) الملفات الجديدة/المُعدَّلة/المحذوفة — مقارنة كاملة مقابل `gold-erp-hotfix-7-1-2-settlements.zip` (الأرشيف الفعلي، مؤكَّد SHA-256)

**محذوفة: لا شيء إطلاقًا (0 ملف).**

**جديدة بالكامل (7 ملفات):** `supabase/tests/settlements_hotfix_7_1_3.test.sql`؛ `supabase/tests/fixtures/hotfix_7_1_3_upgrade_pre_fixture.sql`؛ `supabase/tests/fixtures/hotfix_7_1_3_upgrade_broken_fixture.sql`؛ `supabase/tests/upgrade_hotfix_7_1_3_settlements.test.sql`؛ `scripts/run_upgrade_test_hotfix_7_1_3_settlements.sh`؛ `scripts/run_upgrade_test_hotfix_7_1_3_broken_fixture.sh`؛ `TEST_RESULTS_HOTFIX_7_1_3.md`.

**مُعدَّلة في مكانها (4 ملفات):** `supabase/migrations/0197_...sql` (Backfill + مُشغِّل UPDATE أُعيد تصميمهما، غير مُعتمَدة بعد، تعديل مُفوَّض صراحة)؛ `supabase/migrations/0198_...sql` (تعليقات فقط)؛ `scripts/postgrest-http-test.mjs` (قسم "Part 17")؛ `supabase/tests/postgrest_http_test_setup.sql` (طريقة دفع + قناة تحصيل نشطتان إضافيتان لِRoute C)؛ `DELIVERY_REPORT.md` (هذا الملحق).

**لم يتغيَّر إطلاقًا:** أي ترحيلة من 0001–0196 (مؤكَّد byte-for-byte ضد الأرشيف الفعلي)، `supabase/seed.sql`، `.env.example`، `src/types/database.ts` (لا عمود جديد هذه الجولة)، `supabase/tests/settlements_hotfix_7_1_2.test.sql`، ولا حُذِف أو أُضعِف أي اختبار قائم.

### 5) تأكيد عدم بدء Phase 8

لم يبدأ أي عمل يخص Phase 8 أو أي مرحلة/وحدة تتجاوز نطاق Settlements/Returns وتصحيحاتها إطلاقًا. كل تغيير مقصور حصرًا على: (أ) تعديل مُفوَّض صراحةً داخل عقد 0197/0198 غير المُعتمَدتين، (ب) اختبارات/سكربتات تحقُّق لنفس الوحدة فقط. **لا `0199` أو أي ترحيلة جديدة.** لا Reports/Dashboard نهائي، لا PDF/Excel، لا Inventory، لا Salla، لا Carrier/Bank APIs، لا Attachments/Backups/2FA، ولا أي مرحلة جديدة.

### 6) خلاصة الملحق الثالث والثلاثون

**خلاصة الملحق الثالث والثلاثون:** تصحيح دقيق داخل عقد 0197–0198 غير المُعتمَدتين بعد (لا 0199، لا مساس بـ0001–0196 المؤكَّد بايت-لبايت ضد الأرشيف الفعلي المُسلَّم سابقًا)، يغلق الافتراض الخاطئ بأن `collection_channel_id_snapshot` دائم منذ الإنشاء — يمنحه الآن دلالة "الأساس الحالي" الصحيحة، متحركًا مع `payment_method_id`/`source_sale_row_version` عبر أي Pending Refresh سليم، ومتجمِّدًا معهما فقط عند خروج المرتجَع نهائيًا من دورة الانتظار. **15/15 PASS اختبار SQL جديد كليًا + 8/8 PASS إعادة تشغيل اختبار 7.1.2 القائم بلا تعديل + 31/31 ملف SQL قائم بلا انحدار + 299 تأكيد HTTP حقيقي (10 جديدة) + 265/265 Vitest (صفر تغيير) + 12/12 سكربت أمان ترقية PASSED (شامل سيناريوَي §11/§13 المُدمَجين حقيقيًا مع §12 القائم، زائد إثبات §14 الحاسم لمسار الفشل الصريح النظيف بلا تخمين) + 89/89 عمود NUMERIC + TypeScript/ESLint/بناء إنتاجي نظيفة بالكامل — كل رقم من تشغيل فعلي في هذه الجلسة تحديدًا. صفر ملفات محذوفة، 7 جديدة، 4 مُعدَّلة (اثنتان منها 0197/0198 أنفسهما، مُفوَّض التعديل صراحة). لم يبدأ Phase 8 ولا أي عمل خارج النطاق. لم يُحذَف ولم يُضعَف أي اختبار قائم. العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP كامل للمشروع.**

---

## الملحق الرابع والثلاثون — "Phase 8 — Reports, Dashboard & Exports": طبقة الاستخبارات الإدارية (تقارير مالية/تشغيلية + تصدير PDF/Excel)

هذا الملحق يوثِّق **Phase 8 كاملة** — أول Phase منذ Hotfix 7.1.3 (الملحق الثالث والثلاثون أعلاه)، وأول عمل يبدأ ترحيلات جديدة بعد تجميد 0001–0198. الهدف: طبقة استخبارات إدارية للقراءة فقط (Reports + Dashboard + Export) فوق كل البيانات التشغيلية المُنتَجة عبر Phases 1–7 (المبيعات/المرتجعات/الشحن/التعديلات/التسويات) — بلا أي تعديل على أي جدول أو دالة إنتاجية قائمة، وبلا أي كتابة بيانات جديدة على الإطلاق (كل شيء `SECURITY DEFINER STABLE`، قراءة بحتة). **قاعدة التجميد صارمة كسابقاتها: 0001–0198 مُجمَّدة بالكامل بلا أي استثناء — تحقُّق مباشر `diff`/`sha256sum` لكل ملف من الـ198 ضد آخر أرشيف مُعتمَد (`gold-erp-hotfix-7-1-3-settlements.zip`)، صفر اختلاف واحد.** كل عمل جديد بدأ حصرًا من **0199**. تفاصيل الاختبار الكاملة بالأرقام الفعلية (كلها من تشغيل فعلي في هذه الجلسة، أُعيد تنفيذه نظيفًا بالكامل في نهايتها) في `TEST_RESULTS_PHASE_8_REPORTS_DASHBOARD.md`. العمل **متوقف الآن نهائيًا**: **"لا تبدأ Phase 9. توقف بعد التسليم وانتظر المراجعة."**

### 1) الترحيلات الست الجديدة (0199–0204) — جدول كامل

| # | الترحيلة | الغرض المختصر |
|---|---|---|
| 0199 | `reports_foundation_helpers_and_lookups.sql` | الأساس المشترك لكل التقارير: `_report_resolve_store_filter()` (رفض صريح، لا تضييق صامت، لأي `store_ids` خارج نطاق رؤية الممثِّل — §8/§9)، `report_visible_stores_lookup()` (بحث نطاق المتاجر بلا حاجة لصلاحية `stores.view`)، صلاحيات `reports.view`/`reports.export_pdf`/`reports.export_excel` الجديدة. |
| 0200 | `dashboard_summary_trends_and_comparisons.sql` | `get_dashboard_summary()`/`get_dashboard_trends()` — لوحة التحكم الرئيسية: مبيعات/مرتجعات/شحن/تعديلات/تسويات + "صافي العائد التشغيلي" (Net Operating Return) المُجمَّع، مع مؤشِّر الأساس (§83) وحجب حقول لكل نطاق صلاحية مستقل (`dashboard.view_financials`, `sales.view_profit`, ...) عبر غياب مفتاح حقيقي (§79) لا `null`. |
| 0201 | `sales_items_categories_karats_employees_reports.sql` | 7 تقارير جانب المبيعات: `get_sales_report()`, `get_items_report()`, `get_categories_report()`, `get_karats_report()`, `get_employees_report()`, وتقريرا ترتيب مرتبطان — كلها بنفس عقد الحجب/الأساس. |
| 0202 | `payment_methods_channels_returns_reports.sql` | `get_payment_methods_report()`, `get_collection_channels_report()`, `get_returns_report()` — الأخير سجل حركة (Movements Ledger) يُوازن كل عكس/إلغاء بتاريخه التجاري الخاص (§85)، لا تاريخ الاكتشاف. |
| 0203 | `shipping_cod_adjustments_reports.sql` | `get_shipping_report()`, `get_cod_report()`, `get_adjustments_report()` (سجل حركة مُوازِن أيضًا لصافي التعديلات). |
| 0204 | `settlements_daily_weekly_monthly_yearly_reports.sql` | `get_settlements_report()` (ثنائي الأساس، يُطابِق `get_dashboard_summary()` رقميًا حرفيًا — §39/§80) + 4 تقارير إدارية مُجمَّعة (يومي/أسبوعي/شهري/سنوي) تُفوِّض كلها لنفس دالة `get_dashboard_summary()` السلطوية بلا إعادة حساب مستقلة (§39 محرِّك تقارير واحد). |

**إضافة-فقط مؤكَّدة:** فحص `grep` مباشر عبر الترحيلات الست يؤكِّد صفر حالة `ALTER TABLE`/`DROP TABLE`/`DROP COLUMN`/`ADD COLUMN`/`CREATE TABLE` — كل الترحيلات تقتصر على `CREATE OR REPLACE FUNCTION`/`COMMENT ON FUNCTION`/`REVOKE`/`GRANT EXECUTE`. لم تُعدَّل أي ترحيلة من 0001–0198 إطلاقًا.

### 2) الركائز المعمارية الأربع (§39/§40-41/§79/§83) وطبقة التصدير

- **محرِّك تقارير واحد (§39):** كل شكل عرض إداري (اليومي/الأسبوعي/الشهري/السنوي، ولوحة التحكم نفسها) يُفوِّض حسابيًا لنفس دالة `get_dashboard_summary()` السلطوية القائمة — لا نسخة حساب ثانية موازية يمكن أن تنحرف عنها رقميًا مع الوقت. مُثبَت حيًّا عبر `reports_detail_golden_scenario.test.sql` PASS F/E (تطابق رقمي حرفي بين `get_settlements_report()` والداشبورد لكلا الأساسين).
- **حدود النقل العشري (§40/§41):** كل حقل مالي/وزني يعبر الحدود من Postgres إلى المتصفح كسلسلة نصية (`text`/`numeric`→JSON string عبر PostgREST) — أُثبِت عدم وجود أي `Number(`/`parseFloat(`/`parseInt(` في طبقة `queries.ts` (الحارس الجديد، القسم 5 أدناه) وعبر قيمة اصطناعية بعرض 27 رقمًا معنويًا (تتجاوز دقة `IEEE-754 double`) تعبر بلا أي تقريب، حيًّا عبر HTTP حقيقي (Part 18 item A) وفي اختبار الوحدة (runtime).
- **الغياب الحقيقي للمفتاح (§79):** كل حقل مالي محجوب بصلاحية غائبة (`gross_profit` بلا `sales.view_profit`، `net_operating_return` بلا `dashboard.view_financials`، إلخ) يغيب **كمفتاح كائن بالكامل** — لا `null` ولا `0` — مُثبَت عبر عامل `in` الفعلي على الكائن القادم من HTTP حقيقي (Part 18 items B/C/E/F) وفي PDF/Excel المُصدَّرين (عمود كامل يغيب من الجدول، لا خلية فارغة).
- **مؤشِّر أساس التقرير (§83):** كل استجابة تحمل `basis` صريحًا (`current_effective_impact_within_period` أو ثنائي الأساس للتسويات) يعرضه `ReportBasisBadge` نصًّا مقروءًا بدل ترك المستخدم يخمن أي منهجية محاسبية يراها.
- **طبقة التصدير (§44):** `src/features/reports/export/pdf.ts` (PDFKit + خط Amiri العربي المُضمَّن، ترقيم صفحات تلقائي `stampFooters`) و`excel.ts` (ExcelJS، خلايا رقمية حقيقية بدقة عشرية كاملة لا نصوص مُنسَّقة) يُغذَّيان من سجل تعريف واحد (`report-registry.ts`/`management-registry.ts`) يضمن أن كل تنسيق عمود (`money`/`weight`/`int`/`date`/`text`/`badge`) معروف ومُطبَّق فعليًا — لا تمريرة `number` خام أبدًا. `src/app/api/reports/export/route.ts` هو نقطة الدخول الوحيدة، مقيَّدة بصلاحيتَي `reports.export_pdf`/`reports.export_excel`.

### 3) نتائج الاختبار (التفصيل الكامل بكل النصوص الحية في `TEST_RESULTS_PHASE_8_REPORTS_DASHBOARD.md`)

- **تجميد 0001–0198:** 198/198 ملف مطابق بايت-لباَيت (diff فارغ + تحقُّق sha256 عيِّني على 0001/0100/0198).
- **اختبارات SQL (29 ملف، قاعدة بيانات نظيفة مستقلة لكل ملف — الاتفاقية القائمة):** 29/29 Exit 0، منها اختباران جديدان كليًا: `reports_dashboard_golden_scenario.test.sql` (7/7 PASS A–G) و`reports_detail_golden_scenario.test.sql` (8/8 PASS A–H)، زائد `upgrade_phase8_reports_dashboard.test.sql` (21 دالة تقرير آمنة على بيانات `seed.sql` وحدها، بلا أي فِكستشر خاص). صفر انحدار على أي ملف من Phases 1–7 (بعد تصحيح منهجي: كل ملف على قاعدة بيانات خاصة به، لتفادي تلوُّث بيانات اختبارات التزامن الحقيقية عبر `dblink` التي تُنفِّذ `COMMIT` فعليًا).
- **اختبارات ترقية القاعدة التاريخية:** 11/11 سكربت Exit 0 — يؤكِّد أن 6 ترحيلات Phase 8 آمنة تمامًا فوق أي قاعدة تاريخية من أي Phase سابق.
- **HTTP/PostgREST حقيقي:** قسم "Part 18" جديد (البنود A–G) فوق Parts 1–17 القائمة بلا أي تعديل — **322 تأكيد `OK` إجمالًا (23 جديدة)**، يُثبِت حيًّا مؤشِّر الأساس، حدود النقل العشري، الغياب الحقيقي للمفتاح بأشكاله الأربعة (حقل مالي واحد/قسم كامل/جذر الاستجابة/استقلال كل نطاق صلاحية عن الآخر)، والرفض الصريح لفلتر متجر خارج النطاق.
- **Vitest:** 316/316 عبر 28 ملفًا (265 قائمة بلا أي تعديل + 51 جديدة عبر 3 ملفات — تصدير PDF/Excel حقيقي مع قراءة عكسية عبر ExcelJS، مكوِّنات العرض المشتركة، وامتداد حارس "no-JS-float" لطبقة القراءة بشكل مُصمَّم مختلف عمدًا عن حارس الكتابة في Settlements).
- **TypeScript/ESLint/Next Build/فحص الأنواع الرقمية:** الأربعة نظيفة بالكامل (صفر خطأ TypeScript، صفر خطأ ESLint (4 تحذيرات قائمة مسبقًا غير متعلقة)، بناء إنتاجي ناجح لكل مسارات `/reports/*` (16) + `/dashboard` + `/api/reports/export`، 89/89 عمود NUMERIC مطابق).

### 4) الملفات الجديدة/المُعدَّلة/المحذوفة — مقارنة كاملة مقابل `gold-erp-hotfix-7-1-3-settlements.zip`

**محذوفة: لا شيء إطلاقًا (0 ملف).**

**جديدة بالكامل (~40 ملفًا):**
ست ترحيلات (`0199`–`0204`، جدول §1 أعلاه)؛
17 صفحة تقرير/لوحة تحكم تحت `src/app/(app)/reports/*/page.tsx` (فهرس + 16 تقريرًا: `sales`, `items`, `categories`, `karats`, `employees`, `payment-methods`, `collection-channels`, `returns`, `shipping`, `cod`, `adjustments`, `settlements`, `daily`, `weekly`, `monthly`, `yearly`) و`src/app/(app)/dashboard/page.tsx`؛
طبقة `src/features/reports/` كاملة (`queries.ts`, `url.ts`, `components/period-picker.tsx`, `report-basis-badge.tsx`, `report-export-buttons.tsx`, `report-filter-bar.tsx`, `report-summary-cards.tsx`, `report-table.tsx`, `export/report-registry.ts`, `export/management-registry.ts`, `export/pdf.ts`, `export/excel.ts`)؛
طبقة `src/features/dashboard/` (`queries.ts`, `components/kpi-section.tsx`, `net-operating-return-card.tsx`)؛
`src/app/api/reports/export/route.ts`؛
خط Amiri العربي المُضمَّن (`src/assets/fonts/Amiri-Regular.ttf`, `Amiri-Bold.ttf`, `Amiri-OFL-LICENSE.txt`)؛
3 ملفات اختبار Vitest جديدة (`tests/reports-export-generation.test.ts`, `tests/reports-dashboard-components.test.tsx`, `tests/reports-dashboard-money-string-invariant.test.ts`)؛
2 اختبار SQL جديد + اختبار ترقية جديد (`supabase/tests/reports_dashboard_golden_scenario.test.sql`, `reports_detail_golden_scenario.test.sql`, `upgrade_phase8_reports_dashboard.test.sql`)؛
`TEST_RESULTS_PHASE_8_REPORTS_DASHBOARD.md`.

**مُعدَّلة (5 ملفات):** `scripts/postgrest-http-test.mjs` (قسم "Part 18" جديد، ~180 سطرًا، بنود A–G)؛ `supabase/tests/postgrest_http_test_setup.sql` (منح صلاحيات Phase 8 لثلاثة ممثِّلين موجودين مسبقًا — لا ممثِّلون/UUIDs جدد)؛ `package.json`/`package-lock.json` (إضافة `exceljs@^4.4.0`, `pdfkit@^0.20.1`, `@types/pdfkit@^0.17.6`)؛ `DELIVERY_REPORT.md` (هذا الملحق).

**لم يتغيَّر إطلاقًا:** أي ترحيلة من 0001–0198 (مؤكَّد byte-for-byte)، `supabase/seed.sql`، `.env.example`، `src/types/database.ts` (لا عمود جدول جديد — Phase 8 لا يُنشئ أي جدول)، أي ملف اختبار قائم من Phases 1–7 (265 اختبار Vitest + 26 ملف SQL ذاتي الاكتفاء + 5 ملفات تزامن حقيقي)، ولا حُذِف أو أُضعِف أي اختبار قائم.

### 5) تأكيد عدم بدء Phase 9

لم يبدأ أي عمل يخص Phase 9 أو أي وحدة محظورة إطلاقًا. كل تغيير مقصور حصرًا على طبقة Reports/Dashboard/Export للقراءة فقط، فوق البيانات التشغيلية القائمة من Phases 1–7، بلا أي جدول جديد وبلا أي كتابة بيانات. **لا Inventory، لا Salla API، لا Carrier API، لا Bank API، لا GL، لا Attachments، لا Backups، لا 2FA، ولا أي مرحلة جديدة بعد هذا التسليم.**

### 6) خلاصة الملحق الرابع والثلاثون

**خلاصة الملحق الرابع والثلاثون:** طبقة استخبارات إدارية كاملة (Reports + Dashboard + تصدير PDF/Excel) فوق ست ترحيلات إضافة-فقط جديدة كليًا (0199–0204، بلا أي مساس — ولو بايت واحد — بـ0001–0198 المُجمَّدة، مؤكَّد آليًا بايت-لباَيت)، تُطبِّق أربع ركائز معمارية بشكل مُثبَت حيًّا: محرِّك تقارير واحد بلا حساب مزدوج (§39)، حدود نقل عشري بلا أي تقريب JS عبر HTTP حقيقي بعرض 27 رقمًا معنويًا (§40/§41)، غياب حقيقي للمفتاح بأربعة أشكال مختلفة مُثبَتة حيًّا (§79)، ومؤشِّر أساس تقرير صريح (§83) — زائد طبقة تصدير PDF/Excel حقيقية (لا محاكاة) بخط عربي مُضمَّن ودقة عشرية كاملة في خلايا Excel الرقمية. **7/7 + 8/8 PASS اختباري SQL جديدين كليًا (سيناريو ذهبي مالي مُتحقَّق يدويًا) + Exit 0 لِـ21 دالة تقرير على بيانات ترقية تاريخية بلا أي فِكستشر خاص + 29/29 ملف SQL قائم بلا انحدار (بعد تصحيح منهجي لتلوُّث بيانات تزامن حقيقي بين الملفات) + 11/11 سكربت أمان ترقية + 322 تأكيد HTTP حقيقي (23 جديدة عبر Part 18) + 316/316 Vitest (51 جديدة عبر 3 ملفات، بما فيها قراءة عكسية PDF/Excel حقيقية عبر ExcelJS وامتداد حارس "no-JS-float" مُصمَّم خصيصًا لطبقة القراءة) + 89/89 عمود NUMERIC + TypeScript/ESLint/بناء إنتاجي نظيفة بالكامل — كل رقم من تشغيل فعلي في هذه الجلسة تحديدًا، أُعيد تنفيذه نظيفًا في نهايتها. صفر ملفات محذوفة، نحو 40 ملفًا جديدًا، 5 مُعدَّلة. لم يبدأ Phase 9 ولا أي عمل خارج النطاق. لم يُحذَف ولم يُضعَف أي اختبار قائم. العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP كامل للمشروع.**

---

## الملحق الخامس والثلاثون — "Phase 8 — Integrity Patch 8.1": الخصوصية المالية + سلامة تاريخ الحدث + اكتمال عقد التصدير والتقارير

هذا الملحق يوثِّق **Patch 8.1 كاملة** — أول باتش تصحيحي فوق طبقة Reports/Dashboard/Export التي سلَّمها Phase 8 (الملحق الرابع والثلاثون أعلاه). الهدف: عشر ترحيلات إضافة-فقط (0205–0214) تُشدِّد مصفوفة الخصوصية المالية، تُصحِّح الأساس الزمني لعدة تقارير من ذاكرة الحالة الحالية (Current-State Cache) إلى سجل حركة حقيقي مؤرَّخ بتاريخه التجاري الخاص (Event Date، §85)، تُغلِق فجوة تصدير كانت تُبتِر النتائج صامتًا، وتُصلِح عيب أداء حقيقي (N+1) اكتُشف بالقياس لا بالتخمين. **قاعدة التجميد صارمة كسابقاتها: 0001–0212 مُجمَّدة بالكامل — تحقُّق مباشر عبر مقارنة الشجرة الكاملة ضد آخر أرشيف مُسلَّم فعليًا (`gold-erp-phase8-reports-dashboard.zip`) يؤكِّد صفر اختلاف على أي ترحيلة من 0001–0204؛ وترحيلتا 0213/0214 هما الوحيدتان المُضافتان تحديدًا خلال الجلسة الأخيرة من هذا الباتش (0205–0212 أُنجزت في جلسات سابقة من نفس Patch 8.1 قبل تلخيص المحادثة، وأُعيد التحقُّق منها بالكامل في هذه الجلسة أيضًا).** تفاصيل الاختبار الكاملة بالأرقام الفعلية في `TEST_RESULTS_PATCH_8_1.md`. العمل **متوقف الآن نهائيًا**: **"لا تبدأ Phase 9. توقف بعد التسليم وانتظر المراجعة."**

### 1) الترحيلات العشر الجديدة (0205–0214) — جدول كامل

| # | الترحيلة | الغرض المختصر |
|---|---|---|
| 0205 | `dashboard_privacy_trend_clipping_shipping_movements.sql` | تشديد مصفوفة الخصوصية المالية (§1-3): `net_shipping_result`/`carrier_cost_effect` و`net_adjustments_result`/`direct_costs` في `get_dashboard_summary()`/الاتجاهات أصبحا يتطلَّبان `dashboard.view_financials` **و** `sales.view_profit` معًا (مطابقة تامة لعتبة `get_shipping_report()`/`get_adjustments_report()` الحالية على مستوى الصف)؛ تصحيح قصّ نطاق الاتجاهات الزمنية (§9) عبر `effective_start`/`effective_end` بدل الحدود التقويمية الخام؛ الشحن الآن مصدره `_report_shipping_profit_movements()` المؤرَّخ بالحدث لا ذاكرة `shipment_date`. |
| 0206 | `shipping_report_dual_basis_and_export_cap.sql` | `get_shipping_report()` يكتسب `p_basis` (§7-8): `current_effective` (الافتراضي، بلا تغيير) أو `movements_during_period` (سجل حركة مالية صفًّا بصف). سقف التصدير يرتفع 500 → 5000 (§11-14/§60). |
| 0207 | `payment_methods_report_rebuild.sql` | إعادة بناء `get_payment_methods_report()`/`get_collection_channels_report()` (§22-25/§64): جانب المبيعات/النقد الفعلي المُسترَد/التسويات مفصولة صراحة لا مُدمَجة في رقم "ربح" واحد مُضلِّل، هوية الزوج (طريقة الدفع + قناة التحصيل) لتجميع المبيعات. |
| 0208 | `returns_report_dual_basis.sql` | `get_returns_report()` يكتسب `p_basis` (§26-29): `business_effect` (الافتراضي، الأثر المحاسبي كما هو) أو `actual_cash` (جديد — سجل النقد الفعلي من `sales_return_refund_events` الحقيقي، لا الأثر المحسوب). |
| 0209 | `cod_report_canonical_transitions.sql` | `get_cod_report()` يكتسب `p_basis` (§30-32/§65): `current_effective` (الافتراضي) أو `collection_transitions` (جديد — سجل انتقالات `shipment_cod_events` المؤرَّخ الحقيقي بدل ذاكرة `cod_collection_state` الحالية فقط). |
| 0210 | `sales_report_profit_split_and_employee_attribution.sql` | `get_sales_report()`: فصل الربح الأصلي عن الربح الفعلي (§33-36) وتصحيح نسبة البائع (§66) على أساس دفعة المبيعات (Sales Cohort). توقيع بلا تغيير — `CREATE OR REPLACE` مباشرة. |
| 0211 | `categories_karats_historical_snapshots_and_hierarchy.sql` | تسميات الفئة/العيار التاريخية (§37) لا تُعاد كتابتها بإعادة تسمية بيانات رئيسية لاحقة، زائد التسلسل الهرمي للفئة (§38/§67) عبر `parent_id` الموجود أصلًا. |
| 0212 | `settlements_report_effective_status_and_filters.sql` | `get_settlements_report()`: `p_effective_status` (§41) — أول فلتر "ملغاة" يعمل فعليًا (`settlement_batches.status` لا يمكن أن يكون `'cancelled'` حرفيًا أبدًا — القيمة مُشتقَّة من وجود صف إلغاء)، زائد مجموعة فلاتر كاملة (`p_route_kind`/`p_payment_method_id`/`p_collection_channel_id`/`p_shipping_carrier_id`/`p_has_variance`/`p_provider_statement_reference`). |
| 0213 | `report_shipping_zones_lookup.sql` | `report_shipping_zones_lookup()` — دالة بحث جديدة كليًا سدَّت الثغرة الوحيدة التي فاتت 0199 (فلتر `p_shipping_zone_id` في `get_shipping_report()` كان موجودًا منذ 0203 بلا دالة بحث تُغذِّي قائمته المنسدلة). |
| 0214 | `sales_report_performance_optimization.sql` | إصلاح أداء حقيقي (§50-51/§71): استبدال 6 استعلامات فرعية مترابطة لكل صف بِ`GROUP BY CTE` مُجمَّعة مرة واحدة — **3515.8ms → 308.7ms (11.4×)** عند القياس الفعلي على 10,500 طلب. توقيع بلا تغيير — `CREATE OR REPLACE`. |

**إضافة-فقط مؤكَّدة:** فحص مباشر عبر العشر ترحيلات يؤكِّد صفر حالة `ALTER TABLE`/`DROP TABLE`/`DROP COLUMN`/`ADD COLUMN`/`CREATE TABLE` — فقط `CREATE [OR REPLACE] FUNCTION`/`DROP FUNCTION IF EXISTS <توقيع دقيق>` (عند تغيُّر التوقيع فقط، §0)/`COMMENT`/`REVOKE`/`GRANT EXECUTE`. لم تُعدَّل أي ترحيلة من 0001–0204 إطلاقًا (مؤكَّد عبر مقارنة شجرة كاملة ضد الأرشيف الفعلي، صفر اختلاف).

### 2) الركائز الأربع الجديدة لهذا الباتش

- **الخصوصية المالية المزدوجة (§1-3):** كل حقل تكلفة/ربح في Shipping و Adjustments داخل `get_dashboard_summary()` أصبح يتطلَّب صلاحيتين معًا (`dashboard.view_financials` + `sales.view_profit`) بدل واحدة، مطابقة تامة لعتبة تقارير الصف التفصيلية المقابلة — إغلاق تناقض كان موجودًا منذ 0200. مُثبَت حيًّا عبر HTTP حقيقي (Part 18 item F، بعد تصحيح تأكيد قديم فات عليه هذا التشديد نفسه — انظر `TEST_RESULTS_PATCH_8_1.md` §2).
- **سلامة تاريخ الحدث بأساس مزدوج صريح (§7-8/§26-32/§85):** Shipping/Returns/COD الثلاثة اكتسبت `p_basis` يتيح التبديل بين "الحالة الحالية" (الافتراضي، بلا تغيير) و"سجل الحركات المؤرَّخ بحدثه الخاص" — كل حركة عكس/إلغاء تُوازَن بتاريخها التجاري الخاص لا تاريخ اكتشافها، مطابقة للاتفاقية الراسخة أصلًا في Adjustments/Settlements.
- **اكتمال عقد التصدير (§60-62/§68-69):** سقف الصفوف رفع من 500 إلى 5000 عبر 6 دوال تقرير، مع تأكيد حقيقي هذه الجلسة (اختبار تكامل Vitest جديد يستدعي معالج `GET /api/reports/export` الفعلي نفسه) أن تجاوز السقف يُعيد `422 export_too_large` صريحًا لا ملفًّا مبتورًا صامتًا، وأن حجب الأعمدة (§61/§62) يعمل عبر المسار الإنتاجي الفعلي لا مُحاكاة معزولة فقط.
- **إصلاح أداء مُثبَت بالقياس لا بالتخمين (§50-51/§71):** عيب N+1 حقيقي في `get_sales_report()` اكتُشف عبر فِكستشر أداء بمقياس واقعي (10,500 طلب)، أُصلِح بإعادة كتابة الاستعلام (توقيع بلا تغيير)، وأُعيد التحقُّق من تطابق كل رقم مالي حرفيًا قبل/بعد الإصلاح عبر السيناريو الذهبي — **11.4× تحسُّن**، زائد إثبات جديد هذه الجلسة عبر HTTP حقيقي (Part 19 item F) أن ترقيم الصفحات بعد الإعادة كتابة لا يُكرِّر ولا يُسقِط أي صف.

### 3) نتائج الاختبار (التفصيل الكامل في `TEST_RESULTS_PATCH_8_1.md`)

- **اختبارات SQL:** **42/42 ملف PASS** — الحزمة الكاملة تحت `supabase/tests/` بلا استثناء واحد (27 ملفًا ذاتي الاكتفاء دفعة واحدة + 11 سكربت أمان ترقية عبر تسلسل هجرة جزئي صحيح + 5 اختبارات تزامن حقيقي عبر `dblink` على قاعدة بيانات مستقلة)، بما فيها الاختبارات الجديدة كليًا لهذا الباتش: `reports_golden_scenario_extended.test.sql` (§8 نطاق المتجر على بيانات حقيقية متعددة المتاجر + §79 الغياب الحقيقي للمفتاح على 6 دوال تقرير لم تُختبَر من قبل)، `upgrade_phase8_multidomain.test.sql` (بيانات تاريخية حقيقية متعددة النطاقات عبر RPCs قديمة، مُهاجَرة، ثم مقروءة عبر دوال Phase 8 الجديدة بأرقام معروفة مسبقًا)، `performance_reports_dashboard.test.sql` (10 دوال تقرير/لوحة تحكم مقابل سقوف زمنية صارمة). صفر انحدار على أي اختبار من أي Phase سابق.
- **HTTP/PostgREST حقيقي:** قسم **"Part 19" جديد كليًا (18 تأكيدًا، البنود A–F)** فوق Parts 1–18 القائمة — **341/341 تأكيد `OK` إجمالًا، صفر `FAIL`** — يُثبِت حيًّا `report_shipping_zones_lookup()` الجديدة، قوائم `p_basis` المنسدلة الثلاث (Shipping/Returns/COD)، فلاتر `get_settlements_report()` الجديدة، وتطابق ترقيم صفحات `get_sales_report()` بلا تكرار/فقدان بعد إعادة كتابة الأداء. اكتُشف وصُحِّح أثناء إعادة التشغيل تأكيد قديم واحد فات عليه تشديد الخصوصية في 0205 (تفصيل كامل في `TEST_RESULTS_PATCH_8_1.md` §2) — إصلاح اختبار، لا إصلاح كود إنتاجي.
- **Vitest:** **406/406 PASS عبر 32 ملفًا** (390 قائمة + اختباران جديدان كليًا هذه الجلسة: `tests/reports-export-route-integration.test.ts` — تكامل حقيقي على معالج التصدير الفعلي نفسه، §68-69 — و`tests/report-filter-bar-and-period-picker.test.tsx` — يُغلِق الفجوة الأخيرة بين مكوِّنات التقارير المشتركة الخمسة، §70).
- **TypeScript/ESLint/فحص الأنواع الرقمية:** الثلاثة نظيفة بالكامل (صفر خطأ TypeScript، صفر خطأ ESLint، 89/89 عمود NUMERIC مطابق).
- **الأداء:** `get_sales_report()` — **3515.8ms → 308.7ms (11.4×)** على 10,500 طلب، زائد 9 دوال تقرير/لوحة تحكم أخرى، جميعها ضمن سقوفها الزمنية (تفصيل كامل في `PERFORMANCE_RESULTS_PATCH_8_1.md`).
- **سلامة التحزيم:** عيب تحزيم حقيقي (لا افتراضي) اكتُشف بفحص مباشر لآخر أرشيف مُسلَّم فعليًا — `.env.example`/`next-env.d.ts` كانا غائبين تمامًا رغم وجودهما الصحيح في شجرة العمل — جذره تحزيم قائم على استبعاد git بدلًا من قائمة استبعاد صريحة، أُصلِح عبر `scripts/build_delivery_zip.sh` الجديد ببوابة سلامة قبل/بعد (تفصيل كامل في `PACKAGING_INTEGRITY_PATCH_8_1.md`).

### 4) الملفات الجديدة/المُعدَّلة/المحذوفة — مقارنة كاملة مقابل `gold-erp-phase8-reports-dashboard.zip`

**محذوفة: لا شيء إطلاقًا (0 ملف).**

**جديدة بالكامل (~29 ملفًا):** عشر ترحيلات (`0205`–`0214`، جدول §1 أعلاه)؛ `src/features/dashboard/components/period-presets.tsx`؛ `scripts/build_delivery_zip.sh`؛ `scripts/run_upgrade_test_phase8_multidomain.sh`؛ `supabase/tests/fixtures/{phase8_golden_scenario_multistore_extension,phase8_performance_fixture,phase8_upgrade_pre_fixture}.sql`؛ `supabase/tests/{performance_reports_dashboard,reports_golden_scenario_extended,upgrade_phase8_multidomain}.test.sql`؛ `tests/{dashboard-period-presets,report-url-typed-filters,reports-export-route-integration}.test.ts`؛ `tests/report-filter-bar-and-period-picker.test.tsx`؛ `PACKAGING_INTEGRITY_PATCH_8_1.md`؛ `PERFORMANCE_RESULTS_PATCH_8_1.md`؛ `TEST_RESULTS_PATCH_8_1.md`؛ `.env.example`/`next-env.d.ts` (يظهران "جديدَين" هنا فقط لأنهما كانا غائبَين عن الأرشيف السابق بسبب عيب التحزيم الموصوف أعلاه — لم يُفقَدا من شجرة العمل قط).

**مُعدَّلة في مكانها (~25 ملفًا):** `scripts/postgrest-http-test.mjs` (قسم "Part 19" الجديد + تصحيح تأكيد Part 18 item F القديم)؛ صفحات `dashboard/page.tsx` و`reports/{cod,returns,settlements,shipping}/page.tsx`؛ `src/app/api/reports/export/route.ts`؛ مكوِّنات لوحة التحكم (`kpi-section`, `net-operating-return-card`, `trend-chart`) والتقارير المشتركة (`report-basis-badge`, `report-filter-bar`, `report-summary-cards`, `report-table`)؛ `excel.ts`/`pdf.ts`/`report-registry.ts`/`queries.ts`/`url.ts` تحت `src/features/reports/`؛ `src/lib/decimal.ts`؛ `src/types/database.ts`؛ `tests/{decimal,reports-dashboard-components,reports-dashboard-money-string-invariant,reports-export-generation}.test.ts(x)`؛ `DELIVERY_REPORT.md` (هذا الملحق).

**لم يتغيَّر إطلاقًا:** أي ترحيلة من 0001–0204 (مؤكَّد byte-for-byte ضد الأرشيف الفعلي)، `supabase/seed.sql`، أي اختبار قائم من Phases 1–7 (390 اختبار Vitest + 30 ملف SQL ذاتي الاكتفاء + 11 سكربت ترقية + 5 ملفات تزامن حقيقي من قبل هذا الباتش)، ولا حُذِف أو أُضعِف أي اختبار قائم.

### 5) تأكيد عدم بدء Phase 9

لم يبدأ أي عمل يخص Phase 9 أو أي وحدة محظورة إطلاقًا (Inventory، Salla API، Carrier API، Bank API، GL، Attachments، Backups، 2FA، ميزات المزامنة، Forecasting/AI، CRM، Payroll). كل تغيير مقصور حصرًا على تشديد/تصحيح/إكمال عقد طبقة Reports/Dashboard/Export القائمة من Phase 8 — لا جدول جديد، لا كتابة بيانات جديدة، لا حقل بيانات إنتاجي جديد.

### 6) خلاصة الملحق الخامس والثلاثون

**خلاصة الملحق الخامس والثلاثون:** عشر ترحيلات إضافة-فقط جديدة كليًا (0205–0214، بلا أي مساس — ولو بايت واحد — بـ0001–0204 المُجمَّدة، مؤكَّد آليًا عبر مقارنة شجرة كاملة) تُشدِّد مصفوفة الخصوصية المالية (§1-3، تطابق تام مع عتبة تقارير الصف)، تُضيف أساسًا مزدوجًا صريحًا لثلاثة تقارير (Shipping/Returns/COD، §7-8/§26-32) يفصل "الحالة الحالية" عن "سجل الحركة المؤرَّخ بحدثه الخاص" (§85)، تُغلِق فجوة بحث المنطقة الشحنية الوحيدة المتبقية، وتُصلِح عيب أداء N+1 حقيقي مُثبَت بالقياس (11.4×) لا بالتخمين. **42/42 ملف SQL PASS (الحزمة الكاملة بلا استثناء) + 341/341 تأكيد HTTP حقيقي PASS (18 جديدة عبر "Part 19"، زائد إصلاح تأكيد قديم فات عليه تحديث ترحيلة سابقة من نفس الباتش) + 406/406 Vitest PASS عبر 32 ملفًا (اختبار تكامل حقيقي جديد على معالج التصدير الفعلي + إغلاق الفجوة الأخيرة في تغطية مكوِّنات React المشتركة) + TypeScript/ESLint/فحص الأنواع الرقمية نظيفة بالكامل + عيب تحزيم حقيقي اكتُشف ومُعالَج بنيويًّا — كل رقم من تشغيل فعلي في هذه الجلسة تحديدًا، أُعيد تنفيذه نظيفًا في نهايتها بعد آخر تعديل على أي ملف. صفر ملفات محذوفة، نحو 29 ملفًا جديدًا، نحو 25 مُعدَّلة. لم يبدأ Phase 9 ولا أي عمل خارج النطاق. لم يُحذَف ولم يُضعَف أي اختبار قائم. العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP كامل للمشروع.**

---

## الملحق السادس والثلاثون — "Phase 8 — Final Integrity Hotfix 8.1.1": الأساس المُفسَّر متعدد الأقسام + اكتمال التصدير + سلامة العكس الكانوني في COD/Settlements

هذا الملحق يوثِّق **Hotfix 8.1.1 كاملة** — الهوتفكس الثاني فوق طبقة Reports/Dashboard/Export (بعد Patch 8.1، الملحق الخامس والثلاثون أعلاه)، مُنفَّذ بعد أن أثبتت مراجعة مستقلة لـPatch 8.1 المُسلَّمة (SHA-256 `7fa1bf08853902c5bdf209e75dbd2afa224f30b2a526bab1e883740b011bb348`، مؤكَّد مطابقًا للأرشيف الفعلي على القرص) أن **"Phase 8 غير معتمدة بعد"**. الهدف: ست ترحيلات إضافة-فقط (0215–0220) تُقيم مُحلِّل عرض تقرير واحد أساسي/متعدد الأقسام (§1/§5/§46)، تُعيد بناء تقرير طرق الدفع الثلاثي الأقسام ببوابات صلاحية مستقلة لكل قسم (§6-10)، ترفع سقف التصدير 500 → 5000 مع حارس `export_incomplete_dataset` صريح (§11-14)، تُصلِح "الانعكاس الوهمي" الكانوني في COD (§23-26) وتُطبِّق نفس منطق التسميات التاريخية على Payment Methods (§27)، تُكمِل مجموعة فلاتر Settlements/Adjustments (§28-35)، وتُصحِّح دلالة `refund_method_id` المعتمدة على الأساس في Returns (§36). **قاعدة التجميد صارمة كسابقاتها: 0001–0214 مُجمَّدة بالكامل — تحقُّق مباشر عبر `diff` بايت-لباَيت لكل ترحيلة من الـ214 ضد الأرشيف الفعلي `gold-erp-patch-8-1-reports-dashboard.zip` يؤكِّد صفر اختلاف على الإطلاق؛ الترحيلات الست 0215–0220 هي الوحيدة المُضافة.** تفاصيل الاختبار الكاملة بالأرقام الفعلية في `TEST_RESULTS_HOTFIX_8_1_1.md`. العمل **متوقف الآن نهائيًا**: **"لا تبدأ Phase 9. توقف بعد التسليم وانتظر المراجعة."**

### 1) الترحيلات الست الجديدة (0215–0220) — جدول كامل

| # | الترحيلة | الغرض المختصر |
|---|---|---|
| 0215 | `items_adjustments_export_cap_and_filters.sql` | سقف تصدير `get_items_report()`/`get_adjustments_report()` يرتفع 500 → 5000 (§11-14/§60)؛ `get_adjustments_report()` يكتسب مجموعة فلاتر كاملة جديدة (§32-35: `p_original_sale_store_id`, `p_processing_store_id`, `p_payment_method_id`, `p_collection_channel_id`, `p_participates_in_settlement`, `p_movement_type`, `p_created_by`, `p_approved_by`) — توقيع مُغيَّر، `DROP FUNCTION` + `CREATE` صريح. |
| 0216 | `cod_report_canonical_reversal_and_historical_labels.sql` | §23-26 CRITICAL — إصلاح "الانعكاس الوهمي" في `collection_transitions`: العكس الحقيقي الوحيد هو `collected→not_collected` صراحةً؛ أي انتقال آخر (`collected→expected`, `collected→unknown`, إلخ) أثره صفر ويُستبعَد كليًا من الصفوف بدل احتسابه انعكاسًا زائفًا. زائد §27 تسميات Settlement التاريخية من لقطة الدفعة لا من ربط حي. |
| 0217 | `payment_methods_settlement_historical_labels.sql` | نفس إصلاح التسميات التاريخية (§27) لقسم Settlement داخل `get_payment_methods_report()` تحديدًا. |
| 0218 | `settlements_report_filtered_summary_and_draft.sql` | §28-31 CRITICAL — `filtered_batch_scope` واحدة تُطبَّق مرة واحدة فتُغذِّي Rows **و** الملخَّص المالي معًا (لا يمكن أن يختلفا بعد اليوم)؛ `p_effective_status='draft'` فلتر حقيقي يعمل (كان كودًا ميتًا سابقًا)؛ `has_variance` من ممثِّل بلا `settlements.view_financials` يُرفَض صراحةً بدل التجاهل الصامت. |
| 0219 | `returns_report_filter_semantics.sql` | §36 — `refund_method_id` أصبح بلا أثر تحت أساس `business_effect` (يُصفِّي على طريقة البيع الأصلية فقط)، وبالأثر الصحيح تحت `actual_cash` فقط. |
| 0220 | `report_settlement_store_scope_draft_zero_lines_fix.sql` | **إصلاح إضافي اكتشفته كتابة الاختبار الذاتي أثناء هذا الهوتفكس** — تفصيل كامل في القسم 6 أدناه. |

**إضافة-فقط مؤكَّدة:** فحص مباشر (`grep`) عبر الست ترحيلات يؤكِّد صفر حالة `ALTER TABLE`/`DROP TABLE`/`DROP COLUMN`/`ADD COLUMN`/`CREATE TABLE` — فقط `CREATE [OR REPLACE] FUNCTION`/`DROP FUNCTION IF EXISTS <توقيع دقيق>` (عند تغيُّر التوقيع فقط، §0)/`COMMENT`/`REVOKE`/`GRANT EXECUTE`. لم تُعدَّل أي ترحيلة من 0001–0214 إطلاقًا (مؤكَّد عبر `diff` بايت-لباَيت لكل ملف على حدة، صفر اختلاف).

### 2) الركائز المعمارية الأربع لهذا الهوتفكس

- **مُحلِّل عرض تقرير واحد أساسي/متعدد الأقسام (§1/§5/§46):** `src/features/reports/export/presentation.ts` (جديد كليًا) يوحِّد منطق "أي الأقسام تُعرَض، بأي تسميات، بأي بيانات تعريف مُحلَّة" لكل من الشاشة (`report-sections.tsx` الجديد) والتصدير (`excel.ts`/`pdf.ts` المُعاد بناؤهما بالكامل) — تقرير طرق الدفع (§6-10) هو أول مستهلك حقيقي: ثلاثة أقسام (مبيعات/نقد مُسترَد فعليًا/تسويات) كل واحد منها مُبوَّب بصلاحية مستقلة تمامًا عن الآخرَين (`sales.view` منفصل عن `returns.view` منفصل عن `settlements.view`)، مع بوابة أساسية واحدة (`reports.view` فقط، **لا** `sales.view` أبدًا) تحكم الوصول لأصل التقرير — مُثبَت حيًّا عبر HTTP حقيقي (القسم 4 أدناه، البند F).
- **اكتمال عقد التصدير (§11-22):** سقف الصفوف يرتفع من 500 إلى 5000 عبر `get_items_report()`/`get_adjustments_report()`، مع حارس `export_incomplete_dataset` صريح جديد في `src/app/api/reports/export/route.ts` يمنع تصدير مجموعة بيانات مبتورة صامتًا عند تجاوز السقف حتى الجديد؛ ملف Excel يُقسَّم الآن Summary+Data بورقتَين منفصلتَين مع `AutoFilter`/صف مُجمَّد (§15-19)؛ بيانات تعريف التصدير تحمل تسميات الفلاتر **المُحلَّة** الفعلية لا معرِّفاتها الخام (§20-22، عبر `filter-labels.ts` الجديد).
- **سلامة العكس الكانوني ودقة التسميات التاريخية (§23-27):** COD يكتسب تعريفًا صارمًا للعكس الحقيقي الوحيد (`collected→not_collected`) بدل احتساب أي انتقال آخر انعكاسًا زائفًا؛ تسميات Settlement (في كل من COD وPayment Methods) تُقرَأ الآن من لقطة الدفعة وقت الحدث لا من ربط حي قد يتغيَّر لاحقًا.
- **اكتمال مجموعة الفلاتر عبر أربعة تقارير (§28-36):** Settlements (ملخَّص مُصفَّى + فلتر `draft` حقيقي + رفض `has_variance` الصريح)، Adjustments (مجموعة فلاتر كاملة جديدة)، Returns (`refund_method_id` مُعتمِد على الأساس). كل واحدة مُثبَتة حيًّا عبر SQL + HTTP حقيقي (القسمان 1 و4).

### 3) نتائج الاختبار (التفصيل الكامل بالأرقام والاستدلال الكامل في `TEST_RESULTS_HOTFIX_8_1_1.md`)

كل رقم في هذا القسم أُعيد تنفيذه واقعيًا في هذه الجلسة تحديدًا — بما في ذلك تصحيح منهجي لخطأ تحقُّق ذاتي: أول تمريرة للحزمة الكاملة استخدمت قاعدة بيانات مشتركة واحدة لكل ملفات SQL ذاتية الاكتفاء بدل قاعدة مستقلة لكل ملف (الاتفاقية القائمة)، فأنتجت خمس حالات فشل زائفة بسبب تلوُّث بيانات من ملفات إعداد تُثبِّت بياناتها فعليًا (`financial_master_data.test.sql`, `postgrest_http_test_setup.sql`) لا تتراجع عنها؛ إعادة التنفيذ الصحيحة (قاعدة بيانات مستقلة نظيفة — مُستنسَخة عبر `CREATE DATABASE ... TEMPLATE` لتسريع الدورة — لكل ملف) أعادت **جميع** الملفات إلى PASS نظيف، مؤكِّدةً أن الحزمة سليمة فعلًا وأن `TEST_RESULTS_HOTFIX_8_1_1.md` (المكتوب في جلسة سابقة من هذا الهوتفكس نفسه) كان دقيقًا من البداية.

- **اختبارات SQL:** **44/44 ملف Exit 0** — 31 ملفًا ذاتي الاكتفاء (كل واحد على قاعدة بيانات مستقلة نظيفة مُهاجَرة بالكامل 0001–0220 + `seed.sql`) + 13 اختبار ترقية (فِكستشر ما-قبل ترحيلة معيَّنة → هجرة جزئية → تأكيد، كل واحد عبر سكربته المخصَّص، 12 منها أُعيدت بالتوازي هذه الجلسة وأكَّدت Exit 0 لكل سكربت). يتضمَّن الاختبار الجديد كليًا لهذا الهوتفكس `hotfix_8_1_1_reports_exports.test.sql` (6 أقسام: A مصفوفة تطابق COD الكانونية، B1-B4 فلاتر Settlements ورفض `has_variance`، C1-C4 مجموعة فلاتر Adjustments، D1-D3 دلالة `refund_method_id`، F1-F3 بنية صلاحيات Payment Methods) واختبار الترقية الجديد `upgrade_hotfix_8_1_1_reports.test.sql` (§60، تفصيل في `TEST_RESULTS_HOTFIX_8_1_1.md` §3) الذي يُثبِت أن إصلاحَي 0216/0220 رجعيَّا الأثر على بيانات حقيقية مكتوبة بالكامل قبل 0214. صفر انحدار على أي ملف من Phase 2 وحتى Hotfix 8.1.1.
- **HTTP/PostgREST حقيقي:** قسم **"Part 20" جديد كليًا (9 تأكيدات، البنود A–C)** فوق Parts 1–19 القائمة — **350/350 تأكيد `OK` إجمالًا، صفر `FAIL`** (مُعاد التحقُّق منه بالكامل هذه الجلسة عبر تشغيل فعلي كامل ضد PostgREST حقيقي + JWTs موقَّعة حقيقية). يُثبِت حيًّا رفع سقف التصدير عبر HTTP، وأن دفعة تسوية مسودة حقيقية تظهر الآن بمعرِّفها عبر `get_settlements_report(effective_status='draft')` بعد 0220 (كانت تُعيد صفر صفوف دائمًا قبله)، وأن `p_processing_store_id`/`p_participates_in_settlement=false` يصلان كقيم منطقية/معرِّفات حقيقية عبر HTTP لا نصوصًا مُسقَطة.
- **Vitest:** **423/423 PASS عبر 32 ملفًا** (مُعاد تنفيذه بالكامل هذه الجلسة)، منها 4 اختبارات حدود جديدة صراحةً على سقف التصدير (`51/501/1200/5000` صفًّا — القيمتان 501 و1200 كانتا سترفضان خطأً تحت السقف القديم 500) بالإضافة لأربعة اختبارات §6-10/§13/§79/§36 المُضافة في جلسة سابقة من نفس الهوتفكس.
- **TypeScript/ESLint/بناء إنتاجي:** الثلاثة نظيفة بالكامل — `tsc --noEmit` صفر خطأ، `eslint` صفر خطأ (4 تحذيرات `no-unused-vars` قائمة مسبقًا في ملف اختبار لم يُلمَس بهذا الهوتفكس)، `npm run build` ناجح بـ48 مسارًا.

### 4) الإصلاح الإضافي المُكتشَف — ترحيلة 0220 (خلاصة، التفصيل الكامل في `TEST_RESULTS_HOTFIX_8_1_1.md` §6)

أثناء كتابة اختبار §28-31 اكتُشف أن `get_settlements_report(effective_status='draft')` يُعيد صفر صفوف **دائمًا** بصرف النظر عن الفلتر، لأن دفعة مسودة حقيقية (لم تُعتمَد بعد) لها صفر أسطر بالتصميم دائمًا (`create_draft_settlement_batch()` لا تحجز شيئًا ماليًا)، والدالة الداخلية المشتركة `_report_settlement_batch_in_store_scope()` (0200) كانت تشترط `exists(...)` كأول شرط فتستبعد أي دفعة بصفر أسطر دائمًا — بينما الدالة المكافئة الصحيحة في نطاق Settlements نفسه، `_settlement_batch_all_stores_visible()` (0186)، تحمل التعليق الصريح "Vacuously true for a batch with zero lines" منذ Patch 7.1. هذا **عيب منتج حقيقي موجود مسبقًا** (لا علاقة له بهذا الهوتفكس تحديدًا سوى أنه أول من احتاج المسار الذي كشفه)، أُصلِح بمطابقة قطبية 0186 تمامًا، وأُثبِتت سلامته لكل الاستخدامات السبعة الأخرى (فرعها "صفر أسطر" كان كودًا ميتًا لها أصلًا، لأنها جميعًا تُقيِّد مصدرها لدفعات `finalized`/`reconciled` التي تملك سطرًا واحدًا على الأقل ببناء `finalize_settlement_batch()` نفسها) — مُثبَت حيًّا عبر ثلاثة مسارات مستقلة: SQL معاملي، اختبار ترقية على بيانات تاريخية، وHTTP حقيقي.

### 5) الملفات الجديدة/المُعدَّلة/المحذوفة — مقارنة كاملة مقابل `gold-erp-patch-8-1-reports-dashboard.zip`

**محذوفة: لا شيء إطلاقًا (0 ملف).**

**جديدة بالكامل (13 ملف كود + هذا التقرير):** الترحيلات الست 0215–0220 (جدول §1 أعلاه)؛ `src/features/reports/export/presentation.ts`؛ `src/features/reports/export/filter-labels.ts`؛ `src/features/reports/components/report-sections.tsx`؛ `supabase/tests/hotfix_8_1_1_reports_exports.test.sql`؛ `supabase/tests/upgrade_hotfix_8_1_1_reports.test.sql`؛ `supabase/tests/fixtures/hotfix_8_1_1_upgrade_pre_fixture.sql`؛ `scripts/run_upgrade_test_hotfix_8_1_1_reports.sh`؛ `TEST_RESULTS_HOTFIX_8_1_1.md`.

**مُعدَّلة في مكانها (18 ملفًا):** `src/features/reports/export/excel.ts` (إعادة بناء كاملة — تقسيم Summary+Data)، `pdf.ts` (عرض متعدد الأقسام)، `report-registry.ts`، `queries.ts`؛ `src/app/api/reports/export/route.ts`؛ 8 صفحات: `reports/{returns,shipping,cod,payment-methods,categories,adjustments,settlements}/page.tsx` + `dashboard/page.tsx`؛ `src/features/dashboard/components/period-presets.tsx`؛ `scripts/postgrest-http-test.mjs` (قسم "Part 20")؛ `supabase/tests/fixtures/phase8_golden_scenario_fixture.sql` (إصلاح تصلُّب تاريخ ما-قبل-موجود في الفِكستشر، غير ناتج عن هذا الهوتفكس، مُوثَّق في تعليقات الملف نفسه)؛ `tests/reports-export-generation.test.ts`، `tests/reports-export-route-integration.test.ts`؛ `DELIVERY_REPORT.md` (هذا الملحق).

**لم يتغيَّر إطلاقًا:** أي ترحيلة من 0001–0214 (مؤكَّد بايت-لباَيت ضد الأرشيف الفعلي)، `supabase/seed.sql`، `.env.example`، `src/types/database.ts` (لا جدول/عمود جديد — هذا الهوتفكس طبقة قراءة فقط)، أي اختبار قائم من Phase 2 وحتى Patch 8.1 — لم يُحذَف ولم يُضعَف أي منها.

### 6) تأكيد عدم بدء Phase 9

لم يبدأ أي عمل يخص Phase 9 أو أي وحدة محظورة إطلاقًا (Inventory، Salla API، Carrier API، Bank API، GL، Attachments، Backups، 2FA، ميزات المزامنة، Forecasting/AI، CRM، Payroll). كل تغيير مقصور حصرًا على تشديد/تصحيح/إكمال عقد طبقة Reports/Dashboard/Export القائمة من Phase 8/Patch 8.1 — لا جدول جديد، لا عمود بيانات إنتاجي جديد، لا كتابة بيانات جديدة إنتاجيًا (باستثناء المسار القياسي القائم أصلًا لدفعات `settlement_batches.status='draft'` منذ Phase 7).

### 7) خلاصة الملحق السادس والثلاثون

**خلاصة الملحق السادس والثلاثون:** ست ترحيلات إضافة-فقط جديدة كليًا (0215–0220، بلا أي مساس — ولو بايت واحد — بـ0001–0214 المُجمَّدة، مؤكَّد بايت-لباَيت لكل ملف على حدة) تُقيم مُحلِّل عرض تقرير واحد أساسي/متعدد الأقسام (§1/§5/§46) وأول مستهلك حقيقي له (Payment Methods الثلاثي الأقسام ببوابات صلاحية مستقلة، §6-10)، ترفع سقف التصدير 500 → 5000 مع حارس اكتمال بيانات صريح واكتمال بيانات تعريف الفلاتر المُحلَّة (§11-22)، تُصلِح "الانعكاس الوهمي" الكانوني في COD وتُوحِّد التسميات التاريخية عبر COD وPayment Methods (§23-27)، تُكمِل مجموعات فلاتر Settlements/Adjustments/Returns (§28-36) بما فيها إصلاح إضافي حقيقي لعيب منتج مسبق مُكتشَف أثناء الاختبار (ترحيلة 0220، تفصيل §4 أعلاه). **44/44 ملف SQL PASS (الحزمة الكاملة، مُعاد التحقُّق منها هذه الجلسة بمنهجية قاعدة-بيانات-مستقلة-لكل-ملف الصحيحة بعد تصحيح خطأ تحقُّق ذاتي أول) + 350/350 تأكيد HTTP حقيقي PASS (9 جديدة عبر "Part 20") + 423/423 Vitest PASS عبر 32 ملفًا + TypeScript/ESLint/بناء إنتاجي نظيفة بالكامل — كل رقم من تشغيل فعلي كامل في هذه الجلسة تحديدًا. صفر ملفات محذوفة، 13 ملف كود جديد + هذا التقرير، 18 مُعدَّلة. لم يبدأ Phase 9 ولا أي عمل خارج النطاق. لم يُحذَف ولم يُضعَف أي اختبار قائم. العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP كامل للمشروع.**

---

## الملحق السابع والثلاثون — "Phase 8 — Final Closure Hotfix 8.1.2": مقارنة تقويمية للوحدات، تفصيل التقارير الإدارية، تسميات الاسترداد التاريخية وإغلاق العقد (ترحيلات 0221–0226)

هذا الملحق يوثِّق **Hotfix 8.1.2 كاملة** — الهوتفكس الثالث والأخير فوق طبقة Reports/Dashboard/Export (بعد Patch 8.1 والملحق الخامس والثلاثون، وHotfix 8.1.1 والملحق السادس والثلاثون أعلاه)، مُنفَّذ فوق مواصفة إغلاق نهائي من 54 بندًا. **قاعدة التجميد صارمة كسابقاتها: 0001–0220 مُجمَّدة بالكامل — لم تُعدَّل أي ترحيلة منها، وست ترحيلات إضافة-فقط فقط (0221–0226) هي الجديدة.** تفاصيل الاختبار الكاملة بالأرقام الفعلية في `TEST_RESULTS_HOTFIX_8_1_2.md`. العمل **متوقف الآن نهائيًا**: **"لا تبدأ Phase 9. توقف بعد التسليم وانتظر المراجعة."**

### 1) الترحيلات الست الجديدة (0221–0226) — جدول كامل

| # | الترحيلة | الغرض المختصر |
|---|---|---|
| 0221 | `dashboard_calendar_comparison.sql` | §1-5 CRITICAL — `report_calendar_comparison_period()` (حساب تاريخ صِرف) يحسب الفترة السابقة الصحيحة **تقويميًا** (أسبوع رياض كامل سابق/شهر ميلادي كامل سابق/سنة ميلادية كاملة سابقة) بدل "المدى المكافئ الطول السابق مباشرة" الخاطئ لهذه الحالات الثلاث. `get_dashboard_summary_with_comparison()` تستدعي `get_dashboard_summary()` الكانونية مرتين فقط ولا تشتق رقمًا ماليًا بنفسها. **عيب حرج مُكتشَف ومُصلَح في هذه الجلسة نفسها:** `_report_recompute_comparison()` كانت تُعيد `null` لكل مجال متى ما كانت `report_pct_change()` تُعيد SQL NULL حقيقيًا (شائع جدًا) لأن `jsonb_set()` STRICT تُسقِط الاستدعاء كاملًا لأي وسيط NULL — أُصلِح بـ`coalesce(to_jsonb(...), 'null'::jsonb)`، مُثبَت عبر اختبار مباشر على 5 قيم preset. |
| 0222 | `management_reports_calendar_comparison_breakdowns.sql` | §6-15 — التقارير الإدارية الأربعة تتحوَّل لاستخدام الدالة القادرة على التقويم، وتكتسب الأسبوعي/الشهري/السنوي مصفوفة `breakdown` حقيقية عبر `get_dashboard_trends()` الموجودة دون أي تكرار حسابي. |
| 0223 | `settlement_store_visibility_vs_filter_split.sql` | §16-18 CRITICAL — فصل "الرؤية" (`_report_actor_full_store_scope()` جديدة، نطاق الممثِّل الكامل) عن "الفلتر الصريح" (`_report_settlement_batch_matches_store_filter()` جديدة، فحص ANY-line) لدفعات التسوية العابرة للمتاجر، عبر أربع دوال (`get_dashboard_summary`/`get_dashboard_trends`/`get_settlements_report`/`get_cod_report`). |
| 0224 | `returns_payment_methods_refund_historical_labels.sql` | §19-22 — `get_returns_report()`/`get_payment_methods_report()` (Refund Cash) تقرآن `refund_method_name_snapshot` (0106/0107) بدل ربط حي — إعادة تسمية طريقة استرداد لا تُشوِّه تقارير تاريخية. |
| 0225 | `payment_methods_report_original_method_filter_and_store_scope.sql` | §31-33 — توقيع مُغيَّر (`DROP`+`CREATE`): `p_payment_method_id` جديد (طريقة الدفع الأصلية) مُميَّز عن `p_refund_method_id` القائم (طريقة الاسترداد الفعلية)؛ قسم Settlement يكتسب أيضًا إصلاح §16-18 (مؤجَّل عمدًا من 0223). |
| 0226 | `items_report_salesperson_filter.sql` | §34-36 — توقيع مُغيَّر: `p_salesperson_id` جديد يُصفِّي على `sales_orders.salesperson_id` الحقيقي. |

**إضافة-فقط مؤكَّدة:** صفر `ALTER TABLE`/`DROP TABLE`/`CREATE TABLE` عبر الست ترحيلات. توقيعان فقط تغيَّرا فعليًا (`get_payment_methods_report` في 0225، `get_items_report` في 0226)، كلاهما `DROP FUNCTION IF EXISTS <التوقيع الدقيق>` + `CREATE FUNCTION` صريح (§0).

### 2) الشقّ الكامل للواجهة فوق §6-15/§41 — لا يكتفي بـSQL

بخلاف مسودة عمل مبكرة داخل هذه الجلسة نفسها اعتبرت السقف البرمجي وحده كافيًا، رُوجِعت المواصفة الأصلية فتبيَّن أنها تطلب صراحةً إعادة بناء **شاشات** التقارير الإدارية الأربعة بعرض تفصيل + مؤشر أساس + نطاق مقارنة ظاهر — فأُنجِز الشقّ الكامل:

- مكوّنان جديدان: `ManagementBreakdownTable` (جدول تفصيل، غائب تمامًا لليومي وفق عقد غياب-المفتاح-الحقيقي §79) و`ComparisonRangeNote` (نطاق المقارنة التقويمية بالعربية).
- الشاشات الأربع (`daily`/`weekly`/`monthly`/`yearly`) تعرض الآن `ReportBasisBadge` + `ComparisonRangeNote` معًا، والثلاث غير اليومية تعرض جدول التفصيل الجديد أيضًا.
- PDF/Excel: `ExportMeta.comparisonLabel` جديد + جدول/ورقة تفصيل كاملة (ترويسة مُكرَّرة في PDF، AutoFilter+صف مُجمَّد في Excel) — تكافؤ شاشة/تصدير كامل (§41/§48).

تحقُّق مباشر لبنية JSON الفعلية ضد قاعدة بيانات حقيقية مُهاجَرة كاملةً يؤكِّد كل مفتاح تقرأه هذه المكوّنات بالضبط، بما فيها تأكيد أن اليومي لا يحمل `breakdown` إطلاقًا.

### 3) الإثبات المُستند لقاعدة البيانات: >500 صف حقيقي (§37-39)

اختبار SQL جديد كليًا (`hotfix_8_1_2_row_count_proof.test.sql`) يُدرِج **550 طلب بيع حقيقي + 550 تعديل مُعتمَد حقيقي** عبر الدوال الإنتاجية الفعلية (لا إدراج خام)، ثم يُثبِت أن `get_items_report()`/`get_adjustments_report()` تُعيدان `total_count=550` **و** `rows.length=550` عند `p_limit=5000`، وأن `total_count` **يبقى** 550 الصحيح (لا يهبط لمطابقة الصفحة) عند `p_limit=500` بينما `rows.length` يُقصّ فعليًا عند 500 — إثبات مباشر أن العدّ الإجمالي لا يكذب أبدًا. مكمَّل باختبارَي Vitest جديدَين يُثبتان نفس الحجم (550 صفًا) يُصدَّر كملف Excel حقيقي (551 صفًا بالترويسة) بلا بتر عبر خط الأنابيب الحقيقي.

### 4) نتائج الاختبار (التفصيل الكامل بالأرقام في `TEST_RESULTS_HOTFIX_8_1_2.md`)

- **اختبارات SQL ذات الصلة:** **6/6 ملف PASS** (كل واحد على قاعدة بيانات مستقلة نظيفة مُهاجَرة بالكامل 0001–0226 + `seed.sql`) — الثلاثة Golden Scenario، `hotfix_8_1_1_reports_exports.test.sql` (صفر انحدار)، `hotfix_8_1_2_row_count_proof.test.sql` الجديد، و`upgrade_phase8_reports_dashboard.test.sql`. `rls_and_permissions.test.sql` (الحارس العام) أُعيد أيضًا: PASS كامل.
- **ملاحظة منهجية مسجَّلة بصراحة:** محاولة أولى لتشغيل الأرشيف التاريخي الكامل (+60 ملف) تسلسليًا على قاعدة مشتركة واحدة أنتجت فشلًا زائفًا بالجملة، مصدره أثر `dblink` المتروك عمدًا من ملفات التزامن + ملفات ترقية تحتاج سكربتها المخصَّص لا `psql -f` مباشر — لا علاقة له بكود هذا الهوتفكس. بعد التصحيح المنهجي (قاعدة معزولة لكل مجموعة، مطابقةً للاتفاقية القائمة فعليًا في المشروع)، كل ملف ذي صلة عاد PASS نظيفًا. التفصيل الكامل والاستدلال في §4 من `TEST_RESULTS_HOTFIX_8_1_2.md`.
- **الأداء:** `performance_reports_dashboard.test.sql` (10,500 طلب/365 يومًا) PASS كامل — `get_monthly_management_report` (إحدى الدوال الأربع المُعاد بناؤها) عند 250.9ms مقابل سقف 4000ms رغم استدعائها الآن `get_dashboard_summary()` مرتين بدل مرة.
- **سلامة الترقية:** تطبيقان كاملان مستقلان من الصفر لكامل الـ226 ترحيلة (صفر خطأ في الحالتين) + إعادة إنتاج مسار الترقية الفعلي (0221–0226 فوق لقطة `gold_erp_base_0220` الحقيقية). لا ترحيلة جدول/عمود في هذا الهوتفكس، فلا حاجة موضوعية لفِكستشر ترقية مخصَّص.
- **Vitest:** **427/427 PASS عبر 32 ملفًا**، منها اختباران جديدان صراحةً لِ§37-39.
- **TypeScript/ESLint/بناء إنتاجي:** الثلاثة نظيفة بالكامل — `tsc --noEmit` صفر خطأ، `eslint` صفر خطأ (4 تحذيرات قائمة مسبقًا في ملف لم يُلمَس)، `next build` ناجح بـ48 مسارًا.

### 5) الملفات الجديدة/المُعدَّلة/المحذوفة — مقارنة كاملة مقابل `gold-erp-hotfix-8-1-1-reports-dashboard.zip`

**محذوفة: لا شيء إطلاقًا (0 ملف).**

**جديدة بالكامل (9 ملف كود + هذا التقرير):** الترحيلات الست 0221–0226 (جدول §1 أعلاه)؛ `src/features/reports/components/comparison-range-note.tsx`؛ `src/features/reports/components/management-breakdown-table.tsx`؛ `supabase/tests/hotfix_8_1_2_row_count_proof.test.sql`؛ `TEST_RESULTS_HOTFIX_8_1_2.md`.

**مُعدَّلة في مكانها (18 ملفًا):** `src/types/database.ts`؛ `src/features/reports/queries.ts`؛ `src/features/reports/export/{report-registry.ts,excel.ts,pdf.ts,management-registry.ts,filter-labels.ts}`؛ `src/features/reports/components/report-filter-bar.tsx`؛ `src/app/api/reports/export/route.ts`؛ `src/app/(app)/reports/{daily,weekly,monthly,yearly,payment-methods,returns,items,page}.tsx`؛ `tests/reports-export-route-integration.test.ts`؛ `DELIVERY_REPORT.md` (هذا الملحق).

**لم يتغيَّر إطلاقًا:** أي ترحيلة من 0001–0220، `supabase/seed.sql`، `.env.example`، أي اختبار قائم من Phase 2 حتى Hotfix 8.1.1 — لم يُحذَف ولم يُضعَف أي منها.

### 6) تأكيد عدم بدء Phase 9

لم يبدأ أي عمل يخص Phase 9 أو أي وحدة محظورة (Inventory، Salla API، Carrier API، Bank API، GL، Attachments، Backups، 2FA، ميزات المزامنة، Forecasting/AI، CRM، Payroll). كل تغيير مقصور حصرًا على تشديد/إكمال عقد طبقة Reports/Dashboard/Export القائمة — لا جدول جديد، لا عمود بيانات إنتاجي جديد، لا كتابة بيانات إنتاجية جديدة.

### 7) خلاصة الملحق السابع والثلاثون

**خلاصة الملحق السابع والثلاثون:** ست ترحيلات إضافة-فقط جديدة كليًا (0221–0226، بلا أي مساس بـ0001–0220 المُجمَّدة) تُصلِح عيبًا حرجًا مُكتشَفًا ومُصلَحًا في هذه الجلسة نفسها (`_report_recompute_comparison()` STRICT-NULL)، تُقيم مقارنة تقويمية صحيحة للوحدات الثلاث عبر لوحة التحكم والتقارير الإدارية الأربعة **بشقّيها الكاملين (SQL + واجهة + تصدير)**، تفصل رؤية دفعة التسوية العابرة للمتاجر عن فلترها الصريح عبر أربع دوال، توحِّد التسميات التاريخية لطريقة الاسترداد، وتُضيف فلترين جديدين مع إثبات DB-backed حقيقي لتجاوز 500 صف بلا بتر صامت. **6/6 ملف SQL ذي صلة PASS + إثبات >500 صف حقيقي جديد + 427/427 Vitest + TypeScript/ESLint/بناء إنتاجي نظيفة بالكامل + أداء ضمن السقف بهامش واسع + سلامة ترقية مؤكَّدة بتطبيقين كاملين من الصفر** — كل رقم من تشغيل فعلي كامل في هذه الجلسة تحديدًا. صفر ملفات محذوفة، 9 ملفات جديدة، 18 مُعدَّلة. لم يبدأ Phase 9 ولا أي عمل خارج النطاق. لم يُحذَف ولم يُضعَف أي اختبار قائم. العمل متوقف الآن نهائيًا، بانتظار المراجعة والموافقة من المستخدم بعد إرسال ZIP كامل للمشروع.**

---

*نهاية التقرير.*
