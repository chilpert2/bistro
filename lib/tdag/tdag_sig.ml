open Core_kernel.Std

type 'a result = ('a, [`Msg of string]) Pervasives.result

type trace =
  | Run of { ready : time ;
             start : time ;
             end_ : time ;
             outcome : unit result }
  | Skipped of [ `Done_already
               | `Missing_dep
               | `Allocation_error of string ]

and time = float

module type Domain = sig

  module Thread : sig
    type 'a t
    val return : 'a -> 'a t
    val bind : 'a t -> ('a ->'b t) -> 'b t
  end

  module Allocator : sig
    type t
    type request
    type resource

    val request : t -> request -> resource result Thread.t
    val release : t -> resource -> unit
  end

  module Task : sig
    type t
    type config

    val id : t -> string
    val requirement : t -> Allocator.request
    val perform : Allocator.resource -> config -> t -> unit result Thread.t
    val is_done : config -> t -> bool Thread.t
    val clean : config -> t -> unit Thread.t
  end

end

module type S = sig
  type t
  type task
  type allocator
  type config
  type 'a thread

  type event =
    | Task_ready of task
    | Task_started of task
    | Task_ended of task * unit result
    | Task_skipped of task * [ `Done_already
                             | `Missing_dep
                             | `Allocation_error of string ]

  val empty : t
  val add_task : t -> task -> t
  val add_dep : t -> task -> on:task -> t

  val run :
    ?log:(time -> event -> unit) ->
    config -> allocator -> t -> trace String.Map.t thread
end