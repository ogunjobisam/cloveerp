/**
 * Full and light users, as the console shows them for one organisation.
 *
 * The price list sells full users (a plan includes some, more are extra) and
 * light users (people who only approve, look at reports or count stock). The
 * database decides who is which — erp.person_seat() reads the permissions each
 * person's roles reach — and public.erp_platform_seats() returns the counts
 * with each limit and where it came from. This file only words them. Pure, so
 * the wording is tested without a browser.
 */

export type SeatLimitFrom = "contract" | "plan";

export type SeatCount = {
  used: number;
  /** Null where nothing limits it: no contract or plan says, or one says unlimited. */
  limit: number | null;
  /** Null where the organisation has neither a contract nor a plan. */
  limit_from: SeatLimitFrom | null;
};

export type PlatformSeats = {
  tenant_id: string;
  full: SeatCount;
  light: SeatCount;
};

export type SeatFigure = {
  /** The figure itself: "7", or "7 of 15" where there is a limit. */
  value: string;
  /** One short sentence under it. */
  hint: string;
  /** More in use than the contract or plan allows. */
  over: boolean;
};

export function seatFigure(seat: SeatCount): SeatFigure {
  const source = seat.limit_from === "contract" ? "the contract" : "the plan";

  if (seat.limit === null) {
    return {
      value: String(seat.used),
      hint:
        seat.limit_from === null
          ? "No contract or plan yet."
          : `${seat.limit_from === "contract" ? "The contract" : "The plan"} sets no limit.`,
      over: false,
    };
  }

  const extra = seat.used - seat.limit;
  if (extra > 0) {
    return {
      value: `${seat.used} of ${seat.limit}`,
      hint: `${extra} more than ${source} ${seat.limit_from === "contract" ? "sold" : "allows"}.`,
      over: true,
    };
  }

  return {
    value: `${seat.used} of ${seat.limit}`,
    hint: seat.limit_from === "contract" ? "As sold on the contract." : "The plan's limit.",
    over: false,
  };
}
