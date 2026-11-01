# Algorithm Practice

Small, reproducible workspace for LeetCode, GeeksforGeeks, HackerRank, and
interview-style drills.

The template keeps Rust, Go, and Java side by side so the same problem can be
solved in the language you want to train that day.

## Commands

```sh
make test
make test-rust
make test-go
make test-java
make fmt
```

Add one file per problem, keep the test close to the solution, and prefer small
pure functions over platform-specific stdin parsing until a platform requires
otherwise.
