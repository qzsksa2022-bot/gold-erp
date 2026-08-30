import { z } from "zod";
import { PAGE_SIZE_DEFAULT } from "@/lib/constants";

/** Shared pagination/search querystring shape used by every list page. */
export const listSearchParamsSchema = z.object({
  q: z.string().trim().optional().default(""),
  page: z.coerce.number().int().min(1).optional().default(1),
  pageSize: z.coerce.number().int().min(1).max(100).optional().default(PAGE_SIZE_DEFAULT),
});

export type ListSearchParams = z.infer<typeof listSearchParamsSchema>;
