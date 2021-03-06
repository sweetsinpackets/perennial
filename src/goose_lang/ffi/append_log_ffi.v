From RecordUpdate Require Import RecordSet.

From Perennial.Helpers Require Import CountableTactics Transitions.
From Perennial.goose_lang Require Import lang lifting slice typing.
From Perennial.goose_lang Require ffi.disk.

(* TODO: move this out, it's completely general *)
Section recoverable.
  Context {Σ:Type}.
  Inductive RecoverableState :=
    | UnInit
    | Initing
    | Closed (s:Σ)
    | Opening (s:Σ)
    | Opened (s:Σ) (l:loc)
  .

  Definition recoverable_model : ffi_model :=
    mkFfiModel (RecoverableState) (populate UnInit).

  Local Existing Instance recoverable_model.

  Context {ext:ext_op}.

  Definition openΣ : transition state (Σ*loc) :=
    bind (reads id) (λ rs, match rs.(world) with
                           | Opened s l => ret (s,l)
                           | _ => undefined
                           end).

  Definition modifyΣ (f:Σ -> Σ) : transition state unit :=
    bind openΣ (λ '(s, l), modify (set world (λ _, Opened (f s) l))).

  (* TODO: generalize to a transition to construct the initial value, using a zoom *)
  Definition initTo (init:Σ) (l:loc) : transition state unit :=
    bind (reads id) (λ rs, match rs.(world) with
                           | UnInit => modify (set world (fun _ => Opened init l))
                           | _ => undefined
                           end).

  Definition open (l:loc) : transition state Σ :=
    bind (reads id) (λ rs, match rs.(world) with
                           | Closed s => bind (modify (set world (fun _ => Opened s l)))
                                             (fun _ => ret s)
                           | _ => undefined
                           end).

  Definition close : transition (RecoverableState) unit :=
    bind (reads id) (fun s => match s with
                           | Opened s _ => modify (fun _ => Closed s)
                           | _ => undefined
                           end).

  Global Instance Recoverable_inhabited : Inhabited RecoverableState := populate UnInit.
End recoverable.

Arguments RecoverableState Σ : clear implicits.
Arguments recoverable_model Σ : clear implicits.

Definition ty_ := forall (val_ty:val_types), @ty val_ty.
(* TODO: slice should not require an entire ext_ty *)
Definition sliceT_ (t: ty_) : ty_ := λ val_ty, prodT (arrayT (t _)) uint64T.
Definition blockT_: ty_ := sliceT_ (λ val_ty, byteT).


Inductive LogOp :=
  | AppendOp (* log, slice of blocks *)
  | GetOp (* log, index *)
  | ResetOp (* log *)
  | InitOp (* disk size *)
  | OpenOp (* (no arguments) *)
.

Instance eq_LogOp : EqDecision LogOp.
Proof.
  solve_decision.
Defined.

Instance LogOp_fin : Countable LogOp.
Proof.
  solve_countable LogOp_rec 5%nat.
Qed.

Definition log_op : ext_op.
Proof.
  refine (mkExtOp LogOp _ _).
Defined.

Inductive Log_ty := LogT.

Instance log_val_ty: val_types :=
  {| ext_tys := Log_ty; |}.

Section log.
  Existing Instances log_op log_val_ty.
  Instance log_ty: ext_types log_op :=
    {| val_tys := log_val_ty;
       get_ext_tys (op: @external log_op) :=
         match op with
         | AppendOp => (extT LogT, sliceT_ blockT_ _)
         | GetOp => (prodT (extT LogT) uint64T, prodT (blockT_ _) boolT)
         | ResetOp => (extT LogT, unitT)
         | InitOp => (uint64T, extT LogT)
         | OpenOp => (unitT, extT LogT)
         end; |}.

  Definition log_state := RecoverableState (list disk.Block).

  Instance log_model : ffi_model := recoverable_model (list disk.Block).

  Existing Instances r_mbind r_fmap.

  Definition read_slice (t:ty) (v:val): transition state (list val) :=
    match v with
    | PairV (#(LitLoc l)) (PairV #(LitInt sz) #(LitInt cap)) =>
      (* TODO: implement *)
      ret []
    | _ => undefined
    end.

  Fixpoint tmapM {Σ A B} (f: A -> transition Σ B) (l: list A) : transition Σ (list B) :=
    match l with
    | [] => ret []
    | x::xs => f x;; tmapM f xs
    end.

  (* TODO: implement *)
  Definition to_block (l: list val): option disk.Block := None.

  Definition allocIdent: transition state loc :=
    l ← allocateN 1;
    modify (set heap <[l := Free #()]>);;
    ret l.

  Definition log_step (op:LogOp) (v:val) : transition state val :=
    match op, v with
    | GetOp, PairV (LitV (LitLoc logPtr)) (LitV (LitInt a)) =>
      openΣ ≫= λ '(log, logPtr_),
      check (logPtr = logPtr_);;
      b ← unwrap (log !! int.nat a);
      l ← allocateN 4096;
      modify (state_insert_list l (disk.Block_to_vals b));;
      ret $ #(LitLoc l)
    | ResetOp, PairV (LitV (LitLoc logPtr)) (LitV LitUnit) =>
      openΣ ≫= λ '(_, logPtr_),
      check (logPtr = logPtr_);;
      modifyΣ (fun _ => []);;
      ret $ #()
    | InitOp, LitV LitUnit =>
      logPtr ← allocIdent;
      initTo [] logPtr;;
      ret $ LitV $ LitLoc logPtr
    | OpenOp, LitV LitUnit =>
      logPtr ← allocIdent;
      s ← open logPtr;
      ret $ LitV $ LitLoc logPtr
    | AppendOp, PairV (LitV (LitLoc logPtr)) v =>
      openΣ ≫= λ '(_, logPtr_),
      check (logPtr = logPtr_);;
      (* FIXME: append should be non-atomic in the spec because it needs to read
         an input slice (and the slices the input points to). *)
      (* this is absolutely horrendous to reason about *)
      block_slices ← read_slice (slice.T (slice.T byteT)) v;
      block_vals ← tmapM (read_slice (@slice.T _ log_ty byteT)) block_slices;
      new_blocks ← tmapM (unwrap ∘ to_block) block_vals;
      modifyΣ (λ s, s ++ new_blocks);;
      ret $ #()
    | _, _ => undefined
    end.

  Instance log_semantics : ext_semantics log_op log_model :=
    {| ext_step := log_step;
       ext_crash := fun s s' => relation.denote close s s' tt; |}.
End log.

From iris.algebra Require Import auth agree excl csum.
From Perennial.program_logic Require Import ghost_var.
Definition openR := csumR (fracR) (agreeR (leibnizO loc)).
Definition Log_Closed q : openR := Cinl (q).
Definition Log_Opened (l: loc) : openR := Cinr (to_agree l).

Class logG Σ :=
  { logG_open_inG :> inG Σ openR;
    logG_open_name : gname;
    logG_state_inG:> inG Σ (authR (optionUR (exclR (leibnizO (list disk.Block)))));
    logG_state_name: gname;
  }.

Record log_names :=
  { log_names_open: gname;
    log_names_state: gname; }.

Definition log_get_names {Σ} (lG: logG Σ) :=
  {| log_names_open := logG_open_name; log_names_state := logG_state_name |}.

Definition log_update {Σ} (lG: logG Σ) (names: log_names) :=
  {| logG_open_inG := logG_open_inG;
     logG_open_name := (log_names_open names);
     logG_state_inG := logG_state_inG;
     logG_state_name := (log_names_state names);
  |}.

Definition log_open {Σ} {lG :logG Σ} (l: loc) :=
  own (logG_open_name) (Log_Opened l).
Definition log_closed {Σ} {lG :logG Σ} (q: Qp) :=
  own (logG_open_name) (Log_Closed q).

Definition log_auth {Σ} {lG :logG Σ} (vs: list (disk.Block)) :=
  own (logG_state_name) (● Excl' (vs: leibnizO (list disk.Block))).
Definition log_frag {Σ} {lG :logG Σ} (vs: list (disk.Block)) :=
  own (logG_state_name) (◯ Excl' (vs: leibnizO (list disk.Block))).

Section log_interp.
  Existing Instances log_op log_model log_val_ty.

  Definition log_ctx {Σ} {lG: logG Σ} (lg: @ffi_state log_model) : iProp Σ :=
    match lg with
    | Opened s l => log_open l ∗ log_auth s
    | Closed s => log_closed (1/2) ∗ log_auth s
    | UnInit => log_closed (1/2) ∗ log_auth []
    | _ => False%I
    end.

  Definition log_start {Σ} {lG: logG Σ} (lg: @ffi_state log_model) : iProp Σ :=
    match lg with
    | Opened s l => log_open l ∗ log_frag s
    | Closed s => log_closed (1/2) ∗ log_frag s
    | UnInit => log_closed (1/2) ∗ log_frag []
    | _ => False%I
    end.

  Definition log_restart {Σ} (lG: logG Σ) (lg: @ffi_state log_model) :=
    match lg with
    | Opened s l => log_open l
    | Closed s => log_closed (1/2)
    | UnInit => log_closed (1/2)
    | _ => False%I
    end.

End log_interp.
