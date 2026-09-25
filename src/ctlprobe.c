// 用法: ctlprobe <major> <minor> —— 打开临时节点测 ALSA ctl PVERSION
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/sysmacros.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sound/asound.h>

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s maj min\n", argv[0]); return 2; }
    int maj = atoi(argv[1]), min = atoi(argv[2]);
    char path[64];
    snprintf(path, sizeof path, "/dev/ctlprobe.%d", min);  // /tmp 带 nodev，必须建在 /dev 下
    unlink(path);
    if (mknod(path, S_IFCHR | 0600, makedev(maj, min)) && fprintf(stderr, "mknod %d:%d FAIL\n", maj, min));
    int fd = open(path, O_RDWR);
    if (fd < 0) { printf("%d:%d open FAIL\n", maj, min); unlink(path); return 1; }
    int ver = -1;
    if (ioctl(fd, SNDRV_CTL_IOCTL_PVERSION, &ver) == 0) {
        struct snd_ctl_card_info ci;
        int rc = ioctl(fd, SNDRV_CTL_IOCTL_CARD_INFO, &ci);
        printf("%d:%d CTL OK pversion=%d card_info_rc=%d name=%s\n", maj, min, ver, rc,
               rc == 0 ? (char *)ci.id : "");
    } else {
        printf("%d:%d NOT-CTL\n", maj, min);
    }
    close(fd); unlink(path);
    return 0;
}
