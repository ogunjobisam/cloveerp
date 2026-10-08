import { Link, useRouteContext } from "@tanstack/react-router";
import type { ReactNode } from "react";

import { apexHref } from "../../lib/backend";

/**
 * A link to one of the apex's own pages: the product page or the enquiry
 * form.
 *
 * On the apex, www, a preview or a local stack it is an ordinary link inside
 * the page. On a client's host or the demonstration those pages are the
 * apex's (src/lib/backend.ts, marketingIsElsewhere), so the link is the
 * apex's address, a whole-page move: the demonstration's own enquiry form
 * would post to the demonstration's project, where nobody reads it. The root
 * route sends a page asked for there to the apex as well; this makes the
 * address the link shows, opens in a new tab or is copied the right one.
 *
 * The host is the root route's (src/routes/__root.tsx), the same on the
 * server and in the browser, so the first render and the hydration agree.
 */
export function ApexLink({
  to,
  className,
  children,
}: {
  to: "/product" | "/contact";
  className: string;
  children: ReactNode;
}) {
  const { host } = useRouteContext({ from: "__root__" });
  const href = apexHref(to, host);
  if (href !== to) {
    return (
      <a href={href} className={className}>
        {children}
      </a>
    );
  }
  return (
    <Link to={to} className={className}>
      {children}
    </Link>
  );
}
