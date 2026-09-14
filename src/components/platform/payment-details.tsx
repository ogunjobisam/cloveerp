import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Landmark } from "lucide-react";
import { useState } from "react";

import { TOUCH } from "../erp/page";
import { callErp } from "../../lib/erp";
import type { PlatformRole } from "../../lib/platform";
import type { BillingDetailsRead } from "../../lib/platform-today";
import { Card, Fail, INPUT } from "./kit";

/**
 * Where contract invoices ask to be paid.
 *
 * Every invoice is emailed to the customer when it is issued (20260914097300),
 * and the email and the invoice the customer reads both carry these details.
 * Until they are set, an invoice says payment details will follow from the
 * accounts team, and Today asks for them. Everybody on the staff can read
 * them; only an owner changes them, and the platform log records that they
 * changed without the numbers.
 */

const BUTTON = `${TOUCH} inline-flex items-center justify-center gap-1.5 rounded-md bg-primary px-3 text-sm font-semibold text-primary-foreground disabled:opacity-60`;
const SECONDARY = `${TOUCH} inline-flex items-center justify-center gap-1.5 rounded-md border border-input px-3 text-sm font-medium disabled:opacity-60`;

type Form = {
  legal_name: string;
  registered_address: string;
  company_number: string;
  bank_account_name: string;
  sort_code: string;
  account_number: string;
  payment_reference_guidance: string;
};

function formFrom(d: BillingDetailsRead | undefined): Form {
  return {
    legal_name: d?.legal_name ?? "",
    registered_address: d?.registered_address ?? "",
    company_number: d?.company_number ?? "",
    bank_account_name: d?.bank_account_name ?? "",
    sort_code: d?.sort_code ?? "",
    account_number: d?.account_number ?? "",
    payment_reference_guidance: d?.payment_reference_guidance ?? "",
  };
}

export function PaymentDetails({ role }: { role: PlatformRole }) {
  const queryClient = useQueryClient();
  const isOwner = role === "owner";
  const details = useQuery({
    queryKey: ["erp_platform_billing_details"],
    queryFn: () => callErp<BillingDetailsRead>("erp_platform_billing_details"),
  });
  const [editing, setEditing] = useState(false);
  const [form, setForm] = useState<Form>(formFrom(undefined));
  const save = useMutation({
    mutationFn: (f: Form) =>
      callErp("erp_platform_set_billing_details", {
        p_legal_name: f.legal_name.trim(),
        p_registered_address: f.registered_address.trim() || null,
        p_company_number: f.company_number.trim() || null,
        p_bank_account_name: f.bank_account_name.trim(),
        p_sort_code: f.sort_code.trim(),
        p_account_number: f.account_number.trim(),
        p_payment_reference_guidance: f.payment_reference_guidance.trim() || null,
      }),
    onSuccess: () => {
      setEditing(false);
      void queryClient.invalidateQueries({ queryKey: ["erp_platform_billing_details"] });
    },
  });

  const field = (key: keyof Form, caption: string, placeholder: string, hint?: string) => (
    <label className="block text-xs font-medium">
      {caption}
      <input
        className={INPUT}
        value={form[key]}
        placeholder={placeholder}
        onChange={(e) => setForm((prev) => ({ ...prev, [key]: e.target.value }))}
      />
      {hint ? <span className="mt-1 block font-normal text-muted-foreground">{hint}</span> : null}
    </label>
  );

  return (
    <Card
      title="Payment details"
      icon={<Landmark className="size-4 text-primary" />}
      description="What every contract invoice asks to be paid into. They are shown in the invoice email and on the invoice in the customer's own agreement. Only an owner changes them."
    >
      {details.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : details.error ? (
        <Fail error={details.error} />
      ) : editing ? (
        <form
          className="flex flex-col gap-3"
          onSubmit={(e) => {
            e.preventDefault();
            save.mutate(form);
          }}
        >
          <div className="grid gap-3 sm:grid-cols-2">
            {field(
              "legal_name",
              "Company name",
              "Clove ERP Ltd",
              "As registered, printed on every invoice.",
            )}
            {field("company_number", "Company number", "12345678")}
            {field(
              "bank_account_name",
              "Account name",
              "Clove ERP Ltd",
              "The name on the bank account.",
            )}
            {field("sort_code", "Sort code", "12-34-56")}
            {field("account_number", "Account number", "12345678", "Digits only, usually eight.")}
            {field(
              "payment_reference_guidance",
              "Reference guidance",
              "Please quote the invoice reference.",
              "Shown under the reference, which every invoice already asks the customer to quote.",
            )}
          </div>
          <label className="block text-xs font-medium">
            Registered address
            <textarea
              className={`${INPUT} min-h-20`}
              value={form.registered_address}
              placeholder="The registered office, as Companies House has it"
              onChange={(e) => setForm((prev) => ({ ...prev, registered_address: e.target.value }))}
            />
          </label>
          {save.error ? <Fail error={save.error} /> : null}
          <div className="flex flex-wrap gap-2">
            <button type="submit" className={BUTTON} disabled={save.isPending}>
              {save.isPending ? "Saving…" : "Save the payment details"}
            </button>
            <button type="button" className={SECONDARY} onClick={() => setEditing(false)}>
              Cancel
            </button>
          </div>
        </form>
      ) : (
        <div className="flex flex-col gap-3">
          {details.data.set ? (
            <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
              <dt className="text-muted-foreground">Company</dt>
              <dd>
                {details.data.legal_name}
                {details.data.company_number
                  ? ` · company number ${details.data.company_number}`
                  : ""}
              </dd>
              <dt className="text-muted-foreground">Account name</dt>
              <dd>{details.data.bank_account_name}</dd>
              <dt className="text-muted-foreground">Sort code</dt>
              <dd className="font-mono">{details.data.sort_code}</dd>
              <dt className="text-muted-foreground">Account number</dt>
              <dd className="font-mono">{details.data.account_number}</dd>
              {details.data.payment_reference_guidance ? (
                <>
                  <dt className="text-muted-foreground">Reference</dt>
                  <dd>{details.data.payment_reference_guidance}</dd>
                </>
              ) : null}
              {details.data.registered_address ? (
                <>
                  <dt className="text-muted-foreground">Registered address</dt>
                  <dd className="whitespace-pre-line">{details.data.registered_address}</dd>
                </>
              ) : null}
              <dt className="text-muted-foreground">Last changed</dt>
              <dd className="text-xs text-muted-foreground">
                {details.data.updated_at
                  ? new Date(details.data.updated_at).toLocaleString("en-GB")
                  : "—"}
                {details.data.updated_by ? ` by ${details.data.updated_by}` : ""}
              </dd>
            </dl>
          ) : (
            <p className="text-sm font-medium text-destructive">
              No payment details are set, so every invoice says payment details will follow from the
              accounts team.
            </p>
          )}
          {isOwner ? (
            <button
              type="button"
              className={`${details.data.set ? SECONDARY : BUTTON} self-start`}
              onClick={() => {
                setForm(formFrom(details.data));
                setEditing(true);
              }}
            >
              {details.data.set ? "Change the payment details" : "Add payment details"}
            </button>
          ) : (
            <p className="text-xs text-muted-foreground">Only an owner can change these.</p>
          )}
        </div>
      )}
    </Card>
  );
}
