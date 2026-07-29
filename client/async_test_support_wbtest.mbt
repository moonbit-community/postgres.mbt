///|
/// Async counterpart to `@test.expect_error` for client white-box tests.
///
/// The project currently uses async 0.19.0, whose public test support does not
/// provide this helper.
#callsite(autofill(loc))
async fn[T, E : Error] expect_error_async(
  f : async () -> T raise E,
  loc~ : SourceLoc,
) -> E {
  try f() catch {
    error => error
  } noraise {
    _ =>
      @test.fail(
        "expected error, but program succeeded without raising anything",
        loc~,
      )
  }
}
