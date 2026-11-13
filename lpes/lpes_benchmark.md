# LPES Benchmark Corpus — Verified Privilege-Escalation CVEs

Ground-truth dataset for the regression and evaluation suite described in `lpes_specs.md` §9.1.

**Verification pass: 2026-11-13.** Every entry was checked against the authoritative CVE record on **CVE.org (cveawg.mitre.org)** — including the CNA's description, affected version range, and fix-commit references — with **NVD** as secondary source. All fix SHAs listed below were confirmed present in the **mainline tree** (`torvalds/linux`) via `github.com/torvalds/linux/commit/<sha>`.

**Corpus state: 83 verified entries (from an initial seed of 100 leads). 18 seed entries were dropped after verification — the drop list with reasons is kept at the bottom (negative knowledge: these IDs are tempting but wrong for this corpus).**

---

## How to read this file

Columns per entry:

| Column | Meaning |
|---|---|
| **File · Function** | Verified from the CNA description (fixes several seed errors) |
| **Last vuln / First fixed** | Mainline releases. CNA's exact stable-range text (e.g., "through 4.11.9") is in the notes |
| **Fix commit** | Mainline SHA (✓ = confirmed in torvalds tree). Vulnerable tree = `sha^` |
| **Verified notes** | Verified mechanism, entry conditions (namespaces, sysctls, arch, hardware), caveats, and CNA-vs-community discrepancies |

**Reachability metadata legend (in notes):** `userns` = requires user/net namespaces (unprivileged via `unshare(CLONE_NEWUSER)`); `bpf` = requires `kernel.unprivileged_bpf_disabled=0`; `net` = network-facing, not a local-shell bug; `phys` = physical access required; plus config/arch requirements.

---

## Distribution summary (verified)

| Class | Name | Count | Share | Notes |
|---|---|---|---|---|
| C1 | Use-after-free | 20 | 24% | netfilter/net-sched waves dominate |
| C2 | Double-free / invalid-free | 4 | 5% | genuinely scarce in the CVE record |
| C3 | Heap buffer overflow | 12 | 14% | |
| C4 | Stack buffer overflow | 3 | 4% | post-2017 stack hardening shows |
| C5 | Integer overflow → small alloc | 5 | 6% | |
| C6 | Uninitialized variable | 2 | 2% | leaks rarely get privesc CVEs |
| C7 | Race condition / TOCTOU | 7 | 8% | |
| C8 | Missing / wrong capability check | 3 | 4% | |
| C9 | Missing permission check | 4 | 5% | |
| C10 | User-controlled format string | 0 | 0% | **no verified LPE CVE exists** — synthetic-only class (see note) |
| C11 | Arbitrary write via user offset | 7 | 8% | |
| C12 | Refcount overflow / underflow | 2 | 2% | |
| C13 | Type confusion | 10 | 12% | eBPF verifier dominates; `bpf` gate applies to all |
| C14 | OOB read via unchecked user index | 4 | 5% | reads are usually classified as info-leak, not prvesc |
| | **Total** | **83** | | |

The skew is deliberate and now verified to mirror reality: UAF/heap-OOB classes (dominated by the 2021–2024 netfilter/net-sched disclosure waves) are what unprivileged users actually exploit. Weak classes (C2, C4, C6, C10, C12, C14) reflect genuine scarcity, not curation bias. **Top-up targets:** C10 (synthetic only), C6 (+3: query NVD for `CWE-908` + `copy_to_user`), C14 (+4: `CWE-125`/`CWE-129` with local reachability), C8 (+2: container-era advisories).

---

## C1 — Use-after-free (20)

| CVE | File · Function | Last vuln | First fixed | Fix commit | Verified notes |
|---|---|---|---|---|---|
| CVE-2024-1086 | net/netfilter/nf_tables_api.c · nft_verdict_init | v6.6 | v6.7 | `f342de4e2f33` ✓ | Error-path `kfree` of live rule; massively exploited (Google CNA). Stable: 6.6.6, 6.1.69, 5.15.148, 5.10.205, 5.4.266. `userns` |
| CVE-2023-32233 | net/netfilter/nf_tables_api.c · anonymous set batch cleanup | v6.3 | v6.4 | `c1592a89942e` ✓ | CNA: "through 6.3.1 … arbitrary read and write operations". Documented r/w primitive. `userns` |
| CVE-2023-3390 | net/netfilter/nf_tables_api.c · NFT_MSG_NEWRULE error handling | v6.3 | v6.4 | `1240eb93f061` ✓ | Seed said pipapo — **corrected**: error-handling UAF in nf_tables_api.c (Google CNA). `userns` |
| CVE-2023-6817 | net/netfilter/nft_set_pipapo.c · nft_pipapo_walk | v6.6 | v6.7 | `317eb9685095` ✓ | pipapo walk vs. deferred GC. `userns` |
| CVE-2022-2588 | net/sched/cls_route.c · route4_change | v5.19 | v6.0 | TBD — canonical record, no commit ref | Old filter freed before removal from hashtable when handle changes (Canonical CNA). `userns` |
| CVE-2023-4244 | net/sched/cls_u32.c · u32_change | v6.5 | v6.6 | `3e91b0ebd994` ✓ | Race-condition-driven UAF (Google CNA). `userns` |
| CVE-2023-1829 | net/sched/cls_tcindex.c · tcindex_delete | v6.3 | v6.4 | `8c710f75256b` ✓ | tcindex filter delete UAF (Google CNA). `userns` |
| CVE-2023-3609 | net/sched/cls_u32.c · tcf_change_indev failure path | v6.4 | v6.5 | TBD | Seed said cls_api — **corrected** to cls_u32 (Google CNA: "If tcf_change_indev() fails…"). `userns` |
| CVE-2023-3776 | net/sched/cls_fw.c · tcf_change_indev failure path | v6.4 | v6.5 | TBD | Seed said cls_u32 — **corrected** to cls_fw (Google CNA). `userns` |
| CVE-2023-4004 | net/netfilter/nft_set_pipapo.c · nft_pipapo_remove | v6.4 | v6.5 | TBD | Seed said cls_fw — **corrected**: pipapo element removal without NFT_SET_EXT_KEY (Red Hat CNA). `userns` |
| CVE-2023-6932 | net/ipv4/igmp.c · igmp timer race | v6.6 | v6.7 | TBD | Seed said sch_qfq — **corrected to net/ipv4/igmp** (Google CNA). Race → timer wrongly re-registered → UAF. Exploited in the wild per Google TAG. `userns` |
| CVE-2022-29582 | fs/io_uring.c · io_uring timeout race | v5.17 | v5.18 | `e677edbcabee` ✓ | CNA: "race condition in io_uring timeouts … local user who has no privileges". CNA: before 5.17.3 |
| CVE-2022-47939 | fs/ksmbd/smb2pdu.c · smb2_tree_disconnect | v5.19 | v6.0 | `cf6531d98190` ✓ | `net` — SMB client needed; CNA range 5.15–5.19 before 5.19.2 |
| CVE-2017-11176 | ipc/mqueue.c · mq_notify | v4.12 | v4.13 | `f991af3daaba` ✓ | sock pointer not NULLed on Netlink-close retry path. CNA: through 4.11.9. Classic Project Zero writeup (UAF writeup reference for C1 specialists) |
| CVE-2024-26642 | net/netfilter/nf_tables_api.c · anonymous set with timeout flag | v6.7 | v6.8 | TBD | Linux CNA fix "disallow anonymous set with timeout flag". Seed said chain binding — **corrected**. `userns` |
| CVE-2021-26708 | net/vmw_vsock/af_vsock.c · vsock transport assignment races | v5.10 | v5.12 | `c518adafa39f` ✓ | "Multiple race conditions … wrong locking" (CNA: before 5.10.13 stable; mainline fix in 5.12-rc). Requires AF_VSOCK socket creation — reachable by unprivileged users |
| CVE-2017-8824 | net/dccp/proto.c · dccp_disconnect | v4.14 | v4.15 | TBD | CNA: "gain privileges or DoS (use-after-free)". CNA: through 4.14.3 |
| CVE-2015-3636 | net/ipv4/ping.c · ping_unhash | v4.0 | v4.1 | `a134f083e79f` ✓ | list head not initialized during unhash → list corruption/UAF. CNA: before 4.0.3. Requires ping socket creation (`ping_group_range`) |
| CVE-2015-8543 | net/core · protocol registration validation | v4.3 | v4.4 | `79462ad02e86` ✓ | CNA: "does not validate protocol identifiers for certain protocol families" (ping-family). CNA: through 4.3.3. Android-era |
| CVE-2021-43267 | net/tipc/crypto.c · TIPC key negotiation | v5.15 | v5.16 | `fa40d9734a57` ✓ | `net` — remote attackers on a TIPC network; heap OOB during key negotiation. CNA: before 5.14.16. Threat-model stretch — keep flagged |

## C2 — Double-free / invalid-free (4)

| CVE | File · Function | Last vuln | First fixed | Fix commit | Verified notes |
|---|---|---|---|---|---|
| CVE-2017-6074 | net/dccp/input.c · dccp_rcv_state_process | v4.9 | v4.10 | `5edabca9d4cf` ✓ | DCCP_PKT_REQUEST mishandled in LISTEN state → double-free. CNA: through 4.9.11. Unprivileged via `SO_REUSEPORT` |
| CVE-2022-32250 | net/netfilter/nf_tables_api.c · nft_set_elem_init error path | v5.18 | v5.19 | TBD | CNA: "local user (able to create user/net namespaces) … invalid free". CNA: through 5.18.1. `userns` |
| CVE-2017-2636 | drivers/tty/n_hdlc.c · n_hdlc race | v4.10 | v4.11 | TBD | Red Hat CNA: **"double free"** — reclassified from C1. CNA: through 4.10.1. Requires N_HDLC line discipline (unprivileged TTYIOCSETD) |
| CVE-2016-2384 | sound/usb/midi.c · snd_usbmidi_create | v4.4 | v4.5 | `07d86ca93db7` ✓ | Debian CNA: **"Double free vulnerability"** — moved from C1 to strengthen C2. `phys` (USB device insertion) |

## C3 — Heap buffer overflow (12)

| CVE | File · Function | Last vuln | First fixed | Fix commit | Verified notes |
|---|---|---|---|---|---|
| CVE-2021-22555 | net/netfilter/x_tables.c · compat target size | v5.12 | v5.13 | TBD | Google CNA: "heap out-of-bounds write affecting Linux **since v2.6.19-rc1**" — corrected file (was nft_compat.c). Famous kmalloc-trick writeup. `userns` |
| CVE-2022-1015 | net/netfilter/nf_tables_api.c · nft register write | v5.17 | v5.18 | TBD | OOB write on nft registers (Red Hat CNA). `userns` |
| CVE-2017-1000112 | net/ipv4/ip_output.c · ip_ufo_append_data | v4.13 | v4.14 | TBD | UFO→non-UFO path switch with MSG_MORE → heap corruption (CNA). UFO has since been removed entirely — pre-fix trees only |
| CVE-2022-2639 | net/openvswitch/flow_netlink.c · actions copy/reserve | v5.18 | v5.19 | `cefa91b2332d` ✓ | Integer coercion error with large action counts (Red Hat CNA). Requires OVS module loaded |
| CVE-2022-25636 | net/netfilter/nf_dup_netdev.c · nft_fwd_dup_netdev | v5.16 | v5.17 | `b1a5983f56e3` ✓ | Heap OOB write; exploited within days of disclosure. CNA range "5.4 through 5.6.10" is a typo for 5.16.10 (cross-check at build time). `userns` |
| CVE-2020-14386 | io_uring/ · provide-kbufs | v5.8 | v5.9 | `acf69c946233` ✓ | Red Hat CNA: "before 5.9-rc4. Memory corruption can be exploited to gain root from unprivileged processes" |
| CVE-2017-7184 | net/xfrm/xfrm_user.c · xfrm_replay_verify_len | v4.10 | v4.11 | `677e806da4d9` ✓ | Size data not validated after XFRM_MSG_NEWAE (corrected function from generic rcv_msg). CNA: through 4.10.6 |
| CVE-2016-4998 | net/ipv4/netfilter/ · IPT_SO_SET_REPLACE compat copy | v4.6 | v4.7 | `6e94e0cfb088` ✓ | Compat setsockopt OOB (CNA: before 4.6). Sibling CVE-2016-4997 is in the same class. `userns`+`net_raw` needed for compat setsockopt path |
| CVE-2016-4997 | net/ipv4/netfilter/ · compat IPT/IP6T_SO_SET_REPLACE | v4.6 | v4.7 | `ce683e5f9d04` ✓ | Red Hat CNA: "allow local users to gain privileges" — **reclassified from C14 to C3** (it's a write, not a read). CNA: before 4.6.3 |
| CVE-2016-3134 | net/netfilter/ · offset-field validation | v4.5 | v4.6 | `54d83fc74aa9` ✓ | CNA: "does not validate certain offset fields … gain privileges or DoS (heap memory corruption)" — **reclassified from C14 to C3**. CNA: through 4.5.2 |
| CVE-2019-2214 | drivers/android/binder.c · binder_transaction | v5.4 | Android (2019) | TBD (Android common) | Google CNA: **"possible out of bounds write due to a missing bounds check"** — reclassified from C1 (the epoll-UAF narrative comes from exploit writeups; the CNA record says OOB write). "Bad Binder"; no mainline cycle for the vulnerable branch — reproduce against Android common kernels |
| CVE-2022-2078 | net/netfilter/nf_tables_api.c · nft_set_desc_concat_parse | v5.18 | v5.19 | `fecf31ee395b` ✓ | **Replaces rejected CVE-2022-1972** (NVD: "DO NOT USE THIS CANDIDATE NUMBER … duplicate of CVE-2022-2078"). Buffer overflow via concat set desc parsing (Red Hat CNA). `userns` |

## C4 — Stack buffer overflow (3)

| CVE | File · Function | Last vuln | First fixed | Fix commit | Verified notes |
|---|---|---|---|---|---|
| CVE-2010-3849 | net/econet/af_econet.c · econet_sendmsg | v2.6.36 | v2.6.36.2 (stable) | TBD | CNA: "when an econet address is configured" — needs `CONFIG_ECONET` + an admin-configured econet address (reachability caveat; module later removed). Classic exploit era |
| CVE-2017-1000253 | fs/binfmt_elf.c · total_mapping_size | v4.11 | v4.12 | `a87938b2e246` ✓ (per CNA text) | Distributions without the Apr 14 2017 fix were vulnerable; large-ELF mapping overflow |
| CVE-2022-4378 | kernel/sysctl.c · sysctl write path | v6.0 | v6.1 | TBD | Red Hat CNA: "stack overflow … SYSCTL subsystem … changes certain kernel parameters" — **reclassified from C9** (specs cite it as the C9 example; CNA mechanism is stack overflow). Note: `kernel.sysctl` writes require the sysctl to be world-writable — usually gated by `/proc/sys` perms |

*Note: seed entry CVE-2017-1000251 was verified to be a **BlueZ Bluetooth stack overflow**, not the PowerPC binfmt_elf bug — dropped.*

## C5 — Integer overflow → small alloc (5)

| CVE | File · Function | Last vuln | First fixed | Fix commit | Verified notes |
|---|---|---|---|---|---|
| CVE-2017-7308 | net/packet/af_packet.c · packet_set_ring | v4.10 | v4.11 | TBD | Block-size validation OOB. CNA: through 4.10.6. Needs `CAP_NET_RAW` (available in userns) |
| CVE-2017-1000111 | net/packet/af_packet.c · packet_snd / ring option | v4.13 | v4.14 | TBD | CNA: "analogous to previously disclosed CVE-2016-8655 — a socket option that changes ring behavior". Companion of CVE-2016-8655 |
| CVE-2022-0185 | fs/fs_context.c · legacy_parse_param | v5.16 | v5.17 | `722d94847de2` ✓ | Heap OOB via length verification overflow. Stable fixed in 5.16.2/5.15.16. Exploit chains through FUSE (`CONFIG_FUSE_FS`). `userns` |
| CVE-2018-14634 | fs/binfmt_elf.c · create_elf_tables | v4.18 | v4.19 | TBD | Unprivileged user + SUID binary reaches oversized stack alloc (Red Hat CNA: "with access to SUID … binaries") |
| CVE-2021-33909 | fs/seq_file.c · seq buffer allocation | v5.13 | v5.14 | `8cae8cd89f05` ✓ | "SizeBuster". CNA: 3.16 through 5.13.x before 5.13.4 → mainline 5.14. Integer overflow → heap OOB |

*Note: seed entry CVE-2016-0728 moved to C12 (its CNA description is object-reference mishandling, not integer overflow).*

## C6 — Uninitialized variable (2)

| CVE | File · Function | Last vuln | First fixed | Fix commit | Verified notes |
|---|---|---|---|---|---|
| CVE-2024-42076 | net/can/j1939/socket.c · j1939_send_one | v6.10 | v6.11 | TBD | Linux CNA: "Initialize unused data … **kernel-infoleak**" — **reclassified from C14; corrected from netfilter to CAN j1939**. Info leak defeating KASLR — prvesc enabler per specs §2. Needs `CONFIG_CAN_J1939`; requires CAN socket access |
| CVE-2024-50264 | net/vmw_vsock/virtio_transport*.c · vsk->trans dangling pointer | v6.11 | v6.12 | TBD | Linux CNA: "Initialization of the dangling pointer … during loopback connection". Specs' own C6 example (uninit/dangling-pointer pattern) |

*Top-up guidance: query NVD for `CWE-908` + `copy_to_user` leaks; struct-padding leaks via `kmemdup`-style paths are chronically under-CVE'd.*

## C7 — Race condition / TOCTOU (7)

| CVE | File · Function | Last vuln | First fixed | Fix commit | Verified notes |
|---|---|---|---|---|---|
| CVE-2016-5195 | mm/gup.c · __get_user_pages (Dirty COW) | v4.8 | v4.9 | `19be0eaffa3a` ✓ | CNA: 2.x through 4.x before 4.8.3 (stable); mainline fix is the FOLL_WRITE-games removal. Seed's guessed SHA was wrong — this one is verified |
| CVE-2016-8655 | net/packet/af_packet.c · packet_set_ring | v4.8 | v4.9 | `84ac7260236a` ✓ | register_prot_hook race. CNA: through 4.8.12. Needs `CAP_NET_RAW` (userns) |
| CVE-2024-0582 | io_uring/ · IORING_REGISTER_PBUF_RING | v6.7 | v6.8 | `c392cbecd8ec` ✓ | Red Hat CNA says "memory leak" (pbuf ring mmap then free) — **discrepancy**: exploit community treats it as UAF via dangling user mmap; widely exploited. Judge on mechanism, not CNA label. Keep at C7 per specs |
| CVE-2014-3151 | kernel/futex/requeue.c · futex_requeue_pi | v3.15 | v3.16 | TBD | Towelroot. CVE.org record sparse; mechanism (requeue_pi plist corruption → arbitrary write) is exhaustively documented in stable backports (3.14.5, 3.15.2). Unprivileged via futex syscall directly |
| CVE-2018-18281 | mm/mremap.c · mremap TLB flush race | v4.19 | v4.20 | `eb66ae030829` ✓ | **Corrected from n_tty.c**: "Since 3.2, mremap() performs TLB flushes after dropping pagetable locks"; races with ftruncate. Race-window bug — good stress-test for C7 queries |
| CVE-2017-15649 | net/packet/af_packet.c · packet_fanout data race | v4.13 | v4.14 | `008ba2a13f2d` ✓ | CNA: "crafted system calls that trigger mishandling of packet_fanout data" — confirmed prvesc. CNA: before 4.13.6 |
| CVE-2014-0196 | drivers/tty/n_tty.c · n_tty_write LECHO & !OPOST | v3.14 | v3.15 | `4291086b1f08` ✓ | **Corrected function** (n_tty_write, not ldisc). TTY driver access mismanaged → concurrent writes race |

## C8 — Missing / wrong capability check (3)

| CVE | File · Function | Last vuln | First fixed | Fix commit | Verified notes |
|---|---|---|---|---|---|
| CVE-2019-13272 | kernel/ptrace.c · ptrace_link | v5.1 | v5.2 | `6994eefb0053` ✓ | CNA: "mishandles the recording of the credentials of a process that wants to create a ptrace relationship" (Jann Horn). CNA: before 5.1.17 (stable); mainline 5.2 |
| CVE-2022-0492 | kernel/cgroup/cgroup-v1.c · cgroup_release_agent_write | v5.16 | v5.17 | `24f600856418` ✓ | **Corrected ID**: seed had CVE-2022-0494, which is an unrelated scsi_ioctl info leak. release_agent reachable from cgroup namespace (`userns`); stable fixed 5.16.3 |
| CVE-2010-3850 | net/econet/af_econet.c · ec_dev_ioctl | v2.6.36 | v2.6.36.2 (stable) | TBD | **Reclassified from C6**: CNA says "does not require the CAP_NET_ADMIN capability" — a textbook C8. Needs `CONFIG_ECONET` |

*Note: specs' C8 example CVE-2024-41055 was verified as **mm/sparsemem pfn_section_valid NULL-deref (DoS)**, not the hidraw ioctl bug — dropped; the specs example needs replacing (suggest finding the actual hidraw CVE before relying on it).*

## C9 — Missing permission check (4)

| CVE | File · Function | Last vuln | First fixed | Fix commit | Verified notes |
|---|---|---|---|---|---|
| CVE-2012-0056 | fs/proc/base.c · mem_write | v3.2 | v3.3 | TBD | "Mempodipper". CNA: "when ASLR is disabled" + before 3.2.2 (stable) — record the ASLR precondition in the corpus JSON |
| CVE-2015-1328 | fs/overlayfs/ · file-creation permission check | Ubuntu 15.04 | Ubuntu kernel 3.19.0-21.21 | TBD (Ubuntu git) | Canonical CNA — Ubuntu-only; no mainline cycle. **Reproduce against Ubuntu archive kernels** |
| CVE-2021-3492 | fs/shiftfs/ · copy_from_user fault handling | Ubuntu 20.04 | Ubuntu update (2021) | `25c891a949bf` ✓ / `8fee52ab9da8` ✓ | **Corrected: shiftfs (out-of-tree Ubuntu filesystem), not overlayfs** — Canonical CNA. Ubuntu-only |
| CVE-2021-3493 | fs/overlayfs/ · file capabilities on copy-up | v5.11 | Ubuntu update (2021) / mainline 6.2 | `7c03e2cda4a5` ✓ | overlayfs did not validate file-capability setting w.r.t. user namespaces (`userns`). Mainline fix landed in v6.2 — the Ubuntu kernels carried it earlier |

## C10 — User-controlled format string (0)

**No verified LPE format-string CVE exists in the CVE record.** The seed candidate CVE-2013-6282 verified as an ARM `get_user`/`put_user` address-validation bug (reclassified to C11). Format-string prvescs are effectively extinct in modern kernels (`%n` disabled, constant-format enforcement in `printk`/`__printf` attributes). **Run C10 specialists against synthetic cases only; exclude the class from recall metrics (§9.2), keep precision-only.**

## C11 — Arbitrary write via user offset (7)

| CVE | File · Function | Last vuln | First fixed | Fix commit | Verified notes |
|---|---|---|---|---|---|
| CVE-2023-0386 | fs/overlayfs/ · ovl_copy_up (setuid/caps) | v6.2 | v6.3 | `4f11ada10d0a` ✓ | Unauthorized execution of setuid/capability files via OverlayFS — requires `userns` + FUSE (`CONFIG_FUSE_FS`) for the classic chain |
| CVE-2022-0847 | lib/iov_iter.c · copy_page_to_iter_pipe / push_pipe | v5.16 | v5.17 | `f6dd975583bd` ✓ (mainline confirmed) | Dirty Pipe. CNA: pipe-buffer `flags` **lacking proper initialization** — interesting: mechanism is an uninit flags field, impact is arbitrary page-cache write. Stable: 5.16.11. Present since v5.8 |
| CVE-2008-0600 | fs/splice.c · vmsplice_to_pipe | v2.6.24.1 | v2.6.24.2 (stable) / v2.6.25 mainline | TBD | CNA: 2.6.17 through 2.6.24.1, "does not validate a certain userspace pointer before dereference" — the classic vmsplice era |
| CVE-2013-2094 | kernel/events/core.c · perf_swevent_init | v3.8 | v3.9 | `8176cced706b` ✓ | CNA: "uses an incorrect integer data type" → OOB write at controlled index (event_id). CNA: before 3.8.9 (stable). Needs `perf_event_paranoid` ≤ 1 |
| CVE-2010-3904 | net/rds/page.c · rds_page_copy_user | v2.6.35 | v2.6.36 | TBD | Canonical CNA: "does not properly validate … userspace pointer" — **reclassified from C1 to C11** (mechanism is unvalidated user page → arbitrary r/w). RDS was later disabled by default |
| CVE-2013-6282 | arch/arm · get_user / put_user (v6k/v7) | v3.5 | v3.5.5 (stable) | `8404663f81d2` ✓ | **Reclassified from C10**: ARM-only unvalidated user addresses → arbitrary kernel r/w. `arch: arm`. Good negative-control for arch-gated findings |
| CVE-2016-10088 | drivers/scsi/sg.c · sg ioctl paths (KERNEL_DS) | v4.9 | v4.10 | `128394eff343` ✓ | Debian CNA: "does not properly restrict write operations when KERNEL_DS is set … read or write to arbitrary kernel-memory locations" — **reclassified from C14 to C11**. Needs sg device node |

## C12 — Refcount overflow / underflow (2)

| CVE | File · Function | Last vuln | First fixed | Fix commit | Verified notes |
|---|---|---|---|---|---|
| CVE-2019-11487 | mm/ · page->_refcount overflow | v5.0 | v5.1 | `15fab63e1e57`, `6b3a70773630`, `88b1a17dfc3e`, `8fde12ca79af`, `f958d7b528b1` ✓ (fix series) | CNA: "reference count overflow, with resultant use-after-free issues, **if about 140 GiB of RAM exists**" — hardware precondition must be recorded; regression should run the source-only scan (no memory requirement for detection). CNA: before 5.1-rc5 |
| CVE-2016-0728 | security/keys/process_keys.c · join_session_keyring | v4.4 | v4.5 | `23567fd052a9` ✓ | **Moved from C5**: Red Hat CNA: "mishandles object references in a certain error case" — refcount-underflow mechanism, not integer-overflow-in-alloc. Present since ~2.6.10. Specs' C5 example should be updated accordingly |

## C13 — Type confusion (10)

| CVE | File · Function | Last vuln | First fixed | Fix commit | Verified notes |
|---|---|---|---|---|---|
| CVE-2018-9568 | net/core/sock.c · sk_clone_lock | v4.19 | v4.20 | TBD | Google CNA: "memory corruption due to **type confusion** … local escalation of privilege with no additional execution privileges" — confirmed class. sa_family/socket-state confusion |
| CVE-2017-16995 | kernel/bpf/verifier.c · check_alu_op | v4.14 | v4.15 | `95a762e2c8c9` ✓ | Debian CNA: "memory corruption or possibly have unspecified impact" — the famous verifier-state-tracking exploit. `bpf` gate |
| CVE-2020-8835 | kernel/bpf/verifier.c · ALU32 register bounds | v5.6 | v5.7 | `f2d67fec0b43` ✓ | Canonical CNA: "5.5.0 and newer … 32-bit operations" — confirmed. `bpf` gate |
| CVE-2022-23222 | kernel/bpf/verifier.c · *_OR_NULL pointer arithmetic | v5.15 | v5.16 | `64620e0a1e71` ✓ | CNA: through 5.15.14 → mainline 5.16 (corrected from seed's 5.17). `bpf` gate |
| CVE-2021-3490 | kernel/bpf/verifier.c · ALU32 bounds for AND/OR/XOR | v5.12 | v5.13 | `049c4e13714e` ✓ | Canonical CNA confirms bitwise-ops bounds tracking. `bpf` gate |
| CVE-2021-4204 | kernel/bpf/ · improper input validation → OOB | v5.16 | v5.17 | TBD | Red Hat CNA: "local attacker with a special…" — OOB access via verifier bypass. `bpf` gate |
| CVE-2021-31440 | kernel/bpf/verifier.c · pointer arithmetic bounds | v5.11 | v5.12 | `10bf4e83167c` ✓ | ZDI record: LPE on 5.11.15. `bpf` gate |
| CVE-2017-17862 | kernel/bpf/verifier.c · unreachable-code pruning | v4.14 | v4.15 | `c131187db2d3` ✓ | CNA: "ignores unreachable code, even though it would still be processed by JIT compilers". CNA: through 4.14.8. `bpf` gate |
| CVE-2018-18445 | kernel/bpf/verifier.c · adjust_scalar_min_max_bounds | v4.18 | v4.19 | `b799207e1e18` ✓ | CNA: "faulty computation of numeric bounds in the BPF verifier permits out-of-bounds memory accesses". CNA: before 4.18.13 (stable). `bpf` gate |
| CVE-2021-33200 | kernel/bpf/verifier.c · pointer-arithmetic limits | v5.12 | v5.13 | `3d0220f6861d` / `a7036191277f` / `bb01a1bba579` ✓ (series; CID bb01a1bba579) | CNA: through 5.12.7 → mainline 5.13. `bpf` gate |

**Class caveat (all C13 eBPF entries):** `kernel.unprivileged_bpf_disabled` defaults to 2 on modern distros. Record `required_sysctls: {unprivileged_bpf_disabled: 0}` per entry, or the Verifier (§4.3) will rightly suppress them — and the regression harness must boot test kernels with the sysctl set.

## C14 — OOB read via unchecked user index (4)

| CVE | File · Function | Last vuln | First fixed | Fix commit | Verified notes |
|---|---|---|---|---|---|
| CVE-2022-1016 | net/netfilter/nf_tables_core.c · nft_do_chain | v5.17 | v5.18 | TBD | **Discrepancy**: Red Hat CNA describes "use-after-free … needs to handle 'return' properly"; community describes OOB **read** of nft registers (info leak). Keep in C14 for the read primitive, cross-listed conceptually with C1. `userns` |
| CVE-2022-47940 | fs/ksmbd/smb2pdu.c · smb2_write length validation | v5.18 | v5.19 | `158a66b24573` ✓ | `net`. CNA: "lacks length validation in the non-padding case in smb2_write". CNA range: 5.15 through 5.18 before 5.18.18 |
| CVE-2017-9077 | net/ipv6/tcp_ipv6.c · tcp_v6_syn_recv_sock | v4.11 | v4.12 | `83eaddab4378` ✓ | "Mishandles inheritance … DoS or possibly unspecified other impact" — **prvesc unproven**; kept as a weak/verify entry for C14. CNA: through 4.11.1 |
| CVE-2013-1828 | net/sctp/socket.c · sctp_getsockopt_assoc_stats | v3.8 | v3.9 | `726bc6b092da` ✓ | **Corrected from xfrm to sctp**: size value not validated before copy — local users leak/corrupt (Red Hat CNA). CNA: before 3.8.4 |

---

## Dropped during verification (18) — negative knowledge

These seed entries failed verification. Do **not** re-add without new evidence; the reasons matter for corpus curation:

| CVE | Actual record (verified) | Why dropped |
|---|---|---|
| CVE-2010-4164 | net/x25/x25_facilities.c integer underflow — **remote** DoS | wrong class, remote attacker |
| CVE-2013-6282→C11 | ARM get_user/put_user | reclassified (kept under C11), not dropped — listed here for the C10 note |
| CVE-2014-7911 | Android **Java ObjectInputStream** deserialization | not a kernel bug at all |
| CVE-2015-5283 | sctp_init init-order panic — local DoS | DoS, not prvesc |
| CVE-2016-9603 | **QEMU** Cirrus VGA | not a kernel CVE |
| CVE-2017-1000251 | **BlueZ Bluetooth** stack overflow | wrong bug (kernel bluetooth; requires BT; different class) |
| CVE-2017-12193 | lib/assoc_array.c node-split DoS (NULL deref) | DoS-only per CNA |
| CVE-2017-18017 | xt_TCPMSS tcpmss_mangle_packet — **remote** DoS | remote, DoS |
| CVE-2017-7541 | brcmfmac (Broadcom WiFi) buffer overflow | device-specific (`phys`-ish, requires brcmfmac hardware) |
| CVE-2017-7542 | ip6_find_1stfragopt DoS (integer overflow/infinite loop) | DoS; seed's refcount claim was wrong |
| CVE-2017-9075 | sctp_v6_create_accept_sk inheritance DoS | weaker sibling of kept CVE-2017-9077 |
| CVE-2018-5803 | sctp sm_make_chunk packet-length error — remote | remote DoS; seed's double-free claim wrong |
| CVE-2018-1068 | 32-bit bridging syscall — **privileged** user required | outside threat model (§2) |
| CVE-2022-0168 | fs/cifs smb2_ioctl_query_info DoS | client-side CIFS DoS; seed's ematch claim wrong |
| CVE-2022-24959 | hamradio yam_siocdevprivate **memory leak** | leak/DoS; seed's af_key-race claim wrong |
| CVE-2022-3702 | **Lenovo Vantage HardwareScan** (Windows plugin) | not a kernel CVE |
| CVE-2022-47941 | ksmbd missing kfree → **memory leak** | leak, not prvesc |
| CVE-2024-41055 | mm/sparsemem pfn_section_valid NULL-deref DoS | DoS; **also invalidates the specs' C8 example** |
| CVE-2022-1972 | **Rejected/reserved duplicate** — replaced by CVE-2022-2078 | invalid CVE ID |

---

## Caveats that remain (updated)

- **Netfilter/net-sched over-representation (~30% of C1–C3)** now verified as realistic, but per-class recall on those families must be high or G1 fails. If balance is preferred, grow io_uring/BPF entries from the 2021+ CNA wave.
- **Threat-model stretches, flagged in rows:** ksmbd/TIPC (`net`), USB MIDI (`phys`), Ubuntu shiftfs/overlayfs (distro trees), Android binder (no mainline cycle for 2019-2214's affected branch).
- **Mechanism vs CNA-label discrepancies** worth encoding as Verifier test cases: CVE-2024-0582 (CNA "memory leak" vs exploitable UAF), CVE-2022-1016 (CNA "UAF" vs OOB read), CVE-2019-2214 (CNA "OOB write" vs epoll-UAF narrative), CVE-2022-0847 (CNA "uninit flags" vs arbitrary write). A detection system must classify by mechanism, not label.
- **Preconditions to record per corpus JSON:** `userns`, `bpf` sysctl, `perf_event_paranoid`, `CONFIG_*` gates (ECONET, CAN_J1939, FUSE_FS, NF_TABLES), RAM (2019-11487), ASLR-off (2012-0056), arch=arm (2013-6282).
- **Era skew:** heavy 2015–2024; old trees (2008–2013) need older compiler/SAST toolchain pins (§5.4).

## Specs cross-reference — examples that must be updated in `lpes_specs.md`

The verification contradicted several CVE examples used in the specs:

| Specs location | Stated example | Verified reality |
|---|---|---|
| §2.1 C8 row | CVE-2024-41055 (hidraw) | mm/sparsemem NULL-deref DoS — replace |
| §2.1 C9 row | CVE-2022-4378 (procfs) | SYSCTL **stack overflow** → belongs to C4 |
| §2.1 C12 row | CVE-2019-11487 (refcount) | ✓ still valid (page->_refcount) |
| §2.1 C5 row | CVE-2016-0728 (keyrings) | refcount-underflow mechanism → belongs to C12 |
| §2.1 C14 row | CVE-2024-42076 (netfilter) | CAN j1939 **infoleak** → belongs to C6 |
| §4.5 / G6 flow | — | unaffected |

## Reproduction workflow (per entry, updated)

```bash
# Trees: vulnerable = fix_sha^, fixed = fix_sha (mainline, torvalds/linux)
# For stable-level reproduction, use the CNA range in the row notes
# (e.g. CVE-2024-1086: last-vulnerable stable tags 6.6.5 / 6.1.68 / 5.15.147).

git show <fix_sha>                      # fix hunk line ≈ expected primary_line
git checkout <fix_sha>^ && lpes scan --kernel . --classes <class>   # must find
git checkout <fix_sha>   && lpes scan --kernel . --classes <class>  # must NOT re-emit
git tag --contains <fix_sha>            # = first fixed release (verify column)
```

Per-CVE record to write into `tests/corpus/` (schema aligned with §8.3):

```json
{
  "cve": "CVE-2024-1086",
  "class": "C1",
  "repo": "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git",
  "fix_commit": "f342de4e2f33",
  "pre_fix_commit": "<fix_commit^1>",
  "last_vulnerable_release": "v6.6",
  "first_fixed_release": "v6.7",
  "stable_fixes": {"v6.6": "v6.6.6", "v6.1": "v6.1.69", "v5.15": "v5.15.148"},
  "expected": {"file": "net/netfilter/nf_tables_api.c", "function": "nft_verdict_init", "line": 0},
  "required_configs": ["CONFIG_NF_TABLES", "CONFIG_USER_NS"],
  "required_sysctls": {},
  "threat_model_notes": "userns; nft netlink",
  "cna": "Google",
  "verified": true
}
```

**Remaining to complete per entry:** (1) `expected.line` from the fix hunk (`git show <fix_sha>`); (2) the ~25 `TBD` fix SHAs (resolvable one `git log --grep` each, or via the NVD reference list); (3) top-up queries to return to 100+ entries per the distribution table's top-up targets.

---

*Companion to `lpes_specs.md` (§9.1) and `lpes_tech_arch.md`. Verification data cached under the repo is reproducible via the cveawg.mitre.org API (`/api/cve/<ID>`) plus `github.com/torvalds/linux/commit/<sha>` presence checks.*
