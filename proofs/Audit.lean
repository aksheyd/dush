import Dush
import Lean

open Lean Elab Command in
elab "#audit " ids:ident* : command => do
  let allowed := [``propext, ``Classical.choice, ``Quot.sound]
  for id in ids do
    let n ← liftCoreM <| realizeGlobalConstNoOverloadWithInfo id
    let axs ← liftCoreM <| collectAxioms n
    logInfo m!"{n}: {axs.toList}"
    for a in axs do
      unless allowed.contains a do
        throwError "{n} depends on the non-standard axiom {a}"

#audit
  Dush.roundUp512_dvd
  Dush.le_roundUp512
  Dush.roundUp512_least
  Dush.entryBytes_eq_duUnits
  Dush.dushBlocks_eq_howmany
  Dush.dushBlocks_eq_du_apparent
  Dush.dushBlocks_eq_du_physical
  Dush.flag_blocks_agree
  Dush.getbsize_bounds
  Dush.getbsize_suffix_dvd
  Dush.scale_default_entry
  Dush.scale_default_display
  Dush.scale_default_human
  Dush.scale_default_bytes
  Dush.scale_physical_cb
  Dush.blocksize_1000_quirk
  Dush.blocksize_1000_apparent
  Dush.Human.humanize_eq_closed
  Dush.Human.scale_eq_iff
  Dush.Human.scale_mono
  Dush.Human.mantissa_eq
  Dush.Human.value10_mono
  Dush.Human.value10_upper
  Dush.Human.value10_lower
  Dush.Human.mantissa_bounds
  Dush.Acct.step_comm
  Dush.Acct.total_perm
  Dush.Acct.order_matters_without_consistency
  Dush.Acct.total_eq_counted
  Dush.Acct.counted_sublist
  Dush.Acct.counted_untracked
  Dush.Acct.counted_once
  Dush.Acct.workers_sum
  Dush.Acct.parallel_eq_sequential
  Dush.Acct.grand_total_eq
  Dush.Acct.linkStep_eq_duStep
  Dush.Acct.duStep_comm
  Dush.Acct.duTotal_perm
  Dush.Acct.du_workers_sum
  Dush.Acct.du_parallel_eq_sequential
  Dush.Acct.du_grand_total_eq
  Dush.Acct.du_counted_once
  Dush.Acct.du_eq_dush
  Dush.Acct.dush_bytes_eq_du_units
  Dush.Acct.du_expiry_counterexample
  Dush.Acct.total_line_not_sum_of_lines
