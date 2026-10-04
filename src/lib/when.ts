/**
 * A moment, as the reader's own clock shows it.
 *
 * The database hands timestamps over as ISO text in UTC. Cutting that text to
 * "2026-09-14 09:15" printed UTC as though it were local, so in British Summer
 * Time every such time on the desk was an hour behind the screens that did
 * format it (J-127). Every timestamp the desk shows goes through here.
 */

/** "14 Sep 2026, 10:15" in the reader's own zone; the text given when it is not a time. */
export function whenText(iso: string | null | undefined): string {
  if (!iso) return "—";
  const when = new Date(iso);
  if (Number.isNaN(when.getTime())) return iso;
  const day = when.toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" });
  const time = when.toLocaleTimeString("en-GB", {
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  });
  return `${day}, ${time}`;
}
