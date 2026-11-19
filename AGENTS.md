# Project guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

Additional MoonBit skills are available at
<https://github.com/moonbitlang/skills>.

## Project structure

Each MoonBit package has its own directory. Its `moon.pkg` lists dependencies.
The directory also contains source files, blackbox tests (`_test.mbt`), and
whitebox tests (`_wbtest.mbt`).

The top-level `moon.mod` lists module metadata.

## Coding convention

- Separate MoonBit blocks with `///|`. Block order does not matter, so some
  refactors can proceed one block at a time.

- Where possible, keep each package's deprecated blocks in `deprecated.mbt`.

## Documentation

- After changing code, check whether documentation needs a corresponding update,
  including `README.md`, `README.mbt.md`, package documentation, examples, and
  user-facing and internal code comments.

- Update documentation in the same change when behavior, public APIs,
  configuration, examples, or workflows change. If no documentation update is
  needed, make that explicit in the final summary.

- Revise internal comments when the implementation details, invariants,
  assumptions, or control flow they describe change. Remove stale explanations.

## Tooling

- Format code with `moon fmt`.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` updates each package's generated `.mbti` interface. An unchanged
  `.mbti` indicates that the declared public interface stayed the same, as it
  usually does in an internal refactor.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` for package tests. For real PostgreSQL integration
  tests, run `node scripts/pg_integration_test.mjs`. When you need integration
  coverage, run `node scripts/pg_integration_test.mjs --enable-coverage`.
  MoonBit supports snapshot testing; when changes affect outputs, run
  `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for well-defined,
  stable results, such as scientific computations. Use snapshot tests to record
  current behavior. Run `moon coverage analyze > uncovered.log` to find code
  that tests did not cover.
