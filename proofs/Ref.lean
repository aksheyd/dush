import Dush

/-! Golden vectors for `tests/proof/bridge_test.zig`, computed by the definitions the theorems
are about. `just proof` regenerates `vectors/golden.txt` and fails if it changed.

Line formats (space separated):
* `H n s` — `Dush.Human.humanize n = s`
* `R n m` — `Dush.roundUp512 n = m`
* `S a size blocks b` — `Entry.bytes` with `-A` iff `a = 1`
* `B bs n k` — `Dush.dushBlocks bs n = k`
* `A a k t_1 … t_k grand m e_1 … e_m` — `k` operands, their totals (`opTotals`), the `-c`
  total (`total` of the flattened trace), then `m` entries `op dev ino nlink blocks size`. -/

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
  let ts := opTotals w Seen.empty ops
  let grand := total w (tr.map Prod.snd)
  let a := if apparent then 1 else 0
  s!"A {a} {ts.length} " ++ " ".intercalate (ts.map toString) ++ s!" {grand} {tr.length} " ++
    " ".intercalate (tr.map showEntry)

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
  for seed in List.range 200 do
    let tr := mkTrace seed (seed % 40)
    IO.println (traceLine false tr)
    IO.println (traceLine true tr)
