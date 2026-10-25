// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira's early address-space claim (madeira_early_va_claim in Madeira's app/Madeira/JITAllocator.c,
// GPL-3.0-or-later), made by the app before main for a launch that will run the Windows engine.
//
// Madeira reserves the 0x140000000 window that fixed-base .exe images need, and the largest run above it
// for its JIT pool, before UIKit, Metal and the rest of the app allocate into that low gap. WineCore's own
// copy of the constructor only runs when the framework is loaded, which is late. The Windows test panel
// writes Documents/wine/.early-claim and asks for the app to be reopened; at that launch this constructor
// takes the flag (one launch only), makes the same PROT_NONE reservations, and Gow3WineEngine.swift hands
// them to the framework's madeira_early_* globals when it loads it. GoW3 launches never see the flag.
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static unsigned long early[6];   // window base, size, pool base, size, intruder base, size
static unsigned early_tag, early_prot;
static int early_claimed;

__attribute__((constructor(101), used)) static void gow3_wine_early_claim(void)
{
    const char *home = getenv("HOME");
    char flag[1024];
    if (!home || snprintf(flag, sizeof flag, "%s/Documents/wine/.early-claim", home) >= (int)sizeof flag) return;
    if (access(flag, F_OK) != 0) return;
    unlink(flag);

    const vm_address_t win = 0x140000000ul, winsz = 0x8000000ul;   // 128 MB, as Madeira
    vm_address_t a = win;
    if (vm_allocate(mach_task_self(), &a, winsz, VM_FLAGS_FIXED) == KERN_SUCCESS && a == win) {
        vm_protect(mach_task_self(), a, winsz, 0, VM_PROT_NONE);
        early[0] = win;
        early[1] = winsz;
    }
    // The largest run starting at the window's end, 1 GB down to 256 MB in 16 MB steps.
    for (vm_size_t sz = 1024ul << 20; sz >= (256ul << 20); sz -= (16ul << 20)) {
        a = win + winsz;
        if (vm_allocate(mach_task_self(), &a, sz, VM_FLAGS_FIXED) == KERN_SUCCESS && a == win + winsz) {
            vm_protect(mach_task_self(), a, sz, 0, VM_PROT_NONE);
            early[2] = a;
            early[3] = sz;
            break;
        }
    }
    // What blocked the run: the first mapping above it (Madeira logs it).
    vm_address_t ra = win + winsz + (vm_address_t)early[3];
    vm_size_t rs = 0;
    natural_t depth = 0;
    vm_region_submap_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
    if (vm_region_recurse_64(mach_task_self(), &ra, &rs, &depth, (vm_region_recurse_info_t)&info, &cnt) == KERN_SUCCESS
        && ra < 0x190000000ul) {
        early[4] = ra;
        early[5] = rs;
        early_tag = info.user_tag;
        early_prot = (unsigned)info.protection;
    }
    early_claimed = 1;
}

// 1 when this launch made the claim; out gets window base and size, pool base and size, intruder base and
// size, intruder tag and protection.
int gow3_wine_early_claim_result(unsigned long out[8])
{
    for (int i = 0; i < 6; i++) out[i] = early[i];
    out[6] = early_tag;
    out[7] = early_prot;
    return early_claimed;
}
