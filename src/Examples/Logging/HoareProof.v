Require Import POCS.
Require Import Spec.HoareTactics.

Require Import Examples.Logging.Impl.
Require Import Examples.Logging.LogLayout.

Record LogicalState :=
  { ls_disk : disk;
    ls_log : list (addr * block);
  }.

Inductive DiskDecode (d: disk) (ls: LogicalState) : Prop :=
| disk_decode
    (Hsize: 2 + LOG_LENGTH + length ls.(ls_disk) = length d)
    (Hdisk: forall i, i <= length ls.(ls_disk) -> index ls.(ls_disk) i = index d (i + 258)).

Inductive LogDecode (d: disk) (ls: LogicalState) : Prop :=
| log_decode bhdr bdesc hdr desc
    (Hbhdr: index d O = Some bhdr)
    (Hbdesc: index d 1 = Some bdesc)
    (Hhdr_dec : LogHdr_fmt.(decode) bhdr = hdr)
    (Hdesc_dec : Descriptor_fmt.(decode) bdesc = desc)
    (Hlog_length: length ls.(ls_log) <= LOG_LENGTH)
    (Hlog: forall i, i < hdr.(log_length) ->
                     exists a b,
                       index ls.(ls_log) i = Some (a, b) /\
                       index desc.(addresses) i = Some a /\
                       index d (2 + i) = Some b):
    LogDecode d ls.

Inductive CommitStatus d b : Prop :=
| commit_status bhdr
    (Hbhdr: index d O = Some bhdr)
    (Hstatus : (LogHdr_fmt.(decode) bhdr).(committed) = b):
    CommitStatus d b.

Fixpoint logical_log_apply (l: list (addr * block)) (d: disk)  : disk :=
  match l with
  | nil => d
  | (a, b) :: l' => logical_log_apply l' (assign d (2+LOG_LENGTH+a) b)
  end.

Definition ls_snoc ls a v : LogicalState :=
  {| ls_disk := ls_disk ls;
     ls_log := ls_log ls ++ ((a, v) :: nil) |}.

Definition ls_clear ls : LogicalState :=
  {| ls_disk := ls_disk ls;
     ls_log := nil |}.

Definition log_write_cspec ls (a: addr) (v: block) : Specification TxnD.WriteStatus unit D.State :=
  fun state =>
    {|
      pre := LogDecode state ls /\ DiskDecode state ls /\ CommitStatus state false;
      post := fun state' status =>
                match status with
                | TxnD.WriteErr => state' = state
                | TxnD.WriteOK =>
                  LogDecode state' (ls_snoc ls a v)
                  /\ DiskDecode state' (ls_snoc ls a v)
                  /\ CommitStatus state' false
                end;
      alternate := fun state' _ => DiskDecode state' ls /\ CommitStatus state' false
    |}.

Definition log_size_cspec ls : Specification nat unit D.State :=
  fun state =>
    {|
      pre := LogDecode state ls /\ DiskDecode state ls /\ CommitStatus state false;
      post := fun state' sz => state = state' /\ sz = length ls.(ls_disk);
      alternate := fun state' _ => state = state'
    |}.

Definition log_read_cspec ls (a: addr) : Specification block unit D.State :=
  fun state =>
    {|
      pre := LogDecode state ls /\ DiskDecode state ls /\ CommitStatus state false;
      post := fun state' v => state = state' /\
                              match index ls.(ls_disk) a with
                              | Some v' => v = v'
                              | None => True
                              end;
      alternate := fun state' _ => state = state'
    |}.

Definition log_recover_spec ls : Specification block unit D.State :=
  fun state =>
    {|
      pre := LogDecode state ls /\ DiskDecode state ls /\ CommitStatus state false;
      post := fun state' v => LogDecode state' (ls_clear ls) /\
                       DiskDecode state' (ls_clear ls) /\
                       CommitStatus state' false;
      alternate := fun state' _ => state = state'
    |}.
