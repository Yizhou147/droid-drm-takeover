// storage-rebind —— 把安卓当下活的存储挂载重新接进容器的 mount namespace。
//
// 背景（详见 工作总结 §3.12）：容器的 /storage/emulated/0 是容器 boot 时对安卓那个
// fuse 超级块做的一次 bind。安卓每次重启框架（stop/start、MediaProvider 崩、交还）
// 都会 mount 出一个**新的**超级块，容器还抱着旧的那个 —— 之后一律 ENOTCONN，
// 跟权限无关，改授权永远修不好。/data/media/0（容器的 /Android）在 /data 上，
// 不受这个影响，但它可能因为 boot 时存储没就绪而根本没挂上，这里一并补。
//
// 必须在安卓侧（root、init mount ns）跑：在容器 ns 里 mount --bind 宿主机路径是错的，
// 路径解析走的是当前 ns，会把已经抱住的旧超级块再绑一遍（实测踩过）。
// 跨 ns 注入只能用 open_tree(OPEN_TREE_CLONE) + move_mount。
//
// 用法: storage-rebind [-c] [-s 源] [-d 容器挂点] [容器init pid]
//   -c          只报告不一致，不动手（dry run）
//   -s/-d       只做这一对（调试/手动修某个挂点时用）；缺省做 TAB 里全部
//   pid         缺省自动取 /data/local/Droidspaces/Pids/*.pid
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <unistd.h>
#include <sched.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/wait.h>
#include <sys/sysmacros.h>
#include <sys/syscall.h>

// 内核 5.2 才有 mount fd API，老 libc 头文件不一定带
#ifndef OPEN_TREE_CLONE
#define OPEN_TREE_CLONE 1
#endif
#ifndef AT_RECURSIVE
#define AT_RECURSIVE 0x8000
#endif
#ifndef MOVE_MOUNT_F_EMPTY_PATH
#define MOVE_MOUNT_F_EMPTY_PATH 0x00000004
#endif
#ifndef SYS_open_tree
#define SYS_open_tree 428
#endif
#ifndef SYS_move_mount
#define SYS_move_mount 429
#endif

#define PIDFILE_DIR "/data/local/Droidspaces/Pids"

struct mount_pair {
    const char *src;   // 安卓（init ns）里的源路径
    const char *dst;   // 容器里的挂点
    const char *name;  // 只给日志用
};

// 表里两项的挂点在容器 ns 内是绝对路径，所以 dst 直接按容器根解析。
static const struct mount_pair TAB[] = {
    { "/storage/emulated/0", "/storage/emulated/0", "android-storage(fuse)" },
    { "/data/media/0", "/Android", "android-media(raw)" },
};
static const int TAB_N = sizeof(TAB) / sizeof(TAB[0]);

// mountinfo 里“真正提供这个路径的那个挂载”的 dev（major:minor 编码后的值）。
// 故意只读 /proc，绝不 stat 挂载本身：它的 daemon 被 SIGSTOP 时（轮里的常态）
// 任何 IO 都会永久挂住。最长前缀匹配，"/" 也参与，这样“没挂上”会回落成根的 dev，
// 与“挂的是旧超级块”一起都能被识别成不一致。
static unsigned long mountinfo_dev(const char *mountinfo_path, const char *path) {
    FILE *f = fopen(mountinfo_path, "r");
    if (!f) return 0;

    char line[4096], mnt[1024];
    size_t best = 0;
    unsigned long dev = 0;

    while (fgets(line, sizeof line, f)) {
        unsigned int ma = 0, mi = 0;
        // 字段：id parent major:minor root mountpoint options...
        if (sscanf(line, "%*u %*u %u:%u %*s %1023s", &ma, &mi, mnt) != 3) continue;

        size_t n = strlen(mnt);
        if (n == 0 || n >= sizeof mnt || strncmp(path, mnt, n) != 0) continue;
        // 必须在路径分量边界上截断；"/" 例外，它覆盖所有绝对路径
        if (path[n] != '\0' && path[n] != '/' && mnt[n - 1] != '/') continue;
        if (n <= best) continue;

        best = n;
        dev = makedev(ma, mi);
    }
    fclose(f);
    return dev;
}

static void mkdir_p(const char *path) {
    char buf[512];
    snprintf(buf, sizeof buf, "%s", path);
    for (char *p = buf + 1; *p; p++) {
        if (*p != '/') continue;
        *p = '\0';
        mkdir(buf, 0755);
        *p = '/';
    }
    mkdir(buf, 0755);
}

// 一次修复在子进程里做：setns 之后本进程的根会切到容器，父进程要继续按宿主机路径
// 解析下一项；另外挂载调用万一卡住，alarm 兜底，不能把调用脚本一起拖死。
static int rebind_one(pid_t cpid, const char *src, const char *dst) {
    char nspath[64];
    snprintf(nspath, sizeof nspath, "/proc/%d/ns/mnt", (int)cpid);

    pid_t ch = fork();
    if (ch < 0) { fprintf(stderr, "fork FAIL %s\n", strerror(errno)); return -1; }

    if (ch == 0) {
        alarm(10);
        int nsfd = open(nspath, O_RDONLY | O_CLOEXEC);
        int tree = (int)syscall(SYS_open_tree, AT_FDCWD, src,
                                OPEN_TREE_CLONE | AT_RECURSIVE);
        if (nsfd < 0 || tree < 0) {
            fprintf(stderr, "open ns=%s open_tree=%s\n",
                    nsfd < 0 ? strerror(errno) : "ok",
                    tree < 0 ? strerror(errno) : "ok");
            _exit(2);
        }
        if (setns(nsfd, CLONE_NEWNS) < 0) { fprintf(stderr, "setns %s\n", strerror(errno)); _exit(2); }

        mkdir_p(dst);                       // boot 时存储没就绪则挂点压根不存在
        umount2(dst, MNT_DETACH);           // lazy：旧端点死了/冻着都能摘掉
        if (syscall(SYS_move_mount, tree, "", AT_FDCWD, dst,
                    MOVE_MOUNT_F_EMPTY_PATH) < 0) {
            fprintf(stderr, "move_mount %s\n", strerror(errno));
            _exit(3);
        }
        _exit(0);
    }

    int st = 0;
    if (waitpid(ch, &st, 0) < 0) return -1;
    if (WIFEXITED(st) && WEXITSTATUS(st) == 0) return 0;
    return WIFEXITED(st) ? -WEXITSTATUS(st) : -1;
}

int main(int argc, char **argv) {
    int check = 0;
    pid_t cpid = 0;
    const char *only_src = NULL, *only_dst = NULL;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-c")) { check = 1; continue; }
        if (!strcmp(argv[i], "-s") && i + 1 < argc) { only_src = argv[++i]; continue; }
        if (!strcmp(argv[i], "-d") && i + 1 < argc) { only_dst = argv[++i]; continue; }
        cpid = atoi(argv[i]);
    }

    if (cpid <= 0) {
        // 自动取容器 pidfile（内容是容器 init 的 pid）；目录里通常就一个
        DIR *d = opendir(PIDFILE_DIR);
        char name[256];
        if (d) {
            struct dirent *de;
            while ((de = readdir(d))) {
                size_t n = strlen(de->d_name);
                if (n < 5 || strcmp(de->d_name + n - 4, ".pid")) continue;
                snprintf(name, sizeof name, "%s/%s", PIDFILE_DIR, de->d_name);
                FILE *p = fopen(name, "r");
                if (p) {
                    int v = 0;
                    if (fscanf(p, "%d", &v) == 1 && v > 0) cpid = v;
                    fclose(p);
                }
                if (cpid > 0) break;
            }
            closedir(d);
        }
    }
    if (cpid <= 0) { fprintf(stderr, "容器 pid 取不到，显式传 pid\n"); return 1; }

    char guest_mi[64];
    snprintf(guest_mi, sizeof guest_mi, "/proc/%d/mountinfo", (int)cpid);
    if (access(guest_mi, R_OK)) { fprintf(stderr, "%s 读不了（容器没在跑？）\n", guest_mi); return 1; }

    const struct mount_pair *tab = TAB;
    int n = TAB_N;
    struct mount_pair one;
    if (only_src && only_dst) {
        one.src = only_src; one.dst = only_dst; one.name = "custom";
        tab = &one;
        n = 1;
    } else if (only_src || only_dst) {
        fprintf(stderr, "-s 和 -d 要成对给\n");
        return 1;
    }

    int fixed = 0, bad = 0;
    for (int i = 0; i < n; i++) {
        unsigned long h = mountinfo_dev("/proc/self/mountinfo", tab[i].src);
        unsigned long g = mountinfo_dev(guest_mi, tab[i].dst);

        if (h == 0) { printf("%s SKIP(宿主机读不到 mountinfo)\n", tab[i].name); bad++; continue; }
        if (h == g) { printf("%s SAME %u:%u\n", tab[i].name, major(h), minor(h)); continue; }

        printf("%s STALE host=%u:%u guest=%u:%u%s\n", tab[i].name,
               major(h), minor(h), major(g), minor(g), check ? " (check-only)" : "");
        if (check) { bad++; continue; }

        int rc = rebind_one(cpid, tab[i].src, tab[i].dst);
        if (rc == 0) {
            printf("%s REBIND-OK\n", tab[i].name);
            fixed++;
        } else {
            printf("%s REBIND-FAIL rc=%d\n", tab[i].name, rc);
            bad++;
        }
    }

    if (fixed) printf("STORAGE-FIXED fixed=%d\n", fixed);
    if (check) return bad ? 10 : 0;
    return bad ? 1 : 0;
}
