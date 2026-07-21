# Candidate-eligibility filter for the drain (SHARED: drain-next.sh via
# drain_select_candidates, and the gate test runner). Input is the tracker
# adapter's list-items JSON; $lbl is the work-class label the drain claims on.
# Emits `<id>\t<url>` TSV for every OPEN item that is labelled AND unblocked AND
# unassigned, ordered by ascending issue number (oldest-first, FIFO drain).
.items
| map(select((.labels | index($lbl)) and .blocked_by_count == 0 and (.assignees | length == 0)))
| sort_by(.url | split("/") | last | tonumber)
| .[]
| [.id, .url]
| @tsv
