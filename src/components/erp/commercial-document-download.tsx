import { useMutation } from "@tanstack/react-query";

import { friendlyError } from "@/lib/errors";
import {
  commercialDocumentLink,
  type CommercialDocumentLinkInput,
} from "../../lib/commercial-document.functions";
import { TOUCH } from "./page";

/**
 * "Download PDF" for an order form or invoice that was emailed.
 *
 * Asks for a five-minute signed link (src/lib/commercial-document.functions.ts)
 * only when pressed, so a screen listing twenty invoices mints nothing until
 * somebody wants one, and follows it: the link is signed as a download under
 * the document's own file name, so the browser saves it and the page stays
 * where it is. The link is shown as well, for a browser that does not follow.
 * Refusals are the database's: another organisation's document is not found.
 */
export function CommercialDocumentDownload({
  request,
  caption = "Download PDF",
  compact = false,
}: {
  request: CommercialDocumentLinkInput;
  caption?: string;
  compact?: boolean;
}) {
  const link = useMutation({
    mutationFn: () => commercialDocumentLink({ data: request }),
    onSuccess: (result) => {
      if (typeof window !== "undefined") window.location.assign(result.signedUrl);
    },
  });

  return (
    <span className="inline-flex flex-col items-start gap-1">
      <button
        type="button"
        className={
          compact
            ? "text-xs font-medium underline underline-offset-2 disabled:opacity-60"
            : `${TOUCH} inline-flex items-center rounded-md border border-input px-3 text-xs font-medium disabled:opacity-60`
        }
        disabled={link.isPending}
        onClick={() => link.mutate()}
      >
        {link.isPending ? "Preparing…" : caption}
      </button>
      {link.data ? (
        <a
          href={link.data.signedUrl}
          className="text-xs text-muted-foreground underline underline-offset-2"
          rel="noreferrer"
        >
          {link.data.filename}
        </a>
      ) : null}
      {link.error ? (
        <span role="alert" className="text-xs text-destructive">
          {friendlyError(link.error).title}
        </span>
      ) : null}
    </span>
  );
}
