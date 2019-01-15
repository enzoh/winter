(module
  (import "foo" "i32_global" (global i32))
  (import "foo" "i64_global" (global i64))
  (import "foo" "f32_global" (global f32))
  (import "foo" "f64_global" (global f64))

  (global i32 (i32.const 1))
  (global i64 (i64.const 2))
  (global f32 (f32.const 3))
  (global f64 (f64.const 4))

  (global i32 (get_global 0))
  (global i64 (get_global 1))
  (global f32 (get_global 2))
  (global f64 (get_global 3)))
