import Dush

open Dush Dush.Acct

def lcg (s : Nat) : Nat := (s * 6364136223846793005 + 1442695040888963407) % 2 ^ 64

def iterate (f : Nat → Nat) : Nat → Nat → List Nat
  | 0, _ => []
  | k + 1, s => let s' := f s; s' :: iterate f k s'

def limit : Nat := 2 ^ 63

def humanizeInputs : List Nat :=
  let pows := (List.range 7).map (1024 ^ ·)
  let mants := [0, 1, 9, 10, 99, 100, 511, 512, 513, 972, 973, 999, 1000, 1001, 1023, 1024,
    1025, 1535, 1536, 9215, 9216, 10188, 10189, 10239, 10240, 102400, 1023487, 1023488,
    1023999, 1024000, 1048575, 1048576]
  let scaled := pows.flatMap fun p => mants.flatMap fun m => [m * p - 1, m * p, m * p + 1]
  let twos := (List.range 63).flatMap fun k => [2 ^ k - 1, 2 ^ k, 2 ^ k + 1]
  let rnd := (iterate lcg 4000 7).map fun r => (r % limit) / 2 ^ (r % 61)
  (([limit - 1] ++ scaled ++ twos ++ rnd).filter (· < limit)).eraseDups

def roundInputs : List Nat :=
  (List.range 2100) ++ ((iterate lcg 500 11).map fun r => r % 2 ^ 62)

def blockSizes : List Nat := [512, 1000, 1024, 4096, 1048576, 1073741824]

structure Shape where
  dev : Nat
  ino : Nat
  nlink : Nat
  blocks : Nat
  size : Nat

def shapeOf (seed : Nat) (dev ino : Nat) : Shape :=
  let r := lcg (seed * 1000003 + dev * 7919 + ino)
  ⟨dev, ino, 1 + r % 3, (r / 8) % 64, (r / 1024) % 40000⟩

def mkTrace (seed len : Nat) : List (Nat × Entry) :=
  let rs := iterate lcg len (seed + 1)
  let es := rs.map fun r =>
    let sh := shapeOf seed (1 + r % 2) ((r / 2) % 7)
    ((r / 64) % 3, (⟨sh.dev, sh.ino, sh.nlink, sh.blocks, sh.size⟩ : Entry))
  let ops := (List.range 3).map fun i => es.filter (·.1 = i)
  ops.flatten

def showEntry (p : Nat × Entry) : String :=
  s!"{p.1} {p.2.dev} {p.2.ino} {p.2.nlink} {p.2.blocks} {p.2.size}"

def traceLine (apparent : Bool) (tr : List (Nat × Entry)) : String :=
  let w := Entry.bytes apparent
  let ops := (List.range 3).map fun i => (tr.filter (·.1 = i)).map Prod.snd
  let ts := duOpTotals w (fun _ => 0) ops
  let grand := duTotal w (tr.map Prod.snd)
  let a := if apparent then 1 else 0
  s!"A {a} {ts.length} " ++ " ".intercalate (ts.map toString) ++ s!" {grand} {tr.length} " ++
    " ".intercalate (tr.map showEntry)

def b01 (b : Bool) : Nat := if b then 1 else 0

def rawCbs : List Nat := [1, 100, 511, 512, 513, 1000, 1024, 4096, 1048576]

def rawBss : List Nat := [512, 1000, 1024, 4096, 1048576, 1073741824]

def main : IO Unit := do
  for n in humanizeInputs do
    IO.println s!"H {n} {Human.humanize n}"
  for n in roundInputs do
    IO.println s!"R {n} {roundUp512 n}"
  for r in iterate lcg 300 23 do
    let size := r % 2 ^ 40
    let blocks := (r / 2 ^ 40) % 2 ^ 20
    IO.println s!"S 0 {size} {blocks} {Entry.bytes false ⟨0, 0, 1, blocks, size⟩}"
    IO.println s!"S 1 {size} {blocks} {Entry.bytes true ⟨0, 0, 1, blocks, size⟩}"
  for bs in blockSizes do
    for n in (List.range 70).map (· * 511) ++ (iterate lcg 100 (bs % 97)).map (· % 2 ^ 62) do
      IO.println s!"B {bs} {n} {dushBlocks bs n}"
  for a in [false, true] do
    for cb in rawCbs do
      for bs in rawBss do
        for r in iterate lcg 6 (cb * 31 + bs % 1009 + b01 a) do
          let sc := Scale.init a cb bs
          let size := r % 2 ^ 40
          let blocks := (r / 2 ^ 40) % 2 ^ 20
          let n := (r / 7) % 2 ^ 40
          IO.println s!"C {b01 a} {cb} {bs} {size} {blocks} {n} {sc.entryBlocks size blocks} {sc.display n} {sc.humanBytes n}"
  for live in [false, true] do
    for links in List.range 8 do
      for nlink in List.range 8 do
        let li : Int := (links : Int) - 2
        let ni : Int := (nlink : Int) - 1
        let (sk, l', lv') := linkStep live li ni
        IO.println s!"L {b01 live} {li} {ni} {b01 sk} {l'} {b01 lv'}"
  for seed in List.range 200 do
    let tr := mkTrace seed (seed % 40)
    IO.println (traceLine false tr)
    IO.println (traceLine true tr)
