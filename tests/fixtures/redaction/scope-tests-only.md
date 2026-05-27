# Test scope manifest — allows only tests/ tree.
# Used by integration tests to force redaction of out-of-scope paths
# (e.g. src/*, /etc/*, /home/*) so redactions>0 in redaction.applied.
+ tests/
