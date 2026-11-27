## design — pass

- 7 SPEC(s): DSRACE-1, DSRACE-2, DSRACE-3, DSRACE-4, DSRACE-5, DSRACE-6, DSRACE-7

- DSRACE-1 (covers RQTIE-1, RQTIE-3): After successfully adding the zbuild:claimed label (gh backend), the claim posts a concurrent claim note with the run's holder, then reads back all trusted concurrent claim notes to detect concurrent claimants
- DSRACE-2 (covers RQTIE-2, RQTIE-1): Only the run whose concurrent claim note is first (by created_at, then id) returns {"acquired": true}; all others return {"acquired": false}
- DSRACE-3 (covers RQCMT-1): The losing run updates its concurrent claim note body to "not started"
- DSRACE-4 (covers RQLBL-1): When zbuild_claim_acquire receives {"acquired": false, "race_lost": true} from the coordinator, _ZBUILD_CLAIM_ACQUIRED is not set and zbuild_claim_release does not remove the zbuild:claimed label
- DSRACE-5 (covers RQTIE-1): A coordinator response with race_lost: true causes zbuild_claim_acquire to refuse immediately without entering the stale-takeover path, printing a message that names the concurrent winner
- DSRACE-6 (covers RQADR-1): ADR-005 §5 tells a reader: after adding the label (gh backend), a note is posted as the holder record, the first note by created_at then id wins, the loser marks its note "not started", and race_lost: true in the refused response skips the stale-takeover path
- DSRACE-7 (covers RQREB-1): After posting the concurrent claim note (the synchronous holder record, gh backend), the claim reads back the GitHub issue's current state before proceeding with arbitration
- no finding was open for it
