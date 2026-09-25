/* kwinwrap — ptrace supervisor that logs every DRM_IOCTL_MODE_ATOMIC issued
 * by a child process tree (and eventually can rewrite them).
 *
 * usage: kwinwrap --out LOG [--] prog args...
 * run as root; child drops uid/gid via env KWINWRAP_UID/KWINWRAP_GID.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <grp.h>
#include <pwd.h>
#include <fcntl.h>
#include <dirent.h>
#include <signal.h>
#include <time.h>
#include <sys/ptrace.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <sys/uio.h>
#include <sys/syscall.h>
#include <sys/prctl.h>
#include <poll.h>
#include <linux/elf.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <sys/syscall.h>
#include <linux/major.h>
#include <asm-generic/statfs.h>
#include <stdint.h>
#include <linux/seccomp.h>
#include <linux/filter.h>
#include <linux/audit.h>

static long long nsnow(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

struct ptregs { unsigned long long regs[31]; unsigned long long sp, pc, pstate; };

static FILE *LOG;
static int DRMFD = -1;
static int RELAYFD = -1;   /* dup of the lease fd — kwin's FB/blob namespace */
static int LEASE = 0;      /* KWINWRAP_LEASE=1 to enable (default OFF:
                            * v6.6 drm_lease_held() returns true for non-master
                            * files, so kwin's auth=0 side-file sees through
                            * the lease; blobs there then miss on the lease
                            * relay fd. GetResources rewriting replaced it.) */
static char propnames[512][16];

static const char *pname(unsigned id) {
    if (id >= 512) return "?";
    if (propnames[id][0]) return propnames[id];
    if (DRMFD >= 0) {
        drmModePropertyRes *p = drmModeGetProperty(DRMFD, id);
        if (p) { snprintf(propnames[id], 16, "%s", p->name); drmModeFreeProperty(p);
                 return propnames[id]; }
    }
    snprintf(propnames[id], 16, "prop%u", id);
    return propnames[id];
}

static int getregs(pid_t t, struct ptregs *r) {
    struct iovec io = { .iov_base = r, .iov_len = sizeof *r };
    return ptrace(PTRACE_GETREGSET, t, (void *)NT_PRSTATUS, &io) ? -1 : 0;
}

static __u32 find_prop(unsigned obj, uint32_t obj_type, const char *name) {
    drmModeObjectProperties *p =
        drmModeObjectGetProperties(DRMFD, obj, obj_type);
    if (!p) return 0;
    __u32 id = 0;
    for (uint32_t i = 0; i < p->count_props && !id; i++) {
        drmModePropertyRes *q = drmModeGetProperty(DRMFD, p->props[i]);
        if (q) {
            if (!strcmp(q->name, name)) id = q->prop_id;
            drmModeFreeProperty(q);
        }
    }
    drmModeFreeObjectProperties(p);
    return id;
}

static ssize_t readmem(pid_t t, unsigned long long addr, void *buf, size_t n) {
    /* AT_SECURE tracees (capability binaries) are non-dumpable, so
     * process_vm_readv / /proc/pid/mem fail with EPERM; PEEKDATA through the
     * existing ptrace link still works. */
    unsigned char *dst = buf;
    size_t orig_n = n;
    unsigned long long a = addr & ~7ULL;
    long first = ptrace(PTRACE_PEEKDATA, t, (void *)a, NULL);
    if (first == -1 && errno) return -1;
    unsigned char *src = (unsigned char *)&first + (addr - a);
    size_t head = 8 - (size_t)(addr - a);
    if (head > n) head = n;
    memcpy(dst, src, head);
    dst += head; a += 8; n -= head;
    while (n) {
        long w = ptrace(PTRACE_PEEKDATA, t, (void *)a, NULL);
        if (w == -1 && errno) return -1;
        size_t chunk = n < 8 ? n : 8;
        memcpy(dst, &w, chunk);
        dst += chunk; a += 8; n -= chunk;
    }
    return (ssize_t)orig_n;
}

static void dump_commit(pid_t t, unsigned long long uptr) {
    struct drm_mode_atomic a;
    if (readmem(t, uptr, &a, sizeof a) != (ssize_t)sizeof a) {
        fprintf(LOG, "ATOMIC: readmem struct failed (%s)\n", strerror(errno));
        fflush(LOG); return;
    }
    __u32 cnts[64], objs[64];
    __u32 nobj = a.count_objs > 64 ? 64 : a.count_objs;
    if (readmem(t, a.objs_ptr, objs, nobj * 4) < 0 ||
        readmem(t, a.count_props_ptr, cnts, nobj * 4) < 0) {
        fprintf(LOG, "ATOMIC: readmem arrays failed (%s)\n", strerror(errno));
        fflush(LOG); return;
    }
    unsigned total = 0;
    for (__u32 i = 0; i < nobj; i++) total += cnts[i];
    if (total > 2048) total = 2048;
    static __u32 props[2048];
    static __u64 vals[2048];
    if (readmem(t, a.props_ptr, props, total * 4) < 0 ||
        readmem(t, a.prop_values_ptr, vals, total * 8) < 0) {
        fprintf(LOG, "ATOMIC: readmem props failed (%s)\n", strerror(errno));
        fflush(LOG); return;
    }
    fprintf(LOG, "=== ATOMIC tid=%d nobjs=%u flags=0x%x%s ===\n",
            t, a.count_objs, a.flags,
            (a.flags & DRM_MODE_ATOMIC_TEST_ONLY) ? " TEST_ONLY" : "");
    unsigned off = 0;
    for (__u32 o = 0; o < nobj; o++) {
        fprintf(LOG, "  obj=%u n=%u\n", objs[o], cnts[o]);
        for (__u32 i = 0; i < cnts[o] && off + i < 2048; i++)
            fprintf(LOG, "    %-18s = 0x%llx\n",
                    pname(props[off + i]), (unsigned long long)vals[off + i]);
        off += cnts[o];
    }
    fflush(LOG);
}

struct phase { pid_t t; int p; int sub; unsigned long long nr;
               long long hret; long long e_ns; char path[96]; int foreign; };

/* PTRACE_O_TRACEFORK auto-attaches every forked child (Xwayland, plasma-keyboard,
 * ... started by kwin) to this tracer, and the inherited seccomp filter keeps
 * reporting their openat/ioctl to us. Only the compositor itself may have its
 * card/render opens rewritten — for anyone else just resume and don't touch. */
static pid_t CHILD;
static pid_t tgid_of(pid_t t) {
    char p[64];
    FILE *f;
    char line[256];
    pid_t tg = -1;
    snprintf(p, sizeof p, "/proc/%d/status", t);
    if (!(f = fopen(p, "r"))) return -1;
    while (fgets(line, sizeof line, f))
        if (sscanf(line, "Tgid: %d", &tg) == 1) break;
    fclose(f);
    return tg;
}

static int setregs(pid_t t, struct ptregs *r) {
    struct iovec io = { .iov_base = r, .iov_len = sizeof *r };
    return ptrace(PTRACE_SETREGSET, t, (void *)NT_PRSTATUS, &io) ? -1 : 0;
}

#define NR_IOCTL   29
#define NR_OPENAT  56

/* ---- targeted interception (KWINWRAP_SECCOMP=1) ------------------------
 * Plain PTRACE_SYSCALL stops the tracee on EVERY syscall of every thread:
 * freedreno GL submits hundreds of ioctls per frame, the tracer saturates a
 * core processing stops, and commit dt/exec balloons to 100+ ms (~9 fps).
 * Installing a seccomp RET_TRACE filter in the child makes it stop only at
 * the four syscalls we actually rewrite/log: ioctl(ATOMIC|GETRESOURCES),
 * openat, openat2.  Tracer then arms the matching exit with one
 * PTRACE_SYSCALL and resumes everything else with PTRACE_CONT. */
static int SECCMODE;
static int nattempt;
#ifndef PTRACE_EVENT_SECCOMP
#define PTRACE_EVENT_SECCOMP 7
#endif

static int install_drm_filter(void) {
    static struct sock_filter f[] = {
        /* 0 */ BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                         offsetof(struct seccomp_data, arch)),
        /* 1 */ BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_AARCH64, 0, 10),
        /* 2 */ BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                         offsetof(struct seccomp_data, nr)),
        /* 3 */ BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 29, 2, 0),
        /* 4 */ BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 56, 6, 0),
        /* 5 */ BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 437, 5, 6),
        /* 6 */ BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                         offsetof(struct seccomp_data, args) + 8),
        /* 7 */ BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,
                         DRM_IOCTL_MODE_ATOMIC, 1, 0),
        /* 8 */ BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,
                         DRM_IOCTL_MODE_GETRESOURCES, 1, 3),
        /* 9 */ BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRACE | 0x10),
        /*10 */ BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRACE | 0x11),
        /*11 */ BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRACE | 0x12),
        /*12 */ BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog fp = { sizeof f / sizeof f[0], f };
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) return -1;
    if (syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, 0, &fp) == 0) return 0;
    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &fp) == 0) return 0;
    return -1;
}
#define DRM_SET_MASTER_REQ 0x4004641EULL
#define DRM_DROP_MASTER_REQ 0xC004641FULL

/* --- fd hijack (Plan C, dup flavor) ---
 * ptraced-context SET_MASTER is policy-denied on this vendor kernel, so root
 * kwinwrap acquires master BEFORE fork. At the ENTRY stop of every
 * openat(*card*), the syscall itself is rewritten to dup(HIJACK_FD): the
 * tracee never touches the card node and receives a fresh, real fd that
 * shares the master file_priv (all close()/fd-number bookkeeping stays
 * natural — return-value rewriting would alias when kwin opens the same
 * node twice, cf. DrmDevice::openWithAuthentication re-opening).
 */
#define HIJACK_FD 250
#define NR_DUP    99
static int HIJACK;
static int MASTERFD = -1;
/* -1 = unknown (probe mode: kwin owns real card fds after our DROP_MASTER),
 *  1 = kwin commits natively (passthrough),  0 = relay through kwinwrap's fd */
static int NATIVE = -1;

static int hijack_entry(pid_t t, struct ptregs *R, const char *path) {
    /* kwin commits atomics on the RENDER node fd (regs[0]==-2 proved it) —
     * render files can never be master -> every commit -13. Redirect card
     * AND render opens onto our master file. */
    if (!strstr(path, "card") && !strstr(path, "render")) return 0;
    struct ptregs d = *R;
    d.regs[8] = NR_DUP;
    d.regs[0] = HIJACK_FD;
    if (setregs(t, &d)) {
        fprintf(LOG, "HIJACK setregs failed (%s)\n", strerror(errno));
        return 0;
    }
    fprintf(LOG, "HIJACK openat(%s) tid=%d -> dup(%d)\n", path, t, HIJACK_FD);
    fflush(LOG);
    return 1;
}

static void log_hijack_result(pid_t t, long long fd) {
    fprintf(LOG, "HIJACK -> fd=%lld %s\n", fd,
            fd < 0 ? strerror((int)-fd) : "OK");
    fflush(LOG);
}

static void log_card_open(pid_t t, long fd, const char *path) {
    if (!strstr(path, "card") && !strstr(path, "render")) return;
    fprintf(LOG, "openat tid=%d fd=%ld %s\n", t, fd,
            path[0] ? path : "(unreadable)");
    fflush(LOG);
}

static void peekstr(pid_t t, unsigned long long addr, char *out, size_t max) {
    size_t i = 0;
    long w = 0;
    unsigned long long cur = ~0ULL;
    while (i + 1 < max) {
        unsigned long long a = addr + i;
        if ((a & ~7ULL) != cur) {
            errno = 0;
            w = ptrace(PTRACE_PEEKDATA, t, (void *)(a & ~7ULL), NULL);
            if (w == -1 && errno) break;
            cur = a & ~7ULL;
        }
        unsigned char c = ((unsigned char *)&w)[a & 7];
        out[i++] = (char)c;
        if (!c) { out[i - 1] = 0; return; }
    }
    out[i] = 0;
}

static struct phase phases[512];
static int nphase;

/* Signal-stop merges (a pending signal reported at a syscall boundary) can
 * flip a p-toggle parity, after which "entry" handlers run on exit stops and
 * vice versa — dmesg proved kwin's original ioctls still executed despite
 * the x8=-1 skip. Ask the kernel for the true direction instead. */
#ifndef PTRACE_GET_SYSCALL_INFO
#define PTRACE_GET_SYSCALL_INFO 0x4209
#endif
struct ksyscall_info {
    unsigned char op; unsigned char pad[3]; unsigned int arch;
    unsigned long long ip, sp;
    union {
        struct { unsigned long long nr, args[6]; } entry;
        struct { long long ret; unsigned long long flags, data1, data2; } exit_;
    };
};
/* returns 1=entry, 2=exit, 0=unknown */
static int syscall_dir(pid_t t) {
    struct ksyscall_info si;
    errno = 0;
    long n = ptrace(PTRACE_GET_SYSCALL_INFO, t, (long)sizeof si, &si);
    if (n <= 0 || si.op == 0 || si.op > 3) return 0;
    return si.op;   /* PTRACE_SYSCALL_INFO_ENTRY=1 EXIT=2 */
}

/* ---- rewrite mode: strip kwin's phantom outputs, keep only real panel ---- */
static int FILTER;
static unsigned KEEP_OBJS[8] = { 67, 206, 97 };
static int NKEEP = 3;

static void init_keep(void) {
    char *e = getenv("KWINWRAP_KEEP");
    if (!e) return;
    int n = 0;
    for (char *s = strtok(e, ","); s && n < 8; s = strtok(NULL, ","))
        KEEP_OBJS[n++] = (unsigned)strtoul(s, NULL, 0);
    if (n) NKEEP = n;
}

static int keep_obj(unsigned id) {
    for (int i = 0; i < NKEEP; i++)
        if (KEEP_OBJS[i] == id) return 1;
    return 0;
}

static int keep_prop(unsigned obj, const char *name) {
    if (obj == 67)  return !strcmp(name, "CRTC_ID");   /* link-status kills it */
    if (obj == 206) return !strcmp(name, "MODE_ID") || !strcmp(name, "ACTIVE");
    return 1;  /* plane 97: pass through */
}

static int writeto(pid_t t, unsigned long long addr, const void *buf, size_t n) {
    const unsigned char *src = buf;
    unsigned long long a = addr & ~7ULL;
    size_t pre = (size_t)(addr - a);
    if (pre || n < 8) {
        long w = ptrace(PTRACE_PEEKDATA, t, (void *)a, NULL);
        if (w == -1 && errno) return -1;
        unsigned char *wb = (unsigned char *)&w;
        size_t k = 8 - pre; if (k > n) k = n;
        memcpy(wb + pre, src, k);
        if (ptrace(PTRACE_POKEDATA, t, (void *)a, (void *)w)) return -1;
        src += k; n -= k; a += 8;
    }
    while (n) {
        unsigned char b[8] = {0};
        size_t k = n < 8 ? n : 8;
        memcpy(b, src, k);
        long w;
        memcpy(&w, b, 8);
        if (k < 8) {
            long old = ptrace(PTRACE_PEEKDATA, t, (void *)a, NULL);
            if (old == -1 && errno) return -1;
            memcpy(b + k, (unsigned char *)&old + k, 8 - k);
            memcpy(&w, b, 8);
        }
        if (ptrace(PTRACE_POKEDATA, t, (void *)a, (void *)w)) return -1;
        src += k; n -= k; a += 8;
    }
    return 0;
}

static void filter_commit(pid_t t, unsigned long long uptr,
                          struct ptregs *r) {
    struct drm_mode_atomic a;
    if (readmem(t, uptr, &a, sizeof a) != (ssize_t)sizeof a) return;
    if (a.count_objs > 64) return;
    __u32 objs[64], cnts[64];
    __u32 nobj = a.count_objs;
    if (readmem(t, a.objs_ptr, objs, nobj * 4) < 0 ||
        readmem(t, a.count_props_ptr, cnts, nobj * 4) < 0) return;
    unsigned total = 0;
    for (__u32 i = 0; i < nobj; i++) total += cnts[i];
    if (total > 2048) return;
    static __u32 props[2048];
    static __u64 vals[2048];
    if (readmem(t, a.props_ptr, props, total * 4) < 0 ||
        readmem(t, a.prop_values_ptr, vals, total * 8) < 0) return;

    __u32 nobjs2 = 0, nprops2 = 0;
    __u32 objs2[64], cnts2[64], props2[2048];
    __u64 vals2[2048];
    unsigned off = 0;
    for (__u32 o = 0; o < nobj; o++) {
        unsigned kept = 0;
        if (keep_obj(objs[o])) {
            for (__u32 i = 0; i < cnts[o]; i++)
                if (keep_prop(objs[o], pname(props[off + i]))) {
                    props2[nprops2] = props[off + i];
                    vals2[nprops2]  = vals[off + i];
                    nprops2++; kept++;
                }
        }
        if (kept) { objs2[nobjs2] = objs[o]; cnts2[nobjs2] = kept; nobjs2++; }
        off += cnts[o];
    }
    if (nobjs2 == nobj && nprops2 == total) return;  /* nothing to strip */

    /* scratch: below this thread's stack pointer, 8-byte aligned */
    unsigned long long sp = (r->sp - 0x4000) & ~0xFULL;
    unsigned long long p_objs = sp;
    unsigned long long p_cnts = sp + 64 * 4;
    unsigned long long p_props = sp + 2 * 64 * 4;
    unsigned long long p_vals = sp + 2 * 64 * 4 + 2048 * 4;
    if (writeto(t, p_objs, objs2, nobjs2 * 4) ||
        writeto(t, p_cnts, cnts2, nobjs2 * 4) ||
        writeto(t, p_props, props2, nprops2 * 4) ||
        writeto(t, p_vals, vals2, (size_t)nprops2 * 8)) {
        fprintf(LOG, "FILTER: writeto failed (%s)\n", strerror(errno));
        fflush(LOG); return;
    }
    a.count_objs = nobjs2;
    a.objs_ptr = p_objs;
    a.count_props_ptr = p_cnts;
    a.props_ptr = p_props;
    a.prop_values_ptr = p_vals;
    if (writeto(t, uptr, &a, sizeof a)) {
        fprintf(LOG, "FILTER: poke struct failed (%s)\n", strerror(errno));
        fflush(LOG); return;
    }
    fprintf(LOG, ">>> FILTER: nobjs %u->%u nprops %u->%u\n",
            nobj, nobjs2, total, nprops2);
    for (__u32 o = 0; o < nobjs2; o++) fprintf(LOG, "    kept obj=%u n=%u\n", objs2[o], cnts2[o]);
    fflush(LOG);
}

/* ---- ATOMIC relay -------------------------------------------------------
 * dmesg showed kwin's MODE_ATOMIC ioctls executing with auth=0 — they are
 * not on the hijacked master file (render-node/join fd, cf. Anland kwin +
 * vendor kernel that permits atomic-on-render), hence the -13. So execute
 * the request HERE, in kwinwrap's own untraced root context on
 * DRMFD (same file as the hijacked dups: object/blob/FB namespace shared),
 * and hand the result back to the child by skipping its syscall (x8 = -1
 * at true entry stop -> -ENOSYS at its exit stop, which we overwrite with
 * the relay's raw ret).
 * Sanitize for the context switch: IN_FENCE_FD values are child fd numbers
 * -> rewrite to -1 (kernel treats -1 as "no fence"); user_data
 * (out_fence_ptr) -> 0. When FILTER is on, phantom objects/props are
 * dropped from the LOCAL copy only — the child's memory stays untouched.
 */
static __u32 r_objs[64], r_cnts[64], r_props[2048];
static __u64 r_vals[2048];

static int build_local_atomic(pid_t t, unsigned long long uptr,
                              struct drm_mode_atomic *la) {
    if (readmem(t, uptr, la, sizeof *la) != (ssize_t)sizeof *la) return -1;
    struct drm_mode_atomic src = *la;
    if (src.count_objs > 64) return -1;
    __u32 objs[64], cnts[64];
    if (readmem(t, src.objs_ptr, objs, src.count_objs * 4) < 0 ||
        readmem(t, src.count_props_ptr, cnts, src.count_objs * 4) < 0)
        return -1;
    unsigned total = 0;
    for (__u32 i = 0; i < src.count_objs; i++) total += cnts[i];
    if (total > 2048) return -1;
    __u32 props[2048];
    __u64 vals[2048];
    if (readmem(t, src.props_ptr, props, total * 4) < 0 ||
        readmem(t, src.prop_values_ptr, vals, total * 8) < 0)
        return -1;

    /* Dynamic target: kwin probes connector 67 against different crtcs;
     * whatever CRTC this request links 67 to (T) must itself survive the
     * filter, else the kernel sees "enabled/connectors mismatch" -22. */
    unsigned T = 0;
    int dyn = 0;
    __u64 crtc_of[64];
    int has_mode[64];
    if (FILTER) {
        unsigned o2 = 0;
        for (__u32 o = 0; o < src.count_objs; o++) {
            crtc_of[o] = ~0ULL; has_mode[o] = 0;
            for (__u32 i = 0; i < cnts[o]; i++, o2++) {
                const char *nm = pname(props[o2]);
                if (!strcmp(nm, "CRTC_ID")) crtc_of[o] = vals[o2];
                else if (!strcmp(nm, "MODE_ID")) has_mode[o] = 1;
                else if (!strcmp(nm, "link-status") || !strcmp(nm, "CONNECTORS_ID"))
                    has_mode[o] = 2;   /* connector-ish, never a plane */
            }
        }
        for (__u32 o = 0; o < src.count_objs; o++)
            if (objs[o] == 67 && crtc_of[o] != ~0ULL) { T = (unsigned)crtc_of[o]; dyn = 1; }
    }

    __u32 nobjs2 = 0, nprops2 = 0;
    unsigned off = 0;
    for (__u32 o = 0; o < src.count_objs; o++) {
        int is67 = objs[o] == 67;
        int keepobj = !dyn || is67 || (dyn && T && objs[o] == T) ||
                      (dyn && T && crtc_of[o] == T && !has_mode[o]);
        unsigned kept = 0;
        for (__u32 i = 0; i < cnts[o]; i++, off++) {
            const char *nm = pname(props[off]);
            if (dyn && !keepobj) continue;
            if (dyn && is67 && strcmp(nm, "CRTC_ID")) continue;
            if (dyn && T && objs[o] == T &&
                strcmp(nm, "MODE_ID") && strcmp(nm, "ACTIVE")) continue;
            r_props[nprops2] = props[off];
            r_vals[nprops2] = !strcmp(nm, "IN_FENCE_FD") ? ~0ULL : vals[off];
            nprops2++; kept++;
        }
        if (kept) { r_objs[nobjs2] = objs[o]; r_cnts[nobjs2] = kept; nobjs2++; }
    }
    la->count_objs = nobjs2;
    la->objs_ptr = (unsigned long long)(uintptr_t)r_objs;
    la->count_props_ptr = (unsigned long long)(uintptr_t)r_cnts;
    la->props_ptr = (unsigned long long)(uintptr_t)r_props;
    la->prop_values_ptr = (unsigned long long)(uintptr_t)r_vals;
    la->reserved = 0;
    /* kernel treats user_data as an opaque event cookie; keep the child's
     * value so flip completion events carry the pointer kwin expects */
    la->user_data = src.user_data;
    return 0;
}

/* dmesg-proven: this kernel validates atomic flags with the 0x100/0x200/
 * 0x400 encoding (same as the container headers) — kwin's 0x500 reaches the
 * driver; only our translated 0x5 was rejected as "invalid flag". Relay raw. */
static long relay_atomic(struct drm_mode_atomic *la) {
    int ret = ioctl(RELAYFD >= 0 ? RELAYFD : DRMFD, DRM_IOCTL_MODE_ATOMIC, la);
    int e = errno;
    return ret < 0 ? -e : 0;
}

/* ---- primary-plane dual-pipe split --------------------------------------
 * This 3200x2136 dual-DSI panel cannot be driven by a single legacy pipe:
 * kwin picks plane97 (legacy virtual) and everything scans out garbled
 * (花屏, proven across GL + QPainter rounds). The vendor composer and our
 * own band commits use SSPP planes 161 (left half) + 157 (right half) fed
 * the SAME framebuffer. So rewrite every kwin commit that touches plane97
 * in-place (scratch below the thread's SP — unused while it sits in its
 * own syscall) into that two-plane layout. kwin then EXECUTES THE REWRITTEN
 * COMMIT ITSELF on its native master fd: ret, flip events, fences all stay
 * on the natural path.
 */
#define SPLIT_PLANE_VIRT 97u
#define SPLIT_PLANE_VIRT2 129u
#define SPLIT_PLANE_L    161u
#define SPLIT_PLANE_R    157u
#define SPLIT_CRTC       206u
#define SPLIT_CONN       67u
#define SPLIT_W 1600u
#define SPLIT_H 2136u
static __u32 s_objs[64], s_cnts[64], s_props[2048], s_props2[2048];
static __u64 s_vals[2048], s_vals2[2048];
static __u32 pl_fb, pl_crtc, pl_sx, pl_sy, pl_sw, pl_sh, pl_cx, pl_cy, pl_cw, pl_ch;
/* forensics: last poked scratch, so the exit-stop handler can dump what
 * the kernel actually consumed when a rebuilt commit still fails */
static pid_t sc_tid = -1;
static unsigned long long sc_sp;
static __u32 sc_no, sc_np;
static int sc_dumped;

static void split_commit(pid_t t, unsigned long long uptr, struct ptregs *r) {
    struct drm_mode_atomic a;
    if (readmem(t, uptr, &a, sizeof a) != (ssize_t)sizeof a) return;
    __u32 nobj = a.count_objs;
    if (nobj == 0 || nobj > 60) return;
    if (readmem(t, a.objs_ptr, s_objs, nobj * 4) < 0 ||
        readmem(t, a.count_props_ptr, s_cnts, nobj * 4) < 0) return;
    int p97 = -1, pdup = -1;
    unsigned total = 0, eoff[64];
    for (__u32 i = 0; i < nobj; i++) {
        eoff[i] = total;
        if (s_objs[i] == SPLIT_PLANE_VIRT || s_objs[i] == SPLIT_PLANE_VIRT2) {
            if (p97 < 0) p97 = (int)i;
            else if (pdup < 0) pdup = (int)i;
        }
        total += s_cnts[i];
    }
    if (total > 2000) return;
    if (readmem(t, a.props_ptr, s_props, total * 4) < 0 ||
        readmem(t, a.prop_values_ptr, s_vals, (size_t)total * 8) < 0) return;

    /* Inventory. kwin's choice of plane/crtc varies round to round (it
     * re-probes and falls back to REAL planes 133/141 on REAL crtcs
     * 271/280/298 when a test fails — that raw phase showed black garbage:
     * one full-width plane cannot drive the split DSI panel). So never
     * assume the fake plane or crtc 206 were picked: steal the framebuffer
     * from whichever plane is active, force halves onto crtc 206, and
     * re-home whatever connector/crtc the commit lights up. */
    __u64 fb = 0, kblob = 0;
    int kact = -1, i206 = -1, iconn = -1, areal = -1;
    int areal_fb = -1, areal_crtc = -1, kact_act = -1, kact_mode = -1;
    int i206_act = -1, i206_mode = -1, iconn_crtc = -1;
    for (__u32 o = 0; o < nobj; o++) {
        if ((int)o == p97 || (int)o == pdup) continue;
        unsigned base = eoff[o];
        __u32 oc = s_cnts[o];
        int i_act = -1, i_mode = -1, i_crtc = -1, i_fb = -1;
        for (__u32 i = 0; i < oc; i++) {
            const char *nm = pname(s_props[base + i]);
            if (!strcmp(nm, "ACTIVE")) i_act = (int)i;
            else if (!strcmp(nm, "MODE_ID")) i_mode = (int)i;
            else if (!strcmp(nm, "CRTC_ID")) i_crtc = (int)i;
            else if (!strcmp(nm, "FB_ID")) i_fb = (int)i;
        }
        if (s_objs[o] == SPLIT_CRTC && i_act >= 0) {
            i206 = (int)o; i206_act = i_act; i206_mode = i_mode;
            continue;
        }
        if (i_act >= 0 && s_vals[base + i_act]) {   /* crtc kwin lights up */
            kact = (int)o; kact_act = i_act; kact_mode = i_mode;
            kblob = i_mode >= 0 ? s_vals[base + i_mode] : 0;
            continue;
        }
        if (s_objs[o] == SPLIT_CONN) {
            if (i_crtc >= 0 && s_vals[base + i_crtc] != SPLIT_CRTC) {
                iconn = (int)o; iconn_crtc = i_crtc;
            }
            continue;
        }
        if (i_fb >= 0 && i_crtc >= 0 && s_vals[base + i_crtc] && areal < 0) {
            areal = (int)o; areal_fb = i_fb; areal_crtc = i_crtc;
            fb = s_vals[base + i_fb];
        }
    }
    if (p97 >= 0) {
        unsigned base = eoff[p97];
        for (__u32 i = 0; i < s_cnts[p97]; i++)
            if (!strcmp(pname(s_props[base + i]), "FB_ID") && s_vals[base + i]) {
                fb = s_vals[base + i];
                break;
            }
    }
    int do_split = fb != 0;
    if (do_split && kact >= 0 && !kblob) {
        __u32 mp = find_prop(SPLIT_CRTC, DRM_MODE_OBJECT_CRTC, "MODE_ID");
        drmModeObjectProperties *cp =
            drmModeObjectGetProperties(DRMFD, SPLIT_CRTC,
                                       DRM_MODE_OBJECT_CRTC);
        if (mp && cp) {
            for (uint32_t i = 0; i < cp->count_props; i++)
                if (cp->props[i] == mp) { kblob = cp->prop_values[i]; break; }
            drmModeFreeObjectProperties(cp);
        }
    }
    if (p97 < 0 && areal < 0 && kact < 0 && iconn < 0) {
        static int np97;
        if (++np97 <= 3) {
            fprintf(LOG, "SPLIT: nothing to steal (nobj=%u objs:", nobj);
            for (__u32 i = 0; i < nobj && i < 16; i++)
                fprintf(LOG, " %u", s_objs[i]);
            fprintf(LOG, "\n");
            fflush(LOG);
        }
        return;
    }
    __u32 virt_id = p97 >= 0 ? s_objs[p97] :
                    (areal >= 0 ? s_objs[areal] : 0);
    if (!do_split) {
        static int nskip;
        if (++nskip <= 3) {
            fprintf(LOG, "SPLIT: idle virt, strip only (#%d) virt=%u\n",
                    nskip, virt_id);
            fflush(LOG);
        }
    }
    if (do_split) {
        if (!pl_crtc) {
            pl_crtc = find_prop(SPLIT_PLANE_L, DRM_MODE_OBJECT_PLANE, "CRTC_ID");
            pl_fb = find_prop(SPLIT_PLANE_L, DRM_MODE_OBJECT_PLANE, "FB_ID");
            if (!pl_fb) pl_fb = find_prop(SPLIT_PLANE_L, DRM_MODE_OBJECT_PLANE, "FB");
            pl_sx = find_prop(SPLIT_PLANE_L, DRM_MODE_OBJECT_PLANE, "SRC_X");
            pl_sy = find_prop(SPLIT_PLANE_L, DRM_MODE_OBJECT_PLANE, "SRC_Y");
            pl_sw = find_prop(SPLIT_PLANE_L, DRM_MODE_OBJECT_PLANE, "SRC_W");
            pl_sh = find_prop(SPLIT_PLANE_L, DRM_MODE_OBJECT_PLANE, "SRC_H");
            pl_cx = find_prop(SPLIT_PLANE_L, DRM_MODE_OBJECT_PLANE, "CRTC_X");
            pl_cy = find_prop(SPLIT_PLANE_L, DRM_MODE_OBJECT_PLANE, "CRTC_Y");
            pl_cw = find_prop(SPLIT_PLANE_L, DRM_MODE_OBJECT_PLANE, "CRTC_W");
            pl_ch = find_prop(SPLIT_PLANE_L, DRM_MODE_OBJECT_PLANE, "CRTC_H");
            fprintf(LOG, "SPLIT: prop ids fb=%u crtc=%u src=%u/%u/%u/%u dst=%u/%u/%u/%u\n",
                    pl_fb, pl_crtc, pl_sx, pl_sy, pl_sw, pl_sh, pl_cx, pl_cy, pl_cw, pl_ch);
            fflush(LOG);
        }
        if (!pl_fb || !pl_crtc || !pl_sx || !pl_cw) return;
    }

    /* If a half-pipe plane is already an object in this commit (kwin lists all
     * idle planes every frame), rewriting it in place beats appending a
     * duplicate — duplicate plane objects collide in kernel state (src_h=0
     * garbage -> check failure / E2BIG). */
    __u32 no = 0, np = 0;
    unsigned off = 0;
    int hfound[2] = {0, 0};
    const __u32 halves[2] = { SPLIT_PLANE_L, SPLIT_PLANE_R };
    /* dmesg-proven: on a real commit carrying PAGE_FLIP_EVENT the kernel
     * creates a vblank event for EVERY crtc state in the commit; an event on
     * an off pipe fails drm_atomic_crtc_check ("requesting event but off",
     * -EINVAL) while TEST_ONLY commits never get here. So never carry a
     * crtc that stays off (271's VRR-only no-op entries, kact shutdowns). */
    int evdrop = !(a.flags & DRM_MODE_ATOMIC_TEST_ONLY) &&
                 (a.flags & DRM_MODE_PAGE_FLIP_EVENT);
    for (__u32 o = 0; o < nobj; o++) {
        __u32 oc = s_cnts[o];   /* snapshot: s_cnts[no] write may alias s_cnts[o] */
        if ((int)o == p97 || (int)o == pdup) { off += oc; continue; }
        if (evdrop) {
            int is_crtc = 0, lit = 0;
            for (__u32 i = 0; i < oc; i++) {
                const char *nm = pname(s_props[off + i]);
                int crtcy = !strcmp(nm, "ACTIVE") || !strcmp(nm, "MODE_ID") ||
                            !strcmp(nm, "VRR_ENABLED");
                is_crtc |= crtcy;
                if (crtcy && s_vals[off + i]) lit = 1;
            }
            if (is_crtc && !lit) {
                static int nevd;
                if (++nevd <= 3) {
                    fprintf(LOG, "EVDROP: off crtc %u stripped from 0x%x (#%d)\n",
                            s_objs[o], a.flags, nevd);
                    fflush(LOG);
                }
                off += oc;
                continue;
            }
        }
        int hidx = (s_objs[o] == halves[0]) ? 0 :
                   (s_objs[o] == halves[1]) ? 1 : -1;
        if (do_split && hidx >= 0) {
            __u32 n0 = np;
            s_props2[np] = pl_crtc; s_vals2[np++] = SPLIT_CRTC;
            s_props2[np] = pl_fb;   s_vals2[np++] = fb;
            s_props2[np] = pl_sx; s_vals2[np++] = (__u64)hidx * SPLIT_W << 16;
            s_props2[np] = pl_sy; s_vals2[np++] = 0;
            s_props2[np] = pl_sw; s_vals2[np++] = (__u64)SPLIT_W << 16;
            s_props2[np] = pl_sh; s_vals2[np++] = (__u64)SPLIT_H << 16;
            s_props2[np] = pl_cx; s_vals2[np++] = (__u64)hidx * SPLIT_W;
            s_props2[np] = pl_cy; s_vals2[np++] = 0;
            s_props2[np] = pl_cw; s_vals2[np++] = SPLIT_W;
            s_props2[np] = pl_ch; s_vals2[np++] = SPLIT_H;
            s_objs[no] = s_objs[o];
            s_cnts[no] = np - n0;
            no++;
            hfound[hidx] = 1;
            off += oc;
            continue;
        }
        if (do_split && (int)o == areal) {
            /* disable the real full-width plane we took the fb from */
            s_props2[np] = s_props[off + areal_fb]; s_vals2[np++] = 0;
            s_props2[np] = s_props[off + areal_crtc]; s_vals2[np++] = 0;
            s_objs[no] = s_objs[o];
            s_cnts[no] = 2;
            no++;
            off += oc;
            continue;
        }
        if (do_split && (int)o == kact) {
            /* kwin lit crtc K (271/280/298...): shut it down, 206 takes over */
            for (__u32 i = 0; i < oc; i++, off++) {
                s_props2[np] = s_props[off];
                s_vals2[np++] = ((int)i == kact_act || (int)i == kact_mode)
                                    ? 0 : s_vals[off];
            }
            s_objs[no] = s_objs[o];
            s_cnts[no] = oc;
            no++;
            continue;
        }
        if (do_split && (int)o == i206 && kact >= 0) {
            for (__u32 i = 0; i < oc; i++, off++) {
                __u64 v = s_vals[off];
                if ((int)i == i206_act) v = 1;
                else if (i206_mode >= 0 && (int)i == i206_mode) v = kblob;
                s_props2[np] = s_props[off];
                s_vals2[np++] = v;
            }
            if (i206_mode < 0 && kblob) {
                __u32 mp = find_prop(SPLIT_CRTC, DRM_MODE_OBJECT_CRTC, "MODE_ID");
                if (mp) { s_props2[np] = mp; s_vals2[np++] = kblob; oc++; }
            }
            s_objs[no] = s_objs[o];
            s_cnts[no] = oc;
            no++;
            continue;
        }
        if (do_split && (int)o == iconn) {
            for (__u32 i = 0; i < oc; i++, off++) {
                s_props2[np] = s_props[off];
                s_vals2[np++] = (int)i == iconn_crtc ? SPLIT_CRTC : s_vals[off];
            }
            s_objs[no] = s_objs[o];
            s_cnts[no] = oc;
            no++;
            continue;
        }
        /* Drop no-op plane entries (FB=0, CRTC=0, no live fence): kwin lists all
         * idle planes every commit; sde atomic_check time scales with objects,
         * and these entries cannot change kernel state (only 157/161 ever got
         * enabled by us; those hit the in-place branch above when listed). */
        if (hidx < 0) {
            int planeish = 0, active = 0;
            for (__u32 i = 0; i < oc; i++) {
                const char *nm = pname(s_props[off + i]);
                __u64 v = s_vals[off + i];
                if (!strcmp(nm, "FB_ID") || !strcmp(nm, "CRTC_ID")) {
                    planeish = 1;
                    if (v) { active = 1; break; }
                } else if (!strcmp(nm, "IN_FENCE_FD") && v != 0 &&
                           v != 0xffffffffffffffffULL) {
                    planeish = 1; active = 1; break;
                }
            }
            if (planeish && !active) { off += oc; continue; }
        }
        s_objs[no] = s_objs[o];
        s_cnts[no] = oc;
        no++;
        for (__u32 i = 0; i < oc; i++, off++) {
            s_props2[np] = s_props[off];
            s_vals2[np]  = s_vals[off];
            np++;
        }
    }
    if (do_split) {
        for (int h = 0; h < 2; h++) {
            if (hfound[h]) continue;
            __u32 n0 = np;
            s_props2[np] = pl_crtc; s_vals2[np++] = SPLIT_CRTC;
            s_props2[np] = pl_fb;   s_vals2[np++] = fb;
            s_props2[np] = pl_sx; s_vals2[np++] = (__u64)h * SPLIT_W << 16;
            s_props2[np] = pl_sy; s_vals2[np++] = 0;
            s_props2[np] = pl_sw; s_vals2[np++] = (__u64)SPLIT_W << 16;
            s_props2[np] = pl_sh; s_vals2[np++] = (__u64)SPLIT_H << 16;
            s_props2[np] = pl_cx; s_vals2[np++] = (__u64)h * SPLIT_W;
            s_props2[np] = pl_cy; s_vals2[np++] = 0;
            s_props2[np] = pl_cw; s_vals2[np++] = SPLIT_W;
            s_props2[np] = pl_ch; s_vals2[np++] = SPLIT_H;
            s_objs[no] = halves[h];
            s_cnts[no] = np - n0;
            no++;
        }
        if (kact >= 0 && i206 < 0 && kblob) {
            __u32 pa = find_prop(SPLIT_CRTC, DRM_MODE_OBJECT_CRTC, "ACTIVE");
            __u32 pm = find_prop(SPLIT_CRTC, DRM_MODE_OBJECT_CRTC, "MODE_ID");
            if (pa && pm) {
                __u32 n0 = np;
                s_props2[np] = pa; s_vals2[np++] = 1;
                s_props2[np] = pm; s_vals2[np++] = kblob;
                s_objs[no] = SPLIT_CRTC;
                s_cnts[no] = np - n0;
                no++;
            }
        }
    }

    static int ndebug;
    if (++ndebug <= 12) {
        fprintf(LOG, "BUILT: flags=0x%x no=%u np=%u total=%u cnts[", a.flags, no, np, total);
        for (__u32 i = 0; i < no; i++)
            fprintf(LOG, "%u,", s_cnts[i]);
        fprintf(LOG, "] objs:");
        unsigned o2 = 0;
        for (__u32 i = 0; i < no; i++) {
            fprintf(LOG, " %u[%u]", s_objs[i], s_cnts[i]);
            for (__u32 j = 0; j < s_cnts[i]; j++, o2++)
                fprintf(LOG, " %s#%u=0x%llx", pname(s_props2[o2]),
                        s_props2[o2], s_vals2[o2]);
        }
        fprintf(LOG, "\n");
        fflush(LOG);
    }

    unsigned long long sp = (r->sp - 0x8000) & ~0xFULL;
    unsigned long long p_objs = sp;
    unsigned long long p_cnts = sp + 64 * 4;
    unsigned long long p_props = sp + 2 * 64 * 4;
    unsigned long long p_vals = sp + 2 * 64 * 4 + 2048u * 4;
    if (writeto(t, p_objs, s_objs, no * 4) ||
        writeto(t, p_cnts, s_cnts, no * 4) ||
        writeto(t, p_props, s_props2, (size_t)np * 4) ||
        writeto(t, p_vals, s_vals2, (size_t)np * 8)) {
        fprintf(LOG, "SPLIT: writeback failed (%s)\n", strerror(errno));
        fflush(LOG);
        return;
    }
    a.count_objs = no;
    a.objs_ptr = p_objs;
    a.count_props_ptr = p_cnts;
    a.props_ptr = p_props;
    a.prop_values_ptr = p_vals;
    if (writeto(t, uptr, &a, sizeof a)) {
        fprintf(LOG, "SPLIT: poke struct failed (%s)\n", strerror(errno));
        fflush(LOG);
        return;
    }
    sc_tid = t; sc_sp = sp; sc_no = no; sc_np = np;
    {   /* verify the child really holds what we poked (counts + objs) */
        static __u32 vfy[64];
        if (readmem(t, p_cnts, vfy, no * 4) < 0 ||
            memcmp(vfy, s_cnts, no * 4) ||
            readmem(t, p_objs, vfy, no * 4) < 0 ||
            memcmp(vfy, s_objs, no * 4)) {
            fprintf(LOG, "SCRATCH MISMATCH no=%u: cnts=", no);
            for (__u32 i = 0; i < no; i++) fprintf(LOG, "%u,", vfy[i]);
            fprintf(LOG, " objs=");
            if (readmem(t, p_objs, vfy, no * 4) == (ssize_t)(no * 4))
                for (__u32 i = 0; i < no; i++) fprintf(LOG, "%u,", vfy[i]);
            fprintf(LOG, " (want cnts ");
            for (__u32 i = 0; i < no; i++) fprintf(LOG, "%u,", s_cnts[i]);
            fprintf(LOG, " objs ");
            for (__u32 i = 0; i < no; i++) fprintf(LOG, "%u,", s_objs[i]);
            fprintf(LOG, ")\n");
            fflush(LOG);
        }
    }
    static int nsplit;
    if (++nsplit <= 5 || (nsplit & 63) == 1) {
        fprintf(LOG, "SPLIT: virt=%u objs %u->%u fb=%llu split=%d kact=%d (#%d)\n",
                virt_id, nobj, no, fb, do_split, kact, nsplit);
        fflush(LOG);
    }
}

/* Every fd the child holds that could talk to DRM — dups of the lease all
 * readlink to /dev/dri/card0, so this catches side-opens (renderD etc.). */
static void dump_drm_fds(pid_t t) {
    char dir[64];
    snprintf(dir, sizeof dir, "/proc/%d/fd", t);
    DIR *d = opendir(dir);
    if (!d) { fprintf(LOG, "FDDUMP opendir failed\n"); return; }
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char p[300], tgt[256];
        snprintf(p, sizeof p, "%s/%s", dir, e->d_name);
        ssize_t n = readlink(p, tgt, sizeof tgt - 1);
        if (n <= 0) continue;
        tgt[n] = 0;
        if (strstr(tgt, "drm") || strstr(tgt, "card") || strstr(tgt, "render"))
            fprintf(LOG, "FDDUMP tid=%d fd=%s -> %s\n", t, e->d_name, tgt);
    }
    closedir(d);
    fflush(LOG);
}

/* ---- GETRESOURCES rewrite -------------------------------------------------
 * Phantom Virtual-1/2 (writeback) connectors become kwin outputs and break
 * its layer configuration. The lease experiment failed to hide them (a
 * non-master file sees through leases), so we intercept the kernel's
 * GETRESOURCES reply at the child's exit stop and repack the connector id
 * array without VIRTUAL/WRITEBACK-typed ones. Works on whatever fd kwin
 * actually enumerates with. Both passes are handled: count query (id_ptr=0)
 * and the real fetch. */
static __u32 bad_conn[16];
static int nbad_conn = -1;   /* -1 = not computed yet; >=0 = cached count */
static __u32 good_conn[32];
static int ngood_conn;

static void mark_bad_conns(void) {
    if (nbad_conn >= 0) return;
    nbad_conn = 0; ngood_conn = 0;
    drmModeRes *r = drmModeGetResources(DRMFD);
    if (!r) { nbad_conn = -1; return; }   /* retry next time */
    for (int i = 0; i < r->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(DRMFD, r->connectors[i]);
        if (!c) continue;
        if (c->connector_type == DRM_MODE_CONNECTOR_VIRTUAL ||
            c->connector_type == DRM_MODE_CONNECTOR_WRITEBACK) {
            if (nbad_conn < 16) bad_conn[nbad_conn++] = c->connector_id;
            fprintf(LOG, "GETRES: marking conn %u type %u bad\n",
                    c->connector_id, c->connector_type);
        } else if (ngood_conn < 32) {
            good_conn[ngood_conn++] = c->connector_id;
        }
        drmModeFreeConnector(c);
    }
    drmModeFreeResources(r);
    fflush(LOG);
}

/* kwin allocated its array from OUR patched count-query reply, so we know
 * the buffer holds exactly ngood_conn slots — regenerate the reply instead
 * of repacking what the kernel wrote (it fills from the top of its own
 * unfiltered walk and may have put bad ids in a short buffer). */
static void filter_getres(pid_t t, unsigned long long uptr) {
    mark_bad_conns();
    if (nbad_conn <= 0 || ngood_conn <= 0) return;
    struct drm_mode_card_res cr;
    if (readmem(t, uptr, &cr, sizeof cr) != (ssize_t)sizeof cr) return;
    if (cr.count_connectors == 0) return;
    unsigned oldc = cr.count_connectors;
    if (cr.connector_id_ptr) {
        if (writeto(t, cr.connector_id_ptr, good_conn, ngood_conn * 4)) {
            fprintf(LOG, "GETRES: poke ids failed (%s)\n", strerror(errno));
            return;
        }
    }
    cr.count_connectors = ngood_conn;
    if (writeto(t, uptr, &cr, sizeof cr)) {
        fprintf(LOG, "GETRES: poke struct failed (%s)\n", strerror(errno));
        return;
    }
    fprintf(LOG, "GETRES: conns %u->%d [%s]\n", oldc, ngood_conn,
            cr.connector_id_ptr ? "ids" : "count-only");
    fflush(LOG);
}

/* syscall-entry work, shared by the classic all-syscall stop and the
 * seccomp-event stop. */
static void handle_entry(pid_t t, struct phase *ph) {
    struct ptregs r;
    /* tri-state: 0 unknown, -1 the compositor itself, 1 a forked outsider */
    if (ph->foreign == 0)
        ph->foreign = (tgid_of(t) == CHILD) ? -1 : 1;
    if (ph->foreign == 1) {
        ph->nr = 0;
        ph->sub = 0;
        return;
    }
    if (getregs(t, &r)) return;
    ph->nr = r.regs[8];
    ph->sub = 0;
    if (r.regs[8] == NR_OPENAT || r.regs[8] == 437 /*openat2*/) {
        peekstr(t, r.regs[1], ph->path, sizeof ph->path);
        /* In probe/native mode kwin must get a REAL card file
         * (auto-master on first open after our DROP_MASTER);
         * dup'ing our fd would keep it forever non-master.
         * Only after the probe proved EACCES (NATIVE==0) we
         * resume the dup hijack and relay again. */
        if (HIJACK && NATIVE == 0 &&
            hijack_entry(t, &r, ph->path))
            ph->sub = 3;
    }
    if (r.regs[8] == 29 && r.regs[1] == DRM_IOCTL_MODE_GETRESOURCES) {
        fprintf(LOG, "GETRES entry tid=%d fd=%llu\n", t, r.regs[0]);
        fflush(LOG);
        if (HIJACK) ph->sub = 5;
    }
    if (r.regs[8] == 29 && r.regs[1] == DRM_IOCTL_MODE_ATOMIC) {
        ph->e_ns = nsnow();
        {
            struct drm_mode_atomic hd = { 0 };
            if (readmem(t, r.regs[2], &hd, sizeof hd) == (ssize_t)sizeof hd) {
                ph->hret = hd.flags;
                fprintf(LOG, ">>> ATOMIC tid=%d flags=0x%x nobj=%u\n",
                        t, hd.flags, hd.count_objs);
            }
            fflush(LOG);
        }
        if (NATIVE == -1 && MASTERFD >= 0) {
            /* probe: run kwin's RAW commit to learn if its fd
             * is master; do NOT split yet (would corrupt the
             * modeset probe and give a false negative) */
            nattempt++;
            dump_commit(t, r.regs[2]);
            if (nattempt == 1) dump_drm_fds(t);
            ph->sub = 6;
        } else if (NATIVE == 1) {
            struct drm_mode_atomic hd2 = { 0 };
            int have_hd = readmem(t, r.regs[2], &hd2, sizeof hd2) ==
                              (ssize_t)sizeof hd2;
            int is_test = have_hd && (hd2.flags & DRM_MODE_ATOMIC_TEST_ONLY);
            static int flipdump, applydump, s14dump;
            if (have_hd && hd2.count_objs == 14 && !is_test &&
                s14dump < 2) {
                s14dump++;
                fprintf(LOG, "--- steady flip14 #%d ---\n", s14dump);
                dump_commit(t, r.regs[2]);
            } else if (have_hd && hd2.count_objs == 15 && flipdump < 3) {
                flipdump++;
                fprintf(LOG, "--- steady %s #%d ---\n",
                        is_test ? "test" : "flip", flipdump);
                dump_commit(t, r.regs[2]);
            } else if (have_hd && hd2.count_objs == 30 && !is_test &&
                       applydump < 1) {
                applydump++;
                fprintf(LOG, "--- working apply #1 ---\n");
                dump_commit(t, r.regs[2]);
            }
            if (have_hd) {
                split_commit(t, r.regs[2], &r);
            }
            ph->sub = 2;   /* passthrough, log ret at exit */
        } else if (MASTERFD >= 0) {
            if (nattempt < 3) dump_commit(t, r.regs[2]);
            if (nattempt == 0) { dump_drm_fds(t); }
            nattempt++;
            struct drm_mode_atomic la = { 0 };
            long rr = -EINVAL;
            if (build_local_atomic(t, r.regs[2], &la) == 0)
                rr = relay_atomic(&la);
            else
                fprintf(LOG, "RELAY: build failed (%s)\n",
                        strerror(errno));
            fprintf(LOG, "RELAY tid=%d fd=%llu flags=0x%x nobjs=%u -> ret=%ld %s\n",
                    t, r.regs[0], la.flags, la.count_objs, rr,
                    rr ? strerror((int)-rr) : "OK");
            fflush(LOG);
            ph->sub = 4;
            ph->hret = rr;
            static int flip_poll_done;
            if (rr == 0 && !flip_poll_done && (la.flags & 0x1)) {
                flip_poll_done = 1;
                struct pollfd pfd = { DRMFD, POLLIN, 0 };
                int pr = poll(&pfd, 1, 2000);
                fprintf(LOG, "RELAY: flip-event poll ret=%d revents=0x%x\n",
                        pr, pr > 0 ? pfd.revents : 0);
                fflush(LOG);
            }
            struct ptregs s = r;
            s.regs[8] = ~0ULL;   /* skip: -> -ENOSYS */
            setregs(t, &s);
        } else {
            ph->sub = 2;
            dump_commit(t, r.regs[2]);
            if (FILTER) filter_commit(t, r.regs[2], &r);
        }
    }
}

int main(int argc, char **argv) {
    char *out = "/tmp/kwinwrap.log";
    int di = 1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--out") && i + 1 < argc) { out = argv[++i]; di = i + 1; }
        else if (!strcmp(argv[i], "--")) { di = i + 1; break; }
        else if (i == 1 || di == i) di = i;
    }
    if (di >= argc) { fprintf(stderr, "usage: kwinwrap --out LOG -- prog args...\n"); return 1; }
    LOG = fopen(out, "we");
    if (!LOG) { perror("open log"); return 1; }
    setvbuf(stderr, NULL, _IOLBF, 0);
    FILTER = getenv("KWINWRAP_FILTER") ? 1 : 0;
    SECCMODE = getenv("KWINWRAP_SECCOMP") ? 1 : 0;
    LEASE = getenv("KWINWRAP_LEASE") ? 1 : 0;
    init_keep();
    fprintf(LOG, "kwinwrap: FILTER=%d keep=%u,%u,%u uid=%d euid=%d\n", FILTER,
            KEEP_OBJS[0], KEEP_OBJS[1], KEEP_OBJS[2], getuid(), geteuid());
    { char caps[128] = ""; FILE *f = fopen("/proc/self/status", "r");
      if (f) { char ln[256]; while (fgets(ln, sizeof ln, f))
                   if (!strncmp(ln, "CapEff", 6)) { snprintf(caps, sizeof caps, "%s", ln); break; }
               fclose(f); }
      fprintf(LOG, "kwinwrap: %s", caps); fflush(LOG); }
    DRMFD = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    HIJACK = getenv("KWINWRAP_HIJACK") ? 1 : 0;
    if (HIJACK && DRMFD >= 0) {
        /* The FIRST open of card0 auto-becomes master when master is free
         * (drm_master_open -> drm_new_set_master), so never SET_MASTER on a
         * second fd — that is EBUSY. Claim DRMFD itself. */
        int mret = ioctl(DRMFD, DRM_SET_MASTER_REQ, 0);
        fprintf(LOG, "kwinwrap: hijack SET_MASTER on openfd %d ret=%d %s\n",
                DRMFD, mret, mret ? strerror(errno) : "OK");
        if (mret == 0 && dup2(DRMFD, HIJACK_FD) == HIJACK_FD) {
            /* dup2 clears CLOEXEC on the new fd — child inherits master */
            MASTERFD = HIJACK_FD;
            /* relayed atomics hit file_priv->atomic / universal_planes caps
             * in the kernel handler — enable them on the shared file now,
             * before kwin's first TEST_ONLY commit arrives. */
            int c1 = drmSetClientCap(DRMFD, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
            int c2 = drmSetClientCap(DRMFD, DRM_CLIENT_CAP_ATOMIC, 1);
            fprintf(LOG, "kwinwrap: caps universal=%d atomic=%d\n", c1, c2);
            /* The vendor composer left the panel ON (crtc active, connector
             * linked). Its DSI bridge refuses mode changes on an active
             * panel ("seamless" path -> -22 in atomic check), and kwin's
             * per-output test commits then never pass. A normal compositor
             * starts from VT-off; emulate that with a disable commit. */
            unsigned dis_conn = 67, dis_crtc = 206;
            __u32 p_link = find_prop(dis_conn, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID");
            __u32 p_act  = find_prop(dis_crtc, DRM_MODE_OBJECT_CRTC, "ACTIVE");
            __u32 p_mode = find_prop(dis_crtc, DRM_MODE_OBJECT_CRTC, "MODE_ID");
            if (p_link && p_act && p_mode) {
                /* target crtc = whatever conn67 is linked to NOW (composer
                 * may have restored onto a different pipe); skip the crtc
                 * disable entirely if it is already unlinked */
                unsigned cur = 0;
                drmModeObjectProperties *cp =
                    drmModeObjectGetProperties(DRMFD, dis_conn, DRM_MODE_OBJECT_CONNECTOR);
                if (cp) {
                    for (uint32_t i = 0; i < cp->count_props; i++)
                        if (cp->props[i] == p_link) { cur = (unsigned)cp->prop_values[i]; break; }
                    drmModeFreeObjectProperties(cp);
                }
                __u32 objs[2] = { dis_conn, cur };
                __u32 cnts[2] = { 1, cur ? 2u : 0u };
                __u32 prs[3]  = { p_link, p_act, p_mode };
                __u64 vs[3]   = { 0, 0, 0 };
                struct drm_mode_atomic d = {
                    .flags = DRM_MODE_ATOMIC_ALLOW_MODESET,
                    .count_objs = cur ? 2 : 1,
                    .objs_ptr = (unsigned long long)(uintptr_t)objs,
                    .count_props_ptr = (unsigned long long)(uintptr_t)cnts,
                    .props_ptr = (unsigned long long)(uintptr_t)prs,
                    .prop_values_ptr = (unsigned long long)(uintptr_t)vs,
                };
                int dr = ioctl(DRMFD, DRM_IOCTL_MODE_ATOMIC, &d);
                fprintf(LOG, "kwinwrap: pre-disable conn%u(from crtc%u) ret=%d %s\n",
                        dis_conn, cur, dr, dr ? strerror(errno) : "OK");
            } else {
                fprintf(LOG, "kwinwrap: pre-disable props %u/%u/%u not found\n",
                        p_link, p_act, p_mode);
            }
            /* ---- DRM lease ------------------------------------------------
             * Phantom Virtual-1/2 writeback connectors (ids 33/64) show up as
             * kwin outputs ("Failed to find a working output layer
             * configuration! 5120x2560"). A lease of everything real — minus
             * those connectors — makes drmModeGetResources on the lessee fd
             * return only DSI-1. The lessee file is is_master=1 +
             * authenticated=1 (v6.6 drm_mode_create_lease_ioctl), so kwin may
             * not even trip the EACCES path anymore; if it still does, the
             * relay must stay inside kwin's namespace: RELAYFD = dup(leasefd)
             * shares the same drm_file, so kwin's blobs/FBs resolve there. */
            if (LEASE) {
                static __u32 lobjs[256];
                int nl = 0;
                drmModeRes *lr = drmModeGetResources(DRMFD);
                drmModePlaneRes *plr = drmModeGetPlaneResources(DRMFD);
                if (lr && plr) {
                    for (int i = 0; i < lr->count_connectors && nl < 250; i++) {
                        drmModeConnector *c = drmModeGetConnector(DRMFD, lr->connectors[i]);
                        if (!c) continue;
                        int skip = c->connector_type == DRM_MODE_CONNECTOR_VIRTUAL ||
                                   c->connector_type == DRM_MODE_CONNECTOR_WRITEBACK ||
                                   c->connector_id == 33 || c->connector_id == 64;
                        int cid = c->connector_id, cty = c->connector_type;
                        drmModeFreeConnector(c);
                        if (skip) { fprintf(LOG, "kwinwrap: lease SKIP conn=%d type=%d\n", cid, cty); continue; }
                        lobjs[nl++] = cid;
                    }
                    for (int i = 0; i < lr->count_crtcs && nl < 250; i++) lobjs[nl++] = lr->crtcs[i];
                    /* v6.6 drm_mode_object_lease_required: only FB/CONNECTOR/
                     * PLANE/CRTC are leaseable — encoders give EINVAL. */
                    for (uint32_t i = 0; i < plr->count_planes && nl < 250; i++) lobjs[nl++] = plr->planes[i];
                } else {
                    fprintf(LOG, "kwinwrap: lease GetResources failed (%s)\n", strerror(errno));
                }
                struct drm_mode_create_lease cl = {
                    .object_ids = (unsigned long long)(uintptr_t)lobjs,
                    .object_count = nl,
                    .flags = 0,
                };
                int lret = ioctl(DRMFD, DRM_IOCTL_MODE_CREATE_LEASE, &cl);
                fprintf(LOG, "kwinwrap: lease %d objs ret=%d fd=%u lessee_id=%u %s\n",
                        nl, lret, cl.fd, cl.lessee_id, lret ? strerror(errno) : "OK");
                if (lret == 0) {
                    int lfd = (int)cl.fd;
                    RELAYFD = dup(lfd);
                    drmSetClientCap(lfd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
                    drmSetClientCap(lfd, DRM_CLIENT_CAP_ATOMIC, 1);
                    drmSetClientCap(RELAYFD, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
                    drmSetClientCap(RELAYFD, DRM_CLIENT_CAP_ATOMIC, 1);
                    if (dup2(lfd, HIJACK_FD) == HIJACK_FD) {
                        MASTERFD = HIJACK_FD;   /* child gets the LEASE, not master */
                        fprintf(LOG, "kwinwrap: HIJACK_FD=%d is lease fd, relay fd=%d\n",
                                HIJACK_FD, RELAYFD);
                        /* Does this kernel filter GetResources by lease? */
                        drmModeRes *vr = drmModeGetResources(RELAYFD);
                        if (vr) {
                            fprintf(LOG, "kwinwrap: lease view: %d conns [", vr->count_connectors);
                            for (int i = 0; i < vr->count_connectors; i++)
                                fprintf(LOG, "%d ", vr->connectors[i]);
                            fprintf(LOG, "] %d crtcs %d encs\n",
                                    vr->count_crtcs, vr->count_encoders);
                            drmModeFreeResources(vr);
                        } else fprintf(LOG, "kwinwrap: lease view GetResources failed\n");
                        drmModePlaneRes *vpr = drmModeGetPlaneResources(RELAYFD);
                        fprintf(LOG, "kwinwrap: lease planes=%u\n",
                                vpr ? vpr->count_planes : 0u);
                        if (vpr) drmModeFreePlaneResources(vpr);
                    } else {
                        fprintf(LOG, "kwinwrap: dup2 lease->%d failed (%s), stay on master\n",
                                HIJACK_FD, strerror(errno));
                        close(lfd);
                    }
                }
            }
            fflush(LOG);
        } else {
            if (mret) perror("kwinwrap: SET_MASTER failed");
            HIJACK = 0;
        }
        fflush(LOG);
    } else if (HIJACK) {
        perror("kwinwrap: card0 open failed");
        HIJACK = 0;
    }

    if (HIJACK && MASTERFD >= 0) {
        /* Android blanking writes connector brightness=0 before dying; kwin
         * never touches the SDE "brightness" prop -> panel stays black.
         * We are the only master right now, so this is the last chance to
         * write it without EACCES (KWINWRAP_BRIGHTNESS=<0..4095>). */
        char *be = getenv("KWINWRAP_BRIGHTNESS");
        if (be && *be) {
            __u32 pid_ = find_prop(67, DRM_MODE_OBJECT_CONNECTOR, "brightness");
            struct drm_mode_obj_set_property sp = {
                .obj_id = 67, .obj_type = DRM_MODE_OBJECT_CONNECTOR,
                .prop_id = pid_, .value = strtoull(be, NULL, 0),
            };
            int r = pid_ ? ioctl(DRMFD, DRM_IOCTL_MODE_OBJ_SETPROPERTY, &sp) : -1;
            fprintf(LOG, "kwinwrap: brightness %s prop=%u ret=%d %s\n",
                    be, pid_, r, r ? strerror(errno) : "OK");
            fflush(LOG);
        }
    }

    if (HIJACK && MASTERFD >= 0 && !LEASE) {
        /* Hand DRM to kwin natively: release our master so kwin's first REAL
         * open of card0 auto-becomes master (first-opener rule, cf. uid1000
         * SETMASTER probe). Relay remains only as probe-failure fallback. */
        int dret = ioctl(DRMFD, DRM_DROP_MASTER_REQ, 0);
        fprintf(LOG, "kwinwrap: DROP_MASTER ret=%d %s\n",
                dret, dret ? strerror(errno) : "OK");
        fflush(LOG);
    }

    pid_t child = fork();
    if (child == 0) {
        if (ptrace(PTRACE_TRACEME, 0, NULL, NULL)) { perror("traceme"); _exit(2); }
        if (SECCMODE && install_drm_filter()) {
            fprintf(stderr, "kwinwrap: seccomp install failed (%s)\n",
                    strerror(errno));
            _exit(4);
        }
        char *u = getenv("KWINWRAP_UID");
        char *g = getenv("KWINWRAP_GID");
        if (u && g) {
            uid_t nu = (uid_t)atoi(u);
            gid_t ng = (gid_t)atoi(g);
            /* 补上补充组 —— 原来这里只有 setgid+setuid，exec 出去就是裸的 uid/gid，
             * 一个补充组都不带。/dev/dri/renderD128 与 /dev/kgsl-3d0 都是
             * crw-rw---- root:droidspaces-gpu(786)，桌面用户明明在该组里（id 输出含 786），
             * 组身份一丢就 EACCES ⇒ kwin 里 "MESA-EGL: failed to open renderD128/kgsl-3d0"
             * → "EGL setup failed, disabling glamor" → **falling back to sw**（llvmpipe），
             * 表现就是 09-25 用户实报的"GPU 驱动炸了、设置界面花屏、动效全无"。
             * card0 之所以没暴露这个洞，是因为轮里一直有 `chmod 666 /dev/dri/card0` 兜着。
             * 治法选补组而不是把 render 节点 chmod 666：后者等于给安卓侧所有进程开 GPU。
             * 顺带把 video(44)/input(996) 这些本就该属于桌面用户的权限一起对齐。
             * 失败退回 setgroups(0)，绝不静默。 */
            struct passwd *pw = getpwuid(nu);
            if (pw && initgroups(pw->pw_name, ng) == 0) {
                fprintf(LOG, "KWINWRAP-GROUPS: initgroups(%s,%d) ok ngroups=%d\n",
                        pw->pw_name, (int)ng, getgroups(0, NULL));
            } else {
                fprintf(LOG, "KWINWRAP-GROUPS: initgroups 失败(%s)，退回只清组\n",
                        strerror(errno));
                setgroups(0, NULL);
            }
            if (setgid(ng)) perror("kwinwrap: setgid");
            if (setuid(nu)) perror("kwinwrap: setuid");
        }
        execvp(argv[di], argv + di);
        perror("execvp");
        _exit(3);
    }

    int status;
    CHILD = child;
    waitpid(child, &status, 0);
    ptrace(PTRACE_SETOPTIONS, child, NULL,
           (void *)(long)(PTRACE_O_TRACESYSGOOD | PTRACE_O_TRACECLONE |
                          PTRACE_O_TRACEFORK | PTRACE_O_TRACEVFORK |
                          PTRACE_O_EXITKILL |
                          /* RET_TRACE events are silently downgraded to
                           * -ENOSYS unless the tracer asked for them: */
                          (SECCMODE ? (1 << PTRACE_EVENT_SECCOMP) : 0)));
    phases[nphase++] = (struct phase){ child, 0 };
    ptrace(PTRACE_SYSCALL, child, NULL, NULL);

    for (;;) {
        pid_t t = waitpid(-1, &status, __WALL);
        if (t < 0) { if (errno == EINTR) continue; break; }
        if (WIFEXITED(status) || WIFSIGNALED(status)) {
            if (t == child) { fprintf(LOG, "child gone status=%d\n", status); fflush(LOG); break; }
            for (int i = 0; i < nphase; i++)
                if (phases[i].t == t) { phases[i] = phases[--nphase]; break; }
            continue;
        }
        if (WIFSTOPPED(status) &&
            (status >> 8) == (SIGTRAP | (PTRACE_EVENT_SECCOMP << 8))) {
            /* seccomp RET_TRACE entry stop: only the syscalls we care about
             * get here.  Run the entry handler, then arm exactly the
             * matching exit stop with one PTRACE_SYSCALL. */
            struct phase *ph = NULL;
            for (int i = 0; i < nphase; i++)
                if (phases[i].t == t) { ph = &phases[i]; break; }
            if (!ph && nphase < 512) {
                phases[nphase++] = (struct phase){ t, 0, 0 };
                ph = &phases[nphase - 1];
            }
            if (ph) {
                handle_entry(t, ph);
                ph->p = 1;
                ptrace(PTRACE_SYSCALL, t, NULL, NULL);
            } else {
                ptrace(PTRACE_CONT, t, NULL, NULL);
            }
            continue;
        }
        if (WIFSTOPPED(status) && (status >> 8) == (SIGTRAP | 0x80)) {
            /* syscall-stop */
            struct phase *ph = NULL;
            for (int i = 0; i < nphase; i++)
                if (phases[i].t == t) { ph = &phases[i]; break; }
            if (!ph && nphase < 512) {
                phases[nphase++] = (struct phase){ t, 0, 0 };
                ph = &phases[nphase - 1];
            }
            int dir = syscall_dir(t);
            int entry = dir ? dir == 1 : (ph && ph->p == 0);
            int exity = dir ? dir == 2 : (ph && ph->p == 1);
            if (ph && entry) {
                handle_entry(t, ph);
            } else if (ph && exity && ph->sub == 6 && ph->nr == NR_IOCTL) {
                struct ptregs r;
                if (getregs(t, &r) == 0) {
                    long long own = (long long)r.regs[0];
                    fprintf(LOG, "PROBE tid=%d fd=%llu own=%lld %s\n",
                            t, r.regs[0], own, own ? strerror((int)-own) : "OK");
                    fflush(LOG);
                    /* Only EACCES proves "not master". TEST_ONLY commits
                     * legitimately fail (-22/-2) while still EXECUTING on
                     * kwin's master fd — treat anything else as native. */
                    if (own != -EACCES) {
                        NATIVE = 1;
                        fprintf(LOG, ">>> kwin is native master: passthrough\n");
                    } else {
                        NATIVE = 0;
                        int mr = ioctl(DRMFD, DRM_SET_MASTER_REQ, 0);
                        fprintf(LOG, ">>> re-SETMASTER ret=%d %s; relaying\n",
                                mr, mr ? strerror(errno) : "OK");
                        struct drm_mode_atomic la = { 0 };
                        long rr = -EINVAL;
                        if (build_local_atomic(t, r.regs[2], &la) == 0)
                            rr = relay_atomic(&la);
                        fprintf(LOG, "PROBE-RELAY flags=0x%x nobjs=%u -> ret=%ld %s\n",
                                la.flags, la.count_objs, rr,
                                rr ? strerror((int)-rr) : "OK");
                        r.regs[0] = (unsigned long long)rr;
                        setregs(t, &r);
                    }
                    fflush(LOG);
                }
                ph->sub = 0;
            } else if (ph && exity && ph->sub == 5 && ph->nr == NR_IOCTL) {
                struct ptregs r;
                if (getregs(t, &r) == 0 && (long long)r.regs[0] == 0)
                    filter_getres(t, r.regs[2]);
                ph->sub = 0;
            } else if (ph && exity && ph->sub == 3) {
                struct ptregs r;
                if (getregs(t, &r) == 0)
                    log_hijack_result(t, (long long)r.regs[0]);
                ph->sub = 0;
            } else if (ph && exity && ph->sub == 4 && ph->nr == NR_IOCTL) {
                struct ptregs r;
                if (getregs(t, &r) == 0) {
                    long long own = (long long)r.regs[0];
                    r.regs[0] = (unsigned long long)ph->hret;
                    setregs(t, &r);
                    fprintf(LOG, "<<< ATOMIC tid=%d own=%lld relay=%lld injected\n",
                            t, own, ph->hret);
                    fflush(LOG);
                }
                ph->sub = 0;
            } else if (ph && exity && ph->sub == 2 && ph->nr == NR_IOCTL) {
                struct ptregs r;
                if (getregs(t, &r) == 0) {
                    static long long last_commit_ns;
                    long long now = nsnow();
                    long long dt_us = last_commit_ns ?
                        (now - last_commit_ns) / 1000 : 0;
                    long long exec_us = ph->e_ns ? (now - ph->e_ns) / 1000 : 0;
                    if (r.regs[0] == 0) last_commit_ns = now;
                    fprintf(LOG, "<<< ATOMIC tid=%d f=0x%llx ret=%lld dt=%lldus exec=%lldus%s\n",
                            t, (unsigned long long)ph->hret, (long long)r.regs[0],
                            dt_us, exec_us,
                            (long long)r.regs[0] < 0
                                ? strerror((int)-(long long)r.regs[0]) : "");
                    if ((long long)r.regs[0] == -2 && sc_dumped < 12 &&
                        sc_no && t == sc_tid) {
                        sc_dumped++;
                        __u32 dno = sc_no > 60 ? 60 : sc_no;
                        __u32 dnp = sc_np > 240 ? 240 : sc_np;
                        __u32 do_[64], dc[64], dp[240];
                        int ok = readmem(t, sc_sp, do_, dno * 4) >= 0 &&
                                 readmem(t, sc_sp + 256, dc, dno * 4) >= 0 &&
                                 readmem(t, sc_sp + 512, dp, dnp * 4) >= 0;
                        fprintf(LOG, "SCRATCH-DUMP #%d tid=%d ok=%d objs=", sc_dumped, t, ok);
                        for (__u32 i = 0; i < dno; i++) fprintf(LOG, "%u,", do_[i]);
                        fprintf(LOG, " cnts=");
                        for (__u32 i = 0; i < dno; i++) fprintf(LOG, "%u,", dc[i]);
                        fprintf(LOG, " props=");
                        for (__u32 i = 0; i < dnp; i++) fprintf(LOG, "%u,", dp[i]);
                        fprintf(LOG, "\n");
                    }
                    fflush(LOG);
                    ph->sub = 0;
                }
            } else if (ph && exity && (ph->nr == NR_OPENAT || ph->nr == 437)) {
                struct ptregs r;
                if (getregs(t, &r) == 0) {
                    if ((long long)r.regs[0] >= 0) {
                        log_card_open(t, (long)r.regs[0], ph->path);
                        if (HIJACK && !ph->path[0]) {
                            /* path unreadable — did the child really open a
                             * DRM node (unmastered file = future -13s)? */
                            char lnk[128] = "", procl[64];
                            snprintf(procl, sizeof procl, "/proc/%d/fd/%lld",
                                     t, (long long)r.regs[0]);
                            int n = readlink(procl, lnk, sizeof lnk - 1);
                            if (n > 0 && (strstr(lnk, "card") ||
                                          strstr(lnk, "render")))
                                fprintf(LOG, "REALOPEN tid=%d fd=%lld -> %s\n",
                                        t, (long long)r.regs[0], lnk);
                            fflush(LOG);
                        }
                    } else if (strstr(ph->path, "card")) {
                        fprintf(LOG, "openat FAIL tid=%d %s ret=%lld\n",
                                t, ph->path, (long long)r.regs[0]);
                        fflush(LOG);
                    }
                }
            }
            if (SECCMODE) {
                if (ph && exity) ph->p = 0;
                ptrace(ph && exity ? PTRACE_CONT : PTRACE_SYSCALL,
                       t, NULL, NULL);
            } else {
                if (ph) ph->p ^= 1;
                ptrace(PTRACE_SYSCALL, t, NULL, NULL);
            }
            continue;
        }
        if (WIFSTOPPED(status) && WSTOPSIG(status) == SIGTRAP) {
            /* ptrace event or group-stop: register tid, continue quietly.
             * In seccomp mode only re-arm a syscall-stop when an exit stop
             * is already pending; arming fresh would confuse entry/exit
             * pairing with the seccomp events. */
            struct phase *ph2 = NULL;
            for (int i = 0; i < nphase; i++)
                if (phases[i].t == t) { ph2 = &phases[i]; break; }
            if (!ph2 && nphase < 512) {
                phases[nphase++] = (struct phase){ t, 0, 0 };
                ph2 = &phases[nphase - 1];
            }
            int arm = !SECCMODE || (ph2 && ph2->p == 1);
            ptrace(arm ? PTRACE_SYSCALL : PTRACE_CONT, t, NULL, NULL);
            continue;
        }
        /* any other signal-stop: forward unchanged, keeping an armed
         * exit-stop pending if the signal interrupted a trapped syscall */
        {
            struct phase *ph2 = NULL;
            int fresh = 0;
            for (int i = 0; i < nphase; i++)
                if (phases[i].t == t) { ph2 = &phases[i]; break; }
            if (!ph2 && nphase < 512) {
                phases[nphase++] = (struct phase){ t, 0, 0 };
                ph2 = &phases[nphase - 1];
                fresh = 1;
            }
            int sig = WSTOPSIG(status);
            /* PTRACE_O_TRACEFORK auto-attaches a forked child (Xwayland) with a
             * pending SIGSTOP group-stop; re-injecting it would pin the child
             * stopped forever (stop -> forward SIGSTOP -> stop ...), so the
             * first stop we ever see for a tid swallows it. */
            if (fresh && sig == SIGSTOP) sig = 0;
            int arm = !SECCMODE || (ph2 && ph2->p == 1);
            ptrace(arm ? PTRACE_SYSCALL : PTRACE_CONT, t, NULL, (void *)(long)sig);
        }
    }
    return 0;
}
