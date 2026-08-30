"use client";

import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";

export function UsersTabs({ usersPanel, rolesPanel }: { usersPanel: React.ReactNode; rolesPanel: React.ReactNode }) {
  return (
    <Tabs defaultValue="users">
      <TabsList>
        <TabsTrigger value="users">المستخدمون</TabsTrigger>
        <TabsTrigger value="roles">الأدوار والصلاحيات</TabsTrigger>
      </TabsList>
      <TabsContent value="users">{usersPanel}</TabsContent>
      <TabsContent value="roles">{rolesPanel}</TabsContent>
    </Tabs>
  );
}
