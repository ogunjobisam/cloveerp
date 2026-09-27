import { useMutation } from "@tanstack/react-query";
import { useRef, useState } from "react";
import { flushSync } from "react-dom";

import { callErp } from "../../lib/erp";
import type { RenderedDocument } from "../../lib/count-worklist";

/**
 * Render a document through the door that renders it, draw it, then open the
 * print dialog on it — once. A second press while the first is rendering, or
 * while its dialog is open, is ignored rather than queued behind it as a
 * second dialog.
 *
 * The count sheet's (PR10 M3b), shared with the remittance advice (PR13 M4):
 * `door` is the public function that renders and the permission it asks, so a
 * screen can draw the button only for somebody the door would take.
 */
export function usePrintRendered(door: { readonly fn: string; readonly permission: string }) {
  const [sheet, setSheet] = useState<RenderedDocument | null>(null);
  const busy = useRef(false);
  const [printing, setPrinting] = useState(false);

  function print() {
    if (busy.current) return;
    busy.current = true;
    setPrinting(true);
    try {
      window.print();
    } finally {
      busy.current = false;
      setPrinting(false);
    }
  }

  const render = useMutation({
    mutationFn: (documentId: string) =>
      callErp<RenderedDocument>(door.fn, { p_document_id: documentId }),
    onSuccess: (rendered) => {
      // Drawn before the print dialog opens, or the paper is the last sheet.
      flushSync(() => setSheet(rendered));
      busy.current = false;
      print();
    },
    onError: () => {
      busy.current = false;
    },
  });

  function open(documentId: string) {
    if (busy.current || render.isPending) return;
    busy.current = true;
    render.mutate(documentId);
  }

  return {
    sheet,
    render,
    open,
    print,
    printing: printing || render.isPending,
    close: () => setSheet(null),
    permission: door.permission,
  };
}
