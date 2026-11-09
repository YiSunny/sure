# Variable recurring income

Bills → income source → Edit offers **Income amount → Variable amount (estimate
only)**. This is opt-in for each income source and requires a specific deposit
account. Fixed income and expense bills keep their existing amount tolerance.

The entered amount is a fallback estimate. Future paydays use the last settled
paycheck's actual amount, displayed as approximate. A same-currency, posted,
standard inflow on the selected account must match the source's merchant or
known name and fall inside the payday matching window. The amount itself is not
a matching condition. Two possible deposits or competing income series are
left unmatched rather than selecting one by amount. Pending deposits, transfers
and entries already assigned to other occurrences are not automatically claimed.

A single complete receipt closes the payday with its actual amount, smaller or
larger than estimated; the bank transaction is never changed. Explicit partial
allocations do not close a payday as if they were the full receipt. Removing the
settling allocation reopens the payday and restores its estimate. Multi-part pay
or payments outside the matching window require manual review.

The usual post-sync recurring pipeline refreshes observed income and matches
open paydays. Selecting variable income does not silently apply it to every
income source in the household. It is not an automatic salary classifier.
