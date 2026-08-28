# Tests import `bodies/...` and `helpers`, so both the repo's `src` and this
# directory have to be on the path. CI already passes --path:src; this keeps a
# bare `nim r tests/x.nim` working too.
switch("path", "$projectDir/..")
switch("path", "$projectDir/../src")
switch("path", "$projectDir")
