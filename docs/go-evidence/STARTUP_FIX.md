# Occupied-port startup regression

Reproduced against PR head `9854dc0`: a child running the real `main` with a
reserved loopback port printed `fixture simulator listening on ...`, then
`bind: address already in use`, and exited with status zero. The new subprocess
regression failed against that implementation.

The server now binds explicitly before opening the database, logs the actual
bound address only after initialization, and serves that listener. Startup and
unexpected serve errors return through `run()` to `main()`'s nonzero exit path.
Deferred cleanup runs before exit; SIGINT/SIGTERM still close the server normally.

Validation after the fix:

- Real-main subprocess with occupied port: nonzero exit, bind diagnostic, no
  listening/readiness message.
- Real-main subprocess with port zero: log contains its allocated port, the
  authenticated capabilities API answers HTTP 200, and SIGTERM exits zero.
- Complete Go suite with race detection passed; statement coverage 89.8%.
- `go vet ./...`, formatting/diff checks and build (`-buildvcs=false`) passed.

No Elixir code or web UI changed in this follow-up. Existing resource measurements
were not rerun and predate this startup correction. No production deployment or
merge was performed.
