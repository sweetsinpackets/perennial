(* autogenerated from github.com/mit-pdos/goose-nfsd/addr *)
From Perennial.goose_lang Require Import prelude.
From Perennial.goose_lang Require Import ffi.disk_prelude.

From Goose Require github_com.mit_pdos.goose_nfsd.common.

(* Address of disk object and its size *)
Module Addr.
  Definition S := struct.decl [
    "Blkno" :: uint64T;
    "Off" :: uint64T;
    "Sz" :: uint64T
  ].
End Addr.

Definition Addr__Flatid: val :=
  rec: "Addr__Flatid" "a" :=
    struct.loadF Addr.S "Blkno" "a" * disk.BlockSize * #8 + struct.loadF Addr.S "Off" "a".

Definition Addr__Eq: val :=
  rec: "Addr__Eq" "a" "b" :=
    (struct.loadF Addr.S "Blkno" "a" = struct.get Addr.S "Blkno" "b") && (struct.loadF Addr.S "Off" "a" = struct.get Addr.S "Off" "b") && (struct.loadF Addr.S "Sz" "a" = struct.get Addr.S "Sz" "b").

Definition MkAddr: val :=
  rec: "MkAddr" "blkno" "off" "sz" :=
    struct.mk Addr.S [
      "Blkno" ::= "blkno";
      "Off" ::= "off";
      "Sz" ::= "sz"
    ].

Definition MkBitAddr: val :=
  rec: "MkBitAddr" "start" "n" :=
    let: "bit" := "n" `rem` common.NBITBLOCK in
    let: "i" := "n" `quot` common.NBITBLOCK in
    let: "addr" := MkAddr ("start" + "i") "bit" #1 in
    "addr".