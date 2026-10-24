/-
Proofs that the bulk walk matches the `du -sh` size rules on the trees the
Zig tests describe, and the places the walker and Apple `du` come apart.

`scan` / `walkList` at `Mode.spec` is the rule: physical bytes are
`st_blocks * 512`, apparent bytes are `round512 st_size`, `-P` never follows,
`-H` follows only the command-line path, `-L` follows every symlink, files
with `nlink > 1` are charged once, and directories are charged once when
`du`'s `dirlinkchk` would remember them (`link count ≠ 1`).
-/

import Dush.Model

namespace Dush

theorem walk_file_step
    (apparent followAll : Bool) (parentDev : Nat) (files dirs : InodeSet)
    (st : Stat) (bulk : Bulk) (rest : List Tree)
    (hdev : st.dev = parentDev) (hid : bulk.fileId = st.ino)
    (hlink : bulk.linkCount? = some st.nlink)
    (hname : bulk.nameLen < 1024) (hok : bulk.lstatOk = true)
    (hino : st.ino ≠ 0)
    (hsize : apparent = true ∨ bulk.size? = none ∨ bulk.size? = some (physical st.blocks))
    (ih : ∀ files dirs, walkList .bulk apparent followAll parentDev files dirs rest =
        walkList .spec apparent followAll parentDev files dirs rest) :
    walkList .bulk apparent followAll parentDev files dirs (.file st bulk :: rest) =
      walkList .spec apparent followAll parentDev files dirs (.file st bulk :: rest) := by
  have hstep :=
    chargeListed_bulk_spec apparent parentDev files st bulk hdev hid hlink hname hok hino hsize
  simp only [walkList]
  rw [hstep]
  simp only [ih]

theorem walk_dir_step
    (apparent followAll : Bool) (parentDev : Nat) (files dirs : InodeSet)
    (st : Stat) (bulk : Bulk) (kids rest : List Tree)
    (hdev : st.dev = parentDev) (hid : bulk.fileId = st.ino)
    (hlink : bulk.linkCount? = some st.nlink)
    (hname : bulk.nameLen < 1024) (hok : bulk.lstatOk = true)
    (hino : st.ino ≠ 0) (hn : st.nlink > 1) (hv : bulk.vtype = VDIR)
    (hsize : apparent = true ∨ bulk.size? = none ∨ bulk.size? = some (physical st.blocks))
    (ihKids : ∀ files dirs, walkList .bulk apparent followAll parentDev files dirs kids =
        walkList .spec apparent followAll parentDev files dirs kids)
    (ihRest : ∀ files dirs, walkList .bulk apparent followAll parentDev files dirs rest =
        walkList .spec apparent followAll parentDev files dirs rest) :
    walkList .bulk apparent followAll parentDev files dirs (.dir st bulk kids :: rest) =
      walkList .spec apparent followAll parentDev files dirs (.dir st bulk kids :: rest) := by
  have hdir := chargeListedDir_bulk_spec apparent parentDev dirs st bulk hdev hid hlink hname hok
    hino hn hsize
  simp only [walkList, hv]
  rw [hdir]
  simp only [ihKids, ihRest]
  simp

theorem walk_link_file
    (apparent : Bool) (parentDev : Nat) (files dirs : InodeSet)
    (own : Stat) (bulk : Bulk) (ok : Bool) (tst : Stat) (tbulk : Bulk) (rest : List Tree)
    (hv : bulk.vtype = VLNK) (hok : ok = true) (hname : bulk.nameLen < 1024)
    (hino : tst.ino ≠ 0)
    (ihRest : ∀ files dirs, walkList .bulk apparent true parentDev files dirs rest =
        walkList .spec apparent true parentDev files dirs rest) :
    walkList .bulk apparent true parentDev files dirs
        (.link own bulk ok (.file tst tbulk) :: rest) =
      walkList .spec apparent true parentDev files dirs
        (.link own bulk ok (.file tst tbulk) :: rest) := by
  have hfile := chargeFollowedFile_eq .bulk apparent files tst hino
  simp only [walkList, hv, hok, hname]
  rw [hfile]
  simp only [ihRest]
  simp

theorem walk_link_dir
    (apparent : Bool) (parentDev : Nat) (files dirs : InodeSet)
    (own : Stat) (bulk : Bulk) (ok : Bool) (tst : Stat) (tbulk : Bulk)
    (tkids rest : List Tree)
    (hv : bulk.vtype = VLNK) (hok : ok = true) (hname : bulk.nameLen < 1024)
    (hino : tst.ino ≠ 0) (hn : tst.nlink > 1)
    (ihKids : ∀ files dirs, walkList .bulk apparent true tst.dev files dirs tkids =
        walkList .spec apparent true tst.dev files dirs tkids)
    (ihRest : ∀ files dirs, walkList .bulk apparent true parentDev files dirs rest =
        walkList .spec apparent true parentDev files dirs rest) :
    walkList .bulk apparent true parentDev files dirs
        (.link own bulk ok (.dir tst tbulk tkids) :: rest) =
      walkList .spec apparent true parentDev files dirs
        (.link own bulk ok (.dir tst tbulk tkids) :: rest) := by
  have hdir := chargeFollowedDir_bulk_spec apparent dirs tst hino hn
  simp only [walkList, hv, hok, hname]
  rw [hdir]
  simp only [ihKids, ihRest]
  simp

theorem walk_link_nofollow
    (apparent : Bool) (parentDev : Nat) (files dirs : InodeSet)
    (own : Stat) (bulk : Bulk) (ok : Bool) (tgt : Tree) (rest : List Tree)
    (hdev : own.dev = parentDev) (hid : bulk.fileId = own.ino)
    (hlink : bulk.linkCount? = some own.nlink)
    (hname : bulk.nameLen < 1024) (hokStat : bulk.lstatOk = true)
    (hino : own.ino ≠ 0)
    (hsize : apparent = true ∨ bulk.size? = none ∨ bulk.size? = some (physical own.blocks))
    (ihRest : ∀ files dirs, walkList .bulk apparent false parentDev files dirs rest =
        walkList .spec apparent false parentDev files dirs rest) :
    walkList .bulk apparent false parentDev files dirs (.link own bulk ok tgt :: rest) =
      walkList .spec apparent false parentDev files dirs (.link own bulk ok tgt :: rest) := by
  have hstep :=
    chargeListed_bulk_spec apparent parentDev files own bulk hdev hid hlink hname hokStat hino hsize
  cases tgt with
  | file _ _ =>
    simp only [walkList]
    rw [hstep]
    simp only [ihRest]
    simp
  | dir _ _ _ =>
    simp only [walkList]
    rw [hstep]
    simp only [ihRest]
    simp
  | link _ _ _ _ =>
    simp only [walkList]
    rw [hstep]
    simp only [ihRest]
    simp

/--
On one device, with vnode types, ids, and link counts agreeing with `stat`,
and with bulk physical sizes either absent or equal to `st_blocks * 512`,
the bulk walker and the `du` rule charge the same bytes.
-/
theorem walkList_bulk_spec (apparent followAll : Bool) :
    ∀ (n parentDev : Nat) (files dirs : InodeSet) (ts : List Tree),
      listSize ts ≤ n →
      FaithfulList apparent ts →
      SingleDevList parentDev ts →
      walkList .bulk apparent followAll parentDev files dirs ts =
        walkList .spec apparent followAll parentDev files dirs ts := by
  intro n
  induction n with
  | zero =>
    intro parentDev files dirs ts hbound _ _
    cases ts with
    | nil => simp [walkList]
    | cons t _ => cases t <;> simp [listSize, treeSize] at hbound <;> omega
  | succ n ih =>
    intro parentDev files dirs ts hbound hf hd
    cases ts with
    | nil => simp [walkList]
    | cons t rest =>
      have hrest : listSize rest ≤ n := by
        have hbound' := hbound
        cases t <;> simp [listSize, treeSize] at hbound' <;> omega
      cases hf with
      | cons hft hfRest =>
        have splitDev : SingleDev parentDev t ∧ SingleDevList parentDev rest := by
          simpa [SingleDevList] using hd
        have ihRest : ∀ files dirs,
            walkList .bulk apparent followAll parentDev files dirs rest =
              walkList .spec apparent followAll parentDev files dirs rest :=
          fun files dirs => ih parentDev files dirs rest hrest hfRest splitDev.2
        cases t with
        | file st bulk =>
          cases hft with
          | file _ _ hid hlink hname hok hino hsize =>
            have hdev : st.dev = parentDev := by simpa [SingleDev] using splitDev.1
            exact walk_file_step apparent followAll parentDev files dirs st bulk rest
              hdev hid hlink hname hok hino hsize ihRest
        | dir st bulk kids =>
          cases hft with
          | dir hv hid hlink hnlink hname hok hino hsize hkids =>
            have hdevAnd : st.dev = parentDev ∧ SingleDevList parentDev kids := by
              simpa [SingleDev] using splitDev.1
            have hkidSize : listSize kids ≤ n := by
              have hbound' := hbound
              simp [listSize, treeSize] at hbound'
              omega
            have ihKids : ∀ files dirs,
                walkList .bulk apparent followAll parentDev files dirs kids =
                  walkList .spec apparent followAll parentDev files dirs kids :=
              fun files dirs => ih parentDev files dirs kids hkidSize hkids hdevAnd.2
            exact walk_dir_step apparent followAll parentDev files dirs st bulk kids rest
              hdevAnd.1 hid hlink hname hok hino hnlink hv hsize ihKids ihRest
        | link own bulk ok tgt =>
          cases hft with
          | link hv hid hlink hname hokStat hino hsize hokTerm hterm htgt =>
            have hdev : own.dev = parentDev := by
              have hlinkDev : own.dev = parentDev ∧ SingleDev parentDev tgt := by
                simpa [SingleDev] using splitDev.1
              exact hlinkDev.1
            by_cases hfol : followAll = true
            · subst hfol
              cases hterm with
              | file tst tbulk =>
                cases htgt with
                | file _ _ _ _ _ _ hinoT _ =>
                  exact walk_link_file apparent parentDev files dirs own bulk ok tst tbulk rest
                    hv hokTerm hname hinoT ihRest
              | dir tst tbulk tkids =>
                cases htgt with
                | dir _ _ _ hnT _ _ hinoT _ hkids =>
                  have hsingle : tst.dev = parentDev ∧ SingleDevList parentDev tkids := by
                    have hlinkDev : own.dev = parentDev ∧
                        SingleDev parentDev (.dir tst tbulk tkids) := by
                      simpa [SingleDev] using splitDev.1
                    simpa [SingleDev] using hlinkDev.2
                  have hkidSize : listSize tkids ≤ n := by
                    have hbound' := hbound
                    simp [listSize, treeSize] at hbound'
                    omega
                  have ihKids : ∀ files dirs,
                      walkList .bulk apparent true tst.dev files dirs tkids =
                        walkList .spec apparent true tst.dev files dirs tkids := by
                    intro files dirs
                    simpa [hsingle.1] using
                      ih parentDev files dirs tkids hkidSize hkids hsingle.2
                  exact walk_link_dir apparent parentDev files dirs own bulk ok tst tbulk tkids rest
                    hv hokTerm hname hinoT hnT ihKids ihRest
            · have hfalse : followAll = false := by
                cases followAll <;> simp_all
              subst hfalse
              exact walk_link_nofollow apparent parentDev files dirs own bulk ok tgt rest
                hdev hid hlink hname hokStat hino hsize ihRest

def Closed : Tree → Prop
  | .file _ _ => True
  | .dir st _ kids => SingleDevList st.dev kids
  | .link _ _ _ tgt => Closed tgt

theorem scan_bulk_spec
    (apparent : Bool) (follow : Follow) (files : InodeSet) (t : Tree)
    (hf : Faithful apparent t) (hc : Closed t) :
    scan .bulk apparent follow files t = scan .spec apparent follow files t := by
  cases t with
  | file st bulk =>
    cases hf with
    | file _ _ _ _ _ _ hino _ =>
      simp [scan]
      exact chargeRootFile_eq .bulk apparent files st hino
  | dir st bulk kids =>
    cases hf with
    | dir _ _ _ _ _ _ hino _ hkids =>
      have hclosed : SingleDevList st.dev kids := by simpa [Closed] using hc
      have hseed := seedDirs_eq .bulk st hino
      have hwalk := walkList_bulk_spec apparent (follow == .L) (listSize kids) st.dev files
        (seedDirs .spec st) kids (Nat.le_refl _) hkids hclosed
      simp [scan, hseed, hwalk]
  | link own bulk ok tgt =>
    cases hf with
    | link _ _ _ _ _ hino _ hokTerm hterm htgt =>
      cases follow with
      | P =>
        simp [scan]
        exact chargeRootFile_eq .bulk apparent files own hino
      | H =>
        cases hterm with
        | file tst tbulk =>
          cases htgt with
          | file _ _ _ _ _ _ hinoT _ =>
            simp [scan, hokTerm]
            exact chargeRootFile_eq .bulk apparent files tst hinoT
        | dir tst tbulk tkids =>
          cases htgt with
          | dir _ _ _ _ _ _ hinoT _ hkids =>
            have hclosed : SingleDevList tst.dev tkids := by
              simpa [Closed] using hc
            have hseed := seedDirs_eq .bulk tst hinoT
            have hwalk := walkList_bulk_spec apparent false (listSize tkids) tst.dev files
              (seedDirs .spec tst) tkids (Nat.le_refl _) hkids hclosed
            have hnot : (Follow.H == Follow.P) = false := by decide
            have hflag : (Follow.H == Follow.L) = false := by decide
            simp [scan, hokTerm, hseed, hnot, hflag, hwalk]
      | L =>
        cases hterm with
        | file tst tbulk =>
          cases htgt with
          | file _ _ _ _ _ _ hinoT _ =>
            simp [scan, hokTerm]
            exact chargeRootFile_eq .bulk apparent files tst hinoT
        | dir tst tbulk tkids =>
          cases htgt with
          | dir _ _ _ _ _ _ hinoT _ hkids =>
            have hclosed : SingleDevList tst.dev tkids := by
              simpa [Closed] using hc
            have hseed := seedDirs_eq .bulk tst hinoT
            have hwalk := walkList_bulk_spec apparent true (listSize tkids) tst.dev files
              (seedDirs .spec tst) tkids (Nat.le_refl _) hkids hclosed
            have hnot : (Follow.L == Follow.P) = false := by decide
            have hflag : (Follow.L == Follow.L) = true := by decide
            simp [scan, hokTerm, hseed, hnot, hflag, hwalk]

/- Fixtures. Sizes are bytes. Bulk physical fields equal `blocks * 512` unless a
   theorem is about a bulk value that does not. -/

def file50 : Tree :=
  .file (S 1 3 1 51200 100) (Bk VREG 3 1 (some (100 * 512)))

def targetDir : Tree :=
  .dir (S 1 2 2 96 1) (Bk VDIR 2 2 (some 512)) [file50]

def linkNode : Tree :=
  .link (S 1 4 1 6 1) (Bk VLNK 4 1 (some 512)) true targetDir

def rootOnlyLink : Tree :=
  .dir (S 1 1 2 128 1) (Bk VDIR 1 2 (some 512)) [linkNode]

def rootBoth : Tree :=
  .dir (S 1 1 3 128 1) (Bk VDIR 1 3 (some 512)) [targetDir, linkNode]

def rootBothRev : Tree :=
  .dir (S 1 1 3 128 1) (Bk VDIR 1 3 (some 512)) [linkNode, targetDir]

def fileG : Tree :=
  .file (S 1 9 1 2048 4) (Bk VREG 9 1 (some 2048))

def dirB : Tree :=
  .dir (S 1 8 2 64 1) (Bk VDIR 8 2 (some 512)) [fileG]

def nestLink : Tree :=
  .link (S 1 7 1 4 1) (Bk VLNK 7 1 (some 512)) true dirB

def dirA : Tree :=
  .dir (S 1 2 3 96 1) (Bk VDIR 2 3 (some 512)) [file50, nestLink]

def cliNested : Tree :=
  .link (S 1 4 1 3 1) (Bk VLNK 4 1 (some 512)) true dirA

def cliPlain : Tree :=
  .link (S 1 4 1 3 1) (Bk VLNK 4 1 (some 512)) true targetDir

def hardFile : Tree :=
  .file (S 1 5 2 65536 128) (Bk VREG 5 2 (some (128 * 512)))

def hardRoot : Tree :=
  .dir (S 1 1 2 64 1) (Bk VDIR 1 2 (some 512)) [hardFile, hardFile]

def onceFile : Tree :=
  .file (S 1 5 1 65536 128) (Bk VREG 5 1 (some (128 * 512)))

def twiceRoot : Tree :=
  .dir (S 1 1 2 64 1) (Bk VDIR 1 2 (some 512)) [onceFile, onceFile]

def hardA : Tree :=
  .dir (S 1 1 2 64 1) (Bk VDIR 1 2 (some 512)) [hardFile]

def hardB : Tree :=
  .dir (S 1 8 2 64 1) (Bk VDIR 8 2 (some 512)) [hardFile]

def sparseFile : Tree :=
  .file (S 1 3 1 (10 * 1024 * 1024) 0) (Bk VREG 3 1 (some 0))

def sparseRoot : Tree :=
  .dir (S 1 1 2 64 1) (Bk VDIR 1 2 (some 512)) [sparseFile]

def oddFile : Tree :=
  .file (S 1 3 1 1000 2) (Bk VREG 3 1 (some 1000))

def oddRoot : Tree :=
  .dir (S 1 1 2 96 1) (Bk VDIR 1 2 (some 96)) [oddFile]

def fatFile : Tree :=
  .file (S 1 3 1 1000 1) (Bk VREG 3 1 none)

def fatNested : Tree :=
  .file (S 1 5 1 6 1) (Bk VREG 5 1 none)

def fatSub : Tree :=
  .dir (S 1 4 2 32 1) (Bk VDIR 4 2 none) [fatNested]

def fatRoot : Tree :=
  .dir (S 1 1 3 64 1) (Bk VDIR 1 3 none) [fatFile, fatSub]

theorem in_tree_P_does_not_follow :
    total .bulk false .P rootOnlyLink = 1024 ∧
    total .bulk false .H rootOnlyLink = 1024 ∧
    total .spec false .P rootOnlyLink = 1024 ∧
    total .spec false .H rootOnlyLink = 1024 := by
  native_decide

theorem in_tree_L_follows_target :
    total .bulk false .L rootOnlyLink = 52224 ∧
    total .spec false .L rootOnlyLink = 52224 ∧
    total .posix false .L rootOnlyLink = 52224 ∧
    total .bulk false .L rootOnlyLink ≠ total .bulk false .P rootOnlyLink := by
  native_decide

theorem in_tree_present_target_counted_once :
    total .bulk false .P rootBoth = 52736 ∧
    total .bulk false .L rootBoth = 52224 ∧
    total .spec false .L rootBoth = 52224 ∧
    total .bulk false .L rootBothRev = 52224 ∧
    total .bulk false .P rootBothRev = 52736 := by
  native_decide

theorem cli_P_H_L :
    total .bulk false .P cliNested = 512 ∧
    total .bulk false .H cliNested = 52224 ∧
    total .bulk false .L cliNested = 54272 ∧
    total .spec false .H cliNested = 52224 ∧
    total .spec false .L cliNested = 54272 := by
  native_decide

theorem cli_H_matches_L_without_nested_symlink :
    total .bulk false .P cliPlain = 512 ∧
    total .bulk false .H cliPlain = 51712 ∧
    total .bulk false .L cliPlain = 51712 ∧
    total .spec false .H cliPlain = 51712 := by
  native_decide

theorem hardlink_counted_once :
    total .bulk false .P hardRoot = 66048 ∧
    total .spec false .P hardRoot = 66048 ∧
    total .bulk false .P twiceRoot = 131584 := by
  native_decide

theorem hardlink_shared_across_command_line_targets :
    let (files, n1) := scan .bulk false .P [] hardA
    let (_, n2) := scan .bulk false .P files hardB
    n1 + n2 = 66560 ∧ n1 + n2 < total .bulk false .P hardA + total .bulk false .P hardB := by
  native_decide

theorem sparse_apparent_exceeds_physical :
    total .bulk false .P sparseRoot = 512 ∧
    total .spec false .P sparseRoot = 512 ∧
    total .bulk true .P sparseRoot = 10486272 ∧
    total .spec true .P sparseRoot = 10486272 ∧
    total .bulk false .P sparseRoot < total .bulk true .P sparseRoot := by
  native_decide

theorem apparent_ignores_unrounded_bulk :
    total .bulk true .P oddRoot = 1536 ∧
    total .spec true .P oddRoot = 1536 ∧
    total .bulk false .P oddRoot = 1512 ∧
    total .spec false .P oddRoot = 1536 ∧
    legacyBulk (some 1000) = 1000 := by
  native_decide

theorem omitted_bulk_size_uses_stat :
    total .bulk false .P fatRoot = 2048 ∧
    total .spec false .P fatRoot = 2048 ∧
    total .bulk true .P fatRoot = 2560 ∧
    total .spec true .P fatRoot = 2560 ∧
    total .bulk false .P fatRoot > physical 1 := by
  native_decide

theorem in_tree_k_blocks_agree :
    kBlocks (total .bulk false .L rootOnlyLink) = 51 ∧
    kBlocks (total .spec false .L rootOnlyLink) = 51 := by
  native_decide

/- Gaps. The Zig code is unchanged. -/

def oldVlnk : Tree :=
  .link (S 1 4 1 6 1) (Bk VCHR 4 1 (some 512)) true targetDir

def oldRoot : Tree :=
  .dir (S 1 1 2 128 1) (Bk VDIR 1 2 (some 512)) [oldVlnk]

theorem vtype_four_does_not_follow :
    total .bulk false .L oldRoot = 1024 ∧
    total .spec false .L oldRoot = 52224 := by
  native_decide

def longFile : Tree :=
  .file (S 1 3 1 4096 10) (Bk VREG 3 1 none 1024)

def longRoot : Tree :=
  .dir (S 1 1 2 64 1) (Bk VDIR 1 2 (some 512)) [longFile]

theorem long_name_contributes_zero :
    total .bulk false .P longRoot = 512 ∧
    total .spec false .P longRoot = 5632 := by
  native_decide

def zeroFile : Tree :=
  .file (S 1 0 2 100 4) (Bk VREG 0 2 (some 2048))

def zeroRoot : Tree :=
  .dir (S 1 1 2 64 1) (Bk VDIR 1 2 (some 512)) [zeroFile, zeroFile]

theorem ino_zero_not_deduped :
    total .bulk false .P zeroRoot = 4608 ∧
    total .spec false .P zeroRoot = 2560 := by
  native_decide

def lowDir : Tree :=
  .dir (S 1 2 1 64 1) (Bk VDIR 2 1 (some 512)) []

def lowLink1 : Tree :=
  .link (S 1 3 1 1 0) (Bk VLNK 3 1 (some 0)) true lowDir

def lowLink2 : Tree :=
  .link (S 1 4 1 1 0) (Bk VLNK 4 1 (some 0)) true lowDir

def lowRoot : Tree :=
  .dir (S 1 1 2 64 1) (Bk VDIR 1 2 (some 512)) [lowLink1, lowLink2]

theorem symlink_to_linkcount_one_deduped_by_walker :
    total .bulk false .L lowRoot = 1024 ∧
    total .posix false .L lowRoot = 1024 ∧
    total .spec false .L lowRoot = 1536 := by
  native_decide

def repeatDir : Tree :=
  .dir (S 1 2 1 100 1) (Bk VDIR 2 1 (some 512)) [onceFile]

def repeatRoot : Tree :=
  .dir (S 1 1 2 64 1) (Bk VDIR 1 2 (some 512)) [repeatDir, repeatDir]

theorem posix_dedups_linkcount_one_directory :
    total .bulk false .P repeatRoot = 132608 ∧
    total .spec false .P repeatRoot = 132608 ∧
    total .posix false .P repeatRoot = 66560 := by
  native_decide

def otherDev : Tree :=
  .file (S 2 5 2 1000 2) (Bk VREG 5 2 (some 1024))

def sameIno : Tree :=
  .file (S 1 5 2 1000 2) (Bk VREG 5 2 (some 1024))

def mountDir : Tree :=
  .dir (S 1 2 2 64 1) (Bk VDIR 2 2 (some 512)) [otherDev]

def crossRoot : Tree :=
  .dir (S 1 1 2 64 1) (Bk VDIR 1 2 (some 512)) [mountDir, sameIno]

theorem cross_device_key_collides :
    total .bulk false .P crossRoot = 2048 ∧
    total .spec false .P crossRoot = 3072 := by
  native_decide

def wrongChild : Tree :=
  .dir (S 1 2 2 64 4) (Bk VDIR 2 2 (some 0)) []

def trustRoot : Tree :=
  .dir (S 1 1 2 64 1) (Bk VDIR 1 2 (some 0)) [wrongChild]

theorem physical_bulk_disagreement_is_not_stat :
    total .bulk false .P trustRoot = 512 ∧
    total .spec false .P trustRoot = 2560 := by
  native_decide

def ordA : Tree :=
  .file (S 1 5 2 100 1) (Bk VREG 5 2 (some 100))

def ordB : Tree :=
  .file (S 1 5 2 100 1) (Bk VREG 5 2 (some 200))

theorem hardlink_bulk_disagreement_is_order_dependent :
    total .bulk false .P (.dir (S 1 1 2 64 1) (Bk VDIR 1 2 (some 512)) [ordA, ordB]) = 612 ∧
    total .bulk false .P (.dir (S 1 1 2 64 1) (Bk VDIR 1 2 (some 512)) [ordB, ordA]) = 712 ∧
    total .spec false .P (.dir (S 1 1 2 64 1) (Bk VDIR 1 2 (some 512)) [ordA, ordB]) = 1024 := by
  native_decide

def zeroLinkDir : Tree :=
  .dir (S 1 2 0 64 1) (Bk VDIR 2 0 (some 512)) []

def zeroLinkRoot : Tree :=
  .dir (S 1 1 2 64 1) (Bk VDIR 1 2 (some 512)) [zeroLinkDir, zeroLinkDir]

theorem linkcount_zero_not_remembered_by_bulk :
    total .bulk false .P zeroLinkRoot = 1536 ∧
    total .spec false .P zeroLinkRoot = 1024 := by
  native_decide

def bigFile : Tree :=
  .file (S 1 9 1 99999 1000) (Bk VREG 9 1 (some (1000 * 512)))

def aliasDir : Tree :=
  .dir (S 1 1 3 64 1) (Bk VDIR 1 3 (some 512)) [bigFile]

def backLink : Tree :=
  .link (S 1 8 1 1 0) (Bk VLNK 8 1 (some 0)) true aliasDir

def smallFile : Tree :=
  .file (S 1 3 1 100 2) (Bk VREG 3 1 (some 1024))

def cycleRoot : Tree :=
  .dir (S 1 1 3 64 1) (Bk VDIR 1 3 (some 512)) [smallFile, backLink]

theorem symlink_to_root_inode_not_recounted :
    total .bulk false .L cycleRoot = 1536 ∧
    total .spec false .L cycleRoot = 1536 := by
  native_decide

/- Apple `du.c` forgets a hardlink after `nlink` observations. dush does not. -/

structure Tick where
  node : Inode
  left : Nat
  deriving DecidableEq, Repr, BEq

def duTick (nlink : Nat) (s : List Tick) (i : Inode) : List Tick × Bool :=
  if nlink ≤ 1 then
    (s, false)
  else
    match s.find? (fun e => e.node == i) with
    | some e =>
      let s := s.filter (fun t => t.node != i)
      if e.left ≤ 1 then (s, true) else (⟨i, e.left - 1⟩ :: s, true)
    | none =>
      (⟨i, nlink - 1⟩ :: s, false)

def dushTick (nlink : Nat) (s : InodeSet) (i : Inode) : InodeSet × Bool :=
  if nlink ≤ 1 then
    (s, false)
  else
    remember true s i

def traceDu (nlink : Nat) (i : Inode) : Nat → List Tick → List Bool
  | 0, _ => []
  | n + 1, s =>
    let (s, skip) := duTick nlink s i
    skip :: traceDu nlink i n s

def traceDush (nlink : Nat) (i : Inode) : Nat → InodeSet → List Bool
  | 0, _ => []
  | n + 1, s =>
    let (s, skip) := dushTick nlink s i
    skip :: traceDush nlink i n s

theorem dedup_agrees_on_the_second_visit :
    traceDush 2 ⟨1, 1⟩ 2 [] = [false, true] ∧
    traceDu 2 ⟨1, 1⟩ 2 [] = [false, true] := by
  native_decide

theorem dedup_expires_in_apple_du :
    traceDush 2 ⟨1, 1⟩ 3 [] = [false, true, true] ∧
    traceDu 2 ⟨1, 1⟩ 3 [] = [false, true, false] := by
  native_decide

end Dush
