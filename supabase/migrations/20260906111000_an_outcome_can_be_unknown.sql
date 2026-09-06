-- An outcome can be unknown.
--
-- D19 has said since the gateway was written that an external write whose
-- outcome is unknown enters an explicit ambiguous state rather than being
-- retried blindly, and the base pack ships a command state machine with an
-- `ambiguous` state in it. erp.command_status never had the value: a lease that
-- expired after the request had left was treated like one that expired before,
-- and the command was sent again.
--
-- This file adds the value and nothing else, on purpose. A value added to an
-- enum cannot be used in the transaction that added it, and every migration
-- is one transaction; the file that follows this one is the first to name it.

alter type erp.command_status add value if not exists 'ambiguous' after 'in_flight';
