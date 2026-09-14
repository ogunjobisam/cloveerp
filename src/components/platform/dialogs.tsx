import { useMutation } from "@tanstack/react-query";
import { useId, useState, type ReactNode } from "react";

import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";

import { TOUCH } from "../erp/page";
import { Fail, INPUT } from "./kit";

/**
 * The console's questions, asked in a dialog.
 *
 * Suspending an organisation, purging one, erasing an enquiry and removing a
 * member of staff were each asked with window.prompt: a browser box that cannot
 * say what is about to happen, cannot show the database's refusal, and on a
 * phone is an unlabelled text field over a page it hides. Each is one of these
 * now. The dialog stays open until the door has answered, and when it refuses
 * the refusal is shown inside it, beside the answers that were refused, so
 * nothing typed is lost to an error somewhere behind it.
 *
 * Wraps the shadcn Dialog the way components/erp/action.tsx does.
 */

export const DIALOG_PRIMARY = `${TOUCH} inline-flex items-center justify-center rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground disabled:opacity-60`;
export const DIALOG_DANGER = `${TOUCH} inline-flex items-center justify-center rounded-md bg-destructive px-4 text-sm font-semibold text-destructive-foreground disabled:opacity-60`;
export const DIALOG_SECONDARY = `${TOUCH} inline-flex items-center justify-center rounded-md border border-input px-4 text-sm font-medium disabled:opacity-60`;

export function FormDialog<T>({
  trigger,
  title,
  description,
  submitLabel,
  busyLabel = "Working…",
  danger = false,
  ready,
  run,
  onDone,
  done,
  onClosed,
  children,
}: {
  /** One element that opens the dialog: a button. */
  trigger: ReactNode;
  title: string;
  description?: ReactNode;
  submitLabel: string;
  busyLabel?: string;
  /** Drawn in red, for the ones that cannot be undone. */
  danger?: boolean;
  /** Whether what has been answered is enough to send. */
  ready: boolean;
  run: () => Promise<T>;
  /** After the door has agreed: refresh what it changed. */
  onDone?: (result: T) => void;
  /**
   * What to show once it has worked, instead of closing: a link shown once, a
   * count of what a sweep removed. Absent, the dialog closes on success.
   */
  done?: (result: T) => ReactNode;
  /** Clear the answers, so the next opening starts empty. */
  onClosed?: () => void;
  children: ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const action = useMutation({
    mutationFn: run,
    onSuccess: (result) => {
      onDone?.(result);
      if (!done) close();
    },
  });

  function close() {
    setOpen(false);
    action.reset();
    onClosed?.();
  }

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        // Never while the door is answering: what it did would be shown nowhere.
        if (!next && action.isPending) return;
        if (next) setOpen(true);
        else close();
      }}
    >
      <DialogTrigger asChild>{trigger}</DialogTrigger>
      <DialogContent className="max-h-[85vh] w-[92vw] max-w-lg overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          {description ? <DialogDescription>{description}</DialogDescription> : null}
        </DialogHeader>

        {action.isSuccess && done ? (
          <div className="flex flex-col gap-4">
            {done(action.data)}
            <div className="flex justify-end">
              <button type="button" className={DIALOG_PRIMARY} onClick={close}>
                Done
              </button>
            </div>
          </div>
        ) : (
          <form
            className="flex flex-col gap-4"
            onSubmit={(e) => {
              e.preventDefault();
              if (ready && !action.isPending) action.mutate();
            }}
          >
            {children}
            {action.error ? <Fail error={action.error} /> : null}
            <div className="flex flex-wrap justify-end gap-2">
              <button
                type="button"
                className={DIALOG_SECONDARY}
                onClick={close}
                disabled={action.isPending}
              >
                Cancel
              </button>
              <button
                type="submit"
                className={danger ? DIALOG_DANGER : DIALOG_PRIMARY}
                disabled={!ready || action.isPending}
              >
                {action.isPending ? busyLabel : submitLabel}
              </button>
            </div>
          </form>
        )}
      </DialogContent>
    </Dialog>
  );
}

/** A labelled box, the way every dialog here asks for text. */
/**
 * Console text is not tenant terminology: nothing here goes through ui(), so
 * the prop is `caption` rather than `label`, which supabase/ci/screen_strings.sh
 * reads as a string a tenant can rename.
 */
function DialogField({
  caption,
  hint,
  children,
}: {
  caption: string;
  hint?: ReactNode;
  children: (id: string) => ReactNode;
}) {
  const id = useId();
  return (
    <div className="flex flex-col gap-1">
      <label htmlFor={id} className="text-sm font-medium">
        {caption}
      </label>
      {children(id)}
      {hint ? <p className="text-xs text-muted-foreground">{hint}</p> : null}
    </div>
  );
}

/**
 * A decision with a reason: suspend, mark ended, enter, erase, remove.
 *
 * `required` where the door refuses an empty reason, which it names; the
 * button stays disabled until one is typed, which only saves the round trip.
 */
export function ReasonDialog({
  trigger,
  title,
  description,
  reasonLabel = "Reason",
  placeholder = "Recorded against your name",
  required = true,
  submitLabel,
  busyLabel,
  danger = false,
  run,
  onDone,
}: {
  trigger: ReactNode;
  title: string;
  description?: ReactNode;
  reasonLabel?: string;
  placeholder?: string;
  required?: boolean;
  submitLabel: string;
  busyLabel?: string;
  danger?: boolean;
  run: (reason: string) => Promise<unknown>;
  onDone?: () => void;
}) {
  const [reason, setReason] = useState("");
  const usable = reason.trim() !== "";
  return (
    <FormDialog
      trigger={trigger}
      title={title}
      description={description}
      submitLabel={submitLabel}
      {...(busyLabel ? { busyLabel } : {})}
      danger={danger}
      ready={!required || usable}
      run={() => run(reason.trim())}
      onDone={() => onDone?.()}
      onClosed={() => setReason("")}
    >
      <DialogField
        caption={required ? reasonLabel : `${reasonLabel} (optional)`}
        hint="Kept in the platform's activity log."
      >
        {(id) => (
          <textarea
            id={id}
            rows={3}
            required={required}
            value={reason}
            placeholder={placeholder}
            onChange={(e) => setReason(e.target.value)}
            className={INPUT}
          />
        )}
      </DialogField>
    </FormDialog>
  );
}

/**
 * The one that removes data for good. The code has to be typed, not a box
 * ticked, and a reason given; the door checks the code again and refuses an
 * organisation that is still active.
 */
export function ConfirmCodeDialog({
  trigger,
  title,
  description,
  code,
  submitLabel,
  run,
  onDone,
}: {
  trigger: ReactNode;
  title: string;
  description: ReactNode;
  code: string;
  submitLabel: string;
  run: (typed: string, reason: string) => Promise<unknown>;
  onDone?: () => void;
}) {
  const [typed, setTyped] = useState("");
  const [reason, setReason] = useState("");
  const matches = typed.trim() === code;
  return (
    <FormDialog
      trigger={trigger}
      title={title}
      description={description}
      submitLabel={submitLabel}
      danger
      ready={matches && reason.trim() !== ""}
      run={() => run(typed.trim(), reason.trim())}
      onDone={() => onDone?.()}
      onClosed={() => {
        setTyped("");
        setReason("");
      }}
    >
      <DialogField
        caption="Type the organisation's code to confirm"
        hint={
          <>
            The code is <span className="font-mono text-foreground">{code}</span>.
            {typed !== "" && !matches ? " What you have typed does not match it yet." : ""}
          </>
        }
      >
        {(id) => (
          <input
            id={id}
            autoComplete="off"
            spellCheck={false}
            value={typed}
            onChange={(e) => setTyped(e.target.value)}
            className={`${INPUT} font-mono`}
          />
        )}
      </DialogField>
      <DialogField caption="Reason" hint="Kept in the platform's activity log.">
        {(id) => (
          <textarea
            id={id}
            rows={2}
            required
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            className={INPUT}
          />
        )}
      </DialogField>
    </FormDialog>
  );
}
