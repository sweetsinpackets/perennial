(* autogenerated from awol *)
From Perennial.Goose Require Import base.

(* 10 is completely arbitrary *)
Definition MaxTxnWrites : uint64 := 10.

Definition logLength : uint64 := 1 + 1 + MaxTxnWrites.

Module Log.
  Record t {model:GoModel} := mk {
    l: LockRef;
    addrs: ptr (slice.t uint64);
    cache: Map Block;
    length: ptr uint64;
  }.
  Arguments mk {model}.
  Global Instance t_zero {model:GoModel} : HasGoZero t := mk (zeroValue _) (zeroValue _) (zeroValue _) (zeroValue _).
End Log.

Definition intToBlock {model:GoModel} (a:uint64) : proc Block :=
  b <- Data.newSlice byte Disk.BlockSize;
  _ <- Data.uint64Put b a;
  Ret b.

Definition blockToInt {model:GoModel} (v:Block) : proc uint64 :=
  a <- Data.uint64Get v;
  Ret a.

(* New initializes a fresh log *)
Definition New {model:GoModel} : proc Log.t :=
  diskSize <- Disk.size;
  _ <- if uint64_le diskSize logLength
  then
    _ <- Data.panic;
    Ret tt
  else Ret tt;
  addrs <- Data.newSlice uint64 0;
  addrPtr <- Data.newPtr (slice.t uint64);
  _ <- Data.writePtr addrPtr addrs;
  cache <- Data.newMap Block;
  header <- intToBlock 0;
  _ <- Disk.write 0 header;
  lengthPtr <- Data.newPtr uint64;
  _ <- Data.writePtr lengthPtr 0;
  l <- Data.newLock;
  Ret {| Log.l := l;
         Log.addrs := addrPtr;
         Log.cache := cache;
         Log.length := lengthPtr; |}.

Definition lock {model:GoModel} (l:Log.t) : proc unit :=
  Data.lockAcquire l.(Log.l) Writer.

Definition unlock {model:GoModel} (l:Log.t) : proc unit :=
  Data.lockRelease l.(Log.l) Writer.

(* BeginTxn allocates space for a new transaction in the log.

   Returns true if the allocation succeeded. *)
Definition BeginTxn {model:GoModel} (l:Log.t) : proc bool :=
  _ <- lock l;
  length <- Data.readPtr l.(Log.length);
  if length == 0
  then
    _ <- unlock l;
    Ret true
  else
    _ <- unlock l;
    Ret false.

(* Read from the logical disk.

   Reads must go through the log to return committed but un-applied writes. *)
Definition Read {model:GoModel} (l:Log.t) (a:uint64) : proc Block :=
  _ <- lock l;
  let! (v, ok) <- Data.mapGet l.(Log.cache) a;
  if ok
  then
    _ <- unlock l;
    Ret v
  else
    _ <- unlock l;
    dv <- Disk.read (logLength + a);
    Ret dv.

Definition Size {model:GoModel} (l:Log.t) : proc uint64 :=
  sz <- Disk.size;
  Ret (sz - logLength).

(* Write to the disk through the log. *)
Definition Write {model:GoModel} (l:Log.t) (a:uint64) (v:Block) : proc unit :=
  _ <- lock l;
  let! (_, ok) <- Data.mapGet l.(Log.cache) a;
  if ok
  then
    _ <- unlock l;
    Ret tt
  else
    length <- Data.readPtr l.(Log.length);
    _ <- if uint64_ge length MaxTxnWrites
    then
      _ <- Data.panic;
      Ret tt
    else Ret tt;
    let nextAddr := 1 + 1 + length in
    addrs <- Data.readPtr l.(Log.addrs);
    newAddrs <- Data.sliceAppend addrs a;
    _ <- Data.writePtr l.(Log.addrs) newAddrs;
    _ <- Disk.write (nextAddr + 1) v;
    _ <- Data.mapAlter l.(Log.cache) a (fun _ => Some v);
    _ <- Data.writePtr l.(Log.length) (length + 1);
    unlock l.

(* encodeAddrs produces a disk block that encodes the addresses in the log *)
Definition encodeAddrs {model:GoModel} (l:Log.t) : proc Block :=
  length <- Data.readPtr l.(Log.length);
  addrs <- Data.readPtr l.(Log.addrs);
  aBlock <- Data.newSlice byte 4096;
  _ <- Loop (fun i =>
        if compare_to Lt i length
        then
          ai <- Data.sliceRead addrs i;
          _ <- Data.uint64Put (slice.subslice (i * 8) (i + 1 * 8) aBlock) ai;
          Continue (i + 1)
        else LoopRet tt) 0;
  Ret aBlock.

(* decodeAddrs reads the address disk block and decodes it into length addresses *)
Definition decodeAddrs {model:GoModel} (length:uint64) : proc (slice.t uint64) :=
  addrs <- Data.newSlice uint64 length;
  aBlock <- Disk.read 1;
  _ <- Loop (fun i =>
        if compare_to Lt i length
        then
          a <- Data.uint64Get (slice.subslice (i * 8) (i + 1 * 8) aBlock);
          _ <- Data.sliceWrite addrs i a;
          Continue (i + 1)
        else LoopRet tt) 0;
  Ret addrs.

(* Commit the current transaction. *)
Definition Commit {model:GoModel} (l:Log.t) : proc unit :=
  _ <- lock l;
  length <- Data.readPtr l.(Log.length);
  aBlock <- encodeAddrs l;
  _ <- unlock l;
  _ <- Disk.write 1 aBlock;
  header <- intToBlock length;
  Disk.write 0 header.

Definition getLogEntry {model:GoModel} (addrs:slice.t uint64) (logOffset:uint64) : proc (uint64 * Block) :=
  let diskAddr := 1 + 1 + logOffset in
  a <- Data.sliceRead addrs logOffset;
  v <- Disk.read (diskAddr + 1);
  Ret (a, v).

(* applyLog assumes we are running sequentially *)
Definition applyLog {model:GoModel} (addrs:slice.t uint64) : proc unit :=
  let length := slice.length addrs in
  Loop (fun i =>
        if compare_to Lt i length
        then
          let! (a, v) <- getLogEntry addrs i;
          _ <- Disk.write (logLength + a) v;
          Continue (i + 1)
        else LoopRet tt) 0.

Definition clearLog {model:GoModel} : proc unit :=
  header <- intToBlock 0;
  Disk.write 0 header.

(* Apply all the committed transactions.

   Frees all the space in the log. *)
Definition Apply {model:GoModel} (l:Log.t) : proc unit :=
  _ <- lock l;
  addrs <- Data.readPtr l.(Log.addrs);
  _ <- applyLog addrs;
  newAddrs <- Data.newSlice uint64 0;
  _ <- Data.writePtr l.(Log.addrs) newAddrs;
  let cache := l.(Log.cache) in
  _ <- Data.mapClear cache;
  _ <- clearLog;
  _ <- Data.writePtr l.(Log.length) 0;
  unlock l.

(* Open recovers the log following a crash or shutdown *)
Definition Open {model:GoModel} : proc Log.t :=
  header <- Disk.read 0;
  length <- blockToInt header;
  addrs <- decodeAddrs length;
  addrPtr <- Data.newPtr (slice.t uint64);
  _ <- Data.writePtr addrPtr addrs;
  _ <- applyLog addrs;
  _ <- clearLog;
  cache <- Data.newMap Block;
  lengthPtr <- Data.newPtr uint64;
  _ <- Data.writePtr lengthPtr 0;
  l <- Data.newLock;
  Ret {| Log.l := l;
         Log.addrs := addrPtr;
         Log.cache := cache;
         Log.length := lengthPtr; |}.