// machoscan —— 快速扫描目录下的全部 Mach-O 文件（单进程，零 fork）
//
// 用法: machoscan <真实目录> [输出路径前缀]
//
// 为什么需要它：大应用（如 Kodi 含 12,000+ 文件）用 shell 逐文件 fork head+od+tr
// 耗时超过 10 分钟；用 C fts_open + read(4) 扫描全部 12,000+ 文件不到 0.1 秒。

#include <fcntl.h>
#include <fts.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int is_macho_file(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    uint32_t magic = 0;
    ssize_t n = read(fd, &magic, sizeof(magic));
    close(fd);
    if (n != 4) return 0;
    // Little-endian & big-endian 32/64-bit Mach-O and Fat (universal) binaries
    return magic == 0xfeedfacfU || magic == 0xfeedfaceU ||
           magic == 0xcffaedfeU || magic == 0xcefaedfeU ||
           magic == 0xbebafecaU || magic == 0xcafebabeU;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "用法: machoscan <dir> [prefix]\n");
        return 2;
    }
    const char *root = argv[1];
    const char *prefix = (argc >= 3 && argv[2][0] != '\0') ? argv[2] : root;
    size_t root_len = strlen(root);
    while (root_len > 1 && root[root_len - 1] == '/') root_len--;

    char *paths[2] = { (char *)root, NULL };
    FTS *ftsp = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (!ftsp) {
        perror("fts_open");
        return 1;
    }

    FTSENT *ent;
    while ((ent = fts_read(ftsp)) != NULL) {
        if (ent->fts_info != FTS_F) continue;
        if (!is_macho_file(ent->fts_path)) continue;
        if (prefix != root && strncmp(ent->fts_path, root, root_len) == 0) {
            printf("%s%s\n", prefix, ent->fts_path + root_len);
        } else {
            printf("%s\n", ent->fts_path);
        }
    }
    fts_close(ftsp);
    return 0;
}
