import { Landmark } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { listCollectionChannels } from "@/features/collection-channels/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Can } from "@/lib/permissions/context";
import { CollectionChannelFormDialog } from "@/features/collection-channels/components/collection-channel-form-dialog";
import { CollectionChannelStatusToggle } from "@/features/collection-channels/components/collection-channel-status-toggle";

export default async function CollectionChannelsPage() {
  await requirePermission("collection_channels.view");
  const channels = await listCollectionChannels();

  return (
    <div>
      <PageHeader
        title="قنوات التحصيل"
        description="مستقلة عن طرق الدفع — عملية بيع مستقبلية تُسجَّل بطريقة دفع وقناة تحصيل معًا (مثال: مدى – محفظة سلة)."
        actions={
          <Can permission="collection_channels.manage">
            <CollectionChannelFormDialog />
          </Can>
        }
      />

      {channels.length === 0 ? (
        <EmptyState icon={Landmark} title="لا توجد قنوات تحصيل بعد" description="ابدأ بإضافة أول قناة." />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>القناة</TableHead>
                <TableHead className="hidden sm:table-cell">المفتاح</TableHead>
                <TableHead>الحالة</TableHead>
                <TableHead className="w-24 text-left">إجراءات</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {channels.map((channel) => (
                <TableRow key={channel.id}>
                  <TableCell>
                    <div className="flex flex-col">
                      <span className="font-medium">{channel.name_ar}</span>
                      {channel.name_en && <span className="text-xs text-muted-foreground">{channel.name_en}</span>}
                    </div>
                  </TableCell>
                  <TableCell className="hidden font-mono text-xs sm:table-cell">{channel.key}</TableCell>
                  <TableCell>
                    <Badge variant={channel.status === "active" ? "success" : "secondary"}>
                      {channel.status === "active" ? "نشط" : "معطّل"}
                    </Badge>
                  </TableCell>
                  <TableCell>
                    <div className="flex items-center justify-end gap-1">
                      <Can permission="collection_channels.manage">
                        <CollectionChannelFormDialog channel={channel} />
                        <CollectionChannelStatusToggle channelId={channel.id} status={channel.status} channelName={channel.name_ar} />
                      </Can>
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
    </div>
  );
}
