open Posix_time2
open Posix_time2.Timespec

module Sys_time = struct
  type t = Timespec.t

  let implementation = "native (high-precision)"
  let time () = clock_gettime `Monotonic

  let of_float d =
    let tv_sec = Int64.of_float d in
    let tv_nsec = Int64.of_float ((d -. floor d) *. 1_000_000_000.) in
    Timespec.create tv_sec tv_nsec

  let to_float { tv_sec; tv_nsec } =
    Int64.to_float tv_sec +. (Int64.to_float tv_nsec /. 1_000_000_000.)

  let normalize ~tv_sec ~tv_nsec =
    let tv_sec = Int64.add tv_sec (Int64.div tv_nsec 1_000_000_000L) in
    let tv_nsec = Int64.rem tv_nsec 1_000_000_000L in
    Timespec.create tv_sec tv_nsec

  let apply fn x y =
    normalize ~tv_sec:(fn x.tv_sec y.tv_sec) ~tv_nsec:(fn x.tv_nsec y.tv_nsec)

  let ( |+| ) = apply Int64.add
  let ( |-| ) = apply Int64.sub

  let ( |*| ) x y =
    normalize
      ~tv_sec:(Int64.mul x.tv_sec y.tv_sec)
      ~tv_nsec:
        (Int64.add
           (Int64.add
              (Int64.mul x.tv_sec y.tv_nsec)
              (Int64.mul x.tv_nsec y.tv_sec))
           (Int64.div (Int64.mul x.tv_nsec y.tv_nsec) 1_000_000_000L))

  let ( |<| ) x y =
    if Int64.equal x.tv_sec y.tv_sec then x.tv_nsec < y.tv_nsec
    else x.tv_sec < y.tv_sec

  let ( |<=| ) x y =
    if Int64.equal x.tv_sec y.tv_sec then x.tv_nsec <= y.tv_nsec
    else x.tv_sec <= y.tv_sec

  let sleep = nanosleep
end

let posix_time : (module Liq_time.T) = (module Sys_time)
let () = Liq_time.implementation := posix_time
